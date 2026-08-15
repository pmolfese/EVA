//
//  FigureExportBasket.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A session-wide collection of figures added via "Add to Export" (see
//  `figureSaveMenu` in ButterflyPanelViews.swift), viewable/exportable from
//  the "Figure Export" window (Window menu, like Debug Log). Each figure is
//  captured as a vector PDF snapshot at add-time — not kept "live" — so the
//  basket has no dependency on the source recording/window staying open, and
//  scales crisply in the contact-sheet layout regardless of size.
//
//  v1 (this pass): reorder/remove + a simple stacked contact-sheet export
//  (one column, wraps to a new page when a page's height fills up). The
//  freeform drag-to-position page layout is a deliberately separate, larger
//  follow-up — see the "figures as a print-dialog-style canvas" idea this
//  was scoped down from.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One figure captured into the basket.
struct FigureBasketItem: Identifiable {
    let id = UUID()
    let title: String
    let legend: [(String, Color)]
    /// The figure's own natural aspect ratio (from the size it was captured
    /// at), so the contact sheet can scale it to a page column width without
    /// distorting it.
    let aspectRatio: CGFloat
    /// Vector snapshot — what actually gets placed on the contact sheet.
    let pdfData: Data
    /// Small raster preview for the basket list only.
    let thumbnailData: Data
    let addedAt: Date

    var thumbnailImage: NSImage? { NSImage(data: thumbnailData) }
}

/// Page size choices for the contact-sheet export. Points at 72/inch, same
/// convention as the rest of the app's figure export.
enum FigureBasketPageSize: String, CaseIterable, Identifiable {
    case usLetter = "Letter (8.5 × 11 in)"
    case square = "Square (8 × 8 in)"

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .usLetter: return CGSize(width: 8.5 * 72, height: 11 * 72)
        case .square: return CGSize(width: 8 * 72, height: 8 * 72)
        }
    }
}

@MainActor
@Observable
final class FigureExportBasket {
    static let shared = FigureExportBasket()

    private(set) var items: [FigureBasketItem] = []
    var pageSize: FigureBasketPageSize = .usLetter

    private init() {}

    /// Captures `figure` (already wrapped in its `FigureCard`, same content
    /// a "Save Figure As…" click would render) as a PDF + thumbnail and adds
    /// it to the basket. Silently no-ops if rendering fails (e.g. a
    /// momentarily zero-sized view), matching `FigureExporter.save`'s own
    /// "no data, no dialog" behavior.
    func add<V: View>(_ figure: V, title: String, legend: [(String, Color)], size: CGSize) {
        guard size.width > 0, size.height > 0,
              let pdfData = FigureExporter.pdfData(figure),
              let thumbnailData = FigureExporter.pngData(figure) else { return }
        let item = FigureBasketItem(
            title: title,
            legend: legend,
            aspectRatio: size.width / size.height,
            pdfData: pdfData,
            thumbnailData: thumbnailData,
            addedAt: Date()
        )
        items.append(item)
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func clear() {
        items.removeAll()
    }

    /// One PNG or PDF file per item, in one chosen folder, named
    /// `<prefix>-<N>.<ext>` where `N` is the item's 1-based position in the
    /// basket — the same number `FigureExportBasketView` shows beside each
    /// row, so what gets written matches what was picked.
    ///
    /// No re-rendering: `pdfData`/`thumbnailData` are the exact bytes
    /// `FigureExporter` would produce for a "Save Figure As…" click on that
    /// same figure — `add(_:title:legend:size:)` captures both up front —
    /// so this is a folder pick and a sequence of writes, nothing more.
    /// JPEG isn't offered here: nothing in the basket is captured as one, and
    /// re-rendering just for a third format isn't worth the added path.
    func exportIndividually(prefix: String, format: FigureFormat) {
        guard !items.isEmpty, format != .jpeg else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for \(items.count) exported figure\(items.count == 1 ? "" : "s")."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let names = Self.filenames(prefix: prefix, count: items.count, format: format)
        for (name, item) in zip(names, items) {
            let data = format == .pdf ? item.pdfData : item.thumbnailData
            try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    /// `<prefix>-<N>.<ext>` for each of `count` items, 1-based and
    /// zero-padded to the width of `count` itself — "-01", "-02", …, "-10"
    /// rather than "-1", "-10", "-2", so Finder's default sort agrees with
    /// basket order past nine items. Pulled out of `exportIndividually` so
    /// the naming scheme is testable without driving a real folder picker,
    /// and so `FigureExportBasketView`'s preview text can share it exactly
    /// rather than reimplementing the padding rule.
    static func filenames(prefix: String, count: Int, format: FigureFormat) -> [String] {
        guard count > 0 else { return [] }
        let cleanedPrefix = sanitizedPrefix(prefix)
        let width = max(String(count).count, 1)
        let ext = format.fileExtension
        return (1...count).map { index in
            "\(cleanedPrefix)-\(String(format: "%0\(width)d", index)).\(ext)"
        }
    }

    /// Strips characters the filesystem would reject or that would otherwise
    /// split the name across an unintended path component, and falls back to
    /// a name that is never empty — an all-invalid or blank prefix must not
    /// silently produce `-1.png` with nothing in front of it.
    ///
    /// Not `private`: `FigureExportBasketView`'s filename preview calls this
    /// too, so what it shows before the folder picker opens is the name that
    /// actually gets written, not a guess at what sanitizing will do to it.
    static func sanitizedPrefix(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined()
        return cleaned.isEmpty ? "EVA-Figure" : cleaned
    }

    /// Lays out every item as a single column, top to bottom, scaled to the
    /// page's width, wrapping to a new page when the next item wouldn't fit.
    /// Exports the whole multi-page contact sheet as one PDF.
    func exportContactSheet() {
        guard !items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "EVA Figures.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let page = pageSize.size
        let margin: CGFloat = 36
        let contentWidth = page.width - margin * 2
        let itemSpacing: CGFloat = 18

        guard let consumer = CGDataConsumer(url: url as CFURL) else { return }
        var mediaBox = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

        var cursorY: CGFloat = page.height - margin
        var pageIsOpen = false

        func beginPageIfNeeded() {
            guard !pageIsOpen else { return }
            ctx.beginPDFPage(nil)
            pageIsOpen = true
            cursorY = page.height - margin
        }
        func endPageIfNeeded() {
            guard pageIsOpen else { return }
            ctx.endPDFPage()
            pageIsOpen = false
        }

        for item in items {
            let itemHeight = contentWidth / max(item.aspectRatio, 0.01)
            beginPageIfNeeded()
            if cursorY - itemHeight < margin, cursorY < page.height - margin {
                endPageIfNeeded()
                beginPageIfNeeded()
            }

            if let provider = CGDataProvider(data: item.pdfData as CFData),
               let itemPDF = CGPDFDocument(provider),
               let pdfPage = itemPDF.page(at: 1) {
                let originY = cursorY - itemHeight
                ctx.saveGState()
                ctx.translateBy(x: margin, y: originY)
                let pageRect = pdfPage.getBoxRect(.mediaBox)
                let scale = pageRect.width > 0 ? contentWidth / pageRect.width : 1
                ctx.scaleBy(x: scale, y: scale)
                ctx.drawPDFPage(pdfPage)
                ctx.restoreGState()
            }
            cursorY -= itemHeight + itemSpacing
        }
        endPageIfNeeded()
        ctx.closePDF()
    }
}
