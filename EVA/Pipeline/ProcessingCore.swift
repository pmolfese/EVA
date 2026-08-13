//
//  ProcessingCore.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Headless apply-core (ROADMAP.md, completed batch suite): applies an
//  `EVAProcessingScript`'s auto steps to a signal with NO SwiftUI view, panel,
//  or gate involved — the prerequisite for unattended (windowless) batch.
//  Unlike `WaveformView.interactiveReplay()` (which drives popovers/sheets for
//  review/decision steps), this only touches already-headless-safe VMs and
//  stops at the first step it can't apply without a human or a view — the
//  caller routes the remainder to windowed replay.
//
//  This is a thin sequencer, not a home for algorithm code: each domain owns
//  its own transform (`FilterViewModel.apply(to:pnsInput:onApplied:)`,
//  `GradientViewModel.apply(to:pnsSignal:onApplied:)`, …) so it stays
//  independently testable and this file doesn't balloon into a second god
//  object as more steps become headless-safe. See ROADMAP.md for the sequencing.
//

import Foundation

@MainActor
final class ProcessingCore {
    let store: RecordingStore
    let filter: FilterViewModel
    let gradient: GradientViewModel
    let ica: ICAViewModel
    let artifactVM: ArtifactViewModel
    let epoching: EpochingViewModel
    let wavelet: WaveletReductionViewModel
    // Needed so the headless path can run the *same* invalidation cascade as the
    // interactive one. Without these two it could only clear part of it, which is
    // exactly the divergence `PipelineInvalidation` exists to remove.
    let template: ArtifactTemplateViewModel
    let segHealth: SegmentHealthViewModel
    /// Spherical electrode positions, needed for PSA's per-epoch bad-channel
    /// interpolation and the escalation of persistently-bad channels to globally
    /// bad. Empty degrades to reject-only, which is what the headless path did
    /// before this was plumbed — silently producing different averages from the
    /// interactive path on the same input.
    let electrodePositions: [Int: SIMD3<Double>]

    init(
        store: RecordingStore,
        filter: FilterViewModel,
        gradient: GradientViewModel,
        ica: ICAViewModel,
        artifactVM: ArtifactViewModel,
        epoching: EpochingViewModel,
        wavelet: WaveletReductionViewModel,
        template: ArtifactTemplateViewModel,
        segHealth: SegmentHealthViewModel,
        electrodePositions: [Int: SIMD3<Double>] = [:]
    ) {
        self.store = store
        self.filter = filter
        self.gradient = gradient
        self.ica = ica
        self.artifactVM = artifactVM
        self.epoching = epoching
        self.wavelet = wavelet
        self.template = template
        self.segHealth = segHealth
        self.electrodePositions = electrodePositions
    }

    /// Result of a headless run: the signal as far as this core could take it,
    /// plus any steps (in order) it stopped short of applying. A non-empty
    /// `remainingSteps` means the script isn't fully headless-capable yet —
    /// the caller should fall back to windowed replay starting from there.
    struct Result {
        var signal: MFFSignalData?
        var remainingSteps: [EVAProcessingStep]
    }

    struct ProgressUpdate {
        var stepName: String
        var stepProgress: Double?
        var fileProgress: Double
    }

