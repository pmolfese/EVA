//
//  WaveletOversmoothingMeasurementTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  CALIBRATION, not a regression test. Gated behind EVA_CALIBRATION=1 (run via
//  scripts/calibrate.sh) so its minutes of compute stay out of the default suite,
//  the same pattern as the method-comparison harness.
//
//  It sweeps the wavelet reducer's threshold over one recording that carries both
//  sides of the question: genuine sharp BRAIN transients (K-complexes, spindles,
//  sharp waves, at physiological per-type amplitudes) that must be PRESERVED, and
//  the transient ARTIFACTS wavelet reduction is meant to REMOVE — blinks, cable
//  movement, a popping electrode, and muscle. For each threshold it reports the
//  truth-free removed-variance the app could grade on, the preservation of each
//  brain transient type, and the removal of each artifact — so we can see whether
//  the reducer separates the two, and whether any truth-free number tracks it.
//

import Foundation
import Testing
@testable import EVA

struct WaveletOversmoothingMeasurementTests {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_CALIBRATION"] == "1"
    }

    @Test func waveletPreservationVersusArtifactRemoval() async throws {
        guard Self.isEnabled else {
            print("WaveletOversmoothingMeasurementTests: set EVA_CALIBRATION=1 (scripts/calibrate.sh) to run. Skipping.")
            return
        }

        let rate = 500.0
        var config = SimulationConfig.default
        config.eegGenerationModel = .dipole
        config.recordingReference = .average
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.channelCount = 32
        config.samplingRate = rate
        config.durationSeconds = 120
        config.brainTransients = BrainTransientConfig(ratePerMinute: 30, amplitudeMicrovolts: 150)
        config.blinksPerMinute = 15
        config.emg = EMGConfig()
        config.cableMovement = CableMovementConfig()
        let popChannel = 8   // 1-based
        config.badChannels = [popChannel: .pop]

        let montage = Montage.standard(count: config.channelCount)
        var eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
        var tSource = GaussianSource(seed: config.seed &+ 0x5851_F42D_4C95_7F2D)
        guard let injection = BrainTransientModel.inject(
            into: &eeg.channels, config: config, montage: montage, source: &tSource)
        else { Issue.record("no transients"); return }
        let clean = eeg.channels   // brain + transients: the reference

        // Layer the artifacts on a copy, keeping each one's truth.
        var noisy = clean
        var ocularSource = GaussianSource(seed: SimulationSeedStreams.ocular(base: config.seed))
        let ocular = OcularArtifactModel.inject(into: &noisy, config: config, montage: montage, source: &ocularSource)
        let additional = AdditionalArtifactModel.injectAdditive(into: &noisy, config: config, montage: montage)
        var emgSource = GaussianSource(seed: config.seed &+ 99)
        _ = EMGArtifactModel.inject(into: &noisy, config: config, montage: montage, source: &emgSource)
        var defectSource = GaussianSource(seed: config.seed &+ 7)
        _ = ChannelDefectModel.apply(to: &noisy, config: config, source: &defectSource)

        let blinkChannel = ocular.blinkTopography.enumerated().max { abs($0.element) < abs($1.element) }?.offset ?? 0
        let signal = SyntheticSignal.make(noisy.map { $0.map(Float.init) }, samplingRate: rate)

        func variance(_ x: ArraySlice<Double>) -> Double {
            guard !x.isEmpty else { return 0 }
            let m = x.reduce(0, +) / Double(x.count)
            return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
        }
        func window(_ ch: Int, _ onset: Double, _ duration: Double) -> (Int, Int)? {
            let start = Int((onset * rate).rounded())
            let end = min(clean[ch].count, start + max(1, Int((duration * rate).rounded())))
            return (start >= 0 && end > start) ? (start, end) : nil
        }
        // Fraction of a brain transient preserved: 1 = intact, 0 = flattened.
        func preservation(_ corrected: [[Float]]) -> [String: Double] {
            var byType: [String: [Double]] = [:]
            for e in injection.episodes {
                guard let (s, x) = window(e.strongestChannel, e.onsetSeconds, e.durationSeconds) else { continue }
                let c = clean[e.strongestChannel][s..<x]
                let r = zip(c, corrected[e.strongestChannel][s..<x].map(Double.init)).map { $0 - $1 }[...]
                let v = variance(c)
                byType[e.type, default: []].append(v > 1e-12 ? 1 - variance(r) / v : 1)
            }
            return byType.mapValues { $0.reduce(0, +) / Double(max(1, $0.count)) }
        }
        // Fraction of an artifact removed over a window/channel: 1 = fully gone.
        func removal(_ corrected: [[Float]], channel: Int, start: Int, end: Int) -> Double {
            guard channel < clean.count, start >= 0, end > start, end <= clean[channel].count else { return 0 }
            let added = zip(noisy[channel][start..<end], clean[channel][start..<end]).map { $0 - $1 }[...]
            let residual = zip(corrected[channel][start..<end].map(Double.init), clean[channel][start..<end]).map { $0 - $1 }[...]
            let a = variance(added)
            return a > 1e-12 ? 1 - variance(residual) / a : 0
        }

        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        var lines = ["=== wavelet: brain preservation vs artifact removal (500 Hz, 120 s) ==="]
        for (label, mode) in [("HARD / continuous-EEG (bior4.4)", WaveletReductionMode.continuousEEG),
                              ("SOFT / ERP (coif4)", WaveletReductionMode.erp)] {
            lines.append("")
            lines.append("--- \(label) ---")
            lines.append("  threshold  removedVar | preserve K/spin/sharp | remove blink/move/pop/emg")
            for scale in [0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0] {
                var cfg = mode.defaultConfiguration(samplingRate: rate)
                cfg.thresholdScale = scale
                cfg.useGPU = false
                let result = WaveletReducer.reduce(
                    signal: signal, channelIndices: Array(0..<config.channelCount), configuration: cfg)
                let out = result.cleaned.data
                let removedVar = 1 - result.varianceRetainedPercent / 100
                let p = preservation(out)
                var blinkR: [Double] = []
                for t in ocular.blinkSeconds { if let (s, x) = window(blinkChannel, t - 0.2, 0.4) { blinkR.append(removal(out, channel: blinkChannel, start: s, end: x)) } }
                var moveR: [Double] = []
                for ep in additional.cableMovementEpisodes {
                    let ch = (ep.affectedChannels.first ?? 1) - 1
                    if let (s, x) = window(ch, ep.onsetSeconds, ep.durationSeconds) { moveR.append(removal(out, channel: ch, start: s, end: x)) }
                }
                let popR = removal(out, channel: popChannel - 1, start: 0, end: clean[popChannel - 1].count)
                var emgR: [Double] = []
                for ch in [0, config.channelCount - 1] { emgR.append(removal(out, channel: ch, start: 0, end: clean[ch].count)) }
                lines.append(String(format: "  %5.2f      %6.3f     | %.2f/%.2f/%.2f      | %.2f/%.2f/%.2f/%.2f",
                    scale, removedVar, p["kComplex"] ?? 1, p["spindle"] ?? 1, p["sharpWave"] ?? 1,
                    mean(blinkR), mean(moveR), popR, mean(emgR)))
            }
        }
        for line in lines { print(line) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("eva-wavelet-oversmoothing.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    }
}
