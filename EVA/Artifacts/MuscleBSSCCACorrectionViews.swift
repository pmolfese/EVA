//
//  MuscleBSSCCACorrectionViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import SwiftUI

struct MuscleBSSCCADetectionSheet: View {
    @Bindable var viewModel: MuscleBSSCCAViewModel
    let signal: MFFSignalData
    let activeLowPassHz: Double?
    let icaMuscleComponentCount: Int?
    let onRestoreDefaults: () -> Void
    let onAnalyze: () -> Void
    let onComponentChange: (MuscleBSSCCAWindowDiagnostic, MuscleBSSCCAComponentDiagnostic, Bool) -> Void
    let onNavigate: (MuscleBSSCCAWindowDiagnostic) -> Void
    let onAddMarkers: () -> Void
    let onClose: () -> Void

    private var configuration: MuscleBSSCCAConfiguration { viewModel.configuration }
    private var candidateWindows: [MuscleBSSCCAWindowDiagnostic] {
        viewModel.result?.windows.filter { window in
            window.skippedReason == nil
                && window.components.contains { $0.automaticallyRemoved || $0.wasOverridden }
        } ?? []
    }
    private var activeEventCount: Int { viewModel.detectedEvents.count }
    private var selectedWindow: MuscleBSSCCAWindowDiagnostic? {
        guard let selectedWindowID = viewModel.selectedWindowID else { return candidateWindows.first }
        return candidateWindows.first(where: { $0.id == selectedWindowID }) ?? candidateWindows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Muscle Artifact")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("MAAC-4")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Detect muscle-dominated BSS-CCA sources, inspect each affected interval on the waveform, and choose which components belong in the later Clean Artifacts correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settings
                    evidenceSummary
                    analysisProgress
                    reviewResults

                    if let status = viewModel.statusMessage {
                        Label(
                            status,
                            systemImage: viewModel.isAnalyzing
                                ? "gearshape.2"
                                : (viewModel.result == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        )
                        .font(.caption)
                        .foregroundStyle(viewModel.isAnalyzing || viewModel.result != nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Restore Defaults", action: onRestoreDefaults)
                    .disabled(viewModel.isAnalyzing)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                if viewModel.isAnalyzing {
                    ProgressView().controlSize(.small)
                }
                Button(viewModel.result == nil ? "Analyze Muscle" : "Analyze Again", action: onAnalyze)
                    .disabled(viewModel.isAnalyzing || hasKnownBandwidthConflict)
                Button("Add \(activeEventCount) Muscle Marker\(activeEventCount == 1 ? "" : "s")", action: onAddMarkers)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isAnalyzing || activeEventCount == 0)
            }
            .padding(20)
        }
        .frame(width: 720, height: 780)
        .onChange(of: viewModel.configuration) { oldValue, newValue in
            var oldDetectionSettings = oldValue
            var newDetectionSettings = newValue
            oldDetectionSettings.componentOverrides = []
            newDetectionSettings.componentOverrides = []
            guard oldDetectionSettings != newDetectionSettings,
                  viewModel.result != nil else { return }
            viewModel.result = nil
            viewModel.selectedWindowID = nil
            viewModel.analysisProgress = nil
            viewModel.analysisStartedAt = nil
            viewModel.statusMessage = "Settings changed. Analyze again before adding muscle markers."
        }
    }

    private var settings: some View {
        GroupBox("Detection settings") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Analysis ranges", selection: $viewModel.configuration.rangeMode) {
                    ForEach(MuscleBSSCCARangeMode.allCases) { mode in
                        Text(mode.rawValue)
                            .tag(mode)
                            .disabled(mode == .epochSegments && signal.epochSegments.isEmpty)
                    }
                }

