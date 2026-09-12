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
        let clock = ContinuousClock()
        let parallelStart = clock.now
        let result = try LAVIEngine.analyze(
            input: input,
            configuration: configuration,
            coefficientProvider: SignificanceIdentityCoefficientProvider()
        ) { update in
            progress.append(update)
        }
        let parallelDuration = clock.now - parallelStart
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
        #expect(progress.details.contains { $0.contains("Fitting aperiodic spectrum") })
        #expect(progress.details.contains { $0.contains("IAAFT iteration") })
        #expect(progress.details.contains { $0.contains("Parallel IAAFT") })
        #expect(progress.details.contains { $0.contains("computing 5-frequency LAVI profile") })
        #expect(progress.completedSignificanceProfiles.contains(200))
        #expect(zip(progress.fractions, progress.fractions.dropFirst()).allSatisfy { $0 <= $1 })

        var serialConfiguration = configuration
        serialConfiguration.computePolicy.maximumWorkerCount = 1
        let serialStart = clock.now
        let serial = try LAVIEngine.analyze(
            input: input,
            configuration: serialConfiguration,
            coefficientProvider: SignificanceIdentityCoefficientProvider()
        )
        let serialDuration = clock.now - serialStart
        print(
            "Rhythmicity 200-surrogate profile: bounded parallel \(parallelDuration), "
                + "serial \(serialDuration)"
        )
        #expect(serial.channels[0].significanceRibbon == channel.significanceRibbon)
        #expect(serial.channels[0].surrogateSummary == channel.surrogateSummary)
    }

    @Test func cancellationDuringSurrogatesPublishesNoPartialResult() throws {
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-lavi-cancelled-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LAVISignificanceCacheStore(
            rootURL: root,
            recordingURL: root.appendingPathComponent("cancel.mff", isDirectory: true)
        )
        #expect(throws: CancellationError.self) {
            try LAVIEngine.analyze(
                input: input,
                configuration: configuration,
                coefficientProvider: SignificanceIdentityCoefficientProvider(),
                significanceCache: cache,
                cancellation: cancellation
            ) { update in
                if update.phase == .generatingSignificance { cancellation.cancel() }
            }
        }
        #expect(try cache.load(
            channel: input.channels[0],
            input: input,
            configuration: configuration
        ) == nil)
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

    @Test func exactPerChannelCacheReusesOnlyCompleteMatchingSignificance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-lavi-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("subject.mff", isDirectory: true)
        let cache = LAVISignificanceCacheStore(
            rootURL: root.appendingPathComponent("cache", isDirectory: true),
            recordingURL: recording
        )
        let samplingRate = 64.0
        let samples = (0..<256).map { index in
            let time = Double(index) / samplingRate
            return sin(2 * Double.pi * 9 * time)
                + 0.25 * cos(2 * Double.pi * 17 * time + 0.2)
                + 0.04 * sin(Double(index) * 0.731)
        }
        let channel = RhythmicityChannelInput(
            channelIndex: 2,
            channelName: "E3",
            samples: samples,
            isInterpolated: false
        )
        let input = RhythmicityInput.entireRecording(
            channels: [channel],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "\(recording.path)#revision-cache", displayName: "subject.mff"),
            processingProvenance: .init(
                sourceRevision: "revision-cache",
                processingSummary: ["Average reference"]
            )
        )
        var configuration = RhythmicityPreset.paperLAVI2026(seed: 0xCA_C4E)
        configuration.frequenciesHz = [4, 8, 12, 18, 24]
        guard case var .onDemand(significance) = configuration.significance else {
            Issue.record("Paper significance was unavailable")
            return
        }
        significance.aperiodicFitRangeHz = 2...28
        configuration.significance = .onDemand(significance)

        let provider = CacheCountingCoefficientProvider()
        let first = try LAVIEngine.analyze(
            input: input,
            configuration: configuration,
            coefficientProvider: provider,
            significanceCache: cache
        )
        let firstCallCount = provider.callCount
        #expect(firstCallCount > configuration.frequenciesHz.count)

        let progress = SignificanceProgressRecorder()
        let second = try LAVIEngine.analyze(
            input: input,
            configuration: configuration,
            coefficientProvider: provider,
            significanceCache: cache
        ) { progress.append($0) }
        #expect(provider.callCount - firstCallCount == configuration.frequenciesHz.count)
        #expect(second.channels[0].significanceRibbon == first.channels[0].significanceRibbon)
        #expect(second.channels[0].aperiodicFit == first.channels[0].aperiodicFit)
        #expect(second.channels[0].surrogateSummary == first.channels[0].surrogateSummary)
        #expect(progress.details.contains { $0.contains("Cache hit") })

        let key = cache.key(channel: channel, input: input, configuration: configuration)
        let cacheURL = cache.fileURL(for: key)
        let payload = try String(contentsOf: cacheURL, encoding: .utf8)
        #expect(!payload.contains("\"samples\""))
        #expect(!payload.contains("surrogateWaveforms"))

        var changedSeedConfiguration = configuration
        if case var .onDemand(changed) = changedSeedConfiguration.significance {
            changed.seed &+= 1
            changedSeedConfiguration.significance = .onDemand(changed)
        }
        #expect(try cache.load(
            channel: channel,
            input: input,
            configuration: changedSeedConfiguration
        ) == nil)

        var changedBackendConfiguration = configuration
        changedBackendConfiguration.backend = .directReferenceCPU
        #expect(try cache.load(
            channel: channel,
            input: input,
            configuration: changedBackendConfiguration
        ) == nil)

        let changedRevisionInput = RhythmicityInput(
            channels: input.channels,
            samplingRate: input.samplingRate,
            segments: input.segments,
            source: input.source,
            processingProvenance: .init(
                sourceRevision: "revision-cache-2",
                processingSummary: input.processingProvenance.processingSummary
            )
        )
        #expect(try cache.load(
            channel: channel,
            input: changedRevisionInput,
            configuration: configuration
        ) == nil)

        let changedSegmentsInput = RhythmicityInput(
            channels: input.channels,
            samplingRate: input.samplingRate,
            segments: [.init(startSample: 0, endSample: 191, label: "Shorter selection")],
            source: input.source,
            processingProvenance: input.processingProvenance
        )
        #expect(try cache.load(
            channel: channel,
            input: changedSegmentsInput,
            configuration: configuration
        ) == nil)

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        object["contentSHA256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL, options: .atomic)
        #expect(throws: RhythmicityPersistenceError.checksumMismatch) {
            try cache.load(channel: channel, input: input, configuration: configuration)
        }
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

private nonisolated final class CacheCountingCoefficientProvider: ComplexCoefficientProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile {
        try cancellation.check()
        lock.lock()
        count += 1
        lock.unlock()
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

    var details: [String] {
        lock.lock()
        defer { lock.unlock() }
        return updates.compactMap(\.detail)
    }

    var completedSignificanceProfiles: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return updates.compactMap(\.completedSignificanceProfiles)
    }
}
