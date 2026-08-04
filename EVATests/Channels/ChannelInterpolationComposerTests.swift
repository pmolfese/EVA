//
//  ChannelInterpolationComposerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import simd
@testable import EVA

struct ChannelInterpolationComposerTests {
    @MainActor
    @Test func interpolationAndRecipeCommitAsOneRevision() {
        let channels = ChannelModel()

        channels.setInterpolation(
            target: 0,
            replacement: [2.5, 3.5],
            sourceIndices: [1, 2],
            sourceWeights: [0.25, 0.75]
        )

        #expect(channels.interpolationRevision == 1)
        #expect(channels.interpolated[0] == [2.5, 3.5])
        #expect(channels.interpolationSources[0]?.indices == [1, 2])

        channels.removeInterpolation(target: 0)

        #expect(channels.interpolationRevision == 2)
        #expect(channels.interpolated[0] == nil)
        #expect(channels.interpolationSources[0] == nil)
    }

    @MainActor
    @Test func interpolationRecomposesFromCurrentProcessedDonors() {
        let channels = ChannelModel()
        channels.interpolated[0] = [99, 99]
        channels.interpolationSources[0] = (indices: [1, 2], weights: [0.25, 0.75])

        let beforeCleaning = SyntheticSignal.make([
            [99, 99],
            [1, 2],
            [3, 4]
        ], samplingRate: 250)
        let before = channels.applyingInterpolations(to: beforeCleaning)
        #expect(before.data[0] == [2.5, 3.5])

        let afterCleaning = SyntheticSignal.make([
            [99, 99],
            [2, 4],
            [6, 8]
        ], samplingRate: 250)
        let after = channels.applyingInterpolations(to: afterCleaning)

        #expect(after.data[0] == [5, 7])
        #expect(channels.interpolated.keys.contains(0))
        #expect(channels.interpolationSources[0]?.indices == [1, 2])
    }

    @MainActor
    @Test func cachedInterpolationRemainsFallbackWithoutRecipe() {
        let channels = ChannelModel()
        channels.interpolated[0] = [7, 8]
        let signal = SyntheticSignal.make([[99, 99], [1, 2]], samplingRate: 250)

        #expect(channels.applyingInterpolations(to: signal).data[0] == [7, 8])
    }

    @MainActor
    @Test func resolverReusesExactSignalAndInterpolationRevision() async {
        let channels = ChannelModel()
        channels.interpolated[0] = [99, 99]
        channels.interpolationSources[0] = (indices: [1, 2], weights: [0.25, 0.75])
        let signal = SyntheticSignal.make([
            [99, 99],
            [1, 2],
            [3, 4]
        ], samplingRate: 250)
        let resolver = InterpolatedSignalResolver()
        let snapshot = channels.interpolationSnapshot
        let key = resolver.key(for: signal, snapshot: snapshot)

        await resolver.resolve(signal: signal, snapshot: snapshot)
        #expect(resolver.cachedSignal(for: key)?.data[0] == [2.5, 3.5])
        #expect(resolver.computationCount == 1)

        // A redraw/viewport change asks for the same key and must be a no-op.
        await resolver.resolve(signal: signal, snapshot: snapshot)
        #expect(resolver.computationCount == 1)
    }

    @MainActor
    @Test func resolverInvalidatesWhenProcessedSamplesChange() async {
        let channels = ChannelModel()
        channels.interpolated[0] = [99, 99]
        channels.interpolationSources[0] = (indices: [1, 2], weights: [0.25, 0.75])
        let beforeCleaning = SyntheticSignal.make([
            [99, 99],
            [1, 2],
            [3, 4]
        ], samplingRate: 250)
        let resolver = InterpolatedSignalResolver()
        let snapshot = channels.interpolationSnapshot

        await resolver.resolve(signal: beforeCleaning, snapshot: snapshot)

        let afterCleaning = beforeCleaning.replacingData([
            [99, 99],
            [2, 4],
            [6, 8]
        ])
        #expect(afterCleaning.dataRevision != beforeCleaning.dataRevision)

        await resolver.resolve(signal: afterCleaning, snapshot: snapshot)
        let newKey = resolver.key(for: afterCleaning, snapshot: snapshot)
        #expect(resolver.cachedSignal(for: newKey)?.data[0] == [5, 7])
        #expect(resolver.computationCount == 2)
    }

