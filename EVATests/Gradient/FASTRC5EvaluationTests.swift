//
//  FASTRC5EvaluationTests.swift
//  EVATests
//
//  Measurement harness for ROADMAP MRI-1 C5. Gated so the ordinary suite
//  remains fast. Run with TEST_RUNNER_EVA_FASTR_C5_EVALUATION=1.
//

import Foundation
import Testing
@testable import EVA

struct FASTRC5EvaluationTests {

    private struct Recording {
        let clean: [[Double]]
        let cleanFloat: [[Float]]
        let noisy: [[Float]]
        let triggers: [Int]
        let rate: Double
    }

    private struct Metrics {
        let truth50: Double
        let truth90: Double
        let correlation50: Double
        let beta50: Double
        let seconds: Double
        let correctedFraction: Double
        let obsComponentsMax: Int
        let ancChannelCount: Int
        let correlationFallbacks: Int
    }

    private struct EvaluationCase {
        let label: String
        let config: GradientCorrectionConfig
    }

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["EVA_FASTR_C5_EVALUATION"] == "1"
    }

    private var selectedCases: Set<String>? {
        guard let raw = ProcessInfo.processInfo.environment["EVA_FASTR_C5_CASES"],
              !raw.isEmpty
        else { return nil }
        return Set(raw.split(separator: ";").map(String.init))
    }

    private func recording() throws -> Recording {
        var config = SimulationConfig.default
        config.seed = 0xC5_FA57_2026
        config.eegGenerationModel = .dipole
        config.recordingReference = .average
        config.bcgEnabled = false
        config.channelCount = 8
        config.samplingRate = 500
        config.durationSeconds = 60

        let montage = Montage.standard(count: config.channelCount)
        let eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
        var noisy = eeg.channels
        let injection = GradientArtifactModel.inject(
            into: &noisy,
            config: config,
            montage: montage,
            template: nil
        )
        return Recording(
            clean: eeg.channels,
            cleanFloat: eeg.channels.map { $0.map(Float.init) },
            noisy: noisy.map { $0.map(Float.init) },
            triggers: injection.quantizedVolumeOnsetsSeconds.map {
                Int(($0 * config.samplingRate).rounded())
            },
            rate: config.samplingRate
        )
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func correlationAndBeta(
        clean: [Double],
        output: [Float],
        range: Range<Int>
    ) -> (correlation: Double, beta: Double) {
        var cleanMean = 0.0
        var outputMean = 0.0
        for index in range {
            cleanMean += clean[index]
            outputMean += Double(output[index])
        }
        cleanMean /= Double(range.count)
        outputMean /= Double(range.count)

        var cross = 0.0
        var cleanEnergy = 0.0
        var outputEnergy = 0.0
        for index in range {
            let x = clean[index] - cleanMean
            let y = Double(output[index]) - outputMean
            cross += x * y
            cleanEnergy += x * x
            outputEnergy += y * y
        }
        return (
            cleanEnergy > 0 && outputEnergy > 0
                ? cross / (cleanEnergy * outputEnergy).squareRoot()
                : 0,
            cleanEnergy > 0 ? cross / cleanEnergy : 0
        )
    }

    private func evaluate(
        _ input: [[Float]],
        recording: Recording,
        config: GradientCorrectionConfig
    ) throws -> Metrics {
        let start = ContinuousClock.now
        let result = try GradientTemplateCorrector.correct(
            channels: input,
            volumeTriggers: recording.triggers,
            config: config,
            samplingRate: recording.rate
        )
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        let first = recording.triggers.first ?? 0
        let tr = recording.triggers.count > 1
            ? recording.triggers[1] - recording.triggers[0]
            : Int(3 * recording.rate)
        let last = min(
            result.channels[0].count,
            (recording.triggers.last ?? first) + tr
        )
        let range = first..<last

        var truths: [Double] = []
        var correlations: [Double] = []
        var betas: [Double] = []
        for channel in result.channels.indices {
            var cleanMean = 0.0
            for index in range { cleanMean += recording.clean[channel][index] }
            cleanMean /= Double(range.count)

            var errorEnergy = 0.0
            var cleanEnergy = 0.0
            for index in range {
                let error = Double(result.channels[channel][index])
                    - recording.clean[channel][index]
                errorEnergy += error * error
                let centered = recording.clean[channel][index] - cleanMean
                cleanEnergy += centered * centered
            }
            truths.append(cleanEnergy > 0 ? errorEnergy / cleanEnergy : 0)
            let signal = correlationAndBeta(
                clean: recording.clean[channel],
                output: result.channels[channel],
                range: range
            )
            correlations.append(signal.correlation)
            betas.append(signal.beta)
        }
        truths.sort()
        correlations.sort()
        betas.sort()

        let fallbacks = result.diagnostics.warnings.reduce(into: 0) { count, warning in
            if case .correlationDonorsFellBack = warning { count += 1 }
        }
        return Metrics(
            truth50: percentile(truths, 0.5),
            truth90: percentile(truths, 0.9),
            correlation50: percentile(correlations, 0.5),
            beta50: percentile(betas, 0.5),
            seconds: seconds,
            correctedFraction: result.diagnostics.epochCount > 0
                ? Double(result.diagnostics.correctedEpochCount)
                    / Double(result.diagnostics.epochCount)
                : 0,
            obsComponentsMax: result.diagnostics.obsComponentCounts.max() ?? 0,
            ancChannelCount: result.diagnostics.ancAppliedChannels.count,
            correlationFallbacks: fallbacks
        )
    }

    private func configuration(
        slices: Int,
        upsample: Int,
        scheme: GradientTemplateScheme = .temporalNeighbors,
        scaling: GradientTemplateScaling = .driftTracking,
        alignment: Bool = true,
        subSample: Bool = true,
        obs: GradientOBSMode = .off,
        anc: Bool = false,
        permissiveCorrelation: Bool = false
    ) -> GradientCorrectionConfig {
        var config = GradientCorrectionConfig()
        config.numberOfSlices = slices
        config.upsampleFactor = upsample
        config.averagingWindowBefore = 4
        config.averagingWindowAfter = 4
        config.templateScheme = scheme
        config.templateScaling = scaling
        config.alignmentEnabled = alignment
        config.subSampleAlignment = alignment && subSample
        config.obs = obs
        config.anc = anc
        config.computeBackend = .cpu
        if permissiveCorrelation {
            config.correlationThreshold = -1
            config.minimumCorrelatedDonors = 1
        }
        return config
    }

    private func cases() -> [EvaluationCase] {
        func item(_ label: String, _ config: GradientCorrectionConfig) -> EvaluationCase {
            EvaluationCase(label: label, config: config)
        }
        return [
            item("volume base", configuration(slices: 1, upsample: 1)),
            item("volume up5", configuration(slices: 1, upsample: 5)),
            item("volume unscaled", configuration(
                slices: 1, upsample: 1, scaling: .unscaled
            )),
            item("volume least-squares", configuration(
                slices: 1, upsample: 1, scaling: .leastSquares
            )),
            item("volume no-alignment", configuration(
                slices: 1, upsample: 1, alignment: false
            )),
            item("volume integer-only", configuration(
                slices: 1, upsample: 1, subSample: false
            )),
            item("volume OBS", configuration(
                slices: 1, upsample: 1, obs: .automatic
            )),
            item("volume ANC", configuration(
                slices: 1, upsample: 1, anc: true
            )),

            item("slice temporal base", configuration(slices: 41, upsample: 5)),
            item("slice temporal up1", configuration(slices: 41, upsample: 1)),
            item("slice temporal unscaled", configuration(
                slices: 41, upsample: 5, scaling: .unscaled
            )),
            item("slice temporal least-squares", configuration(
                slices: 41, upsample: 5, scaling: .leastSquares
            )),
            item("slice temporal no-alignment", configuration(
                slices: 41, upsample: 5, alignment: false
            )),
            item("slice temporal integer-only", configuration(
                slices: 41, upsample: 5, subSample: false
            )),
            item("slice temporal OBS", configuration(
                slices: 41, upsample: 5, obs: .automatic
            )),
            item("slice temporal ANC", configuration(
                slices: 41, upsample: 5, anc: true
            )),

            item("slice correlation default", configuration(
                slices: 41, upsample: 5, scheme: .correlationRanked
            )),
            item("slice correlation permissive", configuration(
                slices: 41,
                upsample: 5,
                scheme: .correlationRanked,
                permissiveCorrelation: true
            )),
            item("slice correlation unscaled", configuration(
                slices: 41,
                upsample: 5,
                scheme: .correlationRanked,
                scaling: .unscaled,
                permissiveCorrelation: true
            )),
            item("slice correlation OBS", configuration(
                slices: 41,
                upsample: 5,
                scheme: .correlationRanked,
                obs: .automatic,
                permissiveCorrelation: true
            )),
            item("slice correlation ANC", configuration(
                slices: 41,
                upsample: 5,
                scheme: .correlationRanked,
                anc: true,
                permissiveCorrelation: true
            )),
        ]
    }

    private func csv(_ label: String, _ clean: Metrics, _ artifact: Metrics) -> String {
        [
            label,
            String(format: "%.6f", clean.truth50),
            String(format: "%.6f", clean.truth90),
            String(format: "%.6f", clean.correlation50),
            String(format: "%.6f", clean.beta50),
            String(format: "%.6f", artifact.truth50),
            String(format: "%.6f", artifact.truth90),
            String(format: "%.6f", artifact.correlation50),
            String(format: "%.6f", artifact.beta50),
            String(format: "%.3f", clean.seconds),
            String(format: "%.3f", artifact.seconds),
            String(format: "%.4f", artifact.correctedFraction),
            String(artifact.obsComponentsMax),
            String(artifact.ancChannelCount),
            String(artifact.correlationFallbacks),
        ].joined(separator: ",")
    }

    @Test func c5Ablation() throws {
        guard enabled else {
            print("FASTRC5EvaluationTests: set EVA_FASTR_C5_EVALUATION=1 to run. Skipping.")
            return
        }

        let data = try recording()
        var lines = [
            "case,clean_truth50,clean_truth90,clean_r50,clean_beta50,artifact_truth50,artifact_truth90,artifact_r50,artifact_beta50,clean_seconds,artifact_seconds,corrected_fraction,obs_components_max,anc_channels,correlation_fallbacks"
        ]
        for evaluation in cases()
        where selectedCases?.contains(evaluation.label) ?? true {
            let clean = try evaluate(
                data.cleanFloat,
                recording: data,
                config: evaluation.config
            )
            let artifact = try evaluate(
                data.noisy,
                recording: data,
                config: evaluation.config
            )
            let line = csv(evaluation.label, clean, artifact)
            lines.append(line)
            print(line)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-fastr-c5-evaluation.csv")
        try (lines.joined(separator: "\n") + "\n").write(
            to: destination,
            atomically: true,
            encoding: .utf8
        )
    }
}
