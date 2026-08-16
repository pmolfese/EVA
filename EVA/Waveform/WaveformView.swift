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
//  Recording content view: scrolling multi-channel EEG waveforms, an event
//  track, a double-click-to-open scalp topomap, and an events panel.
//
//  ---------------------------------------------------------------------------
//  ADDING NEW UI HERE? PLEASE DON'T. (ROADMAP Priority 1, B5)
//
//  New view code goes in a standalone `View` struct that takes value inputs and
//  action closures — see `WaveformChannelRows.swift` for the pattern. The
//  `extension WaveformView` files are legacy: they are functions on one giant
//  struct, so SwiftUI has no per-child dependency boundary and every
//  AttributeGraph node that captures `self` copies the whole view. That copy is
//  a real, measured cost (`initializeWithCopy for WaveformView`, still ~1.5% of
//  the main thread and spiking during selection drags in `trace2.trace`).
//
//  Likewise, new *state* goes on one of the `@Observable` UI models in
//  `WaveformUIModels.swift` (hung off `RecordingStore`), not in a new `@State`
//  here. State behind a reference is not copied with the struct, Observation
//  tracks it per property, and menu-bar commands and the planned REWIND history
//  tree can reach it without a live view.
//
//  This file went 15,400 → ~2,700 lines once, then grew back to 3,014. The
//  point of the note is to stop that happening a third time.
//  ---------------------------------------------------------------------------
//

import Accelerate
import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Selectable MR gradient-artifact removal algorithm.
/// Which correction engine a method runs on.
///
/// EVA has three clean-room gradient engines, all under
/// `EVA/Gradient/`. They are separate implementations rather than one
/// configurable pipeline because the families genuinely differ: local-template
/// averaging, AMRI-style robust reduction, and slice-epoch FASTR with OBS/ANC
/// each have their own donor rules, guardrails, and diagnostics.
enum MRIGradientEngine {
    /// `GradientAAS` — local-neighbour and Allen-style average templates.
    case averageTemplate
    /// `LocalTemplateArtifactCorrector` — AMRI-style median/weighted templates.
    case localTemplate
    /// `GradientTemplateCorrector` — the FASTR family.
    case sliceTemplate
}

/// The top-level split the MRI sheet presents: whole-epoch template methods on
/// one side, slice-epoch FASTR-family methods on the other.
///
/// This is a user-facing grouping, not an engine boundary — the Template tab
/// spans two engines — because the distinction that matters when choosing is
/// "one template per volume" versus "subdivide the volume and model the
/// residual".
enum MRIGradientCategory: String, CaseIterable, Identifiable {
    case template = "Template"
    case fastr = "FASTR"

    var id: String { rawValue }

    /// Methods offered in the picker: everything in this family that is not
    /// retired. A retired method still exists and still runs — a replay file
    /// that names one must reproduce, and `MRIGradientMethod(rawValue:)` still
    /// resolves it — it is only withdrawn from new selections.
    var methods: [MRIGradientMethod] {
        MRIGradientMethod.allCases.filter { $0.category == self && !$0.isDeprecated }
    }

    /// Every method in this family, retired ones included.
    var allMethods: [MRIGradientMethod] {
        MRIGradientMethod.allCases.filter { $0.category == self }
    }
}

enum MRIGradientMethod: String, CaseIterable, Identifiable {
    /// Average artifact subtraction — EVA's local-neighbour volume template.
    ///
    /// Retired 2026-08-09. It existed because it was the fast option, and that
    /// is no longer a distinction: the local-template and FASTR engines are now
    /// GPU-backed and MAS runs a 64-channel ten-minute recording in about a
    /// tenth of a second. MAS is the nearer replacement — the same
    /// local-neighbour template, reduced with a median that resists a single
    /// contaminated donor.
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
    /// Allen et al. (2000) imaging artifact reduction: fixed running sections,
    /// correlation-gated template updates, and ANC.
    case allenIAR = "Allen IAR"
    /// Weighted average artifact subtraction — the local template family with an
    /// exponentially weighted reducer, so nearer donors count for more.
    case waas = "wAAS"
    /// Weighted average artifact regression — wAAS plus a least-squares fit.
    case waar = "wAAR"

    var id: String { rawValue }

    /// Display name. Kept separate from `rawValue`, which is the persistence key
    /// and must stay stable across renames.
    var label: String {
        switch self {
        case .aas: return "Fast AAS"
        case .allenIAR: return "Allen AAS"
        case .mas: return "MAS"
        case .mar: return "MAR"
        case .waas: return "wAAS"
        case .waar: return "wAAR"
        case .fastr: return "FASTR Original"
        case .moosmann: return "Moosmann"
        case .farm: return "FARM"
        }
    }

    var category: MRIGradientCategory {
        switch self {
        case .aas, .allenIAR, .mas, .mar, .waas, .waar: return .template
        case .fastr, .moosmann, .farm: return .fastr
        }
    }

    /// Withdrawn from the picker but still resolvable and still runnable, so
    /// existing eva.xml files keep reproducing.
    var isDeprecated: Bool { self == .aas }

    /// Why it was retired, and what to use instead. Shown in the sheet when a
    /// replay selects one.
    var deprecationNote: String? {
        switch self {
        case .aas:
            return "Fast AAS has been retired: it existed to be the quick option, and the other methods are now GPU-backed and faster. Allen AAS is the default in its place; MAS is the nearer match if you specifically want a local-neighbour template. Existing files that select Fast AAS still reproduce exactly."
        default:
            return nil
        }
    }

    var engine: MRIGradientEngine {
        switch self {
        case .aas, .allenIAR: return .averageTemplate
        case .mas, .mar, .waas, .waar: return .localTemplate
        case .fastr, .moosmann, .farm: return .sliceTemplate
        }
    }

    /// Whether the template is a least-squares-scaled fit rather than a plain
    /// subtraction. Only meaningful for the local-template engine.
    var fitsTemplateScale: Bool { self == .mar || self == .waar }

    /// Whether donors are weighted by temporal distance rather than reduced with
    /// an unweighted median.
    var weightsDonorsByDistance: Bool { self == .waas || self == .waar }

    /// Whether this method runs the FASTR pipeline (slice/OBS/ANC options apply).
    var isFASTR: Bool { engine == .sliceTemplate }

    /// Whether volumes are subdivided into slice epochs, which decides whether
    /// the slices-per-volume control and the slice-rate ANC cutoff mean anything.
    var supportsSliceEpochs: Bool { isFASTR || self == .allenIAR }

    /// Whether the method reads motion parameters at all.
    var usesMotion: Bool { self == .moosmann }

    /// Whether a donor-volume count means anything for this method.
    ///
    /// Allen AAS builds a running template over a fixed section of epochs rather
    /// than a neighbourhood of the target, so it is sized by "Section epochs"
    /// instead. Showing a donor count there would be offering a control the
    /// engine never reads.
    var usesDonorWindow: Bool { self != .allenIAR }
}

