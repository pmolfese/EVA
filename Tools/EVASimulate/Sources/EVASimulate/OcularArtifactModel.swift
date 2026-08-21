//
//  OcularArtifactModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Blinks and eye movements. These are *not* part of the Grouiller forward
//  model — that paper states its synthetic data were free of ocular and muscular
//  artifacts, and the defaults here keep them off so the paper reproduction is
//  unchanged. They exist for teaching: an artifact everybody recognizes on
//  sight, with a known ground truth underneath it.
//
//  Two mechanisms, because they look and behave differently:
//
//  * A **blink** is the eyelid sweeping across the cornea, briefly shorting the
//    corneoretinal dipole toward the scalp. It is a transient — a smooth
//    positive hump of 200-400 ms, largest at Fp1/Fp2, falling off steeply and
//    going slightly negative posteriorly.
//
//  * An **eye movement** is that same standing dipole *rotating*. The scalp
//    potential therefore tracks gaze position, not gaze velocity: it steps to a
//    new level and stays there until the eyes move again. That is why the
//    classic HEOG trace is a square wave rather than a train of spikes, and it
//    is why this model generates a gaze position signal and projects it, rather
//    than injecting a fixed waveform per event.
//
//  Getting that second one right matters for demos: a student who sees square
//  steps in the frontal channels and opposite polarity at F7 versus F8 has
//  learned something true about the physics. A train of identical bumps would
//  have taught them something false.
//

import Foundation

nonisolated struct OcularInjection: Sendable {
    var blinkSeconds: [Double]
    var saccadeSeconds: [Double]
    /// Vertical EOG, as a bipolar pair above and below one eye would see it.
    var veog: [Double]
    /// Horizontal EOG, as an outer-canthi bipolar pair would see it.
    var heog: [Double]
    var blinkTopography: [Double]
    var horizontalTopography: [Double]
    var verticalTopography: [Double]
}

