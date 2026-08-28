//
//  TopomapFieldRasterTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Resizing the Averages workspace's Topography pane used to stutter badly,
//  because TopomapView re-ran its inverse-distance-weighted field interpolation
//  over the whole canvas on every pixel of the drag. The fix renders that field
//  once into a fixed-resolution bitmap and scales it thereafter; these tests
//  cover the bitmap generation itself, not the on-screen resizing.
//

import Testing
import Foundation
import CoreGraphics
@testable import EVA

struct TopomapFieldRasterTests {

    private func layout(_ positions: [(Int, Double, Double)]) -> SensorLayout {
        SensorLayout(
            name: "test",
            positions: positions.map { SensorPosition(channelIndex: $0.0, x: $0.1, y: $0.2) }
        )
    }

    @Test func rendersAtTheDeclaredFixedResolutionRegardlessOfViewSize() throws {
        // The whole point of the cache: the raster's size is a constant, not a
        // function of whatever the pane happens to be at the moment.
        let view = TopomapView(
            layout: layout([(0, 0, 0.5), (1, -0.4, -0.3), (2, 0.4, -0.3)]),
            values: [1.0, -1.0, 0.5],
            timeSeconds: 0,
            fixedScale: nil
        )
        let image = try #require(view.renderFieldImage())
        #expect(image.width == TopomapView.fieldRasterResolution)
        #expect(image.height == TopomapView.fieldRasterResolution)
    }

    @Test func returnsNilWithNoActiveSensors() {
        let view = TopomapView(
            layout: layout([]),
            values: [],
            timeSeconds: 0,
            fixedScale: nil
        )
        #expect(view.renderFieldImage() == nil)
    }

    @Test func returnsNilWhenNoSensorHasAMatchingValue() {
        // Positions reference channel indices past the end of `values`, so
        // `activeSensors` is non-empty but every lookup misses.
        let view = TopomapView(
            layout: layout([(5, 0, 0.5), (6, -0.4, -0.3)]),
            values: [1.0, 2.0],
            timeSeconds: 0,
            fixedScale: nil
        )
        #expect(view.renderFieldImage() == nil)
    }

    @Test func isDeterministicForIdenticalInputs() throws {
        // Not identity-cached at this layer (that happens in the view's
        // @State) -- but two independent renders of the same data must produce
        // pixel-identical images, since the SwiftUI cache's correctness depends
        // on the function being pure.
        let view = TopomapView(
            layout: layout([(0, 0.1, 0.6), (1, -0.5, -0.2), (2, 0.5, -0.2), (3, 0, -0.6)]),
            values: [2.0, -1.5, 0.3, -0.8],
            timeSeconds: 0,
            fixedScale: 4.0
        )
        let first = try #require(view.renderFieldImage())
        let second = try #require(view.renderFieldImage())

        let firstData = try #require(first.dataProvider?.data)
        let secondData = try #require(second.dataProvider?.data)
        #expect((firstData as Data) == (secondData as Data))
    }

    @Test func differentValuesProduceDifferentPixels() throws {
        let base = layout([(0, 0, 0.6), (1, -0.5, -0.3), (2, 0.5, -0.3)])
        let a = TopomapView(layout: base, values: [1.0, 1.0, 1.0], timeSeconds: 0, fixedScale: 2.0)
        let b = TopomapView(layout: base, values: [-1.0, -1.0, -1.0], timeSeconds: 0, fixedScale: 2.0)

        let imageA = try #require(a.renderFieldImage())
        let imageB = try #require(b.renderFieldImage())
        let dataA = try #require(imageA.dataProvider?.data) as Data
        let dataB = try #require(imageB.dataProvider?.data) as Data

        #expect(dataA != dataB)
    }

    @Test func theHeadCircleIsOpaqueAndTheCornersAreTransparent() throws {
        // A visual sanity check cheaper than decoding actual colours: pixels
        // near the raster's centre (inside the head disc) should be filled,
        // and pixels in a corner (outside the disc, never touched by the fill
        // loop) should carry zero alpha from the initial `clear`.
        let view = TopomapView(
            layout: layout([(0, 0, 0.5), (1, -0.4, -0.3), (2, 0.4, -0.3)]),
            values: [1.0, -1.0, 0.5],
            timeSeconds: 0,
            fixedScale: nil
        )
        let image = try #require(view.renderFieldImage())
        let data = try #require(image.dataProvider?.data) as Data
        let bytesPerPixel = 4
        let resolution = TopomapView.fieldRasterResolution

        func alpha(x: Int, y: Int) -> UInt8 {
            let offset = (y * resolution + x) * bytesPerPixel
            return data[data.startIndex + offset + 3]
        }

        #expect(alpha(x: resolution / 2, y: resolution / 2) == 255)
        #expect(alpha(x: 0, y: 0) == 0)
    }
}
