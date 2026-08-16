//
//  RecordingCombinerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Testing
import Foundation
import simd
@testable import EVA

struct RecordingCombinerTests {

    private func namedSignal(_ data: [[Float]], samplingRate: Double, names: [String]? = nil) -> MFFSignalData {
        let base = SyntheticSignal.make(data, samplingRate: samplingRate)
        return MFFSignalData(
            signalURL: base.signalURL,
            signalType: base.signalType,
            numberOfChannels: base.numberOfChannels,
            samplingRate: base.samplingRate,
            duration: base.duration,
            recordingStartTime: base.recordingStartTime,
            events: base.events,
            data: base.data,
            channelNames: names ?? data.indices.map { "Ch\($0 + 1)" }
        )
    }

    /// A 2-channel continuous recording of `sampleCount` samples, filled with a
    /// per-channel constant `value` (so combined results are trivially checkable),
    /// with one "stim" category segment centered at `stimSample`.
    private func makeInput(
        url: URL,
        value: Float,
        sampleCount: Int,
        samplingRate: Double = 250,
        stimSample: Int = 50,
        pre: Int = 20,
        post: Int = 29,
        category: String = "stim",
        badChannels: Set<Int> = [],
        alreadyInterpolatedChannels: Set<Int> = [],
        geometry: ElectrodeGeometry? = nil
    ) -> CombineInput {
        let data: [[Float]] = [
            [Float](repeating: value, count: sampleCount),
            [Float](repeating: value * 2, count: sampleCount),
        ]
        let signal = namedSignal(data, samplingRate: samplingRate)
        let segment = EpochSegment(
            startSample: stimSample - pre,
            endSample: stimSample + post,
            stimulusOffsetSamples: pre,
            category: category,
            sourceCode: category,
            sourceTimeSeconds: Double(stimSample) / samplingRate,
            colorIndex: 0,
            contributingEpochCount: 1
        )
        return CombineInput(
            url: url,
            signal: signal,
            segments: [segment],
            badChannels: badChannels,
            alreadyInterpolatedChannels: alreadyInterpolatedChannels,
            geometry: geometry
        )
    }

    /// Like `makeInput`, but with `trialCount` identical same-category segments
    /// spread across the recording, so `byTrialCount` weighting has something to
    /// differentiate.
    private func makeMultiTrialInput(
        url: URL,
        value: Float,
        trialCount: Int,
        samplingRate: Double = 250,
        pre: Int = 20,
        post: Int = 29,
        category: String = "stim"
    ) -> CombineInput {
        let span = pre + post + 1
        let sampleCount = span * (trialCount + 1)
        let data: [[Float]] = [[Float](repeating: value, count: sampleCount)]
        let signal = namedSignal(data, samplingRate: samplingRate)
        let segments = (0..<trialCount).map { i -> EpochSegment in
            let stim = span * i + pre
            return EpochSegment(
                startSample: stim - pre,
                endSample: stim + post,
                stimulusOffsetSamples: pre,
                category: category,
                sourceCode: category,
                sourceTimeSeconds: Double(stim) / samplingRate,
                colorIndex: 0,
                contributingEpochCount: 1
            )
        }
        return CombineInput(url: url, signal: signal, segments: segments, badChannels: [], geometry: nil)
    }

    @Test func appendConcatenatesChannelsAndOffsetsSegments() throws {
        let a = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100)
        let b = makeInput(
            url: URL(fileURLWithPath: "/tmp/b.mff"), value: 3, sampleCount: 60,
            stimSample: 30
        )
        let log = EVAProcessLog()

        let (signal, segments) = try RecordingCombiner.append([a, b], log: log)

        #expect(signal.data.count == 2)
        #expect(signal.data[0].count == 160)
        // First file's samples come first, unchanged; second file's follow.
        #expect(signal.data[0][0] == 1)
        #expect(signal.data[0][99] == 1)
        #expect(signal.data[0][100] == 3)
        #expect(signal.data[0][159] == 3)

