//
//  EVAProcessingScriptIOTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  eva.xml read/write: standalone-file and package readers round-trip a script
//  (Copy Processing accepts either a loose eva.xml or an MFF package).
//

import Testing
import Foundation
@testable import EVA

struct EVAProcessingScriptIOTests {

    private func sampleScript() -> EVAProcessingScript {
        var s = EVAProcessingScript()
        s.append(EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["method": "AAS", "windowBefore": "3"]))
        s.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "0.5", "lowPassHz": "40"]))
        return s
    }

    @Test func readsStandaloneEvaXMLFile() throws {
        let script = sampleScript()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-\(UUID().uuidString).xml")
        try EVAProcessingScriptXML.data(for: script).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = EVAProcessingScriptXML.read(fromFile: url)
        #expect(read?.steps.map(\.operation) == [.mriGradientCorrection, .filter])
        #expect(read?.steps.first?.parameters["method"] == "AAS")
        #expect(read?.steps.last?.parameters["lowPassHz"] == "40")
    }

    @Test func readFromFileResolvesPackageDirectory() throws {
        let script = sampleScript()
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).mff", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pkg) }
        try EVAProcessingScriptXML.write(script, toPackage: pkg)

        // read(fromFile:) on a directory should read its eva.xml, matching read(fromPackage:).
        let viaFile = EVAProcessingScriptXML.read(fromFile: pkg)
        let viaPackage = EVAProcessingScriptXML.read(fromPackage: pkg)
        #expect(viaFile?.steps.map(\.operation) == [.mriGradientCorrection, .filter])
        #expect(viaFile?.steps.map(\.operation) == viaPackage?.steps.map(\.operation))
    }

    @Test func missingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).xml")
        #expect(EVAProcessingScriptXML.read(fromFile: url) == nil)
    }
}
