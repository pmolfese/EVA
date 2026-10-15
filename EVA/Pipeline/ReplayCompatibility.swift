//
//  ReplayCompatibility.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Compatibility pre-flight (ROADMAP.md (completed batch suite)): checks one recorded step
//  against a target signal's actual sampling rate / channel count / events,
//  so an incompatible step is auto-flagged and unchecked in the replay config
//  pane instead of silently no-oping (or throwing deep inside the gradient/
//  `EEGSignalFilter`) partway through a run. Same shape as
//  `RecordingCombiner.compatibility(of:reference:)` (build flags, surface them
//  in a sanity list), scoped to "does this one step fit this one file" rather
//  than "do these files match a reference."
//

import Foundation

/// The lightweight view of a recording needed by compatibility rules. Batch
/// setup builds this from `MFFSignalMetadata`; live replay builds it from the
/// already-loaded `MFFSignalData`, so setup and runtime execute identical rules.
nonisolated struct ReplayCompatibilityTarget: Sendable, Equatable {
    let numberOfChannels: Int
    let samplingRate: Double
    let events: [MFFEvent]

    init(numberOfChannels: Int, samplingRate: Double, events: [MFFEvent]) {
        self.numberOfChannels = numberOfChannels
        self.samplingRate = samplingRate
        self.events = events
    }

    init(signal: MFFSignalData) {
        self.init(
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            events: signal.events
        )
    }

    init(metadata: MFFSignalMetadata) {
        self.init(
            numberOfChannels: metadata.numberOfChannels,
            samplingRate: metadata.samplingRate,
            events: metadata.events
        )
    }
}

nonisolated enum ReplayCompatibilityFlag: Sendable, Equatable {
    case missingTRMarkers(code: String, found: Int)
    case channelIndicesOutOfRange(field: String, indices: [Int], channelCount: Int)
    case missingEventCodes([String])
    case missingBeatEvents(code: String)

    var message: String {
        switch self {
        case .missingTRMarkers(let code, let found):
            return found == 0
                ? "No \"\(code)\" markers in this file."
                : "Only \(found) \"\(code)\" marker\(found == 1 ? "" : "s") in this file (need at least 2)."
        case .channelIndicesOutOfRange(let field, let indices, let channelCount):
            let oneBased = indices.map { $0 + 1 }.sorted()
            return "\(field) channel\(oneBased.count == 1 ? "" : "s") \(oneBased) out of range for this file's \(channelCount) channels."
        case .missingEventCodes(let codes):
            return "None of these event codes were found: \(codes.sorted().joined(separator: ", "))."
        case .missingBeatEvents(let code):
            return "No \"\(code)\" beats in this file. PCA-S corrects using beats another step detected; it cannot run without them."
        }
    }
}

nonisolated enum ReplayCompatibility {
    /// Checks whether `step` can run as configured against `signal`. `nil`
    /// means no problem was found (including for steps this check doesn't
    /// have an opinion about — an absence of a flag is not a guarantee of
    /// success, just "nothing obviously wrong").
    static func check(_ step: EVAProcessingStep, against signal: MFFSignalData) -> ReplayCompatibilityFlag? {
        check(step, against: ReplayCompatibilityTarget(signal: signal))
    }

    /// Light-target form used by batch setup before any sample data is loaded.
    /// Keep all rules here; the `MFFSignalData` overload above is deliberately
    /// only a convenience adapter for runtime callers.
    static func check(_ step: EVAProcessingStep, against target: ReplayCompatibilityTarget) -> ReplayCompatibilityFlag? {
        switch step.operation {
        case .mriGradientCorrection:
            let code = step.parameters["trMarkerCode"] ?? "TREV"
            let found = target.events.filter { $0.code == code }.count
            return found >= 2 ? nil : .missingTRMarkers(code: code, found: found)

        case .thresholdArtifactDetection:
            var outOfRange: [Int] = []
            for (field, kind) in [("blink", EyeArtifactKind.blink), ("movement", .movement)] {
                let config = EyeArtifactThresholdConfiguration.fromFlatParameters(
                    step.parameters, prefix: field, base: .defaults(for: kind))
                outOfRange += (config.channelOverride ?? []).filter { $0 < 0 || $0 >= target.numberOfChannels }
            }
            guard !outOfRange.isEmpty else { return nil }
            return .channelIndicesOutOfRange(field: "Threshold override", indices: outOfRange, channelCount: target.numberOfChannels)

        case .bcgCorrection:
            // The settings travel; the beats do not. A file with no beats
            // cannot be corrected by a method that locks to them, and saying so
            // in the pre-flight is better than failing halfway through a batch.
            let code = step.parameters["beatEventCode"] ?? EVAProcessingStep.defaultBeatEventCode
            return target.events.contains { $0.code == code }
                ? nil
                : .missingBeatEvents(code: code)

        case .segment:
            guard let codesParam = step.parameters["eventCodes"] else { return nil }
            let codes = Set(codesParam.split(separator: ",").map(String.init))
            guard !codes.isEmpty else { return nil }
            let available = Set(target.events.map(\.code))
            return codes.isDisjoint(with: available) ? .missingEventCodes(codes.sorted()) : nil

        default:
            return nil
        }
    }
}
