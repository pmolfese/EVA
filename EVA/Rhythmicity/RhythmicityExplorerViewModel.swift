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
}

private enum RhythmicityExplorerError: LocalizedError {
    case emptySignal
    case missingRange(String)
    case emptyRange
    case noEligibleChannels
    case missingChannelSet

    var errorDescription: String? {
        switch self {
        case .emptySignal: return "The processed signal contains no readable samples."
        case let .missingRange(name): return "No \(name) is available. Choose another data selection."
        case .emptyRange: return "The selected interval contains no samples."
        case .noEligibleChannels: return "No channels are eligible under the current channel scope."
        case .missingChannelSet: return "Choose a channel set before running the analysis."
        }
    }
}

@MainActor
@Observable
final class RhythmicityExplorerViewModel {
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    var showsSheet = false
    var mode = RhythmicityExplorerMode.bands
    var source = RhythmicitySignalSource.processed
    var configuration = RhythmicityPreset.paperLAVI2026 { didSet { updateStaleState() } }
    var dataSelection = RhythmicityDataSelection.entireProcessedRecording { didSet { updateStaleState() } }
    var channelScope = RhythmicityChannelScope.current { didSet { updateStaleState() } }
    var selectedChannelIndex = 0 { didSet { updateStaleState() } }
    var selectedChannelSetID: UUID? { didSet { updateStaleState() } }
    var includesSignificance = true
    var includesMarkedArtifacts = false { didSet { updateStaleState() } }

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

    var runEstimate: String {
        let channelCount = estimatedChannelIndices.count
        let profileCount = includesSignificance ? 201 : 1
        guard estimatedSelectedSampleCount > 0, channelCount > 0 else { return "Selection is incomplete" }
        return "\(channelCount) channel\(channelCount == 1 ? "" : "s") × \(configuration.frequenciesHz.count) frequencies × \(profileCount) profile\(profileCount == 1 ? "" : "s")"
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
        configuration = enabled ? RhythmicityPreset.paperLAVI2026 : RhythmicityPreset.paperLAVI2026Exploratory
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
        updateStaleState()
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

        configuration = includesSignificance
            ? RhythmicityPreset.paperLAVI2026(seed: UInt64.random(in: UInt64.min...UInt64.max))
            : RhythmicityPreset.paperLAVI2026Exploratory

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
        appendLog("Started \(snapshot.selection.includedChannelIndices.count)-channel \(dataSelection.rawValue.lowercased()) analysis.")

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] (update: RhythmicityProgress) in
            guard let self, self.runGeneration == generation else { return }
            self.progress = min(max(update.fractionComplete, 0), 1)
            self.statusDetail = Self.progressDescription(update)
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
                    timeFrequencyPublishStatus = nil
                    statusTitle = "Analysis complete"
                    statusDetail = "\(output.channels.count) channel\(output.channels.count == 1 ? "" : "s") · \(output.configuration.frequenciesHz.count) frequencies"
                    appendLog("Completed LAVI/ABBA analysis; no waveform or surrogate series was retained.")
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

    func cancel() {
        runGeneration &+= 1
        cancellation?.cancel()
        task?.cancel()
        task = nil
        isRunning = false
        progress = 0
        statusTitle = "Cancelled"
        statusDetail = laviResult == nil ? "No partial result was published." : "Previous result retained."
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
            selection: selection
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
        statusDetail = laviResult == nil ? "No partial result was published." : "Previous result retained."
        appendLog("Cancelled; partial results were discarded.")
    }

    private func appendLog(_ message: String) {
        log.append(RhythmicityLogLine(date: Date(), message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private static func rangeCount(_ range: ClosedRange<Int>) -> Int {
        max(range.upperBound - range.lowerBound + 1, 0)
    }

    private static func artifactSignature(_ sources: [EEGArtifactRejectionSource]) -> String {
        sources.flatMap { source in
            source.events.map { "\(source.id):\($0.id):\($0.beginTimeSeconds):\(source.windowSizeSeconds)" }
        }.sorted().joined(separator: "|")
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
        let phase: String
        switch update.phase {
        case .validating: phase = "Validating input"
        case .transforming: phase = "Computing complex Morlet coefficients"
        case .estimatingAperiodicSpectrum: phase = "Estimating aperiodic spectrum"
        case .generatingSignificance: phase = "Generating matched surrogate noise"
        case .assigningBands: phase = "Assigning ABBA regions"
        case .finished: phase = "Finishing"
        }
        let frequency = update.frequencyHz.map { " · \(String(format: "%.2f", $0)) Hz" } ?? ""
        return phase + frequency
    }
}

private nonisolated enum RhythmicityExplorerRunner {
    static func analyze(
        snapshot: RhythmicityRunSnapshot,
        cancellation: RhythmicityCancellation,
        progress: @escaping @Sendable (RhythmicityProgress) -> Void
    ) throws -> LAVIAnalysisResult {
        var channelResults: [LAVIChannelResult] = []
        var warnings: [RhythmicityWarning] = []
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
                configuration: snapshot.configuration,
                cancellation: cancellation
            ) { update in
                let fraction = (Double(ordinal) + update.fractionComplete) / Double(max(channelIndices.count, 1))
                progress(RhythmicityProgress(
                    fractionComplete: fraction,
                    phase: update.phase,
                    channelIndex: index,
                    frequencyHz: update.frequencyHz,
                    completedTiles: ordinal * snapshot.configuration.frequenciesHz.count + update.completedTiles,
                    totalTiles: channelIndices.count * snapshot.configuration.frequenciesHz.count
                ))
            }
            channelResults.append(contentsOf: output.channels)
            warnings.append(contentsOf: output.warnings)
        }
        try cancellation.check()
        return LAVIAnalysisResult(
            configuration: snapshot.configuration,
            source: snapshot.source,
            processingProvenance: snapshot.provenance,
            samplingRateHz: snapshot.signal.samplingRate,
            channels: channelResults,
            warnings: warnings
        )
    }
}
