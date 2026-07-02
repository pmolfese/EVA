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
        if method != .aas {
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
}
