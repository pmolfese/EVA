//
//  HeadlessBatchProcessor.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Phase 2 of the batch roadmap (ROADMAP.md): processes one file with NO window
//  at all — load → ProcessingCore.applyAutoSteps → write output. Used when a
//  batch's configured script has no decision steps (ICA / drawn artifact
//  cleaning), so there's nothing a human needs to see. Builds a fresh
//  RecordingStore + VM set per file (mirroring WaveformView's own
//  construction) purely as ProcessingCore's collaborators — nothing here is
//  ever attached to a live view.
//

import Foundation

enum HeadlessBatchProcessor {
    enum Outcome {
        /// Fully processed and written to `url`.
        case completed(URL)
        /// The script wasn't fully headless-capable for this file (shouldn't
        /// happen if the caller pre-checked with `EVAProcessingScript.isFullyHeadlessCapable`,
        /// but a per-file event count/layout mismatch can still surface here) —
        /// caller should route this file to windowed Phase-1 batch instead.
        case needsInput
    }

    /// Loads `url`, applies `script`'s steps via a fresh `ProcessingCore`, and
    /// writes an output named for the final export kind into `outputFolder`.
    @MainActor
    static func process(
        url: URL,
        script: EVAProcessingScript,
        outputFolder: URL,
        progress: ((ProcessingCore.ProgressUpdate) -> Void)? = nil
    ) async throws -> Outcome {
        let (signal, pnsSignal, geometry) = try await Task.detached(priority: .userInitiated) {
            let reader = MFFReader()
            let signal = try reader.loadSignal(from: url)
            let pnsSignal = try? reader.loadPNSSignal(from: url)
            // Without this the headless PSA cannot interpolate per-epoch bad
            // channels or escalate persistently-bad ones, so it produced
            // measurably different averages from the interactive path.
            let geometry = ElectrodeGeometry.load(fromPackageContaining: signal.signalURL)
            return (signal, pnsSignal, geometry)
        }.value

        let store = RecordingStore()
        let core = ProcessingCore(
            store: store,
            filter: FilterViewModel(store: store),
            gradient: GradientViewModel(store: store),
            ica: ICAViewModel(store: store),
            artifactVM: ArtifactViewModel(store: store),
            epoching: EpochingViewModel(store: store),
            wavelet: WaveletReductionViewModel(store: store),
            template: ArtifactTemplateViewModel(store: store),
            segHealth: SegmentHealthViewModel(store: store),
            electrodePositions: geometry?.positions ?? [:]
        )

        // **This file's own** ICA operator, not the script source's. Read from
        // the input package, so re-processing a package EVA already ran ICA on
        // re-applies that recording's recorded removal, while a script copied
        // from another subject finds no sidecar and `ProcessingCore` stops at
        // `icaClean` as before. Carrying one subject's unmixing matrix onto
        // another's electrodes would produce plausible, wrong data.
        let icaPayload = ICAReplayPayload.read(fromPackage: url)
        // Likewise this file's own drawn artifacts. A template is a waveform
        // traced on one subject's blink; re-applying it to another's would be
        // plausible and wrong.
        let artifactPayload = ArtifactReplayPayload.read(fromPackage: url)

        let result = await core.applyAutoSteps(
            script, to: signal, pnsSignal: pnsSignal,
            icaPayload: icaPayload, artifactPayload: artifactPayload, progress: progress
        )
        guard result.remainingSteps.isEmpty, let output = result.signal else {
            return .needsInput
        }

        let snapshot: MFFExportSnapshot
        if let epoched = core.epoching.epochedSignal, !core.epoching.epochSegments.isEmpty {
            snapshot = MFFExportSnapshot(
                signal: epoched,
                segments: core.epoching.epochSegments,
                kind: core.epoching.isAveraged ? .averaged : .epoched
            )
        } else {
            snapshot = MFFExportSnapshot(signal: output, segments: [], kind: .continuous)
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let outputURL = outputFolder.appendingPathComponent("\(baseName)-\(snapshot.kind.replayOutputSuffix).mff")
        progress?(ProcessingCore.ProgressUpdate(stepName: "Exporting", stepProgress: nil, fileProgress: 0.95))
        // Same provenance the interactive export writes. Omitting it here meant a
        // batch-produced package silently lacked every "result" line — bad
        // channels, escalated/interpolated channels, per-category SNR.
        let auditLogLines = ProcessingAuditLog.lines(
            gradient: core.gradient,
            epoching: core.epoching,
            channels: store.channels,
            cleaningVariance: store.cleaningVariance
        )
        // The script written out is the one handed in *plus* the channel
        // decisions this run made — PSA's globally-bad escalation can mark and
        // interpolate channels the input script never mentioned. Writing the
        // input script verbatim would describe a run that did not happen. Same
        // shared definition the interactive path uses.
        let outgoingScript = ChannelDecisionSteps.inserted(
            into: script,
            badChannels: store.channels.bad,
            interpolatedChannels: Set(store.channels.interpolated.keys)
        )
        switch await MFFExportWriter.write(
            snapshot: snapshot,
            pnsSignal: pnsSignal,
            script: outgoingScript,
            to: outputURL,
            auditLogLines: auditLogLines,
            // Carry the operator forward, so the output package is re-processable
            // on the same terms its input was.
            icaPayload: core.ica.cleanedSignal != nil ? icaPayload : nil,
            artifactPayload: core.artifactVM.cleanedSignal != nil ? artifactPayload : nil
        ) {
        case .success:
            progress?(ProcessingCore.ProgressUpdate(stepName: "Exporting", stepProgress: 1, fileProgress: 1))
            return .completed(outputURL)
        case .failure(let error):
            throw error
        }
    }
}
