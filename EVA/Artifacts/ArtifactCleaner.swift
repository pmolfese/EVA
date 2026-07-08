//
//  ArtifactCleaner.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Reversible artifact-cleaning methods built from user-defined artifact
//  templates and their detected event windows.
//
//  MAS/MAR/wAAS/wAAR build a *local* template per event from a moving window
//  of neighboring events (median, or Goldman-2000 exponentially-weighted mean),
//  rather than one fixed template for the whole recording — better suited to
//  quasi-periodic artifacts like BCG whose morphology/amplitude drifts over
//  the recording. Inspired by the same-named methods in `amri_eeg_cbc.m` from
//  the Advanced MRI (AMRI) section, NINDS, NIH MATLAB toolbox
//  (https://amri.ninds.nih.gov/software.html; GPL-3.0), itself implementing:
//  Liu Z, de Zwart JA, van Gelderen P, Kuo L-W, Duyn JH. Statistical feature
//  extraction for artifact removal from concurrent fMRI-EEG recordings.
//  NeuroImage (2012), 59(3): 2073-2087. See THIRD_PARTY_NOTICES.md.
//

import Foundation

extension MFFEvent {
    /// This event's true center in time, correcting for the two conventions
    /// EVA's detectors use for `beginTimeSeconds`: waveform-template matching
    /// and Trajectory (map-sequence) scanning stamp the *center* sample
    /// directly; single-map Topography and Continuous-scan topography stamp
    /// the true *onset* (matching the general Onset+Duration convention used
    /// everywhere else — see the event detail popover), so their center is
    /// onset + half their own measured duration, not `beginTimeSeconds` as-is.
    /// Every place that needs "the middle of this event" (cleaning windows,
    /// OBS alignment search, averaged-template previews) should read this
    /// instead of `beginTimeSeconds` directly, or it'll center on the wrong
    /// sample for onset-tagged events — most visibly wrong for Continuous
    /// events, whose duration varies per event rather than matching a fixed
    /// nominal window.
    var centerTimeSeconds: Double {
        if sourceFile.hasPrefix("Topography") || sourceFile.hasPrefix("Continuous") {
            return beginTimeSeconds + (durationSeconds ?? 0) / 2
        }
        return beginTimeSeconds
    }
}

enum DefinedArtifactType: String, CaseIterable, Identifiable, Codable, Sendable {
    case ocular = "Ocular Artifact"
    case ecg = "ECG Artifact"
    case bcg = "BCG Artifact"
    case other = "Other"

    var id: String { rawValue }

    /// Suggested minimum spacing between detected events of this type, used
    /// to pre-fill "Define Artifact"'s merge window (`ArtifactTemplateViewModel
    /// .mergeWindowSeconds`) when the artifact type is chosen or changed.
    /// BCG/ECG are quasi-periodic biological signals with a hard physiological
    /// ceiling on repetition rate (no adult heartbeat exceeds ~240 BPM), so two
    /// hits closer than that are almost certainly the same beat detected
    /// twice. This errs on the generous side (240 BPM) instead of a typical
    /// resting rate, to avoid ever swallowing a genuine second beat during
    /// tachycardia. Ocular/Other have no such floor, so they keep a
    /// conservative generic default.
    var defaultMergeWindowSeconds: Double {
        switch self {
        case .bcg, .ecg: return 0.25
        case .ocular: return 0.20
        case .other: return 0.25
        }
    }

    /// Suggested merge behavior for this type, used to pre-fill "Define
    /// Artifact"'s merge-behavior control alongside `defaultMergeWindowSeconds`.
    /// Discard (keep only the best-scoring hit) is the safe default for every
    /// type — a well-chosen exemplar and threshold shouldn't normally produce
    /// many overlapping hits. Ocular's long/variable-duration case (one long
    /// eye movement scoring at several overlapping offsets) is better solved
    /// by the topography panel's Continuous scan style, which measures a
    /// genuine variable-length span directly instead of stitching together
    /// several fixed-width waveform hits — so Extend is available as a manual
    /// override, but no longer the default for any type.
    var defaultMergeBehavior: ArtifactTemplateMergeBehavior {
        .discard
    }
}

enum ArtifactCleaningMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case doNothing = "Do Nothing"
    case regression = "Regress"
    case obs = "OBS"
    case sspPCA = "SSP/PCA"
    /// Median Artifact Subtraction — local (moving-window) median template.
    case mas = "MAS"
    /// Median Artifact Regression — MAS template, least-squares scaled before subtracting.
    case mar = "MAR"
    /// Weighted Average Artifact Subtraction (Goldman 2000) — local template
    /// exponentially weighted by distance from the current event.
    case waas = "wAAS"
    /// Weighted Average Artifact Regression — wAAS template, least-squares scaled before subtracting.
    case waar = "wAAR"

    var id: String { rawValue }

    nonisolated var removesArtifact: Bool {
        self != .doNothing
    }

    /// Whether this method builds a per-event *local* template from a moving
    /// window of neighboring events, as opposed to one fixed global template
    /// (`.regression`) or a spatial/PCA-based method (`.obs`, `.sspPCA`).
    nonisolated var isLocalTemplateMethod: Bool {
        self == .mas || self == .mar || self == .waas || self == .waar
    }

    /// Whether this method can size each event's correction window from that
    /// event's own measured duration (`DefinedArtifact.usesVariableEventDuration`)
    /// instead of one shared window for the whole artifact. `.regression` and
    /// the local-template methods correct one event at a time, so nothing
    /// stops them from using a per-event length. OBS and SSP/PCA pool every
    /// event into one shared spatial/temporal basis, which requires
    /// uniform-length epochs by construction — they can't support this.
    nonisolated var supportsVariableEventDuration: Bool {
        self == .regression || isLocalTemplateMethod
    }
}

enum ArtifactOBSStrategy: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard = "Standard OBS"
    case topographyGated = "Topography-gated OBS"
    case topographyAligned = "Topography-aligned OBS"
    case topographyWeighted = "Topography-weighted OBS"
    case virtualChannel = "Virtual-channel OBS"
    case clustered = "Clustered OBS"
    case spatiotemporal = "Spatiotemporal OBS"

    var id: String { rawValue }

    nonisolated var requiresTopography: Bool {
        switch self {
        case .topographyGated, .topographyAligned, .topographyWeighted, .virtualChannel:
            return true
        case .standard, .clustered, .spatiotemporal:
            return false
        }
    }

    nonisolated var isExperimental: Bool {
        switch self {
        case .virtualChannel, .clustered, .spatiotemporal:
            return true
        case .standard, .topographyGated, .topographyAligned, .topographyWeighted:
            return false
        }
    }

    nonisolated var helpText: String {
        switch self {
        case .standard:
            return "Fits channel-wise OBS bases from the detected event windows."
        case .topographyGated:
            return "Uses topography-defined event windows, then fits standard channel-wise OBS from those windows."
        case .topographyAligned:
            return "Recenters each event around the strongest nearby match to the saved scalp map before fitting OBS."
        case .topographyWeighted:
            return "Fits channel-wise OBS, then scales correction strength by the saved topography map."
        case .virtualChannel:
            return "Projects the recording onto the saved topography, fits one temporal OBS basis, then projects the correction back to channels."
        case .clustered:
            return "Splits events into amplitude clusters and fits a separate OBS basis for each cluster."
        case .spatiotemporal:
            return "Fits a PCA basis over channel-by-time event windows instead of one independent basis per channel."
        }
    }
}

struct DefinedArtifact: Identifiable, Sendable {
    nonisolated static let defaultOBSComponentCount = 2
    nonisolated static let maximumOBSComponentCount = 8
    nonisolated static let defaultOBSEdgeTaperSeconds = 0.10
    nonisolated static let maximumOBSEdgeTaperSeconds = 0.50
    nonisolated static let defaultOBSAlignmentSearchSeconds = 0.05
    nonisolated static let maximumOBSAlignmentSearchSeconds = 0.20
    nonisolated static let defaultOBSTopographyWeightStrength = 0.75
    nonisolated static let defaultOBSClusterCount = 2
    nonisolated static let maximumOBSClusterCount = 6
    /// Moving-window size (in events) for MAS/MAR/wAAS/wAAR local templates.
    /// Matches `amri_eeg_cbc.m`'s default (`moving_window.size = 21`).
    nonisolated static let defaultLocalTemplateWindowSize = 21
    nonisolated static let minimumLocalTemplateWindowSize = 5
    nonisolated static let maximumLocalTemplateWindowSize = 101
    /// wAAS/wAAR exponential decay factor. Matches `amri_eeg_cbc.m`'s default
    /// (`wfactor = 0.9` [Goldman 2000]).
    nonisolated static let defaultWAASDecayFactor = 0.9
    /// MAS/MAR/wAAS/wAAR edge taper — same mechanism as OBS's, smaller default
    /// since local-template windows are typically much shorter than OBS ones.
    nonisolated static let defaultLocalTemplateEdgeTaperSeconds = 0.05
    nonisolated static let maximumLocalTemplateEdgeTaperSeconds = 0.25

    var id = UUID()
    var type: DefinedArtifactType
    var name: String
    var eventCode: String
    var events: [MFFEvent]
    var selectedChannelIndices: [Int]
    var windowSizeSeconds: Double
    var average: ArtifactTemplateAverage?
    var topography: ArtifactTemplateTopography?
    var cleaningMethod: ArtifactCleaningMethod
    var obsStrategy = ArtifactOBSStrategy.standard
    var obsPCAComponentCount = Self.defaultOBSComponentCount
    var obsEdgeTaperSeconds = Self.defaultOBSEdgeTaperSeconds
    var obsPreservesLocalBaseline = true
    var obsUsesOverlapAdd = true
    var obsAlignmentSearchSeconds = Self.defaultOBSAlignmentSearchSeconds
    var obsTopographyWeightStrength = Self.defaultOBSTopographyWeightStrength
    var obsClusterCount = Self.defaultOBSClusterCount
    var localTemplateWindowSize = Self.defaultLocalTemplateWindowSize
    var waasDecayFactor = Self.defaultWAASDecayFactor
    /// wAAS/wAAR: match AMRI's weighted template donor pool by weighting all
    /// valid epochs, including the current event. When off, EVA uses the
    /// centered local window also used by MAS/MAR.
    var waasUsesAMRIGlobalWeights = true
    /// BCG MAS/MAR/wAAS/wAAR: optional AMRI-style epoch preprocessing. EVA's
    /// default assumes events are already centered; when enabled for BCG
    /// artifacts, each channel estimates a median-power offset, shifts windows
    /// by that offset, and mean-centers epochs before template construction.
    var localTemplateUsesAMRIPreprocessing = false
    /// MAS/MAR/wAAS/wAAR: when true, the correction is de-trended so it
    /// matches the local signal's baseline at both edges of the window
    /// instead of potentially introducing a DC/linear-drift step — same
    /// mechanism as `obsPreservesLocalBaseline`.
    var localTemplatePreservesLocalBaseline = true
    /// MAS/MAR/wAAS/wAAR: seconds of raised-cosine taper at each edge of the
    /// correction window, so the subtraction fades in/out smoothly rather
    /// than cutting off sharply at the window boundary — same mechanism as
    /// `obsEdgeTaperSeconds`.
    var localTemplateEdgeTaperSeconds = Self.defaultLocalTemplateEdgeTaperSeconds
    /// When true (and `cleaningMethod.supportsVariableEventDuration`), each
    /// event's correction window is sized from that event's own measured
    /// `durationSeconds` instead of one fixed window shared by every event.
    /// Off by default — a shared fixed window remains correct and simpler for
    /// artifacts whose events cluster around one duration (the common case);
    /// this exists for artifacts (typically Continuous topography scanning)
    /// whose events genuinely vary in length.
    var usesVariableEventDuration = false
    var appliedMethod: ArtifactCleaningMethod?
    var cleanedAt: Date?

