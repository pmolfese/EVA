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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the band-pass / line-noise / average-reference filtering domain,
//  extracted from WaveformView (first slice of the ProcessingPipeline refactor —
//  see REFACTOR.md). Owns the filter parameters, run state, and the filtered
//  outputs, and orchestrates the L3 `EEGSignalFilter` engine. Cross-domain
//  invalidation (artifact cleaning, epochs, interpolations) is delegated back to
//  the view via the `onApplied` / `onCleared` callbacks so this store stays
//  focused until `RecordingStore` lands.
//

import Combine
import SwiftUI

@MainActor
final class FilterViewModel: ObservableObject {
    init() {
        let d = ProcessingDefaults.shared
        lowCutoff = d.filterHighPassHz
        highCutoff = d.filterLowPassHz
        notch60HzEnabled = d.filterNotch60
        averageReference = d.filterAverageReference
    }

    // MARK: Parameters (portable → eva.xml / replay)
    @Published var lowCutoff = 0.1
    @Published var highCutoff = 30.0
    @Published var highPassSlope = FilterSlope.dB24
    @Published var lowPassSlope = FilterSlope.dB24
    @Published var notch60HzEnabled = false
    @Published var lineNoiseMode = FilterLineNoiseMode.off
    @Published var lineNoiseFrequency = 60.0
    @Published var lineNoiseHarmonics = 2
    @Published var lineNoiseWindowSeconds = 4.0
    @Published var lineNoiseStrength = 1.0
    @Published var averageReference = false
    @Published var filterPNS = true

    // MARK: UI state
    @Published var showsPopover = false
    @Published var showsLineNoiseOptions = false

    // MARK: Run state
    @Published var isFiltering = false
    @Published var progress = 0.0
    @Published var statusMessage: String?
    @Published var statusIsError = false

    // MARK: Results
    /// Filtered EEG (was `filteredSignal`).
    @Published var output: MFFSignalData?
    /// Filtered PNS (was `filteredPNSSignal`).
    @Published var pnsOutput: MFFSignalData?
    /// Source signal type of the PNS input, for change detection.
    @Published var pnsInputSignalType: String?

    var isActive: Bool { output != nil }

    // MARK: Derived

    var activeLineNoiseMode: FilterLineNoiseMode {
        if lineNoiseMode == .adaptiveCleanLine { return .adaptiveCleanLine }
        return notch60HzEnabled ? .notch : lineNoiseMode
    }

    var lineNoiseSummary: String {
        switch activeLineNoiseMode {
        case .off:
            return ""
        case .notch:
            return " + \(String(format: "%.1f", lineNoiseFrequency)) Hz notch"
        case .adaptiveCleanLine:
            let harmonics = lineNoiseHarmonics > 1 ? " x\(lineNoiseHarmonics)" : ""
            return " + CleanLine \(String(format: "%.1f", lineNoiseFrequency)) Hz\(harmonics)"
        }
    }

    func resetToDefaults() {
        lowCutoff = 0.1
        highCutoff = 30
        notch60HzEnabled = false
        lineNoiseMode = .off
        lineNoiseFrequency = 60
        lineNoiseHarmonics = 2
        lineNoiseWindowSeconds = 4
        lineNoiseStrength = 1
        averageReference = false
    }

    // MARK: - eva.xml / replay bridge

    /// Portable parameters for the eva.xml `filter` step.
    var parameters: [String: String] {
        var params: [String: String] = [
            "highPassHz": String(format: "%.3g", lowCutoff),
            "lowPassHz": String(format: "%.3g", highCutoff),
            "averageReference": "\(averageReference)"
        ]
        if notch60HzEnabled { params["notchHz"] = "60" }
        if lineNoiseMode != .off {
            params["lineNoiseHz"] = String(format: "%.0f", lineNoiseFrequency)
            params["lineNoiseHarmonics"] = "\(lineNoiseHarmonics)"
        }
        return params
    }

    // MARK: - Apply / clear

