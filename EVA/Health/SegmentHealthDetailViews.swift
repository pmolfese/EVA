//
//  SegmentHealthDetailViews.swift
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
//  Segment health scan/details sheet and export helpers,
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI
import UniformTypeIdentifiers

extension WaveformView {
    // MARK: - Segment health

    func segmentHealthRequestID(for signal: MFFSignalData) -> String {
        [
            "\(segHealth.shows)",
            "\(segHealth.refreshRequest)",
            segmentHealthSignature(for: signal)
        ].joined(separator: "|")
    }

    func segmentHealthSignature(for signal: MFFSignalData) -> String {
        let badChannelSignature = channels.bad.sorted().map(String.init).joined(separator: ",")
        let interpolationSignature = channels.interpolated.keys.sorted().map(String.init).joined(separator: ",")
        let epochSignature = epoching.epochSegments.map(\.id).joined(separator: ",")
        let definedArtifactSignature = template.definedArtifacts.map { artifact in
            [
                artifact.id.uuidString,
                artifact.eventCode,
                "\(artifactVM.events.count)",
                "\(artifact.windowSizeSeconds)"
            ].joined(separator: ":")
        }.joined(separator: ",")
        let artifactEventSignature = artifactVM.events.map { event in
            [
                event.id,
                event.code,
                "\(event.beginTimeSeconds)"
            ].joined(separator: ":")
        }.joined(separator: ",")

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
            "\(artifactVM.cleaningIsEnabled)",
            "\(epoching.epochedSignal != nil)",
            "\(epoching.isAveraged)",
            "\(epoching.baselineCorrected)",
            "\(epoching.averageReference)",
            badChannelSignature,
            interpolationSignature,
            epochSignature,
            definedArtifactSignature,
            artifactEventSignature
        ].joined(separator: "|")
    }

    func segmentHealthInputSegments(for signal: MFFSignalData) -> [SegmentHealthInputSegment] {
        guard !epoching.isAveraged, !signal.isAveraged else { return [] }
        return SegmentHealthAnalyzer.analysisSegments(
            for: signal,
            epochSegments: epoching.epochedSignal == nil ? [] : epoching.epochSegments
        )
    }

    func segmentHealthArtifactIntervals(for signal: MFFSignalData) -> [SegmentHealthArtifactInterval] {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0 else {
            return []
        }

        let sourceWindows = segmentHealthArtifactSourceWindows()
        guard !sourceWindows.isEmpty else { return [] }

        if epoching.epochedSignal != nil, !epoching.epochSegments.isEmpty {
            return segmentHealthEpochedArtifactIntervals(
                sourceWindows: sourceWindows,
                samplingRate: signal.samplingRate,
                sampleCount: sampleCount
            )
        }

        return sourceWindows.compactMap { window in
            segmentHealthArtifactInterval(
                id: window.id,
                code: window.code,
                sourceFile: window.sourceFile,
                startSeconds: window.startSeconds,
                endSeconds: window.endSeconds,
                samplingRate: signal.samplingRate,
                sampleCount: sampleCount
            )
        }
        .sorted { $0.startSample < $1.startSample }
    }

    func segmentHealthArtifactSourceWindows() -> [(id: String, code: String, sourceFile: String, startSeconds: Double, endSeconds: Double)] {
        let defaultWindowSeconds = 0.25
        var windows: [(id: String, code: String, sourceFile: String, startSeconds: Double, endSeconds: Double)] = []
        var definedEvents = Set<MFFEvent>()

        for artifact in template.definedArtifacts {
            let windowSeconds = max(artifact.windowSizeSeconds, defaultWindowSeconds)
            for event in artifact.events {
                definedEvents.insert(event)
                let halfWindow = windowSeconds / 2
                windows.append((
                    id: "\(artifact.id.uuidString)-\(event.id)",
                    code: event.code,
                    sourceFile: artifact.name,
                    startSeconds: event.beginTimeSeconds - halfWindow,
                    endSeconds: event.beginTimeSeconds + halfWindow
                ))
            }
        }

        for event in artifactVM.events where !definedEvents.contains(event) {
            let halfWindow = defaultWindowSeconds / 2
            windows.append((
                id: event.id,
                code: event.code,
                sourceFile: event.sourceFile,
                startSeconds: event.beginTimeSeconds - halfWindow,
                endSeconds: event.beginTimeSeconds + halfWindow
            ))
        }

        return windows
    }

    func segmentHealthEpochedArtifactIntervals(
        sourceWindows: [(id: String, code: String, sourceFile: String, startSeconds: Double, endSeconds: Double)],
        samplingRate: Double,
        sampleCount: Int
    ) -> [SegmentHealthArtifactInterval] {
        var intervals: [SegmentHealthArtifactInterval] = []
        for segment in epoching.epochSegments {
            let epochStartSeconds = segment.sourceTimeSeconds - Double(segment.stimulusOffsetSamples) / samplingRate
            let epochDurationSeconds = Double(segment.endSample - segment.startSample + 1) / samplingRate
            let epochEndSeconds = epochStartSeconds + epochDurationSeconds

            for window in sourceWindows {
                let overlapStart = max(window.startSeconds, epochStartSeconds)
                let overlapEnd = min(window.endSeconds, epochEndSeconds)
                guard overlapEnd >= overlapStart else { continue }

                let displayStartSeconds = Double(segment.startSample) / samplingRate + (overlapStart - epochStartSeconds)
                let displayEndSeconds = Double(segment.startSample) / samplingRate + (overlapEnd - epochStartSeconds)
                if let interval = segmentHealthArtifactInterval(
                    id: "\(segment.id)-\(window.id)",
                    code: window.code,
                    sourceFile: window.sourceFile,
                    startSeconds: displayStartSeconds,
                    endSeconds: displayEndSeconds,
                    samplingRate: samplingRate,
                    sampleCount: sampleCount
                ) {
                    intervals.append(interval)
                }
            }
        }

        return intervals.sorted { $0.startSample < $1.startSample }
    }

    func segmentHealthArtifactInterval(
        id: String,
        code: String,
        sourceFile: String,
        startSeconds: Double,
        endSeconds: Double,
        samplingRate: Double,
        sampleCount: Int
    ) -> SegmentHealthArtifactInterval? {
        guard samplingRate > 0, sampleCount > 0 else { return nil }
        let lowerSeconds = min(startSeconds, endSeconds)
        let upperSeconds = max(startSeconds, endSeconds)
        let start = min(max(Int((lowerSeconds * samplingRate).rounded(.down)), 0), sampleCount - 1)
        let end = min(max(Int((upperSeconds * samplingRate).rounded(.up)), start), sampleCount - 1)
        guard end >= start else { return nil }
        return SegmentHealthArtifactInterval(
            artifactID: id,
            code: code,
            startSample: start,
            endSample: end,
            sourceFile: sourceFile
        )
    }

    @MainActor
    func refreshSegmentHealthIfNeeded(for signal: MFFSignalData) {
        guard !epoching.isAveraged, !signal.isAveraged else {
            segHealth.clearAnalysis(hide: true, clearLabels: false)
            return
        }
        let signature = segmentHealthSignature(for: signal)

        guard segHealth.shows else {
            segHealth.task?.cancel()
            segHealth.task = nil
            segHealth.signature = nil
            segHealth.analysis = nil
            segHealth.isAnalyzing = false
            segHealth.progress = 0
            segHealth.statusMessage = nil
            return
        }

        guard segHealth.signature != signature || segHealth.analysis?.results.isEmpty != false else {
            return
        }

        let segments = segmentHealthInputSegments(for: signal)
        guard !segments.isEmpty else {
            segHealth.analysis = nil
            segHealth.statusMessage = "No segments are available to score."
            return
        }

        segHealth.task?.cancel()
        segHealth.signature = signature
        segHealth.analysis = nil
        segHealth.isAnalyzing = true
        segHealth.progress = 0
        segHealth.statusMessage = nil

        let excludedChannels = channels.bad
        let artifactIntervals = segmentHealthArtifactIntervals(for: signal)
        let sourceSignal = signal
        let goodnessBase = segmentGoodnessSettings.base
        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            segHealth.progress = min(max(fraction, 0), 1)
        }

        segHealth.task = Task { @MainActor in
            await processingQueue.run("Segment Health") { [self] in
                let worker = Task.detached(priority: .utility) {
                    SegmentHealthAnalyzer.analyze(
                        signal: sourceSignal,
                        segments: segments,
                        excludedChannelIndices: excludedChannels,
                        artifactIntervals: artifactIntervals,
                        base: goodnessBase,
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

                guard !Task.isCancelled,
                      segHealth.shows,
                      segHealth.signature == signature else {
                    return
                }

                segHealth.analysis = analysis
                segHealth.isAnalyzing = false
                segHealth.progress = 1
                segHealth.statusMessage = analysis.results.isEmpty
                    ? "No segment health metrics available."
                    : "Segment health scored \(analysis.results.count) segments."
            }
        }
    }

    func segmentHealthDetailsSheet() -> some View {
        SegmentHealthDetailsView(
            results: segHealth.analysis?.results ?? [],
            isAnalyzing: segHealth.isAnalyzing,
            progress: segHealth.progress,
            statusMessage: segHealth.statusMessage,
            onRefresh: {
                segHealth.shows = true
                segHealth.refreshRequest += 1
            },
            onSave: {
                saveSegmentHealthMetricsJSON()
            },
            onJump: { result in
                jumpToSegment(result)
            },
            onClose: {
                segHealth.showsDetails = false
            }
        )
    }

    func saveSegmentHealthMetricsJSON() {
        guard let signal = currentSegmentHealthSignal() else {
            segHealth.statusMessage = "No signal is ready for segment-metrics export."
            return
        }

        let segments = segmentHealthInputSegments(for: signal)
        guard !segments.isEmpty else {
            segHealth.statusMessage = "No segments are available to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultSegmentHealthExportName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        segHealth.task?.cancel()
        segHealth.shows = true
        segHealth.isAnalyzing = true
        segHealth.progress = 0
        segHealth.statusMessage = "Saving segment health metrics..."

        let signature = segmentHealthSignature(for: signal)
        let reusableAnalysis = segHealth.signature == signature ? segHealth.analysis : nil
        let packageName = recording.packageName
        let processing = segmentHealthProcessingSnapshot()
        let excludedChannels = channels.bad
        let artifactIntervals = segmentHealthArtifactIntervals(for: signal)
        let goodnessBase = segmentGoodnessSettings.base

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            segHealth.progress = min(max(fraction, 0), 1)
        }

        segHealth.task = Task { @MainActor in
            await processingQueue.run("Segment Health") { [self] in
                let worker = Task.detached(priority: .utility) {
                    do {
                        let analysis: SegmentHealthAnalysis
                        if let reusableAnalysis {
                            analysis = reusableAnalysis
                            progressContinuation.yield(0.85)
                        } else {
                            analysis = SegmentHealthAnalyzer.analyze(
                                signal: signal,
                                segments: segments,
                                excludedChannelIndices: excludedChannels,
                                artifactIntervals: artifactIntervals,
                                base: goodnessBase,
                                progress: { fraction in
                                    progressContinuation.yield(0.85 * fraction)
                                }
                            )
                        }

                        let export = SavedSegmentHealthDataset.make(
                            packageName: packageName,
                            signal: signal,
                            processing: processing,
                            analysis: analysis
                        )
                        progressContinuation.yield(0.92)

                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        let data = try encoder.encode(export)
                        progressContinuation.yield(0.97)
                        try data.write(to: url, options: .atomic)
                        return Result<(Int, SegmentHealthAnalysis), Error>.success((export.segments.count, analysis))
                    } catch {
                        return Result<(Int, SegmentHealthAnalysis), Error>.failure(error)
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
                segHealth.isAnalyzing = false

                switch result {
                case .success(let payload):
                    segHealth.progress = 1
                    segHealth.signature = signature
                    segHealth.analysis = payload.1
                    segHealth.statusMessage = "Saved metrics for \(payload.0) segments: \(url.lastPathComponent)"
                case .failure(let error):
                    segHealth.progress = 0
                    segHealth.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func currentSegmentHealthSignal() -> MFFSignalData? {
        guard !epoching.isAveraged else { return nil }
        guard let rawSignal = recording.signal else { return nil }
        let base = ica.cleanedSignal ?? bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
        let preArtifact = filter.output ?? base
        let processed = artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
        let continuousSignal = applyInterpolations(to: processed)
        let signal = epoching.epochedSignal ?? continuousSignal
        return signal.isAveraged ? nil : signal
    }

    func segmentHealthProcessingSnapshot() -> SavedSegmentHealthProcessing {
        SavedSegmentHealthProcessing(
            gradientCorrected: gradient.correctedSignal != nil,
            icaCleaned: ica.cleanedSignal != nil,
            filtered: filter.output != nil,
            filterLowCutoffHz: filter.output == nil ? nil : filter.highPassCutoff,
            filterHighCutoffHz: filter.output == nil ? nil : filter.lowPassCutoff,
            notch60HzEnabled: filter.output == nil ? nil : filter.notch60HzEnabled,
            averageReferenced: filter.output == nil ? nil : filter.averageReference,
            artifactCleaned: artifactVM.cleanedSignal != nil,
            artifactCleaningVisible: artifactVM.cleanedSignal != nil && artifactVM.cleaningIsEnabled,
            epoched: epoching.epochedSignal != nil,
            psaAveraged: epoching.isAveraged,
            psaBaselineCorrected: epoching.baselineCorrected,
            psaAverageReferenced: epoching.averageReference,
            hiddenChannelIndices: channels.hidden.sorted(),
            interpolatedChannelIndices: channels.interpolated.keys.sorted(),
            markedBadChannelIndices: channels.bad.sorted()
        )
    }

    func defaultSegmentHealthExportName() -> String {
        let baseName = (recording.packageName as NSString).deletingPathExtension
        return "\(baseName)-segment-health.json"
    }

}
