//
//  CIFTIThumbnailRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import CoreText
import Foundation

nonisolated struct CIFTIThumbnailRenderer: Sendable {
    let model: CIFTIPreviewModel

    func draw(in context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(red: 0.018, green: 0.028, blue: 0.025, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let pad = max(3, min(size.width, size.height) * 0.045)
        let footerHeight = min(size.height * 0.18, 34)
        let matrixRect = CGRect(
            x: pad,
            y: pad + footerHeight,
            width: size.width - pad * 2,
            height: size.height - pad * 3 - footerHeight
        )
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(matrixRect)
        if let image = CIFTIMatrixRenderer.image(for: model) {
            context.interpolationQuality = .none
            context.draw(image, in: matrixRect.insetBy(dx: 1, dy: 1))
        }

        if min(size.width, size.height) >= 72 {
            drawText("CIFTI", in: CGRect(
                x: pad, y: pad,
                width: size.width - pad * 2, height: footerHeight
            ), context: context)
        }
    }

    private func drawText(_ text: String, in rect: CGRect, context: CGContext) {
        let font = CTFontCreateWithName(
            "SFProRounded-Semibold" as CFString,
            max(10, rect.height * 0.6), nil
        )
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: rect.minX, y: rect.midY - rect.height * 0.2)
        CTLineDraw(line, context)
    }
}