    /// Filters `signal` (and optionally `pnsInput`) off the main thread, updates
    /// the outputs, and calls `onApplied` for cross-domain invalidation.
    func apply(
        to signal: MFFSignalData,
        pnsInput: MFFSignalData?,
        excludedChannels: Set<Int>,
        onApplied: @escaping () -> Void
    ) {
        isFiltering = true
        progress = 0
        statusMessage = nil
        statusIsError = false

        let sourceData = signal.data
        let samplingRate = signal.samplingRate
        let lowCutoff = self.lowCutoff
        let highCutoff = self.highCutoff
        let highPassSlope = self.highPassSlope
        let lowPassSlope = self.lowPassSlope
        let lineNoiseMode = activeLineNoiseMode
        let lineNoiseFrequency = self.lineNoiseFrequency
        let lineNoiseHarmonics = self.lineNoiseHarmonics
        let lineNoiseWindowSeconds = self.lineNoiseWindowSeconds
        let lineNoiseStrength = self.lineNoiseStrength
        let averageReference = self.averageReference

        if lineNoiseMode == .adaptiveCleanLine {
            statusMessage = "Filtering, then applying adaptive CleanLine..."
            statusIsError = false
        }

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.progress = fraction
        }

        Task {
            do {
                let pnsEnabled = pnsInput != nil
                let result = try await Task.detached(priority: .userInitiated) {
                    let filteredData = try await Self.filteredChannels(
                        sourceData,
                        samplingRate: samplingRate,
                        lowCutoff: lowCutoff,
                        highCutoff: highCutoff,
                        highPassSlope: highPassSlope,
                        lowPassSlope: lowPassSlope,
                        lineNoiseMode: lineNoiseMode,
                        notchFrequency: lineNoiseFrequency,
                        lineNoiseHarmonics: lineNoiseHarmonics,
                        lineNoiseWindowSeconds: lineNoiseWindowSeconds,
                        lineNoiseStrength: lineNoiseStrength,
                        averageReference: averageReference,
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
                            lowCutoff: lowCutoff,
                            highCutoff: highCutoff,
                            highPassSlope: highPassSlope,
                            lowPassSlope: lowPassSlope,
                            lineNoiseMode: lineNoiseMode,
                            notchFrequency: lineNoiseFrequency,
                            lineNoiseHarmonics: lineNoiseHarmonics,
                            lineNoiseWindowSeconds: lineNoiseWindowSeconds,
                            lineNoiseStrength: lineNoiseStrength,
                            averageReference: false,
                            excludedChannels: [],
                            progress: { fraction in
                                progressContinuation.yield(0.70 + 0.30 * fraction)
                            }
                        )
                    } else {
                        filteredPNSData = nil
                    }
                    return (filteredData, filteredPNSData)
                }.value
                progressContinuation.finish()
                progressTask.cancel()

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
                statusMessage = "Applied Butterworth \(String(format: "%.1f", lowCutoff))-\(String(format: "%.1f", highCutoff)) Hz\(lineNoiseSummary)\(averageReference ? " + average reference" : "")\(pnsInput == nil ? "" : " + PNS")."
                statusIsError = false
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                statusMessage = error.localizedDescription
                statusIsError = true
            }
            isFiltering = false
        }
    }

    /// Clears the filter outputs and calls `onCleared` for cross-domain invalidation.
    func clear(onCleared: () -> Void) {
        output = nil
        pnsOutput = nil
        pnsInputSignalType = nil
        onCleared()
        statusMessage = "Removed band-pass filter."
        statusIsError = false
    }

    /// Directly sets the EEG output (used by the ICA re-filter restore path).
    func setOutput(_ signal: MFFSignalData?) {
        output = signal
    }

    // MARK: - Transform (L3 orchestration)

    nonisolated static func filteredChannels(
        _ sourceData: [[Float]],
        samplingRate: Double,
        lowCutoff: Double,
        highCutoff: Double,
        highPassSlope: FilterSlope = .dB24,
        lowPassSlope: FilterSlope = .dB24,
        lineNoiseMode: FilterLineNoiseMode,
        notchFrequency: Double,
        lineNoiseHarmonics: Int,
        lineNoiseWindowSeconds: Double,
        lineNoiseStrength: Double,
        averageReference: Bool,
        excludedChannels: Set<Int>,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [[Float]] {
        let notchEnabled = lineNoiseMode == .notch
        var bandPassed = try await EEGSignalFilter.bandPass(
            channels: sourceData,
            samplingRate: samplingRate,
            lowCutoff: lowCutoff,
            highCutoff: highCutoff,
            highPassSlope: highPassSlope,
            lowPassSlope: lowPassSlope,
            notch60HzEnabled: notchEnabled,
            notchFrequency: notchFrequency,
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
}