    var eventCount: Int {
        events.count
    }

    mutating func preserveCleaningSettings(from previous: DefinedArtifact) {
        cleaningMethod = previous.cleaningMethod
        obsStrategy = previous.obsStrategy
        obsPCAComponentCount = previous.obsPCAComponentCount
        obsEdgeTaperSeconds = previous.obsEdgeTaperSeconds
        obsPreservesLocalBaseline = previous.obsPreservesLocalBaseline
        obsUsesOverlapAdd = previous.obsUsesOverlapAdd
        obsAlignmentSearchSeconds = previous.obsAlignmentSearchSeconds
        obsTopographyWeightStrength = previous.obsTopographyWeightStrength
        obsClusterCount = previous.obsClusterCount
        localTemplateWindowSize = previous.localTemplateWindowSize
        waasDecayFactor = previous.waasDecayFactor
        waasUsesAMRIGlobalWeights = previous.waasUsesAMRIGlobalWeights
        localTemplateUsesAMRIPreprocessing = previous.localTemplateUsesAMRIPreprocessing
        localTemplatePreservesLocalBaseline = previous.localTemplatePreservesLocalBaseline
        localTemplateEdgeTaperSeconds = previous.localTemplateEdgeTaperSeconds
        usesVariableEventDuration = previous.usesVariableEventDuration
    }
}

extension DefinedArtifact {
    /// Flat, stable provenance fields for `eva.xml` / `log_eva`.
    ///
    /// Artifact-template cleaning remains a subject-specific decision step
    /// because replay needs the drawn template/event context, but these fields
    /// make exported files auditable and manually reproducible from the source
    /// recording.
    nonisolated func processingParameters(prefix: String) -> [String: String] {
        func key(_ suffix: String) -> String {
            prefix.isEmpty ? suffix : "\(prefix).\(suffix)"
        }
        func integerList(_ values: [Int], oneBased: Bool = false) -> String {
            values.map { String(oneBased ? $0 + 1 : $0) }.joined(separator: ",")
        }
        func fixed(_ value: Double) -> String {
            String(format: "%.6f", value)
        }

        let sortedEvents = events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        var params: [String: String] = [
            key("id"): id.uuidString,
            key("type"): type.rawValue,
            key("name"): name,
            key("eventCode"): eventCode,
            key("eventCount"): "\(events.count)",
            key("eventOnsetsSeconds"): sortedEvents.map { fixed($0.beginTimeSeconds) }.joined(separator: ","),
            key("selectedChannels"): integerList(selectedChannelIndices.sorted(), oneBased: true),
            key("windowSizeSeconds"): fixed(windowSizeSeconds),
            key("cleaningMethod"): cleaningMethod.rawValue,
            key("appliedMethod"): appliedMethod?.rawValue ?? "",
            key("obsStrategy"): obsStrategy.rawValue,
            key("obsPCAComponentCount"): "\(obsPCAComponentCount)",
            key("obsEdgeTaperSeconds"): fixed(obsEdgeTaperSeconds),
            key("obsPreservesLocalBaseline"): "\(obsPreservesLocalBaseline)",
            key("obsUsesOverlapAdd"): "\(obsUsesOverlapAdd)",
            key("obsAlignmentSearchSeconds"): fixed(obsAlignmentSearchSeconds),
            key("obsTopographyWeightStrength"): fixed(obsTopographyWeightStrength),
            key("obsClusterCount"): "\(obsClusterCount)",
            key("localTemplateWindowSize"): "\(localTemplateWindowSize)",
            key("waasDecayFactor"): fixed(waasDecayFactor),
            key("waasUsesAMRIGlobalWeights"): "\(waasUsesAMRIGlobalWeights)",
            key("localTemplateUsesAMRIPreprocessing"): "\(localTemplateUsesAMRIPreprocessing)",
            key("localTemplateAMRIPreprocessingEffective"): "\(type == .bcg && localTemplateUsesAMRIPreprocessing)",
            key("localTemplatePreservesLocalBaseline"): "\(localTemplatePreservesLocalBaseline)",
            key("localTemplateEdgeTaperSeconds"): fixed(localTemplateEdgeTaperSeconds),
            key("usesVariableEventDuration"): "\(usesVariableEventDuration)"
        ]

        let eventDurations = sortedEvents.map { event in
            event.durationSeconds.map(fixed) ?? ""
        }
        if eventDurations.contains(where: { !$0.isEmpty }) {
            params[key("eventDurationsSeconds")] = eventDurations.joined(separator: ",")
        }
        if let cleanedAt {
            params[key("cleanedAt")] = ISO8601DateFormatter().string(from: cleanedAt)
        }

        if let average {
            params[key("averagePresent")] = "true"
            params[key("averageSamplingRate")] = fixed(average.samplingRate)
            params[key("averageWindowSizeSeconds")] = fixed(average.windowSizeSeconds)
            params[key("averageEventCount")] = "\(average.eventCount)"
            params[key("averageSelectedChannels")] = integerList(average.selectedChannelIndices.sorted(), oneBased: true)
            params[key("averageChannelCount")] = "\(average.allChannelSamples.count)"
            params[key("averageSampleCount")] = "\(average.allChannelSamples.first?.count ?? 0)"
        } else {
            params[key("averagePresent")] = "false"
        }

        if let topography {
            params[key("topographyPresent")] = "true"
            params[key("topographyMode")] = topography.mode.rawValue
            params[key("topographyReferenceSample")] = "\(topography.referenceSample)"
            params[key("topographyReferenceTimeSeconds")] = fixed(topography.referenceTimeSeconds)
            params[key("topographyChannelCount")] = "\(topography.channelValues.count)"
            params[key("topographyChannels")] = integerList(topography.channelIndices.sorted(), oneBased: true)
            params[key("topographyMatchThreshold")] = fixed(topography.matchThreshold)
            params[key("topographyMatchCount")] = "\(topography.matchCount)"
            params[key("topographyTrajectoryFrameCount")] = "\(topography.trajectoryFrameCount ?? 0)"
        } else {
            params[key("topographyPresent")] = "false"
        }

        return params
    }
}

struct ArtifactCleaningSummary: Identifiable, Sendable {
    var artifactID: UUID
    var name: String
    var method: ArtifactCleaningMethod
    var eventCount: Int
    var channelCount: Int

    var id: UUID { artifactID }
}

struct OBSPCAComponentVariance: Identifiable, Sendable {
    var componentIndex: Int
    var explainedVariance: Double
    var cumulativeVariance: Double
    var remainingVariance: Double

    var id: Int { componentIndex }
}

struct OBSPCAVarianceReport: Sendable {
    var artifactID: UUID
    var eventCount: Int
    var validEventCount: Int
    var sampledEventCount: Int
    var channelCount: Int
    var windowSampleCount: Int
    var totalResidualVariance: Double
    var components: [OBSPCAComponentVariance]

    func cumulativeVariance(for componentCount: Int) -> Double {
        guard componentCount > 0 else { return 0 }
        let index = min(componentCount, components.count) - 1
        guard components.indices.contains(index) else { return 0 }
        return components[index].cumulativeVariance
    }
}

enum ArtifactCleaningProgressPhase: String, Sendable {
    case preparing = "Preparing"
    case cleaning = "Cleaning"
    case finalizing = "Finalizing"
}

