//
//  ICAViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for the ICA decomposition + component-removal domain, extracted from
//  WaveformView (REFACTOR.md slice 6 — the most coupled processing domain).
//  State-ownership extraction: the store holds ICA parameters, fit filter
//  settings, the decomposition, and the cleaned output; WaveformView still
//  drives the fit/removal orchestration.
//

import SwiftUI

@MainActor
@Observable
final class ICAViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
        let d = ProcessingDefaults.shared
        method = d.icaMethod
        componentCount = d.icaComponentCount
    }

    // MARK: Sheet / run state
    var showsSheet = false
    var isRunning = false
    var progress = 0.0
    var progressMessage = ""
    var statusMessage: String?
    var isRemovingComponents = false

    // MARK: Parameters
    var method: ICAMethod = .picard
    var componentCount = 20
    var varianceThreshold = 0.999
    var usesAverageReference = true
    var downsampleRate = 100.0
    var maxIterations = 200
    var minimumIterations = 10
    var convergenceTolerance = 0.000000000001

    // MARK: Fit pre-filter
    var usesFitFilter = true
    var fitLowCutoff = 1.0
    var fitHighCutoff = 40.0
    var fitNotch60HzEnabled = false
    /// Family for the fit/activation filter. Independent of the main filter
    /// popover's family on purpose — the ICA fit band is its own choice, and a
    /// 1 Hz high-pass has different tradeoffs from a 0.1 Hz display filter.
    var fitFilterFamily: FilterFamily = .iir

    // MARK: Results
    var decomposition: ICADecomposition?
    var cleanedSignal: MFFSignalData?

    // MARK: Debug
    var debugReportRequest = 0
    var debugReportSerial = 0
    var lastReconstructionDebugReport: String?

    var isActive: Bool { cleanedSignal != nil }

    /// The portable settings that define the *fit*.
    ///
    /// This used to carry only method/components/averageReference, while
    /// `ICAConfiguration` is built from nine more properties that all change the
    /// decomposition — so a replayed ICA fit silently used the destination's
    /// defaults for variance retention, decimation, convergence, and the
    /// activation pre-filter. Found by the REWIND determinism audit
    /// (2026-08-13); same class as `categoryGroups`.
    ///
    /// This describes how to *re-fit*. Reproducing a specific removal exactly
    /// does not go through here at all — that is `ICAReplayPayload`, which stores
    /// the fitted operator and the excluded set.
    var parameters: [String: String] {
        var p: [String: String] = [
            "method": method.rawValue,
            "components": "\(componentCount)",
            "averageReference": "\(usesAverageReference)",
            "varianceThreshold": "\(varianceThreshold)",
            "downsampleRate": "\(downsampleRate)",
            "maxIterations": "\(maxIterations)",
            "minimumIterations": "\(minimumIterations)",
            "convergenceTolerance": "\(convergenceTolerance)",
            "fitFilter": "\(usesFitFilter)"
        ]
        if usesFitFilter {
            p["fitLowCutoff"] = "\(fitLowCutoff)"
            p["fitHighCutoff"] = "\(fitHighCutoff)"
            p["fitNotch60Hz"] = "\(fitNotch60HzEnabled)"
            p["fitFilterFamily"] = fitFilterFamily.rawValue
        }
        return p
    }

    /// Deserialization inverse of `parameters` for Copy Processing / replay. The
    /// portable decomposition settings are restored; which components to remove
    /// stays a per-subject decision made in the sheet.
    ///
    /// Absent keys leave the current value alone, so a pre-audit `eva.xml`
    /// replays exactly as it did before the extra keys existed.
    func apply(parameters p: [String: String]) {
        if let m = p["method"].flatMap(ICAMethod.init(rawValue:)) { method = m }
        if let c = p["components"].flatMap(Int.init) { componentCount = c }
        if let a = p["averageReference"] { usesAverageReference = (a == "true") }
        if let v = p["varianceThreshold"].flatMap(Double.init) { varianceThreshold = v }
        if let v = p["downsampleRate"].flatMap(Double.init) { downsampleRate = v }
        if let v = p["maxIterations"].flatMap(Int.init) { maxIterations = v }
        if let v = p["minimumIterations"].flatMap(Int.init) { minimumIterations = v }
        if let v = p["convergenceTolerance"].flatMap(Double.init) { convergenceTolerance = v }
        if let v = p["fitFilter"] { usesFitFilter = (v == "true") }
        if let v = p["fitLowCutoff"].flatMap(Double.init) { fitLowCutoff = v }
        if let v = p["fitHighCutoff"].flatMap(Double.init) { fitHighCutoff = v }
        if let v = p["fitNotch60Hz"] { fitNotch60HzEnabled = (v == "true") }
        if let v = p["fitFilterFamily"].flatMap(FilterFamily.init(rawValue:)) { fitFilterFamily = v }
    }

    func resetForClose() {
        showsSheet = false
        isRunning = false
        progress = 0
        progressMessage = ""
        statusMessage = nil
        isRemovingComponents = false
        decomposition = nil
        cleanedSignal = nil
        debugReportSerial = 0
        lastReconstructionDebugReport = nil
    }
}
