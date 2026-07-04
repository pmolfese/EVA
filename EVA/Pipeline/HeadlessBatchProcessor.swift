//
//  HeadlessBatchProcessor.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
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
    /// (on full success) writes `<name>-processed.mff` into `outputFolder`.
    @MainActor
    static func process(
        url: URL,
        script: EVAProcessingScript,
        outputFolder: URL
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

        let result = await core.applyAutoSteps(script, to: signal, pnsSignal: pnsSignal)
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
        let outputURL = outputFolder.appendingPathComponent("\(baseName)-processed.mff")
        switch await MFFExportWriter.write(snapshot: snapshot, pnsSignal: pnsSignal, script: script, to: outputURL) {
        case .success:
            return .completed(outputURL)
        case .failure(let error):
            throw error
        }
    }
}
