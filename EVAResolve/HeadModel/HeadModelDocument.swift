//
//  HeadModelDocument.swift
//  EVA Resolve
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The `.evahead` package: a folder with a JSON manifest and the pieces written in
//  formats MNE-Python reads directly, so a head model built here is also usable
//  from Python without conversion:
//
//    manifest.json         this struct
//    t1.nii.gz             the (canonicalized) T1, if any
//    scalp-head.fif        the scalp as an MNE head surface (BEM surface id 4)
//    electrodes-dig.fif    electrodes + fiducials as an MNE digitization (own frame)
//    head-mri-trans.fif    the head→MRI transform (MNE -trans.fif)
//
//  Cached lead fields (R4) will sit next to these, keyed by montage hash.
//

import Foundation
import simd

nonisolated struct HeadModelDocument: Codable, Sendable {
    static let packageExtension = "evahead"
    static let manifestName = "manifest.json"

    var formatVersion = 1
    var t1FileName: String?
    var scalpFileName: String?
    var scalpSource: String
    var electrodesFileName: String?
    var electrodesSource: String
    var electrodeNames: [String]
    var electrodeFrame: CoordinateFrame
    var transformFileName: String?
    /// nasion / lpa / rpa → [x, y, z] metres, MRI RAS.
    var mriFiducials: [String: [Double]]
    var templateScale: Double

    func write(to packageURL: URL, t1: NIfTIVolume?, scalp: TriangleMesh?, electrodes: ElectrodePositions?, transform: HeadTransform?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: packageURL.appendingPathComponent(Self.manifestName))
        if let t1, let name = t1FileName { try t1.write(to: packageURL.appendingPathComponent(name)) }
        if let scalp, let name = scalpFileName {
            try BEMSurface.writeFIF([BEMSurface(kind: .head, sigma: 0.3, frame: .mri, mesh: scalp)], to: packageURL.appendingPathComponent(name))
        }
        if let electrodes, let name = electrodesFileName { try electrodes.writeFIF(to: packageURL.appendingPathComponent(name)) }
        if let transform, let name = transformFileName { try transform.writeFIF(to: packageURL.appendingPathComponent(name)) }
    }

    static func read(from packageURL: URL) throws -> (HeadModelDocument, NIfTIVolume?, TriangleMesh?, ElectrodePositions?, HeadTransform?) {
        let manifest = try JSONDecoder().decode(HeadModelDocument.self, from: Data(contentsOf: packageURL.appendingPathComponent(manifestName)))
        let t1 = try manifest.t1FileName.map { try NIfTIVolume.read(from: packageURL.appendingPathComponent($0)).canonicalized() }
        let scalp = try manifest.scalpFileName.map { try BEMSurface.readFIF(from: packageURL.appendingPathComponent($0)).first!.mesh }
        var electrodes = try manifest.electrodesFileName.map { try ElectrodePositions.readFIF(from: packageURL.appendingPathComponent($0), eegNames: manifest.electrodeNames) }
        electrodes?.name = manifest.electrodesSource
        let transform = try manifest.transformFileName.map { try HeadTransform.readFIF(from: packageURL.appendingPathComponent($0)) }
        return (manifest, t1, scalp, electrodes, transform)
    }
}
