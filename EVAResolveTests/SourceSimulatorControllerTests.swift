//
//  SourceSimulatorControllerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-2/SIM-3 Stage 1 — the Source Simulator's live forward field. These exercise
//  the in-process path (no CLI): the controller building a lead field from placed
//  dipoles and turning it into scalp potentials, which is what makes dragging a
//  dipole update the topomap in real time.
//

import Foundation
import Testing
@testable import EVAResolve

@MainActor
@Suite("Source Simulator")
struct SourceSimulatorControllerTests {

    @Test("produces a scalp field for the default dipole")
    func producesField() {
        let controller = SourceSimulatorController()
        let potentials = controller.scalpPotentials()
        #expect(potentials != nil)
        #expect(potentials?.count == controller.montage.electrodes.count)
        // A real dipole makes a spatially varying field, not a flat one.
        if let potentials {
            let spread = (potentials.max() ?? 0) - (potentials.min() ?? 0)
            #expect(spread > 0.1, "expected a non-trivial topography, got spread \(spread)")
        }
    }

    @Test("average reference zero-sums across channels")
    func averageReferenceZeroSums() throws {
        let controller = SourceSimulatorController()
        controller.reference = .average
        let potentials = try #require(controller.scalpPotentials())
        let mean = potentials.reduce(0, +) / Double(potentials.count)
        let peak = potentials.map(abs).max() ?? 1
        #expect(abs(mean) < peak * 1e-6, "average reference should make the channel mean ~0")
    }

    @Test("moving a dipole changes the field")
    func movingChangesField() {
        let controller = SourceSimulatorController()
        let before = try? #require(controller.scalpPotentials())
        controller.sources[0].positionMeters = controller.clampInsideBrain(SIMD3(0.04, -0.02, 0.0))
        let after = try? #require(controller.scalpPotentials())
        #expect(before != after, "the topography should differ after the source moves")
    }

    @Test("keeps sources inside the brain shell")
    func clampsInsideBrain() {
        let controller = SourceSimulatorController()
        let clamped = controller.clampInsideBrain(SIMD3(1, 1, 1)) // far outside
        let radius = (clamped.x * clamped.x + clamped.y * clamped.y + clamped.z * clamped.z).squareRoot()
        #expect(radius <= controller.brainRadiusMeters)
        // And the solver accepts the clamped position.
        controller.sources[0].positionMeters = clamped
        #expect(controller.scalpPotentials() != nil)
    }

    @Test("high-density montages solve", arguments: [19, 32, 64, 128, 256])
    func highDensitySolves(count: Int) {
        let controller = SourceSimulatorController()
        controller.channelCount = count
        let potentials = controller.scalpPotentials()
        #expect(potentials?.count == count)
        #expect(controller.electrodeDisc().count == count)
    }

    @Test("option-drag rotation aims the arrow while staying a unit vector")
    func rotationAimsInPlane() {
        // Axial plane rotates about z: aim toward +x should give orientation ≈ +x,
        // and the z (out-of-plane) component is preserved.
        let start = SIMD3<Double>(0, 0, 0.6) // 0.6 tilt out of the axial plane
        let rotated = HeadProjectionView.Plane.axial.rotatedOrientation(towards: 1, 0, from: start)
        let norm = (rotated.x * rotated.x + rotated.y * rotated.y + rotated.z * rotated.z).squareRoot()
        #expect(abs(norm - 1) < 1e-9, "orientation must stay a unit vector")
        #expect(abs(rotated.z - 0.6) < 1e-9, "out-of-plane tilt is preserved")
        #expect(rotated.x > 0 && abs(rotated.y) < 1e-9, "in-plane heading points toward +x")
        // In-plane magnitude fills the rest of the unit length.
        #expect(abs(rotated.x - (1 - 0.36).squareRoot()) < 1e-9)
    }

    @Test("rotating with a zero direction leaves orientation unchanged")
    func rotationNoOpOnZero() {
        let start = SIMD3<Double>(0, 0.6, 0.8)
        let rotated = HeadProjectionView.Plane.coronal.rotatedOrientation(towards: 0, 0, from: start)
        #expect(rotated == start)
    }

