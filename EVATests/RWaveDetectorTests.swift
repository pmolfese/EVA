//
//  RWaveDetectorTests.swift
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

struct RWaveDetectorTests {

    /// A single-channel ECG-like source: sharp positive QRS-like bumps repeated at a
    /// fixed rate on top of low-amplitude noise.
    private func syntheticECGSource(
        sampleCount: Int,
        samplingRate: Double,
        periodSamples: Int,
        bumpWidth: Int = 16
    ) -> (source: ECGDetectionSource, expectedTimes: [Double]) {
        let bump = SyntheticSignal.bump(width: bumpWidth)
        let positions = Array(stride(from: bumpWidth, to: sampleCount - bumpWidth, by: periodSamples))
        var channel = [Float](repeating: 0, count: sampleCount)
        var state: UInt64 = 12345
        for i in 0..<sampleCount {
            state = state &* 6364136223846793005 &+ 1
            channel[i] = Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
        }
        for start in positions {
            for k in 0..<bumpWidth where start + k < sampleCount {
                channel[start + k] += bump[k]
            }
        }
        let source = ECGDetectionSource(
            id: "synthetic",
            label: "Synthetic ECG",
            channelLabels: ["ECG1"],
            channels: [channel],
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate
        )
        let expectedTimes = positions.map { Double($0 + bumpWidth / 2) / samplingRate }
        return (source, expectedTimes)
    }

    private func config(_ algorithm: ECGDetectionAlgorithm) -> ECGDetectionConfiguration {
        ECGDetectionConfiguration(
            algorithm: algorithm,
            thresholdSD: 2.5,
            minimumRRSeconds: 0.4,
            polarity: .positive
        )
    }

    @Test(arguments: [
        ECGDetectionAlgorithm.simple,
        .panTompkins,
        .hamilton,
        .wfdb,
        .wavelet,
        .christov,
    ])
    func detectsPeriodicBeatsAcrossAlgorithms(algorithm: ECGDetectionAlgorithm) {
        let samplingRate = 250.0
        let (source, expected) = syntheticECGSource(
            sampleCount: 5000, samplingRate: samplingRate, periodSamples: 250
        )
        let events = RWaveDetector.detect(sources: [source], configuration: config(algorithm))

        #expect(!events.isEmpty, "\(algorithm.rawValue) found no beats")
        #expect(events.allSatisfy { $0.code == RWaveDetector.eventCode })
        // Each detected beat should be near a planted bump.
        for event in events {
            let nearest = expected.min(by: { abs($0 - event.beginTimeSeconds) < abs($1 - event.beginTimeSeconds) }) ?? .infinity
            #expect(abs(nearest - event.beginTimeSeconds) < 0.1,
                    "\(algorithm.rawValue) beat at \(event.beginTimeSeconds) not close to any planted beat")
        }
        // Should recover most interior beats without wildly over- or under-detecting.
        #expect(Double(events.count) > Double(expected.count) * 0.4)
        #expect(events.count <= expected.count + 2)
    }

    @Test func detectedEventsAreChronologicallySortedAndNonOverlapping() {
        let samplingRate = 250.0
        let (source, _) = syntheticECGSource(
            sampleCount: 5000, samplingRate: samplingRate, periodSamples: 250
        )
        let events = RWaveDetector.detect(sources: [source], configuration: config(.simple))

        let times = events.map(\.beginTimeSeconds)
        #expect(times == times.sorted())
        for i in 1..<max(times.count, 1) where i < times.count {
            #expect(times[i] - times[i - 1] >= 0.4 - 1e-6, "minimum RR spacing violated")
        }
    }

    @Test func emptySourcesProduceNoEvents() {
        let events = RWaveDetector.detect(sources: [], configuration: config(.simple))
        #expect(events.isEmpty)
    }

    @Test func degenerateSourceIsIgnoredGracefully() {
        let tooShort = ECGDetectionSource(
            id: "short", label: "short", channelLabels: ["a"],
            channels: [[0, 1]], samplingRate: 250, duration: 0.008
        )
        let events = RWaveDetector.detect(sources: [tooShort], configuration: config(.simple))
        #expect(events.isEmpty)
    }

    @Test func zeroSamplingRateIsIgnoredGracefully() {
        let source = ECGDetectionSource(
            id: "bad", label: "bad", channelLabels: ["a"],
            channels: [[Float](repeating: 0, count: 100)], samplingRate: 0, duration: 0
        )
        let events = RWaveDetector.detect(sources: [source], configuration: config(.simple))
        #expect(events.isEmpty)
    }
}
