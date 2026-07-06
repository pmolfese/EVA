//
//  GradientViewModel.swift
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
//  L4 store for the fMRI gradient-artifact-removal domain (AAS / FASTR / FARM /
//  Moosmann), extracted from WaveformView (REFACTOR.md slice 2). This is a
//  state-ownership extraction: the store holds the domain's parameters, run
//  state, and corrected outputs; WaveformView still drives the apply/clear
//  orchestration (it is deeply coupled to the recording, TR markers, and the
//  ICA / filter / artifact stages) and reads/writes the store.
//

import Combine
import SwiftUI

@MainActor
final class GradientViewModel: ObservableObject {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Results
    @Published var correctedSignal: MFFSignalData?
    @Published var correctedPNSSignal: MFFSignalData?

    // MARK: Run state
    @Published var isProcessing = false
    @Published var progress = 0.0
    @Published var statusMessage: String?
    @Published var statusIsError = false

    // MARK: UI state
    @Published var showsPopover = false
    @Published var showsMethodHelp = false
    @Published var showsMotionConfig = false

    // MARK: Parameters (portable → eva.xml)
    @Published var appliesToPNS = true
    @Published var windowBefore = GradientRemover.Window.default.before
    @Published var windowAfter = GradientRemover.Window.default.after
    @Published var trMarkerCode = "TREV"
    @Published var method = MRIGradientMethod.aas

    // FASTR / FARM / Moosmann parameters
    @Published var fastrSlices = 1
    @Published var fastrOBSAuto = true
    @Published var fastrANC = false
    @Published var fastrSubSample = true

    // Motion censoring
    @Published var excludeHighMotion = false
    @Published var motionParameters: MotionParameters?
    @Published var motionFDThreshold = 0.5
    @Published var motionRadiusMm = 50.0

    // TR-marker alignment
    @Published var skipStart = 0
    @Published var skipEnd = 0
    @Published var trSeconds = 0.0

    var isActive: Bool { correctedSignal != nil }

    /// Clears the corrected outputs and run state (used by "Remove Correction").
    func clearResults() {
        correctedSignal = nil
        correctedPNSSignal = nil
    }

    func resetForClose() {
        correctedSignal = nil
        correctedPNSSignal = nil
        isProcessing = false
        progress = 0
        statusMessage = nil
        statusIsError = false
        showsPopover = false
        showsMethodHelp = false
        showsMotionConfig = false
    }

    /// Volume indices flagged as high-motion (FD > threshold), or empty when the
    /// user hasn't enabled exclusion / motion isn't loaded.
    func highMotionVolumeSet() -> Set<Int> {
        guard excludeHighMotion, let motion = motionParameters, motion.count >= 2 else {
            return []
        }
        return Set(motion.volumesExceeding(threshold: motionFDThreshold, radiusMm: motionRadiusMm))
    }

    // MARK: - eva.xml bridge

    var parameters: [String: String] {
        var params: [String: String] = [
            "method": method.rawValue,
            "trMarkerCode": trMarkerCode,
            "windowBefore": "\(windowBefore)",
            "windowAfter": "\(windowAfter)"
        ]
        if method.isFASTR {
            params["slices"] = "\(fastrSlices)"
            params["obs"] = "\(fastrOBSAuto)"
            params["anc"] = "\(fastrANC)"
        }
        if excludeHighMotion {
            params["motionFDThreshold"] = String(format: "%.2f", motionFDThreshold)
        }
        return params
    }

    /// Deserialization inverse of `parameters` for Copy Processing / replay.
    /// Missing keys leave the current value untouched. Motion data itself is
    /// subject-specific (loaded per-recording), so only the threshold is carried;
    /// exclusion no-ops gracefully when the target file has no motion params.
    func apply(parameters p: [String: String]) {
        if let m = p["method"].flatMap(MRIGradientMethod.init(rawValue:)) { method = m }
        if let c = p["trMarkerCode"] { trMarkerCode = c }
        if let v = p["windowBefore"].flatMap(Int.init) { windowBefore = v }
        if let v = p["windowAfter"].flatMap(Int.init) { windowAfter = v }
        if let v = p["slices"].flatMap(Int.init) { fastrSlices = v }
        if let v = p["obs"] { fastrOBSAuto = (v == "true") }
        if let v = p["anc"] { fastrANC = (v == "true") }
        if let v = p["motionFDThreshold"].flatMap(Double.init) {
            motionFDThreshold = v
            excludeHighMotion = true
        }
    }

