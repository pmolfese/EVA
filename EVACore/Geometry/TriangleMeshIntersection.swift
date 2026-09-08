//
//  TriangleMeshIntersection.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Triangle-triangle intersection and the self-intersection sweep the imported
//  BEM quality gates use (EVA_RESOLVE2.md R3.1). A shell that folds through
//  itself still solves and still produces a plausible-looking lead field, so this
//  has to be checked rather than assumed.
//
//  The pair test is the standard separating-axis argument for two triangles:
//  they are disjoint if some axis separates them, and for triangles the only
//  candidate axes are the two face normals and the nine edge-edge cross
//  products. Reference: Möller, T. (1997), "A fast triangle-triangle intersection
//  test", Journal of Graphics Tools 2(2) — the SAT formulation, re-implemented.
//

import Foundation
import simd

extension TriangleMesh {

    /// Triangle pairs that intersect, ignoring pairs that merely share a vertex
    /// or an edge (neighbours always "touch"). Stops after `limit` pairs — the
    /// caller wants to know *whether* the surface folds and see an example, not
    /// enumerate every fold.
    nonisolated func selfIntersectingTriangles(limit: Int = 8, cellsPerAxis: Int = 32) -> [(Int, Int)] {
        guard !triangles.isEmpty else { return [] }
        let (lo, hi) = boundingBox
        let extent = max((hi - lo).max(), 1e-9)
        let cellSize = extent / Double(cellsPerAxis)
        let origin = lo - SIMD3(repeating: cellSize)
        let n = cellsPerAxis + 2

        func cellIndex(_ p: SIMD3<Double>) -> SIMD3<Int> {
            let c = (p - origin) / cellSize
            return SIMD3(min(max(Int(c.x.rounded(.down)), 0), n - 1),
                         min(max(Int(c.y.rounded(.down)), 0), n - 1),
                         min(max(Int(c.z.rounded(.down)), 0), n - 1))
        }

        var buckets = [[Int32]](repeating: [], count: n * n * n)
        for (t, tri) in triangles.enumerated() {
            let a = vertices[Int(tri.x)], b = vertices[Int(tri.y)], c = vertices[Int(tri.z)]
            let tlo = cellIndex(pointwiseMin(a, pointwiseMin(b, c)))
            let thi = cellIndex(pointwiseMax(a, pointwiseMax(b, c)))
            for k in tlo.z...thi.z { for j in tlo.y...thi.y { for i in tlo.x...thi.x {
                buckets[i + n * (j + n * k)].append(Int32(t))
            } } }
        }

        var found: [(Int, Int)] = []
        var tested = Set<Int64>()
        for bucket in buckets where bucket.count > 1 {
            for x in 0..<(bucket.count - 1) {
                for y in (x + 1)..<bucket.count {
                    let a = Int(bucket[x]), b = Int(bucket[y])
                    let key = Int64(min(a, b)) << 32 | Int64(max(a, b))
                    if tested.contains(key) { continue }
                    tested.insert(key)
                    let ta = triangles[a], tb = triangles[b]
                    // Neighbours share vertices by construction; only non-adjacent
                    // triangles crossing each other is a fold.
                    let sa: Set<Int32> = [ta.x, ta.y, ta.z], sb: Set<Int32> = [tb.x, tb.y, tb.z]
                    if !sa.isDisjoint(with: sb) { continue }
                    if TriangleMesh.trianglesIntersect(
                        vertices[Int(ta.x)], vertices[Int(ta.y)], vertices[Int(ta.z)],
                        vertices[Int(tb.x)], vertices[Int(tb.y)], vertices[Int(tb.z)]
                    ) {
                        found.append((a, b))
                        if found.count >= limit { return found }
                    }
                }
            }
        }
        return found
    }

    /// True when the two closed triangles share at least one point.
    nonisolated static func trianglesIntersect(
        _ a0: SIMD3<Double>, _ a1: SIMD3<Double>, _ a2: SIMD3<Double>,
        _ b0: SIMD3<Double>, _ b1: SIMD3<Double>, _ b2: SIMD3<Double>
    ) -> Bool {
        let a = [a0, a1, a2], b = [b0, b1, b2]
        let na = simd_cross(a1 - a0, a2 - a0)
        let nb = simd_cross(b1 - b0, b2 - b0)

        var axes: [SIMD3<Double>] = [na, nb]
        for i in 0..<3 {
            let ea = a[(i + 1) % 3] - a[i]
            for j in 0..<3 {
                axes.append(simd_cross(ea, b[(j + 1) % 3] - b[j]))
            }
        }

        for axis in axes {
            let length = simd_length(axis)
            // Degenerate axis (parallel edges, or a sliver triangle): it separates
            // nothing, so it cannot prove disjointness.
            if length < 1e-14 { continue }
            let unit = axis / length
            var loA = Double.greatestFiniteMagnitude, hiA = -Double.greatestFiniteMagnitude
            var loB = Double.greatestFiniteMagnitude, hiB = -Double.greatestFiniteMagnitude
            for p in a { let d = simd_dot(p, unit); loA = min(loA, d); hiA = max(hiA, d) }
            for p in b { let d = simd_dot(p, unit); loB = min(loB, d); hiB = max(hiB, d) }
            // A shared boundary point is not a crossing; require real overlap.
            let tolerance = 1e-12
            if hiA < loB + tolerance || hiB < loA + tolerance { return false }
        }
        return true
    }
}

extension TriangleMesh {
    /// Where a mesh crosses an axis-aligned plane, as unordered line segments.
    ///
    /// Used to draw a head model as nested contours: the shells of a BEM are
    /// closed surfaces, and a slice through them is the outline you would see on
    /// an MRI. Segments are returned unordered because drawing them needs no
    /// ordering — stitching them into a polyline would be work for nothing.
    ///
    /// - Parameters:
    ///   - axis: 0 = x (sagittal), 1 = y (coronal), 2 = z (axial).
    ///   - offset: the plane's position along that axis, in the mesh's units.
    nonisolated func crossSection(axis: Int, offset: Double) -> [(SIMD3<Double>, SIMD3<Double>)] {
        precondition((0...2).contains(axis))
        var segments: [(SIMD3<Double>, SIMD3<Double>)] = []
        for triangle in triangles {
            let corners = [vertices[Int(triangle.x)], vertices[Int(triangle.y)], vertices[Int(triangle.z)]]
            let distances = corners.map { $0[axis] - offset }
            // A triangle crosses the plane when its corners are not all on one
            // side; the crossing is the segment between the two edge crossings.
            var crossings: [SIMD3<Double>] = []
            for i in 0..<3 {
                let j = (i + 1) % 3
                let (a, b) = (distances[i], distances[j])
                if a == 0 { crossings.append(corners[i]); continue }
                if (a < 0) != (b < 0) {
                    let t = a / (a - b)
                    crossings.append(corners[i] + (corners[j] - corners[i]) * t)
                }
            }
            if crossings.count >= 2 { segments.append((crossings[0], crossings[1])) }
        }
        return segments
    }
}
