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
//  Singleton store for built-in and user-defined channel sets.
//  Built-in sets are compiled into the app; user sets are persisted to
//  ~/Library/Application Support/EVA/channelSets.json.
//
//  ## Known net geometries — a separate, smaller catalog alongside sets
//
//  `SensorLayout` (electrode x/y positions) has always come from exactly one
//  place: a loaded recording's own `sensorLayout.xml`. That is fine for
//  *drawing* a set against the file currently open, but it means creating or
//  browsing sets has always secretly required a recording — there was no way
//  to say "this set is for a 64-channel HydroCel net" and have EVA know what
//  that net even looks like without one being open.
//
//  `KnownNetGeometry` (added 2026-08-15) is a small, separately-persisted
//  catalog — `name` + `positions`, `netGeometries.json` next to
//  `channelSets.json` — that exists specifically to break that dependency.
//  Deliberately **not seeded with any bundled geometries at ship time**: real
//  electrode positions feed directly into topomap rendering and spline
//  interpolation weights, and the only full, trustworthy source for them is
//  a real EGI `sensorLayout.xml` from a real recording — the truncated test
//  fixtures in this repo (13 sensors, sometimes 1, for nets that have
//  hundreds) are not that, and fabricating positions to fill the gap was
//  ruled out explicitly. Self-sourcing instead: `ChannelSetEditorView`
//  offers to save the *focused recording's own* geometry under a name the
//  first time it sees a net not already in the catalog — see
//  `unsavedNetPrompt` — so the catalog grows from real files as they are
//  opened, never from a guess.
//
//  ## `activeSensorLayout`/`activeChannelNames`, and how they stay current
//  across more than one recording window
//
//  The Channel Sets editor is a separate, single-instance utility window
//  (Window menu). It has no recording of its own, so it needs to be told
//  which one's electrode map to draw. Before multi-window this was simple:
//  whichever recording loaded most recently was, definitionally, the only
//  one, and `WaveformView.loadRecordingIfNeeded()` /
//  `finishChannelRoleEdit()` wrote here directly.
//
//  With more than one recording window possibly open, "most recently
//  loaded" stops meaning "the one the editor should show." The first fix
//  tried (2026-08-15) was a `@FocusedValue`-based mirror living in
//  `.commands` — removed the same day, see the note near the bottom of this
//  file for why. The actual fix is `WaveformView.publishChannelSetContext()`,
//  called from three places: on load and on a channel-role edit (same as
//  before, for correctness within one window), and now also when a window
//  *becomes main* (`WindowAccessor`'s `onBecomeMain`, wired from
//  `ContentView`) — that third call is what makes the editor follow focus
//  across multiple windows rather than only load order. This store stays the
//  passive, storage-only side of all three.
//

import Foundation
import Observation
import SwiftUI

@Observable
final class ChannelSetStore {
    private(set) var userSets: [ChannelSet] = []

    /// All sets: built-ins first, then user-defined.
    var allSets: [ChannelSet] { Self.builtInSets + userSets }

    /// Written by `WaveformView.publishChannelSetContext()` — see the file
    /// header. The channel set editor window reads this so it can show the
    /// interactive electrode map.
    var activeSensorLayout: SensorLayout? = nil
    /// Channel labels from the focused recording, used only for display in
    /// the channel set editor. Channel sets remain stored by zero-based index.
    var activeChannelNames: [String]? = nil
    /// Whether the focused recording came from an `.mff` package, vs. some
    /// other reader (BrainVision, etc.). Gates `ProcessingDefaults.
    /// autoSaveNewNetGeometriesFromNonMFF` in `ChannelSetEditorView` — a
    /// non-MFF file's geometry is more often reconstructed/approximate than
    /// the vendor's own file, so auto-saving it needs a separate opt-in.
    /// Defaults true so an unset value (nothing loaded yet) doesn't itself
    /// block anything; the gate only has teeth once a real, non-MFF
    /// recording is focused.
    var activeIsMFFSource: Bool = true

    /// User-saved net geometries — see the file header. Sorted by name for
    /// display; storage order doesn't otherwise matter.
    private(set) var knownGeometries: [KnownNetGeometry] = []

    /// Net names worth offering when creating a set or filtering the list,
    /// beyond what's in `knownGeometries`: any `netType` a saved channel set
    /// already carries, even if no geometry was ever saved for it. This is
    /// what lets "+" suggest a net someone already tagged sets with by
    /// typing a name freehand, not only ones with a saved map.
    var knownNetNames: [String] {
        let fromGeometries = knownGeometries.map(\.name)
        let fromSets = allSets.compactMap(\.netType)
        return Array(Set(fromGeometries + fromSets)).sorted()
    }

