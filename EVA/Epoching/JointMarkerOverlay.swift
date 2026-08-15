//
//  JointMarkerOverlay.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Joint markers (MNE `plot_joint`-style: a time marker with a linked,
//  draggable topomap box) as a reusable overlay layer any butterfly-hosting
//  pane can drop in, rather than a dedicated tab. Right-click any butterfly
//  (Butterfly pane, or a Multi-Butterfly row) → "Add Joint" places a marker
//  at the click location; the box can then be dragged (anywhere inside it,
//  not just a small handle) to retime it. `EpochingViewModel.jointPlotMarkers`
//  is shared, so the same marker/latency shows on every host it's relevant to.
//
//  Boxes stay full-size at their marker's true x — never shrunk or shifted
//  sideways to dodge a neighbor. Instead, when two markers are too close in
//  time to fit side by side, the later one stacks into a new row above the
//  first ("stadium seating": row 0 sits right above the butterfly, row 1
//  above that, and so on), computed by `assignJointMarkerTiers` — the classic
//  minimum-row greedy interval-partitioning algorithm. Because the box never
//  moves off its true x, the guide line down to the butterfly is always a
//  plain vertical line.
//
//  A box holding more than one condition's topomap arranges them per
//  `JointBoxOrientation` — stacked with labels to the left, in a row with
//  labels above, or a roughly-square grid — and every tile's size scales
//  with `EpochingViewModel.jointTopomapScale`. Because box width now varies
//  with condition count/orientation/scale (not a fixed constant), it's
//  computed once per host via `JointMarkerBox.size(...)` and reused for both
//  the stadium-row spacing math and the box's own frame, so they can't
//  disagree — see `WaveformView.jointMarkerLayout`.
//
//  A host embeds this by: (1) computing `WaveformView.jointMarkerLayout(...)`
//  once it knows its own width, reserving `.boxAreaHeight` above its
//  butterfly, (2) drawing `JointMarkerGuideLines` behind its butterfly, and
//  (3) drawing `JointMarkerBoxesLayer` on top, passing that same layout —
//  see `averagesButterflyPane` (AveragesWorkspaceViews.swift) and
//  `multiButterflyRow` (MultiButterflyView.swift) for the two hosts today.
//  Pass `isInteractive: false` in a static export figure so drag/remove/scale
//  controls (which mean nothing in a rendered image) don't get drawn into it.
//

import SwiftUI

/// One marker's resolved topomap tiles for a host's own `topomapSegments`,
/// honoring a live in-progress drag (`EpochingViewModel.jointMarkerLiveDrag`)
/// so every host showing that marker updates together while it's dragged in
/// any one of them.
private struct JointMarkerColumn: Identifiable {
    let marker: JointPlotMarker
    let liveRelativeSample: Int
    let samples: [AveragedTopomapSample]
    var id: UUID { marker.id }
}

private func jointMarkerColumns(
    view: WaveformView,
    topomapSegments: [EpochSegment],
    signal: MFFSignalData
) -> [JointMarkerColumn] {
    let liveDrag = view.epoching.jointMarkerLiveDrag
    return view.epoching.jointPlotMarkers.map { marker in
        let liveSample = (liveDrag?.id == marker.id) ? liveDrag!.relativeSample : marker.relativeSample
        let samples: [AveragedTopomapSample] = topomapSegments.compactMap { segment in
            let epochLength = max(segment.endSample - segment.startSample + 1, 1)
            let localSample = min(max(liveSample, 0), epochLength - 1)
            let sample = min(segment.startSample + localSample, segment.endSample)
            guard sample >= 0, sample < (signal.data.first?.count ?? 0) else { return nil }
            let latencySeconds = signal.samplingRate > 0
                ? Double(localSample - segment.stimulusOffsetSamples) / signal.samplingRate
                : 0
            return AveragedTopomapSample(category: segment.category, sample: sample, latencySeconds: latencySeconds, colorIndex: segment.colorIndex)
        }
        return JointMarkerColumn(marker: marker, liveRelativeSample: liveSample, samples: samples)
    }
}

