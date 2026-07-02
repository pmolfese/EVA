//
//  ArtifactPreviewViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Self-contained artifact- and wavelet-cleaning preview / hover-button / OBS
//  option views (and their small data types) extracted from WaveformView
//  (REFACTOR.md L5). Pure presentation.
//

import SwiftUI

struct ArtifactTemplateFieldLabel: View {
    let title: String
    let help: String
    @State private var showsHelp = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))

            Button {
                showsHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(help)
            .popover(isPresented: $showsHelp, arrowEdge: .trailing) {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 260, alignment: .leading)
            }
        }
    }
}

struct HoverPinnedPreviewButton<PreviewContent: View>: View {
    let helpText: String
    @ViewBuilder var previewContent: () -> PreviewContent

    @State private var showsPreview = false
    @State private var isPreviewPinned = false
    @State private var isButtonHovered = false
    @State private var isPopoverHovered = false
    @State private var hoverTask: Task<Void, Never>?

    private var previewPresentation: Binding<Bool> {
        Binding {
            showsPreview
        } set: { isPresented in
            showsPreview = isPresented
            if !isPresented {
                isPreviewPinned = false
                isPopoverHovered = false
            }
        }
    }

    var body: some View {
        Button {
            isPreviewPinned.toggle()
            showsPreview = isPreviewPinned
            if !showsPreview {
                hoverTask?.cancel()
            }
        } label: {
            Image(systemName: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            isButtonHovered = hovering
            schedulePreviewVisibility()
        }
        .popover(isPresented: previewPresentation, arrowEdge: .trailing) {
            previewContent()
                .onHover { hovering in
                    isPopoverHovered = hovering
                    schedulePreviewVisibility()
                }
        }
        .onDisappear {
            hoverTask?.cancel()
        }
    }

    private func schedulePreviewVisibility() {
        hoverTask?.cancel()
        guard !isPreviewPinned else { return }
        let shouldShow = isButtonHovered || isPopoverHovered
        let delay: UInt64 = shouldShow ? 80_000_000 : 220_000_000
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            showsPreview = isButtonHovered || isPopoverHovered
        }
    }
}

struct ArtifactCleaningPreviewButton: View {
    let artifact: DefinedArtifact
    let beforeSignal: MFFSignalData
    let afterSignal: MFFSignalData?
    let layout: SensorLayout?

    var body: some View {
        HoverPinnedPreviewButton(helpText: "Preview artifact cleanup") {
            ArtifactCleaningPreview(
                artifact: artifact,
                beforeSignal: beforeSignal,
                afterSignal: afterSignal,
                layout: layout
            )
        }
    }
}

struct WaveletCleaningPreviewButton: View {
    let candidate: WaveletArtifactCandidate
    let signal: MFFSignalData
    let configuration: WaveletCleaningConfiguration

    var body: some View {
        HoverPinnedPreviewButton(helpText: "Preview wavelet cleanup") {
            WaveletCleaningPreview(
                candidate: candidate,
                signal: signal,
                configuration: configuration
            )
        }
    }
}

struct WaveletCleaningPreview: View {
    let candidate: WaveletArtifactCandidate
    let signal: MFFSignalData
    let configuration: WaveletCleaningConfiguration

    @State private var preview: WaveletCleaningPreviewResult?
    @State private var isLoadingPreview = false

