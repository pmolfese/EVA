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
final class FilterViewModel: ObservableObject {
    init() {
        let d = ProcessingDefaults.shared
        highPassCutoffText = Self.cutoffText(d.filterHighPassHz)
        lowPassCutoffText = Self.cutoffText(d.filterLowPassHz)
        notch60HzEnabled = d.filterNotch60
        averageReference = d.filterAverageReference
    }

    // MARK: Parameters (portable → eva.xml / replay)
    @Published var highPassCutoffText = "0.1"
    @Published var lowPassCutoffText = "30"
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
    @Published var precision = FilterPrecision.auto

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

    private var activeRequestID = UUID()

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

    var activeLineNoiseMode: FilterLineNoiseMode {
        if lineNoiseMode == .adaptiveCleanLine { return .adaptiveCleanLine }
        return notch60HzEnabled ? .notch : lineNoiseMode
    }

    var frequencySummary: String? {
        guard let cutoffs = try? currentCutoffs() else { return "Invalid cutoff" }
        switch (cutoffs.highPassHz, cutoffs.lowPassHz) {
        case let (highPass?, lowPass?):
            return "Butterworth \(Self.formattedCutoff(highPass))-\(Self.formattedCutoff(lowPass)) Hz"
        case let (highPass?, nil):
            return "Butterworth high-pass \(Self.formattedCutoff(highPass)) Hz"
        case let (nil, lowPass?):
            return "Butterworth low-pass \(Self.formattedCutoff(lowPass)) Hz"
        case (nil, nil):
            return nil
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
            return "\(String(format: "%.1f", lineNoiseFrequency)) Hz notch"
        case .adaptiveCleanLine:
            let harmonics = lineNoiseHarmonics > 1 ? " x\(lineNoiseHarmonics)" : ""
            return "CleanLine \(String(format: "%.1f", lineNoiseFrequency)) Hz\(harmonics)"
        }
    }

    func resetToDefaults() {
        highPassCutoffText = "0.1"
        lowPassCutoffText = "30"
        notch60HzEnabled = false
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
        if notch60HzEnabled { params["notchHz"] = "60" }
        // Explicit mode disambiguates notch vs adaptive CleanLine on replay.
        params["lineNoiseMode"] = activeLineNoiseMode.rawValue
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
        notch60HzEnabled = p["notchHz"] != nil
        switch p["lineNoiseMode"].flatMap(FilterLineNoiseMode.init(rawValue:)) {
        case .adaptiveCleanLine:
            lineNoiseMode = .adaptiveCleanLine
        case .notch, .off:
            lineNoiseMode = .off // active mode becomes .notch via notch60HzEnabled
        case nil:
            // Legacy eva.xml without the explicit mode key: infer from frequency.
            lineNoiseMode = p["lineNoiseHz"] != nil ? .adaptiveCleanLine : .off
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
        excludedChannels: Set<Int>,
        onApplied: @escaping () -> Void
    ) async {
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
        progress = 0
        statusMessage = nil
        statusIsError = false

        let requestID = UUID()
        activeRequestID = requestID

        let sourceData = signal.data
        let samplingRate = signal.samplingRate
        let highPassCutoff = cutoffs.highPassHz
        let lowPassCutoff = cutoffs.lowPassHz
        let highPassSlope = self.highPassSlope
        let lowPassSlope = self.lowPassSlope
        let lineNoiseMode = activeLineNoiseMode
        let lineNoiseFrequency = self.lineNoiseFrequency
        let lineNoiseHarmonics = self.lineNoiseHarmonics
        let lineNoiseWindowSeconds = self.lineNoiseWindowSeconds
        let lineNoiseStrength = self.lineNoiseStrength
        let averageReference = self.averageReference
        let precision = self.precision
        let filterSummary = activeFilterSummary

        if lineNoiseMode == .adaptiveCleanLine {
            statusMessage = "Filtering, then applying adaptive CleanLine..."
            statusIsError = false
        }

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.progress = fraction
        }

        do {
            let pnsEnabled = pnsInput != nil

            let result = try await Task.detached(priority: .userInitiated) {
                    let filteredData = try await Self.filteredChannels(
                        sourceData,
                        samplingRate: samplingRate,
                        lowCutoff: highPassCutoff,
                        highCutoff: lowPassCutoff,
                        highPassSlope: highPassSlope,
                        lowPassSlope: lowPassSlope,
                        lineNoiseMode: lineNoiseMode,
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
                }.value
                progressContinuation.finish()
                progressTask.cancel()

                guard activeRequestID == requestID else { return }

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
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                guard activeRequestID == requestID else { return }
                statusMessage = error.localizedDescription
                statusIsError = true
            }
            if activeRequestID == requestID {
                isFiltering = false
            }
    }

    /// Clears the filter outputs and calls `onCleared` for cross-domain invalidation.
    func clear(onCleared: () -> Void) {
        activeRequestID = UUID()
        isFiltering = false
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
        output = signal
    }

    // MARK: - Transform (L3 orchestration)

    nonisolated static func filteredChannels(
        _ sourceData: [[Float]],
        samplingRate: Double,
        lowCutoff: Double?,
        highCutoff: Double?,
        highPassSlope: FilterSlope = .dB24,
        lowPassSlope: FilterSlope = .dB24,
        lineNoiseMode: FilterLineNoiseMode,
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
        var bandPassed = try await EEGSignalFilter.bandPass(
            channels: sourceData,
            samplingRate: samplingRate,
            lowCutoff: lowCutoff,
            highCutoff: highCutoff,
            highPassSlope: highPassSlope,
            lowPassSlope: lowPassSlope,
            notch60HzEnabled: notchEnabled,
            notchFrequency: notchFrequency,
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
