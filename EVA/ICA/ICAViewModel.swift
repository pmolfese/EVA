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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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

    // MARK: Results
    var decomposition: ICADecomposition?
    var cleanedSignal: MFFSignalData?

    // MARK: Debug
    var debugReportRequest = 0
    var debugReportSerial = 0
    var lastReconstructionDebugReport: String?

    var isActive: Bool { cleanedSignal != nil }

    var parameters: [String: String] {
        [
            "method": method.rawValue,
            "components": "\(componentCount)",
            "averageReference": "\(usesAverageReference)"
        ]
    }

    /// Deserialization inverse of `parameters` for Copy Processing / replay. The
    /// portable decomposition settings are restored; which components to remove
    /// stays a per-subject decision made in the sheet.
    func apply(parameters p: [String: String]) {
        if let m = p["method"].flatMap(ICAMethod.init(rawValue:)) { method = m }
        if let c = p["components"].flatMap(Int.init) { componentCount = c }
        if let a = p["averageReference"] { usesAverageReference = (a == "true") }
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
