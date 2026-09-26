//
//  GradientEpochAlignerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Covers the "Alignment" section of the FASTR-family functional spec on the
//  artifact shape that exposed its failure: a volume epoch built from a train of
//  identical slice artifacts at a non-integer slice period, with triggers whose
//  sub-sample phase drifts from volume to volume (a clock offset between the
//  scanner and the amplifier). Shifted by one slice, that waveform matches itself
//  almost perfectly, which is what let the old period-derived search radius lock
//  onto the neighbouring slice.
//

import Testing
import Foundation
@testable import EVA

struct GradientEpochAlignerTests {

    private static let samplingRate = 500.0
    private static let period = 600
    private static let slices = 16
    /// Non-integer, as it is on a real scanner (41 slices in a 3 s TR at 500 Hz
    /// is 36.59 samples).
    private static let slicePeriod = 36.4
    /// Sub-sample phase gained per volume: a 152 µs/s clock offset over a 3 s TR
    /// at 500 Hz.
    private static let driftPerVolume = 0.228

    /// One slice artifact: a Gaussian-windowed oscillation, band-limited well
    /// inside Nyquist so a fractional delay can represent it exactly.
    private func slicePulse(_ t: Double) -> Double {
        let envelope = exp(-pow((t - 9) / 3.2, 2))
        return 1500 * envelope * sin(2 * .pi * 0.18 * t)
    }

    /// Continuous-time artifact of a volume starting at time zero.
    private func volumeArtifact(_ t: Double) -> Double {
        var total = 0.0
        for slice in 0..<Self.slices {
            let local = t - Double(slice) * Self.slicePeriod
            guard local > -20, local < 40 else { continue }
            total += slicePulse(local)
        }
        return total
    }

    private func physiology(_ sample: Int) -> Double {
        6 * sin(2 * .pi * 7 * Double(sample) / Self.samplingRate)
    }

    private struct Recording {
        let channel: [Float]
        let physiology: [Float]
        let triggers: [Int]
        /// Where each volume's artifact really starts, in samples.
        let onsets: [Double]
    }

    /// Volumes start at a drifting continuous onset; each trigger is that onset
    /// rounded down onto the sample grid, as a TTL marker would be.
    private func makeRecording(volumes: Int, tail: Int = 200) -> Recording {
        let onsets = (0..<volumes).map { Double($0) * (Double(Self.period) + Self.driftPerVolume) + 3 }
        let count = Int(onsets.last!) + Self.period + tail
        var channel = [Float](repeating: 0, count: count)
        var clean = [Float](repeating: 0, count: count)
        for sample in 0..<count {
            var artifact = 0.0
            for onset in onsets where Double(sample) >= onset - 20 && Double(sample) < onset + Double(Self.period) {
                artifact += volumeArtifact(Double(sample) - onset)
            }
            clean[sample] = Float(physiology(sample))
            channel[sample] = clean[sample] + Float(artifact)
        }
        return Recording(
            channel: channel,
            physiology: clean,
            triggers: onsets.map { Int($0.rounded(.down)) },
            onsets: onsets
        )
    }

    private func layout(_ recording: Recording) throws -> GradientEpochLayout {
        try GradientEpochLayout.build(
            volumeTriggers: recording.triggers,
            sampleCount: recording.channel.count,
            slicesPerVolume: 1,
            upsampleFactor: 1,
            relativeTriggerPosition: 0
        )
    }

    // MARK: - Search radius

    @Test func repeatLagFindsTheSlicePeriodOfAVolumeEpoch() throws {
        let recording = makeRecording(volumes: 4)
        let grid = try layout(recording)
        let start = try #require(grid.windowStart(of: 0))
        let window = Array(recording.channel[start..<(start + grid.length)])
        let lag = try #require(GradientEpochAligner.repeatLag(of: window, maximumLag: 80))
        #expect(abs(Double(lag) - Self.slicePeriod) <= 1, "repeat lag \(lag)")
    }

    @Test func repeatLagIsNilForAnArtifactThatDoesNotRepeatWithinTheEpoch() {
        let window = (0..<400).map { index -> Float in
            let phase = Double(index) / 400
            return Float(120 * sin(2 * .pi * phase) + 70 * sin(6 * .pi * phase + 0.6))
        }
        #expect(GradientEpochAligner.repeatLag(of: window, maximumLag: 41) == nil)
    }

    @Test func defaultRadiusStaysBelowHalfTheSlicePeriodOnVolumeEpochs() throws {
        let recording = makeRecording(volumes: 4)
        let grid = try layout(recording)
        // The period-only bound would reach past the neighbouring slice.
        #expect(Double(GradientEpochAligner.defaultSearchRadius(period: grid.period)) > Self.slicePeriod / 2)
        let radius = GradientEpochAligner.defaultSearchRadius(referenceSignal: recording.channel, layout: grid)
        #expect(radius >= 1)
        #expect(Double(radius) < Self.slicePeriod / 2, "radius \(radius)")
    }

