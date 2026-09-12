//
//  RhythmicityExplorerViewModel.swift
//  EVA
//
//  Recording-scoped orchestration for the LAVI/ABBA Bands workspace.
//

import Foundation

enum RhythmicityExplorerMode: String, CaseIterable, Identifiable, Sendable {
    case bands = "Bands"
    case eventRelated = "Event-related"
    case bursts = "Bursts"

    var id: String { rawValue }
}

enum WTPLDisplayMeasure: String, CaseIterable, Identifiable, Sendable {
    case raw = "Raw WTPL"
    case delta = "ΔWTPL"
    case validCounts = "Valid counts"
    var id: String { rawValue }
}

enum RhythmicBurstBackground: String, CaseIterable, Identifiable, Sendable {
    case power = "Power / P90"
    case wtpl = "WTPL"
    var id: String { rawValue }
}

private struct RhythmicityContextSignature: Sendable, Equatable {
    var signalRevision: UUID
    var configuration: RhythmicityConfiguration
    var dataSelection: RhythmicityDataSelection
    var channelScope: RhythmicityChannelScope
    var selectedChannelIndex: Int
    var selectedChannelSetID: UUID?
    var selectedSetChannels: [Int]
    var visibleRange: ClosedRange<Int>?
    var selectedRange: ClosedRange<Int>?
    var badChannels: [Int]
    var hiddenChannels: [Int]
    var interpolationRevision: Int
    var artifactSignature: String
    var includesMarkedArtifacts: Bool
}

private struct RhythmicityRunSnapshot: Sendable {
    var signal: MFFSignalData
    var configuration: RhythmicityConfiguration
    var source: RhythmicitySourceDescriptor
    var provenance: RhythmicityProcessingProvenance
    var selection: RhythmicitySelectionDescriptor
    var significanceCache: LAVISignificanceCacheStore
}

private struct WTPLContextSignature: Sendable, Equatable {
    var signalRevision: UUID
    var segmentSignature: String
    var channelIndices: [Int]
    var conditionA: String
    var conditionB: String?
    var frequenciesHz: [Double]
    var nCycles: [Double]
    var lagCycles: [Double]
    var baselineStartMs: Double
    var baselineEndMs: Double
}

private struct WTPLRunSnapshot: Sendable {
    var signal: MFFSignalData
    var segments: [EpochSegment]
    var conditions: [String]
    var channelIndices: [Int]
    var plan: TFFrequencyPlan
    var lagCycles: [Double]
    var baselineStartMs: Double
    var baselineEndMs: Double
    var source: RhythmicitySourceDescriptor
    var provenance: RhythmicityProcessingProvenance
}

private struct RhythmicBurstContextSignature: Sendable, Equatable {
    var selection: RhythmicityContextSignature
    var configuration: RhythmicBurstConfiguration
    var bandSource: TimeFrequencyBandSource
    var bandSignature: String
}

private enum RhythmicityExplorerError: LocalizedError {
    case emptySignal
    case missingRange(String)
    case emptyRange
    case noEligibleChannels
    case missingChannelSet
    case noEpochs
    case noConditions
    case invalidWTPLComparison
    case invalidWTPLConfiguration

    var errorDescription: String? {
        switch self {
        case .emptySignal: return "The processed signal contains no readable samples."
        case let .missingRange(name): return "No \(name) is available. Choose another data selection."
        case .emptyRange: return "The selected interval contains no samples."
        case .noEligibleChannels: return "No channels are eligible under the current channel scope."
        case .missingChannelSet: return "Choose a channel set before running the analysis."
        case .noEpochs: return "Event-related WTPL requires retained epochs/trials."
        case .noConditions: return "Choose at least one epoch condition for WTPL."
        case .invalidWTPLComparison: return "Choose two different epoch conditions for an A − B WTPL comparison."
        case .invalidWTPLConfiguration: return "WTPL frequency or baseline settings are invalid."
        }
    }
}

@MainActor
@Observable
final class RhythmicityExplorerViewModel {
    let store: RecordingStore
    @ObservationIgnored private let persistenceStore: RhythmicityPersistenceStore

    init(
        store: RecordingStore,
        persistenceStore: RhythmicityPersistenceStore = RhythmicityPersistenceStore()
    ) {
        self.store = store
        self.persistenceStore = persistenceStore
        self.configuration = Self.preferredPaperConfiguration(includesSignificance: true)
    }

    var showsSheet = false
    var mode = RhythmicityExplorerMode.bands
    var source = RhythmicitySignalSource.processed
    var configuration: RhythmicityConfiguration {
        didSet { updateStaleState(); updateWTPLStaleState(); updateBurstStaleState() }
    }
    var dataSelection = RhythmicityDataSelection.entireProcessedRecording {
        didSet { updateStaleState(); updateBurstStaleState() }
    }
    var channelScope = RhythmicityChannelScope.current {
        didSet { updateStaleState(); updateWTPLStaleState(); updateBurstStaleState() }
    }
    var selectedChannelIndex = 0 {
        didSet { updateStaleState(); updateWTPLStaleState(); updateBurstStaleState() }
    }
    var selectedChannelSetID: UUID? {
        didSet { updateStaleState(); updateWTPLStaleState(); updateBurstStaleState() }
    }
    var includesSignificance = true
    var includesMarkedArtifacts = false { didSet { updateStaleState(); updateBurstStaleState() } }

    var isRunning = false
    var progress = 0.0
    var statusTitle = "Ready"
    var statusDetail = "Choose a data range and channels, then run LAVI/ABBA."
    var log: [RhythmicityLogLine] = []
    var runGeneration = 0

    var laviResult: LAVIAnalysisResult?
    var resultSelection: RhythmicitySelectionDescriptor?
    var selectedBandID: ABBABand.ID?
    var resultIsStale = false
    var exportStatus: String?
    var detectedBandSetForTimeFrequency: DetectedRhythmicityBandSet?
    var detectedBandSetForTimeFrequencyIsStale = false
    var timeFrequencyPublishStatus: String?
    var persistedResultStatus: String?

    // MARK: Event-related WTPL
    var wtplResult: WTPLAnalysisResult?
    var wtplResultIsStale = false
    var wtplDisplayMeasure = WTPLDisplayMeasure.delta
    var wtplConditionA = "" {
        didSet {
            if wtplConditionB == wtplConditionA {
                let categories = Array(Set(currentEpochSegments.map(\.category))).sorted()
                wtplConditionB = categories.first(where: { $0 != wtplConditionA })
            }
            updateWTPLStaleState()
        }
    }
    var wtplConditionB: String? { didSet { updateWTPLStaleState() } }
    var wtplShowsDifference = false { didSet { updateWTPLStaleState() } }
    var wtplMinFrequencyHz = 3.16 { didSet { updateWTPLStaleState() } }
    var wtplMaxFrequencyHz = 44.67 { didSet { updateWTPLStaleState() } }
    var wtplFrequencyCount = 47 { didSet { updateWTPLStaleState() } }
    var wtplBaselineStartMs = -1_000.0 { didSet { updateWTPLStaleState() } }
    var wtplBaselineEndMs = -500.0 { didSet { updateWTPLStaleState() } }
    var wtplBandSource = TimeFrequencyBandSource.evaDefaults

    // MARK: Rhythmic bursts
    var burstResult: RhythmicBurstAnalysisResult?
    var burstResultIsStale = false
    var burstConfiguration = RhythmicBurstConfiguration.paper2026 {
        didSet { updateBurstStaleState() }
    }
    var burstBandSource = TimeFrequencyBandSource.rhythmicityExplorer {
        didSet { updateBurstStaleState() }
    }
    var burstBackground = RhythmicBurstBackground.power
    var selectedBurstID: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancellation: RhythmicityCancellation?
    @ObservationIgnored private var resultSignature: RhythmicityContextSignature?
    @ObservationIgnored private var currentSignalRevision: UUID?
    @ObservationIgnored private var currentSamplingRate = 0.0
    @ObservationIgnored private var currentSampleCount = 0
    @ObservationIgnored private var currentChannelCount = 0
    @ObservationIgnored private var currentVisibleRange: ClosedRange<Int>?
    @ObservationIgnored private var currentSelectedRange: ClosedRange<Int>?
    @ObservationIgnored private var currentChannelSets: [ChannelSet] = []
    @ObservationIgnored private var currentArtifactSources: [EEGArtifactRejectionSource] = []
    @ObservationIgnored private var wtplResultSignature: WTPLContextSignature?
    @ObservationIgnored private var burstResultSignature: RhythmicBurstContextSignature?
    @ObservationIgnored private var currentEventSignal: MFFSignalData?
    @ObservationIgnored private var currentEpochSegments: [EpochSegment] = []
    @ObservationIgnored private var loadedPersistenceRecordingPath: String?
    @ObservationIgnored private var lastLoggedProgressPhase: RhythmicityProgressPhase?
    @ObservationIgnored private var lastLoggedProgressChannel: Int?
    @ObservationIgnored private var lastLoggedSignificanceMilestone = 0
    @ObservationIgnored private var runStartedAt: Date?

