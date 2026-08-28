//
//  BCGSurrogateCorrectionTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP SI-3. Truth-backed unit tests for PCA-S: a synthetic recording whose
//  brain part and BCG part are known separately, so "removed the artifact" and
//  "kept the brain" can be asserted as two different numbers rather than one
//  hopeful one.
//
//  The brain sources are placed with the same forward model the correction uses,
//  which would rig the comparison if they sat where the surrogate basis sits —
//  so they are deliberately placed at a different depth and different positions,
//  and the assertions are about relative improvement rather than absolute
//  perfection. The adversarial version of this question (basis displacement,
//  head-model mismatch, rank sweeps) is SI-4's job and belongs in the simulator.
//

import Foundation
import Testing
@testable import EVA

struct BCGSurrogateCorrectionTests {

    // MARK: - Synthetic recording

    private let samplingRate = 250.0
    private let duration = 40.0
    private var sampleCount: Int { Int(samplingRate * duration) }
    private let channelCount = 32

    /// Electrodes spread over the upper hemisphere by a Fibonacci lattice —
    /// deterministic, and not the pattern the surrogate basis places sources on.
    private func geometry() -> ElectrodeGeometry {
        var positions: [Int: SIMD3<Double>] = [:]
        var names: [Int: String] = [:]
        for index in 0..<channelCount {
            let n = Double(index) + 0.5
            // Upper hemisphere plus a little below the equator, as a real cap is.
            let z = 1 - 1.5 * n / Double(channelCount)
            let radius = max(0, 1 - z * z).squareRoot()
            let azimuth = 2 * Double.pi * n * 0.618_033_988_749_895
            positions[index] = SIMD3<Double>(
                radius * cos(azimuth), radius * sin(azimuth), z
            )
            names[index] = "E\(index + 1)"
        }
        return ElectrodeGeometry(name: "Synthetic cap", positions: positions, channelNames: names)
    }

    private func orderedElectrodes(_ geometry: ElectrodeGeometry) -> OrderedElectrodes {
        let head = ForwardHeadModel.classicThreeShell
        return OrderedElectrodes(
            names: (0..<channelCount).map { "E\($0 + 1)" },
            positionsMeters: (0..<channelCount).map { index in
                let direction = geometry.positions[index]!
                return SIMD3<Double>(
                    direction.x * head.scalpRadiusMeters,
                    direction.y * head.scalpRadiusMeters,
                    direction.z * head.scalpRadiusMeters
                )
            }
        )
    }

