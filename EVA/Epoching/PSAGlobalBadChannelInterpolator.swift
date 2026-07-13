//
//  PSAGlobalBadChannelInterpolator.swift
//  EVA
//
//  Computes PSA global bad-channel escalation away from MainActor. Multiple
//  targets share one spherical-spline factorization and their continuous and
//  epoched replacement samples are composed in the same worker pass.
//


import Accelerate
import Foundation
import simd

nonisolated struct PSAGlobalBadChannelInterpolation: Sendable {
    let target: Int
    let indices: [Int]
    let weights: [Double]
    let continuousSeries: [Float]?
    let epochedSeries: [Float]?
    let errorMessage: String?

    var succeeded: Bool { continuousSeries != nil && errorMessage == nil }
}

nonisolated enum PSAGlobalBadChannelInterpolator {
    /// Solves all targets together because they share the same donor set. This
    /// avoids rebuilding and refactoring the spherical-spline matrix once per
    /// escalated channel.
    static func interpolate(
        targets: [Int],
        continuousSignal: MFFSignalData,
        epochedSignal: MFFSignalData?,
        excludedDonors: Set<Int>,
        positions: [Int: SIMD3<Double>]
    ) -> [PSAGlobalBadChannelInterpolation] {
        guard !targets.isEmpty else { return [] }

        let targetSet = Set(targets)
        let good = continuousSignal.data.indices.filter {
            !targetSet.contains($0)
                && !excludedDonors.contains($0)
                && positions[$0] != nil
        }
        let solved = SphericalSpline.interpolationWeightsBatch(
            targets: targets,
            good: good,
            positions: positions
        )

        return targets.map { target in
            guard positions[target] != nil else {
                return failure(
                    target: target,
                    message: "No 3D coordinates for Ch \(target + 1); can't interpolate."
                )
            }
            guard let solution = solved[target] else {
                return failure(
                    target: target,
                    message: "Couldn't compute interpolation weights for Ch \(target + 1)."
                )
            }
            guard let continuousSeries = compose(
                target: target,
                indices: solution.indices,
                weights: solution.weights,
                data: continuousSignal.data
            ) else {
                return failure(
                    target: target,
                    message: "Couldn't compose interpolated samples for Ch \(target + 1)."
                )
            }

            let epochedSeries = epochedSignal.flatMap {
                compose(
                    target: target,
                    indices: solution.indices,
                    weights: solution.weights,
                    data: $0.data
                )
            }
            return PSAGlobalBadChannelInterpolation(
                target: target,
                indices: solution.indices,
                weights: solution.weights,
                continuousSeries: continuousSeries,
                epochedSeries: epochedSeries,
                errorMessage: nil
            )
        }
    }

    private static func failure(
        target: Int,
        message: String
    ) -> PSAGlobalBadChannelInterpolation {
        PSAGlobalBadChannelInterpolation(
            target: target,
            indices: [],
            weights: [],
            continuousSeries: nil,
            epochedSeries: nil,
            errorMessage: message
        )
    }

    private static func compose(
        target: Int,
        indices: [Int],
        weights: [Double],
        data: [[Float]]
    ) -> [Float]? {
        guard data.indices.contains(target),
              indices.count == weights.count,
              !indices.isEmpty
        else { return nil }

        let sampleCount = data[target].count
        guard indices.allSatisfy({ data.indices.contains($0) && data[$0].count == sampleCount }) else {
            return nil
        }

        var series = [Float](repeating: 0, count: sampleCount)
        for (sourceIndex, weight) in zip(indices, weights) {
            vDSP.add(
                multiplication: (data[sourceIndex], Float(weight)),
                series,
                result: &series
            )
        }
        return series
    }
}
