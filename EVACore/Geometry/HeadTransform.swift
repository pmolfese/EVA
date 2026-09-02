//
//  HeadTransform.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Coordinate frames and the rigid/similarity transforms between them, in
//  **metres**, matching EVA's forward models and MNE-Python's `Transform`.
//
//  Frames follow the FIFF numbering so a transform can be written to / read from
//  an MNE `-trans.fif` without translation:
//    head  — the electrode/digitizer frame: origin between LPA and RPA, +x toward
//            RPA, +y toward nasion, +z up (MNE's "head", FIFFV_COORD_HEAD = 4).
//    mri   — the subject MRI surface RAS frame (FreeSurfer "surface RAS"; MNE's
//            "mri", FIFFV_COORD_MRI = 5).
//    mriVoxel, mniTal, ras — the other frames MNE names; kept for interop.
//
//  `fit(source:target:)` is Umeyama's closed-form least-squares alignment of
//  matched point sets (Kabsch when scaling is off). Three fiducials are enough:
//  the cross-covariance is rank-2 there, which the SVD handles by completing
//  the rotation with the cross product of the two resolved singular vectors.
//

import Foundation
import simd

nonisolated enum CoordinateFrame: Int, Codable, Sendable, CaseIterable {
    case unknown = 0
    case device = 1
    case head = 4
    case mri = 5
    case mriSlice = 6
    case mriDisplay = 7
    case mriVoxel = 2001
    case ras = 2003
    case mniTal = 2004

    var displayName: String {
        switch self {
        case .unknown: return "unknown"
        case .device: return "device"
        case .head: return "head"
        case .mri: return "MRI (surface RAS)"
        case .mriSlice: return "MRI slice"
        case .mriDisplay: return "MRI display"
        case .mriVoxel: return "MRI voxel"
        case .ras: return "scanner RAS"
        case .mniTal: return "MNI Talairach"
        }
    }
}

