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
    let overflowHeight: CGFloat
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
            timeMarkerStyle: timeMarkerStyle
        )
        .frame(width: plotWidth, height: rowHeight + (overflowHeight * 2))
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: plotWidth, height: rowHeight)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                .frame(width: plotWidth, height: rowHeight)
        }
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
struct ChannelLabelRow: View {
    let index: Int
    let label: String
    let isHidden: Bool
    let isBad: Bool
    let isInterpolated: Bool
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
