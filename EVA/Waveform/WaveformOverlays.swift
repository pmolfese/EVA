//
//  WaveformOverlays.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The three interaction-hot waveform overlays, extracted from
//  `extension WaveformView` (ROADMAP Priority 1, B2).
//
//  These are the overlays that redraw *during a selection drag*, which is exactly
//  where `trace2.trace` shows `initializeWithCopy for WaveformView` spiking
//  (133–159 samples per 0.5 s at t≈21.5/25.0/27.5/28.0). As methods on
//  `WaveformView` each one was a closure capturing `self`, so every drag tick
//  copied the whole 100-plus-property view struct six times over. As value-input
//  structs they capture nothing.
//
//  They take pre-resolved x positions rather than a signal plus a converter, so
//  the geometry math stays in one place in the parent and these stay trivially
//  checkable. All are `Equatable`, so an unrelated body pass cannot redraw them.
//
//  Deliberately *not* moved here: `segmentHealthOverlay` and
//  `epochBoundaryOverlay`. Neither changes during an interaction — they are
//  functions of the health/epoch results — so they are not on the hot path and
//  carry much more surrounding logic. Extracting them would be churn without a
//  measured reason.
//

import SwiftUI

/// Vertical line marking the sample the topomap is showing.
struct WaveformCursorOverlay: View, Equatable {
    /// Content-space x of the cursor, or nil when no topomap sample is selected.
    let positionX: CGFloat?

    var body: some View {
        if let positionX {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: positionX - 1)
                .allowsHitTesting(false)
        }
    }
}

/// Highlighted time selection across the full channel stack.
///
/// Uses a fixed blue (not the system accent) so it can never be confused with
/// the orange topomap cursor, regardless of the user's macOS accent colour.
struct WaveformSelectionOverlay: View, Equatable {
    /// Content-space x bounds of the selection, or nil when nothing is selected.
    let range: ClosedRange<CGFloat>?

    var body: some View {
        if let range {
            let color = Color(nsColor: .systemBlue)
            Rectangle()
                .fill(color.opacity(0.16))
                .frame(width: max(range.upperBound - range.lowerBound, 2))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle().fill(color.opacity(0.8)).frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(color.opacity(0.8)).frame(width: 1)
                }
                .offset(x: range.lowerBound)
                .allowsHitTesting(false)
        }
    }
}

/// Translucent band spanning the window of the tapped artifact event, drawn in
/// the event's flag color.
struct WaveformArtifactHighlightOverlay: View, Equatable {
    /// Content-space x bounds of the artifact window, or nil when none is tapped.
    let range: ClosedRange<CGFloat>?
    let color: Color

    var body: some View {
        if let range {
            Rectangle()
                .fill(color.opacity(0.18))
                .frame(width: max(range.upperBound - range.lowerBound, 2))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle().fill(color.opacity(0.7)).frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(color.opacity(0.7)).frame(width: 1)
                }
                .offset(x: range.lowerBound)
                .allowsHitTesting(false)
        }
    }
}
