// Copyright-free US Government work; see LICENSE.
import Foundation
import Testing
@testable import EVA

@Suite("ERP group contrasts and CLI definitions")
struct ERPGroupAndOptionsTests {
    private var options: [String: [String]] { [
        "erp-condition": ["frequent:Frequent:freq:0.5", "target:Target:targ:0.3", "novel:Novel:novl:0.2"],
        "erp-peak": ["frequent:p1:180:4:30", "target:p1:300:8:60", "target:p2:500:-3:40:0.5", "novel:p1:450:-6:50"],
        "erp-mixture": ["target:0.1:0.2:0.3", "novel:0:0.5:0"],
        "erp-recipe": ["target:0.25:90:0.7:1.5"],
        "erp-reference": ["frequent"],
        "erp-contrast": ["target-vs-others:target=1,frequent=-0.5,novel=-0.5", "novel-vs-frequent:novel=1,frequent=-1"],
        "erp-noise": ["1.5"], "erp-noise-kind": ["smoothed"],
        "erp-peak-jitter": ["15"], "erp-width-jitter": ["0.1"]
    ] }

    private func config() throws -> SimulationConfig {
        var config = SimulationConfig.default
        var erp = ERPConfig()
        try ERPExperimentOptions.apply(options, to: &erp)
        config.erp = erp
        return config
    }

    @Test("Repeatable definitions preserve every condition, peak, mixture and unit")
    func definitions() throws {
        let config = try config(), erp = try #require(config.erp), design = try #require(erp.experiment)
        #expect(design.conditions.map(\.id) == ["frequent", "target", "novel"])
        #expect(design.conditions[1].peaks.count == 2)
        #expect(design.conditions[1].peaks[1].latencySeconds == 0.5)
        #expect(design.conditions[1].peaks[1].amplitudeMicrovolts == -3)
        #expect(design.conditions[1].peaks[1].widthSeconds == 0.04)
        #expect(design.conditions[1].peaks[1].occurrenceFraction == 0.5)
        #expect(abs(design.conditions[1].recipes.typicalFraction - 0.4) < 1e-12)
        #expect(design.conditions[1].recipes.divergentLatencyRangeSeconds == 0.09)
        #expect(design.independentLatencyJitterSDSeconds == 0.015)
        #expect(design.widthJitterFraction == 0.1)
        #expect(design.addedNoiseRMSMicrovolts == 1.5 && design.addedNoiseKind == .smoothed)
        #expect(design.resolvedGroupContrasts.count == 2)
        let roundTrip = try JSONDecoder().decode(SimulationConfig.self, from: JSONEncoder().encode(config))
        #expect(roundTrip.erp?.experiment == design)
    }

    @Test("CLI edits replace named peak lists but preserve unrelated conditions")
    func replacements() throws {
        var erp = try #require(config().erp)
        let original = erp.experiment!.conditions
        try ERPExperimentOptions.apply(["erp-peak": ["target:new:200:-2:20"]], to: &erp)
        #expect(erp.experiment!.conditions[1].peaks.map(\.id) == ["new"])
        #expect(erp.experiment!.conditions[0] == original[0])
        #expect(erp.experiment!.conditions[2] == original[2])
        try ERPExperimentOptions.apply(["erp-condition": ["only:Only:only:1"]], to: &erp)
        #expect(erp.experiment!.conditions.count == 1)
        #expect(erp.experiment!.conditions[0].peaks[0].id == "p1")
        #expect(erp.experiment!.referenceConditionID == "only")
        #expect(erp.experiment!.resolvedGroupContrasts.isEmpty)
    }

    @Test("Malformed definitions, duplicate IDs and invalid contrasts are rejected")
    func invalidDefinitions() throws {
        let invalid: [[String: [String]]] = [
            ["erp-condition": ["x:Name:X:0.5"]],
            ["erp-condition": ["x:Name:X:0.5", "x:Other:Y:0.5"]],
            ["erp-peak": ["missing:p1:300:8:60"]],
            ["erp-peak": ["target:p1:300:8:60", "target:p1:400:4:60"]],
            ["erp-peak": ["target:p1:NaN:8:60"]],
            ["erp-mixture": ["target:0.5:0.5:0.5"]],
            ["erp-mixture": ["target:0:0:0", "target:0:0:0"]],
            ["erp-recipe": ["target:0.3:50:2:1"]],
            ["erp-reference": ["missing"]],
            ["erp-contrast": ["x:target=1,standard=1"]],
            ["erp-contrast": ["x:target=1,missing=-1"]],
            ["erp-contrast": ["x:target=1,target=-1"]],
            ["erp-contrast": ["x:target=0,standard=0"]],
            ["erp-contrast": ["x:target=1,standard=-1", "x:target=-1,standard=1"]],
            ["erp-noise": ["1", "2"]],
            ["erp-noise-kind": ["pink"]],
            ["erp-experiment": ["false"]]
        ]
        for values in invalid {
            var erp = ERPConfig()
            #expect(throws: SimulateError.self) { try ERPExperimentOptions.apply(values, to: &erp) }
        }
    }

