//
//  EMGArtifactModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Bursty surface electromyogram. Unlike the narrow-band neural sources, muscle
//  activity is broadband, irregular, and strongest near the active muscle. Three
//  source regions cover the common scalp-EEG pattern: left and right temporalis
//  plus posterior neck muscles. Each region has its own band-limited stochastic
//  carrier; smooth randomized burst envelopes prevent artificial spectral edges.
//

import Foundation

nonisolated enum EMGMuscle: String, Codable, Sendable, CaseIterable {
    case leftTemporalis = "left-temporalis"
    case rightTemporalis = "right-temporalis"
    case posteriorNeck = "posterior-neck"
}

nonisolated struct EMGBurstTruth: Codable, Sendable {
    var id: String
    var onsetSeconds: Double
    var durationSeconds: Double
    var muscle: EMGMuscle
    /// RMS carrier amplitude at the strongest electrode during the plateau.
    var amplitudeMicrovolts: Double
}

nonisolated struct EMGInjection: Sendable {
    var bursts: [EMGBurstTruth]
    var leftTemporalisTopography: [Double]
    var rightTemporalisTopography: [Double]
    var posteriorNeckTopography: [Double]
}

nonisolated enum EMGArtifactModel {

    static func inject(
        into channels: inout [[Double]],
        config: SimulationConfig,
        montage: Montage,
        source: inout GaussianSource
    ) -> EMGInjection? {
        guard let model = config.emg,
              model.burstsPerMinute > 0,
              model.amplitudeMicrovolts > 0 else { return nil }

        let topographies = topographies(montage: montage)
        let bursts = makeBursts(config: config, model: model, source: &source)
        guard !bursts.isEmpty else {
            return EMGInjection(
                bursts: [],
                leftTemporalisTopography: topographies.left,
                rightTemporalisTopography: topographies.right,
                posteriorNeckTopography: topographies.neck
            )
        }

        // One independent motor-unit mixture per anatomical source region.
        // Keeping the carrier continuous underneath the envelopes avoids
        // restarting every burst at the same phase or waveform.
        let sampleCount = config.sampleCount
        let leftCarrier = SpectralNoise.bandLimited(
            sampleCount: sampleCount, samplingRate: config.samplingRate,
            lowHz: model.lowHz, highHz: model.highHz, source: &source
        )
        let rightCarrier = SpectralNoise.bandLimited(
            sampleCount: sampleCount, samplingRate: config.samplingRate,
            lowHz: model.lowHz, highHz: model.highHz, source: &source
        )
        let neckCarrier = SpectralNoise.bandLimited(
            sampleCount: sampleCount, samplingRate: config.samplingRate,
            lowHz: model.lowHz, highHz: model.highHz, source: &source
        )

        for burst in bursts {
            let start = max(0, Int((burst.onsetSeconds * config.samplingRate).rounded()))
            let length = max(2, Int((burst.durationSeconds * config.samplingRate).rounded()))
            let end = min(sampleCount, start + length)
            guard start < end else { continue }

            let carrier: [Double]
            let weights: [Double]
            switch burst.muscle {
            case .leftTemporalis:
                carrier = leftCarrier
                weights = topographies.left
            case .rightTemporalis:
                carrier = rightCarrier
                weights = topographies.right
            case .posteriorNeck:
                carrier = neckCarrier
                weights = topographies.neck
            }

            for index in start..<end {
                let u = Double(index - start) / Double(max(1, end - start - 1))
                let value = burstEnvelope(u) * burst.amplitudeMicrovolts * carrier[index]
                for channel in channels.indices where channel < weights.count {
                    channels[channel][index] += weights[channel] * value
                }
            }
        }

        return EMGInjection(
            bursts: bursts,
            leftTemporalisTopography: topographies.left,
            rightTemporalisTopography: topographies.right,
            posteriorNeckTopography: topographies.neck
        )
    }

    static func makeBursts(
        config: SimulationConfig,
        model: EMGConfig,
        source: inout GaussianSource
    ) -> [EMGBurstTruth] {
        guard model.burstsPerMinute > 0 else { return [] }
        let meanInterval = 60 / model.burstsPerMinute
        var time = 0.5 + min(2, meanInterval) * source.uniform()
        var bursts: [EMGBurstTruth] = []

        while time < config.durationSeconds {
            let requestedDuration = model.burstDurationSeconds * (0.6 + 0.8 * source.uniform())
            let duration = min(requestedDuration, config.durationSeconds - time)
            guard duration >= 0.05 else { break }

            let draw = source.uniform()
            let muscle: EMGMuscle = draw < 0.4
                ? .leftTemporalis
                : (draw < 0.8 ? .rightTemporalis : .posteriorNeck)
            let amplitudeFactor = max(0.25, 1 + 0.30 * source.gaussian())
            bursts.append(EMGBurstTruth(
                id: String(format: "emg-%04d", bursts.count + 1),
                onsetSeconds: time,
                durationSeconds: duration,
                muscle: muscle,
                amplitudeMicrovolts: model.amplitudeMicrovolts * amplitudeFactor
            ))

            let stochasticInterval = -meanInterval * log(max(1e-12, source.uniform()))
            time += max(duration + 0.25, stochasticInterval)
        }
        return bursts
    }

    /// Tukey-like envelope with a 15% attack, plateau, and 20% release.
    /// Smoothstep makes both the value and first derivative meet the baseline.
    static func burstEnvelope(_ phase: Double) -> Double {
        let u = max(0, min(1, phase))
        if u < 0.15 { return smoothstep(u / 0.15) }
        if u > 0.80 { return smoothstep((1 - u) / 0.20) }
        return 1
    }

    private static func smoothstep(_ value: Double) -> Double {
        let u = max(0, min(1, value))
        return u * u * (3 - 2 * u)
    }

    static func topographies(
        montage: Montage
    ) -> (left: [Double], right: [Double], neck: [Double]) {
        // Centres are directions from the head centre in Montage's coordinate
        // frame (+x right, +y nose, +z vertex). They target F7/FT7, F8/FT8,
        // and the posterior-inferior O1/Oz/O2 region respectively.
        let left = localizedTopography(
            positions: montage.positions, center: (-0.80, 0.48, 0.28), sigmaRadians: 0.48
        )
        let right = localizedTopography(
            positions: montage.positions, center: (0.80, 0.48, 0.28), sigmaRadians: 0.48
        )
        let neck = localizedTopography(
            positions: montage.positions, center: (0, -0.94, 0.22), sigmaRadians: 0.55
        )
        return (left, right, neck)
    }

    private static func localizedTopography(
        positions: [(x: Double, y: Double, z: Double)],
        center: (Double, Double, Double),
        sigmaRadians: Double
    ) -> [Double] {
        let norm = (center.0 * center.0 + center.1 * center.1 + center.2 * center.2).squareRoot()
        let direction = (center.0 / norm, center.1 / norm, center.2 / norm)
        var weights = positions.map { position -> Double in
            let dot = max(-1, min(1,
                position.x * direction.0 + position.y * direction.1 + position.z * direction.2
            ))
            let angle = acos(dot)
            let z = angle / sigmaRadians
            return exp(-0.5 * z * z)
        }
        let peak = weights.max() ?? 0
        if peak > 0 {
            for index in weights.indices { weights[index] /= peak }
        }
        return weights
    }
}
