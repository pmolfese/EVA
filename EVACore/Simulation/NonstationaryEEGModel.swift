//
//  NonstationaryEEGModel.swift
//  EVA Simulate
//
//  Deterministic neural non-stationarity for ICA, microstate, and PAC method
//  validation. These are controlled phenomenological models, not claims that
//  one stochastic law describes every subject's ongoing EEG.
//

import Foundation

nonisolated struct AlphaBurstTruth: Codable, Sendable {
    var id: String
    var onsetSeconds: Double
    var durationSeconds: Double
    var peakAmplitudeMicrovolts: Double
}

nonisolated struct MicrostateEpisodeTruth: Codable, Sendable {
    var id: String
    var stateIndex: Int
    var onsetSeconds: Double
    var durationSeconds: Double
}

nonisolated struct PhaseAmplitudeCouplingTruth: Codable, Sendable {
    var phaseFrequencyHz: Double
    var phaseCarrierBandName: String
    var targetBandName: String
    var strength: Double
    var preferredPhaseRadians: Double
    var initialPhaseRadians: Double
    var phaseCarrierFraction: Double
    var preferredToOppositeGainRatio: Double
}

nonisolated struct NeuralNonstationarityTruth: Codable, Sendable {
    var alphaBursts: [AlphaBurstTruth]
    /// Multiplicative band-amplitude envelopes sampled at one value per second.
    var bandAmplitudeEnvelopes1Hz: [String: [Double]]
    var microstateEpisodes: [MicrostateEpisodeTruth]
    /// Zero-mean, unit-RMS sensor topographies; rows are states, columns channels.
    var microstateTopographies: [[Double]]
    var microstateCarrierSeed: UInt64?
    var microstateCarrierBandHz: [Double]?
    var requestedMicrostateAmplitudeMicrovolts: Double?
    var realizedMicrostateAmplitudeMicrovolts: Double?
    var phaseAmplitudeCoupling: PhaseAmplitudeCouplingTruth?
}

nonisolated struct NeuralNonstationarityPlan: Sendable {
    var samplingRate: Double
    var alphaEnvelope: [Double]
    var reportedAlphaEnvelope: [Double]
    var alphaBursts: [AlphaBurstTruth]
    var bandEnvelopes: [String: [Double]]
    var bandEnvelopes1Hz: [String: [Double]]
    var microstateEpisodes: [MicrostateEpisodeTruth]
    var microstateTopographies: [[Double]]
    var microstateCarrier: [Double]
    var microstateCarrierSeed: UInt64?
    var microstateCarrierBandHz: [Double]?
    var requestedMicrostateAmplitudeMicrovolts: Double?
    var microstateTransitionSeconds: Double
    var pacGain: [Double]
    var pacCarrier: [Double]
    var pacTruth: PhaseAmplitudeCouplingTruth?

    func applySpectralAndPAC(to component: inout [Double], band: EEGBand) {
        if let truth = pacTruth,
           band.lowHz <= truth.phaseFrequencyHz,
           truth.phaseFrequencyHz < band.highHz {
            if pacCarrier.count == component.count {
                for sample in component.indices {
                    component[sample] += truth.phaseCarrierFraction * pacCarrier[sample]
                }
            }
        }
        if pacTruth?.targetBandName == band.name, pacGain.count == component.count {
            for sample in component.indices { component[sample] *= pacGain[sample] }
        }
        if let envelope = bandEnvelopes[band.name], envelope.count == component.count {
            for sample in component.indices { component[sample] *= envelope[sample] }
        }
    }

    func addMicrostates(to channels: inout [[Double]], amplitudeMicrovolts: Double?) {
        guard let amplitude = amplitudeMicrovolts,
              amplitude > 0,
              !microstateEpisodes.isEmpty,
              !microstateTopographies.isEmpty,
              microstateCarrier.count == channels.first?.count else { return }

        let sampleCount = microstateCarrier.count
        let rate = samplingRate
        for (episodeIndex, episode) in microstateEpisodes.enumerated() {
            let start = max(0, Int((episode.onsetSeconds * rate).rounded()))
            let end = min(sampleCount, Int(((episode.onsetSeconds + episode.durationSeconds) * rate).rounded()))
            guard start < end, microstateTopographies.indices.contains(episode.stateIndex) else { continue }
            let previousState = episodeIndex > 0
                ? microstateEpisodes[episodeIndex - 1].stateIndex
                : episode.stateIndex
            let transitionSamples = min(
                end - start, max(0, Int((microstateTransitionSeconds * rate).rounded()))
            )
            for sample in start..<end {
                let currentWeight: Double
                if transitionSamples > 0, sample - start < transitionSamples {
                    let phase = Double(sample - start + 1) / Double(transitionSamples)
                    currentWeight = 0.5 - 0.5 * cos(Double.pi * phase)
                } else {
                    currentWeight = 1
                }
                let previousWeight = 1 - currentWeight
                let carrier = amplitude * microstateCarrier[sample]
                for channel in channels.indices where channel < microstateTopographies[episode.stateIndex].count {
                    let current = microstateTopographies[episode.stateIndex][channel]
                    let previous = microstateTopographies.indices.contains(previousState)
                        ? microstateTopographies[previousState][channel] : current
                    channels[channel][sample] += carrier
                        * (previousWeight * previous + currentWeight * current)
                }
            }
        }
    }

    func truth(calibrationFactor: Double) -> NeuralNonstationarityTruth {
        NeuralNonstationarityTruth(
            alphaBursts: alphaBursts,
            bandAmplitudeEnvelopes1Hz: bandEnvelopes1Hz,
            microstateEpisodes: microstateEpisodes,
            microstateTopographies: microstateTopographies,
            microstateCarrierSeed: microstateCarrierSeed,
            microstateCarrierBandHz: microstateCarrierBandHz,
            requestedMicrostateAmplitudeMicrovolts: requestedMicrostateAmplitudeMicrovolts,
            realizedMicrostateAmplitudeMicrovolts: requestedMicrostateAmplitudeMicrovolts.map {
                $0 * calibrationFactor
            },
            phaseAmplitudeCoupling: pacTruth
        )
    }
}

