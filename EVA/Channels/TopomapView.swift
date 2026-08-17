//
//  TopomapView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Top-down scalp topography for a single time point. Draws a head outline
//  (circle + nose + ears) with an inverse-distance-weighted interpolation of
//  the per-electrode potential, plus electrode markers and a colorbar.
//

import SwiftUI

enum TopomapColorBarPlacement {
    case bottom
    case trailing
    case none
}

/// Z-score color scaling for a topomap: color spans mean ± sigma·sd.
struct TopomapZScaling: Equatable {
    let mean: Double
    let sd: Double
    let sigma: Double
}

struct TopomapView: View {
    let layout: SensorLayout
    /// Per-channel potential (µV) at the chosen sample, indexed by channel.
    let values: [Double]
    let timeSeconds: Double
    /// When non-nil, fixes the symmetric color scale to ±this value (µV).
    /// When nil, the scale auto-fits to the data at this time point.
    let fixedScale: Double?
    /// Manual asymmetric color limits (min µV, max µV). Overrides `fixedScale`.
    /// 0 stays white; tightening a side toward 0 intensifies that color.
    let colorRange: ClosedRange<Double>?
    /// Z-score scaling: color spans mean ± sigma·sd (white at the mean).
    /// Overrides both `colorRange` and `fixedScale`.
    let zScaling: TopomapZScaling?
    let unitLabel: String
    /// Uses a zero-to-maximum sequential scale for intrinsically non-negative
    /// quantities such as omnibus F statistics.
    let usesPositiveSequentialScale: Bool
    let showsHeader: Bool
    /// When false, the net-layout name is omitted from the header (the latency is
    /// still shown) — used for exported figures.
    let showsLayoutName: Bool
    let colorBarPlacement: TopomapColorBarPlacement
    let minimumMapHeight: CGFloat
    let contentPadding: CGFloat
    /// Resolves a channel index to its display name, for the hover tooltip.
    /// When nil, the tooltip falls back to "Ch <index+1>".
    let channelName: ((Int) -> String)?
    /// Called when the user clicks a channel on the map (nearest electrode
    /// within the hit-test radius). Nil disables tap handling entirely.
    let onTapChannel: ((Int) -> Void)?
    /// Optional emphasis ring, used by cluster-statistics maps to identify the
    /// sensors that participate in the selected corrected cluster.
    let highlightedChannels: Set<Int>

    @State private var hoveredChannel: Int?

    init(
        layout: SensorLayout,
        values: [Double],
        timeSeconds: Double,
        fixedScale: Double?,
        colorRange: ClosedRange<Double>? = nil,
        zScaling: TopomapZScaling? = nil,
        unitLabel: String = "µV",
        usesPositiveSequentialScale: Bool = false,
        showsHeader: Bool = true,
        showsLayoutName: Bool = true,
        colorBarPlacement: TopomapColorBarPlacement = .bottom,
        minimumMapHeight: CGFloat = 260,
        contentPadding: CGFloat = 16,
        channelName: ((Int) -> String)? = nil,
        onTapChannel: ((Int) -> Void)? = nil,
        highlightedChannels: Set<Int> = []
    ) {
        self.layout = layout
        self.values = values
        self.timeSeconds = timeSeconds
        self.fixedScale = fixedScale
        self.colorRange = colorRange
        self.zScaling = zScaling
        self.unitLabel = unitLabel
        self.usesPositiveSequentialScale = usesPositiveSequentialScale
        self.showsHeader = showsHeader
        self.showsLayoutName = showsLayoutName
        self.channelName = channelName
        self.onTapChannel = onTapChannel
        self.highlightedChannels = highlightedChannels
        self.colorBarPlacement = colorBarPlacement
        self.minimumMapHeight = minimumMapHeight
        self.contentPadding = contentPadding
    }

    private let interpolationPower: Double = 3

