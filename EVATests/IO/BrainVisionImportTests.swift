//
//  BrainVisionImportTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import EVA

final class BrainVisionImportTests: XCTestCase {
    func testMarkersPreserveTypeDescriptionAndDuration() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-brainvision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let headerURL = folder.appendingPathComponent("sample.vhdr")
        let markerURL = folder.appendingPathComponent("sample.vmrk")
        let dataURL = folder.appendingPathComponent("sample.eeg")

        try """
        BrainVision Data Exchange Header File Version 1.0

        [Common Infos]
        Codepage=UTF-8
        DataFile=sample.eeg
        MarkerFile=sample.vmrk
        DataFormat=BINARY
        DataOrientation=MULTIPLEXED
        NumberOfChannels=1
        SamplingInterval=1000

        [Binary Infos]
        BinaryFormat=INT_16

        [Channel Infos]
        Ch1=Fz,,0.5,µV
        """.write(to: headerURL, atomically: true, encoding: .utf8)

        try """
        BrainVision Data Exchange Marker File Version 1.0

        [Common Infos]
        Codepage=UTF-8
        DataFile=sample.eeg

        [Marker Infos]
        Mk1=New Segment,,1,1,0,20250101000000000000
        Mk2=Stimulus,Face\\1Happy,2,3,0
        Mk3=SyncStatus,Sync On,4,1,0
        """.write(to: markerURL, atomically: true, encoding: .utf8)

        try int16Data([1, 2, 3, 4]).write(to: dataURL)

        let imported = try SignalImportReader.load(from: headerURL)
        let events = imported.signal.events

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].code, "Stimulus/Face,Happy")
        XCTAssertEqual(events[0].label, "Stimulus")
        XCTAssertEqual(events[0].eventDescription, "Face,Happy")
        XCTAssertEqual(events[0].beginTimeSeconds, 0.001, accuracy: 0.000_001)
        XCTAssertEqual(events[0].durationSeconds ?? -1, 0.003, accuracy: 0.000_001)
        XCTAssertEqual(events[1].code, "SyncStatus/Sync On")
        XCTAssertEqual(events[1].label, "SyncStatus")
        XCTAssertEqual(events[1].eventDescription, "Sync On")
        XCTAssertNil(events[1].durationSeconds)
    }

    func testInfersStandardElectrodeLocationsFromBrainVisionChannelLabels() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-brainvision-standard-labels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let headerURL = folder.appendingPathComponent("standard-labels.vhdr")
        let dataURL = folder.appendingPathComponent("standard-labels.eeg")

        try """
        BrainVision Data Exchange Header File Version 1.0

        [Common Infos]
        Codepage=UTF-8
        DataFile=standard-labels.eeg
        DataFormat=BINARY
        DataOrientation=MULTIPLEXED
        NumberOfChannels=6
        SamplingInterval=1000

        [Binary Infos]
        BinaryFormat=INT_16

        [Channel Infos]
        Ch1=Fp1,,1,µV
        Ch2=Fp2,,1,µV
        Ch3=Cz,,1,µV
        Ch4=Oz,,1,µV
        Ch5=T3,,1,µV
        Ch6=ECG,,1,µV
        """.write(to: headerURL, atomically: true, encoding: .utf8)

        try int16Data((0..<24).map(Int16.init)).write(to: dataURL)

        let imported = try SignalImportReader.load(from: headerURL)
        let layout = try XCTUnwrap(imported.layout)
        let geometry = try XCTUnwrap(imported.geometry)

        XCTAssertEqual(layout.name, "Standard 10-20/10-10 labels")
        XCTAssertEqual(layout.positions.map(\.channelIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(geometry.positions.keys), Set([0, 1, 2, 3, 4]))
        XCTAssertLessThan(geometry.positions[0]?.x ?? 0, 0)
        XCTAssertGreaterThan(geometry.positions[1]?.x ?? 0, 0)
        XCTAssertLessThan(geometry.positions[4]?.x ?? 0, 0)
        XCTAssertNil(geometry.positions[5])
    }

    private func int16Data(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }
}
