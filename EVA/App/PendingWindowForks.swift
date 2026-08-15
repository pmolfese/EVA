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

    /// Everything the claiming window needs. `packageURL` is enough to
    /// re-open the file — no security-scoped folder access beyond the
    /// package itself is threaded through, so a fork of a BrainVision
    /// recording (which needs sidecar-folder access `.mff` does not) can
    /// fail to load; it fails the same visible way any other open failure
    /// does rather than silently, but re-granting that access automatically
    /// is not built.
    struct Payload {
        var packageURL: URL
        var historySeed: RecordingHistoryModel.ForkSeed
        var liveSnapshot: PipelineSnapshot
        var channels: ChannelModel
    }

    private var queue: [Payload] = []

    func push(_ payload: Payload) {
        queue.append(payload)
    }

    func claim() -> Payload? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}
