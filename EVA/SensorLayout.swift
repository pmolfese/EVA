//
//  SensorLayout.swift
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
//  Parses an EGI `sensorLayout.xml` file into 2D electrode positions for
//  drawing a top-down topographic map.
//
//  The sensorLayout coordinates are already a flat 2D projection (z = 0).
//  Type 0 sensors are EEG electrodes numbered 1...N and map directly onto the
//  signal's channels (channel index = number - 1). Type 1 (reference) and
//  type 2 (fiducials) entries are ignored. The nasion fiducial sits at the
//  maximum +y, so +y is anterior — we keep math coordinates with +y pointing
//  up (toward the nose) and let the view flip into screen space.
//

import Foundation

/// A single EEG electrode position, normalized into a unit circle centered on
/// the electrode centroid. `x` increases to the right, `y` increases toward
/// the nose (anterior).
struct SensorPosition: Identifiable, Sendable {
    let channelIndex: Int
    let x: Double
    let y: Double

    var id: Int { channelIndex }
}

struct SensorLayout: Sendable {
    let name: String
    let positions: [SensorPosition]

    /// Loads `sensorLayout.xml` from the package directory that contains the
    /// given signal `.bin` URL. Returns `nil` if the file is missing or
    /// unparseable.
    nonisolated static func load(fromPackageContaining signalURL: URL) -> SensorLayout? {
        let layoutURL = signalURL
            .deletingLastPathComponent()
            .appendingPathComponent("sensorLayout.xml")

        guard let data = try? Data(contentsOf: layoutURL) else {
            return nil
        }

        guard let parsed = EGISensorXMLParser.parse(data: data, requiresZ: false) else { return nil }

        let eegSensors = parsed.sensors.filter { $0.type == 0 }
        guard !eegSensors.isEmpty else {
            return nil
        }

        // Center on the EEG centroid, then scale by the largest radius so the
        // outermost electrode lands on the unit circle.
        let centroidX = eegSensors.map(\.x).reduce(0, +) / Double(eegSensors.count)
        let centroidY = eegSensors.map(\.y).reduce(0, +) / Double(eegSensors.count)

        let maxRadius = eegSensors
            .map { hypot($0.x - centroidX, $0.y - centroidY) }
            .max() ?? 1

        let scale = maxRadius > 0 ? maxRadius : 1

        let positions = eegSensors.map { sensor in
            SensorPosition(
                channelIndex: sensor.number - 1,
                x: (sensor.x - centroidX) / scale,
                y: (sensor.y - centroidY) / scale
            )
        }
        .sorted { $0.channelIndex < $1.channelIndex }

        return SensorLayout(name: parsed.layoutName, positions: positions)
    }
}
