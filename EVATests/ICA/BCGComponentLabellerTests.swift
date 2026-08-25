//
//  BCGComponentLabellerTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct BCGComponentLabellerTests {
    private let samplingRate = 250.0

    @Test func beatLockedComponentOutranksUnrelatedActivity() throws {
        let beats = stride(from: 1.0, through: 18.0, by: 1.0).map { $0 }
        let count = Int(20 * samplingRate)
        var bcg = [Double](repeating: 0, count: count)
        for beat in beats {
            let center = Int((beat + 0.18) * samplingRate)
            for offset in -30...70 where bcg.indices.contains(center + offset) {
                let x = Double(offset) / 18
                bcg[center + offset] += exp(-0.5 * x * x) - 0.55 * exp(-0.5 * pow((Double(offset) - 28) / 15, 2))
            }
        }
        let unrelated = (0..<count).map { index in
            sin(2 * .pi * 9.7 * Double(index) / samplingRate)
                + 0.4 * sin(2 * .pi * 3.3 * Double(index) / samplingRate)
        }
        let bcgFeatures = try #require(BCGComponentLabeller.features(
            source: bcg, samplingRate: samplingRate, detectedBeatTimes: beats
        ))
        let unrelatedFeatures = try #require(BCGComponentLabeller.features(
            source: unrelated, samplingRate: samplingRate, detectedBeatTimes: beats
        ))
        #expect(bcgFeatures.beatLockedFraction > unrelatedFeatures.beatLockedFraction)
        #expect(bcgFeatures.beatConsistency > unrelatedFeatures.beatConsistency)
        #expect(BCGComponentLogisticModel.simulatorPilotV1.probability(for: bcgFeatures)
                > BCGComponentLogisticModel.simulatorPilotV1.probability(for: unrelatedFeatures))
    }

    @Test func fewerThanEightDetectedBeatsCannotChangeLabels() {
        let decomposition = oneComponent(source: [Double](repeating: 0, count: 1_000))
        let base = [0: ICAComponentSuggestion(label: "Brain 90%", confidence: 0.9, reason: "base")]
        let result = BCGComponentLabeller.augmenting(
            base, decomposition: decomposition,
            detectedBeatTimes: [1, 2, 3, 4, 5, 6, 7]
        )
        #expect(result[0]?.label == "Brain 90%")
        #expect(result[0]?.probabilities["BCG"] == nil)
    }

    @Test func suggestionsComposeWithRatherThanEraseTheBaseClassifier() throws {
        let beats = stride(from: 1.0, through: 10.0, by: 1.0).map { $0 }
        var source = [Double](repeating: 0, count: Int(12 * samplingRate))
        for beat in beats {
            let index = Int((beat + 0.16) * samplingRate)
            if source.indices.contains(index) { source[index] = 8 }
            if source.indices.contains(index + 20) { source[index + 20] = -5 }
        }
        let decomposition = oneComponent(source: source)
        let base = [0: ICAComponentSuggestion(
            label: "Other", confidence: 0.3, reason: "generic result",
            probabilities: ["Other": 0.7, "Heart": 0.3]
        )]
        let result = BCGComponentLabeller.augmenting(
            base, decomposition: decomposition, detectedBeatTimes: beats
        )
        let suggestion = try #require(result[0])
        #expect(suggestion.probabilities["Other"] == 0.7)
        #expect(suggestion.probabilities["Heart"] == 0.3)
        #expect(suggestion.probabilities["BCG"] != nil)
        #expect(suggestion.reason.contains("detected R waves"))
    }

    @Test func logisticFitLearnsAContinuousSimulatorTarget() {
        let negative = BCGComponentFeatures(
            beatLockedFraction: 0.05, beatConsistency: 0.10,
            postQRSProminence: 0.10, ecgRelationship: 0.05, heartPrior: 0.1
        )
        let mixed = BCGComponentFeatures(
            beatLockedFraction: 0.50, beatConsistency: 0.55,
            postQRSProminence: 0.60, ecgRelationship: 0.30, heartPrior: 0.3
        )
        let positive = BCGComponentFeatures(
            beatLockedFraction: 0.92, beatConsistency: 0.90,
            postQRSProminence: 0.90, ecgRelationship: 0.80, heartPrior: 0.8
        )
        let model = BCGComponentLogisticModel.fit([
            .init(features: negative, target: 0.02),
            .init(features: mixed, target: 0.55),
            .init(features: positive, target: 0.98)
        ])
        #expect(model.probability(for: negative) < model.probability(for: mixed))
        #expect(model.probability(for: mixed) < model.probability(for: positive))
    }

    @Test func truthUsesGeneratorAndNeuralSubspaces() {
        let membership = ICAComponentLabellerBenchmark.bcgSubspaceMembership(
            map: [1, 1, 0, 0],
            bcgTopographies: [[1, 0, 0, 0], [0, 1, 0, 0]],
            neuralTopographies: [[0, 0, 1, -1]]
        )
        #expect(membership > 0.95)
        let neural = ICAComponentLabellerBenchmark.bcgSubspaceMembership(
            map: [0, 0, 1, -1],
            bcgTopographies: [[1, 0, 0, 0], [0, 1, 0, 0]],
            neuralTopographies: [[0, 0, 1, -1]]
        )
        #expect(neural < 0.05)
    }

    @Test func simulatorTrainingGeneralizesToHeldOutGeneratorConfigurationAndImprovesCorrection() throws {
        let root = PipelineRegressionTests.corpusDirectory
        let trainingNames = ["bcg-labeller-train-lowfield", "bcg-labeller-train-standard"]
        let heldoutName = "bcg-labeller-heldout"
        let required = trainingNames + [heldoutName]
        guard required.allSatisfy({
            FileManager.default.fileExists(atPath:
                root.appendingPathComponent($0).appendingPathComponent("sim_truth.json").path)
        }) else {
            print("BCGComponentLabellerTests: training corpus absent — run ./run-all-tests.sh")
            return
        }

        var training: [BCGComponentTrainingExample] = []
        for name in trainingNames {
            let item = try decomposeCorpus(named: name, root: root)
            training += componentExamples(
                decomposition: item.decomposition, truth: item.truth,
                baseSuggestions: item.baseSuggestions, ecg: item.ecg
            )
        }
        let fitted = BCGComponentLogisticModel.fit(training)
        let heldout = try decomposeCorpus(named: heldoutName, root: root)
        let heldoutExamples = componentExamples(
            decomposition: heldout.decomposition, truth: heldout.truth,
            baseSuggestions: heldout.baseSuggestions, ecg: heldout.ecg
        )
        try #require(!heldoutExamples.isEmpty)

        let predictions = heldoutExamples.map { fitted.probability(for: $0.features) }
        let targets = heldoutExamples.map(\.target)
        let ranking = pairwiseRanking(predictions: predictions, targets: targets)
        #expect(ranking >= 0.70, "held-out graded ranking was \(ranking)")
        let heartPriorRanking = pairwiseRanking(
            predictions: heldoutExamples.map { $0.features.heartPrior }, targets: targets
        )
        #expect(ranking >= heartPriorRanking,
                "beat-locked ranking \(ranking) did not improve on Heart prior \(heartPriorRanking)")

        // The committed coefficients are the inference artifact; pin that they
        // retain the same ordering rather than accidentally becoming unrelated
        // to the reproducible simulator fit above.
        let committed = heldoutExamples.map {
            BCGComponentLogisticModel.simulatorPilotV1.probability(for: $0.features)
        }
        #expect(abs(fitted.intercept - BCGComponentLogisticModel.simulatorPilotV1.intercept) < 1e-12)
        #expect(zip(fitted.weights, BCGComponentLogisticModel.simulatorPilotV1.weights)
            .allSatisfy { abs($0.0 - $0.1) < 1e-12 })
        let committedRanking = pairwiseRanking(predictions: committed, targets: targets)
        #expect(committedRanking >= 0.65, "committed held-out ranking was \(committedRanking)")

        let selected = Set(committed.indices.filter {
            committed[$0] >= BCGComponentLabeller.suggestionThreshold
        })
        try #require(!selected.isEmpty)
        let clean = try MFFReader().loadSignal(from:
            root.appendingPathComponent(heldoutName).appendingPathComponent("sim_clean.mff"))
        let noisy = heldout.signal
        let corrected = ICAArtifactDetector.cleanedSignal(
            from: noisy, decomposition: heldout.decomposition, excluding: selected
        )
        let baselineSNR = PipelineRegressionTests.broadbandSNR(
            clean: clean.data, corrected: noisy.data, padSeconds: 0
        )
        let correctedSNR = PipelineRegressionTests.broadbandSNR(
            clean: clean.data, corrected: corrected.data, padSeconds: 0
        )
        #expect(correctedSNR > baselineSNR,
                "BCG-selected correction reduced SNR from \(baselineSNR) to \(correctedSNR)")
        print("BCG 5.4: Heart prior ranking=\(heartPriorRanking), beat-locked ranking=\(ranking), selected=\(selected.sorted()), SNR \(baselineSNR) -> \(correctedSNR)")
    }

    private func oneComponent(source: [Double]) -> ICADecomposition {
        ICADecomposition(
            sourceSignalPath: "/tmp/bcg-test.bin",
            sourceSamplingRate: samplingRate, analysisSamplingRate: samplingRate,
            decimation: 1, fitFilter: nil, convergenceTolerance: 1e-7,
            minimumIterations: 1, finalChange: 0, varianceThreshold: 1,
            pcaVarianceRetained: 1, averageReference: false,
            channelCount: 2, sampleCount: source.count, componentCount: 1,
            iterations: 1, channelMeans: [0, 0], mixingMatrix: [[1], [0]],
            unmixingMatrix: [[1, 0]], componentMaps: [[1, 0]],
            componentSources: [source], explainedVariance: [1],
            pcaExplainedVariance: [1]
        )
    }

    private func decomposeCorpus(
        named name: String, root: URL
    ) throws -> (signal: MFFSignalData, truth: SimulationTruthFixture,
                 decomposition: ICADecomposition, baseSuggestions: [Int: ICAComponentSuggestion],
                 ecg: (samples: [Float], samplingRate: Double)?) {
        let directory = root.appendingPathComponent(name)
        let noisyURL = directory.appendingPathComponent("sim_noisy.mff")
        let signal = try MFFReader().loadSignal(from: noisyURL)
        let truth = try SimulationTruthFixture.load(
            from: directory.appendingPathComponent("sim_truth.json")
        )
        let decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: ICAConfiguration(
                method: .picardO, componentCount: signal.numberOfChannels,
                varianceThreshold: 0.99999, averageReference: true,
                downsampleRate: 100, maxIterations: 250, learningRate: nil,
                fitFilter: nil, convergenceTolerance: 1e-7, minimumIterations: 1
            )
        )
        let layout = SensorLayout.load(
            fromPackageContaining: noisyURL.appendingPathComponent("signal1.bin")
        )
        let pns = try MFFReader().loadPNSSignal(from: noisyURL)
        return (signal, truth, decomposition,
                ICAComponentAutoLabeler.suggestions(for: decomposition, layout: layout),
                BCGComponentLabeller.likelyECG(in: pns))
    }

    private func componentExamples(
        decomposition: ICADecomposition,
        truth: SimulationTruthFixture,
        baseSuggestions: [Int: ICAComponentSuggestion],
        ecg: (samples: [Float], samplingRate: Double)?
    ) -> [BCGComponentTrainingExample] {
        let leadField = truth.sourceSpace?.leadField.matrixMicrovoltsPerNanoampereMeter ?? []
        let sourceCount = leadField.map(\.count).min() ?? 0
        let neural = (0..<sourceCount).map { source in
            leadField.prefix(decomposition.channelCount).map { $0[source] }
        }
        let bcg = truth.bcgGenerators?.map(\.topography) ?? []
        return (0..<decomposition.componentCount).compactMap { component in
            guard decomposition.componentSources.indices.contains(component),
                  decomposition.componentMaps.indices.contains(component),
                  let features = BCGComponentLabeller.features(
                    source: decomposition.componentSources[component],
                    samplingRate: decomposition.analysisSamplingRate,
                    detectedBeatTimes: truth.bcgDetectedBeatSeconds,
                    ecg: ecg?.samples,
                    ecgSamplingRate: ecg?.samplingRate,
                    heartPrior: baseSuggestions[component]?.probabilities["Heart"]
                        ?? (baseSuggestions[component]?.label.hasPrefix("Heart") == true
                            ? baseSuggestions[component]?.confidence ?? 0 : 0)
                  ) else { return nil }
            let target = ICAComponentLabellerBenchmark.bcgSubspaceMembership(
                map: decomposition.componentMaps[component],
                bcgTopographies: bcg, neuralTopographies: neural
            )
            return BCGComponentTrainingExample(features: features, target: target)
        }
    }

    /// Concordance for continuous targets (ties ignored), equivalent to an AUC
    /// generalized to graded simulator membership.
    private func pairwiseRanking(predictions: [Double], targets: [Double]) -> Double {
        var correct = 0.0, pairs = 0.0
        for first in predictions.indices {
            for second in predictions.indices where second > first {
                let targetDifference = targets[first] - targets[second]
                guard abs(targetDifference) > 0.05 else { continue }
                let predictionDifference = predictions[first] - predictions[second]
                pairs += 1
                if predictionDifference * targetDifference > 0 { correct += 1 }
                else if abs(predictionDifference) < 1e-12 { correct += 0.5 }
            }
        }
        return pairs > 0 ? correct / pairs : 0
    }
}
