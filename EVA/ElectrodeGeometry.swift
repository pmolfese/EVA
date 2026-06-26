//
//  ElectrodeGeometry.swift
//  SummerEEGDemo
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

        let parser = XMLParser(data: data)
        let delegate = CoordinatesParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        var positions: [Int: SIMD3<Double>] = [:]
        for sensor in delegate.sensors where sensor.type == 0 {
            let v = SIMD3<Double>(sensor.x, sensor.y, sensor.z)
            let length = simd_length(v)
            guard length > 0 else { continue }
            positions[sensor.number - 1] = v / length
        }

        guard !positions.isEmpty else { return nil }
        return ElectrodeGeometry(name: delegate.layoutName, positions: positions)
    }
}

private struct RawSensor3D {
    var number: Int
    var type: Int
    var x: Double
    var y: Double
    var z: Double
}

private nonisolated final class CoordinatesParserDelegate: NSObject, XMLParserDelegate {
    private(set) var sensors: [RawSensor3D] = []
    private(set) var layoutName = ""

    private var insideSensor = false
    private var insideTopName = false
    private var text = ""

    private var pendingNumber: Int?
    private var pendingType: Int?
    private var pendingX: Double?
    private var pendingY: Double?
    private var pendingZ: Double?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "sensor":
            insideSensor = true
            pendingNumber = nil
            pendingType = nil
            pendingX = nil
            pendingY = nil
            pendingZ = nil
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
        case "number": pendingNumber = Int(trimmed)
        case "type": pendingType = Int(trimmed)
        case "x": pendingX = Double(trimmed)
        case "y": pendingY = Double(trimmed)
        case "z": pendingZ = Double(trimmed)
        case "name" where insideTopName:
            if layoutName.isEmpty { layoutName = trimmed }
            insideTopName = false
        case "sensor":
            if let number = pendingNumber, let type = pendingType,
               let x = pendingX, let y = pendingY, let z = pendingZ {
                sensors.append(RawSensor3D(number: number, type: type, x: x, y: y, z: z))
            }
            insideSensor = false
        default:
            break
        }

        text = ""
    }
}
