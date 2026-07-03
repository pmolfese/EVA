//
//  WaveletReductionSheetViews.swift
//  EVA
//
//  Wavelet reduction sheet (plain reduction, not the artifact explorer -- that is WaveletArtifactExplorerViews.swift),
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI
import UniformTypeIdentifiers

extension WaveformView {
    // MARK: - Wavelet reduction

    func openWaveletReductionSheet(input: MFFSignalData) {
        // Initialize the config from the current mode's defaults for this rate
        // unless a run already established settings.
        if wavelet.result == nil {
            wavelet.config = wavelet.mode.defaultConfiguration(samplingRate: input.samplingRate)
        }
        wavelet.showsSheet = true
    }

    func setWaveletReductionEnabled(_ isEnabled: Bool) {
        guard wavelet.reducedSignal != nil, wavelet.isEnabled != isEnabled else { return }
        wavelet.isEnabled = isEnabled
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    func revertWaveletReduction() {
        guard wavelet.reducedSignal != nil else { return }
        wavelet.reducedSignal = nil
        wavelet.artifact = nil
        wavelet.result = nil
        wavelet.bandVarianceRetained = nil
        wavelet.statusMessage = "Reverted wavelet reduction."
        wavelet.candidates = []
        wavelet.selectedCandidateID = nil
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
        artifactVM.detectionRefreshToken += 1
    }

    func runWaveletReduction(on input: MFFSignalData) {
        guard !wavelet.isRunning else { return }
        let config = wavelet.config
        let mode = wavelet.mode
        let cores = wavelet.coreCount
        let analysisBand: (low: Double, high: Double)? = {
            guard let low = filter.highPassCutoff,
                  let high = filter.lowPassCutoff else {
                return nil
            }
            return (low, high)
        }()
        // Leave bad channels untouched; reduce everything else.
        let reduceIndices = input.data.indices.filter { !channels.bad.contains($0) }

        wavelet.isRunning = true
        wavelet.progress = 0
        wavelet.statusMessage = "Running wavelet reduction…"
        wavelet.bandVarianceRetained = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            wavelet.progress = min(max(fraction, 0), 1)
        }

        waveletReductionTask?.cancel()
        let sessionID = recordingSessionID
        waveletReductionTask = Task { @MainActor in
            await processingQueue.run("Wavelet Reduction") { [self] in
                let worker = Task.detached(priority: .userInitiated) {
                    WaveletReducer.reduce(
                        signal: input,
                        channelIndices: Array(reduceIndices),
                        configuration: config,
                        coreCount: cores
                    ) { fraction in
                        progressContinuation.yield(fraction * (mode.assessesInBand ? 0.8 : 1.0))
                    }
                }
                let result = await withTaskCancellationHandler(
                    operation: {
                        await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                        progressContinuation.finish()
                    }
                )

                // ERP path: assess variance retained within the analysis band, as HAPPE does.
                var bandRetained: Double?
                if !Task.isCancelled,
                   sessionID == recordingSessionID,
                   mode.assessesInBand,
                   let analysisBand,
                   analysisBand.high > analysisBand.low,
                   analysisBand.high < input.samplingRate / 2 {
                    let bandWorker = Task.detached(priority: .utility) {
                        await bandLimitedVarianceRetained(
                            original: input,
                            cleaned: result.cleaned,
                            channelIndices: Array(reduceIndices),
                            band: analysisBand
                        )
                    }
                    bandRetained = await withTaskCancellationHandler(
                        operation: {
                            await bandWorker.value
                        },
                        onCancel: {
                            bandWorker.cancel()
                        }
                    )
                }

                progressContinuation.finish()
                progressTask.cancel()

                guard !Task.isCancelled, sessionID == recordingSessionID else { return }
                wavelet.reducedSignal = result.cleaned
                wavelet.artifact = result.artifact
                wavelet.result = result
                wavelet.bandVarianceRetained = bandRetained
                wavelet.candidates = WaveletReducer.findCandidates(
                    artifact: result.artifact,
                    channelIndices: Array(reduceIndices),
                    maxCount: 40
                )
                wavelet.selectedCandidateID = wavelet.candidates.first?.id
                wavelet.isEnabled = true
                wavelet.isRunning = false
                wavelet.progress = 1
                let varianceText = String(format: "%.1f%%", result.varianceRetainedPercent)
                wavelet.statusMessage = "Reduced \(reduceIndices.count) channels · \(varianceText) variance retained · r \(String(format: "%.2f", result.meanCorrelation))"
                invalidateEpochsForSignalChange()
                invalidateInterpolations()
                artifactVM.detectionRefreshToken += 1
                waveletReductionTask = nil
            }
        }
    }

