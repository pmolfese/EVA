//
//  GradientRemover.swift
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
//  Swift translation of nimh-sfim/gradient_remover (GradientRemover.py).
//  Upstream author: Joshua Teves. No upstream license was found; see
//  THIRD_PARTY_NOTICES.md.
//
//  Removes MR gradient artifact from simultaneous EEG/fMRI recordings using a
//  per-TR template: each TR-length segment is linearly detrended, a template is
//  built from a weighted average of neighboring detrended TRs, and that template
//  is subtracted from the segment.
//
//  TR onsets are the evenly spaced scanner volume triggers — in EGI MFF files
//  these are the `TREV` events.
//
//  Each channel is corrected independently, so the work is run across all CPU
//  cores, and the per-segment math uses Accelerate (vDSP).
//

import Accelerate
import Foundation

enum GradientRemoverError: LocalizedError {
    case noTRTriggers
    case tooFewTRTriggers(Int)
    case unevenSpacing(spacings: [Int])
    case triggersBeyondData(lastSample: Int, sampleCount: Int)

    var errorDescription: String? {
        switch self {
        case .noTRTriggers:
            return "No TREV trigger events were found, so no gradient template could be built."
        case .tooFewTRTriggers(let count):
            return "Only \(count) usable TREV triggers were found — not enough to build a gradient template."
        case .unevenSpacing(let spacings):
            let list = spacings.map(String.init).joined(separator: ", ")
            return "TREV triggers are not evenly spaced (sample gaps: \(list)). Gradient removal requires regularly spaced TR triggers."
        case .triggersBeyondData(let lastSample, let sampleCount):
            return "The first TR trigger falls at sample \(lastSample) but the recording only has \(sampleCount) samples."
        }
    }
}

struct GradientRemover {
    /// Number of neighboring TRs averaged into the template, before and after
    /// the current TR. Mirrors the Python `window=(4, 4)` default.
    struct Window {
        var before: Int
        var after: Int
        nonisolated static let `default` = Window(before: 4, after: 4)
    }

    /// Runs gradient correction on `channels` (shape: channels × time).
    ///
    /// - Parameters:
    ///   - channels: Raw EEG, one array of samples per channel.
    ///   - trSamples: Sample indices of TR (volume) triggers, sorted ascending.
    ///     Assumed evenly spaced; spacing is taken from the median gap.
    ///   - window: Template window sizes before/after the current TR.
    ///   - spacingTolerance: Max allowed deviation (in samples) of any gap from
    ///     the median before the triggers are rejected as uneven.
    ///   - progress: Optional callback invoked with a 0...1 completion fraction.
    ///     Called from worker threads, so the handler must be thread-safe.
    /// - Returns: Corrected channels, same shape as the input.
    /// - Parameters:
    ///   - excludedTRs: TR indices to exclude as *donors* when averaging the
    ///     template (e.g. high-motion volumes). Excluded TRs are still corrected;
    ///     they just don't contaminate other TRs' templates. Empty = no change.
    nonisolated static func correct(
        channels: [[Float]],
        trSamples: [Int],
        window: Window = .default,
        spacingTolerance: Int = 1,
        excludedTRs: Set<Int> = [],
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [[Float]] {
        guard trSamples.count >= 2 else { throw GradientRemoverError.tooFewTRTriggers(trSamples.count) }

        // Determine an evenly spaced TR grid from the trigger gaps.
        let diffs = zip(trSamples.dropFirst(), trSamples).map { $0 - $1 }
        let spacing = median(of: diffs)
        guard spacing > 0 else { throw GradientRemoverError.unevenSpacing(spacings: uniqueSorted(diffs)) }
        if let worst = diffs.map({ abs($0 - spacing) }).max(), worst > spacingTolerance {
            throw GradientRemoverError.unevenSpacing(spacings: uniqueSorted(diffs))
        }

        let sampleCount = channels.first?.count ?? 0
        let offset = trSamples[0]
        guard offset >= 0, offset + spacing <= sampleCount else {
            throw GradientRemoverError.triggersBeyondData(lastSample: offset + spacing, sampleCount: sampleCount)
        }

        // Only correct whole TRs that fit within the recording; the last TREV
        // trigger often lacks a full volume of data after it, and a trailing
        // partial volume is left untouched.
        let fittableTR = (sampleCount - offset) / spacing
        let nTR = min(trSamples.count, fittableTR)
        guard nTR >= window.before + window.after else {
            throw GradientRemoverError.tooFewTRTriggers(nTR)
        }

        let channelCount = channels.count
        let weightBefore = Float(window.before) / Float(window.before + window.after)
        let weightAfter = Float(window.after) / Float(window.before + window.after)

        var result = channels

        // Progress accounting across parallel workers.
        let progressLock = NSLock()
        var completed = 0
        let reportEvery = max(1, channelCount / 100)

        result.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct index, so concurrent writes don't
            // overlap; the buffer pointer is shared read-only metadata.
            nonisolated(unsafe) let out = out
            DispatchQueue.concurrentPerform(iterations: channelCount) { c in
                out[c] = correctChannel(
                    channels[c],
                    offset: offset,
                    spacing: spacing,
                    nTR: nTR,
                    window: window,
                    weightBefore: weightBefore,
                    weightAfter: weightAfter,
                    excludedTRs: excludedTRs
                )

                if let progress {
                    progressLock.lock()
                    completed += 1
                    let done = completed
                    progressLock.unlock()
                    if done % reportEvery == 0 || done == channelCount {
                        progress(Double(done) / Double(channelCount))
                    }
                }
            }
        }

        return result
    }

