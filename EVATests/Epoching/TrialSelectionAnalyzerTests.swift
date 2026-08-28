//
//  TrialSelectionAnalyzerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The exclusion rules, and the null that keeps their payoff honest.
//

import Testing
import Foundation
@testable import EVA

struct TrialSelectionAnalyzerTests {

    private func similarity(
        index: Int,
        r: Double = 0.95,
        slope: Double = 1.0,
        residual: Double = 0.2,
        distance: Double = 0.5,
        classification: TrialSimilarityAnalyzer.Classification = .typical,
        matchesOwn: Bool = true
    ) -> TrialSimilarityAnalyzer.TrialSimilarity {
        TrialSimilarityAnalyzer.TrialSimilarity(
            id: index,
            trialIndex: index,
            sourceTimeSeconds: Double(index),
            correlation: r,
            slope: slope,
            normalizedResidualRMS: residual,
            robustDistance: distance,
            bestMatchingCategory: matchesOwn ? "A" : "B",
            bestMatchingCorrelation: r,
            matchesOwnCategory: matchesOwn,
            matchesOwnPool: matchesOwn,
            classification: classification
        )
    }

    // MARK: - Rules

    @Test func noCriteriaExcludesNothing() {
        let trials = (0 ..< 5).map { similarity(index: $0) }
        #expect(TrialSelectionAnalyzer.exclusions(from: trials, criteria: .none).isEmpty)
        #expect(TrialSelectionAnalyzer.Criteria.none.isActive == false)
    }

    @Test func eachBoundExcludesOnItsOwnMeasure() {
        let trials = [
            similarity(index: 0, r: 0.1),
            similarity(index: 1, slope: 0.05),
            similarity(index: 2, residual: 0.9),
            similarity(index: 3, distance: 6.0),
            similarity(index: 4)
        ]
        var criteria = TrialSelectionAnalyzer.Criteria()
        criteria.minCorrelation = 0.3
        criteria.minSlope = 0.4
        criteria.maxResidualRMS = 0.6
        criteria.maxRobustDistance = 3.0

        let excluded = TrialSelectionAnalyzer.exclusions(from: trials, criteria: criteria)
        #expect(excluded.map(\.trialIndex) == [0, 1, 2, 3])
        #expect(excluded.first { $0.trialIndex == 0 }?.reasons.first?.hasPrefix("r <") == true)
    }

    @Test func aTrialFailingSeveralRulesReportsAllOfThem() {
        let trials = [similarity(index: 0, r: 0.05, slope: 0.02, residual: 0.95)]
        var criteria = TrialSelectionAnalyzer.Criteria()
        criteria.minCorrelation = 0.3
        criteria.minSlope = 0.4
        criteria.maxResidualRMS = 0.6

        let excluded = TrialSelectionAnalyzer.exclusions(from: trials, criteria: criteria)
        #expect(excluded.count == 1)
        #expect(excluded[0].reasons.count == 3)
    }

    @Test func classificationAndMislabelRulesWork() {
        let trials = [
            similarity(index: 0, classification: .divergent),
            similarity(index: 1, classification: .attenuated),
            similarity(index: 2, matchesOwn: false),
            similarity(index: 3)
        ]

        var byClass = TrialSelectionAnalyzer.Criteria()
        byClass.excludedClassifications = [.divergent]
        #expect(TrialSelectionAnalyzer.exclusions(from: trials, criteria: byClass).map(\.trialIndex) == [0])

        var byMislabel = TrialSelectionAnalyzer.Criteria()
        byMislabel.excludesMislabels = true
        let mislabelled = TrialSelectionAnalyzer.exclusions(from: trials, criteria: byMislabel)
        #expect(mislabelled.map(\.trialIndex) == [2])
        #expect(mislabelled[0].reasons.first?.contains("B") == true)
    }

    // MARK: - Synthetic trials for the outcome

