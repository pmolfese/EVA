//
//  LatestOnlyRunner.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  "Only the newest run may publish" — the ownership primitive behind EVA's
//  `.task(id:)`-driven async work.
//
//  ## Why this exists
//
//  EVA drives detection and analysis from `.task(id:)`. When the id changes
//  mid-flight, SwiftUI cancels the running task and starts a new one. The
//  hand-written version of that protocol produced a real, shipped bug (eye-blink
//  artifacts, 2026-08-13): `updateArtifactEvents` finished its work, observed
//  `Task.isCancelled`, and returned having written *nothing* — leaving the events
//  empty and `isDetecting` stuck `true`. It resolved itself once the request id
//  stopped moving, which made it intermittent and nearly impossible to pin down.
//
//  Two distinct failure modes hide in that one line of `guard`:
//
//  1. **A stale run clobbers a fresh one.** Run A is superseded by run B, then A
//     finishes last and publishes its older results over B's.
//  2. **Cleanup is skipped on the cancellation path.** Every early `return` has to
//     remember to reset the spinner, and one of them didn't.
//
//  ## How the shape prevents them
//
//  Identity is an internal monotonic generation counter, not a caller-supplied
//  token, so callers cannot get the bookkeeping wrong or accidentally reuse a
//  token. The claim happens synchronously before the first suspension point —
//  this type is `@MainActor`, so nothing can interleave between incrementing the
//  generation and recording it.
//
//  `Outcome` is an enum the caller must switch over exhaustively. There is no way
//  to write the equivalent of the original bug without visibly writing a
//  `case .cancelled:` that does nothing — which is the point: the compiler makes
//  you say it out loud.
//
//  A superseded run returns `.superseded` and deliberately touches *no* shared
//  state, because the run that replaced it owns that state now. Clearing a
//  spinner there would blank the indicator for a run still in progress.
//

import Foundation

@MainActor
final class LatestOnlyRunner {
    enum Outcome<Success> {
        /// This run finished and is still the newest: publish its results.
        case completed(Success)
        /// A newer run replaced this one. Touch nothing — the newer run owns the
        /// shared state and will publish and clean up itself.
        case superseded
        /// Cancelled with no successor (e.g. the view went away). Safe to clean
        /// up, but do not publish: the inputs may already be stale.
        case cancelled
    }

    /// Label of the in-flight run, for diagnostics and tests.
    private(set) var activeLabel: String?

    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?

    var isRunning: Bool { activeGeneration != nil }

    /// Runs `work` as the newest run, reporting whether its result may be published.
    ///
    /// Identity is per *call*, not per label: two runs started with the same label
    /// are still distinct, so an identical repeated request cannot be mistaken for
    /// the run already in flight.
    func run<Success>(_ label: String = "", work: () async -> Success) async -> Outcome<Success> {
        generation &+= 1
        let thisGeneration = generation
        activeGeneration = thisGeneration
        activeLabel = label

        let value = await work()

        // A newer run claimed ownership while this one was suspended. Standing
        // down without touching anything is what keeps a stale run from
        // overwriting fresher results.
        guard activeGeneration == thisGeneration else { return .superseded }

        activeGeneration = nil
        activeLabel = nil

        if Task.isCancelled { return .cancelled }
        return .completed(value)
    }

    /// Disowns any in-flight run so it reports `.superseded` and publishes nothing.
    ///
    /// Used when the thing a run was computing for goes away — closing a recording,
    /// say — where results arriving afterwards would land in reused state.
    func invalidate() {
        activeGeneration = nil
        activeLabel = nil
    }
}
