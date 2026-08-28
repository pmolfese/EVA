//
//  WaveformScaleUnits.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Converts EVA's internal display scales into the physical units the rest of the
//  EEG world speaks: µV/mm and mm/sec.
//
//  ## What the internal numbers actually mean
//
//  Neither scale was named in a unit, which is why they were hard to describe.
//
//  - `amplitudeScale` is **the number of µV that fill half a channel row**. The
//    renderers compute `pointsPerMicrovolt = (rowHeight × fraction) /
//    amplitudeScale`, so a *larger* value draws *smaller* traces. Bounds 1…5000,
//    on a log slider, default 100. The fraction is exactly 0.5 in the main
//    waveform and 0.42 in the panel plots — see `channelRowFraction`.
//  - `timeScale` is **points per display sample**, where display samples are
//    normalized to `displaySamplesPerSecond` regardless of the file's actual
//    sampling rate — `displaySampleStride` is `round(samplingRate / 200)`, so
//    `samplingRate / stride × timeScale` collapses to `200 × timeScale`. Default
//    1.
//
//  That normalization is **approximate, and less so than it looks**. The stride
//  is an integer, so `round(samplingRate / 200)` only lands on 200 display
//  samples/sec when the rate is a multiple of 200: exact at 1000 and 2000 Hz,
//  +25% at 250 and 500 Hz, −15% at 512 Hz, +2.4% at 1024 Hz. A unitless "1.0×"
//  promised nothing and so this never mattered; a readout in mm/s does promise
//  something, so every conversion here takes the sampling rate and uses the real
//  stride. Do not reintroduce a rate-free sweep conversion.
//
//  At the defaults this works out to roughly 8.1 µV/mm and 71 mm/sec — close
//  enough to the clinical conventions (7 µV/mm, 30 mm/sec) that exposing the
//  units is a labelling change rather than a rescaling.
//
//  ## Why "nominal" millimetres, and how honest to be about it
//
//  Converting points to millimetres needs the display's true physical size.
//  macOS reports that from EDID, which is wrong or absent on plenty of external
//  monitors and meaningless under projectors, VMs, and screen sharing. A µV/mm
//  readout derived from bad EDID would be stated with authority and be false,
//  which is worse than not showing one.
//
//  So this assumes the **nominal** 72 points per inch and says so in the UI.
//  `pointsPerMillimeter` is a parameter rather than a constant precisely so a
//  future per-display calibration can supply a measured value without any of the
//  conversions changing.
//
//  Exports are the opposite case and need no such hedge: a PDF point *is* 1/72
//  inch by definition, so a figure's stated sensitivity is exact when printed at
//  100%. See `FigureExport`.
//

import CoreGraphics
import Foundation

