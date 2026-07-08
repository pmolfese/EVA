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
//  sub-sample) -> average-artifact template -> FACET template-specific
//  re-alignment -> amplitude-scaled subtraction -> optional OBS residual
//  removal (PCA) -> downsample -> optional ANC.
//
//  TODO: validate against a MATLAB FASTR reference output (no reference dataset
//  available yet).
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

    enum MotionMetric: String, CaseIterable, Identifiable, Sendable {
        case translationOnly
        case allParameters

        var id: String { rawValue }

        var label: String {
            switch self {
            case .translationOnly: return "Translation"
            case .allParameters: return "All 6"
            }
        }

        var help: String {
            switch self {
            case .translationOnly:
                return "BERGEN-faithful RP-info: use translation speed only."
            case .allParameters:
                return "Use translations plus rotations converted to millimeters by the rotation radius."
            }
        }
    }

    nonisolated enum OBSMode: Sendable, Equatable {
        case off
        case auto
        case fixed(Int)
    }

    enum ANCHighPassMode: String, CaseIterable, Identifiable, Sendable {
        case fixed2Hz
        case sliceTriggerDependent

        var id: String { rawValue }
    }

    struct Config: Sendable {
        /// Interpolation factor L (upsampling before template formation).
        var upsampleFactor = 10
        /// Number of fMRI slices per volume; the volume interval is split into
        /// this many epochs. 1 == treat each volume as a single epoch.
        var numberOfSlices = 1
        /// Number of epochs averaged into each artifact template.
        var averagingWindow = 30
        /// Optional asymmetric template window from the UI. When nil, the legacy
        /// symmetric `averagingWindow / 2` behavior is used.
        var averagingWindowBefore: Int? = nil
        var averagingWindowAfter: Int? = nil
        /// Use FACET's AvgWindow/HalfWindow matrix semantics instead of EVA's
        /// asymmetric pre/post window. This preserves FACET's edge saturation and
        /// odd/even slice donor rows.
        var useFacetAveragingWindow = false
        /// BERGEN-style squared-correlation donor ranking, using the best r^2
        /// candidates instead of the default neighbor/FARM donor rule. For
        /// Moosmann, r^2 ranking is constrained to the RP-informed candidate set.
        var usesBergenRSquareDonors = false
        /// Relative trigger position within the artifact (0 = start, 1 = end).
        var relativeTriggerPosition = 0.03
        /// FACET-style fractional-sample alignment of epochs.
        var subSampleAlignment = true
        /// FACET's second alignment pass: align every epoch to the average
        /// artifact template built specifically for that epoch before alpha
        /// scaling and subtraction.
        var alignToAverageArtifact = true
        var templateScheme: TemplateScheme = .neighbor
        /// Optimal-basis-set residual removal.
        var obs: OBSMode = .auto
        /// High-pass cutoff (Hz) for OBS residual matrix formation.
        var obsHighPassHz = 70.0
        /// Match FACET's random 2/3 epoch subset for OBS PCA matrix formation.
        /// False keeps EVA deterministic for reproducible replay.
        var randomizeOBSEpochSelection = false
        /// Optional low-pass (Hz) applied to the corrected signal.
        var lowPassHz: Double? = nil
        /// Adaptive noise cancellation after template subtraction.
        var anc = false
        /// High-pass used before LMS ANC: EVA/FMRIB fixed 2 Hz or FACET's
        /// slice-trigger-rate-dependent cutoff for slice-triggered data.
        var ancHighPassMode: ANCHighPassMode = .fixed2Hz
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
        /// Motion vector used by the Moosmann RP-info donor selector.
        var moosmannMotionMetric: MotionMetric = .translationOnly
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

    nonisolated private static let donorSelectionParallelThreshold = 16

    private struct PreparedEpoch: Sendable {
        let values: [Double]
        let mean: Double
        let sumSquaresCentered: Double
    }

    private struct AlignmentResult: Sendable {
        let markers: [Int]
        let fractionalShifts: [Double]
    }

    private struct TemplateSelection: Sendable {
        let windowBefore: Int
        let windowAfter: Int
        let templateCount: Int
        let moosmannWindow: Int
        let facetTemporalDonors: [[Int]]?
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
        try Task.checkCancellation()
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
        let templateSelection = makeTemplateSelection(
            config: config,
            numTrig: markersUp.count,
            sliceTrigger: sliceTrigger
        )

        // OBS high-pass filter weights (designed on the upsampled axis).
        let nyq = 0.5 * samplingRate
        let obsHPF = obsHighPassWeights(hpf: config.obsHighPassHz, nyq: nyq, L: L, fs: samplingRate)

        // Moosmann (RP-info) per-volume neighbor sets, if requested and usable.
        let moosmannNeighbors: [[Int]]? = config.templateScheme == .moosmann
            ? moosmannVolumeNeighbors(motion: config.motion,
                                      volumeCount: volumeTriggers.count,
                                      window: templateSelection.moosmannWindow,
                                      thresholdMm: config.motionThresholdMm,
                                      metric: config.moosmannMotionMetric,
                                      radiusMm: config.motionRadiusMm)
            : nil

        // Alignment is computed once on channel 0 and reused for all channels.
        let aligner = Aligner(
            markersUp: markersUp,
            prePeak: prePeak, postPeak: postPeak,
            artLength: artLength, searchWindow: searchWindow,
            subSample: config.subSampleAlignment
        )

        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0
        let totalUnits = channels.count

        var result = channels
        // Compute the aligned markers from channel 0 first (shared across channels).
        let channel0Up = DSP.interp(channels[0].map(Double.init), factor: L)
        let alignment = aligner.align(dataUp: channel0Up)
        let alignedMarkers = alignment.markers
        let templateAlignedMarkers: [Int]
        if config.alignToAverageArtifact {
            let channel0ZeroMeanUp = zeroMeanUpsampled(channels[0].map(Double.init), factor: L)
            let channel0Prepared = applySubSampleShifts(
                to: channel0ZeroMeanUp,
                markers: alignedMarkers,
                prePeak: prePeak,
                postPeak: postPeak,
                shifts: alignment.fractionalShifts
            )
            let censoredEpochs = censoredEpochIndices(
                numTrig: alignedMarkers.count,
                sliceTrigger: sliceTrigger,
                slices: slices,
                censoredVolumes: config.censoredVolumes
            )
            let templates = averageArtifactTemplates(
                idata: channel0Prepared,
                markers: alignedMarkers,
                prePeak: prePeak,
                postPeak: postPeak,
                templateSelection: templateSelection,
                sliceTrigger: sliceTrigger,
                slices: slices,
                moosmannNeighbors: moosmannNeighbors,
                censoredEpochs: censoredEpochs,
                config: config
            ).templates
            templateAlignedMarkers = alignToAverageArtifacts(
                dataUp: channel0Prepared,
                baseMarkers: alignedMarkers,
                templates: templates,
                prePeak: prePeak,
                postPeak: postPeak,
                searchWindow: searchWindow
            )
        } else {
            templateAlignedMarkers = alignedMarkers
        }

        // Use an explicitly managed buffer so concurrent writes to distinct slots are safe.
        nonisolated(unsafe) let resultPtr = UnsafeMutablePointer<[Float]>.allocate(capacity: channels.count)
        resultPtr.initialize(from: &result, count: channels.count)
        evaConcurrentPerform(iterations: channels.count) { c in
            guard !Task.isCancelled else { return }
            let raw = channels[c].map(Double.init)
            let corrected = correctChannel(
                raw: raw,
                channelIndex: c,
                alignedMarkers: alignedMarkers,
                templateAlignedMarkers: templateAlignedMarkers,
                fractionalShifts: alignment.fractionalShifts,
                L: L,
                prePeak: prePeak, postPeak: postPeak, artLength: artLength,
                templateSelection: templateSelection,
                sliceTrigger: sliceTrigger,
                slices: slices,
                moosmannNeighbors: moosmannNeighbors,
                censoredVolumes: config.censoredVolumes,
                searchWindow: searchWindow,
                obsHPF: obsHPF,
                config: config, samplingRate: samplingRate
            )
            resultPtr[c] = corrected.map { Float($0) }

            if let progress {
                progressLock.lock()
                completed += 1
                let fraction = Double(completed) / Double(totalUnits)
                progressLock.unlock()
                progress(fraction)
            }
        }
        result = Array(UnsafeBufferPointer(start: resultPtr, count: channels.count))
        resultPtr.deinitialize(count: channels.count)
        resultPtr.deallocate()
        return result
    }

    // MARK: - Per-channel correction

    private nonisolated static func correctChannel(
        raw: [Double],
        channelIndex c: Int,
        alignedMarkers: [Int],
        templateAlignedMarkers: [Int],
        fractionalShifts: [Double],
        L: Int,
        prePeak: Int, postPeak: Int, artLength: Int,
        templateSelection: TemplateSelection,
        sliceTrigger: Bool,
        slices: Int,
        moosmannNeighbors: [[Int]]?,
        censoredVolumes: Set<Int>,
        searchWindow: Int,
        obsHPF: [Double],
        config: Config, samplingRate: Double
    ) -> [Double] {
        let n = raw.count
        var idata = zeroMeanUpsampled(raw, factor: L)
        var iorig = DSP.interp(raw, factor: L)
        idata = applySubSampleShifts(
            to: idata,
            markers: alignedMarkers,
            prePeak: prePeak,
            postPeak: postPeak,
            shifts: fractionalShifts
        )
        iorig = applySubSampleShifts(
            to: iorig,
            markers: alignedMarkers,
            prePeak: prePeak,
            postPeak: postPeak,
            shifts: fractionalShifts
        )
        let upLength = idata.count

        let numTrig = alignedMarkers.count
        let excluded = config.excludedChannels.contains(c)

        // Map censored volumes to censored epoch indices (a volume spans `slices`
        // slice epochs when slice-triggered).
        let censoredEpochs = censoredEpochIndices(
            numTrig: numTrig,
            sliceTrigger: sliceTrigger,
            slices: slices,
            censoredVolumes: censoredVolumes
        )

        // Build noise estimate (template) over the whole upsampled signal.
        var iNoise = [Double](repeating: 0, count: upLength)

        let templates = averageArtifactTemplates(
            idata: idata,
            markers: alignedMarkers,
            prePeak: prePeak,
            postPeak: postPeak,
            templateSelection: templateSelection,
            sliceTrigger: sliceTrigger,
            slices: slices,
            moosmannNeighbors: moosmannNeighbors,
            censoredEpochs: censoredEpochs,
            config: config
        ).templates

        func alignedTarget(_ s: Int) -> ArraySlice<Double>? {
            let start = templateAlignedMarkers[s] - prePeak
            let end = templateAlignedMarkers[s] + postPeak
            guard start >= 0, end < upLength else { return nil }
            return idata[start...end]
        }

        for s in 0..<numTrig {
            guard let avg = templates[s] else { continue }
            guard let target = alignedTarget(s) else { continue }

            // Amplitude scale (Alpha) to minimize squared error, unless excluded.
            let alpha: Double
            if excluded {
                alpha = 1
            } else {
                let vectorLength = vDSP_Length(avg.count)
                var num = 0.0
                var den = 0.0
                avg.withUnsafeBufferPointer { avgBuf in
                    target.withUnsafeBufferPointer { targetBuf in
                        guard let avgBase = avgBuf.baseAddress, let targetBase = targetBuf.baseAddress else { return }
                        vDSP_dotprD(targetBase, 1, avgBase, 1, &num, vectorLength)
                        vDSP_dotprD(avgBase, 1, avgBase, 1, &den, vectorLength)
                    }
                }
                alpha = den == 0 ? 0 : num / den
            }
            let start = templateAlignedMarkers[s] - prePeak
            guard start >= 0, start + avg.count <= iNoise.count else { continue }
            var scaledAlpha = alpha
            avg.withUnsafeBufferPointer { avgBuf in
                iNoise.withUnsafeMutableBufferPointer { noiseBuf in
                    guard let avgBase = avgBuf.baseAddress, let noiseBase = noiseBuf.baseAddress else { return }
                    vDSP_vsmulD(avgBase, 1, &scaledAlpha, noiseBase + start, 1, vDSP_Length(avg.count))
                }
            }
        }

        // OBS residual removal.
        var fittedRes = [Double](repeating: 0, count: upLength)
        if !excluded, config.obs != .off {
            fittedRes = optimalBasisSet(
                idata: idata, iNoise: iNoise, alignedMarkers: alignedMarkers,
                prePeak: prePeak, postPeak: postPeak, artLength: artLength,
                numTrig: numTrig, sliceTrigger: sliceTrigger,
                censoredEpochs: censoredEpochs,
                obsHPF: obsHPF, mode: config.obs,
                randomizeEpochSelection: config.randomizeOBSEpochSelection
            )
        }

        // Corrected (upsampled) = original - template - fitted residual.
        var totalNoise = [Double](repeating: 0, count: upLength)
        let upVectorLength = vDSP_Length(upLength)
        vDSP_vaddD(iNoise, 1, fittedRes, 1, &totalNoise, 1, upVectorLength)
        // vDSP_vsubD computes C = B - A, i.e. original - noise.
        vDSP_vsubD(totalNoise, 1, iorig, 1, &idata, 1, upVectorLength)

        // Downsample back.
        var cleanEEG = L > 1 ? DSP.decimate(idata, factor: L) : idata
        var noise = L > 1 ? DSP.decimate(totalNoise, factor: L) : totalNoise
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
                                           artLength: artLength, samplingRate: samplingRate,
                                           sliceTrigger: sliceTrigger,
                                           highPassMode: config.ancHighPassMode)
        }
        return cleanEEG
    }

    // MARK: - Template averaging

    private nonisolated static func makeTemplateSelection(
        config: Config,
        numTrig: Int,
        sliceTrigger: Bool
    ) -> TemplateSelection {
        let legacyHalfWindow = max(1, config.averagingWindow / 2)
        let windowBefore = max(0, config.averagingWindowBefore ?? legacyHalfWindow)
        let windowAfter = max(0, config.averagingWindowAfter ?? legacyHalfWindow)
        if config.useFacetAveragingWindow {
            let avgWindow = correctedFacetAvgWindow(
                config.averagingWindow,
                numTrig: numTrig,
                sliceTrigger: sliceTrigger
            )
            let halfWindow = sliceTrigger ? avgWindow : max(1, avgWindow / 2)
            return TemplateSelection(
                windowBefore: windowBefore,
                windowAfter: windowAfter,
                templateCount: avgWindow,
                moosmannWindow: max(1, 2 * halfWindow),
                facetTemporalDonors: facetTemporalDonorRows(
                    numTrig: numTrig,
                    halfWindow: halfWindow,
                    sliceTrigger: sliceTrigger
                )
            )
        }

        let templateCount = max(1, windowBefore + windowAfter)
        return TemplateSelection(
            windowBefore: windowBefore,
            windowAfter: windowAfter,
            templateCount: templateCount,
            moosmannWindow: templateCount,
            facetTemporalDonors: nil
        )
    }

    private nonisolated static func correctedFacetAvgWindow(
        _ requested: Int,
        numTrig: Int,
        sliceTrigger: Bool
    ) -> Int {
        var avgWindow = max(2, requested)
        if avgWindow % 2 != 0 { avgWindow += 1 }

        let maxWindow: Int
        if sliceTrigger {
            maxWindow = max(2, (numTrig - 3) / 2)
        } else {
            maxWindow = max(2, numTrig - 2)
        }
        if avgWindow > maxWindow {
            avgWindow = maxWindow
            if avgWindow % 2 != 0 { avgWindow -= 1 }
        }
        return max(2, avgWindow)
    }

    nonisolated static func facetTemporalDonorRows(
        numTrig: Int,
        halfWindow: Int,
        sliceTrigger: Bool
    ) -> [[Int]] {
        guard numTrig > 0 else { return [] }
        let half = max(1, halfWindow)
        var rows = [[Int]]()
        rows.reserveCapacity(numTrig)

        var iStartOneBased = 2
        for sZero in 0..<numTrig {
            let s = sZero + 1
            if sliceTrigger {
                if s == 1 {
                    iStartOneBased = 2
                } else if s == 2 {
                    iStartOneBased = 3
                } else if s > (3 + half), s <= (numTrig - (half + 2)) {
                    iStartOneBased = s - half
                }

                var row: [Int] = []
                var i = iStartOneBased
                while i <= iStartOneBased + 2 * half {
                    let zero = i - 1
                    if zero >= 0, zero < numTrig { row.append(zero) }
                    i += 2
                }
                rows.append(row)
            } else {
                if s == 1 {
                    iStartOneBased = 2
                } else if s > (3 + half), s <= (numTrig - (half + 2)) {
                    iStartOneBased = s - half - 1
                }

                var row: [Int] = []
                let last = iStartOneBased + 2 * half
                if iStartOneBased <= last {
                    for i in iStartOneBased...last {
                        let zero = i - 1
                        if zero >= 0, zero < numTrig { row.append(zero) }
                    }
                }
                rows.append(row)
            }
        }
        return rows
    }

    private nonisolated static func averageArtifactTemplates(
        idata: [Double],
        markers: [Int],
        prePeak: Int,
        postPeak: Int,
        templateSelection: TemplateSelection,
        sliceTrigger: Bool,
        slices: Int,
        moosmannNeighbors: [[Int]]?,
        censoredEpochs: Set<Int>,
        config: Config
    ) -> (templates: [[Double]?], epochs: [[Double]?]) {
        let numTrig = markers.count
        let upLength = idata.count
        let epochs = (0..<numTrig).map { s -> [Double]? in
            let start = markers[s] - prePeak
            let end = markers[s] + postPeak
            guard start >= 0, end < upLength else { return nil }
            return Array(idata[start...end])
        }

        let correlationCandidatePools: [[Int]]? = config.usesBergenRSquareDonors
            ? bergenRSquareCandidatePools(
                numTrig: numTrig,
                sliceTrigger: sliceTrigger,
                slices: slices,
                moosmannNeighbors: moosmannNeighbors
            )
            : nil

        let bergenRSquareNeighbors: [[Int]]? = config.usesBergenRSquareDonors
            ? bergenRSquareEpochNeighbors(
                epochs: epochs,
                select: templateSelection.templateCount,
                candidatePools: correlationCandidatePools,
                excludedEpochs: censoredEpochs
            )
            : nil

        let farmNeighbors: [[Int]]? = !config.usesBergenRSquareDonors && config.templateScheme == .farm
            ? farmEpochNeighbors(
                epochs: epochs,
                select: max(2, templateSelection.templateCount),
                searchHalf: max(2 * templateSelection.templateCount, 25)
            )
            : nil

        let templates = (0..<numTrig).map { s in
            averageTemplate(
                center: s,
                numTrig: numTrig,
                templateSelection: templateSelection,
                sliceTrigger: sliceTrigger,
                slices: slices,
                moosmannNeighbors: moosmannNeighbors,
                farmNeighbors: farmNeighbors,
                bergenRSquareNeighbors: bergenRSquareNeighbors,
                censoredEpochs: censoredEpochs
            ) { idx in
                guard idx >= 0, idx < epochs.count else { return nil }
                return epochs[idx]
            }
        }

        return (templates, epochs)
    }

    private nonisolated static func averageTemplate(
        center s: Int, numTrig: Int,
        templateSelection: TemplateSelection,
        sliceTrigger: Bool,
        slices: Int,
        moosmannNeighbors: [[Int]]?,
        farmNeighbors: [[Int]]?,
        bergenRSquareNeighbors: [[Int]]?,
        censoredEpochs: Set<Int>,
        epoch: (Int) -> [Double]?
    ) -> [Double]? {
        // Collect contributing epoch indices.
        var indices: [Int] = []
        if let rSquared = bergenRSquareNeighbors, s < rSquared.count, !rSquared[s].isEmpty {
            indices = rSquared[s].filter { $0 >= 0 && $0 < numTrig }
        } else if let farm = farmNeighbors, s < farm.count, !farm[s].isEmpty {
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
        } else if let facetRows = templateSelection.facetTemporalDonors, s < facetRows.count {
            indices = facetRows[s]
        } else if sliceTrigger {
            // Average every 2nd neighbor within the requested pre/post window (odd/even slice
            // timing), saturating at the boundaries (FACET AvgArtWghtSliceTrigger).
            var start = s - templateSelection.windowBefore
            if start < 1 { start = (s % 2 == 0) ? 2 : 1 }
            var i = start
            while i <= s + templateSelection.windowAfter {
                if i >= 0 && i < numTrig { indices.append(i) }
                i += 2
            }
        } else {
            let start = max(0, s - templateSelection.windowBefore)
            let end = min(numTrig - 1, s + templateSelection.windowAfter)
            if start <= end {
                for i in start...end { indices.append(i) }
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
        let vlen = vDSP_Length(length)
        var avg = [Double](repeating: 0, count: length)
        var count = 0
        for idx in indices {
            guard let e = epoch(idx) else { continue }
            e.withUnsafeBufferPointer { eBuf in
                vDSP_vaddD(avg, 1, eBuf.baseAddress!, 1, &avg, 1, vlen)
            }
            count += 1
        }
        guard count > 0 else { return nil }
        var inv = 1.0 / Double(count)
        vDSP_vsmulD(avg, 1, &inv, &avg, 1, vlen)
        return avg
    }

    // MARK: - Optimal basis set (OBS)

    private nonisolated static func optimalBasisSet(
        idata: [Double], iNoise: [Double], alignedMarkers: [Int],
        prePeak: Int, postPeak: Int, artLength: Int,
        numTrig: Int, sliceTrigger: Bool,
        censoredEpochs: Set<Int>,
        obsHPF: [Double], mode: OBSMode,
        randomizeEpochSelection: Bool
    ) -> [Double] {
        let upLength = idata.count
        var fittedRes = [Double](repeating: 0, count: upLength)

        // High-pass the residual (data - template).
        let residual = zip(idata, iNoise).map(-)
        let ipca = DSP.filtfiltFIR(obsHPF, residual)

        // Build the PCA matrix from FACET's epoch subset. EVA's default is
        // deterministic for replay; the random option follows FACET's rand-driven
        // 2/3 skip pattern.
        func epochSlice(_ s: Int, from source: [Double]) -> [Double]? {
            let start = alignedMarkers[s] - prePeak
            let end = alignedMarkers[s] + postPeak
            guard start >= 0, end < upLength else { return nil }
            return Array(source[start...end])
        }

        var pcaEpochs: [[Double]] = []
        for s in obsPCAEpochIndices(
            numTrig: numTrig,
            sliceTrigger: sliceTrigger,
            randomized: randomizeEpochSelection
        ) {
            // Skip censored (e.g. high-motion) epochs so they don't pollute the
            // optimal basis set; the OBS fit is still applied to every epoch.
            if !censoredEpochs.contains(s), var e = epochSlice(s, from: ipca) {
                let m = e.reduce(0, +) / Double(e.count)
                for i in 0..<e.count { e[i] -= m }  // detrend (remove mean)
                pcaEpochs.append(e)
            }
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
        artLength: Int, samplingRate: Double,
        sliceTrigger: Bool,
        highPassMode: ANCHighPassMode
    ) -> [Double] {
        let n = clean.count
        // ANC high-pass: EVA/FMRIB fixed 2 Hz by default, or FACET's
        // slice-trigger-rate-dependent cutoff for slice-triggered data.
        let nyq = 0.5 * samplingRate
        let ancf = ancHighPassFrequency(
            triggers: triggers,
            L: L,
            samplingRate: samplingRate,
            sliceTrigger: sliceTrigger,
            mode: highPassMode
        )
        let trans = 0.15
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

    private nonisolated static func zeroMeanUpsampled(_ raw: [Double], factor L: Int) -> [Double] {
        let n = raw.count
        let rawLength = vDSP_Length(n)
        var mean = 0.0
        if n > 0 { vDSP_meanvD(raw, 1, &mean, rawLength) }
        var negMean = -mean
        var zeroMean = [Double](repeating: 0, count: n)
        if n > 0 { vDSP_vsaddD(raw, 1, &negMean, &zeroMean, 1, rawLength) }
        return DSP.interp(zeroMean, factor: L)
    }

    private nonisolated static func censoredEpochIndices(
        numTrig: Int,
        sliceTrigger: Bool,
        slices: Int,
        censoredVolumes: Set<Int>
    ) -> Set<Int> {
        guard !censoredVolumes.isEmpty else { return [] }
        let sliceCount = max(1, slices)
        return Set((0..<numTrig).filter {
            censoredVolumes.contains(sliceTrigger ? $0 / sliceCount : $0)
        })
    }

    nonisolated static func obsPCAEpochIndices(
        numTrig: Int,
        sliceTrigger: Bool,
        randomized: Bool = false,
        randomStep: (() -> Int)? = nil
    ) -> [Int] {
        guard numTrig > 2 else { return [] }
        if randomized {
            var rng = SystemRandomNumberGenerator()
            func nextStep() -> Int {
                if let randomStep {
                    return min(max(randomStep(), 2), 3)
                }
                return Bool.random(using: &rng) ? 3 : 2
            }

            var picks: [Int] = []
            var cumulative = 0
            while cumulative < numTrig {
                cumulative += nextStep()
                picks.append(cumulative)
            }

            if !sliceTrigger {
                guard let start = picks.first, start < numTrig - 1 else { return [] }
                return Array(start..<(numTrig - 1))
            }

            let valid = 1..<(numTrig - 1)
            return picks.filter { valid.contains($0) }
        }

        if !sliceTrigger {
            let start = numTrig > 4 ? 2 : 1
            guard start < numTrig - 1 else { return [] }
            return Array(start..<(numTrig - 1))
        }

        var indices: [Int] = []
        var skip = 2
        var s = 1
        while s < numTrig - 1 {
            indices.append(s)
            s += skip
            skip = (skip == 2) ? 3 : 2
        }
        return indices
    }

    nonisolated static func ancHighPassFrequency(
        triggers: [Int],
        L: Int,
        samplingRate: Double,
        sliceTrigger: Bool,
        mode: ANCHighPassMode
    ) -> Double {
        guard mode == .sliceTriggerDependent, sliceTrigger,
              let first = triggers.first, triggers.count > 1, L > 0,
              samplingRate > 0
        else {
            return 2.0
        }

        let oneSecond = samplingRate * Double(L)
        var triggerCount = 1
        while triggerCount < triggers.count {
            let elapsed = Double(triggers[triggerCount] - first)
            if elapsed >= oneSecond { break }
            triggerCount += 1
        }
        return max(0.1, 0.75 * Double(triggerCount))
    }

    private nonisolated static func applySubSampleShifts(
        to dataUp: [Double],
        markers: [Int],
        prePeak: Int,
        postPeak: Int,
        shifts: [Double]
    ) -> [Double] {
        guard shifts.contains(where: { abs($0) > 1e-9 }) else { return dataUp }
        var shifted = dataUp
        let pad = 10
        for s in markers.indices where s < shifts.count && abs(shifts[s]) > 1e-9 {
            let writeStart = markers[s] - prePeak
            let writeEnd = markers[s] + postPeak
            guard writeStart >= 0, writeEnd < dataUp.count else { continue }

            let segmentStart = max(0, writeStart - pad)
            let segmentEnd = min(dataUp.count - 1, writeEnd + pad)
            guard segmentStart <= segmentEnd else { continue }

            let segment = Array(dataUp[segmentStart...segmentEnd])
            let shiftedSegment = DSP.fractionalShift(segment, by: shifts[s])
            let offset = writeStart - segmentStart
            guard offset >= 0, offset + (writeEnd - writeStart) < shiftedSegment.count else { continue }
            for i in 0...(writeEnd - writeStart) {
                shifted[writeStart + i] = shiftedSegment[offset + i]
            }
        }
        return shifted
    }

    private nonisolated static func alignToAverageArtifacts(
        dataUp: [Double],
        baseMarkers: [Int],
        templates: [[Double]?],
        prePeak: Int,
        postPeak: Int,
        searchWindow: Int
    ) -> [Int] {
        var aligned = baseMarkers
        for s in baseMarkers.indices {
            guard s < templates.count, let template = templates[s], template.count == prePeak + postPeak + 1 else {
                continue
            }
            let shift = bestIntegerShift(
                dataUp: dataUp,
                template: template,
                center: baseMarkers[s],
                prePeak: prePeak,
                postPeak: postPeak,
                searchWindow: searchWindow
            )
            aligned[s] = baseMarkers[s] + shift
        }
        return aligned
    }

    private nonisolated static func bestIntegerShift(
        dataUp: [Double],
        template: [Double],
        center: Int,
        prePeak: Int,
        postPeak: Int,
        searchWindow: Int
    ) -> Int {
        var bestCorr = -Double.infinity
        var bestShift = 0
        for shift in -searchWindow...searchWindow {
            let c = center + shift
            let start = c - prePeak
            let end = c + postPeak
            guard start >= 0, end < dataUp.count else { continue }
            let corr = DSP.pearson(dataUp[start...end], template[...])
            if corr > bestCorr {
                bestCorr = corr
                bestShift = shift
            }
        }
        return bestShift
    }

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
    ///   - motion magnitude defaults to translation speed = ‖Δ(dS,dL,dP)‖ per
    ///     volume (rotation ignored, matching the reference's
    ///     `p_trans_rot_scale=0`), with an option to include all 6 parameters;
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
        thresholdMm: Double,
        metric: MotionMetric = .translationOnly,
        radiusMm: Double = 50
    ) -> [[Int]]? {
        guard let motion, motion.count >= 2, n >= 2, k >= 1 else { return nil }

        // Motion speed (mm) per motion row; first row has no predecessor.
        var speedRows = [Double](repeating: 0, count: motion.count)
        fillResults(&speedRows, iterations: motion.count) { i in
            guard i > 0 else { return 0 }
            return motionSpeed(from: motion[i - 1], to: motion[i],
                               metric: metric, radiusMm: radiusMm)
        }
        // Threshold: keep only supra-threshold speeds (others -> 0).
        for i in speedRows.indices where speedRows[i] <= thresholdMm { speedRows[i] = 0 }

        // Front-pad / trim to the volume count.
        nonisolated(unsafe) var speed = [Double](repeating: 0, count: n)
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

        // Prefix sums of speed so cumulative motion cost is O(1) per (i,j) pair
        // instead of O(n) inside the inner loop.
        nonisolated(unsafe) var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + speed[i] }

        var neighbors = [[Int]](repeating: [], count: n)
        // Each j writes to its own slot — safe to run concurrently.
        nonisolated(unsafe) let neighborsPtr = UnsafeMutablePointer<[Int]>.allocate(capacity: n)
        neighborsPtr.initialize(from: &neighbors, count: n)
        evaConcurrentPerform(iterations: n) { j in
            // dist[i] = |i-j|+1 + motionScaling * (prefix-sum-based cumulative motion)
            // Left of j:  cum = -(prefix[j+1] - prefix[i])
            // Right of j: cum =  prefix[i+1]  - prefix[j+1]
            var dist = [Double](repeating: 0, count: n)
            let prefJ = prefix[j + 1]
            for i in 0..<n {
                let temporal = Double(abs(i - j) + 1)
                let cumMot = i <= j ? (prefJ - prefix[i]) : (prefix[i + 1] - prefJ)
                dist[i] = speed[i] > 0 ? .infinity : temporal + motionScaling * cumMot
            }
            // Partial selection: find k smallest finite distances without a full sort.
            neighborsPtr[j] = kSmallestIndices(dist, k: k)
        }
        neighbors = Array(UnsafeBufferPointer(start: neighborsPtr, count: n))
        neighborsPtr.deinitialize(count: n)
        neighborsPtr.deallocate()
        return neighbors
    }

    private nonisolated static func motionSpeed(
        from previous: MotionSample,
        to current: MotionSample,
        metric: MotionMetric,
        radiusMm: Double
    ) -> Double {
        let dx = current.dS - previous.dS
        let dy = current.dL - previous.dL
        let dz = current.dP - previous.dP
        var squared = dx * dx + dy * dy + dz * dz

        if metric == .allParameters {
            let degToMM = Double.pi / 180.0 * max(radiusMm, 0)
            let dr = (current.roll - previous.roll) * degToMM
            let dp = (current.pitch - previous.pitch) * degToMM
            let dw = (current.yaw - previous.yaw) * degToMM
            squared += dr * dr + dp * dp + dw * dw
        }

        return squared.squareRoot()
    }

    /// Returns indices of the k elements with the smallest values in `dist`,
    /// preserving only finite entries (prefers finite over infinite).
    /// Uses a linear-time partial selection rather than a full sort.
    private nonisolated static func kSmallestIndices(_ dist: [Double], k: Int) -> [Int] {
        let n = dist.count
        guard k > 0, n > 0 else { return [] }
        // Separate finite from infinite up-front.
        var finite  = [(idx: Int, val: Double)]()
        var infinite = [(idx: Int, val: Double)]()
        finite.reserveCapacity(n)
        for i in 0..<n {
            if dist[i].isFinite { finite.append((i, dist[i])) }
            else { infinite.append((i, dist[i])) }
        }
        let pool = finite.isEmpty ? infinite : finite
        guard !pool.isEmpty else { return [] }
        if pool.count <= k { return pool.map(\.idx) }
        // Partial sort: nth_element equivalent via a simple selection on the k-th pivot.
        // For small k (typically 4) this is effectively O(n).
        var indices = pool.map(\.idx)
        var vals    = pool.map(\.val)
        partialSort(&indices, vals: &vals, k: k)
        return Array(indices.prefix(k))
    }

    /// In-place partial sort: rearranges `indices` so the first `k` elements have
    /// the k smallest corresponding `vals`. Uses introselect (quickselect fallback).
    private nonisolated static func partialSort(_ indices: inout [Int], vals: inout [Double], k: Int) {
        var lo = 0, hi = indices.count - 1
        while lo < hi {
            // Median-of-three requires at least 3 elements; fall back to insertion sort for small ranges.
            if hi - lo < 3 {
                if vals[lo] > vals[hi] { indices.swapAt(lo, hi); vals.swapAt(lo, hi) }
                if hi - lo == 2 {
                    let m = lo + 1
                    if vals[lo] > vals[m] { indices.swapAt(lo, m); vals.swapAt(lo, m) }
                    if vals[m]  > vals[hi] { indices.swapAt(m, hi); vals.swapAt(m, hi) }
                }
                break
            }
            let mid = (lo + hi) / 2
            if vals[lo] > vals[mid] { indices.swapAt(lo, mid); vals.swapAt(lo, mid) }
            if vals[lo] > vals[hi]  { indices.swapAt(lo, hi);  vals.swapAt(lo, hi)  }
            if vals[mid] > vals[hi] { indices.swapAt(mid, hi); vals.swapAt(mid, hi) }
            let pivot = vals[mid]
            indices.swapAt(mid, hi - 1); vals.swapAt(mid, hi - 1)
            var i = lo, j = hi - 1
            while true {
                i += 1; while vals[i] < pivot { i += 1 }
                j -= 1; while vals[j] > pivot { j -= 1 }
                if i >= j { break }
                indices.swapAt(i, j); vals.swapAt(i, j)
            }
            indices.swapAt(i, hi - 1); vals.swapAt(i, hi - 1)
            if i <= k { lo = i + 1 } else { hi = i - 1 }
        }
    }

    private nonisolated static func bergenRSquareCandidatePools(
        numTrig: Int,
        sliceTrigger: Bool,
        slices: Int,
        moosmannNeighbors: [[Int]]?
    ) -> [[Int]]? {
        if let moosmannNeighbors {
            var pools = [[Int]](repeating: [], count: numTrig)
            let sliceCount = max(slices, 1)
            fillResults(&pools, iterations: numTrig) { s in
                let volume = sliceTrigger ? s / sliceCount : s
                let sliceIndex = sliceTrigger ? s % sliceCount : 0
                guard volume < moosmannNeighbors.count else { return [] }
                return moosmannNeighbors[volume].compactMap { vol in
                    let idx = sliceTrigger ? vol * sliceCount + sliceIndex : vol
                    return idx >= 0 && idx < numTrig ? idx : nil
                }
            }
            return pools
        }

        guard sliceTrigger else { return nil }
        let sliceCount = max(slices, 1)
        let groups = (0..<sliceCount).map { sliceIndex in
            stride(from: sliceIndex, to: numTrig, by: sliceCount).map { $0 }
        }
        return (0..<numTrig).map { s in
            groups[s % sliceCount]
        }
    }

    /// BERGEN-style best-r^2 artifact selection. Unlike FACET/FARM, this mirrors
    /// `m_best_rsquare_artifact.m`: squared correlation is the score and the
    /// current artifact is eligible, so a target can contribute to its own
    /// template unless the caller excludes it through `candidatePools` or
    /// `excludedEpochs`.
    nonisolated static func bergenRSquareEpochNeighbors(
        epochs: [[Double]?],
        select: Int,
        candidatePools: [[Int]]? = nil,
        excludedEpochs: Set<Int> = []
    ) -> [[Int]] {
        let n = epochs.count
        let selectionCount = max(1, select)
        let prepared = prepareEpochs(epochs)
        var result = [[Int]](repeating: [], count: n)

        fillResults(&result, iterations: n) { s in
            guard let es = prepared[s] else { return [] }
            let pool = candidatePools.flatMap { s < $0.count ? $0[s] : nil } ?? Array(0..<n)
            var candidates: [(index: Int, score: Double)] = []
            candidates.reserveCapacity(pool.count)

            for j in pool where j >= 0 && j < n && !excludedEpochs.contains(j) {
                guard let ej = prepared[j], ej.values.count == es.values.count else { continue }
                let r = preparedPearson(es, ej)
                candidates.append((j, r * r))
            }

            candidates.sort {
                if $0.score == $1.score { return $0.index < $1.index }
                return $0.score > $1.score
            }
            return candidates.prefix(selectionCount).map(\.index)
        }

        return result
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
        let prepared = prepareEpochs(epochs)
        var result = [[Int]](repeating: [], count: n)

        fillResults(&result, iterations: n) { s in
            guard let es = prepared[s] else { return [] }
            let a = max(0, s - searchHalf)
            let b = min(n - 1, s + searchHalf)
            var candidates: [(index: Int, corr: Double)] = []
            for j in a...b where j != s {
                guard let ej = prepared[j], ej.values.count == es.values.count else { continue }
                let c = abs(preparedPearson(es, ej))
                if c >= threshold { candidates.append((j, c)) }
            }
            candidates.sort {
                if $0.corr == $1.corr { return $0.index < $1.index }
                return $0.corr > $1.corr
            }
            return candidates.prefix(max(1, select)).map { $0.index }
        }
        return result
    }

    private nonisolated static func prepareEpochs(_ epochs: [[Double]?]) -> [PreparedEpoch?] {
        epochs.map { values in
            guard let values, values.count > 1 else { return nil }
            let length = vDSP_Length(values.count)
            var mean = 0.0
            var rawSquares = 0.0
            vDSP_meanvD(values, 1, &mean, length)
            vDSP_dotprD(values, 1, values, 1, &rawSquares, length)
            let centeredSquares = max(0, rawSquares - Double(values.count) * mean * mean)
            return PreparedEpoch(values: values, mean: mean, sumSquaresCentered: centeredSquares)
        }
    }

    private nonisolated static func preparedPearson(_ a: PreparedEpoch, _ b: PreparedEpoch) -> Double {
        precondition(a.values.count == b.values.count)
        guard a.values.count > 1 else { return 0 }
        let denominator = (a.sumSquaresCentered * b.sumSquaresCentered).squareRoot()
        guard denominator > 0 else { return 0 }
        var rawDot = 0.0
        vDSP_dotprD(a.values, 1, b.values, 1, &rawDot, vDSP_Length(a.values.count))
        let covariance = rawDot - Double(a.values.count) * a.mean * b.mean
        return covariance / denominator
    }

    private nonisolated static func fillResults<T: Sendable>(
        _ result: inout [T],
        iterations count: Int,
        body: @Sendable (Int) -> T
    ) {
        guard count > 0 else { return }
        guard count >= donorSelectionParallelThreshold, evaMaxWorkers > 1 else {
            for i in 0..<count { result[i] = body(i) }
            return
        }

        nonisolated(unsafe) let resultPtr = UnsafeMutablePointer<T>.allocate(capacity: count)
        resultPtr.initialize(from: &result, count: count)
        evaConcurrentPerform(iterations: count) { i in
            resultPtr[i] = body(i)
        }
        result = Array(UnsafeBufferPointer(start: resultPtr, count: count))
        resultPtr.deinitialize(count: count)
        resultPtr.deallocate()
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
    /// sub-sample fractional shift). Alignment is computed on one channel and both
    /// integer markers and fractional offsets are shared across channels.
    private nonisolated struct Aligner {
        let markersUp: [Int]
        let prePeak: Int
        let postPeak: Int
        let artLength: Int
        let searchWindow: Int
        let subSample: Bool

        func align(dataUp: [Double]) -> AlignmentResult {
            let upLength = dataUp.count
            var aligned = markersUp
            // Reference template = first valid epoch.
            guard let refStart = markersUp.first, refStart - prePeak >= 0,
                  refStart + postPeak < upLength else {
                return AlignmentResult(markers: aligned, fractionalShifts: [Double](repeating: 0, count: markersUp.count))
            }
            let reference = Array(dataUp[(refStart - prePeak)...(refStart + postPeak)])

            for s in markersUp.indices {
                let shift = bestIntegerShift(
                    dataUp: dataUp,
                    template: reference,
                    center: markersUp[s],
                    prePeak: prePeak,
                    postPeak: postPeak,
                    searchWindow: searchWindow
                )
                aligned[s] = markersUp[s] + shift
            }

            let fractionalShifts = subSample
                ? fractionalAlignments(dataUp: dataUp, markers: aligned)
                : [Double](repeating: 0, count: markersUp.count)
            return AlignmentResult(markers: aligned, fractionalShifts: fractionalShifts)
        }

        private func fractionalAlignments(dataUp: [Double], markers: [Int]) -> [Double] {
            var shifts = [Double](repeating: 0, count: markers.count)
            guard let refMarker = markers.first else { return shifts }

            let pad = 10
            let refStart = refMarker - prePeak - pad
            let refEnd = refMarker + postPeak + pad
            guard refStart >= 0, refEnd < dataUp.count else { return shifts }
            let reference = Array(dataUp[refStart...refEnd])

            for s in markers.indices.dropFirst() {
                let start = markers[s] - prePeak - pad
                let end = markers[s] + postPeak + pad
                guard start >= 0, end < dataUp.count else { continue }
                let segment = Array(dataUp[start...end])
                guard segment.count == reference.count else { continue }
                shifts[s] = bestFractionalShift(segment: segment, reference: reference)
            }
            return shifts
        }

        private func bestFractionalShift(segment: [Double], reference: [Double]) -> Double {
            var shiftL = -1.0
            var shiftM = 0.0
            var shiftR = 1.0
            var corrL = compare(reference, DSP.fractionalShift(segment, by: shiftL))
            var corrM = compare(reference, segment)
            var corrR = compare(reference, DSP.fractionalShift(segment, by: shiftR))

            for _ in 0..<15 {
                if corrL > corrR {
                    shiftR = shiftM
                    corrR = corrM
                } else {
                    shiftL = shiftM
                    corrL = corrM
                }
                shiftM = (shiftL + shiftR) / 2
                corrM = compare(reference, DSP.fractionalShift(segment, by: shiftM))
            }
            return shiftM
        }

        private func compare(_ reference: [Double], _ shifted: [Double]) -> Double {
            guard reference.count == shifted.count else { return -.infinity }
            var sse = 0.0
            for i in reference.indices {
                let d = reference[i] - shifted[i]
                sse += d * d
            }
            return -sse
        }
    }
}
