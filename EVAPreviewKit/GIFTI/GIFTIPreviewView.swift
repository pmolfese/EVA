//
//  GIFTIPreviewView.swift
//  EVAPreviewKit
//

import SceneKit
import SwiftUI

struct GIFTIPreviewView: View {
    let model: GIFTIPreviewModel

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 620 {
                HStack(spacing: 0) {
                    visualPanel
                        .frame(width: proxy.size.width * 0.7)
                    Divider()
                    metadataPanel
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        visualPanel.frame(height: max(360, proxy.size.width * 0.72))
                        Divider()
                        GIFTIMetadataContent(model: model)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    @ViewBuilder
    private var visualPanel: some View {
        if model.hasRenderableGeometry {
            GIFTISurfacePanel(model: model)
        } else {
            GIFTIDataPanel(model: model)
        }
    }

    private var metadataPanel: some View {
        ScrollView { GIFTIMetadataContent(model: model) }
            .background(.background)
    }
}

private struct GIFTISurfacePanel: View {
    let model: GIFTIPreviewModel
    @State private var selectedOverlayIndex = 0
    @State private var showsNormals = false

    private var selectedOverlay: GIFTIScalarOverlay? {
        model.displayOverlay(at: selectedOverlayIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                GIFTIScene(model: model, overlay: selectedOverlay, showsNormals: showsNormals)
                    .id("\(selectedOverlayIndex)-\(showsNormals)")
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedOverlay?.name ?? model.fileKind)
                        .font(.headline)
                    Text("Drag to rotate • Scroll to zoom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(.white)
                .padding(14)
            }
            surfaceToolbar
        }
        .background(Color(red: 0.018, green: 0.028, blue: 0.025))
    }

    private var surfaceToolbar: some View {
        HStack(spacing: 12) {
            if model.overlays.count > 1 {
                Text("Frame \(selectedOverlayIndex + 1) of \(model.overlays.count)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 98, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(selectedOverlayIndex) },
                        set: { selectedOverlayIndex = Int($0.rounded()) }
                    ),
                    in: 0...Double(model.overlays.count - 1),
                    step: 1
                )
                Text(selectedOverlay?.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
            } else {
                Label("Smooth vertex normals", systemImage: "circle.hexagongrid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button {
                showsNormals.toggle()
            } label: {
                Label("Normals", systemImage: showsNormals ? "line.diagonal.arrow" : "line.diagonal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.triangles.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .foregroundStyle(.white)
        .background(.black.opacity(0.42))
    }
}

private struct GIFTIScene: View {
    private let bundle: GIFTISceneBundle

    init(model: GIFTIPreviewModel, overlay: GIFTIScalarOverlay?, showsNormals: Bool) {
        bundle = GIFTISceneFactory.make(
            model: model,
            overlay: overlay,
            showsNormals: showsNormals
        )
    }

    var body: some View {
        SceneView(
            scene: bundle.scene,
            pointOfView: bundle.camera,
            options: [.allowsCameraControl],
            preferredFramesPerSecond: 30,
            antialiasingMode: .multisampling4X
        )
    }
}

private struct GIFTIDataPanel: View {
    let model: GIFTIPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.fileKind)
                    .font(.title2.weight(.semibold))
                Text(model.overlay == nil
                     ? "No surface coordinates in this file"
                     : "No compatible surface mesh found nearby")
                    .foregroundStyle(.secondary)
            }
            if model.overlays.count > 1 {
                GIFTIFunctionalHeatmap(
                    overlays: model.overlays,
                    sharedWindow: model.sharedOverlayWindow
                )
                HStack {
                    Text("Nodes")
                    Spacer()
                    Text("\(model.overlays.count.formatted()) frames × \((model.overlay?.values.count ?? 0).formatted()) nodes")
                    Spacer()
                    Text("Time →")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Label(
                    "Add a matching .surf.gii file to this folder to display these values on a cortical surface.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let overlay = model.overlay {
                GIFTIHistogram(values: overlay.values, window: overlay.window)
                if let window = overlay.window {
                    HStack {
                        Text(short(window.lowerBound))
                        Spacer()
                        Text(short(window.upperBound))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(
                    "No Previewable Geometry",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("The GIFTI metadata and data-array structure are available at right.")
                )
            }
            Spacer()
        }
        .padding(28)
        .foregroundStyle(.white)
        .background(Color(red: 0.018, green: 0.028, blue: 0.025))
    }

    private func short(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(3...5)))
    }
}

private struct GIFTIFunctionalHeatmap: View {
    let overlays: [GIFTIScalarOverlay]
    let sharedWindow: ClosedRange<Double>?

    var body: some View {
        Canvas { context, size in
            let frameIndices = sampledIndices(count: overlays.count, limit: 128)
            guard let first = overlays.first,
                  !frameIndices.isEmpty,
                  !first.values.isEmpty else { return }
            let nodeIndices = sampledIndices(count: first.values.count, limit: 256)
            guard !nodeIndices.isEmpty else { return }
            let cellWidth = size.width / CGFloat(frameIndices.count)
            let cellHeight = size.height / CGFloat(nodeIndices.count)

            for (displayColumn, frameIndex) in frameIndices.enumerated() {
                let overlay = overlays[frameIndex]
                for (displayRow, nodeIndex) in nodeIndices.enumerated() where nodeIndex < overlay.values.count {
                    let rect = CGRect(
                        x: CGFloat(displayColumn) * cellWidth,
                        y: CGFloat(displayRow) * cellHeight,
                        width: cellWidth + 0.5,
                        height: cellHeight + 0.5
                    )
                    context.fill(Path(rect), with: .color(color(
                        overlay.values[nodeIndex],
                        window: sharedWindow ?? overlay.window
                    )))
                }
            }
        }
        .frame(height: 260)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sampledIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }
        let step = Double(count - 1) / Double(limit - 1)
        return (0..<limit).map { Int(Double($0) * step) }
    }

    private func color(_ value: Double, window: ClosedRange<Double>?) -> Color {
        guard value.isFinite, let window else { return Color(white: 0.25) }
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return Color(red: 0.3, green: 0.8, blue: 0.65) }
        let t = min(max((value - window.lowerBound) / span, 0), 1)
        if window.lowerBound < 0, window.upperBound > 0 {
            let zero = -window.lowerBound / span
            if t < zero {
                let p = zero > 0 ? t / zero : 0
                return Color(red: 0.14 + 0.72 * p, green: 0.34 + 0.52 * p, blue: 0.94)
            }
            let p = zero < 1 ? (t - zero) / (1 - zero) : 1
            return Color(red: 0.94, green: 0.86 - 0.66 * p, blue: 0.86 - 0.7 * p)
        }
        return Color(red: 0.12 + 0.83 * t, green: 0.36 + 0.52 * t, blue: 0.72 - 0.52 * t)
    }
}

private struct GIFTIHistogram: View {
    let values: [Double]
    let window: ClosedRange<Double>?

