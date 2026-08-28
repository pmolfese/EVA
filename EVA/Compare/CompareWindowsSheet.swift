//
//  CompareWindowsSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A/B compare between two open recording windows (ROADMAP RW-1 item 10).
//
//  The question is "what did that choice actually do to the data" — fork a
//  window before an ICA run, apply the alternative in one of them, then compare.
//  What is shown is deliberately narrow: the relation between the two windows
//  (so a coincidental pairing cannot read as an experiment), the alignment that
//  was possible, the channels that differ most, and the overlay plus difference
//  trace for whichever channel is selected.
//
//  It does not attempt an in-place overlay in the waveform itself. Two windows'
//  viewports, scroll positions, montages, and display scales are independent
//  state, and syncing them is a much larger feature than the measurement this
//  view exists to give.
//

import Charts
import SwiftUI

struct CompareWindowsSheet: View {
    /// The window this sheet was opened from.
    let sourceID: UUID
    let onClose: () -> Void

    @State private var selectedID: UUID?
    @State private var selectedChannel: SignalComparison.ChannelDifference?
    /// Computed off the main actor and held, never recomputed from `body`.
    ///
    /// A full comparison is O(channels × samples) — 150 M sample pairs for a
    /// 20-minute 128-channel recording. Deriving it in a computed property
    /// would re-run it on every body evaluation, including each hover and
    /// selection change, which is the difference between a sheet and a hang.
    @State private var comparison: Result<SignalComparison.Result, Error>?
    @State private var isComparing = false
    /// Decimated plot traces for the selected channel, held for the same reason
    /// as `comparison`: one channel of a 20-minute recording is still a million
    /// samples to walk, and `body` runs far more often than the selection changes.
    @State private var traces: PlotTraces?

    private struct PlotTraces: Equatable {
        var channelID: String
        var a: [Float]
        var b: [Float]
        var difference: [Float]
        var startSample: Int
        var stride: Int
    }

    private var registry: WindowComparisonRegistry { .shared }

    private var source: ComparableWindow? { registry.window(id: sourceID) }
    private var candidates: [(window: ComparableWindow, relation: WindowRelation)] {
        registry.comparisonCandidates(for: sourceID)
    }
    private var selection: (window: ComparableWindow, relation: WindowRelation)? {
        candidates.first { $0.window.id == selectedID } ?? candidates.first
    }

    /// Identity of the pairing being compared. Changing window, or either
    /// window's samples, is what makes the held result stale — nothing else.
    private var comparisonKey: String {
        [
            sourceID.uuidString,
            source?.signal?.dataRevision.uuidString ?? "none",
            selection?.window.id.uuidString ?? "none",
            selection?.window.signal?.dataRevision.uuidString ?? "none"
        ].joined(separator: "|")
    }