    /// Filters original and cleaned signals to the analysis band and returns the
    /// variance retained = var(cleaned_band)/var(original_band) over the reduced
    /// channels, mirroring HAPPE's in-band ERP quality assessment.
    private nonisolated func bandLimitedVarianceRetained(
        original: MFFSignalData,
        cleaned: MFFSignalData,
        channelIndices: [Int],
        band: (low: Double, high: Double)
    ) async -> Double? {
        do {
            let originalBand = try await EEGSignalFilter.bandPass(
                channels: channelIndices.map { original.data[$0] },
                samplingRate: original.samplingRate,
                lowCutoff: band.low,
                highCutoff: band.high
            )
            let cleanedBand = try await EEGSignalFilter.bandPass(
                channels: channelIndices.map { cleaned.data[$0] },
                samplingRate: cleaned.samplingRate,
                lowCutoff: band.low,
                highCutoff: band.high
            )
            var originalVariance = 0.0
            var cleanedVariance = 0.0
            for index in originalBand.indices {
                originalVariance += variance(of: originalBand[index])
                cleanedVariance += variance(of: cleanedBand[index])
            }
            guard originalVariance > 1e-12 else { return nil }
            return cleanedVariance / originalVariance * 100
        } catch {
            return nil
        }
    }

    private nonisolated func variance(of values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        return values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(values.count)
    }

    func applyArtifactCleaning(to signal: MFFSignalData) {
        let artifacts = template.definedArtifacts
        guard artifacts.contains(where: { $0.cleaningMethod.removesArtifact }) else {
            restoreArtifactCleaning()
            return
        }

        artifactVM.isCleaning = true
        artifactVM.cleaningStatusMessage = nil
        artifactVM.cleaningProgress = nil
        let badChannels = channels.bad
        let (progressContinuation, progressTask) = ProgressBridge.make { progress in
            artifactVM.cleaningProgress = progress
        }

        artifactCleaningTask?.cancel()
        let sessionID = recordingSessionID
        artifactCleaningTask = Task {
            await processingQueue.run("Artifact Cleaning") { [self] in
                let worker = Task.detached(priority: .userInitiated) {
                    ArtifactCleaner.cleanedSignal(
                        from: signal,
                        artifacts: artifacts,
                        excluding: badChannels
                    ) { progress in
                        progressContinuation.yield(progress)
                    }
                }
                let outcome = await withTaskCancellationHandler(
                    operation: {
                        await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                        progressContinuation.finish()
                    }
                )
                progressContinuation.finish()
                progressTask.cancel()

                guard !Task.isCancelled, sessionID == recordingSessionID else { return }
                artifactVM.cleanedSignal = outcome.signal
                artifactVM.cleaningIsEnabled = true
                artifactVM.cleaningSummaries = outcome.summaries
                let summariesByID = Dictionary(uniqueKeysWithValues: outcome.summaries.map { ($0.artifactID, $0) })
                let now = Date()
                for index in template.definedArtifacts.indices {
                    if summariesByID[template.definedArtifacts[index].id] != nil,
                       template.definedArtifacts[index].cleaningMethod.removesArtifact {
                        template.definedArtifacts[index].appliedMethod = template.definedArtifacts[index].cleaningMethod
                        template.definedArtifacts[index].cleanedAt = now
                    } else {
                        template.definedArtifacts[index].appliedMethod = nil
                        template.definedArtifacts[index].cleanedAt = nil
                    }
                }

                artifactVM.cleaningStatusMessage = artifactCleaningSummaryText(outcome.summaries)
                artifactVM.statusMessage = artifactVM.cleaningStatusMessage
                artifactVM.detectionRefreshToken += 1
                invalidateEpochsForSignalChange()
                invalidateInterpolations()
                artifactVM.cleaningProgress = nil
                artifactVM.isCleaning = false
                artifactCleaningTask = nil
                if replay.state.isAwaitingDecision {
                    artifactVM.showsCleaningSheet = false
                    replay.resume(.proceed)
                }
                precomputeCleaningPreviews(beforeSignal: signal, afterSignal: outcome.signal)
            }
        }
    }

