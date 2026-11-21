// Copyright-free US Government work; see LICENSE.
import Foundation
import Testing
@testable import EVA

@Suite("Editable ERP experiments")
struct ERPExperimentTests {
    private func design() -> ERPConfig {
        var erp = ERPConfig()
        erp.trialCount = 100
        erp.omissionRate = 0
        erp.latencyJitterSDSeconds = 0
        erp.amplitudeJitterFraction = 0
        erp.interStimulusJitterSeconds = 0
        erp.experiment = ERPExperimentConfig(conditions: [
            ERPConditionConfig(id: "frequent", name: "Frequent", eventCode: "freq", fraction: 0.5,
                               peaks: [ERPWaveformPeak(id: "p1", amplitudeMicrovolts: 4)]),
            ERPConditionConfig(id: "target", name: "Target", eventCode: "targ", fraction: 0.3,
                               peaks: [ERPWaveformPeak(id: "p1")]),
            ERPConditionConfig(id: "novel", name: "Novel", eventCode: "novl", fraction: 0.2,
                               peaks: [ERPWaveformPeak(id: "p1", amplitudeMicrovolts: -6)])
        ])
        return erp
    }

    @Test("Three conditions have exact counts, deterministic order, and independent signed waveforms")
    func conditionCounts() throws {
        let erp = design()
        let a = try ERPExperimentSampler.trials(erp: erp, seed: 42)
        let b = try ERPExperimentSampler.trials(erp: erp, seed: 42)
        let c = try ERPExperimentSampler.trials(erp: erp, seed: 43)
        #expect((0..<3).map { n in a.filter { $0.conditionIndex == n }.count } == [50, 30, 20])
        #expect(a.map(\.conditionIndex) == b.map(\.conditionIndex))
        #expect(a.map(\.conditionIndex) != c.map(\.conditionIndex))
        for trial in a {
            #expect(abs(trial.value(at: 0.3) - [4.0, 8, -6][trial.conditionIndex]) < 1e-12)
        }
    }

    @Test("Largest remainder conserves trials including tiny and zero-share conditions")
    func rounding() throws {
        #expect(ERPExperimentSampler.counts(total: 7, fractions: [0.5, 0.3, 0.2]) == [4, 2, 1])
        #expect(ERPExperimentSampler.counts(total: 2, fractions: [0.01, 0, 0.99]) == [0, 0, 2])
        var erp = design()
        erp.trialCount = 7
        #expect(try ERPExperimentSampler.trials(erp: erp, seed: 1).count == 7)
    }

    @Test("Recipe percentages exclude omissions and produce exact allocated counts")
    func recipesAndOmissions() throws {
        var erp = design()
        erp.omissionRate = 0.2
        for i in erp.experiment!.conditions.indices {
            erp.experiment!.conditions[i].recipes = ERPTrialRecipeMix(
                attenuatedFraction: 0.25, invertedFraction: 0.25, divergentFraction: 0.25)
        }
        let trials = try ERPExperimentSampler.trials(erp: erp, seed: 42)
        for (i, total) in [50, 30, 20].enumerated() {
            let subset = trials.filter { $0.conditionIndex == i }
            #expect(subset.filter { $0.recipe == .omitted }.count == total / 5)
            for recipe in [ERPTrialRecipe.typical, .attenuated, .inverted, .divergent] {
                #expect(subset.filter { $0.recipe == recipe }.count == total / 5)
            }
        }
        #expect(trials.filter { $0.recipe == .omitted }.allSatisfy { $0.value(at: 0.3) == 0 && $0.peaks.allSatisfy { !$0.present } })
        for trial in trials where trial.recipe == .inverted {
            #expect(abs(trial.value(at: 0.3) + [4.0, 8, -6][trial.conditionIndex]) < 1e-12)
        }
        for trial in trials where trial.recipe == .attenuated {
            #expect(abs(trial.value(at: 0.3) - 0.3 * [4.0, 8, -6][trial.conditionIndex]) < 1e-12)
        }
    }

