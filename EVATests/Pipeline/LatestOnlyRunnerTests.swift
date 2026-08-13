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

@MainActor
struct LatestOnlyRunnerTests {

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
        var published: [String] = []

        // Start a slow run, let it actually claim ownership, then supersede it
        // with a fast one. The slow run finishes last — the ordering that made
        // the original bug overwrite fresh results with stale ones.
        async let slow: Void = {
            let outcome = await runner.run("slow") {
                try? await Task.sleep(nanoseconds: 40_000_000)
                return "stale"
            }
            if case .completed(let value) = outcome { published.append(value) }
        }()

        var spins = 0
        while runner.activeLabel != "slow" && spins < 500 {
            await Task.yield()
            spins += 1
        }

        async let fast: Void = {
            let outcome = await runner.run("fast") { "fresh" }
            if case .completed(let value) = outcome { published.append(value) }
        }()

        _ = await (slow, fast)

        #expect(published == ["fresh"], "a superseded run must publish nothing")
        #expect(!runner.isRunning)
    }

    /// The other half: a superseded run must not clean up either, because the
    /// run that replaced it still owns the shared state.
    @Test func supersededRunIsReportedAsSupersededNotCancelled() async {
        let runner = LatestOnlyRunner()
        var slowOutcome: LatestOnlyRunner.Outcome<String>?

        async let slow: Void = {
            slowOutcome = await runner.run("slow") {
                try? await Task.sleep(nanoseconds: 40_000_000)
                return "stale"
            }
        }()

        var spins = 0
        while runner.activeLabel != "slow" && spins < 500 {
            await Task.yield()
            spins += 1
        }

        async let fast: Void = { _ = await runner.run("fast") { "fresh" } }()
        _ = await (slow, fast)

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
        var published: [Int] = []

        async let first: Void = {
            let outcome = await runner.run("same") {
                try? await Task.sleep(nanoseconds: 40_000_000)
                return 1
            }
            if case .completed(let value) = outcome { published.append(value) }
        }()

        var spins = 0
        while !runner.isRunning && spins < 500 {
            await Task.yield()
            spins += 1
        }

        async let second: Void = {
            let outcome = await runner.run("same") { 2 }
            if case .completed(let value) = outcome { published.append(value) }
        }()

        _ = await (first, second)
        #expect(published == [2])
    }

    /// `invalidate()` disowns an in-flight run — the "recording was closed"
    /// case, where late results would land in reused state.
    @Test func invalidateStopsAnInFlightRunFromPublishing() async {
        let runner = LatestOnlyRunner()
        var outcome: LatestOnlyRunner.Outcome<String>?

        async let run: Void = {
            outcome = await runner.run("closing") {
                try? await Task.sleep(nanoseconds: 30_000_000)
                return "late"
            }
        }()

        var spins = 0
        while runner.activeLabel != "closing" && spins < 500 {
            await Task.yield()
            spins += 1
        }
        runner.invalidate()
        _ = await run

        guard case .superseded = outcome else {
            Issue.record("expected .superseded after invalidate, got \(String(describing: outcome))")
            return
        }
        #expect(!runner.isRunning)
    }
}
