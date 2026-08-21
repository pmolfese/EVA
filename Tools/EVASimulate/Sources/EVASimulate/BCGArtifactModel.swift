//
//  BCGArtifactModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The ballistocardiogram. Unlike the gradient artifact, the BCG is genuinely
//  non-stationary — its timing, amplitude and shape all vary from beat to beat —
//  and it sits squarely inside the EEG's own band (1-10 Hz), so nothing can be
//  filtered away without cost. The paper models five separate sources of
//  variability, all reproduced here:
//
//  1. Heart rate wandering between 65 and 85 bpm on a one-minute cycle.
//  2. Mean amplitude per channel, 10-200 µV, spanning low field up through 3T.
//  3. Beat-to-beat amplitude that weights the previous beat and a fresh 15% draw
//     equally — so amplitude is correlated in time, not independent noise.
//  4. Per-channel latency of ~15 ms SD, from phase lags between vessel
//     pulsations across the head.
//  5. Jitter in *detected* QRS timing of ~20 ms, which the paper treats
//     separately from the artifact itself.
//
//  Point 5 deserves emphasis: the jitter is applied only to the event times
//  written into the recording, never to the injected waveform. A correction
//  method that leans on beat timing (AAS and its weighted/median relatives) sees
//  a mis-registered template; one that does not (reference-channel regression,
//  ICA, PCA) is unaffected. Reproducing the paper's Figure 5B — where AAS
//  degrades sharply with jitter and adaptive filtering stays flat — depends
//  entirely on keeping those two clocks separate, so do not "fix" this by
//  injecting at the detected times.
//

import Foundation

nonisolated struct BCGInjection: Sendable {
    /// Where each beat's artifact was actually injected, in seconds.
    var trueBeatSeconds: [Double]
    /// The same beats as an automatic QRS detector would report them — jittered.
    /// These are what gets written to the recording as events.
    var detectedBeatSeconds: [Double]
    /// Peak-to-peak amplitude of each beat, in µV, before per-channel scaling.
    var beatAmplitudesMicrovolts: [Double]
    /// Per-channel scale factor, including sign: the BCG reverses polarity
    /// across the head.
    var channelScales: [Double]
    /// Per-channel arrival latency, in seconds.
    var channelLatenciesSeconds: [Double]
    /// Across-channel mean BCG, kept so the motion-sensor channel can be
    /// derived from it.
    var meanWaveform: [Double]
}

