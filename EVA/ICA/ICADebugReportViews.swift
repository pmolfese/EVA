//
//  ICADebugReportViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ICA debug report generator (clipboard copy + formatted report text),
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - ICA debug report

    func copyICADebugReportToPasteboard() {
        guard let rawSignal = recording.signal else {
            ica.statusMessage = "No recording is loaded."
            return
        }

        ica.debugReportSerial += 1
        let report = icaDebugReport(rawSignal: rawSignal)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        ica.statusMessage = "ICA debug report \(ica.debugReportSerial) copied to clipboard."
    }

    func icaDebugReport(rawSignal: MFFSignalData) -> String {
        let base = ica.cleanedSignal ?? bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
        let processed = filter.output ?? base
        let visibleRange = visibleSampleRange(in: processed)

        var lines: [String] = [
            "# ICA Debug Report",
            "Report serial: \(ica.debugReportSerial)",
            "Recording: \(recording.packageName)",
            "Created: \(Date().formatted(date: .abbreviated, time: .standard))",
            "",
            "## View State",
            "Amplitude scale: \(Int(amplitudeScale)) uV",
            "Time scale: \(String(format: "%.1f", timeScale))x",
            "Horizontal offset: \(String(format: "%.1f", Double(horizontalOffset))) px",
            "Viewport width: \(String(format: "%.1f", Double(horizontalViewportWidth))) px",
            "Visible samples: \(visibleRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "unavailable")",
            "MRI correction active: \(gradient.correctedSignal == nil ? "no" : "yes")",
            "ICA cleaned active: \(ica.cleanedSignal == nil ? "no" : "yes")",
            "ICA removal in progress: \(ica.isRemovingComponents ? "yes" : "no")",
            "Filter active: \(filter.output == nil ? "no" : "yes")",
            "Filter settings: \(filter.activeFilterSummary)",
            "Interpolated channels: \(channels.interpolated.keys.sorted().map { "\($0 + 1)" }.joined(separator: ", ").nilIfEmpty ?? "none")",
            "Bad channels: \(channels.bad.sorted().map { "\($0 + 1)" }.joined(separator: ", ").nilIfEmpty ?? "none")",
            "Hidden channels: \(channels.hidden.sorted().map { "\($0 + 1)" }.joined(separator: ", ").nilIfEmpty ?? "none")",
            "",
            "## ICA Settings",
            "Method field: \(ica.method.displayName)",
            "Components field: \(ica.componentCount)",
            "Keep variance field: \(String(format: "%.3f", ica.varianceThreshold))",
            "Average reference field: \(ica.usesAverageReference ? "on" : "off")",
            "Search Hz field: \(String(format: "%.1f", ica.downsampleRate))",
            "Iterations field: \(ica.maxIterations)",
            "Fit filter field: \(ica.usesFitFilter ? "on" : "off")",
            "Fit Hz field: \(String(format: "%.2f", ica.fitLowCutoff))-\(String(format: "%.2f", ica.fitHighCutoff)), notch \(ica.fitNotch60HzEnabled ? "on" : "off")",
            "Tolerance field: \(String(format: "%.3e", ica.convergenceTolerance))",
            "Minimum iterations field: \(ica.minimumIterations)"
        ]

        if let decomposition = ica.decomposition {
            lines += [
                "",
                "## ICA Decomposition",
                "Components: \(decomposition.componentCount)",
                "Source sampling rate: \(String(format: "%.1f", decomposition.sourceSamplingRate)) Hz",
                "Analysis sampling rate: \(String(format: "%.1f", decomposition.analysisSamplingRate)) Hz",
                "Decimation: \(decomposition.decimation)",
                "Iterations: \(decomposition.iterations)",
                "Final change: \(String(format: "%.3e", decomposition.finalChange))",
                "Converged by tolerance: \(decomposition.finalChange.isFinite && decomposition.finalChange <= decomposition.convergenceTolerance ? "yes" : "no")",
                "Average reference: \(decomposition.averageReference ? "yes" : "no")",
                "PCA variance target: \(String(format: "%.3f", decomposition.varianceThreshold))",
                "Selected PCA variance: \(String(format: "%.1f", decomposition.pcaVarianceRetained * 100))%",
                "Fit filter: \(decomposition.fitFilter.map { "\(String(format: "%.2f", $0.lowCutoff))-\(String(format: "%.2f", $0.highCutoff)) Hz, notch \($0.notch60HzEnabled ? "on" : "off")" } ?? "none")",
                "Excluded components: \(decomposition.excludedComponents.sorted().map { "IC \($0 + 1) \(decomposition.labels[$0] ?? "")" }.joined(separator: ", ").nilIfEmpty ?? "none")"
            ]
        } else {
            lines += ["", "## ICA Decomposition", "No ICA decomposition is currently available."]
        }

        lines += [
            "",
            "## Signal Stats",
            debugStatsLine("Raw full", signal: rawSignal),
            debugStatsLine("Base full", signal: base),
            debugStatsLine("Processed full", signal: processed)
        ]

        if let corrected = gradient.correctedSignal {
            lines.append(debugStatsLine("MRI-corrected full", signal: corrected))
        }
        if let cleaned = ica.cleanedSignal {
            lines.append(debugStatsLine("ICA-cleaned full", signal: cleaned))
        }
        if let filteredFull = filter.output {
            lines.append(debugStatsLine("Filtered full", signal: filteredFull))
        }
        if let visibleRange {
            lines += [
                "",
                "## Visible Window Stats",
                debugStatsLine("Raw visible", signal: rawSignal, sampleRange: clippedSampleRange(visibleRange, in: rawSignal)),
                debugStatsLine("Processed visible", signal: processed, sampleRange: clippedSampleRange(visibleRange, in: processed))
            ]
            if let cleaned = ica.cleanedSignal {
                lines.append(debugStatsLine("ICA-cleaned visible", signal: cleaned, sampleRange: clippedSampleRange(visibleRange, in: cleaned)))
            }
            if let filteredVisible = filter.output {
                lines.append(debugStatsLine("Filtered visible", signal: filteredVisible, sampleRange: clippedSampleRange(visibleRange, in: filteredVisible)))
            }
        }

        if let report = ica.lastReconstructionDebugReport {
            lines += ["", report]
        } else {
            lines += ["", "## Last ICA Removal", "No ICA component removal has been recorded in this window yet."]
        }

        return lines.joined(separator: "\n")
    }

    func icaReconstructionDebugReport(
        beforeBase: MFFSignalData,
        beforeDisplay: MFFSignalData,
        activationSignal: MFFSignalData?,
        afterBase: MFFSignalData,
        afterDisplay: MFFSignalData,
        decomposition: ICADecomposition,
        excludedComponents: Set<Int>
    ) -> String {
        let beforeStats = debugSignalStats(beforeDisplay)
        let afterStats = debugSignalStats(afterDisplay)
        let rmsRatio = beforeStats.rms > 0 ? afterStats.rms / beforeStats.rms : .nan
        let p99Ratio = beforeStats.p99Abs > 0 ? afterStats.p99Abs / beforeStats.p99Abs : .nan

        var lines: [String] = [
            "## Last ICA Removal",
            "Excluded components: \(excludedComponents.sorted().map { "IC \($0 + 1) \(decomposition.labels[$0] ?? "")" }.joined(separator: ", ").nilIfEmpty ?? "none")",
            "Before display signal type: \(beforeDisplay.signalType)",
            "After display signal type: \(afterDisplay.signalType)",
            "Display RMS ratio after/before: \(String(format: "%.3f", rmsRatio))",
            "Display p99 abs ratio after/before: \(String(format: "%.3f", p99Ratio))",
            debugStatsLine("Before base full", signal: beforeBase),
            activationSignal.map { debugStatsLine("ICA activation full", signal: $0) },
            debugStatsLine("After base full", signal: afterBase),
            debugStatsLine("Before display full", signal: beforeDisplay),
            debugStatsLine("After display full", signal: afterDisplay)
        ].compactMap { $0 }

        if let range = visibleSampleRange(in: beforeDisplay),
           let beforeRange = clippedSampleRange(range, in: beforeDisplay),
           let afterRange = clippedSampleRange(range, in: afterDisplay) {
            lines += [
                debugStatsLine("Before display visible", signal: beforeDisplay, sampleRange: beforeRange),
                activationSignal.flatMap { activation in
                    clippedSampleRange(range, in: activation).map {
                        debugStatsLine("ICA activation visible", signal: activation, sampleRange: $0)
                    }
                },
                debugStatsLine("After display visible", signal: afterDisplay, sampleRange: afterRange)
            ].compactMap { $0 }
        }

        return lines.joined(separator: "\n")
    }

    func visibleSampleRange(in signal: MFFSignalData) -> ClosedRange<Int>? {
        guard horizontalViewportWidth > 1, signal.data.first?.isEmpty == false else { return nil }
        let lower = sampleIndex(forContentX: horizontalOffset, in: signal)
        let upper = sampleIndex(forContentX: horizontalOffset + horizontalViewportWidth, in: signal)
        return min(lower, upper)...max(lower, upper)
    }

    func clippedSampleRange(_ range: ClosedRange<Int>, in signal: MFFSignalData) -> ClosedRange<Int>? {
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return nil }
        let lower = min(max(range.lowerBound, 0), sampleCount - 1)
        let upper = min(max(range.upperBound, lower), sampleCount - 1)
        return lower...upper
    }

    func debugStatsLine(_ label: String, signal: MFFSignalData, sampleRange: ClosedRange<Int>? = nil) -> String {
        let stats = debugSignalStats(signal, sampleRange: sampleRange)
        return "\(label): \(stats.summary)"
    }

    func debugSignalStats(_ signal: MFFSignalData, sampleRange: ClosedRange<Int>? = nil) -> ICADebugSignalStats {
        ICADebugSignalStats.make(signal: signal, sampleRange: sampleRange)
    }


}
