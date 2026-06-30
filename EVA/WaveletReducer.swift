//
//  WaveletReducer.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Wavelet-based artifact REDUCTION engine (distinct from the wavelet channel-
//  health "burden" scorer, which uses a fast a-trous approximation). This engine
//  implements real, perfect-reconstruction wavelet transforms — a decimated DWT
//  and a shift-invariant (undecimated) SWT — so that the artifact estimate it
//  subtracts is a faithful wavelet reconstruction, in the spirit of HAPPE's
//  wavelet-thresholded artifact rejection (Gabard-Durnam et al., 2018).
//
//  HAPPE parity notes:
//    * HAPPE's modern continuous path calls MATLAB `wdenoise` (decimated DWT,
//      bior4.4, level-dependent BayesShrink, hard threshold) and SUBTRACTS the
//      denoised reconstruction as the artifact estimate. This engine mirrors that
//      method: threshold the detail coefficients, reconstruct, subtract.
//    * Families here are orthonormal (coif4 — HAPPE's ERP family; sym4/db4 for
//      continuous). True biorthogonal bior4.4 (HAPPE's continuous default) is a
//      planned addition; the method/parameters are otherwise the same.
//

import Foundation

// MARK: - Configuration

nonisolated enum WaveletTransformKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case dwt = "DWT"
    case swt = "SWT"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .dwt:
            return "Decimated discrete wavelet transform — what HAPPE's wdenoise uses. Compact and fast."
        case .swt:
            return "Undecimated (stationary) wavelet transform — shift-invariant, cleaner for visualizing what was removed."
        }
    }
}

nonisolated enum WaveletReductionFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    case coif4 = "coif4"
    case sym4 = "sym4"
    case db4 = "db4"

    var id: String { rawValue }

    /// Orthonormal scaling (decomposition low-pass) filter coefficients.
    var scalingFilter: [Double] {
        switch self {
        case .coif4: return WaveletFilters.coif4
        case .sym4: return WaveletFilters.sym4
        case .db4: return WaveletFilters.db4
        }
    }

    var explanation: String {
        switch self {
        case .coif4:
            return "Coiflet-4 — HAPPE's ERP family. Near-symmetric, good time-frequency balance."
        case .sym4:
            return "Symlet-4 — near-symmetric Daubechies variant, a solid default for continuous EEG."
        case .db4:
            return "Daubechies-4 — compact support, classic choice for transient artifacts."
        }
    }
}

/// HAPPE has two wavelet forms: continuous (EEG) and task/event (ERP). The mode
/// selects sensible defaults (family, levels, threshold rule) and, for ERP,
/// whether quality is assessed on the band-limited signal.
nonisolated enum WaveletReductionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case continuousEEG = "Continuous EEG"
    case erp = "Task / ERP"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .continuousEEG:
            return "HAPPE's continuous path: hard thresholding, more aggressive. Operates on the whole recording. (HAPPE uses bior4.4; EVA uses sym4 as an orthonormal stand-in.)"
        case .erp:
            return "HAPPE's task/ERP path: coif4 with gentler soft thresholding and an extra level, and quality assessed within the ERP analysis band."
        }
    }

    /// Whether reduction quality (variance retained, correlation) is assessed on
    /// the band-limited signal, as HAPPE does for ERP analyses.
    var assessesInBand: Bool { self == .erp }

    func defaultConfiguration(samplingRate: Double) -> WaveletReductionConfiguration {
        switch self {
        case .continuousEEG:
            let levels = samplingRate > 500 ? 10 : (samplingRate > 250 ? 9 : 8)
            return WaveletReductionConfiguration(
                kind: .dwt, family: .sym4, levelCount: levels,
                thresholdRule: .hard, thresholdModel: .bayesShrink, thresholdScale: 1,
                downsampleFactor: 1
            )
        case .erp:
            // ERP analysis bands are low, so the heavy wavelet pass can run on a
            // decimated copy (~250 Hz) for a large speed-up at no analysis cost.
            let factor = WaveletReductionConfiguration.factor(forSourceRate: samplingRate, targetRate: 250)
            let effectiveRate = samplingRate / Double(factor)
            let levels = effectiveRate > 500 ? 11 : (effectiveRate > 250 ? 10 : 9)
            return WaveletReductionConfiguration(
                kind: .dwt, family: .coif4, levelCount: levels,
                thresholdRule: .soft, thresholdModel: .bayesShrink, thresholdScale: 1,
                downsampleFactor: factor
            )
        }
    }
}

