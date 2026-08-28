//
//  ChannelDecisionReplaySheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The pause a replayed channel decision opens (ROADMAP RW-1 item 6).
//
//  ## Why a pause at all
//
//  `markBad` and `interpolateChannels` are judgements about *one* recording's
//  electrodes. Replaying them silently onto another subject marks channels bad
//  that may be perfectly good there, and repairs channels that never needed it.
//  They were classified `.skip` for that reason — but "skip" was not what
//  actually happened: headless batch applied the source's bad-channel list to
//  every file (`ProcessingCore` has always had a `markBad` case), while windowed
//  replay ignored the step entirely. Two engines, opposite answers, neither
//  visible to the operator.
//
//  So the decision becomes a decision: replay stops here, shows exactly which
//  channels the script carries, lets the operator keep the ones that apply to
//  the file in front of them, and applies only those. Skipping leaves the file's
//  own channel state untouched.
//
//  ## Shape
//
//  A value-typed request plus a plain `View` over it, per ROADMAP B5: the sheet
//  holds no view model and no `WaveformView` reference, so the decision logic —
//  which channels are even applicable to this file — is testable without a view.
//

import SwiftUI

/// One replayed channel decision, resolved against the file it would apply to.
struct ChannelDecisionReplayRequest: Identifiable, Equatable {
    /// `markBad` or `interpolateChannels`.
    var operation: EVAProcessingStep.Operation
    var rows: [Row]
    var id: String { operation.rawValue }

    struct Row: Identifiable, Equatable {
        /// 0-based channel index.
        var index: Int
        /// The name this file gives the channel, or `Ch <n>`.
        var label: String
        /// False when the step cannot be honoured for this channel here — the
        /// channel is not in this recording, or (for interpolation) it has no
        /// electrode coordinates. Shown, unticked, and not selectable, because
        /// silently dropping it would hide a real difference between the files.
        var isApplicable: Bool
        /// Why it is not applicable.
        var note: String?
        var id: Int { index }
    }

    /// The channels that can actually be applied, in order.
    var applicableIndices: [Int] { rows.filter(\.isApplicable).map(\.index) }

    /// Builds the request for `channels` against a specific file.
    ///
    /// `positions` is only consulted for interpolation: a bad mark needs no
    /// geometry, but a repair that cannot be re-solved here would only produce
    /// an "interpolation lost" state a moment later, so it is declared
    /// inapplicable up front instead.
    static func make(
        operation: EVAProcessingStep.Operation,
        channels: [Int],
        signal: MFFSignalData,
        positions: [Int: SIMD3<Double>],
        channelNames: [Int: String] = [:]
    ) -> ChannelDecisionReplayRequest {
        let rows = channels.sorted().map { index -> Row in
            let label = channelNames[index] ?? "Ch \(index + 1)"
            if !signal.data.indices.contains(index) {
                return Row(index: index, label: label, isApplicable: false,
                           note: "not in this recording")
            }
            if operation == .interpolateChannels, positions[index] == nil {
                return Row(index: index, label: label, isApplicable: false,
                           note: "no electrode coordinates here")
            }
            return Row(index: index, label: label, isApplicable: true, note: nil)
        }
        return ChannelDecisionReplayRequest(operation: operation, rows: rows)
    }
}

struct ChannelDecisionReplaySheet: View {
    let request: ChannelDecisionReplayRequest
    let sourceName: String
    @Binding var selection: Set<Int>
    let onApply: () -> Void
    let onSkip: () -> Void

    private var isInterpolation: Bool { request.operation == .interpolateChannels }

    private var title: String {
        isInterpolation ? "Interpolate These Channels?" : "Mark These Channels Bad?"
    }

    private var explanation: String {
        let verb = isInterpolation ? "repaired by interpolation" : "marked bad"
        return "\(sourceName) had these channels \(verb). They describe that recording's electrodes, not this one — keep the ones that apply here."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.rows) { row in
                        HStack(spacing: 8) {
                            Toggle("", isOn: binding(for: row))
                                .labelsHidden()
                                .disabled(!row.isApplicable)
                            Text(row.label)
                                .font(.system(.body, design: .monospaced))
                            if let note = row.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(20)
            }
            .frame(minHeight: 120, maxHeight: 280)

            Divider()

            HStack {
                Button("Select All") { selection = Set(request.applicableIndices) }
                Button("Select None") { selection = [] }
                Spacer()
                Button("Skip", action: onSkip)
                Button(isInterpolation ? "Interpolate" : "Mark Bad", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 12)
        }
        .frame(width: 420)
    }

    private func binding(for row: ChannelDecisionReplayRequest.Row) -> Binding<Bool> {
        Binding(
            get: { selection.contains(row.index) },
            set: { isOn in
                if isOn { selection.insert(row.index) } else { selection.remove(row.index) }
            }
        )
    }
}
