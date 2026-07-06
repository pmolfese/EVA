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
    /// Median artifact subtraction — same per-TR template, elementwise median
    /// instead of a weighted mean across donor TRs. Inspired by `amri_eeg_gac.m`
    /// (AMRI toolbox, NINDS/NIH; see THIRD_PARTY_NOTICES.md).
    case mas = "MAS"
    /// Median artifact regression — MAS template, scaled by a least-squares
    /// fit before subtracting. Inspired by `amri_eeg_gac.m`.
    case mar = "MAR"
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
        case .mas: return "MAS"
        case .mar: return "MAR"
        case .fastr: return "FASTR"
        case .moosmann: return "Moosmann"
        case .farm: return "FARM"
        }
    }

    /// Whether this method runs the FASTR pipeline (slice/OBS/ANC options apply).
    var isFASTR: Bool { self == .fastr || self == .moosmann || self == .farm }

    /// Whether this method runs through `GradientRemover`'s per-TR template
    /// path (as opposed to the FASTR pipeline).
    var isTemplateBased: Bool { self == .aas || self == .mas || self == .mar }
}

struct WaveformView: View {
    @ObservedObject var recording: MFFRecording

    @Environment(\.modelContext) private var modelContext
    @Environment(ChannelGoodnessSettings.self) var goodnessSettings
    @Environment(SegmentGoodnessSettings.self) var segmentGoodnessSettings
    @Environment(ProcessingDefaults.self) var processingDefaults
    @Environment(BatchController.self) var batch
    /// Guards batch auto-start to once per freshly-built (per-recording) view.
    @State private var batchStarted = false
    @Query private var markers: [UserMarker]

    @AppStorage(ToolbarButtonLabels.storageKey) private var showsToolbarButtonLabels = true
    @AppStorage(EVAGeneralPreferences.pixelAdaptiveWaveformRenderingKey) var usesPixelAdaptiveWaveformRendering = true

