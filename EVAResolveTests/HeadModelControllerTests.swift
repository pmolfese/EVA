//
//  HeadModelControllerTests.swift
//  EVA Resolve
//
//  End-to-end head model on fsaverage (git-ignored local fixtures from
//  Tools/resolve-validate/make_fixtures.py): T1 → scalp, MNE fiducials, template
//  electrodes with scaling, fit, save as .evahead, reopen.
//

import Foundation
import Testing
import simd
@testable import EVAResolve

@MainActor
@Suite("Head model controller")
struct HeadModelControllerTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("EVATests/Fixtures/Resolve")

    @Test("fsaverage: scalp from T1, fiducials, template fit, package round trip")
    func endToEnd() async throws {
        let t1URL = Self.fixtures.appendingPathComponent("local/fsaverage-T1.nii.gz")
        let headURL = Self.fixtures.appendingPathComponent("local/fsaverage-head.fif")
        guard FileManager.default.fileExists(atPath: t1URL.path), FileManager.default.fileExists(atPath: headURL.path) else {
            print("fsaverage local fixtures missing; run make_fixtures.py — skipping")
            return
        }
        let controller = HeadModelController()

        // Scalp straight from the T1 (star-shaped extraction), compared with MNE's head surface.
        let volume = try NIfTIVolume.read(from: t1URL).canonicalized()
        #expect(volume.isCanonical && volume.nx == 256)
        let scalp = try #require(ScalpFromVolume.scalp(from: volume))
        let mneHead = try BEMSurface.readFIF(from: headURL)[0].mesh
        let mneIndex = SurfaceIndex(mesh: mneHead)
        // Sample the estimated scalp above the ears (z > centroid) where it is star-shaped;
        // it should sit within a few mm of MNE's watershed head surface.
        let upper = scalp.mesh.vertices.filter { $0.z > scalp.centroid.z }
        let distances = upper.map { mneIndex.closestPoint(to: $0).distance }.sorted()
        #expect(distances[distances.count / 2] < 0.003, "median scalp distance \(distances[distances.count / 2])")
        #expect(distances[Int(Double(distances.count) * 0.9)] < 0.008, "90th pct \(distances[Int(Double(distances.count) * 0.9)])")

        // Controller path: use MNE's scalp + fiducials + a scaled template montage.
        controller.loadScalp(from: headURL)
        controller.loadFiducials(from: Self.fixtures.appendingPathComponent("fsaverage-fiducials.fif"))
        #expect(controller.hasMRIFiducials)
        controller.icpAllowScale = true
        controller.useTemplate(.tenTen)
        let fit = try #require(controller.fitResult)
        #expect(fit.rms < 0.006, "rms \(fit.rms)")  // idealized sphere template on a real head
        #expect(controller.templateScale > 0.85 && controller.templateScale < 1.15, "scale \(controller.templateScale)")
        #expect(controller.headToMRI?.from == .head && controller.headToMRI?.to == .mri)
        // Snapped electrodes sit on the scalp.
        let snapped = try #require(controller.electrodesSnappedToScalp())
        for p in snapped.eegPositions { #expect(mneIndex.closestPoint(to: p).distance < 1e-6) }

        // Nudging moves the fit and refining brings it back.
        let before = fit.rms
        controller.nudge(rotationDegrees: SIMD3(0, 0, 5), translationMillimeters: SIMD3(3, 0, 0))
        #expect(controller.fitResult!.rms > before)
        controller.refineFromCurrentPose()
        #expect(controller.fitResult!.rms < 0.006)

        // Package round trip (without the T1 to keep it quick).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HeadModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("test.evahead")
        try controller.save(to: package)
        for name in ["manifest.json", "scalp-head.fif", "electrodes-dig.fif", "head-mri-trans.fif"] {
            #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent(name).path), "missing \(name)")
        }
        let reopened = HeadModelController()
        reopened.open(packageURL: package)
        #expect(reopened.electrodes?.eegNames == controller.electrodes?.eegNames)
        #expect(reopened.hasMRIFiducials)
        #expect(reopened.scalp?.vertices.count == mneHead.vertices.count)
        let a = try #require(reopened.headToMRI), b = try #require(controller.headToMRI)
        for c in 0..<4 { for r in 0..<4 { #expect(abs(a.matrix[c][r] - b.matrix[c][r]) < 1e-5) } }
        #expect(abs((reopened.fitResult?.rms ?? -1) - controller.fitResult!.rms) < 1e-6)
    }

    @Test("fiducial picking from world millimetres")
    func picking() {
        let controller = HeadModelController()
        controller.pickFiducial(worldMillimeters: SIMD3(0, 85, -30))
        #expect(controller.mriFiducials[.nasion] == SIMD3(0, 0.085, -0.03))
        #expect(controller.fiducialToPick == .lpa)
        controller.pickFiducial(worldMillimeters: SIMD3(-80, -20, -40))
        controller.pickFiducial(worldMillimeters: SIMD3(80, -20, -40))
        #expect(controller.hasMRIFiducials && controller.fiducialToPick == .rpa)
        controller.clearFiducials()
        #expect(!controller.hasMRIFiducials && controller.fiducialToPick == .nasion)
    }
}
