//
//  EpochSNRDeterminismTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  `REWIND.md` determinism audit, item 1. The SME bootstrap drew from
//  `SystemRandomNumberGenerator`, so two runs over identical epochs reported
//  different SME — up to ~19% relative apart on categories with few trials.
//  These tests pin the fix and, just as importantly, pin that the fix did not
//  turn the bootstrap into something degenerate.
//

import Testing
import Foundation
@testable import EVA

struct EpochSNRDeterminismTests {

    /// Deterministic synthetic trials: a common evoked response plus per-trial
    /// noise from a seeded generator, so the *input* to the metrics is identical
    /// across runs and any variation must come from the metrics themselves.
    private func trials(count: Int, channels: Int = 8, samples: Int = 128) -> [[[Float]]] {
        var rng = SeededGenerator(seed: 12_345)
        let response = (0..<samples).map { Float(sin(2 * .pi * Double($0) / Double(samples))) * 5 }
        return (0..<count).map { _ in
            (0..<channels).map { _ in
                (0..<samples).map { sample in
                    response[sample] + Float.random(in: -3...3, using: &rng)
                }
            }
        }
    }

    /// The load-bearing one: paired runs must agree exactly, including SME.
    @Test func metricsAreReproducibleAcrossRuns() throws {
        let input = trials(count: 12)
        let a = EpochSNR.metrics(trials: input, baselineSampleCount: 32)
        let b = EpochSNR.metrics(trials: input, baselineSampleCount: 32)

        _ = try #require(a.standardizedMeasurementError, "SME should be computed at 12 trials")
        #expect(a.standardizedMeasurementError == b.standardizedMeasurementError)
        #expect(a.plusMinusSNR == b.plusMinusSNR)
        #expect(a.baselineSNR == b.baselineSNR)
        #expect(a.gfpSNR == b.gfpSNR)
        #expect(a.splitHalfReliability == b.splitHalfReliability)
        #expect(a.noiseCurve == b.noiseCurve)
    }

    /// The regression this replaces was worst on small categories, which is
    /// exactly where the bootstrap has the least to work with.
    @Test func smeIsReproducibleOnASmallCategory() {
        let input = trials(count: 5)
        let a = EpochSNR.metrics(trials: input, baselineSampleCount: 32)
        let b = EpochSNR.metrics(trials: input, baselineSampleCount: 32)
        #expect(a.standardizedMeasurementError == b.standardizedMeasurementError)
    }

    /// Reproducible is not the same as constant. A seed that collapsed the
    /// resampling — always drawing the same trial, say — would also be perfectly
    /// reproducible and completely useless, so pin that SME still responds to
    /// the data and still shrinks as trials accumulate.
    @Test func smeStillMeasuresSomething() {
        let noisy = EpochSNR.metrics(trials: trials(count: 8), baselineSampleCount: 32)
        let quiet = EpochSNR.metrics(trials: trials(count: 40), baselineSampleCount: 32)

        let noisySME = noisy.standardizedMeasurementError ?? 0
        let quietSME = quiet.standardizedMeasurementError ?? 0
        #expect(noisySME > 0, "a degenerate bootstrap would report zero variance")
        #expect(quietSME > 0)
        #expect(quietSME < noisySME, "SME should fall as trials accumulate")
    }

    @Test func smeRespondsToDifferentData() {
        let a = EpochSNR.metrics(trials: trials(count: 10, channels: 8), baselineSampleCount: 32)
        var scaled = trials(count: 10, channels: 8)
        for trial in scaled.indices {
            for channel in scaled[trial].indices {
                scaled[trial][channel] = scaled[trial][channel].map { $0 * 10 }
            }
        }
        let b = EpochSNR.metrics(trials: scaled, baselineSampleCount: 32)
        #expect(a.standardizedMeasurementError != b.standardizedMeasurementError)
    }

    // MARK: - The generator itself

    @Test func seededGeneratorIsReproducibleAndSeedDependent() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        var c = SeededGenerator(seed: 43)

        let fromA = (0..<64).map { _ in a.next() }
        let fromB = (0..<64).map { _ in b.next() }
        let fromC = (0..<64).map { _ in c.next() }

        #expect(fromA == fromB)
        #expect(fromA != fromC)
        #expect(Set(fromA).count == fromA.count, "no repeats in 64 draws")
    }

    /// A zero seed is legal for SplitMix64, but a generator that degenerated on
    /// it would be a nasty trap for a future caller.
    @Test func seededGeneratorHandlesAZeroSeed() {
        var zero = SeededGenerator(seed: 0)
        let draws = (0..<32).map { _ in zero.next() }
        #expect(Set(draws).count == draws.count)
        #expect(!draws.allSatisfy { $0 == 0 })
    }

    /// Rough uniformity over the range, so `Int.random(in:using:)` built on this
    /// actually spreads across the trial indices it is resampling.
    @Test func seededGeneratorIsRoughlyUniform() {
        var rng = SeededGenerator(seed: 7)
        var buckets = [Int](repeating: 0, count: 10)
        for _ in 0..<10_000 {
            buckets[Int.random(in: 0..<10, using: &rng)] += 1
        }
        for bucket in buckets {
            #expect(bucket > 800 && bucket < 1_200, "bucket counts: \(buckets)")
        }
    }
}
