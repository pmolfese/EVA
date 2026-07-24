//
//  CWTRidgePipeline.swift
//  EVA
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
//  End-to-end "CWT Ridge" analysis: optional wavelet denoising, CWT ridge peak
//  detection, then a non-linear alignment engine (DTW / curve registration /
//  maximum likelihood). Peaks that define the template can be found either from
//  each single trial (maximum flexibility, noisier) or from the condition
//  average (stabler), toggled by `peakSource`.
//
//  Pipeline:
//    trials ──[denoise?]──▶ CWT ridge peaks ──▶ template peaks ──▶ align ──▶ average
//
//  Pure computation, structured like `WoodyAlignmentAnalyzer` / `RIDEAnalyzer`.
//

import Foundation

nonisolated enum CWTRidgePipeline {
    /// Where the peaks that drive alignment come from.
    enum PeakSource: String, CaseIterable, Identifiable, Sendable {
        case perTrial = "Per Trial"
        case conditionAverage = "Condition Average"

        var id: String { rawValue }
    }

    struct TrialInput: Sendable {
        var sourceTimeSeconds: Double
        var stimulusOffsetSamples: Int
        var samples: [Float]

        init(sourceTimeSeconds: Double, stimulusOffsetSamples: Int, samples: [Float]) {
            self.sourceTimeSeconds = sourceTimeSeconds
            self.stimulusOffsetSamples = stimulusOffsetSamples
            self.samples = samples
        }
    }

    struct Configuration: Sendable {
        var appliesDenoising: Bool = true
        var denoise: WaveletDenoiser.Configuration = .init()
        var ridge: CWTRidgeDetector.Configuration = .init()
        var peakSource: PeakSource = .conditionAverage
        var engine: NonlinearAligner.Engine = .dtw
        var sakoeChibaBand: Int = 20
        var maxShiftSamples: Int = 60
        var priorSigmaSamples: Double = 15
        /// Analysis window (ms relative to stimulus) restricting peak detection.
        /// `nil` means the whole epoch.
        var windowStartMs: Double?
        var windowEndMs: Double?
        var computesFunctionalPCA: Bool = true
        var functionalPCAComponentCount: Int = 3

        init() {}
    }

    struct TrialResult: Identifiable, Sendable {
        var id: Int
        var trialIndex: Int
        var sourceTimeSeconds: Double
        var detectedPeaks: [CWTRidgeDetector.Peak]
        var netShiftSamples: Double
        var netShiftMs: Double
        var correlation: Double
    }

    struct Result: Sendable {
        var engine: NonlinearAligner.Engine
        var peakSource: PeakSource
        var denoised: Bool
        var samplingRate: Double
        var templatePeaks: [CWTRidgeDetector.Peak]
        var averagePeaks: [CWTRidgeDetector.Peak]
        var scalogram: [[Double]]
        var scales: [Double]
        var trials: [TrialResult]
        var alignedTrials: [[Float]]
        var unalignedAverage: [Float]
        var alignedAverage: [Float]
        var template: [Float]
        var functionalPCA: NonlinearAligner.FunctionalPCA?
        /// Per-trial warping function (output sample → fractional source-sample
        /// index), in the same order as `trials`. Lets callers apply the exact
        /// per-sample warp to other channels — the all-channel aligned butterfly
        /// uses this so it reflects the true non-linear alignment, not a rigid
        /// shift. Empty when unavailable.
        var trialWarpFunctions: [[Double]] = []
    }

    static func run(
        trials rawTrials: [TrialInput],
        samplingRate: Double,
        configuration: Configuration
    ) -> Result? {
        guard samplingRate > 0,
              let first = rawTrials.first,
              !first.samples.isEmpty else { return nil }
        let length = first.samples.count
        let trials = rawTrials.filter { $0.samples.count == length }
        guard !trials.isEmpty else { return nil }

        // 1. Optional wavelet denoising per trial.
        let processed: [[Float]] = trials.map { trial in
            configuration.appliesDenoising
                ? WaveletDenoiser.denoise(trial.samples, configuration: configuration.denoise)
                : trial.samples
        }

        let unalignedAverage = NonlinearAligner.average(processed, length: length)

        // 2. Restrict ridge detection to the window, using the first trial's
        //    stimulus offset as the reference for the scalogram/template.
        let stimulusOffset = trials.first?.stimulusOffsetSamples ?? 0
        let window = sampleWindow(
            startMs: configuration.windowStartMs,
            endMs: configuration.windowEndMs,
            stimulusOffsetSamples: stimulusOffset,
            samplingRate: samplingRate,
            length: length
        )

        // 3. Template peaks + scalogram from the condition average.
        let averageDetection = CWTRidgeDetector.detect(
            unalignedAverage,
            samplingRate: samplingRate,
            stimulusOffsetSamples: stimulusOffset,
            configuration: configuration.ridge
        )
        let averagePeaks = filterPeaks(averageDetection.peaks, to: window)

        // 4. Per-trial peaks (always computed for reporting; drive alignment
        //    only when peakSource == .perTrial).
        let trialPeaks: [[CWTRidgeDetector.Peak]] = zip(processed, trials).map { samples, trial in
            let detection = CWTRidgeDetector.detect(
                samples,
                samplingRate: samplingRate,
                stimulusOffsetSamples: trial.stimulusOffsetSamples,
                configuration: configuration.ridge
            )
            return filterPeaks(detection.peaks, to: window)
        }

        // 5. Build the alignment template. For landmark registration we align to
        //    the average's peaks; DTW / ML align to the average waveform.
        let templatePeaks = averagePeaks

        guard let alignment = NonlinearAligner.align(
            trials: processed,
            template: unalignedAverage,
            engine: configuration.engine,
            sakoeChibaBand: configuration.sakoeChibaBand,
            maxShiftSamples: configuration.maxShiftSamples,
            priorSigmaSamples: configuration.priorSigmaSamples,
            trialPeaks: configuration.peakSource == .perTrial ? trialPeaks : [],
            templatePeaks: templatePeaks
        ) else { return nil }

        let alignedTrials = alignment.warped.map(\.aligned)
        let alignedAverage = alignment.alignedAverage

        let trialResults: [TrialResult] = alignment.warped.enumerated().map { index, warped in
            TrialResult(
                id: index,
                trialIndex: index,
                sourceTimeSeconds: trials[index].sourceTimeSeconds,
                detectedPeaks: index < trialPeaks.count ? trialPeaks[index] : [],
                netShiftSamples: warped.netShiftSamples,
                netShiftMs: warped.netShiftSamples / samplingRate * 1000.0,
                correlation: warped.correlation
            )
        }

        let fpca: NonlinearAligner.FunctionalPCA? = configuration.computesFunctionalPCA
            ? NonlinearAligner.functionalPCA(alignedTrials, componentCount: configuration.functionalPCAComponentCount)
            : nil

        return Result(
            engine: configuration.engine,
            peakSource: configuration.peakSource,
            denoised: configuration.appliesDenoising,
            samplingRate: samplingRate,
            templatePeaks: templatePeaks,
            averagePeaks: averagePeaks,
            scalogram: averageDetection.coefficients,
            scales: averageDetection.scales,
            trials: trialResults,
            alignedTrials: alignedTrials,
            unalignedAverage: unalignedAverage,
            alignedAverage: alignedAverage,
            template: alignment.template,
            functionalPCA: fpca,
            trialWarpFunctions: alignment.warped.map(\.warpFunction)
        )
    }

    // MARK: - Windowing

    private static func sampleWindow(
        startMs: Double?,
        endMs: Double?,
        stimulusOffsetSamples: Int,
        samplingRate: Double,
        length: Int
    ) -> Range<Int>? {
        guard let startMs, let endMs, endMs > startMs else { return nil }
        let startSample = stimulusOffsetSamples + Int((startMs / 1000.0 * samplingRate).rounded())
        let endSample = stimulusOffsetSamples + Int((endMs / 1000.0 * samplingRate).rounded())
        let lower = max(0, min(startSample, endSample))
        let upper = min(length, max(startSample, endSample) + 1)
        return lower < upper ? lower..<upper : nil
    }

    private static func filterPeaks(_ peaks: [CWTRidgeDetector.Peak], to window: Range<Int>?) -> [CWTRidgeDetector.Peak] {
        guard let window else { return peaks }
        return peaks.filter { window.contains($0.sampleIndex) }
    }
}
