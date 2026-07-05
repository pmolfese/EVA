//
//  TRSpacing.swift
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
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Inter-trigger spacing diagnostics for the TR (TREV) markers used by the MR
//  gradient-removal tools. All of AAS, FASTR, FARM and Moosmann assume a fixed
//  TR (they cut each artifact epoch at a single median-derived length), so the
//  UI uses this to warn on — and block correction for — unevenly spaced markers.
//

import Foundation

nonisolated struct TRSpacingInfo: Sendable {
    /// Gaps between consecutive trigger samples.
    let intervalsSamples: [Int]
    let samplingRate: Double
    /// Max allowed deviation (in samples) from the median before markers are
    /// considered unevenly spaced. Mirrors `GradientRemover`'s spacingTolerance.
    let toleranceSamples: Int

    var triggerCount: Int { intervalsSamples.count + (intervalsSamples.isEmpty ? 0 : 1) }
    var hasEnoughTriggers: Bool { intervalsSamples.count >= 1 }

    /// True when every gap is within `toleranceSamples` of the median gap.
    var isEvenlySpaced: Bool {
        guard let median = medianInterval else { return false }
        return intervalsSamples.allSatisfy { abs($0 - median) <= toleranceSamples }
    }

    var distinctIntervalCount: Int { Set(intervalsSamples).count }

    private func seconds(_ samples: Double) -> Double {
        samplingRate > 0 ? samples / samplingRate : 0
    }

    /// Median gap in samples (nil if there are none).
    var medianInterval: Int? {
        guard !intervalsSamples.isEmpty else { return nil }
        let sorted = intervalsSamples.sorted()
        return sorted[sorted.count / 2]
    }

    /// Most common gap (ties broken toward the smaller value), in seconds.
    var modeSeconds: Double {
        guard !intervalsSamples.isEmpty else { return 0 }
        var counts: [Int: Int] = [:]
        for v in intervalsSamples { counts[v, default: 0] += 1 }
        let mode = counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }!.key
        return seconds(Double(mode))
    }

    var medianSeconds: Double { seconds(Double(medianInterval ?? 0)) }

    var meanSeconds: Double {
        guard !intervalsSamples.isEmpty else { return 0 }
        let mean = Double(intervalsSamples.reduce(0, +)) / Double(intervalsSamples.count)
        return seconds(mean)
    }

    /// The TR to display: the single fixed value when evenly spaced, otherwise
    /// the mode (most representative) gap.
    var representativeSeconds: Double { modeSeconds }

    static func from(triggerSamples: [Int], samplingRate: Double, toleranceSamples: Int = 1) -> TRSpacingInfo {
        let sorted = triggerSamples.sorted()
        let intervals = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
        return TRSpacingInfo(intervalsSamples: intervals,
                             samplingRate: samplingRate,
                             toleranceSamples: toleranceSamples)
    }
}