nonisolated enum NonstationaryEEGModel {
    static func makePlan(config: SimulationConfig, montage: Montage) -> NeuralNonstationarityPlan? {
        guard let model = config.neuralNonstationarity else { return nil }
        let traditionalAlpha = EEGGenerator.alphaEnvelope(config: config)
        let alpha = alphaPlan(config: config, model: model, traditional: traditionalAlpha)
        let spectra = spectralPlans(config: config, model: model)
        let microstates = microstatePlan(config: config, model: model, montage: montage)
        let pac = pacPlan(config: config, model: model)

        var realizedAlpha = alpha.envelope
        if let alphaBand = config.eegBands.first(where: \.isAlpha),
           let spectral = spectra.full[alphaBand.name], spectral.count == realizedAlpha.count {
            for sample in realizedAlpha.indices { realizedAlpha[sample] *= spectral[sample] }
        }

        return NeuralNonstationarityPlan(
            samplingRate: config.samplingRate,
            alphaEnvelope: alpha.envelope,
            reportedAlphaEnvelope: realizedAlpha,
            alphaBursts: alpha.truth,
            bandEnvelopes: spectra.full,
            bandEnvelopes1Hz: spectra.oneHz,
            microstateEpisodes: microstates.episodes,
            microstateTopographies: microstates.topographies,
            microstateCarrier: microstates.carrier,
            microstateCarrierSeed: microstates.seed,
            microstateCarrierBandHz: microstates.band,
            requestedMicrostateAmplitudeMicrovolts: model.microstates?.amplitudeMicrovolts,
            microstateTransitionSeconds: model.microstates?.transitionSeconds ?? 0,
            pacGain: pac.gain,
            pacCarrier: pac.carrier,
            pacTruth: pac.truth
        )
    }

    private static func alphaPlan(
        config: SimulationConfig,
        model: NeuralNonstationarityConfig,
        traditional: [Double]
    ) -> (envelope: [Double], truth: [AlphaBurstTruth]) {
        guard let bursts = model.alphaBursts else { return (traditional, []) }
        var source = GaussianSource(seed: SimulationSeedStreams.alphaBursts(base: config.seed))
        var eventTruth: [AlphaBurstTruth] = []
        var burstShape = [Double](repeating: 0, count: config.sampleCount)
        var onset = 0.25 + 0.75 * source.uniform()
        let meanInterval = 60 / bursts.burstsPerMinute
        while onset < config.durationSeconds {
            let duration = min(3.0, max(0.20,
                bursts.meanDurationSeconds + bursts.durationSDSeconds * source.gaussian()))
            let start = max(0, Int((onset * config.samplingRate).rounded()))
            let end = min(config.sampleCount, start + max(2, Int((duration * config.samplingRate).rounded())))
            if start < end {
                for sample in start..<end {
                    let phase = Double(sample - start) / Double(max(end - start - 1, 1))
                    burstShape[sample] = max(burstShape[sample], sin(Double.pi * phase).squared())
                }
                let midpoint = min(traditional.count - 1, max(0, (start + end) / 2))
                eventTruth.append(AlphaBurstTruth(
                    id: String(format: "alpha-%04d", eventTruth.count + 1),
                    onsetSeconds: Double(start) / config.samplingRate,
                    durationSeconds: Double(end - start) / config.samplingRate,
                    peakAmplitudeMicrovolts: traditional[midpoint]
                ))
            }
            // A moderate-CV lognormal renewal process produces irregular but
            // not implausibly clustered spindles. Its mean is exactly the
            // requested onset interval before the no-overlap floor is applied.
            let intervalLogSD = 0.45
            let interval = meanInterval
                * exp(intervalLogSD * source.gaussian() - 0.5 * intervalLogSD.squared())
            onset += max(duration + 0.10, interval)
        }
        let background = min(max(bursts.backgroundFraction, 0), 1)
        let envelope = traditional.indices.map {
            traditional[$0] * (background + (1 - background) * burstShape[$0])
        }
        return (envelope, eventTruth)
    }

    private static func spectralPlans(
        config: SimulationConfig,
        model: NeuralNonstationarityConfig
    ) -> (full: [String: [Double]], oneHz: [String: [Double]]) {
        guard let dynamics = model.spectralDynamics else { return ([:], [:]) }
        var full: [String: [Double]] = [:]
        var oneHz: [String: [Double]] = [:]
        for (bandIndex, band) in config.eegBands.enumerated() where full[band.name] == nil {
            var source = GaussianSource(seed: SimulationSeedStreams.spectralDynamics(
                base: config.seed, index: bandIndex
            ))
            let update = dynamics.updateIntervalSeconds
            let knotCount = max(2, Int(ceil(config.durationSeconds / update)) + 2)
            let rho = exp(-update / dynamics.timeConstantSeconds)
            let innovation = dynamics.logAmplitudeSD * sqrt(max(0, 1 - rho * rho))
            var state = dynamics.logAmplitudeSD * source.gaussian()
            var knots = [Double]()
            knots.reserveCapacity(knotCount)
            for _ in 0..<knotCount {
                knots.append(exp(state - 0.5 * dynamics.logAmplitudeSD.squared()))
                state = rho * state + innovation * source.gaussian()
            }
            let values = (0..<config.sampleCount).map { sample -> Double in
                let time = Double(sample) / config.samplingRate
                let position = time / update
                let lower = min(knots.count - 2, max(0, Int(floor(position))))
                let fraction = min(max(position - Double(lower), 0), 1)
                return knots[lower] + fraction * (knots[lower + 1] - knots[lower])
            }
            full[band.name] = values
            oneHz[band.name] = stride(from: 0, to: config.sampleCount, by: max(1, Int(config.samplingRate.rounded())))
                .map { values[$0] }
        }
        return (full, oneHz)
    }

    private static func microstatePlan(
        config: SimulationConfig,
        model: NeuralNonstationarityConfig,
        montage: Montage
    ) -> (episodes: [MicrostateEpisodeTruth], topographies: [[Double]], carrier: [Double], seed: UInt64?, band: [Double]?) {
        guard let microstates = model.microstates else { return ([], [], [], nil, nil) }
        var source = GaussianSource(seed: SimulationSeedStreams.microstates(base: config.seed))
        var episodes: [MicrostateEpisodeTruth] = []
        var onset = 0.0
        var state = Int(source.uniform() * Double(microstates.stateCount)) % microstates.stateCount
        while onset < config.durationSeconds {
            let logSD = 0.35
            let dwell = min(microstates.maximumDwellSeconds, max(microstates.minimumDwellSeconds,
                microstates.meanDwellSeconds * exp(logSD * source.gaussian() - 0.5 * logSD.squared())))
            let duration = min(dwell, config.durationSeconds - onset)
            episodes.append(MicrostateEpisodeTruth(
                id: String(format: "microstate-%05d", episodes.count + 1),
                stateIndex: state, onsetSeconds: onset, durationSeconds: duration
            ))
            onset += duration
            if microstates.stateCount > 1 {
                let offset = 1 + Int(source.uniform() * Double(microstates.stateCount - 1))
                state = (state + offset) % microstates.stateCount
            }
        }

        let topographies = (0..<microstates.stateCount).map { stateIndex in
            normalizedTopography(stateIndex: stateIndex, positions: montage.positions)
        }
        let seed = SimulationSeedStreams.microstateCarrier(base: config.seed)
        var carrierSource = GaussianSource(seed: seed)
        let carrier = SpectralNoise.bandLimited(
            sampleCount: config.sampleCount, samplingRate: config.samplingRate,
            lowHz: microstates.carrierLowHz, highHz: microstates.carrierHighHz,
            source: &carrierSource
        )
        return (episodes, topographies, carrier, seed,
                [microstates.carrierLowHz, microstates.carrierHighHz])
    }

    private static func normalizedTopography(
        stateIndex: Int,
        positions: [(x: Double, y: Double, z: Double)]
    ) -> [Double] {
        let index = Double(stateIndex + 1)
        let z = 1 - 2 * fractionalPart(index * 0.618_033_988_749_894_9)
        let azimuth = 2 * Double.pi * fractionalPart(index * 0.754_877_666_246_692_7)
        let radial = sqrt(max(0, 1 - z * z))
        let center = (x: radial * cos(azimuth), y: radial * sin(azimuth), z: z)
        var values = positions.map { position in
            let dot = position.x * center.x + position.y * center.y + position.z * center.z
            return dot + 0.30 * (2 * dot * dot - 1)
        }
        let mean = values.reduce(0, +) / Double(max(values.count, 1))
        for index in values.indices { values[index] -= mean }
        let rms = sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(max(values.count, 1)))
        if rms > 1e-12 { for index in values.indices { values[index] /= rms } }
        return values
    }

    private static func pacPlan(
        config: SimulationConfig,
        model: NeuralNonstationarityConfig
    ) -> (gain: [Double], carrier: [Double], truth: PhaseAmplitudeCouplingTruth?) {
        guard let pac = model.phaseAmplitudeCoupling else { return ([], [], nil) }
        var source = GaussianSource(seed: SimulationSeedStreams.phaseAmplitudeCoupling(base: config.seed))
        let initial = 2 * Double.pi * source.uniform()
        let normalization = sqrt(1 + 0.5 * pac.strength.squared())
        let gain = (0..<config.sampleCount).map { sample -> Double in
            let phase = initial + 2 * Double.pi * pac.phaseFrequencyHz
                * Double(sample) / config.samplingRate
            return (1 + pac.strength * cos(phase - pac.preferredPhaseRadians)) / normalization
        }
        let carrier = (0..<config.sampleCount).map { sample -> Double in
            let phase = initial + 2 * Double.pi * pac.phaseFrequencyHz
                * Double(sample) / config.samplingRate
            return sqrt(2) * sin(phase)
        }
        let phaseBand = config.eegBands.first {
            $0.lowHz <= pac.phaseFrequencyHz && pac.phaseFrequencyHz < $0.highHz
        }?.name ?? ""
        return (gain, carrier, PhaseAmplitudeCouplingTruth(
            phaseFrequencyHz: pac.phaseFrequencyHz,
            phaseCarrierBandName: phaseBand,
            targetBandName: pac.targetBandName,
            strength: pac.strength,
            preferredPhaseRadians: pac.preferredPhaseRadians,
            initialPhaseRadians: initial,
            phaseCarrierFraction: pac.phaseCarrierFraction,
            preferredToOppositeGainRatio: (1 + pac.strength) / (1 - pac.strength)
        ))
    }

    private static func fractionalPart(_ value: Double) -> Double { value - floor(value) }
}

private extension Double {
    nonisolated func squared() -> Double { self * self }
}
