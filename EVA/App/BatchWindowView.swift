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
//  `batch` is owned by `EVAApp`, not this view, and injected at the `Window`
//  scene's own definition — see the doc comment on `EVAApp.batchController`
//  for why (a sheet shown on this view's first appearance would not reliably
//  see an `.environment(_:)` attached inside the body instead). Still not
//  shared with any recording window — see `ContentView`'s note on its own
//  placeholder `BatchController` for why every window needs *a* controller in
//  its environment, and why only this one is ever actually driven.
//

import AppKit
import SwiftData
import SwiftUI

struct BatchWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(BatchController.self) private var batch

    @State private var recording: MFFRecording?
    /// Starts true: an idle batch window's whole purpose is showing this
    /// sheet, the same way `ContentView.launchScreen` is just what an empty
    /// recording window shows.
    ///
    /// That initial value only fires once, though — `Window` (unlike
    /// `WindowGroup`) is a singleton scene whose SwiftUI `@State` survives
    /// the window being closed and reopened, it doesn't get torn down and
    /// recreated. Cancel sets this to `false` before closing the window
    /// (see below), and without the `onAppear` reset that `false` was still
    /// sitting there the next time the window opened: no sheet, just the
    /// idle placeholder, with no way back to the setup sheet short of
    /// relaunching EVA (2026-08-15).
    @State private var showsBatchSetup = true
    @State private var batchSummary: BatchController.BatchSummary?
    /// Snapshot of `batch.jobs` taken the moment a run finishes (2026-08-16,
    /// "have it stay open and list the files that are processed"). `jobs` is
    /// a value-type array, so this copy survives `start`/`startHeadless`
    /// reassigning `batch.jobs` for the *next* run — without it, starting a
    /// second batch would silently rewrite the list out from under whatever
    /// was still showing the first run's results. Session-only by design, the
    /// same as `batch` itself: nothing here is meant to survive a relaunch.
    @State private var completedJobs: [BatchController.BatchJob] = []

    var body: some View {
        Group {
            if batch.isActive, !batch.isHeadlessRun, let recording {
                WaveformMarkerContainer(recording: recording)
                    .id(recording.id)
            } else if batch.isActive, batch.isHeadlessRun {
                headlessProgress
            } else if !completedJobs.isEmpty {
                resultsView
            } else {
                idlePlaceholder
            }
        }
        .onAppear {
            // Only re-arm the setup sheet for a genuinely idle reopen — no
            // completed run sitting in `completedJobs` to show instead. Both
            // `batch` and this view's own `@State` (`completedJobs` included)
            // survive the window closing and reopening within the same EVA
            // run — `Window` is a singleton scene, not torn down and rebuilt
            // like `WindowGroup` — so a finished batch's results are already
            // there to find on reopen (2026-08-16, "could it live as long as
            // the current run of EVA?"). The unconditional version of this
            // check (2026-08-15, fixing Cancel leaving the window stuck on
            // the idle placeholder) would otherwise pop the setup sheet right
            // back on top of those results every time.
            if !batch.isActive, completedJobs.isEmpty { showsBatchSetup = true }
        }
        .sheet(isPresented: $showsBatchSetup) {
            BatchSetupSheet(
                // Nothing to leave behind in an idle batch window — Cancel
                // closes the window itself rather than dismissing the sheet
                // onto an empty background, matching "this window's only job
                // is running a batch."
                //
                // Dismissing the sheet and closing the window in the same
                // tick doesn't work: `dismissWindow(id:)` called while this
                // sheet is still presented races the sheet's own dismissal
                // and is silently dropped, so Cancel visibly did nothing
                // (2026-08-15). Flipping `showsBatchSetup` off first lets the
                // sheet actually dismiss; queuing `dismissWindow` on the next
                // run-loop tick (`DispatchQueue.main.async`, not a real
                // delay) closes the window only once that's done.
                onCancel: {
                    showsBatchSetup = false
                    DispatchQueue.main.async {
                        dismissWindow(id: EVAApp.batchWindowID)
                    }
                },
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
            // Was an `.alert` (2026-08-15) — replaced (2026-08-16) because an
            // alert's "OK" is a dead end: acknowledging it was the only way
            // to make it go away, which meant giving up looking at the just-
            // finished file list. `resultsView` is what a completed batch
            // shows now instead; the alert's summary text becomes its
            // header, and `completedJobs` is the thing that actually keeps
            // it on screen rather than a transient dialog.
            if let summary {
                batchSummary = summary
                completedJobs = batch.jobs
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

    /// What a finished batch leaves on screen — every job from the run that
    /// just finished, each with a way to act on its output, rather than a
    /// one-shot summary dialog that only a "New Batch" click could get past.
    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = batchSummary {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Batch complete").font(.headline)
                    Text(batchSummaryMessage(s))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                Divider()
            }
            List(completedJobs) { job in
                batchResultRow(job)
            }
            .listStyle(.inset)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Divider()
            HStack {
                Spacer()
                Button("New Batch") { showsBatchSetup = true }
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func batchResultRow(_ job: BatchController.BatchJob) -> some View {
        HStack(spacing: 10) {
            statusIcon(job.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if case .failed(let message) = job.status {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if job.status == .needsInput {
                    Text("Needs a decision step — rerun through a windowed batch.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if job.status == .skipped {
                    Text("Skipped").font(.caption).foregroundStyle(.secondary)
                } else if let outputURL = job.outputURL {
                    Text(outputURL.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if let outputURL = job.outputURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")

                Button {
                    PendingWindowOpens.shared.push([outputURL])
                    openWindow(id: "main")
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open in EVA")
            }
        }
        .padding(.vertical, 2)
    }

    private func statusIcon(_ status: BatchController.JobStatus) -> some View {
        let (name, color): (String, Color) = {
            switch status {
            case .done: return ("checkmark.circle.fill", .green)
            case .failed: return ("xmark.circle.fill", .red)
            case .needsInput: return ("hand.raised.fill", .orange)
            case .skipped: return ("arrow.uturn.forward.circle.fill", .secondary)
            case .pending, .processing: return ("circle.dotted", .secondary)
            }
        }()
        return Image(systemName: name).foregroundStyle(color)
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
