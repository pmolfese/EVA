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
//  Trial-wise Phase 2: the trial-order plots. Kept in their own file rather
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
    var matchesOwnPool: Bool
    /// Measure name → value, from `SingleTrialAnalyzer`. Kept open so new
    /// measures appear as panels without touching this file.
    var measures: [String: Double]
}

/// One highlighted window's per-trial numbers: the peak inside it, and how well
/// each trial matches the average *within that window only*.
nonisolated struct TrialWindowSeries: Identifiable, Sendable {
    var id: UUID
    var name: String
    var colorIndex: Int
    var startMs: Double
    var endMs: Double
    /// trialIndex → peak amplitude inside the window.
    var peaks: [(trialIndex: Int, value: Double)]
    /// trialIndex → within-window r and β.
    var scores: [(trialIndex: Int, correlation: Double, slope: Double)]
}

nonisolated struct TrialDiagnosticsCategory: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var rows: [TrialDiagnosticsRow]
    /// Per-sample residuals for the heatmap, trial-ordered. Empty when not computed.
    var residuals: [[Double]] = []
    /// Running-average convergence toward the final average.
    var convergence: [TrialDriftStatistics.ConvergencePoint] = []
    /// One entry per highlighted window.
    var windowSeries: [TrialWindowSeries] = []
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

/// A draggable span shown over the butterfly plot.
///
/// Identified by a plain `String` rather than RIDE's component enum, so the same
/// overlay serves RIDE's fixed S/C/R and the free-form windows the other modes
/// let you add. RIDE passes its component `rawValue`; the others pass a UUID
/// string.
struct TrialWindowSelection: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var startMs: Double
    var endMs: Double
    var colorIndex: Int

    var color: Color { TrialWindowPalette.color(at: colorIndex) }
}

enum TrialWindowPalette {
    static let colors: [Color] = [.orange, .purple, .teal, .pink, .green, .indigo]
    static func color(at index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

// MARK: - Shared chrome

/// A "?" beside a chart title that explains how to read it.
///
/// Every panel here reports something whose interpretation is not obvious from
/// its axes — a slope near zero is a finding, a convergence curve ending at 1 is
/// not — so the explanation belongs next to the plot rather than in a document
/// nobody has open.
struct ChartHelpBadge: View {
    let title: String
    let what: String
    let read: String
    var caution: String?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.callout.weight(.semibold))
                labelled("What it shows", what)
                labelled("How to read it", read)
                if let caution {
                    labelled("Watch out", caution, tint: .orange)
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }

    private func labelled(_ heading: String, _ body: String, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            Text(body).font(.caption).foregroundStyle(.primary)
        }
    }
}

/// Chart title + help, so every panel gets the same treatment.
struct ChartTitle: View {
    let text: String
    let help: ChartHelpBadge

    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(.caption).foregroundStyle(.secondary)
            help
        }
    }
}

// MARK: - Shape vs magnitude

/// The r–β plane. Quadrants read: shape intact + magnitude intact = ordinary;
/// shape intact + magnitude gone = the response is absent; negative slope =
/// inverted; low correlation anywhere = noise.
struct TrialShapeMagnitudeScatter: View {
    let rows: [TrialDiagnosticsRow]
    /// Selecting a trial anywhere rings it here, so the rail and the table stay
    /// tied to the same object.
    var selectedTrial: Binding<Int?> = .constant(nil)

    private func symbolSize(for row: TrialDiagnosticsRow) -> CGFloat {
        row.matchesOwnPool ? 45 : 130
    }

    private var xDomain: ClosedRange<Double> {
        let lowest = rows.map(\.correlation).min() ?? -1
        return min(lowest - 0.05, 0.5) ... 1.05
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChartTitle(
                text: "Shape (r) vs magnitude (β)",
                help: ChartHelpBadge(
                    title: "Shape vs magnitude",
                    what: "Each trial regressed on the average of the OTHER trials in its category. r is shape similarity, β is amplitude scaling.",
                    read: "Top right (r high, β near 1) is an ordinary trial. r high with β near 0 means the response is absent — the participant was not engaged. Negative β runs opposite the average. Low r anywhere is noise or an artifact. Crosses matched an average from outside this trial's pool.",
                    caution: "Single-trial EEG is noisy: r far below 1 is normal, not evidence of a bad trial. Compare trials against each other rather than against an absolute cutoff."
                )
            )
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
                    .symbolSize(symbolSize(for: row))
                    .symbol(row.matchesOwnPool ? .circle : .cross)
                }
                if let selected = selectedTrial.wrappedValue,
                   let row = rows.first(where: { $0.trialIndex == selected }) {
                    PointMark(
                        x: .value("Correlation", row.correlation),
                        y: .value("Slope", row.slope)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(260)
                    .symbol(.circle.strokeBorder(lineWidth: 2))
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

// MARK: - Per-window peaks

/// One row per highlighted window: the peak inside it over trial order, beside
/// the within-window similarity. This is the point of drawing windows at all —
/// a number that refers to a component instead of to the whole epoch.
struct TrialWindowPanels: View {
    let series: [TrialWindowSeries]
    let axis: TrialDiagnosticsAxis
    let rows: [TrialDiagnosticsRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(series) { window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(TrialWindowPalette.color(at: window.colorIndex))
                            .frame(width: 8, height: 8)
                        Text(window.name).font(.caption.weight(.semibold))
                        Text("\(Int(window.startMs))–\(Int(window.endMs)) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        ChartHelpBadge(
                            title: "\(window.name): \(Int(window.startMs))–\(Int(window.endMs)) ms",
                            what: "Left: the largest deflection inside this window on each trial. Right: how well each trial matches the category average within this window only.",
                            read: "A drift in the left plot is that component changing over the run. On the right, r near 1 with β near 0 means the component's shape is there but its size is not — the signature of a trial the participant did not engage with.",
                            caution: "Windows that overlap in time both claim the shared variance, so a component's neighbour can inflate it. For overlapping components use the joint fit rather than reading each window alone."
                        )
                    }

                    HStack(alignment: .top, spacing: 14) {
                        windowChart(
                            title: "Peak in window",
                            points: window.peaks.map { (x: xValue(forTrial: $0.trialIndex), y: $0.value, trial: $0.trialIndex) },
                            color: TrialWindowPalette.color(at: window.colorIndex)
                        )
                        windowChart(
                            title: "r within window",
                            points: window.scores.map { (x: xValue(forTrial: $0.trialIndex), y: $0.correlation, trial: $0.trialIndex) },
                            color: TrialWindowPalette.color(at: window.colorIndex),
                            yDomain: -1 ... 1
                        )
                    }
                }
            }
        }
    }

