//
//  SimulatorScoreView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-1 Score mode: the validation payoff a teaching tool can't match. Pick the
//  ground-truth recording (`_clean.mff`), the recording after cleaning it in EVA,
//  and optionally the uncorrected `_noisy.mff`, then run `EVASimulate score` and
//  read the fidelity metrics — SNR, correlation, RMSE, spectral distortion, and a
//  per-band breakdown — so the whole generate → clean → score loop stays in EVA.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SimulatorScoreView: View {
    @Environment(SimulatorController.self) private var simulator
    /// Provided for symmetry with Generate; Score does not open recordings, but
    /// keeping the signature uniform lets the window route both modes the same way.
    let open: (URL) -> Void

    var body: some View {
        @Bindable var simulator = simulator
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    inputsSection(simulator: simulator)
                    if let outcome = simulator.scoreOutcome, simulator.scorePhase == .done {
                        resultsSection(outcome)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if simulator.scorePhase != .idle {
                Divider()
                statusStrip(simulator: simulator)
            }

            Divider()
            bottomBar(simulator: simulator)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Score a correction against ground truth")
                .font(.headline)
            Text("Generate a recording, open the noisy one and clean it in EVA, export the result, then score that export against the clean ground truth. The simulator knows the exact truth, so these numbers are real, not estimated.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inputsSection(simulator: SimulatorController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fileRow(
                title: "Ground truth",
                subtitle: "the clean recording (…_clean.mff)",
                url: simulator.scoreTruthURL,
                choose: { chooseMFF { simulator.scoreTruthURL = $0 } },
                clear: { simulator.scoreTruthURL = nil }
            )
            fileRow(
                title: "Corrected",
                subtitle: "the recording after cleaning in EVA",
                url: simulator.scoreCorrectedURL,
                choose: { chooseMFF { simulator.scoreCorrectedURL = $0 } },
                clear: { simulator.scoreCorrectedURL = nil }
            )
            fileRow(
                title: "Baseline (optional)",
                subtitle: "the uncorrected recording (…_noisy.mff) — shows what the correction bought",
                url: simulator.scoreBaselineURL,
                choose: { chooseMFF { simulator.scoreBaselineURL = $0 } },
                clear: { simulator.scoreBaselineURL = nil }
            )
            if simulator.lastOutput != nil {
                Button {
                    simulator.prefillScoreFromLastGeneration()
                } label: {
                    Label("Fill truth & baseline from last generation", systemImage: "wand.and.stars")
                }
                .buttonStyle(.link)
            }
        }
    }

    private func fileRow(
        title: String, subtitle: String, url: URL?,
        choose: @escaping () -> Void, clear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Button("Choose…", action: choose)
                if url != nil { Button("Clear", action: clear) }
            }
            Text(url?.lastPathComponent ?? subtitle)
                .font(.caption)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Results

    private func resultsSection(_ outcome: SimulatorRunner.ScoreOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Broadband").font(.callout.weight(.semibold))
            broadbandGrid(outcome)

            Text("By band").font(.callout.weight(.semibold))
            bandTable(outcome.corrected.bands)

            Text("SNR is clean-signal power over residual (clean − corrected) power; higher is better. Correlation and RMSE compare the corrected waveform to truth.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func broadbandGrid(_ outcome: SimulatorRunner.ScoreOutcome) -> some View {
        let hasBaseline = outcome.baseline != nil
        return Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                Text("Metric").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Corrected").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if hasBaseline {
                    Text("Uncorrected").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider()
            metricRow("SNR", outcome.corrected.broadbandSNR, outcome.baseline?.broadbandSNR, unit: "", higherBetter: true)
            metricRow("Correlation", outcome.corrected.broadbandCorrelation, outcome.baseline?.broadbandCorrelation, unit: "", higherBetter: true)
            metricRow("RMSE", outcome.corrected.broadbandRMSEMicrovolts, outcome.baseline?.broadbandRMSEMicrovolts, unit: " µV", higherBetter: false)
            metricRow("Spectral distortion", outcome.corrected.spectralDistortionDbRMS, outcome.baseline?.spectralDistortionDbRMS, unit: " dB", higherBetter: false)
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metricRow(_ name: String, _ corrected: Double, _ baseline: Double?, unit: String, higherBetter: Bool) -> some View {
        GridRow {
            Text(name).font(.callout)
            Text(number(corrected) + unit).font(.callout.monospacedDigit().weight(.semibold))
            if let baseline {
                Text(number(baseline) + unit)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bandTable(_ bands: [SimulatorRunner.ScoreBand]) -> some View {
        Table(bands) {
            TableColumn("Band") { Text($0.name) }
            TableColumn("Range") { Text("\(Int($0.lowHz))–\(Int($0.highHz)) Hz").monospacedDigit() }
            TableColumn("SNR") { Text(number($0.snr)).monospacedDigit() }
            TableColumn("Corr") { Text(number($0.correlation)).monospacedDigit() }
            TableColumn("Power (dB)") { Text(number($0.powerRatioDb)).monospacedDigit() }
            TableColumn("Spec. dist (dB)") { Text(number($0.spectralDistortionDbRMS)).monospacedDigit() }
        }
        .frame(minHeight: 180, maxHeight: 260)
    }

    // MARK: Chrome

    private func statusStrip(simulator: SimulatorController) -> some View {
        HStack(spacing: 10) {
            switch simulator.scorePhase {
            case .generating:
                ProgressView().controlSize(.small)
                Text("Scoring…").font(.callout)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(simulator.scoreMessage).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Dismiss") { simulator.clearScoreStatus() }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Dismiss") { simulator.clearScoreStatus() }
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private func bottomBar(simulator: SimulatorController) -> some View {
        HStack {
            Spacer()
            Button {
                simulator.score()
            } label: {
                Label("Score", systemImage: "checkmark.seal")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                simulator.isScoring
                || simulator.scoreTruthURL == nil
                || simulator.scoreCorrectedURL == nil
            )
        }
        .padding(12)
    }

    // MARK: Helpers

    private func number(_ value: Double) -> String {
        if value.isNaN { return "—" }
        if value.isInfinite { return value > 0 ? "∞" : "−∞" }
        return String(format: "%.3g", value)
    }

    private func chooseMFF(_ assign: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mff]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose an MFF recording."
        if panel.runModal() == .OK, let url = panel.url {
            assign(url)
        }
    }
}
