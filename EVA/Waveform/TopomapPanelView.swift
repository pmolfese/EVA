//
//  TopomapPanelView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The side topography panel, extracted from `WaveformView.topomapPanel(for:sample:)`
//  (ROADMAP Priority 1, B2).
//
//  Value inputs + action closures, so it is its own AttributeGraph node and does
//  not copy `WaveformView`. The per-channel `values` are resolved by the parent —
//  the panel neither holds the signal nor knows how to sample it.
//
//  Not `Equatable`: its inputs are `[Double]` scalp values that change whenever
//  the selected sample does, which is the only time this panel is rebuilt anyway.
//  A cheap equality key would compare the same data it is meant to skip.
//

import SwiftUI

struct TopomapPanelView: View {
    let layout: SensorLayout?
    /// One value per channel at the selected sample.
    let values: [Double]
    let timeSeconds: Double
    let channelName: (Int) -> String
    let onTapChannel: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Topography")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if let layout {
                TopomapView(
                    layout: layout,
                    values: values,
                    timeSeconds: timeSeconds,
                    fixedScale: nil,
                    channelName: channelName,
                    onTapChannel: onTapChannel
                )
                Spacer(minLength: 0)
            } else {
                ContentUnavailableView(
                    "No Sensor Layout",
                    systemImage: "circle.dashed",
                    description: Text("This package has no readable sensorLayout.xml, so a topographic map can't be drawn.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