private func jointMarkerXPosition(for relativeSample: Int, width: CGFloat, epochLength: Int) -> CGFloat {
    guard epochLength > 1 else { return 0 }
    return CGFloat(relativeSample) / CGFloat(epochLength - 1) * width
}

/// Greedy interval-partitioning: assigns each x position to the
/// lowest-numbered row such that no two positions sharing a row are closer
/// than `minSpacing` — the standard minimum-rows solution to this problem
/// (same idea calendar apps use to lay out overlapping events in columns,
/// just rows instead of columns here). A crowded cluster of markers simply
/// needs more rows; no position ever moves.
private func assignJointMarkerTiers(idealX: [CGFloat], minSpacing: CGFloat) -> [Int] {
    let order = idealX.indices.sorted { idealX[$0] < idealX[$1] }
    var tierRightEdge: [CGFloat] = []
    var tiers = [Int](repeating: 0, count: idealX.count)
    for index in order {
        let x = idealX[index]
        if let tier = tierRightEdge.firstIndex(where: { x - $0 >= minSpacing }) {
            tiers[index] = tier
            tierRightEdge[tier] = x
        } else {
            tiers[index] = tierRightEdge.count
            tierRightEdge.append(x)
        }
    }
    return tiers
}

/// The resolved "stadium" layout for one host's markers: which row each
/// marker's box sits in, how many rows exist, and the total area to
/// reserve for them. Computed once per host (from its own width, topomap
/// segment count, orientation, and scale) and threaded to
/// `JointMarkerGuideLines`/`JointMarkerBoxesLayer` so a butterfly's own
/// offset, the guide lines, and the boxes all agree.
struct JointMarkerLayout {
    fileprivate let tierByMarkerID: [UUID: Int]
    let tierCount: Int
    let boxAreaHeight: CGFloat
    fileprivate let tierSize: CGSize

    static let empty = JointMarkerLayout(tierByMarkerID: [:], tierCount: 0, boxAreaHeight: 0, tierSize: .zero)
}

extension WaveformView {
    /// Computes the stadium-seating layout for this host's markers at this
    /// host's own `width` (pass the export card's literal width, e.g. 820,
    /// when sizing a `figureSaveMenu` `size:` before rendering — see
    /// `AveragesButterflyFigure`/`MultiButterflyFigure`).
    func jointMarkerLayout(
        topomapSegments: [EpochSegment],
        signal: MFFSignalData,
        referenceSegment: EpochSegment,
        width: CGFloat,
        orientation: JointBoxOrientation = .vertical
    ) -> JointMarkerLayout {
        let markers = epoching.jointPlotMarkers
        guard !markers.isEmpty, !topomapSegments.isEmpty else { return .empty }

        let epochLength = max(referenceSegment.endSample - referenceSegment.startSample + 1, 1)
        let liveDrag = epoching.jointMarkerLiveDrag
        let idealX = markers.map { marker -> CGFloat in
            let sample = (liveDrag?.id == marker.id) ? liveDrag!.relativeSample : marker.relativeSample
            return jointMarkerXPosition(for: sample, width: width, epochLength: epochLength)
        }
        let tierSize = JointMarkerBox.size(forTopomapCount: topomapSegments.count, orientation: orientation, scale: epoching.jointTopomapScale)
        let tiers = assignJointMarkerTiers(idealX: idealX, minSpacing: tierSize.width + 16)
        let tierCount = (tiers.max() ?? 0) + 1

        var tierByMarkerID: [UUID: Int] = [:]
        for (index, marker) in markers.enumerated() { tierByMarkerID[marker.id] = tiers[index] }

        let tierGap: CGFloat = 10
        let boxAreaHeight = CGFloat(tierCount) * tierSize.height + CGFloat(max(tierCount - 1, 0)) * tierGap

        return JointMarkerLayout(tierByMarkerID: tierByMarkerID, tierCount: tierCount, boxAreaHeight: boxAreaHeight, tierSize: tierSize)
    }

