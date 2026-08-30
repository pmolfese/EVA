//
//  SimulatorSweepView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-1 Sweep mode: vary one parameter across a range, generating one recording
//  per value, off the current Generate-tab settings. Drives the CLI `sweep` and
//  shows the resulting `sweep_summary.csv` as a value → uncorrected-SNR table.
//

import AppKit
import SwiftUI

struct SimulatorSweepView: View {
    @Environment(SimulatorController.self) private var simulator
    let open: (URL) -> Void

    var body: some View {
        @Bindable var simulator = simulator
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Parameter sweep").font(.headline)
                        Text("Generate one recording per value of a parameter, varying the current Generate-tab settings. Each run also reports the uncorrected broadband SNR.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LabeledContent("Parameter") {
                        Picker("Parameter", selection: $simulator.sweepParameter) {
                            ForEach(SimulatorRunner.sweepParameters, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: 220)
                    }
                    LabeledContent("Values") {
                        TextField("50, 100, 150", text: $simulator.sweepValuesText)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    }
                    outputRow(folder: simulator.sweepOutputDir) { simulator.sweepOutputDir = $0 } clear: { simulator.sweepOutputDir = nil }

                    if let outcome = simulator.sweepOutcome, simulator.sweepPhase == .done {
                        resultsTable(outcome)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if simulator.sweepPhase != .idle {
                Divider()
                statusStrip(phase: simulator.sweepPhase, message: simulator.sweepMessage,
                            reveal: simulator.sweepOutcome?.directory) { simulator.clearSweepStatus() }
            }
            Divider()
            HStack {
                Spacer()
                Button { simulator.sweep() } label: { Label("Run Sweep", systemImage: "slider.horizontal.3") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(simulator.isSweeping)
            }
            .padding(12)
        }
    }

    private func resultsTable(_ outcome: SimulatorRunner.SweepOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(outcome.parameter) · \(outcome.runs.count) runs").font(.callout.weight(.semibold))
            Table(outcome.runs) {
                TableColumn("Value") { Text(String(format: "%g", $0.value)).monospacedDigit() }
                TableColumn("Uncorrected SNR") { Text(String(format: "%.2f", $0.uncorrectedSNR)).monospacedDigit() }
                TableColumn("") { run in
                    Button("Open") { open(run.noisyURL) }.buttonStyle(.link)
                }
            }
            .frame(minHeight: 160, maxHeight: 280)
        }
    }

    @ViewBuilder
    private func outputRow(folder: URL?, choose: @escaping (URL) -> Void, clear: @escaping () -> Void) -> some View {
        LabeledContent("Output folder") {
            HStack(spacing: 8) {
                Text(folder?.path ?? "Temporary folder (not kept)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose…") { chooseFolder(choose) }
                if folder != nil { Button("Use Temp") { clear() } }
            }
        }
    }

    private func statusStrip(phase: SimulatorController.Phase, message: String, reveal: URL?, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            switch phase {
            case .generating:
                ProgressView().controlSize(.small); Text(message).font(.callout)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let reveal { Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([reveal]) } }
                Button("Dismiss") { dismiss() }
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(); Button("Dismiss") { dismiss() }
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private func chooseFolder(_ assign: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { assign(url) }
    }
}
