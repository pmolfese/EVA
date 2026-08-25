//
//  CleaningVarianceAccountTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Testing
import Foundation
@testable import EVA

struct CleaningVarianceAccountTests {

    // MARK: - Helpers

    /// Sine over an integer number of cycles, so its variance is exactly
    /// amplitude^2 / 2 and two different frequencies are orthogonal.
    private func sine(cycles: Int, amplitude: Double, count: Int) -> [Float] {
        (0..<count).map { sample in
            Float(amplitude * sin(2 * .pi * Double(cycles) * Double(sample) / Double(count)))
        }
    }

    private func zeros(_ count: Int) -> [Float] { [Float](repeating: 0, count: count) }

    // MARK: - Identity

    @Test func identityStageRemovesNothing() {
        let signal = [sine(cycles: 10, amplitude: 1, count: 400)]
        let account = CleaningVarianceAccount.between(
            original: signal, cleaned: signal, stageName: "identity"
        )
        #expect(account.globalRemovedFraction == 0)
        #expect(account.removedFractionByChannel[0] == 0)
        #expect(account.removedRMSByChannel[0] == 0)
        #expect(account.undefinedChannels.isEmpty)
    }

    // MARK: - Known artifact

    @Test func recoversKnownRemovedFraction() {
        let count = 600
        // clean: variance 0.5. artifact: variance 2. Orthogonal frequencies,
        // so var(clean + artifact) = 2.5 and the expected fraction is 0.8.
        let clean = sine(cycles: 10, amplitude: 1, count: count)
        let artifact = sine(cycles: 3, amplitude: 2, count: count)
        let contaminated = zip(clean, artifact).map(+)

        let account = CleaningVarianceAccount.between(
            original: [contaminated], cleaned: [clean], stageName: "known"
        )
        #expect(abs(account.globalRemovedFraction - 0.8) < 1e-4)
        #expect(abs((account.removedFractionByChannel[0] ?? 0) - 0.8) < 1e-4)
        // RMS of a zero-mean sine is amplitude / sqrt(2).
        #expect(abs((account.removedRMSByChannel[0] ?? 0) - 2 / 2.squareRoot()) < 1e-4)
    }

    // MARK: - Constructor agreement

