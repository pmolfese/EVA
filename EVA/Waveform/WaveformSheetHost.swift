//
//  WaveformSheetHost.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Single-sheet host for the recording window (ROADMAP Priority 1, B3).
//
//  `content(for:)` used to chain 18 separate `.sheet(isPresented:)` modifiers.
//  Each one wraps the view in another `ModifiedContent<…>` layer, so the concrete
//  return type of the body became an enormous nested generic — and the Swift
//  runtime pays to instantiate that type's metadata and protocol witness tables
//  the first time the view is displayed.
//
//  That cost was measured, not assumed. In `trace2.trace` (Release, SwiftUI
//  template, 2026-08-12) the session's only hang — 358 ms, at first display of the
//  recording — was 98% type-metadata work under `WaveformView.bodyChrome.getter`:
//  `decodeMangledType`, `_checkGenericRequirements`, `_gatherGenericParameters`,
//  and `lazy protocol witness table accessor for type ModifiedContent<…>`. The
//  mangled names in the trace name `View.sheet(isPresented:onDismiss:content:)`
//  explicitly. Collapsing 18 layers into one is the direct fix.
//
//  The migration keeps every existing call site working: presentation is still
//  driven by the same `showsSheet` booleans on the domain view models, which are
//  *derived* into `activeSheet` rather than each owning a modifier. Nothing needs
//  to change to open a sheet — `epoching.showsSheet = true` still works — and the
//  booleans can be retired VM-by-VM later.
//

import SwiftUI

/// Which sheet the recording window is currently presenting.
///
/// One inspectable value replacing 18 independent booleans. Besides collapsing
/// the modifier chain, this makes "which sheet is open" a single thing that
/// replay and batch debugging can read, and is the shape `REWIND.md` needs to
/// reopen a stage's sheet from a history node.
enum ActiveRecordingSheet: String, Identifiable, CaseIterable, Sendable {
    case psa
    case artifactTemplate
    case artifactCleaning
    case ecgDetection
    case eyeArtifactThreshold
    case bcgDetection
    case waveletExplorer
    case waveletReduction
    case ica
    case replayConfig
    case channelInspector
    case datasetInfo
    case physioImport
    case eegAnalysis
    case channelHealthDetails
    case channelGoodnessSettings
    case segmentHealthDetails
    case motionConfig
    case channelDecisionReplay

    var id: String { rawValue }
}

extension WaveformView {
    /// The sheet to present, derived from the domain view models' existing
    /// presentation booleans.
    ///
    /// Order is significant and matches the order of the original `.sheet` chain:
    /// if two flags are somehow set at once, the same one wins that would have
    /// won before. Dismissing it clears only that flag, so the second then
    /// presents rather than being silently swallowed.
    var activeSheet: ActiveRecordingSheet? {
        if epoching.showsSheet { return .psa }
        if template.showsSheet { return .artifactTemplate }
        if artifactVM.showsCleaningSheet { return .artifactCleaning }
        if ecg.showsSheet { return .ecgDetection }
        if artifactVM.showsThresholdSheet { return .eyeArtifactThreshold }
        if bcg.showsSheet { return .bcgDetection }
        if waveletExplorer.showsSheet { return .waveletExplorer }
        if wavelet.showsSheet { return .waveletReduction }
        if ica.showsSheet { return .ica }
        if replay.showsConfigPane { return .replayConfig }
        if showsChannelInspector { return .channelInspector }
        if showsDatasetInfo { return .datasetInfo }
        if showsPhysioImportSheet { return .physioImport }
        if eegAnalysis.showsSheet { return .eegAnalysis }
        if chanHealth.showsDetails { return .channelHealthDetails }
        if showsChannelGoodnessSettings { return .channelGoodnessSettings }
        if segHealth.showsDetails { return .segmentHealthDetails }
        if gradient.showsMotionConfig { return .motionConfig }
        // Last, so it cannot pre-empt a stage sheet the replay loop itself
        // opened; it is only ever set while the loop is parked at its gate.
        if channelDecisionReplayRequest != nil { return .channelDecisionReplay }
        return nil
    }

    /// Binding for the single `.sheet(item:)`. Writing `nil` (Esc, click-away, or
    /// a child's own dismiss) clears the flag that is currently presenting.
    var activeSheetBinding: Binding<ActiveRecordingSheet?> {
        Binding(
            get: { activeSheet },
            set: { newValue in
                guard newValue == nil else { return }
                dismissActiveSheet()
            }
        )
    }

    /// Clears the presentation flag for whichever sheet is showing.
    ///
    /// Deliberately clears only the active one rather than resetting all 18: if a
    /// second flag is also set, it should present next, matching how the chained
    /// modifiers behaved.
    func dismissActiveSheet() {
        switch activeSheet {
        case .psa: epoching.showsSheet = false
        case .artifactTemplate: template.showsSheet = false
        case .artifactCleaning: artifactVM.showsCleaningSheet = false
        case .ecgDetection: ecg.showsSheet = false
        case .eyeArtifactThreshold: artifactVM.showsThresholdSheet = false
        case .bcgDetection: bcg.showsSheet = false
        case .waveletExplorer: waveletExplorer.showsSheet = false
        case .waveletReduction: wavelet.showsSheet = false
        case .ica: ica.showsSheet = false
        case .replayConfig: replay.showsConfigPane = false
        case .channelInspector: showsChannelInspector = false
        case .datasetInfo: showsDatasetInfo = false
        case .physioImport: showsPhysioImportSheet = false
        case .eegAnalysis: eegAnalysis.showsSheet = false
        case .channelHealthDetails: chanHealth.showsDetails = false
        case .channelGoodnessSettings: showsChannelGoodnessSettings = false
        case .segmentHealthDetails: segHealth.showsDetails = false
        case .motionConfig: gradient.showsMotionConfig = false
        // Dismissing by Esc or click-away is a skip: the loop is waiting on the
        // gate, and leaving it waiting would park the whole replay.
        case .channelDecisionReplay: resolveChannelDecisionReplay(.skip)
        case nil: break
        }
    }

