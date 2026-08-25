//
//  GroupSimulation.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Multi-subject and group simulation (roadmap 3.1).
//
//  ## What a group simulation has to provide that a single recording does not
//
//  It would be easy to read 3.1 as "run the generator N times with different
//  seeds". That produces N recordings and tests nothing: N draws from one
//  distribution have no between-subject structure, so a mixed-effects model
//  fitted to them is estimating a variance component that is zero by
//  construction, and it will look like it works no matter what it does.
//
//  A group study has **two** levels, and both need ground truth:
//
//  * **The population parameter** — the effect that exists in the population,
//    which a group analysis is trying to recover. Here that is the ERP condition
//    difference at `populationEffectMicrovolts`.
//  * **Between-subject variance** — how much each subject departs from it, drawn
//    from declared distributions and recorded per subject.
//
//  Both are written to `group_truth.json`, so a group-level result can be scored
//  against the population value rather than against a single subject's
//  realization. That is the whole point of the item.
//
//  ## Covariates are known, which is unusual and useful
//
//  Each subject's drawn parameters — head size, alpha amplitude, artifact
//  severity, impedance quality, heart rate — are written to `participants.tsv`
//  in BIDS' own format. A real group analysis regresses on covariates it has
//  measured with error and often mis-specified; here the covariates are exact.
//  That makes it possible to ask a question real data cannot answer cleanly:
//  how much of a group result survives when the covariate structure is known
//  perfectly, and how much was covariate mis-specification all along.
//
//  ## Determinism
//
//  Subject seeds are derived from the group seed and the subject index, so the
//  draws are **prefix-stable**: generating 20 subjects produces the same first
//  10 as generating 10. Growing a simulated cohort must not resample the
//  subjects already in it, for the same reason `DipoleEEGGenerator.stableDirection`
//  keeps source 1...N fixed when source N+1 is added.
//

import Foundation

/// Between-subject variability, each declared as a standard deviation.
///
/// Defaults are plausible adult values, not measured ones — they are here to
/// make a cohort look like a cohort, and any claim that turns on their exact
/// size is weak evidence. Set them to zero for a homogeneous cohort, which is a
/// useful negative control: a group method that finds structure in *that* is
/// finding noise.
nonisolated struct GroupVariation: Codable, Sendable {
    /// Head radius, as a fraction of the base model. Adult head size varies by
    /// several percent, and it matters more than it sounds: it changes the
    /// forward model, so every subject's topography differs even for identical
    /// sources.
    var headRadiusSD: Double = 0.05
    /// Electrode placement, in degrees. Cap placement is never twice the same.
    var electrodePlacementSDDegrees: Double = 3
    /// Alpha amplitude, as a fraction. Genuinely large between people.
    var alphaAmplitudeSD: Double = 0.35
    /// BCG amplitude, as a fraction — artifact severity.
    var bcgAmplitudeSD: Double = 0.30
    /// Contact impedance, as a fraction — recording quality.
    var impedanceSD: Double = 0.30
    /// Mean heart rate, in bpm.
    var heartRateSDBPM: Double = 8
    /// The ERP condition difference, as a fraction of the population effect.
    /// This is the between-subject variance a mixed-effects model exists to
    /// estimate.
    var erpEffectSD: Double = 0.30

    static let none = GroupVariation(
        headRadiusSD: 0, electrodePlacementSDDegrees: 0, alphaAmplitudeSD: 0,
        bcgAmplitudeSD: 0, impedanceSD: 0, heartRateSDBPM: 0, erpEffectSD: 0
    )
}

/// What one simulated subject actually drew.
nonisolated struct SubjectDraw: Codable, Sendable {
    var label: String
    var seed: UInt64
    var headRadiusScale: Double
    var electrodePlacementDegrees: Double
    var alphaAmplitudeScale: Double
    var bcgAmplitudeScale: Double
    var impedanceScale: Double
    var heartRateBPM: Double
    /// Multiplier on the population ERP condition difference.
    var erpEffectScale: Double
    /// This subject's realized condition difference, in µV. Nil when the
    /// scenario has no ERP.
    var erpEffectMicrovolts: Double?
}

