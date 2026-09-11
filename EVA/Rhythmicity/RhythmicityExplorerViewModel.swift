//
//  RhythmicityExplorerViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

enum RhythmicityExplorerMode: String, CaseIterable, Identifiable, Sendable {
    case bands = "Bands"
    case eventRelated = "Event-related"
    case bursts = "Bursts"

    var id: String { rawValue }
}

/// Recording-scoped presentation state for the Rhythmicity Explorer.
///
/// Analysis configuration and results will join this model as the numerical
/// milestones in `LAVI.md` land. Keeping the route behind its own model now
/// avoids making the EEG Analysis view model own an unrelated analysis family.
@MainActor
@Observable
final class RhythmicityExplorerViewModel {
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    var showsSheet = false
    var mode = RhythmicityExplorerMode.bands

    func resetForClose() {
        showsSheet = false
        mode = .bands
    }
}
