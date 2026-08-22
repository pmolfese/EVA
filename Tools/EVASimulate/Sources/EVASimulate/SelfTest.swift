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

            // Volume epochs, not slice epochs. At 1000 Hz a TR of 3 s is exactly
            // 3000 samples, but one slice of 41 is 73.17 samples — so slice
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
        let bcgInjection = BCGArtifactModel.inject(
            into: &bcgNoisy, config: bcgConfig,
            montage: Montage.standard(count: bcgConfig.channelCount), source: &bcgSource
        )

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
        // 1024 Hz is the case that used to fail: a sample is 976.5625 µs, so
        // while MFF event times were millisecond-quantized a marker could move
        // half a sample and an interval could land two samples off the median.
        // Roadmap 4.9 fixed the writer and reader, so every rate is now expected
        // to hold — and the rates whose sample period is a whole millisecond
        // (1000, 500) cannot detect a regression, which is why the paper's
        // 1024 Hz and the awkward 2048 Hz are pinned here explicitly.
        var worstTRDeviation = 0
        var trRatesPassed = true
        for rate in [1000.0, 1024.0, 500.0, 2048.0] {
            var trConfig = SimulationConfig.default
            trConfig.channelCount = 2
            trConfig.samplingRate = rate
            // Long enough, and at a TR whose drift accumulates fast enough, to
            // show that the intentional sample-grid alternation remains within
            // EVA's one-sample tolerance after the MFF timestamp round trip.
            trConfig.durationSeconds = 300
            trConfig.repetitionTimeSeconds = 2
            trConfig.slicesPerVolume = 20
            var trSource = GaussianSource(seed: trConfig.seed)
            var trChannels = EEGGenerator.generate(
                config: trConfig,
                montage: Montage.standard(count: trConfig.channelCount),
                source: &trSource
            ).channels
            let trInjection = GradientArtifactModel.inject(
                into: &trChannels, config: trConfig,
                montage: Montage.standard(count: trConfig.channelCount), template: nil
            )
            let trEvents = SimulationWriter.events(
                gradient: trInjection, bcg: nil, ocular: nil, erp: nil, config: trConfig
            ).filter { $0.code == "TREV" }
            let trSamples = trEvents
                .map { SimulationWriter.recoveredSample($0.beginTimeSeconds, samplingRate: rate) }
                .sorted()
            let intervals = zip(trSamples, trSamples.dropFirst()).map { $1 - $0 }
            let median = intervals.isEmpty ? 0 : intervals.sorted()[intervals.count / 2]
            let deviation = intervals.map { abs($0 - median) }.max() ?? 0
            worstTRDeviation = max(worstTRDeviation, deviation)
            trRatesPassed = trRatesPassed && deviation <= 1 && !intervals.isEmpty
        }
        outcomes.append(Outcome(
            name: "TR markers stay within EVA's one-sample spacing tolerance at every rate",
            snr: Double(worstTRDeviation),
            passed: trRatesPassed && SimulationConfig.default.samplingRate == 1000,
            expectation: "max interval deviation <= 1 sample at 500/1000/1024/2048 Hz"
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
        _ = BCGArtifactModel.inject(
            into: &bcgWindowNoisy, config: windowConfig,
            montage: Montage.standard(count: windowConfig.channelCount), source: &bcgWindowSource
        )
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

        // Roadmap 2.2: contact noise follows Johnson-Nyquist's sqrt(R)
        // relationship, and switching the model off exactly restores the old
        // measurement-only behaviour.
        let lowThermal = ImpedanceModel.thermalNoiseRMSMicrovolts(
            impedanceKOhm: 10, samplingRate: 1_000, temperatureKelvin: 298.15
        )
        let highThermal = ImpedanceModel.thermalNoiseRMSMicrovolts(
            impedanceKOhm: 160, samplingRate: 1_000, temperatureKelvin: 298.15
        )
        var disabledConfig = SimulationConfig.default
        disabledConfig.channelCount = 2
        disabledConfig.durationSeconds = 1
        disabledConfig.impedanceNoise = nil
        var disabledChannels = [[Double]](
            repeating: [Double](repeating: 0, count: disabledConfig.sampleCount), count: 2
        )
        var disabledSource = GaussianSource(seed: disabledConfig.seed)
        let disabledRMS = ImpedanceModel.applyThermalNoise(
            to: &disabledChannels, impedances: [10, 160],
            config: disabledConfig, source: &disabledSource
        )
        outcomes.append(Outcome(
            name: "Thermal contact noise follows sqrt(impedance) and can be disabled",
            snr: highThermal / lowThermal,
            passed: abs(highThermal / lowThermal - 4) < 1e-12
                && disabledRMS == [0, 0]
                && disabledChannels.allSatisfy { $0.allSatisfy { $0 == 0 } },
            expectation: "16x resistance gives 4x Johnson RMS; disabled coupling adds exactly nothing"
        ))

        var coupledConfig = SimulationConfig.default
        coupledConfig.channelCount = 3
        coupledConfig.durationSeconds = 2
        coupledConfig.lineNoiseHz = 60
        var coupledChannels = [[Double]](
            repeating: [Double](repeating: 0, count: coupledConfig.sampleCount), count: 3
        )
        var coupledSource = GaussianSource(seed: SimulationSeedStreams.lineNoise(base: coupledConfig.seed))
        let coupledGains = ChannelDefectModel.applyLineNoise(
            to: &coupledChannels, config: coupledConfig,
            impedances: [3, 12, 120], source: &coupledSource
        )
        outcomes.append(Outcome(
            name: "Mains pickup rises predictably with contact impedance",
            snr: coupledGains[2] / coupledGains[1],
            passed: coupledGains[0] < 0.4 * coupledGains[1]
                && coupledGains[2] > 8 * coupledGains[1],
            expectation: "3/12/120 kOhm contacts produce strongly ordered mains gains"
        ))

        var bridgeConfig = SimulationConfig.default
        bridgeConfig.channelCount = 3
        bridgeConfig.bridgedChannelPairs = [ChannelBridge(firstChannel: 1, secondChannel: 2)]
        var bridgeSource = GaussianSource(seed: SimulationSeedStreams.impedance(base: bridgeConfig.seed))
        let bridgeImpedances = ImpedanceModel.values(
            config: bridgeConfig, montage: Montage.standard(count: 3), source: &bridgeSource
        ).map(Double.init)
        outcomes.append(Outcome(
            name: "True electrode bridges retain deceptively low impedance",
            snr: max(bridgeImpedances[0], bridgeImpedances[1]),
            passed: bridgeImpedances[0] < 3 && bridgeImpedances[1] < 3
                && bridgeImpedances[2] > 3,
            expectation: "both bridged contacts read under 3 kOhm while an unbridged contact does not"
        ))

        // A dipole at the center of a homogeneous insulated sphere has the
        // closed-form surface potential 3 p·r̂ / (4πσR²). This checks the series
        // normalization and the V/(A·m) -> µV/(nA·m) unit conversion without
        // using the multilayer recurrence as its own oracle.
        do {
            let homogeneous = SphericalHeadModel(
                name: "homogeneous test sphere",
                centerMeters: .zero,
                shells: [
                    HeadShell(name: "conductor", radiusMeters: 0.085,
                              conductivitySiemensPerMeter: 0.33)
                ]
            )
            let centered = SimulatedSource(
                id: "center", positionMeters: .zero,
                orientation: Vector3D(x: 0, y: 0, z: 1),
                bandName: "test", seed: 0, rmsMomentNanoampereMeters: 1
            )
            let montage = Montage.standard(count: 20)
            let field = try SphericalForwardModel.leadField(
                head: homogeneous, montage: montage, sources: [centered],
                reference: .infinity, terms: 8
            )
            let cz = montage.channelNames.firstIndex(of: "Cz") ?? 0
            let measured = field.matrixMicrovoltsPerNanoampereMeter[cz][0]
            let expected = 1e-3 * 3 / (4 * Double.pi * 0.33 * 0.085 * 0.085)
            let relativeError = abs(measured - expected) / expected
            outcomes.append(Outcome(
                name: "Centered dipole matches the homogeneous-sphere closed form",
                snr: relativeError,
                passed: relativeError < 1e-12,
                expectation: "relative error below 1e-12"
            ))

            let equalConductivityLayers = SphericalHeadModel(
                name: "equal-conductivity layers",
                centerMeters: .zero,
                shells: [
                    HeadShell(name: "inner", radiusMeters: 0.072,
                              conductivitySiemensPerMeter: 0.33),
                    HeadShell(name: "middle", radiusMeters: 0.079,
                              conductivitySiemensPerMeter: 0.33),
                    HeadShell(name: "outer", radiusMeters: 0.085,
                              conductivitySiemensPerMeter: 0.33)
                ]
            )
            let offCenter = SimulatedSource(
                id: "off-center",
                positionMeters: Vector3D(x: 0.018, y: -0.011, z: 0.041),
                orientation: Vector3D(x: 0.3, y: 0.4, z: 0.5).normalized(),
                bandName: "test", seed: 0, rmsMomentNanoampereMeters: 1
            )
            let singleField = try SphericalForwardModel.leadField(
                head: homogeneous, montage: montage, sources: [offCenter],
                reference: .infinity, terms: 100
            )
            let layeredField = try SphericalForwardModel.leadField(
                head: equalConductivityLayers, montage: montage, sources: [offCenter],
                reference: .infinity, terms: 100
            )
            var equalityError = 0.0
            var equalityPeak = 0.0
            for channel in montage.electrodes.indices {
                let single = singleField.matrixMicrovoltsPerNanoampereMeter[channel][0]
                let layered = layeredField.matrixMicrovoltsPerNanoampereMeter[channel][0]
                equalityError = max(equalityError, abs(single - layered))
                equalityPeak = max(equalityPeak, abs(single))
            }
            let equalityRelativeError = equalityError / max(equalityPeak, 1e-30)
            outcomes.append(Outcome(
                name: "Equal-conductivity shell boundaries disappear",
                snr: equalityRelativeError,
                passed: equalityRelativeError < 1e-12,
                expectation: "three equal-conductivity layers match one homogeneous sphere"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "Centered dipole matches the homogeneous-sphere closed form",
                snr: .infinity, passed: false,
                expectation: "a valid finite lead field (\(error.localizedDescription))"
            ))
        }

        do {
            var sourceConfig = SimulationConfig.default
            sourceConfig.channelCount = 20
            sourceConfig.dipoleSourceCount = 7
            let montage = Montage.standard(count: sourceConfig.channelCount)
            let sources = DipoleEEGGenerator.makeSources(config: sourceConfig)

            func convergence(fraction: Double, terms: Int) throws -> LeadFieldConvergenceReport {
                var config = sourceConfig
                config.dipoleSourceCount = 1
                config.dipoleSourceRadiusFraction = fraction
                return try SphericalForwardModel.convergenceReport(
                    head: config.sphericalHeadModel,
                    montage: montage,
                    sources: DipoleEEGGenerator.makeSources(config: config),
                    reference: config.effectiveRecordingReference,
                    terms: terms
                )
            }

            var worstConvergenceChange = 0.0
            var convergencePassed = true
            for fraction in [0.01, 0.25, 0.50, 0.75, 0.85, 0.95, 0.999_999] {
                let report = try convergence(fraction: fraction, terms: sourceConfig.leadFieldTerms)
                worstConvergenceChange = max(
                    worstConvergenceChange, report.maximumRelativeColumnChange
                )
                convergencePassed = convergencePassed && report.converged
            }

            // A negative control that only asserts "an under-resolved field is
            // rejected" is weak: at 10 terms even the default 0.85 depth changes
            // by 0.026, so the assertion would still pass if the metric were
            // broken in a direction that always returns large values. Pin the
            // metric's *shape* instead — truncation error has to fall
            // monotonically as terms are added, at a deep eccentricity where
            // there is real error to watch shrink.
            let truncationSeries = try [10, 25, 50, 100].map {
                try convergence(fraction: 0.99, terms: $0).maximumRelativeColumnChange
            }
            let monotoneDecrease = zip(truncationSeries, truncationSeries.dropFirst())
                .allSatisfy { $0 > $1 }
            let underResolved = try convergence(fraction: 0.99, terms: 10)
            outcomes.append(Outcome(
                name: "Lead-field series convergence is checked across source eccentricity",
                snr: worstConvergenceChange,
                passed: convergencePassed
                    && worstConvergenceChange <= SphericalForwardModel.defaultConvergenceTolerance
                    && !underResolved.converged
                    && monotoneDecrease,
                expectation: "100→200 terms changes every tested depth below 1e-4; truncation error "
                    + "falls monotonically over 10/25/50/100 terms; a 10-term field is rejected"
            ))

            let averageField = try SphericalForwardModel.leadField(
                head: sourceConfig.sphericalHeadModel, montage: montage,
                sources: sources, reference: .average, terms: sourceConfig.leadFieldTerms
            )
            var worstColumnMean = 0.0
            for source in sources.indices {
                let mean = averageField.matrixMicrovoltsPerNanoampereMeter.reduce(0.0) {
                    $0 + $1[source]
                } / Double(sourceConfig.channelCount)
                worstColumnMean = max(worstColumnMean, abs(mean))
            }
            outcomes.append(Outcome(
                name: "Average-referenced lead-field columns have zero mean",
                snr: worstColumnMean,
                passed: worstColumnMean < 1e-14,
                expectation: "worst absolute column mean below 1e-14 µV/(nA·m)"
            ))

            var worstFreeColumnMean = 0.0
            for column in 0..<(3 * sources.count) {
                let mean = averageField.freeOrientationMatrixMicrovoltsPerNanoampereMeter.reduce(0.0) {
                    $0 + $1[column]
                } / Double(sourceConfig.channelCount)
                worstFreeColumnMean = max(worstFreeColumnMean, abs(mean))
            }
            outcomes.append(Outcome(
                name: "Free-orientation lead field is retained and average-referenced",
                snr: worstFreeColumnMean,
                passed: averageField.freeOrientationMatrixMicrovoltsPerNanoampereMeter.first?.count
                    == 3 * sources.count && worstFreeColumnMean < 1e-14,
                expectation: "x/y/z columns for every source, each with mean below 1e-14"
            ))

            var reversedSources = sources
            reversedSources[0].orientation = -reversedSources[0].orientation
            let reversedField = try SphericalForwardModel.leadField(
                head: sourceConfig.sphericalHeadModel, montage: montage,
                sources: [reversedSources[0]], reference: .infinity,
                terms: sourceConfig.leadFieldTerms
            )
            let originalField = try SphericalForwardModel.leadField(
                head: sourceConfig.sphericalHeadModel, montage: montage,
                sources: [sources[0]], reference: .infinity,
                terms: sourceConfig.leadFieldTerms
            )
            var reversalError = 0.0
            for channel in 0..<sourceConfig.channelCount {
                reversalError = max(
                    reversalError,
                    abs(originalField.matrixMicrovoltsPerNanoampereMeter[channel][0]
                        + reversedField.matrixMicrovoltsPerNanoampereMeter[channel][0])
                )
            }
            outcomes.append(Outcome(
                name: "Reversing dipole orientation reverses every sensor potential",
                snr: reversalError,
                passed: reversalError < 1e-12,
                expectation: "peak sign-reversal error below 1e-12 µV/(nA·m)"
            ))

            let quarterTurn: (Vector3D) -> Vector3D = {
                Vector3D(x: $0.y, y: -$0.x, z: $0.z)
            }
            var rotatedSource = sources[0]
            rotatedSource.positionMeters = quarterTurn(rotatedSource.positionMeters)
            rotatedSource.orientation = quarterTurn(rotatedSource.orientation)
            let rotatedMontage = Montage(
                name: "rotated test montage",
                electrodes: montage.electrodes.map {
                    Electrode(name: $0.name, thetaDegrees: $0.thetaDegrees,
                              phiDegrees: $0.phiDegrees + 90)
                }
            )
            let rotatedField = try SphericalForwardModel.leadField(
                head: sourceConfig.sphericalHeadModel, montage: rotatedMontage,
                sources: [rotatedSource], reference: .infinity,
                terms: sourceConfig.leadFieldTerms
            )
            var rotationError = 0.0
            for channel in 0..<sourceConfig.channelCount {
                rotationError = max(
                    rotationError,
                    abs(originalField.matrixMicrovoltsPerNanoampereMeter[channel][0]
                        - rotatedField.matrixMicrovoltsPerNanoampereMeter[channel][0])
                )
            }
            outcomes.append(Outcome(
                name: "Rotating the source and sensors together preserves the field",
                snr: rotationError,
                passed: rotationError < 1e-12,
                expectation: "peak spherical-rotation error below 1e-12 µV/(nA·m)"
            ))

            var largerConfig = sourceConfig
            largerConfig.dipoleSourceCount = 11
            let largerSources = DipoleEEGGenerator.makeSources(config: largerConfig)
            let prefixStable = zip(sources, largerSources).allSatisfy { $0 == $1 }
            outcomes.append(Outcome(
                name: "Adding dipoles preserves the existing source catalog",
                snr: prefixStable ? 0 : 1,
                passed: prefixStable,
                expectation: "positions, orientations, bands and seeds for sources 1-7 unchanged"
            ))

            var artifactConfigA = sourceConfig
            artifactConfigA.samplingRate = 256
            artifactConfigA.durationSeconds = 6
            artifactConfigA.gradientEnabled = false
            artifactConfigA.channelCount = 4
            var artifactConfigB = artifactConfigA
            artifactConfigB.dipoleSourceCount = 19
            var noisyA = [[Double]](
                repeating: [Double](repeating: 0, count: artifactConfigA.sampleCount), count: 4
            )
            var noisyB = noisyA
            var randomA = GaussianSource(seed: SimulationSeedStreams.bcg(base: artifactConfigA.seed))
            var randomB = GaussianSource(seed: SimulationSeedStreams.bcg(base: artifactConfigB.seed))
            let injectionA = BCGArtifactModel.inject(
                into: &noisyA, config: artifactConfigA,
                montage: Montage.standard(count: artifactConfigA.channelCount), source: &randomA
            )
            let injectionB = BCGArtifactModel.inject(
                into: &noisyB, config: artifactConfigB,
                montage: Montage.standard(count: artifactConfigB.channelCount), source: &randomB
            )
            let artifactStable = noisyA == noisyB
                && injectionA.trueBeatSeconds == injectionB.trueBeatSeconds
                && injectionA.detectedBeatSeconds == injectionB.detectedBeatSeconds
                && injectionA.channelScales == injectionB.channelScales
                && injectionA.channelLatenciesSeconds == injectionB.channelLatenciesSeconds
            outcomes.append(Outcome(
                name: "Neural source-count changes do not change the BCG realization",
                snr: artifactStable ? 0 : 1,
                passed: artifactStable,
                expectation: "identical cardiac timing, parameters and samples"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "Dipole lead-field invariants",
                snr: .infinity, passed: false,
                expectation: "valid lead fields (\(error.localizedDescription))"
            ))
        }

        do {
            var dipoleConfig = SimulationConfig.default
            dipoleConfig.eegGenerationModel = .dipole
            dipoleConfig.channelCount = 20
            dipoleConfig.samplingRate = 256
            dipoleConfig.durationSeconds = 2
            dipoleConfig.dipoleSourceCount = 7
            let montage = Montage.standard(count: dipoleConfig.channelCount)
            let first = try DipoleEEGGenerator.generate(config: dipoleConfig, montage: montage)
            let second = try DipoleEEGGenerator.generate(config: dipoleConfig, montage: montage)
            let deviation = abs(first.standardDeviation - dipoleConfig.eegTargetStdMicrovolts)
            outcomes.append(Outcome(
                name: "Dipole projection reaches the requested sensor-space amplitude",
                snr: deviation,
                passed: deviation < 1e-10,
                expectation: "pooled standard-deviation error below 1e-10 µV"
            ))
            outcomes.append(Outcome(
                name: "Dipole generation is sample-for-sample deterministic",
                snr: first.channels == second.channels ? 0 : 1,
                passed: first.channels == second.channels,
                expectation: "two runs with the same seed are identical"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "Dipole generation smoke test",
                snr: .infinity, passed: false,
                expectation: "successful generation (\(error.localizedDescription))"
            ))
        }

        do {
            var scenarioConfig = SimulationConfig.default
            scenarioConfig.eegGenerationModel = .dipole
            scenarioConfig.channelCount = 20
            scenarioConfig.samplingRate = 256
            scenarioConfig.durationSeconds = 3
            scenarioConfig.dipoleSourceCount = 4
            scenarioConfig.dipoleSourceCorrelation = 0.8
            scenarioConfig.dipoleNearPairSeparationDegrees = 1
            scenarioConfig.dipoleMotionDegrees = 15
            let montage = Montage.standard(count: scenarioConfig.channelCount)
            let generated = try DipoleEEGGenerator.generate(
                config: scenarioConfig, montage: montage
            )
            guard let sourceSpace = generated.sourceSpace else {
                throw SimulateError.io("dipole generator returned no source truth")
            }

            let imposedCorrelation = sourceSpace.sourceCorrelationMatrix[0][1]
            outcomes.append(Outcome(
                name: "Correlated-pair scenario imposes the requested Pearson r",
                snr: abs(imposedCorrelation - 0.8),
                passed: abs(imposedCorrelation - 0.8) < 1e-12,
                expectation: "absolute error below 1e-12 for r = 0.8"
            ))

            // Imposing a correlation mixes S001's timecourse into S002. While
            // the pair sat in different bands that quietly destroyed S002's band
            // identity — and the per-band scoring in SNRMetrics goes on assuming
            // it holds. The pair now shares one band, and this checks the
            // *spectrum* rather than the label, so relabelling without changing
            // the signal cannot pass it.
            let correlatedBand = DipoleEEGGenerator.band(
                forSourceIndex: 0, config: scenarioConfig
            )
            let secondSource = sourceSpace.timecoursesNanoampereMeters[1]
            let inBandPower = SNRMetrics.bandPower(
                secondSource, samplingRate: scenarioConfig.samplingRate,
                lowHz: correlatedBand.lowHz, highHz: correlatedBand.highHz,
                segmentLength: 256
            )
            let totalPower = SNRMetrics.bandPower(
                secondSource, samplingRate: scenarioConfig.samplingRate,
                lowHz: 0, highHz: scenarioConfig.samplingRate / 2,
                segmentLength: 256
            )
            let inBandFraction = totalPower > 0 ? inBandPower / totalPower : 0
            outcomes.append(Outcome(
                name: "A correlated pair shares one band instead of smearing across two",
                snr: inBandFraction,
                passed: sourceSpace.sources[1].bandName == correlatedBand.name
                    && inBandFraction > 0.9
                    && (sourceSpace.sources[1].scenarioRole ?? "").contains("shares one spectrum"),
                expectation: "S002 keeps over 90% of its power inside S001's band and says so in its role"
            ))

            var independentConfig = scenarioConfig
            independentConfig.dipoleSourceCorrelation = 0
            let independentSources = DipoleEEGGenerator.makeSources(config: independentConfig)
            let pairSharesBand = sourceSpace.sources[0].bandName
                == sourceSpace.sources[1].bandName
            outcomes.append(Outcome(
                name: "Correlated sources retain a truthful within-band identity",
                snr: pairSharesBand ? 0 : 1,
                passed: pairSharesBand
                    && sourceSpace.sources[0].bandName == scenarioConfig.eegBands[0].name
                    && independentSources[0].bandName != independentSources[1].bandName
                    && sourceSpace.sources[1].scenarioRole?.contains("band matched") == true,
                expectation: "S001/S002 share one declared band only when their waveforms are mixed"
            ))

            let topographicCorrelation = sourceSpace.topographicCorrelationMatrix[0][1]
            let sourceDistance = (
                sourceSpace.sources[0].positionMeters - sourceSpace.sources[1].positionMeters
            ).norm
            outcomes.append(Outcome(
                name: "Near-degenerate sources are distinct but topographically confusable",
                snr: topographicCorrelation,
                passed: sourceDistance > 0 && abs(topographicCorrelation) > 0.999,
                expectation: "distinct 1° locations with |topographic r| above 0.999"
            ))

            let motion = sourceSpace.motions.first
            let startGains = sourceSpace.leadField.matrixMicrovoltsPerNanoampereMeter.map { $0[0] }
            let endGains = motion?.endLeadField.matrixMicrovoltsPerNanoampereMeter.map { $0[0] } ?? []
            let gainChange = zip(startGains, endGains).map { abs($0 - $1) }.max() ?? 0
            outcomes.append(Outcome(
                name: "Moving-source scenario records a changed endpoint operator",
                snr: gainChange,
                passed: sourceSpace.motions.count == 1 && gainChange > 1e-6,
                expectation: "one motion record and a non-trivial lead-field change"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "Difficult source-space scenarios",
                snr: .infinity, passed: false,
                expectation: "successful correlated, near-pair and moving-source generation (\(error.localizedDescription))"
            ))
        }

        let ocularMontage = Montage.standard(count: 20)
        let ocular = OcularDipoleModel.topographies(
            montage: ocularMontage,
            head: SimulationConfig.default.sphericalHeadModel
        )
        let fp1 = ocularMontage.channelNames.firstIndex(of: "Fp1") ?? 0
        let fp2 = ocularMontage.channelNames.firstIndex(of: "Fp2") ?? 0
        let f7 = ocularMontage.channelNames.firstIndex(of: "F7") ?? 0
        let f8 = ocularMontage.channelNames.firstIndex(of: "F8") ?? 0
        let frontalBlink = min(ocular.blink[fp1], ocular.blink[fp2])
        let horizontalOpposition = ocular.horizontal[f7] * ocular.horizontal[f8]
        outcomes.append(Outcome(
            name: "Ocular dipoles produce frontal blink and opposed horizontal EOG fields",
            snr: frontalBlink,
            passed: ocular.dipoles.count == 2 && frontalBlink > 0.8 && horizontalOpposition < 0,
            expectation: "two eye dipoles, Fp1/Fp2 blink above 0.8, F7/F8 opposite signs"
        ))

        let locationTruth = [
            SimulatedSource(
                id: "A", positionMeters: Vector3D(x: 0.01, y: 0, z: 0),
                orientation: Vector3D(x: 1, y: 0, z: 0), bandName: "test",
                seed: 1, rmsMomentNanoampereMeters: 1
            ),
            SimulatedSource(
                id: "B", positionMeters: Vector3D(x: 0, y: 0.02, z: 0),
                orientation: Vector3D(x: 0, y: 1, z: 0), bandName: "test",
                seed: 2, rmsMomentNanoampereMeters: 1
            )
        ]
        let locationEstimate = [
            EstimatedSource(
                id: "component-2", positionMeters: locationTruth[1].positionMeters,
                orientation: -locationTruth[1].orientation
            ),
            EstimatedSource(
                id: "component-1", positionMeters: locationTruth[0].positionMeters,
                orientation: locationTruth[0].orientation
            )
        ]
        let locationScore = SourceMetrics.locationScore(
            truth: locationTruth, estimated: locationEstimate
        )
        outcomes.append(Outcome(
            name: "Source-location scoring is permutation and polarity invariant",
            snr: locationScore.maximumDistanceMillimeters,
            passed: locationScore.maximumDistanceMillimeters < 1e-12
                && (locationScore.meanOrientationErrorDegrees ?? .infinity) < 1e-12,
            expectation: "optimal assignment gives 0 mm and 0° axial error"
        ))

        let trueSignals = [
            [0.0, 1, 0, -1, 0, 1],
            [1.0, 1, -1, -1, 1, -1]
        ]
        let recoveryScore = SourceMetrics.recoveryScore(
            trueIDs: ["A", "B"],
            trueSignals: trueSignals,
            recoveredNames: ["component-B", "component-A"],
            recoveredSignals: [trueSignals[1].map { -$0 }, trueSignals[0]]
        )
        outcomes.append(Outcome(
            name: "Source-waveform scoring is permutation and polarity invariant",
            snr: recoveryScore.minimumAbsoluteCorrelation,
            passed: abs(recoveryScore.minimumAbsoluteCorrelation - 1) < 1e-12,
            expectation: "minimum matched |r| equals 1"
        ))

        do {
            let scenarioDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("eva-simulate-scenario-\(UUID().uuidString)")
            let scenarioURL = scenarioDirectory.appendingPathComponent("round-trip.json")
            defer { try? FileManager.default.removeItem(at: scenarioDirectory) }

            var scenarioConfig = SimulationConfig.default
            scenarioConfig.channelCount = 13
            scenarioConfig.durationSeconds = 11
            scenarioConfig.seed = 123_456
            scenarioConfig.gradientEnabled = true
            scenarioConfig.bcgEnabled = false
            scenarioConfig.includeECG = false
            scenarioConfig.badChannels = [3: .pop]
            scenarioConfig.emg = EMGConfig()
            scenarioConfig.chewing = ChewingConfig()
            scenarioConfig.swallowing = SwallowingConfig()
            scenarioConfig.cableMovement = CableMovementConfig()
            scenarioConfig.sweat = SweatConfig()
            scenarioConfig.bridgedChannelPairs = [ChannelBridge(firstChannel: 1, secondChannel: 2)]
            scenarioConfig.badReference = BadReferenceConfig()
            scenarioConfig.clippingThresholdMicrovolts = 250
            try SimulationScenarioFile.write(
                config: scenarioConfig,
                to: scenarioURL,
                name: "round-trip",
                description: "Self-test scenario"
            )
            let loaded = try SimulationScenarioFile.load(from: scenarioURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let roundTripExact = try encoder.encode(scenarioConfig) == encoder.encode(loaded.config)
            outcomes.append(Outcome(
                name: "Scenario files round-trip the complete configuration",
                snr: roundTripExact ? 0 : 1,
                passed: roundTripExact
                    && loaded.schemaVersion == SimulationScenario.currentSchemaVersion
                    && loaded.name == "round-trip",
                expectation: "schema, metadata, nested model values and seed survive exactly"
            ))

            let overridden = try makeConfig(Arguments([
                "--config", scenarioURL.path,
                "--duration", "7",
                "--seed", "42",
                "--no-gradient",
                "--with-bcg",
                "--with-ecg",
                "--no-emg",
                "--no-chewing",
                "--no-swallowing",
                "--no-cable-movement",
                "--no-sweat",
                "--no-bridges",
                "--no-bad-reference",
                "--no-clipping"
            ]))
            let precedenceCorrect = overridden.durationSeconds == 7
                && overridden.seed == 42
                && !overridden.gradientEnabled
                && overridden.bcgEnabled
                && overridden.includeECG
                && overridden.emg == nil
                && overridden.chewing == nil
                && overridden.swallowing == nil
                && overridden.cableMovement == nil
                && overridden.sweat == nil
                && overridden.bridgedChannelPairs == nil
                && overridden.badReference == nil
                && overridden.clippingThresholdMicrovolts == nil
                && overridden.channelCount == 13
                && overridden.badChannels == [3: .pop]
            outcomes.append(Outcome(
                name: "Explicit flags override a loaded scenario without erasing other values",
                snr: precedenceCorrect ? 0 : 1,
                passed: precedenceCorrect,
                expectation: "defaults < scenario < explicit flags, including boolean re-enabling"
            ))

            let futureURL = scenarioDirectory.appendingPathComponent("future-schema.json")
            let future = SimulationScenario(
                schemaVersion: SimulationScenario.currentSchemaVersion + 1,
                name: "future",
                description: "unsupported schema self-test",
                config: scenarioConfig
            )
            try encoder.encode(future).write(to: futureURL)
            var rejectedFutureSchema = false
            do {
                _ = try SimulationScenarioFile.load(from: futureURL)
            } catch {
                rejectedFutureSchema = true
            }
            outcomes.append(Outcome(
                name: "Scenario loading rejects unsupported schema versions",
                snr: rejectedFutureSchema ? 0 : 1,
                passed: rejectedFutureSchema,
                expectation: "future schemas fail loudly instead of being misread"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "Scenario file reproducibility",
                snr: .infinity, passed: false,
                expectation: "successful round trip and override (\(error.localizedDescription))"
            ))
        }

        let metricRate = 256.0
        let metricClean = (0..<1024).map {
            sin(2 * Double.pi * 10 * Double($0) / metricRate)
                + 0.25 * sin(2 * Double.pi * 3 * Double($0) / metricRate)
        }
        let perfectMetric = SNRMetrics.score(
            label: "perfect", clean: [metricClean], corrected: [metricClean],
            samplingRate: metricRate, channelNames: ["Cz"]
        )
        let perfectRichMetrics = perfectMetric.broadbandRMSEMicrovolts < 1e-12
            && abs(perfectMetric.broadbandCorrelation - 1) < 1e-12
            && perfectMetric.spectralDistortionDbRMS < 1e-12
            && perfectMetric.channels.count == 1
            && perfectMetric.bands.allSatisfy { $0.residualRMS < 1e-12 }
            && abs((perfectMetric.bands.first { $0.name == "8-12" }?.correlation ?? 0) - 1) < 1e-9
        outcomes.append(Outcome(
            name: "Rich waveform metrics recognize a perfect reconstruction",
            snr: perfectMetric.broadbandRMSEMicrovolts,
            passed: perfectRichMetrics,
            expectation: "zero RMSE/distortion, unit correlation, and per-channel detail"
        ))

        let biasedMetric = SNRMetrics.score(
            label: "biased", clean: [metricClean],
            corrected: [metricClean.map { $0 + 2 }],
            samplingRate: metricRate
        )
        outcomes.append(Outcome(
            name: "RMSE exposes a DC error that standard-deviation SNR misses",
            snr: biasedMetric.broadbandRMSEMicrovolts,
            passed: abs(biasedMetric.broadbandRMSEMicrovolts - 2) < 1e-12
                && biasedMetric.broadbandSNR.isInfinite
                && abs(biasedMetric.broadbandCorrelation - 1) < 1e-12,
            expectation: "2 µV RMSE despite infinite legacy SNR and correlation 1"
        ))

        let detectionMetric = DetectionMetrics.score(
            eventType: "test",
            truth: [1, 2, 3],
            detected: [
                DetectedEvent(timeSeconds: 1.01, score: 0.9),
                DetectedEvent(timeSeconds: 2.02, score: 0.8),
                DetectedEvent(timeSeconds: 4.0, score: 0.1)
            ],
            durationSeconds: 5,
            toleranceSeconds: 0.05
        )
        let crowdedDetectionMetric = DetectionMetrics.score(
            eventType: "crowded", truth: [0, 0.1],
            detected: [DetectedEvent(timeSeconds: 0.06), DetectedEvent(timeSeconds: 0.14)],
            durationSeconds: 1, toleranceSeconds: 0.07
        )
        outcomes.append(Outcome(
            name: "Event scoring uses one-to-one tolerance matching",
            snr: detectionMetric.f1,
            passed: detectionMetric.truePositives == 2
                && detectionMetric.falsePositives == 1
                && detectionMetric.falseNegatives == 1
                && abs(detectionMetric.meanAbsoluteTimingErrorMilliseconds - 15) < 1e-9
                && detectionMetric.rocAUC != nil
                && crowdedDetectionMetric.truePositives == 2,
            expectation: "maximum-cardinality matching, 15 ms timing MAE, and a confidence ROC"
        ))

        let erpMetric = ERPMetrics.score(
            truth: [
                ERPComponent(id: "P1", peakLatencySeconds: 0.1, peakAmplitudeMicrovolts: 5),
                ERPComponent(id: "N1", peakLatencySeconds: 0.2, peakAmplitudeMicrovolts: -3)
            ],
            estimated: [
                ERPComponent(id: "N1", peakLatencySeconds: 0.18, peakAmplitudeMicrovolts: -4),
                ERPComponent(id: "P1", peakLatencySeconds: 0.11, peakAmplitudeMicrovolts: 6)
            ]
        )
        outcomes.append(Outcome(
            name: "ERP metrics report signed bias, MAE, and RMSE by component id",
            snr: erpMetric.latencyMAEMilliseconds,
            passed: erpMetric.matchedCount == 2
                && abs(erpMetric.amplitudeBiasMicrovolts) < 1e-12
                && abs(erpMetric.amplitudeMAEMicrovolts - 1) < 1e-12
                && abs(erpMetric.latencyBiasMilliseconds + 5) < 1e-9
                && abs(erpMetric.latencyMAEMilliseconds - 15) < 1e-9,
            expectation: "order-independent amplitude and latency recovery statistics"
        ))

        do {
            var erpConfig = SimulationConfig.default
            erpConfig.channelCount = 20
            erpConfig.samplingRate = 128
            erpConfig.durationSeconds = 45
            var design = ERPConfig()
            design.trialCount = 20
            design.startSeconds = 1
            design.interStimulusIntervalSeconds = 2
            design.interStimulusJitterSeconds = 0.1
            design.targetFraction = 0.25
            design.latencyJitterSDSeconds = 0.03
            design.amplitudeJitterFraction = 0.15
            design.latencyAmplitudeCorrelation = 0.6
            design.omissionRate = 0
            erpConfig.erp = design
            let montage = Montage.standard(count: erpConfig.channelCount)
            var firstChannels = [[Double]](
                repeating: [Double](repeating: 0, count: erpConfig.sampleCount),
                count: erpConfig.channelCount
            )
            var secondChannels = firstChannels
            let first = try ERPGenerator.inject(
                into: &firstChannels, config: erpConfig, montage: montage
            )!
            let second = try ERPGenerator.inject(
                into: &secondChannels, config: erpConfig, montage: montage
            )!
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let truthStable = try encoder.encode(first.trials) == encoder.encode(second.trials)
                && encoder.encode(first.components) == encoder.encode(second.components)
            let targetCount = first.trials.filter { $0.condition == "target" }.count
            let events = SimulationWriter.events(
                gradient: nil, bcg: nil, ocular: nil, erp: first, config: erpConfig
            )
            outcomes.append(Outcome(
                name: "ERP trials, averages, topography and markers are deterministic",
                snr: firstChannels == secondChannels ? 0 : 1,
                passed: firstChannels == secondChannels && truthStable
                    && first.trials.count == 20 && targetCount == 5
                    && first.components.count == 2 && events.count == 20
                    && events.filter { $0.code == "targ" }.count == 5,
                expectation: "repeatable 20-trial design with exact target count and MFF markers"
            ))

            let topographicMean = first.topography.reduce(0, +) / Double(first.topography.count)
            let topographicPeak = first.topography.map(abs).max() ?? 0
            outcomes.append(Outcome(
                name: "ERP variability and dipole topography hit their controls",
                snr: first.realizedLatencyAmplitudeCorrelation,
                passed: abs(first.realizedLatencyAmplitudeCorrelation - 0.6) < 1e-12
                    && abs(topographicMean) < 1e-12
                    && abs(topographicPeak - 1) < 1e-12,
                expectation: "exact r=0.6 variability and normalized average-referenced dipole field"
            ))

            var prefixDesign = design
            prefixDesign.trialCount = 20
            prefixDesign.standardAmplitudeRatio = 1
            prefixDesign.latencyAmplitudeCorrelation = 0
            prefixDesign.omissionRate = 0
            var prefixConfig = erpConfig
            prefixConfig.durationSeconds = 55
            prefixConfig.erp = prefixDesign
            var extendedDesign = prefixDesign
            extendedDesign.trialCount = 24
            var extendedConfig = prefixConfig
            extendedConfig.erp = extendedDesign
            var prefixChannels = [[Double]](
                repeating: [Double](repeating: 0, count: prefixConfig.sampleCount),
                count: prefixConfig.channelCount
            )
            var extendedChannels = [[Double]](
                repeating: [Double](repeating: 0, count: extendedConfig.sampleCount),
                count: extendedConfig.channelCount
            )
            let prefix = try ERPGenerator.inject(
                into: &prefixChannels, config: prefixConfig, montage: montage
            )!
            let extended = try ERPGenerator.inject(
                into: &extendedChannels, config: extendedConfig, montage: montage
            )!
            let factorPrefixesStable = zip(prefix.trials, extended.trials).allSatisfy {
                $0.0.onsetSeconds == $0.1.onsetSeconds
                    && $0.0.peakLatencySeconds == $0.1.peakLatencySeconds
                    && $0.0.peakAmplitudeMicrovolts == $0.1.peakAmplitudeMicrovolts
                    && $0.0.omitted == $0.1.omitted
            }
            let seedValues = [
                prefix.randomSeeds.latency, prefix.randomSeeds.amplitude,
                prefix.randomSeeds.conditionOrder, prefix.randomSeeds.onsetJitter,
                prefix.randomSeeds.omission
            ]
            outcomes.append(Outcome(
                name: "ERP design factors use independent prefix-stable random streams",
                snr: factorPrefixesStable ? 0 : 1,
                passed: factorPrefixesStable && prefix.randomSeeds == extended.randomSeeds
                    && Set(seedValues).count == seedValues.count,
                expectation: "changing trial count does not reroll existing latency, amplitude, onset, or omission draws"
            ))

            var overlapDesign = design
            overlapDesign.trialCount = 5
            overlapDesign.interStimulusIntervalSeconds = 0.4
            overlapDesign.interStimulusJitterSeconds = 0
            overlapDesign.latencyAmplitudeCorrelation = 0
            overlapDesign.omissionRate = 0
            erpConfig.erp = overlapDesign
            var overlapChannels = [[Double]](
                repeating: [Double](repeating: 0, count: erpConfig.sampleCount),
                count: erpConfig.channelCount
            )
            let overlap = try ERPGenerator.inject(
                into: &overlapChannels, config: erpConfig, montage: montage
            )!
            let flagsAreDirectional = overlap.trials.first?.overlapsPreviousTrial == false
                && overlap.trials.first?.overlapsNextTrial == true
                && overlap.trials.last?.overlapsPreviousTrial == true
                && overlap.trials.last?.overlapsNextTrial == false
            outcomes.append(Outcome(
                name: "ERP truth declares overlapping component windows per trial",
                snr: Double(overlap.trials.filter { $0.overlapsAnotherTrial == true }.count),
                passed: overlap.trials.allSatisfy { $0.overlapsAnotherTrial == true }
                    && overlap.trials.allSatisfy {
                        ($0.componentWindowEndSeconds ?? 0) > $0.onsetSeconds
                    }
                    && flagsAreDirectional
                    && first.trials.allSatisfy { $0.overlapsAnotherTrial == false },
                expectation: "dense trials are flagged with directional overlap; separated trials remain scoreable"
            ))

            design.trialCount = 5
            design.omissionRate = 1
            erpConfig.erp = design
            var omittedChannels = [[Double]](
                repeating: [Double](repeating: 0, count: erpConfig.sampleCount),
                count: erpConfig.channelCount
            )
            let omitted = try ERPGenerator.inject(
                into: &omittedChannels, config: erpConfig, montage: montage
            )!
            outcomes.append(Outcome(
                name: "ERP omissions retain stimulus markers but inject no response",
                snr: omitted.trials.filter(\.omitted).count == 5 ? 0 : 1,
                passed: omitted.trials.allSatisfy(\.omitted)
                    && omittedChannels.allSatisfy { $0.allSatisfy { $0 == 0 } },
                expectation: "five true omissions, five events, and zero evoked samples"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "ERP trial simulation",
                snr: .infinity, passed: false,
                expectation: "deterministic source-projected trial generation (\(error.localizedDescription))"
            ))
        }

        do {
            var allConfig = SimulationConfig.default
            allConfig.channelCount = 20
            allConfig.samplingRate = 250
            allConfig.durationSeconds = 12
            allConfig.neuralNonstationarity = NeuralNonstationarityConfig()
            let montage = Montage.standard(count: allConfig.channelCount)
            var firstSource = GaussianSource(seed: allConfig.seed)
            var secondSource = GaussianSource(seed: allConfig.seed)
            let first = EEGGenerator.generate(config: allConfig, montage: montage, source: &firstSource)
            let second = EEGGenerator.generate(config: allConfig, montage: montage, source: &secondSource)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let truthStable = try encoder.encode(first.neuralNonstationarity)
                == encoder.encode(second.neuralNonstationarity)
            outcomes.append(Outcome(
                name: "Neural non-stationarity and its truth are deterministic",
                snr: first.channels == second.channels ? 0 : 1,
                passed: SimulationConfig.default.neuralNonstationarity == nil
                    && first.channels == second.channels && truthStable
                    && first.neuralNonstationarity != nil,
                expectation: "stationary default; opt-in samples and complete truth repeat for one seed"
            ))

            var alphaConfig = allConfig
            var alphaOnly = NeuralNonstationarityConfig()
            alphaOnly.spectralDynamics = nil
            alphaOnly.microstates = nil
            alphaOnly.phaseAmplitudeCoupling = nil
            alphaConfig.durationSeconds = 60
            alphaConfig.neuralNonstationarity = alphaOnly
            let alphaPlan = NonstationaryEEGModel.makePlan(
                config: alphaConfig, montage: montage
            )!
            let traditional = EEGGenerator.alphaEnvelope(config: alphaConfig)
            let relative = zip(alphaPlan.alphaEnvelope, traditional).map {
                $0.1 > 0 ? $0.0 / $0.1 : 0
            }
            let quietFraction = Double(relative.filter { $0 < 0.06 }.count)
                / Double(relative.count)
            outcomes.append(Outcome(
                name: "Alpha is organized into discrete spindle-like bursts",
                snr: Double(alphaPlan.alphaBursts.count),
                passed: alphaPlan.alphaBursts.count >= 8
                    && alphaPlan.alphaBursts.count <= 16
                    && quietFraction > 0.55
                    && (relative.max() ?? 0) > 0.99,
                expectation: "about 12 bursts/min, smooth full peaks, and >55% quiet background"
            ))

            var spectraConfig = allConfig
            spectraConfig.durationSeconds = 60
            var spectraOnly = NeuralNonstationarityConfig()
            spectraOnly.alphaBursts = nil
            spectraOnly.microstates = nil
            spectraOnly.phaseAmplitudeCoupling = nil
            spectraConfig.neuralNonstationarity = spectraOnly
            let spectraPlan = NonstationaryEEGModel.makePlan(
                config: spectraConfig, montage: montage
            )!
            let thetaEnvelope = spectraPlan.bandEnvelopes1Hz["theta"] ?? []
            let lagCorrelation = thetaEnvelope.count > 2
                ? DipoleEEGGenerator.pearson(
                    Array(thetaEnvelope.dropLast()), Array(thetaEnvelope.dropFirst())
                ) : 0
            let dynamicRange = (thetaEnvelope.max() ?? 0) / max(thetaEnvelope.min() ?? 1, 1e-12)
            outcomes.append(Outcome(
                name: "Band amplitudes follow slow stochastic dynamics",
                snr: lagCorrelation,
                passed: spectraPlan.bandEnvelopes1Hz.count == allConfig.eegBands.count
                    && dynamicRange > 1.2 && lagCorrelation > 0.5,
                expectation: "one envelope per band, non-trivial range, and strong adjacent-second continuity"
            ))

            var statesConfig = allConfig
            statesConfig.durationSeconds = 10
            var statesOnly = NeuralNonstationarityConfig()
            statesOnly.alphaBursts = nil
            statesOnly.spectralDynamics = nil
            statesOnly.phaseAmplitudeCoupling = nil
            statesConfig.neuralNonstationarity = statesOnly
            let statesPlan = NonstationaryEEGModel.makePlan(
                config: statesConfig, montage: montage
            )!
            let episodes = statesPlan.microstateEpisodes
            let internalEpisodes = episodes.dropLast()
            let noImmediateRepeats = zip(episodes, episodes.dropFirst()).allSatisfy {
                $0.0.stateIndex != $0.1.stateIndex
            }
            var worstMapCorrelation = 0.0
            for left in statesPlan.microstateTopographies.indices {
                for right in statesPlan.microstateTopographies.indices where right > left {
                    worstMapCorrelation = max(worstMapCorrelation, abs(
                        DipoleEEGGenerator.pearson(
                            statesPlan.microstateTopographies[left],
                            statesPlan.microstateTopographies[right]
                        )
                    ))
                }
            }
            outcomes.append(Outcome(
                name: "Microstates switch among distinct piecewise-stationary maps",
                snr: worstMapCorrelation,
                passed: Set(episodes.map(\.stateIndex)).count == 4
                    && noImmediateRepeats
                    && internalEpisodes.allSatisfy {
                        $0.durationSeconds >= 0.04 && $0.durationSeconds <= 0.25
                    }
                    && worstMapCorrelation < 0.95,
                expectation: "four distinct maps, 40-250 ms dwells, and no immediate state repeats"
            ))

            var pacConfig = allConfig
            pacConfig.durationSeconds = 30
            pacConfig.eegGenerationModel = .dipole
            pacConfig.dipoleSourceCount = 7
            var pacOnly = NeuralNonstationarityConfig()
            pacOnly.alphaBursts = nil
            pacOnly.spectralDynamics = nil
            pacOnly.microstates = nil
            pacConfig.neuralNonstationarity = pacOnly
            let pacEEG = try DipoleEEGGenerator.generate(config: pacConfig, montage: montage)
            let pacTruth = pacEEG.neuralNonstationarity!.phaseAmplitudeCoupling!
            let targetIndex = pacEEG.sourceSpace!.sources.firstIndex {
                $0.bandName == pacTruth.targetBandName
            }!
            let target = pacEEG.sourceSpace!.timecoursesNanoampereMeters[targetIndex]
            var preferredSum = 0.0
            var preferredCount = 0
            var oppositeSum = 0.0
            var oppositeCount = 0
            for sample in target.indices {
                let phase = pacTruth.initialPhaseRadians + 2 * Double.pi
                    * pacTruth.phaseFrequencyHz * Double(sample) / pacConfig.samplingRate
                    - pacTruth.preferredPhaseRadians
                let cosine = cos(phase)
                if cosine > 0.9 { preferredSum += abs(target[sample]); preferredCount += 1 }
                if cosine < -0.9 { oppositeSum += abs(target[sample]); oppositeCount += 1 }
            }
            let realizedRatio = (preferredSum / Double(max(preferredCount, 1)))
                / max(oppositeSum / Double(max(oppositeCount, 1)), 1e-30)
            outcomes.append(Outcome(
                name: "Phase-amplitude coupling peaks at the recorded preferred phase",
                snr: realizedRatio,
                passed: pacTruth.phaseCarrierBandName == "theta"
                    && pacTruth.targetBandName == "gamma-low"
                    && abs(pacTruth.preferredToOppositeGainRatio - 5.6666666667) < 1e-8
                    && realizedRatio > 4,
                expectation: "theta phase truth and >4x gamma amplitude at preferred versus opposite phase"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "Neural non-stationarity",
                snr: .infinity, passed: false,
                expectation: "deterministic bursts, spectra, microstates, and PAC (\(error.localizedDescription))"
            ))
        }

        do {
            var emgConfig = SimulationConfig.default
            emgConfig.channelCount = 20
            emgConfig.durationSeconds = 20
            emgConfig.gradientEnabled = false
            emgConfig.bcgEnabled = false
            var model = EMGConfig()
            model.burstsPerMinute = 30
            emgConfig.emg = model
            let montage = Montage.standard(count: emgConfig.channelCount)
            var firstChannels = [[Double]](
                repeating: [Double](repeating: 0, count: emgConfig.sampleCount),
                count: emgConfig.channelCount
            )
            var secondChannels = firstChannels
            var firstSource = GaussianSource(seed: SimulationSeedStreams.emg(base: emgConfig.seed))
            var secondSource = GaussianSource(seed: SimulationSeedStreams.emg(base: emgConfig.seed))
            let first = EMGArtifactModel.inject(
                into: &firstChannels, config: emgConfig, montage: montage, source: &firstSource
            )!
            let second = EMGArtifactModel.inject(
                into: &secondChannels, config: emgConfig, montage: montage, source: &secondSource
            )!
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let truthStable = try encoder.encode(first.bursts) == encoder.encode(second.bursts)
            let events = SimulationWriter.events(
                gradient: nil, bcg: nil, ocular: nil, erp: nil,
                emg: first, config: emgConfig
            )
            outcomes.append(Outcome(
                name: "EMG bursts, truth, and markers are deterministic",
                snr: firstChannels == secondChannels ? 0 : 1,
                passed: SimulationConfig.default.emg == nil
                    && !first.bursts.isEmpty
                    && firstChannels == secondChannels && truthStable
                    && events.count == first.bursts.count
                    && events.allSatisfy { $0.code == "emg" && ($0.durationSeconds ?? 0) > 0 },
                expectation: "off by default; repeatable burst samples and one duration marker per truth event"
            ))

            var active = [Bool](repeating: false, count: emgConfig.sampleCount)
            for burst in first.bursts {
                let start = max(0, Int((burst.onsetSeconds * emgConfig.samplingRate).rounded()))
                let length = max(2, Int((burst.durationSeconds * emgConfig.samplingRate).rounded()))
                for index in start..<min(active.count, start + length) { active[index] = true }
            }
            let outsideIsQuiet = firstChannels.allSatisfy { channel in
                channel.indices.allSatisfy { active[$0] || channel[$0] == 0 }
            }
            let f7 = montage.channelNames.firstIndex(of: "F7")!
            let lowPower = SNRMetrics.bandPower(
                firstChannels[f7], samplingRate: emgConfig.samplingRate,
                lowHz: 1, highHz: 15, segmentLength: 2048
            )
            let musclePower = SNRMetrics.bandPower(
                firstChannels[f7], samplingRate: emgConfig.samplingRate,
                lowHz: model.lowHz, highHz: model.highHz, segmentLength: 2048
            )
            let powerRatio = musclePower / max(lowPower, 1e-30)
            outcomes.append(Outcome(
                name: "EMG is bursty and broadband above 20 Hz",
                snr: powerRatio,
                passed: outsideIsQuiet && musclePower > 0 && powerRatio > 10,
                expectation: "zero outside truth windows and >10x as much 20-200 Hz as 1-15 Hz power"
            ))

            let f8 = montage.channelNames.firstIndex(of: "F8")!
            let cz = montage.channelNames.firstIndex(of: "Cz")!
            let oz = montage.channelNames.firstIndex(of: "Oz")!
            let fz = montage.channelNames.firstIndex(of: "Fz")!
            let localized = first.leftTemporalisTopography[f7] > first.leftTemporalisTopography[f8]
                && first.leftTemporalisTopography[f7] > first.leftTemporalisTopography[cz]
                && first.rightTemporalisTopography[f8] > first.rightTemporalisTopography[f7]
                && first.rightTemporalisTopography[f8] > first.rightTemporalisTopography[cz]
                && first.posteriorNeckTopography[oz] > first.posteriorNeckTopography[fz]
                && first.posteriorNeckTopography[oz] > first.posteriorNeckTopography[cz]
            outcomes.append(Outcome(
                name: "EMG topographies localize to temporalis and posterior neck",
                snr: localized ? 0 : 1,
                passed: localized,
                expectation: "F7/F8 lateralized temporal maxima and Oz-weighted neck activity"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "EMG artifact simulation",
                snr: .infinity, passed: false,
                expectation: "deterministic localized broadband bursts (\(error.localizedDescription))"
            ))
        }

        do {
            var config = SimulationConfig.default
            config.channelCount = 20
            config.durationSeconds = 20
            var chewing = ChewingConfig()
            chewing.episodesPerMinute = 20
            var swallowing = SwallowingConfig()
            swallowing.eventsPerMinute = 20
            config.chewing = chewing
            config.swallowing = swallowing
            let montage = Montage.standard(count: config.channelCount)
            var firstChannels = [[Double]](
                repeating: [Double](repeating: 0, count: config.sampleCount),
                count: config.channelCount
            )
            var secondChannels = firstChannels
            let first = AdditionalArtifactModel.injectAdditive(
                into: &firstChannels, config: config, montage: montage
            )
            let second = AdditionalArtifactModel.injectAdditive(
                into: &secondChannels, config: config, montage: montage
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let truthStable = try encoder.encode(first.chewingEpisodes)
                == encoder.encode(second.chewingEpisodes)
                && encoder.encode(first.swallowingEpisodes)
                == encoder.encode(second.swallowingEpisodes)
            let events = SimulationWriter.events(
                gradient: nil, bcg: nil, ocular: nil, erp: nil,
                additional: first, config: config
            )
            let expectedEvents = first.chewingEpisodes.count + first.swallowingEpisodes.count
            outcomes.append(Outcome(
                name: "Chewing and swallowing are deterministic stereotyped bursts",
                snr: firstChannels == secondChannels ? 0 : 1,
                passed: !first.chewingEpisodes.isEmpty && !first.swallowingEpisodes.isEmpty
                    && firstChannels == secondChannels && truthStable
                    && events.count == expectedEvents
                    && events.allSatisfy { $0.code == "chew" || $0.code == "swal" },
                expectation: "repeatable orofacial samples, truth, duration markers, and distinct event codes"
            ))

            var movementConfig = SimulationConfig.default
            movementConfig.channelCount = 20
            movementConfig.durationSeconds = 15
            var movement = CableMovementConfig()
            movement.eventsPerMinute = 20
            movementConfig.cableMovement = movement
            var movementChannels = [[Double]](
                repeating: [Double](repeating: 0, count: movementConfig.sampleCount),
                count: movementConfig.channelCount
            )
            let movementTruth = AdditionalArtifactModel.injectAdditive(
                into: &movementChannels, config: movementConfig,
                montage: Montage.standard(count: movementConfig.channelCount)
            )
            let broad = !movementTruth.cableMovementEpisodes.isEmpty
                && movementTruth.cableMovementEpisodes.allSatisfy {
                    ($0.topography?.min() ?? 0) >= 0.24
                        && abs(($0.topography?.max() ?? 0) - 1) < 1e-12
                }

            var sweatConfig = SimulationConfig.default
            sweatConfig.channelCount = 20
            sweatConfig.durationSeconds = 15
            var sweat = SweatConfig()
            sweat.episodesPerMinute = 20
            sweat.durationSeconds = 3
            sweat.affectedChannelCount = 1
            sweatConfig.sweat = sweat
            var sweatChannels = [[Double]](
                repeating: [Double](repeating: 0, count: sweatConfig.sampleCount),
                count: sweatConfig.channelCount
            )
            let sweatTruth = AdditionalArtifactModel.injectAdditive(
                into: &sweatChannels, config: sweatConfig,
                montage: Montage.standard(count: sweatConfig.channelCount)
            )
            let truthChannels = Set(sweatTruth.sweatEpisodes.flatMap(\.affectedChannels))
            let changedChannels = Set(sweatChannels.indices.compactMap { index in
                sweatChannels[index].contains(where: { $0 != 0 }) ? index + 1 : nil
            })
            outcomes.append(Outcome(
                name: "Cable movement is broad while sweat drift stays local",
                snr: Double(changedChannels.count),
                passed: broad && !sweatTruth.sweatEpisodes.isEmpty
                    && sweatTruth.sweatEpisodes.allSatisfy { $0.affectedChannels.count == 1 }
                    && changedChannels == truthChannels,
                expectation: "movement weights every channel; sweat changes exactly its recorded channels"
            ))

            // ---------------------------------------------------------------
            // Roadmap 5.1: the BCG as physical generators.
            // ---------------------------------------------------------------

            var generatorConfig = SimulationConfig.default
            generatorConfig.channelCount = 20
            generatorConfig.samplingRate = 256
            generatorConfig.durationSeconds = 20
            generatorConfig.bcgSpatialModel = .generators
            let generatorMontage = Montage.standard(count: generatorConfig.channelCount)

            // The direct test of the 4.1 defect. Reverse the electrode order so
            // channel *indices* change while the set of *positions* does not.
            //
            // A topography computed from the channel number is unmoved by that;
            // one computed from geometry follows the electrode. Asserting both
            // halves is the point — showing only that the new model changes
            // would not establish that the old one was index-bound.
            var reversedMontage = generatorMontage
            reversedMontage.electrodes.reverse()

            func bcgWeights(model: BCGSpatialModel, montage: Montage) -> [Double] {
                var config = generatorConfig
                config.bcgSpatialModel = model
                var channels = [[Double]](
                    repeating: [Double](repeating: 0, count: config.sampleCount),
                    count: config.channelCount
                )
                var stream = GaussianSource(seed: SimulationSeedStreams.bcg(base: config.seed))
                return BCGArtifactModel.inject(
                    into: &channels, config: config, montage: montage, source: &stream
                ).channelScales
            }

            let legacyForward = bcgWeights(model: .channelIndex, montage: generatorMontage)
            let legacyReversed = bcgWeights(model: .channelIndex, montage: reversedMontage)
            let generatorForward = bcgWeights(model: .generators, montage: generatorMontage)
            let generatorReversed = bcgWeights(model: .generators, montage: reversedMontage)

            let legacyDrift = zip(legacyForward, legacyReversed)
                .map { abs($0 - $1) }.max() ?? 0
            outcomes.append(Outcome(
                name: "The channel-index BCG ignores electrode geometry entirely",
                snr: legacyDrift,
                passed: legacyDrift < 1e-12,
                expectation: "reversing the montage leaves every channel weight identical, "
                    + "which is the defect roadmap 4.1 describes"
            ))

            // Compare the generator topographies themselves rather than the
            // composite's per-channel summary. `channelScales` is a signed
            // peak-to-peak magnitude, and the composite happens to be nearly
            // symmetric under a front-to-back reversal, so it is too lossy to
            // demonstrate the property.
            let forwardSet = BCGGeneratorModel.makeGenerators(
                config: generatorConfig, montage: generatorMontage, beatCount: 4
            )
            let reversedSet = BCGGeneratorModel.makeGenerators(
                config: generatorConfig, montage: reversedMontage, beatCount: 4
            )
            var worstPermutedError = 0.0
            var flattestTopographySpread = Double.infinity
            for (forward, reversed) in zip(forwardSet.generators, reversedSet.generators) {
                let error = zip(forward.topography, reversed.topography.reversed())
                    .map { abs($0 - $1) }.max() ?? 0
                worstPermutedError = max(worstPermutedError, error)
                let spread = (forward.topography.max() ?? 0) - (forward.topography.min() ?? 0)
                flattestTopographySpread = min(flattestTopographySpread, spread)
            }
            outcomes.append(Outcome(
                name: "The generator BCG topography follows the electrode",
                snr: worstPermutedError,
                // The spread clause matters: a uniform topography would also be
                // unchanged by permutation, and would pass the first clause for
                // entirely the wrong reason.
                passed: worstPermutedError < 1e-9 && flattestTopographySpread > 0.3,
                expectation: "every generator's weights permute with the montage to within 1e-9, "
                    + "and none of them is flat"
            ))

            // Roadmap 4.2: rank. Rusiniak et al. report 4-8 components per
            // subject; FMRIB's OBS removes 4 by default. A rank-one artifact
            // makes OBS-4 trivially near-optimal and PCA-S, ICA-S and OBS
            // indistinguishable, so this number decides whether the surrogate
            // comparison in 5.2 can say anything at all.
            var rankChannels = [[Double]](
                repeating: [Double](repeating: 0, count: generatorConfig.sampleCount),
                count: generatorConfig.channelCount
            )
            var rankStream = GaussianSource(
                seed: SimulationSeedStreams.bcg(base: generatorConfig.seed)
            )
            let rankInjection = BCGArtifactModel.inject(
                into: &rankChannels, config: generatorConfig,
                montage: generatorMontage, source: &rankStream
            )
            let generatorSet = rankInjection.generatorSet
            let legacyRank = BCGGeneratorModel.normalizedSingularValues(
                topographies: [legacyForward]
            ).filter { $0 > 0.01 }.count
            let smallestGeneratorValue = generatorSet?.normalizedSingularValues.last ?? 0
            outcomes.append(Outcome(
                name: "The generator BCG has real spatial rank; the channel-index model has one",
                snr: Double(generatorSet?.spatialRank ?? 0),
                passed: generatorSet?.spatialRank == 4
                    && legacyRank == 1
                    // Not merely non-zero: a fourth component at 1e-6 would
                    // count toward the rank while being invisible to any method.
                    && smallestGeneratorValue > 0.05,
                expectation: "rank 4 with the smallest singular value above 5% of the largest, "
                    + "against rank 1 for the channel-index model"
            ))

            // Morphology, not just amplitude. Two beats are compared after
            // normalizing each to unit peak, so a pure amplitude difference
            // cannot produce a low correlation. The zero-jitter arm is the
            // control: without it, a low correlation could just as well mean the
            // extraction window was misaligned.
            func beatShape(
                _ channels: [[Double]], beats: [Double], index: Int, config: SimulationConfig
            ) -> [Double] {
                let start = Int(((beats[index] + 0.02) * config.samplingRate).rounded())
                let length = Int((0.45 * config.samplingRate).rounded())
                guard start >= 0, start + length < config.sampleCount else { return [] }
                var window = Array(channels[0][start..<(start + length)])
                let peak = window.map(abs).max() ?? 0
                if peak > 1e-15 { for i in window.indices { window[i] /= peak } }
                return window
            }

            var fixedConfig = generatorConfig
            fixedConfig.bcgMorphologyJitterFraction = 0
            fixedConfig.heartRateMinBPM = 60
            fixedConfig.heartRateMaxBPM = 60
            fixedConfig.heartRateVariability = 0
            fixedConfig.bcgAmplitudeJitterFraction = 0
            var fixedChannels = [[Double]](
                repeating: [Double](repeating: 0, count: fixedConfig.sampleCount),
                count: fixedConfig.channelCount
            )
            var fixedStream = GaussianSource(seed: SimulationSeedStreams.bcg(base: fixedConfig.seed))
            let fixedInjection = BCGArtifactModel.inject(
                into: &fixedChannels, config: fixedConfig,
                montage: generatorMontage, source: &fixedStream
            )
            var variedConfig = fixedConfig
            variedConfig.bcgMorphologyJitterFraction = 0.35
            var variedChannels = [[Double]](
                repeating: [Double](repeating: 0, count: variedConfig.sampleCount),
                count: variedConfig.channelCount
            )
            var variedStream = GaussianSource(
                seed: SimulationSeedStreams.bcg(base: variedConfig.seed)
            )
            let variedInjection = BCGArtifactModel.inject(
                into: &variedChannels, config: variedConfig,
                montage: generatorMontage, source: &variedStream
            )
            let fixedShapeCorrelation = DipoleEEGGenerator.pearson(
                beatShape(fixedChannels, beats: fixedInjection.trueBeatSeconds,
                          index: 1, config: fixedConfig),
                beatShape(fixedChannels, beats: fixedInjection.trueBeatSeconds,
                          index: 6, config: fixedConfig)
            )
            let variedShapeCorrelation = DipoleEEGGenerator.pearson(
                beatShape(variedChannels, beats: variedInjection.trueBeatSeconds,
                          index: 1, config: variedConfig),
                beatShape(variedChannels, beats: variedInjection.trueBeatSeconds,
                          index: 6, config: variedConfig)
            )
            outcomes.append(Outcome(
                name: "Beat-to-beat BCG morphology varies in shape, not only amplitude",
                snr: variedShapeCorrelation,
                passed: fixedShapeCorrelation > 0.999 && variedShapeCorrelation < 0.99,
                expectation: "amplitude-normalized beats correlate above 0.999 with jitter off "
                    + "and below 0.99 with it on"
            ))

            // Both motional EMF and the Hall separation are linear in B0.
            func peakToPeak(_ config: SimulationConfig) -> Double {
                var channels = [[Double]](
                    repeating: [Double](repeating: 0, count: config.sampleCount),
                    count: config.channelCount
                )
                var stream = GaussianSource(seed: SimulationSeedStreams.bcg(base: config.seed))
                _ = BCGArtifactModel.inject(
                    into: &channels, config: config, montage: generatorMontage, source: &stream
                )
                return channels.map { ($0.max() ?? 0) - ($0.min() ?? 0) }.max() ?? 0
            }
            var lowFieldConfig = generatorConfig
            lowFieldConfig.bcgFieldStrengthTesla = 1.5
            var highFieldConfig = generatorConfig
            highFieldConfig.bcgFieldStrengthTesla = 7.0
            let lowFieldPeak = peakToPeak(lowFieldConfig)
            let highFieldPeak = peakToPeak(highFieldConfig)
            let fieldRatio = lowFieldPeak > 1e-12 ? highFieldPeak / lowFieldPeak : 0
            outcomes.append(Outcome(
                name: "BCG amplitude scales linearly with static field strength",
                snr: fieldRatio,
                passed: abs(fieldRatio - 7.0 / 1.5) < 1e-6,
                expectation: "7 T over 1.5 T gives a peak-to-peak ratio of exactly 4.667"
            ))

            // The paper benchmark must not have moved, and — the part that is
            // easy to get wrong — a scenario file written before these settings
            // existed must still load. Swift's synthesized `Decodable` does not
            // fall back to a property's default when a key is absent, and every
            // scenario carries the complete configuration, so a non-optional
            // addition here would break every file a user already has.
            var legacyScenarioJSON = try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(SimulationConfig.default)
            ) as? [String: Any] ?? [:]
            let addedKeys = [
                "bcgSpatialModel", "bcgFieldStrengthTesla", "bcgMorphologyJitterFraction"
            ]
            for key in addedKeys { legacyScenarioJSON.removeValue(forKey: key) }
            let decodedLegacy = try JSONDecoder().decode(
                SimulationConfig.self,
                from: try JSONSerialization.data(withJSONObject: legacyScenarioJSON)
            )
            outcomes.append(Outcome(
                name: "The channel-index BCG is the default and pre-5.1 scenarios still load",
                snr: Double(addedKeys.count),
                passed: SimulationConfig.default.effectiveBCGSpatialModel == .channelIndex
                    && decodedLegacy.effectiveBCGSpatialModel == .channelIndex
                    && decodedLegacy.effectiveBCGFieldStrengthTesla == 3.0
                    && decodedLegacy.effectiveBCGMorphologyJitterFraction == 0.20,
                expectation: "generators are opt-in, and a configuration missing all three new "
                    + "keys decodes to the pre-5.1 behaviour"
            ))

            // ---------------------------------------------------------------
            // Roadmap 5.2: surrogate-source separation.
            // ---------------------------------------------------------------

            // SymmetricEigen underpins both the 5.1 rank diagnostic and the
            // 5.2 artifact PCA, and neither of those would fail loudly if it
            // were subtly wrong. Verify the decomposition itself: A must equal
            // the sum of lambda_i v_i v_i^T, and the vectors must be orthonormal.
            var eigenTest = [[Double]](repeating: [Double](repeating: 0, count: 12), count: 12)
            var eigenSeed = GaussianSource(seed: 0xEE_1E_11)
            for row in 0..<12 {
                for column in row..<12 {
                    let value = eigenSeed.gaussian()
                    eigenTest[row][column] = value
                    eigenTest[column][row] = value
                }
            }
            let eigenDecomposition = SymmetricEigen.decompose(eigenTest)
            var reconstruction = [[Double]](
                repeating: [Double](repeating: 0, count: 12), count: 12
            )
            for (value, vector) in zip(eigenDecomposition.values, eigenDecomposition.vectors) {
                for row in 0..<12 {
                    for column in 0..<12 {
                        reconstruction[row][column] += value * vector[row] * vector[column]
                    }
                }
            }
            var reconstructionError = 0.0
            for row in 0..<12 {
                for column in 0..<12 {
                    reconstructionError = max(
                        reconstructionError,
                        abs(reconstruction[row][column] - eigenTest[row][column])
                    )
                }
            }
            var orthonormalityError = 0.0
            for i in 0..<12 {
                for j in 0..<12 {
                    let dot = zip(eigenDecomposition.vectors[i], eigenDecomposition.vectors[j])
                        .reduce(0.0) { $0 + $1.0 * $1.1 }
                    orthonormalityError = max(orthonormalityError, abs(dot - (i == j ? 1 : 0)))
                }
            }
            outcomes.append(Outcome(
                name: "Symmetric eigendecomposition reconstructs its input",
                snr: reconstructionError,
                passed: reconstructionError < 1e-10 && orthonormalityError < 1e-10,
                expectation: "A = sum of lambda_i v_i v_i^T to 1e-10 with orthonormal vectors"
            ))

            let surrogateMontage = Montage.standard(count: 64)
            let surrogateHead = SphericalHeadModel.classicThreeShell
            let surrogateBrain = try SurrogateSeparation.brainModel(
                head: surrogateHead, montage: surrogateMontage, count: 29,
                reference: .average, terms: 100
            )

            func identityDeviation(regularization: Double, artifacts: [[Double]]) -> Double {
                let filter = SurrogateSeparation.spatialFilter(
                    brain: surrogateBrain, artifactTopographies: artifacts,
                    brainRegularization: regularization
                )
                var worst = 0.0
                for row in filter.indices {
                    for column in filter[row].indices {
                        let target = row == column ? 1.0 : 0.0
                        worst = max(worst, abs(filter[row][column] - target))
                    }
                }
                return worst
            }

            // Asking the filter to be the *identity* is the wrong test: a
            // three-shell lead field is ill-conditioned, and the directions it
            // reproduces poorly are spatial patterns no dipole can produce
            // anyway. What must be preserved is physiologically reachable
            // signal — topographies of actual dipoles at the depth the simulator
            // uses.
            var dipoleProbeConfig = SimulationConfig.default
            dipoleProbeConfig.channelCount = 64
            dipoleProbeConfig.dipoleSourceCount = 7
            let probeSources = DipoleEEGGenerator.makeSources(config: dipoleProbeConfig)
            let probeField = try SphericalForwardModel.leadField(
                head: surrogateHead, montage: surrogateMontage, sources: probeSources,
                reference: .average, terms: dipoleProbeConfig.leadFieldTerms
            )
            let probeTopographies = (0..<probeSources.count).map { index in
                probeField.matrixMicrovoltsPerNanoampereMeter.map { $0[index] }
            }

            // `apply` takes channels x samples. Treat each probe topography as
            // one sample column, so the matrix is channels x probes — passing
            // the topographies as if they were channels silently computes
            // something meaningless.
            var probeMatrix = [[Double]](
                repeating: [Double](repeating: 0, count: probeTopographies.count),
                count: surrogateMontage.electrodes.count
            )
            for (probe, topography) in probeTopographies.enumerated() {
                for channel in topography.indices { probeMatrix[channel][probe] = topography[channel] }
            }

            func preservation(regularization: Double, artifacts: [[Double]] = []) -> Double {
                let filter = SurrogateSeparation.spatialFilter(
                    brain: surrogateBrain, artifactTopographies: artifacts,
                    brainRegularization: regularization
                )
                let projected = SurrogateSeparation.apply(filter: filter, to: probeMatrix)
                var worst = 1.0
                for probe in probeTopographies.indices {
                    let recovered = (0..<projected.count).map { projected[$0][probe] }
                    worst = min(worst, DipoleEEGGenerator.pearson(probeTopographies[probe], recovered))
                }
                return worst
            }

            let unregularizedPreservation = preservation(regularization: 0)
            let regularizedPreservation = preservation(regularization: 0.02)
            outcomes.append(Outcome(
                name: "Surrogate brain model reproduces real dipole topographies",
                snr: unregularizedPreservation,
                passed: unregularizedPreservation > 0.99,
                expectation: "with no artifact columns and no regularization, every dipole "
                    + "topography survives the filter with correlation above 0.99"
            ))
            // The end-to-end property: a *whole simulated recording* containing
            // no artifact must survive the filter. Topography preservation
            // alone is not enough to conclude this — it is measured one
            // topography at a time, while a recording mixes them.
            var passthroughConfig = SimulationConfig.default
            passthroughConfig.channelCount = 64
            passthroughConfig.samplingRate = 250
            passthroughConfig.durationSeconds = 8
            passthroughConfig.eegGenerationModel = .dipole
            passthroughConfig.recordingReference = .average
            let passthroughEEG = try DipoleEEGGenerator.generate(
                config: passthroughConfig, montage: surrogateMontage
            )
            var passthroughChannels = passthroughEEG.channels
            EEGReferencing.apply(.average, to: &passthroughChannels)
            let passthroughFilter = SurrogateSeparation.spatialFilter(
                brain: surrogateBrain, artifactTopographies: [], brainRegularization: 0.02
            )
            let passthroughResult = SurrogateSeparation.apply(
                filter: passthroughFilter, to: passthroughChannels
            )
            let passthroughCorrelation = zip(passthroughChannels, passthroughResult)
                .map { DipoleEEGGenerator.pearson($0, $1) }.min() ?? 0
            // Correlation is scale-invariant, so it cannot see a filter that
            // preserves shape while shrinking amplitude — and shrinkage is
            // exactly what a regularized fit does. Measure the residual the way
            // `score` does, against the signal itself.
            var passthroughSignalSquares = 0.0
            var passthroughResidualSquares = 0.0
            for channel in passthroughChannels.indices {
                for sample in passthroughChannels[channel].indices {
                    let value = passthroughChannels[channel][sample]
                    passthroughSignalSquares += value * value
                    let residual = value - passthroughResult[channel][sample]
                    passthroughResidualSquares += residual * residual
                }
            }
            let passthroughSNR = passthroughResidualSquares > 1e-30
                ? (passthroughSignalSquares / passthroughResidualSquares).squareRoot()
                : Double.infinity
            outcomes.append(Outcome(
                name: "A whole artifact-free recording survives the surrogate filter",
                snr: passthroughSNR,
                passed: passthroughCorrelation > 0.97 && passthroughSNR > 5,
                expectation: "a clean recording survives with correlation above 0.97 and "
                    + "residual SNR above 5 — correlation alone would miss amplitude shrinkage"
            ))

            outcomes.append(Outcome(
                name: "Brain regularization keeps dipole topographies intact",
                snr: regularizedPreservation,
                passed: regularizedPreservation > 0.95,
                expectation: "2% regularization still preserves dipole topographies above 0.95; "
                    + "a low value means the basis is too deep to describe them"
            ))

            // End to end: generate a recording whose BCG is known, correct it,
            // and check the correction actually recovers signal rather than
            // merely changing it. Scored against the clean truth the same way
            // the `score` command scores a file.
            var separationConfig = SimulationConfig.default
            separationConfig.channelCount = 64
            separationConfig.samplingRate = 250
            // Long enough that the template averages well over 70 accepted
            // beats. This is not padding: the harness measures broadband SNR
            // 0.99 (worse than no correction) at 60 s, against 2.8 at 120 s and
            // 2.5 at 480 s. Below roughly 70 beats the template retains enough
            // ongoing EEG that its third and fourth components are brain
            // activity, and removing them costs more than the artifact does.
            separationConfig.durationSeconds = 150
            separationConfig.eegGenerationModel = .dipole
            separationConfig.recordingReference = .average
            separationConfig.bcgSpatialModel = .generators
            separationConfig.gradientEnabled = false
            let separationMontage = Montage.standard(count: separationConfig.channelCount)
            let separationClean = try DipoleEEGGenerator.generate(
                config: separationConfig, montage: separationMontage
            ).channels
            var separationNoisy = separationClean
            var separationStream = GaussianSource(
                seed: SimulationSeedStreams.bcg(base: separationConfig.seed)
            )
            let separationBCG = BCGArtifactModel.inject(
                into: &separationNoisy, config: separationConfig,
                montage: separationMontage, source: &separationStream
            )
            EEGReferencing.apply(.average, to: &separationNoisy)
            var separationCleanReferenced = separationClean
            EEGReferencing.apply(.average, to: &separationCleanReferenced)

            let separationComponents = SurrogateSeparation.artifactComponents(
                channels: separationNoisy,
                samplingRate: separationConfig.samplingRate,
                beatSeconds: separationBCG.detectedBeatSeconds
            )
            // The generator BCG has spatial rank 4 (roadmap 5.1), and that is
            // how many components the artifact genuinely occupies. Retaining
            // more starts removing EEG: the harness measures broadband SNR 3.00
            // at four components and 1.58 at five, because the fifth carries
            // about 1% of template variance and is ongoing activity rather than
            // artifact. Faithfulness to the paper's 0.5% threshold is kept in
            // the default; this test pins the behaviour at the true rank.
            let separationTopographies = Array(
                (separationComponents?.topographies ?? []).prefix(4)
            )
            let separationBrain = try SurrogateSeparation.brainModel(
                head: separationConfig.sphericalHeadModel, montage: separationMontage,
                count: 29, reference: .average, terms: separationConfig.leadFieldTerms
            )
            let separationFilter = SurrogateSeparation.spatialFilter(
                brain: separationBrain, artifactTopographies: separationTopographies,
                brainRegularization: 0.02
            )
            let separationCorrected = SurrogateSeparation.apply(
                filter: separationFilter, to: separationNoisy
            )
            func broadbandSNR(_ corrected: [[Double]]) -> Double {
                var cleanSquares = 0.0
                var residualSquares = 0.0
                for channel in separationCleanReferenced.indices {
                    for sample in separationCleanReferenced[channel].indices
                    where sample < corrected[channel].count {
                        let clean = separationCleanReferenced[channel][sample]
                        cleanSquares += clean * clean
                        let residual = clean - corrected[channel][sample]
                        residualSquares += residual * residual
                    }
                }
                return residualSquares > 1e-30
                    ? (cleanSquares / residualSquares).squareRoot() : .infinity
            }
            let correctedSNR = broadbandSNR(separationCorrected)
            let uncorrectedSNR = broadbandSNR(separationNoisy)
            outcomes.append(Outcome(
                name: "Surrogate separation improves SNR against a known BCG",
                snr: correctedSNR,
                passed: correctedSNR > 1.8 * uncorrectedSNR
                    && separationTopographies.count == 4
                    && (separationComponents?.acceptedBeatCount ?? 0)
                        > (separationComponents?.candidateBeatCount ?? 1) / 3,
                expectation: "broadband SNR improves by at least 1.8x at the BCG's true rank, "
                    + "with over a third of beats accepted by the pattern search"
            ))

            // ---------------------------------------------------------------
            // Roadmap 5.3: what the brain basis actually contributes.
            // ---------------------------------------------------------------
            //
            // The roadmap warned that a surrogate basis sitting on the simulated
            // sources would flatter this method. Swept with repeated seeds, the
            // harness says the opposite: correction quality *falls* as the brain
            // basis gets richer or closer (broadband SNR 2.13 / 2.20 / 1.82 /
            // 1.50 at 8 / 16 / 29 / 60 regional sources), and displacing the
            // basis by 40 mm slightly helps.
            //
            // The mechanism: separation is bought entirely by the asymmetry
            // between a penalized brain block and an unpenalized artifact block.
            // A more expressive brain model can represent the artifact too, so it
            // competes for it, and less of the artifact is left for the columns
            // meant to carry it.
            //
            // Pinned deterministically here rather than through the seeded sweep,
            // because the sweep's differences are close to its own spread.
            func artifactAbsorption(regionalSources: Int) throws -> Double {
                let brain = try SurrogateSeparation.brainModel(
                    head: separationConfig.sphericalHeadModel, montage: separationMontage,
                    count: regionalSources, reference: .average,
                    terms: separationConfig.leadFieldTerms
                )
                let filter = SurrogateSeparation.spatialFilter(
                    brain: brain, artifactTopographies: separationTopographies,
                    brainRegularization: 0.02
                )
                // Feed the filter a BCG generator topography that the artifact
                // model is meant to remove, and see how much survives.
                guard let generator = separationBCG.generatorSet?.generators.first else { return 0 }
                let column = (0..<separationMontage.electrodes.count).map {
                    $0 < generator.topography.count ? generator.topography[$0] : 0
                }
                let passed = SurrogateSeparation.apply(filter: filter, to: column.map { [$0] })
                let inputNorm = column.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
                let outputNorm = passed.reduce(0.0) { $0 + $1[0] * $1[0] }.squareRoot()
                return inputNorm > 1e-15 ? outputNorm / inputNorm : 0
            }
            let sparseAbsorption = try artifactAbsorption(regionalSources: 8)
            let richAbsorption = try artifactAbsorption(regionalSources: 60)
            outcomes.append(Outcome(
                name: "A richer brain basis absorbs more artifact, weakening the separation",
                snr: richAbsorption - sparseAbsorption,
                passed: richAbsorption > sparseAbsorption,
                expectation: "more of a BCG generator topography survives the filter with 60 "
                    + "regional sources than with 8 — the brain block competing for the artifact"
            ))

            // ---------------------------------------------------------------
            // Roadmap 4.3: placeable ERP components.
            // ---------------------------------------------------------------

            var placedConfig = SimulationConfig.default
            placedConfig.channelCount = 64
            placedConfig.samplingRate = 250
            placedConfig.durationSeconds = 40
            placedConfig.eegGenerationModel = .dipole
            placedConfig.recordingReference = .average
            let placedMontage = Montage.standard(count: placedConfig.channelCount)

            func placedInjection(
                _ components: [ERPComponentConfig]?
            ) throws -> ERPInjection? {
                var config = placedConfig
                var design = ERPConfig()
                design.trialCount = 20
                design.interStimulusIntervalSeconds = 1.5
                design.omissionRate = 0
                design.components = components
                config.erp = design
                var channels = [[Double]](
                    repeating: [Double](repeating: 0, count: config.sampleCount),
                    count: config.channelCount
                )
                return try ERPGenerator.inject(
                    into: &channels, config: config, montage: placedMontage
                )
            }

            let bilateral = [
                ERPComponentConfig(
                    id: "left",
                    positionMillimetres: Vector3D(x: -49, y: -14, z: 0),
                    orientation: Vector3D(x: -0.17, y: -0.25, z: -0.95),
                    peakLatencySeconds: 0.101, widthSeconds: 0.028
                ),
                ERPComponentConfig(
                    id: "right",
                    positionMillimetres: Vector3D(x: 49, y: -11, z: 1),
                    orientation: Vector3D(x: 0.15, y: -0.24, z: -0.96),
                    peakLatencySeconds: 0.103, widthSeconds: 0.028
                )
            ]
            let legacyERP = try placedInjection(nil)
            let placedERP = try placedInjection(bilateral)

            // The 4.3 defect, demonstrated rather than asserted. The old path
            // derived the ERP source from `makeSources`, so it sat *exactly* on
            // ongoing-EEG source #1 — signal and noise in the same place.
            let legacyDistance = legacyERP?.componentSources.first?
                .nearestNeuralSourceMillimetres ?? -1
            let placedDistances = (placedERP?.componentSources ?? [])
                .compactMap(\.nearestNeuralSourceMillimetres)
            outcomes.append(Outcome(
                name: "A placed ERP component no longer sits on an ongoing-EEG source",
                snr: placedDistances.min() ?? 0,
                passed: legacyDistance < 1e-6
                    && placedDistances.count == 2
                    && (placedDistances.min() ?? 0) > 10,
                expectation: "the legacy component is 0 mm from a neural source; placed "
                    + "components are more than 10 mm away, and the distance is in the sidecar"
            ))

            // Placement is honoured: the emitted topography must match a lead
            // field computed directly at the stated coordinates.
            if let placedERP, placedERP.componentSources.count == 2 {
                var worstTopographyError = 0.0
                for component in placedERP.componentSources {
                    let field = try SphericalForwardModel.leadField(
                        head: placedConfig.sphericalHeadModel, montage: placedMontage,
                        sources: [component.source], reference: .average,
                        terms: placedConfig.leadFieldTerms
                    )
                    var expected = field.matrixMicrovoltsPerNanoampereMeter.map { $0[0] }
                    let peak = expected.map(abs).max() ?? 1
                    if peak > 0 { for index in expected.indices { expected[index] /= peak } }
                    let error = zip(component.topography, expected)
                        .map { abs($0 - $1) }.max() ?? 1
                    worstTopographyError = max(worstTopographyError, error)
                }
                // A bilateral pair must actually be bilateral: the two
                // topographies should be near mirror images, which is the whole
                // point of being able to enter a published dipole model.
                let left = placedERP.componentSources[0].topography
                let right = placedERP.componentSources[1].topography
                let mirrorCorrelation = DipoleEEGGenerator.pearson(left, right)
                outcomes.append(Outcome(
                    name: "Placed ERP topographies match their stated coordinates",
                    snr: worstTopographyError,
                    passed: worstTopographyError < 1e-9 && mirrorCorrelation < 0.999,
                    expectation: "each topography reproduces a directly computed lead field to "
                        + "1e-9, and the bilateral pair is not one degenerate pattern"
                ))

                // Components of a real complex do not jitter together.
                let leftLatencies = placedERP.componentSources[0].trialLatencySeconds
                let rightLatencies = placedERP.componentSources[1].trialLatencySeconds
                let jitterCorrelation = abs(
                    DipoleEEGGenerator.pearson(leftLatencies, rightLatencies)
                )
                outcomes.append(Outcome(
                    name: "Each ERP component jitters on its own stream",
                    snr: jitterCorrelation,
                    passed: jitterCorrelation < 0.5
                        && leftLatencies.count == 20 && rightLatencies.count == 20,
                    expectation: "per-trial latencies of two components are close to uncorrelated, "
                        + "which is the confound single-trial estimators exist to resolve"
                ))
            }

            // 4.5a: the convergence check now travels with the call site, because
            // a placed component can sit at any depth and the run-level check
            // covers only the ongoing sources.
            var deepComponent = ERPComponentConfig(id: "deep")
            deepComponent.positionMillimetres = Vector3D(x: 0, y: 0, z: 71.5)
            var deepConfig = placedConfig
            deepConfig.leadFieldTerms = 8
            var deepDesign = ERPConfig()
            deepDesign.trialCount = 4
            deepDesign.components = [deepComponent]
            deepConfig.erp = deepDesign
            var deepChannels = [[Double]](
                repeating: [Double](repeating: 0, count: deepConfig.sampleCount),
                count: deepConfig.channelCount
            )
            var deepRejected = false
            do {
                _ = try ERPGenerator.inject(
                    into: &deepChannels, config: deepConfig, montage: placedMontage
                )
            } catch {
                deepRejected = true
            }
            outcomes.append(Outcome(
                name: "An under-resolved placed component is rejected, not silently wrong",
                snr: deepRejected ? 0 : 1,
                passed: deepRejected,
                expectation: "a component 0.5 mm inside the brain boundary with 8 series terms "
                    + "fails the convergence check rather than producing a plausible topography"
            ))

            // ---------------------------------------------------------------
            // Roadmap 5.3: the Rusiniak evaluation criteria.
            // ---------------------------------------------------------------

            // Explained variance must be exactly 1 when the data lies in the
            // model span, and must fall when something outside it is added.
            // Both halves are needed: a metric that always returned 1 would pass
            // the first on its own.
            let evChannels = 16
            let evSamples = 40
            var evModel = [[Double]](repeating: [Double](repeating: 0, count: evChannels), count: 2)
            var evSeed = GaussianSource(seed: 0xE_1_7A_2C)
            for component in 0..<2 {
                for channel in 0..<evChannels { evModel[component][channel] = evSeed.gaussian() }
            }
            var inModel = [[Double]](
                repeating: [Double](repeating: 0, count: evSamples), count: evChannels
            )
            for sample in 0..<evSamples {
                let a = sin(Double(sample) * 0.3)
                let b = cos(Double(sample) * 0.11)
                for channel in 0..<evChannels {
                    inModel[channel][sample] = a * evModel[0][channel] + b * evModel[1][channel]
                }
            }
            let insideVariance = ERPEvaluation.explainedVariance(
                average: inModel, samplingRate: 100, preSamples: 0,
                modelTopographies: evModel, startSeconds: 0, endSeconds: 0.4
            )
            var withForeign = inModel
            var foreign = [Double](repeating: 0, count: evChannels)
            for channel in 0..<evChannels { foreign[channel] = evSeed.gaussian() }
            for sample in 0..<evSamples {
                for channel in 0..<evChannels {
                    withForeign[channel][sample] += 3 * foreign[channel] * sin(Double(sample) * 0.7)
                }
            }
            let contaminatedVariance = ERPEvaluation.explainedVariance(
                average: withForeign, samplingRate: 100, preSamples: 0,
                modelTopographies: evModel, startSeconds: 0, endSeconds: 0.4
            )
            outcomes.append(Outcome(
                name: "Explained variance is exact in the model span and falls outside it",
                snr: contaminatedVariance,
                passed: abs(insideVariance - 1) < 1e-9 && contaminatedVariance < 0.7,
                expectation: "1.0 for data built from the model topographies, below 0.7 once a "
                    + "foreign topography is added"
            ))

            // Trial rejection has to actually reject. The thresholds are the
            // paper's: 120 µV peak-to-peak, 75 µV per sample.
            var rejectionConfig = SimulationConfig.default
            rejectionConfig.samplingRate = 250
            let rejectionRate = rejectionConfig.samplingRate
            let rejectionOnsets = [1.0, 3.0, 5.0, 7.0]
            var rejectionChannels = [[Double]](
                repeating: [Double](repeating: 0, count: Int(9 * rejectionRate)), count: 4
            )
            // A clean response on every trial, then one trial spoiled by a large
            // excursion that must cost exactly one accepted epoch.
            for onset in rejectionOnsets {
                let start = Int(onset * rejectionRate)
                for offset in 0..<Int(0.2 * rejectionRate) {
                    for channel in rejectionChannels.indices {
                        rejectionChannels[channel][start + offset] += 5 * sin(
                            Double(offset) / (0.2 * rejectionRate) * Double.pi
                        )
                    }
                }
            }
            let spoiled = Int(rejectionOnsets[2] * rejectionRate)
            for offset in 0..<20 { rejectionChannels[0][spoiled + offset] += 400 }

            let rejectionResult = ERPEvaluation.evaluate(
                channels: rejectionChannels, samplingRate: rejectionRate,
                onsets: rejectionOnsets, conditions: rejectionOnsets.map { _ in "target" },
                modelTopographies: [[1, 0, 0, 0]],
                fwhmStartSeconds: 0.05, fwhmEndSeconds: 0.15
            )
            outcomes.append(Outcome(
                name: "Epoch rejection drops exactly the spoiled trial",
                snr: Double(rejectionResult?.acceptedTrials ?? -1),
                passed: rejectionResult?.candidateTrials == 4
                    && rejectionResult?.acceptedTrials == 3,
                expectation: "4 candidate epochs, 3 accepted — the one carrying a 400 µV "
                    + "excursion fails the amplitude and gradient thresholds"
            ))

            var bridged = [[1.0, 2, 3], [3.0, 4, 5], [7.0, 8, 9]]
            let pairs = [ChannelBridge(firstChannel: 1, secondChannel: 2)]
            _ = AdditionalArtifactModel.applyBridging(to: &bridged, pairs: pairs)
            outcomes.append(Outcome(
                name: "True electrode bridging makes a channel pair share one signal",
                snr: bridged[0] == bridged[1] ? 0 : 1,
                passed: bridged[0] == [2, 3, 4] && bridged[1] == bridged[0]
                    && bridged[2] == [7, 8, 9],
                expectation: "the requested pair is sample-identical at its mean; other channels are unchanged"
            ))

            var additiveMixture = [
                [3.0, -2, 7, 5],
                [1.0, 8, -4, 2],
                [-6.0, 3, 9, -1]
            ]
            let unreferred = additiveMixture
            EEGReferencing.apply(.average, to: &additiveMixture)
            var infinityReferenced = unreferred
            EEGReferencing.apply(.infinity, to: &infinityReferenced)
            let referenceResidual = EEGReferencing.maximumAbsoluteMean(additiveMixture)
            var generatedReferenceConfig = SimulationConfig.default
            generatedReferenceConfig.channelCount = 20
            generatedReferenceConfig.samplingRate = 128
            generatedReferenceConfig.durationSeconds = 2
            var generatedReferenceSource = GaussianSource(seed: generatedReferenceConfig.seed)
            let generatedReferenceEEG = EEGGenerator.generate(
                config: generatedReferenceConfig,
                montage: Montage.standard(count: generatedReferenceConfig.channelCount),
                source: &generatedReferenceSource
            )
            outcomes.append(Outcome(
                name: "One recording reference is enforced at the additive boundary",
                snr: referenceResidual,
                passed: referenceResidual < 1e-12 && infinityReferenced == unreferred
                    && EEGReferencing.maximumAbsoluteMean(generatedReferenceEEG.channels) < 1e-12
                    && abs(generatedReferenceEEG.standardDeviation
                        - generatedReferenceConfig.eegTargetStdMicrovolts) < 1e-10,
                expectation: "average reference preserves target EEG scale and zero channel mean; infinity is unchanged"
            ))

            // The claim of roadmap 4.6 is about the *complete* mixture, not the
            // neural layer alone: the BCG, ocular and muscle layers used to be
            // injected in no particular reference at all. Build one recording
            // carrying all of them and check the boundary actually lands.
            //
            // The infinity arm is the part that makes this a test. Without it,
            // "the channel mean is zero" could pass simply because every layer
            // happened to be constructed zero-mean, and the referencing step
            // could be doing nothing whatsoever.
            var compositeConfig = SimulationConfig.default
            compositeConfig.channelCount = 20
            compositeConfig.samplingRate = 128
            compositeConfig.durationSeconds = 6
            compositeConfig.blinksPerMinute = 20
            compositeConfig.saccadesPerMinute = 10
            compositeConfig.emg = EMGConfig()
            let compositeMontage = Montage.standard(count: compositeConfig.channelCount)

            func buildComposite(reference: EEGReference) -> [[Double]] {
                var config = compositeConfig
                config.recordingReference = reference
                var neural = GaussianSource(seed: config.seed)
                var channels = EEGGenerator.generate(
                    config: config, montage: compositeMontage, source: &neural
                ).channels
                _ = GradientArtifactModel.inject(
                    into: &channels, config: config, montage: compositeMontage, template: nil
                )
                var bcgStream = GaussianSource(seed: SimulationSeedStreams.bcg(base: config.seed))
                _ = BCGArtifactModel.inject(
                    into: &channels, config: config, montage: compositeMontage, source: &bcgStream
                )
                var ocularStream = GaussianSource(seed: SimulationSeedStreams.ocular(base: config.seed))
                _ = OcularArtifactModel.inject(
                    into: &channels, config: config, montage: compositeMontage, source: &ocularStream
                )
                var emgStream = GaussianSource(seed: SimulationSeedStreams.emg(base: config.seed))
                _ = EMGArtifactModel.inject(
                    into: &channels, config: config, montage: compositeMontage, source: &emgStream
                )
                EEGReferencing.apply(reference, to: &channels)
                return channels
            }

            let averagedComposite = buildComposite(reference: .average)
            let infinityComposite = buildComposite(reference: .infinity)
            let compositeResidual = EEGReferencing.maximumAbsoluteMean(averagedComposite)
            let infinityCommonMode = EEGReferencing.maximumAbsoluteMean(infinityComposite)
            outcomes.append(Outcome(
                name: "Every artifact layer meets one reference in the complete mixture",
                snr: compositeResidual,
                passed: compositeResidual < 1e-9
                    && infinityCommonMode > 1,
                expectation: "EEG+gradient+BCG+ocular+EMG average-reference to zero mean, "
                    + "while the same mixture at infinity keeps a common mode above 1 µV"
            ))

            var referenceConfig = SimulationConfig.default
            referenceConfig.channelCount = 3
            referenceConfig.durationSeconds = 4
            var reference = BadReferenceConfig()
            reference.amplitudeMicrovolts = 25
            referenceConfig.badReference = reference
            var referenced = [[Double]](
                repeating: [Double](repeating: 0, count: referenceConfig.sampleCount), count: 3
            )
            let referenceTruth = AdditionalArtifactModel.injectAdditive(
                into: &referenced, config: referenceConfig,
                montage: Montage.standard(count: referenceConfig.channelCount)
            )
            outcomes.append(Outcome(
                name: "A bad reference contaminates every channel identically",
                snr: referenceTruth.badReferenceRMSMicrovolts ?? 0,
                passed: referenced[0] == referenced[1] && referenced[1] == referenced[2]
                    && abs((referenceTruth.badReferenceRMSMicrovolts ?? 0) - 25) < 1e-9,
                expectation: "sample-identical common contamination at the requested 25 µV RMS"
            ))

            var clipped = [[-100.0, -40, 0, 40, 100], [1, 2, 3, 4, 5]]
            let counts = AdditionalArtifactModel.applyClipping(
                to: &clipped, thresholdMicrovolts: 40
            )
            outcomes.append(Outcome(
                name: "Amplifier saturation applies hard symmetric rails",
                snr: Double(counts.reduce(0, +)),
                passed: clipped[0] == [-40, -40, 0, 40, 40]
                    && clipped[1] == [1, 2, 3, 4, 5] && counts == [2, 0],
                expectation: "only out-of-range samples clamp to ±40 µV and are counted per channel"
            ))
        } catch {
            outcomes.append(Outcome(
                name: "Additional artifact families",
                snr: .infinity, passed: false,
                expectation: "deterministic physiology and recording defects (\(error.localizedDescription))"
            ))
        }

        return outcomes
    }
}
