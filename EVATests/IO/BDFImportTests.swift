//
//  BDFImportTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation
import XCTest
@testable import EVA

final class BDFImportTests: XCTestCase {
    private struct Channel {
        var label: String
        var unit = "uV"
        var physicalMin = "-8388608"
        var physicalMax = "8388607"
        var digitalMin = "-8388608"
        var digitalMax = "8388607"
        var records: [[Int32]] = []
        var annotations: [String] = []
        var annotationSamples = 64
        var count: Int { records.first?.count ?? annotationSamples }
    }

    func testSignatureAnd24BitSignExtension() throws {
        let url = try write(make(channels: [Channel(label: "A1", records: [
            [-8_388_608, -65_537, -1, 0, 1, 65_536, 8_388_607]
        ])]), name: "signed.BDF")
        defer { remove(url) }
        XCTAssertTrue(SignalImportReader.isSupportedRecordingURL(url))
        let signal = try SignalImportReader.load(from: url).signal
        XCTAssertEqual(signal.data[0], [-8_388_608, -65_537, -1, 0, 1, 65_536, 8_388_607])
        XCTAssertEqual(signal.channelNames, ["A1"])
        XCTAssertEqual(signal.samplingRate, 7)
        XCTAssertEqual(signal.duration, 1)
        XCTAssertNotNil(signal.recordingStartTime)
        XCTAssertEqual(signal.referenceState, .unknown)
        var bad = try Data(contentsOf: url)
        bad[0] = 0
        try bad.write(to: url)
        XCTAssertThrowsError(try SignalImportReader.load(from: url))
    }

