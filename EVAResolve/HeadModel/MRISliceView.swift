//
//  MRISliceView.swift
//  EVA Resolve
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  One orthogonal slice of the head model's T1 with the coregistration overlaid:
//  MRI fiducials (crosses), electrodes within a few millimetres of the plane
//  (dots coloured by scalp residual), and the scalp contour. Click to pick the
//  current fiducial; scroll / slider to move through the volume.
//
//  The volume is canonical (i→R, j→A, k→S), so each plane is a straight slab of
//  the voxel array; the raster is flipped vertically so anterior / superior is up
//  and drawn in radiological-free "neurological" convention (subject's right on
//  the viewer's right), which the axis labels state explicitly.
//

import AppKit
import SwiftUI
import simd

struct MRISliceView: View {
    enum Plane: String, CaseIterable, Identifiable {
        case axial, coronal, sagittal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .axial: return "Axial"
            case .coronal: return "Coronal"
            case .sagittal: return "Sagittal"
            }
        }
        /// Voxel axis held fixed by this plane.
        var fixedAxis: Int { self == .axial ? 2 : (self == .coronal ? 1 : 0) }
        /// (horizontal, vertical) voxel axes of the raster.
        var rasterAxes: (Int, Int) {
            switch self {
            case .axial: return (0, 1)
            case .coronal: return (0, 2)
            case .sagittal: return (1, 2)
            }
        }
        var labels: (left: String, right: String, top: String, bottom: String) {
            switch self {
            case .axial: return ("L", "R", "A", "P")
            case .coronal: return ("L", "R", "S", "I")
            case .sagittal: return ("P", "A", "S", "I")
            }
        }
    }

    let plane: Plane
    @Bindable var controller: HeadModelController
    @Binding var sliceIndex: Int

    var body: some View {
        GeometryReader { geometry in
            let content = sliceContent()
            ZStack {
                Color.black
                if let content {
                    let frame = fitRect(imageSize: content.sizeMillimeters, in: geometry.size)
                    Image(decorative: content.image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    Canvas { context, _ in
                        drawOverlay(context: context, content: content, frame: frame)
                    }
                    .allowsHitTesting(false)
                    axisLabels
                } else {
                    Text(controller.t1 == nil ? "No MRI loaded" : "…").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let content, controller.t1 != nil else { return }
                let frame = fitRect(imageSize: content.sizeMillimeters, in: geometry.size)
                if let world = worldMillimeters(at: location, content: content, frame: frame) {
                    controller.pickFiducial(worldMillimeters: world)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text("\(plane.title)  \(sliceIndex + 1)/\(sliceCount)")
                .font(.caption2.monospacedDigit()).padding(4).foregroundStyle(.white.opacity(0.85))
        }
    }

    private var sliceCount: Int {
        guard let v = controller.t1 else { return 1 }
        return [v.nx, v.ny, v.nz][plane.fixedAxis]
    }

    private var axisLabels: some View {
        let l = plane.labels
        return ZStack {
            VStack { Text(l.top); Spacer(); Text(l.bottom) }
            HStack { Text(l.left); Spacer(); Text(l.right) }
        }
        .font(.caption2.bold()).foregroundStyle(.yellow.opacity(0.8)).padding(6)
        .allowsHitTesting(false)
    }

    // MARK: Slice extraction

    struct SliceContent {
        var image: CGImage
        var width: Int
        var height: Int
        var sizeMillimeters: CGSize
        /// Voxel index of the raster origin (bottom-left in anatomical terms).
        var index: Int
    }

    private func sliceContent() -> SliceContent? {
        guard let v = controller.t1 else { return nil }
        let (ha, va) = plane.rasterAxes
        let dims = [v.nx, v.ny, v.nz]
        let width = dims[ha], height = dims[va]
        let k = min(max(sliceIndex, 0), dims[plane.fixedAxis] - 1)
        let lo = controller.t1Window.min, hi = controller.t1Window.max
        let range = max(hi - lo, 1e-6) / Float(max(controller.brightness, 0.05))
        var pixels = [UInt8](repeating: 0, count: width * height)
        var index = [0, 0, 0]
        index[plane.fixedAxis] = k
        for y in 0..<height {
            index[va] = height - 1 - y  // anatomical positive up
            for x in 0..<width {
                index[ha] = x
                let value = v[index[0], index[1], index[2]]
                let n = (value - lo) / range
                pixels[y * width + x] = UInt8(min(max(n, 0), 1) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let spacing = v.voxelSizeMillimeters
        let size = CGSize(width: Double(width) * spacing[ha], height: Double(height) * spacing[va])
        return SliceContent(image: image, width: width, height: height, sizeMillimeters: size, index: k)
    }

    private func fitRect(imageSize: CGSize, in available: CGSize) -> CGRect {
        let inset: CGFloat = 8
        let w = max(available.width - 2 * inset, 1), h = max(available.height - 2 * inset, 1)
        let scale = min(w / imageSize.width, h / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2, width: size.width, height: size.height)
    }

    // MARK: World ↔ raster

    /// Raster point for a world position (mm); nil when off this slice's plane by
    /// more than `tolerance` mm (returns the in-plane point regardless when
    /// `tolerance` is nil).
    private func rasterPoint(worldMillimeters w: SIMD3<Double>, content: SliceContent, frame: CGRect, tolerance: Double?) -> CGPoint? {
        guard let v = controller.t1 else { return nil }
        let vox = v.worldToVoxel(w)
        let (ha, va) = plane.rasterAxes
        if let tolerance {
            let dk = abs(vox[plane.fixedAxis] - Double(content.index)) * v.voxelSizeMillimeters[plane.fixedAxis]
            if dk > tolerance { return nil }
        }
        let u = (vox[ha] + 0.5) / Double(content.width)
        let t = 1 - (vox[va] + 0.5) / Double(content.height)
        return CGPoint(x: frame.minX + u * frame.width, y: frame.minY + t * frame.height)
    }

    private func worldMillimeters(at p: CGPoint, content: SliceContent, frame: CGRect) -> SIMD3<Double>? {
        guard let v = controller.t1, frame.contains(p) else { return nil }
        let (ha, va) = plane.rasterAxes
        var vox = SIMD3<Double>(repeating: 0)
        vox[ha] = Double((p.x - frame.minX) / frame.width) * Double(content.width) - 0.5
        vox[va] = (1 - Double((p.y - frame.minY) / frame.height)) * Double(content.height) - 0.5
        vox[plane.fixedAxis] = Double(content.index)
        return v.voxelToWorld(vox)
    }

    // MARK: Overlay

    private func drawOverlay(context: GraphicsContext, content: SliceContent, frame: CGRect) {
        guard let v = controller.t1 else { return }
        let mmPerPoint = content.sizeMillimeters.width / frame.width
        // Scalp contour: mesh vertices within half a voxel of the plane.
        if let scalp = controller.scalp {
            let tolerance = v.voxelSizeMillimeters[plane.fixedAxis] * 0.75
            for vertex in scalp.vertices {
                if let p = rasterPoint(worldMillimeters: vertex * 1000, content: content, frame: frame, tolerance: tolerance) {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)), with: .color(.cyan.opacity(0.6)))
                }
            }
        }
        // Electrodes near the plane.
        let residuals = controller.residuals
        for (n, e) in controller.electrodesInMRI.enumerated() {
            guard let p = rasterPoint(worldMillimeters: e * 1000, content: content, frame: frame, tolerance: 4) else { continue }
            let r = residuals?[n] ?? 0
            let color: Color = r < 0.003 ? .green : (r < 0.008 ? .orange : .red)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
        }
        // Fiducials: MRI (solid cross) and electrode-side (hollow circle).
        for kind in HeadModelController.FiducialKind.allCases {
            if let f = controller.mriFiducials[kind], let p = rasterPoint(worldMillimeters: f * 1000, content: content, frame: frame, tolerance: nil) {
                let onPlane = rasterPoint(worldMillimeters: f * 1000, content: content, frame: frame, tolerance: v.voxelSizeMillimeters[plane.fixedAxis] * 1.5) != nil
                var path = Path()
                path.move(to: CGPoint(x: p.x - 7, y: p.y)); path.addLine(to: CGPoint(x: p.x + 7, y: p.y))
                path.move(to: CGPoint(x: p.x, y: p.y - 7)); path.addLine(to: CGPoint(x: p.x, y: p.y + 7))
                context.stroke(path, with: .color(.yellow.opacity(onPlane ? 1 : 0.35)), lineWidth: onPlane ? 2 : 1)
                context.draw(Text(kind.label).font(.caption2).foregroundStyle(.yellow), at: CGPoint(x: p.x + 9, y: p.y - 8))
            }
            if let f = controller.electrodeFiducialsInMRI[kind], let p = rasterPoint(worldMillimeters: f * 1000, content: content, frame: frame, tolerance: 6) {
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.orange), lineWidth: 1.5)
            }
        }
        _ = mmPerPoint
    }
}
