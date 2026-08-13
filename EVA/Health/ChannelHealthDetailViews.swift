//
//  ChannelHealthDetailViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Channel health scan/details sheet and export helpers,
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI
import UniformTypeIdentifiers

extension WaveformView {
    // MARK: - Channel health

    func channelHealthSignature(for signal: MFFSignalData) -> String {
        // Interpolation is deliberately excluded: it changes only one channel,
        // so it does not wipe the whole health run — instead a targeted
        // recompute updates just the interpolated channel's badge.
        return [
            signal.signalURL.path,
            signal.signalType,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            "\(signal.samplingRate)",
            "\(gradient.correctedSignal != nil)",
            "\(ica.cleanedSignal != nil)",
            "\(filter.output != nil)",
            "\(artifactVM.cleanedSignal != nil)",
            "\(artifactVM.cleaningIsEnabled)"
        ].joined(separator: "|")
    }

    func channelHealthDetailsSheet(for signal: MFFSignalData) -> some View {
        @Bindable var goodnessSettings = goodnessSettings
        return ChannelHealthDetailsView(
            results: Array(channels.healthResults.values),
            isAnalyzing: channels.isAnalyzingHealth,
            progress: channels.healthProgress,
            statusMessage: chanHealth.statusMessage,
            onRefresh: {
                channels.showsHealth = true
                channels.healthRefreshToken += 1
            },
            waveletFamily: $goodnessSettings.wavelet.family,
            waveletLevelCount: $goodnessSettings.wavelet.levelCount,
            waveletThresholdModel: $goodnessSettings.wavelet.thresholdModel,
            waveletThresholdRule: $goodnessSettings.wavelet.thresholdRule,
            waveletDownsampleRate: $goodnessSettings.wavelet.downsampleRate,
            waveletCleaningMode: $goodnessSettings.wavelet.cleaningMode,
            waveletIntensity: $goodnessSettings.wavelet.intensity,
            onRunWavelets: {
                runWaveletChannelGoodness(for: signal)
            },
            onClose: {
                chanHealth.showsDetails = false
            }
        )
    }

