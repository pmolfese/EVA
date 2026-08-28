//
//  TrialDiagnosticsDashboard.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The Trial Diagnostics panel laid out as a dashboard rather than a column.
//
//  Stacked, the panel ran to roughly 2,000 points and everything below the first
//  chart was a scroll away — including the exclusion criteria, which you want to
//  drag WHILE watching which trials move. So: a fixed context rail that always
//  shows the summary, the shape/magnitude scatter, what is currently excluded and
//  why, and the criteria; beside it a tabbed pane whose panels get the full width
//  and sit side by side.
//
//  Selecting a trial anywhere marks it everywhere.
//

import Charts
import SwiftUI

struct TrialDiagnosticsDashboard: View {
    let categories: [TrialDiagnosticsCategory]
    @Binding var axis: TrialDiagnosticsAxis
    @Binding var selectedMeasure: String
    @Binding var secondaryMeasure: String
    @Binding var groupCount: Int

    let similarityTrials: [TrialSimilarityAnalyzer.TrialSimilarity]
    let exclusions: [TrialSelectionAnalyzer.Exclusion]
    let outcome: TrialSelectionAnalyzer.Outcome?
    let averageAll: [Double]
    let averageKept: [Double]
    @Binding var criteria: TrialSelectionAnalyzer.Criteria

    // MARK: Commit (ROADMAP TW-5)
    /// The category under review — the one a commit writes. Distinct from
    /// `categories`, which is what the panels draw.
    var reviewedCategory: String?
    var committedSummary: String?
    var isCategoryCommitted: Bool = false
    var committedCategoryCount: Int = 0
    var hasOverrides: Bool = false
    /// Nil leaves the whole panel read-only: the criteria still preview, and
    /// nothing can be committed. That is the correct state before there are
    /// segments to commit against.
    var onSetExcluded: ((Int, Bool) -> Void)?
    var onResetOverrides: (() -> Void)?
    var onCommit: (() -> Void)?
    var onClear: (() -> Void)?
    var onClearCategory: (() -> Void)?

    @State private var tab: Tab = .windows
    @State private var selectedTrial: Int?

    enum Tab: String, CaseIterable, Identifiable {
        case windows = "Windows"
        case drift = "Drift"
        case stability = "Stability"
        case trials = "Trials"
        case effect = "Effect"

        var id: String { rawValue }
    }

    /// Below this the rail and the pane cannot both be usable, so they stack.
    private let twoColumnMinimumWidth: CGFloat = 900
    private let railWidth: CGFloat = 300

    private var category: TrialDiagnosticsCategory? { categories.first }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= twoColumnMinimumWidth
            Group {
                if isWide {
                    HStack(alignment: .top, spacing: 16) {
                        rail.frame(width: railWidth)
                        Divider()
                        pane
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        rail
                        Divider()
                        pane
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 620)
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let category {
                summary(for: category)
                TrialShapeMagnitudeScatter(
                    rows: category.rows,
                    selectedTrial: $selectedTrial,
                    trialWaveforms: category.trialWaveforms,
                    averageWaveform: category.averageWaveform,
                    samplingRate: category.samplingRate,
                    stimulusOffsetSamples: category.stimulusOffsetSamples
                )
                TrialClassificationLegend()
            }
            Divider()
            TrialSelectionCriteriaControls(criteria: $criteria)
            if !exclusions.isEmpty {
                TrialExclusionList(
                    exclusions: exclusions,
                    selectedTrial: $selectedTrial,
                    onSetExcluded: onSetExcluded
                )
            }
            if let onSetExcluded, let onResetOverrides, let onCommit, let onClear, let onClearCategory {
                TrialExclusionCommitBar(
                    category: reviewedCategory,
                    exclusions: exclusions,
                    selectedTrial: selectedTrial,
                    committedSummary: committedSummary,
                    isCategoryCommitted: isCategoryCommitted,
                    committedCategoryCount: committedCategoryCount,
                    hasOverrides: hasOverrides,
                    onSetExcluded: onSetExcluded,
                    onResetOverrides: onResetOverrides,
                    onCommit: onCommit,
                    onClear: onClear,
                    onClearCategory: onClearCategory
                )
            }
        }
    }

