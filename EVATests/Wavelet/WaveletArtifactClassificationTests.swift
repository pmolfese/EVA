//
//  WaveletArtifactClassificationTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Covers the Wavelet Explorer's cross-channel artifact-type classification —
//  the decision matrix directly, plus the wiring that feeds it through a real
//  `explore` scan.
//

import Testing
import Foundation
@testable import EVA

struct WaveletArtifactClassificationTests {

    // Channels 0-3 are "ocular" (frontal), 8-15 are "lateral" (temporal),
    // matching the shape `WaveletChannelRoles.resolve` produces from a real
    // net geometry.
    private let roles = WaveletChannelRoles(
        ocular: Set(0..<4),
        lateral: Set(8..<16)
    )

    private let levelCount = 6
    // With levelCount 6: isCoarse => peakLevel >= 4, isFine => peakLevel <= 2.
    private let coarseLevel = 5
    private let fineLevel = 2

    // MARK: - Decision matrix

    @Test func singleChannelEventIsChannelLocal() {
        // One contributing channel means no spatial pattern to speak of —
        // an electrode pop / bad contact, regardless of frequency or whether
        // that channel happens to sit in the ocular group.
        for level in [fineLevel, coarseLevel] {
            let type = WaveletArtifactAnalyzer.classifyArtifactType(
                contributingChannels: [0],
                peakLevel: level,
                levelCount: levelCount,
                roles: roles
            )
            #expect(type == .channelLocal, "level \(level) gave \(type)")
        }
    }

    @Test func frontalWeightedCoarseEventIsOcular() {
        // 3 of 4 contributing channels are ocular (0.75 >= 0.5) at a coarse
        // (low-frequency) level — the blink/eye-movement signature.
        let type = WaveletArtifactAnalyzer.classifyArtifactType(
            contributingChannels: [0, 1, 2, 20],
            peakLevel: coarseLevel,
            levelCount: levelCount,
            roles: roles
        )
        #expect(type == .ocular)
    }

    @Test func frontalWeightedButFastEventIsNotOcular() {
        // Same frontal channels, but high-frequency: a blink is slow, so
        // this should fall through to movement rather than claim ocular.
        let type = WaveletArtifactAnalyzer.classifyArtifactType(
            contributingChannels: [0, 1, 2, 20],
            peakLevel: fineLevel,
            levelCount: levelCount,
            roles: roles
        )
        #expect(type != .ocular)
    }

    @Test func lateralWeightedFineEventIsMuscle() {
        // Half the contributing channels are lateral (0.5 >= 0.4) at a fine
        // (high-frequency) level — the EMG signature.
        let type = WaveletArtifactAnalyzer.classifyArtifactType(
            contributingChannels: [8, 9, 20, 21],
            peakLevel: fineLevel,
            levelCount: levelCount,
            roles: roles
        )
        #expect(type == .muscle)
    }

    @Test func lateralWeightedButSlowEventIsNotMuscle() {
        // Lateral channels but low-frequency — muscle is broadband/fast, so
        // this shouldn't be labelled muscle.
        let type = WaveletArtifactAnalyzer.classifyArtifactType(
            contributingChannels: [8, 9, 20, 21],
            peakLevel: coarseLevel,
            levelCount: levelCount,
            roles: roles
        )
        #expect(type != .muscle)
    }

    @Test func widespreadUnweightedEventIsMovement() {
        // Many channels, no ocular or lateral concentration — cap shift or
        // subject movement.
        let type = WaveletArtifactAnalyzer.classifyArtifactType(
            contributingChannels: Set(20..<40),
            peakLevel: coarseLevel,
            levelCount: levelCount,
            roles: roles
        )
        #expect(type == .movement)
    }

    @Test func withoutNetGeometryMultiChannelEventsAreUnclassified() {
        // No layout on disk means no ocular/lateral tables. Rather than
        // guess, multi-channel events should come back unclassified — the
        // scan is still useful, it just can't speak to topography.
        let empty = WaveletChannelRoles(ocular: [], lateral: [])
        let type = WaveletArtifactAnalyzer.classifyArtifactType(
            contributingChannels: [0, 1, 2, 3],
            peakLevel: coarseLevel,
            levelCount: levelCount,
            roles: empty
        )
        #expect(type == .unclassified)
    }

    @Test func singleChannelStillClassifiesWithoutNetGeometry() {
        // Channel-local needs no topography table to be identifiable.
        let empty = WaveletChannelRoles(ocular: [], lateral: [])
        let type = WaveletArtifactAnalyzer.classifyArtifactType(
            contributingChannels: [7],
            peakLevel: fineLevel,
            levelCount: levelCount,
            roles: empty
        )
        #expect(type == .channelLocal)
    }

    // MARK: - End-to-end wiring

    /// A burst confined to one channel should survive the scan (that's the
    /// point of per-channel detection — it isn't diluted by the quiet
    /// channels around it) and be reported as channel-local.
    @Test func isolatedChannelBurstSurvivesScanAsChannelLocal() throws {
        let sr = 500.0
        let n = 30_000
        let burstStart = 15_000
        let burstLength = 200

        var data: [[Float]] = []
        for c in 0..<16 {
            var state = UInt64(c + 1) &* 6364136223846793005 &+ 1
            var channel = (0..<n).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
            }
            // Only channel 5 gets the artifact.
            if c == 5 {
                for k in 0..<burstLength {
                    let phase = Double(k) / Double(burstLength) * .pi
                    channel[burstStart + k] += Float(sin(phase)) * 120
                }
            }
            data.append(channel)
        }