    /// Precomputes the before/after hover-preview data for every applied
    /// artifact right after Apply finishes, so the mouse-over preview becomes
    /// a cache lookup instead of recomputing a per-artifact average (over all
    /// events × channels) from scratch on every hover.
    private func precomputeCleaningPreviews(beforeSignal: MFFSignalData, afterSignal: MFFSignalData) {
        let appliedArtifacts = template.definedArtifacts.filter { $0.appliedMethod != nil }
        guard !appliedArtifacts.isEmpty else { return }
        let sessionID = recordingSessionID
        Task.detached(priority: .utility) {
            var entries: [(String, ArtifactCleaningPreviewData)] = []
            entries.reserveCapacity(appliedArtifacts.count)
            for artifact in appliedArtifacts {
                guard let method = artifact.appliedMethod else { continue }
                let key = ArtifactCleaningPreview.cacheKey(artifactID: artifact.id, method: method.rawValue, afterSignal: afterSignal)
                let data = ArtifactCleaningPreview.makePreviewData(
                    artifact: artifact,
                    beforeSignal: beforeSignal,
                    afterSignal: afterSignal
                )
                entries.append((key, data))
            }
            await MainActor.run {
                guard sessionID == self.recordingSessionID else { return }
                for (key, data) in entries {
                    self.template.cleaningPreviewCache[key] = data
                }
            }
        }
    }

    func artifactCleaningSummaryText(_ summaries: [ArtifactCleaningSummary]) -> String {
        guard !summaries.isEmpty else {
            return "No artifact cleanup was applied."
        }
        if summaries.count == 1, let summary = summaries.first {
            return "\(summary.method.rawValue) cleaned \(summary.name) across \(summary.channelCount) channels."
        }
        return "Cleaned \(summaries.count) artifacts."
    }

    func restoreArtifactCleaning() {
        clearAppliedArtifactCleaning()
        artifactVM.cleaningStatusMessage = "Artifact cleaning restored to the current uncleaned signal."
        artifactVM.statusMessage = artifactVM.cleaningStatusMessage
    }

