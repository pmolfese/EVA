//
//  WTPLModels.swift
//  EVA
//
//  Data contracts for event-related Within-Trial Phase Locking. WTPL remains
//  distinct from ITPC: it compares phase across nearby times inside each trial.
//

import Foundation

nonisolated struct WTPLBaselineSpec: Sendable, Codable, Equatable {
    var startSample: Int
    var endSample: Int

    init(startSample: Int, endSample: Int) {
        self.startSample = startSample
        self.endSample = endSample
    }
}

nonisolated struct WTPLResult: Sendable, Equatable {
    /// Condition mean, `frequency × time`. Invalid edges are NaN.
    var meanWTPL: [[Double]]
    /// Raw WTPL minus the per-frequency baseline mean.
    var deltaWTPL: [[Double]]?
    /// Optional `trial × frequency × time` values for export/statistics.
    var perTrialWTPL: [[[Double]]]?
    var frequenciesHz: [Double]
    var timesMs: [Double]
    var validTrialCounts: [[Int]]
    /// Unbiased sample variance across valid trials at every cell.
    var varianceWTPL: [[Double]]
    var trialCount: Int
    var baselineWindowMs: ClosedRange<Double>?
    var lagCycles: [Double]
    var warnings: [RhythmicityWarning]
}

nonisolated struct FrequencyTimeMaps: Sendable, Equatable {
    var power: [[Double]]?
    var itpc: [[Double]]?
    var wtpl: [[Double]]?
    var deltaWTPL: [[Double]]?
    var frequenciesHz: [Double]
    var timesMs: [Double]
}

nonisolated struct WTPLChannelResult: Sendable, Equatable {
    var channelIndex: Int
    var channelName: String
    var meanWTPL: [[Double]]
    var deltaWTPL: [[Double]]?
    var validTrialCounts: [[Int]]
    var varianceWTPL: [[Double]]
    var trialCount: Int
}

nonisolated struct WTPLConditionResult: Sendable, Equatable {
    var condition: String
    var channels: [WTPLChannelResult]
}

nonisolated struct WTPLAnalysisResult: Sendable, Equatable {
    var source: RhythmicitySourceDescriptor
    var processingProvenance: RhythmicityProcessingProvenance
    var frequenciesHz: [Double]
    var timesMs: [Double]
    var nCycles: [Double]
    var lagCycles: [Double]
    var edgePolicy: RhythmicityEdgePolicy
    var baselineWindowMs: ClosedRange<Double>?
    var conditions: [WTPLConditionResult]
    var warnings: [RhythmicityWarning]
}

nonisolated enum WTPLAnalysisError: Error, Sendable, Equatable, LocalizedError {
    case noTrials
    case emptyTrial(index: Int)
    case mismatchedTrialLength(index: Int, expected: Int, actual: Int)
    case invalidSamplingRate(Double)
    case invalidEventSample(index: Int, sampleCount: Int)
    case invalidFrequencyPlan
    case frequencyAtOrAboveNyquist(index: Int, value: Double, nyquist: Double)
    case invalidLag(index: Int, value: Double)
    case invalidBaseline(start: Int, end: Int, sampleCount: Int)
    case coefficientShapeMismatch(expected: Int, real: Int, imaginary: Int)
    case mismatchedTimeAxis(condition: String)

    var errorDescription: String? {
        switch self {
        case .noTrials: return "WTPL requires at least one epoch/trial."
        case let .emptyTrial(index): return "WTPL trial \(index + 1) is empty."
        case let .mismatchedTrialLength(index, expected, actual):
            return "WTPL trial \(index + 1) has \(actual) samples; expected \(expected)."
        case let .invalidSamplingRate(value): return "WTPL sampling rate must be finite and positive; received \(value)."
        case let .invalidEventSample(index, sampleCount): return "WTPL event sample \(index) is outside the \(sampleCount)-sample epoch."
        case .invalidFrequencyPlan: return "WTPL frequencies and cycle widths must be nonempty, finite, positive, ascending, and equal in count."
        case let .frequencyAtOrAboveNyquist(index, value, nyquist):
            return "WTPL frequency \(index + 1) (\(value) Hz) must be below Nyquist (\(nyquist) Hz)."
        case let .invalidLag(index, value): return "WTPL lag \(index + 1) must be finite and nonzero; received \(value)."
        case let .invalidBaseline(start, end, sampleCount):
            return "WTPL baseline [\(start), \(end)] is outside the \(sampleCount)-sample epoch."
        case let .coefficientShapeMismatch(expected, real, imaginary):
            return "WTPL coefficient provider returned \(real)/\(imaginary) samples; expected \(expected)."
        case let .mismatchedTimeAxis(condition):
            return "WTPL condition \(condition) has a different epoch time axis and cannot be compared by sample index."
        }
    }
}
