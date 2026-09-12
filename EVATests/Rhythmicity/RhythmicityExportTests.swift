//
//  RhythmicityExportTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct RhythmicityExportTests {
    @Test func artifactRangesSplitSegmentsWithoutBridgingOrOverlap() {
        let segments = [
            RhythmicitySegment(startSample: 0, endSample: 99, label: "recording"),
            RhythmicitySegment(startSample: 120, endSample: 149, label: "trial", trialID: "t1"),
        ]
        let output = RhythmicitySegmentPolicy.removing(
            excludedRanges: [10...19, 15...25, 40...40, 90...130],
            from: segments
        )
        #expect(output.map { $0.startSample...$0.endSample } == [0...9, 26...39, 41...89, 131...149])
        #expect(output.last?.trialID == "t1")
        #expect(zip(output, output.dropFirst()).allSatisfy { $0.endSample < $1.startSample })
    }

    @Test func packageContainsVersionedManifestLongCSVsAndNumpyArrays() throws {
        let samplingRate = 200.0
        let samples = (0..<2_000).map { sin(2 * Double.pi * 10 * Double($0) / samplingRate) }
        let input = RhythmicityInput.entireRecording(
            channels: [RhythmicityChannelInput(channelIndex: 3, channelName: "E4", samples: samples)],
            samplingRate: samplingRate,
            source: .init(recordingIdentity: "fixture#revision", displayName: "Fixture"),
            processingProvenance: .init(sourceRevision: "revision", processingSummary: ["Reference state: average"])
        )
        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.backend = .directReferenceCPU
        configuration.frequenciesHz = [8, 10, 12]
        let result = try LAVIEngine.analyze(input: input, configuration: configuration)
        let selection = RhythmicitySelectionDescriptor(
            source: .processed,
            dataSelection: .entireProcessedRecording,
            segments: input.segments,
            channelScope: .current,
            channelSetName: nil,
            includedChannelIndices: [3],
            excludedBadChannelIndices: [5],
            interpolatedChannelIndices: [3],
            includedMarkedArtifacts: false
        )
        let contents = try RhythmicityExport.bundle(
            result: result,
            selection: selection,
            additionalWarnings: ["Fixture warning"],
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(Set(contents.files.keys) == [
            "manifest.json", "lavi.csv", "abba-bands.csv", "lavi.npy", "lavi-ribbon.npy", "warnings.txt",
        ])

        let manifest = try #require(contents.files["manifest.json"])
        let json = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        #expect(json["schema"] as? String == "org.nih.eva.rhythmicity")
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["samplingRateHz"] as? Double == samplingRate)
        #expect((json["frequenciesHz"] as? [Double]) == [8, 10, 12])
        let significance = try #require(json["significance"] as? [String: Any])
        #expect(significance["available"] as? Bool == false)

        let laviCSV = String(decoding: try #require(contents.files["lavi.csv"]), as: UTF8.self)
        #expect(laviCSV.contains("valid_pair_count,effective_duration_seconds"))
        #expect(laviCSV.components(separatedBy: "\n").count == 5)
        let abbaCSV = String(decoding: try #require(contents.files["abba-bands.csv"]), as: UTF8.self)
        #expect(abbaCSV.contains("peak_relative_lavi,significant,significance_margin"))

        let laviNPY = try #require(contents.files["lavi.npy"])
        #expect(Array(laviNPY.prefix(6)) == [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59])
        #expect(String(decoding: laviNPY.prefix(128), as: UTF8.self).contains("'shape': (1, 3)"))
        let ribbonNPY = try #require(contents.files["lavi-ribbon.npy"])
        #expect(String(decoding: ribbonNPY.prefix(128), as: UTF8.self).contains("'shape': (1, 2, 3)"))

        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("fixture-rhythmicity", isDirectory: true)
        try RhythmicityExport.write(contents, to: destination)
        #expect(contents.files.keys.allSatisfy {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path)
        })
    }
}
