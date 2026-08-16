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

/// PSA settings that determine whether a channel is interpolated within an
/// epoch and whether an epoch is rejected because too many channels are bad.
/// All values come from the saved `segment` step in eva.xml; no defaults are
/// filled in here because the Combine sheet is intended to verify provenance,
/// not guess which settings an older file used.
nonisolated struct PSAArtifactThresholdSnapshot: Sendable, Equatable {
    let interpolatesBadChannelsPerEpoch: Bool?
    let minMicrovolts: Double?
    let maxMicrovolts: Double?
    let maxSlopeMicrovoltsPerSample: Double?
    let maxAccelerationMicrovoltsPerSample: Double?
    let maxBadChannelFraction: Double?
    let maxBadChannelCount: Int?
    let usesAbsoluteBadChannelCount: Bool?
    let escalatesBadChannelsToGlobal: Bool?
    let globalEscalationThresholdPercent: Double?

    init?(parameters: [String: String]) {
        let relevantKeys = parameters.keys.filter {
            $0 == "interpolateBadChannelsPerEpoch" || $0.hasPrefix("badChannel.")
        }
        guard !relevantKeys.isEmpty else { return nil }

        interpolatesBadChannelsPerEpoch = Self.bool(parameters["interpolateBadChannelsPerEpoch"])
        minMicrovolts = parameters["badChannel.minMicrovolts"].flatMap(Double.init)
        maxMicrovolts = parameters["badChannel.maxMicrovolts"].flatMap(Double.init)
        maxSlopeMicrovoltsPerSample = parameters["badChannel.maxSlopeMicrovoltsPerSample"].flatMap(Double.init)
        maxAccelerationMicrovoltsPerSample = parameters["badChannel.maxAccelerationMicrovoltsPerSample"].flatMap(Double.init)
        maxBadChannelFraction = parameters["badChannel.maxBadChannelFraction"].flatMap(Double.init)
        maxBadChannelCount = parameters["badChannel.maxBadChannelCount"].flatMap(Int.init)
        usesAbsoluteBadChannelCount = Self.bool(parameters["badChannel.usesAbsoluteBadChannelCount"])
        escalatesBadChannelsToGlobal = Self.bool(parameters["badChannel.escalateToGlobal"])
        globalEscalationThresholdPercent = parameters["badChannel.globalEscalationThresholdPercent"].flatMap(Double.init)
    }

    var isComplete: Bool {
        guard let interpolatesBadChannelsPerEpoch else { return false }
        guard interpolatesBadChannelsPerEpoch else { return true }
        guard minMicrovolts != nil,
              maxMicrovolts != nil,
              maxSlopeMicrovoltsPerSample != nil,
              maxAccelerationMicrovoltsPerSample != nil,
              let usesAbsoluteBadChannelCount,
              escalatesBadChannelsToGlobal != nil else { return false }
        if usesAbsoluteBadChannelCount {
            guard maxBadChannelCount != nil else { return false }
        } else {
            guard maxBadChannelFraction != nil else { return false }
        }
        if escalatesBadChannelsToGlobal == true {
            guard globalEscalationThresholdPercent != nil else { return false }
        }
        return true
    }

    /// Human-readable settings for the expanded Combine sanity check.
    var detail: String {
        guard let enabled = interpolatesBadChannelsPerEpoch else {
            return "Saved PSA interpolation toggle is missing"
        }
        guard enabled else { return "Per-epoch bad-channel interpolation off" }

        var parts: [String] = []
        if let minMicrovolts, let maxMicrovolts {
            parts.append("range \(Self.number(minMicrovolts))…\(Self.number(maxMicrovolts)) µV")
        }
        if let maxSlopeMicrovoltsPerSample {
            parts.append("slope ≤ \(Self.number(maxSlopeMicrovoltsPerSample)) µV/sample")
        }
        if let maxAccelerationMicrovoltsPerSample {
            parts.append("acceleration ≤ \(Self.number(maxAccelerationMicrovoltsPerSample)) µV/sample")
        }
        if usesAbsoluteBadChannelCount == true, let maxBadChannelCount {
            parts.append("reject epoch > \(maxBadChannelCount) bad channels")
        } else if usesAbsoluteBadChannelCount == false, let maxBadChannelFraction {
            parts.append("reject epoch > \(Self.number(maxBadChannelFraction * 100))% bad channels")
        }
        if escalatesBadChannelsToGlobal == true, let globalEscalationThresholdPercent {
            parts.append("global escalation at \(Self.number(globalEscalationThresholdPercent))% of epochs")
        } else if escalatesBadChannelsToGlobal == false {
            parts.append("global escalation off")
        }
        if !isComplete { parts.append("saved settings incomplete") }
        return parts.joined(separator: " · ")
    }

    func differingFields(from reference: Self) -> [String] {
        var fields: [String] = []
        if interpolatesBadChannelsPerEpoch != reference.interpolatesBadChannelsPerEpoch {
            fields.append("interpolation on/off")
            return fields
        }
        // Dormant values are intentionally ignored: the check compares the
        // thresholds that actually affected PSA, not stale values hidden by an
        // off toggle or by the other reject-epoch unit.
        guard interpolatesBadChannelsPerEpoch == true else { return fields }
        if minMicrovolts != reference.minMicrovolts { fields.append("minimum µV") }
        if maxMicrovolts != reference.maxMicrovolts { fields.append("maximum µV") }
        if maxSlopeMicrovoltsPerSample != reference.maxSlopeMicrovoltsPerSample { fields.append("maximum slope") }
        if maxAccelerationMicrovoltsPerSample != reference.maxAccelerationMicrovoltsPerSample { fields.append("maximum acceleration") }
        if usesAbsoluteBadChannelCount != reference.usesAbsoluteBadChannelCount {
            fields.append("reject-epoch unit")
        } else if usesAbsoluteBadChannelCount == true {
            if maxBadChannelCount != reference.maxBadChannelCount { fields.append("reject-epoch count") }
        } else if maxBadChannelFraction != reference.maxBadChannelFraction {
            fields.append("reject-epoch percentage")
        }
        if escalatesBadChannelsToGlobal != reference.escalatesBadChannelsToGlobal {
            fields.append("global escalation on/off")
        } else if escalatesBadChannelsToGlobal == true,
                  globalEscalationThresholdPercent != reference.globalEscalationThresholdPercent {
            fields.append("global escalation threshold")
        }
        return fields
    }

    private static func bool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3g", value)
    }
}

