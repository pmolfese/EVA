//
//  EpochingViewModel.swift
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
//  L4 store for the PSA epoching / averaging domain and the averaged-data
//  display state (butterfly, overlaid categories, noise band), extracted from
//  WaveformView (REFACTOR.md slice 4). State-ownership extraction: the store
//  holds the epoching parameters, rejection settings, results, and display
//  toggles; WaveformView still drives the epoching orchestration.
//

import SwiftUI

@MainActor
@Observable
final class EpochingViewModel {
    enum AveragedDisplayMode: String, CaseIterable, Identifiable {
        case waveform = "Waveform"
        case averages = "Averages"
        case trials = "Trials"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .waveform: return "waveform.path.ecg"
            case .averages: return "chart.xyaxis.line"
            case .trials: return "waveform.path.ecg.rectangle"
            }
        }
    }

    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Sheet / selection
    var showsSheet = false
    var segmentField = PSASegmentField.code
    var eventSearchText = ""
    var selectedEventCodes = Set<String>()

    // MARK: Epoch window (portable → eva.xml)
    var preStimulus = 0.2
    var postStimulus = 0.8
    var offset = 0.0
    var baselineCorrected = true
    var averageReference = true
    var averageOnApply = false

    // MARK: Category naming / timing markers
    var categoryNames = [String: String]()
    /// Named groups that pool several event codes into one shared category for
    /// averaging, IN ADDITION to each code's own category (not instead of it) —
    /// e.g. "face" = {happy, sad, angry} produces segments for "face" as well as
    /// segments for "happy"/"sad"/"angry" individually. Value = member codes.
    var categoryGroups = [String: Set<String>]()
    var timingMarkerEnabledValues = Set<String>()
    var timingMarkerValuesBySegmentValue = [String: String]()
    var timingTolerance = 0.5

    // MARK: Artifact rejection
    var skipIfContainsArtifact = false
    var skipEyeBlinks = true
    var skipEyeMovements = true
    var skippedDefinedArtifactIDs = Set<DefinedArtifact.ID>()
    var knownArtifactIDsForRejection = Set<DefinedArtifact.ID>()
    /// Excludes segments the user manually marked "Bad" (Segment Health
    /// right-click / popover) from category averages. Independent of
    /// `skipIfContainsArtifact` — this is a manual call, not detector-driven.
    var skipIfLabeledBad = true

    // MARK: Per-epoch bad-channel interpolation
    /// Detects and interpolates channels that are only bad WITHIN a given
    /// epoch (transient per-trial artifacts a whole-recording health scan
    /// misses), instead of rejecting the whole epoch or leaving it uncorrected.
    var interpolatesBadChannelsPerEpoch = true
    var epochBadChannelThresholds = EpochBadChannelThresholds()
    var showsEpochBadChannelOptions = false
    /// When a channel is flagged bad in at least this fraction of epochs, mark
    /// it bad for the whole recording and interpolate it there instead of
    /// leaving it as a per-epoch-only correction.
    var escalatesBadChannelsToGlobal = true
    var escalationThresholdPercent = 50.0
    /// One line per channel escalated by the last Apply, e.g. "Ch12: bad in
    /// 62% of epochs (31/50)" — surfaced in the status message and folded into
    /// the exported process log via `currentProcessingAuditLogLines()`.
    var escalatedChannelSummaries: [String] = []
    /// One line per channel flagged bad in at least one epoch by the last
    /// Apply, e.g. "Ch12 (14 of 120 epochs)" — including channels that never
    /// crossed the escalation threshold. Surfaced in the status message and
    /// folded into the exported process log via `currentProcessingAuditLogLines()`.
    var epochBadChannelSummary: [String] = []
    /// Channels flagged bad in every accepted segment from the last PSA run.
    var epochBadChannelAllSegmentsSummary: [String] = []
    /// One line per channel showing the accepted segment numbers where it was
    /// interpolated, e.g. "Ch1(4,5,6)".
    var interpolatedChannelsBySegmentSummary: [String] = []
    /// Segments omitted from averaging because the user manually labeled them bad.
    var skippedLabeledBadSegmentsSummary: [String] = []

    // MARK: Run state
    var statusMessage: String?
    var isApplying = false
    var phaseMessage: String?
    /// Fraction complete (0...1) while segmenting; nil for indeterminate
    /// phases (e.g. averaging), which fall back to a spinner.
    var segmentingProgress: Double?

    // MARK: Results
    var epochedSignal: MFFSignalData?
    var epochSegments: [EpochSegment] = []
    var isAveraged = false

    // MARK: Averaged-data display
    var showsButterflyPlot = false
    var showsNoiseBand = true
    var showsOverlaidCategories = false
    var butterflyTopomapRelativeSample: Int?
    var averagedDisplayMode: AveragedDisplayMode = .waveform
    var showsAveragesButterfly = true
    var showsAveragesTopography = true
    var showsAveragesInspector = true
    var showsAveragesLog = true
    var psaExclusionSummary = PSAExclusionSummary()

    // MARK: Figure labeling (session-only; never mutates EpochSegment.category)
    /// Category → user-facing display name, for publication figures/legends.
    var categoryRenames = [String: String]()

    /// The display label for a category, honoring any session rename.
    func displayCategory(_ category: String) -> String {
        let renamed = categoryRenames[category]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (renamed?.isEmpty == false) ? renamed! : category
    }

    // MARK: Topomap color scale (Cmd-hold control in the topography pane)
    enum TopomapScaleMode: String, CaseIterable, Identifiable { case microvolts = "µV", zScore = "Z"; var id: String { rawValue } }
    var topomapScaleMode: TopomapScaleMode = .microvolts

    /// µV mode: when true, topomaps use the manual min/max below instead of the
    /// auto symmetric ±scale. Tightening the range intensifies the colors.
    var topomapScaleManual = false
    var topomapScaleMin = -5.0
    var topomapScaleMax = 5.0
    /// Lock min = −max so the scale stays symmetric about 0.
    var topomapSymmetric = true

    /// Z-score mode: color scale spans ±`topomapZSigma` SD about the mean. Mean/SD
    /// auto-compute from the displayed maps unless the user overrides them.
    var topomapZSigma = 2.0
    var topomapZMean = 0.0
    var topomapZSD = 1.0
    var topomapZManual = false

    // MARK: Multi-condition overlay (figure building)
    /// Categories chosen for overlay. Empty == all (so no seeding is needed).
    var overlaySelectedCategories: Set<String> = []
    /// Butterfly panel: overlay selected conditions on shared axes vs. stacked.
    var showsOverlayButterfly = false

    /// Effective overlay selection over the currently-available categories
    /// (empty selection resolves to "all").
    func overlayCategories(available: [String]) -> Set<String> {
        overlaySelectedCategories.isEmpty ? Set(available) : overlaySelectedCategories.intersection(available)
    }

    func isOverlaySelected(_ category: String, available: [String]) -> Bool {
        overlayCategories(available: available).contains(category)
    }

    func toggleOverlayCategory(_ category: String, available: [String]) {
        var current = overlayCategories(available: available) // resolves "all" first
        if current.contains(category) { current.remove(category) } else { current.insert(category) }
        // Keep at least one selected.
        if current.isEmpty { current = [category] }
        overlaySelectedCategories = current
    }

    var parameters: [String: String] {
        var p: [String: String] = [
            "preStimulusMs": String(format: "%.0f", preStimulus * 1000),
            "postStimulusMs": String(format: "%.0f", postStimulus * 1000),
            "offsetMs": String(format: "%.0f", offset * 1000),
            "baselineCorrected": "\(baselineCorrected)",
            "averageReference": "\(averageReference)",
            "average": "\(averageOnApply)",
            "skipEyeBlinks": "\(skipEyeBlinks)",
            "skipEyeMovements": "\(skipEyeMovements)",
            "skipArtifacts": "\(skipIfContainsArtifact)",
            "skipLabeledBad": "\(skipIfLabeledBad)",
            "interpolateBadChannelsPerEpoch": "\(interpolatesBadChannelsPerEpoch)"
        ]
        if interpolatesBadChannelsPerEpoch {
            p.merge(epochBadChannelThresholds.flatParameters(prefix: "badChannel")) { current, _ in current }
            p["badChannel.escalateToGlobal"] = "\(escalatesBadChannelsToGlobal)"
            p["badChannel.globalEscalationThresholdPercent"] = String(format: "%.0f", escalationThresholdPercent)
        }
        if !selectedEventCodes.isEmpty {
            p["eventCodes"] = selectedEventCodes.sorted().joined(separator: ",")
        }
        // Only non-default category names (a code defaults to itself) need carrying.
        for code in selectedEventCodes where (categoryNames[code].map { $0 != code } ?? false) {
            p["category.\(code)"] = categoryNames[code]!
        }
        // DIN (timing marker) adjustment: which segment values use it, and which
        // marker code each one pairs with. Only emitted when at least one is on,
        // matching the "only non-default state" convention above.
        let enabledWithMarker = timingMarkerEnabledValues
            .compactMap { value -> (String, String)? in
                guard let marker = timingMarkerValuesBySegmentValue[value] else { return nil }
                return (value, marker)
            }
        if !enabledWithMarker.isEmpty {
            p["timingTolerance"] = String(format: "%.3f", timingTolerance)
            for (value, marker) in enabledWithMarker {
                p["din.\(value)"] = marker
            }
        }
        return p
    }

    /// Deserialization inverse of `parameters` for Copy Processing / replay.
    /// Event codes are portable when the target recording has the same codes;
    /// DIN pairings are portable when the target also has the paired marker
    /// code's events (`makeBuildJob` already validates that at apply time).
    func apply(parameters p: [String: String]) {
        if let v = p["preStimulusMs"].flatMap(Double.init) { preStimulus = v / 1000 }
        if let v = p["postStimulusMs"].flatMap(Double.init) { postStimulus = v / 1000 }
        if let v = p["offsetMs"].flatMap(Double.init) { offset = v / 1000 }
        if let v = p["baselineCorrected"] { baselineCorrected = (v == "true") }
        if let v = p["averageReference"] { averageReference = (v == "true") }
        if let v = p["average"] { averageOnApply = (v == "true") }
        if let v = p["skipEyeBlinks"] { skipEyeBlinks = (v == "true") }
        if let v = p["skipEyeMovements"] { skipEyeMovements = (v == "true") }
        if let v = p["skipArtifacts"] { skipIfContainsArtifact = (v == "true") }
        if let v = p["skipLabeledBad"] { skipIfLabeledBad = (v == "true") }
        if let v = p["interpolateBadChannelsPerEpoch"] { interpolatesBadChannelsPerEpoch = (v == "true") }
        epochBadChannelThresholds = EpochBadChannelThresholds.fromFlatParameters(
            p,
            prefix: "badChannel",
            base: epochBadChannelThresholds
        )
        if let v = p["badChannel.escalateToGlobal"] { escalatesBadChannelsToGlobal = (v == "true") }
        if let v = p["badChannel.globalEscalationThresholdPercent"].flatMap(Double.init) {
            escalationThresholdPercent = v
        }
        if let codes = p["eventCodes"] {
            selectedEventCodes = Set(codes.split(separator: ",").map(String.init))
        }
        for (key, value) in p where key.hasPrefix("category.") {
            categoryNames[String(key.dropFirst("category.".count))] = value
        }
        if let v = p["timingTolerance"].flatMap(Double.init) { timingTolerance = v }
        var dinEnabled = Set<String>()
        var dinValues = [String: String]()
        for (key, value) in p where key.hasPrefix("din.") {
            let segmentValue = String(key.dropFirst("din.".count))
            dinEnabled.insert(segmentValue)
            dinValues[segmentValue] = value
        }
        if !dinEnabled.isEmpty {
            timingMarkerEnabledValues = dinEnabled
            timingMarkerValuesBySegmentValue = dinValues
        }
    }

    // MARK: - PSA build job + apply (headless-capable)

    /// This VM's own event-code/label projection for segmenting, matching
    /// `WaveformView.psaSegmentValue(for:)`. `.artifact` mode also resolves to
    /// the event code — callers segmenting on artifacts pass artifact-detection
    /// events in as `events` already, so no WaveformView-only artifact lookup
    /// is needed here.
    func segmentValue(for event: MFFEvent) -> String {
        switch segmentField {
        case .code, .artifact: return event.code
        case .label: return event.label ?? event.code
        }
    }

    private func selectedCategoriesByCode() -> [String: [String]]? {
        var categoriesByCode = [String: [String]]()
        for code in selectedEventCodes {
            let category = (categoryNames[code] ?? code).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { return nil }
            categoriesByCode[code] = [category]
        }
        for (groupName, members) in categoryGroups {
            let category = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { continue }
            for member in members where selectedEventCodes.contains(member) {
                categoriesByCode[member, default: []].append(category)
            }
        }
        return categoriesByCode
    }

    private func selectedTimingMarkersBySegmentValue(events: [MFFEvent]) -> [String: String]? {
        let availableValues = Set(events.map(segmentValue(for:)))
        var timingMarkersBySegmentValue = [String: String]()
        for value in selectedEventCodes where timingMarkerEnabledValues.contains(value) {
            guard let timingValue = timingMarkerValuesBySegmentValue[value],
                  availableValues.contains(timingValue), timingValue != value else {
                return nil
            }
            timingMarkersBySegmentValue[value] = timingValue
        }
        return timingMarkersBySegmentValue
    }

    private static func colorIndices(for categories: [String]) -> [String: Int] {
        let uniqueCategories = Array(Set(categories)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: uniqueCategories.enumerated().map { index, category in
            (category, index)
        })
    }

    /// Builds a `PSABuildJob` from this VM's configuration + `allEvents`
    /// (already resolved to whatever `segmentField` needs — e.g. the caller
    /// supplies artifact-detection events when segmenting on `.artifact`).
    /// Headless-capable: unlike `WaveformView.psaBuildJob(from:)`, this
    /// doesn't read `template.definedArtifacts`/`electrodeGeometry`/
    /// SwiftData markers off the view — those are passed in (or default to
    /// empty/off, which degrades gracefully: no defined-artifact rejection,
    /// no per-epoch-interpolation donor positions).
    func makeBuildJob(
        from signal: MFFSignalData,
        events allEvents: [MFFEvent],
        artifactRejectionEvents: [MFFEvent] = [],
        electrodePositions: [Int: SIMD3<Double>] = [:],
        globallyBadChannels: Set<Int> = []
    ) -> PSABuildJob? {
        guard let categoriesBySegmentValue = selectedCategoriesByCode() else {
            statusMessage = "Enter a category name for each selected event."
            return nil
        }
        let sortedEvents = allEvents.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        guard let timingMarkersBySegmentValue = selectedTimingMarkersBySegmentValue(events: sortedEvents) else {
            statusMessage = "Choose a timing marker for each DIN-adjusted event."
            return nil
        }
        let timingEventsBySegmentValue = Dictionary(grouping: sortedEvents, by: segmentValue(for:))
        for (segValue, timingValue) in timingMarkersBySegmentValue {
            guard timingEventsBySegmentValue[timingValue]?.isEmpty == false else {
                statusMessage = "No \(timingValue) timing markers found for \(segValue)."
                return nil
            }
        }
        let events = sortedEvents.filter { selectedEventCodes.contains(segmentValue(for: $0)) }
        guard !events.isEmpty else {
            statusMessage = segmentField == .artifact
                ? "Select at least one artifact type."
                : "Select at least one event \(segmentField.rawValue.lowercased())."
            return nil
        }
        guard signal.samplingRate > 0, let sampleCount = signal.data.first?.count, sampleCount > 0 else {
            statusMessage = "This signal has no readable samples."
            return nil
        }
        let preSamples = max(Int((preStimulus * signal.samplingRate).rounded()), 0)
        let epochLength = max(Int(((preStimulus + postStimulus) * signal.samplingRate).rounded()), 1)
        guard epochLength > 0 else {
            statusMessage = "Epoch duration must be greater than zero."
            return nil
        }
        let skipArtifacts = skipIfContainsArtifact && segmentField != .artifact
        return PSABuildJob(
            signal: signal,
            events: events,
            categoriesBySegmentValue: categoriesBySegmentValue,
            timingMarkersBySegmentValue: timingMarkersBySegmentValue,
            timingEventsBySegmentValue: timingEventsBySegmentValue,
            artifactEventsForRejection: skipArtifacts ? artifactRejectionEvents : [],
            artifactEventsForRejectionByLabel: skipArtifacts && !artifactRejectionEvents.isEmpty ? ["artifacts": artifactRejectionEvents] : [:],
            preSamples: preSamples,
            epochLength: epochLength,
            psaOffset: offset,
            sampleCount: sampleCount,
            colorIndices: Self.colorIndices(for: categoriesBySegmentValue.values.flatMap { $0 }),
            skipIfContainsArtifact: skipArtifacts,
            artifactRejectionLabel: "artifacts",
            timingTolerance: timingTolerance,
            interpolatesBadChannelsPerEpoch: interpolatesBadChannelsPerEpoch,
            epochBadChannelThresholds: epochBadChannelThresholds,
            electrodePositions: electrodePositions,
            globallyBadChannels: globallyBadChannels
        )
    }

    /// Headless build → (average) → post-process for `job`, writing results
    /// into this VM. Returns the final signal, or `nil` if nothing survived.
    ///
    /// Unlike `WaveformView.applyPSACore`, this has no `recordingSessionID`
    /// staleness guard (safe — it only ever writes to `self`; see
    /// `GradientViewModel.apply` for why a one-shot headless caller doesn't
    /// need one), doesn't cache the raw pre-average epochs for later
    /// re-toggling (`segmentedEpochSignal`/`segmentedEpochSegments` are a
    /// `WaveformView`-only *display* cache), and doesn't escalate per-epoch
    /// bad channels to globally-bad + interpolate (that reaches into
    /// `WaveformView.interpolate(_:in:)`, which needs live electrode geometry
    /// and updates view-only status text — a live-view-only feature, not
    /// meaningful for a one-shot headless run).
    func applyBuildJob(
        _ job: PSABuildJob,
        averageReference: Bool,
        baselineCorrect: Bool,
        badChannels: Set<Int>
    ) async -> MFFSignalData? {
        isApplying = true
        phaseMessage = "Segmenting…"
        segmentingProgress = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] (update: EpochBuildProgress) in
            self?.phaseMessage = "Segmenting… (\(update.completed) of \(update.total))"
            self?.segmentingProgress = update.fraction
        }
        let buildWorker = Task.detached(priority: .userInitiated) {
            await job.buildEpochs { completed, total in
                progressContinuation.yield(EpochBuildProgress(completed: completed, total: total))
            }
        }
        let built = await withTaskCancellationHandler(
            operation: { await buildWorker.value },
            onCancel: { buildWorker.cancel() }
        )
        progressContinuation.finish()
        progressTask.cancel()
        segmentingProgress = nil

        guard !Task.isCancelled else {
            isApplying = false
            phaseMessage = nil
            return nil
        }
        guard let built else {
            isApplying = false
            phaseMessage = nil
            statusMessage = "No trials survived PSA segmentation. All candidate epochs were rejected, skipped, or out of bounds."
            return nil
        }

        var exclusionSummary = built.exclusionSummary
        let epochBadChannelCounts = built.epochBadChannelCounts
        let totalEpochsEvaluated = built.totalEpochsEvaluated

        let finalResult: PSABuildResult
        let wasAveraged: Bool
        if averageOnApply {
            phaseMessage = "Averaging…"
            let colorIndices = Self.colorIndices(for: built.segments.map(\.category))
            let averageWorker = Task.detached(priority: .userInitiated) {
                built.average(colorIndices: colorIndices)
            }
            let averagedOpt = await withTaskCancellationHandler(
                operation: { await averageWorker.value },
                onCancel: { averageWorker.cancel() }
            )
            guard !Task.isCancelled, let averaged = averagedOpt else {
                isApplying = false
                phaseMessage = nil
                statusMessage = "No averages could be computed."
                return nil
            }
            phaseMessage = "Post-processing…"
            let postWorker = Task.detached(priority: .userInitiated) {
                averaged.postProcessed(averageReference: averageReference, baselineCorrect: baselineCorrect, badChannels: badChannels)
            }
            finalResult = await withTaskCancellationHandler(
                operation: { await postWorker.value },
                onCancel: { postWorker.cancel() }
            )
            wasAveraged = true
        } else {
            phaseMessage = "Post-processing…"
            let postWorker = Task.detached(priority: .userInitiated) {
                built.postProcessed(averageReference: averageReference, baselineCorrect: baselineCorrect, badChannels: badChannels)
            }
            finalResult = await withTaskCancellationHandler(
                operation: { await postWorker.value },
                onCancel: { postWorker.cancel() }
            )
            wasAveraged = false
        }

        guard !Task.isCancelled else {
            isApplying = false
            phaseMessage = nil
            return nil
        }
        epochedSignal = finalResult.signal
        epochSegments = finalResult.segments
        isAveraged = wasAveraged
        exclusionSummary.outputSegments = finalResult.segments.count
        exclusionSummary.badChannelCount = epochBadChannelCounts.count
        psaExclusionSummary = exclusionSummary
        if wasAveraged {
            showsButterflyPlot = true
        } else {
            showsButterflyPlot = false
            averagedDisplayMode = .waveform
        }

        var parts: [String] = []
        if averageReference { parts.append("avg ref") }
        if baselineCorrect { parts.append("baseline corrected") }
        var statusText = finalResult.message + (parts.isEmpty ? "" : " · " + parts.joined(separator: ", "))
        epochBadChannelSummary = []
        if interpolatesBadChannelsPerEpoch, totalEpochsEvaluated > 0, !epochBadChannelCounts.isEmpty {
            let segmentBadChannels = epochBadChannelCounts.keys.sorted().map { "Ch\($0 + 1)" }
            epochBadChannelSummary = epochBadChannelCounts.keys.sorted().map {
                "Ch\($0 + 1) (\(epochBadChannelCounts[$0] ?? 0) of \(totalEpochsEvaluated) epochs)"
            }
            statusText += " · \(epochBadChannelCounts.count) channel\(epochBadChannelCounts.count == 1 ? "" : "s") bad in \u{2265}1 epoch (\(segmentBadChannels.joined(separator: ", ")))"
            if built.rejectedForTooManyBadChannels > 0 {
                statusText += " · \(built.rejectedForTooManyBadChannels) epoch\(built.rejectedForTooManyBadChannels == 1 ? "" : "s") rejected for too many bad channels"
            }
        }
        statusMessage = statusText
        isApplying = false
        phaseMessage = nil
        return finalResult.signal
    }

    func resetForClose() {
        showsSheet = false
        eventSearchText = ""
        selectedEventCodes.removeAll()
        categoryNames.removeAll()
        categoryGroups.removeAll()
        timingMarkerEnabledValues.removeAll()
        timingMarkerValuesBySegmentValue.removeAll()
        skippedDefinedArtifactIDs.removeAll()
        knownArtifactIDsForRejection.removeAll()
        escalatedChannelSummaries.removeAll()
        epochBadChannelSummary.removeAll()
        epochBadChannelAllSegmentsSummary.removeAll()
        interpolatedChannelsBySegmentSummary.removeAll()
        skippedLabeledBadSegmentsSummary.removeAll()
        statusMessage = nil
        isApplying = false
        phaseMessage = nil
        epochedSignal = nil
        epochSegments = []
        isAveraged = false
        showsButterflyPlot = false
        showsOverlaidCategories = false
        butterflyTopomapRelativeSample = nil
        averagedDisplayMode = .waveform
        showsAveragesButterfly = true
        showsAveragesTopography = true
        showsAveragesInspector = true
        showsAveragesLog = true
        psaExclusionSummary = PSAExclusionSummary()
        categoryRenames.removeAll()
        overlaySelectedCategories.removeAll()
        showsOverlayButterfly = false
        topomapScaleMode = .microvolts
        topomapScaleManual = false
        topomapSymmetric = true
        topomapZManual = false
        topomapZSigma = 2.0
    }
}