    deinit {
        cancellation?.cancel()
        task?.cancel()
    }

    var selectedChannelResult: LAVIChannelResult? {
        guard let result = laviResult else { return nil }
        return result.channels.first { $0.channelIndex == selectedChannelIndex } ?? result.channels.first
    }

    var validity: RhythmicityValidity {
        if resultIsStale { return .stale }
        guard let result = laviResult else {
            return statusTitle == "Cannot run" ? .invalid : .ready
        }
        if result.channels.allSatisfy({ channel in
            channel.validPairCounts.allSatisfy { $0 == 0 }
        }) {
            return .invalid
        }
        guard result.channels.allSatisfy({ $0.significanceRibbon != nil }) else { return .exploratory }
        return result.configuration.presetID == RhythmicityPreset.paperLAVI2026.presetID
            ? .referenceValid : .customSignificance
    }

    var detectedSustainedCount: Int {
        laviResult?.channels.flatMap(\.bands).count { $0.direction == .sustained } ?? 0
    }

    var detectedTransientCount: Int {
        laviResult?.channels.flatMap(\.bands).count { $0.direction == .transient } ?? 0
    }

    var alphaAnchorCount: Int {
        laviResult?.channels.count { channel in
            channel.bands.contains { $0.relativeToAlpha == 0 }
        } ?? 0
    }

    var backendDescription: String {
        switch laviResult?.configuration.backend ?? configuration.backend {
        case .automatic: return "Automatic · Metal when suitable"
        case .metalGPU: return "Metal · Float32"
        case .accelerateFFTCPU: return "Accelerate FFT · Float64"
        case .directReferenceCPU: return "Direct CPU oracle · Float64"
        }
    }

    var runEstimate: String {
        if mode == .eventRelated {
            let conditions = selectedWTPLConditions
            let trials = currentEpochSegments.count { conditions.contains($0.category) }
            return "\(estimatedChannelIndices.count) channel\(estimatedChannelIndices.count == 1 ? "" : "s") × \(trials) trials × \(wtplFrequencyCount) frequencies"
        }
        if mode == .bursts {
            return "\(estimatedChannelIndices.count) channel\(estimatedChannelIndices.count == 1 ? "" : "s") × \(estimatedSelectedSampleCount) samples × \(configuration.frequenciesHz.count) frequencies"
        }
        let channelCount = estimatedChannelIndices.count
        let profileCount = includesSignificance ? 201 : 1
        guard estimatedSelectedSampleCount > 0, channelCount > 0 else { return "Selection is incomplete" }
        return "\(channelCount) channel\(channelCount == 1 ? "" : "s") × \(configuration.frequenciesHz.count) frequencies × \(profileCount) profile\(profileCount == 1 ? "" : "s")"
    }

    var selectedWTPLConditions: [String] {
        var values = [wtplConditionA].filter { !$0.isEmpty }
        if wtplShowsDifference, let b = wtplConditionB, !b.isEmpty, !values.contains(b) { values.append(b) }
        return values
    }

    var selectedWTPLChannelResult: WTPLChannelResult? {
        guard let condition = wtplResult?.conditions.first(where: { $0.condition == wtplConditionA })
            ?? wtplResult?.conditions.first else { return nil }
        return condition.channels.first { $0.channelIndex == selectedChannelIndex } ?? condition.channels.first
    }

    var selectedBurst: RhythmicBurst? {
        guard let result = burstResult else { return nil }
        if let selectedBurstID,
           let selected = result.bursts.first(where: { $0.id == selectedBurstID }) {
            return selected
        }
        return result.bursts.first { $0.channelIndex == selectedChannelIndex }
            ?? result.bursts.first
    }

    var wtplBaselineIsAvailable: Bool {
        guard let signal = currentEventSignal,
              let condition = selectedWTPLConditions.first else { return false }
        let stack = TimeFrequencyTrials.stack(
            signal: signal, segments: currentEpochSegments, category: condition,
            channelIndices: [max(min(selectedChannelIndex, max(signal.data.count - 1, 0)), 0)]
        )
        return Self.baselineSpec(
            startMs: wtplBaselineStartMs, endMs: wtplBaselineEndMs, stack: stack
        ) != nil
    }

    var validityWarnings: [String] {
        var warnings: [String] = []
        let duration = Double(estimatedSelectedSampleCount) / max(currentSamplingRate, 1)
        if configuration.frequenciesHz.first.map({ $0 < 3 }) == true, duration < 180 {
            warnings.append("Below 3 Hz, several minutes of usable data are recommended.")
        }
        if configuration.frequenciesHz.last.map({ $0 > 40 }) == true, currentSamplingRate < 1_000 {
            warnings.append("Above approximately 40–45 Hz, at least 1 kHz sampling is recommended.")
        }
        if duration > 0, duration < 10 {
            warnings.append("This short selection may provide too few valid lag pairs at low frequencies.")
        }
        if !store.channels.bad.isEmpty {
            let count = store.channels.bad.count
            warnings.append("\(count) globally bad channel\(count == 1 ? " is" : "s are") excluded.")
        }
        if includesMarkedArtifacts, !currentArtifactSources.isEmpty {
            warnings.append("Expert override: marked artifact intervals are included.")
        }
        if let result = laviResult {
            warnings.append(contentsOf: result.warnings.map(\.displayText))
            warnings.append(contentsOf: result.channels.flatMap { $0.warnings.map(\.displayText) })
        }
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }

    func setSignificanceEnabled(_ enabled: Bool) {
        guard includesSignificance != enabled else { return }
        includesSignificance = enabled
        configuration = Self.preferredPaperConfiguration(includesSignificance: enabled)
    }

    func synchronizeContext(
        signal: MFFSignalData,
        visibleRange: ClosedRange<Int>?,
        selectedRange: ClosedRange<Int>?,
        channelSets: [ChannelSet],
        artifactSources: [EEGArtifactRejectionSource]
    ) {
        currentSignalRevision = signal.dataRevision
        currentSamplingRate = signal.samplingRate
        currentSampleCount = signal.data.first?.count ?? 0
        currentChannelCount = signal.data.count
        currentVisibleRange = visibleRange
        currentSelectedRange = selectedRange
        currentChannelSets = channelSets
        currentArtifactSources = artifactSources
        if !signal.data.indices.contains(selectedChannelIndex) { selectedChannelIndex = 0 }
        if selectedChannelSetID == nil || !channelSets.contains(where: { $0.id == selectedChannelSetID }) {
            selectedChannelSetID = channelSets.first?.id
        }
        restorePersistedResultIfNeeded(signal: signal)
        updateStaleState()
        updateBurstStaleState()
    }

    func synchronizeEventContext(signal: MFFSignalData, segments: [EpochSegment]) {
        currentEventSignal = signal
        currentEpochSegments = segments
        let categories = Array(Set(segments.map(\.category))).sorted()
        if wtplConditionA.isEmpty || !categories.contains(wtplConditionA) {
            wtplConditionA = categories.first ?? ""
        }
        if wtplConditionB == nil || !categories.contains(wtplConditionB ?? "") || wtplConditionB == wtplConditionA {
            wtplConditionB = categories.first(where: { $0 != wtplConditionA })
        }
        updateWTPLStaleState()
    }

