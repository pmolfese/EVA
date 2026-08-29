//
//  BEMForwardModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Boundary Element Method (BEM) EEG forward model. A piecewise-homogeneous
//  volume conductor bounded by nested triangulated surfaces is solved with the
//  Geselowitz double-layer boundary integral equation, discretized by constant
//  (centroid-collocation) elements, with Van Oosterom & Strackee exact triangle
//  solid angles and Lynn–Timlake deflation of the rank-deficient system.
//
//  ## Why this exists, and its honest scope
//
//  The analytic `SphericalForwardModel` is exact for concentric spheres and is
//  the right tool for *comparing* inverse/spatial-filter methods. A BEM earns
//  its place on the **generation** side: meshing the same shells (or, later, a
//  realistic head surface) and solving numerically lets EVASimulate create data
//  under a forward operator that is *not* the analytic sphere, so a correction
//  built on the sphere can be tested against the mismatch a real head imposes.
//  This is exactly the "inverse crime" fix ROADMAP 6.5 / SI-4 call for.
//
//  ## Accuracy envelope
//
//  This is the plain (non-isolated) double-layer BEM, and it is validated to
//  converge to the analytic sphere for **both** single- and multi-compartment
//  geometry, at first order in mesh edge length. Measured max relative error at
//  the outer centroids vs. the analytic model (off-centre dipole), per shell
//  subdivision level (320 / 1280 / 5120 elements per shell):
//
//      homogeneous          2.5%  → 0.6%  → 0.15%
//      2-shell  1:2         2.9%  → 0.7%  → 0.17%
//      3-shell  1:40 skull  6.5%  → 2.9%  → 0.8%
//      3-shell  1:80 skull  11%   → 5.7%  → 1.65%
//
//  Accuracy at a fixed mesh degrades with skull contrast, which is the expected
//  behaviour of the plain formulation: the isolated-skull approach (IPA;
//  Hämäläinen & Sarvas 1989) buys the same accuracy at a coarser mesh for very
//  high contrast, and is a worthwhile *efficiency* follow-up (ROADMAP SI-4) —
//  but it is no longer a correctness prerequisite. The default subdivision (3)
//  gives ≈3% at a realistic 1:40 skull, and refining to 4 gives <1%.
//
//  The one caveat is cost: the system is dense (`elementCount²`), so a 3-shell
//  head is 960 unknowns at subdivision 2, 3840 at 3, 15360 at 4. Subdivision 3
//  is the practical default; 4 is a several-second solve.
//
//  References:
//    * Geselowitz, D. B. (1967). On bioelectric potentials in an inhomogeneous
//      volume conductor. Biophysical Journal, 7(1), 1–11.
//    * Van Oosterom, A., & Strackee, J. (1983). The solid angle of a plane
//      triangle. IEEE Trans. Biomed. Eng., BME-30(2), 125–126.
//    * Barnard, A. C. L., Duck, I. M., & Lynn, M. S. (1967). The application of
//      electromagnetic theory to electrocardiology. Biophysical Journal, 7(5),
//      443–462. (Lynn–Timlake deflation of the singular double-layer system.)
//

import Foundation

