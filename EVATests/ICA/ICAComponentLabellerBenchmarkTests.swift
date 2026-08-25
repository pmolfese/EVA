//
//  ICAComponentLabellerBenchmarkTests.swift
//  EVATests
//
//  Roadmap 8.1: decompose one deliberately mixed EVASimulate recording, derive
//  graded class truth from its known topographies, and report every class for
//  ICLabel and EVA's transparent heuristic separately.
//

import Foundation
import Testing
@testable import EVA

struct ICAComponentLabellerBenchmarkTests {
    struct LabellerWatermark: Codable {
        var macroF1: Double
        var perClassF1: [String: Double]
    }

    static let corpusDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".regression-corpus/labeller-benchmark")
    }()

    static let watermarkURL = Fixtures.directory
        .appendingPathComponent("ica-labeller-watermark.json")

    @Test func gradedTruthRetainsOverlapRatherThanForcingOneHotLabels() {
        let membership = ICAComponentLabellerBenchmark.gradedMembership(
            map: [1, 1, 0, 0],
            truthClasses: [
                ICAComponentTruthClass(label: "Brain", topographies: [[1, 0, 0, 0]]),
                ICAComponentTruthClass(label: "Eye", topographies: [[0, 1, 0, 0]])
            ]
        )
        #expect((membership["Brain"] ?? 0) > 0)
        #expect((membership["Eye"] ?? 0) > 0)
        #expect(abs(membership.values.reduce(0, +) - 1) < 1e-12)
    }

    @Test func simulatedPerClassBenchmark() throws {
        let noisyURL = Self.corpusDirectory.appendingPathComponent("sim_noisy.mff")
        let truthURL = Self.corpusDirectory.appendingPathComponent("sim_truth.json")
        guard FileManager.default.fileExists(atPath: noisyURL.path),
              FileManager.default.fileExists(atPath: truthURL.path) else {
            print("ICAComponentLabellerBenchmarkTests: corpus absent — run ./run-all-tests.sh")
            return
        }

        let signal = try MFFReader().loadSignal(from: noisyURL)
        let layout = try #require(SensorLayout.load(
            fromPackageContaining: noisyURL.appendingPathComponent("signal1.bin")
        ))
        let truth = try SimulationTruthFixture.load(from: truthURL)
        let decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: ICAConfiguration(
                method: .picardO,
                componentCount: signal.numberOfChannels,
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
        try #require(decomposition.componentCount >= 10)

        let truthClasses = Self.truthClasses(
            truth: truth, signal: signal, componentChannelCount: decomposition.channelCount
        )
        for label in ICAComponentLabellerBenchmark.knownClasses {
            #expect(truthClasses.contains { $0.label == label && !$0.topographies.isEmpty })
        }

        let icLabelSuggestions = ICLabelClassifier.suggestions(
            for: decomposition, layout: layout
        )
        let heuristicSuggestions = ICAComponentAutoLabeler.heuristicSuggestions(
            for: decomposition, layout: layout
        )
        let results = [
            ICAComponentLabellerBenchmark.evaluate(
                labeller: "ICLabel", decomposition: decomposition,
                suggestions: icLabelSuggestions, truthClasses: truthClasses
            ),
            ICAComponentLabellerBenchmark.evaluate(
                labeller: "EVA heuristic", decomposition: decomposition,
                suggestions: heuristicSuggestions, truthClasses: truthClasses
            )
        ]

        try #require(results.allSatisfy { $0.classifiedCount == decomposition.componentCount })
        for result in results {
            #expect(result.perClass.keys.contains("Other"))
            for label in ICAComponentLabellerBenchmark.knownClasses {
                let metrics = try #require(result.perClass[label])
                #expect(metrics.support > 0)
                #expect(metrics.precision.isFinite && (0...1).contains(metrics.precision))
                #expect(metrics.recall.isFinite && (0...1).contains(metrics.recall))
                #expect(metrics.f1.isFinite && (0...1).contains(metrics.f1))
            }
        }

        let snapshots = Dictionary(uniqueKeysWithValues: results.map { result in
            (result.labeller, LabellerWatermark(
                macroF1: result.macroF1,
                perClassF1: Dictionary(uniqueKeysWithValues:
                    ICAComponentLabellerBenchmark.knownClasses.map { label in
                        (label, result.perClass[label]?.f1 ?? 0)
                    })
            ))
        })
        if ProcessInfo.processInfo.environment["EVA_UPDATE_WATERMARK"] == "1"
            || !FileManager.default.fileExists(atPath: Self.watermarkURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let text = String(data: try encoder.encode(snapshots), encoding: .utf8) ?? ""
            Issue.record("Record EVATests/Fixtures/ica-labeller-watermark.json:\n\(text)")
            return
        }

        let recordedData = try Data(contentsOf: Self.watermarkURL)
        let recorded = try JSONDecoder().decode(
            [String: LabellerWatermark].self, from: recordedData
        )
        for result in results {
            let baseline = try #require(recorded[result.labeller])
            #expect(result.macroF1 >= max(baseline.macroF1 - 0.10, 0))
            for label in ICAComponentLabellerBenchmark.knownClasses {
                let current = result.perClass[label]?.f1 ?? 0
                let previous = baseline.perClassF1[label] ?? 0
                #expect(current >= max(previous - 0.15, 0),
                        "\(result.labeller) \(label) F1 fell from \(previous) to \(current)")
            }
        }
    }

    static func truthClasses(
        truth: SimulationTruthFixture,
        signal: MFFSignalData,
        componentChannelCount: Int
    ) -> [ICAComponentTruthClass] {
        let leadField = truth.sourceSpace?.leadField.matrixMicrovoltsPerNanoampereMeter ?? []
        let sourceCount = leadField.map(\.count).min() ?? 0
        let brain = (0..<sourceCount).map { source in
            leadField.prefix(componentChannelCount).map { $0[source] }
        }
        let eye = [truth.blinkTopography, truth.horizontalEyeTopography]
            .filter { !$0.isEmpty }
        let heart = truth.bcgGenerators?.map(\.topography) ?? []
        let muscle = [
            truth.emgLeftTemporalisTopography,
            truth.emgRightTemporalisTopography,
            truth.emgPosteriorNeckTopography
        ].compactMap { $0 }
        let line = lineNoiseTopographies(
            data: signal.data, samplingRate: signal.samplingRate,
            frequency: truth.config.lineNoiseHz
        )
        let channelNoise = truth.badChannels.keys.compactMap(Int.init).map { number in
            var basis = [Double](repeating: 0, count: componentChannelCount)
            if basis.indices.contains(number - 1) { basis[number - 1] = 1 }
            return basis
        }
        return [
            ICAComponentTruthClass(label: "Brain", topographies: brain),
            ICAComponentTruthClass(label: "Eye", topographies: eye),
            ICAComponentTruthClass(label: "Heart", topographies: heart),
            ICAComponentTruthClass(label: "Muscle", topographies: muscle),
            ICAComponentTruthClass(label: "Line Noise", topographies: line),
            ICAComponentTruthClass(label: "Channel Noise", topographies: channelNoise)
        ]
    }

    static func lineNoiseTopographies(
        data: [[Float]], samplingRate: Double, frequency: Double
    ) -> [[Double]] {
        guard samplingRate > 0, frequency > 0 else { return [] }
        let sampleCount = data.map(\.count).min() ?? 0
        guard sampleCount > 0 else { return [] }
        var sineMap = [Double](repeating: 0, count: data.count)
        var cosineMap = [Double](repeating: 0, count: data.count)
        for channel in data.indices {
            for sample in 0..<sampleCount {
                let phase = 2 * Double.pi * frequency * Double(sample) / samplingRate
                let value = Double(data[channel][sample])
                sineMap[channel] += value * sin(phase)
                cosineMap[channel] += value * cos(phase)
            }
        }
        return [sineMap, cosineMap]
    }
}
