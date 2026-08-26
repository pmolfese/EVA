//
//  WaveformChannelRows.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Standalone per-channel row views, extracted from the `channelLabel` /
//  `waveformRow` methods on `WaveformView` (ROADMAP Priority 1, B1). Both are
//  real `View` *types* rather than functions on the giant `WaveformView` struct,
//  so SwiftUI can diff them and the two channel-stack `ForEach`s no longer copy
//  the whole 118-property `WaveformView` on every row (the 393-sample
//  `initializeWithCopy` in the hang trace). They take plain value inputs plus
//  action closures — never `self` — so a `progress` tick or unrelated `@State`
//  write can't invalidate them.
//
//  `WaveformChannelRow` is `Equatable` (compared by a cheap revision key, not the
//  raw `[Float]`) and marked `.equatable()` at the call site so rows whose data +
//  viewport didn't change skip the Canvas redraw entirely.
//

import SwiftUI

/// One trace row in the horizontally-scrolling channel stack.
///
/// Equality is by `(dataRevision, index, isHidden)` — the samples drawn are a
/// pure function of those three — plus the viewport/scale/appearance inputs, so
/// `==` stays O(1) instead of comparing the full sample buffer. Action closures
/// are excluded from `==` (they carry no comparable identity); the disabled/label
/// state they depend on is represented by the compared value inputs.
struct WaveformChannelRow: View, Equatable {
    let index: Int
    /// Trace samples for this row: `[]` when the channel is hidden (the row keeps
    /// its slot but draws nothing), otherwise the channel's series.
    let samples: [Float]
    let samplingRate: Double
    /// Identity of the underlying sample-data version, used for equality so the
    /// row need not compare `samples` element-by-element.
    let dataRevision: UUID
    let isHidden: Bool
    let amplitudeScale: Double
    let timeScale: Double
    let sampleStride: Int
    let visibleRange: ClosedRange<CGFloat>
    let plotWidth: CGFloat
    let rowHeight: CGFloat
    /// Points of headroom above and below the row that the trace may travel
    /// into before the canvas clips it. Zero clips exactly at the row edge.
    let overflowHeight: CGFloat
    /// Mark excursions that left the drawable area — see
    /// `EVAGeneralPreferences.traceClipIndicatorsKey`.
    let showsClipIndicators: Bool
    let color: Color
    let usesPixelAdaptiveRendering: Bool
    let showsTimeMarkers: Bool
    let timeMarkerStyle: WaveformTimeMarkerStyle
    /// Whether a time selection exists, enabling "Define Artifact…".
    let canDefineArtifact: Bool
    /// Pre-resolved "Move <name> to Physio" menu title.
    let moveToPhysioTitle: String
    let onDefineArtifact: () -> Void
    let onMoveToPhysio: () -> Void

    static func == (lhs: WaveformChannelRow, rhs: WaveformChannelRow) -> Bool {
        lhs.index == rhs.index
            && lhs.samplingRate == rhs.samplingRate
            && lhs.dataRevision == rhs.dataRevision
            && lhs.isHidden == rhs.isHidden
            && lhs.amplitudeScale == rhs.amplitudeScale
            && lhs.timeScale == rhs.timeScale
            && lhs.sampleStride == rhs.sampleStride
            && lhs.visibleRange == rhs.visibleRange
            && lhs.plotWidth == rhs.plotWidth
            && lhs.rowHeight == rhs.rowHeight
            && lhs.overflowHeight == rhs.overflowHeight
            && lhs.showsClipIndicators == rhs.showsClipIndicators
            && lhs.color == rhs.color
            && lhs.usesPixelAdaptiveRendering == rhs.usesPixelAdaptiveRendering
            && lhs.showsTimeMarkers == rhs.showsTimeMarkers
            && lhs.timeMarkerStyle == rhs.timeMarkerStyle
            && lhs.canDefineArtifact == rhs.canDefineArtifact
            && lhs.moveToPhysioTitle == rhs.moveToPhysioTitle
    }

    var body: some View {
        WaveformPlot(
            samples: samples,
            samplingRate: samplingRate,
            amplitudeScale: amplitudeScale,
            timeScale: timeScale,
            sampleStride: sampleStride,
            visibleRange: visibleRange,
            nominalHeight: rowHeight,
            color: color,
            usesPixelAdaptiveRendering: usesPixelAdaptiveRendering,
            showsTimeMarkers: showsTimeMarkers,
            timeMarkerStyle: timeMarkerStyle,
            showsClipIndicators: showsClipIndicators
        )
        // Trace only — no background, no border. Row chrome is drawn once for
        // the whole stack by `WaveformView.channelRowBackdrop`, beneath every
        // trace.
        //
        // Not a style choice: a row that paints its own opaque background
        // paints it *over* whatever the row above bled downward into it, so
        // self-drawn chrome makes overflow visible upward and invisible
        // downward — and only by accident of sibling paint order, since every
        // row carries the same `zIndex`. One shared layer underneath removes
        // both the asymmetry and the dependence on ordering.
        .frame(width: plotWidth, height: rowHeight + (overflowHeight * 2))
        .frame(width: plotWidth, height: rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Define Artifact…", action: onDefineArtifact)
                .disabled(!canDefineArtifact)

            Divider()
            Button(moveToPhysioTitle, action: onMoveToPhysio)
        }
        .accessibilityLabel("Channel \(index + 1)")
        .zIndex(1)
    }
}

