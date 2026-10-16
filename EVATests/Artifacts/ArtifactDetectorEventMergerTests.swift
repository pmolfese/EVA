//
//  ArtifactDetectorEventMergerTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct ArtifactDetectorEventMergerTests {
    @Test func automaticDetectionReplacesOnlyThresholdAndQRSEvents() {
        let movement = event(
            id: "movement",
            time: 1,
            source: MovementPCAArtifactMarkerBuilder.sourceFile
        )
        let bcg = event(id: "bcg", time: 2, source: BCGDetector.sourceFile)
        let staleEye = event(
            id: "old-eye",
            time: 3,
            source: EyeArtifactThresholdDetector.sourceFile
        )
        let staleQRS = event(id: "old-qrs", time: 4, source: "\(RWaveDetector.sourceFile): Simple")
        let freshEye = event(
            id: "new-eye",
            time: 5,
            source: EyeArtifactThresholdDetector.sourceFile
        )

        let merged = ArtifactDetectorEventMerger.replacingAutomaticEvents(
            in: [staleQRS, movement, staleEye, bcg],
            with: [freshEye]
        )

        #expect(merged.map(\.id) == ["movement", "bcg", "new-eye"])
    }

    @Test func disablingThresholdDetectionPreservesOtherMarkers() {
        let movement = event(
            id: "movement",
            time: 1,
            source: MovementPCAArtifactMarkerBuilder.sourceFile
        )
        let eye = event(
            id: "eye",
            time: 2,
            source: EyeArtifactThresholdDetector.sourceFile
        )

        let merged = ArtifactDetectorEventMerger.replacingAutomaticEvents(
            in: [movement, eye],
            with: []
        )

        #expect(merged.map(\.id) == ["movement"])
    }

    private func event(id: String, time: Double, source: String) -> MFFEvent {
        MFFEvent(
            id: id,
            code: "ART",
            beginTimeSeconds: time,
            rawBeginTime: "\(time)",
            sourceFile: source
        )
    }
}

struct ThresholdOcularArtifactBridgeTests {
    private let blink = EyeArtifactThresholdConfiguration.defaults(for: .blink)
    private let movement = EyeArtifactThresholdConfiguration.defaults(for: .movement)

    private func event(_ id: String, kind: EyeArtifactKind, time: Double = 1) -> MFFEvent {
        MFFEvent(id: id, code: kind.eventCode, beginTimeSeconds: time,
                 rawBeginTime: "\(time)", sourceFile: EyeArtifactThresholdDetector.sourceFile,
                 durationSeconds: 0.12, timeAnchor: .peak)
    }

    @Test func separatesOcularKindsWithoutClaimingManualOrImportedEvents() throws {
        let manual = DefinedArtifact(type: .ocular, name: "Manual blink", eventCode: "Eye Blink",
                                     events: [], selectedChannelIndices: [], windowSizeSeconds: 0.4,
                                     average: nil, topography: nil, cleaningMethod: .obs)
        let imported = MFFEvent(id: "imported", code: "Eye Blink", beginTimeSeconds: 2,
                                rawBeginTime: "2", sourceFile: "events.xml")
        var artifacts = [manual]
        let b = event("blink", kind: .blink)
        let m = event("movement", kind: .movement)
        let changed = ThresholdOcularArtifactBridge.synchronize(
            artifacts: &artifacts, events: [b, m, imported],
            blinkConfiguration: blink, movementConfiguration: movement)
        #expect(changed.count == 2)
        #expect(artifacts.count == 3)
        #expect(artifacts[0].id == manual.id)
        for (kind, expected) in [(EyeArtifactKind.blink, b), (.movement, m)] {
            let artifact = try #require(artifacts.first { $0.thresholdOcularKind == kind })
            #expect(artifact.type == .ocular)
            #expect(artifact.cleaningMethod == .doNothing)
            #expect(artifact.events == [expected])
            #expect(artifact.average == nil)
            #expect(!artifact.usesVariableEventDuration)
        }
    }

