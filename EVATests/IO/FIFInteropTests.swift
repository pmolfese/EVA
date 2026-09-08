//
//  FIFInteropTests.swift
//  EVATests
//
//  FIF reading against MNE-Python's own readers (fsaverage trans / fiducials /
//  BEM surfaces, references in resolve_reference.json) and write → read round
//  trips. Files we write are also left for Tools/resolve-validate/check_swift_fif.py
//  to read back with MNE.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("FIF interop")
struct FIFInteropTests {
    struct Reference: Decodable {
        struct Trans: Decodable { var from: Int; var to: Int; var matrix: [[Double]] }
        struct Fiducials: Decodable {
            struct P: Decodable { var kind: Int; var ident: Int; var r: [Double] }
            var frame: Int; var points: [P]
        }
        struct Head: Decodable { var path: String; var id: Int; var np: Int; var ntri: Int; var coord_frame: Int; var rr_first: [[Double]]; var tris_first: [[Int]]; var rr_mean: [Double] }
        struct BEM: Decodable {
            struct S: Decodable { var id: Int; var np: Int; var ntri: Int; var sigma: Double; var rr_mean: [Double] }
            var path: String; var surfaces: [S]
        }
        var trans: Trans; var fiducials: Fiducials; var head_surface: Head; var bem_surfaces: BEM
    }
    struct Root: Decodable { var fif: Reference }

    static let reference: Reference = {
        try! JSONDecoder().decode(Root.self, from: Data(contentsOf: Fixtures.url("Resolve/resolve_reference.json"))).fif
    }()

