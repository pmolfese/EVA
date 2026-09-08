//
//  FIFThumbnailRenderer.swift
//  EVAPreviewKit
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Finder thumbnails for `.fif`. Because a `.fif` can be any of a dozen
//  documents, the thumbnail's job is to make *which* one obvious at 64 points:
//
//    recording      stacked waveform traces
//    epochs/average overlaid butterfly traces on a baseline
//    head model     nested shell contours
//    digitization   the point cloud from above
//    anything else  a stack of blocks, one bar per block kind
//
//  Colors are flat and opaque on a solid backing, never translucent, for the
//  same reason the MFF renderer gives: a thumbnail composites onto a white list
//  row, a dark sidebar or the desktop, and alpha would make one file look like
//  three different ones.
//

import CoreGraphics
import Foundation

nonisolated struct FIFThumbnailRenderer: Sendable {

    struct Palette: Sendable {
        let backing: CGColor
        let border: CGColor
        let trace: CGColor
        let faint: CGColor
        let shells: [CGColor]

        static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
            CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }

        static let light = Palette(
            backing: rgb(252, 252, 253),
            border: rgb(206, 209, 214),
            trace: rgb(52, 104, 194),
            faint: rgb(150, 172, 208),
            shells: [rgb(214, 93, 139), rgb(58, 150, 150), rgb(92, 96, 186)])

        static let dark = Palette(
            backing: rgb(38, 39, 43),
            border: rgb(70, 72, 78),
            trace: rgb(122, 168, 240),
            faint: rgb(78, 104, 150),
            shells: [rgb(230, 128, 170), rgb(94, 190, 190), rgb(140, 144, 226)])
    }

    let summary: FIFQuickLookSummary
    var palette: Palette = .light

    func draw(in context: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.setFillColor(palette.backing)
        context.fill(rect)

        let inset = rect.insetBy(dx: size.width * 0.08, dy: size.height * 0.08)
        if let recording = summary.recording {
            if recording.conditionTraces.isEmpty {
                drawStackedTraces(recording.traces, amplitude: recording.amplitudeMicrovolts, in: inset, context: context)
            } else {
                drawButterfly(recording, in: inset, context: context)
            }
        } else if let model = summary.headModel {
            drawShells(model, in: inset, context: context)
        } else if let digitization = summary.digitization {
            drawPoints(digitization, in: inset, context: context)
        } else {
            drawBlocks(in: inset, context: context)
        }

        context.setStrokeColor(palette.border)
        context.setLineWidth(max(1, size.width * 0.012))
        context.stroke(rect.insetBy(dx: size.width * 0.006, dy: size.height * 0.006))
    }

    // MARK: - Looks

    private func drawStackedTraces(_ traces: [FIFQuickLookSummary.Recording.Trace],
                                   amplitude: Float, in rect: CGRect, context: CGContext) {
        guard !traces.isEmpty, amplitude > 0 else { return drawBlocks(in: rect, context: context) }
        let rows = min(traces.count, 6)
        let height = rect.height / CGFloat(rows)
        context.setStrokeColor(palette.trace)
        context.setLineWidth(max(0.7, rect.width * 0.012))
        for row in 0..<rows {
            let values = traces[row].values
            guard values.count > 1 else { continue }
            let midY = rect.maxY - (CGFloat(row) + 0.5) * height
            let step = rect.width / CGFloat(values.count - 1)
            context.beginPath()
            for (index, value) in values.enumerated() {
                let y = midY + CGFloat(value / amplitude) * height * 0.42
                let point = CGPoint(x: rect.minX + CGFloat(index) * step, y: y)
                index == 0 ? context.move(to: point) : context.addLine(to: point)
            }
            context.strokePath()
        }
    }

    private func drawButterfly(_ recording: FIFQuickLookSummary.Recording,
                               in rect: CGRect, context: CGContext) {
        let amplitude = recording.amplitudeMicrovolts
        guard amplitude > 0 else { return drawBlocks(in: rect, context: context) }
        let panels = min(recording.conditionTraces.count, 2)
        guard panels > 0 else { return drawBlocks(in: rect, context: context) }
        let gap = rect.width * 0.05
        let width = (rect.width - gap * CGFloat(panels - 1)) / CGFloat(panels)

        for panel in 0..<panels {
            let frame = CGRect(x: rect.minX + CGFloat(panel) * (width + gap),
                               y: rect.minY, width: width, height: rect.height)
            context.setStrokeColor(palette.faint)
            context.setLineWidth(max(0.5, rect.width * 0.006))
            context.stroke(CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: 0))

            context.setStrokeColor(palette.trace)
            context.setLineWidth(max(0.5, rect.width * 0.007))
            // A full butterfly is unreadable at 64 points — every channel
            // overlaid turns into a solid block of ink. A spread of a few
            // channels keeps the shape of the response.
            for trace in thinned(recording.conditionTraces[panel], to: 6) {
                let values = trace.values
                guard values.count > 1 else { continue }
                let step = frame.width / CGFloat(values.count - 1)
                context.beginPath()
                for (index, value) in values.enumerated() {
                    let y = frame.midY + CGFloat(value / amplitude) * frame.height * 0.38
                    let point = CGPoint(x: frame.minX + CGFloat(index) * step, y: y)
                    index == 0 ? context.move(to: point) : context.addLine(to: point)
                }
                context.strokePath()
            }
        }
    }

    private func thinned(_ traces: [FIFQuickLookSummary.Recording.Trace], to count: Int)
        -> [FIFQuickLookSummary.Recording.Trace] {
        guard traces.count > count, count > 1 else { return traces }
        return (0..<count).map { traces[$0 * (traces.count - 1) / (count - 1)] }
    }

    private func drawShells(_ model: FIFQuickLookSummary.HeadModel,
                            in rect: CGRect, context: CGContext) {
        let side = min(rect.width, rect.height)
        let frame = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        context.setLineWidth(max(0.8, side * 0.014))
        for (index, shell) in model.shells.enumerated() {
            context.setStrokeColor(palette.shells[index % palette.shells.count])
            context.beginPath()
            for segment in shell.sagittal {
                // Contours are in view coordinates (y down); Core Graphics here
                // is y up, so flip as we place them.
                context.move(to: CGPoint(x: frame.minX + frame.width * segment.from.x,
                                         y: frame.maxY - frame.height * segment.from.y))
                context.addLine(to: CGPoint(x: frame.minX + frame.width * segment.to.x,
                                            y: frame.maxY - frame.height * segment.to.y))
            }
            context.strokePath()
        }
    }

    private func drawPoints(_ digitization: FIFQuickLookSummary.Digitization,
                            in rect: CGRect, context: CGContext) {
        let side = min(rect.width, rect.height)
        let frame = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let radius = max(1, side * 0.028)
        for point in digitization.points {
            context.setFillColor(point.isFiducial ? palette.shells[0] : palette.trace)
            let centre = CGPoint(x: frame.minX + frame.width * point.top.x,
                                 y: frame.maxY - frame.height * point.top.y)
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                           width: radius * 2, height: radius * 2))
        }
    }

    /// The generic look: a list of bars, one per block kind, on a fixed
    /// five-row grid so a file with one block reads as a short list rather than
    /// as one enormous rectangle. Deliberately reminiscent of lines of text —
    /// this is the "metadata document" of the family.
    private func drawBlocks(in rect: CGRect, context: CGContext) {
        let rows = 5
        let blocks = Array(summary.outline.prefix(rows))
        let maximum = CGFloat(blocks.map(\.count).max() ?? 1)
        let height = rect.height / CGFloat(rows)
        for index in 0..<rows {
            let filled = index < blocks.count
            // Filled rows scale with the block count; the remaining rows are
            // short and faint, which reads as "and a few smaller things".
            let fraction: CGFloat = filled
                ? max(0.3, 0.35 + 0.65 * CGFloat(blocks[index].count) / maximum)
                : 0.22 + 0.1 * CGFloat((index * 7) % 3)
            let bar = CGRect(x: rect.minX,
                             y: rect.maxY - CGFloat(index + 1) * height + height * 0.28,
                             width: rect.width * fraction,
                             height: height * 0.44)
            context.setFillColor(filled ? (index == 0 ? palette.trace : palette.faint) : palette.faint)
            context.fill(bar)
        }
    }
}
