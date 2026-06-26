//
//  ChannelCluster.swift
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
