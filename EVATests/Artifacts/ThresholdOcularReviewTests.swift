import Foundation
import Testing
@testable import EVA

struct ThresholdOcularReviewTests {
    private let blink = EyeArtifactThresholdConfiguration.defaults(for: .blink)
    private let movement = EyeArtifactThresholdConfiguration.defaults(for: .movement)

    private func candidate(_ id: String, time: Double) -> ThresholdOcularCandidate {
        ThresholdOcularCandidate(
            event: MFFEvent(id: id, code: "Eye Blink", beginTimeSeconds: time,
                            rawBeginTime: "\(time)", sourceFile: EyeArtifactThresholdDetector.sourceFile,
                            durationSeconds: 0.2, timeAnchor: .peak),
            startTimeSeconds: time - 0.05, endTimeSeconds: time + 0.15, peakMicrovolts: 200)
    }

    private func artifact(_ candidates: [ThresholdOcularCandidate], revision: UUID = UUID()) throws -> DefinedArtifact {
        var definitions: [DefinedArtifact] = []
        ThresholdOcularArtifactBridge.synchronize(
            artifacts: &definitions, events: candidates.map(\.event),
            blinkConfiguration: blink, movementConfiguration: movement,
            candidates: candidates, sourceRevision: revision)
        return try #require(definitions.first)
    }

    @Test func preservesExactAsymmetricThresholdBoundsAndSignedPeak() throws {
        var row = [Float](repeating: 0, count: 500)
        for index in 100..<131 { row[index] = -180 }
        row[105] = -240
        var config = blink
        config.channelOverride = [0]
        let candidates = EyeArtifactThresholdDetector.detectCandidates(
            kind: .blink, channels: [row], samplingRate: 100, duration: 5, configuration: config)
        let detected = try #require(candidates.first)
        #expect(detected.startTimeSeconds == 1)
        #expect(detected.endTimeSeconds == 1.31)
        #expect(detected.event.beginTimeSeconds == 1.05)
        #expect(detected.peakMicrovolts == -240)
        #expect(detected.event.timeAnchor == .peak)
        #expect(candidates.map(\.event) == EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: [row], samplingRate: 100, duration: 5, configuration: config))
    }

    @Test func exclusionsSurviveIdenticalRefreshButResetForNewInputsOrSettings() throws {
        let candidates = [candidate("a", time: 1), candidate("b", time: 2)]
        let revision = UUID()
        var definitions = [try artifact(candidates, revision: revision)]
        ThresholdOcularReview.setIncluded(false, eventID: "a", artifact: &definitions[0])
        #expect(definitions[0].events.map(\.id) == ["b"])
        #expect(definitions[0].thresholdOcularCandidates?.count == 2)
        let unchanged = ThresholdOcularArtifactBridge.synchronize(
            artifacts: &definitions, events: candidates.map(\.event),
            blinkConfiguration: blink, movementConfiguration: movement,
            candidates: candidates, sourceRevision: revision)
        #expect(unchanged.isEmpty)
        #expect(definitions[0].events.map(\.id) == ["b"])
        definitions[0].windowSizeSeconds = 0.8
        var revised = blink
        revised.amplitudeMinMicrovolts += 1
        let changed = ThresholdOcularArtifactBridge.synchronize(
            artifacts: &definitions, events: candidates.map(\.event),
            blinkConfiguration: revised, movementConfiguration: movement,
            candidates: candidates, sourceRevision: revision)
        #expect(!changed.isEmpty)
        #expect(definitions[0].events.count == 2)
        #expect(definitions[0].windowSizeSeconds == 0.8)
        ThresholdOcularReview.setIncluded(false, eventID: "b", artifact: &definitions[0])
        ThresholdOcularArtifactBridge.synchronize(
            artifacts: &definitions, events: candidates.map(\.event),
            blinkConfiguration: revised, movementConfiguration: movement,
            candidates: candidates, sourceRevision: UUID())
        #expect(definitions[0].events.count == 2)
        #expect(definitions[0].thresholdOcularExcludedEventIDs?.isEmpty == true)
    }

