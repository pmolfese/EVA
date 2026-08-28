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

    /// Points per inch a raster export is rendered at. `ImageRenderer.scale = 2`
    /// against the nominal 72 pt/inch.
    nonisolated static let rasterScale: CGFloat = 2
    nonisolated static var rasterDPI: Double { Double(WaveformScaleUnits.nominalPointsPerInch) * Double(rasterScale) }

    /// Renders `view` to PDF data without prompting for a save location —
    /// used by `FigureExportBasket` to snapshot a figure at "Add to Export"
    /// time, and by `save` itself for the `.pdf` save-panel path.
    static func pdfData<V: View>(_ view: V) -> Data? { pdf(view) }

    /// Renders `view` to PNG data without prompting — used for the basket's
    /// list thumbnails.
    static func pngData<V: View>(_ view: V) -> Data? { raster(view, format: .png) }

    private static func raster<V: View>(_ view: V, format: FigureFormat) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = rasterScale // higher DPI for print
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)

        // Declare the physical size, or the file lies about it.
        //
        // `NSBitmapImageRep(cgImage:)` takes its `size` from the pixel dimensions,
        // so a 2× render came out claiming to be twice as large as it was drawn.
        // Nothing writes a resolution into the PNG in that state, so every viewer
        // and every layout program falls back to 72 dpi and places the figure at
        // double size — which silently doubles any sensitivity printed on it.
        //
        // Setting `size` back to the rendered *point* extent is what makes the
        // PNG carry a `pHYs` chunk (and the JPEG its JFIF density) saying 144 dpi.
        // The figure then drops onto a page at the size it was composed at, and
        // the µV/mm in its caption is the µV/mm you can measure with a ruler.
        rep.size = NSSize(
            width: CGFloat(cgImage.width) / rasterScale,
            height: CGFloat(cgImage.height) / rasterScale
        )

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

/// The physical scale of an exported figure, in the units the EEG literature
/// uses.
///
/// **Exact, unlike the on-screen readout.** A PDF point is 1/72 inch by
/// definition and a raster export now declares its resolution, so a figure
/// placed at 100% really is drawn at the sensitivity printed on it — no display
/// calibration involved, because no display is. That is why the units reach
/// figures before they reach the screen honestly.
///
/// Computed from each plot's own geometry rather than from the toolbar, because
/// the panel plots use a different fraction of their height than the main
/// waveform does (`WaveformScaleUnits.traceRowFraction` versus
/// `channelRowFraction`) and fit a whole epoch to a fixed width instead of
/// scrolling at `timeScale`.
struct FigureScale: Equatable {
    var amplitudeScale: Double
    var plotSize: CGSize
    /// Seconds of signal spanning `plotSize.width`. Nil when the plot is not a
    /// time series — the caption then states sensitivity alone rather than
    /// inventing a sweep speed.
    var seconds: Double?

    var microvoltsPerMillimeter: Double {
        WaveformScaleUnits.microvoltsPerMillimeter(
            amplitudeScale: amplitudeScale,
            plotHeight: plotSize.height
        )
    }

    var millimetersPerSecond: Double? {
        guard let seconds, seconds > 0 else { return nil }
        return WaveformScaleUnits.millimetersPerSecond(
            plotWidth: plotSize.width, seconds: seconds
        )
    }

    var caption: String {
        var parts = ["\(WaveformScaleUnits.format(microvoltsPerMillimeter)) µV/mm"]
        if let sweep = millimetersPerSecond {
            parts.append("\(WaveformScaleUnits.format(sweep)) mm/s")
        }
        return parts.joined(separator: " · ") + " at 100% size"
    }
}

/// A self-contained, white-background figure wrapper (title + plot + legend) sized
/// for export, independent of the app's scroll/selection chrome.
struct FigureCard<Content: View>: View {
    let title: String
    let legend: [(String, Color)]
    let size: CGSize
    /// Optional so a caller that cannot state its geometry honestly omits the
    /// caption rather than printing a number it cannot stand behind.
    var scale: FigureScale?
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
            if let scale {
                Text(scale.caption)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.black.opacity(0.55))
            }
        }
        .padding(18)
        .background(Color.white)
    }
}
