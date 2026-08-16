//
//  BESAImportTests.swift
//  EVATests
//

import XCTest
@testable import EVA

final class BESAImportTests: XCTestCase {
    func testAVRUsesChannelRowsScaleRateAndLabels() throws {
        let url = try write(
            """
            Npts=3 TSB=0 DI=4 SB=2 Nchan=2
            Fz Cz
            2 4 6
            -2 -4 -6
            """,
            extension: "avr"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let signal = try SignalImportReader.load(from: url).signal
        XCTAssertEqual(signal.numberOfChannels, 2)
        XCTAssertEqual(signal.channelNames, ["Fz", "Cz"])
        XCTAssertEqual(signal.samplingRate, 250, accuracy: 0.000_001)
        XCTAssertEqual(signal.duration, 0.012, accuracy: 0.000_001)
        XCTAssertEqual(signal.data[0], [1, 2, 3])
        XCTAssertEqual(signal.data[1], [-1, -2, -3])
    }

    func testMULUsesSampleRowsScaleRateAndLabels() throws {
        let url = try write(
            """
            TimePoints=3 Channels=2 SamplingInterval[ms]=2 Bins/uV=4
            F3 F4
            4 8
            12 16
            -4 -8
            """,
            extension: "mul"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let signal = try SignalImportReader.load(from: url).signal
        XCTAssertEqual(signal.channelNames, ["F3", "F4"])
        XCTAssertEqual(signal.samplingRate, 500, accuracy: 0.000_001)
        XCTAssertEqual(signal.duration, 0.006, accuracy: 0.000_001)
        XCTAssertEqual(signal.data[0], [1, 3, -1])
        XCTAssertEqual(signal.data[1], [2, 4, -2])
    }

    func testRaggedRowsAreRejectedForBothOrientations() throws {
        let avr = try write(
            """
            Npts=3 DI=4 SB=1 Nchan=2
            Fz Cz
            1 2 3
            4 5
            """,
            extension: "avr"
        )
        defer { try? FileManager.default.removeItem(at: avr.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: avr))

        let mul = try write(
            """
            SamplingInterval[ms]=2 Bins/uV=1
            Fz Cz
            1 2
            3
            """,
            extension: "mul"
        )
        defer { try? FileManager.default.removeItem(at: mul.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: mul)) { error in
            XCTAssertTrue(error.localizedDescription.contains("MUL row 2"))
        }
    }

    func testZeroScaleAndNonFiniteInputAreRejected() throws {
        let zeroScale = try write(
            """
            Npts=2 DI=4 SB=0 Nchan=1
            Fz
            1 2
            """,
            extension: "avr"
        )
        defer { try? FileManager.default.removeItem(at: zeroScale.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: zeroScale))

        let nonFinite = try write(
            """
            SamplingInterval[ms]=2 Bins/uV=1
            Fz
            NaN
            """,
            extension: "mul"
        )
        defer { try? FileManager.default.removeItem(at: nonFinite.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: nonFinite))
    }

    private func write(_ contents: String, extension fileExtension: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-besa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("sample.\(fileExtension)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
