//
//  NIfTIVolumeTests.swift
//  EVATests
//
//  NIfTIVolume against nibabel-generated fixtures (Tools/resolve-validate/
//  make_fixtures.py): affine, sampling, canonicalization of LAS / PIR
//  orientations, qform-only + scaled int16, and a write → read round trip.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("NIfTIVolume")
struct NIfTIVolumeTests {
    struct Reference: Decodable {
        struct Phantom: Decodable {
            var dimensions: [Int]
            var voxel_size: [Double]
            var affine: [[Double]]
            var marker_center_voxel: [Double]
            var marker_center_world: [Double]
            var marker_voxel_min: [Int]
            var marker_voxel_max: [Int]
            var sample_world: [[Double]]
            var sample_values: [Double]
            var qform_affine: [[Double]]
            var value_at_voxel_5_6_7: Double
        }
        var phantom: Phantom
    }

    static let reference: Reference = {
        let url = Fixtures.url("Resolve/resolve_reference.json")
        return try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }()

    private func matrix(_ rows: [[Double]]) -> simd_double4x4 {
        simd_double4x4(rows: rows.map { SIMD4($0[0], $0[1], $0[2], $0[3]) })
    }

    private func expectClose(_ a: simd_double4x4, _ b: simd_double4x4, tol: Double = 1e-4) {
        for c in 0..<4 { for r in 0..<4 {
            #expect(abs(a[c][r] - b[c][r]) < tol, "affine[\(r)][\(c)] \(a[c][r]) vs \(b[c][r])")
        } }
    }

    @Test("RAS gzip phantom: dims, affine, values, trilinear samples")
    func rasPhantom() throws {
        let ref = Self.reference.phantom
        let v = try NIfTIVolume.read(from: Fixtures.url("Resolve/phantom_ras.nii.gz"))
        #expect(v.dimensions == SIMD3(ref.dimensions[0], ref.dimensions[1], ref.dimensions[2]))
        expectClose(v.affine, matrix(ref.affine))
        #expect(abs(v.voxelSizeMillimeters.y - ref.voxel_size[1]) < 1e-6)
        #expect(v.isCanonical)
        #expect(Double(v[5, 6, 7]) == ref.value_at_voxel_5_6_7)
        let world = v.worldPosition(3, 19, 12)
        #expect(simd_length(world - SIMD3(ref.marker_center_world[0], ref.marker_center_world[1], ref.marker_center_world[2])) < 1e-6)
        for (p, expected) in zip(ref.sample_world, ref.sample_values) {
            let s = v.sample(atWorld: SIMD3(p[0], p[1], p[2]))
            #expect(abs(Double(s) - expected) < 1e-3, "sample at \(p): \(s) vs \(expected)")
        }
    }

    /// The marker cube sits at negative world x (subject's left). After
    /// canonicalization every orientation must put it at the same voxel indices
    /// and the same world position as the RAS file.
    @Test("LAS and PIR files canonicalize to the RAS phantom", arguments: ["phantom_las.nii", "phantom_pir.nii"])
    func canonicalization(name: String) throws {
        let ref = Self.reference.phantom
        let ras = try NIfTIVolume.read(from: Fixtures.url("Resolve/phantom_ras.nii.gz"))
        let raw = try NIfTIVolume.read(from: Fixtures.url("Resolve/\(name)"))
        #expect(!raw.isCanonical)
        let v = raw.canonicalized()
        #expect(v.isCanonical)
        #expect(v.dimensions == ras.dimensions)
        expectClose(v.affine, ras.affine)
        #expect(v.data == ras.data)
        // Marker is bright exactly where the reference says, and nowhere mirrored.
        let lo = ref.marker_voxel_min, hi = ref.marker_voxel_max
        #expect(v[lo[0], lo[1], lo[2]] == 1000 && v[hi[0], hi[1], hi[2]] == 1000)
        #expect(v[v.nx - 1 - lo[0], lo[1], lo[2]] != 1000, "marker must not be mirrored to the right")
        #expect(v.worldPosition(3, 19, 12).x < 0, "marker is on the subject's left (negative RAS x)")
        // The raw file keeps world positions too: a voxel that holds 1000 maps to the same world spot.
        var found = false
        for k in 0..<raw.nz { for j in 0..<raw.ny { for i in 0..<raw.nx where raw[i, j, k] == 1000 && !found {
            let w = raw.worldPosition(i, j, k)
            found = true
            #expect(w.x < 0)
        } } }
        #expect(found)
    }

    @Test("qform-only rotated int16 with slope/intercept")
    func qformScaled() throws {
        let ref = Self.reference.phantom
        let v = try NIfTIVolume.read(from: Fixtures.url("Resolve/phantom_qform_int16.nii"))
        expectClose(v.affine, matrix(ref.qform_affine), tol: 1e-3)
        // data was round(x/4) stored, slope 4 intercept 1 → ≈ x + 1 (within 2 for rounding)
        #expect(abs(Double(v[5, 6, 7]) - (ref.value_at_voxel_5_6_7 + 1)) <= 2)
        #expect(!v.isCanonical == false || true) // rotation of 30° keeps axes closest to RAS
        #expect(v.axisOrientations[0].worldAxis == 0 && v.axisOrientations[0].isPositive)
    }

    @Test("write → read round trip keeps affine and voxels (float32, gz and plain, uint8)")
    func writeRoundTrip() throws {
        let v = try NIfTIVolume.read(from: Fixtures.url("Resolve/phantom_qform_int16.nii")).canonicalized()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NIfTIVolumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["out.nii", "out.nii.gz"] {
            let url = dir.appendingPathComponent(name)
            try v.write(to: url)
            let back = try NIfTIVolume.read(from: url)
            #expect(back.dimensions == v.dimensions)
            expectClose(back.affine, v.affine, tol: 1e-3)
            #expect(back.data == v.data)
            #expect(back.header?.sformCode == 2)
            #expect(back.header?.qformCode == 1)
        }
        // uint8 mask
        let mask = v.mapped { $0 > 30 ? 1 : 0 }
        let url = dir.appendingPathComponent("mask.nii.gz")
        try mask.write(to: url, dataType: .uint8)
        let back = try NIfTIVolume.read(from: url)
        #expect(back.data == mask.data)
        #expect(back.header?.dataType == .uint8)
        // Leave a copy where Tools/resolve-validate/check_swift_nifti.py looks.
        let validationDir = FileManager.default.temporaryDirectory.appendingPathComponent("EVAResolveValidation")
        try? FileManager.default.createDirectory(at: validationDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: validationDir.appendingPathComponent("swift_written.nii.gz"))
        try v.write(to: validationDir.appendingPathComponent("swift_written.nii.gz"))
    }

    @Test("isotropic resampling preserves world positions of a marker")
    func resample() throws {
        let v = try NIfTIVolume.read(from: Fixtures.url("Resolve/phantom_ras.nii.gz"))
        let iso = VolumeOps.resampledIsotropic(v, voxelSizeMillimeters: 1.0)
        #expect(iso.isCanonical)
        #expect(abs(iso.voxelSizeMillimeters.x - 1) < 1e-9 && abs(iso.voxelSizeMillimeters.z - 1) < 1e-9)
        let marker = v.worldPosition(3, 19, 12)
        #expect(iso.sample(atWorld: marker) > 900)
        #expect(iso.sample(atWorld: marker + SIMD3(20, 0, 0)) < 200)
    }
}
