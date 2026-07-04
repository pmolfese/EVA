//
//  EEGAnalysisModels.swift
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

import Foundation

nonisolated struct EEGFrequencyBand: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var lowHz: Double
    var highHz: Double

    var id: String { name }

    static let restingDefaults: [EEGFrequencyBand] = [
        EEGFrequencyBand(name: "Delta", lowHz: 1, highHz: 4),
        EEGFrequencyBand(name: "Theta", lowHz: 4, highHz: 8),
        EEGFrequencyBand(name: "Alpha", lowHz: 8, highHz: 13),
        EEGFrequencyBand(name: "Beta", lowHz: 13, highHz: 30),
        EEGFrequencyBand(name: "Low Gamma", lowHz: 30, highHz: 45)
    ]
}

nonisolated enum EEGConnectivityMetric: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case coherence
    case imaginaryCoherence
    case phaseLockingValue
    case weightedPhaseLagIndex
    case amplitudeEnvelopeCorrelation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coherence: return "Coherence"
        case .imaginaryCoherence: return "Imaginary Coherence"
        case .phaseLockingValue: return "Phase Locking Value"
        case .weightedPhaseLagIndex: return "Weighted Phase-Lag Index"
        case .amplitudeEnvelopeCorrelation: return "Amplitude-Envelope Correlation"
        }
    }

    var shortName: String {
        switch self {
        case .coherence: return "Coh"
        case .imaginaryCoherence: return "ImCoh"
        case .phaseLockingValue: return "PLV"
        case .weightedPhaseLagIndex: return "wPLI"
        case .amplitudeEnvelopeCorrelation: return "AEC"
        }
    }
}

nonisolated struct EEGArtifactRejectionSource: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var eventCode: String
    var windowSizeSeconds: Double
    var events: [MFFEvent]

    var eventCount: Int { events.count }
}

nonisolated struct EEGAnalysisProcessingSnapshot: Codable, Sendable {
    var signalDescription: String
    var gradientCorrected: Bool
    var icaCleaned: Bool
    var filtered: Bool
    var filterLowCutoffHz: Double?
    var filterHighCutoffHz: Double?
    var notch60HzEnabled: Bool?
    var averageReferenced: Bool?
    var artifactCleaned: Bool
    var artifactCleaningVisible: Bool
    var waveletReduced: Bool
    var waveletReductionVisible: Bool
    var interpolatedChannelIndices: [Int]
    var markedBadChannelIndices: [Int]
}

nonisolated struct EEGAnalysisConfiguration: Codable, Sendable {
    var segmentLengthSeconds: Double
    var keptSegmentGrades: [ChannelHealthGrade]
    var artifactRejectionThreshold: Double
    var selectedArtifactSourceNames: [String]
    var frequencyBands: [EEGFrequencyBand]
    var connectivityBand: EEGFrequencyBand
    var connectivityMetrics: [EEGConnectivityMetric]
    var includesChannelConnectivity: Bool
    var includesRegionConnectivity: Bool
}

nonisolated struct EEGAnalysisSegmentDecision: Codable, Identifiable, Sendable {
    var segmentID: String
    var segmentIndex: Int
    var startSample: Int
    var endSample: Int
    var startTimeSeconds: Double
    var endTimeSeconds: Double
    var durationSeconds: Double
    var healthGrade: ChannelHealthGrade
    var healthGoodPercentage: Int
    var artifactOverlapFraction: Double
    var artifactCount: Int
    var isIncluded: Bool
    var rejectionReasons: [String]

    var id: String { segmentID }
}

nonisolated struct EEGAnalysisSegmentSummary: Codable, Sendable {
    var totalSegmentCount: Int
    var includedSegmentCount: Int
    var rejectedByHealthCount: Int
    var rejectedByArtifactCount: Int
    var totalDurationSeconds: Double
    var includedDurationSeconds: Double
}

nonisolated struct EEGSpectralBandValue: Codable, Identifiable, Sendable {
    var bandName: String
    var lowHz: Double
    var highHz: Double
    var absolutePower: Double
    var relativePower: Double
    var log10Power: Double

    var id: String { bandName }
}

nonisolated struct EEGSpectralChannelResult: Codable, Identifiable, Sendable {
    var channelIndex: Int
    var channelName: String
    var totalPower: Double
    var bandValues: [EEGSpectralBandValue]

    var id: Int { channelIndex }
}

nonisolated struct EEGSpectralRecordingBandSummary: Codable, Identifiable, Sendable {
    var bandName: String
    var lowHz: Double
    var highHz: Double
    var meanAbsolutePower: Double
    var meanRelativePower: Double
    var channelRelativePowers: [Double]

    var id: String { bandName }
}

nonisolated struct EEGSpectralAnalysisResult: Codable, Sendable {
    var segmentCount: Int
    var durationSeconds: Double
    var channelCount: Int
    var fftBinHz: Double
    var bands: [EEGSpectralRecordingBandSummary]
    var channels: [EEGSpectralChannelResult]
}

nonisolated enum EEGConnectivityScope: String, Codable, Sendable {
    case channel
    case region
}

nonisolated struct EEGConnectivityNode: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var scope: EEGConnectivityScope
    var channelIndices: [Int]
}

nonisolated struct EEGConnectivityMetricValue: Codable, Identifiable, Sendable {
    var metric: EEGConnectivityMetric
    var value: Double

    var id: String { metric.rawValue }
}

nonisolated struct EEGConnectivityPairResult: Codable, Identifiable, Sendable {
    var scope: EEGConnectivityScope
    var nodeA: EEGConnectivityNode
    var nodeB: EEGConnectivityNode
    var metricValues: [EEGConnectivityMetricValue]

    var id: String { "\(scope.rawValue)-\(nodeA.id)-\(nodeB.id)" }
}

nonisolated struct EEGConnectivityAnalysisResult: Codable, Sendable {
    var band: EEGFrequencyBand
    var metrics: [EEGConnectivityMetric]
    var channelPairs: [EEGConnectivityPairResult]
    var regionPairs: [EEGConnectivityPairResult]
}

nonisolated struct EEGAnalysisRecordingSummary: Codable, Sendable {
    var packageName: String
    var signalType: String
    var samplingRate: Double
    var durationSeconds: Double
    var channelCount: Int
    var analyzedChannelCount: Int
}

nonisolated struct EEGAnalysisResult: Codable, Sendable {
    var schemaVersion: Int
    var createdAt: Date
    var recording: EEGAnalysisRecordingSummary
    var processing: EEGAnalysisProcessingSnapshot
    var configuration: EEGAnalysisConfiguration
    var segments: EEGAnalysisSegmentSummary
    var segmentDecisions: [EEGAnalysisSegmentDecision]
    var spectral: EEGSpectralAnalysisResult?
    var connectivity: EEGConnectivityAnalysisResult?
}

nonisolated struct EEGAnalysisExportOptions: Sendable {
    var includesPerChannelDetails: Bool
    var includesSegmentDetails: Bool
    var includesConnectivityPairs: Bool
}
