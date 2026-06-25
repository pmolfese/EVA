//
//  TopomapView.swift
//  EEGView
//
//  Top-down scalp topography for a single time point. Draws a head outline
//  (circle + nose + ears) with an inverse-distance-weighted interpolation of
//  the per-electrode potential, plus electrode markers and a colorbar.
//

import SwiftUI

enum TopomapColorBarPlacement {
    case bottom
    case trailing
}

struct TopomapView: View {
    let layout: SensorLayout
    /// Per-channel potential (µV) at the chosen sample, indexed by channel.
    let values: [Double]
    let timeSeconds: Double
    /// When non-nil, fixes the symmetric color scale to ±this value (µV).
    /// When nil, the scale auto-fits to the data at this time point.
    let fixedScale: Double?
    let unitLabel: String
    let showsHeader: Bool
    let colorBarPlacement: TopomapColorBarPlacement
    let minimumMapHeight: CGFloat

    init(
        layout: SensorLayout,
        values: [Double],
        timeSeconds: Double,
        fixedScale: Double?,
        unitLabel: String = "µV",
        showsHeader: Bool = true,
        colorBarPlacement: TopomapColorBarPlacement = .bottom,
        minimumMapHeight: CGFloat = 260
    ) {
        self.layout = layout
        self.values = values
        self.timeSeconds = timeSeconds
        self.fixedScale = fixedScale
        self.unitLabel = unitLabel
        self.showsHeader = showsHeader
        self.colorBarPlacement = colorBarPlacement
        self.minimumMapHeight = minimumMapHeight
    }

    private let interpolationPower: Double = 3