    /// Body of the single `.sheet(item:)`.
    ///
    /// Takes the pipeline signals as parameters because they are locals of
    /// `content(for:)` — the stage a sheet operates on differs per sheet (`base`
    /// for ICA, `cleaningBase` for artifact cleaning, `waveletInput` for wavelet
    /// reduction), and that routing is exactly what the original chain encoded.
    @ViewBuilder
    func sheetContent(
        _ sheet: ActiveRecordingSheet,
        base: MFFSignalData,
        cleaningBase: MFFSignalData,
        waveletInput: MFFSignalData,
        continuousSignal: MFFSignalData
    ) -> some View {
        switch sheet {
        case .psa:
            psaSheet(for: continuousSignal)

        case .artifactTemplate:
            artifactTemplateSheet(for: continuousSignal)

        case .artifactCleaning:
            artifactCleaningSheet(for: cleaningBase)

        case .ecgDetection:
            ecgDetectionSheet(for: continuousSignal)

        case .eyeArtifactThreshold:
            EyeArtifactThresholdSheet(
                signal: continuousSignal,
                sensorLayoutName: recording.sensorLayout?.name,
                detectsEyeBlinkArtifacts: $detectsEyeBlinkArtifacts,
                detectsEyeMovementArtifacts: $detectsEyeMovementArtifacts,
                blinkChannelOverrideText: $blinkChannelOverrideText,
                movementChannelOverrideText: $movementChannelOverrideText,
                artifactVM: artifactVM
            )

        case .bcgDetection:
            bcgDetectionSheet(for: continuousSignal, selection: activeSelectionRange(in: continuousSignal))
                .onAppear {
                    autoSelectBCGProxySetIfEnabled(for: continuousSignal)
                    prepareCWLDefaults(pns: displayedPhysioSignal())
                }

        case .waveletExplorer:
            waveletArtifactExplorerSheet(for: continuousSignal)

        case .waveletReduction:
            waveletReductionSheet(input: waveletInput)

        case .ica:
            icaSheet(for: base)

        case .replayConfig:
            ReplayConfigSheet(
                controller: replay,
                onStart: { startInteractiveReplay() },
                onCancel: { replay.reset() }
            )

        case .channelInspector:
            channelInspectorSheet(for: continuousSignal)

        case .datasetInfo:
            DatasetInfoSheet(
                recording: recording,
                epoching: epoching,
                effectiveType: effectiveFileType,
                isTypeOverridden: recordingStore.fileTypeOverride != nil,
                onChangeType: { setFileTypeOverride($0) },
                onClose: { showsDatasetInfo = false }
            )

        case .physioImport:
            PhysioImportSheet(
                recording: recording,
                onComplete: { showsPhysioImportSheet = false },
                onCancel: { showsPhysioImportSheet = false }
            )

        case .eegAnalysis:
            EEGAnalysisSheet(
                viewModel: eegAnalysis,
                packageName: recording.packageName,
                signal: continuousSignal,
                processing: eegAnalysisProcessingSnapshot(),
                artifactSources: eegArtifactRejectionSources(),
                excludedChannelIndices: channels.bad,
                channelSets: ChannelSetStore.shared.allSets,
                sensorLayout: recording.sensorLayout,
                onClose: { eegAnalysis.showsSheet = false }
            )

        case .channelHealthDetails:
            channelHealthDetailsSheet(for: continuousSignal)

        case .channelGoodnessSettings:
            ChannelGoodnessSettingsView()
                .environment(goodnessSettings)

        case .channelDecisionReplay:
            if let request = channelDecisionReplayRequest {
                ChannelDecisionReplaySheet(
                    request: request,
                    sourceName: replay.sourceName,
                    selection: binding(recordingStore.status, \.replayChannelDecisionSelection),
                    onApply: { resolveChannelDecisionReplay(.proceed) },
                    onSkip: { resolveChannelDecisionReplay(.skip) }
                )
            }

        case .segmentHealthDetails:
            segmentHealthDetailsSheet()

        case .motionConfig:
            MotionConfigView(
                parameters: $gradient.motionParameters,
                fileFormat: $gradient.motionFileFormat,
                fdThreshold: $gradient.motionFDThreshold,
                radiusMm: $gradient.motionRadiusMm,
                motionMetric: $gradient.motionMetric,
                skipStart: $gradient.skipStart,
                skipEnd: $gradient.skipEnd,
                trSeconds: $gradient.trSeconds,
                trMarkerCode: gradient.trMarkerCode,
                trMarkerSamples: recording.signal.map {
                    trMarkerSamples(in: $0, code: gradient.trMarkerCode)
                } ?? [],
                samplingRate: recording.signal?.samplingRate ?? 0,
                donorVolumes: gradient.donorVolumes,
                onClose: {
                    gradient.showsMotionConfig = false
                    gradient.showsPopover = true
                }
            )
        }
    }
}