    @Test("a time course makes the field vary over the epoch")
    func timeCourseVariesField() {
        let controller = SourceSimulatorController()
        controller.sources[0].activations = [
            .init(startSeconds: 0, lengthSeconds: controller.durationSeconds,
                  amplitudeNanoampereMeters: 20, waveform: .sine(frequencyHz: 5))
        ]
        // Quarter period of a 5 Hz sine (0.05 s) swings from 0 to peak.
        let atZero = controller.fieldPotentials(atSample: 0)
        let atPeak = controller.fieldPotentials(atSample: Int(0.05 * controller.sampleRate))
        #expect(atZero != atPeak)
        // At t=0 a sine is 0, so the field should be ~flat there.
        if let atZero { #expect((atZero.map(abs).max() ?? 0) < 1e-6) }
    }

    @Test("erp bump peaks at the window centre")
    func erpPeaks() {
        let controller = SourceSimulatorController()
        controller.sources[0].activations = [
            .init(startSeconds: 0.2, lengthSeconds: 0.2,
                  amplitudeNanoampereMeters: 20, waveform: .erp(widthSeconds: 0.02))
        ]
        let rate = controller.sampleRate
        let atCentre = controller.fieldPotentials(atSample: Int(0.30 * rate)) // window centre
        let early = controller.fieldPotentials(atSample: Int(0.05 * rate))    // before the window
        let peakC = atCentre?.map(abs).max() ?? 0
        let peakE = early?.map(abs).max() ?? 0
        #expect(peakC > peakE, "the transient should be strongest at the window centre")
    }

    @Test("activations fire only inside their window")
    func activationsAreWindowed() {
        let controller = SourceSimulatorController()
        controller.durationSeconds = 2
        controller.sources[0].activations = [
            .init(startSeconds: 0.5, lengthSeconds: 0.5,
                  amplitudeNanoampereMeters: 30, waveform: .hold)
        ]
        let before = controller.fieldPotentials(atSample: Int(0.1 * controller.sampleRate))
        #expect((before?.map(abs).max() ?? 1) < 1e-9, "silent before the window")
        let inside = controller.fieldPotentials(atSample: Int(0.7 * controller.sampleRate))
        #expect((inside?.map(abs).max() ?? 0) > 1e-3, "active inside the window")
    }

    @Test("generate scalp EEG writes a readable MFF")
    func generatesReadableRecording() throws {
        let controller = SourceSimulatorController()
        controller.channelCount = 32
        controller.durationSeconds = 2
        controller.sampleRate = 256
        controller.sources[0].activations = [
            .init(startSeconds: 0, lengthSeconds: 2,
                  amplitudeNanoampereMeters: 20, waveform: .sine(frequencyHz: 8))
        ]

        let url = try controller.writeRecording()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        let signal = try MFFReader().loadSignal(from: url)
        #expect(signal.numberOfChannels == 32)
        #expect(signal.data.first?.count == controller.sampleCount)
        // The layout sidecars were written, so a topomap-capable layout loads.
        #expect(SensorLayout.load(fromPackageContaining: signal.signalURL) != nil)
    }

    // MARK: Stage 3b — noise + truth-backed scoring

    @Test("noise is scaled to the requested SNR")
    func noiseHitsTargetSNR() {
        // A non-trivial clean field: 8 channels of a sine.
        let clean = (0..<8).map { c in
            (0..<200).map { t in Double(c + 1) * sin(2 * .pi * 6 * Double(t) / 200) }
        }
        for model in SourceSimulatorNoise.Model.allCases {
            for target in [-3.0, 0.0, 6.0, 12.0] {
                let noise = SourceSimulatorNoise.noiseMatrix(clean: clean, model: model, targetSNRdB: target, seed: 5)
                let noisy = clean.indices.map { c in clean[c].indices.map { clean[c][$0] + noise[c][$0] } }
                let score = SourceSimulatorNoise.score(clean: clean, noisy: noisy)
                #expect(abs(score.snrDb - target) < 1e-6, "\(model) @ \(target)dB → \(score.snrDb)")
            }
        }
    }

    @Test("noise is deterministic in its seed")
    func noiseIsDeterministic() {
        let clean = [[1.0, 2, 3, 4, 5, 6, 7, 8]]
        let a = SourceSimulatorNoise.noiseMatrix(clean: clean, model: .pink, targetSNRdB: 5, seed: 42)
        let b = SourceSimulatorNoise.noiseMatrix(clean: clean, model: .pink, targetSNRdB: 5, seed: 42)
        let c = SourceSimulatorNoise.noiseMatrix(clean: clean, model: .pink, targetSNRdB: 5, seed: 43)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("identical fields score as perfect")
    func identicalScoresPerfect() {
        let field = [[1.0, -2, 3, -4], [0.5, 0.5, -0.5, -0.5]]
        let score = SourceSimulatorNoise.score(clean: field, noisy: field)
        #expect(score.snrDb.isInfinite)
        #expect(abs(score.correlation - 1) < 1e-9)
    }

    @Test("enabling noise changes the field and yields a live score")
    func noiseChangesFieldAndScores() throws {
        let controller = SourceSimulatorController()
        let clean = try #require(controller.cleanPotentials())

        controller.noiseEnabled = true
        controller.noiseModel = .white
        controller.noiseTargetSNRdB = 3
        controller.showNoisyField = true

        #expect(controller.hasContamination)
        let noisy = try #require(controller.scalpPotentials())
        // The shown field now differs from the clean truth.
        let maxDelta = zip(clean, noisy).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDelta > 1e-9)

        // Whole-recording SNR matches the request (constant field → exact).
        let overall = try #require(controller.overallScore())
        #expect(abs(overall.snrDb - 3) < 1e-6)
        #expect(controller.liveScore() != nil)
    }

    @Test("artifacts inject onto the field with recoverable truth")
    func artifactsInjectWithTruth() {
        let montage = Montage.standard(count: 32)
        var options = SourceSimulatorArtifacts.Options()
        options.blink = true
        options.blinksPerMinute = 60          // ~4 blinks in 4 s
        options.blinkAmplitudeMicrovolts = 100
        let result = SourceSimulatorArtifacts.inject(
            montage: montage, channelCount: 32, samplingRate: 250, durationSeconds: 4, options: options
        )
        #expect(!result.truth.blinkSeconds.isEmpty)
        let energy = result.channels.flatMap { $0 }.map(abs).max() ?? 0
        #expect(energy > 1, "blink should leave a visible frontal deflection, got \(energy)")
    }

    @Test("generate writes clean + noisy + truth sidecar under contamination")
    func generateWritesTruthBackedSet() throws {
        let controller = SourceSimulatorController()
        controller.channelCount = 32
        controller.durationSeconds = 2
        controller.noiseEnabled = true
        controller.noiseTargetSNRdB = 6

        let url = try controller.writeRecording()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(url.lastPathComponent == "source_sim_noisy.mff")
        let cleanURL = directory.appendingPathComponent("source_sim_clean.mff")
        let truthURL = directory.appendingPathComponent("source_sim_truth.json")
        #expect(FileManager.default.fileExists(atPath: cleanURL.path))
        #expect(FileManager.default.fileExists(atPath: truthURL.path))

        let sidecar = try JSONDecoder().decode(SourceSimulatorController.TruthSidecar.self, from: Data(contentsOf: truthURL))
        #expect(sidecar.noiseEnabled)
        #expect(!sidecar.dipoles.isEmpty)
        #expect(sidecar.overallSNRdB != nil)
    }

    @Test("electrode disc has one point per channel within the unit range")
    func electrodeDisc() {
        let controller = SourceSimulatorController()
        controller.channelCount = 32
        let disc = controller.electrodeDisc()
        #expect(disc.count == 32)
        // Azimuthal layout: 10-20 electrodes sit at or inside the equator (r≈1),
        // with a little headroom for below-equator sites.
        for entry in disc {
            let r = (entry.point.x * entry.point.x + entry.point.y * entry.point.y).squareRoot()
            #expect(r < 1.6)
        }
    }

    // MARK: - Stage 3c — single-dipole-fit localization diagnostic

    @Test("a clean single-dipole field is recovered to sub-centimetre")
    func cleanFieldRecoversSource() throws {
        // The default scene is one dipole firing a hold from t=0, so the field at
        // the playhead is a single clean dipole — the sanity case the fit must ace.
        let controller = SourceSimulatorController()
        let loc = try #require(controller.liveLocalization())
        #expect(loc.usedNoisyField == false)
        #expect(loc.trueSourceName == "Source 1")
        let mm = try #require(loc.positionErrorMillimeters)
        let deg = try #require(loc.orientationErrorDegrees)
        #expect(mm < 3, "clean recovery should be sub-centimetre, got \(mm) mm")
        #expect(deg < 5, "clean orientation should be close, got \(deg)°")
        #expect(loc.fit.goodnessOfFit > 0.99, "one dipole explains a one-dipole field")
    }

    @Test("noise degrades the fit relative to the clean field")
    func noiseDegradesFit() throws {
        let controller = SourceSimulatorController()
        let clean = try #require(controller.liveLocalization())

        controller.noiseEnabled = true
        controller.noiseModel = .white
        controller.noiseTargetSNRdB = -3   // heavy noise so the effect is unambiguous
        controller.showNoisyField = true
        let noisy = try #require(controller.liveLocalization())

        #expect(noisy.usedNoisyField == true)
        #expect(noisy.fit.goodnessOfFit < clean.fit.goodnessOfFit,
                "a noisy field is explained less well by one dipole")
        let cleanMM = try #require(clean.positionErrorMillimeters)
        let noisyMM = try #require(noisy.positionErrorMillimeters)
        #expect(noisyMM > cleanMM, "noise should move the fitted position off the truth")
    }

