//
//  EventTrackIndexTests.swift
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

import XCTest
@testable import EVA

final class EventTrackIndexTests: XCTestCase {
    func testVisibleMarkersUseInclusiveBinarySearchBounds() {
        let events = [
            event(id: "a", seconds: 0),
            event(id: "b", seconds: 1),
            event(id: "c", seconds: 2),
            event(id: "d", seconds: 3)
        ]
        let index = EventTrackIndex(
            events: events,
            samplingRate: 10,
            timeScale: 2,
            sampleStride: 1,
            laneCount: 1
        )

        let visible = index.visibleMarkers(in: 20...40)

        XCTAssertEqual(visible.map(\.event.id), ["b", "c"])
    }

    func testDenseThresholdSuppressesSwiftUIFlagsForMarkerFloods() {
        XCTAssertTrue(EventTrackView.drawsEventFlags(visibleMarkerCount: EventTrackView.denseMarkerThreshold))
        XCTAssertFalse(EventTrackView.drawsEventFlags(visibleMarkerCount: EventTrackView.denseMarkerThreshold + 1))
    }

    private func event(id: String, seconds: Double) -> MFFEvent {
        MFFEvent(
            id: id,
            code: id.uppercased(),
            beginTimeSeconds: seconds,
            rawBeginTime: "",
            sourceFile: "test.vmrk"
        )
    }
}
