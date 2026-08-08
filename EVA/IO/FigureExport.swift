//
//  FigureExport.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Renders a waveform/butterfly plot to a publication-ready image (PNG / JPEG /
//  PDF) via SwiftUI ImageRenderer, saved through NSSavePanel. Used by the
//  right-click "Save Figure As…" menu on averaged-data plots.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FigureFormat: String, CaseIterable, Identifiable {
    case png, jpeg, pdf
    var id: String { rawValue }
    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .pdf: return "PDF"
        }
    }
    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .pdf: return .pdf
        }
    }
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .pdf: return "pdf"
        }
    }
}

@MainActor
enum FigureExporter {
    /// Renders `view` to the chosen format and prompts for a save location.
    static func save<V: View>(_ view: V, defaultName: String, format: FigureFormat) {
        let data: Data?
        switch format {
        case .png, .jpeg: data = raster(view, format: format)
        case .pdf: data = pdf(view)
        }
        guard let data else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private static func raster<V: View>(_ view: V, format: FigureFormat) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2 // higher DPI for print
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let type: NSBitmapImageRep.FileType = (format == .png) ? .png : .jpeg
        let properties: [NSBitmapImageRep.PropertyKey: Any] = (format == .jpeg)
            ? [.compressionFactor: 0.95] : [:]
        return rep.representation(using: type, properties: properties)
    }

    private static func pdf<V: View>(_ view: V) -> Data? {
        let renderer = ImageRenderer(content: view)
        let mutableData = NSMutableData()
        var produced: Data?
        renderer.render { size, draw in
            guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else { return }
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            produced = mutableData as Data
        }
        return produced
    }
}

/// A self-contained, white-background figure wrapper (title + plot + legend) sized
/// for export, independent of the app's scroll/selection chrome.
struct FigureCard<Content: View>: View {
    let title: String
    let legend: [(String, Color)]
    let size: CGSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.black)
            }
            content()
                .frame(width: size.width, height: size.height)
            if !legend.isEmpty {
                FlowLegend(items: legend)
            }
        }
        .padding(18)
        .background(Color.white)
    }
}
