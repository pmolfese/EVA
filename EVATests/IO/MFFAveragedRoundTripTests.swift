//
//  MFFAveragedRoundTripTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Regression: EVA-exported averaged/epoched MFF packages must contain a
//  categories.xml so EVA (and other readers) recognize them as averaged on
//  reopen — previously only epochs.xml was written and the file read as continuous.
//

import Testing
import Foundation
@testable import EVA

struct MFFAveragedRoundTripTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-avg-\(UUID().uuidString).mff")
    }

    @Test func averagedExportWritesCategoriesAndReadsBackAsAveraged() throws {
        // Start from a real continuous fixture, then export it as an average of
        // two categories (each with a >1 trial count).
        let source = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let sampleCount = source.data.first?.count ?? 0
        try #require(sampleCount >= 200)

        let half = sampleCount / 2
        let segments = [
            EpochSegment(startSample: 0, endSample: half - 1, stimulusOffsetSamples: 10,
                         category: "Target", sourceCode: "TAR", sourceTimeSeconds: 0,
                         colorIndex: 0, contributingEpochCount: 30),
            EpochSegment(startSample: half, endSample: sampleCount - 1, stimulusOffsetSamples: 10,
                         category: "Standard", sourceCode: "STD", sourceTimeSeconds: 0,
                         colorIndex: 1, contributingEpochCount: 42)
        ]

        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(signal: source, segments: segments, kind: .averaged, to: out)

        // categories.xml must now exist.
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("categories.xml").path))

        // Reopen: EVA must see it as segmented + averaged with both categories.
        let readback = try MFFReader().loadSignal(from: out)
        #expect(readback.isSegmented)
        #expect(readback.isAveraged)
        #expect(readback.epochSegments.count == 2)
        #expect(Set(readback.epochSegments.map(\.category)) == ["Target", "Standard"])
    }

    @Test func singletonCategoryAveragesReadBackAsAveraged() throws {
        let source = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let sampleCount = source.data.first?.count ?? 0
        try #require(sampleCount >= 200)
        let half = sampleCount / 2
        let segments = [
            EpochSegment(startSample: 0, endSample: half - 1, stimulusOffsetSamples: 10,
                         category: "Target", sourceCode: "TAR", sourceTimeSeconds: 0,
                         colorIndex: 0, contributingEpochCount: 1),
            EpochSegment(startSample: half, endSample: sampleCount - 1, stimulusOffsetSamples: 10,
                         category: "Standard", sourceCode: "STD", sourceTimeSeconds: 0,
                         colorIndex: 1, contributingEpochCount: 1)
        ]

        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(signal: source, segments: segments, kind: .averaged, to: out)

        let categories = try String(contentsOf: out.appendingPathComponent("categories.xml"), encoding: .utf8)
        #expect(categories.components(separatedBy: "<name>Average</name>").count - 1 == 2)
        let readback = try MFFReader().loadSignal(from: out)
        #expect(readback.isAveraged)
        #expect(readback.epochSegments.allSatisfy { $0.contributingEpochCount == 1 })
    }

    @Test func singletonEpochsRemainUnaveraged() throws {
        let source = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let sampleCount = source.data.first?.count ?? 0
        try #require(sampleCount >= 200)
        let half = sampleCount / 2
        let segments = [
            EpochSegment(startSample: 0, endSample: half - 1, stimulusOffsetSamples: 10,
                         category: "Target", sourceCode: "TAR", sourceTimeSeconds: 0,
                         colorIndex: 0, contributingEpochCount: 1),
            EpochSegment(startSample: half, endSample: sampleCount - 1, stimulusOffsetSamples: 10,
                         category: "Standard", sourceCode: "STD", sourceTimeSeconds: 0,
                         colorIndex: 1, contributingEpochCount: 1)
        ]

        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(signal: source, segments: segments, kind: .epoched, to: out)

        let readback = try MFFReader().loadSignal(from: out)
        #expect(readback.isSegmented)
        #expect(!readback.isAveraged)
    }

    @Test func legacySingletonAverageUsesEVAProcessingRecord() throws {
        let source = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let sampleCount = source.data.first?.count ?? 0
        try #require(sampleCount >= 200)
        let half = sampleCount / 2
        let segments = [
            EpochSegment(startSample: 0, endSample: half - 1, stimulusOffsetSamples: 10,
                         category: "Target", sourceCode: "TAR", sourceTimeSeconds: 0,
                         colorIndex: 0, contributingEpochCount: 1),
            EpochSegment(startSample: half, endSample: sampleCount - 1, stimulusOffsetSamples: 10,
                         category: "Standard", sourceCode: "STD", sourceTimeSeconds: 0,
                         colorIndex: 1, contributingEpochCount: 1)
        ]

        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(signal: source, segments: segments, kind: .averaged, to: out)
        let categoriesURL = out.appendingPathComponent("categories.xml")
        let categories = try String(contentsOf: categoriesURL, encoding: .utf8)
            .replacingOccurrences(of: "\n        <name>Average</name>", with: "")
        try categories.write(to: categoriesURL, atomically: true, encoding: .utf8)
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .segment, parameters: ["average": "true"]))
        try EVAProcessingScriptXML.write(script, toPackage: out)

        let readback = try MFFReader().loadSignal(from: out)
        #expect(readback.isAveraged)
    }

    @Test func continuousEventMetadataRoundTrips() throws {
        let source = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let event = MFFEvent(
            id: "rich-event",
            code: "TARG",
            label: "Target",
            eventDescription: "A semantic description",
            cell: "cell-7",
            beginTimeSeconds: 0.125,
            rawBeginTime: "0.125",
            sourceFile: "original.vmrk",
            durationSeconds: 0.250
        )
        let signal = MFFSignalData(
            signalURL: source.signalURL,
            signalType: source.signalType,
            numberOfChannels: source.numberOfChannels,
            samplingRate: source.samplingRate,
            duration: source.duration,
            recordingStartTime: source.recordingStartTime,
            events: [event],
            data: source.data,
            channelNames: source.channelNames,
            impedancesKOhm: source.impedancesKOhm
        )
        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: out) }

        try MFFWriter.write(signal: signal, segments: [], kind: .continuous, to: out)
        let readback = try MFFReader().loadSignal(from: out)
        let restored = try #require(readback.events.first { $0.code == "TARG" })

        #expect(restored.label == event.label)
        #expect(restored.eventDescription == event.eventDescription)
        #expect(restored.cell == event.cell)
        #expect(abs(restored.beginTimeSeconds - event.beginTimeSeconds) < 1e-5)
        #expect(abs((restored.durationSeconds ?? 0) - 0.250) < 1e-9)
    }

    @MainActor
    @Test func eventRoundTripProducesIdenticalPSASampleRanges() async throws {
        let samplingRate = 100.0
        let event = MFFEvent(
            id: "boundary", code: "TARG", label: "Target",
            eventDescription: "sample-boundary sentinel", cell: "7",
            beginTimeSeconds: 2.0, rawBeginTime: "2.0", sourceFile: "sentinel",
            durationSeconds: 0.1
        )
        let signal = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/sentinel.raw"),
            signalType: "sentinel", numberOfChannels: 1,
            samplingRate: samplingRate, duration: 5,
            recordingStartTime: Date(timeIntervalSince1970: 1_700_000_000),
            events: [event],
            data: [(0..<500).map(Float.init)],
            channelNames: ["Fz"]
        )

        func segments(for candidate: MFFSignalData) async throws -> [EpochSegment] {
            let vm = EpochingViewModel(store: RecordingStore())
            vm.selectedEventCodes = ["TARG"]
            vm.categoryNames = ["TARG": "Target"]
            vm.preStimulus = 0.1
            vm.postStimulus = 0.2
            vm.skipIfContainsArtifact = false
            vm.interpolatesBadChannelsPerEpoch = false
            let job = try #require(vm.makeBuildJob(from: candidate, events: candidate.events))
            return try #require(await job.buildEpochs()).segments
        }

        let before = try await segments(for: signal)
        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(signal: signal, segments: [], kind: .continuous, to: out)
        let readback = try MFFReader().loadSignal(from: out)
        let after = try await segments(for: readback)

        #expect(before.count == 1)
        #expect(after.count == 1)
        #expect(after[0].startSample == before[0].startSample)
        #expect(after[0].endSample == before[0].endSample)
        #expect(after[0].stimulusOffsetSamples == before[0].stimulusOffsetSamples)
        #expect(after[0].sourceTimeSeconds == before[0].sourceTimeSeconds)
    }
}
