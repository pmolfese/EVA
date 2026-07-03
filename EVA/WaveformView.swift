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

/// Selectable MR gradient-artifact removal algorithm.
enum MRIGradientMethod: String, CaseIterable, Identifiable {
    /// Average artifact subtraction — the per-TR template in `GradientRemover`.
    case aas = "AAS"
    /// FMRIB Artifact Slice Template Removal (Niazy 2005) with OBS/ANC.
    case fastr = "FASTR"
    /// FASTR with Moosmann (2009) realignment-parameter-informed averaging.
    case moosmann = "Moosmann"
    /// FASTR with FARM (van der Meer 2010) most-correlated-epoch averaging.
    case farm = "FARM"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aas: return "AAS"
        case .fastr: return "FASTR"
        case .moosmann: return "Moosmann"
        case .farm: return "FARM"
        }
    }

    /// Whether this method runs the FASTR pipeline (slice/OBS/ANC options apply).
    var isFASTR: Bool { self == .fastr || self == .moosmann || self == .farm }
}

struct WaveformView: View {
    @ObservedObject var recording: MFFRecording

    @Environment(\.modelContext) private var modelContext
    @Environment(ChannelGoodnessSettings.self) private var goodnessSettings
    @Environment(ProcessingDefaults.self) var processingDefaults
    @Environment(BatchController.self) private var batch
    /// Guards batch auto-start to once per freshly-built (per-recording) view.
    @State private var batchStarted = false
    @Query private var markers: [UserMarker]

    @AppStorage(ToolbarButtonLabels.storageKey) private var showsToolbarButtonLabels = true

    @State private var amplitudeScale: Double = 100
    @State private var timeScale: Double = 1
    @State private var horizontalOffset: CGFloat = 0
    @State private var horizontalViewportWidth: CGFloat = 1
    @State var horizontalScrollPosition = ScrollPosition(idType: Int.self, x: 0)
    @State private var horizontalJumpValue: Double = 0
    @State private var isSyncingSliderFromScroll = false
    @State private var isCommandKeyPressed = false
    @State private var commandKeyMonitor: Any?
    @State var showsEventsPanel = false
    @State private var selectedEventID: MFFEvent.ID?
    /// Artifact event whose window is highlighted in the waveform (tap its flag).
    @State private var highlightedArtifactEvent: MFFEvent?
    @State private var highlightedArtifactColor: Color = .orange
    @State var selectedEventCodes = Set<String>()
    @State private var displayedEventsCache = WaveformDisplayedEventsCache.empty
    @State private var eventTrackSourceSummary = EventTrackSourceSummary.empty
    @State var topomapSample: Int?
    @State var selectedSampleRange: ClosedRange<Int>?
    @State var dragSelectionStartSample: Int?
    @State var dragSelectionEndSample: Int?
    @State private var eventTrackContextSample: Int?
    /// Timestamp of the last stationary click, used to detect a double-click
    /// manually inside the single waveform interaction gesture.
    @State private var lastWaveformClick: (time: Date, x: CGFloat)?
    /// Live global x of the scrolling waveform content's leading edge. Used to
    /// convert a gesture's global x into a scroll-independent content x.
    @State private var waveformContentMinX: CGFloat = 0
    @State private var detectsEyeBlinkArtifacts = false
    @State private var detectsEyeMovementArtifacts = false
    /// Raw text buffers for the threshold-panel ocular-channel override fields
    /// (kept out of the config so mid-typing doesn't reparse the entry).
    @State private var blinkChannelOverrideText = ""
    @State private var movementChannelOverrideText = ""
    @State var detectsECGArtifacts = false
    @State var showsECGDetectionSheet = false
    // BCG detection
    // BCG detection domain, extracted into an L4 store (REFACTOR.md).
    @StateObject var bcg = BCGDetectionViewModel()
    /// Stable UUID so re-running detection updates the existing DefinedArtifact rather than appending a new one.
    let bcgDefinedArtifactID = UUID()
    @State var ecgDetectionSelectedPNSChannels = Set<Int>()
    @State var ecgDetectionProxyChannels = ""
    @State var ecgProxyChannelSetID: ChannelSet.ID? = nil
    @State var ecgDetectionAlgorithm = ECGDetectionAlgorithm.panTompkins
    @State var ecgDetectionThresholdSD = 4.0
    @State var ecgDetectionMinimumRRSeconds = 0.30
    @State var ecgDetectionPolarity = ECGDetectionPolarity.either
    @State var isEstimatingECGDetection = false
    @State var ecgAlgorithmResults: [ECGDetectionAlgorithm: ECGAlgorithmResult] = [:]
    // Artifact detection + cleaning domain, extracted into an L4 store. See
    // REFACTOR.md slice 5.
    @StateObject var artifactVM = ArtifactViewModel()
    // "Define Artifact" template-detection domain, extracted into an L4 store
    // (REFACTOR.md — analysis-domain slice).
    @StateObject var template = ArtifactTemplateViewModel()
    @State private var showsWaveletArtifactExplorer = false
    @State private var isRunningWaveletArtifactExplorer = false
    @State private var waveletExplorerProgress = 0.0
    @State private var waveletExplorerStatusTitle = ""
    @State private var waveletExplorerStatusDetail = ""
    @State private var waveletExplorerStatusMessage: String?
    @State private var waveletExplorerLog: [WaveletArtifactExplorerLogLine] = []
    @State private var waveletExplorerResult: WaveletArtifactExplorerResult?
    @State private var waveletExplorerRunGeneration = 0
    @State private var waveletExplorerPipeline = WaveletCleaningPipeline.eeg
    @State private var waveletExplorerCleaningMode = WaveletCleaningMode.conservativeLocal
    @State private var waveletExplorerIntensity = WaveletCleaningMode.conservativeLocal.defaultIntensity
    @State private var waveletExplorerChannelScope = WaveletExplorerChannelScope.visibleGood
    @State private var waveletExplorerDownsampleRate = 250.0
    @State private var waveletExplorerLevelCount = 8
    @State private var waveletExplorerThresholdScale = 1.0
    @State private var waveletExplorerWaveletFamily = WaveletCleaningFamily.bior44
    @State private var waveletExplorerThresholdRule = WaveletCleaningThresholdRule.hard
    @State private var waveletExplorerThresholdModel = WaveletCleaningThresholdModel.bayesShrink
    @State private var waveletExplorerMergeWindowSeconds = 0.10
    @State private var waveletExplorerMinimumDurationSeconds = 0.02
    @State private var waveletExplorerMaximumCandidates = 80
    // ICA decomposition + component removal, extracted into an L4 store. See
    // REFACTOR.md slice 6.
    @StateObject var ica = ICAViewModel()
    // PSA epoching / averaging + averaged-data display, extracted into an L4
    // store. See REFACTOR.md slice 4.
    @StateObject var epoching = EpochingViewModel()
    @State var segmentedEpochSignal: MFFSignalData?
    @State var segmentedEpochSegments: [EpochSegment] = []
    @StateObject private var eegAnalysis = EEGAnalysisViewModel()

    // Band-pass / notch filtering (applied to the active base signal).
    /// Filtering domain (band-pass / line-noise / average-reference), extracted
    /// into an L4 store. See REFACTOR.md.
    @StateObject var filter = FilterViewModel()
    // Wavelet artifact reduction (HAPPE-style) pipeline stage.
    // Wavelet-reduction domain, extracted into an L4 store. See REFACTOR.md slice 3.
    @StateObject private var wavelet = WaveletReductionViewModel()
    @State private var channelStatusIsError = false
    // Scrollable status history (newest first), shown when the status area is clicked.
    @State private var statusHistory: [StatusHistoryEntry] = []
    @State private var lastRecordedStatusBySource: [String: String] = [:]
    @State private var showsStatusHistory = false
    // Physio (PNS) channel display. Shown by default when present; pinned below
    // the EEG channels and synced to the EEG time axis.
    @State private var showsPhysioChannels = true
    @State private var physioRanges: [ClosedRange<Float>] = []
    @State private var physioScaleFactors: [Int: Double] = [:]
    @State private var physioMaxScaledChannels = Set<Int>()
    @State private var physioFlippedPolarity = Set<Int>()
    /// User-assigned renames for physio channels (keyed by merged channel index).
    @State private var physioChannelRenames: [Int: String] = [:]
    /// Index of the channel currently being renamed (nil when no rename in progress).
    @State private var physioRenameTarget: Int? = nil
    @State private var physioRenameText: String = ""
    /// Synthetic PNS channels created from ICA components.
    @State private var syntheticPNSChannels: [SyntheticPNSChannel] = []


    // MRI gradient-artifact removal domain (AAS / FASTR / FARM / Moosmann),
    // extracted into an L4 store. See REFACTOR.md slice 2.
    @StateObject var gradient = GradientViewModel()
    @StateObject var replay = ReplayController()

    // Per-channel state, shared with the menu-bar Channels commands.
    @State var channels = ChannelModel()
    @State private var electrodeGeometry: ElectrodeGeometry?
    @State private var channelStatusMessage: String?
    @State private var channelLabelMetricsExportRequest = 0
    // Channel-health coordination, extracted into an L4 store (REFACTOR.md).
    @StateObject private var chanHealth = ChannelHealthViewModel()
    @State private var showsChannelGoodnessSettings = false
    @State private var channelGoodnessSettingsRequest = 0
    // Segment-health domain, extracted into an L4 store (REFACTOR.md).
    @StateObject var segHealth = SegmentHealthViewModel()
    @State private var resetToOriginalRequest = 0
    @State private var mffExportRequest = 0
    @State private var copyProcessingRequest = 0
    @State private var datasetInfoRequest = 0
    @State private var showsDatasetInfo = false
    @State private var isExportingMFF = false
    @State private var mffExportStatusMessage: String?
    @State var recordingSessionID = UUID()
    @State private var waveletExplorerTask: Task<Void, Never>?
    @State var topographyTask: Task<Void, Never>?
    @State var artifactTemplateTask: Task<Void, Never>?
    @State private var waveletReductionTask: Task<Void, Never>?
    @State private var artifactCleaningTask: Task<Void, Never>?
    @State private var icaTask: Task<Void, Never>?
    @State private var icaRemovalTask: Task<Void, Never>?
    @State var psaTask: Task<Void, Never>?
    @State private var filterTask: Task<Void, Never>?
    @State var gradientTask: Task<Void, Never>?
    @State private var replayTask: Task<Void, Never>?
    @State private var mffExportTask: Task<Void, Never>?
    @State var bcgTask: Task<Void, Never>?
    @State var bcgRefinementTask: Task<Void, Never>?

    /// Keep the time slider visually comparable across sampling rates. The old
    /// fixed stride of 5 samples at 1000 Hz displayed about 200 plotted points/s.
    private let referenceDisplaySampleRate = 1_000.0
    private let referenceDisplaySampleStride = 5
    private let channelRowHeight: CGFloat = 70
    private let channelOverflowHeight: CGFloat = 28
    private let eventTrackHeight: CGFloat = 64
    private let rowSpacing: CGFloat = 12
    private let labelColumnWidth: CGFloat = 120
    private let eventsPanelWidth: CGFloat = 300
    private let topomapPanelWidth: CGFloat = 320
    private let butterflyPanelWidth: CGFloat = 360
    private let overlaidCategoriesPanelWidth: CGFloat = 380
    private let amplitudeScaleBounds: ClosedRange<Double> = 1...5_000
    private let physioScaleOptions: [Double] = [8, 16, 32, 64]
    private let physioScaleBounds: ClosedRange<Double> = 1...64

    private var amplitudeScaleSliderBounds: ClosedRange<Double> {
        log10(amplitudeScaleBounds.lowerBound)...log10(amplitudeScaleBounds.upperBound)
    }

    private var amplitudeScaleSliderBinding: Binding<Double> {
        Binding(
            get: {
                log10(min(max(amplitudeScale, amplitudeScaleBounds.lowerBound), amplitudeScaleBounds.upperBound))
            },
            set: { value in
                amplitudeScale = roundedAmplitudeScale(pow(10, value))
            }
        )
    }

    private var artifactMenuControls: ArtifactMenuControls {
        ArtifactMenuControls(
            artifacts: template.definedArtifacts,
            deleteRequest: $template.deletionRequest,
            deleteAllRequest: $template.deleteAllRequest
        )
    }

    private var psaControls: PSAViewControls {
        PSAViewControls(
            showButterfly: $epoching.showsButterflyPlot,
            showOverlaidCategories: $epoching.showsOverlaidCategories,
            isAveraged: epoching.isAveraged
        )
    }

    private var segmentHealthControls: SegmentHealthViewControls {
        SegmentHealthViewControls(
            showsHealth: $segHealth.shows,
            showsMouseOverHealth: $segHealth.showsMouseOver,
            detailsRequest: $segHealth.detailsRequest,
            refreshRequest: $segHealth.refreshRequest,
            isAnalyzing: segHealth.isAnalyzing,
            progress: segHealth.progress
        )
    }

    private var physioViewControls: PhysioViewControls {
        let realCount = recording.pnsSignal?.numberOfChannels ?? 0
        let total = realCount + syntheticPNSChannels.count
        return PhysioViewControls(
            showsPhysio: $showsPhysioChannels,
            hasPhysio: total > 0,
            channelCount: total
        )
    }

    private var channelHealthControls: ChannelHealthViewControls {
        ChannelHealthViewControls(
            showsHealth: Binding(
                get: { channels.showsHealth },
                set: { channels.showsHealth = $0 }
            ),
            detailsRequest: $chanHealth.detailsRequest,
            refreshRequest: Binding(
                get: { channels.healthRefreshToken },
                set: { channels.healthRefreshToken = $0 }
            ),
            settingsRequest: $channelGoodnessSettingsRequest,
            isAnalyzing: channels.isAnalyzingHealth,
            progress: channels.healthProgress
        )
    }

    var body: some View {
        installEventHandlers(on: bodyChrome)
    }

