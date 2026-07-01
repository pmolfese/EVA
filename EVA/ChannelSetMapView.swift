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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Interactive scalp map for defining channel sets. Tap any electrode to
//  toggle its membership. Selected channels render as filled blue circles
//  with their number visible; deselected channels render as open,
//  semi-transparent circles.
//

import SwiftUI

struct ChannelSetMapView: View {
    let layout: SensorLayout
    @Binding var selectedIndices: Set<Int>
    var interactive: Bool = true
    /// Optional hook called after a tap toggles a channel, with the channel and
    /// its new membership state. Used to apply symmetry mirroring.
    var onToggle: ((Int, Bool) -> Void)? = nil

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

                ForEach(layout.positions) { sensor in
                    let pos = sensorPoint(sensor, center: center, radius: radius)
                    let selected = selectedIndices.contains(sensor.channelIndex)
                    electrodeMarker(channelIndex: sensor.channelIndex, selected: selected)
                        .position(pos)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func electrodeMarker(channelIndex: Int, selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? Color.blue.opacity(0.25) : Color.clear)
            Circle()
                .stroke(
                    selected ? Color.blue : Color.primary.opacity(0.30),
                    lineWidth: selected ? 1.5 : 0.8
                )
            Text("\(channelIndex + 1)")
                .font(.system(size: 6, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.blue : Color.primary.opacity(0.45))
        }
        .frame(width: 16, height: 16)
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
