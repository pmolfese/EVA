//
//  BVEFMontageTests.swift
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

final class BVEFMontageTests: XCTestCase {
    private func montage() throws -> BVEFMontage {
        try BVEFMontage.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Electrodes defaults="false">
          <Electrode><Name>GND</Name><Theta>67</Theta><Phi>90</Phi><Radius>1</Radius></Electrode>
          <Electrode><Name>REF</Name><Theta>23</Theta><Phi>90</Phi><Radius>1</Radius></Electrode>
          <Electrode><Name>Fp1</Name><Theta>-90</Theta><Phi>-72</Phi><Radius>1</Radius><Number>1</Number></Electrode>
          <Electrode><Name>Fp2</Name><Theta>90</Theta><Phi>72</Phi><Radius>1</Radius><Number>2</Number></Electrode>
          <Electrode><Name>Cz</Name><Theta>0</Theta><Phi>0</Phi><Radius>1</Radius><Number>3</Number></Electrode>
          <Electrode><Name>EOGL</Name><Theta>-131</Theta><Phi>-64</Phi><Radius>0</Radius><Number>4</Number></Electrode>
        </Electrodes>
        """.utf8), sourceName: "Test Cap.bvef")
    }

    func testSignedSphericalAnglesPreserveLeftRightAndAnterior() throws {
        let locations = try montage().resolved(channelNames: ["Fp1", "Fp2", "Cz", "EOGL"], using: .names)
        let left = try XCTUnwrap(locations.geometry.positions[0])
        let right = try XCTUnwrap(locations.geometry.positions[1])
        XCTAssertEqual(left.x, -0.30901699437494745, accuracy: 1e-12)
        XCTAssertEqual(right.x, 0.30901699437494745, accuracy: 1e-12)
        XCTAssertEqual(left.y, 0.9510565162951535, accuracy: 1e-12)
        XCTAssertEqual(right.y, left.y, accuracy: 1e-12)
        XCTAssertEqual(locations.geometry.positions[2]?.z, 1)
        XCTAssertNil(locations.geometry.positions[3])
        XCTAssertEqual(locations.layout.positions.count, 3)
        XCTAssertNil(locations.geometry.reference)
    }

    func testNameMatchingUsesIdentityRatherThanFileOrder() throws {
        let mapping = try montage().matches(channelNames: [" EEG Cz-REF ", "fp2", "Fp1", "Other"], using: .names)
        XCTAssertEqual(mapping.map { $0.electrode?.name }, ["Cz", "Fp2", "Fp1", nil])
        let result = try montage().resolved(channelNames: ["Cz", "Fp2", "Fp1", "Other"], using: .names)
        XCTAssertEqual(result.geometry.positions[0]?.z, 1)
        XCTAssertNil(result.geometry.positions[3])
    }

    func testNumberMappingDoesNotShiftForUnnumberedReferenceOrGround() throws {
        let mapping = try montage().matches(channelNames: ["E1", "E2", "E3", "E4", "E5"], using: .numbers)
        XCTAssertEqual(mapping.map { $0.electrode?.name }, ["Fp1", "Fp2", "Cz", "EOGL", nil])
        let resolved = try montage().resolved(channelNames: ["E1", "E2", "E3", "E4", "E5"], using: .numbers)
        XCTAssertEqual(resolved.channelNames, ["E1", "E2", "E3", "E4", "E5"])
        XCTAssertEqual(resolved.geometry.positions.count, 3)
        XCTAssertNil(resolved.geometry.positions[3])
        XCTAssertNil(resolved.geometry.positions[4])
    }

    func testReferenceIdentityIsPreservedWithoutAddingASignalRow() throws {
        let reference = ElectrodeGeometry.Reference(channelIndex: 4, name: "VREF", position: SIMD3(0, 0, 1))
        let result = try montage().resolved(channelNames: ["Fp1", "Fp2", "Cz", "EOGL"], using: .names, reference: reference)
        XCTAssertEqual(result.channelNames.count, 4)
        XCTAssertEqual(result.geometry.reference?.channelIndex, 4)
        XCTAssertEqual(result.geometry.reference?.name, "VREF")
        XCTAssertEqual(result.geometry.reference!.position.y, sin(23 * .pi / 180), accuracy: 1e-12)
    }

    func testMalformedAmbiguousAndNonfiniteElectrodesAreRejected() throws {
        let electrode = "<Electrode><Name>Cz</Name><Theta>0</Theta><Phi>0</Phi><Radius>1</Radius><Number>1</Number></Electrode>"
        for xml in ["<NotElectrodes/>", "<Electrodes>" + electrode,
                    "<Electrodes>" + electrode + electrode + "</Electrodes>",
                    "<Electrodes>" + electrode.replacingOccurrences(of: "<Theta>0", with: "<Theta>NaN") + "</Electrodes>",
                    "<Electrodes>" + electrode.replacingOccurrences(of: "<Radius>1", with: "<Radius>-1") + "</Electrodes>",
                    "<!DOCTYPE Electrodes [<!ENTITY name 'Cz'>]><Electrodes>" + electrode + "</Electrodes>"] {
            XCTAssertThrowsError(try BVEFMontage.parse(Data(xml.utf8), sourceName: "invalid.bvef"))
        }
        XCTAssertThrowsError(try montage().matches(channelNames: ["Cz", "cz"], using: .names))
        XCTAssertThrowsError(try montage().resolved(channelNames: ["No match"], using: .names))
    }

    @MainActor
    func testRecordingOverrideLeavesSamplesUntouchedAndSurvivesMFFExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eva-locations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.mff")
        let signal = MFFSignalData(signalURL: folder.appendingPathComponent("raw.bin"), signalType: "EEG",
            numberOfChannels: 4, samplingRate: 10, duration: 1, recordingStartTime: nil,
            events: [], data: (0..<4).map { index in (0..<10).map { Float(index * 10 + $0) } },
            channelNames: ["E1", "E2", "E3", "E4"])
        let targetLocations = try montage().resolved(channelNames: signal.channelNames!, using: .numbers)
        let staleGeometry = ElectrodeGeometry(name: "Wrong net", positions: targetLocations.geometry.positions.mapValues {
            SIMD3(-$0.x, -$0.y, $0.z)
        })
        let stale = EEGLocationOverride(sourceName: "Wrong net", matching: .numbers, channelNames: signal.channelNames!, geometry: staleGeometry)
        try MFFWriter.write(signal: signal, segments: [], kind: .continuous, to: input, locationOverride: stale)
        let sourceBytes = try Data(contentsOf: input.appendingPathComponent("sensorLayout.xml"))
        let recording = MFFRecording(packageURL: input)
        await recording.loadIfNeeded()
        let loaded = try XCTUnwrap(recording.signal)
        XCTAssertGreaterThan(recording.electrodeGeometry!.positions[0]!.x, 0)
        let locations = try montage().resolved(channelNames: signal.channelNames!, using: .numbers)
        try recording.applyLocationOverride(locations)
        XCTAssertEqual(recording.signal?.dataRevision, loaded.dataRevision)
        XCTAssertEqual(recording.signal?.data, loaded.data)
        XCTAssertEqual(recording.sensorLayout?.positions.count, 3)
        XCTAssertNil(recording.electrodeGeometry?.positions[3])

        let output = folder.appendingPathComponent("export.mff")
        let result = await MFFExportWriter.write(snapshot: MFFExportSnapshot(signal: loaded, segments: [], kind: .continuous,
            locationOverride: recording.locationOverride), pnsSignal: nil, script: EVAProcessingScript(), to: output)
        _ = try result.get()
        let reopened = try SignalImportReader.load(from: output)
        XCTAssertEqual(reopened.signal.channelNames, loaded.channelNames)
        XCTAssertEqual(reopened.signal.data, loaded.data)
        XCTAssertEqual(reopened.layout?.positions.count, 3)
        XCTAssertNil(reopened.geometry?.positions[3])
        for (index, position) in locations.geometry.positions {
            let saved = try XCTUnwrap(reopened.geometry?.positions[index])
            XCTAssertLessThan(simd_length(saved - position), 1e-12)
        }
        XCTAssertEqual(try Data(contentsOf: input.appendingPathComponent("sensorLayout.xml")), sourceBytes)
        XCTAssertNotNil(EVAProcessingScriptXML.read(fromPackage: output))
        let log = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("log_eva_") })
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("Test Cap.bvef"))
        XCTAssertThrowsError(try recording.applyLocationOverride(montage().resolved(channelNames: ["Cz"], using: .names)))

        // Moving a channel to Physio and back changes row order. The active
        // override must follow that edit instead of reverting to source XML.
        _ = try recording.moveEEGChannelToPhysio(index: 0)
        XCTAssertEqual(recording.locationOverride?.channelNames, ["E2", "E3", "E4"])
        XCTAssertEqual(recording.locationOverride?.geometry.positions[0]?.x, locations.geometry.positions[1]?.x)
        _ = try recording.movePhysioChannelToEEG(index: 0)
        XCTAssertEqual(recording.locationOverride?.channelNames, ["E2", "E3", "E4", "E1"])
        XCTAssertEqual(recording.locationOverride?.geometry.positions[3]?.x, locations.geometry.positions[0]?.x)
    }

    @MainActor
    func testChannelsWindowRoutesImportToTheIntendedRecording() throws {
        let model = ChannelsWindowModel.shared
        let first = UUID(), second = UUID()
        defer { model.removeRecording(id: first); model.removeRecording(id: second) }
        var applied = false
        let signal = MFFSignalData(signalURL: URL(fileURLWithPath: "/tmp/test"), signalType: "EEG",
            numberOfChannels: 1, samplingRate: 10, duration: 0.1, recordingStartTime: nil,
            events: [], data: [[0]], channelNames: ["Cz"])
        model.publishRecording(id: first, name: "First", signal: signal, acquisitionSignal: signal,
            layout: nil, channelNames: ["Cz"], healthResults: [:], isAnalyzingHealth: false, healthProgress: 0,
            refreshHealth: {}, importLocations: { _ in applied = true })
        model.activateRecording(id: first)
        let value = try montage().resolved(channelNames: ["Cz"], using: .names)
        XCTAssertTrue(model.canImportLocations)
        try model.applyLocationOverride(value, toRecording: first)
        XCTAssertTrue(applied)
        applied = false
        model.publishRecording(id: second, name: "Second", signal: signal, acquisitionSignal: signal,
            layout: nil, channelNames: ["Cz"], healthResults: [:], isAnalyzingHealth: false, healthProgress: 0, refreshHealth: {})
        model.activateRecording(id: second)
        XCTAssertThrowsError(try model.applyLocationOverride(value, toRecording: first))
        XCTAssertFalse(applied)
    }

    func testSuppliedBrainCapFileAgainstMNEWhenLocallyAvailable() throws {
        let folder = Fixtures.directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".regression-corpus/locations")
        let url = folder.appendingPathComponent("BC-MR-64-X52.bvef")
        let referenceURL = folder.appendingPathComponent("bvef-reference.json")
        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            throw XCTSkip("Optional study-specific montage reference is not installed.")
        }
        let file = try BVEFMontage.read(from: url)
        XCTAssertEqual(file.electrodes.count, 66)
        let resolved = try file.resolved(channelNames: (1...64).map { "E\($0)" }, using: .numbers)
        XCTAssertEqual(resolved.geometry.positions.count, 61)
        XCTAssertNil(resolved.geometry.positions[31])
        XCTAssertNil(resolved.geometry.positions[62])
        XCTAssertNil(resolved.geometry.positions[63])
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: referenceURL)) as! [String: [Double]]
        for electrode in file.electrodes {
            let expected = try XCTUnwrap(reference[electrode.name])
            if let position = electrode.position {
                XCTAssertLessThan(simd_length(position - SIMD3(expected[0], expected[1], expected[2])), 1e-12, electrode.name)
            } else {
                XCTAssertEqual(expected, [0, 0, 0])
            }
        }
    }
}