struct WaveformView: View {
    var recording: MFFRecording
    /// Non-nil only when this window was created by "Fork to New Window" —
    /// see `PendingWindowForks` and `applyForkSeed()`. `nil` for every
    /// ordinary open.
    let forkSeed: PendingWindowForks.Payload?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) var openWindow
    @Environment(ChannelGoodnessSettings.self) var goodnessSettings
    @Environment(SegmentGoodnessSettings.self) var segmentGoodnessSettings
    @Environment(ProcessingDefaults.self) var processingDefaults
    @Environment(BatchController.self) var batch
    /// Guards batch auto-start to once per freshly-built (per-recording) view.
    @State private var batchStarted = false
    /// This recording's user markers, pre-filtered and projected to value
    /// signatures by `WaveformMarkerContainer` (A3). Passing them in — rather than
    /// hosting the `@Query` here — keeps a `UserMarker` table change from
    /// re-evaluating the whole `WaveformView` body; only the tiny container
    /// re-runs, and this view re-renders only when its own markers actually change.
    let userMarkers: [WaveformUserMarkerSignature]

    @AppStorage(ToolbarButtonLabels.storageKey) private var showsToolbarButtonLabels = true
    @AppStorage(EVAGeneralPreferences.pixelAdaptiveWaveformRenderingKey) var usesPixelAdaptiveWaveformRendering = true
    @AppStorage(EVAGeneralPreferences.waveformTimeMarkersAcrossTracesKey) var showsTimeMarkersAcrossTraces = false
    @AppStorage(EVAGeneralPreferences.waveformTimeMarkerStyleKey) var waveformTimeMarkerStyleData = WaveformTimeMarkerStyle.defaultData

    @State var recordingStore = RecordingStore()
    var amplitudeScale: Double {
        get { recordingStore.amplitudeScale }
        nonmutating set { recordingStore.amplitudeScale = newValue }
    }
    var timeScale: Double {
        get { recordingStore.timeScale }
        nonmutating set { recordingStore.timeScale = newValue }
    }
    /// Read once per channel row in `waveformRow`, so it goes through the memo
    /// rather than decoding JSON per row per body pass. See
    /// `WaveformTimeMarkerStyleCache`.
    var waveformTimeMarkerStyle: WaveformTimeMarkerStyle {
        WaveformTimeMarkerStyleCache.style(for: waveformTimeMarkerStyleData)
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
    @State var isOptionKeyPressed = false
    @State private var optionKeyMonitor: Any?
    // B4: events-panel and selection state now live on `recordingStore.events` /
    // `recordingStore.selection`. These forwarders keep every existing call site
    // in the ~20 `extension WaveformView` files working unchanged; they come out
    // as children start reading the store directly.
    var showsEventsPanel: Bool {
        get { recordingStore.events.showsEventsPanel }
        nonmutating set { recordingStore.events.showsEventsPanel = newValue }
    }
    var selectedEventID: MFFEvent.ID? {
        get { recordingStore.events.selectedEventID }
        nonmutating set { recordingStore.events.selectedEventID = newValue }
    }
    /// Artifact event whose window is highlighted in the waveform (tap its flag).
    var highlightedArtifactEvent: MFFEvent? {
        get { recordingStore.selection.highlightedArtifactEvent }
        nonmutating set { recordingStore.selection.highlightedArtifactEvent = newValue }
    }
    var highlightedArtifactColor: Color {
        get { recordingStore.selection.highlightedArtifactColor }
        nonmutating set { recordingStore.selection.highlightedArtifactColor = newValue }
    }
    var selectedEventCodes: Set<String> {
        get { recordingStore.events.selectedEventCodes }
        nonmutating set { recordingStore.events.selectedEventCodes = newValue }
    }
    private var displayedEventsCache: WaveformDisplayedEventsCache {
        get { recordingStore.events.displayedEventsCache }
        nonmutating set { recordingStore.events.displayedEventsCache = newValue }
    }
    private var eventTrackSourceSummary: EventTrackSourceSummary {
        get { recordingStore.events.eventTrackSourceSummary }
        nonmutating set { recordingStore.events.eventTrackSourceSummary = newValue }
    }
    var topomapSample: Int? {
        get { recordingStore.selection.topomapSample }
        nonmutating set { recordingStore.selection.topomapSample = newValue }
    }
    var selectedSampleRange: ClosedRange<Int>? {
        get { recordingStore.selection.selectedSampleRange }
        nonmutating set { recordingStore.selection.selectedSampleRange = newValue }
    }
    var dragSelectionStartSample: Int? {
        get { recordingStore.selection.dragSelectionStartSample }
        nonmutating set { recordingStore.selection.dragSelectionStartSample = newValue }
    }
    var dragSelectionEndSample: Int? {
        get { recordingStore.selection.dragSelectionEndSample }
        nonmutating set { recordingStore.selection.dragSelectionEndSample = newValue }
    }
    var eventTrackContextSample: Int? {
        get { recordingStore.selection.eventTrackContextSample }
        nonmutating set { recordingStore.selection.eventTrackContextSample = newValue }
    }
    var waveformHoverInfo: WaveformHoverInfo? {
        get { recordingStore.selection.waveformHoverInfo }
        nonmutating set { recordingStore.selection.waveformHoverInfo = newValue }
    }
    /// Timestamp of the last stationary click, used to detect a double-click
    /// manually inside the single waveform interaction gesture.
    var lastWaveformClick: (time: Date, x: CGFloat)? {
        get { recordingStore.selection.lastWaveformClick }
        nonmutating set { recordingStore.selection.lastWaveformClick = newValue }
    }
    /// Live global x of the scrolling waveform content's leading edge. Used to
    /// convert a gesture's global x into a scroll-independent content x.
    var waveformContentMinX: CGFloat {
        get { recordingStore.selection.waveformContentMinX }
        nonmutating set { recordingStore.selection.waveformContentMinX = newValue }
    }
    /// Physical-unit entry for the scale popover. Text rather than numbers so a
    /// half-typed value does not re-scale the view on every keystroke.
    @AppStorage(EVAGeneralPreferences.defaultSensitivityKey)
    private var defaultSensitivityPreference = EVAGeneralPreferences.defaultSensitivity
    @AppStorage(EVAGeneralPreferences.defaultSweepKey)
    private var defaultSweepPreference = EVAGeneralPreferences.defaultSweep
    /// Load can be re-entered (`loadIfNeeded`), and re-seeding would discard
    /// scale changes the user made after opening.
    @State private var hasSeededDisplayScale = false
    @State private var showsScaleUnitsPopover = false
    @State private var sensitivityEntry = ""
    @State private var sweepEntry = ""
    @State var detectsEyeBlinkArtifacts = false
    @State var detectsEyeMovementArtifacts = false
    /// Raw text buffers for the threshold-panel ocular-channel override fields
    /// (kept out of the config so mid-typing doesn't reparse the entry).
    /// Not `private`: bound by the single sheet host in `WaveformSheetHost.swift` (B3).
    @State var blinkChannelOverrideText = ""
    @State var movementChannelOverrideText = ""
    // ECG / QRS detection domain, extracted into an L4 store.
    @State var ecg: ECGDetectionViewModel
    // BCG detection
    // BCG detection domain, extracted into an L4 store (REFACTOR.md).
    @State var bcg: BCGDetectionViewModel
    // Artifact detection + cleaning domain, extracted into an L4 store. See
    // REFACTOR.md slice 5.
    @State var artifactVM: ArtifactViewModel
    // "Define Artifact" template-detection domain, extracted into an L4 store
    // (REFACTOR.md — analysis-domain slice).
    @State var template: ArtifactTemplateViewModel
    // Wavelet artifact explorer domain, extracted into an L4 store.
    @State var waveletExplorer: WaveletArtifactExplorerViewModel
    // ICA decomposition + component removal, extracted into an L4 store. See
    // REFACTOR.md slice 6.
    @State var ica: ICAViewModel
    // PSA epoching / averaging + averaged-data display, extracted into an L4
    // store. See REFACTOR.md slice 4.
    @State var epoching: EpochingViewModel
    // Moved to `EpochingViewModel` so the shared invalidation cascade can reach
    // them headlessly; forwarders keep existing call sites unchanged.
    var segmentedEpochSignal: MFFSignalData? {
        get { epoching.segmentedEpochSignal }
        nonmutating set { epoching.segmentedEpochSignal = newValue }
    }
    var segmentedEpochSegments: [EpochSegment] {
        get { epoching.segmentedEpochSegments }
        nonmutating set { epoching.segmentedEpochSegments = newValue }
    }
    // Single Trial Analysis domain, extracted into an L4 store — reads the
    // raw per-trial epochs above (segmentedEpochSignal/segmentedEpochSegments),
    // not epoching's averaged output.
    @State var singleTrial: SingleTrialAnalysisViewModel
    @State var eegAnalysis: EEGAnalysisViewModel

    // Band-pass / notch filtering (applied to the active base signal).
    /// Filtering domain (band-pass / line-noise / average-reference), extracted
    /// into an L4 store. See REFACTOR.md.
    @State var filter: FilterViewModel
    @State var showsFilterPopover = false
    @State var showsFilterLineNoiseOptions = false
    // Wavelet artifact reduction pipeline stage.
    // Wavelet-reduction domain, extracted into an L4 store. See REFACTOR.md slice 3.
    @State var wavelet: WaveletReductionViewModel
    // B4: status and physio display state now live on `recordingStore.status` /
    // `recordingStore.physio`.
    var channelStatusIsError: Bool {
        get { recordingStore.status.channelStatusIsError }
        nonmutating set { recordingStore.status.channelStatusIsError = newValue }
    }
    // Scrollable status history (newest first), shown when the status area is clicked.
    private var statusHistory: [StatusHistoryEntry] {
        get { recordingStore.status.statusHistory }
        nonmutating set { recordingStore.status.statusHistory = newValue }
    }
    private var lastRecordedStatusBySource: [String: String] {
        get { recordingStore.status.lastRecordedStatusBySource }
        nonmutating set { recordingStore.status.lastRecordedStatusBySource = newValue }
    }
    // Physio (PNS) channel display. Shown by default when present; pinned below
    // the EEG channels and synced to the EEG time axis.
    var showsPhysioChannels: Bool {
        get { recordingStore.physio.showsPhysioChannels }
        nonmutating set { recordingStore.physio.showsPhysioChannels = newValue }
    }
    var physioRanges: [ClosedRange<Float>] {
        get { recordingStore.physio.ranges }
        nonmutating set { recordingStore.physio.ranges = newValue }
    }
    var physioScaleFactors: [Int: Double] {
        get { recordingStore.physio.scaleFactors }
        nonmutating set { recordingStore.physio.scaleFactors = newValue }
    }
    var physioMaxScaledChannels: Set<Int> {
        get { recordingStore.physio.maxScaledChannels }
        nonmutating set { recordingStore.physio.maxScaledChannels = newValue }
    }
    var physioFlippedPolarity: Set<Int> {
        get { recordingStore.physio.flippedPolarity }
        nonmutating set { recordingStore.physio.flippedPolarity = newValue }
    }
    /// User-assigned renames for physio channels (keyed by merged channel index).
    var physioChannelRenames: [Int: String] {
        get { recordingStore.physio.channelRenames }
        nonmutating set { recordingStore.physio.channelRenames = newValue }
    }
    /// Index of the channel currently being renamed (nil when no rename in progress).
    var physioRenameTarget: Int? {
        get { recordingStore.physio.renameTarget }
        nonmutating set { recordingStore.physio.renameTarget = newValue }
    }
    /// Synthetic PNS channels created from ICA components.
    var syntheticPNSChannels: [SyntheticPNSChannel] {
        get { recordingStore.physio.syntheticPNSChannels }
        nonmutating set { recordingStore.physio.syntheticPNSChannels = newValue }
    }


    // MRI gradient-artifact removal domain (AAS / FASTR / FARM / Moosmann),
    // extracted into an L4 store. See REFACTOR.md slice 2.
    @State var gradient: GradientViewModel
    @State var replay = ReplayController()

    // Per-channel state, shared with the menu-bar Channels commands.
    var channels: ChannelModel { recordingStore.channels }
    /// Serializes major processing operations (filter, gradient, ICA, wavelet
    /// reduction, artifact cleaning, channel/segment health, PSA, BCG, EEG
    /// analysis) so at most one runs at a time even if triggered back to
    /// back. Lives on `RecordingStore` (not owned here) so standalone VMs
    /// that only hold `store` can reach it too.
    var processingQueue: ProcessingQueue { recordingStore.processingQueue }
    @State var electrodeGeometry: ElectrodeGeometry?
    var channelStatusMessage: String? {
        get { recordingStore.status.channelStatusMessage }
        nonmutating set { recordingStore.status.channelStatusMessage = newValue }
    }
    @State private var channelLabelMetricsExportRequest = 0
    // Channel-health coordination, extracted into an L4 store (REFACTOR.md).
    @State var chanHealth: ChannelHealthViewModel
    // Not `private`: read by the single sheet host in `WaveformSheetHost.swift` (B3).
    @State var showsChannelGoodnessSettings = false
    @State private var channelGoodnessSettingsRequest = 0
    // Segment-health domain, extracted into an L4 store (REFACTOR.md).
    @State var segHealth: SegmentHealthViewModel
    @State private var resetToOriginalRequest = 0
    @State private var mffExportRequest = 0
    @State private var copyProcessingRequest = 0
    @State private var datasetInfoRequest = 0
    // Not `private`: read by the single sheet host in `WaveformSheetHost.swift` (B3).
    @State var showsDatasetInfo = false
    @State private var importPhysioRequest = 0
    @State var showsPhysioImportSheet = false
    /// Set to scroll the channel list to that row (e.g. from a topomap/butterfly
    /// click); `.scrollPosition(id:)` on the vertical channel ScrollView consumes it.
    var scrollToChannelRequest: Int? {
        get { recordingStore.selection.scrollToChannelRequest }
        nonmutating set { recordingStore.selection.scrollToChannelRequest = newValue }
    }
    @State var showsChannelInspector = false
    @State var channelInspectorSelection: ChannelInspectorSelection = .channel(0)
    @State var channelInspectorOverlayEnabled = true
    @State var channelInspectorShowsStandardError = false
    @State var showsPSASummaryBubble = false
    @State var showsPerEpochBadChannelsBubble = false
    @State var showsAverageSNRHelp = false
    @State var averageSNRSortOrder: [KeyPathComparator<AverageSNRRow>] = [
        KeyPathComparator(\AverageSNRRow.category, order: .forward)
    ]
    // B4: category-group popover state now lives on `recordingStore.events`.
    var categoryGroupSelectedCodes: Set<String> {
        get { recordingStore.events.categoryGroupSelectedCodes }
        nonmutating set { recordingStore.events.categoryGroupSelectedCodes = newValue }
    }
    var showsCategoryGroupPopover: Bool {
        get { recordingStore.events.showsCategoryGroupPopover }
        nonmutating set { recordingStore.events.showsCategoryGroupPopover = newValue }
    }
    var categoryGroupMode: CategoryGroupMode {
        get { recordingStore.events.categoryGroupMode }
        nonmutating set { recordingStore.events.categoryGroupMode = newValue }
    }
    var categoryGroupName: String {
        get { recordingStore.events.categoryGroupName }
        nonmutating set { recordingStore.events.categoryGroupName = newValue }
    }
    var categoryRegexSourceCode: String {
        get { recordingStore.events.categoryRegexSourceCode }
        nonmutating set { recordingStore.events.categoryRegexSourceCode = newValue }
    }
    var categoryRegexPattern: String {
        get { recordingStore.events.categoryRegexPattern }
        nonmutating set { recordingStore.events.categoryRegexPattern = newValue }
    }
    var categoryRegexMatchField: CategoryRegexMatchField {
        get { recordingStore.events.categoryRegexMatchField }
        nonmutating set { recordingStore.events.categoryRegexMatchField = newValue }
    }
    var physioRenameText: String {
        get { recordingStore.physio.renameText }
        nonmutating set { recordingStore.physio.renameText = newValue }
    }
    var showsStatusHistory: Bool {
        get { recordingStore.status.showsStatusHistory }
        nonmutating set { recordingStore.status.showsStatusHistory = newValue }
    }
    var showsRecentProcessingHistory: Bool {
        get { recordingStore.status.showsRecentProcessingHistory }
        nonmutating set { recordingStore.status.showsRecentProcessingHistory = newValue }
    }
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
    @State var snrTask: Task<Void, Never>?
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
    let rowSpacing: CGFloat = 12
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
            deleteAllRequest: $template.deleteAllRequest,
            showsAppliedCorrection: Binding(
                get: { artifactVM.cleaningIsEnabled },
                set: { setArtifactCleaningEnabled($0) }
            ),
            appliedCorrectionAvailable: artifactVM.cleanedSignal != nil
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
            isAvailable: segmentHealthIsAvailable,
            isAnalyzing: segHealth.isAnalyzing,
            progress: segHealth.progress
        )
    }

    private var segmentHealthIsAvailable: Bool {
        !epoching.isAveraged
            && epoching.epochedSignal?.isAveraged != true
            && recording.signal?.isAveraged != true
    }

    private var physioViewControls: PhysioViewControls {
        let realCount = recording.pnsSignal?.numberOfChannels ?? 0
        let total = realCount + syntheticPNSChannels.count
        return PhysioViewControls(
            showsPhysio: binding(recordingStore.physio, \.showsPhysioChannels),
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
    init(
        recording: MFFRecording,
        userMarkers: [WaveformUserMarkerSignature],
        forkSeed: PendingWindowForks.Payload? = nil
    ) {
        self.recording = recording
        self.userMarkers = userMarkers
        self.forkSeed = forkSeed
        let store = RecordingStore()
        _recordingStore = State(initialValue: store)
        _ecg = State(wrappedValue: ECGDetectionViewModel(store: store))
        _bcg = State(wrappedValue: BCGDetectionViewModel(store: store))
        _artifactVM = State(wrappedValue: ArtifactViewModel(store: store))
        _template = State(wrappedValue: ArtifactTemplateViewModel(store: store))
        _ica = State(wrappedValue: ICAViewModel(store: store))
        _epoching = State(wrappedValue: EpochingViewModel(store: store))
        _singleTrial = State(wrappedValue: SingleTrialAnalysisViewModel(store: store))
        _eegAnalysis = State(wrappedValue: EEGAnalysisViewModel(store: store))
        _filter = State(wrappedValue: FilterViewModel(store: store))
        _wavelet = State(wrappedValue: WaveletReductionViewModel(store: store))
        _gradient = State(wrappedValue: GradientViewModel(store: store))
        _chanHealth = State(wrappedValue: ChannelHealthViewModel(store: store))
        _segHealth = State(wrappedValue: SegmentHealthViewModel(store: store))
        _waveletExplorer = State(wrappedValue: WaveletArtifactExplorerViewModel(store: store))
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
                // `content(...)` is called from exactly ONE call site — not
                // branched on `interpolationSnapshot.isEmpty` — because an
                // if/else here would be a structural-identity change the
                // moment the user interpolates their first channel: SwiftUI
                // would tear down and remount the whole subtree, causing its
                // `.task(id: channelHealthSignature(...))` below to fire as a
                // fresh mount (wiping ALL channel health results) while its
                // `.onChange(of: channels.interpolated.keys.sorted())` (meant
                // to selectively patch just the interpolated channel) would
                // NOT fire, since a fresh mount has no prior value to diff
                // against. See recomputeChannelHealthForInterpolation.
                let interpolationSnapshot = channels.interpolationSnapshot
                let resolutionKey: InterpolatedSignalResolver.Key? = interpolationSnapshot.isEmpty
                    ? nil
                    : recordingStore.interpolatedSignalResolver.key(for: waveletStage, snapshot: interpolationSnapshot)
                let continuousSignal: MFFSignalData = {
                    guard let resolutionKey else { return waveletStage }
                    return recordingStore.interpolatedSignalResolver.cachedSignal(for: resolutionKey)
                        ?? recordingStore.interpolatedSignalResolver.displaySignal(
                            whileResolving: resolutionKey,
                            fallback: waveletStage
                        )
                }()
                content(
                    for: epoching.epochedSignal ?? continuousSignal,
                    base: base,
                    cleaningBase: preArtifact,
                    waveletInput: processed,
                    continuousSignal: continuousSignal
                )
                .task(id: resolutionKey) {
                    guard let resolutionKey else { return }
                    if recordingStore.interpolatedSignalResolver.cachedSignal(for: resolutionKey) == nil {
                        await recordingStore.interpolatedSignalResolver.resolve(
                            signal: waveletStage,
                            snapshot: interpolationSnapshot
                        )
                    }
                }
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

    /// Runs `action` after the current SwiftUI update finishes.
    ///
    /// Menu commands arrive here as `@State` request counters, so their
    /// `.onChange` handlers run *inside* SwiftUI's update — which AppKit performs
    /// within a CoreAnimation transaction commit. `NSSavePanel`/`NSOpenPanel`
    /// refuse to run there:
    ///
    ///     Suppressing invocation of -[NSApplication runModalForWindow:].
    ///     … cannot run inside a transaction begin/commit pair …
    ///
    /// The panel silently never appears — intermittently, because it depends on
    /// whether the command lands mid-transaction. Hopping to the next main-queue
    /// turn guarantees the commit has finished. (Same reason the ICA sheet is
    /// opened via `DispatchQueue.main.async` in `content(for:)`.)
    private func afterCurrentTransaction(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    private func installRequestHandlers(on content: some View) -> some View {
        content
        .onChange(of: resetToOriginalRequest) { _, _ in
            resetToOriginalData()
        }
        .onChange(of: mffExportRequest) { _, _ in
            afterCurrentTransaction { exportCurrentSignalToMFF() }
        }
        .onChange(of: copyProcessingRequest) { _, _ in
            afterCurrentTransaction { importProcessingFromOtherFile() }
        }
        .onChange(of: datasetInfoRequest) { _, _ in
            showsDatasetInfo = true
        }
        .onChange(of: importPhysioRequest) { _, _ in
            showsPhysioImportSheet = true
        }
        .onChange(of: channelLabelMetricsExportRequest) { _, _ in
            afterCurrentTransaction { saveChannelLabelMetricsJSON() }
        }
        .onChange(of: segHealth.detailsRequest) { _, _ in
            guard segmentHealthIsAvailable else {
                segHealth.clearAnalysis(hide: true, clearLabels: false)
                return
            }
            segHealth.shows = true
            segHealth.showsDetails = true
        }
        .onChange(of: chanHealth.detailsRequest) { _, _ in
            chanHealth.showsDetails = true
        }
        .onChange(of: channelGoodnessSettingsRequest) { _, _ in
            showsChannelGoodnessSettings = true
        }
        .onChange(of: channels.interpolationRevision) { _, _ in
            // Once the final interpolation is removed the resolver is bypassed;
            // release its retained derived signal instead of keeping it for the
            // lifetime of the recording window.
            if channels.interpolated.isEmpty {
                recordingStore.interpolatedSignalResolver.reset()
            }
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
            installOptionKeyMonitor()
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
        publishChannelSetContext()
        seedPhysioPolarityDefaultsIfNeeded()
        seedDisplayScaleDefaults()
        seedProcessingHistoryFromDisk()
        adoptOnDiskEpochsIfPresent()
        applyForkSeed()
        autoStartBatchIfNeeded()
    }

    /// Publishes this window's electrode layout to `ChannelSetStore`, the
    /// single-instance Channel Sets editor's data source.
    ///
    /// Two call sites, both direct writes rather than routed through
    /// `@FocusedValue`/`.commands` — a `ChannelSetFocusMirror` living inside
    /// `.commands` was tried first (2026-08-15) and found broken by manual
    /// test: the editor read "no sensor layout available" even with a
    /// recording open, most likely because an invisible, zero-size view
    /// mounted purely for a `.onChange` side effect does not reliably get
    /// re-evaluated the way a real, visible command button does — unverified
    /// beyond that it did not work. This is deliberately the older, plainer
    /// mechanism instead: call sites write directly, on load
    /// (`loadRecordingIfNeeded`), on a channel-role edit
    /// (`finishChannelRoleEdit`), and on this window becoming main
    /// (`WindowAccessor`'s `onBecomeMain`, wired from `ContentView`) — the
    /// last one is what makes the editor follow *focus* rather than *load
    /// order* across multiple recording windows, which is the actual
    /// multi-window requirement; the first two are what make it correct
    /// within one window regardless of focus.
    func publishChannelSetContext() {
        ChannelSetStore.shared.activeSensorLayout = recording.sensorLayout
        ChannelSetStore.shared.activeChannelNames = recording.signal?.channelNames
        ChannelSetStore.shared.activeIsMFFSource = recording.packageURL.pathExtension.lowercased() == "mff"
    }

    /// Applies a fork's captured state on top of ordinary load-time seeding —
    /// see `PendingWindowForks` and REWIND.md "Forking to a new window".
    /// Deliberately runs *after* `seedProcessingHistoryFromDisk()` and
    /// `adoptOnDiskEpochsIfPresent()`, not instead of them: this window opened
    /// the same file fresh, so that ordinary seeding runs and is harmlessly
    /// redundant (same eva.xml), and this call is what makes the fork's
    /// full — possibly live-edited — history and live pipeline state win over
    /// it rather than a race depending on call order.
    ///
    /// `PipelineSnapshotting.restore` is the exact call ordinary history
    /// navigation already uses — a fork is "restore this snapshot," just into
    /// a freshly-constructed set of view models instead of this window's own.
    private func applyForkSeed() {
        guard let forkSeed else { return }
        recordingStore.processingHistory.seedFork(forkSeed.historySeed)
        recordingStore.channels = forkSeed.channels
        PipelineSnapshotting.restore(
            forkSeed.liveSnapshot,
            store: recordingStore, gradient: gradient, bcg: bcg, ica: ica,
            filter: filter, wavelet: wavelet, artifactVM: artifactVM, template: template,
            segHealth: segHealth, epoching: epoching
        )
    }

    /// Seeds the history rail with what `eva.xml` says already happened to this
    /// file, so a processed recording does not read as "raw" the moment it
    /// opens.
    ///
    /// `currentProcessingChainSignature`-driven recording (`recordProcessingHistory`)
    /// only ever sees *this session's* pipeline view models, which start empty —
    /// it has no way to know a previously-applied filter or interpolation is
    /// already baked into the loaded samples. The package's own `eva.xml` does
    /// know, so this reads it back with the matching reader
    /// (`EVAProcessingScriptXML.read`) and hands the steps to
    /// `RecordingHistoryModel.seedOnDiskPrefix`, which every future `record()`
    /// call folds in ahead of whatever this session does. See that method for
    /// why the nodes it creates are shown but not navigable.
    ///
    /// Only reads an ICA payload digest, matching what the *live* path
    /// disambiguates (`currentPayloadDigests()`) — artifact cleaning's step
    /// parameters are already sufficient on their own, live or on disk.
    private func seedProcessingHistoryFromDisk() {
        guard let script = EVAProcessingScriptXML.read(fromPackage: recording.packageURL),
              !script.steps.isEmpty else { return }
        var payloadDigests: [EVAProcessingStep.Operation: String] = [:]
        if script.steps.contains(where: { $0.operation == .icaClean }),
           let payload = ICAReplayPayload.read(fromPackage: recording.packageURL) {
            payloadDigests[.icaClean] = EVAHistory.digest([
                payload.replayIdentityBytes.base64EncodedString()
            ])
        }
        recordingStore.processingHistory.seedOnDiskPrefix(
            recordingKey: recording.packageName,
            steps: script.steps,
            payloadDigests: payloadDigests
        )
        // The tip is what is actually on screen right now — the loaded signal,
        // with every pipeline view model still empty — so it is free to mark
        // instant. Matches what `recordProcessingHistory()` does after every
        // live `record()`: capture immediately follows adopt.
        recordingStore.processingHistory.storeSnapshot(capturePipelineSnapshot())
    }

    /// Puts the newly-opened recording at the preferred sensitivity and sweep
    /// speed from Settings.
    ///
    /// Converted here rather than stored as raw scales, because the sweep
    /// conversion needs *this file's* sampling rate: the decimation stride is an
    /// integer, so a stored `timeScale` would mean a different physical speed in
    /// a 250 Hz file than in a 1000 Hz one. See
    /// `WaveformScaleUnits.pointsPerSecond`.
    ///
    /// Only on load, never on a settings change — the preference is a starting
    /// point, and yanking the view out from under someone who has since adjusted
    /// the sliders would be worse than useless. Clamped to the sliders' ranges so
    /// a preference outside them lands at the edge rather than somewhere the
    /// controls cannot represent.
    private func seedDisplayScaleDefaults() {
        guard !hasSeededDisplayScale else { return }
        hasSeededDisplayScale = true
        amplitudeScale = clampedAmplitudeScale(
            WaveformScaleUnits.amplitudeScale(
                forMicrovoltsPerMillimeter: defaultSensitivityPreference,
                rowHeight: channelRowHeight
            )
        )
        timeScale = clampedTimeScale(
            WaveformScaleUnits.timeScale(
                forMillimetersPerSecond: defaultSweepPreference,
                samplingRate: scaleUnitsSamplingRate
            )
        )
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
        guard epoching.epochedSignal == nil else { return }
        applyFileTypeInterpretation()
    }

    /// The file kind EVA is working with: the user's session override if they set
    /// one in Dataset Info, otherwise what the reader detected.
    var effectiveFileType: MFFFileType? {
        recordingStore.fileTypeOverride ?? recording.signal?.detectedFileType
    }

    /// Sets (or clears, with `nil`) the session override and re-interprets the
    /// recording accordingly.
    func setFileTypeOverride(_ type: MFFFileType?) {
        recordingStore.fileTypeOverride = type
        applyFileTypeInterpretation()
    }

    /// Brings the epoch state in line with `effectiveFileType`.
    ///
    /// Used both on load and when the user corrects the type by hand, so the
    /// override is a real escape hatch rather than a relabelling: choosing
    /// "Averaged" on a package EVA misread actually enables the averaged
    /// workspace, butterfly plots, and the rest.
    func applyFileTypeInterpretation() {
        guard let signal = recording.signal else { return }
        let type = effectiveFileType ?? .continuous

        guard type != .continuous else {
            // Treat as a continuous strip: drop any adopted on-disk epochs.
            epoching.epochedSignal = nil
            epoching.epochSegments = []
            epoching.isAveraged = false
            segmentedEpochSignal = nil
            segmentedEpochSegments = []
            epoching.statusMessage = nil
            return
        }

        guard !signal.epochSegments.isEmpty else {
            // Nothing on disk to adopt — say so rather than silently doing nothing.
            epoching.statusMessage = "This package has no epoch/category structure to read as \(type.displayName.lowercased())."
            return
        }

        let averaged = (type == .averaged || type == .grandAverage)
        segmentedEpochSignal = signal
        segmentedEpochSegments = signal.epochSegments
        epoching.epochedSignal = signal
        epoching.epochSegments = signal.epochSegments
        epoching.isAveraged = averaged
        epoching.statusMessage = averaged
            ? "Loaded \(signal.epochSegments.count) averaged categories"
            : "Loaded \(signal.epochSegments.count) epochs"
    }

    /// Markers the user has created for *this* recording, surfaced as events.
    /// `userMarkers` is already filtered to this recording by the container.
    var userMarkerEvents: [MFFEvent] {
        userMarkers.map { marker in
            MFFEvent(
                id: "user-marker-\(marker.idHash)",
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
            userMarkers: userMarkers,
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
                let overlapWindowSeconds = overlayWindowSeconds(for: event)
                return epoching.epochSegments.compactMap { segment in
                    EpochedOverlayEventMapper.map(
                        event,
                        into: segment,
                        samplingRate: signal.samplingRate,
                        overlapWindowSeconds: overlapWindowSeconds
                    )
                }
            }
            .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    /// Matches Segment Health's artifact windows so every epoch reported as
    /// containing a defined/detected artifact also receives a visible flag.
    private func overlayWindowSeconds(for event: MFFEvent) -> Double? {
        let defaultWindowSeconds = 0.25
        if let artifact = template.definedArtifacts.first(where: { artifact in
            artifact.events.contains { $0.id == event.id }
        }) {
            return max(artifact.windowSizeSeconds, defaultWindowSeconds)
        }
        if artifactVM.events.contains(where: { $0.id == event.id }) {
            return defaultWindowSeconds
        }
        return nil
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

            workspaceContent(
                displayMode: displayMode,
                signal: signal,
                events: events,
                eventsKey: eventCacheKey,
                isShowingEpochs: isShowingEpochs
            )
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
        // REWIND work item 1: fold the chain into the history tree when it moves.
        // Keyed on a signature of stage outputs rather than run per body pass —
        // see `WaveformHistoryRail.swift` for why that is both cheap and correct.
        .onChange(of: processingChainSignature, initial: true) { _, _ in
            recordProcessingHistory()
        }
        // B3: one `.sheet(item:)` in place of 18 chained `.sheet(isPresented:)`.
        // Presentation is still driven by the same per-VM booleans — they are
        // derived into `activeSheet` rather than each owning a modifier. See
        // `WaveformSheetHost.swift` for why the chain was the measured cost.
        .sheet(item: activeSheetBinding) { sheet in
            sheetContent(
                sheet,
                base: base,
                cleaningBase: cleaningBase,
                waveletInput: waveletInput,
                continuousSignal: continuousSignal
            )
        }
        .overlay(alignment: .top) { replayBanner() }
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
    private func waveformWorkspace(
        for signal: MFFSignalData,
        events: [MFFEvent],
        eventsKey: WaveformDisplayedEventsCache.Key,
        isShowingEpochs: Bool
    ) -> some View {
        HStack(spacing: 0) {
            // The processing history is *not* a panel here. It lives in the
            // status popover's History tab (`ProcessingStatusPopover.swift`), so
            // it costs no waveform width — see that file for the reasoning.
            waveformArea(for: signal, events: events, isShowingEpochs: isShowingEpochs)

            if showsEventsPanel {
                Divider()
                // B2/C1: a standalone `Equatable` view, so unrelated state
                // changes (drag ticks, progress ticks) no longer re-run this
                // body — which is why its derived lists need no cache.
                EventsPanelView(
                    events: events,
                    eventsKey: eventsKey,
                    selectedEventCodes: selectedEventCodes,
                    selectedEventID: selectedEventID,
                    onSelectEvent: { jumpToEvent($0, in: signal) },
                    onToggleCode: { toggleEventCode($0) },
                    onClearCodes: { selectedEventCodes.removeAll() },
                    onClose: { showsEventsPanel = false }
                )
                .equatable()
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
                TopomapPanelView(
                    layout: recording.sensorLayout,
                    values: topomapValues(at: topomapSample, in: signal),
                    timeSeconds: signal.samplingRate > 0 ? Double(topomapSample) / signal.samplingRate : 0,
                    channelName: { eegChannelDisplayName(index: $0, signal: signal) },
                    onTapChannel: { openChannelInspector(channel: $0) },
                    onClose: { self.topomapSample = nil }
                )
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
                showsFilterPopover.toggle()
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
            .popover(isPresented: $showsFilterPopover, arrowEdge: .bottom) {
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
                scaleReadout(WaveformScaleUnits.sensitivityLabel(
                    amplitudeScale: amplitudeScale, rowHeight: channelRowHeight
                ))
            }

            if showsTimeScale {
                HStack(spacing: 8) {
                    Text("Time Scale")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: Binding(get: { timeScale }, set: { timeScale = $0 }), in: 0.2...8, step: 0.1)
                        .frame(width: 170)
                    scaleReadout(WaveformScaleUnits.sweepLabel(
                        timeScale: timeScale, samplingRate: scaleUnitsSamplingRate
                    ))
                }
            }
        }
        // Once for the whole control. Both readouts open the same sheet, and two
        // `.popover` modifiers sharing one binding would each try to present it.
        .popover(isPresented: $showsScaleUnitsPopover, arrowEdge: .bottom) {
            scaleUnitsPopover()
        }
    }

    /// The readout beside a scale slider.
    ///
    /// One line, in physical units only, **left**-justified in a fixed frame —
    /// which is what makes the amplitude and time rows line up with each other.
    /// The first version stacked the raw value above the physical one and
    /// right-aligned each in a differently-sized frame (86 pt and 64 pt), so the
    /// two rows could not agree on an edge in either direction. The raw
    /// `amplitudeScale` and `timeScale` numbers moved into the popover, where
    /// they are still available but are not the headline.
    @ViewBuilder
    private func scaleReadout(_ label: String) -> some View {
        Button {
            showsScaleUnitsPopover = true
        } label: {
            Text(label)
                .font(.caption.monospacedDigit())
                .frame(width: scaleReadoutWidth, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to type an exact sensitivity or sweep speed.")
    }

    /// Wide enough for the longest reading either row produces — "9.6 µV/mm" —
    /// so neither truncates and both share one left edge.
    private var scaleReadoutWidth: CGFloat { 80 }

    /// Typed entry in physical units, plus the clinical preset.
    ///
    /// The units are **nominal** — 72 points to the inch — because the true size
    /// of a point needs the display's physical dimensions, which macOS reports
    /// from EDID and which is wrong or missing on plenty of external monitors.
    /// Saying so in the popover is the point: a figure stated with authority and
    /// quietly false would be worse than no figure at all. See
    /// `WaveformScaleUnits`.
    @ViewBuilder
    private func scaleUnitsPopover() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Display Scale")
                .font(.headline)

            Text("±\(formatAmplitudeScale(amplitudeScale)) µV per half row  ·  "
                 + String(format: "%.1f×", timeScale) + " time")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Sensitivity").font(.caption)
                    TextField("", text: $sensitivityEntry)
                        .frame(width: 64)
                        .onSubmit(applySensitivityEntry)
                    Text("µV/mm").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Sweep").font(.caption)
                    TextField("", text: $sweepEntry)
                        .frame(width: 64)
                        .onSubmit(applySweepEntry)
                    Text("mm/s").font(.caption).foregroundStyle(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Apply") {
                    applySensitivityEntry()
                    applySweepEntry()
                }
                .keyboardShortcut(.defaultAction)
                Button("Clinical") {
                    amplitudeScale = clampedAmplitudeScale(
                        WaveformScaleUnits.amplitudeScale(
                            forMicrovoltsPerMillimeter: WaveformScaleUnits.clinicalMicrovoltsPerMillimeter,
                            rowHeight: channelRowHeight
                        )
                    )
                    timeScale = clampedTimeScale(
                        WaveformScaleUnits.timeScale(
                            forMillimetersPerSecond: WaveformScaleUnits.clinicalMillimetersPerSecond,
                            samplingRate: scaleUnitsSamplingRate
                        )
                    )
                    syncScaleUnitEntries()
                }
                .help("7 µV/mm and 30 mm/s — the standard clinical review settings.")
            }

            Divider()

            Text("Nominal millimetres, assuming 72 points per inch. EVA does not "
                 + "yet measure this display, so on-screen size may differ. Exported "
                 + "PDFs are exact at 100%.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
        }
        .padding(14)
        .onAppear(perform: syncScaleUnitEntries)
    }

    /// The loaded file's rate, because the sweep speed genuinely depends on it —
    /// see `WaveformScaleUnits.pointsPerSecond`. Falls back to the rate the
    /// stride was designed around so an empty window still shows a sane number.
    private var scaleUnitsSamplingRate: Double {
        let rate = recording.signal?.samplingRate ?? 0
        return rate > 0 ? rate : referenceDisplaySampleRate
    }

    private func syncScaleUnitEntries() {
        sensitivityEntry = WaveformScaleUnits.format(
            WaveformScaleUnits.microvoltsPerMillimeter(
                amplitudeScale: amplitudeScale, rowHeight: channelRowHeight
            )
        )
        sweepEntry = WaveformScaleUnits.format(
            WaveformScaleUnits.millimetersPerSecond(
                timeScale: timeScale, samplingRate: scaleUnitsSamplingRate
            )
        )
    }

    private func applySensitivityEntry() {
        guard let value = Double(sensitivityEntry), value > 0 else {
            syncScaleUnitEntries()
            return
        }
        amplitudeScale = clampedAmplitudeScale(
            WaveformScaleUnits.amplitudeScale(
                forMicrovoltsPerMillimeter: value, rowHeight: channelRowHeight
            )
        )
        syncScaleUnitEntries()
    }

    private func applySweepEntry() {
        guard let value = Double(sweepEntry), value > 0 else {
            syncScaleUnitEntries()
            return
        }
        timeScale = clampedTimeScale(
            WaveformScaleUnits.timeScale(
                forMillimetersPerSecond: value, samplingRate: scaleUnitsSamplingRate
            )
        )
        syncScaleUnitEntries()
    }

    /// Both clamps exist so a typed value out of the slider's range lands at the
    /// edge rather than silently doing nothing — and so the readout that follows
    /// reports what was actually applied rather than what was asked for.
    private func clampedAmplitudeScale(_ value: Double) -> Double {
        min(max(value, amplitudeScaleBounds.lowerBound), amplitudeScaleBounds.upperBound)
    }

    private func clampedTimeScale(_ value: Double) -> Double {
        min(max(value, 0.2), 8)
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

                Text(recordingToolbarSummary(for: signal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 300, idealWidth: 440, maxWidth: 480, alignment: .leading)
            .layoutPriority(1)

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

    // `StatusHistoryEntry` moved to `WaveformUIModels.swift` (B4), beside
    // `RecordingStatusModel`, which now owns the history.

    /// Messages currently worth surfacing, gathered from each feature's status.
    private var activeLogMessages: [StatusLogLine] {
        var lines: [StatusLogLine] = []
        if !gradient.isProcessing, let mriStatus = gradient.statusMessage {
            lines.append(StatusLogLine(source: "MRI", text: mriStatus, isError: gradient.statusIsError))
        }
        if !filter.isFiltering, let filterStatusMessage = filter.statusMessage {
            lines.append(StatusLogLine(source: "Filter", text: filterStatusMessage, isError: filter.statusIsError))
        }
        if let psaStatus = epoching.statusMessage {
            lines.append(StatusLogLine(source: "Segment", text: psaStatus, isError: false))
        }
        if let channelStatusMessage {
            lines.append(StatusLogLine(source: "Channel", text: channelStatusMessage, isError: channelStatusIsError))
        }
        if let chanStatus = chanHealth.statusMessage {
            lines.append(StatusLogLine(source: "Channel Health", text: chanStatus, isError: false))
        }
        if let segStatus = segHealth.statusMessage {
            lines.append(StatusLogLine(source: "Segment Health", text: segStatus, isError: false))
        }
        if let cleaningStatus = artifactVM.cleaningStatusMessage {
            lines.append(StatusLogLine(source: "Artifact", text: cleaningStatus, isError: false))
        }
        if let explorerStatus = waveletExplorer.statusMessage {
            lines.append(StatusLogLine(source: "Wavelet", text: explorerStatus, isError: false))
        }
        if let waveletStatus = wavelet.statusMessage {
            lines.append(StatusLogLine(source: "Wavelet Reduction", text: waveletStatus, isError: false))
        }
        if let mffExportStatusMessage {
            lines.append(StatusLogLine(source: "Export", text: mffExportStatusMessage, isError: false))
        }
        return lines
    }

    /// Appends any newly-changed status messages to the scrollable history.
    private func recordStatusHistory(_ lines: [StatusLogLine]) {
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

    /// One source instead of reaching into each view model by name, so a new
    /// long-running stage appears here by reporting progress rather than by
    /// editing this property. See `OperationProgressCenter`.
    private var activeOperationProgress: [OperationProgress] {
        recordingStore.operationProgress.operations
    }

    /// Flattens the eight view models the status area reads into one comparable
    /// value, so `StatusLogView` re-renders only when the displayed status
    /// changes. See `StatusLogView.swift` for why this boundary exists.
    private var statusLogSnapshot: StatusLogSnapshot {
        var snapshot = StatusLogSnapshot()

        // Rich progress comes from the one center; the fallback bars below are
        // for stages that only report a bare fraction.
        snapshot.operations = recordingStore.operationProgress.operations
        if gradient.isProcessing, gradient.operationProgress == nil {
            snapshot.progressRows.append(StatusLogProgressRow(label: "MRI", value: gradient.progress))
        }
        if filter.isFiltering, filter.operationProgress == nil {
            snapshot.progressRows.append(StatusLogProgressRow(label: "Filter", value: filter.progress))
        }
        if let cleaningProgress = artifactVM.cleaningProgress {
            snapshot.progressRows.append(StatusLogProgressRow(label: "Artifact", value: cleaningProgress.fraction))
        }
        if waveletExplorer.isRunning {
            snapshot.progressRows.append(StatusLogProgressRow(label: "Wavelet", value: waveletExplorer.progress))
        }
        if wavelet.isRunning {
            snapshot.progressRows.append(StatusLogProgressRow(label: "Reduction", value: wavelet.progress))
        }
        if channels.isAnalyzingHealth, chanHealth.operationProgress == nil {
            snapshot.progressRows.append(StatusLogProgressRow(label: "Health", value: channels.healthProgress))
        }
        if segHealth.isAnalyzing {
            snapshot.progressRows.append(StatusLogProgressRow(label: "Segments", value: segHealth.progress))
        }
        if isExportingMFF {
            snapshot.progressRows.append(StatusLogProgressRow(label: "MFF", value: 0.5))
        }

        snapshot.messages = activeLogMessages
        return snapshot
    }

    /// Consolidated status/progress area shown at the far right of the toolbar,
    /// so individual buttons no longer push inline messages into the layout.
    func statusLog() -> some View {
        StatusLogView(
            snapshot: statusLogSnapshot,
            onActivate: {
                // Open on whichever tab answers the question you probably have:
                // if something is running, that; otherwise the tree. Preserves
                // what the old two-popover switch did, without making the other
                // half unreachable — which is what it used to do.
                recordingStore.status.statusPopoverTab =
                    activeOperationProgress.isEmpty ? .history : .queue
                showsStatusHistory = true
            }
        )
        .equatable()
        .onChange(of: activeLogMessages) { _, lines in
            recordStatusHistory(lines)
        }
        .popover(isPresented: binding(recordingStore.status, \.showsStatusHistory), arrowEdge: .bottom) {
            ProcessingStatusPopoverView(
                operations: activeOperationProgress,
                statusHistory: statusHistory,
                historyNodes: historyRailNodes,
                historyShortID: recordingStore.processingHistory.currentShortID,
                canStepBack: recordingStore.processingHistory.canStepBack,
                canStepForward: recordingStore.processingHistory.canStepForward,
                tab: binding(recordingStore.status, \.statusPopoverTab),
                onClearStatusHistory: { statusHistory.removeAll() },
                onSelectNode: { navigateHistory(to: EVAHistoryNodeID(hex: $0)) },
                onStepBack: { stepHistoryBack() },
                onStepForward: { stepHistoryForward() },
                onFork: { forkToNewWindow() }
            )
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
                    isOptionKeyPressed: isOptionKeyPressed,
                    timeMarkerStyle: waveformTimeMarkerStyle,
                    laneCount: eventLaneCount,
                    onSelectEvent: { event, color in
                        selectEventFromTrack(event, color: color, in: signal)
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
                        // Plain `VStack`, not `LazyVStack` — deliberate, and measured.
                        //
                        // This stack's scroll container is the *horizontal* ScrollView,
                        // so a lazy stack here re-runs its placement algorithm on every
                        // horizontal offset change while its laziness (vertical) is
                        // governed by the outer vertical ScrollView. In `trace3.trace`
                        // that was ~30% of the wheel-scroll window —
                        // `LazyStack.place` 10.6%, `resolveIndexAndPosition` 10.5%,
                        // `StackPlacement.measureBackwards`/`flushBackwards` 9.1% —
                        // and **absent entirely** from the click-drag window, which is
                        // what pinned it to scrolling rather than to rendering.
                        //
                        // The rows are `.equatable()`, so eagerly building them is cheap
                        // (`WaveformChannelRow` is 0.55% of the whole trace).
                        VStack(alignment: .leading, spacing: rowSpacing) {
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
                        .overlay(alignment: .topLeading) { waveformHoverOverlay() }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                updateWaveformHover(at: location, in: signal)
                            case .ended:
                                waveformHoverInfo = nil
                            }
                        }
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
            .scrollPosition(id: binding(recordingStore.selection, \.scrollToChannelRequest), anchor: .center)

            // Pinned physio (PNS) pane: always visible below the EEG channels
            // (separated by a gap), sharing the EEG time axis. Like the events
            // bar, it stays put while the EEG channels scroll vertically.
            if showsPhysioChannels,
               let pns = displayedPhysioSignal(), !pns.data.isEmpty {
                physioPane(pns, eegSamplingRate: signal.samplingRate)
            }

            if isOptionKeyPressed || selectedSampleRange != nil || isShowingEpochs {
                Divider()

                HStack(spacing: 16) {
                    if isOptionKeyPressed {
                        Text("Jump")
                            .font(.caption.weight(.semibold))
                            .frame(width: labelColumnWidth, alignment: .leading)

                        let maxOffset = horizontalMaximumOffset(for: plotWidth)
                        Slider(value: horizontalJumpBinding(plotWidth: plotWidth), in: 0...1)
                            .disabled(maxOffset <= geometryUpdateQuantum)
                            .help(maxOffset <= geometryUpdateQuantum
                                  ? "The entire waveform is already visible."
                                  : "Jump horizontally through the waveform.")
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

    @ViewBuilder
    private func workspaceContent(
        displayMode: EpochingViewModel.AveragedDisplayMode,
        signal: MFFSignalData,
        events: [MFFEvent],
        eventsKey: WaveformDisplayedEventsCache.Key,
        isShowingEpochs: Bool
    ) -> some View {
        if displayMode == .averages {
            averagesWorkspace(for: signal)
                .transition(.opacity)
        } else if displayMode == .trials {
            singleTrialAnalysisWorkspace()
                .transition(.opacity)
        } else {
            waveformWorkspace(
                for: signal,
                events: events,
                eventsKey: eventsKey,
                isShowingEpochs: isShowingEpochs
            )
            .transition(.opacity)
        }
    }

    // The topomap and events panels moved to `TopomapPanelView.swift` and
    // `EventsPanelView.swift` (B2).

    // MARK: - Channel interpolation

    /// Returns `signal` with any interpolated channels swapped in.
    func applyInterpolations(to signal: MFFSignalData) -> MFFSignalData {
        let snapshot = channels.interpolationSnapshot
        guard !snapshot.isEmpty else { return signal }
        return recordingStore.interpolatedSignalResolver.resolveSynchronously(
            signal: signal,
            snapshot: snapshot
        )
    }

    /// Replaces channel `index` with a spherical-spline interpolation from the
    /// good channels of the currently displayed signal.
    @discardableResult
    func interpolate(_ index: Int, in signal: MFFSignalData, updatesStatus: Bool = true) -> (message: String, isError: Bool) {
        if updatesStatus {
            channelStatusMessage = nil
            channelStatusIsError = false
        }
        guard let geometry = electrodeGeometry, geometry.positions[index] != nil else {
            let message = "No 3D coordinates for Ch \(index + 1); can't interpolate."
            if updatesStatus {
                channelStatusMessage = message
                channelStatusIsError = true
            }
            return (message, true)
        }

        let good = signal.data.indices.filter {
            $0 != index
                && !channels.bad.contains($0)
                && channels.interpolated[$0] == nil
                && geometry.positions[$0] != nil
        }

        guard let (indices, weights) = SphericalSpline.interpolationWeights(
            target: index,
            good: good,
            positions: geometry.positions
        ) else {
            let message = "Couldn't compute interpolation weights for Ch \(index + 1)."
            if updatesStatus {
                channelStatusMessage = message
                channelStatusIsError = true
            }
            return (message, true)
        }

        let length = signal.data[index].count
        var series = [Float](repeating: 0, count: length)
        for (channelIndex, weight) in zip(indices, weights) {
            let source = signal.data[channelIndex]
            guard source.count == length else { continue }
            // series += Float(weight) * source
            vDSP.add(multiplication: (source, Float(weight)), series, result: &series)
        }

        channels.setInterpolation(
            target: index,
            replacement: series,
            sourceIndices: indices,
            sourceWeights: weights.map(Float.init)
        )
        channels.bad.remove(index)
        let message = "Interpolated Ch \(index + 1) from \(indices.count) neighbors."
        if updatesStatus {
            channelStatusMessage = message
            channelStatusIsError = false
        }
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
        return (message, false)
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
        epoching.epochedSignal = epoched.replacingSamples(newData)
        return true
    }

    /// Interpolated channels are derived from the source data, so they go stale
    /// when the gradient/filter pipeline changes.
    /// Interactive entry point for the shared cascade. See `PipelineInvalidation`.
    func invalidateInterpolations() {
        PipelineInvalidation.interpolations(store: recordingStore)
    }

    private func tearDownRecordingSessionForClose() {
        recordingSessionID = UUID()
        cancelInFlightRecordingTasks()
        clearRecordingStateForClose()
        recording.tearDownForClose()
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
        removeOptionKeyMonitor()

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
        waveformHoverInfo = nil
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
        showsRecentProcessingHistory = false
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
        channels.removeAllInterpolations()
        recordingStore.interpolatedSignalResolver.reset()
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
        invalidateEpochsForSignalChange()

        // Force artifact overlays and downstream views to rebuild from the base.
        artifactVM.detectionRefreshToken += 1
    }

    /// Interactive entry point for the shared cascade. See `PipelineInvalidation`.
    func invalidateEpochsForSignalChange() {
        PipelineInvalidation.epochsAndDerived(
            epoching: epoching,
            segHealth: segHealth,
            selection: recordingStore.selection
        )
    }

    // MARK: - SwiftData markers

    private func addMarker(atSample sample: Int, in signal: MFFSignalData) {
        let time = signal.samplingRate > 0 ? Double(sample) / signal.samplingRate : 0
        modelContext.insert(UserMarker(packageName: recording.packageName, timeSeconds: time))
    }

    // MARK: - Keyboard state

    /// Option (⌥) is the app's interaction modifier: held, it reveals the jump
    /// slider, the per-sample hover badge, the event-stack chooser, and the
    /// topomap colour-scale controls. Option rather than Command because
    /// Command-click is already claimed by the system for list/table
    /// multi-selection, and ⌥ is the conventional macOS "alternate action".
    private func installOptionKeyMonitor() {
        guard optionKeyMonitor == nil else { return }
        isOptionKeyPressed = NSEvent.modifierFlags.contains(.option)
        optionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let optionIsPressed = event.modifierFlags.contains(.option)
            isOptionKeyPressed = optionIsPressed
            if !optionIsPressed {
                waveformHoverInfo = nil
            }
            return event
        }
    }

    private func removeOptionKeyMonitor() {
        if let optionKeyMonitor {
            NSEvent.removeMonitor(optionKeyMonitor)
        }
        optionKeyMonitor = nil
        isOptionKeyPressed = false
        waveformHoverInfo = nil
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

    /// Delegates to `WaveformScaleUnits`, which is also what the µV/mm and mm/s
    /// readouts use. Two copies of this rounding would let the stated sweep
    /// speed drift from the drawn one — and because the stride is an integer,
    /// that drift is up to 25% rather than a rounding wobble.
    func displaySampleStride(for samplingRate: Double) -> Int {
        guard samplingRate > 0 else { return referenceDisplaySampleStride }
        return WaveformScaleUnits.displaySampleStride(samplingRate: samplingRate)
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
        let maxOffset = horizontalMaximumOffset(for: plotWidth, viewportWidth: resolvedWidth)
        let nextJumpValue = maxOffset > 0 ? Double(resolvedOffset / maxOffset) : 0
        updateHorizontalJumpValueFromScroll(nextJumpValue)
    }

    private func horizontalMaximumOffset(
        for plotWidth: CGFloat,
        viewportWidth: CGFloat? = nil
    ) -> CGFloat {
        max(plotWidth - (viewportWidth ?? horizontalViewportWidth), 0)
    }

    /// Keeps the slider visually pinned at zero when the plot already fits in
    /// the viewport. A plain `$horizontalJumpValue` binding lets the thumb move
    /// even though the resulting scroll offset is always zero.
    private func horizontalJumpBinding(plotWidth: CGFloat) -> Binding<Double> {
        Binding(
            get: {
                horizontalMaximumOffset(for: plotWidth) > geometryUpdateQuantum
                    ? horizontalJumpValue
                    : 0
            },
            set: { newValue in
                guard !isSyncingSliderFromScroll else { return }
                let maxOffset = horizontalMaximumOffset(for: plotWidth)
                guard maxOffset > geometryUpdateQuantum else {
                    updateHorizontalJumpValueFromScroll(0)
                    horizontalScrollPosition.scrollTo(x: 0)
                    return
                }
                let clamped = min(max(newValue, 0), 1)
                horizontalJumpValue = clamped
                horizontalScrollPosition.scrollTo(x: CGFloat(clamped) * maxOffset)
            }
        )
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

    private func selectEventFromTrack(_ event: MFFEvent, color: Color, in signal: MFFSignalData) {
        // Marks the row selected in the events list (line 2101) without
        // scrolling the waveform — the flag being clicked is on-screen by
        // definition, so recentering on it here was pure unwanted jitter.
        // Jumping to an (possibly off-screen) event from the events *list*
        // still goes through `jumpToEvent` directly (see the `List` row
        // button above) and is unaffected by this.
        selectedEventID = event.id
        // Toggle: selecting the highlighted flag again clears it. Only
        // artifact-detection events (defined artifacts, eye-artifact threshold
        // detection) get this band; imported MFF events aren't highlighted this
        // way. The band centers on `event.centerTimeSeconds`, which accounts
        // for onset-tagged sources (Topography/Continuous) vs. center-tagged
        // ones (Template/Trajectory/threshold detection).
        if highlightedArtifactEvent?.id == event.id {
            highlightedArtifactEvent = nil
        } else if isCenteredArtifactDetectionEvent(event) {
            highlightedArtifactEvent = event
            highlightedArtifactColor = color
        } else {
            highlightedArtifactEvent = nil
        }
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

    /// Kept here because `MFFExportFlowViews` and `WaveletArtifactExplorerViews`
    /// also call it; delegates to the panel's implementation so the two cannot
    /// drift apart.
    func formattedEventTime(_ seconds: Double) -> String {
        EventsPanelView.formattedEventTime(seconds)
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
