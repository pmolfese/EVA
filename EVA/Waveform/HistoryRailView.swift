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
//  and each node's defining parameters. Clicking a node navigates to it: the
//  pipeline is restored from that node's snapshot when cached; a supported
//  evicted node is re-derived first. Undo and redo are pointer movement, with
//  reconstruction only as the cache fallback.
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
    /// Navigate to a node. Value-typed id, so the list holds no tree reference.
    var onSelect: ((String) -> Void)?
    /// Fork a new window from this specific node, rather than from wherever
    /// the pointer currently is — a per-row context menu, added 2026-08-16
    /// alongside the existing "wherever the pointer is" toolbar button
    /// (`HistoryTabView.onFork`). Both call the same underlying operation;
    /// this one just navigates there first. `nil` disables the menu entirely
    /// (e.g. in render-only contexts like `ImageRenderer` snapshots).
    var onFork: ((String) -> Void)?
    /// Pin or unpin this node's snapshot — an exemption from cache eviction,
    /// within an allowance (`RecordingHistoryModel.setPinned`).
    var onTogglePin: ((String) -> Void)?
    /// Rename a node, replacing the default step rendering with the operator's
    /// own name for that point.
    var onRename: ((String) -> Void)?

    static func == (lhs: HistoryRailNodeList, rhs: HistoryRailNodeList) -> Bool {
        lhs.nodes == rhs.nodes
    }

    /// What clicking this row will cost, said before the click rather than
    /// after it.
    ///
    /// The cost half is **measured or absent** (ROADMAP RW-1 item 7): a node
    /// EVA has actually timed says how long its rebuild took, and one it has
    /// not says only that a rebuild is needed. There is deliberately no
    /// fast/slow guess from a table of stage names — a wrong estimate is worse
    /// than none, because it is the number someone decides to wait on.
    static func helpText(for node: HistoryRailNode) -> String {
        if node.isInstant {
            return node.isPinned
                ? "Go to this point — pinned, so its signal stays cached."
                : "Go to this point in the processing history"
        }
        guard let seconds = node.rebuildSeconds else {
            return "Rebuild and go to this point — its signal was freed to save memory, so this recomputes it."
        }
        return "Rebuild and go to this point — its signal was freed to save memory. It took \(durationText(seconds)) to compute the first time."
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "under a second" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int(seconds / 60)
        let rest = Int(seconds) % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                let row = HistoryRailRow(
                    node: node,
                    isFirst: index == 0,
                    isLast: index == nodes.count - 1
                )
                .equatable()
                .modifier(HistoryRailRowMenu(
                    node: node, onFork: onFork, onTogglePin: onTogglePin, onRename: onRename
                ))

                if let onSelect, !node.isCurrent, node.isReachable {
                    // Non-instant nodes are no longer disabled: clicking one
                    // re-derives it from its steps (see
                    // `WaveformHistoryRail.requestNavigation`), so the only
                    // difference is speed, surfaced in the help text rather
                    // than by refusing the click (2026-08-16).
                    Button { onSelect(node.id) } label: { row }
                        .buttonStyle(.plain)
                        .help(HistoryRailNodeList.helpText(for: node))
                } else if !node.isReachable, !node.isCurrent {
                    // Unreachable: a step the file arrived with, whose input
                    // this session never had. It is real history and stays
                    // listed, but it is not a click that could be honoured —
                    // re-deriving it would replay the on-disk steps against
                    // their own output (ROADMAP RW-1 item 1). Showing it
                    // greyed and saying why beats offering a click that only
                    // ever produces an error.
                    row
                        .opacity(0.6)
                        .help(node.unreachableReason
                              ?? "This point can't be rebuilt from what this session has.")
                } else {
                    row
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The per-row menu: the three actions that are real.
///
/// ROADMAP RW-1 item 9 settled the rest by deletion rather than by building
/// them. `REWIND.md` promised a row menu with rename, delete-future, pin,
/// reopen-stage, and export/report-from-node; of those, **delete future** is
/// already what applying a divergent action does (and doing it explicitly would
/// be a second way to destroy work), **reopen stage** is a restore-the-sheet
/// feature much larger than a menu item, and **export/report from node**
/// belongs with the reports work in F-1. What remains is Fork (shipped
/// 2026-08-16), Pin (item 7), and Rename.
///
/// Fork and Pin are withheld on an unreachable node: forking one starts by
/// navigating there, and pinning one would reserve an allowance for a snapshot
/// that can never be rebuilt. Rename is offered on every node — a name is an
/// annotation, and naming a point you can no longer visit is still useful.
private struct HistoryRailRowMenu: ViewModifier {
    let node: HistoryRailNode
    let onFork: ((String) -> Void)?
    let onTogglePin: ((String) -> Void)?
    let onRename: ((String) -> Void)?

    private var hasAnyAction: Bool {
        onRename != nil || (node.isReachable && (onFork != nil || onTogglePin != nil))
    }

    func body(content: Content) -> some View {
        if hasAnyAction {
            content.contextMenu {
                if let onFork, node.isReachable {
                    Button {
                        onFork(node.id)
                    } label: {
                        Label("Fork to New Window", systemImage: "macwindow.badge.plus")
                    }
                }
                if let onTogglePin, node.isReachable {
                    Button {
                        onTogglePin(node.id)
                    } label: {
                        Label(
                            node.isPinned ? "Unpin" : "Pin",
                            systemImage: node.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .help("A pinned point keeps its cached signal instead of being evicted to save memory.")
                }
                if let onRename {
                    Button {
                        onRename(node.id)
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                }
            }
        } else {
            content
        }
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
        .padding(.leading, 12 + CGFloat(node.depth) * 14)
        .padding(.trailing, 10)
        .background(alignment: .topLeading) { spine }
        // Branches you have left stay visible but recede, so the current lineage
        // reads at a glance. Dimming rather than hiding is the whole point — the
        // rail used to render only the path to the current node, which made
        // stepping back look like the steps after it had been destroyed.
        .opacity(node.isOnCurrentPath ? 1 : 0.55)
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
        .padding(.leading, 12 + CGFloat(node.depth) * 14)
    }

    private var lineColor: Color { Color.secondary.opacity(0.35) }
    private var spineWidth: CGFloat { 8 }
    /// Puts the dot on the title's optical centre.
    private var dotInset: CGFloat { 7 }

    private var accessibilityText: String {
        var text = node.title
        if !node.subtitle.isEmpty { text += ", \(node.subtitle)" }
        if node.isCurrent { text += ", current" }
        if !node.isOnCurrentPath { text += ", on another branch" }
        return text
    }
}
