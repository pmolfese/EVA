//
//  LAVISignificanceProviderTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct LAVISignificanceProviderTests {
    @Test func paperPresetPinsValidatedInferenceConfiguration() {
        let preset = RhythmicityPreset.paperLAVI2026
        guard case let .onDemand(significance) = preset.significance else {
            Issue.record("Paper preset did not enable on-demand significance")
            return
        }
        #expect(significance.repetitions == 200)
        #expect(significance.alpha == 0.05)
        #expect(significance.tailRule == .fifthOrderStatisticPerFrequency)
        #expect(significance.amplitudeDistribution == .observedSamples)
        #expect(significance.iaaft == .paper2026)
        #expect(preset.backend == .accelerateFFTCPU)
        #expect(preset.computePolicy == .productionDefault)
    }

    @Test func significanceConfigurationRoundTripsThroughCodable() throws {
        let original = RhythmicityPreset.paperLAVI2026(seed: 0x1234_5678)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RhythmicityConfiguration.self, from: data)
        #expect(decoded == original)
    }

    @Test func extractsExactFifthObservationsInEachTail() throws {
        let profiles = (0..<200).map { surrogate in
            [Double(surrogate), Double(1_000 - surrogate), Double(surrogate * 2)]
        }
        let ribbon = try LAVISignificanceProvider.extractPaperRibbon(
            profiles: profiles,
            frequenciesHz: [4, 8, 16],
            seed: 77
        )
        #expect(ribbon.lower == [4, 805, 8])
        #expect(ribbon.upper == [195, 996, 390])
        #expect(ribbon.seed == 77)
        #expect(ribbon.surrogateCount == 200)
        #expect(ribbon.tailRule == .fifthOrderStatisticPerFrequency)
    }

    @Test func rejectsAnExploratorySurrogateCountForPaperInference() {
        let profiles = [[Double]](repeating: [0.4], count: 20)
        #expect(throws: LAVISignificanceError.paperTailRequires200(repetitions: 20)) {
            try LAVISignificanceProvider.extractPaperRibbon(
                profiles: profiles,
                frequenciesHz: [10]
            )
        }
    }

    @Test func fullEnginePublishesRibbonFitDiagnosticsAndSignificantBands() throws {
        let samplingRate = 64.0
        let samples = (0..<256).map { index in
            let time = Double(index) / samplingRate
            return sin(2 * Double.pi * 8 * time)
                + 0.35 * sin(2 * Double.pi * 15 * time + 0.4)
                + 0.05 * sin(Double(index) * 0.731)
        }
        let input = RhythmicityInput.entireRecording(
            channels: [RhythmicityChannelInput(channelIndex: 3, channelName: "E4", samples: samples)],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "m2-integration", displayName: "M2 Integration"),
            processingProvenance: .init(sourceRevision: "m2-v1")
        )
        var configuration = RhythmicityPreset.paperLAVI2026(seed: 123_456)
        configuration.frequenciesHz = [4, 8, 12, 16, 20]
        guard case var .onDemand(significance) = configuration.significance else {
            Issue.record("Missing significance configuration")
            return
        }
        significance.aperiodicFitRangeHz = 2...24
        configuration.significance = .onDemand(significance)

        let progress = SignificanceProgressRecorder()
        let result = try LAVIEngine.analyze(
            input: input,
            configuration: configuration,
            coefficientProvider: SignificanceIdentityCoefficientProvider()
        ) { update in
            progress.append(update)
        }
        let channel = try #require(result.channels.first)
        let ribbon = try #require(channel.significanceRibbon)
        let summary = try #require(channel.surrogateSummary)
        let fit = try #require(channel.aperiodicFit)
        #expect(ribbon.lower.count == configuration.frequenciesHz.count)
        #expect(ribbon.upper.count == configuration.frequenciesHz.count)
        #expect(ribbon.seed == 123_456)
        #expect(summary.requestedCount == 200)
        #expect(summary.retainedCount == 200)
        #expect(summary.diagnostics.count == 200)
        #expect(fit.welchWindowCount == 3)
        #expect(!channel.bands.isEmpty)
        #expect(channel.bands.allSatisfy { $0.isSignificant != nil })
        #expect(progress.phases.contains(.estimatingAperiodicSpectrum))
        #expect(progress.phases.contains(.generatingSignificance))
        #expect(zip(progress.fractions, progress.fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func cancellationDuringSurrogatesPublishesNoPartialResult() {
        let samplingRate = 64.0
        let samples = (0..<256).map { index in
            sin(2 * Double.pi * 8 * Double(index) / samplingRate)
                + 0.1 * cos(Double(index) * 0.31)
        }
        let input = RhythmicityInput.entireRecording(
            channels: [RhythmicityChannelInput(channelIndex: 0, channelName: "E1", samples: samples)],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "cancel", displayName: "Cancel"),
            processingProvenance: .init(sourceRevision: "1")
        )
        var configuration = RhythmicityPreset.paperLAVI2026(seed: 7)
        configuration.frequenciesHz = [4, 8, 12, 16]
        guard case var .onDemand(significance) = configuration.significance else {
            Issue.record("Missing significance configuration")
            return
        }
        significance.aperiodicFitRangeHz = 2...24
        configuration.significance = .onDemand(significance)
        let cancellation = RhythmicityCancellation()
        #expect(throws: CancellationError.self) {
            try LAVIEngine.analyze(
                input: input,
                configuration: configuration,
                coefficientProvider: SignificanceIdentityCoefficientProvider(),
                cancellation: cancellation
            ) { update in
                if update.phase == .generatingSignificance { cancellation.cancel() }
            }
        }
    }

    @Test func directMorletBackendProducesFinitePaperRibbon() throws {
        let samplingRate = 64.0
        let samples = (0..<256).map { index in
            let time = Double(index) / samplingRate
            return sin(2 * Double.pi * 10 * time)
                + 0.3 * sin(2 * Double.pi * 19 * time + 0.6)
                + 0.08 * cos(Double(index) * 1.713)
        }
        let input = RhythmicityInput.entireRecording(
            channels: [RhythmicityChannelInput(channelIndex: 0, channelName: "E1", samples: samples)],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "direct-m2", displayName: "Direct M2"),
            processingProvenance: .init(sourceRevision: "1")
        )
        var configuration = RhythmicityPreset.paperLAVI2026(seed: 99)
        configuration.backend = .directReferenceCPU
        configuration.frequenciesHz = [8, 12, 20, 28]
        guard case var .onDemand(significance) = configuration.significance else {
            Issue.record("Missing significance configuration")
            return
        }
        significance.aperiodicFitRangeHz = 2...30
        configuration.significance = .onDemand(significance)
        let result = try LAVIEngine.analyze(input: input, configuration: configuration)
        let channel = try #require(result.channels.first)
        #expect(channel.values.allSatisfy { $0.isFinite })
        #expect(channel.lowerSignificance?.allSatisfy { $0.isFinite } == true)
        #expect(channel.upperSignificance?.allSatisfy { $0.isFinite } == true)
        #expect(channel.significanceRibbon?.surrogateCount == 200)
        #expect(channel.bands.allSatisfy { $0.isSignificant != nil })
    }
}

private nonisolated struct SignificanceIdentityCoefficientProvider: ComplexCoefficientProvider {
    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile {
        try cancellation.check()
        let scale = 1 + frequencyHz / 100
        return ComplexCoefficientTile(
            frequencyHz: frequencyHz,
            real: signal.map { $0 * scale },
            imaginary: signal.indices.map { index in
                0.1 * sin(2 * Double.pi * frequencyHz * Double(index) / samplingRate)
            },
            validSampleRange: signal.indices
        )
    }
}

private nonisolated final class SignificanceProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [RhythmicityProgress] = []

    func append(_ update: RhythmicityProgress) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    var phases: [RhythmicityProgressPhase] {
        lock.lock()
        defer { lock.unlock() }
        return updates.map(\.phase)
    }

    var fractions: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return updates.map(\.fractionComplete)
    }
}
