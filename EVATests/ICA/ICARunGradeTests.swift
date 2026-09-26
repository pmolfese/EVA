//
//  ICARunGradeTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The ICA run grade: metric extraction from a decomposition, the band edges
//  settled by ICARunGradeMeasurementTests, and the history dispatch.
//

import Foundation
import Testing
@testable import EVA

struct ICARunGradeTests {

    private func decomposition(
        components n: Int = 20, samples: Int = 30 * 20 * 20, iterations: Int = 80,
        finalChange: Double = 1e-8, excluded: Set<Int> = [0],
        brain: [Int: Double] = [:], labels: [Int: String] = [:]
    ) -> ICADecomposition {
        var d = ICADecomposition(
            sourceSignalPath: "/tmp/synthetic.bin",
            sourceSamplingRate: 250, analysisSamplingRate: 125, decimation: 2,
            fitFilter: nil, convergenceTolerance: 1e-7, minimumIterations: 10,
            finalChange: finalChange, varianceThreshold: 0.999, pcaVarianceRetained: 1,
            averageReference: true, channelCount: n, sampleCount: samples,
            componentCount: n, iterations: iterations,
            channelMeans: [Double](repeating: 0, count: n),
            mixingMatrix: [], unmixingMatrix: [], componentMaps: [], componentSources: [],
            explainedVariance: (0..<n).map { $0 == 0 ? 10 : 1 },
            pcaExplainedVariance: [])
        d.excludedComponents = excluded
        for (component, p) in brain {
            d.labelSuggestions[component] = ICAComponentSuggestion(
                label: "Brain", confidence: p, reason: "test", probabilities: ["Brain": p])
        }
        d.labels = labels
        return d
    }

    private func grade(_ d: ICADecomposition, maxIterations: Int = 200) -> StepQuality {
        ICARunGrade.grade(from: ICARunMetrics(decomposition: d, maxIterations: maxIterations))
    }

    private func metric(_ q: StepQuality, _ name: String) -> QualityMetric? {
        q.metrics.first { $0.name == name }
    }

    @Test func extractsKappaAndRemovedVariance() {
        let m = ICARunMetrics(decomposition: decomposition(), maxIterations: 200)
        #expect(m.kappa == 30)
        #expect(abs(m.removedVarianceFraction - 10.0 / 29.0) < 1e-12)
        #expect(m.converged)
    }

    @Test func aWellPosedRemovalGradesGood() {
        #expect(grade(decomposition(brain: [0: 0.05])).grade == .good)
    }

    @Test func kappaBandEdges() {
        func g(_ kappa: Double) -> RunGrade? {
            metric(grade(decomposition(samples: Int(kappa * 400))), "Data per component")?.grade
        }
        #expect(g(ICARunGrade.kappaGoodFloor) == .good)
        #expect(g(ICARunGrade.kappaGoodFloor - 0.5) == .watch)
        // No Poor band: the campaign found no harm down to κ ≈ 4.
        #expect(g(1) == .watch)
    }

    @Test func hittingTheIterationCapIsReportedNotGraded() {
        let q = grade(decomposition(iterations: 200, finalChange: 1e-3))
        #expect(metric(q, "Convergence")?.detail.contains("cap") == true)
        #expect(q.grade == .good)
    }

    @Test func removingAComponentICLabelCallsBrainIsPoor() {
        #expect(metric(grade(decomposition(brain: [0: 0.62])), "Removed components")?.grade == .poor)
        #expect(metric(grade(decomposition(brain: [0: 0.30])), "Removed components")?.grade == .watch)
        #expect(metric(grade(decomposition(brain: [0: 0.10])), "Removed components")?.grade == .good)
    }

    @Test func aBrainLabelWithoutProbabilitiesIsWatch() {
        let q = grade(decomposition(labels: [0: "Brain 63%"]))
        #expect(metric(q, "Removed components")?.grade == .watch)
    }

    @Test func aReplayedDecompositionWithoutASampleCountSkipsKappa() {
        var d = decomposition()
        d.sampleCount = 0
        let q = grade(d)
        #expect(metric(q, "Data per component")?.reached == false)
        #expect(q.grade == .good)
    }

    @Test func removedVarianceNeverDrivesTheGrade() {
        // Nearly everything removed, but nothing else wrong.
        let q = grade(decomposition(excluded: Set(0..<15)))
        #expect(q.grade == .good)
        #expect(metric(q, "Removed variance") != nil)
    }

    @MainActor @Test func theICANodeIsGradedAndOthersAreNot() {
        var snapshot = PipelineSnapshot()
        snapshot.icaRunMetrics = ICARunMetrics(decomposition: decomposition(brain: [0: 0.9]), maxIterations: 200)
        #expect(RecordingHistoryModel.quality(for: EVAProcessingStep(operation: .icaClean), in: snapshot)?.grade == .poor)
        #expect(RecordingHistoryModel.quality(for: EVAProcessingStep(operation: .filter), in: snapshot) == nil)
    }
}
