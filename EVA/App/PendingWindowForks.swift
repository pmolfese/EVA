//
//  PendingWindowForks.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Hands a freshly-created "main" window everything it needs to *become* a
//  fork of the window that spawned it — REWIND.md "Forking to a new window".
//
//  Same shape as `PendingWindowOpens` and the same reason for existing (no
//  channel from `openWindow(id:)` back into the window it creates), but a
//  richer payload: not just a file to open, but the source window's whole
//  history tree, its snapshot cache, its live pipeline state, and its channel
//  decisions — everything "memory copy, not reprocessing" requires. See that
//  section for why re-running the pipeline in the new window instead would
//  have been the wrong design.
//

import Foundation

@MainActor
final class PendingWindowForks {
    static let shared = PendingWindowForks()
    private init() {}

    /// Everything the claiming window needs.
    ///
    /// `securityScopedURLs` are carried alongside `packageURL` because the
    /// claiming window re-reads the file itself, and for a format whose data
    /// lives *beside* the header — BrainVision's `.vmrk`/`.eeg`, EDF, Persyst,
    /// BESA — the package URL alone is not enough to read it. Forking one of
    /// those used to produce a window that failed to load, visibly but for no
    /// reason the operator could act on (ROADMAP RW-1 item 12). Scopes are
    /// process-wide and refcounted, so passing the same URLs across is the whole
    /// fix: no bookmarks, and no normalized copy of the recording.
    struct Payload {
        var packageURL: URL
        /// See `MFFRecording.securityScopedURLs`.
        var securityScopedURLs: [URL] = []
        var historySeed: RecordingHistoryModel.ForkSeed
        var liveSnapshot: PipelineSnapshot
        var channels: ChannelModel
        /// The source window's comparison group, so the fork joins the same
        /// experiment rather than looking like an unrelated window that happens
        /// to have the file open (ROADMAP RW-1 item 10).
        var comparisonGroupID: UUID
        /// Short ID of the node the fork was taken at.
        var forkedFromNode: String
    }

    private var queue: [Payload] = []

    func push(_ payload: Payload) {
        queue.append(payload)
    }

    func claim() -> Payload? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}
