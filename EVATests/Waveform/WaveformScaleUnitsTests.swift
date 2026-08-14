//
//  WaveformScaleUnitsTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The failure mode worth guarding: the readout drifting away from what is drawn.
//
//  A µV/mm figure is only worth showing if it is the sensitivity actually on
//  screen, and nothing about a wrong one looks wrong — it is a plausible number
//  in the right units. So the first test restates the renderers' own arithmetic
//  independently and checks the conversion agrees, rather than calling the
//  conversion twice and confirming it equals itself.
//

import Testing
import Foundation
import CoreGraphics
@testable import EVA

struct WaveformScaleUnitsTests {

    /// The main waveform's row height, from `WaveformView.channelRowHeight`.
    private let rowHeight: CGFloat = 70

    // MARK: - Agreement with the renderers

    /// `WaveformPlot` draws at `(nominalHeight × channelRowFraction) /
    /// amplitudeScale` points per µV. Written out longhand here so a change to
    /// either constant fails this rather than silently re-labelling the display.
    @Test("Points per microvolt matches the renderer's own formula")
    func pointsPerMicrovoltMatchesRenderer() {
        let amplitudeScale = 100.0
        let expected = Double(rowHeight * 0.5) / amplitudeScale
        let actual = WaveformScaleUnits.pointsPerMicrovolt(
            amplitudeScale: amplitudeScale, rowHeight: rowHeight
        )
        #expect(abs(actual - expected) < 1e-12)
        #expect(WaveformScaleUnits.channelRowFraction == 0.5)
        #expect(WaveformScaleUnits.traceRowFraction == 0.42)
    }

    /// The conversion must use the file's **real** stride, not the nominal 200.
    ///
    /// The decimation aims for 200 display samples/sec at any rate, but the
    /// stride is an integer, so `round(samplingRate / 200)` only lands on it for
    /// multiples of 200. This test exists because the first version of the
    /// conversion assumed the normalization was exact and would have mis-stated
    /// the sweep speed by up to 25% on the rates EEG most commonly uses.
    @Test("Points per second follows the real integer stride, not the nominal rate")
    func sweepFollowsTheRealStride() {
        for samplingRate in [250.0, 500.0, 512.0, 1000.0, 1024.0, 2000.0] {
            let stride = Double(max(Int((samplingRate / 200).rounded()), 1))
            let expected = samplingRate / stride
            let actual = WaveformScaleUnits.pointsPerSecond(timeScale: 1, samplingRate: samplingRate)
            #expect(abs(actual - expected) < 1e-9, "\(samplingRate) Hz")
        }
    }

    /// The deviation is real and worth pinning, so nobody "simplifies" the
    /// conversion back to a rate-free constant.
    @Test("Rates that are not multiples of 200 really do sweep differently")
    func nonMultipleRatesDeviate() {
        let at1000 = WaveformScaleUnits.pointsPerSecond(timeScale: 1, samplingRate: 1000)
        let at250 = WaveformScaleUnits.pointsPerSecond(timeScale: 1, samplingRate: 250)
        #expect(at1000 == 200)
        #expect(at250 == 250)
        #expect(at250 != at1000)
    }

    // MARK: - The documented defaults

    /// The numbers quoted in `WaveformScaleUnits`' header and in the design
    /// discussion. If these move, the prose is stale.
    @Test("EVA's defaults are ~8.1 µV/mm and ~71 mm/s at 1000 Hz")
    func defaultsMatchTheDocumentedFigures() {
        let sensitivity = WaveformScaleUnits.microvoltsPerMillimeter(
            amplitudeScale: 100, rowHeight: rowHeight
        )
        let sweep = WaveformScaleUnits.millimetersPerSecond(timeScale: 1, samplingRate: 1000)
        #expect(abs(sensitivity - 8.1) < 0.05)
        #expect(abs(sweep - 70.6) < 0.1)
    }

    @Test("Nominal points per millimetre is 72/25.4")
    func nominalConversion() {
        #expect(abs(WaveformScaleUnits.nominalPointsPerMillimeter - 2.8346) < 0.001)
    }

    // MARK: - Round trips

    @Test("Sensitivity round-trips through amplitudeScale")
    func sensitivityRoundTrips() {
        for target in [1.0, 7.0, 8.1, 50.0, 200.0] {
            let scale = WaveformScaleUnits.amplitudeScale(
                forMicrovoltsPerMillimeter: target, rowHeight: rowHeight
            )
            let back = WaveformScaleUnits.microvoltsPerMillimeter(
                amplitudeScale: scale, rowHeight: rowHeight
            )
            #expect(abs(back - target) < 1e-9, "µV/mm \(target) did not round-trip")
        }
    }

