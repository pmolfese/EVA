//
//  TemporaryFileSweeper.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Clears out what EVA leaves in its sandbox `tmp`.
//
//  macOS does not reliably empty a sandboxed app's container `tmp`: the shared
//  per-user temp directory is swept periodically, the container one is not, and
//  files from months back were found surviving there — including a 1.5 GB
//  combined recording nobody could reach any more. So EVA owns the cleanup, in
//  two places:
//
//  - A combined recording (`RecordingCombiner.writeTempPackage`) exists only in
//    `tmp`, so its folder is removed when the last window showing it closes.
//  - At launch, anything EVA wrote more than a day ago is swept. That catches
//    what the close path never sees — a quit or a crash, which close no window
//    through `closeRecording()` — and simulator output left in `tmp` because
//    the user chose no destination folder.
//
//  Age is the newest modification anywhere inside an item, not the item's own
//  date: a folder's date only moves when a direct child is added or removed, so
//  a package being written into would otherwise look as old as its first file.
//

import Foundation

nonisolated enum TemporaryFileSweeper {
    /// Anything untouched for longer than this is fair game at launch. Long
    /// enough that no recording opened in the previous session can still be in
    /// use — nothing is open yet when the sweep runs, and `ContentView` does not
    /// restore recordings across launches.
    static let maximumAge: TimeInterval = 24 * 60 * 60

    /// Folders that hold one UUID-named run per child (the simulator's and the
    /// Resolve hand-off's work directories). Their own date moves whenever a
    /// run is added, so they are swept child by child rather than as a unit.
    /// The folder itself is left in place even when emptied: removing it could
    /// race a run that is creating its subfolder at that moment.
    static let workAreaNames: Set<String> = ["EVASimulate", "EVAResolveHandoff"]

    /// The folder prefix `RecordingCombiner.writeTempPackage` writes under.
    static let combinedPackagePrefix = "EVA-Combined-"

    /// Removes every item in `directory` whose newest modification is older than
    /// `maximumAge`, and returns what was removed. Items macOS manages itself
    /// (`TemporaryItems`, the `.savedState` window-restoration folder) are
    /// never touched.
    @discardableResult
    static func sweep(
        _ directory: URL = FileManager.default.temporaryDirectory,
        olderThan maximumAge: TimeInterval = maximumAge,
        now: Date = Date()
    ) -> [URL] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        var removed: [URL] = []
        for child in children(of: directory) where !isSystemManaged(child) {
            let candidates = workAreaNames.contains(child.lastPathComponent)
                ? children(of: child)
                : [child]
            for item in candidates where isStale(item, cutoff: cutoff) && remove(item) {
                removed.append(item)
            }
        }
        return removed
    }

    /// Removes the temporary folder holding a combined recording once nothing
    /// open still reads it, and returns whether it did.
    ///
    /// Only a package `RecordingCombiner.writeTempPackage` wrote qualifies — a
    /// direct child of an `EVA-Combined-…` folder directly inside
    /// `temporaryDirectory` — so closing a file the user opened from anywhere
    /// else can never delete it. `openPackageURLs` should list every recording
    /// still open, and every one about to be (a fork not yet claimed by its new
    /// window), since those share the closing window's package.
    @discardableResult
    static func removeCombinedPackage(
        _ packageURL: URL,
        unlessReferencedBy openPackageURLs: [URL],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        guard isCombinedPackage(packageURL, temporaryDirectory: temporaryDirectory) else { return false }
        let folder = packageURL.deletingLastPathComponent()
        let stillOpen = openPackageURLs.contains {
            canonicalPath($0.deletingLastPathComponent()) == canonicalPath(folder)
        }
        return !stillOpen && remove(folder)
    }

    /// Whether `packageURL` is a combined recording living in `tmp` — the case
    /// where closing its window discards the recording itself, not just the
    /// processing done to it.
    static func isCombinedPackage(
        _ packageURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let folder = packageURL.deletingLastPathComponent()
        return folder.lastPathComponent.hasPrefix(combinedPackagePrefix)
            && canonicalPath(folder.deletingLastPathComponent()) == canonicalPath(temporaryDirectory)
    }

    // MARK: - Helpers

    private static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
    }

    private static func isSystemManaged(_ url: URL) -> Bool {
        url.lastPathComponent == "TemporaryItems" || url.pathExtension == "savedState"
    }

    /// An item whose date cannot be read — itself or anything inside it — is
    /// treated as fresh: the sweep only ever errs toward keeping a file.
    private static func isStale(_ url: URL, cutoff: Date) -> Bool {
        guard let newest = newestModification(of: url) else { return false }
        return newest < cutoff
    }

    private static func newestModification(of url: URL) -> Date? {
        guard var newest = modificationDate(of: url) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return newest }
        for case let item as URL in enumerator {
            guard let date = modificationDate(of: item) else { return nil }
            newest = max(newest, date)
        }
        return newest
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func remove(_ url: URL) -> Bool {
        (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// `/var` and `/private/var` name the same folder; compare resolved paths.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
