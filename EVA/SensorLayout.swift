//
//  SensorLayout.swift
//  EVA
//
//  Copyright (C) 2026 Peter Molfese
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

        let parser = XMLParser(data: data)
        let delegate = SensorLayoutParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            return nil
        }

        let eegSensors = delegate.sensors.filter { $0.type == 0 }
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

        return SensorLayout(name: delegate.layoutName, positions: positions)
    }
}

private struct RawSensor {
    var number: Int
    var type: Int
    var x: Double
    var y: Double
}

private nonisolated final class SensorLayoutParserDelegate: NSObject, XMLParserDelegate {
    private(set) var sensors: [RawSensor] = []
    private(set) var layoutName = ""

    private var currentElement = ""
    private var insideSensor = false
    private var insideTopName = false
    private var text = ""

    private var pendingNumber: Int?
    private var pendingType: Int?
    private var pendingX: Double?
    private var pendingY: Double?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        text = ""

        switch elementName {
        case "sensor":
            insideSensor = true
            pendingNumber = nil
            pendingType = nil
            pendingX = nil
            pendingY = nil
        case "name" where !insideSensor:
            insideTopName = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "number":
            pendingNumber = Int(trimmed)
        case "type":
            pendingType = Int(trimmed)
        case "x":
            pendingX = Double(trimmed)
        case "y":
            pendingY = Double(trimmed)
        case "name" where insideTopName:
            if layoutName.isEmpty {
                layoutName = trimmed
            }
            insideTopName = false
        case "sensor":
            if let number = pendingNumber,
               let type = pendingType,
               let x = pendingX,
               let y = pendingY {
                sensors.append(RawSensor(number: number, type: type, x: x, y: y))
            }
            insideSensor = false
        default:
            break
        }

        text = ""
    }
}
