//
//  RhythmicityExplorerView.swift
//  EVA
//

import AppKit
import SwiftUI

private enum RhythmicityBandsPresentation: String, CaseIterable, Identifiable {
    case spectrum = "Spectrum"
    case matrix = "Matrix"
    case gallery = "Gallery"
    case topography = "Topography"
    var id: String { rawValue }
}

struct RhythmicityExplorerView: View {
    @Bindable var viewModel: RhythmicityExplorerViewModel

    let packageName: String
    let signal: MFFSignalData
    let visibleSampleRange: ClosedRange<Int>?
    let channelSets: [ChannelSet]
    let artifactSources: [EEGArtifactRejectionSource]
    let sensorLayout: SensorLayout?
    let onUseInTimeFrequency: () -> Void
    let onClose: () -> Void

    @State private var bandsPresentation = RhythmicityBandsPresentation.spectrum
    @State private var showsHelp = false
    @State private var showsRunLog = false

    private var selectedRange: ClosedRange<Int>? { viewModel.store.selection.selectedSampleRange }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if viewModel.mode == .bands {
                bandsWorkspace
            } else {
                unavailableWorkspace
            }
            Divider()
            footer
        }
        .frame(minWidth: 1_050, idealWidth: 1_260, minHeight: 720, idealHeight: 850)
        .onAppear { synchronizeContext() }
        .sheet(isPresented: $showsHelp) {
            RhythmicityHelpView { showsHelp = false }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rhythmicity Explorer")
                    .font(.title3.weight(.semibold))
                Text(packageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(RhythmicityExplorerMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)

            Divider().frame(height: 28)

            Menu {
                Button {
                    viewModel.setSignificanceEnabled(true)
                } label: {
                    Label("Paper 2026", systemImage: viewModel.includesSignificance ? "checkmark" : "doc.text")
                }
                Button {
                    viewModel.setSignificanceEnabled(false)
                } label: {
                    Label("Exploratory — no significance", systemImage: viewModel.includesSignificance ? "doc.text" : "checkmark")
                }
            } label: {
                Label(viewModel.includesSignificance ? "Paper 2026" : "Exploratory", systemImage: "slider.horizontal.3")
            }
            .help("Paper 2026 runs 200 matched surrogates per channel. Exploratory mode computes median-defined regions without inferential labels.")

            Spacer()

            Button { showsHelp = true } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            Button {
                if viewModel.publishSelectedChannelBandsToTimeFrequency() {
                    onUseInTimeFrequency()
                }
            } label: {
                Label("Use in Time-Frequency", systemImage: "square.grid.3x3.fill.square")
            }
            .disabled(
                viewModel.laviResult == nil || viewModel.isRunning ||
                viewModel.resultIsStale || viewModel.selectedChannelResult?.bands.isEmpty != false
            )
            .help("Publish the displayed channel's ABBA boundaries for this recording session. Saved band preferences are not changed.")
            Button(action: exportPackage) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.laviResult == nil || viewModel.isRunning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var bandsWorkspace: some View {
        HSplitView {
            inspector
                .frame(minWidth: 280, idealWidth: 310, maxWidth: 360)
            resultCanvas
                .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 11) {
                        labeledPicker("Source", selection: $viewModel.source, values: RhythmicitySignalSource.allCases)
                            .disabled(true)
                        labeledPicker("Data", selection: $viewModel.dataSelection, values: RhythmicityDataSelection.allCases)
                        labeledPicker("Channels", selection: $viewModel.channelScope, values: RhythmicityChannelScope.allCases)

                        if viewModel.channelScope == .current {
                            Picker("Channel", selection: $viewModel.selectedChannelIndex) {
                                ForEach(signal.data.indices, id: \.self) { index in
                                    Text(channelName(index)).tag(index)
                                }
                            }
                        }
                        if viewModel.channelScope == .namedSet {
                            Picker("Set", selection: $viewModel.selectedChannelSetID) {
                                ForEach(channelSets) { set in Text(set.name).tag(Optional(set.id)) }
                            }
                        }

                        Toggle("Include marked artifacts", isOn: $viewModel.includesMarkedArtifacts)
                            .help("Expert override. Off by default: selected artifact windows split the valid LAVI segments so lag pairs cannot cross them.")

                        Divider()
                        keyValue("Frequencies", "47 · 3.16–44.67 Hz")
                        keyValue("Morlet / lag", "5 / 1.5 cycles")
                        keyValue("Backend", "Accelerate FFT · Float64")
                        Text(viewModel.runEstimate)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }

                GroupBox("Validity & provenance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(viewModel.validity.rawValue, systemImage: validityIcon)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(validityColor)
                        Text(validityExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(viewModel.validityWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        keyValue("Signal revision", String(signal.dataRevision.uuidString.prefix(8)))
                        keyValue("Sampling", "\(format(signal.samplingRate)) Hz")
                        keyValue("Reference", signal.referenceState.rawValue.capitalized)
                    }
                    .padding(.top, 4)
                }

                if let result = viewModel.laviResult {
                    GroupBox("Detection summary") {
                        VStack(alignment: .leading, spacing: 7) {
                            keyValue("Analyzed channels", "\(result.channels.count)")
                            keyValue("Sustained regions", "\(viewModel.detectedSustainedCount)")
                            keyValue("Transient regions", "\(viewModel.detectedTransientCount)")
                            keyValue("Alpha anchors", "\(viewModel.alphaAnchorCount)/\(result.channels.count)")
                            keyValue("Significance", significanceSource(result))
                            if let duration = viewModel.selectedChannelResult?.effectiveDurationsSeconds.filter(\.isFinite).min() {
                                keyValue("Minimum evidence", "\(format(duration)) s")
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var resultCanvas: some View {
        if let result = viewModel.laviResult, let channel = viewModel.selectedChannelResult {
            VStack(alignment: .leading, spacing: 12) {
                summaryChips(result)
                HStack {
                    Picker("Presentation", selection: $bandsPresentation) {
                        ForEach(RhythmicityBandsPresentation.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 500)
                    Spacer()
                    Picker("Displayed channel", selection: $viewModel.selectedChannelIndex) {
                        ForEach(result.channels, id: \.channelIndex) { item in
                            Text(item.channelName).tag(item.channelIndex)
                        }
                    }
                    .frame(maxWidth: 220)
                }

                switch bandsPresentation {
                case .spectrum:
                    LAVISpectrumView(result: channel, selectedBandID: $viewModel.selectedBandID)
                    ABBABandTableView(channel: channel, selection: $viewModel.selectedBandID)
                        .frame(minHeight: 210)
                case .matrix:
                    LAVIMultiChannelMatrix(
                        channels: result.channels,
                        selectedChannelIndex: viewModel.selectedChannelIndex,
                        onSelectChannel: { viewModel.selectedChannelIndex = $0 }
                    )
                    ABBABandTableView(channel: channel, selection: $viewModel.selectedBandID)
                        .frame(minHeight: 210)
                case .gallery:
                    LAVISpectrumGallery(
                        channels: result.channels,
                        selectedChannelIndex: $viewModel.selectedChannelIndex,
                        selectedBandID: $viewModel.selectedBandID
                    )
                case .topography:
                    topography(result: result, selectedChannel: channel)
                }
            }
            .padding(16)
            .overlay(alignment: .top) {
                if viewModel.resultIsStale {
                    Label("Displayed result is stale for the current signal or controls", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
        } else {
            ContentUnavailableView(
                "Ready for LAVI/ABBA",
                systemImage: "waveform.path",
                description: Text("Run a processed recording to inspect phase persistence, matched surrogate noise, and individualized sustained/transient bands.")
            )
        }
    }

    private var unavailableWorkspace: some View {
        ContentUnavailableView(
            viewModel.mode == .eventRelated ? "Event-related WTPL is a later milestone" : "Burst analysis is a later milestone",
            systemImage: viewModel.mode == .eventRelated ? "waveform.path.ecg.rectangle" : "bolt.horizontal.circle",
            description: Text("Bands mode is fully available. This mode remains disabled until its independently validated numerical engine lands.")
        )
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if showsRunLog {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(viewModel.log) { line in
                            Text("\(line.date.formatted(date: .omitted, time: .standard))  \(line.message)")
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
                .frame(height: 90)
                Divider()
            }
            HStack(spacing: 12) {
                Button { showsRunLog.toggle() } label: {
                    Label("Run Log", systemImage: showsRunLog ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)

                if viewModel.isRunning {
                    ProgressView(value: viewModel.progress).frame(width: 180)
                    Text("\(Int((viewModel.progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.statusTitle).font(.caption.weight(.semibold))
                    Text(viewModel.timeFrequencyPublishStatus ?? viewModel.exportStatus ?? viewModel.statusDetail)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if viewModel.isRunning {
                    Button("Cancel") { viewModel.cancel() }
                } else {
                    Button(viewModel.laviResult == nil ? "Run Analysis" : "Re-run Analysis") { runAnalysis() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(viewModel.mode != .bands)
                }
                Button("Close", action: onClose)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func summaryChips(_ result: LAVIAnalysisResult) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("Duration", viewModel.selectedChannelResult?.effectiveDurationsSeconds.filter(\.isFinite).min().map { "\(format($0)) s" } ?? "—")
                chip("Channels", "\(result.channels.count)")
                chip("Sustained", "\(viewModel.detectedSustainedCount)")
                chip("Transient", "\(viewModel.detectedTransientCount)")
                chip("Alpha anchored", "\(viewModel.alphaAnchorCount)/\(result.channels.count)")
                chip("Significance", significanceSource(result))
                chip("Backend", "Accelerate FFT")
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func topography(result: LAVIAnalysisResult, selectedChannel: LAVIChannelResult) -> some View {
        if let layout = sensorLayout {
            let selectedBand = selectedChannel.bands.first { $0.id == viewModel.selectedBandID }
                ?? selectedChannel.bands.first
            let values = topographyValues(result: result, selectedBand: selectedBand)
            VStack(alignment: .leading, spacing: 8) {
                Text("Per-band peak LAVI topography")
                    .font(.headline)
                Text(selectedBand.map { "Matching \($0.canonicalName ?? "unanchored") \($0.direction.rawValue) regions across channels." } ?? "Select a band in Spectrum view.")
                    .font(.caption).foregroundStyle(.secondary)
                TopomapView(
                    layout: layout.includingReference(forChannelCount: signal.numberOfChannels),
                    values: values,
                    timeSeconds: 0,
                    fixedScale: nil,
                    colorRange: 0...1,
                    unitLabel: "LAVI",
                    usesPositiveSequentialScale: true,
                    showsHeader: false,
                    colorBarPlacement: .trailing,
                    channelName: { channelName($0) },
                    onTapChannel: { index in
                        if result.channels.contains(where: { $0.channelIndex == index }) {
                            viewModel.selectedChannelIndex = index
                        }
                    },
                    highlightedChannels: [viewModel.selectedChannelIndex],
                    visibleChannels: Set(result.channels.map(\.channelIndex))
                )
                .frame(maxWidth: 620, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                "No sensor layout",
                systemImage: "brain.head.profile",
                description: Text("The spectrum, matrix, gallery, and exports remain available for recordings without electrode coordinates.")
            )
        }
    }

    private func topographyValues(result: LAVIAnalysisResult, selectedBand: ABBABand?) -> [Double] {
        var values = [Double](repeating: .nan, count: signal.numberOfChannels)
        guard let selectedBand else { return values }
        for channel in result.channels where values.indices.contains(channel.channelIndex) {
            let match: ABBABand?
            if let relative = selectedBand.relativeToAlpha {
                match = channel.bands.first { $0.relativeToAlpha == relative && $0.direction == selectedBand.direction }
            } else {
                match = channel.bands.min { abs($0.peakFrequencyHz - selectedBand.peakFrequencyHz) < abs($1.peakFrequencyHz - selectedBand.peakFrequencyHz) }
            }
            values[channel.channelIndex] = match?.peakLAVI ?? .nan
        }
        return values
    }

    private func runAnalysis() {
        viewModel.run(
            packageName: packageName,
            signal: signal,
            visibleRange: visibleSampleRange,
            selectedRange: selectedRange,
            channelSets: channelSets,
            artifactSources: artifactSources
        )
    }

    private func synchronizeContext() {
        viewModel.synchronizeContext(
            signal: signal,
            visibleRange: visibleSampleRange,
            selectedRange: selectedRange,
            channelSets: channelSets,
            artifactSources: artifactSources
        )
    }

    private func exportPackage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for the Rhythmicity Export"
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let base = (packageName as NSString).deletingPathExtension
        let destination = parent.appendingPathComponent("\(base)-rhythmicity", isDirectory: true)
        do {
            try viewModel.exportPackage(to: destination)
        } catch {
            viewModel.exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func channelName(_ index: Int) -> String {
        guard let names = signal.channelNames, names.indices.contains(index) else {
            return "E\(index + 1)"
        }
        return names[index]
    }

    private var validityIcon: String {
        switch viewModel.validity {
        case .ready: return "checkmark.circle"
        case .referenceValid: return "checkmark.seal.fill"
        case .customSignificance: return "checkmark.seal"
        case .exploratory: return "scope"
        case .invalid: return "exclamationmark.octagon"
        case .stale: return "clock.arrow.circlepath"
        }
    }

    private var validityColor: Color {
        switch viewModel.validity {
        case .referenceValid, .customSignificance: return .green
        case .exploratory, .stale: return .orange
        case .invalid: return .red
        case .ready: return .secondary
        }
    }

    private var validityExplanation: String {
        switch viewModel.validity {
        case .ready: return "No result has been computed for this selection."
        case .exploratory: return "LAVI and median-defined ABBA regions are available; significance was not computed."
        case .referenceValid: return "Paper 2026 settings with a complete, recording-matched 200-surrogate ribbon."
        case .customSignificance: return "A complete on-demand ribbon matches the custom analysis configuration."
        case .invalid: return viewModel.statusDetail
        case .stale: return "The displayed result does not match the current signal, range, channel scope, or settings. Export remains available and records the result's original provenance."
        }
    }

    private func significanceSource(_ result: LAVIAnalysisResult) -> String {
        guard let ribbon = result.channels.first?.significanceRibbon else { return "Not computed" }
        return ribbon.source == .onDemandSurrogates ? "200 on-demand" : ribbon.source.rawValue
    }

    private func chip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func labeledPicker<T: Hashable & Identifiable>(
        _ label: String,
        selection: Binding<T>,
        values: [T]
    ) -> some View where T.ID == String {
        Picker(label, selection: selection) {
            ForEach(values) { value in Text(value.id).tag(value) }
        }
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