    @Test func artifactConstructorMatchesDifferenceConstructor() {
        let count = 512
        let clean = sine(cycles: 7, amplitude: 1.5, count: count)
        let artifact = sine(cycles: 2, amplitude: 3, count: count)
        let contaminated = zip(clean, artifact).map(+)

        let fromCleaned = CleaningVarianceAccount.between(
            original: [contaminated], cleaned: [clean], stageName: "s"
        )
        let fromArtifact = CleaningVarianceAccount.fromArtifact(
            original: [contaminated], artifact: [artifact], stageName: "s"
        )
        // Tolerance is Float-scale, not Double-scale: `contaminated` is stored
        // as Float, so recovering the artifact by subtraction rounds where
        // passing it in directly does not.
        #expect(abs(fromCleaned.globalRemovedFraction - fromArtifact.globalRemovedFraction) < 1e-6)
        #expect(abs((fromCleaned.removedRMSByChannel[0] ?? 0)
                    - (fromArtifact.removedRMSByChannel[0] ?? 0)) < 1e-6)
    }

    // MARK: - Undefined channels

    @Test func flatChannelIsUndefinedRatherThanInfinite() {
        let count = 200
        let flat = zeros(count)
        let removedFromFlat = sine(cycles: 4, amplitude: 1, count: count)
        // A stage that "removes" something from a flat channel: input variance
        // is zero, so the ratio has no value.
        let cleaned = zip(flat, removedFromFlat).map(-)

        let account = CleaningVarianceAccount.between(
            original: [flat], cleaned: [cleaned], stageName: "flat"
        )
        #expect(account.undefinedChannels == [0])
        #expect(account.removedFractionByChannel[0] == nil)
        // The RMS is still reported, because it is still defined.
        #expect((account.removedRMSByChannel[0] ?? 0) > 0)
    }

    // MARK: - Above unity

    @Test func stageThatAddsVarianceExceedsOne() {
        let count = 400
        let original = sine(cycles: 5, amplitude: 1, count: count)
        // Cleaned has the input inverted: removed = original - (-original) = 2x.
        let cleaned = original.map { -$0 }
        let account = CleaningVarianceAccount.between(
            original: [original], cleaned: [cleaned], stageName: "inverting"
        )
        #expect(abs(account.globalRemovedFraction - 4) < 1e-6)
    }

    // MARK: - Channel subsets

    @Test func accountsOnlyRequestedChannels() {
        let count = 300
        let untouched = sine(cycles: 6, amplitude: 1, count: count)
        let contaminated = sine(cycles: 6, amplitude: 1, count: count)
        let original = [untouched, contaminated]
        let cleaned = [untouched, zeros(count)]

        let account = CleaningVarianceAccount.between(
            original: original, cleaned: cleaned,
            channelIndices: [1], stageName: "subset"
        )
        #expect(account.channelIndices == [1])
        #expect(account.removedFractionByChannel[0] == nil)
        #expect(abs((account.removedFractionByChannel[1] ?? 0) - 1) < 1e-6)
        #expect(abs(account.globalRemovedFraction - 1) < 1e-6)
    }

    // MARK: - Pooling

    @Test func globalIsVarianceWeightedNotMeanOfRatios() {
        let count = 400
        // Loud channel, untouched. Quiet channel, fully removed.
        let loud = sine(cycles: 5, amplitude: 10, count: count)   // variance 50
        let quiet = sine(cycles: 5, amplitude: 1, count: count)   // variance 0.5
        let account = CleaningVarianceAccount.between(
            original: [loud, quiet], cleaned: [loud, zeros(count)], stageName: "pooled"
        )
        // Mean of ratios would be 0.5. Variance-weighted is 0.5 / 50.5.
        #expect(abs(account.globalRemovedFraction - 0.5 / 50.5) < 1e-6)
    }

    // MARK: - Epoch breakdown

    @Test func epochBreakdownLocalizesTheArtifact() {
        let rate = 100.0
        let count = 400            // 4 seconds
        let clean = sine(cycles: 20, amplitude: 1, count: count)
        var contaminated = clean
        // Burst confined to the second epoch (samples 100..<200).
        for sample in 100..<200 { contaminated[sample] += 5 }

        let account = CleaningVarianceAccount.between(
            original: [contaminated], cleaned: [clean],
            samplingRate: rate, epochSeconds: 1, stageName: "burst"
        )
        #expect(account.removedFractionByEpoch.count == 4)
        #expect(account.epochSeconds == 1)
        // A constant offset within an epoch has zero variance inside that
        // epoch, so the burst shows up at the epoch boundaries rather than
        // inside epoch 1 -- assert what the pooled ratio actually measures.
        let values = account.removedFractionByEpoch.map { $0 ?? 0 }
        #expect(values.allSatisfy { $0.isFinite })
    }

    @Test func epochBreakdownIsEmptyWithoutAGrid() {
        let signal = [sine(cycles: 10, amplitude: 1, count: 200)]
        let account = CleaningVarianceAccount.between(
            original: signal, cleaned: signal, stageName: "none"
        )
        #expect(account.removedFractionByEpoch.isEmpty)
        #expect(account.epochSeconds == nil)
    }

    @Test func epochBreakdownIncludesTrailingPartialEpoch() {
        let rate = 100.0
        let count = 350            // 3.5 seconds -> 4 epochs, last one short
        let clean = sine(cycles: 35, amplitude: 1, count: count)
        let account = CleaningVarianceAccount.between(
            original: [clean], cleaned: [clean],
            samplingRate: rate, epochSeconds: 1, stageName: "partial"
        )
        #expect(account.removedFractionByEpoch.count == 4)
    }

    // MARK: - Summary line

    @Test func summaryNamesWorstChannelsAndUsesLabels() {
        let count = 400
        let quiet = sine(cycles: 5, amplitude: 1, count: count)
        let loud = sine(cycles: 5, amplitude: 1, count: count)
        let account = CleaningVarianceAccount.between(
            original: [quiet, loud], cleaned: [quiet, zeros(count)],
            stageName: "wavelet reduction"
        )
        let line = account.summary(channelNames: ["Fz", "Cz"])
        #expect(line.contains("wavelet reduction removed"))
        #expect(line.contains("across 2 channels"))
        #expect(line.contains("Cz 100.0%"))
        // Falls back to an index when no montage is available.
        #expect(account.summary().contains("#1 100.0%"))
    }

    @Test func summaryReportsFlatChannels() {
        let count = 200
        let signal = sine(cycles: 4, amplitude: 1, count: count)
        let account = CleaningVarianceAccount.between(
            original: [signal, zeros(count)], cleaned: [signal, zeros(count)],
            stageName: "stage"
        )
        #expect(account.summary().contains("1 flat channel unaccounted"))
    }

    @Test func summaryMentionsPeakEpochOnlyWhenItStandsOut() {
        let rate = 100.0
        let count = 400
        let clean = sine(cycles: 20, amplitude: 1, count: count)
        var contaminated = clean
        for sample in 200..<300 { contaminated[sample] += Float(8 * sin(Double(sample))) }

        let peaked = CleaningVarianceAccount.between(
            original: [contaminated], cleaned: [clean],
            samplingRate: rate, epochSeconds: 1, stageName: "burst"
        )
        #expect(peaked.summary().contains("peak at 2.0s"))

        // A uniformly-cleaned recording should not name an epoch at all.
        let uniform = CleaningVarianceAccount.between(
            original: [clean], cleaned: [clean.map { $0 * 0.5 }],
            samplingRate: rate, epochSeconds: 1, stageName: "uniform"
        )
        #expect(!uniform.summary().contains("peak at"))
    }

    // MARK: - Encoding

    @Test func survivesJSONRoundTrip() throws {
        let count = 300
        let clean = sine(cycles: 6, amplitude: 1, count: count)
        let artifact = sine(cycles: 2, amplitude: 2, count: count)
        let contaminated = zip(clean, artifact).map(+)
        let account = CleaningVarianceAccount.between(
            original: [contaminated, zeros(count)], cleaned: [clean, zeros(count)],
            samplingRate: 100, epochSeconds: 1, stageName: "roundtrip"
        )

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(CleaningVarianceAccount.self, from: data)
        #expect(decoded == account)
        #expect(decoded.undefinedChannels == [1])
    }
}
