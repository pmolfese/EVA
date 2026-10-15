//
//  GradientCoverageTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP MRI-1: motion semantics, the motion-required refusal, per-volume
//  coverage, `MRI_GRAD_UNRELIABLE` provenance events, and PSA interval overlap.
//

import Testing
import Foundation
@testable import EVA

struct GradientCoverageTests {

    // MARK: - Motion metric

    /// Moosmann et al. (2009) Eq. 5 is the Euclidean norm of the translation
    /// change; EVA's older translation metric sums absolute values. A diagonal
    /// move separates them by √3.
    @Test func translationSpeedIsTheEuclideanNormOfTheChange() {
        let motion = [
            MotionSample(id: 0, roll: 0, pitch: 0, yaw: 0, dS: 0, dL: 0, dP: 0),
            MotionSample(id: 1, roll: 5, pitch: 5, yaw: 5, dS: 0.2, dL: 0.2, dP: 0.2),
            MotionSample(id: 2, roll: 5, pitch: 5, yaw: 5, dS: 0.2, dL: 0.2, dP: 0.6),
        ]
        let speed = GradientDonorSelection.motionMagnitudes(motion: motion, metric: .translationSpeed, radiusMm: 50)
        let sum = GradientDonorSelection.motionMagnitudes(motion: motion, metric: .translationOnly, radiusMm: 50)
        #expect(speed[0] == 0)
        #expect(abs(speed[1] - (0.12).squareRoot()) < 1e-12)   // √(3·0.2²)
        #expect(abs(speed[2] - 0.4) < 1e-12)                    // single axis: both agree
        #expect(abs(sum[1] - 0.6) < 1e-12)
        #expect(abs(sum[2] - 0.4) < 1e-12)
        // Rotations are ignored by both translation metrics.
        // At the paper's 0.3 mm threshold the diagonal move (0.346) is flagged by
        // either; at 0.5 mm only the L1 sum flags it.
        let flaggedBySpeed = GradientDonorSelection.highMotionVolumes(
            motion: motion, metric: .translationSpeed, thresholdMm: 0.5, radiusMm: 50)
        let flaggedBySum = GradientDonorSelection.highMotionVolumes(
            motion: motion, metric: .translationOnly, thresholdMm: 0.5, radiusMm: 50)
        #expect(flaggedBySpeed.isEmpty)
        #expect(flaggedBySum == [1])
    }

