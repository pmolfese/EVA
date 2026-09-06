//
//  FitWaveformPanels.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The two waveform readings of a dipole fit, beneath the measured butterfly:
//
//  * Source waveforms — each fitted dipole's moment over time, one trace per
//    condition. This is what says *when* a source is active and whether the
//    conditions differ, which a single RMS bar per dipole cannot show.
//  * Residual components — a PCA of what the dipole model has NOT explained.
//    Place dipoles that account for the highlighted interval and those
//    components shrink; whatever is left is structure still to be modelled.
//
//  Both come from `SingleDipoleFit.decompose`, computed per condition after a fit.
//

import SwiftUI

/// Shared plotting helper: draws a set of series into a canvas on a common
/// symmetric scale, with a baseline.
private struct SeriesPlot {
    static func draw(
        _ context: inout GraphicsContext, size: CGSize,
        series: [(values: [Double], color: Color)],
        peak: Double,
        highlight: ClosedRange<Int>? = nil,
        sampleCount: Int
    ) {
        guard sampleCount > 1, peak > 0 else {
            context.draw(Text("—").font(.caption2).foregroundColor(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let midY = size.height / 2
        let yScale = (size.height * 0.44) / peak
        let xScale = size.width / CGFloat(sampleCount - 1)

        if let highlight {
            let lower = CGFloat(min(max(highlight.lowerBound, 0), sampleCount - 1)) * xScale
            let upper = CGFloat(min(max(highlight.upperBound, 0), sampleCount - 1)) * xScale
            let rect = CGRect(x: lower, y: 0, width: max(1, upper - lower), height: size.height)
            context.fill(Path(rect), with: .color(.purple.opacity(0.10)))
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: midY))
        baseline.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.75)

        let stride = max(sampleCount / max(Int(size.width), 1), 1)
        for entry in series {
            guard entry.values.count == sampleCount else { continue }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY - CGFloat(entry.values[0]) * yScale))
            var s = stride
            while s < sampleCount {
                path.addLine(to: CGPoint(x: CGFloat(s) * xScale,
                                         y: midY - CGFloat(entry.values[s]) * yScale))
                s += stride
            }
            context.stroke(path, with: .color(entry.color), lineWidth: 1.3)
        }
    }
}

// MARK: - Source waveforms

/// One small chart per fitted dipole, with every condition overlaid, so a
/// difference between conditions at a shared location is visible as a difference
/// in time course rather than a single number.
struct SourceWaveformsView: View {
    @Bindable var controller: SourceSimulatorController

    var body: some View {
        let decompositions = controller.sharedFitDecompositions
        let dipoleCount = decompositions.first?.decomposition.sourceWaveforms.count ?? 0
        let peak = decompositions
            .flatMap { $0.decomposition.sourceWaveforms }
            .reduce(0.0) { m, series in max(m, series.reduce(0.0) { max($0, abs($1)) }) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Source waveforms").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if peak > 0 {
                    Text(String(format: "peak ±%.1f nA·m", peak))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if dipoleCount == 0 {
                Text("Run a fit to see each dipole's time course.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(0..<dipoleCount, id: \.self) { index in
                    dipoleRow(index: index, decompositions: decompositions, peak: peak)
                }
                conditionLegend(decompositions)
            }
        }
    }

    @ViewBuilder
    private func dipoleRow(
        index: Int,
        decompositions: [SourceSimulatorController.ConditionDecomposition],
        peak: Double
    ) -> some View {
        let series: [(values: [Double], color: Color)] = decompositions.enumerated().compactMap {
            conditionIndex, entry in
            guard index < entry.decomposition.sourceWaveforms.count else { return nil }
            return (entry.decomposition.sourceWaveforms[index],
                    FitConditionPalette.color(conditionIndex))
        }
        let sampleCount = series.first?.values.count ?? 0
        VStack(alignment: .leading, spacing: 1) {
            Text("Dipole \(index + 1)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Canvas { context, size in
                SeriesPlot.draw(&context, size: size, series: series, peak: peak,
                                sampleCount: sampleCount)
            }
            .frame(height: 46)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        }
    }

    @ViewBuilder
    private func conditionLegend(
        _ decompositions: [SourceSimulatorController.ConditionDecomposition]
    ) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(decompositions.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 4) {
                    Circle().fill(FitConditionPalette.color(index)).frame(width: 7, height: 7)
                    Text(entry.name).font(.caption2)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Residual components

/// PCA of what the model has not explained. The percentages are shares of the
/// original data variance, so they fall as dipoles are added — the readout for
/// "is there anything left worth modelling?".
struct ResidualComponentsView: View {
    @Bindable var controller: SourceSimulatorController

    var body: some View {
        let decompositions = controller.sharedFitDecompositions
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Residual components").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let first = decompositions.first?.decomposition {
                    Text(String(format: "%.1f%% unexplained", first.residualFraction * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(first.residualFraction > 0.15 ? .orange : .secondary)
                }
            }
            if decompositions.isEmpty {
                Text("Run a fit to see what the model leaves behind.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("What the dipoles above do not account for. Add or move dipoles to explain the highlighted interval and these shrink.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(decompositions.enumerated()), id: \.offset) { index, entry in
                    conditionResidual(name: entry.name,
                                      decomposition: entry.decomposition,
                                      color: FitConditionPalette.color(index))
                }
            }
        }
    }

    @ViewBuilder
    private func conditionResidual(
        name: String, decomposition: SingleDipoleFit.SourceDecomposition, color: Color
    ) -> some View {
        let components = decomposition.residualComponents
        let peak = components
            .flatMap(\.timeCourse)
            .reduce(0.0) { max($0, abs($1)) }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.caption2.weight(.semibold))
                Spacer()
                Text(String(format: "model %.0f%%", decomposition.explainedFraction * 100))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if components.isEmpty {
                Text("Nothing left above the noise floor.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "PC %d — %.1f%% of total variance",
                                    index + 1, component.varianceFraction * 100))
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                        Canvas { context, size in
                            SeriesPlot.draw(&context, size: size,
                                            series: [(component.timeCourse, color.opacity(0.85))],
                                            peak: peak,
                                            sampleCount: component.timeCourse.count)
                        }
                        .frame(height: 34)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    }
                }
            }
        }
    }
}
