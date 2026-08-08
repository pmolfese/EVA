//
//  MarkdownDocument.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Block-level Markdown model, parsed with Foundation's own CommonMark/GFM
//  parser — no third-party dependency and no web view.
//
//  `AttributedString(markdown:options:)` with `interpretedSyntax: .full` does the
//  actual parsing: the result is a flat run sequence where every run carries a
//  `presentationIntent` describing the block path it sits under (innermost
//  first), e.g. a list item's text has `[paragraph, listItem 2, unorderedList]`.
//  All this file does is invert those paths into a tree the renderer can walk.
//  Headings, lists, block quotes, fenced code, thematic breaks, and GFM tables
//  all come through; nothing is hand-parsed.
//
//  Rendering lives in `MarkdownView`; the split is deliberate so the parse is
//  testable without a view.
//

import Foundation

/// One block-level element. Inline styling (bold/italic/code/links) stays inside
/// the `AttributedString` payloads and is turned into fonts by `MarkdownView`.
nonisolated enum MarkdownBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    /// Fenced or indented code. `language` is the info string, when given.
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
}

nonisolated struct MarkdownList: Equatable {
    var isOrdered: Bool
    /// Ordinal of the first item, so a list starting at `3.` renders as such.
    var startOrdinal: Int
    /// Each item is itself a block sequence — nested lists and multi-paragraph
    /// items fall out of this for free.
    var items: [[MarkdownBlock]]
}

nonisolated struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading, center, trailing
    }

    var alignments: [Alignment]
    var header: [AttributedString]
    var rows: [[AttributedString]]

    /// Column count taken from the widest row, since a malformed table can have
    /// a short row and the renderer still has to lay out a rectangle.
    var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }
}

