//
//  FastrCorrector.swift
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
//  FASTR (fMRI Artifact Slice Template Removal) gradient-artifact correction for
//  simultaneous EEG/fMRI, after Niazy et al. (2005). This is a Swift port of the
//  algorithm shared by the FMRIB EEGLAB plugin (fmrib_fastr) and the FACET
//  toolbox (Glaser et al. 2013), targeting the volume-trigger workflow used by
//  EVA (TREV markers), with the per-volume acquisition optionally subdivided into
//  per-slice epochs.
//
//  Pipeline per channel: upsample -> align slice epochs (integer + optional
//  sub-sample) -> average-artifact template -> amplitude-scaled subtraction ->
//  optional OBS residual removal (PCA) -> downsample -> optional ANC.
//
//  TODO: validate against a MATLAB FASTR reference output (no reference dataset
//  available yet). TODO: exact odd/even slice averaging and iterative sub-sample
//  alignment to match FACET bit-for-bit; FARM template selection.
//

import Accelerate
import Foundation

struct FastrCorrector {

    enum TemplateScheme: String, CaseIterable, Sendable {
        /// Average temporally-neighboring epochs (Niazy / FACET default).
        case neighbor
        /// FARM: average the most-correlated epochs (van der Meer 2010),
        /// robust to motion. Falls back to `neighbor` where no epoch correlates
        /// above threshold.
        case farm
        /// Moosmann (2009) realignment-parameter-informed averaging: average the
        /// volumes whose head position is most similar to the target volume,
        /// using motion realignment parameters. Falls back to `neighbor` when no
        /// usable motion is supplied.
        case moosmann
    }

    enum OBSMode: Sendable, Equatable {
        case off
        case auto
        case fixed(Int)
    }

    struct Config: Sendable {
        /// Interpolation factor L (upsampling before template formation).
        var upsampleFactor = 10
        /// Number of fMRI slices per volume; the volume interval is split into
        /// this many epochs. 1 == treat each volume as a single epoch.
        var numberOfSlices = 1
        /// Number of epochs averaged into each artifact template.
        var averagingWindow = 30
        /// Relative trigger position within the artifact (0 = start, 1 = end).
        var relativeTriggerPosition = 0.03
        /// FACET-style fractional-sample alignment of epochs.
        var subSampleAlignment = true
        var templateScheme: TemplateScheme = .neighbor
        /// Optimal-basis-set residual removal.
        var obs: OBSMode = .auto
        /// High-pass cutoff (Hz) for OBS residual matrix formation.
        var obsHighPassHz = 70.0
        /// Optional low-pass (Hz) applied to the corrected signal.
        var lowPassHz: Double? = nil
        /// Adaptive noise cancellation after template subtraction.
        var anc = false
        /// Channels excluded from OBS and ANC (e.g. ECG).
        var excludedChannels: Set<Int> = []

        /// Volume indices to exclude as template donors (e.g. high-motion TRs).
        /// Excluded volumes are still corrected; they just don't contribute to
        /// other epochs' templates or the OBS basis. Empty = no exclusion.
        var censoredVolumes: Set<Int> = []

        /// Per-volume motion realignment parameters for the Moosmann scheme.
        var motion: [MotionSample]? = nil
        /// Movement threshold (mm) for including a volume in a Moosmann template.
        var motionThresholdMm = 0.5
        /// Sphere radius (mm) converting rotation to mm for motion distance.
        var motionRadiusMm = 50.0
    }

    enum FastrError: LocalizedError {
        case tooFewTriggers(Int)
        case invalidSpacing

        var errorDescription: String? {
            switch self {
            case .tooFewTriggers(let n):
                return "FASTR needs more triggers to build a template (found \(n))."
            case .invalidSpacing:
                return "Trigger spacing could not be determined (uneven or zero)."
            }
        }
    }

