//
//  ClusterStatisticsViews.swift
//  EVA
//
//  Trials-workspace design and result views for single-subject cluster
//  permutation statistics.
//

import Charts
import SwiftUI

struct ClusterStatisticsPane: View {
    @Bindable var viewModel: SingleTrialAnalysisViewModel
    let rawSignal: MFFSignalData?
    let rawSegments: [EpochSegment]
    let categories: [String]
    let sensorLayout: SensorLayout?
    let averageReference: Bool
    let baselineCorrected: Bool
    let badChannels: Set<Int>
    let channelName: (Int) -> String
    let categoryColor: (String) -> Color
    let displayCategory: (String) -> String

    @State private var analysisTask: Task<Void, Never>?
    @State private var selectedClusterID: Int?

    private struct InvalidationSignature: Equatable {
        let categories: [String]
        let dataRevision: UUID?
        let averageReference: Bool
        let baselineCorrected: Bool
        let badChannels: Set<Int>
        let sensorLayout: SensorLayout?
        let statistic: ClusterStatisticKind
        let conditionA: String?
        let conditionB: String?
        let fConditions: Set<String>
        let windowStartMs: Double
        let windowEndMs: Double
        let permutationCount: Int
        let threshold: Double
        let sampleStride: Int
    }

    private var invalidationSignature: InvalidationSignature {
        InvalidationSignature(
            categories: categories,
            dataRevision: rawSignal?.dataRevision,
            averageReference: averageReference,
            baselineCorrected: baselineCorrected,
            badChannels: badChannels,
            sensorLayout: sensorLayout,
            statistic: viewModel.clusterStatistic,
            conditionA: viewModel.clusterConditionA,
            conditionB: viewModel.clusterConditionB,
            fConditions: viewModel.clusterFConditions,
            windowStartMs: viewModel.clusterWindowStartMs,
            windowEndMs: viewModel.clusterWindowEndMs,
            permutationCount: viewModel.clusterPermutationCount,
            threshold: activeClusterThreshold,
            sampleStride: viewModel.clusterSampleStride
        )
    }

    private var canRun: Bool {
        guard rawSignal != nil else { return false }
        let requiredCount = viewModel.clusterStatistic == .t ? 2 : 3
        guard selectedConditionNames.count >= requiredCount,
              selectedConditionNames.allSatisfy({ condition in
                  rawSegments.filter { $0.category == condition }.count >= 2
              }) else { return false }
        return viewModel.clusterWindowEndMs > viewModel.clusterWindowStartMs
            && viewModel.clusterPermutationCount > 0
            && activeClusterThreshold > 0
            && viewModel.clusterSampleStride > 0
    }

    private var selectedConditionNames: [String] {
        switch viewModel.clusterStatistic {
        case .t:
            return [viewModel.clusterConditionA, viewModel.clusterConditionB].compactMap { $0 }
        case .f:
            return categories.filter { viewModel.clusterFConditions.contains($0) }
        }
    }

    private var activeClusterThreshold: Double {
        viewModel.clusterStatistic == .t ? viewModel.clusterThreshold : viewModel.clusterFThreshold
    }

    private var activeThresholdBinding: Binding<Double> {
        Binding(
            get: { activeClusterThreshold },
            set: { value in
                if viewModel.clusterStatistic == .t {
                    viewModel.clusterThreshold = value
                } else {
                    viewModel.clusterFThreshold = value
                }
            }
        )
    }

