//
//  ChannelHealthViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the channel-health coordination state, extracted from
//  WaveformView (REFACTOR.md — analysis-domain slice). The health results and
//  scan progress live in `ChannelModel` (shared with the menu commands); this
//  store owns only the view-level coordination: the status message, run
//  signature, in-flight task, and details-sheet toggles.
//

import Combine
import SwiftUI

@MainActor
final class ChannelHealthViewModel: ObservableObject {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    @Published var statusMessage: String?
    @Published var signature: String?
    @Published var task: Task<Void, Never>?
    @Published var showsDetails = false
    @Published var detailsRequest = 0

    func resetForClose() {
        task?.cancel()
        task = nil
        statusMessage = nil
        signature = nil
        showsDetails = false
    }
}