    @Test("Peak occurrence controls only the selected component among responding trials")
    func partialPeaks() throws {
        var erp = design()
        erp.omissionRate = 0.2
        erp.experiment!.conditions[0].peaks[0].occurrenceFraction = 0.5
        erp.experiment!.conditions[0].peaks.append(ERPWaveformPeak(id: "p2", latencySeconds: 0.5, amplitudeMicrovolts: -3))
        let trials = try ERPExperimentSampler.trials(erp: erp, seed: 5).filter { $0.conditionIndex == 0 }
        #expect(trials.filter { $0.peaks[0].present }.count == 20)
        #expect(trials.filter { $0.peaks[1].present }.count == 40)
        #expect(trials.filter { $0.recipe != .omitted && !$0.peaks[0].present }.allSatisfy { $0.peaks[1].amplitudeMicrovolts == -3 })
    }

    @Test("Whole-response jitter preserves relative peak timing; independent jitter changes it")
    func jitterScope() throws {
        var erp = design()
        erp.latencyJitterSDSeconds = 0.02
        erp.experiment!.conditions[0].peaks.append(ERPWaveformPeak(id: "p2", latencySeconds: 0.5))
        let shared = try ERPExperimentSampler.trials(erp: erp, seed: 8).filter { $0.conditionIndex == 0 }
        #expect(shared.allSatisfy { abs($0.peaks[1].latencySeconds - $0.peaks[0].latencySeconds - 0.2) < 1e-12 })
        erp.experiment!.independentLatencyJitterSDSeconds = 0.02
        let independent = try ERPExperimentSampler.trials(erp: erp, seed: 8).filter { $0.conditionIndex == 0 }
        #expect(independent.contains { abs($0.peaks[1].latencySeconds - $0.peaks[0].latencySeconds - 0.2) > 0.001 })
    }

    @Test("ISI variation changes intervals within the requested range, independently of response settings")
    func intervals() throws {
        var erp = design()
        erp.startSeconds = 0
        erp.interStimulusIntervalSeconds = 0.4
        erp.interStimulusJitterSeconds = 0.3
        let trials = try ERPExperimentSampler.trials(erp: erp, seed: 6)
        #expect(trials[0].onsetSeconds == 0)
        let gaps = zip(trials.dropFirst(), trials).map { $0.onsetSeconds - $1.onsetSeconds }
        #expect(gaps.allSatisfy { $0 >= 0.1 && $0 <= 0.7 })
        #expect(Set(gaps).count > 1)
        erp.experiment!.addedNoiseRMSMicrovolts = 4
        erp.latencyJitterSDSeconds = 0.1
        #expect(try ERPExperimentSampler.trials(erp: erp, seed: 6).map(\.onsetSeconds) == trials.map(\.onsetSeconds))
    }

    @Test("Invalid shares, recipes, event codes, jitter, and nonfinite peaks fail before generation")
    func validation() throws {
        let changes: [(inout ERPConfig) -> Void] = [
            { $0.experiment!.conditions[0].fraction = 0.9 },
            { $0.experiment!.conditions[0].recipes.invertedFraction = 1.1 },
            { $0.experiment!.conditions[0].eventCode = "targ" },
            { $0.experiment!.conditions[0].eventCode = "TREV" },
            { $0.experiment!.conditions[0].eventCode = "a&b" },
            { $0.experiment!.conditions[0].name = "target" },
            { $0.experiment!.conditions[0].peaks[0].widthSeconds = 0 },
            { $0.experiment!.conditions[0].peaks[0].amplitudeMicrovolts = .infinity },
            { $0.experiment!.conditions[0].peaks[0].occurrenceFraction = -0.1 },
            { $0.experiment!.conditions = [] },
            { $0.interStimulusJitterSeconds = $0.interStimulusIntervalSeconds },
            { $0.latencyJitterSDSeconds = -0.01 },
            { $0.trialCount = 0 }
        ]
        for change in changes {
            var erp = design(); change(&erp)
            #expect(throws: SimulateError.self) { try ERPExperimentSampler.trials(erp: erp, seed: 1) }
        }
    }

