//
//  PCASRunGrade.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Turns a PCA-S result into a `StepQuality` grade. The bands here are the ones
//  the SI-4 Track-2 adversarial campaign measured and the owner settled
//  (docs/provenance/pca-s-adversarial-evaluation.md):
//
//    * accepted beats — hard-refused below 10 (upstream, by
//      `BCGSurrogateSettings.minimumAcceptedBeats`); reliable benefit needs ~40+,
//      so 10–39 is a warning band, not a block.
//    * removed variance — a report, not a target: modest below 0.6, watch as it
//      climbs toward the 1.0 over-subtraction line, poor at or past it. This
//      also stands in for electrode/co-registration mismatch, which the campaign
//      showed a condition-number guard could not detect but removed variance can.
//    * component reliability — the 0.9 split-half gate is measured-and-kept; the
//      grade reads how many components survived it.
//
//  Pure and free of the correction engine: the grade is derived from the report
//  a successful run already produces, or from the error a refusal already throws.
//  No new control flow in `BCGSurrogateCorrection`.
//

import Foundation

nonisolated enum PCASRunGrade {

    // MARK: Bands (settled with the owner, 2026-09-12/13)

    /// Accepted-beat count at or above which the correction reliably helps.
    static let beatsGoodFloor = 40
    /// Hard-refuse floor (enforced upstream); below it PCA-S cannot estimate a
    /// topography. Kept here so the grade can label a refusal consistently.
    static let beatsRefuseFloor = 10
    /// Removed-variance fraction below which removal is modest and safe.
    static let removedVarianceGoodCeiling = 0.6
    /// Removed-variance fraction at or above which the operator has taken more
    /// than the artifact carried — an over-subtraction / distortion signature.
    static let removedVariancePoorFloor = 1.0
    /// Retained-component count at or above which the dictionary is well-formed.
    static let reliabilityGoodComponentCount = 3

    // MARK: Successful run

    static func grade(from report: BCGSurrogateReport) -> StepQuality {
        let beats = beatsMetric(
            accepted: report.acceptedBeatCount, candidates: report.candidateBeatCount)
        let reliability = reliabilityMetric(
            kept: report.artifactComponentCount,
            rejected: report.reliabilityRejectedComponentCount,
            reliabilities: report.artifactComponentReliabilities)
        let removed = removedVarianceMetric(report.removedVarianceFraction)

        let metrics = [beats, reliability, removed]
        let overall = metrics.map(\.grade).max() ?? .good
        return StepQuality(grade: overall, summary: summary(for: overall, metrics: metrics), metrics: metrics)
    }

    // MARK: Refusal (no output; the pointer stays one step back)

    static func grade(refusal error: BCGSurrogateError) -> StepQuality {
        // Name the gate that tripped, and mark the metrics that were never
        // reached rather than pretending they scored zero.
        var beats = QualityMetric(name: "Accepted beats", grade: .poor,
                                  detail: "the run stopped before this was measured.", reached: false)
        var reliability = QualityMetric(name: "Component reliability", grade: .poor,
                                        detail: "not reached; the run stopped at an earlier gate.", reached: false)
        let removed = QualityMetric(name: "Removed variance", grade: .poor,
                                    detail: "not reached; nothing was removed.", reached: false)

        switch error {
        case let .tooFewAcceptedBeats(accepted, required):
            beats = QualityMetric(
                name: "Accepted beats", grade: .poor,
                detail: "\(accepted) of a required \(required) matched the artifact pattern — too few to estimate a topography.")
        case .noArtifactComponents:
            reliability = QualityMetric(
                name: "Component reliability", grade: .poor,
                detail: "no component repeated reliably enough across beats to be treated as artifact.")
        default:
            break
        }

        return StepQuality(
            grade: .poor,
            summary: error.errorDescription ?? "PCA-S made no change to the recording.",
            metrics: [beats, reliability, removed])
    }

    // MARK: Metric builders

    private static func beatsMetric(accepted: Int, candidates: Int) -> QualityMetric {
        let grade: RunGrade
        if accepted < beatsRefuseFloor { grade = .poor }
        else if accepted < beatsGoodFloor { grade = .watch }
        else { grade = .good }
        let ofCandidates = candidates > 0 ? " of \(candidates) candidates" : ""
        let tail: String
        switch grade {
        case .good: tail = ""
        case .watch: tail = " — reliable benefit needs about \(beatsGoodFloor)+."
        case .poor: tail = " — below the \(beatsRefuseFloor)-beat floor."
        }
        return QualityMetric(name: "Accepted beats", grade: grade,
                             detail: "\(accepted)\(ofCandidates)\(tail)")
    }

    private static func reliabilityMetric(kept: Int, rejected: Int, reliabilities: [Double]) -> QualityMetric {
        let grade: RunGrade = kept >= reliabilityGoodComponentCount ? .good : (kept >= 1 ? .watch : .poor)
        let considered = kept + rejected
        let minText = reliabilities.min().map { String(format: ", lowest %.2f", $0) } ?? ""
        return QualityMetric(
            name: "Component reliability", grade: grade,
            detail: "\(kept) of \(considered) component\(considered == 1 ? "" : "s") kept above 0.9\(minText).")
    }

    private static func removedVarianceMetric(_ fraction: Double) -> QualityMetric {
        let grade: RunGrade
        if fraction >= removedVariancePoorFloor { grade = .poor }
        else if fraction >= removedVarianceGoodCeiling { grade = .watch }
        else { grade = .good }
        let tail: String
        switch grade {
        case .good: tail = " — modest, artifact-sized."
        case .watch: tail = " — nearing the 1.0 over-subtraction line."
        case .poor: tail = " — at or past 1.0; the correction removed more than the artifact carried."
        }
        return QualityMetric(name: "Removed variance", grade: grade,
                             detail: String(format: "%.2f", fraction) + tail)
    }

    private static func summary(for overall: RunGrade, metrics: [QualityMetric]) -> String {
        switch overall {
        case .good:
            return "Clean PCA-S correction."
        case .watch:
            let reasons = metrics.filter { $0.grade == .watch }.map(\.name.localizedLowercase)
            let because = reasons.isEmpty ? "" : " (" + reasons.joined(separator: ", ") + ")"
            return "Corrected, but worth a look before you trust it\(because)."
        case .poor:
            return "Applied, but likely degraded the data — over-subtraction. Review or re-run."
        }
    }
}
