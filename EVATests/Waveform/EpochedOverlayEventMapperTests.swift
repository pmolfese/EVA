//
//  EpochedOverlayEventMapperTests.swift
//  EVATests
//

import Testing
@testable import EVA

struct EpochedOverlayEventMapperTests {
    private let segment = EpochSegment(
        startSample: 0,
        endSample: 99,
        stimulusOffsetSamples: 0,
        category: "Trial",
        sourceCode: "stim",
        sourceTimeSeconds: 10,
        colorIndex: 0,
        contributingEpochCount: 1
    )

    @Test func overlappingArtifactWhoseCenterPrecedesEpochGetsBoundaryFlag() throws {
        let event = MFFEvent(
            id: "artifact-before",
            code: "ART",
            beginTimeSeconds: 9.9,
            rawBeginTime: "",
            sourceFile: "Template 80%",
            durationSeconds: 0.4
        )

        let mapped = try #require(EpochedOverlayEventMapper.map(
            event,
            into: segment,
            samplingRate: 100,
            overlapWindowSeconds: 0.4
        ))

        #expect(mapped.beginTimeSeconds == 0)
        #expect(mapped.durationSeconds == event.durationSeconds)
    }

    @Test func instantaneousMarkerBeforeEpochIsNotMapped() {
        let event = MFFEvent(
            id: "marker-before",
            code: "MARK",
            beginTimeSeconds: 9.9,
            rawBeginTime: "",
            sourceFile: "User Markers"
        )

        #expect(EpochedOverlayEventMapper.map(
            event,
            into: segment,
            samplingRate: 100
        ) == nil)
    }

    @Test func markerInsideEpochKeepsRelativePosition() throws {
        let event = MFFEvent(
            id: "marker-inside",
            code: "MARK",
            beginTimeSeconds: 10.25,
            rawBeginTime: "",
            sourceFile: "User Markers"
        )

        let mapped = try #require(EpochedOverlayEventMapper.map(
            event,
            into: segment,
            samplingRate: 100
        ))

        #expect(mapped.beginTimeSeconds == 0.25)
    }
}
