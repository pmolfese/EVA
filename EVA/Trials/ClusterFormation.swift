//
//  ClusterFormation.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The channel x time lattice on which clusters are grown, shared by the t and
//  F analyzers. Both the fixed-threshold cluster-mass statistic (Maris &
//  Oostenveld 2007) and threshold-free cluster enhancement (Smith & Nichols
//  2009) live here so the two analyzers differ only in the statistic they map
//  onto the lattice.
//

import Foundation

// MARK: - Cluster

/// A connected set of channel x time points surviving cluster correction.
nonisolated struct SpatiotemporalCluster: Identifiable, Sendable, Equatable {
    let id: Int
    /// Positive means the first condition exceeds the second; negative the
    /// reverse. Always 1 for intrinsically non-negative statistics such as F.
    let sign: Int
    let pointIndices: [Int]
    /// Summed statistic for cluster-mass inference; peak TFCE score under TFCE.
    let mass: Double
    let pValue: Double
    let startSample: Int
    let endSample: Int
    let channelIndices: [Int]

    /// Re-labels a cluster after the display sort without disturbing anything else.
    func withID(_ newID: Int) -> SpatiotemporalCluster {
        SpatiotemporalCluster(
            id: newID,
            sign: sign,
            pointIndices: pointIndices,
            mass: mass,
            pValue: pValue,
            startSample: startSample,
            endSample: endSample,
            channelIndices: channelIndices
        )
    }
}

// MARK: - Inference mode

nonisolated enum ClusterInferenceMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case clusterMass = "Cluster mass"
    case tfce = "TFCE"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .clusterMass:
            return "Maris & Oostenveld cluster mass: points passing the cluster-forming threshold are grown into clusters and each cluster's summed statistic is compared against the permutation distribution of the largest cluster."
        case .tfce:
            return "Threshold-free cluster enhancement: every point is scored by integrating cluster extent over all thresholds, removing the arbitrary cluster-forming threshold at the cost of a slower run."
        }
    }
}

/// Smith & Nichols' recommended exponents. Exposed because the defaults were
/// tuned for fMRI volumes, and EEG channel x time lattices are far sparser
/// spatially, so users occasionally need to move E.
nonisolated struct TFCEParameters: Sendable, Equatable {
    /// Extent exponent.
    var extentExponent = 0.5
    /// Height exponent.
    var heightExponent = 2.0
    /// Number of integration steps between zero and the statistic maximum.
    var stepCount = 50

    static let `default` = TFCEParameters()

    var isValid: Bool {
        extentExponent >= 0 && extentExponent.isFinite
            && heightExponent >= 0 && heightExponent.isFinite
            && stepCount >= 2 && stepCount <= 500
    }
}

/// How a cluster-forming threshold was specified. Resolved against the design's
/// degrees of freedom once the analyzer knows them.
nonisolated enum ClusterFormingThreshold: Sendable, Equatable {
    /// A raw statistic value: `|t| >= value`, or `F >= value`.
    case statistic(Double)
    /// An uncorrected tail probability, converted to the equivalent statistic.
    case probability(Double)
}

// MARK: - Grid

