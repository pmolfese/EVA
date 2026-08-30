//
//  SimulatorGroupView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-1 Group mode: generate a cohort of simulated subjects drawn around the
//  current Generate-tab settings with controlled between-subject variability.
//  Drives the CLI `generate-group` and lists the resulting subjects.
//

import AppKit
import SwiftUI

struct SimulatorGroupView: View {
    @Environment(SimulatorController.self) private var simulator
    let open: (URL) -> Void

    var body: some View {
        @Bindable var simulator = simulator
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Group generation").font(.headline)
                        Text("Draw a cohort of subjects around the current Generate-tab settings, with controlled between-subject variability. Writes one recording per subject plus a participants table.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LabeledContent("Subjects") {
                        HStack(spacing: 8) {
                            TextField("Subjects", value: $simulator.groupSubjectCount, format: .number)
                                .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 70)
                            Stepper("", value: $simulator.groupSubjectCount, in: 1...200).labelsHidden()
                        }
                    }
                    LabeledContent("Group seed") {
                        HStack(spacing: 8) {
                            Toggle("Fixed", isOn: $simulator.groupUsesSeed).labelsHidden()
                            TextField("Seed", value: $simulator.groupSeed, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 130)
                                .disabled(!simulator.groupUsesSeed)
                        }
                    }

                    Toggle("Homogeneous (no between-subject variability)", isOn: $simulator.groupVariability.homogeneous)
                    if !simulator.groupVariability.homogeneous {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Between-subject SDs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            sd("Head radius", $simulator.groupVariability.headRadiusSD, 0...0.3, 2)
                            sd("Placement °", $simulator.groupVariability.placementSD, 0...10, 1)
                            sd("Alpha", $simulator.groupVariability.alphaSD, 0...1, 2)
                            sd("BCG", $simulator.groupVariability.bcgSD, 0...1, 2)
                            sd("Impedance", $simulator.groupVariability.impedanceSD, 0...1, 2)
                            sd("Heart rate", $simulator.groupVariability.heartRateSD, 0...25, 1)
                            sd("ERP effect", $simulator.groupVariability.erpEffectSD, 0...1, 2)
                        }
                    }

                    outputRow(folder: simulator.groupOutputDir) { simulator.groupOutputDir = $0 } clear: { simulator.groupOutputDir = nil }

                    if let outcome = simulator.groupOutcome, simulator.groupPhase == .done {
                        resultsList(outcome)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if simulator.groupPhase != .idle {
                Divider()
                statusStrip(phase: simulator.groupPhase, message: simulator.groupMessage,
                            reveal: simulator.groupOutcome?.directory) { simulator.clearGroupStatus() }
            }
            Divider()
            HStack {
                Spacer()
                Button { simulator.generateGroup() } label: { Label("Generate Group", systemImage: "person.3") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(simulator.isGrouping)
            }
            .padding(12)
        }
    }

    private func resultsList(_ outcome: SimulatorRunner.GroupOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(outcome.subjects.count) subjects").font(.callout.weight(.semibold))
                Spacer()
                if let tsv = outcome.participantsTSV {
                    Button("Reveal participants.tsv") { NSWorkspace.shared.activateFileViewerSelecting([tsv]) }
                        .buttonStyle(.link)
                }
            }
            Table(outcome.subjects) {
                TableColumn("Subject") { Text($0.label) }
                TableColumn("") { subject in
                    Button("Open") { open(subject.noisyURL) }.buttonStyle(.link)
                }
            }
            .frame(minHeight: 160, maxHeight: 280)
        }
    }

    private func sd(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ precision: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.\(precision)f", value.wrappedValue))
                .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
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
