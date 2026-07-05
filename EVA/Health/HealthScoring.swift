//
//  HealthScoring.swift
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

import Foundation

nonisolated enum HealthScoring {
    static func clippingFraction(absValues: [Double], maxAbs: Double) -> Double {
        guard absValues.count > 3, maxAbs > 20 else { return 0 }
        let tolerance = max(maxAbs * 0.001, 0.01)
        let clipped = absValues.filter { abs($0 - maxAbs) <= tolerance }.count
        return Double(clipped) / Double(absValues.count)
    }

    static func scoreUpperRatio(_ ratio: Double, green: Double, red: Double) -> Double {
        guard ratio.isFinite else { return 0 }
        if ratio <= green { return 1 }
        if ratio >= red { return 0 }
        return 1 - (ratio - green) / max(red - green, 1e-9)
    }

    static func scoreTwoSidedRatio(_ ratio: Double, green: Double, red: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 0 }
        return scoreUpperRatio(max(ratio, 1 / ratio), green: green, red: red)
    }

    static func scoreUpperFraction(_ fraction: Double, green: Double, red: Double) -> Double {
        scoreUpperRatio(fraction, green: green, red: red)
    }

    static func scoreLowerBound(_ value: Double, green: Double, red: Double) -> Double {
        guard value.isFinite else { return 0 }
        if value >= green { return 1 }
        if value <= red { return 0 }
        return (value - red) / max(green - red, 1e-9)
    }

    static func grade(for score: Double) -> ChannelHealthGrade {
        if score >= 0.78 { return .good }
        if score >= 0.50 { return .watch }
        return .poor
    }

    static func formatPercent(_ fraction: Double) -> String {
        String(format: "%.1f%%", min(max(fraction, 0), 1) * 100)
    }

    static func formatRatio(_ ratio: Double) -> String {
        guard ratio.isFinite else { return "nanx" }
        return String(format: "%.1fx", ratio)
    }

    static func formatMicrovolts(_ value: Double) -> String {
        guard value.isFinite else { return "nan uV" }
        if abs(value) >= 100 {
            return String(format: "%.0f uV", value)
        }
        if abs(value) >= 10 {
            return String(format: "%.1f uV", value)
        }
        return String(format: "%.2f uV", value)
    }
}