/// Precomputed neighbor lists over flattened `channel * sampleCount + sample`
/// feature indices. Building this once per analysis rather than re-deriving
/// neighbors inside every permutation is what makes TFCE affordable: the
/// threshold-free integration visits the lattice tens of times per permutation.
nonisolated struct ClusterGrid: Sendable {
    let channelCount: Int
    let sampleCount: Int
    let featureCount: Int
    /// CSR layout: neighbors of feature `i` are
    /// `neighborIndices[neighborOffsets[i] ..< neighborOffsets[i + 1]]`.
    private let neighborOffsets: [Int32]
    private let neighborIndices: [Int32]

    init(channelCount: Int, sampleCount: Int, spatialAdjacency: [[Int]]) {
        self.channelCount = channelCount
        self.sampleCount = sampleCount
        featureCount = channelCount * sampleCount

        var offsets = [Int32](repeating: 0, count: featureCount + 1)
        var indices: [Int32] = []
        indices.reserveCapacity(featureCount * 6)

        for channel in 0..<channelCount {
            let spatialNeighbors = channel < spatialAdjacency.count
                ? spatialAdjacency[channel].filter { $0 >= 0 && $0 < channelCount && $0 != channel }
                : []
            for sample in 0..<sampleCount {
                let feature = channel * sampleCount + sample
                if sample > 0 { indices.append(Int32(feature - 1)) }
                if sample + 1 < sampleCount { indices.append(Int32(feature + 1)) }
                for neighbor in spatialNeighbors {
                    indices.append(Int32(neighbor * sampleCount + sample))
                }
                offsets[feature + 1] = Int32(indices.count)
            }
        }
        neighborOffsets = offsets
        neighborIndices = indices
    }

    /// Scratch buffers reused across the many component passes a single
    /// permutation performs. Stamp-based visitation avoids re-zeroing the
    /// whole lattice between passes.
    final class Workspace {
        var visitStamp: [Int32]
        var currentStamp: Int32 = 0
        var queue: [Int32]

        init(featureCount: Int) {
            visitStamp = [Int32](repeating: 0, count: featureCount)
            queue = []
            queue.reserveCapacity(min(featureCount, 4_096))
        }

        func beginPass() {
            currentStamp &+= 1
            if currentStamp == Int32.max {
                for index in visitStamp.indices { visitStamp[index] = 0 }
                currentStamp = 1
            }
            queue.removeAll(keepingCapacity: true)
        }
    }

    func makeWorkspace() -> Workspace { Workspace(featureCount: featureCount) }

    // MARK: Fixed-threshold clusters

    struct Candidate {
        let sign: Int
        let points: [Int]
        let mass: Double
        let startSample: Int
        let endSample: Int
        let channels: [Int]
    }

    /// Grows sign-constrained connected components of points at or beyond
    /// `threshold`. `signed` false treats the statistic as non-negative (F).
    func formClusters(
        statistics: [Double],
        threshold: Double,
        signed: Bool,
        workspace: Workspace
    ) -> [Candidate] {
        workspace.beginPass()
        var output: [Candidate] = []
        statistics.withUnsafeBufferPointer { values in
            neighborOffsets.withUnsafeBufferPointer { offsets in
                neighborIndices.withUnsafeBufferPointer { adjacency in
                    for seed in 0..<featureCount {
                        let seedValue = values[seed]
                        guard abs(seedValue) >= threshold else { continue }
                        if workspace.visitStamp[seed] == workspace.currentStamp { continue }
                        let sign = (!signed || seedValue >= 0) ? 1 : -1

                        workspace.queue.removeAll(keepingCapacity: true)
                        workspace.queue.append(Int32(seed))
                        workspace.visitStamp[seed] = workspace.currentStamp

                        var cursor = 0
                        var mass = 0.0
                        var points: [Int] = []
                        var channels = Set<Int>()
                        var startSample = sampleCount
                        var endSample = 0

                        while cursor < workspace.queue.count {
                            let point = Int(workspace.queue[cursor])
                            cursor += 1
                            points.append(point)
                            mass += signed ? abs(values[point]) : values[point]
                            channels.insert(point / sampleCount)
                            let sample = point % sampleCount
                            startSample = min(startSample, sample)
                            endSample = max(endSample, sample)

                            for slot in Int(offsets[point])..<Int(offsets[point + 1]) {
                                let neighbor = Int(adjacency[slot])
                                guard workspace.visitStamp[neighbor] != workspace.currentStamp else { continue }
                                let value = values[neighbor]
                                guard abs(value) >= threshold else { continue }
                                guard !signed || (value >= 0 ? 1 : -1) == sign else { continue }
                                workspace.visitStamp[neighbor] = workspace.currentStamp
                                workspace.queue.append(Int32(neighbor))
                            }
                        }

                        output.append(Candidate(
                            sign: sign,
                            points: points.sorted(),
                            mass: mass,
                            startSample: startSample,
                            endSample: endSample,
                            channels: channels.sorted()
                        ))
                    }
                }
            }
        }
        return output
    }

    /// Largest cluster mass, the family-wise null statistic. Skips the
    /// bookkeeping `formClusters` does for display.
    func maximumClusterMass(
        statistics: [Double],
        threshold: Double,
        signed: Bool,
        workspace: Workspace
    ) -> Double {
        workspace.beginPass()
        var best = 0.0
        statistics.withUnsafeBufferPointer { values in
            neighborOffsets.withUnsafeBufferPointer { offsets in
                neighborIndices.withUnsafeBufferPointer { adjacency in
                    for seed in 0..<featureCount {
                        let seedValue = values[seed]
                        guard abs(seedValue) >= threshold else { continue }
                        if workspace.visitStamp[seed] == workspace.currentStamp { continue }
                        let sign = (!signed || seedValue >= 0) ? 1 : -1

                        workspace.queue.removeAll(keepingCapacity: true)
                        workspace.queue.append(Int32(seed))
                        workspace.visitStamp[seed] = workspace.currentStamp

                        var cursor = 0
                        var mass = 0.0
                        while cursor < workspace.queue.count {
                            let point = Int(workspace.queue[cursor])
                            cursor += 1
                            mass += signed ? abs(values[point]) : values[point]
                            for slot in Int(offsets[point])..<Int(offsets[point + 1]) {
                                let neighbor = Int(adjacency[slot])
                                guard workspace.visitStamp[neighbor] != workspace.currentStamp else { continue }
                                let value = values[neighbor]
                                guard abs(value) >= threshold else { continue }
                                guard !signed || (value >= 0 ? 1 : -1) == sign else { continue }
                                workspace.visitStamp[neighbor] = workspace.currentStamp
                                workspace.queue.append(Int32(neighbor))
                            }
                        }
                        best = max(best, mass)
                    }
                }
            }
        }
        return best
    }

    // MARK: Threshold-free cluster enhancement

    /// TFCE score at every point, signed to preserve effect direction.
    ///
    /// The textbook formulation re-runs connected components at every one of
    /// `stepCount` thresholds, which costs `stepCount` full lattice sweeps per
    /// permutation. Because components only ever merge as the threshold falls,
    /// the same integral can be accumulated with a single descending sweep: a
    /// union-find keeps the components, each threshold level charges its
    /// contribution to component roots rather than to individual points, and
    /// one pass back down the merge forest distributes those charges to
    /// members. That is O(n log n) instead of O(n x stepCount).
    func tfceScores(
        statistics: [Double],
        signed: Bool,
        parameters: TFCEParameters
    ) -> [Double] {
        var scores = [Double](repeating: 0, count: featureCount)
        guard parameters.isValid, statistics.count == featureCount else { return scores }

        var magnitudes = [Double](repeating: 0, count: featureCount)
        var peak = 0.0
        for index in 0..<featureCount {
            let magnitude = signed ? abs(statistics[index]) : max(statistics[index], 0)
            magnitudes[index] = magnitude
            peak = max(peak, magnitude)
        }
        guard peak > 0, peak.isFinite else { return scores }

        let stepHeight = peak / Double(parameters.stepCount)
        // Features in descending magnitude: the order in which they activate as
        // the integration threshold falls.
        let order = (0..<featureCount)
            .filter { magnitudes[$0] > 0 }
            .sorted { magnitudes[$0] > magnitudes[$1] }

        var parent = [Int32](repeating: -1, count: featureCount)   // union-find
        var componentSize = [Int32](repeating: 0, count: featureCount)
        var active = [Bool](repeating: false, count: featureCount)
        var pending = [Double](repeating: 0, count: featureCount)
        var mergeChild: [Int32] = []
        var mergeParent: [Int32] = []
        /// The parent's accumulated charge at the moment of the merge. The
        /// child's members were not part of the parent's component before then,
        /// so only what the parent accrues *after* this point may flow down.
        var parentChargeAtMerge: [Double] = []
        var activeRoots: [Int32] = []

        func find(_ start: Int32) -> Int32 {
            var root = start
            while parent[Int(root)] >= 0 { root = parent[Int(root)] }
            var cursor = start
            while parent[Int(cursor)] >= 0 {
                let next = parent[Int(cursor)]
                parent[Int(cursor)] = root
                cursor = next
            }
            return root
        }

        var cursor = 0
        // Descend through the integration levels, highest first.
        for step in stride(from: parameters.stepCount, through: 1, by: -1) {
            let height = stepHeight * Double(step)

            while cursor < order.count, magnitudes[order[cursor]] >= height {
                let feature = Int32(order[cursor])
                cursor += 1
                active[Int(feature)] = true
                componentSize[Int(feature)] = 1
                activeRoots.append(feature)

                let sign = statistics[Int(feature)] >= 0 ? 1 : -1
                for slot in Int(neighborOffsets[Int(feature)])..<Int(neighborOffsets[Int(feature) + 1]) {
                    let neighbor = Int(neighborIndices[slot])
                    guard active[neighbor] else { continue }
                    if signed, (statistics[neighbor] >= 0 ? 1 : -1) != sign { continue }
                    let a = find(feature)
                    let b = find(Int32(neighbor))
                    guard a != b else { continue }
                    // Union by size; the absorbed root is recorded so its
                    // members can collect the parent's later charges.
                    let (child, root) = componentSize[Int(a)] < componentSize[Int(b)] ? (a, b) : (b, a)
                    parent[Int(child)] = root
                    componentSize[Int(root)] += componentSize[Int(child)]
                    mergeChild.append(child)
                    mergeParent.append(root)
                    parentChargeAtMerge.append(pending[Int(root)])
                }
            }

            guard !activeRoots.isEmpty else { continue }
            let heightTerm = pow(height, parameters.heightExponent) * stepHeight
            var write = 0
            for slot in 0..<activeRoots.count {
                let candidate = activeRoots[slot]
                // Absorbed roots are dropped here rather than at merge time so
                // removal stays O(1) amortized.
                guard parent[Int(candidate)] < 0 else { continue }
                activeRoots[write] = candidate
                write += 1
                pending[Int(candidate)] += pow(Double(componentSize[Int(candidate)]), parameters.extentExponent)
                    * heightTerm
            }
            activeRoots.removeLast(activeRoots.count - write)
        }

        // Push each component's charges down to everything it absorbed. Reverse
        // merge order guarantees a parent's total is complete before a child
        // reads it, because a parent can only itself be absorbed later in time.
        for index in stride(from: mergeChild.count - 1, through: 0, by: -1) {
            let child = Int(mergeChild[index])
            let root = Int(mergeParent[index])
            pending[child] += pending[root] - parentChargeAtMerge[index]
        }

        for index in 0..<featureCount where active[index] {
            let magnitude = pending[index]
            scores[index] = (signed && statistics[index] < 0) ? -magnitude : magnitude
        }
        return scores
    }

    /// Connected components of points whose corrected p-value passes `alpha`.
    /// TFCE corrects point-wise, so the reported "clusters" are a readability
    /// grouping of the surviving points, not the inference unit.
    func componentsOfSignificantPoints(
        scores: [Double],
        pValues: [Double],
        alpha: Double,
        signed: Bool,
        workspace: Workspace
    ) -> [Candidate] {
        var mask = [Double](repeating: 0, count: featureCount)
        for index in 0..<featureCount where pValues[index] <= alpha {
            // Reuse the thresholded grower by handing it a masked field whose
            // only supra-threshold points are the significant ones.
            mask[index] = signed ? (scores[index] >= 0 ? 1 : -1) : 1
        }
        let components = formClusters(statistics: mask, threshold: 1, signed: signed, workspace: workspace)
        return components.map { component in
            Candidate(
                sign: component.sign,
                points: component.points,
                mass: component.points.map { abs(scores[$0]) }.max() ?? 0,
                startSample: component.startSample,
                endSample: component.endSample,
                channels: component.channels
            )
        }
    }
}

