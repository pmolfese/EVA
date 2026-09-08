//
//  NIfTIThumbnailRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import CoreText
import Foundation

nonisolated struct NIfTIThumbnailRenderer: Sendable {
    let model: NIfTIPreviewModel

    func draw(in context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(CGColor(gray: 0.025, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let pad = max(2, min(size.width, size.height) * 0.018)
        let gap = max(1, pad * 0.65)
        let cellWidth = (size.width - pad * 2 - gap) / 2
        let cellHeight = (size.height - pad * 2 - gap) / 2
        let rects = [
            CGRect(x: pad, y: pad + cellHeight + gap, width: cellWidth, height: cellHeight),
            CGRect(x: pad + cellWidth + gap, y: pad + cellHeight + gap, width: cellWidth, height: cellHeight),
            CGRect(x: pad, y: pad, width: cellWidth, height: cellHeight)
        ]

        for (index, rect) in rects.enumerated() where model.slices.indices.contains(index) {
            context.setFillColor(CGColor(gray: 0.07, alpha: 1))
            context.fill(rect)
            guard let image = NIfTISliceRenderer.image(
                for: model.slices[index],
                window: model.intensityWindow
            ) else { continue }
            let fitted = aspectFit(
                aspect: model.slices[index].physicalAspectRatio,
                inside: rect.insetBy(dx: gap, dy: gap)
            )
            context.interpolationQuality = .high
            context.draw(image, in: fitted)
        }

        let summaryRect = CGRect(
            x: pad + cellWidth + gap, y: pad,
            width: cellWidth, height: cellHeight
        )
        context.setFillColor(CGColor(red: 0.08, green: 0.20, blue: 0.17, alpha: 1))
        context.fill(summaryRect)
        if min(size.width, size.height) >= 96 {
            drawText("NIfTI", in: summaryRect.insetBy(dx: pad * 2, dy: pad * 2), context: context)
        }
    }

    private func aspectFit(aspect: Double, inside rect: CGRect) -> CGRect {
        guard aspect.isFinite, aspect > 0 else { return rect }
        if Double(rect.width / rect.height) > aspect {
            let width = rect.height * CGFloat(aspect)
            return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        let height = rect.width / CGFloat(aspect)
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    private func drawText(_ text: String, in rect: CGRect, context: CGContext) {
        let font = CTFontCreateWithName("SFProRounded-Semibold" as CFString, max(11, rect.height * 0.17), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: rect.minX, y: rect.midY)
        CTLineDraw(line, context)
    }
}
