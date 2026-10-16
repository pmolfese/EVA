// Threshold ocular candidate review for the Clean Artifacts workflow.

import SwiftUI

nonisolated enum ThresholdOcularReview {
    static func setIncluded(_ included: Bool, eventID: String, artifact: inout DefinedArtifact) {
        guard let candidates = artifact.thresholdOcularCandidates,
              candidates.contains(where: { $0.id == eventID }) else { return }
        var excluded = artifact.thresholdOcularExcludedEventIDs ?? []
        if included { excluded.remove(eventID) } else { excluded.insert(eventID) }
        artifact.thresholdOcularExcludedEventIDs = excluded
        artifact.events = candidates.filter { !excluded.contains($0.id) }.map(\.event)
        artifact.average = nil
    }

    static func usableEvents(artifact: DefinedArtifact, signal: MFFSignalData) -> [MFFEvent] {
        artifact.events.filter { ArtifactCleaner.correctionWindow(for: $0, artifact: artifact, signal: signal) != nil }
    }

    /// Union of padded correction windows, so overlapping events count once.
    static func coveredSeconds(artifact: DefinedArtifact, signal: MFFSignalData) -> Double {
        let ranges = artifact.events.compactMap {
            ArtifactCleaner.correctionWindow(for: $0, artifact: artifact, signal: signal)
        }.sorted { $0.lowerBound < $1.lowerBound }
        var total = 0
        var merged: Range<Int>?
        for range in ranges {
            if let last = merged, range.lowerBound <= last.upperBound {
                merged = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                total += merged?.count ?? 0
                merged = range
            }
        }
        total += merged?.count ?? 0
        return signal.samplingRate > 0 ? Double(total) / signal.samplingRate : 0
    }
}