// MARK: - Parallel result storage

/// Disjoint-index result buffer for the concurrent permutation map. The pointer
/// is initialized before workers start, every worker writes a unique index, and
/// deallocation happens only after all synchronous GCD waves have returned.
nonisolated final class PermutationValueStorage: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<Double>
    private let count: Int

    init(count: Int) {
        self.count = max(count, 0)
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(repeating: 0, count: max(count, 1))
    }

    subscript(index: Int) -> Double {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }

    var values: [Double] { Array(UnsafeBufferPointer(start: pointer, count: count)) }

    func deallocate() {
        pointer.deinitialize(count: max(count, 1))
        pointer.deallocate()
    }
}

// MARK: - Shared correction helpers

nonisolated enum ClusterCorrection {
    /// Monte-Carlo p with the observed statistic included in its own null, so
    /// the smallest attainable p is `1 / (permutations + 1)` and the test stays
    /// exact rather than reporting an impossible p = 0.
    static func pValue(observed: Double, nullMaxima: [Double]) -> Double {
        let exceedances = nullMaxima.reduce(into: 0) { count, value in
            if value >= observed { count += 1 }
        }
        return Double(exceedances + 1) / Double(nullMaxima.count + 1)
    }

    /// Point-wise corrected p from the max-statistic null, used by TFCE.
    static func pointPValues(scores: [Double], nullMaxima: [Double]) -> [Double] {
        guard !nullMaxima.isEmpty else { return [Double](repeating: 1, count: scores.count) }
        let sorted = nullMaxima.sorted()
        let denominator = Double(nullMaxima.count + 1)
        return scores.map { score in
            let magnitude = abs(score)
            // Number of null maxima >= magnitude, via the sorted null.
            var low = 0
            var high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid] < magnitude { low = mid + 1 } else { high = mid }
            }
            return Double(sorted.count - low + 1) / denominator
        }
    }

    /// Orders clusters for display: most significant first, ties broken by mass.
    static func sortedForDisplay(_ clusters: [SpatiotemporalCluster]) -> [SpatiotemporalCluster] {
        clusters
            .sorted {
                if $0.pValue != $1.pValue { return $0.pValue < $1.pValue }
                return $0.mass > $1.mass
            }
            .enumerated()
            .map { $1.withID($0) }
    }
}
