//
//  TriangleMesh.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A closed triangulated surface in metres: scalp / skull / brain boundaries from
//  MNE BEM files, GIFTI surfaces, the BEM icosphere, or (R3) marching cubes.
//  Provides normals, a uniform-grid accelerator, and exact closest-point queries
//  (Ericson, *Real-Time Collision Detection* §5.1.5) for coregistration.
//

import Foundation
import simd

nonisolated struct TriangleMesh: Sendable {
    var vertices: [SIMD3<Double>]
    var triangles: [SIMD3<Int32>]
    /// Optional, per vertex, unit length; computed on demand when nil.
    var vertexNormals: [SIMD3<Double>]?

    init(vertices: [SIMD3<Double>], triangles: [SIMD3<Int32>], vertexNormals: [SIMD3<Double>]? = nil) {
        self.vertices = vertices
        self.triangles = triangles
        self.vertexNormals = vertexNormals
    }

    /// A sphere of the given radius from the BEM icosphere (subdivision 3 → 1280
    /// triangles, 4 → 5120), centred on `centre`.
    static func icosphere(subdivisions: Int, radius: Double, centre: SIMD3<Double> = .zero) -> TriangleMesh {
        let unit = BEMForwardModel.icosphere(subdivisions: subdivisions)
        return TriangleMesh(
            vertices: unit.vertices.map { centre + $0 * radius },
            triangles: unit.faces.map { SIMD3(Int32($0.0), Int32($0.1), Int32($0.2)) })
    }

    var centroid: SIMD3<Double> {
        vertices.isEmpty ? .zero : vertices.reduce(.zero, +) / Double(vertices.count)
    }

    var boundingBox: (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for v in vertices { lo = pointwiseMin(lo, v); hi = pointwiseMax(hi, v) }
        return (lo, hi)
    }

    func faceNormal(_ t: Int) -> SIMD3<Double> {
        let tri = triangles[t]
        let a = vertices[Int(tri.x)], b = vertices[Int(tri.y)], c = vertices[Int(tri.z)]
        let n = simd_cross(b - a, c - a)
        let l = simd_length(n)
        return l > 0 ? n / l : .zero
    }

    /// Area-weighted vertex normals (outward when triangles wind counter-clockwise
    /// seen from outside, the MNE/FreeSurfer convention).
    func computedVertexNormals() -> [SIMD3<Double>] {
        var normals = [SIMD3<Double>](repeating: .zero, count: vertices.count)
        for tri in triangles {
            let a = vertices[Int(tri.x)], b = vertices[Int(tri.y)], c = vertices[Int(tri.z)]
            let n = simd_cross(b - a, c - a)  // twice the area, along the normal
            normals[Int(tri.x)] += n; normals[Int(tri.y)] += n; normals[Int(tri.z)] += n
        }
        return normals.map { let l = simd_length($0); return l > 0 ? $0 / l : SIMD3(0, 0, 1) }
    }

    var normals: [SIMD3<Double>] { vertexNormals ?? computedVertexNormals() }

    /// Total surface area and enclosed volume (divergence theorem; positive for
    /// outward winding).
    var areaAndVolume: (area: Double, volume: Double) {
        var area = 0.0, volume = 0.0
        for tri in triangles {
            let a = vertices[Int(tri.x)], b = vertices[Int(tri.y)], c = vertices[Int(tri.z)]
            area += simd_length(simd_cross(b - a, c - a)) / 2
            volume += simd_dot(a, simd_cross(b, c)) / 6
        }
        return (area, volume)
    }

    func transformed(by t: HeadTransform) -> TriangleMesh {
        TriangleMesh(vertices: vertices.map(t.apply), triangles: triangles,
                     vertexNormals: vertexNormals?.map(t.applyToDirection))
    }

    func scaled(_ s: Double, about c: SIMD3<Double>? = nil) -> TriangleMesh {
        let centre = c ?? centroid
        return TriangleMesh(vertices: vertices.map { centre + ($0 - centre) * s }, triangles: triangles, vertexNormals: vertexNormals)
    }

    // MARK: Closest point

    struct ClosestPoint: Sendable {
        var point: SIMD3<Double>
        var distance: Double
        var triangle: Int
        /// Outward face normal at the hit triangle.
        var normal: SIMD3<Double>
        /// Positive outside the surface, negative inside (by face normal).
        var signedDistance: Double
    }

    /// Closest point on triangle (a, b, c) to p.
    static func closestPointOnTriangle(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return a + v * ab
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return a + w * ac
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + w * (c - b)
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return a + ab * v + ac * w
    }

    /// Brute-force closest point; use `SurfaceIndex` for repeated queries.
    func closestPoint(to p: SIMD3<Double>) -> ClosestPoint {
        var best = ClosestPoint(point: .zero, distance: .greatestFiniteMagnitude, triangle: -1, normal: .zero, signedDistance: 0)
        for (t, tri) in triangles.enumerated() {
            let q = TriangleMesh.closestPointOnTriangle(p, vertices[Int(tri.x)], vertices[Int(tri.y)], vertices[Int(tri.z)])
            let d = simd_length(p - q)
            if d < best.distance { best = ClosestPoint(point: q, distance: d, triangle: t, normal: .zero, signedDistance: 0) }
        }
        best.normal = faceNormal(best.triangle)
        best.signedDistance = simd_dot(p - best.point, best.normal) >= 0 ? best.distance : -best.distance
        return best
    }
}

