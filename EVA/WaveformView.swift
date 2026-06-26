//
//  WaveformView.swift
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
//  Recording content view: scrolling multi-channel EEG waveforms, an event
//  track, a double-click-to-open scalp topomap, and an events panel.
//

import Accelerate
import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct WaveformView: View {
    @ObservedObject var recording: MFFRecording

    @Environment(\.modelContext) private var modelContext
    @Query private var markers: [UserMarker]

    @State private var amplitudeScale: Double = 100
    @State private var timeScale: Double = 1
    @State private var horizontalOffset: CGFloat = 0
    @State private var horizontalViewportWidth: CGFloat = 1
    @State private var horizontalScrollPosition = ScrollPosition(idType: Int.self, x: 0)
    @State private var horizontalJumpValue: Double = 0
    @State private var isSyncingSliderFromScroll = false
    @State private var isCommandKeyPressed = false
    @State private var commandKeyMonitor: Any?
    @State private var showsEventsPanel = false
    @State private var selectedEventID: MFFEvent.ID?
    @State private var selectedEventCodes = Set<String>()
    @State private var topomapSample: Int?
    @State private var butterflyTopomapRelativeSample: Int?
    @State private var selectedSampleRange: ClosedRange<Int>?
    @State private var dragSelectionStartSample: Int?
    @State private var dragSelectionEndSample: Int?
    /// Timestamp of the last stationary click, used to detect a double-click
    /// manually inside the single waveform interaction gesture.
    @State private var lastWaveformClick: (time: Date, x: CGFloat)?
    /// Live global x of the scrolling waveform content's leading edge. Used to
    /// convert a gesture's global x into a scroll-independent content x.
    @State private var waveformContentMinX: CGFloat = 0
    @State private var detectsEyeBlinkArtifacts = false
    @State private var detectsEyeMovementArtifacts = false
    @State private var detectsECGArtifacts = false
    @State private var artifactDetectionMethod = ArtifactDetectionMethod.threshold
    @State private var artifactEvents: [MFFEvent] = []
    @State private var isDetectingArtifacts = false
    @State private var artifactStatusMessage: String?
    @State private var artifactDetectionRefreshToken = 0
    @State private var showsArtifactTemplateSheet = false
    @State private var artifactTemplateSelectionRange: ClosedRange<Int>?
    @State private var artifactTemplateClickedChannel: Int?
    @State private var artifactTemplateType = DefinedArtifactType.ocular
    @State private var artifactTemplateDefinedArtifactID: DefinedArtifact.ID?
    @State private var artifactTemplateName = "Eye Blink"
    @State private var artifactTemplateEventCode = "Eye Blink"
    @State private var artifactTemplateChannelScope = ArtifactTemplateChannelScope.clickedChannel
    @State private var artifactTemplateCustomChannels = ""
    @State private var artifactTemplateThreshold = 0.70
    @State private var artifactTemplateWindowSeconds = 0.40
    @State private var artifactTemplateDownsampleRate = 250.0
    @State private var artifactTemplateMergeWindowSeconds = 0.25
    @State private var artifactTemplatePolarity = ArtifactTemplatePolarity.same
    @State private var artifactTemplateTopographyMode = ArtifactTopographyMode.off
    @State private var artifactTopographyChannelScope = ArtifactTopographyChannelScope.allGood
    @State private var artifactTopographyMetric = ArtifactTopographyMetric.pearson
    @State private var isRefreshingTopography = false
    /// Monotonic token so out-of-order live topography refreshes can be ignored
    /// (only the most recently started refresh is allowed to apply its result).
    @State private var topographyRefreshGeneration = 0
    /// Snapshot of the scan-affecting controls at the moment the last full scan
    /// ran, used to know when the displayed result is stale (→ "Rescan").
    @State private var lastArtifactScanSignature: ArtifactScanSignature?
    @State private var isApplyingArtifactTemplate = false
    @State private var artifactTemplateResult: ArtifactTemplateDetectionResult?
    @State private var selectedArtifactTemplateChannel: Int?
    @State private var artifactTemplateStatusMessage: String?
    @State private var definedArtifacts: [DefinedArtifact] = []
    @State private var showsArtifactCleaningSheet = false
    @State private var isCleaningArtifacts = false
    @State private var artifactCleaningStatusMessage: String?
    @State private var artifactCleaningSummaries: [ArtifactCleaningSummary] = []
    @State private var artifactCleaningProgress: ArtifactCleaningProgress?
    @State private var artifactDeletionRequest: DefinedArtifact.ID?
    @State private var deleteAllArtifactsRequest = 0
    @State private var obsVarianceReportCache = [String: OBSPCAVarianceReport]()
    @State private var showsICASheet = false
    @State private var isRunningICA = false
    @State private var icaProgress = 0.0
    @State private var icaProgressMessage = ""
    @State private var icaMethod: ICAMethod = .picard
    @State private var icaComponentCount = 20
    @State private var icaVarianceThreshold = 0.99
    @State private var icaUsesAverageReference = true
    @State private var icaDownsampleRate = 100.0
    @State private var icaMaxIterations = 200
    @State private var icaUsesFitFilter = true
    @State private var icaFitLowCutoff = 1.0
    @State private var icaFitHighCutoff = 40.0
    @State private var icaFitNotch60HzEnabled = false
    @State private var icaConvergenceTolerance = 0.000000000001
    @State private var icaMinimumIterations = 10
    @State private var icaStatusMessage: String?
    @State private var icaDecomposition: ICADecomposition?
    @State private var isRemovingICAComponents = false
    @State private var icaDebugReportRequest = 0
    @State private var icaDebugReportSerial = 0
    @State private var lastICAReconstructionDebugReport: String?
    @State private var showsPSASheet = false
    @State private var psaSelectedEventCodes = Set<String>()
    @State private var psaPreStimulus = 0.2
    @State private var psaPostStimulus = 0.8
    @State private var psaOffset = 0.0
    @State private var psaCategoryNames = [String: String]()
    @State private var psaSkipIfContainsArtifact = false
    @State private var psaSkipEyeBlinks = true
    @State private var psaSkipEyeMovements = true
    @State private var psaSkippedDefinedArtifactIDs = Set<DefinedArtifact.ID>()
    @State private var psaKnownArtifactIDsForRejection = Set<DefinedArtifact.ID>()
    @State private var psaAverageOnApply = false
    @State private var psaBaselineCorrected = false
    @State private var psaAverageReference = false
    @State private var psaStatusMessage: String?
    @State private var epochedSignal: MFFSignalData?
    @State private var epochSegments: [EpochSegment] = []
    @State private var segmentedEpochSignal: MFFSignalData?
    @State private var segmentedEpochSegments: [EpochSegment] = []
    @State private var psaIsAveraged = false
    @State private var showsButterflyPlot = false
    @State private var showsOverlaidCategories = false

    // Band-pass / notch filtering (applied to the active base signal).
    @State private var icaCleanedSignal: MFFSignalData?
    @State private var filteredSignal: MFFSignalData?
    @State private var artifactCleanedSignal: MFFSignalData?
    @State private var artifactCleaningIsEnabled = true
    @State private var isFiltering = false
    @State private var filterProgress: Double = 0
    @State private var filterStatusMessage: String?
    @State private var showsFilterPopover = false
    @State private var filterLowCutoff = 0.1
    @State private var filterHighCutoff = 30.0
    @State private var notch60HzEnabled = false
    @State private var filterAverageReference = false

    // MRI artifact removal. The gradient-corrected signal becomes the base that
    // filtering and display build on.
    @State private var gradientCorrectedSignal: MFFSignalData?
    @State private var isProcessingMRI = false
    @State private var mriStatusMessage: String?
    @State private var mriProgress: Double = 0

    // Per-channel state, shared with the menu-bar Channels commands.
    @State private var channels = ChannelModel()
    @State private var electrodeGeometry: ElectrodeGeometry?
    @State private var channelStatusMessage: String?
    @State private var channelHealthStatusMessage: String?
    @State private var channelHealthSignature: String?
    @State private var channelHealthTask: Task<Void, Never>?
    @State private var channelLabelMetricsExportRequest = 0
    @State private var showsSegmentHealth = false
    @State private var showsSegmentHealthMouseOver = false
    @State private var showsSegmentHealthDetails = false
    @State private var segmentHealthAnalysis: SegmentHealthAnalysis?
    @State private var isAnalyzingSegmentHealth = false
    @State private var segmentHealthProgress: Double = 0
    @State private var segmentHealthStatusMessage: String?
    @State private var segmentHealthSignature: String?
    @State private var segmentHealthTask: Task<Void, Never>?
    @State private var segmentHealthDetailsRequest = 0
    @State private var segmentHealthRefreshRequest = 0
    @State private var resetToOriginalRequest = 0
    @State private var mffExportRequest = 0
    @State private var isExportingMFF = false
    @State private var mffExportStatusMessage: String?

    private let sampleStride = 5
    private let channelRowHeight: CGFloat = 70
    private let channelOverflowHeight: CGFloat = 28
    private let eventTrackHeight: CGFloat = 64
    private let rowSpacing: CGFloat = 12
    private let labelColumnWidth: CGFloat = 120
    private let eventsPanelWidth: CGFloat = 300
    private let topomapPanelWidth: CGFloat = 320
    private let butterflyPanelWidth: CGFloat = 360
    private let overlaidCategoriesPanelWidth: CGFloat = 380

    var body: some View {
        Group {
            if recording.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Opening \(recording.packageName)…")
                        .font(.headline)
                    Text("Reading EEG channels and events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let rawSignal = recording.signal {
                // Processing pipeline: raw → gradient-corrected → ICA-cleaned →
                // band-pass → artifact-cleaned → interpolated-channel overlay.
                // `base` is what filtering builds on; `preArtifact` is the
                // reversible source used by Clean Artifacts.
                let base = icaCleanedSignal ?? gradientCorrectedSignal ?? rawSignal
                let preArtifact = filteredSignal ?? base
                let processed = artifactCleaningIsEnabled ? (artifactCleanedSignal ?? preArtifact) : preArtifact
                let continuousSignal = applyInterpolations(to: processed)
                content(
                    for: epochedSignal ?? continuousSignal,
                    base: base,
                    cleaningBase: preArtifact,
                    continuousSignal: continuousSignal
                )
            } else {
                ContentUnavailableView(
                    "Couldn't Read Recording",
                    systemImage: "waveform.slash",
                    description: Text(recording.loadError ?? "This file is not a readable MFF package.")
                )
            }
        }
        .navigationTitle(recording.packageName)
        .focusedSceneValue(\.channelModel, channels)
        .focusedSceneValue(\.channelLabelMetricsExportRequest, $channelLabelMetricsExportRequest)
        .focusedSceneValue(\.artifactMenuControls, ArtifactMenuControls(
            artifacts: definedArtifacts,
            deleteRequest: $artifactDeletionRequest,
            deleteAllRequest: $deleteAllArtifactsRequest
        ))
        .focusedSceneValue(\.icaDebugReportRequest, $icaDebugReportRequest)
        .focusedSceneValue(\.resetToOriginalRequest, $resetToOriginalRequest)
        .focusedSceneValue(\.psaViewControls, PSAViewControls(
            showButterfly: $showsButterflyPlot,
            showOverlaidCategories: $showsOverlaidCategories,
            isAveraged: psaIsAveraged
        ))
        .focusedSceneValue(\.segmentHealthViewControls, SegmentHealthViewControls(
            showsHealth: $showsSegmentHealth,
            showsMouseOverHealth: $showsSegmentHealthMouseOver,
            detailsRequest: $segmentHealthDetailsRequest,
            refreshRequest: $segmentHealthRefreshRequest,
            isAnalyzing: isAnalyzingSegmentHealth,
            progress: segmentHealthProgress
        ))
        .focusedSceneValue(\.mffExportRequest, $mffExportRequest)
        .onChange(of: resetToOriginalRequest) { _, _ in
            resetToOriginalData()
        }
        .onChange(of: mffExportRequest) { _, _ in
            exportCurrentSignalToMFF()
        }
        .onChange(of: channelLabelMetricsExportRequest) { _, _ in
            saveChannelLabelMetricsJSON()
        }
        .onChange(of: segmentHealthDetailsRequest) { _, _ in
            showsSegmentHealth = true
            showsSegmentHealthDetails = true
        }
        .onChange(of: artifactDeletionRequest) { _, artifactID in
            guard let artifactID else { return }
            deleteDefinedArtifact(id: artifactID)
            artifactDeletionRequest = nil
        }
        .onChange(of: deleteAllArtifactsRequest) { _, _ in
            deleteAllDefinedArtifacts()
        }
        .onChange(of: psaBaselineCorrected) { _, _ in
            refreshEpochDisplay()
        }
        .onChange(of: psaAverageReference) { _, _ in
            refreshEpochDisplay()
        }
        .onChange(of: showsButterflyPlot) { _, _ in
            if !showsButterflyPlot, !showsOverlaidCategories {
                butterflyTopomapRelativeSample = nil
            }
        }
        .onChange(of: showsOverlaidCategories) { _, _ in
            if !showsButterflyPlot, !showsOverlaidCategories {
                butterflyTopomapRelativeSample = nil
            }
        }
        .onChange(of: icaDebugReportRequest) { _, _ in
            copyICADebugReportToPasteboard()
        }
        .task {
            await recording.loadIfNeeded()
            if electrodeGeometry == nil {
                electrodeGeometry = recording.electrodeGeometry
            }
        }
        .onAppear {
            installCommandKeyMonitor()
        }
        .onDisappear {
            removeCommandKeyMonitor()
            channelHealthTask?.cancel()
            channelHealthTask = nil
            segmentHealthTask?.cancel()
            segmentHealthTask = nil
        }
    }

    /// Markers the user has created for *this* recording, surfaced as events.
    private var userMarkerEvents: [MFFEvent] {
        markers
            .filter { $0.packageName == recording.packageName }
            .map { marker in
                MFFEvent(
                    id: "user-marker-\(marker.persistentModelID.hashValue)",
                    code: marker.note.isEmpty ? "Marker" : marker.note,
                    beginTimeSeconds: marker.timeSeconds,
                    rawBeginTime: "",
                    sourceFile: "User Markers"
                )
            }
    }

    /// The signal's own events plus user markers and generated in-memory artifact events, time-sorted.
    private func displayedEvents(
        for signal: MFFSignalData,
        includeContinuousOverlays: Bool = true,
        mapContinuousOverlaysIntoEpochs: Bool = false
    ) -> [MFFEvent] {
        guard includeContinuousOverlays else {
            return signal.events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        }

        let overlays = mapContinuousOverlaysIntoEpochs
            ? epochedContinuousOverlayEvents(for: signal)
            : continuousOverlayEventsForDisplay()
        return (signal.events + overlays).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    private func continuousOverlayEventsForDisplay() -> [MFFEvent] {
        var events = userMarkerEvents
        var seen = Set(events)

        for event in definedArtifacts.flatMap(\.events) where seen.insert(event).inserted {
            events.append(event)
        }
        for event in artifactEvents where seen.insert(event).inserted {
            events.append(event)
        }

        return events
    }

    private func epochedContinuousOverlayEvents(for signal: MFFSignalData) -> [MFFEvent] {
        guard epochedSignal != nil,
              signal.samplingRate > 0,
              !epochSegments.isEmpty else {
            return []
        }

        return continuousOverlayEventsForDisplay()
            .flatMap { event in
                epochSegments.compactMap { segment in
                    epochedOverlayEvent(event, in: segment, samplingRate: signal.samplingRate)
                }
            }
            .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    private func epochedOverlayEvent(
        _ event: MFFEvent,
        in segment: EpochSegment,
        samplingRate: Double
    ) -> MFFEvent? {
        let epochSampleCount = segment.endSample - segment.startSample + 1
        guard epochSampleCount > 0 else { return nil }

        let epochStartSeconds = segment.sourceTimeSeconds - Double(segment.stimulusOffsetSamples) / samplingRate
        let epochEndSeconds = epochStartSeconds + Double(epochSampleCount) / samplingRate
        guard event.beginTimeSeconds >= epochStartSeconds,
              event.beginTimeSeconds < epochEndSeconds else {
            return nil
        }

        let offsetSamples = Int(((event.beginTimeSeconds - epochStartSeconds) * samplingRate).rounded())
        let displaySample = min(max(segment.startSample + offsetSamples, segment.startSample), segment.endSample)
        let displayTime = Double(displaySample) / samplingRate
        return MFFEvent(
            id: "epoched-overlay-\(segment.id)-\(event.id)",
            code: event.code,
            beginTimeSeconds: displayTime,
            rawBeginTime: event.rawBeginTime,
            sourceFile: event.sourceFile
        )
    }

    @ViewBuilder
    private func content(
        for signal: MFFSignalData,
        base: MFFSignalData,
        cleaningBase: MFFSignalData,
        continuousSignal: MFFSignalData
    ) -> some View {
        let isShowingEpochs = epochedSignal != nil
        let events = displayedEvents(
            for: signal,
            includeContinuousOverlays: true,
            mapContinuousOverlaysIntoEpochs: isShowingEpochs
        )

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                controls(for: signal, base: base, continuousSignal: continuousSignal)

                Divider()

                waveformArea(for: signal, events: events, isShowingEpochs: isShowingEpochs)
            }

            if showsEventsPanel {
                Divider()
                eventsPanel(for: signal, events: events)
                    .frame(width: eventsPanelWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }

            if showsButterflyPlot, psaIsAveraged {
                Divider()
                butterflyPanel(for: signal)
                    .frame(width: butterflyPanelWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }

            if showsOverlaidCategories, psaIsAveraged {
                Divider()
                overlaidCategoriesPanel(for: signal)
                    .frame(width: overlaidCategoriesPanelWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }

            if let topomapSample {
                Divider()
                topomapPanel(for: signal, sample: topomapSample)
                    .frame(width: topomapPanelWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }

            if let butterflyTopomapRelativeSample, psaIsAveraged {
                Divider()
                averagedTopomapPanel(for: signal, relativeSample: butterflyTopomapRelativeSample)
                    .frame(width: topomapPanelWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .sheet(isPresented: $showsPSASheet) {
            psaSheet(for: continuousSignal)
        }
        .sheet(isPresented: $showsArtifactTemplateSheet) {
            artifactTemplateSheet(for: continuousSignal)
        }
        .sheet(isPresented: $showsArtifactCleaningSheet) {
            artifactCleaningSheet(for: cleaningBase)
        }
        .sheet(isPresented: $showsICASheet) {
            icaSheet(for: base)
        }
        .sheet(isPresented: $showsSegmentHealthDetails) {
            segmentHealthDetailsSheet()
        }
        .onChange(of: artifactDetectionMethod) { _, method in
            if method == .ica {
                DispatchQueue.main.async {
                    openICASheet(for: base)
                }
            }
        }
        .task(id: artifactDetectionRequestID(for: continuousSignal)) {
            await updateArtifactEvents(for: continuousSignal)
        }
        .task(id: channelHealthRequestID(for: continuousSignal)) {
            refreshChannelHealthIfNeeded(for: continuousSignal)
        }
        .task(id: segmentHealthRequestID(for: signal)) {
            refreshSegmentHealthIfNeeded(for: signal)
        }
    }

    // MARK: - Controls

    private func controls(for signal: MFFSignalData, base: MFFSignalData, continuousSignal: MFFSignalData) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Amplitude")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: $amplitudeScale, in: 10...1000, step: 10)
                        .frame(width: 170)
                    Text("\(Int(amplitudeScale)) µV")
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("Time Scale")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: $timeScale, in: 0.2...8, step: 0.1)
                        .frame(width: 170)
                    Text(String(format: "%.1fx", timeScale))
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
            }

            HStack(spacing: 6) {
            Menu {
                Button("Gradient Artifact Removal") {
                    removeGradientArtifact(from: recording.signal)
                }
                .disabled(isProcessingMRI || recording.signal == nil)

                if gradientCorrectedSignal != nil {
                    Button("Restore Original (Undo Gradient Removal)", role: .destructive) {
                        clearGradientCorrection()
                    }
                }

                Divider()

                Button("BCG Removal") {}
                    .disabled(true)
                    .help("Ballistocardiogram removal — coming soon.")
            } label: {
                ToolbarIcon(name: "icon.mri", isActive: gradientCorrectedSignal != nil)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("MRI")
            .disabled(isProcessingMRI)
            .help(gradientCorrectedSignal != nil
                ? "Gradient artifact removed using TREV triggers."
                : "MR artifact removal")

            Button {
                showsFilterPopover.toggle()
            } label: {
                ToolbarIcon(name: "icon.filter", isActive: filteredSignal != nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter")
            .disabled(isFiltering)
            .help(filteredSignal != nil
                ? "Active: Butterworth \(String(format: "%.1f", filterLowCutoff))–\(String(format: "%.1f", filterHighCutoff)) Hz\(notch60HzEnabled ? " + 60 Hz notch" : "")\(filterAverageReference ? " + avg ref" : "")"
                : "Apply a band-pass / notch / average-reference filter")
            .popover(isPresented: $showsFilterPopover, arrowEdge: .bottom) {
                filterPopover(for: base)
            }

            Menu {
                if activeSelectionRange(in: signal) != nil,
                   let defaultChannel = defaultArtifactTemplateChannel(in: signal) {
                    Button("Define Artifact…") {
                        openArtifactTemplateSheet(for: signal, clickedChannel: defaultChannel)
                    }

                    Divider()
                }

                Button("Clean Artifacts…") {
                    showsArtifactCleaningSheet = true
                }
                .disabled(definedArtifacts.isEmpty)

                Toggle("Show Applied Correction", isOn: Binding(
                    get: { artifactCleaningIsEnabled },
                    set: { setArtifactCleaningEnabled($0) }
                ))
                .disabled(artifactCleanedSignal == nil)
                .help(artifactCleanedSignal == nil
                    ? "Apply artifact cleaning before toggling the corrected signal."
                    : "Switch between the artifact-corrected signal and the uncorrected signal.")

                Divider()

                Toggle("Eye Blink", isOn: $detectsEyeBlinkArtifacts)
                Toggle("Eye Movement", isOn: $detectsEyeMovementArtifacts)
                Toggle("ECG", isOn: $detectsECGArtifacts)
                    .disabled(true)
                    .help("ECG artifact detection is not implemented yet.")

                Divider()

                Picker("Method", selection: $artifactDetectionMethod) {
                    ForEach(ArtifactDetectionMethod.allCases) { method in
                        Text(method.rawValue)
                            .tag(method)
                    }
                }
                .pickerStyle(.inline)

                if artifactDetectionMethod == .threshold, detectsEyeBlinkArtifacts || detectsEyeMovementArtifacts {
                    Divider()
                    Text("Threshold: ±150 µV on EGI VEOG/HEOG channels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if artifactDetectionMethod == .template {
                    Divider()
                    Text("Right-click a highlighted waveform region to define a template.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if artifactDetectionMethod == .ica {
                    Divider()
                    Button("Run / Review ICA…") {
                        openICASheet(for: base)
                    }
                    Text("Inspect component maps and remove selected components.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                ToolbarIcon(name: "icon.artifacts", isActive: artifactsAreActive)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("Artifacts")
            .help(artifactHelpText)

            Menu {
                Button("Segment…") {
                    openPSASheet(for: continuousSignal)
                }

                Button("Average Current Epochs") {
                    averageCurrentEpochs()
                }
                .disabled(segmentedEpochSignal == nil || segmentedEpochSegments.isEmpty)

                Toggle("Average Reference", isOn: $psaAverageReference)
                    .disabled(epochedSignal == nil)
                    .help("Re-reference the epochs to the common average of the good channels (excludes bad channels, uses interpolated values).")

                Toggle("Baseline Correction (pre-stimulus)", isOn: $psaBaselineCorrected)
                    .disabled(epochedSignal == nil)
                    .help("Subtract each epoch's mean over the pre-stimulus interval from the whole epoch.")

                Button(showsButterflyPlot ? "Hide Butterfly" : "Show Butterfly") {
                    showsButterflyPlot.toggle()
                    if !showsButterflyPlot {
                        butterflyTopomapRelativeSample = nil
                    }
                }
                .disabled(!psaIsAveraged || epochedSignal == nil)

                if epochedSignal != nil {
                    Divider()
                    Button("Undo Segmentation", role: .destructive) {
                        clearEpochs()
                    }
                }
            } label: {
                ToolbarIcon(name: "icon.process", isActive: epochedSignal != nil)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("Processing")
            .help("Segment the recording into event-locked epochs")

            Button {
                showsEventsPanel.toggle()
            } label: {
                ToolbarIcon(name: "icon.events", isActive: showsEventsPanel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Events")
            .help(showsEventsPanel ? "Hide the events panel" : "Show the events panel")

            if let topomapSample {
                Button("Mark Time Point") {
                    addMarker(atSample: topomapSample, in: signal)
                }
                .help("Save a marker at the current topomap cursor.")
            }
            }

            Spacer(minLength: 12)

            statusLog()
                .frame(width: 240)

            Text("\(signal.numberOfChannels) ch · \(Int(signal.samplingRate)) Hz · \(String(format: "%.1f", signal.duration)) s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Status log

    /// A single line shown in the toolbar log area.
    private struct LogLine: Hashable {
        let text: String
        let isError: Bool
    }

    /// Messages currently worth surfacing, gathered from each feature's status.
    private var activeLogMessages: [LogLine] {
        var lines: [LogLine] = []
        if !isProcessingMRI, let mriStatusMessage {
            lines.append(LogLine(text: mriStatusMessage, isError: true))
        }
        if !isFiltering, let filterStatusMessage {
            lines.append(LogLine(text: filterStatusMessage, isError: true))
        }
        if let psaStatusMessage {
            lines.append(LogLine(text: psaStatusMessage, isError: false))
        }
        if let channelStatusMessage {
            lines.append(LogLine(text: channelStatusMessage, isError: true))
        }
        if let channelHealthStatusMessage {
            lines.append(LogLine(text: channelHealthStatusMessage, isError: false))
        }
        if let segmentHealthStatusMessage {
            lines.append(LogLine(text: segmentHealthStatusMessage, isError: false))
        }
        if let artifactCleaningStatusMessage {
            lines.append(LogLine(text: artifactCleaningStatusMessage, isError: false))
        }
        if let mffExportStatusMessage {
            lines.append(LogLine(text: mffExportStatusMessage, isError: false))
        }
        return lines
    }

    /// Consolidated status/progress area shown at the far right of the toolbar,
    /// so individual buttons no longer push inline messages into the layout.
    @ViewBuilder
    private func statusLog() -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if isProcessingMRI {
                logProgressRow(label: "MRI", value: mriProgress)
            }
            if isFiltering {
                logProgressRow(label: "Filter", value: filterProgress)
            }
            if let artifactCleaningProgress {
                logProgressRow(label: "Artifact", value: artifactCleaningProgress.fraction)
            }
            if channels.isAnalyzingHealth {
                logProgressRow(label: "Health", value: channels.healthProgress)
            }
            if isAnalyzingSegmentHealth {
                logProgressRow(label: "Segments", value: segmentHealthProgress)
            }
            if isExportingMFF {
                logProgressRow(label: "MFF", value: 0.5)
            }

            ForEach(activeLogMessages, id: \.self) { line in
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(line.isError ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line.text)
            }

            if !isProcessingMRI,
               !isFiltering,
               !channels.isAnalyzingHealth,
               !isAnalyzingSegmentHealth,
               activeLogMessages.isEmpty {
                Text("Ready")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status log")
    }

    private func logProgressRow(label: String, value: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: value)
                .progressViewStyle(.linear)
            Text("\(Int(value * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Waveform area

    @ViewBuilder
    private func waveformArea(for signal: MFFSignalData, events: [MFFEvent], isShowingEpochs: Bool) -> some View {
        let plotWidth = plotWidth(for: signal)

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Events")
                        .font(.system(.headline, design: .monospaced))
                    if let recordingStartTime = signal.recordingStartTime {
                        Text(recordingStartTime.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(events.count) markers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: labelColumnWidth, height: eventTrackHeight, alignment: .topLeading)

                EventTrackView(
                    events: events,
                    samplingRate: signal.samplingRate,
                    timeScale: timeScale,
                    sampleStride: sampleStride,
                    contentOffset: horizontalOffset,
                    visibleRange: visibleHorizontalRange,
                    viewportWidth: horizontalViewportWidth
                )
                .frame(maxWidth: .infinity, minHeight: eventTrackHeight, maxHeight: eventTrackHeight)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 12) {
                    LazyVStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(channelIndices(in: signal), id: \.self) { index in
                            channelLabel(index: index, signal: signal)
                        }
                    }
                    .frame(width: labelColumnWidth, alignment: .topLeading)

                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: rowSpacing) {
                            ForEach(channelIndices(in: signal), id: \.self) { index in
                                waveformRow(index: index, channel: signal.data[index], plotWidth: plotWidth, signal: signal)
                            }
                        }
                        // Each overlay is its own independent layer so that the
                        // selection band growing during a drag cannot relayout or
                        // shift the topomap cursor's rendering.
                        .overlay(alignment: .topLeading) { segmentHealthOverlay(for: signal) }
                        .overlay(alignment: .topLeading) { epochBoundaryOverlay() }
                        .overlay(alignment: .topLeading) { selectionOverlay(for: signal) }
                        .overlay(alignment: .topLeading) { cursorOverlay() }
                        .contentShape(Rectangle())
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onChange(of: proxy.frame(in: .global).minX, initial: true) { _, newValue in
                                        waveformContentMinX = newValue
                                    }
                            }
                        )
                        .gesture(waveformInteractionGesture(in: signal))
                        .padding(.trailing, 20)
                    }
                    .scrollPosition($horizontalScrollPosition)
                    .scrollIndicators(.visible, axes: .horizontal)
                    .onScrollGeometryChange(
                        for: HorizontalViewport.self,
                        of: { geometry in
                            HorizontalViewport(
                                offsetX: geometry.contentOffset.x,
                                width: geometry.containerSize.width
                            )
                        },
                        action: { _, newValue in
                            horizontalOffset = max(newValue.offsetX, 0)
                            horizontalViewportWidth = max(newValue.width, 1)
                            let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
                            isSyncingSliderFromScroll = true
                            horizontalJumpValue = maxOffset > 0 ? Double(horizontalOffset / maxOffset) : 0
                            isSyncingSliderFromScroll = false
                        }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            if isCommandKeyPressed || selectedSampleRange != nil || isShowingEpochs {
                Divider()

                HStack(spacing: 16) {
                    if isCommandKeyPressed {
                        Text("Jump")
                            .font(.caption.weight(.semibold))
                            .frame(width: labelColumnWidth, alignment: .leading)

                        Slider(value: $horizontalJumpValue, in: 0...1)
                            .onChange(of: horizontalJumpValue) { _, newValue in
                                guard !isSyncingSliderFromScroll else { return }
                                let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
                                horizontalScrollPosition.scrollTo(x: CGFloat(newValue) * maxOffset)
                            }
                    }

                    if let selectedSampleRange {
                        Text(selectionDescription(selectedSampleRange, in: signal))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Button("Clear Selection") {
                            clearSelection()
                        }
                        .font(.caption)
                    }

                    Spacer(minLength: 0)

                    if isShowingEpochs {
                        epochLegend()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Channels

    private func channelIndices(in signal: MFFSignalData) -> [Int] {
        Array(signal.data.indices)
    }

    /// Trace/label color: gray for bad, teal for interpolated, accent otherwise.
    private func channelColor(_ index: Int) -> Color {
        if channels.bad.contains(index) { return .gray }
        if channels.interpolated[index] != nil { return .teal }
        return .accentColor
    }

    private func channelLabel(index: Int, signal: MFFSignalData) -> some View {
        let isHidden = channels.hidden.contains(index)
        let label = signal.channelNames?.indices.contains(index) == true
            ? signal.channelNames?[index].nilIfEmpty ?? "Ch \(index + 1)"
            : "Ch \(index + 1)"
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isHidden {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                } else if channels.interpolated[index] != nil {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                } else if channels.bad.contains(index) {
                    Image(systemName: "xmark.circle")
                        .font(.caption2)
                }
            }
            .foregroundStyle(channelColor(index))
            .frame(maxWidth: .infinity, alignment: .leading)

            if channels.showsHealth {
                ChannelHealthBadge(
                    result: channels.healthResults[index],
                    isAnalyzing: channels.isAnalyzingHealth
                )
            }
        }
        .opacity(isHidden ? 0.4 : 1)
        .frame(maxWidth: .infinity, minHeight: channelRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { toggleHidden(index) }
        .help("Click to show/hide the trace. Right-click for Mark Bad / Interpolate.")
        .contextMenu {
            if channels.bad.contains(index) {
                Button("Unmark Bad") { channels.bad.remove(index) }
            } else {
                Button("Mark Bad") { channels.bad.insert(index) }
            }

            if channels.interpolated[index] != nil {
                Button("Remove Interpolation") { channels.interpolated[index] = nil }
            } else {
                Button("Interpolate") { interpolate(index, in: signal) }
                    .disabled(electrodeGeometry?.positions[index] == nil)
            }

            Divider()
            Button(isHidden ? "Show Trace" : "Hide Trace") { toggleHidden(index) }
        }
    }

    private func toggleHidden(_ index: Int) {
        if channels.hidden.contains(index) {
            channels.hidden.remove(index)
        } else {
            channels.hidden.insert(index)
        }
    }

    @ViewBuilder
    private func waveformRow(index: Int, channel: [Float], plotWidth: CGFloat, signal: MFFSignalData) -> some View {
        WaveformPlot(
            // Hidden channels keep their row but draw no trace.
            samples: channels.hidden.contains(index) ? [] : channel,
            amplitudeScale: amplitudeScale,
            timeScale: timeScale,
            sampleStride: sampleStride,
            visibleRange: visibleHorizontalRange,
            nominalHeight: channelRowHeight,
            color: channelColor(index)
        )
        .frame(width: plotWidth, height: channelRowHeight + (channelOverflowHeight * 2))
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: plotWidth, height: channelRowHeight)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                .frame(width: plotWidth, height: channelRowHeight)
        }
        .frame(width: plotWidth, height: channelRowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Define Artifact…") {
                openArtifactTemplateSheet(for: signal, clickedChannel: index)
            }
            .disabled(activeSelectionRange(in: signal) == nil)
        }
        .accessibilityLabel("Channel \(index + 1)")
        .zIndex(1)
    }

    /// Vertical cursor at the topomap sample, drawn once across the channel
    /// stack. Vivid orange so it is unmistakably distinct from the blue
    /// selection band.
    @ViewBuilder
    private func cursorOverlay() -> some View {
        if let topomapSample {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: contentX(forSample: topomapSample) - 1)
                .allowsHitTesting(false)
        }
    }

    /// Highlighted time selection across the full channel stack. Uses a fixed
    /// blue (not the system accent) so it can never be confused with the yellow
    /// topomap cursor, regardless of the user's macOS accent colour.
    @ViewBuilder
    private func selectionOverlay(for signal: MFFSignalData) -> some View {
        if let range = activeSelectionRange(in: signal) {
            let lowerX = contentX(forSample: range.lowerBound)
            let upperX = contentX(forSample: range.upperBound)
            let selectionColor = Color(nsColor: .systemBlue)
            Rectangle()
                .fill(selectionColor.opacity(0.16))
                .frame(width: max(upperX - lowerX, 2))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(selectionColor.opacity(0.8))
                        .frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(selectionColor.opacity(0.8))
                        .frame(width: 1)
                }
                .offset(x: lowerX)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func segmentHealthOverlay(for signal: MFFSignalData) -> some View {
        if showsSegmentHealth,
           let results = segmentHealthAnalysis?.results,
           let sampleCount = signal.data.first?.count,
           sampleCount > 0 {
            ZStack(alignment: .topLeading) {
                ForEach(results) { result in
                    let start = min(max(result.startSample, 0), sampleCount - 1)
                    let end = min(max(result.endSample + 1, start + 1), sampleCount)
                    let startX = contentX(forSample: start)
                    let endX = contentX(forSample: end)
                    SegmentHealthBand(
                        result: result,
                        showsMouseOverHealth: showsSegmentHealthMouseOver
                    )
                        .frame(width: max(endX - startX, 2))
                        .frame(maxHeight: .infinity)
                        .offset(x: startX)
                }
            }
        }
    }

    /// Distance (pt) a press must travel before it counts as a selection drag
    /// rather than a click.
    private static let dragSelectionThreshold: CGFloat = 4
    /// Max seconds between two clicks to count as a double-click.
    private static let doubleClickInterval: TimeInterval = 0.5

    /// A single gesture that handles BOTH the selection drag and the
    /// double-click topomap cursor. Doing it in one gesture avoids SwiftUI's
    /// gesture arbitration entirely: a press that moves past the threshold is a
    /// selection; a stationary press is a click, and two clicks in quick
    /// succession place the topomap cursor. Neither can trigger the other.
    private func waveformInteractionGesture(in signal: MFFSignalData) -> some Gesture {
        // Global coordinate space, converted to content x by subtracting the
        // content's live leading edge (waveformContentMinX). This stays correct
        // even if the horizontal ScrollView scrolls during the drag.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard dragDistance(value) >= Self.dragSelectionThreshold else { return }
                dragSelectionStartSample = sampleIndex(forContentX: contentX(fromGlobalX: value.startLocation.x), in: signal)
                dragSelectionEndSample = sampleIndex(forContentX: contentX(fromGlobalX: value.location.x), in: signal)
            }
            .onEnded { value in
                if dragDistance(value) >= Self.dragSelectionThreshold {
                    // Treat as a selection drag.
                    let start = sampleIndex(forContentX: contentX(fromGlobalX: value.startLocation.x), in: signal)
                    let end = sampleIndex(forContentX: contentX(fromGlobalX: value.location.x), in: signal)
                    let lower = min(start, end)
                    let upper = max(start, end)
                    if upper > lower {
                        selectedSampleRange = lower...upper
                    }
                    dragSelectionStartSample = nil
                    dragSelectionEndSample = nil
                    lastWaveformClick = nil
                    return
                }

                // Otherwise it's a stationary click: detect a double-click by hand.
                let clickX = contentX(fromGlobalX: value.location.x)
                let now = Date()
                if let last = lastWaveformClick,
                   now.timeIntervalSince(last.time) < Self.doubleClickInterval,
                   abs(clickX - last.x) < 6 {
                    topomapSample = sampleIndex(forContentX: clickX, in: signal)
                    butterflyTopomapRelativeSample = nil
                    lastWaveformClick = nil
                } else {
                    lastWaveformClick = (now, clickX)
                }
            }
    }

    private func dragDistance(_ value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }

    /// Converts a global-space x into content-space x (0 == first sample),
    /// independent of the horizontal scroll position.
    private func contentX(fromGlobalX globalX: CGFloat) -> CGFloat {
        globalX - waveformContentMinX
    }

    private func activeSelectionRange(in signal: MFFSignalData) -> ClosedRange<Int>? {
        if let dragSelectionStartSample, let dragSelectionEndSample {
            let lower = min(dragSelectionStartSample, dragSelectionEndSample)
            let upper = max(dragSelectionStartSample, dragSelectionEndSample)
            return clampedSampleRange(lower...upper, in: signal)
        }

        if let selectedSampleRange {
            return clampedSampleRange(selectedSampleRange, in: signal)
        }

        return nil
    }

    private func clampedSampleRange(_ range: ClosedRange<Int>, in signal: MFFSignalData) -> ClosedRange<Int>? {
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return nil }
        let lower = min(max(range.lowerBound, 0), sampleCount - 1)
        let upper = min(max(range.upperBound, lower), sampleCount - 1)
        return lower...upper
    }

    private func selectionDescription(_ range: ClosedRange<Int>, in signal: MFFSignalData) -> String {
        guard signal.samplingRate > 0 else { return "Selection" }
        let lowerSeconds = Double(range.lowerBound) / signal.samplingRate
        let upperSeconds = Double(range.upperBound) / signal.samplingRate
        let duration = max(upperSeconds - lowerSeconds, 0)
        return String(format: "Selection %.3f–%.3fs (%.3fs)", lowerSeconds, upperSeconds, duration)
    }

    private func clearSelection() {
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
    }

    /// Green dividers between concatenated epochs.
    @ViewBuilder
    private func epochBoundaryOverlay() -> some View {
        if epochedSignal != nil {
            ForEach(epochSegments.dropFirst()) { segment in
                Rectangle()
                    .fill(Color.green)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .offset(x: contentX(forSample: segment.startSample) - 1)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func epochLegend() -> some View {
        if !epochSegments.isEmpty {
            let summaries = epochCategorySummaries()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(summaries) { summary in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(summary.color)
                                .frame(width: 12, height: 12)
                            Text("\(summary.category) · \(summary.count)")
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: 12, height: 2)
                        Text("epoch boundary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)
            }
            .frame(maxWidth: 320)
        }
    }

    // MARK: - Topomap panel

    @ViewBuilder
    private func topomapPanel(for signal: MFFSignalData, sample: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Topography")
                    .font(.headline)
                Spacer()
                Button {
                    topomapSample = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if let layout = recording.sensorLayout {
                TopomapView(
                    layout: layout,
                    values: topomapValues(at: sample, in: signal),
                    timeSeconds: signal.samplingRate > 0 ? Double(sample) / signal.samplingRate : 0,
                    fixedScale: nil
                )
                Spacer(minLength: 0)
            } else {
                ContentUnavailableView(
                    "No Sensor Layout",
                    systemImage: "circle.dashed",
                    description: Text("This package has no readable sensorLayout.xml, so a topographic map can't be drawn.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Butterfly panel

    @ViewBuilder
    private func butterflyPanel(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Butterfly")
                        .font(.headline)
                    Text("Averaged categories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsButterflyPlot = false
                    butterflyTopomapRelativeSample = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if psaIsAveraged, !epochSegments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(epochSegments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Label(segment.category, systemImage: "waveform.path.ecg")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(epochColor(for: segment.colorIndex))
                                    Spacer()
                                    Text("\(segment.contributingEpochCount) avg")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                GeometryReader { proxy in
                                    ButterflyConditionPlot(
                                        data: signal.data,
                                        segment: segment,
                                        hiddenChannels: channels.hidden,
                                        amplitudeScale: amplitudeScale,
                                        color: epochColor(for: segment.colorIndex),
                                        highlightRelativeSample: butterflyTopomapRelativeSample
                                    )
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(
                                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                                            .onEnded { value in
                                                butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: segment
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 6, coordinateSpace: .local)
                                            .onChanged { value in
                                                guard butterflyTopomapRelativeSample != nil else { return }
                                                butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: segment
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .help("Double-click to compare topographies at this latency. Drag the yellow line to move it.")
                                }
                                .frame(height: 150)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "No Averages",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Create PSA averages before showing a butterfly plot.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func overlaidCategoriesPanel(for signal: MFFSignalData) -> some View {
        let visibleChannels = signal.data.indices.filter { !channels.hidden.contains($0) }
        let colors = epochSegments.map { epochColor(for: $0.colorIndex) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overlaid Categories")
                        .font(.headline)
                    Text("All category averages, per channel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsOverlaidCategories = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if psaIsAveraged, !epochSegments.isEmpty {
                // Category color legend.
                FlowLegend(items: epochSegments.map { ($0.category, epochColor(for: $0.colorIndex)) })
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleChannels, id: \.self) { channelIndex in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Ch \(channelIndex + 1)")
                                    .font(.caption.weight(.semibold).monospaced())
                                    .foregroundStyle(channelColor(channelIndex))

                                GeometryReader { proxy in
                                    OverlaidCategoryChannelPlot(
                                        data: signal.data,
                                        channelIndex: channelIndex,
                                        segments: epochSegments,
                                        colors: colors,
                                        amplitudeScale: amplitudeScale,
                                        highlightRelativeSample: butterflyTopomapRelativeSample
                                    )
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(
                                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                                            .onEnded { value in
                                                guard let first = epochSegments.first else { return }
                                                butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: first
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 6, coordinateSpace: .local)
                                            .onChanged { value in
                                                guard butterflyTopomapRelativeSample != nil,
                                                      let first = epochSegments.first else { return }
                                                butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: first
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .help("Double-click to show a topomap for every category at this latency. Drag the yellow line to move it.")
                                }
                                .frame(height: 88)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "No Averages",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Create PSA averages before overlaying categories.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func averagedTopomapPanel(for signal: MFFSignalData, relativeSample: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Topographies")
                        .font(.headline)
                    Text(averagedTopomapLatencyText(relativeSample: relativeSample))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    butterflyTopomapRelativeSample = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if let layout = recording.sensorLayout {
                let samples = averagedTopomapSamples(relativeSample: relativeSample, in: signal)
                let scale = fixedTopomapScale(for: samples.map(\.sample), in: signal)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(samples) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.category)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(epochColor(for: entry.colorIndex))
                                TopomapView(
                                    layout: layout,
                                    values: topomapValues(at: entry.sample, in: signal),
                                    timeSeconds: entry.latencySeconds,
                                    fixedScale: scale
                                )
                                .frame(height: 320)
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "No Sensor Layout",
                    systemImage: "circle.dashed",
                    description: Text("This package has no readable sensorLayout.xml, so topographic maps can't be drawn.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func relativeSample(forButterflyX x: CGFloat, width: CGFloat, segment: EpochSegment) -> Int {
        let epochLength = max(segment.endSample - segment.startSample + 1, 1)
        let normalized = min(max(x / max(width, 1), 0), 1)
        return min(max(Int((normalized * CGFloat(epochLength - 1)).rounded()), 0), epochLength - 1)
    }

    private func averagedTopomapSamples(relativeSample: Int, in signal: MFFSignalData) -> [AveragedTopomapSample] {
        epochSegments.compactMap { segment in
            let epochLength = max(segment.endSample - segment.startSample + 1, 1)
            let localSample = min(max(relativeSample, 0), epochLength - 1)
            let sample = min(segment.startSample + localSample, segment.endSample)
            guard sample >= 0, sample < (signal.data.first?.count ?? 0) else { return nil }
            let latencySeconds = signal.samplingRate > 0
                ? Double(localSample - segment.stimulusOffsetSamples) / signal.samplingRate
                : 0
            return AveragedTopomapSample(
                category: segment.category,
                sample: sample,
                latencySeconds: latencySeconds,
                colorIndex: segment.colorIndex
            )
        }
    }

    private func averagedTopomapLatencyText(relativeSample: Int) -> String {
        guard let segment = epochSegments.first, (epochedSignal?.samplingRate ?? 0) > 0 else {
            return "Latency"
        }
        let samplingRate = epochedSignal?.samplingRate ?? 1
        let latency = Double(relativeSample - segment.stimulusOffsetSamples) / samplingRate
        return String(format: "Latency %.3fs", latency)
    }

    private func fixedTopomapScale(for samples: [Int], in signal: MFFSignalData) -> Double? {
        let maxAbs = samples
            .flatMap { sample in topomapValues(at: sample, in: signal).map(abs) }
            .max() ?? 0
        return maxAbs > 0 ? maxAbs : nil
    }

    // MARK: - Events panel

    @ViewBuilder
    private func eventsPanel(for signal: MFFSignalData, events: [MFFEvent]) -> some View {
        let summaries = groupedEventSummaries(events)
        let visibleEvents = filteredEvents(events)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Events")
                        .font(.headline)
                    Text("\(visibleEvents.count) of \(events.count) markers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsEventsPanel = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if !summaries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        codeChip(title: "All Events", count: events.count, isSelected: selectedEventCodes.isEmpty) {
                            selectedEventCodes.removeAll()
                        }
                        ForEach(summaries) { summary in
                            codeChip(title: summary.code, count: summary.count, isSelected: selectedEventCodes.contains(summary.code)) {
                                toggleEventCode(summary.code)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            Divider()

            if events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "list.bullet.rectangle",
                    description: Text("This recording has no event markers yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleEvents) { event in
                    Button {
                        jumpToEvent(event, in: signal)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.code)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                            Text(formattedEventTime(event.beginTimeSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(event.sourceFile)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedEventID == event.id ? Color.accentColor.opacity(0.14) : Color.clear
                    )
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func codeChip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Artifact template definition

    private func defaultArtifactTemplateChannel(in signal: MFFSignalData) -> Int? {
        signal.data.indices.first { !channels.hidden.contains($0) && !channels.bad.contains($0) }
            ?? signal.data.indices.first { !channels.hidden.contains($0) }
            ?? signal.data.indices.first
    }

    private func inferredArtifactType(name: String, eventCode: String) -> DefinedArtifactType {
        let text = "\(name) \(eventCode)".lowercased()
        if text.contains("ecg") || text.contains("heart") || text.contains("cardiac") {
            return .ecg
        }
        if text.contains("bcg") || text.contains("ballisto") {
            return .bcg
        }
        if text.contains("eye") || text.contains("blink") || text.contains("ocular") || text.contains("eog") {
            return .ocular
        }
        return .other
    }

    private func nextArtifactTemplateDefaultName(baseName: String = "Eye Blink") -> String {
        let existingNames = Set(definedArtifacts.flatMap { artifact in
            [artifact.name, artifact.eventCode]
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })

        var index = 1
        while existingNames.contains("A\(index): \(baseName)") {
            index += 1
        }
        return "A\(index): \(baseName)"
    }

    private func openArtifactTemplateSheet(for signal: MFFSignalData, clickedChannel: Int) {
        guard let range = activeSelectionRange(in: signal), signal.samplingRate > 0 else {
            artifactTemplateStatusMessage = "Highlight a waveform region before defining an artifact."
            return
        }

        let defaultName = nextArtifactTemplateDefaultName()
        artifactTemplateSelectionRange = range
        artifactTemplateClickedChannel = clickedChannel
        artifactTemplateDefinedArtifactID = nil
        artifactTemplateName = defaultName
        artifactTemplateEventCode = defaultName
        artifactTemplateType = inferredArtifactType(name: defaultName, eventCode: defaultName)
        artifactTemplateChannelScope = .clickedChannel
        artifactTemplateCustomChannels = "\(clickedChannel + 1)"
        artifactTemplateWindowSeconds = max(Double(range.upperBound - range.lowerBound + 1) / signal.samplingRate, 0.02)
        artifactTemplateDownsampleRate = min(250, signal.samplingRate)
        artifactTemplateThreshold = 0.70
        artifactTemplateMergeWindowSeconds = 0.25
        artifactTemplatePolarity = .same
        artifactTemplateTopographyMode = .off
        artifactTopographyChannelScope = .allGood
        artifactTopographyMetric = .pearson
        artifactTemplateStatusMessage = nil
        artifactTemplateResult = nil
        lastArtifactScanSignature = nil
        selectedArtifactTemplateChannel = nil
        artifactDetectionMethod = .template
        showsArtifactTemplateSheet = true
    }

    private func artifactTemplateSheet(for signal: MFFSignalData) -> some View {
        let selectedChannels = artifactTemplateSelectedChannels(in: signal)
        let comparisonChannels = Array(signal.data.indices)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Define Artifact")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let range = artifactTemplateSelectionRange {
                    Text(selectionDescription(range, in: signal))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Type",
                        help: "Used by Clean Artifacts to group ocular, ECG, BCG, and other artifact definitions."
                    )
                    Picker("Type", selection: $artifactTemplateType) {
                        ForEach(DefinedArtifactType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    Color.clear
                        .frame(width: 0, height: 0)
                    Color.clear
                        .frame(width: 0, height: 0)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Name",
                        help: "A human-readable label for this artifact template. This is saved in the JSON so you can recognize the exemplar later."
                    )
                    TextField("Artifact name", text: $artifactTemplateName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Event Code",
                        help: "The event marker name inserted for each match. These generated markers appear in the Events panel and can be used by PSA artifact rejection."
                    )
                    TextField("Event code", text: $artifactTemplateEventCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Channels",
                        help: "Chooses which channels define the template score. Clicked Channel is fastest and easiest to interpret; Ocular Channels is useful for blinks; All Channels uses a weighted spatial template."
                    )
                    Picker("Channels", selection: $artifactTemplateChannelScope) {
                        ForEach(ArtifactTemplateChannelScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Specific",
                        help: "A comma- or space-separated list of 1-based channel numbers, such as 8, 25, 126. Used only when Channels is set to Specific Channels."
                    )
                    TextField("1, 8, 25", text: $artifactTemplateCustomChannels)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .disabled(artifactTemplateChannelScope != .specificChannels)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Threshold",
                        help: "Minimum normalized cross-correlation required to count a match. 70% is a permissive starting point; higher values find fewer, more template-like events."
                    )
                    HStack {
                        Slider(value: $artifactTemplateThreshold, in: 0.30...0.98, step: 0.01)
                        Text("\(Int((artifactTemplateThreshold * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Polarity",
                        help: "Controls whether matches must have the same direction as the exemplar, the opposite direction, or either direction. Either is useful when channel reference or artifact direction varies."
                    )
                    Picker("Polarity", selection: $artifactTemplatePolarity) {
                        ForEach(ArtifactTemplatePolarity.allCases) { polarity in
                            Text(polarity.rawValue).tag(polarity)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Window (s)",
                        help: "Duration of the template window centered on the highlighted exemplar. Larger windows capture more context but can make matching more specific."
                    )
                    TextField("Window", value: $artifactTemplateWindowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    ArtifactTemplateFieldLabel(
                        title: "Search Hz",
                        help: "Temporary downsample rate used while searching. Lower values are faster; 250 Hz is usually enough for slow artifacts like blinks."
                    )
                    TextField("Hz", value: $artifactTemplateDownsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Merge (s)",
                        help: "Minimum spacing between reported matches. Nearby high-scoring windows are merged so a single blink or artifact becomes one event."
                    )
                    TextField("Merge", value: $artifactTemplateMergeWindowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    ArtifactTemplateFieldLabel(
                        title: "Topography",
                        help: "Also scans for the exemplar's scalp voltage map (spatial pattern across all electrodes), independent of the per-channel waveform shape. Window Middle uses the centre sample, Window Peak the highest global field power sample, Window Average the mean map over the window. Match counts are compared against the channel scans below."
                    )
                    Picker("Topography", selection: $artifactTemplateTopographyMode) {
                        ForEach(ArtifactTopographyMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                if artifactTemplateTopographyMode.isEnabled {
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Topo Channels",
                            help: "Which channels the scalp-topography correlation uses. Bad channels are always excluded. Channel clusters (regions of interest) are coming soon."
                        )
                        HStack(spacing: 8) {
                            Picker("Topo Channels", selection: $artifactTopographyChannelScope) {
                                ForEach(ArtifactTopographyChannelScope.allCases) { scope in
                                    Text(scope.label).tag(scope)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)

                            Button("New Cluster…") {}
                                .disabled(true)
                                .help("Define reusable channel clusters (regions of interest) — coming soon.")
                        }

                        ArtifactTemplateFieldLabel(
                            title: "Fit Metric",
                            help: "Cost function for scalp-map similarity, independent of the waveform Polarity. Pearson r matches same-polarity maps; |Pearson r| also matches polarity-inverted maps; Opposite (−r) matches only the inverted map."
                        )
                        Picker("Fit Metric", selection: $artifactTopographyMetric) {
                            ForEach(ArtifactTopographyMetric.allCases) { metric in
                                Text(metric.rawValue).tag(metric)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            }

            Text("\(selectedChannels.count) selected channels · all-channel comparison enabled")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isApplyingArtifactTemplate {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning template matches...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let artifactTemplateStatusMessage {
                Text(artifactTemplateStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let artifactTemplateResult {
                artifactTemplateResultView(artifactTemplateResult)
            }

            HStack {
                Button("Save JSON…") {
                    saveArtifactTemplateJSON(artifactTemplateResult?.savedTemplate)
                }
                .disabled(artifactTemplateResult == nil)

                Spacer()

                Button("Close") {
                    showsArtifactTemplateSheet = false
                }

                Button(artifactTemplateResult == nil ? "Apply" : "Rescan") {
                    applyArtifactTemplate(to: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isApplyingArtifactTemplate
                        || artifactTemplateSelectionRange == nil
                        || selectedChannels.isEmpty
                        || comparisonChannels.isEmpty
                        || artifactTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || artifactTemplateEventCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        // Once a scan exists, only enable when settings changed.
                        || (artifactTemplateResult != nil && !artifactTemplateScanIsStale)
                )
            }
        }
        .padding(20)
        .frame(width: 700)
        .onChange(of: artifactTemplateTopographyMode) { _, _ in
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: artifactTopographyChannelScope) { _, _ in
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: artifactTopographyMetric) { _, _ in
            refreshTopographyIfNeeded(for: signal)
        }
    }

    /// Recomputes only the topography result (reference map + matches) when the
    /// reference mode or channel scope changes, but only after a full detection
    /// has already been run once. Keeps the displayed topomap in sync without a
    /// new Apply.
    private func refreshTopographyIfNeeded(for signal: MFFSignalData) {
        guard artifactTemplateResult != nil,
              let range = artifactTemplateSelectionRange else {
            return
        }

        guard artifactTemplateTopographyMode.isEnabled else {
            artifactTemplateResult?.topographyEvents = []
            artifactTemplateResult?.topographyReference = nil
            return
        }

        let configuration = artifactTemplateConfiguration(for: signal, range: range)
        topographyRefreshGeneration += 1
        let generation = topographyRefreshGeneration
        isRefreshingTopography = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                ArtifactTemplateDetector.detectTopography(in: signal, configuration: configuration)
            }.value
            // Ignore stale completions: a newer refresh has superseded this one
            // and will publish its own result (and clear the spinner).
            guard generation == topographyRefreshGeneration else { return }
            artifactTemplateResult?.topographyEvents = outcome.events
            artifactTemplateResult?.topographyReference = outcome.reference
            isRefreshingTopography = false
        }
    }

    private func artifactTemplateResultView(_ result: ArtifactTemplateDetectionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Label("\(result.selectedEvents.count) matches", systemImage: "scope")
                    .font(.caption.weight(.semibold))
                Label("+\(result.additionalComparisonCount) with all-channel model", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.additionalComparisonCount > 0 ? .orange : .secondary)
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                if let average = result.templateAverage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Average waveform")
                            .font(.caption.weight(.semibold))
                        ArtifactTemplateAveragePlot(
                            average: average,
                            primaryChannel: artifactTemplateClickedChannel,
                            highlightedChannels: Set(average.selectedChannelIndices)
                        )
                        .frame(height: 170)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let topography = result.topographyReference {
                    artifactTopographyMapView(topography)
                }
            }

            if let average = result.templateAverage {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Strongest average channels")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        ForEach(average.channelSummaries.prefix(8)) { summary in
                            Button {
                                selectArtifactTemplateChannel(summary.channelIndex)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ch \(summary.channelIndex + 1)")
                                        .font(.caption2.weight(.semibold))
                                    Text(String(format: "%.1f µV", summary.peakAbsoluteMicrovolts))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(artifactTemplateChannelChipColor(summary, average: average))
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Use Ch \(summary.channelIndex + 1) as the defining artifact channel.")
                        }
                    }
                }
            }

            if !result.scopeCounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Channel selection comparison")
                        .font(.caption.weight(.semibold))

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                        GridRow {
                            Text("Option")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Channels")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Found")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        ForEach(result.scopeCounts) { scope in
                            GridRow {
                                Text(scope.name)
                                    .font(.caption)
                                Text("\(scope.channelCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(scope.matchCount)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(scope.matchCount > result.selectedEvents.count ? .orange : .primary)
                            }
                        }

                        if let selectedArtifactTemplateChannel,
                           let matchCount = result.singleChannelMatchCounts[selectedArtifactTemplateChannel] {
                            GridRow {
                                Text("Selected Channel: Ch \(selectedArtifactTemplateChannel + 1)")
                                    .font(.caption)
                                Text("1")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(matchCount)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(matchCount > result.selectedEvents.count ? .orange : .primary)
                            }
                        }
                    }
                }
            }
            if let topography = result.topographyReference {
                Divider()
                artifactTopographyComparisonView(topography, result: result)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The template scalp map, shown beside the average waveform plot. Updates
    /// live as the reference mode / channel scope change.
    @ViewBuilder
    private func artifactTopographyMapView(_ topography: ArtifactTemplateTopography) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Scalp topography")
                    .font(.caption.weight(.semibold))
                if isRefreshingTopography {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Text(topography.mode.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let layout = recording.sensorLayout {
                TopomapView(
                    layout: layout,
                    values: topography.channelValues.map(Double.init),
                    timeSeconds: topography.referenceTimeSeconds,
                    fixedScale: nil,
                    showsHeader: false,
                    colorBarPlacement: .trailing,
                    minimumMapHeight: 150
                )
                .frame(width: 230, height: 170)
            } else {
                Text("No sensor layout — the scalp map can't be drawn, but topography matching still ran.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 230, height: 170, alignment: .topLeading)
            }
        }
    }

    /// The topography vs waveform match-count comparison and the apply button.
    @ViewBuilder
    private func artifactTopographyComparisonView(
        _ topography: ArtifactTemplateTopography,
        result: ArtifactTemplateDetectionResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Label("\(topography.matchCount) scalp-topography matches", systemImage: "circle.grid.3x3.fill")
                    .font(.caption.weight(.semibold))
                Text("\(topography.channelIndices.count) channels · \(artifactTopographyMetric.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    Text("Method").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Found").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Selected channels (waveform)").font(.caption)
                    Text("\(result.selectedEvents.count)").font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("All-channel waveform model").font(.caption)
                    Text("\(result.comparisonEvents.count)").font(.caption.monospacedDigit())
                }
                GridRow {
                    Text("Scalp topography (\(topography.mode.rawValue))").font(.caption)
                    Text("\(topography.matchCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Button("Use topography matches as events") {
                useTopographyMatches(result)
            }
            .font(.caption)
            .disabled(result.topographyEvents.isEmpty)
            .help("Replace the current artifact markers with the scalp-topography matches.")
        }
    }

    private func useTopographyMatches(_ result: ArtifactTemplateDetectionResult) {
        if let artifactID = artifactTemplateDefinedArtifactID,
           let index = definedArtifacts.firstIndex(where: { $0.id == artifactID }) {
            definedArtifacts[index].events = result.topographyEvents
            definedArtifacts[index].topography = result.topographyReference
            invalidateOBSVarianceCache(for: artifactID)
            clearAppliedArtifactCleaning()
        }
        artifactEvents = definedArtifacts.isEmpty ? result.topographyEvents : definedArtifacts.flatMap(\.events)
        selectedEventCodes = [artifactTemplateEventCode.trimmingCharacters(in: .whitespacesAndNewlines)]
        showsEventsPanel = true
        artifactStatusMessage = "\(result.topographyEvents.count) topography matches"
    }

    private func artifactTemplateChannelChipColor(
        _ summary: ArtifactTemplateChannelSummary,
        average: ArtifactTemplateAverage
    ) -> Color {
        if artifactTemplateClickedChannel == summary.channelIndex {
            return Color.blue.opacity(0.24)
        }

        if selectedArtifactTemplateChannel == summary.channelIndex {
            return Color.blue.opacity(0.18)
        }

        if average.selectedChannelIndices.contains(summary.channelIndex) {
            return Color.accentColor.opacity(0.14)
        }

        return Color.secondary.opacity(0.08)
    }

    private func selectArtifactTemplateChannel(_ channelIndex: Int) {
        artifactTemplateClickedChannel = channelIndex
        selectedArtifactTemplateChannel = channelIndex
        artifactTemplateChannelScope = .clickedChannel
        artifactTemplateCustomChannels = "\(channelIndex + 1)"
    }

    private func applyArtifactTemplate(to signal: MFFSignalData) {
        guard let range = artifactTemplateSelectionRange else {
            artifactTemplateStatusMessage = "Highlight a waveform region before applying."
            return
        }

        let selectedChannels = artifactTemplateSelectedChannels(in: signal)
        guard !selectedChannels.isEmpty else {
            artifactTemplateStatusMessage = "Choose at least one readable channel."
            return
        }

        let configuration = artifactTemplateConfiguration(for: signal, range: range)

        isApplyingArtifactTemplate = true
        artifactTemplateStatusMessage = nil

        let signature = artifactScanSignature
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ArtifactTemplateDetector.detect(in: signal, configuration: configuration)
            }.value

            artifactTemplateResult = result
            lastArtifactScanSignature = signature
            selectedArtifactTemplateChannel = nil
            upsertDefinedArtifact(from: result, configuration: configuration)
            artifactEvents = definedArtifacts.flatMap(\.events)
            selectedEventCodes = [configuration.eventCode]
            showsEventsPanel = true
            artifactStatusMessage = "\(result.selectedEvents.count) template matches"
            isApplyingArtifactTemplate = false
        }
    }

    private func upsertDefinedArtifact(
        from result: ArtifactTemplateDetectionResult,
        configuration: ArtifactTemplateConfiguration
    ) {
        let name = configuration.name.nilIfEmpty ?? "Artifact"
        let eventCode = configuration.eventCode.nilIfEmpty ?? name
        let artifact = DefinedArtifact(
            id: artifactTemplateDefinedArtifactID ?? UUID(),
            type: artifactTemplateType,
            name: name,
            eventCode: eventCode,
            events: result.selectedEvents,
            selectedChannelIndices: configuration.selectedChannelIndices,
            windowSizeSeconds: configuration.windowSizeSeconds,
            average: result.templateAverage,
            topography: result.topographyReference,
            cleaningMethod: .obs,
            appliedMethod: nil,
            cleanedAt: nil
        )

        if let index = definedArtifacts.firstIndex(where: { $0.id == artifact.id }) {
            let previousMethod = definedArtifacts[index].cleaningMethod
            let previousOBSComponentCount = definedArtifacts[index].obsPCAComponentCount
            let previousOBSEdgeTaperSeconds = definedArtifacts[index].obsEdgeTaperSeconds
            let previousOBSPreservesLocalBaseline = definedArtifacts[index].obsPreservesLocalBaseline
            let previousOBSUsesOverlapAdd = definedArtifacts[index].obsUsesOverlapAdd
            definedArtifacts[index] = artifact
            definedArtifacts[index].cleaningMethod = previousMethod
            definedArtifacts[index].obsPCAComponentCount = previousOBSComponentCount
            definedArtifacts[index].obsEdgeTaperSeconds = previousOBSEdgeTaperSeconds
            definedArtifacts[index].obsPreservesLocalBaseline = previousOBSPreservesLocalBaseline
            definedArtifacts[index].obsUsesOverlapAdd = previousOBSUsesOverlapAdd
        } else {
            definedArtifacts.append(artifact)
            registerPSADefinedArtifactForRejection(artifact.id)
        }
        invalidateOBSVarianceCache(for: artifact.id)
        artifactTemplateDefinedArtifactID = artifact.id
        clearAppliedArtifactCleaning()
    }

    private func deleteDefinedArtifact(id: DefinedArtifact.ID) {
        guard let index = definedArtifacts.firstIndex(where: { $0.id == id }) else { return }
        let name = definedArtifacts[index].name
        definedArtifacts.remove(at: index)

        if artifactTemplateDefinedArtifactID == id {
            artifactTemplateDefinedArtifactID = nil
            artifactTemplateResult = nil
            lastArtifactScanSignature = nil
            selectedArtifactTemplateChannel = nil
        }

        invalidateOBSVarianceCache(for: id)
        removePSADefinedArtifactForRejection(id)
        refreshAfterDeletingArtifacts(message: "Deleted \(name).")
    }

    private func deleteAllDefinedArtifacts() {
        guard !definedArtifacts.isEmpty else { return }
        definedArtifacts.removeAll()
        artifactTemplateDefinedArtifactID = nil
        artifactTemplateResult = nil
        lastArtifactScanSignature = nil
        selectedArtifactTemplateChannel = nil
        invalidateOBSVarianceCache()
        psaSkippedDefinedArtifactIDs.removeAll()
        psaKnownArtifactIDsForRejection.removeAll()
        refreshAfterDeletingArtifacts(message: "Deleted all defined artifacts.")
    }

    private func registerPSADefinedArtifactForRejection(_ id: DefinedArtifact.ID) {
        if psaKnownArtifactIDsForRejection.insert(id).inserted {
            psaSkippedDefinedArtifactIDs.insert(id)
        }
    }

    private func removePSADefinedArtifactForRejection(_ id: DefinedArtifact.ID) {
        psaSkippedDefinedArtifactIDs.remove(id)
        psaKnownArtifactIDsForRejection.remove(id)
    }

    private func reconcilePSADefinedArtifactRejectionSelections() {
        let currentIDs = Set(definedArtifacts.map(\.id))
        psaSkippedDefinedArtifactIDs.formIntersection(currentIDs)
        psaKnownArtifactIDsForRejection.formIntersection(currentIDs)
        for id in currentIDs where !psaKnownArtifactIDsForRejection.contains(id) {
            registerPSADefinedArtifactForRejection(id)
        }
    }

    private func invalidateOBSVarianceCache(for artifactID: DefinedArtifact.ID? = nil) {
        guard let artifactID else {
            obsVarianceReportCache.removeAll()
            return
        }
        let prefix = "\(artifactID.uuidString)|"
        obsVarianceReportCache = obsVarianceReportCache.filter { !$0.key.hasPrefix(prefix) }
    }

    private func refreshAfterDeletingArtifacts(message: String) {
        clearAppliedArtifactCleaning()
        artifactEvents = definedArtifacts.flatMap(\.events)
        artifactDetectionRefreshToken += 1
        artifactStatusMessage = definedArtifacts.isEmpty ? nil : "\(definedArtifacts.count) artifact definitions"
        artifactCleaningStatusMessage = message
    }

    private func artifactCleaningSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Clean Artifacts")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(definedArtifacts.count) defined")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if definedArtifacts.isEmpty {
                ContentUnavailableView(
                    "No Artifacts Defined",
                    systemImage: "scope",
                    description: Text("Use Define Artifact first, then return here to choose a cleanup method.")
                )
                .frame(minHeight: 220)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            Text("")
                                .frame(width: 24)
                            Text("Type")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Name")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Treatment")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                            .gridCellColumns(4)

                        ForEach($definedArtifacts) { $artifact in
                            GridRow {
                                Button {
                                    deleteDefinedArtifact(id: artifact.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(isCleaningArtifacts)
                                .help("Delete this artifact definition.")
                                .frame(width: 24)

                                Picker("Type", selection: $artifact.type) {
                                    ForEach(DefinedArtifactType.allCases) { type in
                                        Text(type.rawValue).tag(type)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artifact.name)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(artifact.eventCount) events · \(artifact.eventCode)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 210, alignment: .leading)

                                artifactTreatmentControl(
                                    artifact: $artifact,
                                    signal: signal,
                                    cleanedSignal: artifactCleanedSignal,
                                    layout: recording.sensorLayout
                                )
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 220, maxHeight: 340)
            }

            if isCleaningArtifacts {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: artifactCleaningProgress?.fraction ?? 0)
                        .progressViewStyle(.linear)
                    Text(artifactCleaningProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let artifactCleaningStatusMessage {
                Text(artifactCleaningStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button("Restore Original") {
                    restoreArtifactCleaning()
                }
                .disabled(artifactCleanedSignal == nil && definedArtifacts.allSatisfy { $0.appliedMethod == nil })

                Spacer()

                Button("Close") {
                    showsArtifactCleaningSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    applyArtifactCleaning(to: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCleaningArtifacts || !definedArtifacts.contains { $0.cleaningMethod.removesArtifact })
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(width: 800)
    }

    private func artifactTreatmentControl(
        artifact: Binding<DefinedArtifact>,
        signal: MFFSignalData,
        cleanedSignal: MFFSignalData?,
        layout: SensorLayout?
    ) -> some View {
        HStack(spacing: 8) {
            Picker("Treatment", selection: artifact.cleaningMethod) {
                ForEach(ArtifactCleaningMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .help(artifactTreatmentHelpText)

            if artifact.wrappedValue.cleaningMethod == .obs || artifact.wrappedValue.cleaningMethod == .sspPCA {
                ArtifactOBSOptionsButton(
                    artifact: artifact,
                    signal: signal,
                    reportCache: $obsVarianceReportCache,
                    onSettingsChange: clearAppliedArtifactCleaning
                )
            }

            if let appliedMethod = artifact.wrappedValue.appliedMethod {
                if appliedMethod == artifact.wrappedValue.cleaningMethod {
                    HStack(spacing: 6) {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        ArtifactCleaningPreviewButton(
                            artifact: artifact.wrappedValue,
                            beforeSignal: signal,
                            afterSignal: cleanedSignal,
                            layout: layout
                        )
                    }
                } else {
                    Text("Applied: \(appliedMethod.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    private var artifactTreatmentHelpText: String {
        """
        Do Nothing: keep the artifact definition but do not alter the data.
        Regress: subtracts the average artifact waveform; useful as a historical/simple comparison.
        OBS: subtracts the mean artifact plus residual PCA components with padded, tapered edges; good for repeated blinks, ECG, and BCG-like artifacts.
        SSP/PCA: projects out stable spatial artifact patterns across channels; useful for consistent topographies, but more global.
        """
    }

    private var artifactCleaningProgressText: String {
        guard let progress = artifactCleaningProgress else {
            return "Preparing artifact cleanup..."
        }
        let artifactPosition = progress.artifactCount > 1
            ? "\(progress.artifactIndex) of \(progress.artifactCount): "
            : ""
        let detail = progress.detail.map { " · \($0)" } ?? ""
        switch progress.phase {
        case .preparing:
            return "Setting up \(artifactPosition)\(progress.artifactName) (\(progress.artifactTotal) events) with \(progress.method.rawValue)\(detail)"
        case .cleaning:
            let current = min(progress.artifactCompleted, progress.artifactTotal)
            let overall = progress.total > progress.artifactTotal
                ? " · \(progress.completed) of \(progress.total) overall"
                : ""
            return "Cleaning \(current) of \(progress.artifactTotal) \(artifactPosition)\(progress.artifactName) events with \(progress.method.rawValue)\(overall)"
        case .finalizing:
            return "Finalizing \(artifactPosition)\(progress.artifactName) with \(progress.method.rawValue)\(detail)"
        }
    }

    private func setArtifactCleaningEnabled(_ isEnabled: Bool) {
        guard artifactCleanedSignal != nil,
              artifactCleaningIsEnabled != isEnabled else {
            return
        }
        artifactCleaningIsEnabled = isEnabled
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    private func applyArtifactCleaning(to signal: MFFSignalData) {
        let artifacts = definedArtifacts
        guard artifacts.contains(where: { $0.cleaningMethod.removesArtifact }) else {
            restoreArtifactCleaning()
            return
        }

        isCleaningArtifacts = true
        artifactCleaningStatusMessage = nil
        artifactCleaningProgress = nil
        let badChannels = channels.bad
        let (progressStream, progressContinuation) = AsyncStream<ArtifactCleaningProgress>.makeStream()
        let progressTask = Task { @MainActor in
            for await progress in progressStream {
                artifactCleaningProgress = progress
            }
        }

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                ArtifactCleaner.cleanedSignal(
                    from: signal,
                    artifacts: artifacts,
                    excluding: badChannels
                ) { progress in
                    progressContinuation.yield(progress)
                }
            }.value
            progressContinuation.finish()
            progressTask.cancel()

            artifactCleanedSignal = outcome.signal
            artifactCleaningIsEnabled = true
            artifactCleaningSummaries = outcome.summaries
            let summariesByID = Dictionary(uniqueKeysWithValues: outcome.summaries.map { ($0.artifactID, $0) })
            let now = Date()
            for index in definedArtifacts.indices {
                if summariesByID[definedArtifacts[index].id] != nil,
                   definedArtifacts[index].cleaningMethod.removesArtifact {
                    definedArtifacts[index].appliedMethod = definedArtifacts[index].cleaningMethod
                    definedArtifacts[index].cleanedAt = now
                } else {
                    definedArtifacts[index].appliedMethod = nil
                    definedArtifacts[index].cleanedAt = nil
                }
            }

            artifactCleaningStatusMessage = artifactCleaningSummaryText(outcome.summaries)
            artifactStatusMessage = artifactCleaningStatusMessage
            artifactDetectionRefreshToken += 1
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
            artifactCleaningProgress = nil
            isCleaningArtifacts = false
        }
    }

    private func artifactCleaningSummaryText(_ summaries: [ArtifactCleaningSummary]) -> String {
        guard !summaries.isEmpty else {
            return "No artifact cleanup was applied."
        }
        if summaries.count == 1, let summary = summaries.first {
            return "\(summary.method.rawValue) cleaned \(summary.name) across \(summary.channelCount) channels."
        }
        return "Cleaned \(summaries.count) artifacts."
    }

    private func restoreArtifactCleaning() {
        clearAppliedArtifactCleaning()
        artifactCleaningStatusMessage = "Artifact cleaning restored to the current uncleaned signal."
        artifactStatusMessage = artifactCleaningStatusMessage
    }

    private func clearAppliedArtifactCleaning() {
        let hadCleaning = artifactCleanedSignal != nil || definedArtifacts.contains { $0.appliedMethod != nil }
        artifactCleanedSignal = nil
        artifactCleaningIsEnabled = true
        artifactCleaningSummaries = []
        artifactCleaningProgress = nil
        artifactCleaningStatusMessage = nil
        for index in definedArtifacts.indices {
            definedArtifacts[index].appliedMethod = nil
            definedArtifacts[index].cleanedAt = nil
        }
        guard hadCleaning else { return }
        artifactDetectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    /// Current values of the scan-affecting controls.
    private var artifactScanSignature: ArtifactScanSignature {
        ArtifactScanSignature(
            eventCode: artifactTemplateEventCode,
            clickedChannel: artifactTemplateClickedChannel,
            channelScope: artifactTemplateChannelScope,
            customChannels: artifactTemplateCustomChannels,
            threshold: artifactTemplateThreshold,
            windowSeconds: artifactTemplateWindowSeconds,
            downsampleRate: artifactTemplateDownsampleRate,
            mergeWindowSeconds: artifactTemplateMergeWindowSeconds,
            polarity: artifactTemplatePolarity,
            range: artifactTemplateSelectionRange
        )
    }

    /// True when settings have changed since the displayed result was produced
    /// (or no scan has run yet).
    private var artifactTemplateScanIsStale: Bool {
        lastArtifactScanSignature != artifactScanSignature
    }

    /// Builds the detector configuration from the current sheet controls.
    private func artifactTemplateConfiguration(
        for signal: MFFSignalData,
        range: ClosedRange<Int>
    ) -> ArtifactTemplateConfiguration {
        ArtifactTemplateConfiguration(
            name: artifactTemplateName.trimmingCharacters(in: .whitespacesAndNewlines),
            eventCode: artifactTemplateEventCode.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedChannelIndices: artifactTemplateSelectedChannels(in: signal),
            comparisonChannelIndices: Array(signal.data.indices),
            exemplarRange: range,
            matchThreshold: artifactTemplateThreshold,
            windowSizeSeconds: max(artifactTemplateWindowSeconds, 0.01),
            downsampleRate: min(max(artifactTemplateDownsampleRate, 20), signal.samplingRate),
            mergeWindowSeconds: max(artifactTemplateMergeWindowSeconds, 0.01),
            polarity: artifactTemplatePolarity,
            comparisonScopes: artifactTemplateComparisonScopes(in: signal),
            topographyMode: artifactTemplateTopographyMode,
            topographyChannelIndices: artifactTopographyChannels(in: signal),
            topographyMetric: artifactTopographyMetric
        )
    }

    /// Channels used for the scalp-topography correlation: all readable channels
    /// minus bad channels (and, in future, restricted to a selected cluster).
    private func artifactTopographyChannels(in signal: MFFSignalData) -> [Int] {
        switch artifactTopographyChannelScope {
        case .allGood:
            return signal.data.indices.filter { !channels.bad.contains($0) }
        }
    }

    private func artifactTemplateSelectedChannels(in signal: MFFSignalData) -> [Int] {
        switch artifactTemplateChannelScope {
        case .clickedChannel:
            if let artifactTemplateClickedChannel, signal.data.indices.contains(artifactTemplateClickedChannel) {
                return [artifactTemplateClickedChannel]
            }
            return []
        case .ocularChannels:
            return ocularTemplateChannels(channelCount: signal.numberOfChannels)
        case .visibleChannels:
            return signal.data.indices.filter { !channels.hidden.contains($0) }
        case .allChannels:
            return Array(signal.data.indices)
        case .specificChannels:
            return parseChannelList(artifactTemplateCustomChannels, channelCount: signal.numberOfChannels)
        }
    }

    private func artifactTemplateComparisonScopes(in signal: MFFSignalData) -> [ArtifactTemplateComparisonScope] {
        var scopes: [ArtifactTemplateComparisonScope] = [
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.clickedChannel.rawValue,
                channelIndices: artifactTemplateClickedChannel.map { [$0] } ?? []
            ),
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.ocularChannels.rawValue,
                channelIndices: ocularTemplateChannels(channelCount: signal.numberOfChannels)
            ),
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.visibleChannels.rawValue,
                channelIndices: signal.data.indices.filter { !channels.hidden.contains($0) }
            ),
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.allChannels.rawValue,
                channelIndices: Array(signal.data.indices)
            )
        ]

        let specificChannels = parseChannelList(artifactTemplateCustomChannels, channelCount: signal.numberOfChannels)
        if !specificChannels.isEmpty {
            scopes.append(
                ArtifactTemplateComparisonScope(
                    name: ArtifactTemplateChannelScope.specificChannels.rawValue,
                    channelIndices: specificChannels
                )
            )
        }

        var seen = Set<String>()
        return scopes.filter { scope in
            let key = scope.channelIndices.sorted().map(String.init).joined(separator: ",")
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func ocularTemplateChannels(channelCount: Int) -> [Int] {
        let oneBasedChannels: [Int]
        switch channelCount {
        case 241...:
            oneBasedChannels = [18, 37, 238, 241]
        case 127...:
            oneBasedChannels = [8, 25, 126, 127]
        default:
            oneBasedChannels = Array(1...min(channelCount, 4))
        }
        return oneBasedChannels.map { $0 - 1 }.filter { $0 >= 0 && $0 < channelCount }
    }

    private func parseChannelList(_ text: String, channelCount: Int) -> [Int] {
        let separators = CharacterSet(charactersIn: ",; ").union(.newlines)
        return Array(Set(text.components(separatedBy: separators).compactMap { token in
            guard let oneBased = Int(token.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            let zeroBased = oneBased - 1
            return zeroBased >= 0 && zeroBased < channelCount ? zeroBased : nil
        })).sorted()
    }

    private func saveArtifactTemplateJSON(_ template: SavedArtifactTemplate?) {
        guard let template else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(template.name.replacingOccurrences(of: " ", with: "-")).artifact.json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(template)
            try data.write(to: url, options: .atomic)
            artifactTemplateStatusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            artifactTemplateStatusMessage = error.localizedDescription
        }
    }

    // MARK: - ICA artifact exploration

    private func openICASheet(for signal: MFFSignalData) {
        icaComponentCount = min(max(icaComponentCount, 1), signal.numberOfChannels)
        icaDownsampleRate = min(icaDownsampleRate, signal.samplingRate)
        icaStatusMessage = nil
        artifactDetectionMethod = .ica
        showsICASheet = true
    }

    private func icaSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("ICA Artifact Components")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let icaDecomposition {
                    Text("\(icaDecomposition.componentCount) components · \(Int(icaDecomposition.analysisSamplingRate)) Hz")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Method",
                        help: "Picard (recommended) is a preconditioned ICA that converges in a few iterations. FastICA is a fast symmetric fixed-point solver. Infomax is the slower MNE/EEGLAB extended-infomax kept for reference."
                    )
                    Picker("Method", selection: $icaMethod) {
                        ForEach(ICAMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .gridCellColumns(4)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Components",
                        help: "Maximum number of PCA/ICA components to estimate. The variance setting may choose fewer components to avoid whitening tiny noisy directions."
                    )
                    TextField("Components", value: $icaComponentCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Search Hz",
                        help: "Temporary downsample rate used only for fitting and previewing ICA — the selected components are still removed from the full-rate EEG afterward. This auto-scales to the fit filter: by Nyquist the rate only needs to be just above twice the highest frequency the filter keeps (≈2× the high cutoff, or 2× 60 Hz when the notch is on), so it can be far lower than the recording rate, which is what makes the fit fast. You can always set it higher."
                    )
                    TextField("Hz", value: $icaDownsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Iterations",
                        help: "Maximum solver iterations. Picard and FastICA typically converge in well under this; it acts mainly as a safety cap. Infomax may use more."
                    )
                    TextField("Iterations", value: $icaMaxIterations, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Keep Var",
                        help: "PCA variance target used to choose how many components to keep, capped by the Components field. 99% is a practical default for avoiding near-zero variance components."
                    )
                    TextField("Fraction", value: $icaVarianceThreshold, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Avg Ref",
                        help: "Subtracts the instantaneous average across channels before ICA fitting. This removes common-mode reference structure that can dominate the first PCA direction."
                    )
                    Toggle("Use", isOn: $icaUsesAverageReference)
                        .toggleStyle(.checkbox)

                    Text("Components are capped after PCA screening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Fit Filter",
                        help: "Recommended for ICA: fit components on a filtered copy of the data. A 1 Hz high-pass is commonly used so slow drift does not dominate the decomposition."
                    )
                    Toggle("Use", isOn: $icaUsesFitFilter)
                        .toggleStyle(.checkbox)

                    ArtifactTemplateFieldLabel(
                        title: "Fit Hz",
                        help: "Band-pass range used only for fitting ICA. The selected components are still removed from the full-rate EEG after review."
                    )
                    HStack(spacing: 6) {
                        TextField("Low", value: $icaFitLowCutoff, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                        Text("–")
                            .foregroundStyle(.secondary)
                        TextField("High", value: $icaFitHighCutoff, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                    }
                    .disabled(!icaUsesFitFilter)

                    Toggle("60 Hz notch", isOn: $icaFitNotch60HzEnabled)
                        .toggleStyle(.checkbox)
                        .disabled(!icaUsesFitFilter)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Tolerance",
                        help: "MNE-style early stopping threshold for summed squared ICA weight change between iterations. Smaller values may run longer."
                    )
                    TextField("Tolerance", value: $icaConvergenceTolerance, format: .number.precision(.significantDigits(2...4)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Min Iter",
                        help: "Minimum number of infomax iterations before tolerance-based early stopping is allowed."
                    )
                    TextField("Min", value: $icaMinimumIterations, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    Text("Stops when weights stabilize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Run ICA") {
                    runICA(on: signal)
                }
                .disabled(isRunningICA)

                if isRunningICA {
                    ProgressView(value: icaProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                    Text("\(Int((icaProgress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(icaProgressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                }

                if let icaDecomposition, !icaDecomposition.excludedComponents.isEmpty {
                    Button("Remove Selected Components") {
                        removeSelectedICAComponents(from: signal)
                    }
                    .disabled(isRemovingICAComponents)

                    Button("Save JSON…") {
                        saveICAJSON(icaDecomposition)
                    }
                }

                if isRemovingICAComponents {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reconstructing EEG")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") {
                    showsICASheet = false
                }
            }

            if let icaStatusMessage {
                Text(icaStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let icaDecomposition {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(0..<icaDecomposition.componentCount, id: \.self) { component in
                            icaComponentCard(component, signal: signal)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 520)
            } else {
                ContentUnavailableView(
                    "No ICA Yet",
                    systemImage: "square.grid.3x3",
                    description: Text("Run ICA to inspect component topographies and time courses.")
                )
                .frame(height: 260)
            }
        }
        .padding(20)
        .frame(width: 980, height: 760)
        .onAppear { autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
        .onChange(of: icaUsesFitFilter) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
        .onChange(of: icaFitNotch60HzEnabled) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
        .onChange(of: icaFitHighCutoff) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
    }

    /// Recommended ICA fit/analysis rate. By Nyquist the rate only needs to be
    /// a little above twice the highest frequency the fit filter preserves, so
    /// it can be far below the recording rate — which is what keeps the fit fast.
    private func recommendedICAAnalysisRate(samplingRate: Double) -> Double {
        let highCutoff = icaUsesFitFilter ? icaFitHighCutoff : 40.0
        let notchFrequency = (icaUsesFitFilter && icaFitNotch60HzEnabled) ? 60.0 : 0.0
        let maxFrequency = max(highCutoff, notchFrequency)
        // 20% headroom above the Nyquist minimum, rounded up to a tidy 10 Hz step.
        let raw = max(2.4 * maxFrequency, 100.0)
        let rounded = (raw / 10).rounded(.up) * 10
        return min(rounded, samplingRate)
    }

    private func autoScaleICAAnalysisRate(samplingRate: Double) {
        guard samplingRate > 0 else { return }
        icaDownsampleRate = recommendedICAAnalysisRate(samplingRate: samplingRate)
    }

    private func icaComponentCard(_ component: Int, signal: MFFSignalData) -> some View {
        let isExcluded = icaDecomposition?.excludedComponents.contains(component) == true
        let label = Binding<String>(
            get: { icaDecomposition?.labels[component] ?? "" },
            set: { newValue in icaDecomposition?.labels[component] = newValue }
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: icaComponentExcludedBinding(component)) {
                    Text("IC \(component + 1)")
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                Text(icaExplainedVarianceText(component))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let layout = recording.sensorLayout,
               let values = icaDecomposition?.componentMaps[safe: component] {
                let displayValues = normalizedTopography(values)
                TopomapView(
                    layout: layout,
                    values: displayValues,
                    timeSeconds: 0,
                    fixedScale: 1,
                    unitLabel: "a.u.",
                    showsHeader: false,
                    colorBarPlacement: .trailing,
                    minimumMapHeight: 178
                )
                .frame(height: 210)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 230)
                    .overlay {
                        Text("No layout")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }

            if let decomposition = icaDecomposition,
               let source = decomposition.componentSources[safe: component] {
                ICATimeCoursePreview(
                    samples: source,
                    visibleRange: icaVisibleSourceRange(for: decomposition, in: signal)
                )
            }

            TextField("Label", text: label)
                .textFieldStyle(.roundedBorder)
                .disabled(!isExcluded)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isExcluded ? Color.red.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isExcluded ? Color.red.opacity(0.35) : Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .help(icaDecomposition?.labelSuggestions[component]?.reason ?? "Select components that look like eye, muscle, cardiac, or movement artifacts. Labels are saved with the JSON artifact set.")
    }

    private func icaComponentExcludedBinding(_ component: Int) -> Binding<Bool> {
        Binding(
            get: { icaDecomposition?.excludedComponents.contains(component) == true },
            set: { isSelected in
                if isSelected {
                    icaDecomposition?.excludedComponents.insert(component)
                    if icaDecomposition?.labels[component]?.isEmpty != false {
                        icaDecomposition?.labels[component] = "Artifact"
                    }
                } else {
                    icaDecomposition?.excludedComponents.remove(component)
                }
            }
        )
    }

    private func icaExplainedVarianceText(_ component: Int) -> String {
        guard let value = icaDecomposition?.explainedVariance[safe: component],
              let total = icaDecomposition?.explainedVariance.reduce(0, +),
              total > 0 else {
            return ""
        }
        return String(format: "%.1f%%", (value / total) * 100)
    }

    private func icaVisibleSourceRange(for decomposition: ICADecomposition, in signal: MFFSignalData) -> ClosedRange<Int>? {
        guard decomposition.sampleCount > 1 else { return nil }

        let lowerSample = sampleIndex(forContentX: horizontalOffset, in: signal)
        let upperSample = sampleIndex(forContentX: horizontalOffset + horizontalViewportWidth, in: signal)
        let lowerSource = min(max(lowerSample / max(decomposition.decimation, 1), 0), decomposition.sampleCount - 1)
        let upperSource = min(max(upperSample / max(decomposition.decimation, 1), lowerSource + 1), decomposition.sampleCount - 1)
        return lowerSource...upperSource
    }

    private func runICA(on signal: MFFSignalData) {
        isRunningICA = true
        icaProgress = 0
        icaProgressMessage = "Preparing ICA..."
        icaStatusMessage = nil

        let fitLowCutoff = max(icaFitLowCutoff, 0.1)
        let fitHighCutoff = min(max(icaFitHighCutoff, 0.2), signal.samplingRate / 2 - 0.1)
        if icaUsesFitFilter, fitHighCutoff <= fitLowCutoff {
            isRunningICA = false
            icaStatusMessage = "ICA fit filter needs a high cutoff above the low cutoff."
            return
        }

        let configuration = ICAConfiguration(
            method: icaMethod,
            componentCount: min(max(icaComponentCount, 1), signal.numberOfChannels),
            varianceThreshold: min(max(icaVarianceThreshold, 0.01), 1.0),
            averageReference: icaUsesAverageReference,
            downsampleRate: min(max(icaDownsampleRate, 20), signal.samplingRate),
            maxIterations: max(icaMaxIterations, 1),
            learningRate: nil,
            fitFilter: icaUsesFitFilter ? ICAFitFilterSettings(
                lowCutoff: fitLowCutoff,
                highCutoff: fitHighCutoff,
                notch60HzEnabled: icaFitNotch60HzEnabled
            ) : nil,
            convergenceTolerance: max(icaConvergenceTolerance, 0),
            minimumIterations: min(max(icaMinimumIterations, 0), max(icaMaxIterations, 1))
        )

        let (progressStream, progressContinuation) = AsyncStream<ICAProgressUpdate>.makeStream()
        let progressTask = Task { @MainActor in
            for await update in progressStream {
                icaProgress = min(max(update.fraction, 0), 1)
                icaProgressMessage = update.message
            }
        }

        Task {
            do {
                let decomposition = try await Task.detached(priority: .userInitiated) {
                    let fitSignal: MFFSignalData
                    if let fitFilter = configuration.fitFilter {
                        let filteredData = try await EEGSignalFilter.bandPass(
                            channels: signal.data,
                            samplingRate: signal.samplingRate,
                            lowCutoff: fitFilter.lowCutoff,
                            highCutoff: fitFilter.highCutoff,
                            notch60HzEnabled: fitFilter.notch60HzEnabled,
                            progress: { fraction in
                                progressContinuation.yield(
                                    ICAProgressUpdate(
                                        fraction: 0.25 * fraction,
                                        message: "Filtering ICA fit copy"
                                    )
                                )
                            }
                        )
                        fitSignal = MFFSignalData(
                            signalURL: signal.signalURL,
                            signalType: "\(signal.signalType) ICA Fit Filtered",
                            numberOfChannels: signal.numberOfChannels,
                            samplingRate: signal.samplingRate,
                            duration: signal.duration,
                            recordingStartTime: signal.recordingStartTime,
                            events: signal.events,
                            data: filteredData,
                            channelNames: signal.channelNames
                        )
                    } else {
                        fitSignal = signal
                    }

                    return try ICAArtifactDetector.fit(
                        signal: fitSignal,
                        configuration: configuration,
                        progress: { fraction in
                            let scaled = configuration.fitFilter == nil ? fraction : 0.25 + 0.75 * fraction
                            progressContinuation.yield(
                                ICAProgressUpdate(
                                    fraction: scaled,
                                    message: icaProgressMessage(for: fraction)
                                )
                            )
                        }
                    )
                }.value
                progressContinuation.finish()
                progressTask.cancel()
                icaProgress = 1
                icaProgressMessage = "ICA complete"
                var labeledDecomposition = decomposition
                let suggestions = ICAComponentAutoLabeler.suggestions(
                    for: decomposition,
                    layout: recording.sensorLayout
                )
                labeledDecomposition.labelSuggestions = suggestions
                for (component, suggestion) in suggestions {
                    labeledDecomposition.labels[component] = suggestion.label
                }
                icaDecomposition = labeledDecomposition
                if decomposition.finalChange.isFinite,
                   decomposition.iterations >= configuration.maxIterations,
                   decomposition.finalChange > configuration.convergenceTolerance {
                    icaStatusMessage = String(
                        format: "ICA stopped at %d iterations. Auto-labeled %d components. Final change %.2g; try more iterations or fewer components.",
                        decomposition.iterations,
                        suggestions.count,
                        decomposition.finalChange
                    )
                } else if decomposition.finalChange.isFinite {
                    icaStatusMessage = String(
                        format: "ICA finished in %d iterations. Auto-labeled %d components. Final change %.2g.",
                        decomposition.iterations,
                        suggestions.count,
                        decomposition.finalChange
                    )
                } else {
                    icaStatusMessage = "ICA finished in \(decomposition.iterations) iterations after learning-rate backoff."
                }
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                icaStatusMessage = error.localizedDescription
                icaProgressMessage = "ICA failed"
            }
            isRunningICA = false
        }
    }

    private nonisolated func icaProgressMessage(for detectorFraction: Double) -> String {
        switch detectorFraction {
        case ..<0.08:
            return "Downsampling ICA data"
        case ..<0.16:
            return "Centering channels"
        case ..<0.30:
            return "Building covariance"
        case ..<0.40:
            return "Solving PCA whitening"
        case ..<0.48:
            return "Whitening data"
        case ..<0.88:
            return "Rotating ICA weights"
        default:
            return "Preparing component maps"
        }
    }

    private func removeSelectedICAComponents(from signal: MFFSignalData) {
        guard let decomposition = icaDecomposition,
              !decomposition.excludedComponents.isEmpty else {
            icaStatusMessage = "Select at least one component to remove."
            return
        }

        let excludedComponents = decomposition.excludedComponents
        let shouldRestoreFilter = filteredSignal != nil
        let beforeDisplaySignal = filteredSignal ?? signal
        let restoredFilterLowCutoff = filterLowCutoff
        let restoredFilterHighCutoff = filterHighCutoff
        let restoredNotch60HzEnabled = notch60HzEnabled
        let restoredAmplitudeScale = amplitudeScale
        let restoredTimeScale = timeScale
        let restoredScrollPosition = horizontalScrollPosition
        isRemovingICAComponents = true
        lastICAReconstructionDebugReport = """
        ## Last ICA Removal
        Status: reconstruction in progress
        Excluded components: \(excludedComponents.sorted().map { "IC \($0 + 1) \(decomposition.labels[$0] ?? "")" }.joined(separator: ", ").nilIfEmpty ?? "none")
        Before display signal type: \(beforeDisplaySignal.signalType)
        \(debugStatsLine("Before display full", signal: beforeDisplaySignal))
        """
        icaStatusMessage = "Reconstructing EEG..."

        Task {
            var reconstructionActivationSignal: MFFSignalData?
            if let fitFilter = decomposition.fitFilter {
                do {
                    icaStatusMessage = "Filtering ICA activation copy..."
                    let activationData = try await EEGSignalFilter.bandPass(
                        channels: signal.data,
                        samplingRate: signal.samplingRate,
                        lowCutoff: fitFilter.lowCutoff,
                        highCutoff: fitFilter.highCutoff,
                        notch60HzEnabled: fitFilter.notch60HzEnabled
                    )

                    reconstructionActivationSignal = MFFSignalData(
                        signalURL: signal.signalURL,
                        signalType: "\(signal.signalType) ICA Activation Filtered",
                        numberOfChannels: signal.numberOfChannels,
                        samplingRate: signal.samplingRate,
                        duration: signal.duration,
                        recordingStartTime: signal.recordingStartTime,
                        events: signal.events,
                        data: activationData,
                        channelNames: signal.channelNames
                    )
                } catch {
                    filterStatusMessage = error.localizedDescription
                }
            }

            icaStatusMessage = "Reconstructing EEG..."
            let cleaned = await Task.detached(priority: .userInitiated) {
                ICAArtifactDetector.cleanedSignal(
                    from: signal,
                    activationSignal: reconstructionActivationSignal,
                    decomposition: decomposition,
                    excluding: excludedComponents
                )
            }.value

            var restoredFilteredSignal: MFFSignalData?
            if shouldRestoreFilter {
                do {
                    let filteredData = try await Task.detached(priority: .userInitiated) {
                        try await EEGSignalFilter.bandPass(
                            channels: cleaned.data,
                            samplingRate: cleaned.samplingRate,
                            lowCutoff: restoredFilterLowCutoff,
                            highCutoff: restoredFilterHighCutoff,
                            notch60HzEnabled: restoredNotch60HzEnabled
                        )
                    }.value

                    restoredFilteredSignal = MFFSignalData(
                        signalURL: cleaned.signalURL,
                        signalType: cleaned.signalType,
                        numberOfChannels: cleaned.numberOfChannels,
                        samplingRate: cleaned.samplingRate,
                        duration: cleaned.duration,
                        recordingStartTime: cleaned.recordingStartTime,
                        events: cleaned.events,
                        data: filteredData,
                        channelNames: cleaned.channelNames
                    )
                } catch {
                    filterStatusMessage = error.localizedDescription
                }
            }

            icaCleanedSignal = cleaned
            filteredSignal = restoredFilteredSignal
            clearAppliedArtifactCleaning()
            lastICAReconstructionDebugReport = icaReconstructionDebugReport(
                beforeBase: signal,
                beforeDisplay: beforeDisplaySignal,
                activationSignal: reconstructionActivationSignal,
                afterBase: cleaned,
                afterDisplay: restoredFilteredSignal ?? cleaned,
                decomposition: decomposition,
                excludedComponents: excludedComponents
            )
            filterLowCutoff = restoredFilterLowCutoff
            filterHighCutoff = restoredFilterHighCutoff
            notch60HzEnabled = restoredNotch60HzEnabled
            amplitudeScale = restoredAmplitudeScale
            timeScale = restoredTimeScale
            horizontalScrollPosition = restoredScrollPosition
            artifactEvents = []
            artifactStatusMessage = "Removed \(excludedComponents.count) ICA components."
            artifactDetectionRefreshToken += 1
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
            isRemovingICAComponents = false
            showsICASheet = false
        }
    }

    private func saveICAJSON(_ decomposition: ICADecomposition?) {
        guard let decomposition else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ica-artifacts.json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(ICAArtifactDetector.savedArtifactSet(from: decomposition))
            try data.write(to: url, options: .atomic)
            icaStatusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            icaStatusMessage = error.localizedDescription
        }
    }

    // MARK: - ICA debug report

    private func copyICADebugReportToPasteboard() {
        guard let rawSignal = recording.signal else {
            icaStatusMessage = "No recording is loaded."
            return
        }

        icaDebugReportSerial += 1
        let report = icaDebugReport(rawSignal: rawSignal)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        icaStatusMessage = "ICA debug report \(icaDebugReportSerial) copied to clipboard."
    }

    private func icaDebugReport(rawSignal: MFFSignalData) -> String {
        let base = icaCleanedSignal ?? gradientCorrectedSignal ?? rawSignal
        let processed = filteredSignal ?? base
        let visibleRange = visibleSampleRange(in: processed)

        var lines: [String] = [
            "# ICA Debug Report",
            "Report serial: \(icaDebugReportSerial)",
            "Recording: \(recording.packageName)",
            "Created: \(Date().formatted(date: .abbreviated, time: .standard))",
            "",
            "## View State",
            "Amplitude scale: \(Int(amplitudeScale)) uV",
            "Time scale: \(String(format: "%.1f", timeScale))x",
            "Horizontal offset: \(String(format: "%.1f", Double(horizontalOffset))) px",
            "Viewport width: \(String(format: "%.1f", Double(horizontalViewportWidth))) px",
            "Visible samples: \(visibleRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "unavailable")",
            "MRI correction active: \(gradientCorrectedSignal == nil ? "no" : "yes")",
            "ICA cleaned active: \(icaCleanedSignal == nil ? "no" : "yes")",
            "ICA removal in progress: \(isRemovingICAComponents ? "yes" : "no")",
            "Filter active: \(filteredSignal == nil ? "no" : "yes")",
            "Filter settings: \(String(format: "%.2f", filterLowCutoff))-\(String(format: "%.2f", filterHighCutoff)) Hz, notch \(notch60HzEnabled ? "on" : "off")",
            "Interpolated channels: \(channels.interpolated.keys.sorted().map { "\($0 + 1)" }.joined(separator: ", ").nilIfEmpty ?? "none")",
            "Bad channels: \(channels.bad.sorted().map { "\($0 + 1)" }.joined(separator: ", ").nilIfEmpty ?? "none")",
            "Hidden channels: \(channels.hidden.sorted().map { "\($0 + 1)" }.joined(separator: ", ").nilIfEmpty ?? "none")",
            "",
            "## ICA Settings",
            "Method field: \(icaMethod.displayName)",
            "Components field: \(icaComponentCount)",
            "Keep variance field: \(String(format: "%.2f", icaVarianceThreshold))",
            "Average reference field: \(icaUsesAverageReference ? "on" : "off")",
            "Search Hz field: \(String(format: "%.1f", icaDownsampleRate))",
            "Iterations field: \(icaMaxIterations)",
            "Fit filter field: \(icaUsesFitFilter ? "on" : "off")",
            "Fit Hz field: \(String(format: "%.2f", icaFitLowCutoff))-\(String(format: "%.2f", icaFitHighCutoff)), notch \(icaFitNotch60HzEnabled ? "on" : "off")",
            "Tolerance field: \(icaConvergenceTolerance)",
            "Minimum iterations field: \(icaMinimumIterations)"
        ]

        if let decomposition = icaDecomposition {
            lines += [
                "",
                "## ICA Decomposition",
                "Components: \(decomposition.componentCount)",
                "Source sampling rate: \(String(format: "%.1f", decomposition.sourceSamplingRate)) Hz",
                "Analysis sampling rate: \(String(format: "%.1f", decomposition.analysisSamplingRate)) Hz",
                "Decimation: \(decomposition.decimation)",
                "Iterations: \(decomposition.iterations)",
                "Final change: \(decomposition.finalChange)",
                "Converged by tolerance: \(decomposition.finalChange.isFinite && decomposition.finalChange <= decomposition.convergenceTolerance ? "yes" : "no")",
                "Average reference: \(decomposition.averageReference ? "yes" : "no")",
                "PCA variance target: \(String(format: "%.2f", decomposition.varianceThreshold))",
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

        if let gradientCorrectedSignal {
            lines.append(debugStatsLine("MRI-corrected full", signal: gradientCorrectedSignal))
        }
        if let icaCleanedSignal {
            lines.append(debugStatsLine("ICA-cleaned full", signal: icaCleanedSignal))
        }
        if let filteredSignal {
            lines.append(debugStatsLine("Filtered full", signal: filteredSignal))
        }
        if let visibleRange {
            lines += [
                "",
                "## Visible Window Stats",
                debugStatsLine("Raw visible", signal: rawSignal, sampleRange: clippedSampleRange(visibleRange, in: rawSignal)),
                debugStatsLine("Processed visible", signal: processed, sampleRange: clippedSampleRange(visibleRange, in: processed))
            ]
            if let icaCleanedSignal {
                lines.append(debugStatsLine("ICA-cleaned visible", signal: icaCleanedSignal, sampleRange: clippedSampleRange(visibleRange, in: icaCleanedSignal)))
            }
            if let filteredSignal {
                lines.append(debugStatsLine("Filtered visible", signal: filteredSignal, sampleRange: clippedSampleRange(visibleRange, in: filteredSignal)))
            }
        }

        if let lastICAReconstructionDebugReport {
            lines += ["", lastICAReconstructionDebugReport]
        } else {
            lines += ["", "## Last ICA Removal", "No ICA component removal has been recorded in this window yet."]
        }

        return lines.joined(separator: "\n")
    }

    private func icaReconstructionDebugReport(
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

    private func visibleSampleRange(in signal: MFFSignalData) -> ClosedRange<Int>? {
        guard horizontalViewportWidth > 1, signal.data.first?.isEmpty == false else { return nil }
        let lower = sampleIndex(forContentX: horizontalOffset, in: signal)
        let upper = sampleIndex(forContentX: horizontalOffset + horizontalViewportWidth, in: signal)
        return min(lower, upper)...max(lower, upper)
    }

    private func clippedSampleRange(_ range: ClosedRange<Int>, in signal: MFFSignalData) -> ClosedRange<Int>? {
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return nil }
        let lower = min(max(range.lowerBound, 0), sampleCount - 1)
        let upper = min(max(range.upperBound, lower), sampleCount - 1)
        return lower...upper
    }

    private func debugStatsLine(_ label: String, signal: MFFSignalData, sampleRange: ClosedRange<Int>? = nil) -> String {
        let stats = debugSignalStats(signal, sampleRange: sampleRange)
        return "\(label): \(stats.summary)"
    }

    private func debugSignalStats(_ signal: MFFSignalData, sampleRange: ClosedRange<Int>? = nil) -> ICADebugSignalStats {
        ICADebugSignalStats.make(signal: signal, sampleRange: sampleRange)
    }

    // MARK: - PSA epoching

    private func openPSASheet(for signal: MFFSignalData) {
        reconcilePSADefinedArtifactRejectionSelections()
        let events = segmentableEvents(for: signal)
        let summaries = groupedEventSummaries(events)
        let availableCodes = Set(summaries.map(\.code))
        psaSelectedEventCodes = psaSelectedEventCodes.intersection(availableCodes)
        for summary in summaries where psaCategoryNames[summary.code] == nil {
            psaCategoryNames[summary.code] = summary.code
        }
        psaStatusMessage = nil
        showsPSASheet = true
    }

    private func segmentableEvents(for signal: MFFSignalData) -> [MFFEvent] {
        (signal.events + userMarkerEvents).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    private func psaSheet(for signal: MFFSignalData) -> some View {
        let events = segmentableEvents(for: signal)
        let summaries = groupedEventSummaries(events)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("PSA Segmentation")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(events.count) available events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Segment On")
                    .font(.caption.weight(.semibold))

                if summaries.isEmpty {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "list.bullet.rectangle",
                        description: Text("This recording has no events to segment on.")
                    )
                    .frame(height: 120)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(summaries) { summary in
                                HStack(spacing: 12) {
                                    Toggle(isOn: psaEventCodeBinding(summary.code)) {
                                        Text(summary.code)
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    .frame(width: 150, alignment: .leading)

                                    Text("\(summary.count)")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .frame(width: 44, alignment: .trailing)

                                    TextField("Category", text: psaCategoryBinding(summary.code))
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(!psaSelectedEventCodes.contains(summary.code))
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(height: 160)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Pre-stimulus (s)")
                        .font(.caption.weight(.semibold))
                    TextField("Pre", value: $psaPreStimulus, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    Text("Post-stimulus (s)")
                        .font(.caption.weight(.semibold))
                    TextField("Post", value: $psaPostStimulus, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                GridRow {
                    Text("Offset (s)")
                        .font(.caption.weight(.semibold))
                    TextField("Offset", value: $psaOffset, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Skip if contains artifact", isOn: $psaSkipIfContainsArtifact)
                VStack(alignment: .leading, spacing: 7) {
                    psaArtifactRejectionRow(
                        title: "Eye Blink",
                        detail: "Default detector",
                        isOn: $psaSkipEyeBlinks,
                        help: "Rejects epochs containing default eye blink artifact events."
                    )
                    psaArtifactRejectionRow(
                        title: "Eye Movement",
                        detail: "Default detector",
                        isOn: $psaSkipEyeMovements,
                        help: "Rejects epochs containing default eye movement artifact events."
                    )
                    if !definedArtifacts.isEmpty {
                        Divider()
                            .padding(.vertical, 2)
                        ForEach(definedArtifacts) { artifact in
                            psaArtifactRejectionRow(
                                title: artifact.name,
                                detail: "\(artifact.events.count) events · \(artifact.type.rawValue)",
                                isOn: psaDefinedArtifactBinding(artifact.id),
                                help: "Rejects epochs containing events from this defined artifact."
                            )
                        }
                    }
                }
                .disabled(!psaSkipIfContainsArtifact)
                .padding(.leading, 18)
                Toggle("Average by category", isOn: $psaAverageOnApply)
                Toggle("Average reference", isOn: $psaAverageReference)
                    .help("Re-reference to the common average of the good channels (excludes bad channels, uses interpolated values).")
                Toggle("Baseline correct (pre-stimulus)", isOn: $psaBaselineCorrected)
                    .help("Subtract each epoch's mean over the pre-stimulus interval from the whole epoch.")
            }

            if let psaStatusMessage {
                Text(psaStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showsPSASheet = false
                }
                Button("Apply") {
                    applyPSA(to: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApplyPSA(events: events))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func psaArtifactRejectionRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        help: String
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(help)
    }

    private func psaDefinedArtifactBinding(_ id: DefinedArtifact.ID) -> Binding<Bool> {
        Binding(
            get: { psaSkippedDefinedArtifactIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    psaSkippedDefinedArtifactIDs.insert(id)
                    psaKnownArtifactIDsForRejection.insert(id)
                } else {
                    psaSkippedDefinedArtifactIDs.remove(id)
                    psaKnownArtifactIDsForRejection.insert(id)
                }
            }
        )
    }

    private func psaEventCodeBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { psaSelectedEventCodes.contains(code) },
            set: { isSelected in
                if isSelected {
                    psaSelectedEventCodes.insert(code)
                    if psaCategoryNames[code]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        psaCategoryNames[code] = code
                    }
                } else {
                    psaSelectedEventCodes.remove(code)
                }
            }
        )
    }

    private func psaCategoryBinding(_ code: String) -> Binding<String> {
        Binding(
            get: { psaCategoryNames[code] ?? code },
            set: { psaCategoryNames[code] = $0 }
        )
    }

    private func canApplyPSA(events: [MFFEvent]) -> Bool {
        !events.isEmpty
            && !psaSelectedEventCodes.isEmpty
            && psaPreStimulus >= 0
            && psaPostStimulus > 0
            && selectedPSACategoriesByCode() != nil
    }

    private func selectedPSACategoriesByCode() -> [String: String]? {
        var categoriesByCode = [String: String]()
        for code in psaSelectedEventCodes {
            let category = (psaCategoryNames[code] ?? code).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { return nil }
            categoriesByCode[code] = category
        }
        return categoriesByCode
    }

    private func applyPSA(to signal: MFFSignalData) {
        let result = buildEpochs(from: signal)
        guard let result else { return }

        // Keep the raw (un-baselined) epochs as the source so baseline correction
        // can be toggled on/off without re-segmenting.
        segmentedEpochSignal = result.signal
        segmentedEpochSegments = result.segments

        if psaAverageOnApply, let averaged = averageEpochResult(result) {
            let display = postProcessedEpochs(averaged)
            epochedSignal = display.signal
            epochSegments = display.segments
            psaIsAveraged = true
            psaStatusMessage = averaged.message + psaPostProcessingSuffix()
        } else {
            let display = postProcessedEpochs(result)
            epochedSignal = display.signal
            epochSegments = display.segments
            psaIsAveraged = false
            showsButterflyPlot = false
            psaStatusMessage = result.message + psaPostProcessingSuffix()
        }

        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        topomapSample = nil
        butterflyTopomapRelativeSample = nil
        selectedEventCodes.removeAll()
        horizontalScrollPosition.scrollTo(x: 0)
        showsPSASheet = false
    }

    private func buildEpochs(from signal: MFFSignalData) -> PSABuildResult? {
        guard let categoriesByCode = selectedPSACategoriesByCode() else {
            psaStatusMessage = "Enter a category name for each selected event."
            return nil
        }

        let events = segmentableEvents(for: signal)
            .filter { psaSelectedEventCodes.contains($0.code) }
            .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }

        guard !events.isEmpty else {
            psaStatusMessage = "Select at least one event code."
            return nil
        }
        guard signal.samplingRate > 0, let sampleCount = signal.data.first?.count, sampleCount > 0 else {
            psaStatusMessage = "This signal has no readable samples."
            return nil
        }

        let preSamples = max(Int((psaPreStimulus * signal.samplingRate).rounded()), 0)
        let epochLength = max(Int(((psaPreStimulus + psaPostStimulus) * signal.samplingRate).rounded()), 1)
        guard epochLength > 0 else {
            psaStatusMessage = "Epoch duration must be greater than zero."
            return nil
        }

        var epochedData = Array(repeating: [Float](), count: signal.numberOfChannels)
        var epochedEvents: [MFFEvent] = []
        var segments: [EpochSegment] = []
        var skippedOutOfBounds = 0
        var skippedArtifacts = 0
        var accepted = 0
        let categoryColorIndices = categoryColorIndices(for: Array(categoriesByCode.values))
        let artifactEventsForRejection = psaArtifactEventsForRejection(in: signal)

        for event in events {
            guard let category = categoriesByCode[event.code] else { continue }
            let correctedSample = Int(((event.beginTimeSeconds + psaOffset) * signal.samplingRate).rounded())
            let startSample = correctedSample - preSamples
            let endSample = startSample + epochLength

            guard startSample >= 0, endSample <= sampleCount else {
                skippedOutOfBounds += 1
                continue
            }

            if shouldSkipEpochForArtifact(
                startSample: startSample,
                endSample: endSample,
                samplingRate: signal.samplingRate,
                artifactEvents: artifactEventsForRejection
            ) {
                skippedArtifacts += 1
                continue
            }

            for channelIndex in signal.data.indices {
                guard signal.data[channelIndex].count >= endSample else { continue }
                epochedData[channelIndex].append(contentsOf: signal.data[channelIndex][startSample..<endSample])
            }

            let epochStart = accepted * epochLength
            let stimulusSample = epochStart + preSamples
            let stimulusTime = Double(stimulusSample) / signal.samplingRate
            epochedEvents.append(
                MFFEvent(
                    id: "psa-\(accepted)-\(event.id)",
                    code: category,
                    beginTimeSeconds: stimulusTime,
                    rawBeginTime: String(format: "%.6f", stimulusTime),
                    sourceFile: "PSA: \(event.code)"
                )
            )
            segments.append(
                EpochSegment(
                    startSample: epochStart,
                    endSample: epochStart + epochLength - 1,
                    stimulusOffsetSamples: preSamples,
                    category: category,
                    sourceCode: event.code,
                    sourceTimeSeconds: event.beginTimeSeconds,
                    colorIndex: categoryColorIndices[category] ?? 0,
                    contributingEpochCount: 1
                )
            )
            accepted += 1
        }

        guard accepted > 0, let totalSamples = epochedData.first?.count, totalSamples > 0 else {
            psaStatusMessage = skippedArtifacts > 0
                ? "No epochs remained after artifact rejection."
                : "No epochs fit inside the recording bounds."
            return nil
        }

        let epochedSignal = MFFSignalData(
            signalURL: signal.signalURL,
            signalType: "\(signal.signalType) Epochs",
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: Double(totalSamples) / signal.samplingRate,
            recordingStartTime: signal.recordingStartTime,
            events: epochedEvents,
            data: epochedData,
            channelNames: signal.channelNames
        )

        var message = "\(accepted) epochs"
        if skippedArtifacts > 0 {
            message += ", \(skippedArtifacts) skipped for \(psaArtifactRejectionLabel())"
        }
        if skippedOutOfBounds > 0 {
            message += ", \(skippedOutOfBounds) out of bounds"
        }

        return PSABuildResult(signal: epochedSignal, segments: segments, message: message)
    }

    private func psaArtifactEventsForRejection(in signal: MFFSignalData) -> [MFFEvent] {
        guard psaSkipIfContainsArtifact else { return [] }

        var events: [MFFEvent] = []
        if psaSkipEyeBlinks {
            events += artifactEventsOrDetection(for: .blink, in: signal)
        }
        if psaSkipEyeMovements {
            events += artifactEventsOrDetection(for: .movement, in: signal)
        }
        events += definedArtifacts
            .filter { psaSkippedDefinedArtifactIDs.contains($0.id) }
            .flatMap(\.events)

        return events
    }

    private func artifactEventsOrDetection(for kind: EyeArtifactKind, in signal: MFFSignalData) -> [MFFEvent] {
        let existingEvents = artifactEvents.filter { $0.code == kind.eventCode }
        if !existingEvents.isEmpty {
            return existingEvents
        }

        return EyeArtifactThresholdDetector.detect(
            kind: kind,
            channels: signal.data,
            samplingRate: signal.samplingRate,
            duration: signal.duration
        )
    }

    private func shouldSkipEpochForArtifact(
        startSample: Int,
        endSample: Int,
        samplingRate: Double,
        artifactEvents: [MFFEvent]
    ) -> Bool {
        guard psaSkipIfContainsArtifact,
              !artifactEvents.isEmpty,
              samplingRate > 0 else { return false }
        let startSeconds = Double(startSample) / samplingRate
        let endSeconds = Double(endSample) / samplingRate
        return artifactEvents.contains { event in
            event.beginTimeSeconds >= startSeconds && event.beginTimeSeconds <= endSeconds
        }
    }

    private func psaArtifactRejectionLabel() -> String {
        var labels: [String] = []
        if psaSkipEyeBlinks {
            labels.append("eye blinks")
        }
        if psaSkipEyeMovements {
            labels.append("eye movements")
        }
        let definedCount = definedArtifacts.filter {
            psaSkippedDefinedArtifactIDs.contains($0.id)
        }.count
        if definedCount == 1 {
            labels.append("1 defined artifact")
        } else if definedCount > 1 {
            labels.append("\(definedCount) defined artifacts")
        }
        return labels.isEmpty ? "artifacts" : labels.joined(separator: "/")
    }

    private func averageCurrentEpochs() {
        guard let segmentedEpochSignal, !segmentedEpochSegments.isEmpty else {
            psaStatusMessage = "Create epochs before averaging."
            return
        }

        let result = PSABuildResult(
            signal: segmentedEpochSignal,
            segments: segmentedEpochSegments,
            message: "\(segmentedEpochSegments.count) epochs"
        )
        guard let averaged = averageEpochResult(result) else { return }

        let display = postProcessedEpochs(averaged)
        epochedSignal = display.signal
        epochSegments = display.segments
        psaIsAveraged = true
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        topomapSample = nil
        butterflyTopomapRelativeSample = nil
        selectedEventCodes.removeAll()
        horizontalScrollPosition.scrollTo(x: 0)
        psaStatusMessage = averaged.message + psaPostProcessingSuffix()
    }

    private func averageEpochResult(_ result: PSABuildResult) -> PSABuildResult? {
        let signal = result.signal
        guard signal.samplingRate > 0,
              !result.segments.isEmpty,
              let firstSegment = result.segments.first else {
            psaStatusMessage = "No epochs are available to average."
            return nil
        }

        let epochLength = firstSegment.endSample - firstSegment.startSample + 1
        guard epochLength > 0 else {
            psaStatusMessage = "Epochs have invalid lengths."
            return nil
        }

        let groupedSegments = Dictionary(grouping: result.segments, by: \.category)
        let orderedCategories = groupedSegments.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let colorIndices = categoryColorIndices(for: orderedCategories)

        var averagedData = Array(repeating: [Float](), count: signal.numberOfChannels)
        var averagedEvents: [MFFEvent] = []
        var averagedSegments: [EpochSegment] = []
        var outputStartSample = 0

        for category in orderedCategories {
            guard let segments = groupedSegments[category]?.sorted(by: { $0.startSample < $1.startSample }),
                  let representative = segments.first else { continue }

            let validSegments = segments.filter {
                $0.endSample - $0.startSample + 1 == epochLength
                    && $0.startSample >= 0
                    && $0.endSample < (signal.data.first?.count ?? 0)
            }
            guard !validSegments.isEmpty else { continue }

            for channelIndex in signal.data.indices {
                var accumulator = [Double](repeating: 0, count: epochLength)
                let channel = signal.data[channelIndex]
                for segment in validSegments {
                    for offset in 0..<epochLength {
                        accumulator[offset] += Double(channel[segment.startSample + offset])
                    }
                }

                let divisor = Double(validSegments.count)
                averagedData[channelIndex].append(contentsOf: accumulator.map { Float($0 / divisor) })
            }

            let stimulusSample = outputStartSample + representative.stimulusOffsetSamples
            let stimulusTime = Double(stimulusSample) / signal.samplingRate
            averagedEvents.append(
                MFFEvent(
                    id: "psa-average-\(category)-\(outputStartSample)",
                    code: category,
                    beginTimeSeconds: stimulusTime,
                    rawBeginTime: String(format: "%.6f", stimulusTime),
                    sourceFile: "PSA Average"
                )
            )
            averagedSegments.append(
                EpochSegment(
                    startSample: outputStartSample,
                    endSample: outputStartSample + epochLength - 1,
                    stimulusOffsetSamples: representative.stimulusOffsetSamples,
                    category: category,
                    sourceCode: category,
                    sourceTimeSeconds: representative.sourceTimeSeconds,
                    colorIndex: colorIndices[category] ?? 0,
                    contributingEpochCount: validSegments.reduce(0) { $0 + $1.contributingEpochCount }
                )
            )
            outputStartSample += epochLength
        }

        guard let totalSamples = averagedData.first?.count, totalSamples > 0 else {
            psaStatusMessage = "No averages could be computed."
            return nil
        }

        let averagedSignal = MFFSignalData(
            signalURL: signal.signalURL,
            signalType: "\(signal.signalType) Averages",
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: Double(totalSamples) / signal.samplingRate,
            recordingStartTime: signal.recordingStartTime,
            events: averagedEvents,
            data: averagedData,
            channelNames: signal.channelNames
        )

        let totalContributors = averagedSegments.reduce(0) { $0 + $1.contributingEpochCount }
        return PSABuildResult(
            signal: averagedSignal,
            segments: averagedSegments,
            message: "\(averagedSegments.count) averages from \(totalContributors) epochs"
        )
    }

    /// Subtracts each epoch's pre-stimulus mean (per channel) from the whole
    /// epoch. Because this is a per-sample subtraction of a per-epoch constant,
    /// it commutes with averaging, so it can be applied to either single epochs
    /// or category averages with identical results.
    private func baselineCorrectedEpochs(_ result: PSABuildResult) -> PSABuildResult {
        var data = result.signal.data
        for segment in result.segments {
            let preCount = segment.stimulusOffsetSamples
            guard preCount > 0 else { continue }   // no pre-stimulus window to use
            let preStart = segment.startSample
            let preEnd = preStart + preCount        // exclusive
            for channel in data.indices {
                guard preEnd <= data[channel].count, segment.endSample < data[channel].count else { continue }
                var sum = 0.0
                for sample in preStart..<preEnd { sum += Double(data[channel][sample]) }
                let baseline = Float(sum / Double(preCount))
                // Skip only non-finite baselines (e.g. NaN from corrupt data);
                // a baseline of exactly 0 is valid and subtracting it is a no-op.
                guard baseline.isFinite else { continue }
                for sample in segment.startSample...segment.endSample {
                    data[channel][sample] -= baseline
                }
            }
        }

        let corrected = MFFSignalData(
            signalURL: result.signal.signalURL,
            signalType: result.signal.signalType,
            numberOfChannels: result.signal.numberOfChannels,
            samplingRate: result.signal.samplingRate,
            duration: result.signal.duration,
            recordingStartTime: result.signal.recordingStartTime,
            events: result.signal.events,
            data: data,
            channelNames: result.signal.channelNames
        )
        return PSABuildResult(signal: corrected, segments: result.segments, message: result.message)
    }

    /// Applies a common-average reference to the epoch data, computed from the
    /// good (non-bad) channels. Because interpolated channels are already swapped
    /// into the epoched signal, the reference correctly uses their reconstructed
    /// values and excludes bad channels.
    private func averageReferencedEpochs(_ result: PSABuildResult) -> PSABuildResult {
        let referencedData = EEGSignalFilter.averageReferenced(result.signal.data, excluding: channels.bad)
        let referenced = MFFSignalData(
            signalURL: result.signal.signalURL,
            signalType: result.signal.signalType,
            numberOfChannels: result.signal.numberOfChannels,
            samplingRate: result.signal.samplingRate,
            duration: result.signal.duration,
            recordingStartTime: result.signal.recordingStartTime,
            events: result.signal.events,
            data: referencedData,
            channelNames: result.signal.channelNames
        )
        return PSABuildResult(signal: referenced, segments: result.segments, message: result.message)
    }

    /// Applies the active PSA post-processing (average reference, then baseline
    /// correction) to a built/averaged result in the standard ERP order.
    private func postProcessedEpochs(_ result: PSABuildResult) -> PSABuildResult {
        var output = result
        if psaAverageReference { output = averageReferencedEpochs(output) }
        if psaBaselineCorrected { output = baselineCorrectedEpochs(output) }
        return output
    }

    private func psaPostProcessingSuffix() -> String {
        var parts: [String] = []
        if psaAverageReference { parts.append("avg ref") }
        if psaBaselineCorrected { parts.append("baseline corrected") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: ", ")
    }

    /// Re-derives the displayed epochs from the raw segmented source, applying
    /// averaging and the active post-processing per the current toggles. Used when
    /// a post-processing toggle changes after epochs already exist.
    private func refreshEpochDisplay() {
        guard let segmentedEpochSignal, !segmentedEpochSegments.isEmpty else { return }

        let base = PSABuildResult(
            signal: segmentedEpochSignal,
            segments: segmentedEpochSegments,
            message: "\(segmentedEpochSegments.count) epochs"
        )

        let result: PSABuildResult
        if psaIsAveraged {
            guard let averaged = averageEpochResult(base) else { return }
            result = averaged
        } else {
            result = base
        }

        let display = postProcessedEpochs(result)
        epochedSignal = display.signal
        epochSegments = display.segments
        psaStatusMessage = result.message + psaPostProcessingSuffix()
    }

    private func clearEpochs() {
        epochedSignal = nil
        epochSegments = []
        segmentedEpochSignal = nil
        segmentedEpochSegments = []
        psaIsAveraged = false
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        topomapSample = nil
        butterflyTopomapRelativeSample = nil
        showsButterflyPlot = false
        selectedEventCodes.removeAll()
        psaStatusMessage = nil
        segmentHealthTask?.cancel()
        segmentHealthTask = nil
        segmentHealthAnalysis = nil
        segmentHealthSignature = nil
        isAnalyzingSegmentHealth = false
        segmentHealthProgress = 0
        horizontalScrollPosition.scrollTo(x: 0)
    }

    private func epochCategorySummaries() -> [EpochCategorySummary] {
        let grouped = Dictionary(grouping: epochSegments, by: \.category)
        return grouped.map { category, segments in
            EpochCategorySummary(
                category: category,
                count: segments.reduce(0) { $0 + $1.contributingEpochCount },
                color: epochColor(for: segments.first?.colorIndex ?? 0)
            )
        }
        .sorted { $0.category.localizedStandardCompare($1.category) == .orderedAscending }
    }

    private func epochColor(for index: Int) -> Color {
        let palette: [Color] = [.green, .blue, .orange, .pink, .teal, .indigo]
        return palette[index % palette.count]
    }

    private func categoryColorIndices(for categories: [String]) -> [String: Int] {
        let uniqueCategories = Array(Set(categories)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: uniqueCategories.enumerated().map { index, category in
            (category, index)
        })
    }

    // MARK: - MFF export

    private func exportCurrentSignalToMFF() {
        guard !isExportingMFF else { return }
        guard let snapshot = currentMFFExportSnapshot() else {
            mffExportStatusMessage = "No signal is ready to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mff]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultMFFExportName(for: snapshot.kind)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExportingMFF = true
        mffExportStatusMessage = "Exporting \(snapshot.kind.statusName) MFF..."

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    try MFFWriter.write(
                        signal: snapshot.signal,
                        segments: snapshot.segments,
                        kind: snapshot.kind,
                        to: url
                    )
                    return Result<URL, Error>.success(url)
                } catch {
                    return Result<URL, Error>.failure(error)
                }
            }.value

            await MainActor.run {
                isExportingMFF = false
                switch result {
                case .success(let outputURL):
                    mffExportStatusMessage = "Exported \(snapshot.kind.statusName) MFF: \(outputURL.lastPathComponent)"
                case .failure(let error):
                    mffExportStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private func currentMFFExportSnapshot() -> MFFExportSnapshot? {
        guard let rawSignal = recording.signal else { return nil }

        let base = icaCleanedSignal ?? gradientCorrectedSignal ?? rawSignal
        let preArtifact = filteredSignal ?? base
        let processed = artifactCleaningIsEnabled ? (artifactCleanedSignal ?? preArtifact) : preArtifact
        let continuousSignal = applyInterpolations(to: processed)

        if let epochedSignal, !epochSegments.isEmpty {
            return MFFExportSnapshot(
                signal: epochedSignal,
                segments: epochSegments,
                kind: psaIsAveraged ? .averaged : .epoched
            )
        }

        return MFFExportSnapshot(signal: continuousSignal, segments: [], kind: .continuous)
    }

    private func defaultMFFExportName(for kind: MFFExportKind) -> String {
        let baseName = (recording.packageName as NSString).deletingPathExtension
        let suffix: String
        switch kind {
        case .continuous:
            suffix = "processed"
        case .epoched:
            suffix = "epochs"
        case .averaged:
            suffix = "averages"
        }
        return "\(baseName)-\(suffix).mff"
    }

    // MARK: - Filtering

    private func filterPopover(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Band-pass Filter")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Low Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("Low", value: $filterLowCutoff, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Stepper("", value: $filterLowCutoff, in: 0.1...100, step: 0.1)
                        .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("High Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("High", value: $filterHighCutoff, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Stepper("", value: $filterHighCutoff, in: 0.5...200, step: 0.5)
                        .labelsHidden()
                }
            }

            Toggle("Apply 60 Hz IIR notch", isOn: $notch60HzEnabled)

            Toggle("Average reference", isOn: $filterAverageReference)
                .help("Re-reference to the common average: subtract the mean across all channels at each time point. Removes shared reference signal.")

            HStack {
                Button("Reset 0.1–30 Hz") {
                    filterLowCutoff = 0.1
                    filterHighCutoff = 30
                    notch60HzEnabled = false
                    filterAverageReference = false
                }

                if filteredSignal != nil {
                    Button("Remove Filter", role: .destructive) {
                        clearBandpassFilter()
                        showsFilterPopover = false
                    }
                }

                Spacer()

                Button("Apply Filter") {
                    applyBandpassFilter(to: signal)
                    showsFilterPopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func applyBandpassFilter(to signal: MFFSignalData) {
        isFiltering = true
        filterProgress = 0
        filterStatusMessage = nil

        let signalURL = signal.signalURL
        let signalType = signal.signalType
        let numberOfChannels = signal.numberOfChannels
        let samplingRate = signal.samplingRate
        let duration = signal.duration
        let recordingStartTime = signal.recordingStartTime
        let events = signal.events
        let sourceData = signal.data
        let lowCutoff = filterLowCutoff
        let highCutoff = filterHighCutoff
        let notch60HzEnabled = notch60HzEnabled
        let averageReference = filterAverageReference

        // Stream per-channel completion fractions to the UI.
        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()
        let progressTask = Task { @MainActor in
            for await fraction in progressStream {
                filterProgress = fraction
            }
        }

        Task {
            do {
                let badChannels = channels.bad
                let filteredData = try await Task.detached(priority: .userInitiated) {
                    var bandPassed = try await EEGSignalFilter.bandPass(
                        channels: sourceData,
                        samplingRate: samplingRate,
                        lowCutoff: lowCutoff,
                        highCutoff: highCutoff,
                        notch60HzEnabled: notch60HzEnabled,
                        progress: { fraction in progressContinuation.yield(fraction) }
                    )
                    if averageReference {
                        EEGSignalFilter.averageReferenceInPlace(&bandPassed, excluding: badChannels)
                    }
                    return bandPassed
                }.value
                progressContinuation.finish()
                progressTask.cancel()

                filteredSignal = MFFSignalData(
                    signalURL: signalURL,
                    signalType: signalType,
                    numberOfChannels: numberOfChannels,
                    samplingRate: samplingRate,
                    duration: duration,
                    recordingStartTime: recordingStartTime,
                    events: events,
                    data: filteredData,
                    channelNames: signal.channelNames
                )
                clearAppliedArtifactCleaning()
                artifactDetectionRefreshToken += 1
                invalidateEpochsForSignalChange()
                invalidateInterpolations()
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                filterStatusMessage = error.localizedDescription
            }

            isFiltering = false
        }
    }

    private func clearBandpassFilter() {
        filteredSignal = nil
        clearAppliedArtifactCleaning()
        filterStatusMessage = nil
        artifactDetectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    // MARK: - MRI gradient artifact removal

    /// TREV (volume trigger) sample indices from the raw recording, used as the
    /// TR grid for gradient correction.
    private func trevSamples(in signal: MFFSignalData) -> [Int] {
        signal.events
            .filter { $0.code == "TREV" }
            .map { Int(($0.beginTimeSeconds * signal.samplingRate).rounded()) }
            .sorted()
    }

    private func removeGradientArtifact(from signal: MFFSignalData?) {
        guard let signal else { return }

        let trSamples = trevSamples(in: signal)
        isProcessingMRI = true
        mriProgress = 0
        mriStatusMessage = nil

        let signalURL = signal.signalURL
        let signalType = signal.signalType
        let numberOfChannels = signal.numberOfChannels
        let samplingRate = signal.samplingRate
        let duration = signal.duration
        let recordingStartTime = signal.recordingStartTime
        let events = signal.events
        let sourceData = signal.data

        // Stream completion fractions from the worker threads to the UI.
        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()
        let progressTask = Task { @MainActor in
            for await fraction in progressStream {
                mriProgress = fraction
            }
        }

        Task {
            do {
                let correctedData = try await Task.detached(priority: .userInitiated) {
                    try GradientRemover.correct(channels: sourceData, trSamples: trSamples) { fraction in
                        progressContinuation.yield(fraction)
                    }
                }.value
                progressContinuation.finish()
                progressTask.cancel()

                gradientCorrectedSignal = MFFSignalData(
                    signalURL: signalURL,
                    signalType: signalType,
                    numberOfChannels: numberOfChannels,
                    samplingRate: samplingRate,
                    duration: duration,
                    recordingStartTime: recordingStartTime,
                    events: events,
                    data: correctedData,
                    channelNames: signal.channelNames
                )
                // The base signal changed, so any band-pass filter computed on
                // the old base is stale.
                icaCleanedSignal = nil
                icaDecomposition = nil
                filteredSignal = nil
                clearAppliedArtifactCleaning()
                mriStatusMessage = nil
                artifactDetectionRefreshToken += 1
                invalidateEpochsForSignalChange()
                invalidateInterpolations()
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                mriStatusMessage = error.localizedDescription
            }

            isProcessingMRI = false
        }
    }

    private func clearGradientCorrection() {
        gradientCorrectedSignal = nil
        icaCleanedSignal = nil
        icaDecomposition = nil
        filteredSignal = nil
        clearAppliedArtifactCleaning()
        mriStatusMessage = nil
        artifactDetectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    // MARK: - Artifact detection

    private var artifactsAreActive: Bool {
        detectsEyeBlinkArtifacts
            || detectsEyeMovementArtifacts
            || detectsECGArtifacts
            || !artifactEvents.isEmpty
            || !definedArtifacts.isEmpty
            || artifactCleanedSignal != nil
    }

    private var artifactHelpText: String {
        if isCleaningArtifacts {
            return "Artifact cleaning\nCleaning artifacts..."
        }

        if isDetectingArtifacts {
            return "Artifact detection\nDetecting artifacts..."
        }

        if artifactCleanedSignal != nil, !artifactCleaningIsEnabled {
            return "Artifact cleaning\nApplied correction hidden for comparison."
        }

        if artifactCleanedSignal != nil {
            return "Artifact cleaning\n\(artifactCleaningStatusMessage ?? "Artifact cleanup applied.")"
        }

        if let artifactStatusMessage {
            return "Artifact detection\n\(artifactStatusMessage)"
        }

        if !definedArtifacts.isEmpty {
            return "Artifact detection\n\(definedArtifacts.count) artifact definitions"
        }

        return "Artifact detection"
    }

    private func artifactDetectionRequestID(for signal: MFFSignalData) -> String {
        return [
            signal.signalURL.path,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            "\(detectsEyeBlinkArtifacts)",
            "\(detectsEyeMovementArtifacts)",
            "\(detectsECGArtifacts)",
            artifactDetectionMethod.rawValue,
            "\(artifactDetectionRefreshToken)"
        ].joined(separator: "|")
    }

    @MainActor
    private func updateArtifactEvents(for signal: MFFSignalData) async {
        if artifactDetectionMethod == .template || artifactDetectionMethod == .ica {
            isDetectingArtifacts = false
            return
        }

        guard (detectsEyeBlinkArtifacts || detectsEyeMovementArtifacts), artifactDetectionMethod == .threshold else {
            artifactEvents = []
            artifactStatusMessage = artifactsAreActive ? "Only threshold eye artifact detection is available." : nil
            isDetectingArtifacts = false
            return
        }

        isDetectingArtifacts = true
        artifactStatusMessage = nil

        let sourceData = signal.data
        let samplingRate = signal.samplingRate
        let duration = signal.duration
        let detectBlinks = detectsEyeBlinkArtifacts
        let detectMovements = detectsEyeMovementArtifacts

        let detectedEvents = await Task.detached(priority: .userInitiated) {
            var events: [MFFEvent] = []
            if detectBlinks {
                events += EyeArtifactThresholdDetector.detect(
                    kind: .blink,
                    channels: sourceData,
                    samplingRate: samplingRate,
                    duration: duration
                )
            }
            if detectMovements {
                events += EyeArtifactThresholdDetector.detect(
                    kind: .movement,
                    channels: sourceData,
                    samplingRate: samplingRate,
                    duration: duration
                )
            }
            return events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        }.value

        artifactEvents = detectedEvents
        artifactStatusMessage = artifactDetectionSummary(for: detectedEvents)
        isDetectingArtifacts = false
    }

    private func artifactDetectionSummary(for events: [MFFEvent]) -> String {
        guard !events.isEmpty else { return "No eye artifacts detected." }
        let blinkCount = events.filter { $0.code == EyeArtifactKind.blink.eventCode }.count
        let movementCount = events.filter { $0.code == EyeArtifactKind.movement.eventCode }.count
        var parts: [String] = []
        if blinkCount > 0 {
            parts.append("\(blinkCount) blinks")
        }
        if movementCount > 0 {
            parts.append("\(movementCount) eye movements")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Channel health

    private func channelHealthRequestID(for signal: MFFSignalData) -> String {
        [
            "\(channels.showsHealth)",
            "\(channels.healthRefreshToken)",
            channelHealthSignature(for: signal)
        ].joined(separator: "|")
    }

    private func channelHealthSignature(for signal: MFFSignalData) -> String {
        return [
            signal.signalURL.path,
            signal.signalType,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            "\(signal.samplingRate)",
            "\(gradientCorrectedSignal != nil)",
            "\(icaCleanedSignal != nil)",
            "\(filteredSignal != nil)",
            "\(artifactCleanedSignal != nil)",
            "\(artifactCleaningIsEnabled)",
            channels.interpolated.keys.sorted().map(String.init).joined(separator: ",")
        ].joined(separator: "|")
    }

    @MainActor
    private func refreshChannelHealthIfNeeded(for signal: MFFSignalData) {
        let signature = channelHealthSignature(for: signal)

        guard channels.showsHealth else {
            channelHealthTask?.cancel()
            channelHealthTask = nil
            channelHealthSignature = nil
            channels.clearHealthResults()
            channelHealthStatusMessage = nil
            return
        }

        guard channelHealthSignature != signature || channels.healthResults.isEmpty else {
            return
        }

        channelHealthTask?.cancel()
        channelHealthSignature = signature
        channels.healthResults = [:]
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        channelHealthStatusMessage = nil

        let layout = recording.sensorLayout
        let sourceSignal = signal
        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()
        let progressTask = Task { @MainActor in
            for await fraction in progressStream {
                channels.healthProgress = min(max(fraction, 0), 1)
            }
        }

        channelHealthTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                ChannelHealthAnalyzer.analyze(
                    signal: sourceSignal,
                    layout: layout,
                    progress: { fraction in
                        progressContinuation.yield(fraction)
                    }
                )
            }

            let analysis = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )

            progressContinuation.finish()
            progressTask.cancel()

            guard !Task.isCancelled,
                  channels.showsHealth,
                  channelHealthSignature == signature else {
                return
            }

            channels.healthResults = analysis.resultsByChannel
            channels.isAnalyzingHealth = false
            channels.healthProgress = 1
            channelHealthStatusMessage = analysis.resultsByChannel.isEmpty
                ? "No channel health metrics available."
                : "Channel health scored \(analysis.resultsByChannel.count) channels."
        }
    }

    private func saveChannelLabelMetricsJSON() {
        guard !channels.bad.isEmpty else {
            channelHealthStatusMessage = "Mark at least one bad channel before saving labels."
            return
        }
        guard let signal = currentChannelLabelMetricsSignal() else {
            channelHealthStatusMessage = "No signal is ready for channel-label export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultChannelLabelMetricsExportName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        channelHealthTask?.cancel()
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        channelHealthStatusMessage = "Saving channel label metrics..."

        let packageName = recording.packageName
        let layout = recording.sensorLayout
        let processing = channelHealthProcessingSnapshot()
        let hiddenChannels = channels.hidden

        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()
        let progressTask = Task { @MainActor in
            for await fraction in progressStream {
                channels.healthProgress = min(max(fraction, 0), 1)
            }
        }

        channelHealthTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                do {
                    let analysis = ChannelHealthAnalyzer.analyze(
                        signal: signal,
                        layout: layout,
                        progress: { fraction in
                            progressContinuation.yield(0.85 * fraction)
                        }
                    )
                    let export = SavedChannelHealthDataset.make(
                        packageName: packageName,
                        signal: signal,
                        processing: processing,
                        hiddenChannelIndices: hiddenChannels,
                        analysis: analysis
                    )
                    progressContinuation.yield(0.92)

                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(export)
                    progressContinuation.yield(0.97)
                    try data.write(to: url, options: .atomic)
                    return Result<Int, Error>.success(export.channels.count)
                } catch {
                    return Result<Int, Error>.failure(error)
                }
            }.value

            progressContinuation.finish()
            progressTask.cancel()
            channels.isAnalyzingHealth = false

            switch result {
            case .success(let channelCount):
                channels.healthProgress = 1
                channelHealthStatusMessage = "Saved labels and metrics for \(channelCount) channels: \(url.lastPathComponent)"
            case .failure(let error):
                channels.healthProgress = 0
                channelHealthStatusMessage = error.localizedDescription
            }
        }
    }

    private func currentChannelLabelMetricsSignal() -> MFFSignalData? {
        guard let rawSignal = recording.signal else { return nil }
        let base = icaCleanedSignal ?? gradientCorrectedSignal ?? rawSignal
        let preArtifact = filteredSignal ?? base
        return artifactCleaningIsEnabled ? (artifactCleanedSignal ?? preArtifact) : preArtifact
    }

    private func channelHealthProcessingSnapshot() -> SavedChannelHealthProcessing {
        SavedChannelHealthProcessing(
            gradientCorrected: gradientCorrectedSignal != nil,
            icaCleaned: icaCleanedSignal != nil,
            filtered: filteredSignal != nil,
            filterLowCutoffHz: filteredSignal == nil ? nil : filterLowCutoff,
            filterHighCutoffHz: filteredSignal == nil ? nil : filterHighCutoff,
            notch60HzEnabled: filteredSignal == nil ? nil : notch60HzEnabled,
            averageReferenced: filteredSignal == nil ? nil : filterAverageReference,
            artifactCleaned: artifactCleanedSignal != nil,
            artifactCleaningVisible: artifactCleanedSignal != nil && artifactCleaningIsEnabled,
            interpolatedChannelIndices: channels.interpolated.keys.sorted(),
            markedBadChannelIndices: channels.bad.sorted()
        )
    }

    private func defaultChannelLabelMetricsExportName() -> String {
        let baseName = (recording.packageName as NSString).deletingPathExtension
        return "\(baseName)-channel-labels.json"
    }

    // MARK: - Segment health

    private func segmentHealthRequestID(for signal: MFFSignalData) -> String {
        [
            "\(showsSegmentHealth)",
            "\(segmentHealthRefreshRequest)",
            segmentHealthSignature(for: signal)
        ].joined(separator: "|")
    }

    private func segmentHealthSignature(for signal: MFFSignalData) -> String {
        let badChannelSignature = channels.bad.sorted().map(String.init).joined(separator: ",")
        let interpolationSignature = channels.interpolated.keys.sorted().map(String.init).joined(separator: ",")
        let epochSignature = epochSegments.map(\.id).joined(separator: ",")
        let definedArtifactSignature = definedArtifacts.map { artifact in
            [
                artifact.id.uuidString,
                artifact.eventCode,
                "\(artifact.events.count)",
                "\(artifact.windowSizeSeconds)"
            ].joined(separator: ":")
        }.joined(separator: ",")
        let artifactEventSignature = artifactEvents.map { event in
            [
                event.id,
                event.code,
                "\(event.beginTimeSeconds)"
            ].joined(separator: ":")
        }.joined(separator: ",")

        return [
            signal.signalURL.path,
            signal.signalType,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            "\(signal.samplingRate)",
            "\(gradientCorrectedSignal != nil)",
            "\(icaCleanedSignal != nil)",
            "\(filteredSignal != nil)",
            "\(artifactCleanedSignal != nil)",
            "\(artifactCleaningIsEnabled)",
            "\(epochedSignal != nil)",
            "\(psaIsAveraged)",
            "\(psaBaselineCorrected)",
            "\(psaAverageReference)",
            badChannelSignature,
            interpolationSignature,
            epochSignature,
            definedArtifactSignature,
            artifactEventSignature
        ].joined(separator: "|")
    }

    private func segmentHealthInputSegments(for signal: MFFSignalData) -> [SegmentHealthInputSegment] {
        SegmentHealthAnalyzer.analysisSegments(
            for: signal,
            epochSegments: epochedSignal == nil ? [] : epochSegments
        )
    }

    private func segmentHealthArtifactIntervals(for signal: MFFSignalData) -> [SegmentHealthArtifactInterval] {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0 else {
            return []
        }

        let sourceWindows = segmentHealthArtifactSourceWindows()
        guard !sourceWindows.isEmpty else { return [] }

        if epochedSignal != nil, !epochSegments.isEmpty {
            return segmentHealthEpochedArtifactIntervals(
                sourceWindows: sourceWindows,
                samplingRate: signal.samplingRate,
                sampleCount: sampleCount
            )
        }

        return sourceWindows.compactMap { window in
            segmentHealthArtifactInterval(
                id: window.id,
                code: window.code,
                sourceFile: window.sourceFile,
                startSeconds: window.startSeconds,
                endSeconds: window.endSeconds,
                samplingRate: signal.samplingRate,
                sampleCount: sampleCount
            )
        }
        .sorted { $0.startSample < $1.startSample }
    }

    private func segmentHealthArtifactSourceWindows() -> [(id: String, code: String, sourceFile: String, startSeconds: Double, endSeconds: Double)] {
        let defaultWindowSeconds = 0.25
        var windows: [(id: String, code: String, sourceFile: String, startSeconds: Double, endSeconds: Double)] = []
        var definedEvents = Set<MFFEvent>()

        for artifact in definedArtifacts {
            let windowSeconds = max(artifact.windowSizeSeconds, defaultWindowSeconds)
            for event in artifact.events {
                definedEvents.insert(event)
                let halfWindow = windowSeconds / 2
                windows.append((
                    id: "\(artifact.id.uuidString)-\(event.id)",
                    code: event.code,
                    sourceFile: artifact.name,
                    startSeconds: event.beginTimeSeconds - halfWindow,
                    endSeconds: event.beginTimeSeconds + halfWindow
                ))
            }
        }

        for event in artifactEvents where !definedEvents.contains(event) {
            let halfWindow = defaultWindowSeconds / 2
            windows.append((
                id: event.id,
                code: event.code,
                sourceFile: event.sourceFile,
                startSeconds: event.beginTimeSeconds - halfWindow,
                endSeconds: event.beginTimeSeconds + halfWindow
            ))
        }

        return windows
    }

    private func segmentHealthEpochedArtifactIntervals(
        sourceWindows: [(id: String, code: String, sourceFile: String, startSeconds: Double, endSeconds: Double)],
        samplingRate: Double,
        sampleCount: Int
    ) -> [SegmentHealthArtifactInterval] {
        var intervals: [SegmentHealthArtifactInterval] = []
        for segment in epochSegments {
            let epochStartSeconds = segment.sourceTimeSeconds - Double(segment.stimulusOffsetSamples) / samplingRate
            let epochDurationSeconds = Double(segment.endSample - segment.startSample + 1) / samplingRate
            let epochEndSeconds = epochStartSeconds + epochDurationSeconds

            for window in sourceWindows {
                let overlapStart = max(window.startSeconds, epochStartSeconds)
                let overlapEnd = min(window.endSeconds, epochEndSeconds)
                guard overlapEnd >= overlapStart else { continue }

                let displayStartSeconds = Double(segment.startSample) / samplingRate + (overlapStart - epochStartSeconds)
                let displayEndSeconds = Double(segment.startSample) / samplingRate + (overlapEnd - epochStartSeconds)
                if let interval = segmentHealthArtifactInterval(
                    id: "\(segment.id)-\(window.id)",
                    code: window.code,
                    sourceFile: window.sourceFile,
                    startSeconds: displayStartSeconds,
                    endSeconds: displayEndSeconds,
                    samplingRate: samplingRate,
                    sampleCount: sampleCount
                ) {
                    intervals.append(interval)
                }
            }
        }

        return intervals.sorted { $0.startSample < $1.startSample }
    }

    private func segmentHealthArtifactInterval(
        id: String,
        code: String,
        sourceFile: String,
        startSeconds: Double,
        endSeconds: Double,
        samplingRate: Double,
        sampleCount: Int
    ) -> SegmentHealthArtifactInterval? {
        guard samplingRate > 0, sampleCount > 0 else { return nil }
        let lowerSeconds = min(startSeconds, endSeconds)
        let upperSeconds = max(startSeconds, endSeconds)
        let start = min(max(Int((lowerSeconds * samplingRate).rounded(.down)), 0), sampleCount - 1)
        let end = min(max(Int((upperSeconds * samplingRate).rounded(.up)), start), sampleCount - 1)
        guard end >= start else { return nil }
        return SegmentHealthArtifactInterval(
            artifactID: id,
            code: code,
            startSample: start,
            endSample: end,
            sourceFile: sourceFile
        )
    }

    @MainActor
    private func refreshSegmentHealthIfNeeded(for signal: MFFSignalData) {
        let signature = segmentHealthSignature(for: signal)

        guard showsSegmentHealth else {
            segmentHealthTask?.cancel()
            segmentHealthTask = nil
            segmentHealthSignature = nil
            segmentHealthAnalysis = nil
            isAnalyzingSegmentHealth = false
            segmentHealthProgress = 0
            segmentHealthStatusMessage = nil
            return
        }

        guard segmentHealthSignature != signature || segmentHealthAnalysis?.results.isEmpty != false else {
            return
        }

        let segments = segmentHealthInputSegments(for: signal)
        guard !segments.isEmpty else {
            segmentHealthAnalysis = nil
            segmentHealthStatusMessage = "No segments are available to score."
            return
        }

        segmentHealthTask?.cancel()
        segmentHealthSignature = signature
        segmentHealthAnalysis = nil
        isAnalyzingSegmentHealth = true
        segmentHealthProgress = 0
        segmentHealthStatusMessage = nil

        let excludedChannels = channels.bad
        let artifactIntervals = segmentHealthArtifactIntervals(for: signal)
        let sourceSignal = signal
        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()
        let progressTask = Task { @MainActor in
            for await fraction in progressStream {
                segmentHealthProgress = min(max(fraction, 0), 1)
            }
        }

        segmentHealthTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                SegmentHealthAnalyzer.analyze(
                    signal: sourceSignal,
                    segments: segments,
                    excludedChannelIndices: excludedChannels,
                    artifactIntervals: artifactIntervals,
                    progress: { fraction in
                        progressContinuation.yield(fraction)
                    }
                )
            }

            let analysis = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )

            progressContinuation.finish()
            progressTask.cancel()

            guard !Task.isCancelled,
                  showsSegmentHealth,
                  segmentHealthSignature == signature else {
                return
            }

            segmentHealthAnalysis = analysis
            isAnalyzingSegmentHealth = false
            segmentHealthProgress = 1
            segmentHealthStatusMessage = analysis.results.isEmpty
                ? "No segment health metrics available."
                : "Segment health scored \(analysis.results.count) segments."
        }
    }

    private func segmentHealthDetailsSheet() -> some View {
        SegmentHealthDetailsView(
            results: segmentHealthAnalysis?.results ?? [],
            isAnalyzing: isAnalyzingSegmentHealth,
            progress: segmentHealthProgress,
            statusMessage: segmentHealthStatusMessage,
            onRefresh: {
                showsSegmentHealth = true
                segmentHealthRefreshRequest += 1
            },
            onSave: {
                saveSegmentHealthMetricsJSON()
            },
            onJump: { result in
                jumpToSegment(result)
            },
            onClose: {
                showsSegmentHealthDetails = false
            }
        )
    }

    private func saveSegmentHealthMetricsJSON() {
        guard let signal = currentSegmentHealthSignal() else {
            segmentHealthStatusMessage = "No signal is ready for segment-metrics export."
            return
        }

        let segments = segmentHealthInputSegments(for: signal)
        guard !segments.isEmpty else {
            segmentHealthStatusMessage = "No segments are available to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultSegmentHealthExportName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        segmentHealthTask?.cancel()
        showsSegmentHealth = true
        isAnalyzingSegmentHealth = true
        segmentHealthProgress = 0
        segmentHealthStatusMessage = "Saving segment health metrics..."

        let signature = segmentHealthSignature(for: signal)
        let reusableAnalysis = segmentHealthSignature == signature ? segmentHealthAnalysis : nil
        let packageName = recording.packageName
        let processing = segmentHealthProcessingSnapshot()
        let excludedChannels = channels.bad
        let artifactIntervals = segmentHealthArtifactIntervals(for: signal)

        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()
        let progressTask = Task { @MainActor in
            for await fraction in progressStream {
                segmentHealthProgress = min(max(fraction, 0), 1)
            }
        }

        segmentHealthTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                do {
                    let analysis: SegmentHealthAnalysis
                    if let reusableAnalysis {
                        analysis = reusableAnalysis
                        progressContinuation.yield(0.85)
                    } else {
                        analysis = SegmentHealthAnalyzer.analyze(
                            signal: signal,
                            segments: segments,
                            excludedChannelIndices: excludedChannels,
                            artifactIntervals: artifactIntervals,
                            progress: { fraction in
                                progressContinuation.yield(0.85 * fraction)
                            }
                        )
                    }

                    let export = SavedSegmentHealthDataset.make(
                        packageName: packageName,
                        signal: signal,
                        processing: processing,
                        analysis: analysis
                    )
                    progressContinuation.yield(0.92)

                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(export)
                    progressContinuation.yield(0.97)
                    try data.write(to: url, options: .atomic)
                    return Result<(Int, SegmentHealthAnalysis), Error>.success((export.segments.count, analysis))
                } catch {
                    return Result<(Int, SegmentHealthAnalysis), Error>.failure(error)
                }
            }.value

            progressContinuation.finish()
            progressTask.cancel()
            isAnalyzingSegmentHealth = false

            switch result {
            case .success(let payload):
                segmentHealthProgress = 1
                segmentHealthSignature = signature
                segmentHealthAnalysis = payload.1
                segmentHealthStatusMessage = "Saved metrics for \(payload.0) segments: \(url.lastPathComponent)"
            case .failure(let error):
                segmentHealthProgress = 0
                segmentHealthStatusMessage = error.localizedDescription
            }
        }
    }

    private func currentSegmentHealthSignal() -> MFFSignalData? {
        guard let rawSignal = recording.signal else { return nil }
        let base = icaCleanedSignal ?? gradientCorrectedSignal ?? rawSignal
        let preArtifact = filteredSignal ?? base
        let processed = artifactCleaningIsEnabled ? (artifactCleanedSignal ?? preArtifact) : preArtifact
        let continuousSignal = applyInterpolations(to: processed)
        return epochedSignal ?? continuousSignal
    }

    private func segmentHealthProcessingSnapshot() -> SavedSegmentHealthProcessing {
        SavedSegmentHealthProcessing(
            gradientCorrected: gradientCorrectedSignal != nil,
            icaCleaned: icaCleanedSignal != nil,
            filtered: filteredSignal != nil,
            filterLowCutoffHz: filteredSignal == nil ? nil : filterLowCutoff,
            filterHighCutoffHz: filteredSignal == nil ? nil : filterHighCutoff,
            notch60HzEnabled: filteredSignal == nil ? nil : notch60HzEnabled,
            averageReferenced: filteredSignal == nil ? nil : filterAverageReference,
            artifactCleaned: artifactCleanedSignal != nil,
            artifactCleaningVisible: artifactCleanedSignal != nil && artifactCleaningIsEnabled,
            epoched: epochedSignal != nil,
            psaAveraged: psaIsAveraged,
            psaBaselineCorrected: psaBaselineCorrected,
            psaAverageReferenced: psaAverageReference,
            hiddenChannelIndices: channels.hidden.sorted(),
            interpolatedChannelIndices: channels.interpolated.keys.sorted(),
            markedBadChannelIndices: channels.bad.sorted()
        )
    }

    private func defaultSegmentHealthExportName() -> String {
        let baseName = (recording.packageName as NSString).deletingPathExtension
        return "\(baseName)-segment-health.json"
    }

    // MARK: - Channel interpolation

    /// Returns `signal` with any interpolated channels swapped in.
    private func applyInterpolations(to signal: MFFSignalData) -> MFFSignalData {
        guard !channels.interpolated.isEmpty else { return signal }
        var data = signal.data
        for (index, series) in channels.interpolated where index < data.count && series.count == data[index].count {
            data[index] = series
        }
        return MFFSignalData(
            signalURL: signal.signalURL,
            signalType: signal.signalType,
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: signal.events,
            data: data,
            channelNames: signal.channelNames
        )
    }

    /// Replaces channel `index` with a spherical-spline interpolation from the
    /// good channels of the currently displayed signal.
    private func interpolate(_ index: Int, in signal: MFFSignalData) {
        channelStatusMessage = nil
        guard let geometry = electrodeGeometry, geometry.positions[index] != nil else {
            channelStatusMessage = "No 3D coordinates for Ch \(index + 1); can't interpolate."
            return
        }

        let good = signal.data.indices.filter {
            $0 != index && !channels.bad.contains($0) && geometry.positions[$0] != nil
        }

        guard let (indices, weights) = SphericalSpline.interpolationWeights(
            target: index,
            good: good,
            positions: geometry.positions
        ) else {
            channelStatusMessage = "Couldn't compute interpolation weights for Ch \(index + 1)."
            return
        }

        let length = signal.data[index].count
        var series = [Float](repeating: 0, count: length)
        for (channelIndex, weight) in zip(indices, weights) {
            let source = signal.data[channelIndex]
            guard source.count == length else { continue }
            // series += Float(weight) * source
            vDSP.add(multiplication: (source, Float(weight)), series, result: &series)
        }

        channels.interpolated[index] = series
        channels.bad.remove(index)
        artifactDetectionRefreshToken += 1
        invalidateEpochsForSignalChange()
    }

    /// Interpolated channels are derived from the source data, so they go stale
    /// when the gradient/filter pipeline changes.
    private func invalidateInterpolations() {
        channels.interpolated.removeAll()
    }

    /// Clears every derived buffer (filters, re-reference, MRI correction, ICA,
    /// artifact detections, epochs, interpolations) so the view falls back to the
    /// original recording — without needing to close and reopen the file.
    /// Analysis parameters (cutoffs, ICA settings, template names) are preserved.
    private func resetToOriginalData() {
        // Derived signals.
        filteredSignal = nil
        icaCleanedSignal = nil
        icaDecomposition = nil
        gradientCorrectedSignal = nil
        artifactCleanedSignal = nil
        artifactCleaningIsEnabled = true

        // Artifact detection + templates.
        artifactEvents = []
        artifactTemplateResult = nil
        definedArtifacts = []
        artifactCleaningSummaries = []
        artifactCleaningProgress = nil
        obsVarianceReportCache.removeAll()
        psaSkippedDefinedArtifactIDs.removeAll()
        psaKnownArtifactIDsForRejection.removeAll()
        detectsEyeBlinkArtifacts = false
        detectsEyeMovementArtifacts = false
        detectsECGArtifacts = false
        selectedArtifactTemplateChannel = nil
        artifactTemplateClickedChannel = nil
        artifactTemplateSelectionRange = nil
        artifactTemplateDefinedArtifactID = nil

        // Status messages and progress.
        filterStatusMessage = nil
        icaStatusMessage = nil
        artifactStatusMessage = nil
        artifactTemplateStatusMessage = nil
        artifactCleaningStatusMessage = nil
        mriStatusMessage = nil
        psaStatusMessage = nil
        channelStatusMessage = nil
        channelHealthStatusMessage = nil
        segmentHealthStatusMessage = nil
        lastICAReconstructionDebugReport = nil

        // Interpolations, epochs, and the dependent selection/topomap state.
        invalidateInterpolations()
        channels.clearHealthResults()
        channelHealthSignature = nil
        segmentHealthTask?.cancel()
        segmentHealthTask = nil
        segmentHealthAnalysis = nil
        segmentHealthSignature = nil
        isAnalyzingSegmentHealth = false
        segmentHealthProgress = 0
        invalidateEpochsForSignalChange()

        // Force artifact overlays and downstream views to rebuild from the base.
        artifactDetectionRefreshToken += 1
    }

    private func invalidateEpochsForSignalChange() {
        epochedSignal = nil
        epochSegments = []
        segmentedEpochSignal = nil
        segmentedEpochSegments = []
        psaIsAveraged = false
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        topomapSample = nil
        butterflyTopomapRelativeSample = nil
        showsButterflyPlot = false
        showsOverlaidCategories = false
        segmentHealthTask?.cancel()
        segmentHealthTask = nil
        segmentHealthAnalysis = nil
        segmentHealthSignature = nil
        isAnalyzingSegmentHealth = false
        segmentHealthProgress = 0
    }

    // MARK: - SwiftData markers

    private func addMarker(atSample sample: Int, in signal: MFFSignalData) {
        let time = signal.samplingRate > 0 ? Double(sample) / signal.samplingRate : 0
        modelContext.insert(UserMarker(packageName: recording.packageName, timeSeconds: time))
    }

    // MARK: - Keyboard state

    private func installCommandKeyMonitor() {
        guard commandKeyMonitor == nil else { return }
        isCommandKeyPressed = NSEvent.modifierFlags.contains(.command)
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            isCommandKeyPressed = event.modifierFlags.contains(.command)
            return event
        }
    }

    private func removeCommandKeyMonitor() {
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
        }
        commandKeyMonitor = nil
        isCommandKeyPressed = false
    }

    // MARK: - Geometry helpers

    private func plotWidth(for signal: MFFSignalData) -> CGFloat {
        let sampleCount = signal.data.first?.count ?? 0
        let displayedPoints = max(sampleCount / sampleStride, 1)
        return max(CGFloat(displayedPoints) * CGFloat(timeScale), 600)
    }

    private var visibleHorizontalRange: ClosedRange<CGFloat> {
        let buffer = horizontalViewportWidth * 0.15
        let lower = max(horizontalOffset - buffer, 0)
        let upper = horizontalOffset + horizontalViewportWidth + buffer
        return lower...upper
    }

    private func sampleIndex(forContentX x: CGFloat, in signal: MFFSignalData) -> Int {
        let sampleCount = signal.data.first?.count ?? 1
        let plottedIndex = x / max(CGFloat(timeScale), 0.001)
        let sample = Int((plottedIndex * CGFloat(sampleStride)).rounded())
        return min(max(sample, 0), max(sampleCount - 1, 0))
    }

    private func contentX(forSample sample: Int) -> CGFloat {
        (CGFloat(sample) / CGFloat(sampleStride)) * CGFloat(timeScale)
    }

    private func topomapValues(at sample: Int, in signal: MFFSignalData) -> [Double] {
        signal.data.map { channel in
            sample < channel.count ? Double(channel[sample]) : 0
        }
    }

    private func jumpToEvent(_ event: MFFEvent, in signal: MFFSignalData) {
        selectedEventID = event.id
        let plotWidth = plotWidth(for: signal)
        let plottedIndex = event.beginTimeSeconds * signal.samplingRate / Double(sampleStride)
        let targetX = CGFloat(plottedIndex) * CGFloat(timeScale)
        let viewportCenter = max(horizontalViewportWidth / 2, 1)
        let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
        let clampedOffset = min(max(targetX - viewportCenter, 0), maxOffset)

        isSyncingSliderFromScroll = true
        horizontalJumpValue = maxOffset > 0 ? Double(clampedOffset / maxOffset) : 0
        isSyncingSliderFromScroll = false
        horizontalScrollPosition.scrollTo(x: clampedOffset)
    }

    private func jumpToSegment(_ result: SegmentHealthResult) {
        guard let signal = currentSegmentHealthSignal(),
              let sampleCount = signal.data.first?.count,
              sampleCount > 0 else {
            return
        }

        let lower = min(max(result.startSample, 0), sampleCount - 1)
        let upper = min(max(result.endSample, lower), sampleCount - 1)
        selectedSampleRange = lower...upper
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        selectedEventID = nil

        let plotWidth = plotWidth(for: signal)
        let segmentCenterX = (contentX(forSample: lower) + contentX(forSample: upper + 1)) / 2
        let viewportCenter = max(horizontalViewportWidth / 2, 1)
        let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
        let clampedOffset = min(max(segmentCenterX - viewportCenter, 0), maxOffset)

        isSyncingSliderFromScroll = true
        horizontalJumpValue = maxOffset > 0 ? Double(clampedOffset / maxOffset) : 0
        isSyncingSliderFromScroll = false
        horizontalScrollPosition.scrollTo(x: clampedOffset)
    }

    private func formattedEventTime(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%06.3f", minutes, remainingSeconds)
        }
        return String(format: "%.3fs", seconds)
    }

    private func groupedEventSummaries(_ events: [MFFEvent]) -> [EventSummary] {
        Dictionary(grouping: events, by: \.code)
            .map { EventSummary(code: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count
                    ? lhs.code.localizedStandardCompare(rhs.code) == .orderedAscending
                    : lhs.count > rhs.count
            }
    }

    private func filteredEvents(_ events: [MFFEvent]) -> [MFFEvent] {
        selectedEventCodes.isEmpty ? events : events.filter { selectedEventCodes.contains($0.code) }
    }

    private func toggleEventCode(_ code: String) {
        if selectedEventCodes.contains(code) {
            selectedEventCodes.remove(code)
        } else {
            selectedEventCodes.insert(code)
        }
    }
}

// MARK: - Supporting views

/// Which channels the scalp-topography correlation uses. Bad channels are always
/// excluded. Cluster (region-of-interest) options will be added once channel
/// clusters are implemented (see [[ChannelCluster]]).
private enum ArtifactTopographyChannelScope: CaseIterable, Hashable, Identifiable {
    case allGood

    var id: Self { self }

    var label: String {
        switch self {
        case .allGood: return "All good channels"
        }
    }
}

/// Snapshot of the artifact-template controls that affect a full scan. Topography
/// mode/scope are excluded because they refresh live without a rescan.
private struct ArtifactScanSignature: Equatable {
    var eventCode: String
    var clickedChannel: Int?
    var channelScope: ArtifactTemplateChannelScope
    var customChannels: String
    var threshold: Double
    var windowSeconds: Double
    var downsampleRate: Double
    var mergeWindowSeconds: Double
    var polarity: ArtifactTemplatePolarity
    var range: ClosedRange<Int>?
}

/// A toolbar button face that draws its own fixed-size rounded-rect chrome so
/// that every control — whether a plain Button or a Menu — renders at an
/// identical size regardless of how the system button/menu styles add padding.
struct ToolbarIcon: View {
    let name: String
    var isActive: Bool = false

    private let size = CGSize(width: 77, height: 58)

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 33, height: 33)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive
                          ? Color.accentColor
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
    }
}

private extension View {
    /// Renders a toolbar button as solid blue (`borderedProminent`) when its
    /// feature is active, and as a plain bordered button otherwise.
    @ViewBuilder
    func activeToggle(_ isActive: Bool) -> some View {
        if isActive {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct ICADebugSignalStats {
    let channelCount: Int
    let sampleCount: Int
    let sampledValueCount: Int
    let mean: Double
    let rms: Double
    let p50Abs: Double
    let p95Abs: Double
    let p99Abs: Double
    let maxAbs: Double
    let maxAbsChannel: Int?

    var summary: String {
        let channelText = maxAbsChannel.map { "Ch \($0 + 1)" } ?? "n/a"
        return [
            "\(channelCount) ch",
            "\(sampleCount) samples",
            "sampled \(sampledValueCount)",
            "mean \(Self.format(mean))",
            "RMS \(Self.format(rms))",
            "p50|x| \(Self.format(p50Abs))",
            "p95|x| \(Self.format(p95Abs))",
            "p99|x| \(Self.format(p99Abs))",
            "max|x| \(Self.format(maxAbs)) (\(channelText))"
        ].joined(separator: "; ")
    }

    static func make(signal: MFFSignalData, sampleRange: ClosedRange<Int>? = nil) -> Self {
        let channelCount = signal.data.count
        let sampleCount = signal.data.first?.count ?? 0
        guard channelCount > 0, sampleCount > 0 else {
            return ICADebugSignalStats(
                channelCount: channelCount,
                sampleCount: sampleCount,
                sampledValueCount: 0,
                mean: 0,
                rms: 0,
                p50Abs: 0,
                p95Abs: 0,
                p99Abs: 0,
                maxAbs: 0,
                maxAbsChannel: nil
            )
        }

        let range = sampleRange ?? 0...(sampleCount - 1)
        let lower = min(max(range.lowerBound, 0), sampleCount - 1)
        let upper = min(max(range.upperBound, lower), sampleCount - 1)
        let rangeCount = upper - lower + 1
        let sampleBudget = 200_000
        let sampleStride = max((rangeCount * max(channelCount, 1)) / sampleBudget, 1)

        var sampledAbsValues: [Double] = []
        sampledAbsValues.reserveCapacity(min(sampleBudget, rangeCount * channelCount / sampleStride + channelCount))
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        var maxAbs = 0.0
        var maxAbsChannel: Int?

        for channelIndex in signal.data.indices {
            let channel = signal.data[channelIndex]
            guard !channel.isEmpty else { continue }
            let channelUpper = min(upper, channel.count - 1)
            guard channelUpper >= lower else { continue }

            for sample in stride(from: lower, through: channelUpper, by: sampleStride) {
                let value = Double(channel[sample])
                guard value.isFinite else { continue }
                let absValue = abs(value)
                sampledAbsValues.append(absValue)
                sum += value
                sumSquares += value * value
                count += 1

                if absValue > maxAbs {
                    maxAbs = absValue
                    maxAbsChannel = channelIndex
                }
            }
        }

        guard count > 0 else {
            return ICADebugSignalStats(
                channelCount: channelCount,
                sampleCount: sampleCount,
                sampledValueCount: 0,
                mean: 0,
                rms: 0,
                p50Abs: 0,
                p95Abs: 0,
                p99Abs: 0,
                maxAbs: 0,
                maxAbsChannel: nil
            )
        }

        sampledAbsValues.sort()
        return ICADebugSignalStats(
            channelCount: channelCount,
            sampleCount: sampleCount,
            sampledValueCount: count,
            mean: sum / Double(count),
            rms: sqrt(sumSquares / Double(count)),
            p50Abs: percentile(sampledAbsValues, fraction: 0.50),
            p95Abs: percentile(sampledAbsValues, fraction: 0.95),
            p99Abs: percentile(sampledAbsValues, fraction: 0.99),
            maxAbs: maxAbs,
            maxAbsChannel: maxAbsChannel
        )
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let position = min(max(fraction, 0), 1) * Double(sortedValues.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sortedValues.count - 1)
        let weight = position - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "nan" }
        if abs(value) >= 100 {
            return String(format: "%.1f uV", value)
        }
        if abs(value) >= 10 {
            return String(format: "%.2f uV", value)
        }
        return String(format: "%.3f uV", value)
    }
}

private struct HorizontalViewport: Equatable {
    let offsetX: CGFloat
    let width: CGFloat
}

private struct SegmentHealthBand: View {
    let result: SegmentHealthResult
    let showsMouseOverHealth: Bool
    @State private var showsDetails = false

    var body: some View {
        Rectangle()
            .fill(result.grade.color.opacity(result.grade.segmentOverlayOpacity))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(result.grade.color.opacity(0.28))
                    .frame(width: result.grade == .good ? 0 : 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                guard showsMouseOverHealth else {
                    showsDetails = false
                    return
                }
                showsDetails = hovering
            }
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                SegmentHealthPopover(result: result)
            }
            .onChange(of: showsMouseOverHealth) { _, isEnabled in
                if !isEnabled {
                    showsDetails = false
                }
            }
            .accessibilityLabel("Segment health \(result.goodPercentage) percent good")
    }
}

private struct SegmentHealthDetailsView: View {
    let results: [SegmentHealthResult]
    let isAnalyzing: Bool
    let progress: Double
    let statusMessage: String?
    let onRefresh: () -> Void
    let onSave: () -> Void
    let onJump: (SegmentHealthResult) -> Void
    let onClose: () -> Void

    private var gradeCounts: [(ChannelHealthGrade, Int)] {
        ChannelHealthGrade.allHealthGrades.map { grade in
            (grade, results.filter { $0.grade == grade }.count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Segment Health")
                        .font(.title3.weight(.semibold))
                    Text("\(results.count) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    ForEach(gradeCounts, id: \.0) { grade, count in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(grade.color)
                                .frame(width: 8, height: 8)
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if isAnalyzing {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    onRefresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isAnalyzing)

                Button {
                    onSave()
                } label: {
                    Label("Save Metrics JSON...", systemImage: "square.and.arrow.down")
                }
                .disabled(results.isEmpty || isAnalyzing)

                Button("Close") {
                    onClose()
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(spacing: 0) {
                SegmentHealthTableHeader()

                Divider()

                if results.isEmpty {
                    ContentUnavailableView(
                        "No Segment Health",
                        systemImage: "rectangle.split.3x1",
                        description: Text(isAnalyzing ? "Scoring segments..." : "Refresh to score the current signal.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results) { result in
                                SegmentHealthTableRow(
                                    result: result,
                                    onJump: {
                                        onJump(result)
                                    }
                                )
                                Divider()
                            }
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            }
        }
        .padding(20)
        .frame(minWidth: 880, minHeight: 520)
    }
}

private struct SegmentHealthTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Segment")
                .frame(width: 78, alignment: .leading)
            Text("Category")
                .frame(width: 145, alignment: .leading)
            Text("Time")
                .frame(width: 170, alignment: .leading)
            Text("Health")
                .frame(width: 96, alignment: .leading)
            Text("Summary")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Jump")
                .frame(width: 64, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct SegmentHealthTableRow: View {
    let result: SegmentHealthResult
    let onJump: () -> Void
    @State private var showsDetails = false
    @State private var pinsDetails = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(result.segmentIndex + 1)")
                .font(.caption.monospacedDigit())
                .frame(width: 78, alignment: .leading)

            Text(result.category)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 145, alignment: .leading)

            Text(segmentTimeText(result))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)

            HStack(spacing: 6) {
                Circle()
                    .fill(result.grade.color)
                    .frame(width: 9, height: 9)
                Text("\(result.goodPercentage)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(result.grade.color)
            }
            .frame(width: 96, alignment: .leading)

            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onJump()
            } label: {
                Label("Jump", systemImage: "arrow.right.to.line")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Jump to this segment in the waveform viewer")
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHovered || pinsDetails ? result.grade.color.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                showsDetails = true
            } else if !pinsDetails {
                showsDetails = false
            }
        }
        .onTapGesture {
            pinsDetails.toggle()
            showsDetails = pinsDetails
        }
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            SegmentHealthPopover(result: result)
        }
        .onChange(of: showsDetails) { _, isShowing in
            if !isShowing {
                pinsDetails = false
            }
        }
    }

    private func segmentTimeText(_ result: SegmentHealthResult) -> String {
        let start = Self.formatSeconds(result.startTimeSeconds)
        let end = Self.formatSeconds(result.endTimeSeconds)
        return "\(start)-\(end)"
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remaining = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%05.2f", minutes, remaining)
        }
        return String(format: "%.2fs", seconds)
    }
}

private struct SegmentHealthPopover: View {
    let result: SegmentHealthResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Segment \(result.segmentIndex + 1)")
                        .font(.headline)
                    Text(result.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(result.goodPercentage)% good")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(result.grade.color)
            }

            HStack(spacing: 8) {
                Text(segmentWindowText(result))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if result.contributingEpochCount > 1 {
                    Text("\(result.contributingEpochCount) epochs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.metrics) { metric in
                    SegmentHealthMetricRow(metric: metric)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func segmentWindowText(_ result: SegmentHealthResult) -> String {
        String(
            format: "%.2fs-%.2fs (%.2fs)",
            result.startTimeSeconds,
            result.endTimeSeconds,
            result.durationSeconds
        )
    }
}

private struct SegmentHealthMetricRow: View {
    let metric: SegmentHealthMetric

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(metric.grade.color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(metric.grade.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(metric.grade.color)
                }
                Text(metric.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ChannelHealthBadge: View {
    let result: ChannelHealthResult?
    let isAnalyzing: Bool
    @State private var showsDetails = false
    @State private var pinsDetails = false

    var body: some View {
        Group {
            if let result {
                Circle()
                    .fill(result.grade.color)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                    }
            } else if isAnalyzing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 22, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill((result?.grade.color ?? Color.secondary).opacity(result == nil ? 0.06 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder((result?.grade.color ?? Color.secondary).opacity(result == nil ? 0.20 : 0.35), lineWidth: 0.75)
        )
        .onHover { hovering in
            guard result != nil else { return }
            if hovering {
                showsDetails = true
            } else if !pinsDetails {
                showsDetails = false
            }
        }
        .onTapGesture {
            guard result != nil else { return }
            pinsDetails.toggle()
            showsDetails = pinsDetails
        }
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            if let result {
                ChannelHealthPopover(result: result)
            }
        }
        .onChange(of: showsDetails) { _, isShowing in
            if !isShowing {
                pinsDetails = false
            }
        }
        .accessibilityLabel(result.map { "Channel health \($0.goodPercentage) percent good" } ?? "Channel health pending")
    }
}

private struct ChannelHealthPopover: View {
    let result: ChannelHealthResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ch \(result.channelIndex + 1)")
                    .font(.headline)
                Spacer()
                Text("\(result.goodPercentage)% good")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(result.grade.color)
            }

            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.metrics) { metric in
                    ChannelHealthMetricRow(metric: metric)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}

private struct ChannelHealthMetricRow: View {
    let metric: ChannelHealthMetric

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(metric.grade.color)
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(metric.grade.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(metric.grade.color)
                }
                Text(metric.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension ChannelHealthGrade {
    static var allHealthGrades: [ChannelHealthGrade] {
        [.good, .watch, .poor]
    }

    var color: Color {
        switch self {
        case .good: return .green
        case .watch: return .yellow
        case .poor: return .red
        }
    }

    var segmentOverlayOpacity: Double {
        switch self {
        case .good: return 0.08
        case .watch: return 0.11
        case .poor: return 0.12
        }
    }
}

private struct EventSummary: Identifiable {
    let code: String
    let count: Int
    var id: String { code }
}

nonisolated struct EpochSegment: Identifiable, Sendable {
    let startSample: Int
    let endSample: Int
    let stimulusOffsetSamples: Int
    let category: String
    let sourceCode: String
    let sourceTimeSeconds: Double
    let colorIndex: Int
    let contributingEpochCount: Int

    var id: String {
        "\(startSample)-\(endSample)-\(category)-\(sourceCode)-\(sourceTimeSeconds)-\(contributingEpochCount)"
    }
}

private struct EpochCategorySummary: Identifiable {
    let category: String
    let count: Int
    let color: Color

    var id: String { category }
}

private struct AveragedTopomapSample: Identifiable {
    let category: String
    let sample: Int
    let latencySeconds: Double
    let colorIndex: Int

    var id: String { "\(category)-\(sample)" }
}

private struct PSABuildResult {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let message: String
}

private struct MFFExportSnapshot: Sendable {
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let kind: MFFExportKind
}

private struct ICAProgressUpdate: Sendable {
    var fraction: Double
    var message: String
}

private struct ArtifactTemplateFieldLabel: View {
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

private struct ArtifactCleaningPreviewButton: View {
    let artifact: DefinedArtifact
    let beforeSignal: MFFSignalData
    let afterSignal: MFFSignalData?
    let layout: SensorLayout?

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
        .help("Preview artifact cleanup")
        .onHover { hovering in
            isButtonHovered = hovering
            schedulePreviewVisibility()
        }
        .popover(isPresented: previewPresentation, arrowEdge: .trailing) {
            ArtifactCleaningPreview(
                artifact: artifact,
                beforeSignal: beforeSignal,
                afterSignal: afterSignal,
                layout: layout
            )
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

private struct ArtifactOBSOptionsButton: View {
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

private struct ArtifactOBSOptionsSheet: View {
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

private struct ArtifactCleaningPreviewData: Sendable {
    var beforeAverage: ArtifactTemplateAverage?
    var afterAverage: ArtifactTemplateAverage?
    var beforeTopographyValues: [Double]?
    var afterTopographyValues: [Double]?
    var topographyScale: Double?
    var waveformScaleMicrovolts: Float?
    var afterScaleMicrovolts: Float?
    var reductionMetrics: ArtifactCleaningReductionMetrics?
}

private struct ArtifactCleaningReductionMetrics: Sendable {
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

private struct ArtifactCleaningPreview: View {
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

private enum ArtifactTemplateChannelScope: String, CaseIterable, Identifiable {
    case clickedChannel = "Clicked Channel"
    case ocularChannels = "Ocular Channels"
    case visibleChannels = "Visible Channels"
    case allChannels = "All Channels"
    case specificChannels = "Specific Channels"

    var id: String { rawValue }
}

private enum ArtifactDetectionMethod: String, CaseIterable, Identifiable {
    case threshold = "Threshold"
    case template = "Template"
    case ica = "ICA"

    var id: String { rawValue }
}

nonisolated private enum EyeArtifactKind {
    case blink
    case movement

    var eventCode: String {
        switch self {
        case .blink: return "Eye Blink"
        case .movement: return "Eye Movement"
        }
    }

    var idComponent: String {
        switch self {
        case .blink: return "eye-blink"
        case .movement: return "eye-movement"
        }
    }
}

nonisolated private enum EyeArtifactThresholdDetector {
    private static let thresholdMicrovolts: Float = 150
    private static let minimumDurationSeconds = 0.05
    private static let mergeGapSeconds = 0.25

    static func detect(
        kind: EyeArtifactKind,
        channels: [[Float]],
        samplingRate: Double,
        duration: TimeInterval
    ) -> [MFFEvent] {
        guard samplingRate > 0, duration > 0, let sampleCount = channels.first?.count, sampleCount > 0 else {
            return []
        }

        let candidateChannels = ocularChannelIndices(kind: kind, channelCount: channels.count)
            .filter { $0 < channels.count && channels[$0].count == sampleCount }
        guard !candidateChannels.isEmpty else { return [] }

        let minimumSamples = max(Int((minimumDurationSeconds * samplingRate).rounded()), 1)
        let mergeGapSamples = max(Int((mergeGapSeconds * samplingRate).rounded()), 1)

        var intervals: [ClosedRange<Int>] = []
        var activeStart: Int?
        var lastAboveThreshold: Int?

        for sample in 0..<sampleCount {
            let exceedsThreshold = candidateChannels.contains { channelIndex in
                abs(channels[channelIndex][sample]) >= thresholdMicrovolts
            }

            if exceedsThreshold {
                if activeStart == nil {
                    activeStart = sample
                }
                lastAboveThreshold = sample
            } else if let start = activeStart, let end = lastAboveThreshold {
                if end - start + 1 >= minimumSamples {
                    append(start...end, to: &intervals, mergeGapSamples: mergeGapSamples)
                }
                activeStart = nil
                lastAboveThreshold = nil
            }
        }

        if let start = activeStart, let end = lastAboveThreshold, end - start + 1 >= minimumSamples {
            append(start...end, to: &intervals, mergeGapSamples: mergeGapSamples)
        }

        return intervals.enumerated().map { index, interval in
            let peakSample = peakSample(in: interval, channels: channels, candidateChannels: candidateChannels)
            let time = min(max(Double(peakSample) / samplingRate, 0), duration)
            return MFFEvent(
                id: "artifact-\(kind.idComponent)-threshold-\(index)-\(peakSample)",
                code: kind.eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: "Artifact Detection"
            )
        }
    }

    private static func ocularChannelIndices(kind: EyeArtifactKind, channelCount: Int) -> [Int] {
        // EGI channel numbers are 1-based; signal arrays are 0-based.
        let oneBasedChannels: [Int]
        switch (kind, channelCount) {
        case (.blink, 241...):
            oneBasedChannels = [18, 37, 238, 241]
        case (.blink, 127...):
            oneBasedChannels = [8, 25, 126, 127]
        case (.movement, 252...):
            oneBasedChannels = [226, 252]
        case (.movement, 128...):
            oneBasedChannels = [1, 32, 125, 128]
        default:
            oneBasedChannels = Array(1...min(channelCount, 4))
        }

        return oneBasedChannels.map { $0 - 1 }
    }

    private static func append(
        _ interval: ClosedRange<Int>,
        to intervals: inout [ClosedRange<Int>],
        mergeGapSamples: Int
    ) {
        guard let last = intervals.last else {
            intervals.append(interval)
            return
        }

        if interval.lowerBound - last.upperBound <= mergeGapSamples {
            intervals[intervals.count - 1] = last.lowerBound...interval.upperBound
        } else {
            intervals.append(interval)
        }
    }

    private static func peakSample(
        in interval: ClosedRange<Int>,
        channels: [[Float]],
        candidateChannels: [Int]
    ) -> Int {
        var peakSample = interval.lowerBound
        var peakValue: Float = 0

        for sample in interval {
            for channelIndex in candidateChannels {
                let value = abs(channels[channelIndex][sample])
                if value > peakValue {
                    peakValue = value
                    peakSample = sample
                }
            }
        }

        return peakSample
    }
}

private struct EventMarkerStyle {
    let color: Color
    let stemTopY: CGFloat
}

private struct WaveformPlot: View {
    let samples: [Float]
    let amplitudeScale: Double
    let timeScale: Double
    let sampleStride: Int
    let visibleRange: ClosedRange<CGFloat>
    let nominalHeight: CGFloat
    var color: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard samples.count > sampleStride else { return }

            let xScale = CGFloat(timeScale)
            let lowerVisibleIndex = max(Int(floor(visibleRange.lowerBound / max(xScale, 0.001))) - 2, 0)
            let upperVisibleIndex = Int(ceil(visibleRange.upperBound / max(xScale, 0.001))) + 2

            let firstSampleIndex = min(lowerVisibleIndex * sampleStride, samples.count - 1)
            let lastSampleIndex = min(max(upperVisibleIndex * sampleStride, firstSampleIndex + sampleStride), samples.count - 1)
            guard lastSampleIndex > firstSampleIndex else { return }

            let midY = size.height / 2
            let pointsPerMicrovolt = (nominalHeight / 2) / max(amplitudeScale, 1)

            var path = Path()
            let firstPlottedIndex = firstSampleIndex / sampleStride
            path.move(
                to: CGPoint(
                    x: CGFloat(firstPlottedIndex) * xScale,
                    y: midY - CGFloat(samples[firstSampleIndex]) * pointsPerMicrovolt
                )
            )

            for sampleIndex in stride(from: firstSampleIndex + sampleStride, through: lastSampleIndex, by: sampleStride) {
                let plottedIndex = sampleIndex / sampleStride
                path.addLine(
                    to: CGPoint(
                        x: CGFloat(plottedIndex) * xScale,
                        y: midY - CGFloat(samples[sampleIndex]) * pointsPerMicrovolt
                    )
                )
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: visibleRange.lowerBound, y: midY))
            baseline.addLine(to: CGPoint(x: visibleRange.upperBound, y: midY))

            context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 0.75)
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

/// One channel with every category average overlaid (each in its category color),
/// aligned on the epoch latency axis.
private struct OverlaidCategoryChannelPlot: View {
    let data: [[Float]]
    let channelIndex: Int
    let segments: [EpochSegment]
    let colors: [Color]
    let amplitudeScale: Double
    var highlightRelativeSample: Int? = nil

    var body: some View {
        Canvas { context, size in
            guard channelIndex < data.count, let first = segments.first else { return }
            let channel = data[channelIndex]

            let epochLength = max(first.endSample - first.startSample + 1, 1)
            guard epochLength > 1 else { return }

            let midY = size.height / 2
            let pointsPerMicrovolt = (size.height * 0.42) / max(amplitudeScale, 1)
            let xScale = size.width / CGFloat(max(epochLength - 1, 1))
            let sampleStep = max(epochLength / max(Int(size.width), 1), 1)

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.28)), lineWidth: 0.75)

            let stimulusX = CGFloat(first.stimulusOffsetSamples) * xScale
            var stimulus = Path()
            stimulus.move(to: CGPoint(x: stimulusX, y: 0))
            stimulus.addLine(to: CGPoint(x: stimulusX, y: size.height))
            context.stroke(stimulus, with: .color(.green.opacity(0.7)), lineWidth: 1)

            if let highlightRelativeSample {
                let clamped = min(max(highlightRelativeSample, 0), epochLength - 1)
                let cursorX = CGFloat(clamped) * xScale
                var cursor = Path()
                cursor.move(to: CGPoint(x: cursorX, y: 0))
                cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
                context.stroke(cursor, with: .color(.yellow), lineWidth: 1.5)
            }

            for (index, segment) in segments.enumerated() {
                guard segment.startSample >= 0, segment.endSample < channel.count else { continue }
                let color = index < colors.count ? colors[index] : .accentColor

                var path = Path()
                path.move(
                    to: CGPoint(
                        x: 0,
                        y: midY - CGFloat(channel[segment.startSample]) * pointsPerMicrovolt
                    )
                )
                for localSample in stride(from: sampleStep, through: epochLength - 1, by: sampleStep) {
                    let sample = segment.startSample + localSample
                    guard sample < channel.count else { break }
                    path.addLine(
                        to: CGPoint(
                            x: CGFloat(localSample) * xScale,
                            y: midY - CGFloat(channel[sample]) * pointsPerMicrovolt
                        )
                    )
                }
                context.stroke(path, with: .color(color), lineWidth: 1.1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

/// Compact wrapping legend of colored category labels.
private struct FlowLegend: View {
    let items: [(String, Color)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            legendRow
            ScrollView(.horizontal, showsIndicators: false) { legendRow }
        }
    }

    private var legendRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.1)
                        .frame(width: 9, height: 9)
                    Text(item.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct ButterflyConditionPlot: View {
    let data: [[Float]]
    let segment: EpochSegment
    let hiddenChannels: Set<Int>
    let amplitudeScale: Double
    let color: Color
    var highlightRelativeSample: Int? = nil

    var body: some View {
        Canvas { context, size in
            guard segment.startSample >= 0,
                  segment.endSample >= segment.startSample,
                  !data.isEmpty else { return }

            let epochLength = segment.endSample - segment.startSample + 1
            guard epochLength > 1 else { return }

            let midY = size.height / 2
            let pointsPerMicrovolt = (size.height * 0.42) / max(amplitudeScale, 1)
            let xScale = size.width / CGFloat(max(epochLength - 1, 1))
            let sampleStep = max(epochLength / max(Int(size.width), 1), 1)

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.28)), lineWidth: 0.75)

            let stimulusX = CGFloat(segment.stimulusOffsetSamples) * xScale
            var stimulus = Path()
            stimulus.move(to: CGPoint(x: stimulusX, y: 0))
            stimulus.addLine(to: CGPoint(x: stimulusX, y: size.height))
            context.stroke(stimulus, with: .color(.green.opacity(0.75)), lineWidth: 1)

            // Shared topography cursor.
            if let highlightRelativeSample {
                let clamped = min(max(highlightRelativeSample, 0), epochLength - 1)
                let cursorX = CGFloat(clamped) * xScale
                var cursor = Path()
                cursor.move(to: CGPoint(x: cursorX, y: 0))
                cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
                context.stroke(cursor, with: .color(.yellow), lineWidth: 1.5)
            }

            for channelIndex in data.indices where !hiddenChannels.contains(channelIndex) {
                let channel = data[channelIndex]
                guard segment.endSample < channel.count else { continue }

                var path = Path()
                path.move(
                    to: CGPoint(
                        x: 0,
                        y: midY - CGFloat(channel[segment.startSample]) * pointsPerMicrovolt
                    )
                )

                for localSample in stride(from: sampleStep, through: epochLength - 1, by: sampleStep) {
                    let sample = segment.startSample + localSample
                    path.addLine(
                        to: CGPoint(
                            x: CGFloat(localSample) * xScale,
                            y: midY - CGFloat(channel[sample]) * pointsPerMicrovolt
                        )
                    )
                }

                context.stroke(path, with: .color(color.opacity(0.22)), lineWidth: 0.7)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct ArtifactTemplateAveragePlot: View {
    let average: ArtifactTemplateAverage
    let primaryChannel: Int?
    let highlightedChannels: Set<Int>
    var fixedScaleMicrovolts: Float? = nil
    var maximumBackgroundChannels: Int = .max
    var usesAmplitudeWeightedOpacity = false

    var body: some View {
        Canvas { context, size in
            guard let sampleCount = average.allChannelSamples.first?.count, sampleCount > 1 else { return }

            let midY = size.height / 2
            let maxAbs = max(fixedScaleMicrovolts ?? average.allChannelSamples.flatMap { $0.map(abs) }.max() ?? 1, 1)
            let yScale = (size.height * 0.42) / CGFloat(maxAbs)
            let xScale = size.width / CGFloat(sampleCount - 1)
            let peakByChannel = Dictionary(uniqueKeysWithValues: average.channelSummaries.map {
                ($0.channelIndex, $0.peakAbsoluteMicrovolts)
            })
            let strongestBackgroundChannels = Set(
                average.channelSummaries
                    .map(\.channelIndex)
                    .filter { primaryChannel != $0 && !highlightedChannels.contains($0) }
                    .prefix(maximumBackgroundChannels)
            )

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.28)), lineWidth: 0.75)

            for channelIndex in average.allChannelSamples.indices {
                let samples = average.allChannelSamples[channelIndex]
                guard samples.count == sampleCount else { continue }

                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * yScale))
                let sampleStep = max(sampleCount / max(Int(size.width), 1), 1)
                for sample in stride(from: sampleStep, through: sampleCount - 1, by: sampleStep) {
                    path.addLine(
                        to: CGPoint(
                            x: CGFloat(sample) * xScale,
                            y: midY - CGFloat(samples[sample]) * yScale
                        )
                    )
                }

                let isPrimary = primaryChannel == channelIndex
                let isHighlighted = highlightedChannels.contains(channelIndex)
                if !isPrimary,
                   !isHighlighted,
                   maximumBackgroundChannels != .max,
                   !strongestBackgroundChannels.contains(channelIndex) {
                    continue
                }

                let strokeColor: Color
                let lineWidth: CGFloat
                if isPrimary {
                    strokeColor = .blue
                    lineWidth = 1.75
                } else if isHighlighted {
                    strokeColor = .accentColor
                    lineWidth = 1.35
                } else {
                    let opacity: Double
                    if usesAmplitudeWeightedOpacity {
                        let relativePeak = Double(max(peakByChannel[channelIndex] ?? 0, 0) / maxAbs)
                        opacity = min(max(0.06 + relativePeak * 0.18, 0.06), 0.24)
                    } else {
                        opacity = 0.22
                    }
                    strokeColor = .secondary.opacity(opacity)
                    lineWidth = 0.65
                }
                context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct ICATimeCoursePreview: View {
    let samples: [Double]
    let visibleRange: ClosedRange<Int>?
    @State private var isExpanded = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        ICATimeCoursePlot(samples: samples, visibleRange: visibleRange)
            .frame(height: 64)
            .contentShape(Rectangle())
            .onHover { isHovering in
                hoverTask?.cancel()
                if isHovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            isExpanded = true
                        }
                    }
                } else {
                    isExpanded = false
                }
            }
            .onDisappear {
                hoverTask?.cancel()
            }
            .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Component Time Course")
                        .font(.headline)
                    ICATimeCoursePlot(samples: samples, visibleRange: visibleRange)
                        .frame(width: 720, height: 260)
                }
                .padding(14)
            }
            .help("Hover for 2 seconds to expand the component time course.")
    }
}

private struct ICATimeCoursePlot: View {
    let samples: [Double]
    let visibleRange: ClosedRange<Int>?

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1,
                  let range = clippedRange(visibleRange, count: samples.count),
                  range.upperBound > range.lowerBound else { return }

            let midY = size.height / 2
            let scale = robustScale(samples, in: range)
            let yScale = (size.height * 0.42) / CGFloat(scale.amplitude)
            let binCount = max(Int(size.width.rounded(.down)), 2)
            let visibleCount = range.upperBound - range.lowerBound + 1

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.75)

            var trace = Path()
            var didStartTrace = false

            for bin in 0..<binCount {
                let start = range.lowerBound + bin * visibleCount / binCount
                let end = max(start + 1, range.lowerBound + (bin + 1) * visibleCount / binCount)
                let boundedEnd = min(end, samples.count)
                var sum = 0.0
                var count = 0

                for index in start..<boundedEnd {
                    let value = samples[index]
                    guard value.isFinite else { continue }
                    sum += clamp(value - scale.center, to: -scale.amplitude...scale.amplitude)
                    count += 1
                }

                guard count > 0 else { continue }

                let x = CGFloat(bin) / CGFloat(max(binCount - 1, 1)) * size.width
                let meanY = midY - CGFloat(sum / Double(count)) * yScale
                if didStartTrace {
                    trace.addLine(to: CGPoint(x: x, y: meanY))
                } else {
                    trace.move(to: CGPoint(x: x, y: meanY))
                    didStartTrace = true
                }
            }

            context.stroke(trace, with: .color(.accentColor), lineWidth: 1.2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private func clippedRange(_ range: ClosedRange<Int>?, count: Int) -> ClosedRange<Int>? {
        guard count > 1 else { return nil }
        let fallback = 0...(count - 1)
        guard let range else { return fallback }
        let lower = min(max(range.lowerBound, 0), count - 1)
        let upper = min(max(range.upperBound, lower), count - 1)
        return lower...upper
    }

    private func robustScale(_ values: [Double], in range: ClosedRange<Int>) -> (center: Double, amplitude: Double) {
        guard !values.isEmpty, range.upperBound >= range.lowerBound else {
            return (0, 1)
        }

        let visibleCount = range.upperBound - range.lowerBound + 1
        let edgeTrim = min(visibleCount / 100, 100)
        let lowerBound = min(range.lowerBound + edgeTrim, values.count - 1)
        let upperBound = min(max(range.upperBound - edgeTrim + 1, lowerBound + 1), values.count)
        let scaleStride = max((upperBound - lowerBound) / 5_000, 1)
        var scaledValues: [Double] = []
        scaledValues.reserveCapacity((upperBound - lowerBound) / scaleStride + 1)

        for index in stride(from: lowerBound, to: upperBound, by: scaleStride) {
            let value = values[index]
            if value.isFinite {
                scaledValues.append(value)
            }
        }

        guard scaledValues.count > 1 else {
            let fallback = values.first(where: { $0.isFinite }) ?? 0
            return (fallback, 1)
        }

        scaledValues.sort()
        let low = percentile(sortedValues: scaledValues, fraction: 0.02)
        let high = percentile(sortedValues: scaledValues, fraction: 0.98)
        let center = percentile(sortedValues: scaledValues, fraction: 0.50)
        let amplitude = max(abs(high - center), abs(low - center), 1e-9)
        return (center, amplitude)
    }

    private func percentile(sortedValues: [Double], fraction: Double) -> Double {
        guard let first = sortedValues.first else {
            return 0
        }
        guard sortedValues.count > 1 else {
            return first
        }

        let position = min(max(fraction, 0), 1) * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(lowerIndex + 1, sortedValues.count - 1)
        let weight = position - Double(lowerIndex)
        return sortedValues[lowerIndex] * (1 - weight) + sortedValues[upperIndex] * weight
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct EventTrackView: View {
    let events: [MFFEvent]
    let samplingRate: Double
    let timeScale: Double
    let sampleStride: Int
    /// True horizontal scroll offset of the waveform content, used so event
    /// markers line up with the waveform cursor.
    let contentOffset: CGFloat
    let visibleRange: ClosedRange<CGFloat>
    let viewportWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))

            Canvas { context, size in
                guard samplingRate > 0 else { return }
                let baselineY = size.height - 16
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: baselineY))
                baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
                context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 1)

                for event in visibleEvents {
                    let x = localXPosition(for: event)
                    let style = style(for: event)
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: style.stemTopY))
                    marker.addLine(to: CGPoint(x: x, y: baselineY))
                    context.stroke(marker, with: .color(style.color), lineWidth: 1)
                }
            }

            ForEach(visibleEvents) { event in
                let x = localXPosition(for: event)
                let style = style(for: event)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.code)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(style.color.opacity(0.15), in: Capsule())
                    Text(String(format: "%.3fs", event.beginTimeSeconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(style.color)
                .offset(x: min(max(x + 4, 0), max(viewportWidth - 70, 0)), y: 4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    private var visibleEvents: [MFFEvent] {
        events.filter { visibleRange.contains(globalXPosition(for: $0)) }
    }

    private func globalXPosition(for event: MFFEvent) -> CGFloat {
        guard samplingRate > 0 else { return 0 }
        let plottedIndex = event.beginTimeSeconds * samplingRate / Double(sampleStride)
        return CGFloat(plottedIndex) * CGFloat(timeScale)
    }

    private func localXPosition(for event: MFFEvent) -> CGFloat {
        // Position relative to the true scroll offset (not the buffered
        // culling range) so markers align with the waveform cursor.
        globalXPosition(for: event) - contentOffset
    }

    private func style(for event: MFFEvent) -> EventMarkerStyle {
        let sources = Array(Set(events.map(\.sourceFile))).sorted()
        let sourceIndex = sources.firstIndex(of: event.sourceFile) ?? 0
        let palette: [Color] = [.orange, .blue, .green, .red, .pink, .teal, .indigo, .brown]
        return EventMarkerStyle(
            color: palette[sourceIndex % palette.count],
            stemTopY: 18 + CGFloat(sourceIndex % 3) * 10
        )
    }
}
