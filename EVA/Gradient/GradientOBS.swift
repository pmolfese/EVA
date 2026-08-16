//
//  GradientOBS.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Independent implementation written from EVA's own functional specification
//  (docs/provenance/fastr-functional-spec.md) under the clean-room process
//  described in docs/provenance/README.md. No third-party artifact-correction source
//  was consulted. Method reference: Niazy et al., NeuroImage 28(3):720-737, 2005.
//
//  Optimal basis set residual removal.
//
//  Subtracting an averaged template cancels the part of the gradient artifact
//  that repeats identically. What is left over still has structure — the artifact
//  varies from epoch to epoch in ways a single average cannot express. OBS finds
//  the dominant shapes in those leftovers by principal component analysis and
//  removes each epoch's projection onto them.
//
//  The basis is estimated per chunk rather than once per recording, because the
//  residual's shape drifts over a long scan and one basis for the whole session
//  would describe none of it well.
//

import Foundation

nonisolated enum GradientOBS {

    /// Fewest residual epochs that will produce a basis worth using.
    static let minimumEpochsForBasis = 8

    /// Splits epoch indices into contiguous chunks of roughly `chunkSeconds`.
    ///
    /// A trailing chunk that would be too small to support its own basis is
    /// merged into the one before it, so every chunk that is returned has enough
    /// epochs to work with.
    static func chunkRanges(
        epochCount: Int,
        epochPeriodSamples: Int,
        samplingRate: Double,
        chunkSeconds: Double
    ) -> [Range<Int>] {
        guard epochCount > 0 else { return [] }
        guard chunkSeconds > 0, samplingRate > 0, epochPeriodSamples > 0 else {
            return [0..<epochCount]
        }

        let epochsPerChunk = max(
            minimumEpochsForBasis,
            Int((chunkSeconds * samplingRate / Double(epochPeriodSamples)).rounded())
        )
        guard epochsPerChunk < epochCount else { return [0..<epochCount] }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < epochCount {
            let end = min(start + epochsPerChunk, epochCount)
            ranges.append(start..<end)
            start = end
        }
        // Fold an undersized tail back into its predecessor.
        if ranges.count > 1, let last = ranges.last, last.count < minimumEpochsForBasis {
            let previous = ranges[ranges.count - 2]
            ranges.removeLast(2)
            ranges.append(previous.lowerBound..<last.upperBound)
        }
        return ranges
    }

    /// Picks at most `limit` indices, evenly spaced across `candidates`.
    ///
    /// Capping the epoch count keeps the eigen-decomposition affordable on long
    /// recordings. The spec calls for deterministic subsampling, so this strides
    /// through the candidates rather than sampling them randomly.
    static func subsample(_ candidates: [Int], limit: Int) -> [Int] {
        guard limit > 0 else { return [] }
        guard candidates.count > limit else { return candidates }
        var picked: [Int] = []
        picked.reserveCapacity(limit)
        for slot in 0..<limit {
            let step = limit > 1 ? Double(candidates.count - 1) / Double(limit - 1) : 0
            let index = Int((Double(slot) * step).rounded())
            let candidate = candidates[min(index, candidates.count - 1)]
            if picked.last != candidate { picked.append(candidate) }
        }
        return picked
    }

    /// Builds an orthonormal basis for the dominant shapes in `residuals`.
    ///
    /// The residuals are *not* mean-centered across epochs: the average leftover
    /// shape is itself artifact worth removing, and leaving it in place lets the
    /// first component capture it.
    ///
    /// Principal directions come from the epoch-by-epoch Gram matrix rather than
    /// the sample-by-sample covariance. The two have the same non-zero spectrum,
    /// and there are far fewer epochs in a chunk than samples in an epoch, so the
    /// Gram matrix is much smaller to decompose.
    ///
    /// - Parameters:
    ///   - residuals: Equal-length residual epochs, already detrended.
    ///   - mode: How many components to remove.
    ///   - varianceThreshold: For `.automatic`, the share of residual variance the
    ///     retained components must explain.
    ///   - maximumComponents: Ceiling on `.automatic` selection.
    /// - Returns: Orthonormal basis vectors, most significant first.
    static func basis(
        residuals: [[Float]],
        mode: GradientOBSMode,
        varianceThreshold: Double,
        maximumComponents: Int
    ) -> [[Double]] {
        guard mode.isEnabled else { return [] }
        let epochCount = residuals.count
        guard epochCount >= 2, let length = residuals.first?.count, length > 1 else { return [] }
        guard residuals.allSatisfy({ $0.count == length }) else { return [] }
        return computeBasis(
            gramMatrix(residuals),
            residuals,
            mode,
            varianceThreshold,
            maximumComponents
        )
    }

    /// The epoch-by-epoch Gram matrix, row-major and flattened.
    ///
    /// Split out so a compute backend can produce it in bulk. The eigenvalue
    /// ratios drive a discrete component count, so whoever computes this must
    /// hand back `Double` — see the OBS notes in
    /// `docs/provenance/fastr-gpu-port-plan.md`.
    static func gramMatrix(_ residuals: [[Float]]) -> [Double] {
        let epochCount = residuals.count
        guard epochCount > 0, let length = residuals.first?.count else { return [] }
        var gram = [Double](repeating: 0, count: epochCount * epochCount)
        for row in 0..<epochCount {
            for column in row..<epochCount {
                var total = 0.0
                let a = residuals[row]
                let b = residuals[column]
                for index in 0..<length { total += Double(a[index]) * Double(b[index]) }
                gram[row * epochCount + column] = total
                gram[column * epochCount + row] = total
            }
        }
        return gram
    }

    /// Component selection and basis construction, given a Gram matrix computed
    /// elsewhere. `gram` is row-major, `residuals.count` on a side.
    static func basis(
        gram: [Double],
        residuals: [[Float]],
        mode: GradientOBSMode,
        varianceThreshold: Double,
        maximumComponents: Int
    ) -> [[Double]] {
        guard mode.isEnabled else { return [] }
        let epochCount = residuals.count
        guard epochCount >= 2, let length = residuals.first?.count, length > 1 else { return [] }
        guard residuals.allSatisfy({ $0.count == length }) else { return [] }
        guard gram.count == epochCount * epochCount else { return [] }
        return computeBasis(gram, residuals, mode, varianceThreshold, maximumComponents)
    }

    private static func computeBasis(
        _ gram: [Double],
        _ residuals: [[Float]],
        _ mode: GradientOBSMode,
        _ varianceThreshold: Double,
        _ maximumComponents: Int
    ) -> [[Double]] {
        let epochCount = residuals.count
        let length = residuals[0].count

        // Total residual variance, from the trace rather than from a full
        // spectrum. The trace of a symmetric matrix *is* the sum of its
        // eigenvalues, so this is an identity, not an approximation — and it
        // means the share-of-variance test that `.automatic` applies costs O(n)
        // instead of a decomposition.
        var total = 0.0
        for index in 0..<epochCount { total += gram[index * epochCount + index] }
        guard total > 1e-20 else { return [] }

        // How many eigenpairs could possibly be used. `.automatic` stops at
        // `obsMaximumComponents` whatever the variance says, and `.fixed` asks
        // for a specific small number, so this is single digits in practice
        // against an `n` of up to 256. Decomposing all of it and discarding
        // 98% of the eigenvectors was the most expensive thing in the pipeline.
        let usable = min(epochCount, length)
        let wanted: Int
        switch mode {
        case .off:
            return []
        case .fixed(let componentCount):
            wanted = min(max(0, componentCount), usable)
        case .automatic:
            wanted = min(max(1, min(maximumComponents, epochCount)), usable)
        }
        guard wanted > 0 else { return [] }

        let square = (0..<epochCount).map { row in
            Array(gram[(row * epochCount)..<((row + 1) * epochCount)])
        }
        var leading = LinearAlgebra.leadingSymmetricEigenpairs(square, count: wanted)
        if leading.values.count != wanted {
            // The truncated solver declined; take the full spectrum rather than
            // silently returning a worse basis.
            let full = LinearAlgebra.symmetricEigenDecomposition(square)
            guard full.values.count == epochCount else { return [] }
            let order = Array((0..<epochCount).reversed().prefix(wanted))
            leading = (
                values: order.map { full.values[$0] },
                vectors: order.map { source in (0..<epochCount).map { full.vectors[$0][source] } }
            )
        }
        // A Gram matrix is positive semi-definite; anything below zero is
        // rounding, and it should not subtract from the share of variance.
        let eigenvalues = leading.values.map { max($0, 0) }

        let requested: Int
        switch mode {
        case .off:
            return []
        case .fixed(let componentCount):
            requested = max(0, componentCount)
        case .automatic:
            var cumulative = 0.0
            var count = 0
            let cap = max(1, min(maximumComponents, epochCount))
            for value in eigenvalues {
                cumulative += value
                count += 1
                if cumulative / total >= varianceThreshold || count >= cap { break }
            }
            requested = count
        }

        let componentCount = min(requested, usable)
        guard componentCount > 0 else { return [] }

        var vectors: [[Double]] = []
        vectors.reserveCapacity(componentCount)
        for component in 0..<componentCount {
            guard eigenvalues[component] > 1e-20 else { break }
            // An eigenvector of the Gram matrix weights the epochs; combining
            // them with those weights gives the direction in sample space.
            let weights = leading.vectors[component]
            var vector = [Double](repeating: 0, count: length)
            for epoch in 0..<epochCount {
                let weight = weights[epoch]
                guard weight != 0 else { continue }
                let residual = residuals[epoch]
                for index in 0..<length { vector[index] += weight * Double(residual[index]) }
            }
            var norm = 0.0
            for value in vector { norm += value * value }
            norm = norm.squareRoot()
            guard norm > 1e-12 else { break }
            for index in vector.indices { vector[index] /= norm }
            vectors.append(vector)
        }
        return vectors
    }

    /// The component of `epoch` that lies in the span of `basis` — that is, the
    /// part OBS removes. Returns zeros when the basis is empty, so the caller can
    /// add the result unconditionally.
    static func projection(of epoch: [Float], onto basis: [[Double]]) -> [Float] {
        var removed = [Double](repeating: 0, count: epoch.count)
        for vector in basis {
            guard vector.count == epoch.count else { continue }
            var coefficient = 0.0
            for index in epoch.indices { coefficient += Double(epoch[index]) * vector[index] }
            guard coefficient != 0 else { continue }
            for index in removed.indices { removed[index] += coefficient * vector[index] }
        }
        return removed.map { $0.isFinite ? Float($0) : 0 }
    }
}
