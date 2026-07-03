//
//  ReplayConfigSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Pre-replay configuration pane for "Copy Processing From…": a checklist of the
//  source recording's steps with include/skip + per-step "pause to review"
//  toggles and a global Full-Auto vs Review-Each mode. No inline parameter
//  editors — edits happen at each pause by reopening the existing panel.
//

import AppKit
import SwiftUI

struct ReplayConfigSheet: View {
    @ObservedObject var controller: ReplayController
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Copy Processing")
                    .font(.headline)
                Text("Re-apply the processing from \(controller.sourceName). Portable steps run automatically; decision steps pause so you can review or choose before continuing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            HStack {
                Picker("Mode", selection: $controller.mode) {
                    ForEach(ReplayController.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($controller.steps) { $step in
                        stepRow($step)
                        Divider()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .frame(minHeight: 180, maxHeight: 320)

            Divider()

            HStack(spacing: 8) {
                Toggle("Export result when finished", isOn: $controller.exportWhenFinished)
                if controller.exportWhenFinished {
                    Button(controller.outputFolder?.lastPathComponent ?? "Choose Folder…") {
                        chooseOutputFolder()
                    }
                    .buttonStyle(.link)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Text(startSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Start") { onStart() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
            .padding(20)
        }
        .frame(width: 480)
    }

    @ViewBuilder
    private func stepRow(_ step: Binding<ReplayController.StepConfig>) -> some View {
        let kind = step.wrappedValue.kind
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: step.included)
                .labelsHidden()
                .disabled(kind == .skip)

            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: step.wrappedValue.step.operation))
                    .font(.callout.weight(.medium))
                Text(kindDescription(kind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if kind == .review {
                Toggle("Pause to review", isOn: step.pauseToReview)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(!step.wrappedValue.included)
            } else if kind == .decision {
                Label("Pauses for input", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .opacity(kind == .skip ? 0.5 : 1)
    }

    private var canStart: Bool {
        guard controller.steps.contains(where: { $0.included && $0.kind != .skip }) else { return false }
        if controller.exportWhenFinished, controller.outputFolder == nil { return false }
        return true
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { controller.outputFolder = panel.url }
    }

    private var startSummary: String {
        let runnable = controller.plannedActions()
        let pauses = runnable.filter { $0.gate != nil }.count
        return "\(runnable.count) step\(runnable.count == 1 ? "" : "s") · \(pauses) pause\(pauses == 1 ? "" : "s")"
    }

    private func label(for op: EVAProcessingStep.Operation) -> String {
        switch op {
        case .mriGradientCorrection: return "MRI Gradient Correction"
        case .filter: return "Band-pass / Line-noise Filter"
        case .thresholdArtifactDetection: return "Threshold Artifact Detection"
        case .icaClean: return "ICA Component Removal"
        case .artifactClean: return "Artifact Cleaning"
        case .waveletReduce: return "Wavelet Reduction"
        case .interpolateChannels: return "Channel Interpolation"
        case .markBad: return "Bad-channel Marks"
        default: return op.rawValue
        }
    }

    private func kindDescription(_ kind: ReplayInteraction) -> String {
        switch kind {
        case .auto: return "Runs automatically"
        case .review: return "Review parameters, then runs"
        case .decision: return "Pauses for your decision"
        case .skip: return "Subject-specific — not copied"
        }
    }
}
