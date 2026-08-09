//
//  ReleaseNotesCatalog.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Discovers the release-note documents bundled under `EVA/ReleaseNotes/` and
//  presents them newest-first for the Release Notes window.
//
//  Adding a release is dropping a `.md` file into that folder — there is no list
//  to update in code. Each file starts with a small front-matter block:
//
//      ---
//      version: 0.1.6
//      date: 2026-08-08
//      title: GPU acceleration and empirical Bayes wavelets
//      ---
//
//  `version` is required (it is what the list is keyed and sorted by); `date` and
//  `title` are optional. Ordering uses `AppVersion`, the same comparator the
//  update checker uses for GitHub tags, so `0.1.10` correctly follows `0.1.9`.
//

import Foundation

nonisolated struct ReleaseNote: Identifiable, Equatable {
    /// The raw version string as written in front matter, e.g. `0.1.6`.
    let version: String
    let title: String?
    let date: Date?
    /// Markdown body with the front matter removed.
    let body: String

    var id: String { version }

    var displayVersion: String {
        version.hasPrefix("v") ? version : "v\(version)"
    }

    var formattedDate: String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

nonisolated enum ReleaseNotesCatalog {
    static let resourceSubdirectory = "ReleaseNotes"

    /// Every bundled release note, newest first.
    ///
    /// A file that fails to parse (no `version` in its front matter) is skipped
    /// rather than crashing the window — a malformed note should cost that one
    /// entry, not the whole list.
    static func load(from bundle: Bundle = .main) -> [ReleaseNote] {
        notes(at: urls(in: bundle))
    }

    static func notes(at urls: [URL]) -> [ReleaseNote] {
        urls
            .compactMap { url -> ReleaseNote? in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return note(from: contents)
            }
            .sorted { left, right in
                // Unparseable versions sort last rather than being dropped, so a
                // typo'd version is visible in the UI and gets noticed.
                switch (AppVersion(left.version), AppVersion(right.version)) {
                case let (.some(a), .some(b)): return a > b
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return left.version > right.version
                }
            }
    }

    /// Bundled `.md` URLs. Checks the `ReleaseNotes` subdirectory first, then
    /// falls back to a flat scan — Xcode copies resources from synchronized
    /// folder groups without necessarily preserving the folder, and requiring
    /// front matter (below) keeps the flat scan from picking up unrelated
    /// markdown.
    static func urls(in bundle: Bundle) -> [URL] {
        let nested = bundle.urls(
            forResourcesWithExtension: "md",
            subdirectory: resourceSubdirectory
        ) ?? []
        if !nested.isEmpty { return nested }
        return bundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
    }

    // MARK: - Parsing

    /// Splits front matter from body and builds a note. Returns `nil` when there
    /// is no front matter or no `version` key.
    static func note(from contents: String) -> ReleaseNote? {
        let (metadata, body) = splitFrontMatter(contents)
        guard let version = metadata["version"], !version.isEmpty else { return nil }

        return ReleaseNote(
            version: version,
            title: metadata["title"].flatMap { $0.isEmpty ? nil : $0 },
            date: metadata["date"].flatMap(parseDate),
            body: body
        )
    }

    /// Front matter is a `---`-delimited block of `key: value` lines at the very
    /// top of the file. Anything else means "no front matter", and the whole
    /// input is the body.
    static func splitFrontMatter(_ contents: String) -> (metadata: [String: String], body: String) {
        var lines = contents.components(separatedBy: .newlines)
        // Tolerates a UTF-8 BOM or a stray blank first line.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let first = lines.first, isDelimiter(first) else {
            return ([:], contents)
        }

        var metadata: [String: String] = [:]
        var index = 1
        while index < lines.count, !isDelimiter(lines[index]) {
            let line = lines[index]
            if let separator = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<separator]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = line[line.index(after: separator)...]
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { metadata[key] = value }
            }
            index += 1
        }

        guard index < lines.count else {
            // Unterminated block — treat the file as having no front matter
            // rather than silently swallowing all of it.
            return ([:], contents)
        }

        let body = lines[(index + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (metadata, body)
    }

    private static func isDelimiter(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "---"
    }

    /// Accepts `YYYY-MM-DD`, which is what the front matter documents.
    static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}
