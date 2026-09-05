//
//  GradientTemplateCorrector.swift
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
//  described in docs/provenance/README.md. Written without reference to FMRIB FASTR,
//  FACET, BERGEN, or EVA's earlier ported implementation; those toolboxes are
//  cited as historical and scientific references only. See
//  docs/provenance/fastr-audit-log.md.
//
//  Method references: Niazy et al., NeuroImage 28(3):720-737, 2005;
//  Moosmann et al., NeuroImage 45(4):1144-1150, 2009; van der Meer et al.,
//  Clinical Neurophysiology 121(5):766-776, 2010; Glaser et al., BMC
//  Neuroscience 14:138, 2013.
//
//  Removes the periodic MRI gradient artifact from EEG recorded during fMRI by
//  estimating, for each artifact epoch, a template built from other epochs and
//  subtracting a least-squares-scaled copy of it, then optionally removing what
//  is left with an optimal basis set and an adaptive filter.
//
//  The correction is computed on an internally upsampled axis, but what gets
//  downsampled is the *artifact estimate*, not the signal — so samples outside a
//  corrected epoch come through bit-identical to the input at any upsample
//  factor.
//
//  This file is the driver. It makes every discrete choice — donor sets, epoch
//  shifts, template scales, OBS component counts, whether ANC runs — and hands
//  the dense arithmetic to a `GradientBackend` batched across channels. See
//  `GradientAcceleration.swift` and docs/provenance/fastr-gpu-port-plan.md.
//

import Foundation

