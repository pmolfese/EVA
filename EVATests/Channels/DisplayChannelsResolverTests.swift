//
//  DisplayChannelsResolverTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct DisplayChannelsResolverTests {
    private let frontalID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    @Test("Display resolution preserves authored order and removes duplicates")
    func preservesOrder() {
        let set = ChannelSet(
            id: frontalID,
            name: "Frontal",
            channelIndices: [7, 2, 5, 2, 1]
        )

        let result = DisplayChannelsResolver.indices(
            selectedSetID: frontalID,
            sets: [set],
            channelCount: 8,
            netType: nil
        )

        #expect(result == [7, 2, 5, 1])
    }

    @Test("Missing or invalid selections fall back to every source channel")
    func invalidSelectionFallsBackToAll() {
        let invalid = ChannelSet(
            id: frontalID,
            name: "Out of range",
            channelIndices: [0, 8]
        )

        #expect(DisplayChannelsResolver.indices(
            selectedSetID: frontalID,
            sets: [invalid],
            channelCount: 8,
            netType: nil
        ) == Array(0..<8))

        #expect(DisplayChannelsResolver.indices(
            selectedSetID: UUID(),
            sets: [invalid],
            channelCount: 8,
            netType: nil
        ) == Array(0..<8))
    }

    @Test("Net-specific sets require an exact net while Any Net sets remain available")
    func honorsNetCompatibility() {
        let exact = ChannelSet(name: "Exact", channelIndices: [0, 1], netType: "HydroCel 64")
        let any = ChannelSet(name: "Any", channelIndices: [2, 3], netType: nil)

        let matching = DisplayChannelsResolver.compatibleSets(
            from: [exact, any],
            channelCount: 64,
            netType: "HydroCel 64"
        )
        let different = DisplayChannelsResolver.compatibleSets(
            from: [exact, any],
            channelCount: 64,
            netType: "HydroCel 128"
        )

        #expect(matching.map(\.name) == ["Exact", "Any"])
        #expect(different.map(\.name) == ["Any"])
    }

    @Test("Empty and negative-index sets are not display compatible")
    func rejectsUnusableSets() {
        let empty = ChannelSet(name: "Empty", channelIndices: [])
        let negative = ChannelSet(name: "Negative", channelIndices: [-1, 0])

        #expect(!DisplayChannelsResolver.isCompatible(empty, channelCount: 4, netType: nil))
        #expect(!DisplayChannelsResolver.isCompatible(negative, channelCount: 4, netType: nil))
    }
}
