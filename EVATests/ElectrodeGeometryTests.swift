//
//  ElectrodeGeometryTests.swift
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
import simd
@testable import EVA

struct ElectrodeGeometryTests {

    @Test func loadsUnitPositionsFromCoordinatesXML() {
        // example_1 ships a coordinates.xml with true 3D positions.
        let signalURL = Fixtures.url("example_1.mff").appendingPathComponent("signal1.bin")
        let geometry = try! #require(ElectrodeGeometry.load(fromPackageContaining: signalURL))

        #expect(!geometry.positions.isEmpty)
        #expect(!geometry.name.isEmpty)
        // Every position is projected onto the unit sphere.
        for (_, v) in geometry.positions {
            #expect(abs(simd_length(v) - 1) < 1e-9)
        }
    }

    @Test func returnsNilWhenCoordinatesMissing() {
        // example_4 has no coordinates.xml.
        let signalURL = Fixtures.url("example_4.mff").appendingPathComponent("signal1.bin")
        #expect(ElectrodeGeometry.load(fromPackageContaining: signalURL) == nil)
    }
}
