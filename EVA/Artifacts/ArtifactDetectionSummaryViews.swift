//
//  ArtifactDetectionSummaryViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  General-purpose artifact-detection helpers (active/help-text state, EEG analysis snapshot, event refresh),
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI

/// Threshold eye/QRS detection owns only its own marker sources. Re-running it
/// replaces those markers while preserving BCG, wavelet, and user-defined
/// artifact events, allowing threshold detection and ICA/template workflows to
/// remain active independently.
nonisolated enum ArtifactDetectorEventMerger {
    static func replacingAutomaticEvents(
        in existing: [MFFEvent],
        with detected: [MFFEvent]
    ) -> [MFFEvent] {
        let retained = existing.filter { !isAutomaticEvent($0) }
        return (retained + detected).sorted { lhs, rhs in
            if lhs.beginTimeSeconds != rhs.beginTimeSeconds {
                return lhs.beginTimeSeconds < rhs.beginTimeSeconds
            }
            return lhs.id < rhs.id
        }
    }

    static func isAutomaticEvent(_ event: MFFEvent) -> Bool {
        event.sourceFile == EyeArtifactThresholdDetector.sourceFile
            || event.sourceFile == RWaveDetector.sourceFile
            || event.sourceFile.hasPrefix("\(RWaveDetector.sourceFile):")
    }
}

/// Converts threshold candidates to ordinary event-windowed cleaning definitions.
/// Updates in place so re-detection preserves treatment choices and replay IDs.
nonisolated enum ThresholdOcularArtifactBridge {
    @discardableResult
    static func synchronize(
        artifacts: inout [DefinedArtifact],
        events: [MFFEvent],
        blinkConfiguration: EyeArtifactThresholdConfiguration,
        movementConfiguration: EyeArtifactThresholdConfiguration,
        candidates detailedCandidates: [ThresholdOcularCandidate]? = nil,
        sourceRevision: UUID? = nil
    ) -> Set<UUID> {
        var changed = Set<UUID>()
        for kind in [EyeArtifactKind.blink, .movement] {
            let candidates = events.filter {
                $0.sourceFile == EyeArtifactThresholdDetector.sourceFile && $0.code == kind.eventCode
            }.sorted {
                $0.beginTimeSeconds == $1.beginTimeSeconds
                    ? $0.id < $1.id : $0.beginTimeSeconds < $1.beginTimeSeconds
            }
            let configuration = kind == .blink ? blinkConfiguration : movementConfiguration
            let details = detailedCandidates?.filter { $0.event.code == kind.eventCode }
                .sorted { $0.event.beginTimeSeconds < $1.event.beginTimeSeconds }
            if let existingIndex = artifacts.firstIndex(where: { $0.thresholdOcularKind == kind }) {
                let previous = artifacts[existingIndex]
                let sameDetection = (previous.thresholdOcularCandidates?.map(\.event) ?? previous.events) == candidates
                    && previous.thresholdOcularConfiguration == configuration
                    && (sourceRevision == nil || previous.thresholdOcularSourceRevision == sourceRevision)
                let excluded = sameDetection ? (previous.thresholdOcularExcludedEventIDs ?? []) : []
                let accepted = sameDetection && previous.reviewState != nil
                    ? previous.reviewState!.candidates.filter {
                        ArtifactReviewEngine.choice(for: $0.id, artifact: previous).decision == .include
                    }
                    : candidates.filter { !excluded.contains($0.id) }
                if !sameDetection {
                    ArtifactReviewEngine.removeSplitClasses(from: &artifacts, sourceID: previous.id)
                }
                guard let index = artifacts.firstIndex(where: { $0.id == previous.id }) else { continue }
                guard previous.events != accepted || !sameDetection
                    || previous.thresholdOcularCandidates != details else { continue }
                artifacts[index].events = accepted
                if !sameDetection { artifacts[index].reviewState = nil }
                artifacts[index].thresholdOcularCandidates = details
                artifacts[index].thresholdOcularExcludedEventIDs = excluded
                artifacts[index].thresholdOcularSourceRevision = sourceRevision
                artifacts[index].thresholdOcularConfiguration = configuration
                artifacts[index].average = nil
                artifacts[index].topography = nil
                changed.insert(artifacts[index].id)
            } else if !candidates.isEmpty {
                let artifact = DefinedArtifact(
                    type: .ocular,
                    name: kind == .blink ? "Eye Blinks" : "Eye Movements",
                    eventCode: kind.eventCode,
                    events: candidates,
                    selectedChannelIndices: [],
                    windowSizeSeconds: 0.50,
                    average: nil,
                    topography: nil,
                    cleaningMethod: .doNothing,
                    thresholdOcularKind: kind,
                    thresholdOcularConfiguration: configuration,
                    thresholdOcularCandidates: details,
                    thresholdOcularExcludedEventIDs: [],
                    thresholdOcularSourceRevision: sourceRevision
                )
                artifacts.append(artifact)
                changed.insert(artifact.id)
            }
        }
        return changed
    }
}

