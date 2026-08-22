//
//  ERPGenerator.swift
//  EVA Simulate
//
//  Trial-variable event-related potentials with explicit dipole topography and
//  complete per-trial truth. This layer is opt-in and uses independent named
//  random streams, so adding ERPs cannot change ongoing EEG/artifact realizations
//  and changing one ERP factor cannot consume another factor's draws.
//

import Foundation

nonisolated struct ERPTrialTruth: Codable, Sendable {
    var id: String
    var condition: String
    var eventCode: String
    var onsetSeconds: Double
    var peakLatencySeconds: Double
    var peakTimeSeconds: Double
    var peakAmplitudeMicrovolts: Double
    var omitted: Bool
    /// The simulated component is evaluated from onset through this time.
    /// Optional keeps truth sidecars from before overlap reporting readable.
    var componentWindowEndSeconds: Double? = nil
    var overlapsPreviousTrial: Bool? = nil
    var overlapsNextTrial: Bool? = nil
    var overlapsAnotherTrial: Bool? = nil
}

nonisolated struct ERPRandomSeedTruth: Codable, Sendable, Equatable {
    var latency: UInt64
    var amplitude: UInt64
    var conditionOrder: UInt64
    var onsetJitter: UInt64
    var omission: UInt64
}

nonisolated struct ERPInjection: Sendable {
    var trials: [ERPTrialTruth]
    /// Exact peaks of the generated condition averages at the strongest sensor.
    var components: [ERPComponent]
    var source: SimulatedSource
    var topography: [Double]
    var waveformDescription: String
    var realizedLatencyAmplitudeCorrelation: Double
    var randomSeeds: ERPRandomSeedTruth
}