    @Test("New designs round-trip while old scenarios retain their original generation path")
    func roundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let erp = design()
        let roundTrip = try JSONDecoder().decode(ERPConfig.self, from: encoder.encode(erp))
        #expect(roundTrip.experiment == erp.experiment)
        let old = ERPConfig()
        let data = try encoder.encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("experiment"))
        #expect(try JSONDecoder().decode(ERPConfig.self, from: data).experiment == nil)
        #expect(ERPExperimentConfig.editing(old)?.conditions.count == 2)
        var placed = old; placed.components = [ERPComponentConfig()]
        #expect(ERPExperimentConfig.editing(placed) == nil)
    }

    @Test("Gaussian noise has configured RMS and does not alter clean channels")
    func sensorNoise() {
        var config = SimulationConfig.default
        config.samplingRate = 1000
        config.erp = design()
        config.erp!.experiment!.addedNoiseRMSMicrovolts = 3
        let clean = [[Double]](repeating: [Double](repeating: 0, count: 100_000), count: 2)
        var noisy = clean, repeatNoisy = clean
        ERPExperimentSampler.addSensorNoise(to: &noisy, config: config)
        ERPExperimentSampler.addSensorNoise(to: &repeatNoisy, config: config)
        #expect(noisy == repeatNoisy)
        #expect(noisy[0] != noisy[1])
        #expect(clean[0].allSatisfy { $0 == 0 })
        let rms = sqrt(noisy[0].reduce(0) { $0 + $1 * $1 } / Double(noisy[0].count))
        #expect(abs(rms - 3) < 0.04)
        let smooth = ERPExperimentSampler.noise(count: 100_000, samplingRate: 1000, rms: 3, kind: .smoothed, seed: 42)
        let smoothRMS = sqrt(smooth.reduce(0) { $0 + $1 * $1 } / Double(smooth.count))
        #expect(abs(smoothRMS - 3) < 0.15)
    }

    @Test("Injected multi-condition truth retains event identities, recipes, signed peaks and overlap")
    func injectedTruth() throws {
        var config = SimulationConfig.default
        config.channelCount = 4; config.samplingRate = 100; config.durationSeconds = 12
        var erp = design(); erp.trialCount = 10; erp.interStimulusIntervalSeconds = 0.5
        config.erp = erp
        let empty = [[Double]](repeating: [Double](repeating: 0, count: config.sampleCount), count: 4)
        var channels = empty, other = empty
        let montage = Montage.standard(count: 4)
        let injection = try #require(ERPGenerator.inject(into: &channels, config: config, montage: montage))
        _ = try ERPGenerator.inject(into: &other, config: config, montage: montage)
        #expect(channels == other)
        #expect(Set(injection.trials.map(\.eventCode)) == Set(["freq", "targ", "novl"]))
        #expect(injection.components.count == 3)
        #expect(injection.trials.allSatisfy { $0.recipe == .typical && $0.realizedPeaks?.count == 1 })
        #expect(injection.trials.filter { $0.condition == "novel" }.allSatisfy { abs($0.peakAmplitudeMicrovolts + 6) < 1e-12 })
        #expect(injection.trials.contains { $0.overlapsAnotherTrial == true })
        config.durationSeconds = 2
        #expect(throws: SimulateError.self) { try ERPGenerator.inject(into: &other, config: config, montage: montage) }
    }

    @Test("All-omitted and single-condition experiments are valid")
    func allOmitted() throws {
        var erp = design()
        erp.experiment!.conditions = [erp.experiment!.conditions[0]]
        erp.experiment!.conditions[0].fraction = 1
        erp.omissionRate = 1
        let trials = try ERPExperimentSampler.trials(erp: erp, seed: 42)
        #expect(trials.count == 100)
        #expect(trials.allSatisfy { $0.recipe == .omitted && $0.value(at: 0.3) == 0 })
    }
}
