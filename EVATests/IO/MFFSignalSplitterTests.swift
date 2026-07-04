//
//  MFFSignalSplitterTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import EVA

final class MFFSignalSplitterTests: XCTestCase {
    func testSplitSlicesSamplesAndShiftsEvents() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let signal = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/source.mff/signal1.bin"),
            signalType: "EEG",
            numberOfChannels: 2,
            samplingRate: 10,
            duration: 1,
            recordingStartTime: start,
            events: [
                MFFEvent(id: "early", code: "A", beginTimeSeconds: 0.1, rawBeginTime: "", sourceFile: "test"),
                MFFEvent(id: "boundary", code: "B", beginTimeSeconds: 0.5, rawBeginTime: "", sourceFile: "test"),
                MFFEvent(id: "late", code: "C", beginTimeSeconds: 0.9, rawBeginTime: "", sourceFile: "test")
            ],
            data: [
                Array(0..<10).map(Float.init),
                Array(10..<20).map(Float.init)
            ],
            channelNames: ["E1", "E2"],
            impedancesKOhm: [1.2, 3.4]
        )

        let split = try MFFSignalSplitter.split(signal: signal, atSample: 5)

        XCTAssertEqual(split.boundarySample, 5)
        XCTAssertEqual(split.left.signal.data[0], [0, 1, 2, 3, 4])
        XCTAssertEqual(split.right.signal.data[0], [5, 6, 7, 8, 9])
        XCTAssertEqual(split.left.signal.events.map(\.code), ["A"])
        XCTAssertEqual(split.right.signal.events.map(\.code), ["B", "C"])
        XCTAssertEqual(split.right.signal.events.map(\.beginTimeSeconds), [0.0, 0.4])
        XCTAssertEqual(split.right.signal.recordingStartTime, start.addingTimeInterval(0.5))
        XCTAssertEqual(split.right.signal.channelNames, ["E1", "E2"])
        XCTAssertEqual(split.right.signal.impedancesKOhm, [1.2, 3.4])
        XCTAssertFalse(split.right.signal.isSegmented)
        XCTAssertFalse(split.right.signal.isAveraged)
    }

    func testSplitClampsBoundaryAwayFromEdges() throws {
        let signal = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/source.mff/signal1.bin"),
            signalType: "EEG",
            numberOfChannels: 1,
            samplingRate: 10,
            duration: 1,
            recordingStartTime: nil,
            events: [],
            data: [Array(0..<10).map(Float.init)]
        )

        let splitAtStart = try MFFSignalSplitter.split(signal: signal, atSample: 0)
        XCTAssertEqual(splitAtStart.boundarySample, 1)
        XCTAssertEqual(splitAtStart.left.sampleCount, 1)
        XCTAssertEqual(splitAtStart.right.sampleCount, 9)

        let splitAtEnd = try MFFSignalSplitter.split(signal: signal, atSample: 9)
        XCTAssertEqual(splitAtEnd.boundarySample, 9)
        XCTAssertEqual(splitAtEnd.left.sampleCount, 9)
        XCTAssertEqual(splitAtEnd.right.sampleCount, 1)
    }
}
