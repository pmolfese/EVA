//
//  BCGDetectorTests.swift
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

struct BCGDetectorTests {

    /// Builds channels carrying a shared periodic "cardiac" pulse train (a narrow bump
    /// repeated every `periodSamples`) plus per-channel pseudo-random noise, mimicking a
    /// BCG artifact that is spatially consistent but temporally sparse.
    private func periodicPulseChannels(
        channelCount: Int,
        sampleCount: Int,
        periodSamples: Int,
        pulseWidth: Int = 40
    ) -> (data: [[Float]], expectedTimes: [Double]) {
        let pulse = SyntheticSignal.bump(width: pulseWidth)
        let positions = Array(stride(from: pulseWidth, to: sampleCount - pulseWidth, by: periodSamples))
        var data: [[Float]] = (0..<channelCount).map { c in
            var state = UInt64(c + 11) &* 6364136223846793005 &+ 1
            return (0..<sampleCount).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 4)
            }
        }
        for c in 0..<channelCount {
            for start in positions {
                for k in 0..<pulseWidth where start + k < sampleCount {
                    data[c][start + k] += pulse[k]
                }
            }
        }
        return (data, positions.map { Double($0 + pulseWidth / 2) })
    }

    @Test func periodicityEventsFindsRepeatingPulses() async {
        let samplingRate = 250.0
        // 1 Hz pulse train (60 bpm) falls inside the default 40-120 bpm band.
        let (data, expected) = periodicPulseChannels(
            channelCount: 6, sampleCount: 6000, periodSamples: 250
        )
        let times = await BCGDetector.periodicityEvents(
            channels: data, samplingRate: samplingRate
        )

        #expect(!times.isEmpty)
        // Every detected event should land near an expected pulse (within 120 ms).
        for t in times {
            let expectedSeconds = expected.map { $0 / samplingRate }
            let nearest = expectedSeconds.min(by: { abs($0 - t) < abs($1 - t) }) ?? .infinity
            #expect(abs(nearest - t) < 0.12, "detected time \(t) not close to any expected pulse")
        }
        // Should recover most of the interior pulses (edges are attenuated by filtering).
        #expect(times.count >= expected.count / 2)
    }

    @Test func periodicityEventsEmptyOnFlatSignal() async {
        let flat: [[Float]] = (0..<4).map { _ in [Float](repeating: 0, count: 2000) }
        let times = await BCGDetector.periodicityEvents(channels: flat, samplingRate: 250)
        #expect(times.isEmpty)
    }

    @Test func periodicityEventsHandlesEmptyInput() async {
        let times = await BCGDetector.periodicityEvents(channels: [], samplingRate: 250)
        #expect(times.isEmpty)
    }

    @Test func cardiacPowerEventsFindsRepeatingPulses() async {
        let samplingRate = 250.0
        // Default band is 0.8-1.5 Hz; use a ~1 Hz pulse train.
        let (data, expected) = periodicPulseChannels(
            channelCount: 6, sampleCount: 6000, periodSamples: 250
        )
        let times = await BCGDetector.cardiacPowerEvents(
            channels: data, samplingRate: samplingRate
        )

        #expect(!times.isEmpty)
        let expectedSeconds = expected.map { $0 / samplingRate }
        for t in times {
            let nearest = expectedSeconds.min(by: { abs($0 - t) < abs($1 - t) }) ?? .infinity
            #expect(abs(nearest - t) < 0.15)
        }
    }

    @Test func spatialPCAEventsFindsRepeatingPulses() async {
        let samplingRate = 250.0
        let (data, expected) = periodicPulseChannels(
            channelCount: 8, sampleCount: 6000, periodSamples: 250
        )
        let times = await BCGDetector.spatialPCAEvents(
            channels: data, samplingRate: samplingRate
        )

        #expect(!times.isEmpty)
        let expectedSeconds = expected.map { $0 / samplingRate }
        var hits = 0
        for t in times {
            let nearest = expectedSeconds.min(by: { abs($0 - t) < abs($1 - t) }) ?? .infinity
            if abs(nearest - t) < 0.15 { hits += 1 }
        }
        #expect(Double(hits) / Double(times.count) > 0.8, "most detections should align with planted pulses")
    }

    @Test func qrsLockingEventsShiftsAndClipsToRecordingDuration() {
        let qrsTimes = [0.1, 1.0, 5.0, 9.95]
        let shifted = BCGDetector.qrsLockingEvents(
            qrsTimes: qrsTimes, lagSeconds: 0.3, recordingDuration: 10.0
        )
        // Last time (9.95 + 0.3 = 10.25) exceeds duration and should be dropped.
        #expect(shifted == [0.4, 1.3, 5.3])
    }

    @Test func qrsLockingEventsDropsNegativeShifts() {
        let shifted = BCGDetector.qrsLockingEvents(
            qrsTimes: [0.1], lagSeconds: -0.5, recordingDuration: 10.0
        )
        #expect(shifted.isEmpty)
    }

    @Test func makeEventsProducesSortedCodedEvents() {
        let events = BCGDetector.makeEvents(times: [0.5, 1.5, 2.5], windowSeconds: 0.1)
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.code == BCGDetector.eventCode })
        #expect(events.map(\.beginTimeSeconds) == [0.5, 1.5, 2.5])
    }

    @Test func computeGFPIsZeroForIdenticalChannelsAtZero() {
        let channels: [[Float]] = [[0, 0, 0], [0, 0, 0]]
        let gfp = BCGDetector.computeGFP(channels: channels)
        #expect(gfp == [0, 0, 0])
    }

    @Test func computeGFPHandlesEmptyChannels() {
        #expect(BCGDetector.computeGFP(channels: []).isEmpty)
    }

    @Test func findPeaksRespectsMinimumSpacing() {
        // Two adjacent spikes closer than the minimum spacing: only the taller survives.
        var signal = [Float](repeating: 0, count: 100)
        signal[40] = 10
        signal[45] = 12
        signal[80] = 9
        let peaks = BCGDetector.findPeaks(
            in: signal, samplingRate: 100, thresholdSD: 1.0, minSpacingSamples: 20
        )
        // Expect one peak near sample 45 (taller of the close pair) and one near 80.
        #expect(peaks.count == 2)
    }

    @Test func virtualECGComponentTracksSharedCardiacSignal() async {
        let samplingRate = 250.0
        let (data, _) = periodicPulseChannels(
            channelCount: 6, sampleCount: 6000, periodSamples: 250
        )
        let pc = await BCGDetector.virtualECGComponent(channels: data, samplingRate: samplingRate)
        #expect(pc != nil)
        #expect(pc?.count == 6000)
    }

    @Test func virtualECGComponentNilForTooFewChannels() async {
        let pc = await BCGDetector.virtualECGComponent(channels: [[1, 2, 3]], samplingRate: 250)
        #expect(pc == nil)
    }
}
