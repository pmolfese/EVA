//
//  EVASimulateSelfTestTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-0: the simulator's determinism corpus (`SelfTest.run()`, ~106 checks) is
//  owned by the `EVASimulate` command-line-tool target and reachable as its
//  `selftest` subcommand. Rather than compile `SelfTest` and its metric helpers a
//  third time into the test module — where `SNRMetrics` and `SurrogateBrainModel`
//  would collide with EVA's own types — this wrapper runs the bundled CLI as a
//  subprocess and asserts it reports zero failures. Building EVATests builds its
//  EVA.app host, which depends on and embeds the CLI at
//  Contents/MacOS/EVASimulate, so the executable is always present and current.
//

import Foundation
import Testing

@Suite("EVASimulate self-test")
struct EVASimulateSelfTestTests {

    /// Locate the CLI embedded alongside the test host's own executable
    /// (EVA.app/Contents/MacOS/EVASimulate). These tests run inside the sandboxed
    /// EVA.app host, so `Bundle.main` is the app bundle and its executable's
    /// directory is Contents/MacOS.
    private func embeddedCLIURL() throws -> URL {
        let hostExecutable = try #require(
            Bundle.main.executableURL,
            "Could not resolve the test host executable URL"
        )
        let macOSDir = hostExecutable.deletingLastPathComponent()
        let cli = macOSDir.appendingPathComponent("EVASimulate")
        try #require(
            FileManager.default.isExecutableFile(atPath: cli.path),
            "Embedded EVASimulate CLI not found at \(cli.path)"
        )
        return cli
    }

    @Test("determinism corpus passes with zero failures")
    func selfTestPasses() throws {
        let cli = try embeddedCLIURL()

        let process = Process()
        process.executableURL = cli
        process.arguments = ["selftest"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Drain before waiting so a large corpus cannot deadlock on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        let passCount = output.components(separatedBy: "[PASS]").count - 1
        let failCount = output.components(separatedBy: "[FAIL]").count - 1

        #expect(
            process.terminationStatus == 0,
            "EVASimulate selftest exited \(process.terminationStatus) with \(failCount) failure(s):\n\(output)"
        )
        // Guard against a vacuous pass (e.g. the binary printing usage and exiting 0).
        #expect(
            passCount >= 100,
            "expected the full determinism corpus (~106 checks); saw \(passCount) PASS lines:\n\(output)"
        )
    }
}
