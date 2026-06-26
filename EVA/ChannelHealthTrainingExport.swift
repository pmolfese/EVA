//
//  ChannelHealthTrainingExport.swift
//  EVA
//
//  Copyright (C) 2026 Peter Molfese
//  SPDX-License-Identifier: GPL-3.0-only
//
//  JSON schema for collecting human-reviewed channel labels and the numeric
//  features needed to train a future Core ML channel-quality model.
//

import Foundation

nonisolated enum SavedChannelHealthLabel: String, Codable, Sendable {
    case good
    case bad
}

nonisolated struct SavedChannelHealthDataset: Codable, Sendable {
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
    var processing: SavedChannelHealthProcessing
    var analysis: SavedChannelHealthAnalysisMetadata
    var channels: [SavedChannelHealthChannel]
}

nonisolated struct SavedChannelHealthProcessing: Codable, Sendable {
    var gradientCorrected: Bool
    var icaCleaned: Bool
    var filtered: Bool
    var filterLowCutoffHz: Double?
    var filterHighCutoffHz: Double?
    var notch60HzEnabled: Bool?
    var averageReferenced: Bool?
    var artifactCleaned: Bool
    var artifactCleaningVisible: Bool
    /// 0-based channel indices whose displayed trace has an interpolation overlay.
    var interpolatedChannelIndices: [Int]
    /// 0-based channel indices marked bad at export time.
    var markedBadChannelIndices: [Int]
}

nonisolated struct SavedChannelHealthAnalysisMetadata: Codable, Sendable {
    var analyzerVersion: Int
    var sampleStride: Int
    var effectiveSamplingRate: Double
    var analyzedSampleCount: Int
    var baselines: ChannelHealthBaselines?
}

nonisolated struct SavedChannelHealthChannel: Codable, Sendable {
    /// 0-based channel index used internally by EVA.
    var channelIndex: Int
    /// 1-based channel number shown to users and used by EGI layouts.
    var channelNumber: Int
    var channelName: String?
    var label: SavedChannelHealthLabel
    var isMarkedBad: Bool
    var isHidden: Bool
    var isInterpolated: Bool
    var health: ChannelHealthResult?
    var features: ChannelHealthFeatures?
}

extension SavedChannelHealthDataset {
    nonisolated static func make(
        packageName: String,
        signal: MFFSignalData,
        processing: SavedChannelHealthProcessing,
        hiddenChannelIndices: Set<Int>,
        analysis: ChannelHealthAnalysis
    ) -> Self {
        let badChannelIndices = Set(processing.markedBadChannelIndices)
        let interpolatedChannelIndices = Set(processing.interpolatedChannelIndices)
        let sampleCount = signal.data.first?.count ?? 0
        let channels = signal.data.indices.map { channelIndex in
            let isBad = badChannelIndices.contains(channelIndex)
            let rawChannelName = signal.channelNames?.indices.contains(channelIndex) == true
                ? signal.channelNames?[channelIndex]
                : nil
            let channelName = rawChannelName?.isEmpty == false ? rawChannelName : nil

            return SavedChannelHealthChannel(
                channelIndex: channelIndex,
                channelNumber: channelIndex + 1,
                channelName: channelName,
                label: isBad ? .bad : .good,
                isMarkedBad: isBad,
                isHidden: hiddenChannelIndices.contains(channelIndex),
                isInterpolated: interpolatedChannelIndices.contains(channelIndex),
                health: analysis.resultsByChannel[channelIndex],
                features: analysis.featuresByChannel[channelIndex]
            )
        }

        return SavedChannelHealthDataset(
            schemaVersion: 1,
            createdAt: Date(),
            labelSource: "EVA bad-channel snapshot: marked bad => bad; unmarked => good",
            packageName: packageName,
            sourceSignalPath: signal.signalURL.path,
            signalType: signal.signalType,
            samplingRate: signal.samplingRate,
            durationSeconds: signal.duration,
            sampleCount: sampleCount,
            channelCount: signal.numberOfChannels,
            processing: processing,
            analysis: SavedChannelHealthAnalysisMetadata(
                analyzerVersion: 1,
                sampleStride: analysis.sampleStride,
                effectiveSamplingRate: analysis.effectiveSamplingRate,
                analyzedSampleCount: analysis.analyzedSampleCount,
                baselines: analysis.baselines
            ),
            channels: channels
        )
    }
}
