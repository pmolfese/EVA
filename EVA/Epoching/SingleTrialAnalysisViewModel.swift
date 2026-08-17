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
        statusMessage = nil
        isRunning = false
        runProgress = nil
    }
}
