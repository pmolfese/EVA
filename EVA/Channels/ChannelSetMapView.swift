//
//  ChannelSetMapView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Interactive scalp map for defining channel sets. Tap any electrode to
//  toggle its membership, or drag outward from a point to add every electrode
//  enclosed by the resulting circle. Selected channels render as filled blue
//  circles with their number visible; deselected channels render as open,
//  semi-transparent circles.
//

import SwiftUI

struct ChannelSetMapView: View {
    let layout: SensorLayout
    @Binding var selectedIndices: Set<Int>
    var interactive: Bool = true
    var channelLabel: (Int) -> String = { "\($0 + 1)" }
    /// Optional hook called after a tap toggles a channel, with the channel and
    /// its new membership state. Used to apply symmetry mirroring.
    var onToggle: ((Int, Bool) -> Void)? = nil

    /// Live center-to-edge drag used to preview a circular batch selection.
    /// It is intentionally transient: only the enclosed channel membership is
    /// committed when the pointer is released.
    @State private var selectionCircle: SelectionCircle?

    private struct SelectionCircle {
        let center: CGPoint
        let radius: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: side / 2, y: side / 2)
            let radius = side / 2 * 0.86

            ZStack {
                Canvas { ctx, _ in
                    drawHead(in: &ctx, center: center, radius: radius)
                }
                .frame(width: side, height: side)

                if let selectionCircle, interactive {
                    Circle()
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay {
                            Circle()
                                .stroke(
                                    Color.accentColor.opacity(0.9),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                                )
                        }
                        .frame(
                            width: selectionCircle.radius * 2,
                            height: selectionCircle.radius * 2
                        )
                        .position(selectionCircle.center)
                        .allowsHitTesting(false)
                }

                ForEach(layout.positions) { sensor in
                    let pos = sensorPoint(sensor, center: center, radius: radius)
                    let selected = selectedIndices.contains(sensor.channelIndex)
                    let label = channelLabel(sensor.channelIndex)
                    electrodeMarker(label: label, selected: selected)
                        .position(pos)
                        .help(label)
                        .onTapGesture {
                            guard interactive else { return }
                            let nowSelected = !selected
                            if nowSelected {
                                selectedIndices.insert(sensor.channelIndex)
                            } else {
                                selectedIndices.remove(sensor.channelIndex)
                            }
                            onToggle?(sensor.channelIndex, nowSelected)
                        }
                        .animation(.easeInOut(duration: 0.1), value: selected)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .simultaneousGesture(circleSelectionGesture(center: center, headRadius: radius))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func circleSelectionGesture(center: CGPoint, headRadius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            .onChanged { value in
                guard interactive else { return }
                selectionCircle = SelectionCircle(
                    center: value.startLocation,
                    radius: hypot(
                        value.location.x - value.startLocation.x,
                        value.location.y - value.startLocation.y
                    )
                )
            }
            .onEnded { value in
                guard interactive else {
                    selectionCircle = nil
                    return
                }
                let circle = SelectionCircle(
                    center: value.startLocation,
                    radius: hypot(
                        value.location.x - value.startLocation.x,
                        value.location.y - value.startLocation.y
                    )
                )
                addChannels(
                    enclosedBy: circle,
                    mapCenter: center,
                    headRadius: headRadius
                )
                selectionCircle = nil
            }
    }

    /// Circle drags are additive. Removal remains an explicit electrode click,
    /// which makes repeated patches predictable and prevents an overlapping
    /// circle from unexpectedly toggling an already-authored region off.
    private func addChannels(
        enclosedBy circle: SelectionCircle,
        mapCenter: CGPoint,
        headRadius: CGFloat
    ) {
        let enclosed = Set(layout.positions.compactMap { sensor -> Int? in
            let point = sensorPoint(sensor, center: mapCenter, radius: headRadius)
            return hypot(point.x - circle.center.x, point.y - circle.center.y) <= circle.radius
                ? sensor.channelIndex
                : nil
        })
        guard !enclosed.isEmpty else { return }

        let additions = enclosed.subtracting(selectedIndices)
        selectedIndices.formUnion(enclosed)
        for channel in additions.sorted() {
            onToggle?(channel, true)
        }
    }

    @ViewBuilder
    private func electrodeMarker(label: String, selected: Bool) -> some View {
        let size = markerSize(for: label)
        ZStack {
            Circle()
                .fill(selected ? Color.blue.opacity(0.25) : Color.clear)
            Circle()
                .stroke(
                    selected ? Color.blue : Color.primary.opacity(0.30),
                    lineWidth: selected ? 1.5 : 0.8
                )
            Text(label)
                .font(.system(size: fontSize(for: label), weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.blue : Color.primary.opacity(0.45))
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .frame(width: size, height: size)
    }

    private func markerSize(for label: String) -> CGFloat {
        if layout.positions.count > 128 { return 18 }
        if layout.positions.count > 64 { return 20 }
        return max(24, min(32, CGFloat(label.count) * 5 + 10))
    }

    private func fontSize(for label: String) -> CGFloat {
        if layout.positions.count > 128 { return 5.5 }
        if layout.positions.count > 64 { return 6.5 }
        return label.count > 4 ? 7 : 8
    }

    private func sensorPoint(_ sensor: SensorPosition, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(sensor.x) * radius,
            y: center.y - CGFloat(sensor.y) * radius
        )
    }

    private func drawHead(in ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let stroke = GraphicsContext.Shading.color(.primary.opacity(0.45))

        let headRect = CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: headRect), with: stroke, lineWidth: 1.5)

        var nose = Path()
        let nw = radius * 0.10, nh = radius * 0.10
        nose.move(to:    CGPoint(x: center.x - nw, y: center.y - radius + 1))
        nose.addLine(to: CGPoint(x: center.x,       y: center.y - radius - nh))
        nose.addLine(to: CGPoint(x: center.x + nw, y: center.y - radius + 1))
        ctx.stroke(nose, with: stroke, lineWidth: 1.5)

        let eh = radius * 0.28, ew = radius * 0.08
        for side in [-1.0, 1.0] {
            var ear = Path()
            let bx = center.x + CGFloat(side) * radius
            ear.move(to: CGPoint(x: bx, y: center.y - eh / 2))
            ear.addCurve(
                to: CGPoint(x: bx, y: center.y + eh / 2),
                control1: CGPoint(x: bx + CGFloat(side) * ew, y: center.y - eh / 3),
                control2: CGPoint(x: bx + CGFloat(side) * ew, y: center.y + eh / 3)
            )
            ctx.stroke(ear, with: stroke, lineWidth: 1.5)
        }
    }
}
