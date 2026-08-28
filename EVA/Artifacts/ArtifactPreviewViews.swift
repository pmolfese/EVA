//
//  ArtifactPreviewViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Self-contained artifact- and wavelet-cleaning preview / hover-button / OBS
//  option views (and their small data types) extracted from WaveformView
//  (REFACTOR.md L5). Pure presentation.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

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

/// Explains every `ArtifactOBSStrategy` option in one popover, next to the
/// "OBS strategy" picker label. Unlike `ArtifactTemplateFieldLabel` (one
/// short string), this covers all seven strategies plus their published
/// reference, so it needs a scrollable, multi-section layout instead.
struct OBSStrategyHelpButton: View {
    @State private var showsHelp = false

    var body: some View {
        Button {
            showsHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Explain the OBS strategy options")
        .popover(isPresented: $showsHelp, arrowEdge: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("OBS Strategies")
                        .font(.headline)

                    Text("Optimal Basis Set (OBS) removes a stereotyped artifact (e.g. BCG, gradient) by fitting a low-rank basis to the detected event windows and subtracting the fitted component. All seven strategies below fit that same basis; they differ in how the fitting window is chosen or how the basis is applied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(ArtifactOBSStrategy.allCases) { strategy in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(strategy.rawValue)
                                    .font(.caption.weight(.semibold))
                                if strategy.requiresTopography {
                                    Text("needs topography")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if strategy.isExperimental {
                                    Text("Experimental")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.yellow.opacity(0.25), in: Capsule())
                                }
                            }
                            Text(strategy.helpText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    Text("Reference")
                        .font(.caption.weight(.semibold))
                    Text(ArtifactOBSStrategy.standard.reference ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("All strategies fit the same OBS basis described above; the topography-gated/-aligned/-weighted, virtual-channel, clustered, and spatiotemporal variants are EVA-specific refinements of it and have no separate published reference of their own.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
            }
            .frame(maxHeight: 420)
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
    var cleaningPreviewCache: [String: ArtifactCleaningPreviewData] = [:]

    var body: some View {
        HoverPinnedPreviewButton(helpText: "Preview artifact cleanup") {
            ArtifactCleaningPreview(
                artifact: artifact,
                beforeSignal: beforeSignal,
                afterSignal: afterSignal,
                layout: layout,
                cachedPreviewData: cleaningPreviewCache[
                    ArtifactCleaningPreview.cacheKey(
                        artifactID: artifact.id,
                        method: artifact.appliedMethod?.rawValue ?? artifact.cleaningMethod.rawValue,
                        afterSignal: afterSignal
                    )
                ]
            )
        }
    }
}

struct WaveletCleaningPreviewButton: View {
    let candidate: WaveletArtifactCandidate
    let signal: MFFSignalData
    let configuration: WaveletCleaningConfiguration
    /// Results precomputed right after a scan (see
    /// `WaveletArtifactExplorerViewModel.previewCache` /
    /// `precomputeWaveletExplorerPreviews`), keyed by `WaveletCleaningPreview
    /// .cacheKey`. When a hit exists, opening this preview is a dictionary
    /// lookup instead of a fresh decompose-threshold-reconstruct pass.
    var precomputed: [String: WaveletCleaningPreviewResult] = [:]

    var body: some View {
        HoverPinnedPreviewButton(helpText: "Preview wavelet cleanup") {
            WaveletCleaningPreview(
                candidate: candidate,
                signal: signal,
                configuration: configuration,
                precomputed: precomputed
            )
        }
    }
}

struct WaveletCleaningPreview: View {
    let candidate: WaveletArtifactCandidate
    let signal: MFFSignalData
    let configuration: WaveletCleaningConfiguration
    var precomputed: [String: WaveletCleaningPreviewResult] = [:]

    @State private var preview: WaveletCleaningPreviewResult?
    @State private var isLoadingPreview = false

    /// Cache key shared with the precompute pass — must stay in exact sync
    /// with every field the preview's result actually depends on, or a
    /// precomputed entry could be served for the wrong settings.
    static func cacheKey(
        candidateID: String,
        configuration: WaveletCleaningConfiguration,
        signalDuration: Double
    ) -> String {
        [
            candidateID,
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
            String(format: "%.3f", signalDuration)
        ].joined(separator: "|")
    }

    private var previewLoadID: String {
        Self.cacheKey(candidateID: candidate.id, configuration: configuration, signalDuration: signal.duration)
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
        if let cached = precomputed[previewLoadID] {
            preview = cached
            isLoadingPreview = false
            return
        }

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

struct WaveletScalogramButton: View {
    let candidate: WaveletArtifactCandidate
    let signal: MFFSignalData

    @State private var showsScalogram = false

    var body: some View {
        Button {
            showsScalogram.toggle()
        } label: {
            Image(systemName: "eye")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Show this candidate as a time-frequency-power view (what it looks like to the wavelet)")
        .popover(isPresented: $showsScalogram, arrowEdge: .trailing) {
            WaveletScalogramPopoverView(candidate: candidate, signal: signal)
        }
    }
}

struct WaveletScalogramPopoverView: View {
    let candidate: WaveletArtifactCandidate
    let signal: MFFSignalData

    @State private var result: WaveletScalogramResult?
    @State private var isLoading = false

    private var loadID: String {
        "\(candidate.id)|\(candidate.channelIndex)|\(signal.duration)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time-Frequency View")
                        .font(.headline)
                    Text("Candidate \(candidate.rank) · Ch \(candidate.channelIndex + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let result {
                    Text("\(Int(result.effectiveSamplingRate.rounded())) Hz analyzed")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let result {
                WaveletScalogramCanvas(result: result)
                    .frame(width: 520, height: 260)
                HStack(spacing: 10) {
                    Text("Low power").font(.caption2).foregroundStyle(.secondary)
                    scalogramColorLegend
                        .frame(width: 120, height: 10)
                    Text("High power").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(String(format: "%.2f", result.startTimeSeconds))s – \(String(format: "%.2f", result.endTimeSeconds))s")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Time on x, frequency on y (log-spaced), color is wavelet power (Morlet). Includes 0.5s of context on each side of the detected window so you can see the artifact against its surroundings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLoading {
                ProgressView("Computing time-frequency view…")
                    .frame(width: 520, height: 260)
            } else {
                Text("No scalogram could be computed for this candidate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 520, height: 260)
            }
        }
        .padding(14)
        .task(id: loadID) {
            isLoading = true
            result = nil
            let signal = signal
            let candidate = candidate
            let computed = await Task.detached(priority: .userInitiated) {
                WaveletScalogram.compute(
                    signal: signal,
                    channelIndex: candidate.channelIndex,
                    startSample: candidate.startSample,
                    endSample: candidate.endSample
                )
            }.value
            guard !Task.isCancelled else { return }
            result = computed
            isLoading = false
        }
    }

    private var scalogramColorLegend: some View {
        LinearGradient(
            colors: (0...8).map { WaveletScalogramCanvas.color(forNormalizedPower: Double($0) / 8) },
            startPoint: .leading,
            endPoint: .trailing
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Renders `power[frequencyIndex][timeIndex]` as a heatmap: time on x,
/// frequency on y (row 0 / lowest frequency at the bottom), color intensity
/// from a fixed blue→amber→red ramp on log-compressed, per-scalogram-
/// normalized power (log compression because wavelet power spans orders of
/// magnitude — a linear scale would make everything but the single loudest
/// cell look black).
struct WaveletScalogramCanvas: View {
    let result: WaveletScalogramResult

    var body: some View {
        GeometryReader { geo in
            let rows = result.power.count
            let columns = result.power.first?.count ?? 0
            Canvas { context, size in
                guard rows > 0, columns > 0 else { return }
                let maxPower = result.power.flatMap { $0 }.max() ?? 0
                guard maxPower > 1e-12 else { return }
                let logMax = log10(maxPower + 1e-12)
                // A cell 4 orders of magnitude below the peak reads as ~0 —
                // matches how sparse, transient wavelet power typically is.
                let logFloor = logMax - 4
                let cellWidth = size.width / CGFloat(columns)
                let cellHeight = size.height / CGFloat(rows)

                for row in 0..<rows {
                    for column in 0..<columns {
                        let value = result.power[row][column]
                        let logValue = log10(value + 1e-12)
                        let normalized = max(0, min(1, (logValue - logFloor) / (logMax - logFloor)))
                        let y = size.height - CGFloat(row + 1) * cellHeight
                        let rect = CGRect(x: CGFloat(column) * cellWidth, y: y, width: cellWidth + 1, height: cellHeight + 1)
                        context.fill(Path(rect), with: .color(Self.color(forNormalizedPower: normalized)))
                    }
                }
            }
            .overlay(alignment: .leading) {
                VStack {
                    Text(Self.frequencyLabel(result.frequenciesHz.last ?? 0))
                    Spacer()
                    Text(Self.frequencyLabel(result.frequenciesHz.first ?? 0))
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(3)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private static func frequencyLabel(_ hz: Double) -> String {
        hz >= 10 ? String(format: "%.0f Hz", hz) : String(format: "%.1f Hz", hz)
    }

    /// Flat blue → amber → red ramp (no perceptual-uniformity library
    /// available here) — good enough to read "where's the power," not meant
    /// as a publication colormap.
    static func color(forNormalizedPower value: Double) -> Color {
        let v = max(0, min(1, value))
        if v < 0.5 {
            let t = v / 0.5
            return Color(red: 0.05 + 0.1 * t, green: 0.05 + 0.35 * t, blue: 0.35 + 0.45 * t)
        } else {
            let t = (v - 0.5) / 0.5
            return Color(red: 0.15 + 0.85 * t, green: 0.4 + 0.2 * t, blue: 0.8 - 0.75 * t)
        }
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

struct ArtifactLocalTemplateOptionsButton: View {
    @Binding var artifact: DefinedArtifact
    let onSettingsChange: () -> Void

    @State private var showsOptions = false

    var body: some View {
        Button("Options...") {
            showsOptions = true
        }
        .font(.caption)
        .popover(isPresented: $showsOptions) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(artifact.cleaningMethod.rawValue) Options")
                        .font(.headline)

                    if artifact.cleaningMethod.isLocalTemplateMethod {
                        if artifact.type == .bcg {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(
                                    "AMRI BCG epoch preprocessing",
                                    isOn: Binding(
                                        get: { artifact.localTemplateUsesAMRIPreprocessing },
                                        set: { newValue in
                                            artifact.localTemplateUsesAMRIPreprocessing = newValue
                                            onSettingsChange()
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                Text("Matches amri_eeg_cbc.m's R-marker preprocessing: estimate each channel's median-power BCG delay, shift all windows by that delay, and mean-center epochs before template building. Leave off when events are already centered.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Divider()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Window size")
                                    .font(.caption)
                                Spacer()
                                Stepper(
                                    "\(artifact.localTemplateWindowSize) events",
                                    value: Binding(
                                        get: { artifact.localTemplateWindowSize },
                                        set: { newValue in
                                            artifact.localTemplateWindowSize = newValue
                                            onSettingsChange()
                                        }
                                    ),
                                    in: DefinedArtifact.minimumLocalTemplateWindowSize...DefinedArtifact.maximumLocalTemplateWindowSize,
                                    step: 2
                                )
                            }
                            Text(artifact.cleaningMethod == .waas || artifact.cleaningMethod == .waar
                                 ? "Number of neighboring events used when AMRI global weighting is off. MAS/MAR always use this centered local window."
                                 : "Number of neighboring events (centered on the current one) used to build each local template.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if artifact.cleaningMethod == .waas || artifact.cleaningMethod == .waar {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(
                                    "AMRI global weighting",
                                    isOn: Binding(
                                        get: { artifact.waasUsesAMRIGlobalWeights },
                                        set: { newValue in
                                            artifact.waasUsesAMRIGlobalWeights = newValue
                                            onSettingsChange()
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                Text("Matches amri_eeg_cbc.m: every valid event contributes with weight decay^distance, including the current event. Turn off to use EVA's local moving window.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Decay factor")
                                        .font(.caption)
                                    Spacer()
                                    Text(String(format: "%.2f", artifact.waasDecayFactor))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { artifact.waasDecayFactor },
                                        set: { newValue in
                                            artifact.waasDecayFactor = newValue
                                            onSettingsChange()
                                        }
                                    ),
                                    in: 0.5...0.99
                                )
                                Text("Weight of an event at distance d is decay^d — lower values favor nearby events more strongly (Goldman 2000).")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(
                                "Preserve local baseline",
                                isOn: Binding(
                                    get: { artifact.localTemplatePreservesLocalBaseline },
                                    set: { newValue in
                                        artifact.localTemplatePreservesLocalBaseline = newValue
                                        onSettingsChange()
                                    }
                                )
                            )
                            .toggleStyle(.checkbox)
                            Text("De-trends the correction so it matches the local signal's baseline at both edges of the window, instead of risking a DC/linear-drift step relative to the surrounding signal. Same mechanism as OBS's.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Edge taper")
                                    .font(.caption)
                                Spacer()
                                Text("\(Int((artifact.localTemplateEdgeTaperSeconds * 1000).rounded())) ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            AlwaysVisibleSlider(
                                value: Binding(
                                    get: { artifact.localTemplateEdgeTaperSeconds },
                                    set: { newValue in
                                        artifact.localTemplateEdgeTaperSeconds = min(max(newValue, 0), DefinedArtifact.maximumLocalTemplateEdgeTaperSeconds)
                                        onSettingsChange()
                                    }
                                ),
                                range: 0...DefinedArtifact.maximumLocalTemplateEdgeTaperSeconds,
                                step: 0.01
                            )
                            Text("Fades the subtraction in/out smoothly over this many seconds at each edge of the window, instead of cutting off sharply at the boundary. Bounded to half the (possibly per-event) window length.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "Use each event's own duration",
                            isOn: Binding(
                                get: { artifact.usesVariableEventDuration },
                                set: { newValue in
                                    artifact.usesVariableEventDuration = newValue
                                    onSettingsChange()
                                }
                            )
                        )
                        .toggleStyle(.checkbox)
                        Text("Sizes each event's correction window from its own measured duration instead of one shared window — needed for artifacts whose events genuinely vary in length (e.g. Continuous topography scanning). Leave off when events cluster around one duration. Not available for OBS/SSP-PCA, which pool every event into one shared basis and require uniform-length epochs.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .frame(width: 400)
            .frame(maxHeight: 560)
        }
    }
}

private struct AlwaysVisibleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @State private var isHovered = false

    private var clampedValue: Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (clampedValue - range.lowerBound) / span
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let thumbDiameter: CGFloat = isHovered ? 24 : 22
            let thumbRadius = thumbDiameter / 2
            let trackStart = thumbRadius
            let trackWidth = max(width - thumbDiameter, 1)
            let thumbCenter = trackStart + CGFloat(fraction) * trackWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.20))
                    .frame(width: trackWidth, height: 8)
                    .offset(x: trackStart)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, thumbCenter - trackStart), height: 8)
                    .offset(x: trackStart)

                ForEach(0...10, id: \.self) { tick in
                    Circle()
                        .fill(Color.secondary.opacity(0.26))
                        .frame(width: 3, height: 3)
                        .offset(
                            x: trackStart + CGFloat(tick) / 10 * trackWidth - 1.5,
                            y: 11
                        )
                }

                Circle()
                    .fill(thumbFill)
                    .overlay(
                        Circle()
                            .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.24), radius: 3, x: 0, y: 1)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbCenter - thumbRadius)
                    .animation(.easeOut(duration: 0.10), value: isHovered)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        updateValue(from: gesture.location.x, trackStart: trackStart, trackWidth: trackWidth)
                    }
            )
            .onHover { isHovered = $0 }
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Edge taper")
        .accessibilityValue("\(Int((clampedValue * 1000).rounded())) ms")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = snapped(clampedValue + step)
            case .decrement:
                value = snapped(clampedValue - step)
            @unknown default:
                break
            }
        }
        .help("Drag to adjust edge taper")
    }

    private var thumbFill: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.white
        #endif
    }

    private func updateValue(from locationX: CGFloat, trackStart: CGFloat, trackWidth: CGFloat) {
        let rawFraction = min(max((locationX - trackStart) / trackWidth, 0), 1)
        let rawValue = range.lowerBound + Double(rawFraction) * (range.upperBound - range.lowerBound)
        value = snapped(rawValue)
    }

    private func snapped(_ rawValue: Double) -> Double {
        let clamped = min(max(rawValue, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let steps = ((clamped - range.lowerBound) / step).rounded()
        return min(max(range.lowerBound + steps * step, range.lowerBound), range.upperBound)
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

    private var showsOBSVarianceReport: Bool {
        guard showsOBSVarianceOptions else { return false }
        return artifact.obsStrategy != .virtualChannel && artifact.obsStrategy != .spatiotemporal
    }

    private var hasTopography: Bool {
        artifact.topography != nil
    }

    /// Menu items in a `Picker` can't reliably show a hover tooltip on macOS,
    /// so the reason a topography-requiring strategy is disabled has to be
    /// visible in the label itself, not just a `.help()` that won't appear.
    private func obsStrategyMenuLabel(for strategy: ArtifactOBSStrategy) -> String {
        guard strategy.requiresTopography, !hasTopography else { return strategy.rawValue }
        return "\(strategy.rawValue) (run topography scan first)"
    }

    private var obsStrategyBinding: Binding<ArtifactOBSStrategy> {
        Binding {
            artifact.obsStrategy
        } set: { newValue in
            let bounded = newValue.requiresTopography && !hasTopography ? ArtifactOBSStrategy.standard : newValue
            guard artifact.obsStrategy != bounded else { return }
            artifact.obsStrategy = bounded
            onSettingsChange()
        }
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

    private var alignmentSearchBinding: Binding<Double> {
        Binding {
            artifact.obsAlignmentSearchSeconds
        } set: { newValue in
            let bounded = min(max(newValue, 0), DefinedArtifact.maximumOBSAlignmentSearchSeconds)
            guard abs(artifact.obsAlignmentSearchSeconds - bounded) > 0.0001 else { return }
            artifact.obsAlignmentSearchSeconds = bounded
            onSettingsChange()
        }
    }

    private var topographyWeightBinding: Binding<Double> {
        Binding {
            artifact.obsTopographyWeightStrength
        } set: { newValue in
            let bounded = min(max(newValue, 0), 1)
            guard abs(artifact.obsTopographyWeightStrength - bounded) > 0.0001 else { return }
            artifact.obsTopographyWeightStrength = bounded
            onSettingsChange()
        }
    }

    private var clusterCountBinding: Binding<Int> {
        Binding {
            artifact.obsClusterCount
        } set: { newValue in
            let bounded = min(max(newValue, 1), DefinedArtifact.maximumOBSClusterCount)
            guard artifact.obsClusterCount != bounded else { return }
            artifact.obsClusterCount = bounded
            onSettingsChange()
        }
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

    private var perChannelAlignmentBinding: Binding<Bool> {
        Binding {
            artifact.obsPerChannelAlignment
        } set: { newValue in
            guard artifact.obsPerChannelAlignment != newValue else { return }
            artifact.obsPerChannelAlignment = newValue
            onSettingsChange()
        }
    }

    /// aOBS per-electrode alignment only applies to the channel-wise OBS
    /// strategies; the virtual-channel / clustered / spatiotemporal strategies
    /// don't route through the per-channel fit, so the toggle is hidden there.
    private var supportsPerChannelAlignment: Bool {
        switch artifact.obsStrategy {
        case .standard, .topographyGated, .topographyAligned, .topographyWeighted:
            return true
        case .virtualChannel, .clustered, .spatiotemporal:
            return false
        }
    }

    private var reportCacheKey: String {
        [
            artifact.id.uuidString,
            artifact.cleaningMethod.rawValue,
            artifact.obsStrategy.rawValue,
            "\(artifact.eventCount)",
            "\(artifact.events.first?.beginTimeSeconds ?? -1)",
            "\(artifact.events.last?.beginTimeSeconds ?? -1)",
            "\(artifact.windowSizeSeconds)",
            "\(artifact.obsEdgeTaperSeconds)",
            "\(artifact.obsAlignmentSearchSeconds)",
            "\(artifact.obsTopographyWeightStrength)",
            "\(artifact.obsClusterCount)",
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

                obsStrategyControls
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

                if supportsPerChannelAlignment {
                    Toggle("Per-electrode alignment (aOBS, experimental)", isOn: perChannelAlignmentBinding)
                        .help("Shifts each event's OBS window independently per channel — within the ± lag below — to the lag that best matches that channel's own mean artifact, before fitting and subtracting. Compensates for artifacts that reach electrodes at different times (BCG pulse propagation, fronto→posterior ocular gradients). Channels where the artifact is too weak to align keep the shared window.")

                    if artifact.obsPerChannelAlignment {
                        HStack(spacing: 10) {
                            Text("Max lag")
                                .frame(width: 88, alignment: .leading)
                            Slider(
                                value: alignmentSearchBinding,
                                in: 0...DefinedArtifact.maximumOBSAlignmentSearchSeconds,
                                step: 0.01
                            )
                            Text("±\(Int((artifact.obsAlignmentSearchSeconds * 1000).rounded())) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .help("Largest per-channel time shift aOBS may apply when aligning each electrode to its own artifact peak. Shared with the topography-aligned strategy's search radius.")
                    }
                }

                Text("Windowed corrections are forced to zero at the padded boundaries before tapering, which helps avoid step-like edges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsOBSVarianceReport {
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
            } else if showsOBSVarianceOptions {
                Text("Residual PCA variance is shown for channel-wise OBS strategies. This strategy uses a different basis geometry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 620)
        .task(id: reportCacheKey) {
            await loadReport()
        }
    }

    @ViewBuilder
    private var obsStrategyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("OBS strategy")
                    .font(.callout.weight(.medium))
                OBSStrategyHelpButton()
            }

            Picker("OBS strategy", selection: obsStrategyBinding) {
                ForEach(ArtifactOBSStrategy.allCases) { strategy in
                    Text(obsStrategyMenuLabel(for: strategy))
                        .tag(strategy)
                        .disabled(strategy.requiresTopography && !hasTopography)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 260, alignment: .leading)
            .help("Chooses how OBS builds and applies its artifact basis.")

            if !hasTopography && ArtifactOBSStrategy.allCases.contains(where: \.requiresTopography) {
                Text("Strategies marked above need a saved topography reference — run a topography scan in Define Artifact first.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text(artifact.obsStrategy.helpText)
                if artifact.obsStrategy.isExperimental {
                    Text("Experimental")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.25), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if artifact.obsStrategy.requiresTopography && !hasTopography {
                Label("This strategy needs a saved topography reference.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            switch artifact.obsStrategy {
            case .standard, .topographyGated:
                EmptyView()
            case .topographyAligned:
                HStack(spacing: 10) {
                    Text("Search")
                        .frame(width: 88, alignment: .leading)
                    Slider(
                        value: alignmentSearchBinding,
                        in: 0...DefinedArtifact.maximumOBSAlignmentSearchSeconds,
                        step: 0.01
                    )
                    Text("±\(Int((artifact.obsAlignmentSearchSeconds * 1000).rounded())) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .help("Maximum event recentering distance when matching the saved topography near each event.")
            case .topographyWeighted:
                HStack(spacing: 10) {
                    Text("Weighting")
                        .frame(width: 88, alignment: .leading)
                    Slider(value: topographyWeightBinding, in: 0...1, step: 0.05)
                    Text(Self.percent(artifact.obsTopographyWeightStrength))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .help("How strongly the saved topography scales OBS correction strength by channel.")
            case .virtualChannel:
                Text("Uses the PCA component count above for the temporal basis fitted on the topography-projected virtual channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .clustered:
                Stepper(value: clusterCountBinding, in: 1...DefinedArtifact.maximumOBSClusterCount) {
                    Text("Clusters: \(artifact.obsClusterCount)")
                        .font(.caption.monospacedDigit())
                }
                .help("Number of amplitude groups used to fit separate OBS bases.")
            case .spatiotemporal:
                Text("Uses the PCA component count above for channel-by-time components fitted across event windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        guard showsOBSVarianceReport else {
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
    /// Precomputed at Apply time (see `applyArtifactCleaning(to:)` +
    /// `ArtifactTemplateViewModel.cleaningPreviewCache`). When present for
    /// `previewLoadID`, hovering skips `loadPreview()`'s live recompute
    /// entirely — this is the common case once the user has applied cleaning.
    var cachedPreviewData: ArtifactCleaningPreviewData?

    @State private var previewData: ArtifactCleaningPreviewData?
    @State private var isLoadingPreview = false
    @State private var magnifiesResidual = false

    /// Shared with the precompute step so cache keys always match.
    static func cacheKey(artifactID: DefinedArtifact.ID, method: String, afterSignal: MFFSignalData?) -> String {
        [
            artifactID.uuidString,
            method,
            afterSignal?.signalType ?? "no-after",
            String(afterSignal?.duration ?? 0)
        ].joined(separator: "-")
    }

    private var previewLoadID: String {
        Self.cacheKey(
            artifactID: artifact.id,
            method: artifact.appliedMethod?.rawValue ?? artifact.cleaningMethod.rawValue,
            afterSignal: afterSignal
        )
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
        if let cachedPreviewData {
            // Common case: Apply already precomputed this — instant, no spinner.
            previewData = cachedPreviewData
            isLoadingPreview = false
            return
        }
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

    /// Not `private` — called directly (off the main thread) to precompute and
    /// cache preview data right after Apply finishes, so hovering the preview
    /// button becomes a cache lookup instead of a live recompute. See
    /// `applyArtifactCleaning(to:)` in WaveletReductionSheetViews.swift and
    /// `ArtifactTemplateViewModel.cleaningPreviewCache`.
    nonisolated static func makePreviewData(
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
        // Event-level bounds filtering first (channel-independent), so the
        // per-channel work below — the expensive part — can run in parallel
        // over channels with a fixed, shared `accepted` divisor, matching the
        // original (serial, event-outer) accumulation semantics exactly.
        struct ValidWindow { let start: Int; let end: Int }
        var validWindows: [ValidWindow] = []
        validWindows.reserveCapacity(artifact.events.count)
        for event in artifact.events {
            let center = Int((event.centerTimeSeconds * signal.samplingRate).rounded())
            let start = center - windowSamples / 2
            let end = start + windowSamples
            guard start >= 0, end <= sampleCount else { continue }
            validWindows.append(ValidWindow(start: start, end: end))
        }
        let accepted = validWindows.count
        guard accepted > 0 else { return nil }

        var averages = Array(repeating: [Float](repeating: 0, count: windowSamples), count: signal.numberOfChannels)
        averages.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct channel row; bounded to
            // evaMaxWorkers so a large channel count can't oversubscribe.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: signal.data.count) { channelIndex in
                let channelData = signal.data[channelIndex]
                var accumulated = [Float](repeating: 0, count: windowSamples)
                for window in validWindows {
                    guard channelData.count >= window.end else { continue }
                    let firstMean = mean(channelData, start: window.start, count: edgeSamples)
                    let lastMean = mean(channelData, start: window.end - edgeSamples, count: edgeSamples)
                    let slope = (lastMean - firstMean) / baselineDenominator
                    for offset in 0..<windowSamples {
                        let baseline = firstMean + slope * (Double(offset) - firstCenter)
                        accumulated[offset] += Float(Double(channelData[window.start + offset]) - baseline)
                    }
                }
                out[channelIndex] = accumulated
            }
        }
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