    @State var recordingStore = RecordingStore()
    var amplitudeScale: Double {
        get { recordingStore.amplitudeScale }
        nonmutating set { recordingStore.amplitudeScale = newValue }
    }
    var timeScale: Double {
        get { recordingStore.timeScale }
        nonmutating set { recordingStore.timeScale = newValue }
    }
    var horizontalOffset: CGFloat {
        get { recordingStore.horizontalOffset }
        nonmutating set { recordingStore.horizontalOffset = newValue }
    }
    var horizontalViewportWidth: CGFloat {
        get { recordingStore.horizontalViewportWidth }
        nonmutating set { recordingStore.horizontalViewportWidth = newValue }
    }
    var horizontalScrollPosition: ScrollPosition {
        get { recordingStore.horizontalScrollPosition }
        nonmutating set { recordingStore.horizontalScrollPosition = newValue }
    }
    @State var horizontalJumpValue: Double = 0
    @State var isSyncingSliderFromScroll = false
    @State var isCommandKeyPressed = false
    @State private var commandKeyMonitor: Any?
    @State var showsEventsPanel = false
    @State var selectedEventID: MFFEvent.ID?
    /// Artifact event whose window is highlighted in the waveform (tap its flag).
    @State var highlightedArtifactEvent: MFFEvent?
    @State var highlightedArtifactColor: Color = .orange
    @State var selectedEventCodes = Set<String>()
    @State private var displayedEventsCache = WaveformDisplayedEventsCache.empty
    @State private var eventTrackSourceSummary = EventTrackSourceSummary.empty
    @State var topomapSample: Int?
    @State var selectedSampleRange: ClosedRange<Int>?
    @State var dragSelectionStartSample: Int?
    @State var dragSelectionEndSample: Int?
    @State var eventTrackContextSample: Int?
    /// Timestamp of the last stationary click, used to detect a double-click
    /// manually inside the single waveform interaction gesture.
    @State var lastWaveformClick: (time: Date, x: CGFloat)?
    /// Live global x of the scrolling waveform content's leading edge. Used to
    /// convert a gesture's global x into a scroll-independent content x.
    @State var waveformContentMinX: CGFloat = 0
    @State var detectsEyeBlinkArtifacts = false
    @State var detectsEyeMovementArtifacts = false
    /// Raw text buffers for the threshold-panel ocular-channel override fields
    /// (kept out of the config so mid-typing doesn't reparse the entry).
    @State private var blinkChannelOverrideText = ""
    @State private var movementChannelOverrideText = ""
    // ECG / QRS detection domain, extracted into an L4 store.
    @StateObject var ecg: ECGDetectionViewModel
    // BCG detection
    // BCG detection domain, extracted into an L4 store (REFACTOR.md).
    @StateObject var bcg: BCGDetectionViewModel
    /// Stable UUID so re-running detection updates the existing DefinedArtifact rather than appending a new one.
    let bcgDefinedArtifactID = UUID()
    // Artifact detection + cleaning domain, extracted into an L4 store. See
    // REFACTOR.md slice 5.
    @StateObject var artifactVM: ArtifactViewModel
    // "Define Artifact" template-detection domain, extracted into an L4 store
    // (REFACTOR.md — analysis-domain slice).
    @StateObject var template: ArtifactTemplateViewModel
    // Wavelet artifact explorer domain, extracted into an L4 store.
    @StateObject var waveletExplorer: WaveletArtifactExplorerViewModel
    // ICA decomposition + component removal, extracted into an L4 store. See
    // REFACTOR.md slice 6.
    @StateObject var ica: ICAViewModel
    // PSA epoching / averaging + averaged-data display, extracted into an L4
    // store. See REFACTOR.md slice 4.
    @StateObject var epoching: EpochingViewModel
    @State var segmentedEpochSignal: MFFSignalData?
    @State var segmentedEpochSegments: [EpochSegment] = []
    // Single Trial Analysis domain, extracted into an L4 store — reads the
    // raw per-trial epochs above (segmentedEpochSignal/segmentedEpochSegments),
    // not epoching's averaged output.
    @StateObject var singleTrial: SingleTrialAnalysisViewModel
    @StateObject var eegAnalysis: EEGAnalysisViewModel

    // Band-pass / notch filtering (applied to the active base signal).
    /// Filtering domain (band-pass / line-noise / average-reference), extracted
    /// into an L4 store. See REFACTOR.md.
    @StateObject var filter: FilterViewModel
    // Wavelet artifact reduction (HAPPE-style) pipeline stage.
    // Wavelet-reduction domain, extracted into an L4 store. See REFACTOR.md slice 3.
    @StateObject var wavelet: WaveletReductionViewModel
    @State var channelStatusIsError = false
    // Scrollable status history (newest first), shown when the status area is clicked.
    @State private var statusHistory: [StatusHistoryEntry] = []
    @State private var lastRecordedStatusBySource: [String: String] = [:]
    @State private var showsStatusHistory = false
    // Physio (PNS) channel display. Shown by default when present; pinned below
    // the EEG channels and synced to the EEG time axis.
    @State var showsPhysioChannels = true
    @State var physioRanges: [ClosedRange<Float>] = []
    @State var physioScaleFactors: [Int: Double] = [:]
    @State var physioMaxScaledChannels = Set<Int>()
    @State var physioFlippedPolarity = Set<Int>()
    /// User-assigned renames for physio channels (keyed by merged channel index).
    @State var physioChannelRenames: [Int: String] = [:]
    /// Index of the channel currently being renamed (nil when no rename in progress).
    @State var physioRenameTarget: Int? = nil
    @State var physioRenameText: String = ""
    /// Synthetic PNS channels created from ICA components.
    @State var syntheticPNSChannels: [SyntheticPNSChannel] = []


    // MRI gradient-artifact removal domain (AAS / FASTR / FARM / Moosmann),
    // extracted into an L4 store. See REFACTOR.md slice 2.
    @StateObject var gradient: GradientViewModel
    @StateObject var replay = ReplayController()

