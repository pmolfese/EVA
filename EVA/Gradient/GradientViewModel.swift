//
//  GradientViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for the fMRI gradient-artifact-removal domain. The store holds the
//  domain's parameters, run state, and corrected outputs; WaveformView still
//  drives the apply/clear orchestration (it is deeply coupled to the recording,
//  TR markers, and the ICA / filter / artifact stages) and reads/writes the store.
//
//  Every method here runs on one of EVA's three clean-room engines under
//  `EVA/Gradient/` — `GradientAAS`, `LocalTemplateArtifactCorrector`,
//  or `GradientTemplateCorrector`. See docs/provenance/README.md.
//

import SwiftUI

/// How many optimal-basis-set components the FASTR family removes, as a flat
/// choice for a picker. Maps onto `GradientOBSMode`.
enum GradientOBSSelection: String, CaseIterable, Identifiable, Sendable {
    case off
    case automatic
    case fixed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .automatic: return "Automatic"
        case .fixed: return "Fixed"
        }
    }
}

/// How the FASTR family picks the donor epochs a template is built from, beyond
/// what the method itself implies.
enum GradientDonorRanking: String, CaseIterable, Identifiable, Sendable {
    case methodDefault
    case squaredCorrelation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .methodDefault: return "Default"
        case .squaredCorrelation: return "Squared r"
        }
    }

    var help: String {
        switch self {
        case .methodDefault:
            return "Use the selected method's own donor rule: nearest epochs in time for FASTR, correlation ranking for FARM, motion-informed neighbourhoods for Moosmann."
        case .squaredCorrelation:
            return "Rank candidates by squared correlation instead, so a strongly anti-correlated epoch qualifies as readily as a strongly correlated one."
        }
    }
}

