//
//  MNERealFileReferenceTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Same parity checks as MNEReferenceTests, sourced from a real EGI MFF
//  acquisition (real digitized electrode geometry, real task events, real
//  noise floor) rather than an idealized synthetic montage — plus a
//  band-pass filter check, which the synthetic fixture doesn't cover. See
//  Tools/mne-compare/make_real_reference.py for how the fixture is built.
//
//  The fixture is a real subject's EEG: it lives at
//  EVATests/Fixtures/Compare/local/ (git-ignored, like
//  EVATests/Fixtures/Resolve/local/) and is never committed. These tests skip
//  cleanly when it's absent — the same pattern FIFInteropTests.readBEM uses
//  for its git-ignored fsaverage fixtures — so a bare `xcodebuild test` stays
//  green without it.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("MNE reference parity (real recording)")
struct MNERealFileReferenceTests {

    struct Reference: Decodable {
        struct Interpolation: Decodable {
            var target: String
            var good_channels: [String]
            var weights: [Double]
            var interpolated_uv: [Double]
        }
        struct AverageReference: Decodable {
            var excluded: String
            var output_uv: [[Double]]
        }
        struct FilterRef: Decodable {
            var l_freq: Double
            var h_freq: Double
            var filtered_mne_uv: [[Double]]
        }
        var channels: [String]
        var positions: [String: [Double]]
        var sampling_rate: Double
        var signal_uv: [[Double]]
        var interpolation: Interpolation
        var average_reference: AverageReference
        var filter: FilterRef
    }

    private static var fixtureURL: URL {
        Fixtures.directory.appendingPathComponent("Compare/local/real_reference.json")
    }

    /// `nil` when the git-ignored real-recording fixture hasn't been
    /// generated locally (`Tools/mne-compare/make_real_reference.py`).
    private static let reference: Reference? = {
        guard FileManager.default.fileExists(atPath: fixtureURL.path),
              let data = try? Data(contentsOf: fixtureURL) else { return nil }
        return try? JSONDecoder().decode(Reference.self, from: data)
    }()

    private func requireReference() -> Reference? {
        guard let ref = Self.reference else {
            print("real_reference.json not present at \(Self.fixtureURL.path); run Tools/mne-compare/make_real_reference.py — skipping")
            return nil
        }
        return ref
    }

    private func unitPositions(_ ref: Reference) -> [Int: SIMD3<Double>] {
        var out: [Int: SIMD3<Double>] = [:]
        for (index, name) in ref.channels.enumerated() {
            guard let p = ref.positions[name] else { continue }
            let v = SIMD3<Double>(p[0], p[1], p[2])
            out[index] = v / simd_length(v)
        }
        return out
    }

    @Test("real-recording interpolation weights match MNE")
    func interpolationWeightsMatchMNE() throws {
        guard let ref = requireReference() else { return }
        let positions = unitPositions(ref)
        let target = ref.channels.firstIndex(of: ref.interpolation.target)!
        let good = ref.interpolation.good_channels.map { ref.channels.firstIndex(of: $0)! }

        let solved = try #require(SphericalSpline.interpolationWeights(target: target, good: good, positions: positions))
        for (swiftWeight, mneWeight) in zip(solved.weights, ref.interpolation.weights) {
            #expect(abs(swiftWeight - mneWeight) < 1e-4, "weight mismatch: \(swiftWeight) vs \(mneWeight)")
        }
    }

    @Test("real-recording ChannelInterpolationSolver reproduces MNE's waveform")
    func solverReproducesInterpolatedWaveform() throws {
        guard let ref = requireReference() else { return }
        let signal = SyntheticSignal.make(ref.signal_uv.map { $0.map(Float.init) }, samplingRate: ref.sampling_rate)
        let target = ref.channels.firstIndex(of: ref.interpolation.target)!
        let positions = unitPositions(ref)

        let result = ChannelInterpolationSolver.solve(
            target: target, in: signal, bad: [target], alreadyInterpolated: [], positions: positions
        )
        let solution = try #require(try? result.get())
        // Real digitized geometry (vs. the synthetic fixture's idealized
        // positions) plus millivolt-scale unreferenced amplitudes widens the
        // tolerance needed, but this is still tight relative to the signal.
        for (swiftValue, mneValue) in zip(solution.replacement, ref.interpolation.interpolated_uv) {
            #expect(abs(Double(swiftValue) - mneValue) < 0.5, "interpolated sample mismatch: \(swiftValue) vs \(mneValue)")
        }
    }

