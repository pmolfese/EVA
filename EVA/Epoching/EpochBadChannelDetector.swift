//
//  EpochBadChannelDetector.swift
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
//  L3 engine: per-epoch bad-channel detection + interpolation. Distinct from
//  ChannelHealthAnalyzer (whole-recording, ratio-vs-median scoring) — this uses
//  absolute thresholds over one short epoch window, to catch transient
//  per-trial artifacts (a channel that's fine overall but spikes in ONE trial).
//

import Foundation

/// Absolute per-epoch bad-channel thresholds. Unlike `ChannelBaseMetricSettings`
/// (whole-recording, ratio-vs-median), these are literal µV bounds over one
/// epoch window — appropriate for a window too short for a stable median.
nonisolated struct EpochBadChannelThresholds: Codable, Sendable, Equatable {
    /// Minimum allowed sample value (µV) anywhere in the epoch.
    var minMicrovolts: Double = -150
    /// Maximum allowed sample value (µV) anywhere in the epoch.
    var maxMicrovolts: Double = 150
    /// Maximum allowed |sample-to-sample change| (µV) — catches sharp steps.
    var maxSlopeMicrovoltsPerSample: Double = 25
    /// Maximum allowed |change in slope| (µV) — catches spikes distinct from a
    /// fast but smooth ramp.
    var maxAccelerationMicrovoltsPerSample: Double = 15
    /// If more than this fraction of channels are flagged bad within one
    /// epoch, the whole epoch is rejected instead of interpolated — it's
    /// treated as too messy to trust rather than papered over with a spline
    /// fit from a shrinking pool of "good" neighbors. This also skips the
    /// (expensive) interpolation step entirely for epochs that would be
    /// discarded anyway. Fraction of the net's channel count, default 10%.
    /// Used unless `usesAbsoluteBadChannelCount` is on.
    var maxBadChannelFraction: Double = 0.10
    /// Same reject-epoch threshold as `maxBadChannelFraction`, but as a literal
    /// channel count rather than a fraction of the net — useful when comparing
    /// recordings across different nets/channel counts where a fixed number of
    /// bad channels matters more than a fixed proportion. Used only when
    /// `usesAbsoluteBadChannelCount` is on.
    var maxBadChannelCount: Int = 13
    /// Whether the reject-epoch threshold above is read from
    /// `maxBadChannelCount` (true) or `maxBadChannelFraction` (false, default).
    var usesAbsoluteBadChannelCount: Bool = false

    // MARK: - Flat eva.xml parameters

    /// Emits each threshold as its own prefixed key so Copy Processing and
    /// exported `eva.xml` stay readable without needing a JSON payload.
    func flatParameters(prefix: String) -> [String: String] {
        [
            "\(prefix).minMicrovolts": Self.num(minMicrovolts),
            "\(prefix).maxMicrovolts": Self.num(maxMicrovolts),
            "\(prefix).maxSlopeMicrovoltsPerSample": Self.num(maxSlopeMicrovoltsPerSample),
            "\(prefix).maxAccelerationMicrovoltsPerSample": Self.num(maxAccelerationMicrovoltsPerSample),
            "\(prefix).maxBadChannelFraction": Self.num(maxBadChannelFraction),
            "\(prefix).maxBadChannelCount": "\(maxBadChannelCount)",
            "\(prefix).usesAbsoluteBadChannelCount": "\(usesAbsoluteBadChannelCount)"
        ]
    }

    /// Rebuilds thresholds from flat params, keeping `base` for missing keys so
    /// older `eva.xml` files remain replayable.
    static func fromFlatParameters(
        _ p: [String: String],
        prefix: String,
        base: EpochBadChannelThresholds
    ) -> EpochBadChannelThresholds {
        var t = base
        if let v = p["\(prefix).minMicrovolts"].flatMap(Double.init) { t.minMicrovolts = v }
        if let v = p["\(prefix).maxMicrovolts"].flatMap(Double.init) { t.maxMicrovolts = v }
        if let v = p["\(prefix).maxSlopeMicrovoltsPerSample"].flatMap(Double.init) { t.maxSlopeMicrovoltsPerSample = v }
        if let v = p["\(prefix).maxAccelerationMicrovoltsPerSample"].flatMap(Double.init) { t.maxAccelerationMicrovoltsPerSample = v }
        if let v = p["\(prefix).maxBadChannelFraction"].flatMap(Double.init) { t.maxBadChannelFraction = v }
        if let v = p["\(prefix).maxBadChannelCount"].flatMap(Int.init) { t.maxBadChannelCount = v }
        if let v = p["\(prefix).usesAbsoluteBadChannelCount"] { t.usesAbsoluteBadChannelCount = (v == "true") }
        return t
    }

    private static func num(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// Thread-safe cache of spherical-spline interpolation weights, keyed by
/// (target channel, sorted good-channel set). The weights returned by
/// `SphericalSpline.interpolationWeights` are a pure function of that pair
/// (positions/order/terms/lambda are fixed for a given recording) — but
/// computing them means solving an (n+1)×(n+1) linear system with a naive
/// O(n³) Gauss-Jordan elimination (no Accelerate/LAPACK), where n is the good-
/// channel count (~100-250). In practice the SAME (target, good-set) pair
/// recurs across most epochs — a flaky channel tends to be flagged bad in
/// most/all trials, not a different random set each time — so caching turns
/// an O(n³) solve into an O(1) lookup for every epoch after the first one
/// that sees a given bad-channel combination. Shared across the parallel
/// per-epoch workers in `PSABuildJob.buildEpochs()`.
final class SphericalSplineWeightCache: @unchecked Sendable {
    private var storage: [String: (indices: [Int], weights: [Double])] = [:]
    private let lock = NSLock()

    private static func key(target: Int, good: [Int]) -> String {
        "\(target)|\(good.sorted().map(String.init).joined(separator: ","))"
    }

    func weights(
        target: Int, good: [Int], positions: [Int: SIMD3<Double>]
    ) -> (indices: [Int], weights: [Double])? {
        weights(targets: [target], good: good, positions: positions)[target]
    }

    /// Batched lookup for several targets sharing the SAME `good` set (the
    /// common case: several channels bad in the same epoch). Cache hits
    /// return immediately; misses are solved TOGETHER via one shared LU
    /// factorization (`SphericalSpline.interpolationWeightsBatch`) instead of
    /// one independent O(n³) solve per miss — the "shared factorization"
    /// optimization stacked on top of the cross-epoch cache.
    func weights(
        targets: [Int], good: [Int], positions: [Int: SIMD3<Double>]
    ) -> [Int: (indices: [Int], weights: [Double])] {
        var result: [Int: (indices: [Int], weights: [Double])] = [:]
        var missing: [Int] = []

        lock.lock()
        for target in targets {
            if let cached = storage[Self.key(target: target, good: good)] {
                result[target] = cached
            } else {
                missing.append(target)
            }
        }
        lock.unlock()

        guard !missing.isEmpty else { return result }

        let solved = SphericalSpline.interpolationWeightsBatch(targets: missing, good: good, positions: positions)

        lock.lock()
        for (target, value) in solved {
            storage[Self.key(target: target, good: good)] = value
        }
        lock.unlock()

        result.merge(solved) { current, _ in current }
        return result
    }
}

nonisolated enum EpochBadChannelDetector {
    /// Flags channels whose min/max, slope, or acceleration within `range`
    /// exceed `thresholds`. `data` is indexed by channel; `range` is the
    /// sample window (shared across channels) to evaluate.
    static func detectBadChannels(
        in data: [[Float]],
        range: Range<Int>,
        thresholds: EpochBadChannelThresholds,
        excluding: Set<Int> = []
    ) -> Set<Int> {
        guard range.count > 1 else { return [] }
        var bad = Set<Int>()
        for index in data.indices where !excluding.contains(index) {
            let channel = data[index]
            guard range.upperBound <= channel.count else { continue }

            var minValue = channel[range.lowerBound]
            var maxValue = minValue
            var maxSlope: Float = 0
            var maxAcceleration: Float = 0
            var previousSlope: Float?

            for sample in (range.lowerBound + 1)..<range.upperBound {
                let value = channel[sample]
                if value < minValue { minValue = value }
                if value > maxValue { maxValue = value }

                let slope = abs(value - channel[sample - 1])
                if slope > maxSlope { maxSlope = slope }
                if let previousSlope {
                    let acceleration = abs(slope - previousSlope)
                    if acceleration > maxAcceleration { maxAcceleration = acceleration }
                }
                previousSlope = slope
            }

            if Double(minValue) < thresholds.minMicrovolts
                || Double(maxValue) > thresholds.maxMicrovolts
                || Double(maxSlope) > thresholds.maxSlopeMicrovoltsPerSample
                || Double(maxAcceleration) > thresholds.maxAccelerationMicrovoltsPerSample {
                bad.insert(index)
            }
        }
        return bad
    }

    /// Interpolates `badChannels` within `range` only (leaves the rest of each
    /// channel's data untouched), using spherical-spline weights computed from
    /// the epoch's good channels (globally good AND not flagged bad in this
    /// epoch). Channels with no electrode position are skipped (left as-is).
    static func interpolate(
        badChannels: Set<Int>,
        in data: inout [[Float]],
        range: Range<Int>,
        positions: [Int: SIMD3<Double>],
        excludingGloballyBad: Set<Int>,
        weightCache: SphericalSplineWeightCache? = nil
    ) {
        guard !badChannels.isEmpty, range.count > 1 else { return }
        let good = data.indices.filter {
            !badChannels.contains($0) && !excludingGloballyBad.contains($0) && positions[$0] != nil
        }
        guard !good.isEmpty else { return }

        // Batched, not per-target: when an epoch has several bad channels
        // they all share this SAME good-set, so solving them together lets
        // the cache (or SphericalSpline.interpolationWeightsBatch on a miss)
        // factor the shared system matrix once instead of once per channel.
        let targets = badChannels.filter { positions[$0] != nil }
        guard !targets.isEmpty else { return }
        let resolvedByTarget = weightCache?.weights(targets: Array(targets), good: good, positions: positions)
            ?? SphericalSpline.interpolationWeightsBatch(targets: Array(targets), good: good, positions: positions)

        for target in targets {
            guard let (indices, weights) = resolvedByTarget[target] else { continue }

            var series = [Float](repeating: 0, count: range.count)
            for (channelIndex, weight) in zip(indices, weights) {
                guard data.indices.contains(channelIndex), range.upperBound <= data[channelIndex].count else { continue }
                let source = data[channelIndex]
                let w = Float(weight)
                for (offset, sample) in range.enumerated() {
                    series[offset] += w * source[sample]
                }
            }
            for (offset, sample) in range.enumerated() {
                data[target][sample] = series[offset]
            }
        }
    }
}