nonisolated struct WaveletReductionConfiguration: Sendable {
    var kind: WaveletTransformKind = .dwt
    var family: WaveletReductionFamily = .coif4
    var levelCount: Int = 8
    var thresholdRule: WaveletCleaningThresholdRule = .hard
    var thresholdModel: WaveletCleaningThresholdModel = .bayesShrink
    /// Multiplies the computed coefficient threshold. >1 removes more, <1 less.
    var thresholdScale: Double = 1
    /// Decimation factor for the wavelet pass. 1 = full rate. Larger factors run
    /// the (expensive) transform on a downsampled copy and upsample the removed
    /// artifact back to full rate before subtracting.
    var downsampleFactor: Int = 1

    /// Factor that brings `sourceRate` down to ~`targetRate` (1 if already lower).
    static func factor(forSourceRate sourceRate: Double, targetRate: Double) -> Int {
        guard sourceRate > targetRate else { return 1 }
        return Downsampler.factor(sourceRate: sourceRate, targetRate: targetRate)
    }
}

// MARK: - Results

nonisolated struct WaveletChannelReductionMetrics: Identifiable, Sendable {
    var channelIndex: Int
    var varianceRetainedPercent: Double
    var correlation: Double
    var removedRMSMicrovolts: Double
    var peakReductionPercent: Double
    /// Fraction of each detail level's energy classified as artifact (finest
    /// level first). Useful for "which scale/band was cleaned" teaching views.
    var removedEnergyByLevel: [Double]

    var id: Int { channelIndex }
}

nonisolated struct WaveletReductionResult: Sendable {
    /// Cleaned signal (original minus the wavelet artifact estimate).
    var cleaned: MFFSignalData
    /// The removed artifact estimate, same shape as the input.
    var artifact: MFFSignalData
    var perChannel: [Int: WaveletChannelReductionMetrics]
    /// Global variance retained = var(cleaned)/var(original) over reduced channels.
    var varianceRetainedPercent: Double
    var meanCorrelation: Double
}

/// A window where the reduction removed the most energy — used to let the user
/// zoom in and see (original / removed / cleaned) what changed.
nonisolated struct WaveletReductionCandidate: Identifiable, Sendable {
    var id: String
    var rank: Int
    var channelIndex: Int
    var startSample: Int
    var endSample: Int
    var peakSample: Int
    var startTimeSeconds: Double
    var peakTimeSeconds: Double
    var removedRMSMicrovolts: Double
    var peakRemovedMicrovolts: Double

    var durationSeconds: Double { Double(endSample - startSample) }
}

// MARK: - Engine

