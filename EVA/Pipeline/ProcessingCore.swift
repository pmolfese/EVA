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
        icaPayload: ICAReplayPayload? = nil,
        artifactPayload: ArtifactReplayPayload? = nil,
        progress: ((ProgressUpdate) -> Void)? = nil
    ) async -> Result {
        var current = ica.cleanedSignal ?? gradient.correctedSignal ?? signal

        // `icaClean` is `replayable: false` — correctly, because the fitted
        // operator belongs to one subject's electrodes and Copy Processing must
        // not carry it onto another. But when the caller supplies **that
        // package's own** `eva_ica.json`, the step is re-applicable after all:
        // it becomes two matrix multiplies against the recorded operator, not a
        // refit. So it joins the walk, and the `.icaClean` case below decides.
        //
        // **Only when a payload is in hand.** Without one the step stays out of
        // the walk, exactly as `replayableSteps` left it before — which is not a
        // silent omission: a non-replayable step is classified `.skip`, and the
        // batch config pane shows it as "Recorded for provenance only", unchecked
        // by default. The user has already been told it will not run. Making the
        // absent-payload case *stop* instead would send batches that complete
        // today off to windowed replay for no reason.
        //
        // The safety property is structural rather than checked: the payload is
        // read from the *input package* (`HeadlessBatchProcessor`), never from
        // whatever file the script came from, so a script copied from another
        // subject arrives with no payload and nothing changes.
        let steps = script.steps.filter {
            $0.replayable
                || ($0.operation == .icaClean && icaPayload != nil)
                || ($0.operation == .artifactClean && artifactPayload != nil)
                // `markBad` needs no payload — the channel list *is* the step —
                // and it has to be applied, not merely carried. Skipping it left
                // `store.channels.bad` empty, and because the outgoing script is
                // rebuilt from that state, the incoming mark was then stripped:
                // a batch output claiming no channels were bad when its own
                // script said one was. Found by a paired run, 2026-08-13.
                || $0.operation == .markBad
        }
        // Lights off before the walk, so the script alone decides. Without this
        // a script with no `reference` step still average-referenced its epochs,
        // because `EpochingViewModel.averageReference` defaults to *true* and
        // "leave it alone" is not the same as "off". Same derivation the
        // interactive navigation uses — see `ReplaySettingsRestore`.
        let lights = ReplaySettingsRestore.settings(for: steps)
        filter.averageReference = lights.continuousReference != nil
        epoching.averageReference = lights.epochReference != nil
        epoching.baselineCorrected = lights.baselineCorrection

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

            case .reference:
                // Nothing to do here, and that is the point.
                //
                // The flags this step encodes were set from the *whole* step
                // list before the walk started, so the re-reference happens
                // inside `FilterViewModel`'s tail (continuous) or inside the PSA
                // fold (epoch) — the same two places, on the same buffers, at
                // the same points in the chain as an interactive run.
                //
                // The first version of this applied a separate pass over
                // `filter.output` here, which was one ordering argument away
                // from re-referencing twice: `.filter` had already done it,
                // because `averageReference` was still set. Deriving the flags
                // up front and leaving the arithmetic where it has always lived
                // removes the interactive/headless split rather than reasoning
                // about it, which is what every paired-run divergence in this
                // project has argued for.
                break

            case .baseline:
                // Same shape as `.reference`, and simpler: the flag was already
                // set from the whole step list before the walk started, and
                // `applyBuildJob`'s own fold applies it when `segment` runs.
                break

            case .icaClean:
                // Unreachable without a payload — the filter above kept the step
                // out of the walk. Belt and braces, and it keeps the `guard`
                // honest if that filter ever changes.
                guard let icaPayload else {
                    return Result(signal: current, remainingSteps: Array(steps[index...]))
                }
                ica.apply(parameters: step.parameters)
                do {
                    let before = current
                    current = try await ICAComponentRemoval.apply(
                        to: current,
                        payload: icaPayload,
                        ica: ica,
                        artifactVM: artifactVM,
                        template: template,
                        epoching: epoching,
                        segHealth: segHealth,
                        store: store
                    )
                    store.cleaningVariance.record(
                        CleaningVarianceAccount.between(
                            original: before,
                            cleaned: current,
                            epochSeconds: CleaningVarianceAccount.defaultEpochSeconds,
                            stageName: "icaClean"
                        )
                    )
                } catch {
                    // Stopping rather than continuing with the uncorrected
                    // signal: a payload that does not fit this recording means
                    // the rest of the script describes data we do not have.
                    ica.statusMessage = error.localizedDescription
                    return Result(signal: current, remainingSteps: Array(steps[index...]))
                }

            case .artifactClean:
                // Same contract as `icaClean`: unreachable without a payload,
                // and the payload comes from the input package rather than the
                // script's source, so templates drawn on one subject's blink
                // cannot be applied to another's.
                guard let artifactPayload else {
                    return Result(signal: current, remainingSteps: Array(steps[index...]))
                }
                // Templates are re-derived against `current` — the signal being
                // cleaned — rather than restored from whatever the definition was
                // drawn on. See `ArtifactReplayPayload`.
                let artifacts = artifactPayload.artifacts(rederivedAgainst: current)
                template.definedArtifacts = artifacts
                let outcome = ArtifactCleaner.cleanedSignal(
                    from: current,
                    artifacts: artifacts,
                    excluding: store.channels.bad.union(store.channels.interpolated.keys)
                )
                ArtifactCleaningCore.commit(
                    cleanedSignal: outcome.signal,
                    summaries: outcome.summaries,
                    statusMessage: "Cleaned \(outcome.summaries.count) artifact(s).",
                    artifactVM: artifactVM,
                    template: template,
                    epoching: epoching,
                    segHealth: segHealth,
                    store: store
                )
                store.cleaningVariance.record(
                    CleaningVarianceAccount.between(
                        original: current,
                        cleaned: outcome.signal,
                        epochSeconds: CleaningVarianceAccount.defaultEpochSeconds,
                        stageName: "artifactClean"
                    )
                )
                current = outcome.signal

            case .markBad:
                // Absolute, not additive: the step carries the whole set, so it
                // replaces rather than unions. That is what makes "unmark a
                // channel" expressible as an ordinary step — see `REWIND.md`,
                // *Channel decisions: the carry-through rules*.
                store.channels.bad = ChannelDecisionSteps.channelIndices(
                    from: step.parameters["channels"] ?? ""
                )

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
