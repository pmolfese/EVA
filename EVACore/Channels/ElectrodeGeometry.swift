//
//  ElectrodeGeometry.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Parses an EGI `coordinates.xml` file into 3D electrode positions (unit
//  vectors on a sphere), used for spherical-spline channel interpolation.
//  Unlike `sensorLayout.xml` (a flat 2D projection with z = 0), coordinates.xml
//  carries the true 3D head positions.
//

import Foundation
import simd

nonisolated struct ElectrodeGeometry: Sendable {
    let name: String
    /// channelIndex (number − 1) → unit position vector on the sphere.
    let positions: [Int: SIMD3<Double>]
    /// Optional sensor names from `coordinates.xml`, keyed like `positions`.
    let channelNames: [Int: String]

    nonisolated init(
        name: String,
        positions: [Int: SIMD3<Double>],
        channelNames: [Int: String] = [:]
    ) {
        self.name = name
        self.positions = positions
        self.channelNames = channelNames
    }

    nonisolated static func load(fromPackageContaining signalURL: URL) -> ElectrodeGeometry? {
        let url = signalURL
            .deletingLastPathComponent()
            .appendingPathComponent("coordinates.xml")

        return load(fromCoordinatesXML: url)
    }

    /// Loads either a standalone coordinates.xml or an MFF/package directory
    /// containing one. This is shared by EVA and EVASimulate so both interpret
    /// sensor numbering and axes identically.
    nonisolated static func load(from path: URL) -> ElectrodeGeometry? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return load(fromCoordinatesXML: path.appendingPathComponent("coordinates.xml"))
        }
        return load(fromCoordinatesXML: path)
    }

    nonisolated static func load(fromCoordinatesXML url: URL) -> ElectrodeGeometry? {

        guard let data = try? Data(contentsOf: url) else { return nil }

        guard let parsed = EGISensorXMLParser.parse(data: data, requiresZ: true) else { return nil }

        var positions: [Int: SIMD3<Double>] = [:]
        var channelNames: [Int: String] = [:]
        for sensor in parsed.sensors where sensor.type == 0 {
            guard let z = sensor.z else { continue }
            let v = SIMD3<Double>(sensor.x, sensor.y, z)
            let length = simd_length(v)
            guard length > 0 else { continue }
            positions[sensor.number - 1] = v / length
            if let name = sensor.name, !name.isEmpty {
                channelNames[sensor.number - 1] = name
            }
        }

        guard !positions.isEmpty else { return nil }
        return ElectrodeGeometry(
            name: parsed.layoutName, positions: positions, channelNames: channelNames
        )
    }
}