    // MARK: - Apply (the transform itself)

    /// Runs the configured method (AAS or FASTR/FARM/Moosmann) against `signal`
    /// (and `pnsSignal`, if `appliesToPNS`), updating `correctedSignal`/
    /// `correctedPNSSignal`. `onApplied` carries cross-domain invalidation
    /// (ICA/filter outputs computed on the old base are now stale) back to the
    /// caller — this store stays focused on its own domain, same pattern as
    /// `FilterViewModel.apply(to:pnsInput:onApplied:)`.
    ///
    /// This method itself has no `recordingSessionID` staleness guard: it only
    /// ever writes into `self`, which is safe regardless of caller. A caller
    /// whose VM instance can outlive a single run (the interactive Apply
    /// button, whose `GradientViewModel` survives a same-window "Close
    /// Recording" while a Task may still be in flight) must still guard the
    /// *outer* Task against that with its own session check before/after
    /// awaiting this call — see `MRIGradientArtifactViews.applyGradientCorrection`
    /// for that caller-side guard. A one-shot headless caller (`ProcessingCore`)
    /// doesn't need one: its VMs are fresh per run and never "closed" mid-flight.
    func apply(
        to signal: MFFSignalData,
        pnsSignal: MFFSignalData?,
        onApplied: @escaping () -> Void = {}
    ) async {
        switch method {
        case .aas, .mas, .mar:
            await removeGradientArtifact(from: signal, pnsSignal: pnsSignal, onApplied: onApplied)
        case .fastr, .moosmann, .farm:
            await removeGradientArtifactFASTR(from: signal, pnsSignal: pnsSignal, onApplied: onApplied)
        }
    }

    /// TR marker samples for `signal`, filtered to `trMarkerCode` and trimmed
    /// by `skipStart`/`skipEnd`.
    private func trimmedTRMarkers(in signal: MFFSignalData, samplingRate: Double? = nil) -> [Int] {
        let rate = samplingRate ?? signal.samplingRate
        let all = signal.events
            .filter { $0.code == trMarkerCode }
            .map { Int(($0.beginTimeSeconds * rate).rounded()) }
            .sorted()
        guard all.count > skipStart + skipEnd else { return [] }
        return Array(all[skipStart..<(all.count - skipEnd)])
    }

    private func removeGradientArtifact(
        from signal: MFFSignalData,
        pnsSignal: MFFSignalData?,
        onApplied: @escaping () -> Void
    ) async {
        let trSamples = trimmedTRMarkers(in: signal)
        let window = GradientRemover.Window(before: windowBefore, after: windowAfter)
        let excludedTRs = highMotionVolumeSet()
        let excludedCount = excludedTRs.count
        isProcessing = true
        progress = 0
        statusMessage = nil

        let pnsInput = appliesToPNS ? pnsSignal : nil
        let pnsTRSamples = pnsInput.map {
            trimmedTRMarkers(in: signal, samplingRate: $0.samplingRate)
        } ?? []

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.progress = fraction
        }

        let reducer: GradientRemover.TemplateReducer = method == .aas ? .weightedMean : .median
        let fit: GradientRemover.TemplateFit = method == .mar ? .regress : .subtract

