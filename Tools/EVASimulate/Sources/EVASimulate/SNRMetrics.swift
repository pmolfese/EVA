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
    /// Zero-lag correlation of the clean and corrected band-limited signals.
    var correlation: Double
    /// RMS dB error between corrected and clean Welch spectra inside the band.
    var spectralDistortionDbRMS: Double
}

nonisolated struct ChannelScore: Codable, Sendable {
    var name: String
    var snr: Double
    var rmseMicrovolts: Double
    var correlation: Double
    var cleanStandardDeviation: Double
    var residualStandardDeviation: Double
    var spectralDistortionDbRMS: Double
    var bands: [BandScore]
}

nonisolated struct CorrectionScore: Codable, Sendable {
    var label: String
    /// The paper's Equation 2, over the whole band and all channels.
    var broadbandSNR: Double
    var cleanStandardDeviation: Double
    var residualStandardDeviation: Double
    /// Absolute error, including any DC bias that standard deviation omits.
    var broadbandRMSEMicrovolts: Double
    var broadbandCorrelation: Double
    var spectralDistortionDbRMS: Double
    var bands: [BandScore]
    var channels: [ChannelScore]
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
        channelNames: [String]? = nil,
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

        let spectra = clean.indices.map {
            pairedSpectrum(clean[$0], corrected[$0], samplingRate: samplingRate,
                           segmentLength: segmentLength)
        }
        var channelBands = [[BandScore]](repeating: [], count: clean.count)
        var bandScores: [BandScore] = []
        for band in bands {
            for channel in spectra.indices {
                channelBands[channel].append(makeBandScore(
                    name: band.name, low: band.low, high: band.high,
                    spectra: [spectra[channel]]
                ))
            }
            bandScores.append(makeBandScore(
                name: band.name, low: band.low, high: band.high, spectra: spectra
            ))
        }

        let resolvedNames = channelNames?.count == clean.count
            ? channelNames!
            : clean.indices.map { "E\($0 + 1)" }
        let channels = clean.indices.map { index -> ChannelScore in
            let channelResidual = residual[index]
            let channelCleanStd = standardDeviation(clean[index])
            let channelResidualStd = standardDeviation(channelResidual)
            return ChannelScore(
                name: resolvedNames[index],
                snr: channelResidualStd > 0 ? channelCleanStd / channelResidualStd : .infinity,
                rmseMicrovolts: rmse(clean[index], corrected[index]),
                correlation: pearson(clean[index], corrected[index]),
                cleanStandardDeviation: channelCleanStd,
                residualStandardDeviation: channelResidualStd,
                spectralDistortionDbRMS: spectralDistortion(
                    spectra: [spectra[index]], low: 0,
                    high: min(70, samplingRate / 2)
                ),
                bands: channelBands[index]
            )
        }

        return CorrectionScore(
            label: label,
            broadbandSNR: residualStd > 0 ? cleanStd / residualStd : .infinity,
            cleanStandardDeviation: cleanStd,
            residualStandardDeviation: residualStd,
            broadbandRMSEMicrovolts: pooledRMSE(clean, corrected),
            broadbandCorrelation: pooledCorrelation(clean, corrected),
            spectralDistortionDbRMS: spectralDistortion(
                spectra: spectra, low: 0, high: min(70, samplingRate / 2)
            ),
            bands: bandScores,
            channels: channels
        )
    }

    private struct PairedSpectrum {
        var binHz: Double
        var clean: [Double]
        var corrected: [Double]
        var residual: [Double]
        var cross: [Double]
    }

    private static func makeBandScore(
        name: String, low: Double, high: Double, spectra: [PairedSpectrum]
    ) -> BandScore {
        guard let first = spectra.first else {
            return BandScore(name: name, lowHz: low, highHz: high, snr: 0,
                             powerRatioDb: 0, cleanRMS: 0, residualRMS: 0,
                             correlation: 0, spectralDistortionDbRMS: 0)
        }
        let firstBin = max(0, Int(ceil(low / first.binHz)))
        let lastBin = min(first.clean.count - 1, Int(floor(high / first.binHz)))
        guard lastBin >= firstBin else {
            return BandScore(name: name, lowHz: low, highHz: high, snr: 0,
                             powerRatioDb: 0, cleanRMS: 0, residualRMS: 0,
                             correlation: 0, spectralDistortionDbRMS: 0)
        }
        var cleanPower = 0.0
        var correctedPower = 0.0
        var residualPower = 0.0
        var crossPower = 0.0
        for spectrum in spectra {
            for bin in firstBin...lastBin {
                cleanPower += spectrum.clean[bin]
                correctedPower += spectrum.corrected[bin]
                residualPower += spectrum.residual[bin]
                crossPower += spectrum.cross[bin]
            }
        }
        let divisor = Double(max(1, spectra.count))
        cleanPower /= divisor
        correctedPower /= divisor
        residualPower /= divisor
        crossPower /= divisor
        let denominator = (cleanPower * correctedPower).squareRoot()
        return BandScore(
            name: name, lowHz: low, highHz: high,
            snr: residualPower > 0 ? (cleanPower / residualPower).squareRoot() : .infinity,
            powerRatioDb: cleanPower > 0
                ? 10 * log10(max(correctedPower, 1e-30) / cleanPower) : 0,
            cleanRMS: cleanPower.squareRoot(),
            residualRMS: residualPower.squareRoot(),
            correlation: denominator > 1e-30 ? crossPower / denominator : 0,
            spectralDistortionDbRMS: spectralDistortion(
                spectra: spectra, low: low, high: high
            )
        )
    }

    private static func pairedSpectrum(
        _ clean: [Double], _ corrected: [Double], samplingRate: Double,
        segmentLength: Int
    ) -> PairedSpectrum {
        let count = min(clean.count, corrected.count)
        let n = welchLength(sampleCount: count, requested: segmentLength)
        let bins = max(1, n / 2 + 1)
        var result = PairedSpectrum(
            binHz: samplingRate / Double(n), clean: [Double](repeating: 0, count: bins),
            corrected: [Double](repeating: 0, count: bins),
            residual: [Double](repeating: 0, count: bins),
            cross: [Double](repeating: 0, count: bins)
        )
        guard count >= n, n >= 8 else { return result }
        var window = [Double](repeating: 0, count: n)
        var windowPower = 0.0
        for i in 0..<n {
            window[i] = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n - 1)))
            windowPower += window[i] * window[i]
        }
        windowPower /= Double(n)
        let scale = Double(n) * Double(n) * windowPower
        var segments = 0
        var start = 0
        while start + n <= count {
            let cleanMean = clean[start..<(start + n)].reduce(0, +) / Double(n)
            let correctedMean = corrected[start..<(start + n)].reduce(0, +) / Double(n)
            var xr = [Double](repeating: 0, count: n)
            var xi = [Double](repeating: 0, count: n)
            var yr = [Double](repeating: 0, count: n)
            var yi = [Double](repeating: 0, count: n)
            for i in 0..<n {
                xr[i] = (clean[start + i] - cleanMean) * window[i]
                yr[i] = (corrected[start + i] - correctedMean) * window[i]
            }
            DSP.fft(re: &xr, im: &xi, inverse: false)
            DSP.fft(re: &yr, im: &yi, inverse: false)
            for bin in 0..<bins {
                let weight = (bin == 0 || bin == n / 2) ? 1.0 : 2.0
                let px = weight * (xr[bin] * xr[bin] + xi[bin] * xi[bin]) / scale
                let py = weight * (yr[bin] * yr[bin] + yi[bin] * yi[bin]) / scale
                let cross = weight * (xr[bin] * yr[bin] + xi[bin] * yi[bin]) / scale
                result.clean[bin] += px
                result.corrected[bin] += py
                result.residual[bin] += max(0, px + py - 2 * cross)
                result.cross[bin] += cross
            }
            segments += 1
            start += n / 2
        }
        if segments > 0 {
            for bin in 0..<bins {
                result.clean[bin] /= Double(segments)
                result.corrected[bin] /= Double(segments)
                result.residual[bin] /= Double(segments)
                result.cross[bin] /= Double(segments)
            }
        }
        return result
    }

    private static func spectralDistortion(
        spectra: [PairedSpectrum], low: Double, high: Double
    ) -> Double {
        guard let first = spectra.first else { return 0 }
        let firstBin = max(0, Int(ceil(low / first.binHz)))
        let lastBin = min(first.clean.count - 1, Int(floor(high / first.binHz)))
        guard lastBin >= firstBin else { return 0 }
        var cleanPSD = [Double](repeating: 0, count: lastBin - firstBin + 1)
        var correctedPSD = cleanPSD
        for spectrum in spectra {
            for bin in firstBin...lastBin {
                cleanPSD[bin - firstBin] += spectrum.clean[bin]
                correctedPSD[bin - firstBin] += spectrum.corrected[bin]
            }
        }
        // Use one global reference floor rather than a per-band floor. In a
        // notch/dropout band both spectra can be at floating-point dust; their
        // dB ratio is then numerically enormous but scientifically meaningless.
        let globalPeak = spectra.flatMap(\.clean).max() ?? 0
        let floorPower = max(globalPeak * 1e-10 * Double(max(1, spectra.count)), 1e-30)
        var squares = 0.0
        for index in cleanPSD.indices {
            let difference = 10 * log10(max(correctedPSD[index], floorPower)
                / max(cleanPSD[index], floorPower))
            squares += difference * difference
        }
        return (squares / Double(cleanPSD.count)).squareRoot()
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(values.count)).squareRoot()
    }

    private static func rmse(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }
        var squares = 0.0
        for index in 0..<count { squares += pow(lhs[index] - rhs[index], 2) }
        return (squares / Double(count)).squareRoot()
    }

    private static func pearson(_ lhs: [Double], _ rhs: [Double]) -> Double {
        DipoleEEGGenerator.pearson(lhs, rhs)
    }

    private static func pooledRMSE(_ lhs: [[Double]], _ rhs: [[Double]]) -> Double {
        var squares = 0.0
        var count = 0
        for channel in lhs.indices {
            let n = min(lhs[channel].count, rhs[channel].count)
            for index in 0..<n { squares += pow(lhs[channel][index] - rhs[channel][index], 2) }
            count += n
        }
        return count > 0 ? (squares / Double(count)).squareRoot() : 0
    }

    private static func pooledCorrelation(_ lhs: [[Double]], _ rhs: [[Double]]) -> Double {
        var numerator = 0.0
        var leftSquares = 0.0
        var rightSquares = 0.0
        for channel in lhs.indices {
            let count = min(lhs[channel].count, rhs[channel].count)
            guard count > 1 else { continue }
            let leftMean = lhs[channel].prefix(count).reduce(0, +) / Double(count)
            let rightMean = rhs[channel].prefix(count).reduce(0, +) / Double(count)
            for index in 0..<count {
                let left = lhs[channel][index] - leftMean
                let right = rhs[channel][index] - rightMean
                numerator += left * right
                leftSquares += left * left
                rightSquares += right * right
            }
        }
        let denominator = (leftSquares * rightSquares).squareRoot()
        return denominator > 1e-30 ? numerator / denominator : 0
    }

    private static func welchLength(sampleCount: Int, requested: Int) -> Int {
        let limit = min(sampleCount, max(8, requested))
        guard limit >= 8 else { return max(2, limit) }
        var length = 8
        while length <= limit / 2 { length *= 2 }
        return length
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
        let n = welchLength(sampleCount: x.count, requested: segmentLength)
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
