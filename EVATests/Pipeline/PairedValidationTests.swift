//
//  PairedValidationTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP RW-1 item 4 — paired interactive/headless validation, by byte
//  comparison rather than by argument.
//
//  Every divergence this project has shipped had the same shape: two paths that
//  were *supposed* to do the same thing, agreed about in prose, and differed in
//  fact — headless referencing twice, a headless wavelet pass excluding nothing,
//  a batch output whose eva.xml claimed a bad channel its own state had lost. So
//  the standard here is sample equality, and the comparisons run through the
//  same public entry points the app does.
//
//  ## What is covered where
//
//  Two of item 4's five comparisons are already load-bearing tests elsewhere,
//  and are not duplicated here:
//
//  - **ICA replay** — `ICAReplayPayloadTests.rehydratedApplyMatchesFitApply`
//    compares a payload round-tripped through disk against the live
//    decomposition's own output. This file adds the *pipeline-level* pairing:
//    the same payload driven through `ProcessingCore`.
//  - **Artifact-template re-derivation** —
//    `ArtifactReplayPayloadTests.rederivingAgainstTheSameSignalReproducesTheTemplate`
//    compares a re-derived template against the original samples.
//
//  This file covers the rest: `markBad` (including the ambient-application rule
//  from item 3), channel interpolation, continuous and epoch referencing, and
//  gradient motion parameters. Motion is compared on the exclusion set the
//  parameters produce rather than on corrected samples — the repository carries
//  no MRI fixture with TR markers, and the set is the decision those parameters
//  actually drive.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct PairedValidationTests {

    // MARK: - Fixtures

    @MainActor
    private struct Pipeline {
        let store = RecordingStore()
        let filter: FilterViewModel
        let gradient: GradientViewModel
        let ica: ICAViewModel
        let artifactVM: ArtifactViewModel
        let epoching: EpochingViewModel
        let wavelet: WaveletReductionViewModel
        let template: ArtifactTemplateViewModel
        let segHealth: SegmentHealthViewModel
        let bcg: BCGDetectionViewModel

        init() {
            filter = FilterViewModel(store: store)
            gradient = GradientViewModel(store: store)
            ica = ICAViewModel(store: store)
            artifactVM = ArtifactViewModel(store: store)
            epoching = EpochingViewModel(store: store)
            wavelet = WaveletReductionViewModel(store: store)
            template = ArtifactTemplateViewModel(store: store)
            segHealth = SegmentHealthViewModel(store: store)
            bcg = BCGDetectionViewModel(store: store)
        }

        func core(positions: [Int: SIMD3<Double>] = [:]) -> ProcessingCore {
            ProcessingCore(
                store: store, filter: filter, gradient: gradient, bcg: bcg, ica: ica,
                artifactVM: artifactVM, epoching: epoching, wavelet: wavelet,
                template: template, segHealth: segHealth, electrodePositions: positions
            )
        }
    }

    /// Four channels of deterministic noise with a repeated evoked bump, plus
    /// `stim` events — the same generator shape `ProcessingCoreTests` uses.
    private func stimSignal(
        channelCount: Int = 4, spacing: Int = 500, nEvents: Int = 8, samplingRate: Double = 250
    ) -> MFFSignalData {
        let sampleCount = spacing * (nEvents + 1)
        var state: UInt64 = 918_273
        func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1
            return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
        }
        var data: [[Float]] = (0..<channelCount).map { channel in
            (0..<sampleCount).map { _ in noise() * Float(channel + 1) }
        }
        let triggers = (1...nEvents).map { $0 * spacing }
        for trigger in triggers {
            for channel in data.indices {
                for k in 0..<40 where trigger + k < sampleCount {
                    data[channel][trigger + k] += 40 * Float(sin(Double(k) * 0.3))
                }
            }
        }
        let events = triggers.enumerated().map { index, sample in
            MFFEvent(
                id: "stim\(index)", code: "stim",
                beginTimeSeconds: Double(sample) / samplingRate,
                rawBeginTime: "\(sample)", sourceFile: "test"
            )
        }
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/paired-validation.bin"),
            signalType: "EEG",
            numberOfChannels: channelCount,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: events,
            data: data
        )
    }

    /// Four electrodes spread over the sphere, enough for a spline solve.
    private func positions(_ count: Int = 8) -> [Int: SIMD3<Double>] {
        var result: [Int: SIMD3<Double>] = [:]
        for index in 0..<count {
            let theta = Double(index) * 2.399963  // golden-angle spiral
            let z = 1 - 2 * (Double(index) + 0.5) / Double(count)
            let r = (1 - z * z).squareRoot()
            result[index] = SIMD3(r * cos(theta), r * sin(theta), z)
        }
        return result
    }

    private func expectSameSamples(
        _ lhs: MFFSignalData, _ rhs: MFFSignalData, _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(lhs.data.count == rhs.data.count, "\(what): channel count", sourceLocation: sourceLocation)
        for channel in lhs.data.indices where rhs.data.indices.contains(channel) {
            #expect(
                lhs.data[channel] == rhs.data[channel],
                "\(what): channel \(channel) differs",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - markBad

    /// The ambient-application rule from ROADMAP RW-1 item 3, as a byte
    /// comparison.
    ///
    /// `ChannelDecisionSteps` writes `markBad` before the first `segment`, or at
    /// the end when there is none — so in a wavelet-only script the mark is
    /// written **after** the wavelet step it has to affect. Wavelet reduction
    /// takes `channels.bad` as its excluded set, so a replay that applied the
    /// mark in written order would exclude nothing and produce different
    /// samples from the session that wrote the script.
    @Test("A markBad written after wavelet still excludes the channel from it")
    func markBadAppliesBeforeTheStepsThatConsultIt() async throws {
        let signal = stimSignal()

        // Interactive: the operator marked Ch 2 bad, then ran wavelet reduction.
        let live = Pipeline()
        live.store.channels.bad = [1]
        live.wavelet.apply(parameters: ["mode": "conservative"])
        await live.wavelet.apply(
            to: signal, excludedChannels: live.store.channels.bad, analysisBand: nil
        )
        let interactive = live.wavelet.reducedSignal

        // Headless: the script that session wrote, in the order it wrote it.
        let replayed = Pipeline()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .waveletReduce, parameters: ["mode": "conservative"]))
        script = ChannelDecisionSteps.inserted(
            into: script, badChannels: [1], interpolatedChannels: []
        )
        #expect(
            script.steps.map(\.operation) == [.waveletReduce, .markBad],
            "precondition: the mark really is written after the step it affects"
        )
        let result = await replayed.core().applyAutoSteps(script, to: signal)

        #expect(replayed.store.channels.bad == [1])
        let headless = try #require(result.signal)
        let interactiveSignal = try #require(interactive)
        expectSameSamples(interactiveSignal, headless, "wavelet output with a bad channel")
    }

    /// The comparison above only means something if excluding the channel
    /// changes the samples at all.
    @Test("Excluding a bad channel really does change the wavelet output")
    func exclusionIsObservable() async {
        let signal = stimSignal()

        let excluded = Pipeline()
        excluded.wavelet.apply(parameters: ["mode": "conservative"])
        await excluded.wavelet.apply(to: signal, excludedChannels: [1], analysisBand: nil)

        let included = Pipeline()
        included.wavelet.apply(parameters: ["mode": "conservative"])
        await included.wavelet.apply(to: signal, excludedChannels: [], analysisBand: nil)

        #expect(excluded.wavelet.reducedSignal?.data != included.wavelet.reducedSignal?.data)
    }

    @Test("markBad replaces the bad set rather than merging into it")
    func markBadIsAbsolute() async {
        let signal = stimSignal()
        let replayed = Pipeline()
        replayed.store.channels.bad = [3]

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(
            operation: .markBad, parameters: ["channels": "1,2", "scope": "ambient"],
            replayable: false
        ))
        _ = await replayed.core().applyAutoSteps(script, to: signal)

        #expect(replayed.store.channels.bad == [0, 1])
    }

    // MARK: - Interpolation

    /// Interactive and headless repairs must be the same arithmetic, which they
    /// are because they are the same function — this is the test that keeps it
    /// that way (`ChannelInterpolationSolver`, RW-1 item 3).
    @Test("A replayed interpolation reproduces the click's samples exactly")
    func interpolationParity() async throws {
        let signal = stimSignal(channelCount: 8)
        let geometry = positions(8)

        // Interactive: the solver the click runs, with the same ambient state.
        let direct = try #require(
            try? ChannelInterpolationSolver.solve(
                target: 2, in: signal, bad: [5], alreadyInterpolated: [], positions: geometry
            ).get()
        )

        // Headless: the recorded decision, replayed.
        let replayed = Pipeline()
        var script = EVAProcessingScript()
        script = ChannelDecisionSteps.inserted(
            into: script, badChannels: [5], interpolatedChannels: [2]
        )
        _ = await replayed.core(positions: geometry).applyAutoSteps(script, to: signal)

        #expect(replayed.store.channels.interpolated[2] == direct.replacement)
        #expect(replayed.store.channels.interpolationSources[2]?.indices == direct.indices)
        #expect(replayed.store.channels.interpolationSources[2]?.weights == direct.weights)
        // A repaired channel is no longer bad, and no loss was recorded.
        #expect(replayed.store.channels.bad.contains(2) == false)
        #expect(replayed.store.channels.interpolationLost.isEmpty)
    }

    /// The failure contract: a recorded repair that cannot be re-solved here
    /// must return the channel to bad and say so — never leave it looking good,
    /// and never leave stale replacement samples active.
    @Test("A repair that cannot be re-solved is lost explicitly, not ignored")
    func unsolvableInterpolationBecomesAnExplicitLoss() async {
        let signal = stimSignal(channelCount: 8)
        let replayed = Pipeline()

        var script = EVAProcessingScript()
        script = ChannelDecisionSteps.inserted(
            into: script, badChannels: [], interpolatedChannels: [2]
        )
        // No electrode positions: nothing to solve from.
        _ = await replayed.core(positions: [:]).applyAutoSteps(script, to: signal)

        #expect(replayed.store.channels.interpolated[2] == nil, "no stale replacement samples")
        #expect(replayed.store.channels.bad.contains(2), "the channel goes back to bad")
        #expect(replayed.store.channels.interpolationLost[2] != nil, "and the loss is recorded")

        // And it reaches the audit log, so a batch output says it too.
        let lines = ProcessingAuditLog.lines(
            gradient: replayed.gradient,
            bcg: replayed.bcg,
            epoching: replayed.epoching,
            channels: replayed.store.channels,
            cleaningVariance: replayed.store.cleaningVariance
        )
        #expect(lines.contains { $0.hasPrefix("interpolateChannels lost:") })
    }

    // MARK: - ICA replay through the pipeline

    /// `ICAReplayPayloadTests` proves the payload re-applies to the same
    /// samples. This proves the *pipeline* does: the step, the payload, and
    /// `ProcessingCore`'s walk together produce what applying the payload
    /// directly does — no extra centring, no missed invalidation, no double
    /// application.
    @Test("An icaClean step with its payload matches applying the payload directly")
    func icaReplayThroughTheCoreMatchesDirectApply() async throws {
        let samplingRate = 200.0
        let count = 1200
        let sources: [[Double]] = [
            (0..<count).map { sin(2 * .pi * 7 * Double($0) / samplingRate) },
            (0..<count).map { 2 * (Double($0 % 50) / 50.0) - 1 },
            (0..<count).map { Double(($0 / 31) % 2) * 2 - 1 }
        ]
        let mixing: [[Double]] = [
            [0.8, 0.3, -0.4], [-0.5, 0.9, 0.2], [0.2, -0.7, 0.8], [0.6, 0.4, 0.5]
        ]
        var channels: [[Float]] = []
        for channel in 0..<4 {
            var series = [Float](repeating: 0, count: count)
            for t in 0..<count {
                var value: Double = 0
                for source in 0..<3 {
                    value += mixing[channel][source] * sources[source][t]
                }
                series[t] = Float(value)
            }
            channels.append(series)
        }
        let signal = SyntheticSignal.make(channels, samplingRate: samplingRate)

        var decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: ICAConfiguration(
                method: .picard,
                componentCount: 3,
                varianceThreshold: 0.99999,
                averageReference: false,
                downsampleRate: samplingRate,
                maxIterations: 300,
                learningRate: nil,
                fitFilter: nil,
                convergenceTolerance: 1e-7,
                minimumIterations: 1
            )
        )
        decomposition.excludedComponents = [0]
        let payload = ICAReplayPayload(decomposition: decomposition, method: .picard)

        let direct = try await ICAReplay.apply(to: signal, payload: payload)

        let replayed = Pipeline()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(
            operation: .icaClean, parameters: replayed.ica.parameters, replayable: false
        ))
        let result = await replayed.core().applyAutoSteps(
            script, to: signal, icaPayload: payload
        )
        #expect(result.remainingSteps.isEmpty)
        let headless = try #require(result.signal)

        expectSameSamples(direct, headless, "ICA-cleaned signal")
    }

    // MARK: - Referencing

    @Test("Continuous referencing replays to the same samples it produced")
    func continuousReferenceParity() async throws {
        let signal = stimSignal()

        let live = Pipeline()
        live.filter.apply(parameters: ["highPassHz": "1.0", "lowPassHz": "40.0"])
        live.filter.averageReference = true
        await live.filter.apply(to: signal, pnsInput: nil, onApplied: {})
        let interactive = try #require(live.filter.output)

        let replayed = Pipeline()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(
            operation: .filter, parameters: ["highPassHz": "1.0", "lowPassHz": "40.0"]
        ))
        script.append(EVAProcessingStep(
            operation: .reference,
            parameters: Rereferencing.parameters(
                scheme: .average, domain: .continuous, excluding: []
            )
        ))
        let result = await replayed.core().applyAutoSteps(script, to: signal)
        let headless = try #require(result.signal)

        expectSameSamples(interactive, headless, "average-referenced continuous signal")
    }

    /// The `reference` step is what turns referencing on; a script without one
    /// must not re-reference, whatever the view model's default happens to be.
    /// (That default is `true` for epochs, which is how a headless run once
    /// average-referenced epochs no script asked for.)
    @Test("No reference step means no referencing, in either domain")
    func absentReferenceStepLeavesTheSignalAlone() async throws {
        let signal = stimSignal()

        let referenced = Pipeline()
        var withStep = EVAProcessingScript()
        withStep.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))
        withStep.append(EVAProcessingStep(
            operation: .reference,
            parameters: Rereferencing.parameters(
                scheme: .average, domain: .continuous, excluding: []
            )
        ))
        let withResult = await referenced.core().applyAutoSteps(withStep, to: signal)

        let plain = Pipeline()
        var withoutStep = EVAProcessingScript()
        withoutStep.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))
        let withoutResult = await plain.core().applyAutoSteps(withoutStep, to: signal)

        #expect(referenced.filter.averageReference)
        #expect(plain.filter.averageReference == false)
        let a = try #require(withResult.signal)
        let b = try #require(withoutResult.signal)
        #expect(a.data != b.data, "the reference step has to be doing something")
    }

    @Test("Epoch referencing is driven by the step, and reproduces itself")
    func epochReferenceParity() async throws {
        let signal = stimSignal()
        let segmentParameters = [
            "eventCodes": "stim", "preStimulusMs": "40", "postStimulusMs": "120",
            "average": "true", "interpolateBadChannelsPerEpoch": "false"
        ]

        func run() async -> Pipeline {
            let pipeline = Pipeline()
            var script = EVAProcessingScript()
            script.append(EVAProcessingStep(
                operation: .reference,
                parameters: Rereferencing.parameters(
                    scheme: .average, domain: .epoch, excluding: []
                )
            ))
            script.append(EVAProcessingStep(operation: .segment, parameters: segmentParameters))
            _ = await pipeline.core().applyAutoSteps(script, to: signal)
            return pipeline
        }

        let first = await run()
        let second = await run()
        #expect(first.epoching.averageReference)
        let a = try #require(first.epoching.epochedSignal)
        let b = try #require(second.epoching.epochedSignal)
        expectSameSamples(a, b, "epoch-referenced average")

        // And the step is what turned it on: without one, the same script's
        // epochs are not average-referenced.
        let unreferenced = Pipeline()
        var plain = EVAProcessingScript()
        plain.append(EVAProcessingStep(operation: .segment, parameters: segmentParameters))
        _ = await unreferenced.core().applyAutoSteps(plain, to: signal)
        #expect(unreferenced.epoching.averageReference == false)
        let c = try #require(unreferenced.epoching.epochedSignal)
        #expect(a.data != c.data)
    }

    // MARK: - Gradient motion parameters

    /// Motion parameters decide which volumes are excluded. Replaying the step
    /// has to reproduce that decision exactly — a threshold or metric that did
    /// not survive serialization would silently correct a different set of
    /// volumes, which is the same class of bug as re-referencing twice.
    @Test("Replayed motion settings exclude exactly the same volumes")
    func gradientMotionParametersParity() {
        let motion = MotionParameters(
            samples: (0..<12).map { index in
                let jolt = index == 5 || index == 9
                return MotionSample(
                    id: index,
                    roll: jolt ? 0.9 : 0.01, pitch: 0.02, yaw: 0.01,
                    dS: jolt ? 1.4 : 0.05, dL: 0.03, dP: 0.04
                )
            },
            sourceName: "synthetic.1D"
        )

        let live = GradientViewModel(store: RecordingStore())
        live.motionParameters = motion
        live.excludeHighMotion = true
        live.motionFDThreshold = 0.4
        live.motionMetric = .allParameters
        let interactive = live.highMotionVolumeSet()
        #expect(!interactive.isEmpty, "precondition: the fixture has high-motion volumes")

        let replayed = GradientViewModel(store: RecordingStore())
        replayed.apply(parameters: live.parameters)
        replayed.motionParameters = motion

        #expect(replayed.highMotionVolumeSet() == interactive)
        #expect(replayed.motionFDThreshold == live.motionFDThreshold)
        #expect(replayed.motionMetric == live.motionMetric)
    }

    // MARK: - Payload/script consistency instrumentation

    /// The observed impossible state: a package carrying `eva_ica.json` whose
    /// `eva.xml` records no `icaClean`. Instrumented rather than guessed at
    /// (RW-1 item 4).
    @Test("A payload with no step is reported, in both directions")
    func payloadConsistencyFindings() {
        var withStep = EVAProcessingScript()
        withStep.append(EVAProcessingStep(operation: .icaClean, replayable: false))

        #expect(
            PayloadConsistency.findings(
                script: withStep, hasICAPayload: false, hasArtifactPayload: false
            ) == [.stepWithoutPayload(kind: .ica)]
        )
        #expect(
            PayloadConsistency.findings(
                script: EVAProcessingScript(), hasICAPayload: true, hasArtifactPayload: false
            ) == [.payloadWithoutStep(kind: .ica)]
        )
        // Agreement in either direction is silent.
        #expect(
            PayloadConsistency.findings(
                script: withStep, hasICAPayload: true, hasArtifactPayload: false
            ).isEmpty
        )
        #expect(
            PayloadConsistency.findings(
                script: EVAProcessingScript(), hasICAPayload: false, hasArtifactPayload: false
            ).isEmpty
        )
    }

    // MARK: - PCA-S (ROADMAP SI-3)

    /// A beat-locked recording with electrode coordinates: enough for PCA-S to
    /// have something to remove and somewhere to put the brain model.
    private func beatLockedSignal(
        channelCount: Int = 16, samplingRate: Double = 250, duration: Double = 30
    ) -> (signal: MFFSignalData, positions: [Int: SIMD3<Double>]) {
        let sampleCount = Int(samplingRate * duration)
        var state: UInt64 = 5_150_237
        func noise() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return (Double(state >> 40) / Double(UInt32.max) - 0.5) * 8
        }
        var data = (0..<channelCount).map { channel in
            (0..<sampleCount).map { sample in
                Float(6 * sin(2 * .pi * (7 + Double(channel % 3)) * Double(sample) / samplingRate)
                      + noise())
            }
        }
        // Beats every 0.85 s, each stamping a fixed spatial pattern.
        var beatTimes: [Double] = []
        let pattern = (0..<channelCount).map { cos(Double($0) / Double(channelCount) * 2 * .pi) }
        var time = 1.0
        while time < duration - 1 {
            beatTimes.append(time)
            let start = Int(time * samplingRate)
            for offset in 0..<Int(0.5 * samplingRate) where start + offset < sampleCount {
                let phase = Double(offset) / (0.5 * samplingRate)
                let shape = sin(2 * .pi * phase) * exp(-1.5 * phase)
                for channel in 0..<channelCount {
                    data[channel][start + offset] += Float(60 * shape * pattern[channel])
                }
            }
            time += 0.85
        }
        let events = beatTimes.enumerated().map { index, seconds in
            MFFEvent(
                id: "beat\(index)", code: BCGDetector.eventCode,
                beginTimeSeconds: seconds,
                rawBeginTime: "\(Int(seconds * samplingRate))", sourceFile: "test"
            )
        }
        let signal = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/paired-pcas.bin"),
            signalType: "EEG",
            numberOfChannels: channelCount,
            samplingRate: samplingRate,
            duration: duration,
            recordingStartTime: nil,
            events: events,
            data: data,
            channelNames: (0..<channelCount).map { "E\($0 + 1)" }
        )
        return (signal, positions(channelCount))
    }

    /// SI-3's exit criterion, as a byte comparison: the same recording and the
    /// same settings must produce the same samples whether PCA-S is applied
    /// through the sheet's runner or replayed headlessly from `eva.xml`.
    ///
    /// Both sides go through `BCGSurrogateCorrection`, which is the point — the
    /// test is here to catch a *second* path appearing, the way the gradient
    /// cascade grew four hand-written copies before RW-1 item 14 found them.
    @Test func surrogateCorrectionMatchesBetweenDirectUseAndHeadlessReplay() async throws {
        let fixture = beatLockedSignal()
        var settings = BCGSurrogateSettings.default
        settings.regionalSourceCount = 20

        // Interactive: what the sheet's runner does, minus the view models.
        let beats = fixture.signal.events
            .filter { $0.code == BCGDetector.eventCode }
            .map(\.beginTimeSeconds)
        let direct = try await BCGSurrogateCorrection.correct(
            data: fixture.signal.data,
            samplingRate: fixture.signal.samplingRate,
            correctedRows: Array(fixture.signal.data.indices),
            geometry: ElectrodeGeometry(name: "test", positions: fixture.positions),
            channelNames: fixture.signal.channelNames,
            beatSeconds: beats,
            settings: settings
        )

        // Headless: the same thing arrived at from a recorded script.
        var script = EVAProcessingScript()
        var parameters = settings.parameters
        parameters["method"] = BCGDetectionMethod.surrogatePCAS.rawValue
        parameters["beatEventCode"] = BCGDetector.eventCode
        script.append(EVAProcessingStep(operation: .bcgCorrection, parameters: parameters))

        let pipeline = Pipeline()
        let core = pipeline.core(positions: fixture.positions)
        let result = await core.applyAutoSteps(script, to: fixture.signal)

        #expect(result.remainingSteps.isEmpty, "the step did not run headlessly")
        let headless = try #require(result.signal)
        expectSameSamples(
            fixture.signal.replacingSamples(direct.data),
            headless,
            "PCA-S interactive vs headless"
        )

        // The premise: the correction actually changed the recording, so the
        // comparison is not two copies of the input.
        #expect(headless.data != fixture.signal.data)
        // And the headless path leaves the same provenance the interactive one
        // does — the account the roadmap names, and the fitted report.
        #expect(pipeline.store.cleaningVariance.accounts.contains {
            $0.stageName == BCGSurrogateCorrection.varianceStageName
        })
        let report = try #require(pipeline.bcg.surrogateReport)
        #expect(report.artifactComponentCount == direct.report.artifactComponentCount)
        #expect(pipeline.bcg.appliedCorrection == .surrogatePCAS)
    }

    /// A file with no beats must stop the walk rather than emit an uncorrected
    /// recording whose own script claims it was corrected.
    @Test func headlessSurrogateCorrectionStopsWhenTheFileHasNoBeats() async throws {
        let fixture = beatLockedSignal()
        let withoutBeats = MFFSignalData(
            signalURL: fixture.signal.signalURL,
            signalType: fixture.signal.signalType,
            numberOfChannels: fixture.signal.numberOfChannels,
            samplingRate: fixture.signal.samplingRate,
            duration: fixture.signal.duration,
            recordingStartTime: nil,
            events: [],
            data: fixture.signal.data,
            channelNames: fixture.signal.channelNames
        )
        var script = EVAProcessingScript()
        var parameters = BCGSurrogateSettings.default.parameters
        parameters["beatEventCode"] = BCGDetector.eventCode
        script.append(EVAProcessingStep(operation: .bcgCorrection, parameters: parameters))

        let pipeline = Pipeline()
        let core = pipeline.core(positions: fixture.positions)
        let result = await core.applyAutoSteps(script, to: withoutBeats)

        #expect(result.remainingSteps.count == 1, "the step must not be treated as done")
        #expect(result.signal?.data == withoutBeats.data)
        #expect(pipeline.bcg.correctedSignal == nil)
    }

    /// Geometry is a refusal, not a fallback — headlessly too, where there is
    /// nobody to warn.
    @Test func headlessSurrogateCorrectionStopsWithoutCoordinates() async throws {
        let fixture = beatLockedSignal()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(
            operation: .bcgCorrection,
            parameters: BCGSurrogateSettings.default.parameters
        ))

        let pipeline = Pipeline()
        // No positions: the package carried no coordinates.
        let core = pipeline.core()
        let result = await core.applyAutoSteps(script, to: fixture.signal)

        #expect(result.remainingSteps.count == 1)
        #expect(pipeline.bcg.correctedSignal == nil)
    }
}
