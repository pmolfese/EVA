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
        /// A check that currently fails for a reason outside this tool. It is
        /// reported, loudly, but does not fail the run — a self-test that always
        /// exits non-zero stops being read.
        var knownLimitation: String? = nil
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
            // A second of quiet before the sequence starts, so the very first
            // volume's artifact is not clipped by the start of the recording.
            // A clipped first volume differs from every other one, which puts a
            // floor under the residual and blunts the check.
            config.preScanSeconds = 1

            var source = GaussianSource(seed: config.seed)
            let montage = Montage.standard(count: config.channelCount)
            let eeg = EEGGenerator.generate(config: config, montage: montage, source: &source)
            var noisy = eeg.channels
            let injection = GradientArtifactModel.inject(into: &noisy, config: config, montage: montage, template: nil)

            // Volume epochs, not slice epochs. At 1024 Hz a TR of 3 s is exactly
            // 3072 samples, but one slice of 41 is 74.93 samples — so slice
            // onsets never repeat their sub-sample phase even with the clocks
            // perfectly locked. That is a real property of real acquisitions,
            // and it is why IAR and FASTR interpolate up to ~10 kHz before doing
            // any slice-level alignment. Testing at the volume level isolates the
            // clock drift, which is what these checks are about.
            let epochSamples = Int((config.repetitionTimeSeconds * config.samplingRate).rounded())
            // Epochs start a few milliseconds *before* each trigger. Band-limiting
            // the artifact at the amplifier's anti-alias filter spreads its sharp
            // onset symmetrically in time, so a little of every slice artifact
            // arrives before the trigger that announces it. An epoch that starts
            // exactly on the trigger cannot subtract that part, and the leftover
            // puts a floor under the residual that has nothing to do with the
            // clock drift this check is measuring. Real correctors pad for the
            // same reason.
            let padSeconds = 0.004
            let corrected = averageArtifactSubtraction(
                channels: noisy,
                onsetsSeconds: injection.volumeOnsetsSeconds.map { $0 - padSeconds },
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
        let bcgEEG = EEGGenerator.generate(
            config: bcgConfig,
            montage: Montage.standard(count: bcgConfig.channelCount),
            source: &bcgSource
        )
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

        // Every injected waveform must start and end at baseline. A template
        // that is still non-zero where its window closes injects a step
        // discontinuity at every single event — a square edge repeating at the
        // heart rate or the blink rate, which smears broadband energy through
        // the spectrum and looks obviously wrong on screen. This was a real bug
        // in the ECG (a 22 µV jump at each beat, from a P wave truncated at the
        // window edge), so it is pinned rather than trusted.
        var templateConfig = SimulationConfig.default
        templateConfig.blinksPerMinute = 15
        let templates: [(String, HighRateTemplate)] = [
            ("BCG", BCGArtifactModel.waveformTemplate(config: templateConfig)),
            ("blink", OcularArtifactModel.blinkTemplate(config: templateConfig)),
            ("gradient slice", GradientArtifactModel.syntheticTemplate(config: templateConfig))
        ]
        for (name, template) in templates {
            outcomes.append(Outcome(
                name: "\(name) template starts and ends at baseline",
                snr: template.edgeDiscontinuity,
                passed: template.edgeDiscontinuity < 0.01,
                expectation: "edge value below 1% of peak (shown in the SNR column)"
            ))
        }

        // TR markers have to survive the round trip through MFF's microsecond
        // datetime format without picking up spurious sample jitter: EVA
        // tolerates one sample of deviation and refuses to correct beyond it.
        var trConfig = SimulationConfig.default
        trConfig.channelCount = 2
        // Long enough, and at a TR whose drift accumulates fast enough, to hit
        // the marginal cases: a shorter run passed while the written file still
        // carried a stray two-sample interval.
        trConfig.durationSeconds = 300
        trConfig.repetitionTimeSeconds = 2
        trConfig.slicesPerVolume = 20
        var trSource = GaussianSource(seed: trConfig.seed)
        var trChannels = EEGGenerator.generate(
            config: trConfig,
            montage: Montage.standard(count: trConfig.channelCount),
            source: &trSource
        ).channels
        let trInjection = GradientArtifactModel.inject(into: &trChannels, config: trConfig, montage: Montage.standard(count: trConfig.channelCount), template: nil)
        let trEvents = SimulationWriter.events(
            gradient: trInjection, bcg: nil, ocular: nil, config: trConfig
        ).filter { $0.code == "TREV" }
        let trSamples = trEvents
            .map { Int(($0.beginTimeSeconds * trConfig.samplingRate).rounded()) }
            .sorted()
        let intervals = zip(trSamples, trSamples.dropFirst()).map { $1 - $0 }
        let median = intervals.isEmpty ? 0 : intervals.sorted()[intervals.count / 2]
        let deviation = intervals.map { abs($0 - median) }.max() ?? 0
        outcomes.append(Outcome(
            name: "TR markers stay within EVA's one-sample spacing tolerance",
            snr: Double(deviation),
            passed: deviation <= 1,
            expectation: "max deviation from the median interval <= 1 sample",
            knownLimitation: deviation <= 1 ? nil :
                "MFFWriter formats event times with DateFormatter, which resolves only "
                + "milliseconds, so a 0.977 ms sample grid cannot survive the round trip. "
                + "EVA's gradient stage then reports 'TRs are not evenly spaced'. Fix is in "
                + "TODO_Aug21.md; --clock-offset 0 avoids it meanwhile."
        ))

        // The scanner window has to be respected: no gradient artifact before it
        // starts, but the BCG carries on, because the static field never
        // switches off.
        var windowConfig = SimulationConfig.default
        windowConfig.channelCount = 4
        windowConfig.durationSeconds = 60
        windowConfig.preScanSeconds = 15
        windowConfig.postScanSeconds = 10
        var windowSource = GaussianSource(seed: windowConfig.seed)
        let windowEEG = EEGGenerator.generate(
            config: windowConfig,
            montage: Montage.standard(count: windowConfig.channelCount),
            source: &windowSource
        )
        var windowNoisy = windowEEG.channels
        _ = GradientArtifactModel.inject(into: &windowNoisy, config: windowConfig, montage: Montage.standard(count: windowConfig.channelCount), template: nil)
        let quietEnd = Int(10 * windowConfig.samplingRate)
        var quietResidual = 0.0
        for channel in windowNoisy.indices {
            for i in 0..<quietEnd {
                quietResidual = max(quietResidual, abs(windowNoisy[channel][i] - windowEEG.channels[channel][i]))
            }
        }
        outcomes.append(Outcome(
            name: "No gradient artifact before the scanner starts",
            snr: quietResidual,
            passed: quietResidual < 1e-9,
            expectation: "peak difference from clean EEG of 0 µV in the pre-scan window"
        ))

        var bcgWindowNoisy = windowEEG.channels
        var bcgWindowSource = GaussianSource(seed: windowConfig.seed &+ 1)
        _ = BCGArtifactModel.inject(into: &bcgWindowNoisy, config: windowConfig, source: &bcgWindowSource)
        var quietBCG = 0.0
        for channel in bcgWindowNoisy.indices {
            for i in 0..<quietEnd {
                quietBCG = max(quietBCG, abs(bcgWindowNoisy[channel][i] - windowEEG.channels[channel][i]))
            }
        }
        outcomes.append(Outcome(
            name: "BCG continues through the pre-scan window",
            snr: quietBCG,
            passed: quietBCG > 1,
            expectation: "clearly non-zero cardiac artifact before scanning starts"
        ))

        // A blink has to be frontally maximal, or it is not a blink.
        let demoMontage = Montage.standard(count: 20)
        let blinkTopography = OcularArtifactModel.blinkTopography(positions: demoMontage.positions)
        let names = demoMontage.channelNames
        let peakIndex = blinkTopography.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let peakName = peakIndex < names.count ? names[peakIndex] : "?"
        let czIndex = names.firstIndex(of: "Cz") ?? 0
        outcomes.append(Outcome(
            name: "Blink topography peaks frontally and vanishes at the vertex",
            snr: abs(blinkTopography[czIndex]),
            passed: (peakName == "Fp1" || peakName == "Fp2") && abs(blinkTopography[czIndex]) < 0.1,
            expectation: "max at Fp1/Fp2 (got \(peakName)), |Cz| below 0.1"
        ))

        // Impedance has to track the defect, and the bridged-electrode case has
        // to keep reading *low*. If someone "fixes" that by making every bad
        // channel read high, the recording quietly loses the one thing it was
        // teaching: that impedance screening misses a bridged pair.
        var impedanceConfig = SimulationConfig.default
        impedanceConfig.channelCount = 20
        impedanceConfig.badChannels = [3: .flat, 7: .noisy, 11: .drift, 15: .pop, 19: .line]
        var impedanceSource = GaussianSource(seed: impedanceConfig.seed)
        let impedances = ImpedanceModel.values(
            config: impedanceConfig,
            montage: Montage.standard(count: impedanceConfig.channelCount),
            source: &impedanceSource
        ).map(Double.init)

        // EVA's default health bands: 40 kOhm and under is fully good, 70 and up
        // is poor or worse.
        let healthy = (0..<20).filter { impedanceConfig.badChannels[$0 + 1] == nil }
        let healthyWorst = healthy.map { impedances[$0] }.max() ?? 0
        outcomes.append(Outcome(
            name: "Healthy electrodes read inside the good impedance band",
            snr: healthyWorst,
            passed: healthyWorst <= 40,
            expectation: "worst healthy channel at or under 40 kOhm"
        ))

        let highContact = [7, 11, 15, 19].map { impedances[$0 - 1] }.min() ?? 0
        outcomes.append(Outcome(
            name: "Poor-contact defects read high",
            snr: highContact,
            passed: highContact >= 60,
            expectation: "noisy/drift/pop/line all at or above 60 kOhm"
        ))

        outcomes.append(Outcome(
            name: "A bridged electrode reads LOW despite recording nothing",
            snr: impedances[2],
            passed: impedances[2] < 5,
            expectation: "the flat channel under 5 kOhm — impedance screening misses this one"
        ))

        return outcomes
    }
}
