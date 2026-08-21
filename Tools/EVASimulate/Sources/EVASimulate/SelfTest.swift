//
//  SelfTest.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A harness that produces plausible-looking data but does not actually
//  reproduce the phenomenon under study is worse than no harness, because every
//  number it emits looks like evidence. These checks pin the two behaviours the
//  whole model is built to exhibit, using a deliberately minimal average-artifact
//  subtraction written here rather than borrowed from EVA — the point is to test
//  the *data*, so the corrector has to be something simple enough to be
//  obviously correct.
//
//  1. With the EEG and MRI clocks locked (--clock-offset 0) and a TR that is a
//     whole number of samples, every volume's artifact is bit-for-bit the same,
//     so an average template cancels it *exactly*. What is left is not artifact
//     at all but the averaged EEG the template picked up along the way, whose
//     standard deviation is std(EEG)/sqrt(N) over N epochs. So the expected SNR
//     is not "large", it is sqrt(N) — a number the check can pin precisely.
//  2. With the paper's measured 152 µs/s drift, the same subtraction lands far
//     below that ceiling, because the artifacts no longer repeat their
//     sub-sample phase.
//
//  If (1) drifts away from sqrt(N), the model has picked up an unintended source
//  of epoch-to-epoch variation, or template subtraction has stopped being exact.
//  If (2) ever approaches it, the clock model has stopped working and every
//  correction method the harness scores will look better than it is.
//

import Foundation

