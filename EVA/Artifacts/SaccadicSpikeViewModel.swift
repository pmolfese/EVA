//
//  SaccadicSpikeViewModel.swift
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
final class SaccadicSpikeViewModel {
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    var showsSheet = false
    var configuration = SaccadicSpikeConfiguration.default
    var czChannels = ""
    var verticalEOGChannels = ""
    var lowerVerticalEOGChannels = ""
    var horizontalEOGChannels = ""
    var result: SaccadicSpikeDetectionResult?
    var isDetecting = false
    var statusMessage: String?
    var definedArtifactID: DefinedArtifact.ID?

    @ObservationIgnored var detectionTask: Task<Void, Never>?

    func resetForClose() {
        detectionTask?.cancel()
        detectionTask = nil
        showsSheet = false
        result = nil
        isDetecting = false
        statusMessage = nil
        definedArtifactID = nil
    }
}