    static let validationDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EVAResolveValidation")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func expectClose(_ a: simd_double4x4, _ b: [[Double]], tol: Double) {
        for r in 0..<4 { for c in 0..<4 { #expect(abs(a[c][r] - b[r][c]) < tol, "[\(r)][\(c)] \(a[c][r]) vs \(b[r][c])") } }
    }

    @Test("fsaverage-trans.fif matches mne.read_trans")
    func readTrans() throws {
        let ref = Self.reference.trans
        let t = try HeadTransform.readFIF(from: Fixtures.url("Resolve/fsaverage-trans.fif"))
        #expect(t.from.rawValue == ref.from && t.to.rawValue == ref.to)
        #expect(t.from == .head && t.to == .mri)
        expectClose(t.matrix, ref.matrix, tol: 1e-6)
    }

    @Test("trans write → read round trip, and file for MNE to check")
    func writeTrans() throws {
        let original = try HeadTransform.readFIF(from: Fixtures.url("Resolve/fsaverage-trans.fif"))
        let url = Self.validationDirectory.appendingPathComponent("swift-trans.fif")
        try original.writeFIF(to: url)
        let back = try HeadTransform.readFIF(from: url)
        #expect(back.from == original.from && back.to == original.to)
        for c in 0..<4 { for r in 0..<4 { #expect(abs(back.matrix[c][r] - original.matrix[c][r]) < 1e-6) } }
        // A fresh transform from fiducials, too.
        let t = HeadTransform.headFrame(nasion: SIMD3(0, 0.1, -0.02), lpa: SIMD3(-0.08, 0, -0.03), rpa: SIMD3(0.08, 0, -0.03), from: .mri).inverted()
        try t.writeFIF(to: Self.validationDirectory.appendingPathComponent("swift-headmri-trans.fif"))
        let back2 = try HeadTransform.readFIF(from: Self.validationDirectory.appendingPathComponent("swift-headmri-trans.fif"))
        #expect(back2.from == .head && back2.to == .mri)
    }

    @Test("fsaverage-fiducials.fif matches mne.io.read_fiducials")
    func readFiducials() throws {
        let ref = Self.reference.fiducials
        let d = try Digitization.readFIF(from: Fixtures.url("Resolve/fsaverage-fiducials.fif"))
        #expect(d.frame.rawValue == ref.frame && d.frame == .mri)
        #expect(d.points.count == ref.points.count)
        for (p, q) in zip(d.points, ref.points) {
            #expect(Int(p.kind.rawValue) == q.kind && Int(p.ident) == q.ident)
            #expect(simd_length(p.r - SIMD3(q.r[0], q.r[1], q.r[2])) < 1e-7)
        }
        #expect(d.nasion != nil && d.lpa != nil && d.rpa != nil)
        #expect(d.lpa!.x < 0 && d.rpa!.x > 0 && d.nasion!.y > 0)
        let positions = ElectrodePositions(digitization: d, name: "fsaverage")
        #expect(positions.hasFiducials && positions.eeg.isEmpty && positions.frame == .mri)
    }

    @Test("digitization write → read round trip with EEG, fiducials, head shape")
    func writeDig() throws {
        var p = try ElectrodePositions.read(from: Fixtures.url("Resolve/sample.csv"))
        p.points.append(.init(name: "hsp", kind: .headShape, position: SIMD3(0.01, 0.02, 0.09), channelIndex: nil))
        p.frame = .head
        let url = Self.validationDirectory.appendingPathComponent("swift-dig.fif")
        try p.writeFIF(to: url)
        let back = try ElectrodePositions.readFIF(from: url, eegNames: p.eegNames)
        #expect(back.frame == .head)
        #expect(back.eegNames == p.eegNames)
        for (a, b) in zip(back.eegPositions, p.eegPositions) { #expect(simd_length(a - b) < 1e-7) }
        #expect(simd_length(back.nasion! - p.nasion!) < 1e-7 && simd_length(back.lpa! - p.lpa!) < 1e-7 && simd_length(back.rpa! - p.rpa!) < 1e-7)
        #expect(back.headShape.count == 1)
    }

    @Test("fsaverage head and BEM surfaces match mne.read_bem_surfaces (local fsaverage copies)")
    func readBEM() throws {
        // The surfaces are FreeSurfer-derived and git-ignored; Tools/resolve-validate/
        // make_fixtures.py copies them from the MNE data into Fixtures/Resolve/local.
        let head = Self.reference.head_surface
        let headURL = Fixtures.directory.appendingPathComponent("Resolve/\(head.path)")
        guard FileManager.default.fileExists(atPath: headURL.path) else {
            print("fsaverage surfaces not present at \(headURL.path); run make_fixtures.py — skipping")
            return
        }
        let surfaces = try BEMSurface.readFIF(from: headURL)
        #expect(surfaces.count == 1)
        let s = surfaces[0]
        #expect(Int(s.kind.rawValue) == head.id && s.frame.rawValue == head.coord_frame)
        #expect(s.mesh.vertices.count == head.np && s.mesh.triangles.count == head.ntri)
        for (v, r) in zip(s.mesh.vertices.prefix(3), head.rr_first) { #expect(simd_length(v - SIMD3(r[0], r[1], r[2])) < 1e-7) }
        for (t, r) in zip(s.mesh.triangles.prefix(3), head.tris_first) { #expect(t == SIMD3(Int32(r[0]), Int32(r[1]), Int32(r[2]))) }
        let mean = s.mesh.centroid
        #expect(simd_length(mean - SIMD3(head.rr_mean[0], head.rr_mean[1], head.rr_mean[2])) < 1e-6)
        // (MNE writes no normals tag for head surfaces; they are computed on demand.)
        // Outward winding: positive volume, ~ head sized.
        let (_, volume) = s.mesh.areaAndVolume
        #expect(volume > 0.002 && volume < 0.006, "volume \(volume) m³")

        let bem = Self.reference.bem_surfaces
        let three = try BEMSurface.readFIF(from: Fixtures.directory.appendingPathComponent("Resolve/\(bem.path)"))
        #expect(three.count == 3)
        for (s, r) in zip(three, bem.surfaces) {
            #expect(Int(s.kind.rawValue) == r.id && s.mesh.vertices.count == r.np && s.mesh.triangles.count == r.ntri)
            #expect(abs(s.sigma - r.sigma) < 1e-6)
        }
        // Nested: head encloses skull encloses brain (by volume).
        let volumes = three.map { $0.mesh.areaAndVolume.volume }
        #expect(volumes[0] > volumes[1] && volumes[1] > volumes[2])
    }

    @Test("BEM surfaces write → read round trip (icosphere shells), file for MNE to check")
    func writeBEM() throws {
        let shells: [BEMSurface] = [
            BEMSurface(kind: .head, sigma: 0.3, frame: .mri, mesh: .icosphere(subdivisions: 2, radius: 0.09)),
            BEMSurface(kind: .skull, sigma: 0.006, frame: .mri, mesh: .icosphere(subdivisions: 2, radius: 0.085)),
            BEMSurface(kind: .brain, sigma: 0.3, frame: .mri, mesh: .icosphere(subdivisions: 2, radius: 0.08))
        ]
        let url = Self.validationDirectory.appendingPathComponent("swift-bem.fif")
        try BEMSurface.writeFIF(shells, to: url)
        let back = try BEMSurface.readFIF(from: url)
        #expect(back.count == 3)
        for (a, b) in zip(back, shells) {
            #expect(a.kind == b.kind && abs(a.sigma - b.sigma) < 1e-6 && a.frame == .mri)
            #expect(a.mesh.vertices.count == b.mesh.vertices.count && a.mesh.triangles == b.mesh.triangles)
            for (v, w) in zip(a.mesh.vertices, b.mesh.vertices) { #expect(simd_length(v - w) < 1e-7) }
            #expect(a.mesh.vertexNormals != nil)
        }
    }
}
