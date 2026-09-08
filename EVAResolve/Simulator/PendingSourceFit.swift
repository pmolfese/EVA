//
//  PendingSourceFit.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Hands the Source window a dataset to fit when an averaged recording is opened
//  (from EVA's "Fit Source Model", Finder, or File ▸ Open; see `SourceFitImporter`). Same throwaway-channel idea
//  as `PendingWindowOpens`, but the Source window is single-instance and may
//  already be open, so a Notification wakes it whether it is new or existing.
//

import Foundation

extension Notification.Name {
    static let evaPendingSourceFit = Notification.Name("EVAResolve.pendingSourceFit")
}

@MainActor
final class PendingSourceFit {
    static let shared = PendingSourceFit()
    private init() {}

    struct Payload {
        var dataset: SourceSimulatorController.FitDataset
        var selection: ClosedRange<Int>?
    }

    private var pending: Payload?
    /// Last import failure, shown by the Source window; cleared on the next push.
    private(set) var lastError: String?

    /// Stores the dataset for the Source window and posts a notification so an
    /// already-open window claims it too. Caller then opens the source window.
    func push(_ payload: Payload) {
        pending = payload
        lastError = nil
        NotificationCenter.default.post(name: .evaPendingSourceFit, object: nil)
    }

    /// Records an import failure and wakes the window so it can show it.
    func report(_ message: String) {
        lastError = message
        NotificationCenter.default.post(name: .evaPendingSourceFit, object: nil)
    }

    /// Pops the pending dataset, or nil if there is none.
    func claim() -> Payload? {
        defer { pending = nil }
        return pending
    }
}
