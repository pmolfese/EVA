//
//  MFFRecording.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Non-document app model for opening and viewing EEG recordings.
//

import Foundation
import simd
import UniformTypeIdentifiers

extension UTType {
    /// EGI MFF recording package. EGI/Philips owns the format; EVA reads it.
    static var mff: UTType {
        UTType(importedAs: "com.egi.mff")
    }
}

enum ChannelRoleEditError: LocalizedError {
    case missingEEGSignal
    case missingPhysioSignal
    case invalidChannel
    case cannotMoveLastEEGChannel
    case incompatiblePhysioTiming
    case incompatibleEEGTiming

    var errorDescription: String? {
        switch self {
        case .missingEEGSignal:
            return "No EEG signal is loaded."
        case .missingPhysioSignal:
            return "No physio signal is loaded."
        case .invalidChannel:
            return "That channel is no longer available."
        case .cannotMoveLastEEGChannel:
            return "At least one EEG channel must remain."
        case .incompatiblePhysioTiming:
            return "This channel cannot be appended to the existing physio signal because the sampling rate or sample count differs."
        case .incompatibleEEGTiming:
            return "This physio channel cannot be moved to EEG because the sampling rate or sample count differs."
        }
    }
}

/// A loaded or loading EEG recording used by EVA's normal WindowGroup app flow.
@Observable
final class MFFRecording: Identifiable {

    let id = UUID()
    let packageURL: URL
    let packageName: String
    /// Sidecar/folder URLs whose security scope this recording was opened with.
    ///
    /// Readable because a **fork** needs them: the second window re-reads the
    /// file for itself (`MFFRecording` cannot be shared — see
    /// `WaveformView.forkToNewWindow`), and a format whose data lives beside the
    /// header rather than inside a package — BrainVision's `.vmrk`/`.eeg`, EDF,
    /// Persyst, BESA — cannot be re-read without the same scope the original
    /// open was granted. Forks used to drop them and fail to load
    /// (ROADMAP RW-1 item 12).
    ///
    /// Scopes are process-wide and refcounted, so handing the same URLs to a
    /// second window in this process is enough; no bookmark round-trip and no
    /// normalized copy of the file are needed.
    private(set) var securityScopedURLs: [URL]

    private(set) var signal: MFFSignalData?
    /// Peripheral/physiological channels (ECG, EMG, …), shown alongside the EEG.
    private(set) var pnsSignal: MFFSignalData?
    private(set) var sensorLayout: SensorLayout?
    private(set) var electrodeGeometry: ElectrodeGeometry?
    private(set) var antiAliasTimingCorrection: MFFAntiAliasTimingCorrection?
    /// Per-category grand-average noise band from a combined package's
    /// `eva_noise.json` sidecar (empty for ordinary recordings).
    private(set) var noiseCurvesByCategory: [String: [Float]] = [:]
    private(set) var loadError: String?
    private(set) var isLoading = true
    private(set) var loadProgress: Double?
    private(set) var loadStatusMessage = "Preparing to read recording"
    private(set) var loadDetailMessage: String?

    /// Where a channel was plotted before `moveEEGChannelToPhysio` sent it to
    /// Physio, keyed by its stable name rather than index — index shifts on
    /// every move, name doesn't. `movePhysioChannelToEEG` was appending the
    /// returning channel's data back onto the EEG signal but never restoring
    /// its `sensorLayout`/`electrodeGeometry` entry, so a channel moved back
    /// stayed permanently stuck in the editor's "No plotted location" bucket
    /// — and repeated round trips could put two different channels' data
    /// under one fallback-generated display name ("Ch 241" appearing twice),
    /// since the fallback in `channelName(at:in:fallbackPrefix:)` names by
    /// current index, not identity (2026-08-16, manual test finding).
    @ObservationIgnored private var physioOriginPositions: [String: SensorPosition] = [:]
    @ObservationIgnored private var physioOriginGeometry: [String: SIMD3<Double>] = [:]

    @ObservationIgnored private var activeLoadRequestID = UUID()
    @ObservationIgnored private var loadTask: Task<LoadResult, Never>?
    @ObservationIgnored private var isClosed = false

    init(packageURL: URL, securityScopedURLs: [URL] = []) {
        self.packageURL = packageURL
        self.packageName = packageURL.lastPathComponent
        self.securityScopedURLs = securityScopedURLs
    }

    deinit {
        loadTask?.cancel()
    }

