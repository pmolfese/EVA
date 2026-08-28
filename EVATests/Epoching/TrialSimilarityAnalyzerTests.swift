//
//  TrialSimilarityAnalyzerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Synthetic trials with known ground truth: an attenuated trial, an inverted
//  one, a pure-noise one, and one carrying the wrong category's waveform. If the
//  analyzer cannot recover cases we built by hand, it has no business ranking
//  real ones.
//

import Testing
import Foundation
@testable import EVA

struct TrialSimilarityAnalyzerTests {

    private let samplingRate = 500.0
    private let sampleCount = 200
    private let stimulusOffset = 50

    /// A smooth deflection standing in for an ERP component.
    private func component(amplitude: Double, phase: Double = 0) -> [Float] {
        (0 ..< sampleCount).map { index in
            let t = Double(index - stimulusOffset) / samplingRate
            guard t >= 0, t <= 0.3 else { return 0 }
            return Float(amplitude * sin(.pi * t / 0.3 + phase))
        }
    }

    private func noise(seed: UInt64, scale: Double = 0.05) -> [Float] {
        var state = seed
        return (0 ..< sampleCount).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2 * scale)
        }
    }

    private func trial(_ samples: [Float], at seconds: Double = 0) -> SingleTrialAnalyzer.TrialInput {
        SingleTrialAnalyzer.TrialInput(
            sourceTimeSeconds: seconds,
            stimulusOffsetSamples: stimulusOffset,
            samples: samples
        )
    }

    private func combine(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map(+)
    }

    /// `count` ordinary trials: the same component plus independent noise.
    private func ordinaryTrials(count: Int, amplitude: Double = 1.0) -> [SingleTrialAnalyzer.TrialInput] {
        (0 ..< count).map { index in
            trial(
                combine(component(amplitude: amplitude), noise(seed: UInt64(index + 1))),
                at: Double(index)
            )
        }
    }

    private func analyze(
        _ categories: [TrialSimilarityAnalyzer.CategoryInput],
        reference: TrialSimilarityAnalyzer.Reference = .mean
    ) throws -> [TrialSimilarityAnalyzer.CategoryResult] {
        try #require(
            TrialSimilarityAnalyzer.analyze(
                categories: categories,
                samplingRate: samplingRate,
                windowStartMs: 0,
                windowEndMs: 300,
                reference: reference
            )
        )
    }

    // MARK: - The four readings

    @Test func ordinaryTrialsScoreHighOnShapeAndMagnitude() throws {
        let results = try analyze([.init(name: "A", trials: ordinaryTrials(count: 12))])
        let a = try #require(results.first)

        for row in a.trials {
            #expect(row.correlation > 0.9, "trial \(row.trialIndex) correlation \(row.correlation)")
            #expect(abs(row.slope - 1) < 0.25, "trial \(row.trialIndex) slope \(row.slope)")
            #expect(row.classification == .typical)
        }
    }

    @Test func aFlattenedResponseReadsAsAttenuatedNotDivergent() throws {
        // Shape intact, amplitude collapsed — the signature we care about most,
        // and the one a plain amplitude threshold reports as merely "small".
        var trials = ordinaryTrials(count: 12)
        trials[3] = trial(combine(component(amplitude: 0.1), noise(seed: 77)), at: 3)

        let results = try analyze([.init(name: "A", trials: trials)])
        let flagged = try #require(results.first?.trials.first { $0.trialIndex == 3 })

        #expect(flagged.correlation > 0.5, "shape should survive: \(flagged.correlation)")
        #expect(flagged.slope < 0.5, "amplitude should not: \(flagged.slope)")
        #expect(flagged.classification == .attenuated)
    }

    @Test func anInvertedTrialIsCalledInvertedRatherThanAttenuated() throws {
        var trials = ordinaryTrials(count: 12)
        trials[5] = trial(combine(component(amplitude: -1.0), noise(seed: 31)), at: 5)

        let results = try analyze([.init(name: "A", trials: trials)])
        let flagged = try #require(results.first?.trials.first { $0.trialIndex == 5 })

        #expect(flagged.slope < 0)
        #expect(flagged.classification == .inverted)
    }

    @Test func aPureNoiseTrialIsDivergent() throws {
        var trials = ordinaryTrials(count: 12)
        trials[7] = trial(noise(seed: 999, scale: 1.0), at: 7)

        let results = try analyze([.init(name: "A", trials: trials)])
        let flagged = try #require(results.first?.trials.first { $0.trialIndex == 7 })

        #expect(flagged.correlation < 0.5)
        #expect(flagged.normalizedResidualRMS > 0.5)
        #expect(flagged.classification == .divergent)
    }

    // MARK: - Mislabelling

    @Test func aTrialCarryingAnotherCategorysWaveformNamesThatCategory() throws {
        // The one claim here that is directly checkable rather than heuristic:
        // this trial is labelled A but is B's waveform.
        var aTrials = ordinaryTrials(count: 12, amplitude: 1.0)
        // Distinct times: two categories cannot contain the same event, and the
        // pooling derivation reads shared timestamps as exactly that.
        let bTrials = (0 ..< 12).map { index in
            trial(
                combine(component(amplitude: 1.0, phase: .pi), noise(seed: UInt64(index + 500))),
                at: 100 + Double(index)
            )
        }
        aTrials[4] = trial(combine(component(amplitude: 1.0, phase: .pi), noise(seed: 4242)), at: 4)

        let results = try analyze([
            .init(name: "A", trials: aTrials),
            .init(name: "B", trials: bTrials)
        ])

        let a = try #require(results.first { $0.name == "A" })
        let suspect = try #require(a.trials.first { $0.trialIndex == 4 })

        #expect(suspect.bestMatchingCategory == "B")
        #expect(suspect.matchesOwnCategory == false)
        #expect(a.possibleMislabels.map(\.trialIndex) == [4])
    }

    @Test func ordinaryTrialsMatchTheirOwnCategory() throws {
        let results = try analyze([
            .init(name: "A", trials: ordinaryTrials(count: 10)),
            .init(name: "B", trials: (0 ..< 10).map { index in
                trial(combine(component(amplitude: 1.0, phase: .pi), noise(seed: UInt64(index + 900))), at: 100 + Double(index))
            })
        ])

        for category in results {
            #expect(category.possibleMislabels.isEmpty, "\(category.name) flagged a mislabel it should not have")
        }
    }

    @Test func aNoiseTrialDoesNotGetAccusedOfBeingMislabelled() throws {
        // A pure-noise trial correlates with nothing, so it still has a "best"
        // match — whichever category wins by luck. Naming that category would be
        // a false accusation on the one measure here meant to be checkable.
        var aTrials = ordinaryTrials(count: 12)
        aTrials[6] = trial(noise(seed: 555, scale: 1.0), at: 6)
        let bTrials = (0 ..< 12).map { index in
            trial(combine(component(amplitude: 1.0, phase: .pi), noise(seed: UInt64(index + 700))), at: 100 + Double(index))
        }

        let results = try analyze([
            .init(name: "A", trials: aTrials),
            .init(name: "B", trials: bTrials)
        ])
        let a = try #require(results.first { $0.name == "A" })
        let noisy = try #require(a.trials.first { $0.trialIndex == 6 })

        #expect(noisy.classification == .divergent, "it is still divergent")
        #expect(noisy.matchesOwnCategory, "but not a mislabel: best r was \(noisy.bestMatchingCorrelation ?? -1)")
        #expect(a.possibleMislabels.isEmpty)
    }

    @Test func twoSimilarCategoriesDoNotAccuseEachOtherOnANearTie() throws {
        // Nearly identical conditions: every trial correlates about equally with
        // both averages. Without the margin, half of them would be "mislabelled".
        let aTrials = ordinaryTrials(count: 14, amplitude: 1.0)
        let bTrials = (0 ..< 14).map { index in
            trial(combine(component(amplitude: 1.02), noise(seed: UInt64(index + 3000))), at: 100 + Double(index))
        }

        let results = try analyze([
            .init(name: "A", trials: aTrials),
            .init(name: "B", trials: bTrials)
        ])
        for category in results {
            #expect(category.possibleMislabels.isEmpty, "\(category.name) accused \(category.possibleMislabels.count)")
        }
    }

    // MARK: - Pooled categories

    /// LC++/RC++ pooled into "correct", LI++/RI++ into "incorrect", built the
    /// way PSA builds them: one event fans out to its own code AND its group, so
    /// the pooled category literally contains the sub-category's trials, at the
    /// same `sourceTimeSeconds`.
    private func flankerCategories() -> [TrialSimilarityAnalyzer.CategoryInput] {
        func make(_ amplitude: Double, _ phase: Double, seed: UInt64, at times: [Double]) -> [SingleTrialAnalyzer.TrialInput] {
            times.enumerated().map { index, time in
                trial(combine(component(amplitude: amplitude, phase: phase), noise(seed: seed &+ UInt64(index))), at: time)
            }
        }
        let lcTimes = (0 ..< 10).map { Double($0) * 2 }
        let rcTimes = (0 ..< 10).map { Double($0) * 2 + 1 }
        let liTimes = (0 ..< 10).map { 100 + Double($0) * 2 }
        let riTimes = (0 ..< 10).map { 100 + Double($0) * 2 + 1 }

        // Two "correct" conditions that differ a little; the "incorrect" pair is
        // clearly different from both.
        let lc = make(1.0, 0.0, seed: 10, at: lcTimes)
        let rc = make(1.0, 0.5, seed: 20, at: rcTimes)
        let li = make(1.0, .pi, seed: 30, at: liTimes)
        let ri = make(1.0, .pi - 0.5, seed: 40, at: riTimes)

        return [
            .init(name: "LC++", trials: lc),
            .init(name: "RC++", trials: rc),
            .init(name: "LI++", trials: li),
            .init(name: "RI++", trials: ri),
            .init(name: "correct", trials: lc + rc),
            .init(name: "incorrect", trials: li + ri)
        ]
    }

    @Test func poolingIsDerivedFromTheTrialsThemselves() {
        let relations = TrialSimilarityAnalyzer.pooledRelations(flankerCategories())

        // "correct" holds LC++ and RC++ trials, so all three overlap.
        #expect(relations["correct"] == ["LC++", "RC++"])
        #expect(relations["LC++"] == ["correct"])
        #expect(relations["RC++"] == ["correct"])
        // And nothing crosses to the other pool.
        #expect(relations["LC++"]?.contains("LI++") == false)
        #expect(relations["correct"]?.contains("incorrect") == false)
    }

    @Test func aPooledCategoryDoesNotAccuseItsOwnMembers() throws {
        // The bug this fixes: every "correct" trial resembles its own
        // sub-condition more than the pool, because the pool is diluted by the
        // other condition. Left unhandled it flagged nearly every trial.
        let results = try analyze(flankerCategories())
        let pooled = try #require(results.first { $0.name == "correct" })

        #expect(pooled.possibleMislabels.isEmpty,
                "accused \(pooled.possibleMislabels.map(\.trialIndex))")
    }

    @Test func lcMatchingRcIsNotLCButIsStillCorrect() throws {
        // The user's rule, verbatim: LC yes to RC is "LC no, correct yes".
        let results = try analyze(flankerCategories())
        let lc = try #require(results.first { $0.name == "LC++" })

        for row in lc.trials where row.bestMatchingCategory == "RC++" || row.bestMatchingCategory == "correct" {
            #expect(row.matchesOwnPool, "trial \(row.trialIndex) was accused for matching a pool sibling")
        }
        #expect(lc.possibleMislabels.isEmpty)
    }

    @Test func aTrialResemblingTheOtherPoolIsStillAMislabel() throws {
        // And the rule has to keep working: LC++ looking like LI++ crosses the
        // pool boundary and is a real labelling claim.
        var categories = flankerCategories()
        guard let lcIndex = categories.firstIndex(where: { $0.name == "LC++" }),
              let correctIndex = categories.firstIndex(where: { $0.name == "correct" }) else {
            Issue.record("fixture shape changed")
            return
        }
        let planted = trial(combine(component(amplitude: 1.0, phase: .pi), noise(seed: 8080)), at: 4)
        categories[lcIndex].trials[2] = planted
        // The pooled category holds the same trial, since it is the same event.
        categories[correctIndex].trials[2] = planted

        let results = try analyze(categories)
        let lc = try #require(results.first { $0.name == "LC++" })
        let suspect = try #require(lc.trials.first { $0.trialIndex == 2 })

        #expect(suspect.matchesOwnPool == false, "best was \(suspect.bestMatchingCategory ?? "?")")
        #expect(lc.possibleMislabels.map(\.trialIndex).contains(2))
    }

    @Test func explicitPoolingOverridesTheDerivedRelation() throws {
        // For callers that know their grouping and would rather say so.
        var categories = flankerCategories()
        guard let index = categories.firstIndex(where: { $0.name == "LC++" }) else {
            Issue.record("fixture shape changed")
            return
        }
        categories[index].pooledWith = []

        let relations = TrialSimilarityAnalyzer.pooledRelations(categories)
        #expect(relations["LC++"] == [])
    }

    // MARK: - Leave-one-out

    @Test func leaveOneOutRemovesATrialsInfluenceOnItsOwnScore() throws {
        // A noise trial included in its own reference correlates with itself.
        // With only a handful of trials that self-contribution is large, and it
        // is exactly what would hide the trial we are hunting.
        var trials = ordinaryTrials(count: 4)
        trials[0] = trial(noise(seed: 12345, scale: 1.0), at: 0)

        let results = try analyze([.init(name: "A", trials: trials)])
        let looRow = try #require(results.first?.trials.first { $0.trialIndex == 0 })

        // Same trial, scored against an average that includes it.
        let naiveAverage = try #require(TrialSimilarityAnalyzer.average(trials, reference: .mean))
        let window = try #require(
            SingleTrialAnalyzer.sampleRange(
                startMs: 0, endMs: 300,
                stimulusOffsetSamples: stimulusOffset,
                samplingRate: samplingRate,
                length: sampleCount
            )
        )
        let trialWindow = trials[0].samples[window].map(Double.init)
        let naiveWindow = Array(naiveAverage[window])
        let naive = TrialSimilarityAnalyzer.regression(of: trialWindow, on: naiveWindow)

        #expect(naive.correlation > looRow.correlation,
                "LOO \(looRow.correlation) should be below naive \(naive.correlation)")
    }

    // MARK: - Robustness

    @Test func theMADThresholdIsNotInflatedByTheOutliersItLooksFor() throws {
        // Three wild trials out of fifteen. An SD-based rule widens until they
        // stop qualifying; a MAD-based one does not.
        var trials = ordinaryTrials(count: 15)
        for index in [2, 8, 11] {
            trials[index] = trial(noise(seed: UInt64(index * 77), scale: 3.0), at: Double(index))
        }

        let results = try analyze([.init(name: "A", trials: trials)])
        let flagged = Set(
            try #require(results.first).trials
                .filter { $0.classification == .divergent }
                .map(\.trialIndex)
        )
        #expect(flagged.isSuperset(of: [2, 8, 11]), "flagged \(flagged.sorted())")
    }

    @Test func aMedianReferenceIsBarelyMovedByOneWildTrial() throws {
        var trials = ordinaryTrials(count: 11)
        trials[0] = trial(component(amplitude: 25), at: 0)

        let mean = try #require(TrialSimilarityAnalyzer.average(trials, reference: .mean))
        let median = try #require(TrialSimilarityAnalyzer.average(trials, reference: .median))
        let clean = try #require(TrialSimilarityAnalyzer.average(Array(trials.dropFirst()), reference: .mean))

        func distance(_ a: [Double], _ b: [Double]) -> Double {
            sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
        }
        #expect(distance(median, clean) < distance(mean, clean))
    }

    // MARK: - Guards

    @Test func aCategoryWithOneTrialIsSkippedRatherThanScoredAgainstNothing() throws {
        let results = TrialSimilarityAnalyzer.analyze(
            categories: [.init(name: "A", trials: ordinaryTrials(count: 1))],
            samplingRate: samplingRate,
            windowStartMs: 0,
            windowEndMs: 300
        )
        #expect(results == nil)
    }

    @Test func aFlatReferenceYieldsNoShapeRatherThanADivideByZero() {
        let flat = [Double](repeating: 0, count: 50)
        let values = (0 ..< 50).map { Double($0) }
        let fit = TrialSimilarityAnalyzer.regression(of: values, on: flat)
        #expect(fit.slope == 0)
        #expect(fit.correlation == 0)
        #expect(TrialSimilarityAnalyzer.normalizedResidualRMS(values, flat) == 0)
    }
}
