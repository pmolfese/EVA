//
//  AdditionalArtifactModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The non-MR artifact families from roadmap item 2.1: stereotyped orofacial
//  activity, cable motion, sweat drift, electrode bridging, bad-reference
//  contamination, and amplifier clipping. Additive physiology is injected
//  first; bridge and clipping operations are applied at the end of the recording
//  chain because they act on the already-combined electrode voltage.
//

import Foundation

nonisolated struct ArtifactEpisodeTruth: Codable, Sendable {
    var id: String
    var kind: String
    var onsetSeconds: Double
    var durationSeconds: Double
    var amplitudeMicrovolts: Double
    /// 1-based channels central to or directly affected by the episode.
    var affectedChannels: [Int]
    /// Present for spatially varying events such as cable movement.
    var topography: [Double]? = nil
}

nonisolated struct AdditionalArtifactInjection: Sendable {
    var chewingEpisodes: [ArtifactEpisodeTruth] = []
    var swallowingEpisodes: [ArtifactEpisodeTruth] = []
    var cableMovementEpisodes: [ArtifactEpisodeTruth] = []
    var sweatEpisodes: [ArtifactEpisodeTruth] = []
    var chewingTopography: [Double] = []
    var swallowingTopography: [Double] = []
    var badReferenceRMSMicrovolts: Double? = nil
    var bridgedChannelPairs: [ChannelBridge] = []
    var clippedSampleCounts: [Int] = []
}

