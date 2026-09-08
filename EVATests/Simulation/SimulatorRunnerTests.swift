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

    @Test("bundled scenario presets are available and load")
    func scenarioPresetsLoad() throws {
        let presets = SimulatorScenarioLibrary.all
        #expect(!presets.isEmpty, "expected the scenarios folder reference to be bundled")
        let first = try #require(presets.first)
        let loaded = try #require(SimulatorScenarioLibrary.config(for: first))
        #expect(loaded.config.channelCount > 0)
    }

    @Test("sweep generates one run per value")
    func sweepRuns() throws {
        var config = fastConfig()
        config.bcgEnabled = true
        let outcome = try SimulatorRunner.sweep(
            config: config, name: "SweepTest",
            parameter: "bcg-amplitude", values: [50, 120],
            options: SimulatorRunner.Options()
        )
        defer { try? FileManager.default.removeItem(at: outcome.directory) }
        #expect(outcome.runs.count == 2)
        for run in outcome.runs {
            #expect(FileManager.default.fileExists(atPath: run.noisyURL.path))
            #expect(run.uncorrectedSNR.isFinite || run.uncorrectedSNR.isInfinite)
        }
    }

    @Test("group generates one subject per draw")
    func groupSubjects() throws {
        var variability = SimulatorRunner.GroupVariability()
        variability.homogeneous = true
        let outcome = try SimulatorRunner.generateGroup(
            config: fastConfig(), name: "GroupTest",
            subjects: 2, groupSeed: 7, variability: variability,
            options: SimulatorRunner.Options()
        )
        defer { try? FileManager.default.removeItem(at: outcome.directory) }
        #expect(outcome.subjects.count == 2)
        for subject in outcome.subjects {
            #expect(FileManager.default.fileExists(atPath: subject.noisyURL.path))
        }
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

    @Test("scores a recording against its ground truth")
    func scoresAgainstTruth() throws {
        // Turn a couple of artifacts on so noisy actually differs from clean.
        var config = fastConfig()
        config.bcgEnabled = true
        config.blinksPerMinute = 20
        let generated = try SimulatorRunner.generate(config: config, name: "Score")
        defer { try? FileManager.default.removeItem(at: generated.directory) }

        // Score the noisy recording as if it were the "corrected" one, with the
        // clean recording as truth and noisy also as the uncorrected baseline.
        let outcome = try SimulatorRunner.score(
            truth: generated.cleanURL,
            corrected: generated.noisyURL,
            baseline: generated.noisyURL,
            label: "noisy-as-corrected"
        )

        #expect(!outcome.corrected.bands.isEmpty, "expected a per-band breakdown")
        #expect(!outcome.corrected.channels.isEmpty, "expected per-channel scores")
        #expect(outcome.baseline != nil, "baseline was supplied")
        #expect(outcome.corrected.broadbandSNR.isFinite || outcome.corrected.broadbandSNR.isInfinite)
    }

    @Test("scoring identical recordings is a near-perfect match")
    func scoringIdenticalIsPerfect() throws {
        let generated = try SimulatorRunner.generate(config: fastConfig(), name: "Perfect")
        defer { try? FileManager.default.removeItem(at: generated.directory) }
        // Clean vs clean: the residual is ~zero, so correlation should be ~1.
        let outcome = try SimulatorRunner.score(
            truth: generated.cleanURL, corrected: generated.cleanURL
        )
        #expect(outcome.corrected.broadbandCorrelation > 0.99)
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
