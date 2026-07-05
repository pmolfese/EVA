//
//  ProcessingCore.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Headless apply-core (REFACTOR.md item E / TODO.md Priority 1): applies an
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
//  object as more steps become headless-safe. See TODO.md for the sequencing.
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

    init(
        store: RecordingStore,
        filter: FilterViewModel,
        gradient: GradientViewModel,
        ica: ICAViewModel,
        artifactVM: ArtifactViewModel,
        epoching: EpochingViewModel,
        wavelet: WaveletReductionViewModel
    ) {
        self.store = store
        self.filter = filter
        self.gradient = gradient
        self.ica = ica
        self.artifactVM = artifactVM
        self.epoching = epoching
        self.wavelet = wavelet
    }

    /// Result of a headless run: the signal as far as this core could take it,
    /// plus any steps (in order) it stopped short of applying. A non-empty
    /// `remainingSteps` means the script isn't fully headless-capable yet —
    /// the caller should fall back to windowed replay starting from there.
    struct Result {
        var signal: MFFSignalData?
        var remainingSteps: [EVAProcessingStep]
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
        pnsSignal: MFFSignalData? = nil
    ) async -> Result {
        var current = ica.cleanedSignal ?? gradient.correctedSignal ?? signal

        let steps = script.replayableSteps
        for (index, step) in steps.enumerated() {
            if ReplayCompatibility.check(step, against: current) != nil {
                return Result(signal: current, remainingSteps: Array(steps[index...]))
            }
            switch step.operation {
            case .mriGradientCorrection:
                gradient.apply(parameters: step.parameters)
                await gradient.apply(to: current, pnsSignal: pnsSignal) { [ica, filter] in
                    // The base signal changed, so any ICA/filter output
                    // computed on the old base is now stale.
                    ica.cleanedSignal = nil
                    ica.decomposition = nil
                    filter.output = nil
                    filter.pnsOutput = nil
                    filter.pnsInputSignalType = nil
                }
                current = gradient.correctedSignal ?? current

            case .filter:
                filter.apply(parameters: step.parameters)
                let pnsInput = filter.filterPNS ? pnsFilterBaseSignal(pnsSignal: pnsSignal) : nil
                await filter.apply(to: current, pnsInput: pnsInput, onApplied: {})
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
                await wavelet.apply(to: current, excludedChannels: store.channels.bad, analysisBand: analysisBand)
                current = wavelet.reducedSignal ?? current

            case .segment:
                epoching.apply(parameters: step.parameters)
                guard let job = epoching.makeBuildJob(
                    from: current,
                    events: epoching.segmentField == .artifact ? artifactVM.events : current.events,
                    artifactRejectionEvents: psaArtifactRejectionEvents(for: current),
                    globallyBadChannels: store.channels.bad
                ) else {
                    return Result(signal: current, remainingSteps: Array(steps[index...]))
                }
                if let averaged = await epoching.applyBuildJob(
                    job,
                    averageReference: epoching.averageReference,
                    baselineCorrect: epoching.baselineCorrected,
                    badChannels: store.channels.bad
                ) {
                    current = averaged
                }

            default:
                return Result(signal: current, remainingSteps: Array(steps[index...]))
            }
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
        var events: [MFFEvent] = []
        if epoching.skipEyeBlinks {
            events += EyeArtifactThresholdDetector.detect(
                kind: .blink, channels: signal.data, samplingRate: signal.samplingRate,
                duration: signal.duration, configuration: artifactVM.blinkThresholdConfig)
        }
        if epoching.skipEyeMovements {
            events += EyeArtifactThresholdDetector.detect(
                kind: .movement, channels: signal.data, samplingRate: signal.samplingRate,
                duration: signal.duration, configuration: artifactVM.movementThresholdConfig)
        }
        return events
    }
}