    private func xValue(forTrial index: Int) -> Double {
        guard axis == .elapsedTime else { return Double(index) }
        return rows.first { $0.trialIndex == index }?.sourceTimeSeconds ?? Double(index)
    }

    /// A little headroom past the data, so points do not sit on the frame.
    private func defaultDomain(for points: [(x: Double, y: Double, trial: Int)]) -> ClosedRange<Double> {
        let values = points.map(\.y)
        guard let low = values.min(), let high = values.max(), high > low else { return -1 ... 1 }
        let padding = (high - low) * 0.1
        return (low - padding) ... (high + padding)
    }

    private func classification(forTrial index: Int) -> TrialSimilarityAnalyzer.Classification {
        rows.first { $0.trialIndex == index }?.classification ?? .typical
    }

    @ViewBuilder
    private func windowChart(
        title: String,
        points: [(x: Double, y: Double, trial: Int)],
        color: Color,
        yDomain: ClosedRange<Double>? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    PointMark(
                        x: .value("Order", point.x),
                        y: .value(title, point.y)
                    )
                    .foregroundStyle(classification(forTrial: point.trial).color)
                    .symbolSize(classification(forTrial: point.trial) == .typical ? 22 : 70)
                }
            }
            .chartYScale(domain: yDomain ?? defaultDomain(for: points))
            .frame(height: 120)
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
                ChartTitle(
                    text: "\(measure) over \(axis.rawValue.lowercased())",
                    help: ChartHelpBadge(
                        title: "\(measure) over the run",
                        what: "One point per trial in order, with a running median through them. ρ is Spearman's rank correlation against order, with its p.",
                        read: "A sloped median line means the measure drifted — fatigue, habituation or electrode drift. Trial order and elapsed time differ wherever the session had breaks, so check both.",
                        caution: "The p is uncorrected for the several measures in the picker; treat a single p just under 0.05 as a prompt to look, not a result."
                    )
                )
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
            ChartTitle(
                text: "\(measure) by group (mean ± SEM)",
                help: ChartHelpBadge(
                    title: "Split groups",
                    what: "Trials divided into equal, contiguous blocks in order — the classic split-half or early/middle/late comparison.",
                    read: "Bars are group means, whiskers the standard error. Non-overlapping whiskers suggest the measure really did change across the run.",
                    caution: "Groups are contiguous in trial order, so anything that tracks time — a break, a re-application of gel — lands in one group and looks like an effect."
                )
            )
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
            ChartTitle(
                text: "Running average vs final average",
                help: ChartHelpBadge(
                    title: "Convergence",
                    what: "How far the average of the first N trials sits from the final average, as N grows. Solid is RMS distance, dashed is 1 − r (shape only).",
                    read: "A curve that flattens early means the ERP had settled and more trials were not buying much. Still falling at the right edge means it had not.",
                    caution: "Both reach 0 at the last trial by construction. A late outlier cannot show as a dip, because the final average already contains it — only early contamination shows."
                )
            )
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
            ChartTitle(
                text: "Residual per trial over time",
                help: ChartHelpBadge(
                    title: "Residual heatmap",
                    what: "Trial minus the category average, per sample. Rows are trials in order, red above the average and blue below.",
                    read: "A whole row coloured means that trial is off throughout. A coloured column across many rows means a moment in the epoch where every trial departs — usually an artifact or a mistimed marker rather than a trial problem.",
                    caution: "Intensity is scaled to the 95th percentile of all residuals, so one extreme sample cannot wash the map out — but it also means the scale changes between categories."
                )
            )
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