    @Test("Subject contrasts equal scaled population waveforms at every tested time")
    func waveformContrasts() throws {
        let base = try config(), reference = base.erp!.experiment!.conditions[0]
        let population = try #require(GroupSimulation.populationWaveformContrasts(base))
        for effect in [0.0, 0.4, 1.0, 1.8, -0.6] {
            var draw = GroupSimulation.draw(index: 0, groupSeed: 12, variation: .none, base: base)
            draw.erpEffectScale = effect
            let subject = GroupSimulation.configure(base, with: draw)
            let realized = try #require(GroupSimulation.populationWaveformContrasts(subject))
            #expect(subject.erp!.experiment!.conditions[0] == reference)
            for t in stride(from: 0.0, through: 1.0, by: 0.007) {
                for i in population.indices {
                    #expect(abs(realized[i].value(at: t) - effect * population[i].value(at: t)) < 1e-11)
                }
                let a = base.erp!.experiment!.conditions[1].value(at: t)
                let b = reference.value(at: t)
                #expect(abs(subject.erp!.experiment!.conditions[1].value(at: t) - (b + effect * (a - b))) < 1e-11)
            }
        }
        #expect(GroupSimulation.populationEffect(base) == nil)
        #expect(GroupSimulation.populationComponentEffects(base) == nil)
    }

    @Test("Truth agrees with configured subjects and draws are cohort-prefix stable")
    func groupTruth() throws {
        let base = try config()
        let small = (0..<3).map { GroupSimulation.draw(index: $0, groupSeed: 90, variation: GroupVariation(), base: base) }
        let large = (0..<7).map { GroupSimulation.draw(index: $0, groupSeed: 90, variation: GroupVariation(), base: base) }
        #expect(small.map(\.erpEffectScale) == Array(large.prefix(3)).map(\.erpEffectScale))
        let truth = GroupSimulation.truth(subjects: small, groupSeed: 90, variation: GroupVariation(), base: base)
        #expect(truth.erpEstimand == nil && truth.populationEffectMicrovolts == nil)
        #expect(truth.erpExperimentEstimand?.referenceConditionID == "frequent")
        for draw in small {
            let generated = try #require(GroupSimulation.populationWaveformContrasts(GroupSimulation.configure(base, with: draw)))
            let reported = try #require(draw.erpWaveformContrasts)
            for i in generated.indices {
                #expect(abs(generated[i].value(at: 0.31) - reported[i].value(at: 0.31)) < 1e-11)
            }
        }
        let decoded = try JSONDecoder().decode(GroupTruth.self, from: JSONEncoder().encode(truth))
        #expect(decoded.erpExperimentEstimand?.contrasts.map(\.id) == truth.erpExperimentEstimand?.contrasts.map(\.id))
    }

    @Test("Default group contrasts cover every non-reference condition")
    func defaultsAndHomogeneous() throws {
        var base = try config()
        base.erp!.experiment!.groupContrasts = nil
        #expect(base.erp!.experiment!.resolvedGroupContrasts.map(\.id) == ["target-minus-frequent", "novel-minus-frequent"])
        let draw = GroupSimulation.draw(index: 0, groupSeed: 4, variation: .none, base: base)
        let subject = GroupSimulation.configure(base, with: draw)
        #expect(subject.erp!.experiment == base.erp!.experiment)
        #expect(draw.erpEffectScale == 1)
        base.erp!.experiment!.groupReferenceConditionID = "novel"
        #expect(base.erp!.experiment!.resolvedGroupContrasts.map(\.id) == ["frequent-minus-novel", "target-minus-novel"])
    }

    private func cli(_ args: [String]) throws -> (Int32, String) {
        let executable = try #require(Bundle.main.executableURL).deletingLastPathComponent().appendingPathComponent("EVASimulate")
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = args
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @Test("CLI preserves repeated flags and generates a multi-condition cohort without an input file")
    func inlineCLIGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ERPGroupTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelArgs = options.keys.sorted().flatMap { key in options[key]!.flatMap { ["--\(key)", $0] } }
            + ["--erp-trials", "10", "--erp-isi", "0.4", "--erp-isi-jitter", "0.1", "--erp-fit-duration",
               "--channels", "4", "--rate", "100", "--duration", "8", "--no-gradient", "--no-bcg"]
        let result = try cli(["generate-group", "--subjects", "2", "--homogeneous", "--erp-effect-sd", "0.3", "--output", root.path] + modelArgs)
        #expect(result.0 == 0, "\(result.1)")
        let truth = try JSONDecoder().decode(GroupTruth.self, from: Data(contentsOf: root.appendingPathComponent("group_truth.json")))
        #expect(truth.subjectCount == 2)
        #expect(truth.erpExperimentEstimand?.contrasts.count == 2)
        for subject in truth.subjects {
            let url = root.appendingPathComponent("sub-\(subject.label)/sim_truth.json")
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let trials = try #require(json["erpTrials"] as? [[String: Any]])
            #expect(trials.count == 10)
            #expect(Set(trials.compactMap { $0["eventCode"] as? String }) == Set(["freq", "targ", "novl"]))
            #expect(subject.erpWaveformContrasts?.count == 2)
        }
        let conflict = try cli(["generate", "--erp-experiment", "--erp-amplitude", "7", "--write-config", root.appendingPathComponent("bad.json").path])
        #expect(conflict.0 != 0)
        #expect(conflict.1.contains("Legacy shape options"))
    }
}