nonisolated enum BCGArtifactModel {

    static func inject(
        into channels: inout [[Double]],
        config: SimulationConfig,
        source: inout GaussianSource
    ) -> BCGInjection {
        let template = waveformTemplate(config: config)

        let beats = beatTimes(config: config)
        let amplitudes = beatAmplitudes(count: beats.count, config: config, source: &source)

        var scales = [Double](repeating: 0, count: config.channelCount)
        var latencies = [Double](repeating: 0, count: config.channelCount)
        for channel in 0..<config.channelCount {
            // A smooth spatial pattern that crosses zero, so some channels carry
            // an inverted BCG the way a real montage does. Spatial structure is
            // what PCA- and ICA-based methods key on, so a model that gave every
            // channel the same sign would flatter them.
            let phase = 2 * Double.pi * Double(channel) / Double(max(1, config.channelCount))
            scales[channel] = (0.35 + 0.65 * cos(phase)) * (1 + 0.1 * source.gaussian())
            latencies[channel] = config.bcgChannelLatencySDSeconds * source.gaussian()
        }

        var mean = [Double](repeating: 0, count: config.sampleCount)
        for (index, beat) in beats.enumerated() {
            let amplitude = amplitudes[index]
            for channel in channels.indices {
                template.add(
                    into: &channels[channel],
                    outputRate: config.samplingRate,
                    eventSeconds: beat + latencies[channel],
                    scale: amplitude * scales[channel]
                )
            }
            template.add(
                into: &mean,
                outputRate: config.samplingRate,
                eventSeconds: beat,
                scale: amplitude
            )
        }

        let detected = beats.map { beat in
            max(0, beat + config.qrsDetectionJitterSDSeconds * source.gaussian())
        }

        return BCGInjection(
            trueBeatSeconds: beats,
            detectedBeatSeconds: detected,
            beatAmplitudesMicrovolts: amplitudes,
            channelScales: scales,
            channelLatenciesSeconds: latencies,
            meanWaveform: mean
        )
    }

    /// Paper: "the heart rate was modulated smoothly between 65 and 85 beats per
    /// minute using a sine wave of one minute period." Beat times accumulate the
    /// instantaneous RR interval rather than being placed on a fixed grid, so
    /// the rate really does drift.
    static func beatTimes(config: SimulationConfig) -> [Double] {
        let mid = (config.heartRateMaxBPM + config.heartRateMinBPM) / 2
        let half = (config.heartRateMaxBPM - config.heartRateMinBPM) / 2
        let omega = 2 * Double.pi / max(config.heartRateCycleSeconds, 1e-9)

        var times: [Double] = []
        var t = 0.5
        while t < config.durationSeconds {
            times.append(t)
            let bpm = mid + half * sin(omega * t)
            t += 60 / max(bpm, 1)
        }
        return times
    }

    /// Paper: each beat's amplitude "[takes] into account equally the amplitude
    /// of the last event and a random fluctuation which followed a normal
    /// distribution with a standard deviation of 15% of the BCG mean amplitude."
    static func beatAmplitudes(
        count: Int,
        config: SimulationConfig,
        source: inout GaussianSource
    ) -> [Double] {
        let mean = config.bcgAmplitudeMicrovolts
        var amplitudes: [Double] = []
        amplitudes.reserveCapacity(count)
        var previous = mean
        for _ in 0..<count {
            let draw = mean * (1 + config.bcgAmplitudeJitterFraction * source.gaussian())
            let amplitude = 0.5 * (previous + draw)
            amplitudes.append(amplitude)
            previous = amplitude
        }
        return amplitudes
    }

    /// One beat's BCG, as a multiphasic wave built from four Gaussians and
    /// normalized to unit peak-to-peak.
    ///
    /// EVA's shape, not the paper's — they matched "global features of
    /// experimental recordings" without printing a waveform. The timings below
    /// put the dominant negative deflection around 120 ms after the R wave and
    /// the whole disturbance inside ~600 ms, which is where a real BCG lives.
    static func waveformTemplate(config: SimulationConfig) -> HighRateTemplate {
        let rate = config.artifactRate
        // The first lobe is centred 30 ms after the beat with a 20 ms width, so
        // the window has to open ~4 sigma before that or the waveform starts
        // partway up its own leading edge and every beat injects a step.
        let leadIn = 0.06
        let count = max(8, Int(((config.bcgWaveformSeconds + leadIn) * rate).rounded()))
        var waveform = [Double](repeating: 0, count: count)

        let lobes: [(center: Double, sigma: Double, amplitude: Double)] = [
            (0.030, 0.020, 0.30),
            (0.120, 0.030, -1.00),
            (0.220, 0.040, 0.80),
            (0.380, 0.060, -0.35)
        ]
        for index in 0..<count {
            let t = Double(index) / rate - leadIn
            var value = 0.0
            for lobe in lobes {
                let z = (t - lobe.center) / lobe.sigma
                value += lobe.amplitude * exp(-0.5 * z * z)
            }
            waveform[index] = value
        }

        GradientArtifactModel.normalizeToUnitPeakToPeak(&waveform)
        return HighRateTemplate(samples: waveform, rate: rate, leadInSeconds: leadIn)
    }

    // MARK: - Auxiliary reference channels

    /// A synthetic ECG at the true beat times, so R-wave detection is exercised
    /// rather than bypassed. Amplitude is ~1 mV, the usual scale for a scalp-lead
    /// ECG recorded through an EEG amplifier.
    static func ecgChannel(beats: [Double], config: SimulationConfig) -> [Double] {
        var channel = [Double](repeating: 0, count: config.sampleCount)
        let rate = config.artifactRate

        // Lobes are defined relative to the R peak, and the window is sized to
        // contain all of them with margin: 5 sigma in front of the P wave and
        // past the T wave. Sizing it any tighter truncates a Gaussian mid-slope,
        // and since every beat reuses this template, that truncation becomes a
        // step discontinuity repeating at the heart rate — small in amplitude,
        // but broadband, obvious once filtered, and wrong.
        let lobes: [(offset: Double, sigma: Double, amplitude: Double)] = [
            (-0.160, 0.020, 0.15),   // P
            (-0.020, 0.006, -0.10),  // Q
            (0.000, 0.008, 1.00),    // R
            (0.020, 0.008, -0.25),   // S
            (0.220, 0.040, 0.30)     // T
        ]
        let leadIn = 0.28
        let tailOut = 0.42
        let count = max(8, Int(((leadIn + tailOut) * rate).rounded()))
        var beatWaveform = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(index) / rate - leadIn
            var value = 0.0
            for lobe in lobes {
                let z = (t - lobe.offset) / lobe.sigma
                value += lobe.amplitude * exp(-0.5 * z * z)
            }
            beatWaveform[index] = value
        }
        let template = HighRateTemplate(samples: beatWaveform, rate: rate, leadInSeconds: leadIn)

        for beat in beats {
            template.add(
                into: &channel,
                outputRate: config.samplingRate,
                eventSeconds: beat,
                scale: config.ecgAmplitudeMicrovolts
            )
        }

        // Slow baseline wander, as respiration and electrode drift produce. A
        // dead-flat isoelectric line between beats reads as synthetic at a
        // glance, and a class demo of high-pass filtering needs something for
        // the filter to actually remove.
        let wanderAmplitude = config.ecgAmplitudeMicrovolts * 0.03
        for index in channel.indices {
            let t = Double(index) / config.samplingRate
            channel[index] += wanderAmplitude
                * (sin(2 * Double.pi * 0.23 * t) + 0.5 * sin(2 * Double.pi * 0.07 * t + 1.1))
        }
        return channel
    }

    /// A modelled motion sensor, per the paper's Kalman-filtering section: the
    /// sensor sees the BCG through a saturating nonlinearity, sigmoid(a·x) with
    /// a = 0.1, "so as to induce a strong saturation of motion signal, thereby
    /// modelling strong nonlinear effects".
    ///
    /// The nonlinearity is the point. A reference channel that were a linear
    /// copy of the artifact would make regression-based correction trivially
    /// perfect and tell you nothing about how it behaves on a real carbon-wire
    /// loop or piezo sensor.
    static func motionSensorChannel(meanBCG: [Double], gain: Double) -> [Double] {
        meanBCG.map { value in
            let sigmoid = 1 / (1 + exp(-gain * value))
            // Centered and scaled to a plausible sensor range in the same units
            // as the rest of the file.
            return (sigmoid - 0.5) * 200
        }
    }
}