/// Uniform-grid acceleration structure for closest-point queries on a mesh.
nonisolated final class SurfaceIndex: @unchecked Sendable {
    let mesh: TriangleMesh
    private let origin: SIMD3<Double>
    private let cellSize: Double
    private let cells: SIMD3<Int>
    private var buckets: [[Int32]]

    init(mesh: TriangleMesh, cellsPerAxis: Int = 32) {
        self.mesh = mesh
        let (lo, hi) = mesh.boundingBox
        let extent = max((hi - lo).max(), 1e-6)
        cellSize = extent / Double(cellsPerAxis)
        origin = lo - SIMD3(repeating: cellSize)  // one cell of margin
        let n = cellsPerAxis + 2
        cells = SIMD3(n, n, n)
        buckets = [[Int32]](repeating: [], count: n * n * n)
        for (t, tri) in mesh.triangles.enumerated() {
            let a = mesh.vertices[Int(tri.x)], b = mesh.vertices[Int(tri.y)], c = mesh.vertices[Int(tri.z)]
            let tlo = cell(pointwiseMin(a, pointwiseMin(b, c))), thi = cell(pointwiseMax(a, pointwiseMax(b, c)))
            for k in tlo.z...thi.z { for j in tlo.y...thi.y { for i in tlo.x...thi.x {
                buckets[bucketIndex(i, j, k)].append(Int32(t))
            } } }
        }
    }

    private func cell(_ p: SIMD3<Double>) -> SIMD3<Int> {
        let c = (p - origin) / cellSize
        return SIMD3(clamp(Int(floor(c.x)), 0, cells.x - 1), clamp(Int(floor(c.y)), 0, cells.y - 1), clamp(Int(floor(c.z)), 0, cells.z - 1))
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
    private func bucketIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { i + cells.x * (j + cells.y * k) }

    /// Exact closest point: expands rings of cells until the ring's inner
    /// boundary is farther than the best distance found.
    func closestPoint(to p: SIMD3<Double>) -> TriangleMesh.ClosestPoint {
        let c = cell(p)
        var best = TriangleMesh.ClosestPoint(point: .zero, distance: .greatestFiniteMagnitude, triangle: -1, normal: .zero, signedDistance: 0)
        var visited = Set<Int32>()
        let maxRing = max(cells.x, cells.y, cells.z)
        for ring in 0...maxRing {
            // Anything in this ring is at least (ring − 1) cells away from p's cell edge.
            let bound = Double(max(ring - 1, 0)) * cellSize
            if best.distance < bound { break }
            for k in (c.z - ring)...(c.z + ring) {
                guard k >= 0 && k < cells.z else { continue }
                for j in (c.y - ring)...(c.y + ring) {
                    guard j >= 0 && j < cells.y else { continue }
                    for i in (c.x - ring)...(c.x + ring) {
                        guard i >= 0 && i < cells.x else { continue }
                        let onRing = abs(i - c.x) == ring || abs(j - c.y) == ring || abs(k - c.z) == ring
                        guard onRing else { continue }
                        for t in buckets[bucketIndex(i, j, k)] where !visited.contains(t) {
                            visited.insert(t)
                            let tri = mesh.triangles[Int(t)]
                            let q = TriangleMesh.closestPointOnTriangle(p, mesh.vertices[Int(tri.x)], mesh.vertices[Int(tri.y)], mesh.vertices[Int(tri.z)])
                            let d = simd_length(p - q)
                            if d < best.distance { best = .init(point: q, distance: d, triangle: Int(t), normal: .zero, signedDistance: 0) }
                        }
                    }
                }
            }
        }
        if best.triangle < 0 { return mesh.closestPoint(to: p) }
        best.normal = mesh.faceNormal(best.triangle)
        best.signedDistance = simd_dot(p - best.point, best.normal) >= 0 ? best.distance : -best.distance
        return best
    }
}
