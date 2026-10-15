//
//  LAVISpectrumView.swift
//  EVA
//

import Charts
import SwiftUI

struct LAVISpectrumView: View {
    let result: LAVIChannelResult
    @Binding var selectedBandID: ABBABand.ID?
    var compact = false

    @State private var hoveredIndex: Int?

    private struct Point: Identifiable {
        var index: Int
        var frequency: Double
        var x: Double
        var value: Double
        var lower: Double?
        var upper: Double?
        var id: Int { index }
    }

    private var points: [Point] {
        result.frequenciesHz.indices.compactMap { index in
            let frequency = result.frequenciesHz[index]
            let value = result.values[index]
            guard frequency > 0, value.isFinite else { return nil }
            return Point(
                index: index,
                frequency: frequency,
                x: log10(frequency),
                value: value,
                lower: result.lowerSignificance.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                upper: result.upperSignificance.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.channelName)
                            .font(.headline)
                        Text("Higher LAVI means more persistent phase relations, not greater power.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    legend
                }
            }

            ZStack(alignment: .topTrailing) {
                chart
                if !compact, let hoveredIndex, let point = points.first(where: { $0.index == hoveredIndex }) {
                    hoverCard(point)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(result.bands) { band in
                RectangleMark(
                    xStart: .value("Band start", log10(max(band.beginFrequencyHz, 0.000_001))),
                    xEnd: .value("Band end", log10(max(band.endFrequencyHz, 0.000_001))),
                    yStart: .value("Minimum LAVI", 0),
                    yEnd: .value("Maximum LAVI", 1)
                )
                .foregroundStyle(bandColor(band).opacity(bandOpacity(band)))
            }

            ForEach(points.filter { $0.lower?.isFinite == true && $0.upper?.isFinite == true }) { point in
                AreaMark(
                    x: .value("log10 frequency", point.x),
                    yStart: .value("Lower surrogate limit", point.lower ?? 0),
                    yEnd: .value("Upper surrogate limit", point.upper ?? 0)
                )
                .foregroundStyle(Color.secondary.opacity(0.18))
                .interpolationMethod(.linear)
            }

            RuleMark(y: .value("Observed median", result.median))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            ForEach(points) { point in
                LineMark(
                    x: .value("log10 frequency", point.x),
                    y: .value("LAVI", point.value)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: compact ? 1.2 : 2))
                .interpolationMethod(.linear)
            }

            if !compact {
                ForEach(result.bands) { band in
                    PointMark(
                        x: .value("Band extremum", log10(max(band.peakFrequencyHz, 0.000_001))),
                        y: .value("Peak LAVI", band.peakLAVI)
                    )
                    .foregroundStyle(bandColor(band))
                    .symbolSize(selectedBandID == band.id ? 110 : 55)
                    .annotation(position: band.direction == .sustained ? .top : .bottom) {
                        Text(band.canonicalName ?? "Unanchored")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: frequencyTicks.map(log10)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let logged = value.as(Double.self) {
                        Text(formatFrequency(pow(10, logged)))
                    }
                }
            }
        }
        .chartXAxisLabel(compact ? "" : "Frequency (Hz, log scale)")
        .chartYAxisLabel(compact ? "" : "LAVI")
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hoveredIndex = nearestIndex(to: location, proxy: proxy, geometry: geometry)
                        case .ended: hoveredIndex = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let index = nearestIndex(to: location, proxy: proxy, geometry: geometry) else { return }
                        selectedBandID = result.bands.first { $0.beginIndex <= index && index <= $0.endIndex }?.id
                    }
            }
        }
        .frame(minHeight: compact ? 100 : 290)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Label("Sustained", systemImage: "square.fill").foregroundStyle(Color.blue)
            Label("Transient", systemImage: "square.fill").foregroundStyle(Color.orange)
            Label("Surrogate ribbon", systemImage: "rectangle.fill").foregroundStyle(Color.secondary)
        }
        .font(.caption2)
    }

    private func hoverCard(_ point: Point) -> some View {
        let band = result.bands.first { $0.beginIndex <= point.index && point.index <= $0.endIndex }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(String(format: "%.2f", point.frequency)) Hz · LAVI \(String(format: "%.4f", point.value))")
                .font(.caption.weight(.semibold).monospacedDigit())
            Text("Median difference \(signed(point.value - result.median))")
            if let lower = point.lower, let upper = point.upper {
                Text("Ribbon \(String(format: "%.4f", lower))…\(String(format: "%.4f", upper))")
            }
            if let band {
                Text("\(band.canonicalName ?? "Unanchored") · \(band.direction.rawValue) · \(significance(band))")
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private var xDomain: ClosedRange<Double> {
        let values = result.frequenciesHz.filter { $0 > 0 }
        return log10(values.first ?? 1)...log10(values.last ?? 100)
    }

    private var frequencyTicks: [Double] {
        let range = (result.frequenciesHz.first ?? 1)...(result.frequenciesHz.last ?? 100)
        return [3, 4, 6, 8, 10, 14, 20, 30, 40, 50].filter(range.contains)
    }

    private func nearestIndex(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Int? {
        guard let anchor = proxy.plotFrame else { return nil }
        let plot = geometry[anchor]
        let localX = location.x - plot.minX
        guard localX >= 0, localX <= plot.width,
              let x: Double = proxy.value(atX: localX) else { return nil }
        return points.min { abs($0.x - x) < abs($1.x - x) }?.index
    }

    private func bandColor(_ band: ABBABand) -> Color {
        band.direction == .sustained ? .blue : .orange
    }

    private func bandOpacity(_ band: ABBABand) -> Double {
        if selectedBandID == band.id { return 0.25 }
        if band.isSignificant == true { return 0.14 }
        return 0.055
    }

    private func significance(_ band: ABBABand) -> String {
        switch band.isSignificant {
        case true: return "significant"
        case false: return "not significant"
        case nil: return "not computed"
        }
    }

    private func signed(_ value: Double) -> String { String(format: "%+.4f", value) }

    private func formatFrequency(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
