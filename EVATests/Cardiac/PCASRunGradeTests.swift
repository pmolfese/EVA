//
//  PCASRunGradeTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Band boundaries for the PCA-S run grade (SI-4 Track 3). The numbers here are
//  the ones the campaign settled; this pins them so a later edit to the producer
//  cannot quietly move a threshold.
//

import Foundation
import Testing
@testable import EVA

struct PCASRunGradeTests {

    private func diagnostics() -> SourceInformedOperatorDiagnostics {
        SourceInformedOperatorDiagnostics(
            electrodeCount: 32, brainColumnCount: 29, artifactInputCount: 4,
            artifactRetainedCount: 4, artifactDroppedCount: 0,
            requestedBrainRegularization: 0.02, projectedBrainMeanColumnPower: 1,
            effectiveRidge: 0.02, minimumCholeskyDiagonal: 0.5, maximumCholeskyDiagonal: 4)
    }

    /// A report with the grade-relevant fields set; everything else is filler.
    private func report(
        accepted: Int, candidates: Int, kept: Int, rejected: Int,
        reliabilities: [Double], removed: Double
    ) -> BCGSurrogateReport {
        BCGSurrogateReport(
            correctedChannelCount: 32, excludedChannelCount: 0,
            candidateBeatCount: candidates, acceptedBeatCount: accepted,
            artifactComponentCount: kept, artifactVarianceFractions: reliabilities.map { _ in 0.1 },
            artifactComponentReliabilities: reliabilities,
            reliabilityRejectedComponentCount: rejected,
            patternSearch: "iterative", representativeBeatIndex: nil,
            regionalSourceCount: 29, brainColumnCount: 29, brainRegularization: 0.02,
            operatorDiagnostics: diagnostics(), headModelName: "Classic 3-shell (1:80)",
            headShellRadiiMeters: [0.08, 0.085, 0.088, 0.092], harmonicTerms: 60,
            geometryName: "test", reference: "average", removedVarianceFraction: removed)
    }

    @Test func aStrongLongRecordingGradesGood() {
        let q = PCASRunGrade.grade(from: report(
            accepted: 156, candidates: 190, kept: 4, rejected: 0,
            reliabilities: [0.99, 0.98, 0.97, 0.96], removed: 0.44))
        #expect(q.grade == .good)
        #expect(q.metrics.allSatisfy { $0.grade == .good })
    }

    @Test func tooFewBeatsPullsTheGradeToWatch() {
        let q = PCASRunGrade.grade(from: report(
            accepted: 24, candidates: 61, kept: 4, rejected: 0,
            reliabilities: [0.99, 0.98, 0.97, 0.96], removed: 0.44))
        #expect(q.grade == .watch)
        #expect(q.metrics.first { $0.name == "Accepted beats" }?.grade == .watch)
    }

    @Test func beatsAtTheGoodFloorAreGood() {
        let q = PCASRunGrade.grade(from: report(
            accepted: 40, candidates: 90, kept: 4, rejected: 0,
            reliabilities: [0.99, 0.98, 0.97, 0.96], removed: 0.44))
        #expect(q.metrics.first { $0.name == "Accepted beats" }?.grade == .good)
    }

    @Test func removedVarianceNearingOneIsWatch() {
        let q = PCASRunGrade.grade(from: report(
            accepted: 100, candidates: 120, kept: 4, rejected: 0,
            reliabilities: [0.99, 0.98, 0.97, 0.96], removed: 0.71))
        #expect(q.grade == .watch)
        #expect(q.metrics.first { $0.name == "Removed variance" }?.grade == .watch)
    }

    @Test func overSubtractionGradesPoorEvenWhenApplied() {
        let q = PCASRunGrade.grade(from: report(
            accepted: 100, candidates: 120, kept: 4, rejected: 0,
            reliabilities: [0.99, 0.98, 0.97, 0.96], removed: 1.10))
        #expect(q.grade == .poor)
        #expect(q.metrics.first { $0.name == "Removed variance" }?.grade == .poor)
    }

    @Test func fewKeptComponentsIsWatch() {
        let q = PCASRunGrade.grade(from: report(
            accepted: 100, candidates: 120, kept: 2, rejected: 2,
            reliabilities: [0.95, 0.92], removed: 0.4))
        #expect(q.metrics.first { $0.name == "Component reliability" }?.grade == .watch)
        #expect(q.grade == .watch)
    }

    @Test func theOverallGradeIsTheWorstMetric() {
        // Good beats, good reliability, poor removed variance → overall poor.
        let q = PCASRunGrade.grade(from: report(
            accepted: 156, candidates: 190, kept: 4, rejected: 0,
            reliabilities: [0.99, 0.98, 0.97, 0.96], removed: 1.2))
        #expect(q.grade == .poor)
    }

    @Test func aTooFewBeatsRefusalGradesPoorAndNamesTheGate() {
        let q = PCASRunGrade.grade(refusal: .tooFewAcceptedBeats(accepted: 6, required: 10))
        #expect(q.grade == .poor)
        let beats = q.metrics.first { $0.name == "Accepted beats" }
        #expect(beats?.grade == .poor)
        #expect(beats?.reached == true)
        #expect(beats?.detail.contains("6") == true)
        // The gates it never reached are marked not-reached, not scored zero.
        #expect(q.metrics.first { $0.name == "Removed variance" }?.reached == false)
    }

    @Test func aNoComponentsRefusalPointsAtReliability() {
        let q = PCASRunGrade.grade(refusal: .noArtifactComponents)
        #expect(q.grade == .poor)
        #expect(q.metrics.first { $0.name == "Component reliability" }?.reached == true)
    }
}
