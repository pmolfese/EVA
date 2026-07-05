//
//  MultiRecordingModels.swift
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
//  Data model for combining / grand-averaging several recordings from one
//  subject. See `RecordingCombiner` for the engine and `CombineRecordingsSheet`
//  for the UI.
//

import Foundation

enum CombineMode: String, CaseIterable, Identifiable, Sendable {
    case append
    case grandAverage

    var id: String { rawValue }
    var label: String {
        switch self {
        case .append:       return "Append"
        case .grandAverage: return "Grand Average"
        }
    }
    var detail: String {
        switch self {
        case .append:
            return "Concatenate every file's segments into one combined segmented recording (merged categories). Good for pooling trials and redistribution."
        case .grandAverage:
            return "Average each category across files into a single averaged recording with butterfly plots and per-file SNR."
        }
    }
}

enum WeightingMode: String, CaseIterable, Identifiable, Sendable {
    case equalPerFile
    case byTrialCount
    case byInverseVariance

    var id: String { rawValue }
    var label: String {
        switch self {
        case .equalPerFile:      return "Equal per file"
        case .byTrialCount:      return "By trial count"
        case .byInverseVariance: return "By measured noise (recommended)"
        }
    }
    var detail: String {
        switch self {
        case .equalPerFile:      return "Every file contributes equally regardless of trial count or quality."
        case .byTrialCount:      return "Weight each file in proportion to its number of good trials."
        case .byInverseVariance: return "Weight each file by 1/noise² (precision). Optimal when files differ in quality; reduces to trial-count weighting when noise is uniform."
        }
    }
}

enum BadChannelPolicy: String, CaseIterable, Identifiable, Sendable {
    case interpolatePerFile
    case excludePerChannel

    var id: String { rawValue }
    var label: String {
        switch self {
        case .interpolatePerFile: return "Interpolate per file"
        case .excludePerChannel:  return "Exclude per channel"
        }
    }
    var detail: String {
        switch self {
        case .interpolatePerFile:
            return "Spherical-spline interpolate each file's bad channels before averaging (keeps a full-rank average)."
        case .excludePerChannel:
            return "For each channel, average only over files where it is good — no interpolated data, at the cost of uneven per-channel N."
        }
    }
}

/// Per-category counts for the sanity table. When the file carries an `eva.xml`
/// with rejection detail, `totalTrials` > `goodTrials` and `exclusionReasons`
/// is populated; otherwise `totalTrials == goodTrials` (only survivors known).
nonisolated struct CategorySummary: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let totalTrials: Int
    let goodTrials: Int
    var exclusionReasons: [String: Int] = [:]

    var hasRejectionInfo: Bool { totalTrials > goodTrials || !exclusionReasons.isEmpty }
}

/// A compatibility problem between a file and the reference file.
enum CompatibilityFlag: Sendable, Hashable {
    case channelCountMismatch(Int, expected: Int)
    case samplingRateMismatch(Double, expected: Double)
    case epochLengthMismatch(Int, expected: Int)
    case categoryUnmatched(String)
    case notSegmented

    var message: String {
        switch self {
        case .channelCountMismatch(let n, let e): return "Channel count \(n) ≠ \(e)"
        case .samplingRateMismatch(let r, let e): return "Sampling rate \(Int(r)) ≠ \(Int(e)) Hz"
        case .epochLengthMismatch(let n, let e):  return "Epoch length \(n) ≠ \(e) samples"
        case .categoryUnmatched(let name):        return "Category “\(name)” has no match"
        case .notSegmented:                       return "Not segmented / averaged — no epochs to combine"
        }
    }
}

/// One row of the combine sanity table.
nonisolated struct RecordingSummary: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let fileName: String
    let netName: String
    let channelCount: Int
    let samplingRate: Double
    let epochLengthSamples: Int
    let isAveraged: Bool
    let categories: [CategorySummary]
    /// True when the package carries an `eva.xml` — i.e. it was preprocessed in
    /// EVA (or an upstream tool that writes the same record).
    let hasProcessingRecord: Bool
    var snr: SNRMetrics
    var compatibility: [CompatibilityFlag] = []

    var isCompatible: Bool { compatibility.isEmpty }
    var totalGoodTrials: Int { categories.reduce(0) { $0 + $1.goodTrials } }
    var totalTrials: Int { categories.reduce(0) { $0 + $1.totalTrials } }
    var hasRejectionInfo: Bool { categories.contains(where: \.hasRejectionInfo) }

    /// "excluded" totals aggregated across categories, by reason.
    var exclusionReasons: [String: Int] {
        var out: [String: Int] = [:]
        for c in categories { for (reason, n) in c.exclusionReasons { out[reason, default: 0] += n } }
        return out
    }
}

// MARK: - Category matching

/// Auto-maps category names across files by normalized equality plus a small
/// edit-distance fallback, so "Target"/"target"/"Tgt" collapse to one canonical
/// name. The user can override the result in the combine sheet.
nonisolated enum CategoryMatcher {
    /// - Returns: the canonical category list and a per-file raw→canonical map.
    static func autoMap(
        rawCategoriesByFile: [URL: [String]]
    ) -> (canonical: [String], map: [URL: [String: String]]) {
        // Canonical clusters keyed by normalized form; display name = first seen.
        var canonicalForNormalized: [String: String] = [:]
        var order: [String] = []

        // First pass: exact normalized grouping.
        for (_, names) in rawCategoriesByFile.sorted(by: { $0.key.path < $1.key.path }) {
            for name in names {
                let norm = normalize(name)
                if canonicalForNormalized[norm] == nil {
                    // Try to merge into an existing near cluster (edit distance).
                    if let near = canonicalForNormalized.keys.first(where: { editDistance($0, norm) <= 1 && !$0.isEmpty }) {
                        canonicalForNormalized[norm] = canonicalForNormalized[near]
                    } else {
                        canonicalForNormalized[norm] = name
                        order.append(name)
                    }
                }
            }
        }

        var map: [URL: [String: String]] = [:]
        for (url, names) in rawCategoriesByFile {
            var m: [String: String] = [:]
            for name in names {
                m[name] = canonicalForNormalized[normalize(name)] ?? name
            }
            map[url] = m
        }
        return (order, map)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

// MARK: - Provenance

/// Provenance recorded into the combined package's `eva.xml` + log for
/// reproducibility.
nonisolated struct CombineProvenance: Codable, Sendable {
    struct Contributor: Codable, Sendable {
        let fileName: String
        let goodTrials: Int
        let totalTrials: Int
        let weightApplied: Double
        let plusMinusSNR: Double?
        let baselineSNR: Double?
    }

    let createdAt: Date
    let mode: String
    let weighting: String
    let badChannelPolicy: String
    let rebaselined: Bool
    let contributors: [Contributor]

    /// One-line-per-contributor summary for the text log.
    func logLines() -> [String] {
        var lines = [
            "Combine: mode=\(mode), weighting=\(weighting), badChannels=\(badChannelPolicy), rebaselined=\(rebaselined)"
        ]
        for c in contributors {
            let snr = c.plusMinusSNR.map { String(format: "%.2f", $0) } ?? "n/a"
            lines.append("  • \(c.fileName): \(c.goodTrials)/\(c.totalTrials) good trials, weight=\(String(format: "%.3f", c.weightApplied)), ±SNR=\(snr)")
        }
        return lines
    }
}