    /// A width-independent upper-bound estimate of the box area height, for
    /// the rare spot that needs a number before its own width is known (a
    /// `ScrollView`/grid row's outer `.frame(height:)`, which has to be set
    /// before the `GeometryReader` inside it can report a real width).
    /// Assumes up to 3 stadium rows' worth of markers; if a host somehow
    /// needs more than that, the exact `jointMarkerLayout(width:)` used for
    /// the real render still lays them out correctly — only this estimate
    /// (and thus the outer row's height) would be a little short.
    func jointMarkerEstimatedBoxHeight(topomapSegmentCount: Int, orientation: JointBoxOrientation = .vertical) -> CGFloat {
        guard !epoching.jointPlotMarkers.isEmpty, topomapSegmentCount > 0 else { return 0 }
        let tierHeight = JointMarkerBox.size(forTopomapCount: topomapSegmentCount, orientation: orientation, scale: epoching.jointTopomapScale).height
        let estimatedTiers = min(epoching.jointPlotMarkers.count, 3)
        return CGFloat(estimatedTiers) * tierHeight + CGFloat(max(estimatedTiers - 1, 0)) * 10
    }

    /// The "Add Joint" context-menu row. `pointerRelativeSample` is whatever
    /// the host tracked from the last hover position (nil disables the item,
    /// e.g. before the pointer has ever been over the plot).
    @ViewBuilder
    func addJointMarkerMenuItem(pointerRelativeSample: Int?) -> some View {
        Button {
            if let pointerRelativeSample {
                epoching.addJointMarker(atRelativeSample: pointerRelativeSample)
            }
        } label: {
            Label("Add Joint", systemImage: "plus.circle")
        }
        .disabled(pointerRelativeSample == nil)
    }

    /// The joint-box "Layout" (orientation) + "Size" (topomap scale)
    /// controls, shown in a host's header once it has markers worth
    /// controlling (more than one condition for orientation; any markers at
    /// all for size).
    @ViewBuilder
    func jointBoxControls(showsOrientation: Bool) -> some View {
        if showsOrientation {
            Picker("Joint box layout", selection: Binding(
                get: { epoching.jointBoxOrientation },
                set: { epoching.jointBoxOrientation = $0 }
            )) {
                ForEach(JointBoxOrientation.allCases) { orientation in
                    Text(orientation.rawValue).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .help("How joint marker boxes arrange more than one condition's topomap.")
        }
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { epoching.jointTopomapScale }, set: { epoching.jointTopomapScale = $0 }),
                in: 0.6...2.2
            )
            .frame(width: 90)
        }
        .help("Size of joint marker topomaps.")
    }
}

/// Dashed vertical guide lines from the top of the reserved box space down
/// through the whole host (butterfly + GFP strip, if shown) at each marker's
/// x. Always a plain vertical line — boxes never move off their true x
/// (see the file header), so there's nothing to bend around any more.
struct JointMarkerGuideLines: View {
    let view: WaveformView
    let topomapSegments: [EpochSegment]
    let signal: MFFSignalData
    let referenceSegment: EpochSegment
    let width: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        let epochLength = max(referenceSegment.endSample - referenceSegment.startSample + 1, 1)
        let columns = jointMarkerColumns(view: view, topomapSegments: topomapSegments, signal: signal)
        Canvas { context, size in
            for column in columns {
                let x = jointMarkerXPosition(for: column.liveRelativeSample, width: width, epochLength: epochLength)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(width: width, height: totalHeight)
    }
}

/// The draggable topomap boxes themselves, one per marker, positioned at its
/// true x and its assigned stadium row (`markerLayout`). Dragging anywhere
/// inside a box retimes that marker; every host currently displaying it
/// (e.g. every Multi-Butterfly row) updates together via the shared
/// `jointMarkerLiveDrag`/`jointPlotMarkers`. Pass `isInteractive: false` for
/// a static export figure — no drag, no remove button, no scale menu.
struct JointMarkerBoxesLayer: View {
    let view: WaveformView
    let layout: SensorLayout
    let signal: MFFSignalData
    let topomapSegments: [EpochSegment]
    let referenceSegment: EpochSegment
    let width: CGFloat
    let markerLayout: JointMarkerLayout
    /// Unique per host instance so simultaneous drags on different hosts
    /// (e.g. two Multi-Butterfly rows) don't share one coordinate space.
    let coordinateSpaceName: String
    var isInteractive: Bool = true
    var orientation: JointBoxOrientation = .vertical

