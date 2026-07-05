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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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
}
