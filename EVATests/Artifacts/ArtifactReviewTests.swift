import Foundation
import Testing
@testable import EVA

struct ArtifactReviewTests {
    @Test func navigationAdvancesEighteenExamplesIncludingPartialLastSet() {
        let first = ArtifactReviewNavigation(count: 49, selectedIndex: 4)
        #expect(first.visibleRange == 0..<18)
        #expect(first.pageCount == 3)
        #expect(first.destination(-1) == nil)
        #expect(first.destination(1) == 18)
        let second = ArtifactReviewNavigation(count: 49, selectedIndex: 31)
        #expect(second.visibleRange == 18..<36)
        #expect(second.destination(-1) == 0)
        #expect(second.destination(1) == 36)
        let last = ArtifactReviewNavigation(count: 49, selectedIndex: 48)
        #expect(last.visibleRange == 36..<49)
        #expect(last.destination(1) == nil)
        #expect(last.destination(-1) == 18)
        #expect(ArtifactReviewNavigation(count: 319, selectedIndex: 0).pageCount == 18)
    }

    @Test func oneSetNavigatesExamplesAndNeverWraps() {
        let middle = ArtifactReviewNavigation(count: 18, selectedIndex: 4)
        #expect(middle.pageCount == 1)
        #expect(middle.destination(-1) == 3)
        #expect(middle.destination(1) == 5)
        #expect(middle.destination(1, byPage: true) == nil)
        #expect(ArtifactReviewNavigation(count: 18, selectedIndex: 0).destination(-1) == nil)
        #expect(ArtifactReviewNavigation(count: 18, selectedIndex: 17).destination(1) == nil)
        #expect(ArtifactReviewNavigation(count: 1, selectedIndex: 0).destination(1) == nil)
    }

    @Test func exactAndEmptySetsHaveValidBounds() {
        let exact = ArtifactReviewNavigation(count: 36, selectedIndex: 8)
        #expect(exact.pageCount == 2)
        #expect(exact.destination(1) == 18)
        let last = ArtifactReviewNavigation(count: 36, selectedIndex: 35)
        #expect(last.visibleRange == 18..<36)
        #expect(last.destination(1) == nil)
        let empty = ArtifactReviewNavigation(count: 0, selectedIndex: 0)
        #expect(empty.visibleRange.isEmpty)
        #expect(empty.destination(1) == nil)
        #expect(empty.destination(-1) == nil)
        let stale = ArtifactReviewNavigation(count: 3, selectedIndex: 20)
        #expect(stale.visibleRange == 0..<3)
        #expect(stale.destination(1) == nil)
    }

    private func event(_ id: String, time: Double) -> MFFEvent {
        MFFEvent(id: id, code: "blink", beginTimeSeconds: time, rawBeginTime: "\(time)",
                 sourceFile: "test", durationSeconds: 0.18, timeAnchor: .peak)
    }
    private func definition(_ events: [MFFEvent]) -> DefinedArtifact {
        DefinedArtifact(type: .ocular, name: "Blinks", eventCode: "blink", events: events,
                        selectedChannelIndices: [0, 1], windowSizeSeconds: 0.5,
                        average: nil, topography: nil, cleaningMethod: .obs)
    }
    private func fixture() -> (MFFSignalData, DefinedArtifact) {
        let events = [event("a", time: 1), event("b", time: 2), event("c", time: 3)]
        var row = [Float](repeating: 0, count: 500)
        for center in [100, 200, 300] {
            for offset in -20...20 { row[center + offset] = 200 * Float(exp(-pow(Double(offset) / 6, 2))) }
        }
        return (SyntheticSignal.make([row, row.map { -$0 }], samplingRate: 100), definition(events))
    }

