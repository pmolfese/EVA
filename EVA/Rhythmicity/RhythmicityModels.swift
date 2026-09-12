//
//  RhythmicityModels.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

nonisolated enum LAVIAmplitudeDistribution: String, Sendable, Codable, Equatable {
    /// Paper-described IAAFT: retain the finite observed sample distribution.
    case observedSamples
}

nonisolated enum IAAFTNonconvergencePolicy: String, Sendable, Codable, Equatable {
    /// Match the maintained toolbox: keep the final iterate and report it.
    case retainAndReport
}

nonisolated struct IAAFTConfiguration: Sendable, Codable, Equatable {
    var errorThreshold: Double
    var speedThreshold: Double
    var maximumIterations: Int

    static let paper2026 = IAAFTConfiguration(
        errorThreshold: 2e-4,
        speedThreshold: 1e-6,
        maximumIterations: 1_000
    )
}

nonisolated struct LAVIOnDemandSignificanceConfiguration: Sendable, Codable, Equatable {
    var repetitions: Int
    var seed: UInt64
    var alpha: Double
    var tailRule: LAVITailRule
    var aperiodicFitRangeHz: ClosedRange<Double>
    var excludedFitRangesHz: [ClosedRange<Double>]
    var amplitudeDistribution: LAVIAmplitudeDistribution
    var iaaft: IAAFTConfiguration
    var nonconvergencePolicy: IAAFTNonconvergencePolicy
}

nonisolated enum LAVISignificanceConfiguration: Sendable, Codable, Equatable {
    /// Return median-defined ABBA regions without inferential labels.
    case none
    /// Generate a recording-matched null distribution using IAAFT.
    case onDemand(LAVIOnDemandSignificanceConfiguration)
}

nonisolated enum RhythmicityEdgePolicy: String, Sendable, Codable, Equatable {
    /// Keep the zero-padded same-convolution samples. Primarily a diagnostic mode.
    case referenceSamePadding
    /// Require the complete wavelet to be immersed in the finite signal segment.
    case validOnly
}

nonisolated enum RhythmicityPrecision: String, Sendable, Codable, Equatable {
    case float32
    case float64
}

nonisolated enum RhythmicityComputeBackend: String, Sendable, Codable, Equatable {
    /// Prefer Metal for workloads above the measured crossover and otherwise
    /// use the bounded Accelerate FFT implementation.
    case automatic
    /// Scalar double-precision implementation used as the correctness oracle.
    case directReferenceCPU
    /// Bounded worker pool with tiled Accelerate FFT convolution.
    case accelerateFFTCPU
    /// Tiled single-frequency Float coefficient production on Metal.
    case metalGPU
}

nonisolated struct RhythmicityComputePolicy: Sendable, Codable, Equatable {
    /// Total backend allowance, including cached kernels and in-flight tiles.
    var memoryBudgetBytes: Int
    /// Zero selects EVA's global CPU cap; positive values impose a lower cap.
    var maximumWorkerCount: Int
    /// Requested uncontaminated overlap-save output length before FFT rounding.
    var preferredOutputTileSamples: Int

    static let productionDefault = RhythmicityComputePolicy(
        memoryBudgetBytes: 512 * 1_024 * 1_024,
        maximumWorkerCount: 0,
        preferredOutputTileSamples: 32_768
    )
}

nonisolated struct RhythmicityConfiguration: Sendable, Codable, Equatable {
    var presetID: String
    var frequenciesHz: [Double]
    var morletWidthCycles: Double
    var laviLagCycles: Double
    var wtplLagCycles: [Double]
    var alphaAnchorHz: ClosedRange<Double>
    var significance: LAVISignificanceConfiguration
    var edgePolicy: RhythmicityEdgePolicy
    var precision: RhythmicityPrecision
    var backend: RhythmicityComputeBackend
    var computePolicy: RhythmicityComputePolicy = .productionDefault
}

nonisolated struct RhythmicityChannelInput: Sendable, Equatable {
    var channelIndex: Int
    var channelName: String
    var samples: [Double]
    var isInterpolated: Bool

    init(
        channelIndex: Int,
        channelName: String,
        samples: [Double],
        isInterpolated: Bool = false
    ) {
        self.channelIndex = channelIndex
        self.channelName = channelName
        self.samples = samples
        self.isInterpolated = isInterpolated
    }
}