    private var previewLoadID: String {
        [
            candidate.id,
            configuration.pipeline.rawValue,
            configuration.mode.rawValue,
            configuration.waveletFamily.rawValue,
            configuration.thresholdModel.rawValue,
            configuration.thresholdRule.rawValue,
            "\(configuration.levelCount)",
            String(format: "%.3f", configuration.thresholdScale),
            String(format: "%.3f", configuration.intensity),
            configuration.channelIndices.map(String.init).joined(separator: ","),
            String(format: "%.3f", configuration.paddingSeconds),
            String(format: "%.3f", signal.duration)
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wavelet Cleaning Preview")
                        .font(.headline)
                    Text("Candidate \(candidate.rank) · Ch \(candidate.channelIndex + 1) · \(Self.timeString(candidate.peakTimeSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(configuration.pipeline.rawValue) · \(configuration.mode.rawValue) · \(configuration.waveletFamily.rawValue) · \(configuration.thresholdModel.rawValue) · \(configuration.thresholdRule.rawValue)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let preview {
                let sharedScale = Self.waveformScale([
                    preview.beforeAverage,
                    preview.artifactAverage,
                    preview.afterAverage
                ])
                let removedScale = Self.waveformScale([preview.artifactAverage])
                let removedSubtitle = Self.removedScaleSubtitle(
                    sharedScale: sharedScale,
                    removedScale: removedScale
                )
                let removedPlotScale = removedSubtitle == nil ? sharedScale : removedScale

                metricsView(preview.metrics)

                HStack(spacing: 10) {
                    waveformPreview(
                        title: "Before",
                        average: preview.beforeAverage,
                        scale: sharedScale
                    )
                    waveformPreview(
                        title: "Removed",
                        subtitle: removedSubtitle,
                        average: preview.artifactAverage,
                        scale: removedPlotScale
                    )
                    waveformPreview(
                        title: "After",
                        average: preview.afterAverage,
                        scale: sharedScale
                    )
                }

                removedEnergyHeatmap(preview.channelRemovedEnergy)

                Text("Preview window \(Self.timeString(preview.startTimeSeconds))-\(Self.timeString(preview.endTimeSeconds)); \(configuration.channelIndices.count) channels cleaned with \(configuration.levelCount) undecimated levels, \(configuration.thresholdModel.rawValue), \(String(format: "%.2f", configuration.intensity))x intensity, and a \(String(format: "%.2f", configuration.thresholdScale))x effective gate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLoadingPreview {
                loadingPreview
            } else {
                Text("No valid wavelet cleanup preview could be computed for this candidate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 700, height: 430, alignment: .topLeading)
        .task(id: previewLoadID) {
            await loadPreview()
        }
    }

    @MainActor
    private func loadPreview() async {
        isLoadingPreview = true
        preview = nil
        let signal = signal
        let candidate = candidate
        let configuration = configuration
        let result = await Task.detached(priority: .userInitiated) {
            WaveletArtifactAnalyzer.cleaningPreview(
                in: signal,
                candidate: candidate,
                configuration: configuration
            )
        }.value
        guard !Task.isCancelled else { return }
        preview = result
        isLoadingPreview = false
    }

    private func metricsView(_ metrics: WaveletCleaningPreviewMetrics) -> some View {
        HStack(spacing: 8) {
            metricChip(
                title: "Variance kept",
                value: String(format: "%.0f%%", metrics.varianceRetainedPercent),
                detail: "Remaining variance"
            )
            metricChip(
                title: "Shape r",
                value: String(format: "%.3f", metrics.correlation),
                detail: "Before/after similarity"
            )
            metricChip(
                title: "Removed RMS",
                value: Self.microvoltString(Float(metrics.removedRMSMicrovolts)),
                detail: "Mean removed amplitude"
            )
            metricChip(
                title: "Peak drop",
                value: String(format: "%.0f%%", metrics.peakReductionPercent),
                detail: "Peak amplitude reduction"
            )
        }
    }

    private func metricChip(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func removedEnergyHeatmap(_ channels: [WaveletCleaningChannelEnergy]) -> some View {
        let sortedChannels = channels.sorted { $0.channelIndex < $1.channelIndex }
        let columns = Array(repeating: GridItem(.fixed(22), spacing: 4), count: 24)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Removed energy by channel")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(strongestRemovedEnergyText(sortedChannels))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(sortedChannels) { channel in
                    let intensity = min(max(channel.normalizedRemovedEnergy, 0), 1)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(removedEnergyColor(intensity))
                        .frame(width: 22, height: 14)
                        .overlay {
                            Text("\(channel.channelIndex + 1)")
                                .font(.system(size: 6, weight: .semibold, design: .monospaced))
                                .foregroundStyle(intensity > 0.60 ? Color.white : Color.primary.opacity(0.65))
                        }
                        .help(removedEnergyHelp(channel))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func removedEnergyColor(_ intensity: Double) -> Color {
        let value = min(max(intensity, 0), 1)
        return Color(
            red: 0.18 + 0.78 * value,
            green: 0.42 - 0.16 * value,
            blue: 0.72 - 0.58 * value,
            opacity: 0.22 + 0.76 * value
        )
    }

    private func strongestRemovedEnergyText(_ channels: [WaveletCleaningChannelEnergy]) -> String {
        let strongest = channels.sorted {
            if $0.normalizedRemovedEnergy == $1.normalizedRemovedEnergy {
                return $0.channelIndex < $1.channelIndex
            }
            return $0.normalizedRemovedEnergy > $1.normalizedRemovedEnergy
        }
        .prefix(3)
        .map { "Ch \($0.channelIndex + 1) \(Self.microvoltString(Float($0.removedRMSMicrovolts)))" }

        return strongest.isEmpty ? "No removed energy" : strongest.joined(separator: " · ")
    }

    private func removedEnergyHelp(_ channel: WaveletCleaningChannelEnergy) -> String {
        [
            "Ch \(channel.channelIndex + 1)",
            "removed RMS \(Self.microvoltString(Float(channel.removedRMSMicrovolts)))",
            "peak \(Self.microvoltString(channel.peakRemovedMicrovolts))",
            String(format: "energy %.1f%% of local signal", min(max(channel.removedEnergyFraction, 0), 9.99) * 100)
        ].joined(separator: "\n")
    }

    private func waveformPreview(
        title: String,
        subtitle: String? = nil,
        average: ArtifactTemplateAverage,
        scale: Float?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            ArtifactTemplateAveragePlot(
                average: average,
                primaryChannel: candidate.channelIndex,
                highlightedChannels: [candidate.channelIndex],
                fixedScaleMicrovolts: scale,
                maximumBackgroundChannels: 18,
                usesAmplitudeWeightedOpacity: true
            )
            .frame(height: 112)
        }
        .frame(maxWidth: .infinity)
    }

    private var loadingPreview: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.08))
            .overlay {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Computing local wavelet reconstruction...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 170)
    }

    nonisolated private static func waveformScale(_ averages: [ArtifactTemplateAverage]) -> Float? {
        let maxAbs = averages
            .flatMap { $0.allChannelSamples }
            .flatMap { $0.map(abs) }
            .max() ?? 0
        return maxAbs > 0 ? maxAbs : nil
    }

    nonisolated private static func removedScaleSubtitle(sharedScale: Float?, removedScale: Float?) -> String? {
        guard let sharedScale,
              let removedScale,
              sharedScale > 0,
              removedScale > 0,
              sharedScale > removedScale * 1.5 else {
            return nil
        }
        return String(format: "%.1fx", sharedScale / removedScale)
    }

    nonisolated private static func microvoltString(_ value: Float) -> String {
        if value >= 100 {
            return String(format: "%.0f µV", value)
        }
        if value >= 10 {
            return String(format: "%.1f µV", value)
        }
        return String(format: "%.2f µV", value)
    }

    nonisolated private static func timeString(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%06.3f", minutes, remainingSeconds)
        }
        return String(format: "%.3fs", seconds)
    }
}

struct ArtifactOBSOptionsButton: View {
    @Binding var artifact: DefinedArtifact
    let signal: MFFSignalData
    @Binding var reportCache: [String: OBSPCAVarianceReport]
    let onSettingsChange: () -> Void

