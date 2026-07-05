//
//  MFFAveragedRoundTripTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Regression: EVA-exported averaged/epoched MFF packages must contain a
//  categories.xml so EVA (and other readers) recognize them as averaged on
//  reopen — previously only epochs.xml was written and the file read as continuous.
//

import Testing
import Foundation
@testable import EVA

struct MFFAveragedRoundTripTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-avg-\(UUID().uuidString).mff")
    }

    @Test func averagedExportWritesCategoriesAndReadsBackAsAveraged() throws {
        // Start from a real continuous fixture, then export it as an average of
        // two categories (each with a >1 trial count).
        let source = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let sampleCount = source.data.first?.count ?? 0
        try #require(sampleCount >= 200)

        let half = sampleCount / 2
        let segments = [
            EpochSegment(startSample: 0, endSample: half - 1, stimulusOffsetSamples: 10,
                         category: "Target", sourceCode: "TAR", sourceTimeSeconds: 0,
                         colorIndex: 0, contributingEpochCount: 30),
            EpochSegment(startSample: half, endSample: sampleCount - 1, stimulusOffsetSamples: 10,
                         category: "Standard", sourceCode: "STD", sourceTimeSeconds: 0,
                         colorIndex: 1, contributingEpochCount: 42)
        ]

        let out = tempURL()
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(signal: source, segments: segments, kind: .averaged, to: out)

        // categories.xml must now exist.
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("categories.xml").path))

        // Reopen: EVA must see it as segmented + averaged with both categories.
        let readback = try MFFReader().loadSignal(from: out)
        #expect(readback.isSegmented)
        #expect(readback.isAveraged)
        #expect(readback.epochSegments.count == 2)
        #expect(Set(readback.epochSegments.map(\.category)) == ["Target", "Standard"])
    }
}
