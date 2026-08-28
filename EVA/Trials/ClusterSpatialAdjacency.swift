//
//  ClusterSpatialAdjacency.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Sensor neighborhood definitions for spatiotemporal clustering. Which sensors
//  count as adjacent materially changes what clusters can form — too sparse and
//  a genuine effect fragments into several sub-threshold clusters, too dense and
//  everything merges into one uninterpretable blob — so this is a user choice
//  with a reported neighbor count, not a hidden constant.
//
//  Distances are measured in EVA's normalized 2D sensor projection, where the
//  head outline has unit radius. A neighbor distance of 0.25 therefore means a
//  quarter of the head radius regardless of montage size.
//

import Foundation

nonisolated enum ClusterAdjacencyMethod: String, CaseIterable, Identifiable, Sendable, Equatable {
    /// Every sensor within a fixed radius. This is the FieldTrip `distance`
    /// convention and the one most published EEG cluster tests use: neighborhood
    /// size follows sensor density, so dense regions get more neighbors.
    case distance = "Within distance"
    /// A fixed number of nearest sensors. Guarantees a connected, uniform graph
    /// even for irregular or sparse montages where one radius does not fit all.
    case nearestNeighbors = "K nearest"
    /// No spatial links: clusters extend in time only, within each channel.
    case temporalOnly = "Time only"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .distance:
            return "Sensors closer than the given fraction of the head radius are neighbors. Neighborhood size follows sensor density, matching the convention used by most published EEG cluster tests."
        case .nearestNeighbors:
            return "Each sensor is linked to its K closest sensors, symmetrized. Gives every sensor the same neighborhood size, which suits irregular or sparse montages."
        case .temporalOnly:
            return "Clusters extend across time within a channel but never across sensors. Use when no layout is available or when channels are not spatially interpretable."
        }
    }
}

nonisolated struct ClusterAdjacencyConfiguration: Sendable, Equatable {
    var method = ClusterAdjacencyMethod.distance
    /// Radius in normalized head-radius units, used by `.distance`.
    var distance = 0.25
    /// Neighbor count used by `.nearestNeighbors`.
    var neighborCount = 4

    static let `default` = ClusterAdjacencyConfiguration()

    var isValid: Bool {
        switch method {
        case .distance: return distance > 0 && distance <= 2 && distance.isFinite
        case .nearestNeighbors: return neighborCount >= 1 && neighborCount <= 32
        case .temporalOnly: return true
        }
    }
}

/// What a configuration produced, so the UI can warn about degenerate graphs
/// before the user spends ten thousand permutations on them.
nonisolated struct ClusterAdjacencySummary: Sendable, Equatable {
    let meanNeighborCount: Double
    let minimumNeighborCount: Int
    let maximumNeighborCount: Int
    /// Sensors with no neighbors at all — they can only form temporal clusters.
    let isolatedChannelCount: Int
    /// Number of connected components in the sensor graph.
    let componentCount: Int

    var isDegenerate: Bool { isolatedChannelCount > 0 || meanNeighborCount < 1.5 }
    var isOverConnected: Bool { meanNeighborCount > 12 }
}

