//
//  MarkdownView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Renders the blocks produced by `MarkdownDocument` as native SwiftUI. Text is
//  real `Text`, so it selects, scales, and picks up light/dark appearance the
//  way the rest of EVA does — none of which a `WKWebView` would give for free.
//

import SwiftUI

struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    init(markdown: String) {
        self.blocks = MarkdownDocument.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block)
                    .padding(.top, topPadding(for: block, isFirst: index == 0))
            }
        }
        .textSelection(.enabled)
    }

    /// Leading gap for each block. Headings get extra room above so sections
    /// read as sections, and the first block never gets any.
    private func topPadding(for block: MarkdownBlock, isFirst: Bool) -> CGFloat {
        guard !isFirst else { return 0 }
        switch block {
        case let .heading(level, _):
            return level <= 1 ? 26 : (level == 2 ? 22 : 16)
        case .thematicBreak:
            return 18
        default:
            return 10
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownInlineStyle.styled(text, base: Self.headingFont(level: level)))
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            Text(MarkdownInlineStyle.styled(text, base: .body))
                .fixedSize(horizontal: false, vertical: true)

        case let .codeBlock(_, code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25))
            )

        case let .blockQuote(children):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                MarkdownView(blocks: children)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .list(list):
            MarkdownListView(list: list)

        case let .table(table):
            MarkdownTableView(table: table)

        case .thematicBreak:
            Divider()
        }
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .system(.title, weight: .bold)
        case 2: return .system(.title2, weight: .bold)
        case 3: return .system(.title3, weight: .semibold)
        default: return .system(.headline, weight: .semibold)
        }
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(at: index))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        // Keeps the text edges of every item aligned regardless
                        // of whether the marker is "•" or "10.".
                        .frame(minWidth: 18, alignment: .trailing)
                    MarkdownView(blocks: item)
                }
            }
        }
        .padding(.leading, 6)
    }

    private func marker(at index: Int) -> String {
        list.isOrdered ? "\(list.startOrdinal + index)." : "•"
    }
}

/// Grid-based table. Uses `Grid` rather than `Table` because the content is
/// static formatted text, not a selectable/sortable data set.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 7) {
                if !table.header.isEmpty {
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(table.header[safe: column], base: .system(.body, weight: .semibold), column: column)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(row[safe: column], base: .body, column: column)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func cell(_ text: AttributedString?, base: Font, column: Int) -> some View {
        Text(MarkdownInlineStyle.styled(text ?? AttributedString(), base: base))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment(for: column))
    }

    private func alignment(for column: Int) -> Alignment {
        switch table.alignments[safe: column] ?? .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// Turns the parser's `inlinePresentationIntent` runs into concrete fonts.
///
/// SwiftUI applies some of these itself, but not consistently across every
/// intent, and headings need the traits composed onto a non-body base font —
/// so they are resolved explicitly here instead.
enum MarkdownInlineStyle {
    static func styled(_ text: AttributedString, base: Font) -> AttributedString {
        var result = text

        for run in result.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = base

            if intent.contains(.code) {
                font = font.monospaced()
            }
            if intent.contains(.stronglyEmphasized) {
                font = font.bold()
            }
            if intent.contains(.emphasized) {
                font = font.italic()
            }

            result[run.range].font = font

            if intent.contains(.strikethrough) {
                result[run.range].strikethroughStyle = .single
            }
            if run.link != nil {
                result[run.range].underlineStyle = .single
            }
        }

        return result
    }
}
