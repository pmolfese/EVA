//
//  SingleTrialAnalysisViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for the "Single Trial Analysis" domain — extracts per-trial
//  amplitude/latency measures from the raw (pre-average) epochs a PSA
//  segmentation produced, while the file is still open. State-ownership
//  extraction: this VM holds selection/parameters/results; `WaveformView`
//  drives the actual computation via `SingleTrialAnalyzer` (L3).
//

import SwiftUI

/// Whether the analysis runs on one channel directly, or averages a channel
/// set (ROI) into a single series first.
enum SingleTrialChannelScope: String, CaseIterable, Identifiable {
    case singleChannel = "Single Channel"
    case channelSet = "Channel Set (ROI average)"

    var id: String { rawValue }
}

enum SingleTrialAnalysisMode: String, CaseIterable, Identifiable {
    case measurements = "Measurements"
    case woody = "Woody Alignment"
    case ride = "RIDE"
    case cwtRidge = "CWT Ridge"
    case clusterStatistics = "Cluster Statistics"
    case trialDiagnostics = "Trial Diagnostics"

    var id: String { rawValue }
}

enum RIDEPlotMode: String, CaseIterable, Identifiable {
    case alignedAverages = "Aligned Averages"
    case components = "Components"

    var id: String { rawValue }
}

nonisolated struct SingleTrialRunProgress: Sendable, Equatable {
    var fraction: Double
    var title: String
    var detail: String
}

