import Foundation
import Testing
@testable import EVA

@MainActor
struct PSADecisionMatrixArtifactStatusTests {
    private func event(_ id: String, code: String = "Eye Blink",
                       state: PSAArtifactCorrectionState) -> PSAArtifactEventDetail {
        .init(eventID: id, label: code, code: code, relativeTimeSeconds: 0.1,
              hasCorrection: state != .uncorrected, isCorrected: state == .corrected,
              method: state == .uncorrected ? nil : "OBS", inputRMSMicrovolts: 20,
              outputRMSMicrovolts: 10, rmsChangeFraction: 0.5)
    }

    private func model(events: [Int: [PSAArtifactEventDetail]],
                       reasons: [Int: [String]] = [:],
                       scores: [Int] = Array(repeating: 100, count: 8)) -> PSADecisionMatrixModel {
        let signal = SyntheticSignal.make(Array(repeating: Array(repeating: Float(1), count: 400), count: 4),
                                          samplingRate: 100)
        let segments = (0..<8).map { epoch in
            EpochSegment(startSample: epoch * 50, endSample: epoch * 50 + 49,
                         stimulusOffsetSamples: 10, category: "stim", sourceCode: "stim",
                         sourceTimeSeconds: Double(epoch) * 0.5, colorIndex: 0, contributingEpochCount: 1)
        }
        let preparation = PSADecisionMatrixPreparation.make(
            signal: signal, segments: segments, thresholds: .init(), detectorSegments: [:],
            recordingChannelGoodness: [:], electrodePositions: [:], globallyBadChannels: [],
            segmentHealthGoodnessScores: scores,
            suggestedRejectedEpochReasons: reasons, artifactEventsByEpoch: events
        )
        let model = PSADecisionMatrixModel(preparation: preparation)
        model.setChannelDecision(.keep, channels: [0, 1, 2, 3])
        return model
    }

    @Test func rejectedFirstSortUsesFinalDecisionsThenHealthAndAcquisitionOrder() {
        let model = model(events: [:],
                          reasons: [1: ["Uncorrected artifact"], 3: ["Missing timing marker"]],
                          scores: [80, 95, 40, 100, 60, 100, 20, 95])
        model.epochRejectionHealthThreshold = 0
        model.setEpochDecision(.reject, epoch: 5)
        model.epochOrder = .rejectedFirst
        #expect(model.orderedEpochs == [1, 3, 5, 6, 2, 4, 0, 7])

        // A manual keep moves an otherwise rejected epoch into the kept group.
        model.setEpochDecision(.keep, epoch: 1)
        #expect(model.orderedEpochs == [3, 5, 6, 2, 4, 0, 1, 7])

        // Health-threshold changes must also regroup without changing sort mode.
        model.epochRejectionHealthThreshold = 90
        #expect(model.orderedEpochs == [6, 2, 4, 0, 3, 5, 1, 7])

        // A high-health epoch still belongs with rejects if its repair is infeasible.
        model.setCellDecision(.interpolate, for: .init(channelIndex: 0, epochIndex: 7))
        #expect(model.resolvedEpochDecision(7) == .reject)
        #expect(model.orderedEpochs == [6, 2, 4, 0, 7, 3, 5, 1])
        #expect(model.preparation.segments.count == 8)
    }

    @Test func everyRenderedEpochIconHasALegendMeaningAndHoverExplanation() throws {
        let model = model(events: [
            0: [event("first-corrected", state: .corrected), event("still-uncorrected", state: .uncorrected)],
            1: [event("corrected", state: .corrected)],
            2: [event("cardiac", code: "BCG", state: .disabled)],
            3: [event("gradient", code: "MRI gradient", state: .uncorrected)],
            6: [event("muscle", code: "Muscle EMG", state: .uncorrected)]
        ], reasons: [4: ["Missing timing marker"]])
        model.setEpochDecision(.reject, epoch: 5)
        let expected: [PSAEpochStatusIcon] = [.ocular, .correctedOcular, .cardiac, .gradient,
                                             .timing, .exclusion, .otherArtifact]
        for (epoch, expectedIcon) in expected.enumerated() {
            let icon = try #require(model.epochStatusIcon(for: epoch))
            #expect(icon == expectedIcon)
            #expect(PSAEpochStatusIcon.allCases.contains(icon)) // Legend's exact vocabulary.
            let hover = model.healthHoverSummary(for: .epoch(epoch))
            #expect(hover.contains(icon.title))
            #expect(hover.contains(icon.explanation))
        }
        #expect(model.epochStatusIcon(for: 7) == nil)
        #expect(model.epochStatusIcon(for: 999) == nil)
        #expect(model.healthHoverSummary(for: .epoch(1)).contains("Kept for average"))
        #expect(model.healthHoverSummary(for: .epoch(1)).contains("1 corrected"))
        #expect(model.selectedCell == nil && model.selectedEpochs.isEmpty && model.selectedChannels.isEmpty)
    }

    @Test func correctionSummaryDeduplicatesEventsAcrossEpochsAndChannels() {
        let corrected = event("shared", state: .corrected)
        let model = model(events: [
            0: [corrected, event("raw", state: .uncorrected)],
            1: [corrected, event("disabled", code: "BCG", state: .disabled)]
        ])
        let all = model.artifactCorrectionSummary()
        #expect(all.eventCount == 3 && all.affectedEpochs == 2)
        #expect(all.corrected == 1 && all.uncorrected == 1 && all.disabled == 1)
        let selected = model.artifactCorrectionSummary(for: [0])
        #expect(selected.eventCount == 2 && selected.corrected == 1 && selected.disabled == 0)
        #expect(model.artifactCorrectionSummary(for: []).statusText == "No artifact events recorded")
        model.selectChannels([0, 1, 2])
        #expect(model.artifactCorrectionSummary().eventCount == 3) // Not multiplied by channel count.
        let hover = model.healthHoverSummary(for: .channel(0))
        #expect(hover.contains("1 corrected · 1 uncorrected · 1 correction disabled"))
        #expect(hover.contains("not channel-specific proof"))
        #expect(model.preparation.artifactEventsByEpoch[0]?.first?.method == "OBS")
        #expect(model.preparation.artifactEventsByEpoch[0]?.first?.rmsChangeFraction == 0.5)
    }

    @Test func mixedCorrectionRecordsCannotClaimAnEventWasFullyCorrected() {
        let model = model(events: [0: [event("shared", state: .corrected)],
                                   1: [event("shared", state: .uncorrected)]])
        let summary = model.artifactCorrectionSummary(for: [0, 1])
        #expect(summary.eventCount == 1)
        #expect(summary.corrected == 0 && summary.uncorrected == 1)
        #expect(model.epochStatusIcon(for: 0) == .correctedOcular)
        #expect(model.epochStatusIcon(for: 1) == .ocular)
    }
}
