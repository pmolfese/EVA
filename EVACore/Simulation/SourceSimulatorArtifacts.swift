//
//  SourceSimulatorArtifacts.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-3 Stage 3b — physiological artifacts injected on top of the clean source
//  field so the user can *see how an artifact moves an estimate* (a blink pulling
//  a fitted dipole frontward, EMG raising posterior power, and so on). This
//  reuses the simulator's own in-module artifact generators — the same code the
//  CLI uses — driven by the Source Simulator's parametric `Montage`, and keeps
//  each artifact's own truth (timing) so the contamination is scoreable, not
//  merely decorative.
//

import Foundation

nonisolated enum SourceSimulatorArtifacts {

    /// Which artifacts to inject and how strong. Each maps onto the fields the
    /// corresponding in-module generator already reads.
    struct Options: Sendable, Equatable {
        var blink = false
        var blinkAmplitudeMicrovolts = 100.0
        var blinksPerMinute = 12.0

        var saccade = false
        var saccadesPerMinute = 20.0
        var eyeMovementAmplitudeMicrovolts = 80.0

        var emg = false
        var emgAmplitudeMicrovolts = 30.0
        var emgBurstsPerMinute = 10.0

        var bcg = false
        var bcgAmplitudeMicrovolts = 40.0

        var seed: UInt64 = 7

        var anyEnabled: Bool { blink || saccade || emg || bcg }
    }

    /// Timing truth for each injected artifact — enough to score localization
    /// drift against, and to write into the recording's sidecar.
    struct Truth: Codable, Sendable, Equatable {
        var blinkSeconds: [Double] = []
        var saccadeSeconds: [Double] = []
        var emgBurstSeconds: [Double] = []
        var bcgBeatSeconds: [Double] = []
    }

    /// Injects the enabled artifacts into a fresh `channelCount × samples` matrix
    /// and returns that contamination plus its truth. Duration / rate / channel
    /// count mirror the source field so the matrices align sample-for-sample.
    static func inject(
        montage: Montage,
        channelCount: Int,
        samplingRate: Double,
        durationSeconds: Double,
        options: Options
    ) -> (channels: [[Double]], truth: Truth) {
        let n = max(1, Int((durationSeconds * samplingRate).rounded()))
        var channels = [[Double]](repeating: [Double](repeating: 0, count: n), count: channelCount)
        var truth = Truth()
        guard options.anyEnabled else { return (channels, truth) }

        var config = SimulationConfig()
        config.channelCount = channelCount
        config.samplingRate = samplingRate
        config.durationSeconds = durationSeconds
        // Start from a silent config — the base defaults enable gradient + BCG.
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.blinksPerMinute = 0
        config.saccadesPerMinute = 0
        config.emg = nil

        if options.blink || options.saccade {
            config.blinksPerMinute = options.blink ? options.blinksPerMinute : 0
            config.blinkAmplitudeMicrovolts = options.blinkAmplitudeMicrovolts
            config.saccadesPerMinute = options.saccade ? options.saccadesPerMinute : 0
            config.eyeMovementAmplitudeMicrovolts = options.eyeMovementAmplitudeMicrovolts
            var source = GaussianSource(seed: options.seed)
            let injection = OcularArtifactModel.inject(into: &channels, config: config, montage: montage, source: &source)
            truth.blinkSeconds = injection.blinkSeconds
            truth.saccadeSeconds = injection.saccadeSeconds
        }

        if options.emg {
            config.emg = EMGConfig(
                burstsPerMinute: options.emgBurstsPerMinute,
                amplitudeMicrovolts: options.emgAmplitudeMicrovolts
            )
            var source = GaussianSource(seed: options.seed &+ 101)
            if let injection = EMGArtifactModel.inject(into: &channels, config: config, montage: montage, source: &source) {
                truth.emgBurstSeconds = injection.bursts.map(\.onsetSeconds)
            }
        }

        if options.bcg {
            config.bcgEnabled = true
            config.bcgAmplitudeMicrovolts = options.bcgAmplitudeMicrovolts
            var source = GaussianSource(seed: options.seed &+ 202)
            let injection = BCGArtifactModel.inject(into: &channels, config: config, montage: montage, source: &source)
            truth.bcgBeatSeconds = injection.trueBeatSeconds
        }

        return (channels, truth)
    }
}
