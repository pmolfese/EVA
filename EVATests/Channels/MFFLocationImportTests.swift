//
//  MFFLocationImportTests.swift
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
import simd
import XCTest
@testable import EVA

final class MFFLocationImportTests: XCTestCase {
    private func sensor(_ number: Int, _ name: String, _ x: String, _ y: String, _ z: String = "0", type: Int = 0) -> String {
        "<sensor><number>\(number)</number><name>\(name)</name><type>\(type)</type><x>\(x)</x><y>\(y)</y><z>\(z)</z></sensor>"
    }
    private func file(_ root: String, _ sensors: String) throws -> ElectrodeLocationFile {
        try ElectrodeLocationFile.parse(Data("<\(root) xmlns=\"http://www.egi.com/\(root)_mff\"><name>Test Net</name><sensors>\(sensors)</sensors></\(root)>".utf8), sourceName: root + ".xml")
    }

    func testCoordinatesUseMFFAxesAndNumbersAndIgnoreFiducials() throws {
        let montage = try file("coordinates",
            sensor(1, "", "-3", "4", "0") + sensor(2, "Cz", "0", "0", "9") +
            sensor(3, "Unknown", "0", "0", "0") + sensor(4, "VREF", "0", "1", "1", type: 1) +
            sensor(400, "Nasion", "0", "10", "0", type: 2))
        XCTAssertEqual(montage.electrodes.count, 4)
        XCTAssertEqual(montage.electrodes.first?.name, "E1")
        let resolved = try montage.resolved(channelNames: ["E1", "E2", "E3"], using: .numbers)
        XCTAssertEqual(resolved.geometry.positions[0]!.x, -0.6, accuracy: 1e-12)
        XCTAssertEqual(resolved.geometry.positions[0]!.y, 0.8, accuracy: 1e-12)
        XCTAssertEqual(resolved.geometry.positions[1]!.z, 1)
        XCTAssertNil(resolved.geometry.positions[2])
        XCTAssertNil(resolved.geometry.positions[3])
        XCTAssertNil(resolved.geometry.reference)
        XCTAssertNil(resolved.layoutOverride)
    }

    func testCoordinatesMatchReorderedNamesAndPreserveReferenceIdentity() throws {
        let montage = try file("coordinates", sensor(1, "Fz", "0", "2", "2") +
            sensor(2, "Cz", "0", "0", "1") + sensor(3, "VREF", "1", "0", "1", type: 1))
        let reference = ElectrodeGeometry.Reference(channelIndex: 2, name: "Acquisition REF", position: SIMD3(0, 0, 1))
        let resolved = try montage.resolved(channelNames: ["EEG Cz-REF", "fz"], using: .names, reference: reference)
        XCTAssertEqual(resolved.geometry.positions[0]!.z, 1)
        XCTAssertEqual(resolved.geometry.positions[1]!.y, sqrt(0.5), accuracy: 1e-12)
        XCTAssertEqual(resolved.geometry.reference?.channelIndex, 2)
        XCTAssertEqual(resolved.geometry.reference?.name, "Acquisition REF")
        XCTAssertEqual(resolved.geometry.reference!.position.x, sqrt(0.5), accuracy: 1e-12)
        let fromFlatReference = try montage.resolved(channelNames: ["Fz", "Cz"], using: .names,
            layoutReference: SensorReference(channelIndex: 2, name: "Known REF", x: 0, y: 0))
        XCTAssertEqual(fromFlatReference.geometry.reference?.name, "Known REF")
        XCTAssertEqual(fromFlatReference.geometry.reference?.channelIndex, 2)
    }