struct ArtifactCleaningProgress: Sendable {
    var completed: Int
    var total: Int
    var artifactCompleted: Int
    var artifactTotal: Int
    var artifactIndex: Int
    var artifactCount: Int
    var artifactName: String
    var method: ArtifactCleaningMethod
    var phase: ArtifactCleaningProgressPhase
    var detail: String?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

nonisolated enum ArtifactCleaner {
    static func obsVarianceReport(
        for artifact: DefinedArtifact,
        in signal: MFFSignalData,
        maximumComponents: Int = DefinedArtifact.maximumOBSComponentCount
    ) -> OBSPCAVarianceReport? {
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return nil }

        let windowSamples = obsPaddedWindowSamples(for: artifact, signal: signal)
        let ranges = artifact.events.compactMap {
            eventWindow(
                event: $0,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
        }
        guard !ranges.isEmpty else { return nil }

        let channels = SignalSelection.validChannels(in: signal.data, sampleCount: sampleCount)
        guard !channels.isEmpty else { return nil }

        let componentLimit = min(max(maximumComponents, 0), max(ranges.count - 1, 0))
        guard componentLimit > 0 else {
            return OBSPCAVarianceReport(
                artifactID: artifact.id,
                eventCount: artifact.events.count,
                validEventCount: ranges.count,
                sampledEventCount: ranges.count,
                channelCount: channels.count,
                windowSampleCount: windowSamples,
                totalResidualVariance: 0,
                components: []
            )
        }

        let sampledRanges = sampledRanges(from: ranges, maximumCount: 80)
        let sampledEventCount = sampledRanges.count
        var aggregateGram = Array(
            repeating: [Double](repeating: 0, count: sampledEventCount),
            count: sampledEventCount
        )
        let varianceContributions = obsVarianceContributions(
            data: signal.data,
            channels: channels,
            sampledRanges: sampledRanges,
            workerCount: workerCount(for: channels.count)
        )
        for contribution in varianceContributions {
            for row in contribution.gram.indices {
                for column in contribution.gram[row].indices {
                    aggregateGram[row][column] += contribution.gram[row][column]
                }
            }
        }
        let contributingChannels = varianceContributions.count

        let eigenvalues = principalComponentEigenvalues(fromGram: aggregateGram, maximumCount: max(sampledEventCount - 1, componentLimit))
        let totalResidualVariance = eigenvalues.reduce(0, +)

        guard totalResidualVariance > 1e-12, contributingChannels > 0 else {
            return OBSPCAVarianceReport(
                artifactID: artifact.id,
                eventCount: artifact.events.count,
                validEventCount: ranges.count,
                sampledEventCount: sampledEventCount,
                channelCount: channels.count,
                windowSampleCount: windowSamples,
                totalResidualVariance: 0,
                components: []
            )
        }

        var cumulative = 0.0
        let components = eigenvalues.prefix(componentLimit).enumerated().map { index, variance in
            let explained = max(variance / totalResidualVariance, 0)
            cumulative = min(cumulative + explained, 1)
            return OBSPCAComponentVariance(
                componentIndex: index + 1,
                explainedVariance: explained,
                cumulativeVariance: cumulative,
                remainingVariance: max(1 - cumulative, 0)
            )
        }

        return OBSPCAVarianceReport(
            artifactID: artifact.id,
            eventCount: artifact.events.count,
            validEventCount: ranges.count,
            sampledEventCount: sampledEventCount,
            channelCount: contributingChannels,
            windowSampleCount: windowSamples,
            totalResidualVariance: totalResidualVariance,
            components: components
        )
    }

    private static func obsVarianceContributions(
        data: [[Float]],
        channels: [Int],
        sampledRanges: [Range<Int>],
        workerCount: Int
    ) -> [OBSVarianceContribution] {
        guard sampledRanges.count > 1, !channels.isEmpty else { return [] }
        let boundedWorkerCount = min(max(workerCount, 1), channels.count)
        guard boundedWorkerCount > 1 else {
            return channels.compactMap {
                obsVarianceContribution(channelData: data[$0], sampledRanges: sampledRanges)
            }
        }

        nonisolated(unsafe) var contributions: [OBSVarianceContribution] = []
        contributions.reserveCapacity(channels.count)
        let lock = NSLock()

        for batchStart in stride(from: 0, to: channels.count, by: boundedWorkerCount) {
            let batchEnd = min(batchStart + boundedWorkerCount, channels.count)
            let batchChannels = Array(channels[batchStart..<batchEnd])
            evaConcurrentPerform(iterations: batchChannels.count) { batchIndex in
                let channel = batchChannels[batchIndex]
                guard let contribution = obsVarianceContribution(
                    channelData: data[channel],
                    sampledRanges: sampledRanges
                ) else {
                    return
                }

                lock.lock()
                contributions.append(contribution)
                lock.unlock()
            }
        }

        return contributions
    }

    private static func obsVarianceContribution(
        channelData: [Float],
        sampledRanges: [Range<Int>]
    ) -> OBSVarianceContribution? {
        let windows = sampledRanges.map { Array(channelData[$0]) }
        guard windows.count > 1 else { return nil }

        let mean = meanWindow(windows)
        let residuals = windows.map { zip($0, mean).map { Double($0.0 - $0.1) } }
        var gram = Array(
            repeating: [Double](repeating: 0, count: residuals.count),
            count: residuals.count
        )
        var channelEnergy = 0.0

        for row in residuals.indices {
            for column in row..<residuals.count {
                let value = LinearAlgebra.dot(residuals[row], residuals[column])
                gram[row][column] = value
                gram[column][row] = value
                if row == column {
                    channelEnergy += value
                }
            }
        }

        guard channelEnergy > 1e-12 else { return nil }
        return OBSVarianceContribution(gram: gram)
    }

    static func cleanedSignal(
        from signal: MFFSignalData,
        artifacts: [DefinedArtifact],
        excluding badChannels: Set<Int>,
        progress: (@Sendable (ArtifactCleaningProgress) -> Void)? = nil
    ) -> (signal: MFFSignalData, summaries: [ArtifactCleaningSummary]) {
        var data = signal.data
        var summaries: [ArtifactCleaningSummary] = []
        let artifactsToClean = artifacts.filter { $0.cleaningMethod.removesArtifact && !$0.events.isEmpty }
        let artifactCount = artifactsToClean.count
        let totalEvents = artifactsToClean.reduce(0) { $0 + $1.events.count }
        var completedEvents = 0

        for (index, artifact) in artifactsToClean.enumerated() {
            guard !Task.isCancelled else { break }
            let startingCompletedEvents = completedEvents

            let reportProgress: (ArtifactCleaningProgressPhase, Int, String?) -> Void = { phase, artifactCompletedEvents, detail in
                let boundedArtifactCompleted = min(max(artifactCompletedEvents, 0), artifact.events.count)
                completedEvents = max(completedEvents, startingCompletedEvents + boundedArtifactCompleted)
                progress?(ArtifactCleaningProgress(
                    completed: completedEvents,
                    total: totalEvents,
                    artifactCompleted: boundedArtifactCompleted,
                    artifactTotal: artifact.events.count,
                    artifactIndex: index + 1,
                    artifactCount: artifactCount,
                    artifactName: artifact.name,
                    method: artifact.cleaningMethod,
                    phase: phase,
                    detail: detail
                ))
            }
            let reportSetupProgress: (String) -> Void = { detail in
                reportProgress(.preparing, 0, detail)
            }
            let reportEventProgress: (Int) -> Void = { artifactCompletedEvents in
                reportProgress(.cleaning, artifactCompletedEvents, nil)
            }
            let reportFinalizingProgress: (String) -> Void = { detail in
                let artifactCompleted = min(max(completedEvents - startingCompletedEvents, 0), artifact.events.count)
                reportProgress(.finalizing, artifactCompleted, detail)
            }

            reportSetupProgress("Checking events and readable channels")

            let channelCount: Int
            switch artifact.cleaningMethod {
            case .doNothing:
                channelCount = 0
            case .regression:
                reportSetupProgress("Preparing saved average waveform templates")
                channelCount = applyTemplateRegression(
                    artifact: artifact,
                    signal: signal,
                    data: &data,
                    eventProgress: reportEventProgress
                )
            case .obs:
                channelCount = applyOBS(
                    artifact: artifact,
                    signal: signal,
                    data: &data,
                    setupProgress: reportSetupProgress,
                    finalizingProgress: reportFinalizingProgress,
                    eventProgress: reportEventProgress
                )
            case .sspPCA:
                channelCount = applySSPPCA(
                    artifact: artifact,
                    signal: signal,
                    data: &data,
                    excluding: badChannels,
                    setupProgress: reportSetupProgress,
                    finalizingProgress: reportFinalizingProgress,
                    eventProgress: reportEventProgress
                )
            case .mas, .mar, .waas, .waar:
                reportSetupProgress("Building local (moving-window) artifact templates")
                channelCount = applyLocalTemplate(
                    artifact: artifact,
                    signal: signal,
                    data: &data,
                    eventProgress: reportEventProgress
                )
            }

            if channelCount > 0 {
                summaries.append(ArtifactCleaningSummary(
                    artifactID: artifact.id,
                    name: artifact.name,
                    method: artifact.cleaningMethod,
                    eventCount: artifact.events.count,
                    channelCount: channelCount
                ))
            }

            if completedEvents < startingCompletedEvents + artifact.events.count {
                reportEventProgress(artifact.events.count)
            }
        }

        let cleaned = MFFSignalData(
            signalURL: signal.signalURL,
            signalType: "\(signal.signalType) Artifact Cleaned",
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: signal.events,
            data: data,
            channelNames: signal.channelNames
        )
        return (cleaned, summaries)
    }

    // MARK: - Methods

    private static func applyTemplateRegression(
        artifact: DefinedArtifact,
        signal: MFFSignalData,
        data: inout [[Float]],
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let average = artifact.average,
              let sampleCount = data.first?.count,
              sampleCount > 0 else {
            return 0
        }

        let baseWindowSamples = windowSamples(for: artifact, signal: signal)
        let channels = SignalSelection.validChannels(in: data, sampleCount: sampleCount)
        var cleanedChannels = Set<Int>()
        var channelTemplates: [(channel: Int, rawTemplate: [Float])] = []

        for channel in channels {
            guard channel < average.allChannelSamples.count,
                  average.allChannelSamples[channel].count == baseWindowSamples else {
                continue
            }
            channelTemplates.append((channel, average.allChannelSamples[channel]))
        }

        guard !channelTemplates.isEmpty else { return 0 }

        for (eventIndex, event) in artifact.events.enumerated() {
            defer { eventProgress(eventIndex + 1) }
            let eventWindowLength = eventWindowSamples(
                for: event,
                artifact: artifact,
                fallback: baseWindowSamples,
                samplingRate: signal.samplingRate
            )
            guard let range = eventWindow(
                event: event,
                windowSamples: eventWindowLength,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            ) else { continue }

            for channelTemplate in channelTemplates {
                // Fit the saved (fixed-length) average waveform to this
                // event's own window length when variable-duration is on —
                // otherwise every event shares the base template as-is.
                let rawTemplate = eventWindowLength == baseWindowSamples
                    ? channelTemplate.rawTemplate
                    : ArtifactTemplateDetector.resampled(channelTemplate.rawTemplate, to: eventWindowLength)
                let template = centeredUnitVector(rawTemplate)
                guard !template.isEmpty else { continue }
                subtractBasis([template], from: &data[channelTemplate.channel], in: range)
                cleanedChannels.insert(channelTemplate.channel)
            }
        }

        return cleanedChannels.count
    }

    /// The window length (samples) to use for `event`'s own correction,
    /// honoring `artifact.usesVariableEventDuration` when the method supports
    /// it and the event actually carries a usable measured duration —
    /// otherwise every event shares `fallback` (the artifact's one fixed
    /// window, derived from `windowSamples(for:signal:)`).
    private static func eventWindowSamples(
        for event: MFFEvent,
        artifact: DefinedArtifact,
        fallback: Int,
        samplingRate: Double
    ) -> Int {
        guard artifact.usesVariableEventDuration,
              artifact.cleaningMethod.supportsVariableEventDuration,
              let duration = event.durationSeconds, duration > 0 else {
            return fallback
        }
        return max(Int((duration * samplingRate).rounded()), 3)
    }

    /// MAS/MAR/wAAS/wAAR: builds a template per event from donor epochs
    /// (median for MAS/MAR, Goldman-2000 exponentially-weighted mean for
    /// wAAS/wAAR), then either subtracts it directly (MAS/wAAS) or scales it by
    /// a least-squares fit first (MAR/wAAR) — matching `amri_eeg_cbc.m`'s
    /// local-pulse-artifact-template logic (see file header for citation).
    ///
    /// Each channel is corrected independently (its template only ever draws
    /// on that same channel's own neighboring epochs), so channels are
    /// processed across all CPU cores, mirroring `GradientRemover.correct`.
    /// The donor-event plan is built per channel because optional AMRI
    /// preprocessing can shift/drop windows differently for each channel.
    private static func applyLocalTemplate(
        artifact: DefinedArtifact,
        signal: MFFSignalData,
        data: inout [[Float]],
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let sampleCount = data.first?.count, sampleCount > 0 else { return 0 }

        let windowSamples = windowSamples(for: artifact, signal: signal)
        let ranges = artifact.events.map { event -> Range<Int>? in
            let eventLen = eventWindowSamples(for: event, artifact: artifact, fallback: windowSamples, samplingRate: signal.samplingRate)
            return eventWindow(event: event, windowSamples: eventLen, sampleCount: sampleCount, samplingRate: signal.samplingRate)
        }
        guard ranges.contains(where: { $0 != nil }) else { return 0 }

        let channels = SignalSelection.validChannels(in: data, sampleCount: sampleCount)
        guard !channels.isEmpty else { return 0 }

        let half = max(artifact.localTemplateWindowSize, 1) / 2
        let isWeighted = artifact.cleaningMethod == .waas || artifact.cleaningMethod == .waar
        let regresses = artifact.cleaningMethod == .mar || artifact.cleaningMethod == .waar
        let decay = artifact.waasDecayFactor
        let waasUsesAMRIGlobalWeights = artifact.waasUsesAMRIGlobalWeights
        let usesAMRIPreprocessing = artifact.type == .bcg && artifact.localTemplateUsesAMRIPreprocessing
        let preservesLocalBaseline = artifact.localTemplatePreservesLocalBaseline
        let edgeTaperSamplesRaw = max(Int((artifact.localTemplateEdgeTaperSeconds * signal.samplingRate).rounded()), 0)

        let progressLock = NSLock()
        nonisolated(unsafe) var completedChannels = 0
        let reportEvery = max(1, channels.count / 20)
        nonisolated(unsafe) var cleanedFlags = [Bool](repeating: false, count: channels.count)

        data.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct index, so concurrent writes
            // don't overlap; same pattern as `GradientRemover.correct`.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: channels.count) { index in
                guard !Task.isCancelled else { return }
                let channel = channels[index]
                let (corrected, cleaned) = correctChannelLocalTemplate(
                    out[channel],
                    ranges: ranges,
                    localHalfWindow: half,
                    isWeighted: isWeighted,
                    waasUsesAMRIGlobalWeights: waasUsesAMRIGlobalWeights,
                    decay: decay,
                    regresses: regresses,
                    usesAMRIPreprocessing: usesAMRIPreprocessing,
                    preservesLocalBaseline: preservesLocalBaseline,
                    edgeTaperSamplesRaw: edgeTaperSamplesRaw
                )
                out[channel] = corrected
                cleanedFlags[index] = cleaned

                progressLock.lock()
                completedChannels += 1
                let done = completedChannels
                progressLock.unlock()
                if done % reportEvery == 0 || done == channels.count {
                    eventProgress(Int(Double(done) / Double(channels.count) * Double(ranges.count)))
                }
            }
        }

