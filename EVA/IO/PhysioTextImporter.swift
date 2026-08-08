//
//  PhysioTextImporter.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Parses plain-text physio exports for File → Import Physio: GE scanner logs
//  (one sample per line, no header, no timebase) and delimited multi-column
//  exports (e.g. Biopac text export, optionally with a header row and/or a
//  leading time column). No sample rate is ever assumed for a headerless,
//  single-column file — the caller must ask the user, since the format alone
//  doesn't carry one.
//

import Foundation

/// One physio channel decoded from an imported file, before trimming/resampling.
nonisolated struct ImportedPhysioChannel: Sendable, Identifiable {
    let id = UUID()
    var name: String
    var samples: [Float]
}

/// Result of parsing one imported physio file.
nonisolated struct PhysioTextImportResult: Sendable {
    var channels: [ImportedPhysioChannel]
    /// Sampling rate in Hz, populated only when confidently derived from a
    /// leading time column. `nil` for headerless files with no embedded
    /// timebase (e.g. GE scanner logs) — the caller must ask the user.
    var detectedSamplingRateHz: Double?
}

enum PhysioTextImportError: LocalizedError {
    case unreadable
    case empty
    case raggedRows(lineNumber: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Could not read this file as text."
        case .empty: return "This file has no numeric data."
        case .raggedRows(let line): return "Line \(line) has a different number of columns than the rest of the file."
        }
    }
}

enum PhysioTextImporter {
    static func parse(contentsOf url: URL) throws -> PhysioTextImportResult {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw PhysioTextImportError.unreadable
        }
        return try parse(text: text, suggestedName: channelNameHeuristic(fromFileName: url.lastPathComponent))
    }

    static func parse(text: String, suggestedName: String) throws -> PhysioTextImportResult {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstLine = lines.first else { throw PhysioTextImportError.empty }

        let delimiter = detectDelimiter(in: firstLine)
        var rows = lines.map { splitRow($0, delimiter: delimiter) }

        // A header row is present if the first row's cells aren't all numeric.
        var header: [String]?
        if !rows[0].allSatisfy({ Double($0) != nil }) {
            header = rows[0]
            rows.removeFirst()
        }
        guard let columnCount = rows.first?.count else { throw PhysioTextImportError.empty }

        for (i, row) in rows.enumerated() where row.count != columnCount {
            throw PhysioTextImportError.raggedRows(lineNumber: i + (header == nil ? 1 : 2))
        }

        var columns = Array(repeating: [Float](), count: columnCount)
        for i in columns.indices { columns[i].reserveCapacity(rows.count) }
        for row in rows {
            for (c, cell) in row.enumerated() {
                columns[c].append(Float(cell) ?? .nan)
            }
        }

        // A leading time column: strictly increasing and evenly spaced, i.e.
        // it reads like a clock rather than a physiological signal.
        var dataColumns = columns
        var detectedRate: Double?
        var channelNames = header
        if columnCount > 1, isUniformTimeAxis(columns[0]) {
            detectedRate = inferredSamplingRate(fromTimeAxis: columns[0])
            dataColumns.removeFirst()
            if var names = channelNames, !names.isEmpty {
                names.removeFirst()
                channelNames = names
            }
        }

        let resolvedNames: [String]
        if let channelNames, channelNames.count == dataColumns.count {
            resolvedNames = channelNames
        } else if dataColumns.count == 1 {
            resolvedNames = [suggestedName]
        } else {
            resolvedNames = (0..<dataColumns.count).map { "\(suggestedName) \($0 + 1)" }
        }

        let channels = zip(resolvedNames, dataColumns).map { ImportedPhysioChannel(name: $0, samples: $1) }
        return PhysioTextImportResult(channels: channels, detectedSamplingRateHz: detectedRate)
    }

    /// Guesses a channel name from a filename like `PPGData_...` or
    /// `RESPData_...` (GE scanner physio log convention). Falls back to the
    /// leading run of letters, then the whole base name.
    static func channelNameHeuristic(fromFileName fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let knownPrefixes = ["PPG", "RESP", "ECG", "EMG", "EDA", "GSR", "PULSE", "TRIG", "CO2", "SPO2"]
        let upper = base.uppercased()
        for prefix in knownPrefixes where upper.hasPrefix(prefix) {
            return prefix
        }
        let letters = base.prefix { $0.isLetter }
        return letters.isEmpty ? base : String(letters)
    }

    // MARK: - Parsing helpers

    private static func detectDelimiter(in line: String) -> Character? {
        if line.contains("\t") { return "\t" }
        if line.contains(",") { return "," }
        return nil   // whitespace-run delimited (or a single value per line)
    }

    private static func splitRow(_ line: String, delimiter: Character?) -> [String] {
        guard let delimiter else {
            return line.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return line.split(separator: delimiter, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// True when `column` reads like a clock: strictly increasing with a
    /// tight coefficient of variation on the sample-to-sample deltas.
    private static func isUniformTimeAxis(_ column: [Float]) -> Bool {
        guard column.count > 3 else { return false }
        var deltas: [Float] = []
        deltas.reserveCapacity(column.count - 1)
        for i in 1..<column.count {
            let d = column[i] - column[i - 1]
            guard d > 0, d.isFinite else { return false }
            deltas.append(d)
        }
        let mean = deltas.reduce(0, +) / Float(deltas.count)
        guard mean > 0 else { return false }
        let variance = deltas.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(deltas.count)
        return variance.squareRoot() / mean < 0.05
    }

    /// Derives a sampling rate from a detected time column, in Hz. Returns
    /// `nil` when the deltas are ≈1 (a plain sample-index counter, which
    /// implies no rate by itself).
    private static func inferredSamplingRate(fromTimeAxis column: [Float]) -> Double? {
        guard column.count > 1 else { return nil }
        let meanDelta = Double(column[column.count - 1] - column[0]) / Double(column.count - 1)
        guard meanDelta > 0, abs(meanDelta - 1) > 1e-6 else { return nil }
        return 1.0 / meanDelta
    }
}
