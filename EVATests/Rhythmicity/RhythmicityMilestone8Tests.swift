//
//  RhythmicityMilestone8Tests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct RhythmicityMilestone8Tests {
    @Test func automaticBackendUsesMeasuredCrossoverAndAlwaysHasCPUFallback() {
        let small = RhythmicityBackendResolver.resolve(
            requested: .automatic,
            sampleCount: 1_000,
            frequencyCount: 10,
            metalAvailable: true
        )
        #expect(small.selected == .accelerateFFTCPU)
        #expect(small.precision == .float64)

        let large = RhythmicityBackendResolver.resolve(
            requested: .automatic,
            sampleCount: 10_000,
            frequencyCount: 47,
            metalAvailable: true
        )
        #expect(large.selected == .metalGPU)
        #expect(large.precision == .float32)

        let unavailable = RhythmicityBackendResolver.resolve(
            requested: .metalGPU,
            sampleCount: 10_000,
            frequencyCount: 47,
            metalAvailable: false
        )
        #expect(unavailable.selected == .accelerateFFTCPU)
        #expect(unavailable.fallbackReason?.contains("Metal") == true)
    }

    @Test func compiledMetalKernelMatchesCPUCoefficientsAndValidBoundaries() throws {
        let provider = try #require(RhythmicityMetalCoefficientProvider.shared)
        let samplingRate = 256.0
        let samples = (0..<4_096).map { index in
            let time = Double(index) / samplingRate
            return sin(2 * Double.pi * 9 * time + 0.23)
                + 0.31 * cos(2 * Double.pi * 27 * time)
                + 0.04 * sin(Double(index) * 0.713)
        }
        for frequency in [7.0, 10.0, 23.0] {
            let direct = try DirectComplexCoefficientProvider().coefficients(
                signal: samples,
                samplingRate: samplingRate,
                frequencyHz: frequency,
                widthCycles: 5,
                edgePolicy: .validOnly,
                cancellation: RhythmicityCancellation()
            )
            let metal = try provider.coefficients(
                signal: samples,
                samplingRate: samplingRate,
                frequencyHz: frequency,
                widthCycles: 5,
                edgePolicy: .validOnly,
                cancellation: RhythmicityCancellation()
            )
            let maximumError = zip(direct.real, metal.real).reduce(0.0) {
                max($0, abs($1.0 - $1.1))
            }
            let maximumImaginaryError = zip(direct.imaginary, metal.imaginary).reduce(0.0) {
                max($0, abs($1.0 - $1.1))
            }
            #expect(maximumError < 2e-4)
            #expect(maximumImaginaryError < 2e-4)
            #expect(metal.validSampleRange == direct.validSampleRange)
        }
    }

    @Test func metalFloatParityKeepsLAVIAndABBABoundariesStable() throws {
        _ = try #require(RhythmicityMetalCoefficientProvider.shared)
        let samplingRate = 256.0
        let samples = (0..<8_192).map { index in
            let time = Double(index) / samplingRate
            let phaseReset = Double(index / 640) * 0.41
            return sin(2 * Double.pi * 10 * time)
                + 0.35 * sin(2 * Double.pi * 18 * time + phaseReset)
                + 0.05 * cos(Double(index) * 0.317)
        }
        let input = RhythmicityInput.entireRecording(
            channels: [.init(channelIndex: 0, channelName: "Cz", samples: samples)],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "/fixture/metal", displayName: "Metal fixture"),
            processingProvenance: .init(sourceRevision: "revision-metal")
        )
        var directConfiguration = RhythmicityPreset.paperLAVI2026Exploratory
        directConfiguration.frequenciesHz = [6, 8, 10, 12, 16, 18, 22, 30]
        directConfiguration.backend = .directReferenceCPU
        let direct = try LAVIEngine.analyze(input: input, configuration: directConfiguration)

        var metalConfiguration = directConfiguration
        metalConfiguration.backend = .metalGPU
        let metal = try LAVIEngine.analyze(input: input, configuration: metalConfiguration)
        let directChannel = direct.channels[0]
        let metalChannel = metal.channels[0]
        let maximumError = zip(directChannel.values, metalChannel.values).reduce(0.0) {
            max($0, abs($1.0 - $1.1))
        }
        #expect(maximumError < 2e-5)
        #expect(metalChannel.validPairCounts == directChannel.validPairCounts)
        #expect(metalChannel.bands.map(Self.boundary) == directChannel.bands.map(Self.boundary))
        #expect(metal.configuration.backend == .metalGPU)
        #expect(metal.configuration.precision == .float32)
    }

    @Test func batchedMetalSignificanceProfilesMatchCPUAcrossFiniteRuns() throws {
        let metal = try #require(RhythmicityMetalCoefficientProvider.shared)
        let samplingRate = 128.0
        let frequencies = [6.0, 10.0, 18.0, 27.0]
        let surrogateRuns = (0..<4).map { surrogate in
            [1_024, 713].enumerated().map { run, count in
                (0..<count).map { index in
                    let time = Double(index) / samplingRate
                    return sin(2 * Double.pi * (8 + Double(surrogate)) * time + Double(run) * 0.2)
                        + 0.27 * cos(2 * Double.pi * 21 * time + Double(surrogate) * 0.13)
                        + 0.03 * sin(Double(index + surrogate * 17) * 0.619)
                }
            }
        }
        let metalProfiles = try metal.laviProfiles(
            surrogateRuns: surrogateRuns,
            samplingRate: samplingRate,
            frequenciesHz: frequencies,
            widthCycles: 5,
            lagCycles: 1,
            edgePolicy: .validOnly,
            cancellation: RhythmicityCancellation()
        )

        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.backend = .directReferenceCPU
        configuration.frequenciesHz = frequencies
        configuration.laviLagCycles = 1
        let cpuProfiles = try surrogateRuns.enumerated().map { surrogate, runs in
            let samples = runs[0] + [.nan] + runs[1]
            let input = RhythmicityInput.entireRecording(
                channels: [.init(channelIndex: surrogate, channelName: "S\(surrogate)", samples: samples)],
                samplingRate: samplingRate,
                source: .init(recordingIdentity: "metal-batch", displayName: "Metal batch"),
                processingProvenance: .init(sourceRevision: "1")
            )
            return try LAVIEngine.analyze(input: input, configuration: configuration).channels[0].values
        }
        #expect(metalProfiles.count == cpuProfiles.count)
        for (metalProfile, cpuProfile) in zip(metalProfiles, cpuProfiles) {
            #expect(metalProfile.count == frequencies.count)
            let maximumError = zip(metalProfile, cpuProfile).reduce(0.0) {
                max($0, abs($1.0 - $1.1))
            }
            #expect(maximumError < 2e-4)
        }
    }

    @Test func significanceWorkerPlannerHonorsExplicitCapAndMemoryBudget() {
        var cappedPolicy = RhythmicityComputePolicy.productionDefault
        cappedPolicy.maximumWorkerCount = 3
        let capped = LAVISignificanceWorkPlanner.workerCount(
            workItemCount: 200,
            totalSamples: 8_192,
            longestRunSamples: 8_192,
            frequenciesHz: [4, 8, 16, 32],
            samplingRate: 256,
            widthCycles: 5,
            policy: cappedPolicy,
            includesCPUProfileAnalysis: true
        )
        #expect(capped == 3)

        var constrainedPolicy = cappedPolicy
        constrainedPolicy.maximumWorkerCount = 8
        constrainedPolicy.memoryBudgetBytes = 2 * 1_024 * 1_024
        let constrained = LAVISignificanceWorkPlanner.workerCount(
            workItemCount: 200,
            totalSamples: 65_536,
            longestRunSamples: 65_536,
            frequenciesHz: [4, 8, 16, 32],
            samplingRate: 256,
            widthCycles: 5,
            policy: constrainedPolicy,
            includesCPUProfileAnalysis: true
        )
        #expect(constrained == 1)
    }

    @Test func fullPaperSignificanceUsesBatchedMetalProfiles() throws {
        _ = try #require(RhythmicityMetalCoefficientProvider.shared)
        let samplingRate = 64.0
        let samples = (0..<256).map { index in
            let time = Double(index) / samplingRate
            return sin(2 * Double.pi * 9 * time)
                + 0.3 * cos(2 * Double.pi * 17 * time + 0.2)
                + 0.04 * sin(Double(index) * 0.731)
        }
        let input = RhythmicityInput.entireRecording(
            channels: [.init(channelIndex: 0, channelName: "Cz", samples: samples)],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "metal-significance", displayName: "Metal significance"),
            processingProvenance: .init(sourceRevision: "1")
        )
        var configuration = RhythmicityPreset.paperLAVI2026(seed: 0x5151)
        configuration.backend = .metalGPU
        configuration.frequenciesHz = [4, 8, 12, 18, 24]
        guard case var .onDemand(significance) = configuration.significance else {
            Issue.record("Paper significance was unavailable")
            return
        }
        significance.aperiodicFitRangeHz = 2...28
        configuration.significance = .onDemand(significance)
        let progress = MetalSignificanceProgressRecorder()
        let result = try LAVIEngine.analyze(input: input, configuration: configuration) {
            progress.append($0)
        }
        let channel = try #require(result.channels.first)
        #expect(result.configuration.backend == .metalGPU)
        #expect(channel.significanceRibbon?.surrogateCount == 200)
        #expect(channel.lowerSignificance?.allSatisfy(\.isFinite) == true)
        #expect(channel.upperSignificance?.allSatisfy(\.isFinite) == true)
        #expect(progress.details.contains { $0.contains("Metal batch") })
        #expect(progress.completedProfiles.contains(200))
    }

    @Test func profileRecordsFFTAndMetalCoefficientCosts() throws {
        let metal = try #require(RhythmicityMetalCoefficientProvider.shared)
        let samplingRate = 512.0
        let samples = (0..<32_768).map { index in
            let time = Double(index) / samplingRate
            return sin(2 * Double.pi * 4 * time) + 0.2 * cos(2 * Double.pi * 17 * time)
        }
        let clock = ContinuousClock()
        let fftStart = clock.now
        let fft = try AccelerateFFTComplexCoefficientProvider().coefficients(
            signal: samples,
            samplingRate: samplingRate,
            frequencyHz: 4,
            widthCycles: 5,
            edgePolicy: .validOnly,
            cancellation: RhythmicityCancellation()
        )
        let fftDuration = clock.now - fftStart
        let metalStart = clock.now
        let gpu = try metal.coefficients(
            signal: samples,
            samplingRate: samplingRate,
            frequencyHz: 4,
            widthCycles: 5,
            edgePolicy: .validOnly,
            cancellation: RhythmicityCancellation()
        )
        let metalDuration = clock.now - metalStart
        print("Rhythmicity profile 32,768 samples × 4 Hz: FFT \(fftDuration), Metal \(metalDuration)")
        #expect(fft.real.count == samples.count)
        #expect(gpu.real.count == samples.count)
    }

    @Test func persistedPayloadRoundTripsAndTracksSourceAndUpstreamStaleness() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-rhythmicity-persistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RhythmicityPersistenceStore(rootURL: root)
        let fixture = Self.persistenceFixture()
        let recording = root.appendingPathComponent("subject.mff", isDirectory: true)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try store.save(
            result: fixture.result,
            selection: fixture.selection,
            recordingURL: recording,
            savedAt: savedAt
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("\"samples\""))
        #expect(text.contains(RhythmicityExport.referenceCommit))

        let loadedCurrent = try store.load(
            recordingURL: recording,
            currentSourceRevision: "revision-1"
        )
        let current = try #require(loadedCurrent)
        #expect(current.status == .current)
        #expect(current.savedAt == savedAt)
        #expect(current.result.configuration == fixture.result.configuration)
        #expect(current.result.channels[0].values.prefix(2) == fixture.result.channels[0].values.prefix(2))
        #expect(current.result.channels[0].values[2].isNaN)
        #expect(current.selection == fixture.selection)

        let loadedChangedSignal = try store.load(
            recordingURL: recording,
            currentSourceRevision: "revision-2"
        )
        let changedSignal = try #require(loadedChangedSignal)
        #expect(changedSignal.status.isStale)
        #expect(changedSignal.status.explanation?.contains("signal") == true)

        let loadedChangedMethod = try store.load(
            recordingURL: recording,
            currentSourceRevision: "revision-1",
            currentMethodVersion: "future-method-revision"
        )
        let changedMethod = try #require(loadedChangedMethod)
        #expect(changedMethod.status.isStale)
        #expect(changedMethod.status.explanation?.contains("method") == true)

        let loadedChangedUpstream = try store.load(
            recordingURL: recording,
            currentSourceRevision: "revision-1",
            currentUpstreamReferenceCommit: "future-upstream-revision"
        )
        let changedUpstream = try #require(loadedChangedUpstream)
        #expect(changedUpstream.status.isStale)
        #expect(changedUpstream.status.explanation?.contains("upstream") == true)
    }

    @Test func persistedPayloadRejectsChecksumTampering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-rhythmicity-tamper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RhythmicityPersistenceStore(rootURL: root)
        let fixture = Self.persistenceFixture()
        let recording = root.appendingPathComponent("subject.mff", isDirectory: true)
        let url = try store.save(
            result: fixture.result,
            selection: fixture.selection,
            recordingURL: recording
        )
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["contentSHA256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        #expect(throws: RhythmicityPersistenceError.checksumMismatch) {
            try store.load(recordingURL: recording, currentSourceRevision: "revision-1")
        }
    }

    private static func boundary(_ band: ABBABand) -> String {
        "\(band.beginIndex):\(band.endIndex):\(band.peakIndex):\(band.direction.rawValue)"
    }

    private static func persistenceFixture() -> (
        result: LAVIAnalysisResult,
        selection: RhythmicitySelectionDescriptor
    ) {
        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.frequenciesHz = [8, 10, 12]
        let band = ABBABand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
            beginIndex: 0,
            endIndex: 2,
            peakIndex: 1,
            beginFrequencyHz: 8,
            endFrequencyHz: 12,
            peakFrequencyHz: 10,
            peakLAVI: 0.8,
            deviationFromMedian: 0.1,
            direction: .sustained,
            relativeToAlpha: 0,
            canonicalName: "Alpha",
            isSignificant: nil,
            significanceMargin: nil
        )
        let channel = LAVIChannelResult(
            channelIndex: 0,
            channelName: "Cz",
            frequenciesHz: [8, 10, 12],
            values: [0.6, 0.8, .nan],
            validPairCounts: [100, 100, 0],
            effectiveDurationsSeconds: [1, 1, 0],
            median: 0.7,
            bands: [band],
            warnings: [.insufficientValidDuration(channelIndex: 0, frequencyHz: 12)]
        )
        let result = LAVIAnalysisResult(
            configuration: configuration,
            source: .init(recordingIdentity: "/fixture/subject.mff#revision-1", displayName: "subject.mff"),
            processingProvenance: .init(sourceRevision: "revision-1", processingSummary: ["Average reference"]),
            samplingRateHz: 256,
            channels: [channel],
            warnings: channel.warnings
        )
        let selection = RhythmicitySelectionDescriptor(
            source: .processed,
            dataSelection: .entireProcessedRecording,
            segments: [.init(startSample: 0, endSample: 255, label: "Entire recording")],
            channelScope: .current,
            channelSetName: nil,
            includedChannelIndices: [0],
            excludedBadChannelIndices: [],
            interpolatedChannelIndices: [],
            includedMarkedArtifacts: false
        )
        return (result, selection)
    }
}

private nonisolated final class MetalSignificanceProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [RhythmicityProgress] = []

    func append(_ update: RhythmicityProgress) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    var details: [String] {
        lock.lock()
        defer { lock.unlock() }
        return updates.compactMap(\.detail)
    }

    var completedProfiles: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return updates.compactMap(\.completedSignificanceProfiles)
    }
}
