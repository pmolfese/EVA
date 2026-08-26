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
    enum Operation: String, Codable, Sendable, CaseIterable {
        case filter
        case reference
        case mriGradientCorrection
        case waveletReduce
        case artifactClean
        case thresholdArtifactDetection
        case icaClean
        case bcgDetection
        case ecgDetection
        case interpolateChannels
        case markBad
        case segment
        case baseline
        case average
        case combine
        case combineBadChannelPolicy
        case split
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

/// How a captured step behaves during interactive replay.
nonisolated enum ReplayInteraction: Equatable {
    /// Portable — applied automatically with no pause (filter, threshold detection).
    case auto
    /// Applied automatically, but pauses first so the user can review/edit its
    /// parameters in the existing panel (MRI gradient — TR-skip/motion/window).
    case review
    /// Requires a human decision: an automated part runs, then replay pauses for
    /// the user to make a subject-specific choice (ICA component removal).
    case decision
    /// Applied automatically **because the target file's own record supplies
    /// what the step needs** — the ICA operator in its `eva_ica.json`, the drawn
    /// artifact definitions in its artifact sidecar. Subject-specific by
    /// classification, already-decided in fact, so nothing is asked and nothing
    /// is carried across subjects.
    ///
    /// This is the third state between "portable" and "subject-specific", and it
    /// is a property of *(operation, what this file carries)* rather than of the
    /// operation alone — which is why it only exists on
    /// `replayInteraction(given:)` and never on the plain classification
    /// (ROADMAP RW-1 item 6).
    case resolvedFromPayload
    /// Not replayable and not surfaced as a pause.
    case skip
}

/// What a *particular* file brings to a replay, beyond the script.
///
/// Payload availability is per-file and must be read from the file being
/// processed, never from the file the script came from: an ICA operator belongs
/// to one subject's electrodes and a drawn template to one subject's blink. A
/// script copied from another subject arrives with none of this, and every
/// subject-specific step correctly stays a decision.
nonisolated struct ReplayPayloadAvailability: Equatable, Sendable {
    /// This file has its own `eva_ica.json`.
    var hasICAPayload = false
    /// This file has its own drawn-artifact payload.
    var hasArtifactPayload = false
    /// This file has electrode coordinates, so a recorded interpolation can be
    /// re-solved for it (`ChannelInterpolationSolver`).
    var hasElectrodeGeometry = false

    /// What a plain script read tells you: nothing about any file.
    static let none = ReplayPayloadAvailability()
}

extension EVAProcessingStep {
    /// Pure classification of this step for the interactive replay engine,
    /// knowing nothing about the file it will be applied to.
    ///
    /// Prefer `replayInteraction(given:)` wherever the target file is known —
    /// this one has to assume the worst, so it reports the subject-specific
    /// steps as `.skip`/`.decision` even when the file could resolve them.
    var replayInteraction: ReplayInteraction {
        guard replayable else { return .skip }
        switch operation {
        // `.reference`/`.baseline` carry portable settings (reference type,
        // baseline window), not a subject-specific result the way ICA
        // component choice or a drawn artifact template is — same category
        // as filter/threshold/segment/wavelet, not the `.skip` default
        // (2026-08-15, confirmed against a batch run misclassifying both).
        case .filter, .thresholdArtifactDetection, .segment, .waveletReduce,
             .reference, .baseline: return .auto
        case .mriGradientCorrection: return .review
        case .icaClean, .artifactClean: return .decision
        default: return .skip
        }
    }

    /// Classification for a *specific* file, given what that file carries.
    ///
    /// Three rules, each of which used to live somewhere it could not be reused
    /// or tested (ROADMAP RW-1 item 6):
    ///
    /// 1. **ICA and artifact cleaning become `.resolvedFromPayload`** when the
    ///    file has its own sidecar. `BatchSetupSheet` worked this out privately
    ///    to label a row and, separately, to decide whether a batch could run
    ///    headlessly — while `ProcessingCore` worked it out a third time from
    ///    the payload arguments it was handed. Same rule, three copies.
    /// 2. **Channel decisions become `.decision`**, not `.skip`. `markBad` and
    ///    `interpolateChannels` describe *this* subject's electrodes, so
    ///    carrying them onto another file is a choice a person has to make —
    ///    and today headless batch applied the source's bad-channel list to
    ///    every file while windowed replay ignored it entirely, which is the
    ///    divergence rather than either answer. Interpolation additionally
    ///    needs geometry to re-solve against; without it there is nothing to
    ///    offer, so it stays `.skip`.
    /// 3. Everything else classifies exactly as it does without a file.
    func replayInteraction(given availability: ReplayPayloadAvailability) -> ReplayInteraction {
        switch operation {
        case .icaClean where availability.hasICAPayload:
            return .resolvedFromPayload
        case .artifactClean where availability.hasArtifactPayload:
            return .resolvedFromPayload
        case .markBad:
            return .decision
        case .interpolateChannels:
            return availability.hasElectrodeGeometry ? .decision : .skip
        default:
            return replayInteraction
        }
    }
}

/// An ordered list of processing steps — the shared abstraction behind both
/// `eva.xml` persistence and the future replay ("Copy Processing From…") engine.
nonisolated struct EVAProcessingScript: Codable, Sendable {
    var version: Int = 1
    /// What EVA wrote this package as — the authoritative record of the file's
    /// kind, independent of any inference from `categories.xml`/`epochs.xml`.
    ///
    /// Detection from the EGI structure is heuristic (it reads `#seg` counts and
    /// `<name>Average</name>` markers, with a legacy fallback), and a package
    /// written by another tool, hand-edited, or produced by an unusual import can
    /// defeat it. When EVA itself wrote the file it *knows* the answer, so it
    /// records it here and the reader trusts it over the heuristic.
    ///
    /// Optional because packages written before this field, or by other tools,
    /// won't have it — those still fall back to detection.
    var fileType: MFFFileType?
    /// EVA build that wrote this package, e.g. `"0.1.6 (142)"`.
    ///
    /// Provenance, not configuration: when a result looks wrong months later, the
    /// first question is which build produced it, and that is not recoverable
    /// from the samples.
    ///
    /// Populated on *read* with whatever wrote that package. Writing always
    /// stamps `currentAppVersion` instead of echoing this — a script replayed via
    /// Copy Processing carries the *source* package's version, and preserving it
    /// would misattribute the new file to a build that never touched it.
    var appVersion: String?
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

    /// This build, as `"<short version> (<build>)"`. Resolved once — the bundle
    /// cannot change while the app is running.
    static let currentAppVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }()

    static func data(for script: EVAProcessingScript) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <evaProcessing version="\(script.version)" appName="EVA" appVersion="\(escape(currentAppVersion))" writtenAt="\(iso(Date()))"\(script.fileType.map { " fileType=\"\($0.rawValue)\"" } ?? "")>

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
        read(fromFile: packageURL.appendingPathComponent(fileName))
    }

    /// Reads a script from a standalone `eva.xml` (or MFF package directory)
    /// chosen by the user. If `url` is a package directory, its `eva.xml` is read.
    static func read(fromFile url: URL) -> EVAProcessingScript? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            // A package/directory was picked — read its eva.xml.
            return parse(fileURL: url.appendingPathComponent(fileName))
        }
        return parse(fileURL: url)
    }

    private static func parse(fileURL url: URL) -> EVAProcessingScript? {
        guard let data = try? Data(contentsOf: url),
              let doc = try? XMLDocument(data: data),
              let root = doc.rootElement() else { return nil }

        var script = EVAProcessingScript()
        script.version = Int(root.attribute(forName: "version")?.stringValue ?? "1") ?? 1
        script.fileType = root.attribute(forName: "fileType")?.stringValue
            .flatMap(MFFFileType.init(rawValue:))
        script.appVersion = root.attribute(forName: "appVersion")?.stringValue

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
