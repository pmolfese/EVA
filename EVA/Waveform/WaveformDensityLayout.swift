//
//  WaveformDensityLayout.swift
//  EVA
//
//  Display-only channel-density geometry. This never changes samples, channel
//  membership, processing history, or eva.xml.
//

import CoreGraphics

nonisolated enum WaveformDensityMode: Hashable, Sendable {
    case fit
    case fixed(Int)

    var requestedCount: Int? {
        guard case .fixed(let count) = self else { return nil }
        return count
    }
}

nonisolated struct WaveformDensityGeometry: Equatable, Sendable {
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let channelsPerScreen: Int

    var rowPitch: CGFloat { rowHeight + rowSpacing }
}

nonisolated enum WaveformDensityLayout {
    static let maximumChannelsPerScreen = 64
    static let minimumChannelsPerScreen = 1
    static let fitRowHeight = WaveformScaleUnits.channelRowHeight
    static let fitRowSpacing: CGFloat = 12
    /// Six points is the compact label renderer's legibility floor. If an
    /// unusually short viewport cannot physically fit it, spacing falls to zero
    /// before the row itself yields.
    static let minimumRowHeight: CGFloat = 6

    /// Caps the rendered row count to the currently displayed set without
    /// overwriting the user's fixed-density preference. A target of 64 can
    /// therefore show all 28 channels in a Frontal set, then return to 64 when
    /// the user switches back to a larger set.
    static func effectiveMode(
        _ requested: WaveformDensityMode,
        availableChannelCount: Int
    ) -> WaveformDensityMode {
        guard case .fixed(let count) = requested else { return requested }
        return .fixed(min(max(availableChannelCount, 1), max(count, 1)))
    }

    /// Exact height of a channel stack using `geometry` for every row.
    ///
    /// The label and trace columns live in separate SwiftUI stacks because the
    /// traces also sit inside a horizontal `ScrollView`. Giving that nested
    /// scroller this explicit height keeps its AppKit document view in lockstep
    /// with the labels when density changes all row dimensions at once.
    static func stackHeight(
        rowCount: Int,
        geometry: WaveformDensityGeometry
    ) -> CGFloat {
        let count = max(rowCount, 0)
        guard count > 0 else { return 0 }
        return CGFloat(count) * geometry.rowHeight
            + CGFloat(count - 1) * geometry.rowSpacing
    }

    /// Geometry for the vertically scrollable EEG viewport only. Its height is
    /// measured after the event track and pinned physio pane have taken space.
    static func geometry(
        mode: WaveformDensityMode,
        viewportHeight: CGFloat
    ) -> WaveformDensityGeometry {
        let height = max(viewportHeight, 1)
        switch mode {
        case .fit:
            let count = max(
                Int(floor((height + fitRowSpacing) / (fitRowHeight + fitRowSpacing))),
                1
            )
            return WaveformDensityGeometry(
                rowHeight: fitRowHeight,
                rowSpacing: fitRowSpacing,
                channelsPerScreen: count
            )

        case .fixed(let rawCount):
            let count = min(
                max(rawCount, minimumChannelsPerScreen),
                maximumChannelsPerScreen
            )
            // At ordinary densities retain the existing 12-point breathing
            // room. At dense settings, spacing yields to the traces instead of
            // consuming the entire viewport before a row is drawn.
            let approximatePitch = height / CGFloat(count)
            let usableMinimumRowHeight = min(minimumRowHeight, approximatePitch)
            let spacingAllowedByFloor: CGFloat
            if count > 1 {
                spacingAllowedByFloor = max(
                    (height - usableMinimumRowHeight * CGFloat(count)) / CGFloat(count - 1),
                    0
                )
            } else {
                spacingAllowedByFloor = fitRowSpacing
            }
            let spacing = min(
                fitRowSpacing,
                max(0, approximatePitch * 0.12),
                spacingAllowedByFloor
            )
            let rowHeight = max(
                (height - spacing * CGFloat(max(count - 1, 0))) / CGFloat(count),
                usableMinimumRowHeight
            )
            return WaveformDensityGeometry(
                rowHeight: rowHeight,
                rowSpacing: spacing,
                channelsPerScreen: count
            )
        }
    }
}
