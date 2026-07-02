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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct RecordingCombinerTests {

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
        badChannels: Set<Int> = []
    ) -> CombineInput {
        let data: [[Float]] = [
            [Float](repeating: value, count: sampleCount),
            [Float](repeating: value * 2, count: sampleCount),
        ]
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
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
        return CombineInput(url: url, signal: signal, segments: [segment], badChannels: badChannels, geometry: nil)
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
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
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

    @Test func appendConcatenatesChannelsAndOffsetsSegments() {
        let a = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100)
        let b = makeInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 3, sampleCount: 60)
        let log = EVAProcessLog()

        let (signal, segments) = RecordingCombiner.append([a, b], log: log)

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
        #expect(segments[1].startSample == 30 + 100)
    }

    @Test func appendPreservesChannelValuesAcrossThreeFiles() {
        let inputs = [
            makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 40),
            makeInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 2, sampleCount: 40),
            makeInput(url: URL(fileURLWithPath: "/tmp/c.mff"), value: 3, sampleCount: 40),
        ]
        let (signal, segments) = RecordingCombiner.append(inputs, log: EVAProcessLog())

        #expect(signal.data[0].count == 120)
        #expect(segments.count == 3)
        #expect(segments.map(\.startSample) == [30, 70, 110])
    }

    @Test func grandAverageCombinesEqualWeightFiles() {
        // Two files, same category, constant channel 0 values 1 and 3 -> average 2.
        let a = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100)
        let b = makeInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 3, sampleCount: 100)
        let log = EVAProcessLog()

        let result = RecordingCombiner.grandAverage(
            [a, b],
            categoryMap: [:],
            weighting: .equalPerFile,
            badChannelPolicy: .interpolatePerFile,
            rebaseline: false,
            log: log
        )

        #expect(result != nil)
        guard let result else { return }
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

    @Test func grandAverageAppliesCategoryRemapping() {
        let a = makeInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 1, sampleCount: 100, category: "Target")
        let b = makeInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 3, sampleCount: 100, category: "target")

        let result = RecordingCombiner.grandAverage(
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

        #expect(result?.segments.count == 1)
        #expect(result?.segments.first?.category == "Combined")
        #expect(result?.segments.first?.contributingEpochCount == 2)
    }

    @Test func grandAverageByTrialCountWeightsLargerFileMore() {
        // File `a` contributes 1 trial at value 0, file `b` contributes 3 trials at
        // value 10. Equal-per-file weighting would average to 5; trial-count
        // weighting should pull the result toward b's value (7.5).
        let a = makeMultiTrialInput(url: URL(fileURLWithPath: "/tmp/a.mff"), value: 0, trialCount: 1)
        let b = makeMultiTrialInput(url: URL(fileURLWithPath: "/tmp/b.mff"), value: 10, trialCount: 3)

        let equalResult = RecordingCombiner.grandAverage(
            [a, b], categoryMap: [:], weighting: .equalPerFile,
            badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
        )
        let trialWeightedResult = RecordingCombiner.grandAverage(
            [a, b], categoryMap: [:], weighting: .byTrialCount,
            badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
        )

        func channel0Mean(_ result: RecordingCombiner.GrandAverageOutput?) -> Float {
            guard let seg = result?.segments.first else { return .nan }
            let window = Array(result!.signal.data[0][seg.startSample...seg.endSample])
            return window.reduce(0, +) / Float(window.count)
        }

        let equalMean = channel0Mean(equalResult)
        let weightedMean = channel0Mean(trialWeightedResult)
        #expect(abs(equalMean - 5) < 1e-3)
        #expect(abs(weightedMean - 7.5) < 1e-3)
        #expect(weightedMean > equalMean)
    }

    @Test func grandAverageReturnsNilWithNoOverlappingCategories() {
        let input = CombineInput(
            url: URL(fileURLWithPath: "/tmp/empty.mff"),
            signal: SyntheticSignal.make([[0, 0, 0]], samplingRate: 250),
            segments: [],
            badChannels: [],
            geometry: nil
        )
        let result = RecordingCombiner.grandAverage(
            [input], categoryMap: [:], weighting: .equalPerFile,
            badChannelPolicy: .interpolatePerFile, rebaseline: false, log: EVAProcessLog()
        )
        #expect(result == nil)
    }

    @Test func compatibilityFlagsChannelAndSamplingRateMismatch() {
        let reference = RecordingSummary(
            url: URL(fileURLWithPath: "/tmp/ref.mff"), fileName: "ref.mff", netName: "",
            channelCount: 128, samplingRate: 250, epochLengthSamples: 100,
            isAveraged: false, categories: [], hasProcessingRecord: false, snr: SNRMetrics()
        )
        let mismatched = RecordingSummary(
            url: URL(fileURLWithPath: "/tmp/other.mff"), fileName: "other.mff", netName: "",
            channelCount: 64, samplingRate: 500, epochLengthSamples: 100,
            isAveraged: false, categories: [], hasProcessingRecord: false, snr: SNRMetrics()
        )

        let flags = RecordingCombiner.compatibility(of: mismatched, reference: reference)
        #expect(flags.contains(.channelCountMismatch(64, expected: 128)))
        #expect(flags.contains(.samplingRateMismatch(500, expected: 250)))
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
}