    var body: some View {
        Canvas { context, size in
            let bins = histogram
            guard let maximum = bins.max(), maximum > 0 else { return }
            let width = size.width / CGFloat(bins.count)
            for (index, count) in bins.enumerated() {
                let height = size.height * CGFloat(count / maximum)
                let rect = CGRect(
                    x: CGFloat(index) * width,
                    y: size.height - height,
                    width: max(width - 1, 1),
                    height: height
                )
                context.fill(Path(rect), with: .color(Color(red: 0.28, green: 0.85, blue: 0.66)))
            }
        }
        .frame(minHeight: 180)
        .padding(14)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private var histogram: [Double] {
        let binCount = 64
        var bins = [Double](repeating: 0, count: binCount)
        guard let window else { return bins }
        let range = window.upperBound - window.lowerBound
        guard range > 0 else { return bins }
        let stride = max(values.count / 250_000, 1)
        for index in Swift.stride(from: 0, to: values.count, by: stride) {
            let value = values[index]
            guard value.isFinite else { continue }
            let normalized = min(max((value - window.lowerBound) / range, 0), 1)
            bins[min(Int(normalized * Double(binCount)), binCount - 1)] += 1
        }
        return bins
    }
}

private struct GIFTIMetadataContent: View {
    let model: GIFTIPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    badge("GIFTI \(model.version)")
                    badge(model.fileKind)
                }
            }

            VStack(spacing: 8) {
                row("Vertices", model.vertexCount.formatted())
                row("Triangles", model.triangleCount.formatted())
                row("Data arrays", model.arrays.count.formatted())
                if !model.overlays.isEmpty { row("Overlay datasets", model.overlays.count.formatted()) }
                if let source = model.companionSurfaceName { row("Surface", source) }
                if let structure = model.anatomicalStructure { row("Structure", structure) }
                if let type = model.geometricType { row("Geometry", type) }
                if let space = model.coordinateSpace { row("Space", cleaned(space)) }
                if let bounds = model.boundsText { row("Bounds", bounds) }
                row("File size", ByteCountFormatter.string(fromByteCount: model.byteSize, countStyle: .file))
            }

            Divider()
            Text("Data Arrays")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(model.arrays.enumerated()), id: \.offset) { _, array in
                VStack(alignment: .leading, spacing: 3) {
                    Text(array.intentDisplayName)
                        .font(.subheadline.weight(.medium))
                    Text("\(array.dimensionsText) • \(shortType(array.dataType)) • \(shortEncoding(array.encoding))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.labels.isEmpty {
                Divider()
                row("Labels", model.labels.count.formatted())
            }
            if let description = model.metadata["Description"], !description.isEmpty {
                Divider()
                Text("Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(description)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.13), in: Capsule())
    }

    private func shortType(_ value: String) -> String {
        value.replacingOccurrences(of: "NIFTI_TYPE_", with: "")
    }

    private func shortEncoding(_ value: String) -> String {
        value.replacingOccurrences(of: "Binary", with: "")
    }

    private func cleaned(_ value: String) -> String {
        value.replacingOccurrences(of: "NIFTI_XFORM_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
}
