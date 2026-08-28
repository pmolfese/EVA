//
//  EventTimeAnchorTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  `MFFEvent.timeAnchor` — the stored answer to "which instant does
//  `beginTimeSeconds` name?" — and the things that used to guess it.
//
//  EVA formerly inferred the answer by matching on `sourceFile` prefixes at
//  three separate call sites. These tests pin the three properties that made
//  the replacement worth doing: the derived geometry is consistent whichever
//  anchor an event carries, an anchor survives every hop between collections,
//  and a payload written before the field existed still decodes to the geometry
//  it had at the time.
//

import Testing
import Foundation
@testable import EVA

struct EventTimeAnchorTests {

    private func event(
        anchor: EventTimeAnchor,
        begin: Double = 10,
        duration: Double? = 0.4,
        code: String = "blnk",
        sourceFile: String = "test.mff",
        id: String = "e1"
    ) -> MFFEvent {
        MFFEvent(
            id: id,
            code: code,
            beginTimeSeconds: begin,
            rawBeginTime: "\(begin)",
            sourceFile: sourceFile,
            durationSeconds: duration,
            timeAnchor: anchor
        )
    }

    // MARK: - Derived geometry

    @Test func onsetEventRunsForwardFromItsMark() {
        let onset = event(anchor: .onset)
        #expect(onset.onsetTimeSeconds == 10)
        #expect(onset.centerTimeSeconds == 10.2)
        #expect(onset.endTimeSeconds == 10.4)
        #expect(onset.spanSeconds == 10...10.4)
    }

    @Test(arguments: [EventTimeAnchor.center, .peak])
    func centeredEventStraddlesItsMark(anchor: EventTimeAnchor) {
        let centered = event(anchor: anchor)
        #expect(centered.onsetTimeSeconds == 9.8)
        #expect(centered.centerTimeSeconds == 10)
        #expect(abs(centered.endTimeSeconds - 10.2) < 1e-12)
        #expect(centered.spanSeconds?.lowerBound == 9.8)
    }

    /// `.peak` exists to be labelled differently, not to be shaped differently.
    @Test func peakAndCenterShareGeometry() {
        let peak = event(anchor: .peak)
        let center = event(anchor: .center)
        #expect(peak.onsetTimeSeconds == center.onsetTimeSeconds)
        #expect(peak.centerTimeSeconds == center.centerTimeSeconds)
        #expect(peak.timeAnchor.timeFieldLabel != center.timeAnchor.timeFieldLabel)
    }

    /// With no duration there is no span, so every instant coincides and the
    /// anchor cannot move anything. This is why an anchor rule that does not
    /// also supply a duration has no visible effect on a stimulus marker.
    @Test(arguments: EventTimeAnchor.allCases)
    func durationlessEventIsAPointWhateverItsAnchor(anchor: EventTimeAnchor) {
        let point = event(anchor: anchor, duration: nil)
        #expect(point.onsetTimeSeconds == 10)
        #expect(point.centerTimeSeconds == 10)
        #expect(point.endTimeSeconds == 10)
        #expect(point.spanSeconds == nil)
    }

    @Test(arguments: EventTimeAnchor.allCases)
    func spanIsAlwaysOneDurationLong(anchor: EventTimeAnchor) {
        let span = try! #require(event(anchor: anchor, duration: 0.25).spanSeconds)
        #expect(abs((span.upperBound - span.lowerBound) - 0.25) < 1e-12)
    }

    @Test func zeroDurationHasNoSpan() {
        #expect(event(anchor: .center, duration: 0).spanSeconds == nil)
    }

    // MARK: - Reanchoring

    /// Re-anchoring reinterprets the marked instant; it never moves it. The
    /// sample the file recorded is a fact, and only EVA's reading of it is the
    /// user's to change.
    @Test func reanchoringKeepsTheMarkedInstant() {
        let original = event(anchor: .onset)
        let reanchored = original.reanchored(to: .peak)
        #expect(reanchored.beginTimeSeconds == original.beginTimeSeconds)
        #expect(reanchored.timeAnchor == .peak)
        #expect(reanchored.onsetTimeSeconds != original.onsetTimeSeconds)
    }