nonisolated enum WaveformScaleUnits {

    // MARK: - The constants the renderers actually use

    /// Fraction of a channel row's height that one polarity of a full-scale
    /// trace occupies in the **main waveform** (`WaveformPlot`) — exactly half.
    ///
    /// This is the one the toolbar's Scale slider governs, so it is the one the
    /// readout must use.
    static let channelRowFraction: CGFloat = 0.5

    /// Height of one channel row in the main waveform stack.
    ///
    /// Lives here rather than staying private to `WaveformView` because the
    /// trace-overflow preference has to express its headroom as a multiple of
    /// full scale ("1.8×"), and full scale is `channelRowHeight *
    /// channelRowFraction`. A second copy of `70` in the preferences panel
    /// would silently start lying the day this one moved.
    static let channelRowHeight: CGFloat = 70

    /// Points from a row's midline to a full-scale trace peak: the denominator
    /// of the overflow multiplier.
    static var fullScaleHalfHeight: CGFloat { channelRowHeight * channelRowFraction }

    /// Overflow headroom (points, one side) expressed as a multiple of a
    /// full-scale excursion — the unit the preference slider reads out in,
    /// because "63 pt" means nothing to the eye and "1.8×" does.
    static func overflowMultiplier(forHeadroom headroom: CGFloat) -> CGFloat {
        guard fullScaleHalfHeight > 0 else { return 1 }
        return (fullScaleHalfHeight + max(headroom, 0)) / fullScaleHalfHeight
    }

    /// Inverse of `overflowMultiplier(forHeadroom:)`.
    static func headroom(forOverflowMultiplier multiplier: CGFloat) -> CGFloat {
        max(multiplier - 1, 0) * fullScaleHalfHeight
    }

    /// The same fraction for the **panel** plots — butterfly, overlaid category,
    /// single-trial. Slightly under a half so full-scale traces do not butt
    /// against the panel edges.
    ///
    /// That these differ is not an oversight to unify: the main waveform stacks
    /// rows that must not collide, while a panel plot owns its whole box. But it
    /// does mean a figure exported from a panel is drawn at a different
    /// sensitivity than the same `amplitudeScale` in the main view, which is
    /// exactly why the figure caption computes its own rather than reusing the
    /// toolbar's.
    ///
    /// The single source for both: `WaveformPlotViews` multiplies its heights by
    /// these, and the readout would silently start lying if they drifted apart.
    /// `WaveformScaleUnitsTests` pins the relationship.
    static let traceRowFraction: CGFloat = 0.42

    /// Display samples per second after decimation, held constant across
    /// sampling rates by `WaveformView.displaySampleStride`.
    static let displaySamplesPerSecond: Double = 200

    /// Nominal typographic points per inch. Points are physical only by
    /// convention here — see the file header.
    static let nominalPointsPerInch: Double = 72
    static let millimetersPerInch: Double = 25.4

    /// Nominal points per millimetre, ≈2.835.
    static let nominalPointsPerMillimeter = nominalPointsPerInch / millimetersPerInch

    // MARK: - Clinical conventions

    /// Standard clinical review sensitivity, µV per millimetre.
    static let clinicalMicrovoltsPerMillimeter: Double = 7
    /// Standard clinical paper speed, millimetres per second.
    static let clinicalMillimetersPerSecond: Double = 30

    // MARK: - Amplitude

    /// Points of vertical deflection per microvolt — the renderers' own formula.
    static func pointsPerMicrovolt(
        amplitudeScale: Double,
        rowHeight: CGFloat,
        fraction: CGFloat = channelRowFraction
    ) -> Double {
        let usable = Double(rowHeight * fraction)
        return usable / max(amplitudeScale, 1)
    }

    /// Sensitivity, in the conventional µV-per-millimetre form.
    ///
    /// Note the inversion: a *higher* µV/mm means a *less* sensitive display, and
    /// tracks `amplitudeScale` directly rather than inversely.
    static func microvoltsPerMillimeter(
        amplitudeScale: Double,
        rowHeight: CGFloat,
        fraction: CGFloat = channelRowFraction,
        pointsPerMillimeter: Double = nominalPointsPerMillimeter
    ) -> Double {
        let perMicrovolt = pointsPerMicrovolt(
            amplitudeScale: amplitudeScale, rowHeight: rowHeight, fraction: fraction
        )
        guard perMicrovolt > 0 else { return 0 }
        return pointsPerMillimeter / perMicrovolt
    }

    /// The `amplitudeScale` that produces a wanted sensitivity. Inverse of
    /// `microvoltsPerMillimeter`, so round-tripping either way is lossless.
    static func amplitudeScale(
        forMicrovoltsPerMillimeter target: Double,
        rowHeight: CGFloat,
        fraction: CGFloat = channelRowFraction,
        pointsPerMillimeter: Double = nominalPointsPerMillimeter
    ) -> Double {
        guard target > 0, pointsPerMillimeter > 0 else { return 1 }
        let usable = Double(rowHeight * fraction)
        return usable * target / pointsPerMillimeter
    }

    // MARK: - Time

    /// Decimation stride the waveform renders at — the authority for it, used
    /// by `WaveformView.displaySampleStride` so the readout cannot drift from
    /// the drawing.
    static func displaySampleStride(samplingRate: Double) -> Int {
        guard samplingRate > 0 else { return 5 }
        return max(Int((samplingRate / displaySamplesPerSecond).rounded()), 1)
    }

    /// Horizontal points per second of signal, for a file at `samplingRate`.
    ///
    /// **The stride is an integer, and that is not a rounding detail.** The
    /// intent is 200 display samples per second at any sampling rate, but
    /// `round(samplingRate / 200)` can only hit it when the rate is a multiple
    /// of 200. It is exact at 1000 and 2000 Hz and wrong elsewhere — +25% at 250
    /// and 500 Hz, −15% at 512 Hz, +2.4% at 1024 Hz — which covers most of the
    /// rates EEG actually ships at.
    ///
    /// Harmless while the control read "1.0×", because a unitless multiplier
    /// promises nothing. It stops being harmless the moment the readout claims a
    /// speed in millimetres per second, so every physical-unit conversion takes
    /// the sampling rate and uses the real stride rather than the nominal 200.
    static func pointsPerSecond(timeScale: Double, samplingRate: Double) -> Double {
        let stride = Double(displaySampleStride(samplingRate: samplingRate))
        guard stride > 0, samplingRate > 0 else { return displaySamplesPerSecond * timeScale }
        return samplingRate / stride * timeScale
    }

    /// Sweep speed, in the conventional millimetres-per-second form.
    static func millimetersPerSecond(
        timeScale: Double,
        samplingRate: Double,
        pointsPerMillimeter: Double = nominalPointsPerMillimeter
    ) -> Double {
        guard pointsPerMillimeter > 0 else { return 0 }
        return pointsPerSecond(timeScale: timeScale, samplingRate: samplingRate) / pointsPerMillimeter
    }

    /// The `timeScale` that produces a wanted sweep speed on this file.
    static func timeScale(
        forMillimetersPerSecond target: Double,
        samplingRate: Double,
        pointsPerMillimeter: Double = nominalPointsPerMillimeter
    ) -> Double {
        let perScale = pointsPerSecond(timeScale: 1, samplingRate: samplingRate)
        guard perScale > 0 else { return 1 }
        return target * pointsPerMillimeter / perScale
    }

    // MARK: - Arbitrary geometry

    /// Sensitivity for a plot of known height that is not a channel row — the
    /// butterfly and single-trial figures, which size their traces from the whole
    /// panel rather than from `channelRowHeight`.
    static func microvoltsPerMillimeter(
        amplitudeScale: Double,
        plotHeight: CGFloat,
        pointsPerMillimeter: Double = nominalPointsPerMillimeter
    ) -> Double {
        microvoltsPerMillimeter(
            amplitudeScale: amplitudeScale,
            rowHeight: plotHeight,
            fraction: traceRowFraction,
            pointsPerMillimeter: pointsPerMillimeter
        )
    }

    /// Sweep speed for a plot that fits a known duration into a known width —
    /// how every epoch figure is laid out, since those do not use `timeScale`.
    static func millimetersPerSecond(
        plotWidth: CGFloat,
        seconds: Double,
        pointsPerMillimeter: Double = nominalPointsPerMillimeter
    ) -> Double {
        guard seconds > 0, pointsPerMillimeter > 0 else { return 0 }
        return (Double(plotWidth) / seconds) / pointsPerMillimeter
    }

    // MARK: - Formatting

    /// Two significant-ish digits below 10, none above — "9.6 µV/mm", "71 mm/s".
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }

    static func sensitivityLabel(
        amplitudeScale: Double,
        rowHeight: CGFloat,
        fraction: CGFloat = channelRowFraction,
        pointsPerMillimeter: Double = nominalPointsPerMillimeter
    ) -> String {
        let value = microvoltsPerMillimeter(
            amplitudeScale: amplitudeScale,
            rowHeight: rowHeight,
            fraction: fraction,
            pointsPerMillimeter: pointsPerMillimeter
        )
        return "\(format(value)) µV/mm"
    }

    static func sweepLabel(
        timeScale: Double,
        samplingRate: Double,
        pointsPerMillimeter: Double = nominalPointsPerMillimeter
    ) -> String {
        let value = millimetersPerSecond(
            timeScale: timeScale,
            samplingRate: samplingRate,
            pointsPerMillimeter: pointsPerMillimeter
        )
        return "\(format(value)) mm/s"
    }
}
