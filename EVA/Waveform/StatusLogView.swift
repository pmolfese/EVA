//
//  StatusLogView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The toolbar status/progress area, extracted from `WaveformView.statusLog()`
//  (ROADMAP Priority 1, B2).
//
//  This one is different from the other extracted panels: its inputs come from
//  **eight** different view models (`gradient`, `filter`, `artifactVM`,
//  `waveletExplorer`, `wavelet`, `channels`, `segHealth`, plus MFF export). Taking
//  those as eight model references would rebuild the panel whenever any of them
//  changed anything at all, which is what it already did as a method on
//  `WaveformView`.
//
//  So the parent flattens them into a `StatusLogSnapshot` value first. That is
//  the point of the extraction, not a side effect: the snapshot is `Equatable`,
//  so the status area re-renders only when the *displayed* status actually
//  changes — not when some unrelated property of one of those eight models does.
//
//  It is also a deliberate stepping stone toward `REWIND.md`'s progress
//  consolidation, which replaces the per-view-model `operationProgress`
//  properties with a single queue. `StatusLogSnapshot` is the aggregation
//  boundary that migration needs: when the queue lands, only the code that
//  *builds* a snapshot has to change, not this view.
//

import SwiftUI

/// A single line shown in the toolbar log area.
struct StatusLogLine: Hashable {
    let source: String
    let text: String
    let isError: Bool
}

/// One labelled progress bar in the status area.
struct StatusLogProgressRow: Hashable, Identifiable {
    let label: String
    let value: Double

    var id: String { label }
}

/// Everything the status area displays, flattened to a comparable value.
struct StatusLogSnapshot: Equatable {
    /// Rich progress (source + phase + fraction) for operations that report it.
    var operations: [OperationProgress] = []
    /// Simple labelled bars for operations that only report a fraction.
    var progressRows: [StatusLogProgressRow] = []
    var messages: [StatusLogLine] = []
    var hasHistory = false

    /// True when nothing is running and there is nothing to say.
    var isIdle: Bool { operations.isEmpty && progressRows.isEmpty && messages.isEmpty }
}

struct StatusLogView: View, Equatable {
    let snapshot: StatusLogSnapshot
    let onActivate: () -> Void

    static func == (lhs: StatusLogView, rhs: StatusLogView) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(snapshot.operations.enumerated()), id: \.offset) { _, operation in
                    OperationProgressSummary(operation: operation)
                }

                ForEach(snapshot.progressRows) { row in
                    StatusLogProgressRowView(label: row.label, value: row.value)
                }

                ForEach(snapshot.messages, id: \.self) { line in
                    StatusLogLineView(line: line)
                }

                if snapshot.isIdle {
                    Text(snapshot.hasHistory ? "Ready · click for history" : "Ready")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to see the full status history")
        .accessibilityLabel("Status log")
    }
}

/// Source + phase + percentage + bar, for operations that report rich progress.
struct OperationProgressSummary: View {
    let operation: OperationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(operation.source)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(operation.phase)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(Int((operation.clampedFraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: operation.clampedFraction)
                .progressViewStyle(.linear)
        }
    }
}

/// A plain labelled progress bar.
struct StatusLogProgressRowView: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: value)
                .progressViewStyle(.linear)
            Text("\(Int(value * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

struct StatusLogLineView: View {
    let line: StatusLogLine

    var body: some View {
        Text(line.text)
            .font(.caption)
            .foregroundStyle(line.isError ? Color.red : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(line.text)
    }
}
