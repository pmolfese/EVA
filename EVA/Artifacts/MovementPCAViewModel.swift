//
//  MovementPCAViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import SwiftUI

@MainActor
@Observable
final class MovementPCAViewModel {
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    var showsSheet = false
    var configuration = MovementPCAConfiguration.default
    var result: MovementPCADiagnostics?
    var isAnalyzing = false
    var analysisProgress: MovementPCAProgress?
    var analysisStartedAt: Date?
    var statusMessage: String?
    var definedArtifactID: DefinedArtifact.ID?

    @ObservationIgnored var analysisTask: Task<Void, Never>?

    func resetForClose() {
        analysisTask?.cancel()
        analysisTask = nil
        showsSheet = false
        result = nil
        isAnalyzing = false
        analysisProgress = nil
        analysisStartedAt = nil
        statusMessage = nil
        definedArtifactID = nil
    }
}
