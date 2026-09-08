//
//  ForwardFixtureTests.swift
//  EVATests
//
//  The reference lead fields from Tools/forward-compare/make_forward_fixtures.py
//  (EVA_RESOLVE2.md R3.5) are what the imported-BEM forward operator will be
//  measured against. Before any of that exists, this asserts the fixtures are
//  *consumable* by the readers we already ship — geometry, electrodes and trans
//  all parse, agree with what MNE recorded, and are in the frames the README
//  claims. A reference nobody can open is not a reference.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("Forward reference fixtures")
struct ForwardFixtureTests {
    struct Reference: Decodable {
        struct Surface: Decodable { var id: Int; var np: Int; var ntri: Int; var sigma: Double; var coord_frame: Int }
        struct Solver: Decodable {
            var solution_file: String
            var solver_field: String
            var nsol: Int
            var solution_shape: [Int]
            var channel_names: [String]
            var source_rr_head_m: [[Double]]
            var gain: [[Double]]
        }
        struct Case: Decodable {
            var name: String
            var surfaces: [Surface]
            var electrode_names: [String]
            var electrodes_head_m: [[Double]]
            var fiducials_head_m: [String: [Double]]
            var dipoles_mri_m: [[Double]]
            var head_to_mri_trans: [[Double]]
            var solvers: [String: Solver]
        }
        var gain_scale_from_mne: Double
        var cases: [String: Case]
    }