    @State private var showsOptions = false

    var body: some View {
        Button("Options...") {
            showsOptions = true
        }
        .font(.caption)
        .sheet(isPresented: $showsOptions) {
            ArtifactOBSOptionsSheet(
                artifact: $artifact,
                signal: signal,
                reportCache: $reportCache,
                onSettingsChange: onSettingsChange
            )
        }
    }
}

struct ArtifactOBSOptionsSheet: View {
    @Binding var artifact: DefinedArtifact
    let signal: MFFSignalData
    @Binding var reportCache: [String: OBSPCAVarianceReport]
    let onSettingsChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var report: OBSPCAVarianceReport?
    @State private var isLoadingReport = false

    private var showsOBSVarianceOptions: Bool {
        artifact.cleaningMethod == .obs
    }

    private var componentCountBinding: Binding<Int> {
        Binding {
            artifact.obsPCAComponentCount
        } set: { newValue in
            let bounded = min(max(newValue, 0), DefinedArtifact.maximumOBSComponentCount)
            guard artifact.obsPCAComponentCount != bounded else { return }
            artifact.obsPCAComponentCount = bounded
            onSettingsChange()
        }
    }

    private var selectedCumulativeVariance: Double {
        report?.cumulativeVariance(for: artifact.obsPCAComponentCount) ?? 0
    }

    private var edgeTaperBinding: Binding<Double> {
        Binding {
            artifact.obsEdgeTaperSeconds
        } set: { newValue in
            let bounded = min(max(newValue, 0), DefinedArtifact.maximumOBSEdgeTaperSeconds)
            guard abs(artifact.obsEdgeTaperSeconds - bounded) > 0.0001 else { return }
            artifact.obsEdgeTaperSeconds = bounded
            onSettingsChange()
        }
    }

    private var preservesLocalBaselineBinding: Binding<Bool> {
        Binding {
            artifact.obsPreservesLocalBaseline
        } set: { newValue in
            guard artifact.obsPreservesLocalBaseline != newValue else { return }
            artifact.obsPreservesLocalBaseline = newValue
            onSettingsChange()
        }
    }

