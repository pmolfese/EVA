//
//  ChannelSet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A named, non-contiguous subset of EEG channels. Used as a reusable
//  group for proxy-channel selection (BCG detection), topography masking,
//  and region-of-interest analysis. Sets are managed by `ChannelSetStore`.
//

import Foundation

struct ChannelSet: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// 0-based channel indices belonging to this set.
    var channelIndices: [Int]
    /// When set, this channel set is only valid for a specific net layout name.
    /// `nil` means the set applies to any net.
    var netType: String?

    init(id: UUID = UUID(), name: String, channelIndices: [Int], netType: String? = nil) {
        self.id = id
        self.name = name
        self.channelIndices = channelIndices
        self.netType = netType
    }
}

/// JSON envelope for import/export of one or more channel sets.
struct ChannelSetExport: Codable {
    var version: Int = 1
    var sets: [ChannelSet]
}