/// One label-column row: channel name, state icon (hidden/interpolated/bad),
/// health badge, and the per-channel context menu. Value inputs + action
/// closures only — no `WaveformView`/`ChannelModel` capture.
///
/// `Equatable` for the same reason `WaveformChannelRow` is, and it was measured
/// to matter more: in `trace2.trace` the label column cost ~3× the trace rows
/// (721 vs 235 inclusive samples) precisely because B1 gave the plot row a skip
/// boundary and left this one without. Action closures are excluded from `==`;
/// everything they depend on is represented by the compared value inputs.
struct ChannelLabelRow: View, Equatable {
    let index: Int
    let label: String
    let isHidden: Bool
    let isBad: Bool
    let isInterpolated: Bool
    /// Set when a repair this file's own record claims could not be re-solved
    /// here — the reason, ready to show. The channel is bad again; this is what
    /// keeps that from looking like an ordinary bad channel nobody ever tried
    /// to fix (ROADMAP RW-1 item 3).
    let interpolationLostReason: String?
    let color: Color
    let rowHeight: CGFloat
    let healthResult: ChannelHealthResult?
    let isAnalyzingHealth: Bool
    /// Whether the channel has electrode geometry, enabling "Interpolate".
    let canInterpolate: Bool
    /// Pre-resolved "Move <name> to Physio" menu title.
    let moveToPhysioTitle: String
    let onActivateHealth: () -> Void
    let onToggleHidden: () -> Void
    let onMarkBad: () -> Void
    let onUnmarkBad: () -> Void
    let onInterpolate: () -> Void
    let onRemoveInterpolation: () -> Void
    let onMoveToPhysio: () -> Void
    let onExportJSON: () -> Void
    let onExportJSONWithEvents: () -> Void
    let onExport1D: () -> Void
    let onExport1DWithEvents: () -> Void

    static func == (lhs: ChannelLabelRow, rhs: ChannelLabelRow) -> Bool {
        lhs.index == rhs.index
            && lhs.label == rhs.label
            && lhs.isHidden == rhs.isHidden
            && lhs.isBad == rhs.isBad
            && lhs.isInterpolated == rhs.isInterpolated
            && lhs.interpolationLostReason == rhs.interpolationLostReason
            && lhs.color == rhs.color
            && lhs.rowHeight == rhs.rowHeight
            && lhs.healthResult == rhs.healthResult
            && lhs.isAnalyzingHealth == rhs.isAnalyzingHealth
            && lhs.canInterpolate == rhs.canInterpolate
            && lhs.moveToPhysioTitle == rhs.moveToPhysioTitle
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isHidden {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                } else if isInterpolated {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                } else if let interpolationLostReason {
                    // Distinct from a plain bad channel: this one was repaired
                    // in the record and is not repaired here.
                    Image(systemName: "wand.and.stars.inverse")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Interpolation lost — \(interpolationLostReason)")
                } else if isBad {
                    Image(systemName: "xmark.circle")
                        .font(.caption2)
                }
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)

            ChannelHealthBadge(
                result: healthResult,
                isAnalyzing: isAnalyzingHealth,
                onActivate: onActivateHealth
            )
        }
        .opacity(isHidden ? 0.4 : 1)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleHidden)
        .help("Click to show/hide the trace. Right-click for Mark Bad / Interpolate.")
        .contextMenu {
            if isBad {
                Button("Unmark Bad", action: onUnmarkBad)
            } else {
                Button("Mark Bad", action: onMarkBad)
            }

            if isInterpolated {
                Button("Remove Interpolation", action: onRemoveInterpolation)
            } else if interpolationLostReason != nil {
                // Offer the retry directly: the usual reason a lost repair can
                // succeed on a second attempt is that the ambient state changed
                // (another channel unmarked, geometry loaded).
                Button("Interpolate", action: onInterpolate)
                    .disabled(!canInterpolate)
            } else {
                Button("Interpolate", action: onInterpolate)
                    .disabled(!canInterpolate)
            }

            Divider()
            Button(isHidden ? "Show Trace" : "Hide Trace", action: onToggleHidden)

            Divider()
            Button(moveToPhysioTitle, action: onMoveToPhysio)

            Divider()
            Menu("Export Channel") {
                Button("Export as JSON…", action: onExportJSON)
                Button("Export as JSON with Events…", action: onExportJSONWithEvents)
                Button("Export as 1D…", action: onExport1D)
                Button("Export as 1D with Events…", action: onExport1DWithEvents)
            }
        }
    }
}
