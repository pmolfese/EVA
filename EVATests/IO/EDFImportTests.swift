//
//  EDFImportTests.swift
//  EVATests
//

import XCTest
@testable import EVA

final class EDFImportTests: XCTestCase {
    private struct SignalSpec {
        var label: String
        var unit = "uV"
        var physicalMin = -100.0
        var physicalMax = 100.0
        var digitalMin = -32_768.0
        var digitalMax = 32_767.0
        var samplesPerRecord: Int
        var records: [[Int16]] = []
        var annotationRecords: [[UInt8]] = []
    }

    func testCalibratedExtremaNegativeValuesAndUnknownRecordCount() throws {
        let url = try writeEDF(
            recordCountField: "-1",
            signals: [SignalSpec(
                label: "Fz", physicalMin: -200, physicalMax: 200,
                digitalMin: -2_000, digitalMax: 2_000, samplesPerRecord: 2,
                records: [[-2_000, 2_000], [-1_000, 0]]
            )]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let signal = try SignalImportReader.load(from: url).signal
        XCTAssertEqual(signal.numberOfChannels, 1)
        XCTAssertEqual(signal.channelNames, ["Fz"])
        XCTAssertEqual(signal.samplingRate, 2, accuracy: 0.000_001)
        XCTAssertEqual(signal.duration, 2, accuracy: 0.000_001)
        XCTAssertEqual(signal.data[0].count, 4)
        XCTAssertEqual(signal.data[0][0], -200, accuracy: 0.000_01)
        XCTAssertEqual(signal.data[0][1], 200, accuracy: 0.000_01)
        XCTAssertEqual(signal.data[0][2], -100, accuracy: 0.000_01)
        XCTAssertEqual(signal.data[0][3], 0, accuracy: 0.000_01)
    }

    func testEDFPlusAnnotationsPreserveTimingAndIgnoreTimekeepingTAL() throws {
        let tal = Array("+0\u{14}\u{14}\u{0}+0.25\u{15}0.5\u{14}Stimulus/S 1\u{14}\u{0}".utf8)
        let url = try writeEDF(signals: [
            SignalSpec(label: "Cz", samplesPerRecord: 2, records: [[0, 1]]),
            SignalSpec(label: "EDF Annotations", samplesPerRecord: 32, annotationRecords: [tal]),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let signal = try SignalImportReader.load(from: url).signal
        XCTAssertEqual(signal.numberOfChannels, 1)
        XCTAssertEqual(signal.events.count, 1)
        XCTAssertEqual(signal.events[0].code, "Stimulus/S 1")
        XCTAssertEqual(signal.events[0].label, "Stimulus/S 1")
        XCTAssertEqual(signal.events[0].beginTimeSeconds, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(signal.events[0].durationSeconds ?? -1, 0.5, accuracy: 0.000_001)
    }

    func testTruncatedRecordAndInvalidCalibrationAreRejected() throws {
        var truncated = try makeEDF(signals: [
            SignalSpec(label: "Fz", samplesPerRecord: 2, records: [[1, 2]])
        ])
        truncated.removeLast()
        let truncatedURL = try write(truncated, named: "truncated.edf")
        defer { try? FileManager.default.removeItem(at: truncatedURL.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: truncatedURL))

        let invalidURL = try writeEDF(signals: [
            SignalSpec(
                label: "Fz", digitalMin: 10, digitalMax: 10,
                samplesPerRecord: 2, records: [[10, 10]]
            )
        ])
        defer { try? FileManager.default.removeItem(at: invalidURL.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: invalidURL))
    }

    func testMixedDataChannelRatesAreRejected() throws {
        let url = try writeEDF(signals: [
            SignalSpec(label: "Fz", samplesPerRecord: 2, records: [[1, 2]]),
            SignalSpec(label: "Cz", samplesPerRecord: 1, records: [[3]]),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertThrowsError(try SignalImportReader.load(from: url))
    }

    private func writeEDF(
        recordCountField: String = "1",
        signals: [SignalSpec]
    ) throws -> URL {
        try write(makeEDF(recordCountField: recordCountField, signals: signals), named: "sample.edf")
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-edf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeEDF(
        recordCountField: String = "1",
        signals: [SignalSpec]
    ) throws -> Data {
        let actualRecords = signals.map { max($0.records.count, $0.annotationRecords.count) }.max() ?? 0
        let headerBytes = 256 + signals.count * 256
        var data = Data()
        append("0", width: 8, to: &data)
        append("X", width: 80, to: &data)
        append("Startdate X", width: 80, to: &data)
        append("01.01.25", width: 8, to: &data)
        append("00.00.00", width: 8, to: &data)
        append(String(headerBytes), width: 8, to: &data)
        append("EDF+C", width: 44, to: &data)
        append(recordCountField, width: 8, to: &data)
        append("1", width: 8, to: &data)
        append(String(signals.count), width: 4, to: &data)

        for signal in signals { append(signal.label, width: 16, to: &data) }
        for _ in signals { append("", width: 80, to: &data) }
        for signal in signals { append(signal.unit, width: 8, to: &data) }
        for signal in signals { append(String(signal.physicalMin), width: 8, to: &data) }
        for signal in signals { append(String(signal.physicalMax), width: 8, to: &data) }
        for signal in signals { append(String(signal.digitalMin), width: 8, to: &data) }
        for signal in signals { append(String(signal.digitalMax), width: 8, to: &data) }
        for _ in signals { append("", width: 80, to: &data) }
        for signal in signals { append(String(signal.samplesPerRecord), width: 8, to: &data) }
        for _ in signals { append("", width: 32, to: &data) }
        XCTAssertEqual(data.count, headerBytes)

        for record in 0..<actualRecords {
            for signal in signals {
                if signal.label.lowercased().contains("edf annotations") {
                    let source = signal.annotationRecords[record]
                    let byteCount = signal.samplesPerRecord * 2
                    data.append(contentsOf: source.prefix(byteCount))
                    if source.count < byteCount {
                        data.append(contentsOf: repeatElement(UInt8(0), count: byteCount - source.count))
                    }
                } else {
                    for value in signal.records[record] { append(value, to: &data) }
                }
            }
        }
        return data
    }

    private func append(_ string: String, width: Int, to data: inout Data) {
        let bytes = Array(string.utf8.prefix(width))
        data.append(contentsOf: bytes)
        data.append(contentsOf: repeatElement(UInt8(ascii: " "), count: width - bytes.count))
    }

    private func append(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