    @Test("Sweep speed round-trips through timeScale")
    func sweepRoundTrips() {
        // Every rate, including the ones whose stride does not divide evenly —
        // typing 30 mm/s must give 30 mm/s on the file in front of you.
        for samplingRate in [250.0, 512.0, 1000.0, 1024.0] {
            for target in [15.0, 30.0, 70.6, 120.0] {
                let scale = WaveformScaleUnits.timeScale(
                    forMillimetersPerSecond: target, samplingRate: samplingRate
                )
                let back = WaveformScaleUnits.millimetersPerSecond(
                    timeScale: scale, samplingRate: samplingRate
                )
                #expect(abs(back - target) < 1e-9, "mm/s \(target) at \(samplingRate) Hz")
            }
        }
    }

    /// A calibrated display must not require any other change. This is the whole
    /// reason `pointsPerMillimeter` is a parameter rather than a constant.
    @Test("A calibrated points-per-millimetre flows through both conversions")
    func calibrationIsASingleParameter() {
        // A 2× denser display: the same pixels cover half the millimetres, so
        // the same settings are twice as many µV per mm and twice as fast.
        let dense = WaveformScaleUnits.nominalPointsPerMillimeter * 2
        let nominalSensitivity = WaveformScaleUnits.microvoltsPerMillimeter(
            amplitudeScale: 100, rowHeight: rowHeight
        )
        let denseSensitivity = WaveformScaleUnits.microvoltsPerMillimeter(
            amplitudeScale: 100, rowHeight: rowHeight, pointsPerMillimeter: dense
        )
        #expect(abs(denseSensitivity - nominalSensitivity * 2) < 1e-9)

        let denseSweep = WaveformScaleUnits.millimetersPerSecond(
            timeScale: 1, samplingRate: 1000, pointsPerMillimeter: dense
        )
        let nominalSweep = WaveformScaleUnits.millimetersPerSecond(timeScale: 1, samplingRate: 1000)
        #expect(abs(denseSweep - nominalSweep / 2) < 1e-9)
    }

    // MARK: - Degenerate input

    @Test("Zero and negative inputs degrade rather than producing infinities")
    func degenerateInputsAreSafe() {
        #expect(WaveformScaleUnits.microvoltsPerMillimeter(amplitudeScale: 100, rowHeight: 0) == 0)
        #expect(WaveformScaleUnits.millimetersPerSecond(plotWidth: 820, seconds: 0) == 0)
        #expect(WaveformScaleUnits.displaySampleStride(samplingRate: 0) == 5)
        #expect(WaveformScaleUnits.displaySampleStride(samplingRate: 10) == 1)
        #expect(WaveformScaleUnits.amplitudeScale(forMicrovoltsPerMillimeter: 0, rowHeight: rowHeight) == 1)
        #expect(WaveformScaleUnits.format(.nan) == "—")
        #expect(WaveformScaleUnits.format(.infinity) == "—")
    }

    // MARK: - Figure captions

    /// Panel plots use `traceRowFraction`, not the main waveform's half, so a
    /// figure's caption must not reuse the toolbar's number.
    @Test("Figure scale uses the panel fraction, not the channel-row fraction")
    func figureScaleUsesPanelGeometry() {
        let size = CGSize(width: 820, height: 300)
        let scale = FigureScale(amplitudeScale: 100, plotSize: size, seconds: 0.7)

        let expected = WaveformScaleUnits.nominalPointsPerMillimeter
            / (Double(size.height * 0.42) / 100)
        #expect(abs(scale.microvoltsPerMillimeter - expected) < 1e-9)

        // 820 pt over 0.7 s, converted to mm.
        let expectedSweep = (820.0 / 0.7) / WaveformScaleUnits.nominalPointsPerMillimeter
        #expect(abs((scale.millimetersPerSecond ?? 0) - expectedSweep) < 1e-9)
        #expect(scale.caption.contains("µV/mm"))
        #expect(scale.caption.contains("mm/s"))
    }

    @Test("A figure with no duration states sensitivity alone")
    func figureWithoutDurationOmitsSweep() {
        let scale = FigureScale(
            amplitudeScale: 100, plotSize: CGSize(width: 900, height: 330), seconds: nil
        )
        #expect(scale.millimetersPerSecond == nil)
        #expect(scale.caption.contains("µV/mm"))
        #expect(!scale.caption.contains("mm/s"))
    }

