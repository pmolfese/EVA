//
//  MGHThumbnailRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import CoreText
import Foundation

nonisolated struct MGHThumbnailRenderer: Sendable {
    let model: MGHPreviewModel

    func draw(in context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 0.025, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let pad = max(2, min(size.width, size.height) * 0.018), gap = max(1, pad * 0.65)
        let width = (size.width - pad * 2 - gap) / 2, height = (size.height - pad * 2 - gap) / 2
        let rects = [
            CGRect(x: pad, y: pad + height + gap, width: width, height: height),
            CGRect(x: pad + width + gap, y: pad + height + gap, width: width, height: height),
            CGRect(x: pad, y: pad, width: width, height: height)
        ]
        for (index, rect) in rects.enumerated() where model.slices.indices.contains(index) {
            context.setFillColor(CGColor(gray: 0.07, alpha: 1)); context.fill(rect)
            guard let image = NIfTISliceRenderer.image(for: model.slices[index], window: model.intensityWindow) else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: aspectFit(model.slices[index].physicalAspectRatio, rect.insetBy(dx: gap, dy: gap)))
        }
        let summary = CGRect(x: pad + width + gap, y: pad, width: width, height: height)
        context.setFillColor(CGColor(red: 0.18, green: 0.11, blue: 0.24, alpha: 1)); context.fill(summary)
        if min(size.width, size.height) >= 96 { drawText("MGH", in: summary.insetBy(dx: pad * 2, dy: pad * 2), context: context) }
    }

    private func aspectFit(_ aspect: Double, _ rect: CGRect) -> CGRect {
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
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: rect.minX, y: rect.midY); CTLineDraw(line, context)
    }
}
