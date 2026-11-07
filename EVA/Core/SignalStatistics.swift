//
//  SignalStatistics.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

/// Stateless scalar summaries shared by signal-processing algorithms.
/// Inputs are used as supplied: these helpers do not remove NaN or infinite values.
nonisolated enum SignalStatistics {
    /// Interpolates between adjacent values in an ascending, already-sorted array.
    /// For a finite fraction, values outside 0...1 are clamped; empty input returns 0.
    /// Example: [10, 20] at fraction 0.25 returns 12.5. Sorting is the caller's job.
    static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let position = min(max(fraction, 0), 1) * Double(sortedValues.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sortedValues.count - 1)
        let weight = position - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    /// Float counterpart of the Double overload, with the same sorting and fraction contract.
    static func percentile(_ sortedValues: [Float], fraction: Double) -> Float {
        guard !sortedValues.isEmpty else { return 0 }
        let clampedFraction = min(max(fraction, 0), 1)
        let position = clampedFraction * Double(sortedValues.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sortedValues[lower] }
        let weight = Float(position - Double(lower))
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    /// sqrt(mean(x²)), in the input's units. Empty input returns 0.
    static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
    }

    /// Mean squared deviation from the mean, dividing by N. Empty input returns 0.
    static func populationVariance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    /// Squared deviations divided by N − 1, for a sample estimate of variance.
    /// Empty input and finite singleton arrays return 0; nonfinite values are not removed.
    static func sampleVariance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var total = 0.0
        for value in values {
            let delta = value - mean
            total += delta * delta
        }
        return total / Double(max(values.count - 1, 1))
    }

    /// Sum of squares without dividing by sample count; units are input-units squared.
    static func vectorEnergy(_ values: [Double]) -> Double {
        values.reduce(0) { $0 + ($1 * $1) }
    }

    /// Sum of squares accumulated in Double; each multiplication still occurs in Float.
    static func vectorEnergy(_ values: [Float]) -> Double {
        values.reduce(0) { $0 + Double($1 * $1) }
    }
}