nonisolated struct GroupTruth: Codable, Sendable {
    var subjectCount: Int
    var groupSeed: UInt64
    var variation: GroupVariation
    /// The population-level ERP condition difference the cohort was drawn
    /// around. A group analysis should recover this, not any one subject's value.
    var populationEffectMicrovolts: Double?
    var subjects: [SubjectDraw]
    /// Between-subject standard deviations actually realized. Reported because a
    /// requested SD and a realized SD are different things at small N, and a
    /// group study run on 8 subjects should not be read as if it had the
    /// requested spread.
    var realizedBetweenSubjectSD: [String: Double]
}

nonisolated enum GroupSimulation {

    static func subjectSeed(groupSeed: UInt64, index: Int) -> UInt64 {
        SimulationSeedStreams.subject(base: groupSeed, index: index)
    }

    /// Draws one subject's parameters. Depends only on the group seed and the
    /// index, never on the cohort size, which is what makes the draws
    /// prefix-stable.
    static func draw(
        index: Int, groupSeed: UInt64, variation: GroupVariation, base: SimulationConfig
    ) -> SubjectDraw {
        var random = GaussianSource(seed: subjectSeed(groupSeed: groupSeed, index: index))
        // A fixed draw order: adding a varied parameter later must not shuffle
        // the ones already drawn, so new parameters append here rather than
        // being inserted.
        let headRadius = 1 + variation.headRadiusSD * random.gaussian()
        let placement = variation.electrodePlacementSDDegrees * abs(random.gaussian())
        let alpha = max(0.05, 1 + variation.alphaAmplitudeSD * random.gaussian())
        let bcg = max(0.05, 1 + variation.bcgAmplitudeSD * random.gaussian())
        let impedance = max(0.1, 1 + variation.impedanceSD * random.gaussian())
        let midRate = (base.heartRateMinBPM + base.heartRateMaxBPM) / 2
        let heartRate = max(40, midRate + variation.heartRateSDBPM * random.gaussian())
        let effect = 1 + variation.erpEffectSD * random.gaussian()

        return SubjectDraw(
            label: String(format: "%02d", index + 1),
            seed: subjectSeed(groupSeed: groupSeed, index: index),
            headRadiusScale: max(0.7, headRadius),
            electrodePlacementDegrees: placement,
            alphaAmplitudeScale: alpha,
            bcgAmplitudeScale: bcg,
            impedanceScale: impedance,
            heartRateBPM: heartRate,
            erpEffectScale: effect,
            erpEffectMicrovolts: populationEffect(base).map { $0 * effect }
        )
    }

    /// Applies a subject's draw to the base configuration.
    static func configure(_ base: SimulationConfig, with subject: SubjectDraw) -> SimulationConfig {
        var config = base
        config.seed = subject.seed

        // Head size scales every shell, so the conductivity structure is
        // preserved and only the geometry changes.
        var head = config.sphericalHeadModel
        head.shells = head.shells.map {
            HeadShell(
                name: $0.name,
                radiusMeters: $0.radiusMeters * subject.headRadiusScale,
                conductivitySiemensPerMeter: $0.conductivitySiemensPerMeter
            )
        }
        head.name = "\(head.name) (subject \(subject.label))"
        config.sphericalHeadModel = head

        config.montageJitterDegrees = subject.electrodePlacementDegrees > 0
            ? subject.electrodePlacementDegrees : nil

        config.alphaLowMicrovolts = base.alphaLowMicrovolts * subject.alphaAmplitudeScale
        config.alphaHighMicrovolts = base.alphaHighMicrovolts * subject.alphaAmplitudeScale
        config.bcgAmplitudeMicrovolts = base.bcgAmplitudeMicrovolts * subject.bcgAmplitudeScale
        config.impedanceTypicalKOhm = base.impedanceTypicalKOhm * subject.impedanceScale

        let halfRange = (base.heartRateMaxBPM - base.heartRateMinBPM) / 2
        config.heartRateMinBPM = max(35, subject.heartRateBPM - halfRange)
        config.heartRateMaxBPM = subject.heartRateBPM + halfRange

        // Scale the *condition difference*, not the whole response.
        //
        // Multiplying both amplitudes would change how large every subject's
        // ERP is while leaving target-minus-standard proportionally identical —
        // which is a gain difference, not an effect-size difference, and a
        // mixed-effects model would see no between-subject variance in the thing
        // it is estimating. Adjusting the standard ratio instead moves the
        // difference and leaves the common response nearly alone.
        if var erp = config.erp {
            if var components = erp.components {
                for index in components.indices {
                    let ratio = components[index].standardAmplitudeRatio
                    components[index].standardAmplitudeRatio =
                        1 - (1 - ratio) * subject.erpEffectScale
                }
                erp.components = components
            } else {
                erp.standardAmplitudeRatio =
                    1 - (1 - erp.standardAmplitudeRatio) * subject.erpEffectScale
            }
            config.erp = erp
        }
        return config
    }

    /// The population-level condition difference implied by a configuration, in
    /// µV — summed over components when there are several.
    static func populationEffect(_ config: SimulationConfig) -> Double? {
        guard let erp = config.erp else { return nil }
        if let components = erp.components, !components.isEmpty {
            return components.reduce(0.0) {
                $0 + $1.targetAmplitudeMicrovolts * (1 - $1.standardAmplitudeRatio)
            }
        }
        return erp.targetAmplitudeMicrovolts * (1 - erp.standardAmplitudeRatio)
    }

    static func truth(
        subjects: [SubjectDraw], groupSeed: UInt64,
        variation: GroupVariation, base: SimulationConfig
    ) -> GroupTruth {
        func spread(_ values: [Double]) -> Double {
            guard values.count > 1 else { return 0 }
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(values.count - 1)).squareRoot()
        }
        return GroupTruth(
            subjectCount: subjects.count,
            groupSeed: groupSeed,
            variation: variation,
            populationEffectMicrovolts: populationEffect(base),
            subjects: subjects,
            realizedBetweenSubjectSD: [
                "headRadiusScale": spread(subjects.map(\.headRadiusScale)),
                "alphaAmplitudeScale": spread(subjects.map(\.alphaAmplitudeScale)),
                "bcgAmplitudeScale": spread(subjects.map(\.bcgAmplitudeScale)),
                "impedanceScale": spread(subjects.map(\.impedanceScale)),
                "heartRateBPM": spread(subjects.map(\.heartRateBPM)),
                "erpEffectScale": spread(subjects.map(\.erpEffectScale))
            ]
        )
    }

    /// BIDS `participants.tsv`.
    ///
    /// Tab-separated with an `participant_id` first column, per the BIDS
    /// specification. The remaining columns are the exact drawn values — which
    /// is what makes this dataset useful for testing covariate handling rather
    /// than only group means.
    static func participantsTSV(_ truth: GroupTruth) -> String {
        var lines = [
            [
                "participant_id", "head_radius_scale", "electrode_placement_deg",
                "alpha_amplitude_scale", "bcg_amplitude_scale", "impedance_scale",
                "heart_rate_bpm", "erp_effect_scale", "erp_effect_uv"
            ].joined(separator: "\t")
        ]
        for subject in truth.subjects {
            lines.append([
                "sub-\(subject.label)",
                String(format: "%.6f", subject.headRadiusScale),
                String(format: "%.6f", subject.electrodePlacementDegrees),
                String(format: "%.6f", subject.alphaAmplitudeScale),
                String(format: "%.6f", subject.bcgAmplitudeScale),
                String(format: "%.6f", subject.impedanceScale),
                String(format: "%.6f", subject.heartRateBPM),
                String(format: "%.6f", subject.erpEffectScale),
                subject.erpEffectMicrovolts.map { String(format: "%.6f", $0) } ?? "n/a"
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