nonisolated enum MarkdownDocument {

    /// Parses `markdown` into block elements.
    ///
    /// Uses `.returnPartiallyParsedIfPossible`, so malformed input degrades to
    /// plain text rather than throwing — a release note that fails to parse
    /// should still be readable.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return markdown.isEmpty ? [] : [.paragraph(AttributedString(markdown))]
        }

        let fragments = parsed.runs.map { run in
            // `components` is innermost-first; reversing gives a root-down path,
            // which is what the depth-indexed grouping below walks.
            Fragment(
                path: (run.presentationIntent?.components ?? []).reversed(),
                text: AttributedString(parsed[run.range])
            )
        }
        return blocks(fragments, depth: 0)
    }

    // MARK: - Grouping

    private struct Fragment {
        /// Block path from the root down, e.g. `[unorderedList, listItem, paragraph]`.
        var path: [PresentationIntent.IntentType]
        var text: AttributedString
    }

    /// Groups `fragments` by the intent identity at `depth` and turns each group
    /// into a block, recursing for container kinds.
    ///
    /// Identity (not kind) is what separates siblings: two consecutive
    /// paragraphs have the same kind and differ only by identity.
    private static func blocks(_ fragments: [Fragment], depth: Int) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var index = 0

        while index < fragments.count {
            guard depth < fragments[index].path.count else {
                // Text with no block intent left at this depth — shouldn't
                // happen for well-formed input, but emit it rather than drop it.
                let text = trimmed(fragments[index].text)
                if !text.characters.isEmpty { result.append(.paragraph(text)) }
                index += 1
                continue
            }

            let component = fragments[index].path[depth]
            var end = index + 1
            while end < fragments.count,
                  depth < fragments[end].path.count,
                  fragments[end].path[depth].identity == component.identity {
                end += 1
            }

            let group = Array(fragments[index..<end])
            if let block = block(for: component, group: group, depth: depth) {
                result.append(block)
            }
            index = end
        }

        return result
    }

    private static func block(
        for component: PresentationIntent.IntentType,
        group: [Fragment],
        depth: Int
    ) -> MarkdownBlock? {
        switch component.kind {
        case let .header(level):
            let text = trimmed(joined(group))
            return text.characters.isEmpty ? nil : .heading(level: level, text: text)

        case .paragraph:
            let text = trimmed(joined(group))
            return text.characters.isEmpty ? nil : .paragraph(text)

        case let .codeBlock(languageHint):
            // Code keeps its own whitespace; only the trailing newline every
            // fenced block carries is dropped.
            var code = String(joined(group).characters)
            while code.hasSuffix("\n") { code.removeLast() }
            return .codeBlock(language: languageHint, code: code)

        case .blockQuote:
            return .blockQuote(blocks(group, depth: depth + 1))

        case .unorderedList:
            let items = listItems(group, depth: depth + 1)
            guard !items.isEmpty else { return nil }
            return .list(MarkdownList(isOrdered: false, startOrdinal: 1, items: items.map(\.blocks)))

        case .orderedList:
            let items = listItems(group, depth: depth + 1)
            guard !items.isEmpty else { return nil }
            return .list(MarkdownList(
                isOrdered: true,
                startOrdinal: items.first?.ordinal ?? 1,
                items: items.map(\.blocks)
            ))

        case let .table(columns):
            return table(group, columns: columns, depth: depth)

        case .thematicBreak:
            // The parser substitutes a horizontal-bar character as the run's
            // text; the rule itself is what gets drawn, so the text is dropped.
            return .thematicBreak

        case .listItem, .tableRow, .tableHeaderRow, .tableCell:
            // Reachable only if a container is missing from the path; recursing
            // keeps the content rather than dropping it.
            return .paragraph(trimmed(joined(group)))

        @unknown default:
            let text = trimmed(joined(group))
            return text.characters.isEmpty ? nil : .paragraph(text)
        }
    }

    // MARK: - Lists

    private struct ListItem {
        var ordinal: Int
        var blocks: [MarkdownBlock]
    }

    /// Splits a list's fragments into its items. `depth` is the list-item level.
    private static func listItems(_ fragments: [Fragment], depth: Int) -> [ListItem] {
        var items: [ListItem] = []
        var index = 0

        while index < fragments.count {
            guard depth < fragments[index].path.count,
                  case let .listItem(ordinal) = fragments[index].path[depth].kind else {
                index += 1
                continue
            }

            let identity = fragments[index].path[depth].identity
            var end = index + 1
            while end < fragments.count,
                  depth < fragments[end].path.count,
                  fragments[end].path[depth].identity == identity {
                end += 1
            }

            items.append(ListItem(
                ordinal: ordinal,
                blocks: blocks(Array(fragments[index..<end]), depth: depth + 1)
            ))
            index = end
        }

        return items
    }

    // MARK: - Tables

    /// Assembles a table from its cell fragments. Rows sit at `depth + 1` and
    /// cells at `depth + 2`; cells carry no paragraph intent of their own.
    private static func table(
        _ fragments: [Fragment],
        columns: [PresentationIntent.TableColumn],
        depth: Int
    ) -> MarkdownBlock? {
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        var currentRow: [AttributedString] = []
        var currentRowIdentity: Int?
        var currentRowIsHeader = false

        func flushRow() {
            guard currentRowIdentity != nil else { return }
            if currentRowIsHeader {
                header = currentRow
            } else {
                rows.append(currentRow)
            }
            currentRow = []
            currentRowIdentity = nil
        }

        for fragment in fragments {
            guard depth + 1 < fragment.path.count else { continue }
            let rowComponent = fragment.path[depth + 1]
            let isHeader: Bool
            switch rowComponent.kind {
            case .tableHeaderRow: isHeader = true
            case .tableRow: isHeader = false
            default: continue
            }

            if rowComponent.identity != currentRowIdentity {
                flushRow()
                currentRowIdentity = rowComponent.identity
                currentRowIsHeader = isHeader
            }

            // Cells are keyed by column index, so a cell spanning several runs
            // (bold text inside a cell, say) appends rather than starting a new
            // column.
            guard depth + 2 < fragment.path.count,
                  case let .tableCell(columnIndex) = fragment.path[depth + 2].kind else { continue }
            while currentRow.count <= columnIndex {
                currentRow.append(AttributedString())
            }
            currentRow[columnIndex].append(fragment.text)
        }
        flushRow()

        guard !header.isEmpty || !rows.isEmpty else { return nil }

        let alignments = columns.map { column -> MarkdownTable.Alignment in
            switch column.alignment {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            @unknown default: return .leading
            }
        }

        return .table(MarkdownTable(
            alignments: alignments,
            header: header.map(trimmed),
            rows: rows.map { $0.map(trimmed) }
        ))
    }

    // MARK: - Text helpers

    private static func joined(_ fragments: [Fragment]) -> AttributedString {
        fragments.reduce(into: AttributedString()) { $0.append($1.text) }
    }

    /// Drops leading/trailing whitespace while keeping the attribute runs of
    /// what remains — `String` round-tripping would lose the inline styling.
    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var result = text
        while let first = result.characters.first, first.isWhitespace {
            result.removeSubrange(result.startIndex..<result.index(afterCharacter: result.startIndex))
        }
        while let last = result.characters.last, last.isWhitespace {
            let end = result.endIndex
            result.removeSubrange(result.index(beforeCharacter: end)..<end)
        }
        return result
    }
}
