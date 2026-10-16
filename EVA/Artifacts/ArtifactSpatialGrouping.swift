import Foundation

/// Session-only derived features. Nothing here changes review decisions or cleaning.
nonisolated struct ArtifactSpatialFeature: Sendable {
    let eventID: String
    let vector: [Double]
}

nonisolated struct ArtifactSpatialGroup: Identifiable, Sendable {
    let id: Int
    let eventIDs: [String]
    let representativeID: String
    /// Minimum signed correlation to this group's normalized spatial centroid.
    let minimumCorrelation: Double
    /// Optional cached normalized centroid for waveform subgroup previews.
    var meanFeature: [Double] = []
}

nonisolated struct ArtifactSpatialHierarchy: Sendable {
    struct Node: Sendable {
        let group: ArtifactSpatialGroup
        let children: [Int]
    }
    let channels: [Int]
    let features: [ArtifactSpatialFeature]
    let unassignedIDs: [String]
    let nodes: [Node]
    let root: Int?

    /// Cutting an already-built tree does not touch signal data or recompute distances.
    func groups(minimumCorrelation: Double) -> [ArtifactSpatialGroup] {
        guard let root else { return [] }
        var pending = [root], result: [ArtifactSpatialGroup] = []
        while let index = pending.popLast() {
            let node = nodes[index]
            if node.children.isEmpty || node.group.minimumCorrelation >= minimumCorrelation {
                result.append(node.group)
            } else {
                pending.append(contentsOf: node.children.reversed())
            }
        }
        return result.sorted {
            if $0.eventIDs.count == $1.eventIDs.count { return $0.id < $1.id }
            return $0.eventIDs.count > $1.eventIDs.count
        }
    }
}