/// A compatibility problem between a file and the reference file.
enum CompatibilityFlag: Sendable, Hashable {
    case channelCountMismatch(Int, expected: Int)
    case samplingRateMismatch(Double, expected: Double)
    case epochLengthMismatch(Int, expected: Int)
    case categoryUnmatched(String)
    case channelIdentityUnresolved(ChannelMappingFailure)
    case notSegmented

    var message: String {
        switch self {
        case .channelCountMismatch(let n, let e): return "Channel count \(n) ≠ \(e)"
        case .samplingRateMismatch(let r, let e): return "Sampling rate \(Int(r)) ≠ \(Int(e)) Hz"
        case .epochLengthMismatch(let n, let e):  return "Epoch length \(n) ≠ \(e) samples"
        case .categoryUnmatched(let name):        return "Category “\(name)” has no match"
        case .channelIdentityUnresolved(let failure): return failure.message
        case .notSegmented:                       return "Not segmented / averaged — no epochs to combine"
        }
    }
}

nonisolated struct ChannelLayoutSignature: Sendable, Equatable, Hashable {
    let namesInOrder: [String]

    init(channelNames: [String]?, expectedCount: Int) {
        guard let channelNames, channelNames.count == expectedCount else {
            namesInOrder = []
            return
        }
        namesInOrder = channelNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var duplicateNames: Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for name in namesInOrder where !name.isEmpty {
            if !seen.insert(name).inserted { duplicates.insert(name) }
        }
        return duplicates
    }

    var hasUniqueNames: Bool {
        !namesInOrder.isEmpty
            && namesInOrder.allSatisfy { !$0.isEmpty }
            && duplicateNames.isEmpty
    }
}

nonisolated enum ChannelMappingFailure: Sendable, Equatable, Hashable {
    case missingNames
    case duplicateNames(Set<String>)
    case setMismatch(missing: Set<String>, extra: Set<String>)

    var message: String {
        switch self {
        case .missingNames:
            return "Channel identity unavailable — names are missing"
        case .duplicateNames(let names):
            return "Duplicate channel names: \(names.sorted().joined(separator: ", "))"
        case .setMismatch(let missing, let extra):
            var parts: [String] = []
            if !missing.isEmpty { parts.append("missing \(missing.sorted().joined(separator: ", "))") }
            if !extra.isEmpty { parts.append("extra \(extra.sorted().joined(separator: ", "))") }
            return "Channel sets differ — \(parts.joined(separator: "; "))"
        }
    }
}

nonisolated enum ChannelMappingResult: Sendable, Equatable {
    case identity
    /// `sourceIndexByReferenceIndex[referenceIndex] == sourceIndex`.
    case remapped(sourceIndexByReferenceIndex: [Int])
    case unresolved(ChannelMappingFailure)

    var isResolved: Bool {
        switch self {
        case .identity, .remapped: return true
        case .unresolved: return false
        }
    }
}

/// One row of the combine sanity table.
nonisolated struct RecordingSummary: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let fileName: String
    let netName: String
    var channelLayout = ChannelLayoutSignature(channelNames: nil, expectedCount: 0)
    let channelCount: Int
    let samplingRate: Double
    let epochLengthSamples: Int
    let isAveraged: Bool
    let categories: [CategorySummary]
    /// True when the package carries an `eva.xml` — i.e. it was preprocessed in
    /// EVA (or an upstream tool that writes the same record).
    let hasProcessingRecord: Bool
    /// Saved PSA bad-channel/reject-epoch settings, when eva.xml records them.
    var psaArtifactThresholds: PSAArtifactThresholdSnapshot? = nil
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
                    if let near = canonicalForNormalized.keys.first(where: { shouldFuzzyMerge($0, norm) }) {
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

    private static func shouldFuzzyMerge(_ a: String, _ b: String) -> Bool {
        let minLength = min(a.count, b.count)
        guard minLength >= 5, !a.isEmpty, !b.isEmpty else { return false }
        return editDistance(a, b) <= 1
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
