//
//  HeadSilhouette.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A schematic anatomical head outline for each of the three orthographic
//  projection planes — axial (top), coronal (front), sagittal (side) — in the
//  clean line-art style of a generic head icon (rounded skull, nose, lips, chin,
//  ears, and a neck on the front/side views). It replaces the plain scalp circle
//  in the glass-brain projections with a recognizable head while the inner brain
//  shell stays a circle: a sphere's silhouette is a circle from every angle, so
//  the analytic spherical forward geometry is drawn honestly and only the outer
//  head reads differently per view. It is decoration for orientation, not
//  geometry — the forward model and dipole clamping are unchanged.
//
//  Paths are authored in a fixed "box space": +u right, +v up, roughly filling
//  [-1, 1]². Because a realistic head-with-neck is taller than the brain sphere,
//  the sphere is not centred in the box — each plane's `layout` says where the
//  cranium centre sits and how big it is, so callers seat the brain circle and the
//  dipoles inside the skull and let the neck hang below (see `HeadProjectionView`
//  and `FitProjectionView`).
//

import CoreGraphics
import SwiftUI

/// Anatomical silhouette used only to orient the spherical source-model display.
/// It does not alter the forward model, electrode geometry, or dipole fit.
enum HeadModelSex: String, CaseIterable, Identifiable, Sendable {
    case female
    case male

    static let preferenceKey = "resolve.headModelSex"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .female: "Female"
        case .male: "Male"
        }
    }
}

enum HeadSilhouette {

    /// The exact approved illustration asset for this presentation and view.
    /// The assets have a transparent background so the simulator's dipoles and
    /// dashed spherical brain shell remain visible above them on either theme.
    static func assetName(for plane: HeadProjectionView.Plane, sex: HeadModelSex) -> String {
        let sexName = sex == .female ? "Female" : "Male"
        let planeName: String
        switch plane {
        case .axial: planeName = "Axial"
        case .coronal: planeName = "Coronal"
        case .sagittal: planeName = "Sagittal"
        }
        return "HeadSilhouette\(sexName)\(planeName)"
    }

    /// Where the cranium (and thus the brain sphere) sits within the box, and its
    /// radius, both in box units. `center.y` is +up. Callers map the brain circle
    /// and dipoles to `boxCenter + (center.x, −center.y)·half` at a scale where the
    /// scalp radius equals `radius·half`.
    struct Layout {
        var center: CGPoint
        var radius: CGFloat
    }

    static func layout(for plane: HeadProjectionView.Plane) -> Layout {
        switch plane {
        case .axial:
            return Layout(center: CGPoint(x: 0, y: 0), radius: 0.85)
        case .coronal:
            // The source artwork's cranium is much larger than the original
            // schematic path. Seat the spherical scalp shell in that cranial
            // volume, rather than leaving it above the brows as a small globe.
            return Layout(center: CGPoint(x: 0, y: 0.12), radius: 0.80)
        case .sagittal:
            return Layout(center: CGPoint(x: 0, y: 0.12), radius: 0.82)
        }
    }

