//
//  MFFExportWriterTests.swift
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
import Testing
@testable import EVA

@MainActor
struct MFFExportWriterTests {
    @Test(arguments: ["processed", "processed.raw", "processed.mff", "processed.MFF"])
    func exportKeepsProcessingRecordInsideActualPackage(name: String) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let signal = MFFSignalData(
            signalURL: folder.appendingPathComponent("source.raw"),
            signalType: "EEG", numberOfChannels: 1, samplingRate: 10,
            duration: 1, recordingStartTime: nil, events: [],
            data: [Array(0..<10).map(Float.init)]
        )
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["method": "AAS"]))
        script.append(EVAProcessingStep(operation: .bcgDetection, parameters: [:], replayable: false))
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "0.5"]))

        let requestedURL = folder.appendingPathComponent(name)
        let packageURL = name.lowercased().hasSuffix(".mff")
            ? requestedURL : requestedURL.appendingPathExtension("mff")
        let result = await MFFExportWriter.write(
            snapshot: MFFExportSnapshot(signal: signal, segments: [], kind: .continuous),
            pnsSignal: nil, script: script, to: requestedURL
        )
        let outputURL = try result.get()
        #expect(outputURL == packageURL)
        let saved = try #require(EVAProcessingScriptXML.read(fromPackage: packageURL))
        #expect(saved.steps.map(\.operation) == script.steps.map(\.operation))
        #expect(saved.steps.first?.parameters["method"] == "AAS")
        #expect(saved.fileType == .continuous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: packageURL.path)
            .contains { $0.hasPrefix("log_eva_") })
        #expect(try MFFReader().loadSignal(from: packageURL).data == signal.data)
    }
}
