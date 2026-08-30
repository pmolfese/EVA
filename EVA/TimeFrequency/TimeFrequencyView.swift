//
//  TimeFrequencyView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The Time-Frequency view — a third epoch view mode beside Averages and Trials.
//  It reads the same epoch selection through a frequency lens: baseline-
//  normalized ERSP (power) or inter-trial phase coherence (ITPC), for one
//  channel and condition, with an optional A − B condition-difference map.
//  Settings live on `EpochingViewModel` so they persist across mode switches.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TimeFrequencyView: View {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    @Bindable var epoching: EpochingViewModel

    @State private var render: TFRender?
    @State private var isComputing = false
    @State private var isExporting = false
    @State private var exportStatus: String?

    private var categories: [String] {
        Array(Set(segments.map(\.category))).sorted()
    }

    private var channelNames: [String] {
        if let names = signal.channelNames, names.count == signal.data.count { return names }
        return (0..<signal.data.count).map { "Ch \($0 + 1)" }
    }

    // A compact, hashable snapshot of everything the computation depends on, so
    // `.task(id:)` recomputes exactly when an input changes (without hashing the
    // large signal/segment arrays).
    private struct Job: Equatable {
        var measure: EpochingViewModel.TFMeasure
        var method: TFMethod
        var timeBandwidth: Double
        var channel: Int
        var conditionA: String?
        var conditionB: String?
        var showsDifference: Bool
        var minHz: Double
        var maxHz: Double
        var count: Int
        var cyclesLow: Double
        var cyclesHigh: Double
        var baseline: TFBaselineMethod
        var signalToken: String
        var segmentCount: Int
    }

    private var job: Job {
        Job(
            measure: epoching.tfMeasure,
            method: epoching.tfMethod,
            timeBandwidth: epoching.tfTimeBandwidth,
            channel: epoching.tfSelectedChannelIndex,
            conditionA: effectiveConditionA,
            conditionB: epoching.tfShowsDifference ? epoching.tfConditionB : nil,
            showsDifference: epoching.tfShowsDifference,
            minHz: epoching.tfMinFrequencyHz,
            maxHz: epoching.tfMaxFrequencyHz,
            count: epoching.tfFrequencyCount,
            cyclesLow: epoching.tfCyclesLow,
            cyclesHigh: epoching.tfCyclesHigh,
            baseline: epoching.tfBaselineMethod,
            signalToken: "\(signal.signalURL.path)#\(signal.samplingRate)#\(signal.data.count)",
            segmentCount: segments.count
        )
    }

    private var effectiveConditionA: String? {
        epoching.tfConditionA ?? categories.first
    }

    var body: some View {
        Group {
            if categories.isEmpty {
                ContentUnavailableView(
                    "No Epochs",
                    systemImage: "square.grid.3x3.fill.square",
                    description: Text("Create PSA averages/epochs to explore power and phase-locking in the time-frequency domain.")
                )
            } else {
                HStack(spacing: 0) {
                    heatmapArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    controlPanel
                        .frame(width: 260)
                }
            }
        }
        .task(id: job) { await recompute() }
    }

    // MARK: Heatmap area

    @ViewBuilder
    private var heatmapArea: some View {
        VStack(spacing: 8) {
            header
            if let render, !render.grid.isEmpty {
                TFHeatmap(render: render)
                    .overlay(alignment: .topTrailing) {
                        if isComputing { ProgressView().controlSize(.small).padding(8) }
                    }
                TFColorBar(render: render)
                    .frame(height: 34)
                    .padding(.horizontal, 44)
            } else if isComputing {
                Spacer()
                ProgressView("Computing time-frequency…")
                Spacer()
            } else {
                Spacer()
                ContentUnavailableView(
                    "No Trials",
                    systemImage: "square.grid.3x3",
                    description: Text("The selected condition has no epochs on the chosen channel.")
                )
                Spacer()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.headline)
                if let render {
                    Text(headerSubtitle(render)).font(.caption).foregroundStyle(.secondary)
                }
                if let exportStatus {
                    Text(exportStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isExporting {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button("Full Map (NPY)…") { exportNPY() }
                    .disabled(effectiveConditionA == nil)
                Button("Scalar CSV…") { exportScalarCSV() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isExporting || render == nil)
        }
    }

    private var headerTitle: String {
        let measure = epoching.tfMeasure == .power ? "ERSP" : "ITPC"
        let channel = channelNames.indices.contains(epoching.tfSelectedChannelIndex)
            ? channelNames[epoching.tfSelectedChannelIndex] : "—"
        if epoching.tfShowsDifference, let b = epoching.tfConditionB, let a = effectiveConditionA {
            return "\(measure) · \(channel) · \(epoching.displayCategory(a)) − \(epoching.displayCategory(b))"
        }
        return "\(measure) · \(channel) · \(effectiveConditionA.map(epoching.displayCategory) ?? "—")"
    }

    private func headerSubtitle(_ render: TFRender) -> String {
        var parts = ["\(render.frequenciesHz.count) freqs \(Int(epoching.tfMinFrequencyHz))–\(Int(epoching.tfMaxFrequencyHz)) Hz"]
        if let b = render.trialCountB {
            parts.append("\(render.trialCountA) vs \(b) trials")
        } else {
            parts.append("\(render.trialCountA) trials")
        }
        if epoching.tfMeasure == .power && !epoching.tfShowsDifference {
            parts.append("baseline \(epoching.tfBaselineMethod.rawValue)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Controls

    @ViewBuilder
    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlSection("Measure") {
                    Picker("", selection: $epoching.tfMeasure) {
                        ForEach(EpochingViewModel.TFMeasure.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                controlSection("Method") {
                    Picker("", selection: $epoching.tfMethod) {
                        ForEach(TFMethod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if epoching.tfMethod == .multitaper {
                        LabeledContent("Time·BW") {
                            Stepper(value: $epoching.tfTimeBandwidth, in: 2...10, step: 0.5) {
                                Text(String(format: "%.1f", epoching.tfTimeBandwidth)).monospacedDigit()
                            }
                        }
                        Text("\(max(Int(epoching.tfTimeBandwidth - 1), 1)) tapers").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                controlSection("Channel") {
                    Picker("", selection: $epoching.tfSelectedChannelIndex) {
                        ForEach(channelNames.indices, id: \.self) { i in
                            Text(channelNames[i]).tag(i)
                        }
                    }
                    .labelsHidden()
                }

                controlSection("Condition") {
                    Picker("", selection: conditionABinding) {
                        ForEach(categories, id: \.self) { Text(epoching.displayCategory($0)).tag($0) }
                    }
                    .labelsHidden()

                    Toggle("Difference (A − B)", isOn: $epoching.tfShowsDifference)
                        .font(.caption)
                    if epoching.tfShowsDifference {
                        Picker("minus", selection: conditionBBinding) {
                            Text("—").tag(String?.none)
                            ForEach(categories, id: \.self) { Text(epoching.displayCategory($0)).tag(String?.some($0)) }
                        }
                        .labelsHidden()
                    }
                }

                if epoching.tfMeasure == .power && !epoching.tfShowsDifference {
                    controlSection("Baseline") {
                        Picker("", selection: $epoching.tfBaselineMethod) {
                            ForEach(TFBaselineMethod.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        Text("Pre-stimulus window").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                controlSection("Frequencies (Hz)") {
                    LabeledContent("Min") {
                        Stepper(value: $epoching.tfMinFrequencyHz, in: 1...(epoching.tfMaxFrequencyHz - 1), step: 1) {
                            Text("\(Int(epoching.tfMinFrequencyHz))").monospacedDigit()
                        }
                    }
                    LabeledContent("Max") {
                        Stepper(value: $epoching.tfMaxFrequencyHz, in: (epoching.tfMinFrequencyHz + 1)...min(120, signal.samplingRate / 2.5), step: 1) {
                            Text("\(Int(epoching.tfMaxFrequencyHz))").monospacedDigit()
                        }
                    }
                    LabeledContent("Bins") {
                        Stepper(value: $epoching.tfFrequencyCount, in: 5...80, step: 1) {
                            Text("\(epoching.tfFrequencyCount)").monospacedDigit()
                        }
                    }
                }

                controlSection("Cycles (ramp)") {
                    LabeledContent("Low") {
                        Stepper(value: $epoching.tfCyclesLow, in: 1...(epoching.tfCyclesHigh), step: 1) {
                            Text("\(Int(epoching.tfCyclesLow))").monospacedDigit()
                        }
                    }
                    LabeledContent("High") {
                        Stepper(value: $epoching.tfCyclesHigh, in: (epoching.tfCyclesLow)...20, step: 1) {
                            Text("\(Int(epoching.tfCyclesHigh))").monospacedDigit()
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func controlSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private var conditionABinding: Binding<String> {
        Binding(
            get: { effectiveConditionA ?? "" },
            set: { epoching.tfConditionA = $0 }
        )
    }

    private var conditionBBinding: Binding<String?> {
        Binding(
            get: { epoching.tfConditionB },
            set: { epoching.tfConditionB = $0 }
        )
    }

    // MARK: Compute

    private func recompute() async {
        isComputing = true
        defer { isComputing = false }

        let signal = self.signal
        let segments = self.segments
        let job = self.job
        let result = await Task.detached(priority: .userInitiated) {
            TimeFrequencyView.computeRender(signal: signal, segments: segments, job: job)
        }.value

        // Guard against a stale result landing after the inputs changed again.
        if job == self.job { self.render = result }
    }

    // MARK: Export (TF-3)

    private var exportContext: TimeFrequencyExport.Context {
        let plan = TFFrequencyPlan.logSpaced(
            minHz: epoching.tfMinFrequencyHz, maxHz: epoching.tfMaxFrequencyHz,
            count: epoching.tfFrequencyCount, cyclesLow: epoching.tfCyclesLow, cyclesHigh: epoching.tfCyclesHigh
        )
        let maxTimeMs = render?.timesMs.last ?? 0
        return TimeFrequencyExport.Context(
            plan: plan, method: epoching.tfMethod, timeBandwidth: epoching.tfTimeBandwidth,
            baselineMethod: epoching.tfBaselineMethod, bands: EEGFrequencyBand.restingDefaults,
            windows: TimeFrequencyExport.defaultWindows(maxTimeMs: maxTimeMs)
        )
    }

    private var exportBaseName: String {
        (signal.signalURL.deletingPathExtension().lastPathComponent as NSString).lastPathComponent
    }

    private func exportNPY() {
        guard let condition = effectiveConditionA else { return }
        let measure = epoching.tfMeasure
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "npy") ?? .data]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(exportBaseName)-\(condition)-\(measure == .power ? "ersp" : "itpc").npy"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let signal = self.signal, segments = self.segments
        let channels = Array(0..<signal.data.count), names = channelNames, ctx = exportContext
        isExporting = true; exportStatus = nil
        Task {
            let output: (npy: Data, sidecar: Data)? = await Task.detached(priority: .userInitiated) {
                guard let maps = TimeFrequencyExport.conditionMaps(
                    signal: signal, segments: segments, condition: condition,
                    channelIndices: channels, channelNames: names, context: ctx
                ) else { return nil }
                let grid = measure == .power ? maps.ersp : maps.itpc
                return (TimeFrequencyExport.npy(grid), TimeFrequencyExport.sidecarJSON(maps, measure: measure, context: ctx))
            }.value
            isExporting = false
            guard let output else { exportStatus = "Export failed: no trials on this condition."; return }
            do {
                try output.npy.write(to: url, options: .atomic)
                try? output.sidecar.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
                exportStatus = "Saved \(url.lastPathComponent) (+ .json axes)"
            } catch { exportStatus = error.localizedDescription }
        }
    }

    private func exportScalarCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(exportBaseName)-tf-scalars.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let signal = self.signal, segments = self.segments
        let channels = Array(0..<signal.data.count), names = channelNames, ctx = exportContext, conds = categories
        isExporting = true; exportStatus = nil
        Task {
            let data: Data? = await Task.detached(priority: .userInitiated) {
                var maps: [TimeFrequencyExport.ConditionMaps] = []
                for condition in conds {
                    if let m = TimeFrequencyExport.conditionMaps(
                        signal: signal, segments: segments, condition: condition,
                        channelIndices: channels, channelNames: names, context: ctx
                    ) { maps.append(m) }
                }
                guard !maps.isEmpty else { return nil }
                return TimeFrequencyExport.csvData(TimeFrequencyExport.scalarCSVRows(maps, context: ctx))
            }.value
            isExporting = false
            guard let data else { exportStatus = "Export failed: no trials."; return }
            do { try data.write(to: url, options: .atomic); exportStatus = "Saved \(url.lastPathComponent)" }
            catch { exportStatus = error.localizedDescription }
        }
    }

    private nonisolated static func computeRender(signal: MFFSignalData, segments: [EpochSegment], job: Job) -> TFRender? {
        guard let conditionA = job.conditionA,
              job.maxHz > job.minHz, job.count >= 1 else { return nil }

        let plan = TFFrequencyPlan.logSpaced(
            minHz: job.minHz, maxHz: job.maxHz, count: job.count,
            cyclesLow: job.cyclesLow, cyclesHigh: job.cyclesHigh
        )
        let channels = [job.channel]

        let stackA = TimeFrequencyTrials.stack(signal: signal, segments: segments, category: conditionA, channelIndices: channels)
        guard !stackA.isEmpty else { return nil }

        let baseline = baselineSpec(for: stackA, method: job.baseline)
        guard let resultA = TimeFrequencyEngine.ersp(trials: stackA.trials, samplingRate: stackA.samplingRate, plan: plan, baseline: baseline, method: job.method, timeBandwidth: job.timeBandwidth) else { return nil }

        let gridA = job.measure == .power ? resultA.ersp : resultA.itpc

        // Optional condition difference.
        var grid = gridA
        var trialCountB: Int?
        if job.showsDifference, let conditionB = job.conditionB, conditionB != conditionA {
            let stackB = TimeFrequencyTrials.stack(signal: signal, segments: segments, category: conditionB, channelIndices: channels)
            if !stackB.isEmpty,
               let resultB = TimeFrequencyEngine.ersp(trials: stackB.trials, samplingRate: stackB.samplingRate, plan: plan, baseline: baselineSpec(for: stackB, method: job.baseline), method: job.method, timeBandwidth: job.timeBandwidth) {
                let gridB = job.measure == .power ? resultB.ersp : resultB.itpc
                grid = subtract(gridA, gridB)
                trialCountB = stackB.trials.count
            }
        }

        // Time axis (ms relative to the event).
        let n = stackA.timeCount
        let timesMs: [Double] = (0..<n).map { Double($0 - stackA.stimulusOffsetSamples) / stackA.samplingRate * 1000.0 }

        let isDifference = trialCountB != nil
        let isDiverging = job.measure == .power || isDifference
        let range = valueRange(grid, measure: job.measure, isDifference: isDifference)

        return TFRender(
            grid: grid,
            frequenciesHz: plan.frequenciesHz,
            timesMs: timesMs,
            eventSampleIndex: stackA.stimulusOffsetSamples,
            valueRange: range,
            isDiverging: isDiverging,
            measure: job.measure,
            isDifference: isDifference,
            trialCountA: stackA.trials.count,
            trialCountB: trialCountB
        )
    }

    /// Baseline = the pre-stimulus window when there is one, otherwise the first
    /// tenth of the epoch (with a note-worthy but safe fallback).
    private nonisolated static func baselineSpec(for stack: TimeFrequencyTrials.Stack, method: TFBaselineMethod) -> TFBaselineSpec {
        let n = stack.timeCount
        let end: Int
        if stack.stimulusOffsetSamples > 1 {
            end = stack.stimulusOffsetSamples - 1
        } else {
            end = max(1, n / 10)
        }
        return TFBaselineSpec(startSample: 0, endSample: min(end, n - 1), method: method)
    }

    private nonisolated static func subtract(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        guard a.count == b.count else { return a }
        return a.indices.map { fi in
            let ra = a[fi], rb = b[fi]
            let n = min(ra.count, rb.count)
            return (0..<n).map { ra[$0] - rb[$0] }
        }
    }

    private nonisolated static func valueRange(_ grid: [[Double]], measure: EpochingViewModel.TFMeasure, isDifference: Bool) -> ClosedRange<Double> {
        if measure == .itpc && !isDifference {
            let maxVal = grid.flatMap { $0 }.max() ?? 1
            return 0...max(maxVal, 0.05)
        }
        // Diverging: symmetric around 0 using a robust (99th-percentile) extent.
        let magnitudes = grid.flatMap { $0 }.map(abs).sorted()
        guard !magnitudes.isEmpty else { return -1...1 }
        let idx = min(magnitudes.count - 1, Int(Double(magnitudes.count) * 0.99))
        let extent = max(magnitudes[idx], 1e-6)
        return (-extent)...extent
    }
}
