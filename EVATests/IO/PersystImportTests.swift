//
//  PersystImportTests.swift
//  EVATests
//

import XCTest
@testable import EVA

final class PersystImportTests: XCTestCase {
    func testInt16CalibrationChannelOrderAndComments() throws {
        let fixture = try makeFixture(dataType: 0, calibration: 0.5) { data in
            for value: Int16 in [2, 4, -2, -4] { self.append(value, to: &data) }
        }
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let signal = try SignalImportReader.load(from: fixture).signal
        XCTAssertEqual(signal.numberOfChannels, 2)
        XCTAssertEqual(signal.channelNames, ["C4", "C3"])
        XCTAssertEqual(signal.samplingRate, 100, accuracy: 0.000_001)
        XCTAssertEqual(signal.duration, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(signal.data[0], [1, -1])
        XCTAssertEqual(signal.data[1], [2, -2])
        XCTAssertEqual(signal.events.count, 1)
        XCTAssertEqual(signal.events[0].code, "Seizure")
        XCTAssertEqual(signal.events[0].beginTimeSeconds, 0.01, accuracy: 0.000_001)
    }

    func testInt32DataTypeSevenIsDecodedAsSignedInteger() throws {
        let fixture = try makeFixture(dataType: 7, calibration: 0.25) { data in
            for value: Int32 in [400_000, -400_000, 8, -8] { self.append(value, to: &data) }
        }
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let signal = try SignalImportReader.load(from: fixture).signal
        XCTAssertEqual(signal.data[0], [100_000, 2])
        XCTAssertEqual(signal.data[1], [-100_000, -2])
    }

    func testPartialFrameAndUnsupportedTypeAreRejected() throws {
        let partial = try makeFixture(dataType: 0, calibration: 1) { data in
            self.append(Int16(1), to: &data)
            self.append(Int16(2), to: &data)
            self.append(Int16(3), to: &data)
        }
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: partial))

        let unsupported = try makeFixture(dataType: 3, calibration: 1) { data in
            self.append(Int16(1), to: &data)
            self.append(Int16(2), to: &data)
        }
        defer { try? FileManager.default.removeItem(at: unsupported.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: unsupported)) { error in
            XCTAssertTrue(error.localizedDescription.contains("DataType 3"))
        }
    }

    private func makeFixture(
        dataType: Int,
        calibration: Double,
        writeData: (inout Data) -> Void
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-persyst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let layURL = folder.appendingPathComponent("sample.lay")
        let datURL = folder.appendingPathComponent("sample.dat")
        try """
        [FileInfo]
        File=sample.dat
        WaveformCount=2
        SamplingRate=100
        Calibration=\(calibration)
        DataType=\(dataType)

        [ChannelMap]
        C4-REF=1
        C3-REF=0

        [Comments]
        0.01,0,0,0,Seizure
        """.write(to: layURL, atomically: true, encoding: .utf8)
        var data = Data()
        writeData(&data)
        try data.write(to: datURL)
        return layURL
    }

    private func append(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func append(_ value: Int32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
