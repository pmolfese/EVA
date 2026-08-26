//
//  ProcessingStatusPopover.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The panel behind the toolbar status area: **Queue** and **History** as two
//  adjacent tabs in one popover, using the layout in
//  `docs/figures/REWIND_FIG_2.png`. Queue owns active progress and the status
//  log; History owns committed processing lineage. They do not currently share
//  one node lifecycle.
//
//  ## Why the history lives here rather than in a sidebar
//
//  The first pass put the history rail in a 260 pt column left of the waveform.
//  It worked, but it spent permanent horizontal room on something you consult
//  occasionally — and the waveform is the thing people are actually looking at.
//  The status area already owns "what is this app doing", already opens a
//  popover, and is already where progress appears. Putting the tree there costs
//  no waveform width and puts progress beside lineage without conflating them.
//
//  ## What happened to the two old popovers
//
//  This replaces both. The status area used to switch between a live-progress
//  popover and a status-history popover depending on whether anything was
//  running, so whichever one you wanted, you got the other. Both are temporal,
//  so both are now the **Queue** tab: running operations on top, the message log
//  under them. Nothing was dropped — the log's Clear button and the full
//  scrollback are still here.
//
//  Views take values and hold no view model references, per ROADMAP B5.
//

import SwiftUI

nonisolated enum ProcessingStatusTab: String, CaseIterable, Identifiable {
    case queue
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: return "Queue"
        case .history: return "History"
        }
    }

    /// What each tab is *for*, in one line.
    ///
    /// ROADMAP RW-1 item 8 settled the relationship between them: these are two
    /// **adjacent views**, not one node-lifecycle system seen twice. Queue is
    /// work in flight and what it has said; History is the lineage of the
    /// signal currently on screen. A node never appears in Queue, and a running
    /// operation is never a node until it has produced something. Queued,
    /// dependency, and speculative node states stay unbuilt until full-rate
    /// rebuilds actually require them — until then they would be three more
    /// states to keep truthful for no behaviour anyone can see.
    var summary: String {
        switch self {
        case .queue: return "What is running now, and what it has reported."
        case .history: return "The steps that produced the signal on screen."
        }
    }
}

