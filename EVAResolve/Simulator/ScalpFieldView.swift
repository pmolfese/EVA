//
//  ScalpFieldView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-2 Stage 1 — the live scalp field. Renders the forward topography the
//  current dipoles produce (`SourceSimulatorController.scalpPotentials()`), so as
//  a source is dragged in the glass brain the scalp map updates in step. A compact
//  inverse-distance interpolation over the azimuthal electrode layout; the shared
//  topomap renderers assume an MFF-backed `SensorLayout`, which this parametric
//  montage does not have.
//

import SwiftUI

struct ScalpFieldView: View {
    @Bindable var controller: SourceSimulatorController

    private let margin: CGFloat = 18
    private let gridStep: CGFloat = 5

    var body: some View {
        let potentials = controller.scalpPotentials()
        let electrodes = controller.electrodeDisc()

        VStack(spacing: 4) {
            Text("Scalp field").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Canvas { context, size in
                guard let potentials, potentials.count == electrodes.count, !electrodes.isEmpty else {
                    let text = Text("No field — source outside the brain shell.")
                        .font(.caption2).foregroundColor(.secondary)
                    context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }
                draw(&context, size: size, electrodes: electrodes, potentials: potentials)
            }
            .aspectRatio(1, contentMode: .fit)
            if let potentials, let peak = potentials.map(abs).max() {
                Text(String(format: "peak ±%.1f µV", peak))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, electrodes: [(name: String, point: CGPoint)], potentials: [Double]) {
        let displayRadius = max(1.0, electrodes.map { hypot($0.point.x, $0.point.y) }.max() ?? 1.0)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let pixelRadius = min(size.width, size.height) / 2 - margin
        let scale = pixelRadius / CGFloat(displayRadius)

        func toScreen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: center.x + p.x * scale, y: center.y - p.y * scale)
        }

        let peak = max(potentials.map(abs).max() ?? 0, 1e-9)

        // Interpolated field, clipped to the scalp circle.
        let headRect = CGRect(x: center.x - pixelRadius, y: center.y - pixelRadius,
                              width: pixelRadius * 2, height: pixelRadius * 2)
        context.clip(to: Circle().path(in: headRect))
        var x = center.x - pixelRadius
        while x <= center.x + pixelRadius {
            var y = center.y - pixelRadius
            while y <= center.y + pixelRadius {
                // Convert pixel back to disc coords for interpolation.
                let du = Double((x - center.x) / scale)
                let dv = Double((center.y - y) / scale)
                let value = interpolate(at: CGPoint(x: du, y: dv), electrodes: electrodes, potentials: potentials)
                let cell = CGRect(x: x, y: y, width: gridStep, height: gridStep)
                context.fill(Path(cell), with: .color(color(for: value / peak)))
                y += gridStep
            }
            x += gridStep
        }

        // Head outline + nose.
        context.stroke(Circle().path(in: headRect), with: .color(.secondary), lineWidth: 1.5)
        var nose = Path()
        let top = CGPoint(x: center.x, y: center.y - pixelRadius)
        nose.move(to: CGPoint(x: top.x, y: top.y - 8))
        nose.addLine(to: CGPoint(x: top.x - 7, y: top.y + 1))
        nose.addLine(to: CGPoint(x: top.x + 7, y: top.y + 1))
        nose.closeSubpath()
        context.fill(nose, with: .color(.secondary))

        // Electrodes.
        for electrode in electrodes {
            let p = toScreen(electrode.point)
            let r: CGFloat = 1.6
            context.fill(Circle().path(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(.primary.opacity(0.55)))
        }
    }

    /// Inverse-distance-weighted interpolation of the electrode potentials.
    private func interpolate(at point: CGPoint, electrodes: [(name: String, point: CGPoint)], potentials: [Double]) -> Double {
        var weightedSum = 0.0
        var weightTotal = 0.0
        for (index, electrode) in electrodes.enumerated() {
            let dx = Double(point.x - electrode.point.x)
            let dy = Double(point.y - electrode.point.y)
            let d2 = dx * dx + dy * dy
            if d2 < 1e-6 { return potentials[index] }
            let weight = 1.0 / (d2 * d2) // inverse 4th power → crisper peaks
            weightedSum += weight * potentials[index]
            weightTotal += weight
        }
        return weightTotal > 0 ? weightedSum / weightTotal : 0
    }

    /// Diverging blue–white–red map for a normalized value in [-1, 1].
    private func color(for normalized: Double) -> Color {
        let t = max(-1, min(1, normalized))
        let a = abs(t)
        let (r, g, b): (Double, Double, Double) = t >= 0 ? (0.85, 0.15, 0.15) : (0.15, 0.3, 0.85)
        return Color(red: 1 - (1 - r) * a, green: 1 - (1 - g) * a, blue: 1 - (1 - b) * a)
    }
}
