//
//  ReleaseNotesCatalogTests.swift
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

@Suite("Release notes catalog")
struct ReleaseNotesCatalogTests {

    private func note(version: String, title: String = "Title", date: String = "2026-01-01", body: String = "Body.") -> String {
        """
        ---
        version: \(version)
        date: \(date)
        title: \(title)
        ---

        \(body)
        """
    }

    // MARK: - Front matter

    @Test("Front matter is parsed and stripped from the body")
    func frontMatterParsed() {
        let parsed = ReleaseNotesCatalog.note(from: note(
            version: "0.1.6",
            title: "GPU acceleration",
            date: "2026-08-08",
            body: "# Heading\n\nSome text."
        ))

        #expect(parsed?.version == "0.1.6")
        #expect(parsed?.title == "GPU acceleration")
        #expect(parsed?.body == "# Heading\n\nSome text.")
        // The delimiters must not survive into the body, or they render as a
        // stray horizontal rule.
        #expect(parsed?.body.contains("---") == false)
    }

    @Test("A note without a version is rejected")
    func versionIsRequired() {
        let contents = """
        ---
        title: Nameless
        ---

        Body.
        """
        #expect(ReleaseNotesCatalog.note(from: contents) == nil)
    }

    @Test("A file with no front matter is rejected rather than half-parsed")
    func noFrontMatter() {
        #expect(ReleaseNotesCatalog.note(from: "# Just a document\n\nText.") == nil)
    }

    @Test("An unterminated front-matter block does not swallow the document")
    func unterminatedFrontMatter() {
        let contents = """
        ---
        version: 0.1.6

        Body that never closes the block.
        """
        let (metadata, body) = ReleaseNotesCatalog.splitFrontMatter(contents)
        #expect(metadata.isEmpty)
        #expect(body == contents)
    }

    @Test("Title and date are optional")
    func optionalMetadata() {
        let contents = """
        ---
        version: 0.1.4
        ---

        Body.
        """
        let parsed = ReleaseNotesCatalog.note(from: contents)
        #expect(parsed?.version == "0.1.4")
        #expect(parsed?.title == nil)
        #expect(parsed?.date == nil)
        #expect(parsed?.formattedDate == nil)
    }

    @Test("Dates parse as YYYY-MM-DD in a fixed calendar")
    func dateParsing() {
        let date = ReleaseNotesCatalog.parseDate("2026-08-08")
        #expect(date != nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date!)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 8)

        #expect(ReleaseNotesCatalog.parseDate("08/08/2026") == nil)
    }

    // MARK: - Ordering

    @Test("Notes are ordered newest version first")
    func ordering() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately includes a two-digit patch, which a plain string sort
        // would place before 0.1.9.
        for version in ["0.1.6", "0.1.10", "0.1.9", "0.2.0"] {
            try note(version: version).write(
                to: directory.appendingPathComponent("\(version).md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let notes = ReleaseNotesCatalog.notes(at: urls)

        #expect(notes.map(\.version) == ["0.2.0", "0.1.10", "0.1.9", "0.1.6"])
    }

    @Test("Unparseable files are skipped, not fatal")
    func malformedFilesSkipped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try note(version: "0.1.6").write(
            to: directory.appendingPathComponent("good.md"),
            atomically: true,
            encoding: .utf8
        )
        try "no front matter here".write(
            to: directory.appendingPathComponent("bad.md"),
            atomically: true,
            encoding: .utf8
        )

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(ReleaseNotesCatalog.notes(at: urls).map(\.version) == ["0.1.6"])
    }

    @Test("Display version is prefixed with v exactly once")
    func displayVersion() {
        #expect(ReleaseNotesCatalog.note(from: note(version: "0.1.6"))?.displayVersion == "v0.1.6")
        #expect(ReleaseNotesCatalog.note(from: note(version: "v0.1.6"))?.displayVersion == "v0.1.6")
    }

    // MARK: - Bundled content

    @Test("The bundled release notes load and render")
    func bundledNotesLoad() throws {
        // The app bundle, not the test bundle — this is the check that the
        // markdown actually ships inside EVA.app.
        let bundle = Bundle(for: BundleMarker.self)
        let appBundle = Bundle(url: bundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("EVA.app")) ?? Bundle.main

        let notes = ReleaseNotesCatalog.load(from: appBundle)
        try #require(!notes.isEmpty, "No release notes were bundled — check the Copy Bundle Resources phase.")

        for note in notes {
            #expect(AppVersion(note.version) != nil, "Unparseable version \(note.version)")
            #expect(!MarkdownDocument.parse(note.body).isEmpty, "\(note.version) rendered no blocks")
        }
    }
}

/// Anchor for locating the test bundle.
private final class BundleMarker {}
