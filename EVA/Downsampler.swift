//
//  Downsampler.swift
//  EVA
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
//  Central resampling helpers shared across EVA. Several features need to drop a
//  signal to a lower rate before heavy analysis; this collects the common factor
//  math and the two resampling styles in one place:
//
//    * `strided`     — fast nearest-sample decimation (no anti-aliasing). Right
//                      for analysis/detection where only the coarse shape matters
//                      (ICA, template matching, health scoring).
//    * `blockAveraged` — anti-aliased decimation by averaging each block. Right
//                      when the decimated signal (or an estimate derived from it)
//                      is reconstructed and reapplied, e.g. wavelet reduction.
//
//  `linearUpsample` returns a block-decimated signal to its original length.
//

import Foundation

nonisolated enum Downsampler {
    /// Integer decimation factor that brings `sourceRate` to about `targetRate`.
    /// Always ≥ 1 (returns 1 when the target is at or above the source rate).
    static func factor(sourceRate: Double, targetRate: Double) -> Int {
        guard sourceRate > 0, targetRate > 0 else { return 1 }
        return max(Int((sourceRate / max(targetRate, 1)).rounded()), 1)
    }

    /// The effective sampling rate after decimating by `factor`.
    static func effectiveRate(sourceRate: Double, factor: Int) -> Double {
        sourceRate / Double(max(factor, 1))
    }

    // MARK: Nearest-sample (strided) decimation

    static func strided(_ samples: [Float], by factor: Int) -> [Float] {
        guard factor > 1 else { return samples }
        return Swift.stride(from: 0, to: samples.count, by: factor).map { samples[$0] }
    }

    static func strided(_ samples: [Double], by factor: Int) -> [Double] {
        guard factor > 1 else { return samples }
        return Swift.stride(from: 0, to: samples.count, by: factor).map { samples[$0] }
    }

    // MARK: Anti-aliased (block-average) decimation + upsample

    /// Decimation by averaging each block of `factor` samples — light anti-alias
    /// that avoids the gross aliasing of plain striding.
    static func blockAveraged(_ samples: [Double], by factor: Int) -> [Double] {
        guard factor > 1 else { return samples }
        let count = samples.count
        let outCount = (count + factor - 1) / factor
        var out = [Double](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let start = i * factor
            let end = min(start + factor, count)
            var sum = 0.0
            for k in start..<end { sum += samples[k] }
            out[i] = sum / Double(max(end - start, 1))
        }
        return out
    }

    /// Linear interpolation back to `length`, aligning decimated samples to their
    /// block centers to minimize phase shift. Inverse companion to
    /// `blockAveraged`.
    static func linearUpsample(_ samples: [Double], toLength length: Int, factor: Int) -> [Double] {
        guard factor > 1, samples.count > 1 else {
            return (0..<length).map { samples[min($0 / max(factor, 1), max(samples.count - 1, 0))] }
        }
        let centerOffset = Double(factor - 1) / 2
        var out = [Double](repeating: 0, count: length)
        for t in 0..<length {
            let position = (Double(t) - centerOffset) / Double(factor)
            let clamped = min(max(position, 0), Double(samples.count - 1))
            let lower = Int(clamped.rounded(.down))
            let upper = min(lower + 1, samples.count - 1)
            let weight = clamped - Double(lower)
            out[t] = samples[lower] * (1 - weight) + samples[upper] * weight
        }
        return out
    }
}
