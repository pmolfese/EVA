//
//  MultiButterflyView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  "Multi-Butterfly": one all-channel butterfly plot per selected condition,
//  stacked vertically, instead of the single Butterfly pane's one plot with
//  every condition overlaid on shared axes. Reuses `OverlayButterflyPlot`
//  unmodified, one instantiation per condition — no new plotting code.
//
//  Each row can also carry joint markers (right-click → "Add Joint"), same
//  as the Butterfly pane — see `JointMarkerOverlay.swift`. Markers are
//  shared across rows (one latency, one topomap box per row at that
//  latency), so dragging a box in any row retimes it everywhere.
//

import SwiftUI

/// One condition's row in the Multi-Butterfly stack.
struct MultiButterflyGroup: Identifiable {
    let category: String
    let segment: EpochSegment
    var id: String { category }
}

extension WaveformView {
    @ViewBuilder
    func averagesMultiButterflyPane(signal: MFFSignalData, segments: [EpochSegment]) -> some View {
        averagesPanel {
            let groups = multiButterflyGroups(segments: segments)
            if groups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Multi-Butterfly").font(.headline)
                    }
                    ContentUnavailableView(
                        "No Conditions Selected",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Choose one or more conditions from the Conditions menu.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            } else {
                MultiButterflyContent(view: self, signal: signal, groups: groups)
            }
        }
    }

    /// One `EpochSegment` per distinct category among the currently
    /// overlay-selected segments, in first-appearance order — the row order
    /// for both the live pane and the exported figure.
    fileprivate func multiButterflyGroups(segments: [EpochSegment]) -> [MultiButterflyGroup] {
        var seen = Set<String>()
        var result: [MultiButterflyGroup] = []
        for segment in segments where seen.insert(segment.category).inserted {
            result.append(MultiButterflyGroup(category: segment.category, segment: segment))
        }
        return result
    }
}

/// Live pane content — a plain struct so it can hold the pointer position
/// needed for "Add Joint" (shared across rows: whichever row you last
/// hovered supplies the click latency, since markers are the same latency
/// on every row regardless of which one you right-click).
private struct MultiButterflyContent: View {
    let view: WaveformView
    let signal: MFFSignalData
    let groups: [MultiButterflyGroup]

    @State private var pointerRelativeSample: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Multi-Butterfly")
                    .font(.headline)
                Spacer()
                if !view.epoching.jointPlotMarkers.isEmpty {
                    view.jointBoxControls(showsOrientation: false)
                }
                Stepper(
                    "\(view.epoching.multiButterflyColumns) per row",
                    value: Binding(
                        get: { view.epoching.multiButterflyColumns },
                        set: { view.epoching.multiButterflyColumns = $0 }
                    ),
                    in: 1...4
                )
                .font(.caption)
                .fixedSize()
                Text("\(groups.count) condition\(groups.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let columns = max(view.epoching.multiButterflyColumns, 1)
            let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 16), count: columns)

            ScrollView {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        MultiButterflyRow(view: view, signal: signal, group: group, pointerRelativeSample: $pointerRelativeSample)
                    }
                }
            }
            .contextMenu {
                view.figureSaveMenu(
                    title: "Multi-Butterfly",
                    legend: view.overlayLegendItems(),
                    size: exportSize(columns: columns),
                    seconds: view.figureSeconds(groups.map(\.segment), samplingRate: signal.samplingRate),
                    scaleSize: CGSize(width: 780, height: 190)
                ) {
                    MultiButterflyFigure(view: view, signal: signal, groups: groups, columns: columns)
                }
                Divider()
                view.addJointMarkerMenuItem(pointerRelativeSample: pointerRelativeSample)
            }
        }
    }

    private func rowHeight(for group: MultiButterflyGroup) -> CGFloat {
        let boxHeight = view.jointMarkerLayout(
            topomapSegments: [group.segment], signal: signal, referenceSegment: group.segment, width: 780
        ).boxAreaHeight
        return 220
            + (view.epoching.showsAveragesGFP ? 48 : 0)
            + boxHeight
            + MultiButterflyLayout.timeAxisHeight
    }

    private func exportSize(columns: Int) -> CGSize {
        let rowCount = Int(ceil(Double(groups.count) / Double(columns)))
        let tallestRowHeight = groups.map(rowHeight).max() ?? 220
        return CGSize(
            width: CGFloat(columns) * 780 + CGFloat(columns - 1) * 16 + 20,
            height: CGFloat(rowCount) * tallestRowHeight + CGFloat(max(rowCount - 1, 0)) * 16 + 20
        )
    }
}

private struct MultiButterflyRow: View {
    let view: WaveformView
    let signal: MFFSignalData
    let group: MultiButterflyGroup
    @Binding var pointerRelativeSample: Int?

