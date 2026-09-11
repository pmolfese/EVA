//
//  LAVIEngineTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct LAVIEngineTests {
    private struct InputFixture: Decodable {
        struct Signal: Decodable {
            var samplingRateHz: Double
            var channels: [[Double]]
            var frequenciesHz: [Double]
            var waveletWidthCycles: Double
            var lagCycles: Double
        }
        var signal: Signal
    }

    private struct OutputFixture: Decodable { var lavi: [[Double]] }

    private static let inputFixture: InputFixture = decode("Rhythmicity/reference-input.json")
    private static let outputFixture: OutputFixture = decode("Rhythmicity/python-reference.json")

    @Test func directEngineMatchesPinnedPythonLAVI() throws {
        let fixture = Self.inputFixture.signal
        let channels = fixture.channels.enumerated().map { index, samples in
            RhythmicityChannelInput(
                channelIndex: index,
                channelName: "E\(index + 1)",
                samples: samples
            )
        }
        let input = RhythmicityInput.entireRecording(
            channels: channels,
            samplingRate: fixture.samplingRateHz,
            source: .init(recordingIdentity: "synthetic-m0", displayName: "Milestone 0 fixture"),
            processingProvenance: .init(sourceRevision: "fixture-v1")
        )
        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.backend = .directReferenceCPU
        configuration.frequenciesHz = fixture.frequenciesHz
        configuration.morletWidthCycles = fixture.waveletWidthCycles
        configuration.laviLagCycles = fixture.lagCycles
        let result = try LAVIEngine.analyze(input: input, configuration: configuration)

        var maximumError = 0.0
        for channel in result.channels.indices {
            for frequency in configuration.frequenciesHz.indices {
                maximumError = max(
                    maximumError,
                    abs(result.channels[channel].values[frequency]
                        - Self.outputFixture.lavi[channel][frequency])
                )
            }
        }
        #expect(maximumError < 1e-10, "Maximum Python LAVI error: \(maximumError)")
        #expect(result.channels.count == 2)
        #expect(result.channels.allSatisfy { $0.validPairCounts.allSatisfy { $0 > 0 } })
        #expect(result.channels.allSatisfy { $0.lowerSignificance == nil && $0.upperSignificance == nil })
        #expect(result.channels.allSatisfy { $0.values.allSatisfy { $0 >= 0 && $0 <= 1 } })
    }

    @Test func stationarySineHasNearUnitLAVIAtItsFrequency() throws {
        let samplingRate = 200.0
        let samples = (0..<2_400).map { index in
            sin(2 * Double.pi * 10 * Double(index) / samplingRate)
        }
        let result = try LAVIEngine.analyze(
            input: Self.makeInput(samples: samples, samplingRate: samplingRate),
            configuration: Self.paperConfiguration(frequencies: [10])
        )
        #expect(result.channels[0].values[0] > 0.9999)
        #expect(result.channels[0].validPairCounts[0] > 2_000)
    }

    @Test func repeatedPhaseResetsReduceLAVI() throws {
        let samplingRate = 200.0
        let phaseOffsets = [0.0, 2.1, -1.7, 0.8, -2.6, 1.4, -0.3, 2.8, -1.1, 0.4, -2.2, 1.9]
        let samples = (0..<2_400).map { index in
            let phase = phaseOffsets[index / 200]
            return sin(2 * Double.pi * 10 * Double(index) / samplingRate + phase)
        }
        let result = try LAVIEngine.analyze(
            input: Self.makeInput(samples: samples, samplingRate: samplingRate),
            configuration: Self.paperConfiguration(frequencies: [10])
        )
        #expect(result.channels[0].values[0] < 0.95)
    }

    @Test func zeroEnergyIsUnavailableRatherThanZeroRhythmicity() throws {
        let result = try LAVIEngine.analyze(
            input: Self.makeInput(samples: [Double](repeating: 0, count: 1_000), samplingRate: 200),
            configuration: Self.paperConfiguration(frequencies: [10])
        )
        #expect(result.channels[0].values[0].isNaN)
        #expect(result.channels[0].warnings.contains(
            RhythmicityWarning.insufficientValidDuration(channelIndex: 0, frequencyHz: 10)
        ))
    }

    @Test func segmentShorterThanWaveletSupportHasNoPairs() throws {
        let result = try LAVIEngine.analyze(
            input: Self.makeInput(samples: [Double](repeating: 1, count: 30), samplingRate: 200),
            configuration: Self.paperConfiguration(frequencies: [10])
        )
        #expect(result.channels[0].validPairCounts == [0])
        #expect(result.channels[0].values[0].isNaN)
    }

    @Test func lagPairsNeverCrossExplicitSegmentBoundaries() throws {
        let samples = [Double](repeating: 1, count: 20)
        let input = Self.makeInput(
            samples: samples,
            segments: [
                RhythmicitySegment(startSample: 0, endSample: 9, trialID: "a"),
                RhythmicitySegment(startSample: 10, endSample: 19, trialID: "b"),
            ]
        )
        let result = try LAVIEngine.analyze(
            input: input,
            configuration: Self.identityConfiguration,
            coefficientProvider: IdentityCoefficientProvider()
        )
        #expect(result.channels[0].validPairCounts == [16])
        #expect(abs(result.channels[0].values[0] - 1) < 1e-15)
    }

    @Test func nonfiniteSamplesSplitRunsAndAreReported() throws {
        var samples = [Double](repeating: 1, count: 20)
        samples[10] = .nan
        let input = Self.makeInput(
            samples: samples,
            segments: [RhythmicitySegment(startSample: 0, endSample: 19)]
        )
        let result = try LAVIEngine.analyze(
            input: input,
            configuration: Self.identityConfiguration,
            coefficientProvider: IdentityCoefficientProvider()
        )
        #expect(result.channels[0].validPairCounts == [15])
        #expect(result.channels[0].warnings.contains(
            RhythmicityWarning.nonfiniteSamplesExcluded(channelIndex: 0, count: 1)
        ))
    }

    @Test func pooledAccumulatorIsInvariantToNonzeroAmplitudeScaling() throws {
        let base = (0..<40).map { sin(Double($0) * 0.37) + 0.25 * cos(Double($0) * 0.11) }
        let scaled = base.map { -7.5 * $0 }
        let baseResult = try LAVIEngine.analyze(
            input: Self.makeInput(samples: base),
            configuration: Self.identityConfiguration,
            coefficientProvider: IdentityCoefficientProvider()
        )
        let scaledResult = try LAVIEngine.analyze(
            input: Self.makeInput(samples: scaled),
            configuration: Self.identityConfiguration,
            coefficientProvider: IdentityCoefficientProvider()
        )
        #expect(abs(baseResult.channels[0].values[0] - scaledResult.channels[0].values[0]) < 1e-14)
    }

    @Test func validationRejectsOverlappingSegments() {
        let input = Self.makeInput(
            samples: [Double](repeating: 1, count: 20),
            segments: [
                RhythmicitySegment(startSample: 0, endSample: 10),
                RhythmicitySegment(startSample: 10, endSample: 19),
            ]
        )
        #expect(throws: RhythmicityAnalysisError.overlappingOrUnsortedSegments(index: 1)) {
            try LAVIEngine.analyze(
                input: input,
                configuration: Self.identityConfiguration,
                coefficientProvider: IdentityCoefficientProvider()
            )
        }
    }

    @Test func progressHookCanCancelDeterministically() {
        let cancellation = RhythmicityCancellation()
        #expect(throws: CancellationError.self) {
            try LAVIEngine.analyze(
                input: Self.makeInput(samples: [Double](repeating: 1, count: 20)),
                configuration: Self.identityConfiguration,
                coefficientProvider: IdentityCoefficientProvider(),
                cancellation: cancellation
            ) { update in
                if update.phase == .transforming { cancellation.cancel() }
            }
        }
    }

    @Test func progressNeverRegressesAcrossChannels() throws {
        let recorder = ProgressRecorder()
        let first = RhythmicityChannelInput(
            channelIndex: 0,
            channelName: "E1",
            samples: [Double](repeating: 1, count: 20)
        )
        let second = RhythmicityChannelInput(
            channelIndex: 1,
            channelName: "E2",
            samples: [Double](repeating: 2, count: 20)
        )
        let input = RhythmicityInput.entireRecording(
            channels: [first, second],
            samplingRate: 20,
            source: .init(recordingIdentity: "test", displayName: "Test"),
            processingProvenance: .init(sourceRevision: "1")
        )
        _ = try LAVIEngine.analyze(
            input: input,
            configuration: Self.identityConfiguration,
            coefficientProvider: IdentityCoefficientProvider()
        ) { update in
            recorder.append(update.fractionComplete)
        }
        let values = recorder.snapshot
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    private static var identityConfiguration: RhythmicityConfiguration {
        RhythmicityConfiguration(
            presetID: "identity-test",
            frequenciesHz: [5],
            morletWidthCycles: 5,
            laviLagCycles: 0.25,
            wtplLagCycles: [1],
            alphaAnchorHz: 6...14,
            significance: .none,
            edgePolicy: .referenceSamePadding,
            precision: .float64,
            backend: .directReferenceCPU
        )
    }

    private static func makeInput(
        samples: [Double],
        segments: [RhythmicitySegment]? = nil,
        samplingRate: Double = 20
    ) -> RhythmicityInput {
        let channel = RhythmicityChannelInput(
            channelIndex: 0,
            channelName: "E1",
            samples: samples
        )
        if let segments {
            return RhythmicityInput(
                channels: [channel],
                samplingRate: samplingRate,
                segments: segments,
                source: .init(recordingIdentity: "test", displayName: "Test"),
                processingProvenance: .init(sourceRevision: "1")
            )
        }
        return RhythmicityInput.entireRecording(
            channels: [channel],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "test", displayName: "Test"),
            processingProvenance: .init(sourceRevision: "1")
        )
    }

    private static func paperConfiguration(frequencies: [Double]) -> RhythmicityConfiguration {
        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.backend = .directReferenceCPU
        configuration.frequenciesHz = frequencies
        return configuration
    }

    private static func decode<T: Decodable>(_ name: String) -> T {
        let data = try! Data(contentsOf: Fixtures.url(name))
        return try! JSONDecoder().decode(T.self, from: data)
    }
}

private nonisolated struct IdentityCoefficientProvider: ComplexCoefficientProvider {
    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile {
        try cancellation.check()
        return ComplexCoefficientTile(
            frequencyHz: frequencyHz,
            real: signal,
            imaginary: [Double](repeating: 0, count: signal.count),
            validSampleRange: signal.indices
        )
    }
}

private nonisolated final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Double] {
        lock.lock()
        let copy = values
        lock.unlock()
        return copy
    }
}
