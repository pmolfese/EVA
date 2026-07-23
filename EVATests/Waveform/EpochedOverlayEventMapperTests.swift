//
//  EpochedOverlayEventMapperTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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
