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

    /// Three-column "Workbench": conditions on the left, the three linked
    /// orthogonal head views stacked in the centre, and the butterfly waveform
    /// with the shared-fit comparison readouts beneath it on the right.
    private var loadedLayout: some View {
        HStack(spacing: 0) {
            conditionsColumn.frame(width: 196)
            Divider()
            headColumn.frame(maxWidth: .infinity)
            Divider()
            waveformColumn.frame(width: 336)
        }
        // Fitting is slow, so changing an input only marks the fit out of date —
        // the user starts it from the Fit button.
        .onChange(of: fitSignature) { _, _ in
            controller.markFitStale("Interval or dipole count changed — press Fit.")
        }
        .onAppear {
            if controller.sharedFitResult == nil { controller.markFitStale("Press Fit to localize.") }
        }
    }

    private var fitSignature: [Double] {
        [Double(controller.fitDatasetSelection?.lowerBound ?? -1),
         Double(controller.fitDatasetSelection?.upperBound ?? -1),
         Double(controller.fitDipoleCount),
         Double(controller.fitDataset?.conditions.count ?? 0),
         Double(controller.fitDataset?.sampleCount ?? 0)]
    }

    // MARK: Left column — conditions

    /// The Fit control block: an explicit run button (the solve is slow), a
    /// determinate progress bar with a percentage, and the solver's own running
    /// commentary so a long fit never looks hung.
    @ViewBuilder
    private var fitControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.isFittingShared {
                HStack(spacing: 8) {
                    Button("Cancel") { controller.cancelSharedFit() }
                        .controlSize(.small)
                    Text("\(Int((controller.fitProgress * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 38, alignment: .trailing)
                }
                ProgressView(value: min(max(controller.fitProgress, 0), 1))
                    .progressViewStyle(.linear)
            } else {
                Button {
                    controller.runSharedFit()
                } label: {
                    Label(controller.sharedFitResult == nil ? "Fit" : "Re-fit",
                          systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(controller.fitDataset == nil)
                if controller.fitIsStale && controller.sharedFitResult != nil {
                    Label("Out of date", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if !controller.fitProgressMessage.isEmpty {
                Text(controller.fitProgressMessage)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var conditionsColumn: some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conditions").font(.headline).lineLimit(1).fixedSize()
                Spacer()
            }

            fitControls
            Divider()
            if let dataset = controller.fitDataset {
                Text(dataset.label).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = controller.sharedFitResult {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(result.conditions.enumerated()), id: \.offset) { index, condition in
                        HStack(spacing: 8) {
                            Circle().fill(FitConditionPalette.color(index)).frame(width: 9, height: 9)
                            Text(condition.name).font(.callout).lineLimit(1)
                            Spacer()
                            Text("\(fmt(condition.goodnessOfFit * 100))%")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let dataset = controller.fitDataset {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(dataset.conditions.enumerated()), id: \.offset) { index, condition in
                        HStack(spacing: 8) {
                            Circle().fill(FitConditionPalette.color(index)).frame(width: 9, height: 9)
                            Text(condition.name).font(.callout).lineLimit(1)
                        }
                    }
                }
            }

            Divider()

            Stepper("Dipoles: \(controller.fitDipoleCount)",
                    value: $controller.fitDipoleCount, in: 1...8)
                .font(.callout)
            Text("Positions are shared across every condition; each condition's moment is fit at those positions.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            Button("Load demo dataset") { controller.loadFitDemoDataset() }
            if !controller.generationMessage.isEmpty {
                Text(controller.generationMessage).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Centre column — three stacked orthogonal head views

    private var headColumn: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Head — 3 views").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let result = controller.sharedFitResult {
                    Text("\(result.positions.count) dipole\(result.positions.count == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            // Two views on top, one below, each filling its cell.
            HStack(spacing: 10) {
                FitProjectionView(plane: .axial, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FitProjectionView(plane: .coronal, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                FitProjectionView(plane: .sagittal, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Right column — waveform over comparison readouts

    /// Right column, top to bottom: the measured data, what the model says the
    /// sources are doing, and what the model has not explained.
    private var waveformColumn: some View {
        @Bindable var controller = controller
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FitButterflyView(controller: controller)
                Divider()
                SourceWaveformsView(controller: controller)
                Divider()
                ResidualComponentsView(controller: controller)
                Divider()
                if let result = controller.sharedFitResult {
                    spectrumView(result.varianceSpectrum, dipoles: result.positions.count)
                    dipoleComparison(result)
                    perConditionFit(result)
                } else {
                    Text("Drag an interval on the butterfly, then press Fit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
    @AppStorage(HeadModelSex.preferenceKey) private var headModelSexRaw = HeadModelSex.female.rawValue
    private let margin: CGFloat = 12

    @State private var draggingIndex: Int?

    var body: some View {
        let headModelSex = HeadModelSex(rawValue: headModelSexRaw) ?? .female
        _ = controller.sharedFitResult
        return VStack(spacing: 2) {
            Text(plane.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                Canvas { context, size in draw(&context, size: size, sex: headModelSex) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(size: geo.size))
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }

    // MARK: Interaction — drag a fitted dipole to reseed the shared fit

    private func geometry(for size: CGSize) -> (center: CGPoint, scale: CGFloat)? {
        guard let head = controller.fitDataset?.headModel, head.scalpRadiusMeters > 0 else { return nil }
        let half = min(size.width, size.height) / 2 - margin
        let layout = HeadSilhouette.layout(for: plane)
        let boxCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        let center = CGPoint(x: boxCenter.x + layout.center.x * half,
                             y: boxCenter.y - layout.center.y * half)
        return (center, layout.radius * half / CGFloat(head.scalpRadiusMeters))
    }

    private func screenPoint(_ p: Vector3D, center: CGPoint, scale: CGFloat) -> CGPoint {
        let (u, v) = plane.components(SIMD3<Double>(p.x, p.y, p.z))
        return CGPoint(x: center.x + CGFloat(u) * scale, y: center.y - CGFloat(v) * scale)
    }

    private func nearestDipole(to location: CGPoint, center: CGPoint, scale: CGFloat) -> Int? {
        guard let positions = controller.sharedFitResult?.positions else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, position) in positions.enumerated() {
            let p = screenPoint(position, center: center, scale: scale)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d < 20, best == nil || d < best!.distance { best = (index, d) }
        }
        return best?.index
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let (center, scale) = geometry(for: size) else { return }
                if draggingIndex == nil {
                    draggingIndex = nearestDipole(to: value.startLocation, center: center, scale: scale)
                }
                guard let index = draggingIndex,
                      let positions = controller.sharedFitResult?.positions,
                      index < positions.count else { return }
                let u = Double((value.location.x - center.x) / scale)
                let v = Double((center.y - value.location.y) / scale)
                var world = SIMD3<Double>(positions[index].x, positions[index].y, positions[index].z)
                plane.apply(u: u, v: v, to: &world)
                controller.nudgeFitDipole(index: index, to: world)
            }
            .onEnded { _ in
                if draggingIndex != nil { controller.commitFitDrag() }
                draggingIndex = nil
            }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, sex: HeadModelSex) {
        guard let head = controller.fitDataset?.headModel,
              let (center, scale) = geometry(for: size) else { return }
        func point(_ p: Vector3D) -> CGPoint {
            let (u, v) = plane.components(SIMD3<Double>(p.x, p.y, p.z))
            return CGPoint(x: center.x + CGFloat(u) * scale, y: center.y - CGFloat(v) * scale)
        }

        context.draw(Image(HeadSilhouette.assetName(for: plane, sex: sex)),
                     in: CGRect(origin: .zero, size: size))
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
