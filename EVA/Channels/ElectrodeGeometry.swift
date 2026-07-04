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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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

    nonisolated static func load(fromPackageContaining signalURL: URL) -> ElectrodeGeometry? {
        let url = signalURL
            .deletingLastPathComponent()
            .appendingPathComponent("coordinates.xml")

        guard let data = try? Data(contentsOf: url) else { return nil }

        guard let parsed = EGISensorXMLParser.parse(data: data, requiresZ: true) else { return nil }

        var positions: [Int: SIMD3<Double>] = [:]
        for sensor in parsed.sensors where sensor.type == 0 {
            guard let z = sensor.z else { continue }
            let v = SIMD3<Double>(sensor.x, sensor.y, z)
            let length = simd_length(v)
            guard length > 0 else { continue }
            positions[sensor.number - 1] = v / length
        }

        guard !positions.isEmpty else { return nil }
        return ElectrodeGeometry(name: parsed.layoutName, positions: positions)
    }
}
