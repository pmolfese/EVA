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
    }

    var artifactHelpText: String {
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

        for artifact in template.definedArtifacts where !artifact.events.isEmpty {
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
            artifactVM.detectionMethod.rawValue,
            "\(artifactVM.detectionRefreshToken)"
        ].joined(separator: "|")
    }

    @MainActor
    func updateArtifactEvents(for signal: MFFSignalData) async {
        if artifactVM.detectionMethod == .template || artifactVM.detectionMethod == .ica {
            artifactVM.isDetecting = false
            return
        }

        guard (detectsEyeBlinkArtifacts || detectsEyeMovementArtifacts || ecg.isEnabled), artifactVM.detectionMethod == .threshold else {
            artifactVM.events = []
            artifactVM.statusMessage = artifactsAreActive ? "Only threshold artifact detection is available." : nil
            artifactVM.isDetecting = false
            return
        }

        let ecgSources = ecg.isEnabled ? ecgDetectionSources(for: signal) : []
        if ecg.isEnabled, ecgSources.isEmpty, !detectsEyeBlinkArtifacts, !detectsEyeMovementArtifacts {
            artifactVM.events = []
            artifactVM.statusMessage = "Choose a PNS channel or EEG proxy channel for ECG detection."
            artifactVM.isDetecting = false
            return
        }

        artifactVM.isDetecting = true
        artifactVM.statusMessage = nil

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
            await withTaskGroup(of: [MFFEvent].self) { group in
            if detectBlinks {
                group.addTask(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [] }
                    return EyeArtifactThresholdDetector.detect(
                        kind: .blink,
                        channels: sourceData,
                        samplingRate: samplingRate,
                        duration: duration,
                        sensorLayoutName: sensorLayoutName,
                        configuration: blinkConfig
                    )
                }
            }
            if detectMovements {
                group.addTask(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [] }
                    return EyeArtifactThresholdDetector.detect(
                        kind: .movement,
                        channels: sourceData,
                        samplingRate: samplingRate,
                        duration: duration,
                        sensorLayoutName: sensorLayoutName,
                        configuration: movementConfig
                    )
                }
            }
            if detectECG, !ecgSources.isEmpty {
                group.addTask(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [] }
                    return RWaveDetector.detect(sources: ecgSources, configuration: ecgConfiguration)
                }
            }
                var events: [MFFEvent] = []
                for await batch in group { events += batch }
                return events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
            }
        }

        switch outcome {
        case .completed(let detectedEvents):
            artifactVM.isDetecting = false
            artifactVM.events = detectedEvents
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
