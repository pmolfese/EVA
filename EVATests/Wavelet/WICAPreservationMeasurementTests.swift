//
//  WICAPreservationMeasurementTests.swift
//  EVATests
//
//  CALIBRATION, not a regression test. This exercises the complete candidate
//  path (seeded dipole EEG -> EVA ICA -> ICLabel -> component wavelets ->
//  back-projection) and stays behind EVA_CALIBRATION=1 until the method earns a
//  user-facing place in the Artifacts menu.
//

import Foundation
import Testing
@testable import EVA

struct WICAPreservationMeasurementTests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_CALIBRATION"] == "1"
    }

    @Test func seededBrainTransientsAndBlinks() async throws {
        guard Self.isEnabled else {
            print("WICAPreservationMeasurementTests: set EVA_CALIBRATION=1 to run. Skipping.")
            return
        }

        let rate = 250.0
        var config = SimulationConfig.default
        config.eegGenerationModel = .dipole
        config.nonGaussianSources = .default
        config.recordingReference = .average
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.channelCount = 20
        config.samplingRate = rate
        config.durationSeconds = 45
        config.brainTransients = BrainTransientConfig(ratePerMinute: 24, amplitudeMicrovolts: 150)
        config.blinksPerMinute = 16

        let montage = Montage.standard(count: config.channelCount)
        var eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
        var transientSource = GaussianSource(seed: config.seed &+ 0x5851_F42D_4C95_7F2D)
        let transientTruth = try #require(BrainTransientModel.inject(
            into: &eeg.channels, config: config, montage: montage, source: &transientSource
        ))
        let clean = eeg.channels

        var noisy = clean
        var ocularSource = GaussianSource(seed: SimulationSeedStreams.ocular(base: config.seed))
        let ocularTruth = OcularArtifactModel.inject(
            into: &noisy, config: config, montage: montage, source: &ocularSource
        )
        let signal = SyntheticSignal.make(noisy.map { $0.map(Float.init) }, samplingRate: rate)
        let decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: ICAConfiguration(
                method: .picardO,
                componentCount: config.channelCount,
                varianceThreshold: 0.99999,
                averageReference: true,
                downsampleRate: 125,
                maxIterations: 300,
                learningRate: nil,
                fitFilter: nil,
                convergenceTolerance: 1e-7,
                minimumIterations: 1
            )
        )
        let layout = Self.layout(for: montage)
        let suggestions = ICAComponentAutoLabeler.suggestions(for: decomposition, layout: layout)
        let artifactPrefixes = ["Eye", "Muscle", "Heart", "Line Noise", "Channel Noise"]
        let selected = suggestions.compactMap { component, suggestion in
            artifactPrefixes.contains(where: { suggestion.label.hasPrefix($0) }) ? component : nil
        }.sorted()

        var wavelet = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: rate)
        wavelet.thresholdScale = 1
        wavelet.useGPU = false
        let wicaConfig = WICAConfiguration(wavelet: wavelet, coreCount: 4, componentBatchSize: 8)
        let channels = Array(0..<config.channelCount)
        let channelResult = WaveletReducer.reduce(
            signal: signal, channelIndices: channels, configuration: wavelet
        )
        let allResult = try WICAProcessor.reduce(
            signal: signal,
            decomposition: decomposition,
            componentIndices: Set(0..<decomposition.componentCount),
            configuration: wicaConfig
        )
        let selectiveResult = selected.isEmpty ? nil : try WICAProcessor.reduce(
            signal: signal,
            decomposition: decomposition,
            componentIndices: Set(selected),
            configuration: wicaConfig
        )

        let blinkChannel = ocularTruth.blinkTopography.enumerated()
            .max { abs($0.element) < abs($1.element) }?.offset ?? 0
        let rows: [(String, [[Float]])] = [
            ("channel wavelet", channelResult.cleaned.data),
            ("all-component W-ICA", allResult.cleaned.data)
        ] + (selectiveResult.map { [("ICLabel-selective W-ICA", $0.cleaned.data)] } ?? [])

        var lines = ["=== W-ICA: seeded dipole EEG, brain transients, and blinks ==="]
        lines.append("components: \(decomposition.componentCount); ICLabel artifact selection: \(selected)")
        let contributionTotal = decomposition.explainedVariance.reduce(0, +)
        for component in 0..<decomposition.componentCount {
            let suggestion = suggestions[component]
            let contribution = decomposition.explainedVariance.indices.contains(component)
                ? decomposition.explainedVariance[component] : 0
            lines.append(String(
                format: "  IC%02d  %6.2f%%  %@",
                component + 1,
                contributionTotal > 0 ? 100 * contribution / contributionTotal : 0,
                suggestion?.label ?? "unlabeled"
            ))
        }
        for (name, corrected) in rows {
            let preservation = Self.preservation(
                corrected, clean: clean, truth: transientTruth, rate: rate
            )
            let removal = Self.blinkRemoval(
                corrected, clean: clean, noisy: noisy, truth: ocularTruth,
                channel: blinkChannel, rate: rate
            )
            lines.append(String(
                format: "%@: preserve K/spindle/sharp %.3f/%.3f/%.3f; blink removal %.3f",
                name,
                preservation["kComplex"] ?? 1,
                preservation["spindle"] ?? 1,
                preservation["sharpWave"] ?? 1,
                removal
            ))
        }
        for line in lines { print(line) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-wica-preservation.txt")
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: output, atomically: true, encoding: .utf8)
    }

    private static func layout(for montage: Montage) -> SensorLayout {
        let radius = montage.positions.map { hypot($0.x, $0.y) }.max() ?? 1
        let scale = radius > 0 ? radius : 1
        return SensorLayout(
            name: montage.name,
            positions: montage.positions.enumerated().map { index, position in
                SensorPosition(channelIndex: index, x: position.x / scale, y: position.y / scale)
            }
        )
    }

    private static func variance(_ values: ArraySlice<Double>) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    private static func preservation(
        _ corrected: [[Float]],
        clean: [[Double]],
        truth: BrainTransientInjection,
        rate: Double
    ) -> [String: Double] {
        var scores: [String: [Double]] = [:]
        for episode in truth.episodes {
            let channel = episode.strongestChannel
            let start = Int((episode.onsetSeconds * rate).rounded())
            let end = min(clean[channel].count, start + Int((episode.durationSeconds * rate).rounded()))
            guard start >= 0, end > start else { continue }
            let reference = clean[channel][start..<end]
            let residual = zip(reference, corrected[channel][start..<end]).map {
                $0 - Double($1)
            }[...]
            let referenceVariance = variance(reference)
            scores[episode.type, default: []].append(
                referenceVariance > 1e-12 ? 1 - variance(residual) / referenceVariance : 1
            )
        }
        return scores.mapValues { $0.reduce(0, +) / Double(max(1, $0.count)) }
    }

    private static func blinkRemoval(
        _ corrected: [[Float]],
        clean: [[Double]],
        noisy: [[Double]],
        truth: OcularInjection,
        channel: Int,
        rate: Double
    ) -> Double {
        let scores = truth.blinkSeconds.compactMap { onset -> Double? in
            let start = max(0, Int(((onset - 0.1) * rate).rounded()))
            let end = min(clean[channel].count, start + Int((0.6 * rate).rounded()))
            guard end > start else { return nil }
            let artifact = zip(noisy[channel][start..<end], clean[channel][start..<end])
                .map { $0 - $1 }[...]
            let residual = zip(corrected[channel][start..<end], clean[channel][start..<end])
                .map { Double($0) - $1 }[...]
            let artifactVariance = variance(artifact)
            return artifactVariance > 1e-12
                ? 1 - variance(residual) / artifactVariance
                : nil
        }
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }
}
