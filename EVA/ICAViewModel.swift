//
//  ICAViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the ICA decomposition + component-removal domain, extracted from
//  WaveformView (REFACTOR.md slice 6 — the most coupled processing domain).
//  State-ownership extraction: the store holds ICA parameters, fit filter
//  settings, the decomposition, and the cleaned output; WaveformView still
//  drives the fit/removal orchestration.
//

import Combine
import SwiftUI

@MainActor
final class ICAViewModel: ObservableObject {
    init() {
        let d = ProcessingDefaults.shared
        method = d.icaMethod
        componentCount = d.icaComponentCount
    }

    // MARK: Sheet / run state
    @Published var showsSheet = false
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var progressMessage = ""
    @Published var statusMessage: String?
    @Published var isRemovingComponents = false

    // MARK: Parameters
    @Published var method: ICAMethod = .picard
    @Published var componentCount = 20
    @Published var varianceThreshold = 0.999
    @Published var usesAverageReference = true
    @Published var downsampleRate = 100.0
    @Published var maxIterations = 200
    @Published var minimumIterations = 10
    @Published var convergenceTolerance = 0.000000000001

    // MARK: Fit pre-filter
    @Published var usesFitFilter = true
    @Published var fitLowCutoff = 1.0
    @Published var fitHighCutoff = 40.0
    @Published var fitNotch60HzEnabled = false

    // MARK: Results
    @Published var decomposition: ICADecomposition?
    @Published var cleanedSignal: MFFSignalData?

    // MARK: Debug
    @Published var debugReportRequest = 0
    @Published var debugReportSerial = 0
    @Published var lastReconstructionDebugReport: String?

    var isActive: Bool { cleanedSignal != nil }

    var parameters: [String: String] {
        [
            "method": method.rawValue,
            "components": "\(componentCount)",
            "averageReference": "\(usesAverageReference)"
        ]
    }
}