nonisolated enum ERPGenerator {
    private struct MeasuredWaveform {
        var samples: [Double]
        var rate: Double
        var peakSeconds: Double
    }

    static func inject(
        into channels: inout [[Double]],
        config: SimulationConfig,
        montage: Montage
    ) throws -> ERPInjection? {
        guard let erp = config.erp, erp.trialCount > 0 else { return nil }
        let source = makeSource(config: config)
        let field = try SphericalForwardModel.leadField(
            head: config.sphericalHeadModel, montage: montage, sources: [source],
            reference: config.effectiveRecordingReference, terms: config.leadFieldTerms
        )
        var topography = field.matrixMicrovoltsPerNanoampereMeter.map { $0[0] }
        let topographicPeak = topography.map(abs).max() ?? 0
        if topographicPeak > 0 {
            for index in topography.indices { topography[index] /= topographicPeak }
        }

        let measured = try loadMeasuredWaveform(erp)
        let seeds = ERPRandomSeedTruth(
            latency: SimulationSeedStreams.erpLatency(base: config.seed),
            amplitude: SimulationSeedStreams.erpAmplitude(base: config.seed),
            conditionOrder: SimulationSeedStreams.erpConditionOrder(base: config.seed),
            onsetJitter: SimulationSeedStreams.erpOnsetJitter(base: config.seed),
            omission: SimulationSeedStreams.erpOmission(base: config.seed)
        )
        var latencyRandom = GaussianSource(seed: seeds.latency)
        var amplitudeRandom = GaussianSource(seed: seeds.amplitude)
        var conditionRandom = GaussianSource(seed: seeds.conditionOrder)
        var onsetRandom = GaussianSource(seed: seeds.onsetJitter)
        var omissionRandom = GaussianSource(seed: seeds.omission)
        let count = erp.trialCount
        let latencyDraws = (0..<count).map { _ in latencyRandom.gaussian() }
        let latencies = latencyDraws.map { draw in
            let skewed = draw + erp.latencySkew * (draw * draw - 1) / Double(2).squareRoot()
            return max(0.005, erp.peakLatencySeconds + erp.latencyJitterSDSeconds * skewed)
        }
        var amplitudeDraws = (0..<count).map { _ in amplitudeRandom.gaussian() }
        imposeCorrelation(
            master: latencies,
            slave: &amplitudeDraws,
            coefficient: erp.latencyAmplitudeCorrelation
        )

        let targetCount = Int((Double(count) * erp.targetFraction).rounded())
        var order = Array(0..<count)
        if count > 1 {
            for upper in stride(from: count - 1, through: 1, by: -1) {
                let other = min(upper, Int(floor(conditionRandom.uniform() * Double(upper + 1))))
                order.swapAt(upper, other)
            }
        }
        let targets = Set(order.prefix(targetCount))
        let onsets = (0..<count).map { index in
            erp.startSeconds
                + Double(index) * erp.interStimulusIntervalSeconds
                + (2 * onsetRandom.uniform() - 1) * erp.interStimulusJitterSeconds
        }
        let omissionDraws = (0..<count).map { _ in omissionRandom.uniform() }
        let epochSeconds = max(
            erp.peakLatencySeconds
                + 6 * erp.latencyJitterSDSeconds * (1 + abs(erp.latencySkew))
                + 6 * erp.widthSeconds,
            measured.map { erp.peakLatencySeconds - $0.peakSeconds
                + Double($0.samples.count - 1) / $0.rate } ?? 0
        )
        guard (onsets.min() ?? 0) >= 0,
              (onsets.max() ?? 0) + epochSeconds < config.durationSeconds else {
            throw SimulateError.usage(
                "ERP schedule plus component window does not fit inside the recording"
            )
        }
        let epochSamples = max(2, Int((epochSeconds * config.samplingRate).rounded(.up)) + 1)
        var averages = [
            "standard": [Double](repeating: 0, count: epochSamples),
            "target": [Double](repeating: 0, count: epochSamples)
        ]
        var conditionCounts = ["standard": 0, "target": 0]
        var trials: [ERPTrialTruth] = []
        trials.reserveCapacity(count)

        for index in 0..<count {
            let condition = targets.contains(index) ? "target" : "standard"
            let code = condition == "target" ? "targ" : "std"
            let onset = onsets[index]
            let latency = latencies[index]
            let baseAmplitude = erp.targetAmplitudeMicrovolts
                * (condition == "target" ? 1 : erp.standardAmplitudeRatio)
            let omitted = omissionDraws[index] < erp.omissionRate
            let amplitude = omitted ? 0
                : baseAmplitude * max(0, 1 + erp.amplitudeJitterFraction * amplitudeDraws[index])
            var waveform = trialWaveform(
                sampleCount: epochSamples, samplingRate: config.samplingRate,
                latency: latency, kind: erp.waveform, width: erp.widthSeconds,
                measured: measured
            )
            for sample in waveform.indices { waveform[sample] *= amplitude }
            conditionCounts[condition, default: 0] += 1
            for sample in waveform.indices {
                averages[condition]![sample] += waveform[sample]
            }

            let onsetSample = Int((onset * config.samplingRate).rounded())
            for channel in channels.indices {
                let gain = topography[channel]
                for sample in waveform.indices {
                    let destination = onsetSample + sample
                    guard destination >= 0, destination < channels[channel].count else { continue }
                    channels[channel][destination] += gain * waveform[sample]
                }
            }
            trials.append(ERPTrialTruth(
                id: String(format: "trial-%04d", index + 1),
                condition: condition,
                eventCode: code,
                onsetSeconds: onset,
                peakLatencySeconds: latency,
                peakTimeSeconds: onset + latency,
                peakAmplitudeMicrovolts: amplitude,
                omitted: omitted,
                componentWindowEndSeconds: onset + epochSeconds,
                overlapsPreviousTrial: index > 0
                    ? onset < onsets[index - 1] + epochSeconds : false,
                overlapsNextTrial: index + 1 < count
                    ? onsets[index + 1] < onset + epochSeconds : false,
                overlapsAnotherTrial: (index > 0
                    && onset < onsets[index - 1] + epochSeconds)
                    || (index + 1 < count && onsets[index + 1] < onset + epochSeconds)
            ))
        }

        let components = ["standard", "target"].compactMap { condition -> ERPComponent? in
            guard let total = conditionCounts[condition], total > 0,
                  var average = averages[condition] else { return nil }
            for sample in average.indices { average[sample] /= Double(total) }
            guard let peakIndex = average.indices.max(by: {
                abs(average[$0]) < abs(average[$1])
            }) else { return nil }
            return ERPComponent(
                id: condition,
                peakLatencySeconds: Double(peakIndex) / config.samplingRate,
                peakAmplitudeMicrovolts: average[peakIndex]
            )
        }
        let responded = trials.filter { !$0.omitted }
        let normalizedAmplitudes = responded.map { trial in
            let base = erp.targetAmplitudeMicrovolts
                * (trial.condition == "target" ? 1 : erp.standardAmplitudeRatio)
            return base != 0 ? trial.peakAmplitudeMicrovolts / base : 0
        }
        return ERPInjection(
            trials: trials,
            components: components,
            source: source,
            topography: topography,
            waveformDescription: measured == nil ? erp.waveform.rawValue
                : "measured template: \(erp.measuredTemplatePath ?? "")",
            realizedLatencyAmplitudeCorrelation: DipoleEEGGenerator.pearson(
                responded.map(\.peakLatencySeconds), normalizedAmplitudes
            ),
            randomSeeds: seeds
        )
    }

    private static func makeSource(config: SimulationConfig) -> SimulatedSource {
        var sourceConfig = config
        sourceConfig.dipoleSourceCount = 1
        var source = DipoleEEGGenerator.makeSources(config: sourceConfig)[0]
        source.id = "ERP001"
        source.bandName = "event-related potential"
        source.scenarioRole = "fixed ERP component topography"
        return source
    }

    private static func loadMeasuredWaveform(_ config: ERPConfig) throws -> MeasuredWaveform? {
        guard config.waveform == .measured else { return nil }
        guard let path = config.measuredTemplatePath,
              let rate = config.measuredTemplateRateHz, rate > 0 else {
            throw SimulateError.badTemplate("measured ERP waveform needs a path and positive rate")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var samples = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard samples.count >= 8 else {
            throw SimulateError.badTemplate("ERP template \(path) needs at least 8 numeric samples")
        }
        let peak = samples.indices.max { abs(samples[$0]) < abs(samples[$1]) } ?? 0
        let scale = abs(samples[peak])
        guard scale > 1e-15 else { throw SimulateError.badTemplate("ERP template is all zero") }
        for index in samples.indices { samples[index] /= scale }
        return MeasuredWaveform(
            samples: samples, rate: rate, peakSeconds: Double(peak) / rate
        )
    }

    private static func trialWaveform(
        sampleCount: Int, samplingRate: Double, latency: Double,
        kind: ERPWaveformKind, width: Double, measured: MeasuredWaveform?
    ) -> [Double] {
        var values = [Double](repeating: 0, count: sampleCount)
        for sample in values.indices {
            let time = Double(sample) / samplingRate
            switch kind {
            case .gaussian:
                values[sample] = exp(-0.5 * pow((time - latency) / width, 2))
            case .biphasic:
                let positive = exp(-0.5 * pow((time - latency) / width, 2))
                let negativeCenter = latency - 2 * width
                let negative = exp(-0.5 * pow((time - negativeCenter) / (0.8 * width), 2))
                values[sample] = positive - 0.5 * negative
            case .measured:
                guard let measured else { continue }
                let templateTime = time - latency + measured.peakSeconds
                let position = templateTime * measured.rate
                let lower = Int(floor(position))
                guard lower >= 0, lower < measured.samples.count else { continue }
                if lower + 1 < measured.samples.count {
                    let fraction = position - Double(lower)
                    values[sample] = measured.samples[lower] * (1 - fraction)
                        + measured.samples[lower + 1] * fraction
                } else {
                    values[sample] = measured.samples[lower]
                }
            }
        }
        let peak = values.map(abs).max() ?? 0
        if peak > 0 { for index in values.indices { values[index] /= peak } }
        return values
    }

    private static func imposeCorrelation(
        master: [Double], slave: inout [Double], coefficient: Double
    ) {
        let count = min(master.count, slave.count)
        guard count > 1, abs(coefficient) > 0 else { return }
        let xMean = master.prefix(count).reduce(0, +) / Double(count)
        let yMean = slave.prefix(count).reduce(0, +) / Double(count)
        var x = master.prefix(count).map { $0 - xMean }
        var residual = slave.prefix(count).map { $0 - yMean }
        let xRMS = (x.reduce(0) { $0 + $1 * $1 } / Double(count)).squareRoot()
        guard xRMS > 1e-15 else { return }
        for index in x.indices { x[index] /= xRMS }
        let projection = zip(x, residual).reduce(0.0) { $0 + $1.0 * $1.1 } / Double(count)
        for index in residual.indices { residual[index] -= projection * x[index] }
        let residualRMS = (residual.reduce(0) { $0 + $1 * $1 } / Double(count)).squareRoot()
        guard residualRMS > 1e-15 else { return }
        let independent = max(0, 1 - coefficient * coefficient).squareRoot()
        for index in 0..<count {
            slave[index] = coefficient * x[index] + independent * residual[index] / residualRMS
        }
    }
}
