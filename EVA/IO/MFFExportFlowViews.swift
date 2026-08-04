//
//  MFFExportFlowViews.swift
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
//  Copy-processing (eva.xml replay import) and the MFF export flow,
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI
import UniformTypeIdentifiers

extension WaveformView {
    // MARK: - Copy processing (eva.xml replay)

    /// Reads another recording's `eva.xml` and replays its replayable steps onto
    /// the current recording. First slice applies the filter step; other stages
    /// are captured but skipped until their round-trip lands.
    func importProcessingFromOtherFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mff, .xml]
        panel.canChooseDirectories = true // MFF is a directory package
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Copy Processing"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Accept either an MFF package (reads its eva.xml) or a standalone eva.xml.
        guard let script = EVAProcessingScriptXML.read(fromFile: url) else {
            filter.statusMessage = "No eva.xml found in \(url.lastPathComponent)."
            filter.statusIsError = true
            return
        }

        // Present the config pane; the user reviews steps and clicks Start, which
        // launches `interactiveReplay()` via `startInteractiveReplay()`. Passing
        // the CURRENT recording's signal runs the compatibility pre-flight
        // against the file this script is about to be replayed onto.
        replay.configure(script: script, sourceName: url.lastPathComponent, signal: recording.signal)
    }

    // MARK: - MFF export

    func exportCurrentSignalToMFF() {
        guard !isExportingMFF else { return }
        guard let snapshot = currentMFFExportSnapshot() else {
            mffExportStatusMessage = "No signal is ready to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mff]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultMFFExportName(for: snapshot.kind)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pnsForExport = pnsSignalForMFFExport()

        isExportingMFF = true
        mffExportStatusMessage = "Exporting \(snapshot.kind.statusName) MFF..."

        // Capture the active processing pipeline for eva.xml + the process log.
        let processingScript = currentProcessingScript()
        let auditLogLines = currentProcessingAuditLogLines()

        mffExportTask?.cancel()
        let sessionID = recordingSessionID
        mffExportTask = Task {
            let result = await performMFFExport(
                snapshot: snapshot,
                pnsForExport: pnsForExport,
                script: processingScript,
                to: url,
                auditLogLines: auditLogLines
            )
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            isExportingMFF = false
            switch result {
            case .success(let outputURL):
                mffExportStatusMessage = "Exported \(snapshot.kind.statusName) MFF: \(outputURL.lastPathComponent)"
            case .failure(let error):
                mffExportStatusMessage = error.localizedDescription
            }
            mffExportTask = nil
        }
    }

    /// Panel-free MFF export — the core shared by the interactive Save panel,
    /// replay finish-and-export, and the headless batch processor. Thin
    /// forward to `MFFExportWriter`, the view-independent implementation.
    @MainActor
    func performMFFExport(
        snapshot: MFFExportSnapshot,
        pnsForExport: MFFSignalData?,
        script: EVAProcessingScript,
        to url: URL,
        auditLogLines: [String] = []
    ) async -> Result<URL, Error> {
        await MFFExportWriter.write(
            snapshot: snapshot,
            pnsSignal: pnsForExport,
            script: script,
            to: url,
            auditLogLines: auditLogLines
        )
    }

    func pnsSignalForMFFExport() -> MFFSignalData? {
        let renamedPNS = pnsSignalWithRenames()
        guard shouldIncludeSyntheticPNSChannelsInExport() else { return renamedPNS }
        return mergingWithSynthetic(base: renamedPNS)
    }

    func shouldIncludeSyntheticPNSChannelsInExport() -> Bool {
        guard !syntheticPNSChannels.isEmpty else { return false }
        let alert = NSAlert()
        alert.messageText = "Include synthesized ICA channels?"
        let names = syntheticPNSChannels.map(\.name).joined(separator: ", ")
        alert.informativeText = "The following synthetic PNS channels were created from ICA components: \(names). Include them in the exported MFF?"
        alert.addButton(withTitle: "Include")
        alert.addButton(withTitle: "Skip")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func splitCurrentFile(_ selection: MFFSplitSelection, atSample sample: Int) {
        guard !isExportingMFF else { return }
        guard let snapshot = currentMFFExportSnapshot() else {
            mffExportStatusMessage = "No signal is ready to split."
            return
        }

        let split: MFFSignalSplitPair
        do {
            split = try MFFSignalSplitter.split(signal: snapshot.signal, atSample: sample)
        } catch {
            mffExportStatusMessage = error.localizedDescription
            return
        }

        let splitTime = split.left.endTimeSeconds
        let outputs: [MFFSplitOutput]
        switch selection {
        case .left:
            guard let url = splitSaveURL(defaultName: defaultMFFSplitName(side: .left, splitTime: splitTime)) else { return }
            outputs = [MFFSplitOutput(segment: split.left, url: normalizedMFFPackageURL(url))]
        case .right:
            guard let url = splitSaveURL(defaultName: defaultMFFSplitName(side: .right, splitTime: splitTime)) else { return }
            outputs = [MFFSplitOutput(segment: split.right, url: normalizedMFFPackageURL(url))]
        case .both:
            guard let leftURL = splitSaveURL(
                defaultName: defaultMFFSplitName(side: .left, splitTime: splitTime),
                message: "Choose the left-segment file. Eva will create the matching right-segment file beside it."
            ) else { return }
            let pairURLs = splitPairURLs(fromLeftURL: leftURL)
            guard confirmReplacingGeneratedSplitFiles([pairURLs.right]) else { return }
            outputs = [
                MFFSplitOutput(segment: split.left, url: pairURLs.left),
                MFFSplitOutput(segment: split.right, url: pairURLs.right)
            ]
        }

        let pnsForExport = pnsSignalForMFFExport()
        let processingScript = currentProcessingScript()
        let auditLogLines = currentProcessingAuditLogLines()
        isExportingMFF = true
        mffExportStatusMessage = "Splitting MFF at \(formattedEventTime(splitTime))..."

        mffExportTask?.cancel()
        let sessionID = recordingSessionID
        mffExportTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    for output in outputs {
                        let pnsSlice = try pnsForExport.map {
                            try MFFSignalSplitter.slice(
                                signal: $0,
                                startTimeSeconds: output.segment.startTimeSeconds,
                                endTimeSeconds: output.segment.endTimeSeconds,
                                side: output.segment.side
                            ).signal
                        }
                        try MFFWriter.write(
                            signal: output.segment.signal,
                            pnsSignal: pnsSlice,
                            segments: [],
                            kind: .continuous,
                            to: output.url,
                            preserveSourceFileInfo: false
                        )

                        var script = processingScript
                        script.append(EVAProcessingStep(
                            operation: .split,
                            parameters: [
                                "side": output.segment.side.rawValue,
                                "startSeconds": String(format: "%.6f", output.segment.startTimeSeconds),
                                "endSeconds": String(format: "%.6f", output.segment.endTimeSeconds),
                                "boundarySample": "\(split.boundarySample)"
                            ],
                            replayable: false,
                            note: "Created by right-click Split File export."
                        ))
                        try? EVAProcessingScriptXML.write(script, toPackage: output.url)

                        let log = EVAProcessLog(header: "EVA split export — \(output.url.lastPathComponent)")
                        for step in script.steps {
                            let params = step.parameters.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                            log.append("\(step.operation.rawValue)\(params.isEmpty ? "" : ": \(params)")")
                        }
                        for line in auditLogLines {
                            log.append(line)
                        }
                        try? log.write(toPackage: output.url)
                        try Task.checkCancellation()
                    }
                    return Result<[URL], Error>.success(outputs.map(\.url))
                } catch {
                    return Result<[URL], Error>.failure(error)
                }
            }
            let result = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            await MainActor.run {
                isExportingMFF = false
                switch result {
                case .success(let urls):
                    let names = urls.map(\.lastPathComponent).joined(separator: ", ")
                    mffExportStatusMessage = "Exported split MFF\(urls.count == 1 ? "" : "s"): \(names)"
                case .failure(let error):
                    mffExportStatusMessage = error.localizedDescription
                }
            }
            mffExportTask = nil
        }
    }

    func splitSaveURL(defaultName: String, message: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mff]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultName
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    func defaultMFFSplitName(side: MFFSignalSplitSide, splitTime: Double) -> String {
        let baseName = (recording.packageName as NSString).deletingPathExtension
        let time = splitTimeFilenameComponent(splitTime)
        return "\(baseName)-\(side.rawValue)-\(time).mff"
    }

    func splitPairURLs(fromLeftURL leftURL: URL) -> (left: URL, right: URL) {
        let left = normalizedMFFPackageURL(leftURL)
        let directory = left.deletingLastPathComponent()
        let baseName = (left.lastPathComponent as NSString).deletingPathExtension
        let rightBaseName: String
        if let range = baseName.range(of: "-left-", options: .backwards) {
            rightBaseName = baseName.replacingCharacters(in: range, with: "-right-")
        } else if baseName.hasSuffix("-left") {
            rightBaseName = String(baseName.dropLast("-left".count)) + "-right"
        } else {
            rightBaseName = "\(baseName)-right"
        }
        let right = directory.appendingPathComponent(rightBaseName).appendingPathExtension("mff")
        return (left, right)
    }

    func confirmReplacingGeneratedSplitFiles(_ urls: [URL]) -> Bool {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = existing.count == 1 ? "Replace existing split file?" : "Replace existing split files?"
        alert.informativeText = existing.map(\.lastPathComponent).joined(separator: ", ")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func splitTimeFilenameComponent(_ seconds: Double) -> String {
        String(format: "%.3fs", seconds).replacingOccurrences(of: ".", with: "p")
    }

    /// Returns the real PNS signal with any user renames applied to channel names.
    /// Returns nil when there is no real PNS signal.
    func pnsSignalWithRenames() -> MFFSignalData? {
        guard let pns = recording.pnsSignal else { return nil }
        guard !physioChannelRenames.isEmpty else { return pns }
        var names = pns.channelNames ?? (0..<pns.numberOfChannels).map { "PNS \($0 + 1)" }
        for (index, rename) in physioChannelRenames where index < names.count {
            names[index] = rename
        }
        return MFFSignalData(
            signalURL: pns.signalURL,
            signalType: pns.signalType,
            numberOfChannels: pns.numberOfChannels,
            samplingRate: pns.samplingRate,
            duration: pns.duration,
            recordingStartTime: pns.recordingStartTime,
            events: pns.events,
            data: pns.data,
            channelNames: names
        )
    }

    /// Builds a declarative processing record (eva.xml) from the active
    /// pipeline state, so exported packages document how EVA transformed them.
    /// Captures the current processing as a replayable script. Steps are emitted
    /// in canonical chain order (matching `body`: gradient → BCG → ica → filter →
    /// artifact → wavelet → segment) so that replaying them in order reproduces
    /// the portable processing state. Subject-specific outcomes such as the
    /// exact interpolated/bad channel lists go to `currentProcessingAuditLogLines()`.
    /// Keep this order in sync with `body` and `replay(_:)`.
    func currentProcessingScript() -> EVAProcessingScript {
        var script = EVAProcessingScript()

        if gradient.correctedSignal != nil {
            script.append(EVAProcessingStep(operation: .mriGradientCorrection, parameters: gradient.parameters))
        }
        if bcg.correctedSignal != nil {
            script.append(EVAProcessingStep(
                operation: .bcgDetection,
                parameters: bcg.parameters,
                replayable: false,
                note: "BCG/CWL correction is subject-specific; parameters are recorded for provenance."
            ))
        }
        if ica.cleanedSignal != nil {
            script.append(EVAProcessingStep(
                operation: .icaClean,
                parameters: ["averageReference": "\(ica.usesAverageReference)"],
                replayable: false,
                note: "ICA settings are portable; removed component indices are subject-specific."
            ))
        }
        if filter.output != nil {
            script.append(EVAProcessingStep(operation: .filter, parameters: filter.parameters))
        }
        if artifactVM.isCleaningActive, artifactVM.cleaningIsEnabled {
            // Artifact cleaning is defined per-subject (drawn templates / events),
            // so it is provenance-only, not replayable.
            script.append(EVAProcessingStep(
                operation: .artifactClean,
                parameters: artifactCleaningParameters(),
                replayable: false,
                note: "Artifact definitions (templates/events) are subject-specific."
            ))
        }
        if wavelet.isActive {
            script.append(EVAProcessingStep(operation: .waveletReduce, parameters: wavelet.parameters))
        }
        // Threshold-based ocular detection is fully parameterized (no drawn
        // templates), so it is portable and replayable.
        if artifactVM.detectionMethod == .threshold, detectsEyeBlinkArtifacts || detectsEyeMovementArtifacts {
            var p: [String: String] = [
                "eyeBlink": "\(detectsEyeBlinkArtifacts)",
                "eyeMovement": "\(detectsEyeMovementArtifacts)"
            ]
            // Flat, readable params (one <param> per field) rather than a JSON blob.
            p.merge(artifactVM.blinkThresholdConfig.flatParameters(prefix: "blink")) { a, _ in a }
            p.merge(artifactVM.movementThresholdConfig.flatParameters(prefix: "movement")) { a, _ in a }
            script.append(EVAProcessingStep(operation: .thresholdArtifactDetection, parameters: p))
        }
        // PSA: segment (+ optional baseline / average) is portable when the target
        // has the same event codes. Replayable.
        if epoching.epochedSignal != nil, !epoching.selectedEventCodes.isEmpty {
            script.append(EVAProcessingStep(operation: .segment, parameters: epoching.parameters))
        }
        return script
    }

    func artifactCleaningParameters() -> [String: String] {
        var params: [String: String] = [
            "artifactCount": "\(template.definedArtifacts.count)",
            "cleaningEnabled": "\(artifactVM.cleaningIsEnabled)"
        ]
        for (offset, artifact) in template.definedArtifacts.enumerated() {
            params.merge(artifact.processingParameters(prefix: "artifact\(offset + 1)")) { current, _ in current }
        }
        return params
    }

    /// Subject-specific export audit details for `log_eva_*.txt`. These are not
    /// part of `eva.xml` because Copy Processing should replay the portable
    /// settings, not this file's resulting channel/epoch decisions.
    func currentProcessingAuditLogLines() -> [String] {
        var lines: [String] = []
        if !epoching.skippedLabeledBadSegmentsSummary.isEmpty {
            lines.append("segment result: skippedLabeledBadSegments=\(epoching.skippedLabeledBadSegmentsSummary.joined(separator: "; "))")
        }
        if !epoching.epochBadChannelSummary.isEmpty {
            lines.append("segment result: perEpochBadChannels=\(epoching.epochBadChannelSummary.joined(separator: "; "))")
        }
        if !epoching.epochBadChannelAllSegmentsSummary.isEmpty {
            lines.append("segment result: badChannelsInAllKeptSegments=\(epoching.epochBadChannelAllSegmentsSummary.joined(separator: ", "))")
        }
        if !channels.interpolated.isEmpty {
            var fields = [
                "channels=\(channels.interpolated.keys.sorted().map { String($0 + 1) }.joined(separator: ","))"
            ]
            if !epoching.escalatedChannelSummaries.isEmpty {
                fields.append("escalatedFromPerEpochDetection=\(epoching.escalatedChannelSummaries.joined(separator: "; "))")
            }
            lines.append("interpolateChannels result: \(fields.joined(separator: ", "))")
        }
        if !channels.bad.isEmpty {
            lines.append("markBad result: channels=\(channels.bad.sorted().map { String($0 + 1) }.joined(separator: ","))")
        }
        for category in epoching.averageSNRByCategory.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let m = epoching.averageSNRByCategory[category] ?? SNRMetrics()
            func f(_ v: Double?, _ digits: Int = 2) -> String {
                guard let v, v.isFinite else { return "n/a" }
                return String(format: "%.\(digits)f", v)
            }
            lines.append(
                "average SNR [\(category)]: trials=\(m.trialCount), plusMinusSNR=\(f(m.plusMinusSNR)), baselineSNR=\(f(m.baselineSNR)), gfpSNR=\(f(m.gfpSNR)), sme=\(f(m.standardizedMeasurementError, 3)), splitHalfReliability=\(f(m.splitHalfReliability))"
            )
        }
        return lines
    }

    func currentMFFExportSnapshot() -> MFFExportSnapshot? {
        guard let rawSignal = recording.signal else { return nil }

        let base = ica.cleanedSignal ?? bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
        let preArtifact = filter.output ?? base
        let processed = artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
        let continuousSignal = applyInterpolations(to: processed)

        if let epochedSig = epoching.epochedSignal, !epoching.epochSegments.isEmpty {
            return MFFExportSnapshot(
                signal: epochedSig,
                segments: epoching.epochSegments,
                kind: epoching.isAveraged ? .averaged : .epoched
            )
        }

        return MFFExportSnapshot(signal: continuousSignal, segments: [], kind: .continuous)
    }

    func defaultMFFExportName(for kind: MFFExportKind) -> String {
        let baseName = (recording.packageName as NSString).deletingPathExtension
        let suffix: String
        switch kind {
        case .continuous:
            suffix = "processed"
        case .epoched:
            suffix = "epochs"
        case .averaged:
            suffix = "averages"
        }
        return "\(baseName)-\(suffix).mff"
    }

}
