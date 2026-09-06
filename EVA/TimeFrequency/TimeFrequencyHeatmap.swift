//
//  TimeFrequencyHeatmap.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The frequency × time heatmap drawing (Canvas) plus its color bar and the
//  perceptual color maps, for `TimeFrequencyView`. Diverging (blue–white–red)
//  for dB power and A − B differences; sequential for ITPC.
//

import SwiftUI

/// Everything the heatmap needs to draw one map.
struct TFRender: Sendable {
    var grid: [[Double]]          // [frequencyIndex][timeIndex], freq ascending
    var frequenciesHz: [Double]
    var timesMs: [Double]         // one per time index
    var eventSampleIndex: Int
    var valueRange: ClosedRange<Double>
    var isDiverging: Bool
    var measure: EpochingViewModel.TFMeasure
    var isDifference: Bool
    var trialCountA: Int
    var trialCountB: Int?

    var unitLabel: String {
        switch measure {
        case .power: return isDifference ? "Δ dB" : "dB"
        case .itpc: return isDifference ? "Δ ITPC" : "ITPC"
        }
    }
}

/// Maps a scalar to a color for the TF heatmap.
enum TFColorMap {
    /// Diverging blue → white → red for `t ∈ [-1, 1]`.
    static func diverging(_ t: Double) -> Color {
        let x = min(max(t, -1), 1)
        // Anchors: −1 cool blue, 0 near-white, +1 warm red.
        let neg = (r: 0.13, g: 0.36, b: 0.68)
        let mid = (r: 0.96, g: 0.96, b: 0.96)
        let pos = (r: 0.78, g: 0.15, b: 0.16)
        if x < 0 {
            let f = x + 1  // 0..1 from neg→mid
            return Color(red: lerp(neg.r, mid.r, f), green: lerp(neg.g, mid.g, f), blue: lerp(neg.b, mid.b, f))
        } else {
            return Color(red: lerp(mid.r, pos.r, x), green: lerp(mid.g, pos.g, x), blue: lerp(mid.b, pos.b, x))
        }
    }

    /// Sequential (viridis-like) for `t ∈ [0, 1]`.
    static func sequential(_ t: Double) -> Color {
        let x = min(max(t, 0), 1)
        // A few viridis anchors.
        let anchors: [(Double, Double, Double)] = [
            (0.267, 0.005, 0.329),  // dark purple
            (0.283, 0.141, 0.458),
            (0.254, 0.265, 0.530),
            (0.207, 0.372, 0.553),
            (0.164, 0.471, 0.558),
            (0.128, 0.567, 0.551),
            (0.135, 0.659, 0.518),
            (0.267, 0.749, 0.441),
            (0.478, 0.821, 0.318),
            (0.741, 0.873, 0.150),
            (0.993, 0.906, 0.144),  // yellow
        ]
        let scaled = x * Double(anchors.count - 1)
        let i = min(Int(scaled), anchors.count - 2)
        let f = scaled - Double(i)
        let a = anchors[i], b = anchors[i + 1]
        return Color(red: lerp(a.0, b.0, f), green: lerp(a.1, b.1, f), blue: lerp(a.2, b.2, f))
    }

