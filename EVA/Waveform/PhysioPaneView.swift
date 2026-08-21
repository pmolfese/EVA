//
//  PhysioPaneView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The pinned physio (PNS) pane below the EEG channels, extracted from the
//  presentational half of `WaveformView.physioPane(_:eegSamplingRate:)`
//  (ROADMAP Priority 1, B2).
//
//  Scope of the extraction, and why it stops where it does: this view renders the
//  label column and the trace track. The `.task(id:)` that recomputes physio
//  ranges and the rename `.alert` stay on the `WaveformView` side, because they
//  are state plumbing rather than rendering — moving them would put writes to
//  `PhysioDisplayModel` behind a view whose job is to display it.
//
//  It takes `PhysioDisplayModel` (the B4 model) directly rather than a dozen
//  unpacked values. That is the right call *here* — unlike `StatusLogView`, every
//  property on that model affects what this pane draws, so there is nothing to
//  gain by flattening and a lot of parameter noise to lose. Observation still
//  tracks reads per property.
//
//  The two context menus arrive as generic `@ViewBuilder` closures so the pane
//  need not know about `WaveformView`. Two generic parameters is a deliberate
//  ceiling: deep generic nesting is what made the body's type metadata expensive
//  to instantiate in the first place (see `WaveformSheetHost.swift`).
//

import SwiftUI

struct PhysioPaneView<ChannelMenu: View, RowMenu: View, TrackOverlay: View>: View {
    let signal: MFFSignalData
    let physio: PhysioDisplayModel
    /// Resolved display name per channel index (rename-aware).
    let displayNames: [String]
    /// Optional "Max"/"×8" badge per channel index.
    let scaleBadge: (Int) -> String?
    let rowHeight: CGFloat
    let labelColumnWidth: CGFloat
    let eegSamplingRate: Double
    let sampleStride: Int
    let timeScale: Double
    let contentOffset: CGFloat
    let viewportWidth: CGFloat
    let showsTimeMarkers: Bool
    let timeMarkerStyle: WaveformTimeMarkerStyle
    /// Context menu for a label-column row.
    @ViewBuilder let channelMenu: (Int, String) -> ChannelMenu
    /// Transparent per-row hit targets carrying the same menu over the track.
    @ViewBuilder let trackMenuOverlay: () -> RowMenu
    /// Selection/artifact/cursor highlight bands, in the same content-space x
    /// coordinates as the EEG pane's overlays, so a tapped event highlights
    /// through the physio traces too.
    @ViewBuilder let trackHighlightOverlay: () -> TrackOverlay

    private func name(_ index: Int) -> String {
        displayNames.indices.contains(index) ? displayNames[index] : "PNS \(index + 1)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                labelColumn
                    .frame(width: labelColumnWidth, alignment: .topLeading)

                ZStack(alignment: .topLeading) {
                    PhysioTrackView(
                        signal: signal,
                        ranges: physio.ranges,
                        scaleFactors: physio.scaleFactors,
                        maxScaledChannels: physio.maxScaledChannels,
                        flippedPolarity: physio.flippedPolarity,
                        rowHeight: rowHeight,
                        eegSamplingRate: eegSamplingRate,
                        sampleStride: sampleStride,
                        timeScale: timeScale,
                        contentOffset: contentOffset,
                        viewportWidth: viewportWidth,
                        showsTimeMarkers: showsTimeMarkers,
                        timeMarkerStyle: timeMarkerStyle,
                        names: displayNames
                    )
                    // The highlight bands size themselves with
                    // `.frame(maxHeight: .infinity)`, so they must ride as an
                    // `.overlay` on the track — as a ZStack *sibling* they
                    // propose an unbounded height and the pane grows to eat
                    // every spare point the EEG stack would have had.
                    //
                    // `-contentOffset` converts the bands' content-space x
                    // (0 == first sample, which is what the EEG stack uses,
                    // since its overlays live *inside* the horizontal
                    // ScrollView) into this track's viewport space, where
                    // x == 0 is the left edge of the visible window. Without
                    // it the band lands correctly only at scroll offset 0 and
                    // drifts by exactly the scroll distance everywhere else.
                    .overlay(alignment: .topLeading) {
                        trackHighlightOverlay()
                            .offset(x: -contentOffset)
                            .allowsHitTesting(false)
                    }
                    .clipped()
                    .padding(.top, 16)   // align below the "Physio" header

                    trackMenuOverlay()
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Physio")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(height: 16, alignment: .leading)

            ForEach(0..<signal.numberOfChannels, id: \.self) { index in
                let name = name(index)
                HStack(spacing: 5) {
                    Text(name)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let badge = scaleBadge(index) {
                        Text(badge)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if physio.flippedPolarity.contains(index) {
                        Text("flip")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .help("Right-click to adjust physio scaling and polarity.")
                .contextMenu {
                    channelMenu(index, name)
                }
            }
        }
    }
}