    @Test func confidenceIsTransparentAndRespectsSignedSimilarity() {
        let (signal, artifact) = fixture()
        let result = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [])
        var example = result.examples[0]
        #expect(example.matchConfidence.score == 100)
        #expect(example.matchConfidence.referenceCount == 2, "The current event must not support its own score")
        #expect(example.matchConfidence.hasLimitedReference)
        example.correlation = 0.924
        #expect(example.matchConfidence.score == 92)
        example.correlation = 0.82
        #expect(example.matchConfidence.score == 82)
        #expect(example.matchConfidence.explanation.contains("variation"))
        example.correlation = -0.98
        #expect(example.matchConfidence.score == 0)
        #expect(example.matchConfidence.explanation.contains("Opposite polarity"))
        for invalid in [Double.nan, .infinity, -.infinity] {
            example.correlation = invalid
            #expect(example.matchConfidence.score == nil)
        }
    }

    @Test func confidenceIsWithheldForUnusableWindowsAndMissingReferences() {
        let (signal, artifact) = fixture()
        let result = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [])
        var example = result.examples[0]
        example.hasCompleteWindow = false
        #expect(example.matchConfidence.score == nil)
        #expect(example.matchConfidence.explanation.contains("Incomplete"))
        example.hasCompleteWindow = true
        example.samples = []
        #expect(example.matchConfidence.score == nil)
        #expect(example.matchConfidence.explanation.contains("No usable waveform"))
        var single = artifact
        single.events = [artifact.events[0]]
        let one = ArtifactReviewEngine.analyze(artifact: single, signal: signal, excluding: [])
        #expect(one.examples[0].matchConfidence.referenceCount == 0)
        #expect(one.examples[0].matchConfidence.score == nil)
        #expect(one.examples[0].matchConfidence.explanation.contains("No other reference"))
        let flat = ArtifactReviewEngine.analyze(artifact: artifact,
            signal: SyntheticSignal.make([[Float](repeating: 0, count: 500), [Float](repeating: 0, count: 500)], samplingRate: 100), excluding: [])
        #expect(flat.examples.allSatisfy { $0.matchConfidence.score == nil })
    }

    @Test func confidenceReferenceCountsFollowIncludedOnlyRebuildsWithoutChangingDecisions() {
        let (signal, base) = fixture()
        var artifact = base
        ArtifactReviewEngine.setChoice(.hold, eventID: "c", artifact: &artifact)
        ArtifactReviewEngine.rebuildReference(&artifact)
        let before = ArtifactReplayPayload(artifacts: [artifact]).replayIdentityBytes
        let result = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [])
        #expect(result.examples[0].matchConfidence.referenceCount == 1)
        #expect(result.examples[2].matchConfidence.referenceCount == 2)
        #expect(result.examples[2].matchConfidence.score == 100)
        #expect(ArtifactReviewEngine.choice(for: "c", artifact: artifact).decision == .hold)
        #expect(ArtifactReplayPayload(artifacts: [artifact]).replayIdentityBytes == before)
    }

    @Test func impactedChannelsIgnoreOffsetsContextBadAndInvalidChannels() {
        let (source, artifact) = fixture()
        let wave = source.data[0]
        var rows = [wave.map { $0 + 2000 }, wave.map { $0 * 2 }, wave.map { -$0 * 3 },
                    wave, [Float](repeating: 0, count: wave.count), wave.map { $0 * 100 }]
        rows[0][10] = 1e6 // A large contextual spike must not affect the core ranking.
        rows[3][100] = .nan
        let signal = SyntheticSignal.make(rows, samplingRate: 100)
        let impacts = ArtifactReviewEngine.mostImpactedChannels(for: artifact.events[0], artifact: artifact,
            signal: signal, excluding: [5])
        #expect(impacts.map(\.channelIndex) == [2, 1, 0])
        #expect(abs(impacts[0].peakToPeakMicrovolts / impacts[1].peakToPeakMicrovolts - 1.5) < 0.001)
        #expect(abs(impacts[1].peakToPeakMicrovolts / impacts[2].peakToPeakMicrovolts - 2) < 0.001)
        let ties = ArtifactReviewEngine.mostImpactedChannels(for: artifact.events[0], artifact: artifact,
            signal: SyntheticSignal.make(Array(repeating: wave, count: 8), samplingRate: 100), excluding: [])
        #expect(ties.map(\.channelIndex) == [0, 1, 2, 3, 4])
    }

    @Test func contextExtendsDisplayWithoutChangingCorrectionOrScoring() throws {
        let (signal, artifact) = fixture()
        let event = artifact.events[0]
        let short = try #require(ArtifactReviewEngine.contextWindow(for: event, artifact: artifact,
            signal: signal, contextSeconds: 0.25))
        let long = try #require(ArtifactReviewEngine.contextWindow(for: event, artifact: artifact,
            signal: signal, contextSeconds: 2))
        #expect(short.core == long.core)
        #expect(short.padded == long.padded)
        #expect(short.displayed.lowerBound == short.padded.lowerBound - 25)
        #expect(short.displayed.upperBound == short.padded.upperBound + 25)
        #expect(long.displayed.lowerBound < 0, "Missing recording-edge context stays blank rather than shifting alignment")
        let original = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [])
        let extended = SyntheticSignal.make(signal.data + [signal.data[0].map { $0 * 10 }], samplingRate: 100)
        let result = ArtifactReviewEngine.analyze(artifact: artifact, signal: extended, excluding: [])
        #expect(result.channelIndices == original.channelIndices)
        #expect(result.examples.map(\.correlation) == original.examples.map(\.correlation))
        #expect(result.examples[0].impactedChannels.first?.channelIndex == 2)
        let singleScale = ArtifactReviewEngine.displayScale(channels: [0], window: short, signal: extended, analysis: result)
        let sharedScale = ArtifactReviewEngine.displayScale(channels: [0, 2], window: short, signal: extended, analysis: result)
        #expect(sharedScale > singleScale * 9.9)
    }

    @Test func contextualTraceEnvelopePreservesSpikesAndNonfiniteGaps() {
        var row = [Float](repeating: 0, count: 10000)
        row[123] = 1000
        row[124] = -900
        row[125] = .nan
        row[127] = .nan
        let indices = ArtifactReviewEngine.traceIndices(row, range: 0..<row.count)
        #expect(indices.contains(123))
        #expect(indices.contains(124))
        #expect(indices.contains(125))
        #expect(indices.contains(127))
        #expect(indices.first == 0)
        #expect(indices.last == row.count - 1)
        #expect(indices == Array(Set(indices)).sorted())
        #expect(indices.count < row.count)
    }

    @Test func topographyUsesPeakGFPAndMasksExcludedUnmappedAndInvalidSensors() throws {
        let (base, artifact) = fixture()
        let wave = base.data[0]
        var rows = [wave.map { $0 + 900 }, wave.map { -$0 - 400 }, wave.map { $0 * 0.5 + 20 },
                    wave.map { -$0 * 0.5 }, wave.map { $0 * 1000 }, wave]
        rows[5][100] = .nan
        let signal = SyntheticSignal.make(rows, samplingRate: 100)
        let map = try #require(ArtifactReviewEngine.peakTopography(for: artifact.events[0], artifact: artifact,
            signal: signal, excluding: [4], mappedChannels: Set(0..<6)))
        #expect(map.channelIndices == [0, 1, 2, 3])
        #expect(map.sampleIndex == 100)
        #expect(map.timeSeconds == 1)
        #expect(map.values[0] > 0 && map.values[1] < 0)
        #expect(abs(map.channelIndices.map { map.values[$0] }.reduce(0, +)) < 1e-8)
        #expect(map.globalFieldPower > 0)
        #expect(map.values[4] == 0 && map.values[5] == 0, "Masked rows must not be passed to interpolation")
        let mapped = try #require(ArtifactReviewEngine.peakTopography(for: artifact.events[0], artifact: artifact,
            signal: signal, excluding: [], mappedChannels: [0, 1, 2]))
        #expect(mapped.channelIndices == [0, 1, 2])
        let original = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [4])
        let spatial = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [4],
            topographyChannelIndices: [0, 1, 2])
        #expect(original.examples.map(\.correlation) == spatial.examples.map(\.correlation))
        #expect(spatial.examples[0].topography?.channelIndices == [0, 1, 2])
    }

    @Test func topographyWithholdsFlatCommonModeEdgesAndInsufficientSensors() {
        let (base, artifact) = fixture()
        let signal = SyntheticSignal.make(Array(repeating: base.data[0], count: 4), samplingRate: 100)
        #expect(ArtifactReviewEngine.peakTopography(for: artifact.events[0], artifact: artifact,
            signal: signal, excluding: []) == nil, "A common-mode signal has no spatial contrast after average reference")
        #expect(ArtifactReviewEngine.peakTopography(for: artifact.events[0], artifact: artifact,
            signal: base, excluding: []) == nil)
        let flat = SyntheticSignal.make(Array(repeating: [Float](repeating: 7, count: 500), count: 4), samplingRate: 100)
        #expect(ArtifactReviewEngine.peakTopography(for: artifact.events[0], artifact: artifact,
            signal: flat, excluding: []) == nil)
        #expect(ArtifactReviewEngine.peakTopography(for: event("edge", time: 0), artifact: artifact,
            signal: signal, excluding: []) == nil)
    }

    @Test func derivesMultichannelSimilarityWithoutOcularCancellation() {
        let (signal, artifact) = fixture()
        let result = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [])
        #expect(result.referenceCount == 3)
        #expect(result.channelIndices == [0, 1])
        #expect(result.examples.allSatisfy { ($0.correlation ?? 0) > 0.999 })
        #expect(result.examples.allSatisfy { $0.band == .close })
        #expect(result.reference.contains { abs($0) > 50 })
        let excluded = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [0])
        #expect(excluded.channelIndices == [1])
        #expect(excluded.examples.allSatisfy { ($0.correlation ?? 0) > 0.999 })
    }

    @Test func oneEventFlatAndNonfiniteInputsDoNotReceiveFalsePerfectScores() {
        let (signal, artifact) = fixture()
        var single = artifact
        single.events = [artifact.events[0]]
        let one = ArtifactReviewEngine.analyze(artifact: single, signal: signal, excluding: [])
        #expect(one.referenceCount == 1)
        #expect(one.examples[0].correlation == nil)
        var data = signal.data
        data[0][100] = .nan
        let bad = ArtifactReviewEngine.analyze(artifact: artifact, signal: SyntheticSignal.make(data, samplingRate: 100), excluding: [])
        #expect(bad.examples[0].samples.isEmpty)
        #expect(bad.examples[0].correlation == nil)
        let flat = ArtifactReviewEngine.analyze(artifact: artifact,
            signal: SyntheticSignal.make([[Float](repeating: 0, count: 500), [Float](repeating: 0, count: 500)], samplingRate: 100), excluding: [])
        #expect(flat.examples.allSatisfy { $0.correlation == nil })
    }

    @Test func autoRulesPreserveManualChoicesAndKeepMiddleScoresOnHold() {
        let (signal, base) = fixture()
        var artifact = base
        ArtifactReviewEngine.setChoice(.exclude, eventID: "a", artifact: &artifact)
        var result = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [])
        result.examples[1].correlation = 0.82
        result.examples[2].correlation = nil
        let rules = ArtifactReviewRules()
        ArtifactReviewEngine.applyRules(rules, analysis: result, artifact: &artifact)
        #expect(ArtifactReviewEngine.choice(for: "a", artifact: artifact) == ArtifactReviewChoice(decision: .exclude, isManual: true))
        #expect(ArtifactReviewEngine.choice(for: "b", artifact: artifact).decision == .hold)
        #expect(ArtifactReviewEngine.choice(for: "c", artifact: artifact).decision == .hold)
        #expect(artifact.events.isEmpty)
        #expect(ArtifactReviewEngine.candidates(for: artifact).count == 3)
        let cleaned = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])
        #expect(cleaned.summaries.isEmpty)
        #expect(cleaned.signal.data == signal.data)
    }

    @Test func selectedLimitsExcludeBadWindowsOrExcessAmplitude() {
        let (signal, artifact) = fixture()
        let result = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [])
        var rules = ArtifactReviewRules()
        rules.limitsPeak = true
        rules.maximumPeakMicrovolts = 20
        #expect(ArtifactReviewEngine.proposedChoice(for: result.examples[0], artifact: artifact, rules: rules).decision == .exclude)
        var edge = result.examples[0]
        edge.hasCompleteWindow = false
        rules.limitsPeak = false
        #expect(ArtifactReviewEngine.proposedChoice(for: edge, artifact: artifact, rules: rules).decision == .exclude)
    }

    @Test func splitMovesEventsAndPreservesIndependentDefinitionsAndReplay() throws {
        let (signal, base) = fixture()
        var artifact = base
        ArtifactReviewEngine.setChoice(.hold, eventID: "b", artifact: &artifact)
        let child = try #require(ArtifactReviewEngine.split(eventIDs: ["b", "c"], name: "Variation", method: .sspPCA, parent: &artifact))
        #expect(ArtifactReviewEngine.candidates(for: artifact).map(\.id) == ["a"])
        #expect(ArtifactReviewEngine.candidates(for: child).map(\.id) == ["b", "c"])
        #expect(artifact.events.map(\.id) == ["a"])
        #expect(child.events.map(\.id) == ["c"])
        #expect(child.reviewState?.sourceArtifactID == artifact.id)
        #expect(child.cleaningMethod == .sspPCA)
        #expect(child.id != artifact.id)
        #expect(Set(artifact.events.map(\.id)).isDisjoint(with: child.events.map(\.id)))
        let payload = ArtifactReplayPayload(artifacts: [artifact, child])
        let decoded = try JSONDecoder().decode(ArtifactReplayPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.artifacts[1].reviewState?.choices["b"]?.decision == .hold)
        #expect(decoded.artifacts[1].reviewState?.sourceArtifactID == artifact.id)
        #expect(decoded.replayIdentityBytes == payload.replayIdentityBytes)
        let output = ArtifactCleaner.cleanedSignal(from: signal, artifacts: decoded.artifacts, excluding: [])
        #expect(output.signal.data[0][200] == signal.data[0][200], "Held event must remain untouched")
        #expect(output.signal.data[0][100] < signal.data[0][100] * 0.5)
        #expect(output.signal.data[0][300] < signal.data[0][300] * 0.5)
    }

    @Test func extractedSpatialFamilyIsTopLevelButKeepsSourceProvenance() throws {
        let (_, base) = fixture()
        var artifact = base
        let extracted = try #require(ArtifactReviewEngine.split(eventIDs: ["b"],
            name: "Eye movement", method: .obs, displaysAsStandaloneArtifact: true,
            parent: &artifact))

        #expect(extracted.reviewState?.displaysAsStandaloneArtifact == true)
        #expect(extracted.reviewState?.sourceArtifactID == artifact.id)
        #expect(extracted.reviewState?.sourceArtifactID != nil,
                "Top-level presentation must not erase detector lineage")
        #expect(ArtifactReviewEngine.candidates(for: artifact).map(\.id) == ["a", "c"])
        #expect(ArtifactReviewEngine.candidates(for: extracted).map(\.id) == ["b"])
        let decoded = try JSONDecoder().decode(ArtifactReplayPayload.self,
            from: JSONEncoder().encode(ArtifactReplayPayload(artifacts: [artifact, extracted])))
        #expect(decoded.artifacts[1].reviewState?.displaysAsStandaloneArtifact == true)
    }

    @Test func transfersSelectionsBetweenSiblingClassesWithoutDuplicatingEvents() throws {
        let (_, base) = fixture()
        var root = base
        root.thresholdOcularKind = .blink
        root.thresholdOcularCandidates = root.events.map { event in
            ThresholdOcularCandidate(event: event, startTimeSeconds: event.centerTimeSeconds - 0.05,
                endTimeSeconds: event.centerTimeSeconds + 0.13, peakMicrovolts: 200)
        }
        ArtifactReviewEngine.setChoice(.hold, eventID: "c", artifact: &root)
        var eyeMovement = try #require(ArtifactReviewEngine.split(
            eventIDs: ["b"], name: "Eye movement", method: .sspPCA, parent: &root))

        #expect(ArtifactReviewEngine.transfer(eventIDs: ["c"], source: &root, destination: &eyeMovement))
        #expect(ArtifactReviewEngine.candidates(for: root).map(\.id) == ["a"])
        #expect(ArtifactReviewEngine.candidates(for: eyeMovement).map(\.id) == ["b", "c"])
        #expect(eyeMovement.reviewState?.choices["c"]?.decision == .hold)
        #expect(root.reviewState?.sourceArtifactID == nil)
        #expect(eyeMovement.reviewState?.sourceArtifactID == root.id)
        #expect(root.thresholdOcularCandidates?.map(\.id) == ["a", "b", "c"],
                "The detector root keeps its complete ledger for identical refreshes")
        #expect(eyeMovement.thresholdOcularCandidates?.map(\.id) == ["b", "c"])
        #expect(Set(root.events.map(\.id)).isDisjoint(with: eyeMovement.events.map(\.id)))
        #expect(!ArtifactReviewEngine.transfer(eventIDs: ["a"], source: &root, destination: &eyeMovement),
                "The last member must remain in its source class")

        #expect(ArtifactReviewEngine.transfer(eventIDs: ["b"], source: &eyeMovement, destination: &root))
        #expect(root.reviewState?.sourceArtifactID == nil, "Moving back must not turn the root into its own child")
        #expect(ArtifactReviewEngine.candidates(for: root).map(\.id) == ["a", "b"])
        #expect(ArtifactReviewEngine.candidates(for: eyeMovement).map(\.id) == ["c"])
        #expect(root.thresholdOcularCandidates?.map(\.id) == ["a", "b", "c"])
        #expect(eyeMovement.thresholdOcularCandidates?.map(\.id) == ["c"])
    }

    @Test func crossDetectorTransferTracksOriginAndDestinationRefreshReturnsTheEvent() throws {
        let (_, base) = fixture()
        var blinks = base
        blinks.name = "Eye Blinks"
        blinks.thresholdOcularKind = .blink
        blinks.thresholdOcularCandidates = blinks.events.map { event in
            ThresholdOcularCandidate(event: event, startTimeSeconds: event.centerTimeSeconds - 0.05,
                endTimeSeconds: event.centerTimeSeconds + 0.13, peakMicrovolts: 200)
        }
        let movementEvents = [event("m1", time: 4), event("m2", time: 5)]
        var movements = definition(movementEvents)
        movements.name = "Eye Movements"
        movements.thresholdOcularKind = .movement
        movements.thresholdOcularCandidates = movementEvents.map { event in
            ThresholdOcularCandidate(event: event, startTimeSeconds: event.centerTimeSeconds - 0.05,
                endTimeSeconds: event.centerTimeSeconds + 0.13, peakMicrovolts: 120)
        }

        #expect(ArtifactReviewEngine.transfer(eventIDs: ["c"], source: &blinks, destination: &movements))
        #expect(ArtifactReviewEngine.candidates(for: blinks).map(\.id) == ["a", "b"])
        #expect(ArtifactReviewEngine.candidates(for: movements).map(\.id) == ["c", "m1", "m2"])
        #expect(movements.reviewState?.importedCandidateSourceIDs?["c"] == blinks.id)
        #expect(movements.thresholdOcularCandidates?.map(\.id) == ["m1", "m2"],
                "A detector root's ledger must contain only its native detections")

        var artifacts = [blinks, movements]
        ArtifactReviewEngine.removeSplitClasses(from: &artifacts, sourceID: movements.id)
        let restoredBlinks = try #require(artifacts.first { $0.id == blinks.id })
        let refreshedMovements = try #require(artifacts.first { $0.id == movements.id })
        #expect(ArtifactReviewEngine.candidates(for: restoredBlinks).map(\.id) == ["a", "b", "c"])
        #expect(ArtifactReviewEngine.candidates(for: refreshedMovements).map(\.id) == ["m1", "m2"])
        #expect(refreshedMovements.reviewState?.importedCandidateSourceIDs == nil)
    }

    @Test func thresholdRefreshPreservesPartitionsThenResetsDescendantsOnNewDetection() throws {
        let (_, base) = fixture()
        let revision = UUID()
        let candidates = base.events.map { event in
            ThresholdOcularCandidate(event: MFFEvent(id: event.id, code: "Eye Blink",
                beginTimeSeconds: event.beginTimeSeconds, rawBeginTime: event.rawBeginTime,
                sourceFile: EyeArtifactThresholdDetector.sourceFile, durationSeconds: 0.18, timeAnchor: .peak),
                startTimeSeconds: event.beginTimeSeconds - 0.05,
                endTimeSeconds: event.beginTimeSeconds + 0.13, peakMicrovolts: 200)
        }
        let blink = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        let movement = EyeArtifactThresholdConfiguration.defaults(for: .movement)
        var artifacts: [DefinedArtifact] = []
        func sync(_ source: UUID) -> Set<UUID> {
            ThresholdOcularArtifactBridge.synchronize(artifacts: &artifacts, events: candidates.map(\.event),
                blinkConfiguration: blink, movementConfiguration: movement, candidates: candidates, sourceRevision: source)
        }
        _ = sync(revision)
        let child = try #require(ArtifactReviewEngine.split(eventIDs: ["b"], name: "Second shape", method: .obs, parent: &artifacts[0]))
        artifacts.append(child)
        #expect(ArtifactReviewEngine.isThresholdFamily(child))
        #expect(child.reviewState?.sourceThresholdKind == .blink)
        #expect(sync(revision).isEmpty)
        #expect(artifacts.count == 2)
        #expect(artifacts[0].events.map(\.id) == ["a", "c"])
        _ = sync(UUID())
        #expect(artifacts.count == 1)
        #expect(artifacts[0].events.count == 3)
        #expect(artifacts[0].reviewState == nil)
    }

    @Test func rebuildUsesOnlyIncludedEventsAndBCGReviewSelectsArtifactAnchors() {
        let (_, base) = fixture()
        var artifact = base
        artifact.type = .bcg
        artifact.cleaningMethod = .pcaS
        var settings = BCGSurrogateSettings.default
        settings.beatSource = .rWaves
        artifact.pcaSSettings = settings
        ArtifactReviewEngine.setChoice(.exclude, eventID: "a", artifact: &artifact)
        #expect(artifact.pcaSSettings?.beatSource == .artifactEvents)
        ArtifactReviewEngine.rebuildReference(&artifact)
        #expect(artifact.reviewState?.referenceEventIDs == ["b", "c"])
    }
    @Test func reviewedRegressionRederivesAverageAndPCASCannotBypassHeldEvents() async {
        let (signal, base) = fixture()
        var artifact = base
        ArtifactReviewEngine.setChoice(.exclude, eventID: "a", artifact: &artifact)
        artifact.cleaningMethod = .regression
        let output = await ArtifactCleaningExecutor.cleanedSignal(from: signal, artifacts: [artifact], excluding: [], geometry: nil)
        #expect(output.signal.data[0][100] == signal.data[0][100])
        #expect(output.signal.data[0][200] < signal.data[0][200] * 0.5)
        ArtifactReviewEngine.setChoice(.hold, eventID: "b", artifact: &artifact)
        ArtifactReviewEngine.setChoice(.hold, eventID: "c", artifact: &artifact)
        artifact.type = .bcg
        artifact.cleaningMethod = .pcaS
        var settings = BCGSurrogateSettings.default
        settings.beatSource = .rWaves
        artifact.pcaSSettings = settings
        let held = await ArtifactCleaningExecutor.cleanedSignal(from: signal, artifacts: [artifact], excluding: [],
            geometry: nil, rWaveTimes: [1, 2, 3])
        #expect(held.summaries.isEmpty)
        #expect(held.failures.isEmpty)
        #expect(held.signal.data == signal.data)
    }

    @Test func openingReviewDoesNotChangeBCGAnchorsAndOrdinaryMovementIsReviewable() {
        let (_, base) = fixture()
        var artifact = base
        artifact.type = .movement
        #expect(ArtifactReviewEngine.canReview(artifact))
        artifact.cleaningMethod = .movementPCA
        #expect(!ArtifactReviewEngine.canReview(artifact))
        artifact.type = .bcg
        artifact.cleaningMethod = .pcaS
        var settings = BCGSurrogateSettings.default
        settings.beatSource = .rWaves
        artifact.pcaSSettings = settings
        ArtifactReviewEngine.prepare(&artifact)
        #expect(artifact.effectivePCASSettings.beatSource == .rWaves)
        ArtifactReviewEngine.setChoice(.hold, eventID: "a", artifact: &artifact)
        #expect(artifact.effectivePCASSettings.beatSource == .artifactEvents)
    }

}