    /// Deterministic pseudo-random noise, so the whole fixture is reproducible.
    private func noise(seed: UInt64, count: Int, amplitude: Double) -> [Double] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return (Double(state >> 33) / Double(UInt32.max) - 0.5) * 2 * amplitude
        }
    }

    /// Brain activity from five dipoles at 0.85 of the brain radius — inside the
    /// surrogate basis's reach but not at its source positions.
    private func brainSignal(_ electrodes: OrderedElectrodes) throws -> [[Double]] {
        let head = ForwardHeadModel.classicThreeShell
        let radius = head.brainRadiusMeters * 0.85
        let dipoles: [ForwardDipole] = (0..<5).map { index in
            let n = Double(index) + 0.5
            let z = 1 - 2 * n / 5
            let horizontal = max(0, 1 - z * z).squareRoot()
            let azimuth = 2 * Double.pi * n * 0.723_606_797_749_979
            let direction = SIMD3<Double>(
                horizontal * cos(azimuth), horizontal * sin(azimuth), z
            )
            return ForwardDipole(
                id: "S\(index)",
                positionMeters: direction * radius,
                orientationUnit: direction
            )
        }
        let field = try SphericalForwardModel.leadField(
            head: head,
            electrodes: electrodes,
            dipoles: dipoles,
            reference: .average,
            harmonicTerms: 60
        )
        // Each dipole gets a band-limited moment: a sinusoid plus noise, at a
        // physiological amplitude once projected.
        var moments: [[Double]] = []
        for (index, _) in dipoles.enumerated() {
            let frequency = 6.0 + 2.5 * Double(index)
            let jitter = noise(seed: 9_000 + UInt64(index), count: sampleCount, amplitude: 4)
            moments.append((0..<sampleCount).map { sample in
                let t = Double(sample) / samplingRate
                return 12 * sin(2 * .pi * frequency * t) + jitter[sample]
            })
        }
        var signal = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount), count: channelCount
        )
        for channel in 0..<channelCount {
            for (index, moment) in moments.enumerated() {
                let gain = field.orientedMicrovoltsPerNanoampereMeter[channel][index]
                for sample in 0..<sampleCount {
                    signal[channel][sample] += gain * moment[sample]
                }
            }
        }
        return signal
    }

    private func beatTimes() -> [Double] {
        // ~66 bpm with mild variability, well clear of the template window.
        var times: [Double] = []
        var t = 1.0
        var index = 0
        while t < duration - 1.0 {
            times.append(t)
            let jitter = 0.04 * sin(Double(index) * 0.7)
            t += 0.9 + jitter
            index += 1
        }
        return times
    }

    /// A rank-3 beat-locked artifact: three fixed spatial patterns, each with
    /// its own beat-locked time course, plus small per-beat amplitude variation.
    private func bcgArtifact(_ beats: [Double], amplitude: Double = 55) -> [[Double]] {
        var patterns: [[Double]] = []
        for component in 0..<3 {
            var pattern = [Double](repeating: 0, count: channelCount)
            for channel in 0..<channelCount {
                let phase = Double(channel) / Double(channelCount) * 2 * .pi
                pattern[channel] = cos(phase * Double(component + 1) + Double(component))
            }
            let norm = pattern.reduce(0) { $0 + $1 * $1 }.squareRoot()
            patterns.append(pattern.map { $0 / norm })
        }
        var artifact = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount), count: channelCount
        )
        let windowSamples = Int(0.5 * samplingRate)
        for (beatIndex, beat) in beats.enumerated() {
            let start = Int(beat * samplingRate)
            let scale = 1 + 0.08 * sin(Double(beatIndex) * 1.3)
            for offset in 0..<windowSamples {
                let sample = start + offset
                guard sample >= 0, sample < sampleCount else { continue }
                let phase = Double(offset) / Double(windowSamples)
                let shapes = [
                    sin(2 * .pi * phase),
                    sin(4 * .pi * phase) * exp(-3 * phase),
                    sin(6 * .pi * phase) * exp(-5 * phase)
                ]
                for component in 0..<3 {
                    let componentAmplitude = amplitude * scale * shapes[component] / Double(component + 1)
                    for channel in 0..<channelCount {
                        artifact[channel][sample] += componentAmplitude * patterns[component][channel]
                    }
                }
            }
        }
        return artifact
    }

    private struct Fixture {
        var clean: [[Double]]
        var noisy: [[Float]]
        var beats: [Double]
        var geometry: ElectrodeGeometry
    }

    private func makeFixture(artifactAmplitude: Double = 55) throws -> Fixture {
        let geometry = geometry()
        let clean = try brainSignal(orderedElectrodes(geometry))
        let beats = beatTimes()
        let artifact = bcgArtifact(beats, amplitude: artifactAmplitude)
        var noisy = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount {
            noisy[channel] = (0..<sampleCount).map {
                Float(clean[channel][$0] + artifact[channel][$0])
            }
        }
        return Fixture(clean: clean, noisy: noisy, beats: beats, geometry: geometry)
    }

    /// `std(clean) / std(clean − corrected)` over the corrected channels — the
    /// same definition the pipeline regression suite uses.
    private func broadbandSNR(clean: [[Double]], corrected: [[Float]]) -> Double {
        var signalSquares = 0.0
        var residualSquares = 0.0
        for channel in 0..<min(clean.count, corrected.count) {
            for sample in 0..<min(clean[channel].count, corrected[channel].count) {
                let truth = clean[channel][sample]
                signalSquares += truth * truth
                let residual = truth - Double(corrected[channel][sample])
                residualSquares += residual * residual
            }
        }
        guard residualSquares > 1e-30 else { return .infinity }
        return (signalSquares / residualSquares).squareRoot()
    }

    // MARK: - The measurement

    @Test func correctionRemovesTheArtifactAndKeepsTheBrain() async throws {
        let fixture = try makeFixture()
        let rows = Array(0..<channelCount)

        let before = broadbandSNR(clean: fixture.clean, corrected: fixture.noisy)
        let output = try await BCGSurrogateCorrection.correct(
            data: fixture.noisy,
            samplingRate: samplingRate,
            correctedRows: rows,
            geometry: fixture.geometry,
            channelNames: (0..<channelCount).map { "E\($0 + 1)" },
            beatSeconds: fixture.beats
        )
        let after = broadbandSNR(clean: fixture.clean, corrected: output.data)

        // The premise: the fixture really is contaminated. Without this a
        // no-op filter would pass the improvement check on a clean recording.
        #expect(before < 1.0, "uncorrected SNR \(before) — the fixture is not contaminated enough to be a test")
        #expect(after > before * 2, "SNR went \(before) → \(after)")

        // The artifact is beat-locked, so what it leaves behind is best seen in
        // the beat-locked average. Compare the residual template's energy.
        let cleanTemplate = beatLockedEnergy(fixture.clean.map { $0.map(Float.init) }, beats: fixture.beats)
        let noisyTemplate = beatLockedEnergy(fixture.noisy, beats: fixture.beats)
        let correctedTemplate = beatLockedEnergy(output.data, beats: fixture.beats)
        #expect(noisyTemplate > cleanTemplate * 4)
        #expect(correctedTemplate < noisyTemplate * 0.35,
                "beat-locked energy \(noisyTemplate) → \(correctedTemplate)")

        // And the report says what it did, in terms an operator can check.
        #expect(output.report.artifactComponentCount >= 2)
        // A clean artifact repeats: every retained component's split-half
        // correlation is essentially 1 when the dictionary is really artifact.
        #expect(output.report.artifactComponentReliabilities.allSatisfy { $0 > 0.95 })
        #expect(output.report.reliabilityRejectedComponentCount == 0)
        #expect(output.report.acceptedBeatCount >= 20)
        #expect(output.report.correctedChannelCount == channelCount)
        #expect(output.report.removedVarianceFraction > 0.1)
        // Removing nearly everything is correct here — the artifact is four
        // times the brain signal in this fixture — but "removed 100%" would
        // mean the operator had collapsed, so the bound stays.
        #expect(output.report.removedVarianceFraction < 0.995)
        #expect(output.report.headModelName == ForwardHeadModel.classicThreeShell.name)
    }

    private func beatLockedEnergy(_ data: [[Float]], beats: [Double]) -> Double {
        let window = Int(0.5 * samplingRate)
        var accumulated = [[Double]](
            repeating: [Double](repeating: 0, count: window), count: data.count
        )
        var used = 0
        for beat in beats {
            let start = Int(beat * samplingRate)
            guard start >= 0, start + window <= (data.first?.count ?? 0) else { continue }
            used += 1
            for channel in data.indices {
                for offset in 0..<window {
                    accumulated[channel][offset] += Double(data[channel][start + offset])
                }
            }
        }
        guard used > 0 else { return 0 }
        var energy = 0.0
        for channel in accumulated.indices {
            for offset in 0..<window {
                let value = accumulated[channel][offset] / Double(used)
                energy += value * value
            }
        }
        return energy
    }

    /// A weak artifact is the harder half of the claim: with the brain
    /// dominating, a filter that removes "the beat-locked thing" too eagerly
    /// takes brain signal with it.
    @Test func aWeakArtifactIsRemovedWithoutEatingTheBrain() async throws {
        let fixture = try makeFixture(artifactAmplitude: 3)
        let before = broadbandSNR(clean: fixture.clean, corrected: fixture.noisy)
        let output = try await BCGSurrogateCorrection.correct(
            data: fixture.noisy,
            samplingRate: samplingRate,
            correctedRows: Array(0..<channelCount),
            geometry: fixture.geometry,
            channelNames: nil,
            beatSeconds: fixture.beats
        )
        let after = broadbandSNR(clean: fixture.clean, corrected: output.data)
        // The premise: the brain dominates this fixture, so a filter that
        // removes a large share of the variance is removing signal.
        #expect(before > 1.5, "fixture is not brain-dominated: SNR \(before)")
        #expect(after > before, "SNR went \(before) → \(after) — the correction is the largest error in this recording")
        // Only the artifact's own share, not a slice of the brain with it. The
        // artifact is ~13% of the variance here, and the reliability gate is
        // what keeps this number close to it: without the gate the same fixture
        // lost 42% of its variance and its SNR fell to 1.7.
        #expect(output.report.removedVarianceFraction < 0.2,
                "removed \(output.report.removedVarianceFraction) of the variance for a 13% artifact")
        #expect(output.report.reliabilityRejectedComponentCount > 0,
                "nothing was rejected — the gate is not doing anything on a brain-dominated fixture")
        #expect(output.report.artifactComponentReliabilities.allSatisfy { $0 >= 0.9 })
    }

    /// With no artifact to find, PCA-S must refuse rather than invent a
    /// dictionary out of ongoing EEG.
    ///
    /// This falls out of the pattern search rather than being special-cased:
    /// beat epochs of pure EEG do not correlate with each other, so almost none
    /// pass the threshold and the accepted count never reaches the minimum. A
    /// version that "succeeded" here would be building its artifact model from
    /// brain signal and then subtracting it.
    @Test func aRecordingWithNoBeatLockedArtifactIsRefused() async throws {
        let fixture = try makeFixture()
        let cleanFloat = fixture.clean.map { $0.map(Float.init) }
        await #expect(throws: (any Error).self) {
            try await BCGSurrogateCorrection.correct(
                data: cleanFloat,
                samplingRate: samplingRate,
                correctedRows: Array(0..<channelCount),
                geometry: fixture.geometry,
                channelNames: nil,
                beatSeconds: fixture.beats
            )
        }
    }

    // MARK: - Contracts

    @Test func excludedRowsAreReturnedUntouched() async throws {
        let fixture = try makeFixture()
        // Leave two channels out of the fit, as a bad-channel set would.
        let rows = Array(0..<channelCount).filter { $0 != 3 && $0 != 17 }
        let output = try await BCGSurrogateCorrection.correct(
            data: fixture.noisy,
            samplingRate: samplingRate,
            correctedRows: rows,
            geometry: fixture.geometry,
            channelNames: nil,
            beatSeconds: fixture.beats
        )
        #expect(output.data[3] == fixture.noisy[3])
        #expect(output.data[17] == fixture.noisy[17])
        #expect(output.data[0] != fixture.noisy[0])
        #expect(output.report.correctedChannelCount == channelCount - 2)
        #expect(output.report.excludedChannelCount == 2)
    }

    /// The reference contract: correcting data that is *not* average-referenced
    /// must not quietly average-reference it.
    @Test func theRecordingsOwnReferenceSurvives() async throws {
        let fixture = try makeFixture()
        // Give every channel a large common-mode offset, as a physically
        // referenced recording carries.
        var offset = fixture.noisy
        let commonMode = (0..<sampleCount).map { Float(30 * sin(2 * .pi * 0.2 * Double($0) / samplingRate)) }
        for channel in offset.indices {
            for sample in 0..<sampleCount { offset[channel][sample] += commonMode[sample] }
        }

        let output = try await BCGSurrogateCorrection.correct(
            data: offset,
            samplingRate: samplingRate,
            correctedRows: Array(0..<channelCount),
            geometry: fixture.geometry,
            channelNames: nil,
            beatSeconds: fixture.beats
        )

        var worstDifference = 0.0
        for sample in 0..<sampleCount {
            let before = (0..<channelCount).reduce(0.0) { $0 + Double(offset[$1][sample]) }
                / Double(channelCount)
            let after = (0..<channelCount).reduce(0.0) { $0 + Double(output.data[$1][sample]) }
                / Double(channelCount)
            worstDifference = max(worstDifference, abs(before - after))
        }
        #expect(worstDifference < 1e-3, "common mode moved by \(worstDifference) µV")
    }

    @Test func missingGeometryIsRefusedRatherThanApproximated() async throws {
        let fixture = try makeFixture()
        await #expect(throws: BCGSurrogateError.missingGeometry(missingChannelNumbers: [])) {
            try await BCGSurrogateCorrection.correct(
                data: fixture.noisy,
                samplingRate: samplingRate,
                correctedRows: Array(0..<channelCount),
                geometry: nil,
                channelNames: nil,
                beatSeconds: fixture.beats
            )
        }

        // Partial geometry is refused too, and names the channels it lacks.
        var partial = fixture.geometry.positions
        partial[5] = nil
        let incomplete = ElectrodeGeometry(name: "Partial", positions: partial, channelNames: [:])
        await #expect(throws: BCGSurrogateError.missingGeometry(missingChannelNumbers: [6])) {
            try await BCGSurrogateCorrection.correct(
                data: fixture.noisy,
                samplingRate: samplingRate,
                correctedRows: Array(0..<channelCount),
                geometry: incomplete,
                channelNames: nil,
                beatSeconds: fixture.beats
            )
        }
    }

    @Test func tooFewBeatsIsRefusedWithTheCount() async throws {
        let fixture = try makeFixture()
        await #expect(throws: BCGSurrogateError.noBeats) {
            try await BCGSurrogateCorrection.correct(
                data: fixture.noisy,
                samplingRate: samplingRate,
                correctedRows: Array(0..<channelCount),
                geometry: fixture.geometry,
                channelNames: nil,
                beatSeconds: []
            )
        }

        var settings = BCGSurrogateSettings.default
        settings.minimumAcceptedBeats = 500
        await #expect(throws: (any Error).self) {
            try await BCGSurrogateCorrection.correct(
                data: fixture.noisy,
                samplingRate: samplingRate,
                correctedRows: Array(0..<channelCount),
                geometry: fixture.geometry,
                channelNames: nil,
                beatSeconds: fixture.beats,
                settings: settings
            )
        }
    }

    /// Same input, same output — the property every history node depends on.
    @Test func correctionIsDeterministic() async throws {
        let fixture = try makeFixture()
        let rows = Array(0..<channelCount)
        let first = try await BCGSurrogateCorrection.correct(
            data: fixture.noisy, samplingRate: samplingRate, correctedRows: rows,
            geometry: fixture.geometry, channelNames: nil, beatSeconds: fixture.beats
        )
        let second = try await BCGSurrogateCorrection.correct(
            data: fixture.noisy, samplingRate: samplingRate, correctedRows: rows,
            geometry: fixture.geometry, channelNames: nil, beatSeconds: fixture.beats
        )
        #expect(first.data == second.data)
        #expect(first.report == second.report)
    }

    /// Portable settings round-trip through `eva.xml` parameters unchanged;
    /// this is what makes a recorded step replayable.
    @Test func settingsRoundTripThroughParameters() {
        var settings = BCGSurrogateSettings.default
        settings.patternSearch = .paper
        settings.brainRegularization = 0.035
        settings.regionalSourceCount = 21
        settings.correlationThreshold = 0.72
        settings.bandHighHz = 18
        settings.minimumAcceptedBeats = 15

        let restored = BCGSurrogateSettings(parameters: settings.parameters)
        #expect(restored == settings)

        // An older script that names none of these still replays with defaults
        // rather than with zeroes.
        #expect(BCGSurrogateSettings(parameters: [:]) == .default)
    }
}

/// The one place the beat code is duplicated, pinned.
///
/// `EVAProcessingScript.swift` is compiled into the command-line tools, which do
/// not include `EVA/Cardiac`, so the replay classification cannot reach
/// `BCGDetector.eventCode` and spells the default itself. This test is what
/// makes that safe.
struct BCGDetectorEventCodeTests {
    @Test func theReplayDefaultMatchesTheDetectorsOwnCode() {
        #expect(EVAProcessingStep.defaultBeatEventCode == BCGDetector.eventCode)
    }
}
