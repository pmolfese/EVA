//
//  SegmentHealthAnalyzerTests.swift
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
@testable import EVA

struct SegmentHealthAnalyzerTests {

    private let samplingRate = 250.0
    private let count = 5000 // 20 s

    private func cleanChannel(seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1
            let noise = (Double(state >> 33) / Double(UInt32.max) - 0.5) * 4
            return Float(20 * sin(2 * .pi * 10 * Double(i) / samplingRate) + noise)
        }
    }

    @Test func continuousSegmentationCoversWholeRecording() {
        let signal = SyntheticSignal.make([cleanChannel(seed: 1)], samplingRate: samplingRate)
        let segments = SegmentHealthAnalyzer.analysisSegments(for: signal, epochSegments: [])
        #expect(!segments.isEmpty)
        // First segment starts at 0; segments tile contiguously.
        #expect(segments.first?.startSample == 0)
        #expect(segments.last?.endSample == count - 1)
        #expect(segments.allSatisfy { $0.category == "Continuous" })
    }

    @Test func averagedCategoriesAreNeverEligibleForSegmentHealth() {
        let data = [cleanChannel(seed: 1)]
        let averagedSegment = EpochSegment(
            startSample: 0,
            endSample: count - 1,
            stimulusOffsetSamples: 50,
            category: "Target",
            sourceCode: "Target",
            sourceTimeSeconds: 0,
            colorIndex: 0,
            contributingEpochCount: 24
        )
        let signal = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/average.mff/signal1.bin"),
            signalType: "EEG",
            numberOfChannels: data.count,
            samplingRate: samplingRate,
            duration: Double(count) / samplingRate,
            recordingStartTime: nil,
            events: [],
            data: data,
            epochSegments: [averagedSegment],
            isSegmented: true,
            isAveraged: true
        )

        #expect(SegmentHealthAnalyzer.analysisSegments(
            for: signal,
            epochSegments: [averagedSegment]
        ).isEmpty)
        let forcedInput = SegmentHealthInputSegment(
            segmentID: "forced-average",
            segmentIndex: 0,
            category: averagedSegment.category,
            startSample: averagedSegment.startSample,
            endSample: averagedSegment.endSample,
            stimulusOffsetSamples: averagedSegment.stimulusOffsetSamples,
            sourceCode: averagedSegment.sourceCode,
            sourceTimeSeconds: averagedSegment.sourceTimeSeconds,
            contributingEpochCount: averagedSegment.contributingEpochCount
        )
        #expect(SegmentHealthAnalyzer.analyze(
            signal: signal,
            segments: [forcedInput],
            excludedChannelIndices: []
        ).results.isEmpty)
    }

    @Test func segmentWithInjectedArtifactGradesWorse() {
        var channels = (1...4).map { cleanChannel(seed: UInt64($0)) }

        // Corrupt the second 2-second window (samples 500..<1000) with a huge
        // transient across all channels.
        let badStart = 500, badEnd = 1000
        for c in channels.indices {
            for t in badStart..<badEnd {
                channels[c][t] += 4000
            }
        }

        let signal = SyntheticSignal.make(channels, samplingRate: samplingRate)
        let segments = SegmentHealthAnalyzer.analysisSegments(for: signal, epochSegments: [])
        let analysis = SegmentHealthAnalyzer.analyze(
            signal: signal,
            segments: segments,
            excludedChannelIndices: []
        )

        #expect(analysis.results.count == segments.count)

        // The segment overlapping the corruption must score worse than a clean
        // segment late in the recording.
        let badResult = try! #require(analysis.results.first { $0.startSample <= badStart && $0.endSample >= badStart })
        let cleanResult = try! #require(analysis.results.last)
        #expect(badResult.goodPercentage < cleanResult.goodPercentage)
    }

    @Test func emptySegmentsYieldNoResults() {
        let signal = SyntheticSignal.make([cleanChannel(seed: 1)], samplingRate: samplingRate)
        let analysis = SegmentHealthAnalyzer.analyze(signal: signal, segments: [], excludedChannelIndices: [])
        #expect(analysis.results.isEmpty)
    }

    @Test func labeledArtifactMetricIsBinaryForAnyOverlap() {
        let signal = SyntheticSignal.make([cleanChannel(seed: 1)], samplingRate: samplingRate)
        let segment = try! #require(SegmentHealthAnalyzer.analysisSegments(for: signal, epochSegments: []).first)

        let cleanAnalysis = SegmentHealthAnalyzer.analyze(
            signal: signal,
            segments: [segment],
            excludedChannelIndices: []
        )
        let cleanMetric = try! #require(cleanAnalysis.results.first?.metrics.first { $0.name == "Labeled Artifacts" })
        #expect(cleanMetric.score == 1)

        let pointArtifact = SegmentHealthArtifactInterval(
            artifactID: "manual-artifact",
            code: "Artifact",
            startSample: segment.startSample,
            endSample: segment.startSample,
            sourceFile: "Manual"
        )
        let artifactAnalysis = SegmentHealthAnalyzer.analyze(
            signal: signal,
            segments: [segment],
            excludedChannelIndices: [],
            artifactIntervals: [pointArtifact]
        )
        let artifactMetric = try! #require(artifactAnalysis.results.first?.metrics.first { $0.name == "Labeled Artifacts" })
        #expect(artifactMetric.score == 0)
    }
}