    var body: some View {
        let epochLength = max(referenceSegment.endSample - referenceSegment.startSample + 1, 1)
        let columns = jointMarkerColumns(view: view, topomapSegments: topomapSegments, signal: signal)
        let sharedSamples = columns.flatMap(\.samples)
        let sharedScale = view.fixedTopomapScale(for: sharedSamples.map(\.sample), in: signal)
        let sharedColorRange = view.topomapColorRange()
        let sharedAutoZ = view.topomapAutoZ(samples: sharedSamples, in: signal)
        let sharedZScaling = view.topomapZScaling(auto: sharedAutoZ)
        let tileWidth = markerLayout.tierSize.width
        let halfTileWidth = tileWidth / 2

        ForEach(columns) { column in
            let x = jointMarkerXPosition(for: column.liveRelativeSample, width: width, epochLength: epochLength)
            let positionX = min(max(x, halfTileWidth), max(width - halfTileWidth, halfTileWidth))
            let tier = markerLayout.tierByMarkerID[column.marker.id] ?? 0
            let tierTopY = CGFloat(markerLayout.tierCount - 1 - tier) * (markerLayout.tierSize.height + 10)
            let positionY = tierTopY + markerLayout.tierSize.height / 2
            let ownAutoZ = view.topomapAutoZ(samples: column.samples, in: signal)

            JointMarkerBox(
                view: view,
                layout: layout,
                signal: signal,
                column: column,
                scale: view.epoching.jointTopomapScale,
                orientation: orientation,
                topomapScale: column.marker.scaleMode == .microvolts
                    ? view.fixedTopomapScale(for: column.samples.map(\.sample), in: signal)
                    : (column.marker.scaleMode == nil ? sharedScale : nil),
                colorRange: column.marker.scaleMode == nil ? sharedColorRange : nil,
                zScaling: column.marker.scaleMode == .zScore
                    ? TopomapZScaling(mean: ownAutoZ.mean, sd: ownAutoZ.sd, sigma: view.epoching.topomapZSigma)
                    : (column.marker.scaleMode == nil ? sharedZScaling : nil),
                onRemove: isInteractive ? { view.epoching.removeJointMarker(column.marker.id) } : nil,
                onSetScaleMode: isInteractive ? { view.epoching.setJointMarkerScaleMode(column.marker.id, mode: $0) } : nil
            )
            .position(x: positionX, y: positionY)
            .modifier(JointMarkerDragModifier(
                isInteractive: isInteractive,
                view: view,
                markerID: column.marker.id,
                referenceSegment: referenceSegment,
                width: width,
                epochLength: epochLength,
                coordinateSpaceName: coordinateSpaceName
            ))
        }
    }
}

/// Splits the drag gesture out so export figures (`isInteractive: false`)
/// attach no gesture at all, rather than a gesture that would just never fire.
private struct JointMarkerDragModifier: ViewModifier {
    let isInteractive: Bool
    let view: WaveformView
    let markerID: UUID
    let referenceSegment: EpochSegment
    let width: CGFloat
    let epochLength: Int
    let coordinateSpaceName: String