extension ArtifactReviewTests {
    private func spatialExample(_ id: String, values: [Double], channels: [Int]? = nil) -> ArtifactReviewExample {
        ArtifactReviewExample(event: event(id, time: 1), samples: [], correlation: nil,
            peakMicrovolts: nil, durationSeconds: nil, hasCompleteWindow: true, spanInsideCore: nil,
            topography: ArtifactReviewTopography(values: values, channelIndices: channels ?? Array(values.indices),
                sampleIndex: 100, timeSeconds: 1, globalFieldPower: 1))
    }

    @Test func spatialGroupsIgnoreAmplitudeAndOffsetButPreservePolarity() async throws {
        let shape = [-2.0, -1, 0, 0, 1, 2]
        let examples = (0..<12).map { index in
            let gain = Double(index + 1) * (index < 6 ? 1.0 : -1.0)
            let values = shape.map { $0 * gain + 37.0 }
            return spatialExample("e\(index)", values: values)
        }
        let hierarchy = try #require(await ArtifactSpatialGrouping.build(examples: examples))
        let groups = hierarchy.groups(minimumCorrelation: 0.85)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.eventIDs.count == 6 })
        #expect(hierarchy.unassignedIDs.isEmpty)
        #expect(groups.contains { Set($0.eventIDs) == Set((0..<6).map { "e\($0)" }) })
        #expect(groups.allSatisfy { $0.eventIDs.contains($0.representativeID) })
        #expect(groups.allSatisfy { $0.minimumCorrelation > 0.999 })
    }

    @Test func polarityInvariantSpatialGroupsMergeGlobalSignAndRetainOrientation() async throws {
        let shape = [-2.0, -1, 0, 0, 1, 2]
        let examples = (0..<12).map { index in
            let gain = Double(index + 1) * (index < 6 ? 1.0 : -1.0)
            return spatialExample("e\(index)", values: shape.map { $0 * gain + 37.0 })
        }
        let hierarchy = try #require(await ArtifactSpatialGrouping.build(
            examples: examples, polarityMode: .ignoreGlobalPolarity))
        let groups = hierarchy.groups(minimumCorrelation: 0.98)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.eventIDs) == Set(examples.map(\.id)))
        #expect(group.positiveOrientationCount == 6)
        #expect(group.negativeOrientationCount == 6)
        #expect(group.minimumCorrelation > 0.999)
        #expect(!group.meanFeature.isEmpty, "The polarity-aligned centroid must not cancel to zero")
        #expect(group.eventIDs.allSatisfy { abs(group.orientationSign(for: $0)) == 1 })
    }

    private actor SpatialPreviewRecorder {
        var hierarchy: ArtifactSpatialHierarchy?
        func store(_ value: ArtifactSpatialHierarchy) { hierarchy = value }
    }

    @Test func progressiveSpatialCutsMatchCompletedTreeAndParallelMatchesSerial() async throws {
        let count = 144 // Exercise bounded parallel branches as well as serial leaves.
        let layout = SensorLayout(name: "ring", positions: (0..<12).map { index in
            let angle = Double(index) * 2 * .pi / 12
            return SensorPosition(channelIndex: index, x: cos(angle), y: sin(angle))
        })
        let examples = (0..<count).map { event in
            spatialExample(String(format: "e%04d", event), values: (0..<12).map { channel in
                let angle = Double(channel) * 2 * .pi / 12
                let family = Double(event % 3) * 0.8
                return cos(angle + family) + 0.08 * sin(Double((event + 1) * (channel + 2)))
            })
        }
        func check(_ a: ArtifactSpatialCut, _ b: ArtifactSpatialCut) {
            #expect(a.groups.map(\.eventIDs) == b.groups.map(\.eventIDs))
            #expect(a.groups.map(\.meanFeature) == b.groups.map(\.meanFeature))
            #expect(a.groups.map(\.representativeID) == b.groups.map(\.representativeID))
            #expect(a.groups.map(\.orientationSigns) == b.groups.map(\.orientationSigns))
            #expect(a.unassignedIDs == b.unassignedIDs)
        }
        for metric in ArtifactSpatialSimilarityMetric.allCases {
            for polarity in ArtifactSpatialPolarityMode.allCases {
                for request in [ArtifactSpatialInitialCut.targetCount(1, .minimum),
                                .targetCount(3, .tenthPercentile), .cohesion(0.90, .tenthPercentile)] {
                    let recorder = SpatialPreviewRecorder()
                    let full = try #require(await ArtifactSpatialGrouping.build(examples: examples, layout: layout,
                        polarityMode: polarity, similarityMetric: metric, initialCut: request,
                        onInitialHierarchy: { await recorder.store($0) }))
                    let preview = try #require(await recorder.hierarchy)
                    #expect(!preview.isComplete)
                    #expect(full.isComplete)
                    switch request {
                    case let .targetCount(count, rule):
                        check(preview.targetCut(count: count, cohesionRule: rule, outlierFloor: 0.60),
                              full.targetCut(count: count, cohesionRule: rule, outlierFloor: 0.60))
                    case let .cohesion(threshold, rule):
                        check(preview.cohesionCut(minimumScore: threshold, cohesionRule: rule, outlierFloor: 0.60),
                              full.cohesionCut(minimumScore: threshold, cohesionRule: rule, outlierFloor: 0.60))
                    }
                    let serial = try #require(ArtifactSpatialGrouping.hierarchy(features: full.features,
                        channels: full.channels, unassignedIDs: full.unassignedIDs, polarityMode: polarity,
                        similarityMetric: metric, localNeighborhoods: full.localNeighborhoods, storesCentroids: true))
                    #expect(full.nodes.map { $0.group.eventIDs } == serial.nodes.map { $0.group.eventIDs })
                    #expect(full.nodes.map { $0.group.meanFeature } == serial.nodes.map { $0.group.meanFeature })
                    #expect(full.nodes.map { $0.group.minimumCorrelation } == serial.nodes.map { $0.group.minimumCorrelation })
                    #expect(full.nodes.map(\.children) == serial.nodes.map(\.children))
                    let cache = ArtifactSpatialGroupingCache()
                    await cache.insert(preview, for: "preview")
                    #expect(await cache.value(for: "preview") == nil)
                }
            }
        }
    }

    @Test func progressiveCancellationNeverReturnsCompletedHierarchy() async {
        let worker = Task {
            await ArtifactSpatialGrouping.build(examples: [spatialExample("a", values: [-1, 0, 1])],
                initialCut: .targetCount(1, .minimum), onInitialHierarchy: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        #expect(await worker.value == nil)
    }

    @Test func afniInspiredSpatialCostsArePolarityInvariantButKeepOneGlobalOrientation() async throws {
        let values = [-4.0, -3, -2, -1, 1, 2, 3, 4]
        let vector = try #require(ArtifactSpatialGrouping.normalized(values))
        let inverse = vector.map { -$0 }
        let layout = SensorLayout(name: "ring", positions: values.indices.map { index in
            let angle = Double(index) * 2 * Double.pi / Double(values.count)
            return SensorPosition(channelIndex: index, x: cos(angle), y: sin(angle))
        })
        let neighborhoods = ArtifactSpatialGrouping.localNeighborhoods(
            channels: Array(values.indices), layout: layout)
        #expect(neighborhoods.count == values.count)
        for metric in ArtifactSpatialSimilarityMetric.allCases {
            let score = ArtifactSpatialGrouping.similarityScore(vector, inverse,
                polarityMode: .ignoreGlobalPolarity, metric: metric,
                localNeighborhoods: neighborhoods)
            #expect(abs(score - 1) < 1e-10, "\(metric.rawValue) should merge an exact global inversion")
            let hierarchy = try #require(await ArtifactSpatialGrouping.build(examples: [
                spatialExample("positive", values: values),
                spatialExample("negative", values: values.map { -$0 })
            ], layout: layout, polarityMode: .ignoreGlobalPolarity, similarityMetric: metric))
            let groups = hierarchy.groups(minimumCorrelation: 0.98)
            #expect(groups.count == 1)
            #expect(groups.first?.similarityMetric == metric)
        }

        let nonlinear = try #require(ArtifactSpatialGrouping.normalized(values.map { $0 * abs($0) }))
        let pearson = ArtifactSpatialGrouping.similarityScore(vector, nonlinear,
            polarityMode: .ignoreGlobalPolarity, metric: .globalPearson)
        let spearman = ArtifactSpatialGrouping.similarityScore(vector, nonlinear,
            polarityMode: .ignoreGlobalPolarity, metric: .spearman)
        #expect(spearman > pearson)
        #expect(spearman > 0.999)

        let regionalReversal = try #require(ArtifactSpatialGrouping.normalized(
            Array(values.prefix(4)) + values.suffix(4).map { -$0 }))
        let local = ArtifactSpatialGrouping.similarityScore(vector, regionalReversal,
            polarityMode: .ignoreGlobalPolarity, metric: .localPearson,
            localNeighborhoods: neighborhoods)
        #expect(local < 0.95, "Local neighborhoods must not choose independent polarity flips")

        let shuffled = try #require(ArtifactSpatialGrouping.normalized([-4.0, 4, -3, 3, -2, 2, -1, 1]))
        let information = ArtifactSpatialGrouping.similarityScore(vector, shuffled,
            polarityMode: .ignoreGlobalPolarity, metric: .informationComposite)
        #expect(information < 0.85, "Distribution agreement must not erase electrode identity")

        let lpaSame = ArtifactSpatialGrouping.similarityScore(vector, vector,
            polarityMode: .signed, metric: .lpaPlus, localNeighborhoods: neighborhoods)
        let lpcSame = ArtifactSpatialGrouping.similarityScore(vector, vector,
            polarityMode: .signed, metric: .lpcPlus, localNeighborhoods: neighborhoods)
        let lpcOpposite = ArtifactSpatialGrouping.similarityScore(vector, inverse,
            polarityMode: .signed, metric: .lpcPlus, localNeighborhoods: neighborhoods)
        #expect(lpcOpposite > lpcSame, "LPC+ should favor inverse contrast in signed mode")
        #expect(lpaSame > 0.99)
        #expect(lpcOpposite > 0.99)

        let crM = ArtifactSpatialGrouping.similarityScore(vector, nonlinear,
            polarityMode: .ignoreGlobalPolarity, metric: .correlationRatioProduct)
        #expect(crM >= 0 && crM <= 1)
    }

    @Test func spatialCutsAreNestedDeterministicAndDoNotLoseEvents() async throws {
        let examples = (0..<48).map { index in
            let angle = Double(index) / 48 * 2 * Double.pi
            return spatialExample("e\(index)", values: (0..<8).map { channel in
                cos(Double(channel) * 2 * Double.pi / 8 + angle)
            })
        }
        let hierarchy = try #require(await ArtifactSpatialGrouping.build(examples: examples))
        let reversed = try #require(await ArtifactSpatialGrouping.build(examples: examples.reversed()))
        let broad = hierarchy.groups(minimumCorrelation: 0.65)
        let fine = hierarchy.groups(minimumCorrelation: 0.98)
        #expect(fine.count > broad.count)
        #expect(fine.allSatisfy { group in broad.contains { Set(group.eventIDs).isSubset(of: Set($0.eventIDs)) } })
        #expect(fine.flatMap(\.eventIDs).sorted() == examples.map(\.id).sorted())
        #expect(fine.allSatisfy { $0.minimumCorrelation >= 0.98 })
        #expect(fine.map(\.eventIDs) == reversed.groups(minimumCorrelation: 0.98).map(\.eventIDs))
    }

    @Test func robustCohesionKeepsAStableFamilyAndOutlierFloorEjectsTheException() async throws {
        let base = [-3.0, -2, -1, 1, 2, 3]
        var examples = (0..<10).map { index in
            spatialExample("base\(index)", values: base.map { $0 * Double(index + 1) + 12 })
        }
        examples.append(spatialExample("outlier", values: [1, -1, 1, -1, 1, -1]))
        let hierarchy = try #require(await ArtifactSpatialGrouping.build(
            examples: examples, polarityMode: .ignoreGlobalPolarity))

        let minimum = hierarchy.groups(minimumScore: 0.90, cohesionRule: .minimum)
        let robust = hierarchy.groups(minimumScore: 0.90, cohesionRule: .tenthPercentile)
        #expect(minimum.count > robust.count)
        let robustParent = try #require(robust.first)
        #expect(robustParent.minimumCorrelation < robustParent.tenthPercentileCorrelation)
        #expect(robustParent.tenthPercentileCorrelation <= robustParent.medianCorrelation)

        let cut = hierarchy.cohesionCut(minimumScore: 0.90,
            cohesionRule: .tenthPercentile, outlierFloor: 0.85)
        #expect(cut.groups.count == 1)
        #expect(cut.groups[0].eventIDs.count == 10)
        #expect(cut.unassignedIDs == ["outlier"])
        #expect(cut.groups[0].minimumCorrelation > 0.999)
    }

    @Test func targetCountRefinesDeterministicallyAndSelectedGroupsCanMerge() async throws {
        let examples = (0..<48).map { index in
            let angle = Double(index) / 48 * 2 * Double.pi
            return spatialExample("e\(index)", values: (0..<8).map { channel in
                cos(Double(channel) * 2 * Double.pi / 8 + angle)
            })
        }
        let hierarchy = try #require(await ArtifactSpatialGrouping.build(
            examples: examples, polarityMode: .ignoreGlobalPolarity))
        let first = hierarchy.targetCut(count: 5, cohesionRule: .tenthPercentile, outlierFloor: -1)
        let second = hierarchy.targetCut(count: 5, cohesionRule: .tenthPercentile, outlierFloor: -1)
        #expect(first.groups.count == 5)
        #expect(first.groups.map(\.eventIDs) == second.groups.map(\.eventIDs))
        #expect(first.groups.flatMap(\.eventIDs).sorted() == examples.map(\.id).sorted())
        #expect(first.unassignedIDs.isEmpty)
        #expect(first.groups.allSatisfy {
            $0.minimumCorrelation <= $0.tenthPercentileCorrelation + 1e-12
                && $0.tenthPercentileCorrelation <= $0.medianCorrelation + 1e-12
        })

        let merged = try #require(hierarchy.mergedGroup(Array(first.groups.prefix(2)), id: -1000))
        #expect(Set(merged.eventIDs) == Set(first.groups.prefix(2).flatMap(\.eventIDs)))
        #expect((2...12).contains(hierarchy.suggestedTargetCount(maximum: 12,
            cohesionRule: .tenthPercentile)))
    }

    @Test func spatialGroupingRejectsInvalidAndInconsistentMontages() async throws {
        var examples = (0..<18).map { spatialExample("e\($0)", values: [-3, -2, -1, 1, 2, 3]) }
        examples.append(spatialExample("missing", values: [-3, -2, -1, 1, 2, 3], channels: [0, 1, 2]))
        examples.append(spatialExample("flat", values: [4, 4, 4, 4, 4, 4]))
        examples.append(spatialExample("nan", values: [.nan, -2, -1, 1, 2, 3]))
        var incomplete = spatialExample("edge", values: [-3, -2, -1, 1, 2, 3])
        incomplete.hasCompleteWindow = false
        examples.append(incomplete)
        let hierarchy = try #require(await ArtifactSpatialGrouping.build(examples: examples))
        #expect(hierarchy.features.count == 18)
        #expect(Set(hierarchy.unassignedIDs) == Set(["missing", "flat", "nan", "edge"]))
        let inconsistent = [spatialExample("a", values: [-3, -2, -1, 1, 2, 3]),
                            spatialExample("b", values: [-3, -2, -1, 1, 2, 3], channels: [0, 1, 2])]
        let refused = try #require(await ArtifactSpatialGrouping.build(examples: inconsistent))
        #expect(refused.features.isEmpty)
        #expect(refused.unassignedIDs.count == 2)
        let empty = try #require(await ArtifactSpatialGrouping.build(examples: []))
        #expect(empty.groups(minimumCorrelation: 0.85).isEmpty)
    }

    @Test func spatialCacheIsBoundedAndCancellationDoesNotPublishPartialResults() async throws {
        let examples = [spatialExample("a", values: [-1, 0, 1])]
        let hierarchy = try #require(await ArtifactSpatialGrouping.build(examples: examples))
        let cache = ArtifactSpatialGroupingCache()
        for key in ["a", "b", "c", "d"] { await cache.insert(hierarchy, for: key) }
        #expect(await cache.value(for: "a") == nil)
        #expect(await cache.value(for: "d")?.features.count == 1)
        #expect(await cache.value(for: "changed-revision") == nil)
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ArtifactSpatialGrouping.build(examples: examples)
        }
        #expect(await worker.value == nil)
    }

    @Test func spatialGroupingThousandEventWorkload() async throws {
        let examples = (0..<1000).map { index in
            spatialExample("e\(index)", values: (0..<128).map { channel in
                sin(Double(channel) * 0.1 + Double(index % 5)) + Double(index % 17) * 0.001 * cos(Double(channel))
            })
        }
        let clock = ContinuousClock()
        let start = clock.now
        let hierarchy = try #require(await ArtifactSpatialGrouping.build(examples: examples))
        let built = clock.now
        for step in 65...98 { _ = hierarchy.groups(minimumCorrelation: Double(step) / 100) }
        print("Spatial benchmark: 1000 × 128 build \(start.duration(to: built)); 34 cached cuts \(built.duration(to: clock.now))")
        #expect(hierarchy.features.count == 1000)
        #expect(hierarchy.groups(minimumCorrelation: 0.85).flatMap(\.eventIDs).count == 1000)
    }
}


