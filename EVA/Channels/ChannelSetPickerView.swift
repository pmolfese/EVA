//
//  ChannelSetPickerView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Reusable inline picker for selecting a channel set. Embeds a Picker
//  (with a "None" option and all available sets) alongside a "Define…"
//  button that opens the Channel Sets window.
//
//  Usage:
//    ChannelSetPickerView(
//        label: "BCG Proxy Set",
//        selectedSetID: $proxySetID,
//        filterNetType: recording.sensorLayout?.name
//    )
//

import SwiftUI

struct ChannelSetPickerView: View {
    /// Sentinel ID used for the optional "Custom" entry, so callers can detect
    /// it via `selectedSetID == ChannelSetPickerView.customSentinel`.
    static let customSentinel = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

    let label: String
    @Binding var selectedSetID: ChannelSet.ID?
    /// Channel count of the active recording. Sets whose highest channel index
    /// exceeds this are hidden (e.g. a 256-net BCG set on a 128-net file).
    /// Pass 0 to disable the compatibility filter.
    var channelCount: Int
    /// When true, adds a "Custom" entry (tagged `customSentinel`) for callers
    /// that fall back to a manual channel-list field.
    var includesCustom: Bool = false
    /// The active recording's net name, if the caller has one handy — sets
    /// tagged for a *different* net are hidden. A set tagged "Any Net"
    /// (`netType == nil`) always stays, same reasoning as the Channel Sets
    /// editor's own filter: it's explicitly meant to apply regardless.
    /// `nil` (the default) disables this filter — every existing call site
    /// predates this parameter and passes nothing, so behavior is unchanged
    /// unless a caller opts in.
    var filterNetType: String? = nil

    @Environment(\.openWindow) private var openWindow
    private var store: ChannelSetStore { .shared }

    private var filteredSets: [ChannelSet] {
        store.allSets.filter { set in
            if channelCount > 0, (set.channelIndices.max() ?? -1) >= channelCount { return false }
            if let filterNetType, let netType = set.netType, netType != filterNetType { return false }
            return true
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker(label, selection: $selectedSetID) {
                Text("None").tag(Optional<ChannelSet.ID>(nil))
                if includesCustom {
                    Text("Custom").tag(Optional(Self.customSentinel))
                }
                if !filteredSets.isEmpty {
                    Divider()
                    ForEach(filteredSets) { set in
                        Text(set.name).tag(Optional(set.id))
                    }
                }
            }
            .labelsHidden()

            Button("Define…") {
                openWindow(id: EVAApp.channelSetsWindowID)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}
