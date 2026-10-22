import Foundation
import Testing
@testable import EVA

@MainActor
struct MFFAcquisitionGapTests {
    private func signal(gaps: [Range<Int>], pns: Bool = false) -> MFFSignalData {
        let rate = 1000.0
        let events = gaps.enumerated().map { i, range in
            MFFEvent(id: "gap-\(i)", code: "BAD_ACQ_SKIP", beginTimeSeconds: Double(range.lowerBound) / rate,
                     rawBeginTime: "", sourceFile: "test", durationSeconds: Double(range.count) / rate)
        } + [9, 15, 30].map { sample in
            MFFEvent(id: "task-\(sample)", code: "stim", beginTimeSeconds: Double(sample) / rate,
                     rawBeginTime: "", sourceFile: "test")
        }
        return MFFSignalData(signalURL: URL(fileURLWithPath: "/dev/null"), signalType: pns ? "PNSData" : "EEG",
            numberOfChannels: 2, samplingRate: rate, duration: 0.08,
            recordingStartTime: Date(timeIntervalSince1970: 1_700_000_000), events: events,
            data: [(0..<80).map(Float.init), (0..<80).map { Float(100 + $0) }],
            channelNames: pns ? ["ECG", "Resp"] : ["E1", "E2"])
    }

    private func temporaryPackage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("eva-gap-test-\(UUID().uuidString).mff")
    }

    @Test func acquisitionEpochsRestoreMissingSamplesAndPreserveTaskTimes() throws {
        let out = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: out) }
        let source = signal(gaps: [10..<15, 40..<47])
        try MFFWriter.write(signal: source, segments: [], kind: .continuous, to: out, preserveSourceFileInfo: false)
        // An original Net Station recording has acquisition epochs without EVA
        // annotations. Remove the annotation track and retain absolute task times.
        let eventsURL = out.appendingPathComponent("Events_EVA.xml")
        let document = try XMLDocument(contentsOf: eventsURL)
        for node in try document.nodes(forXPath: "//*[local-name()='event']") {
            if try node.nodes(forXPath: "./*[local-name()='code']").first?.stringValue == "BAD_ACQ_SKIP" {
                node.detach()
            }
        }
        try document.xmlData.write(to: eventsURL)
        let loaded = try MFFReader().loadSignal(from: out)
        #expect(loaded.data[0].count == 80)
        #expect(loaded.duration == 0.08)
        #expect(loaded.acquisitionSkipRanges == [10..<15, 40..<47])
        #expect(!loaded.isSegmented)
        #expect(loaded.events.filter { $0.code == "stim" }.map { Int(($0.beginTimeSeconds * 1000).rounded()) } == [9, 15, 30])
        for channel in loaded.data.indices {
            for sample in 0..<80 {
                #expect(loaded.data[channel][sample] == (source.acquisitionSkipRanges.contains { $0.contains(sample) }
                    ? 0 : source.data[channel][sample]))
            }
        }
        // The event at 30 ms must identify sample 30, never compressed sample 25.
        #expect(loaded.data[0][30] == 30)
    }

    @Test func gapMaskAndPNSAlignmentSurviveRepeatedExport() throws {
        let first = temporaryPackage(), second = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let source = signal(gaps: [10..<15])
        let anchorRules = EventAnchorRuleSet(rules: [.init(codePattern: "*", anchor: .center)])
        #expect(source.replacingEvents(anchorRules.applied(to: source.events)).acquisitionSkipRanges == [10..<15])
        try MFFWriter.write(signal: source, pnsSignal: signal(gaps: [], pns: true),
                            segments: [], kind: .continuous, to: first, preserveSourceFileInfo: false)
        let reader = MFFReader()
        let loaded = try reader.loadSignal(from: first)
        let pns = try #require(try reader.loadPNSSignal(from: first))
        #expect(pns.data[0].count == loaded.data[0].count)
        #expect(pns.acquisitionSkipRanges == loaded.acquisitionSkipRanges)
        #expect(pns.data[0][30] == 30)
        try MFFWriter.write(signal: loaded, pnsSignal: pns, segments: [], kind: .continuous,
                            to: second, preserveSourceFileInfo: false)
        let reopened = try reader.loadSignal(from: second)
        #expect(reopened.data == loaded.data)
        #expect(reopened.acquisitionSkipRanges == [10..<15])
        #expect(reopened.events.filter { $0.code == "BAD_ACQ_SKIP" }.count == 1)
    }

    @Test func uninterruptedRecordingIsUnchanged() throws {
        let out = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: out) }
        let source = signal(gaps: [])
        try MFFWriter.write(signal: source, segments: [], kind: .continuous, to: out, preserveSourceFileInfo: false)
        let loaded = try MFFReader().loadSignal(from: out)
        #expect(loaded.data == source.data)
        #expect(loaded.duration == source.duration)
        #expect(loaded.acquisitionSkipRanges.isEmpty)
        #expect(loaded.events.count == source.events.count)
        #expect(zip(loaded.events, source.events).allSatisfy {
            abs($0.beginTimeSeconds - $1.beginTimeSeconds) < 1e-6
        })
    }

    @Test func inconsistentAcquisitionEpochsAreRefused() throws {
        let out = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(signal: signal(gaps: [10..<15]), segments: [], kind: .continuous,
                            to: out, preserveSourceFileInfo: false)
        let url = out.appendingPathComponent("epochs.xml")
        let xml = try String(contentsOf: url, encoding: .utf8)
        try xml.replacingOccurrences(of: "<beginTime>15000</beginTime>", with: "<beginTime>5000</beginTime>")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try MFFReader().loadSignal(from: out) }
    }

    @Test func psaNeverBuildsEpochsAcrossAcquisitionGaps() async throws {
        let source = signal(gaps: [10..<15])
        let model = EpochingViewModel(store: RecordingStore())
        model.selectedEventCodes = ["stim"]
        model.categoryNames = ["stim": "stim"]
        model.preStimulus = 0.002
        model.postStimulus = 0.003
        model.skipIfContainsArtifact = false
        model.interpolatesBadChannelsPerEpoch = false
        var job = try #require(model.makeBuildJob(from: source, events: source.events))
        job.defersBadChannelDecisions = true
        let built = try #require(await job.buildEpochs())
        #expect(built.segments.count == 1)
        #expect(built.segments[0].sourceTimeSeconds == 0.030)
        #expect(built.segments[0].startSample == 0) // concatenated output epoch
        #expect(built.exclusionSummary.skippedArtifacts == 2)
    }
    @Test func filteringDoesNotBridgeMissingAcquisitionSamples() async throws {
        let data: [[Float]] = [(0..<4000).map { i in
            i < 1500 ? Float(sin(Double(i) / 20)) : (i < 2000 ? 9000 : Float(100 + cos(Double(i) / 15)))
        }]
        func filtered(_ input: [[Float]], _ ranges: [Range<Int>]? = nil) async throws -> [[Float]] {
            try await FilterViewModel.filteredChannels(input, samplingRate: 1000,
                lowCutoff: 1, highCutoff: 30, lineNoiseMode: .adaptiveCleanLine,
                notchFrequency: 60, lineNoiseHarmonics: 1, lineNoiseWindowSeconds: 0.5,
                lineNoiseStrength: 1, averageReference: false, excludedChannels: [],
                recordedRanges: ranges, progress: { _ in })
        }
        let actual = try await filtered(data, [0..<1500, 2000..<4000])
        let first = try await filtered([Array(data[0][0..<1500])])
        let second = try await filtered([Array(data[0][2000..<4000])])
        #expect(Array(actual[0][0..<1500]) == first[0])
        #expect(Array(actual[0][2000..<4000]) == second[0])
        #expect(actual[0][1500..<2000].allSatisfy { $0 == 0 })
    }

}