    @MainActor
    func loadIfNeeded() async {
        guard isLoading, signal == nil, loadError == nil, !isClosed else { return }

        let url = packageURL
        let scopedURLs = securityScopedURLs
        let requestID = UUID()
        activeLoadRequestID = requestID
        loadProgress = 0
        loadStatusMessage = "Opening \(packageName)"
        loadDetailMessage = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: SignalImportProgress) in
            guard self.isLoading, !self.isClosed, self.activeLoadRequestID == requestID else { return }
            self.loadProgress = update.fraction
            self.loadStatusMessage = update.message
            self.loadDetailMessage = update.detail
        }

        let progressHandler: @Sendable (SignalImportProgress) -> Void = { update in
            let clamped = min(max(update.fraction, 0), 1)
            progressContinuation.yield(SignalImportProgress(
                fraction: clamped,
                message: update.message,
                detail: update.detail
            ))
        }

        let worker = Task.detached(priority: .userInitiated) {
            Self.load(packageURL: url, securityScopedURLs: scopedURLs, progress: progressHandler)
        }
        loadTask = worker
        let result = await withTaskCancellationHandler(
            operation: {
                await worker.value
            },
            onCancel: {
                worker.cancel()
                progressContinuation.finish()
            }
        )
        progressContinuation.finish()
        progressTask.cancel()

        guard !Task.isCancelled, !isClosed, activeLoadRequestID == requestID else {
            if activeLoadRequestID == requestID {
                loadTask = nil
            }
            return
        }

        loadTask = nil
        signal = Self.applyingEventAnchorRules(to: result.signal)
        // Listed for Preferences ▸ Events, which needs the codes present in
        // real data and a handle to reapply edited rules. Weakly held there.
        OpenRecordingRegistry.shared.register(self)
        pnsSignal = result.pnsSignal
        sensorLayout = result.layout
        electrodeGeometry = result.geometry
        antiAliasTimingCorrection = result.antiAliasTimingCorrection
        if let signalURL = result.signal?.signalURL {
            noiseCurvesByCategory = NoiseSidecar.read(fromPackageContaining: signalURL) ?? [:]
        }
        loadError = result.error
        loadProgress = nil
        loadStatusMessage = result.error == nil ? "Loaded" : "Load failed"
        loadDetailMessage = result.antiAliasTimingCorrection?.loadingMessage
        isLoading = false
    }

    /// Re-reads the freshly-loaded signal's imported events under the user's
    /// event-anchor rules (Preferences ▸ Events).
    ///
    /// Applied here, once, rather than lazily wherever an anchor is read. The
    /// anchor decides cleaning windows, so a lazily-resolved one would make the
    /// preference a hidden input to every numerical result and let a later edit
    /// silently change what a replayed run produces. Baking it in at load means
    /// the events carried into `DefinedArtifact` — and from there into
    /// `eva_artifacts.json` — describe their own geometry.
    @MainActor
    static func applyingEventAnchorRules(to signal: MFFSignalData?) -> MFFSignalData? {
        guard let signal else { return nil }
        let ruleSet = EventAnchorSettings.shared.ruleSet
        guard !ruleSet.isEmpty else { return signal }
        return signal.replacingEvents(ruleSet.applied(to: signal.events))
    }

    /// Reapplies the current event-anchor rules to an already-open recording.
    ///
    /// Rules are baked in at load, so editing them does not retroactively change
    /// an open file — this is the explicit action that does, returning a short
    /// description of what changed for the process log, or `nil` when nothing
    /// did.
    @MainActor
    @discardableResult
    func reapplyEventAnchorRules() -> String? {
        guard let current = signal else { return nil }
        let ruleSet = EventAnchorSettings.shared.ruleSet
        let updated = ruleSet.applied(to: current.events)
        guard updated != current.events else { return nil }
        signal = current.replacingEvents(updated)
        return ruleSet.appliedSummary(for: updated)
    }

    @MainActor
    func tearDownForClose() {
        OpenRecordingRegistry.shared.unregister(self)
        isClosed = true
        activeLoadRequestID = UUID()
        loadTask?.cancel()
        loadTask = nil
        signal = nil
        pnsSignal = nil
        sensorLayout = nil
        electrodeGeometry = nil
        antiAliasTimingCorrection = nil
        noiseCurvesByCategory = [:]
        loadError = nil
        isLoading = false
        loadProgress = nil
        loadStatusMessage = "Closed"
        loadDetailMessage = nil
    }

    @MainActor
    @discardableResult
    func moveEEGChannelToPhysio(index: Int) throws -> String {
        guard let currentSignal = signal else { throw ChannelRoleEditError.missingEEGSignal }
        guard currentSignal.data.indices.contains(index),
              currentSignal.numberOfChannels == currentSignal.data.count else {
            throw ChannelRoleEditError.invalidChannel
        }
        guard currentSignal.numberOfChannels > 1 else {
            throw ChannelRoleEditError.cannotMoveLastEEGChannel
        }

        let movedSamples = currentSignal.data[index]
        let movedName = channelName(at: index, in: currentSignal, fallbackPrefix: "Ch")

        if let position = sensorLayout?.positions.first(where: { $0.channelIndex == index }) {
            physioOriginPositions[movedName] = position
        }
        if let geometryPosition = electrodeGeometry?.positions[index] {
            physioOriginGeometry[movedName] = geometryPosition
        }

        if let currentPNS = pnsSignal,
           !canAppend(samples: movedSamples, samplingRate: currentSignal.samplingRate, to: currentPNS) {
            throw ChannelRoleEditError.incompatiblePhysioTiming
        }

        var eegData = currentSignal.data
        eegData.remove(at: index)
        var eegNames = currentSignal.channelNames
        if eegNames?.indices.contains(index) == true {
            eegNames?.remove(at: index)
        }
        var impedances = currentSignal.impedancesKOhm
        if impedances?.indices.contains(index) == true {
            impedances?.remove(at: index)
        }

        let updatedSignal = MFFSignalData(
            signalURL: currentSignal.signalURL,
            signalType: currentSignal.signalType,
            numberOfChannels: currentSignal.numberOfChannels - 1,
            samplingRate: currentSignal.samplingRate,
            duration: currentSignal.duration,
            recordingStartTime: currentSignal.recordingStartTime,
            events: currentSignal.events,
            data: eegData,
            channelNames: eegNames,
            epochSegments: currentSignal.epochSegments,
            isSegmented: currentSignal.isSegmented,
            isAveraged: currentSignal.isAveraged,
            isGrandAverage: currentSignal.isGrandAverage,
            impedancesKOhm: impedances,
            acquisitionReference: currentSignal.acquisitionReference?.removingChannel(index),
            referenceState: currentSignal.referenceState
        )

        signal = updatedSignal
        pnsSignal = pnsSignalWithAppendedChannel(samples: movedSamples, name: movedName, basedOn: currentSignal)
        sensorLayout = sensorLayout?.removingChannel(index)
        electrodeGeometry = electrodeGeometry?.removingChannel(index)
        return movedName
    }

    @MainActor
    @discardableResult
    func movePhysioChannelToEEG(index: Int) throws -> String {
        guard let currentSignal = signal else { throw ChannelRoleEditError.missingEEGSignal }
        guard let currentPNS = pnsSignal else { throw ChannelRoleEditError.missingPhysioSignal }
        guard currentPNS.data.indices.contains(index),
              currentPNS.numberOfChannels == currentPNS.data.count else {
            throw ChannelRoleEditError.invalidChannel
        }

        let movedSamples = currentPNS.data[index]
        guard movedSamples.count == currentSignal.data.first?.count,
              samplingRatesMatch(currentPNS.samplingRate, currentSignal.samplingRate) else {
            throw ChannelRoleEditError.incompatibleEEGTiming
        }

        let movedName = channelName(at: index, in: currentPNS, fallbackPrefix: "PNS")
        var eegData = currentSignal.data
        eegData.append(movedSamples)
        var eegNames = currentSignal.channelNames ?? (0..<currentSignal.numberOfChannels).map { "Ch \($0 + 1)" }
        eegNames.append(movedName)
        var impedances = currentSignal.impedancesKOhm
        if impedances != nil {
            impedances?.append(.nan)
        }

        var pnsData = currentPNS.data
        pnsData.remove(at: index)
        var pnsNames = currentPNS.channelNames
        if pnsNames?.indices.contains(index) == true {
            pnsNames?.remove(at: index)
        }

        let updatedSignal = MFFSignalData(
            signalURL: currentSignal.signalURL,
            signalType: currentSignal.signalType,
            numberOfChannels: currentSignal.numberOfChannels + 1,
            samplingRate: currentSignal.samplingRate,
            duration: currentSignal.duration,
            recordingStartTime: currentSignal.recordingStartTime,
            events: currentSignal.events,
            data: eegData,
            channelNames: eegNames,
            epochSegments: currentSignal.epochSegments,
            isSegmented: currentSignal.isSegmented,
            isAveraged: currentSignal.isAveraged,
            isGrandAverage: currentSignal.isGrandAverage,
            impedancesKOhm: impedances,
            acquisitionReference: currentSignal.acquisitionReference,
            referenceState: currentSignal.referenceState
        )

        let updatedPNS: MFFSignalData?
        if pnsData.isEmpty {
            updatedPNS = nil
        } else {
            updatedPNS = MFFSignalData(
                signalURL: currentPNS.signalURL,
                signalType: currentPNS.signalType,
                numberOfChannels: currentPNS.numberOfChannels - 1,
                samplingRate: currentPNS.samplingRate,
                duration: currentPNS.duration,
                recordingStartTime: currentPNS.recordingStartTime,
                events: currentPNS.events,
                data: pnsData,
                channelNames: pnsNames
            )
        }

        signal = updatedSignal
        pnsSignal = updatedPNS

        // Restore whatever plotted position this channel had before it was
        // moved to Physio, if any — see `physioOriginPositions`'s doc
        // comment. The new index is always the last one: nothing before it
        // shifted, since this only ever appends.
        let newIndex = updatedSignal.numberOfChannels - 1
        if let origin = physioOriginPositions[movedName] {
            let restored = SensorPosition(channelIndex: newIndex, x: origin.x, y: origin.y)
            sensorLayout = SensorLayout(
                name: sensorLayout?.name ?? "",
                positions: (sensorLayout?.positions ?? []) + [restored],
                reference: sensorLayout?.reference
            )
        }
        if let origin = physioOriginGeometry[movedName] {
            var positions = electrodeGeometry?.positions ?? [:]
            positions[newIndex] = origin
            electrodeGeometry = ElectrodeGeometry(name: electrodeGeometry?.name ?? "", positions: positions)
        }

        return movedName
    }

    /// Appends externally-imported physio channels (e.g. from a GE scanner
    /// PPG/RESP log, or a Biopac export) to the PNS signal, creating one if
    /// none exists yet. Callers must already have resampled every channel to
    /// `samplingRate`, and matching the existing PNS signal's rate if one is
    /// present — this only re-validates that invariant, it doesn't resample.
    /// Each channel is padded/truncated to the existing signal's sample count
    /// (EEG's if there's no PNS yet) so every channel in the merged signal
    /// stays the same length, matching the convention `mergingWithSynthetic`
    /// already relies on for ICA-synthesized channels.
    @MainActor
    @discardableResult
    func appendImportedPhysioChannels(
        _ channels: [(name: String, samples: [Float])],
        samplingRate: Double
    ) -> Bool {
        guard !channels.isEmpty else { return false }
        if let currentPNS = pnsSignal, !samplingRatesMatch(currentPNS.samplingRate, samplingRate) {
            return false
        }

        let targetCount = pnsSignal?.data.first?.count ?? signal?.data.first?.count ?? channels[0].samples.count
        func fitted(_ samples: [Float]) -> [Float] {
            guard targetCount > 0, samples.count != targetCount else { return samples }
            if samples.count > targetCount { return Array(samples.prefix(targetCount)) }
            return samples + Array(repeating: samples.last ?? 0, count: targetCount - samples.count)
        }

        if let currentPNS = pnsSignal {
            var data = currentPNS.data
            var names = currentPNS.channelNames ?? (0..<currentPNS.numberOfChannels).map { "PNS \($0 + 1)" }
            for channel in channels {
                data.append(fitted(channel.samples))
                names.append(channel.name)
            }
            pnsSignal = MFFSignalData(
                signalURL: currentPNS.signalURL,
                signalType: currentPNS.signalType,
                numberOfChannels: currentPNS.numberOfChannels + channels.count,
                samplingRate: currentPNS.samplingRate,
                duration: currentPNS.duration,
                recordingStartTime: currentPNS.recordingStartTime,
                events: currentPNS.events,
                data: data,
                channelNames: names
            )
        } else {
            let anchor = signal
            pnsSignal = MFFSignalData(
                signalURL: anchor?.signalURL ?? packageURL,
                signalType: "Physio",
                numberOfChannels: channels.count,
                samplingRate: samplingRate,
                duration: anchor?.duration ?? (Double(targetCount) / samplingRate),
                recordingStartTime: anchor?.recordingStartTime,
                events: [],
                data: channels.map { fitted($0.samples) },
                channelNames: channels.map { $0.name }
            )
        }
        return true
    }

    private struct LoadResult: Sendable {
        var signal: MFFSignalData?
        var pnsSignal: MFFSignalData?
        var layout: SensorLayout?
        var geometry: ElectrodeGeometry?
        var antiAliasTimingCorrection: MFFAntiAliasTimingCorrection?
        var error: String?
    }

    private func pnsSignalWithAppendedChannel(
        samples: [Float],
        name: String,
        basedOn sourceSignal: MFFSignalData
    ) -> MFFSignalData {
        if let currentPNS = pnsSignal {
            var data = currentPNS.data
            data.append(samples)
            var names = currentPNS.channelNames ?? (0..<currentPNS.numberOfChannels).map { "PNS \($0 + 1)" }
            names.append(name)
            return MFFSignalData(
                signalURL: currentPNS.signalURL,
                signalType: currentPNS.signalType,
                numberOfChannels: currentPNS.numberOfChannels + 1,
                samplingRate: currentPNS.samplingRate,
                duration: currentPNS.duration,
                recordingStartTime: currentPNS.recordingStartTime,
                events: currentPNS.events,
                data: data,
                channelNames: names
            )
        }

        return MFFSignalData(
            signalURL: sourceSignal.signalURL,
            signalType: "Physio",
            numberOfChannels: 1,
            samplingRate: sourceSignal.samplingRate,
            duration: sourceSignal.duration,
            recordingStartTime: sourceSignal.recordingStartTime,
            events: sourceSignal.events,
            data: [samples],
            channelNames: [name]
        )
    }

    private func canAppend(samples: [Float], samplingRate: Double, to signal: MFFSignalData) -> Bool {
        guard let count = signal.data.first?.count else { return true }
        return samplingRatesMatch(signal.samplingRate, samplingRate) && count == samples.count
    }

    private func samplingRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.0001
    }

    private func channelName(at index: Int, in signal: MFFSignalData, fallbackPrefix: String) -> String {
        if signal.channelNames?.indices.contains(index) == true,
           let name = nonEmpty(signal.channelNames?[index]) {
            return name
        }
        return "\(fallbackPrefix) \(index + 1)"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated private static func load(
        packageURL: URL,
        securityScopedURLs: [URL] = [],
        progress: (@Sendable (SignalImportProgress) -> Void)? = nil
    ) -> LoadResult {
        let scopedCandidates = uniquedSecurityScopeURLs([packageURL] + securityScopedURLs)
        let activeScopes = scopedCandidates.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in activeScopes.reversed() {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try Task.checkCancellation()
            let imported = try SignalImportReader.load(from: packageURL, progress: progress)
            try Task.checkCancellation()
            return LoadResult(
                signal: imported.signal,
                pnsSignal: imported.pnsSignal,
                layout: imported.layout,
                geometry: imported.geometry,
                antiAliasTimingCorrection: imported.antiAliasTimingCorrection,
                error: nil
            )
        } catch is CancellationError {
            return LoadResult(
                signal: nil,
                layout: nil,
                geometry: nil,
                antiAliasTimingCorrection: nil,
                error: nil
            )
        } catch {
            return LoadResult(
                signal: nil,
                layout: nil,
                geometry: nil,
                antiAliasTimingCorrection: nil,
                error: error.localizedDescription
            )
        }
    }

    nonisolated private static func uniquedSecurityScopeURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

private extension SensorLayout {
    func removingChannel(_ removedIndex: Int) -> SensorLayout {
        let shiftedPositions = positions.compactMap { position -> SensorPosition? in
            guard position.channelIndex != removedIndex else { return nil }
            let shiftedIndex = position.channelIndex > removedIndex
                ? position.channelIndex - 1
                : position.channelIndex
            return SensorPosition(channelIndex: shiftedIndex, x: position.x, y: position.y)
        }
        .sorted { $0.channelIndex < $1.channelIndex }
        let shiftedReference = reference.flatMap { reference -> SensorReference? in
            guard reference.channelIndex != removedIndex else { return nil }
            return SensorReference(
                channelIndex: reference.channelIndex > removedIndex
                    ? reference.channelIndex - 1
                    : reference.channelIndex,
                name: reference.name,
                x: reference.x,
                y: reference.y
            )
        }
        return SensorLayout(name: name, positions: shiftedPositions, reference: shiftedReference)
    }
}

private extension EEGAcquisitionReference {
    func removingChannel(_ removedIndex: Int) -> EEGAcquisitionReference? {
        guard channelIndex != removedIndex else { return nil }
        return EEGAcquisitionReference(
            channelIndex: channelIndex > removedIndex ? channelIndex - 1 : channelIndex,
            name: name,
            isRecorded: isRecorded
        )
    }
}

private extension ElectrodeGeometry {
    func removingChannel(_ removedIndex: Int) -> ElectrodeGeometry {
        var shiftedPositions: [Int: SIMD3<Double>] = [:]
        for (channelIndex, position) in positions where channelIndex != removedIndex {
            let shiftedIndex = channelIndex > removedIndex ? channelIndex - 1 : channelIndex
            shiftedPositions[shiftedIndex] = position
        }
        return ElectrodeGeometry(name: name, positions: shiftedPositions)
    }
}
