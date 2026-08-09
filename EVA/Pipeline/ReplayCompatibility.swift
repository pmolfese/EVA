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
//  Compatibility pre-flight (TODO.md Priority 1): checks one recorded step
//  against a target signal's actual sampling rate / channel count / events,
//  so an incompatible step is auto-flagged and unchecked in the replay config
//  pane instead of silently no-oping (or throwing deep inside the gradient/
//  `EEGSignalFilter`) partway through a run. Same shape as
//  `RecordingCombiner.compatibility(of:reference:)` (build flags, surface them
//  in a sanity list), scoped to "does this one step fit this one file" rather
//  than "do these files match a reference."
//

import Foundation

nonisolated enum ReplayCompatibilityFlag: Equatable {
    case missingTRMarkers(code: String, found: Int)
    case channelIndicesOutOfRange(field: String, indices: [Int], channelCount: Int)
    case missingEventCodes([String])

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
        }
    }
}

nonisolated enum ReplayCompatibility {
    /// Checks whether `step` can run as configured against `signal`. `nil`
    /// means no problem was found (including for steps this check doesn't
    /// have an opinion about — an absence of a flag is not a guarantee of
    /// success, just "nothing obviously wrong").
    static func check(_ step: EVAProcessingStep, against signal: MFFSignalData) -> ReplayCompatibilityFlag? {
        switch step.operation {
        case .mriGradientCorrection:
            let code = step.parameters["trMarkerCode"] ?? "TREV"
            let found = signal.events.filter { $0.code == code }.count
            return found >= 2 ? nil : .missingTRMarkers(code: code, found: found)

        case .thresholdArtifactDetection:
            var outOfRange: [Int] = []
            for (field, kind) in [("blink", EyeArtifactKind.blink), ("movement", .movement)] {
                let config = EyeArtifactThresholdConfiguration.fromFlatParameters(
                    step.parameters, prefix: field, base: .defaults(for: kind))
                outOfRange += (config.channelOverride ?? []).filter { $0 < 0 || $0 >= signal.numberOfChannels }
            }
            guard !outOfRange.isEmpty else { return nil }
            return .channelIndicesOutOfRange(field: "Threshold override", indices: outOfRange, channelCount: signal.numberOfChannels)

        case .segment:
            guard let codesParam = step.parameters["eventCodes"] else { return nil }
            let codes = Set(codesParam.split(separator: ",").map(String.init))
            guard !codes.isEmpty else { return nil }
            let available = Set(signal.events.map(\.code))
            return codes.isDisjoint(with: available) ? .missingEventCodes(codes.sorted()) : nil

        default:
            return nil
        }
    }
}