    private func trialSet(
        count: Int = 24,
        channels: Int = 4,
        samples: Int = 120,
        noisyIndices: Set<Int> = []
    ) -> [[[Float]]] {
        var state: UInt64 = 4242
        func noise(_ scale: Double) -> Float {
            state = state &* 6364136223846793005 &+ 1
            return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2 * scale)
        }
        return (0 ..< count).map { index in
            let scale = noisyIndices.contains(index) ? 8.0 : 0.4
            return (0 ..< channels).map { _ in
                (0 ..< samples).map { sample in
                    let t = Double(sample - 20) / 100
                    let signal = t >= 0 && t <= 0.6 ? sin(.pi * t / 0.6) * 5 : 0
                    return Float(signal) + noise(scale)
                }
            }
        }
    }

    // MARK: - Outcome

    @Test func droppingGenuinelyNoisyTrialsRaisesSNRBeyondTheNull() throws {
        let noisy: Set<Int> = [3, 9, 15, 20]
        let trials = trialSet(noisyIndices: noisy)

        let outcome = try #require(
            TrialSelectionAnalyzer.evaluate(
                trials: trials,
                excludedIndices: noisy,
                baselineSampleCount: 20,
                permutations: 120
            )
        )

        #expect(outcome.keptCount == trials.count - noisy.count)
        #expect(outcome.excludedCount == noisy.count)

        let observed = try #require(outcome.observedChange)
        #expect(observed > 0)

        // The point of the null: dropping four trials at random does not do
        // this, so most of the gain is not merely "fewer trials".
        let percentile = try #require(outcome.percentileAmongNull)
        #expect(percentile > 0.9, "observed \(observed) sat at percentile \(percentile)")
        let beyond = try #require(outcome.changeBeyondNull)
        #expect(beyond > 0)
    }

    @Test func droppingOrdinaryTrialsLandsInTheMiddleOfTheNull() throws {
        // Nothing wrong with any of them: excluding four arbitrary trials should
        // look exactly like the null, which is what stops a threshold slider
        // from flattering every setting it is dragged to.
        let trials = trialSet()

        let outcome = try #require(
            TrialSelectionAnalyzer.evaluate(
                trials: trials,
                excludedIndices: [1, 5, 11, 17],
                baselineSampleCount: 20,
                permutations: 200
            )
        )

        let percentile = try #require(outcome.percentileAmongNull)
        #expect(percentile > 0.05 && percentile < 0.95, "percentile \(percentile)")
    }

    @Test func theNullIsReproducibleForTheSameSelection() throws {
        let trials = trialSet()
        let first = try #require(
            TrialSelectionAnalyzer.evaluate(trials: trials, excludedIndices: [2, 4], baselineSampleCount: 20, permutations: 40)
        )
        let second = try #require(
            TrialSelectionAnalyzer.evaluate(trials: trials, excludedIndices: [2, 4], baselineSampleCount: 20, permutations: 40)
        )
        #expect(first.nullChanges == second.nullChanges)
    }

    @Test func anEmptySelectionSkipsTheNullEntirely() throws {
        let trials = trialSet()
        let outcome = try #require(
            TrialSelectionAnalyzer.evaluate(trials: trials, excludedIndices: [], baselineSampleCount: 20)
        )
        #expect(outcome.excludedCount == 0)
        #expect(outcome.nullChanges.isEmpty)
        #expect(outcome.percentileAmongNull == nil)
    }

    @Test func tooFewTrialsToSayAnythingReturnsNil() {
        let trials = trialSet(count: 3)
        #expect(TrialSelectionAnalyzer.evaluate(trials: trials, excludedIndices: [0], baselineSampleCount: 5) == nil)

        // And a selection that would leave fewer than two trials.
        let plenty = trialSet(count: 10)
        #expect(
            TrialSelectionAnalyzer.evaluate(
                trials: plenty,
                excludedIndices: Set(0 ..< 9),
                baselineSampleCount: 5
            ) == nil
        )
    }

    // MARK: - The draw

    @Test func randomSubsetIsTheRightSizeAndInRange() {
        var generator = SeededGenerator(seed: 7)
        for wanted in [1, 5, 20] {
            let subset = TrialSelectionAnalyzer.randomSubset(count: wanted, from: 20, using: &generator)
            #expect(subset.count == min(wanted, 20))
            #expect(subset.allSatisfy { $0 >= 0 && $0 < 20 })
        }
    }

    @Test func randomSubsetCoversTheWholeRangeOverManyDraws() {
        var generator = SeededGenerator(seed: 11)
        var seen: Set<Int> = []
        for _ in 0 ..< 400 {
            seen.formUnion(TrialSelectionAnalyzer.randomSubset(count: 2, from: 25, using: &generator))
        }
        // A biased draw would leave part of the range untouched.
        #expect(seen.count == 25, "only saw \(seen.count) of 25")
    }
}
