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
//  Wavelet-based artifact REDUCTION engine (distinct from the wavelet channel-
//  health "burden" scorer, which uses a fast a-trous approximation). This engine
//  implements real, perfect-reconstruction wavelet transforms — a decimated DWT
//  and a shift-invariant (undecimated) SWT — so that the artifact estimate it
//  subtracts is a faithful wavelet reconstruction, in the spirit of HAPPE's
//  wavelet-thresholded artifact rejection (Gabard-Durnam et al., 2018).
//
//  HAPPE parity notes:
//    * HAPPE's default path calls MATLAB `wdenoise` (decimated DWT; bior4.4
//      continuous / coif4 ERP; 'DenoisingMethod','Bayes' with level-dependent
//      noise) and SUBTRACTS the denoised reconstruction as the artifact
//      estimate. This engine mirrors that structure: threshold the detail
//      coefficients, reconstruct, subtract.
//    * MATLAB's 'Bayes' is the Johnstone–Silverman *empirical Bayes* method
//      (sparse mixture prior), NOT BayesShrink. In this subtract-the-kept-
//      coefficients paradigm the two adapt in opposite directions: empirical
//      Bayes keeps only sparse outliers (artifacts) above ~several sigma,
//      while BayesShrink's T = σ_n²/σ_s collapses on heavy-tailed,
//      artifact-inflated EEG bands — classifying nearly everything as
//      artifact and gutting the EEG. The empirical Bayes estimator is
//      implemented in `EmpiricalBayesThreshold` and is this engine's default
//      threshold model. The robust universal threshold (MAD σ · sqrt(2 ln N))
//      remains available; it is the upper bound empirical Bayes is fitted
//      under, and is what a band of pure noise fits to.
//    * Families include both orthonormal (coif4 — HAPPE's ERP family;
//      sym4/db4 alternatives) and true biorthogonal (bior4.4 — HAPPE's
//      continuous family — and bior6.8), the latter giving exact linear
//      phase, matching HAPPE's actual filters.
//
//  Reference implementation license: HAPPE is distributed under GPL-3.0. This
//  file is intended as an independently written Swift implementation of the
//  published wavelet-denoising structure and MATLAB `wdenoise` behavior, not a
//  translation of HAPPE source; see docs/copyleft-provenance-plan.md.
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
    case bior44 = "bior4.4"
    case bior68 = "bior6.8"

    var id: String { rawValue }

    /// The analysis/synthesis filter bank for this family. `coif4`/`sym4`/`db4`
    /// are orthonormal (one filter generates the rest via QMF relations, and
    /// reconstruction reuses the decomposition filters). `bior4.4`/`bior6.8` are
    /// true biorthogonal spline wavelets — HAPPE's actual continuous (bior6.8,
    /// with bior4.4 the earlier HAPPE default) and this is what gives them exact
    /// linear phase (no time-shift distortion from thresholding), unlike the
    /// near-symmetric-but-not-exact orthonormal families.
    var filterBank: WaveletFilterBank {
        switch self {
        case .coif4: return .orthonormal(WaveletFilters.coif4)
        case .sym4: return .orthonormal(WaveletFilters.sym4)
        case .db4: return .orthonormal(WaveletFilters.db4)
        case .bior44:
            return .biorthogonal(
                decompositionLowPass: WaveletFilters.bior44DecompositionLowPass,
                decompositionHighPass: WaveletFilters.bior44DecompositionHighPass,
                reconstructionLowPass: WaveletFilters.bior44ReconstructionLowPass,
                reconstructionHighPass: WaveletFilters.bior44ReconstructionHighPass
            )
        case .bior68:
            return .biorthogonal(
                decompositionLowPass: WaveletFilters.bior68DecompositionLowPass,
                decompositionHighPass: WaveletFilters.bior68DecompositionHighPass,
                reconstructionLowPass: WaveletFilters.bior68ReconstructionLowPass,
                reconstructionHighPass: WaveletFilters.bior68ReconstructionHighPass
            )
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
        case .bior44:
            return "Biorthogonal 4.4 — HAPPE's continuous-path family (happe_wavThresh). True linear phase (exactly symmetric), unlike the orthonormal families above."
        case .bior68:
            return "Biorthogonal 6.8 — longer support than bior4.4, also exactly linear phase."
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
            return "HAPPE's continuous path: bior4.4, hard thresholding, whole recording. Only coefficients above the robust per-level threshold are treated as artifact and subtracted."
        case .erp:
            return "HAPPE's task/ERP path: coif4 with soft thresholding and an extra level, run at the full sampling rate, with quality assessed within the ERP analysis band."
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
                kind: .dwt, family: .bior44, levelCount: levels,
                thresholdRule: .hard, thresholdModel: .empiricalBayes, thresholdScale: 1,
                downsampleFactor: 1,
                useGPU: WaveletMetalBackend.isAvailable
            )
        case .erp:
            // Full rate, like HAPPE. (An earlier default decimated to ~250 Hz,
            // but block-averaging down and linearly upsampling the artifact
            // estimate distorts exactly the sharp transients being removed;
            // the Downsample picker remains for users who opt in.)
            let levels = samplingRate > 500 ? 11 : (samplingRate > 250 ? 10 : 9)
            return WaveletReductionConfiguration(
                kind: .dwt, family: .coif4, levelCount: levels,
                thresholdRule: .soft, thresholdModel: .empiricalBayes, thresholdScale: 1,
                downsampleFactor: 1,
                useGPU: WaveletMetalBackend.isAvailable
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
    /// Multiplies the computed coefficient threshold — the gate a coefficient
    /// must exceed to be classified as artifact and subtracted. >1 raises the
    /// gate (fewer coefficients removed, gentler); <1 lowers it (more removed,
    /// more aggressive).
    var thresholdScale: Double = 1
    /// Decimation factor for the wavelet pass. 1 = full rate. Larger factors run
    /// the (expensive) transform on a downsampled copy and upsample the removed
    /// artifact back to full rate before subtracting.
    var downsampleFactor: Int = 1
    /// Remove each channel's linear trend before the transform, folding it into
    /// the artifact estimate afterward. HAPPE's approximation band swallows
    /// drift anyway, so this is parity-neutral — but doing it explicitly keeps
    /// the transform's periodic boundary from reading a start↔end offset as a
    /// large spurious seam artifact (same rationale as the Explorer's
    /// `detrendedForTransform`).
    var detrend: Bool = true
    /// 0 = one global threshold per level over the whole recording (HAPPE
    /// parity: wdenoise's level-dependent estimate is a single statistic per
    /// level). > 0 re-estimates each level's threshold in overlapping windows
    /// of this many seconds, so a quiet stretch and a noisy stretch each get
    /// their own noise floor — the Explorer's proven local-threshold scheme.
    var thresholdWindowSeconds: Double = 0
    /// Run the decompose → threshold → reconstruct chain on the GPU
    /// (`WaveletMetalBackend`), batching channels into shared dispatches. The
    /// GPU computes in Float where the CPU uses Double, so results agree
    /// closely but not bitwise. Falls back to the CPU automatically when Metal
    /// is unavailable or an encode fails.
    var useGPU: Bool = false
    /// How many of the FINEST detail levels are excluded from artifact
    /// extraction. Level *j* covers roughly `[rate/2^(j+1), rate/2^j]`, so on
    /// data already low-passed well below Nyquist the first few levels sit
    /// entirely in the filter's stopband. Those bands hold nothing but
    /// roll-off residue, which drives their robust sigma (and therefore their
    /// threshold) toward zero and makes essentially all of that residue read
    /// as "artifact". Excluded levels contribute no artifact at all, so their
    /// content passes through into the cleaned signal untouched.
    var skippedFineLevels: Int = 0
    /// Restrict the reduction to `[start, end]` seconds. `nil` on either side
    /// means "from the beginning" / "to the end". Samples outside the span are
    /// left exactly as they came in (artifact = 0 there), and every metric and
    /// candidate is computed only within it — which is how a contaminated
    /// stretch (a filter transient at the tail, say) is kept from dominating
    /// the thresholds' population, the variance-retained figure, and the
    /// candidate ranking.
    var analysisStartSeconds: Double?
    var analysisEndSeconds: Double?

    /// Factor that brings `sourceRate` down to ~`targetRate` (1 if already lower).
    static func factor(forSourceRate sourceRate: Double, targetRate: Double) -> Int {
        guard sourceRate > targetRate else { return 1 }
        return Downsampler.factor(sourceRate: sourceRate, targetRate: targetRate)
    }

    /// The sample span this configuration analyzes, clamped into the
    /// recording. Returns nil if the requested span is too short to transform.
    func analysisRange(sampleCount: Int, samplingRate: Double) -> Range<Int>? {
        guard sampleCount > 0 else { return nil }
        guard analysisStartSeconds != nil || analysisEndSeconds != nil else { return 0..<sampleCount }
        guard samplingRate > 0 else { return 0..<sampleCount }
        let rawStart = analysisStartSeconds.map { Int(($0 * samplingRate).rounded()) } ?? 0
        let rawEnd = analysisEndSeconds.map { Int(($0 * samplingRate).rounded()) } ?? sampleCount
        let start = min(max(rawStart, 0), sampleCount)
        let end = min(max(rawEnd, start), sampleCount)
        guard end - start > 4 else { return nil }
        return start..<end
    }

    /// How many of the finest detail levels lie entirely above `highCutoff`
    /// (the data's low-pass edge) and so contain no signal. Level *j*'s band
    /// starts at `rate/2^(j+1)`; the level is pure stopband once that lower
    /// edge is already at or above the cutoff.
    ///
    /// At 1000 Hz with a 30 Hz low-pass this returns 4: levels 1–4 span
    /// 31–500 Hz, entirely inside the stopband, while level 5 (15.6–31.25 Hz)
    /// straddles the cutoff and still carries signal.
    static func stopbandLevelCount(samplingRate: Double, highCutoff: Double) -> Int {
        guard samplingRate > 0, highCutoff > 0, highCutoff < samplingRate / 2 else { return 0 }
        let count = Int(floor(log2(samplingRate / highCutoff))) - 1
        return max(count, 0)
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
    /// artifact, and per-channel + global quality metrics. With `useGPU` on and
    /// a Metal device available, the decompose → threshold → reconstruct chain
    /// runs on-device in channel batches; otherwise channels are processed
    /// concurrently across up to `coreCount` CPU workers. A GPU encode failure
    /// falls back to the CPU path transparently.
    static func reduce(
        signal: MFFSignalData,
        channelIndices: [Int],
        configuration: WaveletReductionConfiguration,
        coreCount: Int = defaultCoreCount,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> WaveletReductionResult {
        if configuration.useGPU, let backend = WaveletMetalBackend.shared,
           let result = reduceOnGPU(
               signal: signal,
               channelIndices: channelIndices,
               configuration: configuration,
               backend: backend,
               progress: progress
           ) {
            return result
        }
        let indices = channelIndices.filter { signal.data.indices.contains($0) }
        nonisolated(unsafe) var cleanedData = signal.data
        nonisolated(unsafe) var artifactData = signal.data.map { [Float](repeating: 0, count: $0.count) }
        nonisolated(unsafe) var perChannel: [Int: WaveletChannelReductionMetrics] = [:]

        nonisolated(unsafe) var globalOriginalVariance = 0.0
        nonisolated(unsafe) var globalCleanedVariance = 0.0
        nonisolated(unsafe) var correlationSum = 0.0
        nonisolated(unsafe) var correlationCount = 0

        let total = max(indices.count, 1)
        let workerCount = min(max(coreCount, 1), max(indices.count, 1))

        // Process one channel; returns everything the aggregation step needs.
        // Only `analysisRange` is transformed — samples outside it are passed
        // through untouched, and every metric is scoped to the analyzed span so
        // an excluded stretch can't skew the numbers the user reads.
        @Sendable func process(_ channelIndex: Int) -> (
            cleaned: [Float], artifact: [Float],
            metrics: WaveletChannelReductionMetrics,
            originalVariance: Double, cleanedVariance: Double, correlation: Double
        ) {
            let original = signal.data[channelIndex].map(Double.init)
            let untouched = WaveletChannelReductionMetrics(
                channelIndex: channelIndex, varianceRetainedPercent: 100, correlation: 1,
                removedRMSMicrovolts: 0, peakReductionPercent: 0, removedEnergyByLevel: []
            )
            guard let range = configuration.analysisRange(
                sampleCount: original.count, samplingRate: signal.samplingRate
            ) else {
                return (signal.data[channelIndex], [Float](repeating: 0, count: original.count), untouched, 0, 0, 1)
            }

            let segment = Array(original[range])
            let (cleanedSegment, artifactSegment, levelEnergies) = reduceChannel(
                segment, configuration: configuration, samplingRate: signal.samplingRate)

            var cleaned = original
            var artifact = [Double](repeating: 0, count: original.count)
            for offset in 0..<segment.count {
                cleaned[range.lowerBound + offset] = cleanedSegment[offset]
                artifact[range.lowerBound + offset] = artifactSegment[offset]
            }

            let originalVariance = variance(segment)
            let cleanedVariance = variance(cleanedSegment)
            let corr = correlation(segment, cleanedSegment)
            let metrics = WaveletChannelReductionMetrics(
                channelIndex: channelIndex,
                varianceRetainedPercent: originalVariance > 1e-12 ? cleanedVariance / originalVariance * 100 : 100,
                correlation: corr,
                removedRMSMicrovolts: rms(artifactSegment),
                peakReductionPercent: peakReductionPercent(original: segment, cleaned: cleanedSegment),
                removedEnergyByLevel: levelEnergies
            )
            return (cleaned.map(Float.init), artifact.map(Float.init), metrics, originalVariance, cleanedVariance, corr)
        }

        @Sendable func store(_ channelIndex: Int, _ result: (cleaned: [Float], artifact: [Float], metrics: WaveletChannelReductionMetrics, originalVariance: Double, cleanedVariance: Double, correlation: Double)) {
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
                guard !Task.isCancelled else { break }
                store(channelIndex, process(channelIndex))
                completed += 1
                progress?(Double(completed) / Double(total))
            }
        } else {
            let lock = NSLock()
            nonisolated(unsafe) var completed = 0
            evaConcurrentPerform(iterations: workerCount) { worker in
                var offset = worker
                while offset < indices.count {
                    guard !Task.isCancelled else { return }
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
    /// `samplingRate` enables the windowed-threshold option
    /// (`thresholdWindowSeconds`); callers without a rate (short event windows)
    /// can omit it and get the global per-level threshold.
    static func reduceChannel(
        _ samples: [Double],
        configuration: WaveletReductionConfiguration,
        samplingRate: Double = 0
    ) -> (cleaned: [Double], artifact: [Double], removedEnergyByLevel: [Double]) {
        let count = samples.count
        guard count > 4 else {
            return (samples, [Double](repeating: 0, count: count), [])
        }

        let factor = max(configuration.downsampleFactor, 1)
        if factor > 1, count > factor * 8 {
            let decimated = Downsampler.blockAveraged(samples, by: factor)
            let core = coreReduceChannel(
                decimated, configuration: configuration,
                samplingRate: samplingRate / Double(factor))
            let artifact = Downsampler.linearUpsample(core.artifact, toLength: count, factor: factor)
            var cleaned = [Double](repeating: 0, count: count)
            for index in 0..<count {
                cleaned[index] = samples[index] - artifact[index]
            }
            return (cleaned, artifact, core.removedEnergyByLevel)
        }

        return coreReduceChannel(samples, configuration: configuration, samplingRate: samplingRate)
    }

    /// The wavelet decompose → threshold → reconstruct-artifact → subtract core,
    /// run at the sampling rate of the provided samples.
    private static func coreReduceChannel(
        _ samples: [Double],
        configuration: WaveletReductionConfiguration,
        samplingRate: Double
    ) -> (cleaned: [Double], artifact: [Double], removedEnergyByLevel: [Double]) {
        let count = samples.count
        guard count > 4 else {
            return (samples, [Double](repeating: 0, count: count), [])
        }

        let bank = configuration.family.filterBank
        let levels = boundedLevelCount(configuration.levelCount, sampleCount: count)
        guard levels >= 1 else {
            return (samples, [Double](repeating: 0, count: count), [])
        }

        // Detrend first (see `WaveletReductionConfiguration.detrend`): the
        // trend is added back into the artifact estimate below, so the cleaned
        // output is identical to what a drift-swallowing approximation band
        // would have produced — minus the boundary seam.
        var work = samples
        var slope = 0.0
        var intercept = 0.0
        if configuration.detrend {
            (slope, intercept) = linearTrend(samples)
            if slope != 0 || intercept != 0 {
                for index in 0..<count {
                    work[index] -= intercept + slope * Double(index)
                }
            }
        }

        // Reflect-pad both ends by the deepest level's tap reach so the
        // transform's periodic wrap splices mirrored (continuous) data instead
        // of the raw start↔end seam. The artifact is cropped back to the
        // original span after reconstruction.
        let margin = min((bank.length - 1) * (1 << levels), max(count - 1, 0))
        let padded = margin > 0 ? reflectPadded(work, margin: margin) : work

        let transform = WaveletTransform(bank: bank)
        let decomposition: WaveletDecomposition
        switch configuration.kind {
        case .dwt: decomposition = transform.forwardDWT(padded, levels: levels)
        case .swt: decomposition = transform.forwardSWT(padded, levels: levels)
        }

        var artifactDetails = decomposition.details
        var removedEnergyByLevel = [Double](repeating: 0, count: decomposition.details.count)
        let scale = max(configuration.thresholdScale, 0.01)
        let skipped = min(max(configuration.skippedFineLevels, 0), decomposition.details.count)
        for level in decomposition.details.indices {
            // Stopband levels contribute nothing to the artifact — see
            // `skippedFineLevels`. Zeroing the band here (rather than never
            // computing it) keeps the cascade intact: each level still feeds
            // the next one's approximation.
            guard level >= skipped else {
                artifactDetails[level] = [Double](repeating: 0, count: decomposition.details[level].count)
                removedEnergyByLevel[level] = 0
                continue
            }
            let detail = decomposition.details[level]
            // Detail bands are decimated per level under the DWT, so a
            // wall-clock threshold window covers fewer coefficients there.
            let bandRate = configuration.kind == .dwt
                ? samplingRate / Double(1 << (level + 1))
                : samplingRate
            let localThresholds = windowedCoefficientThresholds(
                for: detail,
                model: configuration.thresholdModel,
                windowSeconds: configuration.thresholdWindowSeconds,
                bandRate: bandRate
            )
            let globalThreshold = localThresholds == nil
                ? coefficientThreshold(for: detail, model: configuration.thresholdModel)
                : 0
            var kept = [Double](repeating: 0, count: detail.count)
            var totalEnergy = 0.0
            var keptEnergy = 0.0
            for index in detail.indices {
                let value = detail[index]
                totalEnergy += value * value
                let threshold = (localThresholds?[index] ?? globalThreshold) * scale
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
        let reconstructed: [Double]
        switch configuration.kind {
        case .dwt: reconstructed = transform.inverseDWT(artifactDecomposition)
        case .swt: reconstructed = transform.inverseSWT(artifactDecomposition)
        }

        var artifact = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let paddedIndex = index + margin
            artifact[index] = paddedIndex < reconstructed.count ? reconstructed[paddedIndex] : 0
            if configuration.detrend {
                artifact[index] += intercept + slope * Double(index)
            }
        }
        var cleaned = [Double](repeating: 0, count: count)
        for index in 0..<count {
            cleaned[index] = samples[index] - artifact[index]
        }
        return (cleaned, artifact, removedEnergyByLevel)
    }

    /// Least-squares (slope, intercept) of a channel, mirroring the Explorer's
    /// `removeLinearTrend` but returning the fit so the trend can be folded
    /// into the artifact estimate.
    private static func linearTrend(_ samples: [Double]) -> (slope: Double, intercept: Double) {
        let n = samples.count
        guard n > 2 else { return (0, 0) }
        let xMean = Double(n - 1) / 2
        let yMean = samples.reduce(0, +) / Double(n)
        var numerator = 0.0
        var denominator = 0.0
        for index in samples.indices {
            let dx = Double(index) - xMean
            numerator += dx * (samples[index] - yMean)
            denominator += dx * dx
        }
        guard denominator > 1e-9 else { return (0, 0) }
        let slope = numerator / denominator
        return (slope, yMean - slope * xMean)
    }

    /// Mirrors `samples` outward by `margin` on both ends (edge sample not
    /// repeated), so filter taps near a boundary see locally continuous data
    /// instead of the circular start↔end splice. `margin` must be < count.
    private static func reflectPadded(_ samples: [Double], margin: Int) -> [Double] {
        let n = samples.count
        var out = [Double]()
        out.reserveCapacity(n + 2 * margin)
        for index in stride(from: margin, through: 1, by: -1) {
            out.append(samples[min(index, n - 1)])
        }
        out.append(contentsOf: samples)
        for index in 0..<margin {
            out.append(samples[max(n - 2 - index, 0)])
        }
        return out
    }

    /// Per-coefficient thresholds re-estimated in overlapping (50%-stride)
    /// wall-clock windows and linearly interpolated between window centers —
    /// the Explorer's local-threshold scheme, on this engine's Double bands.
    /// Returns nil when windowing is off, the band rate is unknown, or the
    /// band is too short for more than one window (global threshold applies).
    private static func windowedCoefficientThresholds(
        for detail: [Double],
        model: WaveletCleaningThresholdModel,
        windowSeconds: Double,
        bandRate: Double
    ) -> [Double]? {
        guard windowSeconds > 0, bandRate > 0 else { return nil }
        let windowSamples = max(Int((windowSeconds * bandRate).rounded()), 64)
        let n = detail.count
        guard n > windowSamples else { return nil }

        let stride = max(windowSamples / 2, 1)
        var centers: [Int] = []
        var centerValues: [Double] = []
        var start = 0
        while start < n {
            let end = min(start + windowSamples, n)
            centers.append((start + end - 1) / 2)
            centerValues.append(coefficientThreshold(for: Array(detail[start..<end]), model: model))
            if end == n { break }
            start += stride
        }
        guard centerValues.count > 1 else { return nil }

        var curve = [Double](repeating: centerValues[0], count: n)
        var upper = 1
        for index in 0..<n {
            if index <= centers[0] { continue }
            if index >= centers[centers.count - 1] { curve[index] = centerValues[centerValues.count - 1]; continue }
            while centers[upper] < index { upper += 1 }
            let lower = upper - 1
            let span = Double(centers[upper] - centers[lower])
            let weight = span > 0 ? Double(index - centers[lower]) / span : 0
            curve[index] = centerValues[lower] * (1 - weight) + centerValues[upper] * weight
        }
        return curve
    }

    // MARK: - GPU path

    /// GPU form of the per-channel pipeline: identical prep (decimate, detrend,
    /// reflect-pad) and post (crop, re-trend, upsample, metrics) on the host,
    /// with the transform, thresholding, and reconstruction batched on-device
    /// via `WaveletMetalBackend`. Only the robust threshold statistics stay on
    /// the CPU (they need medians), computed from strided subsamples of the
    /// resident bands — the same split as the Explorer's Metal path. Returns
    /// nil on any encode failure so `reduce` falls back to the CPU.
    private static func reduceOnGPU(
        signal: MFFSignalData,
        channelIndices: [Int],
        configuration: WaveletReductionConfiguration,
        backend: WaveletMetalBackend,
        progress: (@Sendable (Double) -> Void)?
    ) -> WaveletReductionResult? {
        let indices = channelIndices.filter { signal.data.indices.contains($0) }
        var cleanedData = signal.data
        var artifactData = signal.data.map { [Float](repeating: 0, count: $0.count) }
        var perChannel: [Int: WaveletChannelReductionMetrics] = [:]
        var globalOriginalVariance = 0.0
        var globalCleanedVariance = 0.0
        var correlationSum = 0.0
        var correlationCount = 0

        func assembled() -> WaveletReductionResult {
            WaveletReductionResult(
                cleaned: signal.replacingData(cleanedData, signalTypeSuffix: "Wavelet Reduced"),
                artifact: signal.replacingData(artifactData, signalTypeSuffix: "Wavelet Artifact"),
                perChannel: perChannel,
                varianceRetainedPercent: globalOriginalVariance > 1e-12
                    ? globalCleanedVariance / globalOriginalVariance * 100
                    : 100,
                meanCorrelation: correlationCount > 0 ? correlationSum / Double(correlationCount) : 1
            )
        }

        guard let firstIndex = indices.first else { return assembled() }
        let sampleCount = signal.data[firstIndex].count
        // Batching shares one geometry, so ragged channels go to the CPU path.
        guard sampleCount > 4, indices.allSatisfy({ signal.data[$0].count == sampleCount }) else { return nil }

        // One analysis span shared by the whole batch; everything below works
        // in segment coordinates and writes back at `range.lowerBound`.
        guard let range = configuration.analysisRange(
            sampleCount: sampleCount, samplingRate: signal.samplingRate
        ) else { return nil }
        let segmentCount = range.count

        let factor = max(configuration.downsampleFactor, 1)
        let decimates = factor > 1 && segmentCount > factor * 8
        let workCount = decimates ? (segmentCount + factor - 1) / factor : segmentCount
        let effectiveRate = signal.samplingRate / Double(decimates ? factor : 1)

        let bank = configuration.family.filterBank
        let levels = boundedLevelCount(configuration.levelCount, sampleCount: workCount)
        guard levels >= 1 else { return nil }

        let margin = min((bank.length - 1) * (1 << levels), max(workCount - 1, 0))
        var paddedLength = workCount + 2 * margin
        if configuration.kind == .dwt {
            let multiple = 1 << levels
            paddedLength = (paddedLength + multiple - 1) / multiple * multiple
        }

        let decompositionLow = bank.decompositionLowPass.map(Float.init)
        let decompositionHigh = bank.decompositionHighPass.map(Float.init)
        let reconstructionLow = bank.reconstructionLowPass.map(Float.init)
        let reconstructionHigh = bank.reconstructionHighPass.map(Float.init)

        let batchSize = min(
            backend.maximumReductionBatchChannels(
                paddedLength: paddedLength, levelCount: levels, kind: configuration.kind),
            max(indices.count, 1)
        )
        let batchCount = (indices.count + batchSize - 1) / batchSize

        for batchIndex in 0..<batchCount {
            guard !Task.isCancelled else { break }
            let batch = Array(indices[(batchIndex * batchSize)..<min((batchIndex + 1) * batchSize, indices.count)])
            let batchBase = Double(batchIndex) / Double(batchCount)
            let batchSpan = 1.0 / Double(batchCount)

            // Host prep: decimate, detrend, reflect-pad — Double math, exactly
            // as `coreReduceChannel`, converted to Float only for upload.
            var trends = [(slope: Double, intercept: Double)](repeating: (0, 0), count: batch.count)
            var paddedChannels = [[Float]](repeating: [], count: batch.count)
            for (slot, channelIndex) in batch.enumerated() {
                let segment = signal.data[channelIndex][range].map(Double.init)
                var work = decimates ? Downsampler.blockAveraged(segment, by: factor) : segment
                if configuration.detrend {
                    let trend = linearTrend(work)
                    trends[slot] = trend
                    if trend.slope != 0 || trend.intercept != 0 {
                        for index in 0..<work.count {
                            work[index] -= trend.intercept + trend.slope * Double(index)
                        }
                    }
                }
                var padded = margin > 0 ? reflectPadded(work, margin: margin) : work
                let baseLength = padded.count
                while padded.count < paddedLength {
                    // Same tail extension as `WaveletTransform.padToMultiple`:
                    // reflect off the end of the pre-extension array.
                    let offset = padded.count - baseLength
                    let mirrorIndex = baseLength - 2 - offset
                    padded.append(mirrorIndex >= 0 ? padded[mirrorIndex] : (padded.last ?? 0))
                }
                paddedChannels[slot] = padded.map(Float.init)
            }
            progress?(batchBase + batchSpan * 0.15)

            guard let bands = backend.reductionForward(
                channels: paddedChannels,
                kind: configuration.kind,
                levelCount: levels,
                decompositionLowPass: decompositionLow,
                decompositionHighPass: decompositionHigh
            ) else { return nil }
            progress?(batchBase + batchSpan * 0.45)

            // Robust thresholds from strided subsamples of the resident bands.
            var thresholdValues: [[Float]] = []
            var thresholdCenters: [[UInt32]] = []
            let skipped = min(max(configuration.skippedFineLevels, 0), levels)
            for level in 0..<levels {
                let bandLength = bands.bandLengths[level]
                // A stopband level contributes no artifact. An unreachable
                // gate expresses that with no kernel change: `shrink` zeroes
                // every coefficient below the threshold, and nothing clears
                // `greatestFiniteMagnitude` — so both the shrink and the
                // band-energy kernel see an entirely discarded band.
                guard level >= skipped else {
                    thresholdValues.append([Float](repeating: .greatestFiniteMagnitude, count: batch.count))
                    thresholdCenters.append([0])
                    continue
                }
                let bandRate = configuration.kind == .dwt
                    ? effectiveRate / Double(1 << (level + 1))
                    : effectiveRate
                let windowSamples = configuration.thresholdWindowSeconds > 0 && bandRate > 0
                    ? max(Int((configuration.thresholdWindowSeconds * bandRate).rounded()), 64)
                    : Int.max
                if windowSamples < bandLength {
                    // Same window layout as `windowedCoefficientThresholds`.
                    let stride = max(windowSamples / 2, 1)
                    var starts: [Int] = []
                    var centers: [UInt32] = []
                    var start = 0
                    while start < bandLength {
                        let end = min(start + windowSamples, bandLength)
                        starts.append(start)
                        centers.append(UInt32((start + end - 1) / 2))
                        if end == bandLength { break }
                        start += stride
                    }
                    var values = [Float](repeating: 0, count: batch.count * centers.count)
                    for slot in 0..<batch.count {
                        for windowIndex in starts.indices {
                            let windowStart = starts[windowIndex]
                            let windowEnd = min(windowStart + windowSamples, bandLength)
                            let sampleStride = max((windowEnd - windowStart) / 4096, 1)
                            let subsample = bands.detailSubsample(
                                level: level, channel: slot,
                                from: windowStart, to: windowEnd, stride: sampleStride
                            ).map(Double.init)
                            values[slot * centers.count + windowIndex] = Float(coefficientThreshold(
                                for: subsample,
                                model: configuration.thresholdModel,
                                populationCount: windowEnd - windowStart
                            ))
                        }
                    }
                    thresholdValues.append(values)
                    thresholdCenters.append(centers)
                } else {
                    let sampleStride = max(bandLength / 16384, 1)
                    var values = [Float](repeating: 0, count: batch.count)
                    for slot in 0..<batch.count {
                        let subsample = bands.detailSubsample(
                            level: level, channel: slot,
                            from: 0, to: bandLength, stride: sampleStride
                        ).map(Double.init)
                        values[slot] = Float(coefficientThreshold(
                            for: subsample,
                            model: configuration.thresholdModel,
                            populationCount: bandLength
                        ))
                    }
                    thresholdValues.append(values)
                    thresholdCenters.append([0])
                }
            }
            progress?(batchBase + batchSpan * 0.6)

            guard let finish = backend.reductionFinish(
                bands,
                thresholds: WaveletMetalBackend.ReductionThresholds(
                    values: thresholdValues, centers: thresholdCenters),
                thresholdScale: Float(max(configuration.thresholdScale, 0.01)),
                usesSoftThreshold: configuration.thresholdRule == .soft,
                reconstructionLowPass: reconstructionLow,
                reconstructionHighPass: reconstructionHigh,
                reconstructionShift: bank.reconstructionShift
            ) else { return nil }
            progress?(batchBase + batchSpan * 0.85)

            // Host post: crop the margin, restore the trend into the artifact,
            // upsample if decimated, subtract, and score.
            for (slot, channelIndex) in batch.enumerated() {
                let padded = finish.artifact[slot]
                var artifactWork = [Double](repeating: 0, count: workCount)
                let trend = trends[slot]
                for index in 0..<workCount {
                    let paddedIndex = index + margin
                    artifactWork[index] = paddedIndex < padded.count ? Double(padded[paddedIndex]) : 0
                    if configuration.detrend {
                        artifactWork[index] += trend.intercept + trend.slope * Double(index)
                    }
                }
                let artifactSegment = decimates
                    ? Downsampler.linearUpsample(artifactWork, toLength: segmentCount, factor: factor)
                    : artifactWork

                // Back to full-channel coordinates: only `range` changes.
                let original = signal.data[channelIndex].map(Double.init)
                var cleaned = original
                var artifact = [Double](repeating: 0, count: sampleCount)
                var cleanedSegment = [Double](repeating: 0, count: segmentCount)
                let segment = Array(original[range])
                for offset in 0..<segmentCount {
                    let value = segment[offset] - artifactSegment[offset]
                    cleanedSegment[offset] = value
                    cleaned[range.lowerBound + offset] = value
                    artifact[range.lowerBound + offset] = artifactSegment[offset]
                }

                let originalVariance = variance(segment)
                let cleanedVariance = variance(cleanedSegment)
                let corr = correlation(segment, cleanedSegment)
                let energies = (0..<levels).map { level -> Double in
                    let total = finish.totalEnergyByLevel[slot][level]
                    return total > 1e-12 ? finish.keptEnergyByLevel[slot][level] / total : 0
                }
                perChannel[channelIndex] = WaveletChannelReductionMetrics(
                    channelIndex: channelIndex,
                    varianceRetainedPercent: originalVariance > 1e-12 ? cleanedVariance / originalVariance * 100 : 100,
                    correlation: corr,
                    removedRMSMicrovolts: rms(artifactSegment),
                    peakReductionPercent: peakReductionPercent(original: segment, cleaned: cleanedSegment),
                    removedEnergyByLevel: energies
                )
                cleanedData[channelIndex] = cleaned.map(Float.init)
                artifactData[channelIndex] = artifact.map(Float.init)
                globalOriginalVariance += originalVariance
                globalCleanedVariance += cleanedVariance
                correlationSum += corr
                correlationCount += 1
            }
            progress?(batchBase + batchSpan)
        }

        return assembled()
    }

    /// Finds the windows where the most artifact energy was removed, ranked, so
    /// the UI can offer "jump to the biggest changes."
    ///
    /// The list is of distinct *events*, not of channels. Each channel can
    /// contribute several peaks (non-max suppressed within `windowSeconds` of
    /// each other), and peaks that coincide in time across channels are then
    /// collapsed to the single strongest channel — because one blink or motion
    /// event appears on most of the net at once, and a per-channel list would
    /// spend every slot re-reporting whichever event happens to be largest.
    ///
    /// `sampleRange` scopes the search to the analyzed span, and
    /// `edgeMarginSamples` drops peaks hugging either end of it, where a filter
    /// or boundary transient in the input would otherwise outrank every real
    /// artifact in the recording.
    static func findCandidates(
        artifact: MFFSignalData,
        channelIndices: [Int],
        maxCount: Int,
        windowSeconds: Double = 1.0,
        sampleRange: Range<Int>? = nil,
        edgeMarginSamples: Int = 0,
        maxPerChannel: Int = 8
    ) -> [WaveletReductionCandidate] {
        let samplingRate = max(artifact.samplingRate, 1)
        let windowSamples = max(Int((windowSeconds * samplingRate).rounded()), 8)
        let half = windowSamples / 2
        let limit = max(maxCount, 1)

        struct Peak { let channel: Int; let sample: Int; let value: Double; let rms: Double }
        var peaks: [Peak] = []

        for channelIndex in channelIndices where artifact.data.indices.contains(channelIndex) {
            let channel = artifact.data[channelIndex]
            guard channel.count > 4 else { continue }
            let span = sampleRange.map { $0.clamped(to: 0..<channel.count) } ?? 0..<channel.count
            let searchStart = span.lowerBound + max(edgeMarginSamples, 0)
            let searchEnd = span.upperBound - max(edgeMarginSamples, 0)
            guard searchEnd - searchStart > 2 else { continue }

            // Bucket maxima first (one pass), then suppress within a window.
            // Repeatedly rescanning the channel for each peak would cost a full
            // sweep per peak per channel; a 128-channel net makes that the
            // dominant cost of the whole reduction.
            let bucketSize = max(half, 1)
            var bucketPeaks: [(sample: Int, value: Double)] = []
            bucketPeaks.reserveCapacity((searchEnd - searchStart) / bucketSize + 1)
            var bucketStart = searchStart
            while bucketStart < searchEnd {
                let bucketEnd = min(bucketStart + bucketSize, searchEnd)
                var bestSample = bucketStart
                var bestValue = 0.0
                for index in bucketStart..<bucketEnd {
                    let magnitude = abs(Double(channel[index]))
                    if magnitude > bestValue {
                        bestValue = magnitude
                        bestSample = index
                    }
                }
                if bestValue > 1e-9 { bucketPeaks.append((bestSample, bestValue)) }
                bucketStart = bucketEnd
            }

            var acceptedSamples: [Int] = []
            for candidate in bucketPeaks.sorted(by: { $0.value > $1.value }) {
                guard acceptedSamples.count < max(maxPerChannel, 1) else { break }
                guard !acceptedSamples.contains(where: { abs($0 - candidate.sample) < windowSamples }) else { continue }
                acceptedSamples.append(candidate.sample)

                let start = max(candidate.sample - half, span.lowerBound)
                let end = min(start + windowSamples, span.upperBound)
                var energy = 0.0
                for index in start..<end { energy += Double(channel[index]) * Double(channel[index]) }
                let rms = (energy / Double(max(end - start, 1))).squareRoot()
                peaks.append(Peak(channel: channelIndex, sample: candidate.sample, value: candidate.value, rms: rms))
            }
        }

        // Collapse across channels: strongest first, and skip anything that
        // overlaps an already-accepted event in time regardless of channel.
        var events: [Peak] = []
        for peak in peaks.sorted(by: { $0.rms > $1.rms }) {
            guard events.count < limit else { break }
            guard !events.contains(where: { abs($0.sample - peak.sample) < windowSamples }) else { continue }
            events.append(peak)
        }

        return events.enumerated().map { offset, peak in
            let channelCount = artifact.data[peak.channel].count
            let start = max(peak.sample - half, 0)
            let end = min(start + windowSamples, channelCount)
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

    /// Samples at each end of the analyzed span where a candidate would not be
    /// trustworthy, so none is reported there. Sized by the deepest level's tap
    /// reach — the span whose coefficients see the boundary at all — and capped
    /// at 5% of the analyzed length so a short span keeps a usable interior.
    /// Mirrors `WaveletArtifactAnalyzer.edgeMargin`; the reduction itself still
    /// runs over the whole span, this only governs what gets *reported*.
    static func candidateEdgeMargin(
        family: WaveletReductionFamily,
        levelCount: Int,
        sampleCount: Int
    ) -> Int {
        let bank = family.filterBank
        let levels = boundedLevelCount(levelCount, sampleCount: max(sampleCount, 2))
        let reach = (bank.length - 1) * (1 << levels)
        return min(reach, sampleCount / 20)
    }

    // MARK: Thresholding

    /// Soft/hard coefficient shrinkage. Shared with `WaveletDenoiser`.
    static func applyThreshold(
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

    /// `populationCount` is the full band/window size the statistic stands in
    /// for — the `N` in the universal threshold's `sqrt(2 ln N)`. The GPU path
    /// passes it because it estimates from a strided subsample of the resident
    /// band; without it a subsample would get a systematically lower gate.
    private static func coefficientThreshold(
        for values: [Double],
        model: WaveletCleaningThresholdModel,
        populationCount: Int? = nil
    ) -> Double {
        guard values.count > 2 else { return 0 }
        let sigma = robustSigma(values)
        let universal = sigma > 1e-12
            ? sigma * sqrt(2 * log(Double(max(populationCount ?? values.count, 2))))
            : 0

        if model == .empiricalBayes {
            // Returns 0 for a degenerate band, and also for the (in practice
            // vanishing) dense case where the fitted weight hits 1 — a gate of
            // 0 would subtract the whole band, so fall back to the universal
            // threshold, which is the estimator's own upper bound anyway.
            let gate = EmpiricalBayesThreshold.threshold(for: values, populationCount: populationCount)
            return gate > 0 ? gate : universal
        }

        guard model == .bayesShrink, sigma > 1e-12 else { return universal }

        let observedVariance = variance(values)
        let noiseVariance = sigma * sigma
        let signalVariance = max(observedVariance - noiseVariance, 0)
        guard signalVariance > 1e-12 else { return universal }
        let bayes = noiseVariance / sqrt(signalVariance)
        guard bayes.isFinite, bayes > 0 else { return universal }
        return min(universal, max(bayes, sigma * 0.25))
    }

    /// Robust noise σ estimate (MAD / 0.6745). Shared with `WaveletDenoiser`.
    static func robustSigma(_ values: [Double]) -> Double {
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
    /// Index offset applied when placing reconstruction-filter taps back into
    /// the upsampled signal. Zero for orthonormal banks, where all four filters
    /// share one length and the (2i+k) convention already lines up. Biorthogonal
    /// banks have differently-sized decomposition vs. reconstruction low-pass
    /// filters, so reconstruction needs `(decomposition length − reconstruction
    /// length) / 2` of alignment to keep perfect reconstruction (derived
    /// numerically against PyWavelets' bior4.4/bior6.8 filters — see
    /// `biorthogonal(...)` below); the high-pass branch takes the negated shift.
    let reconstructionShift: Int

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
            reconstructionHighPass: high,
            reconstructionShift: 0
        )
    }

    /// Builds a biorthogonal analysis/synthesis bank from four independently
    /// specified filters. Unlike the orthonormal case, decomposition and
    /// reconstruction use genuinely different filters (only dual to each other,
    /// not identical) — the mechanism that lets biorthogonal wavelets be exactly
    /// linear-phase (symmetric), which no non-trivial orthogonal wavelet can be.
    static func biorthogonal(
        decompositionLowPass: [Double],
        decompositionHighPass: [Double],
        reconstructionLowPass: [Double],
        reconstructionHighPass: [Double]
    ) -> WaveletFilterBank {
        WaveletFilterBank(
            decompositionLowPass: decompositionLowPass,
            decompositionHighPass: decompositionHighPass,
            reconstructionLowPass: reconstructionLowPass,
            reconstructionHighPass: reconstructionHighPass,
            reconstructionShift: (decompositionLowPass.count - reconstructionLowPass.count) / 2
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
        let lowLength = bank.decompositionLowPass.count
        let highLength = bank.decompositionHighPass.count
        var approx = [Double](repeating: 0, count: half)
        var detail = [Double](repeating: 0, count: half)
        for i in 0..<half {
            var sumLow = 0.0
            for k in 0..<lowLength {
                let idx = ((2 * i + k) % n + n) % n
                sumLow += bank.decompositionLowPass[k] * x[idx]
            }
            var sumHigh = 0.0
            for k in 0..<highLength {
                let idx = ((2 * i + k) % n + n) % n
                sumHigh += bank.decompositionHighPass[k] * x[idx]
            }
            approx[i] = sumLow
            detail[i] = sumHigh
        }
        return (approx, detail)
    }

    private func idwtStep(_ approx: [Double], _ detail: [Double]) -> [Double] {
        let half = approx.count
        let n = half * 2
        let lowLength = bank.reconstructionLowPass.count
        let highLength = bank.reconstructionHighPass.count
        let shift = bank.reconstructionShift
        var y = [Double](repeating: 0, count: n)
        for i in 0..<half {
            let a = approx[i]
            let d = detail[i]
            for k in 0..<lowLength {
                let idx = ((2 * i + k + shift) % n + n) % n
                y[idx] += bank.reconstructionLowPass[k] * a
            }
            for k in 0..<highLength {
                let idx = ((2 * i + k - shift) % n + n) % n
                y[idx] += bank.reconstructionHighPass[k] * d
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

    /// Split into a wrap-free interior and a wrapping tail. Only samples
    /// within one tap-reach of the end can wrap (`index + k*dilation` only
    /// ever grows), so the modulo — two integer divisions per tap per sample
    /// in the naive form, which dominated this loop at scan scale — is needed
    /// for just that tail. Each output element still accumulates its taps in
    /// the same order with the same operations, so results are bit-identical
    /// to the straightforward version; `inverseSWT`'s perfect reconstruction
    /// depends on that.
    private func swtStep(_ x: [Double], dilation: Int) -> (approx: [Double], detail: [Double]) {
        let n = x.count
        let lowLength = bank.decompositionLowPass.count
        let highLength = bank.decompositionHighPass.count
        var approx = [Double](repeating: 0, count: n)
        var detail = [Double](repeating: 0, count: n)

        let maxReach = max(lowLength - 1, highLength - 1) * dilation
        let interiorEnd = max(n - maxReach, 0)

        x.withUnsafeBufferPointer { xp in
            bank.decompositionLowPass.withUnsafeBufferPointer { lp in
                bank.decompositionHighPass.withUnsafeBufferPointer { hp in
                    approx.withUnsafeMutableBufferPointer { ap in
                        detail.withUnsafeMutableBufferPointer { dp in
                            for index in 0..<interiorEnd {
                                var sumLow = 0.0
                                for k in 0..<lowLength {
                                    sumLow += lp[k] * xp[index + k * dilation]
                                }
                                var sumHigh = 0.0
                                for k in 0..<highLength {
                                    sumHigh += hp[k] * xp[index + k * dilation]
                                }
                                ap[index] = sumLow
                                dp[index] = sumHigh
                            }
                            // `index` and `k * dilation` are both non-negative,
                            // so a single modulo already lands in range.
                            for index in interiorEnd..<n {
                                var sumLow = 0.0
                                for k in 0..<lowLength {
                                    sumLow += lp[k] * xp[(index + k * dilation) % n]
                                }
                                var sumHigh = 0.0
                                for k in 0..<highLength {
                                    sumHigh += hp[k] * xp[(index + k * dilation) % n]
                                }
                                ap[index] = sumLow
                                dp[index] = sumHigh
                            }
                        }
                    }
                }
            }
        }
        return (approx, detail)
    }

    private func iswtStep(_ approx: [Double], _ detail: [Double], dilation: Int) -> [Double] {
        let n = approx.count
        let lowLength = bank.reconstructionLowPass.count
        let highLength = bank.reconstructionHighPass.count
        // Shift scales with dilation here (unlike idwtStep) because à-trous taps
        // are already spaced by `dilation` samples apart.
        let shift = bank.reconstructionShift * dilation
        var y = [Double](repeating: 0, count: n)
        for index in 0..<n {
            let a = approx[index]
            let d = detail[index]
            for k in 0..<lowLength {
                let idx = ((index + k * dilation + shift) % n + n) % n
                y[idx] += 0.5 * bank.reconstructionLowPass[k] * a
            }
            for k in 0..<highLength {
                let idx = ((index + k * dilation - shift) % n + n) % n
                y[idx] += 0.5 * bank.reconstructionHighPass[k] * d
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

    // Biorthogonal spline wavelets (CDF construction; coefficients per
    // PyWavelets, which agrees with MATLAB's Wavelet Toolbox — both trace back
    // to the same published CDF filter tables). Decomposition and
    // reconstruction filters are genuinely different (and different lengths),
    // which is what makes these families exactly linear-phase.

    static let bior44DecompositionLowPass: [Double] = [
        0.03782845550726404, -0.023849465019556843, -0.11062440441843718,
        0.37740285561283066, 0.8526986790088938, 0.37740285561283066,
        -0.11062440441843718, -0.023849465019556843, 0.03782845550726404
    ]
    static let bior44DecompositionHighPass: [Double] = [
        -0.06453888262869706, 0.04068941760916406, 0.41809227322161724,
        -0.7884856164055829, 0.41809227322161724, 0.04068941760916406,
        -0.06453888262869706
    ]
    static let bior44ReconstructionLowPass: [Double] = [
        -0.06453888262869706, -0.04068941760916406, 0.41809227322161724,
        0.7884856164055829, 0.41809227322161724, -0.04068941760916406,
        -0.06453888262869706
    ]
    static let bior44ReconstructionHighPass: [Double] = [
        -0.03782845550726404, -0.023849465019556843, 0.11062440441843718,
        0.37740285561283066, -0.8526986790088938, 0.37740285561283066,
        0.11062440441843718, -0.023849465019556843, -0.03782845550726404
    ]

    static let bior68DecompositionLowPass: [Double] = [
        0.0019088317364812906, -0.0019142861290887667, -0.016990639867602342,
        0.01193456527972926, 0.04973290349094079, -0.07726317316720414,
        -0.09405920349573646, 0.4207962846098268, 0.8259229974584023,
        0.4207962846098268, -0.09405920349573646, -0.07726317316720414,
        0.04973290349094079, 0.01193456527972926, -0.016990639867602342,
        -0.0019142861290887667, 0.0019088317364812906
    ]
    static let bior68DecompositionHighPass: [Double] = [
        0.014426282505624435, -0.014467504896790148, -0.07872200106262882,
        0.04036797903033992, 0.41784910915027457, -0.7589077294536541,
        0.41784910915027457, 0.04036797903033992, -0.07872200106262882,
        -0.014467504896790148, 0.014426282505624435
    ]
    static let bior68ReconstructionLowPass: [Double] = [
        0.014426282505624435, 0.014467504896790148, -0.07872200106262882,
        -0.04036797903033992, 0.41784910915027457, 0.7589077294536541,
        0.41784910915027457, -0.04036797903033992, -0.07872200106262882,
        0.014467504896790148, 0.014426282505624435
    ]
    static let bior68ReconstructionHighPass: [Double] = [
        -0.0019088317364812906, -0.0019142861290887667, 0.016990639867602342,
        0.01193456527972926, -0.04973290349094079, -0.07726317316720414,
        0.09405920349573646, 0.4207962846098268, -0.8259229974584023,
        0.4207962846098268, 0.09405920349573646, -0.07726317316720414,
        -0.04973290349094079, 0.01193456527972926, 0.016990639867602342,
        -0.0019142861290887667, -0.0019088317364812906
    ]
}
