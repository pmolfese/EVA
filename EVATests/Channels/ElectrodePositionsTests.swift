//
//  ElectrodePositionsTests.swift
//  EVATests
//
//  Digitizer readers against MNE-Python's read_custom_montage on the same files,
//  EGI fiducials from a real coordinates.xml, the fiducial head frame against
//  get_ras_to_neuromag_trans, and the bundled 10-05 template.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("ElectrodePositions")
struct ElectrodePositionsTests {
    struct Reference: Decodable {
        struct Digitizer: Decodable {
            var ch_names: [String]
            var ch_pos: [[Double]]
            var nasion: [Double]
            var lpa: [Double]
            var rpa: [Double]
        }
        struct HeadFrame: Decodable { var nasion: [Double]; var lpa: [Double]; var rpa: [Double]; var trans: [[Double]] }
        struct EGI: Decodable { var nasion_cm: [Double]; var lpa_cm: [Double]; var rpa_cm: [Double]; var eeg_count: Int }
        var digitizers: [String: Digitizer]
        var head_frame: HeadFrame
        var egi_fixture: EGI
    }

    static let reference: Reference = {
        try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: Fixtures.url("Resolve/resolve_reference.json")))
    }()

    private func v(_ a: [Double]) -> SIMD3<Double> { SIMD3(a[0], a[1], a[2]) }

    @Test("digitizer formats match MNE", arguments: ["sample.sfp", "sample.elc", "sample.xyz", "sample.csv", "sample.tsv"])
    func formats(name: String) throws {
        let ref = try #require(Self.reference.digitizers[name])
        let p = try ElectrodePositions.read(from: Fixtures.url("Resolve/\(name)"))
        #expect(p.eegNames == ref.ch_names)
        for (ours, theirs) in zip(p.eegPositions, ref.ch_pos) {
            #expect(simd_length(ours - v(theirs)) < 1e-6, "\(name): \(ours) vs \(theirs)")
        }
        #expect(p.hasFiducials)
        #expect(simd_length(p.nasion! - v(ref.nasion)) < 1e-6)
        #expect(simd_length(p.lpa! - v(ref.lpa)) < 1e-6)
        #expect(simd_length(p.rpa! - v(ref.rpa)) < 1e-6)
        #expect(p.eeg.map { $0.channelIndex! } == Array(0..<ref.ch_names.count))
    }

    @Test("EGI coordinates.xml keeps EEG, reference, and fiducials in metres")
    func egi() throws {
        let ref = Self.reference.egi_fixture
        let p = try ElectrodePositions.read(from: Fixtures.url("example_2.mff"))
        #expect(p.eeg.count == ref.eeg_count)
        #expect(p.points.contains { $0.kind == .reference && $0.name == "VREF" })
        #expect(p.hasFiducials)
        #expect(simd_length(p.nasion! - v(ref.nasion_cm) * 0.01) < 1e-9)
        #expect(simd_length(p.lpa! - v(ref.lpa_cm) * 0.01) < 1e-9)
        #expect(simd_length(p.rpa! - v(ref.rpa_cm) * 0.01) < 1e-9)
        #expect(p.eeg.first?.channelIndex == 0 && p.eeg.last?.channelIndex == 255)
        #expect(p.medianRadius > 0.08 && p.medianRadius < 0.12)
        // Same directions as the legacy unit-sphere geometry (which normalizes
        // about the file origin, not the centroid), to a few degrees.
        let legacy = try #require(ElectrodeGeometry.load(from: Fixtures.url("example_2.mff")))
        let geometry = p.toGeometry()
        #expect(geometry.positions.count == legacy.positions.count)
        let dots = geometry.positions.compactMap { k, dir in legacy.positions[k].map { simd_dot(dir, $0) } }
        #expect(dots.min()! > 0.95)
        _ = try p.toMontage()
    }

    @Test("fiducial head frame matches MNE get_ras_to_neuromag_trans")
    func headFrame() throws {
        let ref = Self.reference.head_frame
        let t = HeadTransform.headFrame(nasion: v(ref.nasion), lpa: v(ref.lpa), rpa: v(ref.rpa))
        #expect(t.from == .unknown && t.to == .head)
        let mne = simd_double4x4(rows: ref.trans.map { SIMD4($0[0], $0[1], $0[2], $0[3]) })
        for c in 0..<4 { for r in 0..<4 { #expect(abs(t.matrix[c][r] - mne[c][r]) < 1e-9) } }
        // Fiducials land where the frame says they should.
        let n = t.apply(v(ref.nasion)), l = t.apply(v(ref.lpa)), r = t.apply(v(ref.rpa))
        #expect(abs(n.x) < 1e-12 && n.y > 0 && abs(n.z) < 1e-12)
        #expect(abs(l.y) < 1e-12 && abs(l.z) < 1e-12 && l.x < 0 && abs(l.x + r.x) < 1e-12)
        let p = try ElectrodePositions.read(from: Fixtures.url("Resolve/sample.csv"))
        let head = try #require(p.inHeadFrame())
        #expect(head.frame == .head)
        #expect(abs(head.lpa!.y) < 1e-12)
    }

    @Test("bundled 10-20 / 10-10 / 10-05 templates carry fiducials and scale")
    func templates() throws {
        let m20 = StandardMontage.tenTwenty.positions()
        let m10 = StandardMontage.tenTen.positions()
        let m05 = StandardMontage.tenFive.positions()
        #expect(m20.eeg.count == 21, "10-20 \(m20.eeg.count)"); #expect(m10.eeg.count == 71, "10-10 \(m10.eeg.count)"); #expect(m05.eeg.count == 345, "10-05 \(m05.eeg.count)")
        for m in [m20, m10, m05] {
            #expect(m.hasFiducials && m.frame == .head)
            for e in m.eeg { #expect(abs(simd_length(e.position) - StandardMontage.nominalRadiusMeters) < 1e-4) }
        }
        #expect(m20.eegNames.contains("Cz") && m20.eegNames.contains("Fp1") && !m20.eegNames.contains("AF7"))
        #expect(m10.eegNames.contains("AF7"))
        let cz = m05.eeg.first { $0.name == "Cz" }!.position
        #expect(abs(cz.z - StandardMontage.nominalRadiusMeters) < 1e-9)
        #expect(m05.rpa!.x > 0 && m05.nasion!.y > 0)
        let montage = try m20.toMontage()
        #expect(montage.electrodes.count == 21)
    }

    @Test("unit auto-detection")
    func units() throws {
        let mm = try ElectrodePositions.read(from: Fixtures.url("Resolve/sample.tsv"))
        let m = try ElectrodePositions.read(from: Fixtures.url("Resolve/sample.csv"))
        #expect(abs(mm.medianRadius - m.medianRadius) < 1e-6)
        let forced = try ElectrodePositions.read(from: Fixtures.url("Resolve/sample.csv"), unit: .millimeters)
        #expect(abs(forced.medianRadius - m.medianRadius * 0.001) < 1e-9)
    }
}
