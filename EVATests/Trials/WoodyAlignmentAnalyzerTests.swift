//
//  WoodyAlignmentAnalyzerTests.swift
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

import Foundation
import Testing
@testable import EVA

struct WoodyAlignmentAnalyzerTests {
    private let samplingRate = 1_000.0
    private let stimulusOffsetSamples = 100
    private let length = 260

    private func gaussian(center: Int, amplitude: Double = 1.0, width: Double = 8.0) -> [Float] {
        (0..<length).map { sample in
            let z = (Double(sample - center) / width)
            return Float(amplitude * exp(-0.5 * z * z))
        }
    }

    private func trial(shift: Int, time: Double = 0) -> WoodyAlignmentAnalyzer.TrialInput {
        WoodyAlignmentAnalyzer.TrialInput(
            sourceTimeSeconds: time,
            stimulusOffsetSamples: stimulusOffsetSamples,
            samples: gaussian(center: stimulusOffsetSamples + 70 + shift)
        )
    }

    @Test func recoversKnownLatencyShifts() throws {
        let shifts = [-18, 0, 22]
        let result = try #require(WoodyAlignmentAnalyzer.align(
            trials: shifts.enumerated().map { index, shift in trial(shift: shift, time: Double(index)) },
            samplingRate: samplingRate,
            windowStartMs: 20,
            windowEndMs: 130,
            maxLagMs: 40,
            maxIterations: 8,
            convergenceToleranceSamples: 0
        ))

        #expect(result.shifts.count == shifts.count)
        let estimated = result.shifts.map(\.latencyShiftSamples)
        let estimatedAnchor = estimated.sorted()[estimated.count / 2]
        let expectedAnchor = shifts.sorted()[shifts.count / 2]
        for (row, expected) in zip(result.shifts, shifts) {
            let centeredEstimate = row.latencyShiftSamples - estimatedAnchor
            let centeredExpected = expected - expectedAnchor
            #expect(abs(centeredEstimate - centeredExpected) <= 1)
            #expect(row.correlation > 0.95)
        }
        #expect(result.converged)
    }

    @Test func noShiftTrialsStayNearZero() throws {
        let result = try #require(WoodyAlignmentAnalyzer.align(
            trials: [trial(shift: 0), trial(shift: 0), trial(shift: 0)],
            samplingRate: samplingRate,
            windowStartMs: 20,
            windowEndMs: 130,
            maxLagMs: 30,
            maxIterations: 5,
            convergenceToleranceSamples: 0
        ))

        #expect(result.shifts.allSatisfy { abs($0.latencyShiftSamples) <= 1 })
        #expect(result.converged)
    }

    @Test func respectsMaxLagLimit() throws {
        let result = try #require(WoodyAlignmentAnalyzer.align(
            trials: [trial(shift: 0), trial(shift: 30)],
            samplingRate: samplingRate,
            windowStartMs: 20,
            windowEndMs: 130,
            maxLagMs: 10,
            maxIterations: 4,
            convergenceToleranceSamples: 0
        ))

        #expect(result.shifts.map { abs($0.latencyShiftSamples) }.max() ?? 0 <= 10)
    }

    @Test func alignedAverageSharpensJitteredTrials() throws {
        let result = try #require(WoodyAlignmentAnalyzer.align(
            trials: [-24, -12, 0, 12, 24].enumerated().map { index, shift in
                trial(shift: shift, time: Double(index))
            },
            samplingRate: samplingRate,
            windowStartMs: 20,
            windowEndMs: 130,
            maxLagMs: 40,
            maxIterations: 8,
            convergenceToleranceSamples: 0
        ))

        let unalignedPeak = result.unalignedAverage.map { abs(Double($0)) }.max() ?? 0
        let alignedPeak = result.alignedAverage.map { abs(Double($0)) }.max() ?? 0
        #expect(alignedPeak > unalignedPeak * 1.25)
    }

    @Test func peakModeAlignsHighlightedPositivePeak() throws {
        let shifts = [-16, 0, 18]
        let result = try #require(WoodyAlignmentAnalyzer.align(
            trials: shifts.enumerated().map { index, shift in
                trial(shift: shift, time: Double(index))
            },
            samplingRate: samplingRate,
            windowStartMs: 45,
            windowEndMs: 95,
            maxLagMs: 35,
            maxIterations: 6,
            convergenceToleranceSamples: 0,
            alignmentMode: .peak,
            peakPolarity: .positive
        ))

        let estimated = result.shifts.map(\.latencyShiftSamples)
        let estimatedAnchor = estimated.sorted()[estimated.count / 2]
        let expectedAnchor = shifts.sorted()[shifts.count / 2]
        for (row, expected) in zip(result.shifts, shifts) {
            #expect(abs((row.latencyShiftSamples - estimatedAnchor) - (expected - expectedAnchor)) <= 1)
        }
    }

    @Test func returnsNilForInvalidInputs() {
        let invalidWindow = WoodyAlignmentAnalyzer.align(
            trials: [trial(shift: 0)],
            samplingRate: samplingRate,
            windowStartMs: 100,
            windowEndMs: 20,
            maxLagMs: 40,
            maxIterations: 8,
            convergenceToleranceSamples: 0
        )
        #expect(invalidWindow == nil)

        let mismatched = WoodyAlignmentAnalyzer.align(
            trials: [
                trial(shift: 0),
                WoodyAlignmentAnalyzer.TrialInput(
                    sourceTimeSeconds: 0,
                    stimulusOffsetSamples: stimulusOffsetSamples,
                    samples: [Float](repeating: 0, count: length - 1)
                )
            ],
            samplingRate: samplingRate,
            windowStartMs: 20,
            windowEndMs: 130,
            maxLagMs: 40,
            maxIterations: 8,
            convergenceToleranceSamples: 0
        )
        #expect(mismatched == nil)
    }
}