nonisolated enum SelfTest {

    /// Textbook average-artifact subtraction: average every epoch at the given
    /// onsets, subtract that template from each. No alignment, no scaling, no
    /// OBS — this is Allen (1998) with nothing added.
    static func averageArtifactSubtraction(
        channels: [[Double]],
        onsetsSeconds: [Double],
        epochSamples: Int,
        samplingRate: Double
    ) -> [[Double]] {
        var corrected = channels
        guard epochSamples > 0 else { return corrected }

        let starts = onsetsSeconds.map { Int(($0 * samplingRate).rounded(.down)) }

        for channel in channels.indices {
            var template = [Double](repeating: 0, count: epochSamples)
            var contributing = 0
            for start in starts {
                guard start >= 0, start + epochSamples <= channels[channel].count else { continue }
                for i in 0..<epochSamples { template[i] += channels[channel][start + i] }
                contributing += 1
            }
            guard contributing > 0 else { continue }
            for i in 0..<epochSamples { template[i] /= Double(contributing) }

            for start in starts {
                guard start >= 0, start + epochSamples <= corrected[channel].count else { continue }
                for i in 0..<epochSamples { corrected[channel][start + i] -= template[i] }
            }
        }
        return corrected
    }

    struct Outcome {
        var name: String
        var snr: Double
        var passed: Bool
        var expectation: String
    }

    static func run() -> [Outcome] {
        var outcomes: [Outcome] = []

        func gradientOnlyRun(clockOffset: Double) -> (clean: [[Double]], corrected: [[Double]], config: SimulationConfig) {
            var config = SimulationConfig.default
            config.channelCount = 4
            config.durationSeconds = 60
            config.bcgEnabled = false
            config.slowModulationFraction = 0
            config.clockOffsetMicrosecondsPerSecond = clockOffset

            var source = GaussianSource(seed: config.seed)
            let eeg = EEGGenerator.generate(config: config, source: &source)
            var noisy = eeg.channels
            let injection = GradientArtifactModel.inject(into: &noisy, config: config, template: nil)

            // Volume epochs, not slice epochs. At 1024 Hz a TR of 3 s is exactly
            // 3072 samples, but one slice of 41 is 74.93 samples — so slice
            // onsets never repeat their sub-sample phase even with the clocks
            // perfectly locked. That is a real property of real acquisitions,
            // and it is why IAR and FASTR interpolate up to ~10 kHz before doing
            // any slice-level alignment. Testing at the volume level isolates the
            // clock drift, which is what these checks are about.
            let epochSamples = Int((config.repetitionTimeSeconds * config.samplingRate).rounded())
            let corrected = averageArtifactSubtraction(
                channels: noisy,
                onsetsSeconds: injection.volumeOnsetsSeconds,
                epochSamples: epochSamples,
                samplingRate: config.samplingRate
            )
            return (eeg.channels, corrected, config)
        }

        let locked = gradientOnlyRun(clockOffset: 0)
        let lockedScore = SNRMetrics.score(
            label: "locked clocks",
            clean: locked.clean,
            corrected: locked.corrected,
            samplingRate: locked.config.samplingRate
        )
        // With the artifact cancelling exactly, the only residual is the EEG the
        // template averaged in: std(EEG)/sqrt(N), so SNR should sit at sqrt(N).
        let ceiling = Double(locked.config.volumeCount).squareRoot()
        outcomes.append(Outcome(
            name: "Locked clocks: template subtraction cancels the artifact exactly",
            snr: lockedScore.broadbandSNR,
            passed: lockedScore.broadbandSNR > 0.75 * ceiling && lockedScore.broadbandSNR < 1.35 * ceiling,
            expectation: String(format: "SNR near sqrt(%d) = %.2f, the averaged-EEG ceiling",
                                locked.config.volumeCount, ceiling)
        ))

        let drifting = gradientOnlyRun(clockOffset: 152)
        let driftingScore = SNRMetrics.score(
            label: "152 µs/s drift",
            clean: drifting.clean,
            corrected: drifting.corrected,
            samplingRate: drifting.config.samplingRate
        )
        outcomes.append(Outcome(
            name: "Drifting clocks: the same subtraction leaves a residual",
            snr: driftingScore.broadbandSNR,
            passed: driftingScore.broadbandSNR < lockedScore.broadbandSNR / 4,
            expectation: String(format: "SNR far below the locked-clock %.2f", lockedScore.broadbandSNR)
        ))

        // The BCG's beat-to-beat variability has to survive averaging too,
        // otherwise cardiac correction is trivially solved and every method
        // scores the same.
        var bcgConfig = SimulationConfig.default
        bcgConfig.channelCount = 4
        bcgConfig.durationSeconds = 60
        bcgConfig.gradientEnabled = false
        var bcgSource = GaussianSource(seed: bcgConfig.seed)
        let bcgEEG = EEGGenerator.generate(config: bcgConfig, source: &bcgSource)
        var bcgNoisy = bcgEEG.channels
        let bcgInjection = BCGArtifactModel.inject(into: &bcgNoisy, config: bcgConfig, source: &bcgSource)

        let beatEpoch = Int((bcgConfig.bcgWaveformSeconds * bcgConfig.samplingRate).rounded(.down))
        let atTrueBeats = averageArtifactSubtraction(
            channels: bcgNoisy,
            onsetsSeconds: bcgInjection.trueBeatSeconds,
            epochSamples: beatEpoch,
            samplingRate: bcgConfig.samplingRate
        )
        let atDetectedBeats = averageArtifactSubtraction(
            channels: bcgNoisy,
            onsetsSeconds: bcgInjection.detectedBeatSeconds,
            epochSamples: beatEpoch,
            samplingRate: bcgConfig.samplingRate
        )
        let trueScore = SNRMetrics.score(
            label: "AAS at true beats", clean: bcgEEG.channels,
            corrected: atTrueBeats, samplingRate: bcgConfig.samplingRate
        )
        let detectedScore = SNRMetrics.score(
            label: "AAS at detected beats", clean: bcgEEG.channels,
            corrected: atDetectedBeats, samplingRate: bcgConfig.samplingRate
        )
        outcomes.append(Outcome(
            name: "QRS jitter penalizes timing-dependent correction",
            snr: detectedScore.broadbandSNR,
            passed: detectedScore.broadbandSNR < trueScore.broadbandSNR,
            expectation: String(format: "worse than the %.2f SNR at true beat times", trueScore.broadbandSNR)
        ))

        return outcomes
    }
}