    @MainActor
    func runWaveletChannelGoodness(for signal: MFFSignalData) {
        guard !channels.isAnalyzingHealth else { return }
        let signature = channelHealthSignature(for: signal)
        let shouldRefreshBase = chanHealth.signature != signature || channels.healthResults.isEmpty
        let existingResults = channels.healthResults
        let layout = recording.sensorLayout
        let impedances = recording.signal?.impedancesKOhm
        let baseConfig = goodnessSettings.base
        let impedanceConfig = goodnessSettings.impedance
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac
        let wavelet = goodnessSettings.wavelet
        let configuration = WaveletChannelGoodnessConfiguration(
            channelIndices: Array(signal.data.indices),
            downsampleRate: min(max(wavelet.downsampleRate, 20), signal.samplingRate),
            levelCount: wavelet.levelCount,
            thresholdScale: max(0.05, wavelet.cleaningMode.thresholdMultiplier / max(wavelet.intensity, 0.10)),
            cleaningMode: wavelet.cleaningMode,
            intensity: wavelet.intensity,
            waveletFamily: wavelet.family,
            thresholdRule: wavelet.thresholdRule,
            thresholdModel: wavelet.thresholdModel
        )

        chanHealth.task?.cancel()
        chanHealth.signature = signature
        if shouldRefreshBase {
            channels.healthResults = [:]
        }
        channels.showsHealth = true
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        chanHealth.statusMessage = "Running wavelet channel goodness..."

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        chanHealth.task = Task { @MainActor in
            await processingQueue.run("Channel Health") { [self] in
                let worker = Task.detached(priority: .utility) {
                    let baseAnalysis: ChannelHealthAnalysis
                    if shouldRefreshBase {
                        baseAnalysis = ChannelHealthAnalyzer.analyze(
                            signal: signal,
                            layout: layout,
                            base: baseConfig,
                            spectral: spectralConfig,
                            ransac: ransacConfig,
                            impedance: impedanceConfig,
                            impedancesKOhm: impedances,
                            progress: { fraction in
                                progressContinuation.yield(0.42 * fraction)
                            }
                        )
                    } else {
                        progressContinuation.yield(0.08)
                        baseAnalysis = ChannelHealthAnalysis(resultsByChannel: existingResults)
                    }

                    let waveletStart = shouldRefreshBase ? 0.42 : 0.08
                    let waveletSpan = shouldRefreshBase ? 0.55 : 0.89
                    let waveletResults = WaveletArtifactAnalyzer.channelGoodness(
                        in: signal,
                        configuration: configuration
                    ) { update in
                        progressContinuation.yield(waveletStart + waveletSpan * update.fraction)
                    }
                    progressContinuation.yield(0.98)
                    return ChannelHealthAnalyzer.addingWaveletMetrics(
                        to: baseAnalysis,
                        waveletResults: waveletResults,
                        weight: wavelet.weight
                    )
                }

                let analysis = await withTaskCancellationHandler(
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

                // Clear the spinner *before* the publish guard, not after: a
                // scan that is cancelled, superseded, or whose results are no
                // longer wanted still has to release `isAnalyzing`. Clearing it
                // only on the success path left the progress row stuck on.
                channels.isAnalyzingHealth = false

                guard !Task.isCancelled,
                      channels.showsHealth,
                      chanHealth.signature == signature else {
                    return
                }

                channels.healthResults = analysis.resultsByChannel
                channels.healthProgress = 1
                chanHealth.statusMessage = analysis.resultsByChannel.isEmpty
                    ? "No wavelet channel-goodness metrics available."
                    : "Wavelet channel goodness updated \(analysis.resultsByChannel.count) channels."
            }
        }
    }

    /// The continuous (non-epoched) processed signal the health badges score,
    /// mirroring the `body` pipeline so a badge tap can run health from any row
    /// (rows only carry the possibly-epoched display signal). `nil` pre-load.
    var continuousProcessedSignal: MFFSignalData? {
        guard let rawSignal = recording.signal else { return nil }
        let base = ica.cleanedSignal ?? bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
        let preArtifact = filter.output ?? base
        let processed = artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
        let waveletStage = wavelet.isEnabled ? (wavelet.reducedSignal ?? processed) : processed
        return applyInterpolations(to: waveletStage)
    }

    /// Resets the channel-health badges to their empty state after a major
    /// processing change. Does not auto-run; the user taps a badge to re-run.
    @MainActor
    func resetChannelHealthForStateChange() {
        chanHealth.task?.cancel()
        chanHealth.task = nil
        chanHealth.signature = nil
        channels.clearHealthResults()
        channels.showsHealth = false
        chanHealth.statusMessage = nil
    }

    /// Runs channel health for the first time in the current state (tap a badge
    /// or the menu). No-ops if a scan is running or results already exist for
    /// this exact state; pass `force` to recompute regardless.
    @MainActor
    func runChannelHealthOnDemand(for signal: MFFSignalData, force: Bool = false) {
        guard !channels.isAnalyzingHealth else { return }
        let signature = channelHealthSignature(for: signal)
        if !force, !channels.healthResults.isEmpty, chanHealth.signature == signature {
            return
        }
        channels.showsHealth = true
        startChannelHealthScan(for: signal, signature: signature)
    }

    /// Updates channel health after an interpolation change, touching only the
    /// affected channels' badges and leaving every other result in place.
    /// No-ops if health hasn't been run yet or a scan is already going.
    ///
    /// Newly interpolated channels can be estimated cheaply by averaging their
    /// spline-contributing channels (a Preferences toggle) — good for modest
    /// hardware. Un-interpolated channels (now back to real data) always need a
    /// real analysis, as does the estimate's fallback.
    @MainActor
    func recomputeChannelHealthForInterpolation(oldKeys: [Int], newKeys: [Int], signal: MFFSignalData) {
        guard !channels.healthResults.isEmpty, !channels.isAnalyzingHealth else { return }
        let added = Set(newKeys).subtracting(oldKeys)
        let removed = Set(oldKeys).subtracting(newKeys)
        guard !added.isEmpty || !removed.isEmpty else { return }

        // Removals revert to real data, so they always need a real analysis.
        var needsFullAnalysis = removed

        if ProcessingDefaults.shared.interpolatedHealthFromNeighbors {
            for channel in added {
                if let estimate = averagedNeighborHealth(for: channel) {
                    channels.healthResults[channel] = estimate
                } else {
                    needsFullAnalysis.insert(channel) // no contributors with scores yet
                }
            }
        } else {
            needsFullAnalysis.formUnion(added)
        }

        guard !needsFullAnalysis.isEmpty else { return }

        let affected = needsFullAnalysis
        let layout = recording.sensorLayout
        let impedances = recording.signal?.impedancesKOhm
        let baseConfig = goodnessSettings.base
        let impedanceConfig = goodnessSettings.impedance
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac
        let sourceSignal = signal
        let sessionID = recordingSessionID

        chanHealth.task?.cancel()
        chanHealth.task = Task { @MainActor in
            await processingQueue.run("Channel Health") { [self] in
                let worker = Task.detached(priority: .utility) {
                    ChannelHealthAnalyzer.analyze(
                        signal: sourceSignal,
                        layout: layout,
                        base: baseConfig,
                        spectral: spectralConfig,
                        ransac: ransacConfig,
                        impedance: impedanceConfig,
                        impedancesKOhm: impedances
                    )
                }
                let analysis = await withTaskCancellationHandler(
                    operation: {
                        await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )

                guard !Task.isCancelled, sessionID == recordingSessionID else { return }
                for channel in affected {
                    channels.healthResults[channel] = analysis.resultsByChannel[channel]
                }
                chanHealth.task = nil
            }
        }
    }

    /// Estimates an interpolated channel's health as the spline-weighted average
    /// of its contributing channels' goodness. Returns `nil` when the channel
    /// has no recorded contributors, or none of them have a health score yet
    /// (caller then falls back to a real analysis).
    @MainActor
    func averagedNeighborHealth(for channel: Int) -> ChannelHealthResult? {
        guard let source = channels.interpolationSources[channel] else { return nil }

        var weightedGood = 0.0
        var weightTotal = 0.0
        var count = 0
        for (contributor, weight) in zip(source.indices, source.weights) {
            guard let result = channels.healthResults[contributor] else { continue }
            let w = Double(abs(weight))
            weightedGood += w * Double(result.goodPercentage)
            weightTotal += w
            count += 1
        }
        guard weightTotal > 0, count > 0 else { return nil }

        let good = Int((weightedGood / weightTotal).rounded())
        return ChannelHealthResult(
            channelIndex: channel,
            goodPercentage: good,
            grade: HealthScoring.grade(for: Double(good) / 100),
            summary: "Estimated from \(count) contributing channel\(count == 1 ? "" : "s") (interpolated).",
            metrics: []
        )
    }

    @MainActor
    func startChannelHealthScan(for signal: MFFSignalData, signature: String) {
        chanHealth.task?.cancel()
        chanHealth.signature = signature
        channels.healthResults = [:]
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        chanHealth.statusMessage = nil

        let layout = recording.sensorLayout
        let sourceSignal = signal
        let impedances = recording.signal?.impedancesKOhm
        let baseConfig = goodnessSettings.base
        let impedanceConfig = goodnessSettings.impedance
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac
        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        chanHealth.task = Task { @MainActor in
            await processingQueue.run("Channel Health") { [self] in
                let worker = Task.detached(priority: .utility) {
                    ChannelHealthAnalyzer.analyze(
                        signal: sourceSignal,
                        layout: layout,
                        base: baseConfig,
                        spectral: spectralConfig,
                        ransac: ransacConfig,
                        impedance: impedanceConfig,
                        impedancesKOhm: impedances,
                        progress: { fraction in
                            progressContinuation.yield(fraction)
                        }
                    )
                }

                let analysis = await withTaskCancellationHandler(
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

                // Clear the spinner *before* the publish guard, not after: a
                // scan that is cancelled, superseded, or whose results are no
                // longer wanted still has to release `isAnalyzing`. Clearing it
                // only on the success path left the progress row stuck on.
                channels.isAnalyzingHealth = false

                guard !Task.isCancelled,
                      channels.showsHealth,
                      chanHealth.signature == signature else {
                    return
                }

                channels.healthResults = analysis.resultsByChannel
                channels.healthProgress = 1
                chanHealth.statusMessage = analysis.resultsByChannel.isEmpty
                    ? "No channel health metrics available."
                    : "Channel health scored \(analysis.resultsByChannel.count) channels."
            }
        }
    }

    func saveChannelLabelMetricsJSON() {
        guard !channels.bad.isEmpty else {
            chanHealth.statusMessage = "Mark at least one bad channel before saving labels."
            return
        }
        guard let signal = currentChannelLabelMetricsSignal() else {
            chanHealth.statusMessage = "No signal is ready for channel-label export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultChannelLabelMetricsExportName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        chanHealth.task?.cancel()
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        chanHealth.statusMessage = "Saving channel label metrics..."

        let packageName = recording.packageName
        let layout = recording.sensorLayout
        let impedances = recording.signal?.impedancesKOhm
        let processing = channelHealthProcessingSnapshot()
        let hiddenChannels = channels.hidden
        let baseConfig = goodnessSettings.base
        let impedanceConfig = goodnessSettings.impedance
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        chanHealth.task = Task { @MainActor in
            await processingQueue.run("Channel Health") { [self] in
                let worker = Task.detached(priority: .utility) {
                    do {
                        let analysis = ChannelHealthAnalyzer.analyze(
                            signal: signal,
                            layout: layout,
                            base: baseConfig,
                            spectral: spectralConfig,
                            ransac: ransacConfig,
                            impedance: impedanceConfig,
                            impedancesKOhm: impedances,
                            progress: { fraction in
                                progressContinuation.yield(0.85 * fraction)
                            }
                        )
                        let export = SavedChannelHealthDataset.make(
                            packageName: packageName,
                            signal: signal,
                            processing: processing,
                            hiddenChannelIndices: hiddenChannels,
                            analysis: analysis
                        )
                        progressContinuation.yield(0.92)

                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        let data = try encoder.encode(export)
                        progressContinuation.yield(0.97)
                        try data.write(to: url, options: .atomic)
                        return Result<Int, Error>.success(export.channels.count)
                    } catch {
                        return Result<Int, Error>.failure(error)
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

                progressContinuation.finish()
                progressTask.cancel()
                channels.isAnalyzingHealth = false

                switch result {
                case .success(let channelCount):
                    channels.healthProgress = 1
                    chanHealth.statusMessage = "Saved labels and metrics for \(channelCount) channels: \(url.lastPathComponent)"
                case .failure(let error):
                    channels.healthProgress = 0
                    chanHealth.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func currentChannelLabelMetricsSignal() -> MFFSignalData? {
        guard let rawSignal = recording.signal else { return nil }
        let base = ica.cleanedSignal ?? bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
        let preArtifact = filter.output ?? base
        return artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
    }

    func channelHealthProcessingSnapshot() -> SavedChannelHealthProcessing {
        SavedChannelHealthProcessing(
            gradientCorrected: gradient.correctedSignal != nil,
            icaCleaned: ica.cleanedSignal != nil,
            filtered: filter.output != nil,
            filterLowCutoffHz: filter.output == nil ? nil : filter.highPassCutoff,
            filterHighCutoffHz: filter.output == nil ? nil : filter.lowPassCutoff,
            notch60HzEnabled: filter.output == nil ? nil : filter.notch60HzEnabled,
            averageReferenced: filter.output == nil ? nil : filter.averageReference,
            artifactCleaned: artifactVM.cleanedSignal != nil,
            artifactCleaningVisible: artifactVM.cleanedSignal != nil && artifactVM.cleaningIsEnabled,
            interpolatedChannelIndices: channels.interpolated.keys.sorted(),
            markedBadChannelIndices: channels.bad.sorted()
        )
    }

    func defaultChannelLabelMetricsExportName() -> String {
        let baseName = (recording.packageName as NSString).deletingPathExtension
        return "\(baseName)-channel-labels.json"
    }

}
