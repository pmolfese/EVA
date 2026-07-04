//
//  SegmentHealthTrainingExport.swift
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
//  JSON schema for collecting segment-health metrics and provenance. Human
//  labels can be added later without changing the metric feature payload.
//

import Foundation

nonisolated enum SavedSegmentHealthLabel: String, Codable, Sendable {
    case good
    case bad
}

nonisolated struct SavedSegmentHealthDataset: Codable, Sendable {
    var schemaVersion: Int
    var createdAt: Date
    var labelSource: String
    var packageName: String
    var sourceSignalPath: String
    var signalType: String
    var samplingRate: Double
    var durationSeconds: Double
    var sampleCount: Int
    var channelCount: Int
    var processing: SavedSegmentHealthProcessing
    var analysis: SavedSegmentHealthAnalysisMetadata
    var segments: [SavedSegmentHealthSegment]
}

nonisolated struct SavedSegmentHealthProcessing: Codable, Sendable {
    var gradientCorrected: Bool
    var icaCleaned: Bool
    var filtered: Bool
    var filterLowCutoffHz: Double?
    var filterHighCutoffHz: Double?
    var notch60HzEnabled: Bool?
    var averageReferenced: Bool?
    var artifactCleaned: Bool
    var artifactCleaningVisible: Bool
    var epoched: Bool
    var psaAveraged: Bool
    var psaBaselineCorrected: Bool
    var psaAverageReferenced: Bool
    var hiddenChannelIndices: [Int]
    var interpolatedChannelIndices: [Int]
    var markedBadChannelIndices: [Int]
}

nonisolated struct SavedSegmentHealthAnalysisMetadata: Codable, Sendable {
    var analyzerVersion: Int
    var segmentDefinition: SegmentHealthSegmentDefinition
    var continuousWindowSeconds: Double
    var sampleStride: Int
    var effectiveSamplingRate: Double
    var analyzedSampleCount: Int
    var baselines: SegmentHealthBaselines?
}

nonisolated struct SavedSegmentHealthSegment: Codable, Sendable {
    var segmentID: String
    var segmentIndex: Int
    var category: String
    var startSample: Int
    var endSample: Int
    var startTimeSeconds: Double
    var endTimeSeconds: Double
    var durationSeconds: Double
    var stimulusOffsetSamples: Int?
    var sourceCode: String?
    var sourceTimeSeconds: Double?
    var contributingEpochCount: Int
    var humanLabel: SavedSegmentHealthLabel?
    var health: SegmentHealthResult
    var features: SegmentHealthFeatures?
}

extension SavedSegmentHealthDataset {
    nonisolated static func make(
        packageName: String,
        signal: MFFSignalData,
        processing: SavedSegmentHealthProcessing,
        analysis: SegmentHealthAnalysis
    ) -> Self {
        let sampleCount = signal.data.first?.count ?? 0
        let segments = analysis.results.map { result in
            SavedSegmentHealthSegment(
                segmentID: result.segmentID,
                segmentIndex: result.segmentIndex,
                category: result.category,
                startSample: result.startSample,
                endSample: result.endSample,
                startTimeSeconds: result.startTimeSeconds,
                endTimeSeconds: result.endTimeSeconds,
                durationSeconds: result.durationSeconds,
                stimulusOffsetSamples: result.stimulusOffsetSamples,
                sourceCode: result.sourceCode,
                sourceTimeSeconds: result.sourceTimeSeconds,
                contributingEpochCount: result.contributingEpochCount,
                humanLabel: nil,
                health: result,
                features: analysis.featuresBySegmentID[result.segmentID]
            )
        }

        return SavedSegmentHealthDataset(
            schemaVersion: 1,
            createdAt: Date(),
            labelSource: "EVA segment-health metrics snapshot: no human good/bad labels assigned yet",
            packageName: packageName,
            sourceSignalPath: signal.signalURL.path,
            signalType: signal.signalType,
            samplingRate: signal.samplingRate,
            durationSeconds: signal.duration,
            sampleCount: sampleCount,
            channelCount: signal.numberOfChannels,
            processing: processing,
            analysis: SavedSegmentHealthAnalysisMetadata(
                analyzerVersion: 1,
                segmentDefinition: analysis.segmentDefinition,
                continuousWindowSeconds: SegmentHealthAnalyzer.continuousWindowSeconds,
                sampleStride: analysis.sampleStride,
                effectiveSamplingRate: analysis.effectiveSamplingRate,
                analyzedSampleCount: analysis.analyzedSampleCount,
                baselines: analysis.baselines
            ),
            segments: segments
        )
    }
}