    private var availableWindowMs: ClosedRange<Double>? {
        guard let samplingRate = rawSignal?.samplingRate,
              !selectedConditionNames.isEmpty else { return nil }
        let selected = Set(selectedConditionNames)
        let selectedSegments = rawSegments.filter { selected.contains($0.category) }
        return ClusterStatisticsRunner.commonWindowMilliseconds(
            segments: selectedSegments,
            samplingRate: samplingRate
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            designCard

            if categories.count < (viewModel.clusterStatistic == .t ? 2 : 3) || rawSignal == nil {
                ContentUnavailableView(
                    "Need Retained Trials",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Create the required PSA categories and retain their single trials before running cluster statistics.")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else if let output = viewModel.clusterOutput {
                results(output)
            } else if let status = viewModel.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "Configure a Comparison",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(viewModel.clusterStatistic == .t
                        ? "Choose two mutually exclusive categories and run the two-sided permutation t-test."
                        : "Choose at least three mutually exclusive categories and run the omnibus permutation F-test.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .onAppear {
            seedConditionsIfNeeded()
            seedFConditionsIfNeeded()
            clampWindowToAvailableEpochs()
            if let output = viewModel.clusterOutput,
               output.dataRevision != rawSignal?.dataRevision {
                invalidateResult()
            }
        }
        .onChange(of: invalidationSignature) {
            seedConditionsIfNeeded()
            seedFConditionsIfNeeded()
            invalidateResult()
        }
        .onDisappear { cancelAnalysis(clearStatus: false) }
    }

    private var designCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spatiotemporal Cluster Permutation Test")
                        .font(.headline)
                    Text(viewModel.clusterStatistic == .t
                        ? "Independent single trials · two-sided t · maximum cluster-mass correction"
                        : "Independent single trials · one-way omnibus F · maximum cluster-mass correction")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let signal = rawSignal {
                    Text("\(signal.numberOfChannels - badChannels.count) good channels")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Statistic").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $viewModel.clusterStatistic) {
                        ForEach(ClusterStatisticKind.allCases) { statistic in
                            Text(statistic.rawValue).tag(statistic)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(viewModel.isRunning)
                }

                if viewModel.clusterStatistic == .t {
                    conditionPicker("Condition A", selection: $viewModel.clusterConditionA)
                    Text("−")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 5)
                    conditionPicker("Condition B", selection: $viewModel.clusterConditionB)
                } else {
                    fConditionMenu
                }
                numericField("Start ms", value: $viewModel.clusterWindowStartMs, width: 76)
                numericField("End ms", value: $viewModel.clusterWindowEndMs, width: 76)
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permutations").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $viewModel.clusterPermutationCount) {
                        Text("1,000 · quick").tag(1_000)
                        Text("5,000").tag(5_000)
                        Text("10,000 · final").tag(10_000)
                    }
                    .labelsHidden()
                    .frame(width: 128)
                    .disabled(viewModel.isRunning)
                }