        return cleanedFlags.filter { $0 }.count
    }

    /// Corrects a single channel's events from its own neighboring epochs.
    /// Snapshots the channel before any correction from this pass, so donor
    /// epochs for one event aren't contaminated by an already-corrected
    /// neighboring event within the same pass.
    private static func correctChannelLocalTemplate(
        _ channel: [Float],
        ranges: [Range<Int>?],
        localHalfWindow: Int,
        isWeighted: Bool,
        waasUsesAMRIGlobalWeights: Bool,
        decay: Double,
        regresses: Bool,
        usesAMRIPreprocessing: Bool,
        preservesLocalBaseline: Bool,
        edgeTaperSamplesRaw: Int
    ) -> (channel: [Float], cleaned: Bool) {
        let original = channel
        var corrected = channel
        let effectiveRanges = usesAMRIPreprocessing
            ? amriAlignedRanges(from: ranges, channel: original)
            : ranges
        let rawEpochs: [[Float]?] = effectiveRanges.map { range in range.map { Array(original[$0]) } }
        let templateEpochs: [[Float]?] = usesAMRIPreprocessing
            ? rawEpochs.map { $0.map(meanCentered) }
            : rawEpochs
        let donorPlan = localTemplateDonorPlan(
            ranges: effectiveRanges,
            localHalfWindow: localHalfWindow,
            isWeighted: isWeighted,
            waasUsesAMRIGlobalWeights: waasUsesAMRIGlobalWeights,
            decay: decay
        )
        var cleaned = false

        for (eventIndex, range) in effectiveRanges.enumerated() {
            guard let range,
                  let rawEpoch = rawEpochs[eventIndex],
                  let templateEpoch = templateEpochs[eventIndex] else { continue }
            let donors = donorPlan.donors[eventIndex]
            guard !donors.isEmpty else { continue }

            let template: [Float]
            if isWeighted {
                template = elementwiseWeightedMean(
                    indices: donors,
                    epochs: templateEpochs,
                    weights: donorPlan.weights[eventIndex],
                    length: range.count
                )
            } else {
                template = elementwiseMedian(indices: donors, epochs: templateEpochs, length: range.count)
            }

            let rawCorrection: [Double]
            if regresses {
                let k = Double(localRegressionCoefficient(y: templateEpoch, template: template))
                rawCorrection = template.map { k * Double($0) }
            } else {
                rawCorrection = template.map(Double.init)
            }

            // Same edge-taper + local-baseline mechanism as OBS: fades the
            // subtraction in/out smoothly at the window boundary instead of
            // cutting off sharply, and (optionally) de-trends the correction
            // so it doesn't introduce a DC/linear-drift step relative to the
            // surrounding signal. Bounded to this event's own (possibly
            // variable) window so the taper can't exceed half its length.
            let edgeTaperSamples = min(edgeTaperSamplesRaw, max(range.count / 2 - 1, 0))
            let taper = raisedCosineTaper(count: range.count, edgeSamples: edgeTaperSamples)
            guard let smoothed = smoothedWindowCorrection(
                rawCorrection,
                taper: taper,
                preservesLocalBaseline: preservesLocalBaseline,
                edgeTaperSamples: edgeTaperSamples
            ) else { continue }

            let count = min(range.count, rawEpoch.count, smoothed.weightedValues.count)
            for i in 0..<count {
                corrected[range.lowerBound + i] -= Float(smoothed.weightedValues[i])
            }
            cleaned = true
        }
        return (corrected, cleaned)
    }

    private static func localTemplateDonorPlan(
        ranges: [Range<Int>?],
        localHalfWindow: Int,
        isWeighted: Bool,
        waasUsesAMRIGlobalWeights: Bool,
        decay: Double
    ) -> (donors: [[Int]], weights: [[Double]]) {
        let validEvents = Set(ranges.indices.filter { ranges[$0] != nil })
        let donorsByEvent: [[Int]] = ranges.indices.map { eventIndex in
            guard ranges[eventIndex] != nil else { return [] }
            if isWeighted, waasUsesAMRIGlobalWeights {
                // AMRI wAAS/wAAR weights every valid epoch by distance from the
                // current one; the current event has weight 1.
                return ranges.indices.filter { validEvents.contains($0) }
            }
            let lo = max(0, eventIndex - localHalfWindow)
            let hi = min(ranges.count - 1, eventIndex + localHalfWindow)
            return (lo...hi).filter { $0 != eventIndex && validEvents.contains($0) }
        }
        let weightsByEvent: [[Double]] = isWeighted
            ? ranges.indices.map { eventIndex in
                donorsByEvent[eventIndex].map { pow(decay, abs(Double($0 - eventIndex))) }
            }
            : Array(repeating: [], count: ranges.count)
        return (donorsByEvent, weightsByEvent)
    }

    private static func amriAlignedRanges(from ranges: [Range<Int>?], channel: [Float]) -> [Range<Int>?] {
        let validRanges = ranges.compactMap { $0 }
        guard validRanges.count >= 3,
              let windowLength = validRanges.first?.count,
              windowLength > 2,
              validRanges.allSatisfy({ $0.count == windowLength }) else {
            return ranges
        }

        let powerEpochs = validRanges.dropFirst().dropLast().map { range -> [Double] in
            let epoch = meanCentered(Array(channel[range]))
            return epoch.map { Double($0 * $0) }
        }
        guard !powerEpochs.isEmpty else { return ranges }

        var medianPower = [Double](repeating: 0, count: windowLength)
        var column = [Double](repeating: 0, count: powerEpochs.count)
        for sample in 0..<windowLength {
            for (row, epoch) in powerEpochs.enumerated() { column[row] = epoch[sample] }
            column.sort()
            let mid = column.count / 2
            medianPower[sample] = column.count % 2 == 0
                ? (column[mid - 1] + column[mid]) / 2
                : column[mid]
        }
        guard let peak = medianPower.indices.max(by: { medianPower[$0] < medianPower[$1] }) else {
            return ranges
        }
        let shift = peak - windowLength / 2
        guard shift != 0 else { return ranges }

        return ranges.map { range in
            guard let range else { return nil }
            let shifted = (range.lowerBound + shift)..<(range.upperBound + shift)
            guard shifted.lowerBound >= 0, shifted.upperBound <= channel.count else { return nil }
            return shifted
        }
    }

    private static func meanCentered(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return values }
        let mean = values.reduce(Float(0), +) / Float(values.count)
        return values.map { $0 - mean }
    }

    /// Elementwise median across `epochs[indices]` (each resampled to `length`
    /// first — with variable-event-duration on, a donor event's own epoch may
    /// be a different length than the current event's, so it's fit to
    /// `length` before combining, the same way `applyTemplateRegression` fits
    /// the saved average template to each event's own window).
    private static func elementwiseMedian(indices: [Int], epochs: [[Float]?], length: Int) -> [Float] {
        guard !indices.isEmpty else { return [Float](repeating: 0, count: length) }
        let resized = resizedDonorEpochs(indices: indices, epochs: epochs, length: length)
        var result = [Float](repeating: 0, count: length)
        var column = [Float](repeating: 0, count: resized.count)
        for i in 0..<length {
            for (row, epoch) in resized.enumerated() { column[row] = epoch[i] }
            column.sort()
            let mid = column.count / 2
            result[i] = column.count % 2 == 0 ? (column[mid - 1] + column[mid]) / 2 : column[mid]
        }
        return result
    }

    /// Weighted mean across `epochs[indices]` (each resampled to `length`
    /// first — see `elementwiseMedian`), normalized by `weights` sum.
    private static func elementwiseWeightedMean(indices: [Int], epochs: [[Float]?], weights: [Double], length: Int) -> [Float] {
        guard !indices.isEmpty, indices.count == weights.count else { return [Float](repeating: 0, count: length) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 1e-12 else { return [Float](repeating: 0, count: length) }
        var result = [Double](repeating: 0, count: length)
        for (idx, weight) in zip(indices, weights) {
            guard weight > 0, let segment = epochs[idx] else { continue }
            let resized = segment.count == length ? segment : ArtifactTemplateDetector.resampled(segment, to: length)
            for i in 0..<length { result[i] += weight * Double(resized[i]) }
        }
        return result.map { Float($0 / totalWeight) }
    }

    /// Resamples each donor epoch to `length` (a no-op copy when it's already
    /// that length — the common case when the artifact doesn't use
    /// variable-event-duration).
    private static func resizedDonorEpochs(indices: [Int], epochs: [[Float]?], length: Int) -> [[Float]] {
        indices.map { idx -> [Float] in
            guard let epoch = epochs[idx] else { return [Float](repeating: 0, count: length) }
            return epoch.count == length ? epoch : ArtifactTemplateDetector.resampled(epoch, to: length)
        }
    }

    /// Least-squares scalar fit of `template ≈ k · y`: `k = dot(y, template) / dot(y, y)`.
    /// Matches `amri_eeg_gac.m`/`amri_eeg_cbc.m`'s AAR/MAR/wAAR fit direction.
    private static func localRegressionCoefficient(y: [Float], template: [Float]) -> Float {
        var denom: Float = 0
        var numer: Float = 0
        for i in y.indices {
            denom += y[i] * y[i]
            numer += y[i] * template[i]
        }
        guard denom > 1e-12 else { return 0 }
        return numer / denom
    }

    private static func applyOBS(
        artifact: DefinedArtifact,
        signal: MFFSignalData,
        data: inout [[Float]],
        setupProgress: (String) -> Void,
        finalizingProgress: (String) -> Void,
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let sampleCount = data.first?.count, sampleCount > 0 else { return 0 }

        let coreWindowSamples = windowSamples(for: artifact, signal: signal)
        let edgeTaperSamples = obsEdgeTaperSamples(for: artifact, signal: signal, windowSamples: coreWindowSamples)
        let windowSamples = coreWindowSamples + 2 * edgeTaperSamples
        let coreWindowMilliseconds = milliseconds(for: coreWindowSamples, samplingRate: signal.samplingRate)
        let edgeTaperMilliseconds = milliseconds(for: edgeTaperSamples, samplingRate: signal.samplingRate)
        setupProgress("Resolving event windows (\(coreWindowMilliseconds) ms core, \(edgeTaperMilliseconds) ms edge taper)")
        let baseEventRanges = artifact.events.map {
            eventWindow(
                event: $0,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
        }
        let strategy = resolvedOBSStrategy(for: artifact)
        let eventRanges = strategy == .topographyAligned
            ? topographyAlignedEventRanges(
                artifact: artifact,
                data: data,
                fallbackRanges: baseEventRanges,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
            : baseEventRanges
        let ranges = eventRanges.compactMap { $0 }
        guard !ranges.isEmpty else { return 0 }

        let channels = SignalSelection.validChannels(in: data, sampleCount: sampleCount)
        guard !channels.isEmpty else { return 0 }
        let workerCount = workerCount(for: channels.count)
        let componentLimit = max(artifact.obsPCAComponentCount, 0)
        let taper = raisedCosineTaper(count: windowSamples, edgeSamples: edgeTaperSamples)
        let channelScales = strategy == .topographyWeighted
            ? topographyCorrectionScales(for: artifact, channels: channels)
            : [:]

        switch strategy {
        case .virtualChannel:
            return applyVirtualChannelOBS(
                artifact: artifact,
                data: &data,
                eventRanges: eventRanges,
                ranges: ranges,
                channels: channels,
                sampleCount: sampleCount,
                taper: taper,
                edgeTaperSamples: edgeTaperSamples,
                componentLimit: componentLimit,
                setupProgress: setupProgress,
                finalizingProgress: finalizingProgress,
                eventProgress: eventProgress
            ).count
        case .clustered:
            return applyClusteredChannelwiseOBS(
                artifact: artifact,
                data: &data,
                eventRanges: eventRanges,
                channels: channels,
                sampleCount: sampleCount,
                windowSamples: windowSamples,
                edgeTaperSamples: edgeTaperSamples,
                taper: taper,
                componentLimit: componentLimit,
                workerCount: workerCount,
                setupProgress: setupProgress,
                finalizingProgress: finalizingProgress,
                eventProgress: eventProgress
            ).count
        case .spatiotemporal:
            return applySpatiotemporalOBS(
                artifact: artifact,
                data: &data,
                eventRanges: eventRanges,
                ranges: ranges,
                channels: channels,
                sampleCount: sampleCount,
                taper: taper,
                edgeTaperSamples: edgeTaperSamples,
                componentLimit: componentLimit,
                setupProgress: setupProgress,
                finalizingProgress: finalizingProgress,
                eventProgress: eventProgress
            ).count
        case .standard, .topographyGated, .topographyAligned, .topographyWeighted:
            return applyChannelwiseOBS(
                artifact: artifact,
                data: &data,
                eventRanges: eventRanges,
                ranges: ranges,
                channels: channels,
                sampleCount: sampleCount,
                windowSamples: windowSamples,
                edgeTaperSamples: edgeTaperSamples,
                taper: taper,
                componentLimit: componentLimit,
                workerCount: workerCount,
                channelScales: channelScales,
                setupProgress: setupProgress,
                finalizingProgress: finalizingProgress,
                eventProgress: eventProgress
            ).count
        }
    }

    private static func applyChannelwiseOBS(
        artifact: DefinedArtifact,
        data: inout [[Float]],
        eventRanges: [Range<Int>?],
        ranges: [Range<Int>],
        channels: [Int],
        sampleCount: Int,
        windowSamples: Int,
        edgeTaperSamples: Int,
        taper: [Double],
        componentLimit: Int,
        workerCount: Int,
        channelScales: [Int: Double] = [:],
        setupProgress: (String) -> Void,
        finalizingProgress: (String) -> Void,
        eventProgress: (Int) -> Void
    ) -> Set<Int> {
        let activeChannels = channels.filter {
            channelCorrectionScale(for: $0, scales: channelScales) > 1e-6
        }
        guard !activeChannels.isEmpty else { return [] }

        setupProgress("Fitting OBS bases from \(min(ranges.count, 80)) sampled windows across \(activeChannels.count) channels on \(workerCount) worker\(workerCount == 1 ? "" : "s")")
        let channelBases = fitOBSChannelBases(
            data: data,
            ranges: ranges,
            channels: activeChannels,
            componentLimit: componentLimit,
            workerCount: workerCount,
            setupProgress: setupProgress
        )

        guard !channelBases.isEmpty else { return [] }
        setupProgress("Prepared \(channelBases.count) channel bases; starting per-event subtraction")
        var cleanedChannels = Set<Int>()

        // Snapshot channel data as an immutable capture so concurrent closures
        // can read it without inout aliasing issues.
        let channelSnapshot: [[Float]] = channelBases.map { data[$0.channel] }
        let basisCount = channelBases.count
        let preservesBaseline = artifact.obsPreservesLocalBaseline

        if artifact.obsUsesOverlapAdd {
            // One accumulator per basis (aligned by index, not by channel key) so
            // the concurrentPerform inner loop can index without a dictionary lookup
            // or any locking — each basisIndex owns exactly one accumulator.
            let accumulators = (0..<basisCount).map { _ in
                OBSCorrectionAccumulator(sampleCount: sampleCount)
            }

            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange else { continue }

                evaConcurrentPerform(iterations: basisCount) { basisIndex in
                    guard let correction = fittedCorrection(
                        basis: channelBases[basisIndex].basis,
                        from: channelSnapshot[basisIndex],
                        in: range,
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    ) else { return }
                    let scale = channelCorrectionScale(for: channelBases[basisIndex].channel, scales: channelScales)
                    guard scale > 1e-6 else { return }
                    accumulators[basisIndex].add(correction.scaled(by: scale), in: range)
                }
            }

            finalizingProgress("Combining overlapping OBS corrections")
            for basisIndex in channelBases.indices {
                accumulators[basisIndex].apply(to: &data[channelBases[basisIndex].channel])
                cleanedChannels.insert(channelBases[basisIndex].channel)
            }
        } else {
            // Non-overlap-add: compute corrections concurrently per channel, then
            // apply to data serially (avoids inout aliasing across concurrent writes).
            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange else { continue }

                var corrections = [OBSCorrection?](repeating: nil, count: basisCount)
                nonisolated(unsafe) let correctionsPtr = UnsafeMutablePointer<OBSCorrection?>.allocate(capacity: basisCount)
                correctionsPtr.initialize(from: &corrections, count: basisCount)
                evaConcurrentPerform(iterations: basisCount) { basisIndex in
                    correctionsPtr[basisIndex] = fittedCorrection(
                        basis: channelBases[basisIndex].basis,
                        from: channelSnapshot[basisIndex],
                        in: range,
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    )
                }
                corrections = Array(UnsafeBufferPointer(start: correctionsPtr, count: basisCount))
                correctionsPtr.deinitialize(count: basisCount)
                correctionsPtr.deallocate()
                for basisIndex in channelBases.indices {
                    guard let correction = corrections[basisIndex] else { continue }
                    let channel = channelBases[basisIndex].channel
                    let scale = channelCorrectionScale(for: channel, scales: channelScales)
                    guard scale > 1e-6 else { continue }
                    for offset in 0..<range.count {
                        data[channel][range.lowerBound + offset] -= Float(correction.weightedValues[offset] * scale)
                    }
                    cleanedChannels.insert(channel)
                }
            }
        }

        return cleanedChannels
    }

    private static func applyClusteredChannelwiseOBS(
        artifact: DefinedArtifact,
        data: inout [[Float]],
        eventRanges: [Range<Int>?],
        channels: [Int],
        sampleCount: Int,
        windowSamples: Int,
        edgeTaperSamples: Int,
        taper: [Double],
        componentLimit: Int,
        workerCount: Int,
        setupProgress: (String) -> Void,
        finalizingProgress: (String) -> Void,
        eventProgress: (Int) -> Void
    ) -> Set<Int> {
        let validRanges = eventRanges.compactMap { $0 }
        let requestedClusters = min(
            max(artifact.obsClusterCount, 1),
            DefinedArtifact.maximumOBSClusterCount
        )
        let clusterCount = min(requestedClusters, validRanges.count)
        guard clusterCount > 1 else {
            return applyChannelwiseOBS(
                artifact: artifact,
                data: &data,
                eventRanges: eventRanges,
                ranges: validRanges,
                channels: channels,
                sampleCount: sampleCount,
                windowSamples: windowSamples,
                edgeTaperSamples: edgeTaperSamples,
                taper: taper,
                componentLimit: componentLimit,
                workerCount: workerCount,
                setupProgress: setupProgress,
                finalizingProgress: finalizingProgress,
                eventProgress: eventProgress
            )
        }

        let scoredRanges = validRanges.map { range in
            (range: range, score: clusterScore(data: data, range: range, channels: channels, artifact: artifact))
        }.sorted { $0.score < $1.score }

        var clusters = [[Range<Int>]](repeating: [], count: clusterCount)
        for (rank, scoredRange) in scoredRanges.enumerated() {
            let clusterIndex = min(rank * clusterCount / max(scoredRanges.count, 1), clusterCount - 1)
            clusters[clusterIndex].append(scoredRange.range)
        }

        var cleanedChannels = Set<Int>()
        var completed = 0
        for (clusterIndex, clusterRanges) in clusters.enumerated() where !clusterRanges.isEmpty {
            setupProgress("Fitting clustered OBS basis \(clusterIndex + 1) of \(clusterCount) from \(clusterRanges.count) windows")
            let cleaned = applyChannelwiseOBS(
                artifact: artifact,
                data: &data,
                eventRanges: clusterRanges.map(Optional.some),
                ranges: clusterRanges,
                channels: channels,
                sampleCount: sampleCount,
                windowSamples: windowSamples,
                edgeTaperSamples: edgeTaperSamples,
                taper: taper,
                componentLimit: componentLimit,
                workerCount: workerCount,
                setupProgress: setupProgress,
                finalizingProgress: finalizingProgress
            ) { clusterCompleted in
                eventProgress(completed + clusterCompleted)
            }
            cleanedChannels.formUnion(cleaned)
            completed += clusterRanges.count
            eventProgress(completed)
        }
        return cleanedChannels
    }

    private static func applyVirtualChannelOBS(
        artifact: DefinedArtifact,
        data: inout [[Float]],
        eventRanges: [Range<Int>?],
        ranges: [Range<Int>],
        channels: [Int],
        sampleCount: Int,
        taper: [Double],
        edgeTaperSamples: Int,
        componentLimit: Int,
        setupProgress: (String) -> Void,
        finalizingProgress: (String) -> Void,
        eventProgress: (Int) -> Void
    ) -> Set<Int> {
        guard let topography = artifact.topography,
              let weights = topographyProjectionWeights(for: topography, channels: channels),
              !weights.isEmpty else {
            return []
        }

        let projectionChannels = channels.filter { weights[$0] != nil }
        guard !projectionChannels.isEmpty else { return [] }

        setupProgress("Projecting \(projectionChannels.count) channels onto saved topography for virtual-channel OBS")
        var virtualChannel = [Float](repeating: 0, count: sampleCount)
        for channel in projectionChannels {
            guard let weight = weights[channel] else { continue }
            let scaledWeight = Float(weight)
            for sample in 0..<min(sampleCount, data[channel].count) {
                virtualChannel[sample] += data[channel][sample] * scaledWeight
            }
        }

        guard let virtualBasis = fitOBSChannelBasis(
            channel: -1,
            channelData: virtualChannel,
            ranges: ranges,
            componentLimit: componentLimit
        ) else {
            return []
        }

        setupProgress("Prepared virtual-channel OBS basis; projecting corrections back to the topography map")
        let virtualSnapshot = virtualChannel
        let preservesBaseline = artifact.obsPreservesLocalBaseline
        var cleanedChannels = Set<Int>()

        if artifact.obsUsesOverlapAdd {
            let accumulators = (0..<projectionChannels.count).map { _ in
                OBSCorrectionAccumulator(sampleCount: sampleCount)
            }

            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange,
                      let correction = fittedCorrection(
                        basis: virtualBasis.basis,
                        from: virtualSnapshot,
                        in: range,
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                      ) else { continue }

                for (offset, channel) in projectionChannels.enumerated() {
                    guard let weight = weights[channel] else { continue }
                    accumulators[offset].add(correction.scaled(by: weight), in: range)
                }
            }

            finalizingProgress("Combining overlapping virtual-channel OBS corrections")
            for (offset, channel) in projectionChannels.enumerated() {
                accumulators[offset].apply(to: &data[channel])
                cleanedChannels.insert(channel)
            }
        } else {
            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange,
                      let correction = fittedCorrection(
                        basis: virtualBasis.basis,
                        from: virtualSnapshot,
                        in: range,
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                      ) else { continue }

                for channel in projectionChannels {
                    guard let weight = weights[channel] else { continue }
                    for offset in 0..<range.count {
                        data[channel][range.lowerBound + offset] -= Float(correction.weightedValues[offset] * weight)
                    }
                    cleanedChannels.insert(channel)
                }
            }
        }

        return cleanedChannels
    }

    private static func applySpatiotemporalOBS(
        artifact: DefinedArtifact,
        data: inout [[Float]],
        eventRanges: [Range<Int>?],
        ranges: [Range<Int>],
        channels: [Int],
        sampleCount: Int,
        taper: [Double],
        edgeTaperSamples: Int,
        componentLimit: Int,
        setupProgress: (String) -> Void,
        finalizingProgress: (String) -> Void,
        eventProgress: (Int) -> Void
    ) -> Set<Int> {
        guard channels.count > 1 else { return [] }

        setupProgress("Fitting spatiotemporal OBS basis from \(min(ranges.count, 60)) sampled channel-by-time windows")
        guard let basis = fitSpatiotemporalOBSBasis(
            data: data,
            ranges: ranges,
            channels: channels,
            componentLimit: componentLimit
        ) else {
            return []
        }

        setupProgress("Prepared \(basis.count) spatiotemporal basis vector\(basis.count == 1 ? "" : "s"); starting per-event subtraction")
        let preservesBaseline = artifact.obsPreservesLocalBaseline
        var cleanedChannels = Set<Int>()

        if artifact.obsUsesOverlapAdd {
            let accumulators = (0..<channels.count).map { _ in
                OBSCorrectionAccumulator(sampleCount: sampleCount)
            }

            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange,
                      let corrections = spatiotemporalCorrections(
                        basis: basis,
                        data: data,
                        range: range,
                        channels: channels
                      ) else { continue }

                for (offset, correctionValues) in corrections.enumerated() {
                    guard let correction = smoothedWindowCorrection(
                        correctionValues,
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    ) else { continue }
                    accumulators[offset].add(correction, in: range)
                }
            }

            finalizingProgress("Combining overlapping spatiotemporal OBS corrections")
            for (offset, channel) in channels.enumerated() {
                accumulators[offset].apply(to: &data[channel])
                cleanedChannels.insert(channel)
            }
        } else {
            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange,
                      let corrections = spatiotemporalCorrections(
                        basis: basis,
                        data: data,
                        range: range,
                        channels: channels
                      ) else { continue }

                for (channelOffset, channel) in channels.enumerated() {
                    guard let correction = smoothedWindowCorrection(
                        corrections[channelOffset],
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    ) else { continue }
                    for sampleOffset in 0..<range.count {
                        data[channel][range.lowerBound + sampleOffset] -= Float(correction.weightedValues[sampleOffset])
                    }
                    cleanedChannels.insert(channel)
                }
            }
        }

        return cleanedChannels
    }

    private static func resolvedOBSStrategy(for artifact: DefinedArtifact) -> ArtifactOBSStrategy {
        let strategy = artifact.obsStrategy
        if strategy.requiresTopography, artifact.topography == nil {
            return .standard
        }
        return strategy
    }

    private static func topographyAlignedEventRanges(
        artifact: DefinedArtifact,
        data: [[Float]],
        fallbackRanges: [Range<Int>?],
        windowSamples: Int,
        sampleCount: Int,
        samplingRate: Double
    ) -> [Range<Int>?] {
        guard let topography = artifact.topography,
              let weights = topographyProjectionWeights(
                for: topography,
                channels: SignalSelection.validChannels(in: data, sampleCount: sampleCount)
              ),
              !weights.isEmpty,
              samplingRate > 0 else {
            return fallbackRanges
        }

        let channels = weights.keys.sorted()
        let reference = channels.compactMap { weights[$0] }
        guard reference.count == channels.count, !reference.isEmpty else { return fallbackRanges }

        let searchSamples = Int((
            min(max(artifact.obsAlignmentSearchSeconds, 0), DefinedArtifact.maximumOBSAlignmentSearchSeconds)
            * samplingRate
        ).rounded())
        guard searchSamples > 0 else { return fallbackRanges }

        return artifact.events.enumerated().map { index, event in
            let nominalCenter = Int((event.centerTimeSeconds * samplingRate).rounded())
            let lower = max(nominalCenter - searchSamples, 0)
            let upper = min(nominalCenter + searchSamples, sampleCount - 1)
            guard lower <= upper else { return fallbackRanges.indices.contains(index) ? fallbackRanges[index] : nil }

            var bestCenter = nominalCenter
            var bestScore = -Double.infinity
            for sample in lower...upper {
                guard eventWindow(centerSample: sample, windowSamples: windowSamples, sampleCount: sampleCount) != nil else {
                    continue
                }
                let values = channels.map { channel -> Double in
                    guard data.indices.contains(channel), data[channel].indices.contains(sample) else { return 0 }
                    return Double(data[channel][sample])
                }
                let normalized = normalizedSpatial(values)
                guard normalized.count == reference.count else { continue }
                let score = abs(LinearAlgebra.dot(reference, normalized))
                if score > bestScore {
                    bestScore = score
                    bestCenter = sample
                }
            }

            return eventWindow(centerSample: bestCenter, windowSamples: windowSamples, sampleCount: sampleCount)
                ?? (fallbackRanges.indices.contains(index) ? fallbackRanges[index] : nil)
        }
    }

    private static func topographyProjectionWeights(
        for topography: ArtifactTemplateTopography,
        channels: [Int]
    ) -> [Int: Double]? {
        let topographyChannels = Set(topography.channelIndices)
        let projectionChannels = channels.filter {
            (topographyChannels.isEmpty || topographyChannels.contains($0))
                && topography.channelValues.indices.contains($0)
        }
        guard projectionChannels.count >= 2 else { return nil }

        let normalized = normalizedSpatial(projectionChannels.map { Double(topography.channelValues[$0]) })
        guard normalized.count == projectionChannels.count, !normalized.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(projectionChannels, normalized))
    }

    private static func topographyCorrectionScales(
        for artifact: DefinedArtifact,
        channels: [Int]
    ) -> [Int: Double] {
        guard let topography = artifact.topography,
              let weights = topographyProjectionWeights(for: topography, channels: channels),
              !weights.isEmpty else {
            return [:]
        }

        let strength = min(max(artifact.obsTopographyWeightStrength, 0), 1)
        let maxWeight = max(weights.values.map { abs($0) }.max() ?? 0, 1e-12)
        var scales: [Int: Double] = [:]
        for channel in channels {
            let normalizedWeight = abs(weights[channel] ?? 0) / maxWeight
            scales[channel] = (1 - strength) + strength * normalizedWeight
        }
        return scales
    }

    private static func channelCorrectionScale(for channel: Int, scales: [Int: Double]) -> Double {
        guard !scales.isEmpty else { return 1 }
        return min(max(scales[channel] ?? 0, 0), 1)
    }

    private static func clusterScore(
        data: [[Float]],
        range: Range<Int>,
        channels: [Int],
        artifact: DefinedArtifact
    ) -> Double {
        if let topography = artifact.topography,
           let weights = topographyProjectionWeights(for: topography, channels: channels),
           !weights.isEmpty {
            var energy = 0.0
            for sample in range {
                var projection = 0.0
                for channel in channels {
                    guard let weight = weights[channel],
                          data.indices.contains(channel),
                          data[channel].indices.contains(sample) else { continue }
                    projection += Double(data[channel][sample]) * weight
                }
                energy += projection * projection
            }
            return sqrt(energy / Double(max(range.count, 1)))
        }

        let sampledChannels = Array(channels.prefix(8))
        guard !sampledChannels.isEmpty else { return 0 }
        var energy = 0.0
        var count = 0
        for channel in sampledChannels where data.indices.contains(channel) {
            for sample in range where data[channel].indices.contains(sample) {
                let value = Double(data[channel][sample])
                energy += value * value
                count += 1
            }
        }
        return sqrt(energy / Double(max(count, 1)))
    }

    private static func fitSpatiotemporalOBSBasis(
        data: [[Float]],
        ranges: [Range<Int>],
        channels: [Int],
        componentLimit: Int
    ) -> [[Double]]? {
        let windows = sampledRanges(from: ranges, maximumCount: 60).map {
            flattenedWindow(data: data, range: $0, channels: channels)
        }
        guard let sampleCount = windows.first?.count,
              sampleCount > 0,
              windows.allSatisfy({ $0.count == sampleCount }) else {
            return nil
        }

        let mean = meanDoubleWindow(windows)
        var basis = [centeredUnitVector(mean)].filter { !$0.isEmpty }
        if windows.count > 1, componentLimit > 0 {
            let residuals = windows.map { zip($0, mean).map { $0.0 - $0.1 } }
            basis += principalComponents(from: residuals, maximumCount: min(componentLimit, windows.count - 1))
        }
        return basis.isEmpty ? nil : basis
    }

    private static func spatiotemporalCorrections(
        basis: [[Double]],
        data: [[Float]],
        range: Range<Int>,
        channels: [Int]
    ) -> [[Double]]? {
        let flattened = flattenedWindow(data: data, range: range, channels: channels)
        let usableBasis = basis.filter {
            $0.count == flattened.count && SignalStatistics.vectorEnergy($0) > 1e-12
        }
        guard !usableBasis.isEmpty else { return nil }

        let y = centeredVector(flattened)
        let coefficients = coefficientsForBasis(usableBasis, y: y)
        guard coefficients.count == usableBasis.count else { return nil }

        var flattenedCorrection = [Double](repeating: 0, count: flattened.count)
        for offset in flattenedCorrection.indices {
            for basisIndex in usableBasis.indices {
                flattenedCorrection[offset] += coefficients[basisIndex] * usableBasis[basisIndex][offset]
            }
        }

        var corrections = Array(
            repeating: [Double](repeating: 0, count: range.count),
            count: channels.count
        )
        for channelOffset in channels.indices {
            let start = channelOffset * range.count
            for sampleOffset in 0..<range.count {
                corrections[channelOffset][sampleOffset] = flattenedCorrection[start + sampleOffset]
            }
        }
        return corrections
    }

    private static func flattenedWindow(
        data: [[Float]],
        range: Range<Int>,
        channels: [Int]
    ) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(channels.count * range.count)
        for channel in channels {
            guard data.indices.contains(channel) else {
                values += [Double](repeating: 0, count: range.count)
                continue
            }
            for sample in range {
                values.append(data[channel].indices.contains(sample) ? Double(data[channel][sample]) : 0)
            }
        }
        return values
    }

    private static func meanDoubleWindow(_ windows: [[Double]]) -> [Double] {
        guard let count = windows.first?.count, count > 0 else { return [] }
        var mean = [Double](repeating: 0, count: count)
        for window in windows where window.count == count {
            for sample in 0..<count {
                mean[sample] += window[sample]
            }
        }
        let divisor = Double(max(windows.count, 1))
        for sample in mean.indices {
            mean[sample] /= divisor
        }
        return mean
    }

    private static func fitOBSChannelBases(
        data: [[Float]],
        ranges: [Range<Int>],
        channels: [Int],
        componentLimit: Int,
        workerCount: Int,
        setupProgress: (String) -> Void
    ) -> [OBSChannelBasis] {
        guard !channels.isEmpty else { return [] }
        let boundedWorkerCount = min(max(workerCount, 1), channels.count)
        guard boundedWorkerCount > 1 else {
            return channels.compactMap { channel in
                fitOBSChannelBasis(
                    channel: channel,
                    channelData: data[channel],
                    ranges: ranges,
                    componentLimit: componentLimit
                )
            }
        }

        nonisolated(unsafe) var bases: [OBSChannelBasis] = []
        bases.reserveCapacity(channels.count)
        let lock = NSLock()
        let batchSize = boundedWorkerCount
        var completedChannels = 0

        for batchStart in stride(from: 0, to: channels.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, channels.count)
            let batchChannels = Array(channels[batchStart..<batchEnd])
            evaConcurrentPerform(iterations: batchChannels.count) { batchIndex in
                let channel = batchChannels[batchIndex]
                guard let basis = fitOBSChannelBasis(
                    channel: channel,
                    channelData: data[channel],
                    ranges: ranges,
                    componentLimit: componentLimit
                ) else {
                    return
                }

                lock.lock()
                bases.append(basis)
                lock.unlock()
            }

            completedChannels = batchEnd
            if completedChannels < channels.count {
                setupProgress("Fitting OBS bases \(completedChannels) of \(channels.count) channels on \(boundedWorkerCount) workers")
            }
        }

        return bases.sorted { $0.channel < $1.channel }
    }

    private static func fitOBSChannelBasis(
        channel: Int,
        channelData: [Float],
        ranges: [Range<Int>],
        componentLimit: Int
    ) -> OBSChannelBasis? {
        let windows = sampledWindows(from: channelData, ranges: ranges, maximumCount: 80)
        guard !windows.isEmpty else { return nil }

        let mean = meanWindow(windows)
        var basis = [centeredUnitVector(mean)].filter { !$0.isEmpty }
        if windows.count > 1, componentLimit > 0 {
            let residuals = windows.map { zip($0, mean).map { Double($0.0 - $0.1) } }
            basis += principalComponents(from: residuals, maximumCount: min(componentLimit, windows.count - 1))
        }
        guard !basis.isEmpty else { return nil }
        return OBSChannelBasis(channel: channel, basis: basis)
    }

    private static func applySSPPCA(
        artifact: DefinedArtifact,
        signal: MFFSignalData,
        data: inout [[Float]],
        excluding badChannels: Set<Int>,
        setupProgress: (String) -> Void,
        finalizingProgress: (String) -> Void,
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let sampleCount = data.first?.count, sampleCount > 0 else { return 0 }

        let coreWindowSamples = windowSamples(for: artifact, signal: signal)
        let edgeTaperSamples = obsEdgeTaperSamples(for: artifact, signal: signal, windowSamples: coreWindowSamples)
        let windowSamples = coreWindowSamples + 2 * edgeTaperSamples
        let coreWindowMilliseconds = milliseconds(for: coreWindowSamples, samplingRate: signal.samplingRate)
        let edgeTaperMilliseconds = milliseconds(for: edgeTaperSamples, samplingRate: signal.samplingRate)
        setupProgress("Resolving event windows (\(coreWindowMilliseconds) ms core, \(edgeTaperMilliseconds) ms edge taper)")
        let eventRanges = artifact.events.map {
            eventWindow(
                event: $0,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
        }
        let ranges = eventRanges.compactMap { $0 }
        let channels = SignalSelection.validChannels(in: data, sampleCount: sampleCount)
            .filter { !badChannels.contains($0) }
        guard channels.count > 1, !ranges.isEmpty else { return 0 }
        let taper = raisedCosineTaper(count: windowSamples, edgeSamples: edgeTaperSamples)

        setupProgress("Computing spatial covariance from \(ranges.count) windows across \(channels.count) channels")
        let covariance = spatialCovariance(data: data, ranges: ranges, channels: channels)
        setupProgress("Solving SSP/PCA projection components")
        let eigen = LinearAlgebra.symmetricEigenDecomposition(covariance)
        guard eigen.values.count == channels.count,
              eigen.vectors.count == channels.count else {
            return 0
        }

        let ordered = eigen.values.indices.sorted { eigen.values[$0] > eigen.values[$1] }
        let componentCount = min(2, ordered.filter { eigen.values[$0] > 1e-9 }.count)
        guard componentCount > 0 else { return 0 }

        let components = ordered.prefix(componentCount).map { component in
            (0..<channels.count).map { row in eigen.vectors[row][component] }
        }

        setupProgress("Prepared \(componentCount) spatial components; starting per-event projection")
        var cleanedChannels = Set<Int>()
        let channelCount = channels.count
        let preservesBaseline = artifact.obsPreservesLocalBaseline

        if artifact.obsUsesOverlapAdd {
            // One accumulator per channel offset (aligned with `channels` array).
            let accumulators = (0..<channelCount).map { _ in
                OBSCorrectionAccumulator(sampleCount: sampleCount)
            }

            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange else { continue }
                // sspCorrections is a single scan over samples; compute it once.
                let rawCorrections = sspCorrections(
                    data: data,
                    range: range,
                    channels: channels,
                    components: components
                )
                // Taper and accumulate per channel in parallel.
                evaConcurrentPerform(iterations: channelCount) { offset in
                    guard let correction = smoothedWindowCorrection(
                        rawCorrections[offset],
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    ) else { return }
                    accumulators[offset].add(correction, in: range)
                }
            }

            finalizingProgress("Combining overlapping SSP/PCA corrections")
            for (offset, channel) in channels.enumerated() {
                accumulators[offset].apply(to: &data[channel])
                cleanedChannels.insert(channel)
            }
        } else {
            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange else { continue }
                let rawCorrections = sspCorrections(
                    data: data,
                    range: range,
                    channels: channels,
                    components: components
                )
                // Compute tapered corrections concurrently, apply serially.
                var smoothed = [OBSCorrection?](repeating: nil, count: channelCount)
                nonisolated(unsafe) let smoothedPtr = UnsafeMutablePointer<OBSCorrection?>.allocate(capacity: channelCount)
                smoothedPtr.initialize(from: &smoothed, count: channelCount)
                evaConcurrentPerform(iterations: channelCount) { offset in
                    smoothedPtr[offset] = smoothedWindowCorrection(
                        rawCorrections[offset],
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    )
                }
                smoothed = Array(UnsafeBufferPointer(start: smoothedPtr, count: channelCount))
                smoothedPtr.deinitialize(count: channelCount)
                smoothedPtr.deallocate()
                for (offset, channel) in channels.enumerated() {
                    guard let correction = smoothed[offset] else { continue }
                    for sampleOffset in 0..<range.count {
                        data[channel][range.lowerBound + sampleOffset] -= Float(correction.weightedValues[sampleOffset])
                    }
                    cleanedChannels.insert(channel)
                }
            }
        }

        return cleanedChannels.count
    }

    // MARK: - Basis fitting

    private static func subtractBasis(_ basis: [[Double]], from channel: inout [Float], in range: Range<Int>) {
        let taper = [Double](repeating: 1, count: range.count)
        subtractBasis(
            basis,
            from: &channel,
            in: range,
            taper: taper,
            preservesLocalBaseline: false,
            edgeTaperSamples: 0
        )
    }

    private static func subtractBasis(
        _ basis: [[Double]],
        from channel: inout [Float],
        in range: Range<Int>,
        taper: [Double],
        preservesLocalBaseline: Bool,
        edgeTaperSamples: Int
    ) {
        guard let correction = fittedCorrection(
            basis: basis,
            from: channel,
            in: range,
            taper: taper,
            preservesLocalBaseline: preservesLocalBaseline,
            edgeTaperSamples: edgeTaperSamples
        ) else { return }

        for offset in 0..<range.count {
            channel[range.lowerBound + offset] -= Float(correction.weightedValues[offset])
        }
    }

    private static func fittedCorrection(
        basis: [[Double]],
        from channel: [Float],
        in range: Range<Int>,
        taper: [Double],
        preservesLocalBaseline: Bool,
        edgeTaperSamples: Int
    ) -> OBSCorrection? {
        let basis = basis.filter { $0.count == range.count && SignalStatistics.vectorEnergy($0) > 1e-12 }
        guard !basis.isEmpty, taper.count == range.count else { return nil }

        let samples = range.map { channel[$0] }
        let y = centeredVector(samples)
        let coefficients = coefficientsForBasis(basis, y: y)
        guard coefficients.count == basis.count else { return nil }

        var correction = [Double](repeating: 0, count: range.count)
        for offset in 0..<range.count {
            for basisIndex in basis.indices {
                correction[offset] += coefficients[basisIndex] * basis[basisIndex][offset]
            }
        }

        if preservesLocalBaseline {
            preserveLocalBaseline(in: &correction, edgeTaperSamples: edgeTaperSamples)
        }
        return smoothedWindowCorrection(
            correction,
            taper: taper,
            preservesLocalBaseline: false,
            edgeTaperSamples: edgeTaperSamples
        )
    }

    private static func coefficientsForBasis(_ basis: [[Double]], y: [Double]) -> [Double] {
        let count = basis.count
        var gram = Array(repeating: [Double](repeating: 0, count: count), count: count)
        var rhs = [Double](repeating: 0, count: count)

        for row in 0..<count {
            rhs[row] = LinearAlgebra.dot(basis[row], y)
            for column in row..<count {
                let value = LinearAlgebra.dot(basis[row], basis[column])
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        for index in 0..<count {
            gram[index][index] += max(abs(gram[index][index]) * 1e-6, 1e-9)
        }
        return LinearAlgebra.solveLinearSystem(gram, rhs) ?? []
    }

    private static func sspCorrections(
        data: [[Float]],
        range: Range<Int>,
        channels: [Int],
        components: [[Double]]
    ) -> [[Double]] {
        var corrections = Array(
            repeating: [Double](repeating: 0, count: range.count),
            count: channels.count
        )

        for (sampleOffset, sample) in range.enumerated() {
            var values = channels.map { Double(data[$0][sample]) }
            let mean = values.reduce(0, +) / Double(max(values.count, 1))
            for index in values.indices {
                values[index] -= mean
            }

            var removal = [Double](repeating: 0, count: channels.count)
            for component in components {
                let coefficient = LinearAlgebra.dot(values, component)
                for index in removal.indices {
                    removal[index] += coefficient * component[index]
                }
            }

            for channelOffset in channels.indices {
                corrections[channelOffset][sampleOffset] = removal[channelOffset]
            }
        }

        return corrections
    }

    private static func smoothedWindowCorrection(
        _ values: [Double],
        taper: [Double],
        preservesLocalBaseline: Bool,
        edgeTaperSamples: Int
    ) -> OBSCorrection? {
        guard values.count == taper.count, !values.isEmpty else { return nil }
        var correction = values
        if preservesLocalBaseline {
            preserveLocalBaseline(in: &correction, edgeTaperSamples: edgeTaperSamples)
        }
        forceZeroAtBoundaries(&correction)
        let weighted = correction.indices.map { correction[$0] * taper[$0] }
        return OBSCorrection(weightedValues: weighted, weights: taper)
    }

    // MARK: - Window helpers

    private static func windowSamples(for artifact: DefinedArtifact, signal: MFFSignalData) -> Int {
        if let count = artifact.average?.allChannelSamples.first?.count, count > 1 {
            return count
        }
        return max(Int((artifact.windowSizeSeconds * signal.samplingRate).rounded()), 3)
    }

    private static func workerCount(for itemCount: Int) -> Int {
        guard itemCount > 1 else { return 1 }
        return min(itemCount, evaMaxWorkers)
    }

    private static func milliseconds(for sampleCount: Int, samplingRate: Double) -> Int {
        guard samplingRate > 0 else { return 0 }
        return Int((Double(sampleCount) / samplingRate * 1000).rounded())
    }

    private static func obsPaddedWindowSamples(for artifact: DefinedArtifact, signal: MFFSignalData) -> Int {
        let windowSamples = windowSamples(for: artifact, signal: signal)
        let edgeSamples = obsEdgeTaperSamples(for: artifact, signal: signal, windowSamples: windowSamples)
        return max(windowSamples + 2 * edgeSamples, windowSamples)
    }

    private static func obsEdgeTaperSamples(
        for artifact: DefinedArtifact,
        signal: MFFSignalData,
        windowSamples: Int
    ) -> Int {
        guard signal.samplingRate > 0 else { return 0 }
        let seconds = min(
            max(artifact.obsEdgeTaperSeconds, 0),
            DefinedArtifact.maximumOBSEdgeTaperSeconds
        )
        let requested = Int((seconds * signal.samplingRate).rounded())
        return min(max(requested, 0), max(windowSamples / 2 - 1, 0))
    }

    private static func eventWindow(
        event: MFFEvent,
        windowSamples: Int,
        sampleCount: Int,
        samplingRate: Double
    ) -> Range<Int>? {
        guard samplingRate > 0, windowSamples > 1, sampleCount >= windowSamples else { return nil }
        let center = Int((event.centerTimeSeconds * samplingRate).rounded())
        return eventWindow(centerSample: center, windowSamples: windowSamples, sampleCount: sampleCount)
    }

    private static func eventWindow(
        centerSample: Int,
        windowSamples: Int,
        sampleCount: Int
    ) -> Range<Int>? {
        guard windowSamples > 1, sampleCount >= windowSamples else { return nil }
        let start = centerSample - windowSamples / 2
        let end = start + windowSamples
        guard start >= 0, end <= sampleCount else { return nil }
        return start..<end
    }

    private static func sampledWindows(from channel: [Float], ranges: [Range<Int>], maximumCount: Int) -> [[Float]] {
        sampledRanges(from: ranges, maximumCount: maximumCount).map { Array(channel[$0]) }
    }

    private static func sampledRanges(from ranges: [Range<Int>], maximumCount: Int) -> [Range<Int>] {
        guard ranges.count > maximumCount, maximumCount > 0 else {
            return ranges
        }

        return (0..<maximumCount).map { index in
            let rangeIndex = index * ranges.count / maximumCount
            return ranges[rangeIndex]
        }
    }

    private static func raisedCosineTaper(count: Int, edgeSamples: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard edgeSamples > 0 else { return [Double](repeating: 1, count: count) }

        return (0..<count).map { index in
            let distanceFromEdge = min(index, count - 1 - index)
            guard distanceFromEdge < edgeSamples else { return 1 }
            let phase = Double(distanceFromEdge) / Double(edgeSamples)
            return 0.5 - 0.5 * cos(.pi * phase)
        }
    }

    private static func preserveLocalBaseline(in correction: inout [Double], edgeTaperSamples: Int) {
        guard correction.count > 2 else { return }
        let anchorCount = min(max(edgeTaperSamples, 1), max(correction.count / 4, 1))
        let leftMean = mean(correction.prefix(anchorCount))
        let rightMean = mean(correction.suffix(anchorCount))
        let denominator = Double(max(correction.count - 1, 1))

        for index in correction.indices {
            let fraction = Double(index) / denominator
            let localBaseline = leftMean + (rightMean - leftMean) * fraction
            correction[index] -= localBaseline
        }
    }

    private static func forceZeroAtBoundaries(_ correction: inout [Double]) {
        guard correction.count > 1 else { return }
        let start = correction.first ?? 0
        let end = correction.last ?? 0
        let denominator = Double(max(correction.count - 1, 1))

        for index in correction.indices {
            let fraction = Double(index) / denominator
            correction[index] -= start + (end - start) * fraction
        }
    }

    private static func mean<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        var total = 0.0
        var count = 0.0
        for value in values {
            total += value
            count += 1
        }
        return count > 0 ? total / count : 0
    }

    // MARK: - PCA helpers

    private static func principalComponents(from residuals: [[Double]], maximumCount: Int) -> [[Double]] {
        guard let sampleCount = residuals.first?.count,
              residuals.count > 1,
              residuals.allSatisfy({ $0.count == sampleCount }),
              maximumCount > 0 else {
            return []
        }

        var gram = Array(repeating: [Double](repeating: 0, count: residuals.count), count: residuals.count)
        for row in residuals.indices {
            for column in row..<residuals.count {
                let value = LinearAlgebra.dot(residuals[row], residuals[column])
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        let eigen = LinearAlgebra.symmetricEigenDecomposition(gram)
        guard eigen.values.count == residuals.count,
              eigen.vectors.count == residuals.count else {
            return []
        }

        let ordered = eigen.values.indices.sorted { eigen.values[$0] > eigen.values[$1] }
        var components: [[Double]] = []
        for component in ordered.prefix(maximumCount) {
            let eigenvalue = eigen.values[component]
            guard eigenvalue > 1e-9 else { continue }

            var vector = [Double](repeating: 0, count: sampleCount)
            for residualIndex in residuals.indices {
                let weight = eigen.vectors[residualIndex][component]
                for sample in 0..<sampleCount {
                    vector[sample] += weight * residuals[residualIndex][sample]
                }
            }

            let scale = sqrt(eigenvalue)
            if scale > 1e-12 {
                for sample in vector.indices {
                    vector[sample] /= scale
                }
            }
            let normalized = centeredUnitVector(vector)
            if !normalized.isEmpty {
                components.append(normalized)
            }
        }
        return components
    }

    private static func principalComponentEigenvalues(from residuals: [[Double]], maximumCount: Int) -> [Double] {
        guard let sampleCount = residuals.first?.count,
              sampleCount > 0,
              residuals.count > 1,
              residuals.allSatisfy({ $0.count == sampleCount }),
              maximumCount > 0 else {
            return []
        }

        var gram = Array(repeating: [Double](repeating: 0, count: residuals.count), count: residuals.count)
        for row in residuals.indices {
            for column in row..<residuals.count {
                let value = LinearAlgebra.dot(residuals[row], residuals[column])
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        return principalComponentEigenvalues(fromGram: gram, maximumCount: maximumCount)
    }

    private static func principalComponentEigenvalues(fromGram gram: [[Double]], maximumCount: Int) -> [Double] {
        guard maximumCount > 0,
              !gram.isEmpty,
              gram.allSatisfy({ $0.count == gram.count }) else {
            return []
        }

        let eigen = LinearAlgebra.symmetricEigenDecomposition(gram)
        guard eigen.values.count == gram.count else { return [] }

        return eigen.values
            .filter { $0 > 1e-12 }
            .sorted(by: >)
            .prefix(maximumCount)
            .map { $0 }
    }

    private static func spatialCovariance(
        data: [[Float]],
        ranges: [Range<Int>],
        channels: [Int]
    ) -> [[Double]] {
        var covariance = Array(repeating: [Double](repeating: 0, count: channels.count), count: channels.count)
        var sampleTotal = 0.0

        for range in ranges {
            let stride = max(range.count / 16, 1)
            var sample = range.lowerBound
            while sample < range.upperBound {
                var values = channels.map { Double(data[$0][sample]) }
                let mean = values.reduce(0, +) / Double(max(values.count, 1))
                for index in values.indices {
                    values[index] -= mean
                }

                for row in channels.indices {
                    for column in row..<channels.count {
                        let value = values[row] * values[column]
                        covariance[row][column] += value
                        if row != column {
                            covariance[column][row] += value
                        }
                    }
                }
                sampleTotal += 1
                sample += stride
            }
        }

        guard sampleTotal > 0 else { return covariance }
        for row in covariance.indices {
            for column in covariance[row].indices {
                covariance[row][column] /= sampleTotal
            }
        }
        return covariance
    }

    // MARK: - Small linear algebra

    private static func meanWindow(_ windows: [[Float]]) -> [Float] {
        guard let count = windows.first?.count, count > 0 else { return [] }
        var mean = [Float](repeating: 0, count: count)
        for window in windows where window.count == count {
            for sample in 0..<count {
                mean[sample] += window[sample]
            }
        }
        let divisor = Float(max(windows.count, 1))
        for sample in mean.indices {
            mean[sample] /= divisor
        }
        return mean
    }

    private static func centeredVector(_ samples: [Float]) -> [Double] {
        centeredVector(samples.map(Double.init))
    }

    private static func centeredVector(_ samples: [Double]) -> [Double] {
        guard !samples.isEmpty else { return [] }
        let mean = samples.reduce(0, +) / Double(samples.count)
        return samples.map { $0 - mean }
    }

    private static func centeredUnitVector(_ samples: [Float]) -> [Double] {
        centeredUnitVector(samples.map(Double.init))
    }

    private static func centeredUnitVector(_ samples: [Double]) -> [Double] {
        var centered = centeredVector(samples)
        let norm = sqrt(SignalStatistics.vectorEnergy(centered))
        guard norm > 1e-12 else { return [] }
        for index in centered.indices {
            centered[index] /= norm
        }
        return centered
    }

    private static func normalizedSpatial(_ values: [Double]) -> [Double] {
        centeredUnitVector(values)
    }

}

nonisolated private struct OBSCorrection {
    var weightedValues: [Double]
    var weights: [Double]

    func scaled(by scale: Double) -> OBSCorrection {
        guard abs(scale - 1) > 1e-12 else { return self }
        return OBSCorrection(
            weightedValues: weightedValues.map { $0 * scale },
            weights: weights
        )
    }
}

nonisolated private struct OBSChannelBasis: Sendable {
    var channel: Int
    var basis: [[Double]]
}

nonisolated private struct OBSVarianceContribution: Sendable {
    var gram: [[Double]]
}

nonisolated private final class OBSCorrectionAccumulator {
    private var weightedValues: [Double]
    private var weights: [Double]

    init(sampleCount: Int) {
        weightedValues = [Double](repeating: 0, count: sampleCount)
        weights = [Double](repeating: 0, count: sampleCount)
    }

    func add(_ correction: OBSCorrection, in range: Range<Int>) {
        guard correction.weightedValues.count == range.count,
              correction.weights.count == range.count,
              range.upperBound <= weightedValues.count else {
            return
        }

        for offset in 0..<range.count {
            let sample = range.lowerBound + offset
            weightedValues[sample] += correction.weightedValues[offset]
            weights[sample] += correction.weights[offset]
        }
    }

    func apply(to channel: inout [Float]) {
        let count = min(channel.count, weightedValues.count)
        for sample in 0..<count where weights[sample] > 0 {
            let divisor = max(weights[sample], 1)
            channel[sample] -= Float(weightedValues[sample] / divisor)
        }
    }
}
