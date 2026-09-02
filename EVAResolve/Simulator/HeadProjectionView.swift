//
//  HeadProjectionView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-3 Stage 1 (tier B) — one orthographic projection of the glass brain. A
//  SwiftUI `Canvas` draws the scalp and brain outlines for a plane, each dipole as
//  a dot with an orientation arrow, and lets the user drag a dipole within the two
//  in-plane axes (the third coordinate is held). Three of these — axial, coronal,
//  sagittal — give full 3D placement without a 3D framework; SceneKit is tier A.
//

import AppKit
import SwiftUI

struct HeadProjectionView: View {
    enum Plane: String, CaseIterable, Identifiable {
        case axial, coronal, sagittal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .axial: return "Axial (top)"
            case .coronal: return "Coronal (front)"
            case .sagittal: return "Sagittal (side)"
            }
        }
        /// The two in-plane axis labels, positive u then positive v.
        var axisLabels: (u: String, v: String) {
            switch self {
            case .axial: return ("R", "A")
            case .coronal: return ("R", "S")
            case .sagittal: return ("A", "S")
            }
        }

        /// In-plane (u, v) meters for a 3-D point.
        func components(_ p: SIMD3<Double>) -> (u: Double, v: Double) {
            switch self {
            case .axial: return (p.x, p.y)
            case .coronal: return (p.x, p.z)
            case .sagittal: return (p.y, p.z)
            }
        }
        /// Write (u, v) meters back into the held 3-D point.
        func apply(u: Double, v: Double, to p: inout SIMD3<Double>) {
            switch self {
            case .axial: p.x = u; p.y = v
            case .coronal: p.x = u; p.z = v
            case .sagittal: p.y = u; p.z = v
            }
        }

        /// The orientation component along this plane's normal (the axis rotation
        /// in this view turns about, held fixed while the in-plane heading changes).
        func normalComponent(_ o: SIMD3<Double>) -> Double {
            switch self {
            case .axial: return o.z
            case .coronal: return o.y
            case .sagittal: return o.x
            }
        }

        /// A unit orientation whose in-plane heading points along `(du, dv)`
        /// (meters-space direction), preserving the out-of-plane tilt — i.e. a
        /// rotation about this plane's normal axis.
        func rotatedOrientation(towards du: Double, _ dv: Double, from current: SIMD3<Double>) -> SIMD3<Double> {
            let length = (du * du + dv * dv).squareRoot()
            guard length > 1e-9 else { return current }
            let out = normalComponent(current)
            let inMagnitude = max(0, 1 - out * out).squareRoot()
            let hu = du / length * inMagnitude
            let hv = dv / length * inMagnitude
            var result = current
            switch self {
            case .axial: result.x = hu; result.y = hv; result.z = out
            case .coronal: result.x = hu; result.z = hv; result.y = out
            case .sagittal: result.y = hu; result.z = hv; result.x = out
            }
            let n = (result.x * result.x + result.y * result.y + result.z * result.z).squareRoot()
            return n > 1e-9 ? result / n : current
        }
    }

    private enum DragMode { case move, rotate }

    let plane: Plane
    @Bindable var controller: SourceSimulatorController

    @State private var draggingID: SourceSimulatorController.Source.ID?
    @State private var dragMode: DragMode = .move

    private let margin: CGFloat = 16

    /// A low-resolution BEM icosphere, cached once and shared by every projection,
    /// drawn as a faint wireframe behind the crisp boundary circle to give the
    /// scalp a translucent glass-brain surface. Same mesh family the BEM solver
    /// uses; subdivision 1 keeps it readable rather than busy.
    private struct Wireframe { let vertices: [SIMD3<Double>]; let edges: [(Int, Int)] }
    private static let unitSphere: Wireframe = {
        let mesh = BEMForwardModel.icosphere(subdivisions: 1)
        var seen = Set<Int>()
        var edges: [(Int, Int)] = []
        for face in mesh.faces {
            for (a, b) in [(face.0, face.1), (face.1, face.2), (face.2, face.0)] {
                let key = min(a, b) * mesh.vertices.count + max(a, b)
                if seen.insert(key).inserted { edges.append((a, b)) }
            }
        }
        return Wireframe(vertices: mesh.vertices, edges: edges)
    }()

    var body: some View {
        // A `Canvas` draw closure is escaping, so accessing observable state inside
        // it does not, on its own, make SwiftUI re-render when that state changes.
        // Touch the state the drawing depends on here in `body` so a scrub (which
        // moves `currentSample`) or a finished fit (`fitResult`) redraws the view.
        _ = controller.currentSample
        _ = controller.fitResult
        _ = controller.showDipoleFit
        _ = controller.showWireframe
        _ = controller.showOutlineCircle
        _ = controller.selectedID
        _ = controller.sources.count
        return VStack(spacing: 2) {
            Text(plane.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                let size = geo.size
                Canvas { context, canvasSize in
                    draw(&context, size: canvasSize)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
                .contextMenu {
                    Button("Fit Dipoles at Playhead") {
                        controller.fitDipoleAtPlayhead()
                    }
                    if controller.showDipoleFit {
                        Button("Hide Dipole Fit") { controller.showDipoleFit = false }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }

    // MARK: Drawing

    private func geometry(for size: CGSize) -> (center: CGPoint, scale: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - margin
        let scale = radius / CGFloat(controller.scalpRadiusMeters)
        return (center, scale)
    }

    private func point(_ u: Double, _ v: Double, center: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(u) * scale, y: center.y - CGFloat(v) * scale)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let (center, scale) = geometry(for: size)
        let scalp = CGFloat(controller.scalpRadiusMeters) * scale
        let brain = CGFloat(controller.brainRadiusMeters) * scale

        // Glass-brain wireframe (BEM icosphere) behind the crisp outline.
        if controller.showWireframe {
            var wire = Path()
            for (a, b) in Self.unitSphere.edges {
                let va = Self.unitSphere.vertices[a] * controller.scalpRadiusMeters
                let vb = Self.unitSphere.vertices[b] * controller.scalpRadiusMeters
                let (au, av) = plane.components(va)
                let (bu, bv) = plane.components(vb)
                wire.move(to: point(au, av, center: center, scale: scale))
                wire.addLine(to: point(bu, bv, center: center, scale: scale))
            }
            context.stroke(wire, with: .color(.secondary.opacity(0.14)), lineWidth: 0.6)
        }

        // Scalp outline + brain shell.
        if controller.showOutlineCircle {
            let scalpRect = CGRect(x: center.x - scalp, y: center.y - scalp, width: scalp * 2, height: scalp * 2)
            context.stroke(Circle().path(in: scalpRect), with: .color(.secondary), lineWidth: 1.5)
            let brainRect = CGRect(x: center.x - brain, y: center.y - brain, width: brain * 2, height: brain * 2)
            context.stroke(Circle().path(in: brainRect), with: .color(.secondary.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // Nose / orientation cue on the anterior-up planes.
        if plane == .axial || plane == .sagittal {
            let apex = point(plane == .axial ? 0 : controller.scalpRadiusMeters * 1.12,
                             plane == .axial ? controller.scalpRadiusMeters * 1.12 : 0,
                             center: center, scale: scale)
            var nose = Path()
            let base: CGFloat = 7
            if plane == .axial {
                nose.move(to: CGPoint(x: apex.x, y: apex.y))
                nose.addLine(to: CGPoint(x: apex.x - base, y: apex.y + base))
                nose.addLine(to: CGPoint(x: apex.x + base, y: apex.y + base))
            } else {
                nose.move(to: CGPoint(x: apex.x, y: apex.y))
                nose.addLine(to: CGPoint(x: apex.x - base, y: apex.y - base))
                nose.addLine(to: CGPoint(x: apex.x - base, y: apex.y + base))
            }
            nose.closeSubpath()
            context.fill(nose, with: .color(.secondary.opacity(0.5)))
        }

        // Axis labels.
        let labels = plane.axisLabels
        context.draw(Text(labels.v).font(.system(size: 9)).foregroundColor(.secondary),
                     at: CGPoint(x: center.x, y: center.y - scalp - 8))
        context.draw(Text(labels.u).font(.system(size: 9)).foregroundColor(.secondary),
                     at: CGPoint(x: center.x + scalp + 8, y: center.y))

        // Sources.
        for source in controller.sources {
            let (u, v) = plane.components(source.positionMeters)
            let p = point(u, v, center: center, scale: scale)
            let selected = source.id == controller.selectedID

            // Orientation arrow.
            let (ou, ov) = plane.components(source.orientationNormalized)
            let arrowLength: CGFloat = 22
            let tip = CGPoint(x: p.x + CGFloat(ou) * arrowLength, y: p.y - CGFloat(ov) * arrowLength)
            var shaft = Path()
            shaft.move(to: p)
            shaft.addLine(to: tip)
            context.stroke(shaft, with: .color(selected ? .accentColor : .orange), lineWidth: 2)
            drawArrowhead(&context, from: p, to: tip, color: selected ? .accentColor : .orange)

            // Dot.
            let dotR: CGFloat = selected ? 6 : 5
            let dotRect = CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2)
            context.fill(Circle().path(in: dotRect), with: .color(selected ? .accentColor : .orange))
            context.stroke(Circle().path(in: dotRect), with: .color(.white.opacity(0.9)), lineWidth: 1)
        }

        // Fitted dipole overlay (Stage 3c localization diagnostic): one purple
        // diamond per fitted dipole, each with a dashed line to its true source.
        if controller.showDipoleFit, let loc = controller.fitResult {
            for pair in loc.pairs {
                drawFittedDipole(&context, pair: pair, center: center, scale: scale)
            }
        }
    }

    /// Draws one fitted dipole: a purple diamond with an orientation arrow at the
    /// fitted position, and a dashed "error" line to the paired true source so the
    /// localization error is visible, not just a number in the inspector.
    private func drawFittedDipole(
        _ context: inout GraphicsContext,
        pair: SingleDipoleFit.MultiLocalization.Pair,
        center: CGPoint, scale: CGFloat
    ) {
        let fitColor = Color.purple
        let fitPosition = SIMD3<Double>(
            pair.fit.positionMeters.x, pair.fit.positionMeters.y, pair.fit.positionMeters.z)
        let (fu, fv) = plane.components(fitPosition)
        let fp = point(fu, fv, center: center, scale: scale)

        // Error line from the true source to the fit.
        if let truth = pair.truePositionMeters {
            let truePosition = SIMD3<Double>(truth.x, truth.y, truth.z)
            let (tu, tv) = plane.components(truePosition)
            let tp = point(tu, tv, center: center, scale: scale)
            var errorLine = Path()
            errorLine.move(to: tp)
            errorLine.addLine(to: fp)
            context.stroke(errorLine, with: .color(fitColor.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }

        // Orientation arrow.
        let orientation = SIMD3<Double>(
            pair.fit.orientationUnit.x, pair.fit.orientationUnit.y, pair.fit.orientationUnit.z)
        let (ou, ov) = plane.components(orientation)
        let arrowLength: CGFloat = 20
        let tip = CGPoint(x: fp.x + CGFloat(ou) * arrowLength, y: fp.y - CGFloat(ov) * arrowLength)
        var shaft = Path()
        shaft.move(to: fp)
        shaft.addLine(to: tip)
        context.stroke(shaft, with: .color(fitColor), lineWidth: 2)
        drawArrowhead(&context, from: fp, to: tip, color: fitColor)

        // A hollow diamond marks the fit, distinct from the filled source dots.
        let r: CGFloat = 6
        var diamond = Path()
        diamond.move(to: CGPoint(x: fp.x, y: fp.y - r))
        diamond.addLine(to: CGPoint(x: fp.x + r, y: fp.y))
        diamond.addLine(to: CGPoint(x: fp.x, y: fp.y + r))
        diamond.addLine(to: CGPoint(x: fp.x - r, y: fp.y))
        diamond.closeSubpath()
        context.fill(diamond, with: .color(Color(nsColor: .textBackgroundColor)))
        context.stroke(diamond, with: .color(fitColor), lineWidth: 2)
    }

    private func drawArrowhead(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let size: CGFloat = 6
        var head = Path()
        head.move(to: to)
        head.addLine(to: CGPoint(x: to.x - size * cos(angle - .pi / 6), y: to.y - size * sin(angle - .pi / 6)))
        head.addLine(to: CGPoint(x: to.x - size * cos(angle + .pi / 6), y: to.y - size * sin(angle + .pi / 6)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    // MARK: Interaction

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let (center, scale) = geometry(for: size)
                if draggingID == nil {
                    draggingID = nearestSource(to: value.startLocation, center: center, scale: scale)
                    // ⌥ at grab time means "rotate the arrow" instead of "move".
                    dragMode = NSEvent.modifierFlags.contains(.option) ? .rotate : .move
                }
                guard let id = draggingID,
                      let index = controller.sources.firstIndex(where: { $0.id == id }) else { return }
                controller.selectedID = id
                let u = Double((value.location.x - center.x) / scale)
                let v = Double((center.y - value.location.y) / scale)

                switch dragMode {
                case .move:
                    var position = controller.sources[index].positionMeters
                    plane.apply(u: u, v: v, to: &position)
                    controller.sources[index].positionMeters = controller.clampInsideBrain(position)
                case .rotate:
                    // Point the arrow from the dipole toward the cursor, in-plane.
                    let (su, sv) = plane.components(controller.sources[index].positionMeters)
                    controller.sources[index].orientationUnit = plane.rotatedOrientation(
                        towards: u - su, v - sv, from: controller.sources[index].orientationUnit
                    )
                }
            }
            .onEnded { _ in draggingID = nil }
    }

    private func nearestSource(to location: CGPoint, center: CGPoint, scale: CGFloat) -> SourceSimulatorController.Source.ID? {
        var best: (id: SourceSimulatorController.Source.ID, distance: CGFloat)?
        for source in controller.sources {
            let (u, v) = plane.components(source.positionMeters)
            let p = point(u, v, center: center, scale: scale)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d < 18, best == nil || d < best!.distance { best = (source.id, d) }
        }
        return best?.id
    }
}
