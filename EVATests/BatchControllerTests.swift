//
//  BatchControllerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Unit coverage for the Batch queue reducer: start/advance/finish transitions,
//  per-job status progression, bounds, and the end summary.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct BatchControllerTests {

    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/tmp/\($0).mff") }
    }

    private func started(_ names: [String]) -> BatchController {
        let c = BatchController()
        c.start(files: urls(names), script: EVAProcessingScript(), sourceName: "src",
                steps: [], mode: .fullAuto, outputFolder: URL(fileURLWithPath: "/tmp/out"))
        return c
    }

    @Test func startActivatesFirstJob() {
        let c = started(["a", "b", "c"])
        #expect(c.isActive)
        #expect(c.currentIndex == 0)
        #expect(c.jobs.count == 3)
        #expect(c.jobs.allSatisfy { $0.status == .pending })
        #expect(c.currentJobURL == URL(fileURLWithPath: "/tmp/a.mff"))
    }

    @Test func completeProgressesThenFinishes() {
        let c = started(["a", "b", "c"])
        c.completeCurrent(.done)
        #expect(c.currentIndex == 1)
        #expect(c.jobs[0].status == .done)

        c.completeCurrent(.done)
        #expect(c.currentIndex == 2)

        c.completeCurrent(.done)
        #expect(!c.isActive)
        #expect(c.currentIndex == -1)
        #expect(c.summary?.done == 3)
        #expect(c.summary?.total == 3)
    }

    @Test func currentJobIsNilBeforeAndAfterRun() {
        let c = BatchController()
        #expect(c.currentJob == nil)
        c.start(files: urls(["a"]), script: EVAProcessingScript(), sourceName: "s",
                steps: [], mode: .fullAuto, outputFolder: URL(fileURLWithPath: "/tmp/o"))
        #expect(c.currentJob != nil)
        c.completeCurrent(.done)
        #expect(c.currentJob == nil)
    }

    @Test func matchesRecordingByURL() {
        let c = started(["a", "b"])
        let match = MFFRecording(packageURL: URL(fileURLWithPath: "/tmp/a.mff"))
        let other = MFFRecording(packageURL: URL(fileURLWithPath: "/tmp/b.mff"))
        #expect(c.matches(recording: match))
        #expect(!c.matches(recording: other))
    }

    @Test func stopMidRunCountsRemainingAsSkipped() {
        let c = started(["a", "b", "c"])
        c.completeCurrent(.done) // a done, now at b
        c.stop()
        #expect(!c.isActive)
        #expect(c.summary?.done == 1)
        #expect(c.summary?.skipped == 2) // b + c still pending → counted skipped
    }

    @Test func failureRecordedInSummary() {
        let c = started(["a", "b"])
        c.completeCurrent(.failed("boom"))
        c.completeCurrent(.done)
        #expect(c.summary?.done == 1)
        #expect(c.summary?.failed == ["a.mff: boom"])
    }

    @Test func outputNameFormatting() {
        let c = started(["subject01"])
        #expect(c.currentJob?.outputName == "subject01-processed.mff")
    }

    @Test func completeAfterFinishIsNoOp() {
        let c = started(["a"])
        c.completeCurrent(.done) // finishes
        c.completeCurrent(.done) // guarded no-op
        #expect(!c.isActive)
        #expect(c.currentIndex == -1)
    }
}
