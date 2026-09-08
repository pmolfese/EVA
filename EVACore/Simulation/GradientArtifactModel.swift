//
//  GradientArtifactModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The imaging (gradient) artifact. Three properties of the real thing matter
//  for judging a correction method, and all three are modelled here:
//
//  1. It is enormous — up to several mV, against ~11 µV of EEG.
//  2. Successive slice artifacts are *not* identical on the EEG's sample grid,
//     because the EEG and MRI clocks drift against each other (152 µs/s on the
//     paper's rig). This is what leaves residual spikes after template
//     subtraction, and it is why the correction problem is not trivial.
//  3. Its amplitude wanders slowly through a scan — subject motion, temperature,
//     mechanical drift — so a template averaged over many volumes fits none of
//     them exactly. The paper models this as a 200 s sine and finds it is the
//     parameter that most separates the methods (their Figure 4B).
//
//  The *shape* of the synthetic waveform is EVA's invention, not the paper's:
//  they used a template measured on their own 3T system. It is built here as the
//  time derivative of a modelled gradient waveform (slice-select trapezoid plus
//  an EPI readout train), because the induced EMF is proportional to dB/dt —
//  which gets the broadband, spiky character right for the right reason. For any
//  result that turns on waveform shape, load a measured template instead with
//  `--gradient-template`.
//

import Foundation

nonisolated struct GradientInjection: Sendable {
    /// Continuous onset time of each volume, on the EEG clock, in seconds.
    var volumeOnsetsSeconds: [Double]
    /// Onsets after quantization to the EEG sample grid — what a recorded TREV
    /// marker actually carries, and what a correction algorithm gets to use.
    var quantizedVolumeOnsetsSeconds: [Double]
    /// Continuous onset of every slice artifact, on the EEG clock.
    var sliceOnsetsSeconds: [Double]
    /// Peak-to-peak artifact amplitude assigned to each channel, in µV.
    var channelAmplitudesMicrovolts: [Double]
}