/// A logically continuous interval. Both sample bounds are inclusive.
nonisolated struct RhythmicitySegment: Sendable, Codable, Equatable {
    var startSample: Int
    var endSample: Int
    var label: String?
    var trialID: String?

    init(startSample: Int, endSample: Int, label: String? = nil, trialID: String? = nil) {
        self.startSample = startSample
        self.endSample = endSample
        self.label = label
        self.trialID = trialID
    }
}

nonisolated struct RhythmicitySourceDescriptor: Sendable, Codable, Equatable {
    var recordingIdentity: String
    var displayName: String

    init(recordingIdentity: String, displayName: String) {
        self.recordingIdentity = recordingIdentity
        self.displayName = displayName
    }
}

nonisolated struct RhythmicityProcessingProvenance: Sendable, Codable, Equatable {
    var sourceRevision: String
    var processingSummary: [String]

    init(sourceRevision: String, processingSummary: [String] = []) {
        self.sourceRevision = sourceRevision
        self.processingSummary = processingSummary
    }
}

nonisolated struct RhythmicityInput: Sendable, Equatable {
    var channels: [RhythmicityChannelInput]
    var samplingRate: Double
    var segments: [RhythmicitySegment]
    var source: RhythmicitySourceDescriptor
    var processingProvenance: RhythmicityProcessingProvenance

    /// Convenience for a continuous snapshot. The segment is still explicit so
    /// downstream code never needs a separate boundary-free path.
    static func entireRecording(
        channels: [RhythmicityChannelInput],
        samplingRate: Double,
        source: RhythmicitySourceDescriptor,
        processingProvenance: RhythmicityProcessingProvenance
    ) -> RhythmicityInput {
        let sampleCount = channels.first?.samples.count ?? 0
        let segments = sampleCount > 0
            ? [RhythmicitySegment(startSample: 0, endSample: sampleCount - 1)]
            : []
        return RhythmicityInput(
            channels: channels,
            samplingRate: samplingRate,
            segments: segments,
            source: source,
            processingProvenance: processingProvenance
        )
    }
}

nonisolated enum ABBADirection: String, Sendable, Codable, Equatable {
    case sustained
    case transient

    var referenceValue: Int { self == .sustained ? 1 : -1 }
}

nonisolated struct ABBABand: Identifiable, Sendable, Codable, Equatable {
    var id: UUID
    var beginIndex: Int
    var endIndex: Int
    var peakIndex: Int
    var beginFrequencyHz: Double
    var endFrequencyHz: Double
    var peakFrequencyHz: Double
    var peakLAVI: Double
    var deviationFromMedian: Double
    var direction: ABBADirection
    var relativeToAlpha: Int?
    var canonicalName: String?
    var isSignificant: Bool?
    var significanceMargin: Double?
}

nonisolated enum LAVISignificanceSource: String, Sendable, Codable, Equatable {
    case deterministicFixture
    case onDemandSurrogates
    case bundledLookup
}

nonisolated enum LAVITailRule: String, Sendable, Codable, Equatable {
    case fifthOrderStatisticPerFrequency
    case toolboxGlobalExtrema
}

nonisolated struct LAVISignificanceRibbon: Sendable, Codable, Equatable {
    var lower: [Double]
    var upper: [Double]
    var frequenciesHz: [Double]
    var source: LAVISignificanceSource
    var surrogateCount: Int
    var alpha: Double
    var tailRule: LAVITailRule
    var seed: UInt64? = nil
    var nonconvergedSurrogateCount: Int = 0
}

nonisolated struct AperiodicSpectrumFit: Sendable, Codable, Equatable {
    var frequenciesHz: [Double]
    var observedPower: [Double]
    var fittedPower: [Double]
    /// Power-law exponent in `power(f) = 10^intercept * f^exponent`.
    var exponent: Double
    /// Base-10 log intercept in `power(f) = 10^intercept * f^exponent`.
    var intercept: Double
    var fitRangeHz: ClosedRange<Double>
    var excludedRangesHz: [ClosedRange<Double>]
    var rSquared: Double
    var welchWindowSamples: Int
    var welchOverlapSamples: Int
    var welchWindowCount: Int
}

