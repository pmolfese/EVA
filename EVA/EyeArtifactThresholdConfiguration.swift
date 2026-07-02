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
    /// merge, bipolar, auto channels) as the seed for each kind. Kinds share
    /// defaults today; split here if they diverge.
    static func defaults(for kind: EyeArtifactKind) -> EyeArtifactThresholdConfiguration {
        switch kind {
        case .blink:
            // A blink is a fast, brief deflection: it peaks within ~100 ms of
            // onset and rarely lasts beyond ~500 ms. The rise window and max
            // duration reject slow drifts that a bare amplitude threshold lets
            // linger for seconds.
            return EyeArtifactThresholdConfiguration(
                amplitudeMinMicrovolts: 150,
                amplitudeMaxMicrovolts: 0,
                riseWindowSeconds: 0.1,
                velocityEnabled: false,
                velocityThresholdMicrovoltsPerMillisecond: 5,
                accelerationEnabled: false,
                accelerationThresholdMicrovoltsPerMillisecondSquared: 2,
                minDurationSeconds: 0.05,
                maxDurationSeconds: 0.5,
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
                maxDurationSeconds: 0,
                mergeGapSeconds: 0.25,
                polarity: .bipolar,
                channelOverride: nil
            )
        }
    }
}