    func body(content: Content) -> some View {
        if isInteractive {
            content.gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
                    .onChanged { value in
                        let sample = view.relativeSample(forButterflyX: value.location.x, width: width, segment: referenceSegment)
                        view.epoching.jointMarkerLiveDrag = (markerID, sample)
                    }
                    .onEnded { value in
                        let sample = view.relativeSample(forButterflyX: value.location.x, width: width, segment: referenceSegment)
                        view.epoching.jointMarkerLiveDrag = nil
                        view.epoching.updateJointMarker(markerID, relativeSample: sample, epochLength: epochLength)
                    }
            )
        } else {
            content
        }
    }
}

/// One marker's topomap tile: latency label, one topomap per
/// `topomapSegments` entry, and (when interactive) a remove ("x") button and
/// a right-click scale-mode menu.
///
/// Four layouts, all scaling their tiles with `scale`:
/// - **Single topomap** (any Multi-Butterfly row; Butterfly pane with one
///   condition): time above, map below — the original, compact form, no
///   per-condition label since there's only one condition to begin with.
/// - **Multiple, `.vertical`**: time once above; each condition gets its own
///   row with the label to the LEFT of its map.
/// - **Multiple, `.horizontal`**: time once above, centered; conditions sit
///   in a full-size row, each with its own label ABOVE its map — the box
///   grows wider per condition rather than shrinking the tiles.
/// - **Multiple, `.fit`**: a roughly-square grid (e.g. 4 conditions → 2×2),
///   each tile labeled above, for when a single row or column would get
///   unwieldy with many conditions.
struct JointMarkerBox: View {
    private static let baseTileInnerSize: CGFloat = 170
    private static let padding: CGFloat = 6
    private static let spacing: CGFloat = 4
    private static let timeLabelAllowance: CGFloat = 22
    private static let conditionLabelAllowance: CGFloat = 13
    private static let verticalLabelWidth: CGFloat = 26

    /// The box's total size for this many topomaps/orientation/scale — used
    /// both to reserve stadium-row space (`WaveformView.jointMarkerLayout`,
    /// before any box exists) and by this view's own rendering, so the two
    /// can never disagree.
    static func size(forTopomapCount count: Int, orientation: JointBoxOrientation, scale: Double) -> CGSize {
        let tile = baseTileInnerSize * CGFloat(scale)
        let pad = padding * 2

        if count <= 1 {
            return CGSize(width: tile + pad, height: tile + timeLabelAllowance + pad)
        }
        switch orientation {
        case .vertical:
            return CGSize(
                width: tile + verticalLabelWidth + spacing + pad,
                height: tile * CGFloat(count) + spacing * CGFloat(count - 1) + timeLabelAllowance + pad
            )
        case .horizontal:
            return CGSize(
                width: tile * CGFloat(count) + spacing * CGFloat(count - 1) + pad,
                height: tile + conditionLabelAllowance + timeLabelAllowance + pad
            )
        case .fit:
            let columns = max(Int(ceil(sqrt(Double(count)))), 1)
            let rows = Int(ceil(Double(count) / Double(columns)))
            return CGSize(
                width: tile * CGFloat(columns) + spacing * CGFloat(columns - 1) + pad,
                height: (tile + conditionLabelAllowance) * CGFloat(rows) + spacing * CGFloat(rows - 1) + timeLabelAllowance + pad
            )
        }
    }

    let view: WaveformView
    let layout: SensorLayout
    let signal: MFFSignalData
    fileprivate let column: JointMarkerColumn
    let scale: Double
    var orientation: JointBoxOrientation = .vertical
    let topomapScale: Double?
    let colorRange: ClosedRange<Double>?
    let zScaling: TopomapZScaling?
    let onRemove: (() -> Void)?
    var onSetScaleMode: ((EpochingViewModel.TopomapScaleMode?) -> Void)? = nil