nonisolated enum IAAFTConvergenceStatus: String, Sendable, Codable, Equatable {
    case converged
    case stalled
    case iterationLimit
}

nonisolated struct IAAFTSurrogateDiagnostics: Sendable, Codable, Equatable {
    var seed: UInt64
    var iterations: Int
    var amplitudeError: Double
    var spectralError: Double
    var status: IAAFTConvergenceStatus
}

nonisolated struct LAVISurrogateSummary: Sendable, Codable, Equatable {
    var seed: UInt64
    var requestedCount: Int
    var retainedCount: Int
    var nonconvergedCount: Int
    var diagnostics: [IAAFTSurrogateDiagnostics]
    var amplitudeDistribution: LAVIAmplitudeDistribution
    var nonconvergencePolicy: IAAFTNonconvergencePolicy
}

nonisolated enum RhythmicityWarning: Sendable, Codable, Equatable {
    case nonfiniteSamplesExcluded(channelIndex: Int, count: Int)
    case insufficientValidDuration(channelIndex: Int, frequencyHz: Double)
    case laviOutsideUnitInterval(channelIndex: Int, frequencyHz: Double, value: Double)
    case iaaftSurrogatesDidNotConverge(channelIndex: Int, count: Int)
    case wtplNoValidSamples(frequencyHz: Double)
    case wtplBaselineUnavailable(frequencyHz: Double)
    case wtplRequestedBaselineOutsideEpoch(startMs: Double, endMs: Double)
    case noAlphaAnchor
    case flatLAVIProfile
    case computeBackendFallback(requested: String, reason: String)
}

nonisolated struct ABBAResult: Sendable, Equatable {
    var median: Double
    var deviationsFromMedian: [Double]
    var bands: [ABBABand]
    var warnings: [RhythmicityWarning]
}

nonisolated struct LAVIChannelResult: Sendable, Codable, Equatable {
    var channelIndex: Int
    var channelName: String
    var frequenciesHz: [Double]
    var values: [Double]
    var validPairCounts: [Int]
    var effectiveDurationsSeconds: [Double]
    var median: Double
    var lowerSignificance: [Double]?
    var upperSignificance: [Double]?
    var significanceRibbon: LAVISignificanceRibbon? = nil
    var aperiodicFit: AperiodicSpectrumFit? = nil
    var surrogateSummary: LAVISurrogateSummary? = nil
    var bands: [ABBABand]
    var warnings: [RhythmicityWarning]
}

nonisolated struct LAVIAnalysisResult: Sendable, Codable, Equatable {
    var configuration: RhythmicityConfiguration
    var source: RhythmicitySourceDescriptor
    var processingProvenance: RhythmicityProcessingProvenance
    var samplingRateHz: Double
    var channels: [LAVIChannelResult]
    var warnings: [RhythmicityWarning]
}

nonisolated enum RhythmicityProgressPhase: String, Sendable, Equatable {
    case validating
    case transforming
    case estimatingAperiodicSpectrum
    case generatingSignificance
    case assigningBands
    case detectingBursts
    case finished
}

nonisolated struct RhythmicityProgress: Sendable, Equatable {
    var fractionComplete: Double
    var phase: RhythmicityProgressPhase
    var channelIndex: Int?
    var frequencyHz: Double?
    var completedTiles: Int
    var totalTiles: Int
    /// Human-readable substage detail for long operations such as IAAFT.
    var detail: String? = nil
    /// Completed paper-significance profiles, separate from coefficient tiles.
    var completedSignificanceProfiles: Int? = nil
    var totalSignificanceProfiles: Int? = nil
}

