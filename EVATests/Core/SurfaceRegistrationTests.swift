//
//  SurfaceRegistrationTests.swift
//  EVATests
//
//  ICP recovers a known perturbation of electrodes lying on a scalp, with and
//  without scale, and the template-scalp fit finds the right head size.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("Surface registration")
struct SurfaceRegistrationTests {
    /// An ellipsoidal "scalp" (sphere scaled per axis) so rotations are observable.
    private func scalp(radius: Double = 0.09) -> TriangleMesh {
        var m = TriangleMesh.icosphere(subdivisions: 4, radius: radius)
        m.vertices = m.vertices.map { SIMD3($0.x * 0.85, $0.y * 1.1, $0.z) }
        return m
    }

    /// Electrodes: the 10-10 template projected onto the scalp, expressed in the
    /// scalp's frame.
    private func electrodesOnScalp(_ surface: SurfaceIndex) -> ElectrodePositions {
        var p = StandardMontage.tenTen.positions(radiusMeters: 0.09)
        p.points = p.points.map { var q = $0; q.position = surface.closestPoint(to: $0.position).point; return q }
        p.frame = .mri
        return p
    }

    private func perturbation(angleDegrees: Double, shift: SIMD3<Double>, scale: Double = 1) -> HeadTransform {
        let a = angleDegrees * .pi / 180
        let axis = simd_normalize(SIMD3(0.3, 1.0, 0.2))
        let q = simd_quatd(angle: a, axis: axis)
        let r = simd_double3x3(q)
        return HeadTransform.rotation(r * scale, translation: shift, from: .head, to: .mri)
    }

    @Test("rigid ICP recovers a 12° / 15 mm perturbation from fiducials + surface")
    func rigid() throws {
        let mesh = scalp()
        let surface = SurfaceIndex(mesh: mesh)
        let truth = electrodesOnScalp(surface)
        let perturb = perturbation(angleDegrees: 12, shift: SIMD3(0.015, -0.01, 0.008))
        // "Digitized" electrodes live in a head frame that is truth moved by the inverse.
        var digitized = truth.transformed(by: perturb.inverted())
        digitized.frame = .head
        // Fiducials on the surface side are the truth's fiducials.
        let fids = (nasion: truth.nasion!, lpa: truth.lpa!, rpa: truth.rpa!)
        let result = try SurfaceRegistration.coregister(electrodes: digitized, surface: surface, surfaceFiducials: fids)
        #expect(result.converged)
        #expect(result.rms < 1e-4, "rms \(result.rms)")
        let recovered = result.transform.apply(digitized.eegPositions)
        for (a, b) in zip(recovered, truth.eegPositions) { #expect(simd_length(a - b) < 5e-4) }
    }

    /// Without fiducials, a near-spherical scalp cannot pin down rotation — ICP
    /// only promises that the points end up on the surface. Check that, and that
    /// trimming keeps gross outliers from dragging the fit.
    @Test("ICP without fiducials from a centroid start puts inliers on the surface despite outliers")
    func noFiducials() throws {
        let mesh = scalp()
        let surface = SurfaceIndex(mesh: mesh)
        let truth = electrodesOnScalp(surface)
        let perturb = perturbation(angleDegrees: 6, shift: SIMD3(0.004, 0.006, -0.005))
        var digitized = truth.transformed(by: perturb.inverted())
        digitized.frame = .head
        var generator = SeededGenerator(seed: 3)
        digitized.points = digitized.points.map { p in
            var q = p
            q.position += SIMD3(Double.random(in: -0.001...0.001, using: &generator), Double.random(in: -0.001...0.001, using: &generator), Double.random(in: -0.001...0.001, using: &generator))
            return q
        }
        digitized.points[5].position += SIMD3(0.03, 0, 0)
        digitized.points[9].position += SIMD3(0, 0, 0.04)
        var options = SurfaceRegistration.ICPOptions()
        options.trimFraction = 0.1
        let result = try SurfaceRegistration.coregister(electrodes: digitized, surface: surface, surfaceFiducials: nil, options: options)
        #expect(result.median < 0.0015, "median \(result.median)")
        #expect(result.maximum > 0.02)  // the outliers stay far
        let inliers = result.distances.enumerated().filter { $0.offset != 5 && $0.offset != 9 }.map(\.element)
        #expect(inliers.max()! < 0.004, "inlier max \(inliers.max()!)")
    }

    /// A real head is asymmetric enough for ICP alone to recover pose. Uses the
    /// git-ignored fsaverage scalp copied by Tools/resolve-validate/make_fixtures.py.
    @Test("ICP on the fsaverage scalp recovers a 6° / 8 mm perturbation without fiducials")
    func fsaveragePose() throws {
        let url = Fixtures.directory.appendingPathComponent("Resolve/local/fsaverage-head.fif")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("fsaverage head not present; run make_fixtures.py — skipping")
            return
        }
        let head = try BEMSurface.readFIF(from: url)[0].mesh
        let surface = SurfaceIndex(mesh: head)
        // Electrodes: the 10-05 template scaled to fsaverage, projected onto the scalp.
        var truth = StandardMontage.tenFive.positions(radiusMeters: 0.095)
        truth.points = truth.points.map { var q = $0; q.position = surface.closestPoint(to: $0.position + head.centroid).point; return q }
        truth.frame = .mri
        let perturb = perturbation(angleDegrees: 6, shift: SIMD3(0.005, -0.004, 0.006))
        var digitized = truth.transformed(by: perturb.inverted())
        digitized.frame = .head
        // Centroid start, no fiducials: the points land on the scalp, with some
        // residual sliding along it.
        let blind = try SurfaceRegistration.coregister(electrodes: digitized, surface: surface, surfaceFiducials: nil)
        #expect(blind.rms < 5e-4, "rms \(blind.rms)")
        let blindErrors = zip(blind.transform.apply(digitized.eegPositions), truth.eegPositions).map { simd_length($0 - $1) }
        #expect(blindErrors.max()! < 0.01 && blindErrors.sorted()[blindErrors.count / 2] < 0.006, "blind max \(blindErrors.max()!)")
        // Fiducial start (the fsaverage fiducials, in MRI space) then ICP: pose to ~1 mm.
        let fiducials = try Digitization.readFIF(from: Fixtures.url("Resolve/fsaverage-fiducials.fif"))
        let headFids = (nasion: fiducials.nasion!, lpa: fiducials.lpa!, rpa: fiducials.rpa!)
        var withFids = digitized
        let inverse = perturb.inverted()
        withFids.points.removeAll { [.nasion, .lpa, .rpa].contains($0.kind) }
        withFids.points += [
            .init(name: "Nasion", kind: .nasion, position: inverse.apply(headFids.nasion), channelIndex: nil),
            .init(name: "LPA", kind: .lpa, position: inverse.apply(headFids.lpa), channelIndex: nil),
            .init(name: "RPA", kind: .rpa, position: inverse.apply(headFids.rpa), channelIndex: nil)
        ]
        let guided = try SurfaceRegistration.coregister(electrodes: withFids, surface: surface, surfaceFiducials: headFids)
        let guidedErrors = zip(guided.transform.apply(withFids.eegPositions), truth.eegPositions).map { simd_length($0 - $1) }
        #expect(guidedErrors.max()! < 0.001, "guided max \(guidedErrors.max()!)")
    }