    /// Run FASTR on `channels` (channels × time).
    ///
    /// - Parameters:
    ///   - channels: raw EEG, one array per channel.
    ///   - volumeTriggers: sample indices of the volume (TR) triggers.
    ///   - config: algorithm configuration.
    ///   - samplingRate: Hz.
    ///   - progress: optional 0...1 progress callback (thread-safe).
    nonisolated static func correct(
        channels: [[Float]],
        volumeTriggers: [Int],
        config: Config,
        samplingRate: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [[Float]] {
        guard volumeTriggers.count >= 2 else {
            throw FastrError.tooFewTriggers(volumeTriggers.count)
        }
        let sampleCount = channels.first?.count ?? 0
        let slices = max(1, config.numberOfSlices)

        // 1. Generate slice triggers by evenly subdividing each volume interval.
        let triggers = sliceTriggers(volumeTriggers: volumeTriggers.sorted(),
                                     slices: slices,
                                     sampleCount: sampleCount)
        guard triggers.count >= 4 else { throw FastrError.tooFewTriggers(triggers.count) }

        let L = max(1, config.upsampleFactor)
        let sliceTrigger = slices > 1

        // Upsampled trigger positions and artifact geometry.
        let markersUp = triggers.map { $0 * L }
        let diffs = zip(markersUp.dropFirst(), markersUp).map { $0 - $1 }
        let minISI = median(diffs)
        guard minISI > 0 else { throw FastrError.invalidSpacing }
        let prePeak = Int((Double(minISI) * config.relativeTriggerPosition).rounded())
        let postPeak = Int((Double(minISI) * (1 - config.relativeTriggerPosition)).rounded())
        let artLength = prePeak + postPeak + 1
        let searchWindow = max(1, Int((3 * Double(L)).rounded()))
        let halfWindow = max(1, config.averagingWindow / 2)

        // OBS high-pass filter weights (designed on the upsampled axis).
        let nyq = 0.5 * samplingRate
        let obsHPF = obsHighPassWeights(hpf: config.obsHighPassHz, nyq: nyq, L: L, fs: samplingRate)

        // Moosmann (RP-info) per-volume neighbor sets, if requested and usable.
        let moosmannNeighbors: [[Int]]? = config.templateScheme == .moosmann
            ? moosmannVolumeNeighbors(motion: config.motion,
                                      volumeCount: volumeTriggers.count,
                                      window: config.averagingWindow,
                                      thresholdMm: config.motionThresholdMm)
            : nil

        // Alignment is computed once on channel 0 and reused for all channels.
        let aligner = Aligner(
            markersUp: markersUp,
            prePeak: prePeak, postPeak: postPeak,
            artLength: artLength, searchWindow: searchWindow,
            subSample: config.subSampleAlignment
        )

        let progressLock = NSLock()
        var completed = 0
        let totalUnits = channels.count

        var result = channels
        // Compute the aligned markers from channel 0 first (shared across channels).
        let channel0Up = DSP.interp(channels[0].map(Double.init), factor: L)
        let alignedMarkers = aligner.align(dataUp: channel0Up)

        DispatchQueue.concurrentPerform(iterations: channels.count) { c in
            let raw = channels[c].map(Double.init)
            let corrected = correctChannel(
                raw: raw,
                channelIndex: c,
                alignedMarkers: alignedMarkers,
                L: L,
                prePeak: prePeak, postPeak: postPeak, artLength: artLength,
                halfWindow: halfWindow, sliceTrigger: sliceTrigger,
                slices: slices,
                moosmannNeighbors: moosmannNeighbors,
                censoredVolumes: config.censoredVolumes,
                searchWindow: searchWindow,
                obsHPF: obsHPF,
                config: config, samplingRate: samplingRate
            )
            result[c] = corrected.map { Float($0) }

            if let progress {
                progressLock.lock()
                completed += 1
                let fraction = Double(completed) / Double(totalUnits)
                progressLock.unlock()
                progress(fraction)
            }
        }
        return result
    }

    // MARK: - Per-channel correction

    private nonisolated static func correctChannel(
        raw: [Double],
        channelIndex c: Int,
        alignedMarkers: [Int],
        L: Int,
        prePeak: Int, postPeak: Int, artLength: Int,
        halfWindow: Int, sliceTrigger: Bool,
        slices: Int,
        moosmannNeighbors: [[Int]]?,
        censoredVolumes: Set<Int>,
        searchWindow: Int,
        obsHPF: [Double],
        config: Config, samplingRate: Double
    ) -> [Double] {
        let n = raw.count
        let mean = raw.reduce(0, +) / Double(max(1, n))
        let zeroMean = raw.map { $0 - mean }
        var idata = DSP.interp(zeroMean, factor: L)
        let iorig = DSP.interp(raw, factor: L)
        let upLength = idata.count

        let numTrig = alignedMarkers.count
        let excluded = config.excludedChannels.contains(c)

        // Map censored volumes to censored epoch indices (a volume spans `slices`
        // slice epochs when slice-triggered).
        let censoredEpochs: Set<Int> = censoredVolumes.isEmpty ? [] :
            Set((0..<numTrig).filter { censoredVolumes.contains(sliceTrigger ? $0 / slices : $0) })

        // Build noise estimate (template) over the whole upsampled signal.
        var iNoise = [Double](repeating: 0, count: upLength)

        // Pre-extract aligned epochs for averaging.
        func epoch(_ s: Int) -> ArraySlice<Double>? {
            let start = alignedMarkers[s] - prePeak
            let end = alignedMarkers[s] + postPeak
            guard start >= 0, end < upLength else { return nil }
            return idata[start...end]
        }

        // FARM: select, per epoch, the most-correlated epochs (computed on this
        // channel's data). Empty entries fall back to the neighbor window.
        let farmNeighbors: [[Int]]? = config.templateScheme == .farm
            ? farmEpochNeighbors(epochs: (0..<numTrig).map { epoch($0).map(Array.init) },
                                 select: max(2, config.averagingWindow),
                                 searchHalf: max(2 * config.averagingWindow, 25))
            : nil

        for s in 0..<numTrig {
            guard let avg = averageTemplate(
                center: s, numTrig: numTrig, halfWindow: halfWindow,
                sliceTrigger: sliceTrigger, slices: slices,
                moosmannNeighbors: moosmannNeighbors, farmNeighbors: farmNeighbors,
                censoredEpochs: censoredEpochs, epoch: epoch
            ) else { continue }
            guard let target = epoch(s) else { continue }

            // Amplitude scale (Alpha) to minimize squared error, unless excluded.
            let alpha: Double
            if excluded {
                alpha = 1
            } else {
                var num = 0.0, den = 0.0
                let t = Array(target)
                for i in 0..<artLength { num += t[i] * avg[i]; den += avg[i] * avg[i] }
                alpha = den == 0 ? 0 : num / den
            }
            let start = alignedMarkers[s] - prePeak
            for i in 0..<artLength { iNoise[start + i] = alpha * avg[i] }
        }

        // OBS residual removal.
        var fittedRes = [Double](repeating: 0, count: upLength)
        if !excluded, config.obs != .off {
            fittedRes = optimalBasisSet(
                idata: idata, iNoise: iNoise, alignedMarkers: alignedMarkers,
                prePeak: prePeak, postPeak: postPeak, artLength: artLength,
                numTrig: numTrig, sliceTrigger: sliceTrigger,
                censoredEpochs: censoredEpochs,
                obsHPF: obsHPF, mode: config.obs
            )
        }

        // Corrected (upsampled) = original - template - fitted residual.
        for i in 0..<upLength { idata[i] = iorig[i] - iNoise[i] - fittedRes[i] }

        // Downsample back.
        var cleanEEG = L > 1 ? DSP.decimate(idata, factor: L) : idata
        var noise = L > 1 ? DSP.decimate(zip(iNoise, fittedRes).map(+), factor: L) : zip(iNoise, fittedRes).map(+)
        // Guard length (decimate can be off by one).
        if cleanEEG.count > n { cleanEEG = Array(cleanEEG[0..<n]) }
        if cleanEEG.count < n { cleanEEG += Array(repeating: raw[cleanEEG.count..<n].first ?? 0, count: n - cleanEEG.count) }
        if noise.count > n { noise = Array(noise[0..<n]) }
        if noise.count < n { noise += Array(repeating: 0, count: n - noise.count) }

        // Optional low-pass.
        if let lpf = config.lowPassHz, lpf > 0 {
            let taps = lowPassWeights(lpf: lpf, fs: samplingRate)
            cleanEEG = DSP.filtfiltFIR(taps, cleanEEG)
            noise = DSP.filtfiltFIR(taps, noise)
        }

        // Optional adaptive noise cancellation.
        if config.anc, !excluded {
            cleanEEG = adaptiveNoiseCancel(clean: cleanEEG, noise: noise,
                                           triggers: alignedMarkers, L: L,
                                           artLength: artLength, samplingRate: samplingRate)
        }
        return cleanEEG
    }

    // MARK: - Template averaging

    private nonisolated static func averageTemplate(
        center s: Int, numTrig: Int, halfWindow: Int, sliceTrigger: Bool,
        slices: Int, moosmannNeighbors: [[Int]]?, farmNeighbors: [[Int]]?,
        censoredEpochs: Set<Int>, epoch: (Int) -> ArraySlice<Double>?
    ) -> [Double]? {
        // Collect contributing epoch indices.
        var indices: [Int] = []
        if let farm = farmNeighbors, s < farm.count, !farm[s].isEmpty {
            // FARM: average the most-correlated epochs (already epoch indices).
            indices = farm[s].filter { $0 >= 0 && $0 < numTrig }
        } else if let neighbors = moosmannNeighbors {
            // Moosmann: average the same slice position across the most
            // motion-similar volumes. Epoch s -> (volume, sliceIndex).
            let volume = sliceTrigger ? s / slices : s
            let sliceIndex = sliceTrigger ? s % slices : 0
            if volume < neighbors.count, !neighbors[volume].isEmpty {
                for vol in neighbors[volume] {
                    let idx = sliceTrigger ? vol * slices + sliceIndex : vol
                    if idx >= 0 && idx < numTrig { indices.append(idx) }
                }
            }
        }
        if !indices.isEmpty {
            // use FARM/Moosmann-selected indices below
        } else if sliceTrigger {
            // Average every 2nd neighbor within +/- halfWindow (odd/even slice
            // timing), saturating at the boundaries (FACET AvgArtWghtSliceTrigger).
            var start = s - halfWindow
            if start < 1 { start = (s % 2 == 0) ? 2 : 1 }
            var i = start
            while i <= s + halfWindow {
                if i >= 0 && i < numTrig { indices.append(i) }
                i += 2
            }
        } else {
            for i in (s - halfWindow)...(s + halfWindow) where i >= 0 && i < numTrig {
                indices.append(i)
            }
        }

        // Drop censored (e.g. high-motion) donors. If that empties the set, keep
        // the original (better an imperfect template than none); otherwise top up
        // to the original count by walking outward so the window doesn't shrink.
        if !censoredEpochs.isEmpty {
            let kept = indices.filter { !censoredEpochs.contains($0) }
            if !kept.isEmpty {
                indices = topUpDonors(kept, center: s, stride: sliceTrigger ? 2 : 1,
                                      target: indices.count, numTrig: numTrig,
                                      censored: censoredEpochs)
            }
        }

        guard let first = epoch(indices.first ?? s) else { return nil }
        let length = first.count
        var avg = [Double](repeating: 0, count: length)
        var count = 0
        for idx in indices {
            guard let e = epoch(idx) else { continue }
            let arr = Array(e)
            for i in 0..<length { avg[i] += arr[i] }
            count += 1
        }
        guard count > 0 else { return nil }
        let inv = 1.0 / Double(count)
        for i in 0..<length { avg[i] *= inv }
        return avg
    }

    // MARK: - Optimal basis set (OBS)

    private nonisolated static func optimalBasisSet(
        idata: [Double], iNoise: [Double], alignedMarkers: [Int],
        prePeak: Int, postPeak: Int, artLength: Int,
        numTrig: Int, sliceTrigger: Bool,
        censoredEpochs: Set<Int>,
        obsHPF: [Double], mode: OBSMode
    ) -> [Double] {
        let upLength = idata.count
        var fittedRes = [Double](repeating: 0, count: upLength)

        // High-pass the residual (data - template).
        let residual = zip(idata, iNoise).map(-)
        let ipca = DSP.filtfiltFIR(obsHPF, residual)

        // Build the PCA matrix from a subset of epochs (every 2nd/3rd).
        func epochSlice(_ s: Int, from source: [Double]) -> [Double]? {
            let start = alignedMarkers[s] - prePeak
            let end = alignedMarkers[s] + postPeak
            guard start >= 0, end < upLength else { return nil }
            return Array(source[start...end])
        }

        var pcaEpochs: [[Double]] = []
        var skip = 2
        var s = 1
        while s < numTrig - 1 {
            // Skip censored (e.g. high-motion) epochs so they don't pollute the
            // optimal basis set; the OBS fit is still applied to every epoch.
            if !censoredEpochs.contains(s), var e = epochSlice(s, from: ipca) {
                let m = e.reduce(0, +) / Double(e.count)
                for i in 0..<e.count { e[i] -= m }  // detrend (remove mean)
                pcaEpochs.append(e)
            }
            // pick every 2nd or 3rd epoch
            s += skip
            skip = (skip == 2) ? 3 : 2
        }
        guard pcaEpochs.count > 2 else { return fittedRes }

        let (basis, oev) = DSP.pca(epochs: pcaEpochs)
        guard !basis.isEmpty else { return fittedRes }

        let pcs: Int
        switch mode {
        case .fixed(let k): pcs = min(max(1, k), basis.count)
        case .auto: pcs = autoSelectPCs(oev: oev, max: basis.count)
        case .off: return fittedRes
        }
        guard pcs > 0 else { return fittedRes }

        // Build design columns: first `pcs` PCs (+ DC for volume triggers).
        var columns = Array(basis[0..<pcs])
        if !sliceTrigger {
            columns.append([Double](repeating: 1, count: artLength))
        }
        // Scale PCs 2..n to the range of PC1 (matches FMRIB/FACET).
        if let range0 = columnRange(columns[0]), range0 > 0 {
            for k in 1..<pcs {
                if let rk = columnRange(columns[k]), rk > 0 {
                    let scale = range0 / rk
                    for i in 0..<columns[k].count { columns[k][i] *= scale }
                }
            }
        }

        // Fit each epoch's high-passed residual onto the OBS and subtract.
        for s in 0..<numTrig {
            guard let target = epochSlice(s, from: ipca) else { continue }
            let fit = DSP.leastSquaresFit(target: target, design: columns)
            let start = alignedMarkers[s] - prePeak
            for i in 0..<artLength { fittedRes[start + i] = fit[i] }
        }
        return fittedRes
    }

    /// Auto-select the number of OBS PCs via FMRIB/FACET's three thresholds.
    private nonisolated static func autoSelectPCs(oev: [Double], max: Int) -> Int {
        let thSlope = 2.0, thCumVar = 80.0, thVarExp = 5.0
        guard oev.count > 4 else { return min(4, max) }

        // SLOPE threshold: first run of 3 consecutive unit gaps in indices where
        // |diff(oev)| < thSlope.
        var dOev: [Int] = []
        for i in 0..<(oev.count - 1) where abs(oev[i + 1] - oev[i]) < thSlope {
            dOev.append(i)
        }
        var slopePC = 4
        if dOev.count >= 4 {
            let dd = zip(dOev.dropFirst(), dOev).map { $0 - $1 }
            for i in 0..<(dd.count - 2) where dd[i] == 1 && dd[i + 1] == 1 && dd[i + 2] == 1 {
                slopePC = dOev[i] - 1
                break
            }
        }

        // CUMVAR threshold: first index where cumulative variance > thCumVar.
        var cum = 0.0
        var cumvarPC = oev.count
        for (i, v) in oev.enumerated() {
            cum += v
            if cum > thCumVar { cumvarPC = i + 1; break }
        }

        // VAREXP threshold: first index where variance < thVarExp, minus 1.
        var varexpPC = oev.count
        for (i, v) in oev.enumerated() where v < thVarExp { varexpPC = i; break }

        let pcs = Int((Double(slopePC) + Double(cumvarPC) + Double(varexpPC)) / 3.0)
        return Swift.max(1, Swift.min(pcs, max))
    }

    // MARK: - Adaptive noise cancellation

    private nonisolated static func adaptiveNoiseCancel(
        clean: [Double], noise: [Double], triggers: [Int], L: Int,
        artLength: Int, samplingRate: Double
    ) -> [Double] {
        let n = clean.count
        // ANC high-pass (volume-trigger ANCf = 2 Hz, per FMRIB).
        let nyq = 0.5 * samplingRate
        let ancf = 2.0, trans = 0.15
        var order = Int((1.2 * samplingRate / (ancf * (1 - trans))).rounded())
        if order % 2 != 0 { order += 1 }
        order = Swift.max(order, 16)
        let hp = DSP.firls(numtaps: order + 1,
                           bands: [(0, ancf * (1 - trans) / nyq), (ancf / nyq, 1)],
                           desired: [(0, 0), (1, 1)])
        let refs = noise
        let tmpd = DSP.filtfiltFIR(hp, clean)
        var num = 0.0, den = 0.0
        for i in 0..<n { num += tmpd[i] * refs[i]; den += refs[i] * refs[i] }
        let alpha = den == 0 ? 0 : num / den
        let scaledRefs = refs.map { alpha * $0 }
        var variance = 0.0
        let meanR = scaledRefs.reduce(0, +) / Double(max(1, n))
        for v in scaledRefs { variance += (v - meanR) * (v - meanR) }
        variance /= Double(max(1, n - 1))
        let filterOrder = Swift.max(1, Int((Double(artLength) / Double(L)).rounded()))
        guard variance > 0 else { return clean }
        let mu = 0.05 / (Double(filterOrder) * variance)
        let (out, y) = DSP.lmsAdaptiveFilter(reference: scaledRefs, data: clean, order: filterOrder, mu: mu)
        if y.contains(where: { $0.isInfinite || $0.isNaN }) { return clean }
        _ = out
        return zip(clean, y).map(-)
    }

    // MARK: - Helpers

    /// Generate slice triggers by evenly subdividing each volume interval.
    private nonisolated static func sliceTriggers(volumeTriggers: [Int], slices: Int, sampleCount: Int) -> [Int] {
        guard slices > 1 else { return volumeTriggers }
        let diffs = zip(volumeTriggers.dropFirst(), volumeTriggers).map { $0 - $1 }
        let medianInterval = median(diffs)
        var result: [Int] = []
        for (i, v) in volumeTriggers.enumerated() {
            let interval = i + 1 < volumeTriggers.count ? volumeTriggers[i + 1] - v : medianInterval
            let spacing = Double(interval) / Double(slices)
            for j in 0..<slices {
                let pos = v + Int((Double(j) * spacing).rounded())
                if pos >= 0 && pos < sampleCount { result.append(pos) }
            }
        }
        return result.sorted()
    }

    /// Moosmann (2009) realignment-parameter-informed (RP-info) neighbor sets, a
    /// port of the Bergen toolbox `m_rp_info` / `m_single_motion`.
    ///
    /// For each volume, the template is drawn from a temporal window of `window`
    /// (k) volumes that is *warped by motion* so it does not average across a
    /// head-movement event, and excludes volumes whose own motion exceeds the
    /// threshold. Specifically:
    ///   - motion magnitude = translation speed = ‖Δ(dS,dL,dP)‖ per volume
    ///     (rotation is ignored, matching the reference's `p_trans_rot_scale=0`);
    ///   - speeds at or below `thresholdMm` are zeroed; if none exceed it the
    ///     result is nil and the caller falls back to a plain moving average;
    ///   - distance = triangular temporal distance + (k / min positive speed) ·
    ///     cumulative signed motion; supra-threshold volumes are excluded;
    ///   - the `window` smallest-distance volumes form the template.
    ///
    /// Motion is front-padded to the volume count (per the reference, to respect
    /// dummy scans excluded before SPM realignment).
    nonisolated static func moosmannVolumeNeighbors(
        motion: [MotionSample]?, volumeCount n: Int, window k: Int,
        thresholdMm: Double
    ) -> [[Int]]? {
        guard let motion, motion.count >= 2, n >= 2, k >= 1 else { return nil }

        // Translation speed (mm) per motion row; first row has no predecessor.
        var speedRows = [Double](repeating: 0, count: motion.count)
        for i in 1..<motion.count {
            let dx = motion[i].dS - motion[i - 1].dS
            let dy = motion[i].dL - motion[i - 1].dL
            let dz = motion[i].dP - motion[i - 1].dP
            speedRows[i] = (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        // Threshold: keep only supra-threshold speeds (others -> 0).
        for i in speedRows.indices where speedRows[i] <= thresholdMm { speedRows[i] = 0 }

        // Front-pad / trim to the volume count.
        var speed = [Double](repeating: 0, count: n)
        let diffN = n - motion.count
        if diffN >= 0 {
            for i in 0..<motion.count { speed[i + diffN] = speedRows[i] }
        } else {
            for i in 0..<n { speed[i] = speedRows[i - diffN] }  // trailing volumes
        }

        // No supra-threshold motion -> standard moving average (caller fallback).
        let positives = speed.filter { $0 > 0 }
        guard let minPositive = positives.min() else { return nil }
        let motionScaling = Double(k) / minPositive

        var neighbors = [[Int]](repeating: [], count: n)
        for j in 0..<n {
            var dist = [Double](repeating: 0, count: n)
            var cum = 0.0
            for i in 0..<n {
                // Triangular temporal distance |i - j| + 1.
                var d = Double(abs(i - j) + 1)
                // Warp by cumulative signed motion: negative left of j, positive right.
                cum += (i <= j ? -speed[i] : speed[i])
                d += motionScaling * cum
                dist[i] = d
            }
            // Exclude volumes with supra-threshold motion (sort to the end).
            for i in 0..<n where speed[i] > 0 { dist[i] = .infinity }
            let order = (0..<n).sorted { dist[$0] < dist[$1] }
            let valid = order.filter { dist[$0].isFinite }
            neighbors[j] = Array((valid.isEmpty ? order : valid).prefix(k))
        }
        return neighbors
    }

    /// FARM (van der Meer 2010 / FACET `AvgArtWghtFARM`) epoch selection: for each
    /// epoch, the indices of the `select` most-correlated epochs within a
    /// ±`searchHalf` neighborhood whose absolute correlation is ≥ 0.9 (excluding
    /// the epoch itself). Entries with no sufficiently-correlated neighbors are
    /// left empty so the caller falls back to the temporal-neighbor window.
    ///
    /// `epochs[s]` is the aligned epoch waveform, or nil if it fell outside data.
    nonisolated static func farmEpochNeighbors(
        epochs: [[Double]?], select: Int, searchHalf: Int, threshold: Double = 0.9
    ) -> [[Int]] {
        let n = epochs.count
        var result = [[Int]](repeating: [], count: n)
        for s in 0..<n {
            guard let es = epochs[s] else { continue }
            let a = max(0, s - searchHalf)
            let b = min(n - 1, s + searchHalf)
            var candidates: [(index: Int, corr: Double)] = []
            for j in a...b where j != s {
                guard let ej = epochs[j], ej.count == es.count else { continue }
                let c = abs(DSP.pearson(es[...], ej[...]))
                if c >= threshold { candidates.append((j, c)) }
            }
            candidates.sort { $0.corr > $1.corr }
            result[s] = candidates.prefix(max(1, select)).map { $0.index }
        }
        return result
    }

    /// Extend a (censored-filtered) donor list back toward its original size by
    /// walking outward from `center` in `stride` steps, appending the nearest
    /// non-censored, in-bounds, not-already-included epochs. Keeps the averaging
    /// window from shrinking near motion. Bounded so it cannot run away.
    private nonisolated static func topUpDonors(
        _ kept: [Int], center s: Int, stride: Int, target: Int,
        numTrig: Int, censored: Set<Int>
    ) -> [Int] {
        guard kept.count < target else { return kept }
        var result = kept
        var have = Set(kept)
        let maxRadius = max(target * stride * 3, stride * 8)
        var d = stride
        while result.count < target && d <= maxRadius {
            for cand in [s - d, s + d] {
                guard cand >= 0, cand < numTrig, !censored.contains(cand), !have.contains(cand)
                else { continue }
                result.append(cand)
                have.insert(cand)
                if result.count >= target { break }
            }
            d += stride
        }
        return result
    }

    private nonisolated static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private nonisolated static func columnRange(_ v: [Double]) -> Double? {
        guard let mn = v.min(), let mx = v.max() else { return nil }
        return mx - mn
    }

    private nonisolated static func obsHighPassWeights(hpf: Double, nyq: Double, L: Int, fs: Double) -> [Double] {
        var order = Int((1.2 * fs * Double(L) / (hpf - 10)).rounded())
        if order % 2 != 0 { order += 1 }
        order = Swift.max(order, 16)
        let nyqL = nyq * Double(L)
        return DSP.firls(numtaps: order + 1,
                         bands: [(0, (hpf - 10) / nyqL), ((hpf + 10) / nyqL, 1)],
                         desired: [(0, 0), (1, 1)])
    }

    private nonisolated static func lowPassWeights(lpf: Double, fs: Double) -> [Double] {
        let nyq = 0.5 * fs
        let trans = 0.15
        var order = Int((3 * Double(Int(fs / lpf))).rounded())
        if order % 2 != 0 { order += 1 }
        order = Swift.max(order, 16)
        return DSP.firls(numtaps: order + 1,
                         bands: [(0, lpf / nyq), (lpf * (1 + trans) / nyq, 1)],
                         desired: [(1, 1), (0, 0)])
    }

    // MARK: - Aligner

    /// Encapsulates epoch alignment (integer cross-correlation + optional
    /// sub-sample fractional shift). Alignment is computed on one channel and the
    /// resulting integer markers are shared across channels.
    private struct Aligner {
        let markersUp: [Int]
        let prePeak: Int
        let postPeak: Int
        let artLength: Int
        let searchWindow: Int
        let subSample: Bool

        func align(dataUp: [Double]) -> [Int] {
            let upLength = dataUp.count
            var aligned = markersUp
            // Reference template = first valid epoch.
            guard let refStart = markersUp.first, refStart - prePeak >= 0,
                  refStart + postPeak < upLength else { return aligned }
            let reference = Array(dataUp[(refStart - prePeak)...(refStart + postPeak)])

            for s in markersUp.indices {
                let center = markersUp[s]
                var bestCorr = -Double.infinity
                var bestShift = 0
                for shift in -searchWindow...searchWindow {
                    let c = center + shift
                    let start = c - prePeak, end = c + postPeak
                    guard start >= 0, end < upLength else { continue }
                    let corr = DSP.pearson(dataUp[start...end], reference[...])
                    if corr > bestCorr { bestCorr = corr; bestShift = shift }
                }
                aligned[s] = center + bestShift
            }
            return aligned
        }
    }
}