extension WaveformView {
    // MARK: - Artifact detection

    var artifactsAreActive: Bool {
        detectsEyeBlinkArtifacts
            || detectsEyeMovementArtifacts
            || ecg.isEnabled
            || !artifactVM.events.isEmpty
            || !template.definedArtifacts.isEmpty
            || waveletExplorer.isRunning
            || artifactVM.cleanedSignal != nil
            || wica.cleanedSignal != nil
    }

    var artifactHelpText: String {
        if wica.isAnalyzing || wica.isApplying {
            return "W-ICA (experimental)\n\(wica.statusMessage ?? "Processing ICA components…")"
        }

        if wica.cleanedSignal != nil, !wica.isEnabled {
            return "W-ICA (experimental)\nApplied result hidden for comparison."
        }

        if wica.cleanedSignal != nil {
            return "W-ICA (experimental)\n\(wica.statusMessage ?? "Component-space wavelet reduction applied.")"
        }

        if waveletExplorer.isRunning {
            return "Wavelet artifact explorer\n\(waveletExplorer.statusTitle.nilIfEmpty ?? "Scanning wavelet artifact evidence...")"
        }

        if artifactVM.isCleaning {
            return "Artifact cleaning\nCleaning artifacts..."
        }

        if artifactVM.isDetecting {
            return "Artifact detection\nDetecting artifacts..."
        }

        if artifactVM.cleanedSignal != nil, !artifactVM.cleaningIsEnabled {
            return "Artifact cleaning\nApplied correction hidden for comparison."
        }

        if artifactVM.cleanedSignal != nil {
            return "Artifact cleaning\n\(artifactVM.cleaningStatusMessage ?? "Artifact cleanup applied.")"
        }

        if let detectStatus = artifactVM.statusMessage {
            return "Artifact detection\n\(detectStatus)"
        }

        if !template.definedArtifacts.isEmpty {
            return "Artifact detection\n\(template.definedArtifacts.count) artifact definitions"
        }

        return "Artifact detection"
    }

    func eegAnalysisProcessingSnapshot() -> EEGAnalysisProcessingSnapshot {
        var parts = ["original"]
        if gradient.correctedSignal != nil {
            parts.append("MRI-corrected")
        }
        if ica.cleanedSignal != nil {
            parts.append("ICA-cleaned")
        }
        if filter.output != nil {
            parts.append("filtered")
        }
        if artifactVM.cleanedSignal != nil, artifactVM.cleaningIsEnabled {
            parts.append("artifact-cleaned")
        }
        if wavelet.reducedSignal != nil, wavelet.isEnabled {
            parts.append("wavelet-reduced")
        }
        if !channels.interpolated.isEmpty {
            parts.append("interpolated")
        }

        return EEGAnalysisProcessingSnapshot(
            signalDescription: "Current working signal: \(parts.joined(separator: " → "))",
            gradientCorrected: gradient.correctedSignal != nil,
            icaCleaned: ica.cleanedSignal != nil,
            filtered: filter.output != nil,
            filterLowCutoffHz: filter.output == nil ? nil : filter.highPassCutoff,
            filterHighCutoffHz: filter.output == nil ? nil : filter.lowPassCutoff,
            notch60HzEnabled: filter.output == nil ? nil : filter.notch60HzEnabled,
            averageReferenced: filter.output == nil ? nil : filter.averageReference,
            artifactCleaned: artifactVM.cleanedSignal != nil,
            artifactCleaningVisible: artifactVM.cleanedSignal != nil && artifactVM.cleaningIsEnabled,
            waveletReduced: wavelet.reducedSignal != nil,
            waveletReductionVisible: wavelet.reducedSignal != nil && wavelet.isEnabled,
            interpolatedChannelIndices: channels.interpolated.keys.sorted(),
            markedBadChannelIndices: channels.bad.sorted()
        )
    }

