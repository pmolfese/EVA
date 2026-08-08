//
//  ReplayController.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for interactive "Copy Processing" replay: owns the pre-replay
//  configuration, the run-state machine, and the async decision gate. WaveformView
//  still owns the apply-functions and drives the loop (reading this controller's
//  state); the UI resolves each pause via `resume(_:)`. This keeps interactive and
//  replay on one code path — replay just awaits a gate between the same steps.
//

import SwiftUI

@MainActor
@Observable
final class ReplayController {

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
        /// Set when `configure` was given a target signal and this step
        /// doesn't fit it (missing TR markers, out-of-range channel override,
        /// unmatched event codes, …) — surfaced in the config pane and
        /// defaults `included` to `false` so an incompatible step doesn't
        /// silently no-op partway through a run.
        var compatibilityFlag: ReplayCompatibilityFlag?
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
    var sourceName = ""
    var steps: [StepConfig] = []
    var mode: Mode = .fullAuto
    var state: State = .idle
    var showsConfigPane = false
    var banner: BannerInfo?

    // MARK: Finish-and-export (the seam Batch produces outputs through)
    var exportWhenFinished = false
    /// Destination folder for replay output; filename suffix follows the final
    /// export kind (`processed`, `segmented`, or `average`).
    var outputFolder: URL?

    private var continuation: CheckedContinuation<Resolution, Never>?
    private var pendingResolution: Resolution?

    // MARK: Config population

    /// Seeds the config pane from a freshly-read script. Skip-classified steps
    /// are shown but excluded by default; gradient defaults to "pause to review".
    /// `signal`, when given, runs the compatibility pre-flight against it —
    /// a step that doesn't fit (missing TR markers, out-of-range channel
    /// override, unmatched event codes) starts unchecked with a reason shown
    /// in the config pane, rather than silently no-oping mid-run.
    func configure(script: EVAProcessingScript, sourceName: String, signal: MFFSignalData? = nil) {
        self.sourceName = sourceName
        steps = script.steps.enumerated().map { index, step in
            let kind = step.replayInteraction
            let flag = signal.flatMap { ReplayCompatibility.check(step, against: $0) }
            return StepConfig(
                id: index,
                step: step,
                kind: kind,
                included: kind != .skip && flag == nil,
                pauseToReview: kind == .review,
                compatibilityFlag: flag
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
    /// `signal` (this file's own signal, distinct from whatever the batch
    /// setup sheet could check) re-runs the compatibility pre-flight
    /// per-file: a step compatible with one batch file may not be with
    /// another (e.g. a TR-marker code present in most files but missing from
    /// this one), so an incompatible step is force-excluded here even if the
    /// batch template had it included.
    func configure(fromBatch batch: BatchController, script: EVAProcessingScript, signal: MFFSignalData? = nil) {
        configure(script: script, sourceName: batch.sourceName, signal: signal)
        for i in steps.indices where batch.stepTemplates.indices.contains(i) {
            steps[i].included = batch.stepTemplates[i].included && steps[i].compatibilityFlag == nil
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
