//
//  TemporaryFileSweeperTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a
//  federal employee as part of official duties. As such, it is not subject to
//  copyright protection within the United States (17 U.S.C. § 105). International
//  copyrights may apply.
//
//  The sweep deletes files, so what is pinned here is mostly what it must *not*
//  delete: anything recent, anything with a recent file buried inside it, the
//  folders macOS manages, and any package outside EVA's own combined-output
//  folders.
//

import Testing
import Foundation
@testable import EVA

final class TemporaryFileSweeperTests {

    /// Stands in for the container `tmp`; removed after each test.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TemporaryFileSweeperTests-\(UUID().uuidString)", isDirectory: true)
    private let now = Date()
    private let fm = FileManager.default

    init() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates a file at `path` under `root`, dated `ageHours` ago.
    @discardableResult
    private func file(_ path: String, ageHours: Double) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try age(url, hours: ageHours)
        return url
    }

    private func age(_ url: URL, hours: Double) throws {
        try fm.setAttributes(
            [.modificationDate: now.addingTimeInterval(-hours * 3600)],
            ofItemAtPath: url.path
        )
    }

    private func exists(_ path: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    // MARK: - Launch sweep

    @Test("Items older than a day are removed; newer ones are kept")
    func removesOnlyStaleItems() throws {
        try file("old.json", ageHours: 48)
        try file("new.json", ageHours: 2)

        TemporaryFileSweeper.sweep(root, now: now)

        #expect(!exists("old.json"))
        #expect(exists("new.json"))
    }

    @Test("A folder is judged by its newest contents, not its own date")
    func folderWithRecentContentIsKept() throws {
        try file("EVA-Combined-A/combined.mff/signal1.bin", ageHours: 72)
        try file("EVA-Combined-A/combined.mff/info.xml", ageHours: 1)
        try age(root.appendingPathComponent("EVA-Combined-A/combined.mff"), hours: 72)
        try age(root.appendingPathComponent("EVA-Combined-A"), hours: 72)

        try file("EVA-Combined-B/combined.mff/signal1.bin", ageHours: 72)
        try age(root.appendingPathComponent("EVA-Combined-B/combined.mff"), hours: 72)
        try age(root.appendingPathComponent("EVA-Combined-B"), hours: 72)

        TemporaryFileSweeper.sweep(root, now: now)

        #expect(exists("EVA-Combined-A/combined.mff/signal1.bin"), "a package must never be partly deleted")
        #expect(!exists("EVA-Combined-B"))
    }

    @Test("Work-area folders are swept run by run and left in place")
    func workAreaSweptPerRun() throws {
        try file("EVASimulate/old-run/sim.mff", ageHours: 72)
        try age(root.appendingPathComponent("EVASimulate/old-run"), hours: 72)
        try file("EVASimulate/new-run/sim.mff", ageHours: 1)

        TemporaryFileSweeper.sweep(root, now: now)

        #expect(!exists("EVASimulate/old-run"))
        #expect(exists("EVASimulate/new-run/sim.mff"))

        try file("EVAResolveHandoff/only-run/fit.json", ageHours: 72)
        try age(root.appendingPathComponent("EVAResolveHandoff/only-run"), hours: 72)
        TemporaryFileSweeper.sweep(root, now: now)
        #expect(!exists("EVAResolveHandoff/only-run"))
        #expect(exists("EVAResolveHandoff"), "the work-area folder itself is never removed")
    }

    @Test("Folders macOS manages are never touched")
    func systemManagedFoldersKept() throws {
        try file("TemporaryItems/x", ageHours: 500)
        try age(root.appendingPathComponent("TemporaryItems"), hours: 500)
        try file("gov.nih.nimh.cmn.eva.savedState/window_1.data", ageHours: 500)
        try age(root.appendingPathComponent("gov.nih.nimh.cmn.eva.savedState"), hours: 500)

        TemporaryFileSweeper.sweep(root, now: now)

        #expect(exists("TemporaryItems/x"))
        #expect(exists("gov.nih.nimh.cmn.eva.savedState/window_1.data"))
    }

    // MARK: - Removal on close

    @Test("Closing a combined package removes its whole folder")
    func combinedPackageRemovedOnClose() throws {
        try file("EVA-Combined-A/combined.mff/signal1.bin", ageHours: 0)
        let package = root.appendingPathComponent("EVA-Combined-A/combined.mff")

        #expect(TemporaryFileSweeper.isCombinedPackage(package, temporaryDirectory: root))
        #expect(TemporaryFileSweeper.removeCombinedPackage(package, unlessReferencedBy: [], temporaryDirectory: root))
        #expect(!exists("EVA-Combined-A"))
    }

    @Test("A combined package another window (or pending fork) still shows is kept")
    func combinedPackageKeptWhileReferenced() throws {
        try file("EVA-Combined-A/combined.mff/signal1.bin", ageHours: 0)
        let package = root.appendingPathComponent("EVA-Combined-A/combined.mff")

        #expect(!TemporaryFileSweeper.removeCombinedPackage(package, unlessReferencedBy: [package], temporaryDirectory: root))
        #expect(exists("EVA-Combined-A/combined.mff/signal1.bin"))
    }

    @Test("Closing a recording opened from anywhere else never deletes it")
    func nonCombinedPackagesNeverRemoved() throws {
        try file("study/subject01.mff/signal1.bin", ageHours: 0)
        let ordinary = root.appendingPathComponent("study/subject01.mff")
        #expect(!TemporaryFileSweeper.isCombinedPackage(ordinary, temporaryDirectory: root))
        #expect(!TemporaryFileSweeper.removeCombinedPackage(ordinary, unlessReferencedBy: [], temporaryDirectory: root))

        // Right folder name, wrong place: not inside the temporary directory.
        try file("nested/EVA-Combined-X/combined.mff/signal1.bin", ageHours: 0)
        let misplaced = root.appendingPathComponent("nested/EVA-Combined-X/combined.mff")
        #expect(!TemporaryFileSweeper.removeCombinedPackage(misplaced, unlessReferencedBy: [], temporaryDirectory: root))

        #expect(exists("study/subject01.mff/signal1.bin"))
        #expect(exists("nested/EVA-Combined-X/combined.mff/signal1.bin"))
    }
}
