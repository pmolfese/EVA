//
//  ChannelCluster.swift
//  EVA
//
//  Copyright (C) 2026 Peter Molfese
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A named subset of channels for region-restricted analysis (e.g. limiting
//  scalp-topography matching to a region of interest).
//
//  STUB: the data model and store exist so UI controls can be wired up now, but
//  creating/editing clusters is not implemented yet. The controls that depend on
//  this are intentionally disabled until the editor lands.
//

import Foundation

struct ChannelCluster: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// 0-based channel indices belonging to the cluster.
    var channelIndices: [Int]
}

/// Placeholder store for user-defined channel clusters. Currently always empty.
///
/// TODO: persist clusters (SwiftData / JSON), provide a create/edit sheet, and
/// then enable the cluster option in the artifact topography controls so the
/// spatial correlation can be restricted to a region of interest.
enum ChannelClusterStore {
    static let clusters: [ChannelCluster] = []
}
