//
//  EVAProcessingScriptXMLTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Covers the two provenance fields on `<evaProcessing>` — `fileType` (what EVA
//  wrote the package as) and `appVersion` (which build wrote it). Both are read
//  back by `MFFReader`/Dataset Info, so a serialization regression would be
//  invisible until someone needed the provenance months later.
//

import Testing
import Foundation
@testable import EVA

struct EVAProcessingScriptXMLTests {

    private func parse(_ script: EVAProcessingScript) throws -> EVAProcessingScript {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try EVAProcessingScriptXML.write(script, toPackage: url)
        guard let read = EVAProcessingScriptXML.read(fromPackage: url) else {
            Issue.record("eva.xml did not parse")
            return EVAProcessingScript()
        }
        return read
    }

    @Test func fileTypeRoundTrips() throws {
        var script = EVAProcessingScript()
        script.fileType = .averaged
        #expect(try parse(script).fileType == .averaged)
    }

    @Test func absentFileTypeStaysNil() throws {
        // Packages written before the field, or by other tools, must keep falling
        // back to detection rather than reading as some default kind.
        #expect(try parse(EVAProcessingScript()).fileType == nil)
    }

    @Test func appVersionIsAlwaysStamped() throws {
        let read = try parse(EVAProcessingScript())
        #expect(read.appVersion == EVAProcessingScriptXML.currentAppVersion)
        #expect(read.appVersion?.isEmpty == false)
    }

    /// A script replayed via Copy Processing carries the *source* package's
    /// version. Writing must stamp the build doing the writing, or the new file
    /// is attributed to a build that never touched it.
    @Test func writingOverwritesAnInheritedAppVersion() throws {
        var script = EVAProcessingScript()
        script.appVersion = "0.0.1 (ancient)"
        let read = try parse(script)
        #expect(read.appVersion == EVAProcessingScriptXML.currentAppVersion)
        #expect(read.appVersion != "0.0.1 (ancient)")
    }

    @Test func stepsAndParametersSurviveAlongsideTheNewAttributes() throws {
        var script = EVAProcessingScript()
        script.fileType = .segmented
        script.append(
            EVAProcessingStep(
                operation: .filter,
                parameters: ["highPassHz": "0.1", "lowPassHz": "30"],
                replayable: true
            )
        )
        let read = try parse(script)
        #expect(read.fileType == .segmented)
        #expect(read.steps.count == 1)
        #expect(read.steps.first?.operation == .filter)
        #expect(read.steps.first?.parameters["highPassHz"] == "0.1")
    }
}