nonisolated enum OcularArtifactModel {

    /// Direction of the eyes from the head centre: forward and a little below
    /// the vertex plane, which is where Fp1/Fp2 sit.
    static let eyeDirection: (x: Double, y: Double, z: Double) = {
        let raw = (x: 0.0, y: 0.95, z: 0.20)
        let length = (raw.x * raw.x + raw.y * raw.y + raw.z * raw.z).squareRoot()
        return (raw.x / length, raw.y / length, raw.z / length)
    }()

    static func inject(
        into channels: inout [[Double]],
        config: SimulationConfig,
        montage: Montage,
        source: inout GaussianSource
    ) -> OcularInjection {
        let sampleCount = config.sampleCount
        let positions = montage.positions

        let blinkTopography = blinkTopography(positions: positions)
        let horizontalTopography = horizontalTopography(positions: positions)

        // Vertical eye movement shares the blink's topography — same dipole,
        // same projection — so it is not modelled separately.
        let verticalTopography = blinkTopography

        var blinkSignal = [Double](repeating: 0, count: sampleCount)
        var blinkTimes: [Double] = []
        if config.blinksPerMinute > 0 {
            let template = blinkTemplate(config: config)
            var t = 1.0 + 2 * source.uniform()
            let meanInterval = 60 / config.blinksPerMinute
            while t < config.durationSeconds {
                blinkTimes.append(t)
                // Amplitude varies beat to beat like everything else about a
                // body; a metronomic blink train looks synthetic immediately.
                let amplitude = max(0.3, 1 + 0.25 * source.gaussian())
                template.add(
                    into: &blinkSignal,
                    outputRate: config.samplingRate,
                    startSeconds: t,
                    scale: amplitude
                )
                // Exponential intervals with a refractory floor: blinks cluster,
                // but nobody blinks twice in 300 ms.
                let interval = -meanInterval * log(max(1e-9, source.uniform()))
                t += max(1.0, interval)
            }
        }

        var gazeHorizontal = [Double](repeating: 0, count: sampleCount)
        var gazeVertical = [Double](repeating: 0, count: sampleCount)
        var saccadeTimes: [Double] = []
        if config.saccadesPerMinute > 0 {
            let meanInterval = 60 / config.saccadesPerMinute
            let transitionSamples = max(1, Int(config.saccadeTransitionSeconds * config.samplingRate))

            var currentH = 0.0
            var currentV = 0.0
            var index = 0
            var nextSaccade = 0.5 + source.uniform() * meanInterval

            while index < sampleCount {
                let time = Double(index) / config.samplingRate
                if time >= nextSaccade {
                    saccadeTimes.append(time)
                    // Gaze wanders around centre and is pulled back toward it,
                    // rather than performing a random walk off to one side.
                    let targetH = max(-1, min(1, 0.6 * source.gaussian() - 0.3 * currentH))
                    let targetV = max(-1, min(1, 0.4 * source.gaussian() - 0.3 * currentV))
                    let startH = currentH
                    let startV = currentV

                    for step in 0..<transitionSamples {
                        let position = index + step
                        guard position < sampleCount else { break }
                        // Smoothstep: a saccade accelerates and decelerates, it
                        // does not jump.
                        let u = Double(step + 1) / Double(transitionSamples)
                        let eased = u * u * (3 - 2 * u)
                        gazeHorizontal[position] = startH + (targetH - startH) * eased
                        gazeVertical[position] = startV + (targetV - startV) * eased
                    }
                    currentH = targetH
                    currentV = targetV
                    index += transitionSamples
                    let interval = -meanInterval * log(max(1e-9, source.uniform()))
                    nextSaccade = time + max(0.15, interval)
                    continue
                }
                gazeHorizontal[index] = currentH
                gazeVertical[index] = currentV
                index += 1
            }
        }

        for channel in channels.indices {
            guard channel < positions.count else { break }
            let blinkWeight = config.blinkAmplitudeMicrovolts * blinkTopography[channel]
            let horizontalWeight = config.eyeMovementAmplitudeMicrovolts * horizontalTopography[channel]
            let verticalWeight = config.eyeMovementAmplitudeMicrovolts * 0.75 * verticalTopography[channel]
            for i in 0..<sampleCount {
                channels[channel][i] += blinkWeight * blinkSignal[i]
                    + horizontalWeight * gazeHorizontal[i]
                    + verticalWeight * gazeVertical[i]
            }
        }

        // The EOG pair sits right at the source, so it sees more of the artifact
        // than any scalp electrode does — which is the entire reason a recording
        // carries one, and what makes regression-based ocular correction work.
        var veog = [Double](repeating: 0, count: sampleCount)
        var heog = [Double](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            veog[i] = config.blinkAmplitudeMicrovolts * 1.4 * blinkSignal[i]
                + config.eyeMovementAmplitudeMicrovolts * 1.2 * gazeVertical[i]
            heog[i] = config.eyeMovementAmplitudeMicrovolts * 1.8 * gazeHorizontal[i]
        }

        return OcularInjection(
            blinkSeconds: blinkTimes,
            saccadeSeconds: saccadeTimes,
            veog: veog,
            heog: heog,
            blinkTopography: blinkTopography,
            horizontalTopography: horizontalTopography,
            verticalTopography: verticalTopography
        )
    }

    /// A blink: fast rise, slower fall, peaking about 120 ms in and effectively
    /// over by 400 ms. Shaped as t^a·exp(−t/τ), which is the usual way to get
    /// that asymmetry without a piecewise definition.
    static func blinkTemplate(config: SimulationConfig) -> HighRateTemplate {
        let rate = config.artifactRate
        let count = max(8, Int((config.blinkDurationSeconds * rate).rounded()))
        var waveform = [Double](repeating: 0, count: count)
        let tau = 0.06
        for index in 0..<count {
            let t = Double(index) / rate
            waveform[index] = pow(t / tau, 2) * exp(-t / tau)
        }
        let peak = waveform.max() ?? 1
        if peak > 0 {
            for index in waveform.indices { waveform[index] /= peak }
        }
        return HighRateTemplate(samples: waveform, rate: rate)
    }

    /// Blink topography: steeply frontal, slightly negative behind the vertex.
    ///
    /// The cube of the cosine to the eyes is not a field solution — a proper one
    /// would place dipoles in a head model and solve — but it reproduces what
    /// matters for recognizing a blink on screen: roughly full amplitude at
    /// Fp1/Fp2, about a quarter of it at F3/F4, nothing at Cz, and a slight
    /// polarity reversal posteriorly.
    static func blinkTopography(positions: [(x: Double, y: Double, z: Double)]) -> [Double] {
        var weights = positions.map { position -> Double in
            let projection = position.x * eyeDirection.x
                + position.y * eyeDirection.y
                + position.z * eyeDirection.z
            return pow(max(0, projection), 3) - 0.05
        }
        let peak = weights.map(abs).max() ?? 1
        if peak > 0 {
            for index in weights.indices { weights[index] /= peak }
        }
        return weights
    }

    /// Horizontal eye movement: antisymmetric left to right, largest at the
    /// lateral frontal sites (F7 and F8), which is exactly where a real HEOG
    /// shows up.
    static func horizontalTopography(positions: [(x: Double, y: Double, z: Double)]) -> [Double] {
        var weights = positions.map { position -> Double in
            let projection = position.x * eyeDirection.x
                + position.y * eyeDirection.y
                + position.z * eyeDirection.z
            return position.x * pow(max(0, projection), 1.5)
        }
        let peak = weights.map(abs).max() ?? 1
        if peak > 0 {
            for index in weights.indices { weights[index] /= peak }
        }
        return weights
    }
}