    @MainActor
    @Test func resolverInvalidatesWhenInterpolationRecipeChanges() async {
        let channels = ChannelModel()
        channels.interpolated[0] = [99, 99]
        channels.interpolationSources[0] = (indices: [1], weights: [1])
        let signal = SyntheticSignal.make([
            [99, 99],
            [1, 2],
            [3, 4]
        ], samplingRate: 250)
        let resolver = InterpolatedSignalResolver()

        let firstSnapshot = channels.interpolationSnapshot
        await resolver.resolve(signal: signal, snapshot: firstSnapshot)

        channels.interpolationSources[0] = (indices: [2], weights: [1])
        let secondSnapshot = channels.interpolationSnapshot
        #expect(secondSnapshot.revision != firstSnapshot.revision)

        await resolver.resolve(signal: signal, snapshot: secondSnapshot)
        let newKey = resolver.key(for: signal, snapshot: secondSnapshot)
        #expect(resolver.cachedSignal(for: newKey)?.data[0] == [3, 4])
        #expect(resolver.computationCount == 2)
    }

    @MainActor
    @Test func resolverRetainsMountedWaveformDuringSameSignalRefresh() async {
        let channels = ChannelModel()
        let signal = SyntheticSignal.make([
            [99, 99],
            [1, 2],
            [3, 4]
        ], samplingRate: 250)
        let resolver = InterpolatedSignalResolver()

        channels.setInterpolation(
            target: 0,
            replacement: [99, 99],
            sourceIndices: [1],
            sourceWeights: [1]
        )
        let firstSnapshot = channels.interpolationSnapshot
        await resolver.resolve(signal: signal, snapshot: firstSnapshot)

        channels.setInterpolation(
            target: 0,
            replacement: [99, 99],
            sourceIndices: [2],
            sourceWeights: [1]
        )
        let pendingKey = resolver.key(for: signal, snapshot: channels.interpolationSnapshot)
        let retained = resolver.displaySignal(whileResolving: pendingKey, fallback: signal)

        #expect(retained.data[0] == [1, 2])

        let newPipelineSignal = signal.replacingData([
            [88, 88],
            [5, 6],
            [7, 8]
        ])
        let newPipelineKey = resolver.key(
            for: newPipelineSignal,
            snapshot: channels.interpolationSnapshot
        )
        let fallback = resolver.displaySignal(
            whileResolving: newPipelineKey,
            fallback: newPipelineSignal
        )
        #expect(fallback.data[0] == [88, 88])
    }

    @Test func psaGlobalEscalationInterpolatesTargetsAsOneBatch() throws {
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
            3: SIMD3(-1, 0, 0),
            4: SIMD3(0, -1, 0),
            5: SIMD3(0, 0, -1),
        ]
        let continuous = SyntheticSignal.make([
            [2, 4], [2, 4], [2, 4], [2, 4], [99, 99], [99, 99]
        ], samplingRate: 250)
        let epoched = SyntheticSignal.make([
            [10, 20], [10, 20], [10, 20], [10, 20], [99, 99], [99, 99]
        ], samplingRate: 250)

        let results = PSAGlobalBadChannelInterpolator.interpolate(
            targets: [4, 5],
            continuousSignal: continuous,
            epochedSignal: epoched,
            excludedDonors: [],
            positions: positions
        )

        #expect(results.count == 2)
        for result in results {
            #expect(result.succeeded)
            #expect(result.indices == [0, 1, 2, 3])
            let continuousSeries = try #require(result.continuousSeries)
            let epochedSeries = try #require(result.epochedSeries)
            for (actual, expected) in zip(continuousSeries, [Float(2), 4]) {
                #expect(abs(actual - expected) < 1e-5)
            }
            for (actual, expected) in zip(epochedSeries, [Float(10), 20]) {
                #expect(abs(actual - expected) < 1e-5)
            }
        }
    }

    @Test func psaGlobalEscalationReportsMissingTargetGeometry() throws {
        let signal = SyntheticSignal.make([
            [1, 2], [1, 2], [1, 2], [99, 99]
        ], samplingRate: 250)
        let positions: [Int: SIMD3<Double>] = [
            0: SIMD3(1, 0, 0),
            1: SIMD3(0, 1, 0),
            2: SIMD3(0, 0, 1),
        ]

        let result = try #require(
            PSAGlobalBadChannelInterpolator.interpolate(
                targets: [3],
                continuousSignal: signal,
                epochedSignal: nil,
                excludedDonors: [],
                positions: positions
            ).first
        )

        #expect(!result.succeeded)
        #expect(result.errorMessage?.contains("No 3D coordinates") == true)
    }
}