    // Per-channel state, shared with the menu-bar Channels commands.
    var channels: ChannelModel { recordingStore.channels }
    /// Serializes major processing operations (filter, gradient, ICA, wavelet
    /// reduction, artifact cleaning, channel/segment health, PSA, BCG, EEG
    /// analysis) so at most one runs at a time even if triggered back to
    /// back. Lives on `RecordingStore` (not owned here) so standalone VMs
    /// that only hold `store` can reach it too.
    var processingQueue: ProcessingQueue { recordingStore.processingQueue }
    @State var electrodeGeometry: ElectrodeGeometry?
    @State var channelStatusMessage: String?
    @State private var channelLabelMetricsExportRequest = 0
    // Channel-health coordination, extracted into an L4 store (REFACTOR.md).
    @StateObject var chanHealth: ChannelHealthViewModel
    @State private var showsChannelGoodnessSettings = false
    @State private var channelGoodnessSettingsRequest = 0
    // Segment-health domain, extracted into an L4 store (REFACTOR.md).
    @StateObject var segHealth: SegmentHealthViewModel
    @State private var resetToOriginalRequest = 0
    @State private var mffExportRequest = 0
    @State private var copyProcessingRequest = 0
    @State private var datasetInfoRequest = 0
    @State private var showsDatasetInfo = false
    @State private var importPhysioRequest = 0
    @State var showsPhysioImportSheet = false
    /// Set to scroll the channel list to that row (e.g. from a topomap/butterfly
    /// click); `.scrollPosition(id:)` on the vertical channel ScrollView consumes it.
    @State var scrollToChannelRequest: Int?
    @State var showsChannelInspector = false
    @State var channelInspectorSelection: ChannelInspectorSelection = .channel(0)
    @State var channelInspectorOverlayEnabled = true
    @State var channelInspectorShowsStandardError = false
    @State var showsCategoryGroupPopover = false
    @State var categoryGroupName = ""
    @State var categoryGroupSelectedCodes = Set<String>()
    @State var isExportingMFF = false
    @State var mffExportStatusMessage: String?
    @State var recordingSessionID = UUID()
    @State var waveletExplorerTask: Task<Void, Never>?
    @State var topographyTask: Task<Void, Never>?
    @State var artifactTemplateTask: Task<Void, Never>?
    @State var waveletReductionTask: Task<Void, Never>?
    @State var artifactCleaningTask: Task<Void, Never>?
    @State var icaTask: Task<Void, Never>?
    @State var icaRemovalTask: Task<Void, Never>?
    @State var psaTask: Task<Void, Never>?
    @State var filterTask: Task<Void, Never>?
    @State var gradientTask: Task<Void, Never>?
    @State var replayTask: Task<Void, Never>?
    @State var mffExportTask: Task<Void, Never>?
    @State var bcgTask: Task<Void, Never>?
    @State var bcgRefinementTask: Task<Void, Never>?
    @State var artifactIdentityRefreshTask: Task<Void, Never>?

    /// Keep the time slider visually comparable across sampling rates. The old
    /// fixed stride of 5 samples at 1000 Hz displayed about 200 plotted points/s.
    private let referenceDisplaySampleRate = 1_000.0
    private let referenceDisplaySampleStride = 5
    let channelRowHeight: CGFloat = 70
    let channelOverflowHeight: CGFloat = 28
    private let eventTrackHeight: CGFloat = 64
    private let rowSpacing: CGFloat = 12
    let labelColumnWidth: CGFloat = 120
    private let geometryUpdateQuantum: CGFloat = 0.5
    private let jumpSliderUpdateQuantum = 0.0005
    private let eventsPanelWidth: CGFloat = 300
    private let topomapPanelWidth: CGFloat = 320
    private let butterflyPanelWidth: CGFloat = 360
    private let overlaidCategoriesPanelWidth: CGFloat = 380
    private let amplitudeScaleBounds: ClosedRange<Double> = 1...5_000
    let physioScaleOptions: [Double] = [8, 16, 32, 64]
    let physioScaleBounds: ClosedRange<Double> = 1...64

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
            averagedDisplayMode: $epoching.averagedDisplayMode,
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

