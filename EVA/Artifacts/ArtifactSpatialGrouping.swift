import Foundation

/// Session-only derived features. Nothing here changes review decisions or cleaning.
nonisolated struct ArtifactSpatialFeature: Sendable {
    let eventID: String
    let vector: [Double]
}

/// Whether a scalp field and its global sign reversal describe different
/// families. Ocular dipoles commonly appear in both orientations, so Review can
/// group their spatial axis while retaining each event's orientation.
nonisolated enum ArtifactSpatialPolarityMode: String, CaseIterable, Identifiable, Sendable {
    case signed = "Signed"
    case ignoreGlobalPolarity = "Ignore global polarity"
    var id: String { rawValue }
}

/// AFNI-inspired comparison costs for polarity-invariant scalp fields. Signed
/// grouping deliberately remains ordinary Pearson correlation.
nonisolated enum ArtifactSpatialSimilarityMetric: String, CaseIterable, Identifiable, Sendable {
    case globalPearson = "Global Pearson"
    case localPearson = "Local Pearson"
    case spearman = "Spearman"
    case robustComposite = "Robust composite"
    case informationComposite = "Information composite"
    var id: String { rawValue }
}

nonisolated struct ArtifactSpatialGroup: Identifiable, Sendable {
    let id: Int
    let eventIDs: [String]
    let representativeID: String
    /// Minimum selected comparison score to this group's normalized centroid.
    let minimumCorrelation: Double
    /// Optional cached normalized centroid for waveform subgroup previews.
    var meanFeature: [Double] = []
    /// One orientation per event ID, relative to this node's canonical centroid.
    /// These signs preserve direction after projective (polarity-invariant)
    /// grouping and can orient nested waveform profiles without changing raw data.
    var orientationSigns: [Int8] = []
    var polarityMode: ArtifactSpatialPolarityMode = .signed
    var similarityMetric: ArtifactSpatialSimilarityMetric = .globalPearson

    var positiveOrientationCount: Int { orientationSigns.filter { $0 >= 0 }.count }
    var negativeOrientationCount: Int { orientationSigns.filter { $0 < 0 }.count }
    func orientationSign(for eventID: String) -> Double {
        guard let index = eventIDs.firstIndex(of: eventID), orientationSigns.indices.contains(index) else { return 1 }
        return orientationSigns[index] < 0 ? -1 : 1
    }
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

    /// One overlapping neighborhood per sensor. The size grows slowly with the
    /// montage, stays bounded, and uses physical layout rather than channel order.
    static func localNeighborhoods(channels: [Int], layout: SensorLayout?) -> [[Int]] {
        guard channels.count >= 3, let layout else { return [] }
        let positions = Dictionary(layout.positions.map { ($0.channelIndex, $0) },
            uniquingKeysWith: { first, _ in first })
        guard channels.allSatisfy({ positions[$0] != nil }) else { return [] }
        let size = min(channels.count, max(3, min(12, Int(Double(channels.count).squareRoot().rounded()))))
        return channels.indices.map { center in
            let origin = positions[channels[center]]!
            return channels.indices.sorted { lhs, rhs in
                let a = positions[channels[lhs]]!, b = positions[channels[rhs]]!
                let da = pow(a.x - origin.x, 2) + pow(a.y - origin.y, 2)
                let db = pow(b.x - origin.x, 2) + pow(b.y - origin.y, 2)
                if da == db { return channels[lhs] < channels[rhs] }
                return da < db
            }.prefix(size).sorted()
        }
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double], indices: [Int]? = nil) -> Double? {
        let selected = indices ?? Array(lhs.indices)
        guard selected.count >= 3, lhs.count == rhs.count,
              selected.allSatisfy({ lhs.indices.contains($0) }) else { return nil }
        let lm = selected.reduce(0) { $0 + lhs[$1] } / Double(selected.count)
        let rm = selected.reduce(0) { $0 + rhs[$1] } / Double(selected.count)
        var numerator = 0.0, left = 0.0, right = 0.0
        for index in selected {
            let a = lhs[index] - lm, b = rhs[index] - rm
            numerator += a * b; left += a * a; right += b * b
        }
        let denominator = sqrt(left * right)
        guard denominator.isFinite, denominator > 1e-12 else { return nil }
        return max(-1, min(1, numerator / denominator))
    }

    private static func rankVector(_ values: [Double]) -> [Double]? {
        guard values.count >= 3, values.allSatisfy(\.isFinite) else { return nil }
        let order = values.indices.sorted {
            if values[$0] == values[$1] { return $0 < $1 }
            return values[$0] < values[$1]
        }
        var ranks = [Double](repeating: 0, count: values.count)
        var start = 0
        while start < order.count {
            var end = start + 1
            while end < order.count, values[order[end]] == values[order[start]] { end += 1 }
            let average = Double(start + end - 1) / 2
            for location in start..<end { ranks[order[location]] = average }
            start = end
        }
        return normalized(ranks)
    }

    private static func trimmedCorrelation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let keep = max(3, Int(ceil(Double(lhs.count) * 0.85)))
        let indices = lhs.indices.sorted {
            let a = abs(lhs[$0] - rhs[$0]), b = abs(lhs[$1] - rhs[$1])
            if a == b { return $0 < $1 }
            return a < b
        }.prefix(keep)
        return correlation(lhs, rhs, indices: Array(indices)) ?? dot(lhs, rhs)
    }

    /// Histogram-derived terms are intentionally blended with electrode-wise
    /// Pearson agreement. Distribution agreement alone would discard scalp location.
    private static func informationAgreement(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = lhs.count
        guard count >= 4 else { return max(0, dot(lhs, rhs)) }
        let bins = max(3, min(8, Int(Double(count).squareRoot().rounded())))
        let lower = min(lhs.min() ?? 0, rhs.min() ?? 0)
        let upper = max(lhs.max() ?? 0, rhs.max() ?? 0)
        guard upper - lower > 1e-12 else { return 0 }
        func bin(_ value: Double) -> Int {
            min(bins - 1, max(0, Int((value - lower) / (upper - lower) * Double(bins))))
        }
        let xb = lhs.map(bin), yb = rhs.map(bin)
        var xCounts = [Double](repeating: 0, count: bins)
        var yCounts = [Double](repeating: 0, count: bins)
        var joint = [Double](repeating: 0, count: bins * bins)
        for index in lhs.indices {
            xCounts[xb[index]] += 1; yCounts[yb[index]] += 1
            joint[xb[index] * bins + yb[index]] += 1
        }
        func entropy(_ counts: [Double]) -> Double {
            counts.reduce(0) { result, value in
                guard value > 0 else { return result }
                let probability = value / Double(count)
                return result - probability * log(probability)
            }
        }
        let hx = entropy(xCounts), hy = entropy(yCounts), hxy = entropy(joint)
        let mutualInformation = max(0, hx + hy - hxy)
        let normalizedMI = hx + hy > 1e-12 ? min(1, 2 * mutualInformation / (hx + hy)) : 0
        let hellingerAffinity = zip(xCounts, yCounts).reduce(0) {
            $0 + sqrt(($1.0 / Double(count)) * ($1.1 / Double(count)))
        }
        func correlationRatio(groups: [Int], values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(count)
            let total = values.reduce(0) { $0 + pow($1 - mean, 2) }
            guard total > 1e-12 else { return 0 }
            var grouped = [[Double]](repeating: [], count: bins)
            for index in values.indices { grouped[groups[index]].append(values[index]) }
            let between = grouped.reduce(0.0) { result, values in
                guard !values.isEmpty else { return result }
                let groupMean = values.reduce(0, +) / Double(values.count)
                return result + Double(values.count) * pow(groupMean - mean, 2)
            }
            return max(0, min(1, between / total))
        }
        let symmetricRatio = (correlationRatio(groups: xb, values: rhs)
            + correlationRatio(groups: yb, values: lhs)) / 2
        return 0.4 * normalizedMI + 0.3 * hellingerAffinity + 0.3 * symmetricRatio
    }

    /// All polarity-invariant costs first choose exactly one orientation from
    /// global Pearson correlation. Neighborhoods and histogram terms cannot flip
    /// independently, which preserves the physical meaning of a scalp field.
    static func similarityScore(_ lhs: [Double], _ rhs: [Double],
                                polarityMode: ArtifactSpatialPolarityMode,
                                metric: ArtifactSpatialSimilarityMetric,
                                localNeighborhoods: [[Int]] = []) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        let raw = dot(lhs, rhs)
        guard polarityMode == .ignoreGlobalPolarity else { return max(-1, min(1, raw)) }
        let aligned = raw < 0 ? rhs.map { -$0 } : rhs
        let global = abs(raw)
        if global > 1 - 1e-12 { return 1 }
        func localScore() -> Double {
            let values = localNeighborhoods.compactMap { correlation(lhs, aligned, indices: $0) }
            return values.isEmpty ? global : values.reduce(0, +) / Double(values.count)
        }
        func rankScore() -> Double {
            guard let a = rankVector(lhs), let b = rankVector(aligned) else { return global }
            return dot(a, b)
        }
        let score: Double
        switch metric {
        case .globalPearson:
            score = global
        case .localPearson:
            score = localScore()
        case .spearman:
            score = rankScore()
        case .robustComposite:
            score = 0.30 * global + 0.30 * localScore()
                + 0.25 * rankScore() + 0.15 * trimmedCorrelation(lhs, aligned)
        case .informationComposite:
            score = 0.55 * global + 0.45 * informationAgreement(lhs, aligned)
        }
        return max(-1, min(1, score))
    }

    /// Bounded parallel normalization, followed by a deterministic divisive spherical tree.
    /// No n×n distance matrix is retained. Raw amplitude is deliberately factored out.
    static func build(examples: [ArtifactReviewExample],
                      layout: SensorLayout? = nil,
                      polarityMode: ArtifactSpatialPolarityMode = .signed,
                      similarityMetric: ArtifactSpatialSimilarityMetric = .globalPearson) async -> ArtifactSpatialHierarchy? {
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
        let neighborhoods = localNeighborhoods(channels: channels, layout: layout)
        return hierarchy(features: features, channels: channels,
            unassignedIDs: examples.map(\.id).filter { !assigned.contains($0) }, polarityMode: polarityMode,
            similarityMetric: similarityMetric, localNeighborhoods: neighborhoods)
    }

    /// Shared unit-vector tree builder. Projective mode treats `v` and `-v` as
    /// the same spatial axis, but sign-aligns members before averaging so opposite
    /// orientations never cancel. Waveform callers optionally retain centroids so
    /// drawing subgroup averages requires no analysis on the main actor.
    static func hierarchy(features: [ArtifactSpatialFeature], channels: [Int],
                          unassignedIDs: [String],
                          polarityMode: ArtifactSpatialPolarityMode = .signed,
                          similarityMetric: ArtifactSpatialSimilarityMetric = .globalPearson,
                          localNeighborhoods: [[Int]] = [],
                          storesCentroids: Bool = false) -> ArtifactSpatialHierarchy? {
        guard !Task.isCancelled else { return nil }
        let dimension = features.first?.vector.count ?? 0
        var nodes: [ArtifactSpatialHierarchy.Node] = []
        func centroid(_ indices: [Int]) -> [Double]? {
            guard let first = indices.first else { return nil }
            if polarityMode == .signed {
                var sum = [Double](repeating: 0, count: dimension)
                for index in indices { for c in sum.indices { sum[c] += features[index].vector[c] } }
                return normalized(sum)
            }
            // A projective mean: iteratively orient every member toward the
            // current axis, then average. Anchor the final sign to the first
            // deterministic member so orientation labels are stable across runs.
            let anchor = features[first].vector
            var center = anchor
            for _ in 0..<12 {
                var sum = [Double](repeating: 0, count: dimension)
                for index in indices {
                    let vector = features[index].vector
                    let sign = dot(vector, center) < 0 ? -1.0 : 1.0
                    for c in sum.indices { sum[c] += sign * vector[c] }
                }
                guard var next = normalized(sum) else { return nil }
                if dot(next, anchor) < 0 { next = next.map { -$0 } }
                let settled = abs(dot(next, center)) > 1 - 1e-12
                center = next
                if settled { break }
            }
            return center
        }
        func similarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
            similarityScore(lhs, rhs, polarityMode: polarityMode,
                metric: similarityMetric, localNeighborhoods: localNeighborhoods)
        }
        func append(_ indices: [Int], depth: Int) -> Int {
            let center = centroid(indices)
            let correlations = indices.map { index in center.map { similarity(features[index].vector, $0) } ?? -1 }
            let representative = indices.indices.max { correlations[$0] < correlations[$1] } ?? 0
            let quality = correlations.min() ?? -1
            var children: [Int] = []
            if indices.count > 1, quality < 0.9999, depth < 32, !Task.isCancelled {
                let seedA = indices[indices.indices.min { correlations[$0] < correlations[$1] } ?? 0]
                let seedB = indices.min {
                    similarity(features[$0].vector, features[seedA].vector)
                        < similarity(features[$1].vector, features[seedA].vector)
                }!
                var a = features[seedA].vector, b = features[seedB].vector
                var left: [Int] = [], right: [Int] = []
                for _ in 0..<12 {
                    if Task.isCancelled { break }
                    let previous = left
                    left = []; right = []
                    for index in indices {
                        if similarity(features[index].vector, a) >= similarity(features[index].vector, b) { left.append(index) }
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
            let signs: [Int8] = indices.map { index in
                guard polarityMode == .ignoreGlobalPolarity, let center else { return 1 }
                return dot(features[index].vector, center) < 0 ? -1 : 1
            }
            nodes.append(.init(group: ArtifactSpatialGroup(id: id,
                eventIDs: indices.map { features[$0].eventID },
                representativeID: features[indices[representative]].eventID,
                minimumCorrelation: max(-1, min(quality, 1)),
                meanFeature: storesCentroids || polarityMode == .ignoreGlobalPolarity ? center ?? [] : [],
                orientationSigns: signs, polarityMode: polarityMode,
                similarityMetric: polarityMode == .signed ? .globalPearson : similarityMetric), children: children))
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
