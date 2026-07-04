//
//  PhysioTextImporterTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct PhysioTextImporterTests {

    @Test func parsesGEStyleHeaderlessSingleColumn() throws {
        // GE scanner PPG/RESP logs: one integer sample per line, no header, no timebase.
        let text = " -442\n -428\n -414\n -420\n -414\n"
        let result = try PhysioTextImporter.parse(text: text, suggestedName: "PPG")

        #expect(result.channels.count == 1)
        #expect(result.channels[0].name == "PPG")
        #expect(result.channels[0].samples == [-442, -428, -414, -420, -414])
        #expect(result.detectedSamplingRateHz == nil)
    }

    @Test func channelNameHeuristicMatchesKnownGEPrefixes() {
        #expect(PhysioTextImporter.channelNameHeuristic(fromFileName: "PPGData_hypermepi_1003202313_25_14_568") == "PPG")
        #expect(PhysioTextImporter.channelNameHeuristic(fromFileName: "RESPData_hypermepi_1003202313_25_14_568") == "RESP")
        #expect(PhysioTextImporter.channelNameHeuristic(fromFileName: "mystery.txt") == "mystery")
    }

    @Test func parsesHeaderedMultiColumnWithoutTimeAxis() throws {
        let text = """
        ECG,EMG
        1.0,2.0
        1.5,2.5
        2.0,3.0
        """
        let result = try PhysioTextImporter.parse(text: text, suggestedName: "Physio")

        #expect(result.channels.map(\.name) == ["ECG", "EMG"])
        #expect(result.channels[0].samples == [1.0, 1.5, 2.0])
        #expect(result.channels[1].samples == [2.0, 2.5, 3.0])
        #expect(result.detectedSamplingRateHz == nil)
    }

    @Test func detectsSamplingRateFromLeadingTimeColumn() throws {
        // A uniform 0.01 s time column (100 Hz) followed by one data column.
        let rows = (0..<50).map { i in "\(Double(i) * 0.01)\t\(100 + i)" }
        let text = (["Time\tECG"] + rows).joined(separator: "\n")
        let result = try PhysioTextImporter.parse(text: text, suggestedName: "Physio")

        #expect(result.channels.count == 1)
        #expect(result.channels[0].name == "ECG")
        #expect(result.channels[0].samples.count == 50)
        let rate = try #require(result.detectedSamplingRateHz)
        #expect(abs(rate - 100) < 0.5)
    }

    @Test func sampleIndexTimeColumnDoesNotImplyRate() throws {
        // A plain 0,1,2,... sample counter shouldn't be mistaken for a rate.
        let rows = (0..<20).map { i in "\(i),\(i * 2)" }
        let text = rows.joined(separator: "\n")
        let result = try PhysioTextImporter.parse(text: text, suggestedName: "Physio")

        #expect(result.channels.count == 1)
        #expect(result.detectedSamplingRateHz == nil)
    }

    @Test func raggedRowsThrow() {
        let text = "1,2\n3,4,5\n"
        #expect(throws: PhysioTextImportError.self) {
            try PhysioTextImporter.parse(text: text, suggestedName: "X")
        }
    }

    @Test func emptyFileThrows() {
        #expect(throws: PhysioTextImportError.self) {
            try PhysioTextImporter.parse(text: "\n\n  \n", suggestedName: "X")
        }
    }
}
