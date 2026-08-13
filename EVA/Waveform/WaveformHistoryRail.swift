//
//  WaveformHistoryRail.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Glue between the live pipeline and the History rail: when the processing chain
//  changes, rebuild `RecordingHistoryModel`'s tree from `currentProcessingScript()`.
//
//  This is the one part of the rail that has to live on `WaveformView` — the
//  domain view models are its `@State`, and `currentProcessingScript()` already
//  reads all eight of them. The rail's *views* are standalone `Equatable` structs
//  taking values (`HistoryRailView`), per ROADMAP B5.
//
//  ## Why a signature rather than rebuilding every pass
//
//  `currentProcessingScript()` walks eight view models and formats ~40 parameter
//  strings — cheap in isolation, but ROADMAP Priority 1 is emphatic that nothing
//  new belongs on the per-body-pass path, and `WaveformView`'s body runs at
//  pointer frequency during a selection drag. So the rebuild hangs off an
//  `.onChange` of a signature made only of `Bool`s and `UUID`s: whether each
//  stage has output, and the `dataRevision` of the signals that do.
//
//  `dataRevision` is what makes this correct rather than merely cheap. Re-running
//  a stage always produces new sample data and therefore a new revision, so a
//  re-apply with *different* parameters is caught even though the signature never
//  looks at a parameter. The reverse — a parameter edited without applying —
//  correctly changes nothing, because nothing about the signal changed either.
//

import SwiftUI

extension WaveformView {

    /// Cheap identity of the processing chain: which stages are active and which
    /// exact sample data each produced. Deliberately no parameter values — see
    /// the file header.
    var processingChainSignature: String {
        [
            recording.signal?.dataRevision.uuidString ?? "none",
            gradient.correctedSignal?.dataRevision.uuidString ?? "-",
            bcg.correctedSignal?.dataRevision.uuidString ?? "-",
            ica.cleanedSignal?.dataRevision.uuidString ?? "-",
            filter.output?.dataRevision.uuidString ?? "-",
            wavelet.reducedSignal?.dataRevision.uuidString ?? "-",
            epoching.epochedSignal?.dataRevision.uuidString ?? "-",
            "\(artifactVM.isCleaningActive)\(artifactVM.cleaningIsEnabled)",
            // Threshold detection produces no signal of its own, so it needs its
            // own terms or its step would appear and disappear unnoticed.
            "\(artifactVM.detectionMethod == .threshold)",
            "\(detectsEyeBlinkArtifacts)\(detectsEyeMovementArtifacts)"
        ].joined(separator: "|")
    }

    /// Rebuilds the derived history. Safe to call redundantly: the model assigns
    /// only when the resulting tree actually differs.
    func rebuildProcessingHistory() {
        recordingStore.processingHistory.rebuild(
            recordingKey: recording.packageName,
            script: currentProcessingScript()
        )
    }

    /// Rail rows, with the root's subtitle describing the recording itself the
    /// way the figure in `REWIND.md` does: `128 ch · 1000 Hz · 21:04`.
    var historyRailNodes: [HistoryRailNode] {
        recordingStore.processingHistory.railNodes(rawSubtitle: rawRecordingSummary)
    }

    private var rawRecordingSummary: String {
        guard let signal = recording.signal else { return "not loaded" }
        var parts = ["\(signal.numberOfChannels) ch"]
        if signal.samplingRate > 0 {
            parts.append("\(Int(signal.samplingRate.rounded())) Hz")
        }
        if signal.duration > 0 {
            parts.append(Self.clockDuration(signal.duration))
        }
        return parts.joined(separator: " · ")
    }

    /// `21:04`, or `1:21:04` past an hour.
    static func clockDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
