//
//  GradientDonorSelection.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Independent implementation written from EVA's own functional specification
//  (docs/provenance/fastr-functional-spec.md) under the clean-room process
//  described in docs/provenance/README.md. No third-party artifact-correction source
//  was consulted.
//
//  Chooses which artifact epochs contribute to the template subtracted from a
//  given target epoch. Three families are supported: nearest-in-time,
//  motion-informed, and waveform-correlation ranking.
//

import Foundation

nonisolated enum GradientDonorSelection {

    // MARK: - Motion magnitude

    /// Per-volume motion magnitude in mm.
    ///
    /// This is framewise displacement — the volume-to-volume *change* in the
    /// rigid-body parameters — because the purpose of the motion-informed
    /// strategy is to avoid averaging across motion *events*. `allParameters`
    /// delegates to EVA's existing `MotionParameters.framewiseDisplacement`
    /// (Power et al. 2012) so there is a single definition in the codebase;
    /// `translationOnly` is the translation terms of that same sum. Volume 0
    /// has no predecessor and is defined as 0.
    static func motionMagnitudes(
        motion: [MotionSample],
        metric: GradientMotionMetric,
        radiusMm: Double
    ) -> [Double] {
        switch metric {
        case .allParameters:
            let parameters = MotionParameters(samples: motion, sourceName: "")
            return parameters.framewiseDisplacement(radiusMm: radiusMm)
        case .translationOnly:
            guard motion.count > 1 else { return [Double](repeating: 0, count: motion.count) }
            var magnitudes = [Double](repeating: 0, count: motion.count)
            for i in 1..<motion.count {
                let current = motion[i]
                let previous = motion[i - 1]
                magnitudes[i] = abs(current.dS - previous.dS)
                    + abs(current.dL - previous.dL)
                    + abs(current.dP - previous.dP)
            }
            return magnitudes
        }
    }

    /// Aligns a motion file to the recording's volume count.
    ///
    /// A short file is assumed to be missing dummy scans that were dropped from
    /// the front, so it is front-padded with zero-motion rows; a long file has
    /// its trailing rows ignored. Both cases are reported.
    static func alignMotionToVolumes(
        motion: [MotionSample],
        volumeCount: Int
    ) -> (samples: [MotionSample], warnings: [GradientCorrectionWarning]) {
        guard !motion.isEmpty else { return ([], []) }
        if motion.count == volumeCount { return (motion, []) }

        if motion.count < volumeCount {
            let missing = volumeCount - motion.count
            let padding = (0..<missing).map { index in
                MotionSample(id: index, roll: 0, pitch: 0, yaw: 0, dS: 0, dL: 0, dP: 0)
            }
            let shifted = motion.enumerated().map { offset, sample in
                MotionSample(
                    id: missing + offset,
                    roll: sample.roll, pitch: sample.pitch, yaw: sample.yaw,
                    dS: sample.dS, dL: sample.dL, dP: sample.dP
                )
            }
            return (padding + shifted, [.motionRowsFrontPadded(count: missing)])
        }

        let extra = motion.count - volumeCount
        return (Array(motion.prefix(volumeCount)), [.motionRowsTruncated(count: extra)])
    }

    /// Volumes whose motion magnitude exceeds `thresholdMm`.
    static func highMotionVolumes(
        motion: [MotionSample],
        metric: GradientMotionMetric,
        thresholdMm: Double,
        radiusMm: Double
    ) -> Set<Int> {
        let magnitudes = motionMagnitudes(motion: motion, metric: metric, radiusMm: radiusMm)
        var volumes: Set<Int> = []
        for (index, magnitude) in magnitudes.enumerated() where magnitude > thresholdMm {
            volumes.insert(index)
        }
        return volumes
    }

    // MARK: - Temporal neighbors

    /// The `desired` eligible epochs nearest in time to `target`.
    ///
    /// Edge policy is saturation: the search expands outward one step at a time
    /// and keeps going on whichever side still has epochs, so an epoch at the
    /// start of the recording draws its full donor count from later epochs
    /// rather than returning a short list. When two candidates are equidistant
    /// the earlier one is taken first, which makes the result deterministic.
    static func nearestTemporalDonors(
        target: Int,
        epochCount: Int,
        desired: Int,
        allowsSelfDonation: Bool,
        isEligible: (Int) -> Bool
    ) -> [Int] {
        guard desired > 0, epochCount > 0 else { return [] }
        var donors: [Int] = []
        donors.reserveCapacity(desired)

        if allowsSelfDonation, isEligible(target) { donors.append(target) }

        var offset = 1
        while donors.count < desired, offset < epochCount {
            for candidate in [target - offset, target + offset] {
                guard donors.count < desired else { break }
                guard candidate >= 0, candidate < epochCount else { continue }
                guard candidate != target else { continue }
                guard isEligible(candidate) else { continue }
                donors.append(candidate)
            }
            offset += 1
        }
        return donors.sorted()
    }

    // MARK: - Motion-informed

    /// Donor *volumes* for every volume, avoiding high-motion volumes both as
    /// donors and as barriers to average across.
    ///
    /// Returns `nil` when no volume exceeds the threshold — with no motion
    /// events there is nothing for this strategy to do, and the caller should
    /// use temporal neighbors instead.
    static func motionInformedDonorVolumes(
        volumeCount: Int,
        highMotion: Set<Int>,
        censored: Set<Int>,
        desired: Int
    ) -> (donors: [[Int]], crossedBarrier: Set<Int>)? {
        guard !highMotion.isEmpty, volumeCount > 0, desired > 0 else { return nil }

        var donors: [[Int]] = []
        donors.reserveCapacity(volumeCount)
        var crossedBarrier: Set<Int> = []

        func ineligible(_ volume: Int) -> Bool {
            highMotion.contains(volume) || censored.contains(volume)
        }

        for target in 0..<volumeCount {
            var picked: [Int] = []
            var left = target - 1
            var right = target + 1
            var leftBlocked = false
            var rightBlocked = false

            // Walk outward, but treat a high-motion volume as a wall: once a
            // side hits one, that side contributes nothing further.
            while picked.count < desired, !leftBlocked || !rightBlocked {
                if !leftBlocked {
                    if left < 0 || highMotion.contains(left) {
                        leftBlocked = true
                    } else {
                        if !censored.contains(left) { picked.append(left) }
                        left -= 1
                    }
                }
                guard picked.count < desired else { break }
                if !rightBlocked {
                    if right >= volumeCount || highMotion.contains(right) {
                        rightBlocked = true
                    } else {
                        if !censored.contains(right) { picked.append(right) }
                        right += 1
                    }
                }
            }

            // Not enough donors inside the motion-free neighborhood: relax the
            // barrier rule rather than under-average, and say so.
            if picked.count < desired {
                var offset = 1
                var pickedSet = Set(picked)
                while picked.count < desired, offset < volumeCount {
                    for candidate in [target - offset, target + offset] {
                        guard picked.count < desired else { break }
                        guard candidate >= 0, candidate < volumeCount else { continue }
                        guard candidate != target, !ineligible(candidate) else { continue }
                        guard !pickedSet.contains(candidate) else { continue }
                        picked.append(candidate)
                        pickedSet.insert(candidate)
                        crossedBarrier.insert(target)
                    }
                    offset += 1
                }
            }

            donors.append(picked.sorted())
        }

        return (donors, crossedBarrier)
    }

    // MARK: - Correlation ranking

    /// Pearson correlation of two equal-length waveforms after mean removal.
    /// Returns 0 when either waveform is flat.
    static func pearsonCorrelation(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in
                pearsonCorrelation(left.baseAddress!, right.baseAddress!, count: a.count)
            }
        }
    }

    /// Same computation over two windows of a larger buffer, so a batched caller
    /// does not have to copy every candidate out into its own array.
    static func pearsonCorrelation(
        _ a: UnsafePointer<Float>,
        _ b: UnsafePointer<Float>,
        count: Int
    ) -> Double {
        guard count > 0 else { return 0 }
        var meanA = 0.0
        var meanB = 0.0
        for i in 0..<count {
            meanA += Double(a[i])
            meanB += Double(b[i])
        }
        meanA /= Double(count)
        meanB /= Double(count)

        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for i in 0..<count {
            let da = Double(a[i]) - meanA
            let db = Double(b[i]) - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        let denominator = (varianceA * varianceB).squareRoot()
        guard denominator > 1e-20 else { return 0 }
        return covariance / denominator
    }

    /// A scored correlation candidate, before ranking.
    nonisolated struct ScoredCandidate: Sendable {
        let epoch: Int
        let score: Double
        /// Volumes between the candidate and the target — the first tie-break.
        let distance: Int
    }

    /// Candidate epochs for correlation ranking, in the order they are scored.
    ///
    /// Candidates are drawn from epochs at the same slice position, within
    /// `searchWindow` volumes on either side — the window bounds what would
    /// otherwise be a quadratic search over every epoch in the recording.
    ///
    /// Eligibility depends only on the epoch grid and on censoring, never on the
    /// channel, so a batched caller can build this list once and reuse it for
    /// every channel.
    static func correlationCandidates(
        target: Int,
        layout: GradientEpochLayout,
        isEligible: (Int) -> Bool,
        searchWindow: Int
    ) -> [(candidate: Int, distance: Int)] {
        let targetVolume = layout.volumeIndex[target]
        let slice = layout.slicePosition[target]
        var candidates: [(candidate: Int, distance: Int)] = []
        for offset in 1...max(1, searchWindow) {
            for volume in [targetVolume - offset, targetVolume + offset] {
                guard volume >= 0, volume < layout.volumeCount else { continue }
                guard let candidate = layout.epochIndex(volume: volume, slicePosition: slice) else { continue }
                guard candidate != target, isEligible(candidate) else { continue }
                candidates.append((candidate, offset))
            }
        }
        return candidates
    }

    /// Turns scored candidates into a donor list.
    ///
    /// Under `squared` ranking every candidate competes on r², so a strongly
    /// anti-correlated epoch ranks as highly as a strongly correlated one. Under
    /// plain correlation ranking (FARM-style) a candidate must reach `threshold`
    /// to qualify, and too few qualifying candidates reports `fellBack` so the
    /// caller can use temporal neighbors instead.
    ///
    /// Scores arrive already quantized by `GradientTemplateCorrector.quantized`.
    /// Ranking is a discrete decision, and a score computed to a different last
    /// bit on a different backend must not reorder the donor set; rounding first
    /// is what makes the tie-breaks — proximity in time, then epoch index — decide
    /// those cases identically everywhere.
    static func rankCorrelationDonors(
        _ scored: [ScoredCandidate],
        squared: Bool,
        threshold: Double,
        minimumQualified: Int,
        desired: Int
    ) -> (donors: [Int], fellBack: Bool) {
        guard !scored.isEmpty else { return ([], true) }
        var ranked = scored

        if !squared {
            let qualified = ranked.filter { $0.score >= threshold }
            guard qualified.count >= min(minimumQualified, desired) else { return ([], true) }
            ranked = qualified
        }

        // Highest score first; ties resolved by proximity in time, then by epoch
        // index, so the selection is fully deterministic.
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.epoch < rhs.epoch
        }

        return (ranked.prefix(desired).map(\.epoch).sorted(), false)
    }

    /// Donors ranked by waveform similarity to the target.
    ///
    /// Candidates are drawn from epochs at the same slice position, within
    /// `searchWindow` volumes on either side — the window bounds what would
    /// otherwise be a quadratic search over every epoch in the recording.
    ///
    /// Under `squared` ranking the score is r², so a strongly anti-correlated
    /// epoch ranks as highly as a strongly correlated one, and the target may be
    /// its own donor if `allowsSelfDonation` is set. Under plain correlation
    /// ranking (FARM-style) a candidate must reach `threshold` to qualify, the
    /// target is never its own donor, and too few qualifying candidates reports
    /// `fellBack` so the caller can use temporal neighbors instead.
    static func correlationRankedDonors(
        target: Int,
        layout: GradientEpochLayout,
        waveform: (Int) -> [Float]?,
        isEligible: (Int) -> Bool,
        squared: Bool,
        threshold: Double,
        minimumQualified: Int,
        desired: Int,
        searchWindow: Int,
        allowsSelfDonation: Bool
    ) -> (donors: [Int], fellBack: Bool) {
        guard desired > 0, let targetWave = waveform(target) else { return ([], true) }

        var scored: [ScoredCandidate] = []
        if squared, allowsSelfDonation, isEligible(target) {
            scored.append(ScoredCandidate(epoch: target, score: 1, distance: 0))
        }

        for (candidate, distance) in correlationCandidates(
            target: target, layout: layout, isEligible: isEligible, searchWindow: searchWindow
        ) {
            guard let candidateWave = waveform(candidate) else { continue }
            let r = pearsonCorrelation(targetWave, candidateWave)
            scored.append(ScoredCandidate(
                epoch: candidate,
                score: GradientTemplateCorrector.quantized(squared ? r * r : r),
                distance: distance
            ))
        }

        return rankCorrelationDonors(
            scored,
            squared: squared,
            threshold: threshold,
            minimumQualified: minimumQualified,
            desired: desired
        )
    }
}