    /// The affine map from box space (+v up) to screen: `screen = boxCenter +
    /// (u·half, −v·half)`, where `half` is the box's on-screen half-size.
    static func transform(center boxCenter: CGPoint, radius half: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: half, b: 0, c: 0, d: -half, tx: boxCenter.x, ty: boxCenter.y)
    }

    /// The full head outline for a plane (skull, face, jaw, neck, nose, ears) as a
    /// closed smooth curve in box space, plus an ear detail where it reads clearly.
    /// Stroke it after `.applying(transform(center:radius:))`.
    static func path(for plane: HeadProjectionView.Plane, sex: HeadModelSex) -> Path {
        var path = closedCurve(through: controlPoints(for: plane, sex: sex))
        path.addPath(details(for: plane, sex: sex))
        return path
    }

    // MARK: Control points per plane (box space, +v up)

    private static func controlPoints(for plane: HeadProjectionView.Plane, sex: HeadModelSex) -> [CGPoint] {
        switch plane {
        case .axial:
            // Top-down: an egg, longer front-to-back than wide, with a small nose
            // bump at anterior (+v). Ears are separate arcs in `details`.
            return [
                CGPoint(x: 0.000, y: 1.05),   // nose (anterior)
                CGPoint(x: 0.090, y: 0.98),
                CGPoint(x: 0.260, y: 0.93),
                CGPoint(x: 0.460, y: 0.84),
                CGPoint(x: 0.620, y: 0.68),
                CGPoint(x: 0.715, y: 0.46),
                CGPoint(x: 0.755, y: 0.20),
                CGPoint(x: 0.755, y: -0.06),
                CGPoint(x: 0.720, y: -0.32),
                CGPoint(x: 0.645, y: -0.56),
                CGPoint(x: 0.530, y: -0.76),
                CGPoint(x: 0.370, y: -0.90),
                CGPoint(x: 0.190, y: -0.98),
                CGPoint(x: 0.000, y: -1.00),  // occiput
                CGPoint(x: -0.190, y: -0.98),
                CGPoint(x: -0.370, y: -0.90),
                CGPoint(x: -0.530, y: -0.76),
                CGPoint(x: -0.645, y: -0.56),
                CGPoint(x: -0.720, y: -0.32),
                CGPoint(x: -0.755, y: -0.06),
                CGPoint(x: -0.755, y: 0.20),
                CGPoint(x: -0.715, y: 0.46),
                CGPoint(x: -0.620, y: 0.68),
                CGPoint(x: -0.460, y: 0.84),
                CGPoint(x: -0.260, y: 0.93),
                CGPoint(x: -0.090, y: 0.98),
            ]
        case .coronal:
            if sex == .female { return femaleCoronalControlPoints }
            // Front: the face oval only — crown, temples, cheekbones, jaw and a
            // rounded chin. The ears and neck are separate strokes in `details`,
            // which is what makes it read as a head rather than an egg.
            return [
                CGPoint(x: 0.000, y: 0.950),   // crown
                CGPoint(x: 0.160, y: 0.925),
                CGPoint(x: 0.300, y: 0.865),
                CGPoint(x: 0.385, y: 0.755),
                CGPoint(x: 0.425, y: 0.600),   // temple
                CGPoint(x: 0.440, y: 0.420),   // widest
                CGPoint(x: 0.435, y: 0.240),
                CGPoint(x: 0.415, y: 0.080),
                CGPoint(x: 0.385, y: -0.060),  // cheekbone
                CGPoint(x: 0.350, y: -0.190),
                CGPoint(x: 0.300, y: -0.310),  // cheek
                CGPoint(x: 0.235, y: -0.400),  // jaw
                CGPoint(x: 0.150, y: -0.455),
                CGPoint(x: 0.070, y: -0.480),
                CGPoint(x: 0.000, y: -0.485),  // chin
                CGPoint(x: -0.070, y: -0.480),
                CGPoint(x: -0.150, y: -0.455),
                CGPoint(x: -0.235, y: -0.400),
                CGPoint(x: -0.300, y: -0.310),
                CGPoint(x: -0.350, y: -0.190),
                CGPoint(x: -0.385, y: -0.060),
                CGPoint(x: -0.415, y: 0.080),
                CGPoint(x: -0.435, y: 0.240),
                CGPoint(x: -0.440, y: 0.420),
                CGPoint(x: -0.425, y: 0.600),
                CGPoint(x: -0.385, y: 0.755),
                CGPoint(x: -0.300, y: 0.865),
                CGPoint(x: -0.160, y: 0.925),
            ]
        case .sagittal:
            if sex == .female { return femaleSagittalControlPoints }
            // Side, facing +u (anterior): crown, forehead, brow, the nasion dip,
            // nose, lips, chin, jaw and neck, then a full round occiput. The ear
            // is added by `details`.
            return [
                CGPoint(x: 0.050, y: 0.950),    // crown
                CGPoint(x: 0.260, y: 0.920),
                CGPoint(x: 0.420, y: 0.820),
                CGPoint(x: 0.530, y: 0.660),
                CGPoint(x: 0.585, y: 0.480),    // forehead
                CGPoint(x: 0.605, y: 0.340),    // brow ridge
                CGPoint(x: 0.575, y: 0.260),    // nasion
                CGPoint(x: 0.600, y: 0.190),    // nose bridge
                CGPoint(x: 0.635, y: 0.090),
                CGPoint(x: 0.665, y: -0.020),   // nose tip
                CGPoint(x: 0.585, y: -0.060),   // under the nose
                CGPoint(x: 0.600, y: -0.115),   // philtrum
                CGPoint(x: 0.615, y: -0.145),   // upper lip
                CGPoint(x: 0.575, y: -0.175),   // mouth
                CGPoint(x: 0.600, y: -0.215),   // lower lip
                CGPoint(x: 0.555, y: -0.265),   // chin crease
                CGPoint(x: 0.545, y: -0.340),   // chin
                CGPoint(x: 0.485, y: -0.415),   // under chin
                CGPoint(x: 0.360, y: -0.470),   // jaw
                CGPoint(x: 0.200, y: -0.500),   // jaw angle
                CGPoint(x: 0.060, y: -0.500),   // below the ear
                CGPoint(x: 0.020, y: -0.620),   // throat
                CGPoint(x: 0.000, y: -0.800),   // neck (front)
                CGPoint(x: 0.000, y: -1.000),
                CGPoint(x: -0.420, y: -1.000),  // neck (back)
                CGPoint(x: -0.400, y: -0.800),
                CGPoint(x: -0.420, y: -0.620),  // nape
                CGPoint(x: -0.480, y: -0.440),
                CGPoint(x: -0.550, y: -0.220),
                CGPoint(x: -0.600, y: 0.050),   // occiput
                CGPoint(x: -0.570, y: 0.360),
                CGPoint(x: -0.460, y: 0.620),
                CGPoint(x: -0.300, y: 0.820),
                CGPoint(x: -0.120, y: 0.920),
            ]
        }
    }

    /// Strokes drawn alongside the main outline: the ears (as their own arcs, the
    /// way a head icon draws them) and, on the front view, the neck.
    private static func details(for plane: HeadProjectionView.Plane, sex: HeadModelSex) -> Path {
        var path = Path()
        switch plane {
        case .axial:
            path.addPath(ellipse(cx: 0.80, cy: -0.02, rx: 0.05, ry: 0.17))
            path.addPath(ellipse(cx: -0.80, cy: -0.02, rx: 0.05, ry: 0.17))
        case .coronal:
            let earX: CGFloat = sex == .female ? 0.410 : 0.445
            let earY: CGFloat = sex == .female ? 0.085 : 0.10
            let earRX: CGFloat = sex == .female ? 0.050 : 0.055
            let earRY: CGFloat = sex == .female ? 0.135 : 0.145
            path.addPath(ellipse(cx: earX, cy: earY, rx: earRX, ry: earRY))
            path.addPath(ellipse(cx: -earX, cy: earY, rx: earRX, ry: earRY))
            path.addPath(neck(mirrored: false, sex: sex))
            path.addPath(neck(mirrored: true, sex: sex))
            path.addPath(frontalFeatures(sex: sex))
        case .sagittal:
            path.addPath(ellipse(cx: sex == .female ? -0.08 : -0.10,
                                 cy: sex == .female ? 0.04 : 0.02,
                                 rx: sex == .female ? 0.068 : 0.075,
                                 ry: sex == .female ? 0.145 : 0.155))
            path.addPath(profileFeatures(sex: sex))
        }
        return path
    }

    /// Deliberately sparse facial landmarks make the coronal view read as a
    /// person rather than a scalp oval, while leaving the upper cranium clear for
    /// dipole markers. These are orientation cues, never anatomical geometry.
    private static func frontalFeatures(sex: HeadModelSex) -> Path {
        var path = Path()
        let eyeY: CGFloat = sex == .female ? 0.245 : 0.235
        let eyeX: CGFloat = sex == .female ? 0.155 : 0.165
        let eyeWidth: CGFloat = sex == .female ? 0.075 : 0.070
        let eyeHeight: CGFloat = sex == .female ? 0.030 : 0.025
        let browLift: CGFloat = sex == .female ? 0.085 : 0.075

        path.addPath(brow(centerX: -eyeX, y: eyeY + browLift, width: eyeWidth * 1.35, arch: sex == .female ? 0.020 : 0.012))
        path.addPath(brow(centerX: eyeX, y: eyeY + browLift, width: eyeWidth * 1.35, arch: sex == .female ? 0.020 : 0.012))
        path.addPath(eye(centerX: -eyeX, y: eyeY, width: eyeWidth, height: eyeHeight))
        path.addPath(eye(centerX: eyeX, y: eyeY, width: eyeWidth, height: eyeHeight))

        // A short bridge and soft nostril cue; no fill so this remains light
        // enough for a head-model overlay.
        path.move(to: CGPoint(x: -0.018, y: eyeY - 0.025))
        path.addCurve(to: CGPoint(x: -0.028, y: 0.015),
                      control1: CGPoint(x: -0.030, y: 0.145),
                      control2: CGPoint(x: -0.040, y: 0.065))
        path.addCurve(to: CGPoint(x: 0.000, y: -0.002),
                      control1: CGPoint(x: -0.022, y: -0.005),
                      control2: CGPoint(x: -0.010, y: -0.010))
        path.addCurve(to: CGPoint(x: 0.028, y: 0.015),
                      control1: CGPoint(x: 0.010, y: -0.010),
                      control2: CGPoint(x: 0.022, y: -0.005))
        path.addCurve(to: CGPoint(x: 0.018, y: eyeY - 0.025),
                      control1: CGPoint(x: 0.040, y: 0.065),
                      control2: CGPoint(x: 0.030, y: 0.145))

        let mouthY: CGFloat = sex == .female ? -0.205 : -0.215
        let mouthHalf: CGFloat = sex == .female ? 0.105 : 0.090
        path.move(to: CGPoint(x: -mouthHalf, y: mouthY))
        path.addCurve(to: CGPoint(x: 0, y: mouthY + (sex == .female ? 0.010 : 0.004)),
                      control1: CGPoint(x: -mouthHalf * 0.55, y: mouthY + 0.010),
                      control2: CGPoint(x: -mouthHalf * 0.20, y: mouthY + 0.010))
        path.addCurve(to: CGPoint(x: mouthHalf, y: mouthY),
                      control1: CGPoint(x: mouthHalf * 0.20, y: mouthY + 0.010),
                      control2: CGPoint(x: mouthHalf * 0.55, y: mouthY + 0.010))
        return path
    }

    /// A single eye/brow in profile is enough to orient the sagittal head while
    /// its large interior remains visually empty for fitted sources.
    private static func profileFeatures(sex: HeadModelSex) -> Path {
        var path = Path()
        let x: CGFloat = sex == .female ? 0.495 : 0.515
        let y: CGFloat = 0.245
        path.addPath(brow(centerX: x, y: y + 0.070, width: sex == .female ? 0.085 : 0.090,
                           arch: sex == .female ? 0.018 : 0.010))
        path.move(to: CGPoint(x: x - 0.055, y: y))
        path.addCurve(to: CGPoint(x: x + 0.045, y: y),
                      control1: CGPoint(x: x - 0.025, y: y + 0.022),
                      control2: CGPoint(x: x + 0.020, y: y + 0.022))
        path.addCurve(to: CGPoint(x: x - 0.055, y: y),
                      control1: CGPoint(x: x + 0.018, y: y - 0.015),
                      control2: CGPoint(x: x - 0.028, y: y - 0.015))
        path.addPath(ellipse(cx: x + 0.002, cy: y + 0.002, rx: 0.010, ry: 0.012))
        return path
    }

    private static func brow(centerX: CGFloat, y: CGFloat, width: CGFloat, arch: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: centerX - width, y: y))
        path.addCurve(to: CGPoint(x: centerX + width, y: y),
                      control1: CGPoint(x: centerX - width * 0.40, y: y + arch),
                      control2: CGPoint(x: centerX + width * 0.40, y: y + arch))
        return path
    }

    private static func eye(centerX: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: centerX - width, y: y))
        path.addCurve(to: CGPoint(x: centerX + width, y: y),
                      control1: CGPoint(x: centerX - width * 0.42, y: y + height),
                      control2: CGPoint(x: centerX + width * 0.42, y: y + height))
        path.addCurve(to: CGPoint(x: centerX - width, y: y),
                      control1: CGPoint(x: centerX + width * 0.42, y: y - height * 0.75),
                      control2: CGPoint(x: centerX - width * 0.42, y: y - height * 0.75))
        path.addPath(ellipse(cx: centerX, cy: y, rx: height * 0.58, ry: height * 0.72))
        return path
    }

    /// One side of the front view's neck: down from behind the jaw, flaring out
    /// into the shoulder line.
    private static func neck(mirrored: Bool, sex: HeadModelSex) -> Path {
        let s: CGFloat = mirrored ? -1 : 1
        let jaw: CGFloat = sex == .female ? 0.180 : 0.215
        let shoulder: CGFloat = sex == .female ? 0.275 : 0.310
        var path = Path()
        path.move(to: CGPoint(x: s * jaw, y: -0.415))
        path.addCurve(to: CGPoint(x: s * jaw, y: -0.850),
                      control1: CGPoint(x: s * jaw, y: -0.580),
                      control2: CGPoint(x: s * jaw, y: -0.710))
        path.addCurve(to: CGPoint(x: s * shoulder, y: -1.000),
                      control1: CGPoint(x: s * jaw, y: -0.930),
                      control2: CGPoint(x: s * (jaw + shoulder) / 2, y: -0.970))
        return path
    }

    /// A subtly more oval, tapered adult female face. Keeping the skull volume
    /// nearly identical means switching presentation never moves a dipole or
    /// changes the spherical analytic geometry beneath it.
    private static let femaleCoronalControlPoints: [CGPoint] = [
        CGPoint(x: 0.000, y: 0.950), CGPoint(x: 0.155, y: 0.925),
        CGPoint(x: 0.285, y: 0.865), CGPoint(x: 0.365, y: 0.755),
        CGPoint(x: 0.400, y: 0.600), CGPoint(x: 0.415, y: 0.420),
        CGPoint(x: 0.405, y: 0.240), CGPoint(x: 0.380, y: 0.080),
        CGPoint(x: 0.345, y: -0.075), CGPoint(x: 0.300, y: -0.210),
        CGPoint(x: 0.240, y: -0.325), CGPoint(x: 0.165, y: -0.410),
        CGPoint(x: 0.085, y: -0.462), CGPoint(x: 0.000, y: -0.480),
        CGPoint(x: -0.085, y: -0.462), CGPoint(x: -0.165, y: -0.410),
        CGPoint(x: -0.240, y: -0.325), CGPoint(x: -0.300, y: -0.210),
        CGPoint(x: -0.345, y: -0.075), CGPoint(x: -0.380, y: 0.080),
        CGPoint(x: -0.405, y: 0.240), CGPoint(x: -0.415, y: 0.420),
        CGPoint(x: -0.400, y: 0.600), CGPoint(x: -0.365, y: 0.755),
        CGPoint(x: -0.285, y: 0.865), CGPoint(x: -0.155, y: 0.925),
    ]

    /// Side view with the same cranium, plus a softer brow, smaller nose and
    /// rounded chin. No cosmetic details are encoded in a scientific overlay.
    private static let femaleSagittalControlPoints: [CGPoint] = [
        CGPoint(x: 0.040, y: 0.950), CGPoint(x: 0.245, y: 0.920),
        CGPoint(x: 0.400, y: 0.820), CGPoint(x: 0.500, y: 0.660),
        CGPoint(x: 0.545, y: 0.480), CGPoint(x: 0.555, y: 0.340),
        CGPoint(x: 0.530, y: 0.260), CGPoint(x: 0.548, y: 0.185),
        CGPoint(x: 0.575, y: 0.090), CGPoint(x: 0.600, y: -0.005),
        CGPoint(x: 0.535, y: -0.055), CGPoint(x: 0.545, y: -0.110),
        CGPoint(x: 0.575, y: -0.145), CGPoint(x: 0.545, y: -0.180),
        CGPoint(x: 0.575, y: -0.220), CGPoint(x: 0.535, y: -0.275),
        CGPoint(x: 0.520, y: -0.340), CGPoint(x: 0.460, y: -0.410),
        CGPoint(x: 0.330, y: -0.465), CGPoint(x: 0.180, y: -0.495),
        CGPoint(x: 0.040, y: -0.495), CGPoint(x: 0.000, y: -0.620),
        CGPoint(x: -0.010, y: -0.800), CGPoint(x: -0.010, y: -1.000),
        CGPoint(x: -0.380, y: -1.000), CGPoint(x: -0.370, y: -0.800),
        CGPoint(x: -0.395, y: -0.620), CGPoint(x: -0.455, y: -0.440),
        CGPoint(x: -0.525, y: -0.220), CGPoint(x: -0.575, y: 0.050),
        CGPoint(x: -0.545, y: 0.360), CGPoint(x: -0.440, y: 0.620),
        CGPoint(x: -0.285, y: 0.820), CGPoint(x: -0.110, y: 0.920),
    ]

    private static func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    // MARK: Smooth closed curve (uniform Catmull-Rom → cubic Bézier)

    /// A closed smooth curve interpolating `points`, converted to cubic Béziers so
    /// the outline is round rather than a polygon. Uniform Catmull-Rom with the
    /// standard 1/6 tangent scaling; wrap-around indexing closes the loop.
    private static func closedCurve(through points: [CGPoint]) -> Path {
        var path = Path()
        let n = points.count
        guard n >= 3 else {
            if let first = points.first {
                path.move(to: first)
                for p in points.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
            return path
        }
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n]
            let p1 = points[i]
            let p2 = points[(i + 1) % n]
            let p3 = points[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }
}
