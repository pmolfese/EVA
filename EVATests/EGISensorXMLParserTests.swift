//
//  EGISensorXMLParserTests.swift
//  EVATests
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

import Testing
import Foundation
@testable import EVA

struct EGISensorXMLParserTests {

    private static let coordinatesXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <sensorLayout xmlns="http://www.egi.com/coordinates_mff">
      <name>Test Layout</name>
      <sensors>
        <sensor><number>1</number><type>0</type><x>10</x><y>20</y><z>30</z></sensor>
        <sensor><number>2</number><type>0</type><x>-5</x><y>15</y><z>25</z></sensor>
        <sensor><number>3</number><type>1</type><x>0</x><y>0</y><z>0</z></sensor>
      </sensors>
    </sensorLayout>
    """

    @Test func parsesSensorsAndLayoutName() {
        let data = Data(Self.coordinatesXML.utf8)
        let parsed = try! #require(EGISensorXMLParser.parse(data: data, requiresZ: true))

        #expect(parsed.layoutName == "Test Layout")
        #expect(parsed.sensors.count == 3)

        let first = try! #require(parsed.sensors.first { $0.number == 1 })
        #expect(first.x == 10)
        #expect(first.y == 20)
        #expect(first.z == 30)
        #expect(first.type == 0)
    }

    @Test func returnsNilForMalformedXML() {
        #expect(EGISensorXMLParser.parse(data: Data("not xml".utf8), requiresZ: true) == nil)
    }

    @Test func parsesRealFixtureCoordinates() {
        // example_1 ships a full 256-channel coordinates.xml.
        let url = Fixtures.url("example_1.mff").appendingPathComponent("coordinates.xml")
        let data = try! Data(contentsOf: url)
        let parsed = try! #require(EGISensorXMLParser.parse(data: data, requiresZ: true))
        #expect(parsed.sensors.contains { $0.type == 0 })
        #expect(parsed.sensors.allSatisfy { $0.z != nil })
    }
}
