//
//  ArtifactTemplateDetectorTests.swift
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

struct ArtifactTemplateDetectorTests {

    private let samplingRate = 250.0
    private let count = 2500
    private let width = 50 // 0.2 s

    private func config(exemplar: ClosedRange<Int>) -> ArtifactTemplateConfiguration {
        ArtifactTemplateConfiguration(
            name: "TestArtifact",
            eventCode: "TART",
            selectedChannelIndices: [0, 1, 2, 3],
            comparisonChannelIndices: [0, 1, 2, 3],
            exemplarRange: exemplar,
            matchThreshold: 0.8,
            windowSizeSeconds: Double(width) / samplingRate,
            downsampleRate: samplingRate,
            mergeWindowSeconds: 0.1,
            polarity: .same
        )
    }

    @Test func detectsRepeatedExemplarOccurrences() {
        let positions = [200, 700, 1200, 1700, 2200]
        let planted = SyntheticSignal.plantedBumps(
            channelCount: 4, count: count, positions: positions, width: width, samplingRate: samplingRate
        )
        let signal = SyntheticSignal.make(planted.data, samplingRate: samplingRate)

        let result = ArtifactTemplateDetector.detect(in: signal, configuration: config(exemplar: planted.exemplar))

        // The exemplar plus its identical copies should be found; allow the
        // detector to merge/miss edge cases but require it to catch most.
        #expect(result.selectedEvents.count >= 3, "found \(result.selectedEvents.count) of \(positions.count)")
    }

    @Test func flatSignalYieldsNoMatches() {
        // Pure low-amplitude noise, no planted artifact: exemplar window is just
        // noise and should not match elsewhere at a 0.8 threshold.
        let planted = SyntheticSignal.plantedBumps(
            channelCount: 4, count: count, positions: [], width: width, samplingRate: samplingRate
        )
        let signal = SyntheticSignal.make(planted.data, samplingRate: samplingRate)
        let result = ArtifactTemplateDetector.detect(in: signal, configuration: config(exemplar: 200...(200 + width - 1)))
        // At most a small number of spurious matches; certainly not a structured set.
        #expect(result.selectedEvents.count <= 2)
    }

    @Test func emptySignalYieldsEmptyResult() {
        let empty = SyntheticSignal.make([], samplingRate: samplingRate)
        let result = ArtifactTemplateDetector.detect(in: empty, configuration: config(exemplar: 0...10))
        #expect(result.selectedEvents.isEmpty)
    }

    // MARK: - Trajectory (map sequence) frame exclusion

    /// A rotating 4-channel spatial pattern, distinct per frame `t`, so every
    /// frame contributes independent information to trajectory scoring.
    private func trajectoryFramePattern(t: Int, channelCount: Int = 4) -> [Float] {
        (0..<channelCount).map { c in
            Float(50 * sin(2 * .pi * Double(c) / Double(channelCount) + Double(t) * 0.3))
        }
    }

    private let trajectorySamplingRate = 100.0

    private func trajectoryConfig(
        exemplar: ClosedRange<Int>,
        excludedFrames: Set<Int> = []
    ) -> ArtifactTemplateConfiguration {
        ArtifactTemplateConfiguration(
            name: "TrajectoryTest",
            eventCode: "TRAJ",
            selectedChannelIndices: [0, 1, 2, 3],
            comparisonChannelIndices: [0, 1, 2, 3],
            exemplarRange: exemplar,
            matchThreshold: 0.85,
            windowSizeSeconds: 10 / trajectorySamplingRate,
            downsampleRate: trajectorySamplingRate,
            mergeWindowSeconds: 0.1,
            polarity: .same,
            topographyMode: .trajectory,
            trajectoryShiftSeconds: 0,
            trajectoryScaleRange: 0,
            trajectoryGFPWeighted: false,
            trajectoryExcludedDisplayFrameIndices: excludedFrames
        )
    }

    /// Builds a 4-channel, 400-sample (@ 100 Hz) recording: a clean 10-frame
    /// reference trajectory at samples 50–59, flat elsewhere, and a second copy
    /// at samples 200–209 with frame index 5 sign-flipped (perfectly anti-
    /// correlated) so its mean spatial-correlation score dips just below
    /// threshold — until that one frame is excluded from scoring.
    private func trajectorySignal() -> MFFSignalData {
        let sr = trajectorySamplingRate
        let total = 400
        var data = [[Float]](repeating: [Float](repeating: 0, count: total), count: 4)
        for t in 0..<10 {
            let clean = trajectoryFramePattern(t: t)
            for c in 0..<4 {
                data[c][50 + t] = clean[c]
                data[c][200 + t] = t == 5 ? -clean[c] : clean[c]
            }
        }
        return SyntheticSignal.make(data, samplingRate: sr)
    }

    @Test func trajectoryCorruptedFrameDropsScoreBelowThreshold() {
        let signal = trajectorySignal()
        let (events, _) = ArtifactTemplateDetector.detectTopography(
            in: signal,
            configuration: trajectoryConfig(exemplar: 50...59)
        )
        let corruptedMatch = events.contains { abs($0.beginTimeSeconds * 100 - 205) < 6 }
        #expect(!corruptedMatch, "corrupted-frame copy should score below threshold without exclusion")
    }

    @Test func excludingCorruptedFrameRestoresMatch() {
        let signal = trajectorySignal()
        let (events, reference) = ArtifactTemplateDetector.detectTopography(
            in: signal,
            configuration: trajectoryConfig(exemplar: 50...59, excludedFrames: [5])
        )
        #expect(reference?.trajectoryFrameCount == 10)
        let corruptedMatch = events.contains { abs($0.beginTimeSeconds * 100 - 205) < 6 }
        #expect(corruptedMatch, "excluding the corrupted frame should let the rest of the sequence match")
    }
}