    @Test func reanchoringCanSupplyADuration() throws {
        let point = event(anchor: .onset, duration: nil)
        let widened = point.reanchored(to: .peak, durationSeconds: 0.4)
        #expect(widened.durationSeconds == 0.4)
        // Tolerance, not equality: the span's upper bound is computed as
        // 9.8 + 0.4, which in binary floating point is 10.200000000000001.
        let span = try #require(widened.spanSeconds)
        #expect(abs(span.lowerBound - 9.8) < 1e-12)
        #expect(abs(span.upperBound - 10.2) < 1e-12)
    }

    // MARK: - Codable migration

    /// A payload written before `timeAnchor` existed must decode to the
    /// geometry it had then, not to the `.onset` default the initializer uses.
    /// `eva_artifacts.json` holds detector events, and defaulting a centered
    /// one to `.onset` would move its cleaning window half a duration late on
    /// every reload — silent, and numerically wrong.
    @Test(arguments: [
        ("Template 90%", EventTimeAnchor.center),
        ("Trajectory 85%", EventTimeAnchor.center),
        ("Eye Artifact Threshold", EventTimeAnchor.center),
        ("Topography 90%", EventTimeAnchor.onset),
        ("Continuous 75%", EventTimeAnchor.onset),
    ])
    func legacyPayloadDecodesToItsOriginalGeometry(sourceFile: String, expected: EventTimeAnchor) throws {
        let legacy = """
        {
            "id": "legacy-1",
            "code": "ARTF",
            "beginTimeSeconds": 10.0,
            "rawBeginTime": "10.000000",
            "sourceFile": "\(sourceFile)",
            "durationSeconds": 0.4
        }
        """
        let decoded = try JSONDecoder().decode(MFFEvent.self, from: Data(legacy.utf8))
        #expect(decoded.timeAnchor == expected)

        // The property that actually mattered: the center the old
        // `centerTimeSeconds` computed is the center this decodes to.
        let legacyCenter = expected == .onset ? 10.2 : 10.0
        #expect(decoded.centerTimeSeconds == legacyCenter)
    }

    @Test func storedAnchorWinsOverTheLegacySniff() throws {
        // A "Template" source with an explicit `.onset` stamp decodes as onset,
        // proving the migration path only fills a genuinely missing field.
        let json = """
        {
            "id": "new-1",
            "code": "ARTF",
            "beginTimeSeconds": 10.0,
            "rawBeginTime": "10.000000",
            "sourceFile": "Template 90%",
            "durationSeconds": 0.4,
            "timeAnchor": "onset"
        }
        """
        let decoded = try JSONDecoder().decode(MFFEvent.self, from: Data(json.utf8))
        #expect(decoded.timeAnchor == .onset)
        #expect(decoded.centerTimeSeconds == 10.2)
    }