    var body: some View {
        VStack(spacing: 12) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline) {
                    Text(layout.name.isEmpty ? "Topography" : layout.name)
                        .font(.headline)
                    Spacer()
                    Text(String(format: "t = %.3f s", timeSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if colorBarPlacement == .trailing {
                HStack(spacing: 10) {
                    mapCanvas
                    verticalColorBar
                }
            } else {
                mapCanvas
                horizontalColorBar
            }
        }
        .padding(16)
    }

    private var mapCanvas: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: minimumMapHeight)
    }

    private var scale: Double {
        if let fixedScale, fixedScale > 0 {
            return fixedScale
        }
        let maxAbs = activeSensors
            .compactMap { value(for: $0) }
            .map(abs)
            .max() ?? 1
        return maxAbs > 0 ? maxAbs : 1
    }

    private var activeSensors: [SensorPosition] {
        layout.positions.filter { $0.channelIndex < values.count }
    }

    private func value(for sensor: SensorPosition) -> Double? {
        guard sensor.channelIndex < values.count else { return nil }
        return values[sensor.channelIndex]
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Leave a margin so nose/ears stay inside the canvas.
        let radius = min(size.width, size.height) / 2 * 0.86
        let currentScale = scale

        let sensors = activeSensors
        let points: [(point: CGPoint, value: Double)] = sensors.compactMap { sensor in
            guard let v = value(for: sensor) else { return nil }
            // +y is anterior; screen y grows downward, so flip y.
            let p = CGPoint(
                x: center.x + CGFloat(sensor.x) * radius,
                y: center.y - CGFloat(sensor.y) * radius
            )
            return (p, v)
        }

        drawInterpolatedField(
            in: &context,
            center: center,
            radius: radius,
            points: points,
            scale: currentScale
        )

        // Clip the head circle outline on top of the field.
        let headRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.stroke(Path(ellipseIn: headRect), with: .color(.primary.opacity(0.7)), lineWidth: 2)

        drawNoseAndEars(in: &context, center: center, radius: radius)

        // Electrode markers.
        for (point, _) in points {
            let dot = CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2)
            context.fill(Path(ellipseIn: dot), with: .color(.black.opacity(0.55)))
        }
    }

    private func drawInterpolatedField(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        points: [(point: CGPoint, value: Double)],
        scale: Double
    ) {
        guard !points.isEmpty else { return }

        let step: CGFloat = 4
        let radiusSquared = radius * radius

        var x = center.x - radius
        while x <= center.x + radius {
            var y = center.y - radius
            while y <= center.y + radius {
                let dx = x - center.x
                let dy = y - center.y
                if dx * dx + dy * dy <= radiusSquared {
                    let interpolated = idwValue(at: CGPoint(x: x, y: y), points: points)
                    let color = divergingColor(forNormalized: interpolated / scale)
                    let cell = CGRect(x: x, y: y, width: step, height: step)
                    context.fill(Path(cell), with: .color(color))
                }
                y += step
            }
            x += step
        }
    }

    private func idwValue(at location: CGPoint, points: [(point: CGPoint, value: Double)]) -> Double {
        var weightedSum = 0.0
        var weightTotal = 0.0

        for (point, value) in points {
            let dx = Double(location.x - point.x)
            let dy = Double(location.y - point.y)
            let distanceSquared = dx * dx + dy * dy

            if distanceSquared < 0.5 {
                return value
            }

            let weight = 1.0 / pow(distanceSquared, interpolationPower / 2)
            weightedSum += weight * value
            weightTotal += weight
        }

        return weightTotal > 0 ? weightedSum / weightTotal : 0
    }

    private func drawNoseAndEars(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let strokeColor = GraphicsContext.Shading.color(.primary.opacity(0.7))

        // Nose: small triangle pointing up.
        var nose = Path()
        let noseHalfWidth = radius * 0.12
        let noseHeight = radius * 0.12
        nose.move(to: CGPoint(x: center.x - noseHalfWidth, y: center.y - radius + 1))
        nose.addLine(to: CGPoint(x: center.x, y: center.y - radius - noseHeight))
        nose.addLine(to: CGPoint(x: center.x + noseHalfWidth, y: center.y - radius + 1))
        context.stroke(nose, with: strokeColor, lineWidth: 2)

        // Ears: small arcs on each side.
        let earHeight = radius * 0.3
        let earWidth = radius * 0.09
        for side in [-1.0, 1.0] {
            var ear = Path()
            let baseX = center.x + CGFloat(side) * radius
            ear.move(to: CGPoint(x: baseX, y: center.y - earHeight / 2))
            ear.addCurve(
                to: CGPoint(x: baseX, y: center.y + earHeight / 2),
                control1: CGPoint(x: baseX + CGFloat(side) * earWidth, y: center.y - earHeight / 3),
                control2: CGPoint(x: baseX + CGFloat(side) * earWidth, y: center.y + earHeight / 3)
            )
            context.stroke(ear, with: strokeColor, lineWidth: 2)
        }
    }

    // MARK: - Color

    private var horizontalColorBar: some View {
        let currentScale = scale
        return HStack(spacing: 8) {
            Text(String(format: "%.1f", -currentScale))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            LinearGradient(
                colors: stride(from: -1.0, through: 1.0, by: 0.1).map { divergingColor(forNormalized: $0) },
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 12)
            .clipShape(Capsule())

            Text(String(format: "+%.1f %@", currentScale, unitLabel))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var verticalColorBar: some View {
        let currentScale = scale
        return VStack(spacing: 6) {
            Text(String(format: "+%.1f", currentScale))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            LinearGradient(
                colors: stride(from: 1.0, through: -1.0, by: -0.1).map { divergingColor(forNormalized: $0) },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 12, height: max(80, minimumMapHeight * 0.70))
            .clipShape(Capsule())

            Text(String(format: "%.1f", -currentScale))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(unitLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 34)
    }

    /// Diverging blue–white–red map. `normalized` is expected in roughly -1...1.
    private func divergingColor(forNormalized normalized: Double) -> Color {
        guard normalized.isFinite else {
            return Color(red: 0.96, green: 0.96, blue: 0.96)
        }
        let t = max(-1, min(1, normalized))
        let cold = (red: 0.23, green: 0.30, blue: 0.75)
        let mid = (red: 0.96, green: 0.96, blue: 0.96)
        let warm = (red: 0.78, green: 0.16, blue: 0.16)

        if t < 0 {
            let f = t + 1 // 0 at -1, 1 at 0
            return Color(
                red: cold.red + (mid.red - cold.red) * f,
                green: cold.green + (mid.green - cold.green) * f,
                blue: cold.blue + (mid.blue - cold.blue) * f
            )
        } else {
            return Color(
                red: mid.red + (warm.red - mid.red) * t,
                green: mid.green + (warm.green - mid.green) * t,
                blue: mid.blue + (warm.blue - mid.blue) * t
            )
        }
    }
}
