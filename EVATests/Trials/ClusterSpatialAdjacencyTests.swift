//
//  ClusterSpatialAdjacencyTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct ClusterSpatialAdjacencyTests {
    /// A 5x5 grid of sensors spaced 0.2 apart in the normalized projection.
    private func gridLayout(side: Int = 5, spacing: Double = 0.2) -> SensorLayout {
        var positions: [SensorPosition] = []
        for row in 0..<side {
            for column in 0..<side {
                positions.append(SensorPosition(
                    channelIndex: row * side + column,
                    x: Double(column) * spacing,
                    y: Double(row) * spacing
                ))
            }
        }
        return SensorLayout(name: "grid", positions: positions)
    }

    private var allChannels: [Int] { Array(0..<25) }

    @Test func distanceMethodLinksOnlyTheImmediateRing() {
        let adjacency = ClusterSpatialAdjacency.build(
            channelIndices: allChannels,
            layout: gridLayout(),
            configuration: .init(method: .distance, distance: 0.25)
        )
        // 0.25 reaches orthogonal neighbors at 0.20 but not diagonals at 0.283.
        #expect(adjacency[0].count == 2)          // corner
        #expect(adjacency[12].count == 4)         // interior
        #expect(adjacency[12] == [7, 11, 13, 17])
    }

    @Test func distanceMethodWidensWithRadius() {
        let narrow = ClusterSpatialAdjacency.build(
            channelIndices: allChannels,
            layout: gridLayout(),
            configuration: .init(method: .distance, distance: 0.25)
        )
        let wide = ClusterSpatialAdjacency.build(
            channelIndices: allChannels,
            layout: gridLayout(),
            configuration: .init(method: .distance, distance: 0.30)
        )
        // 0.30 now admits the diagonals at 0.283.
        #expect(wide[12].count == 8)
        #expect(wide[12].count > narrow[12].count)
    }

    @Test func nearestNeighborsIsSymmetricAndSoMayExceedK() {
        let adjacency = ClusterSpatialAdjacency.build(
            channelIndices: allChannels,
            layout: gridLayout(),
            configuration: .init(method: .nearestNeighbors, neighborCount: 4)
        )
        for (channel, neighbors) in adjacency.enumerated() {
            #expect(neighbors.count >= 2)
            for neighbor in neighbors {
                #expect(adjacency[neighbor].contains(channel), "adjacency must be symmetric")
            }
        }
        // A corner has only three sensors within its K-radius, but symmetry
        // pulls in whoever chose it, so it never ends up isolated.
        #expect(!adjacency[0].isEmpty)
    }

    @Test func temporalOnlyProducesNoSpatialLinks() {
        let adjacency = ClusterSpatialAdjacency.build(
            channelIndices: allChannels,
            layout: gridLayout(),
            configuration: .init(method: .temporalOnly)
        )
        #expect(adjacency.count == 25)
        #expect(adjacency.allSatisfy { $0.isEmpty })
    }

    @Test func missingLayoutFallsBackToNoSpatialLinks() {
        let adjacency = ClusterSpatialAdjacency.build(
            channelIndices: allChannels,
            layout: nil,
            configuration: .init(method: .distance, distance: 0.5)
        )
        #expect(adjacency.allSatisfy { $0.isEmpty })
    }

    @Test func summaryDetectsIsolatedSensorsAndComponents() {
        // Too tight a radius leaves every sensor alone.
        let isolated = ClusterSpatialAdjacency.build(
            channelIndices: allChannels,
            layout: gridLayout(),
            configuration: .init(method: .distance, distance: 0.05)
        )
        let isolatedSummary = ClusterSpatialAdjacency.summarize(isolated)
        #expect(isolatedSummary.isolatedChannelCount == 25)
        #expect(isolatedSummary.componentCount == 25)
        #expect(isolatedSummary.isDegenerate)

        let connected = ClusterSpatialAdjacency.summarize(
            ClusterSpatialAdjacency.build(
                channelIndices: allChannels,
                layout: gridLayout(),
                configuration: .init(method: .distance, distance: 0.25)
            )
        )
        #expect(connected.isolatedChannelCount == 0)
        #expect(connected.componentCount == 1)
        #expect(!connected.isDegenerate)
        // 25 sensors, 40 undirected orthogonal links, so 80/25 = 3.2 mean.
        #expect(abs(connected.meanNeighborCount - 3.2) < 1e-12)
    }

    @Test func summaryFlagsOverConnectedGraphs() {
        let summary = ClusterSpatialAdjacency.summarize(
            ClusterSpatialAdjacency.build(
                channelIndices: allChannels,
                layout: gridLayout(),
                configuration: .init(method: .distance, distance: 1.5)
            )
        )
        #expect(summary.isOverConnected)
    }

    @Test func suggestedDistanceTracksSensorSpacing() throws {
        let dense = try #require(ClusterSpatialAdjacency.suggestedDistance(
            channelIndices: allChannels,
            layout: gridLayout(spacing: 0.1)
        ))
        let sparse = try #require(ClusterSpatialAdjacency.suggestedDistance(
            channelIndices: allChannels,
            layout: gridLayout(spacing: 0.4)
        ))
        #expect(sparse > dense)
        // 1.7x the median nearest-neighbor spacing.
        #expect(abs(dense - 0.17) < 1e-9)

        // And it produces a connected graph, which is the point of suggesting it.
        let summary = ClusterSpatialAdjacency.summarize(
            ClusterSpatialAdjacency.build(
                channelIndices: allChannels,
                layout: gridLayout(spacing: 0.1),
                configuration: .init(method: .distance, distance: dense)
            )
        )
        #expect(summary.componentCount == 1)
        #expect(summary.isolatedChannelCount == 0)
    }

    @Test func rejectsOutOfRangeConfigurations() {
        #expect(!ClusterAdjacencyConfiguration(method: .distance, distance: 0).isValid)
        #expect(!ClusterAdjacencyConfiguration(method: .distance, distance: .nan).isValid)
        #expect(!ClusterAdjacencyConfiguration(method: .nearestNeighbors, neighborCount: 0).isValid)
        #expect(!ClusterAdjacencyConfiguration(method: .nearestNeighbors, neighborCount: 99).isValid)
        #expect(ClusterAdjacencyConfiguration(method: .temporalOnly).isValid)
    }
}
