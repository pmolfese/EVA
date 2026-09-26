//
//  ICARunGrade.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Turns an ICA component removal into a `StepQuality` grade (ROADMAP §
//  Processing run-grade). Graded:
//
//    * what was removed — the largest ICLabel Brain probability among removed
//      components, on ICLabel's own reading (≥ 0.5: "ICLabel thinks this is
//      brain" → Poor; ≥ 0.25 → Watch). A convention, not a measurement: ICLabel
//      labels synthetic sources unreliably, so it cannot be calibrated on the
//      simulator. Without probabilities (the heuristic labeller, a headless
//      replay) a removed component *labelled* Brain grades Watch.
//    * data per component — κ = analysis samples / components², Watch below
//      the published 20 × n² rule of thumb (Onton & Makeig 2006). Also a
//      convention: the campaign (`ICARunGradeMeasurementTests`,
//      docs/provenance/run-grade-calibration.md § ICA) found EVA's Picard
//      isolated a blink just as cleanly at κ ≈ 4 as at κ ≈ 150, so there is no
//      evidence for a Poor band — and none that the rule is wrong for weaker,
//      less non-Gaussian sources, which the campaign did not test.
//
//  Reported, not graded:
//
//    * convergence — the app's default tolerance (1e-12) means almost every fit
//      stops at the iteration cap, and the campaign found no quality difference
//      it could attribute to that.
//    * removed variance — a blink-heavy frontal recording legitimately gives up
//      a large share.
//

import Foundation

nonisolated struct ICARunMetrics: Codable, Sendable, Equatable, Hashable {
    var componentCount: Int
    /// Samples the decomposition was fitted on, at the analysis rate. `nil`
    /// when it cannot be known (never for a live fit).
    var analysisSampleCount: Int?
    var iterations: Int
    var maxIterations: Int
    var finalChange: Double
    var convergenceTolerance: Double
    var removedComponentCount: Int
    var removedVarianceFraction: Double
    /// Largest ICLabel Brain probability among removed components; `nil` when
    /// the components carry no probabilities (a headless replay).
    var maxRemovedBrainProbability: Double?
    /// Removed components whose label says Brain.
    var removedBrainLabelCount: Int

    var kappa: Double? {
        guard let analysisSampleCount, componentCount > 0 else { return nil }
        return Double(analysisSampleCount) / Double(componentCount * componentCount)
    }

    var converged: Bool {
        iterations < maxIterations || finalChange <= convergenceTolerance
    }

    /// Metrics for removing `decomposition.excludedComponents`.
    ///
    /// - Parameter analysisSampleCount: overrides the decomposition's own count;
    ///   pass it for a payload-rebuilt decomposition, which does not carry one.
    init(decomposition: ICADecomposition, maxIterations: Int, analysisSampleCount: Int? = nil) {
        let removed = decomposition.excludedComponents.filter { $0 >= 0 && $0 < decomposition.componentCount }
        componentCount = decomposition.componentCount
        let own = decomposition.componentSources.first?.count ?? decomposition.sampleCount
        self.analysisSampleCount = analysisSampleCount ?? (own > 0 ? own : nil)
        iterations = decomposition.iterations
        self.maxIterations = max(1, maxIterations)
        finalChange = decomposition.finalChange
        convergenceTolerance = decomposition.convergenceTolerance
        removedComponentCount = removed.count
        let total = decomposition.explainedVariance.reduce(0) { $0 + max(0, $1) }
        let taken = removed.reduce(0.0) { sum, c in
            sum + (decomposition.explainedVariance.indices.contains(c) ? max(0, decomposition.explainedVariance[c]) : 0)
        }
        removedVarianceFraction = total > 0 ? taken / total : 0
        let probabilities = removed.compactMap { decomposition.labelSuggestions[$0]?.probabilities["Brain"] }
        maxRemovedBrainProbability = probabilities.max()
        removedBrainLabelCount = removed.filter { c in
            let label = decomposition.labels[c] ?? decomposition.labelSuggestions[c]?.label ?? ""
            return label.hasPrefix("Brain")
        }.count
    }
}