    /// Custom init so every domain VM can hold the SAME `RecordingStore` instance
    /// directly (RecordingStore direct-injection pass, REFACTOR.md) instead of
    /// reading channel/viewport state through WaveformView's forwarding
    /// properties. Properties not listed here keep their inline default values —
    /// Swift only requires explicit assignment for properties whose default
    /// needs to change (here, `store` must be the SAME instance across
    /// `recordingStore` and every VM, not each's own default `RecordingStore()`).
    init(recording: MFFRecording) {
        self.recording = recording
        let store = RecordingStore()
        _recordingStore = State(initialValue: store)
        _ecg = StateObject(wrappedValue: ECGDetectionViewModel(store: store))
        _bcg = StateObject(wrappedValue: BCGDetectionViewModel(store: store))
        _artifactVM = StateObject(wrappedValue: ArtifactViewModel(store: store))
        _template = StateObject(wrappedValue: ArtifactTemplateViewModel(store: store))
        _ica = StateObject(wrappedValue: ICAViewModel(store: store))
        _epoching = StateObject(wrappedValue: EpochingViewModel(store: store))
        _singleTrial = StateObject(wrappedValue: SingleTrialAnalysisViewModel(store: store))
        _eegAnalysis = StateObject(wrappedValue: EEGAnalysisViewModel(store: store))
        _filter = StateObject(wrappedValue: FilterViewModel(store: store))
        _wavelet = StateObject(wrappedValue: WaveletReductionViewModel(store: store))
        _gradient = StateObject(wrappedValue: GradientViewModel(store: store))
        _chanHealth = StateObject(wrappedValue: ChannelHealthViewModel(store: store))
        _segHealth = StateObject(wrappedValue: SegmentHealthViewModel(store: store))
        _waveletExplorer = StateObject(wrappedValue: WaveletArtifactExplorerViewModel(store: store))
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
                let base = ica.cleanedSignal ?? bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
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
        .focusedSceneValue(\.importPhysioRequest, $importPhysioRequest)
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
        .onChange(of: importPhysioRequest) { _, _ in
            showsPhysioImportSheet = true
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
        seedPhysioPolarityDefaultsIfNeeded()
        adoptOnDiskEpochsIfPresent()
        autoStartBatchIfNeeded()
    }

    /// Honor each PNS sensor's own `<positiveUp>` convention as the initial
    /// polarity (channels marked negative-up start flipped), instead of
    /// drawing every physio trace positive-up like EEG. Only seeds channels
    /// the user hasn't already touched via the per-channel "Flip Polarity"
    /// control, and only runs once per load (`physioFlippedPolarity` starts
    /// empty right before this on a fresh recording).
    private func seedPhysioPolarityDefaultsIfNeeded() {
        guard physioFlippedPolarity.isEmpty,
              let flags = recording.pnsSignal?.positiveUpFlags else { return }
        for (index, positiveUp) in flags.enumerated() where !positiveUp {
            physioFlippedPolarity.insert(index)
        }
    }

    /// When a Batch run swaps this file in, auto-configure the replay from the
    /// shared batch config and start it (once). Load failures are reported so the
    /// batch advances past a bad file.
    private func autoStartBatchIfNeeded() {
        guard batch.isActive, !batchStarted, batch.matches(recording: recording) else { return }
        guard let signal = recording.signal else {
            batch.completeCurrent(.failed(recording.loadError ?? "Could not load recording."))
            return
        }
        guard let script = batch.script else { return }
        batchStarted = true
        // Compatibility pre-flight per file: a step compatible with most batch
        // files may not be with this one (e.g. missing TR markers), so it's
        // re-checked here even though the batch template already chose which
        // steps to include.
        replay.configure(fromBatch: batch, script: script, signal: signal)
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
    func displayedEvents(
        for signal: MFFSignalData,
        includeContinuousOverlays: Bool = true,
        includeArtifactOverlays: Bool = true,
        mapContinuousOverlaysIntoEpochs: Bool = false
    ) -> [MFFEvent] {
        guard includeContinuousOverlays else {
            return signal.events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        }

        let overlays = mapContinuousOverlaysIntoEpochs
            ? epochedContinuousOverlayEvents(for: signal, includeArtifactOverlays: includeArtifactOverlays)
            : continuousOverlayEventsForDisplay(includeArtifactOverlays: includeArtifactOverlays)
        return (signal.events + overlays).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    private func displayedEventsCacheKey(
        for signal: MFFSignalData,
        includeContinuousOverlays: Bool,
        includeArtifactOverlays: Bool,
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
            includeArtifactOverlays: includeArtifactOverlays,
            mapContinuousOverlaysIntoEpochs: mapContinuousOverlaysIntoEpochs
        )
    }

    private func refreshDisplayedEventsCache(
        for signal: MFFSignalData,
        includeContinuousOverlays: Bool,
        includeArtifactOverlays: Bool,
        mapContinuousOverlaysIntoEpochs: Bool,
        key: WaveformDisplayedEventsCache.Key
    ) {
        guard displayedEventsCache.key != key else { return }
        displayedEventsCache = WaveformDisplayedEventsCache(
            key: key,
            events: displayedEvents(
                for: signal,
                includeContinuousOverlays: includeContinuousOverlays,
                includeArtifactOverlays: includeArtifactOverlays,
                mapContinuousOverlaysIntoEpochs: mapContinuousOverlaysIntoEpochs
            )
        )
    }

    private func continuousOverlayEventsForDisplay(includeArtifactOverlays: Bool = true) -> [MFFEvent] {
        var events = userMarkerEvents
        var seenIDs = Set(events.map(\.id))

        guard includeArtifactOverlays else { return events }

        for event in definedArtifactEventList() where seenIDs.insert(event.id).inserted {
            events.append(event)
        }
        for event in artifactVM.events where seenIDs.insert(event.id).inserted {
            events.append(event)
        }

        return events
    }

    private func epochedContinuousOverlayEvents(
        for signal: MFFSignalData,
        includeArtifactOverlays: Bool = true
    ) -> [MFFEvent] {
        guard epoching.epochedSignal != nil,
              signal.samplingRate > 0,
              !epoching.epochSegments.isEmpty else {
            return []
        }

        return continuousOverlayEventsForDisplay(includeArtifactOverlays: includeArtifactOverlays)
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
        let includeArtifactOverlays = !epoching.isAveraged
        let eventCacheKey = displayedEventsCacheKey(
            for: signal,
            includeContinuousOverlays: true,
            includeArtifactOverlays: includeArtifactOverlays,
            mapContinuousOverlaysIntoEpochs: isShowingEpochs
        )
        let events = displayedEventsCache.key == eventCacheKey
            ? displayedEventsCache.events
            : displayedEvents(
                for: signal,
                includeContinuousOverlays: true,
                includeArtifactOverlays: includeArtifactOverlays,
                mapContinuousOverlaysIntoEpochs: isShowingEpochs
            )
        let displayMode = epoching.isAveraged ? epoching.averagedDisplayMode : .waveform

        VStack(spacing: 0) {
            // Full-width button bar — side panels below must not shrink it.
            if displayMode == .averages {
                averagesToolbar(for: signal)
            } else {
                controls(for: signal, base: base, waveletInput: waveletInput, continuousSignal: continuousSignal)
            }

            Divider()

            Group {
                if displayMode == .averages {
                    averagesWorkspace(for: signal)
                        .transition(.opacity)
                } else if displayMode == .trials {
                    singleTrialAnalysisWorkspace()
                        .transition(.opacity)
                } else {
                    waveformWorkspace(for: signal, events: events, isShowingEpochs: isShowingEpochs)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: displayMode)
        }
        .onAppear {
            refreshDisplayedEventsCache(
                for: signal,
                includeContinuousOverlays: true,
                includeArtifactOverlays: includeArtifactOverlays,
                mapContinuousOverlaysIntoEpochs: isShowingEpochs,
                key: eventCacheKey
            )
        }
        .onChange(of: eventCacheKey) { _, newKey in
            refreshDisplayedEventsCache(
                for: signal,
                includeContinuousOverlays: true,
                includeArtifactOverlays: includeArtifactOverlays,
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
        .sheet(isPresented: $ecg.showsSheet) {
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
                .onAppear {
                    autoSelectBCGProxySetIfEnabled(for: continuousSignal)
                    prepareCWLDefaults(pns: displayedPhysioSignal())
                }
        }
        .sheet(isPresented: $waveletExplorer.showsSheet) {
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
        .sheet(isPresented: $showsChannelInspector) {
            channelInspectorSheet(for: continuousSignal)
        }
        .sheet(isPresented: $showsDatasetInfo) {
            DatasetInfoSheet(
                recording: recording,
                epoching: epoching,
                onClose: { showsDatasetInfo = false }
            )
        }
        .sheet(isPresented: $showsPhysioImportSheet) {
            PhysioImportSheet(
                recording: recording,
                onComplete: { showsPhysioImportSheet = false },
                onCancel: { showsPhysioImportSheet = false }
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

    @ViewBuilder
    private func waveformWorkspace(for signal: MFFSignalData, events: [MFFEvent], isShowingEpochs: Bool) -> some View {
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
            toolbarScaleControls()

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
                .disabled(waveletExplorer.isRunning)

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
                
                Button(ecg.isEnabled ? "Configure ECG / QRS Detection…" : "ECG / QRS Detection…") {
                    openECGDetectionSheet(for: continuousSignal)
                }
                if ecg.isEnabled {
                    Button("Turn Off ECG Detection") {
                        ecg.isEnabled = false
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

            toolbarStatusAndModeControls(for: signal)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    func toolbarScaleControls(showsTimeScale: Bool = true) -> some View {
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

            if showsTimeScale {
                HStack(spacing: 8) {
                    Text("Time Scale")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: Binding(get: { timeScale }, set: { timeScale = $0 }), in: 0.2...8, step: 0.1)
                        .frame(width: 170)
                    Text(String(format: "%.1fx", timeScale))
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }

    func averagedModePicker() -> some View {
        Picker("View Mode", selection: $epoching.averagedDisplayMode) {
            ForEach(EpochingViewModel.AveragedDisplayMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 315)
        .help("Switch between waveform rows, averages, and single-trial analysis.")
    }

    func toolbarStatusAndModeControls(for signal: MFFSignalData) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                statusLog()
                    .frame(width: 240)

                Text(recordingToolbarSummary(for: signal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 240, alignment: .leading)
            }

            if epoching.isAveraged {
                averagedModePicker()
                    .frame(width: 315)
            }
        }
    }

    private func recordingToolbarSummary(for signal: MFFSignalData) -> String {
        var parts = [String]()
        if let netName = recording.sensorLayout?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !netName.isEmpty {
            parts.append(netName)
        }
        parts.append("\(signal.numberOfChannels) ch")
        parts.append("\(Int(signal.samplingRate)) Hz")
        parts.append("\(String(format: "%.1f", signal.duration)) s")
        return parts.joined(separator: " · ")
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
        if let explorerStatus = waveletExplorer.statusMessage {
            lines.append(LogLine(source: "Wavelet", text: explorerStatus, isError: false))
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
    func statusLog() -> some View {
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
                if waveletExplorer.isRunning {
                    logProgressRow(label: "Wavelet", value: waveletExplorer.progress)
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
                   !waveletExplorer.isRunning,
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
                        // Only artifact-detection events (defined artifacts,
                        // eye-artifact threshold detection) get this band;
                        // imported MFF events aren't highlighted this way. The
                        // band itself centers on `event.centerTimeSeconds`,
                        // which already accounts for onset-tagged sources
                        // (Topography/Continuous) vs. center-tagged ones
                        // (Template/Trajectory/threshold detection) — see
                        // `MFFEvent.centerTimeSeconds`.
                        if highlightedArtifactEvent?.id == event.id {
                            highlightedArtifactEvent = nil
                        } else if isCenteredArtifactDetectionEvent(event) {
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
                                .id(index)
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
                                        updateWaveformContentMinX(newValue)
                                    }
                            }
                        )
                        .gesture(waveformInteractionGesture(in: signal))
                        .padding(.trailing, 20)
                    }
                    .scrollPosition(Binding(get: { horizontalScrollPosition }, set: { horizontalScrollPosition = $0 }))
                    .scrollIndicators(.visible, axes: .horizontal)
                    .onScrollGeometryChange(
                        for: HorizontalViewport.self,
                        of: { geometry in
                            HorizontalViewport(
                                offsetX: quantizedGeometryValue(geometry.contentOffset.x),
                                width: quantizedGeometryValue(geometry.containerSize.width)
                            )
                        },
                        action: { _, newValue in
                            updateHorizontalViewport(newValue, plotWidth: plotWidth)
                        }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollPosition(id: $scrollToChannelRequest, anchor: .center)

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
                    fixedScale: nil,
                    channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                    onTapChannel: { openChannelInspector(channel: $0) }
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

    // MARK: - Channel interpolation

    /// Returns `signal` with any interpolated channels swapped in.
    func applyInterpolations(to signal: MFFSignalData) -> MFFSignalData {
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
    func interpolate(_ index: Int, in signal: MFFSignalData) {
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

        // Averaging is linear, so applying the SAME interpolation weights to the
        // already-averaged epoched signal's other channels reproduces exactly
        // what re-running PSA after interpolating would have produced — patch it
        // in place instead of discarding the averages (invalidateEpochsForSignalChange).
        // NOTE: `segmentedEpochSignal` is NOT a reliable "on-disk pre-segmented
        // file" signal — PSAEpochingViews.applyPSA sets it on every in-app PSA
        // run too (as a raw-epochs cache), so gating on it here was wrong: it
        // made this branch never fire after any normal PSA apply, silently
        // falling through to invalidateEpochsForSignalChange() every time
        // (previously masked; surfaced once something else called interpolate()
        // right after an Apply, e.g. the bad-channel escalation feature).
        if reinterpolateEpochedSignal(index, indices: indices, weights: weights) {
            // Averages patched in place — segmentation/averages remain intact.
        } else {
            invalidateEpochsForSignalChange()
        }
    }

    /// Re-derives channel `index` in the already-averaged `epoching.epochedSignal`
    /// using the SAME per-source weights just computed for the continuous signal,
    /// so an interpolation doesn't force re-running PSA. Returns false (no-op) if
    /// there's no averaged result yet, or the epoched signal doesn't have the
    /// same channel layout (stale/mismatched — safer to fall back to invalidating).
    private func reinterpolateEpochedSignal(_ index: Int, indices: [Int], weights: [Double]) -> Bool {
        guard let epoched = epoching.epochedSignal,
              epoched.data.indices.contains(index),
              indices.allSatisfy({ epoched.data.indices.contains($0) })
        else { return false }

        let length = epoched.data[index].count
        var series = [Float](repeating: 0, count: length)
        for (channelIndex, weight) in zip(indices, weights) {
            let source = epoched.data[channelIndex]
            guard source.count == length else { return false }
            vDSP.add(multiplication: (source, Float(weight)), series, result: &series)
        }
        var newData = epoched.data
        newData[index] = series
        epoching.epochedSignal = epoched.replacingData(newData)
        return true
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
        artifactIdentityRefreshTask?.cancel()
        artifactIdentityRefreshTask = nil

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
        singleTrial.resetForClose()
        bcg.resetForClose()
        ecg.resetForClose()
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

        waveletExplorer.resetForClose()

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
    func resetToOriginalData() {
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
        ecg.isEnabled = false
        ecg.selectedPNSChannels.removeAll()
        ecg.proxyChannels = ""
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
        epoching.psaExclusionSummary = PSAExclusionSummary()
        epoching.averagedDisplayMode = .waveform
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

    func plotWidth(for signal: MFFSignalData) -> CGFloat {
        let sampleCount = signal.data.first?.count ?? 0
        let displayedPoints = max(sampleCount / displaySampleStride(for: signal), 1)
        return max(CGFloat(displayedPoints) * CGFloat(timeScale), 600)
    }

    private var targetDisplaySamplesPerSecond: Double {
        referenceDisplaySampleRate / Double(referenceDisplaySampleStride)
    }

    func displaySampleStride(for signal: MFFSignalData) -> Int {
        displaySampleStride(for: signal.samplingRate)
    }

    func displaySampleStride(for samplingRate: Double) -> Int {
        guard samplingRate > 0 else { return referenceDisplaySampleStride }
        return max(Int((samplingRate / targetDisplaySamplesPerSecond).rounded()), 1)
    }

    private func quantizedGeometryValue(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return (value / geometryUpdateQuantum).rounded() * geometryUpdateQuantum
    }

    private func updateWaveformContentMinX(_ newValue: CGFloat) {
        let nextValue = quantizedGeometryValue(newValue)
        guard abs(waveformContentMinX - nextValue) >= geometryUpdateQuantum else { return }
        waveformContentMinX = nextValue
    }

    private func updateHorizontalViewport(_ viewport: HorizontalViewport, plotWidth: CGFloat) {
        let nextOffset = max(viewport.offsetX, 0)
        let nextWidth = max(viewport.width, 1)
        let offsetChanged = abs(horizontalOffset - nextOffset) >= geometryUpdateQuantum
        let widthChanged = abs(horizontalViewportWidth - nextWidth) >= geometryUpdateQuantum
        guard offsetChanged || widthChanged else { return }

        if offsetChanged {
            horizontalOffset = nextOffset
        }
        if widthChanged {
            horizontalViewportWidth = nextWidth
        }

        let resolvedOffset = offsetChanged ? nextOffset : horizontalOffset
        let resolvedWidth = widthChanged ? nextWidth : horizontalViewportWidth
        let maxOffset = max(plotWidth - resolvedWidth, 0)
        let nextJumpValue = maxOffset > 0 ? Double(resolvedOffset / maxOffset) : 0
        updateHorizontalJumpValueFromScroll(nextJumpValue)
    }

    private func updateHorizontalJumpValueFromScroll(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0), 1)
        guard abs(horizontalJumpValue - clamped) >= jumpSliderUpdateQuantum else { return }
        isSyncingSliderFromScroll = true
        horizontalJumpValue = clamped
        isSyncingSliderFromScroll = false
    }

    var visibleHorizontalRange: ClosedRange<CGFloat> {
        let buffer = horizontalViewportWidth * 0.15
        let lower = max(horizontalOffset - buffer, 0)
        let upper = horizontalOffset + horizontalViewportWidth + buffer
        return lower...upper
    }

    func sampleIndex(forContentX x: CGFloat, in signal: MFFSignalData) -> Int {
        let sampleCount = signal.data.first?.count ?? 1
        let plottedIndex = x / max(CGFloat(timeScale), 0.001)
        let sample = Int((plottedIndex * CGFloat(displaySampleStride(for: signal))).rounded())
        return min(max(sample, 0), max(sampleCount - 1, 0))
    }

    func contentX(forSample sample: Int, in signal: MFFSignalData) -> CGFloat {
        (CGFloat(sample) / CGFloat(displaySampleStride(for: signal))) * CGFloat(timeScale)
    }

    func topomapValues(at sample: Int, in signal: MFFSignalData) -> [Double] {
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

    func jumpToSegment(_ result: SegmentHealthResult) {
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

    func formattedEventTime(_ seconds: Double) -> String {
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

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
