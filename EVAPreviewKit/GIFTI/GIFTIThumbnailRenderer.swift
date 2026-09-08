//
//  GIFTIThumbnailRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import CoreText
import Foundation

nonisolated struct GIFTIThumbnailRenderer: Sendable {
    let model: GIFTIPreviewModel

    func draw(in context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(red: 0.018, green: 0.028, blue: 0.025, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let inset = min(size.width, size.height) * 0.08
        let drawingRect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        if model.vertices.isEmpty {
            drawHistogram(in: drawingRect, context: context)
        } else {
            drawSurface(in: drawingRect, context: context)
        }

        if min(size.width, size.height) >= 80 {
            drawText("GIFTI", in: CGRect(x: inset, y: inset * 0.35, width: size.width, height: inset), context: context)
        }
    }

    private func drawSurface(in rect: CGRect, context: CGContext) {
        let projected = model.vertices.map { point in
            CGPoint(
                x: CGFloat(0.72 * point.x - 0.69 * point.y),
                y: CGFloat(0.28 * point.x + 0.30 * point.y + 0.91 * point.z)
            )
        }
        guard let first = projected.first else { return }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in projected.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let width = max(maxX - minX, 1), height = max(maxY - minY, 1)
        let scale = min(rect.width / width, rect.height / height)
        let offsetX = rect.midX - (minX + maxX) * scale / 2
        let offsetY = rect.midY - (minY + maxY) * scale / 2
        func mapped(_ index: UInt32) -> CGPoint {
            let point = projected[Int(index)]
            return CGPoint(x: point.x * scale + offsetX, y: point.y * scale + offsetY)
        }

        context.setLineWidth(max(0.3, min(rect.width, rect.height) / 900))
        context.setStrokeColor(CGColor(red: 0.32, green: 0.92, blue: 0.71, alpha: 0.62))
        context.beginPath()
        if model.triangles.isEmpty {
            let stride = max(projected.count / 40_000, 1)
            let radius = max(0.5, min(rect.width, rect.height) / 500)
            for index in Swift.stride(from: 0, to: projected.count, by: stride) {
                let point = CGPoint(x: projected[index].x * scale + offsetX, y: projected[index].y * scale + offsetY)
                context.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
            context.setFillColor(CGColor(red: 0.32, green: 0.92, blue: 0.71, alpha: 0.75))
            context.fillPath()
        } else {
            let stride = max(model.triangles.count / 35_000, 1)
            for index in Swift.stride(from: 0, to: model.triangles.count, by: stride) {
                let triangle = model.triangles[index]
                context.move(to: mapped(triangle.a))
                context.addLine(to: mapped(triangle.b))
                context.addLine(to: mapped(triangle.c))
                context.closePath()
            }
            context.strokePath()
        }
    }

    private func drawHistogram(in rect: CGRect, context: CGContext) {
        guard let overlay = model.overlay, let window = overlay.window else { return }
        var bins = [Double](repeating: 0, count: 48)
        let range = window.upperBound - window.lowerBound
        let stride = max(overlay.values.count / 100_000, 1)
        for index in Swift.stride(from: 0, to: overlay.values.count, by: stride) {
            let value = overlay.values[index]
            guard value.isFinite else { continue }
            let normalized = min(max((value - window.lowerBound) / range, 0), 1)
            bins[min(Int(normalized * Double(bins.count)), bins.count - 1)] += 1
        }
        guard let maximum = bins.max(), maximum > 0 else { return }
        let width = rect.width / CGFloat(bins.count)
        context.setFillColor(CGColor(red: 0.28, green: 0.85, blue: 0.66, alpha: 0.9))
        for (index, count) in bins.enumerated() {
            let height = rect.height * CGFloat(count / maximum)
            context.fill(CGRect(x: rect.minX + CGFloat(index) * width, y: rect.minY, width: max(width - 1, 1), height: height))
        }
    }

    private func drawText(_ text: String, in rect: CGRect, context: CGContext) {
        let font = CTFontCreateWithName("SFProRounded-Semibold" as CFString, max(11, rect.height * 0.7), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY)
        CTLineDraw(line, context)
    }
}
