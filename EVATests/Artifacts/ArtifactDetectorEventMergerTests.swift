//
//  ArtifactDetectorEventMergerTests.swift
//  EVATests
//

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
