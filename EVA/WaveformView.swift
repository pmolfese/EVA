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
    @State private var showsECGDetectionSheet = false
    // BCG detection
    @State private var detectsBCGArtifacts = false
    @State private var showsBCGDetectionSheet = false
    @State private var bcgDetectionMethod = BCGDetectionMethod.periodicity
    @State private var bcgEventCode = "BCG"
    @State private var bcgWindowSeconds = 0.700
    @State private var bcgThresholdSD = 2.5
    @State private var bcgMinHR: Double = 40
    @State private var bcgMaxHR: Double = 120
    @State private var bcgPowerMinHz = 0.8
    @State private var bcgPowerMaxHz = 1.5
    @State private var bcgQRSLagMs = 300.0
    @State private var bcgPCAComponents = 1
    @State private var bcgSpatialWhiten = false
    @State private var bcgSlidingNormalize = true
    @State private var bcgRespAdaptive = true
    @State private var isRunningBCGDetection = false
    @State private var bcgDetectionStatus: String? = nil
    @State private var bcgRefinedTemplate: [Float]? = nil
    @State private var bcgRefinedKeptCount: Int? = nil
    @State private var bcgIsRefining = false
    @State private var bcgRejectFraction = 0.20
    /// Stable UUID so re-running detection updates the existing DefinedArtifact rather than appending a new one.
    private let bcgDefinedArtifactID = UUID()
    @State private var ecgDetectionSelectedPNSChannels = Set<Int>()
    @State private var ecgDetectionProxyChannels = ""
    @State private var ecgDetectionAlgorithm = ECGDetectionAlgorithm.panTompkins
    @State private var ecgDetectionThresholdSD = 4.0
    @State private var ecgDetectionMinimumRRSeconds = 0.30
    @State private var ecgDetectionPolarity = ECGDetectionPolarity.either
    @State private var isEstimatingECGDetection = false
    @State private var ecgAlgorithmResults: [ECGDetectionAlgorithm: ECGAlgorithmResult] = [:]
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
    @State private var artifactDefinitionPanel = ArtifactDefinitionPanel.waveforms
    @State private var artifactTemplateConfirmedSource: ArtifactDefinitionResultSource?
    @State private var artifactTemplateTopographyMode = ArtifactTopographyMode.off
    @State private var artifactTrajectoryShiftSeconds = 0.05
    @State private var artifactTrajectoryScaleRange   = 0.10
    @State private var artifactTrajectoryGFPWeighted  = true
    @State private var artifactTrajectorySelectedFrame: ArtifactTrajectoryFrame? = nil
    @State private var artifactTopographyChannelScope = ArtifactTopographyChannelScope.allGood
    @State private var artifactTopographyTopN: Int = 16
    @State private var artifactTopographyMetric = ArtifactTopographyMetric.pearson
    @State private var isRefreshingTopography = false
    /// Monotonic token so out-of-order live topography refreshes can be ignored
    /// (only the most recently started refresh is allowed to apply its result).
    @State private var topographyRefreshGeneration = 0
    /// Snapshot of the scan-affecting controls at the moment the last full scan
    /// ran, used to know when the displayed result is stale (→ "Rescan").
    @State private var lastArtifactScanSignature: ArtifactScanSignature?
    @State private var isApplyingArtifactTemplate = false
    @State private var artifactScanCompleted: Int = 0
    @State private var artifactScanTotal: Int = 0
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
    @State private var showsICASheet = false
    @State private var isRunningICA = false
    @State private var icaProgress = 0.0
    @State private var icaProgressMessage = ""
    @State private var icaMethod: ICAMethod = .picard
    @State private var icaComponentCount = 20
    @State private var icaVarianceThreshold = 0.999
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
    @State private var psaSegmentField = PSASegmentField.code
    @State private var psaEventSearchText = ""
    @State private var psaSelectedEventCodes = Set<String>()
    @State private var psaPreStimulus = 0.2
    @State private var psaPostStimulus = 0.8
    @State private var psaOffset = 0.0
    @State private var psaCategoryNames = [String: String]()
    @State private var psaTimingMarkerEnabledValues = Set<String>()
    @State private var psaTimingMarkerValuesBySegmentValue = [String: String]()
    @State private var psaTimingTolerance = 0.5
    @State private var psaSkipIfContainsArtifact = false
    @State private var psaSkipEyeBlinks = true
    @State private var psaSkipEyeMovements = true
    @State private var psaSkippedDefinedArtifactIDs = Set<DefinedArtifact.ID>()
    @State private var psaKnownArtifactIDsForRejection = Set<DefinedArtifact.ID>()
    @State private var psaAverageOnApply = false
    @State private var psaBaselineCorrected = false
    @State private var psaAverageReference = false
    @State private var psaStatusMessage: String?
    @State private var psaIsApplying = false
    @State private var psaPhaseMessage: String? = nil
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
    @State private var filteredPNSSignal: MFFSignalData?
    @State private var filteredPNSInputSignalType: String?
    @State private var filterPNSChannels = true
    @State private var artifactCleanedSignal: MFFSignalData?
    @State private var artifactCleaningIsEnabled = true
    // Wavelet artifact reduction (HAPPE-style) pipeline stage.
    @State private var waveletReducedSignal: MFFSignalData?
    @State private var waveletReductionArtifact: MFFSignalData?
    @State private var waveletReductionIsEnabled = true
    @State private var waveletReductionResult: WaveletReductionResult?
    @State private var waveletReductionMode = WaveletReductionMode.continuousEEG
    @State private var waveletReductionConfig = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: 250)
    @State private var isRunningWaveletReduction = false
    @State private var waveletReductionProgress = 0.0
    @State private var waveletReductionStatusMessage: String?
    @State private var waveletReductionBandVarianceRetained: Double?
    @State private var waveletReductionCoreCount = WaveletReducer.defaultCoreCount
    @State private var waveletReductionCandidates: [WaveletReductionCandidate] = []
    @State private var selectedWaveletCandidateID: String?
    @State private var showsWaveletReductionSheet = false
    @State private var isFiltering = false
    @State private var filterProgress: Double = 0
    @State private var filterStatusMessage: String?
    @State private var filterStatusIsError = false
    @State private var mriStatusIsError = false
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

    @State private var showsFilterPopover = false
    @State private var filterLowCutoff = 0.1
    @State private var filterHighPassSlope = FilterSlope.dB24
    @State private var filterHighCutoff = 30.0
    @State private var filterLowPassSlope = FilterSlope.dB24
    @State private var notch60HzEnabled = false
    @State private var filterLineNoiseMode = FilterLineNoiseMode.off
    @State private var filterLineNoiseFrequency = 60.0
    @State private var filterLineNoiseHarmonics = 2
    @State private var filterLineNoiseWindowSeconds = 4.0
    @State private var filterLineNoiseStrength = 1.0
    @State private var showsFilterLineNoiseOptions = false
    @State private var filterAverageReference = false

    // MRI artifact removal. The gradient-corrected signal becomes the base that
    // filtering and display build on.
    @State private var gradientCorrectedSignal: MFFSignalData?
    @State private var gradientCorrectedPNSSignal: MFFSignalData?
    @State private var mriAppliesToPNS = true
    @State private var isProcessingMRI = false
    @State private var mriStatusMessage: String?
    @State private var mriProgress: Double = 0
    @State private var showsMRIPopover = false
    // Number of neighboring TRs averaged into the template before/after the
    // current TR. Exposed in the MRI popover; defaults mirror GradientRemover.
    @State private var mriWindowBefore = GradientRemover.Window.default.before
    @State private var mriWindowAfter = GradientRemover.Window.default.after
    // Event code whose occurrences mark the TR (volume) onsets. Defaults to
    // "TREV" when present in the recording.
    @State private var mriTRMarkerCode = "TREV"
    // Head-motion configuration for fMRI-gradient correction (FASTR et al.).
    @State private var showsMotionConfig = false
    @State private var motionParameters: MotionParameters?
    @State private var motionFDThreshold = 0.5
    @State private var motionRadiusMm = 50.0
    // Gradient-removal method selection and FASTR parameters.
    @State private var mriMethod = MRIGradientMethod.aas
    @State private var showsMRIMethodHelp = false
    @State private var fastrSlices = 1
    @State private var fastrOBSAuto = true
    @State private var fastrANC = false
    @State private var fastrSubSample = true
    // Optional: drop volumes whose FD exceeds the threshold from templates.
    @State private var mriExcludeHighMotion = false
    // TR-marker alignment: trim TREV events from the start/end of the recording
    // to match the motion file, and a sanity-check TR (seconds between events).
    @State private var mriSkipStart = 0
    @State private var mriSkipEnd = 0
    @State private var mriTRSeconds = 0.0

    // Per-channel state, shared with the menu-bar Channels commands.
    @State private var channels = ChannelModel()
    @State private var electrodeGeometry: ElectrodeGeometry?
    @State private var channelStatusMessage: String?
    @State private var channelHealthStatusMessage: String?
    @State private var channelHealthSignature: String?
    @State private var channelHealthTask: Task<Void, Never>?
    @State private var channelLabelMetricsExportRequest = 0
    @State private var showsChannelHealthDetails = false
    @State private var channelHealthDetailsRequest = 0
    @State private var showsChannelGoodnessSettings = false
    @State private var channelGoodnessSettingsRequest = 0
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
    private let physioScaleOptions: [Double] = [8, 16, 32, 64]
    private let physioScaleBounds: ClosedRange<Double> = 1...64

    private var artifactMenuControls: ArtifactMenuControls {
        ArtifactMenuControls(
            artifacts: definedArtifacts,
            deleteRequest: $artifactDeletionRequest,
            deleteAllRequest: $deleteAllArtifactsRequest
        )
    }

    private var psaControls: PSAViewControls {
        PSAViewControls(
            showButterfly: $showsButterflyPlot,
            showOverlaidCategories: $showsOverlaidCategories,
            isAveraged: psaIsAveraged
        )
    }

    private var segmentHealthControls: SegmentHealthViewControls {
        SegmentHealthViewControls(
            showsHealth: $showsSegmentHealth,
            showsMouseOverHealth: $showsSegmentHealthMouseOver,
            detailsRequest: $segmentHealthDetailsRequest,
            refreshRequest: $segmentHealthRefreshRequest,
            isAnalyzing: isAnalyzingSegmentHealth,
            progress: segmentHealthProgress
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
            detailsRequest: $channelHealthDetailsRequest,
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
                let base = icaCleanedSignal ?? gradientCorrectedSignal ?? rawSignal
                let preArtifact = filteredSignal ?? base
                let processed = artifactCleaningIsEnabled ? (artifactCleanedSignal ?? preArtifact) : preArtifact
                // Wavelet reduction stage: computed from `processed`, applied
                // before interpolation. Toggleable and revertible like cleaning.
                let waveletStage = waveletReductionIsEnabled ? (waveletReducedSignal ?? processed) : processed
                let continuousSignal = applyInterpolations(to: waveletStage)
                content(
                    for: epochedSignal ?? continuousSignal,
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
        .focusedSceneValue(\.icaDebugReportRequest, $icaDebugReportRequest)
        .focusedSceneValue(\.resetToOriginalRequest, $resetToOriginalRequest)
        .focusedSceneValue(\.psaViewControls, psaControls)
        .focusedSceneValue(\.segmentHealthViewControls, segmentHealthControls)
        .focusedSceneValue(\.channelHealthViewControls, channelHealthControls)
        .focusedSceneValue(\.mffExportRequest, $mffExportRequest)
        .focusedSceneValue(\.physioViewControls, physioViewControls)
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
        .onChange(of: channelHealthDetailsRequest) { _, _ in
            channels.showsHealth = true
            showsChannelHealthDetails = true
        }
        .onChange(of: channelGoodnessSettingsRequest) { _, _ in
            showsChannelGoodnessSettings = true
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
            await loadRecordingIfNeeded()
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

    private func loadRecordingIfNeeded() async {
        await recording.loadIfNeeded()
        if electrodeGeometry == nil {
            electrodeGeometry = recording.electrodeGeometry
        }
        adoptOnDiskEpochsIfPresent()
    }

    /// When the opened file was segmented or category-averaged by other software,
    /// the reader already supplies `epochSegments`. Surface them through the same
    /// state the in-app PSA pipeline uses, so the recording displays as discrete
    /// epochs (with stimulus-locked markers) instead of a misleading continuous
    /// strip with out-of-place events.
    private func adoptOnDiskEpochsIfPresent() {
        guard epochedSignal == nil,
              let signal = recording.signal,
              signal.isSegmented,
              !signal.epochSegments.isEmpty else {
            return
        }
        segmentedEpochSignal = signal
        segmentedEpochSegments = signal.epochSegments
        epochedSignal = signal
        epochSegments = signal.epochSegments
        psaIsAveraged = signal.isAveraged
        psaStatusMessage = signal.isAveraged
            ? "Loaded \(signal.epochSegments.count) averaged categories"
            : "Loaded \(signal.epochSegments.count) epochs"
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
        let isShowingEpochs = epochedSignal != nil
        let events = displayedEvents(
            for: signal,
            includeContinuousOverlays: true,
            mapContinuousOverlaysIntoEpochs: isShowingEpochs
        )

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                controls(for: signal, base: base, waveletInput: waveletInput, continuousSignal: continuousSignal)

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
        .sheet(isPresented: $showsECGDetectionSheet) {
            ecgDetectionSheet(for: continuousSignal)
        }
        .sheet(isPresented: $showsBCGDetectionSheet) {
            bcgDetectionSheet(for: continuousSignal, selection: activeSelectionRange(in: continuousSignal))
        }
        .sheet(isPresented: $showsWaveletArtifactExplorer) {
            waveletArtifactExplorerSheet(for: continuousSignal)
        }
        .sheet(isPresented: $showsWaveletReductionSheet) {
            waveletReductionSheet(input: waveletInput)
        }
        .sheet(isPresented: $showsICASheet) {
            icaSheet(for: base)
        }
        .sheet(isPresented: $showsChannelHealthDetails) {
            channelHealthDetailsSheet(for: continuousSignal)
        }
        .sheet(isPresented: $showsChannelGoodnessSettings) {
            ChannelGoodnessSettingsView()
                .environment(goodnessSettings)
        }
        .sheet(isPresented: $showsSegmentHealthDetails) {
            segmentHealthDetailsSheet()
        }
        .sheet(isPresented: $showsMotionConfig) {
            MotionConfigView(
                parameters: $motionParameters,
                fdThreshold: $motionFDThreshold,
                radiusMm: $motionRadiusMm,
                skipStart: $mriSkipStart,
                skipEnd: $mriSkipEnd,
                trSeconds: $mriTRSeconds,
                trMarkerCode: mriTRMarkerCode,
                trMarkerSamples: recording.signal.map { trMarkerSamples(in: $0, code: mriTRMarkerCode) } ?? [],
                samplingRate: recording.signal?.samplingRate ?? 0,
                windowBefore: mriWindowBefore,
                windowAfter: mriWindowAfter,
                onClose: {
                    showsMotionConfig = false
                    showsMRIPopover = true
                }
            )
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

    private func controls(for signal: MFFSignalData, base: MFFSignalData, waveletInput: MFFSignalData, continuousSignal: MFFSignalData) -> some View {
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
            Button {
                showsMRIPopover.toggle()
            } label: {
                ToolbarIcon(name: "icon.mri", isActive: gradientCorrectedSignal != nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("MRI")
            .disabled(isProcessingMRI)
            .help(gradientCorrectedSignal != nil
                ? "Gradient artifact removed using \(mriTRMarkerCode) triggers."
                : "MR artifact removal")
            .popover(isPresented: $showsMRIPopover, arrowEdge: .bottom) {
                mriPopover(for: recording.signal)
            }

            Button {
                showsFilterPopover.toggle()
            } label: {
                ToolbarIcon(name: "icon.filter", isActive: filteredSignal != nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter")
            .disabled(isFiltering)
            .help(filteredSignal != nil
                ? "Active: Butterworth \(String(format: "%.1f", filterLowCutoff))–\(String(format: "%.1f", filterHighCutoff)) Hz\(filterLineNoiseSummary)\(filterAverageReference ? " + avg ref" : "")"
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
                }

                Button("Clean Artifacts…") {
                    showsArtifactCleaningSheet = true
                }
                .disabled(definedArtifacts.isEmpty)

                Divider()

                Button("Wavelet Artifact Explorer…") {
                    openWaveletArtifactExplorer(for: continuousSignal)
                }
                .disabled(isRunningWaveletArtifactExplorer)

                Button("Wavelet Reduction…") {
                    openWaveletReductionSheet(input: waveletInput)
                }

                Toggle("Show Wavelet Reduction", isOn: Binding(
                    get: { waveletReductionIsEnabled },
                    set: { setWaveletReductionEnabled($0) }
                ))
                .disabled(waveletReducedSignal == nil)
                .help(waveletReducedSignal == nil
                    ? "Run wavelet reduction before toggling the reduced signal."
                    : "Switch between the wavelet-reduced signal and the input signal.")

                Button("Revert Wavelet Reduction") {
                    revertWaveletReduction()
                }
                .disabled(waveletReducedSignal == nil)

                Divider()

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
                
                Divider()
                
                Button(detectsECGArtifacts ? "Configure ECG / QRS Detection…" : "ECG / QRS Detection…") {
                    openECGDetectionSheet(for: continuousSignal)
                }
                if detectsECGArtifacts {
                    Button("Turn Off ECG Detection") {
                        detectsECGArtifacts = false
                        artifactDetectionRefreshToken += 1
                    }
                }
                Button(detectsBCGArtifacts ? "Configure BCG Detection…" : "BCG Detection…") {
                    showsBCGDetectionSheet = true
                }
                if detectsBCGArtifacts {
                    Button("Turn Off BCG Detection") {
                        disableBCGDetection()
                    }
                }

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
        if !isProcessingMRI, let mriStatusMessage {
            lines.append(LogLine(source: "MRI", text: mriStatusMessage, isError: mriStatusIsError))
        }
        if !isFiltering, let filterStatusMessage {
            lines.append(LogLine(source: "Filter", text: filterStatusMessage, isError: filterStatusIsError))
        }
        if let psaStatusMessage {
            lines.append(LogLine(source: "Segment", text: psaStatusMessage, isError: false))
        }
        if let channelStatusMessage {
            lines.append(LogLine(source: "Channel", text: channelStatusMessage, isError: channelStatusIsError))
        }
        if let channelHealthStatusMessage {
            lines.append(LogLine(source: "Channel Health", text: channelHealthStatusMessage, isError: false))
        }
        if let segmentHealthStatusMessage {
            lines.append(LogLine(source: "Segment Health", text: segmentHealthStatusMessage, isError: false))
        }
        if let artifactCleaningStatusMessage {
            lines.append(LogLine(source: "Artifact", text: artifactCleaningStatusMessage, isError: false))
        }
        if let waveletExplorerStatusMessage {
            lines.append(LogLine(source: "Wavelet", text: waveletExplorerStatusMessage, isError: false))
        }
        if let waveletReductionStatusMessage {
            lines.append(LogLine(source: "Wavelet Reduction", text: waveletReductionStatusMessage, isError: false))
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
                if isProcessingMRI {
                    logProgressRow(label: "MRI", value: mriProgress)
                }
                if isFiltering {
                    logProgressRow(label: "Filter", value: filterProgress)
                }
                if let artifactCleaningProgress {
                    logProgressRow(label: "Artifact", value: artifactCleaningProgress.fraction)
                }
                if isRunningWaveletArtifactExplorer {
                    logProgressRow(label: "Wavelet", value: waveletExplorerProgress)
                }
                if isRunningWaveletReduction {
                    logProgressRow(label: "Reduction", value: waveletReductionProgress)
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
                    StatusLogLineView(line: line)
                }

                if !isProcessingMRI,
                   !isFiltering,
                   !isRunningWaveletArtifactExplorer,
                   !isRunningWaveletReduction,
                   !channels.isAnalyzingHealth,
                   !isAnalyzingSegmentHealth,
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
    }

    // MARK: - Physio (PNS) pane

    private func pnsFilterBaseSignal() -> MFFSignalData? {
        guard let raw = recording.pnsSignal else { return nil }
        if mriAppliesToPNS, let gradientCorrectedPNSSignal {
            return gradientCorrectedPNSSignal
        }
        return raw
    }

    private func displayedPhysioSignal() -> MFFSignalData? {
        let base: MFFSignalData?
        if let pnsBase = pnsFilterBaseSignal() {
            if filterPNSChannels,
               let filteredPNSSignal,
               filteredPNSInputSignalType == pnsBase.signalType {
                base = filteredPNSSignal
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
                        sampleStride: sampleStride,
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

    private func physioRangeTaskID(for signal: MFFSignalData) -> String {
        [
            signal.signalURL.path,
            signal.signalType,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            filterPNSChannels ? "filterPNS" : "rawPNS",
            mriAppliesToPNS ? "mriPNS" : "rawMRI"
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
        let currentScale = physioScaleFactor(for: index)
        let isMaxScaled = physioMaxScaledChannels.contains(index)
        let isFlipped = physioFlippedPolarity.contains(index)
        Text("\(name): \(isMaxScaled ? "Max" : physioScaleLabel(currentScale))\(isFlipped ? ", flipped" : "")")

        Button("Rename…") {
            physioRenameText = name
            physioRenameTarget = index
        }

        Divider()

        Divider()

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
                if waveletReducedSignal != nil {
                    Toggle("Show reduction", isOn: Binding(
                        get: { waveletReductionIsEnabled },
                        set: { setWaveletReductionEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    Button("Revert") { revertWaveletReduction() }
                }
                Spacer()
                Button(waveletReducedSignal == nil ? "Run" : "Re-run") {
                    runWaveletReduction(on: input)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunningWaveletReduction || reduceCount == 0)
                Button("Close") { showsWaveletReductionSheet = false }
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
                Picker("Mode", selection: $waveletReductionMode) {
                    ForEach(WaveletReductionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: waveletReductionMode) { _, newMode in
                    waveletReductionConfig = newMode.defaultConfiguration(samplingRate: input.samplingRate)
                }

                Text(waveletReductionMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Transform")
                        Picker("", selection: $waveletReductionConfig.kind) {
                            ForEach(WaveletTransformKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Wavelet")
                        Picker("", selection: $waveletReductionConfig.family) {
                            ForEach(WaveletReductionFamily.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Threshold rule")
                        Picker("", selection: $waveletReductionConfig.thresholdRule) {
                            ForEach(WaveletCleaningThresholdRule.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Threshold model")
                        Picker("", selection: $waveletReductionConfig.thresholdModel) {
                            ForEach(WaveletCleaningThresholdModel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Levels")
                        Stepper("\(waveletReductionConfig.levelCount)", value: $waveletReductionConfig.levelCount, in: 1...WaveletReducer.maximumLevelCount)
                            .frame(width: 120)
                    }
                    GridRow {
                        Text("Strength")
                        TextField("x", value: $waveletReductionConfig.thresholdScale, format: .number.precision(.fractionLength(2)))
                            .frame(width: 80)
                    }
                    GridRow {
                        Text("Downsample")
                        Picker("", selection: $waveletReductionConfig.downsampleFactor) {
                            ForEach(downsampleFactorOptions(for: input.samplingRate), id: \.self) { factor in
                                Text(downsampleFactorLabel(factor: factor, rate: input.samplingRate)).tag(factor)
                            }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    GridRow {
                        Text("CPU cores")
                        Stepper("\(waveletReductionCoreCount) of \(WaveletReducer.maximumCoreCount)", value: $waveletReductionCoreCount, in: 1...WaveletReducer.maximumCoreCount)
                            .frame(width: 140)
                    }
                }
                .font(.callout)

                if isRunningWaveletReduction {
                    ProgressView(value: waveletReductionProgress)
                    Text("\(Int((waveletReductionProgress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let result = waveletReductionResult {
                    Divider()
                    waveletReductionQCView(result: result)
                } else if let message = waveletReductionStatusMessage {
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

            if waveletReductionCandidates.isEmpty {
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

                if let result = waveletReductionResult {
                    waveletPerLevelBars(result: result)
                }

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(waveletReductionCandidates) { candidate in
                            Button {
                                selectedWaveletCandidateID = candidate.id
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
                                        .fill(candidate.id == selectedWaveletCandidateID
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
        if !options.contains(waveletReductionConfig.downsampleFactor) {
            options.append(waveletReductionConfig.downsampleFactor)
        }
        return options.sorted()
    }

    private func downsampleFactorLabel(factor: Int, rate: Double) -> String {
        let decimatedRate = Int((rate / Double(max(factor, 1))).rounded())
        return factor == 1 ? "Full (\(decimatedRate) Hz)" : "\(decimatedRate) Hz"
    }

    private var selectedWaveletCandidate: WaveletReductionCandidate? {
        waveletReductionCandidates.first { $0.id == selectedWaveletCandidateID }
            ?? waveletReductionCandidates.first
    }

    @ViewBuilder
    private func waveletCandidatePlot(candidate: WaveletReductionCandidate, input: MFFSignalData) -> some View {
        let channel = candidate.channelIndex
        let start = candidate.startSample
        let end = min(candidate.endSample, input.data[safe: channel]?.count ?? 0)
        let original = input.data[safe: channel].map { Array($0[start..<max(start, end)]) } ?? []
        let cleaned = waveletReducedSignal?.data[safe: channel].map { Array($0[start..<min(end, $0.count)]) } ?? []
        let removed = waveletReductionArtifact?.data[safe: channel].map { Array($0[start..<min(end, $0.count)]) } ?? []
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
                if let band = waveletReductionBandVarianceRetained {
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

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                WaveletArtifactAnalyzer.explore(in: signal, configuration: configuration) { update in
                    Task { @MainActor in
                        publishWaveletExplorerProgress(update, generation: generation)
                    }
                }
            }.value

            guard generation == waveletExplorerRunGeneration else { return }
            waveletExplorerResult = result
            waveletExplorerProgress = 1
            waveletExplorerStatusTitle = "Wavelet artifact explorer scan complete"
            waveletExplorerStatusDetail = "\(result.candidates.count) candidates across \(result.channelCount) channels over \(String(format: "%.1f", result.analyzedDurationSeconds)) seconds."
            waveletExplorerStatusMessage = "\(result.candidates.count) wavelet candidates found"
            isRunningWaveletArtifactExplorer = false
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
        let centerX = (contentX(forSample: lower) + contentX(forSample: upper + 1)) / 2
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
        artifactTopographyTopN = 16
        artifactTopographyMetric = .pearson
        artifactTrajectoryGFPWeighted = true
        artifactTrajectorySelectedFrame = nil
        artifactDefinitionPanel = .waveforms
        artifactTemplateConfirmedSource = nil
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

            artifactIdentitySection

            Picker("Artifact definition section", selection: $artifactDefinitionPanel) {
                ForEach(ArtifactDefinitionPanel.allCases) { panel in
                    Text(panel.rawValue).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            artifactDefinitionPanelContent(signal: signal, selectedChannels: selectedChannels)

            artifactDefinitionComparisonSection(signal: signal)

            HStack {
                Button("Save JSON…") {
                    saveArtifactTemplateJSON(artifactTemplateResult?.savedTemplate)
                }
                .disabled(artifactTemplateResult == nil)

                Spacer()

                Button(artifactDefinitionCloseTitle) {
                    showsArtifactTemplateSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button(artifactDefinitionApplyTitle) {
                    applyActiveArtifactDefinitionPanel(to: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isApplyingArtifactTemplate
                        || artifactTemplateSelectionRange == nil
                        || selectedChannels.isEmpty
                        || comparisonChannels.isEmpty
                        || artifactTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || artifactTemplateEventCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !activeArtifactDefinitionPanelCanRun
                )
            }
        }
        .padding(20)
        .frame(width: 760)
        .onChange(of: artifactDefinitionPanel) { _, panel in
            if panel == .topography, !artifactTemplateTopographyMode.isEnabled {
                artifactTemplateTopographyMode = .peak
            }
        }
        .onChange(of: artifactTemplateTopographyMode) { _, _ in
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: artifactTopographyChannelScope) { _, _ in
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: artifactTopographyTopN) { _, _ in
            guard artifactTopographyChannelScope == .topN else { return }
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: artifactTopographyMetric) { _, _ in
            refreshTopographyIfNeeded(for: signal)
        }
    }

    private var artifactIdentitySection: some View {
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

                ArtifactTemplateFieldLabel(
                    title: "Event Code",
                    help: "The event marker name inserted for each match. These generated markers appear in the Events panel and can be used by PSA artifact rejection."
                )
                TextField("Event code", text: $artifactTemplateEventCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            GridRow {
                ArtifactTemplateFieldLabel(
                    title: "Name",
                    help: "A human-readable label for this artifact template. This is saved in the JSON so you can recognize the exemplar later."
                )
                TextField("Artifact name", text: $artifactTemplateName)
                    .textFieldStyle(.roundedBorder)
                    .gridCellColumns(3)
            }
        }
    }

    private func artifactWaveformConfigurationSection(selectedChannels: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                waveformChannelGridRows
                waveformThresholdGridRows
                waveformWindowGridRows
            }

            Text("\(selectedChannels.count) selected channels · all-channel comparison enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var waveformChannelGridRows: some View {
        Group {
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
                    .frame(width: 180)
                    .disabled(artifactTemplateChannelScope != .specificChannels)
            }
        }
    }

    private var waveformThresholdGridRows: some View {
        Group {
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
                .frame(width: 180)
            }
        }
    }

    private var waveformWindowGridRows: some View {
        Group {
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
                HStack(spacing: 10) {
                    TextField("Hz", value: $artifactTemplateDownsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text("Merge")
                        .font(.caption.weight(.semibold))
                    TextField("Merge", value: $artifactTemplateMergeWindowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
            }
        }
    }

    private func artifactTopographyConfigurationSection(signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Reference",
                        help: "Scans for the exemplar's scalp voltage map (spatial pattern across electrodes). Window Middle uses the centre sample, Window Peak the highest global field power sample, and Window Average the mean map over the window."
                    )
                    Picker("Reference", selection: $artifactTemplateTopographyMode) {
                        ForEach(ArtifactTopographyMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Fit Metric",
                        help: "Cost function for scalp-map similarity, independent of the waveform polarity. Pearson r matches same-polarity maps; |Pearson r| also matches polarity-inverted maps; Opposite (-r) matches only the inverted map."
                    )
                    Picker("Fit Metric", selection: $artifactTopographyMetric) {
                        ForEach(ArtifactTopographyMetric.allCases) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

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

                        if artifactTopographyChannelScope == .topN {
                            Stepper(value: $artifactTopographyTopN, in: 3...128) {
                                Text("N = \(artifactTopographyTopN)")
                                    .font(.caption.monospacedDigit())
                            }
                            .help("Number of channels selected by highest RMS amplitude in the exemplar window. Fewer channels focus the spatial correlation on those that express the artifact most strongly.")
                        }
                    }

                    ArtifactTemplateFieldLabel(
                        title: "Threshold",
                        help: "Minimum spatial correlation required to count a scalp-map match."
                    )
                    HStack {
                        Slider(value: $artifactTemplateThreshold, in: 0.30...0.98, step: 0.01)
                        Text("\(Int((artifactTemplateThreshold * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 180)
                }

                if artifactTemplateTopographyMode == .trajectory {
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Shift (s)",
                            help: "Maximum time shift (±seconds) applied to the reference trajectory when searching for the best-fitting alignment. Handles beat-to-beat onset jitter. Set to 0 to disable."
                        )
                        TextField("Shift", value: $artifactTrajectoryShiftSeconds, format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        ArtifactTemplateFieldLabel(
                            title: "Scale ±",
                            help: "Fractional time-scale tolerance (0–1). E.g. 0.10 allows the trajectory to be stretched or compressed by ±10%, accommodating heart-rate variation. Set to 0 to disable."
                        )
                        HStack(spacing: 8) {
                            TextField("Scale", value: $artifactTrajectoryScaleRange, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            if let ref = artifactTemplateResult?.topographyReference,
                               let frames = ref.trajectoryFrameCount {
                                Text("\(frames)-frame trajectory")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "GFP Weighting",
                            help: "When on, each frame's spatial-correlation score is weighted by the reference frame's Global Field Power (amplitude). Peak-amplitude frames drive the match; quiet frames barely count. Good for artifacts with a clear temporal peak (BCG, saccades, muscle bursts). Turn off for sustained or amplitude-flat artifacts where the quiet periods are part of the signature."
                        )
                        Toggle("Weight frames by amplitude", isOn: $artifactTrajectoryGFPWeighted)
                            .toggleStyle(.checkbox)
                    }
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Window (s)",
                        help: "Duration of the exemplar window used to build the reference map (or trajectory). Centered on your highlighted region."
                    )
                    TextField("Window", value: $artifactTemplateWindowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    ArtifactTemplateFieldLabel(
                        title: "Sample Hz",
                        help: "Internal downsample rate used during the scan. Lower values run faster; 250 Hz is enough for scalp-map artifacts. Does not affect output event precision."
                    )
                    TextField("Hz", value: $artifactTemplateDownsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Merge (s)",
                        help: "Hits within this time window of each other are merged into a single event (keeping the highest-scoring one). Prevents double-counting a single artifact."
                    )
                    TextField("Merge", value: $artifactTemplateMergeWindowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            Text("\(artifactTopographyChannels(in: signal).count) topography channels · bad channels excluded")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var artifactDefinitionCloseTitle: String {
        guard let artifactTemplateConfirmedSource else {
            return "Close"
        }
        return "Confirm \(artifactTemplateConfirmedSource.confirmationName) Selection"
    }

    private var artifactDefinitionApplyTitle: String {
        switch artifactDefinitionPanel {
        case .waveforms:
            return artifactTemplateResult == nil ? "Run Waveform Scan" : "Rescan Waveforms"
        case .topography:
            return artifactTemplateResult?.topographyReference == nil ? "Run Topography Scan" : "Rescan Topography"
        }
    }

    private var activeArtifactDefinitionPanelCanRun: Bool {
        switch artifactDefinitionPanel {
        case .waveforms:
            return artifactTemplateResult == nil || artifactTemplateScanIsStale
        case .topography:
            return artifactTemplateTopographyMode.isEnabled
        }
    }

    private func applyActiveArtifactDefinitionPanel(to signal: MFFSignalData) {
        switch artifactDefinitionPanel {
        case .waveforms:
            applyArtifactTemplate(to: signal, preferredSource: .waveform)
        case .topography:
            applyArtifactTemplate(to: signal, preferredSource: .topography)
        }
    }

    @ViewBuilder
    private func artifactDefinitionPanelContent(signal: MFFSignalData, selectedChannels: [Int]) -> some View {
        switch artifactDefinitionPanel {
        case .waveforms:
            artifactWaveformsPanel(signal: signal, selectedChannels: selectedChannels)
        case .topography:
            artifactTopographyPanel(signal: signal)
        }
    }

    private func artifactWaveformsPanel(signal: MFFSignalData, selectedChannels: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            artifactWaveformConfigurationSection(selectedChannels: selectedChannels)
            artifactDefinitionActivityView(
                isRunning: isApplyingArtifactTemplate,
                runningText: "Scanning waveform matches..."
            )

            if let artifactTemplateResult {
                artifactWaveformResultView(artifactTemplateResult, signal: signal)
            } else {
                artifactDefinitionEmptyPreview(
                    title: "No waveform scan yet",
                    detail: "Run waveform matching to inspect the exemplar average and channel-scope behavior."
                )
            }
        }
    }

    private func artifactTopographyPanel(signal: MFFSignalData) -> some View {
        let isRunning = isApplyingArtifactTemplate || isRefreshingTopography
        let runningText = isRefreshingTopography
            ? "Refreshing topography matches..."
            : "Scanning topography matches..."

        return VStack(alignment: .leading, spacing: 12) {
            artifactTopographyConfigurationSection(signal: signal)
            artifactDefinitionActivityView(isRunning: isRunning, runningText: runningText)

            if let topography = artifactTemplateResult?.topographyReference {
                artifactTopographyResultView(topography)
            } else {
                artifactDefinitionEmptyPreview(
                    title: "No topography scan yet",
                    detail: "Run a topography scan to inspect the scalp map and spatial match settings."
                )
            }
        }
    }

    @ViewBuilder
    private func artifactDefinitionActivityView(isRunning: Bool, runningText: String) -> some View {
        if isRunning {
            HStack(spacing: 10) {
                if artifactScanTotal > 0 {
                    ProgressView(value: Double(artifactScanCompleted), total: Double(artifactScanTotal))
                        .frame(width: 100)
                    Text("\(artifactScanCompleted) / \(artifactScanTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Text(runningText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let artifactTemplateStatusMessage {
            Text(artifactTemplateStatusMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func artifactDefinitionEmptyPreview(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func artifactDefinitionComparisonSection(signal: MFFSignalData) -> some View {
        if artifactTemplateResult != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run Comparison")
                    .font(.caption.weight(.semibold))

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        Text("Selection")
                        Text("Found")
                        Text("Evidence")
                        Text("")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                    if let result = artifactTemplateResult {
                        artifactDefinitionComparisonRow(
                            source: .waveform,
                            count: result.selectedEvents.count,
                            detail: waveformComparisonDetail(result, signal: signal),
                            score: nil
                        ) {
                            useWaveformMatches(result, signal: signal)
                        }

                        if let topography = result.topographyReference {
                            artifactDefinitionComparisonRow(
                                source: .topography,
                                count: topography.matchCount,
                                detail: "\(topography.channelIndices.count) channels · \(artifactTopographyMetric.rawValue)",
                                score: nil
                            ) {
                                useTopographyMatches(result, signal: signal)
                            }
                        }
                    }

                }

                Text("The selected row becomes the artifact event set used by Clean Artifacts and PSA rejection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func artifactDefinitionComparisonRow(
        source: ArtifactDefinitionResultSource,
        count: Int,
        detail: String,
        score: Double?,
        action: @escaping () -> Void
    ) -> some View {
        GridRow {
            Label(source.displayName, systemImage: artifactTemplateConfirmedSource == source ? "checkmark.circle.fill" : source.systemImage)
                .font(.caption)
                .foregroundStyle(artifactTemplateConfirmedSource == source ? .green : .primary)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.semibold))
            HStack(spacing: 6) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let score {
                    Text(String(format: "best %.2f", score))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button(artifactTemplateConfirmedSource == source ? "Selected" : "Use") {
                action()
            }
            .font(.caption)
            .disabled(count == 0 || artifactTemplateConfirmedSource == source)
        }
    }

    private func waveformComparisonDetail(_ result: ArtifactTemplateDetectionResult, signal: MFFSignalData) -> String {
        let allChannelText = result.comparisonEvents.count == result.selectedEvents.count
            ? "all-channel same"
            : "all-channel \(result.comparisonEvents.count)"
        return "\(artifactTemplateSelectedChannels(in: signal).count) selected · \(allChannelText)"
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
        artifactScanCompleted = 0
        artifactScanTotal = 0
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                ArtifactTemplateDetector.detectTopography(in: signal, configuration: configuration) { completed, total in
                    Task { @MainActor in
                        self.artifactScanCompleted = completed
                        self.artifactScanTotal = total
                    }
                }
            }.value
            // Ignore stale completions: a newer refresh has superseded this one
            // and will publish its own result (and clear the spinner).
            guard generation == topographyRefreshGeneration else { return }
            artifactTemplateResult?.topographyEvents = outcome.events
            artifactTemplateResult?.topographyReference = outcome.reference
            artifactTrajectorySelectedFrame = nil
            isRefreshingTopography = false
        }
    }

    private func artifactWaveformResultView(_ result: ArtifactTemplateDetectionResult, signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

            if let average = result.templateAverage {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Strongest average channels")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        ForEach(average.channelSummaries.prefix(8)) { summary in
                            Button {
                                selectArtifactTemplateChannel(summary.channelIndex, autoApplyIn: signal)
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
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func artifactTopographyResultView(_ topography: ArtifactTemplateTopography) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Label("Scalp-topography template", systemImage: "circle.grid.3x3.fill")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(topography.channelIndices.count) channels · \(artifactTopographyMetric.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            artifactTopographyMapView(topography)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The template scalp map. For trajectory mode shows a clickable frame strip;
    /// for single-map modes shows a single topomap.
    @ViewBuilder
    private func artifactTopographyMapView(_ topography: ArtifactTemplateTopography) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Scalp topography")
                    .font(.caption.weight(.semibold))
                if isRefreshingTopography {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Text(topography.mode.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Trajectory strip — only shown when frames are available
            if let frames = topography.trajectoryDisplayFrames, frames.count > 1 {
                trajectoryFrameStrip(frames: frames, topography: topography)
            }

            // Large topomap — uses selected frame if clicked, else default
            let displayValues: [Double] = {
                let vals = artifactTrajectorySelectedFrame?.channelValues ?? topography.channelValues
                return vals.map(Double.init)
            }()
            let displayTime: Double =
                artifactTrajectorySelectedFrame?.timeSeconds ?? topography.referenceTimeSeconds

            if let layout = recording.sensorLayout {
                TopomapView(
                    layout: layout,
                    values: displayValues,
                    timeSeconds: displayTime,
                    fixedScale: nil,
                    showsHeader: false,
                    colorBarPlacement: .trailing,
                    minimumMapHeight: 150
                )
                .frame(width: 230, height: 170)

                if let frame = artifactTrajectorySelectedFrame {
                    Text(String(format: "+%.0f ms", frame.relativeSeconds * 1000))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No sensor layout — topography matching still ran.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 230, height: 170, alignment: .topLeading)
            }
        }
    }

    /// Horizontal strip of small topomap thumbnails for trajectory mode.
    /// Each thumbnail shows one sampled frame; a GFP bar above indicates amplitude.
    /// Clicking a thumbnail selects it and updates the large display below.
    @ViewBuilder
    private func trajectoryFrameStrip(
        frames: [ArtifactTrajectoryFrame],
        topography: ArtifactTemplateTopography
    ) -> some View {
        let thumbW: CGFloat = 72
        let thumbH: CGFloat = 64

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text("Trajectory frames")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if artifactTrajectorySelectedFrame != nil {
                    Button("Clear") { artifactTrajectorySelectedFrame = nil }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(frames) { frame in
                        trajectoryFrameThumb(
                            frame: frame,
                            thumbW: thumbW,
                            thumbH: thumbH
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func trajectoryFrameThumb(
        frame: ArtifactTrajectoryFrame,
        thumbW: CGFloat,
        thumbH: CGFloat
    ) -> some View {
        let isSelected = artifactTrajectorySelectedFrame?.frameIndex == frame.frameIndex
        let borderColor: Color = isSelected ? Color.accentColor : Color.clear

        VStack(spacing: 2) {
            Group {
                if let layout = recording.sensorLayout {
                    TopomapView(
                        layout: layout,
                        values: frame.channelValues.map(Double.init),
                        timeSeconds: frame.timeSeconds,
                        fixedScale: nil,
                        showsHeader: false,
                        colorBarPlacement: .trailing,
                        minimumMapHeight: thumbH
                    )
                    .frame(width: thumbW, height: thumbH)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: thumbW, height: thumbH)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(borderColor, lineWidth: 2)
            )

            Text(String(format: "+%.0f ms", frame.relativeSeconds * 1000))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            artifactTrajectorySelectedFrame = isSelected ? nil : frame
        }
    }

    private func useWaveformMatches(_ result: ArtifactTemplateDetectionResult, signal: MFFSignalData) {
        guard let range = artifactTemplateSelectionRange else { return }
        let configuration = artifactTemplateConfiguration(for: signal, range: range)
        upsertDefinedArtifact(from: result, configuration: configuration, source: .waveform)
        artifactEvents = definedArtifacts.flatMap(\.events)
        selectedEventCodes = [configuration.eventCode]
        showsEventsPanel = true
        artifactTemplateConfirmedSource = .waveform
        artifactStatusMessage = "\(result.selectedEvents.count) waveform matches"
    }

    private func useTopographyMatches(_ result: ArtifactTemplateDetectionResult, signal: MFFSignalData? = nil) {
        if let range = artifactTemplateSelectionRange,
           let signalForConfiguration = signal ?? recording.signal {
            let configuration = artifactTemplateConfiguration(for: signalForConfiguration, range: range)
            upsertDefinedArtifact(from: result, configuration: configuration, source: .topography)
        } else if let artifactID = artifactTemplateDefinedArtifactID,
                  let index = definedArtifacts.firstIndex(where: { $0.id == artifactID }) {
            definedArtifacts[index].events = result.topographyEvents
            definedArtifacts[index].topography = result.topographyReference
            invalidateOBSVarianceCache(for: artifactID)
            clearAppliedArtifactCleaning()
        }
        artifactEvents = definedArtifacts.isEmpty ? result.topographyEvents : definedArtifacts.flatMap(\.events)
        selectedEventCodes = [artifactTemplateEventCode.trimmingCharacters(in: .whitespacesAndNewlines)]
        showsEventsPanel = true
        artifactTemplateConfirmedSource = .topography
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

    private func selectArtifactTemplateChannel(_ channelIndex: Int, autoApplyIn signal: MFFSignalData? = nil) {
        artifactTemplateClickedChannel = channelIndex
        selectedArtifactTemplateChannel = channelIndex
        artifactTemplateChannelScope = .clickedChannel
        artifactTemplateCustomChannels = "\(channelIndex + 1)"
        guard let signal,
              !isApplyingArtifactTemplate else {
            return
        }
        if artifactTemplateResult != nil {
            applyArtifactTemplate(to: signal, preferredSource: .waveform)
        }
    }

    private func applyArtifactTemplate(
        to signal: MFFSignalData,
        preferredSource: ArtifactDefinitionResultSource = .waveform
    ) {
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
        artifactScanCompleted = 0
        artifactScanTotal = 0

        let signature = artifactScanSignature
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ArtifactTemplateDetector.detect(in: signal, configuration: configuration) { completed, total in
                    Task { @MainActor in
                        self.artifactScanCompleted = completed
                        self.artifactScanTotal = total
                    }
                }
            }.value

            artifactTemplateResult = result
            lastArtifactScanSignature = signature
            selectedArtifactTemplateChannel = nil
            let source: ArtifactDefinitionResultSource = preferredSource == .topography ? .topography : .waveform
            upsertDefinedArtifact(from: result, configuration: configuration, source: source)
            artifactEvents = definedArtifacts.flatMap(\.events)
            selectedEventCodes = [configuration.eventCode]
            showsEventsPanel = true
            artifactTemplateConfirmedSource = source
            artifactStatusMessage = source == .topography
                ? "\(result.topographyEvents.count) topography matches"
                : "\(result.selectedEvents.count) template matches"
            isApplyingArtifactTemplate = false
        }
    }

    private func upsertDefinedArtifact(
        from result: ArtifactTemplateDetectionResult,
        configuration: ArtifactTemplateConfiguration,
        source: ArtifactDefinitionResultSource = .waveform
    ) {
        let name = configuration.name.nilIfEmpty ?? "Artifact"
        let eventCode = configuration.eventCode.nilIfEmpty ?? name
        let selectedEvents = source == .topography ? result.topographyEvents : result.selectedEvents
        let artifact = DefinedArtifact(
            id: artifactTemplateDefinedArtifactID ?? UUID(),
            type: artifactTemplateType,
            name: name,
            eventCode: eventCode,
            events: selectedEvents,
            selectedChannelIndices: configuration.selectedChannelIndices,
            windowSizeSeconds: configuration.windowSizeSeconds,
            average: result.templateAverage,
            topography: source == .topography ? result.topographyReference : nil,
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
            artifactTemplateConfirmedSource = nil
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
        artifactTemplateConfirmedSource = nil
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

    // MARK: - Wavelet reduction

    private func openWaveletReductionSheet(input: MFFSignalData) {
        // Initialize the config from the current mode's defaults for this rate
        // unless a run already established settings.
        if waveletReductionResult == nil {
            waveletReductionConfig = waveletReductionMode.defaultConfiguration(samplingRate: input.samplingRate)
        }
        showsWaveletReductionSheet = true
    }

    private func setWaveletReductionEnabled(_ isEnabled: Bool) {
        guard waveletReducedSignal != nil, waveletReductionIsEnabled != isEnabled else { return }
        waveletReductionIsEnabled = isEnabled
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    private func revertWaveletReduction() {
        guard waveletReducedSignal != nil else { return }
        waveletReducedSignal = nil
        waveletReductionArtifact = nil
        waveletReductionResult = nil
        waveletReductionBandVarianceRetained = nil
        waveletReductionStatusMessage = "Reverted wavelet reduction."
        waveletReductionCandidates = []
        selectedWaveletCandidateID = nil
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
        artifactDetectionRefreshToken += 1
    }

    private func runWaveletReduction(on input: MFFSignalData) {
        guard !isRunningWaveletReduction else { return }
        let config = waveletReductionConfig
        let mode = waveletReductionMode
        let cores = waveletReductionCoreCount
        let analysisBand = (low: filterLowCutoff, high: filterHighCutoff)
        // Leave bad channels untouched; reduce everything else.
        let reduceIndices = input.data.indices.filter { !channels.bad.contains($0) }

        isRunningWaveletReduction = true
        waveletReductionProgress = 0
        waveletReductionStatusMessage = "Running wavelet reduction…"
        waveletReductionBandVarianceRetained = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            waveletReductionProgress = min(max(fraction, 0), 1)
        }

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                WaveletReducer.reduce(
                    signal: input,
                    channelIndices: Array(reduceIndices),
                    configuration: config,
                    coreCount: cores
                ) { fraction in
                    progressContinuation.yield(fraction * (mode.assessesInBand ? 0.8 : 1.0))
                }
            }.value

            // ERP path: assess variance retained within the analysis band, as HAPPE does.
            var bandRetained: Double?
            if mode.assessesInBand,
               analysisBand.high > analysisBand.low,
               analysisBand.high < input.samplingRate / 2 {
                bandRetained = await Task.detached(priority: .utility) {
                    await bandLimitedVarianceRetained(
                        original: input,
                        cleaned: result.cleaned,
                        channelIndices: Array(reduceIndices),
                        band: analysisBand
                    )
                }.value
            }

            progressContinuation.finish()
            progressTask.cancel()

            waveletReducedSignal = result.cleaned
            waveletReductionArtifact = result.artifact
            waveletReductionResult = result
            waveletReductionBandVarianceRetained = bandRetained
            waveletReductionCandidates = WaveletReducer.findCandidates(
                artifact: result.artifact,
                channelIndices: Array(reduceIndices),
                maxCount: 40
            )
            selectedWaveletCandidateID = waveletReductionCandidates.first?.id
            waveletReductionIsEnabled = true
            isRunningWaveletReduction = false
            waveletReductionProgress = 1
            let varianceText = String(format: "%.1f%%", result.varianceRetainedPercent)
            waveletReductionStatusMessage = "Reduced \(reduceIndices.count) channels · \(varianceText) variance retained · r \(String(format: "%.2f", result.meanCorrelation))"
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
            artifactDetectionRefreshToken += 1
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
        let (progressContinuation, progressTask) = ProgressBridge.make { progress in
            artifactCleaningProgress = progress
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
            topographyMetric: artifactTopographyMetric,
            trajectoryShiftSeconds: artifactTrajectoryShiftSeconds,
            trajectoryScaleRange: artifactTrajectoryScaleRange,
            trajectoryGFPWeighted: artifactTrajectoryGFPWeighted
        )
    }

    /// Channels used for the scalp-topography correlation: all readable channels
    /// minus bad channels (and, in future, restricted to a selected cluster).
    private func artifactTopographyChannels(in signal: MFFSignalData) -> [Int] {
        let goodChannels = signal.data.indices.filter { !channels.bad.contains($0) }
        switch artifactTopographyChannelScope {
        case .allGood:
            return goodChannels
        case .topN:
            guard let range = artifactTemplateSelectionRange,
                  !goodChannels.isEmpty else { return goodChannels }
            let n = max(min(artifactTopographyTopN, goodChannels.count), 3)
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
                        help: "PCA variance target used to choose how many components to keep, capped by the Components field. 99.9% is a practical default for preserving blink components while still avoiding near-zero noisy directions."
                    )
                    TextField("Fraction", value: $icaVarianceThreshold, format: .number.precision(.fractionLength(3)))
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
                    TextField("Tolerance", value: $icaConvergenceTolerance, format: .number.notation(.scientific).precision(.significantDigits(2...4)))
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

                if let icaDecomposition, !icaDecomposition.excludedComponents.isEmpty {
                    Button("Synthesize as PNS Channel") {
                        synthesizeICAAsPNS(decomposition: icaDecomposition, signal: signal)
                    }
                    .help("Sum the checked component activations and add them as a new physio (PNS) channel.")
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

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: ICAProgressUpdate) in
            icaProgress = min(max(update.fraction, 0), 1)
            icaProgressMessage = update.message
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
                    filterStatusIsError = true
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
                    filterStatusIsError = true
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
            "Keep variance field: \(String(format: "%.3f", icaVarianceThreshold))",
            "Average reference field: \(icaUsesAverageReference ? "on" : "off")",
            "Search Hz field: \(String(format: "%.1f", icaDownsampleRate))",
            "Iterations field: \(icaMaxIterations)",
            "Fit filter field: \(icaUsesFitFilter ? "on" : "off")",
            "Fit Hz field: \(String(format: "%.2f", icaFitLowCutoff))-\(String(format: "%.2f", icaFitHighCutoff)), notch \(icaFitNotch60HzEnabled ? "on" : "off")",
            "Tolerance field: \(String(format: "%.3e", icaConvergenceTolerance))",
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
        reconcilePSAEventSelection(for: events)
        psaStatusMessage = nil
        showsPSASheet = true
    }

    private func reconcilePSAEventSelection(for events: [MFFEvent]) {
        let summaries = groupedPSAEventSummaries(events)
        let availableValues = Set(summaries.map(\.code))
        psaSelectedEventCodes = psaSelectedEventCodes.intersection(availableValues)
        for summary in summaries where psaCategoryNames[summary.code] == nil {
            psaCategoryNames[summary.code] = summary.code
        }
        var enabledTimingValues = psaTimingMarkerEnabledValues.intersection(availableValues)
        var timingMarkerValues = psaTimingMarkerValuesBySegmentValue.filter { segmentValue, timingValue in
            availableValues.contains(segmentValue)
                && availableValues.contains(timingValue)
                && segmentValue != timingValue
        }
        var timingValuesWithoutOptions = Set<String>()
        for segmentValue in enabledTimingValues {
            let options = psaTimingMarkerOptions(in: summaries, excluding: segmentValue)
            if let currentValue = timingMarkerValues[segmentValue],
               options.contains(where: { $0.code == currentValue }) {
                continue
            }
            if let defaultValue = options.first?.code {
                timingMarkerValues[segmentValue] = defaultValue
            } else {
                timingValuesWithoutOptions.insert(segmentValue)
                timingMarkerValues[segmentValue] = nil
            }
        }
        enabledTimingValues.subtract(timingValuesWithoutOptions)
        psaTimingMarkerEnabledValues = enabledTimingValues
        psaTimingMarkerValuesBySegmentValue = timingMarkerValues
    }

    private func segmentableEvents(for signal: MFFSignalData) -> [MFFEvent] {
        switch psaSegmentField {
        case .artifact:
            return artifactEvents.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        case .code, .label:
            return (signal.events + userMarkerEvents).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        }
    }

    private func psaSheet(for signal: MFFSignalData) -> some View {
        let events = segmentableEvents(for: signal)
        let allSummaries = groupedPSAEventSummaries(events)
        let summaries = filteredPSAEventSummaries(allSummaries)
        let segmentFieldBinding = Binding<PSASegmentField>(
            get: { psaSegmentField },
            set: { newField in
                psaSegmentField = newField
                reconcilePSAEventSelection(for: events)
            }
        )

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
                HStack {
                    Text("Segment On")
                        .font(.caption.weight(.semibold))
                    Picker("Segment On", selection: segmentFieldBinding) {
                        ForEach(PSASegmentField.allCases) { field in
                            Text(field.rawValue).tag(field)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)

                    Spacer(minLength: 12)

                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter events", text: $psaEventSearchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    if !psaEventSearchText.isEmpty {
                        Button {
                            psaEventSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear filter")
                    }
                }

                if allSummaries.isEmpty {
                    ContentUnavailableView(
                        psaSegmentField == .artifact ? "No Artifacts Detected" : "No Events",
                        systemImage: psaSegmentField == .artifact ? "waveform.path.ecg.rectangle" : "list.bullet.rectangle",
                        description: Text(psaSegmentField == .artifact
                            ? "Enable eye blink, eye movement, or ECG/QRS detection in the Artifacts panel first."
                            : "This recording has no events to segment on.")
                    )
                    .frame(height: 120)
                } else if summaries.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "magnifyingglass",
                        description: Text("No artifact types match the filter.")
                    )
                    .frame(height: 120)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(summaries) { summary in
                                psaSegmentEventRow(summary: summary, allSummaries: allSummaries)
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
                        .help("Ignored for categories that use a DIN timing marker.")

                    Text("DIN Tolerance (s)")
                        .font(.caption.weight(.semibold))
                    let missedCount = psaMissedDINCount(events: events)
                    HStack(spacing: 8) {
                        TextField("Tolerance", value: $psaTimingTolerance, format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .help("Maximum time between an event and a DIN marker for them to be paired. Events with no DIN within this window are skipped.")
                        if missedCount > 0 {
                            Label("\(missedCount) unmatched", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("\(missedCount) selected event\(missedCount == 1 ? "" : "s") have no DIN within ±\(String(format: "%.3f", psaTimingTolerance)) s and will be skipped.")
                        }
                    }
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
                if psaIsApplying {
                    ProgressView()
                        .controlSize(.small)
                    Text(psaPhaseMessage ?? "Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    showsPSASheet = false
                }
                .disabled(psaIsApplying)
                Button("Apply") {
                    Task { await applyPSA(to: signal) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApplyPSA(events: events) || psaIsApplying)
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    private func psaSegmentEventRow(summary: EventSummary, allSummaries: [EventSummary]) -> some View {
        let timingOptions = psaTimingMarkerOptions(in: allSummaries, excluding: summary.code)
        let isSelected = psaSelectedEventCodes.contains(summary.code)
        let usesTimingMarker = psaTimingMarkerEnabledValues.contains(summary.code)

        return HStack(spacing: 12) {
            Toggle(isOn: psaEventCodeBinding(summary.code)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.code)
                        .font(.system(.body, design: .monospaced))
                    if let detail = summary.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 150, alignment: .leading)

            Text("\(summary.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            TextField("Category", text: psaCategoryBinding(summary.code))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 170)
                .disabled(!isSelected)

            Toggle("DIN", isOn: psaTimingMarkerEnabledBinding(summary.code, options: timingOptions))
                .toggleStyle(.checkbox)
                .disabled(!isSelected || timingOptions.isEmpty)
                .help("Use the nearest selected timing marker as this category's onset.")

            Picker("Timing Marker", selection: psaTimingMarkerSelectionBinding(summary.code, options: timingOptions)) {
                if timingOptions.isEmpty {
                    Text("No markers").tag("")
                } else {
                    ForEach(timingOptions) { option in
                        Text(option.code).tag(option.code)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 128)
            .disabled(!isSelected || !usesTimingMarker || timingOptions.isEmpty)
            .help("Marker group whose nearest event supplies the true onset time.")
        }
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
                    psaTimingMarkerEnabledValues.remove(code)
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

    private func psaTimingMarkerEnabledBinding(_ segmentValue: String, options: [EventSummary]) -> Binding<Bool> {
        Binding(
            get: { psaTimingMarkerEnabledValues.contains(segmentValue) },
            set: { isEnabled in
                if isEnabled {
                    psaTimingMarkerEnabledValues.insert(segmentValue)
                    if let currentValue = psaTimingMarkerValuesBySegmentValue[segmentValue],
                       options.contains(where: { $0.code == currentValue }) {
                        return
                    }
                    psaTimingMarkerValuesBySegmentValue[segmentValue] = options.first?.code
                } else {
                    psaTimingMarkerEnabledValues.remove(segmentValue)
                }
            }
        )
    }

    private func psaTimingMarkerSelectionBinding(_ segmentValue: String, options: [EventSummary]) -> Binding<String> {
        Binding(
            get: {
                let validOptions = Set(options.map(\.code))
                if let currentValue = psaTimingMarkerValuesBySegmentValue[segmentValue],
                   validOptions.contains(currentValue) {
                    return currentValue
                }
                return options.first?.code ?? ""
            },
            set: { newValue in
                if options.contains(where: { $0.code == newValue }) {
                    psaTimingMarkerValuesBySegmentValue[segmentValue] = newValue
                }
            }
        )
    }

    private func psaTimingMarkerOptions(in summaries: [EventSummary], excluding segmentValue: String) -> [EventSummary] {
        summaries.filter { $0.code != segmentValue }
    }

    private func canApplyPSA(events: [MFFEvent]) -> Bool {
        !events.isEmpty
            && !psaSelectedEventCodes.isEmpty
            && psaPreStimulus >= 0
            && psaPostStimulus > 0
            && selectedPSACategoriesByCode() != nil
            && selectedPSATimingMarkersBySegmentValue(events: events) != nil
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

    private func selectedPSATimingMarkersBySegmentValue(events: [MFFEvent]) -> [String: String]? {
        let availableValues = Set(groupedPSAEventSummaries(events).map(\.code))
        var timingMarkersBySegmentValue = [String: String]()
        for segmentValue in psaSelectedEventCodes where psaTimingMarkerEnabledValues.contains(segmentValue) {
            guard let timingValue = psaTimingMarkerValuesBySegmentValue[segmentValue],
                  availableValues.contains(timingValue),
                  timingValue != segmentValue else {
                return nil
            }
            timingMarkersBySegmentValue[segmentValue] = timingValue
        }
        return timingMarkersBySegmentValue
    }

    private func applyPSA(to signal: MFFSignalData) async {
        // Validate and capture all inputs on the main actor before going off-thread.
        guard let job = psaBuildJob(from: signal) else { return }
        let shouldAverage = psaAverageOnApply
        let shouldAvgRef = psaAverageReference
        let shouldBaseline = psaBaselineCorrected
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()

        psaIsApplying = true
        psaPhaseMessage = "Segmenting…"

        let built = await Task.detached(priority: .userInitiated) {
            job.buildEpochs()
        }.value

        guard let built else {
            psaIsApplying = false
            psaPhaseMessage = nil
            return
        }

        // Keep raw epochs as source so post-processing can be toggled later.
        segmentedEpochSignal = built.signal
        segmentedEpochSegments = built.segments

        let finalResult: PSABuildResult
        let wasAveraged: Bool
        if shouldAverage {
            psaPhaseMessage = "Averaging…"
            let colorIndices = categoryColorIndices(for: built.segments.map(\.category))
            let averagedOpt = await Task.detached(priority: .userInitiated) {
                built.average(colorIndices: colorIndices)
            }.value
            guard let averaged = averagedOpt else {
                psaIsApplying = false
                psaPhaseMessage = nil
                psaStatusMessage = "No averages could be computed."
                return
            }
            psaPhaseMessage = "Post-processing…"
            finalResult = await Task.detached(priority: .userInitiated) {
                averaged.postProcessed(averageReference: shouldAvgRef, baselineCorrect: shouldBaseline, badChannels: badChannels)
            }.value
            wasAveraged = true
        } else {
            psaPhaseMessage = "Post-processing…"
            finalResult = await Task.detached(priority: .userInitiated) {
                built.postProcessed(averageReference: shouldAvgRef, baselineCorrect: shouldBaseline, badChannels: badChannels)
            }.value
            wasAveraged = false
        }

        epochedSignal = finalResult.signal
        epochSegments = finalResult.segments
        psaIsAveraged = wasAveraged
        if !wasAveraged { showsButterflyPlot = false }
        psaStatusMessage = finalResult.message + suffix
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        topomapSample = nil
        butterflyTopomapRelativeSample = nil
        selectedEventCodes.removeAll()
        horizontalScrollPosition.scrollTo(x: 0)
        psaIsApplying = false
        psaPhaseMessage = nil
        showsPSASheet = false
    }

    /// Validates PSA inputs on the main actor and packages them into a Sendable job
    /// that can run epoch-slicing off the main thread.
    private func psaBuildJob(from signal: MFFSignalData) -> PSABuildJob? {
        guard let categoriesBySegmentValue = selectedPSACategoriesByCode() else {
            psaStatusMessage = "Enter a category name for each selected event."
            return nil
        }
        let allEvents = segmentableEvents(for: signal)
            .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        guard let timingMarkersBySegmentValue = selectedPSATimingMarkersBySegmentValue(events: allEvents) else {
            psaStatusMessage = "Choose a timing marker for each DIN-adjusted event."
            return nil
        }
        let timingEventsBySegmentValue = Dictionary(grouping: allEvents, by: psaSegmentValue(for:))
        for (segmentValue, timingValue) in timingMarkersBySegmentValue {
            guard timingEventsBySegmentValue[timingValue]?.isEmpty == false else {
                psaStatusMessage = "No \(timingValue) timing markers found for \(segmentValue)."
                return nil
            }
        }
        let events = allEvents.filter { psaSelectedEventCodes.contains(psaSegmentValue(for: $0)) }
        guard !events.isEmpty else {
            psaStatusMessage = psaSegmentField == .artifact
                ? "Select at least one artifact type."
                : "Select at least one event \(psaSegmentField.rawValue.lowercased())."
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
        return PSABuildJob(
            signal: signal,
            events: events,
            categoriesBySegmentValue: categoriesBySegmentValue,
            timingMarkersBySegmentValue: timingMarkersBySegmentValue,
            timingEventsBySegmentValue: timingEventsBySegmentValue,
            artifactEventsForRejection: psaArtifactEventsForRejection(in: signal),
            preSamples: preSamples,
            epochLength: epochLength,
            psaOffset: psaOffset,
            sampleCount: sampleCount,
            colorIndices: categoryColorIndices(for: Array(categoriesBySegmentValue.values)),
            skipIfContainsArtifact: psaSkipIfContainsArtifact && psaSegmentField != .artifact,
            artifactRejectionLabel: psaArtifactRejectionLabel(),
            timingTolerance: psaTimingTolerance
        )
    }

    /// Count of selected events that have no DIN candidate within the current tolerance window.
    /// Used for the live unmatched-DIN warning in the PSA sheet.
    private func psaMissedDINCount(events: [MFFEvent]) -> Int {
        let tolerance = psaTimingTolerance
        var missed = 0
        for event in events {
            let segValue = psaSegmentValue(for: event)
            guard psaTimingMarkerEnabledValues.contains(segValue),
                  let timingValue = psaTimingMarkerValuesBySegmentValue[segValue] else { continue }
            let candidates = events.filter { psaSegmentValue(for: $0) == timingValue }
            let hasMatch = candidates.contains { abs($0.beginTimeSeconds - event.beginTimeSeconds) <= tolerance }
            if !hasMatch { missed += 1 }
        }
        return missed
    }

    private func nearestPSATimingEvent(to event: MFFEvent, in candidates: [MFFEvent]) -> MFFEvent? {
        candidates.min { lhs, rhs in
            let lhsDistance = abs(lhs.beginTimeSeconds - event.beginTimeSeconds)
            let rhsDistance = abs(rhs.beginTimeSeconds - event.beginTimeSeconds)
            if lhsDistance == rhsDistance {
                return lhs.beginTimeSeconds < rhs.beginTimeSeconds
            }
            return lhsDistance < rhsDistance
        }
    }

    private func psaArtifactEventsForRejection(in signal: MFFSignalData) -> [MFFEvent] {
        // When segmenting on artifacts themselves, don't reject epochs for containing those artifacts.
        guard psaSkipIfContainsArtifact, psaSegmentField != .artifact else { return [] }

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
        let shouldAvgRef = psaAverageReference
        let shouldBaseline = psaBaselineCorrected
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()
        let base = PSABuildResult(
            signal: segmentedEpochSignal,
            segments: segmentedEpochSegments,
            message: "\(segmentedEpochSegments.count) epochs"
        )
        let colorIndices = categoryColorIndices(for: base.segments.map(\.category))
        Task {
            let averagedOpt = await Task.detached(priority: .userInitiated) {
                base.average(colorIndices: colorIndices)
            }.value
            guard let averaged = averagedOpt else {
                psaStatusMessage = "No averages could be computed."
                return
            }
            let display = await Task.detached(priority: .userInitiated) {
                averaged.postProcessed(averageReference: shouldAvgRef, baselineCorrect: shouldBaseline, badChannels: badChannels)
            }.value
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
            psaStatusMessage = averaged.message + suffix
        }
    }

    private func averageEpochResult(_ result: PSABuildResult) -> PSABuildResult? {
        guard result.signal.samplingRate > 0, !result.segments.isEmpty else {
            psaStatusMessage = "No epochs are available to average."
            return nil
        }
        let colorIndices = categoryColorIndices(for: result.segments.map(\.category))
        return result.average(colorIndices: colorIndices)
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
        let shouldAvgRef = psaAverageReference
        let shouldBaseline = psaBaselineCorrected
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()
        let base = PSABuildResult(
            signal: segmentedEpochSignal,
            segments: segmentedEpochSegments,
            message: "\(segmentedEpochSegments.count) epochs"
        )
        let isAveraged = psaIsAveraged
        let colorIndices = categoryColorIndices(for: base.segments.map(\.category))
        Task {
            let result: PSABuildResult
            if isAveraged {
                let averagedOpt2 = await Task.detached(priority: .userInitiated) {
                    base.average(colorIndices: colorIndices)
                }.value
                guard let averaged = averagedOpt2 else { return }
                result = averaged
            } else {
                result = base
            }
            let display = await Task.detached(priority: .userInitiated) {
                result.postProcessed(averageReference: shouldAvgRef, baselineCorrect: shouldBaseline, badChannels: badChannels)
            }.value
            epochedSignal = display.signal
            epochSegments = display.segments
            psaStatusMessage = result.message + suffix
        }
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

        // Build the real PNS signal with any user renames applied.
        let renamedPNS = pnsSignalWithRenames()

        // If synthetic ICA channels exist, ask whether to include them.
        let includeSynthetic: Bool
        if !syntheticPNSChannels.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Include synthesized ICA channels?"
            let names = syntheticPNSChannels.map(\.name).joined(separator: ", ")
            alert.informativeText = "The following synthetic PNS channels were created from ICA components: \(names). Include them in the exported MFF?"
            alert.addButton(withTitle: "Include")
            alert.addButton(withTitle: "Skip")
            includeSynthetic = alert.runModal() == .alertFirstButtonReturn
        } else {
            includeSynthetic = false
        }

        // Merge real PNS + (optionally) synthetic channels into a single signal.
        let pnsForExport: MFFSignalData?
        if includeSynthetic {
            pnsForExport = mergingWithSynthetic(base: renamedPNS)
        } else {
            pnsForExport = renamedPNS
        }

        isExportingMFF = true
        mffExportStatusMessage = "Exporting \(snapshot.kind.statusName) MFF..."

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    try MFFWriter.write(
                        signal: snapshot.signal,
                        pnsSignal: pnsForExport,
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

    private var activeFilterLineNoiseMode: FilterLineNoiseMode {
        if filterLineNoiseMode == .adaptiveCleanLine {
            return .adaptiveCleanLine
        }
        return notch60HzEnabled ? .notch : filterLineNoiseMode
    }

    private var filterLineNoiseSummary: String {
        switch activeFilterLineNoiseMode {
        case .off:
            return ""
        case .notch:
            return " + \(String(format: "%.1f", filterLineNoiseFrequency)) Hz notch"
        case .adaptiveCleanLine:
            let harmonics = filterLineNoiseHarmonics > 1 ? " x\(filterLineNoiseHarmonics)" : ""
            return " + CleanLine \(String(format: "%.1f", filterLineNoiseFrequency)) Hz\(harmonics)"
        }
    }

    private func filterPopover(for signal: MFFSignalData) -> some View {
        let lineNoiseMode = activeFilterLineNoiseMode
        let lineNoiseBinding = Binding<FilterLineNoiseMode> {
            activeFilterLineNoiseMode
        } set: { mode in
            filterLineNoiseMode = mode
            notch60HzEnabled = mode == .notch
            if mode != .off {
                showsFilterLineNoiseOptions = true
            }
        }

        return VStack(alignment: .leading, spacing: 14) {
            Text("Band-pass Filter")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("High-Pass Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("Low", value: $filterLowCutoff, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Stepper("", value: $filterLowCutoff, in: 0.1...100, step: 0.1)
                        .labelsHidden()
                    Picker("HP Slope", selection: $filterHighPassSlope) {
                        ForEach(FilterSlope.allCases) { slope in
                            Text(slope.label).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .help("High-pass rolloff slope. 12 dB/oct (2-pole) is gentler and produces less ringing near the cutoff; 24 dB/oct (4-pole) is steeper. Both are applied zero-phase (forward+backward pass).")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Low-Pass Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("High", value: $filterHighCutoff, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Stepper("", value: $filterHighCutoff, in: 0.5...200, step: 0.5)
                        .labelsHidden()
                    Picker("LP Slope", selection: $filterLowPassSlope) {
                        ForEach(FilterSlope.allCases) { slope in
                            Text(slope.label).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
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

                DisclosureGroup("Line Noise Options", isExpanded: $showsFilterLineNoiseOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Frequency")
                                .font(.caption)
                                .frame(width: 76, alignment: .leading)
                            TextField("Hz", value: $filterLineNoiseFrequency, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Stepper("", value: $filterLineNoiseFrequency, in: 45...65, step: 0.5)
                                .labelsHidden()
                        }

                        HStack {
                            Text("Harmonics")
                                .font(.caption)
                                .frame(width: 76, alignment: .leading)
                            Stepper(value: $filterLineNoiseHarmonics, in: 1...4) {
                                Text("\(filterLineNoiseHarmonics)")
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
                                Text(String(format: "%.1fs", filterLineNoiseWindowSeconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $filterLineNoiseWindowSeconds, in: 1...10, step: 0.5)
                        }
                        .disabled(lineNoiseMode != .adaptiveCleanLine)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Strength")
                                    .font(.caption)
                                Spacer()
                                Text(String(format: "%.2fx", filterLineNoiseStrength))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $filterLineNoiseStrength, in: 0.25...1.50, step: 0.05)
                        }
                        .disabled(lineNoiseMode != .adaptiveCleanLine)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .disabled(lineNoiseMode == .off)
            }

            Toggle("Average reference", isOn: $filterAverageReference)
                .help("Re-reference to the common average: subtract the mean across all channels at each time point. Removes shared reference signal.")

            if recording.pnsSignal != nil {
                Toggle("Filter PNS", isOn: $filterPNSChannels)
                    .font(.caption)
                    .help("Apply the band-pass and line-noise filter to physio/PNS channels. Average reference is EEG-only.")
            }

            HStack {
                Button("Reset 0.1–30 Hz") {
                    filterLowCutoff = 0.1
                    filterHighCutoff = 30
                    notch60HzEnabled = false
                    filterLineNoiseMode = .off
                    filterLineNoiseFrequency = 60
                    filterLineNoiseHarmonics = 2
                    filterLineNoiseWindowSeconds = 4
                    filterLineNoiseStrength = 1
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
        .frame(width: 330)
    }

    private nonisolated static func filteredChannels(
        _ sourceData: [[Float]],
        samplingRate: Double,
        lowCutoff: Double,
        highCutoff: Double,
        highPassSlope: FilterSlope = .dB24,
        lowPassSlope: FilterSlope = .dB24,
        lineNoiseMode: FilterLineNoiseMode,
        notchFrequency: Double,
        lineNoiseHarmonics: Int,
        lineNoiseWindowSeconds: Double,
        lineNoiseStrength: Double,
        averageReference: Bool,
        excludedChannels: Set<Int>,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [[Float]] {
        let notchEnabled = lineNoiseMode == .notch
        var bandPassed = try await EEGSignalFilter.bandPass(
            channels: sourceData,
            samplingRate: samplingRate,
            lowCutoff: lowCutoff,
            highCutoff: highCutoff,
            highPassSlope: highPassSlope,
            lowPassSlope: lowPassSlope,
            notch60HzEnabled: notchEnabled,
            notchFrequency: notchFrequency,
            progress: { fraction in
                progress(lineNoiseMode == .adaptiveCleanLine ? 0.62 * fraction : fraction)
            }
        )
        if lineNoiseMode == .adaptiveCleanLine {
            bandPassed = await EEGSignalFilter.adaptiveLineNoiseReduction(
                channels: bandPassed,
                samplingRate: samplingRate,
                baseFrequency: notchFrequency,
                harmonicCount: lineNoiseHarmonics,
                windowSeconds: lineNoiseWindowSeconds,
                strength: lineNoiseStrength,
                progress: { fraction in progress(0.62 + 0.38 * fraction) }
            )
        }
        if averageReference {
            EEGSignalFilter.averageReferenceInPlace(&bandPassed, excluding: excludedChannels)
        }
        return bandPassed
    }

    private func applyBandpassFilter(to signal: MFFSignalData) {
        isFiltering = true
        filterProgress = 0
        filterStatusMessage = nil
        filterStatusIsError = false

        let signalURL = signal.signalURL
        let signalType = signal.signalType
        let numberOfChannels = signal.numberOfChannels
        let samplingRate = signal.samplingRate
        let duration = signal.duration
        let recordingStartTime = signal.recordingStartTime
        let events = signal.events
        let sourceData = signal.data
        let pnsInput = filterPNSChannels ? pnsFilterBaseSignal() : nil
        let lowCutoff = filterLowCutoff
        let highPassSlope = filterHighPassSlope
        let highCutoff = filterHighCutoff
        let lowPassSlope = filterLowPassSlope
        let lineNoiseMode = activeFilterLineNoiseMode
        let lineNoiseFrequency = filterLineNoiseFrequency
        let lineNoiseHarmonics = filterLineNoiseHarmonics
        let lineNoiseWindowSeconds = filterLineNoiseWindowSeconds
        let lineNoiseStrength = filterLineNoiseStrength
        let averageReference = filterAverageReference
        if lineNoiseMode == .adaptiveCleanLine {
            filterStatusMessage = "Filtering, then applying adaptive CleanLine..."
            filterStatusIsError = false
        }

        // Stream per-channel completion fractions to the UI.
        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            filterProgress = fraction
        }

        Task {
            do {
                let badChannels = channels.bad
                let pnsEnabled = pnsInput != nil
                let result = try await Task.detached(priority: .userInitiated) {
                    let filteredData = try await Self.filteredChannels(
                        sourceData,
                        samplingRate: samplingRate,
                        lowCutoff: lowCutoff,
                        highCutoff: highCutoff,
                        highPassSlope: highPassSlope,
                        lowPassSlope: lowPassSlope,
                        lineNoiseMode: lineNoiseMode,
                        notchFrequency: lineNoiseFrequency,
                        lineNoiseHarmonics: lineNoiseHarmonics,
                        lineNoiseWindowSeconds: lineNoiseWindowSeconds,
                        lineNoiseStrength: lineNoiseStrength,
                        averageReference: averageReference,
                        excludedChannels: badChannels,
                        progress: { fraction in
                            progressContinuation.yield(pnsEnabled ? 0.70 * fraction : fraction)
                        }
                    )

                    let filteredPNSData: [[Float]]?
                    if let pnsInput {
                        filteredPNSData = try await Self.filteredChannels(
                            pnsInput.data,
                            samplingRate: pnsInput.samplingRate,
                            lowCutoff: lowCutoff,
                            highCutoff: highCutoff,
                            highPassSlope: highPassSlope,
                            lowPassSlope: lowPassSlope,
                            lineNoiseMode: lineNoiseMode,
                            notchFrequency: lineNoiseFrequency,
                            lineNoiseHarmonics: lineNoiseHarmonics,
                            lineNoiseWindowSeconds: lineNoiseWindowSeconds,
                            lineNoiseStrength: lineNoiseStrength,
                            averageReference: false,
                            excludedChannels: [],
                            progress: { fraction in
                                progressContinuation.yield(0.70 + 0.30 * fraction)
                            }
                        )
                    } else {
                        filteredPNSData = nil
                    }
                    return (filteredData, filteredPNSData)
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
                    data: result.0,
                    channelNames: signal.channelNames
                )
                if let pnsInput, let filteredPNSData = result.1 {
                    filteredPNSSignal = MFFSignalData(
                        signalURL: pnsInput.signalURL,
                        signalType: "\(pnsInput.signalType) filtered",
                        numberOfChannels: pnsInput.numberOfChannels,
                        samplingRate: pnsInput.samplingRate,
                        duration: pnsInput.duration,
                        recordingStartTime: pnsInput.recordingStartTime,
                        events: pnsInput.events,
                        data: filteredPNSData,
                        channelNames: pnsInput.channelNames
                    )
                    filteredPNSInputSignalType = pnsInput.signalType
                } else {
                    filteredPNSSignal = nil
                    filteredPNSInputSignalType = nil
                }
                clearAppliedArtifactCleaning()
                artifactDetectionRefreshToken += 1
                invalidateEpochsForSignalChange()
                invalidateInterpolations()
                filterStatusMessage = "Applied Butterworth \(String(format: "%.1f", lowCutoff))-\(String(format: "%.1f", highCutoff)) Hz\(filterLineNoiseSummary)\(averageReference ? " + average reference" : "")\(pnsInput == nil ? "" : " + PNS")."
                filterStatusIsError = false
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
        filteredPNSSignal = nil
        filteredPNSInputSignalType = nil
        clearAppliedArtifactCleaning()
        filterStatusMessage = "Removed band-pass filter."
        filterStatusIsError = false
        artifactDetectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    // MARK: - MRI gradient artifact removal

    /// Volume-trigger sample indices from the raw recording (events whose code
    /// matches `code`), used as the TR grid for gradient correction.
    private func trMarkerSamples(in signal: MFFSignalData, code: String, samplingRate: Double? = nil) -> [Int] {
        let rate = samplingRate ?? signal.samplingRate
        return signal.events
            .filter { $0.code == code }
            .map { Int(($0.beginTimeSeconds * rate).rounded()) }
            .sorted()
    }

    /// Distinct event codes in the recording with their occurrence counts,
    /// sorted by descending count then code.
    private func eventCodeCounts(in signal: MFFSignalData) -> [(code: String, count: Int)] {
        var counts: [String: Int] = [:]
        for event in signal.events {
            counts[event.code, default: 0] += 1
        }
        return counts
            .map { (code: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
    }

    @ViewBuilder
    private func mriPopover(for signal: MFFSignalData?) -> some View {
        let codeCounts = signal.map(eventCodeCounts) ?? []
        let selectedCount = codeCounts.first { $0.code == mriTRMarkerCode }?.count
        let motionUsable = (motionParameters?.count ?? 0) >= 2
        let motionAlignmentOK = mriMotionAlignmentOK(selectedCount: selectedCount)
        let spacing = trSpacingInfo(for: signal)
        let canApply = signal != nil && !isProcessingMRI && (selectedCount ?? 0) >= 2
            && (mriMethod != .moosmann || motionUsable)
            && motionAlignmentOK
            && spacing.hasEnoughTriggers && spacing.isEvenlySpaced

        VStack(alignment: .leading, spacing: 14) {
            Text("MR Gradient Removal")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Method")
                        .font(.caption.weight(.semibold))
                    Button {
                        showsMRIMethodHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("About AAS vs FASTR and references")
                    .popover(isPresented: $showsMRIMethodHelp, arrowEdge: .trailing) {
                        mriMethodHelp()
                    }
                }
                Picker("Method", selection: $mriMethod) {
                    ForEach(MRIGradientMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("TR Marker Event")
                    .font(.caption.weight(.semibold))
                if codeCounts.isEmpty {
                    Text("No events found in this recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("TR Marker Event", selection: $mriTRMarkerCode) {
                                ForEach(codeCounts, id: \.code) { entry in
                                    Text("\(entry.code)  (\(entry.count))").tag(entry.code)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150, alignment: .leading)
                            if let selectedCount {
                                Text("\(trimmedMarkerCount(total: selectedCount)) of \(selectedCount) \(mriTRMarkerCode) markers used.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No \(mriTRMarkerCode) markers in this recording.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .leading, spacing: 6) {
                            mriSkipControl(
                                title: "Skip First",
                                value: $mriSkipStart,
                                totalMarkers: selectedCount,
                                otherSkip: mriSkipEnd
                            )
                            mriSkipControl(
                                title: "Skip Last",
                                value: $mriSkipEnd,
                                totalMarkers: selectedCount,
                                otherSkip: mriSkipStart
                            )
                        }
                    }

                    if let selectedCount, selectedCount > 0 {
                        mriTRSpacingStatus(spacing: spacing, totalMarkers: selectedCount)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Template Window (neighboring TRs)")
                    .font(.caption.weight(.semibold))
                HStack {
                    Text("Pre")
                        .font(.caption)
                        .frame(width: 36, alignment: .leading)
                    TextField("Pre", value: $mriWindowBefore, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Stepper("", value: $mriWindowBefore, in: 1...64)
                        .labelsHidden()
                }
                HStack {
                    Text("Post")
                        .font(.caption)
                        .frame(width: 36, alignment: .leading)
                    TextField("Post", value: $mriWindowAfter, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Stepper("", value: $mriWindowAfter, in: 1...64)
                        .labelsHidden()
                }
            }

            let motionLoaded = (motionParameters?.count ?? 0) >= 2

            if mriMethod == .moosmann, motionLoaded {
                Text("Using motion: \(motionParameters?.sourceName ?? "") (\(motionParameters?.count ?? 0) vols), threshold \(String(format: "%.2f", motionFDThreshold)) mm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Optional motion-censoring for AAS/FASTR/FARM (Moosmann censors
            // intrinsically, so the toggle is hidden there).
            if motionLoaded, mriMethod != .moosmann {
                Toggle(isOn: $mriExcludeHighMotion) {
                    Text("Exclude high-motion TRs")
                        .font(.caption)
                }
                .help("High-motion volumes (FD over the threshold set in Configure Motion…) are still corrected, but are not used as donors when building artifact templates.")
            }

            if recording.pnsSignal != nil {
                Toggle("Apply to PNS channels", isOn: $mriAppliesToPNS)
                    .font(.caption)
                    .help("Apply the selected MRI gradient artifact correction to physio/PNS channels using the same TR markers.")
            }

            if mriMethod.isFASTR {
                VStack(alignment: .leading, spacing: 8) {
                    Text("FASTR Options")
                        .font(.caption.weight(.semibold))
                    HStack {
                        Text("Slices / volume")
                            .font(.caption)
                            .frame(width: 96, alignment: .leading)
                        TextField("Slices", value: $fastrSlices, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Stepper("", value: $fastrSlices, in: 1...128)
                            .labelsHidden()
                    }
                    .help("Number of fMRI slices per volume. Each TR interval is split into this many slice epochs.")
                    Toggle("Sub-sample alignment", isOn: $fastrSubSample)
                        .font(.caption)
                        .help("FACET-style fractional-sample epoch alignment.")
                    Toggle("OBS residual removal (auto PCs)", isOn: $fastrOBSAuto)
                        .font(.caption)
                        .help("Remove residual artifact via an optimal basis set of residual PCs.")
                    Toggle("Adaptive noise cancellation (ANC)", isOn: $fastrANC)
                        .font(.caption)
                        .help("Apply LMS adaptive noise cancellation after template subtraction.")
                }
            }

            Divider()

            Button {
                showsMRIPopover = false
                showsMotionConfig = true
            } label: {
                Label(motionParameters == nil
                      ? "Configure Motion…"
                      : "Motion: \(motionParameters?.sourceName ?? "") (\(motionParameters?.count ?? 0) TRs)…",
                      systemImage: "slider.horizontal.3")
            }
            .help("Load 3dvolreg motion parameters, plot head motion, and set a motion threshold.")

            if let motionParameters {
                mriMotionAlignmentStatus(motion: motionParameters, selectedCount: selectedCount)
            }

            HStack {
                Button("Reset 4 / 4") {
                    mriWindowBefore = GradientRemover.Window.default.before
                    mriWindowAfter = GradientRemover.Window.default.after
                }

                if gradientCorrectedSignal != nil {
                    Button("Restore Original", role: .destructive) {
                        clearGradientCorrection()
                        showsMRIPopover = false
                    }
                }

                Spacer()

                Button("Apply") {
                    switch mriMethod {
                    case .aas:
                        removeGradientArtifact(from: signal)
                    case .fastr, .moosmann, .farm:
                        removeGradientArtifactFASTR(from: signal)
                    }
                    showsMRIPopover = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
                .help(applyButtonHelp(motionUsable: motionUsable, selectedCount: selectedCount, spacing: spacing, motionAlignmentOK: motionAlignmentOK))
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            // Default to TREV when present; otherwise fall back to the most
            // common event code so the picker always shows a valid selection.
            if !codeCounts.contains(where: { $0.code == mriTRMarkerCode }) {
                if codeCounts.contains(where: { $0.code == "TREV" }) {
                    mriTRMarkerCode = "TREV"
                } else if let first = codeCounts.first {
                    mriTRMarkerCode = first.code
                }
            }
            clampMRITrims(totalMarkers: codeCounts.first { $0.code == mriTRMarkerCode }?.count)
        }
        .onChange(of: mriTRMarkerCode) { _, newCode in
            clampMRITrims(totalMarkers: codeCounts.first { $0.code == newCode }?.count)
        }
    }

    private func clampMRITrims(totalMarkers: Int?) {
        let maximumCombinedSkip = max(0, (totalMarkers ?? 0) - 2)
        mriSkipStart = min(max(mriSkipStart, 0), maximumCombinedSkip)
        mriSkipEnd = min(max(mriSkipEnd, 0), maximumCombinedSkip - mriSkipStart)
    }

    private func mriSkipControl(
        title: String,
        value: Binding<Int>,
        totalMarkers: Int?,
        otherSkip: Int
    ) -> some View {
        let maximum = max(0, (totalMarkers ?? 0) - otherSkip - 2)

        return HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
            Stepper("", value: value, in: 0...maximum)
                .labelsHidden()
        }
        .help("Trim \(title.lowercased()) \(mriTRMarkerCode) markers before running AAS/FASTR correction.")
        .onChange(of: value.wrappedValue) { _, newValue in
            value.wrappedValue = min(max(newValue, 0), maximum)
        }
    }

    private func trimmedMarkerCount(total: Int) -> Int {
        max(total - mriSkipStart - mriSkipEnd, 0)
    }

    private func mriMotionAlignmentOK(selectedCount: Int?) -> Bool {
        guard let motionParameters else { return true }
        guard let selectedCount else { return false }
        return trimmedMarkerCount(total: selectedCount) == motionParameters.count
    }

    @ViewBuilder
    private func mriMotionAlignmentStatus(motion: MotionParameters, selectedCount: Int?) -> some View {
        let usedCount = selectedCount.map(trimmedMarkerCount(total:)) ?? 0
        let matches = selectedCount != nil && usedCount == motion.count
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: matches ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(matches ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(matches
                     ? "Motion file matches \(usedCount) \(mriTRMarkerCode) TRs."
                     : "Motion file has \(motion.count) TRs; current \(mriTRMarkerCode) selection uses \(usedCount).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(matches ? Color.secondary : Color.orange)

                Text(matches
                     ? "\(motion.sourceName), FD threshold \(String(format: "%.2f", motionFDThreshold)) mm."
                     : "Adjust Skip First/Last, choose the matching TR marker event, or clear the motion file before applying.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func mriTRSpacingStatus(spacing: TRSpacingInfo, totalMarkers: Int) -> some View {
        let usedCount = trimmedMarkerCount(total: totalMarkers)
        HStack(spacing: 6) {
            Image(systemName: spacing.isEvenlySpaced ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(spacing.isEvenlySpaced ? Color.secondary : Color.orange)
            if spacing.hasEnoughTriggers {
                Text(spacing.isEvenlySpaced
                     ? "Fixed TR \(String(format: "%.3f", spacing.modeSeconds)) s after trim."
                     : "TRs uneven after trim; correction is disabled.")
            } else {
                Text("Need at least 2 markers after trim; currently using \(usedCount).")
            }
        }
        .font(.caption2)
        .foregroundStyle(spacing.isEvenlySpaced ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// TR markers after trimming `mriSkipStart` events from the start and
    /// `mriSkipEnd` from the end (to align the EEG's TREV events to the motion
    /// file). Returns [] if the skips would leave nothing.
    private func trimmedTRMarkers(in signal: MFFSignalData, code: String, samplingRate: Double? = nil) -> [Int] {
        let all = trMarkerSamples(in: signal, code: code, samplingRate: samplingRate)
        guard all.count > mriSkipStart + mriSkipEnd else { return [] }
        return Array(all[mriSkipStart..<(all.count - mriSkipEnd)])
    }

    private func trSpacingInfo(for signal: MFFSignalData?) -> TRSpacingInfo {
        guard let signal else {
            return TRSpacingInfo.from(triggerSamples: [], samplingRate: 0)
        }
        return TRSpacingInfo.from(
            triggerSamples: trimmedTRMarkers(in: signal, code: mriTRMarkerCode),
            samplingRate: signal.samplingRate
        )
    }

    private func removeGradientArtifact(from signal: MFFSignalData?) {
        guard let signal else { return }

        let trSamples = trimmedTRMarkers(in: signal, code: mriTRMarkerCode)
        let window = GradientRemover.Window(before: mriWindowBefore, after: mriWindowAfter)
        let excludedTRs = highMotionVolumeSet()
        let excludedCount = excludedTRs.count
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
        let pnsInput = mriAppliesToPNS ? recording.pnsSignal : nil
        let pnsTRSamples = pnsInput.map {
            trimmedTRMarkers(in: signal, code: mriTRMarkerCode, samplingRate: $0.samplingRate)
        } ?? []

        // Stream completion fractions from the worker threads to the UI.
        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            mriProgress = fraction
        }

        Task {
            do {
                let hasPNS = pnsInput != nil
                let result = try await Task.detached(priority: .userInitiated) {
                    let correctedData = try GradientRemover.correct(channels: sourceData, trSamples: trSamples, window: window, excludedTRs: excludedTRs) { fraction in
                        progressContinuation.yield(hasPNS ? 0.70 * fraction : fraction)
                    }
                    let correctedPNSData: [[Float]]?
                    if let pnsInput {
                        correctedPNSData = try GradientRemover.correct(channels: pnsInput.data, trSamples: pnsTRSamples, window: window, excludedTRs: excludedTRs) { fraction in
                            progressContinuation.yield(0.70 + 0.30 * fraction)
                        }
                    } else {
                        correctedPNSData = nil
                    }
                    return (correctedData, correctedPNSData)
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
                    data: result.0,
                    channelNames: signal.channelNames
                )
                if let pnsInput, let correctedPNSData = result.1 {
                    gradientCorrectedPNSSignal = MFFSignalData(
                        signalURL: pnsInput.signalURL,
                        signalType: "\(pnsInput.signalType) MRI",
                        numberOfChannels: pnsInput.numberOfChannels,
                        samplingRate: pnsInput.samplingRate,
                        duration: pnsInput.duration,
                        recordingStartTime: pnsInput.recordingStartTime,
                        events: pnsInput.events,
                        data: correctedPNSData,
                        channelNames: pnsInput.channelNames
                    )
                } else {
                    gradientCorrectedPNSSignal = nil
                }
                // The base signal changed, so any band-pass filter computed on
                // the old base is stale.
                icaCleanedSignal = nil
                icaDecomposition = nil
                filteredSignal = nil
                filteredPNSSignal = nil
                filteredPNSInputSignalType = nil
                clearAppliedArtifactCleaning()
                mriStatusMessage = "Applied MRI gradient artifact correction (\(mriTRMarkerCode) markers, template window \(window.before) pre / \(window.after) post TRs\(excludedCount > 0 ? ", \(excludedCount) high-motion TRs excluded" : "")\(pnsInput == nil ? "" : " + PNS"))."
                mriStatusIsError = false
                artifactDetectionRefreshToken += 1
                invalidateEpochsForSignalChange()
                invalidateInterpolations()
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                mriStatusMessage = error.localizedDescription
                mriStatusIsError = true
            }

            isProcessingMRI = false
        }
    }

    /// Volume indices flagged as high-motion (FD > threshold) when the user has
    /// enabled exclusion and motion parameters are loaded; empty otherwise.
    private func highMotionVolumeSet() -> Set<Int> {
        guard mriExcludeHighMotion, let motion = motionParameters, motion.count >= 2 else {
            return []
        }
        return Set(motion.volumesExceeding(threshold: motionFDThreshold, radiusMm: motionRadiusMm))
    }

    private func removeGradientArtifactFASTR(from signal: MFFSignalData?) {
        guard let signal else { return }

        let trSamples = trimmedTRMarkers(in: signal, code: mriTRMarkerCode)
        var config = FastrCorrector.Config()
        config.numberOfSlices = max(1, fastrSlices)
        config.subSampleAlignment = fastrSubSample
        config.obs = fastrOBSAuto ? .auto : .off
        config.anc = fastrANC
        if mriMethod == .moosmann {
            config.templateScheme = .moosmann
            config.motion = motionParameters?.samples
            config.motionThresholdMm = motionFDThreshold
            config.motionRadiusMm = motionRadiusMm
        } else if mriMethod == .farm {
            config.templateScheme = .farm
        }
        // Optional motion-censoring (Moosmann excludes high-motion volumes
        // intrinsically, so only apply the explicit set for the other methods).
        if mriMethod != .moosmann {
            config.censoredVolumes = highMotionVolumeSet()
        }
        let censoredCount = config.censoredVolumes.count
        let methodName = mriMethod.rawValue
        let configCopy = config

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
        let slices = config.numberOfSlices
        let pnsInput = mriAppliesToPNS ? recording.pnsSignal : nil
        let pnsTRSamples = pnsInput.map {
            trimmedTRMarkers(in: signal, code: mriTRMarkerCode, samplingRate: $0.samplingRate)
        } ?? []

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            mriProgress = fraction
        }

        Task {
            do {
                let hasPNS = pnsInput != nil
                let result = try await Task.detached(priority: .userInitiated) {
                    let correctedData = try FastrCorrector.correct(
                        channels: sourceData,
                        volumeTriggers: trSamples,
                        config: configCopy,
                        samplingRate: samplingRate
                    ) { fraction in
                        progressContinuation.yield(hasPNS ? 0.70 * fraction : fraction)
                    }
                    let correctedPNSData: [[Float]]?
                    if let pnsInput {
                        correctedPNSData = try FastrCorrector.correct(
                            channels: pnsInput.data,
                            volumeTriggers: pnsTRSamples,
                            config: configCopy,
                            samplingRate: pnsInput.samplingRate
                        ) { fraction in
                            progressContinuation.yield(0.70 + 0.30 * fraction)
                        }
                    } else {
                        correctedPNSData = nil
                    }
                    return (correctedData, correctedPNSData)
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
                    data: result.0,
                    channelNames: signal.channelNames
                )
                if let pnsInput, let correctedPNSData = result.1 {
                    gradientCorrectedPNSSignal = MFFSignalData(
                        signalURL: pnsInput.signalURL,
                        signalType: "\(pnsInput.signalType) MRI",
                        numberOfChannels: pnsInput.numberOfChannels,
                        samplingRate: pnsInput.samplingRate,
                        duration: pnsInput.duration,
                        recordingStartTime: pnsInput.recordingStartTime,
                        events: pnsInput.events,
                        data: correctedPNSData,
                        channelNames: pnsInput.channelNames
                    )
                } else {
                    gradientCorrectedPNSSignal = nil
                }
                icaCleanedSignal = nil
                icaDecomposition = nil
                filteredSignal = nil
                filteredPNSSignal = nil
                filteredPNSInputSignalType = nil
                clearAppliedArtifactCleaning()
                mriStatusMessage = "Applied \(methodName) correction (\(mriTRMarkerCode) markers, \(slices) slice\(slices == 1 ? "" : "s")/volume\(fastrOBSAuto ? ", OBS" : "")\(fastrANC ? ", ANC" : "")\(censoredCount > 0 ? ", \(censoredCount) high-motion TRs excluded" : "")\(pnsInput == nil ? "" : " + PNS"))."
                mriStatusIsError = false
                artifactDetectionRefreshToken += 1
                invalidateEpochsForSignalChange()
                invalidateInterpolations()
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                mriStatusMessage = error.localizedDescription
                mriStatusIsError = true
            }

            isProcessingMRI = false
        }
    }

    /// Tooltip for the Apply button explaining why it may be disabled.
    private func applyButtonHelp(motionUsable: Bool, selectedCount: Int?, spacing: TRSpacingInfo, motionAlignmentOK: Bool) -> String {
        if (selectedCount ?? 0) < 2 {
            return "Select a TR marker event with at least two markers to enable Apply."
        }
        if !spacing.hasEnoughTriggers {
            return "Too few TR markers after trimming to run correction."
        }
        if !spacing.isEvenlySpaced {
            return "TRs are not evenly spaced"
        }
        if !motionAlignmentOK, let motionParameters, let selectedCount {
            return "Motion file has \(motionParameters.count) TRs, but \(trimmedMarkerCount(total: selectedCount)) \(mriTRMarkerCode) markers are selected after trimming."
        }
        if mriMethod == .moosmann, !motionUsable {
            return "Moosmann requires a motion file. Load one via Configure Motion… to enable Apply."
        }
        return "Apply \(mriMethod.rawValue) gradient artifact removal."
    }

    /// Explanation of the AAS vs FASTR choice with references.
    @ViewBuilder
    private func mriMethodHelp() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gradient Artifact Removal Methods")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("AAS — Average Artifact Subtraction")
                    .font(.subheadline.weight(.semibold))
                Text("Builds one artifact template per TR by averaging neighboring volumes and subtracts it. Fast and robust when motion is low. This is EVA's per-TR template method (Allen et al. 2000).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("FASTR — fMRI Artifact Slice Template Removal")
                    .font(.subheadline.weight(.semibold))
                Text("Subdivides each volume into slice epochs, aligns them (optionally at sub-sample resolution), subtracts a per-slice template, then removes residual artifact with an Optimal Basis Set (OBS) and optional adaptive noise cancellation (ANC). Better suppression, more parameters (Niazy et al. 2005).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Moosmann — RP-informed averaging")
                    .font(.subheadline.weight(.semibold))
                Text("A FASTR variant (Bergen toolbox) that builds each volume's template from a motion-warped temporal window of low-motion volumes — excluding high-motion volumes and avoiding averaging across head-movement events (translation only). Falls back to a plain moving average when no motion exceeds the threshold. Requires loaded motion parameters (Moosmann et al. 2009).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("FARM — most-correlated-epoch averaging")
                    .font(.subheadline.weight(.semibold))
                Text("A FASTR variant whose template, for each artifact, averages the most similar artifacts (highest waveform correlation, ≥ 0.9) rather than temporal neighbors. Robust to motion without needing external motion parameters; selection is derived from the EEG itself (van der Meer et al. 2010, as in FACET).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("References")
                    .font(.caption.weight(.semibold))
                Text("• Allen, Josephs & Turner (2000). NeuroImage 12:230–239.")
                Text("• Niazy, Beckmann, Iannetti, Brady & Smith (2005). NeuroImage 28(3):720–737.")
                Text("• Moosmann et al. (2009). NeuroImage 45(4):1144–1150.")
                Text("• van der Meer et al. (2010). NeuroImage 49(3):2495–2505.")
                Text("• Glaser et al. (2013). FACET toolbox. BMC Neuroscience 14:138.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text("EVA's FASTR is a port of the FMRIB/FACET implementations. See the in-app TODO for pending MATLAB-reference validation.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func clearGradientCorrection() {
        gradientCorrectedSignal = nil
        gradientCorrectedPNSSignal = nil
        icaCleanedSignal = nil
        icaDecomposition = nil
        filteredSignal = nil
        filteredPNSSignal = nil
        filteredPNSInputSignalType = nil
        clearAppliedArtifactCleaning()
        mriStatusMessage = "Removed MRI gradient correction."
        mriStatusIsError = false
        artifactDetectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    // MARK: - Artifact detection

    private func openECGDetectionSheet(for signal: MFFSignalData) {
        prepareECGDetectionDefaults(for: signal, pns: displayedPhysioSignal())
        showsECGDetectionSheet = true
    }

    private func prepareECGDetectionDefaults(for signal: MFFSignalData, pns: MFFSignalData?) {
        if let pns {
            ecgDetectionSelectedPNSChannels = ecgDetectionSelectedPNSChannels
                .filter { pns.data.indices.contains($0) }
            if ecgDetectionSelectedPNSChannels.isEmpty && ecgDetectionProxyChannels.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ecgDetectionSelectedPNSChannels = Set(likelyECGPNSChannelIndices(in: pns))
            }
        } else {
            ecgDetectionSelectedPNSChannels.removeAll()
        }

        let proxyChannels = parseChannelList(ecgDetectionProxyChannels, channelCount: signal.numberOfChannels)
        if proxyChannels.count != Set(proxyChannels).count {
            ecgDetectionProxyChannels = proxyChannels.map { String($0 + 1) }.joined(separator: ", ")
        }
    }

    private func ecgDetectionSheet(for signal: MFFSignalData) -> some View {
        let pns = displayedPhysioSignal()
        let sources = ecgDetectionSources(for: signal)

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ECG / QRS Detection")
                    .font(.headline)
                Text("Select PNS channels, EEG proxy channels, or both. Detected QRS complexes appear as artifact events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if let pns {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("PNS Channels")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Likely ECG") {
                            ecgDetectionSelectedPNSChannels = Set(likelyECGPNSChannelIndices(in: pns))
                        }
                        Button("All") {
                            ecgDetectionSelectedPNSChannels = Set(pns.data.indices)
                        }
                        Button("None") {
                            ecgDetectionSelectedPNSChannels.removeAll()
                        }
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(pns.data.indices), id: \.self) { index in
                                Toggle(pnsChannelDisplayName(index: index, signal: pns), isOn: ecgPNSSelectionBinding(for: index))
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }
            } else {
                Text("No PNS channels are available for this recording. Use EEG proxy channels below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("EEG Proxy Channels")
                    .font(.caption.weight(.semibold))
                TextField("1, 8, 25 or 1-4", text: $ecgDetectionProxyChannels)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Visible Good") {
                        let indices = signal.data.indices.filter { !channels.hidden.contains($0) && !channels.bad.contains($0) }
                        ecgDetectionProxyChannels = indices.map { String($0 + 1) }.joined(separator: ", ")
                    }
                    Button("Clear") {
                        ecgDetectionProxyChannels = ""
                    }
                    Spacer()
                    Text(ecgProxySummary(in: signal))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Detection")
                    .font(.caption.weight(.semibold))

                Picker("Polarity", selection: $ecgDetectionPolarity) {
                    ForEach(ECGDetectionPolarity.allCases) { polarity in
                        Text(polarity.rawValue).tag(polarity)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Text("Threshold")
                        .font(.caption)
                        .frame(width: 86, alignment: .leading)
                    TextField("Threshold", value: $ecgDetectionThresholdSD, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("robust SD")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $ecgDetectionThresholdSD, in: 2...10, step: 0.5)
                }

                HStack {
                    Text("Min RR")
                        .font(.caption)
                        .frame(width: 86, alignment: .leading)
                    TextField("Min RR", value: $ecgDetectionMinimumRRSeconds, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $ecgDetectionMinimumRRSeconds, in: 0.20...1.20, step: 0.05)
                }
            }

            Text(ecgSourceSummary(sources))
                .font(.caption)
                .foregroundStyle(sources.isEmpty ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            ecgAlgorithmComparisonView()

            HStack {
                if detectsECGArtifacts {
                    Button("Disable ECG Detection", role: .destructive) {
                        detectsECGArtifacts = false
                        artifactDetectionRefreshToken += 1
                        showsECGDetectionSheet = false
                    }
                }

                Spacer()

                Button("Cancel") {
                    showsECGDetectionSheet = false
                }
                Button("Detect QRS") {
                    detectsECGArtifacts = true
                    artifactDetectionMethod = .threshold
                    artifactDetectionRefreshToken += 1
                    showsECGDetectionSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sources.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task(id: ecgDetectionPreviewRequestID(for: signal)) {
            await refreshECGDetectionEstimate(for: signal)
        }
        .onAppear {
            prepareECGDetectionDefaults(for: signal, pns: pns)
        }
    }

    // MARK: - BCG Detection sheet

    @ViewBuilder
    private func bcgDetectionSheet(for signal: MFFSignalData, selection: ClosedRange<Int>?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("BCG Detection")
                    .font(.headline)
                Text("Ballistocardiogram artifacts are caused by the heartbeat-driven pulse wave. Choose a method below — each exploits a different signature of BCG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            // Method tab strip
            Picker("Method", selection: $bcgDetectionMethod) {
                ForEach(BCGDetectionMethod.allCases) { method in
                    Text(method.tabLabel).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Method description
            Text(bcgDetectionMethod.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            // Per-method options
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bcgMethodOptions(for: signal, selection: selection)

                    // Shared options
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Output")
                            .font(.caption.weight(.semibold))

                        HStack {
                            Text("Event code")
                                .font(.caption)
                                .frame(width: 100, alignment: .leading)
                            TextField("BCG", text: $bcgEventCode)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("Window")
                                .font(.caption)
                                .padding(.leading, 8)
                            TextField("s", value: $bcgWindowSeconds, format: .number.precision(.fractionLength(3)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Threshold")
                                .font(.caption)
                                .frame(width: 100, alignment: .leading)
                            TextField("SD", value: $bcgThresholdSD, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("robust SD above mean")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $bcgThresholdSD, in: 1...6, step: 0.25)
                        }
                        .opacity(bcgDetectionMethod == .qrsLocking ? 0.35 : 1)
                        .disabled(bcgDetectionMethod == .qrsLocking)
                    }

                    if let status = bcgDetectionStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? Color.green : .secondary)
                    }

                    // Iterative refinement panel — spatial PCA only, shown after detection
                    if bcgDetectionMethod == .spatialPCA && detectsBCGArtifacts {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Iterative Exemplar Refinement")
                                .font(.caption.weight(.semibold))
                            Text("Re-epochs detected beats, scores each by PC1 projection, rejects the weakest fraction, re-averages, and re-detects using the cleaner template.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Reject fraction")
                                    .font(.caption)
                                    .frame(width: 100, alignment: .leading)
                                TextField("%", value: Binding(
                                    get: { bcgRejectFraction * 100 },
                                    set: { bcgRejectFraction = $0 / 100 }
                                ), format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                Text("% of beats removed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $bcgRejectFraction, in: 0.05...0.50, step: 0.05)
                            }

                            if let refined = bcgRefinedTemplate, refined.count == signal.numberOfChannels,
                               let sensorLayout = recording.sensorLayout {
                                HStack(spacing: 12) {
                                    TopomapView(
                                        layout: sensorLayout,
                                        values: refined.map { Double($0) },
                                        timeSeconds: 0,
                                        fixedScale: nil,
                                        showsHeader: false,
                                        colorBarPlacement: .trailing,
                                        minimumMapHeight: 80
                                    )
                                    .frame(width: 90, height: 90)
                                    .clipShape(Circle())

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Refined template")
                                            .font(.caption.weight(.semibold))
                                        if let kept = bcgRefinedKeptCount {
                                            let total = artifactEvents.filter { $0.sourceFile == BCGDetector.sourceFile }.count
                                            Text("Averaged from \(kept) / \(total + (total - kept)) beats")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Action row
            HStack {
                if detectsBCGArtifacts {
                    Button("Disable BCG Detection", role: .destructive) {
                        disableBCGDetection()
                        showsBCGDetectionSheet = false
                    }
                }
                Spacer()
                if isRunningBCGDetection || bcgIsRefining {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") {
                    showsBCGDetectionSheet = false
                }
                if bcgDetectionMethod == .spatialPCA && detectsBCGArtifacts {
                    Button("Refine") {
                        Task { await runBCGRefinement(signal: signal) }
                    }
                    .disabled(bcgIsRefining || isRunningBCGDetection)
                }
                Button("Detect BCG") {
                    Task { await runBCGDetection(signal: signal, selection: selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunningBCGDetection || (bcgDetectionMethod == .qrsLocking && !detectsECGArtifacts))
            }
            .padding(20)
        }
        .frame(width: 560)
        .disabled(isRunningBCGDetection || bcgIsRefining)
    }

    @ViewBuilder
    private func bcgMethodOptions(for signal: MFFSignalData, selection: ClosedRange<Int>?) -> some View {
        switch bcgDetectionMethod {
        case .periodicity:
            VStack(alignment: .leading, spacing: 10) {
                Text("Heart rate range")
                    .font(.caption.weight(.semibold))
                HStack {
                    Text("Min HR")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("BPM", value: $bcgMinHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcgMinHR, in: 30...80, step: 1)
                }
                HStack {
                    Text("Max HR")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("BPM", value: $bcgMaxHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcgMaxHR, in: 60...180, step: 1)
                }
                if selection != nil {
                    Label("Uses all EEG channels; selection ignored for this method.", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case .spatialPCA:
            VStack(alignment: .leading, spacing: 10) {
                Text("Spatial PC extraction")
                    .font(.caption.weight(.semibold))
                if selection != nil {
                    Label("Will derive the BCG spatial map from your highlighted selection.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("No selection — will use the first 30 s of the recording. Highlight a clear BCG exemplar for better results.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(spacing: 10) {
                    Text("Components")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    Stepper("\(bcgPCAComponents)", value: $bcgPCAComponents, in: 1...4)
                        .labelsHidden()
                    Text("\(bcgPCAComponents) PC\(bcgPCAComponents == 1 ? "" : "s") combined via RSS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help("Project onto the top N spatial components and combine scores via root-sum-of-squares. 2–3 components captures BCG sources that span more than one dipole.")

                Toggle(isOn: $bcgSpatialWhiten) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Spatial whitening")
                            .font(.caption)
                        Text("Suppresses alpha / muscle before PCA so BCG stands out")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Equalises all spatial directions by the background covariance before computing the BCG subspace. Reduces contamination from large non-BCG sources in the exemplar PCs.")

                Toggle(isOn: $bcgRespAdaptive) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Respiratory envelope normalization")
                            .font(.caption)
                        Text("6 s sliding RMS — tracks ~0.2 Hz BCG amplitude modulation")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("BCG amplitude is modulated ~10–20% by breathing. A short sliding RMS normalisation keeps sensitivity uniform across the breath cycle, preventing missed beats at respiratory troughs.")

                Toggle(isOn: $bcgSlidingNormalize) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sliding z-score normalization")
                            .font(.caption)
                        Text("30 s window — adapts to slow amplitude drift across the run")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Normalises the detection signal in a 30 s rolling window so the fixed SD threshold adapts to slow changes in BCG amplitude over the course of the recording.")
            }

        case .cardiacPowerMap:
            VStack(alignment: .leading, spacing: 10) {
                Text("Cardiac frequency band")
                    .font(.caption.weight(.semibold))
                HStack {
                    Text("Low cutoff")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("Hz", value: $bcgPowerMinHz, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcgPowerMinHz, in: 0.3...1.5, step: 0.05)
                }
                HStack {
                    Text("High cutoff")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("Hz", value: $bcgPowerMaxHz, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcgPowerMaxHz, in: 0.8...3.0, step: 0.05)
                }
            }

        case .qrsLocking:
            VStack(alignment: .leading, spacing: 10) {
                Text("QRS → BCG lag")
                    .font(.caption.weight(.semibold))
                if detectsECGArtifacts {
                    Label("ECG detection is active — QRS times will be used.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("ECG / QRS detection must be enabled first (Artifacts → ECG / QRS Detection).", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Lag")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("ms", value: $bcgQRSLagMs, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcgQRSLagMs, in: 100...700, step: 10)
                }
                .help("Typical BCG onset lags the R-wave by 200–400 ms. Start at 300 ms and adjust to align the BCG artifact peak with detected events.")
            }
        }
    }

    private func disableBCGDetection() {
        detectsBCGArtifacts = false
        artifactEvents = artifactEvents.filter { $0.sourceFile != BCGDetector.sourceFile }
        definedArtifacts.removeAll { $0.id == bcgDefinedArtifactID }
        bcgRefinedTemplate = nil
        bcgRefinedKeptCount = nil
    }

    private func runBCGDetection(signal: MFFSignalData, selection: ClosedRange<Int>?) async {
        isRunningBCGDetection = true
        bcgDetectionStatus = nil
        bcgRefinedTemplate = nil
        bcgRefinedKeptCount = nil

        let channels    = signal.data
        let sr          = signal.samplingRate
        let duration    = signal.duration
        let threshold   = bcgThresholdSD
        let winSec      = bcgWindowSeconds
        let method      = bcgDetectionMethod

        let times: [Double]

        switch method {
        case .periodicity:
            times = await BCGDetector.periodicityEvents(
                channels: channels,
                samplingRate: sr,
                minHR: bcgMinHR,
                maxHR: bcgMaxHR,
                thresholdSD: threshold
            )

        case .spatialPCA:
            let nComp      = bcgPCAComponents
            let whiten     = bcgSpatialWhiten
            let slideNorm  = bcgSlidingNormalize
            let respNorm   = bcgRespAdaptive
            times = await BCGDetector.spatialPCAEvents(
                channels: channels,
                samplingRate: sr,
                exemplarRange: selection,
                numComponents: nComp,
                spatialWhiten: whiten,
                slidingNormalize: slideNorm,
                respAdaptive: respNorm,
                thresholdSD: threshold
            )

        case .cardiacPowerMap:
            times = await BCGDetector.cardiacPowerEvents(
                channels: channels,
                samplingRate: sr,
                minHz: bcgPowerMinHz,
                maxHz: bcgPowerMaxHz,
                thresholdSD: threshold
            )

        case .qrsLocking:
            let qrsTimes = artifactEvents
                .filter { $0.code == RWaveDetector.eventCode }
                .map { $0.beginTimeSeconds }
            times = BCGDetector.qrsLockingEvents(
                qrsTimes: qrsTimes,
                lagSeconds: bcgQRSLagMs / 1000.0,
                recordingDuration: duration
            )
        }

        let code    = bcgEventCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let useCode = code.isEmpty ? BCGDetector.eventCode : code

        let newEvents: [MFFEvent] = times.enumerated().map { (idx, t) in
            MFFEvent(
                id: "bcg-\(method.rawValue)-\(idx)-\(t)",
                code: useCode,
                beginTimeSeconds: t,
                rawBeginTime: String(format: "%.4f", t),
                sourceFile: BCGDetector.sourceFile
            )
        }

        let nonBCG = artifactEvents.filter { $0.sourceFile != BCGDetector.sourceFile }
        artifactEvents = (nonBCG + newEvents).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }

        if let estBPM = estimatedBPM(from: times) {
            bcgDetectionStatus = "✓ \(newEvents.count) events  ·  ~\(String(format: "%.0f", estBPM)) BPM"
        } else {
            bcgDetectionStatus = newEvents.isEmpty
                ? "No events detected — try lowering the threshold or check channel selection."
                : "✓ \(newEvents.count) events"
        }

        detectsBCGArtifacts = !newEvents.isEmpty
        showsEventsPanel = !newEvents.isEmpty
        if !newEvents.isEmpty {
            selectedEventCodes = [useCode]
            registerBCGDefinedArtifact(events: newEvents, eventCode: useCode)
        }
        isRunningBCGDetection = false
        if !newEvents.isEmpty {
            showsBCGDetectionSheet = false
        }
    }

    private func runBCGRefinement(signal: MFFSignalData) async {
        let existingTimes = artifactEvents
            .filter { $0.sourceFile == BCGDetector.sourceFile }
            .map { $0.beginTimeSeconds }
        guard !existingTimes.isEmpty else { return }

        let channels = signal.data
        let sr = signal.samplingRate

        bcgIsRefining = true
        bcgDetectionStatus = "Refining…"

        let result = await BCGDetector.refineSpatialPCA(
            channels: channels,
            samplingRate: sr,
            detectedTimes: existingTimes,
            rejectFraction: bcgRejectFraction,
            numComponents: bcgPCAComponents,
            spatialWhiten: bcgSpatialWhiten,
            slidingNormalize: bcgSlidingNormalize,
            respAdaptive: bcgRespAdaptive,
            thresholdSD: bcgThresholdSD
        )

        guard let (newTimes, templateValues, keptCount) = result else {
            bcgDetectionStatus = "⚠ Not enough detected events to refine"
            bcgIsRefining = false
            return
        }

        let useCode = bcgEventCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? BCGDetector.eventCode : bcgEventCode
        let newEvents: [MFFEvent] = newTimes.enumerated().map { (idx, t) in
            MFFEvent(id: "bcg-refined-\(idx)-\(t)",
                     code: useCode,
                     beginTimeSeconds: t,
                     rawBeginTime: String(format: "%.4f", t),
                     sourceFile: BCGDetector.sourceFile)
        }

        let nonBCG = artifactEvents.filter { $0.sourceFile != BCGDetector.sourceFile }
        artifactEvents = (nonBCG + newEvents).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        detectsBCGArtifacts = true
        bcgRefinedTemplate = templateValues
        bcgRefinedKeptCount = keptCount

        let total = existingTimes.count
        let bpmStr = estimatedBPM(from: newTimes).map { String(format: "  ·  ~%.0f BPM", $0) } ?? ""
        bcgDetectionStatus = "✓ Refined: \(keptCount)/\(total) beats kept → \(newEvents.count) events\(bpmStr)"
        registerBCGDefinedArtifact(events: newEvents, eventCode: useCode)
        bcgIsRefining = false
    }

    private func registerBCGDefinedArtifact(events: [MFFEvent], eventCode: String) {
        let artifact = DefinedArtifact(
            id: bcgDefinedArtifactID,
            type: .bcg,
            name: "BCG",
            eventCode: eventCode,
            events: events,
            selectedChannelIndices: [],
            windowSizeSeconds: bcgWindowSeconds,
            average: nil,
            topography: nil,
            cleaningMethod: .obs
        )
        if let index = definedArtifacts.firstIndex(where: { $0.id == bcgDefinedArtifactID }) {
            let prevMethod    = definedArtifacts[index].cleaningMethod
            let prevOBSComps  = definedArtifacts[index].obsPCAComponentCount
            let prevTaper     = definedArtifacts[index].obsEdgeTaperSeconds
            let prevBaseline  = definedArtifacts[index].obsPreservesLocalBaseline
            let prevOverlap   = definedArtifacts[index].obsUsesOverlapAdd
            definedArtifacts[index] = artifact
            definedArtifacts[index].cleaningMethod              = prevMethod
            definedArtifacts[index].obsPCAComponentCount        = prevOBSComps
            definedArtifacts[index].obsEdgeTaperSeconds         = prevTaper
            definedArtifacts[index].obsPreservesLocalBaseline   = prevBaseline
            definedArtifacts[index].obsUsesOverlapAdd           = prevOverlap
        } else {
            definedArtifacts.append(artifact)
        }
        invalidateOBSVarianceCache(for: bcgDefinedArtifactID)
        clearAppliedArtifactCleaning()
    }

    private func estimatedBPM(from times: [Double]) -> Double? {
        guard times.count >= 2 else { return nil }
        let sorted = times.sorted()
        let ipi = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
        let median = ipi.sorted()[ipi.count / 2]
        guard median > 0 else { return nil }
        return 60.0 / median
    }

    private func ecgPNSSelectionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { ecgDetectionSelectedPNSChannels.contains(index) },
            set: { isSelected in
                if isSelected {
                    ecgDetectionSelectedPNSChannels.insert(index)
                } else {
                    ecgDetectionSelectedPNSChannels.remove(index)
                }
            }
        )
    }

    @ViewBuilder
    private func ecgAlgorithmComparisonView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Algorithm Comparison")
                    .font(.caption.weight(.semibold))
                Spacer()
                if isEstimatingECGDetection {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if ecgAlgorithmResults.isEmpty && !isEstimatingECGDetection {
                Text("Select channels above to preview detection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Algorithm")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("QRS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("BPM")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("")
                    }
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                        .gridCellColumns(4)
                    ForEach(ECGDetectionAlgorithm.allCases, id: \.self) { algo in
                        GridRow {
                            Text(algo.displayName)
                                .font(.caption2)
                            if let result = ecgAlgorithmResults[algo] {
                                Text("\(result.count)")
                                    .font(.caption2.monospacedDigit())
                                if let bpm = result.bpm, bpm.isFinite {
                                    Text(String(format: "%.0f", bpm))
                                        .font(.caption2.monospacedDigit())
                                } else {
                                    Text("—")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text(isEstimatingECGDetection ? "…" : "—")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("")
                            }
                            Button {
                                ecgDetectionAlgorithm = algo
                            } label: {
                                Image(systemName: ecgDetectionAlgorithm == algo ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(ecgDetectionAlgorithm == algo ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Use \(algo.displayName) for detection")
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func ecgDetectionPreviewRequestID(for signal: MFFSignalData) -> String {
        [
            signal.signalURL.path,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            displayedPhysioSignal().map { physioRangeTaskID(for: $0) } ?? "noPNS",
            ecgDetectionSelectedPNSChannels.sorted().map(String.init).joined(separator: ","),
            ecgDetectionProxyChannels,
            ecgDetectionPolarity.rawValue,
            String(format: "%.3f", ecgDetectionThresholdSD),
            String(format: "%.3f", ecgDetectionMinimumRRSeconds)
        ].joined(separator: "|")
    }

    @MainActor
    private func refreshECGDetectionEstimate(for signal: MFFSignalData) async {
        let requestID = ecgDetectionPreviewRequestID(for: signal)
        let sources = ecgDetectionSources(for: signal)
        guard !sources.isEmpty else {
            isEstimatingECGDetection = false
            ecgAlgorithmResults = [:]
            return
        }

        isEstimatingECGDetection = true
        ecgAlgorithmResults = [:]

        let thresholdSD = ecgDetectionThresholdSD
        let minRR = ecgDetectionMinimumRRSeconds
        let polarity = ecgDetectionPolarity
        let duration = sources.map(\.duration).max() ?? signal.duration

        let results = await withTaskGroup(
            of: (ECGDetectionAlgorithm, Int).self,
            returning: [ECGDetectionAlgorithm: ECGAlgorithmResult].self
        ) { group in
            for algorithm in ECGDetectionAlgorithm.allCases {
                let config = ECGDetectionConfiguration(
                    algorithm: algorithm,
                    thresholdSD: thresholdSD,
                    minimumRRSeconds: minRR,
                    polarity: polarity
                )
                group.addTask(priority: .utility) {
                    let count = RWaveDetector.detect(sources: sources, configuration: config).count
                    return (algorithm, count)
                }
            }
            var out: [ECGDetectionAlgorithm: ECGAlgorithmResult] = [:]
            for await (algo, count) in group {
                let bpm = duration > 0 ? Double(count) / duration * 60 : nil
                out[algo] = ECGAlgorithmResult(count: count, bpm: bpm)
            }
            return out
        }

        guard !Task.isCancelled, requestID == ecgDetectionPreviewRequestID(for: signal) else { return }
        isEstimatingECGDetection = false
        ecgAlgorithmResults = results
    }

    private func pnsChannelDisplayName(index: Int, signal: MFFSignalData) -> String {
        let name = signal.channelNames?.indices.contains(index) == true
            ? signal.channelNames?[index].nilIfEmpty ?? "PNS \(index + 1)"
            : "PNS \(index + 1)"
        return "\(index + 1): \(name)"
    }

    private func eegChannelDisplayName(index: Int, signal: MFFSignalData) -> String {
        let name = signal.channelNames?.indices.contains(index) == true
            ? signal.channelNames?[index].nilIfEmpty ?? "Ch \(index + 1)"
            : "Ch \(index + 1)"
        return "\(index + 1): \(name)"
    }

    private func likelyECGPNSChannelIndices(in pns: MFFSignalData) -> [Int] {
        let names = pns.channelNames ?? []
        let cardiacTokens = ["ecg", "ekg", "card", "heart"]
        let pulseTokens = ["pulse", "pleth", "ppg"]

        let cardiac = pns.data.indices.filter { index in
            guard names.indices.contains(index) else { return false }
            let lower = names[index].lowercased()
            return cardiacTokens.contains { lower.contains($0) }
        }
        if !cardiac.isEmpty { return cardiac }

        let pulse = pns.data.indices.filter { index in
            guard names.indices.contains(index) else { return false }
            let lower = names[index].lowercased()
            return pulseTokens.contains { lower.contains($0) }
        }
        if !pulse.isEmpty { return pulse }

        return pns.data.indices.first.map { [$0] } ?? []
    }

    private func ecgProxySummary(in signal: MFFSignalData) -> String {
        let indices = parseChannelList(ecgDetectionProxyChannels, channelCount: signal.numberOfChannels)
        guard !indices.isEmpty else { return "No EEG proxy channels selected" }
        return "\(indices.count) EEG proxy channel\(indices.count == 1 ? "" : "s")"
    }

    private func ecgSourceSummary(_ sources: [ECGDetectionSource]) -> String {
        guard !sources.isEmpty else {
            return "Choose at least one PNS channel or EEG proxy channel before detecting QRS complexes."
        }
        let channelCount = sources.reduce(0) { $0 + $1.channelLabels.count }
        return "Will detect from \(channelCount) channel\(channelCount == 1 ? "" : "s") across \(sources.count) source group\(sources.count == 1 ? "" : "s")."
    }

    private func ecgDetectionSources(for signal: MFFSignalData) -> [ECGDetectionSource] {
        var sources: [ECGDetectionSource] = []

        if let pns = displayedPhysioSignal() {
            let indices = ecgDetectionSelectedPNSChannels.sorted().filter { pns.data.indices.contains($0) }
            let valid = indices.filter { pns.data[$0].count == (pns.data.first?.count ?? 0) }
            if !valid.isEmpty {
                sources.append(
                    ECGDetectionSource(
                        id: "pns",
                        label: "PNS",
                        channelLabels: valid.map { pnsChannelDisplayName(index: $0, signal: pns) },
                        channels: valid.map { pns.data[$0] },
                        samplingRate: pns.samplingRate,
                        duration: min(pns.duration, signal.duration)
                    )
                )
            }
        }

        let eegIndices = parseChannelList(ecgDetectionProxyChannels, channelCount: signal.numberOfChannels)
            .filter { signal.data.indices.contains($0) }
        let eegValid = eegIndices.filter { signal.data[$0].count == (signal.data.first?.count ?? 0) }
        if !eegValid.isEmpty {
            sources.append(
                ECGDetectionSource(
                    id: "eeg",
                    label: "EEG proxy",
                    channelLabels: eegValid.map { eegChannelDisplayName(index: $0, signal: signal) },
                    channels: eegValid.map { signal.data[$0] },
                    samplingRate: signal.samplingRate,
                    duration: signal.duration
                )
            )
        }

        return sources
    }

    private var artifactsAreActive: Bool {
        detectsEyeBlinkArtifacts
            || detectsEyeMovementArtifacts
            || detectsECGArtifacts
            || !artifactEvents.isEmpty
            || !definedArtifacts.isEmpty
            || isRunningWaveletArtifactExplorer
            || artifactCleanedSignal != nil
    }

    private var artifactHelpText: String {
        if isRunningWaveletArtifactExplorer {
            return "Wavelet artifact explorer\n\(waveletExplorerStatusTitle.nilIfEmpty ?? "Scanning wavelet artifact evidence...")"
        }

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
            ecgDetectionSelectedPNSChannels.sorted().map(String.init).joined(separator: ","),
            ecgDetectionProxyChannels,
            ecgDetectionAlgorithm.rawValue,
            ecgDetectionPolarity.rawValue,
            "\(ecgDetectionThresholdSD)",
            "\(ecgDetectionMinimumRRSeconds)",
            displayedPhysioSignal().map { physioRangeTaskID(for: $0) } ?? "noPNS",
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

        guard (detectsEyeBlinkArtifacts || detectsEyeMovementArtifacts || detectsECGArtifacts), artifactDetectionMethod == .threshold else {
            artifactEvents = []
            artifactStatusMessage = artifactsAreActive ? "Only threshold artifact detection is available." : nil
            isDetectingArtifacts = false
            return
        }

        let ecgSources = detectsECGArtifacts ? ecgDetectionSources(for: signal) : []
        if detectsECGArtifacts, ecgSources.isEmpty, !detectsEyeBlinkArtifacts, !detectsEyeMovementArtifacts {
            artifactEvents = []
            artifactStatusMessage = "Choose a PNS channel or EEG proxy channel for ECG detection."
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
        let detectECG = detectsECGArtifacts
        let ecgConfiguration = ECGDetectionConfiguration(
            algorithm: ecgDetectionAlgorithm,
            thresholdSD: ecgDetectionThresholdSD,
            minimumRRSeconds: ecgDetectionMinimumRRSeconds,
            polarity: ecgDetectionPolarity
        )

        let detectedEvents = await withTaskGroup(of: [MFFEvent].self) { group in
            if detectBlinks {
                group.addTask(priority: .userInitiated) {
                    EyeArtifactThresholdDetector.detect(
                        kind: .blink,
                        channels: sourceData,
                        samplingRate: samplingRate,
                        duration: duration
                    )
                }
            }
            if detectMovements {
                group.addTask(priority: .userInitiated) {
                    EyeArtifactThresholdDetector.detect(
                        kind: .movement,
                        channels: sourceData,
                        samplingRate: samplingRate,
                        duration: duration
                    )
                }
            }
            if detectECG, !ecgSources.isEmpty {
                group.addTask(priority: .userInitiated) {
                    RWaveDetector.detect(sources: ecgSources, configuration: ecgConfiguration)
                }
            }
            var events: [MFFEvent] = []
            for await batch in group { events += batch }
            return events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        }

        artifactEvents = detectedEvents
        artifactStatusMessage = artifactDetectionSummary(for: detectedEvents)
        isDetectingArtifacts = false
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

    private func channelHealthDetailsSheet(for signal: MFFSignalData) -> some View {
        @Bindable var goodnessSettings = goodnessSettings
        return ChannelHealthDetailsView(
            results: Array(channels.healthResults.values),
            isAnalyzing: channels.isAnalyzingHealth,
            progress: channels.healthProgress,
            statusMessage: channelHealthStatusMessage,
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
                showsChannelHealthDetails = false
            }
        )
    }

    @MainActor
    private func runWaveletChannelGoodness(for signal: MFFSignalData) {
        guard !channels.isAnalyzingHealth else { return }
        let signature = channelHealthSignature(for: signal)
        let shouldRefreshBase = channelHealthSignature != signature || channels.healthResults.isEmpty
        let existingResults = channels.healthResults
        let layout = recording.sensorLayout
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

        channelHealthTask?.cancel()
        channelHealthSignature = signature
        if shouldRefreshBase {
            channels.healthResults = [:]
        }
        channels.showsHealth = true
        channels.isAnalyzingHealth = true
        channels.healthProgress = 0
        channelHealthStatusMessage = "Running wavelet channel goodness..."

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        channelHealthTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                let baseAnalysis: ChannelHealthAnalysis
                if shouldRefreshBase {
                    baseAnalysis = ChannelHealthAnalyzer.analyze(
                        signal: signal,
                        layout: layout,
                        base: baseConfig,
                        spectral: spectralConfig,
                        ransac: ransacConfig,
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
                  channelHealthSignature == signature else {
                return
            }

            channels.healthResults = analysis.resultsByChannel
            channels.isAnalyzingHealth = false
            channels.healthProgress = 1
            channelHealthStatusMessage = analysis.resultsByChannel.isEmpty
                ? "No wavelet channel-goodness metrics available."
                : "Wavelet channel goodness updated \(analysis.resultsByChannel.count) channels."
        }
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
        let baseConfig = goodnessSettings.base
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac
        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        channelHealthTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                ChannelHealthAnalyzer.analyze(
                    signal: sourceSignal,
                    layout: layout,
                    base: baseConfig,
                    spectral: spectralConfig,
                    ransac: ransacConfig,
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
        let baseConfig = goodnessSettings.base
        let spectralConfig = goodnessSettings.spectral
        let ransacConfig = goodnessSettings.ransac

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            channels.healthProgress = min(max(fraction, 0), 1)
        }

        channelHealthTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                do {
                    let analysis = ChannelHealthAnalyzer.analyze(
                        signal: signal,
                        layout: layout,
                        base: baseConfig,
                        spectral: spectralConfig,
                        ransac: ransacConfig,
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
        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            segmentHealthProgress = min(max(fraction, 0), 1)
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

        let (progressContinuation, progressTask) = ProgressBridge.make { fraction in
            segmentHealthProgress = min(max(fraction, 0), 1)
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
        channels.bad.remove(index)
        channelStatusMessage = "Interpolated Ch \(index + 1) from \(indices.count) neighbors."
        channelStatusIsError = false
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
        filteredPNSSignal = nil
        filteredPNSInputSignalType = nil
        icaCleanedSignal = nil
        icaDecomposition = nil
        gradientCorrectedSignal = nil
        gradientCorrectedPNSSignal = nil
        artifactCleanedSignal = nil
        artifactCleaningIsEnabled = true
        waveletReducedSignal = nil
        waveletReductionArtifact = nil
        waveletReductionResult = nil
        waveletReductionIsEnabled = true
        waveletReductionBandVarianceRetained = nil
        waveletReductionStatusMessage = nil
        waveletReductionCandidates = []
        selectedWaveletCandidateID = nil

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
        ecgDetectionSelectedPNSChannels.removeAll()
        ecgDetectionProxyChannels = ""
        selectedArtifactTemplateChannel = nil
        artifactTemplateClickedChannel = nil
        artifactTemplateSelectionRange = nil
        artifactTemplateDefinedArtifactID = nil

        // Status messages and progress.
        filterStatusMessage = nil
        filterStatusIsError = false
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

    private func groupedPSAEventSummaries(_ events: [MFFEvent]) -> [EventSummary] {
        Dictionary(grouping: events, by: psaSegmentValue(for:))
            .map { value, groupedEvents in
                let distinctCodes = Set(groupedEvents.map(\.code)).sorted()
                let searchFields = psaSearchFields(for: value, events: groupedEvents)
                let searchText = psaSearchText(fields: searchFields)
                let detail: String?
                switch psaSegmentField {
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

    private func filteredPSAEventSummaries(_ summaries: [EventSummary]) -> [EventSummary] {
        let filters = psaSearchFilters(from: psaEventSearchText)
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
        switch psaSegmentField {
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

    private func psaSegmentValue(for event: MFFEvent) -> String {
        switch psaSegmentField {
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

// MARK: - Supporting views

/// Which channels the scalp-topography correlation uses. Bad channels are always
/// excluded. Cluster (region-of-interest) options will be added once channel
/// clusters are implemented (see [[ChannelCluster]]).
private enum ArtifactTopographyChannelScope: CaseIterable, Hashable, Identifiable {
    case allGood
    case topN

    var id: Self { self }

    var label: String {
        switch self {
        case .allGood: return "All good channels"
        case .topN:    return "Top N by amplitude"
        }
    }
}

private enum ArtifactDefinitionPanel: String, CaseIterable, Identifiable {
    case waveforms = "Waveforms"
    case topography = "Topography"

    var id: String { rawValue }
}

private enum ArtifactDefinitionResultSource: Equatable {
    case waveform
    case topography

    var displayName: String {
        switch self {
        case .waveform: return "Waveform"
        case .topography: return "Topography"
        }
    }

    var confirmationName: String {
        switch self {
        case .waveform: return "Waveform"
        case .topography: return "Topography"
        }
    }

    var systemImage: String {
        switch self {
        case .waveform: return "waveform.path"
        case .topography: return "circle.grid.3x3.fill"
        }
    }
}

private enum WaveletExplorerChannelScope: String, CaseIterable, Identifiable {
    case visibleGood = "Visible Good"
    case allGood = "All Good"
    case all = "All Channels"
    case ocular = "Ocular"

    var id: String { rawValue }
}

private enum FilterLineNoiseMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case notch = "IIR Notch"
    case adaptiveCleanLine = "CleanLine"

    var id: String { rawValue }
}

private struct WaveletArtifactExplorerLogLine: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
}

/// A PNS channel synthesized from one or more ICA components.
struct SyntheticPNSChannel: Identifiable {
    let id = UUID()
    /// Display name — defaults to "ICA" + sorted component numbers, e.g. "ICA13".
    var name: String
    /// Time course at `samplingRate` (sum of selected component activations, linearly
    /// upsampled from the ICA analysis rate to the EEG sampling rate).
    let samples: [Float]
    let samplingRate: Double
    /// The ICA component indices (0-based) that were summed to produce this channel.
    let sourceComponents: [Int]
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
            p50Abs: SignalStatistics.percentile(sampledAbsValues, fraction: 0.50),
            p95Abs: SignalStatistics.percentile(sampledAbsValues, fraction: 0.95),
            p99Abs: SignalStatistics.percentile(sampledAbsValues, fraction: 0.99),
            maxAbs: maxAbs,
            maxAbsChannel: maxAbsChannel
        )
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

private enum ChannelHealthSort: String, CaseIterable, Identifiable {
    case lowestGoodness = "Lowest First"
    case highestGoodness = "Highest First"
    case channel = "Channel"

    var id: String { rawValue }
}

private struct ChannelHealthDetailsView: View {
    let results: [ChannelHealthResult]
    let isAnalyzing: Bool
    let progress: Double
    let statusMessage: String?
    let onRefresh: () -> Void
    @Binding var waveletFamily: WaveletCleaningFamily
    @Binding var waveletLevelCount: Int
    @Binding var waveletThresholdModel: WaveletCleaningThresholdModel
    @Binding var waveletThresholdRule: WaveletCleaningThresholdRule
    @Binding var waveletDownsampleRate: Double
    @Binding var waveletCleaningMode: WaveletCleaningMode
    @Binding var waveletIntensity: Double
    let onRunWavelets: () -> Void
    let onClose: () -> Void

    @State private var sort = ChannelHealthSort.lowestGoodness
    @State private var showsWaveletOptions = false

    private var sortedResults: [ChannelHealthResult] {
        switch sort {
        case .lowestGoodness:
            return results.sorted {
                if $0.goodPercentage == $1.goodPercentage {
                    return $0.channelIndex < $1.channelIndex
                }
                return $0.goodPercentage < $1.goodPercentage
            }
        case .highestGoodness:
            return results.sorted {
                if $0.goodPercentage == $1.goodPercentage {
                    return $0.channelIndex < $1.channelIndex
                }
                return $0.goodPercentage > $1.goodPercentage
            }
        case .channel:
            return results.sorted { $0.channelIndex < $1.channelIndex }
        }
    }

    private var gradeCounts: [(ChannelHealthGrade, Int)] {
        ChannelHealthGrade.allHealthGrades.map { grade in
            (grade, results.filter { $0.grade == grade }.count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Channel Goodness")
                        .font(.title3.weight(.semibold))
                    Text("\(results.count) channels scored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Sort", selection: $sort) {
                    ForEach(ChannelHealthSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .labelsHidden()
                .frame(width: 145)

                Button("Refresh", action: onRefresh)
                    .disabled(isAnalyzing)

                Button("Wavelet...") { showsWaveletOptions = true }
                    .disabled(isAnalyzing)
                    .popover(isPresented: $showsWaveletOptions, arrowEdge: .bottom) {
                        WaveletRunPopover(
                            family: $waveletFamily,
                            levelCount: $waveletLevelCount,
                            thresholdModel: $waveletThresholdModel,
                            thresholdRule: $waveletThresholdRule,
                            downsampleRate: $waveletDownsampleRate,
                            cleaningMode: $waveletCleaningMode,
                            intensity: $waveletIntensity,
                            isAnalyzing: isAnalyzing,
                            onRun: {
                                showsWaveletOptions = false
                                onRunWavelets()
                            }
                        )
                    }

                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                ForEach(gradeCounts, id: \.0) { grade, count in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(grade.color)
                            .frame(width: 8, height: 8)
                        Text("\(grade.displayName) \(count)")
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(grade.color.opacity(0.10))
                    )
                }

                Spacer()
            }

            if isAnalyzing {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if sortedResults.isEmpty {
                Spacer()
                Text("No channel goodness metrics yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                        GridRow {
                            Text("Ch")
                            Text("Good")
                            Text("Grade")
                            Text("Summary")
                            Text("Weakest Metrics")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ForEach(sortedResults) { result in
                            GridRow {
                                Text("\(result.channelIndex + 1)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                Text("\(result.goodPercentage)%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(result.grade.color)
                                Text(result.grade.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(result.grade.color)
                                Text(result.summary)
                                    .font(.caption)
                                    .lineLimit(2)
                                Text(weakestMetricText(result))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 760, idealWidth: 880, minHeight: 520, idealHeight: 640)
    }

    private func weakestMetricText(_ result: ChannelHealthResult) -> String {
        result.metrics.prefix(3).map {
            "\($0.name) \(Int(($0.score * 100).rounded()))%"
        }
        .joined(separator: " | ")
    }
}

private struct WaveletRunPopover: View {
    @Binding var family: WaveletCleaningFamily
    @Binding var levelCount: Int
    @Binding var thresholdModel: WaveletCleaningThresholdModel
    @Binding var thresholdRule: WaveletCleaningThresholdRule
    @Binding var downsampleRate: Double
    @Binding var cleaningMode: WaveletCleaningMode
    @Binding var intensity: Double
    let isAnalyzing: Bool
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wavelet Channel Burden")
                .font(.headline)
            Text("Scores each channel by its multiscale transient (artifact) burden using an undecimated wavelet decomposition.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Wavelet")
                    Picker("", selection: $family) {
                        ForEach(WaveletCleaningFamily.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                GridRow {
                    Text("Cleaning mode")
                    Picker("", selection: $cleaningMode) {
                        ForEach(WaveletCleaningMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                GridRow {
                    Text("Threshold model")
                    Picker("", selection: $thresholdModel) {
                        ForEach(WaveletCleaningThresholdModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                GridRow {
                    Text("Threshold rule")
                    Picker("", selection: $thresholdRule) {
                        ForEach(WaveletCleaningThresholdRule.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                GridRow {
                    Text("Levels")
                    Stepper("\(levelCount)", value: $levelCount, in: 1...WaveletArtifactAnalyzer.maximumLevelCount)
                        .frame(width: 110)
                }
                GridRow {
                    Text("Intensity")
                    TextField("x", value: $intensity, format: .number.precision(.fractionLength(2)))
                        .frame(width: 80)
                }
                GridRow {
                    Text("Downsample (Hz)")
                    TextField("Hz", value: $downsampleRate, format: .number.precision(.fractionLength(0)))
                        .frame(width: 80)
                }
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Run", action: onRun)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAnalyzing)
            }
        }
        .padding(14)
        .frame(width: 320)
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
    var detail: String? = nil
    var searchText: String = ""
    var searchFields: [PSAEventSearchField: String] = [:]
    var id: String { code }
}

private enum PSAEventSearchField: String, CaseIterable {
    case code = "Code"
    case label = "Label"
    case description = "Description"
    case cell = "Cell"
    case source = "Source"

    init?(alias: String) {
        switch alias
            .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
            .lowercased() {
        case "code", "codes":
            self = .code
        case "label", "labels":
            self = .label
        case "description", "descriptions", "desc":
            self = .description
        case "cell", "cells":
            self = .cell
        case "source", "sources", "file", "files":
            self = .source
        default:
            return nil
        }
    }
}

private struct PSAEventSearchFilter {
    let field: PSAEventSearchField?
    let value: String
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

    /// Averages each category's epochs. Runs off the main thread.
    func average(colorIndices: [String: Int]) -> PSABuildResult? {
        guard signal.samplingRate > 0, !segments.isEmpty,
              let firstSegment = segments.first else { return nil }
        let epochLength = firstSegment.endSample - firstSegment.startSample + 1
        guard epochLength > 0 else { return nil }

        let groupedSegments = Dictionary(grouping: segments, by: \.category)
        let orderedCategories = groupedSegments.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }

        var averagedData = Array(repeating: [Float](), count: signal.numberOfChannels)
        var averagedEvents: [MFFEvent] = []
        var averagedSegments: [EpochSegment] = []
        var outputStartSample = 0

        for category in orderedCategories {
            guard let segs = groupedSegments[category]?.sorted(by: { $0.startSample < $1.startSample }),
                  let representative = segs.first else { continue }
            let minChannelLength = signal.data.map(\.count).min() ?? 0
            let validSegs = segs.filter {
                $0.endSample - $0.startSample + 1 == epochLength
                    && $0.startSample >= 0
                    && $0.endSample < minChannelLength
            }
            guard !validSegs.isEmpty else { continue }

            for channelIndex in signal.data.indices {
                var accumulator = [Double](repeating: 0, count: epochLength)
                let channel = signal.data[channelIndex]
                for seg in validSegs {
                    for offset in 0..<epochLength {
                        accumulator[offset] += Double(channel[seg.startSample + offset])
                    }
                }
                let divisor = Double(validSegs.count)
                averagedData[channelIndex].append(contentsOf: accumulator.map { Float($0 / divisor) })
            }

            let stimulusSample = outputStartSample + representative.stimulusOffsetSamples
            let stimulusTime = Double(stimulusSample) / signal.samplingRate
            averagedEvents.append(MFFEvent(
                id: "psa-average-\(category)-\(outputStartSample)",
                code: category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: "PSA Average"
            ))
            averagedSegments.append(EpochSegment(
                startSample: outputStartSample,
                endSample: outputStartSample + epochLength - 1,
                stimulusOffsetSamples: representative.stimulusOffsetSamples,
                category: category,
                sourceCode: category,
                sourceTimeSeconds: representative.sourceTimeSeconds,
                colorIndex: colorIndices[category] ?? 0,
                contributingEpochCount: validSegs.reduce(0) { $0 + $1.contributingEpochCount }
            ))
            outputStartSample += epochLength
        }

        guard let totalSamples = averagedData.first?.count, totalSamples > 0 else { return nil }
        let averaged = MFFSignalData(
            signalURL: signal.signalURL,
            signalType: signal.signalType,
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: Double(totalSamples) / signal.samplingRate,
            recordingStartTime: signal.recordingStartTime,
            events: averagedEvents,
            data: averagedData,
            channelNames: signal.channelNames
        )
        let categoryCount = orderedCategories.count
        let totalEpochs = averagedSegments.reduce(0) { $0 + $1.contributingEpochCount }
        let msg = "\(categoryCount) categor\(categoryCount == 1 ? "y" : "ies"), \(totalEpochs) epochs averaged"
        return PSABuildResult(signal: averaged, segments: averagedSegments, message: msg)
    }

    /// Applies average-reference and/or baseline correction. Runs off the main thread.
    func postProcessed(averageReference: Bool, baselineCorrect: Bool, badChannels: Set<Int>) -> PSABuildResult {
        var output = self
        if averageReference { output = output.withAverageReference(excluding: badChannels) }
        if baselineCorrect { output = output.withBaselineCorrection() }
        return output
    }

    private func withAverageReference(excluding bad: Set<Int>) -> PSABuildResult {
        let referencedData = EEGSignalFilter.averageReferenced(signal.data, excluding: bad)
        let s = MFFSignalData(signalURL: signal.signalURL, signalType: signal.signalType,
                              numberOfChannels: signal.numberOfChannels, samplingRate: signal.samplingRate,
                              duration: signal.duration, recordingStartTime: signal.recordingStartTime,
                              events: signal.events, data: referencedData, channelNames: signal.channelNames)
        return PSABuildResult(signal: s, segments: segments, message: message)
    }

    private func withBaselineCorrection() -> PSABuildResult {
        var data = signal.data
        for segment in segments {
            let preCount = segment.stimulusOffsetSamples
            guard preCount > 0 else { continue }
            let preStart = segment.startSample
            let preEnd = preStart + preCount
            for channel in data.indices {
                guard preEnd <= data[channel].count, segment.endSample < data[channel].count else { continue }
                var sum = 0.0
                for sample in preStart..<preEnd { sum += Double(data[channel][sample]) }
                let baseline = Float(sum / Double(preCount))
                guard baseline.isFinite else { continue }
                for sample in segment.startSample...segment.endSample {
                    data[channel][sample] -= baseline
                }
            }
        }
        let s = MFFSignalData(signalURL: signal.signalURL, signalType: signal.signalType,
                              numberOfChannels: signal.numberOfChannels, samplingRate: signal.samplingRate,
                              duration: signal.duration, recordingStartTime: signal.recordingStartTime,
                              events: signal.events, data: data, channelNames: signal.channelNames)
        return PSABuildResult(signal: s, segments: segments, message: message)
    }
}

/// Captures all inputs needed to build PSA epochs off the main thread.
private struct PSABuildJob: Sendable {
    let signal: MFFSignalData
    let events: [MFFEvent]
    let categoriesBySegmentValue: [String: String]
    let timingMarkersBySegmentValue: [String: String]
    let timingEventsBySegmentValue: [String: [MFFEvent]]
    let artifactEventsForRejection: [MFFEvent]
    let preSamples: Int
    let epochLength: Int
    let psaOffset: Double
    let sampleCount: Int
    let colorIndices: [String: Int]
    let skipIfContainsArtifact: Bool
    let artifactRejectionLabel: String
    let timingTolerance: Double

    func buildEpochs() -> PSABuildResult? {
        var epochedData = Array(repeating: [Float](), count: signal.numberOfChannels)
        var epochedEvents: [MFFEvent] = []
        var segments: [EpochSegment] = []
        var skippedOutOfBounds = 0
        var skippedArtifacts = 0
        var skippedTimingMarkers = 0
        var timingAdjusted = 0
        var accepted = 0

        for event in events {
            guard let category = categoriesBySegmentValue[event.code] ?? categoriesBySegmentValue[event.label ?? ""] else { continue }
            let segmentValue: String = categoriesBySegmentValue[event.code] != nil ? event.code : (event.label ?? event.code)
            let anchorTimeSeconds: Double
            let timingMarkerValue = timingMarkersBySegmentValue[event.code] ?? timingMarkersBySegmentValue[event.label ?? ""]
            if let timingMarkerValue {
                let candidates = timingEventsBySegmentValue[timingMarkerValue] ?? []
                guard let timingEvent = nearestEvent(to: event, in: candidates) else {
                    skippedTimingMarkers += 1
                    continue
                }
                anchorTimeSeconds = timingEvent.beginTimeSeconds
                timingAdjusted += 1
            } else {
                anchorTimeSeconds = event.beginTimeSeconds + psaOffset
            }
            let correctedSample = Int((anchorTimeSeconds * signal.samplingRate).rounded())
            let startSample = correctedSample - preSamples
            let endSample = startSample + epochLength

            guard startSample >= 0, endSample <= sampleCount else {
                skippedOutOfBounds += 1
                continue
            }
            if skipIfContainsArtifact, !artifactEventsForRejection.isEmpty {
                let startSeconds = Double(startSample) / signal.samplingRate
                let endSeconds = Double(endSample) / signal.samplingRate
                if artifactEventsForRejection.contains(where: { $0.beginTimeSeconds >= startSeconds && $0.beginTimeSeconds <= endSeconds }) {
                    skippedArtifacts += 1
                    continue
                }
            }

            guard signal.data.indices.allSatisfy({ signal.data[$0].count >= endSample }) else { continue }
            for channelIndex in signal.data.indices {
                epochedData[channelIndex].append(contentsOf: signal.data[channelIndex][startSample..<endSample])
            }

            let epochStart = accepted * epochLength
            let stimulusSample = epochStart + preSamples
            let stimulusTime = Double(stimulusSample) / signal.samplingRate
            epochedEvents.append(MFFEvent(
                id: "psa-\(accepted)-\(event.id)",
                code: category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: timingMarkerValue.map { "PSA: \(segmentValue) via \($0)" } ?? "PSA: \(segmentValue)"
            ))
            segments.append(EpochSegment(
                startSample: epochStart,
                endSample: epochStart + epochLength - 1,
                stimulusOffsetSamples: preSamples,
                category: category,
                sourceCode: event.code,
                sourceTimeSeconds: anchorTimeSeconds,
                colorIndex: colorIndices[category] ?? 0,
                contributingEpochCount: 1
            ))
            accepted += 1
        }

        guard accepted > 0, let totalSamples = epochedData.first?.count, totalSamples > 0 else { return nil }

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
        if skippedArtifacts > 0 { message += ", \(skippedArtifacts) skipped for \(artifactRejectionLabel)" }
        if timingAdjusted > 0 { message += ", \(timingAdjusted) timing adjusted" }
        if skippedTimingMarkers > 0 { message += ", \(skippedTimingMarkers) missing timing marker" }
        if skippedOutOfBounds > 0 { message += ", \(skippedOutOfBounds) out of bounds" }
        return PSABuildResult(signal: epochedSignal, segments: segments, message: message)
    }

    private func nearestEvent(to event: MFFEvent, in candidates: [MFFEvent]) -> MFFEvent? {
        let within = timingTolerance > 0
            ? candidates.filter { abs($0.beginTimeSeconds - event.beginTimeSeconds) <= timingTolerance }
            : candidates
        return within.min { lhs, rhs in
            let ld = abs(lhs.beginTimeSeconds - event.beginTimeSeconds)
            let rd = abs(rhs.beginTimeSeconds - event.beginTimeSeconds)
            return ld == rd ? lhs.beginTimeSeconds < rhs.beginTimeSeconds : ld < rd
        }
    }
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

private struct HoverPinnedPreviewButton<PreviewContent: View>: View {
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

private struct ArtifactCleaningPreviewButton: View {
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

private struct WaveletCleaningPreviewButton: View {
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

private struct WaveletCleaningPreview: View {
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

private enum PSASegmentField: String, CaseIterable, Identifiable {
    case code = "Code"
    case label = "Label"
    case artifact = "Artifacts"

    var id: String { rawValue }
}

private struct ECGAlgorithmResult: Sendable {
    let count: Int
    let bpm: Double?
}

private enum ECGDetectionAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case simple = "Simple"
    case panTompkins = "Pan-Tompkins"
    case hamilton = "Hamilton"
    case wfdb = "WFDB"
    case wavelet = "Wavelet"
    case christov = "Christov"

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String { rawValue }

    nonisolated var tabTitle: String {
        switch self {
        case .simple:
            return "Simple"
        case .panTompkins:
            return "Pan-T"
        case .hamilton:
            return "Hamilton"
        case .wfdb:
            return "WFDB"
        case .wavelet:
            return "Wavelet"
        case .christov:
            return "Christov"
        }
    }

    nonisolated var summary: String {
        switch self {
        case .simple:
            return "Robust peak picking on the baseline-corrected waveform."
        case .panTompkins:
            return "Band-pass, derivative, squaring, moving integration, and adaptive QRS thresholding."
        case .hamilton:
            return "Slope-envelope QRS detection with adaptive signal/noise thresholding."
        case .wfdb:
            return "WFDB-style curve-length and slope-energy QRS detection inspired by wqrs/gqrs."
        case .wavelet:
            return "Multiscale detail-energy QRS detection for sharp cardiac transients in noisy signals."
        case .christov:
            return "Christov-style adaptive slope-envelope detection with time-varying signal/noise thresholds."
        }
    }
}

private enum ECGDetectionPolarity: String, CaseIterable, Identifiable, Sendable {
    case positive = "Positive"
    case negative = "Negative"
    case either = "Either"

    var id: String { rawValue }

    nonisolated func score(_ zValue: Double) -> Double {
        switch self {
        case .positive:
            return max(zValue, 0)
        case .negative:
            return max(-zValue, 0)
        case .either:
            return abs(zValue)
        }
    }
}

private struct ECGDetectionSource: Sendable {
    var id: String
    var label: String
    var channelLabels: [String]
    var channels: [[Float]]
    var samplingRate: Double
    var duration: TimeInterval
}

private struct ECGDetectionConfiguration: Sendable {
    var algorithm: ECGDetectionAlgorithm
    var thresholdSD: Double
    var minimumRRSeconds: Double
    var polarity: ECGDetectionPolarity
}

private struct ECGProcessedChannel: Sendable {
    var scores: [Double]
    var waveform: [Double]
}

private struct RWaveCandidate: Sendable {
    var timeSeconds: Double
    var score: Double
    var sourceID: String
    var sourceLabel: String
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

nonisolated private enum RWaveDetector {
    static let eventCode = "R Wave"
    private static let sourceFile = "ECG Detection"
    private static let baselineWindowSeconds = 0.60
    private static let qrsHighPassWindowSeconds = 0.20
    private static let qrsSmoothingWindowSeconds = 0.035
    private static let panTompkinsIntegrationWindowSeconds = 0.150
    private static let hamiltonSlopeWindowSeconds = 0.080
    private static let hamiltonNoiseWindowSeconds = 1.00
    private static let wfdbCurveLengthWindowSeconds = 0.130
    private static let wfdbSlopeWindowSeconds = 0.050
    private static let waveletDetailEnvelopeWindowSeconds = 0.080
    private static let christovEnvelopeWindowSeconds = 0.040
    private static let christovLongSlopeWindowSeconds = 0.280
    private static let adaptivePeakSpacingSeconds = 0.080
    private static let rPeakRefinementWindowSeconds = 0.080

    static func detect(
        sources: [ECGDetectionSource],
        configuration: ECGDetectionConfiguration
    ) -> [MFFEvent] {
        let threshold = min(max(configuration.thresholdSD, 1), 20)
        let minimumRRSeconds = min(max(configuration.minimumRRSeconds, 0.15), 2.0)
        var candidates: [RWaveCandidate] = []

        for source in sources {
            candidates += detectCandidates(
                in: source,
                algorithm: configuration.algorithm,
                threshold: threshold,
                minimumRRSeconds: minimumRRSeconds,
                polarity: configuration.polarity
            )
        }

        let selected = strongestNonOverlapping(candidates, minimumIntervalSeconds: minimumRRSeconds)
            .sorted { $0.timeSeconds < $1.timeSeconds }

        return selected.enumerated().map { index, candidate in
            let time = candidate.timeSeconds
            return MFFEvent(
                id: "artifact-rwave-\(configuration.algorithm.id)-\(index)-\(Int((time * 1_000_000).rounded()))",
                code: eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: "\(sourceFile): \(configuration.algorithm.rawValue)"
            )
        }
    }

    private static func detectCandidates(
        in source: ECGDetectionSource,
        algorithm: ECGDetectionAlgorithm,
        threshold: Double,
        minimumRRSeconds: Double,
        polarity: ECGDetectionPolarity
    ) -> [RWaveCandidate] {
        guard source.samplingRate > 0,
              source.duration > 0,
              let sampleCount = source.channels.map(\.count).min(),
              sampleCount > 2 else {
            return []
        }

        let processedChannels = source.channels.compactMap {
            processedChannel(
                samples: $0,
                sampleCount: sampleCount,
                samplingRate: source.samplingRate,
                algorithm: algorithm,
                polarity: polarity
            )
        }
        guard !processedChannels.isEmpty else { return [] }

        let aggregate = aggregateScores(processedChannels, sampleCount: sampleCount)

        switch algorithm {
        case .simple:
            return staticPeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: threshold,
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .panTompkins:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.45, 0.90),
                floorThreshold: max(threshold * 0.25, 0.55),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .hamilton:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.55, 1.00),
                floorThreshold: max(threshold * 0.30, 0.65),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .wfdb:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.50, 0.95),
                floorThreshold: max(threshold * 0.28, 0.60),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .wavelet:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.48, 0.90),
                floorThreshold: max(threshold * 0.25, 0.55),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        case .christov:
            return adaptivePeakCandidates(
                aggregate: aggregate,
                processedChannels: processedChannels,
                source: source,
                threshold: max(threshold * 0.52, 0.95),
                floorThreshold: max(threshold * 0.30, 0.60),
                minimumRRSeconds: minimumRRSeconds,
                polarity: polarity
            )
        }
    }

    private static func processedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double,
        algorithm: ECGDetectionAlgorithm,
        polarity: ECGDetectionPolarity
    ) -> ECGProcessedChannel? {
        switch algorithm {
        case .simple:
            return simpleProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate,
                polarity: polarity
            )
        case .panTompkins:
            return panTompkinsProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        case .hamilton:
            return hamiltonProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        case .wfdb:
            return wfdbProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        case .wavelet:
            return waveletProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        case .christov:
            return christovProcessedChannel(
                samples: samples,
                sampleCount: sampleCount,
                samplingRate: samplingRate
            )
        }
    }

    private static func simpleProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double,
        polarity: ECGDetectionPolarity
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let highPassed = baselineRemoved(
            samples: samples,
            sampleCount: sampleCount,
            samplingRate: samplingRate
        )
        guard let scores = normalizedPolarityScores(
            values: highPassed,
            sampleCount: sampleCount,
            polarity: polarity
        ) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: highPassed)
    }

    private static func panTompkinsProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let differentiated = derivative(filtered)
        let squared = differentiated.map { $0 * $0 }
        let integrationWindow = sampleWindow(
            seconds: panTompkinsIntegrationWindowSeconds,
            samplingRate: samplingRate,
            minimum: 3
        )
        let integrated = centeredMovingAverage(
            squared,
            sampleCount: sampleCount,
            windowSamples: integrationWindow
        )
        guard let scores = normalizedEnvelopeScores(values: integrated, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func hamiltonProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let slope = derivative(filtered).map { abs($0) }
        let shortWindow = sampleWindow(
            seconds: hamiltonSlopeWindowSeconds,
            samplingRate: samplingRate,
            minimum: 3
        )
        let longWindow = sampleWindow(
            seconds: hamiltonNoiseWindowSeconds,
            samplingRate: samplingRate,
            minimum: shortWindow * 2
        )
        let shortEnvelope = centeredMovingAverage(
            slope,
            sampleCount: sampleCount,
            windowSamples: shortWindow
        )
        let noiseEnvelope = centeredMovingAverage(
            shortEnvelope,
            sampleCount: sampleCount,
            windowSamples: longWindow
        )
        var enhanced = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            enhanced[sample] = max(shortEnvelope[sample] - noiseEnvelope[sample] * 0.50, 0)
        }
        guard let scores = normalizedEnvelopeScores(values: enhanced, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func wfdbProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let slope = derivative(filtered).map { abs($0) }
        let slopeWindow = sampleWindow(
            seconds: wfdbSlopeWindowSeconds,
            samplingRate: samplingRate,
            minimum: 3
        )
        let slopeEnergy = centeredMovingAverage(
            slope.map { $0 * $0 },
            sampleCount: sampleCount,
            windowSamples: slopeWindow
        )
        let curveLength = curveLengthEnvelope(
            filtered,
            sampleCount: sampleCount,
            samplingRate: samplingRate
        )
        var combined = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            combined[sample] = curveLength[sample] + sqrt(max(slopeEnergy[sample], 0))
        }

        guard let scores = normalizedEnvelopeScores(values: combined, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func waveletProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let first = centeredMovingAverage(
            filtered,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(seconds: 0.025, samplingRate: samplingRate, minimum: 1)
        )
        let second = centeredMovingAverage(
            filtered,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(seconds: 0.050, samplingRate: samplingRate, minimum: 3)
        )
        let third = centeredMovingAverage(
            filtered,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(seconds: 0.100, samplingRate: samplingRate, minimum: 5)
        )
        let fourth = centeredMovingAverage(
            filtered,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(seconds: 0.200, samplingRate: samplingRate, minimum: 9)
        )

        var detailEnergy = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            let d1 = filtered[sample] - first[sample]
            let d2 = first[sample] - second[sample]
            let d3 = second[sample] - third[sample]
            let d4 = third[sample] - fourth[sample]
            detailEnergy[sample] = d1 * d1 + 0.85 * d2 * d2 + 0.60 * d3 * d3 + 0.35 * d4 * d4
        }
        let envelope = centeredMovingAverage(
            detailEnergy.map { sqrt(max($0, 0)) },
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: waveletDetailEnvelopeWindowSeconds,
                samplingRate: samplingRate,
                minimum: 3
            )
        )
        guard let scores = normalizedEnvelopeScores(values: envelope, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func christovProcessedChannel(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> ECGProcessedChannel? {
        guard sampleCount > 2 else { return nil }

        let filtered = qrsFiltered(samples: samples, sampleCount: sampleCount, samplingRate: samplingRate)
        let firstDerivative = derivative(filtered)
        let secondDerivative = derivative(firstDerivative)
        var complexLead = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            complexLead[sample] = abs(firstDerivative[sample]) + 0.45 * abs(secondDerivative[sample])
        }
        let shortEnvelope = centeredMovingAverage(
            complexLead,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: christovEnvelopeWindowSeconds,
                samplingRate: samplingRate,
                minimum: 3
            )
        )
        let slowEnvelope = centeredMovingAverage(
            shortEnvelope,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: christovLongSlopeWindowSeconds,
                samplingRate: samplingRate,
                minimum: 7
            )
        )
        var enhanced = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            enhanced[sample] = max(shortEnvelope[sample] - slowEnvelope[sample] * 0.35, 0)
        }
        guard let scores = normalizedEnvelopeScores(values: enhanced, sampleCount: sampleCount) else {
            return nil
        }

        return ECGProcessedChannel(scores: scores, waveform: filtered)
    }

    private static func aggregateScores(
        _ channels: [ECGProcessedChannel],
        sampleCount: Int
    ) -> [Double] {
        var aggregate = Array(repeating: 0.0, count: sampleCount)
        for channel in channels {
            for sample in 0..<sampleCount where channel.scores[sample] > aggregate[sample] {
                aggregate[sample] = channel.scores[sample]
            }
        }
        return aggregate
    }

    private static func staticPeakCandidates(
        aggregate: [Double],
        processedChannels: [ECGProcessedChannel],
        source: ECGDetectionSource,
        threshold: Double,
        minimumRRSeconds: Double,
        polarity: ECGDetectionPolarity
    ) -> [RWaveCandidate] {
        let sampleCount = aggregate.count
        var candidates: [RWaveCandidate] = []
        for sample in 1..<(sampleCount - 1) {
            let score = aggregate[sample]
            guard score >= threshold,
                  score >= aggregate[sample - 1],
                  score > aggregate[sample + 1] else {
                continue
            }
            let refinedSample = refinedPeakSample(
                near: sample,
                processedChannels: processedChannels,
                samplingRate: source.samplingRate,
                polarity: polarity
            )
            let time = Double(refinedSample) / source.samplingRate
            guard time >= 0, time <= source.duration else { continue }
            candidates.append(RWaveCandidate(
                timeSeconds: time,
                score: score,
                sourceID: source.id,
                sourceLabel: source.label
            ))
        }

        return strongestNonOverlapping(candidates, minimumIntervalSeconds: minimumRRSeconds)
    }

    private static func adaptivePeakCandidates(
        aggregate: [Double],
        processedChannels: [ECGProcessedChannel],
        source: ECGDetectionSource,
        threshold: Double,
        floorThreshold: Double,
        minimumRRSeconds: Double,
        polarity: ECGDetectionPolarity
    ) -> [RWaveCandidate] {
        let spacingSamples = sampleWindow(
            seconds: adaptivePeakSpacingSeconds,
            samplingRate: source.samplingRate,
            minimum: 1
        )
        let peaks = localPeakIndices(in: aggregate, minimumSpacingSamples: spacingSamples)
        guard !peaks.isEmpty else { return [] }

        var peakScores = peaks.map { aggregate[$0] }.filter(\.isFinite)
        peakScores.sort()
        var signalLevel = max(threshold, percentile(sortedValues: peakScores, fraction: 0.85))
        var noiseLevel = max(0, percentile(sortedValues: peakScores, fraction: 0.20))
        var adaptiveThreshold = max(floorThreshold, min(threshold, noiseLevel + 0.25 * (signalLevel - noiseLevel)))
        var candidates: [RWaveCandidate] = []

        for peak in peaks {
            let score = aggregate[peak]
            guard score.isFinite else { continue }

            if score >= adaptiveThreshold {
                let refinedSample = refinedPeakSample(
                    near: peak,
                    processedChannels: processedChannels,
                    samplingRate: source.samplingRate,
                    polarity: polarity
                )
                let time = Double(refinedSample) / source.samplingRate
                if time >= 0, time <= source.duration {
                    candidates.append(RWaveCandidate(
                        timeSeconds: time,
                        score: score,
                        sourceID: source.id,
                        sourceLabel: source.label
                    ))
                }
                signalLevel = 0.125 * score + 0.875 * signalLevel
            } else {
                noiseLevel = 0.125 * score + 0.875 * noiseLevel
            }

            adaptiveThreshold = max(floorThreshold, noiseLevel + 0.25 * (signalLevel - noiseLevel))
        }

        return strongestNonOverlapping(candidates, minimumIntervalSeconds: minimumRRSeconds)
    }

    private static func normalizedPolarityScores(
        values: [Double],
        sampleCount: Int,
        polarity: ECGDetectionPolarity
    ) -> [Double]? {
        guard let stats = robustStats(values: values, sampleCount: sampleCount) else { return nil }
        return values.map { value in
            guard value.isFinite else { return 0 }
            return polarity.score((value - stats.center) / stats.scale)
        }
    }

    private static func normalizedEnvelopeScores(
        values: [Double],
        sampleCount: Int
    ) -> [Double]? {
        guard let stats = robustStats(values: values, sampleCount: sampleCount) else { return nil }
        return values.map { value in
            guard value.isFinite else { return 0 }
            return max((value - stats.center) / stats.scale, 0)
        }
    }

    private static func qrsFiltered(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> [Double] {
        let baselineCorrected = baselineRemoved(
            samples: samples,
            sampleCount: sampleCount,
            samplingRate: samplingRate
        )
        let highPassWindow = sampleWindow(
            seconds: qrsHighPassWindowSeconds,
            samplingRate: samplingRate,
            minimum: 3
        )
        let trend = centeredMovingAverage(
            baselineCorrected,
            sampleCount: sampleCount,
            windowSamples: highPassWindow
        )
        var highPassed = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            highPassed[sample] = baselineCorrected[sample] - trend[sample]
        }

        let smoothingWindow = sampleWindow(
            seconds: qrsSmoothingWindowSeconds,
            samplingRate: samplingRate,
            minimum: 1
        )
        return centeredMovingAverage(
            highPassed,
            sampleCount: sampleCount,
            windowSamples: smoothingWindow
        )
    }

    private static func baselineRemoved(
        samples: [Float],
        sampleCount: Int,
        samplingRate: Double
    ) -> [Double] {
        let halfWindow = max(Int((baselineWindowSeconds * samplingRate / 2).rounded()), 1)
        var sums = Array(repeating: 0.0, count: sampleCount + 1)
        var counts = Array(repeating: 0.0, count: sampleCount + 1)

        for index in 0..<sampleCount {
            let value = Double(samples[index])
            if value.isFinite {
                sums[index + 1] = sums[index] + value
                counts[index + 1] = counts[index] + 1
            } else {
                sums[index + 1] = sums[index]
                counts[index + 1] = counts[index]
            }
        }

        var result = Array(repeating: 0.0, count: sampleCount)
        for index in 0..<sampleCount {
            let lower = max(0, index - halfWindow)
            let upper = min(sampleCount, index + halfWindow + 1)
            let count = counts[upper] - counts[lower]
            let baseline = count > 0 ? (sums[upper] - sums[lower]) / count : 0
            let value = Double(samples[index])
            result[index] = value.isFinite ? value - baseline : 0
        }
        return result
    }

    private static func derivative(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values }
        var result = Array(repeating: 0.0, count: values.count)
        result[0] = values[1] - values[0]
        result[values.count - 1] = values[values.count - 1] - values[values.count - 2]
        if values.count > 2 {
            for index in 1..<(values.count - 1) {
                result[index] = (values[index + 1] - values[index - 1]) / 2
            }
        }
        return result
    }

    private static func curveLengthEnvelope(
        _ values: [Double],
        sampleCount: Int,
        samplingRate: Double
    ) -> [Double] {
        guard sampleCount > 1 else { return Array(values.prefix(sampleCount)) }

        let differences = derivative(values)
        let robustScale = robustStats(values: differences, sampleCount: sampleCount)?.scale ?? 1
        let scale = max(robustScale, 1e-6)
        var increments = Array(repeating: 0.0, count: sampleCount)
        for sample in 0..<sampleCount {
            let normalizedSlope = differences[sample] / scale
            increments[sample] = sqrt(1 + normalizedSlope * normalizedSlope) - 1
        }

        return centeredMovingAverage(
            increments,
            sampleCount: sampleCount,
            windowSamples: sampleWindow(
                seconds: wfdbCurveLengthWindowSeconds,
                samplingRate: samplingRate,
                minimum: 3
            )
        )
    }

    private static func centeredMovingAverage(
        _ values: [Double],
        sampleCount: Int,
        windowSamples: Int
    ) -> [Double] {
        guard sampleCount > 0 else { return [] }
        guard windowSamples > 1 else { return Array(values.prefix(sampleCount)) }

        let radius = max(windowSamples / 2, 1)
        var sums = Array(repeating: 0.0, count: sampleCount + 1)
        var counts = Array(repeating: 0.0, count: sampleCount + 1)

        for index in 0..<sampleCount {
            let value = values[index]
            if value.isFinite {
                sums[index + 1] = sums[index] + value
                counts[index + 1] = counts[index] + 1
            } else {
                sums[index + 1] = sums[index]
                counts[index + 1] = counts[index]
            }
        }

        var result = Array(repeating: 0.0, count: sampleCount)
        for index in 0..<sampleCount {
            let lower = max(0, index - radius)
            let upper = min(sampleCount, index + radius + 1)
            let count = counts[upper] - counts[lower]
            result[index] = count > 0 ? (sums[upper] - sums[lower]) / count : 0
        }
        return result
    }

    private static func sampleWindow(seconds: Double, samplingRate: Double, minimum: Int) -> Int {
        max(Int((seconds * samplingRate).rounded()), minimum)
    }

    private static func localPeakIndices(
        in values: [Double],
        minimumSpacingSamples: Int
    ) -> [Int] {
        guard values.count > 2 else { return [] }

        var peaks: [Int] = []
        for index in 1..<(values.count - 1) {
            guard values[index].isFinite,
                  values[index] >= values[index - 1],
                  values[index] > values[index + 1] else {
                continue
            }
            peaks.append(index)
        }
        guard let firstPeak = peaks.first else { return [] }

        var selected: [Int] = []
        var clusterStart = firstPeak
        var bestPeak = firstPeak
        for peak in peaks.dropFirst() {
            if peak - clusterStart <= minimumSpacingSamples {
                if values[peak] > values[bestPeak] {
                    bestPeak = peak
                }
            } else {
                selected.append(bestPeak)
                clusterStart = peak
                bestPeak = peak
            }
        }
        selected.append(bestPeak)
        return selected
    }

    private static func refinedPeakSample(
        near sample: Int,
        processedChannels: [ECGProcessedChannel],
        samplingRate: Double,
        polarity: ECGDetectionPolarity
    ) -> Int {
        guard let sampleCount = processedChannels.map(\.waveform.count).min(), sampleCount > 0 else {
            return sample
        }

        let radius = sampleWindow(
            seconds: rPeakRefinementWindowSeconds,
            samplingRate: samplingRate,
            minimum: 1
        )
        let lower = max(0, sample - radius)
        let upper = min(sampleCount - 1, sample + radius)
        var bestSample = min(max(sample, lower), upper)
        var bestScore = -Double.greatestFiniteMagnitude

        for candidateSample in lower...upper {
            var score = 0.0
            for channel in processedChannels {
                let value = channel.waveform[candidateSample]
                guard value.isFinite else { continue }
                score = max(score, polarity.score(value))
            }
            if score > bestScore {
                bestScore = score
                bestSample = candidateSample
            }
        }

        return bestSample
    }

    private static func robustStats(
        values: [Double],
        sampleCount: Int
    ) -> (center: Double, scale: Double)? {
        let sampleStride = max(sampleCount / 20_000, 1)
        var sampled: [Double] = []
        sampled.reserveCapacity(sampleCount / sampleStride + 1)
        for index in stride(from: 0, to: sampleCount, by: sampleStride) {
            let value = values[index]
            if value.isFinite {
                sampled.append(value)
            }
        }
        guard sampled.count >= 8 else { return nil }

        var centerValues = sampled
        let center = median(&centerValues)
        var deviations = sampled.map { abs($0 - center) }
        let mad = median(&deviations)
        let rms = sqrt(sampled.reduce(0.0) { $0 + ($1 - center) * ($1 - center) } / Double(sampled.count))
        let p95 = percentile(sortedValues: centerValues, fraction: 0.95)
        let scale = max(mad * 1.4826, (p95 - center) / 3, rms * 0.10, 1e-6)
        return (center, scale)
    }

    private static func strongestNonOverlapping(
        _ candidates: [RWaveCandidate],
        minimumIntervalSeconds: Double
    ) -> [RWaveCandidate] {
        var selected: [RWaveCandidate] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let overlaps = selected.contains { abs($0.timeSeconds - candidate.timeSeconds) < minimumIntervalSeconds }
            if !overlaps {
                selected.append(candidate)
            }
        }
        return selected
    }

    private static func percentile(sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        let position = clamped * Double(sortedValues.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper {
            return sortedValues[lower]
        }
        let weight = position - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    private static func median(_ values: inout [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        values.sort()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
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
        let low = SignalStatistics.percentile(scaledValues, fraction: 0.02)
        let high = SignalStatistics.percentile(scaledValues, fraction: 0.98)
        let center = SignalStatistics.percentile(scaledValues, fraction: 0.50)
        let amplitude = max(abs(high - center), abs(low - center), 1e-9)
        return (center, amplitude)
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Pinned physio (PNS) trace pane, sharing the EEG time axis. Mirrors
/// `EventTrackView`: it is offset-driven (not its own scroll view) so it stays
/// fixed while the EEG channels scroll vertically and aligns horizontally with
/// the waveform cursor.
private struct PhysioTrackView: View {
    let signal: MFFSignalData
    let ranges: [ClosedRange<Float>]
    let scaleFactors: [Int: Double]
    let maxScaledChannels: Set<Int>
    let flippedPolarity: Set<Int>
    let rowHeight: CGFloat
    let eegSamplingRate: Double
    let sampleStride: Int
    let timeScale: Double
    let contentOffset: CGFloat
    let viewportWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            guard signal.samplingRate > 0, eegSamplingRate > 0, sampleStride > 0,
                  size.width > 0 else { return }
            let pxPerSecond = eegSamplingRate / Double(sampleStride) * timeScale
            guard pxPerSecond > 0 else { return }

            let pnsSR = signal.samplingRate
            let tStart = max(0, Double(contentOffset) / pxPerSecond)
            let tEnd = Double(contentOffset + size.width) / pxPerSecond

            for (c, channel) in signal.data.enumerated() {
                let rowTop = CGFloat(c) * rowHeight
                let midY = rowTop + rowHeight / 2
                let usable = rowHeight - 8

                // Row baseline.
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: rowTop + rowHeight - 2))
                baseline.addLine(to: CGPoint(x: size.width, y: rowTop + rowHeight - 2))
                context.stroke(baseline, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

                guard !channel.isEmpty else { continue }
                let startSample = max(0, Int(tStart * pnsSR))
                let endSample = min(channel.count - 1, Int(tEnd * pnsSR) + 1)
                guard endSample > startSample else { continue }

                let maxScaled = maxScaledChannels.contains(c)
                let fallbackRange = c < ranges.count
                    ? ranges[c]
                    : (channel.min() ?? -1)...(channel.max() ?? 1)
                let range: ClosedRange<Float>
                if maxScaled {
                    let scanStep = max(1, (endSample - startSample) / 5_000)
                    var lo = Float.greatestFiniteMagnitude
                    var hi = -Float.greatestFiniteMagnitude
                    var k = startSample
                    while k <= endSample {
                        let value = channel[k]
                        if value.isFinite {
                            lo = min(lo, value)
                            hi = max(hi, value)
                        }
                        k += scanStep
                    }
                    range = lo < hi ? lo...hi : fallbackRange
                } else {
                    range = fallbackRange
                }

                let span = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
                let center = (range.lowerBound + range.upperBound) / 2
                let scaleFactor = maxScaled
                    ? CGFloat(1)
                    : CGFloat(min(max(scaleFactors[c] ?? 1, 1), 64))
                let polarity: CGFloat = flippedPolarity.contains(c) ? -1 : 1
                let yScale = usable / CGFloat(span) * scaleFactor
                let minY = rowTop + 4
                let maxY = rowTop + rowHeight - 4
                // Decimate to ~1 point per pixel.
                let step = max(1, (endSample - startSample) / max(1, Int(size.width)))

                var path = Path()
                var started = false
                var j = startSample
                while j <= endSample {
                    let x = CGFloat(Double(j) / pnsSR * pxPerSecond) - contentOffset
                    let centered = CGFloat(channel[j] - center) * polarity
                    let rawY = midY - centered * yScale
                    let y = min(max(rawY, minY), maxY)
                    if started {
                        path.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        path.move(to: CGPoint(x: x, y: y))
                        started = true
                    }
                    j += step
                }
                context.stroke(path, with: .color(.pink), lineWidth: 1)
            }
        }
        .frame(height: CGFloat(signal.numberOfChannels) * rowHeight)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
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

private enum BCGDetectionMethod: String, CaseIterable, Identifiable {
    case periodicity    = "periodicity"
    case spatialPCA     = "spatialPCA"
    case cardiacPowerMap = "cardiacPowerMap"
    case qrsLocking     = "qrsLocking"

    var id: String { rawValue }

    var tabLabel: String {
        switch self {
        case .periodicity:     return "Periodicity"
        case .spatialPCA:      return "Spatial PCA"
        case .cardiacPowerMap: return "Power Map"
        case .qrsLocking:      return "QRS Lock"
        }
    }

    var summary: String {
        switch self {
        case .periodicity:
            return "Bandpass the EEG to the cardiac band, compute the Global Field Power, and find peaks. Exploits the fact that BCG repeats at a stable heart rate — no exemplar needed."
        case .spatialPCA:
            return "Derive the dominant spatial map of BCG from a highlighted exemplar window (or the first 30 s), project the full recording onto it, and detect peaks. Works even when beat morphology varies."
        case .cardiacPowerMap:
            return "Identify which channels carry the most cardiac-band energy, compute a power-weighted time series, and detect peaks. Good when BCG is focal to a subset of electrodes."
        case .qrsLocking:
            return "Offset each detected R-wave by a fixed mechanical delay. Requires ECG / QRS detection to be active. The lag from QRS to BCG onset is typically 200–400 ms — adjust to align peaks."
        }
    }
}