    @Test("template scalp fit recovers head scale")
    func templateFit() throws {
        let template = scalp(radius: 0.09)
        let templateIndex = SurfaceIndex(mesh: template)
        let templateElectrodes = electrodesOnScalp(templateIndex)
        // Subject head is 8% bigger and moved.
        let move = perturbation(angleDegrees: 5, shift: SIMD3(0.01, 0.02, 0.0), scale: 1.08)
        var subject = templateElectrodes.transformed(by: move)
        subject.frame = .head
        let fit = try SurfaceRegistration.fitTemplateScalp(
            template: template, templateFiducials: (templateElectrodes.nasion!, templateElectrodes.lpa!, templateElectrodes.rpa!),
            electrodes: subject)
        #expect(abs(fit.scale - 1.08) < 0.01, "scale \(fit.scale)")
        #expect(fit.templateToElectrodes.from == .mri && fit.templateToElectrodes.to == .head)
        let moved = template.transformed(by: fit.templateToElectrodes)
        let movedIndex = SurfaceIndex(mesh: moved)
        let residual = subject.eegPositions.map { movedIndex.closestPoint(to: $0).distance }
        #expect(residual.max()! < 1e-3, "max \(residual.max()!)")
    }

    @Test("projection puts points on the surface")
    func projection() {
        let mesh = scalp()
        let surface = SurfaceIndex(mesh: mesh)
        let points = StandardMontage.tenTwenty.positions(radiusMeters: 0.1).eegPositions
        let projected = SurfaceRegistration.project(points, onto: surface)
        for p in projected { #expect(surface.closestPoint(to: p).distance < 1e-9) }
    }
}