nonisolated enum GradientTemplateCorrector {

    /// Whether a Metal backend can be used on this machine. `.metal` falls back
    /// to the CPU silently when this is false, so a caller only needs it to
    /// decide whether to offer the choice.
    static var isMetalAvailable: Bool { GradientMetalBackend.isAvailable }

    /// Removes gradient artifact from `channels`.
    ///
    /// - Parameters:
    ///   - channels: Channel-major samples. Every channel must be the same length.
    ///   - volumeTriggers: Sample indices of the scanner volume markers.
    ///   - config: Epoch geometry, donor strategy, alignment, motion, and backend
    ///     options.
    ///   - samplingRate: Samples per second before internal upsampling.
    ///   - progress: Called with a monotonically increasing fraction in 0...1,
    ///     ending at exactly 1.
    /// - Returns: Corrected channels, same shape and order, plus diagnostics.
    static func correct(
        channels: [[Float]],
        volumeTriggers: [Int],
        config: GradientCorrectionConfig,
        samplingRate: Double,
        progress: (Double) -> Void = { _ in }
    ) throws -> GradientCorrectionResult {

        // MARK: Validate

        guard !channels.isEmpty else { throw GradientCorrectionError.noChannels }
        let sampleCount = channels[0].count
        guard sampleCount > 0 else { throw GradientCorrectionError.emptyChannels }
        guard channels.allSatisfy({ $0.count == sampleCount }) else {
            throw GradientCorrectionError.mismatchedChannelLengths
        }
        guard config.upsampleFactor >= 1 else {
            throw GradientCorrectionError.invalidConfiguration("upsampleFactor must be at least 1")
        }
        guard config.numberOfSlices >= 1 else {
            throw GradientCorrectionError.invalidConfiguration("numberOfSlices must be at least 1")
        }
        guard (0...1).contains(config.relativeTriggerPosition) else {
            throw GradientCorrectionError.invalidConfiguration("relativeTriggerPosition must be between 0 and 1")
        }

        let factor = config.upsampleFactor
        let layout = try GradientEpochLayout.build(
            volumeTriggers: volumeTriggers,
            sampleCount: sampleCount,
            slicesPerVolume: config.numberOfSlices,
            upsampleFactor: factor,
            relativeTriggerPosition: config.relativeTriggerPosition
        )

        var setupWarnings: [GradientCorrectionWarning] = []

        // MARK: Motion

        var highMotionVolumes: Set<Int> = []
        var motionDonorVolumes: [[Int]]?
        var effectiveScheme = config.templateScheme
        let desiredDonors = config.requestedDonorCount

        if let motion = config.motion, !motion.isEmpty {
            let aligned = GradientDonorSelection.alignMotionToVolumes(
                motion: motion,
                volumeCount: layout.volumeCount
            )
            setupWarnings.append(contentsOf: aligned.warnings)
            // High-motion volumes are still corrected, but never donate — this
            // holds for every strategy once motion is loaded, not just the
            // motion-informed one.
            highMotionVolumes = GradientDonorSelection.highMotionVolumes(
                motion: aligned.samples,
                metric: config.motionMetric,
                thresholdMm: config.motionThresholdMm,
                radiusMm: config.motionRadiusMm
            )
        } else if config.templateScheme == .motionInformed {
            setupWarnings.append(.motionUnavailableForScheme)
            effectiveScheme = .temporalNeighbors
        }

        if effectiveScheme == .motionInformed {
            if let selection = GradientDonorSelection.motionInformedDonorVolumes(
                volumeCount: layout.volumeCount,
                highMotion: highMotionVolumes,
                censored: config.censoredVolumes,
                desired: desiredDonors
            ) {
                motionDonorVolumes = selection.donors
                for volume in selection.crossedBarrier.sorted() {
                    setupWarnings.append(.donorsCrossedMotionBarrier(epoch: volume))
                }
            } else {
                setupWarnings.append(.noSupraThresholdMotion)
                effectiveScheme = .temporalNeighbors
            }
        }

        // MARK: Alignment

        // Estimated once, from one channel, and applied to every channel, so
        // cross-channel timing is preserved. Reduced deterministically on the
        // CPU: a parallel reduction that changed the summation order could pick
        // a different winner on a near-tie and move every downstream shift.
        let diagnosticChannel = representativeChannel(
            channels,
            excluding: config.excludedChannels
        )
        let searchRadius = config.alignmentEnabled
            ? (config.alignmentSearchRadius ?? GradientEpochAligner.defaultSearchRadius(period: layout.period))
            : 0
        let alignment = searchRadius > 0
            ? GradientEpochAligner.align(
                referenceSignal: GradientSincResampler.upsample(channels[diagnosticChannel], factor: factor),
                layout: layout,
                searchRadius: searchRadius,
                estimatesSubSample: config.subSampleAlignment
            )
            : GradientEpochAlignment.identity(epochCount: layout.count)

        // MARK: Per-epoch eligibility

        let epochCount = layout.count
        let length = layout.length
        var windowStarts = [Int](repeating: -1, count: epochCount)
        var donorEligible = [Bool](repeating: false, count: epochCount)
        for epoch in 0..<epochCount {
            let start = layout.windowStart(of: epoch, shift: alignment.integerShifts[epoch])
            windowStarts[epoch] = start ?? -1
            let volume = layout.volumeIndex[epoch]
            let censored = config.censoredVolumes.contains(volume) || highMotionVolumes.contains(volume)
            donorEligible[epoch] = start != nil && !censored
        }
        func isEligible(_ epoch: Int) -> Bool { donorEligible[epoch] }

        let plan = GradientBatchPlan(
            sampleCount: sampleCount,
            upsampleFactor: factor,
            epochCount: epochCount,
            windowLength: length,
            windowStarts: windowStarts,
            fractionalShifts: config.subSampleAlignment
                ? alignment.fractionalShifts
                : [Double](repeating: 0, count: epochCount)
        )

        // MARK: Backend and tiling

        let activeChannels = channels.indices.filter { !config.excludedChannels.contains($0) }
        let backend = resolveBackend(
            config.computeBackend,
            plan: plan,
            channelCount: activeChannels.count,
            minimumWorkload: config.metalMinimumWorkload
        )
        let tileWidth = max(1, min(
            max(activeChannels.count, 1),
            backend.maximumTileChannels(plan: plan)
        ))
        let tiles = stride(from: 0, to: activeChannels.count, by: tileWidth).map { start in
            Array(activeChannels[start..<min(start + tileWidth, activeChannels.count)])
        }

        let emitsDiagnostics = activeChannels.contains(diagnosticChannel)
        let periodAtSampleRate = max(1, layout.period / factor)
        let obsChunks = config.obs.isEnabled
            ? GradientOBS.chunkRanges(
                epochCount: epochCount,
                epochPeriodSamples: periodAtSampleRate,
                samplingRate: samplingRate,
                chunkSeconds: config.obsChunkSeconds
            )
            : []

        // MARK: Correlation candidates

        // The candidate list depends only on the epoch grid and on censoring, so
        // it is enumerated once and scored for every channel at once.
        let usesCorrelation = effectiveScheme == .correlationRanked
            || effectiveScheme == .squaredCorrelationRanked
        var correlationPairs: [GradientEpochPair] = []
        var correlationDistances: [Int32] = []
        var correlationRanges = [Range<Int>](repeating: 0..<0, count: epochCount)
        if usesCorrelation {
            for target in 0..<epochCount {
                guard windowStarts[target] >= 0 else { continue }
                let first = correlationPairs.count
                for (candidate, distance) in GradientDonorSelection.correlationCandidates(
                    target: target,
                    layout: layout,
                    isEligible: isEligible,
                    searchWindow: config.correlationSearchWindow
                ) {
                    correlationPairs.append(
                        GradientEpochPair(target: Int32(target), candidate: Int32(candidate))
                    )
                    correlationDistances.append(Int32(distance))
                }
                correlationRanges[target] = first..<correlationPairs.count
            }
        }

        // MARK: Correct

        var corrected = channels
        var epochWarningsByEpoch = [[GradientCorrectionWarning]](repeating: [], count: epochCount)
        var obsWarningsByChunk = [[GradientCorrectionWarning]](repeating: [], count: max(obsChunks.count, 1))
        var ancWarnings: [GradientCorrectionWarning] = []
        var epochDiagnostics: [GradientEpochDiagnostic] = []
        var obsComponentCounts: [Int] = []
        var ancAppliedChannels: Set<Int> = []

        let unitsPerTile = 6
        var completedUnits = 0
        let totalUnits = max(1, tiles.count * unitsPerTile)
        func advance() {
            completedUnits += 1
            progress(min(1, Double(completedUnits) / Double(totalUnits)))
        }

        for tile in tiles {
            try Task.checkCancellation()
            let width = tile.count
            let slotCount = width * epochCount
            let tileInputs = tile.map { channels[$0] }
            let diagnosticSlot = tile.firstIndex(of: diagnosticChannel)

            // Stage 1 — upsample and lift every epoch onto the aligned grid.
            let windows = try backend.extractEpochWindows(channels: tileInputs, plan: plan)
            advance()
            try Task.checkCancellation()

            // Stage 2 — donor sets. Every discrete choice in the pipeline that
            // depends on waveform similarity is made here, on the CPU.
            var donorLists = [[Int32]](repeating: [], count: slotCount)
            var correlationScores: [Double] = []
            if usesCorrelation, !correlationPairs.isEmpty {
                correlationScores = try scoreCorrelations(
                    backend: backend,
                    pairs: correlationPairs,
                    windows: windows,
                    channelCount: width,
                    plan: plan
                )
            }

            func record(_ selection: (donors: [Int], fellBack: Bool), target: Int) {
                if selection.fellBack {
                    epochWarningsByEpoch[target].append(.correlationDonorsFellBack(epoch: target))
                }
                if selection.donors.isEmpty {
                    epochWarningsByEpoch[target].append(.noEligibleDonors(epoch: target))
                    epochDiagnostics.append(diagnostic(
                        layout: layout, alignment: alignment, epoch: target,
                        donors: [], scale: 0, corrected: false
                    ))
                }
            }

            for target in 0..<epochCount {
                guard windowStarts[target] >= 0 else {
                    if emitsDiagnostics, diagnosticSlot != nil {
                        epochWarningsByEpoch[target].append(.epochOutOfBounds(epoch: target))
                        epochDiagnostics.append(diagnostic(
                            layout: layout, alignment: alignment, epoch: target,
                            donors: [], scale: 0, corrected: false
                        ))
                    }
                    continue
                }

                guard usesCorrelation else {
                    // Temporal and motion-informed donors depend only on the
                    // epoch grid, so one selection serves every channel.
                    let selection = selectDonors(
                        target: target, scheme: effectiveScheme, layout: layout,
                        config: config, desired: desiredDonors,
                        motionDonorVolumes: motionDonorVolumes,
                        isEligible: isEligible, scored: nil
                    )
                    let list = selection.donors.map(Int32.init)
                    for slot in 0..<width { donorLists[slot * epochCount + target] = list }
                    if emitsDiagnostics, diagnosticSlot != nil { record(selection, target: target) }
                    continue
                }

                for slot in 0..<width {
                    let selection = selectDonors(
                        target: target, scheme: effectiveScheme, layout: layout,
                        config: config, desired: desiredDonors,
                        motionDonorVolumes: motionDonorVolumes,
                        isEligible: isEligible,
                        scored: scoredCandidates(
                            target: target,
                            channelSlot: slot,
                            pairCount: correlationPairs.count,
                            pairs: correlationPairs,
                            distances: correlationDistances,
                            range: correlationRanges[target],
                            scores: correlationScores,
                            squared: effectiveScheme == .squaredCorrelationRanked,
                            allowsSelfDonation: config.allowsSelfDonation,
                            isEligible: isEligible
                        )
                    )
                    donorLists[slot * epochCount + target] = selection.donors.map(Int32.init)
                    if emitsDiagnostics, slot == diagnosticSlot { record(selection, target: target) }
                }
            }
            correlationScores = []
            advance()
            try Task.checkCancellation()

            // Stage 3 — donor-average templates and the two dot products the
            // scale is fitted from.
            let donors = flatten(donorLists, slotCount: slotCount)
            donorLists = []
            let templates = try backend.buildTemplates(
                windows: windows,
                donors: donors,
                channelCount: width,
                plan: plan
            )
            advance()
            try Task.checkCancellation()

            // Turn the raw per-epoch fits into the scales actually applied.
            var scales = [Double](repeating: 1, count: slotCount)
            for slot in 0..<width {
                var fitted = [Double?](repeating: nil, count: epochCount)
                for epoch in 0..<epochCount {
                    let index = slot * epochCount + epoch
                    guard templates.present[index] else {
                        if slot == diagnosticSlot, emitsDiagnostics,
                           windowStarts[epoch] >= 0, donors.offsets[index + 1] > donors.offsets[index] {
                            epochWarningsByEpoch[epoch].append(.degenerateTemplate(epoch: epoch))
                            epochDiagnostics.append(diagnostic(
                                layout: layout, alignment: alignment, epoch: epoch,
                                donors: donorIndices(donors, slot: index), scale: 0, corrected: false
                            ))
                        }
                        continue
                    }
                    fitted[epoch] = sanitizedScale(
                        quantized(templates.projections[index] / templates.energies[index]),
                        range: config.templateScaleRange
                    )
                    if fitted[epoch] == nil, slot == diagnosticSlot, emitsDiagnostics,
                       config.templateScaling != .unscaled {
                        epochWarningsByEpoch[epoch].append(.templateScaleRejected(epoch: epoch))
                    }
                }
                let resolved = resolveScales(
                    fitted: fitted,
                    mode: config.templateScaling,
                    smoothingEpochs: config.templateScaleSmoothingEpochs
                )
                for epoch in 0..<epochCount { scales[slot * epochCount + epoch] = resolved[epoch] }

                guard slot == diagnosticSlot, emitsDiagnostics else { continue }
                for epoch in 0..<epochCount where templates.present[slot * epochCount + epoch] {
                    epochDiagnostics.append(diagnostic(
                        layout: layout, alignment: alignment, epoch: epoch,
                        donors: donorIndices(donors, slot: slot * epochCount + epoch),
                        scale: resolved[epoch], corrected: true
                    ))
                }
            }

            // Stage 4 — residuals, and the artifact estimate put back on each
            // epoch's own sub-sample phase.
            let runsOBS = config.obs.isEnabled && !obsChunks.isEmpty
            let batch = try backend.residualsAndEstimates(
                windows: windows,
                templates: templates,
                scales: scales,
                channelCount: width,
                plan: plan,
                needsResiduals: runsOBS
            )
            advance()
            try Task.checkCancellation()

            // Stage 5 — OBS: what template subtraction left behind still has
            // structure. Find the dominant shapes among the residuals in each
            // chunk and add each epoch's projection onto them to the artifact
            // estimate. Every decision here — which chunks run, how many
            // components come out — stays on the CPU; only the Gram matrix is
            // handed to the backend.
            var obsContributions: [Float]?
            if runsOBS {
                obsContributions = try applyOBS(
                    backend: backend,
                    tile: tile,
                    diagnosticSlot: emitsDiagnostics ? diagnosticSlot : nil,
                    chunks: obsChunks,
                    residuals: batch.residuals,
                    present: templates.present,
                    energies: templates.energies,
                    scales: scales,
                    config: config,
                    plan: plan,
                    componentCounts: &obsComponentCounts,
                    warningsByChunk: &obsWarningsByChunk
                )
            }
            advance()
            try Task.checkCancellation()

            // Stage 6 — gather, average the overlaps, decimate, subtract, and
            // adapt away whatever artifact drift the epoch-wise stages could not
            // follow.
            var (cleaned, artifact) = try backend.assembleCorrection(
                inputs: tileInputs,
                estimates: batch.estimates,
                obsContributions: obsContributions,
                present: templates.present,
                plan: plan
            )

            // ANC runs per channel, so an excluded channel is simply left out of
            // the batch rather than run and discarded.
            let ancChannels = config.anc
                ? tile.indices.filter { !config.ancExcludedChannels.contains(tile[$0]) }
                : []
            if !ancChannels.isEmpty {
                let request = GradientANCRequest(
                    cutoffHz: GradientANC.cutoffHz(
                        policy: config.ancHighPass,
                        epochPeriodSamples: periodAtSampleRate,
                        samplingRate: samplingRate
                    ),
                    samplingRate: samplingRate,
                    filterLength: config.ancFilterLength,
                    stepSize: config.ancStepSize
                )
                let results = try backend.adaptiveNoiseCancel(
                    cleaned: ancChannels.map { cleaned[$0] },
                    references: ancChannels.map { artifact[$0] },
                    request: request
                )
                for (position, slot) in ancChannels.enumerated() {
                    if results[position].applied {
                        ancAppliedChannels.insert(tile[slot])
                        cleaned[slot] = results[position].output
                    } else {
                        ancWarnings.append(
                            .ancSkippedForUninformativeReference(channel: tile[slot])
                        )
                    }
                }
            }

            for slot in 0..<width { corrected[tile[slot]] = cleaned[slot] }
            advance()
        }

        if tiles.isEmpty { progress(1) }

        var warnings = setupWarnings
        for bucket in epochWarningsByEpoch { warnings.append(contentsOf: bucket) }
        for bucket in obsWarningsByChunk { warnings.append(contentsOf: bucket) }
        warnings.append(contentsOf: ancWarnings)

        return GradientCorrectionResult(
            channels: corrected,
            diagnostics: GradientCorrectionDiagnostics(
                epochCount: epochCount,
                period: layout.period,
                samplesBefore: layout.samplesBefore,
                samplesAfter: layout.samplesAfter,
                referenceChannel: diagnosticChannel,
                computeBackend: backend.backend,
                highMotionVolumes: highMotionVolumes,
                // Uncorrected epochs are recorded while the scales are resolved
                // and corrected ones after, so restore epoch order.
                epochs: epochDiagnostics.sorted { $0.epoch < $1.epoch },
                obsComponentCounts: obsComponentCounts,
                ancAppliedChannels: ancAppliedChannels,
                warnings: warnings
            )
        )
    }

    // MARK: - Backend selection

    /// The backend that will actually run, after availability and size checks.
    ///
    /// A GPU round trip has a fixed cost that a short recording never earns back,
    /// and the user should not have to reason about where that crossover is.
    static func resolveBackend(
        _ requested: GradientComputeBackend,
        plan: GradientBatchPlan,
        channelCount: Int,
        minimumWorkload: Int
    ) -> GradientBackend {
        guard requested == .metal else { return GradientCPUBackend.shared }
        let workload = plan.epochBufferCount(channels: max(channelCount, 1))
        guard workload >= minimumWorkload else { return GradientCPUBackend.shared }
        return GradientMetalBackend.shared ?? GradientCPUBackend.shared
    }

    // MARK: - Correlation scoring

    /// Correlations for every `(channel, candidate pair)`, in target blocks so a
    /// long recording never needs the whole matrix resident at once.
    private static func scoreCorrelations(
        backend: GradientBackend,
        pairs: [GradientEpochPair],
        windows: GradientDeviceBuffer,
        channelCount: Int,
        plan: GradientBatchPlan
    ) throws -> [Double] {
        let total = channelCount * pairs.count
        var scores = [Double](repeating: 0, count: total)
        guard total > 0 else { return scores }

        let blockPairs = max(1, correlationValueBudget / max(channelCount, 1))
        var first = 0
        while first < pairs.count {
            let last = min(first + blockPairs, pairs.count)
            let block = Array(pairs[first..<last])
            let values = try backend.epochCorrelations(
                pairs: block,
                windows: windows,
                channelCount: channelCount,
                plan: plan
            )
            for channel in 0..<channelCount {
                let source = channel * block.count
                let destination = channel * pairs.count + first
                for index in 0..<block.count {
                    scores[destination + index] = values[source + index]
                }
            }
            first = last
        }
        return scores
    }

    /// How many correlation values one block may hold. 8 million doubles is
    /// 64 MB, which keeps the transfer comfortably inside a GPU's working set
    /// while still being large enough that the per-dispatch overhead disappears.
    private static let correlationValueBudget = 8_000_000

    private static func scoredCandidates(
        target: Int,
        channelSlot: Int,
        pairCount: Int,
        pairs: [GradientEpochPair],
        distances: [Int32],
        range: Range<Int>,
        scores: [Double],
        squared: Bool,
        allowsSelfDonation: Bool,
        isEligible: (Int) -> Bool
    ) -> [GradientDonorSelection.ScoredCandidate] {
        var scored: [GradientDonorSelection.ScoredCandidate] = []
        scored.reserveCapacity(range.count + 1)
        if squared, allowsSelfDonation, isEligible(target) {
            scored.append(.init(epoch: target, score: 1, distance: 0))
        }
        let base = channelSlot * pairCount
        for index in range {
            let r = scores[base + index]
            scored.append(.init(
                epoch: Int(pairs[index].candidate),
                score: quantized(squared ? r * r : r),
                distance: Int(distances[index])
            ))
        }
        return scored
    }

    // MARK: - Donor dispatch

    private static func selectDonors(
        target: Int,
        scheme: GradientTemplateScheme,
        layout: GradientEpochLayout,
        config: GradientCorrectionConfig,
        desired: Int,
        motionDonorVolumes: [[Int]]?,
        isEligible: (Int) -> Bool,
        scored: [GradientDonorSelection.ScoredCandidate]?
    ) -> (donors: [Int], fellBack: Bool) {

        func temporal() -> [Int] {
            GradientDonorSelection.nearestTemporalDonors(
                target: target,
                epochCount: layout.count,
                desired: desired,
                allowsSelfDonation: config.allowsSelfDonation,
                isEligible: isEligible
            )
        }

        switch scheme {
        case .temporalNeighbors:
            return (temporal(), false)

        case .motionInformed:
            guard let volumeDonors = motionDonorVolumes else { return (temporal(), false) }
            let volume = layout.volumeIndex[target]
            guard volume < volumeDonors.count else { return (temporal(), false) }
            let slice = layout.slicePosition[target]
            let donors = volumeDonors[volume]
                .compactMap { layout.epochIndex(volume: $0, slicePosition: slice) }
                .filter(isEligible)
            // A volume can be motion-free yet still have no usable epoch at this
            // slice position near the end of the recording.
            return donors.isEmpty ? (temporal(), false) : (donors, false)

        case .correlationRanked, .squaredCorrelationRanked:
            guard desired > 0, let scored else { return (temporal(), true) }
            let result = GradientDonorSelection.rankCorrelationDonors(
                scored,
                squared: scheme == .squaredCorrelationRanked,
                threshold: config.correlationThreshold,
                minimumQualified: config.minimumCorrelatedDonors,
                desired: desired
            )
            if result.fellBack || result.donors.isEmpty {
                return (temporal(), true)
            }
            return (result.donors, false)
        }
    }

    // MARK: - OBS

    /// Runs the optimal-basis-set stage over one tile of channels.
    ///
    /// - Returns: Per-`(channel, epoch)` contributions to add to the artifact
    ///   estimate, on each epoch's own sub-sample phase, or nil when no chunk
    ///   produced a basis.
    private static func applyOBS(
        backend: GradientBackend,
        tile: [Int],
        diagnosticSlot: Int?,
        chunks: [Range<Int>],
        residuals: [Float],
        present: [Bool],
        energies: [Double],
        scales: [Double],
        config: GradientCorrectionConfig,
        plan: GradientBatchPlan,
        componentCounts: inout [Int],
        warningsByChunk: inout [[GradientCorrectionWarning]]
    ) throws -> [Float]? {

        let epochCount = plan.epochCount
        let length = plan.windowLength
        let width = tile.count

        struct Job {
            let slot: Int
            let chunk: Int
            let usable: [Int]
            let sampled: [Int]
            let detrended: [[Float]]
        }

        var jobs: [Job] = []
        var detrendedBuffer: [Float] = []
        var gramJobs: [GradientGramJob] = []

        for slot in 0..<width {
            guard !config.obsExcludedChannels.contains(tile[slot]) else { continue }
            let isDiagnostic = slot == diagnosticSlot

            for (chunkIndex, chunk) in chunks.enumerated() {
                let usable = chunk.filter { present[slot * epochCount + $0] }
                guard usable.count >= GradientOBS.minimumEpochsForBasis else {
                    if isDiagnostic, !usable.isEmpty {
                        warningsByChunk[chunkIndex].append(.obsChunkTooSmall(epochCount: usable.count))
                    }
                    continue
                }

                // If template subtraction already accounted for essentially all
                // of the artifact, the residual is brain signal, and the basis
                // would describe that instead.
                var residualEnergy = 0.0
                var removedEnergy = 0.0
                for epoch in usable {
                    let index = slot * epochCount + epoch
                    removedEnergy += scales[index] * scales[index] * energies[index]
                    let base = index * length
                    for offset in 0..<length {
                        let value = Double(residuals[base + offset])
                        residualEnergy += value * value
                    }
                }
                guard removedEnergy <= 0
                    || residualEnergy >= config.obsResidualEnergyFloor * removedEnergy
                else {
                    if isDiagnostic {
                        warningsByChunk[chunkIndex].append(
                            .obsResidualBelowFloor(chunkStart: chunk.lowerBound)
                        )
                    }
                    continue
                }

                let sampled = GradientOBS.subsample(usable, limit: config.obsMaximumEpochsPerChunk)
                let detrended = sampled.map { epoch -> [Float] in
                    let base = (slot * epochCount + epoch) * length
                    return GradientFilters.removeLinearTrend(
                        Array(residuals[base..<(base + length)])
                    )
                }
                gramJobs.append(GradientGramJob(offset: detrendedBuffer.count, size: detrended.count))
                for window in detrended { detrendedBuffer.append(contentsOf: window) }
                jobs.append(Job(
                    slot: slot, chunk: chunkIndex, usable: usable,
                    sampled: sampled, detrended: detrended
                ))
            }
        }

        guard !jobs.isEmpty else { return nil }
        let finalizedJobs = jobs

        let grams = try backend.gramMatrices(
            jobs: gramJobs,
            detrended: detrendedBuffer,
            windowLength: length
        )

        // Jobs are independent — chunks partition the epochs and slots are
        // distinct channels — so each writes to its own disjoint range of
        // `contributions` and they can run at once. This is where the time goes
        // once the Gram is on the GPU: the eigen-decompositions dominate, and
        // running them one after another left most of the machine idle.
        var contributions = [Float](repeating: 0, count: width * epochCount * length)
        var componentsPerJob = [Int?](repeating: nil, count: finalizedJobs.count)

        contributions.withUnsafeMutableBufferPointer { buffer in
            let out = GradientUnsafeSendable(base: buffer.baseAddress!)
            componentsPerJob.withUnsafeMutableBufferPointer { countBuffer in
                let counts = GradientUnsafeSendable(base: countBuffer.baseAddress!)
                GradientParallel.forEach(finalizedJobs.count) { index in
                    let job = finalizedJobs[index]
                    let basis = GradientOBS.basis(
                        gram: grams[index],
                        residuals: job.detrended,
                        mode: config.obs,
                        varianceThreshold: config.obsVarianceThreshold,
                        maximumComponents: config.obsMaximumComponents
                    )
                    guard !basis.isEmpty else { return }
                    counts.base[index] = basis.count

                    for epoch in job.usable {
                        let base = (job.slot * epochCount + epoch) * length
                        var removed = GradientOBS.projection(
                            of: Array(residuals[base..<(base + length)]),
                            onto: basis
                        )
                        if plan.appliesFractionalDelay(epoch) {
                            removed = GradientSincResampler.fractionalDelay(
                                removed, by: plan.fractionalShifts[epoch]
                            )
                        }
                        for offset in 0..<length { out.base[base + offset] = removed[offset] }
                    }
                }
            }
        }

        // Diagnostics are merged back in job order, which is (channel, chunk)
        // order, so what the diagnostic channel reports does not depend on how
        // the jobs happened to be scheduled.
        var produced = false
        for (index, job) in finalizedJobs.enumerated() {
            guard let count = componentsPerJob[index] else {
                if job.slot == diagnosticSlot {
                    warningsByChunk[job.chunk].append(
                        .obsBasisUnavailable(chunkStart: chunks[job.chunk].lowerBound)
                    )
                }
                continue
            }
            produced = true
            if job.slot == diagnosticSlot { componentCounts.append(count) }
        }
        return produced ? contributions : nil
    }

    // MARK: - Template scaling

    /// Rounds a value onto a fixed grid before it is compared or sorted.
    ///
    /// Donor ranking, correlation qualification, and template-scale rejection are
    /// discrete choices, and a value computed to a different last bit on a
    /// different backend must not flip them. A grid of 1e-6 is coarse enough to
    /// absorb the roughly 1e-7 relative error of compensated float32
    /// accumulation, and fine enough that it cannot change a decision that was
    /// not already a near-tie: correlations between real donor candidates differ
    /// in the fourth decimal, and a 1e-6 shift in a template scale moves a 100 µV
    /// artifact estimate by 1e-4 µV.
    static func quantized(_ value: Double) -> Double {
        guard value.isFinite, abs(value) < 1e9 else { return value }
        return (value * 1e6).rounded() / 1e6
    }

    /// Rejects a fitted scale that cannot be describing a real artifact amplitude.
    ///
    /// A non-finite or non-positive fit means the projection was meaningless, and
    /// a wildly out-of-range one means the template did not match the epoch at
    /// all. In every case the honest answer is that this epoch produced no usable
    /// amplitude estimate, so `nil` is returned and the caller falls back.
    static func sanitizedScale(_ raw: Double, range: ClosedRange<Double>) -> Double? {
        guard raw.isFinite, raw > 0, range.contains(raw) else { return nil }
        return raw
    }

    /// Turns per-epoch fitted scales into the scales actually applied.
    ///
    /// - `.unscaled` ignores the fits entirely.
    /// - `.leastSquares` uses each fit as-is, falling back to 1 where the fit was
    ///   rejected.
    /// - `.driftTracking` takes a running median across neighbouring epochs. A
    ///   genuine amplitude change persists over many epochs and survives the
    ///   median; the epoch-to-epoch scatter that comes from brain signal
    ///   correlating with the template does not, so it stops being subtracted.
    ///   The median rather than a mean because it also passes a step change —
    ///   which is what head motion produces — through sharply.
    static func resolveScales(
        fitted: [Double?],
        mode: GradientTemplateScaling,
        smoothingEpochs: Int
    ) -> [Double] {
        switch mode {
        case .unscaled:
            return [Double](repeating: 1, count: fitted.count)

        case .leastSquares:
            return fitted.map { $0 ?? 1 }

        case .driftTracking:
            let halfWindow = max(1, smoothingEpochs) / 2
            var resolved = [Double](repeating: 1, count: fitted.count)
            for index in fitted.indices {
                guard fitted[index] != nil else { continue }
                let lower = max(0, index - halfWindow)
                let upper = min(fitted.count - 1, index + halfWindow)
                var neighbourhood = [Double]()
                neighbourhood.reserveCapacity(upper - lower + 1)
                for neighbour in lower...upper {
                    if let value = fitted[neighbour] { neighbourhood.append(value) }
                }
                guard !neighbourhood.isEmpty else { continue }
                neighbourhood.sort()
                let middle = neighbourhood.count / 2
                resolved[index] = neighbourhood.count.isMultiple(of: 2)
                    ? (neighbourhood[middle - 1] + neighbourhood[middle]) / 2
                    : neighbourhood[middle]
            }
            return resolved
        }
    }

    // MARK: - Helpers

    /// The channel alignment is estimated from: the highest-variance channel
    /// that is not excluded, since gradient artifact dominates variance and a
    /// flat or disconnected channel carries no timing information. Ties go to
    /// the lowest index so the choice is deterministic.
    static func representativeChannel(
        _ channels: [[Float]],
        excluding excluded: Set<Int>
    ) -> Int {
        var best = 0
        var bestVariance = -Double.infinity
        var found = false
        for index in channels.indices where !excluded.contains(index) {
            let channel = channels[index]
            guard !channel.isEmpty else { continue }
            var mean = 0.0
            for value in channel { mean += Double(value) }
            mean /= Double(channel.count)
            var variance = 0.0
            for value in channel {
                let deviation = Double(value) - mean
                variance += deviation * deviation
            }
            variance /= Double(channel.count)
            if variance > bestVariance {
                bestVariance = variance
                best = index
                found = true
            }
        }
        return found ? best : 0
    }

    private static func flatten(_ lists: [[Int32]], slotCount: Int) -> GradientDonorTable {
        var offsets = [Int32](repeating: 0, count: slotCount + 1)
        var indices: [Int32] = []
        indices.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        for slot in 0..<slotCount {
            offsets[slot] = Int32(indices.count)
            indices.append(contentsOf: lists[slot])
        }
        offsets[slotCount] = Int32(indices.count)
        return GradientDonorTable(offsets: offsets, indices: indices)
    }

    private static func donorIndices(_ table: GradientDonorTable, slot: Int) -> [Int] {
        let first = Int(table.offsets[slot])
        let last = Int(table.offsets[slot + 1])
        guard last > first else { return [] }
        return table.indices[first..<last].map(Int.init)
    }

    private static func diagnostic(
        layout: GradientEpochLayout,
        alignment: GradientEpochAlignment,
        epoch: Int,
        donors: [Int],
        scale: Double,
        corrected: Bool
    ) -> GradientEpochDiagnostic {
        GradientEpochDiagnostic(
            epoch: epoch,
            trigger: layout.triggers[epoch],
            volume: layout.volumeIndex[epoch],
            slicePosition: layout.slicePosition[epoch],
            integerShift: alignment.integerShifts[epoch],
            fractionalShift: alignment.fractionalShifts[epoch],
            donorIndices: donors,
            templateScale: scale,
            corrected: corrected
        )
    }
}
