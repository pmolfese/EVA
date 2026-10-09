//
//  WaveformDensityLayoutTests.swift
//  EVATests
//
//  Display density must change row geometry without silently changing the
//  physical sensitivity stated beside the scale control.
//

import CoreGraphics
import Testing
@testable import EVA

struct WaveformDensityLayoutTests {

    @Test("Fit keeps EVA's established row geometry")
    func fitKeepsEstablishedGeometry() {
        let geometry = WaveformDensityLayout.geometry(
            mode: .fit,
            viewportHeight: 720
        )

        #expect(geometry.rowHeight == WaveformScaleUnits.channelRowHeight)
        #expect(geometry.rowSpacing == 12)
        #expect(geometry.channelsPerScreen == 8)
    }

    @Test("Fit count follows the available EEG viewport")
    func fitCountFollowsViewport() {
        let short = WaveformDensityLayout.geometry(mode: .fit, viewportHeight: 400)
        let tall = WaveformDensityLayout.geometry(mode: .fit, viewportHeight: 900)

        #expect(short.channelsPerScreen == 5)
        #expect(tall.channelsPerScreen == 11)
        #expect(tall.channelsPerScreen > short.channelsPerScreen)
    }

    @Test("Fixed density fits the requested channel count")
    func fixedDensityFillsViewport() {
        for viewportHeight: CGFloat in [420, 720, 1_080] {
            for count in [16, 32, 64] {
                let geometry = WaveformDensityLayout.geometry(
                    mode: .fixed(count),
                    viewportHeight: viewportHeight
                )
                let occupiedHeight = CGFloat(count) * geometry.rowHeight
                    + CGFloat(count - 1) * geometry.rowSpacing

                #expect(geometry.channelsPerScreen == count)
                #expect(abs(occupiedHeight - viewportHeight) < 1e-8)
            }
        }
    }

    @Test("Fixed density is bounded to one through 64 channels")
    func fixedDensityIsBounded() {
        let below = WaveformDensityLayout.geometry(mode: .fixed(-10), viewportHeight: 720)
        let above = WaveformDensityLayout.geometry(mode: .fixed(256), viewportHeight: 720)

        #expect(below.channelsPerScreen == 1)
        #expect(above.channelsPerScreen == 64)
    }

    @Test("Dense layouts yield spacing to the signal rows")
    func spacingCompressesAtHighDensity() {
        let roomy = WaveformDensityLayout.geometry(mode: .fixed(16), viewportHeight: 2_000)
        let dense = WaveformDensityLayout.geometry(mode: .fixed(64), viewportHeight: 420)

        #expect(roomy.rowSpacing == WaveformDensityLayout.fitRowSpacing)
        #expect(dense.rowSpacing < roomy.rowSpacing)
        #expect(dense.rowHeight >= WaveformDensityLayout.minimumRowHeight)
    }

    @Test("Changing density can preserve physical sensitivity")
    func densityPreservesPhysicalSensitivity() {
        let targetSensitivity = 7.0

        for mode in [
            WaveformDensityMode.fit,
            .fixed(16),
            .fixed(32),
            .fixed(64),
        ] {
            let geometry = WaveformDensityLayout.geometry(
                mode: mode,
                viewportHeight: 720
            )
            let amplitudeScale = WaveformScaleUnits.amplitudeScale(
                forMicrovoltsPerMillimeter: targetSensitivity,
                rowHeight: geometry.rowHeight
            )
            let displayedSensitivity = WaveformScaleUnits.microvoltsPerMillimeter(
                amplitudeScale: amplitudeScale,
                rowHeight: geometry.rowHeight
            )

            #expect(abs(displayedSensitivity - targetSensitivity) < 1e-9)
        }
    }

    @Test("A small display set caps rendering without replacing the requested density")
    func displaySetCapsEffectiveDensity() {
        let requested = WaveformDensityMode.fixed(64)
        let effective = WaveformDensityLayout.effectiveMode(
            requested,
            availableChannelCount: 28
        )

        #expect(effective == .fixed(28))
        #expect(requested == .fixed(64))
        #expect(WaveformDensityLayout.effectiveMode(.fit, availableChannelCount: 28) == .fit)
    }
}
