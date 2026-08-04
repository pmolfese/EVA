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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Phase 2 of the batch roadmap (TODO.md): processes one file with NO window
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
        let (signal, pnsSignal) = try await Task.detached(priority: .userInitiated) {
            let reader = MFFReader()
            let signal = try reader.loadSignal(from: url)
            let pnsSignal = try? reader.loadPNSSignal(from: url)
            return (signal, pnsSignal)
        }.value

        let store = RecordingStore()
        let core = ProcessingCore(
            store: store,
            filter: FilterViewModel(store: store),
            gradient: GradientViewModel(store: store),
            ica: ICAViewModel(store: store),
            artifactVM: ArtifactViewModel(store: store),
            epoching: EpochingViewModel(store: store),
            wavelet: WaveletReductionViewModel(store: store)
        )

        let result = await core.applyAutoSteps(script, to: signal, pnsSignal: pnsSignal, progress: progress)
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
        switch await MFFExportWriter.write(snapshot: snapshot, pnsSignal: pnsSignal, script: script, to: outputURL) {
        case .success:
            progress?(ProcessingCore.ProgressUpdate(stepName: "Exporting", stepProgress: 1, fileProgress: 1))
            return .completed(outputURL)
        case .failure(let error):
            throw error
        }
    }
}
