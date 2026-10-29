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
import Charts

struct SimulatorSweepView: View {
    @Environment(SimulatorController.self) private var simulator
    let open: (URL) -> Void
    @State private var metric: SweepMetric = .snr
    @State private var condition = ""

    var body: some View {
        @Bindable var simulator = simulator
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Parameter sweep").font(.headline)
                        Text("Vary the Generate-tab settings for one simulated subject. Repeat seeds across values, optionally cross two axes, and evaluate ERP recovery against clean recordings.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    axisEditor("Primary axis", parameter: $simulator.sweepParameter, values: $simulator.sweepValuesText,
                               condition: $simulator.sweepCondition, peak: $simulator.sweepPeak)
                    HStack {
                        Toggle("Two-axis grid", isOn: $simulator.sweepGrid)
                        HelpButton(topic: SweepHelp.grid)
                    }
                    if simulator.sweepGrid {
                        axisEditor("Second axis", parameter: $simulator.sweepParameter2, values: $simulator.sweepValuesText2,
                                   condition: $simulator.sweepCondition2, peak: $simulator.sweepPeak2)
                    }
                    HStack {
                        Stepper("Seed repetitions: \(simulator.sweepRepeats)", value: $simulator.sweepRepeats, in: 1...100)
                        HelpButton(topic: SweepHelp.seeds)
                    }
                    HStack {
                        Toggle("Extend recordings to fit ERP schedules", isOn: $simulator.sweepFitDuration)
                        HelpButton(topic: SweepHelp.duration)
                    }
                    evaluationEditor
                    if let plan = try? simulator.sweepPlan() {
                        Text("\(plan.runCount) recordings · \(plan.axes.map { String($0.values.count) }.joined(separator: " × ")) values × \(plan.repeats) seeds")
                            .font(.callout.weight(.semibold))
                    } else {
                        Text("Enter numeric values or start:stop:step to preview run count.").foregroundStyle(.secondary)
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

    private func axisEditor(_ title: String, parameter: Binding<String>, values: Binding<String>, condition: Binding<String>, peak: Binding<String>) -> some View {
        let descriptor = SimulationSweep.parameters.first { $0.id == parameter.wrappedValue }!
        let peaks = simulator.config.erp?.experiment?.conditions.first(where: { $0.id == condition.wrappedValue })?.peaks ?? []
        return GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Parameter", selection: parameter) {
                        ForEach(SimulationSweep.parameters) { Text($0.label).tag($0.id) }
                    }
                    HelpButton(topic: SweepHelp.parameters)
                }
                HStack {
                    TextField("Values or start:stop:step", text: values).textFieldStyle(.roundedBorder)
                    Button("Example values") { values.wrappedValue = descriptor.example }
                    HelpButton(topic: SweepHelp.values)
                }
                if descriptor.scope != .global {
                    HStack {
                        Picker("Condition", selection: condition) {
                            Text(descriptor.id == "erp-condition-share" ? "Select condition…" : "All conditions").tag("")
                            ForEach(simulator.config.erp?.experiment?.conditions ?? []) { Text($0.name).tag($0.id) }
                        }
                        HelpButton(topic: SweepHelp.scope)
                    }
                    if descriptor.scope == .peak && !condition.wrappedValue.isEmpty {
                        Picker("Peak", selection: peak) {
                            Text("All peaks").tag("")
                            ForEach(Array(peaks.enumerated()), id: \.element.id) { index, item in
                                Text("Peak \(index + 1) · \((item.latencySeconds * 1000).formatted()) ms").tag(item.id)
                            }
                        }
                    }
                    if descriptor.id == "erp-condition-share" {
                        Text("Other shares are redistributed proportionally; zero-share others divide the remainder equally.").font(.caption)
                    } else if ["erp-inverted", "erp-attenuated", "erp-divergent"].contains(descriptor.id) {
                        Text("Uses the Typical remainder; other recipe fractions stay fixed. Totals above 1 are rejected.").font(.caption)
                    }
                }
                if parameter.wrappedValue.hasPrefix("erp-"), simulator.config.erp?.experiment == nil {
                    Text("Enable the editable ERP experiment in Generate → ERP first.").foregroundStyle(.orange)
                }
            }.padding(6)
        }
        .onChange(of: condition.wrappedValue) { peak.wrappedValue = "" }
    }

    private var evaluationEditor: some View {
        @Bindable var simulator = simulator
        return GroupBox("Evaluation") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Mode", selection: $simulator.sweepEvaluation.mode) {
                        ForEach(SweepEvaluationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    HelpButton(topic: SweepHelp.evaluation)
                }
                if simulator.sweepEvaluation.mode != .none {
                    HStack {
                        numeric("Pre-stimulus (s)", $simulator.sweepEvaluation.preSeconds)
                        numeric("Post-stimulus (s)", $simulator.sweepEvaluation.postSeconds)
                        HelpButton(topic: SweepHelp.windows)
                    }
                    HStack {
                        numeric("Peak start (s)", $simulator.sweepEvaluation.peakStartSeconds)
                        numeric("Peak end (s)", $simulator.sweepEvaluation.peakEndSeconds)
                    }
                    HStack {
                        TextField("Peak channel (1-based)", value: $simulator.sweepEvaluation.peakChannel, format: .number)
                            .textFieldStyle(.roundedBorder)
                        Text("Peak channel (1-based)").font(.caption)
                        HelpButton(topic: SweepHelp.peaks)
                    }
                    if simulator.sweepEvaluation.mode == .reject {
                        HStack {
                            numeric("Reject peak-to-peak > (µV)", $simulator.sweepEvaluation.rejectionMicrovolts)
                            HelpButton(topic: SweepHelp.rejection)
                        }
                    }
                    Text("Unfiltered, baseline-corrected epochs. Scores all conditions against their clean recording averages, including background EEG and overlapping responses. No artifact correction or recipe classification is applied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    private func numeric(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder)
        }
    }

    private func resultsTable(_ outcome: SimulatorRunner.SweepOutcome) -> some View {
        let report = outcome.report
        let conditions = report.rows.flatMap(\.evaluations).reduce(into: [String: String]()) { $0[$1.conditionID] = $1.conditionName }
        let selected = conditions[condition] == nil ? (conditions.keys.sorted().first ?? "") : condition
        let points = report.aggregates(metric: metric, condition: selected)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(outcome.runs.count) recordings").font(.headline)
                Spacer()
                HelpButton(topic: SweepHelp.results)
                Button("Reveal results") { NSWorkspace.shared.activateFileViewerSelecting([outcome.directory.appendingPathComponent("sweep_results.json")]) }
            }
            HStack {
                Picker("Metric", selection: $metric) {
                    ForEach(SweepMetric.allCases.filter { report.plan.evaluation.mode != .none || $0 == .snr }) { Text($0.title).tag($0) }
                }
                if metric != .snr {
                    Picker("Condition", selection: Binding(get: { selected }, set: { condition = $0 })) {
                        ForEach(conditions.keys.sorted(), id: \.self) { Text(conditions[$0]!).tag($0) }
                    }
                }
            }
            if points.isEmpty {
                Text("No finite values for this metric. Inspect per-run statuses for absent epochs, all-rejected trials, or undefined metrics.").font(.caption)
            } else {
                Chart(points) { point in
                    let series = point.secondValue.map { "Axis 2 = \($0.formatted())" } ?? "Mean"
                    LineMark(x: .value("Value", point.value), y: .value(metric.title, point.mean))
                        .foregroundStyle(by: .value("Series", series))
                    PointMark(x: .value("Value", point.value), y: .value(metric.title, point.mean))
                        .foregroundStyle(by: .value("Series", series))
                    if let sd = point.sd {
                        RuleMark(x: .value("Value", point.value), yStart: .value("Mean − SD", point.mean - sd), yEnd: .value("Mean + SD", point.mean + sd))
                            .foregroundStyle(by: .value("Series", series))
                    }
                }
                .chartXAxisLabel((try? SimulationSweep.parameter(report.plan.axes[0].parameter).label) ?? report.plan.axes[0].parameter)
                .frame(height: 240)
                Text("Mean ± sample SD across seeds; not confidence intervals. Undefined values are excluded; n is the number of valid repetitions.").font(.caption).foregroundStyle(.secondary)
                Table(points) {
                    TableColumn("Value") { Text($0.value.formatted()) }
                    TableColumn("Axis 2") { Text($0.secondValue?.formatted() ?? "—") }
                    TableColumn("n") { Text(String($0.count)) }
                    TableColumn("Mean") { Text($0.mean.formatted()) }
                    TableColumn("SD") { Text($0.sd?.formatted() ?? "—") }
                }.frame(height: 160)
            }
            let unavailable = report.rows.flatMap(\.evaluations).filter { $0.status != "ok" }.count
            if unavailable > 0 { Text("\(unavailable) condition/run results have no complete epochs or no retained trials. See evaluation.json for counts and status.").foregroundStyle(.orange).font(.caption) }
            Table(outcome.runs) {
                TableColumn("Value") { Text($0.value.formatted()) }
                TableColumn("Run") { Text($0.directory.lastPathComponent).font(.caption) }
                TableColumn("") { run in Button("Open") { open(run.noisyURL) }.buttonStyle(.link) }
            }.frame(height: 160)
        }
        .onAppear { metric = report.plan.evaluation.mode == .none ? .snr : .rmse }
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
