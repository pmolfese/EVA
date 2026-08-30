//
//  SimulatorRunnerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-1: exercise the exact runtime path the Simulated Recording window uses —
//  `SimulatorRunner.generate` locating the bundled EVASimulate tool via
//  `Bundle.main` and running it. These tests are hosted by the sandboxed EVA.app,
//  so a pass also confirms the App Sandbox permits executing the embedded tool
//  and writing/reading its output, which is the one thing the GUI cannot fake.
//

import Foundation
import Testing
@testable import EVA

@Suite("SimulatorRunner")
struct SimulatorRunnerTests {

    /// A deliberately tiny recording so the test stays fast: 2 seconds, few
    /// channels, artifacts off.
    private func fastConfig() -> SimulationConfig {
        var config = SimulationConfig.default
        config.durationSeconds = 2
        config.channelCount = 8
        config.samplingRate = 250
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.blinksPerMinute = 0
        config.emg = nil
        config.seed = 12_345
        return config
    }

    @Test("locates the embedded CLI in the app bundle")
    func locatesCLI() throws {
        let cli = try #require(
            SimulatorRunner.locateCLI(),
            "Expected EVASimulate beside the app executable in Contents/MacOS"
        )
        #expect(FileManager.default.isExecutableFile(atPath: cli.path))
    }

    @Test("generates a contaminated recording that flows to disk")
    func generatesRecording() throws {
        let output = try SimulatorRunner.generate(
            config: fastConfig(), name: "UnitTest"
        )
        defer { try? FileManager.default.removeItem(at: output.directory) }

        // The noisy recording is what SIM-1 opens; the clean + truth are written
        // alongside it.
        #expect(FileManager.default.fileExists(atPath: output.noisyURL.path))
        #expect(FileManager.default.fileExists(atPath: output.cleanURL.path))
        #expect(FileManager.default.fileExists(atPath: output.truthURL.path))
        #expect(output.noisyURL.pathExtension == "mff")
    }

    @Test("writes a command record describing the invocation")
    func writesCommandRecord() throws {
        let output = try SimulatorRunner.generate(config: fastConfig(), name: "Cmd")
        defer { try? FileManager.default.removeItem(at: output.directory) }
        #expect(FileManager.default.fileExists(atPath: output.commandURL.path))
        let json = try String(contentsOf: output.commandURL, encoding: .utf8)
        #expect(json.contains("generate"), "command record should name the subcommand")
        #expect(json.contains("--config"), "command record should carry the arguments")
    }

    @Test("relocates outputs into a chosen directory")
    func relocatesToChosenDirectory() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVASimulateTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        var options = SimulatorRunner.Options()
        options.outputDirectory = dest
        options.prefix = "run"
        let output = try SimulatorRunner.generate(
            config: fastConfig(), name: "Reloc", options: options
        )

        #expect(output.directory == dest)
        #expect(output.noisyURL == dest.appendingPathComponent("run_noisy.mff"))
        #expect(FileManager.default.fileExists(atPath: output.noisyURL.path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("run_scenario.json").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("run_command.json").path))
    }

    @Test("the same seed reproduces the same samples")
    func seedIsDeterministic() throws {
        let first = try SimulatorRunner.generate(config: fastConfig(), name: "A")
        defer { try? FileManager.default.removeItem(at: first.directory) }
        let second = try SimulatorRunner.generate(config: fastConfig(), name: "B")
        defer { try? FileManager.default.removeItem(at: second.directory) }

        let signalA = first.noisyURL.appendingPathComponent("signal1.bin")
        let signalB = second.noisyURL.appendingPathComponent("signal1.bin")
        let dataA = try Data(contentsOf: signalA)
        let dataB = try Data(contentsOf: signalB)
        #expect(dataA == dataB, "identical seed and config should yield identical samples")
    }
}
