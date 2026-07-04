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

    /// Maps an electrode impedance (kΩ) to a 0...1 goodness score using the
    /// EGI quality bands: <40 great, 40–60 good, 60–70 fair, 70+ poor. The score
    /// anchors are chosen so the resulting grade lands great/good → "good",
    /// fair → "watch", poor → "poor".
    static func scoreImpedanceKOhm(_ kOhm: Double) -> Double {
        guard kOhm.isFinite, kOhm >= 0 else { return 0 }
        switch kOhm {
        case ..<40:
            return 1.0
        case 40..<60:
            return interpolate(kOhm, fromLow: 40, fromHigh: 60, toLow: 1.0, toHigh: 0.78)
        case 60..<70:
            return interpolate(kOhm, fromLow: 60, fromHigh: 70, toLow: 0.78, toHigh: 0.50)
        default:
            return max(0, interpolate(kOhm, fromLow: 70, fromHigh: 120, toLow: 0.49, toHigh: 0.0))
        }
    }

    /// Human-readable EGI impedance band for `kOhm`.
    static func impedanceBand(_ kOhm: Double) -> String {
        guard kOhm.isFinite else { return "unknown" }
        switch kOhm {
        case ..<40:  return "great"
        case 40..<60: return "good"
        case 60..<70: return "fair"
        default:      return "poor"
        }
    }

    private static func interpolate(_ x: Double, fromLow: Double, fromHigh: Double, toLow: Double, toHigh: Double) -> Double {
        let t = (x - fromLow) / max(fromHigh - fromLow, 1e-9)
        return toLow + min(max(t, 0), 1) * (toHigh - toLow)
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
