//
//  FilterViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for the band-pass / line-noise / average-reference filtering domain,
//  extracted from WaveformView (first slice of the ProcessingPipeline refactor —
//  see REFACTOR.md). Owns the filter parameters, run state, and the filtered
//  outputs, and orchestrates the L3 `EEGSignalFilter` engine. Cross-domain
//  invalidation (artifact cleaning, epochs, interpolations) is delegated back to
//  the view via the `onApplied` / `onCleared` callbacks so this store stays
//  focused until `RecordingStore` lands.
//

import SwiftUI

private enum FilterViewModelError: LocalizedError {
    case invalidCutoff(field: String, value: String)
    case noFilterOperation

    var errorDescription: String? {
        switch self {
        case let .invalidCutoff(field, value):
            return "\(field) cutoff '\(value)' is not a valid number. Leave it blank to turn that cutoff off."
        case .noFilterOperation:
            return "Enter a high-pass or low-pass cutoff, enable line-noise filtering, or enable average reference."
        }
    }
}

private struct FilterCutoffs: Sendable {
    var highPassHz: Double?
    var lowPassHz: Double?

    var hasFrequencyFilter: Bool {
        highPassHz != nil || lowPassHz != nil
    }
}

@MainActor
@Observable
final class FilterViewModel {
    /// Held directly (not threaded through per-call parameters) so this VM can
    /// read channel exclusions itself — the first slice of the RecordingStore
    /// direct-injection pass (REFACTOR.md). Lets a future consumer (a second
    /// averagedView window, a headless path) construct this VM against a
    /// RecordingStore without going through WaveformView.
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
        let d = ProcessingDefaults.shared
        highPassCutoffText = Self.cutoffText(d.filterHighPassHz)
        lowPassCutoffText = Self.cutoffText(d.filterLowPassHz)
        notch60HzEnabled = d.filterNotch60
        averageReference = d.filterAverageReference
        filterFamily = FilterFamily(rawValue: d.filterDefaultFamily) ?? .iir
    }

    // MARK: Parameters (portable → eva.xml / replay)
    var highPassCutoffText = "0.1"
    var lowPassCutoffText = "30"
    var highPassSlope = FilterSlope.dB24
    var lowPassSlope = FilterSlope.dB24
    /// Filter implementation family. `.iir` reproduces the historical behavior;
    /// `.fir` is linear-phase FIR; `.auto` is the Net Station hybrid (IIR
    /// high-pass below the crossover, FIR elsewhere). Applied to both edges.
    var filterFamily = FilterFamily.iir
    /// Crossover (Hz) below which an `.auto` high-pass stays IIR.
    var firCrossoverHz = EEGSignalFilter.defaultFIRCrossoverHz
    /// Explicit FIR transition-band width (Hz); nil = auto (fraction of cutoff).
    var firTransitionHz: Double?
    /// When on (and the FIR family is selected), the line-noise notch is applied
    /// as a linear-phase FIR band-stop instead of the default zero-phase IIR
    /// biquad. FIR is markedly more expensive; default off.
    var notchUsesFIR = false
    var lineNoiseMode = FilterLineNoiseMode.off
    var lineNoiseFrequency = 60.0
    var lineNoiseHarmonics = 2
    var lineNoiseWindowSeconds = 4.0
    var lineNoiseStrength = 1.0
    var averageReference = false
    var filterPNS = true
    var precision = FilterPrecision.auto

    // MARK: Run state
    var isFiltering = false
    var progress = 0.0
    /// Forwards into the shared `OperationProgressCenter` so the status area has
    /// one source to read. See `OperationProgressCenter`.
    var operationProgress: OperationProgress? {
        get { store.operationProgress.progress(for: Self.progressSource) }
        set { store.operationProgress.set(newValue, for: Self.progressSource) }
    }
    static let progressSource = "Filter"
    var statusMessage: String?
    var statusIsError = false

    // MARK: Results
    /// Filtered EEG (was `filteredSignal`).
    var output: MFFSignalData?
    /// Filtered PNS (was `filteredPNSSignal`).
    var pnsOutput: MFFSignalData?
    /// Source signal type of the PNS input, for change detection.
    var pnsInputSignalType: String?

    @ObservationIgnored private var activeRequestID = UUID()
    @ObservationIgnored private var activeWorker: Task<([[Float]], [[Float]]?), Error>?

    var isActive: Bool { output != nil }

    /// Compatibility bridge for code/tests that still treat the high-pass edge as
    /// the old "low cutoff" number.
    var lowCutoff: Double {
        get { highPassCutoff ?? 0.1 }
        set { highPassCutoffText = Self.cutoffText(newValue) }
    }

    /// Compatibility bridge for code/tests that still treat the low-pass edge as
    /// the old "high cutoff" number.
    var highCutoff: Double {
        get { lowPassCutoff ?? 30 }
        set { lowPassCutoffText = Self.cutoffText(newValue) }
    }

    var highPassCutoff: Double? {
        Self.optionalCutoffValue(from: highPassCutoffText)
    }

    var lowPassCutoff: Double? {
        Self.optionalCutoffValue(from: lowPassCutoffText)
    }

    // MARK: Derived

    var activeLineNoiseMode: FilterLineNoiseMode { lineNoiseMode }

    /// The notch is applied as FIR only when it is active, the toggle is on, and
    /// the FIR family is selected — otherwise it stays a zero-phase IIR biquad.
    var notchIsFIREffective: Bool {
        lineNoiseMode == .notch && notchUsesFIR && filterFamily == .fir
    }

    /// Compatibility bridge for older call sites and serialized parameters that
    /// represented notch filtering with a separate Boolean.
    var notch60HzEnabled: Bool {
        get { lineNoiseMode == .notch }
        set {
            if newValue {
                if lineNoiseMode != .notch { lineNoiseMode = .notch }
            } else if lineNoiseMode == .notch {
                lineNoiseMode = .off
            }
        }
    }

    var frequencySummary: String? {
        guard let cutoffs = try? currentCutoffs() else { return "Invalid cutoff" }
        switch (cutoffs.highPassHz, cutoffs.lowPassHz) {
        case let (highPass?, lowPass?):
            return "\(methodLabel(highPass: highPass, lowPass: lowPass)) \(Self.formattedCutoff(highPass))-\(Self.formattedCutoff(lowPass)) Hz"
        case let (highPass?, nil):
            return "\(methodLabel(highPass: highPass, lowPass: nil)) high-pass \(Self.formattedCutoff(highPass)) Hz"
        case let (nil, lowPass?):
            return "\(methodLabel(highPass: nil, lowPass: lowPass)) low-pass \(Self.formattedCutoff(lowPass)) Hz"
        case (nil, nil):
            return nil
        }
    }

    /// Human-readable design label for the active family and cutoffs. `.auto`
    /// resolves per edge, so a mixed hybrid reads e.g. "FIR (IIR HP)".
    private func methodLabel(highPass: Double?, lowPass: Double?) -> String {
        switch filterFamily {
        case .iir:
            return "Butterworth"
        case .fir:
            return "FIR"
        case .auto:
            let hpIsIIR = highPass.map { $0 < firCrossoverHz } ?? false
            return hpIsIIR ? "FIR (IIR HP)" : "FIR"
        }
    }

    var activeFilterSummary: String {
        var parts: [String] = []
        if let frequencySummary {
            parts.append(frequencySummary)
        }
        if let lineNoiseDescription {
            parts.append(lineNoiseDescription)
        }
        if averageReference {
            parts.append("average reference")
        }
        return parts.isEmpty ? "No filter" : parts.joined(separator: " + ")
    }

    var lineNoiseSummary: String {
        lineNoiseDescription.map { " + \($0)" } ?? ""
    }

    private var lineNoiseDescription: String? {
        switch activeLineNoiseMode {
        case .off:
            return nil
        case .notch:
            if notchUsesFIR, filterFamily == .fir {
                let harmonics = lineNoiseHarmonics > 1 ? " x\(lineNoiseHarmonics)" : ""
                return "FIR \(String(format: "%.1f", lineNoiseFrequency)) Hz notch\(harmonics)"
            }
            return "IIR \(String(format: "%.1f", lineNoiseFrequency)) Hz notch"
        case .adaptiveCleanLine:
            let harmonics = lineNoiseHarmonics > 1 ? " x\(lineNoiseHarmonics)" : ""
            return "CleanLine \(String(format: "%.1f", lineNoiseFrequency)) Hz\(harmonics)"
        }
    }

    func resetToDefaults() {
        highPassCutoffText = "0.1"
        lowPassCutoffText = "30"
        lineNoiseMode = .off
        lineNoiseFrequency = 60
        lineNoiseHarmonics = 2
        lineNoiseWindowSeconds = 4
        lineNoiseStrength = 1
        averageReference = false
        precision = .auto
    }

    // MARK: - eva.xml / replay bridge

    /// Portable parameters for the eva.xml `filter` step.
    var parameters: [String: String] {
        let cutoffs = try? currentCutoffs()
        var params: [String: String] = ["averageReference": "\(averageReference)"]
        if let highPassHz = cutoffs?.highPassHz {
            params["highPassHz"] = String(format: "%.3g", highPassHz)
        }
        if let lowPassHz = cutoffs?.lowPassHz {
            params["lowPassHz"] = String(format: "%.3g", lowPassHz)
        }
        params["highPassSlope"] = "\(highPassSlope.rawValue)"
        params["lowPassSlope"] = "\(lowPassSlope.rawValue)"
        // Always record the filter family — including the explicit "iir" label —
        // so eva.xml and the log_ file state the filter style unambiguously. This
        // makes new files differ from pre-FIR eva.xml, which is intended.
        params["filterFamily"] = filterFamily.rawValue
        if filterFamily == .auto {
            params["firCrossoverHz"] = String(format: "%.3g", firCrossoverHz)
        }
        if filterFamily != .iir, let firTransitionHz {
            params["firTransitionHz"] = String(format: "%.3g", firTransitionHz)
        }
        if notch60HzEnabled { params["notchHz"] = "60" }
        // Explicit mode disambiguates notch vs adaptive CleanLine on replay.
        params["lineNoiseMode"] = activeLineNoiseMode.rawValue
        // Label the notch style (IIR vs FIR) explicitly whenever a notch is used.
        if lineNoiseMode == .notch {
            params["notchUsesFIR"] = "\(notchIsFIREffective)"
        }
        if lineNoiseMode != .off {
            params["lineNoiseHz"] = String(format: "%.0f", lineNoiseFrequency)
            params["lineNoiseHarmonics"] = "\(lineNoiseHarmonics)"
        }
        params["precision"] = precision.rawValue
        return params
    }

    /// Deserialization inverse of `parameters`: seed the store from a portable
    /// eva.xml `filter` step (used by Copy Processing / replay). Missing keys
    /// leave the current, defaults-seeded value untouched.
    func apply(parameters p: [String: String]) {
        highPassCutoffText = p["highPassHz"] ?? ""
        lowPassCutoffText = p["lowPassHz"] ?? ""
        if let v = p["highPassSlope"].flatMap(Int.init), let s = FilterSlope(rawValue: v) { highPassSlope = s }
        if let v = p["lowPassSlope"].flatMap(Int.init), let s = FilterSlope(rawValue: v) { lowPassSlope = s }
        // A missing filterFamily key means a pre-FIR eva.xml: default to IIR so
        // historical files reproduce byte-identically regardless of the user's
        // new-work default preference.
        filterFamily = p["filterFamily"].flatMap(FilterFamily.init(rawValue:)) ?? .iir
        firCrossoverHz = p["firCrossoverHz"].flatMap(Double.init) ?? EEGSignalFilter.defaultFIRCrossoverHz
        firTransitionHz = p["firTransitionHz"].flatMap(Double.init)
        notchUsesFIR = p["notchUsesFIR"] == "true"
        let serializedMode = p["lineNoiseMode"].flatMap(FilterLineNoiseMode.init(rawValue:))
        if let serializedMode {
            lineNoiseMode = serializedMode
        } else if p["lineNoiseHz"] != nil {
            // Legacy eva.xml without an explicit mode used lineNoiseHz for CleanLine.
            lineNoiseMode = .adaptiveCleanLine
        } else {
            lineNoiseMode = p["notchHz"] != nil ? .notch : .off
        }
        if let hz = p["lineNoiseHz"].flatMap(Double.init) { lineNoiseFrequency = hz }
        if let h = p["lineNoiseHarmonics"].flatMap(Int.init) { lineNoiseHarmonics = h }
        averageReference = p["averageReference"] == "true"
        if let prec = p["precision"].flatMap(FilterPrecision.init(rawValue:)) { precision = prec }
    }

    // MARK: - Apply / clear

    /// Filters `signal` (and optionally `pnsInput`) off the main thread, updates
    /// the outputs, and calls `onApplied` for cross-domain invalidation.
    /// `async` so the replay coordinator can await filter completion before the
    /// next pipeline step; the interactive caller wraps it in a `Task`. Both use
    /// this one method — there is no separate replay path.
    func apply(
        to signal: MFFSignalData,
        pnsInput: MFFSignalData?,
        onApplied: @escaping () -> Void
    ) async {
        let excludedChannels = store.channels.bad
        let cutoffs: FilterCutoffs
        do {
            cutoffs = try currentCutoffs()
            guard cutoffs.hasFrequencyFilter || activeLineNoiseMode != .off || averageReference else {
                throw FilterViewModelError.noFilterOperation
            }
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
            return
        }

        isFiltering = true
        progress = 0.02
        statusMessage = nil
        statusIsError = false

        let requestID = UUID()
        activeRequestID = requestID
        activeWorker?.cancel()

        let sourceData = signal.data
        let samplingRate = signal.samplingRate
        let highPassCutoff = cutoffs.highPassHz
        let lowPassCutoff = cutoffs.lowPassHz
        let highPassSlope = self.highPassSlope
        let lowPassSlope = self.lowPassSlope
        let filterFamily = self.filterFamily
        let firCrossoverHz = self.firCrossoverHz
        let firTransitionHz = self.firTransitionHz
        let notchUsesFIR = self.notchUsesFIR
        let lineNoiseMode = activeLineNoiseMode
        let lineNoiseFrequency = self.lineNoiseFrequency
        let lineNoiseHarmonics = self.lineNoiseHarmonics
        let lineNoiseWindowSeconds = self.lineNoiseWindowSeconds
        let lineNoiseStrength = self.lineNoiseStrength
        let averageReference = self.averageReference
        let precision = self.precision
        let filterSummary = activeFilterSummary
        let pnsEnabled = pnsInput != nil

        beginOperationProgress(
            subtitle: filterSummary,
            hasCleanLine: lineNoiseMode == .adaptiveCleanLine,
            hasPNS: pnsEnabled
        )

        if lineNoiseMode == .adaptiveCleanLine {
            statusMessage = "Filtering, then applying adaptive CleanLine..."
            statusIsError = false
        }

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.updateFilterProgress(
                fraction,
                hasCleanLine: lineNoiseMode == .adaptiveCleanLine,
                hasPNS: pnsEnabled,
                eegChannels: sourceData.count,
                pnsChannels: pnsInput?.data.count ?? 0
            )
        }

        do {
            let worker = Task.detached(priority: .userInitiated) {
                    let filteredData = try await Self.filteredChannels(
                        sourceData,
                        samplingRate: samplingRate,
                        lowCutoff: highPassCutoff,
                        highCutoff: lowPassCutoff,
                        highPassSlope: highPassSlope,
                        lowPassSlope: lowPassSlope,
                        filterFamily: filterFamily,
                        firCrossoverHz: firCrossoverHz,
                        firTransitionHz: firTransitionHz,
                        lineNoiseMode: lineNoiseMode,
                        notchUsesFIR: notchUsesFIR,
                        notchFrequency: lineNoiseFrequency,
                        lineNoiseHarmonics: lineNoiseHarmonics,
                        lineNoiseWindowSeconds: lineNoiseWindowSeconds,
                        lineNoiseStrength: lineNoiseStrength,
                        averageReference: averageReference,
                        precision: precision,
                        excludedChannels: excludedChannels,
                        progress: { fraction in
                            progressContinuation.yield(pnsEnabled ? 0.70 * fraction : fraction)
                        }
                    )

                    let filteredPNSData: [[Float]]?
                    if let pnsInput {
                        filteredPNSData = try await Self.filteredChannels(
                            pnsInput.data,
                            samplingRate: pnsInput.samplingRate,
                            lowCutoff: highPassCutoff,
                            highCutoff: lowPassCutoff,
                            highPassSlope: highPassSlope,
                            lowPassSlope: lowPassSlope,
                            lineNoiseMode: lineNoiseMode,
                            notchFrequency: lineNoiseFrequency,
                            lineNoiseHarmonics: lineNoiseHarmonics,
                            lineNoiseWindowSeconds: lineNoiseWindowSeconds,
                            lineNoiseStrength: lineNoiseStrength,
                            averageReference: false,
                            precision: precision,
                            excludedChannels: [],
                            progress: { fraction in
                                progressContinuation.yield(0.70 + 0.30 * fraction)
                            }
                        )
                    } else {
                        filteredPNSData = nil
                    }
                    return (filteredData, filteredPNSData)
                }
                activeWorker = worker
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                        progressContinuation.finish()
                    }
                )
                progressContinuation.finish()
                progressTask.cancel()

                guard activeRequestID == requestID, !Task.isCancelled else {
                    operationProgress = nil
                    return
                }
                activeWorker = nil

                updateFinalizingProgress(averageReference: averageReference)

                output = signal.replacingData(result.0)
                if let pnsInput, let filteredPNSData = result.1 {
                    pnsOutput = MFFSignalData(
                        signalURL: pnsInput.signalURL,
                        signalType: "\(pnsInput.signalType) filtered",
                        numberOfChannels: pnsInput.numberOfChannels,
                        samplingRate: pnsInput.samplingRate,
                        duration: pnsInput.duration,
                        recordingStartTime: pnsInput.recordingStartTime,
                        events: pnsInput.events,
                        data: filteredPNSData,
                        channelNames: pnsInput.channelNames
                    )
                    pnsInputSignalType = pnsInput.signalType
                } else {
                    pnsOutput = nil
                    pnsInputSignalType = nil
                }
                onApplied()
                statusMessage = "Applied \(filterSummary)\(pnsInput == nil ? "" : " + PNS")."
                statusIsError = false
                progress = 1
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                guard activeRequestID == requestID else { return }
                activeWorker = nil
                statusMessage = error.localizedDescription
                statusIsError = true
            }
            if activeRequestID == requestID {
                activeWorker = nil
                isFiltering = false
                operationProgress = nil
            }
    }

    /// Clears the filter outputs and calls `onCleared` for cross-domain invalidation.
    func clear(onCleared: () -> Void) {
        activeRequestID = UUID()
        activeWorker?.cancel()
        activeWorker = nil
        isFiltering = false
        operationProgress = nil
        output = nil
        pnsOutput = nil
        pnsInputSignalType = nil
        onCleared()
        statusMessage = "Removed filter."
        statusIsError = false
    }

    /// Directly sets the EEG output (used by the ICA re-filter restore path).
    func setOutput(_ signal: MFFSignalData?) {
        activeRequestID = UUID()
        activeWorker?.cancel()
        activeWorker = nil
        output = signal
    }

    func cancelInFlightWork() {
        activeRequestID = UUID()
        activeWorker?.cancel()
        activeWorker = nil
        isFiltering = false
        progress = 0
        operationProgress = nil
    }

    func resetForClose() {
        cancelInFlightWork()
        statusMessage = nil
        statusIsError = false
        output = nil
        pnsOutput = nil
        pnsInputSignalType = nil
    }

    private func beginOperationProgress(subtitle: String, hasCleanLine: Bool, hasPNS: Bool) {
        var stages = ["Preparing", "EEG filtering"]
        if hasCleanLine { stages.append("Adaptive CleanLine") }
        if hasPNS { stages.append("PNS filtering") }
        stages.append("Finalizing")
        operationProgress = .started(
            source: "Filter",
            title: "Signal Filtering",
            subtitle: subtitle,
            phase: "Designing filter coefficients",
            stages: stages
        ).updating(
            fraction: 0.02,
            phase: "Designing filter coefficients",
            activeStage: 0
        )
    }

    private func updateFilterProgress(
        _ workerFraction: Double,
        hasCleanLine: Bool,
        hasPNS: Bool,
        eegChannels: Int,
        pnsChannels: Int
    ) {
        let bounded = min(max(workerFraction, 0), 1)
        let isPNS = hasPNS && bounded >= 0.70
        let local = isPNS
            ? min(max((bounded - 0.70) / 0.30, 0), 1)
            : min(max(bounded / (hasPNS ? 0.70 : 1), 0), 1)
        let inCleanLine = hasCleanLine && local >= 0.62
        let phaseFraction: Double
        if hasCleanLine {
            phaseFraction = inCleanLine ? (local - 0.62) / 0.38 : local / 0.62
        } else {
            phaseFraction = local
        }
        let count = isPNS ? pnsChannels : eegChannels
        let completed = min(count, max(0, Int((phaseFraction * Double(count)).rounded())))
        let displayFraction = 0.06 + 0.88 * bounded
        progress = displayFraction

        let cleanLineStage = 2
        let pnsStage = 2 + (hasCleanLine ? 1 : 0)
        let activeStage = isPNS ? pnsStage : (inCleanLine ? cleanLineStage : 1)
        let target = isPNS ? "PNS" : "EEG"
        let phase: String
        if isPNS {
            phase = inCleanLine ? "Applying adaptive CleanLine to PNS" : "Filtering PNS channels"
        } else {
            phase = inCleanLine ? "Applying adaptive CleanLine" : "Filtering EEG channels"
        }
        operationProgress = operationProgress?.updating(
            fraction: displayFraction,
            phase: phase,
            detail: count > 0 ? "\(target) channels \(completed) of \(count)" : nil,
            activeStage: activeStage
        )
    }

    private func updateFinalizingProgress(averageReference: Bool) {
        progress = 0.98
        guard let current = operationProgress else { return }
        operationProgress = current.updating(
            fraction: 0.98,
            phase: averageReference ? "Applying average reference and finalizing" : "Finalizing filtered signal",
            activeStage: current.stages.count - 1
        )
    }

    // MARK: - Transform (L3 orchestration)

    nonisolated static func filteredChannels(
        _ sourceData: [[Float]],
        samplingRate: Double,
        lowCutoff: Double?,
        highCutoff: Double?,
        highPassSlope: FilterSlope = .dB24,
        lowPassSlope: FilterSlope = .dB24,
        filterFamily: FilterFamily = .iir,
        firCrossoverHz: Double = EEGSignalFilter.defaultFIRCrossoverHz,
        firTransitionHz: Double? = nil,
        lineNoiseMode: FilterLineNoiseMode,
        notchUsesFIR: Bool = false,
        notchFrequency: Double,
        lineNoiseHarmonics: Int,
        lineNoiseWindowSeconds: Double,
        lineNoiseStrength: Double,
        averageReference: Bool,
        precision: FilterPrecision = .auto,
        excludedChannels: Set<Int>,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [[Float]] {
        let notchEnabled = lineNoiseMode == .notch
        // The notch is applied as FIR only when the toggle is on and the FIR
        // family is selected; otherwise it is a single zero-phase IIR biquad.
        let notchIsFIR = notchEnabled && notchUsesFIR && filterFamily == .fir
        var bandPassed = try await EEGSignalFilter.bandPass(
            channels: sourceData,
            samplingRate: samplingRate,
            lowCutoff: lowCutoff,
            highCutoff: highCutoff,
            highPassSlope: highPassSlope,
            lowPassSlope: lowPassSlope,
            highPassFamily: filterFamily,
            lowPassFamily: filterFamily,
            firCrossoverHz: firCrossoverHz,
            firTransitionHz: firTransitionHz,
            notch60HzEnabled: notchEnabled,
            notchFrequency: notchFrequency,
            notchIsFIR: notchIsFIR,
            notchHarmonics: lineNoiseHarmonics,
            precision: precision,
            progress: { fraction in
                progress(lineNoiseMode == .adaptiveCleanLine ? 0.62 * fraction : fraction)
            }
        )
        if lineNoiseMode == .adaptiveCleanLine {
            bandPassed = await EEGSignalFilter.adaptiveLineNoiseReduction(
                channels: bandPassed,
                samplingRate: samplingRate,
                baseFrequency: notchFrequency,
                harmonicCount: lineNoiseHarmonics,
                windowSeconds: lineNoiseWindowSeconds,
                strength: lineNoiseStrength,
                progress: { fraction in progress(0.62 + 0.38 * fraction) }
            )
        }
        if averageReference {
            EEGSignalFilter.averageReferenceInPlace(&bandPassed, excluding: excludedChannels)
        }
        return bandPassed
    }

    private func currentCutoffs() throws -> FilterCutoffs {
        FilterCutoffs(
            highPassHz: try Self.parseCutoff(highPassCutoffText, field: "High-pass"),
            lowPassHz: try Self.parseCutoff(lowPassCutoffText, field: "Low-pass")
        )
    }

    private static func parseCutoff(_ text: String, field: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed) else {
            throw FilterViewModelError.invalidCutoff(field: field, value: trimmed)
        }
        return value
    }

    private static func optionalCutoffValue(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private static func cutoffText(_ value: Double) -> String {
        String(format: "%.3g", value)
    }

    private static func formattedCutoff(_ value: Double) -> String {
        String(format: "%.3g", value)
    }
}
