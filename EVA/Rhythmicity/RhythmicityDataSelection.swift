//
//  RhythmicityDataSelection.swift
//  EVA
//
//  User-facing selection contracts for the Bands workspace.  These stay
//  independent of SwiftUI so run snapshots and export manifests can record the
//  exact choice that produced a result.
//

import Foundation

nonisolated enum RhythmicitySignalSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case processed = "Processed recording"

    var id: String { rawValue }
}

nonisolated enum RhythmicityDataSelection: String, CaseIterable, Identifiable, Sendable, Codable {
    case entireProcessedRecording = "Entire recording"
    case currentVisibleRange = "Visible range"
    case selectedRange = "Waveform selection"

    var id: String { rawValue }
}

nonisolated enum RhythmicityChannelScope: String, CaseIterable, Identifiable, Sendable, Codable {
    case current = "Selected channel"
    case visibleGood = "Visible good channels"
    case namedSet = "Channel set"
    case allGood = "All good EEG channels"

    var id: String { rawValue }
}

nonisolated struct RhythmicitySelectionDescriptor: Sendable, Codable, Equatable {
    var source: RhythmicitySignalSource
    var dataSelection: RhythmicityDataSelection
    var segments: [RhythmicitySegment]
    var channelScope: RhythmicityChannelScope
    var channelSetName: String?
    var includedChannelIndices: [Int]
    var excludedBadChannelIndices: [Int]
    var interpolatedChannelIndices: [Int]
    var includedMarkedArtifacts: Bool

    var selectedSampleCount: Int {
        segments.reduce(0) { partial, segment in
            partial + max(segment.endSample - segment.startSample + 1, 0)
        }
    }
}

nonisolated enum RhythmicityValidity: String, Sendable, Equatable {
    case ready = "Ready"
    case exploratory = "Exploratory"
    case referenceValid = "Reference-valid"
    case customSignificance = "Custom significance"
    case invalid = "Invalid / insufficient"
    case stale = "Stale"
}

nonisolated struct RhythmicityLogLine: Identifiable, Sendable, Equatable {
    var id = UUID()
    var date: Date
    var message: String
}

nonisolated enum RhythmicitySegmentPolicy {
    /// Subtract inclusive artifact ranges without ever joining the pieces on
    /// either side. Overlapping/adjacent exclusions are merged first so output
    /// remains strictly ordered and nonoverlapping for `LAVIEngine` validation.
    static func removing(
        excludedRanges: [ClosedRange<Int>],
        from segments: [RhythmicitySegment]
    ) -> [RhythmicitySegment] {
        let sorted = excludedRanges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        var output: [RhythmicitySegment] = []
        for segment in segments.sorted(by: { $0.startSample < $1.startSample }) {
            var cursor = segment.startSample
            var part = 1
            for exclusion in merged
            where exclusion.upperBound >= segment.startSample && exclusion.lowerBound <= segment.endSample {
                if exclusion.lowerBound > cursor {
                    output.append(piece(segment, start: cursor, end: min(exclusion.lowerBound - 1, segment.endSample), part: part))
                    part += 1
                }
                cursor = max(cursor, exclusion.upperBound + 1)
                if cursor > segment.endSample { break }
            }
            if cursor <= segment.endSample {
                output.append(piece(segment, start: cursor, end: segment.endSample, part: part))
            }
        }
        return output
    }

    private static func piece(
        _ source: RhythmicitySegment,
        start: Int,
        end: Int,
        part: Int
    ) -> RhythmicitySegment {
        RhythmicitySegment(
            startSample: start,
            endSample: end,
            label: source.label.map { "\($0) part \(part)" },
            trialID: source.trialID
        )
    }
}