nonisolated enum AdditionalArtifactModel {

    static func injectAdditive(
        into channels: inout [[Double]],
        config: SimulationConfig,
        montage: Montage,
        includeBadReference: Bool = true
    ) -> AdditionalArtifactInjection {
        var truth = AdditionalArtifactInjection()
        let muscleTopographies = EMGArtifactModel.topographies(montage: montage)

        if let model = config.chewing {
            var source = GaussianSource(seed: SimulationSeedStreams.chewing(base: config.seed))
            truth.chewingTopography = zip(
                muscleTopographies.left, muscleTopographies.right
            ).map { max($0.0, $0.1) }
            truth.chewingEpisodes = injectChewing(
                into: &channels, config: config, model: model,
                weights: truth.chewingTopography, source: &source
            )
        }
        if let model = config.swallowing {
            var source = GaussianSource(seed: SimulationSeedStreams.swallowing(base: config.seed))
            truth.swallowingTopography = muscleTopographies.neck
            truth.swallowingEpisodes = injectSwallowing(
                into: &channels, config: config, model: model,
                weights: truth.swallowingTopography, source: &source
            )
        }
        if let model = config.cableMovement {
            var source = GaussianSource(seed: SimulationSeedStreams.cableMovement(base: config.seed))
            truth.cableMovementEpisodes = injectCableMovement(
                into: &channels, config: config, model: model,
                montage: montage, source: &source
            )
        }
        if let model = config.sweat {
            var source = GaussianSource(seed: SimulationSeedStreams.sweat(base: config.seed))
            truth.sweatEpisodes = injectSweat(
                into: &channels, config: config, model: model, source: &source
            )
        }
        if includeBadReference {
            truth.badReferenceRMSMicrovolts = injectBadReference(
                into: &channels, config: config
            )
        }
        return truth
    }

    /// A faulty physical reference is a recording defect, so the main pipeline
    /// applies it after the nominal recording reference. Keeping this helper
    /// public to the module also preserves isolated model tests.
    static func injectBadReference(
        into channels: inout [[Double]], config: SimulationConfig
    ) -> Double? {
        guard let model = config.badReference else { return nil }
        var source = GaussianSource(seed: SimulationSeedStreams.badReference(base: config.seed))
        let reference = SpectralNoise.bandLimited(
            sampleCount: config.sampleCount, samplingRate: config.samplingRate,
            lowHz: model.lowHz, highHz: model.highHz, source: &source
        ).map { $0 * model.amplitudeMicrovolts }
        for channel in channels.indices {
            for index in channels[channel].indices { channels[channel][index] += reference[index] }
        }
        return standardDeviation(reference)
    }

    static func applyBridging(
        to channels: inout [[Double]], pairs: [ChannelBridge]
    ) -> [ChannelBridge] {
        for pair in pairs {
            let first = pair.firstChannel - 1
            let second = pair.secondChannel - 1
            guard channels.indices.contains(first), channels.indices.contains(second) else { continue }
            let count = min(channels[first].count, channels[second].count)
            for index in 0..<count {
                let shared = 0.5 * (channels[first][index] + channels[second][index])
                channels[first][index] = shared
                channels[second][index] = shared
            }
        }
        return pairs
    }

    static func applyClipping(
        to channels: inout [[Double]], thresholdMicrovolts: Double
    ) -> [Int] {
        channels.indices.map { channel -> Int in
            var clipped = 0
            for index in channels[channel].indices {
                let value = channels[channel][index]
                if value > thresholdMicrovolts {
                    channels[channel][index] = thresholdMicrovolts
                    clipped += 1
                } else if value < -thresholdMicrovolts {
                    channels[channel][index] = -thresholdMicrovolts
                    clipped += 1
                }
            }
            return clipped
        }
    }

    private static func injectChewing(
        into channels: inout [[Double]], config: SimulationConfig,
        model: ChewingConfig, weights: [Double], source: inout GaussianSource
    ) -> [ArtifactEpisodeTruth] {
        let schedule = episodes(
            ratePerMinute: model.episodesPerMinute, meanDuration: model.durationSeconds,
            recordingDuration: config.durationSeconds, source: &source
        )
        let carrier = SpectralNoise.bandLimited(
            sampleCount: config.sampleCount, samplingRate: config.samplingRate,
            lowHz: model.lowHz, highHz: model.highHz, source: &source
        )
        var truth: [ArtifactEpisodeTruth] = []
        for (episodeIndex, episode) in schedule.enumerated() {
            let amplitude = model.amplitudeMicrovolts * max(0.3, 1 + 0.2 * source.gaussian())
            injectWindow(
                into: &channels, onset: episode.onset, duration: episode.duration,
                samplingRate: config.samplingRate, weights: weights
            ) { sample, phase in
                let localTime = phase * episode.duration
                let chew = 0.2 + 0.8 * pow(sin(Double.pi * model.cycleHz * localTime), 2)
                return amplitude * EMGArtifactModel.burstEnvelope(phase) * chew * carrier[sample]
            }
            truth.append(ArtifactEpisodeTruth(
                id: String(format: "chew-%04d", episodeIndex + 1), kind: "chewing",
                onsetSeconds: episode.onset, durationSeconds: episode.duration,
                amplitudeMicrovolts: amplitude, affectedChannels: strongestChannels(weights, count: 2)
            ))
        }
        return truth
    }

    private static func injectSwallowing(
        into channels: inout [[Double]], config: SimulationConfig,
        model: SwallowingConfig, weights: [Double], source: inout GaussianSource
    ) -> [ArtifactEpisodeTruth] {
        let schedule = episodes(
            ratePerMinute: model.eventsPerMinute, meanDuration: model.durationSeconds,
            recordingDuration: config.durationSeconds, source: &source
        )
        let carrier = SpectralNoise.bandLimited(
            sampleCount: config.sampleCount, samplingRate: config.samplingRate,
            lowHz: model.lowHz, highHz: model.highHz, source: &source
        )
        var truth: [ArtifactEpisodeTruth] = []
        for (episodeIndex, episode) in schedule.enumerated() {
            let amplitude = model.amplitudeMicrovolts * max(0.3, 1 + 0.2 * source.gaussian())
            injectWindow(
                into: &channels, onset: episode.onset, duration: episode.duration,
                samplingRate: config.samplingRate, weights: weights
            ) { sample, phase in
                let first = exp(-0.5 * pow((phase - 0.32) / 0.14, 2))
                let second = 0.8 * exp(-0.5 * pow((phase - 0.68) / 0.12, 2))
                return amplitude * (first + second) * carrier[sample]
            }
            truth.append(ArtifactEpisodeTruth(
                id: String(format: "swallow-%04d", episodeIndex + 1), kind: "swallowing",
                onsetSeconds: episode.onset, durationSeconds: episode.duration,
                amplitudeMicrovolts: amplitude, affectedChannels: strongestChannels(weights, count: 3)
            ))
        }
        return truth
    }

    private static func injectCableMovement(
        into channels: inout [[Double]], config: SimulationConfig,
        model: CableMovementConfig, montage: Montage, source: inout GaussianSource
    ) -> [ArtifactEpisodeTruth] {
        let schedule = episodes(
            ratePerMinute: model.eventsPerMinute, meanDuration: model.durationSeconds,
            recordingDuration: config.durationSeconds, source: &source
        )
        var truth: [ArtifactEpisodeTruth] = []
        for (episodeIndex, episode) in schedule.enumerated() {
            let center = min(max(0, Int(source.uniform() * Double(montage.positions.count))),
                             max(0, montage.positions.count - 1))
            let weights = broadTopography(positions: montage.positions, centerIndex: center)
            let amplitude = model.amplitudeMicrovolts * max(0.3, 1 + 0.25 * source.gaussian())
            let phaseOffset = 2 * Double.pi * source.uniform()
            injectWindow(
                into: &channels, onset: episode.onset, duration: episode.duration,
                samplingRate: config.samplingRate, weights: weights
            ) { _, phase in
                let time = phase * episode.duration
                return amplitude * EMGArtifactModel.burstEnvelope(phase)
                    * sin(2 * Double.pi * model.oscillationHz * time + phaseOffset)
            }
            truth.append(ArtifactEpisodeTruth(
                id: String(format: "move-%04d", episodeIndex + 1), kind: "cable-movement",
                onsetSeconds: episode.onset, durationSeconds: episode.duration,
                amplitudeMicrovolts: amplitude, affectedChannels: [center + 1], topography: weights
            ))
        }
        return truth
    }

    private static func injectSweat(
        into channels: inout [[Double]], config: SimulationConfig,
        model: SweatConfig, source: inout GaussianSource
    ) -> [ArtifactEpisodeTruth] {
        let schedule = episodes(
            ratePerMinute: model.episodesPerMinute, meanDuration: model.durationSeconds,
            recordingDuration: config.durationSeconds, source: &source
        )
        var truth: [ArtifactEpisodeTruth] = []
        for (episodeIndex, episode) in schedule.enumerated() {
            var available = Array(channels.indices)
            var selected: [Int] = []
            for _ in 0..<min(model.affectedChannelCount, available.count) {
                let draw = min(available.count - 1, Int(source.uniform() * Double(available.count)))
                selected.append(available.remove(at: draw))
            }
            let amplitude = model.amplitudeMicrovolts * max(0.3, 1 + 0.2 * source.gaussian())
            let sign = source.uniform() < 0.5 ? -1.0 : 1.0
            for channel in selected {
                injectWindow(
                    into: &channels, onset: episode.onset, duration: episode.duration,
                    samplingRate: config.samplingRate,
                    weights: channels.indices.map { $0 == channel ? 1.0 : 0.0 }
                ) { _, phase in sign * amplitude * pow(sin(Double.pi * phase), 2) }
            }
            truth.append(ArtifactEpisodeTruth(
                id: String(format: "sweat-%04d", episodeIndex + 1), kind: "sweat",
                onsetSeconds: episode.onset, durationSeconds: episode.duration,
                amplitudeMicrovolts: sign * amplitude,
                affectedChannels: selected.map { $0 + 1 }.sorted()
            ))
        }
        return truth
    }

    private static func episodes(
        ratePerMinute: Double, meanDuration: Double, recordingDuration: Double,
        source: inout GaussianSource
    ) -> [(onset: Double, duration: Double)] {
        guard ratePerMinute > 0 else { return [] }
        let meanInterval = 60 / ratePerMinute
        var onset = 0.5 + min(2, meanInterval) * source.uniform()
        var result: [(Double, Double)] = []
        while onset < recordingDuration {
            let requested = meanDuration * (0.75 + 0.5 * source.uniform())
            let duration = min(requested, recordingDuration - onset)
            guard duration >= 0.05 else { break }
            result.append((onset, duration))
            let interval = -meanInterval * log(max(1e-12, source.uniform()))
            onset += max(duration + 0.25, interval)
        }
        return result
    }

    private static func injectWindow(
        into channels: inout [[Double]], onset: Double, duration: Double,
        samplingRate: Double, weights: [Double],
        value: (_ sample: Int, _ phase: Double) -> Double
    ) {
        let start = max(0, Int((onset * samplingRate).rounded()))
        let length = max(2, Int((duration * samplingRate).rounded()))
        let end = min(channels.first?.count ?? 0, start + length)
        guard start < end else { return }
        for sample in start..<end {
            let phase = Double(sample - start) / Double(max(1, end - start - 1))
            let sampleValue = value(sample, phase)
            for channel in channels.indices where channel < weights.count {
                channels[channel][sample] += weights[channel] * sampleValue
            }
        }
    }

    private static func broadTopography(
        positions: [(x: Double, y: Double, z: Double)], centerIndex: Int
    ) -> [Double] {
        guard positions.indices.contains(centerIndex) else { return [] }
        let center = positions[centerIndex]
        var weights = positions.map { position -> Double in
            let dot = max(-1, min(1,
                position.x * center.x + position.y * center.y + position.z * center.z
            ))
            let angle = acos(dot)
            return 0.25 + 0.75 * exp(-0.5 * pow(angle / 1.0, 2))
        }
        let peak = weights.max() ?? 0
        if peak > 0 { for index in weights.indices { weights[index] /= peak } }
        return weights
    }

    private static func strongestChannels(_ weights: [Double], count: Int) -> [Int] {
        weights.indices.sorted { weights[$0] > weights[$1] }.prefix(count).map { $0 + 1 }
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(values.count)).squareRoot()
    }
}
