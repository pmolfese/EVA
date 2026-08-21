//
//  SNRMetrics.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Scoring a correction against ground truth.
//
//  The headline number is the paper's:
//
//      SNR = std(EEG) / std(EEG - EEG_corrected)
//
//  It is a summary of the discrepancy between two signals, and the paper is
//  candid about what it cannot do: being normalized, it does not quantify
//  absolute residual noise, and being a difference measure, it cannot tell
//  signal *attenuation* from signal *amplification*. A method that halves the
//  EEG and one that doubles it can land on the same SNR.
//
//  So every band here is reported with a second number — the ratio of corrected
//  to clean band power, in dB — which does separate those two cases. Negative dB
//  means the correction removed EEG along with the artifact (over-filtering,
//  which the paper warns is the real hazard); positive means it left more energy
//  in the band than belongs there. Read the two together: a high SNR with a
//  strongly negative dB is a method that is quietly deleting the signal.
//

import Foundation

nonisolated struct BandScore: Codable, Sendable {
    var name: String
    var lowHz: Double
    var highHz: Double
    /// std(clean) / std(clean - corrected), within the band.
    var snr: Double
    /// 10·log10(corrected band power / clean band power).
    var powerRatioDb: Double
    /// Band-limited RMS of the ground-truth EEG, in µV.
    var cleanRMS: Double
    /// Band-limited RMS of what the correction got wrong, in µV.
    var residualRMS: Double
}

nonisolated struct CorrectionScore: Codable, Sendable {
    var label: String
    /// The paper's Equation 2, over the whole band and all channels.
    var broadbandSNR: Double
    var cleanStandardDeviation: Double
    var residualStandardDeviation: Double
    var bands: [BandScore]
}

nonisolated enum SNRMetrics {

    /// The paper's evaluation bands: 4 Hz wide to 20 Hz, then 5 Hz wide to 70.
    static let defaultBands: [(name: String, low: Double, high: Double)] = [
        ("0-4", 0, 4), ("4-8", 4, 8), ("8-12", 8, 12), ("12-16", 12, 16),
        ("16-20", 16, 20), ("20-25", 20, 25), ("25-30", 25, 30), ("30-35", 30, 35),
        ("35-40", 35, 40), ("40-45", 40, 45), ("45-50", 45, 50), ("50-55", 50, 55),
        ("55-60", 55, 60), ("60-65", 60, 65), ("65-70", 65, 70)
    ]

    static func score(
        label: String,
        clean: [[Double]],
        corrected: [[Double]],
        samplingRate: Double,
        bands: [(name: String, low: Double, high: Double)] = defaultBands,
        segmentLength: Int = 4096
    ) -> CorrectionScore {
        precondition(clean.count == corrected.count, "channel counts must match")

        var residual = [[Double]]()
        residual.reserveCapacity(clean.count)
        for channel in clean.indices {
            let a = clean[channel]
            let b = corrected[channel]
            let count = min(a.count, b.count)
            var difference = [Double](repeating: 0, count: count)
            for i in 0..<count { difference[i] = a[i] - b[i] }
            residual.append(difference)
        }

        let cleanStd = EEGGenerator.pooledStandardDeviation(clean)
        let residualStd = EEGGenerator.pooledStandardDeviation(residual)

        var bandScores: [BandScore] = []
        for band in bands {
            var cleanPower = 0.0
            var residualPower = 0.0
            var correctedPower = 0.0
            for channel in clean.indices {
                cleanPower += bandPower(
                    clean[channel], samplingRate: samplingRate,
                    lowHz: band.low, highHz: band.high, segmentLength: segmentLength
                )
                residualPower += bandPower(
                    residual[channel], samplingRate: samplingRate,
                    lowHz: band.low, highHz: band.high, segmentLength: segmentLength
                )
                correctedPower += bandPower(
                    corrected[channel], samplingRate: samplingRate,
                    lowHz: band.low, highHz: band.high, segmentLength: segmentLength
                )
            }
            let channelCount = Double(max(1, clean.count))
            cleanPower /= channelCount
            residualPower /= channelCount
            correctedPower /= channelCount

            bandScores.append(BandScore(
                name: band.name,
                lowHz: band.low,
                highHz: band.high,
                snr: residualPower > 0 ? (cleanPower / residualPower).squareRoot() : .infinity,
                powerRatioDb: cleanPower > 0 ? 10 * log10(max(correctedPower, 1e-30) / cleanPower) : 0,
                cleanRMS: cleanPower.squareRoot(),
                residualRMS: residualPower.squareRoot()
            ))
        }

        return CorrectionScore(
            label: label,
            broadbandSNR: residualStd > 0 ? cleanStd / residualStd : .infinity,
            cleanStandardDeviation: cleanStd,
            residualStandardDeviation: residualStd,
            bands: bandScores
        )
    }

    /// Mean-square power of `x` within a band, from a Welch periodogram.
    ///
    /// Welch rather than one transform of the whole recording: the segments
    /// average away the variance of a single periodogram, and a Hann window
    /// keeps the enormous low-frequency content of an uncorrected recording from
    /// leaking into the high bands and making a broken correction look fine up
    /// at 60 Hz.
    static func bandPower(
        _ x: [Double],
        samplingRate: Double,
        lowHz: Double,
        highHz: Double,
        segmentLength: Int
    ) -> Double {
        let n = min(SpectralNoise.nextPowerOfTwo(segmentLength), SpectralNoise.nextPowerOfTwo(max(x.count, 2)))
        guard x.count >= n, n >= 8 else { return 0 }

        var window = [Double](repeating: 0, count: n)
        var windowPower = 0.0
        for i in 0..<n {
            window[i] = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n - 1)))
            windowPower += window[i] * window[i]
        }
        windowPower /= Double(n)

        let hop = n / 2
        let binHz = samplingRate / Double(n)
        let firstBin = max(0, Int(ceil(lowHz / binHz)))
        let lastBin = min(n / 2, Int(floor(highHz / binHz)))
        guard lastBin >= firstBin else { return 0 }

        var total = 0.0
        var segments = 0
        var start = 0
        while start + n <= x.count {
            var re = [Double](repeating: 0, count: n)
            var im = [Double](repeating: 0, count: n)
            var mean = 0.0
            for i in 0..<n { mean += x[start + i] }
            mean /= Double(n)
            for i in 0..<n { re[i] = (x[start + i] - mean) * window[i] }

            DSP.fft(re: &re, im: &im, inverse: false)

            var power = 0.0
            for k in firstBin...lastBin {
                let magnitude = re[k] * re[k] + im[k] * im[k]
                // Every bin but DC and Nyquist has a mirror in the upper half.
                let weight = (k == 0 || k == n / 2) ? 1.0 : 2.0
                power += weight * magnitude
            }
            // Parseval, undone for the window's own power loss.
            total += power / (Double(n) * Double(n) * windowPower)
            segments += 1
            start += hop
        }

        guard segments > 0 else { return 0 }
        return total / Double(segments)
    }
}
