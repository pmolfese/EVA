//
//  SourceFitModeView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-3 Stage 3c — the Source window's "Fit" mode. Fits a shared-geometry dipole
//  model to an averaged dataset across conditions: one butterfly of all conditions,
//  a drag-to-select interval, and a comparison that shows the dipole positions are
//  shared while the per-condition moments differ — the answer to "does the source
//  model change between conditions?". Populated by the "Fit Source Model" bridge
//  from the waveform viewer, or by a built-in demo dataset.
//

import SwiftUI

/// Distinct colors for conditions, matched between the butterfly and the comparison.
enum FitConditionPalette {
    static let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .red, .indigo]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

struct SourceFitModeView: View {
    @Bindable var controller: SourceSimulatorController

    var body: some View {
        Group {
            if controller.fitDataset != nil {
                loadedLayout
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "scope").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No data to fit").font(.headline)
            Text("Right-click a butterfly or topomap in a recording and choose “Fit Source Model”, or load a demo dataset to try it.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Load demo dataset") { controller.loadFitDemoDataset() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var loadedLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                projections
                FitButterflyView(controller: controller)
                if !controller.generationMessage.isEmpty {
                    HStack { Text(controller.generationMessage).font(.caption2).foregroundStyle(.secondary); Spacer() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            comparisonPanel.frame(width: 300)
        }
        // Re-fit when the interval, dipole count, or dataset changes.
        .onChange(of: fitSignature) { _, _ in controller.scheduleSharedFit() }
        .onAppear { if controller.sharedFitResult == nil { controller.scheduleSharedFit() } }
    }

    private var fitSignature: [Double] {
        [Double(controller.fitDatasetSelection?.lowerBound ?? -1),
         Double(controller.fitDatasetSelection?.upperBound ?? -1),
         Double(controller.fitDipoleCount),
         Double(controller.fitDataset?.conditions.count ?? 0),
         Double(controller.fitDataset?.sampleCount ?? 0)]
    }

    private var projections: some View {
        HStack(spacing: 10) {
            FitProjectionView(plane: .axial, controller: controller)
            FitProjectionView(plane: .coronal, controller: controller)
            FitProjectionView(plane: .sagittal, controller: controller)
        }
        .frame(height: 180)
    }

    // MARK: Comparison panel

    private var comparisonPanel: some View {
        @Bindable var controller = controller
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Fit").font(.headline)
                    Spacer()
                    if controller.isFittingShared { ProgressView().controlSize(.mini) }
                }
                if let dataset = controller.fitDataset {
                    Text(dataset.label).font(.caption).foregroundStyle(.secondary)
                }

                Stepper("Dipoles: \(controller.fitDipoleCount)",
                        value: $controller.fitDipoleCount, in: 1...8)
                    .font(.callout)

                if let result = controller.sharedFitResult {
                    spectrumView(result.varianceSpectrum, dipoles: result.positions.count)
                    conditionLegend(result)
                    dipoleComparison(result)
                    perConditionFit(result)
                } else {
                    Text("Select an interval on the butterfly to fit.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()
                Button("Load demo dataset") { controller.loadFitDemoDataset() }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func spectrumView(_ spectrum: [Double], dipoles: Int) -> some View {
        let shown = Array(spectrum.prefix(8))
        let maxValue = shown.first ?? 1
        VStack(alignment: .leading, spacing: 2) {
            Text("SVD spectrum (model order)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < dipoles ? Color.purple : Color.secondary.opacity(0.35))
                        .frame(width: 12, height: max(1, CGFloat(value / max(maxValue, 1e-9)) * 30))
                }
            }
            .frame(height: 32, alignment: .bottom)
            Text("bars past the dipole count are faint — over/under-modeling is visible")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func conditionLegend(_ result: SingleDipoleFit.SharedGeometryResult) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(result.conditions.enumerated()), id: \.offset) { index, condition in
                HStack(spacing: 4) {
                    Circle().fill(FitConditionPalette.color(index)).frame(width: 8, height: 8)
                    Text(condition.name).font(.caption2)
                }
            }
        }
    }

    /// The heart of the comparison: per shared dipole, its moment across every
    /// condition side by side. Same position (shared geometry), differing bars =
    /// the model differs between conditions in moment, not location.
    @ViewBuilder
    private func dipoleComparison(_ result: SingleDipoleFit.SharedGeometryResult) -> some View {
        let truthErrors = controller.sharedFitTruthErrors()
        let maxMoment = result.conditions.flatMap { $0.dipoles }.map(\.magnitudeNanoampereMeters).max() ?? 1
        VStack(alignment: .leading, spacing: 8) {
            Text("Moment by condition").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(result.positions.enumerated()), id: \.offset) { dipoleIndex, position in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Dipole \(dipoleIndex + 1)").font(.caption.monospacedDigit())
                        Spacer()
                        Text(positionText(position)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if dipoleIndex < truthErrors.count {
                        Text("→ \(truthErrors[dipoleIndex].name): \(fmt(truthErrors[dipoleIndex].positionMillimeters)) mm")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(result.conditions.enumerated()), id: \.offset) { conditionIndex, condition in
                            let moment = dipoleIndex < condition.dipoles.count
                                ? condition.dipoles[dipoleIndex].magnitudeNanoampereMeters : 0
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(FitConditionPalette.color(conditionIndex))
                                    .frame(width: 22, height: max(2, CGFloat(moment / max(maxMoment, 1e-9)) * 34))
                                Text(fmt(moment)).font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
            Text("shared position · per-condition moment (nA·m)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func perConditionFit(_ result: SingleDipoleFit.SharedGeometryResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Goodness of fit").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(result.conditions.enumerated()), id: \.offset) { index, condition in
                HStack {
                    Circle().fill(FitConditionPalette.color(index)).frame(width: 7, height: 7)
                    Text(condition.name).font(.caption2)
                    Spacer()
                    Text("\(fmt(condition.goodnessOfFit * 100))%").font(.caption2.monospacedDigit())
                }
            }
        }
    }

    private func positionText(_ p: Vector3D) -> String {
        String(format: "(%.0f, %.0f, %.0f) mm", p.x * 1000, p.y * 1000, p.z * 1000)
    }

    private func fmt(_ v: Double) -> String {
        if v.isNaN { return "—" }
        if v.isInfinite { return "∞" }
        return String(format: "%.1f", v)
    }
}

/// All conditions' fields overlaid vs time, colored per condition, with a
/// drag-to-select interval that drives the shared-geometry fit.
struct FitButterflyView: View {
    @Bindable var controller: SourceSimulatorController
    private let dragThreshold: CGFloat = 3

    var body: some View {
        _ = controller.fitDatasetSelection
        let conditions = controller.fitDatasetConditions()
        let sampleCount = conditions.first?.data.first?.count ?? 0
        let peak = conditions.flatMap { $0.data }.reduce(0.0) { m, ch in
            max(m, ch.reduce(0.0) { max($0, abs($1)) })
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Conditions (butterfly)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if peak > 0 {
                    Text(String(format: "peak ±%.1f µV", peak)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(selectionLabel(sampleCount: sampleCount)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Canvas { context, size in
                    draw(&context, size: size, conditions: conditions, sampleCount: sampleCount, peak: peak)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geo.size.width, sampleCount: sampleCount))
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private func draw(
        _ context: inout GraphicsContext, size: CGSize,
        conditions: [SourceSimulatorController.FitDataset.ConditionData], sampleCount: Int, peak: Double
    ) {
        guard sampleCount > 1, peak > 0 else {
            context.draw(Text("Load a dataset to fit.").font(.caption2).foregroundColor(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let midY = size.height / 2
        let yScale = (size.height * 0.45) / peak
        let xScale = size.width / CGFloat(sampleCount - 1)
        let stride = max(sampleCount / max(Int(size.width), 1), 1)

        if let selection = controller.fitDatasetSelection {
            let lower = CGFloat(min(max(selection.lowerBound, 0), sampleCount - 1)) * xScale
            let upper = CGFloat(min(max(selection.upperBound, 0), sampleCount - 1)) * xScale
            let rect = CGRect(x: lower, y: 0, width: max(1, upper - lower), height: size.height)
            context.fill(Path(rect), with: .color(.purple.opacity(0.12)))
            context.stroke(Path(rect), with: .color(.purple.opacity(0.5)), lineWidth: 1)
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: midY))
        baseline.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.75)

        for (conditionIndex, condition) in conditions.enumerated() {
            let color = FitConditionPalette.color(conditionIndex)
            for channel in condition.data {
                guard channel.count == sampleCount else { continue }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY - CGFloat(channel[0]) * yScale))
                var s = stride
                while s < sampleCount {
                    path.addLine(to: CGPoint(x: CGFloat(s) * xScale, y: midY - CGFloat(channel[s]) * yScale))
                    s += stride
                }
                context.stroke(path, with: .color(color.opacity(0.28)), lineWidth: 0.5)
            }
        }
    }

    private func dragGesture(width: CGFloat, sampleCount: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard sampleCount > 1, width > 0, abs(value.translation.width) >= dragThreshold else { return }
                let start = sample(atX: value.startLocation.x, width: width, sampleCount: sampleCount)
                let end = sample(atX: value.location.x, width: width, sampleCount: sampleCount)
                controller.fitDatasetSelection = min(start, end)...max(start, end)
            }
            .onEnded { value in
                guard sampleCount > 1, width > 0 else { return }
                if abs(value.translation.width) < dragThreshold {
                    controller.fitDatasetSelection = nil   // click clears → whole dataset
                } else {
                    let start = sample(atX: value.startLocation.x, width: width, sampleCount: sampleCount)
                    let end = sample(atX: value.location.x, width: width, sampleCount: sampleCount)
                    controller.fitDatasetSelection = min(start, end)...max(start, end)
                }
            }
    }

    private func sample(atX x: CGFloat, width: CGFloat, sampleCount: Int) -> Int {
        Int((min(max(x / width, 0), 1) * CGFloat(sampleCount - 1)).rounded())
    }

    private func selectionLabel(sampleCount: Int) -> String {
        guard let dataset = controller.fitDataset, dataset.sampleRate > 0 else { return "" }
        guard let selection = controller.fitDatasetSelection else { return "whole epoch" }
        let lower = Double(dataset.startSample + selection.lowerBound) / dataset.sampleRate
        let upper = Double(dataset.startSample + selection.upperBound) / dataset.sampleRate
        return String(format: "%.3f–%.3f s", lower, upper)
    }
}

/// One orthographic projection of the shared-geometry fit: head outline plus the
/// fitted dipole positions (purple diamonds) and, when known, the true sources
/// (small green dots).
struct FitProjectionView: View {
    let plane: HeadProjectionView.Plane
    @Bindable var controller: SourceSimulatorController
    private let margin: CGFloat = 12

    var body: some View {
        _ = controller.sharedFitResult
        return VStack(spacing: 2) {
            Text(plane.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Canvas { context, size in draw(&context, size: size) }
                .aspectRatio(1, contentMode: .fit)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard let head = controller.fitDataset?.headModel else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - margin
        let scalp = head.scalpRadiusMeters
        guard scalp > 0 else { return }
        let scale = radius / CGFloat(scalp)
        func point(_ p: Vector3D) -> CGPoint {
            let (u, v) = plane.components(SIMD3<Double>(p.x, p.y, p.z))
            return CGPoint(x: center.x + CGFloat(u) * scale, y: center.y - CGFloat(v) * scale)
        }

        let scalpRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Circle().path(in: scalpRect), with: .color(.secondary), lineWidth: 1.5)
        let brain = CGFloat(head.brainRadiusMeters) * scale
        let brainRect = CGRect(x: center.x - brain, y: center.y - brain, width: brain * 2, height: brain * 2)
        context.stroke(Circle().path(in: brainRect), with: .color(.secondary.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // True sources, if known.
        if let truth = controller.fitDataset?.truth {
            for t in truth {
                let p = point(t.position)
                let r: CGFloat = 4
                context.fill(Circle().path(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(.green.opacity(0.8)))
            }
        }

        // Fitted (shared) dipoles.
        guard let result = controller.sharedFitResult else { return }
        for position in result.positions {
            let p = point(position)
            let r: CGFloat = 5
            var diamond = Path()
            diamond.move(to: CGPoint(x: p.x, y: p.y - r))
            diamond.addLine(to: CGPoint(x: p.x + r, y: p.y))
            diamond.addLine(to: CGPoint(x: p.x, y: p.y + r))
            diamond.addLine(to: CGPoint(x: p.x - r, y: p.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(Color(nsColor: .textBackgroundColor)))
            context.stroke(diamond, with: .color(.purple), lineWidth: 2)
        }
    }
}