    private var usesOverlapAddBinding: Binding<Bool> {
        Binding {
            artifact.obsUsesOverlapAdd
        } set: { newValue in
            guard artifact.obsUsesOverlapAdd != newValue else { return }
            artifact.obsUsesOverlapAdd = newValue
            onSettingsChange()
        }
    }

    private var reportCacheKey: String {
        [
            artifact.id.uuidString,
            artifact.cleaningMethod.rawValue,
            "\(artifact.eventCount)",
            "\(artifact.events.first?.beginTimeSeconds ?? -1)",
            "\(artifact.events.last?.beginTimeSeconds ?? -1)",
            "\(artifact.windowSizeSeconds)",
            "\(artifact.obsEdgeTaperSeconds)",
            "\(signal.signalURL.path)",
            "\(signal.samplingRate)",
            "\(signal.duration)",
            "\(DefinedArtifact.maximumOBSComponentCount)"
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(artifact.cleaningMethod.rawValue) Options")
                        .font(.title3.weight(.semibold))
                    Text(artifact.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(artifact.eventCount) events")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if showsOBSVarianceOptions {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: componentCountBinding, in: 0...DefinedArtifact.maximumOBSComponentCount) {
                        Text("PCA components: \(artifact.obsPCAComponentCount)")
                            .font(.callout.weight(.medium))
                    }

                    Text("OBS always removes the mean artifact waveform; PCA components model the remaining event-to-event residual shape.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("SSP/PCA uses the edge settings below to fade the spatial projection in and out around each event.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Edge handling")
                    .font(.callout.weight(.medium))

                HStack(spacing: 10) {
                    Text("Edge taper")
                        .frame(width: 88, alignment: .leading)
                    Slider(
                        value: edgeTaperBinding,
                        in: 0...DefinedArtifact.maximumOBSEdgeTaperSeconds,
                        step: 0.01
                    )
                    Text("\(Int((artifact.obsEdgeTaperSeconds * 1000).rounded())) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .help("Adds this much padding before and after each event, then ramps the OBS correction smoothly from zero at the padded edges.")

                Toggle("Preserve local baseline", isOn: preservesLocalBaselineBinding)
                    .help("Removes local DC/slope from the correction so the cleaned segment keeps the surrounding slow baseline.")

                Toggle("Weighted overlap-add for nearby events", isOn: usesOverlapAddBinding)
                    .help("Combines overlapping OBS correction windows with weights so close events do not get over-subtracted where they overlap.")

                Text("Windowed corrections are forced to zero at the padded boundaries before tapering, which helps avoid step-like edges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsOBSVarianceOptions {
                if isLoadingReport {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Fitting residual PCA to artifact windows...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let report {
                    obsVarianceReportView(report)
                } else {
                    ContentUnavailableView(
                        "No OBS PCA Estimate",
                        systemImage: "chart.bar.xaxis",
                        description: Text("There were not enough valid artifact windows to estimate residual PCA variance.")
                    )
                    .frame(height: 180)
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .task(id: reportCacheKey) {
            await loadReport()
        }
    }

    private func obsVarianceReportView(_ report: OBSPCAVarianceReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Selected components account for \(Self.percent(selectedCumulativeVariance)) of residual variance.")
                    .font(.callout.weight(.medium))
                ProgressView(value: selectedCumulativeVariance)
                    .progressViewStyle(.linear)
                Text("\(Self.percent(max(1 - selectedCumulativeVariance, 0))) residual variance remains after the selected PCA components.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                obsReportChip(title: "Valid", value: "\(report.validEventCount)/\(report.eventCount)")
                obsReportChip(title: "Sampled", value: "\(report.sampledEventCount)")
                obsReportChip(title: "Channels", value: "\(report.channelCount)")
                obsReportChip(title: "Window", value: "\(report.windowSampleCount)")
            }

            if report.components.isEmpty {
                Text("The residual windows have no measurable PCA variance after subtracting the mean artifact waveform.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        Text("Component")
                        Text("Adds")
                        Text("Cumulative")
                        Text("Remaining")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    ForEach(report.components) { component in
                        GridRow {
                            Label("\(component.componentIndex)", systemImage: component.componentIndex <= artifact.obsPCAComponentCount ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(component.componentIndex <= artifact.obsPCAComponentCount ? .green : .secondary)
                            Text(Self.percent(component.explainedVariance))
                            Text(Self.percent(component.cumulativeVariance))
                            Text(Self.percent(component.remainingVariance))
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }

    private func obsReportChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func loadReport() async {
        guard showsOBSVarianceOptions else {
            report = nil
            isLoadingReport = false
            return
        }

        let key = reportCacheKey
        if let cachedReport = reportCache[key] {
            report = cachedReport
            isLoadingReport = false
            return
        }

        isLoadingReport = true
        report = nil
        let artifact = artifact
        let signal = signal
        let fittedReport = await Task.detached(priority: .userInitiated) {
            ArtifactCleaner.obsVarianceReport(for: artifact, in: signal)
        }.value
        guard !Task.isCancelled else { return }
        report = fittedReport
        if let fittedReport {
            reportCache[key] = fittedReport
        }
        isLoadingReport = false
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

struct ArtifactCleaningPreviewData: Sendable {
    var beforeAverage: ArtifactTemplateAverage?
    var afterAverage: ArtifactTemplateAverage?
    var beforeTopographyValues: [Double]?
    var afterTopographyValues: [Double]?
    var topographyScale: Double?
    var waveformScaleMicrovolts: Float?
    var afterScaleMicrovolts: Float?
    var reductionMetrics: ArtifactCleaningReductionMetrics?
}

struct ArtifactCleaningReductionMetrics: Sendable {
    var beforePeakMicrovolts: Float
    var afterPeakMicrovolts: Float
    var beforeRMSMicrovolts: Float
    var afterRMSMicrovolts: Float

    var peakReduction: Double? {
        reduction(before: beforePeakMicrovolts, after: afterPeakMicrovolts)
    }

    var rmsReduction: Double? {
        reduction(before: beforeRMSMicrovolts, after: afterRMSMicrovolts)
    }

    private func reduction(before: Float, after: Float) -> Double? {
        guard before > 1e-6 else { return nil }
        return max(0, min(1, 1 - Double(after / before)))
    }
}

struct ArtifactCleaningPreview: View {
    let artifact: DefinedArtifact
    let beforeSignal: MFFSignalData
    let afterSignal: MFFSignalData?
    let layout: SensorLayout?

    @State private var previewData: ArtifactCleaningPreviewData?
    @State private var isLoadingPreview = false
    @State private var magnifiesResidual = false

    private var previewLoadID: String {
        [
            artifact.id.uuidString,
            artifact.appliedMethod?.rawValue ?? artifact.cleaningMethod.rawValue,
            afterSignal?.signalType ?? "no-after",
            String(afterSignal?.duration ?? 0)
        ].joined(separator: "-")
    }

    private var previewHeight: CGFloat {
        artifact.topography != nil && layout != nil ? 540 : 285
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(artifact.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(artifact.appliedMethod?.rawValue ?? artifact.cleaningMethod.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if artifact.topography != nil, let layout {
                if let previewData,
                   let beforeValues = previewData.beforeTopographyValues,
                   let afterValues = previewData.afterTopographyValues {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Topography")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            topographyPreview(title: "Before", layout: layout, values: beforeValues, scale: previewData.topographyScale)
                            topographyPreview(title: "After", layout: layout, values: afterValues, scale: previewData.topographyScale)
                        }
                    }
                } else if isLoadingPreview {
                    loadingPreview(title: "Topography", height: 180)
                }
            }

            if let beforeAverage = previewData?.beforeAverage {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Average Waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if previewData?.afterAverage != nil {
                            Toggle("Magnify residual", isOn: $magnifiesResidual)
                                .toggleStyle(.checkbox)
                                .font(.caption2)
                                .help("Use an independent y-axis for the After plot to inspect small residual activity.")
                        }
                    }
                    if let metrics = previewData?.reductionMetrics {
                        reductionMetricsView(metrics)
                    }
                    HStack(spacing: 10) {
                        waveformPreview(
                            title: "Before",
                            subtitle: sharedScaleSubtitle,
                            average: beforeAverage,
                            scale: previewData?.waveformScaleMicrovolts
                        )
                        if let afterAverage = previewData?.afterAverage {
                            waveformPreview(
                                title: "After",
                                subtitle: afterWaveformSubtitle,
                                average: afterAverage,
                                scale: afterWaveformScale
                            )
                        } else {
                            missingPreview(title: "After")
                        }
                    }
                }
            } else if isLoadingPreview {
                loadingPreview(title: "Average Waveform", height: 110)
            } else {
                Text("No preview average available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 320, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 520, height: previewHeight, alignment: .topLeading)
        .task(id: previewLoadID) {
            await loadPreview()
        }
    }

    @MainActor
    private func loadPreview() async {
        isLoadingPreview = true
        previewData = nil
        let artifact = artifact
        let beforeSignal = beforeSignal
        let afterSignal = afterSignal
        let data = await Task.detached(priority: .userInitiated) {
            Self.makePreviewData(
                artifact: artifact,
                beforeSignal: beforeSignal,
                afterSignal: afterSignal
            )
        }.value
        guard !Task.isCancelled else { return }
        previewData = data
        isLoadingPreview = false
    }

    private var afterWaveformScale: Float? {
        guard magnifiesResidual else {
            return previewData?.waveformScaleMicrovolts
        }
        return previewData?.afterScaleMicrovolts ?? previewData?.waveformScaleMicrovolts
    }

    private var sharedScaleSubtitle: String? {
        guard !magnifiesResidual, previewData?.afterAverage != nil else { return nil }
        return "Shared scale"
    }

    private var afterWaveformSubtitle: String? {
        guard magnifiesResidual,
              let sharedScale = previewData?.waveformScaleMicrovolts,
              let afterScale = previewData?.afterScaleMicrovolts,
              afterScale > 0,
              sharedScale > afterScale * 1.1 else {
            return sharedScaleSubtitle
        }
        return String(format: "%.1fx residual scale", sharedScale / afterScale)
    }

    private func reductionMetricsView(_ metrics: ArtifactCleaningReductionMetrics) -> some View {
        HStack(spacing: 8) {
            metricChip(
                title: "Peak",
                value: "\(Self.microvoltString(metrics.beforePeakMicrovolts)) -> \(Self.microvoltString(metrics.afterPeakMicrovolts))",
                reduction: metrics.peakReduction
            )
            metricChip(
                title: "RMS",
                value: "\(Self.microvoltString(metrics.beforeRMSMicrovolts)) -> \(Self.microvoltString(metrics.afterRMSMicrovolts))",
                reduction: metrics.rmsReduction
            )
        }
    }

    private func metricChip(title: String, value: String, reduction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let reduction {
                    Text(Self.percentString(reduction))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func waveformPreview(
        title: String,
        subtitle: String?,
        average: ArtifactTemplateAverage,
        scale: Float?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ArtifactTemplateAveragePlot(
                average: average,
                primaryChannel: nil,
                highlightedChannels: Set(artifact.selectedChannelIndices),
                fixedScaleMicrovolts: scale,
                maximumBackgroundChannels: 18,
                usesAmplitudeWeightedOpacity: true
            )
            .frame(height: 110)
        }
        .frame(maxWidth: .infinity)
    }

    private func missingPreview(title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
                .overlay {
                    Text("Not applied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 110)
        }
        .frame(maxWidth: .infinity)
    }

    private func topographyPreview(title: String, layout: SensorLayout, values: [Double], scale: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TopomapView(
                layout: layout,
                values: values,
                timeSeconds: artifact.topography?.referenceTimeSeconds ?? 0,
                fixedScale: scale,
                showsHeader: false,
                colorBarPlacement: .bottom,
                minimumMapHeight: 130
            )
            .frame(height: 180)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }

    private func loadingPreview(title: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
                .overlay {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing preview...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: height)
        }
    }

    nonisolated private static func makePreviewData(
        artifact: DefinedArtifact,
        beforeSignal: MFFSignalData,
        afterSignal: MFFSignalData?
    ) -> ArtifactCleaningPreviewData {
        let beforeAverage = average(in: beforeSignal, artifact: artifact)
            ?? artifact.average.map(baselineAlignedAverage)
        let afterAverage = afterSignal.flatMap { average(in: $0, artifact: artifact) }
        let beforeTopographyValues = beforeAverage.flatMap(centerValues(from:))
        let afterTopographyValues = afterAverage.flatMap(centerValues(from:))

        return ArtifactCleaningPreviewData(
            beforeAverage: beforeAverage,
            afterAverage: afterAverage,
            beforeTopographyValues: beforeTopographyValues,
            afterTopographyValues: afterTopographyValues,
            topographyScale: topographyScale(beforeTopographyValues, afterTopographyValues),
            waveformScaleMicrovolts: waveformScale(beforeAverage, afterAverage),
            afterScaleMicrovolts: waveformScale(afterAverage),
            reductionMetrics: reductionMetrics(beforeAverage: beforeAverage, afterAverage: afterAverage, artifact: artifact)
        )
    }

    nonisolated private static func waveformScale(_ averages: ArtifactTemplateAverage?...) -> Float? {
        let maxAbs = averages.compactMap { $0 }.flatMap { average in
            average.allChannelSamples.flatMap { $0.map(abs) }
        }.max() ?? 0
        return maxAbs > 0 ? maxAbs : nil
    }

    nonisolated private static func reductionMetrics(
        beforeAverage: ArtifactTemplateAverage?,
        afterAverage: ArtifactTemplateAverage?,
        artifact: DefinedArtifact
    ) -> ArtifactCleaningReductionMetrics? {
        guard let beforeAverage, let afterAverage else { return nil }
        let before = waveformMetrics(for: beforeAverage, preferredChannels: artifact.selectedChannelIndices)
        let after = waveformMetrics(for: afterAverage, preferredChannels: artifact.selectedChannelIndices)
        return ArtifactCleaningReductionMetrics(
            beforePeakMicrovolts: before.peak,
            afterPeakMicrovolts: after.peak,
            beforeRMSMicrovolts: before.rms,
            afterRMSMicrovolts: after.rms
        )
    }

    nonisolated private static func waveformMetrics(
        for average: ArtifactTemplateAverage,
        preferredChannels: [Int]
    ) -> (peak: Float, rms: Float) {
        let validPreferredChannels = preferredChannels.filter {
            average.allChannelSamples.indices.contains($0)
        }
        let channels = validPreferredChannels.isEmpty
            ? Array(average.allChannelSamples.indices)
            : validPreferredChannels
        var peak: Float = 0
        var squareSum = 0.0
        var sampleCount = 0
        for channel in channels {
            for value in average.allChannelSamples[channel] {
                peak = max(peak, abs(value))
                squareSum += Double(value * value)
                sampleCount += 1
            }
        }
        let rms = sampleCount > 0 ? Float(sqrt(squareSum / Double(sampleCount))) : 0
        return (peak, rms)
    }

    nonisolated private static func microvoltString(_ value: Float) -> String {
        if value >= 100 {
            return String(format: "%.0f µV", value)
        }
        if value >= 10 {
            return String(format: "%.1f µV", value)
        }
        return String(format: "%.2f µV", value)
    }

    nonisolated private static func percentString(_ value: Double) -> String {
        String(format: "%.0f%% reduction", value * 100)
    }

    nonisolated private static func topographyScale(_ before: [Double]?, _ after: [Double]?) -> Double? {
        guard let before, let after else { return nil }
        let maxAbs = (before + after).map(abs).max() ?? 0
        return maxAbs > 0 ? maxAbs : nil
    }

    nonisolated private static func centerValues(from average: ArtifactTemplateAverage) -> [Double]? {
        guard let sampleCount = average.allChannelSamples.first?.count, sampleCount > 0 else { return nil }
        let center = sampleCount / 2
        return average.allChannelSamples.map { samples in
            center < samples.count ? Double(samples[center]) : 0
        }
    }

    nonisolated private static func average(in signal: MFFSignalData, artifact: DefinedArtifact) -> ArtifactTemplateAverage? {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0,
              !artifact.events.isEmpty else {
            return nil
        }

        let windowSamples = artifact.average?.allChannelSamples.first?.count
            ?? max(Int((artifact.windowSizeSeconds * signal.samplingRate).rounded()), 3)
        guard windowSamples > 1, sampleCount >= windowSamples else { return nil }

        let edgeSamples = previewBaselineEdgeSamples(windowSamples: windowSamples, samplingRate: signal.samplingRate)
        let firstCenter = Double(edgeSamples - 1) / 2
        let lastCenter = Double(windowSamples - edgeSamples) + firstCenter
        let baselineDenominator = max(lastCenter - firstCenter, 1)
        var averages = Array(repeating: [Float](repeating: 0, count: windowSamples), count: signal.numberOfChannels)
        var accepted = 0
        for event in artifact.events {
            let center = Int((event.beginTimeSeconds * signal.samplingRate).rounded())
            let start = center - windowSamples / 2
            let end = start + windowSamples
            guard start >= 0, end <= sampleCount else { continue }

            for channelIndex in signal.data.indices where signal.data[channelIndex].count >= end {
                let channelData = signal.data[channelIndex]
                let firstMean = mean(channelData, start: start, count: edgeSamples)
                let lastMean = mean(channelData, start: end - edgeSamples, count: edgeSamples)
                let slope = (lastMean - firstMean) / baselineDenominator
                for offset in 0..<windowSamples {
                    let baseline = firstMean + slope * (Double(offset) - firstCenter)
                    averages[channelIndex][offset] += Float(Double(channelData[start + offset]) - baseline)
                }
            }
            accepted += 1
        }

        guard accepted > 0 else { return nil }
        let divisor = Float(accepted)
        for channelIndex in averages.indices {
            for sample in averages[channelIndex].indices {
                averages[channelIndex][sample] /= divisor
            }
        }

        var summaries: [ArtifactTemplateChannelSummary] = []
        summaries.reserveCapacity(averages.count)
        for channelIndex in averages.indices {
            let samples = averages[channelIndex]
            var peak: Float = 0
            var squareSum: Float = 0
            for value in samples {
                peak = max(peak, abs(value))
                squareSum += value * value
            }
            let divisor = Float(samples.isEmpty ? 1 : samples.count)
            let meanSquare = squareSum / divisor
            summaries.append(ArtifactTemplateChannelSummary(
                channelIndex: channelIndex,
                peakAbsoluteMicrovolts: peak,
                rmsMicrovolts: sqrt(meanSquare)
            ))
        }
        summaries.sort {
            $0.peakAbsoluteMicrovolts == $1.peakAbsoluteMicrovolts
                ? $0.channelIndex < $1.channelIndex
                : $0.peakAbsoluteMicrovolts > $1.peakAbsoluteMicrovolts
        }

        return ArtifactTemplateAverage(
            samplingRate: signal.samplingRate,
            windowSizeSeconds: Double(windowSamples) / signal.samplingRate,
            eventCount: accepted,
            selectedChannelIndices: artifact.selectedChannelIndices,
            allChannelSamples: averages,
            channelSummaries: summaries
        )
    }

    nonisolated private static func baselineAlignedAverage(_ average: ArtifactTemplateAverage) -> ArtifactTemplateAverage {
        guard let sampleCount = average.allChannelSamples.first?.count, sampleCount > 1 else {
            return average
        }

        let edgeSamples = previewBaselineEdgeSamples(windowSamples: sampleCount, samplingRate: average.samplingRate)
        let firstCenter = Double(edgeSamples - 1) / 2
        let lastCenter = Double(sampleCount - edgeSamples) + firstCenter
        let baselineDenominator = max(lastCenter - firstCenter, 1)
        var samples = average.allChannelSamples

        for channelIndex in samples.indices {
            let channelSamples = samples[channelIndex]
            guard channelSamples.count >= sampleCount else { continue }
            let firstMean = mean(channelSamples, start: 0, count: edgeSamples)
            let lastMean = mean(channelSamples, start: sampleCount - edgeSamples, count: edgeSamples)
            let slope = (lastMean - firstMean) / baselineDenominator
            for offset in 0..<sampleCount {
                let baseline = firstMean + slope * (Double(offset) - firstCenter)
                samples[channelIndex][offset] = Float(Double(channelSamples[offset]) - baseline)
            }
        }

        var summaries: [ArtifactTemplateChannelSummary] = []
        summaries.reserveCapacity(samples.count)
        for channelIndex in samples.indices {
            let channelSamples = samples[channelIndex]
            var peak: Float = 0
            var squareSum: Float = 0
            for value in channelSamples {
                peak = max(peak, abs(value))
                squareSum += value * value
            }
            let divisor = Float(channelSamples.isEmpty ? 1 : channelSamples.count)
            let meanSquare = squareSum / divisor
            summaries.append(ArtifactTemplateChannelSummary(
                channelIndex: channelIndex,
                peakAbsoluteMicrovolts: peak,
                rmsMicrovolts: sqrt(meanSquare)
            ))
        }
        summaries.sort {
            $0.peakAbsoluteMicrovolts == $1.peakAbsoluteMicrovolts
                ? $0.channelIndex < $1.channelIndex
                : $0.peakAbsoluteMicrovolts > $1.peakAbsoluteMicrovolts
        }

        return ArtifactTemplateAverage(
            samplingRate: average.samplingRate,
            windowSizeSeconds: average.windowSizeSeconds,
            eventCount: average.eventCount,
            selectedChannelIndices: average.selectedChannelIndices,
            allChannelSamples: samples,
            channelSummaries: summaries
        )
    }

    nonisolated private static func previewBaselineEdgeSamples(windowSamples: Int, samplingRate: Double) -> Int {
        let maximumByWindow = max(1, windowSamples / 4)
        let fractionCount = max(1, Int((Double(windowSamples) * 0.10).rounded()))
        let maximumByTime = samplingRate > 0
            ? max(1, Int((samplingRate * 0.10).rounded()))
            : fractionCount
        let minimumUsefulCount = min(3, maximumByWindow, maximumByTime)
        return min(max(fractionCount, minimumUsefulCount), maximumByWindow, maximumByTime)
    }

    nonisolated private static func mean(_ samples: [Float], start: Int, count: Int) -> Double {
        guard count > 0, start >= 0, start + count <= samples.count else { return 0 }
        var sum = 0.0
        for index in start..<(start + count) {
            sum += Double(samples[index])
        }
        return sum / Double(count)
    }
}
