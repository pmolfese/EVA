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

import SwiftUI

enum FastrDonorSelection: String, CaseIterable, Identifiable, Sendable {
    case methodDefault
    case bergenRSquare

    var id: String { rawValue }

    var label: String {
        switch self {
        case .methodDefault: return "Default"
        case .bergenRSquare: return "BERGEN r²"
        }
    }

    var help: String {
        switch self {
        case .methodDefault:
            return "Use the selected method's donor rule: temporal FASTR, FARM correlation, or Moosmann RP-info."
        case .bergenRSquare:
            return "Rank FASTR-family donors by BERGEN-style squared correlation."
        }
    }
}

@MainActor
@Observable
final class GradientViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Results
    var correctedSignal: MFFSignalData?
    var correctedPNSSignal: MFFSignalData?

    // MARK: Run state
    var isProcessing = false
    var progress = 0.0
    var operationProgress: OperationProgress?
    var statusMessage: String?
    var statusIsError = false

    // MARK: UI state
    var showsPopover = false
    var showsMethodHelp = false
    var showsFastrDonorHelp = false
    var showsFastrOptionsHelp = false
    var showsOBSRandomHelp = false
    var showsANCHighPassHelp = false
    var showsMotionConfig = false

    // MARK: Parameters (portable → eva.xml)
    var appliesToPNS = true
    var windowBefore = GradientRemover.Window.default.before
    var windowAfter = GradientRemover.Window.default.after
    var trMarkerCode = "TREV"
    var method = MRIGradientMethod.aas

    // FASTR-family parameters and shared optional Metal execution
    var fastrSlices = 1
    var fastrOBSAuto = true
    var fastrANC = false
    var fastrSubSample = true
    var fastrUseFacetWindow = false
    var fastrOBSRandomSampling = false
    var fastrANCSliceHighPass = false
    var fastrUseMetal = false
    var fastrDonorSelection = FastrDonorSelection.methodDefault

    var fastrUsesBergenRSquareDonors: Bool {
        get { fastrDonorSelection == .bergenRSquare }
        set { fastrDonorSelection = newValue ? .bergenRSquare : .methodDefault }
    }

    // Motion censoring
    var excludeHighMotion = false
    var motionParameters: MotionParameters?
    var motionFileFormat = MotionFileFormat.auto
    var motionFDThreshold = 0.5
    var motionRadiusMm = 50.0
    var moosmannMotionMetric = FastrCorrector.MotionMetric.translationOnly

    // TR-marker alignment
    var skipStart = 0
    var skipEnd = 0
    var trSeconds = 0.0

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
        operationProgress = nil
        statusMessage = nil
        statusIsError = false
        showsPopover = false
        showsMethodHelp = false
        showsFastrDonorHelp = false
        showsFastrOptionsHelp = false
        showsOBSRandomHelp = false
        showsANCHighPassHelp = false
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
            params["subSample"] = "\(fastrSubSample)"
            params["facetWindow"] = "\(fastrUseFacetWindow)"
            params["obsRandomSampling"] = "\(fastrOBSRandomSampling)"
            params["ancSliceHighPass"] = "\(fastrANCSliceHighPass)"
            params["fastrDonorSelection"] = fastrDonorSelection.rawValue
            params["bergenRSquareDonors"] = "\(fastrUsesBergenRSquareDonors)"
            params["moosmannMotionMetric"] = moosmannMotionMetric.rawValue
        }
        if method.isFASTR || method == .mas || method == .mar {
            params["metal"] = "\(fastrUseMetal)"
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
        if let v = p["subSample"] { fastrSubSample = (v == "true") }
        if let v = p["facetWindow"] { fastrUseFacetWindow = (v == "true") }
        if let v = p["obsRandomSampling"] { fastrOBSRandomSampling = (v == "true") }
        if let v = p["ancSliceHighPass"] { fastrANCSliceHighPass = (v == "true") }
        if let v = p["metal"] { fastrUseMetal = (v == "true") }
        if let v = p["fastrDonorSelection"].flatMap(FastrDonorSelection.init(rawValue:)) {
            fastrDonorSelection = v
        } else if let v = p["bergenRSquareDonors"] {
            fastrUsesBergenRSquareDonors = (v == "true")
        }
        if let v = p["moosmannMotionMetric"].flatMap(FastrCorrector.MotionMetric.init(rawValue:)) {
            moosmannMotionMetric = v
        }
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
        progress = 0.02
        statusMessage = nil

        let pnsInput = appliesToPNS ? pnsSignal : nil
        let pnsTRSamples = pnsInput.map {
            trimmedTRMarkers(in: signal, samplingRate: $0.samplingRate)
        } ?? []

        let reducer: GradientRemover.TemplateReducer = method == .aas ? .weightedMean : .median
        let fit: GradientRemover.TemplateFit = method == .mar ? .regress : .subtract
        let donorSelection: GradientRemover.DonorSelection = method == .aas ? .sideWindow : .amriMovingWindow
        let usesMetal = (method == .mas || method == .mar) && fastrUseMetal
        let computeBackend: GradientRemover.ComputeBackend = usesMetal ? .metal : .cpu
        let hasPNS = pnsInput != nil
        beginOperationProgress(
            subtitle: "\(method.rawValue) · \(usesMetal && GradientRemoverMetalBackend.isAvailable ? "Metal GPU" : "CPU")",
            hasPNS: hasPNS,
            phase: "Preparing TR grid and motion exclusions"
        )
        let eegChannelCount = sourceDataChannelCount(signal)
        let pnsChannelCount = pnsInput?.data.count ?? 0
        let correctionPhase = method == .mar
            ? "Building median templates and fitting MAR"
            : "Building artifact templates"
        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.updateCorrectionProgress(
                fraction,
                hasPNS: hasPNS,
                eegChannels: eegChannelCount,
                pnsChannels: pnsChannelCount,
                phase: correctionPhase
            )
        }

        do {
            let sourceData = signal.data
            let samplingRate = signal.samplingRate
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let correctedData = try GradientRemover.correct(channels: sourceData, trSamples: trSamples, window: window, excludedTRs: excludedTRs, reducer: reducer, fit: fit, donorSelection: donorSelection, computeBackend: computeBackend, samplingRate: samplingRate) { fraction in
                    progressContinuation.yield(hasPNS ? 0.70 * fraction : fraction)
                }
                try Task.checkCancellation()
                let correctedPNSData: [[Float]]?
                if let pnsInput {
                    correctedPNSData = try GradientRemover.correct(channels: pnsInput.data, trSamples: pnsTRSamples, window: window, excludedTRs: excludedTRs, reducer: reducer, fit: fit, donorSelection: donorSelection, computeBackend: computeBackend, samplingRate: pnsInput.samplingRate) { fraction in
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
            guard !Task.isCancelled else {
                isProcessing = false
                operationProgress = nil
                return
            }

            updateFinalizingProgress()

            correctedSignal = signal.replacingData(result.0)
            if let pnsInput, let correctedPNSData = result.1 {
                correctedPNSSignal = pnsInput.replacingData(correctedPNSData, signalTypeSuffix: "MRI")
            } else {
                correctedPNSSignal = nil
            }
            let backendDescription = usesMetal && GradientRemoverMetalBackend.isAvailable ? ", Metal GPU" : ""
            statusMessage = "Applied \(method.rawValue) gradient artifact correction (\(trMarkerCode) markers, template window \(window.before) pre / \(window.after) post TRs\(backendDescription)\(excludedCount > 0 ? ", \(excludedCount) high-motion TRs excluded" : "")\(pnsInput == nil ? "" : " + PNS"))."
            statusIsError = false
            progress = 1
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
        operationProgress = nil
    }

    private func removeGradientArtifactFASTR(
        from signal: MFFSignalData,
        pnsSignal: MFFSignalData?,
        onApplied: @escaping () -> Void
    ) async {
        let trSamples = trimmedTRMarkers(in: signal)
        var config = FastrCorrector.Config()
        config.numberOfSlices = max(1, fastrSlices)
        config.averagingWindowBefore = max(0, windowBefore)
        config.averagingWindowAfter = max(0, windowAfter)
        config.averagingWindow = fastrUseFacetWindow ? 30 : max(1, windowBefore + windowAfter)
        config.useFacetAveragingWindow = fastrUseFacetWindow
        config.subSampleAlignment = fastrSubSample
        config.obs = fastrOBSAuto ? .auto : .off
        config.randomizeOBSEpochSelection = fastrOBSRandomSampling
        config.anc = fastrANC
        config.ancHighPassMode = fastrANCSliceHighPass ? .sliceTriggerDependent : .fixed2Hz
        config.computeBackend = fastrUseMetal ? .metal : .cpu
        config.usesBergenRSquareDonors = fastrUsesBergenRSquareDonors
        if method == .moosmann {
            config.templateScheme = .moosmann
            config.motion = motionParameters?.samples
            config.motionThresholdMm = motionFDThreshold
            config.moosmannMotionMetric = moosmannMotionMetric
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
        progress = 0.02
        statusMessage = nil

        let pnsInput = appliesToPNS ? pnsSignal : nil
        let pnsTRSamples = pnsInput.map {
            trimmedTRMarkers(in: signal, samplingRate: $0.samplingRate)
        } ?? []

        let hasPNS = pnsInput != nil
        beginOperationProgress(
            subtitle: "\(methodName) · \(fastrUseMetal && FastrCorrector.isMetalAvailable ? "Metal GPU" : "CPU")",
            hasPNS: hasPNS,
            phase: "Preparing triggers and artifact alignment"
        )
        let eegChannelCount = sourceDataChannelCount(signal)
        let pnsChannelCount = pnsInput?.data.count ?? 0
        let correctionPhase = fastrOBSAuto
            ? "Building templates and fitting OBS"
            : "Building and subtracting artifact templates"
        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.updateCorrectionProgress(
                fraction,
                hasPNS: hasPNS,
                eegChannels: eegChannelCount,
                pnsChannels: pnsChannelCount,
                phase: correctionPhase
            )
        }

        do {
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
            guard !Task.isCancelled else {
                isProcessing = false
                operationProgress = nil
                return
            }

            updateFinalizingProgress()

            correctedSignal = signal.replacingData(result.0)
            if let pnsInput, let correctedPNSData = result.1 {
                correctedPNSSignal = pnsInput.replacingData(correctedPNSData, signalTypeSuffix: "MRI")
            } else {
                correctedPNSSignal = nil
            }
            let windowDescription = fastrUseFacetWindow ? "FACET AvgWindow 30" : "\(windowBefore) pre / \(windowAfter) post"
            let obsDescription = fastrOBSAuto ? ", OBS\(fastrOBSRandomSampling ? " random" : "")" : ""
            let ancDescription = fastrANC ? ", ANC\(fastrANCSliceHighPass ? " slice-rate HPF" : "")" : ""
            let backendDescription = fastrUseMetal && FastrCorrector.isMetalAvailable ? ", Metal GPU" : ""
            statusMessage = "Applied \(methodName) correction (\(trMarkerCode) markers, \(slices) slice\(slices == 1 ? "" : "s")/volume, template window \(windowDescription)\(fastrUsesBergenRSquareDonors ? ", BERGEN r² donors" : "")\(obsDescription)\(ancDescription)\(backendDescription)\(censoredCount > 0 ? ", \(censoredCount) high-motion TRs excluded" : "")\(pnsInput == nil ? "" : " + PNS"))."
            statusIsError = false
            progress = 1
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
        operationProgress = nil
    }

    private func sourceDataChannelCount(_ signal: MFFSignalData) -> Int {
        signal.data.count
    }

    private func beginOperationProgress(subtitle: String, hasPNS: Bool, phase: String) {
        var stages = ["Preparing", "EEG correction"]
        if hasPNS { stages.append("PNS correction") }
        stages.append("Finalizing")
        operationProgress = .started(
            source: "MRI",
            title: "MRI Gradient Removal",
            subtitle: subtitle,
            phase: phase,
            stages: stages
        ).updating(fraction: 0.02, phase: phase, activeStage: 0)
    }

    private func updateCorrectionProgress(
        _ workerFraction: Double,
        hasPNS: Bool,
        eegChannels: Int,
        pnsChannels: Int,
        phase: String
    ) {
        let bounded = min(max(workerFraction, 0), 1)
        let isPNS = hasPNS && bounded >= 0.70
        let localFraction = isPNS
            ? min(max((bounded - 0.70) / 0.30, 0), 1)
            : min(max(bounded / (hasPNS ? 0.70 : 1), 0), 1)
        let count = isPNS ? pnsChannels : eegChannels
        let completed = min(count, max(0, Int((localFraction * Double(count)).rounded())))
        let target = isPNS ? "PNS" : "EEG"
        let displayFraction = 0.06 + 0.88 * bounded
        progress = displayFraction
        let stage = isPNS ? 2 : 1
        operationProgress = operationProgress?.updating(
            fraction: displayFraction,
            phase: isPNS ? "Correcting PNS channels" : phase,
            detail: count > 0 ? "\(target) channels \(completed) of \(count)" : nil,
            activeStage: stage
        )
    }

    private func updateFinalizingProgress() {
        progress = 0.98
        guard let current = operationProgress else { return }
        operationProgress = current.updating(
            fraction: 0.98,
            phase: "Finalizing corrected signal",
            activeStage: current.stages.count - 1
        )
    }
}
