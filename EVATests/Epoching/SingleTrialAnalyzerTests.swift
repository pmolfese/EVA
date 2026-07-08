//
//  SingleTrialAnalyzerTests.swift
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

struct SingleTrialAnalyzerTests {

    // 1 ms per sample: stimulus onset at sample 200 (200 ms baseline),
    // 400-sample series spans -200...+199 ms.
    private let samplingRate = 1000.0
    private let stimulusOffsetSamples = 200
    private let seriesLength = 400
    private let windowStartMs = 0.0
    private let windowEndMs = 100.0 // samples 200...300

    private func series(positive: (sample: Int, value: Float)?, negative: (sample: Int, value: Float)?) -> [Float] {
        var samples = [Float](repeating: 0, count: seriesLength)
        if let positive { samples[positive.sample] = positive.value }
        if let negative { samples[negative.sample] = negative.value }
        return samples
    }

    @Test func computesMeanAndPeaksForSingleTrial() throws {
        let average = series(positive: (250, 10), negative: (280, -8))
        let trial = SingleTrialAnalyzer.TrialInput(
            sourceTimeSeconds: 0,
            stimulusOffsetSamples: stimulusOffsetSamples,
            samples: series(positive: (250, 12), negative: (280, -5))
        )

        let result = try #require(SingleTrialAnalyzer.analyze(
            averageSamples: average,
            averageStimulusOffsetSamples: stimulusOffsetSamples,
            samplingRate: samplingRate,
            trials: [trial],
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            adaptiveHalfWidthMs: 5,
            splitCount: 2,
            outlierThresholdSD: 3,
            distributionChunkCount: 1
        ))

        #expect(abs((result.averagePeakLatencyPositiveMs ?? -1) - 50) < 1e-6)
        #expect(abs((result.averagePeakLatencyNegativeMs ?? -1) - 80) < 1e-6)

        let row = try #require(result.trials.first)
        // Window is samples 200...300 inclusive (101 samples); only 250 (12) and 280 (-5) are non-zero.
        #expect(abs(row.meanAmplitude - (12.0 - 5.0) / 101.0) < 1e-9)
        #expect(abs(row.peakAmplitudeAtAverageLatencyPositive - 12) < 1e-9)
        #expect(abs(row.peakAmplitudeAtAverageLatencyNegative - (-5)) < 1e-9)
        #expect(abs(row.peakAmplitudeOwnLatencyPositive - 12) < 1e-9)
        #expect(abs(row.peakLatencyOwnPositiveMs - 50) < 1e-6)
        #expect(abs(row.peakAmplitudeOwnLatencyNegative - (-5)) < 1e-9)
        #expect(abs(row.peakLatencyOwnNegativeMs - 80) < 1e-6)
        // Adaptive window: ±5 ms (11 samples) centered on the average's peak sample.
        #expect(abs(row.adaptiveMeanAmplitudePositive - 12.0 / 11.0) < 1e-9)
        #expect(abs(row.adaptiveMeanAmplitudeNegative - (-5.0 / 11.0)) < 1e-9)
        #expect(abs(row.peakToPeakAmplitude - 17) < 1e-9)
    }

    @Test func ownLatencyDiffersFromAverageLockedLatency() throws {
        let average = series(positive: (250, 10), negative: nil)
        // This trial's own biggest positive value is at sample 260, not 250 —
        // "own latency" should find 260, while the average-locked reading
        // still samples exactly at 250.
        var samples = [Float](repeating: 0, count: seriesLength)
        samples[250] = 3
        samples[260] = 9
        let trial = SingleTrialAnalyzer.TrialInput(
            sourceTimeSeconds: 0, stimulusOffsetSamples: stimulusOffsetSamples, samples: samples
        )

        let result = try #require(SingleTrialAnalyzer.analyze(
            averageSamples: average,
            averageStimulusOffsetSamples: stimulusOffsetSamples,
            samplingRate: samplingRate,
            trials: [trial],
            windowStartMs: windowStartMs, windowEndMs: windowEndMs,
            adaptiveHalfWidthMs: 5, splitCount: 1, outlierThresholdSD: 3, distributionChunkCount: 1
        ))
        let row = try #require(result.trials.first)

        #expect(abs(row.peakAmplitudeAtAverageLatencyPositive - 3) < 1e-9)
        #expect(abs(row.peakAmplitudeOwnLatencyPositive - 9) < 1e-9)
        #expect(abs(row.peakLatencyOwnPositiveMs - 60) < 1e-6)
    }

    @Test func flagsStatisticalOutlier() throws {
        let average = series(positive: (250, 1), negative: nil)
        // Four trials with a near-identical flat window, one clear outlier.
        func flatTrial(level: Float) -> SingleTrialAnalyzer.TrialInput {
            SingleTrialAnalyzer.TrialInput(
                sourceTimeSeconds: 0, stimulusOffsetSamples: stimulusOffsetSamples,
                samples: [Float](repeating: level, count: seriesLength)
            )
        }
        let trials = [flatTrial(level: 1.0), flatTrial(level: 1.0), flatTrial(level: 1.0), flatTrial(level: 50.0)]

        let result = try #require(SingleTrialAnalyzer.analyze(
            averageSamples: average, averageStimulusOffsetSamples: stimulusOffsetSamples,
            samplingRate: samplingRate, trials: trials,
            windowStartMs: windowStartMs, windowEndMs: windowEndMs,
            adaptiveHalfWidthMs: 5, splitCount: 1, outlierThresholdSD: 1.0, distributionChunkCount: 1
        ))

        #expect(result.trials.count == 4)
        #expect(result.trials[0].isOutlier == false)
        #expect(result.trials[1].isOutlier == false)
        #expect(result.trials[2].isOutlier == false)
        #expect(result.trials[3].isOutlier == true)
    }

    @Test func splitGroupsDivideChronologicallyInHalves() throws {
        let average = series(positive: (250, 1), negative: nil)
        func trial(at time: Double) -> SingleTrialAnalyzer.TrialInput {
            SingleTrialAnalyzer.TrialInput(
                sourceTimeSeconds: time, stimulusOffsetSamples: stimulusOffsetSamples,
                samples: [Float](repeating: 1, count: seriesLength)
            )
        }
        let trials = [trial(at: 0), trial(at: 1), trial(at: 2), trial(at: 3)]

        let result = try #require(SingleTrialAnalyzer.analyze(
            averageSamples: average, averageStimulusOffsetSamples: stimulusOffsetSamples,
            samplingRate: samplingRate, trials: trials,
            windowStartMs: windowStartMs, windowEndMs: windowEndMs,
            adaptiveHalfWidthMs: 5, splitCount: 2, outlierThresholdSD: 3, distributionChunkCount: 1
        ))

        #expect(result.splitGroups.count == 2)
        #expect(result.splitGroups[0].label == "First Half")
        #expect(result.splitGroups[0].trialCount == 2)
        #expect(result.splitGroups[1].label == "Last Half")
        #expect(result.splitGroups[1].trialCount == 2)
    }

    @Test func distributionBucketsTrialsByTimeChunk() throws {
        let average = series(positive: (250, 1), negative: nil)
        func trial(at time: Double) -> SingleTrialAnalyzer.TrialInput {
            SingleTrialAnalyzer.TrialInput(
                sourceTimeSeconds: time, stimulusOffsetSamples: stimulusOffsetSamples,
                samples: [Float](repeating: 1, count: seriesLength)
            )
        }
        let trials = [trial(at: 0), trial(at: 10), trial(at: 20), trial(at: 30)]

        let result = try #require(SingleTrialAnalyzer.analyze(
            averageSamples: average, averageStimulusOffsetSamples: stimulusOffsetSamples,
            samplingRate: samplingRate, trials: trials,
            windowStartMs: windowStartMs, windowEndMs: windowEndMs,
            adaptiveHalfWidthMs: 5, splitCount: 1, outlierThresholdSD: 3, distributionChunkCount: 2
        ))

        #expect(result.distribution.count == 2)
        #expect(result.distribution[0].retainedTrialCount == 2)
        #expect(result.distribution[1].retainedTrialCount == 2)
    }

    @Test func returnsNilForEmptyTrialsOrInvalidWindow() {
        let average = series(positive: (250, 1), negative: nil)
        let noTrials = SingleTrialAnalyzer.analyze(
            averageSamples: average, averageStimulusOffsetSamples: stimulusOffsetSamples,
            samplingRate: samplingRate, trials: [],
            windowStartMs: windowStartMs, windowEndMs: windowEndMs,
            adaptiveHalfWidthMs: 5, splitCount: 1, outlierThresholdSD: 3, distributionChunkCount: 1
        )
        #expect(noTrials == nil)

        let trial = SingleTrialAnalyzer.TrialInput(
            sourceTimeSeconds: 0, stimulusOffsetSamples: stimulusOffsetSamples,
            samples: [Float](repeating: 1, count: seriesLength)
        )
        let invalidWindow = SingleTrialAnalyzer.analyze(
            averageSamples: average, averageStimulusOffsetSamples: stimulusOffsetSamples,
            samplingRate: samplingRate, trials: [trial],
            windowStartMs: 100, windowEndMs: 50,
            adaptiveHalfWidthMs: 5, splitCount: 1, outlierThresholdSD: 3, distributionChunkCount: 1
        )
        #expect(invalidWindow == nil)
    }
}