                Text(rangeModeExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Continuous window").font(.caption).frame(width: 125, alignment: .leading)
                    Slider(value: $viewModel.configuration.continuousWindowSeconds, in: 2...30, step: 1)
                        .disabled(configuration.rangeMode == .epochSegments)
                    Text(String(format: "%.0f s", configuration.continuousWindowSeconds))
                        .font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Text("Overlap").font(.caption).frame(width: 125, alignment: .leading)
                    Slider(value: $viewModel.configuration.continuousOverlapFraction, in: 0...0.75, step: 0.05)
                        .disabled(configuration.rangeMode == .epochSegments)
                    Text(String(format: "%.0f%%", configuration.continuousOverlapFraction * 100))
                        .font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
                }

                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                    GridRow {
                        Text("EEG band")
                        numberField($viewModel.configuration.eegBandLowHz)
                        Text("to")
                        numberField($viewModel.configuration.eegBandHighHz)
                        Text("Hz")
                    }
                    GridRow {
                        Text("EMG band")
                        numberField($viewModel.configuration.emgBandLowHz)
                        Text("to")
                        numberField($viewModel.configuration.emgBandHighHz)
                        Text("Hz")
                    }
                    GridRow {
                        Text("EMG / EEG gate")
                        numberField($viewModel.configuration.minimumEMGToEEGPowerRatio)
                        Text("")
                        Text("Analysis rate")
                        numberField($viewModel.configuration.analysisSamplingRate)
                        Text("Hz")
                    }
                }
                .font(.caption)

                Text("A source is suggested when its mean EMG-band power divided by mean EEG-band power reaches the gate. Defaults reproduce the De Vos 1–15 / 15–30 Hz, 1/7 criterion. CCA is estimated near 250 Hz and its spatial operator is later applied to native-rate samples.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
        .disabled(viewModel.isAnalyzing)
    }

    @ViewBuilder
    private var evidenceSummary: some View {
        GroupBox("Input checks") {
            VStack(alignment: .leading, spacing: 5) {
                if signal.samplingRate / 2 < configuration.emgBandHighHz {
                    Label(
                        String(format: "The %.1f Hz Nyquist limit does not cover the %.1f Hz EMG-band ceiling; MAAC-4 cannot run.", signal.samplingRate / 2, configuration.emgBandHighHz),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                } else if let activeLowPassHz, activeLowPassHz < configuration.emgBandHighHz {
                    Label(
                        String(format: "The active %.1f Hz low-pass attenuates part of the configured EMG band. Raise the cutoff or lower the EMG-band ceiling.", activeLowPassHz),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Label("The signal bandwidth covers the configured EMG classifier band.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }

                if let icaMuscleComponentCount {
                    Text(icaMuscleComponentCount == 0
                         ? "Upstream ICA/ICLabel found no muscle-labeled components. This is context only and does not gate MAAC-4."
                         : "Upstream ICA/ICLabel labeled \(icaMuscleComponentCount) component(s) as Muscle. This is context only and does not gate MAAC-4.")
                } else {
                    Text("No upstream ICA/ICLabel result is available; MAAC-4 remains independently runnable.")
                }
            }
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var analysisProgress: some View {
        if viewModel.isAnalyzing, let progress = viewModel.analysisProgress {
            GroupBox("Analysis progress") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(progress.phase.rawValue).font(.callout.weight(.semibold))
                            Text(progressDetail(progress))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text("\(Int((progress.fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress.fraction, total: 1)
                        .progressViewStyle(.linear)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            progressMetric("Windows", "\(progress.completedWindowCount)/\(progress.totalWindowCount)")
                            progressMetric("Analyzed", "\(progress.analyzedWindowCount)")
                            progressMetric("Flagged", "\(progress.affectedWindowCount)")
                            progressMetric("Skipped", "\(progress.skippedWindowCount)")
                            progressMetric("Components", "\(progress.classifiedComponentCount)")
                            progressMetric("Selected", "\(progress.selectedComponentCount)")
                            progressMetric("Rate", rateText(progress.windowsPerSecond))
                            progressMetric("Remaining", remainingText(progress, now: context.date))
                        }
                    }

                    Text("For each interval EVA downsamples only the estimation copy, forms EEG(t) and EEG(t−1), solves the canonical correlations, measures every recovered source in the configured EEG and EMG bands, and records the sources that cross the spectral-ratio gate. No correction is applied during this scan.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var reviewResults: some View {
        if let result = viewModel.result {
            GroupBox("Detected muscle-artifact ranges") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        resultMetric("Analyzed", "\(result.analyzedWindowCount)")
                        resultMetric("Candidates", "\(candidateWindows.count)")
                        resultMetric("Included", "\(activeEventCount)")
                        resultMetric("Components", "\(result.removedComponentCount)")
                    }

                    if candidateWindows.isEmpty {
                        Text("No BSS-CCA source crossed the muscle spectral-ratio gate. Nothing will be added to Clean Artifacts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Text("#").frame(width: 24, alignment: .trailing)
                            Text("RANGE").frame(width: 155, alignment: .leading)
                            Text("REMOVE").frame(width: 60, alignment: .trailing)
                            Text("MAX RATIO").frame(width: 82, alignment: .trailing)
                            Spacer()
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ScrollView(.vertical) {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(candidateWindows.enumerated()), id: \.element.id) { offset, window in
                                    HStack(spacing: 8) {
                                        Button {
                                            viewModel.selectedWindowID = window.id
                                        } label: {
                                            HStack(spacing: 8) {
                                                Text("\(offset + 1)").frame(width: 24, alignment: .trailing)
                                                Text(rangeText(window.sampleRange)).frame(width: 155, alignment: .leading)
                                                Text("\(window.removedComponentCount)").frame(width: 60, alignment: .trailing)
                                                Text(ratioText(window)).frame(width: 82, alignment: .trailing)
                                            }
                                            .font(.caption.monospacedDigit())
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        Spacer()
                                        Button {
                                            viewModel.selectedWindowID = window.id
                                            onNavigate(window)
                                        } label: {
                                            Image(systemName: "scope")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Center and highlight this complete analysis interval on the waveform.")
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(
                                        window.id == selectedWindow?.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                                }
                            }
                        }
                        .frame(height: min(CGFloat(candidateWindows.count) * 34, 170))

                        if let selectedWindow,
                           let selectedIndex = candidateWindows.firstIndex(where: { $0.id == selectedWindow.id }) {
                            Divider()
                            HStack {
                                Text("Components in selected range")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("lag r = temporal autocorrelation · ratio = EMG/EEG power")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(selectedWindow.components) { component in
                                Toggle(isOn: componentRemovalBinding(window: selectedWindow, component: component)) {
                                    HStack {
                                        Text("C\(component.componentIndex)").frame(width: 32, alignment: .leading)
                                        Text(String(format: "lag r %.3f", component.lagOneAutocorrelation)).frame(width: 96, alignment: .leading)
                                        Text(String(format: "ratio %.3f", component.emgToEEGPowerRatio)).frame(width: 92, alignment: .leading)
                                        Text(component.wasOverridden ? "manual" : (component.automaticallyRemoved ? "suggested" : "retained"))
                                            .foregroundStyle(component.wasOverridden ? Color.blue : (component.automaticallyRemoved ? Color.orange : Color.secondary))
                                    }
                                    .font(.caption.monospacedDigit())
                                }
                                .toggleStyle(.checkbox)
                            }

                            HStack(spacing: 8) {
                                Button {
                                    selectAdjacentWindow(from: selectedIndex, offset: -1)
                                } label: {
                                    Label("Previous", systemImage: "chevron.left")
                                }
                                .disabled(selectedIndex == candidateWindows.startIndex)
                                Button {
                                    selectAdjacentWindow(from: selectedIndex, offset: 1)
                                } label: {
                                    Label("Next", systemImage: "chevron.right")
                                }
                                .disabled(selectedIndex == candidateWindows.index(before: candidateWindows.endIndex))
                                Button("Show in Waveform") { onNavigate(selectedWindow) }
                                Spacer()
                            }
                        }

                        Text("Checked components will be removed only after you add these markers and later choose Apply in Clean Artifacts. Unchecked automatic suggestions remain in this review list for comparison.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func componentRemovalBinding(
        window: MuscleBSSCCAWindowDiagnostic,
        component: MuscleBSSCCAComponentDiagnostic
    ) -> Binding<Bool> {
        Binding(
            get: {
                viewModel.result?.windows.first(where: { $0.id == window.id })?
                    .components.first(where: { $0.id == component.id })?.removed ?? component.removed
            },
            set: { onComponentChange(window, component, $0) }
        )
    }

    private func selectAdjacentWindow(from index: Int, offset: Int) {
        let target = index + offset
        guard candidateWindows.indices.contains(target) else { return }
        let window = candidateWindows[target]
        viewModel.selectedWindowID = window.id
        onNavigate(window)
    }

    private func numberField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 66)
    }

    private var hasKnownBandwidthConflict: Bool {
        signal.samplingRate / 2 < configuration.emgBandHighHz
            || (activeLowPassHz.map { $0 < configuration.emgBandHighHz } ?? false)
    }

    private var rangeModeExplanation: String {
        switch configuration.rangeMode {
        case .automatic:
            return signal.epochSegments.isEmpty
                ? "No stored epochs are present, so Automatic uses overlapping continuous windows."
                : "Automatic uses the signal's \(signal.epochSegments.count) stored epoch boundaries."
        case .continuousWindows:
            return "Scans overlapping windows across the recording; later correction crossfades their removed contributions."
        case .epochSegments:
            return signal.epochSegments.isEmpty
                ? "No recorded epoch boundaries are available for this signal."
                : "Scans each of the signal's \(signal.epochSegments.count) stored epochs independently."
        }
    }

    private func progressDetail(_ progress: MuscleBSSCCAProgress) -> String {
        switch progress.phase {
        case .preparing:
            return "Building \(progress.totalWindowCount) analysis interval(s) and validating the configured frequency bands."
        case .decomposing:
            return "Processed \(formattedSampleCount(progress.completedSampleCount)) of \(formattedSampleCount(progress.totalSampleCount)) window-samples and classified \(progress.classifiedComponentCount) recovered source(s)."
        case .assembling:
            return "All intervals are classified. Ordering diagnostics and building the review candidates."
        case .complete:
            return "The BSS-CCA component decisions are ready for waveform review."
        }
    }

    private func progressMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func resultMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func rangeText(_ range: Range<Int>) -> String {
        String(
            format: "%.3f–%.3f s",
            Double(range.lowerBound) / signal.samplingRate,
            Double(range.upperBound) / signal.samplingRate
        )
    }

    private func ratioText(_ window: MuscleBSSCCAWindowDiagnostic) -> String {
        let ratio = window.components.filter(\.removed).map(\.emgToEEGPowerRatio).max()
            ?? window.components.filter(\.automaticallyRemoved).map(\.emgToEEGPowerRatio).max()
            ?? 0
        return String(format: "%.3f", ratio)
    }

    private func rateText(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        return String(format: "%.1f/s", value)
    }

    private func remainingText(_ progress: MuscleBSSCCAProgress, now: Date) -> String {
        guard let seconds = progress.estimatedSecondsRemaining else { return "—" }
        let currentElapsed = viewModel.analysisStartedAt.map { now.timeIntervalSince($0) } ?? progress.elapsedSeconds
        let sinceUpdate = max(currentElapsed - progress.elapsedSeconds, 0)
        return durationText(max(seconds - sinceUpdate, 0))
    }

    private func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let rounded = Int(seconds.rounded())
        return rounded < 60 ? "\(rounded)s" : String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    private func formattedSampleCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }
}

struct MuscleBSSCCAOptionsButton: View {
    @Binding var artifact: DefinedArtifact
    let signal: MFFSignalData
    let excludedChannels: Set<Int>
    let activeLowPassHz: Double?
    let icaMuscleComponentCount: Int?
    let onSettingsChange: () -> Void

    @State private var showsOptions = false
    @State private var diagnostics: MuscleBSSCCADiagnostics?
    @State private var isAnalyzing = false
    @State private var analysisMessage: String?

    private var configuration: MuscleBSSCCAConfiguration {
        artifact.muscleBSSCCAConfiguration ?? .default
    }

    var body: some View {
        Button("Options...") { showsOptions = true }
            .font(.caption)
            .popover(isPresented: $showsOptions) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("MAAC-4 Muscle BSS-CCA")
                        .font(.headline)

                    rangeControls
                    Divider()
                    spectralControls
                    Divider()
                    evidenceSummary
                    analysisControls
                    componentReview
                }
                .padding(16)
                .frame(width: 570)
            }
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Processing ranges")
                .font(.caption.weight(.semibold))
            Picker("Processing ranges", selection: binding(\.rangeMode)) {
                ForEach(MuscleBSSCCARangeMode.allCases) { mode in
                    Text(mode.rawValue)
                        .tag(mode)
                        .disabled(mode == .epochSegments && signal.epochSegments.isEmpty)
                }
            }
            .labelsHidden()

            Text(rangeModeExplanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Continuous window")
                    .font(.caption.weight(.semibold))
                Slider(value: binding(\.continuousWindowSeconds), in: 2...30, step: 1)
                    .disabled(configuration.rangeMode == .epochSegments)
                Text(String(format: "%.0f s", configuration.continuousWindowSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            HStack {
                Text("Overlap")
                    .font(.caption.weight(.semibold))
                Slider(value: binding(\.continuousOverlapFraction), in: 0...0.75, step: 0.05)
                    .disabled(configuration.rangeMode == .epochSegments)
                Text(String(format: "%.0f%%", configuration.continuousOverlapFraction * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private var spectralControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Component classifier")
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("EEG band")
                    compactNumberField(binding(\.eegBandLowHz))
                    Text("to")
                    compactNumberField(binding(\.eegBandHighHz))
                    Text("Hz")
                }
                GridRow {
                    Text("EMG band")
                    compactNumberField(binding(\.emgBandLowHz))
                    Text("to")
                    compactNumberField(binding(\.emgBandHighHz))
                    Text("Hz")
                }
                GridRow {
                    Text("EMG / EEG gate")
                    compactNumberField(binding(\.minimumEMGToEEGPowerRatio))
                    Text("")
                    Text("Analysis rate")
                    compactNumberField(binding(\.analysisSamplingRate))
                    Text("Hz")
                }
            }
            .font(.caption)
            Text("A source is suggested for removal when its mean EMG-band power divided by its mean EEG-band power reaches the gate. Defaults reproduce the De Vos 1–15 / 15–30 Hz, 1/7 criterion. CCA is estimated near 250 Hz and its spatial operator is applied to the native-rate samples.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var evidenceSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if signal.samplingRate / 2 < configuration.emgBandHighHz {
                Label(
                    String(format: "The %.1f Hz Nyquist limit does not cover the %.1f Hz EMG-band ceiling; MAAC-4 will refuse to run.", signal.samplingRate / 2, configuration.emgBandHighHz),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else if let activeLowPassHz, activeLowPassHz < configuration.emgBandHighHz {
                Label(
                    String(format: "The active %.1f Hz low-pass attenuates part of the configured EMG band. Raise the cutoff or lower the EMG-band ceiling before analysis.", activeLowPassHz),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            if let icaMuscleComponentCount {
                Text(icaMuscleComponentCount == 0
                     ? "Upstream ICA/ICLabel has no muscle-labeled components. This is QC context only; it never gates BSS-CCA."
                     : "Upstream ICA/ICLabel labeled \(icaMuscleComponentCount) component(s) as Muscle. This is QC context only; it never gates BSS-CCA.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No upstream ICA/ICLabel result is available. BSS-CCA remains independently runnable.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var analysisControls: some View {
        HStack {
            Button(isAnalyzing ? "Analyzing..." : "Analyze Components") {
                Task { await analyzeComponents() }
            }
            .disabled(isAnalyzing || hasKnownBandwidthConflict)

            if isAnalyzing { ProgressView().controlSize(.small) }
            if let analysisMessage {
                Text(analysisMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var componentReview: some View {
        if let diagnostics {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(diagnostics.windows) { window in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(windowTitle(window))
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                if let skippedReason = window.skippedReason {
                                    Text("Skipped: \(skippedReason)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ForEach(window.components) { component in
                                Toggle(isOn: removalBinding(window: window, component: component)) {
                                    HStack {
                                        Text("C\(component.componentIndex)")
                                            .frame(width: 28, alignment: .leading)
                                        Text(String(format: "lag r %.3f", component.lagOneAutocorrelation))
                                        Text(String(format: "EMG/EEG %.3f", component.emgToEEGPowerRatio))
                                        if component.wasOverridden {
                                            Text("manual")
                                                .foregroundStyle(.blue)
                                        } else if component.automaticallyRemoved {
                                            Text("suggested")
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .font(.caption.monospacedDigit())
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            .frame(maxHeight: 270)
            Text("Checked components are removed when you Apply. Unchecking an automatic suggestion, or checking a retained component, is saved as a deterministic per-range override.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func compactNumberField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 62)
    }

    private var hasKnownBandwidthConflict: Bool {
        signal.samplingRate / 2 < configuration.emgBandHighHz
            || (activeLowPassHz.map { $0 < configuration.emgBandHighHz } ?? false)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MuscleBSSCCAConfiguration, Value>) -> Binding<Value> {
        Binding {
            configuration[keyPath: keyPath]
        } set: { newValue in
            var updated = configuration
            updated[keyPath: keyPath] = newValue
            updated.componentOverrides = []
            artifact.muscleBSSCCAConfiguration = updated
            diagnostics = nil
            analysisMessage = nil
            onSettingsChange()
        }
    }

    private var rangeModeExplanation: String {
        switch configuration.rangeMode {
        case .automatic:
            return signal.epochSegments.isEmpty
                ? "No stored epochs are present, so Automatic uses 10-second continuous windows with overlap/crossfade."
                : "Automatic uses the signal's \(signal.epochSegments.count) stored epoch boundaries."
        case .continuousWindows:
            return "Uses overlapping windows across the complete recording and crossfades their removed contributions."
        case .epochSegments:
            return signal.epochSegments.isEmpty
                ? "No recorded epoch boundaries are available for this signal."
                : "Uses each of the signal's \(signal.epochSegments.count) stored epochs independently."
        }
    }

    @MainActor
    private func analyzeComponents() async {
        isAnalyzing = true
        diagnostics = nil
        analysisMessage = nil
        let data = signal.data
        let samplingRate = signal.samplingRate
        let epochs = signal.epochSegments
        let configuration = configuration
        let selected = Set(artifact.selectedChannelIndices.filter(data.indices.contains))
        let excluded = selected.isEmpty
            ? excludedChannels
            : excludedChannels.union(data.indices.filter { !selected.contains($0) })
        let result = await Task.detached(priority: .userInitiated) {
            try? MuscleBSSCCACorrector.analyze(
                data: data,
                samplingRate: samplingRate,
                epochSegments: epochs,
                configuration: configuration,
                excluding: excluded
            )
        }.value
        guard !Task.isCancelled else {
            isAnalyzing = false
            return
        }
        guard configuration == self.configuration else {
            isAnalyzing = false
            return
        }
        diagnostics = result
        if let result {
            analysisMessage = "Suggested \(result.removedComponentCount) component(s) in \(result.affectedWindowCount) of \(result.analyzedWindowCount) window(s)."
        } else {
            analysisMessage = "Analysis could not form a stable CCA decomposition with these settings and channels."
        }
        isAnalyzing = false
    }

    private func removalBinding(
        window: MuscleBSSCCAWindowDiagnostic,
        component: MuscleBSSCCAComponentDiagnostic
    ) -> Binding<Bool> {
        Binding {
            diagnostics?.windows
                .first(where: { $0.sampleRange == window.sampleRange })?
                .components.first(where: { $0.componentIndex == component.componentIndex })?
                .removed ?? component.removed
        } set: { removes in
            var updated = configuration
            updated.componentOverrides.removeAll {
                $0.rangeStartSample == window.sampleRange.lowerBound
                    && $0.componentIndex == component.componentIndex
            }
            if removes != component.automaticallyRemoved {
                updated.componentOverrides.append(MuscleBSSCCAComponentOverride(
                    rangeStartSample: window.sampleRange.lowerBound,
                    componentIndex: component.componentIndex,
                    removes: removes
                ))
            }
            artifact.muscleBSSCCAConfiguration = updated
            if let windowIndex = diagnostics?.windows.firstIndex(where: { $0.sampleRange == window.sampleRange }),
               let componentIndex = diagnostics?.windows[windowIndex].components.firstIndex(where: { $0.componentIndex == component.componentIndex }) {
                diagnostics?.windows[windowIndex].components[componentIndex].removed = removes
                diagnostics?.windows[windowIndex].components[componentIndex].wasOverridden = removes != component.automaticallyRemoved
            }
            onSettingsChange()
        }
    }

    private func windowTitle(_ window: MuscleBSSCCAWindowDiagnostic) -> String {
        String(
            format: "%.2f–%.2f s · %d channels",
            Double(window.sampleRange.lowerBound) / signal.samplingRate,
            Double(window.sampleRange.upperBound) / signal.samplingRate,
            window.usableChannelCount
        )
    }
}

extension WaveformView {
    func openMuscleBSSCCASheet(for signal: MFFSignalData) {
        muscleBSSCCA.analysisTask?.cancel()
        muscleBSSCCA.analysisTask = nil
        muscleBSSCCA.isAnalyzing = false
        muscleBSSCCA.result = nil
        muscleBSSCCA.selectedWindowID = nil
        muscleBSSCCA.analysisProgress = nil
        muscleBSSCCA.analysisStartedAt = nil
        muscleBSSCCA.samplingRate = signal.samplingRate
        muscleBSSCCA.statusMessage = "Review the settings, then analyze the signal for muscle-dominated BSS-CCA sources."
        if let existing = template.definedArtifacts.first(where: \.isMuscleBSSCCADefinition) {
            muscleBSSCCA.definedArtifactID = existing.id
            muscleBSSCCA.configuration = existing.muscleBSSCCAConfiguration ?? .default
            muscleBSSCCA.selectedChannelIndices = existing.selectedChannelIndices.isEmpty
                ? Array(signal.data.indices)
                : existing.selectedChannelIndices
        } else {
            muscleBSSCCA.definedArtifactID = nil
            muscleBSSCCA.configuration = .default
            muscleBSSCCA.selectedChannelIndices = Array(signal.data.indices)
        }
        muscleBSSCCA.showsSheet = true
    }

    func muscleBSSCCASheet(for signal: MFFSignalData) -> some View {
        MuscleBSSCCADetectionSheet(
            viewModel: muscleBSSCCA,
            signal: signal,
            activeLowPassHz: filter.output == nil ? nil : filter.lowPassCutoff,
            icaMuscleComponentCount: upstreamICAMuscleComponentCount,
            onRestoreDefaults: {
                muscleBSSCCA.configuration = .default
                muscleBSSCCA.result = nil
                muscleBSSCCA.selectedWindowID = nil
                muscleBSSCCA.analysisProgress = nil
                muscleBSSCCA.analysisStartedAt = nil
                muscleBSSCCA.statusMessage = "Defaults restored. Analyze the signal to update muscle candidates."
                clearMuscleBSSCCADetectionOverlays()
            },
            onAnalyze: { analyzeMuscleBSSCCA(in: signal) },
            onComponentChange: { window, component, removes in
                updateMuscleBSSCCAComponent(window: window, component: component, removes: removes, signal: signal)
            },
            onNavigate: { window in navigateToMuscleBSSCCAWindow(window, in: signal) },
            onAddMarkers: { addMuscleBSSCCAResult(for: signal) },
            onClose: {
                muscleBSSCCA.analysisTask?.cancel()
                muscleBSSCCA.analysisTask = nil
                muscleBSSCCA.isAnalyzing = false
                muscleBSSCCA.analysisProgress = nil
                muscleBSSCCA.analysisStartedAt = nil
                muscleBSSCCA.showsSheet = false
            }
        )
    }

    private func analyzeMuscleBSSCCA(in signal: MFFSignalData) {
        let configuration = muscleBSSCCA.configuration
        let selected = Set(muscleBSSCCA.selectedChannelIndices.filter(signal.data.indices.contains))
        let excludedBase = channels.bad.union(channels.interpolated.keys)
        let excluded = selected.isEmpty
            ? excludedBase
            : excludedBase.union(signal.data.indices.filter { !selected.contains($0) })

        muscleBSSCCA.analysisTask?.cancel()
        muscleBSSCCA.isAnalyzing = true
        muscleBSSCCA.result = nil
        muscleBSSCCA.selectedWindowID = nil
        muscleBSSCCA.analysisStartedAt = Date()
        clearMuscleBSSCCADetectionOverlays()

        if let sampleCount = signal.data.first?.count,
           let plan = try? MuscleBSSCCACorrector.analysisRanges(
               sampleCount: sampleCount,
               samplingRate: signal.samplingRate,
               epochSegments: signal.epochSegments,
               configuration: configuration
           ) {
            muscleBSSCCA.analysisProgress = MuscleBSSCCAProgress(
                phase: .preparing,
                completedWindowCount: 0,
                totalWindowCount: plan.ranges.count,
                completedSampleCount: 0,
                totalSampleCount: plan.ranges.reduce(0) { $0 + $1.count },
                analyzedWindowCount: 0,
                affectedWindowCount: 0,
                skippedWindowCount: 0,
                classifiedComponentCount: 0,
                selectedComponentCount: 0,
                elapsedSeconds: 0
            )
        } else {
            muscleBSSCCA.analysisProgress = nil
        }
        muscleBSSCCA.statusMessage = "Estimating lagged CCA sources and classifying their EEG/EMG spectra…"

        let sessionID = recordingSessionID
        let (progressContinuation, progressTask) = ProgressBridge.make { (update: MuscleBSSCCAProgress) in
            muscleBSSCCA.analysisProgress = update
        }
        muscleBSSCCA.analysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                Result {
                    try MuscleBSSCCACorrector.analyze(
                        data: signal.data,
                        samplingRate: signal.samplingRate,
                        epochSegments: signal.epochSegments,
                        configuration: configuration,
                        excluding: excluded
                    ) { update in
                        progressContinuation.yield(update)
                    }
                }
            }
            let outcome = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )
            await ProgressBridge.finishAndWait(progressContinuation, task: progressTask)
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            guard configuration == muscleBSSCCA.configuration else {
                muscleBSSCCA.isAnalyzing = false
                muscleBSSCCA.analysisTask = nil
                muscleBSSCCA.analysisStartedAt = nil
                muscleBSSCCA.statusMessage = "Settings changed. Analyze again before adding muscle markers."
                return
            }
            switch outcome {
            case .success(let diagnostics):
                muscleBSSCCA.result = diagnostics
                muscleBSSCCA.selectedWindowID = diagnostics.windows.first(where: { window in
                    window.skippedReason == nil
                        && window.components.contains { $0.automaticallyRemoved || $0.wasOverridden }
                })?.id
                muscleBSSCCA.statusMessage = diagnostics.affectedWindowCount == 0
                    ? "Analyzed \(diagnostics.analyzedWindowCount) ranges; no source crossed the muscle spectral-ratio gate."
                    : "Found \(diagnostics.affectedWindowCount) muscle-artifact range(s) with \(diagnostics.removedComponentCount) selected component(s). Review them before adding markers."
                recordingStore.events.displayedEventsCache = .empty
                artifactVM.detectionRefreshToken += 1
            case .failure(let error):
                muscleBSSCCA.result = nil
                muscleBSSCCA.statusMessage = error.localizedDescription
            }
            muscleBSSCCA.isAnalyzing = false
            muscleBSSCCA.analysisTask = nil
            muscleBSSCCA.analysisStartedAt = nil
        }
    }

    private func updateMuscleBSSCCAComponent(
        window: MuscleBSSCCAWindowDiagnostic,
        component: MuscleBSSCCAComponentDiagnostic,
        removes: Bool,
        signal: MFFSignalData
    ) {
        var configuration = muscleBSSCCA.configuration
        configuration.componentOverrides.removeAll {
            $0.rangeStartSample == window.sampleRange.lowerBound
                && $0.componentIndex == component.componentIndex
        }
        if removes != component.automaticallyRemoved {
            configuration.componentOverrides.append(MuscleBSSCCAComponentOverride(
                rangeStartSample: window.sampleRange.lowerBound,
                componentIndex: component.componentIndex,
                removes: removes
            ))
        }
        muscleBSSCCA.configuration = configuration
        if let windowIndex = muscleBSSCCA.result?.windows.firstIndex(where: { $0.id == window.id }),
           let componentIndex = muscleBSSCCA.result?.windows[windowIndex].components.firstIndex(where: { $0.id == component.id }) {
            muscleBSSCCA.result?.windows[windowIndex].components[componentIndex].removed = removes
            muscleBSSCCA.result?.windows[windowIndex].components[componentIndex].wasOverridden = removes != component.automaticallyRemoved
        }
        muscleBSSCCA.statusMessage = "Component review updated. Add the current muscle markers when the selections look right."
        recordingStore.events.displayedEventsCache = .empty
        artifactVM.detectionRefreshToken += 1
        if let updated = muscleBSSCCA.result?.windows.first(where: { $0.id == window.id }) {
            navigateToMuscleBSSCCAWindow(updated, in: signal)
        }
    }

    private func navigateToMuscleBSSCCAWindow(_ window: MuscleBSSCCAWindowDiagnostic, in signal: MFFSignalData) {
        let onset = Double(window.sampleRange.lowerBound) / signal.samplingRate
        let event = MFFEvent(
            id: "maac-muscle-review-\(window.sampleRange.lowerBound)-\(window.sampleRange.upperBound)",
            code: MuscleBSSCCAArtifactMarkerBuilder.eventCode,
            label: "MAAC Muscle Candidate",
            eventDescription: "BSS-CCA muscle-component review interval",
            beginTimeSeconds: onset,
            rawBeginTime: String(format: "%.6f", onset),
            sourceFile: MuscleBSSCCAArtifactMarkerBuilder.sourceFile,
            durationSeconds: Double(window.sampleRange.count) / signal.samplingRate,
            timeAnchor: .onset
        )
        selectedEventCodes.insert(MuscleBSSCCAArtifactMarkerBuilder.eventCode)
        jumpToEvent(event, in: signal)
        highlightedArtifactEvent = event
        highlightedArtifactColor = .purple
    }

    private func clearMuscleBSSCCADetectionOverlays() {
        recordingStore.events.displayedEventsCache = .empty
        artifactVM.detectionRefreshToken += 1
    }

    private func addMuscleBSSCCAResult(for signal: MFFSignalData) {
        guard let diagnostics = muscleBSSCCA.result else { return }
        let events = MuscleBSSCCAArtifactMarkerBuilder.events(
            from: diagnostics,
            samplingRate: signal.samplingRate
        )
        guard !events.isEmpty else { return }
        let artifact = DefinedArtifact(
            id: muscleBSSCCA.definedArtifactID ?? UUID(),
            type: .muscle,
            name: "MAAC Muscle",
            eventCode: MuscleBSSCCAArtifactMarkerBuilder.eventCode,
            events: events,
            selectedChannelIndices: muscleBSSCCA.selectedChannelIndices,
            windowSizeSeconds: muscleBSSCCA.configuration.continuousWindowSeconds,
            average: nil,
            topography: nil,
            cleaningMethod: .bssCCA,
            usesVariableEventDuration: false,
            muscleBSSCCAConfiguration: muscleBSSCCA.configuration,
            appliedMethod: nil,
            cleanedAt: nil
        )

        if let index = template.definedArtifacts.firstIndex(where: \.isMuscleBSSCCADefinition) {
            template.definedArtifacts[index] = artifact
        } else {
            template.definedArtifacts.append(artifact)
        }
        registerPSADefinedArtifactForRejection(artifact.id)
        muscleBSSCCA.definedArtifactID = artifact.id
        artifactVM.events = definedArtifactEventList()
        selectedEventCodes = [artifact.eventCode]
        clearAppliedArtifactCleaning()
        artifactVM.cleaningStatusMessage = "Added \(artifact.eventCount) reviewed MAAC-4 muscle marker(s). Open Clean Artifacts when you are ready to apply BSS-CCA."
        muscleBSSCCA.showsSheet = false
    }

    func muscleBSSCCARangeSummary(_ artifact: DefinedArtifact, signal: MFFSignalData) -> String {
        let configuration = artifact.muscleBSSCCAConfiguration ?? .default
        let usesEpochs = configuration.rangeMode == .epochSegments
            || (configuration.rangeMode == .automatic && !signal.epochSegments.isEmpty)
        if usesEpochs { return "\(signal.epochSegments.count) recorded epochs · BSS-CCA" }
        return String(
            format: "%.0f s windows · %.0f%% overlap · BSS-CCA",
            configuration.continuousWindowSeconds,
            configuration.continuousOverlapFraction * 100
        )
    }

    var upstreamICAMuscleComponentCount: Int? {
        guard let decomposition = ica.decomposition else { return nil }
        return decomposition.labelSuggestions.values.count {
            $0.label.compare("Muscle", options: .caseInsensitive) == .orderedSame
        }
    }
}
