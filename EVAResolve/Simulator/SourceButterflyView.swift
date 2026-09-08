//
//  SourceButterflyView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-3 Stage 3c — a butterfly plot of the field the sources produce (all channels
//  overlaid against time), with a drag-to-select interval. The selected window is
//  what the spatiotemporal ("interval") dipole fit is computed over — the
//  Scherg/Berg idea that a *time interval*, not a single instant, is what separates
//  simultaneous sources. Drag to select; click to clear (fit the whole epoch).
//

import SwiftUI

struct SourceButterflyView: View {
    @Bindable var controller: SourceSimulatorController

    @State private var dragStartSample: Int?
    private let dragThreshold: CGFloat = 3

    var body: some View {
        // Touch the observed state the Canvas draws from so it re-renders on a
        // scrub, a geometry/noise change, or a selection change (a Canvas draw
        // closure is escaping and doesn't establish observation on its own).
        _ = controller.currentSample
        _ = controller.fitSelection
        _ = controller.showNoisyField
        let matrix = controller.displayedMatrix(over: nil) ?? []
        let sampleCount = matrix.first?.count ?? 0

        let peak = matrix.reduce(0.0) { m, ch in max(m, ch.reduce(0.0) { max($0, abs($1)) }) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Field (butterfly)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if peak > 0 {
                    Text(String(format: "peak ±%.1f µV", peak))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(selectionLabel(sampleCount: sampleCount))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Canvas { context, size in
                    draw(&context, size: size, matrix: matrix, sampleCount: sampleCount)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geo.size.width, sampleCount: sampleCount))
            }
            .frame(height: 96)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize, matrix: [[Double]], sampleCount: Int) {
        guard sampleCount > 1, !matrix.isEmpty else {
            context.draw(
                Text("Place a source and add an activation to see the field.")
                    .font(.caption2).foregroundColor(.secondary),
                at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let midY = size.height / 2
        var maxAbs = 1e-9
        for channel in matrix { for v in channel { maxAbs = max(maxAbs, abs(v)) } }
        let yScale = (size.height * 0.45) / maxAbs
        let xScale = size.width / CGFloat(sampleCount - 1)
        let stride = max(sampleCount / max(Int(size.width), 1), 1)

        // Selected interval highlight (what the interval fit uses).
        if let selection = controller.fitSelection {
            let lower = CGFloat(min(max(selection.lowerBound, 0), sampleCount - 1)) * xScale
            let upper = CGFloat(min(max(selection.upperBound, 0), sampleCount - 1)) * xScale
            let rect = CGRect(x: lower, y: 0, width: max(1, upper - lower), height: size.height)
            context.fill(Path(rect), with: .color(.purple.opacity(0.14)))
            context.stroke(Path(rect), with: .color(.purple.opacity(0.5)), lineWidth: 1)
        }

        // Baseline.
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: midY))
        baseline.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.75)

        // Channel traces overlaid.
        for channel in matrix {
            guard channel.count == sampleCount else { continue }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY - CGFloat(channel[0]) * yScale))
            var s = stride
            while s < sampleCount {
                path.addLine(to: CGPoint(x: CGFloat(s) * xScale, y: midY - CGFloat(channel[s]) * yScale))
                s += stride
            }
            context.stroke(path, with: .color(.accentColor.opacity(0.35)), lineWidth: 0.6)
        }

        // Playhead.
        let playX = CGFloat(min(max(controller.currentSample, 0), sampleCount - 1)) * xScale
        var playhead = Path()
        playhead.move(to: CGPoint(x: playX, y: 0))
        playhead.addLine(to: CGPoint(x: playX, y: size.height))
        context.stroke(playhead, with: .color(.orange), lineWidth: 1)
    }

    // MARK: Interaction

    private func dragGesture(width: CGFloat, sampleCount: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard sampleCount > 1, width > 0 else { return }
                let start = sample(atX: value.startLocation.x, width: width, sampleCount: sampleCount)
                if dragStartSample == nil { dragStartSample = start }
                let end = sample(atX: value.location.x, width: width, sampleCount: sampleCount)
                if abs(value.translation.width) >= dragThreshold {
                    controller.fitSelection = min(start, end)...max(start, end)
                }
            }
            .onEnded { value in
                defer { dragStartSample = nil }
                guard sampleCount > 1, width > 0 else { return }
                // A click (no meaningful drag) clears the selection → fit the whole
                // epoch. A drag sets the interval.
                if abs(value.translation.width) < dragThreshold {
                    controller.fitSelection = nil
                } else {
                    let start = sample(atX: value.startLocation.x, width: width, sampleCount: sampleCount)
                    let end = sample(atX: value.location.x, width: width, sampleCount: sampleCount)
                    controller.fitSelection = min(start, end)...max(start, end)
                }
            }
    }

    private func sample(atX x: CGFloat, width: CGFloat, sampleCount: Int) -> Int {
        let fraction = min(max(x / width, 0), 1)
        return Int((fraction * CGFloat(sampleCount - 1)).rounded())
    }

    private func selectionLabel(sampleCount: Int) -> String {
        let rate = controller.sampleRate
        guard rate > 0 else { return "" }
        guard let selection = controller.fitSelection else { return "whole epoch" }
        let lower = Double(selection.lowerBound) / rate
        let upper = Double(selection.upperBound) / rate
        return String(format: "%.2f–%.2f s", lower, upper)
    }
}
