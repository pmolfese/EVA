//
//  FastrCorrectorTests.swift
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
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct FastrCorrectorTests {

    // Build a synthetic EEG channel: small physiological signal + a large
    // repeating gradient artifact locked to evenly-spaced volume triggers.
    private func makeSyntheticChannel(spacing: Int, volumes: Int)
        -> (channel: [Float], triggers: [Int]) {
        let sampleCount = spacing * volumes
        func gradient(_ k: Int) -> Float { 80 * Float(sin(Double(k) * 0.4)) + 40 * Float(k % 11) }
        func physio(_ t: Int) -> Float { 6 * Float(sin(2 * .pi * 4 * Double(t) / 250)) }
        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount { channel[t] = physio(t) + gradient(t % spacing) }
        let triggers = (0..<volumes).map { $0 * spacing }
        return (channel, triggers)
    }

    @Test func reducesGradientArtifactPower() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)

        var config = FastrCorrector.Config()
        config.upsampleFactor = 2     // keep test fast
        config.numberOfSlices = 1
        config.averagingWindow = 20
        config.subSampleAlignment = false
        config.obs = .off
        config.anc = false

        let result = try FastrCorrector.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result.count == 1)
        #expect(result[0].count == channel.count)

        // Variance in the interior should drop substantially after correction.
        func variance(_ x: ArraySlice<Float>) -> Double {
            let arr = Array(x).map(Double.init)
            let m = arr.reduce(0, +) / Double(arr.count)
            return arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(arr.count)
        }
        let lo = spacing * 4
        let hi = channel.count - spacing * 4
        let before = variance(channel[lo..<hi])
        let after = variance(result[0][lo..<hi])
        #expect(after < before * 0.5)
    }

    @Test func tooFewTriggersThrows() {
        let config = FastrCorrector.Config()
        #expect(throws: (any Error).self) {
            _ = try FastrCorrector.correct(
                channels: [[0, 1, 2, 3]],
                volumeTriggers: [0],
                config: config,
                samplingRate: 250
            )
        }
    }

    @Test func preservesChannelCountAndLength() throws {
        let spacing = 100
        let volumes = 30
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.obs = .off

        let result = try FastrCorrector.correct(
            channels: [channel, channel, channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result.count == 3)
        for c in result { #expect(c.count == channel.count) }
    }

    @Test func excludedChannelSkipsOBSWithoutCrashing() throws {
        let spacing = 100
        let volumes = 30
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.obs = .auto
        config.excludedChannels = [1]

        let result = try FastrCorrector.correct(
            channels: [channel, channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result.count == 2)
        for c in result { #expect(c.allSatisfy { $0.isFinite }) }
    }

    // MARK: - Motion censoring

    @Test func censoringIgnoresHighMotionDonorsButStillCorrectsThem() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)

        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.numberOfSlices = 1
        config.obs = .off
        config.censoredVolumes = [10, 11, 25]   // pretend these are high-motion

        let result = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: config, samplingRate: 250
        )
        #expect(result[0].count == channel.count)
        #expect(result[0].allSatisfy { $0.isFinite })

        // Censored TRs are still corrected (their artifact power drops too).
        func variance(_ x: ArraySlice<Float>) -> Double {
            let arr = Array(x).map(Double.init)
            let m = arr.reduce(0, +) / Double(arr.count)
            return arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(arr.count)
        }
        let s = triggers[25]
        let before = variance(channel[s..<(s + spacing)])
        let after = variance(result[0][s..<(s + spacing)])
        #expect(after < before * 0.6)
    }

    @Test func censoringEntireNeighborhoodFallsBackGracefully() throws {
        // Censor a long contiguous run so some epochs have no clean neighbors;
        // the fallback must keep the output finite (no empty-template crash).
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)

        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.obs = .off
        config.censoredVolumes = Set(5...35)

        let result = try FastrCorrector.correct(
            channels: [channel], volumeTriggers: triggers,
            config: config, samplingRate: 250
        )
        #expect(result[0].allSatisfy { $0.isFinite })
    }

    // MARK: - Moosmann neighbor selection

    private func sample(_ id: Int, _ values: (Double, Double, Double, Double, Double, Double))
        -> MotionSample {
        MotionSample(id: id, roll: values.0, pitch: values.1, yaw: values.2,
                     dS: values.3, dL: values.4, dP: values.5)
    }

    @Test func moosmannReturnsNilWhenNoSupraThresholdMotion() {
        // Tiny, sub-threshold movements => no motion event => nil (caller uses a
        // plain moving average), matching m_rp_info's fallback.
        let motion = (0..<10).map { sample($0, (0, 0, 0, 0.001 * Double($0), 0, 0)) }
        let neighbors = FastrCorrector.moosmannVolumeNeighbors(
            motion: motion, volumeCount: 10, window: 4, thresholdMm: 0.5
        )
        #expect(neighbors == nil)
    }

    @Test func moosmannExcludesAndDoesNotCrossMotionEvent() {
        // 10 volumes, all near-stationary except a large translation jump at
        // volume 5 (speed >> threshold). Volume 5 should be excluded from every
        // template, and windows should not cross the barrier at 5.
        var motion: [MotionSample] = []
        for v in 0..<10 {
            let pos = v < 5 ? 0.0 : 5.0   // step of 5 mm between vol 4 and 5
            motion.append(sample(v, (0, 0, 0, pos, 0, 0)))
        }
        let neighbors = FastrCorrector.moosmannVolumeNeighbors(
            motion: motion, volumeCount: 10, window: 3, thresholdMm: 0.5
        )
        let n = try! #require(neighbors)
        // The high-motion volume is never used.
        #expect(n.allSatisfy { !$0.contains(5) })
        // A center to the left of the event stays left of it.
        #expect(n[2].allSatisfy { $0 < 5 })
        // A center to the right stays right of it.
        #expect(n[7].allSatisfy { $0 > 5 })
    }

    @Test func moosmannReturnsNilWithoutMotion() {
        let neighbors = FastrCorrector.moosmannVolumeNeighbors(
            motion: nil, volumeCount: 10, window: 4, thresholdMm: 0.5
        )
        #expect(neighbors == nil)
    }

    @Test func moosmannFrontPadsShorterMotion() {
        // 6 volumes, 4 motion rows => motion applies to trailing volumes (2..5),
        // padded volumes 0,1 are treated as motionless. A jump within the motion
        // produces a usable (non-nil) weighting.
        let motion = [
            sample(0, (0, 0, 0, 0, 0, 0)),
            sample(1, (0, 0, 0, 0, 0, 0)),
            sample(2, (0, 0, 0, 5, 0, 0)),   // jump => supra-threshold
            sample(3, (0, 0, 0, 5, 0, 0)),
        ]
        let neighbors = FastrCorrector.moosmannVolumeNeighbors(
            motion: motion, volumeCount: 6, window: 3, thresholdMm: 0.5
        )
        let n = try! #require(neighbors)
        #expect(n.count == 6)
        // The supra-threshold volume (motion row 2 -> volume index 4) is excluded.
        #expect(n.allSatisfy { !$0.contains(4) })
    }

    // MARK: - FARM epoch selection

    @Test func farmSelectsMostCorrelatedEpochs() {
        // Epochs 0,2,4 share waveform A; epochs 1,3,5 share waveform B.
        let length = 32
        let waveA = (0..<length).map { sin(2 * .pi * Double($0) / Double(length)) }
        let waveB = (0..<length).map { cos(2 * .pi * Double($0) / Double(length)) }
        var epochs: [[Double]?] = []
        for s in 0..<6 { epochs.append(s % 2 == 0 ? waveA : waveB) }

        let neighbors = FastrCorrector.farmEpochNeighbors(
            epochs: epochs, select: 2, searchHalf: 10
        )
        // Epoch 0 (waveA) should pick other even epochs (waveA), never odd ones.
        #expect(neighbors[0].allSatisfy { $0 % 2 == 0 })
        #expect(!neighbors[0].contains(0))   // excludes itself
        // Epoch 1 (waveB) should pick other odd epochs.
        #expect(neighbors[1].allSatisfy { $0 % 2 == 1 })
    }

    @Test func farmFallsBackWhenNoCorrelatedEpoch() {
        // Each epoch is distinct random-ish noise => nothing correlates >= 0.9.
        var epochs: [[Double]?] = []
        for s in 0..<8 {
            epochs.append((0..<16).map { sin(Double(s * 13 + $0) * 1.7) })
        }
        let neighbors = FastrCorrector.farmEpochNeighbors(
            epochs: epochs, select: 3, searchHalf: 7, threshold: 0.999
        )
        // With a near-1 threshold, most epochs find no match => empty (fallback).
        #expect(neighbors.contains { $0.isEmpty })
    }

    @Test func farmCorrectionRunsEndToEnd() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.numberOfSlices = 1
        config.templateScheme = .farm
        config.obs = .off

        let result = try FastrCorrector.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result[0].count == channel.count)
        #expect(result[0].allSatisfy { $0.isFinite })

        // FARM should still reduce the gradient artifact power.
        func variance(_ x: ArraySlice<Float>) -> Double {
            let arr = Array(x).map(Double.init)
            let m = arr.reduce(0, +) / Double(arr.count)
            return arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(arr.count)
        }
        let lo = spacing * 4, hi = channel.count - spacing * 4
        #expect(variance(result[0][lo..<hi]) < variance(channel[lo..<hi]) * 0.5)
    }

    @Test func moosmannCorrectionRunsEndToEnd() throws {
        let spacing = 120
        let volumes = 40
        let (channel, triggers) = makeSyntheticChannel(spacing: spacing, volumes: volumes)
        // Motion: a stationary head with one large movement event midway, so the
        // Moosmann branch (not the moving-average fallback) is exercised.
        var motion: [MotionSample] = []
        for v in 0..<volumes {
            let pos = v < volumes / 2 ? 0.0 : 4.0
            motion.append(sample(v, (0, 0, 0, pos, 0, 0)))
        }
        var config = FastrCorrector.Config()
        config.upsampleFactor = 2
        config.numberOfSlices = 1
        config.templateScheme = .moosmann
        config.motion = motion
        config.motionThresholdMm = 0.5
        config.obs = .off

        let result = try FastrCorrector.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 250
        )
        #expect(result[0].count == channel.count)
        #expect(result[0].allSatisfy { $0.isFinite })
    }
}
