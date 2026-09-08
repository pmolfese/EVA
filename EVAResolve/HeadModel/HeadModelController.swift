//
//  HeadModelController.swift
//  EVA Resolve
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  State for the Head Model window: a subject's T1 (or none), a scalp surface,
//  fiducials picked on the MRI, an electrode set, and the head→MRI transform
//  that coregistration produces. All geometry in metres, MRI RAS frame; the
//  volume's affine is millimetres and converted at the boundary.
//
//  Workflow (each step optional except electrodes):
//    MRI  → load a NIfTI; a quick star-shaped scalp is extracted (R3 will replace it)
//    Fiducials → click nasion / LPA / RPA on the slices (or take MNE's -fiducials.fif)
//    Electrodes → EGI coordinates.xml, digitizer file, MNE dig, or a template
//    Fit  → fiducial alignment, then ICP to the scalp; nudge; snap to scalp
//    Save → .evahead package; MNE -trans.fif / -dig.fif / -head.fif exports
//

import Foundation
import Observation
import simd

@MainActor
@Observable
final class HeadModelController {
    enum FiducialKind: String, CaseIterable, Identifiable, Codable {
        case nasion, lpa, rpa
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nasion: return "Nasion"
            case .lpa: return "LPA"
            case .rpa: return "RPA"
            }
        }
    }

    // MARK: MRI
    private(set) var t1: NIfTIVolume?
    private(set) var t1URL: URL?
    private(set) var t1Window: (min: Float, max: Float) = (0, 1)
    var brightness: Double = 1.0

    // MARK: Scalp
    private(set) var scalp: TriangleMesh?
    private(set) var scalpIndex: SurfaceIndex?
    private(set) var scalpSource = "none"

    // MARK: Fiducials on the MRI (metres, MRI RAS)
    var mriFiducials: [FiducialKind: SIMD3<Double>] = [:]
    var fiducialToPick: FiducialKind = .nasion

    // MARK: Electrodes (their own frame) and the fit
    private(set) var electrodes: ElectrodePositions?
    private(set) var electrodesSource = "none"
    private(set) var headToMRI: HeadTransform?
    private(set) var fitResult: SurfaceRegistration.ICPResult?
    private(set) var templateScale: Double = 1
    var icpAllowScale = false
    var icpTrimFraction = 0.05
    var statusMessage = ""

    var hasMRIFiducials: Bool { mriFiducials.count == 3 }

    /// Electrodes in the MRI frame under the current transform (or as loaded).
    var electrodesInMRI: [SIMD3<Double>] {
        guard let electrodes else { return [] }
        let positions = electrodes.eegPositions
        return headToMRI.map { $0.apply(positions) } ?? positions
    }

    var electrodeFiducialsInMRI: [FiducialKind: SIMD3<Double>] {
        guard let electrodes else { return [:] }
        var out: [FiducialKind: SIMD3<Double>] = [:]
        if let n = electrodes.nasion { out[.nasion] = headToMRI?.apply(n) ?? n }
        if let l = electrodes.lpa { out[.lpa] = headToMRI?.apply(l) ?? l }
        if let r = electrodes.rpa { out[.rpa] = headToMRI?.apply(r) ?? r }
        return out
    }

    /// Distance of every electrode to the scalp (metres), or nil without a scalp.
    var residuals: [Double]? {
        guard let scalpIndex else { return nil }
        return electrodesInMRI.map { scalpIndex.closestPoint(to: $0).distance }
    }

    // MARK: Loading

    func loadT1(from url: URL) {
        statusMessage = "Reading \(url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let volume = try NIfTIVolume.read(from: url).canonicalized()
                let window = volume.minMax()
                let scalp = ScalpFromVolume.scalp(from: volume)
                await MainActor.run {
                    guard let self else { return }
                    self.t1 = volume
                    self.t1URL = url
                    self.t1Window = window
                    self.mriFiducials = [:]
                    if let scalp {
                        self.setScalp(scalp.mesh, source: "estimated from \(url.lastPathComponent)")
                    }
                    self.statusMessage = "Loaded \(url.lastPathComponent): \(volume.nx)×\(volume.ny)×\(volume.nz), \(String(format: "%.2f", volume.voxelSizeMillimeters.x)) mm"
                    self.refit()
                }
            } catch {
                await MainActor.run { self?.statusMessage = error.localizedDescription }
            }
        }
    }

    func loadScalp(from url: URL) {
        do {
            let lower = url.lastPathComponent.lowercased()
            if lower.hasSuffix(".fif") {
                let surfaces = try BEMSurface.readFIF(from: url)
                let head = surfaces.first { $0.kind == .head } ?? surfaces[0]
                setScalp(head.mesh, source: url.lastPathComponent)
            } else if lower.hasSuffix(".gii") {
                let model = try GIFTIQuickLookReader.readDocument(from: url)
                let vertices = model.vertices.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) / 1000 }
                let triangles = model.triangles.map { SIMD3(Int32($0.a), Int32($0.b), Int32($0.c)) }
                setScalp(TriangleMesh(vertices: vertices, triangles: triangles), source: url.lastPathComponent)
            } else {
                statusMessage = "Scalp surfaces: MNE -head.fif / -bem.fif or GIFTI .gii"
                return
            }
            refit()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func setScalp(_ mesh: TriangleMesh, source: String) {
        scalp = mesh
        scalpIndex = SurfaceIndex(mesh: mesh)
        scalpSource = source
    }

    func loadFiducials(from url: URL) {
        do {
            let d = try Digitization.readFIF(from: url)
            if let n = d.nasion { mriFiducials[.nasion] = n }
            if let l = d.lpa { mriFiducials[.lpa] = l }
            if let r = d.rpa { mriFiducials[.rpa] = r }
            statusMessage = "Fiducials from \(url.lastPathComponent) (\(d.frame.displayName))"
            refit()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadElectrodes(from url: URL) {
        do {
            let lower = url.lastPathComponent.lowercased()
            let positions = lower.hasSuffix(".fif")
                ? try ElectrodePositions.readFIF(from: url)
                : try ElectrodePositions.read(from: url)
            electrodes = positions
            electrodesSource = url.lastPathComponent
            headToMRI = nil
            fitResult = nil
            templateScale = 1
            statusMessage = "\(positions.eeg.count) electrodes from \(url.lastPathComponent)" + (positions.hasFiducials ? " with fiducials" : " (no fiducials)")
            refit()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func useTemplate(_ montage: StandardMontage) {
        electrodes = montage.positions()
        electrodesSource = montage.displayName
        headToMRI = nil
        fitResult = nil
        templateScale = 1
        statusMessage = "\(electrodes!.eeg.count) template electrodes (\(montage.displayName))"
        refit()
    }

    // MARK: Fiducial picking

    /// Sets the fiducial being picked from a world position in **millimetres**
    /// (what the slice views produce from the volume affine).
    func pickFiducial(worldMillimeters p: SIMD3<Double>) {
        mriFiducials[fiducialToPick] = p / 1000
        if let next = FiducialKind.allCases.first(where: { mriFiducials[$0] == nil }) { fiducialToPick = next }
        refit()
    }

    func clearFiducials() {
        mriFiducials = [:]
        fiducialToPick = .nasion
        refit()
    }

    // MARK: Fitting

    /// Fiducial alignment when both sides have fiducials; ICP when a scalp exists.
    func refit() {
        guard let electrodes else { headToMRI = nil; fitResult = nil; return }
        let surfaceFids: (nasion: SIMD3<Double>, lpa: SIMD3<Double>, rpa: SIMD3<Double>)? =
            hasMRIFiducials ? (mriFiducials[.nasion]!, mriFiducials[.lpa]!, mriFiducials[.rpa]!) : nil
        if let scalpIndex {
            var options = SurfaceRegistration.ICPOptions()
            options.allowScale = icpAllowScale
            options.trimFraction = icpTrimFraction
            if let result = try? SurfaceRegistration.coregister(electrodes: electrodes, surface: scalpIndex, surfaceFiducials: surfaceFids, options: options) {
                headToMRI = result.transform
                fitResult = result
                templateScale = result.scale
                statusMessage = String(format: "Fit: RMS %.1f mm, median %.1f mm, max %.1f mm (%d iterations%@)",
                                       result.rms * 1000, result.median * 1000, result.maximum * 1000, result.iterations,
                                       result.converged ? "" : ", not converged")
                return
            }
        }
        if let f = surfaceFids, let n = electrodes.nasion, let l = electrodes.lpa, let r = electrodes.rpa,
           let fit = try? HeadTransform.fit(source: [n, l, r], target: [f.nasion, f.lpa, f.rpa], from: electrodes.frame, to: .mri) {
            headToMRI = fit.transform
            fitResult = nil
            statusMessage = String(format: "Fiducial alignment: RMS %.1f mm (no scalp for ICP)", fit.rmsError * 1000)
        } else if headToMRI == nil {
            headToMRI = HeadTransform.identity(from: electrodes.frame, to: .mri)
        }
    }

    /// Manual adjustment about the electrodes' centroid, degrees and millimetres.
    func nudge(rotationDegrees: SIMD3<Double> = .zero, translationMillimeters: SIMD3<Double> = .zero, scale: Double = 1) {
        guard let electrodes else { return }
        var current = headToMRI ?? HeadTransform.identity(from: electrodes.frame, to: .mri)
        let centre = electrodesInMRI.reduce(.zero, +) / Double(max(electrodesInMRI.count, 1))
        let rx = simd_quatd(angle: rotationDegrees.x * .pi / 180, axis: SIMD3(1, 0, 0))
        let ry = simd_quatd(angle: rotationDegrees.y * .pi / 180, axis: SIMD3(0, 1, 0))
        let rz = simd_quatd(angle: rotationDegrees.z * .pi / 180, axis: SIMD3(0, 0, 1))
        let r = simd_double3x3(rz * ry * rx) * scale
        // p' = R (p − c) + c + t
        let adjust = HeadTransform.rotation(r, translation: centre - r * centre + translationMillimeters / 1000, from: .mri, to: .mri)
        current = current.then(adjust)
        headToMRI = current
        templateScale *= scale
        if let scalpIndex {
            let d = scalpIndex.closestPoint(to: .zero).distance  // touch to keep the index alive
            _ = d
            let residuals = electrodesInMRI.map { scalpIndex.closestPoint(to: $0).distance }
            fitResult = SurfaceRegistration.ICPResult(transform: current, scale: templateScale, iterations: 0, distances: residuals, converged: true)
            statusMessage = String(format: "Adjusted: RMS %.1f mm", fitResult!.rms * 1000)
        }
    }

    /// Re-runs ICP from the current pose (after nudging).
    func refineFromCurrentPose() {
        guard let electrodes, let scalpIndex, let start = headToMRI else { return }
        var options = SurfaceRegistration.ICPOptions()
        options.allowScale = icpAllowScale
        options.trimFraction = icpTrimFraction
        let result = SurfaceRegistration.icp(points: electrodes.eegPositions + electrodes.headShape, surface: scalpIndex, initial: start, options: options)
        headToMRI = result.transform
        fitResult = result
        templateScale = result.scale
        statusMessage = String(format: "Refined: RMS %.1f mm, max %.1f mm", result.rms * 1000, result.maximum * 1000)
    }

    /// Electrodes projected onto the scalp, in the MRI frame (what a BEM consumes).
    func electrodesSnappedToScalp() -> ElectrodePositions? {
        guard let electrodes, let scalpIndex, let t = headToMRI else { return nil }
        var moved = electrodes.transformed(by: t)
        moved.points = moved.points.map { p in
            guard p.kind == .eeg else { return p }
            var q = p
            q.position = scalpIndex.closestPoint(to: p.position).point
            return q
        }
        return moved
    }

    // MARK: Exports

    func exportTrans(to url: URL) throws {
        guard let headToMRI else { throw HeadModelError.nothingToExport("transform") }
        try headToMRI.writeFIF(to: url)
    }

    func exportDig(to url: URL, inMRIFrame: Bool) throws {
        guard let electrodes else { throw HeadModelError.nothingToExport("electrodes") }
        if inMRIFrame, let t = headToMRI { try electrodes.transformed(by: t).writeFIF(to: url) }
        else { try electrodes.writeFIF(to: url) }
    }

    func exportScalp(to url: URL) throws {
        guard let scalp else { throw HeadModelError.nothingToExport("scalp surface") }
        try BEMSurface.writeFIF([BEMSurface(kind: .head, sigma: 0.3, frame: .mri, mesh: scalp)], to: url)
    }

    // MARK: Document

    func save(to packageURL: URL) throws {
        let document = HeadModelDocument(
            t1FileName: t1 != nil ? "t1.nii.gz" : nil,
            scalpFileName: scalp != nil ? "scalp-head.fif" : nil,
            scalpSource: scalpSource,
            electrodesFileName: electrodes != nil ? "electrodes-dig.fif" : nil,
            electrodesSource: electrodesSource,
            electrodeNames: electrodes?.eegNames ?? [],
            electrodeFrame: electrodes?.frame ?? .unknown,
            transformFileName: headToMRI != nil ? "head-mri-trans.fif" : nil,
            mriFiducials: mriFiducials.reduce(into: [:]) { $0[$1.key.rawValue] = [$1.value.x, $1.value.y, $1.value.z] },
            templateScale: templateScale)
        try document.write(to: packageURL, t1: t1, scalp: scalp, electrodes: electrodes, transform: headToMRI)
        statusMessage = "Saved \(packageURL.lastPathComponent)"
    }

    func open(packageURL: URL) {
        do {
            let (document, t1, scalp, electrodes, transform) = try HeadModelDocument.read(from: packageURL)
            self.t1 = t1
            self.t1URL = t1 != nil ? packageURL.appendingPathComponent(document.t1FileName ?? "") : nil
            self.t1Window = t1?.minMax() ?? (0, 1)
            if let scalp { setScalp(scalp, source: document.scalpSource) } else { self.scalp = nil; scalpIndex = nil; scalpSource = "none" }
            self.electrodes = electrodes
            self.electrodesSource = document.electrodesSource
            self.headToMRI = transform
            self.templateScale = document.templateScale
            self.mriFiducials = document.mriFiducials.reduce(into: [:]) { acc, kv in
                if let kind = FiducialKind(rawValue: kv.key), kv.value.count == 3 { acc[kind] = SIMD3(kv.value[0], kv.value[1], kv.value[2]) }
            }
            if let scalpIndex, let t = transform, let electrodes {
                let residuals = electrodes.eegPositions.map { scalpIndex.closestPoint(to: t.apply($0)).distance }
                fitResult = SurfaceRegistration.ICPResult(transform: t, scale: templateScale, iterations: 0, distances: residuals, converged: true)
            } else {
                fitResult = nil
            }
            statusMessage = "Opened \(packageURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    enum HeadModelError: LocalizedError {
        case nothingToExport(String)
        var errorDescription: String? {
            switch self { case .nothingToExport(let what): return "There is no \(what) to export yet." }
        }
    }
}