    /// Where `channelSets.json`/`netGeometries.json` live. Instance-scoped,
    /// not a hardcoded static path, specifically so tests can point a store
    /// at an isolated temp directory instead of silently reading and writing
    /// the real `~/Library/Application Support/EVA/` — a shared singleton
    /// backed by real user data is not something a test suite should be
    /// mutating.
    private let storageDirectory: URL

    static let shared = ChannelSetStore()

    private init() {
        storageDirectory = Self.defaultStorageDirectory
        loadUserSets()
        loadKnownGeometries()
    }

    /// Test-only: an isolated store, so persistence logic (save, rename with
    /// merge, delete) is exercisable without touching `.shared`'s real files.
    init(testStorageDirectory: URL) {
        storageDirectory = testStorageDirectory
        loadUserSets()
        loadKnownGeometries()
    }

    private static var defaultStorageDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("EVA", isDirectory: true)
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

    // MARK: - Known net geometries

    /// Saves `positions` under `name`, or replaces an existing entry of the
    /// same name — the same "save again to update" behavior `save(_:)` gives
    /// channel sets. This is the one and only way the catalog grows: called
    /// from `ChannelSetEditorView`'s "save this net" prompt against a real,
    /// currently-loaded recording's own geometry. See the file header for
    /// why nothing seeds this at ship time.
    func saveGeometry(name: String, positions: [SensorPosition]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let idx = knownGeometries.firstIndex(where: { $0.name == trimmed }) {
            knownGeometries[idx].positions = positions
        } else {
            knownGeometries.append(KnownNetGeometry(name: trimmed, positions: positions))
        }
        persistKnownGeometries()
    }

    func geometry(named name: String) -> KnownNetGeometry? {
        knownGeometries.first { $0.name == name }
    }

    func deleteGeometry(_ geometry: KnownNetGeometry) {
        knownGeometries.removeAll { $0.id == geometry.id }
        persistKnownGeometries()
    }

    /// Renames a saved net geometry, and reassigns every user channel set's
    /// `netType` that pointed at the old name so nothing is left tagged with
    /// a name that no longer exists — the exact "typed '64 channel' two
    /// ways" scenario this was asked for: rename one onto the other's name
    /// and everything reattaches to a single, consolidated entry.
    ///
    /// If a geometry already exists under `newName`, this is treated as an
    /// intentional merge, not a data overwrite: the *existing* entry's saved
    /// positions win and `geometry`'s own are discarded, on the reasoning
    /// that a rename should never silently replace real, already-saved
    /// geometry data with a click that only meant to fix a name. Only the
    /// now-redundant duplicate entry is removed.
    ///
    /// Built-in sets are not touched — `builtInSets` is a compile-time
    /// constant, not something a rename can rewrite. Renaming a geometry
    /// away from the one built-in net name in use ("HydroCel GSN 256 1.0",
    /// the BCG proxy set) would leave that built-in set's `netType` stale.
    /// Narrow enough (one built-in, one specific string) not to be worth
    /// solving here.
    func renameGeometry(_ geometry: KnownNetGeometry, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != geometry.name else { return }

        let oldName = geometry.name
        if knownGeometries.contains(where: { $0.name == trimmed && $0.id != geometry.id }) {
            knownGeometries.removeAll { $0.id == geometry.id }
        } else if let idx = knownGeometries.firstIndex(where: { $0.id == geometry.id }) {
            knownGeometries[idx].name = trimmed
        }

        for i in userSets.indices where userSets[i].netType == oldName {
            userSets[i].netType = trimmed
        }

        persistKnownGeometries()
        persistUserSets()
    }

    // MARK: - Persistence

    private var storageURL: URL {
        storageDirectory.appendingPathComponent("channelSets.json")
    }

    private func loadUserSets() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        userSets = (try? JSONDecoder().decode([ChannelSet].self, from: data)) ?? []
    }

    private func persistUserSets() {
        let url = storageURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(userSets) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private var geometriesStorageURL: URL {
        storageDirectory.appendingPathComponent("netGeometries.json")
    }

    private func loadKnownGeometries() {
        guard let data = try? Data(contentsOf: geometriesStorageURL) else { return }
        knownGeometries = (try? JSONDecoder().decode([KnownNetGeometry].self, from: data)) ?? []
    }

    private func persistKnownGeometries() {
        let url = geometriesStorageURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(knownGeometries) {
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

// `ChannelSetContext`/`ChannelSetFocusMirror` (a `@FocusedValue`-based
// mirror living in `.commands`) were tried here 2026-08-15 and removed the
// same day — manual test found the editor still reporting "no sensor layout
// available" with a recording open, most likely because an invisible,
// zero-size view mounted purely for a `.onChange` side effect does not get
// re-evaluated the way a real, visible command button does. Replaced by
// direct writes from `WaveformView.publishChannelSetContext()`, called on
// load, on a channel-role edit, and — via `WindowAccessor`'s `onBecomeMain`
// — when a recording window becomes main. See that method's doc comment.