    /// Raster exports render at 2× and must declare it, or every viewer places
    /// them at 72 dpi and doubles the physical size — which would silently halve
    /// the sensitivity printed in the caption.
    @Test("Raster exports declare 144 dpi")
    func rasterDeclaresItsResolution() {
        #expect(FigureExporter.rasterDPI == 144)
    }

    // MARK: - Settings defaults

    /// The stored defaults must reproduce EVA's historical starting point, or
    /// everyone who never opens the panel silently gets a different view than
    /// they had before the preference existed.
    @Test("The shipped defaults reproduce amplitudeScale 100 and timeScale 1")
    func shippedDefaultsMatchTheOldBehaviour() {
        let amplitude = WaveformScaleUnits.amplitudeScale(
            forMicrovoltsPerMillimeter: EVAGeneralPreferences.defaultSensitivity,
            rowHeight: rowHeight
        )
        #expect(abs(amplitude - 100) < 0.7)

        let time = WaveformScaleUnits.timeScale(
            forMillimetersPerSecond: EVAGeneralPreferences.defaultSweep,
            samplingRate: 1000
        )
        #expect(abs(time - 1) < 0.005)
    }

    /// The reason the preference is stored in mm/s rather than as a `timeScale`:
    /// one stored `timeScale` would mean different physical speeds per file.
    @Test("A stored sweep preference gives the same physical speed at every rate")
    func sweepPreferenceIsPortableAcrossRates() {
        let preferred = 30.0
        for samplingRate in [250.0, 500.0, 512.0, 1000.0, 1024.0, 2000.0] {
            let time = WaveformScaleUnits.timeScale(
                forMillimetersPerSecond: preferred, samplingRate: samplingRate
            )
            let actual = WaveformScaleUnits.millimetersPerSecond(
                timeScale: time, samplingRate: samplingRate
            )
            #expect(abs(actual - preferred) < 1e-9, "\(samplingRate) Hz")
        }

        // And the raw scales genuinely differ, which is the whole point.
        let at250 = WaveformScaleUnits.timeScale(forMillimetersPerSecond: preferred, samplingRate: 250)
        let at1000 = WaveformScaleUnits.timeScale(forMillimetersPerSecond: preferred, samplingRate: 1000)
        #expect(at250 != at1000)
    }

    /// Both preset buttons must land inside the toolbar sliders' ranges, or the
    /// seeded value is clamped and the panel lies about what you will get.
    @Test("Both settings presets are reachable by the toolbar sliders")
    func presetsAreReachable() {
        for sensitivity in [WaveformScaleUnits.clinicalMicrovoltsPerMillimeter,
                            EVAGeneralPreferences.defaultSensitivity] {
            let scale = WaveformScaleUnits.amplitudeScale(
                forMicrovoltsPerMillimeter: sensitivity, rowHeight: rowHeight
            )
            #expect(scale >= 1 && scale <= 5000, "µV/mm \(sensitivity)")
        }
        for sweep in [WaveformScaleUnits.clinicalMillimetersPerSecond,
                      EVAGeneralPreferences.defaultSweep] {
            let scale = WaveformScaleUnits.timeScale(
                forMillimetersPerSecond: sweep, samplingRate: 1000
            )
            #expect(scale >= 0.2 && scale <= 8, "mm/s \(sweep)")
        }
    }

    // MARK: - Clinical preset

    @Test("The clinical preset lands on 7 µV/mm and 30 mm/s")
    func clinicalPresetIsExact() {
        let scale = WaveformScaleUnits.amplitudeScale(
            forMicrovoltsPerMillimeter: WaveformScaleUnits.clinicalMicrovoltsPerMillimeter,
            rowHeight: rowHeight
        )
        // Inside the slider's 1…5000 range, so the preset is reachable rather
        // than being silently clamped.
        #expect(scale > 1 && scale < 5000)
        #expect(abs(
            WaveformScaleUnits.microvoltsPerMillimeter(amplitudeScale: scale, rowHeight: rowHeight) - 7
        ) < 1e-9)

        let time = WaveformScaleUnits.timeScale(
            forMillimetersPerSecond: WaveformScaleUnits.clinicalMillimetersPerSecond,
            samplingRate: 1000
        )
        #expect(time > 0.2 && time < 8)
        #expect(abs(
            WaveformScaleUnits.millimetersPerSecond(timeScale: time, samplingRate: 1000) - 30
        ) < 1e-9)
    }
}
