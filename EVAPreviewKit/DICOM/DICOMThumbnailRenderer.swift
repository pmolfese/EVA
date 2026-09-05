//
//  DICOMThumbnailRenderer.swift
//  EVAPreviewKit
//

import CoreGraphics
import CoreText
import Foundation

nonisolated struct DICOMThumbnailRenderer: Sendable {
    let model: DICOMPreviewModel

    func draw(in context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 0.02, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let padding = max(3, min(size.width, size.height) * 0.035)
        let labelHeight = min(size.height * 0.16, 30)
        let imageRect = CGRect(
            x: padding, y: padding + labelHeight,
            width: size.width - padding * 2, height: size.height - padding * 2 - labelHeight
        )
        if let image = DICOMImageRenderer.image(for: model.image) {
            context.interpolationQuality = .high
            context.draw(image, in: aspectFit(model.physicalAspectRatio, imageRect))
        }
        if min(size.width, size.height) >= 72 {
            let text = model.modality.map { "DICOM · \($0)" } ?? "DICOM"
            drawText(text, at: CGPoint(x: padding, y: padding + 1), height: labelHeight, context: context)
        }
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

    private func drawText(_ text: String, at point: CGPoint, height: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("SFProRounded-Semibold" as CFString, max(9, height * 0.48), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
