//
//  SimulatorWindowView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The New → Simulated Recording "studio" window (SIM-1). Single-instance, like
//  the Batch window and the utility windows. A top mode selector chooses among
//  the simulator's jobs — Generate is implemented; Score / Sweep / Group are
//  visible-but-inert placeholders the shell makes room for. Generate hosts a
//  tabbed inspector (`SimulatorGenerateView`) that drives the bundled EVASimulate
//  tool and opens the contaminated recording in an ordinary main window.
//
//  `simulator` is owned by `EVAApp` and injected at the `Window` scene root, not
//  here (see the note on `EVAApp.batchController` / `simulatorController`).
//

import AppKit
import SwiftUI

struct SimulatorWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(SimulatorController.self) private var simulator

    var body: some View {
        @Bindable var simulator = simulator
        VStack(spacing: 0) {
            Picker("Mode", selection: $simulator.mode) {
                ForEach(SimulatorController.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            .disabled(simulator.isGenerating)

            Divider()

            switch simulator.mode {
            case .generate:
                SimulatorGenerateView(open: openRecording)
            case .score:
                SimulatorScoreView(open: openRecording)
            default:
                comingSoon(simulator.mode)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    /// Loads a generated recording into a fresh main window — the same mechanism
    /// Batch's "Open in EVA" and File → Open Recording use.
    private func openRecording(_ url: URL) {
        PendingWindowOpens.shared.push([url])
        openWindow(id: "main")
    }

    private func comingSoon(_ mode: SimulatorController.Mode) -> some View {
        VStack(spacing: 12) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
            Text(mode.title)
                .font(.title2.weight(.semibold))
            Text(description(for: mode))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Coming soon.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func description(for mode: SimulatorController.Mode) -> String {
        switch mode {
        case .generate:
            return ""
        case .score:
            return "Compare a corrected or processed recording against its ground truth — SNR, per-band residual, ERP recovery, and topography — so you can score your cleaning without leaving EVA."
        case .sweep:
            return "Vary one parameter across a range and generate a recording for each value, to map how a method holds up as conditions change."
        case .group:
            return "Generate a population of subjects with controlled between-subject variability for group-level validation."
        }
    }
}