@MainActor
@Observable
final class GradientViewModel {
    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore, defaults: ProcessingDefaults = .shared) {
        self.store = store
        // Seed from the global preferences so a newly-opened recording starts on
        // the user's preferred family and method, and on the backend they chose
        // once rather than one they have to re-pick per run.
        self.method = defaults.gradientDefaultMethod
        self.lastTemplateMethod = defaults.gradientDefaultTemplateMethod
        self.lastFASTRMethod = defaults.gradientDefaultFASTRMethod
        self.computeBackend = defaults.gradientComputeBackend
    }

    /// Default donor count, in neighbouring volumes total.
    static let defaultDonorVolumes = 8

    // MARK: Results
    var correctedSignal: MFFSignalData?
    var correctedPNSSignal: MFFSignalData?

    /// What the last run actually did, in the audit-log style the export writer
    /// collects (`"<operation> result: <fields>"`).
    ///
    /// The engines produce a lot of "why" — epochs left uncorrected, donors
    /// turned away, stages that stood down, scales rejected as implausible — and
    /// none of it is recoverable from the corrected samples afterwards. It is
    /// recorded here so it reaches `log_eva_<date>_<time>.txt` in the exported
    /// package and the Details disclosure in the sheet.
    var auditLogLines: [String] = []

    // MARK: Run state
    var isProcessing = false
    var progress = 0.0
    /// Forwards into the shared `OperationProgressCenter` so the status area has
    /// one source to read. See `OperationProgressCenter`.
    var operationProgress: OperationProgress? {
        get { store.operationProgress.progress(for: Self.progressSource) }
        set { store.operationProgress.set(newValue, for: Self.progressSource) }
    }
    static let progressSource = "MRI"
    var statusMessage: String?
    var statusIsError = false

    // MARK: UI state
    var showsPopover = false
    var showsMethodHelp = false
    var showsDonorHelp = false
    var showsAdvanced = false
    var showsSafetyHelp = false
    var showsMotionConfig = false
    var showsRunDetails = false

    // MARK: Shared parameters
    var appliesToPNS = true
    /// How many neighbouring volumes contribute to a template, in total rather
    /// than split before and after.
    ///
    /// The papers describe a count of artifacts, not a one-sided reach, and the
    /// engines agree: the FASTR family reads only the sum — every scheme is
    /// handed `requestedDonorCount` and expands outward from the target itself,
    /// so the split never had an effect — and Allen AAS uses a running section
    /// instead. Only the local-template family honoured a split, where the only
    /// thing asymmetry reliably buys is edge bias.
    var donorVolumes = GradientViewModel.defaultDonorVolumes

    /// The total split as evenly as the engines want it, remainder before.
    private var donorSplit: (before: Int, after: Int) {
        let total = max(1, donorVolumes)
        let after = total / 2
        return (total - after, after)
    }
    var trMarkerCode = "TREV"
    var method = MRIGradientMethod.allenIAR
    var slicesPerVolume = 1
    /// Where the trigger sits inside its artifact epoch, as a fraction.
    var relativeTriggerPosition = 0.0
    var computeBackend = GradientComputeBackend.cpu

    // MARK: Alignment (FASTR family)
    var alignmentEnabled = true
    var subSampleAlignment = true
    var upsampleFactor = 1

    // MARK: Template scaling (FASTR family)
    var templateScaling = GradientTemplateScaling.driftTracking
    var templateScaleSmoothingEpochs = 15
    var templateScaleMinimum = 0.2
    var templateScaleMaximum = 5.0

    // MARK: Correlation donors (FASTR family)
    var donorRanking = GradientDonorRanking.methodDefault
    var correlationThreshold = 0.9
    var minimumCorrelatedDonors = 4
    var correlationSearchWindow = 240

    // MARK: OBS (FASTR family)
    var obsSelection = GradientOBSSelection.off
    var obsFixedComponents = 3
    var obsVarianceThreshold = 0.9
    var obsMaximumComponents = 5
    var obsChunkSeconds = 60.0
    var obsMaximumEpochsPerChunk = 256
    var obsResidualEnergyFloor = 0.01

    // MARK: ANC (FASTR family and Allen IAR)
    var ancEnabled = false
    var ancSliceHighPass = false
    var ancFilterLength = 32
    var ancStepSize = 0.01

    // MARK: Local template (MAS / MAR / wAAS / wAAR)

    /// Exponential weighting time constant for wAAS/wAAR, in seconds. A donor
    /// this far from the target counts for 1/e of an adjacent one.
    var localWeightingTimeConstantSeconds = 4.0
    /// Reject donors whose waveform does not resemble the target's, scored on
    /// the highest-variance channel so every channel shares one donor set.
    var localRejectsUncorrelatedDonors = false
    var localMinimumDonorCorrelation = 0.9
    var localMinimumDonorDistance = 0
    var localMinimumDonorCount = 1
    var localSkipsTargetsWithoutEnoughDonors = false

    // MARK: Allen IAR

    /// Epochs the running template spans, or 0 for the preset's own choice.
    ///
    /// The slice preset derives this from the epoch rate — roughly 7.5 seconds
    /// of epochs, which at 30 slices per 2 s TR is far more than the volume
    /// preset's 25 — so a fixed default here would silently override the method.
    /// 0 means "let the preset decide".
    var allenSectionEpochs = 0
    var allenCorrelationGate = 0.975
    var allenInitialEpochs = 5

    // MARK: Channel scope

    /// Channels that receive template subtraction but skip OBS and ANC.
    ///
    /// One user-facing concept over two engine sets. `excludedChannels` passes a
    /// channel through untouched, which is the wrong tool for a channel you still
    /// want corrected but do not trust the residual-modelling stages on — OBS
    /// pools epochs into a shared basis and ANC adapts against the artifact
    /// estimate, and a questionable channel distorts both.
    var templateOnlyChannelSetID: ChannelSet.ID?

    /// Resolved 0-based indices for `templateOnlyChannelSetID`.
    var templateOnlyChannels: Set<Int> {
        guard let id = templateOnlyChannelSetID,
              let set = ChannelSetStore.shared.allSets.first(where: { $0.id == id })
        else { return [] }
        return Set(set.channelIndices)
    }

    // MARK: Motion censoring
    var excludeHighMotion = false
    var motionParameters: MotionParameters?
    var motionFileFormat = MotionFileFormat.auto
    var motionFDThreshold = 0.5
    var motionRadiusMm = 50.0
    var motionMetric = GradientMotionMetric.translationOnly

    // MARK: TR-marker alignment
    var skipStart = 0
    var skipEnd = 0
    var trSeconds = 0.0

    var isActive: Bool { correctedSignal != nil }

    /// Last method chosen in each family, so switching tabs and switching back
    /// returns to what you were using rather than resetting to the first entry.
    private var lastTemplateMethod = MRIGradientMethod.allenIAR
    private var lastFASTRMethod = MRIGradientMethod.fastr

    /// What the method dropdown offers: the current family's live methods, plus
    /// the current selection when that has been retired. A replay can select a
    /// retired method, and it should stay visible and named rather than leaving
    /// the control blank.
    var selectableMethods: [MRIGradientMethod] {
        let live = method.category.methods
        return live.contains(method) ? live : live + [method]
    }

    /// Drives the family tab. Reading derives the family from the current
    /// method; writing restores that family's last selection.
    var categoryBinding: Binding<MRIGradientCategory> {
        Binding(
            get: { self.method.category },
            set: { category in
                guard category != self.method.category else { return }
                switch self.method.category {
                case .template: self.lastTemplateMethod = self.method
                case .fastr: self.lastFASTRMethod = self.method
                }
                self.method = category == .template
                    ? self.lastTemplateMethod
                    : self.lastFASTRMethod
            }
        )
    }

    /// Whether the GPU path is offered at all on this machine.
    var isMetalAvailable: Bool { GradientTemplateCorrector.isMetalAvailable }

    /// Whether the selected method's engine actually has a GPU path here.
    /// `GradientAAS` has none, so Fast AAS and Allen AAS always run on the CPU.
    var backendIsAvailable: Bool {
        switch method.engine {
        case .sliceTemplate: return GradientTemplateCorrector.isMetalAvailable
        case .localTemplate: return LocalTemplateMetalBackend.isAvailable
        case .averageTemplate: return false
        }
    }

    /// Clears the corrected outputs and run state (used by "Remove Correction").
    func clearResults() {
        correctedSignal = nil
        correctedPNSSignal = nil
        auditLogLines = []
    }

    func resetForClose() {
        correctedSignal = nil
        correctedPNSSignal = nil
        auditLogLines = []
        isProcessing = false
        progress = 0
        operationProgress = nil
        statusMessage = nil
        statusIsError = false
        showsPopover = false
        showsMethodHelp = false
        showsDonorHelp = false
        showsAdvanced = false
        showsSafetyHelp = false
        showsMotionConfig = false
        showsRunDetails = false
        templateOnlyChannelSetID = nil
    }

    /// Volume indices flagged as high-motion (FD > threshold), or empty when the
    /// user hasn't enabled exclusion / motion isn't loaded.
    func highMotionVolumeSet() -> Set<Int> {
        guard excludeHighMotion, let motion = motionParameters, motion.count >= 2 else {
            return []
        }
        // Deliberately the same definition the motion-informed scheme uses
        // internally, rather than `MotionParameters.volumesExceeding`. That
        // helper is fixed to all six rigid-body terms, so it ignored the metric
        // picker: a user who chose Translation Only still got a set computed
        // from all six, and every method except Moosmann silently excluded
        // different volumes than the sheet said it would. One definition now.
        return GradientDonorSelection.highMotionVolumes(
            motion: motion.samples,
            metric: motionMetric,
            thresholdMm: motionFDThreshold,
            radiusMm: motionRadiusMm
        )
    }

    // MARK: - Engine configuration

    /// Config for the FASTR family.
    private func sliceTemplateConfig() -> GradientCorrectionConfig {
        var config = GradientCorrectionConfig()
        config.numberOfSlices = max(1, slicesPerVolume)
        config.relativeTriggerPosition = min(max(relativeTriggerPosition, 0), 1)
        // Summed straight back into `requestedDonorCount`, which is all the
        // FASTR family ever reads.
        config.averagingWindowBefore = donorSplit.before
        config.averagingWindowAfter = donorSplit.after
        config.upsampleFactor = max(1, upsampleFactor)

        config.alignmentEnabled = alignmentEnabled
        config.subSampleAlignment = alignmentEnabled && subSampleAlignment

        config.templateScaling = templateScaling
        config.templateScaleSmoothingEpochs = max(1, templateScaleSmoothingEpochs)
        let lower = max(0.001, min(templateScaleMinimum, templateScaleMaximum))
        let upper = max(lower, templateScaleMaximum)
        config.templateScaleRange = lower...upper

        switch method {
        case .moosmann:
            config.templateScheme = .motionInformed
            config.motion = motionParameters?.samples
            config.motionThresholdMm = motionFDThreshold
            config.motionMetric = motionMetric
            config.motionRadiusMm = motionRadiusMm
        case .farm:
            config.templateScheme = .correlationRanked
        default:
            config.templateScheme = .temporalNeighbors
        }
        // Squared-correlation ranking replaces whatever the method would have
        // used, which is what the historical BERGEN option did.
        if donorRanking == .squaredCorrelation {
            config.templateScheme = .squaredCorrelationRanked
            config.allowsSelfDonation = true
        }
        config.correlationThreshold = correlationThreshold
        config.minimumCorrelatedDonors = max(1, minimumCorrelatedDonors)
        config.correlationSearchWindow = max(1, correlationSearchWindow)

        switch obsSelection {
        case .off: config.obs = .off
        case .automatic: config.obs = .automatic
        case .fixed: config.obs = .fixed(componentCount: max(1, obsFixedComponents))
        }
        config.obsVarianceThreshold = obsVarianceThreshold
        config.obsMaximumComponents = max(1, obsMaximumComponents)
        config.obsChunkSeconds = max(1, obsChunkSeconds)
        config.obsMaximumEpochsPerChunk = max(GradientOBS.minimumEpochsForBasis, obsMaximumEpochsPerChunk)
        config.obsResidualEnergyFloor = max(0, obsResidualEnergyFloor)

        config.anc = ancEnabled
        config.ancHighPass = ancSliceHighPass ? .sliceTriggerDependent : .fixed2Hz
        config.ancFilterLength = max(1, ancFilterLength)
        config.ancStepSize = ancStepSize

        // Moosmann censors intrinsically; the explicit set applies elsewhere.
        if method != .moosmann {
            config.censoredVolumes = highMotionVolumeSet()
        }
        let templateOnly = templateOnlyChannels
        config.obsExcludedChannels = templateOnly
        config.ancExcludedChannels = templateOnly

        config.computeBackend = computeBackend
        return config
    }

    /// Config for the AAS family.
    private func averageTemplateConfig(samplingRate: Double) -> GradientAAS.Config {
        var config: GradientAAS.Config
        switch method {
        case .allenIAR:
            config = slicesPerVolume > 1
                ? .allenIARSlice(
                    slicesPerVolume: slicesPerVolume,
                    samplingRate: samplingRate,
                    trSeconds: trSeconds > 0 ? trSeconds : nil
                )
                : .allenIARVolume
            if allenSectionEpochs > 0 {
                config.templateWindow = .fixedSections(epochCount: max(2, allenSectionEpochs))
            }
            config.correlationGate = allenCorrelationGate
            config.alwaysIncludeInitialEpochs = max(0, allenInitialEpochs)
        default:
            config = .evaLocal
            config.templateWindow = .localNeighbors(
                before: donorSplit.before,
                after: donorSplit.after
            )
        }
        config.relativeTriggerPosition = min(max(relativeTriggerPosition, 0), 1)
        config.anc = ancEnabled
        config.ancHighPass = ancSliceHighPass ? .sliceTriggerDependent : .fixed2Hz
        config.ancFilterLength = max(1, ancFilterLength)
        config.ancStepSize = ancStepSize
        config.censoredVolumes = highMotionVolumeSet()
        return config
    }

    /// Config for the AMRI-style local template family.
    private func localTemplateConfig(samplingRate: Double) -> LocalTemplateConfiguration {
        var config = LocalTemplateConfiguration()
        config.donorsBefore = donorSplit.before
        config.donorsAfter = donorSplit.after
        config.reducer = method.weightsDonorsByDistance
            ? .exponentiallyWeighted(
                timeConstantSamples: max(1, localWeightingTimeConstantSeconds * samplingRate)
            )
            : .median
        config.fit = method.fitsTemplateScale ? .leastSquares : .unscaled
        config.minimumDonorDistanceSamples = max(0, localMinimumDonorDistance)
        config.minimumDonorCount = max(1, localMinimumDonorCount)
        config.insufficientDonorPolicy = localSkipsTargetsWithoutEnoughDonors
            ? .skipTarget
            : .useAvailable
        config.minimumDonorCorrelation = localRejectsUncorrelatedDonors
            ? localMinimumDonorCorrelation
            : nil
        config.computeBackend = computeBackend
        config.excludedDonorIndices = highMotionVolumeSet()
        return config
    }

    // MARK: - eva.xml bridge

    /// Marks the parameter block as belonging to the clean-room engines.
    private static let engineToken = "cleanroom-1"

    /// Keys that only EVA's previous gradient correctors ever wrote.
    ///
    /// Absence of the engine token is *not* enough to call a block legacy — a
    /// hand-written processing script that says nothing but `method` and
    /// `trMarkerCode` is perfectly valid and must still run. What identifies an
    /// old block is a key that no current engine has.
    private static let legacyOnlyKeys = [
        "facetWindow", "obsRandomSampling", "bergenRSquareDonors",
        "fastrDonorSelection", "moosmannMotionMetric", "metal"
    ]

    /// Whether this block came from a corrector whose options no longer map.
    private static func isLegacy(_ p: [String: String]) -> Bool {
        guard p["engine"] != engineToken else { return false }
        if legacyOnlyKeys.contains(where: { p[$0] != nil }) { return true }
        // `obs` changed from a bool to a three-way selection, so a bool here is
        // itself evidence of the old writer.
        if let obs = p["obs"], obs == "true" || obs == "false" { return true }
        return false
    }

    var parameters: [String: String] {
        var params: [String: String] = [
            "engine": Self.engineToken,
            "method": method.rawValue,
            "trMarkerCode": trMarkerCode,
            "donorVolumes": "\(donorVolumes)",
            "backend": computeBackend.rawValue
        ]
        if method.supportsSliceEpochs {
            params["slices"] = "\(slicesPerVolume)"
        }
        if method.isFASTR {
            params["upsampleFactor"] = "\(upsampleFactor)"
            params["alignment"] = "\(alignmentEnabled)"
            params["subSample"] = "\(subSampleAlignment)"
            params["templateScaling"] = templateScaling.rawValue
            params["scaleSmoothingEpochs"] = "\(templateScaleSmoothingEpochs)"
            params["scaleMinimum"] = String(format: "%.4f", templateScaleMinimum)
            params["scaleMaximum"] = String(format: "%.4f", templateScaleMaximum)
            params["donorRanking"] = donorRanking.rawValue
            params["correlationThreshold"] = String(format: "%.4f", correlationThreshold)
            params["minimumCorrelatedDonors"] = "\(minimumCorrelatedDonors)"
            params["correlationSearchWindow"] = "\(correlationSearchWindow)"
            params["obs"] = obsSelection.rawValue
            params["obsFixedComponents"] = "\(obsFixedComponents)"
            params["obsVarianceThreshold"] = String(format: "%.4f", obsVarianceThreshold)
            params["obsMaximumComponents"] = "\(obsMaximumComponents)"
            params["obsChunkSeconds"] = String(format: "%.2f", obsChunkSeconds)
            params["obsMaximumEpochsPerChunk"] = "\(obsMaximumEpochsPerChunk)"
            params["obsResidualEnergyFloor"] = String(format: "%.5f", obsResidualEnergyFloor)
        }
        if method == .allenIAR {
            params["allenSectionEpochs"] = "\(allenSectionEpochs)"
            params["allenCorrelationGate"] = String(format: "%.4f", allenCorrelationGate)
            params["allenInitialEpochs"] = "\(allenInitialEpochs)"
        }
        if method.engine == .localTemplate {
            params["localMinimumDonorDistance"] = "\(localMinimumDonorDistance)"
            params["localMinimumDonorCount"] = "\(localMinimumDonorCount)"
            params["localSkipsTargets"] = "\(localSkipsTargetsWithoutEnoughDonors)"
            if method.weightsDonorsByDistance {
                params["localWeightingTimeConstant"] = String(format: "%.3f", localWeightingTimeConstantSeconds)
            }
            params["localRejectsUncorrelatedDonors"] = "\(localRejectsUncorrelatedDonors)"
            if localRejectsUncorrelatedDonors {
                params["localMinimumDonorCorrelation"] = String(format: "%.4f", localMinimumDonorCorrelation)
            }
        }
        if let id = templateOnlyChannelSetID, method.isFASTR {
            params["templateOnlyChannelSetID"] = id.uuidString
        }
        if method.isFASTR || method == .allenIAR {
            params["anc"] = "\(ancEnabled)"
            params["ancSliceHighPass"] = "\(ancSliceHighPass)"
            params["ancFilterLength"] = "\(ancFilterLength)"
            params["ancStepSize"] = String(format: "%.5f", ancStepSize)
        }
        if method.usesMotion || excludeHighMotion {
            params["motionFDThreshold"] = String(format: "%.2f", motionFDThreshold)
            params["motionMetric"] = motionMetric.rawValue
            params["motionRadiusMm"] = String(format: "%.1f", motionRadiusMm)
        }
        // Four inputs the correction reads but this block used to omit — found by
        // the REWIND determinism audit (2026-08-13). `skipStart`/`skipEnd` trim
        // the TR-marker list in `trimmedTRMarkers`, so they change which volumes
        // are corrected at all; `appliesToPNS` decides whether the PNS channels
        // are corrected; `excludeHighMotion` gates `highMotionVolumeSet()`.
        // Motion censoring already serialized its *threshold* while omitting the
        // switch that turns it on, which is the more confusing half to lose.
        params["skipStart"] = "\(skipStart)"
        params["skipEnd"] = "\(skipEnd)"
        params["appliesToPNS"] = "\(appliesToPNS)"
        params["excludeHighMotion"] = "\(excludeHighMotion)"
        return params
    }

    /// Deserialization inverse of `parameters` for Copy Processing / replay.
    ///
    /// Missing keys leave the current value untouched. Motion data itself is
    /// subject-specific (loaded per-recording), so only the threshold and metric
    /// are carried; exclusion no-ops gracefully when the target file has no
    /// motion parameters.
    ///
    /// A block written by EVA's previous gradient correctors is ignored in full.
    /// Those engines had different defaults and options that do not map onto
    /// these one-to-one — quietly applying the half that happens to share a name
    /// would produce a run the file does not describe. A block that is merely
    /// sparse, such as a hand-written processing script, is applied normally.
    func apply(parameters p: [String: String]) {
        guard !Self.isLegacy(p) else {
            statusMessage = "This file's gradient settings were written by an earlier correction engine and could not be carried over; the current defaults are in use."
            statusIsError = false
            return
        }

        if let m = p["method"].flatMap(MRIGradientMethod.init(rawValue:)) { method = m }
        if let c = p["trMarkerCode"] { trMarkerCode = c }
        if let v = p["donorVolumes"].flatMap(Int.init) {
            donorVolumes = v
        } else if let before = p["windowBefore"].flatMap(Int.init),
                  let after = p["windowAfter"].flatMap(Int.init) {
            // A block from before the split was retired. The sum is what every
            // engine but the local-template one was using anyway.
            donorVolumes = max(1, before + after)
        }
        if let v = p["backend"].flatMap(GradientComputeBackend.init(rawValue:)) { computeBackend = v }
        if let v = p["slices"].flatMap(Int.init) { slicesPerVolume = v }

        if let v = p["upsampleFactor"].flatMap(Int.init) { upsampleFactor = v }
        if let v = p["alignment"] { alignmentEnabled = (v == "true") }
        if let v = p["subSample"] { subSampleAlignment = (v == "true") }
        if let v = p["templateScaling"].flatMap(GradientTemplateScaling.init(rawValue:)) {
            templateScaling = v
        }
        if let v = p["scaleSmoothingEpochs"].flatMap(Int.init) { templateScaleSmoothingEpochs = v }
        if let v = p["scaleMinimum"].flatMap(Double.init) { templateScaleMinimum = v }
        if let v = p["scaleMaximum"].flatMap(Double.init) { templateScaleMaximum = v }
        if let v = p["donorRanking"].flatMap(GradientDonorRanking.init(rawValue:)) { donorRanking = v }
        if let v = p["correlationThreshold"].flatMap(Double.init) { correlationThreshold = v }
        if let v = p["minimumCorrelatedDonors"].flatMap(Int.init) { minimumCorrelatedDonors = v }
        if let v = p["correlationSearchWindow"].flatMap(Int.init) { correlationSearchWindow = v }

        if let v = p["obs"].flatMap(GradientOBSSelection.init(rawValue:)) { obsSelection = v }
        if let v = p["obsFixedComponents"].flatMap(Int.init) { obsFixedComponents = v }
        if let v = p["obsVarianceThreshold"].flatMap(Double.init) { obsVarianceThreshold = v }
        if let v = p["obsMaximumComponents"].flatMap(Int.init) { obsMaximumComponents = v }
        if let v = p["obsChunkSeconds"].flatMap(Double.init) { obsChunkSeconds = v }
        if let v = p["obsMaximumEpochsPerChunk"].flatMap(Int.init) { obsMaximumEpochsPerChunk = v }
        if let v = p["obsResidualEnergyFloor"].flatMap(Double.init) { obsResidualEnergyFloor = v }

        if let v = p["allenSectionEpochs"].flatMap(Int.init) { allenSectionEpochs = v }
        if let v = p["allenCorrelationGate"].flatMap(Double.init) { allenCorrelationGate = v }
        if let v = p["allenInitialEpochs"].flatMap(Int.init) { allenInitialEpochs = v }

        if let v = p["localMinimumDonorDistance"].flatMap(Int.init) { localMinimumDonorDistance = v }
        if let v = p["localMinimumDonorCount"].flatMap(Int.init) { localMinimumDonorCount = v }
        if let v = p["localSkipsTargets"] { localSkipsTargetsWithoutEnoughDonors = (v == "true") }
        if let v = p["localWeightingTimeConstant"].flatMap(Double.init) {
            localWeightingTimeConstantSeconds = v
        }
        if let v = p["localRejectsUncorrelatedDonors"] { localRejectsUncorrelatedDonors = (v == "true") }
        if let v = p["localMinimumDonorCorrelation"].flatMap(Double.init) {
            localMinimumDonorCorrelation = v
        }

        if let v = p["anc"] { ancEnabled = (v == "true") }
        if let v = p["ancSliceHighPass"] { ancSliceHighPass = (v == "true") }
        if let v = p["ancFilterLength"].flatMap(Int.init) { ancFilterLength = v }
        if let v = p["ancStepSize"].flatMap(Double.init) { ancStepSize = v }

        if let v = p["templateOnlyChannelSetID"].flatMap(UUID.init(uuidString:)) {
            templateOnlyChannelSetID = v
        }
        if let v = p["motionMetric"].flatMap(GradientMotionMetric.init(rawValue:)) { motionMetric = v }
        if let v = p["motionRadiusMm"].flatMap(Double.init) { motionRadiusMm = v }
        if let v = p["motionFDThreshold"].flatMap(Double.init) {
            motionFDThreshold = v
            // Legacy inference: scripts written before `excludeHighMotion` was
            // serialized only emitted a threshold when censoring was on (or the
            // method needed motion anyway), so a present threshold implied it.
            // The explicit key below overrides this when it exists.
            excludeHighMotion = true
        }
        if let v = p["skipStart"].flatMap(Int.init) { skipStart = v }
        if let v = p["skipEnd"].flatMap(Int.init) { skipEnd = v }
        if let v = p["appliesToPNS"] { appliesToPNS = (v == "true") }
        if let v = p["excludeHighMotion"] { excludeHighMotion = (v == "true") }
    }

    // MARK: - Apply (the transform itself)

    /// Runs the configured method against `signal` (and `pnsSignal`, if
    /// `appliesToPNS`), updating `correctedSignal`/`correctedPNSSignal`.
    ///
    /// `onApplied` carries cross-domain invalidation (ICA/filter outputs computed
    /// on the old base are now stale) back to the caller — this store stays
    /// focused on its own domain, same pattern as
    /// `FilterViewModel.apply(to:pnsInput:onApplied:)`.
    ///
    /// This method itself has no `recordingSessionID` staleness guard: it only
    /// ever writes into `self`, which is safe regardless of caller. A caller
    /// whose VM instance can outlive a single run (the interactive Apply
    /// button, whose `GradientViewModel` survives a same-window "Close
    /// Recording" while a Task may still be in flight) must still guard the
    /// *outer* Task against that with its own session check before/after
    /// awaiting this call — see `MRIGradientArtifactViews.applyGradientCorrection`
    /// for that caller-side guard. A one-shot headless caller (`ProcessingCore`)
    /// doesn't need one: its VMs are fresh per run and never "closed" mid-flight.
    func apply(
        to signal: MFFSignalData,
        pnsSignal: MFFSignalData?,
        onApplied: @escaping () -> Void = {}
    ) async {
        await runCorrection(from: signal, pnsSignal: pnsSignal, onApplied: onApplied)
    }

    /// TR marker samples for `signal`, filtered to `trMarkerCode` and trimmed
    /// by `skipStart`/`skipEnd`.
    private func trimmedTRMarkers(in signal: MFFSignalData, samplingRate: Double? = nil) -> [Int] {
        let rate = samplingRate ?? signal.samplingRate
        let all = signal.events
            .filter { $0.code == trMarkerCode }
            .map { Int(($0.beginTimeSeconds * rate).rounded()) }
            .sorted()
        guard all.count > skipStart + skipEnd else { return [] }
        return Array(all[skipStart..<(all.count - skipEnd)])
    }

    /// One correction run, shared by all three engines.
    ///
    /// The engines differ only in the closure that turns channels into corrected
    /// channels; everything around it — progress staging, cancellation, PNS
    /// handling, and cross-domain invalidation — is identical, so it lives here
    /// once rather than being duplicated per family.
    private func runCorrection(
        from signal: MFFSignalData,
        pnsSignal: MFFSignalData?,
        onApplied: @escaping () -> Void
    ) async {
        let trSamples = trimmedTRMarkers(in: signal)
        let pnsInput = appliesToPNS ? pnsSignal : nil
        let pnsTRSamples = pnsInput.map {
            trimmedTRMarkers(in: signal, samplingRate: $0.samplingRate)
        } ?? []
        let hasPNS = pnsInput != nil

        isProcessing = true
        progress = 0.02
        statusMessage = nil

        let usesGPU = computeBackend == .metal && backendIsAvailable
        beginOperationProgress(
            subtitle: "\(method.label) · \(usesGPU ? "Metal GPU" : "CPU")",
            hasPNS: hasPNS,
            phase: "Preparing triggers and artifact alignment"
        )
        let eegChannelCount = signal.data.count
        let pnsChannelCount = pnsInput?.data.count ?? 0
        let correctionPhase = correctionPhaseDescription()
        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.updateCorrectionProgress(
                fraction,
                hasPNS: hasPNS,
                eegChannels: eegChannelCount,
                pnsChannels: pnsChannelCount,
                phase: correctionPhase
            )
        }

        let run = correctionClosure(samplingRate: signal.samplingRate)
        let pnsRun = pnsInput.map { correctionClosure(samplingRate: $0.samplingRate) }

        do {
            let sourceData = signal.data
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let corrected = try run(sourceData, trSamples) { fraction in
                    progressContinuation.yield(hasPNS ? 0.70 * fraction : fraction)
                }
                try Task.checkCancellation()
                let correctedPNSData: [[Float]]?
                if let pnsInput, let pnsRun {
                    // Only the EEG report is kept: the PNS pass repeats the same
                    // decisions on a handful of channels and would just double
                    // every line.
                    correctedPNSData = try pnsRun(pnsInput.data, pnsTRSamples) { fraction in
                        progressContinuation.yield(0.70 + 0.30 * fraction)
                    }.channels
                } else {
                    correctedPNSData = nil
                }
                try Task.checkCancellation()
                return (corrected.channels, correctedPNSData, corrected.report)
            }
            let result = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )
            progressContinuation.finish()
            progressTask.cancel()
            guard !Task.isCancelled else {
                isProcessing = false
                operationProgress = nil
                return
            }

            updateFinalizingProgress()

            auditLogLines = result.2
            let censored = highMotionVolumeSet()
            if !censored.isEmpty, !method.usesMotion {
                let listed = censored.sorted().prefix(20).map(String.init).joined(separator: ",")
                auditLogLines.append(
                    "\(Self.operation) excluded: motionCensoredVolumes=\(censored.count) "
                    + "(metric=\(motionMetric.rawValue), threshold=\(String(format: "%.2f", motionFDThreshold))mm, "
                    + "volumes \(listed)\(censored.count > 20 ? ", …" : ""))"
                )
            }
            correctedSignal = signal.replacingSamples(result.0)
            if let pnsInput, let correctedPNSData = result.1 {
                correctedPNSSignal = pnsInput.replacingSamples(correctedPNSData, signalTypeSuffix: "MRI")
            } else {
                correctedPNSSignal = nil
            }
            statusMessage = summaryMessage(usesGPU: usesGPU, hasPNS: hasPNS)
            statusIsError = false
            progress = 1
            onApplied()
        } catch is CancellationError {
            progressContinuation.finish()
            progressTask.cancel()
        } catch {
            progressContinuation.finish()
            progressTask.cancel()
            statusMessage = error.localizedDescription
            statusIsError = true
        }
        isProcessing = false
        operationProgress = nil
    }

    /// `(channels, triggers, progress) -> corrected channels` for the selected
    /// engine. Captured before the detached task so nothing touches the main
    /// actor's state off-actor.
    private func correctionClosure(
        samplingRate: Double
    ) -> @Sendable ([[Float]], [Int], @escaping (Double) -> Void) throws -> (channels: [[Float]], report: [String]) {
        switch method.engine {
        case .sliceTemplate:
            let config = sliceTemplateConfig()
            let label = method.label
            return { channels, triggers, progress in
                let result = try GradientTemplateCorrector.correct(
                    channels: channels,
                    volumeTriggers: triggers,
                    config: config,
                    samplingRate: samplingRate,
                    progress: progress
                )
                return (result.channels, Self.report(for: result.diagnostics, method: label))
            }

        case .averageTemplate:
            let config = averageTemplateConfig(samplingRate: samplingRate)
            let label = method.label
            return { channels, triggers, progress in
                let result = try GradientAAS.correct(
                    channels: channels,
                    volumeTriggers: triggers,
                    config: config,
                    samplingRate: samplingRate,
                    progress: progress
                )
                return (result.channels, Self.report(for: result.diagnostics, method: label))
            }

        case .localTemplate:
            let config = localTemplateConfig(samplingRate: samplingRate)
            // This engine has no progress callback of its own, so the fraction is
            // reported at the boundaries rather than faked at a finer granularity
            // than the engine actually provides.
            let label = method.label
            let floor = config.minimumDonorCorrelation
            return { channels, triggers, progress in
                progress(0)
                let result = try LocalTemplateArtifactCorrector.correctGradient(
                    channels: channels,
                    trSamples: triggers,
                    samplingRate: samplingRate,
                    configuration: config
                )
                progress(1)
                return (
                    result.cleanedChannels,
                    Self.report(for: result.eventSummaries, method: label, correlationFloor: floor)
                )
            }
        }
    }

    private func correctionPhaseDescription() -> String {
        switch method.engine {
        case .sliceTemplate:
            return obsSelection == .off
                ? "Building and subtracting artifact templates"
                : "Building templates and fitting OBS"
        case .averageTemplate:
            return method == .allenIAR
                ? "Building running artifact templates"
                : "Building artifact templates"
        case .localTemplate:
            let reducer = method.weightsDonorsByDistance ? "distance-weighted" : "median"
            return method.fitsTemplateScale
                ? "Building \(reducer) templates and fitting the scale"
                : "Building \(reducer) artifact templates"
        }
    }

    private func summaryMessage(usesGPU: Bool, hasPNS: Bool) -> String {
        var parts: [String] = ["\(trMarkerCode) markers"]
        if method.supportsSliceEpochs, slicesPerVolume > 1 {
            parts.append("\(slicesPerVolume) slices/volume")
        }
        switch method.engine {
        case .sliceTemplate:
            parts.append("\(donorVolumes) donor volumes")
            parts.append("\(templateScaling.label.lowercased()) scaling")
            if donorRanking == .squaredCorrelation { parts.append("squared-r donors") }
            if obsSelection != .off { parts.append("OBS \(obsSelection.label.lowercased())") }
            let templateOnly = templateOnlyChannels.count
            if templateOnly > 0 { parts.append("\(templateOnly) template-only channels") }
        case .averageTemplate:
            if method == .allenIAR {
                parts.append("\(allenSectionEpochs)-epoch sections")
                parts.append("gate \(String(format: "%.3f", allenCorrelationGate))")
            }
        case .localTemplate:
            let reducer = method.weightsDonorsByDistance ? "distance-weighted" : "median"
            parts.append("\(reducer) template, \(donorVolumes) donor volumes")
            if method.fitsTemplateScale { parts.append("least-squares fit") }
            if localRejectsUncorrelatedDonors {
                parts.append("donor r ≥ \(String(format: "%.2f", localMinimumDonorCorrelation))")
            }
        }
        if ancEnabled, method.isFASTR || method == .allenIAR {
            parts.append("ANC\(ancSliceHighPass ? " slice-rate HPF" : "")")
        }
        if usesGPU { parts.append("Metal GPU") }
        let censored = highMotionVolumeSet().count
        if censored > 0, method != .moosmann { parts.append("\(censored) high-motion TRs excluded") }
        if hasPNS { parts.append("PNS included") }
        return "Applied \(method.label) correction (\(parts.joined(separator: ", ")))."
    }

    // MARK: - Run reports

    nonisolated static let operation = "mriGradientCorrection"

    /// Report for the two engines that return `GradientCorrectionDiagnostics`.
    ///
    /// Warnings are grouped and counted rather than listed one per epoch: a
    /// recording with nine thousand epochs can raise thousands of them, and
    /// "templateScaleRejected x14" is the fact a reviewer needs, with the epoch
    /// numbers only useful for the handful of cases that are rare enough to
    /// chase individually.
    nonisolated static func report(
        for diagnostics: GradientCorrectionDiagnostics,
        method: String
    ) -> [String] {
        var lines: [String] = []
        let corrected = diagnostics.correctedEpochCount
        let uncorrected = diagnostics.epochs.count - corrected
        lines.append(
            "\(operation) result: method=\(method), backend=\(diagnostics.computeBackend.rawValue), "
            + "epochs=\(diagnostics.epochCount), period=\(diagnostics.period), "
            + "corrected=\(corrected), uncorrected=\(uncorrected), "
            + "referenceChannel=\(diagnostics.referenceChannel + 1)"
        )

        if !diagnostics.highMotionVolumes.isEmpty {
            let volumes = diagnostics.highMotionVolumes.sorted()
            lines.append(
                "\(operation) excluded: highMotionVolumes=\(volumes.count) (\(volumes.prefix(20).map(String.init).joined(separator: ",")))"
            )
        }

        var counts: [String: Int] = [:]
        var examples: [String: [Int]] = [:]
        for warning in diagnostics.warnings {
            let (kind, epoch) = Self.classify(warning)
            counts[kind, default: 0] += 1
            if let epoch, (examples[kind]?.count ?? 0) < 10 {
                examples[kind, default: []].append(epoch)
            }
        }
        for kind in counts.keys.sorted() {
            var line = "\(operation) warning: \(kind) x\(counts[kind] ?? 0)"
            if let epochs = examples[kind], !epochs.isEmpty {
                let shown = epochs.map(String.init).joined(separator: ",")
                line += " (epochs \(shown)\((counts[kind] ?? 0) > epochs.count ? ", …" : ""))"
            }
            lines.append(line)
        }

        if !diagnostics.obsComponentCounts.isEmpty {
            let components = diagnostics.obsComponentCounts.map(String.init).joined(separator: ",")
            lines.append("\(operation) obs: componentsPerChunk=\(components)")
        }
        if !diagnostics.ancAppliedChannels.isEmpty {
            lines.append("\(operation) anc: appliedChannels=\(diagnostics.ancAppliedChannels.count)")
        }
        return lines
    }

    /// Report for the local-template engine, whose diagnostics are per event.
    nonisolated static func report(
        for summaries: [LocalTemplateEventSummary],
        method: String,
        correlationFloor: Double?
    ) -> [String] {
        var lines: [String] = []
        let skipped = summaries.filter { $0.skippedReason != nil }
        lines.append(
            "\(operation) result: method=\(method), backend=cpu, "
            + "events=\(summaries.count), corrected=\(summaries.count - skipped.count), "
            + "skipped=\(skipped.count)"
        )

        var byReason: [String: [Int]] = [:]
        for summary in skipped {
            guard let reason = summary.skippedReason else { continue }
            byReason[reason.rawValue, default: []].append(summary.eventIndex)
        }
        for reason in byReason.keys.sorted() {
            let events = byReason[reason] ?? []
            let shown = events.prefix(20).map(String.init).joined(separator: ",")
            lines.append(
                "\(operation) skipped: \(reason) x\(events.count) "
                + "(events \(shown)\(events.count > 20 ? ", …" : ""))"
            )
        }

        if let floor = correlationFloor {
            let rejected = summaries.flatMap(\.rejectedDonors)
            let affected = summaries.filter { !$0.rejectedDonors.isEmpty }.count
            var line = "\(operation) donors: correlationFloor=\(String(format: "%.3f", floor)), "
                + "rejected=\(rejected.count) across \(affected) events"
            if let worst = rejected.min(by: { $0.correlation < $1.correlation }) {
                line += ", lowest r=\(String(format: "%.3f", worst.correlation))"
            }
            lines.append(line)
        }
        return lines
    }

    /// Warning kind plus the epoch it names, for grouping.
    nonisolated private static func classify(_ warning: GradientCorrectionWarning) -> (String, Int?) {
        switch warning {
        case .epochOutOfBounds(let epoch): return ("epochOutOfBounds", epoch)
        case .noEligibleDonors(let epoch): return ("noEligibleDonors", epoch)
        case .degenerateTemplate(let epoch): return ("degenerateTemplate", epoch)
        case .templateScaleRejected(let epoch): return ("templateScaleRejected", epoch)
        case .donorsCrossedMotionBarrier(let epoch): return ("donorsCrossedMotionBarrier", epoch)
        case .correlationDonorsFellBack(let epoch): return ("correlationDonorsFellBack", epoch)
        case .motionUnavailableForScheme: return ("motionUnavailableForScheme", nil)
        case .noSupraThresholdMotion: return ("noSupraThresholdMotion", nil)
        case .motionRowsFrontPadded(let count): return ("motionRowsFrontPadded(\(count))", nil)
        case .motionRowsTruncated(let count): return ("motionRowsTruncated(\(count))", nil)
        case .obsChunkTooSmall: return ("obsChunkTooSmall", nil)
        case .obsBasisUnavailable(let start): return ("obsBasisUnavailable", start)
        case .obsResidualBelowFloor(let start): return ("obsResidualBelowFloor", start)
        case .ancSkippedForUninformativeReference(let channel): return ("ancSkipped", channel)
        }
    }

    private func beginOperationProgress(subtitle: String, hasPNS: Bool, phase: String) {
        var stages = ["Preparing", "EEG correction"]
        if hasPNS { stages.append("PNS correction") }
        stages.append("Finalizing")
        operationProgress = .started(
            source: "MRI",
            title: "MRI Gradient Removal",
            subtitle: subtitle,
            phase: phase,
            stages: stages
        ).updating(fraction: 0.02, phase: phase, activeStage: 0)
    }

    private func updateCorrectionProgress(
        _ workerFraction: Double,
        hasPNS: Bool,
        eegChannels: Int,
        pnsChannels: Int,
        phase: String
    ) {
        let bounded = min(max(workerFraction, 0), 1)
        let isPNS = hasPNS && bounded >= 0.70
        let localFraction = isPNS
            ? min(max((bounded - 0.70) / 0.30, 0), 1)
            : min(max(bounded / (hasPNS ? 0.70 : 1), 0), 1)
        let count = isPNS ? pnsChannels : eegChannels
        let completed = min(count, max(0, Int((localFraction * Double(count)).rounded())))
        let target = isPNS ? "PNS" : "EEG"
        let displayFraction = 0.06 + 0.88 * bounded
        progress = displayFraction
        let stage = isPNS ? 2 : 1
        operationProgress = operationProgress?.updating(
            fraction: displayFraction,
            phase: isPNS ? "Correcting PNS channels" : phase,
            detail: count > 0 ? "\(target) channels \(completed) of \(count)" : nil,
            activeStage: stage
        )
    }

    private func updateFinalizingProgress() {
        progress = 0.98
        guard let current = operationProgress else { return }
        operationProgress = current.updating(
            fraction: 0.98,
            phase: "Finalizing corrected signal",
            activeStage: current.stages.count - 1
        )
    }
}
