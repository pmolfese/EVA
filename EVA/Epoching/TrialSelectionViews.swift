//
//  TrialSelectionViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Trial-wise Phase 3: the exclusion controls, what the average looks like
//  with and without, and the null that stops the SNR number from flattering
//  every threshold it is dragged to.
//

import Charts
import SwiftUI

// MARK: - Optional bound control

/// A slider that can be switched off entirely, because "no bound on this
/// measure" is a different state from "a bound at the end of its range".
///
/// Not private: the dashboard's context rail shows the same controls beside the
/// plots rather than below them.
struct OptionalBoundSlider: View {
    let label: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let defaultValue: Double
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Toggle(isOn: Binding(
                get: { value != nil },
                set: { value = $0 ? defaultValue : nil }
            )) {
                Text(label).font(.caption)
            }
            .toggleStyle(.checkbox)
            .frame(width: compact ? 108 : 190, alignment: .leading)

            Slider(
                value: Binding(get: { value ?? defaultValue }, set: { value = $0 }),
                in: range
            )
            .disabled(value == nil)
            .frame(width: compact ? 96 : 220)

            Text(value.map { String(format: "%.2f", $0) } ?? "off")
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}


// MARK: - Dashboard pieces

/// Just the criteria, for the dashboard's context rail — the whole point of the
/// two-column layout is dragging these while the plots stay on screen.
struct TrialSelectionCriteriaControls: View {
    @Binding var criteria: TrialSelectionAnalyzer.Criteria

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Exclude when").font(.caption).foregroundStyle(.secondary)
            OptionalBoundSlider(label: "r below", value: $criteria.minCorrelation, range: -1 ... 1, defaultValue: 0.3, compact: true)
            OptionalBoundSlider(label: "β below", value: $criteria.minSlope, range: -1 ... 2, defaultValue: 0.4, compact: true)
            OptionalBoundSlider(label: "residual above", value: $criteria.maxResidualRMS, range: 0 ... 3, defaultValue: 1.0, compact: true)
            OptionalBoundSlider(label: "distance above", value: $criteria.maxRobustDistance, range: 0 ... 10, defaultValue: 3.0, compact: true)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(TrialSimilarityAnalyzer.Classification.allCases, id: \.self) { classification in
                    if classification != .typical {
                        Toggle(classification.displayName, isOn: Binding(
                            get: { criteria.excludedClassifications.contains(classification) },
                            set: { isOn in
                                if isOn { criteria.excludedClassifications.insert(classification) }
                                else { criteria.excludedClassifications.remove(classification) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
                Toggle("Matches outside pool", isOn: $criteria.excludesMislabels)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
    }
}

struct TrialExclusionList: View {
    let exclusions: [TrialSelectionAnalyzer.Exclusion]
    @Binding var selectedTrial: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Excluded (\(exclusions.count))").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(exclusions) { exclusion in
                        HStack(alignment: .top, spacing: 6) {
                            Text("#\(exclusion.trialIndex)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 30, alignment: .leading)
                            Text(exclusion.reasons.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 1)
                        .padding(.horizontal, 3)
                        .background(
                            selectedTrial == exclusion.trialIndex ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedTrial = selectedTrial == exclusion.trialIndex ? nil : exclusion.trialIndex
                        }
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }
}

struct TrialAverageComparison: View {
    let averageAll: [Double]
    let averageKept: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChartTitle(
                text: "Average, all trials vs kept",
                help: ChartHelpBadge(
                    title: "Before and after",
                    what: "The category average computed from every trial, and from only the survivors.",
                    read: "A large gap means the excluded trials were shaping the ERP. Almost no gap means the exclusion changed little — which is a reason to leave them in.",
                    caution: "A cleaner-looking curve is not evidence the excluded trials were bad; dropping anything unlike the mean always tidies the mean."
                )
            )
            Chart {
                ForEach(Array(averageAll.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("Sample", index), y: .value("µV", value), series: .value("s", "All"))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(averageKept.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("Sample", index), y: .value("µV", value), series: .value("s", "Kept"))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(height: 200)
        }
    }
}

struct TrialNullDistribution: View {
    let outcome: TrialSelectionAnalyzer.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChartTitle(
                text: "Against \(outcome.excludedCount) random exclusions",
                help: ChartHelpBadge(
                    title: "The null",
                    what: "Grey bars: the change in plus-minus SNR from excluding the same NUMBER of trials at random, 200 times. Orange: this selection.",
                    read: "Sitting inside the grey bulk means the change is what dropping that many trials does anyway. Sitting far right means the criterion picked something specific.",
                    caution: "Far right is expected, not a vindication: the criterion selects on similarity to this very average, so an excess over the null is built in. It is not evidence the excluded trials were bad."
                )
            )
            let histogram = outcome.nullHistogram()
            Chart {
                ForEach(Array(histogram.enumerated()), id: \.offset) { _, bin in
                    BarMark(
                        x: .value("ΔSNR", bin.center),
                        y: .value("Draws", bin.count),
                        width: .fixed(max(2, 240 / Double(max(histogram.count, 1))))
                    )
                    .foregroundStyle(Color.secondary.opacity(0.45))
                }
                if let observed = outcome.observedChange {
                    RuleMark(x: .value("Observed", observed))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartXScale(domain: outcome.nullPlotRange ?? (-1 ... 1))
            .frame(height: 200)
            if let percentile = outcome.percentileAmongNull {
                Text("percentile \(Int((percentile * 100).rounded())) · selecting on similarity to the mean always improves it")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