@MainActor
@Observable
final class SingleTrialAnalysisViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Presence
    var showsSheet = false

    // MARK: Selection
    var selectedCategory: String?
    var channelScope = SingleTrialChannelScope.singleChannel
    var selectedChannelIndex: Int?
    var selectedChannelSetID: ChannelSet.ID?
    var showsAllConditionsInButterfly = false
    var analysisMode = SingleTrialAnalysisMode.measurements

    // MARK: Analysis window (ms, relative to stimulus onset) — nil until the
    // user drag-selects a range on the averaged-trace picker.
    var windowStartMs: Double?
    var windowEndMs: Double?

    // MARK: Parameters
    var adaptiveHalfWidthMs = 10.0
    var splitCount = 2
    var outlierThresholdSD = 3.0
    var distributionChunkCount = 2
    // Trial diagnostics (ROADMAP.md, Trial-wise project).
    var similarityResults: [TrialSimilarityAnalyzer.CategoryResult]?
    var diagnosticsRows: [TrialDiagnosticsCategory] = []
    var diagnosticsAxis = TrialDiagnosticsAxis.trialIndex
    var diagnosticsMeasure = "Peak (own, +)"
    var diagnosticsSecondaryMeasure = "Slope (β)"
    var diagnosticsGroupCount = 3
    /// Comparing every category at once is what makes the cross-category
    /// mislabel check possible; off, only the selected category is scored.
    var diagnosticsUsesAllCategories = true
    /// The plot and its controls fold away once a run has produced results —
    /// otherwise the answer always starts below the fold. Reopens on demand,
    /// and whenever a run fails.
    var setupIsExpanded = true

    // MARK: - Free-form analysis windows
    //
    // RIDE has three fixed components with their own stored bounds. Every other
    // mode gets a list you can add to, so a window can point at whichever peak
    // is being investigated. Kept per mode, because the windows you want while
    // measuring are rarely the ones you want while scoring trials.
    var measurementWindows: [TrialAlignmentMetrics.AnalysisWindow] = []
    var cwtWindows: [TrialAlignmentMetrics.AnalysisWindow] = []
    var diagnosticsWindows: [TrialAlignmentMetrics.AnalysisWindow] = []
    /// Woody aligns on a single window by construction — one rigid shift per
    /// trial, estimated against one target. Showing it as a window makes that
    /// visible instead of implied.
    var woodyWindows: [TrialAlignmentMetrics.AnalysisWindow] = []

    /// How many windows a mode admits. Woody's 1 is a statement about the
    /// method.
    func maximumWindows(for mode: SingleTrialAnalysisMode) -> Int {
        switch mode {
        case .woody: 1
        case .measurements, .cwtRidge, .trialDiagnostics: 8
        case .ride, .clusterStatistics: 0
        }
    }

    func windows(for mode: SingleTrialAnalysisMode) -> [TrialAlignmentMetrics.AnalysisWindow] {
        switch mode {
        case .measurements: measurementWindows
        case .cwtRidge: cwtWindows
        case .trialDiagnostics: diagnosticsWindows
        case .woody: woodyWindows
        case .ride, .clusterStatistics: []
        }
    }

    func setWindows(_ windows: [TrialAlignmentMetrics.AnalysisWindow], for mode: SingleTrialAnalysisMode) {
        switch mode {
        case .measurements: measurementWindows = windows
        case .cwtRidge: cwtWindows = windows
        case .trialDiagnostics: diagnosticsWindows = windows
        // Woody estimates ONE rigid shift per trial, so it gets exactly one
        // window — the cap is the point, not a limitation to work around.
        case .woody: woodyWindows = Array(windows.prefix(1))
        case .ride, .clusterStatistics: break
        }
    }

    func updateWindow(_ id: UUID, startMs: Double, endMs: Double, for mode: SingleTrialAnalysisMode) {
        var current = windows(for: mode)
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].startMs = min(startMs, endMs)
        current[index].endMs = max(startMs, endMs)
        setWindows(current, for: mode)
    }

    /// Adds a window, preferring the exact span the user just dragged.
    ///
    /// When a drag selection is active, the new window is placed at EXACTLY
    /// that span — dragging then pressing Add is how you place a window
    /// on purpose, and a window that lands somewhere other than where you
    /// dragged would defeat the point of dragging first. With no drag active,
    /// a window lands over the middle third of the current analysis span
    /// instead, so it appears somewhere visible rather than at zero width.
    @discardableResult
    func addWindow(for mode: SingleTrialAnalysisMode) -> Bool {
        var current = windows(for: mode)
        guard current.count < maximumWindows(for: mode) else { return false }

        let start: Double
        let end: Double
        if let dragStart = windowStartMs, let dragEnd = windowEndMs, dragEnd > dragStart {
            start = dragStart
            end = dragEnd
        } else {
            let spanStart = windowStartMs ?? 0
            let spanEnd = windowEndMs ?? (spanStart + 400)
            let span = max(spanEnd - spanStart, 50)
            start = spanStart + span * 0.35
            end = start + span * 0.3
        }

        current.append(
            TrialAlignmentMetrics.AnalysisWindow(
                name: "W\(current.count + 1)",
                startMs: start,
                endMs: end
            )
        )
        setWindows(current, for: mode)
        return true
    }

    func removeWindow(_ id: UUID, for mode: SingleTrialAnalysisMode) {
        setWindows(windows(for: mode).filter { $0.id != id }, for: mode)
    }
    // Phase 3: exclusion criteria and what they buy.
    var selectionCriteria = TrialSelectionAnalyzer.Criteria.none
    var selectionOutcome: TrialSelectionAnalyzer.Outcome?
    var selectionExclusions: [TrialSelectionAnalyzer.Exclusion] = []
    /// Channel-resolved averages for the before/after overlay.
    var selectionAverageAll: [Double] = []
    var selectionAverageKept: [Double] = []
    /// Multichannel trials for the selected category, kept so dragging a
    /// threshold re-scores without re-slicing the recording.
    var selectionTrialMatrices: [[[Float]]] = []
    var selectionBaselineSampleCount = 0
    var usesWoodyAlignedTrialsForMeasurements = false
    var woodyAlignmentMode = WoodyAlignmentAnalyzer.AlignmentMode.correlation
    var woodyPeakPolarity = WoodyAlignmentAnalyzer.PeakPolarity.either
    var woodyRunsAllCategories = false
    var woodyMaxLagMs = 100.0
    var woodyMaxIterations = 8
    var woodyConvergenceToleranceSamples = 0
    /// Apply wavelet shrinkage denoising to each trial before Woody alignment.
    var woodyAppliesDenoising = false
    var showsWoodyAlignedOverlay = true
    var woodyAlignmentAnimationProgress = 1.0
    var isWoodyAlignmentAnimating = false
    var loopsWoodyAlignmentAnimation = true
    var rideIncludesStimulusComponent = true
    var rideIncludesCentralComponent = true
    var rideIncludesResponseComponent = false
    var rideRunsAllCategories = false
    var rideStimulusWindowStartMs = -100.0
    var rideStimulusWindowEndMs = 100.0
    var rideCentralWindowStartMs = 200.0
    var rideCentralWindowEndMs = 500.0
    // R is relative to the response marker; S and C are stimulus-relative.
    var rideResponseWindowStartMs = -300.0
    var rideResponseWindowEndMs = 300.0
    var rideStimulusLatencySource = RIDEAnalyzer.LatencySource.stimulusLocked
    var rideCentralLatencySource = RIDEAnalyzer.LatencySource.estimated
    var rideResponseLatencySource = RIDEAnalyzer.LatencySource.fixed
    var rideFixedStimulusLatencyMs = 0.0
    var rideFixedCentralLatencyMs = 0.0
    var rideCentralLatencySearchMode = RIDEAnalyzer.CentralLatencySearchMode.mostProbable
    var rideCentralMaxLagMs = 100.0
    var rideDefaultResponseLatencyMs = 500.0
    var rideMaxIterations = 6
    var rideConvergenceToleranceSamples = 0
    /// Apply wavelet shrinkage denoising to each trial before RIDE decomposition.
    var rideAppliesDenoising = false
    var ridePlotMode = RIDEPlotMode.alignedAverages
    var showsRIDEAlignedOverlay = true
    var rideAlignmentAnimationProgress = 1.0
    var isRIDEAlignmentAnimating = false
    var loopsRIDEAlignmentAnimation = true

    // MARK: CWT Ridge parameters
    var cwtAppliesDenoising = true
    var cwtPeakSource = CWTRidgePipeline.PeakSource.conditionAverage
    var cwtEngine = NonlinearAligner.Engine.dtw
    var cwtRidgePolarity = CWTRidgeDetector.Polarity.either
    var cwtWavelet = CWTWavelet.ricker
    var cwtMinSNR = 3.0
    var cwtMinScale = 2.0
    var cwtMaxScale = 64.0
    var cwtMaxShiftMs = 100.0
    var cwtSakoeChibaBand = 20
    var cwtPriorSigmaMs = 30.0
    var cwtComputesFunctionalPCA = true
    var cwtRunsAllCategories = false
    var showsCWTAlignedOverlay = true

    // MARK: Cluster-statistics parameters
    var clusterStatistic = ClusterStatisticKind.t
    var clusterConditionA: String?
    var clusterConditionB: String?
    var clusterFConditions: Set<String> = []
    var clusterWindowStartMs = -100.0
    var clusterWindowEndMs = 800.0
    var clusterPermutationCount = 1_000
    var clusterThreshold = 2.0
    var clusterFThreshold = 4.0
    var clusterAlpha = 0.05
    /// Cluster-forming threshold entered as an uncorrected p rather than as a
    /// raw statistic. On by default: a fixed |t| means a different p at every
    /// trial count, so the raw form is only comparable within one analysis.
    var clusterUsesProbabilityThreshold = true
    var clusterThresholdProbability = 0.05
    var clusterInference = ClusterInferenceMode.clusterMass
    var clusterTFCE = TFCEParameters.default
    /// Treats the conditions as measurements of the same units rather than as
    /// unrelated trials. Off by default because ordinary single-subject epochs
    /// have no pairing to exploit.
    var clusterRepeatedMeasures = false
    var clusterAdjacency = ClusterAdjacencyConfiguration.default
    /// Set once per recording from the montage's own sensor spacing, so the
    /// default neighborhood is not a constant that suits only dense nets.
    var clusterAdjacencyDistanceInitialized = false
    var clusterShowsStandardError = true
    /// Analyze every Nth sample. Explicit because it changes the temporal
    /// lattice on which clusters are formed, not merely the plot resolution.
    var clusterSampleStride = 2
    var clusterOutput: ClusterStatisticsOutput?

    // MARK: Result / run state
    var result: SingleTrialAnalyzer.Result?
    var woodyResult: WoodyAlignmentAnalyzer.Result?
    var woodyResultCategory: String?
    var woodyResultChannelIndices: [Int] = []
    var woodyResultsByCategory: [String: WoodyAlignmentAnalyzer.Result] = [:]
    var rideResult: RIDEAnalyzer.Result?
    var rideResultCategory: String?
    var rideResultChannelIndices: [Int] = []
    var rideResultsByCategory: [String: RIDEAnalyzer.Result] = [:]
    var cwtResult: CWTRidgePipeline.Result?
    var cwtResultCategory: String?
    var cwtResultChannelIndices: [Int] = []
    var cwtResultsByCategory: [String: CWTRidgePipeline.Result] = [:]
    var statusMessage: String?
    var isRunning = false
    var runProgress: SingleTrialRunProgress?

    var hasWindow: Bool {
        guard let start = windowStartMs, let end = windowEndMs else { return false }
        return end > start
    }

    func resetForClose() {
        showsSheet = false
        selectedCategory = nil
        channelScope = .singleChannel
        selectedChannelIndex = nil
        selectedChannelSetID = nil
        showsAllConditionsInButterfly = false
        analysisMode = .measurements
        windowStartMs = nil
        windowEndMs = nil
        result = nil
        woodyResult = nil
        woodyResultCategory = nil
        woodyResultChannelIndices = []
        woodyResultsByCategory = [:]
        showsWoodyAlignedOverlay = true
        woodyAlignmentAnimationProgress = 1.0
        isWoodyAlignmentAnimating = false
        loopsWoodyAlignmentAnimation = true
        ridePlotMode = .alignedAverages
        showsRIDEAlignedOverlay = true
        rideAlignmentAnimationProgress = 1.0
        isRIDEAlignmentAnimating = false
        loopsRIDEAlignmentAnimation = true
        rideResult = nil
        rideResultCategory = nil
        rideResultChannelIndices = []
        rideResultsByCategory = [:]
        cwtResult = nil
        cwtResultCategory = nil
        cwtResultChannelIndices = []
        cwtResultsByCategory = [:]
        clusterConditionA = nil
        clusterConditionB = nil
        clusterFConditions = []
        clusterOutput = nil
        clusterAdjacencyDistanceInitialized = false
        statusMessage = nil
        isRunning = false
        runProgress = nil
    }
}
