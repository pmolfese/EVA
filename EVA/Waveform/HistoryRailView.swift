//
//  HistoryRailView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The history rail from `REWIND.md` — the trunk, the current-node highlight,
//  and each node's defining parameters. Read-only for now: it renders the chain
//  that produced the signal on screen, and clicking a node does not yet navigate.
//
//  **These are the rail's contents, not a panel.** The rail is presented inside
//  the status popover's History tab (`ProcessingStatusPopover.swift`), which is
//  where the chrome — footer, node count, short id — lives. It began as a
//  sidebar left of the waveform; that container is gone, because permanent
//  horizontal room is the wrong price for something you consult occasionally.
//
//  ## Shape
//
//  Several small `View` structs with **value inputs**, not one container.
//  `REWIND.md` says so explicitly, and it is the one piece of UI advice in that
//  document backed by a measurement: ROADMAP B2 found that extracting
//  `WaveformAreaView` as a single struct would have made things *worse* (7+
//  generic parameters, and deep generic nesting is what made the body's type
//  metadata cost 358 ms to instantiate on first display). So: a list that takes
//  `[HistoryRailNode]`, a row that takes one, and no view here holds a reference
//  to a view model.
//
//  Both are `Equatable` and marked `.equatable()` at their call sites, so the
//  rail does not re-render on drag ticks, progress ticks, or anything else that
//  leaves the processing chain alone — which is most of what `WaveformView` does.
//

import SwiftUI

/// The stack of nodes, without the scroll container.
///
/// Separate from its scroll view so it can be rendered and inspected on its own:
/// `ImageRenderer` produces an empty image for anything inside a `ScrollView`,
/// so a headless render of the whole tab shows its chrome and nothing between.
/// That is a renderer limitation rather than a layout fault, but it also makes
/// the scroll container exactly the right seam to put a boundary on — see
/// `HistoryRailRenderTests`.
struct HistoryRailNodeList: View, Equatable {
    let nodes: [HistoryRailNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                HistoryRailRow(
                    node: node,
                    isFirst: index == 0,
                    isLast: index == nodes.count - 1
                )
                .equatable()
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One node: the rail spine, its dot, and the node's title and parameters.
struct HistoryRailRow: View, Equatable {
    let node: HistoryRailNode
    let isFirst: Bool
    let isLast: Bool

    static func == (lhs: HistoryRailRow, rhs: HistoryRailRow) -> Bool {
        lhs.node == rhs.node && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Gutter the spine is drawn into. The spine cannot be a sibling
            // here: it needs to span the row's full height, and a flexible
            // child inside a `ScrollView` is proposed *infinity*, which
            // collapses the whole row to nothing. Drawing it as a background —
            // where the proposed size is the row's resolved size — is what
            // makes `maxHeight: .infinity` mean "as tall as this row".
            Color.clear
                .frame(width: spineWidth, height: 1)
            label
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .background(alignment: .topLeading) { spine }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(node.title)
                    .font(.system(.body, weight: node.isCurrent ? .semibold : .regular))
                if node.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !node.subtitle.isEmpty {
                Text(node.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if node.isCurrent {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
    }

    /// The vertical connector plus this node's dot. Two fixed segments around
    /// the dot and one flexible tail, so consecutive rows join seamlessly
    /// without any row needing to know the others' heights — and the ends stay
    /// clean because the first row draws no lead-in and the last no tail.
    private var spine: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : lineColor)
                .frame(width: 1, height: dotInset)
            Circle()
                .fill(node.isCurrent ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: spineWidth, height: spineWidth)
            Rectangle()
                .fill(isLast ? Color.clear : lineColor)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .frame(width: spineWidth)
        .padding(.leading, 12)
    }

    private var lineColor: Color { Color.secondary.opacity(0.35) }
    private var spineWidth: CGFloat { 8 }
    /// Puts the dot on the title's optical centre.
    private var dotInset: CGFloat { 7 }

    private var accessibilityText: String {
        var text = node.title
        if !node.subtitle.isEmpty { text += ", \(node.subtitle)" }
        if node.isCurrent { text += ", current" }
        return text
    }
}
