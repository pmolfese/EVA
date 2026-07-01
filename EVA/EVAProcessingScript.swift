//
//  EVAProcessingScript.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A declarative, replayable record of the processing EVA applied to a
//  recording, serialized to `eva.xml` inside the MFF package. Distinct from the
//  append-only `log_eva_*.txt` audit trail: this is the minimal current-state
//  script that "Copy Processing From…" and multi-file combine can re-apply.
//

import Foundation

/// Per-category trial-rejection record attached to an `average` step: how many
/// trials were available, how many survived into the average, and why the rest
/// were excluded. Only present when EVA (or an upstream tool that wrote eva.xml)
/// performed the rejection — a plain MFF average records only the survivors.
nonisolated struct CategoryRejection: Codable, Sendable, Hashable {
    var category: String
    var total: Int
    var included: Int
    /// Reason code → count (freeform for now; may be canonicalized later).
    var reasons: [String: Int] = [:]

    var excluded: Int { max(total - included, 0) }
}

/// One processing operation with typed string parameters.
nonisolated struct EVAProcessingStep: Codable, Identifiable, Sendable, Hashable {
    enum Operation: String, Codable, Sendable {
        case filter
        case reference
        case mriGradientCorrection
        case waveletReduce
        case artifactClean
        case icaClean
        case bcgDetection
        case ecgDetection
        case interpolateChannels
        case markBad
        case segment
        case baseline
        case average
        case combine
    }

    var id: UUID = UUID()
    var operation: Operation
    /// Portable operation parameters (e.g. `highPassHz` → `"0.1"`).
    var parameters: [String: String] = [:]
    /// False when the step encodes a subject-specific *result* (e.g. which ICA
    /// components were removed) rather than portable settings. Non-replayable
    /// steps are recorded for provenance but skipped by Copy Processing.
    var replayable: Bool = true
    /// Optional human-readable note (shown in the copy-processing checklist).
    var note: String?
    /// Per-category trial rejection, for `average` steps. Empty otherwise.
    var rejections: [CategoryRejection] = []
    var appliedAt: Date = Date()
}

/// An ordered list of processing steps — the shared abstraction behind both
/// `eva.xml` persistence and the future replay ("Copy Processing From…") engine.
nonisolated struct EVAProcessingScript: Codable, Sendable {
    var version: Int = 1
    var steps: [EVAProcessingStep] = []

    mutating func append(_ step: EVAProcessingStep) {
        steps.append(step)
    }

    var replayableSteps: [EVAProcessingStep] {
        steps.filter(\.replayable)
    }
}

// MARK: - eva.xml serialization

nonisolated enum EVAProcessingScriptXML {
    static let fileName = "eva.xml"

    static func data(for script: EVAProcessingScript) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <evaProcessing version="\(script.version)" appName="EVA" writtenAt="\(iso(Date()))">

        """
        for step in script.steps {
            xml += "  <step op=\"\(step.operation.rawValue)\" replayable=\"\(step.replayable)\" appliedAt=\"\(iso(step.appliedAt))\">\n"
            for key in step.parameters.keys.sorted() {
                xml += "    <param key=\"\(escape(key))\">\(escape(step.parameters[key] ?? ""))</param>\n"
            }
            if let note = step.note, !note.isEmpty {
                xml += "    <note>\(escape(note))</note>\n"
            }
            for r in step.rejections {
                xml += "    <category name=\"\(escape(r.category))\" total=\"\(r.total)\" included=\"\(r.included)\">\n"
                for reason in r.reasons.keys.sorted() {
                    xml += "      <reason code=\"\(escape(reason))\" count=\"\(r.reasons[reason] ?? 0)\"/>\n"
                }
                xml += "    </category>\n"
            }
            xml += "  </step>\n"
        }
        xml += "</evaProcessing>\n"
        return Data(xml.utf8)
    }

    /// Writes `eva.xml` into an MFF package directory.
    static func write(_ script: EVAProcessingScript, toPackage packageURL: URL) throws {
        let url = packageURL.appendingPathComponent(fileName)
        try data(for: script).write(to: url, options: .atomic)
    }

    /// Reads `eva.xml` from an MFF package directory, if present.
    static func read(fromPackage packageURL: URL) -> EVAProcessingScript? {
        let url = packageURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let doc = try? XMLDocument(data: data),
              let root = doc.rootElement() else { return nil }

        var script = EVAProcessingScript()
        script.version = Int(root.attribute(forName: "version")?.stringValue ?? "1") ?? 1

        for node in root.elements(forName: "step") {
            guard let opRaw = node.attribute(forName: "op")?.stringValue,
                  let op = EVAProcessingStep.Operation(rawValue: opRaw) else { continue }
            var params: [String: String] = [:]
            for p in node.elements(forName: "param") {
                if let key = p.attribute(forName: "key")?.stringValue {
                    params[key] = p.stringValue ?? ""
                }
            }
            let replayable = (node.attribute(forName: "replayable")?.stringValue ?? "true") == "true"
            let note = node.elements(forName: "note").first?.stringValue

            var rejections: [CategoryRejection] = []
            for cat in node.elements(forName: "category") {
                guard let name = cat.attribute(forName: "name")?.stringValue else { continue }
                let total = Int(cat.attribute(forName: "total")?.stringValue ?? "0") ?? 0
                let included = Int(cat.attribute(forName: "included")?.stringValue ?? "0") ?? 0
                var reasons: [String: Int] = [:]
                for reason in cat.elements(forName: "reason") {
                    if let code = reason.attribute(forName: "code")?.stringValue {
                        reasons[code] = Int(reason.attribute(forName: "count")?.stringValue ?? "0") ?? 0
                    }
                }
                rejections.append(CategoryRejection(category: name, total: total, included: included, reasons: reasons))
            }

            script.append(EVAProcessingStep(
                operation: op,
                parameters: params,
                replayable: replayable,
                note: note,
                rejections: rejections
            ))
        }
        return script
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
