import Foundation
import Testing
@testable import EVA

@MainActor
struct PSAAmplitudeCutoffTests {
    private func preparation(value: Float = 180) -> PSADecisionMatrixPreparation {
        let count = 12
        var data = Array(repeating: Array(repeating: Float(5), count: 40), count: count)
        for channel in [0, 4, 8] {
            for sample in 0..<20 { data[channel][sample] = value }
        }
        let signal = SyntheticSignal.make(data, samplingRate: 100)
        let segments = (0..<2).map { epoch in
            EpochSegment(startSample: epoch * 20, endSample: epoch * 20 + 19,
                         stimulusOffsetSamples: 5, category: "stim", sourceCode: "stim",
                         sourceTimeSeconds: Double(epoch), colorIndex: 0, contributingEpochCount: 1)
        }
        let positions = Dictionary(uniqueKeysWithValues: (0..<count).map { channel in
            let angle = Double(channel) * 2 * .pi / Double(count)
            return (channel, SIMD3<Double>(cos(angle), sin(angle), 0))
        })
        return .make(
            signal: signal, segments: segments,
            thresholds: EpochBadChannelThresholds(maxBadChannelCount: 2, usesAbsoluteBadChannelCount: true),
            detectorSegments: [0: [1], 4: [1], 8: [1]], recordingChannelGoodness: [:],
            electrodePositions: positions, globallyBadChannels: [], segmentHealthGoodnessScores: [100, 100],
            suggestedRejectedEpochReasons: [0: ["Too many bad channels"]]
        )
    }

    private func model(_ preparation: PSADecisionMatrixPreparation) -> PSADecisionMatrixModel {
        let model = PSADecisionMatrixModel(preparation: preparation)
        // Isolate absolute cutoffs from the separate relative health decisions.
        model.interpolationHealthThreshold = 0
        model.epochRejectionHealthThreshold = 0
        return model
    }

    @Test func wideningMaximumRescuesTrialAndAveragingUsesTheSameDecisions() throws {
        let model = model(preparation())
        #expect(model.amplitudeRange == -150...150)
        #expect(model.badChannelCount(epoch: 0) == 3)
        #expect(model.resolvedEpochDecision(0) == .reject)
        #expect(model.keptEpochCount == 1)
        #expect(model.snapshot().materializedResult()?.segments.count == 1)

        model.amplitudeRange = -150...200
        #expect(model.badChannelCount(epoch: 0) == 0)
        #expect(model.rejectionReasons(for: 0).isEmpty)
        #expect(model.keptEpochCount == 2)
        let snapshot = model.snapshot()
        let rescued = try #require(snapshot.materializedResult())
        #expect(rescued.segments.count == 2)
        // The rescued channel is retained, not interpolated using stale flags.
        #expect(rescued.signal.data[0][0] == 180)

        model.amplitudeRange = -150...150
        #expect(model.resolvedEpochDecision(0) == .reject)
        #expect(model.snapshot().materializedResult()?.segments.count == 1)
        // An already-created worker snapshot must remain immutable.
        #expect(snapshot.materializedResult()?.segments.count == 2)
    }

    @Test func minimumAndMaximumAreIndependentAndTighteningRejectsAgain() {
        let model = model(preparation(value: -180))
        model.amplitudeRange = -150...250
        #expect(model.resolvedEpochDecision(0) == .reject)
        model.amplitudeRange = -200...250
        #expect(model.resolvedEpochDecision(0) == .keep)
        model.amplitudeRange = -170...250
        #expect(model.resolvedEpochDecision(0) == .reject)
    }

    @Test func slopeAccelerationAndRawEvidenceRemainAuthoritative() {
        for metric in ["slope", "acceleration", "raw"] {
            var prepared = preparation()
            for channel in [0, 4, 8] {
                if metric == "slope" {
                    prepared.evidence[0][channel]?.maximumSlopeMicrovoltsPerSample = 30
                } else if metric == "acceleration" {
                    prepared.evidence[0][channel]?.maximumAccelerationMicrovoltsPerSample = 20
                } else {
                    prepared.evidence[0][channel]?.maximumMicrovolts = 5
                    prepared.rawEvidence[0][channel]?.maximumMicrovolts = 250
                }
            }
            let model = model(prepared)
            model.amplitudeRange = -200...200
            #expect(model.badChannelCount(epoch: 0) == 3, "\(metric) must still flag channels")
            #expect(model.resolvedEpochDecision(0) == .reject)
        }
    }

    @Test func artifactHealthAndManualDecisionsAreNotBypassed() {
        for reason in ["Eye Blink", "Labeled Bad", "No timing marker", "health", "manual"] {
            var prepared = preparation()
            if reason == "health" { prepared.epochGoodnessScores[0] = 10 }
            let model = model(prepared)
            if reason == "health" {
                model.epochRejectionHealthThreshold = 50
            } else if reason == "manual" {
                model.setEpochDecision(.reject, epochs: [0])
            } else {
                model.suggestedRejectedEpochReasons[0] = [reason]
            }
            model.amplitudeRange = -200...200
            #expect(model.resolvedEpochDecision(0) == .reject, "\(reason) must remain in force")
            #expect(model.snapshot().materializedResult()?.segments.count == 1)
        }
        let model = model(preparation())
        let cell = PSADecisionCellID(channelIndex: 0, epochIndex: 0)
        model.setCellDecision(.interpolate, for: cell)
        model.amplitudeRange = -200...200
        #expect(model.cellOverrides[cell] == .interpolate)
        #expect(model.resolvedCellDecision(cell) == .interpolate)
        model.setEpochDecision(.keep, epochs: [0])
        model.amplitudeRange = -100...100
        #expect(model.resolvedEpochDecision(0) == .keep)
    }

    @Test func globalAndUnexplainedDetectorFlagsAreNotCleared() {
        var prepared = preparation()
        prepared.globallyBadChannels = [0, 4, 8]
        let independent = PSADecisionCellID(channelIndex: 1, epochIndex: 1)
        prepared.detectorSuggestions.insert(independent)
        let model = model(prepared)
        model.amplitudeRange = -300...300
        #expect(model.badChannelCount(epoch: 0) == 3)
        #expect(model.resolvedEpochDecision(0) == .reject)
        #expect(model.resolvedCellDecision(independent) == .interpolate)
    }

    @Test func rebuildingPreservesEditedCutoffsButUsesNewConfigurationWhenUnedited() {
        let original = model(preparation())
        original.amplitudeRange = -220...210
        original.setEpochDecision(.reject, epochs: [1])
        let rebuilt = model(preparation())
        rebuilt.restoreManualDecisions(from: original)
        #expect(rebuilt.amplitudeRange == original.amplitudeRange)
        #expect(rebuilt.resolvedEpochDecision(1) == .reject)

        var configured = preparation()
        configured.thresholds.minMicrovolts = -250
        configured.thresholds.maxMicrovolts = 250
        let fresh = model(configured)
        fresh.restoreManualDecisions(from: model(preparation()))
        #expect(fresh.amplitudeRange == -250...250)
    }
}
