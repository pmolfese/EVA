//
//  BIDSCommon.swift
//  EVA BIDS
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Shared BIDS-EEG entity naming, TSV/JSON sidecar helpers, and channel-type
//  inference used by to-bids, from-bids, and inspect-bids.
//

import Foundation

struct BIDSEntities {
    var subject: String
    var session: String?
    var task: String
    var run: Int?

    var subjectDir: String { "sub-\(subject)" }
    var sessionDir: String? { session.map { "ses-\($0)" } }

    var stem: String {
        var parts = ["sub-\(subject)"]
        if let session { parts.append("ses-\(session)") }
        parts.append("task-\(task)")
        if let run { parts.append(String(format: "run-%02d", run)) }
        return parts.joined(separator: "_")
    }

    var eegDirectoryComponents: [String] {
        var comps = [subjectDir]
        if let sessionDir { comps.append(sessionDir) }
        comps.append("eeg")
        return comps
    }

    /// Parses entities out of a BIDS filename like
    /// `sub-01_ses-01_task-rest_run-02_eeg.edf`. Requires at least sub- and task-.
    static func parse(fromFileName fileName: String) -> BIDSEntities? {
        let stem = (fileName as NSString).deletingPathExtension
        let tokens = stem.split(separator: "_").map(String.init)
        var pairs: [String: String] = [:]
        for token in tokens {
            guard let dashIndex = token.firstIndex(of: "-") else { continue }
            let key = String(token[token.startIndex..<dashIndex])
            let value = String(token[token.index(after: dashIndex)...])
            pairs[key] = value
        }
        guard let subject = pairs["sub"], let task = pairs["task"] else { return nil }
        return BIDSEntities(
            subject: subject,
            session: pairs["ses"],
            task: task,
            run: pairs["run"].flatMap(Int.init)
        )
    }
}

enum ChannelType {
    /// Classifies a peripheral (PNS) channel by name for BIDS `_channels.tsv`.
    /// Falls back to MISC — never guesses ECG/EOG/etc. from a bare pattern
    /// match on ambiguous names.
    static func infer(fromPNSName name: String) -> String {
        let upper = name.uppercased()
        if upper.contains("ECG") || upper.contains("EKG") { return "ECG" }
        if upper.contains("EOG") { return "EOG" }
        if upper.contains("EMG") { return "EMG" }
        if upper.contains("RESP") { return "RESP" }
        if upper.contains("TEMP") { return "TEMP" }
        if upper.contains("GSR") || upper.contains("EDA") { return "GSR" }
        if upper.contains("TRIG") || upper.contains("STI") { return "TRIG" }
        return "MISC"
    }
}

enum TSV {
    static func write(headers: [String], rows: [[String]], to url: URL) throws {
        var lines = [headers.joined(separator: "\t")]
        lines.append(contentsOf: rows.map { $0.joined(separator: "\t") })
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Parses a TSV into header-keyed rows. BIDS uses "n/a" for missing values;
    /// callers get the raw string back and decide how to interpret "n/a".
    static func read(_ url: URL) throws -> [[String: String]] {
        let (_, rows) = try readWithHeaders(url)
        return rows
    }

    /// Same as `read`, but also returns the header row on its own — needed to
    /// check required columns on a TSV that has zero data rows (e.g. an empty
    /// events.tsv), where `read`'s row-keyed dictionaries would be empty too.
    static func readWithHeaders(_ url: URL) throws -> (headers: [String], rows: [[String: String]]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return ([], []) }
        let headers = lines.removeFirst().split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let rows = lines.map { line -> [String: String] in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            var row: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                row[header] = index < fields.count ? fields[index] : "n/a"
            }
            return row
        }
        return (headers, rows)
    }
}

enum BIDSJSON {
    static func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EVABIDSError.usage("\(url.lastPathComponent) is not a JSON object.")
        }
        return object
    }
}

enum EVABIDSError: LocalizedError {
    case usage(String)
    case helpRequested
    case notFound(URL)
    case ambiguous(String)
    case outputExists(URL)

    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        case .helpRequested: return nil
        case .notFound(let url): return "\(url.path) does not exist."
        case .ambiguous(let message): return message
        case .outputExists(let url): return "\(url.path) already exists. Pass --overwrite to replace it."
        }
    }
}

func writeStdout(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
func writeStdoutLine(_ text: String = "") { writeStdout(text + "\n") }
func writeStderr(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
func writeStderrLine(_ text: String = "") { writeStderr(text + "\n") }

func absoluteFileURL(_ path: String) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
        .standardizedFileURL
}

func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

func fileExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
}