    @MainActor
    @Test func theTranslationSpeedMetricRoundTripsThroughTheScript() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .moosmann
        vm.motionMetric = .translationSpeed
        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: vm.parameters)
        #expect(restored.motionMetric == .translationSpeed)
    }

    // MARK: - Motion required

    @MainActor
    @Test func motionIsRequiredForMoosmannAndForCensoring() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .fastr
        #expect(vm.missingRequiredMotion == nil)
        vm.excludeHighMotion = true
        #expect(vm.missingRequiredMotion != nil)
        vm.excludeHighMotion = false
        vm.method = .moosmann
        #expect(vm.missingRequiredMotion != nil)
        vm.motionParameters = MotionParameters(
            samples: (0..<4).map { MotionSample(id: $0, roll: 0, pitch: 0, yaw: 0, dS: 0, dL: 0, dP: 0) },
            sourceName: "m.1D")
        #expect(vm.missingRequiredMotion == nil)
    }

    /// The interactive Apply is disabled without motion, but replay and batch
    /// used to run Moosmann anyway as plain nearest-neighbour averaging.
    @MainActor
    @Test func aRunNeedingMotionRefusesWithoutIt() async {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .moosmann
        vm.trMarkerCode = "TR"
        await vm.apply(to: Self.periodicGradientSignal(), pnsSignal: nil)
        #expect(vm.correctedSignal == nil)
        #expect(vm.statusIsError)
        #expect(vm.statusMessage?.contains("motion") == true)
    }

    @MainActor
    @Test func headlessReplayStopsAtAGradientStepThatNeedsMotion() async {
        let signal = Self.periodicGradientSignal()
        let core = Self.makeCore()
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .mriGradientCorrection,
                                         parameters: ["method": "FASTR", "trMarkerCode": "TR",
                                                      "excludeHighMotion": "true"]))
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))

        let result = await core.applyAutoSteps(script, to: signal)

        #expect(result.remainingSteps.count == 2)
        #expect(result.remainingSteps.first?.operation == .mriGradientCorrection)
        #expect(core.gradient.correctedSignal == nil)
        #expect(result.signal?.data[0] == signal.data[0])
    }

    // MARK: - Coverage from diagnostics

    private func diagnostics(
        corrected: [Bool], warnings: [GradientCorrectionWarning], upsample: Int = 1
    ) -> GradientCorrectionDiagnostics {
        GradientCorrectionDiagnostics(
            epochCount: corrected.count, period: 100 * upsample,
            samplesBefore: 0, samplesAfter: 100 * upsample - 1,
            referenceChannel: 0, computeBackend: .cpu, highMotionVolumes: [],
            epochs: corrected.enumerated().map { index, ok in
                GradientEpochDiagnostic(
                    epoch: index, trigger: index * 100 * upsample, volume: index, slicePosition: 0,
                    integerShift: 0, fractionalShift: 0, donorIndices: [],
                    templateScale: 1, corrected: ok)
            },
            obsComponentCounts: [], ancAppliedChannels: [],
            warnings: warnings, upsampleFactor: upsample)
    }

    @Test func edgesFailuresFallbacksAndBarrierCrossingsAreDistinguished() {
        let d = diagnostics(
            corrected: [true, true, false, true, false, false, true],
            warnings: [
                .templateScaleRejected(epoch: 1),
                .noEligibleDonors(epoch: 2),
                .donorsCrossedMotionBarrier(epoch: 3),
                .degenerateTemplate(epoch: 4),
                .epochOutOfBounds(epoch: 5),
            ])
        let coverage = GradientCoverage.from(diagnostics: d, sampleCount: 700)
        #expect(coverage.epochs.map(\.status) == [.corrected, .watch, .failed, .unreliable, .failed, .edge, .corrected])
        #expect(coverage.volumeCount == 7)
        #expect(coverage.gradableEpochCount == 6)

        // Epochs 2–4 are contiguous and all unreliable: one span, 200..<500.
        let spans = coverage.unreliableSpans
        #expect(spans.count == 1)
        #expect(spans.first?.startSample == 200)
        #expect(spans.first?.endSample == 500)
        #expect(spans.first?.epochCount == 3)
        #expect(spans.first?.reasons == ["noEligibleDonors": 1, "donorsCrossedMotionBarrier": 1, "degenerateTemplate": 1])
    }

    /// An uncorrected epoch the engine gave no reason for is still a failure,
    /// and says so rather than carrying an empty reason list.
    @Test func anUnexplainedUncorrectedEpochIsAFailure() {
        let coverage = GradientCoverage.from(
            diagnostics: diagnostics(corrected: [true, false, true], warnings: []), sampleCount: 300)
        #expect(coverage.epochs[1].status == .failed)
        #expect(coverage.epochs[1].reasons == ["uncorrected"])
    }

    @Test func upsampledEpochsArePlacedOnTheRecordingsOwnAxis() {
        let coverage = GradientCoverage.from(
            diagnostics: diagnostics(corrected: [true, false, true], warnings: [.noEligibleDonors(epoch: 1)], upsample: 4),
            sampleCount: 300)
        #expect(coverage.epochs[1].startSample == 100)
        #expect(coverage.epochs[1].endSample == 200)
    }

    @Test func separatedFailuresStaySeparateSpans() {
        let coverage = GradientCoverage.from(
            diagnostics: diagnostics(
                corrected: [false, true, false],
                warnings: [.noEligibleDonors(epoch: 0), .noEligibleDonors(epoch: 2)]),
            sampleCount: 300)
        #expect(coverage.unreliableSpans.map(\.startSample) == [0, 200])
    }

    @Test func motionFileMismatchIsARunLevelNote() {
        let coverage = GradientCoverage.from(
            diagnostics: diagnostics(corrected: [true, true], warnings: [.motionRowsFrontPadded(count: 3)]),
            sampleCount: 200)
        #expect(coverage.runNotes.count == 1)
        #expect(coverage.unreliableSpans.isEmpty)
    }

    @Test func localTemplateSkipsMapToEdgeAndFailure() {
        let summaries = [
            LocalTemplateEventSummary(eventIndex: 0, donorIndices: [1], skippedReason: nil, methodName: "m"),
            LocalTemplateEventSummary(eventIndex: 1, donorIndices: [], skippedReason: .insufficientDonors, methodName: "m"),
            LocalTemplateEventSummary(eventIndex: 2, donorIndices: [], skippedReason: .outsideRecording, methodName: "m"),
        ]
        let coverage = GradientCoverage.from(localSummaries: summaries, triggers: [200, 0, 100, 100], sampleCount: 300)
        #expect(coverage.epochs.map(\.status) == [.corrected, .failed, .edge])
        #expect(coverage.epochs[1].startSample == 100)
        #expect(coverage.epochs[1].endSample == 200)
    }

    // MARK: - Events

    @Test func spansBecomeOnsetAnchoredDurationEvents() {
        let coverage = GradientCoverage.from(
            diagnostics: diagnostics(corrected: [true, false, false, true],
                                     warnings: [.noEligibleDonors(epoch: 1), .noEligibleDonors(epoch: 2)]),
            sampleCount: 400)
        let events = coverage.unreliableEvents(samplingRate: 1000)
        #expect(events.count == 1)
        let event = events[0]
        #expect(event.code == GradientCoverage.unreliableEventCode)
        #expect(event.timeAnchor == .onset)
        #expect(abs(event.beginTimeSeconds - 0.1) < 1e-12)
        #expect(abs((event.durationSeconds ?? 0) - 0.2) < 1e-12)
        #expect(event.eventDescription?.contains("2 epochs") == true)
    }

    @Test func aReRunReplacesThePreviousRunsSpans() {
        let old = MFFEvent(id: "old", code: GradientCoverage.unreliableEventCode, beginTimeSeconds: 5,
                           rawBeginTime: "5", sourceFile: GradientCoverage.eventSourceFile, durationSeconds: 1)
        let tr = MFFEvent(id: "tr", code: "TREV", beginTimeSeconds: 1, rawBeginTime: "1", sourceFile: "x")
        let new = MFFEvent(id: "new", code: GradientCoverage.unreliableEventCode, beginTimeSeconds: 2,
                           rawBeginTime: "2", sourceFile: GradientCoverage.eventSourceFile, durationSeconds: 1)
        let merged = GradientCoverage.replacingUnreliableEvents(in: [old, tr], with: [new])
        #expect(merged.map(\.id) == ["tr", "new"])
    }

    /// End to end: a local-template run that cannot find enough donors for any
    /// TR leaves the scan uncorrected, and says where.
    @MainActor
    @Test func aFailedRunMarksItsSpansOnTheCorrectedSignal() async throws {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .mas
        vm.trMarkerCode = "TR"
        vm.localMinimumDonorCount = 1000
        vm.localSkipsTargetsWithoutEnoughDonors = true
        await vm.apply(to: Self.periodicGradientSignal(), pnsSignal: nil)

        let corrected = try #require(vm.correctedSignal)
        let spans = corrected.events.filter { $0.code == GradientCoverage.unreliableEventCode }
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { ($0.durationSeconds ?? 0) > 0 })
        #expect(vm.coverage?.epochCount(.failed) ?? 0 > 0)
        #expect(vm.auditLogLines.contains { $0.hasPrefix("mriGradientCorrection coverage:") })
        #expect(vm.auditLogLines.contains { $0.hasPrefix("mriGradientCorrection unreliable:") })

        // Report-only records the same coverage and writes no events.
        let quiet = GradientViewModel(store: RecordingStore())
        quiet.apply(parameters: vm.parameters)
        quiet.unreliablePolicy = .reportOnly
        await quiet.apply(to: Self.periodicGradientSignal(), pnsSignal: nil)
        let quietSignal = try #require(quiet.correctedSignal)
        #expect(!quietSignal.events.contains { $0.code == GradientCoverage.unreliableEventCode })
        #expect(quiet.coverage == vm.coverage)
    }

    @MainActor
    @Test func theUnreliablePolicyRoundTrips() {
        let vm = GradientViewModel(store: RecordingStore())
        #expect(vm.parameters["unreliableEvents"] == "mark")
        vm.unreliablePolicy = .reportOnly
        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: vm.parameters)
        #expect(restored.unreliablePolicy == .reportOnly)
    }

    // MARK: - Grade

    private func metrics(corrected: Int, total: Int, edge: Int?, unreliable: Int? = nil,
                         notes: [String]? = nil) -> GradientRunMetrics {
        GradientRunMetrics(
            residualFractionP90: 0.01, residualFractionMedian: 0.01,
            residualFractionMax: 0.01, worstChannel: 0,
            inBandResidualFractionP90: 0.01, inBandResidualFractionMedian: 0.01,
            removedVarianceFraction: 0.999,
            correctedEpochs: corrected, totalEpochs: total, gradedChannelCount: 8,
            edgeEpochs: edge, unreliableEpochs: unreliable, coverageNotes: notes)
    }

    private func coverageGrade(_ m: GradientRunMetrics) -> RunGrade? {
        GradientRunGrade.grade(from: m).metrics.first { $0.name == "Epoch coverage" }?.grade
    }

    /// Ten edge epochs used to cost a 100-epoch run its Good grade.
    @Test func edgeEpochsDoNotCountAgainstCoverage() {
        #expect(coverageGrade(metrics(corrected: 90, total: 100, edge: nil)) == .watch)
        #expect(coverageGrade(metrics(corrected: 90, total: 100, edge: 10)) == .good)
    }

    @Test func anyUnreliableSpanOrNoteIsWorthALookButNeverPoorAlone() {
        #expect(coverageGrade(metrics(corrected: 100, total: 100, edge: 0, unreliable: 1)) == .watch)
        #expect(coverageGrade(metrics(corrected: 100, total: 100, edge: 0, notes: ["motion file short"])) == .watch)
        #expect(coverageGrade(metrics(corrected: 100, total: 100, edge: 0, unreliable: 0)) == .good)
    }

    /// History entries written before the coverage fields existed must decode.
    @Test func olderMetricsStillDecode() throws {
        let legacy = """
        {"residualFractionP90":0.01,"residualFractionMedian":0.01,"residualFractionMax":0.01,
         "removedVarianceFraction":0.999,"correctedEpochs":10,"totalEpochs":10,"gradedChannelCount":4}
        """
        let decoded = try JSONDecoder().decode(GradientRunMetrics.self, from: Data(legacy.utf8))
        #expect(decoded.edgeEpochs == nil)
        #expect(decoded.correctedEpochFraction == 1)
    }

    // MARK: - PSA

    @Test func overlapCountsAnEventThatStartedBeforeTheWindow() {
        let blink = MFFEvent(id: "b", code: "blink", beginTimeSeconds: 0.9, rawBeginTime: "0.9",
                             sourceFile: "x", durationSeconds: 0.4, timeAnchor: .onset)
        #expect(blink.overlaps(startSeconds: 1.0, endSeconds: 2.0))
        #expect(!blink.overlaps(startSeconds: 1.4, endSeconds: 2.0))
        // Centred: 0.9 ± 0.2.
        let centred = MFFEvent(id: "c", code: "blink", beginTimeSeconds: 0.9, rawBeginTime: "0.9",
                               sourceFile: "x", durationSeconds: 0.4, timeAnchor: .center)
        #expect(centred.overlaps(startSeconds: 1.0, endSeconds: 2.0))
        #expect(!centred.overlaps(startSeconds: 1.2, endSeconds: 2.0))
        // A point event is the old start-inside test.
        let point = MFFEvent(id: "p", code: "x", beginTimeSeconds: 0.9, rawBeginTime: "0.9", sourceFile: "x")
        #expect(!point.overlaps(startSeconds: 1.0, endSeconds: 2.0))
        #expect(point.overlaps(startSeconds: 0.5, endSeconds: 0.9))
    }

    @MainActor
    @Test func psaMRIRejectionSerializesAndIsOffForOlderScripts() {
        let vm = EpochingViewModel(store: RecordingStore())
        #expect(vm.skipUnreliableMRI)
        #expect(vm.parameters["skipUnreliableMRI"] == "true")
        var older = vm.parameters
        older.removeValue(forKey: "skipUnreliableMRI")
        let restored = EpochingViewModel(store: RecordingStore())
        restored.apply(parameters: older)
        #expect(!restored.skipUnreliableMRI)
    }

    // MARK: - C3: final TR and missing markers

    /// A recording that ends one TR after its last marker lacks only the final
    /// window's closing sample. Allen IAR left that whole TR uncorrected — the
    /// reason it read ~100× worse than local-median on clock-synced data.
    @Test func allenIARCorrectsTheFinalTROfARecordingThatStopsWithTheScan() throws {
        let signal = Self.periodicGradientSignal()
        let triggers = signal.events.map { Int(($0.beginTimeSeconds * signal.samplingRate).rounded()) }
        #expect(triggers.last! + 100 == signal.data[0].count, "precondition: ends one TR after the last marker")

        let result = try GradientAAS.correct(
            channels: signal.data, volumeTriggers: triggers,
            config: .allenIARVolume, samplingRate: signal.samplingRate)
        let allCorrected = result.diagnostics.epochs.allSatisfy { $0.corrected }
        #expect(allCorrected)
        #expect(result.channels[0].count == signal.data[0].count)

        // The final TR's residual is no worse than an interior one's.
        func energy(_ range: Range<Int>) -> Double {
            range.reduce(0.0) { $0 + Double(result.channels[0][$1] * result.channels[0][$1]) }
        }
        let raw = (1900..<2000).reduce(0.0) { $0 + Double(signal.data[0][$1] * signal.data[0][$1]) }
        #expect(energy(1900..<2000) < raw * 0.2)
    }

    @Test func missingMarkersAreFoundFromTheTriggerSpacing() {
        // TR 100, markers at 400 and 500 missing.
        let triggers = [0, 100, 200, 300, 600, 700, 800]
        let gaps = GradientCoverage.missingTriggerGaps(triggers: triggers)
        #expect(gaps.count == 1)
        #expect(gaps.first?.start == 400)
        #expect(gaps.first?.end == 600)
        #expect(gaps.first?.missing == 2)
        // Ordinary one-sample jitter is not a gap.
        #expect(GradientCoverage.missingTriggerGaps(triggers: [0, 100, 201, 300, 399, 500]).isEmpty)
    }

    /// A volume whose next marker is missing is sliced on the median TR, not
    /// across the whole gap.
    @Test func aVolumeBeforeAMissingMarkerIsSlicedOnTheMedianTR() throws {
        let layout = try GradientEpochLayout.build(
            volumeTriggers: [0, 100, 200, 400, 500], sampleCount: 700,
            slicesPerVolume: 4, upsampleFactor: 1, relativeTriggerPosition: 0)
        let slicesOfVolume2 = zip(layout.volumeIndex, layout.triggers).filter { $0.0 == 2 }.map(\.1)
        #expect(slicesOfVolume2 == [200, 225, 250, 275])
    }

    /// End to end: one missing marker leaves one TR of full artifact, which is
    /// now marked and graded Watch rather than passing silently.
    @MainActor
    @Test func aMissingMarkerIsMarkedUnreliableAndGradedWatch() async throws {
        let full = Self.periodicGradientSignal()
        let dropped = full.replacingEvents(full.events.filter { $0.id != "tr10" })
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .allenIAR
        vm.trMarkerCode = "TR"
        await vm.apply(to: dropped, pnsSignal: nil)

        let corrected = try #require(vm.correctedSignal)
        let spans = corrected.events.filter { $0.code == GradientCoverage.unreliableEventCode }
        #expect(spans.count == 1)
        #expect(abs((spans.first?.beginTimeSeconds ?? 0) - 1.0) < 1e-9)       // sample 1000
        #expect(abs((spans.first?.durationSeconds ?? 0) - 0.1) < 1e-9)        // one TR
        #expect(vm.coverage?.runNotes.contains { $0.contains("missing") } == true)
        let metrics = try #require(vm.runMetrics)
        let coverageGrade = GradientRunGrade.grade(from: metrics).metrics.first { $0.name == "Epoch coverage" }?.grade
        #expect(coverageGrade == .watch)
    }

    // MARK: - Fixtures

    @MainActor
    static func makeCore() -> ProcessingCore {
        let store = RecordingStore()
        return ProcessingCore(
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

    /// Slow physiology plus a large artifact repeating every TR, with TR events
    /// — the same construction `ProcessingCoreTests` uses.
    static func periodicGradientSignal(spacing: Int = 100, nTR: Int = 20) -> MFFSignalData {
        let sampleCount = spacing * nTR
        let samplingRate = 1000.0
        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount {
            let k = t % spacing
            channel[t] = 5 * Float(sin(2 * .pi * 3 * Double(t) / 1000))
                + 50 * Float(sin(Double(k) * 0.3)) + 30 * Float(k % 7)
        }
        let events = stride(from: 0, to: sampleCount, by: spacing).enumerated().map { i, sample in
            MFFEvent(id: "tr\(i)", code: "TR", beginTimeSeconds: Double(sample) / samplingRate,
                     rawBeginTime: "\(sample)", sourceFile: "test")
        }
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/synthetic.bin"),
            signalType: "EEG", numberOfChannels: 1, samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate, recordingStartTime: nil,
            events: events, data: [channel])
    }
}