nonisolated enum BEMForwardModel {
    /// Icosahedron subdivision count for the shell meshes. Each subdivision
    /// quadruples the triangle count (20·4ⁿ per shell), so 3 → 1280/shell.
    static let defaultSubdivisions = 3

    enum BEMForwardError: LocalizedError, Sendable, Equatable {
        case invalidSubdivisions(Int)
        case tooFewShells(Int)
        case dipoleOutsideBrain(id: String)
        case singularSystem
        case nonFiniteOutput

        var errorDescription: String? {
            switch self {
            case .invalidSubdivisions(let n):
                return "Invalid BEM forward model: subdivisions must be between 0 and 5 (received \(n))"
            case .tooFewShells(let n):
                return "Invalid BEM forward model: at least one conductive shell is required (received \(n))"
            case .dipoleOutsideBrain(let id):
                return "Invalid BEM forward model: dipole \(id) is not inside the innermost shell"
            case .singularSystem:
                return "Invalid BEM forward model: the deflated boundary system could not be factored"
            case .nonFiniteOutput:
                return "Invalid BEM forward model: the solved potentials contain a non-finite value"
            }
        }
    }

    // MARK: - Public API

    /// Lead field for a piecewise-homogeneous head, solved by BEM over meshed
    /// shells. Electrode potentials are interpolated from the nearest outer-shell
    /// element centroid (a first-order interpolation, documented).
    static func leadField(
        head: ForwardHeadModel,
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference,
        subdivisions: Int = defaultSubdivisions
    ) throws -> ForwardLeadField {
        guard subdivisions >= 0, subdivisions <= 5 else {
            throw BEMForwardError.invalidSubdivisions(subdivisions)
        }
        guard head.shells.count >= 1 else {
            throw BEMForwardError.tooFewShells(head.shells.count)
        }

        let solution = try solveSurfacePotentials(
            head: head, dipoles: dipoles, subdivisions: subdivisions
        )

        // Interpolate each electrode from the nearest outer-shell centroid by
        // angular distance (direction from the head centre).
        let outer = solution.outerCentroids
        var freeMatrix = [[Double]](
            repeating: [Double](repeating: 0, count: 3 * dipoles.count),
            count: electrodes.positionsMeters.count
        )
        for (electrodeIndex, position) in electrodes.positionsMeters.enumerated() {
            let direction = normalized(subtract(position, head.centerMeters))
            var bestIndex = 0
            var bestDot = -Double.greatestFiniteMagnitude
            for (centroidIndex, centroidDirection) in outer.directions.enumerated() {
                let d = dot(direction, centroidDirection)
                if d > bestDot { bestDot = d; bestIndex = centroidIndex }
            }
            let row = outer.rows[bestIndex]
            for column in 0..<(3 * dipoles.count) {
                freeMatrix[electrodeIndex][column] = solution.freePotentials[row][column]
            }
        }

        if reference == .average {
            for column in 0..<(3 * dipoles.count) {
                let mean = freeMatrix.reduce(0.0) { $0 + $1[column] } / Double(freeMatrix.count)
                for electrodeIndex in freeMatrix.indices { freeMatrix[electrodeIndex][column] -= mean }
            }
        }

        var orientedMatrix = [[Double]](
            repeating: [Double](repeating: 0, count: dipoles.count),
            count: electrodes.positionsMeters.count
        )
        for electrodeIndex in orientedMatrix.indices {
            for (dipoleIndex, dipole) in dipoles.enumerated() {
                orientedMatrix[electrodeIndex][dipoleIndex] =
                    freeMatrix[electrodeIndex][3 * dipoleIndex] * dipole.orientationUnit.x
                    + freeMatrix[electrodeIndex][3 * dipoleIndex + 1] * dipole.orientationUnit.y
                    + freeMatrix[electrodeIndex][3 * dipoleIndex + 2] * dipole.orientationUnit.z
            }
        }

        guard freeMatrix.allSatisfy({ $0.allSatisfy(\.isFinite) }),
              orientedMatrix.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw BEMForwardError.nonFiniteOutput
        }

        return ForwardLeadField(
            electrodeNames: electrodes.names,
            dipoleIDs: dipoles.map(\.id),
            reference: reference,
            freeMicrovoltsPerNanoampereMeter: freeMatrix,
            orientedMicrovoltsPerNanoampereMeter: orientedMatrix
        )
    }

    // MARK: - Core solve (exposed for validation against the analytic sphere)

    struct OuterSurface {
        /// Row index in `freePotentials` for each outer-shell element.
        var rows: [Int]
        /// Unit direction of each outer element centroid from the head centre.
        var directions: [SIMD3<Double>]
        /// Physical centroid positions of the outer elements.
        var positions: [SIMD3<Double>]
    }

    struct Solution {
        /// Surface potential at every element centroid (all shells), one column
        /// per free source orientation (3 × dipoles), in µV/(nA·m).
        var freePotentials: [[Double]]
        var outerCentroids: OuterSurface
    }

    /// Assembles and solves the deflated BEM system, returning the surface
    /// potential at every element centroid. Separated from electrode
    /// interpolation so a test can score the solver at the outer centroids
    /// directly, without interpolation error.
    static func solveSurfacePotentials(
        head: ForwardHeadModel,
        dipoles: [ForwardDipole],
        subdivisions: Int
    ) throws -> Solution {
        let unit = icosphere(subdivisions: subdivisions)
        let shellCount = head.shells.count

        // Build the global element list across all shells.
        var centroids: [SIMD3<Double>] = []
        var vertsA: [SIMD3<Double>] = []
        var vertsB: [SIMD3<Double>] = []
        var vertsC: [SIMD3<Double>] = []
        var conductivityJump: [Double] = []      // σ_in − σ_out for the element's surface
        var conductivityMean: [Double] = []       // (σ_in + σ_out) / 2
        var isOuter: [Bool] = []
        centroids.reserveCapacity(shellCount * unit.faces.count)

        for shell in 0..<shellCount {
            let radius = head.shells[shell].radiusMeters
            let sigmaIn = head.shells[shell].conductivitySiemensPerMeter
            let sigmaOut = shell < shellCount - 1
                ? head.shells[shell + 1].conductivitySiemensPerMeter
                : 0.0
            let outer = shell == shellCount - 1
            for face in unit.faces {
                let a = add(scale(unit.vertices[face.0], radius), head.centerMeters)
                let b = add(scale(unit.vertices[face.1], radius), head.centerMeters)
                let c = add(scale(unit.vertices[face.2], radius), head.centerMeters)
                vertsA.append(a); vertsB.append(b); vertsC.append(c)
                centroids.append(scale(add(add(a, b), c), 1.0 / 3.0))
                conductivityJump.append(sigmaIn - sigmaOut)
                conductivityMean.append((sigmaIn + sigmaOut) / 2)
                isOuter.append(outer)
            }
        }
        let elementCount = centroids.count
        let facesPerShell = unit.faces.count

        // Validate dipoles inside the innermost shell.
        let sigma0 = head.shells[0].conductivitySiemensPerMeter
        let brainRadius = head.shells[0].radiusMeters
        for dipole in dipoles {
            let r = norm(subtract(dipole.positionMeters, head.centerMeters))
            guard r < brainRadius else { throw BEMForwardError.dipoleOutsideBrain(id: dipole.id) }
        }

        // System matrix A (row-major, elementCount²), from the Geselowitz BIE
        //   σ̄_i V_i − (1/4π) Σ_j (σ_in−σ_out)_j Ω_ij V_j = σ0 V∞(r_i)
        //   A_ij = σ̄_i · δ_ij − (1/4π) · (σ_in−σ_out)_j · Ω_ij
        // where Ω_ij is the Van Oosterom–Strackee *signed* solid angle of element
        // j at centroid i. With outward-oriented vertices this Ω is +4π for a
        // point enclosed by a closed surface (verified numerically), so it equals
        // +∫dΩ and the double-layer term carries a minus sign.
        //
        // Auto-solid-angle diagonal: the collocation centroids sit just *inside*
        // their own surface (a triangle centroid is at radius < the vertex
        // radius), where the geometric self-surface sum is +4π — but the BIE's
        // on-surface principal value is +2π. Setting Ω_ii = 2π − Σ_{j≠i on S(i)}
        // forces the self-surface total to +2π, which is exactly the condition
        // that makes A·1 = 0 hold with conductivity contrast (constant potential,
        // no source ⇒ equilibrium). Getting this sign wrong is invisible on a
        // single-compartment head — where the diagonal absorbs it — and only
        // shows up once cross-surface coupling exists.
        let fourPiInverse = 1.0 / (4.0 * Double.pi)
        var a = [Double](repeating: 0, count: elementCount * elementCount)

        for i in 0..<elementCount {
            let p = centroids[i]
            let shellOfI = i / facesPerShell
            var selfSurfaceSolidAngle = 0.0     // Σ_{j on S(i), j≠i} Ω_ij
            for j in 0..<elementCount where j != i {
                let omega = solidAngle(at: p, a: vertsA[j], b: vertsB[j], c: vertsC[j])
                if j / facesPerShell == shellOfI { selfSurfaceSolidAngle += omega }
                a[i * elementCount + j] = -fourPiInverse * conductivityJump[j] * omega
            }
            let omegaSelf = 2.0 * Double.pi - selfSurfaceSolidAngle
            a[i * elementCount + i] =
                conductivityMean[i] - fourPiInverse * conductivityJump[i] * omegaSelf
        }

        // Lynn–Timlake deflation: the double-layer system is rank-deficient
        // (potential defined up to a constant). Adding a rank-1 term shifts the
        // zero eigenvalue to a nonzero value and fixes the solution's mean,
        // leaving every other mode untouched.
        var diagonalMagnitude = 0.0
        for i in 0..<elementCount { diagonalMagnitude += abs(a[i * elementCount + i]) }
        let deflation = (diagonalMagnitude / Double(elementCount)) / Double(elementCount)
        for index in 0..<(elementCount * elementCount) { a[index] += deflation }

        // Right-hand side: b_i(column) = σ0 · φ∞ for each free source orientation.
        // σ0·φ∞ = (1/4π) · p·(r−r0)/|r−r0|³ is independent of σ0.
        // Column-major RHS (elementCount rows × columnCount columns), as
        // `LUFactorization.solve(_:rightHandSideCount:)` / LAPACK dgetrs_ expect.
        let columnCount = 3 * dipoles.count
        var rhs = [Double](repeating: 0, count: elementCount * columnCount)
        let bases = [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1)]
        for (dipoleIndex, dipole) in dipoles.enumerated() {
            for (axis, moment) in bases.enumerated() {
                let column = 3 * dipoleIndex + axis
                for i in 0..<elementCount {
                    let d = subtract(centroids[i], dipole.positionMeters)
                    let r = norm(d)
                    // b_i = σ0 φ∞ = (1/4π) p·(r−r0)/|r−r0|³. Positive sign matches
                    // EVA's analytic SphericalForwardModel dipole convention
                    // (a +z moment reads positive over the +z pole).
                    let value = r > 1e-12 ? fourPiInverse * dot(moment, d) / (r * r * r) : 0
                    rhs[column * elementCount + i] = value
                }
            }
        }

        // Factor once, solve for every source column. LUFactorization expects a
        // row-major matrix and a row-major RHS of `rightHandSideCount` columns.
        guard let factor = LinearAlgebra.factorLinearSystem(a: a, size: elementCount) else {
            throw BEMForwardError.singularSystem
        }
        guard let solved = factor.solve(rhs, rightHandSideCount: columnCount) else {
            throw BEMForwardError.singularSystem
        }

        // Scale V/(A·m) → µV/(nA·m) and unpack into [element][column].
        let unitScale = 1e-3
        var potentials = [[Double]](
            repeating: [Double](repeating: 0, count: columnCount), count: elementCount
        )
        for i in 0..<elementCount {
            for column in 0..<columnCount {
                potentials[i][column] = solved[column * elementCount + i] * unitScale
            }
        }

        // Describe the outer shell for electrode interpolation.
        var rows: [Int] = []
        var directions: [SIMD3<Double>] = []
        var positions: [SIMD3<Double>] = []
        for i in 0..<elementCount where isOuter[i] {
            rows.append(i)
            directions.append(normalized(subtract(centroids[i], head.centerMeters)))
            positions.append(centroids[i])
        }

        return Solution(
            freePotentials: potentials,
            outerCentroids: OuterSurface(rows: rows, directions: directions, positions: positions)
        )
    }

    // MARK: - Geometry: icosphere mesh

    struct UnitMesh {
        var vertices: [SIMD3<Double>]         // on the unit sphere
        var faces: [(Int, Int, Int)]          // outward-oriented (CCW seen from outside)
    }

    /// A unit-sphere icosphere: an icosahedron subdivided `subdivisions` times,
    /// every vertex re-projected to the unit sphere. Deterministic, so a mesh is
    /// reproducible across runs and machines.
    static func icosphere(subdivisions: Int) -> UnitMesh {
        let t = (1.0 + 5.0.squareRoot()) / 2.0
        var vertices: [SIMD3<Double>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1)
        ].map { normalized($0) }
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)
        ]

        var midpointCache: [Int64: Int] = [:]
        func midpoint(_ i: Int, _ j: Int) -> Int {
            let key = i < j ? Int64(i) << 32 | Int64(j) : Int64(j) << 32 | Int64(i)
            if let cached = midpointCache[key] { return cached }
            let mid = normalized(scale(add(vertices[i], vertices[j]), 0.5))
            vertices.append(mid)
            let index = vertices.count - 1
            midpointCache[key] = index
            return index
        }

        for _ in 0..<max(subdivisions, 0) {
            var next: [(Int, Int, Int)] = []
            next.reserveCapacity(faces.count * 4)
            for face in faces {
                let ab = midpoint(face.0, face.1)
                let bc = midpoint(face.1, face.2)
                let ca = midpoint(face.2, face.0)
                next.append((face.0, ab, ca))
                next.append((face.1, bc, ab))
                next.append((face.2, ca, bc))
                next.append((ab, bc, ca))
            }
            faces = next
        }

        // Enforce outward orientation (CCW seen from outside) regardless of the
        // seed winding: the solid-angle sign convention the solver depends on
        // requires each face normal (b−a)×(c−a) to point away from the centre.
        faces = faces.map { face in
            let a = vertices[face.0], b = vertices[face.1], c = vertices[face.2]
            let normal = cross(subtract(b, a), subtract(c, a))
            let outward = add(add(a, b), c)   // centroid direction from origin
            return dot(normal, outward) >= 0 ? face : (face.0, face.2, face.1)
        }
        return UnitMesh(vertices: vertices, faces: faces)
    }

    // MARK: - Van Oosterom & Strackee signed solid angle

    /// Signed solid angle subtended by triangle (A,B,C) at point `p`. With
    /// outward-oriented (CCW-from-outside) vertices, a point enclosed by the
    /// closed surface sees a total of −4π summed over its triangles, which is
    /// the sign convention the assembly above relies on.
    static func solidAngle(
        at p: SIMD3<Double>, a A: SIMD3<Double>, b B: SIMD3<Double>, c C: SIMD3<Double>
    ) -> Double {
        let a = subtract(A, p), b = subtract(B, p), c = subtract(C, p)
        let na = norm(a), nb = norm(b), nc = norm(c)
        let numerator = dot(a, cross(b, c))
        let denominator = na * nb * nc
            + dot(a, b) * nc + dot(b, c) * na + dot(c, a) * nb
        return 2.0 * atan2(numerator, denominator)
    }

    // MARK: - SIMD helpers

    private static func dot(_ l: SIMD3<Double>, _ r: SIMD3<Double>) -> Double {
        l.x * r.x + l.y * r.y + l.z * r.z
    }
    private static func cross(_ l: SIMD3<Double>, _ r: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(l.y * r.z - l.z * r.y, l.z * r.x - l.x * r.z, l.x * r.y - l.y * r.x)
    }
    private static func norm(_ v: SIMD3<Double>) -> Double { dot(v, v).squareRoot() }
    private static func normalized(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let n = norm(v); return n > 1e-15 ? scale(v, 1 / n) : SIMD3<Double>(repeating: 0)
    }
    private static func add(_ l: SIMD3<Double>, _ r: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(l.x + r.x, l.y + r.y, l.z + r.z)
    }
    private static func subtract(_ l: SIMD3<Double>, _ r: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(l.x - r.x, l.y - r.y, l.z - r.z)
    }
    private static func scale(_ v: SIMD3<Double>, _ s: Double) -> SIMD3<Double> {
        SIMD3<Double>(v.x * s, v.y * s, v.z * s)
    }
}