nonisolated enum RhythmicityAnalysisError: Error, Sendable, Equatable, LocalizedError {
    case noChannels
    case emptyChannel(channelIndex: Int)
    case mismatchedChannelLength(channelIndex: Int, expected: Int, actual: Int)
    case invalidSamplingRate(Double)
    case noSegments
    case invalidSegment(index: Int, start: Int, end: Int, sampleCount: Int)
    case overlappingOrUnsortedSegments(index: Int)
    case noFrequencies
    case invalidFrequency(index: Int, value: Double)
    case frequenciesNotStrictlyAscending(index: Int)
    case frequencyAtOrAboveNyquist(index: Int, value: Double, nyquist: Double)
    case invalidMorletWidth(Double)
    case invalidLAVILag(Double)
    case coefficientShapeMismatch(expected: Int, real: Int, imaginary: Int)
    case incompleteFrequencyResults(expected: Int, actual: Int)
    case invalidSignificanceConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .noChannels:
            return "Rhythmicity analysis requires at least one channel."
        case let .emptyChannel(channelIndex):
            return "Channel \(channelIndex) contains no samples."
        case let .mismatchedChannelLength(channelIndex, expected, actual):
            return "Channel \(channelIndex) has \(actual) samples; expected \(expected)."
        case let .invalidSamplingRate(value):
            return "Sampling rate must be finite and positive; received \(value)."
        case .noSegments:
            return "Rhythmicity analysis requires at least one selected segment."
        case let .invalidSegment(index, start, end, sampleCount):
            return "Segment \(index) [\(start), \(end)] is outside 0..<\(sampleCount)."
        case let .overlappingOrUnsortedSegments(index):
            return "Segment \(index) overlaps or precedes the previous segment."
        case .noFrequencies:
            return "Rhythmicity analysis requires at least one frequency."
        case let .invalidFrequency(index, value):
            return "Frequency \(index) must be finite and positive; received \(value)."
        case let .frequenciesNotStrictlyAscending(index):
            return "Frequency \(index) is not strictly greater than its predecessor."
        case let .frequencyAtOrAboveNyquist(index, value, nyquist):
            return "Frequency \(index) (\(value) Hz) must be below Nyquist (\(nyquist) Hz)."
        case let .invalidMorletWidth(value):
            return "Morlet width must be finite and positive; received \(value)."
        case let .invalidLAVILag(value):
            return "LAVI lag must be finite and positive; received \(value)."
        case let .coefficientShapeMismatch(expected, real, imaginary):
            return "Coefficient provider returned \(real)/\(imaginary) samples; expected \(expected)."
        case let .incompleteFrequencyResults(expected, actual):
            return "Rhythmicity produced \(actual) frequency results; expected \(expected)."
        case let .invalidSignificanceConfiguration(message):
            return "Invalid LAVI significance configuration: \(message)"
        }
    }
}

nonisolated enum ABBAError: Error, Sendable, Equatable, LocalizedError {
    case emptyProfile
    case countMismatch(lavi: Int, frequencies: Int)
    case invalidFrequency(index: Int, value: Double)
    case frequenciesNotStrictlyAscending(index: Int)
    case invalidAlphaAnchor(lower: Double, upper: Double)
    case ribbonCountMismatch
    case ribbonFrequencyMismatch(index: Int)
    case invalidRibbon(index: Int)

    var errorDescription: String? {
        switch self {
        case .emptyProfile: return "ABBA requires a nonempty LAVI profile."
        case let .countMismatch(lavi, frequencies):
            return "ABBA received \(lavi) LAVI values and \(frequencies) frequencies."
        case let .invalidFrequency(index, value):
            return "ABBA frequency \(index) must be finite and positive; received \(value)."
        case let .frequenciesNotStrictlyAscending(index):
            return "ABBA frequency \(index) is not strictly increasing."
        case let .invalidAlphaAnchor(lower, upper):
            return "ABBA alpha anchor \(lower)...\(upper) Hz is invalid."
        case .ribbonCountMismatch:
            return "The significance ribbon does not match the LAVI profile length."
        case let .ribbonFrequencyMismatch(index):
            return "The significance ribbon frequency differs at index \(index)."
        case let .invalidRibbon(index):
            return "The significance ribbon is invalid at index \(index)."
        }
    }
}

/// Cooperative cancellation usable from synchronous numerical kernels.
nonisolated final class RhythmicityCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func check() throws {
        let taskCancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
        if isCancelled || taskCancelled {
            throw CancellationError()
        }
    }
}