extension ArtifactReviewTests {
    private func waveformFixture(widths: [Double], shifts: [Int]? = nil,
                                 gains: [Double] = [1, -0.7, 0.3]) -> (ArtifactReviewAnalysis, ArtifactSpatialGroup) {
        let points = 64
        let examples = widths.enumerated().map { index, width in
            let values: [Float] = gains.flatMap { gain in
                (0..<points).map { point in
                    let x = (Double(point - (shifts?[index] ?? 0)) - 31.5) / 63.0
                    return Float(gain * Double(index + 1) * exp(-pow(x / width, 2)))
                }
            }
            return ArtifactReviewExample(event: event("wave-\(index)", time: Double(index + 1)),
                samples: values, correlation: nil, peakMicrovolts: nil, durationSeconds: nil,
                hasCompleteWindow: true, spanInsideCore: nil)
        }
        let analysis = ArtifactReviewAnalysis(examples: examples, reference: [], channelIndices: Array(gains.indices),
            pointsPerChannel: points, referenceCount: 0, sourceRevision: UUID(), artifactID: UUID())
        let family = ArtifactSpatialGroup(id: 1, eventIDs: examples.map(\.id),
            representativeID: examples.first?.id ?? "", minimumCorrelation: 1)
        return (analysis, family)
    }

