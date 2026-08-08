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

    enum ComputeBackend: String, Sendable {
        case cpu
        case metal
    }

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
        /// Dense FASTR kernels run on the CPU by default. Metal is optional and
        /// falls back to CPU if no compatible device or shader pipeline exists.
        var computeBackend: ComputeBackend = .cpu
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
        /// OBS PCA is recomputed independently every `obsChunkSeconds` of the
        /// recording rather than once globally, matching Niazy et al. (2005)'s
        /// reference FASTR implementation: a single global basis assumes the
        /// artifact shape is stationary for the whole recording, which both
        /// loses accuracy over a long scan (motion, drift) and makes the PCA
        /// Gram-matrix eigendecomposition (O(epoch count³)) the dominant cost
        /// of the whole correction for slice-triggered data with many epochs.
        var obsChunkSeconds = 60.0
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

    /// Safety ceiling on how many epochs feed one chunk's OBS PCA Gram matrix.
    /// `Config.obsChunkSeconds` chunking (matching FASTR's reference
    /// implementation) already keeps this bounded in practice — a 1-minute
    /// chunk of even densely slice-triggered data is normally in the
    /// hundreds, not thousands — but this remains as a hard backstop against
    /// a pathologically large `obsChunkSeconds` value turning the O(p³)
    /// eigendecomposition back into the dominant cost of the correction.
    nonisolated private static let maxPCAEpochCount = 1500

    /// Test-only override for the Metal batch size. `metalBatchSize` is
    /// otherwise bound by real memory (RAM headroom and the GPU's buffer size
    /// limit), which small synthetic test signals never approach — this lets
    /// tests force multiple/small batches to exercise that code path
    /// deterministically. `nil` (the default) uses the real calculation.
    nonisolated(unsafe) static var debugBatchSizeOverride: Int?

    nonisolated static var isMetalAvailable: Bool { FastrMetalBackend.isAvailable }

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

    /// CPU-computed inputs to the OBS fit: the high-passed residual and the
    /// (already scaled) PCA design columns for every chunk of the recording
    /// (see `Config.obsChunkSeconds`) — `nil` for a chunk with too few usable
    /// epochs. Split out from `optimalBasisSet` so the FASTR Metal batch path
    /// can gather these for every channel in a batch and fit them with one
    /// GPU dispatch per chunk instead of one Metal round trip per channel.
    private struct OBSPreparation: Sendable {
        let ipca: [Double]
        let chunkColumns: [[[Double]]?]
    }

    private struct PreparedChannel: Sendable {
        let raw: [Double]
        let original: [Double]
        let templateNoise: [Double]
        var residualNoise: [Double]
        let excluded: Bool
        var obsPreparation: OBSPreparation?
        /// `idata - iNoise`, staged for the Metal batch path so the OBS
        /// high-pass filter can be run once for the whole channel batch
        /// instead of once per channel. Set only when OBS is deferred.
        var obsResidual: [Double]?
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
        let metal = config.computeBackend == .metal ? FastrMetalBackend.shared : nil

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
        let channel0Up = metal?.interpolate(channels[0], factor: L, subtractMean: false)
            ?? DSP.interp(channels[0].map(Double.init), factor: L)
        let alignment = aligner.align(dataUp: channel0Up)
        let alignedMarkers = alignment.markers
        let templateAlignedMarkers: [Int]
        if config.alignToAverageArtifact {
            let channel0ZeroMeanUp = metal?.interpolate(channels[0], factor: L, subtractMean: true)
                ?? zeroMeanUpsampled(channels[0].map(Double.init), factor: L)
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

        let epochChunks = obsChunkEpochIndices(
            alignedMarkers: alignedMarkers,
            chunkSeconds: config.obsChunkSeconds,
            samplingRate: samplingRate,
            L: L
        )

        if let metal {
            return correctMetalBatches(
                channels: channels,
                alignedMarkers: alignedMarkers,
                templateAlignedMarkers: templateAlignedMarkers,
                fractionalShifts: alignment.fractionalShifts,
                L: L,
                prePeak: prePeak,
                postPeak: postPeak,
                artLength: artLength,
                templateSelection: templateSelection,
                sliceTrigger: sliceTrigger,
                slices: slices,
                moosmannNeighbors: moosmannNeighbors,
                censoredVolumes: config.censoredVolumes,
                obsHPF: obsHPF,
                epochChunks: epochChunks,
                config: config,
                samplingRate: samplingRate,
                metal: metal,
                progress: progress
            )
        }

        // Use an explicitly managed buffer so concurrent writes to distinct slots are safe.
        nonisolated(unsafe) let resultPtr = UnsafeMutablePointer<[Float]>.allocate(capacity: channels.count)
        resultPtr.initialize(from: &result, count: channels.count)
        evaConcurrentPerform(iterations: channels.count) { c in
            guard !Task.isCancelled else { return }
            let raw = channels[c].map(Double.init)
            let corrected = correctChannel(
                raw: raw,
                rawFloat: channels[c],
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
                obsHPF: obsHPF,
                epochChunks: epochChunks,
                config: config, samplingRate: samplingRate,
                metal: nil
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

    private nonisolated static func correctMetalBatches(
        channels: [[Float]],
        alignedMarkers: [Int],
        templateAlignedMarkers: [Int],
        fractionalShifts: [Double],
        L: Int,
        prePeak: Int,
        postPeak: Int,
        artLength: Int,
        templateSelection: TemplateSelection,
        sliceTrigger: Bool,
        slices: Int,
        moosmannNeighbors: [[Int]]?,
        censoredVolumes: Set<Int>,
        obsHPF: [Double],
        epochChunks: [[Int]],
        config: Config,
        samplingRate: Double,
        metal: FastrMetalBackend,
        progress: (@Sendable (Double) -> Void)?
    ) -> [[Float]] {
        let sampleCount = channels.first?.count ?? 0
        let batchSize = metalBatchSize(
            channelCount: channels.count,
            sampleCount: sampleCount,
            factor: L,
            maxBufferLength: metal.maxBufferLength
        )
        let sharedDonorRows = sharedTemplateDonorRows(
            markers: alignedMarkers,
            prePeak: prePeak,
            postPeak: postPeak,
            templateSelection: templateSelection,
            sliceTrigger: sliceTrigger,
            slices: slices,
            moosmannNeighbors: moosmannNeighbors,
            censoredEpochs: censoredEpochIndices(
                numTrig: alignedMarkers.count,
                sliceTrigger: sliceTrigger,
                slices: slices,
                censoredVolumes: censoredVolumes
            ),
            config: config,
            upsampledCount: sampleCount * L
        )
        var result = channels
        nonisolated(unsafe) let resultPtr = UnsafeMutablePointer<[Float]>.allocate(capacity: channels.count)
        resultPtr.initialize(from: &result, count: channels.count)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0

        // One batch's Metal calls block the thread that issued them
        // (`waitUntilCompleted`), and the CPU-only stages between them
        // (PCA/design-column setup, ANC) only use the cores needed for that
        // one batch's channel count. Run up to `pipelineDepth` batches on
        // separate threads at once so one batch's GPU wait overlaps with
        // another batch's CPU-side work — otherwise the whole pipeline
        // serializes on a single thread alternating between blocked-on-GPU
        // and CPU-bound, and neither the GPU nor the CPU ever reads busy.
        let batchStarts = Array(stride(from: 0, to: channels.count, by: batchSize))
        let pipelineDepth = min(2, max(batchStarts.count, 1))

        func processBatch(_ batchStart: Int) {
            guard !Task.isCancelled else { return }
            let batchEnd = min(batchStart + batchSize, channels.count)
            let batchChannels = Array(channels[batchStart..<batchEnd])
            let centeredUpsampled = metal.interpolateChannels(
                batchChannels,
                factor: L,
                subtractMean: true
            )

            var originalUpsampled: [[Double]]?
            var shiftedCentered: [[Double]]?
            var shiftedOriginal: [[Double]]?
            var batchTemplateNoise: [[Double]]?
            if let centeredUpsampled,
               let sharedDonorRows {
                var centered = centeredUpsampled
                fillResults(&centered, iterations: centered.count) { offset in
                    applySubSampleShifts(
                        to: centeredUpsampled[offset],
                        markers: alignedMarkers,
                        prePeak: prePeak,
                        postPeak: postPeak,
                        shifts: fractionalShifts
                    )
                }
                batchTemplateNoise = metal.buildTemplateNoiseChannels(
                    data: centered,
                    markers: alignedMarkers,
                    targetStarts: templateAlignedMarkers.map { $0 - prePeak },
                    donorRows: sharedDonorRows,
                    prePeak: prePeak,
                    artifactLength: artLength,
                    fixedAlpha: (batchStart..<batchEnd).map { config.excludedChannels.contains($0) }
                )
                if batchTemplateNoise != nil {
                    shiftedCentered = centered
                    originalUpsampled = metal.interpolateChannels(
                        batchChannels,
                        factor: L,
                        subtractMean: false
                    )
                    if let originalUpsampled {
                        var original = originalUpsampled
                        fillResults(&original, iterations: original.count) { offset in
                            applySubSampleShifts(
                                to: originalUpsampled[offset],
                                markers: alignedMarkers,
                                prePeak: prePeak,
                                postPeak: postPeak,
                                shifts: fractionalShifts
                            )
                        }
                        shiftedOriginal = original
                    } else {
                        batchTemplateNoise = nil
                        shiftedCentered = nil
                    }
                }
            }
            if originalUpsampled == nil {
                originalUpsampled = metal.interpolateChannels(
                    batchChannels,
                    factor: L,
                    subtractMean: false
                )
            }
            let preparedCentered = shiftedCentered ?? centeredUpsampled
            let preparedOriginal = shiftedOriginal ?? originalUpsampled
            let precomputedNoise = batchTemplateNoise
            let hasPrecomputedNoise = precomputedNoise != nil

            let count = batchChannels.count
            nonisolated(unsafe) let preparedPtr = UnsafeMutablePointer<PreparedChannel?>.allocate(capacity: count)
            preparedPtr.initialize(repeating: nil, count: count)
            evaConcurrentPerform(iterations: count) { offset in
                guard !Task.isCancelled else { return }
                let channelIndex = batchStart + offset
                let rawFloat = batchChannels[offset]
                preparedPtr[offset] = prepareChannel(
                    raw: rawFloat.map(Double.init),
                    rawFloat: rawFloat,
                    centeredUpsampled: preparedCentered?[offset],
                    originalUpsampled: preparedOriginal?[offset],
                    precomputedTemplateNoise: precomputedNoise?[offset],
                    inputsAreShifted: hasPrecomputedNoise,
                    channelIndex: channelIndex,
                    alignedMarkers: alignedMarkers,
                    templateAlignedMarkers: templateAlignedMarkers,
                    fractionalShifts: fractionalShifts,
                    L: L,
                    prePeak: prePeak,
                    postPeak: postPeak,
                    artLength: artLength,
                    templateSelection: templateSelection,
                    sliceTrigger: sliceTrigger,
                    slices: slices,
                    moosmannNeighbors: moosmannNeighbors,
                    censoredVolumes: censoredVolumes,
                    obsHPF: obsHPF,
                    epochChunks: epochChunks,
                    config: config,
                    metal: metal,
                    deferOBSToMetalBatch: true
                )
            }
            let prepared = (0..<count).map { preparedPtr[$0] }
            preparedPtr.deinitialize(count: count)
            preparedPtr.deallocate()
            guard prepared.allSatisfy({ $0 != nil }) else { return }
            var ready = prepared.compactMap { $0 }

            // High-pass every channel's OBS residual with one GPU dispatch
            // for the whole batch (matches DSP.filtfiltFIR per channel)
            // instead of one CPU convolution pass per channel; the cheap
            // PCA/design-column setup that follows still runs concurrently
            // per channel on the CPU.
            let hpfIndices = ready.indices.filter { ready[$0].obsResidual != nil }
            if !hpfIndices.isEmpty {
                let batchFiltered = metal.filtfiltChannels(
                    taps: obsHPF,
                    signals: hpfIndices.map { ready[$0].obsResidual! }
                )
                let numTrig = alignedMarkers.count
                nonisolated(unsafe) let hpfReadyPtr = UnsafeMutablePointer<PreparedChannel>.allocate(capacity: ready.count)
                hpfReadyPtr.initialize(from: &ready, count: ready.count)
                evaConcurrentPerform(iterations: hpfIndices.count) { i in
                    let idx = hpfIndices[i]
                    let ipca = batchFiltered?[i] ?? DSP.filtfiltFIR(obsHPF, hpfReadyPtr[idx].obsResidual!)
                    hpfReadyPtr[idx].obsPreparation = prepareOBSFromFilteredResidual(
                        ipca: ipca, alignedMarkers: alignedMarkers,
                        prePeak: prePeak, postPeak: postPeak, artLength: artLength,
                        sliceTrigger: sliceTrigger, epochChunks: epochChunks,
                        censoredEpochs: censoredEpochIndices(
                            numTrig: numTrig, sliceTrigger: sliceTrigger,
                            slices: slices, censoredVolumes: censoredVolumes
                        ),
                        mode: config.obs, randomizeEpochSelection: config.randomizeOBSEpochSelection
                    )
                }
                ready = Array(UnsafeBufferPointer(start: hpfReadyPtr, count: ready.count))
                hpfReadyPtr.deinitialize(count: ready.count)
                hpfReadyPtr.deallocate()
            }

            // Fit the OBS design for every channel in this batch, per chunk,
            // with one GPU dispatch per chunk instead of one Metal round trip
            // per channel issued from concurrent CPU threads (which
            // serialized on the command queue and let per-call overhead
            // dominate the tiny actual work).
            let obsIndices = ready.indices.filter { ready[$0].obsPreparation != nil }
            if !obsIndices.isEmpty {
                nonisolated(unsafe) let readyPtr = UnsafeMutablePointer<PreparedChannel>.allocate(capacity: ready.count)
                readyPtr.initialize(from: &ready, count: ready.count)
                for (chunkIndex, chunkEpochs) in epochChunks.enumerated() {
                    let chunkIndices = obsIndices.filter {
                        (readyPtr[$0].obsPreparation?.chunkColumns[safe: chunkIndex] ?? nil) != nil
                    }
                    guard !chunkIndices.isEmpty else { continue }
                    let epochStarts = chunkEpochs.map { alignedMarkers[$0] - prePeak }
                    let batchFit = metal.fitOptimalBasisChannels(
                        data: chunkIndices.map { readyPtr[$0].obsPreparation!.ipca },
                        epochStarts: epochStarts,
                        columnsPerChannel: chunkIndices.map { readyPtr[$0].obsPreparation!.chunkColumns[chunkIndex]! }
                    )
                    if let batchFit {
                        for (i, idx) in chunkIndices.enumerated() {
                            var accumulated = readyPtr[idx].residualNoise
                            vDSP_vaddD(accumulated, 1, batchFit[i], 1, &accumulated, 1, vDSP_Length(accumulated.count))
                            readyPtr[idx].residualNoise = accumulated
                        }
                    } else {
                        evaConcurrentPerform(iterations: chunkIndices.count) { i in
                            let idx = chunkIndices[i]
                            let prep = readyPtr[idx].obsPreparation!
                            let columns = prep.chunkColumns[chunkIndex]!
                            let upLength = readyPtr[idx].original.count
                            for s in chunkEpochs {
                                let start = alignedMarkers[s] - prePeak
                                let end = alignedMarkers[s] + postPeak
                                guard start >= 0, end < upLength else { continue }
                                let target = Array(prep.ipca[start...end])
                                let fit = DSP.leastSquaresFit(target: target, design: columns)
                                for k in 0..<artLength { readyPtr[idx].residualNoise[start + k] = fit[k] }
                            }
                        }
                    }
                }
                ready = Array(UnsafeBufferPointer(start: readyPtr, count: ready.count))
                readyPtr.deinitialize(count: ready.count)
                readyPtr.deallocate()
            }
            let finalReady = ready

            let gpu = metal.correctAndDecimateChannels(
                original: finalReady.map(\.original),
                templateNoise: finalReady.map(\.templateNoise),
                residualNoise: finalReady.map(\.residualNoise),
                factor: L,
                targetCount: sampleCount
            )

            nonisolated(unsafe) let decimatedPtr = UnsafeMutablePointer<(clean: [Double], noise: [Double])>.allocate(capacity: count)
            decimatedPtr.initialize(repeating: (clean: [], noise: []), count: count)
            evaConcurrentPerform(iterations: count) { offset in
                let gpuResult: (clean: [Double], noise: [Double])? = {
                    guard let gpu else { return nil }
                    return (gpu.clean[offset], gpu.noise[offset])
                }()
                decimatedPtr[offset] = decimateChannel(finalReady[offset], gpuResult: gpuResult, L: L, metal: metal)
            }
            var decimated = (0..<count).map { decimatedPtr[$0] }
            decimatedPtr.deinitialize(count: count)
            decimatedPtr.deallocate()

            // Batch the optional post low-pass across the whole channel batch
            // with one GPU dispatch (matches DSP.filtfiltFIR per channel)
            // instead of one CPU convolution pass per channel, per signal.
            if let lpf = config.lowPassHz, lpf > 0 {
                let taps = lowPassWeights(lpf: lpf, fs: samplingRate)
                let combined = decimated.map(\.clean) + decimated.map(\.noise)
                let batchFiltered = metal.filtfiltChannels(taps: taps, signals: combined)
                nonisolated(unsafe) let decimatedPtr2 = UnsafeMutablePointer<(clean: [Double], noise: [Double])>.allocate(capacity: count)
                decimatedPtr2.initialize(from: &decimated, count: count)
                evaConcurrentPerform(iterations: count) { offset in
                    if let batchFiltered {
                        decimatedPtr2[offset] = (clean: batchFiltered[offset], noise: batchFiltered[count + offset])
                    } else {
                        decimatedPtr2[offset] = (
                            clean: DSP.filtfiltFIR(taps, decimatedPtr2[offset].clean),
                            noise: DSP.filtfiltFIR(taps, decimatedPtr2[offset].noise)
                        )
                    }
                }
                decimated = Array(UnsafeBufferPointer(start: decimatedPtr2, count: count))
                decimatedPtr2.deinitialize(count: count)
                decimatedPtr2.deallocate()
            }
            let finalDecimated = decimated

            nonisolated(unsafe) let outputPtr = UnsafeMutablePointer<[Float]>.allocate(capacity: count)
            outputPtr.initialize(repeating: [], count: count)
            evaConcurrentPerform(iterations: count) { offset in
                outputPtr[offset] = finishChannel(
                    finalReady[offset],
                    clean: finalDecimated[offset].clean,
                    noise: finalDecimated[offset].noise,
                    alignedMarkers: alignedMarkers,
                    L: L,
                    artLength: artLength,
                    sliceTrigger: sliceTrigger,
                    config: config,
                    samplingRate: samplingRate,
                    applyLowPass: false
                ).map(Float.init)
            }
            for offset in 0..<count {
                resultPtr[batchStart + offset] = outputPtr[offset]
            }
            outputPtr.deinitialize(count: count)
            outputPtr.deallocate()

            progressLock.lock()
            completed += count
            let fraction = Double(completed) / Double(channels.count)
            progressLock.unlock()
            progress?(fraction)
        }

        if pipelineDepth > 1 {
            DispatchQueue.concurrentPerform(iterations: pipelineDepth) { worker in
                var index = worker
                while index < batchStarts.count {
                    processBatch(batchStarts[index])
                    index += pipelineDepth
                }
            }
        } else {
            for start in batchStarts { processBatch(start) }
        }

        let finalResult = Array(UnsafeBufferPointer(start: resultPtr, count: channels.count))
        resultPtr.deinitialize(count: channels.count)
        resultPtr.deallocate()
        return finalResult
    }

    private nonisolated static func metalBatchSize(
        channelCount: Int,
        sampleCount: Int,
        factor: Int,
        maxBufferLength: Int
    ) -> Int {
        if let override = debugBatchSizeOverride {
            return max(1, min(channelCount, override))
        }
        let upsampledCount = max(sampleCount * max(factor, 1), 1)
        // Per-channel staging budget: upsampled Double/Float working buffers
        // that exist simultaneously for every channel in a batch
        // (interpolation, HPF/low-pass filtfilt scratch, templates, OBS work).
        let bytesPerSample = 96
        let bytesPerChannel = max(upsampledCount * bytesPerSample, 1)

        // Batch size used to be capped at CPU core count (plus a flat
        // 16-channel ceiling) — a leftover from treating GPU batching like
        // CPU parallelism, even though the GPU dispatch doesn't care how many
        // CPU workers exist. That cap forced tiny batches for anything but
        // short recordings, which starves the GPU: most wall-clock time ends
        // up in the per-channel CPU stages between many small, frequent GPU
        // round trips, so Activity Monitor shows the GPU sitting near-idle.
        // Bound purely by real memory: a fraction of physical RAM, and the
        // GPU's own single-buffer size limit (the largest per-batch buffer is
        // one Float array of channelCount x upsampledCount).
        let physicalMemory = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        let ramBudget = min(4 * 1_024 * 1_024 * 1_024, physicalMemory / 4)
        let ramBound = max(1, ramBudget / bytesPerChannel)
        let bufferBound = max(1, maxBufferLength / (upsampledCount * 4))
        let memoryBound = min(ramBound, bufferBound)

        return max(1, min(channelCount, memoryBound))
    }

    // MARK: - Per-channel correction

    private nonisolated static func correctChannel(
        raw: [Double],
        rawFloat: [Float],
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
        obsHPF: [Double],
        epochChunks: [[Int]],
        config: Config, samplingRate: Double,
        metal: FastrMetalBackend?
    ) -> [Double] {
        let prepared = prepareChannel(
            raw: raw,
            rawFloat: rawFloat,
            centeredUpsampled: nil,
            originalUpsampled: nil,
            precomputedTemplateNoise: nil,
            inputsAreShifted: false,
            channelIndex: c,
            alignedMarkers: alignedMarkers,
            templateAlignedMarkers: templateAlignedMarkers,
            fractionalShifts: fractionalShifts,
            L: L,
            prePeak: prePeak,
            postPeak: postPeak,
            artLength: artLength,
            templateSelection: templateSelection,
            sliceTrigger: sliceTrigger,
            slices: slices,
            moosmannNeighbors: moosmannNeighbors,
            censoredVolumes: censoredVolumes,
            obsHPF: obsHPF,
            epochChunks: epochChunks,
            config: config,
            metal: metal
        )
        let decimated = decimateChannel(prepared, gpuResult: nil, L: L, metal: metal)
        return finishChannel(
            prepared,
            clean: decimated.clean,
            noise: decimated.noise,
            alignedMarkers: alignedMarkers,
            L: L,
            artLength: artLength,
            sliceTrigger: sliceTrigger,
            config: config,
            samplingRate: samplingRate,
            applyLowPass: true
        )
    }

    private nonisolated static func prepareChannel(
        raw: [Double],
        rawFloat: [Float],
        centeredUpsampled: [Double]?,
        originalUpsampled: [Double]?,
        precomputedTemplateNoise: [Double]?,
        inputsAreShifted: Bool,
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
        obsHPF: [Double],
        epochChunks: [[Int]],
        config: Config,
        metal: FastrMetalBackend?,
        deferOBSToMetalBatch: Bool = false
    ) -> PreparedChannel {
        var idata = centeredUpsampled
            ?? metal?.interpolate(rawFloat, factor: L, subtractMean: true)
            ?? zeroMeanUpsampled(raw, factor: L)
        var iorig = originalUpsampled
            ?? metal?.interpolate(rawFloat, factor: L, subtractMean: false)
            ?? DSP.interp(raw, factor: L)
        if !inputsAreShifted {
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
        }
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

        var iNoise: [Double]
        if let precomputedTemplateNoise, precomputedTemplateNoise.count == upLength {
            iNoise = precomputedTemplateNoise
        } else {
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
            let targetStarts = templateAlignedMarkers.map { $0 - prePeak }
            let metalNoise = metal?.buildTemplateNoise(
                data: idata,
                templates: templates,
                targetStarts: targetStarts,
                fixedAlpha: excluded
            )
            iNoise = metalNoise ?? [Double](repeating: 0, count: upLength)

            func alignedTarget(_ s: Int) -> ArraySlice<Double>? {
                let start = templateAlignedMarkers[s] - prePeak
                let end = templateAlignedMarkers[s] + postPeak
                guard start >= 0, end < upLength else { return nil }
                return idata[start...end]
            }

            if metalNoise == nil || iNoise.count != upLength {
                iNoise = [Double](repeating: 0, count: upLength)
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
                    let start = targetStarts[s]
                    guard start >= 0, start + avg.count <= iNoise.count else { continue }
                    var scaledAlpha = alpha
                    avg.withUnsafeBufferPointer { avgBuf in
                        iNoise.withUnsafeMutableBufferPointer { noiseBuf in
                            guard let avgBase = avgBuf.baseAddress, let noiseBase = noiseBuf.baseAddress else { return }
                            vDSP_vsmulD(avgBase, 1, &scaledAlpha, noiseBase + start, 1, vDSP_Length(avg.count))
                        }
                    }
                }
            }
        }

        // OBS residual removal.
        var fittedRes = [Double](repeating: 0, count: upLength)
        var obsResidual: [Double]?
        if !excluded, config.obs != .off {
            if deferOBSToMetalBatch {
                // Only stage the (idata - iNoise) residual here (this runs
                // inside a concurrent per-channel loop, which is fine); the
                // high-pass filter and OBS fit are batched once for the whole
                // channel batch by the caller.
                obsResidual = zip(idata, iNoise).map(-)
            } else {
                fittedRes = optimalBasisSet(
                    idata: idata, iNoise: iNoise, alignedMarkers: alignedMarkers,
                    prePeak: prePeak, postPeak: postPeak, artLength: artLength,
                    sliceTrigger: sliceTrigger, epochChunks: epochChunks,
                    censoredEpochs: censoredEpochs,
                    obsHPF: obsHPF, mode: config.obs,
                    randomizeEpochSelection: config.randomizeOBSEpochSelection,
                    metal: metal
                )
            }
        }

        return PreparedChannel(
            raw: raw,
            original: iorig,
            templateNoise: iNoise,
            residualNoise: fittedRes,
            excluded: excluded,
            obsPreparation: nil,
            obsResidual: obsResidual
        )
    }

    /// Correct-and-decimate plus the trailing length guard, split out of
    /// `finishChannel` so the Metal batch path can apply the optional
    /// low-pass filter across a whole channel batch in one GPU dispatch
    /// before doing the (necessarily per-channel, sequential) ANC step.
    private nonisolated static func decimateChannel(
        _ prepared: PreparedChannel,
        gpuResult: (clean: [Double], noise: [Double])?,
        L: Int,
        metal: FastrMetalBackend?
    ) -> (clean: [Double], noise: [Double]) {
        let n = prepared.raw.count
        let upLength = prepared.original.count
        var cleanEEG: [Double]
        var noise: [Double]
        if let gpuResult = gpuResult ?? metal?.correctAndDecimate(
            original: prepared.original,
            templateNoise: prepared.templateNoise,
            residualNoise: prepared.residualNoise,
            factor: L,
            targetCount: n
        ) {
            cleanEEG = gpuResult.clean
            noise = gpuResult.noise
        } else {
            var totalNoise = [Double](repeating: 0, count: upLength)
            let upVectorLength = vDSP_Length(upLength)
            vDSP_vaddD(prepared.templateNoise, 1, prepared.residualNoise, 1,
                       &totalNoise, 1, upVectorLength)
            var corrected = [Double](repeating: 0, count: upLength)
            // vDSP_vsubD computes C = B - A, i.e. original - noise.
            vDSP_vsubD(totalNoise, 1, prepared.original, 1, &corrected, 1, upVectorLength)
            cleanEEG = L > 1 ? DSP.decimate(corrected, factor: L) : corrected
            noise = L > 1 ? DSP.decimate(totalNoise, factor: L) : totalNoise
        }
        // Guard length (decimate can be off by one).
        if cleanEEG.count > n { cleanEEG = Array(cleanEEG[0..<n]) }
        if cleanEEG.count < n { cleanEEG += Array(repeating: prepared.raw[cleanEEG.count..<n].first ?? 0, count: n - cleanEEG.count) }
        if noise.count > n { noise = Array(noise[0..<n]) }
        if noise.count < n { noise += Array(repeating: 0, count: n - noise.count) }
        return (cleanEEG, noise)
    }

    /// Optional low-pass (unless already applied by the caller in batch) and
    /// ANC, given the decimated clean/noise pair from `decimateChannel`.
    private nonisolated static func finishChannel(
        _ prepared: PreparedChannel,
        clean: [Double],
        noise: [Double],
        alignedMarkers: [Int],
        L: Int,
        artLength: Int,
        sliceTrigger: Bool,
        config: Config,
        samplingRate: Double,
        applyLowPass: Bool
    ) -> [Double] {
        var cleanEEG = clean
        var noise = noise

        // Optional low-pass.
        if applyLowPass, let lpf = config.lowPassHz, lpf > 0 {
            let taps = lowPassWeights(lpf: lpf, fs: samplingRate)
            cleanEEG = DSP.filtfiltFIR(taps, cleanEEG)
            noise = DSP.filtfiltFIR(taps, noise)
        }

        // Optional adaptive noise cancellation.
        if config.anc, !prepared.excluded {
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

    /// Returns channel-independent donor rows for the fused Metal template path.
    /// Correlation-ranked FARM and Bergen donors remain channel-specific.
    private nonisolated static func sharedTemplateDonorRows(
        markers: [Int],
        prePeak: Int,
        postPeak: Int,
        templateSelection: TemplateSelection,
        sliceTrigger: Bool,
        slices: Int,
        moosmannNeighbors: [[Int]]?,
        censoredEpochs: Set<Int>,
        config: Config,
        upsampledCount: Int
    ) -> [[Int]]? {
        guard config.templateScheme != .farm, !config.usesBergenRSquareDonors else { return nil }
        let numTrig = markers.count
        return (0..<numTrig).map { s in
            var indices: [Int] = []
            if let neighbors = moosmannNeighbors {
                let volume = sliceTrigger ? s / max(slices, 1) : s
                let sliceIndex = sliceTrigger ? s % max(slices, 1) : 0
                if volume < neighbors.count, !neighbors[volume].isEmpty {
                    indices = neighbors[volume].compactMap { volume in
                        let index = sliceTrigger ? volume * max(slices, 1) + sliceIndex : volume
                        return index >= 0 && index < numTrig ? index : nil
                    }
                }
            }
            if indices.isEmpty,
               let facetRows = templateSelection.facetTemporalDonors,
               s < facetRows.count {
                indices = facetRows[s]
            } else if indices.isEmpty, sliceTrigger {
                var start = s - templateSelection.windowBefore
                if start < 1 { start = (s % 2 == 0) ? 2 : 1 }
                var index = start
                while index <= s + templateSelection.windowAfter {
                    if index >= 0 && index < numTrig { indices.append(index) }
                    index += 2
                }
            } else if indices.isEmpty {
                let start = max(0, s - templateSelection.windowBefore)
                let end = min(numTrig - 1, s + templateSelection.windowAfter)
                if start <= end { indices = Array(start...end) }
            }

            if !censoredEpochs.isEmpty {
                let targetCount = indices.count
                let kept = indices.filter { !censoredEpochs.contains($0) }
                indices = topUpDonors(
                    kept,
                    center: s,
                    stride: sliceTrigger ? 2 : 1,
                    target: targetCount,
                    numTrig: numTrig,
                    censored: censoredEpochs
                )
            }

            guard let first = indices.first else { return [] }
            let firstStart = markers[first] - prePeak
            guard firstStart >= 0, firstStart + prePeak + postPeak < upsampledCount else { return [] }
            return indices.filter { index in
                let start = markers[index] - prePeak
                return start >= 0 && start + prePeak + postPeak < upsampledCount
            }
        }
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

        var templates = [[Double]?](repeating: nil, count: numTrig)
        fillResults(&templates, iterations: numTrig) { s in
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

        // Drop censored (e.g. high-motion) donors and top up from clean epochs.
        // A censored epoch must never re-enter a template, even when every donor
        // in the original neighborhood was censored.
        if !censoredEpochs.isEmpty {
            let kept = indices.filter { !censoredEpochs.contains($0) }
            indices = topUpDonors(kept, center: s, stride: sliceTrigger ? 2 : 1,
                                  target: indices.count, numTrig: numTrig,
                                  censored: censoredEpochs)
            guard !indices.isEmpty else { return nil }
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

    /// CPU-only OBS setup: high-pass the residual, build the PCA epoch subset,
    /// and derive the (scaled) design columns. Returns `nil` when OBS should
    /// contribute nothing (too few usable epochs, empty basis, zero PCs, or
    /// `mode == .off`), matching `optimalBasisSet`'s all-zero early-outs.
    private nonisolated static func prepareOBS(
        idata: [Double], iNoise: [Double], alignedMarkers: [Int],
        prePeak: Int, postPeak: Int, artLength: Int,
        sliceTrigger: Bool,
        epochChunks: [[Int]],
        censoredEpochs: Set<Int>,
        obsHPF: [Double], mode: OBSMode,
        randomizeEpochSelection: Bool
    ) -> OBSPreparation? {
        // High-pass the residual (data - template).
        let residual = zip(idata, iNoise).map(-)
        let ipca = DSP.filtfiltFIR(obsHPF, residual)
        return prepareOBSFromFilteredResidual(
            ipca: ipca, alignedMarkers: alignedMarkers,
            prePeak: prePeak, postPeak: postPeak, artLength: artLength,
            sliceTrigger: sliceTrigger, epochChunks: epochChunks,
            censoredEpochs: censoredEpochs,
            mode: mode, randomizeEpochSelection: randomizeEpochSelection
        )
    }

    /// The non-filtering half of `prepareOBS`: builds a PCA design (basis
    /// columns) independently for each chunk of the recording from an
    /// already high-passed residual (`ipca`). Split out so the Metal batch
    /// path can high-pass every channel's residual with one GPU dispatch and
    /// then run this (cheap, CPU) part concurrently per channel.
    ///
    /// Chunking matches Niazy et al. (2005)'s reference FASTR implementation
    /// ("each 1-min portion of the data is processed at a time... to provide
    /// a degree of adaptivity") rather than fitting one global OBS: a single
    /// basis assumes the artifact shape is stationary for the whole
    /// recording, which loses accuracy over a long scan and — for
    /// slice-triggered data with many epochs — makes the Gram-matrix
    /// eigendecomposition (O(epoch count³)) the dominant cost of the entire
    /// correction if left unbounded.
    private nonisolated static func prepareOBSFromFilteredResidual(
        ipca: [Double], alignedMarkers: [Int],
        prePeak: Int, postPeak: Int, artLength: Int,
        sliceTrigger: Bool,
        epochChunks: [[Int]],
        censoredEpochs: Set<Int>,
        mode: OBSMode,
        randomizeEpochSelection: Bool
    ) -> OBSPreparation? {
        let upLength = ipca.count

        func epochSlice(_ s: Int) -> [Double]? {
            let start = alignedMarkers[s] - prePeak
            let end = alignedMarkers[s] + postPeak
            guard start >= 0, end < upLength else { return nil }
            return Array(ipca[start...end])
        }

        var anyChunkValid = false
        let chunkColumns: [[[Double]]?] = epochChunks.map { chunkEpochs -> [[Double]]? in
            // FACET's subsample pattern (EVA's default is deterministic for
            // replay; the random option follows FACET's rand-driven 2/3 skip
            // pattern), applied within this chunk rather than globally.
            let localIndices = obsPCAEpochIndices(
                numTrig: chunkEpochs.count,
                sliceTrigger: sliceTrigger,
                randomized: randomizeEpochSelection
            )
            let epochIndices = capPCAEpochCount(localIndices.compactMap { chunkEpochs[safe: $0] })

            var pcaEpochs: [[Double]] = []
            for s in epochIndices {
                // Skip censored (e.g. high-motion) epochs so they don't
                // pollute the optimal basis set; the OBS fit is still
                // applied to every epoch.
                if !censoredEpochs.contains(s), var e = epochSlice(s) {
                    let m = e.reduce(0, +) / Double(e.count)
                    for i in 0..<e.count { e[i] -= m }  // detrend (remove mean)
                    pcaEpochs.append(e)
                }
            }
            guard pcaEpochs.count > 2 else { return nil }

            let (basis, oev) = DSP.pca(epochs: pcaEpochs)
            guard !basis.isEmpty else { return nil }

            let pcs: Int
            switch mode {
            case .fixed(let k): pcs = min(max(1, k), basis.count)
            case .auto: pcs = autoSelectPCs(oev: oev, max: basis.count)
            case .off: return nil
            }
            guard pcs > 0 else { return nil }

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
            anyChunkValid = true
            return columns
        }

        guard anyChunkValid else { return nil }
        return OBSPreparation(ipca: ipca, chunkColumns: chunkColumns)
    }

    /// CPU fallback fit: least-squares each chunk's epochs onto that chunk's
    /// own OBS design and scatter the fit back into a full-length array.
    private nonisolated static func applyOBSFitCPU(
        _ prep: OBSPreparation,
        epochChunks: [[Int]],
        alignedMarkers: [Int],
        prePeak: Int, postPeak: Int, artLength: Int,
        upLength: Int
    ) -> [Double] {
        var fittedRes = [Double](repeating: 0, count: upLength)
        for (chunkIndex, chunkEpochs) in epochChunks.enumerated() {
            guard let columns = prep.chunkColumns[safe: chunkIndex] ?? nil else { continue }
            for s in chunkEpochs {
                let start = alignedMarkers[s] - prePeak
                let end = alignedMarkers[s] + postPeak
                guard start >= 0, end < upLength else { continue }
                let target = Array(prep.ipca[start...end])
                let fit = DSP.leastSquaresFit(target: target, design: columns)
                for i in 0..<artLength { fittedRes[start + i] = fit[i] }
            }
        }
        return fittedRes
    }

    private nonisolated static func optimalBasisSet(
        idata: [Double], iNoise: [Double], alignedMarkers: [Int],
        prePeak: Int, postPeak: Int, artLength: Int,
        sliceTrigger: Bool,
        epochChunks: [[Int]],
        censoredEpochs: Set<Int>,
        obsHPF: [Double], mode: OBSMode,
        randomizeEpochSelection: Bool,
        metal: FastrMetalBackend?
    ) -> [Double] {
        let upLength = idata.count
        guard let prep = prepareOBS(
            idata: idata, iNoise: iNoise, alignedMarkers: alignedMarkers,
            prePeak: prePeak, postPeak: postPeak, artLength: artLength,
            sliceTrigger: sliceTrigger, epochChunks: epochChunks,
            censoredEpochs: censoredEpochs,
            obsHPF: obsHPF, mode: mode,
            randomizeEpochSelection: randomizeEpochSelection
        ) else { return [Double](repeating: 0, count: upLength) }

        var fittedRes = [Double](repeating: 0, count: upLength)
        for (chunkIndex, chunkEpochs) in epochChunks.enumerated() {
            guard let columns = prep.chunkColumns[safe: chunkIndex] ?? nil else { continue }
            let epochStarts = chunkEpochs.map { alignedMarkers[$0] - prePeak }
            if let metalFit = metal?.fitOptimalBasis(
                data: prep.ipca,
                epochStarts: epochStarts,
                columns: columns
            ) {
                for i in 0..<upLength { fittedRes[i] += metalFit[i] }
            } else {
                for s in chunkEpochs {
                    let start = alignedMarkers[s] - prePeak
                    let end = alignedMarkers[s] + postPeak
                    guard start >= 0, end < upLength else { continue }
                    let target = Array(prep.ipca[start...end])
                    let fit = DSP.leastSquaresFit(target: target, design: columns)
                    for i in 0..<artLength { fittedRes[start + i] = fit[i] }
                }
            }
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
        _ = out

        // `mu` is a single scalar tuned from this channel's *global* reference
        // variance; plain LMS (no leakage) is only stable while mu stays below
        // a bound tied to the *local* reference power, so a channel with
        // strongly time-varying reference power can diverge partway through
        // and then grow unboundedly for the rest of the recording — LMS has
        // no mechanism to recover once that happens. Over hundreds of
        // thousands of samples that eventually exceeds Double's range, but an
        // isInfinite/isNaN check alone only catches it once it's fully blown
        // up; a still-finite-but-enormous result can slip through here and
        // overflow a later recursive filter (e.g. the post-processing
        // Butterworth) into actual Inf/NaN, surfacing as an error on a
        // different stage than where the divergence actually started. Treat
        // "way outside the input's own scale" as divergence too, not just
        // literal non-finite values.
        let cleanScale = clean.reduce(0) { Swift.max($0, abs($1)) }
        let divergenceBound = Swift.max(cleanScale, 1) * 1000
        guard y.allSatisfy({ $0.isFinite && abs($0) <= divergenceBound }) else { return clean }

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

    /// Evenly subsamples `indices` down to `maxPCAEpochCount` (preserving
    /// spread across the recording rather than truncating to the front) when
    /// FACET's own subsample exceeds it. A no-op below the cap.
    private nonisolated static func capPCAEpochCount(_ indices: [Int]) -> [Int] {
        guard indices.count > maxPCAEpochCount else { return indices }
        let stride = Double(indices.count) / Double(maxPCAEpochCount)
        return (0..<maxPCAEpochCount).map { indices[Int(Double($0) * stride)] }
    }

    /// Groups epoch indices into contiguous `chunkSeconds`-long windows by
    /// each epoch's upsampled marker sample position, for FASTR's per-chunk
    /// OBS PCA (`Config.obsChunkSeconds`). `alignedMarkers` is assumed
    /// time-ordered (epochs are derived from sequential slice/volume
    /// triggers), so each chunk is a contiguous run of epoch indices.
    private nonisolated static func obsChunkEpochIndices(
        alignedMarkers: [Int],
        chunkSeconds: Double,
        samplingRate: Double,
        L: Int
    ) -> [[Int]] {
        guard !alignedMarkers.isEmpty else { return [] }
        guard chunkSeconds > 0, samplingRate > 0, L > 0 else {
            return [Array(alignedMarkers.indices)]
        }
        let chunkSamples = max(1, Int((chunkSeconds * samplingRate * Double(L)).rounded()))

        var chunks: [[Int]] = []
        var currentChunk: [Int] = []
        var chunkStartSample = alignedMarkers[0]
        for (index, marker) in alignedMarkers.enumerated() {
            if !currentChunk.isEmpty, marker - chunkStartSample >= chunkSamples {
                chunks.append(currentChunk)
                currentChunk = []
                chunkStartSample = marker
            }
            currentChunk.append(index)
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }
        return chunks
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
        // Each epoch aligns against its own template independently, so this
        // scales across CPU cores instead of running serially.
        fillResults(&aligned, iterations: baseMarkers.count) { s in
            guard s < templates.count, let template = templates[s], template.count == prePeak + postPeak + 1 else {
                return baseMarkers[s]
            }
            let shift = bestIntegerShift(
                dataUp: dataUp,
                template: template,
                center: baseMarkers[s],
                prePeak: prePeak,
                postPeak: postPeak,
                searchWindow: searchWindow
            )
            return baseMarkers[s] + shift
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
        let maxRadius = max(stride, numTrig * stride)
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

            // Every epoch's shift search is independent of the others, so this
            // scales across CPU cores instead of running serially — the same
            // pattern used for per-channel work elsewhere in FASTR.
            fillResults(&aligned, iterations: markersUp.count) { s in
                let shift = bestIntegerShift(
                    dataUp: dataUp,
                    template: reference,
                    center: markersUp[s],
                    prePeak: prePeak,
                    postPeak: postPeak,
                    searchWindow: searchWindow
                )
                return markersUp[s] + shift
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

            // Epoch 0 defines the reference and keeps shift 0; every other
            // epoch's bisection search is independent, so it can run across
            // CPU cores instead of serially.
            fillResults(&shifts, iterations: markers.count) { s in
                guard s != 0 else { return 0 }
                let start = markers[s] - prePeak - pad
                let end = markers[s] + postPeak + pad
                guard start >= 0, end < dataUp.count else { return 0 }
                let segment = Array(dataUp[start...end])
                guard segment.count == reference.count else { return 0 }
                return bestFractionalShift(segment: segment, reference: reference)
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