                numericField(
                    viewModel.clusterStatistic == .t ? "Cluster |t|" : "Cluster F",
                    value: activeThresholdBinding,
                    width: 66
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Cluster α").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $viewModel.clusterAlpha) {
                        Text(".01").tag(0.01)
                        Text(".05").tag(0.05)
                        Text(".10").tag(0.10)
                    }
                    .labelsHidden()
                    .frame(width: 68)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sample stride").font(.caption2).foregroundStyle(.secondary)
                    Stepper("\(viewModel.clusterSampleStride)", value: $viewModel.clusterSampleStride, in: 1...16)
                        .frame(width: 78)
                        .disabled(viewModel.isRunning)
                }

                Spacer(minLength: 6)

                if viewModel.isRunning {
                    Button("Cancel", role: .cancel) { cancelAnalysis(clearStatus: true) }
                } else {
                    Button("Run Test") { runAnalysis() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRun)
                }
            }

            if viewModel.clusterStatistic == .f && selectedConditionNames.count < 3 {
                Label("Select at least three mutually exclusive conditions.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let progress = viewModel.runProgress, viewModel.isRunning {
                HStack(spacing: 10) {
                    ProgressView(value: min(max(progress.fraction, 0), 1))
                        .frame(maxWidth: 320)
                    Text(progress.detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Label(
                    averageReference ? "Average reference applied per trial" : "Recorded reference retained",
                    systemImage: averageReference ? "checkmark.circle" : "circle"
                )
                Label(
                    baselineCorrected ? "Baseline corrected per trial" : "No baseline correction",
                    systemImage: baselineCorrected ? "checkmark.circle" : "circle"
                )
                if sensorLayout == nil {
                    Label("No layout: temporal clusters only", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let availableWindowMs {
                    Label(
                        "Available \(formatMilliseconds(availableWindowMs.lowerBound)) to \(formatMilliseconds(availableWindowMs.upperBound)) ms",
                        systemImage: "clock"
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Corrected p-values apply to whole clusters. Their member sensors and time samples should not be interpreted as independently significant or as precise spatial/temporal boundaries.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if viewModel.clusterStatistic == .f {
                Text("The omnibus F-test indicates that at least one selected condition differs; it does not identify which pairs differ. Use planned two-condition tests for follow-up contrasts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func conditionPicker(_ title: String, selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                Text("Choose…").tag(String?.none)
                ForEach(categories, id: \.self) { category in
                    Text(displayCategory(category)).tag(String?.some(category))
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(viewModel.isRunning)
        }
    }

    private var fConditionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Conditions").font(.caption2).foregroundStyle(.secondary)
            Menu {
                Button("Select all") {
                    viewModel.clusterFConditions = Set(categories)
                }
                Divider()
                ForEach(categories, id: \.self) { category in
                    Button {
                        if viewModel.clusterFConditions.contains(category) {
                            viewModel.clusterFConditions.remove(category)
                        } else {
                            viewModel.clusterFConditions.insert(category)
                        }
                    } label: {
                        Label(
                            displayCategory(category),
                            systemImage: viewModel.clusterFConditions.contains(category) ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                Text("\(viewModel.clusterFConditions.intersection(Set(categories)).count) selected")
                    .frame(width: 112, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 128)
            .disabled(viewModel.isRunning)
        }
    }

    private func numericField(_ title: String, value: Binding<Double>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .disabled(viewModel.isRunning)
        }
    }

    @ViewBuilder
    private func results(_ output: ClusterStatisticsOutput) -> some View {
        let significant = output.analysis.clusters.filter { $0.pValue <= viewModel.clusterAlpha }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                Text(conditionSummary(output.analysis))
                    .font(.subheadline.weight(.semibold))
                Text("\(significant.count) cluster\(significant.count == 1 ? "" : "s") at p ≤ \(formatP(viewModel.clusterAlpha))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(significant.isEmpty ? .secondary : Color.accentColor)
                Text("\(output.analysis.permutationCount) permutations · \(output.analysis.statistic == .t ? "|t|" : "F") ≥ \(String(format: "%.1f", output.analysis.clusterThreshold))\(degreesOfFreedomText(output.analysis))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !output.usedSpatialAdjacency {
                    Label("temporal-only adjacency", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Observed \(output.analysis.statistic == .t ? "t" : "F") map")
                        .font(.caption.weight(.semibold))
                    Text("Channels ↓ · time → · saturated cells belong to corrected clusters")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ClusterStatisticHeatmap(
                        result: output.analysis,
                        alpha: viewModel.clusterAlpha,
                        selectedClusterID: selectedClusterID,
                        onSelectCluster: { selectedClusterID = $0 }
                    )
                    .frame(minWidth: 520, maxWidth: .infinity, minHeight: 260)
                }

                clusterList(output, clusters: significant)
                    .frame(width: 310, height: 300)
            }

            if let cluster = selectedCluster(in: output) {
                Divider()
                clusterDetail(cluster, output: output)
            } else if significant.isEmpty {
                ContentUnavailableView(
                    "No Corrected Clusters",
                    systemImage: "checkmark.circle",
                    description: Text("No spatiotemporal clusters met the selected corrected p-value threshold.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    private func clusterList(
        _ output: ClusterStatisticsOutput,
        clusters: [ClusterPermutationAnalyzer.Cluster]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Corrected clusters")
                .font(.caption.weight(.semibold))
            if clusters.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(clusters) { cluster in
                            Button {
                                selectedClusterID = cluster.id
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: output.analysis.statistic == .f
                                          ? "chart.bar.fill"
                                          : (cluster.sign > 0 ? "arrow.up.right" : "arrow.down.right"))
                                        .foregroundStyle(output.analysis.statistic == .f
                                                         ? Color.purple
                                                         : (cluster.sign > 0 ? Color.red : Color.blue))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Cluster \(cluster.id + 1) · p = \(formatP(cluster.pValue))")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                        Text("\(latencyText(cluster.startSample, output: output))–\(latencyText(cluster.endSample, output: output)) ms · \(cluster.channelIndices.count) ch · mass \(String(format: "%.1f", cluster.mass))")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if cluster.pValue <= viewModel.clusterAlpha {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    selectedClusterID == cluster.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func clusterDetail(
        _ cluster: ClusterPermutationAnalyzer.Cluster,
        output: ClusterStatisticsOutput
    ) -> some View {
        let globalChannels = cluster.channelIndices.compactMap {
            output.channelIndices.indices.contains($0) ? output.channelIndices[$0] : nil
        }
        let direction: String = if output.analysis.statistic == .f {
            "Omnibus condition effect"
        } else if cluster.sign > 0 {
            "\(displayCategory(output.analysis.conditionNames[0])) > \(displayCategory(output.analysis.conditionNames[1]))"
        } else {
            "\(displayCategory(output.analysis.conditionNames[0])) < \(displayCategory(output.analysis.conditionNames[1]))"
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cluster \(cluster.id + 1)")
                    .font(.headline)
                Text(direction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(output.analysis.statistic == .f
                                     ? Color.purple
                                     : (cluster.sign > 0 ? Color.red : Color.blue))
                Text("corrected p = \(formatP(cluster.pValue)) · \(latencyText(cluster.startSample, output: output))–\(latencyText(cluster.endSample, output: output)) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Show standard error", isOn: $viewModel.clusterShowsStandardError)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            HStack(alignment: .top, spacing: 16) {
                ClusterConditionTraceChart(
                    output: output,
                    cluster: cluster,
                    showsStandardError: viewModel.clusterShowsStandardError,
                    displayCategory: displayCategory,
                    categoryColor: categoryColor
                )
                .frame(minWidth: 520, maxWidth: .infinity)
                .frame(height: 260)

                if let sensorLayout, let signal = rawSignal {
                    TopomapView(
                        layout: sensorLayout,
                        values: statisticTopomap(cluster: cluster, output: output, channelCount: signal.numberOfChannels),
                        timeSeconds: Double(output.relativeSampleOffsets[cluster.startSample] + output.relativeSampleOffsets[cluster.endSample]) / 2 / output.samplingRate,
                        fixedScale: nil,
                        unitLabel: output.analysis.statistic == .t ? "t" : "F",
                        usesPositiveSequentialScale: output.analysis.statistic == .f,
                        showsHeader: false,
                        colorBarPlacement: .trailing,
                        minimumMapHeight: 185,
                        contentPadding: 4,
                        channelName: channelName,
                        highlightedChannels: Set(globalChannels)
                    )
                    .frame(width: 270, height: 240)
                }
            }

            Text("Cluster sensors: \(globalChannels.map(channelName).joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func selectedCluster(in output: ClusterStatisticsOutput) -> ClusterPermutationAnalyzer.Cluster? {
        let significant = output.analysis.clusters.filter { $0.pValue <= viewModel.clusterAlpha }
        if let selectedClusterID,
           let selected = significant.first(where: { $0.id == selectedClusterID }) {
            return selected
        }
        return significant.first
    }

    private func statisticTopomap(
        cluster: ClusterPermutationAnalyzer.Cluster,
        output: ClusterStatisticsOutput,
        channelCount: Int
    ) -> [Double] {
        var values = [Double](repeating: 0, count: channelCount)
        let samples = cluster.startSample...cluster.endSample
        for (localChannel, globalChannel) in output.channelIndices.enumerated() where values.indices.contains(globalChannel) {
            var sum = 0.0
            for sample in samples {
                sum += output.analysis.observedStatistics[localChannel * output.analysis.sampleCount + sample]
            }
            values[globalChannel] = sum / Double(samples.count)
        }
        return values
    }

    private func latencyText(_ localSample: Int, output: ClusterStatisticsOutput) -> String {
        guard output.relativeSampleOffsets.indices.contains(localSample) else { return "?" }
        return String(Int((Double(output.relativeSampleOffsets[localSample]) / output.samplingRate * 1_000).rounded()))
    }

    private func formatP(_ value: Double) -> String {
        if value < 0.001 { return "<.001" }
        return String(format: "%.3f", value).replacingOccurrences(of: "0.", with: ".")
    }

    private func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }

    private func conditionSummary(_ analysis: ClusterStatisticsAnalysis) -> String {
        zip(analysis.conditionNames, analysis.conditionCounts)
            .map { "\(displayCategory($0.0)) (n=\($0.1))" }
            .joined(separator: analysis.statistic == .t ? " vs " : " · ")
    }

    private func degreesOfFreedomText(_ analysis: ClusterStatisticsAnalysis) -> String {
        if let numerator = analysis.numeratorDegreesOfFreedom,
           let denominator = analysis.denominatorDegreesOfFreedom {
            return " · df=(\(numerator), \(denominator))"
        }
        if let denominator = analysis.denominatorDegreesOfFreedom {
            return " · df=\(denominator)"
        }
        return ""
    }

    private func seedConditionsIfNeeded() {
        if viewModel.clusterConditionA == nil || !categories.contains(viewModel.clusterConditionA ?? "") {
            viewModel.clusterConditionA = categories.first
        }
        if viewModel.clusterConditionB == nil
            || !categories.contains(viewModel.clusterConditionB ?? "")
            || viewModel.clusterConditionB == viewModel.clusterConditionA {
            viewModel.clusterConditionB = categories.first { $0 != viewModel.clusterConditionA }
        }
    }

    private func seedFConditionsIfNeeded() {
        let needsInitialSelection = viewModel.clusterFConditions.isEmpty
        viewModel.clusterFConditions.formIntersection(categories)
        if needsInitialSelection {
            var selected = Set<String>()
            var usedSourceTrials = Set<Int64>()
            for category in categories {
                let sourceTrials = Set(rawSegments.lazy
                    .filter { $0.category == category }
                    .map { Int64(($0.sourceTimeSeconds * 1_000_000).rounded()) })
                guard !sourceTrials.isEmpty, usedSourceTrials.isDisjoint(with: sourceTrials) else { continue }
                selected.insert(category)
                usedSourceTrials.formUnion(sourceTrials)
            }
            viewModel.clusterFConditions = selected
        }
    }

    private func invalidateResult() {
        guard !viewModel.isRunning else { return }
        viewModel.clusterOutput = nil
        selectedClusterID = nil
    }

    private func clampWindowToAvailableEpochs() {
        guard let availableWindowMs else { return }
        let clippedStart = max(viewModel.clusterWindowStartMs, availableWindowMs.lowerBound)
        let clippedEnd = min(viewModel.clusterWindowEndMs, availableWindowMs.upperBound)
        if clippedEnd > clippedStart {
            viewModel.clusterWindowStartMs = clippedStart
            viewModel.clusterWindowEndMs = clippedEnd
        } else {
            viewModel.clusterWindowStartMs = availableWindowMs.lowerBound
            viewModel.clusterWindowEndMs = availableWindowMs.upperBound
        }
    }

    private func runAnalysis() {
        clampWindowToAvailableEpochs()
        guard canRun, let rawSignal else { return }

        analysisTask?.cancel()
        viewModel.clusterOutput = nil
        selectedClusterID = nil
        viewModel.statusMessage = nil
        viewModel.isRunning = true
        viewModel.runProgress = .init(fraction: 0, title: "Cluster Statistics", detail: "Starting…")

        let job = ClusterStatisticsJob(
            signal: rawSignal,
            segments: rawSegments,
            statistic: viewModel.clusterStatistic,
            conditionNames: selectedConditionNames,
            sensorLayout: sensorLayout,
            badChannels: badChannels,
            averageReference: averageReference,
            baselineCorrected: baselineCorrected,
            windowStartMs: viewModel.clusterWindowStartMs,
            windowEndMs: viewModel.clusterWindowEndMs,
            sampleStride: viewModel.clusterSampleStride,
            permutationCount: viewModel.clusterPermutationCount,
            clusterThreshold: activeClusterThreshold,
            seed: viewModel.clusterStatistic == .t ? 0xE7A_C1A5_7E57 : 0xE7A_F1A5_7E57
        )
        let (progressContinuation, progressTask) = ProgressBridge.make { (update: SingleTrialRunProgress) in
            viewModel.runProgress = update
        }

        analysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                ClusterStatisticsRunner.run(job: job, progress: progressContinuation)
            }
            let response = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel(); progressContinuation.finish() }
            )
            await ProgressBridge.finishAndWait(progressContinuation, task: progressTask)
            guard !Task.isCancelled else { return }
            viewModel.clusterOutput = response.output
            viewModel.statusMessage = response.errorMessage
            selectedClusterID = response.output?.analysis.clusters.first(where: {
                $0.pValue <= viewModel.clusterAlpha
            })?.id
            viewModel.isRunning = false
            viewModel.runProgress = nil
            analysisTask = nil
        }
    }

    private func cancelAnalysis(clearStatus: Bool) {
        analysisTask?.cancel()
        analysisTask = nil
        viewModel.isRunning = false
        viewModel.runProgress = nil
        if clearStatus { viewModel.statusMessage = "Cluster-statistics run cancelled." }
    }
}

private struct ClusterStatisticHeatmap: View {
    let result: ClusterStatisticsAnalysis
    let alpha: Double
    let selectedClusterID: Int?
    let onSelectCluster: (Int?) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let cellWidth = size.width / CGFloat(max(result.sampleCount, 1))
                let cellHeight = size.height / CGFloat(max(result.channelCount, 1))
                let scale = result.observedStatistics.map(abs).max() ?? 1
                let significantPoints = Set(result.clusters.filter { $0.pValue <= alpha }.flatMap(\.pointIndices))
                let selectedPoints = Set(result.clusters.first(where: { $0.id == selectedClusterID })?.pointIndices ?? [])

                for channel in 0..<result.channelCount {
                    for sample in 0..<result.sampleCount {
                        let point = channel * result.sampleCount + sample
                        let statistic = result.observedStatistics[point]
                        let rect = CGRect(
                            x: CGFloat(sample) * cellWidth,
                            y: CGFloat(channel) * cellHeight,
                            width: max(cellWidth + 0.4, 1),
                            height: max(cellHeight + 0.4, 1)
                        )
                        context.fill(
                            Path(rect),
                            with: .color(color(statistic, scale: scale).opacity(significantPoints.contains(point) ? 1 : 0.34))
                        )
                        if selectedPoints.contains(point) {
                            context.stroke(Path(rect), with: .color(.yellow.opacity(0.95)), lineWidth: 0.8)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    let sample = min(max(Int(value.location.x / max(proxy.size.width, 1) * CGFloat(result.sampleCount)), 0), result.sampleCount - 1)
                    let channel = min(max(Int(value.location.y / max(proxy.size.height, 1) * CGFloat(result.channelCount)), 0), result.channelCount - 1)
                    let point = channel * result.sampleCount + sample
                    onSelectCluster(result.clusters.first(where: {
                        $0.pValue <= alpha && $0.pointIndices.contains(point)
                    })?.id)
                }
            )
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func color(_ value: Double, scale: Double) -> Color {
        if result.statistic == .f {
            let normalized = min(max(value / max(scale, 1e-12), 0), 1)
            return Color(
                red: 0.96 - 0.52 * normalized,
                green: 0.96 - 0.83 * normalized,
                blue: 0.98 - 0.23 * normalized
            )
        }
        let normalized = min(max(value / max(scale, 1e-12), -1), 1)
        if normalized >= 0 {
            return Color(red: 0.96 - 0.20 * normalized, green: 0.96 - 0.80 * normalized, blue: 0.96 - 0.80 * normalized)
        }
        let magnitude = -normalized
        return Color(red: 0.96 - 0.73 * magnitude, green: 0.96 - 0.66 * magnitude, blue: 0.96 - 0.21 * magnitude)
    }
}

private struct ClusterTracePoint: Identifiable {
    let category: String
    let sample: Int
    let latencyMs: Double
    let mean: Double
    let standardError: Double
    var lowerBound: Double { mean - standardError }
    var upperBound: Double { mean + standardError }
    var id: String { "\(category)-\(sample)" }
}

private struct ClusterConditionTraceChart: View {
    let output: ClusterStatisticsOutput
    let cluster: ClusterPermutationAnalyzer.Cluster
    let showsStandardError: Bool
    let displayCategory: (String) -> String
    let categoryColor: (String) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showsStandardError ? "Condition mean waveforms ± SEM" : "Condition mean waveforms")
                .font(.caption.weight(.semibold))
            chart
        }
    }

    private var chart: some View {
        Chart {
            if showsStandardError {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Latency", point.latencyMs),
                        yStart: .value("Mean − SEM", point.lowerBound),
                        yEnd: .value("Mean + SEM", point.upperBound),
                        series: .value("Condition", point.category)
                    )
                    .foregroundStyle(categoryColor(point.category).opacity(0.16))
                }
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("Latency", point.latencyMs),
                    y: .value("Mean amplitude", point.mean),
                    series: .value("Condition", point.category)
                )
                .foregroundStyle(categoryColor(point.category))
                .lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            RuleMark(x: .value("Cluster start", latencyMs(cluster.startSample)))
                .foregroundStyle(Color.accentColor.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(x: .value("Cluster end", latencyMs(cluster.endSample)))
                .foregroundStyle(Color.accentColor.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartXAxisLabel("Latency (ms)")
        .chartYAxisLabel(showsStandardError ? "Trial mean ± SEM (µV)" : "Trial mean (µV)")
        .chartLegend(position: .top, alignment: .leading) {
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(output.analysis.conditionNames, id: \.self) { category in
                        HStack(spacing: 4) {
                            Circle().fill(categoryColor(category)).frame(width: 7, height: 7)
                            Text(displayCategory(category)).font(.caption)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var points: [ClusterTracePoint] {
        output.analysis.conditionNames.flatMap { category -> [ClusterTracePoint] in
            guard let summary = output.clusterWaveforms[cluster.id]?[category],
                  summary.mean.count == output.analysis.sampleCount,
                  summary.standardError.count == output.analysis.sampleCount else { return [] }
            return (0..<output.analysis.sampleCount).map { sample in
                return ClusterTracePoint(
                    category: category,
                    sample: sample,
                    latencyMs: latencyMs(sample),
                    mean: summary.mean[sample],
                    standardError: summary.standardError[sample]
                )
            }
        }
    }

    private func latencyMs(_ sample: Int) -> Double {
        Double(output.relativeSampleOffsets[sample]) / output.samplingRate * 1_000
    }
}
