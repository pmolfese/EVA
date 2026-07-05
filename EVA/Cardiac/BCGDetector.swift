//
//  BCGDetector.swift
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
//  Four independent approaches to detecting ballistocardiogram (BCG) artifact events
//  in simultaneous EEG/fMRI. Each method exploits a different signature of BCG:
//
//  1. GFP Periodicity   — BCG repeats at the cardiac rate; bandpass + GFP peak-find.
//  2. Spatial PCA       — BCG dominates the top spatial PCs of an exemplar window.
//  3. Cardiac Power Map — channels loaded with cardiac-band power drive a weighted GFP.
//  4. QRS Locking       — BCG lags the R-wave by a fixed mechanical delay (~300 ms).
//
//  Spatial PCA improvements implemented here:
//   • Multi-component subspace (top N eigenvectors, RSS-combined score)
//   • Sliding z-score normalization (adapts to amplitude drift)
//   • Spatial whitening (suppresses dominant non-BCG directions before PCA)
//   • Respiratory-envelope adaptive normalization (5-10 s window, tracks ~0.2 Hz modulation)
//

import Accelerate
import Foundation

nonisolated enum BCGDetector {
    static let eventCode  = "BCG"
    static let sourceFile = "BCG Detection"

    // MARK: - Method 1: GFP Periodicity

    /// Bandpass EEG to the cardiac band, compute per-sample GFP, detect peaks.
    static func periodicityEvents(
        channels: [[Float]],
        samplingRate: Double,
        minHR: Double = 40,
        maxHR: Double = 120,
        thresholdSD: Double = 2.5
    ) async -> [Double] {
        guard !channels.isEmpty,
              let n = channels.first?.count, n > Int(samplingRate * 4),
              samplingRate > 0
        else { return [] }

        let minHz = minHR / 60.0
        let maxHz = maxHR / 60.0
        guard let filtered = try? await EEGSignalFilter.bandPass(
            channels: channels,
            samplingRate: samplingRate,
            lowCutoff: minHz,
            highCutoff: min(maxHz, samplingRate / 2 - 0.1),
            highPassSlope: .dB12,
            lowPassSlope: .dB12
        ) else { return [] }

        let gfp = computeGFP(channels: filtered)
        let minSpacing = Int(samplingRate / maxHz * 0.6)
        return findPeaks(in: gfp, samplingRate: samplingRate,
                         thresholdSD: thresholdSD, minSpacingSamples: max(minSpacing, 1))
    }

    // MARK: - Method 2: Spatial PCA

    /// Detect BCG events by projecting the full recording onto the top spatial PCs
    /// derived from an exemplar window. Multiple improvements over a naïve single-PC
    /// approach:
    ///
    /// - **Multi-component**: projects onto the top `numComponents` PCs and combines
    ///   them via root-sum-of-squares, catching BCG whose spatial structure spans more
    ///   than one dipole.
    /// - **Spatial whitening**: optionally pre-whitens the exemplar covariance by the
    ///   background (non-exemplar) data covariance, suppressing dominant non-BCG
    ///   directions (alpha, muscle) so the BCG subspace stands out more cleanly.
    /// - **Sliding z-score**: normalises the detection signal in a rolling window so the
    ///   threshold adapts to slow amplitude drift rather than being set from a single
    ///   global statistic.
    /// - **Respiratory envelope normalization**: a short (~6 s) sliding window tracks the
    ///   ~0.2 Hz respiratory modulation of BCG amplitude, keeping sensitivity uniform
    ///   across the breath cycle.
    static func spatialPCAEvents(
        channels: [[Float]],
        samplingRate: Double,
        exemplarRange: ClosedRange<Int>? = nil,
        exemplarChannels: [[Float]]? = nil,   // pre-averaged template; overrides range
        numComponents: Int = 1,
        spatialWhiten: Bool = false,
        slidingNormalize: Bool = true,
        respAdaptive: Bool = true,
        thresholdSD: Double = 2.5
    ) async -> [Double] {
        guard channels.count >= 2,
              let firstCh = channels.first, firstCh.count > 10,
              samplingRate > 0
        else { return [] }

        let nCh  = channels.count
        let nAll = firstCh.count
        let nComp = max(1, min(numComponents, nCh - 1))

        // Resolve the exemplar matrix — pre-averaged template takes priority.
        let exemplar: [[Float]]
        let pcaRangeForWhitening: Range<Int>     // used only if spatialWhiten

        if let pre = exemplarChannels, pre.count == nCh, !(pre.first?.isEmpty ?? true) {
            // Caller supplied a refined averaged template — mean-centre each channel.
            exemplar = pre.map { ch in
                var mu: Float = 0
                vDSP_meanv(ch, 1, &mu, vDSP_Length(ch.count))
                var neg = -mu
                var shifted = ch
                vDSP_vsadd(ch, 1, &neg, &shifted, 1, vDSP_Length(ch.count))
                return shifted
            }
            pcaRangeForWhitening = 0 ..< nAll   // whiten against full recording
        } else {
            let pcaRange: Range<Int>
            if let r = exemplarRange, r.count > nCh {
                pcaRange = r.lowerBound ..< (r.upperBound + 1)
            } else {
                let fallback = min(nAll, Int(samplingRate * 30))
                pcaRange = 0 ..< fallback
            }
            pcaRangeForWhitening = pcaRange
            exemplar = channels.map { ch in
                let slice = Array(ch[pcaRange])
                var mu: Float = 0
                vDSP_meanv(slice, 1, &mu, vDSP_Length(slice.count))
                var neg = -mu
                var shifted = slice
                vDSP_vsadd(slice, 1, &neg, &shifted, 1, vDSP_Length(slice.count))
                return shifted
            }
        }

        // Optionally whiten by background covariance.
        let pcaInput: [[Float]]
        var whiteningMatrix: [Float] = []
        if spatialWhiten {
            let bgRange: Range<Int>
            if pcaRangeForWhitening.count < nAll / 2 {
                let afterEnd  = pcaRangeForWhitening.upperBound
                let remaining = nAll - afterEnd
                bgRange = remaining > pcaRangeForWhitening.count
                    ? afterEnd ..< nAll
                    : 0 ..< pcaRangeForWhitening.lowerBound
            } else {
                bgRange = 0 ..< nAll
            }
            let bgData: [[Float]] = channels.map { ch in
                let slice = Array(ch[bgRange])
                var mu: Float = 0
                vDSP_meanv(slice, 1, &mu, vDSP_Length(slice.count))
                var neg = -mu
                var shifted = slice
                vDSP_vsadd(slice, 1, &neg, &shifted, 1, vDSP_Length(slice.count))
                return shifted
            }
            let result = applyWhitening(exemplar: exemplar, background: bgData)
            pcaInput = result.whitened
            whiteningMatrix = result.W
        } else {
            pcaInput = exemplar
        }

        // Compute top nComp eigenvectors from exemplar covariance.
        let eigvecs = topEigenvectors(exemplar: pcaInput, k: nComp)

        // When whitening is active, eigvecs live in the whitened space; apply W to the
        // full recording so the projection is in the same space as the eigenvectors.
        let projChannels: [[Float]]
        if spatialWhiten, whiteningMatrix.count == nCh * nCh {
            let chFlat = channels.flatMap { $0 }
            var wChFlat = [Float](repeating: 0, count: nCh * nAll)
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                        Int32(nCh), Int32(nAll), Int32(nCh),
                        1.0, whiteningMatrix, Int32(nCh),
                        chFlat, Int32(nAll),
                        0.0, &wChFlat, Int32(nAll))
            projChannels = (0..<nCh).map { i in Array(wChFlat[(i * nAll)..<((i + 1) * nAll)]) }
        } else {
            projChannels = channels
        }

        // Project full recording onto each component and combine via RSS.
        var combinedScore = [Float](repeating: 0, count: nAll)
        for vec in eigvecs {
            var proj = [Float](repeating: 0, count: nAll)
            for i in projChannels.indices {
                var w = vec[i]
                vDSP_vsma(projChannels[i], 1, &w, proj, 1, &proj, 1, vDSP_Length(nAll))
            }
            // score += proj²
            vDSP.add(multiplication: (proj, proj), combinedScore, result: &combinedScore)
        }
        // RSS: sqrt(sum of squared projections)
        var len = Int32(nAll)
        vvsqrtf(&combinedScore, combinedScore, &len)

        // Smooth with a ~100 ms window to merge multi-sample peaks.
        let smoothW = max(1, Int(samplingRate * 0.10))
        var signal = boxCarSmooth(combinedScore, window: smoothW)

        // Respiratory-envelope adaptive normalization: divide by a ~6 s
        // sliding RMS so the threshold is stable across the breath cycle.
        if respAdaptive {
            let respWindow = max(smoothW + 1, Int(samplingRate * 6.0))
            signal = slidingRMSNormalize(signal, windowSamples: respWindow)
        }

        // Sliding z-score over a ~30 s window to handle slow amplitude drift.
        if slidingNormalize {
            let normWindow = max(Int(samplingRate * 6.0) + 1, Int(samplingRate * 30.0))
            signal = slidingZScore(signal, windowSamples: normWindow)
        }

        let minSpacing = Int(samplingRate * 0.50)
        return findPeaks(in: signal, samplingRate: samplingRate,
                         thresholdSD: slidingNormalize ? thresholdSD : thresholdSD,
                         minSpacingSamples: minSpacing)
    }

    // MARK: - Iterative Exemplar Refinement

    /// Epoch the recording at `detectedTimes`, score each epoch by PC1 projection power,
    /// reject the worst `rejectFraction`, average the survivors, re-detect using the
    /// refined template, and return the new event times + the averaged template waveforms.
    ///
    /// Returns `nil` when there are too few detected events to work with.
    static func refineSpatialPCA(
        channels: [[Float]],
        samplingRate: Double,
        detectedTimes: [Double],
        windowHalfSeconds: Double = 0.35,
        rejectFraction: Double = 0.20,
        numComponents: Int = 1,
        spatialWhiten: Bool = false,
        slidingNormalize: Bool = true,
        respAdaptive: Bool = true,
        thresholdSD: Double = 2.5
    ) async -> (times: [Double], templateChannelValues: [Float], keptCount: Int)? {
        let nCh  = channels.count
        guard nCh > 0, !detectedTimes.isEmpty else { return nil }
        let nAll = channels[0].count
        let halfW = Int(windowHalfSeconds * samplingRate)
        let epochLen = halfW * 2 + 1

        // ── 1. Extract valid epochs ──────────────────────────────────────────
        var validCenters: [Int] = []
        for t in detectedTimes {
            let c = Int(t * samplingRate)
            if c - halfW >= 0, c + halfW < nAll { validCenters.append(c) }
        }
        guard validCenters.count >= 4 else { return nil }
        let nEpochs = validCenters.count

        // epochs[ch][epoch * epochLen ..< (epoch+1)*epochLen]
        var epochs = [[Float]](repeating: [Float](repeating: 0, count: nEpochs * epochLen), count: nCh)
        for (ei, c) in validCenters.enumerated() {
            for ch in 0..<nCh {
                let src = channels[ch]
                let base = ei * epochLen
                for s in 0..<epochLen {
                    epochs[ch][base + s] = src[c - halfW + s]
                }
                // mean-centre this epoch
                epochs[ch].withUnsafeMutableBufferPointer { buf in
                    var mu: Float = 0
                    vDSP_meanv(buf.baseAddress! + base, 1, &mu, vDSP_Length(epochLen))
                    var neg = -mu
                    vDSP_vsadd(buf.baseAddress! + base, 1, &neg,
                               buf.baseAddress! + base, 1, vDSP_Length(epochLen))
                }
            }
        }

        // ── 2. Grand-average template for scoring ────────────────────────────
        var grandAvg = [[Float]](repeating: [Float](repeating: 0, count: epochLen), count: nCh)
        var scaleE = Float(1) / Float(nEpochs)
        for ch in 0..<nCh {
            for ei in 0..<nEpochs {
                let base = ei * epochLen
                epochs[ch].withUnsafeBufferPointer { eBuf in
                    grandAvg[ch].withUnsafeMutableBufferPointer { gBuf in
                        vDSP_vsma(eBuf.baseAddress! + base, 1, &scaleE,
                                  gBuf.baseAddress!, 1,
                                  gBuf.baseAddress!, 1, vDSP_Length(epochLen))
                    }
                }
            }
        }

        // ── 3. PC1 of the grand-average for scoring ──────────────────────────
        let pcs = topEigenvectors(exemplar: grandAvg, k: 1)
        guard let pc1 = pcs.first, pc1.count == nCh else { return nil }

        // Score each epoch: max-abs of (PC1ᵀ · epoch_sample) across time.
        var scores = [Float](repeating: 0, count: nEpochs)
        for ei in 0..<nEpochs {
            var maxAbsProj: Float = 0
            for s in 0..<epochLen {
                var proj: Float = 0
                for ch in 0..<nCh {
                    proj += pc1[ch] * epochs[ch][ei * epochLen + s]
                }
                let absP = abs(proj)
                if absP > maxAbsProj { maxAbsProj = absP }
            }
            scores[ei] = maxAbsProj
        }

        // ── 4. Reject bottom `rejectFraction` by score ───────────────────────
        let rejectCount = max(0, Int(Double(nEpochs) * rejectFraction))
        let keepCount   = nEpochs - rejectCount
        guard keepCount >= 2 else { return nil }

        var indexed = scores.enumerated().map { ($0.offset, $0.element) }
        indexed.sort { $0.1 > $1.1 }   // descending — keep the top
        let keepSet = Set(indexed.prefix(keepCount).map { $0.0 })

        // ── 5. Re-average survivors ──────────────────────────────────────────
        var refinedAvg = [[Float]](repeating: [Float](repeating: 0, count: epochLen), count: nCh)
        var scaleK = Float(1) / Float(keepCount)
        for ei in 0..<nEpochs where keepSet.contains(ei) {
            for ch in 0..<nCh {
                let base = ei * epochLen
                epochs[ch].withUnsafeBufferPointer { eBuf in
                    refinedAvg[ch].withUnsafeMutableBufferPointer { rBuf in
                        vDSP_vsma(eBuf.baseAddress! + base, 1, &scaleK,
                                  rBuf.baseAddress!, 1,
                                  rBuf.baseAddress!, 1, vDSP_Length(epochLen))
                    }
                }
            }
        }

        // ── 6. Re-detect using refined template ──────────────────────────────
        let refinedTimes = await spatialPCAEvents(
            channels: channels,
            samplingRate: samplingRate,
            exemplarChannels: refinedAvg,
            numComponents: numComponents,
            spatialWhiten: spatialWhiten,
            slidingNormalize: slidingNormalize,
            respAdaptive: respAdaptive,
            thresholdSD: thresholdSD
        )

        // ── 7. Flatten refined average to [Float] for topomap display ────────
        // One value per channel: peak-GFP sample of the averaged epoch.
        var gfp = [Float](repeating: 0, count: epochLen)
        for s in 0..<epochLen {
            var sumSq: Float = 0
            for ch in 0..<nCh { sumSq += refinedAvg[ch][s] * refinedAvg[ch][s] }
            gfp[s] = sqrt(sumSq / Float(nCh))
        }
        let peakS = gfp.indices.max(by: { gfp[$0] < gfp[$1] }) ?? (epochLen / 2)
        var templateValues = [Float](repeating: 0, count: nCh)
        for ch in 0..<nCh { templateValues[ch] = refinedAvg[ch][peakS] }

        return (times: refinedTimes, templateChannelValues: templateValues, keptCount: keepCount)
    }

    // MARK: - Method 3: Cardiac Power Map

    /// Weight each channel by its cardiac-band RMS, sum to a single weighted time series,
    /// and detect peaks. Channels that carry the most BCG energy dominate the signal.
    static func cardiacPowerEvents(
        channels: [[Float]],
        samplingRate: Double,
        minHz: Double = 0.8,
        maxHz: Double = 1.5,
        thresholdSD: Double = 2.5
    ) async -> [Double] {
        guard !channels.isEmpty,
              let n = channels.first?.count, n > Int(samplingRate * 4),
              samplingRate > 0
        else { return [] }

        guard let filtered = try? await EEGSignalFilter.bandPass(
            channels: channels,
            samplingRate: samplingRate,
            lowCutoff: minHz,
            highCutoff: min(maxHz, samplingRate / 2 - 0.1),
            highPassSlope: .dB12,
            lowPassSlope: .dB12
        ) else { return [] }

        let weights: [Float] = filtered.map { ch in
            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(ch.count))
            return rms
        }
        let totalW = weights.reduce(0, +)
        guard totalW > 0 else { return [] }

        var weighted = [Float](repeating: 0, count: n)
        for (idx, ch) in filtered.enumerated() {
            var w = weights[idx] / totalW
            vDSP_vsma(ch, 1, &w, weighted, 1, &weighted, 1, vDSP_Length(n))
        }

        let absW     = vDSP.absolute(weighted)
        let smoothW  = max(1, Int(samplingRate * 0.05))
        let smoothed = boxCarSmooth(absW, window: smoothW)
        let minSpacing = Int(samplingRate * 0.50)
        return findPeaks(in: smoothed, samplingRate: samplingRate,
                         thresholdSD: thresholdSD, minSpacingSamples: minSpacing)
    }

    // MARK: - Method 4: QRS Locking

    /// Shift existing R-wave event times by a fixed BCG mechanical lag.
    static func qrsLockingEvents(
        qrsTimes: [Double],
        lagSeconds: Double,
        recordingDuration: Double
    ) -> [Double] {
        qrsTimes
            .map { $0 + lagSeconds }
            .filter { $0 >= 0 && $0 < recordingDuration }
    }

    // MARK: - Virtual ECG (PCA across the proxy channel group)

    /// Collapses a BCG-proxy channel group into a single "virtual ECG" trace:
    /// band-pass each channel to the cardiac band, take the first principal
    /// component across the group, and return its time series (sign-normalized
    /// so the dominant deflection is positive). This averages out
    /// channel-specific noise — the generalization of FMRIB/OBS's "best EEG
    /// channel" step to a whole channel group. Feed the result into a QRS
    /// detector (e.g. Pan-Tompkins) to get beat times.
    static func virtualECGComponent(
        channels: [[Float]],
        samplingRate: Double,
        minHR: Double = 40,
        maxHR: Double = 120
    ) async -> [Float]? {
        guard channels.count >= 2,
              let first = channels.first, first.count > 10,
              samplingRate > 0
        else { return nil }

        let minHz = minHR / 60.0
        let maxHz = maxHR / 60.0
        guard let filtered = try? await EEGSignalFilter.bandPass(
            channels: channels,
            samplingRate: samplingRate,
            lowCutoff: minHz,
            highCutoff: min(maxHz, samplingRate / 2 - 0.1),
            highPassSlope: .dB12,
            lowPassSlope: .dB12
        ) else { return nil }

        let nCh = filtered.count
        let nAll = filtered.first?.count ?? 0
        guard nAll > 0 else { return nil }

        // Mean-centre each channel, then take the top eigenvector of the
        // channel covariance over the whole (filtered) recording.
        let centered: [[Float]] = filtered.map { ch in
            var mu: Float = 0
            vDSP_meanv(ch, 1, &mu, vDSP_Length(ch.count))
            var neg = -mu
            var shifted = ch
            vDSP_vsadd(ch, 1, &neg, &shifted, 1, vDSP_Length(ch.count))
            return shifted
        }
        guard let vec = topEigenvectors(exemplar: centered, k: 1).first, vec.count == nCh else {
            return nil
        }

        // Project the centred channels onto the first PC → 1-D series.
        var pc = [Float](repeating: 0, count: nAll)
        for i in centered.indices {
            var w = vec[i]
            vDSP_vsma(centered[i], 1, &w, pc, 1, &pc, 1, vDSP_Length(nAll))
        }

        // Sign-normalize so the largest-magnitude excursion is positive, giving
        // the QRS detector a consistent polarity.
        var minV: Float = 0
        var maxV: Float = 0
        vDSP_minv(pc, 1, &minV, vDSP_Length(nAll))
        vDSP_maxv(pc, 1, &maxV, vDSP_Length(nAll))
        if abs(minV) > abs(maxV) {
            var negOne: Float = -1
            vDSP_vsmul(pc, 1, &negOne, &pc, 1, vDSP_Length(nAll))
        }
        return pc
    }

    // MARK: - MFFEvent helpers

    static func makeEvents(times: [Double], windowSeconds: Double) -> [MFFEvent] {
        times.enumerated().map { (idx, t) in
            MFFEvent(
                id: "bcg-\(idx)-\(t)",
                code: eventCode,
                beginTimeSeconds: t,
                rawBeginTime: String(format: "%.4f", t),
                sourceFile: sourceFile
            )
        }
    }

    // MARK: - Shared internals

    static func computeGFP(channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        let n = first.count
        var sum2 = [Float](repeating: 0, count: n)
        for ch in channels {
            vDSP.add(multiplication: (ch, ch), sum2, result: &sum2)
        }
        var invCh = 1.0 / Float(channels.count)
        vDSP_vsmul(sum2, 1, &invCh, &sum2, 1, vDSP_Length(n))
        var len = Int32(n)
        vvsqrtf(&sum2, sum2, &len)
        return sum2
    }

    /// Non-maximum suppression peak finder.
    static func findPeaks(
        in signal: [Float],
        samplingRate: Double,
        thresholdSD: Double,
        minSpacingSamples: Int
    ) -> [Double] {
        guard signal.count > 4 else { return [] }

        let (mu, sigma) = robustMeanSD(signal)
        let threshold = Float(mu + thresholdSD * sigma)

        var candidates: [(sample: Int, value: Float)] = []
        for i in 1 ..< (signal.count - 1) {
            if signal[i] > threshold && signal[i] >= signal[i-1] && signal[i] >= signal[i+1] {
                candidates.append((i, signal[i]))
            }
        }

        candidates.sort { $0.value > $1.value }
        var kept = [Bool](repeating: true, count: candidates.count)
        for i in 0 ..< candidates.count {
            guard kept[i] else { continue }
            for j in (i+1) ..< candidates.count {
                if abs(candidates[j].sample - candidates[i].sample) < minSpacingSamples {
                    kept[j] = false
                }
            }
        }

        return zip(candidates, kept)
            .compactMap { $1 ? Double($0.sample) / samplingRate : nil }
            .sorted()
    }

    // MARK: - Eigenvector computation

    /// Returns the top `k` eigenvectors of the exemplar covariance matrix,
    /// computed via deflated power iteration (orthogonal deflation after each PC).
    private static func topEigenvectors(exemplar: [[Float]], k: Int) -> [[Float]] {
        let nCh = exemplar.count
        guard nCh > 0, let firstCh = exemplar.first, firstCh.count > 0, k >= 1 else {
            return [[Float](repeating: 1.0 / sqrt(Float(max(nCh, 1))), count: nCh)]
        }
        let nT   = firstCh.count
        let flat = exemplar.flatMap { $0 }   // row-major (nCh × nT)

        // Symmetric covariance C = flat * flat^T / nT (upper triangle).
        var cov = [Float](repeating: 0, count: nCh * nCh)
        let alpha: Float = 1.0 / Float(nT)
        cblas_ssyrk(CblasRowMajor, CblasUpper, CblasNoTrans,
                    Int32(nCh), Int32(nT),
                    alpha, flat, Int32(nT),
                    0.0, &cov, Int32(nCh))
        // Symmetrise upper → lower.
        for i in 0 ..< nCh {
            for j in (i+1) ..< nCh { cov[j * nCh + i] = cov[i * nCh + j] }
        }

        var eigvecs = [[Float]]()
        eigvecs.reserveCapacity(k)
        var workCov = cov   // deflated copy

        for _ in 0 ..< k {
            var v  = [Float](repeating: 1.0 / sqrt(Float(nCh)), count: nCh)
            var Cv = [Float](repeating: 0, count: nCh)
            for _ in 0 ..< 120 {
                cblas_sgemv(CblasRowMajor, CblasNoTrans,
                            Int32(nCh), Int32(nCh),
                            1.0, workCov, Int32(nCh),
                            v, 1, 0.0, &Cv, 1)
                var norm: Float = 0
                vDSP_svesq(Cv, 1, &norm, vDSP_Length(nCh))
                norm = sqrt(norm)
                if norm < 1e-12 { break }
                var invN = 1.0 / norm
                vDSP_vsmul(Cv, 1, &invN, &v, 1, vDSP_Length(nCh))
            }
            eigvecs.append(v)

            // Deflate: workCov -= lambda * v * v^T   (lambda = v^T C v)
            cblas_sgemv(CblasRowMajor, CblasNoTrans,
                        Int32(nCh), Int32(nCh),
                        1.0, workCov, Int32(nCh),
                        v, 1, 0.0, &Cv, 1)
            var lambda: Float = 0
            vDSP_dotpr(v, 1, Cv, 1, &lambda, vDSP_Length(nCh))
            let negLambda = -lambda
            cblas_ssyr(CblasRowMajor, CblasUpper,
                       Int32(nCh), negLambda, v, 1, &workCov, Int32(nCh))
            for i in 0 ..< nCh {
                for j in (i+1) ..< nCh { workCov[j * nCh + i] = workCov[i * nCh + j] }
            }
        }
        return eigvecs
    }

    // MARK: - Spatial whitening

    /// Pre-whiten the exemplar by the background covariance so that all spatial
    /// directions are equalised before PCA. Suppresses dominant non-BCG sources
    /// (alpha oscillations, muscle) whose large power would otherwise capture early PCs.
    ///
    /// Whitening matrix: W = V * diag(1 / sqrt(λ + ε)) * V^T
    /// Applied to each frame of the exemplar: X_white = W * X
    /// Returns the whitened exemplar and the nCh×nCh whitening matrix W (row-major).
    private static func applyWhitening(exemplar: [[Float]], background: [[Float]]) -> (whitened: [[Float]], W: [Float]) {
        let nCh = exemplar.count
        guard nCh > 1, let bgFirst = background.first, bgFirst.count > nCh else {
            return (exemplar, [])
        }
        let nT_bg = bgFirst.count
        let bgFlat = background.flatMap { $0 }

        // Background covariance (upper triangle).
        var bgCov = [Float](repeating: 0, count: nCh * nCh)
        let alpha: Float = 1.0 / Float(nT_bg)
        cblas_ssyrk(CblasRowMajor, CblasUpper, CblasNoTrans,
                    Int32(nCh), Int32(nT_bg),
                    alpha, bgFlat, Int32(nT_bg),
                    0.0, &bgCov, Int32(nCh))
        for i in 0 ..< nCh {
            for j in (i+1) ..< nCh { bgCov[j * nCh + i] = bgCov[i * nCh + j] }
        }

        // Eigendecompose background covariance: V, λ.
        var jobz: Int8 = Int8(UInt8(ascii: "V"))
        var uplo: Int8 = Int8(UInt8(ascii: "U"))
        var n32   = Int32(nCh)
        var lda   = Int32(nCh)
        var eigenvalues = [Float](repeating: 0, count: nCh)
        var lwork = Int32(3 * nCh + 64)
        var work  = [Float](repeating: 0, count: Int(lwork))
        var info  = Int32(0)
        ssyev_(&jobz, &uplo, &n32, &bgCov, &lda, &eigenvalues, &work, &lwork, &info)
        guard info == 0 else { return (exemplar, []) }   // fallback: no whitening

        // ssyev_ (Fortran column-major) returns eigenvectors as its columns; viewed
        // from Swift (row-major) those columns become rows: bgCov[i, :] = eigenvector i.
        // Build W = V * diag(1/sqrt(λ+ε)) * V^T where V has eigenvectors as columns.
        // With eigenvectors as rows E: V = E^T, so W = E^T * diag(invSqrtLambda) * E.
        let eps: Float = max(eigenvalues.max() ?? 1, 1e-6) * 1e-3
        let invSqrtLambda = eigenvalues.map { 1.0 / sqrt(max($0, eps)) }
        // Scale row i of bgCov by 1/sqrt(λ_i): Vscaled[i, :] = invSqrtLambda[i] * E[i, :]
        var Vscaled = bgCov
        Vscaled.withUnsafeMutableBufferPointer { buf in
            for i in 0 ..< nCh {
                var s = invSqrtLambda[i]
                // Row i is contiguous at buf + i*nCh with stride 1.
                vDSP_vsmul(buf.baseAddress! + i * nCh, 1, &s,
                           buf.baseAddress! + i * nCh, 1, vDSP_Length(nCh))
            }
        }
        // W = E^T * Vscaled  (= V * diag(invSqrtLambda) * V^T)
        var W = [Float](repeating: 0, count: nCh * nCh)
        cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans,
                    Int32(nCh), Int32(nCh), Int32(nCh),
                    1.0, bgCov, Int32(nCh),
                    Vscaled, Int32(nCh),
                    0.0, &W, Int32(nCh))

        // Apply W to exemplar: each time slice is a column vector of length nCh.
        // Exemplar is (nCh × nT_ex); result = W * exemplar → (nCh × nT_ex).
        let nT_ex = exemplar[0].count
        let exFlat = exemplar.flatMap { $0 }
        var resultFlat = [Float](repeating: 0, count: nCh * nT_ex)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(nCh), Int32(nT_ex), Int32(nCh),
                    1.0, W, Int32(nCh),
                    exFlat, Int32(nT_ex),
                    0.0, &resultFlat, Int32(nT_ex))

        // Unpack back into [[Float]] (nCh × nT_ex).
        let whitened = (0 ..< nCh).map { ch in
            Array(resultFlat[(ch * nT_ex) ..< ((ch + 1) * nT_ex)])
        }
        return (whitened, W)
    }

    // MARK: - Signal normalisation

    /// Sliding z-score: subtract a rolling mean and divide by a rolling SD.
    /// Makes the detection threshold independent of slow (< 1/windowSamples Hz) drift.
    private static func slidingZScore(_ x: [Float], windowSamples w: Int) -> [Float] {
        guard w > 1, x.count > w else { return x }
        let n    = x.count
        let half = w / 2
        // Prefix sums for O(1) window mean & sum-of-squares.
        var pSum  = [Double](repeating: 0, count: n + 1)
        var pSum2 = [Double](repeating: 0, count: n + 1)
        for i in 0 ..< n {
            pSum[i+1]  = pSum[i]  + Double(x[i])
            pSum2[i+1] = pSum2[i] + Double(x[i]) * Double(x[i])
        }
        var out = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let lo    = max(0, i - half)
            let hi    = min(n, i + half + 1)
            let cnt   = Double(hi - lo)
            let mean  = (pSum[hi]  - pSum[lo])  / cnt
            let mean2 = (pSum2[hi] - pSum2[lo]) / cnt
            let vari  = max(mean2 - mean * mean, 0)
            let sd    = vari > 0 ? sqrt(vari) : 1.0
            out[i] = Float((Double(x[i]) - mean) / sd)
        }
        return out
    }

    /// Divides the signal by its local RMS (computed over `windowSamples`), which
    /// tracks the ~0.2 Hz respiratory amplitude modulation of BCG. The result is
    /// dimensionless so the fixed SD threshold remains calibrated.
    private static func slidingRMSNormalize(_ x: [Float], windowSamples w: Int) -> [Float] {
        guard w > 1, x.count > w else { return x }
        let n    = x.count
        let half = w / 2
        var pSum2 = [Double](repeating: 0, count: n + 1)
        for i in 0 ..< n { pSum2[i+1] = pSum2[i] + Double(x[i]) * Double(x[i]) }
        var out = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let lo  = max(0, i - half)
            let hi  = min(n, i + half + 1)
            let rms = sqrt(max((pSum2[hi] - pSum2[lo]) / Double(hi - lo), 1e-20))
            out[i]  = Float(Double(x[i]) / rms)
        }
        return out
    }

    // MARK: - Utilities

    private static func boxCarSmooth(_ x: [Float], window w: Int) -> [Float] {
        guard w > 1, x.count > w else { return x }
        let n    = x.count
        let half = w / 2
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0 ..< n { prefix[i+1] = prefix[i] + x[i] }
        var out = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let lo    = max(0, i - half)
            let hi    = min(n - 1, i + half)
            let count = Float(hi - lo + 1)
            out[i]    = (prefix[hi+1] - prefix[lo]) / count
        }
        return out
    }

    private static func robustMeanSD(_ x: [Float]) -> (mean: Double, sd: Double) {
        guard x.count >= 4 else {
            var m: Float = 0; vDSP_meanv(x, 1, &m, vDSP_Length(x.count))
            return (Double(m), 1.0)
        }
        let sorted = x.sorted()
        let lo = sorted.count / 4
        let hi = sorted.count * 3 / 4
        let trimmed = Array(sorted[lo ..< hi])
        var mu: Float = 0
        vDSP_meanv(trimmed, 1, &mu, vDSP_Length(trimmed.count))
        var variance: Float = 0
        for v in trimmed { let d = v - mu; variance += d * d }
        let sd = sqrt(Double(variance) / Double(trimmed.count))
        return (Double(mu), max(sd, 1e-10))
    }
}