struct ProcessingStatusPopoverView: View {
    let operations: [OperationProgress]
    let statusHistory: [StatusHistoryEntry]
    let historyNodes: [HistoryRailNode]
    let historyShortID: String
    let canStepBack: Bool
    let canStepForward: Bool
    @Binding var tab: ProcessingStatusTab
    let onClearStatusHistory: () -> Void
    let onSelectNode: (String) -> Void
    let onStepBack: () -> Void
    let onStepForward: () -> Void
    let onFork: () -> Void
    let onForkNode: (String) -> Void
    /// What the snapshot cache is holding against its budget — see
    /// `RecordingHistoryModel.snapshotBudgetSummary`.
    var cacheSummary: String = ""
    var onTogglePinNode: ((String) -> Void)?
    var onRenameNode: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .queue:
                    QueueTabView(
                        operations: operations,
                        statusHistory: statusHistory,
                        onClearStatusHistory: onClearStatusHistory
                    )
                case .history:
                    HistoryTabView(
                        nodes: historyNodes,
                        shortID: historyShortID,
                        canStepBack: canStepBack,
                        canStepForward: canStepForward,
                        onSelectNode: onSelectNode,
                        onStepBack: onStepBack,
                        onStepForward: onStepForward,
                        onFork: onFork,
                        onForkNode: onForkNode,
                        cacheSummary: cacheSummary,
                        onTogglePinNode: onTogglePinNode,
                        onRenameNode: onRenameNode
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Fixed rather than sized to content: the two tabs have very different
        // natural heights, and a popover that resizes as you switch tabs is
        // unpleasant to use and easy to lose your place in.
        .frame(width: 460, height: 420)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ProcessingStatusTab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    HStack(spacing: 5) {
                        Text(candidate.title)
                            .font(.system(.body, weight: tab == candidate ? .semibold : .regular))
                        // The badge is the count of things in flight, so an idle
                        // session shows nothing rather than a "0".
                        if candidate == .queue, !operations.isEmpty {
                            Text("\(operations.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(tab == candidate ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                // The two tabs are adjacent views of different things, and
                // saying which is which is the whole of ROADMAP RW-1 item 8 —
                // see `ProcessingStatusTab.summary`.
                .help(candidate.summary)
                .accessibilityAddTraits(tab == candidate ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Queue

/// Temporal view: what is running, then what has been said about it.
struct QueueTabView: View {
    let operations: [OperationProgress]
    let statusHistory: [StatusHistoryEntry]
    let onClearStatusHistory: () -> Void

    var body: some View {
        ScrollView {
            QueueTabContent(
                operations: operations,
                statusHistory: statusHistory,
                onClearStatusHistory: onClearStatusHistory
            )
        }
    }
}

/// The queue's contents, outside the scroll container — the same seam as
/// `HistoryRailNodeList`, and for the same reason: `ImageRenderer` renders
/// nothing inside a `ScrollView`, so this is the part a headless render can
/// actually check.
struct QueueTabContent: View {
    let operations: [OperationProgress]
    let statusHistory: [StatusHistoryEntry]
    let onClearStatusHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if operations.isEmpty {
                Text("Nothing running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(operations.enumerated()), id: \.offset) { index, operation in
                    if index > 0 { Divider() }
                    QueuedOperationView(operation: operation)
                }
            }

            Divider()

            HStack {
                Text("Status log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: onClearStatusHistory)
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(statusHistory.isEmpty)
            }

            if statusHistory.isEmpty {
                Text("No status messages yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(statusHistory.reversed()) { entry in
                    StatusHistoryEntryView(entry: entry)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One in-flight operation: title, elapsed time, bar, phase, and its stages.
struct QueuedOperationView: View {
    let operation: OperationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.title)
                        .font(.headline)
                    Text(operation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsedText(since: operation.startedAt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                ProgressView(value: operation.clampedFraction)
                    .progressViewStyle(.linear)
                Text("\(Int((operation.clampedFraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(operation.phase)
                    .font(.callout.weight(.medium))
                if let detail = operation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(operation.stages) { stage in
                    HStack(spacing: 7) {
                        Image(systemName: Self.stageIcon(stage.state))
                            .foregroundStyle(Self.stageColor(stage.state))
                            .frame(width: 14)
                        Text(stage.name)
                            .font(.caption)
                            .foregroundStyle(stage.state == .pending ? Color.secondary : Color.primary)
                    }
                }
            }
        }
    }

    static func stageIcon(_ state: OperationProgress.StageState) -> String {
        switch state {
        case .complete: return "checkmark.circle.fill"
        case .active: return "circle.inset.filled"
        case .pending: return "circle"
        }
    }

    static func stageColor(_ state: OperationProgress.StageState) -> Color {
        switch state {
        case .complete: return .green
        case .active: return .accentColor
        case .pending: return .secondary
        }
    }

    static func elapsedText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct StatusHistoryEntryView: View {
    let entry: StatusHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.source.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(entry.text)
                .font(.callout)
                .foregroundStyle(entry.isError ? Color.red : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - History

/// Positional view: where in the tree the current signal sits.
struct HistoryTabView: View {
    let nodes: [HistoryRailNode]
    let shortID: String
    let canStepBack: Bool
    let canStepForward: Bool
    let onSelectNode: (String) -> Void
    let onStepBack: () -> Void
    let onStepForward: () -> Void
    /// "Fork to New Window" from the footer — REWIND.md "Forking to a new
    /// window". Forks *wherever the pointer currently is*, the same node
    /// stepping back/forward already operates on.
    let onFork: () -> Void
    /// Fork from a specific row instead, via its context menu — added
    /// 2026-08-16 alongside the footer button rather than replacing it, so
    /// "fork from here" is reachable both as "the node I'm looking at right
    /// now" (footer) and "that other node up there" (right-click) without
    /// first clicking to navigate there.
    let onForkNode: (String) -> Void
    /// Cache occupancy against the byte budget. Empty hides the line.
    var cacheSummary: String = ""
    var onTogglePinNode: ((String) -> Void)?
    var onRenameNode: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                HistoryRailNodeList(
                    nodes: nodes,
                    onSelect: onSelectNode,
                    onFork: onForkNode,
                    onTogglePin: onTogglePinNode,
                    onRename: onRenameNode
                )
                .equatable()
            }
            Divider()
            footer
        }
    }

    /// Transport, position, and identity. The controls are live now — clicking a
    /// node or stepping restores that point in the history.
    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onStepBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!canStepBack)
            .help("Back one step")
            .accessibilityLabel("Step back")

            Button(action: onStepForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!canStepForward)
            .help("Forward one step")
            .accessibilityLabel("Step forward")

            Text("\(nodes.count) \(nodes.count == 1 ? "step" : "steps")")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Eviction is otherwise invisible: nodes quietly stop being instant
            // and nothing says a budget exists (ROADMAP RW-1 item 7).
            if !cacheSummary.isEmpty {
                Text(cacheSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Cached signals let you jump back instantly. Past this budget the oldest are freed and their steps are recomputed on demand; pinned points are kept.")
            }

            Spacer()

            Button(action: onFork) {
                Label("Fork to New Window", systemImage: "macwindow.badge.plus")
                    .labelStyle(.iconOnly)
            }
            .help("Open a new window on this recording, starting from exactly what's on screen — edit it independently from here.")
            .accessibilityLabel("Fork to new window")

            Text(shortID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help("Identity of the current node: a hash of every step that produced it.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
