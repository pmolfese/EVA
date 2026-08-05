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
//  built from neighboring detrended TRs, and that template is subtracted from
//  (AAS/MAS) or regressed out of (MAR) the segment.
//
//  TR onsets are the evenly spaced scanner volume triggers — in EGI MFF files
//  these are the `TREV` events.
//
//  Each channel is corrected independently, so the work is run across all CPU
//  cores, and the per-segment math uses Accelerate (vDSP).
//
//  MAS/MAR (median-reduced template, with optional regression fit instead of
//  plain subtraction) are inspired by the same-named methods in `amri_eeg_gac.m`
//  from the Advanced MRI (AMRI) section, NINDS, NIH MATLAB toolbox
//  (https://amri.ninds.nih.gov/software.html; GPL-3.0), itself implementing:
//  Liu Z, de Zwart JA, van Gelderen P, Kuo L-W, Duyn JH. Statistical feature
//  extraction for artifact removal from concurrent fMRI-EEG recordings.
//  NeuroImage (2012), 59(3): 2073-2087. See THIRD_PARTY_NOTICES.md.
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
    enum ComputeBackend: String, Sendable {
        case cpu
        case metal
    }

    /// Number of neighboring TRs averaged into the template, before and after
    /// the current TR. Mirrors the Python `window=(4, 4)` default.
    struct Window {
        var before: Int
        var after: Int
        nonisolated static let `default` = Window(before: 4, after: 4)
    }

    /// How the neighboring-TR template is combined. `.weightedMean` is the
    /// original AAS behavior (before/after weighted by window size);
    /// `.median` (MAS/MAR) takes the elementwise median across the combined
    /// before+after donor TRs, which is more robust to an occasional
    /// corrupted donor volume than a mean ever can be.
    enum TemplateReducer: Sendable {
        case weightedMean
        case median
    }

    /// Whether the template is subtracted as-is (AAS/MAS) or scaled by a
    /// least-squares fit before subtracting (AAR/MAR) — the fit lets the
    /// template's amplitude adapt to slow gradient-artifact drift that a
    /// fixed 1:1 subtraction can't track. Fit direction matches
    /// `amri_eeg_gac.m`'s AAR/MAR: `k = dot(y, template) / dot(y, y)`, i.e.
    /// solving `template ≈ k · y` in least squares, then subtracting `k ·
    /// template` from `y`.
    enum TemplateFit: Sendable {
        case subtract
        case regress
    }

    /// How donor TRs are selected for each template. The side-window mode is
    /// EVA's original gradient-remover path. The AMRI mode mirrors
    /// `amri_eeg_gac.m`'s centered moving window: expand edge windows to keep
    /// the requested size where possible, exclude the current/ignored/outlier
    /// epochs, and avoid epochs closer than the AMRI no-window interval.
    enum DonorSelection: Sendable {
        case sideWindow
        case amriMovingWindow
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
        reducer: TemplateReducer = .weightedMean,
        fit: TemplateFit = .subtract,
        donorSelection: DonorSelection = .sideWindow,
        computeBackend: ComputeBackend = .cpu,
        samplingRate: Double? = nil,
        amriNoWindowSeconds: Double = 0.3,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [[Float]] {
        try Task.checkCancellation()
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
        let metal: GradientRemoverMetalBackend?
        switch computeBackend {
        case .cpu: metal = nil
        case .metal: metal = GradientRemoverMetalBackend.shared
        }
        let weightBefore = Float(window.before) / Float(window.before + window.after)
        let weightAfter = Float(window.after) / Float(window.before + window.after)

        var result = channels

        // Progress accounting across parallel workers.
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0
        let reportEvery = max(1, channelCount / 100)

        result.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct index, so concurrent writes don't
            // overlap; the buffer pointer is shared read-only metadata.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: channelCount) { c in
                guard !Task.isCancelled else { return }
                out[c] = correctChannel(
                    channels[c],
                    offset: offset,
                    spacing: spacing,
                    nTR: nTR,
                    window: window,
                    weightBefore: weightBefore,
                    weightAfter: weightAfter,
                    excludedTRs: excludedTRs,
                    reducer: reducer,
                    fit: fit,
                    donorSelection: donorSelection,
                    metal: metal,
                    samplingRate: samplingRate,
                    amriNoWindowSeconds: amriNoWindowSeconds
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
        excludedTRs: Set<Int> = [],
        reducer: TemplateReducer = .weightedMean,
        fit: TemplateFit = .subtract,
        donorSelection: DonorSelection = .sideWindow,
        metal: GradientRemoverMetalBackend? = nil,
        samplingRate: Double? = nil,
        amriNoWindowSeconds: Double = 0.3
    ) -> [Float] {
        // Detrend every TR segment once (Python caches detrended TRs lazily).
        var detrended = [[Float]]()
        detrended.reserveCapacity(nTR)
        for n in 0..<nTR {
            guard !Task.isCancelled else { return channel }
            let start = offset + n * spacing
            detrended.append(linearDetrend(Array(channel[start..<(start + spacing)])))
        }

        var row = channel
        var template = [Float](repeating: 0, count: spacing)
        var corrected = [Float](repeating: 0, count: spacing)
        let usesAMRIDonorSelection: Bool
        switch donorSelection {
        case .sideWindow: usesAMRIDonorSelection = false
        case .amriMovingWindow: usesAMRIDonorSelection = true
        }
        let outlierTRs = usesAMRIDonorSelection ? correlationOutliers(in: detrended) : []
        let minimumDistanceTRs: Int
        if usesAMRIDonorSelection,
           let samplingRate,
           samplingRate > 0,
           amriNoWindowSeconds > 0 {
            minimumDistanceTRs = max(Int((amriNoWindowSeconds * samplingRate / Double(spacing)).rounded()), 0)
        } else {
            minimumDistanceTRs = 0
        }

        if let metal {
            let usesMedian: Bool
            switch reducer {
            case .weightedMean: usesMedian = false
            case .median: usesMedian = true
            }
            if usesMedian {
                var donors = [[Int]](repeating: [], count: nTR)
                for n in 0..<nTR {
                    guard !Task.isCancelled else { return channel }
                    switch donorSelection {
                    case .sideWindow:
                        guard n >= window.before, n <= nTR - window.after - 1 else { continue }
                        let before = ((n - window.before)..<n).filter { !excludedTRs.contains($0) }
                        let after = ((n + 1)..<(n + window.after + 1)).filter { !excludedTRs.contains($0) }
                        donors[n] = before + after
                    case .amriMovingWindow:
                        donors[n] = amriWindowIndices(
                            center: n, before: window.before, after: window.after, count: nTR
                        ).filter {
                            $0 != n
                                && !excludedTRs.contains($0)
                                && !outlierTRs.contains($0)
                                && abs($0 - n) > minimumDistanceTRs
                        }
                    }
                }

                let fitRegression: Bool
                switch fit {
                case .subtract: fitRegression = false
                case .regress: fitRegression = true
                }
                if let correctedSegments = metal.correctMedianSegments(
                    detrended,
                    donors: donors,
                    fitRegression: fitRegression
                ) {
                    for n in 0..<nTR {
                        let start = offset + n * spacing
                        row.replaceSubrange(start..<(start + spacing), with: correctedSegments[n])
                    }
                    return row
                }
            }
        }

        for n in 0..<nTR {
            guard !Task.isCancelled else { return channel }
            let start = offset + n * spacing

            // Donor TR indices on each side, dropping excluded (e.g. high-motion)
            // TRs. When `excludedTRs` is empty these are the full ranges, so the
            // template is identical to the unfiltered case.
            let beforeIdx: [Int]
            let afterIdx: [Int]
            switch donorSelection {
            case .sideWindow:
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
                beforeIdx = ((n - window.before)..<n).filter { !excludedTRs.contains($0) }
                afterIdx = ((n + 1)..<(n + window.after + 1)).filter { !excludedTRs.contains($0) }

            case .amriMovingWindow:
                let indices = amriWindowIndices(center: n, before: window.before, after: window.after, count: nTR)
                    .filter {
                        $0 != n
                            && !excludedTRs.contains($0)
                            && !outlierTRs.contains($0)
                            && abs($0 - n) > minimumDistanceTRs
                    }
                beforeIdx = indices.filter { $0 < n }
                afterIdx = indices.filter { $0 > n }
            }

            // If both sides are fully censored, leave the TR detrended (as at the
            // edges) — better than subtracting an empty template.
            if beforeIdx.isEmpty && afterIdx.isEmpty {
                row.replaceSubrange(start..<(start + spacing), with: detrended[n])
                continue
            }

            switch reducer {
            case .weightedMean:
                // Renormalize weights when one side has no surviving donors so
                // the template amplitude stays correct.
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

            case .median:
                // MAS/MAR: elementwise median across the combined before+after
                // donor TRs — no before/after weighting, since a median doesn't
                // compose the way a weighted mean does. Robust to an occasional
                // corrupted donor volume without needing outlier detection.
                template = elementwiseMedian(of: detrended, indices: beforeIdx + afterIdx, length: spacing)
            }

            switch fit {
            case .subtract:
                // corrected = detrended[n] - template
                vDSP.subtract(detrended[n], template, result: &corrected)

            case .regress:
                // MAR/AAR: scale the template by a least-squares fit before
                // subtracting, so its amplitude can adapt to slow gradient
                // drift a fixed 1:1 subtraction can't track. Matches
                // amri_eeg_gac.m's AAR/MAR: k = dot(y, template) / dot(y, y),
                // solving "template ≈ k · y" (y = detrended[n]) in least
                // squares, then corrected = y - k · template.
                let k = regressionCoefficient(y: detrended[n], template: template)
                var scaledTemplate = template
                var kScalar = k
                vDSP_vsmul(template, 1, &kScalar, &scaledTemplate, 1, vDSP_Length(spacing))
                vDSP.subtract(detrended[n], scaledTemplate, result: &corrected)
            }
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

    /// Elementwise median of `segments[indices]`, each of length `length`.
    /// Returns an all-zero template if `indices` is empty.
    nonisolated private static func elementwiseMedian(
        of segments: [[Float]],
        indices: [Int],
        length: Int
    ) -> [Float] {
        guard !indices.isEmpty else { return [Float](repeating: 0, count: length) }
        var result = [Float](repeating: 0, count: length)
        var column = [Float](repeating: 0, count: indices.count)
        for i in 0..<length {
            for (row, tr) in indices.enumerated() { column[row] = segments[tr][i] }
            column.sort()
            let mid = column.count / 2
            result[i] = column.count % 2 == 0 ? (column[mid - 1] + column[mid]) / 2 : column[mid]
        }
        return result
    }

    nonisolated private static func amriWindowIndices(center: Int, before: Int, after: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let targetCount = min(max(before + after + 1, 1), count)
        var start = max(center - before, 0)
        var end = min(center + after, count - 1)
        let missing = targetCount - (end - start + 1)
        if missing > 0 {
            if start == 0 {
                end = min(count - 1, end + missing)
            } else if end == count - 1 {
                start = max(0, start - missing)
            }
        }
        return Array(start...end)
    }

    nonisolated private static func correlationOutliers(in segments: [[Float]]) -> Set<Int> {
        guard segments.count >= 4, let length = segments.first?.count, length > 1 else { return [] }
        let medianTemplate = elementwiseMedian(of: segments, indices: Array(segments.indices), length: length)
        let correlations = segments.map { pearson($0, medianTemplate) }
        let sorted = correlations.sorted()
        let q1 = sorted[max(0, min(sorted.count - 1, Int((Double(sorted.count) * 0.25).rounded()) - 1))]
        let q3 = sorted[max(0, min(sorted.count - 1, Int((Double(sorted.count) * 0.75).rounded()) - 1))]
        let iqr = max(q3 - q1, 0)
        let threshold = q1 - 4 * iqr
        return Set(correlations.indices.filter { correlations[$0] < threshold })
    }

    nonisolated private static func pearson(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let meanA = Double(a.reduce(0, +)) / Double(a.count)
        let meanB = Double(b.reduce(0, +)) / Double(b.count)
        var aa = 0.0
        var bb = 0.0
        var ab = 0.0
        for i in a.indices {
            let da = Double(a[i]) - meanA
            let db = Double(b[i]) - meanB
            aa += da * da
            bb += db * db
            ab += da * db
        }
        let denom = (aa * bb).squareRoot()
        guard denom > 1e-12 else { return 0 }
        return ab / denom
    }

    /// Least-squares scalar fit of `template ≈ k · y`: `k = dot(y, template) / dot(y, y)`.
    nonisolated private static func regressionCoefficient(y: [Float], template: [Float]) -> Float {
        var denom: Float = 0
        vDSP_dotpr(y, 1, y, 1, &denom, vDSP_Length(y.count))
        guard denom > 1e-12 else { return 0 }
        var numer: Float = 0
        vDSP_dotpr(y, 1, template, 1, &numer, vDSP_Length(y.count))
        return numer / denom
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
