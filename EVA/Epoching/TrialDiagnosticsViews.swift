//
//  TrialDiagnosticsViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Phase 2 of TRIALWISE.md: the trial-order plots. Kept in their own file rather
//  than added to SingleTrialAnalysisViews.swift, which is already ~4,000 lines.
//
//  Panels, in the order they answer questions:
//    · shape vs magnitude scatter — WHAT kind of odd is each trial
//    · measure over trial order   — WHEN did it happen, and is there drift
//    · split groups               — early/middle/late, the classic comparison
//    · convergence                — had the average settled by the end
//    · residual heatmap           — is a trial bad throughout or just briefly
//

import Charts
import SwiftUI

// MARK: - Input

/// One trial's row, joining the amplitude/latency measures to the similarity
/// scores. Assembled by the caller because the two analyzers are deliberately
/// independent.
nonisolated struct TrialDiagnosticsRow: Identifiable, Sendable {
    var id: Int
    var trialIndex: Int
    var sourceTimeSeconds: Double
    var correlation: Double
    var slope: Double
    var normalizedResidualRMS: Double
    var robustDistance: Double
    var classification: TrialSimilarityAnalyzer.Classification
    var bestMatchingCategory: String?
    var matchesOwnCategory: Bool
    /// Measure name → value, from `SingleTrialAnalyzer`. Kept open so new
    /// measures appear as panels without touching this file.
    var measures: [String: Double]
}

nonisolated struct TrialDiagnosticsCategory: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var rows: [TrialDiagnosticsRow]
    /// Per-sample residuals for the heatmap, trial-ordered. Empty when not computed.
    var residuals: [[Double]] = []
    /// Running-average convergence toward the final average.
    var convergence: [TrialDriftStatistics.ConvergencePoint] = []
}

enum TrialDiagnosticsAxis: String, CaseIterable, Identifiable {
    case trialIndex = "Trial order"
    case elapsedTime = "Elapsed time"

    var id: String { rawValue }
}

// MARK: - Colors

extension TrialSimilarityAnalyzer.Classification {
    var color: Color {
        switch self {
        case .typical: return .teal
        case .attenuated: return .orange
        case .inverted: return .purple
        case .divergent: return .red
        }
    }
}

// MARK: - Root

struct TrialDiagnosticsPanels: View {
    let categories: [TrialDiagnosticsCategory]
    @Binding var axis: TrialDiagnosticsAxis
    @Binding var selectedMeasure: String
    @Binding var groupCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            controls

