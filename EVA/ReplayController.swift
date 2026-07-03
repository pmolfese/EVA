//
//  ReplayController.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for interactive "Copy Processing" replay: owns the pre-replay
//  configuration, the run-state machine, and the async decision gate. WaveformView
//  still owns the apply-functions and drives the loop (reading this controller's
//  state); the UI resolves each pause via `resume(_:)`. This keeps interactive and
//  replay on one code path — replay just awaits a gate between the same steps.
//

import Combine
import SwiftUI

@MainActor
final class ReplayController: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case fullAuto = "Full Auto"
        case reviewEach = "Review Each"
        var id: String { rawValue }
    }

    /// What the loop should do at a step, resolved from the config + mode.
    enum GateKind: Equatable { case review, decision }

    enum State: Equatable {
        case idle
        case configuring
        case running(index: Int)
        case awaitingReview(index: Int)
        case awaitingDecision(index: Int)
        case finished
        case cancelled

        var isAwaitingReview: Bool { if case .awaitingReview = self { return true }; return false }
        var isAwaitingDecision: Bool { if case .awaitingDecision = self { return true }; return false }
        var isAwaiting: Bool { isAwaitingReview || isAwaitingDecision }
        var isRunning: Bool {
            switch self {
            case .running, .awaitingReview, .awaitingDecision: return true
            default: return false
            }
        }
    }

    /// How the user resolves a pause.
    enum Resolution: Equatable { case proceed, skip, cancel }

    struct StepConfig: Identifiable {
        let id: Int // index into `script.steps`
        let step: EVAProcessingStep
        let kind: ReplayInteraction
        var included: Bool
        var pauseToReview: Bool
    }

    struct ReplayAction: Identifiable, Equatable {
        let stepIndex: Int
        let operation: EVAProcessingStep.Operation
        let interaction: ReplayInteraction
        let gate: GateKind?
        var id: Int { stepIndex }
    }

    struct BannerInfo: Equatable {
        var title: String
        var detail: String
        var showsSkip: Bool
        var progress: Double?
    }

    // MARK: Config + state
    @Published var sourceName = ""
    @Published var steps: [StepConfig] = []
    @Published var mode: Mode = .fullAuto
    @Published var state: State = .idle
    @Published var showsConfigPane = false
    @Published var banner: BannerInfo?

    // MARK: Finish-and-export (the seam Batch produces outputs through)
    @Published var exportWhenFinished = false
    /// Destination folder for the processed MFF; output is `<name>-processed.mff`.
    @Published var outputFolder: URL?

    private var continuation: CheckedContinuation<Resolution, Never>?
    private var pendingResolution: Resolution?

    // MARK: Config population

    /// Seeds the config pane from a freshly-read script. Skip-classified steps
    /// are shown but excluded by default; gradient defaults to "pause to review".
    func configure(script: EVAProcessingScript, sourceName: String) {
        self.sourceName = sourceName
        steps = script.steps.enumerated().map { index, step in
            let kind = step.replayInteraction
            return StepConfig(
                id: index,
                step: step,
                kind: kind,
                included: kind != .skip,
                pauseToReview: kind == .review
            )
        }
        mode = .fullAuto
        state = .configuring
        banner = nil
        continuation = nil
        pendingResolution = nil
        showsConfigPane = true
    }

    /// Seeds this (fresh, per-recording) controller from a batch's shared config:
    /// re-seed steps from the script, then overlay the batch's include/review
    /// choices + mode, and turn on finish-and-export to the batch folder. The
    /// per-file config pane is skipped — batch already configured everything.
    func configure(fromBatch batch: BatchController, script: EVAProcessingScript) {
        configure(script: script, sourceName: batch.sourceName)
        for i in steps.indices where batch.stepTemplates.indices.contains(i) {
            steps[i].included = batch.stepTemplates[i].included
            steps[i].pauseToReview = batch.stepTemplates[i].pauseToReview
        }
        mode = batch.mode
        exportWhenFinished = true
        outputFolder = batch.outputFolder
        showsConfigPane = false
    }

    /// Pure reduction of (steps + mode) → the ordered actions the loop runs.
    /// Excludes skipped/unchecked steps; decides which get a gate.
    func plannedActions() -> [ReplayAction] {
        steps.compactMap { cfg in
            guard cfg.included, cfg.kind != .skip else { return nil }
            let gate: GateKind?
            switch cfg.kind {
            case .decision:
                gate = .decision
            case .review:
                gate = cfg.pauseToReview ? .review : nil
            case .auto:
                gate = (mode == .reviewEach || cfg.pauseToReview) ? .review : nil
            case .skip:
                gate = nil
            }
            return ReplayAction(
                stepIndex: cfg.id,
                operation: cfg.step.operation,
                interaction: cfg.kind,
                gate: gate
            )
        }
    }

    func parameters(forStep index: Int) -> [String: String] {
        steps.first { $0.id == index }?.step.parameters ?? [:]
    }

    // MARK: Async decision gate

    /// Suspends the replay loop until `resume(_:)` is called. Sets the run state
    /// and (optionally) a banner while paused.
    func gate(_ reason: State, banner: BannerInfo?) async -> Resolution {
        state = reason
        self.banner = banner
        return await withCheckedContinuation { cont in
            if let pending = pendingResolution {
                pendingResolution = nil
                cont.resume(returning: pending)
            } else {
                continuation = cont
            }
        }
    }

    /// Resolves a pending gate. Idempotent: a resume with no waiter is buffered
    /// (for the race where the UI finishes before the loop reaches its gate); a
    /// second resume is a harmless no-op.
    func resume(_ resolution: Resolution) {
        banner = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: resolution)
        } else {
            pendingResolution = resolution
        }
    }

    func cancel() { resume(.cancel) }

    func reset() {
        // Release any waiter so the loop can unwind, then clear.
        if continuation != nil { resume(.cancel) }
        state = .idle
        steps = []
        banner = nil
        showsConfigPane = false
        pendingResolution = nil
        sourceName = ""
    }
}