    @Test func reportsPaddedEdgeSkipsAndUnionOfOverlappingWindows() throws {
        let signal = SyntheticSignal.make([[Float](repeating: 0, count: 400)], samplingRate: 100)
        let candidates = [candidate("edge", time: 0.1), candidate("a", time: 1), candidate("b", time: 1.5)]
        var definition = try artifact(candidates)
        #expect(ArtifactCleaner.correctionWindow(for: candidates[1].event, artifact: definition, signal: signal) == 65..<135)
        #expect(ArtifactCleaner.correctionWindow(for: candidates[1].event, artifact: definition, signal: signal, includesTaper: false) == 75..<125)
        #expect(ArtifactCleaner.correctionWindow(for: candidates[0].event, artifact: definition, signal: signal) == nil)
        #expect(ArtifactCleaner.correctionWindow(for: candidates[0].event, artifact: definition, signal: signal, requiresCompleteWindow: false) == -25..<45)
        #expect(ThresholdOcularReview.usableEvents(artifact: definition, signal: signal).count == 2)
        #expect(abs(ThresholdOcularReview.coveredSeconds(artifact: definition, signal: signal) - 1.2) < 1e-9)
        ThresholdOcularReview.setIncluded(false, eventID: "a", artifact: &definition)
        #expect(abs(ThresholdOcularReview.coveredSeconds(artifact: definition, signal: signal) - 0.7) < 1e-9)
    }

    @Test func acceptedEventsAndReviewChoicesRoundTripAndAffectCleaningIdentity() throws {
        let candidates = [candidate("a", time: 1), candidate("b", time: 2)]
        var definition = try artifact(candidates)
        let initial = ArtifactReplayPayload(artifacts: [definition]).replayIdentityBytes
        ThresholdOcularReview.setIncluded(false, eventID: "a", artifact: &definition)
        definition.sspPCAComponentCount = 1
        let payload = ArtifactReplayPayload(artifacts: [definition])
        #expect(initial != payload.replayIdentityBytes)
        let decoded = try JSONDecoder().decode(ArtifactReplayPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.artifacts[0].thresholdOcularCandidates == candidates)
        #expect(decoded.artifacts[0].thresholdOcularExcludedEventIDs == ["a"])
        #expect(decoded.artifacts[0].events.map(\.id) == ["b"])
        #expect(decoded.artifacts[0].sspPCAComponentCount == 1)
        #expect(decoded.replayIdentityBytes == payload.replayIdentityBytes)
        var otherCount = definition
        otherCount.sspPCAComponentCount = 2
        #expect(ArtifactReplayPayload(artifacts: [otherCount]).replayIdentityBytes != payload.replayIdentityBytes)
        // Optional review metadata must not prevent decoding pre-stage-2 payloads.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any])
        for key in ["thresholdOcularCandidates", "thresholdOcularExcludedEventIDs", "thresholdOcularSourceRevision", "sspPCAComponentCount"] {
            json.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(DefinedArtifact.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.thresholdOcularCandidates == nil)
        #expect(legacy.sspPCAComponentCount == nil)
    }

    @Test func excludedEventsCannotTrainOrReceiveCorrection() throws {
        let candidates = [candidate("a", time: 1), candidate("b", time: 2)]
        var row = [Float](repeating: 0, count: 400)
        for center in [100, 200] {
            for offset in -10...10 { row[center + offset] = 200 * Float(exp(-pow(Double(offset) / 5, 2))) }
        }
        let signal = SyntheticSignal.make([row, row.map { -$0 }], samplingRate: 100)
        var definition = try artifact(candidates)
        ThresholdOcularReview.setIncluded(false, eventID: "a", artifact: &definition)
        for method in [ArtifactCleaningMethod.obs, .sspPCA] {
            definition.cleaningMethod = method
            definition.sspPCAComponentCount = 1
            let result = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [definition], excluding: [])
            #expect(result.signal.data[0][100] == row[100])
            #expect(result.signal.data[0][200] < row[200] * 0.5)
        }
        ThresholdOcularReview.setIncluded(false, eventID: "b", artifact: &definition)
        let result = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [definition], excluding: [])
        #expect(result.summaries.isEmpty)
        #expect(result.signal.data == signal.data)
    }
}
