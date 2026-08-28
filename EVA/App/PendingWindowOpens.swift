//
//  PendingWindowOpens.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Hands a freshly-created "main" window the file it was opened to show.
//
//  `openWindow(id:)` has no way to pass data directly to the window it
//  creates — `WindowGroup`'s typed `for:` variant exists for that, but ties
//  the window's identity to macOS's state-restoration machinery, which would
//  try to relaunch this exact selection (via a possibly-stale
//  security-scoped bookmark) the next time EVA starts. That is a bigger
//  commitment than "open recording always makes a new window" was asking
//  for.
//
//  This is a narrower, throwaway channel instead: push the picked URLs
//  immediately before calling `openWindow(id: "main")`, and the new window's
//  `ContentView` claims (pops) them once, the first time its body appears.
//  FIFO, so opening several files in quick succession — unlikely from one
//  person, but not impossible — hands each new window the right one rather
//  than racing.
//

import Foundation

@MainActor
final class PendingWindowOpens {
    static let shared = PendingWindowOpens()
    private init() {}

    private var queue: [[URL]] = []

    /// Queues `urls` for the next new "main" window to claim, then the caller
    /// should call `openWindow(id: "main")`.
    func push(_ urls: [URL]) {
        queue.append(urls)
    }

    /// Pops the oldest unclaimed entry, or `nil` if this window was not
    /// created to open anything in particular — the ordinary "empty window,
    /// drop a file on it" case.
    func claim() -> [URL]? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}