    @Test("real-recording average reference matches MNE")
    func averageReferenceMatchesMNE() throws {
        guard let ref = requireReference() else { return }
        var channels = ref.signal_uv.map { $0.map(Float.init) }
        let excluded = ref.channels.firstIndex(of: ref.average_reference.excluded)!

        Rereferencing.applyInPlace(&channels, excluding: [excluded])

        for (channelIndex, expectedChannel) in ref.average_reference.output_uv.enumerated() {
            for (sampleIndex, expectedValue) in expectedChannel.enumerated() {
                let actual = Double(channels[channelIndex][sampleIndex])
                #expect(abs(actual - expectedValue) < 0.5,
                        "ch \(channelIndex) sample \(sampleIndex): \(actual) vs \(expectedValue)")
            }
        }
    }

    /// EVA's `.eeglabMNE` FIR design rule exists specifically to reproduce
    /// `mne.filter.filter_data(fir_design='firwin', phase='zero')`, and on
    /// paper the two designs agree: same transition-width formula (a 1 Hz
    /// high-pass clamps to a 1 Hz transition on both sides — MNE's
    /// `min(max(f*0.25, 2), f)`, EVA's headroom cap — so the combined
    /// band-pass kernel shares a ~3300-tap length at this sampling rate), same
    /// −6 dB-at-passband-edge convention, same delay-corrected single-pass
    /// application (MNE's "zero phase" for a linear-phase kernel is one
    /// centered pass, not EVA's own historical `.zeroPhase`, which runs the
    /// kernel twice — see `FIRApplication`'s doc comment).
    ///
    /// In practice they come out close but not identical: on this real
    /// recording, measured after trimming 4 s from each edge (the reflected-
    /// padding transient a ~3300-tap kernel needs to settle against real,
    /// 1/f-heavy EEG — longer than it would for white noise), the relative
    /// RMS difference is on the order of 0.5-1%, not floating-point noise.
    /// That gap most likely comes from `scipy.signal.firwin`'s exact window
    /// normalization differing in its last bit from EVA's own windowed-sinc
    /// implementation (`DSP.windowedSincLowPass`), not from a wrong cutoff or
    /// transition width — but this test asserts the *quantified* gap rather
    /// than asserting they're identical, so a real regression (a materially
    /// different filter) still fails it.
    @Test("band-pass filter (1-40 Hz, firwin/Hamming) matches MNE closely, quantified, in the interior")
    func bandPassFilterMatchesMNE() async throws {
        guard let ref = requireReference() else { return }
        let channels = ref.signal_uv.map { $0.map(Float.init) }

        let filtered = try await EEGSignalFilter.bandPass(
            channels: channels,
            samplingRate: ref.sampling_rate,
            lowCutoff: ref.filter.l_freq,
            highCutoff: ref.filter.h_freq,
            highPassFamily: .fir,
            lowPassFamily: .fir,
            firWindow: .hamming,
            firApplication: .delayCompensated,
            firDesignRule: .eeglabMNE
        )

        let trim = Int(4 * ref.sampling_rate)
        var sumSq = 0.0
        var referenceSumSq = 0.0
        var count = 0
        for (channelIndex, expectedChannel) in ref.filter.filtered_mne_uv.enumerated() {
            let actualChannel = filtered[channelIndex]
            guard actualChannel.count == expectedChannel.count, actualChannel.count > 2 * trim else { continue }
            for sampleIndex in trim..<(actualChannel.count - trim) {
                let diff = Double(actualChannel[sampleIndex]) - expectedChannel[sampleIndex]
                sumSq += diff * diff
                referenceSumSq += expectedChannel[sampleIndex] * expectedChannel[sampleIndex]
                count += 1
            }
        }
        let rms = count > 0 ? (sumSq / Double(count)).squareRoot() : .infinity
        let referenceRMS = count > 0 ? (referenceSumSq / Double(count)).squareRoot() : 0
        let relativeRMS = referenceRMS > 0 ? rms / referenceRMS : .infinity
        #expect(relativeRMS < 0.02, "interior relative RMS diff = \(relativeRMS) (rms \(rms) µV vs signal rms \(referenceRMS) µV)")
    }
}
