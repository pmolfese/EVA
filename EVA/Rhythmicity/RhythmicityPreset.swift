//
//  RhythmicityPreset.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//

import Foundation

nonisolated enum RhythmicityPreset {
    /// A stable default makes command-line/tests reproducible and lets exact
    /// reruns reuse completed per-channel significance results. The resolved
    /// seed always remains part of the result and cache configuration.
    static let defaultPaperSeed: UInt64 = 0x4c41_5649_3230_3236

    static let paperLAVI2026 = RhythmicityConfiguration(
        presetID: "lavi-paper-2026",
        frequenciesHz: (0...46).map { index in
            pow(10.0, 0.5 + 0.025 * Double(index))
        },
        morletWidthCycles: 5.0,
        laviLagCycles: 1.5,
        wtplLagCycles: [-1.0, 1.0],
        alphaAnchorHz: 6.0...14.0,
        significance: .onDemand(
            LAVIOnDemandSignificanceConfiguration(
                repetitions: 200,
                seed: defaultPaperSeed,
                alpha: 0.05,
                tailRule: .fifthOrderStatisticPerFrequency,
                aperiodicFitRangeHz: pow(10.0, 0.5)...pow(10.0, 1.65),
                excludedFitRangesHz: [],
                amplitudeDistribution: .observedSamples,
                iaaft: .paper2026,
                nonconvergencePolicy: .retainAndReport
            )
        ),
        edgePolicy: .validOnly,
        precision: .float64,
        backend: .accelerateFFTCPU,
        computePolicy: .productionDefault
    )

    static func paperLAVI2026(seed: UInt64) -> RhythmicityConfiguration {
        var configuration = paperLAVI2026
        guard case var .onDemand(significance) = configuration.significance else {
            return configuration
        }
        significance.seed = seed
        configuration.significance = .onDemand(significance)
        return configuration
    }

    /// Explicitly exploratory form used by the direct numerical oracle and
    /// bounded diagnostics that should not launch 200 surrogate analyses.
    static var paperLAVI2026Exploratory: RhythmicityConfiguration {
        var configuration = paperLAVI2026
        configuration.significance = .none
        return configuration
    }
}