            ForEach(categories) { category in
                VStack(alignment: .leading, spacing: 14) {
                    header(for: category)
                    TrialShapeMagnitudeScatter(rows: category.rows)
                    TrialMeasureOverOrderChart(
                        rows: category.rows,
                        measure: selectedMeasure,
                        axis: axis
                    )
                    TrialSplitGroupChart(
                        rows: category.rows,
                        measure: selectedMeasure,
                        groupCount: groupCount
                    )
                    if !category.convergence.isEmpty {
                        TrialConvergenceChart(points: category.convergence)
                    }
                    if !category.residuals.isEmpty {
                        TrialResidualHeatmap(residuals: category.residuals)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var availableMeasures: [String] {
        let names = Set(categories.flatMap { $0.rows.flatMap(\.measures.keys) })
        return names.sorted()
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("X axis", selection: $axis) {
                ForEach(TrialDiagnosticsAxis.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .help("Trial order is ordinal; elapsed time includes gaps, and drift often tracks the clock rather than the count.")

            Picker("Measure", selection: $selectedMeasure) {
                ForEach(availableMeasures, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 240)

            Stepper("Groups: \(groupCount)", value: $groupCount, in: 2 ... 8)
                .frame(width: 140)

            Spacer()
            classificationLegend
        }
    }

    private var classificationLegend: some View {
        HStack(spacing: 10) {
            ForEach(TrialSimilarityAnalyzer.Classification.allCases, id: \.self) { classification in
                HStack(spacing: 4) {
                    Circle().fill(classification.color).frame(width: 7, height: 7)
                    Text(classification.displayName).font(.caption2).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
    }

    private func header(for category: TrialDiagnosticsCategory) -> some View {
        let counts = Dictionary(grouping: category.rows, by: \.classification)
            .mapValues(\.count)
        let mislabels = category.rows.filter { !$0.matchesOwnCategory }

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(category.name).font(.headline)
                Text("\(category.rows.count) trials")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(TrialSimilarityAnalyzer.Classification.allCases, id: \.self) { classification in
                    if let count = counts[classification], count > 0, classification != .typical {
                        Text("\(count) \(classification.displayName.lowercased())")
                            .font(.caption)
                            .foregroundStyle(classification.color)
                    }
                }
            }
            if !mislabels.isEmpty {
                // The one claim here that is checkable rather than heuristic.
                Text("\(mislabels.count) trial\(mislabels.count == 1 ? "" : "s") match another category's average more closely: "
                     + mislabels.prefix(6).map { "#\($0.trialIndex) → \($0.bestMatchingCategory ?? "?")" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Shape vs magnitude

/// The r–β plane. Quadrants read: shape intact + magnitude intact = ordinary;
/// shape intact + magnitude gone = the response is absent; negative slope =
/// inverted; low correlation anywhere = noise.
struct TrialShapeMagnitudeScatter: View {
    let rows: [TrialDiagnosticsRow]

    private var xDomain: ClosedRange<Double> {
        let lowest = rows.map(\.correlation).min() ?? -1
        return min(lowest - 0.05, 0.5) ... 1.05
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shape (r) vs magnitude (β)").font(.caption).foregroundStyle(.secondary)
            Chart {
                RectangleMark(
                    xStart: .value("r", 0.4), xEnd: .value("r", 1.0),
                    yStart: .value("slope", -0.2), yEnd: .value("slope", 0.5)
                )
                .foregroundStyle(Color.orange.opacity(0.08))

                RuleMark(y: .value("Slope", 1.0))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                RuleMark(y: .value("Slope", 0))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary)

                ForEach(rows) { row in
                    PointMark(
                        x: .value("Correlation", row.correlation),
                        y: .value("Slope", row.slope)
                    )
                    .foregroundStyle(row.classification.color)
                    .symbolSize(row.matchesOwnCategory ? 45 : 130)
                    .symbol(row.matchesOwnCategory ? .circle : .cross)
                }
            }
            // Typical trials pile up just below r = 1, so a fixed −1…1 domain
            // spends nearly all its width on empty space and clips the cluster
            // against the right edge. Fit the low end to the data and keep a
            // little headroom past 1.
            .chartXScale(domain: xDomain)
            .chartXAxisLabel("r")
            .chartYAxisLabel("β")
            .frame(height: 200)
        }
    }
}

// MARK: - Measure over order

struct TrialMeasureOverOrderChart: View {
    let rows: [TrialDiagnosticsRow]
    let measure: String
    let axis: TrialDiagnosticsAxis

    private var points: [(x: Double, y: Double, row: TrialDiagnosticsRow)] {
        rows.compactMap { row in
            guard let value = row.measures[measure] else { return nil }
            let x = axis == .trialIndex ? Double(row.trialIndex) : row.sourceTimeSeconds
            return (x, value, row)
        }
    }

    private var drift: TrialDriftStatistics.RankCorrelation? {
        TrialDriftStatistics.rankCorrelation(of: points.map(\.y), against: points.map(\.x))
    }

    private var smoothed: [(x: Double, y: Double)] {
        let values = points.map(\.y)
        let median = TrialDriftStatistics.runningMedian(values, window: max(5, values.count / 8))
        return zip(points.map(\.x), median).map { ($0, $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(measure) over \(axis.rawValue.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let drift {
                    // ρ says whether it is monotonic; the p is on n trials, and
                    // is not corrected for the several measures on offer.
                    Text("ρ = \(drift.rho, format: .number.precision(.fractionLength(2)))  p = \(drift.p, format: .number.precision(.fractionLength(3)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(drift.isSignificant ? Color.orange : .secondary)
                }
            }
            Chart {
                ForEach(Array(smoothed.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Order", point.x),
                        y: .value("Median", point.y),
                        series: .value("Series", "median")
                    )
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    PointMark(
                        x: .value("Order", point.x),
                        y: .value(measure, point.y)
                    )
                    .foregroundStyle(point.row.classification.color)
                    .symbolSize(point.row.classification == .typical ? 30 : 90)
                }
            }
            .chartXAxisLabel(axis == .trialIndex ? "Trial" : "Seconds")
            .frame(height: 180)
        }
    }
}

// MARK: - Split groups

struct TrialSplitGroupChart: View {
    let rows: [TrialDiagnosticsRow]
    let measure: String
    let groupCount: Int

    private var summaries: [TrialDriftStatistics.GroupSummary] {
        let values = rows.sorted { $0.trialIndex < $1.trialIndex }.compactMap { $0.measures[measure] }
        return TrialDriftStatistics.groupSummaries(values, groupCount: groupCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(measure) by group (mean ± SEM)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(summaries) { group in
                BarMark(
                    x: .value("Group", group.label),
                    y: .value(measure, group.mean)
                )
                .foregroundStyle(Color.accentColor.opacity(0.7))

                RuleMark(
                    x: .value("Group", group.label),
                    yStart: .value("Low", group.mean - group.standardError),
                    yEnd: .value("High", group.mean + group.standardError)
                )
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(.primary)
            }
            .frame(height: 150)
        }
    }
}

// MARK: - Convergence

struct TrialConvergenceChart: View {
    let points: [TrialDriftStatistics.ConvergencePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Running average vs final average")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(points) { point in
                LineMark(
                    x: .value("Trials", point.trialCount),
                    y: .value("Distance", point.normalizedDistanceToFinal),
                    series: .value("Series", "distance")
                )
                .foregroundStyle(Color.accentColor)

                LineMark(
                    x: .value("Trials", point.trialCount),
                    y: .value("Distance", 1 - point.correlationWithFinal),
                    series: .value("Series", "shape")
                )
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXAxisLabel("Trials averaged")
            .chartYAxisLabel("distance to final")
            .frame(height: 150)
            Text("Solid: RMS distance from the final average. Dashed: 1 − r, shape only. Both reach 0 at the last trial by construction, so read the approach — still falling at the right edge means the average had not settled.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Residual heatmap

/// Trials down, time across, |residual| as intensity. Separates a trial that is
/// bad throughout from one that is bad only in a window.
struct TrialResidualHeatmap: View {
    let residuals: [[Double]]

    private var scale: Double {
        let magnitudes = residuals.flatMap { $0.map(abs) }
        guard !magnitudes.isEmpty else { return 1 }
        // 95th percentile rather than the max, so one enormous sample does not
        // wash the whole map out.
        let sorted = magnitudes.sorted()
        return max(sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)], 1e-9)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Residual per trial over time")
                .font(.caption)
                .foregroundStyle(.secondary)
            Canvas { context, size in
                guard let columns = residuals.first?.count, columns > 0 else { return }
                let rowHeight = size.height / CGFloat(residuals.count)
                let columnWidth = size.width / CGFloat(columns)
                let limit = scale

                for (rowIndex, row) in residuals.enumerated() {
                    for (columnIndex, value) in row.enumerated() {
                        let intensity = min(abs(value) / limit, 1)
                        guard intensity > 0.02 else { continue }
                        let rect = CGRect(
                            x: CGFloat(columnIndex) * columnWidth,
                            y: CGFloat(rowIndex) * rowHeight,
                            width: columnWidth + 0.5,
                            height: rowHeight + 0.5
                        )
                        context.fill(
                            Path(rect),
                            with: .color(value >= 0
                                         ? Color.red.opacity(intensity)
                                         : Color.blue.opacity(intensity))
                        )
                    }
                }
            }
            .frame(height: max(90, min(Double(residuals.count) * 6, 260)))
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            Text("Rows are trials in order; red is above the average, blue below.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
