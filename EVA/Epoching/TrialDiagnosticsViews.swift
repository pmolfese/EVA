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

/// The two alignment views for one trial, both computed against the average of
/// the OTHER trials. Keeping the metrics together guarantees the heatmap and
/// affine scatter refer to the same reference and trial index.
nonisolated struct TrialAlignmentSeries: Identifiable, Sendable {
    var id: Int { trialIndex }
    var trialIndex: Int
    var timeResolvedCorrelation: [TrialAlignmentMetrics.TimeResolvedPoint]
    var affineFit: TrialAlignmentMetrics.AffineFit?
}

/// Ready-to-display alignment diagnostics plus the deliberately bounded search
/// settings shown in the panel's caption.
nonisolated struct TrialAlignmentSummary: Sendable {
    var trials: [TrialAlignmentSeries]
    var correlationWindowMs: Double
    var correlationStepMs: Double
    var maximumLagMs: Double
    var maximumTimeScaleDeviation: Double

    static func analyze(
        trials: [SingleTrialAnalyzer.TrialInput],
        samplingRate: Double,
        correlationWindowMs: Double = 100,
        correlationStepMs: Double = 10,
        maximumLagMs: Double = 100,
        maximumTimeScaleDeviation: Double = 0.10
    ) -> TrialAlignmentSummary? {
        guard trials.count >= 2, samplingRate > 0 else { return nil }

        let windowSamples = max(Int((correlationWindowMs / 1000 * samplingRate).rounded()), 3)
        let stepSamples = max(Int((correlationStepMs / 1000 * samplingRate).rounded()), 1)
        let maxLagSamples = max(Int((maximumLagMs / 1000 * samplingRate).rounded()), 0)
        let lagToleranceSamples = max(0.05 * samplingRate, 1) // 50 ms

        let series = trials.indices.compactMap { index -> TrialAlignmentSeries? in
            let others = trials.enumerated().compactMap { offset, trial in
                offset == index ? nil : trial
            }
            guard let reference = TrialSimilarityAnalyzer.average(others, reference: .mean) else { return nil }
            let trial = trials[index]
            let samples = trial.samples.map(Double.init)
            return TrialAlignmentSeries(
                trialIndex: index,
                timeResolvedCorrelation: TrialAlignmentMetrics.timeResolvedCorrelation(
                    trial: samples,
                    reference: reference,
                    windowSamples: windowSamples,
                    stepSamples: stepSamples,
                    stimulusOffsetSamples: trial.stimulusOffsetSamples,
                    samplingRate: samplingRate
                ),
                affineFit: TrialAlignmentMetrics.affineFit(
                    trial: samples,
                    reference: reference,
                    maxLagSamples: maxLagSamples,
                    samplingRate: samplingRate,
                    maxTimeScaleDeviation: maximumTimeScaleDeviation,
                    timeScaleAnchorSample: Double(trial.stimulusOffsetSamples),
                    lagToleranceSamples: lagToleranceSamples
                )
            )
        }

        guard !series.isEmpty else { return nil }
        return TrialAlignmentSummary(
            trials: series,
            correlationWindowMs: correlationWindowMs,
            correlationStepMs: correlationStepMs,
            maximumLagMs: maximumLagMs,
            maximumTimeScaleDeviation: maximumTimeScaleDeviation
        )
    }
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
    /// trialIndex → that trial's samples, for the hover overlay. Empty when the
    /// caller did not supply them; the overlay then simply does not appear.
    var trialWaveforms: [Int: [Double]] = [:]
    /// The category average the trials were scored against.
    var averageWaveform: [Double] = []
    var samplingRate: Double = 0
    var stimulusOffsetSamples: Int = 0
    /// Sliding-correlation and bounded affine-fit results. Nil when the caller
    /// did not request alignment diagnostics.
    var alignment: TrialAlignmentSummary? = nil
    /// Leave-one-out residual attribution across the selected channels. Nil
    /// when fewer than two trials or no common channels were available.
    var channelResiduals: TrialChannelResidualAnalyzer.Summary? = nil
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
    /// Waveforms for the hover overlay. Empty leaves the plot exactly as it was:
    /// hovering still highlights nothing and clicking still selects.
    var trialWaveforms: [Int: [Double]] = [:]
    var averageWaveform: [Double] = []
    var samplingRate: Double = 0
    var stimulusOffsetSamples: Int = 0

    /// The dot under the pointer, cleared when the pointer leaves.
    @State private var hoveredTrial: Int?
    /// A dot that was option+clicked, so the overlay stays up while you read it.
    @State private var pinnedTrial: Int?

    private func symbolSize(for row: TrialDiagnosticsRow) -> CGFloat {
        row.matchesOwnPool ? 45 : 130
    }

    private var xDomain: ClosedRange<Double> {
        let lowest = rows.map(\.correlation).min() ?? -1
        return min(lowest - 0.05, 0.5) ... 1.05
    }

    /// What the overlay is showing: the pinned trial wins over the hovered one,
    /// so moving the pointer away to read the card does not dismiss it.
    private var overlayRow: TrialDiagnosticsRow? {
        guard !trialWaveforms.isEmpty else { return nil }
        guard let index = pinnedTrial ?? hoveredTrial else { return nil }
        return rows.first { $0.trialIndex == index }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChartTitle(
                text: "Shape (r) vs magnitude (β)",
                help: ChartHelpBadge(
                    title: "Shape vs magnitude",
                    what: "Each trial regressed on the average of the OTHER trials in its category. r is shape similarity, β is amplitude scaling.",
                    read: "Top right (r high, β near 1) is an ordinary trial. r high with β near 0 means the response is absent — the participant was not engaged. Negative β runs opposite the average. Low r anywhere is noise or an artifact. Crosses matched an average from outside this trial's pool. Hover a dot to see that trial drawn over the average; option+click keeps that card up, and a plain click selects the trial everywhere.",
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
                if let row = overlayRow, row.trialIndex != selectedTrial.wrappedValue {
                    PointMark(
                        x: .value("Correlation", row.correlation),
                        y: .value("Slope", row.slope)
                    )
                    .foregroundStyle(Color.secondary)
                    .symbolSize(200)
                    .symbol(.circle.strokeBorder(lineWidth: 1.5))
                }
            }
            // Typical trials pile up just below r = 1, so a fixed −1…1 domain
            // spends nearly all its width on empty space and clips the cluster
            // against the right edge. Fit the low end to the data and keep a
            // little headroom past 1.
            .chartXScale(domain: xDomain)
            .chartXAxisLabel("r")
            .chartYAxisLabel("β")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoveredTrial = nearestTrial(to: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hoveredTrial = nil
                            }
                        }
                        // Option+click pins the card, matching the modifier the
                        // rest of the app uses for "show me more about this".
                        // Attached ahead of the plain tap so the modified click
                        // does not fall through to selection.
                        .gesture(
                            SpatialTapGesture()
                                .modifiers(.option)
                                .onEnded { event in
                                    guard let index = nearestTrial(to: event.location, proxy: proxy, geometry: geometry) else {
                                        pinnedTrial = nil
                                        return
                                    }
                                    // Option+clicking the pinned dot lets go of it.
                                    pinnedTrial = pinnedTrial == index ? nil : index
                                }
                        )
                        .onTapGesture { location in
                            guard let index = nearestTrial(to: location, proxy: proxy, geometry: geometry) else {
                                selectedTrial.wrappedValue = nil
                                return
                            }
                            selectedTrial.wrappedValue = selectedTrial.wrappedValue == index ? nil : index
                        }
                }
            }
            .frame(height: 200)
            .overlay(alignment: overlayAlignment) {
                if let row = overlayRow {
                    TrialOverlayCard(
                        row: row,
                        trial: trialWaveforms[row.trialIndex] ?? [],
                        average: averageWaveform,
                        samplingRate: samplingRate,
                        stimulusOffsetSamples: stimulusOffsetSamples,
                        isPinned: pinnedTrial == row.trialIndex
                    )
                    .padding(4)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Keep the card away from the dot it describes: trials cluster at high r,
    /// so the card sits on whichever side of the plot that trial is not on.
    private var overlayAlignment: Alignment {
        guard let row = overlayRow else { return .topLeading }
        return row.correlation > (xDomain.lowerBound + xDomain.upperBound) / 2 ? .topLeading : .topTrailing
    }

    /// Nearest dot in screen space, within a forgiving radius — the cluster near
    /// r = 1 is dense enough that a value-space search would pick the wrong one.
    private func nearestTrial(
        to location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> Int? {
        guard let anchor = proxy.plotFrame else { return nil }
        let plot = geometry[anchor]
        var best: (index: Int, distance: CGFloat)?
        for row in rows {
            guard let x = proxy.position(forX: row.correlation),
                  let y = proxy.position(forY: row.slope) else { continue }
            let point = CGPoint(x: plot.minX + x, y: plot.minY + y)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if best == nil || distance < best!.distance {
                best = (row.trialIndex, distance)
            }
        }
        guard let best, best.distance <= 14 else { return nil }
        return best.index
    }
}

// MARK: - Trial vs average overlay

/// The card the scatter raises: one trial drawn over its category average, with
/// the scores that put the dot where it is. Answers the question the scatter
/// cannot — *what does this trial actually look like* — without leaving the rail.
struct TrialOverlayCard: View {
    let row: TrialDiagnosticsRow
    let trial: [Double]
    let average: [Double]
    let samplingRate: Double
    let stimulusOffsetSamples: Int
    var isPinned: Bool = false

    private struct Sample: Identifiable {
        var id: Int { index * 2 + (isTrial ? 1 : 0) }
        var index: Int
        var ms: Double
        var value: Double
        var isTrial: Bool
    }

    private func ms(at index: Int) -> Double {
        guard samplingRate > 0 else { return Double(index) }
        return Double(index - stimulusOffsetSamples) / samplingRate * 1000
    }

    private var samples: [Sample] {
        var points: [Sample] = []
        points.reserveCapacity(trial.count + average.count)
        for (index, value) in average.enumerated() {
            points.append(Sample(index: index, ms: ms(at: index), value: value, isTrial: false))
        }
        for (index, value) in trial.enumerated() {
            points.append(Sample(index: index, ms: ms(at: index), value: value, isTrial: true))
        }
        return points
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("Trial \(row.trialIndex + 1)")
                    .font(.caption.weight(.semibold))
                Circle().fill(row.classification.color).frame(width: 7, height: 7)
                Text(row.classification.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Chart(samples) { sample in
                LineMark(
                    x: .value("ms", sample.ms),
                    y: .value("µV", sample.value),
                    series: .value("Series", sample.isTrial ? "Trial" : "Average")
                )
                .foregroundStyle(sample.isTrial ? row.classification.color : Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: sample.isTrial ? 1.4 : 1.0))
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let ms = value.as(Double.self) { Text("\(Int(ms))") } }
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks { AxisGridLine(); AxisValueLabel().font(.caption2) }
            }
            .frame(width: 210, height: 92)

            HStack(spacing: 8) {
                metric("r", row.correlation)
                metric("β", row.slope)
                metric("RMS", row.normalizedResidualRMS)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .shadow(radius: 4)
    }

    private func metric(_ name: String, _ value: Double) -> some View {
        HStack(spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(.caption2.monospacedDigit())
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
                        caution: "This single-category p is uncorrected. The cross-category small multiples below report Benjamini-Hochberg adjusted q values for the displayed family."
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

// MARK: - Cross-category drift

/// The selected measure repeated with a shared y-scale across every scored
/// category. Significance is based on the BH-adjusted q across exactly these
/// visible panels, making the statistical family match what the user sees.
struct CrossCategoryDriftSmallMultiples: View {
    let categories: [TrialDiagnosticsCategory]
    let measure: String
    let axis: TrialDiagnosticsAxis

    private struct Entry: Identifiable {
        var id: String { category }
        var category: String
        var points: [(x: Double, y: Double)]
        var rho: Double
        var rawP: Double
        var adjustedP: Double
    }

    private var entries: [Entry] {
        let unadjusted = categories.compactMap { category -> Entry? in
            let points = category.rows.compactMap { row -> (x: Double, y: Double)? in
                guard let value = row.measures[measure] else { return nil }
                return (
                    axis == .trialIndex ? Double(row.trialIndex) : row.sourceTimeSeconds,
                    value
                )
            }
            guard let drift = TrialDriftStatistics.rankCorrelation(
                of: points.map(\.y),
                against: points.map(\.x)
            ) else { return nil }
            return Entry(
                category: category.name,
                points: points,
                rho: drift.rho,
                rawP: drift.p,
                adjustedP: 1
            )
        }
        let adjusted = TrialDriftStatistics.benjaminiHochbergAdjustedPValues(unadjusted.map(\.rawP))
        return unadjusted.enumerated().map { offset, entry in
            var entry = entry
            entry.adjustedP = adjusted[offset]
            return entry
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = entries.flatMap { $0.points.map(\.y) }
        guard let low = values.min(), let high = values.max() else { return -1 ... 1 }
        guard high > low else { return (low - 1) ... (high + 1) }
        let padding = (high - low) * 0.08
        return (low - padding) ... (high + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChartTitle(
                text: "\(measure) across categories",
                help: ChartHelpBadge(
                    title: "Cross-category drift",
                    what: "The same measure and y-scale repeated for every scored category. Each panel reports Spearman ρ and a Benjamini-Hochberg FDR-adjusted q across the visible categories.",
                    read: "An orange panel survives q < .05 after accounting for the number of categories shown. Similar slopes across categories suggest a session-wide influence; one isolated slope suggests a condition-specific change.",
                    caution: "The correction covers the visible category comparisons for this measure and axis. Changing the measure or switching trial order/elapsed time defines a new exploratory family."
                )
            )
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { _, entry in
                    categoryPanel(entry)
                }
            }
            Text("BH-FDR family: \(entries.count) visible categories · orange means q < .05")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func categoryPanel(_ entry: Entry) -> some View {
        let isSignificant = entry.adjustedP < 0.05
        let smoothedValues = TrialDriftStatistics.runningMedian(
            entry.points.map(\.y),
            window: max(5, entry.points.count / 8)
        )
        let smoothed = zip(entry.points.map(\.x), smoothedValues).map { ($0, $1) }

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.category).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("ρ \(entry.rho, format: .number.precision(.fractionLength(2))) · q \(entry.adjustedP, format: .number.precision(.fractionLength(3)))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSignificant ? Color.orange : .secondary)
            }
            Chart {
                ForEach(Array(smoothed.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Order", point.0),
                        y: .value(measure, point.1)
                    )
                    .foregroundStyle(isSignificant ? Color.orange : Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(Array(entry.points.enumerated()), id: \.offset) { _, point in
                    PointMark(
                        x: .value("Order", point.x),
                        y: .value(measure, point.y)
                    )
                    .foregroundStyle(isSignificant ? Color.orange.opacity(0.7) : Color.accentColor.opacity(0.65))
                    .symbolSize(18)
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxisLabel(axis == .trialIndex ? "Trial" : "Seconds")
            .frame(height: 125)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSignificant ? Color.orange.opacity(0.55) : Color.clear, lineWidth: 1)
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

// MARK: - Channel residual attribution

/// Ranks the selected sensors by their share of one trial's multichannel
/// leave-one-out residual. The trial strip uses the same selection binding as
/// every other diagnostics panel, so a suspicious point can be followed here
/// without hunting for its row again.
struct TrialChannelResidualPanel: View {
    let summary: TrialChannelResidualAnalyzer.Summary
    @Binding var selectedTrial: Int?

    private var activeResult: TrialChannelResidualAnalyzer.TrialResult? {
        if let selectedTrial,
           let selected = summary.trials.first(where: { $0.trialIndex == selectedTrial }) {
            return selected
        }
        return summary.trials.max { $0.totalNormalizedResidualRMS < $1.totalNormalizedResidualRMS }
    }

    private func patternColor(_ pattern: TrialChannelResidualAnalyzer.Pattern) -> Color {
        pattern == .localized ? .orange : .teal
    }

    var body: some View {
        if summary.channelCount < 2 {
            ContentUnavailableView(
                "One channel cannot be localized",
                systemImage: "sensor",
                description: Text("Choose Channel Set (ROI average) above and score again to compare the sensors inside it.")
            )
        } else if let result = activeResult {
            VStack(alignment: .leading, spacing: 12) {
                ChartTitle(
                    text: "Where this trial's residual comes from",
                    help: ChartHelpBadge(
                        title: "Channel residual contribution",
                        what: "Each sensor is compared with its own leave-one-out category average inside the configured windows. Bars show its share of the trial's total squared normalized residual.",
                        read: "One dominant bar points to a localized sensor problem. Similar bars across many sensors point to a trial-wide response or artifact.",
                        caution: "This attributes mismatch; it does not prove a sensor is broken. A focal physiological source can also be spatially concentrated."
                    )
                )

                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(summary.trials.sorted { $0.trialIndex < $1.trialIndex }) { trial in
                            Button("T\(trial.trialIndex + 1)") {
                                selectedTrial = trial.trialIndex
                            }
                            .buttonStyle(.plain)
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                patternColor(trial.pattern).opacity(
                                    selectedTrial == trial.trialIndex ? 0.34 : 0.14
                                ),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .overlay {
                                if selectedTrial == trial.trialIndex {
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(patternColor(trial.pattern), lineWidth: 1)
                                }
                            }
                            .help("Residual \(String(format: "%.2f", trial.totalNormalizedResidualRMS)); \(trial.pattern.rawValue)")
                        }
                    }
                }

                HStack(spacing: 18) {
                    Label(
                        result.pattern == .localized ? "Localized mismatch" : "Distributed mismatch",
                        systemImage: result.pattern == .localized
                            ? "scope"
                            : "rectangle.3.group"
                    )
                    .foregroundStyle(patternColor(result.pattern))
                    .font(.callout.weight(.semibold))
                    metric("dominant share", result.dominantContributionFraction.formatted(.percent.precision(.fractionLength(0))))
                    metric("effective channels", String(format: "%.1f / %d", result.effectiveChannelCount, summary.channelCount))
                    metric("total residual", String(format: "%.2f", result.totalNormalizedResidualRMS))
                }

                let ranked = result.channels.sorted { $0.contributionFraction > $1.contributionFraction }
                Chart(Array(ranked.prefix(16))) { channel in
                    BarMark(
                        x: .value("Contribution", channel.contributionFraction),
                        y: .value("Channel", channel.channelName)
                    )
                    .foregroundStyle(
                        channel.channelIndex == result.dominantChannelIndex
                            ? patternColor(result.pattern)
                            : Color.secondary.opacity(0.55)
                    )
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(channel.contributionFraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXScale(domain: 0 ... max(ranked.first?.contributionFraction ?? 0.01, 0.05))
                .chartXAxisLabel("share of multichannel residual")
                .frame(height: max(190, CGFloat(min(ranked.count, 16)) * 24))

                Text(ranked.count > 16
                     ? "Showing the 16 largest contributors. Contributions are computed across all \(ranked.count) selected channels."
                     : "Orange means concentrated in one sensor; teal means spread across the selected channels.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
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

// MARK: - Alignment

/// Sliding leave-one-out correlation, with trials down and latency across.
/// A local red patch distinguishes a component-specific mismatch from a trial
/// that is unlike the category throughout its epoch.
struct TrialTimeResolvedCorrelationHeatmap: View {
    let summary: TrialAlignmentSummary
    var selectedTrial: Binding<Int?> = .constant(nil)

    private var orderedTrials: [TrialAlignmentSeries] {
        summary.trials.sorted { $0.trialIndex < $1.trialIndex }
    }

    private var timeDomain: ClosedRange<Double> {
        let times = summary.trials.flatMap { $0.timeResolvedCorrelation.map(\.centerMs) }
        let low = times.min() ?? 0
        let high = times.max() ?? 1
        return low ... max(high, low + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChartTitle(
                text: "Where each trial matches",
                help: ChartHelpBadge(
                    title: "Time-resolved correlation",
                    what: "Each cell is the correlation inside a sliding window, comparing that trial with the average of the OTHER trials.",
                    read: "Teal is a matching shape; red is an inverted shape; pale cells have little relationship. A vertical patch means many trials diverge at the same component. Click a row to select that trial throughout the dashboard.",
                    caution: "The windows overlap, so adjacent cells are not independent tests. Treat this as a localization view, not a field of p-values."
                )
            )
            Canvas { context, size in
                guard !orderedTrials.isEmpty else { return }
                let domain = timeDomain
                let span = max(domain.upperBound - domain.lowerBound, 1)
                let rowHeight = size.height / CGFloat(orderedTrials.count)

                for (rowIndex, trial) in orderedTrials.enumerated() {
                    let cellWidth = size.width / CGFloat(max(trial.timeResolvedCorrelation.count, 1)) + 0.75
                    for point in trial.timeResolvedCorrelation {
                        let x = CGFloat((point.centerMs - domain.lowerBound) / span) * size.width
                        let rect = CGRect(
                            x: max(0, x - cellWidth / 2),
                            y: CGFloat(rowIndex) * rowHeight,
                            width: cellWidth,
                            height: rowHeight + 0.5
                        )
                        context.fill(Path(rect), with: .color(color(for: point.correlation)))
                    }

                    if selectedTrial.wrappedValue == trial.trialIndex {
                        let rect = CGRect(
                            x: 0,
                            y: CGFloat(rowIndex) * rowHeight,
                            width: size.width,
                            height: rowHeight
                        ).insetBy(dx: 0.5, dy: 0.5)
                        context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 2)
                    }
                }
            }
            .frame(height: max(140, min(Double(orderedTrials.count) * 8, 320)))
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .overlay {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard !orderedTrials.isEmpty, geometry.size.height > 0 else { return }
                            let fraction = min(max(location.y / geometry.size.height, 0), 0.999_999)
                            let row = min(Int(fraction * CGFloat(orderedTrials.count)), orderedTrials.count - 1)
                            let index = orderedTrials[row].trialIndex
                            selectedTrial.wrappedValue = selectedTrial.wrappedValue == index ? nil : index
                        }
                }
            }
            HStack {
                Text("\(format(timeDomain.lowerBound)) ms")
                Spacer()
                Text("\(format(timeDomain.upperBound)) ms")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Text("Rows are trials · red −1   pale 0   teal +1 · \(format(summary.correlationWindowMs)) ms window / \(format(summary.correlationStepMs)) ms step")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func color(for correlation: Double) -> Color {
        let value = min(max(correlation, -1), 1)
        let strength = 0.08 + 0.92 * abs(value)
        return value >= 0 ? Color.teal.opacity(strength) : Color.red.opacity(strength)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

/// Best bounded affine+dilation fit for every trial. Position separates latency
/// (x) from amplitude (y); the selected-trial readout keeps time scaling and the
/// post-fit residual beside the deformation needed to obtain it.
struct TrialAffineAlignmentPanel: View {
    let summary: TrialAlignmentSummary
    let rows: [TrialDiagnosticsRow]
    var selectedTrial: Binding<Int?> = .constant(nil)

    private var fits: [(series: TrialAlignmentSeries, fit: TrialAlignmentMetrics.AffineFit)] {
        summary.trials.compactMap { series in
            series.affineFit.map { (series, $0) }
        }
    }

    private var selectedFit: TrialAlignmentMetrics.AffineFit? {
        guard let selected = selectedTrial.wrappedValue else { return nil }
        return fits.first { $0.series.trialIndex == selected }?.fit
    }

    private var gainDomain: ClosedRange<Double> {
        let gains = fits.map(\.fit.gain)
        return min(-0.1, (gains.min() ?? 0) - 0.15) ... max(1.15, (gains.max() ?? 1) + 0.15)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChartTitle(
                text: "Best bounded shift, gain, and dilation",
                help: ChartHelpBadge(
                    title: "Affine alignment with uniform dilation",
                    what: "Each trial is fit as gain × other-trial average sampled at α-scaled time, shifted, plus offset. Dilation is anchored at stimulus onset and every search term is bounded.",
                    read: "Near 0 ms and gain 1 means little shift or amplitude adjustment. α below 1 is a slower, stretched response; α above 1 is compressed. Select a point to see α, duration scale, remaining mismatch, and deformation.",
                    caution: "A low residual is not automatically a good trial: dilation, shift, or gain may have worked hard to produce it. Read residual and deformation together."
                )
            )
            Chart {
                RuleMark(x: .value("No lag", 0))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                RuleMark(y: .value("Unit gain", 1))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    .foregroundStyle(.secondary)

                ForEach(fits, id: \.series.trialIndex) { item in
                    PointMark(
                        x: .value("Lag", item.fit.lagMs),
                        y: .value("Gain", item.fit.gain)
                    )
                    .foregroundStyle(color(for: item.series.trialIndex))
                    .symbolSize(55)
                }
                if let selected = selectedTrial.wrappedValue,
                   let item = fits.first(where: { $0.series.trialIndex == selected }) {
                    PointMark(
                        x: .value("Lag", item.fit.lagMs),
                        y: .value("Gain", item.fit.gain)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(250)
                    .symbol(.circle.strokeBorder(lineWidth: 2))
                }
            }
            .chartXScale(domain: -summary.maximumLagMs ... summary.maximumLagMs)
            .chartYScale(domain: gainDomain)
            .chartXAxisLabel("lag (ms; + = late)")
            .chartYAxisLabel("gain")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let index = nearestTrial(to: location, proxy: proxy, geometry: geometry) else {
                                selectedTrial.wrappedValue = nil
                                return
                            }
                            selectedTrial.wrappedValue = selectedTrial.wrappedValue == index ? nil : index
                        }
                }
            }
            .frame(height: 230)

            if let index = selectedTrial.wrappedValue, let fit = selectedFit {
                Text("Trial \(index + 1)")
                    .font(.caption.weight(.semibold))
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                    alignment: .leading,
                    spacing: 4
                ) {
                    metric("lag", String(format: "%+.1f ms", fit.lagMs))
                    metric("gain", String(format: "%.2f×", fit.gain))
                    metric("offset", String(format: "%+.2f", fit.offset))
                    metric("α time scale", String(format: "%.2f", fit.timeScale))
                    metric("duration", String(format: "%.2f×", 1 / fit.timeScale))
                    metric("shape left", String(format: "%.2f", fit.residualAfter))
                    metric("explained", String(format: "%.0f%%", fit.explainedByAlignment * 100))
                    metric("deformation", String(format: "%.2f", fit.deformation))
                }
            } else {
                Text("Select a point or heatmap row to inspect its residual and deformation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Lag limited to ±\(String(format: "%.0f", summary.maximumLagMs)) ms; α limited to \(String(format: "%.2f", 1 - summary.maximumTimeScaleDeviation))…\(String(format: "%.2f", 1 + summary.maximumTimeScaleDeviation)); overlap only, with no zero padding.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func color(for trialIndex: Int) -> Color {
        rows.first { $0.trialIndex == trialIndex }?.classification.color ?? .secondary
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func nearestTrial(
        to location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> Int? {
        guard let anchor = proxy.plotFrame else { return nil }
        let plot = geometry[anchor]
        var nearest: (index: Int, distance: CGFloat)?
        for item in fits {
            guard let x = proxy.position(forX: item.fit.lagMs),
                  let y = proxy.position(forY: item.fit.gain) else { continue }
            let point = CGPoint(x: plot.minX + x, y: plot.minY + y)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if nearest == nil || distance < nearest!.distance {
                nearest = (item.series.trialIndex, distance)
            }
        }
        return nearest.flatMap { $0.distance <= 24 ? $0.index : nil }
    }
}
