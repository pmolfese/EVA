//
//  ProcessingQueueTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Testing
@testable import EVA

@MainActor
struct ProcessingQueueTests {

    @Test func operationsRunOneAtATimeNotConcurrently() async {
        let queue = ProcessingQueue()
        var concurrentCount = 0
        var maxConcurrentCount = 0
        var completionOrder: [String] = []

        async let first: Void = queue.run("first") {
            concurrentCount += 1
            maxConcurrentCount = max(maxConcurrentCount, concurrentCount)
            try? await Task.sleep(nanoseconds: 30_000_000)
            concurrentCount -= 1
            completionOrder.append("first")
        }
        // `async let` does not promise the child tasks start in source order,
        // so wait until "first" genuinely holds the queue before enqueuing
        // "second". Otherwise the FIFO expectation below is a race the test
        // usually wins on an idle machine and can lose under parallel load.
        var spins = 0
        while queue.currentLabel != "first" && spins < 500 {
            await Task.yield()
            spins += 1
        }
        async let second: Void = queue.run("second") {
            concurrentCount += 1
            maxConcurrentCount = max(maxConcurrentCount, concurrentCount)
            try? await Task.sleep(nanoseconds: 10_000_000)
            concurrentCount -= 1
            completionOrder.append("second")
        }

        _ = await (first, second)

        #expect(maxConcurrentCount == 1)
        #expect(completionOrder == ["first", "second"]) // FIFO: enqueued first, runs first
    }

    @Test func queueReflectsCurrentAndWaitingOperations() async {
        let queue = ProcessingQueue()
        var snapshotDuringFirst: (current: String?, waiting: [String])?

        async let first: Void = queue.run("Filter") {
            // Wait for `second` to actually enqueue rather than assuming a
            // fixed delay covers it. A sleep here races the scheduler: when the
            // machine is loaded (a full parallel test run), the sibling task can
            // fail to reach its `run` call before the delay expires, and the
            // snapshot then records an empty queue and fails the expectation.
            var polls = 0
            while queue.waitingLabels.isEmpty && polls < 500 {
                try? await Task.sleep(nanoseconds: 2_000_000)
                polls += 1
            }
            snapshotDuringFirst = (queue.currentLabel, queue.waitingLabels)
        }
        // Likewise, only enqueue `second` once `first` genuinely holds the
        // queue, so the FIFO order under test is established rather than raced.
        var spins = 0
        while queue.currentLabel != "Filter" && spins < 500 {
            await Task.yield()
            spins += 1
        }
        async let second: Void = queue.run("Channel Health") {}

        _ = await (first, second)

        #expect(snapshotDuringFirst?.current == "Filter")
        #expect(snapshotDuringFirst?.waiting == ["Channel Health"])
        #expect(queue.isBusy == false)
        #expect(queue.queue.isEmpty)
    }

    @Test func isBusyReflectsQueueState() async {
        let queue = ProcessingQueue()
        #expect(queue.isBusy == false)

        await queue.run("Solo") {
            #expect(queue.isBusy == true)
        }

        #expect(queue.isBusy == false)
    }

    @Test func finishingProgressBridgePreventsLateProgressFromReappearing() async {
        var displayedProgress: Int?
        let (continuation, task) = ProgressBridge.make { value in
            displayedProgress = value
        }

        continuation.yield(100)
        await ProgressBridge.finishAndWait(continuation, task: task)
        displayedProgress = nil

        // Give any incorrectly detached/queued update a chance to run.
        await Task.yield()
        #expect(displayedProgress == nil)
    }

    @Test func progressBridgeCoalescesBurstsToTheNewestValue() async {
        var applied: [Int] = []
        let (continuation, task) = ProgressBridge.make { (value: Int) in
            applied.append(value)
        }

        // Yield a synchronous burst before the consumer task has run: the
        // 1-slot buffer must collapse it to the newest value, not queue 1,000
        // main-actor applies.
        for value in 0..<1_000 {
            continuation.yield(value)
        }
        await ProgressBridge.finishAndWait(continuation, task: task)

        #expect(applied == [999])
    }

    @Test func progressBridgeAlwaysAppliesTheFinalValue() async {
        var applied: [Int] = []
        let (continuation, task) = ProgressBridge.make { (value: Int) in
            applied.append(value)
        }

        continuation.yield(1)
        continuation.yield(2)
        continuation.yield(3)
        await ProgressBridge.finishAndWait(continuation, task: task)

        // Intermediate values may be dropped, but the value representing the
        // finished state must land before finishAndWait returns.
        #expect(applied.last == 3)
        #expect(applied.count <= 3)
    }
}
