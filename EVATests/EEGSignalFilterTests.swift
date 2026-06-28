//
//  EEGSignalFilterTests.swift
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

struct EEGSignalFilterTests {

    private let samplingRate = 250.0
    private let count = 2000

    private func rms(_ values: [Float]) -> Double {
        SignalStatistics.rootMeanSquare(values.map(Double.init))
    }

    @Test func bandPassPreservesInBandAndAttenuatesOutOfBand() async throws {
        // 10 Hz lives in the 1–40 Hz passband; 0.2 Hz drift and 90 Hz are outside.
        let inBand = SyntheticSignal.sine(frequency: 10, samplingRate: samplingRate, count: count)
        let lowDrift = SyntheticSignal.sine(frequency: 0.2, samplingRate: samplingRate, count: count)
        let highTone = SyntheticSignal.sine(frequency: 90, samplingRate: samplingRate, count: count)

        let filtered = try await EEGSignalFilter.bandPass(
            channels: [inBand, lowDrift, highTone],
            samplingRate: samplingRate,
            lowCutoff: 1,
            highCutoff: 40
        )

        // Compare RMS away from the edges to avoid filter-transient skew.
        func interiorRMS(_ v: [Float]) -> Double { rms(Array(v[400..<(count - 400)])) }

        let inBandRatio = interiorRMS(filtered[0]) / rms(Array(inBand[400..<(count - 400)]))
        #expect(inBandRatio > 0.7, "in-band attenuated too much: \(inBandRatio)")

        let driftRatio = interiorRMS(filtered[1]) / rms(Array(lowDrift[400..<(count - 400)]))
        #expect(driftRatio < 0.3, "low drift not attenuated: \(driftRatio)")

        let highRatio = interiorRMS(filtered[2]) / rms(Array(highTone[400..<(count - 400)]))
        #expect(highRatio < 0.3, "high tone not attenuated: \(highRatio)")
    }

    @Test func bandPassRejectsInvalidRange() async {
        await #expect(throws: EEGSignalFilterError.self) {
            _ = try await EEGSignalFilter.bandPass(
                channels: [SyntheticSignal.sine(frequency: 10, samplingRate: 250, count: 100)],
                samplingRate: 250,
                lowCutoff: 40,
                highCutoff: 10 // high <= low
            )
        }
    }

    @Test func bandPassRejectsZeroSamplingRate() async {
        await #expect(throws: EEGSignalFilterError.self) {
            _ = try await EEGSignalFilter.bandPass(
                channels: [[0, 1, 2]],
                samplingRate: 0,
                lowCutoff: 1,
                highCutoff: 40
            )
        }
    }

    @Test func averageReferenceZeroesPerSampleMean() {
        let channels: [[Float]] = [
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9]
        ]
        let referenced = EEGSignalFilter.averageReferenced(channels)
        // After average referencing, each time sample sums to ~0 across channels.
        for t in 0..<3 {
            let columnSum = referenced.reduce(Float(0)) { $0 + $1[t] }
            #expect(abs(columnSum) < 1e-4)
        }
    }
}