nonisolated enum WaveletReducer {
    static let maximumLevelCount = 12

    /// Default worker count: half the usable cores, at least one.
    static var defaultCoreCount: Int {
        max(evaMaxWorkers / 2, 1)
    }

    static var maximumCoreCount: Int {
        evaMaxWorkers
    }

    /// Reduces the requested channels and returns the cleaned signal, the removed
    /// artifact, and per-channel + global quality metrics. Channels are processed
    /// concurrently across up to `coreCount` workers.
    static func reduce(
        signal: MFFSignalData,
        channelIndices: [Int],
        configuration: WaveletReductionConfiguration,
        coreCount: Int = defaultCoreCount,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> WaveletReductionResult {
        let indices = channelIndices.filter { signal.data.indices.contains($0) }
        var cleanedData = signal.data
        var artifactData = signal.data.map { [Float](repeating: 0, count: $0.count) }
        var perChannel: [Int: WaveletChannelReductionMetrics] = [:]

        var globalOriginalVariance = 0.0
        var globalCleanedVariance = 0.0
        var correlationSum = 0.0
        var correlationCount = 0

        let total = max(indices.count, 1)
        let workerCount = min(max(coreCount, 1), max(indices.count, 1))

        // Process one channel; returns everything the aggregation step needs.
        func process(_ channelIndex: Int) -> (
            cleaned: [Float], artifact: [Float],
            metrics: WaveletChannelReductionMetrics,
            originalVariance: Double, cleanedVariance: Double, correlation: Double
        ) {
            let original = signal.data[channelIndex].map(Double.init)
            let (cleaned, artifact, levelEnergies) = reduceChannel(original, configuration: configuration)
            let originalVariance = variance(original)
            let cleanedVariance = variance(cleaned)
            let corr = correlation(original, cleaned)
            let metrics = WaveletChannelReductionMetrics(
                channelIndex: channelIndex,
                varianceRetainedPercent: originalVariance > 1e-12 ? cleanedVariance / originalVariance * 100 : 100,
                correlation: corr,
                removedRMSMicrovolts: rms(artifact),
                peakReductionPercent: peakReductionPercent(original: original, cleaned: cleaned),
                removedEnergyByLevel: levelEnergies
            )
            return (cleaned.map(Float.init), artifact.map(Float.init), metrics, originalVariance, cleanedVariance, corr)
        }

        func store(_ channelIndex: Int, _ result: (cleaned: [Float], artifact: [Float], metrics: WaveletChannelReductionMetrics, originalVariance: Double, cleanedVariance: Double, correlation: Double)) {
            cleanedData[channelIndex] = result.cleaned
            artifactData[channelIndex] = result.artifact
            perChannel[channelIndex] = result.metrics
            globalOriginalVariance += result.originalVariance
            globalCleanedVariance += result.cleanedVariance
            correlationSum += result.correlation
            correlationCount += 1
        }

        if workerCount <= 1 {
            var completed = 0
            for channelIndex in indices {
                store(channelIndex, process(channelIndex))
                completed += 1
                progress?(Double(completed) / Double(total))
            }
        } else {
            let lock = NSLock()
            var completed = 0
            evaConcurrentPerform(iterations: workerCount) { worker in
                var offset = worker
                while offset < indices.count {
                    let channelIndex = indices[offset]
                    let result = process(channelIndex)
                    lock.lock()
                    store(channelIndex, result)
                    completed += 1
                    let done = completed
                    lock.unlock()
                    progress?(Double(done) / Double(total))
                    offset += workerCount
                }
            }
        }

        return WaveletReductionResult(
            cleaned: signal.replacingData(cleanedData, signalTypeSuffix: "Wavelet Reduced"),
            artifact: signal.replacingData(artifactData, signalTypeSuffix: "Wavelet Artifact"),
            perChannel: perChannel,
            varianceRetainedPercent: globalOriginalVariance > 1e-12
                ? globalCleanedVariance / globalOriginalVariance * 100
                : 100,
            meanCorrelation: correlationCount > 0 ? correlationSum / Double(correlationCount) : 1
        )
    }

    /// Reduces a single channel. Returns (cleaned, artifact, per-level removed
    /// energy fraction). `cleaned = original - artifact`. When the configuration
    /// requests downsampling, the transform runs on a decimated copy and the
    /// removed artifact is upsampled back to full rate before subtracting.
    static func reduceChannel(
        _ samples: [Double],
        configuration: WaveletReductionConfiguration
    ) -> (cleaned: [Double], artifact: [Double], removedEnergyByLevel: [Double]) {
        let count = samples.count
        guard count > 4 else {
            return (samples, [Double](repeating: 0, count: count), [])
        }

        let factor = max(configuration.downsampleFactor, 1)
        if factor > 1, count > factor * 8 {
            let decimated = Downsampler.blockAveraged(samples, by: factor)
            let core = coreReduceChannel(decimated, configuration: configuration)
            let artifact = Downsampler.linearUpsample(core.artifact, toLength: count, factor: factor)
            var cleaned = [Double](repeating: 0, count: count)
            for index in 0..<count {
                cleaned[index] = samples[index] - artifact[index]
            }
            return (cleaned, artifact, core.removedEnergyByLevel)
        }

        return coreReduceChannel(samples, configuration: configuration)
    }

    /// The wavelet decompose → threshold → reconstruct-artifact → subtract core,
    /// run at the sampling rate of the provided samples.
    private static func coreReduceChannel(
        _ samples: [Double],
        configuration: WaveletReductionConfiguration
    ) -> (cleaned: [Double], artifact: [Double], removedEnergyByLevel: [Double]) {
        let count = samples.count
        guard count > 4 else {
            return (samples, [Double](repeating: 0, count: count), [])
        }

        let bank = WaveletFilterBank.orthonormal(configuration.family.scalingFilter)
        let levels = boundedLevelCount(configuration.levelCount, sampleCount: count)
        guard levels >= 1 else {
            return (samples, [Double](repeating: 0, count: count), [])
        }

        let transform = WaveletTransform(bank: bank)
        let decomposition: WaveletDecomposition
        switch configuration.kind {
        case .dwt: decomposition = transform.forwardDWT(samples, levels: levels)
        case .swt: decomposition = transform.forwardSWT(samples, levels: levels)
        }

        var artifactDetails = decomposition.details
        var removedEnergyByLevel = [Double](repeating: 0, count: decomposition.details.count)
        for level in decomposition.details.indices {
            let detail = decomposition.details[level]
            let threshold = coefficientThreshold(
                for: detail,
                model: configuration.thresholdModel
            ) * max(configuration.thresholdScale, 0.01)
            var kept = [Double](repeating: 0, count: detail.count)
            var totalEnergy = 0.0
            var keptEnergy = 0.0
            for index in detail.indices {
                let value = detail[index]
                totalEnergy += value * value
                let thresholded = applyThreshold(value, threshold: threshold, rule: configuration.thresholdRule)
                kept[index] = thresholded
                keptEnergy += thresholded * thresholded
            }
            artifactDetails[level] = kept
            removedEnergyByLevel[level] = totalEnergy > 1e-12 ? keptEnergy / totalEnergy : 0
        }

        // Artifact estimate = reconstruction of the thresholded (large) detail
        // coefficients plus the approximation band — exactly HAPPE's subtracted
        // "wdenoise" output. Cleaned = original - artifact.
        let artifactDecomposition = WaveletDecomposition(
            approx: decomposition.approx,
            details: artifactDetails,
            originalLength: decomposition.originalLength
        )
        let artifact: [Double]
        switch configuration.kind {
        case .dwt: artifact = transform.inverseDWT(artifactDecomposition)
        case .swt: artifact = transform.inverseSWT(artifactDecomposition)
        }

        var cleaned = [Double](repeating: 0, count: count)
        for index in 0..<count {
            cleaned[index] = samples[index] - (index < artifact.count ? artifact[index] : 0)
        }
        return (cleaned, Array(artifact.prefix(count)), removedEnergyByLevel)
    }

    /// Finds the windows where the most artifact energy was removed, ranked, so
    /// the UI can offer "jump to the biggest changes." One candidate per channel
    /// (its strongest removed-artifact peak), then ranked across channels.
    static func findCandidates(
        artifact: MFFSignalData,
        channelIndices: [Int],
        maxCount: Int,
        windowSeconds: Double = 1.0
    ) -> [WaveletReductionCandidate] {
        let samplingRate = max(artifact.samplingRate, 1)
        let windowSamples = max(Int((windowSeconds * samplingRate).rounded()), 8)
        let half = windowSamples / 2

        struct Peak { let channel: Int; let sample: Int; let value: Double; let rms: Double }
        var peaks: [Peak] = []
        for channelIndex in channelIndices where artifact.data.indices.contains(channelIndex) {
            let channel = artifact.data[channelIndex]
            guard channel.count > 4 else { continue }
            var peakSample = 0
            var peakValue = 0.0
            for index in channel.indices {
                let magnitude = abs(Double(channel[index]))
                if magnitude > peakValue {
                    peakValue = magnitude
                    peakSample = index
                }
            }
            guard peakValue > 1e-9 else { continue }
            let start = max(peakSample - half, 0)
            let end = min(start + windowSamples, channel.count)
            var energy = 0.0
            for index in start..<end { energy += Double(channel[index]) * Double(channel[index]) }
            let rms = (energy / Double(max(end - start, 1))).squareRoot()
            peaks.append(Peak(channel: channelIndex, sample: peakSample, value: peakValue, rms: rms))
        }

        let ranked = peaks.sorted { $0.rms > $1.rms }.prefix(max(maxCount, 1))
        return ranked.enumerated().map { offset, peak in
            let start = max(peak.sample - half, 0)
            let end = min(start + windowSamples, artifact.data[peak.channel].count)
            return WaveletReductionCandidate(
                id: "wavelet-reduction-\(peak.channel)-\(peak.sample)",
                rank: offset + 1,
                channelIndex: peak.channel,
                startSample: start,
                endSample: end,
                peakSample: peak.sample,
                startTimeSeconds: Double(start) / samplingRate,
                peakTimeSeconds: Double(peak.sample) / samplingRate,
                removedRMSMicrovolts: peak.rms,
                peakRemovedMicrovolts: peak.value
            )
        }
    }

    static func boundedLevelCount(_ requested: Int, sampleCount: Int) -> Int {
        let maxBySamples = max(Int(floor(log2(Double(max(sampleCount, 2))))) - 1, 1)
        return min(max(requested, 1), maximumLevelCount, maxBySamples)
    }

    // MARK: Thresholding

    private static func applyThreshold(
        _ value: Double,
        threshold: Double,
        rule: WaveletCleaningThresholdRule
    ) -> Double {
        guard abs(value) >= threshold else { return 0 }
        switch rule {
        case .hard:
            return value
        case .soft:
            return value < 0 ? value + threshold : value - threshold
        }
    }

    private static func coefficientThreshold(
        for values: [Double],
        model: WaveletCleaningThresholdModel
    ) -> Double {
        guard values.count > 2 else { return 0 }
        let sigma = robustSigma(values)
        let universal = sigma > 1e-12
            ? sigma * sqrt(2 * log(Double(max(values.count, 2))))
            : 0

        guard model == .bayesShrink, sigma > 1e-12 else { return universal }

        let observedVariance = variance(values)
        let noiseVariance = sigma * sigma
        let signalVariance = max(observedVariance - noiseVariance, 0)
        guard signalVariance > 1e-12 else { return universal }
        let bayes = noiseVariance / sqrt(signalVariance)
        guard bayes.isFinite, bayes > 0 else { return universal }
        return min(universal, max(bayes, sigma * 0.25))
    }

    private static func robustSigma(_ values: [Double]) -> Double {
        let absValues = values.map(abs).sorted()
        guard !absValues.isEmpty else { return 0 }
        return percentile(absValues, fraction: 0.5) / 0.6745
    }

    // MARK: Small math

    private static func variance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    private static func rms(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(0.0) { $0 + $1 * $1 }
        return (sum / Double(values.count)).squareRoot()
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 1 else { return 1 }
        let lhsMean = lhs.prefix(count).reduce(0, +) / Double(count)
        let rhsMean = rhs.prefix(count).reduce(0, +) / Double(count)
        var numerator = 0.0, lhsEnergy = 0.0, rhsEnergy = 0.0
        for index in 0..<count {
            let l = lhs[index] - lhsMean
            let r = rhs[index] - rhsMean
            numerator += l * r
            lhsEnergy += l * l
            rhsEnergy += r * r
        }
        let denominator = (lhsEnergy * rhsEnergy).squareRoot()
        return denominator > 1e-12 ? numerator / denominator : 1
    }

    private static func peakReductionPercent(original: [Double], cleaned: [Double]) -> Double {
        let originalPeak = original.map(abs).max() ?? 0
        let cleanedPeak = cleaned.map(abs).max() ?? 0
        return originalPeak > 1e-9 ? max(originalPeak - cleanedPeak, 0) / originalPeak * 100 : 0
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let position = min(max(fraction, 0), 1) * Double(sortedValues.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sortedValues.count - 1)
        let weight = position - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }
}

// MARK: - Filter bank

nonisolated struct WaveletFilterBank: Sendable {
    let decompositionLowPass: [Double]
    let decompositionHighPass: [Double]
    let reconstructionLowPass: [Double]
    let reconstructionHighPass: [Double]
    var length: Int { decompositionLowPass.count }

    /// Builds an orthonormal analysis/synthesis bank from a scaling filter using
    /// the quadrature-mirror relations. For our (2i+k) periodic convolution
    /// convention the synthesis filters equal the analysis filters (the adjoint),
    /// which yields perfect reconstruction because the analysis rows are
    /// orthonormal.
    static func orthonormal(_ scaling: [Double]) -> WaveletFilterBank {
        let length = scaling.count
        var high = [Double](repeating: 0, count: length)
        for k in 0..<length {
            high[k] = (k % 2 == 0 ? 1.0 : -1.0) * scaling[length - 1 - k]
        }
        return WaveletFilterBank(
            decompositionLowPass: scaling,
            decompositionHighPass: high,
            reconstructionLowPass: scaling,
            reconstructionHighPass: high
        )
    }
}

// MARK: - Transform

nonisolated struct WaveletDecomposition: Sendable {
    var approx: [Double]
    /// Detail coefficients, finest level first.
    var details: [[Double]]
    var originalLength: Int
}

nonisolated struct WaveletTransform: Sendable {
    let bank: WaveletFilterBank

    // DWT (decimated) ----------------------------------------------------------

    func forwardDWT(_ samples: [Double], levels: Int) -> WaveletDecomposition {
        let originalLength = samples.count
        let padded = padToMultiple(samples, of: 1 << levels)
        var approx = padded
        var details: [[Double]] = []
        details.reserveCapacity(levels)
        for _ in 0..<levels {
            let (a, d) = dwtStep(approx)
            details.append(d)
            approx = a
        }
        return WaveletDecomposition(approx: approx, details: details, originalLength: originalLength)
    }

    func inverseDWT(_ decomposition: WaveletDecomposition) -> [Double] {
        var approx = decomposition.approx
        for level in stride(from: decomposition.details.count - 1, through: 0, by: -1) {
            approx = idwtStep(approx, decomposition.details[level])
        }
        return Array(approx.prefix(decomposition.originalLength))
    }

    private func dwtStep(_ x: [Double]) -> (approx: [Double], detail: [Double]) {
        let n = x.count
        let half = n / 2
        let filterLength = bank.length
        var approx = [Double](repeating: 0, count: half)
        var detail = [Double](repeating: 0, count: half)
        for i in 0..<half {
            var sumLow = 0.0
            var sumHigh = 0.0
            for k in 0..<filterLength {
                let idx = ((2 * i + k) % n + n) % n
                let value = x[idx]
                sumLow += bank.decompositionLowPass[k] * value
                sumHigh += bank.decompositionHighPass[k] * value
            }
            approx[i] = sumLow
            detail[i] = sumHigh
        }
        return (approx, detail)
    }

    private func idwtStep(_ approx: [Double], _ detail: [Double]) -> [Double] {
        let half = approx.count
        let n = half * 2
        let filterLength = bank.length
        var y = [Double](repeating: 0, count: n)
        for i in 0..<half {
            let a = approx[i]
            let d = detail[i]
            for k in 0..<filterLength {
                let idx = ((2 * i + k) % n + n) % n
                y[idx] += bank.reconstructionLowPass[k] * a + bank.reconstructionHighPass[k] * d
            }
        }
        return y
    }

    // SWT (undecimated, a-trous) ----------------------------------------------

    func forwardSWT(_ samples: [Double], levels: Int) -> WaveletDecomposition {
        let n = samples.count
        var approx = samples
        var details: [[Double]] = []
        details.reserveCapacity(levels)
        for level in 0..<levels {
            let dilation = 1 << level
            let (a, d) = swtStep(approx, dilation: dilation)
            details.append(d)
            approx = a
        }
        return WaveletDecomposition(approx: approx, details: details, originalLength: n)
    }

    func inverseSWT(_ decomposition: WaveletDecomposition) -> [Double] {
        var approx = decomposition.approx
        for level in stride(from: decomposition.details.count - 1, through: 0, by: -1) {
            let dilation = 1 << level
            approx = iswtStep(approx, decomposition.details[level], dilation: dilation)
        }
        return Array(approx.prefix(decomposition.originalLength))
    }

    private func swtStep(_ x: [Double], dilation: Int) -> (approx: [Double], detail: [Double]) {
        let n = x.count
        let filterLength = bank.length
        var approx = [Double](repeating: 0, count: n)
        var detail = [Double](repeating: 0, count: n)
        for index in 0..<n {
            var sumLow = 0.0
            var sumHigh = 0.0
            for k in 0..<filterLength {
                let idx = ((index + k * dilation) % n + n) % n
                let value = x[idx]
                sumLow += bank.decompositionLowPass[k] * value
                sumHigh += bank.decompositionHighPass[k] * value
            }
            approx[index] = sumLow
            detail[index] = sumHigh
        }
        return (approx, detail)
    }

    private func iswtStep(_ approx: [Double], _ detail: [Double], dilation: Int) -> [Double] {
        let n = approx.count
        let filterLength = bank.length
        var y = [Double](repeating: 0, count: n)
        for index in 0..<n {
            let a = approx[index]
            let d = detail[index]
            for k in 0..<filterLength {
                let idx = ((index + k * dilation) % n + n) % n
                y[idx] += 0.5 * (bank.reconstructionLowPass[k] * a + bank.reconstructionHighPass[k] * d)
            }
        }
        return y
    }

    private func padToMultiple(_ samples: [Double], of multiple: Int) -> [Double] {
        guard multiple > 1 else { return samples }
        let remainder = samples.count % multiple
        guard remainder != 0 else { return samples }
        let padCount = multiple - remainder
        guard let last = samples.last else { return samples }
        // Reflective padding keeps boundaries smooth.
        var padded = samples
        padded.reserveCapacity(samples.count + padCount)
        for offset in 0..<padCount {
            let mirrorIndex = samples.count - 2 - offset
            padded.append(mirrorIndex >= 0 ? samples[mirrorIndex] : last)
        }
        return padded
    }
}

// MARK: - Filter coefficients (PyWavelets, orthonormal scaling filters)

private nonisolated enum WaveletFilters {
    static let db4: [Double] = [
        -0.010597401784997278, 0.032883011666982945, 0.030841381835986965,
        -0.18703481171888114, -0.02798376941698385, 0.6308807679295904,
        0.7148465705525415, 0.23037781330885523
    ]

    static let sym4: [Double] = [
        -0.07576571478927333, -0.02963552764599851, 0.49761866763201545,
        0.8037387518059161, 0.29785779560527736, -0.09921954357684722,
        -0.012603967262037833, 0.032223100604042702
    ]

    static let coif4: [Double] = [
        -1.7849850030882614e-06, -3.2596802368833675e-06, 3.1229875865345646e-05,
        6.233903446100713e-05, -0.0002599745524877931, -0.0005890207562443383,
        0.0012665619292989445, 0.003751436157278457, -0.00565828668661072,
        -0.015211731527946259, 0.025082261844864097, 0.03933442712333749,
        -0.09622044203398798, -0.06662747426342619, 0.4343860564914685,
        0.7822389309206135, 0.41530840703043026, -0.05607731331675481,
        -0.08126669968087875, 0.026682300156053072, 0.016068943964776348,
        -0.0073461663276420935, -0.0016294920126017326, 0.0008923136685823146
    ]
}