    @Test func waveformSubgroupsSeparateDurationWithinOneSpatialFamily() async throws {
        let (analysis, family) = waveformFixture(widths: [0.04, 0.04, 0.04, 0.04, 0.20, 0.20, 0.20, 0.20])
        let result = try #require(await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 0.5))
        let groups = result.hierarchy.groups(minimumCorrelation: 0.95)
        #expect(groups.count == 2)
        #expect(groups.contains { Set($0.eventIDs) == Set((0..<4).map { "wave-\($0)" }) })
        #expect(groups.contains { Set($0.eventIDs) == Set((4..<8).map { "wave-\($0)" }) })
        #expect(groups.allSatisfy { !$0.meanFeature.isEmpty && $0.eventIDs.contains($0.representativeID) })
        #expect(result.hierarchy.unassignedIDs.isEmpty)
        #expect(result.waveform(groups[0].meanFeature, channel: 0).count == result.pointsPerChannel)
    }

    @Test func waveformAlignmentToleratesSmallShiftsAndAmplitudeWithoutPolarityFlips() async throws {
        let (analysis, family) = waveformFixture(widths: Array(repeating: 0.08, count: 5), shifts: [0, 1, 2, -1, -2])
        let result = try #require(await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 0.5))
        #expect(result.maximumAlignmentSeconds > 0 && result.maximumAlignmentSeconds <= 0.020)
        #expect(result.hierarchy.groups(minimumCorrelation: 0.98).count == 1)
        #expect(result.hierarchy.features.count == 5)
        var opposite = analysis
        opposite.examples[4].samples = opposite.examples[0].samples.map { -$0 }
        let signed = try #require(await ArtifactWaveformGrouping.build(analysis: opposite, family: family, windowSeconds: 0.5))
        #expect(signed.hierarchy.groups(minimumCorrelation: 0.90).contains { $0.eventIDs == ["wave-4"] })
        var orientedFamily = family
        orientedFamily.orientationSigns = [1, 1, 1, 1, -1]
        orientedFamily.polarityMode = .ignoreGlobalPolarity
        let oriented = try #require(await ArtifactWaveformGrouping.build(analysis: opposite,
            family: orientedFamily, windowSeconds: 0.5, polarityMode: .orientToSpatialFamily))
        #expect(oriented.hierarchy.groups(minimumCorrelation: 0.90).count == 1)
        #expect(oriented.reorientedEventCount == 1)
        let noShift = try #require(await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 10))
        #expect(noShift.maximumAlignmentSeconds == 0)
    }

    @Test func waveformGroupingKeepsFamilyBoundariesAndWithholdsInvalidExamples() async throws {
        var (analysis, family) = waveformFixture(widths: Array(repeating: 0.08, count: 7))
        analysis.examples[1].samples[5] = .nan
        analysis.examples[2].hasCompleteWindow = false
        analysis.examples[3].samples = Array(repeating: 4, count: analysis.examples[3].samples.count)
        analysis.examples[4].samples.removeLast()
        family = ArtifactSpatialGroup(id: family.id, eventIDs: Array(family.eventIDs.prefix(6)),
            representativeID: "wave-1", minimumCorrelation: 1)
        let result = try #require(await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 0.5))
        #expect(Set(result.hierarchy.features.map(\.eventID)) == Set(["wave-0", "wave-5"]))
        #expect(Set(result.hierarchy.unassignedIDs) == Set(["wave-1", "wave-2", "wave-3", "wave-4"]))
        #expect(result.alignmentReferenceID == "wave-0", "Use a deterministic usable fallback reference")
        analysis.channelIndices = []
        let empty = try #require(await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 0.5))
        #expect(empty.hierarchy.features.isEmpty)
        #expect(Set(empty.hierarchy.unassignedIDs) == Set(family.eventIDs))
    }

    @Test func waveformChannelsAreFixedBoundedAndCutsAreNested() async throws {
        let (analysis, family) = waveformFixture(widths: (0..<30).map { 0.025 + Double($0) * 0.008 },
            gains: [1, -0.9, 0.8, -0.7, 0.6, -0.5, 0.4, -0.3])
        let result = try #require(await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 0.5))
        #expect(result.channelIndices == [0, 1, 2, 3, 4])
        #expect(result.pointsPerChannel <= 64)
        let broad = result.hierarchy.groups(minimumCorrelation: 0.65)
        let fine = result.hierarchy.groups(minimumCorrelation: 0.98)
        #expect(fine.count > broad.count)
        #expect(fine.allSatisfy { group in broad.contains { Set(group.eventIDs).isSubset(of: Set($0.eventIDs)) } })
        #expect(fine.flatMap(\.eventIDs).sorted() == family.eventIDs.sorted())
        #expect(result.waveform(fine[0].meanFeature, channel: 7).isEmpty)
    }

    @Test func waveformCacheCancellationAndThousandEventWorkload() async throws {
        let (analysis, family) = waveformFixture(widths: (0..<1000).map { 0.03 + Double($0 % 5) * 0.035 },
            gains: [1, -0.9, 0.8, -0.7, 0.6, -0.5, 0.4, -0.3])
        let clock = ContinuousClock(), start = ContinuousClock.now
        let result = try #require(await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 0.5))
        let built = clock.now
        for step in 65...98 { _ = result.hierarchy.groups(minimumCorrelation: Double(step) / 100) }
        print("Waveform benchmark: 1000 × 8 build \(start.duration(to: built)); 34 cached cuts \(built.duration(to: clock.now))")
        #expect(result.hierarchy.features.count == 1000)
        let cache = ArtifactWaveformGroupingCache()
        for index in 0..<7 { await cache.insert(result, for: "family-\(index)") }
        #expect(await cache.value(for: "family-0") == nil)
        #expect(await cache.value(for: "family-6")?.hierarchy.features.count == 1000)
        #expect(await cache.value(for: "changed-revision/family-6") == nil)
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 0.5)
        }
        #expect(await worker.value == nil)
    }
}
