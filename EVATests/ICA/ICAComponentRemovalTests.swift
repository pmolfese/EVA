//
//  ICAComponentRemovalTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Applying an ICA removal to the pipeline, now that it is off `WaveformView`.
//
//  The reconstruction itself is already covered byte-for-byte by
//  `ICAReplayPayloadTests`. What is new here is the *pipeline* half — that a
//  removal invalidates what a new base signal must invalidate, and that
//  `ProcessingCore` can now perform the step at all instead of stopping at it.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct ICAComponentRemovalTests {

    private let samplingRate = 200.0
    private let count = 1_000

    private func mixedChannels(channelCount: Int = 4) -> [[Float]] {
        let s0 = (0..<count).map { sin(2 * .pi * 7 * Double($0) / samplingRate) }
        let s1 = (0..<count).map { 2 * (Double($0 % 50) / 50.0) - 1 }
        let s2 = (0..<count).map { Double(($0 / 31) % 2) * 2 - 1 }
        let mixing: [[Double]] = [
            [0.8, 0.3, -0.4], [-0.5, 0.9, 0.2], [0.2, -0.7, 0.8], [0.6, 0.4, 0.5]
        ]
        return (0..<channelCount).map { c in
            (0..<count).map { t -> Float in
                let a = mixing[c][0] * s0[t]
                let b = mixing[c][1] * s1[t]
                let d = mixing[c][2] * s2[t]
                return Float(a + b + d)
            }
        }
    }

    private func fittedPayload(excluding excluded: Set<Int> = [0]) throws -> (MFFSignalData, ICAReplayPayload) {
        let signal = SyntheticSignal.make(mixedChannels(), samplingRate: samplingRate)
        var decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: ICAConfiguration(
                method: .picard, componentCount: 3, varianceThreshold: 0.99999,
                averageReference: false, downsampleRate: samplingRate, maxIterations: 200,
                learningRate: nil, fitFilter: nil, convergenceTolerance: 1e-7, minimumIterations: 1
            )
        )
        decomposition.excludedComponents = excluded
        return (signal, ICAReplayPayload(decomposition: decomposition, method: .picard))
    }

    @MainActor
    private struct Collaborators {
        let store = RecordingStore()
        let ica: ICAViewModel
        let artifactVM: ArtifactViewModel
        let template: ArtifactTemplateViewModel
        let epoching: EpochingViewModel
        let segHealth: SegmentHealthViewModel

        init() {
            ica = ICAViewModel(store: store)
            artifactVM = ArtifactViewModel(store: store)
            template = ArtifactTemplateViewModel(store: store)
            epoching = EpochingViewModel(store: store)
            segHealth = SegmentHealthViewModel(store: store)
        }
    }

    // MARK: - The pipeline cascade

    @Test func applyingARemovalCommitsAndInvalidatesDownstream() async throws {
        let (signal, payload) = try fittedPayload()
        let c = Collaborators()
        c.epoching.epochedSignal = signal
        c.epoching.isAveraged = true
        c.store.selection.topomapSample = 100
        c.store.channels.interpolated = [2: [0, 1, 2]]
        let tokenBefore = c.artifactVM.detectionRefreshToken

        let cleaned = try await ICAComponentRemoval.apply(
            to: signal, payload: payload,
            ica: c.ica, artifactVM: c.artifactVM, template: c.template,
            epoching: c.epoching, segHealth: c.segHealth, store: c.store
        )

        #expect(c.ica.cleanedSignal != nil)
        #expect(c.ica.cleanedSignal?.data[0] == cleaned.data[0])
        #expect(cleaned.data[0] != signal.data[0], "the removal must actually change the samples")
        #expect(c.epoching.epochedSignal == nil, "epochs describe the pre-removal signal")
        #expect(!c.epoching.isAveraged)
        #expect(c.store.selection.topomapSample == nil)
        #expect(c.store.channels.interpolated.isEmpty,
                "interpolations were computed from samples that no longer exist")
        #expect(c.artifactVM.detectionRefreshToken == tokenBefore + 1)
    }

    /// Detection ran against the pre-removal signal, so its events point at
    /// samples that are gone. Keeping them would mark artifacts that the removal
    /// just eliminated.
    @Test func applyingARemovalDropsStaleArtifactEvents() async throws {
        let (signal, payload) = try fittedPayload()
        let c = Collaborators()
        c.artifactVM.events = [
            MFFEvent(id: "blink-1", code: "blink", beginTimeSeconds: 1,
                     rawBeginTime: "1", sourceFile: "eye.xml")
        ]

        try await ICAComponentRemoval.apply(
            to: signal, payload: payload,
            ica: c.ica, artifactVM: c.artifactVM, template: c.template,
            epoching: c.epoching, segHealth: c.segHealth, store: c.store
        )

        #expect(c.artifactVM.events.isEmpty)
    }

    /// Throwing rather than degrading: a payload that does not fit must not
    /// quietly leave the pipeline holding the uncorrected signal as if the
    /// removal had happened.
    @Test func aMismatchedPayloadThrowsAndCommitsNothing() async throws {
        let (_, payload) = try fittedPayload()
        let c = Collaborators()
        let narrower = SyntheticSignal.make(mixedChannels(channelCount: 3), samplingRate: samplingRate)

        await #expect(throws: ICAReplayError.self) {
            try await ICAComponentRemoval.apply(
                to: narrower, payload: payload,
                ica: c.ica, artifactVM: c.artifactVM, template: c.template,
                epoching: c.epoching, segHealth: c.segHealth, store: c.store
            )
        }
        #expect(c.ica.cleanedSignal == nil)
    }

    @Test func stagedPayloadNeedsBothADecompositionAndAnExclusion() throws {
        let c = Collaborators()
        #expect(ICAComponentRemoval.stagedPayload(c.ica) == nil, "no decomposition")

        let (_, payload) = try fittedPayload()
        c.ica.decomposition = payload.decomposition
        c.ica.decomposition?.excludedComponents = []
        #expect(ICAComponentRemoval.stagedPayload(c.ica) == nil, "nothing excluded")

        c.ica.decomposition?.excludedComponents = [1]
        #expect(ICAComponentRemoval.stagedPayload(c.ica)?.excludedComponents == [1])
    }

    // MARK: - Through ProcessingCore

    private func makeCore(store: RecordingStore) -> ProcessingCore {
        ProcessingCore(
            store: store,
            filter: FilterViewModel(store: store),
            gradient: GradientViewModel(store: store),
            bcg: BCGDetectionViewModel(store: store),
            ica: ICAViewModel(store: store),
            artifactVM: ArtifactViewModel(store: store),
            epoching: EpochingViewModel(store: store),
            wavelet: WaveletReductionViewModel(store: store),
            template: ArtifactTemplateViewModel(store: store),
            segHealth: SegmentHealthViewModel(store: store)
        )
    }

    private func icaScript() -> EVAProcessingScript {
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(
            operation: .icaClean,
            parameters: ["averageReference": "false"],
            replayable: false
        ))
        return script
    }

    /// The headless gap this work closed: `ProcessingCore` used to hit the
    /// `default` case on `icaClean` and hand the file back untouched.
    @Test func processingCoreAppliesICAWhenGivenAPayload() async throws {
        let (signal, payload) = try fittedPayload()
        let store = RecordingStore()
        let core = makeCore(store: store)

        let result = await core.applyAutoSteps(icaScript(), to: signal, icaPayload: payload)

        #expect(result.remainingSteps.isEmpty, "the step must no longer stop the core")
        #expect(core.ica.cleanedSignal != nil)
        #expect(result.signal?.data[0] != signal.data[0])
    }

    /// The safety property: **no payload, no ICA.** A script copied from another
    /// subject arrives without a sidecar, and applying that subject's unmixing
    /// matrix to these electrodes would produce plausible, wrong data.
    ///
    /// It *skips* rather than stops, matching what the step already meant before
    /// this work: a non-replayable step is classified `.skip` and the batch
    /// config pane shows it unchecked as "Recorded for provenance only". Making
    /// this stop would divert batches that complete today into windowed replay.
    @Test func processingCoreSkipsICAWithoutAPayload() async throws {
        let (signal, _) = try fittedPayload()
        let store = RecordingStore()
        let core = makeCore(store: store)

        let result = await core.applyAutoSteps(icaScript(), to: signal, icaPayload: nil)

        #expect(result.remainingSteps.isEmpty, "unchanged from before this work")
        #expect(core.ica.cleanedSignal == nil)
        #expect(result.signal?.data[0] == signal.data[0], "the signal must come back untouched")
    }

    /// A payload that does not fit stops the run rather than skipping the step —
    /// the rest of the script describes data that was never produced.
    @Test func processingCoreStopsOnAMismatchedPayload() async throws {
        let (_, payload) = try fittedPayload()
        let narrower = SyntheticSignal.make(mixedChannels(channelCount: 3), samplingRate: samplingRate)
        let store = RecordingStore()
        let core = makeCore(store: store)

        let result = await core.applyAutoSteps(icaScript(), to: narrower, icaPayload: payload)

        #expect(result.remainingSteps.map(\.operation) == [.icaClean])
        #expect(core.ica.cleanedSignal == nil)
    }

    /// The step's portable settings still restore, so the resulting `eva.xml`
    /// describes the fit that produced the operator rather than app defaults.
    @Test func processingCoreRestoresTheStepsPortableSettings() async throws {
        let (signal, payload) = try fittedPayload()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(
            operation: .icaClean,
            parameters: ["method": "picardO", "components": "17", "averageReference": "true"],
            replayable: false
        ))
        let store = RecordingStore()
        let core = makeCore(store: store)

        _ = await core.applyAutoSteps(script, to: signal, icaPayload: payload)

        #expect(core.ica.method == .picardO)
        #expect(core.ica.componentCount == 17)
        #expect(core.ica.usesAverageReference)
    }

    /// Re-applying from the payload must land on the same samples as the live
    /// decomposition did — the whole premise of storing the operator.
    @Test func coreOutputMatchesADirectReconstruction() async throws {
        let (signal, payload) = try fittedPayload(excluding: [0, 2])
        let direct = try await ICAReplay.apply(to: signal, payload: payload)

        let store = RecordingStore()
        let core = makeCore(store: store)
        let result = await core.applyAutoSteps(icaScript(), to: signal, icaPayload: payload)

        let replayed = try #require(result.signal)
        for channel in direct.data.indices {
            #expect(replayed.data[channel] == direct.data[channel],
                    "channel \(channel) differs through ProcessingCore")
        }
    }
}
