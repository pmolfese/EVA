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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Non-document app model for opening and viewing EEG recordings.
//

import Combine
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
final class MFFRecording: ObservableObject, Identifiable {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    let id = UUID()
    let packageURL: URL
    let packageName: String
    private let securityScopedURLs: [URL]

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

    init(packageURL: URL, securityScopedURLs: [URL] = []) {
        self.packageURL = packageURL
        self.packageName = packageURL.lastPathComponent
        self.securityScopedURLs = securityScopedURLs
    }

    @MainActor
    func loadIfNeeded() async {
        guard isLoading, signal == nil, loadError == nil else { return }

        let url = packageURL
        let scopedURLs = securityScopedURLs
        objectWillChange.send()
        loadProgress = 0
        loadStatusMessage = "Opening \(packageName)"
        loadDetailMessage = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: SignalImportProgress) in
            guard self.isLoading else { return }
            self.objectWillChange.send()
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

        let result = await Task.detached(priority: .userInitiated) {
            Self.load(packageURL: url, securityScopedURLs: scopedURLs, progress: progressHandler)
        }.value
        progressContinuation.finish()
        progressTask.cancel()

        objectWillChange.send()
        signal = result.signal
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
            impedancesKOhm: impedances
        )

        objectWillChange.send()
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
            impedancesKOhm: impedances
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

        objectWillChange.send()
        signal = updatedSignal
        pnsSignal = updatedPNS
        return movedName
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
            let imported = try SignalImportReader.load(from: packageURL, progress: progress)
            return LoadResult(
                signal: imported.signal,
                pnsSignal: imported.pnsSignal,
                layout: imported.layout,
                geometry: imported.geometry,
                antiAliasTimingCorrection: imported.antiAliasTimingCorrection,
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
        return SensorLayout(name: name, positions: shiftedPositions)
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
