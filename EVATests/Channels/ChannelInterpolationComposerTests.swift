//
//  ChannelInterpolationComposerTests.swift
//  EVATests
//

import Testing
@testable import EVA

struct ChannelInterpolationComposerTests {
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
}
