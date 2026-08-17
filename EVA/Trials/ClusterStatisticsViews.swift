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
        let threshold: ClusterFormingThreshold
        let sampleStride: Int
        let inference: ClusterInferenceMode
        let tfce: TFCEParameters
        let adjacency: ClusterAdjacencyConfiguration
        let repeatedMeasures: Bool
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
            threshold: activeThresholdSpecification,
            sampleStride: viewModel.clusterSampleStride,
            inference: viewModel.clusterInference,
            tfce: viewModel.clusterTFCE,
            adjacency: viewModel.clusterAdjacency,
            repeatedMeasures: viewModel.clusterRepeatedMeasures
        )
    }

    private var canRun: Bool {
        guard rawSignal != nil else { return false }
        let requiredCount = viewModel.clusterStatistic == .t ? 2 : 3
        guard selectedConditionNames.count >= requiredCount,
              selectedConditionNames.allSatisfy({ condition in
                  rawSegments.filter { $0.category == condition }.count >= 2
              }) else { return false }
        guard viewModel.clusterAdjacency.isValid else { return false }
        if viewModel.clusterInference == .tfce, !viewModel.clusterTFCE.isValid { return false }
        let thresholdOK = viewModel.clusterInference == .tfce
            || (viewModel.clusterUsesProbabilityThreshold
                ? viewModel.clusterThresholdProbability > 0 && viewModel.clusterThresholdProbability < 1
                : activeClusterThreshold > 0)
        return thresholdOK
            && viewModel.clusterWindowEndMs > viewModel.clusterWindowStartMs
            && viewModel.clusterPermutationCount > 0
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

    /// The threshold as the analyzer will receive it. Under TFCE the value is
    /// unused, but keeping it in the invalidation signature is harmless and
    /// avoids a second code path.
    private var activeThresholdSpecification: ClusterFormingThreshold {
        viewModel.clusterUsesProbabilityThreshold
            ? .probability(viewModel.clusterThresholdProbability)
            : .statistic(activeClusterThreshold)
    }

    /// The critical statistic a probability threshold resolves to, for the
    /// live readout beside the field. Nil until enough conditions are chosen
    /// to know the degrees of freedom.
    private var previewedCriticalValue: Double? {
        guard viewModel.clusterUsesProbabilityThreshold,
              viewModel.clusterInference == .clusterMass,
              let degrees = previewedDegreesOfFreedom else { return nil }
        switch viewModel.clusterStatistic {
        case .t:
            return ClusterStatisticsDistributions.criticalT(
                twoTailedAlpha: viewModel.clusterThresholdProbability,
                degreesOfFreedom: degrees.denominator
            )
        case .f:
            guard let numerator = degrees.numerator else { return nil }
            return ClusterStatisticsDistributions.criticalF(
                alpha: viewModel.clusterThresholdProbability,
                numeratorDegreesOfFreedom: numerator,
                denominatorDegreesOfFreedom: degrees.denominator
            )
        }
    }

    /// Degrees of freedom the run will have, derived from the currently chosen
    /// conditions and design so the threshold readout is correct before the run.
    private var previewedDegreesOfFreedom: (numerator: Double?, denominator: Double)? {
        let counts = selectedConditionNames.map { condition in
            rawSegments.filter { $0.category == condition }.count
        }
        guard counts.count >= (viewModel.clusterStatistic == .t ? 2 : 3),
              counts.allSatisfy({ $0 >= 2 }) else { return nil }

        switch (viewModel.clusterStatistic, viewModel.clusterRepeatedMeasures) {
        case (.t, false):
            return (nil, Double(counts.reduce(0, +) - 2))
        case (.t, true):
            // Paired units are limited by the smaller condition.
            let units = counts.min() ?? 0
            guard units > 1 else { return nil }
            return (nil, Double(units - 1))
        case (.f, false):
            return (Double(counts.count - 1), Double(counts.reduce(0, +) - counts.count))
        case (.f, true):
            let units = counts.min() ?? 0
            guard units > 1 else { return nil }
            return (Double(counts.count - 1), Double((counts.count - 1) * (units - 1)))
        }
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
            seedAdjacencyDistanceIfNeeded()
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
                    Text(designSubtitle)
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

            designAndAdjacencyRow

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

                if viewModel.clusterInference == .clusterMass {
                    thresholdControl
                } else {
                    tfceControls
                }

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
                } else if let summary = previewedAdjacencySummary {
                    Label(
                        String(format: "%.1f neighbors per sensor", summary.meanNeighborCount),
                        systemImage: summary.isDegenerate || summary.isOverConnected
                            ? "exclamationmark.triangle"
                            : "point.3.connected.trianglepath.dotted"
                    )
                    .foregroundStyle(summary.isDegenerate || summary.isOverConnected ? Color.orange : .secondary)
                    .help(adjacencyHelpText(summary))
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

            if let caution = plannedPairingMode?.caution {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(viewModel.clusterInference == .tfce
                 ? "TFCE corrects each channel × time point against the permutation distribution of the largest enhanced score. Points listed together below are a readability grouping, not the inference unit."
                 : "Corrected p-values apply to whole clusters. Their member sensors and time samples should not be interpreted as independently significant or as precise spatial/temporal boundaries.")
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

    // MARK: - Design, inference and adjacency controls

    private var designSubtitle: String {
        let unit = viewModel.clusterRepeatedMeasures ? "Matched units" : "Independent single trials"
        let statistic = viewModel.clusterStatistic == .t
            ? (viewModel.clusterRepeatedMeasures ? "paired two-sided t" : "two-sided t")
            : (viewModel.clusterRepeatedMeasures ? "repeated-measures omnibus F" : "one-way omnibus F")
        let correction = viewModel.clusterInference == .tfce
            ? "threshold-free cluster enhancement"
            : "maximum cluster-mass correction"
        return "\(unit) · \(statistic) · \(correction)"
    }

    private var designAndAdjacencyRow: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Design").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $viewModel.clusterRepeatedMeasures) {
                    Text("Independent").tag(false)
                    Text(viewModel.clusterStatistic == .t ? "Paired" : "Repeated measures").tag(true)
                }
                .labelsHidden()
                .frame(width: 160)
                .disabled(viewModel.isRunning)
                .help(viewModel.clusterStatistic == .t
                      ? ClusterPermutationAnalyzer.Design.repeatedMeasures.explanation
                      : ClusterPermutationFAnalyzer.Design.repeatedMeasures.explanation)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Correction").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $viewModel.clusterInference) {
                    ForEach(ClusterInferenceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
                .disabled(viewModel.isRunning)
                .help(viewModel.clusterInference.explanation)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Sensor neighbors").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $viewModel.clusterAdjacency.method) {
                    ForEach(ClusterAdjacencyMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
                .disabled(viewModel.isRunning || sensorLayout == nil)
                .help(viewModel.clusterAdjacency.method.explanation)
            }

            switch viewModel.clusterAdjacency.method {
            case .distance:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Radius").font(.caption2).foregroundStyle(.secondary)
                    TextField(
                        "",
                        value: $viewModel.clusterAdjacency.distance,
                        format: .number.precision(.fractionLength(2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 62)
                    .disabled(viewModel.isRunning || sensorLayout == nil)
                    .help("Fraction of the head radius. Sensors closer than this are neighbors.")
                }
            case .nearestNeighbors:
                VStack(alignment: .leading, spacing: 2) {
                    Text("K").font(.caption2).foregroundStyle(.secondary)
                    Stepper(
                        "\(viewModel.clusterAdjacency.neighborCount)",
                        value: $viewModel.clusterAdjacency.neighborCount,
                        in: 1...32
                    )
                    .frame(width: 74)
                    .disabled(viewModel.isRunning || sensorLayout == nil)
                }
            case .temporalOnly:
                EmptyView()
            }

            Spacer()
        }
    }

    private var thresholdControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(viewModel.clusterUsesProbabilityThreshold
                     ? "Cluster-forming p"
                     : (viewModel.clusterStatistic == .t ? "Cluster |t|" : "Cluster F"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    toggleThresholdMode()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(viewModel.isRunning)
                .help(viewModel.clusterUsesProbabilityThreshold
                      ? "Switch to entering the raw statistic."
                      : "Switch to entering an uncorrected p-value, converted to the critical statistic for this design's degrees of freedom.")
            }
            HStack(spacing: 5) {
                if viewModel.clusterUsesProbabilityThreshold {
                    TextField(
                        "",
                        value: $viewModel.clusterThresholdProbability,
                        format: .number.precision(.fractionLength(3))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .disabled(viewModel.isRunning)
                    if let critical = previewedCriticalValue {
                        Text("= \(viewModel.clusterStatistic == .t ? "|t|" : "F") \(String(format: "%.2f", critical))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField("", value: activeThresholdBinding, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 66)
                        .disabled(viewModel.isRunning)
                }
            }
        }
    }

    private var tfceControls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TFCE E").font(.caption2).foregroundStyle(.secondary)
                TextField(
                    "",
                    value: $viewModel.clusterTFCE.extentExponent,
                    format: .number.precision(.fractionLength(2))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .disabled(viewModel.isRunning)
                .help("Extent exponent. 0.5 is the Smith & Nichols default.")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("TFCE H").font(.caption2).foregroundStyle(.secondary)
                TextField(
                    "",
                    value: $viewModel.clusterTFCE.heightExponent,
                    format: .number.precision(.fractionLength(2))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .disabled(viewModel.isRunning)
                .help("Height exponent. 2.0 is the Smith & Nichols default.")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Steps").font(.caption2).foregroundStyle(.secondary)
                Stepper("\(viewModel.clusterTFCE.stepCount)", value: $viewModel.clusterTFCE.stepCount, in: 2...500, step: 10)
                    .frame(width: 84)
                    .disabled(viewModel.isRunning)
                    .help("Integration steps between zero and the statistic maximum.")
            }
        }
    }

    private func toggleThresholdMode() {
        // Carry the current threshold across so the switch does not silently
        // change what the run will do.
        if viewModel.clusterUsesProbabilityThreshold {
            if let critical = previewedCriticalValue {
                activeThresholdBinding.wrappedValue = (critical * 100).rounded() / 100
            }
            viewModel.clusterUsesProbabilityThreshold = false
        } else {
            if let degrees = previewedDegreesOfFreedom {
                let probability: Double? = switch viewModel.clusterStatistic {
                case .t:
                    ClusterStatisticsDistributions.twoTailedTProbability(
                        activeClusterThreshold,
                        degreesOfFreedom: degrees.denominator
                    )
                case .f:
                    degrees.numerator.map { numerator in
                        ClusterStatisticsDistributions.upperTailFProbability(
                            activeClusterThreshold,
                            numeratorDegreesOfFreedom: numerator,
                            denominatorDegreesOfFreedom: degrees.denominator
                        )
                    }
                }
                if let probability, probability > 0, probability < 1 {
                    viewModel.clusterThresholdProbability = (probability * 1_000).rounded() / 1_000
                }
            }
            viewModel.clusterUsesProbabilityThreshold = true
        }
    }

    /// The adjacency the current settings would build, for the live neighbor
    /// readout. Cheap enough to recompute — it is O(channels²) once per redraw
    /// on at most a few hundred sensors.
    private var previewedAdjacencySummary: ClusterAdjacencySummary? {
        guard let sensorLayout, let rawSignal else { return nil }
        let layoutChannels = Set(sensorLayout.positions.map(\.channelIndex))
        let channels = rawSignal.data.indices.filter {
            layoutChannels.contains($0) && !badChannels.contains($0)
        }
        guard !channels.isEmpty else { return nil }
        return ClusterSpatialAdjacency.summarize(
            ClusterSpatialAdjacency.build(
                channelIndices: channels,
                layout: sensorLayout,
                configuration: viewModel.clusterAdjacency
            )
        )
    }

    private func adjacencyHelpText(_ summary: ClusterAdjacencySummary) -> String {
        var parts = [
            "Range \(summary.minimumNeighborCount)–\(summary.maximumNeighborCount) neighbors, \(summary.componentCount) connected group\(summary.componentCount == 1 ? "" : "s").",
        ]
        if summary.isolatedChannelCount > 0 {
            parts.append("\(summary.isolatedChannelCount) sensor\(summary.isolatedChannelCount == 1 ? "" : "s") have no neighbors and can only form temporal clusters. Increase the radius or K.")
        }
        if summary.isOverConnected {
            parts.append("Neighborhoods this large tend to merge distinct effects into one uninterpretable cluster.")
        }
        return parts.joined(separator: " ")
    }

    /// How the run would match units, so the caution appears before the run
    /// rather than only in its results.
    private var plannedPairingMode: ClusterPairingMode? {
        guard viewModel.clusterRepeatedMeasures else { return nil }
        let selected = Set(selectedConditionNames)
        let segments = rawSegments.filter { selected.contains($0.category) }
        guard !segments.isEmpty else { return nil }
        return segments.allSatisfy { $0.subject?.isEmpty == false } ? .subject : .trialOrder
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
                Text(methodSummary(output))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if output.adjacencySummary.meanNeighborCount == 0 {
                    Label("temporal-only adjacency", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let mode = output.analysis.pairingMode {
                    Label(mode.label, systemImage: mode == .subject ? "person.2" : "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundStyle(mode == .subject ? .secondary : Color.orange)
                        .help(mode.caution ?? "One observation per subject per condition.")
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

    /// One line recording exactly how the reported p-values were produced, so
    /// a figure exported from this pane can be described in a methods section.
    private func methodSummary(_ output: ClusterStatisticsOutput) -> String {
        let analysis = output.analysis
        var parts = ["\(analysis.permutationCount) permutations"]
        switch analysis.inference {
        case .clusterMass:
            let symbol = analysis.statistic == .t ? "|t|" : "F"
            var threshold = "\(symbol) ≥ \(String(format: "%.2f", analysis.resolvedThreshold ?? 0))"
            if case .probability(let alpha) = analysis.thresholdSpecification {
                threshold += " (p \(formatP(alpha)))"
            }
            parts.append(threshold)
        case .tfce:
            parts.append("TFCE E=\(String(format: "%.2g", analysis.tfce.extentExponent)) H=\(String(format: "%.2g", analysis.tfce.heightExponent)) · \(analysis.tfce.stepCount) steps")
        }
        parts.append(adjacencyDescription(output))
        let degrees = degreesOfFreedomText(analysis)
        if !degrees.isEmpty { parts.append(String(degrees.dropFirst(3))) }
        return parts.joined(separator: " · ")
    }

    private func adjacencyDescription(_ output: ClusterStatisticsOutput) -> String {
        switch output.adjacencyConfiguration.method {
        case .temporalOnly:
            return "no spatial adjacency"
        case .distance:
            return "neighbors < \(String(format: "%.2f", output.adjacencyConfiguration.distance)) r (\(String(format: "%.1f", output.adjacencySummary.meanNeighborCount)) mean)"
        case .nearestNeighbors:
            return "\(output.adjacencyConfiguration.neighborCount)-nearest neighbors (\(String(format: "%.1f", output.adjacencySummary.meanNeighborCount)) mean)"
        }
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

    /// Derives the starting neighbor radius from this montage's own sensor
    /// spacing. A constant default would be far too small for a 32-channel cap
    /// and far too large for a 256-channel net.
    private func seedAdjacencyDistanceIfNeeded() {
        guard !viewModel.clusterAdjacencyDistanceInitialized,
              let sensorLayout, let rawSignal else { return }
        let layoutChannels = Set(sensorLayout.positions.map(\.channelIndex))
        let channels = rawSignal.data.indices.filter {
            layoutChannels.contains($0) && !badChannels.contains($0)
        }
        if let suggested = ClusterSpatialAdjacency.suggestedDistance(
            channelIndices: channels,
            layout: sensorLayout
        ) {
            viewModel.clusterAdjacency.distance = suggested
        }
        viewModel.clusterAdjacencyDistanceInitialized = true
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
            threshold: activeThresholdSpecification,
            inference: viewModel.clusterInference,
            tfce: viewModel.clusterTFCE,
            adjacency: sensorLayout == nil
                ? ClusterAdjacencyConfiguration(method: .temporalOnly)
                : viewModel.clusterAdjacency,
            repeatedMeasures: viewModel.clusterRepeatedMeasures,
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