    @Test func refreshPreservesTreatmentAndClearsStaleEvents() throws {
        var artifacts: [DefinedArtifact] = []
        func sync(_ events: [MFFEvent], config: EyeArtifactThresholdConfiguration? = nil) -> Set<UUID> {
            ThresholdOcularArtifactBridge.synchronize(
                artifacts: &artifacts, events: events,
                blinkConfiguration: config ?? blink, movementConfiguration: movement)
        }
        let first = event("first", kind: .blink)
        _ = sync([first])
        let id = try #require(artifacts.first?.id)
        artifacts[0].cleaningMethod = .obs
        artifacts[0].windowSizeSeconds = 0.8
        artifacts[0].obsPCAComponentCount = 3
        #expect(sync([first]).isEmpty, "Identical pre-cleaning detections must not undo Apply")
        let second = event("second", kind: .blink, time: 2)
        #expect(sync([second]) == [id])
        #expect(artifacts.count == 1)
        #expect(artifacts[0].id == id)
        #expect(artifacts[0].cleaningMethod == .obs)
        #expect(artifacts[0].windowSizeSeconds == 0.8)
        #expect(artifacts[0].obsPCAComponentCount == 3)
        var revised = blink
        revised.amplitudeMinMicrovolts += 10
        #expect(sync([second], config: revised) == [id])
        #expect(sync([], config: revised) == [id])
        #expect(artifacts[0].events.isEmpty)
        #expect(artifacts[0].cleaningMethod == .obs)
    }

    @Test func bridgeDefinitionsRoundTripAndDriveExistingCleaners() throws {
        let rate = 100.0
        let centers = [100, 250, 400, 550, 700, 850]
        var row = [Float](repeating: 0, count: 1000)
        for center in centers {
            for offset in -15...15 {
                row[center + offset] = 200 * Float(exp(-pow(Double(offset) / 7, 2)))
            }
        }
        // Zero-mean scalp map across the two corrected channels, matching
        // the spatially centered covariance used by the existing SSP engine.
        let signal = SyntheticSignal.make([row, row.map { -$0 }, row.map { -$0 * 0.4 }], samplingRate: rate)
        var config = blink
        config.channelOverride = [0]
        config.amplitudeMinMicrovolts = 50
        config.minDurationSeconds = 0.01
        config.velocityEnabled = false
        config.accelerationEnabled = false
        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: signal.data, samplingRate: rate,
            duration: signal.duration, configuration: config)
        #expect(events.count == centers.count)
        var artifacts: [DefinedArtifact] = []
        ThresholdOcularArtifactBridge.synchronize(
            artifacts: &artifacts, events: events,
            blinkConfiguration: config, movementConfiguration: movement)
        let data = try JSONEncoder().encode(ArtifactReplayPayload(artifacts: artifacts))
        let decoded = try JSONDecoder().decode(ArtifactReplayPayload.self, from: data)
        #expect(decoded.artifacts[0].thresholdOcularKind == .blink)
        #expect(decoded.artifacts[0].thresholdOcularConfiguration == config)
        for method in [ArtifactCleaningMethod.obs, .sspPCA] {
            var artifact = decoded.artifacts[0]
            artifact.cleaningMethod = method
            let output = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [2])
            #expect(output.summaries.count == 1)
            #expect(output.signal.data[0][100] < row[100] * 0.5, "\(method.rawValue) should reduce the injected peak")
            #expect(output.signal.data[2] == signal.data[2], "Excluded channels must remain untouched")
            #expect(output.signal.data[0][0] == row[0])

            var rederived = decoded.artifacts(rederivedAgainst: signal)[0]
            rederived.cleaningMethod = method
            rederived.windowSizeSeconds = 0.7
            var withoutAverage = rederived
            withoutAverage.average = nil
            let replayed = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [rederived], excluding: [2])
            let direct = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [withoutAverage], excluding: [2])
            #expect(replayed.signal.data == direct.signal.data,
                    "A replay-derived average must not override an edited threshold window")
        }
    }
}