    var body: some View {
        let color = view.epochColor(for: group.segment.colorIndex)
        let gfpHeight: CGFloat = view.epoching.showsAveragesGFP ? 44 : 0

        VStack(alignment: .leading, spacing: 4) {
            Text(view.epoching.displayCategory(group.category))
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)

            GeometryReader { proxy in
                let width = proxy.size.width
                let markerLayout = view.jointMarkerLayout(
                    topomapSegments: [group.segment], signal: signal, referenceSegment: group.segment, width: width
                )
                let boxHeight = markerLayout.boxAreaHeight
                let butterflyHeight = max(proxy.size.height - boxHeight - gfpHeight, 0)

                ZStack(alignment: .topLeading) {
                    if boxHeight > 0 {
                        JointMarkerGuideLines(
                            view: view,
                            topomapSegments: [group.segment],
                            signal: signal,
                            referenceSegment: group.segment,
                            width: width,
                            totalHeight: proxy.size.height
                        )
                    }

                    OverlayButterflyPlot(
                        data: signal.data,
                        segments: [group.segment],
                        colors: [color],
                        hiddenChannels: view.channels.hidden,
                        amplitudeScale: view.amplitudeScale,
                        samplingRate: signal.samplingRate,
                        channelName: { view.eegChannelDisplayName(index: $0, signal: signal) },
                        onTapChannel: { view.channelInspectorSelection = .channel($0) }
                    )
                    .overlay(WaveformVoltageAxisOverlay(amplitudeScale: view.amplitudeScale))
                    .offset(y: boxHeight)
                    .frame(width: width, height: butterflyHeight)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            pointerRelativeSample = view.relativeSample(forButterflyX: location.x, width: width, segment: group.segment)
                        case .ended:
                            break
                        }
                    }

                    if view.epoching.showsAveragesGFP {
                        GFPStripView(data: signal.data, segments: [group.segment], colors: [color])
                            .frame(width: width, height: gfpHeight - 4)
                            .offset(y: boxHeight + butterflyHeight + 4)
                    }

                    if boxHeight > 0 {
                        JointMarkerBoxesLayer(
                            view: view,
                            layout: view.recording.sensorLayout ?? SensorLayout(name: "", positions: []),
                            signal: signal,
                            topomapSegments: [group.segment],
                            referenceSegment: group.segment,
                            width: width,
                            markerLayout: markerLayout,
                            coordinateSpaceName: "multiButterflyJoint-\(group.category)"
                        )
                    }
                }
                .coordinateSpace(name: "multiButterflyJoint-\(group.category)")
            }
            .frame(height: 190 + gfpHeight + view.jointMarkerEstimatedBoxHeight(topomapSegmentCount: 1))

            WaveformTimeAxisView(segment: group.segment, samplingRate: signal.samplingRate)
                .frame(height: MultiButterflyLayout.timeAxisHeight)
        }
    }
}

/// Shared sizing constant between the live rows and the export figure, so
/// their `figureSaveMenu` height math and actual layout can't drift apart.
enum MultiButterflyLayout {
    static let timeAxisHeight: CGFloat = 20
}

/// Static export twin — no hover/drag gestures, one row per condition, same
/// joint-marker boxes as the live pane so exported figures include them.
private struct MultiButterflyFigure: View {
    let view: WaveformView
    let signal: MFFSignalData
    let groups: [MultiButterflyGroup]
    var columns: Int = 1

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(780), spacing: 16), count: max(columns, 1)), alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                let color = view.epochColor(for: group.segment.colorIndex)
                let boxHeight = view.jointMarkerLayout(
                    topomapSegments: [group.segment], signal: signal, referenceSegment: group.segment, width: 780
                ).boxAreaHeight
                let gfpHeight: CGFloat = view.epoching.showsAveragesGFP ? 44 : 0

                VStack(alignment: .leading, spacing: 4) {
                    Text(view.epoching.displayCategory(group.category))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)

                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let markerLayout = view.jointMarkerLayout(
                            topomapSegments: [group.segment], signal: signal, referenceSegment: group.segment, width: width
                        )
                        let butterflyHeight = max(proxy.size.height - boxHeight - gfpHeight, 0)

                        ZStack(alignment: .topLeading) {
                            if boxHeight > 0 {
                                JointMarkerGuideLines(
                                    view: view,
                                    topomapSegments: [group.segment],
                                    signal: signal,
                                    referenceSegment: group.segment,
                                    width: width,
                                    totalHeight: proxy.size.height
                                )
                            }

                            OverlayButterflyPlot(
                                data: signal.data,
                                segments: [group.segment],
                                colors: [color],
                                hiddenChannels: view.channels.hidden,
                                amplitudeScale: view.amplitudeScale,
                                samplingRate: signal.samplingRate
                            )
                            .overlay(WaveformVoltageAxisOverlay(amplitudeScale: view.amplitudeScale))
                            .offset(y: boxHeight)
                            .frame(width: width, height: butterflyHeight)

                            if gfpHeight > 0 {
                                GFPStripView(data: signal.data, segments: [group.segment], colors: [color])
                                    .frame(width: width, height: gfpHeight - 4)
                                    .offset(y: boxHeight + butterflyHeight + 4)
                            }

                            if boxHeight > 0, let layout = view.recording.sensorLayout {
                                JointMarkerBoxesLayer(
                                    view: view,
                                    layout: layout,
                                    signal: signal,
                                    topomapSegments: [group.segment],
                                    referenceSegment: group.segment,
                                    width: width,
                                    markerLayout: markerLayout,
                                    coordinateSpaceName: "multiButterflyJointExport-\(group.category)",
                                    isInteractive: false
                                )
                            }
                        }
                        .coordinateSpace(name: "multiButterflyJointExport-\(group.category)")
                    }
                    .frame(width: 780, height: 190 + gfpHeight + boxHeight)

                    WaveformTimeAxisView(segment: group.segment, samplingRate: signal.samplingRate)
                        .frame(width: 780, height: MultiButterflyLayout.timeAxisHeight)
                }
            }
        }
    }
}
