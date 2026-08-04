//
//  BatchControllerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
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

    @Test func jobNameUsesInputFileName() {
        let c = started(["subject01"])
        #expect(c.currentJob?.name == "subject01.mff")
    }

    @Test func completeAfterFinishIsNoOp() {
        let c = started(["a"])
        c.completeCurrent(.done) // finishes
        c.completeCurrent(.done) // guarded no-op
        #expect(!c.isActive)
        #expect(c.currentIndex == -1)
    }

    // MARK: - Phase 2: headless batch

    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-headless-controller-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func headlessRunNeverDrivesCurrentIndexAndFinishesWithSummary() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))

        let c = BatchController()
        await c.startHeadless(
            files: [Fixtures.url("example_2.mff")],
            script: script,
            sourceName: "src",
            outputFolder: folder
        )

        #expect(!c.isActive) // finished synchronously by the time await returns
        #expect(c.currentIndex == -1) // headless never swaps ContentView's recording
        #expect(!c.isHeadlessRun)
        #expect(c.jobs.first?.status == .done)
        #expect(c.summary?.done == 1)
        #expect(c.summary?.needsInput == 0)
    }

    @Test func headlessRunMarksDecisionStepFilesAsNeedsInput() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .icaClean, parameters: [:]))

        let c = BatchController()
        await c.startHeadless(
            files: [Fixtures.url("example_2.mff")],
            script: script,
            sourceName: "src",
            outputFolder: folder
        )

        #expect(c.jobs.first?.status == .needsInput)
        #expect(c.summary?.needsInput == 1)
        #expect(c.summary?.done == 0)
    }

    @Test func headlessRunRecordsFailureForUnreadableFile() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let c = BatchController()
        await c.startHeadless(
            files: [URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mff")],
            script: EVAProcessingScript(),
            sourceName: "src",
            outputFolder: folder
        )

        guard case .failed = c.jobs.first?.status else {
            Issue.record("expected .failed status")
            return
        }
        #expect(c.summary?.failed.count == 1)
    }
}