        do {
            let hasPNS = pnsInput != nil
            let sourceData = signal.data
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let correctedData = try GradientRemover.correct(channels: sourceData, trSamples: trSamples, window: window, excludedTRs: excludedTRs, reducer: reducer, fit: fit) { fraction in
                    progressContinuation.yield(hasPNS ? 0.70 * fraction : fraction)
                }
                try Task.checkCancellation()
                let correctedPNSData: [[Float]]?
                if let pnsInput {
                    correctedPNSData = try GradientRemover.correct(channels: pnsInput.data, trSamples: pnsTRSamples, window: window, excludedTRs: excludedTRs, reducer: reducer, fit: fit) { fraction in
                        progressContinuation.yield(0.70 + 0.30 * fraction)
                    }
                } else {
                    correctedPNSData = nil
                }
                try Task.checkCancellation()
                return (correctedData, correctedPNSData)
            }
            let result = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )
            progressContinuation.finish()
            progressTask.cancel()
            guard !Task.isCancelled else { isProcessing = false; return }

            correctedSignal = signal.replacingData(result.0)
            if let pnsInput, let correctedPNSData = result.1 {
                correctedPNSSignal = pnsInput.replacingData(correctedPNSData, signalTypeSuffix: "MRI")
            } else {
                correctedPNSSignal = nil
            }
            statusMessage = "Applied \(method.rawValue) gradient artifact correction (\(trMarkerCode) markers, template window \(window.before) pre / \(window.after) post TRs\(excludedCount > 0 ? ", \(excludedCount) high-motion TRs excluded" : "")\(pnsInput == nil ? "" : " + PNS"))."
            statusIsError = false
            onApplied()
        } catch is CancellationError {
            progressContinuation.finish()
            progressTask.cancel()
        } catch {
            progressContinuation.finish()
            progressTask.cancel()
            statusMessage = error.localizedDescription
            statusIsError = true
        }
        isProcessing = false
    }

    private func removeGradientArtifactFASTR(
        from signal: MFFSignalData,
        pnsSignal: MFFSignalData?,
        onApplied: @escaping () -> Void
    ) async {
        let trSamples = trimmedTRMarkers(in: signal)
        var config = FastrCorrector.Config()
        config.numberOfSlices = max(1, fastrSlices)
        config.subSampleAlignment = fastrSubSample
        config.obs = fastrOBSAuto ? .auto : .off
        config.anc = fastrANC
        if method == .moosmann {
            config.templateScheme = .moosmann
            config.motion = motionParameters?.samples
            config.motionThresholdMm = motionFDThreshold
            config.motionRadiusMm = motionRadiusMm
        } else if method == .farm {
            config.templateScheme = .farm
        }
        // Optional motion-censoring (Moosmann excludes high-motion volumes
        // intrinsically, so only apply the explicit set for the other methods).
        if method != .moosmann {
            config.censoredVolumes = highMotionVolumeSet()
        }
        let censoredCount = config.censoredVolumes.count
        let methodName = method.rawValue
        let configCopy = config
        let slices = config.numberOfSlices

        isProcessing = true
        progress = 0
        statusMessage = nil

        let pnsInput = appliesToPNS ? pnsSignal : nil
        let pnsTRSamples = pnsInput.map {
            trimmedTRMarkers(in: signal, samplingRate: $0.samplingRate)
        } ?? []

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.progress = fraction
        }

        do {
            let hasPNS = pnsInput != nil
            let sourceData = signal.data
            let samplingRate = signal.samplingRate
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let correctedData = try FastrCorrector.correct(
                    channels: sourceData,
                    volumeTriggers: trSamples,
                    config: configCopy,
                    samplingRate: samplingRate
                ) { fraction in
                    progressContinuation.yield(hasPNS ? 0.70 * fraction : fraction)
                }
                try Task.checkCancellation()
                let correctedPNSData: [[Float]]?
                if let pnsInput {
                    correctedPNSData = try FastrCorrector.correct(
                        channels: pnsInput.data,
                        volumeTriggers: pnsTRSamples,
                        config: configCopy,
                        samplingRate: pnsInput.samplingRate
                    ) { fraction in
                        progressContinuation.yield(0.70 + 0.30 * fraction)
                    }
                } else {
                    correctedPNSData = nil
                }
                try Task.checkCancellation()
                return (correctedData, correctedPNSData)
            }
            let result = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )
            progressContinuation.finish()
            progressTask.cancel()
            guard !Task.isCancelled else { isProcessing = false; return }

            correctedSignal = signal.replacingData(result.0)
            if let pnsInput, let correctedPNSData = result.1 {
                correctedPNSSignal = pnsInput.replacingData(correctedPNSData, signalTypeSuffix: "MRI")
            } else {
                correctedPNSSignal = nil
            }
            statusMessage = "Applied \(methodName) correction (\(trMarkerCode) markers, \(slices) slice\(slices == 1 ? "" : "s")/volume\(fastrOBSAuto ? ", OBS" : "")\(fastrANC ? ", ANC" : "")\(censoredCount > 0 ? ", \(censoredCount) high-motion TRs excluded" : "")\(pnsInput == nil ? "" : " + PNS"))."
            statusIsError = false
            onApplied()
        } catch is CancellationError {
            progressContinuation.finish()
            progressTask.cancel()
        } catch {
            progressContinuation.finish()
            progressTask.cancel()
            statusMessage = error.localizedDescription
            statusIsError = true
        }
        isProcessing = false
    }
}