    @Test(arguments: EventTimeAnchor.allCases)
    func anchorSurvivesAnEncodeDecodeRoundTrip(anchor: EventTimeAnchor) throws {
        let original = event(anchor: anchor)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MFFEvent.self, from: data)
        #expect(decoded == original)
        #expect(decoded.timeAnchor == anchor)
    }

    // MARK: - Pass-through preservation

    /// Every hop an event makes between collections must carry its anchor. A
    /// dropped one is invisible — the event stays on the same sample and only
    /// its span quietly moves — which is exactly the class of silent parameter
    /// loss the determinism audit kept finding.
    @Test(arguments: EventTimeAnchor.allCases)
    func splitterPreservesAnchorForAnUntrimmedEvent(anchor: EventTimeAnchor) throws {
        let source = event(anchor: anchor, begin: 10, duration: 0.4)
        let signal = Self.signal(events: [source], duration: 30)
        // Boundary at 5 s; the event is marked at 10 s, so it lands in the
        // right-hand part at 5 s from that part's start.
        let pair = try MFFSignalSplitter.split(signal: signal, atSample: 5_000)
        let carried = try #require(pair.right.signal.events.first(where: { $0.id == source.id }))
        #expect(carried.timeAnchor == anchor)
        // Same offset within its part, whatever the anchor.
        #expect(abs(carried.beginTimeSeconds - 5) < 1e-9)
    }

    /// A span cut by a split boundary is no longer centered on its mark, so the
    /// clipped result is re-expressed as an onset rather than claiming a
    /// centering that would displace it.
    @Test func splitterRewritesATrimmedCenteredEventAsOnset() throws {
        // Centered at 5.1 s with a 0.4 s span → 4.9…5.3, straddling a boundary
        // at 5.0 s. The mark is in the second part, so that is where it lands.
        let source = event(anchor: .center, begin: 5.1, duration: 0.4)
        let signal = Self.signal(events: [source], duration: 30)
        let pair = try MFFSignalSplitter.split(signal: signal, atSample: 5_000)
        let carried = try #require(pair.right.signal.events.first(where: { $0.id == source.id }))

        #expect(carried.timeAnchor == .onset)
        // The surviving span is 5.0…5.3 in source time, i.e. 0…0.3 in part time.
        #expect(abs(carried.beginTimeSeconds - 0) < 1e-9)
        #expect(abs((carried.durationSeconds ?? 0) - 0.3) < 1e-9)
    }

    @Test(arguments: EventTimeAnchor.allCases)
    func epochedOverlayMapperPreservesAnchor(anchor: EventTimeAnchor) throws {
        let rate = 1000.0
        let segment = EpochSegment(
            startSample: 0,
            endSample: 999,
            stimulusOffsetSamples: 100,
            category: "cat",
            sourceCode: "STIM",
            sourceTimeSeconds: 10,
            colorIndex: 0,
            contributingEpochCount: 1
        )
        let source = event(anchor: anchor, begin: 10.05, duration: 0.1)
        let mapped = try #require(
            EpochedOverlayEventMapper.map(source, into: segment, samplingRate: rate)
        )
        #expect(mapped.timeAnchor == anchor)
        #expect(mapped.durationSeconds == source.durationSeconds)
    }

    // MARK: - Export

    /// MFF records onset plus duration and cannot express a centered event, so
    /// a centered one must be converted on the way out. Writing
    /// `beginTimeSeconds` straight through exported it half a duration late.
    @Test(arguments: [EventTimeAnchor.center, .peak])
    func exportWritesTheOnsetOfACenteredEvent(anchor: EventTimeAnchor) throws {
        let rate = 1000.0
        let source = event(anchor: anchor, begin: 10, duration: 0.4)
        let signal = Self.signal(events: [source], duration: 30, rate: rate)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-anchor-\(UUID().uuidString).mff")
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(
            signal: signal, segments: [], kind: .continuous, to: out,
            preserveSourceFileInfo: false
        )
        let readback = try MFFReader().loadSignal(from: out)
        let written = try #require(readback.events.first)

        // 9.8 s, the true onset — not 10.0.
        #expect(abs(written.beginTimeSeconds - 9.8) < 1e-3)
        // And it reads back as an onset event covering the same span.
        #expect(written.timeAnchor == .onset)
        #expect(abs((written.spanSeconds?.upperBound ?? 0) - 10.2) < 1e-3)
    }

    @Test func exportLeavesAnOnsetEventWhereItIs() throws {
        let source = event(anchor: .onset, begin: 10, duration: 0.4)
        let signal = Self.signal(events: [source], duration: 30)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-anchor-\(UUID().uuidString).mff")
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(
            signal: signal, segments: [], kind: .continuous, to: out,
            preserveSourceFileInfo: false
        )
        let written = try #require(try MFFReader().loadSignal(from: out).events.first)
        #expect(abs(written.beginTimeSeconds - 10) < 1e-3)
    }

    // MARK: - Fixtures

    static func signal(events: [MFFEvent], duration: Double, rate: Double = 1000) -> MFFSignalData {
        let sampleCount = Int(duration * rate)
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/dev/null"),
            signalType: "EEG",
            numberOfChannels: 2,
            samplingRate: rate,
            duration: duration,
            recordingStartTime: Date(timeIntervalSince1970: 1_760_000_000),
            events: events,
            data: Array(repeating: [Float](repeating: 0, count: sampleCount), count: 2),
            channelNames: ["E1", "E2"]
        )
    }
}