    private func summary(for category: TrialDiagnosticsCategory) -> some View {
        let counts = Dictionary(grouping: category.rows, by: \.classification).mapValues(\.count)
        let mislabels = category.rows.filter { !$0.matchesOwnPool }

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(category.name).font(.headline)
                Text("\(category.rows.count) trials").font(.caption).foregroundStyle(.secondary)
            }
            FlowingBadges(
                items: TrialSimilarityAnalyzer.Classification.allCases.compactMap { classification in
                    guard classification != .typical, let count = counts[classification], count > 0 else { return nil }
                    return (classification.displayName.lowercased(), count, classification.color)
                }
            )
            if !mislabels.isEmpty {
                Text("\(mislabels.count) match an average outside this pool")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let outcome {
                HStack(spacing: 12) {
                    miniStat("kept", "\(outcome.keptCount)")
                    miniStat("SNR", format(outcome.after.plusMinusSNR))
                    if let percentile = outcome.percentileAmongNull {
                        miniStat("vs null", "\(Int((percentile * 100).rounded()))%")
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "—"
    }

    // MARK: - Pane

    private var pane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)

                Spacer()

                if tab == .drift || tab == .windows {
                    Picker("", selection: $axis) {
                        ForEach(TrialDiagnosticsAxis.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            if let category {
                switch tab {
                case .windows: windowsTab(category)
                case .drift: driftTab(category)
                case .stability: stabilityTab(category)
                case .trials: TrialScoreTable(rows: category.rows, selectedTrial: $selectedTrial)
                case .effect: effectTab
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func windowsTab(_ category: TrialDiagnosticsCategory) -> some View {
        if category.windowSeries.isEmpty {
            ContentUnavailableView(
                "No windows yet",
                systemImage: "rectangle.dashed",
                description: Text("Add a window above, then drag it over the peak you want to score.")
            )
        } else {
            // No ScrollView here: the sheet body is already one, and nesting two
            // that scroll the same axis makes the inner one steal the wheel.
            // Let this grow and let the outer scroll carry it.
            TrialWindowPanels(series: category.windowSeries, axis: axis, rows: category.rows)
        }
    }

    private func driftTab(_ category: TrialDiagnosticsCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Left", selection: $selectedMeasure) {
                    ForEach(measures(in: category), id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 210)
                Picker("Right", selection: $secondaryMeasure) {
                    ForEach(measures(in: category), id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 210)
                Stepper("Groups: \(groupCount)", value: $groupCount, in: 2 ... 8).frame(width: 130)
            }
            HStack(alignment: .top, spacing: 14) {
                TrialMeasureOverOrderChart(rows: category.rows, measure: selectedMeasure, axis: axis)
                TrialMeasureOverOrderChart(rows: category.rows, measure: secondaryMeasure, axis: axis)
            }
            TrialSplitGroupChart(rows: category.rows, measure: selectedMeasure, groupCount: groupCount)
        }
    }

    private func stabilityTab(_ category: TrialDiagnosticsCategory) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if !category.convergence.isEmpty {
                TrialConvergenceChart(points: category.convergence)
            }
            if !category.residuals.isEmpty {
                TrialResidualHeatmap(residuals: category.residuals)
            }
        }
    }

    @ViewBuilder
    private var effectTab: some View {
        if exclusions.isEmpty {
            ContentUnavailableView(
                "Nothing excluded",
                systemImage: "slider.horizontal.3",
                description: Text("Set a criterion in the rail to preview what excluding those trials would do.")
            )
        } else {
            HStack(alignment: .top, spacing: 14) {
                TrialAverageComparison(averageAll: averageAll, averageKept: averageKept)
                if let outcome, !outcome.nullChanges.isEmpty {
                    TrialNullDistribution(outcome: outcome)
                }
            }
        }
    }

    private func measures(in category: TrialDiagnosticsCategory) -> [String] {
        Array(Set(category.rows.flatMap(\.measures.keys))).sorted()
    }
}

// MARK: - Classification legend

/// A standing key for the four classification colours plus the dot/cross
/// symbol distinction, always visible in the rail rather than only surfacing
/// on hover. The scatter's `?` still carries the full explanation of what each
/// quadrant means; this is the quick "what does that colour mean" reference —
/// dropping the count badges in `summary(for:)` do not answer that on their own
/// once nothing of a given kind is present in the current category.
struct TrialClassificationLegend: View {
    private static let descriptions: [TrialSimilarityAnalyzer.Classification: String] = [
        .typical: "ordinary trial",
        .attenuated: "shape intact, size gone",
        .inverted: "runs opposite the average",
        .divergent: "shares little with the average"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(TrialSimilarityAnalyzer.Classification.allCases, id: \.self) { classification in
                HStack(spacing: 5) {
                    Circle().fill(classification.color).frame(width: 7, height: 7)
                    Text(classification.displayName).font(.caption2).fontWeight(.medium)
                    Text(Self.descriptions[classification] ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                    Text("own pool").font(.caption2)
                }
                HStack(spacing: 4) {
                    Image(systemName: "multiply").font(.system(size: 8, weight: .bold))
                    Text("outside pool").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.top, 1)
        }
    }
}

// MARK: - Badges

private struct FlowingBadges: View {
    let items: [(label: String, count: Int, color: Color)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("\(item.count) \(item.label)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.color.opacity(0.14), in: Capsule())
                    .foregroundStyle(item.color)
            }
        }
    }
}

// MARK: - Trial table

/// Every trial on one screen — the densest summary available, and the only view
/// here that does not make you read a chart to answer "which ones are odd".
struct TrialScoreTable: View {
    let rows: [TrialDiagnosticsRow]
    @Binding var selectedTrial: Int?

    @State private var sort = SortColumn.robustDistance
    @State private var ascending = false

    enum SortColumn: String, CaseIterable, Identifiable {
        case trial = "#"
        case correlation = "r"
        case slope = "β"
        case residual = "residual"
        case robustDistance = "distance"
        var id: String { rawValue }
    }

    private var sorted: [TrialDiagnosticsRow] {
        let ordered = rows.sorted { a, b in
            switch sort {
            case .trial: a.trialIndex < b.trialIndex
            case .correlation: a.correlation < b.correlation
            case .slope: a.slope < b.slope
            case .residual: a.normalizedResidualRMS < b.normalizedResidualRMS
            case .robustDistance: a.robustDistance < b.robustDistance
            }
        }
        return ascending ? ordered : ordered.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            // Bounded, so it behaves as a list pane rather than competing with
            // the sheet's own scroll for the whole page.
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(sorted) { row in
                        rowView(row)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(SortColumn.allCases) { column in
                Button {
                    if sort == column { ascending.toggle() } else { sort = column; ascending = false }
                } label: {
                    HStack(spacing: 2) {
                        Text(column.rawValue)
                        if sort == column {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 7))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(sort == column ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: width(for: column), alignment: column == .trial ? .leading : .trailing)
            }
            Text("class").font(.caption2).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text("best match").font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func width(for column: SortColumn) -> CGFloat {
        switch column {
        case .trial: 34
        case .correlation, .slope: 44
        case .residual, .robustDistance: 60
        }
    }

    private func rowView(_ row: TrialDiagnosticsRow) -> some View {
        let isSelected = selectedTrial == row.trialIndex
        return HStack(spacing: 8) {
            Text("\(row.trialIndex)")
                .frame(width: width(for: .trial), alignment: .leading)
            numeric(row.correlation, width: width(for: .correlation))
            numeric(row.slope, width: width(for: .slope))
            numeric(row.normalizedResidualRMS, width: width(for: .residual))
            numeric(row.robustDistance, width: width(for: .robustDistance))
            HStack(spacing: 4) {
                Circle().fill(row.classification.color).frame(width: 6, height: 6)
                Text(row.classification.displayName.lowercased())
            }
            .frame(width: 78, alignment: .leading)
            Text(row.matchesOwnPool ? "—" : (row.bestMatchingCategory ?? "—"))
                .foregroundStyle(row.matchesOwnPool ? Color.secondary : .red)
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { selectedTrial = isSelected ? nil : row.trialIndex }
    }

    private func numeric(_ value: Double, width: CGFloat) -> some View {
        Text(String(format: "%.2f", value))
            .frame(width: width, alignment: .trailing)
    }
}