    func eegArtifactRejectionSources() -> [EEGArtifactRejectionSource] {
        var sources: [EEGArtifactRejectionSource] = []
        var definedEvents = Set<MFFEvent>()

        for artifact in template.definedArtifacts where !artifact.events.isEmpty && !ArtifactReviewEngine.isThresholdFamily(artifact) {
            for event in artifact.events {
                definedEvents.insert(event)
            }
            sources.append(
                EEGArtifactRejectionSource(
                    id: artifact.id.uuidString,
                    name: artifact.name,
                    eventCode: artifact.eventCode,
                    windowSizeSeconds: artifact.windowSizeSeconds,
                    events: artifact.events
                )
            )
        }

        let detectorEvents = artifactVM.events.filter { !definedEvents.contains($0) }
        if !detectorEvents.isEmpty {
            let codes = Array(Set(detectorEvents.map(\.code))).sorted().joined(separator: ", ")
            sources.append(
                EEGArtifactRejectionSource(
                    id: "current-detector-events",
                    name: "Current Detector Events",
                    eventCode: codes.isEmpty ? "Detected" : codes,
                    windowSizeSeconds: 0.25,
                    events: detectorEvents
                )
            )
        }

        return sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func artifactDetectionRequestID(for signal: MFFSignalData) -> String {
        return [
            signal.signalURL.path,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            "\(detectsEyeBlinkArtifacts)",
            "\(detectsEyeMovementArtifacts)",
            "\(artifactVM.blinkThresholdConfig.hashValue)",
            "\(artifactVM.movementThresholdConfig.hashValue)",
            "\(ecg.isEnabled)",
            ecg.selectedPNSChannels.sorted().map(String.init).joined(separator: ","),
            ecg.proxyChannels,
            ecg.algorithm.rawValue,
            ecg.polarity.rawValue,
            "\(ecg.thresholdSD)",
            "\(ecg.minimumRRSeconds)",
            displayedPhysioSignal().map { physioRangeTaskID(for: $0) } ?? "noPNS",
            "\(artifactVM.detectionRefreshToken)"
        ].joined(separator: "|")
    }

    @MainActor
    func updateArtifactEvents(for signal: MFFSignalData, cleaningSignal: MFFSignalData) async {
        guard detectsEyeBlinkArtifacts || detectsEyeMovementArtifacts || ecg.isEnabled else {
            artifactVM.events = ArtifactDetectorEventMerger.replacingAutomaticEvents(
                in: artifactVM.events,
                with: []
            )
            synchronizeThresholdOcularArtifacts(candidates: [], sourceRevision: cleaningSignal.dataRevision)
            artifactVM.statusMessage = nil
            artifactVM.isDetecting = false
            return
        }

        let ecgSources = ecg.isEnabled ? ecgDetectionSources(for: signal) : []
        if ecg.isEnabled, ecgSources.isEmpty, !detectsEyeBlinkArtifacts, !detectsEyeMovementArtifacts {
            artifactVM.events = ArtifactDetectorEventMerger.replacingAutomaticEvents(
                in: artifactVM.events,
                with: []
            )
            synchronizeThresholdOcularArtifacts(candidates: [], sourceRevision: cleaningSignal.dataRevision)
            artifactVM.statusMessage = "Choose a PNS channel or EEG proxy channel for ECG detection."
            artifactVM.isDetecting = false
            return
        }

        artifactVM.isDetecting = true
        artifactVM.statusMessage = nil

        let cleaningRevision = cleaningSignal.dataRevision
        let cleaningData = cleaningSignal.data
        let cleaningRate = cleaningSignal.samplingRate
        let cleaningDuration = cleaningSignal.duration
        let sourceData = signal.data
        let samplingRate = signal.samplingRate
        let duration = signal.duration
        let detectBlinks = detectsEyeBlinkArtifacts
        let detectMovements = detectsEyeMovementArtifacts
        let detectECG = ecg.isEnabled
        let blinkConfig = artifactVM.blinkThresholdConfig
        let movementConfig = artifactVM.movementThresholdConfig
        let sensorLayoutName = recording.sensorLayout?.name
        let ecgConfiguration = ECGDetectionConfiguration(
            algorithm: ecg.algorithm,
            thresholdSD: ecg.thresholdSD,
            minimumRRSeconds: ecg.minimumRRSeconds,
            polarity: ecg.polarity
        )

        // Ownership of `events` / `isDetecting` runs through `LatestOnlyRunner`,
        // so a superseded run cannot publish stale results and the cancellation
        // path cannot silently skip clearing the spinner. See that type for the
        // bug this replaced.
        let outcome = await artifactVM.detectionRunner.run("artifactDetection") {
            await withTaskGroup(of: ([MFFEvent], [ThresholdOcularCandidate]).self) { group in
                // Display markers describe the current signal. Cleaning anchors
                // describe the pre-cleaning input so Apply cannot erase its own events.
                for kind in [EyeArtifactKind.blink, .movement] {
                    guard kind == .blink ? detectBlinks : detectMovements else { continue }
                    let config = kind == .blink ? blinkConfig : movementConfig
                    group.addTask(priority: .userInitiated) {
                        guard !Task.isCancelled else { return ([], []) }
                        return (EyeArtifactThresholdDetector.detect(
                            kind: kind, channels: sourceData, samplingRate: samplingRate,
                            duration: duration, sensorLayoutName: sensorLayoutName,
                            configuration: config), [])
                    }
                    group.addTask(priority: .userInitiated) {
                        guard !Task.isCancelled else { return ([], []) }
                        return ([], EyeArtifactThresholdDetector.detectCandidates(
                            kind: kind, channels: cleaningData, samplingRate: cleaningRate,
                            duration: cleaningDuration, sensorLayoutName: sensorLayoutName,
                            configuration: config))
                    }
                }
                if detectECG, !ecgSources.isEmpty {
                    group.addTask(priority: .userInitiated) {
                        guard !Task.isCancelled else { return ([], []) }
                        return (RWaveDetector.detect(sources: ecgSources, configuration: ecgConfiguration), [])
                    }
                }
                var events: [MFFEvent] = []
                var cleaningCandidates: [ThresholdOcularCandidate] = []
                for await (markers, candidates) in group {
                    events += markers
                    cleaningCandidates += candidates
                }
                return (events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }, cleaningCandidates)
            }
        }

        switch outcome {
        case .completed(let (detectedEvents, cleaningCandidates)):
            artifactVM.isDetecting = false
            synchronizeThresholdOcularArtifacts(candidates: cleaningCandidates, sourceRevision: cleaningRevision)
            artifactVM.events = ArtifactDetectorEventMerger.replacingAutomaticEvents(
                in: artifactVM.events,
                with: detectedEvents
            )
            // A finished run is a verdict even when it found nothing — the
            // distinction Segment Health needs. Only the publishing path records
            // it: a cancelled or superseded run describes inputs that may
            // already be stale.
            artifactVM.recordCompletedDetection()
            artifactVM.statusMessage = artifactDetectionSummary(for: detectedEvents)

        case .cancelled:
            // No successor is coming, so release the spinner. Results are not
            // published: the inputs may already be stale.
            artifactVM.isDetecting = false

        case .superseded:
            // A newer run owns `events` and `isDetecting` now. Touching either
            // here is what the original bug did.
            break
        }
    }