    func testFlatLayoutInvertsEGIYAndKeepsCenterElectrodesWithoutInventing3D() throws {
        let montage = try file("sensorLayout", sensor(1, "Left", "-10", "0") +
            sensor(2, "Right", "10", "0") + sensor(3, "Anterior", "0", "-10") +
            sensor(4, "Posterior", "0", "10") + sensor(5, "Cz", "0", "0"))
        let value = try montage.resolved(channelNames: ["Left", "Right", "Anterior", "Posterior", "Cz"], using: .names)
        XCTAssertTrue(value.geometry.positions.isEmpty)
        XCTAssertNotNil(value.layoutOverride)
        let points = Dictionary(uniqueKeysWithValues: value.layout.positions.map { ($0.channelIndex, $0) })
        XCTAssertEqual(points[0]?.x, -1)
        XCTAssertEqual(points[1]?.x, 1)
        XCTAssertEqual(points[2]?.y, 1)
        XCTAssertEqual(points[3]?.y, -1)
        XCTAssertEqual(points[4]?.x, 0)
        XCTAssertEqual(points[4]?.y, 0)
        XCTAssertEqual(try montage.matches(channelNames: ["Cz"], using: .names).first?.electrode?.hasLocation, true)
    }

    func testExistingMFFFixturesAgreeWithNativeGeometryAndLayoutReaders() throws {
        let package = Fixtures.url("example_2.mff")
        let nativeGeometry = try XCTUnwrap(ElectrodeGeometry.load(from: package))
        let coordinates = try ElectrodeLocationFile.read(from: package.appendingPathComponent("coordinates.xml"))
        let count = nativeGeometry.positions.count
        let names = (1...count).map { "E\($0)" }
        let geometry = try coordinates.resolved(channelNames: names, using: .numbers).geometry
        XCTAssertEqual(geometry.positions.count, nativeGeometry.positions.count)
        for (index, position) in nativeGeometry.positions {
            XCTAssertLessThan(simd_length(geometry.positions[index]! - position), 1e-12)
        }
        let flatFile = try ElectrodeLocationFile.read(from: package.appendingPathComponent("sensorLayout.xml"))
        let flat = try flatFile.resolved(channelNames: names, using: .numbers).layout
        let nativeFlat = try XCTUnwrap(SensorLayout.load(fromPackageContaining: package.appendingPathComponent("signal1.bin")))
        XCTAssertEqual(flat.positions.count, nativeFlat.positions.count)
        for (actual, expected) in zip(flat.positions, nativeFlat.positions) {
            XCTAssertEqual(actual.channelIndex, expected.channelIndex)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12)
        }
    }

    func testNamespacePrefixesAreRecognizedAndMalformedFilesAreRejected() throws {
        let xml = "<m:coordinates xmlns:m=\"http://www.egi.com/coordinates_mff\"><m:sensors><m:sensor><m:number>1</m:number><m:type>0</m:type><m:x>0</m:x><m:y>0</m:y><m:z>1</m:z></m:sensor></m:sensors></m:coordinates>"
        let prefixed = try ElectrodeLocationFile.parse(Data(xml.utf8), sourceName: "custom.xml")
        XCTAssertEqual(prefixed.electrodes.first?.position?.z, 1)
        for sensors in [sensor(1, "Fz", "NaN", "0", "1"),
                        sensor(1, "Fz", "1", "0", "1") + sensor(1, "Cz", "0", "0", "1"),
                        sensor(1, "Fz", "1", "0", "1") + sensor(2, "Fz", "0", "0", "1"),
                        "<sensor><number>1</number><type>0</type><x>1</x><y>0</y></sensor>",
                        sensor(1, "Fz", "0", "0", "0")] {
            XCTAssertThrowsError(try file("coordinates", sensors))
        }
        XCTAssertThrowsError(try ElectrodeLocationFile.parse(Data("<info/>".utf8), sourceName: "info.xml"))
        XCTAssertThrowsError(try ElectrodeLocationFile.parse(Data("<coordinates>".utf8), sourceName: "bad.xml"))
    }

    func testSharedImporterStillReadsBrainVision() throws {
        let xml = "<Electrodes><Electrode><Name>Cz</Name><Number>1</Number><Theta>0</Theta><Phi>0</Phi><Radius>1</Radius></Electrode></Electrodes>"
        let common = try ElectrodeLocationFile.parse(Data(xml.utf8), sourceName: "cap.bvef")
        let value = try common.resolved(channelNames: ["Cz"], using: .names)
        XCTAssertEqual(value.geometry.positions[0]?.z, 1)
        XCTAssertNil(value.layoutOverride)
    }

    @MainActor
    func testFlatOverrideRemovesOldGeometryAndStays2DAcrossExportAndReexport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eva-flat-locations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["Fz", "Cz", "Pz"] // automatic standard-name geometry would be wrong here
        let signal = MFFSignalData(signalURL: folder.appendingPathComponent("source.bin"), signalType: "EEG",
            numberOfChannels: 3, samplingRate: 4, duration: 1, recordingStartTime: nil,
            events: [], data: [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]], channelNames: names)
        let spatial = try file("coordinates", sensor(1, "Fz", "0", "1", "1") +
            sensor(2, "Cz", "0", "0", "1") + sensor(3, "Pz", "0", "-1", "1"))
            .resolved(channelNames: names, using: .names)
        let input = folder.appendingPathComponent("source.mff")
        try MFFWriter.write(signal: signal, segments: [], kind: .continuous, to: input, locationOverride: spatial)
        let originalCoordinates = try Data(contentsOf: input.appendingPathComponent("coordinates.xml"))
        let recording = MFFRecording(packageURL: input)
        await recording.loadIfNeeded()
        XCTAssertNotNil(recording.electrodeGeometry)
        let flat = try file("sensorLayout", sensor(1, "Fz", "0", "-10") +
            sensor(2, "Cz", "0", "0") + sensor(3, "Pz", "0", "10"))
            .resolved(channelNames: names, using: .names)
        try recording.applyLocationOverride(flat)
        XCTAssertNil(recording.electrodeGeometry)
        let output = folder.appendingPathComponent("flat.mff")
        let result = await MFFExportWriter.write(snapshot: MFFExportSnapshot(signal: recording.signal!, segments: [], kind: .continuous,
            locationOverride: recording.locationOverride), pnsSignal: nil, script: EVAProcessingScript(), to: output)
        _ = try result.get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("coordinates.xml").path))
        let reopened = try SignalImportReader.load(from: output)
        XCTAssertNil(reopened.geometry)
        XCTAssertEqual(reopened.layout, flat.layout)
        XCTAssertEqual(reopened.signal.data, signal.data)
        let secondOutput = folder.appendingPathComponent("flat-again.mff")
        try MFFWriter.write(signal: reopened.signal, segments: [], kind: .continuous, to: secondOutput)
        XCTAssertNil(try SignalImportReader.load(from: secondOutput).geometry)
        XCTAssertEqual(try Data(contentsOf: input.appendingPathComponent("coordinates.xml")), originalCoordinates)

        // Channel-role edits must also keep the flat override's row mapping.
        _ = try recording.moveEEGChannelToPhysio(index: 0)
        _ = try recording.movePhysioChannelToEEG(index: 0)
        XCTAssertEqual(recording.locationOverride?.channelNames, ["Cz", "Pz", "Fz"])
        XCTAssertNotNil(recording.locationOverride?.layoutOverride)
        XCTAssertNil(recording.electrodeGeometry)
        XCTAssertEqual(recording.locationOverride?.layout.positions.first { $0.channelIndex == 2 }?.y, 1)

        // A later 3D import replaces the 2D marker as well as the XML.
        let thirdOutput = folder.appendingPathComponent("spatial-again.mff")
        try MFFWriter.write(signal: reopened.signal, segments: [], kind: .continuous, to: thirdOutput, locationOverride: spatial)
        XCTAssertNotNil(try SignalImportReader.load(from: thirdOutput).geometry)
    }
}
