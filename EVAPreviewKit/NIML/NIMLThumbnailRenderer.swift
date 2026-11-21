import CoreGraphics
import CoreText
import Foundation

nonisolated struct NIMLThumbnailRenderer: Sendable {
    let model: NIMLPreviewModel

    func draw(in context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let pad = size.width * 0.09
        let element = model.data ?? model.elements.first { !$0.sample.isEmpty }
        let rows = element?.sample ?? []
        let columns = max(1, rows.first?.count ?? 4)
        let rowCount = max(1, min(12, rows.count))
        let cellWidth = (size.width - pad * 2) / CGFloat(columns)
        let cellHeight = size.height * 0.55 / CGFloat(rowCount)
        for row in 0..<rowCount {
            for column in 0..<columns {
                var fraction = 0.35
                if rows.indices.contains(row), rows[row].indices.contains(column),
                   let value = Double(rows[row][column]), value.isFinite,
                   let range = element?.ranges[column], range.upperBound > range.lowerBound {
                    let span = range.upperBound - range.lowerBound
                    let scaled = (value - range.lowerBound) / span
                    if scaled.isFinite { fraction = max(0, min(1, scaled)) }
                }
                context.setFillColor(CGColor(red: 0.15 + fraction * 0.65, green: 0.3 + fraction * 0.4, blue: 0.65, alpha: 1))
                context.fill(CGRect(x: pad + CGFloat(column) * cellWidth, y: size.height * 0.2 + CGFloat(rowCount - row - 1) * cellHeight,
                                    width: cellWidth * 0.85, height: cellHeight * 0.78))
            }
        }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size.height * 0.13, nil)
        let text = NSAttributedString(string: "NIML", attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)
        ])
        context.textPosition = CGPoint(x: pad, y: size.height * 0.81)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
}
