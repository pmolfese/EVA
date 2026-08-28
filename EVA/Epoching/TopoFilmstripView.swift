//
//  TopoFilmstripView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  "Filmstrip": evenly-spaced topomaps across the whole epoch, one row per
//  selected condition — a fast first look before you know where the peaks
//  are, versus Joint Plot's hand-placed markers. Reuses
//  `averagedTopomapSamples` (same call Joint Plot and the Topography pane
//  use) at N evenly-spaced latencies instead of one shared cursor.
//

import SwiftUI

extension WaveformView {
    @ViewBuilder
    func averagesFilmstripPane(signal: MFFSignalData, segments: [EpochSegment]) -> some View {
        averagesPanel {
            if let layout = recording.sensorLayout, let firstSegment = segments.first {
                let epochLength = max(firstSegment.endSample - firstSegment.startSample + 1, 1)
                let times = filmstripTimes(epochLength: epochLength, count: epoching.filmstripTileCount)
                let tilesByTime = times.map { averagedTopomapSamples(relativeSample: $0, in: signal) }
                let allSamples = tilesByTime.flatMap { $0 }
                let scale = fixedTopomapScale(for: allSamples.map(\.sample), in: signal)
                let colorRange = topomapColorRange()
                let autoZ = topomapAutoZ(samples: allSamples, in: signal)
                let zScaling = topomapZScaling(auto: autoZ)
                let categories = overlayAvailableCategories().filter { category in
                    segments.contains { $0.category == category }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Filmstrip")
                            .font(.headline)
                        Spacer()
                        Stepper(
                            "\(epoching.filmstripTileCount) frames",
                            value: $epoching.filmstripTileCount,
                            in: 3...16
                        )
                        .font(.caption)
                        .fixedSize()
                    }

                    if categories.isEmpty {
                        ContentUnavailableView(
                            "No Conditions Selected",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Choose one or more conditions from the Conditions menu.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(categories, id: \.self) { category in
                                    filmstripRow(
                                        category: category,
                                        tilesByTime: tilesByTime,
                                        layout: layout,
                                        signal: signal,
                                        scale: scale,
                                        colorRange: colorRange,
                                        zScaling: zScaling
                                    )
                                }
                            }
                        }
                        .contextMenu {
                            figureSaveMenu(
                                title: "Topo Filmstrip",
                                legend: topomapLegendItems(allSamples),
                                size: CGSize(
                                    width: CGFloat(times.count) * 150 + 20,
                                    height: CGFloat(categories.count) * 190 + 20
                                )
                            ) {
                                filmstripFigure(
                                    categories: categories,
                                    tilesByTime: tilesByTime,
                                    layout: layout,
                                    signal: signal,
                                    scale: scale,
                                    colorRange: colorRange,
                                    zScaling: zScaling
                                )
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Sensor Layout",
                    systemImage: "circle.dashed",
                    description: Text("This package has no readable sensorLayout.xml, so topographic maps can't be drawn.")
                )
            }
        }
    }

    /// `count` sample indices evenly spaced across `0..<epochLength`.
    private func filmstripTimes(epochLength: Int, count: Int) -> [Int] {
        guard count > 1, epochLength > 1 else { return [0] }
        return (0..<count).map { index in
            min(Int((Double(index) / Double(count - 1) * Double(epochLength - 1)).rounded()), epochLength - 1)
        }
    }

    private func filmstripRow(
        category: String,
        tilesByTime: [[AveragedTopomapSample]],
        layout: SensorLayout,
        signal: MFFSignalData,
        scale: Double?,
        colorRange: ClosedRange<Double>?,
        zScaling: TopomapZScaling?
    ) -> some View {
        let firstMatch = tilesByTime.compactMap { $0.first { $0.category == category } }.first
        return VStack(alignment: .leading, spacing: 4) {
            Text(epoching.displayCategory(category))
                .font(.caption.weight(.semibold))
                .foregroundStyle(epochColor(for: firstMatch?.colorIndex ?? 0))
            HStack(spacing: 8) {
                ForEach(tilesByTime.indices, id: \.self) { index in
                    if let entry = tilesByTime[index].first(where: { $0.category == category }) {
                        VStack(spacing: 2) {
                            Text(String(format: "%.3f s", entry.latencySeconds))
                                .font(.system(size: 9, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                            TopomapView(
                                layout: layout,
                                values: topomapValues(at: entry.sample, in: signal),
                                timeSeconds: entry.latencySeconds,
                                fixedScale: scale,
                                colorRange: colorRange,
                                zScaling: zScaling,
                                showsHeader: false,
                                showsLayoutName: false,
                                colorBarPlacement: .none,
                                minimumMapHeight: 130
                            )
                            .frame(width: 130, height: 130)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filmstripFigure(
        categories: [String],
        tilesByTime: [[AveragedTopomapSample]],
        layout: SensorLayout,
        signal: MFFSignalData,
        scale: Double?,
        colorRange: ClosedRange<Double>?,
        zScaling: TopomapZScaling?
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(categories, id: \.self) { category in
                filmstripRow(
                    category: category,
                    tilesByTime: tilesByTime,
                    layout: layout,
                    signal: signal,
                    scale: scale,
                    colorRange: colorRange,
                    zScaling: zScaling
                )
            }
        }
        .padding(4)
        .background(Color.white)
    }
}
