//
//  EGISensorXMLParser.swift
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

import Foundation

nonisolated struct EGISensorXMLSensor: Sendable {
    var number: Int
    var type: Int
    var x: Double
    var y: Double
    var z: Double?
}

nonisolated enum EGISensorXMLParser {
    static func parse(data: Data, requiresZ: Bool) -> (layoutName: String, sensors: [EGISensorXMLSensor])? {
        let parser = XMLParser(data: data)
        let delegate = EGISensorXMLParserDelegate(requiresZ: requiresZ)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return (delegate.layoutName, delegate.sensors)
    }
}

private nonisolated final class EGISensorXMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var sensors: [EGISensorXMLSensor] = []
    private(set) var layoutName = ""

    private let requiresZ: Bool
    private var insideSensor = false
    private var insideTopName = false
    private var text = ""

    private var pendingNumber: Int?
    private var pendingType: Int?
    private var pendingX: Double?
    private var pendingY: Double?
    private var pendingZ: Double?

    init(requiresZ: Bool) {
        self.requiresZ = requiresZ
    }

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
            appendPendingSensor()
            insideSensor = false
        default:
            break
        }

        text = ""
    }

    private func appendPendingSensor() {
        guard let number = pendingNumber,
              let type = pendingType,
              let x = pendingX,
              let y = pendingY,
              !requiresZ || pendingZ != nil else {
            return
        }
        sensors.append(EGISensorXMLSensor(number: number, type: type, x: x, y: y, z: pendingZ))
    }
}