    /// Applies as many leading steps of `script` as this core supports, in
    /// order, starting from `signal` (already gradient/ICA-corrected if the
    /// caller has that upstream state — otherwise pass the raw recording
    /// signal). Stops at the first step it can't do headlessly (a decision
    /// step like ICA/artifact-clean, a transform not yet ported here, or —
    /// via `ReplayCompatibility` — a step that doesn't fit this particular
    /// signal, e.g. gradient correction with no matching TR markers). Stopping
    /// (rather than skipping) preserves chain order: a later step this core
    /// CAN do (e.g. filter after an unsupported gradient step) must not
    /// silently run out of order. This is also the headless path's safety
    /// net against silently no-oping: without it, an incompatible step would
    /// just fail inside its own VM (`statusIsError`) while this core carried
    /// on with the unchanged signal as if nothing were wrong.
    func applyAutoSteps(
        _ script: EVAProcessingScript,
        to signal: MFFSignalData,
        pnsSignal: MFFSignalData? = nil,
        progress: ((ProgressUpdate) -> Void)? = nil
    ) async -> Result {
        var current = ica.cleanedSignal ?? gradient.correctedSignal ?? signal

        let steps = script.replayableSteps
        for (index, step) in steps.enumerated() {
            let stepName = ReplayStepDisplay.label(for: step.operation)
            let stepBase = steps.isEmpty ? 1 : Double(index) / Double(steps.count)
            let stepDone = steps.isEmpty ? 1 : Double(index + 1) / Double(steps.count)
            progress?(ProgressUpdate(stepName: stepName, stepProgress: nil, fileProgress: stepBase))
            if ReplayCompatibility.check(step, against: current) != nil {
                return Result(signal: current, remainingSteps: Array(steps[index...]))
            }
            switch step.operation {
            case .mriGradientCorrection:
                gradient.apply(parameters: step.parameters)
                await gradient.apply(to: current, pnsSignal: pnsSignal) { [self] in
                    // The base signal changed. This used to clear only ICA and
                    // filter output here, while the interactive path also cleared
                    // artifact cleaning, epochs, and interpolations — so a
                    // headless or replayed run carried stale downstream state.
                    // One cascade now serves both.
                    PipelineInvalidation.downstreamOfBaseSignalChange(
                        store: store,
                        ica: ica,
                        filter: filter,
                        artifactVM: artifactVM,
                        template: template,
                        epoching: epoching,
                        segHealth: segHealth
                    )
                }
                current = gradient.correctedSignal ?? current

            case .filter:
                filter.apply(parameters: step.parameters)
                let pnsInput = filter.filterPNS ? pnsFilterBaseSignal(pnsSignal: pnsSignal) : nil
                await filter.apply(to: current, pnsInput: pnsInput) { [self] in
                    // Was `onApplied: {}` — the interactive path cleared applied
                    // artifact cleaning, epochs, and interpolations here, so a
                    // headless run carried stale downstream state.
                    PipelineInvalidation.downstreamOfFilterChange(
                        store: store,
                        artifactVM: artifactVM,
                        template: template,
                        epoching: epoching,
                        segHealth: segHealth
                    )
                }
                current = filter.output ?? current

            case .thresholdArtifactDetection:
                artifactVM.detectionMethod = .threshold
                artifactVM.blinkThresholdConfig = .fromFlatParameters(
                    step.parameters, prefix: "blink", base: artifactVM.blinkThresholdConfig)
                artifactVM.movementThresholdConfig = .fromFlatParameters(
                    step.parameters, prefix: "movement", base: artifactVM.movementThresholdConfig)

            case .waveletReduce:
                wavelet.apply(parameters: step.parameters)
                let analysisBand: (low: Double, high: Double)? = {
                    guard let low = filter.highPassCutoff, let high = filter.lowPassCutoff else { return nil }
                    return (low, high)
                }()
                // Previously passed no `onApplied` at all, so headless wavelet
                // reduction left stale epochs, interpolations, and artifact
                // detection behind.
                await wavelet.apply(
                    to: current,
                    excludedChannels: store.channels.bad,
                    analysisBand: analysisBand
                ) { [self] in
                    PipelineInvalidation.downstreamOfWaveletChange(
                        store: store,
                        artifactVM: artifactVM,
                        epoching: epoching,
                        segHealth: segHealth
                    )
                }
                current = wavelet.reducedSignal ?? current

            case .segment:
                epoching.apply(parameters: step.parameters)
                guard let job = epoching.makeBuildJob(
                    from: current,
                    events: epoching.segmentField == .artifact ? artifactVM.events : current.events,
                    artifactRejectionEvents: psaArtifactRejectionEvents(for: current),
                    electrodePositions: electrodePositions,
                    globallyBadChannels: store.channels.bad
                ) else {
                    return Result(signal: current, remainingSteps: Array(steps[index...]))
                }
                if let averaged = await epoching.applyBuildJob(
                    job,
                    averageReference: epoching.averageReference,
                    baselineCorrect: epoching.baselineCorrected,
                    badChannels: store.channels.bad,
                    electrodePositions: electrodePositions,
                    continuousSignal: current
                ) {
                    current = averaged
                }

            default:
                return Result(signal: current, remainingSteps: Array(steps[index...]))
            }
            progress?(ProgressUpdate(stepName: stepName, stepProgress: 1, fileProgress: stepDone))
        }
        return Result(signal: current, remainingSteps: [])
    }

    private func pnsFilterBaseSignal(pnsSignal: MFFSignalData?) -> MFFSignalData? {
        guard let raw = pnsSignal else { return nil }
        if gradient.appliesToPNS, let correctedPNS = gradient.correctedPNSSignal {
            return correctedPNS
        }
        return raw
    }

    /// Eye-blink/movement rejection events for PSA, computed fresh via the L3
    /// detector (matching `WaveformView.artifactEventsOrDetection`'s fallback
    /// branch). Doesn't include defined-artifact-template rejection — this
    /// core doesn't hold an `ArtifactTemplateViewModel` (that's the drawn,
    /// per-subject decision step this core already stops at).
    private func psaArtifactRejectionEvents(for signal: MFFSignalData) -> [MFFEvent] {
        guard epoching.skipIfContainsArtifact, epoching.segmentField != .artifact else { return [] }
        let sensorLayoutName = SensorLayout.load(fromPackageContaining: signal.signalURL)?.name
        var events: [MFFEvent] = []
        if epoching.skipEyeBlinks {
            events += EyeArtifactThresholdDetector.detect(
                kind: .blink, channels: signal.data, samplingRate: signal.samplingRate,
                duration: signal.duration, sensorLayoutName: sensorLayoutName,
                configuration: artifactVM.blinkThresholdConfig)
        }
        if epoching.skipEyeMovements {
            events += EyeArtifactThresholdDetector.detect(
                kind: .movement, channels: signal.data, samplingRate: signal.samplingRate,
                duration: signal.duration, sensorLayoutName: sensorLayoutName,
                configuration: artifactVM.movementThresholdConfig)
        }
        return events
    }
}
