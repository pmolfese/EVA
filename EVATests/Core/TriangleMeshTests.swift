//
//  TriangleMeshTests.swift
//  EVATests
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("TriangleMesh")
struct TriangleMeshTests {
    @Test("icosphere area, volume and normals")
    func icosphere() {
        let r = 0.09
        let m = TriangleMesh.icosphere(subdivisions: 4, radius: r)
        #expect(m.vertices.count == 2562 && m.triangles.count == 5120)
        let (area, volume) = m.areaAndVolume
        #expect(abs(area / (4 * .pi * r * r) - 1) < 0.01)
        #expect(abs(volume / (4.0 / 3.0 * .pi * r * r * r) - 1) < 0.01)
        let normals = m.computedVertexNormals()
        for (v, n) in zip(m.vertices, normals) { #expect(simd_dot(simd_normalize(v), n) > 0.999) }
    }

    @Test("indexed closest point agrees with brute force, inside and outside")
    func closestPoint() {
        let m = TriangleMesh.icosphere(subdivisions: 3, radius: 0.09, centre: SIMD3(0.01, -0.02, 0.03))
        let index = SurfaceIndex(mesh: m, cellsPerAxis: 16)
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let p = SIMD3(Double.random(in: -0.15...0.15, using: &generator), Double.random(in: -0.15...0.15, using: &generator), Double.random(in: -0.15...0.15, using: &generator))
            let fast = index.closestPoint(to: p)
            let slow = m.closestPoint(to: p)
            #expect(abs(fast.distance - slow.distance) < 1e-12)
            #expect(simd_length(fast.point - slow.point) < 1e-9)
            let radial = simd_length(p - m.centroid)
            // Sign: outside the sphere → positive.
            #expect((fast.signedDistance > 0) == (radial > 0.09) || abs(radial - 0.09) < 2e-3)
            // Distance ≈ |radial − r| for a fine sphere.
            #expect(abs(fast.distance - abs(radial - 0.09)) < 2e-3)
        }
    }

    @Test("closest point on triangle hits vertices, edges and the interior")
    func triangle() {
        let a = SIMD3(0.0, 0, 0), b = SIMD3(1.0, 0, 0), c = SIMD3(0.0, 1, 0)
        #expect(TriangleMesh.closestPointOnTriangle(SIMD3(-1, -1, 0), a, b, c) == a)
        #expect(TriangleMesh.closestPointOnTriangle(SIMD3(2, 0, 0), a, b, c) == b)
        #expect(simd_length(TriangleMesh.closestPointOnTriangle(SIMD3(0.5, -1, 0), a, b, c) - SIMD3(0.5, 0, 0)) < 1e-12)
        #expect(simd_length(TriangleMesh.closestPointOnTriangle(SIMD3(0.25, 0.25, 5), a, b, c) - SIMD3(0.25, 0.25, 0)) < 1e-12)
        #expect(simd_length(TriangleMesh.closestPointOnTriangle(SIMD3(1, 1, 0), a, b, c) - SIMD3(0.5, 0.5, 0)) < 1e-12)
    }
}
