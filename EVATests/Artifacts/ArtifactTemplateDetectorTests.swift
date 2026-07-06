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

    /// Verifies `waveformStretchRange` actually does something: an artifact
    /// whose duration differs from the exemplar (simulating natural
    /// beat-to-beat/blink-to-blink duration variability) should be missed at
    /// stretch = 0 but recovered once the search is allowed to compress or
    /// stretch candidate windows before scoring — i.e. it picks whichever
    /// stretch factor *maximizes* the match score, rather than only ever
    /// testing the exemplar's exact width.
    @Test func stretchRecoversArtifactOfDifferentDuration() {
        let exemplarWidth = 50 // 0.2 s
        let stretchedWidth = 65 // +30% longer than the exemplar
        let exemplarPosition = 200
        let stretchedPosition = 1200

        var data: [[Float]] = (0..<4).map { c in
            var state = UInt64(c + 1) &* 6364136223846793005 &+ 1
            return (0..<count).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
            }
        }
        let exemplarShape = SyntheticSignal.bump(width: exemplarWidth)
        let stretchedShape = SyntheticSignal.bump(width: stretchedWidth)
        for c in 0..<4 {
            for k in 0..<exemplarWidth { data[c][exemplarPosition + k] += exemplarShape[k] }
            for k in 0..<stretchedWidth { data[c][stretchedPosition + k] += stretchedShape[k] }
        }
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
        let exemplarRange = exemplarPosition...(exemplarPosition + exemplarWidth - 1)

        var noStretch = config(exemplar: exemplarRange)
        noStretch.waveformStretchRange = 0
        let resultNoStretch = ArtifactTemplateDetector.detect(in: signal, configuration: noStretch)
        let foundStretchedNoStretch = resultNoStretch.selectedEvents.contains {
            abs($0.beginTimeSeconds - Double(stretchedPosition + stretchedWidth / 2) / samplingRate) < 0.05
        }

        var withStretch = config(exemplar: exemplarRange)
        withStretch.waveformStretchRange = 0.3
        let resultWithStretch = ArtifactTemplateDetector.detect(in: signal, configuration: withStretch)
        let stretchedEvent = resultWithStretch.selectedEvents.first {
            abs($0.beginTimeSeconds - Double(stretchedPosition + stretchedWidth / 2) / samplingRate) < 0.05
        }

        #expect(!foundStretchedNoStretch, "stretch=0 should not match a 30%-longer artifact at this threshold")
        #expect(stretchedEvent != nil, "stretch=0.3 should recover the 30%-longer artifact")

        // The recovered event's matched duration should reflect the wider
        // (stretched) window that scored best, not the exemplar's own width —
        // direct evidence the search picked the *maximizing* stretch factor,
        // not just the unstretched one.
        if let stretchedEvent, let duration = stretchedEvent.durationSeconds {
            let matchedSamples = duration * samplingRate
            #expect(matchedSamples > Double(exemplarWidth) * 1.1, "matched window (\(matchedSamples) samples) should be wider than the exemplar (\(exemplarWidth))")
        }
    }

    /// Reproduces the reported symptom: a single long, continuous artifact
    /// (e.g. a slow eye movement) is really several exemplar-width sub-segments
    /// stitched back-to-back, each independently scoring above threshold
    /// against the (shorter) exemplar. `.discard` keeps only the best of those
    /// and drops the rest (today's original behavior — reproducing "one long
    /// movement reported as several separate events"); `.extend` should span
    /// the whole run into one event covering close to the artifact's true
    /// duration instead.
    @Test func extendMergesOneLongArtifactIntoASingleEvent() {
        let repeats = 3
        let position = 800

        var data: [[Float]] = (0..<4).map { c in
            var state = UInt64(c + 1) &* 6364136223846793005 &+ 1
            return (0..<count).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
            }
        }
        let shape = SyntheticSignal.bump(width: width)
        for c in 0..<4 {
            for r in 0..<repeats {
                let start = position + r * width
                for k in 0..<width { data[c][start + k] += shape[k] }
            }
        }
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
        let exemplarRange = position...(position + width - 1)

        var discardConfig = config(exemplar: exemplarRange)
        discardConfig.mergeBehavior = .discard
        let discardResult = ArtifactTemplateDetector.detect(in: signal, configuration: discardConfig)

        var extendConfig = config(exemplar: exemplarRange)
        extendConfig.mergeBehavior = .extend
        let extendResult = ArtifactTemplateDetector.detect(in: signal, configuration: extendConfig)

        #expect(discardResult.selectedEvents.count >= 2, "discard should split the repeated run into multiple events, found \(discardResult.selectedEvents.count)")
        #expect(extendResult.selectedEvents.count == 1, "extend should collapse the run into a single event, found \(extendResult.selectedEvents.count)")

        if let event = extendResult.selectedEvents.first, let duration = event.durationSeconds {
            let matchedSamples = duration * samplingRate
            #expect(matchedSamples > Double(width) * 1.5, "extended event (\(matchedSamples) samples) should cover much more than one exemplar-width window (\(width))")
        }
    }

    /// Verifies the Continuous topography scan style: a long span where the
    /// same fixed cross-channel spatial *ratio* is sustained (only amplitude
    /// envelopes up and down, like a real eye movement) should be reported as
    /// ONE event whose measured duration reflects the true span — not chopped
    /// into several fixed-width windows the way Windowed scanning would.
    @Test func continuousScanReportsOneVariableDurationEvent() {
        let spatialShape: [Float] = [1.0, 0.6, -0.6, -1.0]
        let longWidth = 300 // 1.2 s
        let position = 800

        var data: [[Float]] = (0..<4).map { c in
            var state = UInt64(c + 1) &* 6364136223846793005 &+ 1
            return (0..<count).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
            }
        }
        // A smooth, always-positive envelope (no zero-crossings) times a fixed
        // spatial ratio across channels — the scalp map's *shape* stays
        // constant throughout, only its amplitude rises and falls, mirroring
        // how a real eye movement's topography stays fairly stable while its
        // amplitude ramps up then back down.
        let envelope = (0..<longWidth).map { i -> Float in
            let x = Double(i) / Double(longWidth - 1)
            return Float(sin(.pi * x)) * 60
        }
        for c in 0..<4 {
            for k in 0..<longWidth {
                data[c][position + k] += spatialShape[c] * envelope[k]
            }
        }
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)

        // Exemplar: a short window right at the envelope's peak, used to
        // derive the Peak-map reference — same as a user highlighting a
        // brief, clean snippet of the movement.
        let peakCenter = position + longWidth / 2
        let exemplarRange = (peakCenter - 10)...(peakCenter + 10)

        var continuousConfig = config(exemplar: exemplarRange)
        continuousConfig.topographyMode = .peak
        continuousConfig.topographyChannelIndices = [0, 1, 2, 3]
        continuousConfig.topographyScanStyle = .continuous
        continuousConfig.matchThreshold = 0.8
        continuousConfig.continuousMinDurationSeconds = 0.05
        continuousConfig.continuousSmoothingSeconds = 0.08
        continuousConfig.mergeWindowSeconds = 0.1

        let result = ArtifactTemplateDetector.detect(in: signal, configuration: continuousConfig)

        #expect(result.topographyEvents.count == 1, "continuous scan should report one event, found \(result.topographyEvents.count)")

        if let event = result.topographyEvents.first, let duration = event.durationSeconds {
            let matchedSamples = duration * samplingRate
            // Should cover a large fraction of the true 300-sample span, not a
            // small fixed window — the whole point of variable-duration output.
            #expect(matchedSamples > 100, "continuous event (\(matchedSamples) samples) should cover most of the 300-sample artifact, not a small fixed window")
        }
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
