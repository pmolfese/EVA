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
    let eventSignal: MFFSignalData
    let epochSegments: [EpochSegment]
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
    private var eventConditions: [String] { Array(Set(epochSegments.map(\.category))).sorted() }
    private var wtplBandResolution: TimeFrequencyBandResolution {
        TimeFrequencyBandResolution.resolve(
            source: viewModel.wtplBandSource,
            userPreferences: ProcessingDefaults.shared.timeFrequencyBands,
            detectedBandSet: viewModel.detectedBandSetForTimeFrequency,
            detectedBandSetIsStale: viewModel.detectedBandSetForTimeFrequencyIsStale ||
                viewModel.detectedBandSetForTimeFrequency.map {
                    $0.sourceRevision != eventSignal.dataRevision.uuidString
                } == true
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if viewModel.mode == .bands {
                bandsWorkspace
            } else if viewModel.mode == .eventRelated {
                eventWorkspace
            } else {
                burstWorkspace
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

            if viewModel.mode == .bands {
                Menu {
                    Button { viewModel.setSignificanceEnabled(true) } label: {
                        Label("Paper 2026", systemImage: viewModel.includesSignificance ? "checkmark" : "doc.text")
                    }
                    Button { viewModel.setSignificanceEnabled(false) } label: {
                        Label("Exploratory — no significance", systemImage: viewModel.includesSignificance ? "doc.text" : "checkmark")
                    }
                } label: {
                    Label(viewModel.includesSignificance ? "Paper 2026" : "Exploratory", systemImage: "slider.horizontal.3")
                }
                .help("Paper 2026 runs 200 matched surrogates per channel. Exploratory mode computes median-defined regions without inferential labels.")
            } else if viewModel.mode == .eventRelated {
                Label("Paper WTPL · ±1 cycle", systemImage: "slider.horizontal.3")
                    .font(.callout)
            } else {
                Label("Paper burst · P90/P75", systemImage: "slider.horizontal.3")
                    .font(.callout)
            }

            Spacer()

            Button { showsHelp = true } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            if viewModel.mode == .bands {
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
            }
            Button(action: exportPackage) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!canExport || viewModel.isRunning)
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

    private var eventWorkspace: some View {
        HSplitView {
            eventInspector
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 390)
            eventCanvas
                .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var burstWorkspace: some View {
        HSplitView {
            burstInspector
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 390)
            burstCanvas
                .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var burstInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Data & channels") {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledPicker("Source", selection: $viewModel.source, values: RhythmicitySignalSource.allCases)
                            .disabled(true)
                        labeledPicker("Data", selection: $viewModel.dataSelection, values: RhythmicityDataSelection.allCases)
                        labeledPicker("Channels", selection: $viewModel.channelScope, values: RhythmicityChannelScope.allCases)
                        if viewModel.channelScope == .current {
                            Picker("Channel", selection: $viewModel.selectedChannelIndex) {
                                ForEach(signal.data.indices, id: \.self) { Text(channelName($0)).tag($0) }
                            }
                        }
                        if viewModel.channelScope == .namedSet {
                            Picker("Set", selection: $viewModel.selectedChannelSetID) {
                                ForEach(channelSets) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        Toggle("Include marked artifacts", isOn: $viewModel.includesMarkedArtifacts)
                    }.padding(.top, 4)
                }

                GroupBox("Detection") {
                    VStack(alignment: .leading, spacing: 10) {
                        keyValue("Morlet width", "5 cycles")
                        LabeledContent("Peak threshold") {
                            TextField("percentile", value: $viewModel.burstConfiguration.peakPercentile, format: .number)
                                .frame(width: 64)
                            Text("percentile")
                        }
                        LabeledContent("Power boundary") {
                            TextField("percentile", value: $viewModel.burstConfiguration.boundaryPercentile, format: .number)
                                .frame(width: 64)
                            Text("percentile")
                        }
                        Picker("Boundary", selection: $viewModel.burstConfiguration.boundarySource) {
                            ForEach(RhythmicBurstBoundarySource.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if viewModel.burstConfiguration.boundarySource == .wtplThreshold {
                            LabeledContent("WTPL threshold") {
                                TextField("WTPL", value: $viewModel.burstConfiguration.wtplThreshold, format: .number)
                                    .frame(width: 64)
                            }
                        }
                        LabeledContent("Minimum duration") {
                            TextField("cycles", value: $viewModel.burstConfiguration.minimumDurationCycles, format: .number)
                                .frame(width: 64)
                            Text("cycles")
                        }
                        keyValue("Merge gap", "max(4 Hz, ¼ lower peak)")
                    }.padding(.top, 4)
                }

                GroupBox("Band assignment") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Source", selection: $viewModel.burstBandSource) {
                            ForEach(TimeFrequencyBandSource.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Text("Current Rhythmicity bands preserve channel-specific sustained/transient ABBA identity when a fresh Bands result exists.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 4)
                }

                GroupBox("Safety boundary") {
                    Label("Bursts are neural-rhythm annotations—not artifact candidates.", systemImage: "checkmark.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }

                GroupBox("Run") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.runEstimate).font(.caption2).foregroundStyle(.secondary)
                        if let result = viewModel.burstResult {
                            keyValue("Bursts", "\(result.bursts.count)")
                            keyValue("Maps", "\(result.maps.count)")
                            ForEach(result.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }.padding(.top, 4)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var burstCanvas: some View {
        if let result = viewModel.burstResult {
            RhythmicBurstView(
                result: result,
                selectedChannelIndex: $viewModel.selectedChannelIndex,
                background: $viewModel.burstBackground,
                selectedBurstID: $viewModel.selectedBurstID
            )
            .padding(16)
            .overlay(alignment: .top) {
                if viewModel.burstResultIsStale {
                    Label("Displayed burst result is stale for the current selection or controls", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold)).padding(7)
                        .background(.regularMaterial, in: Capsule()).padding(8)
                }
            }
        } else {
            ContentUnavailableView(
                "Ready for rhythmic bursts",
                systemImage: "bolt.horizontal.circle",
                description: Text("Detect and measure neural-rhythmicity episodes using the pinned P90/P75 reference workflow.")
            )
        }
    }

    private var eventInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Conditions & measure") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Condition A", selection: $viewModel.wtplConditionA) {
                            ForEach(eventConditions, id: \.self) { Text($0).tag($0) }
                        }
                        Toggle("Difference (A − B)", isOn: $viewModel.wtplShowsDifference)
                            .disabled(eventConditions.count < 2)
                        if viewModel.wtplShowsDifference {
                            Picker("Condition B", selection: Binding(
                                get: { viewModel.wtplConditionB ?? "" },
                                set: { viewModel.wtplConditionB = $0.isEmpty ? nil : $0 }
                            )) {
                                ForEach(eventConditions.filter { $0 != viewModel.wtplConditionA }, id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                        }
                        Picker("Display", selection: $viewModel.wtplDisplayMeasure) {
                            ForEach(WTPLDisplayMeasure.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if viewModel.wtplDisplayMeasure == .delta, !viewModel.wtplBaselineIsAvailable {
                            Label("The complete baseline is outside these epochs. Adjust it or select Raw WTPL.", systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }.padding(.top, 4)
                }

                GroupBox("Channels") {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledPicker("Scope", selection: $viewModel.channelScope, values: RhythmicityChannelScope.allCases)
                        if viewModel.channelScope == .current {
                            Picker("Channel", selection: $viewModel.selectedChannelIndex) {
                                ForEach(eventSignal.data.indices, id: \.self) { Text(channelName($0)).tag($0) }
                            }
                        }
                        if viewModel.channelScope == .namedSet {
                            Picker("Set", selection: $viewModel.selectedChannelSetID) {
                                ForEach(channelSets) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }.padding(.top, 4)
                }

                GroupBox("WTPL configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        keyValue("Method", "Within-Trial Phase Locking")
                        keyValue("Lag family", "−1, +1 cycles")
                        keyValue("Morlet width", "5 cycles")
                        LabeledContent("Frequency minimum") {
                            TextField("Hz", value: $viewModel.wtplMinFrequencyHz, format: .number).frame(width: 75)
                        }
                        LabeledContent("Frequency maximum") {
                            TextField("Hz", value: $viewModel.wtplMaxFrequencyHz, format: .number).frame(width: 75)
                        }
                        LabeledContent("Frequency bins") {
                            Stepper(value: $viewModel.wtplFrequencyCount, in: 5...80) {
                                Text("\(viewModel.wtplFrequencyCount)").monospacedDigit()
                            }
                        }
                        Divider()
                        Text("Explicit ΔWTPL baseline").font(.caption.weight(.semibold))
                        LabeledContent("Start") {
                            TextField("ms", value: $viewModel.wtplBaselineStartMs, format: .number).frame(width: 75)
                        }
                        LabeledContent("End") {
                            TextField("ms", value: $viewModel.wtplBaselineEndMs, format: .number).frame(width: 75)
                        }
                        Text("The interval is never shortened automatically.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 4)
                }

                GroupBox("Band overlay & ROI") {
                    Picker("Source", selection: $viewModel.wtplBandSource) {
                        ForEach(TimeFrequencyBandSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .padding(.top, 4)
                    Text(wtplBandResolution.sourceDescription)
                        .font(.caption2).foregroundStyle(.secondary)
                }

                GroupBox("Run") {
                    VStack(alignment: .leading, spacing: 6) {
                        keyValue("Epochs", "\(epochSegments.count)")
                        keyValue("Conditions", "\(eventConditions.count)")
                        Text(viewModel.runEstimate).font(.caption2).foregroundStyle(.secondary)
                        if let result = viewModel.wtplResult {
                            ForEach(result.warnings.map(\.displayText), id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.top, 4)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var eventCanvas: some View {
        if let result = viewModel.wtplResult {
            WTPLView(
                result: result,
                conditionA: viewModel.wtplConditionA,
                conditionB: viewModel.wtplConditionB,
                showsDifference: viewModel.wtplShowsDifference,
                displayMeasure: viewModel.wtplDisplayMeasure,
                selectedChannelIndex: viewModel.selectedChannelIndex,
                bandResolution: wtplBandResolution
            )
            .padding(16)
            .overlay(alignment: .top) {
                if viewModel.wtplResultIsStale {
                    Label("Displayed WTPL is stale for the current epochs or controls", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold)).padding(7)
                        .background(.regularMaterial, in: Capsule()).padding(8)
                }
            }
        } else if epochSegments.isEmpty {
            ContentUnavailableView(
                "WTPL requires epochs",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Create or retain epochs, then return to Event-related mode.")
            )
        } else {
            ContentUnavailableView(
                "Ready for WTPL",
                systemImage: "waveform.path.ecg.rectangle",
                description: Text("Analyze within-trial phase persistence with explicit conditions and baseline semantics.")
            )
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
                        keyValue("Backend", viewModel.backendDescription)
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
                        if let persisted = viewModel.persistedResultStatus {
                            Text(persisted)
                                .font(.caption2)
                                .foregroundStyle(viewModel.resultIsStale ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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

    private var footer: some View {
        VStack(spacing: 0) {
            if showsRunLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(viewModel.log) { line in
                                Text("\(line.date.formatted(date: .omitted, time: .standard))  \(line.message)")
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    .onChange(of: viewModel.log.last?.id) { _, latestID in
                        guard let latestID else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(latestID, anchor: .bottom)
                        }
                    }
                }
                .frame(height: 120)
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
                    Button(runButtonTitle) { runAnalysis() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(viewModel.mode == .eventRelated && epochSegments.isEmpty)
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
                chip("Backend", viewModel.backendDescription)
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
        if viewModel.mode == .eventRelated {
            viewModel.runEventRelated(
                packageName: packageName,
                signal: eventSignal,
                segments: epochSegments,
                channelSets: channelSets
            )
        } else if viewModel.mode == .bursts {
            viewModel.runBursts(
                packageName: packageName,
                signal: signal,
                visibleRange: visibleSampleRange,
                selectedRange: selectedRange,
                channelSets: channelSets,
                artifactSources: artifactSources
            )
        } else {
            viewModel.run(
                packageName: packageName,
                signal: signal,
                visibleRange: visibleSampleRange,
                selectedRange: selectedRange,
                channelSets: channelSets,
                artifactSources: artifactSources
            )
        }
    }

    private func synchronizeContext() {
        viewModel.synchronizeContext(
            signal: signal,
            visibleRange: visibleSampleRange,
            selectedRange: selectedRange,
            channelSets: channelSets,
            artifactSources: artifactSources
        )
        viewModel.synchronizeEventContext(signal: eventSignal, segments: epochSegments)
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
        let suffix: String
        switch viewModel.mode {
        case .bands: suffix = "rhythmicity"
        case .eventRelated: suffix = "wtpl"
        case .bursts: suffix = "bursts"
        }
        let destination = parent.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
        do {
            if viewModel.mode == .eventRelated {
                let maxTime = viewModel.wtplResult?.timesMs.last ?? 0
                try viewModel.exportWTPLPackage(
                    to: destination,
                    bands: wtplBandResolution.bands,
                    windows: TimeFrequencyExport.defaultWindows(maxTimeMs: maxTime)
                )
            } else if viewModel.mode == .bursts {
                try viewModel.exportBurstPackage(to: destination)
            } else {
                try viewModel.exportPackage(to: destination)
            }
        } catch {
            viewModel.exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private var runButtonTitle: String {
        if viewModel.mode == .eventRelated {
            return viewModel.wtplResult == nil ? "Run WTPL" : "Re-run WTPL"
        }
        if viewModel.mode == .bursts {
            return viewModel.burstResult == nil ? "Detect Bursts" : "Re-run Bursts"
        }
        return viewModel.laviResult == nil ? "Run Analysis" : "Re-run Analysis"
    }

    private var canExport: Bool {
        switch viewModel.mode {
        case .bands: return viewModel.laviResult != nil
        case .eventRelated: return viewModel.wtplResult != nil
        case .bursts: return viewModel.burstResult != nil
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
