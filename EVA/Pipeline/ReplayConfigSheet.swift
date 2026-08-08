//
//  ReplayConfigSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Pre-replay configuration pane for "Copy Processing From…": a checklist of the
//  source recording's steps with include/skip + per-step "pause to review"
//  toggles and a global Full-Auto vs Review-Each mode. No inline parameter
//  editors — edits happen at each pause by reopening the existing panel.
//

import AppKit
import SwiftUI

nonisolated enum ReplayStepDisplay {
    static func label(for op: EVAProcessingStep.Operation) -> String {
        switch op {
        case .mriGradientCorrection: return "MRI Gradient Correction"
        case .filter: return "Band-pass / Line-noise Filter"
        case .thresholdArtifactDetection: return "Threshold Artifact Detection"
        case .icaClean: return "ICA Component Removal"
        case .artifactClean: return "Artifact Cleaning"
        case .waveletReduce: return "Wavelet Reduction"
        case .interpolateChannels: return "Channel Interpolation"
        case .markBad: return "Bad-channel Marks"
        case .segment: return "PSA Segmentation / Averaging"
        case .baseline: return "Baseline Correction"
        case .average: return "Average"
        case .combine: return "Combine"
        case .split: return "Split"
        case .reference: return "Reference"
        case .bcgDetection: return "BCG Detection"
        case .ecgDetection: return "ECG Detection"
        }
    }

    static func kindDescription(_ kind: ReplayInteraction) -> String {
        switch kind {
        case .auto: return "Runs automatically"
        case .review: return "Review parameters, then runs"
        case .decision: return "Pauses for your decision"
        case .skip: return "Recorded for provenance only"
        }
    }

    static func runningDetail(for op: EVAProcessingStep.Operation) -> String {
        switch op {
        case .mriGradientCorrection: return "Correcting MRI gradient artifacts."
        case .filter: return "Filtering the current signal."
        case .thresholdArtifactDetection: return "Detecting threshold-based ocular artifacts."
        case .waveletReduce: return "Applying wavelet artifact reduction."
        case .segment: return "Segmenting and post-processing epochs."
        case .icaClean: return "Running ICA before component review."
        case .artifactClean: return "Waiting for artifact cleaning decisions."
        default: return "Applying this processing step."
        }
    }

    static func settingsHelp(for step: EVAProcessingStep) -> String {
        var lines = [
            label(for: step.operation),
            step.replayable ? "Replayable" : "not replayable"
        ]
        if let note = step.note, !note.isEmpty {
            lines.append("Note: \(note)")
        }
        if step.parameters.isEmpty {
            lines.append("Settings: none recorded")
        } else {
            lines.append("Settings:")
            for key in step.parameters.keys.sorted() {
                lines.append("  \(key): \(step.parameters[key] ?? "")")
            }
        }
        if !step.rejections.isEmpty {
            lines.append("Category rejections:")
            for rejection in step.rejections.sorted(by: { $0.category < $1.category }) {
                lines.append("  \(rejection.category): \(rejection.included)/\(rejection.total) included")
                for reason in rejection.reasons.keys.sorted() {
                    lines.append("    \(reason): \(rejection.reasons[reason] ?? 0)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct CircularStepProgressIndicator: View {
    let progress: Double?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: 3)
            if let progress {
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityLabel("Current step progress")
    }
}

struct ReplayStepSettingsPopover: View {
    let step: EVAProcessingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Step Settings")
                .font(.headline)
            ScrollView {
                Text(ReplayStepDisplay.settingsHelp(for: step))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
    }
}

struct ReplayConfigSheet: View {
    @Bindable var controller: ReplayController
    let onStart: () -> Void
    let onCancel: () -> Void

    @State private var settingsPopoverStepID: Int?

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
        let incompatible = step.wrappedValue.compatibilityFlag
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle("", isOn: step.included)
                    .labelsHidden()
                    .disabled(kind == .skip)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ReplayStepDisplay.label(for: step.wrappedValue.step.operation))
                        .font(.callout.weight(.medium))
                    Text(ReplayStepDisplay.kindDescription(kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    settingsPopoverStepID = step.wrappedValue.id
                } label: {
                    Image(systemName: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show settings")
                .accessibilityLabel("Show step settings")
                .popover(isPresented: settingsPopoverBinding(for: step.wrappedValue.id)) {
                    ReplayStepSettingsPopover(step: step.wrappedValue.step)
                }

                if incompatible != nil {
                    Label("Doesn't fit this file", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if kind == .skip {
                    Label("not replayable", systemImage: "nosign")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if kind == .review {
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
            if let incompatible {
                Text(incompatible.message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.leading, 34) // align under the label, past the checkbox
            }
        }
        .opacity(kind == .skip ? 0.5 : 1)
    }

    private func settingsPopoverBinding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { settingsPopoverStepID == id },
            set: { isPresented in
                if isPresented {
                    settingsPopoverStepID = id
                } else if settingsPopoverStepID == id {
                    settingsPopoverStepID = nil
                }
            }
        )
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
}
