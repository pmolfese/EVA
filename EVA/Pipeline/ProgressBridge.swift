//
//  ProgressBridge.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

nonisolated enum ProgressBridge {
    /// UI progress needs at most display rate; workers can yield far faster
    /// (per-chunk/per-epoch), and every applied update invalidates observing
    /// views. ~30 Hz keeps progress visually continuous while capping that cost.
    static let defaultMinimumInterval: Duration = .milliseconds(33)

    /// Applies streamed progress values on the main actor, coalesced to at most
    /// one apply per `minimumInterval`. Intermediate values are dropped
    /// (newest wins), so `apply` must be last-write-wins — set state, don't
    /// accumulate. The last value yielded before `finish()` is always applied
    /// (after at most one interval), so completion states aren't lost.
    @MainActor
    static func make<Value: Sendable>(
        minimumInterval: Duration = defaultMinimumInterval,
        apply: @escaping @MainActor (Value) -> Void
    ) -> (continuation: AsyncStream<Value>.Continuation, task: Task<Void, Never>) {
        // The 1-slot buffer is what coalesces: while the consumer paces below,
        // newer yields overwrite older ones instead of queueing behind them.
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task { @MainActor in
            for await value in stream {
                apply(value)
                // Pace, letting the buffer collapse any burst to its newest
                // value. Cancellation just ends pacing early; the next stream
                // await then terminates delivery, matching the pre-throttle
                // behavior of `task.cancel()`.
                try? await Task.sleep(for: minimumInterval)
            }
        }
        return (continuation, task)
    }

    /// Closes a progress stream and waits until every already-queued update has
    /// been applied on the main actor. Callers can safely clear their visible
    /// progress state after this returns without a late update restoring it.
    @MainActor
    static func finishAndWait<Value: Sendable>(
        _ continuation: AsyncStream<Value>.Continuation,
        task: Task<Void, Never>
    ) async {
        continuation.finish()
        await task.value
    }
}
