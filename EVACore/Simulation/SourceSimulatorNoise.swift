//
//  SourceSimulatorNoise.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-3 Stage 3b — the noise model and truth-backed scoring math for the Source
//  Simulator. The clean forward field is known exactly at every instant, so this
//  adds a *known* amount of noise (and, elsewhere, known artifacts) and scores
//  the result against that truth without any inverse solver — the honest
//  measurement EVA can make that a real recording cannot.
//

import Foundation

nonisolated enum SourceSimulatorNoise {

    /// Background noise spectra. White is flat; pink is 1/f (physiological EEG
    /// background is closer to pink). Further models (measured-EEG background,
    /// spatially-correlated covariance, per-band, sensor faults) are the
    /// ROADMAP's later additions.
    enum Model: String, CaseIterable, Identifiable, Sendable {
        case white = "White"
        case pink = "Pink (1/f)"
        var id: String { rawValue }
    }

    /// A channels × samples noise matrix, scaled so the whole-recording SNR of
    /// `clean` over the returned noise equals `targetSNRdB`. Deterministic in
    /// `seed`. When `clean` has no power, the noise is returned at unit scale.
    static func noiseMatrix(
        clean: [[Double]],
        model: Model,
        targetSNRdB: Double,
        seed: UInt64
    ) -> [[Double]] {
        let channelCount = clean.count
        let sampleCount = clean.first?.count ?? 0
        guard channelCount > 0, sampleCount > 0 else { return [] }

        var noise = [[Double]](repeating: [Double](repeating: 0, count: sampleCount), count: channelCount)
        for c in 0..<channelCount {
            // A distinct stream per channel (independent per electrode — the
            // simplest, non-spatially-correlated model).
            var source = GaussianSource(seed: seed &+ UInt64(c) &* 0x9E3779B97F4A7C15)
            switch model {
            case .white:
                for t in 0..<sampleCount { noise[c][t] = source.gaussian() }
            case .pink:
                noise[c] = pink(count: sampleCount, source: &source)
            }
        }

        // Scale to the requested SNR relative to the clean field's mean power.
        let cleanPower = meanSquare(clean)
        let noisePower = meanSquare(noise)
        guard cleanPower > 0, noisePower > 0 else { return noise }
        let targetNoisePower = cleanPower / pow(10.0, targetSNRdB / 10.0)
        let scale = (targetNoisePower / noisePower).squareRoot()
        for c in 0..<channelCount {
            for t in 0..<sampleCount { noise[c][t] *= scale }
        }
        return noise
    }

    /// Paul Kellet's refined pinking filter over white noise, normalized to unit
    /// standard deviation. Gives a 1/f spectrum across the audio-ish band, which
    /// is a good enough physiological-background stand-in until the measured-EEG
    /// model lands.
    static func pink(count: Int, source: inout GaussianSource) -> [Double] {
        guard count > 0 else { return [] }
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let white = source.gaussian()
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            out[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
        }
        // Normalize to unit SD so the SNR scaling below is meaningful.
        let mean = out.reduce(0, +) / Double(count)
        var variance = 0.0
        for v in out { let d = v - mean; variance += d * d }
        variance /= Double(count)
        let sd = variance > 0 ? variance.squareRoot() : 1
        for i in 0..<count { out[i] = (out[i] - mean) / sd }
        return out
    }

    // MARK: Scoring

    /// SNR in dB and Pearson correlation of `estimate` against the `truth`
    /// (clean) field, over whatever region the two slices cover. Used both for a
    /// whole-recording score and, on a single-sample slice, for the live readout.
    struct Score: Sendable, Equatable {
        var snrDb: Double
        var correlation: Double
    }

    /// Whole-recording score: `noisy = clean + contamination`. SNR uses the
    /// clean power over the contamination power; correlation is between the
    /// flattened clean and noisy matrices.
    static func score(clean: [[Double]], noisy: [[Double]]) -> Score {
        let cleanFlat = clean.flatMap { $0 }
        let noisyFlat = noisy.flatMap { $0 }
        let n = min(cleanFlat.count, noisyFlat.count)
        guard n > 0 else { return Score(snrDb: .nan, correlation: .nan) }
        var signalPower = 0.0, noisePower = 0.0
        for i in 0..<n {
            signalPower += cleanFlat[i] * cleanFlat[i]
            let d = noisyFlat[i] - cleanFlat[i]
            noisePower += d * d
        }
        let snr = noisePower > 0 ? 10 * log10(signalPower / noisePower) : .infinity
        return Score(snrDb: snr, correlation: pearson(Array(cleanFlat[0..<n]), Array(noisyFlat[0..<n])))
    }

    /// Score at one instant (across channels) — the live scrub readout.
    static func instantaneousScore(cleanColumn: [Double], noisyColumn: [Double]) -> Score {
        score(clean: [cleanColumn], noisy: [noisyColumn])
    }

    // MARK: Helpers

    private static func meanSquare(_ matrix: [[Double]]) -> Double {
        var sum = 0.0, count = 0
        for row in matrix { for v in row { sum += v * v; count += 1 } }
        return count > 0 ? sum / Double(count) : 0
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return .nan }
        let ma = a.reduce(0, +) / Double(n)
        let mb = b.reduce(0, +) / Double(n)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<n {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        guard da > 0, db > 0 else { return .nan }
        return num / (da * db).squareRoot()
    }
}