    private func recompute() async {
        guard let sourceSignal = source?.signal,
              let otherSignal = selection?.window.signal else {
            comparison = nil
            return
        }
        isComparing = true
        defer { isComparing = false }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try SignalComparison.compare(sourceSignal, otherSignal) }
        }.value
        guard !Task.isCancelled else { return }
        comparison = result
        // The previously selected channel belongs to the previous result.
        if case .success(let value) = result,
           !value.channels.contains(where: { $0.id == selectedChannel?.id }) {
            selectedChannel = value.channels.first
        }
        updateTraces(for: selectedChannel ?? successfulResult?.channels.first)
    }

    private var successfulResult: SignalComparison.Result? {
        if case .success(let value) = comparison { return value }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if candidates.isEmpty {
                ContentUnavailableView(
                    "No Other Window to Compare",
                    systemImage: "macwindow.on.rectangle",
                    description: Text("Use Fork to New Window to open a second window on this recording, change something in one of them, then compare.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                windowPicker
                Divider()
                comparisonBody
            }

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .task(id: comparisonKey) { await recompute() }
        .onChange(of: selectedChannel?.id) { _, _ in
            updateTraces(for: selectedChannel ?? successfulResult?.channels.first)
        }
    }

    // MARK: - Header and picker

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compare Windows")
                .font(.title3.weight(.semibold))
            if let source {
                Text("A — \(source.packageName) · node \(source.currentNode) · \(source.lineageSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Compare with", selection: Binding(
                get: { selection?.window.id },
                set: { newValue in
                    selectedID = newValue
                    // The chosen channel belongs to the previous pairing.
                    selectedChannel = nil
                }
            )) {
                ForEach(candidates, id: \.window.id) { candidate in
                    Text(label(for: candidate))
                        .tag(Optional(candidate.window.id))
                }
            }
            .pickerStyle(.menu)

            if let selection {
                Label(selection.relation.detail, systemImage: relationIcon(selection.relation))
                    .font(.caption)
                    .foregroundStyle(selection.relation == .forkedLineage ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(for candidate: (window: ComparableWindow, relation: WindowRelation)) -> String {
        let window = candidate.window
        var text = "\(window.packageName) · node \(window.currentNode)"
        if candidate.relation != .forkedLineage {
            text += " — \(candidate.relation.label.lowercased())"
        } else if let forked = window.forkedFromNode {
            text += " — forked at \(forked)"
        }
        return text
    }

    private func relationIcon(_ relation: WindowRelation) -> String {
        switch relation {
        case .forkedLineage: return "arrow.triangle.branch"
        case .sameFileIndependent: return "exclamationmark.triangle"
        case .differentRecordings: return "exclamationmark.triangle"
        }
    }

    // MARK: - Comparison

    @ViewBuilder
    private var comparisonBody: some View {
        switch comparison {
        case .none:
            HStack(spacing: 8) {
                if isComparing { ProgressView().controlSize(.small) }
                Text(isComparing ? "Comparing…" : "Both windows need a loaded signal to compare.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

        case .success(let result):
            VStack(alignment: .leading, spacing: 12) {
                summaryRow(result)
                if result.isIdentical {
                    Label("These windows are showing identical samples.", systemImage: "equal.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                channelTable(result)
                if let channel = selectedChannel ?? result.channels.first {
                    traceChart(for: channel)
                }
                healthRow
            }
        }
    }

    private func summaryRow(_ result: SignalComparison.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 18) {
                metric("Aligned", result.alignmentSummary)
                metric("Overall RMS Δ", format(result.overallRMSDifference))
                if let worst = result.channels.first {
                    metric("Largest Δ", "\(worst.name) · \(format(worst.rmsDifference))")
                }
            }
            if !result.unmatchedInA.isEmpty || !result.unmatchedInB.isEmpty {
                Text(unmatchedDescription(result))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func unmatchedDescription(_ result: SignalComparison.Result) -> String {
        var parts: [String] = []
        if !result.unmatchedInA.isEmpty {
            parts.append("only in A: \(result.unmatchedInA.prefix(6).joined(separator: ", "))\(result.unmatchedInA.count > 6 ? "…" : "")")
        }
        if !result.unmatchedInB.isEmpty {
            parts.append("only in B: \(result.unmatchedInB.prefix(6).joined(separator: ", "))\(result.unmatchedInB.count > 6 ? "…" : "")")
        }
        return "Not compared — " + parts.joined(separator: "; ") + "."
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    private func channelTable(_ result: SignalComparison.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Channel").frame(width: 120, alignment: .leading)
                Text("RMS Δ").frame(width: 90, alignment: .trailing)
                Text("Max Δ").frame(width: 90, alignment: .trailing)
                Text("r").frame(width: 70, alignment: .trailing)
                Text("Relative").frame(width: 80, alignment: .trailing)
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(result.channels) { channel in
                        Button {
                            selectedChannel = channel
                        } label: {
                            HStack {
                                Text(channel.name).frame(width: 120, alignment: .leading)
                                Text(format(channel.rmsDifference)).frame(width: 90, alignment: .trailing)
                                Text(format(channel.maxAbsDifference)).frame(width: 90, alignment: .trailing)
                                Text(channel.correlation.map { String(format: "%.3f", $0) } ?? "—")
                                    .frame(width: 70, alignment: .trailing)
                                Text(channel.relativeChange.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                                    .frame(width: 80, alignment: .trailing)
                                Spacer()
                            }
                            .font(.caption.monospacedDigit())
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill((selectedChannel ?? result.channels.first) == channel
                                          ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 150)
        }
    }

    private func updateTraces(for channel: SignalComparison.ChannelDifference?) {
        guard let channel,
              let sourceSignal = source?.signal,
              let otherSignal = selection?.window.signal else {
            traces = nil
            return
        }
        let computed = SignalComparison.traces(a: sourceSignal, b: otherSignal, difference: channel)
        traces = PlotTraces(
            channelID: channel.id,
            a: computed.a,
            b: computed.b,
            difference: computed.difference,
            startSample: computed.startSample,
            stride: computed.stride
        )
    }

    @ViewBuilder
    private func traceChart(for channel: SignalComparison.ChannelDifference) -> some View {
        if let sourceSignal = source?.signal, let traces, traces.channelID == channel.id {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(channel.name) — A, B, and A − B")
                    .font(.caption.weight(.semibold))
                Chart {
                    ForEach(Array(traces.a.enumerated()), id: \.offset) { index, value in
                        LineMark(
                            x: .value("Time", seconds(index, traces, rate: sourceSignal.samplingRate)),
                            y: .value("µV", value),
                            series: .value("Trace", "A")
                        )
                        .foregroundStyle(by: .value("Trace", "A"))
                    }
                    ForEach(Array(traces.b.enumerated()), id: \.offset) { index, value in
                        LineMark(
                            x: .value("Time", seconds(index, traces, rate: sourceSignal.samplingRate)),
                            y: .value("µV", value),
                            series: .value("Trace", "B")
                        )
                        .foregroundStyle(by: .value("Trace", "B"))
                    }
                    ForEach(Array(traces.difference.enumerated()), id: \.offset) { index, value in
                        LineMark(
                            x: .value("Time", seconds(index, traces, rate: sourceSignal.samplingRate)),
                            y: .value("µV", value),
                            series: .value("Trace", "A − B")
                        )
                        .foregroundStyle(by: .value("Trace", "A − B"))
                    }
                }
                .chartForegroundStyleScale([
                    "A": Color.accentColor,
                    "B": Color.purple,
                    "A − B": Color.red
                ])
                .chartXAxisLabel("Seconds")
                .frame(height: 150)
            }
        }
    }

    private func seconds(_ index: Int, _ traces: PlotTraces, rate: Double) -> Double {
        guard rate > 0 else { return Double(index) }
        return Double(traces.startSample + index * traces.stride) / rate
    }

    private var healthRow: some View {
        HStack(alignment: .top, spacing: 24) {
            healthColumn(title: "A", window: source)
            healthColumn(title: "B", window: selection?.window)
            Spacer()
        }
    }

    @ViewBuilder
    private func healthColumn(title: String, window: ComparableWindow?) -> some View {
        if let window {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) — \(window.packageName)")
                    .font(.caption.weight(.semibold))
                Text("\(window.badChannelCount) bad · \(window.interpolatedChannelCount) interpolated")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(window.segmentHealthMeanGood.map { "segment health \($0)% mean" } ?? "segment health not run")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(window.artifactsAssessed ? "artifacts assessed" : "artifacts not assessed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        if abs(value) < 0.01 { return String(format: "%.2e", value) }
        return String(format: "%.3f", value)
    }
}
