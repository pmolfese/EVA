//
//  RhythmicityExplorerView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import SwiftUI

/// Initial navigation shell for the LAVI/ABBA/WTPL analysis family.
///
/// The sheet is intentionally honest about its current state: it establishes
/// the product boundary and route without presenting illustrative values as
/// computed results. The result canvas is replaced incrementally by the Bands,
/// Event-related, and Bursts milestones in `LAVI.md`.
struct RhythmicityExplorerView: View {
    @Bindable var viewModel: RhythmicityExplorerViewModel

    let packageName: String
    let signal: MFFSignalData
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(spacing: 18) {
                Picker("Analysis", selection: $viewModel.mode) {
                    ForEach(RhythmicityExplorerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)

                resultPlaceholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)

            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 660, idealHeight: 760)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rhythmicity Explorer")
                    .font(.title3.weight(.semibold))
                Text(packageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(signal.numberOfChannels) channels · \(format(signal.samplingRate)) Hz · \(format(signal.duration)) s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var resultPlaceholder: some View {
        switch viewModel.mode {
        case .bands:
            ContentUnavailableView(
                "Bands analysis is being built",
                systemImage: "waveform.path",
                description: Text("This view will provide LAVI rhythmicity spectra, surrogate noise estimates, and individualized ABBA bands.")
            )
        case .eventRelated:
            ContentUnavailableView(
                "Event-related analysis is being built",
                systemImage: "waveform.path.ecg.rectangle",
                description: Text("This view will provide within-trial phase locking (WTPL), baseline-relative ΔWTPL, and condition comparisons.")
            )
        case .bursts:
            ContentUnavailableView(
                "Burst analysis is being built",
                systemImage: "bolt.horizontal.circle",
                description: Text("This view will identify rhythmic bursts and summarize their timing, duration, occupancy, and band consistency.")
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Numerical analysis is not enabled in this build.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Run Analysis") {}
                .disabled(true)

            Button("Close") { onClose() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}