    @Test("a single dipole cannot fully explain two simultaneous sources")
    func multipleSourcesDegradeSingleFit() throws {
        let single = SourceSimulatorController()
        let singleLoc = try #require(single.liveLocalization())

        let controller = SourceSimulatorController()
        // Add a second, spatially distinct source firing at the same instant.
        controller.sources.append(
            SourceSimulatorController.Source(
                name: "Source 2",
                positionMeters: controller.clampInsideBrain(SIMD3(-0.04, -0.03, 0.02)),
                orientationUnit: SIMD3(1, 0, 0),
                activations: [SourceSimulatorController.Activation(
                    startSeconds: 0, lengthSeconds: 4,
                    amplitudeNanoampereMeters: 20, waveform: .hold)]
            )
        )
        let twoLoc = try #require(controller.liveLocalization())

        #expect(twoLoc.fit.goodnessOfFit < singleLoc.fit.goodnessOfFit,
                "one dipole should explain a two-dipole field less completely")
        let twoMM = try #require(twoLoc.positionErrorMillimeters)
        #expect(twoMM > 5, "the single fit sits away from the dominant source, got \(twoMM) mm")
    }

    @Test("silence at the playhead leaves nothing to fit")
    func silenceHasNoFit() {
        let controller = SourceSimulatorController()
        // Confine the only activation to late in the epoch, then scrub to t=0.
        controller.sources[0].activations = [
            SourceSimulatorController.Activation(
                startSeconds: 3, lengthSeconds: 0.5,
                amplitudeNanoampereMeters: 20, waveform: .hold)
        ]
        controller.currentTime = 0
        #expect(controller.liveLocalization() == nil,
                "with a flat field there is no dipole to localize")
    }

    // MARK: - Stage 3c — sequential multi-dipole fit

    @Test("fits one dipole per source and recovers two separated sources")
    func multiFitRecoversTwoSources() throws {
        let controller = SourceSimulatorController()
        controller.sources.append(
            SourceSimulatorController.Source(
                name: "Source 2",
                positionMeters: controller.clampInsideBrain(SIMD3(-0.04, -0.03, 0.02)),
                orientationUnit: SIMD3(1, 0, 0),
                activations: [SourceSimulatorController.Activation(
                    startSeconds: 0, lengthSeconds: 4,
                    amplitudeNanoampereMeters: 20, waveform: .hold)]
            )
        )
        let loc = try #require(controller.liveMultiLocalization())
        #expect(loc.pairs.count == 2, "one fitted dipole per placed source")
        // With two well-separated dipoles, a two-dipole model explains the field
        // far better than one did, and each source is recovered near its truth.
        #expect(loc.goodnessOfFit > 0.99, "two dipoles should explain a two-dipole field")
        for pair in loc.pairs {
            let mm = try #require(pair.positionErrorMillimeters)
            #expect(mm < 10, "each source recovered within a centimetre, got \(mm) mm")
        }
        // Every true source is claimed exactly once (one-to-one pairing).
        let names = Set(loc.pairs.compactMap(\.trueSourceName))
        #expect(names == ["Source 1", "Source 2"])
    }

    @Test("two dipoles explain a two-source field better than one")
    func multiFitBeatsSingleOnTwoSources() throws {
        let controller = SourceSimulatorController()
        controller.sources.append(
            SourceSimulatorController.Source(
                name: "Source 2",
                positionMeters: controller.clampInsideBrain(SIMD3(-0.04, -0.03, 0.02)),
                orientationUnit: SIMD3(1, 0, 0),
                activations: [SourceSimulatorController.Activation(
                    startSeconds: 0, lengthSeconds: 4,
                    amplitudeNanoampereMeters: 20, waveform: .hold)]
            )
        )
        let single = try #require(controller.liveLocalization())         // one dipole
        let multi = try #require(controller.liveMultiLocalization())     // two dipoles
        #expect(multi.goodnessOfFit > single.fit.goodnessOfFit,
                "adding the second dipole should raise the goodness-of-fit")
    }

    // MARK: - Stage 3c — spatiotemporal (interval) fit

    /// Two simultaneous sources with *distinct* time courses: an instant can't
    /// separate them, but the interval can.
    private func twoDistinctSources() -> SourceSimulatorController {
        let controller = SourceSimulatorController()
        // Source 1 keeps the default full-epoch hold. Source 2 fires a sine, so
        // the two time courses are independent → the data is rank 2 over time.
        controller.sources.append(
            SourceSimulatorController.Source(
                name: "Source 2",
                positionMeters: controller.clampInsideBrain(SIMD3(-0.04, -0.03, 0.02)),
                orientationUnit: SIMD3(1, 0, 0),
                activations: [SourceSimulatorController.Activation(
                    startSeconds: 0, lengthSeconds: 4,
                    amplitudeNanoampereMeters: 20, waveform: .sine(frequencyHz: 10))]
            )
        )
        return controller
    }

    @Test("the interval fit recovers two simultaneous distinct sources")
    func intervalFitRecoversTwoSources() throws {
        let controller = twoDistinctSources()
        let loc = try #require(controller.liveIntervalLocalization())
        #expect(loc.spatioTemporal)
        #expect(loc.pairs.count == 2)
        #expect(loc.goodnessOfFit > 0.99, "two dipoles explain a two-dipole interval")
        for pair in loc.pairs {
            let mm = try #require(pair.positionErrorMillimeters)
            #expect(mm < 10, "each source recovered within a centimetre, got \(mm) mm")
        }
        #expect(Set(loc.pairs.compactMap(\.trueSourceName)) == ["Source 1", "Source 2"])
    }

    @Test("the SVD spectrum shows two significant components for two sources")
    func intervalSpectrumShowsModelOrder() throws {
        let controller = twoDistinctSources()
        let loc = try #require(controller.liveIntervalLocalization())
        #expect(loc.varianceSpectrum.count >= 2)
        // Two distinct sources → the second principal component carries real
        // variance; a single-source interval would leave it near zero.
        #expect(loc.varianceSpectrum[0] > loc.varianceSpectrum[1])
        #expect(loc.varianceSpectrum[1] > 0.02,
                "a genuine second source should lift the 2nd component above noise, got \(loc.varianceSpectrum[1])")
    }

    @Test("one source leaves the second SVD component negligible")
    func intervalSpectrumOneSource() throws {
        // The default single hold dipole: essentially rank 1 over the interval.
        let controller = SourceSimulatorController()
        let loc = try #require(controller.liveIntervalLocalization())
        #expect(loc.varianceSpectrum.count >= 2)
        #expect(loc.varianceSpectrum[0] > 0.98, "one source dominates the spectrum")
        #expect(loc.varianceSpectrum[1] < 0.02, "no real second component for one source")
    }

    // MARK: - Stage 3c — shared-geometry multi-condition fit

    @Test("shared-geometry fit keeps positions but varies moments across conditions")
    func sharedGeometryComparesConditions() throws {
        let controller = twoDistinctSources()   // 2 sources, distinct time courses
        // Condition A: as authored.
        let conditionA = controller.displayedMatrix(over: nil)!
        // Condition B: same generators, but Source 1 fires twice as strongly.
        controller.sources[0].activations[0].amplitudeNanoampereMeters = 40
        let conditionB = controller.displayedMatrix(over: nil)!

        let shared = try #require(SingleDipoleFit.fitSharedGeometry(
            conditions: [("A", conditionA), ("B", conditionB)],
            count: controller.sources.count, head: controller.headModel,
            montage: controller.montage, reference: controller.reference,
            harmonicTerms: controller.harmonicTerms))

        #expect(shared.positions.count == 2)
        #expect(shared.conditions.count == 2)

        // Shared positions recover both true generators.
        for source in controller.sources {
            let truth = Vector3D(x: source.positionMeters.x, y: source.positionMeters.y, z: source.positionMeters.z)
            let nearest = shared.positions.map { ($0 - truth).norm }.min() ?? .greatestFiniteMagnitude
            #expect(nearest * 1000 < 12, "a shared position should sit on a true source, got \(nearest * 1000) mm")
        }

        // The dipole nearest Source 1 should be stronger in condition B (2× drive)
        // than in condition A — the model differs between conditions in *moment*,
        // not geometry.
        let s1 = Vector3D(
            x: controller.sources[0].positionMeters.x,
            y: controller.sources[0].positionMeters.y,
            z: controller.sources[0].positionMeters.z)
        let dipoleIndex = (0..<shared.positions.count).min(by: {
            (shared.positions[$0] - s1).norm < (shared.positions[$1] - s1).norm
        })!
        let magA = shared.conditions[0].dipoles[dipoleIndex].magnitudeNanoampereMeters
        let magB = shared.conditions[1].dipoles[dipoleIndex].magnitudeNanoampereMeters
        #expect(magB > magA * 1.5, "doubling Source 1's drive should roughly double its moment (A \(magA), B \(magB))")
    }

    @Test("Fit mode: demo dataset loads and the shared fit recovers truth")
    func fitModeDemoDatasetFits() throws {
        let controller = SourceSimulatorController()
        controller.loadFitDemoDataset()
        #expect(controller.windowMode == .fit)
        let dataset = try #require(controller.fitDataset)
        #expect(dataset.conditions.count == 2)
        #expect(dataset.truth?.count == 3)
        #expect(controller.fitDipoleCount == 3)

        let result = try #require(controller.runSharedFitNow())
        #expect(result.positions.count == 3)
        #expect(result.conditions.count == 2)
        // Truth pairing is available because the demo carries ground truth.
        let errors = controller.sharedFitTruthErrors()
        #expect(errors.count == 3)
        #expect(errors.allSatisfy { $0.positionMillimeters < 15 },
                "shared positions land near the true sources: \(errors.map(\.positionMillimeters))")
    }

    /// Wall-clock baseline for the shared-geometry solve at a realistic montage
    /// size. Not a pass/fail threshold — it prints the number so the effect of
    /// the Stage 3c-perf work is measurable rather than assumed.
    @Test("benchmark: shared-geometry fit timing")
    func benchmarkSharedFit() throws {
        let controller = SourceSimulatorController()
        controller.channelCount = 64
        controller.loadFitDemoDataset()
        controller.fitDipoleCount = 3
        let dataset = try #require(controller.fitDataset)

        let timings = SingleDipoleFit.PhaseTimings()
        let reporter = SingleDipoleFit.ProgressReporter(
            report: { _, _ in }, isCancelled: { false }, timings: timings)

        let start = Date()
        let result = try #require(controller.runSharedFitNow(reporter: reporter))
        let elapsed = Date().timeIntervalSince(start)

        // A single unseeded dipole runs the coarse search only (joint refinement
        // needs k >= 2), so it isolates search cost from refinement cost.
        controller.fitDipoleCount = 1
        let singleStart = Date()
        _ = try #require(controller.runSharedFitNow())
        let singleElapsed = Date().timeIntervalSince(singleStart)

        print("""
        [BENCH] shared fit: \(String(format: "%.3f", elapsed)) s \
        (channels \(dataset.channelCount), samples \(dataset.sampleCount), \
        conditions \(dataset.conditions.count), dipoles \(result.positions.count))
        [BENCH] phases: \(timings.summary)
        [BENCH] single ECD (coarse search only): \(String(format: "%.3f", singleElapsed)) s
        """)
        #expect(result.positions.count == 3)
    }

    /// The residual PCA is only meaningful if it actually tracks what the model
    /// has left to explain: with the right number of dipoles on noiseless
    /// simulated data almost nothing should remain, and starving the model of
    /// dipoles should leave a large, visible residual.
    @Test("Source waveforms and residual PCA shrink as the model explains the data")
    func decompositionTracksUnexplainedVariance() throws {
        let controller = SourceSimulatorController()
        controller.loadFitDemoDataset()
        let dataset = try #require(controller.fitDataset)
        let condition = try #require(dataset.conditions.first)
        let sampleCount = condition.data.first?.count ?? 0
        #expect(sampleCount > 0)

        func decompose(dipoles: Int) throws -> SingleDipoleFit.SourceDecomposition {
            controller.fitDipoleCount = dipoles
            let fit = try #require(controller.runSharedFitNow())
            let orientations = fit.conditions[0].dipoles.map(\.orientationUnit)
            return try #require(SingleDipoleFit.decompose(
                data: condition.data, positions: fit.positions, orientations: orientations,
                head: dataset.headModel, montage: dataset.montage,
                reference: dataset.reference, harmonicTerms: controller.harmonicTerms))
        }

        // Correct model order: the demo field is generated by this same forward
        // model with no noise, so three dipoles should account for nearly all of it.
        let full = try decompose(dipoles: 3)
        #expect(full.sourceWaveforms.count == 3)
        #expect(full.sourceWaveforms.allSatisfy { $0.count == sampleCount })
        #expect(full.explainedFraction > 0.95,
                "three dipoles should explain a noiseless three-source field (got \(full.explainedFraction))")
        #expect(full.residualFraction < 0.05)

        // Under-modelled: one dipole cannot carry three separated sources, so a
        // substantial residual must remain for the components to show.
        let starved = try decompose(dipoles: 1)
        #expect(starved.sourceWaveforms.count == 1)
        #expect(starved.residualFraction > full.residualFraction,
                "fewer dipoles must leave more unexplained (1 dipole \(starved.residualFraction) vs 3 \(full.residualFraction))")
        #expect(!starved.residualComponents.isEmpty,
                "an under-modelled fit should surface residual components")
        // Component variance shares are ordered strongest first and are shares of
        // the original total, so they cannot exceed 100%.
        let shares = starved.residualComponents.map(\.varianceFraction)
        #expect(shares == shares.sorted(by: >))
        #expect(shares.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(starved.residualComponents.allSatisfy { $0.timeCourse.count == sampleCount })
    }
}