    private func restorePersistedResultIfNeeded(signal: MFFSignalData) {
        let path = signal.signalURL.standardizedFileURL.path
        guard loadedPersistenceRecordingPath != path else { return }
        loadedPersistenceRecordingPath = path
        do {
            guard let persisted = try persistenceStore.load(
                recordingURL: signal.signalURL,
                currentSourceRevision: signal.dataRevision.uuidString
            ) else { return }
            laviResult = persisted.result
            resultSelection = persisted.selection
            configuration = persisted.result.configuration
            includesSignificance = persisted.result.channels.allSatisfy { $0.significanceRibbon != nil }
            source = persisted.selection.source
            dataSelection = persisted.selection.dataSelection
            channelScope = persisted.selection.channelScope
            includesMarkedArtifacts = persisted.selection.includedMarkedArtifacts
            selectedChannelIndex = persisted.result.channels.first?.channelIndex
                ?? persisted.selection.includedChannelIndices.first ?? 0
            if channelScope == .namedSet {
                selectedChannelSetID = currentChannelSets.first {
                    $0.name == persisted.selection.channelSetName
                }?.id
            }

            let contextMatches = restoredContextMatches(persisted.selection, signal: signal)
            if !persisted.status.isStale && contextMatches {
                resultSignature = makeSignature(
                    signalRevision: signal.dataRevision,
                    visibleRange: currentVisibleRange,
                    selectedRange: currentSelectedRange,
                    channelSets: currentChannelSets,
                    artifactSources: currentArtifactSources
                )
                resultIsStale = false
                persistedResultStatus = "Restored current recording-scoped result saved \(persisted.savedAt.formatted())"
                statusTitle = "Saved analysis restored"
                statusDetail = "The stored source revision and selection match the current recording."
            } else {
                resultSignature = nil
                resultIsStale = true
                let reason = persisted.status.explanation
                    ?? "The saved selection or channel context differs from the current recording."
                persistedResultStatus = "Restored stale result · \(reason)"
                statusTitle = "Saved analysis is stale"
                statusDetail = reason
            }
            selectedBandID = selectedChannelResult?.bands.first?.id
            appendLog(persistedResultStatus ?? "Restored saved Rhythmicity result.")
        } catch {
            persistedResultStatus = "Saved result unavailable: \(error.localizedDescription)"
            appendLog(persistedResultStatus ?? "Saved result could not be loaded.")
        }
    }

    private func restoredContextMatches(
        _ persisted: RhythmicitySelectionDescriptor,
        signal: MFFSignalData
    ) -> Bool {
        guard persisted.excludedBadChannelIndices == Array(store.channels.bad).sorted(),
              persisted.interpolatedChannelIndices == store.channels.interpolated.keys.sorted()
        else { return false }
        do {
            var segments = try selectedSegments(
                signal: signal,
                sampleCount: signal.data.first?.count ?? 0,
                visibleRange: currentVisibleRange,
                selectedRange: currentSelectedRange
            )
            if !includesMarkedArtifacts {
                segments = Self.removingArtifactIntervals(
                    from: segments,
                    sources: currentArtifactSources,
                    samplingRate: signal.samplingRate,
                    sampleCount: signal.data.first?.count ?? 0
                )
            }
            let (indices, setName) = try selectedChannels(signal: signal, channelSets: currentChannelSets)
            return segments == persisted.segments
                && indices == persisted.includedChannelIndices
                && setName == persisted.channelSetName
        } catch {
            return false
        }
    }

    private static func preferredPaperConfiguration(
        includesSignificance: Bool,
        seed: UInt64? = nil
    ) -> RhythmicityConfiguration {
        var value: RhythmicityConfiguration
        if includesSignificance {
            value = seed.map(RhythmicityPreset.paperLAVI2026(seed:))
                ?? RhythmicityPreset.paperLAVI2026
        } else {
            value = RhythmicityPreset.paperLAVI2026Exploratory
        }
        value.backend = ProcessingDefaults.shared.rhythmicityUsesGPU
            ? .automatic : .accelerateFFTCPU
        value.precision = .float64
        return value
    }

