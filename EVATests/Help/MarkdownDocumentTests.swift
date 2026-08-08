//
//  MarkdownDocumentTests.swift
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

@Suite("Markdown document")
struct MarkdownDocumentTests {

    // MARK: - Helpers

    private func plainText(_ block: MarkdownBlock?) -> String? {
        switch block {
        case let .heading(_, text): return String(text.characters)
        case let .paragraph(text): return String(text.characters)
        case let .codeBlock(_, code): return code
        default: return nil
        }
    }

    // MARK: - Blocks

    @Test("Headings keep their level and text")
    func headingsKeepLevel() {
        let blocks = MarkdownDocument.parse("# Title\n\n### Third\n")

        guard case let .heading(level, text) = blocks.first else {
            Issue.record("Expected a heading, got \(String(describing: blocks.first))")
            return
        }
        #expect(level == 1)
        #expect(String(text.characters) == "Title")

        guard case let .heading(thirdLevel, _) = blocks.last else {
            Issue.record("Expected a heading")
            return
        }
        #expect(thirdLevel == 3)
    }

    @Test("Consecutive paragraphs stay separate blocks")
    func paragraphsStaySeparate() {
        let blocks = MarkdownDocument.parse("First para.\n\nSecond para.\n")

        #expect(blocks.count == 2)
        #expect(plainText(blocks.first) == "First para.")
        #expect(plainText(blocks.last) == "Second para.")
    }

    @Test("Inline emphasis is preserved as attributes, not literal markers")
    func inlineEmphasisPreserved() {
        let blocks = MarkdownDocument.parse("Some **bold** and `code` here.")

        guard case let .paragraph(text) = blocks.first else {
            Issue.record("Expected a paragraph")
            return
        }
        // The asterisks and backticks are consumed by the parser.
        #expect(String(text.characters) == "Some bold and code here.")

        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains { $0.contains(.stronglyEmphasized) })
        #expect(intents.contains { $0.contains(.code) })
    }

    @Test("Links survive parsing")
    func linksSurvive() {
        let blocks = MarkdownDocument.parse("See [the docs](https://example.org/x).")

        guard case let .paragraph(text) = blocks.first else {
            Issue.record("Expected a paragraph")
            return
        }
        let links = text.runs.compactMap(\.link)
        #expect(links.map(\.absoluteString) == ["https://example.org/x"])
    }

    @Test("Unordered list items become one list block")
    func unorderedList() {
        let blocks = MarkdownDocument.parse("- alpha\n- beta\n- gamma\n")

        guard case let .list(list) = blocks.first else {
            Issue.record("Expected a list, got \(String(describing: blocks.first))")
            return
        }
        #expect(list.isOrdered == false)
        #expect(list.items.count == 3)
        #expect(plainText(list.items[1].first) == "beta")
    }

    @Test("Ordered lists record their starting ordinal")
    func orderedListStartOrdinal() {
        let blocks = MarkdownDocument.parse("3. three\n4. four\n")

        guard case let .list(list) = blocks.first else {
            Issue.record("Expected a list")
            return
        }
        #expect(list.isOrdered)
        #expect(list.startOrdinal == 3)
        #expect(list.items.count == 2)
    }

    @Test("Nested lists nest inside their parent item")
    func nestedLists() {
        let blocks = MarkdownDocument.parse("- outer\n    - inner one\n    - inner two\n")

        guard case let .list(list) = blocks.first else {
            Issue.record("Expected a list")
            return
        }
        #expect(list.items.count == 1)

        let nested = list.items[0].compactMap { block -> MarkdownList? in
            if case let .list(inner) = block { return inner }
            return nil
        }
        #expect(nested.first?.items.count == 2)
    }

    @Test("Fenced code keeps its language hint and interior whitespace")
    func fencedCode() {
        let blocks = MarkdownDocument.parse("```swift\nlet x = 1\n    let y = 2\n```\n")

        guard case let .codeBlock(language, code) = blocks.first else {
            Issue.record("Expected a code block, got \(String(describing: blocks.first))")
            return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1\n    let y = 2")
    }

    @Test("Block quotes contain their own blocks")
    func blockQuotes() {
        let blocks = MarkdownDocument.parse("> quoted line\n")

        guard case let .blockQuote(children) = blocks.first else {
            Issue.record("Expected a block quote")
            return
        }
        #expect(plainText(children.first) == "quoted line")
    }

    @Test("Thematic breaks carry no text")
    func thematicBreaks() {
        let blocks = MarkdownDocument.parse("above\n\n---\n\nbelow\n")

        #expect(blocks.contains { $0 == .thematicBreak })
        // The horizontal-bar placeholder the parser emits must not leak into a
        // paragraph.
        #expect(!blocks.contains { plainText($0)?.contains("\u{2E3A}") == true })
    }

    // MARK: - Tables

    @Test("Tables parse into header and rows")
    func tables() {
        let markdown = """
        | Suite | Lines |
        |---|---|
        | Alpha | 328 |
        | Beta | 95 |
        """
        let blocks = MarkdownDocument.parse(markdown)

        guard case let .table(table) = blocks.first else {
            Issue.record("Expected a table, got \(String(describing: blocks.first))")
            return
        }
        #expect(table.header.map { String($0.characters) } == ["Suite", "Lines"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0].map { String($0.characters) } == ["Alpha", "328"])
        #expect(table.columnCount == 2)
    }

    @Test("Table column alignments are carried through")
    func tableAlignments() {
        let markdown = """
        | L | C | R |
        |:--|:-:|--:|
        | 1 | 2 | 3 |
        """
        guard case let .table(table) = MarkdownDocument.parse(markdown).first else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing])
    }

    @Test("A styled cell stays in one column")
    func tableCellWithInlineStyling() {
        let markdown = """
        | Name | Note |
        |---|---|
        | **bold** name | plain |
        """
        guard case let .table(table) = MarkdownDocument.parse(markdown).first else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.rows[0].count == 2)
        #expect(String(table.rows[0][0].characters) == "bold name")
    }

    // MARK: - Robustness

    @Test("Empty input produces no blocks")
    func emptyInput() {
        #expect(MarkdownDocument.parse("").isEmpty)
    }

    @Test("Plain text with no markup is a single paragraph")
    func plainTextInput() {
        let blocks = MarkdownDocument.parse("just some words")
        #expect(blocks.count == 1)
        #expect(plainText(blocks.first) == "just some words")
    }

    @Test("A full release note parses without losing sections")
    func fullDocument() {
        let markdown = """
        # EVA 0.1.6

        Intro paragraph with **emphasis**.

        ## Wavelets

        - one
        - two

        > A caution.

        | A | B |
        |---|---|
        | 1 | 2 |

        ## Licensing

        Closing paragraph.
        """
        let blocks = MarkdownDocument.parse(markdown)

        let headings = blocks.compactMap { block -> String? in
            if case let .heading(_, text) = block { return String(text.characters) }
            return nil
        }
        #expect(headings == ["EVA 0.1.6", "Wavelets", "Licensing"])
        #expect(blocks.contains { if case .table = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .list = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .blockQuote = $0 { return true } else { return false } })
    }
}
