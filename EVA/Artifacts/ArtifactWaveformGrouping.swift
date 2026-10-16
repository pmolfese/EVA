import Foundation

/// One cached waveform tree for one spatial family. It never merges spatial families.
nonisolated struct ArtifactWaveformGroupingResult: Sendable {
    let hierarchy: ArtifactSpatialHierarchy
    let channelIndices: [Int]
    let pointsPerChannel: Int
    let maximumAlignmentSeconds: Double
    let alignmentReferenceID: String?

    func waveform(_ feature: [Double], channel: Int) -> [Float] {
        guard let index = channelIndices.firstIndex(of: channel), pointsPerChannel > 0,
              feature.count == channelIndices.count * pointsPerChannel else { return [] }
        return feature[(index * pointsPerChannel)..<((index + 1) * pointsPerChannel)].map(Float.init)
    }
}

nonisolated enum ArtifactWaveformGrouping {
    /// Use a fixed set of up to five energetic definition channels for the family.
    /// Profiles are downsampled to at most 64 points/channel to bound cache/work size.
    static func build(analysis: ArtifactReviewAnalysis, family: ArtifactSpatialGroup,
                      windowSeconds: Double) async -> ArtifactWaveformGroupingResult? {
        guard !Task.isCancelled else { return nil }
        let ids = Set(family.eventIDs)
        let sourcePoints = analysis.pointsPerChannel
        let members = analysis.examples.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
        let valid = members.filter {
            $0.hasCompleteWindow && sourcePoints >= 3 && !analysis.channelIndices.isEmpty &&
            $0.samples.count == sourcePoints * analysis.channelIndices.count && $0.samples.allSatisfy(\.isFinite)
        }
        var energies = [Double](repeating: 0, count: analysis.channelIndices.count)
        for example in valid {
            if Task.isCancelled { return nil }
            // Normalize each event's contribution to prevent a single large event
            // from choosing the family's channel set on its own.
            var eventEnergies = [Double](repeating: 0, count: energies.count)
            for channel in eventEnergies.indices {
                let row = example.samples[(channel * sourcePoints)..<((channel + 1) * sourcePoints)]
                let mean = row.reduce(0.0) { $0 + Double($1) } / Double(sourcePoints)
                eventEnergies[channel] = row.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
            }
            let total = eventEnergies.reduce(0, +)
            if total > 1e-12 { for index in energies.indices { energies[index] += eventEnergies[index] / total } }
        }
        let offsets = energies.indices.filter { energies[$0] > 1e-12 }.sorted {
            if energies[$0] == energies[$1] { return analysis.channelIndices[$0] < analysis.channelIndices[$1] }
            return energies[$0] > energies[$1]
        }.prefix(5).sorted { analysis.channelIndices[$0] < analysis.channelIndices[$1] }
        let channels = offsets.map { analysis.channelIndices[$0] }
        let points = min(sourcePoints, 64)
        let secondsPerPoint = windowSeconds.isFinite && windowSeconds > 0 && points > 1
            ? windowSeconds / Double(points - 1) : 0
        let shift = secondsPerPoint > 0 ? min(4, points / 10, Int(floor(0.020 / secondsPerPoint))) : 0
        let croppedPoints = max(points - 2 * shift, 0)

        func profile(_ example: ArtifactReviewExample) -> [Double]? {
            guard points >= 3, !channels.isEmpty else { return nil }
            var result: [Double] = []
            for offset in offsets {
                for point in 0..<points {
                    let location = Double(point) * Double(sourcePoints - 1) / Double(points - 1)
                    let lower = Int(location), upper = min(lower + 1, sourcePoints - 1)
                    let fraction = location - Double(lower)
                    result.append(Double(example.samples[offset * sourcePoints + lower]) * (1 - fraction)
                        + Double(example.samples[offset * sourcePoints + upper]) * fraction)
                }
            }
            return result
        }
        /// A fixed interior support for every shift avoids padding or changing
        /// overlap lengths. Center each channel, then normalize the pooled profile.
        func aligned(_ values: [Double], by lag: Int) -> [Double]? {
            guard croppedPoints >= 3 else { return nil }
            var vector: [Double] = []
            for channel in channels.indices {
                let start = channel * points + shift + lag
                let row = values[start..<(start + croppedPoints)]
                let mean = row.reduce(0, +) / Double(croppedPoints)
                vector.append(contentsOf: row.map { $0 - mean })
            }
            return ArtifactSpatialGrouping.normalized(vector)
        }
        let reference = valid.first { $0.id == family.representativeID && profile($0).flatMap { aligned($0, by: 0) } != nil }
            ?? valid.first { profile($0).flatMap { aligned($0, by: 0) } != nil }
        let referenceVector = reference.flatMap(profile).flatMap { aligned($0, by: 0) }
        let batchSize = max(1, (valid.count + 3) / 4)
        let features = await withTaskGroup(of: [ArtifactSpatialFeature].self) { group in
            for start in stride(from: 0, to: valid.count, by: batchSize) {
                let batch = Array(valid[start..<min(start + batchSize, valid.count)])
                group.addTask {
                    var result: [ArtifactSpatialFeature] = []
                    guard let referenceVector else { return result }
                    // Zero lag wins ties, then smaller shifts. This keeps already
                    // aligned examples stable and never reverses polarity.
                    let lags = [0] + (shift > 0 ? (1...shift).flatMap { [-$0, $0] } : [])
                    for example in batch {
                        if Task.isCancelled { break }
                        guard let raw = profile(example) else { continue }
                        var best: [Double]?, bestScore = -Double.infinity
                        for lag in lags {
                            guard let vector = aligned(raw, by: lag) else { continue }
                            let score = ArtifactSpatialGrouping.dot(vector, referenceVector)
                            if score > bestScore + 1e-12 { best = vector; bestScore = score }
                        }
                        if let best { result.append(.init(eventID: example.id, vector: best)) }
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
        guard let hierarchy = ArtifactSpatialGrouping.hierarchy(features: features, channels: channels,
            unassignedIDs: family.eventIDs.filter { !assigned.contains($0) }, storesCentroids: true) else { return nil }
        return ArtifactWaveformGroupingResult(hierarchy: hierarchy, channelIndices: channels,
            pointsPerChannel: croppedPoints, maximumAlignmentSeconds: Double(shift) * secondsPerPoint,
            alignmentReferenceID: reference?.id)
    }
}

actor ArtifactWaveformGroupingCache {
    static let shared = ArtifactWaveformGroupingCache()
    private var entries: [String: ArtifactWaveformGroupingResult] = [:]
    private var order: [String] = []
    func value(for key: String) -> ArtifactWaveformGroupingResult? { entries[key] }
    func insert(_ value: ArtifactWaveformGroupingResult, for key: String) {
        entries[key] = value
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 6 { entries.removeValue(forKey: order.removeFirst()) }
    }
}