    private var tile: CGFloat { Self.baseTileInnerSize * CGFloat(scale) }

    var body: some View {
        Group {
            if column.samples.count == 1 {
                VStack(spacing: 6) {
                    Text(String(format: "%.3f s", column.samples.first?.latencySeconds ?? 0))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                    if let entry = column.samples.first {
                        topomapTile(for: entry, showsLabel: false, tileSize: tile)
                    }
                }
                .padding(Self.padding)
            } else if orientation == .fit {
                let columns = max(Int(ceil(sqrt(Double(column.samples.count)))), 1)
                VStack(spacing: 6) {
                    Text(String(format: "%.3f s", column.samples.first?.latencySeconds ?? 0))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: Self.spacing), count: columns), spacing: Self.spacing) {
                        ForEach(column.samples) { entry in
                            topomapTile(for: entry, showsLabel: true, tileSize: tile)
                        }
                    }
                }
                .padding(Self.padding)
            } else if orientation == .horizontal {
                VStack(spacing: 6) {
                    Text(String(format: "%.3f s", column.samples.first?.latencySeconds ?? 0))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                    HStack(spacing: Self.spacing) {
                        ForEach(column.samples) { entry in
                            topomapTile(for: entry, showsLabel: true, tileSize: tile)
                        }
                    }
                }
                .padding(Self.padding)
            } else {
                VStack(spacing: 6) {
                    Text(String(format: "%.3f s", column.samples.first?.latencySeconds ?? 0))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                    VStack(spacing: Self.spacing) {
                        ForEach(column.samples) { entry in
                            HStack(spacing: Self.spacing) {
                                Text(view.epoching.displayCategory(entry.category))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(view.epochColor(for: entry.colorIndex))
                                    .lineLimit(1)
                                    .frame(width: Self.verticalLabelWidth, alignment: .trailing)
                                topomapTile(for: entry, showsLabel: false, tileSize: tile)
                            }
                        }
                    }
                }
                .padding(Self.padding)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help("Remove this marker.")
            }
        }
        .contextMenu {
            if let onSetScaleMode {
                Button {
                    onSetScaleMode(nil)
                } label: {
                    if column.marker.scaleMode == nil {
                        Label("Shared Scale", systemImage: "checkmark")
                    } else {
                        Text("Shared Scale")
                    }
                }
                Button {
                    onSetScaleMode(.microvolts)
                } label: {
                    if column.marker.scaleMode == .microvolts {
                        Label("Fixed µV Scale (this marker)", systemImage: "checkmark")
                    } else {
                        Text("Fixed µV Scale (this marker)")
                    }
                }
                Button {
                    onSetScaleMode(.zScore)
                } label: {
                    if column.marker.scaleMode == .zScore {
                        Label("Standard Deviation (this marker)", systemImage: "checkmark")
                    } else {
                        Text("Standard Deviation (this marker)")
                    }
                }
                if onRemove != nil {
                    Divider()
                }
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Marker", systemImage: "trash")
                }
            }
        }
    }

    private func topomapTile(for entry: AveragedTopomapSample, showsLabel: Bool, tileSize: CGFloat) -> some View {
        VStack(spacing: 2) {
            if showsLabel {
                Text(view.epoching.displayCategory(entry.category))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(view.epochColor(for: entry.colorIndex))
                    .lineLimit(1)
            }
            TopomapView(
                layout: layout,
                values: view.topomapValues(at: entry.sample, in: signal),
                timeSeconds: entry.latencySeconds,
                fixedScale: topomapScale,
                colorRange: colorRange,
                zScaling: zScaling,
                showsHeader: false,
                showsLayoutName: false,
                colorBarPlacement: .none,
                minimumMapHeight: tileSize
            )
            .frame(width: tileSize, height: tileSize)
        }
    }
}