    func synchronizeThresholdOcularArtifacts(candidates: [ThresholdOcularCandidate], sourceRevision: UUID) {
        let previousIDs = Set(template.definedArtifacts.map(\.id))
        let changed = ThresholdOcularArtifactBridge.synchronize(
            artifacts: &template.definedArtifacts,
            events: candidates.map(\.event),
            blinkConfiguration: artifactVM.blinkThresholdConfig,
            movementConfiguration: artifactVM.movementThresholdConfig,
            candidates: candidates,
            sourceRevision: sourceRevision
        )
        guard !changed.isEmpty else { return }
        for id in changed { invalidateOBSVarianceCache(for: id) }
        template.cleaningPreviewCache.removeAll()
        // Merely discovering a mark-only artifact does not invalidate another
        // cleaner. Changing a definition that participated in correction does.
        let removedClasses = previousIDs.subtracting(template.definedArtifacts.map(\.id))
        if !removedClasses.isEmpty || template.definedArtifacts.contains(where: {
            changed.contains($0.id) && ($0.cleaningMethod.removesArtifact || $0.appliedMethod != nil)
        }) {
            artifactCleaningTask?.cancel()
            clearAppliedArtifactCleaning()
        }
    }

    func artifactDetectionSummary(for events: [MFFEvent]) -> String {
        guard !events.isEmpty else { return "No artifacts detected." }
        let blinkCount = events.filter { $0.code == EyeArtifactKind.blink.eventCode }.count
        let movementCount = events.filter { $0.code == EyeArtifactKind.movement.eventCode }.count
        let rWaveCount = events.filter { $0.code == RWaveDetector.eventCode }.count
        var parts: [String] = []
        if blinkCount > 0 {
            parts.append("\(blinkCount) blinks")
        }
        if movementCount > 0 {
            parts.append("\(movementCount) eye movements")
        }
        if rWaveCount > 0 {
            parts.append("\(rWaveCount) QRS")
        }
        if parts.isEmpty {
            parts.append("\(events.count) artifact event\(events.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

}
