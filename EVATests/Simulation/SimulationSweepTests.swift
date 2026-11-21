// Copyright-free US Government work; see LICENSE.
import Foundation
import Testing
@testable import EVA

@Suite("Single-subject sweeps and evaluation")
struct SimulationSweepTests {
    func base() -> SimulationConfig {
        var c = SimulationConfig.default
        var erp = ERPConfig(); erp.experiment = ERPExperimentConfig(); erp.trialCount = 10
        erp.interStimulusIntervalSeconds = 0.5; erp.interStimulusJitterSeconds = 0.1
        c.erp = erp; c.channelCount = 4; c.samplingRate = 200; c.durationSeconds = 10
        c.gradientEnabled = false; c.bcgEnabled = false
        return c
    }
    @Test("Lists and ascending/descending ranges reject malformed or nonfinite values")
    func values() throws {
        #expect(try SimulationSweep.values("0:0.3:0.1").count == 4)
        #expect(try SimulationSweep.values("3:1:-1") == [3,2,1])
        #expect(try SimulationSweep.values("-2, 0, 4") == [-2,0,4])
        for text in ["", "1,", "1,bad,2", "nan", "inf", "1,1", "0:1:0", "0:1:-1", "0:100000:1"] {
            #expect(throws: SimulateError.self) { try SimulationSweep.values(text) }
        }
    }
    @Test("Selected peaks change without modifying other conditions")
    func scopes() throws {
        var c = base(); let old = c.erp!.experiment!.conditions[0]
        try SimulationSweep.apply(.init(parameter: "erp-peak-amplitude", values: [-4], conditionID: "target", peakID: "p1"), value: -4, to: &c)
        #expect(c.erp!.experiment!.conditions[1].peaks[0].amplitudeMicrovolts == -4)
        #expect(c.erp!.experiment!.conditions[0] == old)
        #expect(throws: SimulateError.self) { try SimulationSweep.apply(.init(parameter: "erp-noise", values: [1], conditionID: "target"), value: 1, to: &c) }
        #expect(throws: SimulateError.self) { try SimulationSweep.apply(.init(parameter: "erp-peak-width", values: [20], conditionID: "target", peakID: "missing"), value: 20, to: &c) }
    }
    @Test("Shares redistribute proportionally; recipe sweeps consume only Typical")
    func fractions() throws {
        var c = base()
        c.erp!.experiment!.conditions.append(.init(id: "novel", name: "Novel", eventCode: "novl", fraction: 0.2))
        c.erp!.experiment!.conditions[0].fraction = 0.6
        try SimulationSweep.apply(.init(parameter: "erp-condition-share", values: [0.6], conditionID: "target"), value: 0.6, to: &c)
        #expect(abs(c.erp!.experiment!.conditions[0].fraction - 0.3) < 1e-12)
        #expect(abs(c.erp!.experiment!.conditions[2].fraction - 0.1) < 1e-12)
        c.erp!.experiment!.conditions[1].recipes.attenuatedFraction = 0.2
        try SimulationSweep.apply(.init(parameter: "erp-inverted", values: [0.3], conditionID: "target"), value: 0.3, to: &c)
        #expect(c.erp!.experiment!.conditions[1].recipes.typicalFraction == 0.5)
        try SimulationSweep.apply(.init(parameter: "erp-inverted", values: [0.9], conditionID: "target"), value: 0.9, to: &c)
        #expect(throws: SimulateError.self) { try c.erp!.experiment!.validate(erp: c.erp!) }
    }
    @Test("Background gain changes calibrated amplitude; artifact sweep semantics are explicit")
    func artifacts() throws {
        var c = base(); let original = c.eegTargetStdMicrovolts
        try SimulationSweep.apply(.init(parameter: "background-gain", values: [2]), value: 2, to: &c)
        #expect(c.eegTargetStdMicrovolts == original * 2)
        try SimulationSweep.apply(.init(parameter: "bcg-morphology", values: [0]), value: 0, to: &c)
        #expect(c.bcgEnabled && c.bcgSpatialModel == .generators && c.bcgMorphologyJitterFraction == 0)
        try SimulationSweep.apply(.init(parameter: "bad-channel-fraction", values: [0.5]), value: 0.5, to: &c)
        #expect(c.badChannelCount == 2)
    }
    func trial(_ onset: Double, id: String = "a") -> ERPTrialTruth {
        ERPTrialTruth(id: UUID().uuidString, condition: id, eventCode: "A", onsetSeconds: onset,
                      peakLatencySeconds: 0.2, peakTimeSeconds: onset + 0.2, peakAmplitudeMicrovolts: 2, omitted: false)
    }
    @Test("Identical recordings score perfectly; measured peak errors preserve sign and units")
    func exactEvaluation() throws {
        var clean = Array(repeating: 0.0, count: 500), noisy = clean
        clean[120] = -4; clean[320] = -4; noisy[125] = -6; noisy[325] = -6
        let options = SweepEvaluationOptions(mode: .average)
        let a = try SweepEvaluation.evaluate(clean: [clean], noisy: [clean], rate: 100, trials: [trial(1), trial(3)], conditions: [("a", "A")], options: options)[0]
        #expect(a.waveformRMSE == 0 && a.correlation == 1 && a.peakAmplitudeError == 0 && a.peakLatencyErrorMS == 0)
        let b = try SweepEvaluation.evaluate(clean: [clean], noisy: [noisy], rate: 100, trials: [trial(1), trial(3)], conditions: [("a", "A")], options: options)[0]
        #expect(b.peakAmplitudeError == -2 && b.peakLatencyErrorMS == 50)
        #expect(b.retained == 2 && b.candidates == 2)
    }
    @Test("Rejection uses noisy data and compares against all complete clean epochs")
    func rejection() throws {
        var clean = Array(repeating: 0.0, count: 500)
        clean[120] = 2; clean[320] = 6
        var noisy = clean; noisy[330] = 200
        let result = try SweepEvaluation.evaluate(clean: [clean], noisy: [noisy], rate: 100,
            trials: [trial(0.01), trial(1), trial(3), trial(4.8)], conditions: [("a", "A"), ("b", "B")], options: .init(mode: .reject))
        #expect(result[0].scheduled == 4 && result[0].candidates == 2 && result[0].retained == 1)
        #expect(result[0].peakAmplitudeError == -2) // retained 2 versus ALL-clean mean 4
        #expect(result[1].status == "no-complete-epochs" && result[1].waveformRMSE == nil)
        var options = SweepEvaluationOptions(mode: .reject); options.rejectionMicrovolts = 1
        let empty = try SweepEvaluation.evaluate(clean: [clean], noisy: [noisy], rate: 100, trials: [trial(1), trial(3)], conditions: [("a", "A")], options: options)[0]
        #expect(empty.status == "all-rejected" && empty.peakLatencyErrorMS == nil && empty.waveformRMSE == nil)
    }
    @Test("Undefined correlation and peaks remain missing, with finite counts")
    func zero() throws {
        let zero = [Array(repeating: 0.0, count: 300)]
        let e = try SweepEvaluation.evaluate(clean: zero, noisy: zero, rate: 100, trials: [trial(1)], conditions: [("a", "A")], options: .init(mode: .average))[0]
        #expect(e.waveformRMSE == 0 && e.correlation == nil && e.peakLatencyErrorMS == nil && e.retainedFraction == 1)
        var disabled = SweepEvaluationOptions(); disabled.preSeconds = .nan
        #expect(throws: SimulateError.self) { try disabled.validate() }
        var options = SweepEvaluationOptions(mode: .average); options.peakChannel = 2
        #expect(throws: SimulateError.self) { try options.validate(rate: 100, channels: 1) }
    }
    @Test("Aggregates omit missing values and use sample SD")
    func aggregation() {
        let plan = SimulationSweepPlan(axes: [.init(parameter: "erp-noise", values: [1])], repeats: 3)
        let report = SimulationSweepReport(plan: plan, baseSeed: 1, rows: [1.0, 3.0, nil].enumerated().map { i, x in
            SimulationSweepRow(value: 1, repetition: i+1, seed: UInt64(i), directory: "r", uncorrectedSNR: x, evaluations: [])
        })
        let a = report.aggregates(metric: .snr, condition: "")[0]
        #expect(a.count == 2 && a.mean == 2 && a.sd == sqrt(2))
    }
    private func cli(_ args: [String]) throws -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = try #require(Bundle.main.executableURL).deletingLastPathComponent().appendingPathComponent("EVASimulate")
        p.arguments = args; p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }
    @Test("CLI crosses axes, pairs repeated seeds, saves evaluation and reproduces recordings")
    func gridCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SweepGrid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let args = ["sweep", "--erp-experiment", "--erp-trials", "10", "--erp-isi", "0.4", "--erp-isi-jitter", "0.1",
                    "--channels", "4", "--rate", "200", "--duration", "8", "--no-gradient", "--no-bcg", "--no-impedance-noise", "--seed", "42",
                    "--parameter", "erp-noise", "--values", "0,3", "--parameter2", "erp-inverted", "--condition2", "target", "--values2", "0:0.5:0.5",
                    "--repeats", "2", "--evaluate", "average"]
        let a = try cli(args + ["--output", root.appendingPathComponent("a").path])
        #expect(a.0 == 0, "\(a.1)")
        let report = try JSONDecoder().decode(SimulationSweepReport.self, from: Data(contentsOf: root.appendingPathComponent("a/sweep_results.json")))
        #expect(report.rows.count == 8 && report.rows.allSatisfy { $0.evaluations.count == 2 })
        let preserved = try Data(contentsOf: root.appendingPathComponent("a/sweep_results.json"))
        let duplicate = try cli(args + ["--output", root.appendingPathComponent("a").path])
        #expect(duplicate.0 != 0 && duplicate.1.contains("already contains sweep results"))
        #expect(try Data(contentsOf: root.appendingPathComponent("a/sweep_results.json")) == preserved)
        #expect(Set(report.rows.filter { $0.repetition == 1 }.map(\.seed)) == [42])
        #expect(Set(report.rows.filter { $0.repetition == 2 }.map(\.seed)).count == 1)
        #expect(report.rows.filter { $0.value == 0 }.allSatisfy { $0.evaluations.allSatisfy { $0.waveformRMSE == 0 } })
        let b = try cli(args + ["--output", root.appendingPathComponent("b").path])
        #expect(b.0 == 0, "\(b.1)")
        for row in report.rows {
            for kind in ["clean", "noisy"] {
                let path = row.directory + "/sim_" + kind + ".mff/signal1.bin"
                #expect(try Data(contentsOf: root.appendingPathComponent("a/" + path)) == Data(contentsOf: root.appendingPathComponent("b/" + path)))
            }
        }
    }
    @Test("GUI runner reads grid JSON and resolves relocated run paths")
    func runner() throws {
        let plan = SimulationSweepPlan(axes: [.init(parameter: "erp-noise", values: [0, 1])], repeats: 2, evaluation: .init(mode: .average))
        let result = try SimulatorRunner.sweep(config: base(), name: "test", parameter: "erp-noise", values: [0,1], options: .init(), plan: plan)
        defer { try? FileManager.default.removeItem(at: result.directory) }
        #expect(result.report.rows.count == 4 && result.runs.count == 4)
        #expect(result.runs.allSatisfy { FileManager.default.fileExists(atPath: $0.noisyURL.path) })
    }
    @Test("Invalid later cells fail preflight without generating earlier recordings")
    func preflight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SweepInvalid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try cli(["sweep", "--erp-experiment", "--erp-trials", "10", "--parameter", "erp-inverted", "--values", "0,1.1", "--output", root.path])
        #expect(result.0 != 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test("Duration grows per cell, while fixed duration rejects an overflowing schedule")
    func duration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SweepDuration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let args = ["sweep", "--erp-experiment", "--erp-trials", "4", "--erp-isi", "0.5", "--erp-isi-jitter", "0",
                    "--channels", "4", "--rate", "200", "--duration", "5", "--no-gradient", "--no-bcg",
                    "--parameter", "erp-isi", "--values", "0.5,3", "--evaluate", "average"]
        let bad = try cli(args + ["--sweep-fixed-duration", "--output", root.appendingPathComponent("fixed").path])
        #expect(bad.0 != 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("fixed").path))
        let good = try cli(args + ["--output", root.appendingPathComponent("fit").path])
        #expect(good.0 == 0, "\(good.1)")
        let report = try JSONDecoder().decode(SimulationSweepReport.self, from: Data(contentsOf: root.appendingPathComponent("fit/sweep_results.json")))
        #expect(report.rows.allSatisfy { $0.evaluations.reduce(0) { $0 + $1.candidates } == 4 })
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fit/erp-isi-3/scenario.json"))) as? [String: Any])
        let config = try #require(json["config"] as? [String: Any])
        #expect((config["durationSeconds"] as? Double ?? 0) > 10)
    }

    @Test("CLI reject mode persists all-rejected status and refuses evaluation without ERPs")
    func rejectedCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SweepRejected-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let args = ["sweep", "--parameter", "background-gain", "--values", "1", "--evaluate", "reject", "--eval-reject", "0.0001",
                    "--channels", "4", "--rate", "200", "--duration", "8", "--no-gradient", "--no-bcg"]
        let missing = try cli(args + ["--no-erp", "--output", root.appendingPathComponent("missing").path])
        #expect(missing.0 != 0 && missing.1.contains("requires enabled ERP"))
        let result = try cli(args + ["--erp-experiment", "--erp-trials", "4", "--output", root.appendingPathComponent("rejected").path])
        #expect(result.0 == 0, "\(result.1)")
        let report = try JSONDecoder().decode(SimulationSweepReport.self, from: Data(contentsOf: root.appendingPathComponent("rejected/sweep_results.json")))
        #expect(report.rows[0].evaluations.allSatisfy { $0.status == "all-rejected" && $0.waveformRMSE == nil })
        #expect(report.aggregates(metric: .rmse, condition: "target").isEmpty)
    }

}
