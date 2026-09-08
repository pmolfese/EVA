//
//  HeadTransformTests.swift
//  EVATests
//
//  HeadTransform.fit against MNE-Python's fit_matched_points (see
//  Tools/resolve-validate/make_fixtures.py), plus frame bookkeeping.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("HeadTransform")
struct HeadTransformTests {
    struct Reference: Decodable {
        struct Umeyama: Decodable {
            var source: [[Double]]
            var target_rigid_noisy: [[Double]]
            var target_scale_noisy: [[Double]]
            var mne_rigid: [[Double]]
            var mne_scale: [[Double]]
            var fiducials_source: [[Double]]
            var fiducials_target: [[Double]]
            var mne_fiducials: [[Double]]
            var true_rotation: [[Double]]
            var true_translation: [Double]
            var true_scale: Double
        }
        var umeyama: Umeyama
    }

    static let reference: Reference = {
        let url = Fixtures.url("Resolve/resolve_reference.json")
        return try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }()

    private func points(_ rows: [[Double]]) -> [SIMD3<Double>] { rows.map { SIMD3($0[0], $0[1], $0[2]) } }
    private func matrix(_ rows: [[Double]]) -> simd_double4x4 {
        simd_double4x4(rows: rows.map { SIMD4($0[0], $0[1], $0[2], $0[3]) })
    }
    private func expectClose(_ a: simd_double4x4, _ b: simd_double4x4, tol: Double) {
        for c in 0..<4 { for r in 0..<4 {
            #expect(abs(a[c][r] - b[c][r]) < tol, "[\(r)][\(c)] \(a[c][r]) vs \(b[c][r])")
        } }
    }

    @Test("rigid fit matches MNE fit_matched_points")
    func rigidMatchesMNE() throws {
        let ref = Self.reference.umeyama
        let fit = try HeadTransform.fit(source: points(ref.source), target: points(ref.target_rigid_noisy))
        expectClose(fit.transform.matrix, matrix(ref.mne_rigid), tol: 1e-6)
        #expect(abs(fit.scale - 1) < 1e-12)
        #expect(fit.rmsError < 0.002)
        let r = fit.transform.rotation
        #expect(abs(r.determinant - 1) < 1e-9)
    }

    @Test("similarity fit matches MNE with scale")
    func scaleMatchesMNE() throws {
        let ref = Self.reference.umeyama
        // MNE fits scale with an iterative least-squares optimizer, so agreement is
        // to its convergence (~1e-5), not machine precision; the closed-form
        // Umeyama solution must also be at least as good in residual.
        let source = points(ref.source), target = points(ref.target_scale_noisy)
        let fit = try HeadTransform.fit(source: source, target: target, allowScale: true)
        expectClose(fit.transform.matrix, matrix(ref.mne_scale), tol: 1e-4)
        #expect(abs(fit.scale - ref.true_scale) < 0.02)
        let mne = HeadTransform(from: .head, to: .mri, matrix: matrix(ref.mne_scale))
        let mneRMS = (zip(source, target).map { simd_length_squared(mne.apply($0) - $1) }.reduce(0, +) / Double(source.count)).squareRoot()
        #expect(fit.rmsError <= mneRMS + 1e-12, "ours \(fit.rmsError) vs MNE \(mneRMS)")
    }

    @Test("three fiducials (rank-2 covariance) fit exactly")
    func fiducials() throws {
        let ref = Self.reference.umeyama
        let fit = try HeadTransform.fit(source: points(ref.fiducials_source), target: points(ref.fiducials_target))
        expectClose(fit.transform.matrix, matrix(ref.mne_fiducials), tol: 1e-6)
        #expect(fit.rmsError < 1e-9)
        #expect(abs(fit.transform.rotation.determinant - 1) < 1e-9)
    }

    @Test("inverse and chaining keep frames straight")
    func frames() throws {
        let ref = Self.reference.umeyama
        let fit = try HeadTransform.fit(source: points(ref.fiducials_source), target: points(ref.fiducials_target), from: .head, to: .mri)
        let inverse = fit.transform.inverted()
        #expect(inverse.from == .mri && inverse.to == .head)
        let roundTrip = fit.transform.then(inverse)
        #expect(roundTrip.from == .head && roundTrip.to == .head)
        expectClose(roundTrip.matrix, matrix_identity_double4x4, tol: 1e-9)
        let p = SIMD3(0.01, 0.02, 0.03)
        #expect(simd_length(inverse.apply(fit.transform.apply(p)) - p) < 1e-12)
    }

    @Test("degenerate input is refused")
    func degenerate() {
        let line = [SIMD3(0.0, 0, 0), SIMD3(1.0, 0, 0), SIMD3(2.0, 0, 0)]
        #expect(throws: HeadTransform.FitError.self) { try HeadTransform.fit(source: line, target: line) }
        #expect(throws: HeadTransform.FitError.self) { try HeadTransform.fit(source: [.zero, .zero], target: [.zero, .zero]) }
    }
}
