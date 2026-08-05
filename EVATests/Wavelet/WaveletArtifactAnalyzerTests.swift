//
//  WaveletArtifactAnalyzerTests.swift
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

struct WaveletArtifactAnalyzerTests {

    private let samplingRate = 250.0
    private let count = 2500
    private let width = 50

    private func config(exemplar: ClosedRange<Int>) -> WaveletArtifactConfiguration {
        WaveletArtifactConfiguration(
            name: "TestArtifact",
            eventCode: "WART",
            selectedChannelIndices: [0, 1, 2, 3],
            topographyChannelIndices: [],
            exemplarRange: exemplar,
            matchThreshold: 0.8,
            windowSizeSeconds: Double(width) / samplingRate,
            downsampleRate: samplingRate,
            mergeWindowSeconds: 0.1,
            polarity: .same,
            scansWaveform: true,
            scansTopography: false,
            levelCount: 5,
            thresholdScale: 1,
            topographyMetric: .pearson
        )
    }

    @Test func detectsRepeatedWaveformExemplar() {
        let positions = [200, 700, 1200, 1700, 2200]
        let planted = SyntheticSignal.plantedBumps(
            channelCount: 4, count: count, positions: positions, width: width, samplingRate: samplingRate
        )
        let signal = SyntheticSignal.make(planted.data, samplingRate: samplingRate)

        let result = WaveletArtifactAnalyzer.detect(in: signal, configuration: config(exemplar: planted.exemplar))
        #expect(result.hasWaveformMatches)
        #expect(result.waveformEvents.count >= 3, "found \(result.waveformEvents.count)")
    }

    @Test func emptySignalYieldsNoMatches() {
        let empty = SyntheticSignal.make([], samplingRate: samplingRate)
        let result = WaveletArtifactAnalyzer.detect(in: empty, configuration: config(exemplar: 0...10))
        #expect(result.waveformEvents.isEmpty)
        #expect(result.topographyEvents.isEmpty)
    }

    /// Regression for a real bug: `downsampleAndDemean` subtracts one global
    /// mean, and the old edge-clamped a-trous smoothing couldn't track any
    /// remaining slow trend out to the boundaries, so a channel with nothing
    /// but a gentle linear drift (no real artifact at all) got spuriously
    /// flagged right at the start and end of the recording — which is what
    /// "explorer candidates always cluster at the end" turned out to be.
    @Test func driftingBaselineDoesNotFlagRecordingBoundaries() {
        let sr = 250.0
        let n = 60_000
        var data: [[Float]] = []
        for c in 0..<8 {
            var state = UInt64(c + 1) &* 6364136223846793005 &+ 1
            let channel = (0..<n).map { i -> Float in
                state = state &* 6364136223846793005 &+ 1
                let noise = Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
                let drift = Float(Double(i) / Double(n)) * 40 // gentle linear drift, no discrete artifact
                return noise + drift
            }
            data.append(channel)
        }
        let signal = SyntheticSignal.make(data, samplingRate: sr)
        let configuration = WaveletArtifactExplorerConfiguration(
            channelIndices: Array(0..<8), downsampleRate: 250, levelCount: 8, thresholdScale: 1,
            cleaningMode: .conservativeLocal, intensity: 1, waveletFamily: .bior44,
            thresholdRule: .hard, thresholdModel: .bayesShrink,
            mergeWindowSeconds: 0.1, minimumDurationSeconds: 0.02, maximumCandidates: 40
        )
        let result = WaveletArtifactAnalyzer.explore(in: signal, configuration: configuration)
        let duration = Double(n) / sr

        for candidate in result.candidates {
            let fraction = candidate.peakTimeSeconds / duration
            #expect(fraction > 0.02 && fraction < 0.98, "boundary-clustered candidate at fraction \(fraction)")
        }
    }
}
