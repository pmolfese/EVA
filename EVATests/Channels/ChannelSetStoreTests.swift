//
//  ChannelSetStoreTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The known-net-geometry catalog (2026-08-15): a small, separately-saved
//  library of electrode positions that lets a channel set be created for a
//  net without a matching recording open. Every test here uses
//  `ChannelSetStore(testStorageDirectory:)`, not `.shared` — the singleton
//  reads and writes the real `~/Library/Application Support/EVA/`, and a test
//  suite has no business mutating a person's actual saved channel sets.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct ChannelSetStoreTests {

    private func makeStore() -> ChannelSetStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelSetStoreTests-\(UUID().uuidString)", isDirectory: true)
        return ChannelSetStore(testStorageDirectory: dir)
    }

    private func positions(_ count: Int) -> [SensorPosition] {
        (0..<count).map { SensorPosition(channelIndex: $0, x: Double($0), y: Double($0)) }
    }

    // MARK: - Saving geometries

    @Test("Saving a geometry under a new name adds it; saving again under the same name updates it")
    func saveGeometryInsertsOrUpdates() {
        let store = makeStore()
        store.saveGeometry(name: "64ch", positions: positions(64))
        #expect(store.knownGeometries.count == 1)
        #expect(store.geometry(named: "64ch")?.positions.count == 64)

        store.saveGeometry(name: "64ch", positions: positions(65))
        #expect(store.knownGeometries.count == 1, "same name should update in place, not duplicate")
        #expect(store.geometry(named: "64ch")?.positions.count == 65)
    }

    @Test("Blank or whitespace-only names are rejected")
    func saveGeometryRejectsBlankNames() {
        let store = makeStore()
        store.saveGeometry(name: "   ", positions: positions(4))
        #expect(store.knownGeometries.isEmpty)
    }

    @Test("A saved geometry survives a fresh store pointed at the same directory")
    func geometryPersistsAcrossInstances() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelSetStoreTests-\(UUID().uuidString)", isDirectory: true)
        let first = ChannelSetStore(testStorageDirectory: dir)
        first.saveGeometry(name: "128ch", positions: positions(128))

        let second = ChannelSetStore(testStorageDirectory: dir)
        #expect(second.geometry(named: "128ch")?.positions.count == 128)
    }

    // MARK: - Renaming — the "typed '64 channel' two ways" scenario

    @Test("Renaming a geometry to an unused name just relabels it")
    func renameToUnusedNameRelabels() {
        let store = makeStore()
        store.saveGeometry(name: "64ch", positions: positions(64))
        let geometry = store.geometry(named: "64ch")!

        store.renameGeometry(geometry, to: "HydroCel GSN 64 1.0")

        #expect(store.geometry(named: "64ch") == nil)
        #expect(store.geometry(named: "HydroCel GSN 64 1.0")?.positions.count == 64)
        #expect(store.knownGeometries.count == 1)
    }

    @Test("Renaming onto an existing name merges: the destination's positions win, the duplicate is dropped")
    func renameOntoExistingNameMerges() {
        let store = makeStore()
        store.saveGeometry(name: "64 channel", positions: positions(64))
        store.saveGeometry(name: "HydroCel GSN 64 1.0", positions: positions(65)) // the "real" one
        let duplicate = store.geometry(named: "64 channel")!

        store.renameGeometry(duplicate, to: "HydroCel GSN 64 1.0")

        #expect(store.knownGeometries.count == 1, "the two entries should have consolidated into one")
        #expect(store.geometry(named: "HydroCel GSN 64 1.0")?.positions.count == 65,
                "the destination's own saved positions must win, not be silently overwritten")
        #expect(store.geometry(named: "64 channel") == nil)
    }

    @Test("Renaming reassigns every channel set tagged with the old net name")
    func renameCascadesIntoChannelSets() {
        let store = makeStore()
        store.saveGeometry(name: "64ch", positions: positions(64))
        store.save(ChannelSet(name: "Eyes", channelIndices: [1, 2], netType: "64ch"))
        store.save(ChannelSet(name: "Mastoids", channelIndices: [10, 11], netType: "64ch"))
        store.save(ChannelSet(name: "Unrelated", channelIndices: [3], netType: "128ch"))

        store.renameGeometry(store.geometry(named: "64ch")!, to: "HydroCel GSN 64 1.0")

        let netTypes = Set(store.userSets.map(\.netType))
        #expect(!netTypes.contains("64ch"))
        #expect(store.userSets.filter { $0.name != "Unrelated" }.allSatisfy { $0.netType == "HydroCel GSN 64 1.0" })
        #expect(store.userSets.first { $0.name == "Unrelated" }?.netType == "128ch", "unrelated sets must not be touched")
    }

    @Test("Renaming to the same name, or to blank, is a no-op")
    func renameNoOps() {
        let store = makeStore()
        store.saveGeometry(name: "64ch", positions: positions(64))
        let geometry = store.geometry(named: "64ch")!

        store.renameGeometry(geometry, to: "64ch")
        store.renameGeometry(geometry, to: "   ")

        #expect(store.knownGeometries.count == 1)
        #expect(store.geometry(named: "64ch")?.positions.count == 64)
    }

    // MARK: - Deleting

    @Test("Deleting a geometry removes it but leaves channel sets that referenced its name alone")
    func deleteGeometryLeavesSetsUntouched() {
        let store = makeStore()
        store.saveGeometry(name: "64ch", positions: positions(64))
        store.save(ChannelSet(name: "Eyes", channelIndices: [1], netType: "64ch"))

        store.deleteGeometry(store.geometry(named: "64ch")!)

        #expect(store.knownGeometries.isEmpty)
        // The set still exists, still tagged — just with no geometry to draw
        // from. Deleting a geometry is not the same act as deleting a set.
        #expect(store.userSets.first?.netType == "64ch")
    }

    // MARK: - knownNetNames

    @Test("knownNetNames includes both saved geometries and any net name a set uses, deduplicated")
    func knownNetNamesUnionsGeometriesAndSetTags() {
        let store = makeStore()
        store.saveGeometry(name: "64ch", positions: positions(64))
        store.save(ChannelSet(name: "Custom", channelIndices: [1], netType: "256ch")) // no geometry saved for this one
        store.save(ChannelSet(name: "Another", channelIndices: [2], netType: "64ch")) // overlaps the geometry name

        // `allSets` always includes the one built-in (BCG Proxy), tagged
        // "HydroCel GSN 256 1.0" — knownNetNames reads from allSets, so that
        // name is present in every store, not just this test's own additions.
        #expect(store.knownNetNames == ["256ch", "64ch", "HydroCel GSN 256 1.0"])
    }

    @Test("A set with no netType does not contribute a bogus net name")
    func untaggedSetsDoNotPolluteKnownNetNames() {
        let store = makeStore()
        store.save(ChannelSet(name: "Any Net Set", channelIndices: [1], netType: nil))
        // Only the built-in's own net name should show up — nothing from
        // this test's untagged set.
        #expect(store.knownNetNames == ["HydroCel GSN 256 1.0"])
    }
}
