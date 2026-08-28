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
//  Parses an EGI `sensorLayout.xml` file into 2D electrode positions for
//  drawing a top-down topographic map.
//
//  The sensorLayout coordinates are already a flat 2D projection (z = 0).
//  Type 0 sensors are EEG electrodes numbered 1...N and map directly onto the
//  signal's channels (channel index = number - 1). Type 1 is retained
//  separately as the acquisition reference: it is metadata even when the MFF
//  did not write a sample row for it. Type 2 (fiducial) entries are ignored.
//  EGI's flat projection puts
//  anterior/ocular electrodes at smaller raw y values, so we normalize into
//  math coordinates with +y pointing up (toward the nose) and let the view
//  flip into screen space.
//

import Foundation

/// A single EEG electrode position, normalized into a unit circle centered on
/// the electrode centroid. `x` increases to the right, `y` increases toward
/// the nose (anterior).
nonisolated struct SensorPosition: Identifiable, Sendable, Equatable, Codable, Hashable {
    let channelIndex: Int
    let x: Double
    let y: Double

    var id: Int { channelIndex }
}

/// The physical acquisition-reference entry declared by `sensorLayout.xml`.
/// It stays separate from `positions` because many MFFs omit the reference's
/// all-zero sample row. A derived average-referenced signal can restore that
/// row and opt into drawing this position without making a phantom channel
/// appear in the original recording.
nonisolated struct SensorReference: Sendable, Equatable {
    let channelIndex: Int
    let name: String
    let x: Double
    let y: Double
}

nonisolated struct SensorLayout: Sendable, Equatable {
    let name: String
    let positions: [SensorPosition]
    let reference: SensorReference?

    init(name: String, positions: [SensorPosition], reference: SensorReference? = nil) {
        self.name = name
        self.positions = positions
        self.reference = reference
    }

    /// Includes the acquisition reference only when the active signal really
    /// has a row at its declared index (recorded on disk or reconstructed for
    /// average reference).
    func includingReference(forChannelCount channelCount: Int) -> SensorLayout {
        guard let reference,
              reference.channelIndex >= 0,
              reference.channelIndex < channelCount,
              !positions.contains(where: { $0.channelIndex == reference.channelIndex }) else {
            return self
        }
        let position = SensorPosition(
            channelIndex: reference.channelIndex,
            x: reference.x,
            y: reference.y
        )
        return SensorLayout(
            name: name,
            positions: (positions + [position]).sorted { $0.channelIndex < $1.channelIndex },
            reference: reference
        )
    }

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
                y: (centroidY - sensor.y) / scale
            )
        }
        .sorted { $0.channelIndex < $1.channelIndex }

        let reference = parsed.sensors.first(where: { $0.type == 1 }).flatMap { sensor -> SensorReference? in
            guard sensor.number > 0 else { return nil }
            let fallbackName = "Reference (E\(sensor.number))"
            let trimmedName = sensor.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
            return SensorReference(
                channelIndex: sensor.number - 1,
                name: resolvedName,
                x: (sensor.x - centroidX) / scale,
                y: (centroidY - sensor.y) / scale
            )
        }

        return SensorLayout(name: parsed.layoutName, positions: positions, reference: reference)
    }
}