    func clearAppliedArtifactCleaning() {
        let hadCleaning = artifactVM.cleanedSignal != nil || template.definedArtifacts.contains { $0.appliedMethod != nil }
        artifactVM.cleanedSignal = nil
        artifactVM.cleaningIsEnabled = true
        artifactVM.cleaningSummaries = []
        artifactVM.cleaningProgress = nil
        artifactVM.cleaningStatusMessage = nil
        for index in template.definedArtifacts.indices {
            template.definedArtifacts[index].appliedMethod = nil
            template.definedArtifacts[index].cleanedAt = nil
        }
        guard hadCleaning else { return }
        artifactVM.detectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    var artifactScanSignature: ArtifactScanSignature {
        ArtifactScanSignature(
            eventCode: template.eventCode,
            clickedChannel: template.clickedChannel,
            channelScope: template.channelScope,
            customChannels: template.customChannels,
            threshold: template.threshold,
            windowSeconds: template.windowSeconds,
            downsampleRate: template.downsampleRate,
            mergeWindowSeconds: template.mergeWindowSeconds,
            polarity: template.polarity,
            range: template.selectionRange
        )
    }

    /// True when settings have changed since the displayed result was produced
    /// (or no scan has run yet).
    var artifactTemplateScanIsStale: Bool {
        template.lastScanSignature != artifactScanSignature
    }

    /// Builds the detector configuration from the current sheet controls.
    func artifactTemplateConfiguration(
        for signal: MFFSignalData,
        range: ClosedRange<Int>
    ) -> ArtifactTemplateConfiguration {
        ArtifactTemplateConfiguration(
            name: template.name.trimmingCharacters(in: .whitespacesAndNewlines),
            eventCode: template.eventCode.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedChannelIndices: artifactTemplateSelectedChannels(in: signal),
            comparisonChannelIndices: Array(signal.data.indices),
            exemplarRange: range,
            matchThreshold: template.threshold,
            windowSizeSeconds: max(template.windowSeconds, 0.01),
            downsampleRate: min(max(template.downsampleRate, 20), signal.samplingRate),
            mergeWindowSeconds: max(template.mergeWindowSeconds, 0.01),
            polarity: template.polarity,
            comparisonScopes: artifactTemplateComparisonScopes(in: signal),
            topographyMode: template.topographyMode,
            topographyChannelIndices: artifactTopographyChannels(in: signal),
            topographyMetric: template.topographyMetric,
            trajectoryShiftSeconds: template.trajectoryShiftSeconds,
            trajectoryScaleRange: template.trajectoryScaleRange,
            trajectoryGFPWeighted: template.trajectoryGFPWeighted
        )
    }

    /// Channels used for the scalp-topography correlation: all readable channels
    /// minus bad channels (and, in future, restricted to a selected cluster).
    func artifactTopographyChannels(in signal: MFFSignalData) -> [Int] {
        let goodChannels = signal.data.indices.filter { !channels.bad.contains($0) }
        switch template.topographyChannelScope {
        case .allGood:
            return goodChannels
        case .topN:
            guard let range = template.selectionRange,
                  !goodChannels.isEmpty else { return goodChannels }
            let n = max(min(template.topographyTopN, goodChannels.count), 3)
            // Rank by RMS amplitude over the exemplar window.
            let scored: [(Int, Float)] = goodChannels.map { chIdx in
                let ch = signal.data[chIdx]
                let lo = max(range.lowerBound, 0)
                let hi = min(range.upperBound, ch.count - 1)
                guard lo <= hi else { return (chIdx, Float(0)) }
                let slice = ch[lo...hi]
                let mean = slice.reduce(Float(0), +) / Float(slice.count)
                let rms  = sqrt(slice.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
                                / Float(slice.count))
                return (chIdx, rms)
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(n).map { $0.0 }.sorted()
        case .channelSet:
            guard let id = template.topographyChannelSetID,
                  let set = ChannelSetStore.shared.allSets.first(where: { $0.id == id })
            else { return goodChannels }
            // Intersect the set with good channels that exist in this recording.
            let setIndices = Set(set.channelIndices)
            return goodChannels.filter { setIndices.contains($0) }
        }
    }

    func artifactTemplateSelectedChannels(in signal: MFFSignalData) -> [Int] {
        switch template.channelScope {
        case .clickedChannel:
            if let clickedChannel = template.clickedChannel, signal.data.indices.contains(clickedChannel) {
                return [clickedChannel]
            }
            return []
        case .ocularChannels:
            return ocularTemplateChannels(channelCount: signal.numberOfChannels)
        case .visibleChannels:
            return signal.data.indices.filter { !channels.hidden.contains($0) }
        case .allChannels:
            return Array(signal.data.indices)
        case .specificChannels:
            return WaveformView.parseChannelList(template.customChannels, channelCount: signal.numberOfChannels)
        }
    }

    func artifactTemplateComparisonScopes(in signal: MFFSignalData) -> [ArtifactTemplateComparisonScope] {
        var scopes: [ArtifactTemplateComparisonScope] = [
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.clickedChannel.rawValue,
                channelIndices: template.clickedChannel.map { [$0] } ?? []
            ),
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.ocularChannels.rawValue,
                channelIndices: ocularTemplateChannels(channelCount: signal.numberOfChannels)
            ),
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.visibleChannels.rawValue,
                channelIndices: signal.data.indices.filter { !channels.hidden.contains($0) }
            ),
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.allChannels.rawValue,
                channelIndices: Array(signal.data.indices)
            )
        ]

        let specificChannels = WaveformView.parseChannelList(template.customChannels, channelCount: signal.numberOfChannels)
        if !specificChannels.isEmpty {
            scopes.append(
                ArtifactTemplateComparisonScope(
                    name: ArtifactTemplateChannelScope.specificChannels.rawValue,
                    channelIndices: specificChannels
                )
            )
        }

        var seen = Set<String>()
        return scopes.filter { scope in
            let key = scope.channelIndices.sorted().map(String.init).joined(separator: ",")
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    func ocularTemplateChannels(channelCount: Int) -> [Int] {
        let oneBasedChannels: [Int]
        switch channelCount {
        case 241...:
            oneBasedChannels = [18, 37, 238, 241]
        case 127...:
            oneBasedChannels = [8, 25, 126, 127]
        default:
            oneBasedChannels = Array(1...min(channelCount, 4))
        }
        return oneBasedChannels.map { $0 - 1 }.filter { $0 >= 0 && $0 < channelCount }
    }

    static func parseChannelList(_ text: String, channelCount: Int) -> [Int] {
        let separators = CharacterSet(charactersIn: ",; ").union(.newlines)
        var indices = Set<Int>()
        for rawToken in text.components(separatedBy: separators) {
            let token = rawToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-")
            guard !token.isEmpty else { continue }

            let bounds = token.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
            if bounds.count == 2 {
                let lower = min(bounds[0], bounds[1])
                let upper = max(bounds[0], bounds[1])
                for oneBased in lower...upper {
                    let zeroBased = oneBased - 1
                    if zeroBased >= 0 && zeroBased < channelCount {
                        indices.insert(zeroBased)
                    }
                }
            } else if let oneBased = Int(token) {
                let zeroBased = oneBased - 1
                if zeroBased >= 0 && zeroBased < channelCount {
                    indices.insert(zeroBased)
                }
            }
        }
        return indices.sorted()
    }

    func saveArtifactTemplateJSON(_ saved: SavedArtifactTemplate?) {
        guard let saved else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(saved.name.replacingOccurrences(of: " ", with: "-")).artifact.json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(saved)
            try data.write(to: url, options: .atomic)
            template.statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            template.statusMessage = error.localizedDescription
        }
    }


}
