//
//  BEMSolution.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  An imported BEM *solution* (EVA_RESOLVE2.md R3.2): the geometry plus the dense
//  potential-solution matrix MNE computes with `make_bem_solution`. This is what
//  makes importing worth doing — with the solution in hand EVA can evaluate a
//  forward field for *any* dipole, not just the source space someone else chose
//  at export time.
//
//  ## What this can and cannot read
//
//  MNE writes both of its solvers into the same `-bem-sol.fif`, but they hold
//  different objects:
//
//  * `solver='mne'` — a dense (Σ vertices)² matrix of vertex potentials, linear
//    collocation, isolated-skull approach already applied. Self-sufficient: the
//    field for a dipole is arithmetic on these numbers, which is what
//    `BEMSolutionForwardModel` (R3.3) does.
//  * `solver='openmeeg'` — the symmetric-BEM head-matrix inverse. Its unknowns
//    are vertex potentials *and* normal currents on the inner interfaces (486 →
//    1126 for a 162-vertex-per-shell head), stored packed as the n(n+1)/2 upper
//    triangle, and MNE evaluates it only by calling back into libOpenMEEG to
//    re-assemble the source and sensor matrices. EVA cannot evaluate it without
//    reimplementing OpenMEEG's symmetric BEM, which is the work importing exists
//    to avoid, so this reader declines it by name and points at the three routes
//    that do work (see `BEMImportError.unsupportedSolver`).
//
//  The *geometry* is solver-independent and always readable — see `BEMGeometry`.
//
//  Ported from MNE-Python (BSD-3): the solution layout, the approximation
//  constants and `_add_gamma_multipliers`.
//

import Foundation
import simd

nonisolated struct BEMSolution: Sendable {

    var geometry: BEMGeometry

    /// FIFF_BEM_APPROX: 2 = linear collocation, which is what MNE writes and the
    /// only method it (or this) evaluates.
    var approximation: Int

    /// The dense potential solution, `size × size` row-major, single precision.
    /// Kept as `Float` because that is how it is stored on disk and a realistic
    /// head model is hundreds of megabytes — doubling it buys no accuracy the
    /// BEM discretization can support.
    var solution: [Float]

    /// Number of rows/columns; also Σ vertices over the shells.
    var size: Int

    /// Per-shell multipliers derived from the conductivities, in the same
    /// **outer → inner** order MNE derives them, since the solution matrix is
    /// blocked in the file's surface order. Ported from `_add_gamma_multipliers`.
    var sourceMultipliers: [Double]
    var fieldMultipliers: [Double]

    /// Vertex range each shell occupies in the solution matrix, outer first —
    /// the order the surfaces appear in the file, which is the order the matrix
    /// is blocked in. `geometry.shells` is the reverse (inner first).
    var blocks: [Range<Int>]

    /// Refuse rather than thrash: a 3 × 5120-vertex head is a 15360² float32
    /// matrix, ~940 MB. Raise deliberately if the machine can take it.
    static let defaultSizeLimitBytes = 2_000_000_000

    // MARK: - Import

    static func readFIF(from url: URL, subject: String? = nil,
                        sizeLimitBytes: Int = defaultSizeLimitBytes) throws -> BEMSolution {
        let geometry = try BEMGeometry.readFIF(from: url, subject: subject)
        let reader = try FIFReader(url: url)
        let bemTags = reader.blocks(kind: FIF.blockBEM).first ?? reader.tags

        guard let solutionTag = bemTags.first(where: { $0.kind == FIF.bemPotSolution }) else {
            throw BEMImportError.malformed("no BEM solution in \(url.lastPathComponent) — this is a geometry-only file")
        }
        let approximation = bemTags.first(where: { $0.kind == FIF.bemApprox }).map { Int($0.int32()) } ?? Int(FIF.approxLinear)
        guard approximation == Int(FIF.approxLinear) else {
            throw BEMImportError.unsupportedApproximation(approximation)
        }

        let dims = try solutionTag.matrixDimensions()
        let vertices = geometry.vertexCount

        // OpenMEEG: packed 1-D, and larger than the vertex count because it also
        // carries normal currents on the inner interfaces.
        if geometry.provenance.solver == .openmeeg || dims.count == 1 {
            throw BEMImportError.unsupportedSolver(
                geometry.provenance.solver == .openmeeg ? "OpenMEEG" : "an unrecognized solver",
                vertices: vertices, solutionEntries: dims.reduce(1, *))
        }
        guard dims.count == 2, dims[0] == vertices, dims[1] == vertices else {
            throw BEMImportError.solutionShapeMismatch(expected: vertices, found: dims)
        }
        let bytes = vertices * vertices * MemoryLayout<Float>.size
        guard bytes <= sizeLimitBytes else {
            throw BEMImportError.solutionTooLarge(bytes: bytes, limit: sizeLimitBytes)
        }

        // The matrix is blocked in the file's surface order (outer first), which
        // is the reverse of how `BEMGeometry` stores the shells.
        let outerFirst = geometry.shells.reversed()
        var blocks: [Range<Int>] = []
        var start = 0
        for shell in outerFirst {
            blocks.append(start..<(start + shell.mesh.vertices.count))
            start += shell.mesh.vertices.count
        }
        let (source, field) = Self.multipliers(sigmasOuterFirst: outerFirst.map(\.sigma))

        return BEMSolution(geometry: geometry, approximation: approximation,
                           solution: try solutionTag.floatValues(), size: vertices,
                           sourceMultipliers: source, fieldMultipliers: field, blocks: blocks)
    }

    /// `_add_gamma_multipliers` from MNE (BSD-3), with the zero conductivity
    /// outside the head as the leading element: `source = 2 / (σᵢ + σᵢ₋₁)`,
    /// `field = σᵢ − σᵢ₋₁`, over the surfaces in file order (outer first, so the
    /// "previous" compartment of the scalp is the air).
    static func multipliers(sigmasOuterFirst: [Double]) -> (source: [Double], field: [Double]) {
        let sigma = [0.0] + sigmasOuterFirst
        var source: [Double] = [], field: [Double] = []
        for i in 1..<sigma.count {
            source.append(2.0 / (sigma[i] + sigma[i - 1]))
            field.append(sigma[i] - sigma[i - 1])
        }
        return (source, field)
    }

    /// Row `i` of the solution matrix.
    func row(_ i: Int) -> ArraySlice<Float> {
        precondition(i >= 0 && i < size)
        return solution[(i * size)..<((i + 1) * size)]
    }

    /// Which shell a solution row belongs to (index into `blocks`, outer first).
    func blockIndex(ofRow row: Int) -> Int {
        blocks.firstIndex { $0.contains(row) } ?? 0
    }
}