    static let reference: Reference = {
        try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: Fixtures.url("Resolve/Forward/forward_reference.json")))
    }()

    private static func url(_ name: String) -> URL { Fixtures.url("Resolve/Forward/\(name)") }

    @Test("both committed cases are present with two solvers each", arguments: ["fsaverage-ico2", "sphere-ico2"])
    func caseShape(name: String) throws {
        let c = try #require(Self.reference.cases[name])
        #expect(c.surfaces.count == 3)
        #expect(Set(c.surfaces.map(\.id)) == [1, 3, 4])          // brain / skull / head
        #expect(Set(c.solvers.keys) == ["mne", "openmeeg"])
        for (solver, s) in c.solvers {
            // n_electrodes x (3 * n_dipoles), and one solution row per BEM vertex.
            #expect(s.gain.count == c.electrode_names.count, "\(solver) rows")
            #expect(s.gain.allSatisfy { $0.count == 3 * c.dipoles_mri_m.count }, "\(solver) columns")
            let vertices = c.surfaces.reduce(0) { $0 + $1.np }
            switch solver {
            case "mne":
                // Dense vertex-potential solution: self-sufficient, and the operator
                // R3.3 evaluates.
                #expect(s.nsol == vertices)
                #expect(s.solution_shape == [vertices, vertices])
            default:
                // OpenMEEG's symmetric BEM carries normal currents on the two inner
                // interfaces as well as vertex potentials, stored packed. MNE only
                // evaluates it by calling back into libOpenMEEG, so this file is a
                // lead-field source (R3.7), not something EVA can evaluate itself.
                let currents = c.surfaces.filter { $0.id != 4 }.reduce(0) { $0 + $1.ntri }
                #expect(s.nsol == vertices + currents)
                #expect(s.solution_shape == [s.nsol * (s.nsol + 1) / 2])
            }
            #expect(s.channel_names == c.electrode_names, "\(solver) channel order")
            #expect(s.gain.allSatisfy { $0.allSatisfy(\.isFinite) }, "\(solver) finite")
        }
    }

    @Test("geometry FIF parses and matches what MNE recorded", arguments: ["fsaverage-ico2", "sphere-ico2"])
    func geometry(name: String) throws {
        let c = try #require(Self.reference.cases[name])
        let surfaces = try BEMSurface.readFIF(from: Self.url("\(name)-bem.fif"))
        #expect(surfaces.count == c.surfaces.count)
        // File order is MNE's: outer first. Index by id, never by position.
        for ref in c.surfaces {
            let s = try #require(surfaces.first { $0.kind.rawValue == Int32(ref.id) }, "surface id \(ref.id)")
            #expect(s.mesh.vertices.count == ref.np)
            #expect(s.mesh.triangles.count == ref.ntri)
            #expect(abs(s.sigma - ref.sigma) < 1e-7 * max(ref.sigma, 1e-3))   // FIF stores sigma as float32
            #expect(s.frame.rawValue == ref.coord_frame)
            #expect(s.frame == .mri)
            #expect(s.mesh.triangles.allSatisfy { t in
                (0..<Int32(ref.np)).contains(t.x) && (0..<Int32(ref.np)).contains(t.y) && (0..<Int32(ref.np)).contains(t.z)
            }, "triangle indices in range for surface \(ref.id)")
        }
        // Nesting, in the direction EVA cares about: every inner-skull vertex is
        // inside the scalp, i.e. on the negative side of its outward normal.
        let scalp = try #require(surfaces.first { $0.kind == .head })
        let inner = try #require(surfaces.first { $0.kind == .brain })
        let index = SurfaceIndex(mesh: scalp.mesh)
        let outside = inner.mesh.vertices.filter { index.closestPoint(to: $0).signedDistance > 0 }
        #expect(outside.isEmpty, "\(outside.count) inner-skull vertices lie outside the scalp")
    }

    @Test("electrodes and trans parse, in the frames the README claims", arguments: ["fsaverage-ico2", "sphere-ico2"])
    func electrodesAndTrans(name: String) throws {
        let c = try #require(Self.reference.cases[name])
        let dig = try ElectrodePositions.readFIF(from: Self.url("\(name)-electrodes-dig.fif"), eegNames: c.electrode_names)
        #expect(dig.frame == .head)
        let eeg = dig.points.filter { $0.kind == .eeg }
        #expect(eeg.count == c.electrode_names.count)
        for (i, p) in eeg.enumerated() {
            let ref = SIMD3<Double>(c.electrodes_head_m[i][0], c.electrodes_head_m[i][1], c.electrodes_head_m[i][2])
            #expect(simd_length(p.position - ref) < 1e-6, "\(c.electrode_names[i]) at \(p.position) vs \(ref)")
        }
        for (key, value) in c.fiducials_head_m {
            let kind: ElectrodePositions.Kind = key == "nasion" ? .nasion : (key == "lpa" ? .lpa : .rpa)
            let p = try #require(dig.points.first { $0.kind == kind }, "fiducial \(key)")
            #expect(simd_length(p.position - SIMD3<Double>(value[0], value[1], value[2])) < 1e-6, "fiducial \(key)")
        }

        let trans = try HeadTransform.readFIF(from: Self.url("\(name)-trans.fif"))
        #expect(trans.from == .head && trans.to == .mri)
        for r in 0..<4 { for col in 0..<4 {
            #expect(abs(trans.matrix[col][r] - c.head_to_mri_trans[r][col]) < 1e-6, "trans[\(r)][\(col)]")
        } }
    }

    /// MNE reports the dipoles in the head frame; we hold them in MRI. If our
    /// `-trans.fif` and MNE's agree, one is the other transformed — which is the
    /// cheapest possible check that R3.3's frame handling starts from solid ground.
    @Test("MNE's head-frame dipoles are our trans applied to the MRI ones", arguments: ["fsaverage-ico2", "sphere-ico2"])
    func dipoleFrames(name: String) throws {
        let c = try #require(Self.reference.cases[name])
        let trans = try HeadTransform.readFIF(from: Self.url("\(name)-trans.fif"))
        let mriToHead = trans.matrix.inverse
        let mne = try #require(c.solvers["mne"])
        for (i, rr) in c.dipoles_mri_m.enumerated() {
            let head = mriToHead * SIMD4<Double>(rr[0], rr[1], rr[2], 1)
            let ref = mne.source_rr_head_m[i]
            let d = simd_length(SIMD3(head.x, head.y, head.z) - SIMD3<Double>(ref[0], ref[1], ref[2]))
            #expect(d < 1e-6, "dipole \(i) off by \(d) m")
        }
    }
}
