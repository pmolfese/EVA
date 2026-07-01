//
//  ChannelSetStore.swift
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
//  Singleton store for built-in and user-defined channel sets.
//  Built-in sets are compiled into the app; user sets are persisted to
//  ~/Library/Application Support/EVA/channelSets.json.
//

import Foundation
import Observation

@Observable
final class ChannelSetStore {
    private(set) var userSets: [ChannelSet] = []

    /// All sets: built-ins first, then user-defined.
    var allSets: [ChannelSet] { Self.builtInSets + userSets }

    /// Updated by WaveformView whenever a recording is loaded. The channel set
    /// editor window reads this so it can show the interactive electrode map.
    var activeSensorLayout: SensorLayout? = nil

    static let shared = ChannelSetStore()

    private init() {
        loadUserSets()
    }

    // MARK: - Built-in sets

    static let builtInSets: [ChannelSet] = [
        ChannelSet(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "BCG Proxy (HydroCel 256)",
            // Bilaterally symmetric cluster with the largest, most consistent
            // pulse-locked BCG deflections in 256-channel HydroCel nets:
            //   Right: E239 E238 E235 E234 E236 E237
            //   Left:  E242 E244 E243 E246 E241
            // (0-based indices below = electrode number − 1.)
            channelIndices: [238, 237, 234, 233, 235, 236,   // right
                             241, 243, 242, 245, 240].sorted(), // left
            netType: "HydroCel GSN 256 1.0"
        )
    ]

    func isBuiltIn(_ set: ChannelSet) -> Bool {
        Self.builtInSets.contains { $0.id == set.id }
    }

    // MARK: - CRUD

    func save(_ set: ChannelSet) {
        if let idx = userSets.firstIndex(where: { $0.id == set.id }) {
            userSets[idx] = set
        } else {
            userSets.append(set)
        }
        persistUserSets()
    }

    func delete(_ set: ChannelSet) {
        guard !isBuiltIn(set) else { return }
        userSets.removeAll { $0.id == set.id }
        persistUserSets()
    }

    // MARK: - Persistence

    private static var storageURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("EVA", isDirectory: true)
            .appendingPathComponent("channelSets.json")
    }

    private func loadUserSets() {
        guard let data = try? Data(contentsOf: Self.storageURL) else { return }
        userSets = (try? JSONDecoder().decode([ChannelSet].self, from: data)) ?? []
    }

    private func persistUserSets() {
        let url = Self.storageURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(userSets) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Import / Export

    func exportData(sets: [ChannelSet]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(ChannelSetExport(sets: sets))
    }

    func importSets(from data: Data) throws {
        let envelope = try JSONDecoder().decode(ChannelSetExport.self, from: data)
        for set in envelope.sets {
            guard !isBuiltIn(set) else { continue }
            if !userSets.contains(where: { $0.id == set.id }) {
                userSets.append(set)
            }
        }
        persistUserSets()
    }
}