        let signal = SyntheticSignal.make(data, samplingRate: sr)
        let configuration = WaveletArtifactExplorerConfiguration(
            channelIndices: Array(0..<16), downsampleRate: 500, levelCount: 8, thresholdScale: 1,
            cleaningMode: .conservativeLocal, intensity: 1, waveletFamily: .bior44,
            thresholdRule: .hard, thresholdModel: .bayesShrink,
            mergeWindowSeconds: 0.1, minimumDurationSeconds: 0.02, maximumCandidates: 40
        )
        let result = WaveletArtifactAnalyzer.explore(
            in: signal,
            configuration: configuration,
            channelRoles: roles
        )

        let burstTime = Double(burstStart) / sr
        let match = result.candidates.first { abs($0.peakTimeSeconds - burstTime) < 0.5 }
        let found = try #require(
            match,
            "no candidate near \(burstTime)s in \(result.candidates.count) candidates"
        )
        #expect(found.channelIndex == 5, "attributed to Ch \(found.channelIndex + 1)")
        #expect(found.artifactType == .channelLocal, "got \(found.artifactType)")
    }

    /// A fast (high-frequency) burst sits above the downsampled pass's
    /// Nyquist, so only the optional full-rate pass can see it.
    @Test func fastPassFindsBurstAboveDownsampledNyquist() {
        let sr = 1000.0
        let n = 30_000
        let burstStart = 15_000
        let burstLength = 300
        // 300 Hz — well above the 125 Hz Nyquist of a 250 Hz downsampled
        // pass, and above the 250 Hz Nyquist of a 500 Hz one.
        let burstFrequency = 300.0

        var data: [[Float]] = []
        for c in 0..<8 {
            var state = UInt64(c + 1) &* 6364136223846793005 &+ 1
            var channel = (0..<n).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
            }
            if c == 3 {
                for k in 0..<burstLength {
                    let t = Double(k) / sr
                    let envelope = sin(Double(k) / Double(burstLength) * .pi)
                    channel[burstStart + k] += Float(sin(2 * .pi * burstFrequency * t) * envelope) * 60
                }
            }
            data.append(channel)
        }

        let signal = SyntheticSignal.make(data, samplingRate: sr)
        func configuration(fastPass: Bool) -> WaveletArtifactExplorerConfiguration {
            WaveletArtifactExplorerConfiguration(
                channelIndices: Array(0..<8), downsampleRate: 250, levelCount: 8, thresholdScale: 1,
                cleaningMode: .conservativeLocal, intensity: 1, waveletFamily: .bior44,
                thresholdRule: .hard, thresholdModel: .bayesShrink,
                mergeWindowSeconds: 0.1, minimumDurationSeconds: 0.02, maximumCandidates: 40,
                detectsFastArtifacts: fastPass
            )
        }

        let burstTime = Double(burstStart) / sr
        func foundBurst(_ result: WaveletArtifactExplorerResult) -> Bool {
            result.candidates.contains { abs($0.peakTimeSeconds - burstTime) < 0.5 }
        }

        let withoutFastPass = WaveletArtifactAnalyzer.explore(
            in: signal, configuration: configuration(fastPass: false), channelRoles: roles
        )
        let withFastPass = WaveletArtifactAnalyzer.explore(
            in: signal, configuration: configuration(fastPass: true), channelRoles: roles
        )

        #expect(foundBurst(withFastPass), "fast pass missed the \(Int(burstFrequency)) Hz burst")
        #expect(
            !foundBurst(withoutFastPass),
            "the downsampled pass reported a burst above its own Nyquist, so this test isn't measuring what it claims"
        )
    }

    /// Scores are sigmas above each channel's own local median, so a burst on
    /// a quiet channel must not be outranked by ordinary activity on a
    /// channel that simply runs hotter.
    @Test func scoreIsComparableAcrossChannelsOfDifferentAmplitude() {
        let sr = 500.0
        let n = 30_000
        let burstStart = 15_000
        let burstLength = 200

        var data: [[Float]] = []
        for c in 0..<8 {
            var state = UInt64(c + 1) &* 6364136223846793005 &+ 1
            // Channel 0 is quiet; channel 4 has 20x the noise amplitude.
            let noiseGain: Float = c == 4 ? 20 : 1
            var channel = (0..<n).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2) * noiseGain
            }
            // The *only* real artifact is on the quiet channel 0, scaled to
            // its own noise floor — far smaller in absolute terms than
            // channel 4's routine noise.
            if c == 0 {
                for k in 0..<burstLength {
                    let phase = Double(k) / Double(burstLength) * .pi
                    channel[burstStart + k] += Float(sin(phase)) * 40
                }
            }
            data.append(channel)
        }

        let signal = SyntheticSignal.make(data, samplingRate: sr)
        let configuration = WaveletArtifactExplorerConfiguration(
            channelIndices: Array(0..<8), downsampleRate: 500, levelCount: 8, thresholdScale: 1,
            cleaningMode: .conservativeLocal, intensity: 1, waveletFamily: .bior44,
            thresholdRule: .hard, thresholdModel: .bayesShrink,
            mergeWindowSeconds: 0.1, minimumDurationSeconds: 0.02, maximumCandidates: 40
        )
        let result = WaveletArtifactAnalyzer.explore(
            in: signal,
            configuration: configuration,
            channelRoles: roles
        )

        let burstTime = Double(burstStart) / sr
        guard let top = result.candidates.first else {
            Issue.record("scan produced no candidates")
            return
        }
        #expect(
            abs(top.peakTimeSeconds - burstTime) < 0.5,
            "top-ranked candidate is at \(top.peakTimeSeconds)s on Ch \(top.channelIndex + 1), not the planted burst at \(burstTime)s"
        )
    }
}