    private var bodyChrome: some View {
        Group {
            if recording.isLoading {
                let progress = recording.loadProgress ?? 0
                VStack(spacing: 16) {
                    Text("Opening \(recording.packageName)…")
                        .font(.headline)

                    VStack(spacing: 6) {
                        ProgressView(value: progress, total: 1)
                            .progressViewStyle(.linear)
                            .frame(width: 320)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(recording.loadStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let loadDetailMessage = recording.loadDetailMessage {
                        Text(loadDetailMessage)
                            .font(.caption2.weight(.medium))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let rawSignal = recording.signal {
                // Processing pipeline: raw → gradient-corrected → ICA-cleaned →
                // band-pass → artifact-cleaned → interpolated-channel overlay.
                // `base` is what filtering builds on; `preArtifact` is the
                // reversible source used by Clean Artifacts.
                let base = ica.cleanedSignal ?? gradient.correctedSignal ?? rawSignal
                let preArtifact = filter.output ?? base
                let processed = artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
                // Wavelet reduction stage: computed from `processed`, applied
                // before interpolation. Toggleable and revertible like cleaning.
                let waveletStage = wavelet.isEnabled ? (wavelet.reducedSignal ?? processed) : processed
                let continuousSignal = applyInterpolations(to: waveletStage)
                content(
                    for: epoching.epochedSignal ?? continuousSignal,
                    base: base,
                    cleaningBase: preArtifact,
                    waveletInput: processed,
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
        .focusedSceneValue(\.artifactMenuControls, artifactMenuControls)
        .focusedSceneValue(\.icaDebugReportRequest, $ica.debugReportRequest)
        .focusedSceneValue(\.resetToOriginalRequest, $resetToOriginalRequest)
        .focusedSceneValue(\.psaViewControls, psaControls)
        .focusedSceneValue(\.segmentHealthViewControls, segmentHealthControls)
        .focusedSceneValue(\.channelHealthViewControls, channelHealthControls)
        .focusedSceneValue(\.mffExportRequest, $mffExportRequest)
        .focusedSceneValue(\.copyProcessingRequest, $copyProcessingRequest)
        .focusedSceneValue(\.datasetInfoRequest, $datasetInfoRequest)
        .focusedSceneValue(\.physioViewControls, physioViewControls)
    }

    /// Split out of `body` (and further split below) so each modifier chain stays
    /// small enough for the Swift type-checker.
    private func installEventHandlers(on content: some View) -> some View {
        installEpochAndLifecycleHandlers(on: installRequestHandlers(on: content))
    }

    private func installRequestHandlers(on content: some View) -> some View {
        content
        .onChange(of: resetToOriginalRequest) { _, _ in
            resetToOriginalData()
        }
        .onChange(of: mffExportRequest) { _, _ in
            exportCurrentSignalToMFF()
        }
        .onChange(of: copyProcessingRequest) { _, _ in
            importProcessingFromOtherFile()
        }
        .onChange(of: datasetInfoRequest) { _, _ in
            showsDatasetInfo = true
        }
        .onChange(of: channelLabelMetricsExportRequest) { _, _ in
            saveChannelLabelMetricsJSON()
        }
        .onChange(of: segHealth.detailsRequest) { _, _ in
            segHealth.shows = true
            segHealth.showsDetails = true
        }
        .onChange(of: chanHealth.detailsRequest) { _, _ in
            chanHealth.showsDetails = true
        }
        .onChange(of: channelGoodnessSettingsRequest) { _, _ in
            showsChannelGoodnessSettings = true
        }
    }

    private func installEpochAndLifecycleHandlers(on content: some View) -> some View {
        content
        .onChange(of: template.deletionRequest) { _, artifactID in
            guard let artifactID else { return }
            deleteDefinedArtifact(id: artifactID)
            template.deletionRequest = nil
        }
        .onChange(of: template.deleteAllRequest) { _, _ in
            deleteAllDefinedArtifacts()
        }
        .onChange(of: epoching.baselineCorrected) { _, _ in
            refreshEpochDisplay()
        }
        .onChange(of: epoching.averageReference) { _, _ in
            refreshEpochDisplay()
        }
        .onChange(of: epoching.showsButterflyPlot) { _, _ in
            if !epoching.showsButterflyPlot, !epoching.showsOverlaidCategories {
                epoching.butterflyTopomapRelativeSample = nil
            }
        }
        .onChange(of: epoching.showsOverlaidCategories) { _, _ in
            if !epoching.showsButterflyPlot, !epoching.showsOverlaidCategories {
                epoching.butterflyTopomapRelativeSample = nil
            }
        }
        .onChange(of: ica.debugReportRequest) { _, _ in
            copyICADebugReportToPasteboard()
        }
        .task {
            await loadRecordingIfNeeded()
        }
        .onAppear {
            installCommandKeyMonitor()
        }
        .onDisappear {
            tearDownRecordingSessionForClose()
        }
    }

    private func loadRecordingIfNeeded() async {
        await recording.loadIfNeeded()
        if electrodeGeometry == nil {
            electrodeGeometry = recording.electrodeGeometry
        }
        ChannelSetStore.shared.activeSensorLayout = recording.sensorLayout
        ChannelSetStore.shared.activeChannelNames = recording.signal?.channelNames
        adoptOnDiskEpochsIfPresent()
        autoStartBatchIfNeeded()
    }

    /// When a Batch run swaps this file in, auto-configure the replay from the
    /// shared batch config and start it (once). Load failures are reported so the
    /// batch advances past a bad file.
    private func autoStartBatchIfNeeded() {
        guard batch.isActive, !batchStarted, batch.matches(recording: recording) else { return }
        guard recording.signal != nil else {
            batch.completeCurrent(.failed(recording.loadError ?? "Could not load recording."))
            return
        }
        guard let script = batch.script else { return }
        batchStarted = true
        replay.configure(fromBatch: batch, script: script)
        batch.setStatus(.processing)
        startInteractiveReplay()
    }

    /// When the opened file was segmented or category-averaged by other software,
    /// the reader already supplies `epoching.epochSegments`. Surface them through the same
    /// state the in-app PSA pipeline uses, so the recording displays as discrete
    /// epochs (with stimulus-locked markers) instead of a misleading continuous
    /// strip with out-of-place events.
    private func adoptOnDiskEpochsIfPresent() {
        guard epoching.epochedSignal == nil,
              let signal = recording.signal,
              signal.isSegmented,
              !signal.epochSegments.isEmpty else {
            return
        }
        segmentedEpochSignal = signal
        segmentedEpochSegments = signal.epochSegments
        epoching.epochedSignal = signal
        epoching.epochSegments = signal.epochSegments
        epoching.isAveraged = signal.isAveraged
        epoching.statusMessage = signal.isAveraged
            ? "Loaded \(signal.epochSegments.count) averaged categories"
            : "Loaded \(signal.epochSegments.count) epochs"
    }

    /// Markers the user has created for *this* recording, surfaced as events.
    var userMarkerEvents: [MFFEvent] {
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

    private func displayedEventsCacheKey(
        for signal: MFFSignalData,
        includeContinuousOverlays: Bool,
        mapContinuousOverlaysIntoEpochs: Bool
    ) -> WaveformDisplayedEventsCache.Key {
        WaveformDisplayedEventsCache.Key(
            signalURLPath: signal.signalURL.path,
            signalType: signal.signalType,
            signalEvents: EventTrackEventSignature(events: signal.events),
            userMarkers: markers
                .filter { $0.packageName == recording.packageName }
                .map {
                    WaveformUserMarkerSignature(
                        idHash: $0.persistentModelID.hashValue,
                        timeSeconds: $0.timeSeconds,
                        note: $0.note
                    )
                },
            artifactEvents: EventTrackEventSignature(events: artifactVM.events),
            definedArtifacts: template.definedArtifacts.map {
                WaveformDefinedArtifactSignature(
                    id: $0.id,
                    events: EventTrackEventSignature(events: $0.events)
                )
            },
            epochSegments: WaveformEpochSegmentSignature(segments: epoching.epochSegments),
            includeContinuousOverlays: includeContinuousOverlays,
            mapContinuousOverlaysIntoEpochs: mapContinuousOverlaysIntoEpochs
        )
    }

    private func refreshDisplayedEventsCache(
        for signal: MFFSignalData,
        includeContinuousOverlays: Bool,
        mapContinuousOverlaysIntoEpochs: Bool,
        key: WaveformDisplayedEventsCache.Key
    ) {
        guard displayedEventsCache.key != key else { return }
        displayedEventsCache = WaveformDisplayedEventsCache(
            key: key,
            events: displayedEvents(
                for: signal,
                includeContinuousOverlays: includeContinuousOverlays,
                mapContinuousOverlaysIntoEpochs: mapContinuousOverlaysIntoEpochs
            )
        )
    }

    private func continuousOverlayEventsForDisplay() -> [MFFEvent] {
        var events = userMarkerEvents
        var seen = Set(events)

        for event in template.definedArtifacts.flatMap(\.events) where seen.insert(event).inserted {
            events.append(event)
        }
        for event in artifactVM.events where seen.insert(event).inserted {
            events.append(event)
        }

        return events
    }

    private func epochedContinuousOverlayEvents(for signal: MFFSignalData) -> [MFFEvent] {
        guard epoching.epochedSignal != nil,
              signal.samplingRate > 0,
              !epoching.epochSegments.isEmpty else {
            return []
        }

        return continuousOverlayEventsForDisplay()
            .flatMap { event in
                epoching.epochSegments.compactMap { segment in
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
            label: event.label,
            eventDescription: event.eventDescription,
            cell: event.cell,
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
        waveletInput: MFFSignalData,
        continuousSignal: MFFSignalData
    ) -> some View {
        let isShowingEpochs = epoching.epochedSignal != nil
        let eventCacheKey = displayedEventsCacheKey(
            for: signal,
            includeContinuousOverlays: true,
            mapContinuousOverlaysIntoEpochs: isShowingEpochs
        )
        let events = displayedEventsCache.key == eventCacheKey
            ? displayedEventsCache.events
            : displayedEvents(
                for: signal,
                includeContinuousOverlays: true,
                mapContinuousOverlaysIntoEpochs: isShowingEpochs
            )

        VStack(spacing: 0) {
            // Full-width button bar — side panels below must not shrink it.
            controls(for: signal, base: base, waveletInput: waveletInput, continuousSignal: continuousSignal)

            Divider()

            HStack(spacing: 0) {
                waveformArea(for: signal, events: events, isShowingEpochs: isShowingEpochs)

                if showsEventsPanel {
                    Divider()
                    eventsPanel(for: signal, events: events)
                        .frame(width: eventsPanelWidth)
                        .background(Color(nsColor: .windowBackgroundColor))
                }

                if epoching.showsButterflyPlot, epoching.isAveraged {
                    Divider()
                    butterflyPanel(for: signal)
                        .frame(width: butterflyPanelWidth)
                        .background(Color(nsColor: .windowBackgroundColor))
                }

                if epoching.showsOverlaidCategories, epoching.isAveraged {
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

                if let relSample = epoching.butterflyTopomapRelativeSample, epoching.isAveraged {
                    Divider()
                    averagedTopomapPanel(for: signal, relativeSample: relSample)
                        .frame(width: topomapPanelWidth)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .onAppear {
            refreshDisplayedEventsCache(
                for: signal,
                includeContinuousOverlays: true,
                mapContinuousOverlaysIntoEpochs: isShowingEpochs,
                key: eventCacheKey
            )
        }
        .onChange(of: eventCacheKey) { _, newKey in
            refreshDisplayedEventsCache(
                for: signal,
                includeContinuousOverlays: true,
                mapContinuousOverlaysIntoEpochs: isShowingEpochs,
                key: newKey
            )
        }
        .sheet(isPresented: $epoching.showsSheet) {
            psaSheet(for: continuousSignal)
        }
        .sheet(isPresented: $template.showsSheet) {
            artifactTemplateSheet(for: continuousSignal)
        }
        .sheet(isPresented: $artifactVM.showsCleaningSheet) {
            artifactCleaningSheet(for: cleaningBase)
        }
        .sheet(isPresented: $showsECGDetectionSheet) {
            ecgDetectionSheet(for: continuousSignal)
        }
        .sheet(isPresented: $artifactVM.showsThresholdSheet) {
            EyeArtifactThresholdSheet(
                signal: continuousSignal,
                detectsEyeBlinkArtifacts: $detectsEyeBlinkArtifacts,
                detectsEyeMovementArtifacts: $detectsEyeMovementArtifacts,
                blinkChannelOverrideText: $blinkChannelOverrideText,
                movementChannelOverrideText: $movementChannelOverrideText,
                artifactVM: artifactVM
            )
        }
        .sheet(isPresented: $bcg.showsSheet) {
            bcgDetectionSheet(for: continuousSignal, selection: activeSelectionRange(in: continuousSignal))
                .onAppear { autoSelectBCGProxySetIfEnabled(for: continuousSignal) }
        }
        .sheet(isPresented: $showsWaveletArtifactExplorer) {
            waveletArtifactExplorerSheet(for: continuousSignal)
        }
        .sheet(isPresented: $wavelet.showsSheet) {
            waveletReductionSheet(input: waveletInput)
        }
        .sheet(isPresented: $ica.showsSheet) {
            icaSheet(for: base)
        }
        .sheet(isPresented: $replay.showsConfigPane) {
            ReplayConfigSheet(
                controller: replay,
                onStart: { startInteractiveReplay() },
                onCancel: { replay.reset() }
            )
        }
        .sheet(isPresented: $showsDatasetInfo) {
            DatasetInfoSheet(
                recording: recording,
                epoching: epoching,
                onClose: { showsDatasetInfo = false }
            )
        }
        .overlay(alignment: .top) { replayBanner() }
        .sheet(isPresented: $eegAnalysis.showsSheet) {
            EEGAnalysisSheet(
                viewModel: eegAnalysis,
                packageName: recording.packageName,
                signal: continuousSignal,
                processing: eegAnalysisProcessingSnapshot(),
                artifactSources: eegArtifactRejectionSources(),
                excludedChannelIndices: channels.bad,
                channelSets: ChannelSetStore.shared.allSets,
                sensorLayout: recording.sensorLayout,
                onClose: {
                    eegAnalysis.showsSheet = false
                }
            )
        }
        .sheet(isPresented: $chanHealth.showsDetails) {
            channelHealthDetailsSheet(for: continuousSignal)
        }
        .sheet(isPresented: $showsChannelGoodnessSettings) {
            ChannelGoodnessSettingsView()
                .environment(goodnessSettings)
        }
        .sheet(isPresented: $segHealth.showsDetails) {
            segmentHealthDetailsSheet()
        }
        .sheet(isPresented: $gradient.showsMotionConfig) {
            MotionConfigView(
                parameters: $gradient.motionParameters,
                fdThreshold: $gradient.motionFDThreshold,
                radiusMm: $gradient.motionRadiusMm,
                skipStart: $gradient.skipStart,
                skipEnd: $gradient.skipEnd,
                trSeconds: $gradient.trSeconds,
                trMarkerCode: gradient.trMarkerCode,
                trMarkerSamples: recording.signal.map { trMarkerSamples(in: $0, code: gradient.trMarkerCode) } ?? [],
                samplingRate: recording.signal?.samplingRate ?? 0,
                windowBefore: gradient.windowBefore,
                windowAfter: gradient.windowAfter,
                onClose: {
                    gradient.showsMotionConfig = false
                    gradient.showsPopover = true
                }
            )
        }
        .onChange(of: artifactVM.detectionMethod) { _, method in
            if method == .ica {
                DispatchQueue.main.async {
                    openICASheet(for: base)
                }
            }
        }
        .task(id: artifactDetectionRequestID(for: continuousSignal)) {
            await updateArtifactEvents(for: continuousSignal)
        }
        .task(id: channelHealthSignature(for: continuousSignal)) {
            // Channel health is now run on demand (tap a badge). A major state
            // change (new filter/gradient/ICA/artifact repair/interpolation)
            // changes the signature and resets the badges to empty; the user
            // re-runs when ready.
            resetChannelHealthForStateChange()
        }
        .onChange(of: chanHealth.detailsRequest) { _, _ in
            // Opening the details sheet runs health if it hasn't been yet.
            runChannelHealthOnDemand(for: continuousSignal)
        }
        .onChange(of: channels.healthRefreshToken) { _, _ in
            // Menu "Run / Refresh Channel Health" forces a recompute.
            runChannelHealthOnDemand(for: continuousSignal, force: true)
        }
        .onChange(of: channels.interpolated.keys.sorted()) { oldKeys, newKeys in
            // Interpolating (or un-interpolating) a channel updates only that
            // channel's badge; the rest of the run is preserved.
            recomputeChannelHealthForInterpolation(oldKeys: oldKeys, newKeys: newKeys, signal: continuousSignal)
        }
        .task(id: segmentHealthRequestID(for: signal)) {
            refreshSegmentHealthIfNeeded(for: signal)
        }
    }

    // MARK: - Controls

    private func toolbarButtonLabel(_ label: String) -> String? {
        showsToolbarButtonLabels ? label : nil
    }

    private func roundedAmplitudeScale(_ value: Double) -> Double {
        let clamped = min(max(value, amplitudeScaleBounds.lowerBound), amplitudeScaleBounds.upperBound)
        if clamped < 100 {
            return clamped.rounded()
        }
        if clamped < 1_000 {
            return (clamped / 10).rounded() * 10
        }
        return (clamped / 100).rounded() * 100
    }

    private func formatAmplitudeScale(_ value: Double) -> String {
        if value < 100 {
            return String(Int(value.rounded()))
        }
        if value < 1_000 {
            return String(Int((value / 10).rounded() * 10))
        }
        return String(Int((value / 100).rounded() * 100))
    }

    private func controls(for signal: MFFSignalData, base: MFFSignalData, waveletInput: MFFSignalData, continuousSignal: MFFSignalData) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Scale")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: amplitudeScaleSliderBinding, in: amplitudeScaleSliderBounds)
                        .frame(width: 170)
                        .help("Lower values make traces taller.")
                    Text("±\(formatAmplitudeScale(amplitudeScale)) µV")
                        .font(.caption.monospacedDigit())
                        .frame(width: 86, alignment: .trailing)
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
            Button {
                gradient.showsPopover.toggle()
            } label: {
                ToolbarIcon(
                    name: "icon.mri",
                    label: toolbarButtonLabel("MRI"),
                    isActive: gradient.correctedSignal != nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("MRI")
            .disabled(gradient.isProcessing)
            .help(gradient.correctedSignal != nil
                ? "Gradient artifact removed using \(gradient.trMarkerCode) triggers."
                : "MR artifact removal")
            .popover(isPresented: $gradient.showsPopover, arrowEdge: .bottom) {
                mriPopover(for: recording.signal)
            }

            Button {
                filter.showsPopover.toggle()
            } label: {
                ToolbarIcon(
                    name: "icon.filter",
                    label: toolbarButtonLabel("FILTER"),
                    isActive: filter.output != nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter")
            .disabled(filter.isFiltering)
            .help(filter.output != nil
                ? "Active: \(filter.activeFilterSummary)"
                : "Apply a cutoff / notch / average-reference filter")
            .popover(isPresented: $filter.showsPopover, arrowEdge: .bottom) {
                filterPopover(for: base)
            }

            Menu {
                if activeSelectionRange(in: signal) != nil,
                   let defaultChannel = defaultArtifactTemplateChannel(in: signal) {
                    Button("Define Artifact…") {
                        openArtifactTemplateSheet(for: signal, clickedChannel: defaultChannel)
                    }
                }

                Button("Clean Artifacts…") {
                    artifactVM.showsCleaningSheet = true
                }
                .disabled(template.definedArtifacts.isEmpty)

                Divider()

                Button("Wavelet Artifact Explorer…") {
                    openWaveletArtifactExplorer(for: continuousSignal)
                }
                .disabled(isRunningWaveletArtifactExplorer)

                Button("Wavelet Reduction…") {
                    openWaveletReductionSheet(input: waveletInput)
                }

                Toggle("Show Wavelet Reduction", isOn: Binding(
                    get: { wavelet.isEnabled },
                    set: { setWaveletReductionEnabled($0) }
                ))
                .disabled(wavelet.reducedSignal == nil)
                .help(wavelet.reducedSignal == nil
                    ? "Run wavelet reduction before toggling the reduced signal."
                    : "Switch between the wavelet-reduced signal and the input signal.")

                Button("Revert Wavelet Reduction") {
                    revertWaveletReduction()
                }
                .disabled(wavelet.reducedSignal == nil)

                Divider()

                Toggle("Show Applied Correction", isOn: Binding(
                    get: { artifactVM.cleaningIsEnabled },
                    set: { setArtifactCleaningEnabled($0) }
                ))
                .disabled(artifactVM.cleanedSignal == nil)
                .help(artifactVM.cleanedSignal == nil
                    ? "Apply artifact cleaning before toggling the corrected signal."
                    : "Switch between the artifact-corrected signal and the uncorrected signal.")

                Divider()

                Toggle("Eye Blink", isOn: $detectsEyeBlinkArtifacts)
                Toggle("Eye Movement", isOn: $detectsEyeMovementArtifacts)
                
                Divider()
                
                Button(detectsECGArtifacts ? "Configure ECG / QRS Detection…" : "ECG / QRS Detection…") {
                    openECGDetectionSheet(for: continuousSignal)
                }
                if detectsECGArtifacts {
                    Button("Turn Off ECG Detection") {
                        detectsECGArtifacts = false
                        artifactVM.detectionRefreshToken += 1
                    }
                }
                Button(bcg.detectsArtifacts ? "Configure BCG Detection…" : "BCG Detection…") {
                    bcg.showsSheet = true
                }
                if bcg.detectsArtifacts {
                    Button("Turn Off BCG Detection") {
                        disableBCGDetection()
                    }
                }

                Divider()

                Picker("Method", selection: $artifactVM.detectionMethod) {
                    ForEach(ArtifactDetectionMethod.selectableCases) { method in
                        Text(method.rawValue)
                            .tag(method)
                    }
                }
                .pickerStyle(.inline)

                if artifactVM.detectionMethod == .threshold {
                    Divider()
                    Button("Threshold Settings…") {
                        artifactVM.showsThresholdSheet = true
                    }
                    if !detectsEyeBlinkArtifacts, !detectsEyeMovementArtifacts {
                        Text("Enable Eye Blink or Eye Movement above to detect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if artifactVM.detectionMethod == .ica {
                    Divider()
                    Button("Run / Review ICA…") {
                        openICASheet(for: base)
                    }
                    Text("Inspect component maps and remove selected components.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                ToolbarIcon(
                    name: "icon.artifacts",
                    label: toolbarButtonLabel("ARTIFACTS"),
                    isActive: artifactsAreActive
                )
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

                Toggle("Average Reference", isOn: $epoching.averageReference)
                    .disabled(epoching.epochedSignal == nil)
                    .help("Re-reference the epochs to the common average of the good channels (excludes bad channels, uses interpolated values).")

                Toggle("Baseline Correction (pre-stimulus)", isOn: $epoching.baselineCorrected)
                    .disabled(epoching.epochedSignal == nil)
                    .help("Subtract each epoch's mean over the pre-stimulus interval from the whole epoch.")

                Button(epoching.showsButterflyPlot ? "Hide Butterfly" : "Show Butterfly") {
                    epoching.showsButterflyPlot.toggle()
                    if !epoching.showsButterflyPlot {
                        epoching.butterflyTopomapRelativeSample = nil
                    }
                }
                .disabled(!epoching.isAveraged || epoching.epochedSignal == nil)

                if epoching.epochedSignal != nil {
                    Divider()
                    Button("Undo Segmentation", role: .destructive) {
                        clearEpochs()
                    }
                }
            } label: {
                ToolbarIcon(
                    name: "icon.process",
                    label: toolbarButtonLabel("PROCESS"),
                    isActive: epoching.epochedSignal != nil
                )
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("Processing")
            .help("Segment the recording into event-locked epochs")

            Button {
                eegAnalysis.syncArtifactSources(eegArtifactRejectionSources())
                eegAnalysis.showsSheet = true
            } label: {
                ToolbarIcon(
                    name: "icon.eeg-processing",
                    label: toolbarButtonLabel("EEG"),
                    isActive: eegAnalysis.result != nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("EEG Processing")
            .help(eegAnalysis.result == nil ? "Continuous EEG analysis tools" : "EEG analysis results ready")

            Button {
                showsEventsPanel.toggle()
            } label: {
                ToolbarIcon(
                    name: "icon.events",
                    label: toolbarButtonLabel("EVENTS"),
                    isActive: showsEventsPanel
                )
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
        let source: String
        let text: String
        let isError: Bool
    }

    /// A timestamped entry kept in the scrollable status history.
    struct StatusHistoryEntry: Identifiable, Hashable {
        let id = UUID()
        let source: String
        let text: String
        let isError: Bool
        let date: Date
    }

    /// Messages currently worth surfacing, gathered from each feature's status.
    private var activeLogMessages: [LogLine] {
        var lines: [LogLine] = []
        if !gradient.isProcessing, let mriStatus = gradient.statusMessage {
            lines.append(LogLine(source: "MRI", text: mriStatus, isError: gradient.statusIsError))
        }
        if !filter.isFiltering, let filterStatusMessage = filter.statusMessage {
            lines.append(LogLine(source: "Filter", text: filterStatusMessage, isError: filter.statusIsError))
        }
        if let psaStatus = epoching.statusMessage {
            lines.append(LogLine(source: "Segment", text: psaStatus, isError: false))
        }
        if let channelStatusMessage {
            lines.append(LogLine(source: "Channel", text: channelStatusMessage, isError: channelStatusIsError))
        }
        if let chanStatus = chanHealth.statusMessage {
            lines.append(LogLine(source: "Channel Health", text: chanStatus, isError: false))
        }
        if let segStatus = segHealth.statusMessage {
            lines.append(LogLine(source: "Segment Health", text: segStatus, isError: false))
        }
        if let cleaningStatus = artifactVM.cleaningStatusMessage {
            lines.append(LogLine(source: "Artifact", text: cleaningStatus, isError: false))
        }
        if let waveletExplorerStatusMessage {
            lines.append(LogLine(source: "Wavelet", text: waveletExplorerStatusMessage, isError: false))
        }
        if let waveletStatus = wavelet.statusMessage {
            lines.append(LogLine(source: "Wavelet Reduction", text: waveletStatus, isError: false))
        }
        if let mffExportStatusMessage {
            lines.append(LogLine(source: "Export", text: mffExportStatusMessage, isError: false))
        }
        return lines
    }

    /// Appends any newly-changed status messages to the scrollable history.
    private func recordStatusHistory(_ lines: [LogLine]) {
        for line in lines where lastRecordedStatusBySource[line.source] != line.text {
            lastRecordedStatusBySource[line.source] = line.text
            statusHistory.append(StatusHistoryEntry(
                source: line.source,
                text: line.text,
                isError: line.isError,
                date: Date()
            ))
        }
        if statusHistory.count > 200 {
            statusHistory.removeFirst(statusHistory.count - 200)
        }
    }

    /// Consolidated status/progress area shown at the far right of the toolbar,
    /// so individual buttons no longer push inline messages into the layout.
    @ViewBuilder
    private func statusLog() -> some View {
        Button {
            showsStatusHistory = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if gradient.isProcessing {
                    logProgressRow(label: "MRI", value: gradient.progress)
                }
                if filter.isFiltering {
                    logProgressRow(label: "Filter", value: filter.progress)
                }
                if let cleaningProgress = artifactVM.cleaningProgress {
                    logProgressRow(label: "Artifact", value: cleaningProgress.fraction)
                }
                if isRunningWaveletArtifactExplorer {
                    logProgressRow(label: "Wavelet", value: waveletExplorerProgress)
                }
                if wavelet.isRunning {
                    logProgressRow(label: "Reduction", value: wavelet.progress)
                }
                if channels.isAnalyzingHealth {
                    logProgressRow(label: "Health", value: channels.healthProgress)
                }
                if segHealth.isAnalyzing {
                    logProgressRow(label: "Segments", value: segHealth.progress)
                }
                if isExportingMFF {
                    logProgressRow(label: "MFF", value: 0.5)
                }

                ForEach(activeLogMessages, id: \.self) { line in
                    StatusLogLineView(line: line)
                }

                if !gradient.isProcessing,
                   !filter.isFiltering,
                   !isRunningWaveletArtifactExplorer,
                   !wavelet.isRunning,
                   !channels.isAnalyzingHealth,
                   !segHealth.isAnalyzing,
                   activeLogMessages.isEmpty {
                    Text(statusHistory.isEmpty ? "Ready" : "Ready · click for history")
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to see the full status history")
        .onChange(of: activeLogMessages) { _, lines in
            recordStatusHistory(lines)
        }
        .popover(isPresented: $showsStatusHistory, arrowEdge: .bottom) {
            statusHistoryPopover()
        }
        .accessibilityLabel("Status log")
    }

    @ViewBuilder
    private func statusHistoryPopover() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status History")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    statusHistory.removeAll()
                }
                .disabled(statusHistory.isEmpty)
            }

            Divider()

            if statusHistory.isEmpty {
                Text("No status messages yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(statusHistory.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(entry.source.uppercased())
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                                    Spacer()
                                    Text(entry.date, format: .dateTime.hour().minute().second())
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(entry.text)
                                    .font(.callout)
                                    .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 420, height: 380, alignment: .topLeading)
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

    private struct StatusLogLineView: View {
        let line: LogLine

        var body: some View {
            Text(line.text)
                .font(.caption)
                .foregroundStyle(line.isError ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(line.text)
        }
    }

    // MARK: - Waveform area

    @ViewBuilder
    private func waveformArea(for signal: MFFSignalData, events: [MFFEvent], isShowingEpochs: Bool) -> some View {
        let plotWidth = plotWidth(for: signal)
        let displayStride = displaySampleStride(for: signal)

        // Stagger events from different source XML files into vertical lanes so
        // overlapping markers/labels stay legible. Cap the lane count so the
        // track doesn't grow without bound.
        let eventSignature = EventTrackEventSignature(events: events)
        let sourceSummary = eventTrackSourceSummary.signature == eventSignature
            ? eventTrackSourceSummary
            : EventTrackSourceSummary(events: events, signature: eventSignature)
        let eventLaneCount = max(min(sourceSummary.sourceCount, EventTrackView.maxLanes), 1)
        let dynamicEventTrackHeight = eventTrackHeight + CGFloat(eventLaneCount - 1) * EventTrackView.laneSpacing

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
                .frame(width: labelColumnWidth, height: dynamicEventTrackHeight, alignment: .topLeading)

                EventTrackView(
                    events: events,
                    samplingRate: signal.samplingRate,
                    timeScale: timeScale,
                    sampleStride: displayStride,
                    contentOffset: horizontalOffset,
                    visibleRange: visibleHorizontalRange,
                    viewportWidth: horizontalViewportWidth,
                    laneCount: eventLaneCount,
                    onSelectEvent: { event, color in
                        // Toggle: tapping the highlighted flag again clears it.
                        // Only artifact-detection events carry a centered window;
                        // imported MFF events use onset+forward duration, so they
                        // are not highlighted with this centered band.
                        if highlightedArtifactEvent?.id == event.id {
                            highlightedArtifactEvent = nil
                        } else if event.durationSeconds != nil,
                                  event.sourceFile == EyeArtifactThresholdDetector.sourceFile {
                            highlightedArtifactEvent = event
                            highlightedArtifactColor = color
                        } else {
                            highlightedArtifactEvent = nil
                        }
                    }
                )
                .frame(maxWidth: .infinity, minHeight: dynamicEventTrackHeight, maxHeight: dynamicEventTrackHeight)
                .background(
                    WaveformRightClickMonitor { point in
                        eventTrackContextSample = sampleIndex(forContentX: point.x + horizontalOffset, in: signal)
                    }
                )
                .contentShape(Rectangle())
                .contextMenu {
                    splitFileContextMenu(for: signal)
                }
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
                        .overlay(alignment: .topLeading) { epochBoundaryOverlay(for: signal) }
                        .overlay(alignment: .topLeading) { selectionOverlay(for: signal) }
                        .overlay(alignment: .topLeading) { artifactHighlightOverlay(for: signal) }
                        .overlay(alignment: .topLeading) { cursorOverlay(for: signal) }
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

            // Pinned physio (PNS) pane: always visible below the EEG channels
            // (separated by a gap), sharing the EEG time axis. Like the events
            // bar, it stays put while the EEG channels scroll vertically.
            if showsPhysioChannels,
               let pns = displayedPhysioSignal(), !pns.data.isEmpty {
                physioPane(pns, eegSamplingRate: signal.samplingRate)
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
        .onAppear {
            refreshEventTrackSourceSummary(events: events, signature: eventSignature)
        }
        .onChange(of: eventSignature) { _, newSignature in
            refreshEventTrackSourceSummary(events: events, signature: newSignature)
        }
    }

    private func refreshEventTrackSourceSummary(events: [MFFEvent], signature: EventTrackEventSignature) {
        guard eventTrackSourceSummary.signature != signature else { return }
        eventTrackSourceSummary = EventTrackSourceSummary(events: events, signature: signature)
    }

    // MARK: - Physio (PNS) pane

    private func pnsFilterBaseSignal() -> MFFSignalData? {
        guard let raw = recording.pnsSignal else { return nil }
        if gradient.appliesToPNS, let correctedPNS = gradient.correctedPNSSignal {
            return correctedPNS
        }
        return raw
    }

    func displayedPhysioSignal() -> MFFSignalData? {
        let base: MFFSignalData?
        if let pnsBase = pnsFilterBaseSignal() {
            if filter.filterPNS,
                      let filteredPNS = filter.pnsOutput,
                      filter.pnsInputSignalType == pnsBase.signalType {
                base = filteredPNS
            } else {
                base = pnsBase
            }
        } else {
            base = nil
        }
        guard !syntheticPNSChannels.isEmpty || base != nil else { return nil }
        return mergingWithSynthetic(base: base)
    }

    /// Builds a single `MFFSignalData` that contains the real PNS channels (if any)
    /// followed by any synthesized ICA channels. All synthetic samples are stored at
    /// EEG sampling rate (linearly upsampled from the ICA analysis rate).
    private func mergingWithSynthetic(base: MFFSignalData?) -> MFFSignalData? {
        guard let signal = recording.signal else { return base }
        guard !syntheticPNSChannels.isEmpty else { return base }

        let targetRate = base?.samplingRate ?? signal.samplingRate
        let realData   = base?.data ?? []
        let realNames  = base?.channelNames ?? []

        // Pin synthetic channels to exactly this many samples so all channels in
        // the merged signal have identical length (required by ecgDetectionSources
        // and other per-channel length checks). Use the real PNS length when
        // available; otherwise derive from EEG duration at the target rate.
        let targetSampleCount: Int? = realData.first?.count
            ?? { Int((signal.duration * targetRate).rounded()) }()

        var mergedData  = realData
        var mergedNames = realNames

        for synth in syntheticPNSChannels {
            var upsampled = upsampleLinear(synth.samples,
                                           from: synth.samplingRate,
                                           to: targetRate)
            if let target = targetSampleCount {
                if upsampled.count > target {
                    upsampled.removeLast(upsampled.count - target)
                } else if upsampled.count < target {
                    let pad = upsampled.last ?? 0
                    upsampled.append(contentsOf: repeatElement(pad, count: target - upsampled.count))
                }
            }
            mergedData.append(upsampled)
            mergedNames.append(synth.name)
        }

        let anchor = base ?? MFFSignalData(
            signalURL: recording.packageURL,
            signalType: "SyntheticPNS",
            numberOfChannels: 0,
            samplingRate: targetRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: [],
            data: [],
            channelNames: []
        )

        return MFFSignalData(
            signalURL: anchor.signalURL,
            signalType: anchor.signalType,
            numberOfChannels: mergedData.count,
            samplingRate: targetRate,
            duration: anchor.duration,
            recordingStartTime: anchor.recordingStartTime,
            events: anchor.events,
            data: mergedData,
            channelNames: mergedNames.isEmpty ? nil : mergedNames
        )
    }

    private func upsampleLinear(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate > 0, dstRate > 0, !samples.isEmpty else { return samples }
        let ratio = dstRate / srcRate
        guard abs(ratio - 1) > 1e-6 else { return samples }
        let outCount = Int((Double(samples.count) * ratio).rounded())
        var out = [Float]()
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let lo = Int(srcPos)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(srcPos - Double(lo))
            out.append(samples[lo] * (1 - frac) + samples[hi] * frac)
        }
        return out
    }

    /// Per-channel display range (min...max over a strided scan) for the physio
    /// channels, so each trace (ECG, EMG, …) is auto-scaled to its own amplitude.
    nonisolated private static func computePhysioRanges(_ signal: MFFSignalData?) -> [ClosedRange<Float>] {
        guard let signal else { return [] }
        return signal.data.map { channel in
            guard !channel.isEmpty else { return Float(-1)...Float(1) }
            let stride = max(1, channel.count / 4000)
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            var i = 0
            while i < channel.count {
                let v = channel[i]
                if v.isFinite { lo = min(lo, v); hi = max(hi, v) }
                i += stride
            }
            if !(lo < hi) { return (hi - 1)...(hi + 1) }   // flat channel
            return lo...hi
        }
    }

    @ViewBuilder
    private func physioPane(_ pns: MFFSignalData, eegSamplingRate: Double) -> some View {
        let rowHeight: CGFloat = 36
        let names = pns.channelNames
            ?? (0..<pns.numberOfChannels).map { "PNS \($0 + 1)" }

        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                // Channel labels, aligned to the trace rows.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Physio")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 16, alignment: .leading)
                    ForEach(0..<pns.numberOfChannels, id: \.self) { i in
                        let name = physioChannelName(index: i, names: names)
                        HStack(spacing: 5) {
                            Text(name)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if let scaleBadge = physioScaleBadge(for: i) {
                                Text(scaleBadge)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            if physioFlippedPolarity.contains(i) {
                                Text("flip")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                        .help("Right-click to adjust physio scaling and polarity.")
                        .contextMenu {
                            physioChannelContextMenu(index: i, name: name)
                        }
                    }
                }
                .frame(width: labelColumnWidth, alignment: .topLeading)

                ZStack(alignment: .topLeading) {
                    PhysioTrackView(
                        signal: pns,
                        ranges: physioRanges,
                        scaleFactors: physioScaleFactors,
                        maxScaledChannels: physioMaxScaledChannels,
                        flippedPolarity: physioFlippedPolarity,
                        rowHeight: rowHeight,
                        eegSamplingRate: eegSamplingRate,
                        sampleStride: displaySampleStride(for: eegSamplingRate),
                        timeScale: timeScale,
                        contentOffset: horizontalOffset,
                        viewportWidth: horizontalViewportWidth
                    )
                    .padding(.top, 16)   // align below the "Physio" header

                    physioContextMenuOverlay(
                        channelCount: pns.numberOfChannels,
                        names: names,
                        rowHeight: rowHeight
                    )
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: physioRangeTaskID(for: pns)) {
            physioRanges = Self.computePhysioRanges(pns)
            physioScaleFactors = physioScaleFactors.filter { $0.key < pns.numberOfChannels }
            physioMaxScaledChannels = physioMaxScaledChannels.filter { $0 < pns.numberOfChannels }
            physioFlippedPolarity = physioFlippedPolarity.filter { $0 < pns.numberOfChannels }
        }
        .alert("Rename Channel", isPresented: Binding(
            get: { physioRenameTarget != nil },
            set: { if !$0 { physioRenameTarget = nil } }
        )) {
            TextField("Channel name", text: $physioRenameText)
            Button("Rename") {
                if let idx = physioRenameTarget, !physioRenameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    applyPhysioRename(index: idx, name: physioRenameText.trimmingCharacters(in: .whitespaces))
                }
                physioRenameTarget = nil
            }
            Button("Cancel", role: .cancel) { physioRenameTarget = nil }
        } message: {
            Text("Enter a new name for this physio channel.")
        }
    }

    private func applyPhysioRename(index: Int, name: String) {
        let realCount = recording.pnsSignal?.numberOfChannels ?? 0
        if index < realCount {
            physioChannelRenames[index] = name
        } else {
            let synthIdx = index - realCount
            if synthIdx < syntheticPNSChannels.count {
                syntheticPNSChannels[synthIdx].name = name
            }
        }
    }

    func physioRangeTaskID(for signal: MFFSignalData) -> String {
        [
            signal.signalURL.path,
            signal.signalType,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            filter.filterPNS ? "filterPNS" : "rawPNS",
            gradient.appliesToPNS ? "mriPNS" : "rawMRI"
        ].joined(separator: "|")
    }

    private func physioChannelName(index: Int, names: [String]) -> String {
        if let renamed = physioChannelRenames[index] { return renamed }
        return index < names.count ? names[index] : "PNS \(index + 1)"
    }

    private func physioScaleFactor(for index: Int) -> Double {
        physioScaleFactors[index] ?? 1
    }

    private func physioScaleBadge(for index: Int) -> String? {
        if physioMaxScaledChannels.contains(index) {
            return "Max"
        }
        let scale = physioScaleFactor(for: index)
        return scale == 1 ? nil : physioScaleLabel(scale)
    }

    private func physioScaleBinding(for index: Int) -> Binding<Double> {
        Binding(
            get: { physioScaleFactor(for: index) },
            set: { setPhysioScale($0, for: index) }
        )
    }

    private func setPhysioScale(_ scale: Double, for index: Int) {
        physioMaxScaledChannels.remove(index)
        let clamped = min(max(scale, physioScaleBounds.lowerBound), physioScaleBounds.upperBound)
        if abs(clamped - 1) < 0.0001 {
            physioScaleFactors[index] = nil
        } else {
            physioScaleFactors[index] = clamped
        }
    }

    private func setPhysioScaleToMax(for index: Int) {
        physioScaleFactors[index] = nil
        physioMaxScaledChannels.insert(index)
    }

    private func togglePhysioPolarity(for index: Int) {
        if physioFlippedPolarity.contains(index) {
            physioFlippedPolarity.remove(index)
        } else {
            physioFlippedPolarity.insert(index)
        }
    }

    private func physioScaleLabel(_ scale: Double) -> String {
        let rounded = (scale * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.0001 {
            return "\(Int(rounded.rounded()))x"
        }
        if abs(rounded * 10 - (rounded * 10).rounded()) < 0.0001 {
            return String(format: "%.1fx", rounded)
        }
        return String(format: "%.2fx", rounded)
    }

    @ViewBuilder
    private func physioChannelContextMenu(index: Int, name: String) -> some View {
        let realPhysioCount = recording.pnsSignal?.numberOfChannels ?? 0
        let currentScale = physioScaleFactor(for: index)
        let isMaxScaled = physioMaxScaledChannels.contains(index)
        let isFlipped = physioFlippedPolarity.contains(index)
        Text("\(name): \(isMaxScaled ? "Max" : physioScaleLabel(currentScale))\(isFlipped ? ", flipped" : "")")

        Button("Rename…") {
            physioRenameText = name
            physioRenameTarget = index
        }

        Divider()

        if index < realPhysioCount {
            Button("Move to EEG") {
                movePhysioChannelToEEG(index: index, name: name)
            }

            Divider()
        }

        if !isMaxScaled {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scale \(physioScaleLabel(currentScale))")
                    .font(.caption)
                Slider(value: physioScaleBinding(for: index), in: physioScaleBounds, step: 1)
                    .frame(width: 180)
            }
            .padding(.vertical, 2)

            Divider()
        }

        Button(isFlipped ? "Restore Polarity" : "Flip Polarity") {
            togglePhysioPolarity(for: index)
        }

        Divider()

        Button("Auto") {
            setPhysioScale(1, for: index)
        }
        .disabled(!isMaxScaled && currentScale == 1)

        ForEach(physioScaleOptions, id: \.self) { scale in
            Button(physioScaleLabel(scale)) {
                setPhysioScale(scale, for: index)
            }
        }

        Button("Max") {
            setPhysioScaleToMax(for: index)
        }
        .disabled(isMaxScaled)
    }

    private func physioContextMenuOverlay(channelCount: Int, names: [String], rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<channelCount, id: \.self) { index in
                let name = physioChannelName(index: index, names: names)
                Color.clear
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                    .contextMenu {
                        physioChannelContextMenu(index: index, name: name)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

            ChannelHealthBadge(
                result: channels.healthResults[index],
                isAnalyzing: channels.isAnalyzingHealth,
                onActivate: {
                    if let signal = continuousProcessedSignal {
                        runChannelHealthOnDemand(for: signal)
                    }
                }
            )
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

            Divider()
            Button("Move \(eegChannelDisplayName(index: index, signal: signal)) to Physio") {
                moveEEGChannelToPhysio(index: index, in: signal)
            }
        }
    }

    private func toggleHidden(_ index: Int) {
        if channels.hidden.contains(index) {
            channels.hidden.remove(index)
        } else {
            channels.hidden.insert(index)
        }
    }

    private func moveEEGChannelToPhysio(index: Int, in signal: MFFSignalData) {
        let name = eegChannelDisplayName(index: index, signal: signal)
        guard confirmChannelRoleEditReset(action: "Move \(name) to Physio") else { return }

        let insertIndex = recording.pnsSignal?.numberOfChannels ?? 0
        do {
            let movedName = try recording.moveEEGChannelToPhysio(index: index)
            insertPhysioDisplayState(at: insertIndex)
            showsPhysioChannels = true
            finishChannelRoleEdit(message: "Moved \(movedName) to Physio. Export to save the channel role change.")
        } catch {
            channelStatusMessage = error.localizedDescription
            channelStatusIsError = true
        }
    }

    private func movePhysioChannelToEEG(index: Int, name: String) {
        guard confirmChannelRoleEditReset(action: "Move \(name) to EEG") else { return }

        do {
            let movedName = try recording.movePhysioChannelToEEG(index: index)
            removePhysioDisplayState(at: index)
            finishChannelRoleEdit(message: "Moved \(movedName) to EEG. Export to save the channel role change.")
        } catch {
            channelStatusMessage = error.localizedDescription
            channelStatusIsError = true
        }
    }

    private func finishChannelRoleEdit(message: String) {
        resetToOriginalData()
        channels.hidden.removeAll()
        channels.bad.removeAll()
        channels.interpolated.removeAll()
        channels.interpolationSources.removeAll()
        channels.clearHealthResults()
        electrodeGeometry = recording.electrodeGeometry
        ChannelSetStore.shared.activeSensorLayout = recording.sensorLayout
        ChannelSetStore.shared.activeChannelNames = recording.signal?.channelNames
        physioRanges = Self.computePhysioRanges(displayedPhysioSignal())
        channelStatusMessage = message
        channelStatusIsError = false
    }

    private func confirmChannelRoleEditReset(action: String) -> Bool {
        guard hasDerivedChannelRoleState else { return true }

        let alert = NSAlert()
        alert.messageText = "\(action)?"
        alert.informativeText = "This in-memory channel role edit will clear current filters, MRI/ICA/artifact results, epochs, interpolations, channel marks, and health results. The source file on disk will not change until the next export."
        alert.addButton(withTitle: "Move Channel")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var hasDerivedChannelRoleState: Bool {
        filter.output != nil
            || filter.pnsOutput != nil
            || gradient.correctedSignal != nil
            || gradient.correctedPNSSignal != nil
            || ica.cleanedSignal != nil
            || ica.decomposition != nil
            || artifactVM.cleanedSignal != nil
            || !artifactVM.events.isEmpty
            || !template.definedArtifacts.isEmpty
            || wavelet.reducedSignal != nil
            || epoching.epochedSignal != nil
            || eegAnalysis.result != nil
            || eegAnalysis.isRunning
            || !channels.hidden.isEmpty
            || !channels.bad.isEmpty
            || !channels.interpolated.isEmpty
            || !channels.healthResults.isEmpty
    }

    private func insertPhysioDisplayState(at index: Int) {
        physioChannelRenames = shiftPhysioDictionaryKeys(physioChannelRenames, insertingAt: index)
        physioScaleFactors = shiftPhysioDictionaryKeys(physioScaleFactors, insertingAt: index)
        physioMaxScaledChannels = shiftPhysioSet(physioMaxScaledChannels, insertingAt: index)
        physioFlippedPolarity = shiftPhysioSet(physioFlippedPolarity, insertingAt: index)
    }

    private func removePhysioDisplayState(at index: Int) {
        physioChannelRenames = shiftPhysioDictionaryKeys(physioChannelRenames, removingAt: index)
        physioScaleFactors = shiftPhysioDictionaryKeys(physioScaleFactors, removingAt: index)
        physioMaxScaledChannels = shiftPhysioSet(physioMaxScaledChannels, removingAt: index)
        physioFlippedPolarity = shiftPhysioSet(physioFlippedPolarity, removingAt: index)
    }

    private func shiftPhysioDictionaryKeys<Value>(_ values: [Int: Value], insertingAt index: Int) -> [Int: Value] {
        Dictionary(uniqueKeysWithValues: values.map { key, value in
            (key >= index ? key + 1 : key, value)
        })
    }

    private func shiftPhysioDictionaryKeys<Value>(_ values: [Int: Value], removingAt index: Int) -> [Int: Value] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            guard key != index else { return nil }
            return (key > index ? key - 1 : key, value)
        })
    }

    private func shiftPhysioSet(_ values: Set<Int>, insertingAt index: Int) -> Set<Int> {
        Set(values.map { $0 >= index ? $0 + 1 : $0 })
    }

    private func shiftPhysioSet(_ values: Set<Int>, removingAt index: Int) -> Set<Int> {
        Set(values.compactMap { value in
            guard value != index else { return nil }
            return value > index ? value - 1 : value
        })
    }

    @ViewBuilder
    private func waveformRow(index: Int, channel: [Float], plotWidth: CGFloat, signal: MFFSignalData) -> some View {
        WaveformPlot(
            // Hidden channels keep their row but draw no trace.
            samples: channels.hidden.contains(index) ? [] : channel,
            amplitudeScale: amplitudeScale,
            timeScale: timeScale,
            sampleStride: displaySampleStride(for: signal),
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

            Divider()
            Button("Move \(eegChannelDisplayName(index: index, signal: signal)) to Physio") {
                moveEEGChannelToPhysio(index: index, in: signal)
            }
        }
        .accessibilityLabel("Channel \(index + 1)")
        .zIndex(1)
    }

    @ViewBuilder
    private func splitFileContextMenu(for signal: MFFSignalData) -> some View {
        if let sample = splitSampleForContextMenu(in: signal) {
            Menu("Split File") {
                Button("Save Left Segment…") {
                    splitCurrentFile(.left, atSample: sample)
                }
                .disabled(isExportingMFF)

                Button("Save Right Segment…") {
                    splitCurrentFile(.right, atSample: sample)
                }
                .disabled(isExportingMFF)

                Button("Save Both Segments…") {
                    splitCurrentFile(.both, atSample: sample)
                }
                .disabled(isExportingMFF)
            }
        } else {
            Menu("Split File") {
                Button("No Split Point") {}
                    .disabled(true)
            }
            .disabled(true)
        }
    }

    private func splitSampleForContextMenu(in signal: MFFSignalData) -> Int? {
        guard let sampleCount = signal.data.first?.count, sampleCount > 1 else { return nil }
        let fallbackX = horizontalOffset + max(horizontalViewportWidth / 2, 0)
        let fallback = sampleIndex(forContentX: fallbackX, in: signal)
        return min(max(eventTrackContextSample ?? fallback, 1), sampleCount - 1)
    }

    /// Vertical cursor at the topomap sample, drawn once across the channel
    /// stack. Vivid orange so it is unmistakably distinct from the blue
    /// selection band.
    @ViewBuilder
    private func cursorOverlay(for signal: MFFSignalData) -> some View {
        if let topomapSample {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: contentX(forSample: topomapSample, in: signal) - 1)
                .allowsHitTesting(false)
        }
    }

    /// Highlighted time selection across the full channel stack. Uses a fixed
    /// blue (not the system accent) so it can never be confused with the yellow
    /// topomap cursor, regardless of the user's macOS accent colour.
    @ViewBuilder
    private func selectionOverlay(for signal: MFFSignalData) -> some View {
        if let range = activeSelectionRange(in: signal) {
            let lowerX = contentX(forSample: range.lowerBound, in: signal)
            let upperX = contentX(forSample: range.upperBound, in: signal)
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

    /// Translucent band spanning the window of the tapped artifact event, drawn
    /// in the event's flag color. The flag sits at the peak (event onset), so the
    /// window is centered on it using the event's recorded duration.
    @ViewBuilder
    private func artifactHighlightOverlay(for signal: MFFSignalData) -> some View {
        if let event = highlightedArtifactEvent,
           let duration = event.durationSeconds, duration > 0,
           signal.samplingRate > 0,
           let sampleCount = signal.data.first?.count, sampleCount > 0 {
            let halfWindow = duration / 2
            let startSample = Int(((event.beginTimeSeconds - halfWindow) * signal.samplingRate).rounded())
            let endSample = Int(((event.beginTimeSeconds + halfWindow) * signal.samplingRate).rounded())
            let lower = min(max(startSample, 0), sampleCount - 1)
            let upper = min(max(endSample, lower + 1), sampleCount)
            let lowerX = contentX(forSample: lower, in: signal)
            let upperX = contentX(forSample: upper, in: signal)
            Rectangle()
                .fill(highlightedArtifactColor.opacity(0.18))
                .frame(width: max(upperX - lowerX, 2))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle().fill(highlightedArtifactColor.opacity(0.7)).frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(highlightedArtifactColor.opacity(0.7)).frame(width: 1)
                }
                .offset(x: lowerX)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func segmentHealthOverlay(for signal: MFFSignalData) -> some View {
        if segHealth.shows,
           let results = segHealth.analysis?.results,
           let sampleCount = signal.data.first?.count,
           sampleCount > 0 {
            ZStack(alignment: .topLeading) {
                ForEach(results) { result in
                    let start = min(max(result.startSample, 0), sampleCount - 1)
                    let end = min(max(result.endSample + 1, start + 1), sampleCount)
                    let startX = contentX(forSample: start, in: signal)
                    let endX = contentX(forSample: end, in: signal)
                    SegmentHealthBand(
                        result: result,
                        showsMouseOverHealth: segHealth.showsMouseOver
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
                    highlightedArtifactEvent = nil
                    return
                }

                // Otherwise it's a stationary click: detect a double-click by hand.
                let clickX = contentX(fromGlobalX: value.location.x)
                let now = Date()
                if let last = lastWaveformClick,
                   now.timeIntervalSince(last.time) < Self.doubleClickInterval,
                   abs(clickX - last.x) < 6 {
                    topomapSample = sampleIndex(forContentX: clickX, in: signal)
                    epoching.butterflyTopomapRelativeSample = nil
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

    func activeSelectionRange(in signal: MFFSignalData) -> ClosedRange<Int>? {
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

    func selectionDescription(_ range: ClosedRange<Int>, in signal: MFFSignalData) -> String {
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
    private func epochBoundaryOverlay(for signal: MFFSignalData) -> some View {
        if epoching.epochedSignal != nil {
            ForEach(epoching.epochSegments.dropFirst()) { segment in
                Rectangle()
                    .fill(Color.green)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .offset(x: contentX(forSample: segment.startSample, in: signal) - 1)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func epochLegend() -> some View {
        if !epoching.epochSegments.isEmpty {
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
                if epoching.isAveraged {
                    overlayConditionsMenu()
                    Toggle("Overlay", isOn: $epoching.showsOverlayButterfly)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Overlay the selected conditions on shared axes, each in its own color.")
                }
                if !recording.noiseCurvesByCategory.isEmpty, !epoching.showsOverlayButterfly {
                    Toggle("Noise band", isOn: $epoching.showsNoiseBand)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Shade the ± grand-average noise band (from the ± residual across contributing files) behind each category.")
                }
                Button {
                    epoching.showsButterflyPlot = false
                    epoching.butterflyTopomapRelativeSample = nil
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

            if epoching.isAveraged, !epoching.epochSegments.isEmpty {
                let overlaySegments = selectedOverlaySegments()
                ScrollView {
                    if epoching.showsOverlayButterfly {
                        VStack(alignment: .leading, spacing: 10) {
                            FlowLegend(items: overlayLegendItems())
                            GeometryReader { proxy in
                                OverlayButterflyPlot(
                                    data: signal.data,
                                    segments: overlaySegments,
                                    colors: overlaySegments.map { epochColor(for: $0.colorIndex) },
                                    hiddenChannels: channels.hidden,
                                    amplitudeScale: amplitudeScale,
                                    highlightRelativeSample: epoching.butterflyTopomapRelativeSample
                                )
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    SpatialTapGesture(count: 2, coordinateSpace: .local)
                                        .onEnded { value in
                                            guard let first = overlaySegments.first else { return }
                                            epoching.butterflyTopomapRelativeSample = relativeSample(
                                                forButterflyX: value.location.x, width: proxy.size.width, segment: first)
                                            topomapSample = nil
                                        }
                                )
                                .help("Double-click to compare topographies at this latency.")
                                .contextMenu {
                                    figureSaveMenu(title: "Butterfly Overlay",
                                                   legend: overlayLegendItems(),
                                                   size: CGSize(width: 820, height: 300)) {
                                        OverlayButterflyPlot(
                                            data: signal.data,
                                            segments: overlaySegments,
                                            colors: overlaySegments.map { epochColor(for: $0.colorIndex) },
                                            hiddenChannels: channels.hidden,
                                            amplitudeScale: amplitudeScale
                                        )
                                    }
                                }
                            }
                            .frame(height: 220)
                        }
                        .padding(16)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(overlaySegments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Label(epoching.displayCategory(segment.category), systemImage: "waveform.path.ecg")
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
                                        highlightRelativeSample: epoching.butterflyTopomapRelativeSample,
                                        noiseCurve: (epoching.showsNoiseBand && !recording.noiseCurvesByCategory.isEmpty)
                                            ? recording.noiseCurvesByCategory[segment.category]
                                            : nil
                                    )
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(
                                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                                            .onEnded { value in
                                                epoching.butterflyTopomapRelativeSample = relativeSample(
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
                                                guard epoching.butterflyTopomapRelativeSample != nil else { return }
                                                epoching.butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: segment
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .help("Double-click to compare topographies at this latency. Drag the yellow line to move it.")
                                    .contextMenu {
                                        figureSaveMenu(title: "\(epoching.displayCategory(segment.category)) Butterfly",
                                                       legend: [(epoching.displayCategory(segment.category), epochColor(for: segment.colorIndex))],
                                                       size: CGSize(width: 820, height: 300)) {
                                            ButterflyConditionPlot(
                                                data: signal.data,
                                                segment: segment,
                                                hiddenChannels: channels.hidden,
                                                amplitudeScale: amplitudeScale,
                                                color: epochColor(for: segment.colorIndex),
                                                noiseCurve: (epoching.showsNoiseBand && !recording.noiseCurvesByCategory.isEmpty)
                                                    ? recording.noiseCurvesByCategory[segment.category] : nil
                                            )
                                        }
                                    }
                                }
                                .frame(height: 150)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(16)
                    }
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
        let overlaySegments = selectedOverlaySegments()
        let colors = overlaySegments.map { epochColor(for: $0.colorIndex) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overlaid Categories")
                        .font(.headline)
                    Text("Selected category averages, per channel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if epoching.isAveraged { overlayConditionsMenu() }
                Button {
                    epoching.showsOverlaidCategories = false
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

            if epoching.isAveraged, !epoching.epochSegments.isEmpty {
                // Category color legend (renamed labels for figures).
                FlowLegend(items: overlayLegendItems())
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
                                        segments: overlaySegments,
                                        colors: colors,
                                        amplitudeScale: amplitudeScale,
                                        highlightRelativeSample: epoching.butterflyTopomapRelativeSample
                                    )
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(
                                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                                            .onEnded { value in
                                                guard let first = epoching.epochSegments.first else { return }
                                                epoching.butterflyTopomapRelativeSample = relativeSample(
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
                                                guard epoching.butterflyTopomapRelativeSample != nil,
                                                      let first = epoching.epochSegments.first else { return }
                                                epoching.butterflyTopomapRelativeSample = relativeSample(
                                                    forButterflyX: value.location.x,
                                                    width: proxy.size.width,
                                                    segment: first
                                                )
                                                topomapSample = nil
                                            }
                                    )
                                    .help("Double-click to show a topomap for every category at this latency. Drag the yellow line to move it.")
                                    .contextMenu {
                                        figureSaveMenu(title: "Ch \(channelIndex + 1) Overlay",
                                                       legend: overlayLegendItems(),
                                                       size: CGSize(width: 820, height: 220)) {
                                            OverlaidCategoryChannelPlot(
                                                data: signal.data,
                                                channelIndex: channelIndex,
                                                segments: overlaySegments,
                                                colors: colors,
                                                amplitudeScale: amplitudeScale
                                            )
                                        }
                                    }
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
                    epoching.butterflyTopomapRelativeSample = nil
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
                let autoScale = fixedTopomapScale(for: samples.map(\.sample), in: signal) ?? 1
                let autoZ = topomapAutoZ(samples: samples, in: signal)
                let colorRange = topomapColorRange()
                let zScaling = topomapZScaling(auto: autoZ)
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(samples) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(epoching.displayCategory(entry.category))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(epochColor(for: entry.colorIndex))
                                    TopomapView(
                                        layout: layout,
                                        values: topomapValues(at: entry.sample, in: signal),
                                        timeSeconds: entry.latencySeconds,
                                        fixedScale: autoScale,
                                        colorRange: colorRange,
                                        zScaling: zScaling
                                    )
                                    .frame(height: 320)
                                }
                            }
                        }
                        .padding(16)
                        .contextMenu {
                            figureSaveMenu(
                                title: "Topographies",
                                legend: [],
                                size: CGSize(width: CGFloat(max(samples.count, 1)) * 280, height: 300)
                            ) {
                                topomapsFigure(samples: samples, layout: layout, scale: autoScale, colorRange: colorRange, zScaling: zScaling, signal: signal)
                            }
                        }
                    }

                    if isCommandKeyPressed {
                        TopomapScaleControl(
                            mode: $epoching.topomapScaleMode,
                            symmetric: $epoching.topomapSymmetric,
                            minValue: topomapMinBinding,
                            maxValue: topomapMaxBinding,
                            autoScale: autoScale,
                            onAutoMicrovolts: {
                                epoching.topomapScaleManual = false
                                seedTopomapScale(autoScale: autoScale, autoZ: autoZ)
                            },
                            sigma: $epoching.topomapZSigma,
                            zMean: topomapZMeanBinding,
                            zSD: topomapZSDBinding,
                            onAutoZ: {
                                epoching.topomapZManual = false
                                seedTopomapScale(autoScale: autoScale, autoZ: autoZ)
                            }
                        )
                        .padding(.trailing, 10)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .onAppear { seedTopomapScale(autoScale: autoScale, autoZ: autoZ) }
                .onChange(of: epoching.topomapSymmetric) { _, sym in
                    if sym { epoching.topomapScaleMin = -epoching.topomapScaleMax }
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

    /// The manual µV color range (nil to auto-scale). Only in µV mode.
    private func topomapColorRange() -> ClosedRange<Double>? {
        guard epoching.topomapScaleMode == .microvolts,
              epoching.topomapScaleManual,
              epoching.topomapScaleMin < epoching.topomapScaleMax else { return nil }
        return epoching.topomapScaleMin...epoching.topomapScaleMax
    }

    /// The effective z-score scaling, or nil when not in Z mode. `auto` is the
    /// mean/SD computed across the displayed maps.
    private func topomapZScaling(auto: (mean: Double, sd: Double)) -> TopomapZScaling? {
        guard epoching.topomapScaleMode == .zScore else { return nil }
        let mean = epoching.topomapZManual ? epoching.topomapZMean : auto.mean
        let sd = epoching.topomapZManual ? epoching.topomapZSD : auto.sd
        guard sd > 0, epoching.topomapZSigma > 0 else { return nil }
        return TopomapZScaling(mean: mean, sd: sd, sigma: epoching.topomapZSigma)
    }

    private var topomapMinBinding: Binding<Double> {
        Binding(get: { epoching.topomapScaleMin }, set: { value in
            epoching.topomapScaleMin = value
            if epoching.topomapSymmetric { epoching.topomapScaleMax = -value }
            epoching.topomapScaleManual = true
        })
    }

    private var topomapMaxBinding: Binding<Double> {
        Binding(get: { epoching.topomapScaleMax }, set: { value in
            epoching.topomapScaleMax = value
            if epoching.topomapSymmetric { epoching.topomapScaleMin = -value }
            epoching.topomapScaleManual = true
        })
    }

    private var topomapZMeanBinding: Binding<Double> {
        Binding(get: { epoching.topomapZMean }, set: { epoching.topomapZMean = $0; epoching.topomapZManual = true })
    }

    private var topomapZSDBinding: Binding<Double> {
        Binding(get: { epoching.topomapZSD }, set: { epoching.topomapZSD = $0; epoching.topomapZManual = true })
    }

    /// Seeds µV min/max and z mean/SD from the data so the ⌘ control opens at the
    /// current auto values (only while the respective mode is still auto).
    private func seedTopomapScale(autoScale: Double, autoZ: (mean: Double, sd: Double)) {
        if !epoching.topomapScaleManual {
            epoching.topomapScaleMax = autoScale
            epoching.topomapScaleMin = -autoScale
        }
        if !epoching.topomapZManual {
            epoching.topomapZMean = autoZ.mean
            epoching.topomapZSD = autoZ.sd
        }
    }

    /// Mean and (population) standard deviation of the values feeding the maps.
    private func topomapAutoZ(samples: [AveragedTopomapSample], in signal: MFFSignalData) -> (mean: Double, sd: Double) {
        let values = samples.flatMap { topomapValues(at: $0.sample, in: signal) }
        guard !values.isEmpty else { return (0, 1) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sd = variance.squareRoot()
        return (mean, sd > 0 ? sd : 1)
    }

    /// Standalone, side-by-side arrangement of all displayed topomaps for export
    /// (one labeled map per selected condition, shared color scale).
    @ViewBuilder
    private func topomapsFigure(
        samples: [AveragedTopomapSample],
        layout: SensorLayout,
        scale: Double?,
        colorRange: ClosedRange<Double>?,
        zScaling: TopomapZScaling?,
        signal: MFFSignalData
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(samples) { entry in
                VStack(spacing: 6) {
                    Text(epoching.displayCategory(entry.category))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(epochColor(for: entry.colorIndex))
                    TopomapView(
                        layout: layout,
                        values: topomapValues(at: entry.sample, in: signal),
                        timeSeconds: entry.latencySeconds,
                        fixedScale: scale,
                        colorRange: colorRange,
                        zScaling: zScaling,
                        showsLayoutName: false
                    )
                    .frame(width: 250, height: 250)
                }
            }
        }
    }

    private func relativeSample(forButterflyX x: CGFloat, width: CGFloat, segment: EpochSegment) -> Int {
        let epochLength = max(segment.endSample - segment.startSample + 1, 1)
        let normalized = min(max(x / max(width, 1), 0), 1)
        return min(max(Int((normalized * CGFloat(epochLength - 1)).rounded()), 0), epochLength - 1)
    }

    private func averagedTopomapSamples(relativeSample: Int, in signal: MFFSignalData) -> [AveragedTopomapSample] {
        selectedOverlaySegments().compactMap { segment in
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
        guard let segment = epoching.epochSegments.first, (epoching.epochedSignal?.samplingRate ?? 0) > 0 else {
            return "Latency"
        }
        let samplingRate = epoching.epochedSignal?.samplingRate ?? 1
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
                let numberWidth = max(28, CGFloat(String(max(visibleEvents.count, 1)).count) * 8 + 14)
                List(Array(visibleEvents.enumerated()), id: \.element.id) { offset, event in
                    Button {
                        jumpToEvent(event, in: signal)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(offset + 1)")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: numberWidth, alignment: .trailing)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.code)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                ForEach(eventMetadataRows(for: event), id: \.self) { row in
                                    Text(row)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(formattedEventTime(event.beginTimeSeconds))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(event.sourceFile)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Event \(offset + 1), \(eventAccessibilitySummary(event)), \(formattedEventTime(event.beginTimeSeconds))")
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

    // MARK: - Wavelet artifact explorer

    private func openWaveletArtifactExplorer(for signal: MFFSignalData) {
        waveletExplorerDownsampleRate = min(max(waveletExplorerDownsampleRate, 20), signal.samplingRate)
        waveletExplorerStatusMessage = nil
        if waveletExplorerStatusTitle.isEmpty {
            applyWaveletExplorerPipelineDefaults(waveletExplorerPipeline, samplingRate: signal.samplingRate, updatesStatus: false)
            waveletExplorerStatusTitle = "Wavelet artifact explorer ready"
            waveletExplorerStatusDetail = "\(waveletExplorerChannels(in: signal).count) channels selected for exploratory multiscale scanning."
        }
        showsWaveletArtifactExplorer = true
    }

    @ViewBuilder
    private func waveletReductionSheet(input: MFFSignalData) -> some View {
        let reduceCount = input.data.indices.filter { !channels.bad.contains($0) }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wavelet Artifact Reduction")
                        .font(.title3.weight(.semibold))
                    Text("Subtracts a wavelet reconstruction of the large coefficients (HAPPE-style), leaving the low-amplitude signal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(reduceCount) channels · \(Int(input.samplingRate.rounded())) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                waveletReductionSettingsColumn(input: input, reduceCount: reduceCount)
                    .frame(width: 320)

                Divider()

                waveletReductionInspector(input: input)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack {
                if wavelet.reducedSignal != nil {
                    Toggle("Show reduction", isOn: Binding(
                        get: { wavelet.isEnabled },
                        set: { setWaveletReductionEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    Button("Revert") { revertWaveletReduction() }
                }
                Spacer()
                Button(wavelet.reducedSignal == nil ? "Run" : "Re-run") {
                    runWaveletReduction(on: input)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(wavelet.isRunning || reduceCount == 0)
                Button("Close") { wavelet.showsSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 840, height: 640)
    }

    @ViewBuilder
    private func waveletReductionSettingsColumn(input: MFFSignalData, reduceCount: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $wavelet.mode) {
                    ForEach(WaveletReductionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: wavelet.mode) { _, newMode in
                    wavelet.config = newMode.defaultConfiguration(samplingRate: input.samplingRate)
                }

                Text(wavelet.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Transform")
                        Picker("", selection: $wavelet.config.kind) {
                            ForEach(WaveletTransformKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Wavelet")
                        Picker("", selection: $wavelet.config.family) {
                            ForEach(WaveletReductionFamily.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Threshold rule")
                        Picker("", selection: $wavelet.config.thresholdRule) {
                            ForEach(WaveletCleaningThresholdRule.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Threshold model")
                        Picker("", selection: $wavelet.config.thresholdModel) {
                            ForEach(WaveletCleaningThresholdModel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Levels")
                        Stepper("\(wavelet.config.levelCount)", value: $wavelet.config.levelCount, in: 1...WaveletReducer.maximumLevelCount)
                            .frame(width: 120)
                    }
                    GridRow {
                        Text("Strength")
                        TextField("x", value: $wavelet.config.thresholdScale, format: .number.precision(.fractionLength(2)))
                            .frame(width: 80)
                    }
                    GridRow {
                        Text("Downsample")
                        Picker("", selection: $wavelet.config.downsampleFactor) {
                            ForEach(downsampleFactorOptions(for: input.samplingRate), id: \.self) { factor in
                                Text(downsampleFactorLabel(factor: factor, rate: input.samplingRate)).tag(factor)
                            }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    GridRow {
                        Text("CPU cores")
                        Stepper("\(wavelet.coreCount) of \(WaveletReducer.maximumCoreCount)", value: $wavelet.coreCount, in: 1...WaveletReducer.maximumCoreCount)
                            .frame(width: 140)
                    }
                }
                .font(.callout)

                if wavelet.isRunning {
                    ProgressView(value: wavelet.progress)
                    Text("\(Int((wavelet.progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let result = wavelet.result {
                    Divider()
                    waveletReductionQCView(result: result)
                } else if let message = wavelet.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func waveletReductionInspector(input: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspect Changes")
                .font(.headline)

            if wavelet.candidates.isEmpty {
                Spacer()
                Text("Run a reduction to see the largest changes it made, channel by channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                if let candidate = selectedWaveletCandidate {
                    waveletCandidatePlot(candidate: candidate, input: input)
                        .frame(height: 160)
                    Text("Ch \(candidate.channelIndex + 1) · peak \(String(format: "%.2f", candidate.peakTimeSeconds))s · removed \(String(format: "%.2f", candidate.peakRemovedMicrovolts)) µV")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let result = wavelet.result {
                    waveletPerLevelBars(result: result)
                }

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(wavelet.candidates) { candidate in
                            Button {
                                wavelet.selectedCandidateID = candidate.id
                            } label: {
                                HStack {
                                    Text("#\(candidate.rank)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .leading)
                                    Text("Ch \(candidate.channelIndex + 1)")
                                        .font(.caption.weight(.medium))
                                        .frame(width: 56, alignment: .leading)
                                    Text("\(String(format: "%.1f", candidate.peakTimeSeconds))s")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(String(format: "%.1f", candidate.peakRemovedMicrovolts)) µV")
                                        .font(.caption.monospacedDigit())
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(candidate.id == wavelet.selectedCandidateID
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// Downsample factors that keep the decimated rate usable (≥ ~100 Hz),
    /// always including the currently-selected factor so the picker stays valid.
    private func downsampleFactorOptions(for rate: Double) -> [Int] {
        var options = [1, 2, 4, 8].filter { $0 == 1 || rate / Double($0) >= 100 }
        if !options.contains(wavelet.config.downsampleFactor) {
            options.append(wavelet.config.downsampleFactor)
        }
        return options.sorted()
    }

    private func downsampleFactorLabel(factor: Int, rate: Double) -> String {
        let decimatedRate = Int((rate / Double(max(factor, 1))).rounded())
        return factor == 1 ? "Full (\(decimatedRate) Hz)" : "\(decimatedRate) Hz"
    }

    private var selectedWaveletCandidate: WaveletReductionCandidate? {
        wavelet.candidates.first { $0.id == wavelet.selectedCandidateID }
            ?? wavelet.candidates.first
    }

    @ViewBuilder
    private func waveletCandidatePlot(candidate: WaveletReductionCandidate, input: MFFSignalData) -> some View {
        let channel = candidate.channelIndex
        let start = candidate.startSample
        let end = min(candidate.endSample, input.data[safe: channel]?.count ?? 0)
        let original = input.data[safe: channel].map { Array($0[start..<max(start, end)]) } ?? []
        let cleaned = wavelet.reducedSignal?.data[safe: channel].map { Array($0[start..<min(end, $0.count)]) } ?? []
        let removed = wavelet.artifact?.data[safe: channel].map { Array($0[start..<min(end, $0.count)]) } ?? []
        let scale = (original.map(abs).max() ?? 1)

        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            GeometryReader { geo in
                ZStack {
                    tracePath(original, in: geo.size, scale: scale).stroke(Color.secondary, lineWidth: 1)
                    tracePath(removed, in: geo.size, scale: scale).stroke(Color.red.opacity(0.85), lineWidth: 1)
                    tracePath(cleaned, in: geo.size, scale: scale).stroke(Color.accentColor, lineWidth: 1.3)
                }
                .padding(6)
            }
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    legendDot(.secondary, "Original")
                    legendDot(.red.opacity(0.85), "Removed")
                    legendDot(.accentColor, "Cleaned")
                }
                .font(.caption2)
                .padding(.bottom, 4)
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func tracePath(_ samples: [Float], in size: CGSize, scale: Float) -> Path {
        Path { path in
            guard samples.count > 1, scale > 0 else { return }
            let midY = size.height / 2
            let amp = Double(size.height) / 2 * 0.9
            for index in samples.indices {
                let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let y = midY - CGFloat(Double(samples[index]) / Double(scale) * amp)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    @ViewBuilder
    private func waveletPerLevelBars(result: WaveletReductionResult) -> some View {
        let metrics = Array(result.perChannel.values)
        let levelCount = metrics.map(\.removedEnergyByLevel.count).max() ?? 0
        if levelCount > 0 {
            let averages: [Double] = (0..<levelCount).map { level in
                let values = metrics.compactMap { $0.removedEnergyByLevel[safe: level] }
                return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Removed energy by level (fine → coarse)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(averages.indices, id: \.self) { level in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.red.opacity(0.7))
                                .frame(height: max(2, CGFloat(averages[level]) * 44))
                            Text("\(level + 1)")
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 56, alignment: .bottom)
            }
        }
    }

    @ViewBuilder
    private func waveletReductionQCView(result: WaveletReductionResult) -> some View {
        let metrics = Array(result.perChannel.values)
        let meanPeak = metrics.isEmpty ? 0 : metrics.map(\.peakReductionPercent).reduce(0, +) / Double(metrics.count)
        let meanRemoved = metrics.isEmpty ? 0 : metrics.map(\.removedRMSMicrovolts).reduce(0, +) / Double(metrics.count)
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Variance retained").foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", result.varianceRetainedPercent)).monospacedDigit()
                }
                if let band = wavelet.bandVarianceRetained {
                    GridRow {
                        Text("In-band retained").foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", band)).monospacedDigit()
                    }
                }
                GridRow {
                    Text("Mean correlation").foregroundStyle(.secondary)
                    Text(String(format: "%.3f", result.meanCorrelation)).monospacedDigit()
                }
                GridRow {
                    Text("Avg peak reduction").foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", meanPeak)).monospacedDigit()
                }
                GridRow {
                    Text("Avg removed RMS").foregroundStyle(.secondary)
                    Text(String(format: "%.2f µV", meanRemoved)).monospacedDigit()
                }
            }
            .font(.callout)
            Text("Higher variance/correlation = more of the original signal preserved; larger peak reduction/removed RMS = more artifact taken out.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func waveletArtifactExplorerSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Wavelet Artifact Explorer")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(waveletExplorerChannels(in: signal).count) channels · \(Int(signal.samplingRate.rounded())) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    waveletExplorerConfigurationSection(signal: signal)
                    waveletExplorerProgressSection

                    if let waveletExplorerResult {
                        waveletExplorerResultView(waveletExplorerResult, signal: signal)
                    } else {
                        artifactDefinitionEmptyPreview(
                            title: "No wavelet explorer scan yet",
                            detail: "Run a broad multiscale scan to rank transient artifact candidates, noisy channels, and dominant wavelet levels."
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Clear Results") {
                    waveletExplorerResult = nil
                    waveletExplorerLog.removeAll()
                    waveletExplorerProgress = 0
                    waveletExplorerStatusTitle = "Wavelet artifact explorer ready"
                    waveletExplorerStatusDetail = "\(waveletExplorerChannels(in: signal).count) channels selected for exploratory multiscale scanning."
                    waveletExplorerStatusMessage = nil
                }
                .disabled(isRunningWaveletArtifactExplorer && waveletExplorerResult == nil && waveletExplorerLog.isEmpty)

                Spacer()

                Button("Close") {
                    showsWaveletArtifactExplorer = false
                }
                .keyboardShortcut(.cancelAction)

                Button(waveletExplorerResult == nil ? "Run Wavelet Scan" : "Rescan Wavelets") {
                    runWaveletArtifactExplorer(in: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunningWaveletArtifactExplorer || waveletExplorerChannels(in: signal).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 860)
        .frame(minHeight: 640, idealHeight: 760, maxHeight: 820)
    }

    private func waveletExplorerConfigurationSection(signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Pipeline",
                        help: "Preset defaults for HAPPE-inspired wavelet cleaning. EEG emphasizes stronger transient rejection; ERP keeps a smoother, gentler residual."
                    )
                    Picker(
                        "Pipeline",
                        selection: Binding {
                            waveletExplorerPipeline
                        } set: { pipeline in
                            waveletExplorerPipeline = pipeline
                            applyWaveletExplorerPipelineDefaults(pipeline, samplingRate: signal.samplingRate)
                        }
                    ) {
                        ForEach(WaveletCleaningPipeline.allCases) { pipeline in
                            Text(pipeline.rawValue).tag(pipeline)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)

                    ArtifactTemplateFieldLabel(
                        title: "Wavelet",
                        help: "bior4.4 is the non-ERP HAPPE-style choice; coif4 is the ERP-oriented choice."
                    )
                    Picker("Wavelet", selection: $waveletExplorerWaveletFamily) {
                        ForEach(WaveletCleaningFamily.allCases) { family in
                            Text(family.rawValue).tag(family)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Mode",
                        help: "Cleaning profile layered on top of the EEG/ERP pipeline."
                    )
                    Picker(
                        "Mode",
                        selection: Binding {
                            waveletExplorerCleaningMode
                        } set: { mode in
                            waveletExplorerCleaningMode = mode
                            applyWaveletExplorerCleaningModeDefaults(mode)
                        }
                    ) {
                        ForEach(WaveletCleaningMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Intensity",
                        help: "Higher values lower the effective coefficient gate and show stronger preview removal."
                    )
                    HStack {
                        Slider(value: $waveletExplorerIntensity, in: 0.25...2.50, step: 0.05)
                        Text(String(format: "%.2fx", waveletExplorerIntensity))
                            .font(.caption.monospacedDigit())
                            .frame(width: 46, alignment: .trailing)
                    }
                    .frame(width: 190)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Channels",
                        help: "Channels included in the broad wavelet artifact scan."
                    )
                    Picker("Channels", selection: $waveletExplorerChannelScope) {
                        ForEach(WaveletExplorerChannelScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Downsample Hz",
                        help: "Temporary sampling rate for exploratory scanning. Lower rates are faster and usually enough for broad artifacts."
                    )
                    TextField("Hz", value: $waveletExplorerDownsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Levels",
                        help: "Number of undecimated wavelet detail levels to inspect."
                    )
                    Stepper(value: $waveletExplorerLevelCount, in: 1...WaveletArtifactAnalyzer.maximumLevelCount) {
                        Text("\(waveletExplorerLevelCount)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 30, alignment: .leading)
                    }
                    .frame(width: 180, alignment: .leading)

                    ArtifactTemplateFieldLabel(
                        title: "Model",
                        help: "Universal uses a robust MAD threshold per level. BayesShrink adapts each level's threshold from estimated noise and signal variance."
                    )
                    Picker("Model", selection: $waveletExplorerThresholdModel) {
                        ForEach(WaveletCleaningThresholdModel.allCases) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Rule",
                        help: "Hard thresholding removes retained coefficients directly; soft thresholding shrinks retained coefficients for smoother ERP-style cleanup."
                    )
                    Picker("Rule", selection: $waveletExplorerThresholdRule) {
                        ForEach(WaveletCleaningThresholdRule.allCases) { rule in
                            Text(rule.rawValue).tag(rule)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)

                    ArtifactTemplateFieldLabel(
                        title: "Coeff Gate",
                        help: "Multiplier on each channel/level's coefficient threshold after the selected model estimates it."
                    )
                    HStack {
                        Slider(value: $waveletExplorerThresholdScale, in: 0.50...3.00, step: 0.05)
                        Text(String(format: "%.2fx", waveletExplorerThresholdScale))
                            .font(.caption.monospacedDigit())
                            .frame(width: 46, alignment: .trailing)
                    }
                    .frame(width: 190)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Merge (s)",
                        help: "Nearby wavelet bursts closer than this interval are merged into one candidate."
                    )
                    TextField("Merge", value: $waveletExplorerMergeWindowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Min Dur (s)",
                        help: "Shortest over-threshold wavelet burst to keep as a candidate."
                    )
                    TextField("Duration", value: $waveletExplorerMinimumDurationSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {

                    ArtifactTemplateFieldLabel(
                        title: "Candidates",
                        help: "Maximum number of ranked wavelet artifact candidates retained for review."
                    )
                    Stepper(value: $waveletExplorerMaximumCandidates, in: 10...300, step: 10) {
                        Text("\(waveletExplorerMaximumCandidates)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .leading)
                    }
                    .frame(width: 180, alignment: .leading)

                    Text("")
                        .gridCellColumns(2)
                }

                GridRow {
                    Text("\(waveletExplorerChannels(in: signal).count) readable channels · \(waveletExplorerThresholdModel.rawValue) · effective gate \(String(format: "%.2fx", effectiveWaveletExplorerThresholdScale)) · bad channels excluded where applicable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(4)
                }
            }
        }
        .disabled(isRunningWaveletArtifactExplorer)
    }

    private var waveletExplorerProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(waveletExplorerStatusTitle.nilIfEmpty ?? "Wavelet scan idle")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int((waveletExplorerProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: waveletExplorerProgress)
                .progressViewStyle(.linear)

            Text(waveletExplorerStatusDetail.nilIfEmpty ?? "Configure the scan and run the explorer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isRunningWaveletArtifactExplorer && !waveletExplorerLog.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(waveletExplorerLog.suffix(80))) { line in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.title)
                                    .font(.caption2.weight(.semibold))
                                Text(line.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 118)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func waveletExplorerResultView(_ result: WaveletArtifactExplorerResult, signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                waveletExplorerMetricChip(title: "Candidates", value: "\(result.candidates.count)")
                waveletExplorerMetricChip(title: "Artifact energy", value: waveletExplorerPercent(result.summary.artifactEnergyFraction))
                waveletExplorerMetricChip(title: "Effective Hz", value: String(format: "%.1f", result.effectiveSamplingRate))
                waveletExplorerMetricChip(title: "Threshold", value: String(format: "%.3f", result.candidateThreshold))
            }

            HStack(alignment: .top, spacing: 16) {
                waveletExplorerChannelSummary(result.summary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                waveletExplorerLevelSummary(result.summary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            waveletExplorerCandidateTable(result.candidates, signal: signal)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func waveletExplorerMetricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func waveletExplorerChannelSummary(_ summary: WaveletArtifactFeatureSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strongest channels")
                .font(.caption.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Ch")
                    Text("Energy")
                    Text("Peak")
                    Text("Level")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(summary.strongestChannels.prefix(8)) { channel in
                    GridRow {
                        Text("\(channel.channelIndex + 1)")
                        Text(waveletExplorerPercent(channel.artifactEnergyFraction))
                        Text(waveletExplorerMicrovolts(channel.peakArtifactMagnitude))
                        Text("L\(channel.dominantLevel)")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func waveletExplorerLevelSummary(_ summary: WaveletArtifactFeatureSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dominant levels")
                .font(.caption.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Level")
                    Text("Center Hz")
                    Text("Energy")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(summary.levelSummaries) { level in
                    GridRow {
                        Text("L\(level.level)")
                        Text(String(format: "%.1f", level.centerFrequencyHz))
                        Text(waveletExplorerPercent(level.artifactEnergyFraction))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func waveletExplorerCandidateTable(_ candidates: [WaveletArtifactCandidate], signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ranked candidates")
                .font(.caption.weight(.semibold))

            if candidates.isEmpty {
                Text("No over-threshold wavelet bursts met the current duration and merge settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        GridRow {
                            Text("#")
                            Text("Peak")
                            Text("Duration")
                            Text("Score")
                            Text("Peak Ch")
                            Text("Level")
                            Text("Contrib")
                            Text("Preview")
                            Text("")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ForEach(candidates) { candidate in
                            GridRow {
                                Text("\(candidate.rank)")
                                Text(formattedEventTime(candidate.peakTimeSeconds))
                                Text(String(format: "%.3fs", candidate.durationSeconds))
                                Text(String(format: "%.3f", candidate.score))
                                Text("Ch \(candidate.channelIndex + 1)")
                                Text("L\(candidate.dominantLevel)")
                                Text("\(candidate.contributingChannelCount)")
                                WaveletCleaningPreviewButton(
                                    candidate: candidate,
                                    signal: signal,
                                    configuration: waveletCleaningConfiguration(for: signal, candidate: candidate)
                                )
                                Button("Jump") {
                                    jumpToWaveletCandidate(candidate, in: signal)
                                }
                                .font(.caption)
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 190)
            }
        }
    }

    private func applyWaveletExplorerPipelineDefaults(
        _ pipeline: WaveletCleaningPipeline,
        samplingRate: Double,
        updatesStatus: Bool = true
    ) {
        waveletExplorerWaveletFamily = pipeline.defaultFamily
        waveletExplorerThresholdRule = pipeline.defaultThresholdRule
        waveletExplorerThresholdModel = pipeline.defaultThresholdModel
        waveletExplorerThresholdScale = pipeline.defaultThresholdScale
        let defaultMode: WaveletCleaningMode = pipeline == .erp ? .erpGentle : .conservativeLocal
        waveletExplorerCleaningMode = defaultMode
        waveletExplorerIntensity = defaultMode.defaultIntensity
        waveletExplorerLevelCount = min(
            max(pipeline.defaultLevelCount(samplingRate: samplingRate), 1),
            WaveletArtifactAnalyzer.maximumLevelCount
        )

        guard updatesStatus else { return }
        waveletExplorerStatusTitle = "\(pipeline.rawValue) wavelet defaults applied"
        waveletExplorerStatusDetail = "\(pipeline.defaultFamily.rawValue), \(pipeline.defaultThresholdModel.rawValue), \(pipeline.defaultThresholdRule.rawValue.lowercased()) threshold, \(defaultMode.rawValue), \(waveletExplorerLevelCount) levels, and a \(String(format: "%.2f", effectiveWaveletExplorerThresholdScale))x effective coefficient gate. You can still edit every value."
        waveletExplorerStatusMessage = nil
    }

    private func applyWaveletExplorerCleaningModeDefaults(
        _ mode: WaveletCleaningMode,
        updatesStatus: Bool = true
    ) {
        waveletExplorerIntensity = mode.defaultIntensity
        guard updatesStatus else { return }
        waveletExplorerStatusTitle = "\(mode.rawValue) mode applied"
        waveletExplorerStatusDetail = "Intensity \(String(format: "%.2f", waveletExplorerIntensity))x gives a \(String(format: "%.2f", effectiveWaveletExplorerThresholdScale))x effective coefficient gate with the current pipeline settings."
        waveletExplorerStatusMessage = nil
    }

    private var effectiveWaveletExplorerThresholdScale: Double {
        max(
            0.05,
            waveletExplorerThresholdScale
                * waveletExplorerCleaningMode.thresholdMultiplier
                / max(waveletExplorerIntensity, 0.10)
        )
    }

    private func waveletCleaningConfiguration(
        for signal: MFFSignalData,
        candidate: WaveletArtifactCandidate
    ) -> WaveletCleaningConfiguration {
        let channels = Array(Set(waveletExplorerChannels(in: signal) + [candidate.channelIndex])).sorted()
        return WaveletCleaningConfiguration(
            pipeline: waveletExplorerPipeline,
            mode: waveletExplorerCleaningMode,
            channelIndices: channels,
            waveletFamily: waveletExplorerWaveletFamily,
            thresholdRule: waveletExplorerThresholdRule,
            thresholdModel: waveletExplorerThresholdModel,
            levelCount: waveletExplorerLevelCount,
            thresholdScale: effectiveWaveletExplorerThresholdScale,
            intensity: waveletExplorerIntensity,
            paddingSeconds: min(max(candidate.durationSeconds, 0.08), 0.30)
        )
    }

    private func runWaveletArtifactExplorer(in signal: MFFSignalData) {
        guard !isRunningWaveletArtifactExplorer else { return }
        let channelIndices = waveletExplorerChannels(in: signal)
        guard !channelIndices.isEmpty else {
            waveletExplorerStatusMessage = "Wavelet explorer has no readable channels to scan."
            return
        }

        waveletExplorerRunGeneration += 1
        let generation = waveletExplorerRunGeneration
        waveletExplorerResult = nil
        waveletExplorerLog.removeAll()
        waveletExplorerProgress = 0
        waveletExplorerStatusTitle = "Starting wavelet artifact explorer"
        waveletExplorerStatusDetail = "Preparing \(channelIndices.count) channels for broad multiscale artifact discovery."
        waveletExplorerStatusMessage = nil
        isRunningWaveletArtifactExplorer = true

        let configuration = WaveletArtifactExplorerConfiguration(
            channelIndices: channelIndices,
            downsampleRate: min(max(waveletExplorerDownsampleRate, 20), signal.samplingRate),
            levelCount: waveletExplorerLevelCount,
            thresholdScale: effectiveWaveletExplorerThresholdScale,
            cleaningMode: waveletExplorerCleaningMode,
            intensity: waveletExplorerIntensity,
            waveletFamily: waveletExplorerWaveletFamily,
            thresholdRule: waveletExplorerThresholdRule,
            thresholdModel: waveletExplorerThresholdModel,
            mergeWindowSeconds: max(waveletExplorerMergeWindowSeconds, 0.001),
            minimumDurationSeconds: max(waveletExplorerMinimumDurationSeconds, 0.001),
            maximumCandidates: waveletExplorerMaximumCandidates
        )

        waveletExplorerTask?.cancel()
        let sessionID = recordingSessionID
        waveletExplorerTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                WaveletArtifactAnalyzer.explore(in: signal, configuration: configuration) { update in
                    Task { @MainActor in
                        publishWaveletExplorerProgress(update, generation: generation)
                    }
                }
            }
            let result = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )

            guard !Task.isCancelled,
                  sessionID == recordingSessionID,
                  generation == waveletExplorerRunGeneration else { return }
            waveletExplorerResult = result
            waveletExplorerProgress = 1
            waveletExplorerStatusTitle = "Wavelet artifact explorer scan complete"
            waveletExplorerStatusDetail = "\(result.candidates.count) candidates across \(result.channelCount) channels over \(String(format: "%.1f", result.analyzedDurationSeconds)) seconds."
            waveletExplorerStatusMessage = "\(result.candidates.count) wavelet candidates found"
            isRunningWaveletArtifactExplorer = false
            waveletExplorerTask = nil
        }
    }

    @MainActor
    private func publishWaveletExplorerProgress(_ update: WaveletArtifactExplorerProgress, generation: Int) {
        guard generation == waveletExplorerRunGeneration else { return }
        waveletExplorerProgress = update.fraction
        waveletExplorerStatusTitle = update.title
        waveletExplorerStatusDetail = update.detail
        waveletExplorerLog.append(WaveletArtifactExplorerLogLine(
            title: "\(Int((update.fraction * 100).rounded()))% · \(update.title)",
            detail: update.detail
        ))
        if waveletExplorerLog.count > 240 {
            waveletExplorerLog.removeFirst(waveletExplorerLog.count - 240)
        }
    }

    private func waveletExplorerChannels(in signal: MFFSignalData) -> [Int] {
        switch waveletExplorerChannelScope {
        case .visibleGood:
            return signal.data.indices.filter { !channels.hidden.contains($0) && !channels.bad.contains($0) }
        case .allGood:
            return signal.data.indices.filter { !channels.bad.contains($0) }
        case .all:
            return Array(signal.data.indices)
        case .ocular:
            return ocularTemplateChannels(channelCount: signal.numberOfChannels)
                .filter { signal.data.indices.contains($0) && !channels.bad.contains($0) }
        }
    }

    private func jumpToWaveletCandidate(_ candidate: WaveletArtifactCandidate, in signal: MFFSignalData) {
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return }
        let lower = min(max(candidate.startSample, 0), sampleCount - 1)
        let upper = min(max(candidate.endSample, lower), sampleCount - 1)
        selectedSampleRange = lower...upper
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        selectedEventID = nil

        let plotWidth = plotWidth(for: signal)
        let centerX = (contentX(forSample: lower, in: signal) + contentX(forSample: upper + 1, in: signal)) / 2
        let viewportCenter = max(horizontalViewportWidth / 2, 1)
        let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
        let clampedOffset = min(max(centerX - viewportCenter, 0), maxOffset)

        isSyncingSliderFromScroll = true
        horizontalJumpValue = maxOffset > 0 ? Double(clampedOffset / maxOffset) : 0
        isSyncingSliderFromScroll = false
        horizontalScrollPosition.scrollTo(x: clampedOffset)
    }

    private func waveletExplorerPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func waveletExplorerMicrovolts(_ value: Float) -> String {
        if value >= 100 {
            return String(format: "%.0f µV", value)
        }
        if value >= 10 {
            return String(format: "%.1f µV", value)
        }
        return String(format: "%.2f µV", value)
    }

    // MARK: - Wavelet reduction

    private func openWaveletReductionSheet(input: MFFSignalData) {
        // Initialize the config from the current mode's defaults for this rate
        // unless a run already established settings.
        if wavelet.result == nil {
            wavelet.config = wavelet.mode.defaultConfiguration(samplingRate: input.samplingRate)
        }
        wavelet.showsSheet = true
    }

    private func setWaveletReductionEnabled(_ isEnabled: Bool) {
        guard wavelet.reducedSignal != nil, wavelet.isEnabled != isEnabled else { return }
        wavelet.isEnabled = isEnabled
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    private func revertWaveletReduction() {
        guard wavelet.reducedSignal != nil else { return }
        wavelet.reducedSignal = nil
        wavelet.artifact = nil
        wavelet.result = nil
        wavelet.bandVarianceRetained = nil
        wavelet.statusMessage = "Reverted wavelet reduction."
        wavelet.candidates = []
        wavelet.selectedCandidateID = nil
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
        artifactVM.detectionRefreshToken += 1
    }

    private func runWaveletReduction(on input: MFFSignalData) {
        guard !wavelet.isRunning else { return }
        let config = wavelet.config
        let mode = wavelet.mode
        let cores = wavelet.coreCount
        let analysisBand: (low: Double, high: Double)? = {
            guard let low = filter.highPassCutoff,
                  let high = filter.lowPassCutoff else {
                return nil
            }
            return (low, high)
        }()
        // Leave bad channels untouched; reduce everything else.
        let reduceIndices = input.data.indices.filter { !channels.bad.contains($0) }

        wavelet.isRunning = true
        wavelet.progress = 0
        wavelet.statusMessage = "Running wavelet reduction…"
        wavelet.bandVarianceRetained = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            wavelet.progress = min(max(fraction, 0), 1)
        }

        waveletReductionTask?.cancel()
        let sessionID = recordingSessionID
        waveletReductionTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                WaveletReducer.reduce(
                    signal: input,
                    channelIndices: Array(reduceIndices),
                    configuration: config,
                    coreCount: cores
                ) { fraction in
                    progressContinuation.yield(fraction * (mode.assessesInBand ? 0.8 : 1.0))
                }
            }
            let result = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )

            // ERP path: assess variance retained within the analysis band, as HAPPE does.
            var bandRetained: Double?
            if !Task.isCancelled,
               sessionID == recordingSessionID,
               mode.assessesInBand,
               let analysisBand,
               analysisBand.high > analysisBand.low,
               analysisBand.high < input.samplingRate / 2 {
                let bandWorker = Task.detached(priority: .utility) {
                    await bandLimitedVarianceRetained(
                        original: input,
                        cleaned: result.cleaned,
                        channelIndices: Array(reduceIndices),
                        band: analysisBand
                    )
                }
                bandRetained = await withTaskCancellationHandler(
                    operation: {
                        await bandWorker.value
                    },
                    onCancel: {
                        bandWorker.cancel()
                    }
                )
            }

            progressContinuation.finish()
            progressTask.cancel()

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            wavelet.reducedSignal = result.cleaned
            wavelet.artifact = result.artifact
            wavelet.result = result
            wavelet.bandVarianceRetained = bandRetained
            wavelet.candidates = WaveletReducer.findCandidates(
                artifact: result.artifact,
                channelIndices: Array(reduceIndices),
                maxCount: 40
            )
            wavelet.selectedCandidateID = wavelet.candidates.first?.id
            wavelet.isEnabled = true
            wavelet.isRunning = false
            wavelet.progress = 1
            let varianceText = String(format: "%.1f%%", result.varianceRetainedPercent)
            wavelet.statusMessage = "Reduced \(reduceIndices.count) channels · \(varianceText) variance retained · r \(String(format: "%.2f", result.meanCorrelation))"
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
            artifactVM.detectionRefreshToken += 1
            waveletReductionTask = nil
        }
    }

    /// Filters original and cleaned signals to the analysis band and returns the
    /// variance retained = var(cleaned_band)/var(original_band) over the reduced
    /// channels, mirroring HAPPE's in-band ERP quality assessment.
    private nonisolated func bandLimitedVarianceRetained(
        original: MFFSignalData,
        cleaned: MFFSignalData,
        channelIndices: [Int],
        band: (low: Double, high: Double)
    ) async -> Double? {
        do {
            let originalBand = try await EEGSignalFilter.bandPass(
                channels: channelIndices.map { original.data[$0] },
                samplingRate: original.samplingRate,
                lowCutoff: band.low,
                highCutoff: band.high
            )
            let cleanedBand = try await EEGSignalFilter.bandPass(
                channels: channelIndices.map { cleaned.data[$0] },
                samplingRate: cleaned.samplingRate,
                lowCutoff: band.low,
                highCutoff: band.high
            )
            var originalVariance = 0.0
            var cleanedVariance = 0.0
            for index in originalBand.indices {
                originalVariance += variance(of: originalBand[index])
                cleanedVariance += variance(of: cleanedBand[index])
            }
            guard originalVariance > 1e-12 else { return nil }
            return cleanedVariance / originalVariance * 100
        } catch {
            return nil
        }
    }

    private nonisolated func variance(of values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        return values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(values.count)
    }

    func applyArtifactCleaning(to signal: MFFSignalData) {
        let artifacts = template.definedArtifacts
        guard artifacts.contains(where: { $0.cleaningMethod.removesArtifact }) else {
            restoreArtifactCleaning()
            return
        }

        artifactVM.isCleaning = true
        artifactVM.cleaningStatusMessage = nil
        artifactVM.cleaningProgress = nil
        let badChannels = channels.bad
        let (progressContinuation, progressTask) = ProgressBridge.make { progress in
            artifactVM.cleaningProgress = progress
        }

        artifactCleaningTask?.cancel()
        let sessionID = recordingSessionID
        artifactCleaningTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                ArtifactCleaner.cleanedSignal(
                    from: signal,
                    artifacts: artifacts,
                    excluding: badChannels
                ) { progress in
                    progressContinuation.yield(progress)
                }
            }
            let outcome = await withTaskCancellationHandler(
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

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            artifactVM.cleanedSignal = outcome.signal
            artifactVM.cleaningIsEnabled = true
            artifactVM.cleaningSummaries = outcome.summaries
            let summariesByID = Dictionary(uniqueKeysWithValues: outcome.summaries.map { ($0.artifactID, $0) })
            let now = Date()
            for index in template.definedArtifacts.indices {
                if summariesByID[template.definedArtifacts[index].id] != nil,
                   template.definedArtifacts[index].cleaningMethod.removesArtifact {
                    template.definedArtifacts[index].appliedMethod = template.definedArtifacts[index].cleaningMethod
                    template.definedArtifacts[index].cleanedAt = now
                } else {
                    template.definedArtifacts[index].appliedMethod = nil
                    template.definedArtifacts[index].cleanedAt = nil
                }
            }

            artifactVM.cleaningStatusMessage = artifactCleaningSummaryText(outcome.summaries)
            artifactVM.statusMessage = artifactVM.cleaningStatusMessage
            artifactVM.detectionRefreshToken += 1
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
            artifactVM.cleaningProgress = nil
            artifactVM.isCleaning = false
            artifactCleaningTask = nil
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

    func restoreArtifactCleaning() {
        clearAppliedArtifactCleaning()
        artifactVM.cleaningStatusMessage = "Artifact cleaning restored to the current uncleaned signal."
        artifactVM.statusMessage = artifactVM.cleaningStatusMessage
    }

    func clearAppliedArtifactCleaning() {
        let hadCleaning = artifactVM.cleanedSignal != nil || template.definedArtifacts.contains { $0.appliedMethod != nil }
        artifactVM.cleanedSignal = nil
        artifactVM.cleaningIsEnabled = true
        artifactVM.cleaningSummaries = []
        artifactVM.cleaningProgress = nil
        artifactVM.cleaningStatusMessage = nil
        for index in template.definedArtifacts.indices {
            template.definedArtifacts[index].appliedMethod = nil
            template.definedArtifacts[index].cleanedAt = nil
        }
        guard hadCleaning else { return }
        artifactVM.detectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    var artifactScanSignature: ArtifactScanSignature {
        ArtifactScanSignature(
            eventCode: template.eventCode,
            clickedChannel: template.clickedChannel,
            channelScope: template.channelScope,
            customChannels: template.customChannels,
            threshold: template.threshold,
            windowSeconds: template.windowSeconds,
            downsampleRate: template.downsampleRate,
            mergeWindowSeconds: template.mergeWindowSeconds,
            polarity: template.polarity,
            range: template.selectionRange
        )
    }

    /// True when settings have changed since the displayed result was produced
    /// (or no scan has run yet).
    var artifactTemplateScanIsStale: Bool {
        template.lastScanSignature != artifactScanSignature
    }

    /// Builds the detector configuration from the current sheet controls.
    func artifactTemplateConfiguration(
        for signal: MFFSignalData,
        range: ClosedRange<Int>
    ) -> ArtifactTemplateConfiguration {
        ArtifactTemplateConfiguration(
            name: template.name.trimmingCharacters(in: .whitespacesAndNewlines),
            eventCode: template.eventCode.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedChannelIndices: artifactTemplateSelectedChannels(in: signal),
            comparisonChannelIndices: Array(signal.data.indices),
            exemplarRange: range,
            matchThreshold: template.threshold,
            windowSizeSeconds: max(template.windowSeconds, 0.01),
            downsampleRate: min(max(template.downsampleRate, 20), signal.samplingRate),
            mergeWindowSeconds: max(template.mergeWindowSeconds, 0.01),
            polarity: template.polarity,
            comparisonScopes: artifactTemplateComparisonScopes(in: signal),
            topographyMode: template.topographyMode,
            topographyChannelIndices: artifactTopographyChannels(in: signal),
            topographyMetric: template.topographyMetric,
            trajectoryShiftSeconds: template.trajectoryShiftSeconds,
            trajectoryScaleRange: template.trajectoryScaleRange,
            trajectoryGFPWeighted: template.trajectoryGFPWeighted
        )
    }

    /// Channels used for the scalp-topography correlation: all readable channels
    /// minus bad channels (and, in future, restricted to a selected cluster).
    func artifactTopographyChannels(in signal: MFFSignalData) -> [Int] {
        let goodChannels = signal.data.indices.filter { !channels.bad.contains($0) }
        switch template.topographyChannelScope {
        case .allGood:
            return goodChannels
        case .topN:
            guard let range = template.selectionRange,
                  !goodChannels.isEmpty else { return goodChannels }
            let n = max(min(template.topographyTopN, goodChannels.count), 3)
            // Rank by RMS amplitude over the exemplar window.
            let scored: [(Int, Float)] = goodChannels.map { chIdx in
                let ch = signal.data[chIdx]
                let lo = max(range.lowerBound, 0)
                let hi = min(range.upperBound, ch.count - 1)
                guard lo <= hi else { return (chIdx, Float(0)) }
                let slice = ch[lo...hi]
                let mean = slice.reduce(Float(0), +) / Float(slice.count)
                let rms  = sqrt(slice.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
                                / Float(slice.count))
                return (chIdx, rms)
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(n).map { $0.0 }.sorted()
        case .channelSet:
            guard let id = template.topographyChannelSetID,
                  let set = ChannelSetStore.shared.allSets.first(where: { $0.id == id })
            else { return goodChannels }
            // Intersect the set with good channels that exist in this recording.
            let setIndices = Set(set.channelIndices)
            return goodChannels.filter { setIndices.contains($0) }
        }
    }

    func artifactTemplateSelectedChannels(in signal: MFFSignalData) -> [Int] {
        switch template.channelScope {
        case .clickedChannel:
            if let clickedChannel = template.clickedChannel, signal.data.indices.contains(clickedChannel) {
                return [clickedChannel]
            }
            return []
        case .ocularChannels:
            return ocularTemplateChannels(channelCount: signal.numberOfChannels)
        case .visibleChannels:
            return signal.data.indices.filter { !channels.hidden.contains($0) }
        case .allChannels:
            return Array(signal.data.indices)
        case .specificChannels:
            return WaveformView.parseChannelList(template.customChannels, channelCount: signal.numberOfChannels)
        }
    }

    private func artifactTemplateComparisonScopes(in signal: MFFSignalData) -> [ArtifactTemplateComparisonScope] {
        var scopes: [ArtifactTemplateComparisonScope] = [
            ArtifactTemplateComparisonScope(
                name: ArtifactTemplateChannelScope.clickedChannel.rawValue,
                channelIndices: template.clickedChannel.map { [$0] } ?? []
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

        let specificChannels = WaveformView.parseChannelList(template.customChannels, channelCount: signal.numberOfChannels)
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

    static func parseChannelList(_ text: String, channelCount: Int) -> [Int] {
        let separators = CharacterSet(charactersIn: ",; ").union(.newlines)
        var indices = Set<Int>()
        for rawToken in text.components(separatedBy: separators) {
            let token = rawToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-")
            guard !token.isEmpty else { continue }

            let bounds = token.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
            if bounds.count == 2 {
                let lower = min(bounds[0], bounds[1])
                let upper = max(bounds[0], bounds[1])
                for oneBased in lower...upper {
                    let zeroBased = oneBased - 1
                    if zeroBased >= 0 && zeroBased < channelCount {
                        indices.insert(zeroBased)
                    }
                }
            } else if let oneBased = Int(token) {
                let zeroBased = oneBased - 1
                if zeroBased >= 0 && zeroBased < channelCount {
                    indices.insert(zeroBased)
                }
            }
        }
        return indices.sorted()
    }

    func saveArtifactTemplateJSON(_ saved: SavedArtifactTemplate?) {
        guard let saved else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(saved.name.replacingOccurrences(of: " ", with: "-")).artifact.json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(saved)
            try data.write(to: url, options: .atomic)
            template.statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            template.statusMessage = error.localizedDescription
        }
    }

    // MARK: - ICA artifact exploration

    private func openICASheet(for signal: MFFSignalData) {
        ica.componentCount = min(max(ica.componentCount, 1), signal.numberOfChannels)
        ica.downsampleRate = min(ica.downsampleRate, signal.samplingRate)
        ica.statusMessage = nil
        artifactVM.detectionMethod = .ica
        ica.showsSheet = true
    }

    private func icaSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("ICA Artifact Components")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let decomp = ica.decomposition {
                    Text("\(decomp.componentCount) components · \(Int(decomp.analysisSamplingRate)) Hz")
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
                    Picker("Method", selection: $ica.method) {
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
                    TextField("Components", value: $ica.componentCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Search Hz",
                        help: "Temporary downsample rate used only for fitting and previewing ICA — the selected components are still removed from the full-rate EEG afterward. This auto-scales to the fit filter: by Nyquist the rate only needs to be just above twice the highest frequency the filter keeps (≈2× the high cutoff, or 2× 60 Hz when the notch is on), so it can be far lower than the recording rate, which is what makes the fit fast. You can always set it higher."
                    )
                    TextField("Hz", value: $ica.downsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Iterations",
                        help: "Maximum solver iterations. Picard and FastICA typically converge in well under this; it acts mainly as a safety cap. Infomax may use more."
                    )
                    TextField("Iterations", value: $ica.maxIterations, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Keep Var",
                        help: "PCA variance target used to choose how many components to keep, capped by the Components field. 99.9% is a practical default for preserving blink components while still avoiding near-zero noisy directions."
                    )
                    TextField("Fraction", value: $ica.varianceThreshold, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Avg Ref",
                        help: "Subtracts the instantaneous average across channels before ICA fitting. This removes common-mode reference structure that can dominate the first PCA direction."
                    )
                    Toggle("Use", isOn: $ica.usesAverageReference)
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
                    Toggle("Use", isOn: $ica.usesFitFilter)
                        .toggleStyle(.checkbox)

                    ArtifactTemplateFieldLabel(
                        title: "Fit Hz",
                        help: "Band-pass range used only for fitting ICA. The selected components are still removed from the full-rate EEG after review."
                    )
                    HStack(spacing: 6) {
                        TextField("Low", value: $ica.fitLowCutoff, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                        Text("–")
                            .foregroundStyle(.secondary)
                        TextField("High", value: $ica.fitHighCutoff, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                    }
                    .disabled(!ica.usesFitFilter)

                    Toggle("60 Hz notch", isOn: $ica.fitNotch60HzEnabled)
                        .toggleStyle(.checkbox)
                        .disabled(!ica.usesFitFilter)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Tolerance",
                        help: "MNE-style early stopping threshold for summed squared ICA weight change between iterations. Smaller values may run longer."
                    )
                    TextField("Tolerance", value: $ica.convergenceTolerance, format: .number.notation(.scientific).precision(.significantDigits(2...4)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Min Iter",
                        help: "Minimum number of infomax iterations before tolerance-based early stopping is allowed."
                    )
                    TextField("Min", value: $ica.minimumIterations, format: .number)
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
                .disabled(ica.isRunning)

                if ica.isRunning {
                    ProgressView(value: ica.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                    Text("\(Int((ica.progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(ica.progressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                }

                if let decomp = ica.decomposition, !decomp.excludedComponents.isEmpty {
                    Button("Remove Selected Components") {
                        removeSelectedICAComponents(from: signal)
                    }
                    .disabled(ica.isRemovingComponents)

                    Button("Save JSON…") {
                        saveICAJSON(ica.decomposition)
                    }
                }

                if let decomp = ica.decomposition, !decomp.excludedComponents.isEmpty {
                    Button("Synthesize as PNS Channel") {
                        synthesizeICAAsPNS(decomposition: ica.decomposition, signal: signal)
                    }
                    .help("Sum the checked component activations and add them as a new physio (PNS) channel.")
                }

                if ica.isRemovingComponents {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reconstructing EEG")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") {
                    ica.showsSheet = false
                    // Closing without removing components skips this replay step.
                    if replay.state.isAwaitingDecision { replay.resume(.skip) }
                }
            }

            if let icaStatus = ica.statusMessage {
                Text(icaStatus)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let decomp = ica.decomposition {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(0..<decomp.componentCount, id: \.self) { component in
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
        .onChange(of: ica.usesFitFilter) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
        .onChange(of: ica.fitNotch60HzEnabled) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
        .onChange(of: ica.fitHighCutoff) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
    }

    /// Recommended ICA fit/analysis rate. By Nyquist the rate only needs to be
    /// a little above twice the highest frequency the fit filter preserves, so
    /// it can be far below the recording rate — which is what keeps the fit fast.
    private func recommendedICAAnalysisRate(samplingRate: Double) -> Double {
        let highCutoff = ica.usesFitFilter ? ica.fitHighCutoff : 40.0
        let notchFrequency = (ica.usesFitFilter && ica.fitNotch60HzEnabled) ? 60.0 : 0.0
        let maxFrequency = max(highCutoff, notchFrequency)
        // 20% headroom above the Nyquist minimum, rounded up to a tidy 10 Hz step.
        let raw = max(2.4 * maxFrequency, 100.0)
        let rounded = (raw / 10).rounded(.up) * 10
        return min(rounded, samplingRate)
    }

    private func autoScaleICAAnalysisRate(samplingRate: Double) {
        guard samplingRate > 0 else { return }
        ica.downsampleRate = recommendedICAAnalysisRate(samplingRate: samplingRate)
    }

    private func icaComponentCard(_ component: Int, signal: MFFSignalData) -> some View {
        let isExcluded = ica.decomposition?.excludedComponents.contains(component) == true
        let label = Binding<String>(
            get: { ica.decomposition?.labels[component] ?? "" },
            set: { newValue in ica.decomposition?.labels[component] = newValue }
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
               let values = ica.decomposition?.componentMaps[safe: component] {
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

            if let decomposition = ica.decomposition,
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
                .fill(isExcluded
                      ? Color.red.opacity(0.10)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isExcluded
                              ? Color.red.opacity(0.35)
                              : Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .help(ica.decomposition?.labelSuggestions[component]?.reason ?? "Select components that look like eye, muscle, cardiac, or movement artifacts. Labels are saved with the JSON artifact set.")
    }

    private func icaComponentExcludedBinding(_ component: Int) -> Binding<Bool> {
        Binding(
            get: { ica.decomposition?.excludedComponents.contains(component) == true },
            set: { isSelected in
                if isSelected {
                    ica.decomposition?.excludedComponents.insert(component)
                    if ica.decomposition?.labels[component]?.isEmpty != false {
                        ica.decomposition?.labels[component] = "Artifact"
                    }
                } else {
                    ica.decomposition?.excludedComponents.remove(component)
                }
            }
        )
    }

    private func synthesizeICAAsPNS(decomposition: ICADecomposition?, signal: MFFSignalData) {
        guard let decomposition else { return }
        let indices = decomposition.excludedComponents.sorted()
        guard !indices.isEmpty else { return }

        // Default name: "ICA" + 1-based component numbers joined, e.g. "ICA13".
        let name = "ICA" + indices.map { "\($0 + 1)" }.joined()

        // Sum selected component activations (double precision during accumulation).
        let len = decomposition.componentSources.first?.count ?? 0
        var accum = [Double](repeating: 0, count: len)
        for idx in indices {
            if let src = decomposition.componentSources[safe: idx] {
                for i in 0..<min(accum.count, src.count) {
                    accum[i] += src[i]
                }
            }
        }
        let samples = accum.map { Float($0) }

        syntheticPNSChannels.append(SyntheticPNSChannel(
            name: name,
            samples: samples,
            samplingRate: decomposition.analysisSamplingRate,
            sourceComponents: indices
        ))
        showsPhysioChannels = true
    }

    private func icaExplainedVarianceText(_ component: Int) -> String {
        guard let value = ica.decomposition?.explainedVariance[safe: component],
              let total = ica.decomposition?.explainedVariance.reduce(0, +),
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

    private func runICA(on signal: MFFSignalData, onComplete: (@MainActor () -> Void)? = nil) {
        ica.isRunning = true
        ica.progress = 0
        ica.progressMessage = "Preparing ICA..."
        ica.statusMessage = nil

        let fitLowCutoff = max(ica.fitLowCutoff, 0.1)
        let fitHighCutoff = min(max(ica.fitHighCutoff, 0.2), signal.samplingRate / 2 - 0.1)
        if ica.usesFitFilter, fitHighCutoff <= fitLowCutoff {
            ica.isRunning = false
            ica.statusMessage = "ICA fit filter needs a high cutoff above the low cutoff."
            onComplete?()
            return
        }

        let configuration = ICAConfiguration(
            method: ica.method,
            componentCount: min(max(ica.componentCount, 1), signal.numberOfChannels),
            varianceThreshold: min(max(ica.varianceThreshold, 0.01), 1.0),
            averageReference: ica.usesAverageReference,
            downsampleRate: min(max(ica.downsampleRate, 20), signal.samplingRate),
            maxIterations: max(ica.maxIterations, 1),
            learningRate: nil,
            fitFilter: ica.usesFitFilter ? ICAFitFilterSettings(
                lowCutoff: fitLowCutoff,
                highCutoff: fitHighCutoff,
                notch60HzEnabled: ica.fitNotch60HzEnabled
            ) : nil,
            convergenceTolerance: max(ica.convergenceTolerance, 0),
            minimumIterations: min(max(ica.minimumIterations, 0), max(ica.maxIterations, 1))
        )

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: ICAProgressUpdate) in
            ica.progress = min(max(update.fraction, 0), 1)
            ica.progressMessage = update.message
        }

        icaTask?.cancel()
        let sessionID = recordingSessionID
        icaTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
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

                    try Task.checkCancellation()
                    let decomposition = try ICAArtifactDetector.fit(
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
                    try Task.checkCancellation()
                    return decomposition
                }
                let decomposition = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                        progressContinuation.finish()
                    }
                )
                progressContinuation.finish()
                progressTask.cancel()
                guard !Task.isCancelled, sessionID == recordingSessionID else { return }
                ica.progress = 1
                ica.progressMessage = "ICA complete"
                var labeledDecomposition = decomposition
                let suggestions = ICAComponentAutoLabeler.suggestions(
                    for: decomposition,
                    layout: recording.sensorLayout
                )
                labeledDecomposition.labelSuggestions = suggestions
                for (component, suggestion) in suggestions {
                    labeledDecomposition.labels[component] = suggestion.label
                }
                ica.decomposition = labeledDecomposition
                if decomposition.finalChange.isFinite,
                   decomposition.iterations >= configuration.maxIterations,
                   decomposition.finalChange > configuration.convergenceTolerance {
                    ica.statusMessage = String(
                        format: "ICA stopped at %d iterations. Auto-labeled %d components. Final change %.2g; try more iterations or fewer components.",
                        decomposition.iterations,
                        suggestions.count,
                        decomposition.finalChange
                    )
                } else if decomposition.finalChange.isFinite {
                    ica.statusMessage = String(
                        format: "ICA finished in %d iterations. Auto-labeled %d components. Final change %.2g.",
                        decomposition.iterations,
                        suggestions.count,
                        decomposition.finalChange
                    )
                } else {
                    ica.statusMessage = "ICA finished in \(decomposition.iterations) iterations after learning-rate backoff."
                }
            } catch is CancellationError {
                progressContinuation.finish()
                progressTask.cancel()
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                guard sessionID == recordingSessionID else { return }
                ica.statusMessage = error.localizedDescription
                ica.progressMessage = "ICA failed"
            }
            if sessionID == recordingSessionID {
                ica.isRunning = false
                icaTask = nil
            }
            onComplete?()
        }
    }

    /// Awaitable wrapper around `runICA` for the interactive replay loop.
    @MainActor
    private func runICADecomposition(on signal: MFFSignalData) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            runICA(on: signal, onComplete: { cont.resume() })
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
        guard let decomposition = ica.decomposition,
              !decomposition.excludedComponents.isEmpty else {
            ica.statusMessage = "Select at least one component to remove."
            return
        }

        let excludedComponents = decomposition.excludedComponents
        let shouldRestoreFilter = filter.output != nil
        let beforeDisplaySignal = filter.output ?? signal
        let restoredFilterHighPassCutoff = filter.highPassCutoff
        let restoredFilterLowPassCutoff = filter.lowPassCutoff
        let restoredFilterHighPassCutoffText = filter.highPassCutoffText
        let restoredFilterLowPassCutoffText = filter.lowPassCutoffText
        let restoredNotch60HzEnabled = filter.notch60HzEnabled
        let restoredAmplitudeScale = amplitudeScale
        let restoredTimeScale = timeScale
        let restoredScrollPosition = horizontalScrollPosition
        ica.isRemovingComponents = true
        ica.lastReconstructionDebugReport = """
        ## Last ICA Removal
        Status: reconstruction in progress
        Excluded components: \(excludedComponents.sorted().map { "IC \($0 + 1) \(decomposition.labels[$0] ?? "")" }.joined(separator: ", ").nilIfEmpty ?? "none")
        Before display signal type: \(beforeDisplaySignal.signalType)
        \(debugStatsLine("Before display full", signal: beforeDisplaySignal))
        """
        ica.statusMessage = "Reconstructing EEG..."

        icaRemovalTask?.cancel()
        let sessionID = recordingSessionID
        icaRemovalTask = Task {
            var reconstructionActivationSignal: MFFSignalData?
            if let fitFilter = decomposition.fitFilter {
                do {
                    ica.statusMessage = "Filtering ICA activation copy..."
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
                    filter.statusMessage = error.localizedDescription
                    filter.statusIsError = true
                }
            }

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            ica.statusMessage = "Reconstructing EEG..."
            let cleaningWorker = Task.detached(priority: .userInitiated) {
                ICAArtifactDetector.cleanedSignal(
                    from: signal,
                    activationSignal: reconstructionActivationSignal,
                    decomposition: decomposition,
                    excluding: excludedComponents
                )
            }
            let cleaned = await withTaskCancellationHandler(
                operation: {
                    await cleaningWorker.value
                },
                onCancel: {
                    cleaningWorker.cancel()
                }
            )

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            var restoredFilteredSignal: MFFSignalData?
            if shouldRestoreFilter {
                do {
                    let filterWorker = Task.detached(priority: .userInitiated) {
                        try await EEGSignalFilter.bandPass(
                            channels: cleaned.data,
                            samplingRate: cleaned.samplingRate,
                            lowCutoff: restoredFilterHighPassCutoff,
                            highCutoff: restoredFilterLowPassCutoff,
                            notch60HzEnabled: restoredNotch60HzEnabled
                        )
                    }
                    let filteredData = try await withTaskCancellationHandler(
                        operation: {
                            try await filterWorker.value
                        },
                        onCancel: {
                            filterWorker.cancel()
                        }
                    )

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
                    filter.statusMessage = error.localizedDescription
                    filter.statusIsError = true
                }
            }

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            ica.cleanedSignal = cleaned
            filter.output = restoredFilteredSignal
            clearAppliedArtifactCleaning()
            ica.lastReconstructionDebugReport = icaReconstructionDebugReport(
                beforeBase: signal,
                beforeDisplay: beforeDisplaySignal,
                activationSignal: reconstructionActivationSignal,
                afterBase: cleaned,
                afterDisplay: restoredFilteredSignal ?? cleaned,
                decomposition: decomposition,
                excludedComponents: excludedComponents
            )
            filter.highPassCutoffText = restoredFilterHighPassCutoffText
            filter.lowPassCutoffText = restoredFilterLowPassCutoffText
            filter.notch60HzEnabled = restoredNotch60HzEnabled
            amplitudeScale = restoredAmplitudeScale
            timeScale = restoredTimeScale
            horizontalScrollPosition = restoredScrollPosition
            artifactVM.events = []
            artifactVM.statusMessage = "Removed \(excludedComponents.count) ICA components."
            artifactVM.detectionRefreshToken += 1
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
            ica.isRemovingComponents = false
            ica.showsSheet = false
            icaRemovalTask = nil
            // Applying components resolves an interactive-replay decision pause.
            if replay.state.isAwaitingDecision { replay.resume(.proceed) }
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
            ica.statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            ica.statusMessage = error.localizedDescription
        }
    }

    // MARK: - ICA debug report

    private func copyICADebugReportToPasteboard() {
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

    private func icaDebugReport(rawSignal: MFFSignalData) -> String {
        let base = ica.cleanedSignal ?? gradient.correctedSignal ?? rawSignal
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


    // MARK: - Multi-condition overlay helpers

    /// Distinct categories among the adopted segments, in first-appearance order.
    private func overlayAvailableCategories() -> [String] {
        var seen: [String] = []
        for segment in epoching.epochSegments where !seen.contains(segment.category) {
            seen.append(segment.category)
        }
        return seen
    }

    /// Segments whose category is in the current overlay selection.
    private func selectedOverlaySegments() -> [EpochSegment] {
        let available = overlayAvailableCategories()
        let selected = epoching.overlayCategories(available: available)
        return epoching.epochSegments.filter { selected.contains($0.category) }
    }

    /// Legend: one entry per selected category (deduped, renamed), in order.
    private func overlayLegendItems() -> [(String, Color)] {
        let available = overlayAvailableCategories()
        let selected = epoching.overlayCategories(available: available)
        var seen = Set<String>()
        var items: [(String, Color)] = []
        for segment in epoching.epochSegments
        where selected.contains(segment.category) && seen.insert(segment.category).inserted {
            items.append((epoching.displayCategory(segment.category), epochColor(for: segment.colorIndex)))
        }
        return items
    }

    /// A menu of category toggles for choosing which conditions to overlay.
    @ViewBuilder
    private func overlayConditionsMenu() -> some View {
        let available = overlayAvailableCategories()
        Menu {
            ForEach(available, id: \.self) { category in
                Toggle(epoching.displayCategory(category), isOn: Binding(
                    get: { epoching.isOverlaySelected(category, available: available) },
                    set: { _ in epoching.toggleOverlayCategory(category, available: available) }
                ))
            }
        } label: {
            Label("Conditions", systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which conditions to overlay.")
    }

    /// A right-click "Save Figure As…" submenu that renders `figure` (wrapped in a
    /// white FigureCard with title + legend) to PNG / JPEG / PDF.
    @ViewBuilder
    private func figureSaveMenu<Figure: View>(
        title: String,
        legend: [(String, Color)],
        size: CGSize,
        @ViewBuilder figure: @escaping () -> Figure
    ) -> some View {
        Menu("Save Figure As…") {
            ForEach(FigureFormat.allCases) { format in
                Button(format.label) {
                    FigureExporter.save(
                        FigureCard(title: title, legend: legend, size: size, content: figure),
                        defaultName: figureFileName(title),
                        format: format
                    )
                }
            }
        }
    }

    private func figureFileName(_ title: String) -> String {
        let base = (recording.packageName as NSString).deletingPathExtension
        let safeTitle = title.replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "/:")).joined()
        return "\(base)-\(safeTitle)"
    }

    func categoryColorIndices(for categories: [String]) -> [String: Int] {
        let uniqueCategories = Array(Set(categories)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: uniqueCategories.enumerated().map { index, category in
            (category, index)
        })
    }

    // MARK: - Copy processing (eva.xml replay)

    /// Reads another recording's `eva.xml` and replays its replayable steps onto
    /// the current recording. First slice applies the filter step; other stages
    /// are captured but skipped until their round-trip lands.
    private func importProcessingFromOtherFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mff, .xml]
        panel.canChooseDirectories = true // MFF is a directory package
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Copy Processing"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Accept either an MFF package (reads its eva.xml) or a standalone eva.xml.
        guard let script = EVAProcessingScriptXML.read(fromFile: url) else {
            filter.statusMessage = "No eva.xml found in \(url.lastPathComponent)."
            filter.statusIsError = true
            return
        }

        // Present the config pane; the user reviews steps and clicks Start, which
        // launches `interactiveReplay()` via `startInteractiveReplay()`.
        replay.configure(script: script, sourceName: url.lastPathComponent)
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

        let pnsForExport = pnsSignalForMFFExport()

        isExportingMFF = true
        mffExportStatusMessage = "Exporting \(snapshot.kind.statusName) MFF..."

        // Capture the active processing pipeline for eva.xml + the process log.
        let processingScript = currentProcessingScript()

        mffExportTask?.cancel()
        let sessionID = recordingSessionID
        mffExportTask = Task {
            let result = await performMFFExport(
                snapshot: snapshot,
                pnsForExport: pnsForExport,
                script: processingScript,
                to: url
            )
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            isExportingMFF = false
            switch result {
            case .success(let outputURL):
                mffExportStatusMessage = "Exported \(snapshot.kind.statusName) MFF: \(outputURL.lastPathComponent)"
            case .failure(let error):
                mffExportStatusMessage = error.localizedDescription
            }
            mffExportTask = nil
        }
    }

    /// Panel-free MFF export — the core shared by the interactive Save panel and
    /// replay finish-and-export (the seam Batch produces outputs through). Writes
    /// the package plus its `eva.xml` provenance and process log.
    @MainActor
    private func performMFFExport(
        snapshot: MFFExportSnapshot,
        pnsForExport: MFFSignalData?,
        script: EVAProcessingScript,
        to url: URL
    ) async -> Result<URL, Error> {
        let worker = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try MFFWriter.write(
                    signal: snapshot.signal,
                    pnsSignal: pnsForExport,
                    segments: snapshot.segments,
                    kind: snapshot.kind,
                    to: url
                )
                try? EVAProcessingScriptXML.write(script, toPackage: url)
                let log = EVAProcessLog(header: "EVA export — \(url.lastPathComponent)")
                for step in script.steps {
                    let params = step.parameters.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                    log.append("\(step.operation.rawValue)\(params.isEmpty ? "" : ": \(params)")")
                }
                try? log.write(toPackage: url)
                try Task.checkCancellation()
                return Result<URL, Error>.success(url)
            } catch {
                return Result<URL, Error>.failure(error)
            }
        }
        return await withTaskCancellationHandler(
            operation: { await worker.value },
            onCancel: { worker.cancel() }
        )
    }

    private func pnsSignalForMFFExport() -> MFFSignalData? {
        let renamedPNS = pnsSignalWithRenames()
        guard shouldIncludeSyntheticPNSChannelsInExport() else { return renamedPNS }
        return mergingWithSynthetic(base: renamedPNS)
    }

    private func shouldIncludeSyntheticPNSChannelsInExport() -> Bool {
        guard !syntheticPNSChannels.isEmpty else { return false }
        let alert = NSAlert()
        alert.messageText = "Include synthesized ICA channels?"
        let names = syntheticPNSChannels.map(\.name).joined(separator: ", ")
        alert.informativeText = "The following synthetic PNS channels were created from ICA components: \(names). Include them in the exported MFF?"
        alert.addButton(withTitle: "Include")
        alert.addButton(withTitle: "Skip")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func splitCurrentFile(_ selection: MFFSplitSelection, atSample sample: Int) {
        guard !isExportingMFF else { return }
        guard let snapshot = currentMFFExportSnapshot() else {
            mffExportStatusMessage = "No signal is ready to split."
            return
        }

        let split: MFFSignalSplitPair
        do {
            split = try MFFSignalSplitter.split(signal: snapshot.signal, atSample: sample)
        } catch {
            mffExportStatusMessage = error.localizedDescription
            return
        }

        let splitTime = split.left.endTimeSeconds
        let outputs: [MFFSplitOutput]
        switch selection {
        case .left:
            guard let url = splitSaveURL(defaultName: defaultMFFSplitName(side: .left, splitTime: splitTime)) else { return }
            outputs = [MFFSplitOutput(segment: split.left, url: normalizedMFFPackageURL(url))]
        case .right:
            guard let url = splitSaveURL(defaultName: defaultMFFSplitName(side: .right, splitTime: splitTime)) else { return }
            outputs = [MFFSplitOutput(segment: split.right, url: normalizedMFFPackageURL(url))]
        case .both:
            guard let leftURL = splitSaveURL(
                defaultName: defaultMFFSplitName(side: .left, splitTime: splitTime),
                message: "Choose the left-segment file. Eva will create the matching right-segment file beside it."
            ) else { return }
            let pairURLs = splitPairURLs(fromLeftURL: leftURL)
            guard confirmReplacingGeneratedSplitFiles([pairURLs.right]) else { return }
            outputs = [
                MFFSplitOutput(segment: split.left, url: pairURLs.left),
                MFFSplitOutput(segment: split.right, url: pairURLs.right)
            ]
        }

        let pnsForExport = pnsSignalForMFFExport()
        let processingScript = currentProcessingScript()
        isExportingMFF = true
        mffExportStatusMessage = "Splitting MFF at \(formattedEventTime(splitTime))..."

        mffExportTask?.cancel()
        let sessionID = recordingSessionID
        mffExportTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    for output in outputs {
                        let pnsSlice = try pnsForExport.map {
                            try MFFSignalSplitter.slice(
                                signal: $0,
                                startTimeSeconds: output.segment.startTimeSeconds,
                                endTimeSeconds: output.segment.endTimeSeconds,
                                side: output.segment.side
                            ).signal
                        }
                        try MFFWriter.write(
                            signal: output.segment.signal,
                            pnsSignal: pnsSlice,
                            segments: [],
                            kind: .continuous,
                            to: output.url,
                            preserveSourceFileInfo: false
                        )

                        var script = processingScript
                        script.append(EVAProcessingStep(
                            operation: .split,
                            parameters: [
                                "side": output.segment.side.rawValue,
                                "startSeconds": String(format: "%.6f", output.segment.startTimeSeconds),
                                "endSeconds": String(format: "%.6f", output.segment.endTimeSeconds),
                                "boundarySample": "\(split.boundarySample)"
                            ],
                            replayable: false,
                            note: "Created by right-click Split File export."
                        ))
                        try? EVAProcessingScriptXML.write(script, toPackage: output.url)

                        let log = EVAProcessLog(header: "EVA split export — \(output.url.lastPathComponent)")
                        for step in script.steps {
                            let params = step.parameters.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                            log.append("\(step.operation.rawValue)\(params.isEmpty ? "" : ": \(params)")")
                        }
                        try? log.write(toPackage: output.url)
                        try Task.checkCancellation()
                    }
                    return Result<[URL], Error>.success(outputs.map(\.url))
                } catch {
                    return Result<[URL], Error>.failure(error)
                }
            }
            let result = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            await MainActor.run {
                isExportingMFF = false
                switch result {
                case .success(let urls):
                    let names = urls.map(\.lastPathComponent).joined(separator: ", ")
                    mffExportStatusMessage = "Exported split MFF\(urls.count == 1 ? "" : "s"): \(names)"
                case .failure(let error):
                    mffExportStatusMessage = error.localizedDescription
                }
            }
            mffExportTask = nil
        }
    }

    private func splitSaveURL(defaultName: String, message: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mff]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultName
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func defaultMFFSplitName(side: MFFSignalSplitSide, splitTime: Double) -> String {
        let baseName = (recording.packageName as NSString).deletingPathExtension
        let time = splitTimeFilenameComponent(splitTime)
        return "\(baseName)-\(side.rawValue)-\(time).mff"
    }

    private func splitPairURLs(fromLeftURL leftURL: URL) -> (left: URL, right: URL) {
        let left = normalizedMFFPackageURL(leftURL)
        let directory = left.deletingLastPathComponent()
        let baseName = (left.lastPathComponent as NSString).deletingPathExtension
        let rightBaseName: String
        if let range = baseName.range(of: "-left-", options: .backwards) {
            rightBaseName = baseName.replacingCharacters(in: range, with: "-right-")
        } else if baseName.hasSuffix("-left") {
            rightBaseName = String(baseName.dropLast("-left".count)) + "-right"
        } else {
            rightBaseName = "\(baseName)-right"
        }
        let right = directory.appendingPathComponent(rightBaseName).appendingPathExtension("mff")
        return (left, right)
    }

    private func confirmReplacingGeneratedSplitFiles(_ urls: [URL]) -> Bool {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = existing.count == 1 ? "Replace existing split file?" : "Replace existing split files?"
        alert.informativeText = existing.map(\.lastPathComponent).joined(separator: ", ")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func splitTimeFilenameComponent(_ seconds: Double) -> String {
        String(format: "%.3fs", seconds).replacingOccurrences(of: ".", with: "p")
    }

    /// Returns the real PNS signal with any user renames applied to channel names.
    /// Returns nil when there is no real PNS signal.
    private func pnsSignalWithRenames() -> MFFSignalData? {
        guard let pns = recording.pnsSignal else { return nil }
        guard !physioChannelRenames.isEmpty else { return pns }
        var names = pns.channelNames ?? (0..<pns.numberOfChannels).map { "PNS \($0 + 1)" }
        for (index, rename) in physioChannelRenames where index < names.count {
            names[index] = rename
        }
        return MFFSignalData(
            signalURL: pns.signalURL,
            signalType: pns.signalType,
            numberOfChannels: pns.numberOfChannels,
            samplingRate: pns.samplingRate,
            duration: pns.duration,
            recordingStartTime: pns.recordingStartTime,
            events: pns.events,
            data: pns.data,
            channelNames: names
        )
    }

    /// Builds a declarative processing record (eva.xml) from the active
    /// pipeline state, so exported packages document how EVA transformed them.
    /// Captures the current processing as a replayable script. Steps are emitted
    /// in canonical chain order (matching `body`: gradient → ica → filter →
    /// artifact → wavelet → interpolate → markBad) so that replaying them in
    /// order reproduces the same result and each stage's downstream invalidation
    /// lands correctly. Keep this order in sync with `body` and `replay(_:)`.
    private func currentProcessingScript() -> EVAProcessingScript {
        var script = EVAProcessingScript()

        if gradient.correctedSignal != nil {
            script.append(EVAProcessingStep(operation: .mriGradientCorrection, parameters: gradient.parameters))
        }
        if ica.cleanedSignal != nil {
            script.append(EVAProcessingStep(
                operation: .icaClean,
                parameters: ["averageReference": "\(ica.usesAverageReference)"],
                replayable: false,
                note: "ICA settings are portable; removed component indices are subject-specific."
            ))
        }
        if filter.output != nil {
            script.append(EVAProcessingStep(operation: .filter, parameters: filter.parameters))
        }
        if artifactVM.isCleaningActive {
            // Artifact cleaning is defined per-subject (drawn templates / events),
            // so it is provenance-only, not replayable.
            script.append(EVAProcessingStep(
                operation: .artifactClean,
                parameters: ["artifacts": "\(template.definedArtifacts.count)"],
                replayable: false,
                note: "Artifact definitions (templates/events) are subject-specific."
            ))
        }
        if wavelet.isActive {
            script.append(EVAProcessingStep(operation: .waveletReduce, parameters: wavelet.parameters))
        }
        // Threshold-based ocular detection is fully parameterized (no drawn
        // templates), so it is portable and replayable.
        if artifactVM.detectionMethod == .threshold, detectsEyeBlinkArtifacts || detectsEyeMovementArtifacts {
            var p: [String: String] = [
                "eyeBlink": "\(detectsEyeBlinkArtifacts)",
                "eyeMovement": "\(detectsEyeMovementArtifacts)"
            ]
            // Flat, readable params (one <param> per field) rather than a JSON blob.
            p.merge(artifactVM.blinkThresholdConfig.flatParameters(prefix: "blink")) { a, _ in a }
            p.merge(artifactVM.movementThresholdConfig.flatParameters(prefix: "movement")) { a, _ in a }
            script.append(EVAProcessingStep(operation: .thresholdArtifactDetection, parameters: p))
        }
        // PSA: segment (+ optional baseline / average) is portable when the target
        // has the same event codes. Replayable.
        if epoching.epochedSignal != nil, !epoching.selectedEventCodes.isEmpty {
            script.append(EVAProcessingStep(operation: .segment, parameters: epoching.parameters))
        }
        if !channels.interpolated.isEmpty {
            script.append(EVAProcessingStep(
                operation: .interpolateChannels,
                parameters: ["channels": channels.interpolated.keys.sorted().map { String($0 + 1) }.joined(separator: ",")],
                replayable: false,
                note: "Interpolated channel indices are subject-specific."
            ))
        }
        if !channels.bad.isEmpty {
            script.append(EVAProcessingStep(
                operation: .markBad,
                parameters: ["channels": channels.bad.sorted().map { String($0 + 1) }.joined(separator: ",")],
                replayable: false
            ))
        }
        return script
    }

    private func currentMFFExportSnapshot() -> MFFExportSnapshot? {
        guard let rawSignal = recording.signal else { return nil }

        let base = ica.cleanedSignal ?? gradient.correctedSignal ?? rawSignal
        let preArtifact = filter.output ?? base
        let processed = artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
        let continuousSignal = applyInterpolations(to: processed)

        if let epochedSig = epoching.epochedSignal, !epoching.epochSegments.isEmpty {
            return MFFExportSnapshot(
                signal: epochedSig,
                segments: epoching.epochSegments,
                kind: epoching.isAveraged ? .averaged : .epoched
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
        let lineNoiseMode = filter.activeLineNoiseMode
        let lineNoiseBinding = Binding<FilterLineNoiseMode> {
            filter.activeLineNoiseMode
        } set: { mode in
            filter.lineNoiseMode = mode
            filter.notch60HzEnabled = mode == .notch
            if mode != .off {
                filter.showsLineNoiseOptions = true
            }
        }

        return VStack(alignment: .leading, spacing: 14) {
            Text("Filter")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("High-Pass Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("Off", text: $filter.highPassCutoffText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .help("Leave blank for no high-pass cutoff.")
                    Stepper("", value: Binding<Double>(
                        get: { filter.highPassCutoff ?? 0.1 },
                        set: { filter.lowCutoff = $0 }
                    ), in: 0.1...100, step: 0.1)
                        .labelsHidden()
                    Picker("HP Slope", selection: $filter.highPassSlope) {
                        ForEach(FilterSlope.allCases) { slope in
                            Text(slope.label).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(filter.highPassCutoff == nil)
                    .help("High-pass rolloff slope. 12 dB/oct (2-pole) is gentler and produces less ringing near the cutoff; 24 dB/oct (4-pole) is steeper. Both are applied zero-phase (forward+backward pass).")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Low-Pass Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("Off", text: $filter.lowPassCutoffText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .help("Leave blank for no low-pass cutoff.")
                    Stepper("", value: Binding<Double>(
                        get: { filter.lowPassCutoff ?? 30 },
                        set: { filter.highCutoff = $0 }
                    ), in: 0.5...200, step: 0.5)
                        .labelsHidden()
                    Picker("LP Slope", selection: $filter.lowPassSlope) {
                        ForEach(FilterSlope.allCases) { slope in
                            Text(slope.label).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(filter.lowPassCutoff == nil)
                    .help("Low-pass rolloff slope. 24 dB/oct is a common choice for BCG preprocessing; 48 dB/oct gives a sharper brick-wall rolloff at the cost of more ringing. Both are zero-phase.")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Line Noise")
                    .font(.caption.weight(.semibold))
                Picker("Line Noise", selection: lineNoiseBinding) {
                    ForEach(FilterLineNoiseMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                DisclosureGroup("Line Noise Options", isExpanded: $filter.showsLineNoiseOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Frequency")
                                .font(.caption)
                                .frame(width: 76, alignment: .leading)
                            TextField("Hz", value: $filter.lineNoiseFrequency, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Stepper("", value: $filter.lineNoiseFrequency, in: 45...65, step: 0.5)
                                .labelsHidden()
                        }

                        HStack {
                            Text("Harmonics")
                                .font(.caption)
                                .frame(width: 76, alignment: .leading)
                            Stepper(value: $filter.lineNoiseHarmonics, in: 1...4) {
                                Text("\(filter.lineNoiseHarmonics)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 32, alignment: .leading)
                            }
                        }
                        .disabled(lineNoiseMode != .adaptiveCleanLine)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Window")
                                    .font(.caption)
                                Spacer()
                                Text(String(format: "%.1fs", filter.lineNoiseWindowSeconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $filter.lineNoiseWindowSeconds, in: 1...10, step: 0.5)
                        }
                        .disabled(lineNoiseMode != .adaptiveCleanLine)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Strength")
                                    .font(.caption)
                                Spacer()
                                Text(String(format: "%.2fx", filter.lineNoiseStrength))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $filter.lineNoiseStrength, in: 0.25...1.50, step: 0.05)
                        }
                        .disabled(lineNoiseMode != .adaptiveCleanLine)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .disabled(lineNoiseMode == .off)
            }

            Toggle("Average reference", isOn: $filter.averageReference)
                .help("Re-reference to the common average: subtract the mean across all channels at each time point. Removes shared reference signal.")

            HStack {
                Spacer()
                Picker("Precision", selection: $filter.precision) {
                    ForEach(FilterPrecision.allCases) { precision in
                        Text(precision.label).tag(precision)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 190)
                .help("Auto uses Float for routine filters, Double for numerically risky settings, and retries in Double if Float becomes unstable.")
            }

            if recording.pnsSignal != nil {
                Toggle("Filter PNS", isOn: $filter.filterPNS)
                    .font(.caption)
                    .help("Apply the cutoff and line-noise filter to physio/PNS channels. Average reference is EEG-only.")
            }

            HStack {
                Button("Reset 0.1–30 Hz") {
                    filter.resetToDefaults()
                }

                if filter.isActive {
                    Button("Remove Filter", role: .destructive) {
                        clearBandpassFilter()
                        filter.showsPopover = false
                    }
                }

                Spacer()

                Button("Apply Filter") {
                    applyBandpassFilter(to: signal)
                    filter.showsPopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func applyBandpassFilter(to signal: MFFSignalData) {
        let pnsInput = filter.filterPNS ? pnsFilterBaseSignal() : nil
        // The interactive path fires the shared async apply without awaiting;
        // the replay coordinator awaits the same method (one code path).
        filterTask?.cancel()
        let sessionID = recordingSessionID
        filterTask = Task {
            await filter.apply(
                to: signal,
                pnsInput: pnsInput,
                excludedChannels: channels.bad,
                onApplied: { [self] in
                    guard sessionID == recordingSessionID else { return }
                    postFilterInvalidation()
                }
            )
            if !Task.isCancelled, sessionID == recordingSessionID {
                filterTask = nil
            }
        }
    }

    /// Downstream invalidation shared by interactive filtering and replay.
    private func postFilterInvalidation() {
        clearAppliedArtifactCleaning()
        artifactVM.detectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    /// Launches the interactive replay once the user confirms the config pane.
    private func startInteractiveReplay() {
        replay.showsConfigPane = false
        replayTask?.cancel()
        let sessionID = recordingSessionID
        replayTask = Task {
            await interactiveReplay()
            guard sessionID == recordingSessionID else { return }
            replayTask = nil
        }
    }

    /// Re-applies the configured steps to the current recording, in canonical
    /// chain order, driving the SAME apply-functions the interactive UI uses.
    /// Pauses (via the controller's async gate) for review/decision steps, then
    /// resumes. Awaits each transform so downstream steps see settled output.
    @MainActor
    private func interactiveReplay() async {
        guard let rawSignal = recording.signal else { replay.state = .finished; return }
        let actions = replay.plannedActions()

        loop: for action in actions {
            let params = replay.parameters(forStep: action.stepIndex)
            replay.state = .running(index: action.stepIndex)

            switch action.operation {
            case .mriGradientCorrection:
                gradient.apply(parameters: params)
                if action.gate == .review {
                    gradient.showsPopover = true
                    let decision = await replay.gate(.awaitingReview(index: action.stepIndex),
                        banner: .init(title: "Review MRI Gradient Correction",
                                      detail: "Adjust TR-skip, motion, or window in the panel, then Apply.",
                                      showsSkip: true, progress: nil))
                    gradient.showsPopover = false
                    switch decision {
                    case .cancel: break loop
                    case .skip: continue loop
                    case .proceed: break
                    }
                }
                await applyGradientCorrection(to: rawSignal)

            case .filter:
                filter.apply(parameters: params)
                // Auto step: a review gate (Review-Each mode) is banner-only — no
                // popover — so the loop remains the sole applier (no double-apply).
                if action.gate == .review {
                    switch await replay.gate(.awaitingReview(index: action.stepIndex),
                        banner: .init(title: "Apply Filter?",
                                      detail: "\(filter.activeFilterSummary). Continue to apply.",
                                      showsSkip: true, progress: nil)) {
                    case .cancel: break loop
                    case .skip: continue loop
                    case .proceed: break
                    }
                }
                let base = ica.cleanedSignal ?? gradient.correctedSignal ?? rawSignal
                let pnsInput = filter.filterPNS ? pnsFilterBaseSignal() : nil
                await filter.apply(
                    to: base,
                    pnsInput: pnsInput,
                    excludedChannels: channels.bad,
                    onApplied: { [self] in postFilterInvalidation() }
                )

            case .thresholdArtifactDetection:
                artifactVM.detectionMethod = .threshold
                detectsEyeBlinkArtifacts = params["eyeBlink"] == "true"
                detectsEyeMovementArtifacts = params["eyeMovement"] == "true"
                artifactVM.blinkThresholdConfig = .fromFlatParameters(params, prefix: "blink",
                    base: artifactVM.blinkThresholdConfig)
                artifactVM.movementThresholdConfig = .fromFlatParameters(params, prefix: "movement",
                    base: artifactVM.movementThresholdConfig)

            case .icaClean:
                // Auto-run the (portable) decomposition, then pause for the
                // subject-specific component-removal decision.
                ica.apply(parameters: params)
                replay.banner = .init(title: "Running ICA…", detail: "Decomposing components.",
                                      showsSkip: false, progress: nil)
                let base = gradient.correctedSignal ?? rawSignal
                await runICADecomposition(on: base)
                guard ica.decomposition != nil else { replay.banner = nil; continue loop }
                openICASheet(for: base)
                switch await replay.gate(.awaitingDecision(index: action.stepIndex),
                    banner: .init(title: "Select ICA Components",
                                  detail: "Choose components to remove, then Remove — or Close to skip.",
                                  showsSkip: true, progress: nil)) {
                case .cancel: ica.showsSheet = false; break loop
                case .skip, .proceed: break // .proceed = applied; .skip = closed unapplied
                }

            case .segment:
                // Automate PSA: segment (+ baseline / average per params), then
                // open the butterfly plot when an average was produced.
                epoching.apply(parameters: params)
                if let psaSignal = continuousProcessedSignal {
                    await applyPSA(to: psaSignal)
                    if epoching.isAveraged { epoching.showsButterflyPlot = true }
                }

            default:
                continue loop
            }
        }

        if Task.isCancelled {
            replay.banner = nil
            replay.state = .cancelled
            if batch.isActive, batch.matches(recording: recording) {
                batch.completeCurrent(.skipped) // per-file Cancel → skip + advance
            }
            return
        }

        // Finish-and-export: the seam Batch produces outputs through.
        if replay.exportWhenFinished, let folder = replay.outputFolder {
            await exportReplayResult(to: folder)
        }

        replay.banner = nil
        replay.state = .finished

        // Advance the batch only after export has fully completed above.
        if batch.isActive, batch.matches(recording: recording) {
            batch.completeCurrent(.done)
        }
    }

    /// Writes the processed recording to `<folder>/<name>-processed.mff` (with its
    /// eva.xml) after an interactive replay finishes. Panel-free so Batch can call
    /// it per file. Uses renamed PNS without the synthetic-channel prompt.
    @MainActor
    private func exportReplayResult(to folder: URL) async {
        guard let snapshot = currentMFFExportSnapshot() else { return }
        let base = (recording.packageName as NSString).deletingPathExtension
        let url = folder.appendingPathComponent("\(base)-processed.mff")
        replay.banner = .init(title: "Exporting…", detail: url.lastPathComponent,
                              showsSkip: false, progress: nil)
        let result = await performMFFExport(
            snapshot: snapshot,
            pnsForExport: pnsSignalWithRenames(),
            script: currentProcessingScript(),
            to: url
        )
        switch result {
        case .success(let out):
            filter.statusMessage = "Processed + exported \(out.lastPathComponent)."
            filter.statusIsError = false
        case .failure(let error):
            filter.statusMessage = "Export failed: \(error.localizedDescription)"
            filter.statusIsError = true
        }
    }

    /// Top banner shown while an interactive replay is running or paused.
    @ViewBuilder
    private func replayBanner() -> some View {
        if let info = replay.banner {
            HStack(spacing: 12) {
                if replay.state.isAwaiting {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 1) {
                    if batch.isActive, let job = batch.currentJob {
                        Text("File \(batch.currentIndex + 1) of \(batch.jobs.count) · \(job.name)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(info.title).font(.callout.weight(.semibold))
                    Text(info.detail).font(.caption).foregroundStyle(.secondary)
                }

                if ica.isRunning {
                    ProgressView(value: ica.progress).frame(width: 120)
                }

                Spacer(minLength: 12)

                if replay.state.isAwaiting {
                    Button("Continue") { replay.resume(.proceed) }
                        .keyboardShortcut(.defaultAction)
                    if info.showsSkip {
                        Button("Skip") { replay.resume(.skip) }
                    }
                }
                // In batch, Cancel skips just this file; Stop Batch ends the run.
                Button(batch.isActive ? "Skip File" : "Cancel", role: .cancel) { replay.cancel() }
                if batch.isActive {
                    Button("Stop Batch") {
                        batch.stop()
                        replay.cancel()
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.35)))
            .shadow(radius: 6)
            .padding(12)
            .frame(maxWidth: 640)
        }
    }

    private func clearBandpassFilter() {
        filter.clear(onCleared: { [self] in
            clearAppliedArtifactCleaning()
            artifactVM.detectionRefreshToken += 1
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
        })
    }


    // MARK: - Artifact detection




    private var artifactsAreActive: Bool {
        detectsEyeBlinkArtifacts
            || detectsEyeMovementArtifacts
            || detectsECGArtifacts
            || !artifactVM.events.isEmpty
            || !template.definedArtifacts.isEmpty
            || isRunningWaveletArtifactExplorer
            || artifactVM.cleanedSignal != nil
    }

    private var artifactHelpText: String {
        if isRunningWaveletArtifactExplorer {
            return "Wavelet artifact explorer\n\(waveletExplorerStatusTitle.nilIfEmpty ?? "Scanning wavelet artifact evidence...")"
        }

        if artifactVM.isCleaning {
            return "Artifact cleaning\nCleaning artifacts..."
        }

        if artifactVM.isDetecting {
            return "Artifact detection\nDetecting artifacts..."
        }

        if artifactVM.cleanedSignal != nil, !artifactVM.cleaningIsEnabled {
            return "Artifact cleaning\nApplied correction hidden for comparison."
        }

        if artifactVM.cleanedSignal != nil {
            return "Artifact cleaning\n\(artifactVM.cleaningStatusMessage ?? "Artifact cleanup applied.")"
        }

        if let detectStatus = artifactVM.statusMessage {
            return "Artifact detection\n\(detectStatus)"
        }

        if !template.definedArtifacts.isEmpty {
            return "Artifact detection\n\(template.definedArtifacts.count) artifact definitions"
        }

        return "Artifact detection"
    }

    private func eegAnalysisProcessingSnapshot() -> EEGAnalysisProcessingSnapshot {
        var parts = ["original"]
        if gradient.correctedSignal != nil {
            parts.append("MRI-corrected")
        }
        if ica.cleanedSignal != nil {
            parts.append("ICA-cleaned")
        }
        if filter.output != nil {
            parts.append("filtered")
        }
        if artifactVM.cleanedSignal != nil, artifactVM.cleaningIsEnabled {
            parts.append("artifact-cleaned")
        }
        if wavelet.reducedSignal != nil, wavelet.isEnabled {
            parts.append("wavelet-reduced")
        }
        if !channels.interpolated.isEmpty {
            parts.append("interpolated")
        }

        return EEGAnalysisProcessingSnapshot(
            signalDescription: "Current working signal: \(parts.joined(separator: " → "))",
            gradientCorrected: gradient.correctedSignal != nil,
            icaCleaned: ica.cleanedSignal != nil,
            filtered: filter.output != nil,
            filterLowCutoffHz: filter.output == nil ? nil : filter.highPassCutoff,
            filterHighCutoffHz: filter.output == nil ? nil : filter.lowPassCutoff,
            notch60HzEnabled: filter.output == nil ? nil : filter.notch60HzEnabled,
            averageReferenced: filter.output == nil ? nil : filter.averageReference,
            artifactCleaned: artifactVM.cleanedSignal != nil,
            artifactCleaningVisible: artifactVM.cleanedSignal != nil && artifactVM.cleaningIsEnabled,
            waveletReduced: wavelet.reducedSignal != nil,
            waveletReductionVisible: wavelet.reducedSignal != nil && wavelet.isEnabled,
            interpolatedChannelIndices: channels.interpolated.keys.sorted(),
            markedBadChannelIndices: channels.bad.sorted()
        )
    }

    private func eegArtifactRejectionSources() -> [EEGArtifactRejectionSource] {
        var sources: [EEGArtifactRejectionSource] = []
        var definedEvents = Set<MFFEvent>()

        for artifact in template.definedArtifacts where !artifact.events.isEmpty {
            for event in artifact.events {
                definedEvents.insert(event)
            }
            sources.append(
                EEGArtifactRejectionSource(
                    id: artifact.id.uuidString,
                    name: artifact.name,
                    eventCode: artifact.eventCode,
                    windowSizeSeconds: artifact.windowSizeSeconds,
                    events: artifact.events
                )
            )
        }

        let detectorEvents = artifactVM.events.filter { !definedEvents.contains($0) }
        if !detectorEvents.isEmpty {
            let codes = Array(Set(detectorEvents.map(\.code))).sorted().joined(separator: ", ")
            sources.append(
                EEGArtifactRejectionSource(
                    id: "current-detector-events",
                    name: "Current Detector Events",
                    eventCode: codes.isEmpty ? "Detected" : codes,
                    windowSizeSeconds: 0.25,
                    events: detectorEvents
                )
            )
        }

        return sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func artifactDetectionRequestID(for signal: MFFSignalData) -> String {
        return [
            signal.signalURL.path,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            "\(detectsEyeBlinkArtifacts)",
            "\(detectsEyeMovementArtifacts)",
            "\(artifactVM.blinkThresholdConfig.hashValue)",
            "\(artifactVM.movementThresholdConfig.hashValue)",
            "\(detectsECGArtifacts)",
            ecgDetectionSelectedPNSChannels.sorted().map(String.init).joined(separator: ","),
            ecgDetectionProxyChannels,
            ecgDetectionAlgorithm.rawValue,
            ecgDetectionPolarity.rawValue,
            "\(ecgDetectionThresholdSD)",
            "\(ecgDetectionMinimumRRSeconds)",
            displayedPhysioSignal().map { physioRangeTaskID(for: $0) } ?? "noPNS",
            artifactVM.detectionMethod.rawValue,
            "\(artifactVM.detectionRefreshToken)"
        ].joined(separator: "|")
    }

    @MainActor
    private func updateArtifactEvents(for signal: MFFSignalData) async {
        if artifactVM.detectionMethod == .template || artifactVM.detectionMethod == .ica {
            artifactVM.isDetecting = false
            return
        }

        guard (detectsEyeBlinkArtifacts || detectsEyeMovementArtifacts || detectsECGArtifacts), artifactVM.detectionMethod == .threshold else {
            artifactVM.events = []
            artifactVM.statusMessage = artifactsAreActive ? "Only threshold artifact detection is available." : nil
            artifactVM.isDetecting = false
            return
        }

        let ecgSources = detectsECGArtifacts ? ecgDetectionSources(for: signal) : []
        if detectsECGArtifacts, ecgSources.isEmpty, !detectsEyeBlinkArtifacts, !detectsEyeMovementArtifacts {
            artifactVM.events = []
            artifactVM.statusMessage = "Choose a PNS channel or EEG proxy channel for ECG detection."
            artifactVM.isDetecting = false
            return
        }

        artifactVM.isDetecting = true
        artifactVM.statusMessage = nil

        let sourceData = signal.data
        let samplingRate = signal.samplingRate
        let duration = signal.duration
        let detectBlinks = detectsEyeBlinkArtifacts
        let detectMovements = detectsEyeMovementArtifacts
        let detectECG = detectsECGArtifacts
        let blinkConfig = artifactVM.blinkThresholdConfig
        let movementConfig = artifactVM.movementThresholdConfig
        let ecgConfiguration = ECGDetectionConfiguration(
            algorithm: ecgDetectionAlgorithm,
            thresholdSD: ecgDetectionThresholdSD,
            minimumRRSeconds: ecgDetectionMinimumRRSeconds,
            polarity: ecgDetectionPolarity
        )

        let detectedEvents = await withTaskGroup(of: [MFFEvent].self) { group in
            if detectBlinks {
                group.addTask(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [] }
                    return EyeArtifactThresholdDetector.detect(
                        kind: .blink,
                        channels: sourceData,
                        samplingRate: samplingRate,
                        duration: duration,
                        configuration: blinkConfig
                    )
                }
            }
            if detectMovements {
                group.addTask(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [] }
                    return EyeArtifactThresholdDetector.detect(
                        kind: .movement,
                        channels: sourceData,
                        samplingRate: samplingRate,
                        duration: duration,
                        configuration: movementConfig
                    )
                }
            }
            if detectECG, !ecgSources.isEmpty {
                group.addTask(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [] }
                    return RWaveDetector.detect(sources: ecgSources, configuration: ecgConfiguration)
                }
            }
            var events: [MFFEvent] = []
            for await batch in group { events += batch }
            return events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        }

        guard !Task.isCancelled else { return }
        artifactVM.events = detectedEvents
        artifactVM.statusMessage = artifactDetectionSummary(for: detectedEvents)
        artifactVM.isDetecting = false
    }

    private func artifactDetectionSummary(for events: [MFFEvent]) -> String {
        guard !events.isEmpty else { return "No artifacts detected." }
        let blinkCount = events.filter { $0.code == EyeArtifactKind.blink.eventCode }.count
        let movementCount = events.filter { $0.code == EyeArtifactKind.movement.eventCode }.count
        let rWaveCount = events.filter { $0.code == RWaveDetector.eventCode }.count
        var parts: [String] = []
        if blinkCount > 0 {
            parts.append("\(blinkCount) blinks")
        }
        if movementCount > 0 {
            parts.append("\(movementCount) eye movements")
        }
        if rWaveCount > 0 {
            parts.append("\(rWaveCount) QRS")
        }
        if parts.isEmpty {
            parts.append("\(events.count) artifact event\(events.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Channel health

    private func channelHealthSignature(for signal: MFFSignalData) -> String {
        // Interpolation is deliberately excluded: it changes only one channel,
        // so it does not wipe the whole health run — instead a targeted
        // recompute updates just the interpolated channel's badge.
        return [
            signal.signalURL.path,
            signal.signalType,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            "\(signal.samplingRate)",
            "\(gradient.correctedSignal != nil)",
            "\(ica.cleanedSignal != nil)",
            "\(filter.output != nil)",
            "\(artifactVM.cleanedSignal != nil)",
            "\(artifactVM.cleaningIsEnabled)"
        ].joined(separator: "|")
    }

    private func channelHealthDetailsSheet(for signal: MFFSignalData) -> some View {
        @Bindable var goodnessSettings = goodnessSettings
        return ChannelHealthDetailsView(
            results: Array(channels.healthResults.values),
            isAnalyzing: channels.isAnalyzingHealth,
            progress: channels.healthProgress,
            statusMessage: chanHealth.statusMessage,
            onRefresh: {
                channels.showsHealth = true
                channels.healthRefreshToken += 1
            },
            waveletFamily: $goodnessSettings.wavelet.family,
            waveletLevelCount: $goodnessSettings.wavelet.levelCount,
            waveletThresholdModel: $goodnessSettings.wavelet.thresholdModel,
            waveletThresholdRule: $goodnessSettings.wavelet.thresholdRule,
            waveletDownsampleRate: $goodnessSettings.wavelet.downsampleRate,
            waveletCleaningMode: $goodnessSettings.wavelet.cleaningMode,
            waveletIntensity: $goodnessSettings.wavelet.intensity,
            onRunWavelets: {
                runWaveletChannelGoodness(for: signal)
            },
            onClose: {
                chanHealth.showsDetails = false
            }
        )
    }

    @MainActor
    private func runWaveletChannelGoodness(for signal: MFFSignalData) {
        guard !channels.isAnalyzingHealth else { return }
        let signature = channelHealthSignature(for: signal)
        let shouldRefreshBase = chanHealth.signature != signature || channels.healthResults.isEmpty
        let existingResults = channels.healthResults
        let layout = recording.sensorLayout
        let impedances = recording.signal?.impedancesKOhm
        let baseConfig = goodnessSettings.base
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac
        let wavelet = goodnessSettings.wavelet
        let configuration = WaveletChannelGoodnessConfiguration(
            channelIndices: Array(signal.data.indices),
            downsampleRate: min(max(wavelet.downsampleRate, 20), signal.samplingRate),
            levelCount: wavelet.levelCount,
            thresholdScale: max(0.05, wavelet.cleaningMode.thresholdMultiplier / max(wavelet.intensity, 0.10)),
            cleaningMode: wavelet.cleaningMode,
            intensity: wavelet.intensity,
            waveletFamily: wavelet.family,
            thresholdRule: wavelet.thresholdRule,
            thresholdModel: wavelet.thresholdModel
        )

        chanHealth.task?.cancel()
        chanHealth.signature = signature
        if shouldRefreshBase {
            channels.healthResults = [:]
        }
        channels.showsHealth = true
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        chanHealth.statusMessage = "Running wavelet channel goodness..."

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        chanHealth.task = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                let baseAnalysis: ChannelHealthAnalysis
                if shouldRefreshBase {
                    baseAnalysis = ChannelHealthAnalyzer.analyze(
                        signal: signal,
                        layout: layout,
                        base: baseConfig,
                        spectral: spectralConfig,
                        ransac: ransacConfig,
                        impedancesKOhm: impedances,
                        progress: { fraction in
                            progressContinuation.yield(0.42 * fraction)
                        }
                    )
                } else {
                    progressContinuation.yield(0.08)
                    baseAnalysis = ChannelHealthAnalysis(resultsByChannel: existingResults)
                }

                let waveletStart = shouldRefreshBase ? 0.42 : 0.08
                let waveletSpan = shouldRefreshBase ? 0.55 : 0.89
                let waveletResults = WaveletArtifactAnalyzer.channelGoodness(
                    in: signal,
                    configuration: configuration
                ) { update in
                    progressContinuation.yield(waveletStart + waveletSpan * update.fraction)
                }
                progressContinuation.yield(0.98)
                return ChannelHealthAnalyzer.addingWaveletMetrics(
                    to: baseAnalysis,
                    waveletResults: waveletResults
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
                  chanHealth.signature == signature else {
                return
            }

            channels.healthResults = analysis.resultsByChannel
            channels.isAnalyzingHealth = false
            channels.healthProgress = 1
            chanHealth.statusMessage = analysis.resultsByChannel.isEmpty
                ? "No wavelet channel-goodness metrics available."
                : "Wavelet channel goodness updated \(analysis.resultsByChannel.count) channels."
        }
    }

    /// The continuous (non-epoched) processed signal the health badges score,
    /// mirroring the `body` pipeline so a badge tap can run health from any row
    /// (rows only carry the possibly-epoched display signal). `nil` pre-load.
    private var continuousProcessedSignal: MFFSignalData? {
        guard let rawSignal = recording.signal else { return nil }
        let base = ica.cleanedSignal ?? gradient.correctedSignal ?? rawSignal
        let preArtifact = filter.output ?? base
        let processed = artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
        let waveletStage = wavelet.isEnabled ? (wavelet.reducedSignal ?? processed) : processed
        return applyInterpolations(to: waveletStage)
    }

    /// Resets the channel-health badges to their empty state after a major
    /// processing change. Does not auto-run; the user taps a badge to re-run.
    @MainActor
    private func resetChannelHealthForStateChange() {
        chanHealth.task?.cancel()
        chanHealth.task = nil
        chanHealth.signature = nil
        channels.clearHealthResults()
        channels.showsHealth = false
        chanHealth.statusMessage = nil
    }

    /// Runs channel health for the first time in the current state (tap a badge
    /// or the menu). No-ops if a scan is running or results already exist for
    /// this exact state; pass `force` to recompute regardless.
    @MainActor
    private func runChannelHealthOnDemand(for signal: MFFSignalData, force: Bool = false) {
        guard !channels.isAnalyzingHealth else { return }
        let signature = channelHealthSignature(for: signal)
        if !force, !channels.healthResults.isEmpty, chanHealth.signature == signature {
            return
        }
        channels.showsHealth = true
        startChannelHealthScan(for: signal, signature: signature)
    }

    /// Updates channel health after an interpolation change, touching only the
    /// affected channels' badges and leaving every other result in place.
    /// No-ops if health hasn't been run yet or a scan is already going.
    ///
    /// Newly interpolated channels can be estimated cheaply by averaging their
    /// spline-contributing channels (a Preferences toggle) — good for modest
    /// hardware. Un-interpolated channels (now back to real data) always need a
    /// real analysis, as does the estimate's fallback.
    @MainActor
    private func recomputeChannelHealthForInterpolation(oldKeys: [Int], newKeys: [Int], signal: MFFSignalData) {
        guard !channels.healthResults.isEmpty, !channels.isAnalyzingHealth else { return }
        let added = Set(newKeys).subtracting(oldKeys)
        let removed = Set(oldKeys).subtracting(newKeys)
        guard !added.isEmpty || !removed.isEmpty else { return }

        // Removals revert to real data, so they always need a real analysis.
        var needsFullAnalysis = removed

        if ProcessingDefaults.shared.interpolatedHealthFromNeighbors {
            for channel in added {
                if let estimate = averagedNeighborHealth(for: channel) {
                    channels.healthResults[channel] = estimate
                } else {
                    needsFullAnalysis.insert(channel) // no contributors with scores yet
                }
            }
        } else {
            needsFullAnalysis.formUnion(added)
        }

        guard !needsFullAnalysis.isEmpty else { return }

        let affected = needsFullAnalysis
        let layout = recording.sensorLayout
        let impedances = recording.signal?.impedancesKOhm
        let baseConfig = goodnessSettings.base
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac
        let sourceSignal = signal
        let sessionID = recordingSessionID

        chanHealth.task?.cancel()
        chanHealth.task = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                ChannelHealthAnalyzer.analyze(
                    signal: sourceSignal,
                    layout: layout,
                    base: baseConfig,
                    spectral: spectralConfig,
                    ransac: ransacConfig,
                    impedancesKOhm: impedances
                )
            }
            let analysis = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            for channel in affected {
                channels.healthResults[channel] = analysis.resultsByChannel[channel]
            }
            chanHealth.task = nil
        }
    }

    /// Estimates an interpolated channel's health as the spline-weighted average
    /// of its contributing channels' goodness. Returns `nil` when the channel
    /// has no recorded contributors, or none of them have a health score yet
    /// (caller then falls back to a real analysis).
    @MainActor
    private func averagedNeighborHealth(for channel: Int) -> ChannelHealthResult? {
        guard let source = channels.interpolationSources[channel] else { return nil }

        var weightedGood = 0.0
        var weightTotal = 0.0
        var count = 0
        for (contributor, weight) in zip(source.indices, source.weights) {
            guard let result = channels.healthResults[contributor] else { continue }
            let w = Double(abs(weight))
            weightedGood += w * Double(result.goodPercentage)
            weightTotal += w
            count += 1
        }
        guard weightTotal > 0, count > 0 else { return nil }

        let good = Int((weightedGood / weightTotal).rounded())
        return ChannelHealthResult(
            channelIndex: channel,
            goodPercentage: good,
            grade: HealthScoring.grade(for: Double(good) / 100),
            summary: "Estimated from \(count) contributing channel\(count == 1 ? "" : "s") (interpolated).",
            metrics: []
        )
    }

    @MainActor
    private func startChannelHealthScan(for signal: MFFSignalData, signature: String) {
        chanHealth.task?.cancel()
        chanHealth.signature = signature
        channels.healthResults = [:]
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        chanHealth.statusMessage = nil

        let layout = recording.sensorLayout
        let sourceSignal = signal
        let impedances = recording.signal?.impedancesKOhm
        let baseConfig = goodnessSettings.base
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac
        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        chanHealth.task = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                ChannelHealthAnalyzer.analyze(
                    signal: sourceSignal,
                    layout: layout,
                    base: baseConfig,
                    spectral: spectralConfig,
                    ransac: ransacConfig,
                    impedancesKOhm: impedances,
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
                  chanHealth.signature == signature else {
                return
            }

            channels.healthResults = analysis.resultsByChannel
            channels.isAnalyzingHealth = false
            channels.healthProgress = 1
            chanHealth.statusMessage = analysis.resultsByChannel.isEmpty
                ? "No channel health metrics available."
                : "Channel health scored \(analysis.resultsByChannel.count) channels."
        }
    }

    private func saveChannelLabelMetricsJSON() {
        guard !channels.bad.isEmpty else {
            chanHealth.statusMessage = "Mark at least one bad channel before saving labels."
            return
        }
        guard let signal = currentChannelLabelMetricsSignal() else {
            chanHealth.statusMessage = "No signal is ready for channel-label export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultChannelLabelMetricsExportName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        chanHealth.task?.cancel()
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        chanHealth.statusMessage = "Saving channel label metrics..."

        let packageName = recording.packageName
        let layout = recording.sensorLayout
        let impedances = recording.signal?.impedancesKOhm
        let processing = channelHealthProcessingSnapshot()
        let hiddenChannels = channels.hidden
        let baseConfig = goodnessSettings.base
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        chanHealth.task = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                do {
                    let analysis = ChannelHealthAnalyzer.analyze(
                        signal: signal,
                        layout: layout,
                        base: baseConfig,
                        spectral: spectralConfig,
                        ransac: ransacConfig,
                        impedancesKOhm: impedances,
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
            }
            let result = await withTaskCancellationHandler(
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
            channels.isAnalyzingHealth = false

            switch result {
            case .success(let channelCount):
                channels.healthProgress = 1
                chanHealth.statusMessage = "Saved labels and metrics for \(channelCount) channels: \(url.lastPathComponent)"
            case .failure(let error):
                channels.healthProgress = 0
                chanHealth.statusMessage = error.localizedDescription
            }
        }
    }

    private func currentChannelLabelMetricsSignal() -> MFFSignalData? {
        guard let rawSignal = recording.signal else { return nil }
        let base = ica.cleanedSignal ?? gradient.correctedSignal ?? rawSignal
        let preArtifact = filter.output ?? base
        return artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
    }

    private func channelHealthProcessingSnapshot() -> SavedChannelHealthProcessing {
        SavedChannelHealthProcessing(
            gradientCorrected: gradient.correctedSignal != nil,
            icaCleaned: ica.cleanedSignal != nil,
            filtered: filter.output != nil,
            filterLowCutoffHz: filter.output == nil ? nil : filter.highPassCutoff,
            filterHighCutoffHz: filter.output == nil ? nil : filter.lowPassCutoff,
            notch60HzEnabled: filter.output == nil ? nil : filter.notch60HzEnabled,
            averageReferenced: filter.output == nil ? nil : filter.averageReference,
            artifactCleaned: artifactVM.cleanedSignal != nil,
            artifactCleaningVisible: artifactVM.cleanedSignal != nil && artifactVM.cleaningIsEnabled,
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
            "\(segHealth.shows)",
            "\(segHealth.refreshRequest)",
            segmentHealthSignature(for: signal)
        ].joined(separator: "|")
    }

    private func segmentHealthSignature(for signal: MFFSignalData) -> String {
        let badChannelSignature = channels.bad.sorted().map(String.init).joined(separator: ",")
        let interpolationSignature = channels.interpolated.keys.sorted().map(String.init).joined(separator: ",")
        let epochSignature = epoching.epochSegments.map(\.id).joined(separator: ",")
        let definedArtifactSignature = template.definedArtifacts.map { artifact in
            [
                artifact.id.uuidString,
                artifact.eventCode,
                "\(artifactVM.events.count)",
                "\(artifact.windowSizeSeconds)"
            ].joined(separator: ":")
        }.joined(separator: ",")
        let artifactEventSignature = artifactVM.events.map { event in
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
            "\(gradient.correctedSignal != nil)",
            "\(ica.cleanedSignal != nil)",
            "\(filter.output != nil)",
            "\(artifactVM.cleanedSignal != nil)",
            "\(artifactVM.cleaningIsEnabled)",
            "\(epoching.epochedSignal != nil)",
            "\(epoching.isAveraged)",
            "\(epoching.baselineCorrected)",
            "\(epoching.averageReference)",
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
            epochSegments: epoching.epochedSignal == nil ? [] : epoching.epochSegments
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

        if epoching.epochedSignal != nil, !epoching.epochSegments.isEmpty {
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

        for artifact in template.definedArtifacts {
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

        for event in artifactVM.events where !definedEvents.contains(event) {
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
        for segment in epoching.epochSegments {
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

        guard segHealth.shows else {
            segHealth.task?.cancel()
            segHealth.task = nil
            segHealth.signature = nil
            segHealth.analysis = nil
            segHealth.isAnalyzing = false
            segHealth.progress = 0
            segHealth.statusMessage = nil
            return
        }

        guard segHealth.signature != signature || segHealth.analysis?.results.isEmpty != false else {
            return
        }

        let segments = segmentHealthInputSegments(for: signal)
        guard !segments.isEmpty else {
            segHealth.analysis = nil
            segHealth.statusMessage = "No segments are available to score."
            return
        }

        segHealth.task?.cancel()
        segHealth.signature = signature
        segHealth.analysis = nil
        segHealth.isAnalyzing = true
        segHealth.progress = 0
        segHealth.statusMessage = nil

        let excludedChannels = channels.bad
        let artifactIntervals = segmentHealthArtifactIntervals(for: signal)
        let sourceSignal = signal
        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            segHealth.progress = min(max(fraction, 0), 1)
        }

        segHealth.task = Task { @MainActor in
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
                  segHealth.shows,
                  segHealth.signature == signature else {
                return
            }

            segHealth.analysis = analysis
            segHealth.isAnalyzing = false
            segHealth.progress = 1
            segHealth.statusMessage = analysis.results.isEmpty
                ? "No segment health metrics available."
                : "Segment health scored \(analysis.results.count) segments."
        }
    }

    private func segmentHealthDetailsSheet() -> some View {
        SegmentHealthDetailsView(
            results: segHealth.analysis?.results ?? [],
            isAnalyzing: segHealth.isAnalyzing,
            progress: segHealth.progress,
            statusMessage: segHealth.statusMessage,
            onRefresh: {
                segHealth.shows = true
                segHealth.refreshRequest += 1
            },
            onSave: {
                saveSegmentHealthMetricsJSON()
            },
            onJump: { result in
                jumpToSegment(result)
            },
            onClose: {
                segHealth.showsDetails = false
            }
        )
    }

    private func saveSegmentHealthMetricsJSON() {
        guard let signal = currentSegmentHealthSignal() else {
            segHealth.statusMessage = "No signal is ready for segment-metrics export."
            return
        }

        let segments = segmentHealthInputSegments(for: signal)
        guard !segments.isEmpty else {
            segHealth.statusMessage = "No segments are available to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultSegmentHealthExportName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        segHealth.task?.cancel()
        segHealth.shows = true
        segHealth.isAnalyzing = true
        segHealth.progress = 0
        segHealth.statusMessage = "Saving segment health metrics..."

        let signature = segmentHealthSignature(for: signal)
        let reusableAnalysis = segHealth.signature == signature ? segHealth.analysis : nil
        let packageName = recording.packageName
        let processing = segmentHealthProcessingSnapshot()
        let excludedChannels = channels.bad
        let artifactIntervals = segmentHealthArtifactIntervals(for: signal)

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            segHealth.progress = min(max(fraction, 0), 1)
        }

        segHealth.task = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
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
            }
            let result = await withTaskCancellationHandler(
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
            segHealth.isAnalyzing = false

            switch result {
            case .success(let payload):
                segHealth.progress = 1
                segHealth.signature = signature
                segHealth.analysis = payload.1
                segHealth.statusMessage = "Saved metrics for \(payload.0) segments: \(url.lastPathComponent)"
            case .failure(let error):
                segHealth.progress = 0
                segHealth.statusMessage = error.localizedDescription
            }
        }
    }

    private func currentSegmentHealthSignal() -> MFFSignalData? {
        guard let rawSignal = recording.signal else { return nil }
        let base = ica.cleanedSignal ?? gradient.correctedSignal ?? rawSignal
        let preArtifact = filter.output ?? base
        let processed = artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
        let continuousSignal = applyInterpolations(to: processed)
        return epoching.epochedSignal ?? continuousSignal
    }

    private func segmentHealthProcessingSnapshot() -> SavedSegmentHealthProcessing {
        SavedSegmentHealthProcessing(
            gradientCorrected: gradient.correctedSignal != nil,
            icaCleaned: ica.cleanedSignal != nil,
            filtered: filter.output != nil,
            filterLowCutoffHz: filter.output == nil ? nil : filter.highPassCutoff,
            filterHighCutoffHz: filter.output == nil ? nil : filter.lowPassCutoff,
            notch60HzEnabled: filter.output == nil ? nil : filter.notch60HzEnabled,
            averageReferenced: filter.output == nil ? nil : filter.averageReference,
            artifactCleaned: artifactVM.cleanedSignal != nil,
            artifactCleaningVisible: artifactVM.cleanedSignal != nil && artifactVM.cleaningIsEnabled,
            epoched: epoching.epochedSignal != nil,
            psaAveraged: epoching.isAveraged,
            psaBaselineCorrected: epoching.baselineCorrected,
            psaAverageReferenced: epoching.averageReference,
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
        channelStatusIsError = false
        guard let geometry = electrodeGeometry, geometry.positions[index] != nil else {
            channelStatusMessage = "No 3D coordinates for Ch \(index + 1); can't interpolate."
            channelStatusIsError = true
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
            channelStatusIsError = true
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
        channels.interpolationSources[index] = (indices, weights.map(Float.init))
        channels.bad.remove(index)
        channelStatusMessage = "Interpolated Ch \(index + 1) from \(indices.count) neighbors."
        channelStatusIsError = false
        artifactVM.detectionRefreshToken += 1
        invalidateEpochsForSignalChange()
    }

    /// Interpolated channels are derived from the source data, so they go stale
    /// when the gradient/filter pipeline changes.
    func invalidateInterpolations() {
        channels.interpolated.removeAll()
        channels.interpolationSources.removeAll()
    }

    private func tearDownRecordingSessionForClose() {
        recordingSessionID = UUID()
        cancelInFlightRecordingTasks()
        clearRecordingStateForClose()
        recording.tearDownForClose()
        ChannelSetStore.shared.clearActiveRecordingContext()
    }

    private func cancelInFlightRecordingTasks() {
        waveletExplorerTask?.cancel()
        waveletExplorerTask = nil
        topographyTask?.cancel()
        topographyTask = nil
        artifactTemplateTask?.cancel()
        artifactTemplateTask = nil
        waveletReductionTask?.cancel()
        waveletReductionTask = nil
        artifactCleaningTask?.cancel()
        artifactCleaningTask = nil
        icaTask?.cancel()
        icaTask = nil
        icaRemovalTask?.cancel()
        icaRemovalTask = nil
        psaTask?.cancel()
        psaTask = nil
        filterTask?.cancel()
        filterTask = nil
        gradientTask?.cancel()
        gradientTask = nil
        replayTask?.cancel()
        replayTask = nil
        mffExportTask?.cancel()
        mffExportTask = nil
        bcgTask?.cancel()
        bcgTask = nil
        bcgRefinementTask?.cancel()
        bcgRefinementTask = nil

        filter.cancelInFlightWork()
        chanHealth.resetForClose()
        segHealth.resetForClose()
        eegAnalysis.resetForClose()
    }

    private func clearRecordingStateForClose() {
        removeCommandKeyMonitor()

        filter.resetForClose()
        ica.resetForClose()
        gradient.resetForClose()
        artifactVM.resetForClose()
        template.resetForClose()
        wavelet.resetForClose()
        epoching.resetForClose()
        bcg.resetForClose()
        eegAnalysis.resetForClose()
        chanHealth.resetForClose()
        segHealth.resetForClose()

        segmentedEpochSignal = nil
        segmentedEpochSegments = []
        syntheticPNSChannels = []
        displayedEventsCache = .empty
        eventTrackSourceSummary = .empty
        selectedEventID = nil
        highlightedArtifactEvent = nil
        selectedEventCodes.removeAll()
        topomapSample = nil
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        eventTrackContextSample = nil
        lastWaveformClick = nil
        waveformContentMinX = 0

        detectsEyeBlinkArtifacts = false
        detectsEyeMovementArtifacts = false
        blinkChannelOverrideText = ""
        movementChannelOverrideText = ""
        detectsECGArtifacts = false
        showsECGDetectionSheet = false
        ecgDetectionSelectedPNSChannels.removeAll()
        ecgDetectionProxyChannels = ""
        ecgProxyChannelSetID = nil
        isEstimatingECGDetection = false
        ecgAlgorithmResults = [:]

        isRunningWaveletArtifactExplorer = false
        showsWaveletArtifactExplorer = false
        waveletExplorerProgress = 0
        waveletExplorerStatusTitle = ""
        waveletExplorerStatusDetail = ""
        waveletExplorerStatusMessage = nil
        waveletExplorerLog = []
        waveletExplorerResult = nil
        waveletExplorerRunGeneration += 1

        statusHistory = []
        lastRecordedStatusBySource = [:]
        showsStatusHistory = false
        showsPhysioChannels = true
        physioRanges = []
        physioScaleFactors = [:]
        physioMaxScaledChannels = []
        physioFlippedPolarity = []
        physioChannelRenames = [:]
        physioRenameTarget = nil
        physioRenameText = ""

        channels.hidden.removeAll()
        channels.bad.removeAll()
        channels.interpolated.removeAll()
        channels.interpolationSources.removeAll()
        channels.clearHealthResults()
        channels.showsHealth = false
        channels.healthRefreshToken = 0
        electrodeGeometry = nil
        channelStatusMessage = nil
        channelStatusIsError = false
        showsChannelGoodnessSettings = false
        mffExportStatusMessage = nil
        isExportingMFF = false
    }

    /// Clears every derived buffer (filters, re-reference, MRI correction, ICA,
    /// artifact detections, epochs, interpolations) so the view falls back to the
    /// original recording — without needing to close and reopen the file.
    /// Analysis parameters (cutoffs, ICA settings, template names) are preserved.
    private func resetToOriginalData() {
        // Derived signals.
        filter.output = nil
        filter.pnsOutput = nil
        filter.pnsInputSignalType = nil
        ica.cleanedSignal = nil
        ica.decomposition = nil
        gradient.correctedSignal = nil
        gradient.correctedPNSSignal = nil
        artifactVM.cleanedSignal = nil
        artifactVM.cleaningIsEnabled = true
        wavelet.reducedSignal = nil
        wavelet.artifact = nil
        wavelet.result = nil
        wavelet.isEnabled = true
        wavelet.bandVarianceRetained = nil
        wavelet.statusMessage = nil
        wavelet.candidates = []
        wavelet.selectedCandidateID = nil

        // Artifact detection + templates.
        artifactVM.events = []
        template.result = nil
        template.definedArtifacts = []
        artifactVM.cleaningSummaries = []
        artifactVM.cleaningProgress = nil
        template.obsVarianceReportCache.removeAll()
        epoching.skippedDefinedArtifactIDs.removeAll()
        epoching.knownArtifactIDsForRejection.removeAll()
        detectsEyeBlinkArtifacts = false
        detectsEyeMovementArtifacts = false
        detectsECGArtifacts = false
        ecgDetectionSelectedPNSChannels.removeAll()
        ecgDetectionProxyChannels = ""
        template.selectedChannel = nil
        template.clickedChannel = nil
        template.selectionRange = nil
        template.definedArtifactID = nil

        // Status messages and progress.
        filter.statusMessage = nil
        filter.statusIsError = false
        ica.statusMessage = nil
        artifactVM.statusMessage = nil
        template.statusMessage = nil
        artifactVM.cleaningStatusMessage = nil
        gradient.statusMessage = nil
        epoching.statusMessage = nil
        channelStatusMessage = nil
        chanHealth.statusMessage = nil
        segHealth.statusMessage = nil
        if eegAnalysis.isRunning {
            eegAnalysis.cancel()
        }
        eegAnalysis.result = nil
        eegAnalysis.statusMessage = nil
        eegAnalysis.progress = 0
        ica.lastReconstructionDebugReport = nil

        // Interpolations, epochs, and the dependent selection/topomap state.
        invalidateInterpolations()
        channels.clearHealthResults()
        chanHealth.signature = nil
        segHealth.task?.cancel()
        segHealth.task = nil
        segHealth.analysis = nil
        segHealth.signature = nil
        segHealth.isAnalyzing = false
        segHealth.progress = 0
        invalidateEpochsForSignalChange()

        // Force artifact overlays and downstream views to rebuild from the base.
        artifactVM.detectionRefreshToken += 1
    }

    func invalidateEpochsForSignalChange() {
        epoching.epochedSignal = nil
        epoching.epochSegments = []
        segmentedEpochSignal = nil
        segmentedEpochSegments = []
        epoching.isAveraged = false
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        topomapSample = nil
        epoching.butterflyTopomapRelativeSample = nil
        epoching.showsButterflyPlot = false
        epoching.showsOverlaidCategories = false
        segHealth.task?.cancel()
        segHealth.task = nil
        segHealth.analysis = nil
        segHealth.signature = nil
        segHealth.isAnalyzing = false
        segHealth.progress = 0
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
        let displayedPoints = max(sampleCount / displaySampleStride(for: signal), 1)
        return max(CGFloat(displayedPoints) * CGFloat(timeScale), 600)
    }

    private var targetDisplaySamplesPerSecond: Double {
        referenceDisplaySampleRate / Double(referenceDisplaySampleStride)
    }

    private func displaySampleStride(for signal: MFFSignalData) -> Int {
        displaySampleStride(for: signal.samplingRate)
    }

    private func displaySampleStride(for samplingRate: Double) -> Int {
        guard samplingRate > 0 else { return referenceDisplaySampleStride }
        return max(Int((samplingRate / targetDisplaySamplesPerSecond).rounded()), 1)
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
        let sample = Int((plottedIndex * CGFloat(displaySampleStride(for: signal))).rounded())
        return min(max(sample, 0), max(sampleCount - 1, 0))
    }

    private func contentX(forSample sample: Int, in signal: MFFSignalData) -> CGFloat {
        (CGFloat(sample) / CGFloat(displaySampleStride(for: signal))) * CGFloat(timeScale)
    }

    private func topomapValues(at sample: Int, in signal: MFFSignalData) -> [Double] {
        signal.data.map { channel in
            sample < channel.count ? Double(channel[sample]) : 0
        }
    }

    private func jumpToEvent(_ event: MFFEvent, in signal: MFFSignalData) {
        selectedEventID = event.id
        let plotWidth = plotWidth(for: signal)
        let targetSample = Int((event.beginTimeSeconds * signal.samplingRate).rounded())
        let targetX = contentX(forSample: targetSample, in: signal)
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
        let segmentCenterX = (contentX(forSample: lower, in: signal) + contentX(forSample: upper + 1, in: signal)) / 2
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

    private func eventMetadataRows(for event: MFFEvent) -> [String] {
        var rows: [String] = []
        if let label = event.label {
            rows.append("Label: \(label)")
        }
        if let description = event.eventDescription {
            rows.append("Description: \(description)")
        }
        if let cell = event.cell {
            rows.append("Cell: \(cell)")
        }
        return rows
    }

    private func eventAccessibilitySummary(_ event: MFFEvent) -> String {
        ([event.code] + eventMetadataRows(for: event)).joined(separator: ", ")
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

    func groupedPSAEventSummaries(_ events: [MFFEvent]) -> [EventSummary] {
        Dictionary(grouping: events, by: psaSegmentValue(for:))
            .map { value, groupedEvents in
                let distinctCodes = Set(groupedEvents.map(\.code)).sorted()
                let searchFields = psaSearchFields(for: value, events: groupedEvents)
                let searchText = psaSearchText(fields: searchFields)
                let detail: String?
                switch epoching.segmentField {
                case .code:
                    let labels = Set(groupedEvents.compactMap(\.label)).sorted()
                    detail = labels.isEmpty ? nil : "Labels: \(labels.prefix(3).joined(separator: ", "))\(labels.count > 3 ? "..." : "")"
                case .label:
                    detail = distinctCodes.count == 1 ? "Code: \(distinctCodes[0])" : "\(distinctCodes.count) codes"
                case .artifact:
                    let duration = groupedEvents.last.map { $0.beginTimeSeconds } ?? 0
                    let bpm = duration > 0 ? String(format: "%.0f bpm avg", Double(groupedEvents.count) / duration * 60) : nil
                    detail = bpm
                }
                return EventSummary(
                    code: value,
                    count: groupedEvents.count,
                    detail: detail,
                    searchText: searchText,
                    searchFields: searchFields
                )
            }
            .sorted { lhs, rhs in
                lhs.count == rhs.count
                    ? lhs.code.localizedStandardCompare(rhs.code) == .orderedAscending
                    : lhs.count > rhs.count
            }
    }

    func filteredPSAEventSummaries(_ summaries: [EventSummary]) -> [EventSummary] {
        let filters = psaSearchFilters(from: epoching.eventSearchText)
        guard !filters.isEmpty else { return summaries }

        return summaries.filter { summary in
            filters.allSatisfy { filter in
                psaSummary(summary, matches: filter)
            }
        }
    }

    private func psaSummary(_ summary: EventSummary, matches filter: PSAEventSearchFilter) -> Bool {
        let needle = filter.value.lowercased()
        guard !needle.isEmpty else { return true }
        if let field = filter.field {
            return summary.searchFields[field]?.lowercased().contains(needle) == true
        }
        return summary.searchText.lowercased().contains(needle)
    }

    private func psaSearchFilters(from query: String) -> [PSAEventSearchFilter] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        var filters: [PSAEventSearchFilter] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if let filter = psaFieldFilter(
                from: token,
                nextToken: tokens.indices.contains(index + 1) ? tokens[index + 1] : nil,
                followingToken: tokens.indices.contains(index + 2) ? tokens[index + 2] : nil
            ) {
                filters.append(filter.filter)
                index += filter.consumedTokenCount
                continue
            }
            filters.append(PSAEventSearchFilter(field: nil, value: token))
            index += 1
        }

        return filters.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func psaFieldFilter(
        from token: String,
        nextToken: String?,
        followingToken: String?
    ) -> (filter: PSAEventSearchFilter, consumedTokenCount: Int)? {
        if let colon = token.firstIndex(of: ":") {
            let key = String(token[..<colon])
            let value = String(token[token.index(after: colon)...])
            guard let field = PSAEventSearchField(alias: key) else { return nil }
            if !value.isEmpty {
                return (PSAEventSearchFilter(field: field, value: value), 1)
            }
            guard let nextToken else { return nil }
            return (PSAEventSearchFilter(field: field, value: nextToken), 2)
        }

        guard let field = PSAEventSearchField(alias: token),
              let nextToken,
              nextToken.hasPrefix(":") else {
            return nil
        }
        let value = String(nextToken.drop(while: { $0 == ":" }))
        if !value.isEmpty {
            return (PSAEventSearchFilter(field: field, value: value), 2)
        }
        guard let followingToken else { return nil }
        return (PSAEventSearchFilter(field: field, value: followingToken), 3)
    }

    private func psaSearchFields(for segmentValue: String, events: [MFFEvent]) -> [PSAEventSearchField: String] {
        var values: [PSAEventSearchField: [String]] = [
            .code: [],
            .label: [],
            .description: [],
            .cell: [],
            .source: []
        ]
        switch epoching.segmentField {
        case .code:
            values[.code, default: []].append(segmentValue)
        case .label:
            values[.label, default: []].append(segmentValue)
        case .artifact:
            values[.code, default: []].append(segmentValue)
        }
        for event in events {
            values[.code, default: []].append(event.code)
            if let label = event.label { values[.label, default: []].append(label) }
            if let description = event.eventDescription { values[.description, default: []].append(description) }
            if let cell = event.cell { values[.cell, default: []].append(cell) }
            values[.source, default: []].append(event.sourceFile)
        }
        return values.mapValues { $0.joined(separator: " ") }
    }

    private func psaSearchText(fields: [PSAEventSearchField: String]) -> String {
        var values: [String] = []
        for field in PSAEventSearchField.allCases {
            guard let text = fields[field], !text.isEmpty else { continue }
            values.append("\(field.rawValue): \(text)")
        }
        return values.joined(separator: " ")
    }

    func psaSegmentValue(for event: MFFEvent) -> String {
        switch epoching.segmentField {
        case .code:
            return event.code
        case .label:
            return event.label ?? event.code
        case .artifact:
            return event.code
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

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