    /// Corrects a single channel: detrend every TR, then subtract the
    /// neighbor-averaged template TR by TR.
    nonisolated private static func correctChannel(
        _ channel: [Float],
        offset: Int,
        spacing: Int,
        nTR: Int,
        window: Window,
        weightBefore: Float,
        weightAfter: Float,
        excludedTRs: Set<Int> = []
    ) -> [Float] {
        // Detrend every TR segment once (Python caches detrended TRs lazily).
        var detrended = [[Float]]()
        detrended.reserveCapacity(nTR)
        for n in 0..<nTR {
            let start = offset + n * spacing
            detrended.append(linearDetrend(Array(channel[start..<(start + spacing)])))
        }

        var row = channel
        var template = [Float](repeating: 0, count: spacing)
        var corrected = [Float](repeating: 0, count: spacing)

        for n in 0..<nTR {
            let start = offset + n * spacing

            // Edge TRs get no template (Python `get_tr_template`): detrended only.
            //
            // Upstream guard was `n > (n_tr - window.after)`, which paired with
            // the original (buggy) narrow "after" range. We widen the "after"
            // range below to be symmetric with "before", so the last templated TR
            // now reaches detrended[n + window.after]; the guard is tightened to
            // `n > nTR - window.after - 1` to keep that access in bounds.
            // See the correctness note on the "after" accumulation below.
            if n < window.before || n > (nTR - window.after - 1) {
                row.replaceSubrange(start..<(start + spacing), with: detrended[n])
                continue
            }

            // Donor TR indices on each side, dropping excluded (e.g. high-motion)
            // TRs. When `excludedTRs` is empty these are the full ranges, so the
            // template is identical to the unfiltered case.
            let beforeIdx = ((n - window.before)..<n).filter { !excludedTRs.contains($0) }
            let afterIdx = ((n + 1)..<(n + window.after + 1)).filter { !excludedTRs.contains($0) }

            // If both sides are fully censored, leave the TR detrended (as at the
            // edges) — better than subtracting an empty template.
            if beforeIdx.isEmpty && afterIdx.isEmpty {
                row.replaceSubrange(start..<(start + spacing), with: detrended[n])
                continue
            }

            // Renormalize weights when one side has no surviving donors so the
            // template amplitude stays correct.
            let wB: Float
            let wA: Float
            if !beforeIdx.isEmpty && !afterIdx.isEmpty {
                wB = weightBefore; wA = weightAfter
            } else if !beforeIdx.isEmpty {
                wB = 1; wA = 0
            } else {
                wB = 0; wA = 1
            }

            // template = wB * mean(before TRs) + wA * mean(after TRs)
            for i in 0..<spacing { template[i] = 0 }
            if wB > 0 {
                accumulateMean(of: detrended, indices: beforeIdx, scale: wB, into: &template)
            }
            // CORRECTNESS FIX (diverges from upstream Python on purpose):
            // The reference gradient_remover computes the "after" part as
            //   self._get_tr_template_part(n + 1, n + self.window[1] - 1)
            // i.e. range(n+1, n+window.after-1), which averages only
            // window.after - 2 TRs (just 2 of the intended 4 with the default
            // window). That is an off-by-one: weight_after is window.after /
            // (window.before + window.after) = 0.5, sized for window.after TRs,
            // and the "before" side uses the full window.before TRs — so the
            // template is asymmetric and under-counts post-volumes.
            // We use range(n+1 ..< n+window.after+1) → the full window.after TRs,
            // symmetric with "before". (Verified against
            // github.com/nimh-sfim/gradient_remover GradientRemover.py, main.)
            if wA > 0 {
                accumulateMean(of: detrended, indices: afterIdx, scale: wA, into: &template)
            }

            // corrected = detrended[n] - template
            vDSP.subtract(detrended[n], template, result: &corrected)
            row.replaceSubrange(start..<(start + spacing), with: corrected)
        }

        return row
    }

    /// Adds `scale * mean(segments[indices])` into `accumulator` (element-wise).
    nonisolated private static func accumulateMean(
        of segments: [[Float]],
        indices: [Int],
        scale: Float,
        into accumulator: inout [Float]
    ) {
        guard !indices.isEmpty else { return }
        let factor = scale / Float(indices.count)
        for tr in indices {
            // accumulator += factor * segments[tr]
            vDSP.add(multiplication: (segments[tr], factor), accumulator, result: &accumulator)
        }
    }

    /// Least-squares linear detrend of a single channel segment
    /// (scipy.signal.detrend, type="linear"), using Accelerate.
    nonisolated private static func linearDetrend(_ x: [Float]) -> [Float] {
        let n = x.count
        guard n > 1 else { return x }

        let nF = Float(n)
        let sumT = nF * (nF - 1) / 2
        let sumTT = (nF - 1) * nF * (2 * nF - 1) / 6
        let sumY = vDSP.sum(x)

        // sumTY = Σ t * x[t]
        var ramp = [Float](repeating: 0, count: n)
        var start: Float = 0
        var step: Float = 1
        vDSP_vramp(&start, &step, &ramp, 1, vDSP_Length(n))
        let sumTY = vDSP.sum(vDSP.multiply(ramp, x))

        let denom = nF * sumTT - sumT * sumT
        guard denom != 0 else { return x }
        let b = (nF * sumTY - sumT * sumY) / denom
        let a = (sumY - b * sumT) / nF

        // line[t] = a + b*t  (reuse the ramp buffer), then result = x - line.
        var lineStart = a
        var lineStep = b
        vDSP_vramp(&lineStart, &lineStep, &ramp, 1, vDSP_Length(n))
        return vDSP.subtract(x, ramp)
    }

    nonisolated private static func median(of values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    nonisolated private static func uniqueSorted(_ values: [Int]) -> [Int] {
        Array(Set(values)).sorted()
    }
}