    func run(
        packageName: String,
        signal: MFFSignalData,
        visibleRange: ClosedRange<Int>?,
        selectedRange: ClosedRange<Int>?,
        channelSets: [ChannelSet],
        artifactSources: [EEGArtifactRejectionSource]
    ) {
        synchronizeContext(
            signal: signal,
            visibleRange: visibleRange,
            selectedRange: selectedRange,
            channelSets: channelSets,
            artifactSources: artifactSources
        )
        guard !isRunning else { return }

        let retainedSeed: UInt64?
        if case let .onDemand(significance) = configuration.significance {
            retainedSeed = significance.seed
        } else {
            retainedSeed = nil
        }
        configuration = Self.preferredPaperConfiguration(
            includesSignificance: includesSignificance,
            seed: retainedSeed
        )

        let snapshot: RhythmicityRunSnapshot
        let signature: RhythmicityContextSignature
        do {
            snapshot = try makeSnapshot(
                packageName: packageName,
                signal: signal,
                visibleRange: visibleRange,
                selectedRange: selectedRange,
                channelSets: channelSets,
                artifactSources: artifactSources
            )
            signature = makeSignature(
                signalRevision: signal.dataRevision,
                visibleRange: visibleRange,
                selectedRange: selectedRange,
                channelSets: channelSets,
                artifactSources: artifactSources
            )
        } catch {
            statusTitle = "Cannot run"
            statusDetail = error.localizedDescription
            appendLog(error.localizedDescription)
            return
        }

        runGeneration &+= 1
        let generation = runGeneration
        task?.cancel()
        cancellation?.cancel()
        let cancellation = RhythmicityCancellation()
        self.cancellation = cancellation
        isRunning = true
        progress = 0
        statusTitle = "Running LAVI/ABBA"
        statusDetail = runEstimate
        exportStatus = nil
        lastLoggedProgressPhase = nil
        lastLoggedProgressChannel = nil
        lastLoggedSignificanceMilestone = 0
        runStartedAt = Date()
        let selectedSamples = snapshot.selection.segments.reduce(0) {
            $0 + max($1.endSample - $1.startSample + 1, 0)
        }
        appendLog(
            "Started \(snapshot.selection.includedChannelIndices.count)-channel "
                + "\(dataSelection.rawValue.lowercased()) analysis · \(selectedSamples) selected samples "
                + "· \(snapshot.configuration.frequenciesHz.count) frequencies · requested backend "
                + "\(snapshot.configuration.backend.rawValue)."
        )
        if case let .onDemand(significance) = snapshot.configuration.significance {
            let totalProfiles = significance.repetitions * snapshot.selection.includedChannelIndices.count
            appendLog(
                "Paper significance will resolve \(significance.repetitions) matched IAAFT surrogates per uncached channel "
                    + "(up to \(totalProfiles) surrogate LAVI profiles total)."
            )
        }

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] (update: RhythmicityProgress) in
            guard let self, self.runGeneration == generation else { return }
            self.progress = min(max(update.fractionComplete, 0), 1)
            let description = Self.progressDescription(update)
            self.statusDetail = description
            self.recordProgressInLog(update, description: description)
        }

        task = Task { @MainActor in
            await store.processingQueue.run("Rhythmicity Explorer") { [self] in
                let worker = Task.detached(priority: .userInitiated) {
                    try RhythmicityExplorerRunner.analyze(
                        snapshot: snapshot,
                        cancellation: cancellation,
                        progress: { progressContinuation.yield($0) }
                    )
                }
                do {
                    let output = try await withTaskCancellationHandler(
                        operation: { try await worker.value },
                        onCancel: { cancellation.cancel(); worker.cancel() }
                    )
                    progressContinuation.finish()
                    progressTask.cancel()
                    guard runGeneration == generation, !Task.isCancelled else { return }
                    laviResult = output
                    resultSelection = snapshot.selection
                    resultSignature = signature
                    resultIsStale = false
                    isRunning = false
                    progress = 1
                    selectedChannelIndex = output.channels.first(where: { $0.channelIndex == selectedChannelIndex })?.channelIndex
                        ?? output.channels.first?.channelIndex ?? 0
                    selectedBandID = selectedChannelResult?.bands.first?.id
                    updateBurstStaleState()
                    timeFrequencyPublishStatus = nil
                    statusTitle = "Analysis complete"
                    statusDetail = "\(output.channels.count) channel\(output.channels.count == 1 ? "" : "s") · \(output.configuration.frequenciesHz.count) frequencies"
                    let elapsed = Date().timeIntervalSince(runStartedAt ?? Date())
                    appendLog(
                        "Completed LAVI/ABBA in \(String(format: "%.1f", elapsed)) seconds using "
                            + "\(backendDescription); no waveform or surrogate series was retained."
                    )
                    do {
                        let url = try persistenceStore.save(
                            result: output,
                            selection: snapshot.selection,
                            recordingURL: snapshot.signal.signalURL
                        )
                        persistedResultStatus = "Saved recording-scoped result · \(url.lastPathComponent)"
                        appendLog("Saved compact recording-scoped LAVI/ABBA result.")
                    } catch {
                        persistedResultStatus = "Result complete; persistence failed: \(error.localizedDescription)"
                        appendLog(persistedResultStatus ?? "Persistence failed.")
                    }
                } catch is CancellationError {
                    finishCancellation(generation: generation, progressContinuation: progressContinuation, progressTask: progressTask)
                } catch {
                    progressContinuation.finish()
                    progressTask.cancel()
                    guard runGeneration == generation else { return }
                    isRunning = false
                    progress = 0
                    statusTitle = "Analysis failed"
                    statusDetail = error.localizedDescription
                    appendLog("Failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func runEventRelated(
        packageName: String,
        signal: MFFSignalData,
        segments: [EpochSegment],
        channelSets: [ChannelSet]
    ) {
        synchronizeEventContext(signal: signal, segments: segments)
        guard !isRunning else { return }
        do {
            guard !segments.isEmpty else { throw RhythmicityExplorerError.noEpochs }
            let conditions = selectedWTPLConditions
            guard !conditions.isEmpty else { throw RhythmicityExplorerError.noConditions }
            if wtplShowsDifference {
                guard let conditionB = wtplConditionB,
                      !conditionB.isEmpty,
                      conditionB != wtplConditionA else {
                    throw RhythmicityExplorerError.invalidWTPLComparison
                }
            }
            let (indices, _) = try selectedChannels(signal: signal, channelSets: channelSets)
            guard !indices.isEmpty else { throw RhythmicityExplorerError.noEligibleChannels }
            guard wtplMinFrequencyHz > 0, wtplMaxFrequencyHz > wtplMinFrequencyHz,
                  wtplMaxFrequencyHz < signal.samplingRate / 2, wtplFrequencyCount > 0,
                  wtplBaselineStartMs <= wtplBaselineEndMs else {
                throw RhythmicityExplorerError.invalidWTPLConfiguration
            }
            let plan = TFFrequencyPlan.logSpaced(
                minHz: wtplMinFrequencyHz, maxHz: wtplMaxFrequencyHz,
                count: wtplFrequencyCount, cyclesLow: 5, cyclesHigh: 5
            )
            let source = RhythmicitySourceDescriptor(
                recordingIdentity: "\(signal.signalURL.standardizedFileURL.path)#\(signal.dataRevision.uuidString)",
                displayName: packageName
            )
            let snapshot = WTPLRunSnapshot(
                signal: signal, segments: segments, conditions: conditions,
                channelIndices: indices, plan: plan,
                lagCycles: configuration.wtplLagCycles,
                baselineStartMs: wtplBaselineStartMs, baselineEndMs: wtplBaselineEndMs,
                source: source,
                provenance: RhythmicityProcessingProvenance(
                    sourceRevision: signal.dataRevision.uuidString,
                    processingSummary: [
                        "Signal: \(signal.signalType)",
                        "Reference state: \(signal.referenceState.rawValue)",
                        "Conditions: \(conditions.joined(separator: ", "))",
                        "WTPL baseline requested: \(wtplBaselineStartMs)...\(wtplBaselineEndMs) ms",
                    ]
                )
            )
            let signature = makeWTPLSignature(signal: signal, segments: segments, channelIndices: indices, plan: plan)
            startWTPLRun(snapshot: snapshot, signature: signature)
        } catch {
            statusTitle = "Cannot run"
            statusDetail = error.localizedDescription
            appendLog(error.localizedDescription)
        }
    }

    func runBursts(
        packageName: String,
        signal: MFFSignalData,
        visibleRange: ClosedRange<Int>?,
        selectedRange: ClosedRange<Int>?,
        channelSets: [ChannelSet],
        artifactSources: [EEGArtifactRejectionSource]
    ) {
        synchronizeContext(
            signal: signal,
            visibleRange: visibleRange,
            selectedRange: selectedRange,
            channelSets: channelSets,
            artifactSources: artifactSources
        )
        guard !isRunning else { return }
        do {
            let base = try makeSnapshot(
                packageName: packageName,
                signal: signal,
                visibleRange: visibleRange,
                selectedRange: selectedRange,
                channelSets: channelSets,
                artifactSources: artifactSources
            )
            let bands = resolvedBurstBands(channelIndices: base.selection.includedChannelIndices)
            let snapshot = RhythmicBurstRunSnapshot(
                signal: signal,
                rhythmicityConfiguration: configuration,
                burstConfiguration: burstConfiguration,
                source: base.source,
                provenance: RhythmicityProcessingProvenance(
                    sourceRevision: base.provenance.sourceRevision,
                    processingSummary: base.provenance.processingSummary + [
                        "Burst domain: neural rhythmicity analysis; never artifact cleaning",
                        "Burst band source: \(bands.description)",
                    ]
                ),
                selection: base.selection,
                bandsByChannel: bands.byChannel,
                bandSourceDescription: bands.description
            )
            let signature = RhythmicBurstContextSignature(
                selection: makeSignature(
                    signalRevision: signal.dataRevision,
                    visibleRange: visibleRange,
                    selectedRange: selectedRange,
                    channelSets: channelSets,
                    artifactSources: artifactSources
                ),
                configuration: burstConfiguration,
                bandSource: burstBandSource,
                bandSignature: bands.signature
            )
            startBurstRun(snapshot: snapshot, signature: signature)
        } catch {
            statusTitle = "Cannot run"
            statusDetail = error.localizedDescription
            appendLog(error.localizedDescription)
        }
    }

    func exportWTPLPackage(
        to destination: URL,
        bands: [EEGFrequencyBand],
        windows: [TimeFrequencyExport.Window]
    ) throws {
        guard let result = wtplResult else { return }
        let contents = try WTPLExport.bundle(result: result, bands: bands, windows: windows)
        try WTPLExport.write(contents, to: destination)
        exportStatus = "Saved \(destination.lastPathComponent)"
        appendLog(exportStatus ?? "WTPL export complete.")
    }

    func exportBurstPackage(to destination: URL) throws {
        guard let result = burstResult else { return }
        let contents = try RhythmicBurstExport.bundle(result: result)
        try RhythmicBurstExport.write(contents, to: destination)
        exportStatus = "Saved \(destination.lastPathComponent)"
        appendLog(exportStatus ?? "Burst export complete.")
    }

    func cancel() {
        runGeneration &+= 1
        cancellation?.cancel()
        task?.cancel()
        task = nil
        isRunning = false
        progress = 0
        statusTitle = "Cancelled"
        let hasPreviousResult: Bool
        switch mode {
        case .bands: hasPreviousResult = laviResult != nil
        case .eventRelated: hasPreviousResult = wtplResult != nil
        case .bursts: hasPreviousResult = burstResult != nil
        }
        statusDetail = hasPreviousResult ? "Previous result retained." : "No partial result was published."
        appendLog("Cancelled; partial results were discarded.")
    }

    func exportPackage(to destination: URL) throws {
        guard let result = laviResult, let selection = resultSelection else { return }
        let contents = try RhythmicityExport.bundle(
            result: result,
            selection: selection,
            additionalWarnings: validityWarnings
        )
        try RhythmicityExport.write(contents, to: destination)
        exportStatus = "Saved \(destination.lastPathComponent)"
        appendLog(exportStatus ?? "Export complete.")
    }

    @discardableResult
    func publishSelectedChannelBandsToTimeFrequency() -> Bool {
        guard !resultIsStale,
              let result = laviResult,
              let selection = resultSelection,
              let channel = selectedChannelResult,
              let set = DetectedRhythmicityBandSet.make(result: result, selection: selection, channel: channel)
        else {
            timeFrequencyPublishStatus = resultIsStale
                ? "Re-run the stale analysis before publishing its bands."
                : "The selected channel has no ABBA bands to publish."
            return false
        }
        detectedBandSetForTimeFrequency = set
        detectedBandSetForTimeFrequencyIsStale = false
        timeFrequencyPublishStatus = "Using \(set.resultDescription) in Time-Frequency for this session."
        appendLog("Published \(set.resultDescription) to Time-Frequency for this session.")
        return true
    }

    func resetForClose() {
        if isRunning { cancel() }
        showsSheet = false
        mode = .bands
    }

    private var estimatedSelectedSampleCount: Int {
        switch dataSelection {
        case .entireProcessedRecording: return currentSampleCount
        case .currentVisibleRange: return currentVisibleRange.map(Self.rangeCount) ?? 0
        case .selectedRange: return currentSelectedRange.map(Self.rangeCount) ?? 0
        }
    }

    private var estimatedChannelIndices: [Int] {
        let valid = Set(0..<currentChannelCount)
        let bad = store.channels.bad
        switch channelScope {
        case .current:
            return valid.contains(selectedChannelIndex) && !bad.contains(selectedChannelIndex) ? [selectedChannelIndex] : []
        case .visibleGood:
            return valid.subtracting(bad).subtracting(store.channels.hidden).sorted()
        case .namedSet:
            return currentChannelSets.first { $0.id == selectedChannelSetID }?.channelIndices
                .filter { valid.contains($0) && !bad.contains($0) }.sorted() ?? []
        case .allGood:
            return valid.subtracting(bad).sorted()
        }
    }

    private func makeSnapshot(
        packageName: String,
        signal: MFFSignalData,
        visibleRange: ClosedRange<Int>?,
        selectedRange: ClosedRange<Int>?,
        channelSets: [ChannelSet],
        artifactSources: [EEGArtifactRejectionSource]
    ) throws -> RhythmicityRunSnapshot {
        let sampleCount = signal.data.first?.count ?? 0
        guard sampleCount > 0 else { throw RhythmicityExplorerError.emptySignal }
        var segments = try selectedSegments(
            signal: signal,
            sampleCount: sampleCount,
            visibleRange: visibleRange,
            selectedRange: selectedRange
        )
        if !includesMarkedArtifacts {
            segments = Self.removingArtifactIntervals(
                from: segments,
                sources: artifactSources,
                samplingRate: signal.samplingRate,
                sampleCount: sampleCount
            )
        }
        guard !segments.isEmpty else { throw RhythmicityExplorerError.emptyRange }
        let (indices, setName) = try selectedChannels(signal: signal, channelSets: channelSets)
        guard !indices.isEmpty else { throw RhythmicityExplorerError.noEligibleChannels }
        let interpolated = store.channels.interpolated.keys.sorted()
        let selection = RhythmicitySelectionDescriptor(
            source: source,
            dataSelection: dataSelection,
            segments: segments,
            channelScope: channelScope,
            channelSetName: setName,
            includedChannelIndices: indices,
            excludedBadChannelIndices: Array(store.channels.bad).sorted(),
            interpolatedChannelIndices: interpolated,
            includedMarkedArtifacts: includesMarkedArtifacts
        )
        return RhythmicityRunSnapshot(
            signal: signal,
            configuration: configuration,
            source: RhythmicitySourceDescriptor(
                recordingIdentity: "\(signal.signalURL.standardizedFileURL.path)#\(signal.dataRevision.uuidString)",
                displayName: packageName
            ),
            provenance: RhythmicityProcessingProvenance(
                sourceRevision: signal.dataRevision.uuidString,
                processingSummary: [
                    "Signal: \(signal.signalType)",
                    "Reference state: \(signal.referenceState.rawValue)",
                    "Interpolated channels: \(interpolated.map { String($0 + 1) }.joined(separator: ", "))",
                    "Bad channels excluded: \(selection.excludedBadChannelIndices.map { String($0 + 1) }.joined(separator: ", "))",
                    "Marked artifact intervals included: \(includesMarkedArtifacts)",
                ]
            ),
            selection: selection,
            significanceCache: persistenceStore.significanceCache(for: signal.signalURL)
        )
    }

    private func selectedSegments(
        signal: MFFSignalData,
        sampleCount: Int,
        visibleRange: ClosedRange<Int>?,
        selectedRange: ClosedRange<Int>?
    ) throws -> [RhythmicitySegment] {
        func clipped(_ range: ClosedRange<Int>, label: String) throws -> [RhythmicitySegment] {
            let lower = max(range.lowerBound, 0)
            let upper = min(range.upperBound, sampleCount - 1)
            guard lower <= upper else { throw RhythmicityExplorerError.emptyRange }
            return [RhythmicitySegment(startSample: lower, endSample: upper, label: label)]
        }
        switch dataSelection {
        case .entireProcessedRecording:
            if signal.isSegmented, !signal.epochSegments.isEmpty {
                return signal.epochSegments.compactMap { segment in
                    let lower = max(segment.startSample, 0)
                    let upper = min(segment.endSample, sampleCount - 1)
                    guard lower <= upper else { return nil }
                    return RhythmicitySegment(startSample: lower, endSample: upper, label: segment.category, trialID: segment.id)
                }
            }
            return [RhythmicitySegment(startSample: 0, endSample: sampleCount - 1, label: "Entire recording")]
        case .currentVisibleRange:
            guard let visibleRange else { throw RhythmicityExplorerError.missingRange("visible waveform range") }
            return try clipped(visibleRange, label: "Visible range")
        case .selectedRange:
            guard let selectedRange else { throw RhythmicityExplorerError.missingRange("waveform selection") }
            return try clipped(selectedRange, label: "Waveform selection")
        }
    }

    private func selectedChannels(signal: MFFSignalData, channelSets: [ChannelSet]) throws -> ([Int], String?) {
        let valid = Set(signal.data.indices)
        let bad = store.channels.bad
        switch channelScope {
        case .current:
            return (valid.contains(selectedChannelIndex) && !bad.contains(selectedChannelIndex) ? [selectedChannelIndex] : [], nil)
        case .visibleGood:
            return (valid.subtracting(bad).subtracting(store.channels.hidden).sorted(), nil)
        case .namedSet:
            guard let set = channelSets.first(where: { $0.id == selectedChannelSetID }) else {
                throw RhythmicityExplorerError.missingChannelSet
            }
            return (set.channelIndices.filter { valid.contains($0) && !bad.contains($0) }.sorted(), set.name)
        case .allGood:
            return (valid.subtracting(bad).sorted(), nil)
        }
    }

    private func makeSignature(
        signalRevision: UUID,
        visibleRange: ClosedRange<Int>?,
        selectedRange: ClosedRange<Int>?,
        channelSets: [ChannelSet],
        artifactSources: [EEGArtifactRejectionSource]
    ) -> RhythmicityContextSignature {
        RhythmicityContextSignature(
            signalRevision: signalRevision,
            configuration: configuration,
            dataSelection: dataSelection,
            channelScope: channelScope,
            selectedChannelIndex: channelScope == .current ? selectedChannelIndex : -1,
            selectedChannelSetID: channelScope == .namedSet ? selectedChannelSetID : nil,
            selectedSetChannels: channelScope == .namedSet
                ? channelSets.first(where: { $0.id == selectedChannelSetID })?.channelIndices ?? [] : [],
            visibleRange: dataSelection == .currentVisibleRange ? visibleRange : nil,
            selectedRange: dataSelection == .selectedRange ? selectedRange : nil,
            badChannels: Array(store.channels.bad).sorted(),
            hiddenChannels: channelScope == .visibleGood ? Array(store.channels.hidden).sorted() : [],
            interpolationRevision: store.channels.interpolationRevision,
            artifactSignature: Self.artifactSignature(artifactSources),
            includesMarkedArtifacts: includesMarkedArtifacts
        )
    }

    private func updateStaleState() {
        guard let resultSignature, let currentSignalRevision else {
            resultIsStale = laviResult != nil && resultSignature == nil
            return
        }
        let current = makeSignature(
            signalRevision: currentSignalRevision,
            visibleRange: currentVisibleRange,
            selectedRange: currentSelectedRange,
            channelSets: currentChannelSets,
            artifactSources: currentArtifactSources
        )
        resultIsStale = resultSignature != current
        if let published = detectedBandSetForTimeFrequency {
            detectedBandSetForTimeFrequencyIsStale = published.sourceRevision != currentSignalRevision.uuidString
        }
    }

    private func updateWTPLStaleState() {
        guard let signature = wtplResultSignature,
              let signal = currentEventSignal else {
            wtplResultIsStale = wtplResult != nil && wtplResultSignature == nil
            return
        }
        let indices = estimatedChannelIndices
        guard wtplMinFrequencyHz > 0, wtplMaxFrequencyHz > wtplMinFrequencyHz,
              wtplFrequencyCount > 0 else {
            wtplResultIsStale = true
            return
        }
        let plan = TFFrequencyPlan.logSpaced(
            minHz: wtplMinFrequencyHz, maxHz: wtplMaxFrequencyHz,
            count: wtplFrequencyCount, cyclesLow: 5, cyclesHigh: 5
        )
        wtplResultIsStale = signature != makeWTPLSignature(
            signal: signal, segments: currentEpochSegments, channelIndices: indices, plan: plan
        )
    }

    private func updateBurstStaleState() {
        guard let signature = burstResultSignature,
              let signalRevision = currentSignalRevision else {
            burstResultIsStale = burstResult != nil && burstResultSignature == nil
            return
        }
        let bands = resolvedBurstBands(channelIndices: estimatedChannelIndices)
        let current = RhythmicBurstContextSignature(
            selection: makeSignature(
                signalRevision: signalRevision,
                visibleRange: currentVisibleRange,
                selectedRange: currentSelectedRange,
                channelSets: currentChannelSets,
                artifactSources: currentArtifactSources
            ),
            configuration: burstConfiguration,
            bandSource: burstBandSource,
            bandSignature: bands.signature
        )
        burstResultIsStale = signature != current
    }

    private func makeWTPLSignature(
        signal: MFFSignalData,
        segments: [EpochSegment],
        channelIndices: [Int],
        plan: TFFrequencyPlan
    ) -> WTPLContextSignature {
        WTPLContextSignature(
            signalRevision: signal.dataRevision,
            segmentSignature: Self.epochSignature(segments),
            channelIndices: channelIndices,
            conditionA: wtplConditionA,
            conditionB: wtplShowsDifference ? wtplConditionB : nil,
            frequenciesHz: plan.frequenciesHz,
            nCycles: plan.nCycles,
            lagCycles: configuration.wtplLagCycles,
            baselineStartMs: wtplBaselineStartMs,
            baselineEndMs: wtplBaselineEndMs
        )
    }

    private func startWTPLRun(snapshot: WTPLRunSnapshot, signature: WTPLContextSignature) {
        runGeneration &+= 1
        let generation = runGeneration
        task?.cancel()
        cancellation?.cancel()
        let cancellation = RhythmicityCancellation()
        self.cancellation = cancellation
        isRunning = true
        progress = 0
        statusTitle = "Running WTPL"
        statusDetail = runEstimate
        exportStatus = nil
        appendLog("Started event-related WTPL for \(snapshot.conditions.joined(separator: ", ")).")

        let (continuation, progressTask) = ProgressBridge.make { [weak self] (update: RhythmicityProgress) in
            guard let self, self.runGeneration == generation else { return }
            self.progress = min(max(update.fractionComplete, 0), 1)
            self.statusDetail = Self.progressDescription(update)
        }
        task = Task { @MainActor in
            await store.processingQueue.run("Rhythmicity WTPL") { [self] in
                let worker = Task.detached(priority: .userInitiated) {
                    try WTPLExplorerRunner.analyze(
                        snapshot: snapshot, cancellation: cancellation,
                        progress: { continuation.yield($0) }
                    )
                }
                do {
                    let output = try await withTaskCancellationHandler(
                        operation: { try await worker.value },
                        onCancel: { cancellation.cancel(); worker.cancel() }
                    )
                    continuation.finish()
                    progressTask.cancel()
                    guard runGeneration == generation, !Task.isCancelled else { return }
                    wtplResult = output
                    wtplResultSignature = signature
                    wtplResultIsStale = false
                    isRunning = false
                    progress = 1
                    statusTitle = "WTPL complete"
                    statusDetail = "\(output.conditions.count) condition\(output.conditions.count == 1 ? "" : "s") · \(output.frequenciesHz.count) frequencies"
                    appendLog("Completed raw WTPL, ΔWTPL, variance, and valid-count maps.")
                } catch is CancellationError {
                    finishCancellation(generation: generation, progressContinuation: continuation, progressTask: progressTask)
                } catch {
                    continuation.finish()
                    progressTask.cancel()
                    guard runGeneration == generation else { return }
                    isRunning = false
                    progress = 0
                    statusTitle = "WTPL failed"
                    statusDetail = error.localizedDescription
                    appendLog("WTPL failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startBurstRun(
        snapshot: RhythmicBurstRunSnapshot,
        signature: RhythmicBurstContextSignature
    ) {
        runGeneration &+= 1
        let generation = runGeneration
        task?.cancel()
        cancellation?.cancel()
        let cancellation = RhythmicityCancellation()
        self.cancellation = cancellation
        isRunning = true
        progress = 0
        statusTitle = "Detecting rhythmic bursts"
        statusDetail = runEstimate
        exportStatus = nil
        appendLog("Started neural-rhythmicity burst detection; no artifact action is available.")

        let (continuation, progressTask) = ProgressBridge.make { [weak self] (update: RhythmicityProgress) in
            guard let self, self.runGeneration == generation else { return }
            self.progress = min(max(update.fractionComplete, 0), 1)
            self.statusDetail = Self.progressDescription(update)
        }
        task = Task { @MainActor in
            await store.processingQueue.run("Rhythmicity Bursts") { [self] in
                let worker = Task.detached(priority: .userInitiated) {
                    try RhythmicBurstRunner.analyze(
                        snapshot: snapshot,
                        cancellation: cancellation,
                        progress: { continuation.yield($0) }
                    )
                }
                do {
                    let output = try await withTaskCancellationHandler(
                        operation: { try await worker.value },
                        onCancel: { cancellation.cancel(); worker.cancel() }
                    )
                    continuation.finish()
                    progressTask.cancel()
                    guard runGeneration == generation, !Task.isCancelled else { return }
                    burstResult = output
                    burstResultSignature = signature
                    burstResultIsStale = false
                    isRunning = false
                    progress = 1
                    selectedBurstID = output.bursts.first?.id
                    statusTitle = "Burst analysis complete"
                    statusDetail = "\(output.bursts.count) burst\(output.bursts.count == 1 ? "" : "s") · \(output.maps.count) channel-segment map\(output.maps.count == 1 ? "" : "s")"
                    appendLog("Completed peak detection, boundary refinement, overlap merging, band assignment, and metrics.")
                } catch is CancellationError {
                    finishCancellation(generation: generation, progressContinuation: continuation, progressTask: progressTask)
                } catch {
                    continuation.finish()
                    progressTask.cancel()
                    guard runGeneration == generation else { return }
                    isRunning = false
                    progress = 0
                    statusTitle = "Burst analysis failed"
                    statusDetail = error.localizedDescription
                    appendLog("Burst analysis failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finishCancellation(
        generation: Int,
        progressContinuation: AsyncStream<RhythmicityProgress>.Continuation,
        progressTask: Task<Void, Never>
    ) {
        progressContinuation.finish()
        progressTask.cancel()
        guard runGeneration == generation else { return }
        isRunning = false
        progress = 0
        statusTitle = "Cancelled"
        let hasPreviousResult: Bool
        switch mode {
        case .bands: hasPreviousResult = laviResult != nil
        case .eventRelated: hasPreviousResult = wtplResult != nil
        case .bursts: hasPreviousResult = burstResult != nil
        }
        statusDetail = hasPreviousResult ? "Previous result retained." : "No partial result was published."
        appendLog("Cancelled; partial results were discarded.")
    }

    private func appendLog(_ message: String) {
        log.append(RhythmicityLogLine(date: Date(), message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func recordProgressInLog(
        _ update: RhythmicityProgress,
        description: String
    ) {
        if lastLoggedProgressChannel != update.channelIndex {
            lastLoggedProgressChannel = update.channelIndex
            lastLoggedProgressPhase = nil
            lastLoggedSignificanceMilestone = 0
        }

        switch update.phase {
        case .validating, .transforming, .estimatingAperiodicSpectrum, .assigningBands, .finished:
            if lastLoggedProgressPhase != update.phase {
                appendLog(description + ".")
            }
        case .generatingSignificance:
            let completed = update.completedSignificanceProfiles ?? 0
            let total = max(update.totalSignificanceProfiles ?? 0, 0)
            if description.contains("Cache hit") {
                if lastLoggedSignificanceMilestone != total {
                    appendLog(description + ".")
                    lastLoggedSignificanceMilestone = total
                }
            } else if lastLoggedProgressPhase != .generatingSignificance {
                let workerText = update.detail?.contains("Parallel IAAFT") == true
                    ? " · bounded parallel IAAFT enabled" : ""
                appendLog(
                    total > 0
                        ? "Matched significance generation started · \(total) surrogates for this channel\(workerText)."
                        : description + "."
                )
            }
            let milestoneSize = max(total / 10, 1)
            if !description.contains("Cache hit"),
               completed > 0,
               (completed == total || completed >= lastLoggedSignificanceMilestone + milestoneSize) {
                lastLoggedSignificanceMilestone = completed
                appendLog("Completed \(completed) of \(total) matched surrogates for this channel.")
            }
        case .detectingBursts:
            if lastLoggedProgressPhase != update.phase {
                appendLog(description + ".")
            }
        }
        lastLoggedProgressPhase = update.phase
    }

    private static func rangeCount(_ range: ClosedRange<Int>) -> Int {
        max(range.upperBound - range.lowerBound + 1, 0)
    }

    private static func artifactSignature(_ sources: [EEGArtifactRejectionSource]) -> String {
        sources.flatMap { source in
            source.events.map { "\(source.id):\($0.id):\($0.beginTimeSeconds):\(source.windowSizeSeconds)" }
        }.sorted().joined(separator: "|")
    }

    private static func epochSignature(_ segments: [EpochSegment]) -> String {
        segments.map {
            "\($0.id):\($0.category):\($0.startSample):\($0.endSample):\($0.stimulusOffsetSamples)"
        }.joined(separator: "|")
    }

    fileprivate nonisolated static func baselineSpec(
        startMs: Double,
        endMs: Double,
        stack: TimeFrequencyTrials.Stack
    ) -> WTPLBaselineSpec? {
        guard !stack.isEmpty, startMs.isFinite, endMs.isFinite, startMs <= endMs else { return nil }
        let start = stack.stimulusOffsetSamples + Int((startMs / 1_000 * stack.samplingRate).rounded())
        let end = stack.stimulusOffsetSamples + Int((endMs / 1_000 * stack.samplingRate).rounded())
        guard start >= 0, end >= start, end < stack.timeCount else { return nil }
        return WTPLBaselineSpec(startSample: start, endSample: end)
    }

    private static func removingArtifactIntervals(
        from segments: [RhythmicitySegment],
        sources: [EEGArtifactRejectionSource],
        samplingRate: Double,
        sampleCount: Int
    ) -> [RhythmicitySegment] {
        guard !sources.isEmpty else { return segments }
        let intervals = sources.flatMap { source in
            source.events.map { event -> ClosedRange<Int> in
                let half = max(source.windowSizeSeconds, 0.001) / 2
                let lower = min(max(Int(((event.centerTimeSeconds - half) * samplingRate).rounded(.down)), 0), sampleCount - 1)
                let upper = min(max(Int(((event.centerTimeSeconds + half) * samplingRate).rounded(.up)), lower), sampleCount - 1)
                return lower...upper
            }
        }
        return RhythmicitySegmentPolicy.removing(excludedRanges: intervals, from: segments)
    }

    private static func progressDescription(_ update: RhythmicityProgress) -> String {
        let channel = update.channelIndex.map { "Channel \($0 + 1) · " } ?? ""
        if let detail = update.detail { return channel + detail }
        let phase: String
        switch update.phase {
        case .validating: phase = "Validating input"
        case .transforming: phase = "Computing complex Morlet coefficients"
        case .estimatingAperiodicSpectrum: phase = "Estimating aperiodic spectrum"
        case .generatingSignificance: phase = "Generating matched surrogate noise"
        case .assigningBands: phase = "Assigning ABBA regions"
        case .detectingBursts: phase = "Detecting and merging rhythmic bursts"
        case .finished: phase = "Finishing"
        }
        let frequency = update.frequencyHz.map { " · \(String(format: "%.2f", $0)) Hz" } ?? ""
        return channel + phase + frequency
    }

    private func resolvedBurstBands(
        channelIndices: [Int]
    ) -> (byChannel: [Int: [RhythmicBurstBandDefinition]], description: String, signature: String) {
        switch burstBandSource {
        case .evaDefaults:
            let definitions = Self.burstDefinitions(
                EEGFrequencyBand.restingDefaults,
                source: TimeFrequencyBandSource.evaDefaults.rawValue
            )
            return (
                Dictionary(uniqueKeysWithValues: channelIndices.map { ($0, definitions) }),
                TimeFrequencyBandSource.evaDefaults.rawValue,
                definitions.map(\.id).joined(separator: "|")
            )
        case .userPreferences:
            let definitions = Self.burstDefinitions(
                ProcessingDefaults.shared.timeFrequencyBands,
                source: TimeFrequencyBandSource.userPreferences.rawValue
            )
            return (
                Dictionary(uniqueKeysWithValues: channelIndices.map { ($0, definitions) }),
                TimeFrequencyBandSource.userPreferences.rawValue,
                definitions.map { "\($0.id):\($0.lowHz):\($0.highHz)" }.joined(separator: "|")
            )
        case .rhythmicityExplorer:
            if let result = laviResult, !resultIsStale {
                var byChannel: [Int: [RhythmicBurstBandDefinition]] = [:]
                for channelIndex in channelIndices {
                    let channel = result.channels.first { $0.channelIndex == channelIndex }
                    byChannel[channelIndex] = channel.map(Self.burstDefinitions) ?? []
                }
                let signature = byChannel.keys.sorted().flatMap { channel in
                    (byChannel[channel] ?? []).map { "\(channel):\($0.id):\($0.lowHz):\($0.highHz)" }
                }.joined(separator: "|")
                return (byChannel, "Current channel-specific LAVI/ABBA result", signature)
            }
            if let published = detectedBandSetForTimeFrequency,
               !detectedBandSetForTimeFrequencyIsStale {
                let definitions = published.displayBands.map {
                    RhythmicBurstBandDefinition(
                        id: "abba:\($0.id.uuidString)", name: $0.name,
                        lowHz: $0.lowHz, highHz: $0.highHz,
                        direction: $0.direction, source: "Published LAVI/ABBA"
                    )
                }
                return (
                    Dictionary(uniqueKeysWithValues: channelIndices.map { ($0, definitions) }),
                    "Published LAVI/ABBA: \(published.resultDescription)",
                    definitions.map { "\($0.id):\($0.lowHz):\($0.highHz)" }.joined(separator: "|")
                )
            }
            return (
                Dictionary(uniqueKeysWithValues: channelIndices.map { ($0, []) }),
                "No current LAVI/ABBA bands; bursts will be unassigned",
                "unavailable"
            )
        }
    }

    private nonisolated static func burstDefinitions(
        _ bands: [EEGFrequencyBand],
        source: String
    ) -> [RhythmicBurstBandDefinition] {
        bands.map {
            RhythmicBurstBandDefinition(
                id: "\(source):\($0.name):\($0.lowHz):\($0.highHz)",
                name: $0.name, lowHz: $0.lowHz, highHz: $0.highHz,
                direction: nil, source: source
            )
        }
    }

    private nonisolated static func burstDefinitions(
        _ channel: LAVIChannelResult
    ) -> [RhythmicBurstBandDefinition] {
        channel.bands.enumerated().map { index, band in
            RhythmicBurstBandDefinition(
                id: "abba:\(band.id.uuidString)",
                name: band.canonicalName ?? "\(band.direction.rawValue.capitalized) \(index + 1)",
                lowHz: min(band.beginFrequencyHz, band.endFrequencyHz),
                highHz: max(band.beginFrequencyHz, band.endFrequencyHz),
                direction: band.direction,
                source: "Current channel-specific LAVI/ABBA result"
            )
        }
    }
}

private nonisolated enum RhythmicityExplorerRunner {
    static func analyze(
        snapshot: RhythmicityRunSnapshot,
        cancellation: RhythmicityCancellation,
        progress: @escaping @Sendable (RhythmicityProgress) -> Void
    ) throws -> LAVIAnalysisResult {
        let progressRelay = RhythmicityRunnerProgressRelay(progress: progress)
        return try analyzePass(
            snapshot: snapshot,
            cancellation: cancellation,
            progress: { progressRelay.emit($0) }
        )
    }

    private static func analyzePass(
        snapshot: RhythmicityRunSnapshot,
        cancellation: RhythmicityCancellation,
        progress: @escaping @Sendable (RhythmicityProgress) -> Void
    ) throws -> LAVIAnalysisResult {
        var channelResults: [LAVIChannelResult] = []
        var warnings: [RhythmicityWarning] = []
        var runConfiguration = snapshot.configuration
        var effectiveConfiguration: RhythmicityConfiguration?
        let channelIndices = snapshot.selection.includedChannelIndices
        for (ordinal, index) in channelIndices.enumerated() {
            try cancellation.check()
            let name: String
            if let names = snapshot.signal.channelNames, names.indices.contains(index) {
                name = names[index]
            } else {
                name = "E\(index + 1)"
            }
            let channel = RhythmicityChannelInput(
                channelIndex: index,
                channelName: name,
                samples: snapshot.signal.data[index].map(Double.init),
                isInterpolated: snapshot.selection.interpolatedChannelIndices.contains(index)
            )
            let input = RhythmicityInput(
                channels: [channel],
                samplingRate: snapshot.signal.samplingRate,
                segments: snapshot.selection.segments,
                source: snapshot.source,
                processingProvenance: snapshot.provenance
            )
            let output = try LAVIEngine.analyze(
                input: input,
                configuration: runConfiguration,
                significanceCache: snapshot.significanceCache,
                cancellation: cancellation
            ) { update in
                let fraction = (Double(ordinal) + update.fractionComplete) / Double(max(channelIndices.count, 1))
                progress(RhythmicityProgress(
                    fractionComplete: fraction,
                    phase: update.phase,
                    channelIndex: index,
                    frequencyHz: update.frequencyHz,
                    completedTiles: ordinal * snapshot.configuration.frequenciesHz.count + update.completedTiles,
                    totalTiles: channelIndices.count * snapshot.configuration.frequenciesHz.count,
                    detail: update.detail,
                    completedSignificanceProfiles: update.completedSignificanceProfiles,
                    totalSignificanceProfiles: update.totalSignificanceProfiles
                ))
            }
            if let effectiveConfiguration,
               output.configuration.backend != effectiveConfiguration.backend {
                var fallbackSnapshot = snapshot
                fallbackSnapshot.configuration.backend = .accelerateFFTCPU
                fallbackSnapshot.configuration.precision = .float64
                var fallback = try analyzePass(
                    snapshot: fallbackSnapshot,
                    cancellation: cancellation,
                    progress: progress
                )
                let warning = output.warnings.first(where: Self.isBackendFallback)
                    ?? .computeBackendFallback(
                        requested: snapshot.configuration.backend.rawValue,
                        reason: "Metal became unavailable during a later channel; the complete result was recomputed on CPU."
                    )
                if !fallback.warnings.contains(warning) {
                    fallback.warnings.insert(warning, at: 0)
                    if !fallback.channels.isEmpty {
                        fallback.channels[0].warnings.insert(warning, at: 0)
                    }
                }
                return fallback
            }
            if effectiveConfiguration == nil {
                effectiveConfiguration = output.configuration
                runConfiguration = output.configuration
            }
            channelResults.append(contentsOf: output.channels)
            warnings.append(contentsOf: output.warnings)
        }
        try cancellation.check()
        return LAVIAnalysisResult(
            configuration: effectiveConfiguration ?? snapshot.configuration,
            source: snapshot.source,
            processingProvenance: snapshot.provenance,
            samplingRateHz: snapshot.signal.samplingRate,
            channels: channelResults,
            warnings: warnings
        )
    }

    private static func isBackendFallback(_ warning: RhythmicityWarning) -> Bool {
        if case .computeBackendFallback = warning { return true }
        return false
    }
}

private nonisolated final class RhythmicityRunnerProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (RhythmicityProgress) -> Void
    private var highestFraction = -Double.infinity

    init(progress: @escaping @Sendable (RhythmicityProgress) -> Void) {
        self.progress = progress
    }

    func emit(_ update: RhythmicityProgress) {
        lock.lock()
        guard update.fractionComplete >= highestFraction else {
            lock.unlock()
            return
        }
        highestFraction = update.fractionComplete
        lock.unlock()
        progress(update)
    }
}

private nonisolated enum WTPLExplorerRunner {
    static func analyze(
        snapshot: WTPLRunSnapshot,
        cancellation: RhythmicityCancellation,
        progress: @escaping @Sendable (RhythmicityProgress) -> Void
    ) throws -> WTPLAnalysisResult {
        let provider = AccelerateFFTComplexCoefficientProvider()
        let total = max(snapshot.conditions.count * snapshot.channelIndices.count, 1)
        var completed = 0
        var conditionResults: [WTPLConditionResult] = []
        var warnings: [RhythmicityWarning] = []
        var sharedTimes: [Double] = []
        var sharedBaseline: ClosedRange<Double>?

        for condition in snapshot.conditions {
            var channels: [WTPLChannelResult] = []
            for channelIndex in snapshot.channelIndices {
                try cancellation.check()
                let stack = TimeFrequencyTrials.stack(
                    signal: snapshot.signal,
                    segments: snapshot.segments,
                    category: condition,
                    channelIndices: [channelIndex]
                )
                guard !stack.isEmpty else { continue }
                let baseline = RhythmicityExplorerViewModel.baselineSpec(
                    startMs: snapshot.baselineStartMs,
                    endMs: snapshot.baselineEndMs,
                    stack: stack
                )
                if baseline == nil {
                    warnings.append(.wtplRequestedBaselineOutsideEpoch(
                        startMs: snapshot.baselineStartMs, endMs: snapshot.baselineEndMs
                    ))
                }
                let completedBefore = completed
                let result = try WTPLEngine.analyze(
                    trials: stack.trials,
                    samplingRate: stack.samplingRate,
                    plan: snapshot.plan,
                    lagCycles: snapshot.lagCycles,
                    baseline: baseline,
                    eventSampleIndex: stack.stimulusOffsetSamples,
                    coefficientProvider: provider,
                    edgePolicy: .validOnly,
                    retainPerTrial: false,
                    cancellation: cancellation
                ) { update in
                    progress(RhythmicityProgress(
                        fractionComplete: (Double(completedBefore) + update.fractionComplete) / Double(total),
                        phase: update.phase,
                        channelIndex: channelIndex,
                        frequencyHz: update.frequencyHz,
                        completedTiles: completedBefore,
                        totalTiles: total
                    ))
                }
                if sharedTimes.isEmpty {
                    sharedTimes = result.timesMs
                } else if result.timesMs != sharedTimes {
                    throw WTPLAnalysisError.mismatchedTimeAxis(condition: condition)
                }
                if sharedBaseline == nil { sharedBaseline = result.baselineWindowMs }
                warnings.append(contentsOf: result.warnings)
                let name = snapshot.signal.channelNames.flatMap { names in
                    names.indices.contains(channelIndex) ? names[channelIndex] : nil
                } ?? "E\(channelIndex + 1)"
                channels.append(WTPLChannelResult(
                    channelIndex: channelIndex,
                    channelName: name,
                    meanWTPL: result.meanWTPL,
                    deltaWTPL: result.deltaWTPL,
                    validTrialCounts: result.validTrialCounts,
                    varianceWTPL: result.varianceWTPL,
                    trialCount: result.trialCount
                ))
                completed += 1
            }
            if !channels.isEmpty {
                conditionResults.append(WTPLConditionResult(condition: condition, channels: channels))
            }
        }
        guard !conditionResults.isEmpty else { throw WTPLAnalysisError.noTrials }
        var seen = Set<String>()
        warnings = warnings.filter { seen.insert($0.displayText).inserted }
        return WTPLAnalysisResult(
            source: snapshot.source,
            processingProvenance: snapshot.provenance,
            frequenciesHz: snapshot.plan.frequenciesHz,
            timesMs: sharedTimes,
            nCycles: snapshot.plan.nCycles,
            lagCycles: snapshot.lagCycles,
            edgePolicy: .validOnly,
            baselineWindowMs: sharedBaseline,
            conditions: conditionResults,
            warnings: warnings
        )
    }
}