nonisolated enum ClusterSpatialAdjacency {
    /// Local channel index -> local neighbor indices. Always symmetric.
    static func build(
        channelIndices: [Int],
        layout: SensorLayout?,
        configuration: ClusterAdjacencyConfiguration
    ) -> [[Int]] {
        let empty = Array(repeating: [Int](), count: channelIndices.count)
        guard configuration.method != .temporalOnly,
              configuration.isValid,
              let layout else { return empty }

        let positions = Dictionary(uniqueKeysWithValues: layout.positions.map { ($0.channelIndex, $0) })
        // Local indices that actually have coordinates; the rest stay isolated.
        let located = channelIndices.enumerated().compactMap { local, channel -> (Int, SensorPosition)? in
            guard let position = positions[channel] else { return nil }
            return (local, position)
        }
        guard located.count > 1 else { return empty }

        var adjacency = Array(repeating: Set<Int>(), count: channelIndices.count)
        switch configuration.method {
        case .temporalOnly:
            break
        case .distance:
            let squaredRadius = configuration.distance * configuration.distance
            for outer in 0..<located.count {
                let (localA, positionA) = located[outer]
                for inner in (outer + 1)..<located.count {
                    let (localB, positionB) = located[inner]
                    let dx = positionA.x - positionB.x
                    let dy = positionA.y - positionB.y
                    guard dx * dx + dy * dy <= squaredRadius else { continue }
                    adjacency[localA].insert(localB)
                    adjacency[localB].insert(localA)
                }
            }
        case .nearestNeighbors:
            let count = min(configuration.neighborCount, located.count - 1)
            for (localA, positionA) in located {
                let nearest = located
                    .compactMap { localB, positionB -> (Int, Double)? in
                        guard localB != localA else { return nil }
                        let dx = positionA.x - positionB.x
                        let dy = positionA.y - positionB.y
                        return (localB, dx * dx + dy * dy)
                    }
                    .sorted { $0.1 < $1.1 }
                    .prefix(count)
                // Symmetrized, so the effective neighbor count is >= K.
                for (localB, _) in nearest {
                    adjacency[localA].insert(localB)
                    adjacency[localB].insert(localA)
                }
            }
        }
        return adjacency.map { $0.sorted() }
    }

    static func summarize(_ adjacency: [[Int]]) -> ClusterAdjacencySummary {
        guard !adjacency.isEmpty else {
            return ClusterAdjacencySummary(
                meanNeighborCount: 0,
                minimumNeighborCount: 0,
                maximumNeighborCount: 0,
                isolatedChannelCount: 0,
                componentCount: 0
            )
        }
        let counts = adjacency.map(\.count)
        var visited = [Bool](repeating: false, count: adjacency.count)
        var components = 0
        for start in adjacency.indices where !visited[start] {
            components += 1
            var stack = [start]
            visited[start] = true
            while let node = stack.popLast() {
                for neighbor in adjacency[node] where !visited[neighbor] {
                    visited[neighbor] = true
                    stack.append(neighbor)
                }
            }
        }
        return ClusterAdjacencySummary(
            meanNeighborCount: Double(counts.reduce(0, +)) / Double(counts.count),
            minimumNeighborCount: counts.min() ?? 0,
            maximumNeighborCount: counts.max() ?? 0,
            isolatedChannelCount: counts.filter { $0 == 0 }.count,
            componentCount: components
        )
    }

    /// A starting radius for `.distance`: the median nearest-neighbor spacing
    /// scaled so a typical sensor picks up its immediate ring. Montages vary
    /// enormously in density, so a fixed default radius would be wrong for most
    /// of them.
    static func suggestedDistance(channelIndices: [Int], layout: SensorLayout?) -> Double? {
        guard let layout else { return nil }
        let positions = Dictionary(uniqueKeysWithValues: layout.positions.map { ($0.channelIndex, $0) })
        let located = channelIndices.compactMap { positions[$0] }
        guard located.count > 2 else { return nil }

        var nearestDistances: [Double] = []
        nearestDistances.reserveCapacity(located.count)
        for positionA in located {
            var best = Double.greatestFiniteMagnitude
            for positionB in located where positionB.channelIndex != positionA.channelIndex {
                let dx = positionA.x - positionB.x
                let dy = positionA.y - positionB.y
                best = min(best, dx * dx + dy * dy)
            }
            if best.isFinite { nearestDistances.append(sqrt(best)) }
        }
        guard !nearestDistances.isEmpty else { return nil }
        nearestDistances.sort()
        let median = nearestDistances[nearestDistances.count / 2]
        // 1.7x the median spacing reaches the first ring of a roughly
        // hexagonal layout without jumping to the second.
        return (median * 1.7 * 100).rounded() / 100
    }
}
