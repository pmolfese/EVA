//
//  MFFThumbnailRenderer.swift
//  MFFPreviewKit
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Draws the Finder thumbnail for an MFF package. Four looks, all built from the
//  same stack of waveform traces so the family reads as one set:
//
//    continuous    traces alone, densely stacked
//    segmented     traces over a row of opaque condition squares
//    averaged      traces under full-height opaque condition bands
//    grand average many faint subject traces with one bold mean drawn through
//
//  Colors are flat and opaque on a solid backing, never translucent: a thumbnail
//  composites onto whatever is behind it (a white list row, a dark sidebar, the
//  desktop), so alpha would make the same file look different in each place.
//

import CoreGraphics
import Foundation

nonisolated struct MFFThumbnailRenderer: Sendable {

    struct Palette: Sendable {
        let backing: CGColor
        let border: CGColor
        let trace: CGColor
        let faintTrace: CGColor
        let mean: CGColor
        let conditions: [CGColor]
        let rejected: CGColor

        static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> CGColor {
            CGColor(
                red: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        }

        static let light = Palette(
            backing: rgb(255, 255, 255),
            border: rgb(180, 178, 169),
            trace: rgb(127, 119, 221),
            faintTrace: rgb(175, 169, 236),
            mean: rgb(15, 110, 86),
            conditions: [rgb(187, 226, 214), rgb(195, 219, 245)],
            rejected: rgb(246, 201, 200)
        )

        static let dark = Palette(
            backing: rgb(28, 28, 30),
            border: rgb(90, 89, 84),
            trace: rgb(143, 135, 232),
            faintTrace: rgb(83, 74, 183),
            mean: rgb(93, 202, 165),
            conditions: [rgb(28, 67, 56), rgb(36, 61, 87)],
            rejected: rgb(87, 42, 43)
        )
    }

    /// Everything the drawing needs, so the renderer never touches the file.
    struct Model: Sendable {
        var fileType: MFFQuickLookSummary.FileType
        var conditionCount: Int
        var hasRejectedSegments: Bool

        init(
            fileType: MFFQuickLookSummary.FileType,
            conditionCount: Int = 3,
            hasRejectedSegments: Bool = false
        ) {
            self.fileType = fileType
            self.conditionCount = conditionCount
            self.hasRejectedSegments = hasRejectedSegments
        }

        init(summary: MFFQuickLookSummary) {
            fileType = summary.fileType
            if let segmented = summary.segmentedDetail {
                conditionCount = segmented.conditions.count
                hasRejectedSegments = segmented.rejected > 0
            } else if let averaged = summary.averagedDetail {
                conditionCount = averaged.conditions.count
                hasRejectedSegments = false
            } else {
                conditionCount = 0
                hasRejectedSegments = false
            }
        }
    }

    let model: Model
    let palette: Palette

    init(model: Model, palette: Palette = .light) {
        self.model = model
        self.palette = palette
    }

    // MARK: - Drawing

    /// Draws into `context` filling `size`. All geometry below is expressed in a
    /// 100x100 design space and scaled to fit.
    func draw(in context: CGContext, size: CGSize) {
        let side = min(size.width, size.height)
        let scale = side / 100

        context.saveGState()
        context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        context.scaleBy(x: scale, y: scale)
        // The design space below is y-down, matching how the icons were drawn as
        // SVG. CGContext is y-up, so flip once here rather than inverting every
        // coordinate.
        context.translateBy(x: 0, y: 100)
        context.scaleBy(x: 1, y: -1)

        let detail = Detail(forPixelSide: side)

        let bounds = CGRect(x: 2, y: 2, width: 96, height: 96)
        let backing = CGPath(
            roundedRect: bounds,
            cornerWidth: 13,
            cornerHeight: 13,
            transform: nil
        )
        context.addPath(backing)
        context.setFillColor(palette.backing)
        context.fillPath()

        context.saveGState()
        context.addPath(backing)
        context.clip()

        switch model.fileType {
        case .continuous:
            drawTraces(in: context, count: detail.denseTraceCount, top: 14, bottom: 88, width: detail.traceWidth, color: palette.trace, segments: detail.segmentsPerTrace)
        case .segmented:
            drawTraces(in: context, count: detail.sparseTraceCount, top: 16, bottom: 62, width: detail.traceWidth, color: palette.trace, segments: detail.segmentsPerTrace)
            drawConditionSquares(in: context, detail: detail)
        case .averaged:
            // Bands go down first and the traces ride on top: an opaque column
            // with the waveform drawn over it reads the same as a translucent
            // band, but never shifts color against the Finder background.
            drawConditionBands(in: context, detail: detail)
            drawTraces(in: context, count: detail.denseTraceCount, top: 14, bottom: 88, width: detail.traceWidth, color: palette.trace, segments: detail.segmentsPerTrace)
        case .grandAverage:
            drawConvergence(in: context, detail: detail)
        }

        context.restoreGState()

        context.addPath(backing)
        context.setStrokeColor(palette.border)
        context.setLineWidth(detail.borderWidth)
        context.strokePath()

        context.restoreGState()
    }

    /// Feature counts and stroke weights thin out as the icon shrinks, so a 32pt
    /// thumbnail stays legible instead of turning to mud.
    private struct Detail {
        let denseTraceCount: Int
        let sparseTraceCount: Int
        let bandCount: Int
        let squareCount: Int
        let traceWidth: CGFloat
        let borderWidth: CGFloat
        let segmentsPerTrace: Int

        init(forPixelSide side: CGFloat) {
            if side >= 128 {
                denseTraceCount = 5
                sparseTraceCount = 3
                bandCount = 4
                squareCount = 4
                traceWidth = 2
                borderWidth = 1
                segmentsPerTrace = 16
            } else if side >= 64 {
                denseTraceCount = 4
                sparseTraceCount = 2
                bandCount = 3
                squareCount = 4
                traceWidth = 2.6
                borderWidth = 1.6
                segmentsPerTrace = 12
            } else {
                denseTraceCount = 3
                sparseTraceCount = 2
                bandCount = 3
                squareCount = 3
                traceWidth = 6
                borderWidth = 3
                segmentsPerTrace = 6
            }
        }
    }

    // MARK: - Traces

    private func drawTraces(
        in context: CGContext,
        count: Int,
        top: CGFloat,
        bottom: CGFloat,
        width: CGFloat,
        color: CGColor,
        segments: Int,
        amplitude: CGFloat = 4.5,
        seed: UInt64 = 0x5EED
    ) {
        guard count > 0 else { return }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let spacing = count > 1 ? (bottom - top) / CGFloat(count - 1) : 0
        var generator = SplitMix64(seed: seed)
        for index in 0 ..< count {
            let baseline = count > 1 ? top + spacing * CGFloat(index) : (top + bottom) / 2
            context.addPath(
                tracePath(
                    baseline: baseline,
                    amplitude: amplitude,
                    segments: segments,
                    generator: &generator
                )
            )
            context.strokePath()
        }
    }

    private func tracePath(
        baseline: CGFloat,
        amplitude: CGFloat,
        segments: Int,
        generator: inout SplitMix64
    ) -> CGPath {
        let path = CGMutablePath()
        let startX: CGFloat = 9
        let endX: CGFloat = 91
        let step = (endX - startX) / CGFloat(segments)
        path.move(to: CGPoint(x: startX, y: baseline))
        var y = baseline
        for index in 1 ... segments {
            // Pull back toward the baseline so a trace never wanders into its
            // neighbour, which is what makes the stack read as parallel channels.
            let drift = (y - baseline) * 0.45
            y += generator.symmetric(amplitude) - drift
            path.addLine(to: CGPoint(x: startX + step * CGFloat(index), y: y))
        }
        return path
    }

    // MARK: - Segmented

    private func drawConditionSquares(in context: CGContext, detail: Detail) {
        let count = detail.squareCount
        let inset: CGFloat = 11
        let gap: CGFloat = 3
        let available = 100 - inset * 2 - gap * CGFloat(count - 1)
        let width = available / CGFloat(count)
        let height: CGFloat = detail.squareCount > 3 ? 15 : 18
        let top: CGFloat = 100 - 11 - height

        for index in 0 ..< count {
            let isLast = index == count - 1
            let color = (model.hasRejectedSegments && isLast)
                ? palette.rejected
                : palette.conditions[index % palette.conditions.count]
            let rect = CGRect(
                x: inset + (width + gap) * CGFloat(index),
                y: top,
                width: width,
                height: height
            )
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.setFillColor(color)
            context.fillPath()
        }
    }

    // MARK: - Averaged

    private func drawConditionBands(in context: CGContext, detail: Detail) {
        let count = detail.bandCount
        let inset: CGFloat = 9
        let gap: CGFloat = 2
        let available = 100 - inset * 2 - gap * CGFloat(count - 1)
        let width = available / CGFloat(count)

        for index in 0 ..< count {
            let isLast = index == count - 1
            let color = isLast
                ? palette.rejected
                : palette.conditions[index % palette.conditions.count]
            let rect = CGRect(
                x: inset + (width + gap) * CGFloat(index),
                y: 4,
                width: width,
                height: 92
            )
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.setFillColor(color)
            context.fillPath()
        }
    }

    // MARK: - Grand average

    /// Many faint per-subject traces with one heavy mean drawn through them --
    /// the only variant whose meaning survives intact at list-view size.
    private func drawConvergence(in context: CGContext, detail: Detail) {
        let subjectCount = detail.denseTraceCount
        context.setStrokeColor(palette.faintTrace)
        context.setLineWidth(detail.traceWidth * 0.85)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        var generator = SplitMix64(seed: 0xC0FFEE)
        let center: CGFloat = 50
        for index in 0 ..< subjectCount {
            // Spread the subject traces around the midline rather than stacking
            // them, so they read as scatter about a mean, not as channels.
            let offset = CGFloat(index - subjectCount / 2) * 6
            context.addPath(
                tracePath(
                    baseline: center + offset,
                    amplitude: 7.5,
                    segments: detail.segmentsPerTrace,
                    generator: &generator
                )
            )
            context.strokePath()
        }

        var meanGenerator = SplitMix64(seed: 0xBEEF)
        context.setStrokeColor(palette.mean)
        context.setLineWidth(detail.traceWidth * 2.1)
        context.addPath(
            tracePath(
                baseline: center,
                amplitude: 3.5,
                segments: detail.segmentsPerTrace,
                generator: &meanGenerator
            )
        )
        context.strokePath()
    }
}

/// A tiny seeded generator so every icon is byte-identical between renders.
/// Finder caches thumbnails aggressively; a wobble on redraw would look like a
/// glitch.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// A value in `-magnitude ... magnitude`.
    mutating func symmetric(_ magnitude: CGFloat) -> CGFloat {
        let unit = CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53)
        return (unit * 2 - 1) * magnitude
    }
}
