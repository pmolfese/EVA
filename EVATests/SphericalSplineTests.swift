//
//  SphericalSplineTests.swift
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
import simd
@testable import EVA

struct SphericalSplineTests {

    /// A handful of electrodes spread over the unit sphere. Index 0 is the
    /// "bad" channel to interpolate; the rest are good neighbors.
    private static let positions: [Int: SIMD3<Double>] = [
        0: simd_normalize(SIMD3<Double>(0.2, 0.1, 0.95)),
        1: simd_normalize(SIMD3<Double>(1, 0, 0.2)),
        2: simd_normalize(SIMD3<Double>(0, 1, 0.2)),
        3: simd_normalize(SIMD3<Double>(-1, 0, 0.2)),
        4: simd_normalize(SIMD3<Double>(0, -1, 0.2)),
        5: simd_normalize(SIMD3<Double>(0, 0, 1))
    ]

    @Test func weightsSumToOne() {
        // The augmented constraint row forces Σ weights = 1, which guarantees
        // a constant field is reproduced exactly.
        let result = SphericalSpline.interpolationWeights(
            target: 0, good: [1, 2, 3, 4, 5], positions: Self.positions
        )
        let weights = try! #require(result).weights
        #expect(abs(weights.reduce(0, +) - 1) < 1e-6)
    }

    @Test func reproducesConstantField() {
        let result = try! #require(
            SphericalSpline.interpolationWeights(
                target: 0, good: [1, 2, 3, 4, 5], positions: Self.positions
            )
        )
        // A flat field of 42 µV everywhere must interpolate back to 42.
        let interpolated = result.weights.reduce(0) { $0 + $1 * 42.0 }
        #expect(abs(interpolated - 42) < 1e-6)
    }

    @Test func returnsNilWithTooFewGoodChannels() {
        #expect(
            SphericalSpline.interpolationWeights(
                target: 0, good: [1, 2], positions: Self.positions
            ) == nil
        )
    }

    @Test func returnsNilWhenTargetPositionMissing() {
        #expect(
            SphericalSpline.interpolationWeights(
                target: 99, good: [1, 2, 3, 4], positions: Self.positions
            ) == nil
        )
    }

    @Test func ignoresGoodChannelsWithoutPositions() {
        // Channel 88 has no position and must be dropped from the returned indices.
        let result = try! #require(
            SphericalSpline.interpolationWeights(
                target: 0, good: [1, 2, 3, 88], positions: Self.positions
            )
        )
        #expect(result.indices == [1, 2, 3])
        #expect(result.weights.count == 3)
    }
}