nonisolated enum GradientArtifactModel {

    /// Adds the imaging artifact into `channels` in place and returns what was
    /// injected, for the truth sidecar.
    static func inject(
        into channels: inout [[Double]],
        config: SimulationConfig,
        montage: Montage,
        template externalTemplate: HighRateTemplate?
    ) -> GradientInjection {
        let template = externalTemplate ?? syntheticTemplate(config: config)
        let antiAliased = antiAliasedTemplate(template, config: config)

        let drift = 1 + config.clockOffsetMicrosecondsPerSecond * 1e-6
        let sliceInterval = config.sliceIntervalSeconds
        let modulationOmega = 2 * Double.pi / max(config.slowModulationPeriodSeconds, 1e-9)

        var volumeOnsets: [Double] = []
        var quantizedOnsets: [Double] = []
        var sliceOnsets: [Double] = []

        let amplitudes = channelAmplitudes(config: config, montage: montage)

        let scanStart = max(0, config.preScanSeconds)
        let scanEnd = max(scanStart, config.durationSeconds - max(0, config.postScanSeconds))

        for volume in 0..<config.volumeCount {
            // The scanner's clock says the volume starts here; the EEG's clock,
            // running at a slightly different rate, disagrees by a little more
            // with every volume. That accumulating disagreement is the whole
            // point — it is what stops successive artifacts from landing on the
            // same sub-sample phase.
            let onset = scanStart + Double(volume) * config.repetitionTimeSeconds * drift
            // A volume that would run past the end of scanning is not acquired
            // at all — the sequence stops between volumes, not mid-readout.
            guard onset + config.repetitionTimeSeconds <= scanEnd || volume == 0,
                  onset < scanEnd else { break }
            volumeOnsets.append(onset)
            quantizedOnsets.append(
                (onset * config.samplingRate).rounded(.down) / config.samplingRate
            )

            for slice in 0..<config.slicesPerVolume {
                let sliceOnset = onset + Double(slice) * sliceInterval * drift
                guard sliceOnset < scanEnd, sliceOnset < config.durationSeconds else { break }
                sliceOnsets.append(sliceOnset)

                let modulation = 1 + config.slowModulationFraction * sin(modulationOmega * sliceOnset)
                for channel in channels.indices {
                    antiAliased.add(
                        into: &channels[channel],
                        outputRate: config.samplingRate,
                        eventSeconds: sliceOnset,
                        scale: amplitudes[channel] * modulation
                    )
                }
            }
        }

        return GradientInjection(
            volumeOnsetsSeconds: volumeOnsets,
            quantizedVolumeOnsetsSeconds: quantizedOnsets,
            sliceOnsetsSeconds: sliceOnsets,
            channelAmplitudesMicrovolts: amplitudes
        )
    }

    /// Paper: artifact amplitude varies between channels, "from 0 up to
    /// 7000 µV peak-to-peak, to model observed differences in experimental
    /// data". Spread linearly across the montage.
    static func channelAmplitudes(config: SimulationConfig, montage: Montage) -> [Double] {
        let count = max(1, config.channelCount)
        guard count > 1 else { return [config.gradientAmplitudeMaxMicrovolts] }
        let span = config.gradientAmplitudeMaxMicrovolts - config.gradientAmplitudeMinMicrovolts

        // Amplitude follows electrode *position*, not channel number.
        //
        // Spreading it linearly across the channel index — which is what this
        // did before there was a montage — turns into "the artifact grows
        // steadily from Fp1 to O2" once the channels are a real 10-20 set, since
        // the montage is ordered front to back. That is not a property of any
        // scanner, and with a 14x range across the head it buries everything
        // else: a deliberately broken channel becomes invisible next to its
        // neighbours' artifact.
        //
        // The induced voltage depends on the area of the loop formed by the lead
        // and the head, so peripheral electrodes with longer leads pick up more
        // than ones near the vertex. Scaling with arc angle from the vertex
        // captures that, and leaves the variation uncorrelated with channel
        // order.
        guard montage.electrodes.count >= count else {
            return (0..<count).map { index in
                config.gradientAmplitudeMinMicrovolts + span * Double(index) / Double(count - 1)
            }
        }
        let thetas = montage.electrodes.prefix(count).map(\.thetaDegrees)
        let minimum = thetas.min() ?? 0
        let maximum = thetas.max() ?? 90
        let range = max(1e-9, maximum - minimum)
        return thetas.map { theta in
            config.gradientAmplitudeMinMicrovolts + span * (theta - minimum) / range
        }
    }

    /// Band-limits the modelled artifact the way an amplifier's anti-alias
    /// filter would, before anything point-samples it onto the EEG grid.
    ///
    /// Disabling this (`--artifact-anti-alias 0`) is not a nonsense setting: it
    /// models an amplifier whose anti-aliasing is inadequate for gradient-rate
    /// content, which is a real failure mode, and it lets the harness show how
    /// badly aliased artifact defeats template subtraction.
    static func antiAliasedTemplate(_ template: HighRateTemplate, config: SimulationConfig) -> HighRateTemplate {
        guard config.artifactAntiAliasFraction > 0 else { return template }
        let cutoff = config.artifactAntiAliasFraction * config.samplingRate / 2
        var filtered = SpectralNoise.lowPassed(
            template.samples,
            samplingRate: template.rate,
            cutoffHz: cutoff
        )
        // Re-normalize *after* filtering, not before. Most of an unfiltered
        // dB/dt waveform's energy sits above the output Nyquist, so a template
        // normalized before the anti-alias filter would land in the recording at
        // a small fraction of the requested amplitude — and `--gradient-amplitude
        // 7000` has to mean 7000 µV peak-to-peak in the file, since that is what
        // the paper's figure is measuring.
        normalizeToUnitPeakToPeak(&filtered)
        return HighRateTemplate(
            samples: filtered,
            rate: template.rate,
            leadInSeconds: template.leadInSeconds
        )
    }

    // MARK: - Synthetic waveform

    /// One slice's artifact, modelled as dB/dt of a slice-select trapezoid
    /// followed by an EPI readout train, normalized to unit peak-to-peak.
    static func syntheticTemplate(config: SimulationConfig) -> HighRateTemplate {
        let rate = config.artifactRate
        // A millisecond of quiet before the slice begins. Partly so the window
        // opens at a true baseline — the normalization below reads the baseline
        // off the ends, and cannot do that if the waveform is already ramping at
        // sample zero — and partly because it is what a real artifact epoch
        // looks like, the trigger arriving just before the gradients move.
        let leadIn = 0.001
        let count = max(8, Int(((config.sliceArtifactSeconds + leadIn) * rate).rounded()))
        var gradient = [Double](repeating: 0, count: count)

        let ramp = config.gradientRampSeconds

        // Slice selection: one trapezoid at the start of the slice.
        addTrapezoid(
            into: &gradient,
            rate: rate,
            startSeconds: leadIn,
            rampSeconds: ramp * 2,
            plateauSeconds: 0.001,
            amplitude: 1.0
        )

        // Readout: alternating trapezoids at the readout frequency, filling most
        // of the slice's artifact window.
        let halfPeriod = 1 / (2 * max(config.gradientReadoutHz, 1))
        let readoutStart = leadIn + 0.004
        let readoutEnd = leadIn + config.sliceArtifactSeconds * 0.95
        var t = readoutStart
        var polarity = 1.0
        while t + halfPeriod < readoutEnd {
            addTrapezoid(
                into: &gradient,
                rate: rate,
                startSeconds: t,
                rampSeconds: ramp,
                plateauSeconds: max(0, halfPeriod - 2 * ramp),
                amplitude: 0.6 * polarity
            )
            polarity = -polarity
            t += halfPeriod
        }

        // Induced EMF is proportional to dB/dt.
        var waveform = [Double](repeating: 0, count: count)
        for i in 1..<count {
            waveform[i] = (gradient[i] - gradient[i - 1]) * rate
        }

        normalizeToUnitPeakToPeak(&waveform)
        return HighRateTemplate(samples: waveform, rate: rate, leadInSeconds: leadIn)
    }

    private static func addTrapezoid(
        into buffer: inout [Double],
        rate: Double,
        startSeconds: Double,
        rampSeconds: Double,
        plateauSeconds: Double,
        amplitude: Double
    ) {
        let rampSamples = max(1, Int((rampSeconds * rate).rounded()))
        let plateauSamples = max(0, Int((plateauSeconds * rate).rounded()))
        var index = Int((startSeconds * rate).rounded())

        for step in 0..<rampSamples {
            guard index >= 0, index < buffer.count else { index += 1; continue }
            buffer[index] += amplitude * Double(step + 1) / Double(rampSamples)
            index += 1
        }
        for _ in 0..<plateauSamples {
            guard index >= 0, index < buffer.count else { index += 1; continue }
            buffer[index] += amplitude
            index += 1
        }
        for step in 0..<rampSamples {
            guard index >= 0, index < buffer.count else { index += 1; continue }
            buffer[index] += amplitude * Double(rampSamples - step - 1) / Double(rampSamples)
            index += 1
        }
    }

    /// Scales a waveform to unit peak-to-peak while keeping its *baseline* at
    /// zero.
    ///
    /// The baseline is taken from the ends of the window, not from the mean of
    /// the whole waveform. Centering on the mean is the obvious thing to write
    /// and it is wrong here: a waveform that sits at zero except for a few lobes
    /// has a non-zero mean, so subtracting it pushes the quiet parts of the
    /// template *off* zero. Every event then injects a small step that lasts as
    /// long as the template — a square wave at the heart rate, in the BCG's
    /// case, at about 5% of the artifact amplitude.
    ///
    /// Using the edges instead removes a genuine DC offset from a measured
    /// template (which is worth removing) without inventing one in a synthetic
    /// template that was already correct.
    static func normalizeToUnitPeakToPeak(_ x: inout [Double]) {
        guard let minimum = x.min(), let maximum = x.max() else { return }
        let span = maximum - minimum
        guard span > 1e-12 else { return }

        let edgeCount = max(1, x.count / 100)
        let leading = x.prefix(edgeCount).reduce(0, +) / Double(edgeCount)
        let trailing = x.suffix(edgeCount).reduce(0, +) / Double(edgeCount)
        let baseline = (leading + trailing) / 2

        for i in x.indices { x[i] = (x[i] - baseline) / span }
    }

    // MARK: - Measured templates

    /// Loads a measured slice-artifact template from a text file of one sample
    /// per line (or a single comma-separated row) and sinc-interpolates it up to
    /// the model's internal rate.
    ///
    /// The upsample factor must be an integer, which it is whenever the template
    /// was exported at the simulated recording rate. Zero-stuffing plus an ideal
    /// low-pass is exact sinc interpolation for a signal that is already band
    /// limited — which a template exported from a real recording is, by its own
    /// amplifier.
    static func loadTemplate(path: String, templateRate: Double, config: SimulationConfig) throws -> HighRateTemplate {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let values = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count > 8 else {
            throw SimulateError.badTemplate("\(path) contains \(values.count) usable numbers; need at least 8")
        }

        let ratio = config.artifactRate / templateRate
        let factor = Int(ratio.rounded())
        guard factor >= 1, abs(ratio - Double(factor)) < 1e-9 else {
            throw SimulateError.badTemplate(
                "template rate \(templateRate) Hz does not divide the model's internal rate "
                + "\(config.artifactRate) Hz by a whole number; adjust --artifact-oversample"
            )
        }
        guard factor > 1 else {
            var samples = values
            normalizeToUnitPeakToPeak(&samples)
            return HighRateTemplate(samples: samples, rate: templateRate)
        }

        var stuffed = [Double](repeating: 0, count: values.count * factor)
        for (index, value) in values.enumerated() {
            stuffed[index * factor] = value * Double(factor)
        }
        var interpolated = SpectralNoise.lowPassed(
            stuffed,
            samplingRate: config.artifactRate,
            cutoffHz: templateRate / 2
        )
        normalizeToUnitPeakToPeak(&interpolated)
        return HighRateTemplate(samples: interpolated, rate: config.artifactRate)
    }
}
