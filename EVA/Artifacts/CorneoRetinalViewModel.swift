//
//  CorneoRetinalViewModel.swift
//  EVA
//

import SwiftUI

nonisolated struct CorneoRetinalAnalysisProgress: Sendable {
    var fraction: Double
    var stage: String
    var detail: String? = nil
    var blinkCandidateCount: Int? = nil
    var acceptedBlinkCount: Int? = nil
    var blinkSampleCount: Int? = nil
    var usableSampleCount: Int? = nil
    var totalSampleCount: Int? = nil
    var verticalTemplateSampleCount: Int? = nil
    var horizontalRMS: Double? = nil
    var verticalRMS: Double? = nil

    func preservingMetrics(from previous: CorneoRetinalAnalysisProgress?) -> CorneoRetinalAnalysisProgress {
        guard let previous else { return self }
        var merged = self
        merged.blinkCandidateCount = blinkCandidateCount ?? previous.blinkCandidateCount
        merged.acceptedBlinkCount = acceptedBlinkCount ?? previous.acceptedBlinkCount
        merged.blinkSampleCount = blinkSampleCount ?? previous.blinkSampleCount
        merged.usableSampleCount = usableSampleCount ?? previous.usableSampleCount
        merged.totalSampleCount = totalSampleCount ?? previous.totalSampleCount
        merged.verticalTemplateSampleCount = verticalTemplateSampleCount ?? previous.verticalTemplateSampleCount
        merged.horizontalRMS = horizontalRMS ?? previous.horizontalRMS
        merged.verticalRMS = verticalRMS ?? previous.verticalRMS
        return merged
    }
}

nonisolated struct CorneoRetinalAnalysisResult: Sendable {
    var diagnostics: CorneoRetinalDiagnostics
    var blinkEvents: [MFFEvent]
    var blinkDetection: MAACPreliminaryBlinkResult
    var selection: CorneoRetinalChannelSelection
}

nonisolated struct CorneoRetinalBlinkReviewItem: Identifiable, Sendable, Equatable {
    var id: MFFEvent.ID { event.id }
    var event: MFFEvent
    var isIncluded: Bool

    var onsetSeconds: Double { event.onsetTimeSeconds }
    var endSeconds: Double { event.endTimeSeconds }

    mutating func setOnset(
        _ requestedOnset: Double,
        recordingDuration: Double,
        minimumDuration: Double
    ) {
        setSpan(
            onset: requestedOnset,
            end: endSeconds,
            recordingDuration: recordingDuration,
            minimumDuration: minimumDuration
        )
    }

    mutating func setEnd(
        _ requestedEnd: Double,
        recordingDuration: Double,
        minimumDuration: Double
    ) {
        setSpan(
            onset: onsetSeconds,
            end: requestedEnd,
            recordingDuration: recordingDuration,
            minimumDuration: minimumDuration
        )
    }

    private mutating func setSpan(
        onset requestedOnset: Double,
        end requestedEnd: Double,
        recordingDuration: Double,
        minimumDuration: Double
    ) {
        let minimumDuration = max(minimumDuration, 1e-6)
        let recordingDuration = max(recordingDuration, minimumDuration)
        let onset = min(max(requestedOnset, 0), recordingDuration - minimumDuration)
        let end = min(max(requestedEnd, onset + minimumDuration), recordingDuration)
        event = MFFEvent(
            id: event.id,
            code: event.code,
            label: event.label,
            eventDescription: event.eventDescription,
            cell: event.cell,
            beginTimeSeconds: onset,
            rawBeginTime: String(format: "%.6f", onset),
            sourceFile: event.sourceFile,
            durationSeconds: end - onset,
            timeAnchor: .onset
        )
    }
}

@MainActor
@Observable
final class CorneoRetinalViewModel {
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    var showsSheet = false
    var configuration = CorneoRetinalConfiguration.default
    var leftHEOGChannels = ""
    var rightHEOGChannels = ""
    var upperVEOGChannels = ""
    var lowerVEOGChannels = ""
    var result: CorneoRetinalAnalysisResult?
    var blinkReviewItems: [CorneoRetinalBlinkReviewItem] = []
    var selectedBlinkReviewID: MFFEvent.ID?
    var maskEstimateIsStale = false
    var analysisProgress: CorneoRetinalAnalysisProgress?
    var isAnalyzing = false
    var statusMessage: String?
    var definedArtifactID: DefinedArtifact.ID?

    @ObservationIgnored var analysisTask: Task<Void, Never>?

    func resetForClose() {
        analysisTask?.cancel()
        analysisTask = nil
        showsSheet = false
        result = nil
        blinkReviewItems = []
        selectedBlinkReviewID = nil
        maskEstimateIsStale = false
        analysisProgress = nil
        isAnalyzing = false
        statusMessage = nil
        definedArtifactID = nil
    }
}
