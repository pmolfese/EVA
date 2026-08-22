//
//  MFFEventPrecisionTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Regression: MFF event times must survive a write/read round trip at
//  sampling rates whose period is not a whole number of milliseconds.
//
//  Both halves of the round trip used to quantize to 1 ms — the writer because
//  DateFormatter carries millisecond internal precision regardless of how many
//  `S` characters the format string has, and the reader because
//  ISO8601DateFormatter's `.withFractionalSeconds` truncates past three digits.
//  At 1024 Hz a sample is 976.5625 µs, so that displaced events by up to ±0.51
//  samples and two adjacent TR markers could land 1.02 samples apart, which is
//  what produced the intermittent "TRs are not evenly spaced" rejection.
//
//  1000 Hz and 500 Hz cannot catch this: their sample periods are whole
//  milliseconds, so they round-tripped correctly even when the bug was present.
//

import Testing
import Foundation
@testable import EVA

struct MFFEventPrecisionTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-precision-\(UUID().uuidString).mff")
    }

    /// A recording whose start time deliberately carries a sub-millisecond
    /// fraction, so a bug that quantizes the origin separately from the events
    /// cannot hide behind a round number.
    private func makeSignal(sampleRate: Double, eventSamples: [Int]) -> MFFSignalData {
        let sampleCount = (eventSamples.max() ?? 0) + Int(sampleRate)
        let start = Date(timeIntervalSince1970: 1_760_000_000.000_372_5)
        let events = eventSamples.enumerated().map { index, sample in
            MFFEvent(
                id: "event-\(index)",
                code: "TREV",
                beginTimeSeconds: Double(sample) / sampleRate,
                rawBeginTime: "",
                sourceFile: "test"
            )
        }
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/dev/null"),
            signalType: "EEG",
            numberOfChannels: 2,
            samplingRate: sampleRate,
            duration: Double(sampleCount) / sampleRate,
            recordingStartTime: start,
            events: events,
            data: Array(repeating: [Float](repeating: 0, count: sampleCount), count: 2),
            channelNames: ["E1", "E2"]
        )
    }

    private func roundTripSamples(sampleRate: Double, eventSamples: [Int]) throws -> [Int] {
        let signal = makeSignal(sampleRate: sampleRate, eventSamples: eventSamples)
        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(
            signal: signal, segments: [], kind: .continuous, to: out,
            preserveSourceFileInfo: false
        )
        let readback = try MFFReader().loadSignal(from: out)
        return readback.events
            .map { Int(($0.beginTimeSeconds * sampleRate).rounded()) }
            .sorted()
    }

    @Test(arguments: [512.0, 1024.0, 2048.0, 20000.0, 1000.0, 500.0])
    func eventSamplesSurviveRoundTripAtAnyRate(sampleRate: Double) throws {
        // Deliberately not multiples of anything: an event on a whole
        // millisecond would round-trip even with the old millisecond writer.
        let eventSamples = [0, 1, 7, 1023, 1024, 3071, 3072, 5119]
        let recovered = try roundTripSamples(sampleRate: sampleRate, eventSamples: eventSamples)
        #expect(recovered == eventSamples.sorted())
    }

    /// The failure as it actually presented: evenly spaced TR markers whose
    /// spacing must survive to within one sample.
    @Test func trMarkerSpacingSurvivesAt1024Hz() throws {
        let sampleRate = 1024.0
        let samplesPerTR = 3072 // TR = 3 s
        let eventSamples = (0..<20).map { $0 * samplesPerTR }
        let recovered = try roundTripSamples(sampleRate: sampleRate, eventSamples: eventSamples)

        try #require(recovered.count == eventSamples.count)
        let spacings = zip(recovered.dropFirst(), recovered).map { $0 - $1 }
        #expect(spacings.allSatisfy { $0 == samplesPerTR })
    }

    @Test func timestampStringKeepsSixFractionalDigitsAndNumericOffset() {
        let stamp = MFFTimestamp(seconds: 1_760_000_000, nanoseconds: 976_562_500)
        let text = stamp.string()
        // 976562500 ns snaps to the nearest whole microsecond, 976563 (round
        // half up), because the emitted string carries six fractional digits.
        #expect(text.contains(".976563"))
        // MNE's regex requires a numeric offset; a "Z" suffix is rejected.
        #expect(!text.hasSuffix("Z"))
        #expect(text.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil)
    }

    @Test func timestampCarriesAndNormalizesNanosecondOverflow() {
        // Adding across a second boundary carries.
        let advanced = MFFTimestamp(seconds: 100, nanoseconds: 999_999_000)
            .adding(nanoseconds: 1_000)
        #expect(advanced.seconds == 101)
        #expect(advanced.nanoseconds == 0)

        // Sub-microsecond input snaps up into a carry rather than producing an
        // out-of-range remainder.
        let snappedUp = MFFTimestamp(seconds: 100, nanoseconds: 999_999_800)
        #expect(snappedUp.seconds == 101)
        #expect(snappedUp.nanoseconds == 0)

        // Negative nanoseconds borrow a second. Normalization happens before
        // microsecond snapping, so truncating integer division cannot bias the
        // result toward zero the way it would on a negative remainder.
        let negative = MFFTimestamp(seconds: 100, nanoseconds: -1_200)
        #expect(negative.seconds == 99)
        #expect(negative.nanoseconds == 999_999_000)
    }

    @Test func integerSampleOffsetsAvoidDoubleRounding() {
        // 1024 Hz: sample 1 is 976562.5 ns, which must round to 976563 ns
        // (976563 µs·1e-3), not to the 977000 ns a millisecond grid would give.
        #expect(MFFWriter.eventOffsetNanoseconds(sample: 1, sampleRate: 1024) == 976_563)
        #expect(MFFWriter.eventOffsetNanoseconds(sample: 1024, sampleRate: 1024) == 1_000_000_000)
        #expect(MFFWriter.eventOffsetNanoseconds(sample: 0, sampleRate: 1024) == 0)
    }

    @Test(arguments: [
        ("2026-08-21T10:00:00.976563-04:00", 0.976563),
        ("2026-08-21T10:00:00.976-04:00", 0.976),
        ("2026-08-21T10:00:00.976563123-04:00", 0.976563123),
        ("2026-08-21T10:00:00-04:00", 0.0)
    ])
    func fractionalSecondsSplitAtAnyDigitCount(value: String, expected: Double) {
        let (remainder, fraction) = MFFReader.splitFractionalSeconds(value)
        #expect(!remainder.contains("."))
        #expect(abs(fraction - expected) < 1e-12)
    }
}