    @Test func defaultRadiusKeepsThePeriodBoundWhenTheArtifactDoesNotRepeat() throws {
        let period = 400
        let channel = (0..<(period * 6)).map { index -> Float in
            let phase = Double(index % period) / Double(period)
            return Float(120 * sin(2 * .pi * phase) + 70 * sin(6 * .pi * phase + 0.6))
        }
        let grid = try GradientEpochLayout.build(
            volumeTriggers: (0..<5).map { $0 * period },
            sampleCount: channel.count,
            slicesPerVolume: 1,
            upsampleFactor: 1,
            relativeTriggerPosition: 0
        )
        #expect(GradientEpochAligner.defaultSearchRadius(referenceSignal: channel, layout: grid)
                == GradientEpochAligner.defaultSearchRadius(period: grid.period))
    }

    // MARK: - Alignment on volume epochs

    @Test func volumeEpochsDoNotSlipToTheNeighbouringSlice() throws {
        let recording = makeRecording(volumes: 30)
        var config = GradientCorrectionConfig()
        config.averagingWindowBefore = 4
        config.averagingWindowAfter = 4
        config.subSampleAlignment = true
        let result = try GradientTemplateCorrector.correct(
            channels: [recording.channel], volumeTriggers: recording.triggers,
            config: config, samplingRate: Self.samplingRate
        )

        // Truth is the onset's sub-sample phase past its trigger, in [0, 1), so
        // a correct integer shift is 0 or 1 — never a slice away.
        let shifts = result.diagnostics.epochs.map(\.integerShift)
        #expect(shifts.allSatisfy { (0...1).contains($0) }, "shifts \(shifts)")

        // A slipped epoch leaves the samples its window no longer covers
        // exactly as they came in.
        let scan = recording.triggers[0]..<(recording.triggers.last! + Self.period)
        let untouched = scan.filter { result.channels[0][$0] == recording.channel[$0] }.count
        #expect(untouched == 0, "\(untouched) samples inside the scan were left uncorrected")
    }

    @Test func subSampleOffsetsTrackTheTrueArtifactPhase() throws {
        let recording = makeRecording(volumes: 30)
        let grid = try layout(recording)
        let alignment = GradientEpochAligner.align(
            referenceSignal: recording.channel,
            layout: grid,
            searchRadius: GradientEpochAligner.defaultSearchRadius(referenceSignal: recording.channel, layout: grid),
            estimatesSubSample: true
        )

        // The reference fixes an arbitrary common phase, so compare after
        // removing the mean difference.
        let errors = (0..<grid.count).map { epoch -> Double in
            let estimated = Double(alignment.integerShifts[epoch]) + alignment.fractionalShifts[epoch]
            let truth = recording.onsets[epoch] - Double(recording.triggers[epoch])
            return estimated - truth
        }
        let mean = errors.reduce(0, +) / Double(errors.count)
        let worst = errors.map { abs($0 - mean) }.max() ?? 0
        #expect(worst < 0.02, "worst sub-sample phase error \(worst) samples")
    }

    @Test func subSampleAlignmentBringsDriftingVolumeEpochsCloseToTheBrain() throws {
        let recording = makeRecording(volumes: 30)
        var integerOnly = GradientCorrectionConfig()
        integerOnly.averagingWindowBefore = 4
        integerOnly.averagingWindowAfter = 4
        var subSample = integerOnly
        subSample.subSampleAlignment = true

        let scan = recording.triggers[0]..<(recording.triggers.last! + Self.period)
        func residual(_ config: GradientCorrectionConfig) throws -> Double {
            let result = try GradientTemplateCorrector.correct(
                channels: [recording.channel], volumeTriggers: recording.triggers,
                config: config, samplingRate: Self.samplingRate
            )
            var total = 0.0
            for sample in scan {
                let difference = Double(result.channels[0][sample]) - Double(recording.physiology[sample])
                total += difference * difference
            }
            return (total / Double(scan.count)).squareRoot()
        }
        let coarse = try residual(integerOnly)
        let fine = try residual(subSample)
        // The physiology is 6 µV in amplitude (4.2 µV RMS); the artifact peaks
        // at 1500 µV. Integer alignment leaves tens of µV behind.
        #expect(fine < coarse * 0.2, "sub-sample \(fine) vs integer-only \(coarse)")
        #expect(fine < 2, "residual \(fine) µV RMS")
    }
}