        #expect(segments.count == 2)
        // Second file's segment is shifted by the first file's sample count.
        #expect(segments[0].startSample == 30)
        #expect(segments[1].startSample == 10 + 100)
    }

    @Test func appendPreservesChannelValuesAcrossThreeFiles() throws {
        let inputs = [
            makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 40,
                      stimSample: 20, pre: 10, post: 9),
            makeInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 2, sampleCount: 40,
                      stimSample: 20, pre: 10, post: 9),
            makeInput(url: URL(fileURLWithPath: "/tmp/c.mff"), value: 3, sampleCount: 40,
                      stimSample: 20, pre: 10, post: 9),
        ]
        let (signal, segments) = try RecordingCombiner.append(inputs, log: EVAProcessLog())

        #expect(signal.data[0].count == 120)
        #expect(segments.count == 3)
        #expect(segments.map(\.startSample) == [10, 50, 90])
    }

    @Test func grandAverageCombinesEqualWeightFiles() throws {
        // Two files, same category, constant channel 0 values 1 and 3 -> average 2.
        let a = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100)
        let b = makeInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 3, sampleCount: 100)
        let log = EVAProcessLog()

        let result = try RecordingCombiner.grandAverage(
            [a, b],
            categoryMap: [:],
            weighting: .equalPerFile,
            badChannelPolicy: .interpolatePerFile,
            rebaseline: false,
            log: log
        )

        #expect(result.segments.count == 1)
        #expect(result.segments[0].category == "stim")
        #expect(result.segments[0].contributingEpochCount == 2)
        // Channel 0 is a constant field, so the averaged window should be ~2 everywhere.
        let window = result.segments[0]
        let channel0 = Array(result.signal.data[0][window.startSample...window.endSample])
        #expect(channel0.allSatisfy { abs($0 - 2) < 1e-4 })
        // Channel 1 was 2x channel 0's value per file -> average 4.
        let channel1 = Array(result.signal.data[1][window.startSample...window.endSample])
        #expect(channel1.allSatisfy { abs($0 - 4) < 1e-4 })
    }

    @Test func grandAverageAppliesCategoryRemapping() throws {
        let a = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100, category: "Target")
        let b = makeInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 3, sampleCount: 100, category: "target")

        let result = try RecordingCombiner.grandAverage(
            [a, b],
            categoryMap: [
                URL(fileURLWithPath: "/tmp/a.mff"): ["Target": "Combined"],
                URL(fileURLWithPath: "/tmp/b.mff"): ["target": "Combined"],
            ],
            weighting: .equalPerFile,
            badChannelPolicy: .interpolatePerFile,
            rebaseline: false,
            log: EVAProcessLog()
        )

        #expect(result.segments.count == 1)
        #expect(result.segments.first?.category == "Combined")
        #expect(result.segments.first?.contributingEpochCount == 2)
    }

    @Test func categoryMatcherKeepsShortEventCodesDistinct() {
        let a = URL(fileURLWithPath: "/tmp/run1.mff")
        let b = URL(fileURLWithPath: "/tmp/run2.mff")

        let result = CategoryMatcher.autoMap(rawCategoriesByFile: [
            a: ["LC++", "LI++", "RC++", "RI++"],
            b: ["LC++", "LI++", "RC++", "RI++"],
        ])

        #expect(result.map[a]?["LC++"] == "LC++")
        #expect(result.map[a]?["LI++"] == "LI++")
        #expect(result.map[a]?["RC++"] == "RC++")
        #expect(result.map[a]?["RI++"] == "RI++")
        #expect(Set((result.map[a] ?? [:]).values) == ["LC++", "LI++", "RC++", "RI++"])
        #expect(result.map[b] == result.map[a])
    }

    @Test func categoryMatcherStillMergesCaseAndSpacingVariants() {
        let a = URL(fileURLWithPath: "/tmp/run1.mff")
        let b = URL(fileURLWithPath: "/tmp/run2.mff")

        let result = CategoryMatcher.autoMap(rawCategoriesByFile: [
            a: ["Target"],
            b: ["target "],
        ])

        #expect(result.map[a]?["Target"] == "Target")
        #expect(result.map[b]?["target "] == "Target")
    }

    @Test func grandAverageByTrialCountWeightsLargerFileMore() throws {
        // File `a` contributes 1 trial at value 0, file `b` contributes 3 trials at
        // value 10. Equal-per-file weighting would average to 5; trial-count
        // weighting should pull the result toward b's value (7.5).
        let a = makeMultiTrialInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 0, trialCount: 1)
        let b = makeMultiTrialInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 10, trialCount: 3)

        let equalResult = try RecordingCombiner.grandAverage(
            [a, b], categoryMap: [:], weighting: .equalPerFile,
            badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
        )
        let trialWeightedResult = try RecordingCombiner.grandAverage(
            [a, b], categoryMap: [:], weighting: .byTrialCount,
            badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
        )

        func channel0Mean(_ result: RecordingCombiner.GrandAverageOutput) -> Float {
            guard let seg = result.segments.first else { return .nan }
            let window = Array(result.signal.data[0][seg.startSample...seg.endSample])
            return window.reduce(0, +) / Float(window.count)
        }

        let equalMean = channel0Mean(equalResult)
        let weightedMean = channel0Mean(trialWeightedResult)
        #expect(abs(equalMean - 5) < 1e-3)
        #expect(abs(weightedMean - 7.5) < 1e-3)
        #expect(weightedMean > equalMean)
    }

    @Test func grandAverageThrowsWithNoOverlappingCategories() {
        let input = CombineInput(
            url: URL(fileURLWithPath: "/tmp/empty.mff"),
            signal: namedSignal([[0, 0, 0]], samplingRate: 250),
            segments: [],
            badChannels: [],
            geometry: nil
        )
        #expect(throws: CombineError.self) {
            try RecordingCombiner.grandAverage(
                [input], categoryMap: [:], weighting: .equalPerFile,
                badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
            )
        }
    }

    @Test func compatibilityFlagsChannelSamplingRateAndEpochMismatch() {
        let reference = RecordingSummary(
            url: URL(fileURLWithPath: "/tmp/ref.mff"), fileName: "ref.mff", netName: "",
            channelCount: 128, samplingRate: 250, epochLengthSamples: 100,
            isAveraged: false, categories: [], hasProcessingRecord: false, snr: SNRMetrics()
        )
        let mismatched = RecordingSummary(
            url: URL(fileURLWithPath: "/tmp/other.mff"), fileName: "other.mff", netName: "",
            channelCount: 64, samplingRate: 500, epochLengthSamples: 80,
            isAveraged: false, categories: [], hasProcessingRecord: false, snr: SNRMetrics()
        )

        let flags = RecordingCombiner.compatibility(of: mismatched, reference: reference)
        #expect(flags.contains(.channelCountMismatch(64, expected: 128)))
        #expect(flags.contains(.samplingRateMismatch(500, expected: 250)))
        #expect(flags.contains(.epochLengthMismatch(80, expected: 100)))
    }

    @Test func compatibilityFlagsUnsegmentedFile() {
        let reference = RecordingSummary(
            url: URL(fileURLWithPath: "/tmp/ref.mff"), fileName: "ref.mff", netName: "",
            channelCount: 128, samplingRate: 250, epochLengthSamples: 100,
            isAveraged: false, categories: [], hasProcessingRecord: false, snr: SNRMetrics()
        )
        let notSegmented = RecordingSummary(
            url: URL(fileURLWithPath: "/tmp/cont.mff"), fileName: "cont.mff", netName: "",
            channelCount: 128, samplingRate: 250, epochLengthSamples: 0,
            isAveraged: false, categories: [], hasProcessingRecord: false, snr: SNRMetrics()
        )
        let flags = RecordingCombiner.compatibility(of: notSegmented, reference: reference)
        #expect(flags.contains(.notSegmented))
    }

    @Test func summarizeReportsCategoryTrialCounts() {
        let input = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100)
        let summary = RecordingCombiner.summarize(input)
        #expect(summary.channelCount == 2)
        #expect(summary.categories.count == 1)
        #expect(summary.categories[0].name == "stim")
        #expect(summary.categories[0].goodTrials == 1)
    }

    @Test func appendRemapsChannelsByNameAndRepairsMetadata() throws {
        let base = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100)
        let otherBase = makeInput(
            url: URL(fileURLWithPath: "/tmp/b.mff"), value: 10, sampleCount: 60,
            stimSample: 30
        )
        let swappedSignal = MFFSignalData(
            signalURL: otherBase.signal.signalURL,
            signalType: otherBase.signal.signalType,
            numberOfChannels: 2,
            samplingRate: 250,
            duration: 60.0 / 250.0,
            recordingStartTime: nil,
            events: [MFFEvent(id: "b", code: "B", beginTimeSeconds: 0.1, rawBeginTime: "0.1", sourceFile: "b")],
            data: [otherBase.signal.data[1], otherBase.signal.data[0]],
            channelNames: ["Ch2", "Ch1"]
        )
        let other = CombineInput(
            url: otherBase.url,
            signal: swappedSignal,
            segments: otherBase.segments,
            badChannels: [],
            geometry: nil
        )

        let result = try RecordingCombiner.append([base, other], log: EVAProcessLog())

        #expect(result.signal.data[0][100] == 10)
        #expect(result.signal.data[1][100] == 20)
        #expect(result.signal.duration == 160.0 / 250.0)
        #expect(result.signal.isSegmented)
        #expect(!result.signal.isAveraged)
        #expect(result.signal.events.first?.beginTimeSeconds == 0.5)
        #expect(result.signal.epochSegments.count == result.segments.count)
    }

    @Test func appendedTimelineMetadataSurvivesMFFRoundTrip() throws {
        func fullInput(_ name: String, values: [[Float]], eventCode: String) -> CombineInput {
            let base = namedSignal(values, samplingRate: 100, names: ["Fz", "Cz"])
            let event = MFFEvent(
                id: eventCode, code: eventCode, beginTimeSeconds: 0.01,
                rawBeginTime: "0.01", sourceFile: name
            )
            let signal = MFFSignalData(
                signalURL: base.signalURL, signalType: base.signalType,
                numberOfChannels: 2, samplingRate: 100, duration: 0.04,
                recordingStartTime: Date(timeIntervalSince1970: 1_700_000_000),
                events: [event], data: values, channelNames: ["Fz", "Cz"]
            )
            let segment = EpochSegment(
                startSample: 0, endSample: 3, stimulusOffsetSamples: 1,
                category: eventCode, sourceCode: eventCode, sourceTimeSeconds: 0.01,
                colorIndex: 0, contributingEpochCount: 1
            )
            return CombineInput(
                url: URL(fileURLWithPath: "/tmp/\(name).mff"), signal: signal,
                segments: [segment], badChannels: [], geometry: nil
            )
        }
        let inputA = fullInput("a", values: [[1, 2, 3, 4], [11, 12, 13, 14]], eventCode: "A")
        let inputB = fullInput("b", values: [[5, 6, 7, 8], [15, 16, 17, 18]], eventCode: "B")
        let appended = try RecordingCombiner.append([inputA, inputB], log: EVAProcessLog())
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-append-roundtrip-\(UUID().uuidString).mff")
        defer { try? FileManager.default.removeItem(at: package) }
        try MFFWriter.write(
            signal: appended.signal, segments: appended.segments, kind: .epoched, to: package
        )
        let readback = try MFFReader().loadSignal(from: package)

        #expect(readback.data == appended.signal.data)
        #expect(readback.channelNames == appended.signal.channelNames)
        #expect(readback.duration == appended.signal.duration)
        #expect(readback.events.count == appended.signal.events.count)
        #expect(readback.epochSegments.count == appended.signal.epochSegments.count)
        #expect(readback.isSegmented == appended.signal.isSegmented)
        #expect(readback.isAveraged == appended.signal.isAveraged)
    }

    @Test func combineRejectsMissingChannelIdentityAndRateMismatch() {
        let named = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100)
        let unnamedBase = SyntheticSignal.make([[1, 1], [2, 2]], samplingRate: 250)
        let unnamed = CombineInput(url: URL(fileURLWithPath: "/tmp/u.mff"), signal: unnamedBase,
                                   segments: named.segments, badChannels: [], geometry: nil)
        #expect(throws: CombineError.self) {
            try RecordingCombiner.append([named, unnamed], log: EVAProcessLog())
        }

        let differentRate = makeInput(url: URL(fileURLWithPath: "/tmp/r.mff"), value: 2,
                                      sampleCount: 100, samplingRate: 256)
        #expect(throws: CombineError.self) {
            try RecordingCombiner.append([named, differentRate], log: EVAProcessLog())
        }
    }

    @Test func excludePerChannelOmitsBadContributor() throws {
        let bad = makeInput(url: URL(fileURLWithPath: "/tmp/bad.mff"), value: 100,
                            sampleCount: 100, badChannels: [0])
        let good = makeInput(url: URL(fileURLWithPath: "/tmp/good.mff"), value: 2, sampleCount: 100)
        let result = try RecordingCombiner.grandAverage(
            [bad, good], categoryMap: [:], weighting: .equalPerFile,
            badChannelPolicy: .excludePerChannel, rebaseline: false, log: EVAProcessLog()
        )
        #expect(result.signal.data[0].allSatisfy { abs($0 - 2) < 1e-5 })
        #expect(result.signal.isAveraged)
        #expect(result.signal.isGrandAverage)
        #expect(result.signal.events.isEmpty)
    }

    @Test func interpolationPolicyFailsWithoutGeometryButSkipsAlreadyRepairedChannels() throws {
        let unresolved = makeInput(url: URL(fileURLWithPath: "/tmp/unresolved.mff"), value: 4,
                                   sampleCount: 100, badChannels: [0])
        let good = makeInput(url: URL(fileURLWithPath: "/tmp/good.mff"), value: 2, sampleCount: 100)
        #expect(throws: CombineError.self) {
            try RecordingCombiner.grandAverage(
                [unresolved, good], categoryMap: [:], weighting: .equalPerFile,
                badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
            )
        }

        let repaired = makeInput(
            url: URL(fileURLWithPath: "/tmp/repaired.mff"), value: 4, sampleCount: 100,
            badChannels: [0], alreadyInterpolatedChannels: [0]
        )
        _ = try RecordingCombiner.grandAverage(
            [repaired, good], categoryMap: [:], weighting: .equalPerFile,
            badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
        )
    }

    @Test func interpolationPolicyUsesTheSphericalSplineRecipe() throws {
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
        ]
        let geometry = ElectrodeGeometry(name: "test", positions: positions)
        let samples = [
            [Float](repeating: 999, count: 20),
            [Float](repeating: 2, count: 20),
            [Float](repeating: 4, count: 20),
            [Float](repeating: 8, count: 20),
        ]
        let signal = namedSignal(samples, samplingRate: 100)
        let segment = EpochSegment(
            startSample: 0, endSample: 19, stimulusOffsetSamples: 5,
            category: "stim", sourceCode: "stim", sourceTimeSeconds: 0.05,
            colorIndex: 0, contributingEpochCount: 1
        )
        func input(_ name: String) -> CombineInput {
            CombineInput(
                url: URL(fileURLWithPath: "/tmp/\(name).mff"), signal: signal,
                segments: [segment], badChannels: [0], geometry: geometry
            )
        }

        let recipe = try #require(SphericalSpline.interpolationWeights(
            target: 0, good: [1, 2, 3], positions: positions
        ))
        let expected = zip(recipe.indices, recipe.weights).reduce(0.0) {
            $0 + Double(samples[$1.0][0]) * $1.1
        }
        let result = try RecordingCombiner.grandAverage(
            [input("a"), input("b")], categoryMap: [:], weighting: .equalPerFile,
            badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
        )

        #expect(result.signal.data[0].allSatisfy { abs(Double($0) - expected) < 1e-5 })
        #expect(result.signal.data[0].allSatisfy { $0 != 999 })
    }

    @Test func interpolationPolicyRejectsInsufficientDonors() {
        let geometry = ElectrodeGeometry(name: "too-small", positions: [
            0: SIMD3(1, 0, 0), 1: SIMD3(0, 1, 0), 2: SIMD3(0, 0, 1),
        ])
        let signal = namedSignal([
            [Float](repeating: 99, count: 20),
            [Float](repeating: 1, count: 20),
            [Float](repeating: 2, count: 20),
        ], samplingRate: 100)
        let segment = EpochSegment(
            startSample: 0, endSample: 19, stimulusOffsetSamples: 5,
            category: "stim", sourceCode: "stim", sourceTimeSeconds: 0.05,
            colorIndex: 0, contributingEpochCount: 1
        )
        let input = CombineInput(
            url: URL(fileURLWithPath: "/tmp/few.mff"), signal: signal,
            segments: [segment], badChannels: [0], geometry: geometry
        )
        do {
            _ = try RecordingCombiner.grandAverage(
                [input], categoryMap: [:], weighting: .equalPerFile,
                badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
            )
            Issue.record("Expected interpolation to reject fewer than three donors")
        } catch let error as CombineError {
            #expect(error == .interpolationUnavailable(url: input.url, reason: .insufficientDonors([0])))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func duplicateChannelNamesAreUnresolved() {
        let referenceSignal = namedSignal([[1], [2]], samplingRate: 250, names: ["Cz", "Pz"])
        let duplicateSignal = namedSignal([[1], [2]], samplingRate: 250, names: ["Cz", "Cz"])
        let segment = EpochSegment(
            startSample: 0, endSample: 0, stimulusOffsetSamples: 0,
            category: "x", sourceCode: "x", sourceTimeSeconds: 0,
            colorIndex: 0, contributingEpochCount: 1
        )
        let reference = RecordingCombiner.summarize(CombineInput(
            url: URL(fileURLWithPath: "/tmp/ref.mff"), signal: referenceSignal,
            segments: [segment], badChannels: [], geometry: nil
        ))
        let duplicate = RecordingCombiner.summarize(CombineInput(
            url: URL(fileURLWithPath: "/tmp/dup.mff"), signal: duplicateSignal,
            segments: [segment], badChannels: [], geometry: nil
        ))

        #expect(RecordingCombiner.channelMapping(of: duplicate, reference: reference)
            == .unresolved(.duplicateNames(["Cz"])))
    }

    @Test func contributorBadChannelProvenanceMatchesActualPolicy() {
        let a = makeInput(
            url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100,
            badChannels: [0, 1], alreadyInterpolatedChannels: [1]
        )
        let b = makeInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 2, sampleCount: 100)

        let interpolation = RecordingCombiner.badChannelProvenanceSteps(
            for: [a, b], policy: .interpolatePerFile
        )
        #expect(interpolation.count == 2)
        #expect(interpolation[0].operation == .combineBadChannelPolicy)
        #expect(interpolation[0].parameters["channels"] == "1")
        #expect(interpolation[0].parameters["alreadyInterpolatedChannels"] == "2")
        #expect(interpolation[1].parameters["channels"] == "")
        #expect(interpolation.allSatisfy { !$0.replayable })

        let exclusion = RecordingCombiner.badChannelProvenanceSteps(
            for: [a], policy: .excludePerChannel
        )
        #expect(exclusion[0].parameters["channels"] == "1,2")
    }

    @Test func restoresFinalBadAndAlreadyInterpolatedChannelState() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-combine-state-\(UUID().uuidString).mff", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .markBad, parameters: ["channels": "1"]))
        script.append(EVAProcessingStep(operation: .markBad, parameters: ["channels": "2,4"]))
        script.append(EVAProcessingStep(
            operation: .interpolateChannels,
            parameters: ["channels": "3", "method": ChannelDecisionSteps.methodParameterValue]
        ))
        try EVAProcessingScriptXML.write(script, toPackage: package)

        let state = RecordingCombiner.restoredBadChannelState(fromPackage: package)
        #expect(state.bad == [1, 3])
        #expect(state.alreadyInterpolated == [2])
    }

    @Test func psaArtifactThresholdSnapshotReadsCompleteSavedSettings() throws {
        let snapshot = try #require(PSAArtifactThresholdSnapshot(parameters: [
            "interpolateBadChannelsPerEpoch": "true",
            "badChannel.minMicrovolts": "-150.0",
            "badChannel.maxMicrovolts": "150",
            "badChannel.maxSlopeMicrovoltsPerSample": "25",
            "badChannel.maxAccelerationMicrovoltsPerSample": "15",
            "badChannel.maxBadChannelFraction": "0.1",
            "badChannel.maxBadChannelCount": "13",
            "badChannel.usesAbsoluteBadChannelCount": "false",
            "badChannel.escalateToGlobal": "true",
            "badChannel.globalEscalationThresholdPercent": "50"
        ]))

        #expect(snapshot.isComplete)
        #expect(snapshot.minMicrovolts == -150)
        #expect(snapshot.maxBadChannelFraction == 0.1)
        #expect(snapshot.detail.contains("reject epoch > 10% bad channels"))
        #expect(snapshot.detail.contains("global escalation at 50% of epochs"))
    }

    @Test func psaArtifactThresholdComparisonUsesSemanticNumericValues() throws {
        let common: [String: String] = [
            "interpolateBadChannelsPerEpoch": "true",
            "badChannel.minMicrovolts": "-150",
            "badChannel.maxMicrovolts": "150",
            "badChannel.maxSlopeMicrovoltsPerSample": "25",
            "badChannel.maxAccelerationMicrovoltsPerSample": "15",
            "badChannel.maxBadChannelFraction": "0.10",
            "badChannel.maxBadChannelCount": "13",
            "badChannel.usesAbsoluteBadChannelCount": "false",
            "badChannel.escalateToGlobal": "true",
            "badChannel.globalEscalationThresholdPercent": "50"
        ]
        let reference = try #require(PSAArtifactThresholdSnapshot(parameters: common))
        var equivalent = common
        equivalent["badChannel.maxMicrovolts"] = "150.0"
        equivalent["badChannel.maxBadChannelCount"] = "99" // inactive in percentage mode
        let same = try #require(PSAArtifactThresholdSnapshot(parameters: equivalent))
        var changed = common
        changed["badChannel.maxAccelerationMicrovoltsPerSample"] = "20"
        changed["badChannel.maxBadChannelFraction"] = "0.15"
        let different = try #require(PSAArtifactThresholdSnapshot(parameters: changed))

        #expect(same.differingFields(from: reference).isEmpty)
        #expect(different.differingFields(from: reference) == [
            "maximum acceleration", "reject-epoch percentage"
        ])
    }

    @Test func psaArtifactThresholdSnapshotDoesNotInventMissingLegacyValues() throws {
        #expect(PSAArtifactThresholdSnapshot(parameters: ["average": "true"]) == nil)
        let partial = try #require(PSAArtifactThresholdSnapshot(parameters: [
            "interpolateBadChannelsPerEpoch": "true",
            "badChannel.minMicrovolts": "-150"
        ]))
        #expect(!partial.isComplete)
    }
}
