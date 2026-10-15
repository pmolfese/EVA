//
//  DetectedRhythmicityBandSet.swift
//  EVA
//
//  Session-scoped bridge from an explicitly published ABBA result to the
//  Time-Frequency explorer. These values are derived analysis output; they do
//  not mutate the user's saved ProcessingDefaults bands.
//

import Foundation

nonisolated enum TimeFrequencyBandSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case evaDefaults = "EVA defaults"
    case userPreferences = "User preferences"
    case rhythmicityExplorer = "Rhythmicity Explorer"

    var id: String { rawValue }
}

nonisolated struct DetectedRhythmicityBand: Identifiable, Sendable, Codable, Equatable {
    var id: UUID
    var name: String
    var lowHz: Double
    var highHz: Double
    var peakHz: Double
    var direction: ABBADirection
    var isSignificant: Bool?

    var frequencyBand: EEGFrequencyBand {
        EEGFrequencyBand(name: name, lowHz: lowHz, highHz: highHz)
    }
}

nonisolated struct DetectedRhythmicityBandSet: Identifiable, Sendable, Codable, Equatable {
    var id: UUID
    var methodVersion: String
    var recordingIdentity: String
    var recordingDisplayName: String
    var sourceRevision: String
    var channelScope: RhythmicityChannelScope
    var sourceChannelIndex: Int
    var sourceChannelName: String
    var dataSelection: RhythmicitySelectionDescriptor
    var configuration: RhythmicityConfiguration
    /// Full-fidelity ABBA output. Display/export adapters below retain these
    /// values while assigning unique picker labels.
    var bands: [ABBABand]
    var createdAt: Date

    var displayBands: [DetectedRhythmicityBand] { Self.displayBands(from: bands) }
    var frequencyBands: [EEGFrequencyBand] { displayBands.map(\.frequencyBand) }

    var resultDescription: String {
        "\(sourceChannelName) · \(bands.count) ABBA band\(bands.count == 1 ? "" : "s")"
    }

    var provenanceDescription: String {
        "\(recordingDisplayName) · \(sourceChannelName) · \(channelScope.rawValue) · \(dataSelection.dataSelection.rawValue) · \(configuration.presetID) · published \(createdAt.ISO8601Format())"
    }

    static func make(
        result: LAVIAnalysisResult,
        selection: RhythmicitySelectionDescriptor,
        channel: LAVIChannelResult,
        createdAt: Date = Date()
    ) -> DetectedRhythmicityBandSet? {
        guard !channel.bands.isEmpty else { return nil }
        return DetectedRhythmicityBandSet(
            id: UUID(),
            methodVersion: RhythmicityExport.methodVersion,
            recordingIdentity: result.source.recordingIdentity,
            recordingDisplayName: result.source.displayName,
            sourceRevision: result.processingProvenance.sourceRevision,
            channelScope: selection.channelScope,
            sourceChannelIndex: channel.channelIndex,
            sourceChannelName: channel.channelName,
            dataSelection: selection,
            configuration: result.configuration,
            bands: channel.bands,
            createdAt: createdAt
        )
    }

    private static func displayBands(from bands: [ABBABand]) -> [DetectedRhythmicityBand] {
        var usedNames = Set<String>()
        var sustainedCount = 0
        var transientCount = 0
        return bands.map { band -> DetectedRhythmicityBand in
            let ordinal: Int
            if band.direction == .sustained {
                sustainedCount += 1
                ordinal = sustainedCount
            } else {
                transientCount += 1
                ordinal = transientCount
            }
            let base = band.canonicalName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = band.direction == .sustained ? "Sustained \(ordinal)" : "Transient \(ordinal)"
            let candidate = base.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            var name = candidate
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(candidate) \(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            return DetectedRhythmicityBand(
                id: band.id,
                name: name,
                lowHz: min(band.beginFrequencyHz, band.endFrequencyHz),
                highHz: max(band.beginFrequencyHz, band.endFrequencyHz),
                peakHz: band.peakFrequencyHz,
                direction: band.direction,
                isSignificant: band.isSignificant
            )
        }
    }
}

nonisolated struct TimeFrequencyBandResolution: Sendable, Equatable {
    var source: TimeFrequencyBandSource
    var bands: [EEGFrequencyBand]
    var detectedBandSet: DetectedRhythmicityBandSet?
    var warning: String?

    var sourceDescription: String {
        switch source {
        case .evaDefaults: return source.rawValue
        case .userPreferences: return source.rawValue
        case .rhythmicityExplorer:
            return detectedBandSet.map { "Rhythmicity Explorer: \($0.resultDescription)" } ?? source.rawValue
        }
    }

    static func resolve(
        source: TimeFrequencyBandSource,
        userPreferences: [EEGFrequencyBand],
        detectedBandSet: DetectedRhythmicityBandSet?,
        detectedBandSetIsStale: Bool
    ) -> TimeFrequencyBandResolution {
        switch source {
        case .evaDefaults:
            return TimeFrequencyBandResolution(source: source, bands: EEGFrequencyBand.restingDefaults, detectedBandSet: nil, warning: nil)
        case .userPreferences:
            return TimeFrequencyBandResolution(source: source, bands: userPreferences, detectedBandSet: nil, warning: nil)
        case .rhythmicityExplorer:
            guard let detectedBandSet else {
                return TimeFrequencyBandResolution(
                    source: source, bands: [], detectedBandSet: nil,
                    warning: "No ABBA band set has been published for this recording. Use ‘Use in Time-Frequency’ in Rhythmicity Explorer."
                )
            }
            guard !detectedBandSetIsStale else {
                return TimeFrequencyBandResolution(
                    source: source, bands: [], detectedBandSet: nil,
                    warning: "The published ABBA bands are stale because the recording signal changed. Re-run and publish them again."
                )
            }
            return TimeFrequencyBandResolution(
                source: source,
                bands: detectedBandSet.frequencyBands,
                detectedBandSet: detectedBandSet,
                warning: "The \(detectedBandSet.sourceChannelName) boundaries are applied to every displayed channel; channel-specific boundaries are not mixed."
            )
        }
    }
}