nonisolated enum ICARunGrade {

    // MARK: Bands

    /// κ below which the grade reads Watch (the 20 × n² convention).
    static let kappaGoodFloor = 20.0
    /// Removed-component Brain probability at or above which ICLabel reads the
    /// component as brain (poor), and the lower edge of "worth a look".
    static let brainProbabilityPoorFloor = 0.5
    static let brainProbabilityWatchFloor = 0.25

    static func grade(from m: ICARunMetrics) -> StepQuality {
        var graded = [removedMetric(m), dataMetric(m)]
        let overall = graded.filter(\.reached).map(\.grade).max() ?? .good
        graded.append(convergenceMetric(m))
        graded.append(QualityMetric(
            name: "Removed variance", grade: .good,
            detail: String(format: "%.0f%% of the variance in %d component%@ — reported, not graded.",
                           100 * m.removedVarianceFraction, m.removedComponentCount,
                           m.removedComponentCount == 1 ? "" : "s")))
        return StepQuality(grade: overall, summary: summary(overall, graded), metrics: graded)
    }

    private static func dataMetric(_ m: ICARunMetrics) -> QualityMetric {
        guard let kappa = m.kappa else {
            return QualityMetric(name: "Data per component", grade: .good,
                                 detail: "not known for a replayed decomposition.", reached: false)
        }
        let grade: RunGrade = kappa < kappaGoodFloor ? .watch : .good
        let tail = grade == .good
            ? "."
            : String(format: " — below the usual %.0f × n²; weak sources may not separate cleanly (large ones like blinks still do).", kappaGoodFloor)
        return QualityMetric(
            name: "Data per component", grade: grade,
            detail: String(format: "%.1f × n² samples (%d components)", kappa, m.componentCount) + tail)
    }

    /// Reported, never graded (see the file comment).
    private static func convergenceMetric(_ m: ICARunMetrics) -> QualityMetric {
        if m.converged {
            return QualityMetric(name: "Convergence", grade: .good,
                                 detail: "converged in \(m.iterations) iterations.")
        }
        return QualityMetric(
            name: "Convergence", grade: .good,
            detail: String(format: "stopped at the %d-iteration cap (final change %.2g) — reported, not graded.",
                           m.maxIterations, m.finalChange))
    }

    private static func removedMetric(_ m: ICARunMetrics) -> QualityMetric {
        let name = "Removed components"
        if let p = m.maxRemovedBrainProbability {
            let grade: RunGrade = p >= brainProbabilityPoorFloor ? .poor : (p >= brainProbabilityWatchFloor ? .watch : .good)
            let tail: String
            switch grade {
            case .good: tail = "."
            case .watch: tail = " — part of it may be brain."
            case .poor: tail = " — ICLabel reads it as brain; removing it removes brain signal."
            }
            return QualityMetric(name: name, grade: grade,
                                 detail: String(format: "highest ICLabel Brain probability removed: %.2f", p) + tail)
        }
        if m.removedBrainLabelCount > 0 {
            // A label without probabilities (the heuristic labeller, or a
            // replay) is weaker evidence than ICLabel's own reading: Watch.
            return QualityMetric(name: name, grade: .watch,
                                 detail: "\(m.removedBrainLabelCount) removed component\(m.removedBrainLabelCount == 1 ? " is" : "s are") labelled Brain.")
        }
        return QualityMetric(name: name, grade: .good,
                             detail: "none of the \(m.removedComponentCount) removed is labelled Brain.")
    }

    private static func summary(_ overall: RunGrade, _ metrics: [QualityMetric]) -> String {
        switch overall {
        case .good:
            return "Clean ICA removal."
        case .watch:
            let reasons = metrics.filter { $0.reached && $0.grade == .watch }.map(\.name.localizedLowercase)
            return "Removed, but worth a look (" + reasons.joined(separator: ", ") + ")."
        case .poor:
            let reasons = metrics.filter { $0.reached && $0.grade == .poor }.map(\.name.localizedLowercase)
            return "Likely removed brain or separated poorly (" + reasons.joined(separator: ", ") + ")."
        }
    }
}
