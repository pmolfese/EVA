//
//  ChannelHealthViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for the channel-health coordination state, extracted from
//  WaveformView (REFACTOR.md — analysis-domain slice). The health results and
//  scan progress live in `ChannelModel` (shared with the menu commands); this
//  store owns only the view-level coordination: the status message, run
//  signature, in-flight task, and details-sheet toggles.
//

import SwiftUI

@MainActor
@Observable
final class ChannelHealthViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    var statusMessage: String?
    var signature: String?
    @ObservationIgnored var task: Task<Void, Never>?

    var showsDetails = false
    var detailsRequest = 0

    private static let progressSource = "Channel Health"

    /// Forwards into the shared `OperationProgressCenter` so the toolbar
    /// status area shows a per-stage progress row while a scan runs — same
    /// pattern as `FilterViewModel.operationProgress`.
    var operationProgress: OperationProgress? {
        get { store.operationProgress.progress(for: Self.progressSource) }
        set { store.operationProgress.set(newValue, for: Self.progressSource) }
    }

    func resetForClose() {
        task?.cancel()
        task = nil
        statusMessage = nil
        signature = nil
        showsDetails = false
        operationProgress = nil
    }
}