    func testCalibrationOffsetsUnitsAndNegativeGain() throws {
        let url = try write(make(channels: [
            Channel(label: "Fz", unit: "mV", physicalMin: "1", physicalMax: "3",
                    digitalMin: "-100", digitalMax: "100", records: [[-100, 0, 100]]),
            Channel(label: "Cz", unit: "nV", physicalMin: "2000", physicalMax: "-2000",
                    digitalMin: "-100", digitalMax: "100", records: [[-100, 0, 100]])
        ]))
        defer { remove(url) }
        let signal = try SignalImportReader.load(from: url).signal
        XCTAssertEqual(signal.data[0], [1_000, 2_000, 3_000])
        for (a, b) in zip(signal.data[1], [Float(2), 0, -2]) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    func testBDFPlusFourDigitStartDateOverridesLegacyYear() throws {
        var bytes = try make(reserved: "BDF+C", channels: [
            Channel(label: "Cz", records: [[0]]),
            Channel(label: "BDF Annotations", annotations: ["+0\u{14}\u{14}\0"])
        ])
        let recording = Array("Startdate 01-JAN-2090 X X X".utf8)
        bytes.replaceSubrange(88..<168, with: recording + Array(repeating: UInt8(32), count: 80 - recording.count))
        bytes.replaceSubrange(168..<176, with: Array("01.01.yy".utf8))
        let url = try write(bytes)
        defer { remove(url) }
        let start = try XCTUnwrap(BDFRecording.read(from: url).startTime)
        XCTAssertEqual(Calendar.current.component(.year, from: start), 2090)
    }

    func testStatusEventsIgnoreSystemBitsAndSpanRecordBoundaries() throws {
        let url = try write(make(recordCount: "-1", channels: [
            Channel(label: "A1", records: [[0, 1, 2, 3], [4, 5, 6, 7]]),
            Channel(label: "Status", unit: "", records: [
                [0x800005, 0x900005, 0x900006, 0x900006],
                [0x900006, 0x900000, 0x900007, 0x900007]
            ])
        ]))
        defer { remove(url) }
        let imported = try SignalImportReader.load(from: url)
        XCTAssertEqual(imported.signal.channelNames, ["A1"])
        let events = imported.signal.events
        XCTAssertEqual(events.map(\.code), ["5", "6", "7"])
        XCTAssertEqual(events.map(\.beginTimeSeconds), [0, 0.5, 1.5])
        XCTAssertEqual(events.map(\.durationSeconds), [0.5, 0.75, 0.5])
        XCTAssertEqual(imported.pnsSignal?.channelNames, ["Status"])
        XCTAssertEqual(imported.pnsSignal?.data[0][0], Float(0x800005))
        XCTAssertEqual(imported.pnsSignal?.data[0][1], Float(0x900005))
    }

    func testMixedRatesKeepEEGAndPhysioSeparateAndUpsampleStatusByHolding() throws {
        let url = try write(make(channels: [
            Channel(label: "A1", records: [[10, 10, 10, 10]]),
            Channel(label: "EXG1", records: [[20, 20]]),
            Channel(label: "ECG", records: [[30, 30, 30, 30]]),
            Channel(label: "Status", unit: "", records: [[0, 4]])
        ]))
        defer { remove(url) }
        let imported = try SignalImportReader.load(from: url)
        XCTAssertEqual(imported.signal.channelNames, ["A1", "EXG1"])
        XCTAssertEqual(imported.signal.data, [[10, 10, 10, 10], [20, 20, 20, 20]])
        XCTAssertEqual(imported.pnsSignal?.samplingRate, 4)
        XCTAssertEqual(imported.pnsSignal?.channelNames, ["ECG", "Status"])
        XCTAssertEqual(imported.pnsSignal?.data[1], [0, 0, 4, 4])
        XCTAssertEqual(imported.signal.events.first?.beginTimeSeconds, 0.5)
    }

    func testNonVoltageSensorsAreNotTreatedAsScalpEEG() throws {
        let url = try write(make(channels: [
            Channel(label: "A1", records: [[1, 2]]),
            Channel(label: "Skin", unit: "Ohm", records: [[50, 60]])
        ]))
        defer { remove(url) }
        let imported = try SignalImportReader.load(from: url)
        XCTAssertEqual(imported.signal.channelNames, ["A1"])
        XCTAssertEqual(imported.pnsSignal?.channelNames, ["Skin"])
        XCTAssertEqual(imported.pnsSignal?.data[0], [50, 60])
    }

    func testBioSemiBankLabelsAreNotAssignedMastoidCoordinates() throws {
        let url = try write(make(channels: ["A1", "A2", "Fz", "Cz", "Pz"].map {
            Channel(label: $0, records: [[0, 1]])
        }))
        defer { remove(url) }
        let imported = try SignalImportReader.load(from: url)
        let geometry = try XCTUnwrap(imported.geometry)
        XCTAssertNil(geometry.positions[0])
        XCTAssertNil(geometry.positions[1])
        XCTAssertNotNil(geometry.positions[2])

        // Explicit coordinates take precedence even for the ambiguous labels.
        try "A1 0 1 1\nA2 1 0 1\nFz 0 2 1\nCz 0 0 2\nPz 0 -2 1\n"
            .write(to: url.deletingPathExtension().appendingPathExtension("sfp"), atomically: true, encoding: .utf8)
        let withSidecar = try SignalImportReader.load(from: url)
        XCTAssertNotNil(withSidecar.geometry?.positions[0])
        XCTAssertNotNil(withSidecar.geometry?.positions[1])
    }

    func testBDFPlusAnnotationsNormalizeFractionalClockAndPreserveUTF8() throws {
        let url = try write(make(reserved: "BDF+C", channels: [
            Channel(label: "Cz", records: [[0, 1], [2, 3]]),
            Channel(label: "BDF Annotations", unit: "", annotations: [
                "+0.125\u{14}\u{14}\0+0.375\u{15}0.5\u{14}Stimulus α\u{14}\0",
                "+1.125\u{14}\u{14}\0+1.625\u{14}response\u{14}\0"
            ]),
            Channel(label: "Status", unit: "", records: [[0, 3], [3, 0]])
        ]))
        defer { remove(url) }
        let recording = try BDFRecording.read(from: url)
        XCTAssertTrue(recording.isPlus)
        XCTAssertEqual(recording.events.map(\.code), ["Stimulus α", "3", "response"])
        XCTAssertEqual(recording.events.map(\.beginTimeSeconds), [0.25, 0.5, 1.5])
        XCTAssertEqual(recording.events[0].durationSeconds, 0.5)
        XCTAssertEqual(recording.events[1].durationSeconds, 1)
        let calendar = Calendar.current
        let start = try XCTUnwrap(recording.startTime)
        XCTAssertEqual(calendar.component(.year, from: start), 2025)
        XCTAssertEqual(start.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.125, accuracy: 1e-6)
        XCTAssertEqual(try SignalImportReader.load(from: url).signal.numberOfChannels, 1)
    }

    func testBDFPlusDiscontinuitiesAreRefusedAndContiguousDIsAccepted() throws {
        for reserved in ["BDF+C", "BDF+D"] {
            let url = try write(make(reserved: reserved, channels: [
                Channel(label: "Cz", records: [[0], [1]]),
                Channel(label: "BDF Annotations", unit: "", annotations: [
                    "+0\u{14}\u{14}\0", "+3\u{14}\u{14}\0"
                ])
            ]))
            defer { remove(url) }
            XCTAssertThrowsError(try SignalImportReader.load(from: url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("discontinuous"))
            }
        }
        let continuous = try write(make(reserved: "BDF+D", channels: [
            Channel(label: "Cz", records: [[0], [1]]),
            Channel(label: "BDF Annotations", unit: "", annotations: [
                "+0\u{14}\u{14}\0", "+1\u{14}\u{14}\0"
            ])
        ]))
        defer { remove(continuous) }
        XCTAssertEqual(try SignalImportReader.load(from: continuous).signal.duration, 2)
    }

    func testMalformedHeadersPayloadCalibrationAndAnnotationsAreRejected() throws {
        let base = try make(channels: [Channel(label: "A1", records: [[1, 2]])])
        var truncated = base; truncated.removeLast()
        var badCount = base; badCount.replaceSubrange(236..<244, with: Array("-2      ".utf8))
        var enormous = base; enormous.replaceSubrange(244..<252, with: Array("NaN     ".utf8))
        let variants = [truncated, badCount, enormous,
            try make(channels: [Channel(label: "A1", digitalMin: "0", digitalMax: "0", records: [[0]])]),
            try make(reserved: "BDF+C", channels: [Channel(label: "A1", records: [[0]])]),
            try make(reserved: "BDF+C", channels: [
                Channel(label: "A1", records: [[0]]),
                Channel(label: "BDF Annotations", annotations: ["+NaN\u{14}\u{14}\0"])
            ])
        ]
        for bytes in variants {
            let url = try write(bytes)
            defer { remove(url) }
            XCTAssertThrowsError(try SignalImportReader.load(from: url))
        }
    }

    func testResamplingPreservesNativeSamplesDCAndLowFrequencySine() throws {
        let input = (0..<128).map { Float(sin(2 * .pi * Double($0) * 3 / 128)) }
        let upsampled = try BDFImportResampling.upsample(input, toCount: 384, discrete: false)
        for index in input.indices { XCTAssertEqual(upsampled[index * 3], input[index]) }
        for index in 48..<336 {
            let expected = Float(sin(2 * .pi * Double(index) * 3 / 384))
            XCTAssertEqual(upsampled[index], expected, accuracy: 0.0005)
        }
        let dc = try BDFImportResampling.upsample([12, 12, 12], toCount: 8, discrete: false)
        for value in dc { XCTAssertEqual(value, 12, accuracy: 0.0001) }
        XCTAssertEqual(try BDFImportResampling.upsample([1, 2, 3], toCount: 8, discrete: true),
                       [1, 1, 1, 2, 2, 2, 3, 3])
    }

    @MainActor
    func testBDFImportExportsToMFFWithEventsPNSAndProcessingRecord() async throws {
        let input = try write(make(channels: [
            Channel(label: "Cz", records: [[-10, 20, 30, 40]]),
            Channel(label: "Status", unit: "", records: [[0, 2, 2, 0]])
        ]))
        defer { remove(input) }
        let imported = try SignalImportReader.load(from: input)
        let url = input.deletingLastPathComponent().appendingPathComponent("exported.mff")
        let result = await MFFExportWriter.write(
            snapshot: MFFExportSnapshot(signal: imported.signal, segments: [], kind: .continuous),
            pnsSignal: imported.pnsSignal, script: EVAProcessingScript(), to: url
        )
        _ = try result.get()
        let reopened = try SignalImportReader.load(from: url)
        XCTAssertEqual(reopened.signal.data, imported.signal.data)
        XCTAssertEqual(reopened.signal.events.map(\.code), ["2"])
        XCTAssertEqual(reopened.signal.events.first?.beginTimeSeconds, 0.25)
        XCTAssertEqual(reopened.pnsSignal?.data, imported.pnsSignal?.data)
        XCTAssertNotNil(EVAProcessingScriptXML.read(fromPackage: url))
        let logURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("log_eva_") })
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("triggerMask=0xffff"))
    }

    func testBundledBDFMatchesIndependentMNEReference() throws {
        try compareMNE(in: Fixtures.url("BDF"), name: "sample")
    }

    func testVendorRecordingsMatchMNEWhenLocallyAvailable() throws {
        let folder = Fixtures.directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".regression-corpus/bdf")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("Newtest17-256.json").path) else {
            throw XCTSkip("Optional BioSemi vendor recordings: see Tools/bdf-import/README.md")
        }
        try compareMNE(in: folder, name: "Newtest17-256")
        try compareMNE(in: folder, name: "Newtest17-2048")
    }

    private func compareMNE(in folder: URL, name: String) throws {
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name + ".json"))) as! [String: Any]
        let recording = try BDFRecording.read(from: folder.appendingPathComponent(name + ".bdf"))
        XCTAssertEqual(recording.channels.map(\.label), reference["channel_names"] as! [String])
        let referenceData = try Data(contentsOf: folder.appendingPathComponent(name + ".f32"))
        let expected: [Float] = referenceData.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
        }
        var cursor = 0
        for channel in recording.channels {
            // MNE masks STIM to 17 bits. EVA retains all 24 Status bits;
            // compare the shared bits here and test raw words separately.
            var maxError: Float = 0
            for value in channel.samples {
                let comparable = channel.isStatus
                    ? Float(UInt32(value) & UInt32(reference["status_reference_mask"] as! Int)) : value
                maxError = max(maxError, abs(comparable - expected[cursor]))
                cursor += 1
            }
            XCTAssertLessThanOrEqual(maxError, 0.001, "\(name): \(channel.label)")
        }
        XCTAssertEqual(cursor, expected.count)
        XCTAssertEqual(recording.duration, reference["duration"] as! Double, accuracy: 1e-9)
        let expectedEvents = reference["events"] as! [[Double]]
        XCTAssertEqual(recording.events.count, expectedEvents.count)
        for (actual, expected) in zip(recording.events, expectedEvents) {
            XCTAssertEqual(actual.beginTimeSeconds, expected[0], accuracy: 1e-9)
            XCTAssertEqual(Double(actual.code), expected[1])
        }
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    private func write(_ bytes: Data, name: String = "sample.bdf") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eva-bdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func make(recordCount: String? = nil, reserved: String = "24BIT", channels: [Channel]) throws -> Data {
        let records = channels.map { max($0.records.count, $0.annotations.count) }.max() ?? 0
        var data = Data([0xff])
        data.append(contentsOf: "BIOSEMI".utf8)
        func field(_ value: String, _ width: Int) {
            let bytes = Array(value.utf8)
            precondition(bytes.count <= width)
            data.append(contentsOf: bytes)
            data.append(contentsOf: repeatElement(UInt8(32), count: width - bytes.count))
        }
        field("X", 80); field("Startdate 01-JAN-2025 X X X", 80)
        field("01.01.25", 8); field("12.00.00", 8)
        field(String(256 * (channels.count + 1)), 8); field(reserved, 44)
        field(recordCount ?? String(records), 8); field("1", 8); field(String(channels.count), 4)
        for channel in channels { field(channel.label, 16) }
        for _ in channels { field("", 80) }
        for channel in channels { field(channel.unit, 8) }
        for channel in channels { field(channel.physicalMin, 8) }
        for channel in channels { field(channel.physicalMax, 8) }
        for channel in channels { field(channel.digitalMin, 8) }
        for channel in channels { field(channel.digitalMax, 8) }
        for _ in channels { field("", 80) }
        for channel in channels { field(String(channel.count), 8) }
        for _ in channels { field("", 32) }
        for record in 0..<records {
            for channel in channels {
                if !channel.annotations.isEmpty {
                    let bytes = Array(channel.annotations[record].utf8)
                    precondition(bytes.count <= channel.count * 3)
                    data.append(contentsOf: bytes)
                    data.append(contentsOf: repeatElement(UInt8(0), count: channel.count * 3 - bytes.count))
                } else {
                    for value in channel.records[record] {
                        let word = UInt32(bitPattern: value)
                        data.append(contentsOf: [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word >> 16)])
                    }
                }
            }
        }
        return data
    }
}
