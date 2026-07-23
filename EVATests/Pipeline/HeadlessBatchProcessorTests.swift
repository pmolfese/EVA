//
//  HeadlessBatchProcessorTests.swift
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
//  Coverage for Phase 2 of the batch roadmap (TODO.md): processing a real
//  fixture with no window at all, end to end — load, apply, write — and the
//  two "can't finish headlessly" outcomes (a decision step, an unreadable file).
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct HeadlessBatchProcessorTests {

    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-headless-batch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func filterOnlyScriptCompletesAndWritesOutput() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))

        let outcome = try await HeadlessBatchProcessor.process(
            url: Fixtures.url("example_2.mff"), script: script, outputFolder: folder
        )
        guard case .completed(let outputURL) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("eva.xml").path))

        // The written file must actually reflect the filter, not a raw copy.
        let written = try MFFReader().loadSignal(from: outputURL)
        let original = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        #expect(written.data[0] != original.data[0])
    }

    @Test func scriptWithDecisionStepReportsNeedsInput() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))
        script.append(EVAProcessingStep(operation: .icaClean, parameters: [:]))

        let outcome = try await HeadlessBatchProcessor.process(
            url: Fixtures.url("example_2.mff"), script: script, outputFolder: folder
        )
        guard case .needsInput = outcome else {
            Issue.record("expected .needsInput, got \(outcome)")
            return
        }
        // Nothing should be written when the run can't complete headlessly.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func unreadableFileThrows() async {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mff")

        await #expect(throws: Error.self) {
            _ = try await HeadlessBatchProcessor.process(
                url: missing, script: EVAProcessingScript(), outputFolder: folder
            )
        }
    }
}
