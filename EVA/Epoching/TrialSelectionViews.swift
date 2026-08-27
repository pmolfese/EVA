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
    /// Flips one row between excluded and kept. Nil leaves the list read-only,
    /// which is what a host with nothing to commit into should pass.
    var onSetExcluded: ((Int, Bool) -> Void)?

    /// Rows that actually remove a trial. A `.restored` row is listed so the
    /// operator can see the rule was overruled, but counting it as excluded
    /// would claim a trial the average still contains.
    private var excludedCount: Int {
        exclusions.filter(\.isExcluded).count
    }

    private var restoredCount: Int {
        exclusions.count - excludedCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Excluded (\(excludedCount))").font(.caption).foregroundStyle(.secondary)
                if restoredCount > 0 {
                    Text("· \(restoredCount) restored")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(exclusions) { exclusion in
                        HStack(alignment: .top, spacing: 6) {
                            if let onSetExcluded {
                                // The checkbox *is* the override: checked means
                                // this trial leaves the average. Reading it as
                                // "excluded" rather than "keep" matches the
                                // list's own title, so the two cannot disagree.
                                Toggle("", isOn: Binding(
                                    get: { exclusion.isExcluded },
                                    set: { onSetExcluded(exclusion.trialIndex, $0) }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .help(exclusion.isExcluded
                                      ? "Keep this trial in the average"
                                      : "Exclude this trial again")
                            }
                            Text("#\(exclusion.trialIndex)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 30, alignment: .leading)
                                .foregroundStyle(exclusion.isExcluded ? .primary : .secondary)
                            Text(exclusion.reasons.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .strikethrough(!exclusion.isExcluded)
                            if exclusion.origin == .manual {
                                Image(systemName: "hand.point.up.left")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("Excluded by hand — the criteria did not flag this trial.")
                            }
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

// MARK: - Commit

/// Turning a preview into a decision (ROADMAP TW-5).
///
/// Phase 3 previews without altering data, and that has to stay true of the
/// controls too: every path that changes what is excluded is an explicit click
/// here, never a side effect of dragging a threshold. The criteria sliders go
/// on re-proposing forever and commit nothing.
///
/// The bar also has to be honest about three different states that look alike
/// at a glance — what the rule proposes, what the operator changed, and what is
/// already committed to the file — because "3 excluded" means something
/// different in each.
struct TrialExclusionCommitBar: View {
    let category: String?
    let exclusions: [TrialSelectionAnalyzer.Exclusion]
    let selectedTrial: Int?
    /// What the file already carries, rendered for a person: nil when nothing
    /// is committed.
    let committedSummary: String?
    /// Whether the committed record covers the category under review, which is
    /// what makes committing an empty set meaningful (it clears that category).
    let isCategoryCommitted: Bool
    /// How many categories the committed record covers. Decides whether
    /// clearing needs to ask *which* — with one committed category, "this
    /// category" and "all categories" are the same act, and offering both is
    /// two names for one button.
    let committedCategoryCount: Int
    let hasOverrides: Bool

    var onSetExcluded: (Int, Bool) -> Void
    var onResetOverrides: () -> Void
    var onCommit: () -> Void
    var onClear: () -> Void
    var onClearCategory: () -> Void

    @State private var confirmingCommit = false
    @State private var confirmingClear = false
    @State private var confirmingClearCategory = false

    /// Clearing is only worth splitting when there is more than one category to
    /// split it between, and the one under review is actually in the record.
    private var offersPerCategoryClear: Bool {
        isCategoryCommitted && committedCategoryCount > 1
    }

    private var excludedCount: Int { exclusions.filter(\.isExcluded).count }
    private var restoredCount: Int { exclusions.count - excludedCount }
    private var manualCount: Int { exclusions.filter { $0.origin == .manual }.count }

    /// The selected trial is only offered as a hand exclusion when it is not
    /// already in the list — the list's own checkbox handles the rest, and two
    /// controls for one decision is how they end up disagreeing.
    private var selectableTrial: Int? {
        guard let selectedTrial,
              !exclusions.contains(where: { $0.trialIndex == selectedTrial }) else { return nil }
        return selectedTrial
    }

    private var canCommit: Bool {
        category != nil && (excludedCount > 0 || isCategoryCommitted)
    }

    private var commitDescription: String {
        guard let category else { return "" }
        var parts = ["\(excludedCount) trial\(excludedCount == 1 ? "" : "s") excluded from \(category)"]
        if manualCount > 0 { parts.append("\(manualCount) by hand") }
        if restoredCount > 0 { parts.append("\(restoredCount) restored from the rule") }
        return parts.joined(separator: ", ") + "."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            if let committedSummary {
                Label(committedSummary, systemImage: "checkmark.seal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let selectableTrial {
                Button("Exclude #\(selectableTrial) by hand") {
                    onSetExcluded(selectableTrial, true)
                }
                .font(.caption)
                .buttonStyle(.link)
                .help("The criteria did not flag this trial. Excluding it here is recorded as your decision, not the rule's.")
            }

            HStack(spacing: 8) {
                Button("Commit…") { confirmingCommit = true }
                    .disabled(!canCommit)
                    .help(canCommit
                          ? "Record this exclusion in the file and rebuild the average."
                          : "Nothing to commit for this category.")

                if hasOverrides {
                    Button("Reset", action: onResetOverrides)
                        .help("Discard your changes and go back to what the criteria alone propose.")
                }
                Spacer()
                if committedSummary != nil {
                    if offersPerCategoryClear, let category {
                        Menu("Clear…") {
                            Button("Only \(category)") { confirmingClearCategory = true }
                            Button("All \(committedCategoryCount) categories") { confirmingClear = true }
                        }
                        .fixedSize()
                        .help("Remove the committed exclusion for this category, or for all of them.")
                    } else {
                        Button("Clear…") { confirmingClear = true }
                            .help("Remove the committed exclusion entirely and restore every trial.")
                    }
                }
            }
            .controlSize(.small)

            // Said at the point of decision rather than in a help bubble: the
            // whole panel is built to make a selection look like an improvement,
            // and this is the last moment it can be qualified.
            Text("Committing rebuilds the average and records the decision in the file. A cleaner average is not evidence the excluded trials were bad.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Commit this exclusion?",
            isPresented: $confirmingCommit,
            titleVisibility: .visible
        ) {
            Button("Commit") { onCommit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(commitDescription)
        }
        .confirmationDialog(
            "Clear the committed exclusion?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { onClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every trial returns to the average, in every category. The decision is removed from the file on the next export.")
        }
        .confirmationDialog(
            "Clear the committed exclusion for \(category ?? "this category")?",
            isPresented: $confirmingClearCategory,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { onClearCategory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This category's trials return to the average. Every other category keeps the exclusion it was reviewed with.")
        }
    }
}
