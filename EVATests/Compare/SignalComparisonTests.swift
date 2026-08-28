//
//  SignalComparisonTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP RW-1 item 10. The measurements are easy; the alignment is where a
//  comparison quietly becomes meaningless, so most of these are about what gets
//  compared with what.
//

import Foundation
import Testing
@testable import EVA

struct SignalComparisonTests {

    private let samplingRate = 250.0

    private func signal(
        _ data: [[Float]],
        names: [String]? = nil,
        rate: Double? = nil
    ) -> MFFSignalData {
        let sampleCount = data.first?.count ?? 0
        let resolvedRate = rate ?? samplingRate
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/compare.bin"),
            signalType: "EEG",
            numberOfChannels: data.count,
            samplingRate: resolvedRate,
            duration: resolvedRate > 0 ? Double(sampleCount) / resolvedRate : 0,
            recordingStartTime: nil,
            events: [],
            data: data,
            channelNames: names
        )
    }

    private func ramp(_ count: Int, scale: Float = 1) -> [Float] {
        (0..<count).map { Float($0) * scale }
    }

    @Test func identicalSignalsCompareAsIdentical() throws {
        let data = [SyntheticSignal.sine(frequency: 10, samplingRate: samplingRate, count: 500)]
        let result = try SignalComparison.compare(signal(data), signal(data))

        #expect(result.isIdentical)
        #expect(result.overallRMSDifference == 0)
        #expect(result.alignedChannelCount == 1)
        #expect(result.truncatedSamples == 0)
    }

    @Test func differenceStatisticsDescribeTheChange() throws {
        let base = SyntheticSignal.sine(frequency: 10, samplingRate: samplingRate, count: 1000)
        // B is A with a constant 5 µV offset on the second channel only.
        let a = signal([base, base], names: ["E1", "E2"])
        let b = signal([base, base.map { $0 + 5 }], names: ["E1", "E2"])

        let result = try SignalComparison.compare(a, b)
        #expect(!result.isIdentical)
        // Sorted worst-first, so the changed channel leads.
        let worst = try #require(result.channels.first)
        #expect(worst.name == "E2")
        #expect(abs(worst.rmsDifference - 5) < 1e-4)
        #expect(abs(worst.maxAbsDifference - 5) < 1e-3)
        // A constant offset does not change the shape.
        #expect(abs((worst.correlation ?? 0) - 1) < 1e-6)

        let unchanged = try #require(result.channels.last)
        #expect(unchanged.name == "E1")
        #expect(unchanged.rmsDifference == 0)
    }

    /// The case that makes positional comparison dangerous: the same channel
    /// sits at a different row index in the two windows.
    @Test func channelsAreMatchedByNameNotPosition() throws {
        let flat = [Float](repeating: 1, count: 100)
        let ramped = ramp(100)
        let a = signal([flat, ramped], names: ["Cz", "Pz"])
        let b = signal([ramped, flat], names: ["Pz", "Cz"])

        let result = try SignalComparison.compare(a, b)
        #expect(result.alignedChannelCount == 2)
        // Matched correctly, the two windows hold the same data in a different
        // order — so nothing differs. Matching by position would have reported
        // a large difference on both channels.
        #expect(result.isIdentical)
        let cz = try #require(result.channels.first { $0.name == "Cz" })
        #expect(cz.indexA == 0)
        #expect(cz.indexB == 1)
    }

    @Test func unmatchedChannelsAreReportedRatherThanCompared() throws {
        let flat = [Float](repeating: 1, count: 100)
        let a = signal([flat, flat, flat], names: ["Cz", "Pz", "Oz"])
        let b = signal([flat, flat], names: ["Cz", "Fz"])

        let result = try SignalComparison.compare(a, b)
        #expect(result.alignedChannelCount == 1)
        #expect(result.unmatchedInA == ["Pz", "Oz"])
        #expect(result.unmatchedInB == ["Fz"])
        // The summary has to say so: "identical over one of three channels" is a
        // different claim from "identical".
        #expect(result.alignmentSummary.contains("3 unmatched"))
    }

    @Test func unnamedSignalsFallBackToPositionalMatching() throws {
        let a = signal([ramp(100), ramp(100, scale: 2)])
        let b = signal([ramp(100), ramp(100, scale: 2)])
        let result = try SignalComparison.compare(a, b)
        #expect(result.alignedChannelCount == 2)
        #expect(result.isIdentical)
    }

    @Test func differentLengthsAreTruncatedAndSaidSo() throws {
        let a = signal([ramp(500)], names: ["Cz"])
        let b = signal([ramp(400)], names: ["Cz"])

        let result = try SignalComparison.compare(a, b)
        #expect(result.comparedSampleCount == 400)
        #expect(result.truncatedSamples == 100)
        #expect(result.isIdentical, "the overlapping region is the same data")
    }

    @Test func aSamplingRateMismatchIsRefusedRatherThanResampled() {
        let a = signal([ramp(500)], names: ["Cz"])
        let b = signal([ramp(500)], names: ["Cz"], rate: 500)

        #expect(throws: SignalComparison.Failure.samplingRateMismatch(250, 500)) {
            try SignalComparison.compare(a, b)
        }
    }

    @Test func noSharedChannelNamesIsAFailureNotAnEmptyResult() {
        let flat = [Float](repeating: 1, count: 100)
        let a = signal([flat], names: ["Cz"])
        let b = signal([flat], names: ["Fp1"])

        #expect(throws: SignalComparison.Failure.noCommonChannels) {
            try SignalComparison.compare(a, b)
        }
    }

    /// A flat channel has no variance, so correlation is undefined — reporting 0
    /// there would read as "completely unrelated".
    @Test func correlationIsAbsentRatherThanZeroForAFlatChannel() throws {
        let flat = [Float](repeating: 3, count: 200)
        let result = try SignalComparison.compare(
            signal([flat], names: ["Cz"]),
            signal([flat.map { $0 + 1 }], names: ["Cz"])
        )
        let channel = try #require(result.channels.first)
        #expect(channel.correlation == nil)
        #expect(channel.relativeChange != nil)
        #expect(abs(channel.rmsDifference - 1) < 1e-6)
    }

    @Test func tracesDecimateToTheRequestedBudgetAndKeepTheirTimebase() throws {
        let a = signal([ramp(10_000)], names: ["Cz"])
        let b = signal([ramp(10_000, scale: 1.5)], names: ["Cz"])
        let result = try SignalComparison.compare(a, b)
        let channel = try #require(result.channels.first)

        let traces = SignalComparison.traces(a: a, b: b, difference: channel, maximumPoints: 500)
        #expect(traces.a.count <= 500)
        #expect(traces.a.count == traces.b.count)
        #expect(traces.difference.count == traces.a.count)
        #expect(traces.stride == 20)
        // The difference trace really is A − B, not a re-read of A.
        #expect(abs(traces.difference[1] - (traces.a[1] - traces.b[1])) < 1e-6)
    }
}
