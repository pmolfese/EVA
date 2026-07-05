//
//  GrandAverageReaderTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Grand-average detection: EGI grand averages mark every segment
//  <name>Average</name> with #seg == 1 (each contributor is one subject/group),
//  so the reader must key off the Average name, not the trial count.
//

import Testing
import Foundation
@testable import EVA

struct GrandAverageReaderTests {

    /// Builds a valid averaged package with the writer, then overwrites its
    /// categories.xml with a grand-average shape: one condition contributed by
    /// two subject/group averages (two segs), each #seg == 1.
    @Test func detectsGrandAverageFromAverageSegNameAndRepeatedCategory() throws {
        let source = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let sampleCount = source.data.first?.count ?? 0
        try #require(sampleCount >= 200)

        let half = sampleCount / 2
        let segments = [
            EpochSegment(startSample: 0, endSample: half - 1, stimulusOffsetSamples: 5,
                         category: "A", sourceCode: "A", sourceTimeSeconds: 0,
                         colorIndex: 0, contributingEpochCount: 1),
            EpochSegment(startSample: half, endSample: sampleCount - 1, stimulusOffsetSamples: 5,
                         category: "B", sourceCode: "B", sourceTimeSeconds: 0,
                         colorIndex: 1, contributingEpochCount: 1)
        ]

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-ga-\(UUID().uuidString).mff")
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(signal: source, segments: segments, kind: .averaged, to: out)

        // Reuse the writer's epoch timeline for the two blocks.
        let epochs = try epochTimes(in: out)
        try #require(epochs.count == 2)

        // Grand average: one category "Condition", two subject/group Average segs.
        let categories = """
        <?xml version="1.0" encoding="UTF-8"?>
        <categories xmlns="http://www.egi.com/categories_mff">
          <cat>
            <name>Condition</name>
            <segments>
              <seg status="unedited">
                <name>Average</name>
                <beginTime>\(epochs[0].begin)</beginTime>
                <endTime>\(epochs[0].end)</endTime>
                <evtBegin>\(epochs[0].begin)</evtBegin>
                <keys><key><keyCode>#seg</keyCode><data dataType="long">1</data></key>
                      <key><keyCode>subj</keyCode><data dataType="person">GroupA</data></key></keys>
              </seg>
              <seg status="unedited">
                <name>Average</name>
                <beginTime>\(epochs[1].begin)</beginTime>
                <endTime>\(epochs[1].end)</endTime>
                <evtBegin>\(epochs[1].begin)</evtBegin>
                <keys><key><keyCode>#seg</keyCode><data dataType="long">1</data></key>
                      <key><keyCode>subj</keyCode><data dataType="person">GroupB</data></key></keys>
              </seg>
            </segments>
          </cat>
        </categories>
        """
        try categories.write(to: out.appendingPathComponent("categories.xml"), atomically: true, encoding: .utf8)

        let readback = try MFFReader().loadSignal(from: out)
        #expect(readback.isSegmented)
        #expect(readback.isAveraged)       // Average seg name, despite #seg == 1
        #expect(readback.isGrandAverage)   // repeated category / subject keys
        #expect(readback.epochSegments.count == 2)
        #expect(readback.epochSegments.allSatisfy { $0.category == "Condition" })
        // subject is threaded from categories.xml subj keys onto each segment.
        #expect(Set(readback.epochSegments.compactMap(\.subject)) == ["GroupA", "GroupB"])
        #expect(readback.hasMultipleSubjects)
    }

    private struct EpochTime { let begin: Int; let end: Int }

    private func epochTimes(in package: URL) throws -> [EpochTime] {
        let data = try Data(contentsOf: package.appendingPathComponent("epochs.xml"))
        let doc = try XMLDocument(data: data)
        let epochs = try doc.nodes(forXPath: "//epoch")
        return epochs.compactMap { node in
            guard let el = node as? XMLElement,
                  let begin = el.elements(forName: "beginTime").first?.stringValue.flatMap({ Int($0) }),
                  let end = el.elements(forName: "endTime").first?.stringValue.flatMap({ Int($0) }) else { return nil }
            return EpochTime(begin: begin, end: end)
        }
    }
}
