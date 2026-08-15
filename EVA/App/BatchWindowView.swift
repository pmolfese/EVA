//
//  BatchWindowView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Batch's own single-instance window (REWIND.md "A significantly attractive
//  option: batch gets its own dedicated window"), opened from the Window menu
//  via `OpenBatchWindowButton`.
//
//  This is what used to be `ContentView`'s batch-related code — the setup
//  sheet, the headless progress banner, and the `.onChange(of:
//  batch.currentIndex)` that swaps in each job's file — moved here wholesale
//  rather than left shared. Windowed batch pauses for review/decision steps
//  inside the *same* `WaveformView` a manual recording window hosts
//  (`ReplayController`'s pause state lives there, gating the same sheets a
//  person would use), so this window reuses `WaveformMarkerContainer`
//  exactly like `ContentView` does — the difference is only what drives
//  `recording`: `BatchController.currentIndex` advancing through a queue,
//  instead of a person opening a file.
//
//  `batch` is this window's own `@State`, not shared with any recording
//  window — see `ContentView`'s note on its own placeholder `BatchController`
//  for why every window needs *a* controller in its environment, and why
//  only this one is ever actually driven.
//

import SwiftData
import SwiftUI

struct BatchWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var batch = BatchController()
    @State private var recording: MFFRecording?
    /// Starts true: an idle batch window's whole purpose is showing this
    /// sheet, the same way `ContentView.launchScreen` is just what an empty
    /// recording window shows.
    @State private var showsBatchSetup = true
    @State private var batchSummary: BatchController.BatchSummary?

    var body: some View {
        Group {
            if batch.isActive, !batch.isHeadlessRun, let recording {
                WaveformMarkerContainer(recording: recording)
                    .id(recording.id)
            } else if batch.isActive, batch.isHeadlessRun {
                headlessProgress
            } else {
                idlePlaceholder
            }
        }
        .environment(batch)
        .sheet(isPresented: $showsBatchSetup) {
            BatchSetupSheet(
                // Nothing to leave behind in an idle batch window — Cancel
                // closes the window itself rather than dismissing the sheet
                // onto an empty background, matching "this window's only job
                // is running a batch."
                onCancel: { dismissWindow(id: EVAApp.batchWindowID) },
                onStart: { showsBatchSetup = false }
            )
        }
        .onChange(of: batch.currentIndex) { _, idx in
            // Windowed batch drives the shown recording: swap to the current
            // job's file. Headless batch never changes currentIndex (stays
            // -1 throughout — see BatchController.startHeadless), so this
            // never fires for it; completion is picked up below instead.
            guard batch.isActive, idx >= 0, let url = batch.currentJobURL else { return }
            recording?.tearDownForClose()
            recording = MFFRecording(packageURL: url) // fresh UUID → .id() rebuilds
        }
        .onChange(of: batch.summary) { _, summary in
            if let summary { batchSummary = summary }
        }
        .alert("Batch complete", isPresented: Binding(
            get: { batchSummary != nil },
            set: { if !$0 { batchSummary = nil } }
        )) {
            Button("OK") {
                batchSummary = nil
                // Ready for another run rather than left showing the last
                // job's file with nothing to do next.
                showsBatchSetup = true
            }
        } message: {
            if let s = batchSummary {
                Text(batchSummaryMessage(s))
            }
        }
        // Closing mid-batch cancels it — decided explicitly (2026-08-15)
        // rather than left to fall out of whatever the close path happened
        // to do. No confirmation: "Stop Batch" already ends a run with none,
        // and cancelling loses no completed work — finished files are
        // already written.
        .onDisappear {
            if batch.isActive { batch.stop() }
        }
    }

    private func batchSummaryMessage(_ s: BatchController.BatchSummary) -> String {
        var lines = ["Processed \(s.done) of \(s.total)."]
        if s.needsInput > 0 {
            lines.append("\(s.needsInput) need\(s.needsInput == 1 ? "s" : "") a decision step — rerun those through a windowed batch.")
        }
        if s.skipped > 0 { lines.append("Skipped \(s.skipped).") }
        if !s.failed.isEmpty { lines.append("Failed:\n" + s.failed.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    private var idlePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
            Text("Batch Processing")
                .font(.title2.weight(.semibold))
            Text("Configure a batch in the sheet to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Progress for a headless (windowless-per-file) batch run — there's no
    /// per-file WaveformView to show progress through, since headless never
    /// touches a live view at all.
    private var headlessProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CircularStepProgressIndicator(progress: batch.currentStepProgress)
                VStack(alignment: .leading, spacing: 2) {
                    if batch.jobs.indices.contains(batch.headlessIndex) {
                        Text("File \(batch.headlessIndex + 1) of \(batch.jobs.count) · \(batch.jobs[batch.headlessIndex].name)")
                            .font(.callout.weight(.semibold))
                    }
                    Text(batch.currentStepName.isEmpty ? "Processing" : batch.currentStepName)
                        .font(.caption.weight(.semibold))
                    Text("Processing in the background — no per-file window opens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Stop Batch", role: .cancel) { batch.stop() }
            }

            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: batch.overallProgress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("Overall \(Int((batch.overallProgress * 100).rounded()))%")
                    Spacer()
                    if let progress = batch.currentStepProgress {
                        Text("Current step \(Int((progress * 100).rounded()))%")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Hosts the `UserMarker` SwiftData query, same as `ContentView`'s private
/// one — duplicated rather than shared because that one is `private` to
/// `ContentView.swift` and this window has an identical, independent need.
private struct WaveformMarkerContainer: View {
    let recording: MFFRecording
    var forkSeed: PendingWindowForks.Payload? = nil
    @Query private var markers: [UserMarker]

    var body: some View {
        WaveformView(
            recording: recording,
            userMarkers: markers
                .filter { $0.packageName == recording.packageName }
                .map {
                    WaveformUserMarkerSignature(
                        idHash: $0.persistentModelID.hashValue,
                        timeSeconds: $0.timeSeconds,
                        note: $0.note
                    )
                },
            forkSeed: forkSeed
        )
    }
}
