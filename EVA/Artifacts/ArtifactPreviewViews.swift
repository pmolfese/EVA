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

    /// Displays the label and a help button. @State owns the popover visibility;
    /// $showsHelp passes SwiftUI a two-way binding so dismissal updates that state.
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

    /// Builds a scrollable explanation of all OBS strategies and their shared reference.
    /// Opening this popover changes presentation state only, not the cleaning method.
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

    /// Connects popover presentation to local state and clears pin/hover state when
    /// the system dismisses it. A custom Binding runs this cleanup on writes.
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

    /// Combines a click-to-pin button with delayed hover presentation. The generic
    /// PreviewContent closure supplies the actual view; this wrapper owns visibility
    /// and cancels its pending hover task when the button disappears.
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

    /// Debounces hover transitions: wait 80 ms before opening and 220 ms before
    /// closing, allowing the pointer to cross into the popover. Cancels the previous
    /// delay and rechecks cancellation after suspension; pinned previews stay open.
    private func schedulePreviewVisibility() {
        hoverTask?.cancel()
        guard !isPreviewPinned else { return }
        let shouldShow = isButtonHovered || isPopoverHovered
        // Task.sleep uses nanoseconds. The longer close delay bridges the small
        // pointer gap between the button and its popover.
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

    /// Opens the before/after artifact preview, passing any cached result for this
    /// artifact, method and output signal. The parent owns the cache; this is a lookup.
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

    /// Wraps a wavelet cleaning preview in the shared hover/pin interaction and
    /// passes scan-time cached results through to avoid repeating the calculation.
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
    nonisolated static func cacheKey(
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

    /// Identifies this candidate/settings preview for SwiftUI’s task(id:). A changed
    /// ID cancels the old view task and launches a load for the new inputs.
    private var previewLoadID: String {
        Self.cacheKey(candidateID: candidate.id, configuration: configuration, signalDuration: signal.duration)
    }

    /// Shows before/removed/after waveforms, metrics and per-channel removed energy.
    /// Before and after share a scale; a much smaller removed trace may be magnified
    /// with a label. Loading is attached to view identity rather than run inside body.
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

    /// Loads a cached preview or computes one in a detached worker from value inputs.
    /// MainActor owns the view-state writes. Cancellation blocks publication after
    /// the await; it does not automatically stop the detached numerical calculation.
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

    /// Lays out four complementary change measurements; none alone establishes that
    /// cleaning removed only artifact or preserved all neural signal.
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

    /// Renders a compact title, formatted value and explanatory caption with equal width.
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

    /// Displays channel-index-ordered cells colored by normalized removed energy.
    /// The grid is a channel list, not a spatial scalp layout; labels add one for display.
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

    /// Clamps normalized intensity to 0...1 and maps it to the preview’s color/opacity ramp.
    private func removedEnergyColor(_ intensity: Double) -> Color {
        let value = min(max(intensity, 0), 1)
        return Color(
            red: 0.18 + 0.78 * value,
            green: 0.42 - 0.16 * value,
            blue: 0.72 - 0.58 * value,
            opacity: 0.22 + 0.76 * value
        )
    }

    /// Summarizes the three highest-energy channels, breaking ties by channel index.
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

    /// Formats a cell tooltip with removed RMS, peak and local energy fraction.
    /// The displayed fraction is capped; this formatter does not alter computed metrics.
    private func removedEnergyHelp(_ channel: WaveletCleaningChannelEnergy) -> String {
        [
            "Ch \(channel.channelIndex + 1)",
            "removed RMS \(Self.microvoltString(Float(channel.removedRMSMicrovolts)))",
            "peak \(Self.microvoltString(channel.peakRemovedMicrovolts))",
            String(format: "energy %.1f%% of local signal", min(max(channel.removedEnergyFraction, 0), 9.99) * 100)
        ].joined(separator: "\n")
    }

    /// Draws one averaged waveform panel, emphasizing the candidate’s source channel.
    /// An explicit amplitude scale makes comparisons meaningful across adjacent panels.
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

    /// Reserves a stable placeholder area with progress text while reconstruction runs.
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

    /// Finds one positive amplitude limit across all supplied traces. Returns nil
    /// for all-zero/empty data so the plot can use its own fallback scale.
    nonisolated private static func waveformScale(_ averages: [ArtifactTemplateAverage]) -> Float? {
        let maxAbs = averages
            .flatMap { $0.allChannelSamples }
            .flatMap { $0.map(abs) }
            .max() ?? 0
        return maxAbs > 0 ? maxAbs : nil
    }

    /// Labels magnification only when the shared scale exceeds the removed trace’s
    /// scale by more than 1.5×. nil tells the caller to keep the shared scale.
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

    /// Formats nonnegative amplitude summaries in microvolts, with more decimals at small values.
    nonisolated private static func microvoltString(_ value: Float) -> String {
        if value >= 100 {
            return String(format: "%.0f µV", value)
        }
        if value >= 10 {
            return String(format: "%.1f µV", value)
        }
        return String(format: "%.2f µV", value)
    }

    /// Formats seconds as seconds-with-milliseconds or minutes:seconds for longer times.
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

    /// Opens a candidate’s time-frequency view on click; the child computes its scalogram.
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

    /// Combines candidate identity, channel and signal duration for the current load task.
    /// This is a UI task key, not a hash of every recorded sample.
    private var loadID: String {
        "\(candidate.id)|\(candidate.channelIndex)|\(signal.duration)"
    }

    /// Presents the scalogram, legend and timing metadata, with loading/empty states.
    /// Its identity-scoped task snapshots inputs, computes off the UI actor and checks
    /// cancellation before publishing the result.
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

    /// Samples the same color function as the heatmap so the legend matches its ramp.
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

    /// Draws power[frequency][time] as colored rectangles using the available view size.
    /// Log compression shows weaker features; the highest power defines this plot’s scale.
    /// Rows are flipped vertically because screen y grows downward but frequency grows upward.
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
                        // Subtract the cell’s bottom edge from the height to put low frequencies
                        // at the bottom. The extra drawing pixel below prevents hairline gaps.
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

    /// Formats frequency-axis labels in Hz, retaining a decimal below 10 Hz.
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

    /// Presents OBS options with bindings to the parent’s artifact and report cache.
    /// The child edits shared settings directly; this button owns only sheet visibility.
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

struct ArtifactPCASOptionsButton: View {
    @Binding var artifact: DefinedArtifact
    let currentSignal: MFFSignalData
    let hasBroadbandInput: Bool
    let rWaveCount: Int
    let hasCompleteGeometry: Bool
    let onSettingsChange: () -> Void

    @State private var showsOptions = false

    /// Opens PCA-S settings, supplying available input/geometry/beat information
    /// so the sheet can explain whether the selected configuration is ready.
    var body: some View {
        Button("Options...") {
            showsOptions = true
        }
        .font(.caption)
        .sheet(isPresented: $showsOptions) {
            ArtifactPCASOptionsSheet(
                artifact: $artifact,
                currentSignal: currentSignal,
                hasBroadbandInput: hasBroadbandInput,
                rWaveCount: rWaveCount,
                hasCompleteGeometry: hasCompleteGeometry,
                onSettingsChange: onSettingsChange
            )
        }
    }
}

struct ArtifactPCASOptionsSheet: View {
    @Binding var artifact: DefinedArtifact
    let currentSignal: MFFSignalData
    let hasBroadbandInput: Bool
    let rWaveCount: Int
    let hasCompleteGeometry: Bool
    let onSettingsChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Reads resolved PCA-S settings, including the reviewed-event anchor policy.
    private var settings: BCGSurrogateSettings {
        artifact.effectivePCASSettings
    }

    /// Selects the count corresponding to the current anchor source: R-waves or artifact events.
    private var selectedBeatCount: Int {
        settings.beatSource == .rWaves ? rWaveCount : artifact.eventCount
    }

    /// Checks geometry, minimum anchor count and requested broadband availability.
    /// This is a UI readiness summary, not a replacement for numerical input validation.
    private var isReady: Bool {
        hasCompleteGeometry
            && selectedBeatCount >= settings.minimumAcceptedBeats
            && (settings.inputSource != .broadband || hasBroadbandInput)
    }

    /// Creates a two-way connection to any PCA-S setting selected by a writable key path.
    /// The generic Value keeps the field’s type. Writes copy/update the settings struct,
    /// clear the old fitted report and notify the owning workflow of the change.
    private func settingBinding<Value>(
        _ keyPath: WritableKeyPath<BCGSurrogateSettings, Value>
    ) -> Binding<Value> {
        Binding {
            settings[keyPath: keyPath]
        } set: { value in
            var updated = settings
            // A writable key path addresses a typed field without a switch for every
            // setting. Assign the updated value back because settings is a struct.
            updated[keyPath: keyPath] = value
            artifact.pcaSSettings = updated
            artifact.pcaSReport = nil
            onSettingsChange()
        }
    }

    /// Edits anchor source while protecting reviewed event selections. Switching to
    /// R-waves also replaces reviewed-exemplar search with iterative search when needed.
    private var beatSourceBinding: Binding<BCGSurrogateBeatSource> {
        Binding {
            settings.beatSource
        } set: { source in
            guard source != .rWaves || (rWaveCount > 0 && !artifact.hasReviewedEventSelection) else { return }
            var updated = settings
            updated.beatSource = source
            if source == .rWaves, updated.patternSearch == .reviewedExemplar {
                updated.patternSearch = .iterative
            }
            artifact.pcaSSettings = updated
            artifact.pcaSReport = nil
            onSettingsChange()
        }
    }

    /// Clamps the low cutoff above 0.1 Hz and below the high cutoff with a 0.5 Hz gap.
    /// Any accepted write invalidates the previous PCA-S report and notifies the parent.
    private var lowBandBinding: Binding<Double> {
        Binding {
            settings.bandLowHz
        } set: { value in
            var updated = settings
            updated.bandLowHz = min(max(value, 0.1), max(updated.bandHighHz - 0.5, 0.1))
            artifact.pcaSSettings = updated
            artifact.pcaSReport = nil
            onSettingsChange()
        }
    }

    /// Bounds the high cutoff by the low cutoff and the sampling-rate-derived Nyquist
    /// limit. Clears the fitted report because the artifact model’s input band changed.
    private var highBandBinding: Binding<Double> {
        Binding {
            settings.bandHighHz
        } set: { value in
            var updated = settings
            let nyquist = max(currentSignal.samplingRate / 2 - 0.1, 1)
            updated.bandHighHz = min(max(value, updated.bandLowHz + 0.5), nyquist)
            artifact.pcaSSettings = updated
            artifact.pcaSReport = nil
            onSettingsChange()
        }
    }

    /// Assembles input, artifact-model and source-separation controls plus the last-run
    /// report. Bindings save edits immediately; Done dismisses the sheet. onAppear
    /// initializes missing settings and repairs an unavailable R-wave selection.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PCA-S Options")
                    .font(.title3.weight(.semibold))
                Spacer()
                Label(
                    isReady ? "Ready" : "Needs input",
                    systemImage: isReady ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(isReady ? Color.secondary : Color.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Inputs") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Fit topographies from", selection: settingBinding(\.inputSource)) {
                                ForEach(BCGSurrogateInputSource.allCases) { source in
                                    Text(source.label).tag(source)
                                }
                            }
                            Text(settings.inputSource == .broadband
                                 ? "Fits the 1–20 Hz artifact evidence from the pre-filter signal, then applies the spatial operator to the current Clean Artifacts signal. The active temporal filter is preserved."
                                 : "Fits and applies PCA-S using the signal currently entering Clean Artifacts. Use this when the active filter already contains the BCG morphology you want to model.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if settings.inputSource == .broadband && !hasBroadbandInput {
                                Label("Broadband pre-filter data is not available in this workflow.", systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            Divider()

                            Picker("Beat anchors", selection: beatSourceBinding) {
                                Text("Defined BCG matches (\(artifact.eventCount))")
                                    .tag(BCGSurrogateBeatSource.artifactEvents)
                                Text(rWaveCount > 0
                                     ? "Detected R-waves (\(rWaveCount))"
                                     : "Detected R-waves (run ECG detection first)")
                                    .tag(BCGSurrogateBeatSource.rWaves)
                                    .disabled(rWaveCount == 0 || artifact.hasReviewedEventSelection)
                            }
                            if artifact.hasReviewedEventSelection {
                                Text("Reviewed classes use their included artifact events as beat anchors.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }

                            if settings.beatSource == .rWaves {
                                HStack {
                                    Text("R-wave → BCG lag")
                                    Spacer()
                                    TextField(
                                        "Seconds",
                                        value: settingBinding(\.rWaveLagSeconds),
                                        format: .number.precision(.fractionLength(3))
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    Text("s")
                                        .foregroundStyle(.secondary)
                                }
                                Text("The lag shifts electrical R-wave anchors to the expected mechanical BCG complex before epochs are cut.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Label(
                                "\(selectedBeatCount) anchors selected · \(settings.minimumAcceptedBeats) required",
                                systemImage: selectedBeatCount >= settings.minimumAcceptedBeats
                                    ? "checkmark.circle" : "exclamationmark.triangle"
                            )
                            .font(.caption2)
                            .foregroundStyle(selectedBeatCount >= settings.minimumAcceptedBeats ? Color.secondary : Color.orange)

                            Label(
                                hasCompleteGeometry ? "Complete 3D channel coordinates" : "Complete 3D coordinates required",
                                systemImage: hasCompleteGeometry ? "checkmark.circle" : "exclamationmark.triangle"
                            )
                            .font(.caption2)
                            .foregroundStyle(hasCompleteGeometry ? Color.secondary : Color.orange)
                        }
                        .padding(.top, 4)
                    }

                    GroupBox("Artifact model") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Template band")
                                Spacer()
                                TextField("Low", value: lowBandBinding, format: .number.precision(.fractionLength(1)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                Text("–")
                                TextField("High", value: highBandBinding, format: .number.precision(.fractionLength(1)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                Text("Hz")
                                    .foregroundStyle(.secondary)
                            }

                            Picker("Pattern search", selection: settingBinding(\.patternSearch)) {
                                ForEach(BCGArtifactPatternSearch.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }

                            HStack {
                                Text("Beat match")
                                Slider(value: settingBinding(\.correlationThreshold), in: 0.2...0.95)
                                Text(settings.correlationThreshold, format: .number.precision(.fractionLength(2)))
                                    .monospacedDigit()
                                    .frame(width: 38)
                            }
                            .disabled(settings.patternSearch == .reviewedExemplar)

                            HStack {
                                Text("Component reliability")
                                Slider(value: settingBinding(\.minimumComponentReliability), in: 0.3...0.99)
                                Text(settings.minimumComponentReliability, format: .number.precision(.fractionLength(2)))
                                    .monospacedDigit()
                                    .frame(width: 38)
                            }

                            Stepper(
                                "Minimum accepted beats: \(settings.minimumAcceptedBeats)",
                                value: settingBinding(\.minimumAcceptedBeats),
                                in: 4...100
                            )
                        }
                        .padding(.top, 4)
                    }

                    GroupBox("Source separation") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Head model", selection: settingBinding(\.headModel)) {
                                ForEach(BCGSurrogateHeadModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            Text(settings.headModel.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Stepper(
                                "Regional sources: \(settings.regionalSourceCount)",
                                value: settingBinding(\.regionalSourceCount),
                                in: 8...60
                            )

                            HStack {
                                Text("Brain regularization")
                                Slider(value: settingBinding(\.brainRegularization), in: 0.002...0.1)
                                Text(settings.brainRegularization, format: .number.precision(.fractionLength(3)))
                                    .monospacedDigit()
                                    .frame(width: 46)
                            }
                        }
                        .padding(.top, 4)
                    }

                    if let report = artifact.pcaSReport {
                        GroupBox("Last run") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.summary)
                                Text("Reliability: " + report.artifactComponentReliabilities
                                    .map { String(format: "%.2f", $0) }.joined(separator: ", "))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 720)
        .onAppear {
            if artifact.pcaSSettings == nil {
                artifact.pcaSSettings = .default
            }
            if settings.beatSource == .rWaves, rWaveCount == 0 {
                var updated = settings
                updated.beatSource = .artifactEvents
                artifact.pcaSSettings = updated
            }
        }
    }
}

struct ArtifactLocalTemplateOptionsButton: View {
    @Binding var artifact: DefinedArtifact
    let onSettingsChange: () -> Void

    @State private var showsOptions = false

    /// Shows local-template options in a popover, including BCG preprocessing, donor
    /// weighting, edge handling and variable duration. Each custom binding updates the
    /// parent-owned definition and calls onSettingsChange; no cleaning runs here.
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

    /// Bounds the current value for rendering without writing back to the binding.
    private var clampedValue: Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Maps the bounded value into 0...1 along the track; a zero-width range maps to zero.
    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (clampedValue - range.lowerBound) / span
    }

    /// Draws a persistent slider thumb and converts local drag coordinates into values.
    /// GeometryReader supplies actual width; accessibility adjustments use the same
    /// snapping rule as dragging, and hover changes appearance only.
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

    /// Uses the platform control background for the slider thumb, with a white fallback.
    private var thumbFill: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.white
        #endif
    }

    /// Converts a drag’s x coordinate into a clamped fraction of the track, then
    /// writes a snapped value through the parent-provided binding.
    private func updateValue(from locationX: CGFloat, trackStart: CGFloat, trackWidth: CGFloat) {
        let rawFraction = min(max((locationX - trackStart) / trackWidth, 0), 1)
        let rawValue = range.lowerBound + Double(rawFraction) * (range.upperBound - range.lowerBound)
        value = snapped(rawValue)
    }

    /// Rounds to steps measured from the range’s lower bound and clamps again.
    /// A nonpositive step disables quantization while retaining bounds.
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

    /// Distinguishes temporal OBS controls from the SSP/PCA controls sharing this sheet.
    private var showsOBSVarianceOptions: Bool {
        artifact.cleaningMethod == .obs
    }

    /// Shows the channel-wise variance estimate only for compatible OBS geometries.
    /// Virtual-channel and joint spatiotemporal bases need a different interpretation.
    private var showsOBSVarianceReport: Bool {
        guard showsOBSVarianceOptions else { return false }
        return artifact.obsStrategy != .virtualChannel && artifact.obsStrategy != .spatiotemporal
    }

    /// Whether the definition carries the scalp map required by some OBS strategies.
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

    /// Edits strategy, substituting standard OBS when the requested map is missing.
    /// Notifies the owner only when the effective selection actually changes.
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

    /// Clamps residual PCA component count to the supported range and notifies on change.
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

    /// Reads cumulative variance for the chosen count, or zero while no report is loaded.
    private var selectedCumulativeVariance: Double {
        report?.cumulativeVariance(for: artifact.obsPCAComponentCount) ?? 0
    }

    /// Edits the maximum alignment lag in seconds within supported bounds.
    /// A small change tolerance avoids redundant notifications from floating-point controls.
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

    /// Edits the 0...1 blend between uniform and scalp-map-weighted correction.
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

    /// Clamps amplitude-cluster count to the supported integer range before notifying.
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

    /// Edits taper duration in seconds with a supported maximum and change tolerance.
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

    /// Updates the baseline-preservation toggle and notifies only on a changed value.
    private var preservesLocalBaselineBinding: Binding<Bool> {
        Binding {
            artifact.obsPreservesLocalBaseline
        } set: { newValue in
            guard artifact.obsPreservesLocalBaseline != newValue else { return }
            artifact.obsPreservesLocalBaseline = newValue
            onSettingsChange()
        }
    }

    /// Updates whether overlapping corrections are combined before subtraction.
    private var usesOverlapAddBinding: Binding<Bool> {
        Binding {
            artifact.obsUsesOverlapAdd
        } set: { newValue in
            guard artifact.obsUsesOverlapAdd != newValue else { return }
            artifact.obsUsesOverlapAdd = newValue
            onSettingsChange()
        }
    }

    /// Updates experimental per-electrode alignment; its strategy eligibility is handled
    /// by supportsPerChannelAlignment and the visibility of the control.
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

    /// Combines the stored report inputs/settings used by this cache. Component count
    /// is not included: one report estimates up to the supported maximum and the UI
    /// selects a prefix. This key is not a content hash of the signal or event array.
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

    /// Composes OBS/SSP component controls, edge handling and optional variance report.
    /// Settings bindings update the parent immediately. A task keyed by report inputs
    /// loads the numerical estimate separately from constructing the view hierarchy.
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
                Stepper(value: Binding(
                    get: { artifact.sspPCAComponentCount ?? 2 },
                    set: { artifact.sspPCAComponentCount = $0; onSettingsChange() }
                ), in: 1...max(2, min(DefinedArtifact.maximumOBSComponentCount, signal.numberOfChannels - 1))) {
                    Text("Spatial components: \(artifact.sspPCAComponentCount ?? 2)")
                        .font(.callout.weight(.medium))
                }
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

    /// Builds the strategy picker and only the controls relevant to the selected case.
    /// ViewBuilder lets branches with different concrete view types form one result.
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

    /// Displays cumulative variance and per-component contributions from an existing
    /// report. Checkmarks reflect the selected component count; this view does not refit.
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

    /// Renders one short report count with a caption and monospaced value.
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

    /// Loads a cached variance report or fits one in a detached worker. Captures the
    /// cache key and input values before awaiting, then checks cancellation before
    /// writing UI state or cache. Unsupported strategies clear the visible report.
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

    /// Formats a fraction as a percentage with one decimal place.
    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

struct ArtifactCleaningPreviewData: Sendable {
    var beforeAverage: ArtifactTemplateAverage?
    var afterAverage: ArtifactTemplateAverage?
    var removedAverage: ArtifactTemplateAverage?
    var beforeTopographyValues: [Double]?
    var afterTopographyValues: [Double]?
    var topographyScale: Double?
    var waveformScaleMicrovolts: Float?
    var afterScaleMicrovolts: Float?
    var reductionMetrics: ArtifactCleaningReductionMetrics?
    var continuousRemovalMetrics: ArtifactCleaningContinuousRemovalMetrics?
}

struct ArtifactCleaningContinuousRemovalMetrics: Sendable {
    var removedPeakMicrovolts: Float
    var removedRMSMicrovolts: Float
}

struct ArtifactCleaningReductionMetrics: Sendable {
    var beforePeakMicrovolts: Float
    var afterPeakMicrovolts: Float
    var beforeRMSMicrovolts: Float
    var afterRMSMicrovolts: Float

    /// Fractional peak decrease, using the same bounded reduction rule as RMS.
    var peakReduction: Double? {
        reduction(before: beforePeakMicrovolts, after: afterPeakMicrovolts)
    }

    /// Fractional RMS decrease, or nil when the original RMS is too small for a ratio.
    var rmsReduction: Double? {
        reduction(before: beforeRMSMicrovolts, after: afterRMSMicrovolts)
    }

    /// Computes 1 − after/before and clamps to 0...1 for the reduction display.
    /// An increase displays as zero reduction; near-zero input returns nil.
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
    nonisolated static func cacheKey(artifactID: DefinedArtifact.ID, method: String, afterSignal: MFFSignalData?) -> String {
        [
            artifactID.uuidString,
            method,
            afterSignal?.signalType ?? "no-after",
            String(afterSignal?.duration ?? 0)
        ].joined(separator: "-")
    }

    /// Chooses applied method when available so the preview describes committed cleaning.
    private var previewLoadID: String {
        Self.cacheKey(
            artifactID: artifact.id,
            method: artifact.appliedMethod?.rawValue ?? artifact.cleaningMethod.rawValue,
            afterSignal: afterSignal
        )
    }

    /// Reserves panel height for the definition’s expected content: continuous metrics,
    /// CRD verification, or averaged waveforms with optional scalp maps.
    private var previewHeight: CGFloat {
        if artifact.isMovementPCADefinition || artifact.isMuscleBSSCCADefinition { return 190 }
        if artifact.isCorneoRetinalDefinition { return 390 }
        return artifact.topography != nil && layout != nil ? 540 : 285
    }

    /// Presents cached/computed before-and-after evidence without applying cleaning.
    /// Selects waveform versus whole-signal metrics by method; the residual magnification
    /// toggle changes only plot scaling. Its task loads data when preview identity changes.
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
                        Text(artifact.isCorneoRetinalDefinition ? "Blink-mask aligned waveform" : "Average Waveform")
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
                    if artifact.isCorneoRetinalDefinition,
                       let metrics = previewData?.continuousRemovalMetrics {
                        HStack(spacing: 8) {
                            metricChip(title: "Whole-recording removed peak", value: Self.microvoltString(metrics.removedPeakMicrovolts), reduction: nil)
                            metricChip(title: "Whole-recording removed RMS", value: Self.microvoltString(metrics.removedRMSMicrovolts), reduction: nil)
                        }
                    }
                    HStack(spacing: 10) {
                        waveformPreview(
                            title: artifact.type == .saccadicSpike ? "Subtracted SPs" : "Before",
                            subtitle: sharedScaleSubtitle,
                            average: artifact.type == .saccadicSpike
                                ? (previewData?.removedAverage ?? beforeAverage)
                                : beforeAverage,
                            scale: previewData?.waveformScaleMicrovolts
                        )
                        if let afterAverage = previewData?.afterAverage {
                            waveformPreview(
                                title: artifact.type == .saccadicSpike ? "With SPs removed" : "After",
                                subtitle: afterWaveformSubtitle,
                                average: afterAverage,
                                scale: afterWaveformScale
                            )
                        } else {
                            missingPreview(title: "After")
                        }
                    }
                    if artifact.isCorneoRetinalDefinition {
                        Text("These windows are centered on the preliminary blink masks for verification. MAAC-2 removes the continuous eye-position field; it does not remove the eyelid blink waveform itself.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if artifact.isMovementPCADefinition,
                      let metrics = previewData?.continuousRemovalMetrics {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Whole-signal removal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        metricChip(title: "Removed peak", value: Self.microvoltString(metrics.removedPeakMicrovolts), reduction: nil)
                        metricChip(title: "Removed RMS", value: Self.microvoltString(metrics.removedRMSMicrovolts), reduction: nil)
                    }
                    Text("MAAC-3 evaluates and removes factors within each epoch independently; an event-locked average would hide that epoch-specific behavior.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if artifact.isMuscleBSSCCADefinition,
                      let metrics = previewData?.continuousRemovalMetrics {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Whole-signal removal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        metricChip(title: "Removed peak", value: Self.microvoltString(metrics.removedPeakMicrovolts), reduction: nil)
                        metricChip(title: "Removed RMS", value: Self.microvoltString(metrics.removedRMSMicrovolts), reduction: nil)
                    }
                    Text("MAAC-4 estimates BSS-CCA sources per stored epoch or overlapped continuous window. Reviewable spectral suggestions determine which source back-projections are removed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// Uses apply-time cached data when supplied; otherwise snapshots inputs and
    /// computes preview summaries off the UI actor. A cancelled view task cannot publish
    /// the completed worker result, even if that detached worker continues running.
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

    /// Uses the shared scale normally, or the residual’s own scale when magnification is enabled.
    private var afterWaveformScale: Float? {
        guard magnifiesResidual else {
            return previewData?.waveformScaleMicrovolts
        }
        return previewData?.afterScaleMicrovolts ?? previewData?.waveformScaleMicrovolts
    }

    /// Labels a comparable before/after scale when both traces exist and magnification is off.
    private var sharedScaleSubtitle: String? {
        guard !magnifiesResidual, previewData?.afterAverage != nil else { return nil }
        return "Shared scale"
    }

    /// Labels a materially magnified residual (over 1.1×), falling back to the shared-scale label.
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

    /// Shows before/after peak and RMS together with their bounded reduction fractions.
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

    /// Renders one metric and an optional reduction badge; nil omits the percentage.
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

    /// Draws an averaged waveform panel highlighting the definition’s selected channels.
    /// The caller supplies a shared or explicitly magnified amplitude scale.
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

    /// Keeps the After panel’s layout visible while explaining that cleaning has not been applied.
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

    /// Draws a scalp map using the supplied channel values and shared color limit.
    /// The saved reference time is display metadata; values are prepared by the preview helpers.
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

    /// Creates a titled placeholder of fixed height while preview data is prepared.
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
    /// Assembles event averages, before-minus-after traces, scales and change summaries.
    /// Uses the saved average as a before fallback; missing after data leaves comparisons
    /// absent. Continuous-method summaries compare complete traces, not just event averages.
    nonisolated static func makePreviewData(
        artifact: DefinedArtifact,
        beforeSignal: MFFSignalData,
        afterSignal: MFFSignalData?
    ) -> ArtifactCleaningPreviewData {
        let beforeAverage = average(in: beforeSignal, artifact: artifact)
            ?? artifact.average.map(baselineAlignedAverage)
        // Optional.flatMap propagates nil from either missing afterSignal or a
        // failed average, instead of creating a nested Optional.
        let afterAverage = afterSignal.flatMap { average(in: $0, artifact: artifact) }
        let removedAverage = difference(beforeAverage, afterAverage)
        let beforeTopographyValues = beforeAverage.flatMap(centerValues(from:))
        let afterTopographyValues = afterAverage.flatMap(centerValues(from:))
        let previewTopographyScale = topographyScale(beforeTopographyValues, afterTopographyValues)
        let previewWaveformScale = waveformScale(beforeAverage, afterAverage)
        let previewAfterScale = waveformScale(afterAverage)
        let previewReductionMetrics = reductionMetrics(
            beforeAverage: beforeAverage,
            afterAverage: afterAverage,
            artifact: artifact
        )
        let continuousMetrics: ArtifactCleaningContinuousRemovalMetrics? = (artifact.isCorneoRetinalDefinition || artifact.isMovementPCADefinition || artifact.isMuscleBSSCCADefinition)
            ? afterSignal.flatMap {
                Self.continuousRemovalMetrics(
                    before: beforeSignal,
                    after: $0,
                    preferredChannels: artifact.selectedChannelIndices
                )
            }
            : nil

        return ArtifactCleaningPreviewData(
            beforeAverage: beforeAverage,
            afterAverage: afterAverage,
            removedAverage: removedAverage,
            beforeTopographyValues: beforeTopographyValues,
            afterTopographyValues: afterTopographyValues,
            topographyScale: previewTopographyScale,
            waveformScaleMicrovolts: previewWaveformScale,
            afterScaleMicrovolts: previewAfterScale,
            reductionMetrics: previewReductionMetrics,
            continuousRemovalMetrics: continuousMetrics
        )
    }

    /// Measures finite before-minus-after samples over matching channel lengths.
    /// Uses valid preferred channels, falling back to all compatible rows. Returns nil
    /// when dimensions or data cannot support a comparison; no samples are modified.
    nonisolated private static func continuousRemovalMetrics(
        before: MFFSignalData,
        after: MFFSignalData,
        preferredChannels: [Int]
    ) -> ArtifactCleaningContinuousRemovalMetrics? {
        guard before.data.count == after.data.count,
              let sampleCount = before.data.first?.count,
              sampleCount > 0 else { return nil }
        let preferred = preferredChannels.filter {
            before.data.indices.contains($0)
                && after.data.indices.contains($0)
                && before.data[$0].count == sampleCount
                && after.data[$0].count == sampleCount
        }
        let channels = preferred.isEmpty
            ? before.data.indices.filter {
                after.data.indices.contains($0)
                    && before.data[$0].count == sampleCount
                    && after.data[$0].count == sampleCount
            }
            : preferred
        guard !channels.isEmpty else { return nil }
        var peak: Float = 0
        var squareSum = 0.0
        var count = 0
        for channel in channels {
            for sample in 0..<sampleCount {
                let removed = before.data[channel][sample] - after.data[channel][sample]
                guard removed.isFinite else { continue }
                peak = max(peak, abs(removed))
                squareSum += Double(removed) * Double(removed)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return ArtifactCleaningContinuousRemovalMetrics(
            removedPeakMicrovolts: peak,
            removedRMSMicrovolts: Float(sqrt(squareSum / Double(count)))
        )
    }

    /// Subtracts compatible averages sample-by-sample and rebuilds peak/RMS summaries.
    /// Returns nil for missing inputs or differing shapes. Timing/channel correspondence
    /// is assumed from the paired preview inputs, not independently aligned here.
    nonisolated private static func difference(
        _ before: ArtifactTemplateAverage?,
        _ after: ArtifactTemplateAverage?
    ) -> ArtifactTemplateAverage? {
        guard let before, let after,
              before.allChannelSamples.count == after.allChannelSamples.count else { return nil }
        var samples = before.allChannelSamples
        for channel in samples.indices {
            guard samples[channel].count == after.allChannelSamples[channel].count else { return nil }
            for index in samples[channel].indices {
                let beforeValue: Float = samples[channel][index]
                let afterValue: Float = after.allChannelSamples[channel][index]
                samples[channel][index] = beforeValue - afterValue
            }
        }
        var summaries: [ArtifactTemplateChannelSummary] = []
        summaries.reserveCapacity(samples.count)
        for channel in samples.indices {
            let values = samples[channel]
            var peak: Float = 0
            var squareSum: Double = 0
            for value in values {
                peak = max(peak, abs(value))
                squareSum += Double(value) * Double(value)
            }
            let squareMean = values.isEmpty ? 0 : squareSum / Double(values.count)
            summaries.append(ArtifactTemplateChannelSummary(
                channelIndex: channel,
                peakAbsoluteMicrovolts: peak,
                rmsMicrovolts: Float(sqrt(squareMean))
            ))
        }
        summaries.sort {
            $0.peakAbsoluteMicrovolts == $1.peakAbsoluteMicrovolts
                ? $0.channelIndex < $1.channelIndex
                : $0.peakAbsoluteMicrovolts > $1.peakAbsoluteMicrovolts
        }
        return ArtifactTemplateAverage(
            samplingRate: before.samplingRate,
            windowSizeSeconds: before.windowSizeSeconds,
            eventCount: min(before.eventCount, after.eventCount),
            selectedChannelIndices: before.selectedChannelIndices,
            allChannelSamples: samples,
            channelSummaries: summaries
        )
    }

    /// Finds a shared absolute peak across any number of optional averages.
    /// The variadic parameter accepts before/after directly; nil inputs are ignored.
    nonisolated private static func waveformScale(_ averages: ArtifactTemplateAverage?...) -> Float? {
        let maxAbs = averages.compactMap { $0 }.flatMap { average in
            average.allChannelSamples.flatMap { $0.map(abs) }
        }.max() ?? 0
        return maxAbs > 0 ? maxAbs : nil
    }

    /// Computes paired peak/RMS summaries on preferred channels when both averages exist.
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

    /// Aggregates peak and RMS across valid preferred channels, falling back to all
    /// channels. RMS pools samples rather than averaging channel RMS values. Empty
    /// data yields zeros; this helper does not discard nonfinite values.
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

    /// Formats amplitude summaries with precision adapted to their size, in microvolts.
    nonisolated private static func microvoltString(_ value: Float) -> String {
        if value >= 100 {
            return String(format: "%.0f µV", value)
        }
        if value >= 10 {
            return String(format: "%.1f µV", value)
        }
        return String(format: "%.2f µV", value)
    }

    /// Formats a reduction fraction as a whole-number percentage label.
    nonisolated private static func percentString(_ value: Double) -> String {
        String(format: "%.0f%% reduction", value * 100)
    }

    /// Chooses one absolute color limit for two scalp maps; returns nil unless both exist
    /// and their combined peak is positive.
    nonisolated private static func topographyScale(_ before: [Double]?, _ after: [Double]?) -> Double? {
        guard let before, let after else { return nil }
        let maxAbs = (before + after).map(abs).max() ?? 0
        return maxAbs > 0 ? maxAbs : nil
    }

    /// Takes the middle sample of each channel’s average for the scalp map.
    /// Uses the first row’s midpoint; a shorter row contributes zero.
    nonisolated private static func centerValues(from average: ArtifactTemplateAverage) -> [Double]? {
        guard let sampleCount = average.allChannelSamples.first?.count, sampleCount > 0 else { return nil }
        let center = sampleCount / 2
        return average.allChannelSamples.map { samples in
            center < samples.count ? Double(samples[center]) : 0
        }
    }

    /// Builds baseline-aligned, event-centered preview averages in parallel by channel.
    /// CRD uses blink-mask events. Only complete windows count; the same accepted-event
    /// divisor is used for every channel. Returns nil when timing/data/events provide no
    /// complete window. This is display preparation, not a cleaning operation.
    nonisolated private static func average(in signal: MFFSignalData, artifact: DefinedArtifact) -> ArtifactTemplateAverage? {
        let events = artifact.isCorneoRetinalDefinition
            ? (artifact.corneoRetinalBlinkEvents ?? [])
            : artifact.events
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0,
              !events.isEmpty else {
            return nil
        }

        let crdWindowSeconds = min(
            max(0.6, (events.compactMap(\.durationSeconds).max() ?? 0) + 0.2),
            2.0
        )
        let requestedWindowSeconds = artifact.isCorneoRetinalDefinition
            ? crdWindowSeconds
            : artifact.windowSizeSeconds
        let windowSamples = artifact.average?.allChannelSamples.first?.count
            ?? max(Int((requestedWindowSeconds * signal.samplingRate).rounded()), 3)
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
        validWindows.reserveCapacity(events.count)
        for event in events {
            let center = Int((event.centerTimeSeconds * signal.samplingRate).rounded())
            let start = center - windowSamples / 2
            let end = start + windowSamples
            guard start >= 0, end <= sampleCount else { continue }
            validWindows.append(ValidWindow(start: start, end: end))
        }
        let windows = validWindows
        let accepted = windows.count
        guard accepted > 0 else { return nil }

        var averages = Array(repeating: [Float](repeating: 0, count: windowSamples), count: signal.numberOfChannels)
        averages.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct channel row; bounded to
            // evaMaxWorkers so a large channel count can't oversubscribe.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: signal.data.count) { channelIndex in
                let channelData = signal.data[channelIndex]
                var accumulated = [Float](repeating: 0, count: windowSamples)
                for window in windows {
                    guard channelData.count >= window.end else { continue }
                    let firstMean = mean(channelData, start: window.start, count: edgeSamples)
                    let lastMean = mean(channelData, start: window.end - edgeSamples, count: edgeSamples)
                    // Edge means are anchored at the centers of their sample groups. Interpolate
                    // a line between those centers, then subtract it before averaging events.
                    let slope = (lastMean - firstMean) / baselineDenominator
                    for offset in 0..<windowSamples {
                        let baseline = firstMean + slope * (Double(offset) - firstCenter)
                        accumulated[offset] += Float(Double(channelData[window.start + offset]) - baseline)
                    }
                }
                out[channelIndex] = accumulated
            }
        }
        // The event-level divisor is deliberately shared across channels. A short
        // channel row skips a window’s contribution but does not change this count.
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

    /// Detrends a saved average using short means at both edges, then rebuilds its
    /// channel summaries. Used when current-signal event averaging is unavailable.
    /// The saved input value is preserved; the returned copy contains aligned samples.
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

    /// Chooses a short averaging region near each edge: about 10% of the window,
    /// limited by one quarter of its length and 100 ms, with a small usable minimum.
    nonisolated private static func previewBaselineEdgeSamples(windowSamples: Int, samplingRate: Double) -> Int {
        let maximumByWindow = max(1, windowSamples / 4)
        let fractionCount = max(1, Int((Double(windowSamples) * 0.10).rounded()))
        let maximumByTime = samplingRate > 0
            ? max(1, Int((samplingRate * 0.10).rounded()))
            : fractionCount
        let minimumUsefulCount = min(3, maximumByWindow, maximumByTime)
        return min(max(fractionCount, minimumUsefulCount), maximumByWindow, maximumByTime)
    }

    /// Averages a bounded slice without allocating a subarray; invalid bounds/count return zero.
    nonisolated private static func mean(_ samples: [Float], start: Int, count: Int) -> Double {
        guard count > 0, start >= 0, start + count <= samples.count else { return 0 }
        var sum = 0.0
        for index in start..<(start + count) {
            sum += Double(samples[index])
        }
        return sum / Double(count)
    }
}
