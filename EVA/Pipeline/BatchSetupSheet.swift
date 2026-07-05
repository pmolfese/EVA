//
//  BatchSetupSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Setup for Batch Process: choose the MFF files to process, the processing
//  source (a standalone eva.xml or an MFF containing one), the shared step config,
//  and an output folder. Start hands everything to the app-level BatchController.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BatchSetupSheet: View {
    @Environment(BatchController.self) private var batch
    let onCancel: () -> Void
    let onStart: () -> Void

    @State private var files: [URL] = []
    @State private var outputFolder: URL?
    @State private var sourceName = ""
    @State private var script: EVAProcessingScript?
    @StateObject private var config = ReplayController()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Batch Process")
                    .font(.headline)
                Text("Apply one processing script to many recordings. Portable steps run automatically; decision steps (ICA) pause on each file so you can choose, then it continues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filesSection
                    sourceSection
                    outputSection
                }
                .padding(20)
            }
            .frame(minHeight: 260, maxHeight: 420)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if script != nil {
                    Label(
                        canRunHeadless
                            ? "No steps need review — runs in the background with no windows."
                            : "Some steps need your input — files will open one at a time.",
                        systemImage: canRunHeadless ? "bolt.fill" : "macwindow"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { onCancel() }
                    Button("Start") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canStart)
                }
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    // MARK: Sections

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files").font(.callout.weight(.semibold))
                Spacer()
                Button("Add Files…") { addFiles() }
                if !files.isEmpty { Button("Clear") { files.removeAll() } }
            }
            if files.isEmpty {
                Text("No files chosen.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(systemName: "waveform")
                        Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            files.removeAll { $0 == url }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Processing Source").font(.callout.weight(.semibold))
                Spacer()
                Button(script == nil ? "Choose…" : "Change…") { chooseSource() }
            }
            if script == nil {
                Text("Pick an eva.xml or an MFF that was processed in EVA.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("From \(sourceName)").font(.caption).foregroundStyle(.secondary)
                Picker("Mode", selection: Binding(get: { config.mode }, set: { config.mode = $0 })) {
                    ForEach(ReplayController.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                ForEach($config.steps) { $step in
                    if step.kind != .skip {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $step.included).labelsHidden()
                            Text(stepLabel(step.step.operation)).font(.caption)
                            Spacer()
                            if step.kind == .review {
                                Toggle("Review", isOn: $step.pauseToReview)
                                    .toggleStyle(.checkbox).font(.caption)
                            } else if step.kind == .decision {
                                Label("Pauses", systemImage: "hand.raised").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output Folder").font(.callout.weight(.semibold))
                Spacer()
                Button(outputFolder == nil ? "Choose…" : "Change…") { chooseOutputFolder() }
            }
            Text(outputFolder?.path ?? "Processed files are written here as <name>-processed.mff.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: Actions

    private var canStart: Bool {
        !files.isEmpty && script != nil && outputFolder != nil
            && config.steps.contains { $0.included && $0.kind != .skip }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mff]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !files.contains(url) { files.append(url) }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mff, .xml]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let read = EVAProcessingScriptXML.read(fromFile: url) else { return }
        script = read
        sourceName = url.lastPathComponent
        config.configure(script: read, sourceName: sourceName)
        config.showsConfigPane = false
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    /// Full Auto, with no *included* step that would ever pause for a human
    /// (a decision step like ICA/drawn-artifact-cleaning, or a review step
    /// with "pause to review" on) — the whole batch can run headlessly, with
    /// no window opened for any file. See `BatchController.startHeadless`.
    private var canRunHeadless: Bool {
        guard config.mode == .fullAuto else { return false }
        return !config.steps.contains {
            $0.included && ($0.kind == .decision || ($0.kind == .review && $0.pauseToReview))
        }
    }

    private func start() {
        guard let script, let outputFolder else { return }
        var scoped = files
        scoped.append(outputFolder)
        if canRunHeadless {
            Task {
                await batch.startHeadless(
                    files: files,
                    script: script,
                    sourceName: sourceName,
                    outputFolder: outputFolder,
                    scopedURLs: scoped
                )
            }
        } else {
            batch.start(
                files: files,
                script: script,
                sourceName: sourceName,
                steps: config.steps,
                mode: config.mode,
                outputFolder: outputFolder,
                scopedURLs: scoped
            )
        }
        onStart()
    }

    private func stepLabel(_ op: EVAProcessingStep.Operation) -> String {
        switch op {
        case .mriGradientCorrection: return "MRI Gradient Correction"
        case .filter: return "Band-pass / Line-noise Filter"
        case .thresholdArtifactDetection: return "Threshold Artifact Detection"
        case .waveletReduce: return "Wavelet Reduction"
        case .segment: return "PSA Segmentation / Averaging"
        case .icaClean: return "ICA Component Removal"
        default: return op.rawValue
        }
    }
}
