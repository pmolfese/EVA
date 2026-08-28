//
//  LatestOnlyRunnerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Regression coverage for the eye-blink artifact bug (2026-08-13): detection
//  finished, saw `Task.isCancelled`, and returned having published nothing —
//  leaving the events empty and the spinner stuck on.
//
//  These tests exist because that bug was *not* unit-testable where it lived: it
//  was inline in a `@MainActor` function on `WaveformView`, so catching it needed
//  a live view. Extracting the ownership protocol into `LatestOnlyRunner` is what
//  makes the failure modes assertable at all.
//

import Testing
@testable import EVA

/// Lets a test hold a run open until it explicitly releases it.
///
/// Replaces `Task.sleep` + `async let`: `async let` does not promise a child
/// starts before the next statement runs, so a sleep-based "slow" run could
/// finish before the "fast" run ever claimed the runner, inverting the ordering
/// under test. (`ProcessingQueueTests` documents the same trap.) A gate makes the
/// interleaving deterministic instead of probable.
@MainActor
private final class RunGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct LatestOnlyRunnerTests {

    /// Spins until `condition` holds, failing rather than hanging if it never does.
    private func waitUntil(_ label: String, _ condition: () -> Bool) async {
        var spins = 0
        while !condition() && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        if !condition() { Issue.record("timed out waiting for \(label)") }
    }

    @Test func completedRunReportsItsValue() async {
        let runner = LatestOnlyRunner()

        let outcome = await runner.run("detect") { 42 }

        guard case .completed(let value) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(value == 42)
        #expect(!runner.isRunning)
        #expect(runner.activeLabel == nil)
    }

    /// The core of the shipped bug: a superseded run must not publish.
    @Test func supersededRunStandsDownAndNewestRunPublishes() async {
        let runner = LatestOnlyRunner()
        let gate = RunGate()
        var published: [String] = []

        // Hold a run open, supersede it, then let it finish last — the ordering
        // that made the original bug overwrite fresh results with stale ones.
        let slow = Task { @MainActor in
            let outcome = await runner.run("slow") {
                await gate.wait()
                return "stale"
            }
            if case .completed(let value) = outcome { published.append(value) }
        }
        await waitUntil("the slow run to claim") { runner.activeLabel == "slow" }

        let fastOutcome = await runner.run("fast") { "fresh" }
        if case .completed(let value) = fastOutcome { published.append(value) }

        gate.release()
        await slow.value

        #expect(published == ["fresh"], "a superseded run must publish nothing")
        #expect(!runner.isRunning)
    }

    /// The other half: a superseded run must not clean up either, because the
    /// run that replaced it still owns the shared state.
    @Test func supersededRunIsReportedAsSupersededNotCancelled() async {
        let runner = LatestOnlyRunner()
        let gate = RunGate()
        var slowOutcome: LatestOnlyRunner.Outcome<String>?

        let slow = Task { @MainActor in
            slowOutcome = await runner.run("slow") {
                await gate.wait()
                return "stale"
            }
        }
        await waitUntil("the slow run to claim") { runner.activeLabel == "slow" }

        _ = await runner.run("fast") { "fresh" }
        gate.release()
        await slow.value

        guard case .superseded = slowOutcome else {
            Issue.record("expected .superseded, got \(String(describing: slowOutcome))")
            return
        }
    }

    /// Cancelled with no successor: the caller is told, so it can clear its
    /// spinner. This is the exact path that leaked `isDetecting = true`.
    @Test func cancelledRunWithNoSuccessorReportsCancelled() async {
        let runner = LatestOnlyRunner()
        var outcome: LatestOnlyRunner.Outcome<String>?

        let task = Task { @MainActor in
            outcome = await runner.run("cancelled") {
                try? await Task.sleep(nanoseconds: 60_000_000)
                return "value"
            }
        }

        var spins = 0
        while runner.activeLabel != "cancelled" && spins < 500 {
            await Task.yield()
            spins += 1
        }
        task.cancel()
        await task.value

        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(String(describing: outcome))")
            return
        }
        #expect(!runner.isRunning, "a cancelled run must still release ownership")
    }

    /// Two runs with the *same* label are still distinct runs, so a repeated
    /// identical request cannot be mistaken for the one already in flight.
    @Test func identicalLabelsAreStillDistinctRuns() async {
        let runner = LatestOnlyRunner()
        let gate = RunGate()
        var published: [Int] = []

        let first = Task { @MainActor in
            let outcome = await runner.run("same") {
                await gate.wait()
                return 1
            }
            if case .completed(let value) = outcome { published.append(value) }
        }
        await waitUntil("the first run to claim") { runner.isRunning }

        let secondOutcome = await runner.run("same") { 2 }
        if case .completed(let value) = secondOutcome { published.append(value) }

        gate.release()
        await first.value

        #expect(published == [2])
    }

    /// `invalidate()` disowns an in-flight run — the "recording was closed"
    /// case, where late results would land in reused state.
    @Test func invalidateStopsAnInFlightRunFromPublishing() async {
        let runner = LatestOnlyRunner()
        let gate = RunGate()
        var outcome: LatestOnlyRunner.Outcome<String>?

        let run = Task { @MainActor in
            outcome = await runner.run("closing") {
                await gate.wait()
                return "late"
            }
        }
        await waitUntil("the run to claim") { runner.activeLabel == "closing" }

        runner.invalidate()
        gate.release()
        await run.value

        guard case .superseded = outcome else {
            Issue.record("expected .superseded after invalidate, got \(String(describing: outcome))")
            return
        }
        #expect(!runner.isRunning)
    }
}
