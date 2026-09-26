//
//  ArtifactCleanRunGradeTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The artifact-clean run grade: touched-fraction measurement, the band edges
//  settled by ArtifactCleanRunGradeMeasurementTests, the continuous-correction
//  exemption, and the history dispatch.
//

import Foundation
import Testing
@testable import EVA

struct ArtifactCleanRunGradeTests {

    private func artifact(_ method: ArtifactCleaningMethod, events: Int) -> DefinedArtifact {
        DefinedArtifact(
            type: .ocular, name: "Blink", eventCode: "BLNK",
            events: (0..<events).map {
                MFFEvent(id: "e\($0)", code: "BLNK", beginTimeSeconds: Double($0), rawBeginTime: "", sourceFile: "t")
            },
            selectedChannelIndices: [0], windowSizeSeconds: 0.4,
            average: nil, topography: nil, cleaningMethod: method)
    }

    private func metrics(touched: Double, continuous: Bool = false, pooledEvents: Int? = nil) -> ArtifactCleanRunMetrics {
        ArtifactCleanRunMetrics(
            touchedFraction: touched, removedVarianceFraction: 0.3, eventCount: 40,
            methods: ["OBS"], includesContinuousCorrection: continuous,
            minimumPooledBasisEventCount: pooledEvents)
    }

    @Test func measuresTheTouchedFractionOverGradedChannels() {
        let original: [[Float]] = [[1, 1, 1, 1, 1, 1, 1, 1, 1, 1], [2, 2, 2, 2, 2, 2, 2, 2, 2, 2]]
        var cleaned = original
        cleaned[0][2] = 0      // one time point changed on a graded channel
        cleaned[1][7] = 0      // one on a channel that is excluded
        let a = artifact(.obs, events: 25)
        let summary = ArtifactCleaningSummary(artifactID: a.id, name: a.name, method: .obs, eventCount: 25, channelCount: 1)
        let m = ArtifactCleanRunMetrics.measure(
            original: original, cleaned: cleaned, artifacts: [a], summaries: [summary], excludedChannels: [1])
        #expect(m?.touchedFraction == 0.1)
        #expect(m?.minimumPooledBasisEventCount == 25)
        #expect(m?.includesContinuousCorrection == false)
    }

    @Test func touchedBandEdge() {
        func g(_ f: Double) -> RunGrade { ArtifactCleanRunGrade.grade(from: metrics(touched: f)).grade }
        #expect(g(ArtifactCleanRunGrade.touchedWatchFloor - 1e-6) == .good)
        #expect(g(ArtifactCleanRunGrade.touchedWatchFloor) == .watch)
        // No Poor band: cleaning beat the dirty data even at 90 % touched.
        #expect(g(0.95) == .watch)
    }

    @Test func aContinuousCorrectionIsNotGradedOnTouchedFraction() {
        let q = ArtifactCleanRunGrade.grade(from: metrics(touched: 1.0, continuous: true))
        #expect(q.grade == .good)
        #expect(q.metrics.first { $0.name == "Recording touched" }?.reached == false)
    }

    @Test func tooFewEventsForAPooledBasisIsWatch() {
        let few = ArtifactCleanRunGrade.grade(from: metrics(touched: 0.05, pooledEvents: 6))
        let enough = ArtifactCleanRunGrade.grade(from: metrics(touched: 0.05, pooledEvents: 20))
        #expect(few.grade == .watch)
        #expect(enough.grade == .good)
    }

    @MainActor @Test func theArtifactCleanNodeIsGradedAndOthersAreNot() {
        var snapshot = PipelineSnapshot()
        snapshot.artifactRunMetrics = metrics(touched: 0.5)
        #expect(RecordingHistoryModel.quality(for: EVAProcessingStep(operation: .artifactClean), in: snapshot)?.grade == .watch)
        #expect(RecordingHistoryModel.quality(for: EVAProcessingStep(operation: .waveletReduce), in: snapshot) == nil)
    }
}
