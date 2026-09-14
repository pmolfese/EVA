//
//  MuscleBSSCCAViewModel.swift
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
final class MuscleBSSCCAViewModel {
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    var showsSheet = false
    var configuration = MuscleBSSCCAConfiguration.default
    var selectedChannelIndices: [Int] = []
    var samplingRate = 0.0
    var result: MuscleBSSCCADiagnostics?
    var selectedWindowID: Int?
    var isAnalyzing = false
    var analysisProgress: MuscleBSSCCAProgress?
    var analysisStartedAt: Date?
    var statusMessage: String?
    var definedArtifactID: DefinedArtifact.ID?

    @ObservationIgnored var analysisTask: Task<Void, Never>?

    var detectedEvents: [MFFEvent] {
        guard let result else { return [] }
        return MuscleBSSCCAArtifactMarkerBuilder.events(
            from: result,
            samplingRate: samplingRate
        )
    }

    func resetForClose() {
        analysisTask?.cancel()
        analysisTask = nil
        showsSheet = false
        configuration = .default
        selectedChannelIndices = []
        samplingRate = 0
        result = nil
        selectedWindowID = nil
        isAnalyzing = false
        analysisProgress = nil
        analysisStartedAt = nil
        statusMessage = nil
        definedArtifactID = nil
    }
}
