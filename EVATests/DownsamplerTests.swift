//
//  DownsamplerTests.swift
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

struct DownsamplerTests {

    @Test func factorRoundsToNearestInteger() {
        #expect(Downsampler.factor(sourceRate: 1000, targetRate: 250) == 4)
        #expect(Downsampler.factor(sourceRate: 1000, targetRate: 300) == 3) // 3.33 -> 3
        #expect(Downsampler.factor(sourceRate: 1000, targetRate: 2000) == 1) // never below 1
        #expect(Downsampler.factor(sourceRate: 0, targetRate: 250) == 1)     // guarded
    }

    @Test func effectiveRateDividesBySafeFactor() {
        #expect(Downsampler.effectiveRate(sourceRate: 1000, factor: 4) == 250)
        #expect(Downsampler.effectiveRate(sourceRate: 1000, factor: 0) == 1000) // factor clamped to 1
    }

    @Test func stridedPicksEveryNthSample() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        #expect(Downsampler.strided(samples, by: 2) == [0, 2, 4, 6])
        #expect(Downsampler.strided(samples, by: 1) == samples) // factor 1 is identity
    }

    @Test func blockAveragedPreservesConstantAndLength() {
        let constant = [Double](repeating: 5, count: 12)
        let decimated = Downsampler.blockAveraged(constant, by: 4)
        #expect(decimated.count == 3)                       // ceil(12/4)
        #expect(decimated.allSatisfy { abs($0 - 5) < 1e-12 })
    }

    @Test func blockAveragedHandlesRaggedFinalBlock() {
        // 10 samples by 4 -> blocks [0..3],[4..7],[8..9]; last block averages 2.
        let decimated = Downsampler.blockAveraged(Array(0..<10).map(Double.init), by: 4)
        #expect(decimated.count == 3)
        #expect(abs(decimated[2] - 8.5) < 1e-12)            // mean of 8,9
    }

    @Test func linearUpsampleReturnsRequestedLengthAndPreservesConstant() {
        let decimated = [Double](repeating: 7, count: 4)
        let upsampled = Downsampler.linearUpsample(decimated, toLength: 16, factor: 4)
        #expect(upsampled.count == 16)
        #expect(upsampled.allSatisfy { abs($0 - 7) < 1e-9 })
    }

    @Test func decimateThenUpsampleApproximatesLinearRamp() {
        // A linear ramp survives block-average + linear-upsample with small error.
        let ramp = (0..<64).map(Double.init)
        let decimated = Downsampler.blockAveraged(ramp, by: 4)
        let restored = Downsampler.linearUpsample(decimated, toLength: ramp.count, factor: 4)
        #expect(restored.count == ramp.count)
        // Interior samples (away from edges) track the ramp closely.
        let interiorError = (8..<56).map { abs(restored[$0] - ramp[$0]) }.max() ?? 0
        #expect(interiorError < 1.0, "interior error \(interiorError)")
    }
}
