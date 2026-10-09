//
//  DisplayChannels.swift
//  EVA
//
//  Shared resolution and focused-window controls for choosing which ordered
//  channel set the waveform displays. This is presentation state only: it
//  never changes hidden/bad/interpolated state or the underlying signal.
//

import SwiftUI

nonisolated enum DisplayChannelsResolver {
    /// Validates bounds and removes duplicate indices without disturbing the
    /// authored display order. An empty set is not useful as a display set.
    static func normalizedOrder(
        _ indices: [Int],
        channelCount: Int
    ) -> [Int]? {
        guard channelCount > 0, !indices.isEmpty else { return nil }

        var seen = Set<Int>()
        var result: [Int] = []
        result.reserveCapacity(indices.count)
        for index in indices {
            guard (0..<channelCount).contains(index) else { return nil }
            if seen.insert(index).inserted {
                result.append(index)
            }
        }
        return result.isEmpty ? nil : result
    }

    static func isCompatible(
        _ set: ChannelSet,
        channelCount: Int,
        netType: String?
    ) -> Bool {
        if let requiredNet = set.netType, requiredNet != netType {
            return false
        }
        return normalizedOrder(set.channelIndices, channelCount: channelCount) != nil
    }

    static func compatibleSets(
        from sets: [ChannelSet],
        channelCount: Int,
        netType: String?
    ) -> [ChannelSet] {
        sets.filter { isCompatible($0, channelCount: channelCount, netType: netType) }
    }

    static func resolvedSet(
        id: ChannelSet.ID?,
        sets: [ChannelSet],
        channelCount: Int,
        netType: String?
    ) -> ChannelSet? {
        guard let id,
              let set = sets.first(where: { $0.id == id }),
              isCompatible(set, channelCount: channelCount, netType: netType) else {
            return nil
        }
        return set
    }

    /// Missing, deleted, or incompatible selections safely fall back to the
    /// recording's complete source order.
    static func indices(
        selectedSetID: ChannelSet.ID?,
        sets: [ChannelSet],
        channelCount: Int,
        netType: String?
    ) -> [Int] {
        guard let set = resolvedSet(
            id: selectedSetID,
            sets: sets,
            channelCount: channelCount,
            netType: netType
        ), let order = normalizedOrder(set.channelIndices, channelCount: channelCount) else {
            return Array(0..<max(channelCount, 0))
        }
        return order
    }
}

struct DisplayChannelsControls {
    var selectedSetID: Binding<ChannelSet.ID?>
    var channelCount: Int
    var netType: String?
}

extension FocusedValues {
    var displayChannelsControls: DisplayChannelsControls? {
        get { self[DisplayChannelsControlsKey.self] }
        set { self[DisplayChannelsControlsKey.self] = newValue }
    }

    private struct DisplayChannelsControlsKey: FocusedValueKey {
        typealias Value = DisplayChannelsControls
    }
}