nonisolated enum ArtifactSpatialGrouping {
    static func normalized(_ values: [Double]) -> [Double]? {
        guard values.count >= 3, values.allSatisfy(\.isFinite) else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - mean }
        let norm = sqrt(centered.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-10 else { return nil }
        return centered.map { $0 / norm }
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Bounded parallel normalization, followed by a deterministic divisive spherical tree.
    /// No n×n distance matrix is retained. Raw amplitude is deliberately factored out.
    static func build(examples: [ArtifactReviewExample]) async -> ArtifactSpatialHierarchy? {
        guard !Task.isCancelled else { return nil }
        let maps = examples.compactMap(\.topography)
        var counts: [Int: Int] = [:]
        for map in maps { for channel in Set(map.channelIndices) { counts[channel, default: 0] += 1 } }
        let channels = counts.keys.filter { counts[$0, default: 0] >= max(1, Int(ceil(Double(maps.count) * 0.9))) }.sorted()
        // A few missing/invalid sensors must not silently reduce a dense montage to three sensors.
        let minimumCoverage = max(3, Int(ceil(Double(maps.map { $0.channelIndices.count }.max() ?? 0) * 0.8)))
        guard channels.count >= minimumCoverage else {
            return ArtifactSpatialHierarchy(channels: [], features: [], unassignedIDs: examples.map(\.id), nodes: [], root: nil)
        }
        let batchSize = max(1, (examples.count + 3) / 4)
        let requiredChannels = Set(channels)
        let features = await withTaskGroup(of: [ArtifactSpatialFeature].self) { group in
            for start in stride(from: 0, to: examples.count, by: batchSize) {
                let batch = Array(examples[start..<min(start + batchSize, examples.count)])
                group.addTask {
                    var result: [ArtifactSpatialFeature] = []
                    for example in batch {
                        if Task.isCancelled { break }
                        guard let map = example.topography, example.hasCompleteWindow,
                              requiredChannels.isSubset(of: Set(map.channelIndices)),
                              channels.allSatisfy({ map.values.indices.contains($0) }),
                              let vector = normalized(channels.map { map.values[$0] }) else { continue }
                        result.append(ArtifactSpatialFeature(eventID: example.id, vector: vector))
                    }
                    return result
                }
            }
            var result: [ArtifactSpatialFeature] = []
            for await batch in group { result.append(contentsOf: batch) }
            return result.sorted { $0.eventID < $1.eventID }
        }
        guard !Task.isCancelled else { return nil }
        let assigned = Set(features.map(\.eventID))
        return hierarchy(features: features, channels: channels,
            unassignedIDs: examples.map(\.id).filter { !assigned.contains($0) })
    }

    /// Shared signed unit-vector tree builder. Waveform callers optionally retain
    /// centroids so drawing subgroup averages requires no analysis on the main actor.
    static func hierarchy(features: [ArtifactSpatialFeature], channels: [Int],
                          unassignedIDs: [String], storesCentroids: Bool = false) -> ArtifactSpatialHierarchy? {
        guard !Task.isCancelled else { return nil }
        let dimension = features.first?.vector.count ?? 0
        var nodes: [ArtifactSpatialHierarchy.Node] = []
        func centroid(_ indices: [Int]) -> [Double]? {
            var sum = [Double](repeating: 0, count: dimension)
            for index in indices { for c in sum.indices { sum[c] += features[index].vector[c] } }
            return normalized(sum)
        }
        func append(_ indices: [Int], depth: Int) -> Int {
            let center = centroid(indices)
            let correlations = indices.map { index in center.map { dot(features[index].vector, $0) } ?? -1 }
            let representative = indices.indices.max { correlations[$0] < correlations[$1] } ?? 0
            let quality = correlations.min() ?? -1
            var children: [Int] = []
            if indices.count > 1, quality < 0.9999, depth < 32, !Task.isCancelled {
                let seedA = indices[indices.indices.min { correlations[$0] < correlations[$1] } ?? 0]
                let seedB = indices.min { dot(features[$0].vector, features[seedA].vector) < dot(features[$1].vector, features[seedA].vector) }!
                var a = features[seedA].vector, b = features[seedB].vector
                var left: [Int] = [], right: [Int] = []
                for _ in 0..<12 {
                    if Task.isCancelled { break }
                    let previous = left
                    left = []; right = []
                    for index in indices {
                        if dot(features[index].vector, a) >= dot(features[index].vector, b) { left.append(index) }
                        else { right.append(index) }
                    }
                    if left.isEmpty || right.isEmpty { break }
                    a = centroid(left) ?? a; b = centroid(right) ?? b
                    if left == previous { break }
                }
                if !left.isEmpty, !right.isEmpty {
                    children = [append(left, depth: depth + 1), append(right, depth: depth + 1)]
                }
            }
            let id = nodes.count
            nodes.append(.init(group: ArtifactSpatialGroup(id: id,
                eventIDs: indices.map { features[$0].eventID },
                representativeID: features[indices[representative]].eventID,
                minimumCorrelation: max(-1, min(quality, 1)),
                meanFeature: storesCentroids ? center ?? [] : []), children: children))
            return id
        }
        let root = features.isEmpty ? nil : append(Array(features.indices), depth: 0)
        guard !Task.isCancelled else { return nil }
        return ArtifactSpatialHierarchy(channels: channels, features: features,
            unassignedIDs: unassignedIDs, nodes: nodes, root: root)
    }
}

/// Small session cache, keyed by the same source revision/definition/mask key as review.
/// Cancellation never publishes a partial hierarchy.
actor ArtifactSpatialGroupingCache {
    static let shared = ArtifactSpatialGroupingCache()
    private var entries: [String: ArtifactSpatialHierarchy] = [:]
    private var order: [String] = []
    func value(for key: String) -> ArtifactSpatialHierarchy? { entries[key] }
    func insert(_ value: ArtifactSpatialHierarchy, for key: String) {
        entries[key] = value
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 3 { entries.removeValue(forKey: order.removeFirst()) }
    }
}
