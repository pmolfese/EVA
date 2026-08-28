//
//  SensorLayoutTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Testing
import Foundation
@testable import EVA

struct SensorLayoutTests {

    @Test func loadsAndNormalizesToUnitCircle() {
        let signalURL = Fixtures.url("example_1.mff").appendingPathComponent("signal1.bin")
        let layout = try! #require(SensorLayout.load(fromPackageContaining: signalURL))

        #expect(!layout.positions.isEmpty)

        // All electrodes fall within (or on) the unit circle after normalization,
        // and the outermost sits at ~radius 1.
        let radii = layout.positions.map { hypot($0.x, $0.y) }
        #expect((radii.max() ?? 0) <= 1 + 1e-9)
        #expect(abs((radii.max() ?? 0) - 1) < 1e-9)

        // Positions are sorted by channel index.
        let indices = layout.positions.map(\.channelIndex)
        #expect(indices == indices.sorted())
    }

    @Test func returnsNilWhenLayoutMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-package-\(UUID().uuidString)")
            .appendingPathComponent("signal1.bin")
        #expect(SensorLayout.load(fromPackageContaining: missing) == nil)
    }

    @Test func retainsReferenceMetadataWithoutAddingAPhantomChannel() throws {
        let signalURL = Fixtures.url("example_2.mff").appendingPathComponent("signal1.bin")
        let layout = try #require(SensorLayout.load(fromPackageContaining: signalURL))
        let reference = try #require(layout.reference)

        #expect(reference.name == "VREF")
        #expect(!layout.positions.contains { $0.channelIndex == reference.channelIndex })

        let expanded = layout.includingReference(forChannelCount: reference.channelIndex + 1)
        #expect(expanded.positions.contains { $0.channelIndex == reference.channelIndex })
    }
}
