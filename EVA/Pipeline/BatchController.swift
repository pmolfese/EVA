//
//  BatchController.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  App-level coordinator for Batch Process: apply one processing script (an
//  eva.xml) to many MFF files. It survives recording swaps (unlike the per-window
//  view models), holds the queue + shared config, and advances file-by-file.
//  ContentView reacts to `currentIndex` to swap the open recording; each fresh
//  WaveformView auto-starts the existing interactive replay and reports back here.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class BatchController {

    enum JobStatus: Equatable {
        case pending, processing, needsInput, done, skipped
        case failed(String)
    }

    struct BatchJob: Identifiable {
        let id = UUID()
        let url: URL
        var status: JobStatus = .pending
        var name: String { url.lastPathComponent }
    }

    struct BatchSummary: Equatable {
        var done: Int
        var skipped: Int
        var needsInput: Int
        var failed: [String] // "<file>: <message>"
        var total: Int
    }

    // Shared processing definition applied to every file.
    private(set) var script: EVAProcessingScript?
    private(set) var sourceName = ""
    private(set) var stepTemplates: [ReplayController.StepConfig] = []
    private(set) var mode: ReplayController.Mode = .fullAuto
    private(set) var outputFolder: URL?

    // Queue state.
    private(set) var jobs: [BatchJob] = []
    private(set) var currentIndex = -1 // -1 == idle
    private(set) var isActive = false
    private(set) var summary: BatchSummary?

    /// True while `startHeadless` is running — distinguishes the windowless
    /// path from the windowed one for UI that needs to show progress without
    /// a live `WaveformView`/`replayBanner()` (there isn't one). `currentIndex`
    /// stays -1 throughout a headless run (see `startHeadless`), so this uses
    /// its own index for progress display instead.
    private(set) var isHeadlessRun = false
    private(set) var headlessIndex = -1
    private(set) var currentStepName = ""
    private(set) var currentStepProgress: Double?
    private(set) var currentFileProgress = 0.0

    private var scopedURLs: [URL] = []

    var currentJob: BatchJob? {
        guard isActive, jobs.indices.contains(currentIndex) else { return nil }
        return jobs[currentIndex]
    }
    var currentJobURL: URL? { currentJob?.url }
    var overallProgress: Double {
        guard isActive, !jobs.isEmpty else { return 0 }
        let index = isHeadlessRun ? headlessIndex : currentIndex
        guard index >= 0 else { return 0 }
        let fileFraction = min(max(currentFileProgress, 0), 1)
        return min(max((Double(index) + fileFraction) / Double(jobs.count), 0), 1)
    }

    /// True when `recording` is the file currently being processed.
    func matches(recording: MFFRecording) -> Bool {
        currentJobURL == recording.packageURL
    }

    // MARK: - Lifecycle

    func start(
        files: [URL],
        script: EVAProcessingScript,
        sourceName: String,
        steps: [ReplayController.StepConfig],
        mode: ReplayController.Mode,
        outputFolder: URL,
        scopedURLs: [URL] = []
    ) {
        guard !files.isEmpty else { return }
        jobs = files.map { BatchJob(url: $0) }
        self.script = script
        self.sourceName = sourceName
        self.stepTemplates = steps
        self.mode = mode
        self.outputFolder = outputFolder
        self.scopedURLs = scopedURLs
        scopedURLs.forEach { _ = $0.startAccessingSecurityScopedResource() }
        summary = nil
        isActive = true
        updateProgress(stepName: "Waiting to open file", stepProgress: nil, fileProgress: 0)
        currentIndex = 0 // fires ContentView's swap to the first file
    }

    func setStatus(_ status: JobStatus) {
        guard jobs.indices.contains(currentIndex) else { return }
        jobs[currentIndex].status = status
    }

    /// Marks the current job's outcome and advances to the next file.
    func completeCurrent(_ status: JobStatus) {
        guard isActive else { return }
        setStatus(status)
        advance()
    }

    func advance() {
        guard isActive else { return }
        let next = currentIndex + 1
        if next >= jobs.count {
            finish()
        } else {
            updateProgress(stepName: "Waiting to open file", stepProgress: nil, fileProgress: 0)
            currentIndex = next
        }
    }

    /// User pressed "Stop Batch": end the run, leaving unprocessed jobs pending.
    func stop() { finish() }

    func updateProgress(stepName: String, stepProgress: Double?, fileProgress: Double) {
        currentStepName = stepName
        currentStepProgress = stepProgress.map { min(max($0, 0), 1) }
        currentFileProgress = min(max(fileProgress, 0), 1)
    }

    private func finish() {
        let done = jobs.filter { $0.status == .done }.count
        let skipped = jobs.filter { $0.status == .skipped || $0.status == .pending }.count
        let needsInput = jobs.filter { $0.status == .needsInput }.count
        let failed = jobs.compactMap { job -> String? in
            if case .failed(let message) = job.status { return "\(job.name): \(message)" }
            return nil
        }
        summary = BatchSummary(done: done, skipped: skipped, needsInput: needsInput, failed: failed, total: jobs.count)
        isActive = false
        currentIndex = -1
        isHeadlessRun = false
        headlessIndex = -1
        currentStepName = ""
        currentStepProgress = nil
        currentFileProgress = 0
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }

    // MARK: - Phase 2: headless (windowless) batch

    /// Runs entirely without opening any window: no `currentIndex` swap, no
    /// `ContentView`/`WaveformView` involvement at all. Only appropriate when
    /// `script`'s configured (included) steps contain no decision step — the
    /// caller (`BatchSetupSheet`) checks that before choosing this over
    /// `start(...)`. Each file gets a fresh `RecordingStore`/VM set purely as
    /// `ProcessingCore` collaborators (see `HeadlessBatchProcessor`); nothing
    /// here ever touches a live view.
    func startHeadless(
        files: [URL],
        script: EVAProcessingScript,
        sourceName: String,
        outputFolder: URL,
        scopedURLs: [URL] = []
    ) async {
        guard !files.isEmpty else { return }
        jobs = files.map { BatchJob(url: $0) }
        self.script = script
        self.sourceName = sourceName
        self.outputFolder = outputFolder
        self.scopedURLs = scopedURLs
        scopedURLs.forEach { _ = $0.startAccessingSecurityScopedResource() }
        summary = nil
        isActive = true
        isHeadlessRun = true
        currentIndex = -1 // headless never drives ContentView's recording swap

        for index in jobs.indices {
            guard isActive else { break } // Stop Batch was pressed mid-run
            headlessIndex = index
            jobs[index].status = .processing
            updateProgress(stepName: "Loading recording", stepProgress: nil, fileProgress: 0)
            do {
                switch try await HeadlessBatchProcessor.process(
                    url: jobs[index].url,
                    script: script,
                    outputFolder: outputFolder,
                    progress: { [self] update in
                        updateProgress(
                            stepName: update.stepName,
                            stepProgress: update.stepProgress,
                            fileProgress: update.fileProgress
                        )
                    }
                ) {
                case .completed:
                    jobs[index].status = .done
                case .needsInput:
                    jobs[index].status = .needsInput
                }
            } catch {
                jobs[index].status = .failed(error.localizedDescription)
            }
        }
        // If `stop()` fired mid-run it already called `finish()` (and reset
        // `isActive`); don't recompute/reset a second time.
        if isActive { finish() }
    }
}
