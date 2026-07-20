//
//  EyeArtifactThresholdConfiguration.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Per-kind (eye-blink / eye-movement) parameters for the threshold-based ocular
//  artifact detector (`EyeArtifactThresholdDetector`). A plain value type so it
//  can be edited in the UI, persisted, and passed into the nonisolated engine.
//

import Foundation

/// Which deflection polarity counts as a crossing. Blinks are typically a
/// positive VEOG deflection; horizontal saccades are bipolar HEOG steps.
nonisolated enum EyeArtifactPolarity: String, CaseIterable, Codable, Sendable, Identifiable {
    case positive = "Positive"
    case negative = "Negative"
    case bipolar  = "Bipolar"

    var id: String { rawValue }
}

nonisolated struct EyeArtifactThresholdConfiguration: Sendable, Codable, Equatable, Hashable {
    /// Detection threshold: the deflection magnitude that opens a candidate.
    var amplitudeMinMicrovolts: Float
    /// Upper magnitude cap; a candidate whose peak exceeds this is rejected as
    /// saturation/clipping rather than a physiological artifact. `0` = no cap.
    var amplitudeMaxMicrovolts: Float
    /// The baseline→peak deflection must complete within this window. Fast for
    /// blinks; step-like for saccades. `0` = unconstrained.
    var riseWindowSeconds: Double
    /// Gate on the steepest first difference on the rising edge (µV / ms).
    var velocityEnabled: Bool
    var velocityThresholdMicrovoltsPerMillisecond: Float
    /// Gate on the steepest second difference (µV / ms²) — the strongest
    /// discriminator between a sharp blink and slow ocular drift.
    var accelerationEnabled: Bool
    var accelerationThresholdMicrovoltsPerMillisecondSquared: Float
    /// Minimum time the signal stays past threshold for a candidate to count.
    var minDurationSeconds: Double
    /// Maximum candidate duration; longer deflections are rejected. `0` = no cap.
    var maxDurationSeconds: Double
    /// Adjacent candidates closer than this are fused into one event.
    var mergeGapSeconds: Double
    var polarity: EyeArtifactPolarity
    /// User-chosen ocular channels (0-based). `nil` = auto per net geometry.
    var channelOverride: [Int]?

    /// Preserves the original hard-coded behaviour (±150 µV, 0.05 s min, 0.25 s
    /// merge, bipolar, auto channels) as the seed for each kind. Extra gates are
    /// available in the settings sheet, but default to off so "default threshold"
    /// remains compatible with earlier EVA releases.
    static func defaults(for kind: EyeArtifactKind) -> EyeArtifactThresholdConfiguration {
        switch kind {
        case .blink:
            return EyeArtifactThresholdConfiguration(
                amplitudeMinMicrovolts: 150,
                amplitudeMaxMicrovolts: 0,
                riseWindowSeconds: 0,
                velocityEnabled: false,
                velocityThresholdMicrovoltsPerMillisecond: 5,
                accelerationEnabled: false,
                accelerationThresholdMicrovoltsPerMillisecondSquared: 2,
                minDurationSeconds: 0.05,
                maxDurationSeconds: 1,
                mergeGapSeconds: 0.25,
                polarity: .bipolar,
                channelOverride: nil
            )
        case .movement:
            return EyeArtifactThresholdConfiguration(
                amplitudeMinMicrovolts: 150,
                amplitudeMaxMicrovolts: 0,
                riseWindowSeconds: 0,
                velocityEnabled: false,
                velocityThresholdMicrovoltsPerMillisecond: 3,
                accelerationEnabled: false,
                accelerationThresholdMicrovoltsPerMillisecondSquared: 1,
                minDurationSeconds: 0.05,
                maxDurationSeconds: 1,
                mergeGapSeconds: 0.25,
                polarity: .bipolar,
                channelOverride: nil
            )
        }
    }

    // MARK: - Flat eva.xml parameters (human-readable, one <param> per field)

    /// Emits each field as its own prefixed key (e.g. `blink.amplitudeMinMicrovolts`),
    /// so eva.xml stays readable to naive parsers instead of a JSON blob.
    func flatParameters(prefix: String) -> [String: String] {
        var p: [String: String] = [
            "\(prefix).amplitudeMinMicrovolts": Self.num(amplitudeMinMicrovolts),
            "\(prefix).amplitudeMaxMicrovolts": Self.num(amplitudeMaxMicrovolts),
            "\(prefix).riseWindowSeconds": Self.num(riseWindowSeconds),
            "\(prefix).minDurationSeconds": Self.num(minDurationSeconds),
            "\(prefix).maxDurationSeconds": Self.num(maxDurationSeconds),
            "\(prefix).mergeGapSeconds": Self.num(mergeGapSeconds),
            "\(prefix).polarity": polarity.rawValue,
            "\(prefix).velocityEnabled": "\(velocityEnabled)",
            "\(prefix).velocityThreshold": Self.num(velocityThresholdMicrovoltsPerMillisecond),
            "\(prefix).accelerationEnabled": "\(accelerationEnabled)",
            "\(prefix).accelerationThreshold": Self.num(accelerationThresholdMicrovoltsPerMillisecondSquared)
        ]
        if let channels = channelOverride, !channels.isEmpty {
            p["\(prefix).channels"] = channels.map { String($0 + 1) }.joined(separator: ",") // 1-based
        }
        return p
    }

    /// Rebuilds a config from flat params, starting from `base` for any missing key.
    static func fromFlatParameters(_ p: [String: String], prefix: String,
                                   base: EyeArtifactThresholdConfiguration) -> EyeArtifactThresholdConfiguration {
        var c = base
        if let v = p["\(prefix).amplitudeMinMicrovolts"].flatMap(Float.init) { c.amplitudeMinMicrovolts = v }
        if let v = p["\(prefix).amplitudeMaxMicrovolts"].flatMap(Float.init) { c.amplitudeMaxMicrovolts = v }
        if let v = p["\(prefix).riseWindowSeconds"].flatMap(Double.init) { c.riseWindowSeconds = v }
        if let v = p["\(prefix).minDurationSeconds"].flatMap(Double.init) { c.minDurationSeconds = v }
        if let v = p["\(prefix).maxDurationSeconds"].flatMap(Double.init) { c.maxDurationSeconds = v }
        if let v = p["\(prefix).mergeGapSeconds"].flatMap(Double.init) { c.mergeGapSeconds = v }
        if let v = p["\(prefix).polarity"].flatMap(EyeArtifactPolarity.init(rawValue:)) { c.polarity = v }
        if let v = p["\(prefix).velocityEnabled"] { c.velocityEnabled = (v == "true") }
        if let v = p["\(prefix).velocityThreshold"].flatMap(Float.init) { c.velocityThresholdMicrovoltsPerMillisecond = v }
        if let v = p["\(prefix).accelerationEnabled"] { c.accelerationEnabled = (v == "true") }
        if let v = p["\(prefix).accelerationThreshold"].flatMap(Float.init) { c.accelerationThresholdMicrovoltsPerMillisecondSquared = v }
        if let s = p["\(prefix).channels"] {
            let idx = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { $0 - 1 }
            c.channelOverride = idx.isEmpty ? nil : idx
        }
        return c
    }

    /// Compact numeric string (drops trailing `.0` for whole numbers).
    private static func num(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
    private static func num(_ value: Float) -> String { num(Double(value)) }
}