    var body: some View {
        VStack(spacing: 12) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline) {
                    if showsLayoutName {
                        Text(layout.name.isEmpty ? "Topography" : layout.name)
                            .font(.headline)
                    }
                    Spacer()
                    Text(String(format: "t = %.3f s", timeSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            switch colorBarPlacement {
            case .trailing:
                HStack(spacing: 10) {
                    mapCanvas
                    verticalColorBar
                }
            case .bottom:
                mapCanvas
                horizontalColorBar
            case .none:
                mapCanvas
            }
        }
        .padding(contentPadding)
    }

    private var mapCanvas: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredChannel = nearestChannel(at: location, in: CGSize(width: side, height: side))
                case .ended:
                    hoveredChannel = nil
                }
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard let onTapChannel,
                              let channel = nearestChannel(at: value.location, in: CGSize(width: side, height: side))
                        else { return }
                        onTapChannel(channel)
                    }
            )
            .overlay(alignment: .topLeading) { hoverTooltip(side: side) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: minimumMapHeight)
    }

    /// Nearest electrode to `location` (in the canvas's own coordinate space),
    /// within a generous hit radius — mouse precision is looser than the tiny
    /// electrode dots themselves.
    private func nearestChannel(at location: CGPoint, in size: CGSize) -> Int? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 * 0.86
        let hitRadius: CGFloat = 14

        var best: (channel: Int, distanceSquared: CGFloat)?
        for sensor in activeSensors {
            let p = CGPoint(
                x: center.x + CGFloat(sensor.x) * radius,
                y: center.y - CGFloat(sensor.y) * radius
            )
            let dx = p.x - location.x
            let dy = p.y - location.y
            let d2 = dx * dx + dy * dy
            if best == nil || d2 < best!.distanceSquared {
                best = (sensor.channelIndex, d2)
            }
        }
        guard let best, best.distanceSquared <= hitRadius * hitRadius else { return nil }
        return best.channel
    }

    @ViewBuilder
    private func hoverTooltip(side: CGFloat) -> some View {
        if let hoveredChannel, let sensor = activeSensors.first(where: { $0.channelIndex == hoveredChannel }) {
            let name = channelName?(hoveredChannel) ?? "Ch \(hoveredChannel + 1)"
            let center = CGPoint(x: side / 2, y: side / 2)
            let radius = side / 2 * 0.86
            let point = CGPoint(x: center.x + CGFloat(sensor.x) * radius, y: center.y - CGFloat(sensor.y) * radius)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption.weight(.semibold))
                if let v = value(for: sensor) {
                    Text("\(String(format: "%.1f", v)) \(unitLabel)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 2, y: 1)
            .fixedSize()
            .position(x: min(max(point.x, 40), side - 40), y: max(point.y - 22, 14))
            .allowsHitTesting(false)
        }
    }

    /// Maps a µV value to the diverging colormap's -1…1 axis. With a manual
    /// `colorRange`, each side is scaled independently (0 stays white), so a
    /// tighter limit saturates that color faster. With `zScaling`, the map is
    /// linear and centered on the mean (white = mean, ±1 = ±sigma·sd).
    private func normalized(_ value: Double) -> Double {
        if usesPositiveSequentialScale {
            return Swift.max(Swift.min(value / scale, 1), 0)
        }
        if let z = zScaling, z.sd > 0, z.sigma > 0 {
            return Swift.max(Swift.min((value - z.mean) / (z.sigma * z.sd), 1), -1)
        }
        if let colorRange {
            if value >= 0 {
                let upper = colorRange.upperBound
                return upper > 0 ? Swift.min(value / upper, 1) : (value > 0 ? 1 : 0)
            } else {
                let lowerMag = -colorRange.lowerBound
                return lowerMag > 0 ? Swift.max(value / lowerMag, -1) : -1
            }
        }
        return Swift.max(Swift.min(value / scale, 1), -1)
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

        // Electrode markers. Cluster members receive a high-contrast ring;
        // ordinary topomaps pass the default empty set and remain unchanged.
        for sensor in sensors {
            let point = CGPoint(
                x: center.x + CGFloat(sensor.x) * radius,
                y: center.y - CGFloat(sensor.y) * radius
            )
            if highlightedChannels.contains(sensor.channelIndex) {
                let ring = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
                context.fill(Path(ellipseIn: ring), with: .color(.yellow.opacity(0.95)))
                context.stroke(Path(ellipseIn: ring), with: .color(.black.opacity(0.85)), lineWidth: 1.2)
            }
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
                    let color = divergingColor(forNormalized: normalized(interpolated))
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

    /// Color-bar end labels + unit: z-scale in σ, manual range in µV, else ±auto.
    /// `lowMicrovolts`/`highMicrovolts` are populated only for the z-score scale,
    /// giving the SD-equivalent µV value at each end (mean ± sigma·sd) so the
    /// colorbar still reads in physical units even while scaled by SD.
    private var barLabels: (low: String, high: String, unit: String, lowMicrovolts: String?, highMicrovolts: String?) {
        if usesPositiveSequentialScale {
            return ("0.0", String(format: "%.1f", scale), unitLabel, nil, nil)
        }
        if let z = zScaling {
            let span = z.sigma * z.sd
            return (
                String(format: "−%.1f", z.sigma), String(format: "+%.1f", z.sigma), "SD",
                String(format: "%.1f µV", z.mean - span), String(format: "%.1f µV", z.mean + span)
            )
        }
        if let colorRange {
            return (String(format: "%.1f", colorRange.lowerBound), String(format: "%+.1f", colorRange.upperBound), unitLabel, nil, nil)
        }
        let s = scale
        return (String(format: "%.1f", -s), String(format: "%+.1f", s), unitLabel, nil, nil)
    }

    private var horizontalColorBar: some View {
        let labels = barLabels
        return HStack(spacing: 8) {
            VStack(spacing: 1) {
                Text(labels.low)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let lowMicrovolts = labels.lowMicrovolts {
                    Text(lowMicrovolts)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            LinearGradient(
                colors: usesPositiveSequentialScale
                    ? stride(from: 0.0, through: 1.0, by: 0.1).map { divergingColor(forNormalized: $0) }
                    : stride(from: -1.0, through: 1.0, by: 0.1).map { divergingColor(forNormalized: $0) },
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 12)
            .clipShape(Capsule())

            VStack(spacing: 1) {
                Text("\(labels.high) \(labels.unit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let highMicrovolts = labels.highMicrovolts {
                    Text(highMicrovolts)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var verticalColorBar: some View {
        let labels = barLabels
        return VStack(spacing: 6) {
            VStack(spacing: 1) {
                Text(labels.high)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let highMicrovolts = labels.highMicrovolts {
                    Text(highMicrovolts)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            LinearGradient(
                colors: usesPositiveSequentialScale
                    ? stride(from: 1.0, through: 0.0, by: -0.1).map { divergingColor(forNormalized: $0) }
                    : stride(from: 1.0, through: -1.0, by: -0.1).map { divergingColor(forNormalized: $0) },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 12, height: max(80, minimumMapHeight * 0.70))
            .clipShape(Capsule())

            VStack(spacing: 1) {
                Text(labels.low)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let lowMicrovolts = labels.lowMicrovolts {
                    Text(lowMicrovolts)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Text(labels.unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 46)
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
