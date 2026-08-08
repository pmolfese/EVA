//
//  WaveletReductionViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for the wavelet-reduction (HAPPE-style) pipeline stage, extracted
//  from WaveformView (REFACTOR.md slice 3). State-ownership extraction: the
//  store holds the domain's parameters, run state, and reduced outputs;
//  WaveformView still drives the reduction orchestration.
//

import SwiftUI

@MainActor
@Observable
final class WaveletReductionViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Results
    var reducedSignal: MFFSignalData?
    var artifact: MFFSignalData?
    var result: WaveletReductionResult?
    var bandVarianceRetained: Double?

    // MARK: Run state
    var isEnabled = true
    var isRunning = false
    var progress = 0.0
    var statusMessage: String?

    // MARK: UI state
    var showsSheet = false
    /// Presentation state for the advanced analysis-range popover.
    var showsAdvancedRange = false
    /// Draft text for the range fields. Kept as strings so a half-typed value
    /// never reaches the configuration; `commitAdvancedRange` parses them.
    var advancedRangeStartText = ""
    var advancedRangeEndText = ""
    /// Validation feedback for the popover, cleared on a successful commit.
    var advancedRangeMessage: String?

    // MARK: Parameters
    var mode = WaveletReductionMode.continuousEEG
    var config = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: 250)
    var coreCount = WaveletReducer.defaultCoreCount
    var candidates: [WaveletReductionCandidate] = []
    var selectedCandidateID: String?

    var isActive: Bool { reducedSignal != nil }

    func clearResults() {
        reducedSignal = nil
        artifact = nil
        result = nil
        bandVarianceRetained = nil
        candidates = []
        selectedCandidateID = nil
    }

    func resetForClose() {
        clearResults()
        isRunning = false
        progress = 0
        statusMessage = nil
        showsSheet = false
    }

    var parameters: [String: String] {
        [
            "mode": mode.rawValue,
            "kind": config.kind.rawValue,
            "family": config.family.rawValue,
            "levelCount": "\(config.levelCount)",
            "thresholdRule": config.thresholdRule.rawValue,
            "thresholdModel": config.thresholdModel.rawValue,
            "thresholdScale": "\(config.thresholdScale)",
            "downsampleFactor": "\(config.downsampleFactor)",
            "detrend": "\(config.detrend)",
            "thresholdWindowSeconds": "\(config.thresholdWindowSeconds)",
            "useGPU": "\(config.useGPU)",
            "skippedFineLevels": "\(config.skippedFineLevels)",
            // Absent keys mean "unbounded", matching the optionals.
            "analysisStartSeconds": config.analysisStartSeconds.map { "\($0)" } ?? "",
            "analysisEndSeconds": config.analysisEndSeconds.map { "\($0)" } ?? ""
        ]
    }

    /// Deserialization inverse of `parameters` for Copy Processing / replay.
    /// Missing keys leave the current value untouched.
    func apply(parameters p: [String: String]) {
        if let v = p["mode"].flatMap(WaveletReductionMode.init(rawValue:)) { mode = v }
        if let v = p["kind"].flatMap(WaveletTransformKind.init(rawValue:)) { config.kind = v }
        if let v = p["family"].flatMap(WaveletReductionFamily.init(rawValue:)) { config.family = v }
        if let v = p["levelCount"].flatMap(Int.init) { config.levelCount = v }
        if let v = p["thresholdRule"].flatMap(WaveletCleaningThresholdRule.init(rawValue:)) { config.thresholdRule = v }
        if let v = p["thresholdModel"].flatMap(WaveletCleaningThresholdModel.init(rawValue:)) { config.thresholdModel = v }
        if let v = p["thresholdScale"].flatMap(Double.init) { config.thresholdScale = v }
        if let v = p["downsampleFactor"].flatMap(Int.init) { config.downsampleFactor = v }
        if let v = p["detrend"].flatMap(Bool.init) { config.detrend = v }
        if let v = p["thresholdWindowSeconds"].flatMap(Double.init) { config.thresholdWindowSeconds = v }
        if let v = p["useGPU"].flatMap(Bool.init) { config.useGPU = v }
        if let v = p["skippedFineLevels"].flatMap(Int.init) { config.skippedFineLevels = v }
        if let v = p["analysisStartSeconds"] { config.analysisStartSeconds = v.isEmpty ? nil : Double(v) }
        if let v = p["analysisEndSeconds"] { config.analysisEndSeconds = v.isEmpty ? nil : Double(v) }
        syncAdvancedRangeText()
    }

    // MARK: - Advanced analysis range

    /// Refreshes the draft text from the configuration, so reopening the
    /// popover shows what is actually in effect.
    func syncAdvancedRangeText() {
        advancedRangeStartText = config.analysisStartSeconds.map { String(format: "%g", $0) } ?? ""
        advancedRangeEndText = config.analysisEndSeconds.map { String(format: "%g", $0) } ?? ""
    }

    /// Parses the draft text into the configuration. A blank or unparseable
    /// field means "unbounded on that side"; an inverted or too-short span is
    /// rejected so the run can't silently analyze nothing.
    /// Returns a message when the input was rejected.
    @discardableResult
    func commitAdvancedRange(durationSeconds: Double) -> String? {
        let start = Double(advancedRangeStartText.trimmingCharacters(in: .whitespaces))
        let end = Double(advancedRangeEndText.trimmingCharacters(in: .whitespaces))
        let effectiveStart = start ?? 0
        let effectiveEnd = end ?? durationSeconds
        guard effectiveEnd - effectiveStart > 0.05 else {
            return "That range is empty — the end must be later than the start."
        }
        config.analysisStartSeconds = start.map { max($0, 0) }
        config.analysisEndSeconds = end.map { min($0, durationSeconds) }
        syncAdvancedRangeText()
        return nil
    }

    func clearAdvancedRange() {
        config.analysisStartSeconds = nil
        config.analysisEndSeconds = nil
        syncAdvancedRangeText()
    }

    /// "Full recording" or e.g. "0–529.0 s", for the settings row.
    func analysisRangeSummary(durationSeconds: Double) -> String {
        guard config.analysisStartSeconds != nil || config.analysisEndSeconds != nil else {
            return "Full recording"
        }
        let start = config.analysisStartSeconds ?? 0
        let end = config.analysisEndSeconds ?? durationSeconds
        return String(format: "%.1f–%.1f s", start, end)
    }

    // MARK: - Apply (the transform itself)

    /// Runs the configured wavelet reduction against `signal`, excluding
    /// `excludedChannels` (bad channels) from reduction, updating
    /// `reducedSignal`/`artifact`/`result`/`candidates`. `analysisBand` (the
    /// filter step's high-pass/low-pass cutoffs, if any) enables the ERP
    /// in-band variance assessment, matching the interactive path.
    /// `onApplied` carries cross-domain invalidation back to the caller, same
    /// pattern as `FilterViewModel`/`GradientViewModel`. No `recordingSessionID`
    /// staleness guard — see `GradientViewModel.apply`'s doc comment for why a
    /// method that only ever writes to `self` doesn't need one; a caller whose
    /// VM instance can outlive a single run (the interactive sheet) must guard
    /// the outer Task itself.
    func apply(
        to signal: MFFSignalData,
        excludedChannels: Set<Int>,
        analysisBand: (low: Double, high: Double)?,
        onApplied: @escaping () -> Void = {}
    ) async {
        let config = self.config
        let mode = self.mode
        let cores = self.coreCount
        let reduceIndices = signal.data.indices.filter { !excludedChannels.contains($0) }

        isRunning = true
        progress = 0
        statusMessage = "Running wavelet reduction…"
        bandVarianceRetained = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.progress = min(max(fraction, 0), 1)
        }

        let worker = Task.detached(priority: .userInitiated) {
            WaveletReducer.reduce(
                signal: signal,
                channelIndices: Array(reduceIndices),
                configuration: config,
                coreCount: cores
            ) { fraction in
                progressContinuation.yield(fraction * (mode.assessesInBand ? 0.8 : 1.0))
            }
        }
        let result = await withTaskCancellationHandler(
            operation: { await worker.value },
            onCancel: {
                worker.cancel()
                progressContinuation.finish()
            }
        )

        var bandRetained: Double?
        if !Task.isCancelled, mode.assessesInBand, let analysisBand,
           analysisBand.high > analysisBand.low, analysisBand.high < signal.samplingRate / 2 {
            bandRetained = await bandLimitedVarianceRetained(
                original: signal, cleaned: result.cleaned, channelIndices: Array(reduceIndices), band: analysisBand
            )
        }

        progressContinuation.finish()
        progressTask.cancel()
        guard !Task.isCancelled else { isRunning = false; return }

        reducedSignal = result.cleaned
        artifact = result.artifact
        self.result = result
        bandVarianceRetained = bandRetained
        let analyzedRange = config.analysisRange(
            sampleCount: signal.data.first?.count ?? 0, samplingRate: signal.samplingRate)
        candidates = WaveletReducer.findCandidates(
            artifact: result.artifact,
            channelIndices: Array(reduceIndices),
            maxCount: 40,
            sampleRange: analyzedRange,
            edgeMarginSamples: WaveletReducer.candidateEdgeMargin(
                family: config.family,
                levelCount: config.levelCount,
                sampleCount: analyzedRange?.count ?? 0
            )
        )
        selectedCandidateID = candidates.first?.id
        isEnabled = true
        isRunning = false
        progress = 1
        let varianceText = String(format: "%.1f%%", result.varianceRetainedPercent)
        statusMessage = "Reduced \(reduceIndices.count) channels · \(varianceText) variance retained · r \(String(format: "%.2f", result.meanCorrelation))"
        onApplied()
    }

    /// Variance retained = var(cleaned_band)/var(original_band) over the
    /// reduced channels, mirroring HAPPE's in-band ERP quality assessment.
    /// Ported from `WaveletReductionSheetViews.bandLimitedVarianceRetained`.
    private nonisolated func bandLimitedVarianceRetained(
        original: MFFSignalData,
        cleaned: MFFSignalData,
        channelIndices: [Int],
        band: (low: Double, high: Double)
    ) async -> Double? {
        do {
            let originalBand = try await EEGSignalFilter.bandPass(
                channels: channelIndices.map { original.data[$0] },
                samplingRate: original.samplingRate,
                lowCutoff: band.low,
                highCutoff: band.high
            )
            let cleanedBand = try await EEGSignalFilter.bandPass(
                channels: channelIndices.map { cleaned.data[$0] },
                samplingRate: cleaned.samplingRate,
                lowCutoff: band.low,
                highCutoff: band.high
            )
            var originalVariance = 0.0
            var cleanedVariance = 0.0
            for index in originalBand.indices {
                originalVariance += variance(of: originalBand[index])
                cleanedVariance += variance(of: cleanedBand[index])
            }
            guard originalVariance > 1e-12 else { return nil }
            return cleanedVariance / originalVariance * 100
        } catch {
            return nil
        }
    }

    private nonisolated func variance(of values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        return values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(values.count)
    }
}