/// A 4×4 homogeneous transform between two frames, metres.
nonisolated struct HeadTransform: Sendable, Equatable {
    var from: CoordinateFrame
    var to: CoordinateFrame
    var matrix: simd_double4x4

    init(from: CoordinateFrame, to: CoordinateFrame, matrix: simd_double4x4 = matrix_identity_double4x4) {
        self.from = from
        self.to = to
        self.matrix = matrix
    }

    static func identity(from: CoordinateFrame, to: CoordinateFrame) -> HeadTransform {
        HeadTransform(from: from, to: to)
    }

    var rotation: simd_double3x3 {
        simd_double3x3(
            SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
    }

    var translation: SIMD3<Double> {
        SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    /// Uniform scale carried by the rotation block (1 for rigid transforms).
    var scale: Double {
        simd_length(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z))
    }

    func apply(_ point: SIMD3<Double>) -> SIMD3<Double> {
        let p = matrix * SIMD4(point.x, point.y, point.z, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    func apply(_ points: [SIMD3<Double>]) -> [SIMD3<Double>] {
        points.map(apply)
    }

    /// Rotates a direction (no translation, scale removed).
    func applyToDirection(_ v: SIMD3<Double>) -> SIMD3<Double> {
        simd_normalize(rotation * v)
    }

    func inverted() -> HeadTransform {
        HeadTransform(from: to, to: from, matrix: matrix.inverse)
    }

    /// `self` then `next`: maps `from` → `next.to`. Frames must chain.
    func then(_ next: HeadTransform) -> HeadTransform {
        precondition(next.from == to, "frame mismatch: \(to) → \(next.from)")
        return HeadTransform(from: from, to: next.to, matrix: next.matrix * matrix)
    }

    static func rotation(_ r: simd_double3x3, translation t: SIMD3<Double>, from: CoordinateFrame, to: CoordinateFrame) -> HeadTransform {
        var m = matrix_identity_double4x4
        m.columns.0 = SIMD4(r.columns.0, 0)
        m.columns.1 = SIMD4(r.columns.1, 0)
        m.columns.2 = SIMD4(r.columns.2, 0)
        m.columns.3 = SIMD4(t, 1)
        return HeadTransform(from: from, to: to, matrix: m)
    }

    // MARK: Point-set alignment

    struct Fit: Sendable {
        var transform: HeadTransform
        var scale: Double
        /// RMS distance between transformed source and target points, metres.
        var rmsError: Double
        var perPointError: [Double]
    }

    enum FitError: LocalizedError, Equatable {
        case tooFewPoints(Int)
        case countMismatch(source: Int, target: Int)
        case degenerate

        var errorDescription: String? {
            switch self {
            case .tooFewPoints(let n): return "At least 3 matched points are needed to fit a transform (got \(n))."
            case .countMismatch(let s, let t): return "Point counts differ (\(s) source, \(t) target)."
            case .degenerate: return "The points are collinear or coincident; no unique transform."
            }
        }
    }

    /// Least-squares similarity (or rigid) transform mapping `source` onto
    /// `target` (Umeyama 1991). Frames are recorded on the result.
    static func fit(
        source: [SIMD3<Double>], target: [SIMD3<Double>],
        allowScale: Bool = false,
        from: CoordinateFrame = .head, to: CoordinateFrame = .mri
    ) throws -> Fit {
        guard source.count == target.count else { throw FitError.countMismatch(source: source.count, target: target.count) }
        guard source.count >= 3 else { throw FitError.tooFewPoints(source.count) }
        let n = Double(source.count)
        let meanS = source.reduce(.zero, +) / n
        let meanT = target.reduce(.zero, +) / n
        var h = simd_double3x3(0)
        var varianceS = 0.0
        for (s, t) in zip(source, target) {
            let ds = s - meanS, dt = t - meanT
            // outer product dt * dsᵀ, accumulated column-wise
            h.columns.0 += dt * ds.x
            h.columns.1 += dt * ds.y
            h.columns.2 += dt * ds.z
            varianceS += simd_length_squared(ds)
        }
        h = h * (1 / n)
        varianceS /= n
        guard varianceS > 1e-18 else { throw FitError.degenerate }

        let svd = SVD3.decompose(h)
        guard svd.singularValues[1] > 1e-12 * max(svd.singularValues[0], 1e-300) else { throw FitError.degenerate }
        var d = matrix_identity_double3x3
        if (svd.u * svd.v.transpose).determinant < 0 { d.columns.2.z = -1 }
        let r = svd.u * d * svd.v.transpose
        let traceSD = svd.singularValues[0] * d.columns.0.x + svd.singularValues[1] * d.columns.1.y + svd.singularValues[2] * d.columns.2.z
        let c = allowScale ? traceSD / varianceS : 1.0
        let t = meanT - c * (r * meanS)
        let transform = rotation(r * c, translation: t, from: from, to: to)
        let errors = zip(source, target).map { simd_length(transform.apply($0) - $1) }
        let rms = (errors.reduce(0) { $0 + $1 * $1 } / n).squareRoot()
        return Fit(transform: transform, scale: c, rmsError: rms, perPointError: errors)
    }
}

/// 3×3 singular value decomposition via the eigen-decomposition of AᵀA, with the
/// left vectors completed by cross products when the matrix is rank-deficient.
nonisolated enum SVD3 {
    struct Result: Sendable {
        var u: simd_double3x3
        var singularValues: SIMD3<Double>   // descending
        var v: simd_double3x3
    }

    static func decompose(_ a: simd_double3x3) -> Result {
        let ata = a.transpose * a
        let m = [
            [ata.columns.0.x, ata.columns.1.x, ata.columns.2.x],
            [ata.columns.0.y, ata.columns.1.y, ata.columns.2.y],
            [ata.columns.0.z, ata.columns.1.z, ata.columns.2.z]
        ]
        let eigen = LinearAlgebra.symmetricEigenDecomposition(m)
        let order = (0..<3).sorted { eigen.values[$0] > eigen.values[$1] }
        var v = simd_double3x3(0)
        var sigma = SIMD3<Double>(0, 0, 0)
        for (slot, idx) in order.enumerated() {
            let col = SIMD3(eigen.vectors[0][idx], eigen.vectors[1][idx], eigen.vectors[2][idx])
            let normalized = simd_normalize(col)
            switch slot {
            case 0: v.columns.0 = normalized
            case 1: v.columns.1 = normalized
            default: v.columns.2 = normalized
            }
            sigma[slot] = max(0, eigen.values[idx]).squareRoot()
        }
        if v.determinant < 0 { v.columns.2 = -v.columns.2 }
        // Left vectors: u_i = A v_i / σ_i for the well-determined directions,
        // Gram–Schmidt re-orthogonalized; a vanishing σ (rank-2 input such as
        // three fiducials) gets u_2 = u_0 × u_1 instead of noise.
        let vcols = [v.columns.0, v.columns.1, v.columns.2]
        let tolerance = 1e-7 * max(sigma[0], 1e-300)
        var cols: [SIMD3<Double>] = []
        for i in 0..<3 {
            var candidate = a * vcols[i]
            for existing in cols { candidate -= simd_dot(candidate, existing) * existing }
            let length = simd_length(candidate)
            if sigma[i] > tolerance, length > 1e-300 {
                cols.append(candidate / length)
            } else if cols.count == 2 {
                cols.append(simd_normalize(simd_cross(cols[0], cols[1])))
            } else if cols.count == 1 {
                let o = cols[0]
                let helper = abs(o.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
                cols.append(simd_normalize(simd_cross(o, helper)))
            } else {
                cols.append([SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1)][i])
            }
        }
        let u = simd_double3x3(cols[0], cols[1], cols[2])
        return Result(u: u, singularValues: sigma, v: v)
    }
}