    static func color(for value: Double, render: TFRender) -> Color {
        if render.isDiverging {
            let extent = max(abs(render.valueRange.lowerBound), abs(render.valueRange.upperBound))
            return diverging(extent > 0 ? value / extent : 0)
        } else {
            let lo = render.valueRange.lowerBound, hi = render.valueRange.upperBound
            let t = hi > lo ? (value - lo) / (hi - lo) : 0
            return sequential(t)
        }
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// The freq × time heatmap with axes and an event marker.
struct TFHeatmap: View {
    let render: TFRender

    private struct Hover: Equatable {
        var location: CGPoint
        var timeMs: Double
        var frequencyHz: Double
        var value: Double
    }

    @State private var hover: Hover?

    private let leftGutter: CGFloat = 44
    private let bottomGutter: CGFloat = 26
    private let topPad: CGFloat = 6
    // Leave room for the trailing “ms” unit rather than letting it overlap the
    // final time tick or get clipped by a compact gallery heatmap.
    private let rightPad: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let plot = plotRect(in: size)
                drawCells(context: &context, plot: plot)
                drawEventLine(context: &context, plot: plot)
                drawFrequencyAxis(context: &context, plot: plot)
                drawTimeAxis(context: &context, plot: plot)
                context.stroke(Path(plot), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): updateHover(at: location, size: proxy.size)
                case .ended: hover = nil
                }
            }
            .overlay(alignment: .topLeading) { hoverTooltip(in: proxy.size) }
        }
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: leftGutter, y: topPad,
            width: max(1, size.width - leftGutter - rightPad),
            height: max(1, size.height - topPad - bottomGutter)
        )
    }

    private func updateHover(at location: CGPoint, size: CGSize) {
        let plot = plotRect(in: size)
        guard plot.contains(location), !render.grid.isEmpty,
              let timeCount = render.grid.first?.count, timeCount > 0 else {
            hover = nil
            return
        }
        let time = min(max(Int((location.x - plot.minX) / plot.width * CGFloat(timeCount)), 0), timeCount - 1)
        let invertedRow = min(max(Int((location.y - plot.minY) / plot.height * CGFloat(render.grid.count)), 0), render.grid.count - 1)
        let frequency = render.grid.count - 1 - invertedRow
        guard render.frequenciesHz.indices.contains(frequency), render.timesMs.indices.contains(time),
              render.grid[frequency].indices.contains(time) else { hover = nil; return }
        hover = Hover(location: location, timeMs: render.timesMs[time], frequencyHz: render.frequenciesHz[frequency], value: render.grid[frequency][time])
    }

    @ViewBuilder
    private func hoverTooltip(in size: CGSize) -> some View {
        if let hover {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.0f ms · %.2f Hz", hover.timeMs, hover.frequencyHz))
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(String(format: "%.3f %@", hover.value, render.unitLabel))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 2, y: 1)
            .allowsHitTesting(false)
            .offset(x: min(max(hover.location.x + 12, 0), max(size.width - 120, 0)), y: max(hover.location.y - 38, 0))
        }
    }

    private func drawCells(context: inout GraphicsContext, plot: CGRect) {
        let freqCount = render.grid.count
        guard freqCount > 0, let timeCount = render.grid.first?.count, timeCount > 0 else { return }
        let cellW = plot.width / CGFloat(timeCount)
        let cellH = plot.height / CGFloat(freqCount)
        for fi in 0..<freqCount {
            // Row 0 is the lowest frequency → drawn at the bottom.
            let y = plot.minY + CGFloat(freqCount - 1 - fi) * cellH
            let row = render.grid[fi]
            for ti in 0..<min(timeCount, row.count) {
                let x = plot.minX + CGFloat(ti) * cellW
                let rect = CGRect(x: x, y: y, width: cellW + 0.6, height: cellH + 0.6)
                context.fill(Path(rect), with: .color(TFColorMap.color(for: row[ti], render: render)))
            }
        }
    }

    private func drawEventLine(context: inout GraphicsContext, plot: CGRect) {
        let timeCount = render.timesMs.count
        guard timeCount > 1, render.eventSampleIndex >= 0, render.eventSampleIndex < timeCount else { return }
        let x = plot.minX + (CGFloat(render.eventSampleIndex) + 0.5) / CGFloat(timeCount) * plot.width
        var path = Path()
        path.move(to: CGPoint(x: x, y: plot.minY))
        path.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func drawFrequencyAxis(context: inout GraphicsContext, plot: CGRect) {
        let freqCount = render.frequenciesHz.count
        guard freqCount > 0 else { return }
        let tickRows = axisIndices(count: freqCount, ticks: 6)
        let cellH = plot.height / CGFloat(freqCount)
        for fi in tickRows {
            let yCenter = plot.minY + (CGFloat(freqCount - 1 - fi) + 0.5) * cellH
            let hz = render.frequenciesHz[fi]
            let label = hz >= 10 ? String(format: "%.0f", hz) : String(format: "%.1f", hz)
            context.draw(
                Text(label).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                at: CGPoint(x: plot.minX - 6, y: yCenter), anchor: .trailing
            )
        }
        context.draw(
            Text("Hz").font(.system(size: 9)).foregroundStyle(.secondary),
            at: CGPoint(x: 12, y: plot.minY + 4), anchor: .leading
        )
    }

    private func drawTimeAxis(context: inout GraphicsContext, plot: CGRect) {
        let timeCount = render.timesMs.count
        guard timeCount > 1 else { return }
        for ti in axisIndices(count: timeCount, ticks: 6) {
            let x = plot.minX + (CGFloat(ti) + 0.5) / CGFloat(timeCount) * plot.width
            let ms = render.timesMs[ti]
            context.draw(
                Text("\(Int(ms.rounded()))").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: plot.maxY + 12), anchor: .center
            )
        }
        context.draw(
            Text("ms").font(.system(size: 9)).foregroundStyle(.secondary),
            at: CGPoint(x: plot.maxX + 4, y: plot.maxY + 12), anchor: .leading
        )
    }

    /// Evenly spaced indices across `count`, for axis ticks.
    private func axisIndices(count: Int, ticks: Int) -> [Int] {
        guard count > 1 else { return [0] }
        let n = min(ticks, count)
        return (0..<n).map { Int((Double($0) / Double(n - 1) * Double(count - 1)).rounded()) }
    }
}

/// A horizontal color bar with min / max labels for the current map.
struct TFColorBar: View {
    let render: TFRender

    var body: some View {
        VStack(spacing: 2) {
            Canvas { context, size in
                let steps = max(2, Int(size.width))
                for i in 0..<steps {
                    let t = Double(i) / Double(steps - 1)
                    let value = render.valueRange.lowerBound + t * (render.valueRange.upperBound - render.valueRange.lowerBound)
                    let x = CGFloat(i) / CGFloat(steps) * size.width
                    let rect = CGRect(x: x, y: 0, width: size.width / CGFloat(steps) + 1, height: size.height)
                    context.fill(Path(rect), with: .color(TFColorMap.color(for: value, render: render)))
                }
                context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            }
            .frame(height: 14)

            HStack {
                Text(format(render.valueRange.lowerBound)).font(.system(size: 9).monospacedDigit())
                Spacer()
                Text(render.unitLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text(format(render.valueRange.upperBound)).font(.system(size: 9).monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
    }

    private func format(_ v: Double) -> String {
        abs(v) >= 10 ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}
