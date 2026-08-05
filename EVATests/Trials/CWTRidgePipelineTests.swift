//
//  CWTRidgePipelineTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Coverage for the wavelet-based Trials methods: DWT round-trip, wavelet
//  denoising SNR gain, CWT ridge peak detection, matched-wavelet template
//  synthesis, the non-linear alignment engines, and the end-to-end CWT-Ridge
//  pipeline.
//

import Foundation
import Testing
@testable import EVA

struct CWTRidgePipelineTests {
    private let samplingRate = 1_000.0
    private let stimulusOffsetSamples = 100
    private let length = 300

    // A single positive Gaussian bump (a stand-in ERP component).
    private func gaussian(center: Int, amplitude: Double = 1.0, width: Double = 10.0) -> [Float] {
        (0..<length).map { sample in
            let z = Double(sample - center) / width
            return Float(amplitude * exp(-0.5 * z * z))
        }
    }

    private func addNoise(_ trace: [Float], sd: Double, seed: UInt64) -> [Float] {
        var state = seed
        func next() -> Double {
            // xorshift64* for deterministic pseudo-random noise.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let value = (state &* 0x2545F4914F6CDD1D) >> 11
            return Double(value) / Double(1 << 53)
        }
        return trace.map { sample in
            // Box-Muller.
            let u1 = max(next(), 1e-9)
            let u2 = next()
            let g = (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
            return Float(Double(sample) + g * sd)
        }
    }

    // MARK: - DWT

    @Test func dwtRoundTripReconstructsSignal() {
        // Round-trips through the shared DWT core in WaveletReducer.swift that
        // WaveletDenoiser now reuses (instead of a duplicate transform).
        let signal = (0..<128).map { Double(sin(Double($0) * 0.2) + 0.3 * cos(Double($0) * 0.05)) }
        for family in WaveletReductionFamily.allCases {
            let bank = family.filterBank
            let transform = WaveletTransform(bank: bank)
            let decomposition = transform.forwardDWT(signal, levels: 3)
            let reconstructed = transform.inverseDWT(decomposition)
            #expect(reconstructed.count == signal.count)
            let maxError = zip(signal, reconstructed).map { abs($0 - $1) }.max() ?? 0
            #expect(maxError < 1e-6)
        }
    }

    // MARK: - Denoising

    @Test func denoisingReducesNoise() {
        let clean = gaussian(center: 150, amplitude: 5)
        let noisy = addNoise(clean, sd: 1.0, seed: 42)
        let denoised = WaveletDenoiser.denoise(noisy)

        func rms(_ a: [Float], _ b: [Float]) -> Double {
            let n = min(a.count, b.count)
            var sse = 0.0
            for i in 0..<n { let d = Double(a[i] - b[i]); sse += d * d }
            return (sse / Double(n)).squareRoot()
        }

        #expect(denoised.count == noisy.count)
        #expect(rms(denoised, clean) < rms(noisy, clean))
    }

    // MARK: - CWT ridge detection

    @Test func ridgeDetectionFindsKnownPeak() {
        let peakCenter = stimulusOffsetSamples + 80
        let trace = gaussian(center: peakCenter, amplitude: 4, width: 8)
        let result = CWTRidgeDetector.detect(
            trace,
            samplingRate: samplingRate,
            stimulusOffsetSamples: stimulusOffsetSamples,
            configuration: CWTRidgeDetector.Configuration(minSNR: 2.0)
        )
        #expect(!result.peaks.isEmpty)
        let nearest = result.peaks.min { abs($0.sampleIndex - peakCenter) < abs($1.sampleIndex - peakCenter) }
        let found = try! #require(nearest)
        #expect(abs(found.sampleIndex - peakCenter) <= 3)
        #expect(found.polaritySign == 1)
    }

    // MARK: - Matched wavelet template

    @Test func matchedWaveletTemplateTracksDominantPeak() {
        let peakCenter = stimulusOffsetSamples + 60
        let trace = gaussian(center: peakCenter, amplitude: 3, width: 9)
        let window = (stimulusOffsetSamples + 20)..<(stimulusOffsetSamples + 120)
        let template = try! #require(MatchedWaveletTemplate.template(for: trace, window: window))
        #expect(template.count == trace.count)
        // The template's extremum should sit near the true peak.
        let templatePeak = template.indices.max { abs(template[$0]) < abs(template[$1]) } ?? 0
        #expect(abs(templatePeak - peakCenter) <= 5)
    }

    // MARK: - Non-linear alignment

    @Test func maxLikelihoodAlignmentRecoversShift() {
        let template = gaussian(center: 150, amplitude: 2)
        let shifted = gaussian(center: 165, amplitude: 2) // 15 samples later
        let warped = NonlinearAligner.maxLikelihoodAlign(shifted, to: template, index: 0, maxShift: 40, priorSigma: 30)
        // Trial is later than template; alignment shifts it earlier (positive).
        #expect(abs(warped.netShiftSamples - 15) <= 2)
        #expect(warped.correlation > 0.95)
    }

    @Test func dtwAlignmentImprovesAverageSharpness() {
        let engines: [NonlinearAligner.Engine] = [.dtw, .maxLikelihood]
        let centers = [140, 150, 165]
        let trials = centers.map { gaussian(center: $0, amplitude: 2) }
        for engine in engines {
            let result = try! #require(NonlinearAligner.align(trials: trials, engine: engine))
            let alignedPeak = result.alignedAverage.map { abs($0) }.max() ?? 0
            let unalignedPeak = result.unalignedAverage.map { abs($0) }.max() ?? 0
            // Aligning latency jitter should raise the peak of the average.
            #expect(alignedPeak >= unalignedPeak - 1e-4)
        }
    }

    // MARK: - End-to-end pipeline

    @Test func pipelineAlignsJitteredTrials() {
        let centers = [stimulusOffsetSamples + 60, stimulusOffsetSamples + 75, stimulusOffsetSamples + 90]
        let trials = centers.enumerated().map { index, center in
            CWTRidgePipeline.TrialInput(
                sourceTimeSeconds: Double(index),
                stimulusOffsetSamples: stimulusOffsetSamples,
                samples: addNoise(gaussian(center: center, amplitude: 4, width: 8), sd: 0.3, seed: UInt64(index + 1))
            )
        }
        var config = CWTRidgePipeline.Configuration()
        config.windowStartMs = 20
        config.windowEndMs = 200
        config.engine = .dtw
        config.ridge.minSNR = 2.0

        let result = try! #require(CWTRidgePipeline.run(trials: trials, samplingRate: samplingRate, configuration: config))
        #expect(result.trials.count == trials.count)
        #expect(result.alignedTrials.count == trials.count)
        #expect(!result.templatePeaks.isEmpty)

        let alignedPeak = result.alignedAverage.map { abs($0) }.max() ?? 0
        let unalignedPeak = result.unalignedAverage.map { abs($0) }.max() ?? 0
        #expect(alignedPeak >= unalignedPeak - 1e-3)
    }

    @Test func pipelinePerTrialPeakSourceRuns() {
        let trials = (0..<4).map { index in
            CWTRidgePipeline.TrialInput(
                sourceTimeSeconds: Double(index),
                stimulusOffsetSamples: stimulusOffsetSamples,
                samples: gaussian(center: stimulusOffsetSamples + 70 + index * 5, amplitude: 4, width: 8)
            )
        }
        var config = CWTRidgePipeline.Configuration()
        config.peakSource = .perTrial
        config.engine = .curveRegistration
        config.windowStartMs = 20
        config.windowEndMs = 200
        config.ridge.minSNR = 2.0

        let result = try! #require(CWTRidgePipeline.run(trials: trials, samplingRate: samplingRate, configuration: config))
        #expect(result.peakSource == .perTrial)
        #expect(result.trials.allSatisfy { !$0.detectedPeaks.isEmpty })
    }

    // MARK: - Woody matched-wavelet mode

    @Test func woodyMatchedWaveletModeAligns() {
        let shifts = [-15, 0, 18]
        let trials = shifts.enumerated().map { index, shift in
            WoodyAlignmentAnalyzer.TrialInput(
                sourceTimeSeconds: Double(index),
                stimulusOffsetSamples: stimulusOffsetSamples,
                samples: gaussian(center: stimulusOffsetSamples + 70 + shift, amplitude: 3, width: 9)
            )
        }
        let result = try! #require(WoodyAlignmentAnalyzer.align(
            trials: trials,
            samplingRate: samplingRate,
            windowStartMs: 20,
            windowEndMs: 150,
            maxLagMs: 60,
            maxIterations: 4,
            convergenceToleranceSamples: 0,
            alignmentMode: .matchedWavelet,
            peakPolarity: .positive
        ))
        #expect(result.shifts.count == shifts.count)
        let estimated = result.shifts.map(\.latencyShiftSamples)
        let anchor = estimated.sorted()[estimated.count / 2]
        let expectedAnchor = shifts.sorted()[shifts.count / 2]
        for (row, expected) in zip(result.shifts, shifts) {
            #expect(abs((row.latencyShiftSamples - anchor) - (expected - expectedAnchor)) <= 2)
        }
    }
}
