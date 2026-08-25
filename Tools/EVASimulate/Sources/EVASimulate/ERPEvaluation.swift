//
//  ERPEvaluation.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The evaluation criteria of Rusiniak et al. (2022), roadmap 5.3.
//
//  The paper compares BCG correction methods by what survives in an evoked
//  response, not by residual artifact — which is the right question for anyone
//  who wants to analyse the EEG afterwards, and a different question from the
//  broadband SNR that `score` reports. Four criteria:
//
//  1. **Accepted trials.** Epochs are rejected for peak-to-peak amplitude above
//     120 µV or a sample-to-sample gradient above 75 µV, after filtering
//     0.3-30 Hz. A method that leaves large residuals loses trials, and losing
//     trials costs SNR independently of any distortion.
//  2. **SNR of the average**, as the ratio of post-stimulus RMS (0-300 ms) to
//     pre-stimulus RMS (-300-0 ms), averaged over channels. Note this is *not*
//     the `score` command's SNR: it needs no ground truth, which is why the
//     paper could use it on real data.
//  3. **Peak latency and amplitude** of the evoked response in 0-200 ms, at the
//     channel where the seeded model is strongest.
//  4. **Explained variance** of the seeded dipole model over the component's
//     full-width-half-maximum window. 100% would mean the averaged topography
//     is entirely accounted for by the dipoles that generated it; lower values
//     mean the correction distorted the topography, which is what damages
//     source localization.
//
//  ## What is here and what is not
//
//  Criteria 1-3 and explained variance are implemented. **Dipole localization
//  error is not.** The paper fits free dipoles with Nelder-Mead and reports the
//  distance to the seeded positions; that needs an inverse solver, which is
//  Tier 6 work (6.1-6.2). Explained variance covers the same concern — topographic
//  distortion — without one, and it is the metric the paper leans on for the
//  grand average.
//
//  ## Everything here is per-run
//
//  Corrected broadband SNR varies by roughly a factor of two across seeds at a
//  fixed configuration (roadmap 5.3). Every number these functions return is a
//  single realization and means very little alone; the caller is expected to
//  repeat over seeds and report the spread.
//

import Foundation

nonisolated struct ERPEvaluationThresholds: Sendable {
    /// Paper: epochs with peak-to-peak amplitude greater than 120 µV are excluded.
    var peakToPeakMicrovolts: Double = 120
    /// Paper: signal gradients greater than 75 µV/sample are excluded.
    var gradientMicrovoltsPerSample: Double = 75
    /// Paper: rejection is judged on data filtered 0.3-30 Hz.
    var detectionLowHz: Double = 0.3
    var detectionHighHz: Double = 30

    var preStimulusSeconds: Double = 0.3
    var postStimulusSeconds: Double = 0.8
    /// Window for the SNR ratio and for peak detection.
    var responseWindowSeconds: Double = 0.3
    var peakSearchSeconds: Double = 0.2

    static let paper = ERPEvaluationThresholds()
}

nonisolated struct ERPEvaluationResult: Sendable {
    var acceptedTrials: Int
    var candidateTrials: Int
    /// Post-stimulus RMS over pre-stimulus RMS, averaged across channels.
    var signalToNoise: Double
    var peakLatencySeconds: Double
    var peakAmplitudeMicrovolts: Double
    /// Fraction of averaged data variance explained by the seeded dipole model
    /// over the FWHM window, in 0...1.
    var explainedVariance: Double
    /// Channel the peak was read from.
    var peakChannel: Int
}

nonisolated enum ERPEvaluation {

    /// Epochs, rejects, averages, and scores one recording.
    ///
    /// - Parameter modelTopographies: the seeded component topographies, used
    ///   for explained variance. Passing the *true* generators is deliberate:
    ///   the paper fits its own seeded model, and the question is how much of
    ///   the corrected average that model still accounts for.
    static func evaluate(
        channels: [[Double]],
        samplingRate: Double,
        onsets: [Double],
        conditions: [String],
        scoringCondition: String? = nil,
        modelTopographies: [[Double]],
        fwhmStartSeconds: Double,
        fwhmEndSeconds: Double,
        thresholds: ERPEvaluationThresholds = .paper
    ) -> ERPEvaluationResult? {
        guard !channels.isEmpty, !onsets.isEmpty else { return nil }
        let sampleCount = channels.map(\.count).min() ?? 0
        let preSamples = Int((thresholds.preStimulusSeconds * samplingRate).rounded())
        let postSamples = Int((thresholds.postStimulusSeconds * samplingRate).rounded())
        let epochLength = preSamples + postSamples

        // Rejection is judged on filtered data, but the average is formed from
        // the unfiltered epochs — the paper turns the filters off for averaging
        // and re-applies them to the average afterwards.
        let detection = channels.map {
            Filtering.bandPassZeroPhase(
                $0, samplingRate: samplingRate,
                lowHz: thresholds.detectionLowHz, highHz: thresholds.detectionHighHz
            )
        }

        var sum = [[Double]](
            repeating: [Double](repeating: 0, count: epochLength), count: channels.count
        )
        var accepted = 0
        var candidates = 0

        for (index, onset) in onsets.enumerated() {
            if let scoringCondition, index < conditions.count,
               conditions[index] != scoringCondition { continue }
            let start = Int((onset * samplingRate).rounded()) - preSamples
            guard start >= 0, start + epochLength <= sampleCount else { continue }
            candidates += 1

            var reject = false
            for channel in detection.indices {
                var minimum = Double.infinity
                var maximum = -Double.infinity
                var previous = detection[channel][start]
                for offset in 0..<epochLength {
                    let value = detection[channel][start + offset]
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    if offset > 0, abs(value - previous) > thresholds.gradientMicrovoltsPerSample {
                        reject = true
                        break
                    }
                    previous = value
                }
                if reject || maximum - minimum > thresholds.peakToPeakMicrovolts {
                    reject = true
                    break
                }
            }
            guard !reject else { continue }

            accepted += 1
            for channel in channels.indices {
                for offset in 0..<epochLength {
                    sum[channel][offset] += channels[channel][start + offset]
                }
            }
        }
        guard accepted > 0 else {
            return ERPEvaluationResult(
                acceptedTrials: 0, candidateTrials: candidates, signalToNoise: 0,
                peakLatencySeconds: 0, peakAmplitudeMicrovolts: 0,
                explainedVariance: 0, peakChannel: 0
            )
        }
        for channel in sum.indices {
            for offset in 0..<epochLength { sum[channel][offset] /= Double(accepted) }
        }

        // The paper disables filtering while epochs are accumulated, then
        // applies the same 0.3-30 Hz evaluation band to the finished average.
        // Previously the comment above promised this step but the metrics below
        // were computed from the unfiltered average. That made our values
        // internally repeatable, but not comparable with the stated procedure.
        for channel in sum.indices {
            sum[channel] = Filtering.bandPassZeroPhase(
                sum[channel], samplingRate: samplingRate,
                lowHz: thresholds.detectionLowHz, highHz: thresholds.detectionHighHz
            )
        }

        // Baseline-correct on the pre-stimulus interval, as any ERP pipeline
        // does; without it the SNR ratio measures offset rather than response.
        for channel in sum.indices {
            guard preSamples > 0 else { break }
            let mean = (0..<preSamples).reduce(0.0) { $0 + sum[channel][$1] } / Double(preSamples)
            for offset in 0..<epochLength { sum[channel][offset] -= mean }
        }

        let responseSamples = min(
            postSamples, Int((thresholds.responseWindowSeconds * samplingRate).rounded())
        )
        var ratios: [Double] = []
        for channel in sum.indices {
            let baseline = rootMeanSquare(Array(sum[channel][0..<preSamples]))
            let response = rootMeanSquare(
                Array(sum[channel][preSamples..<(preSamples + responseSamples)])
            )
            if baseline > 1e-15 { ratios.append(response / baseline) }
        }
        let snr = ratios.isEmpty ? 0 : ratios.reduce(0, +) / Double(ratios.count)

        // Peak at the channel the seeded model drives hardest — the analogue of
        // the paper reading N100 at Cz, but chosen by the model rather than by
        // montage convention, so it transfers to any montage.
        var peakChannel = 0
        if let first = modelTopographies.first {
            var strongest = 0.0
            for channel in first.indices {
                var magnitude = 0.0
                for topography in modelTopographies where channel < topography.count {
                    magnitude += abs(topography[channel])
                }
                if magnitude > strongest {
                    strongest = magnitude
                    peakChannel = channel
                }
            }
        }
        let searchSamples = min(
            postSamples, Int((thresholds.peakSearchSeconds * samplingRate).rounded())
        )
        var peakOffset = 0
        var peakValue = 0.0
        for offset in 0..<searchSamples {
            let value = sum[peakChannel][preSamples + offset]
            if abs(value) > abs(peakValue) {
                peakValue = value
                peakOffset = offset
            }
        }

        let explained = explainedVariance(
            average: sum, samplingRate: samplingRate, preSamples: preSamples,
            modelTopographies: modelTopographies,
            startSeconds: fwhmStartSeconds, endSeconds: fwhmEndSeconds
        )

        return ERPEvaluationResult(
            acceptedTrials: accepted,
            candidateTrials: candidates,
            signalToNoise: snr,
            peakLatencySeconds: Double(peakOffset) / samplingRate,
            peakAmplitudeMicrovolts: peakValue,
            explainedVariance: explained,
            peakChannel: peakChannel
        )
    }

    /// Fraction of averaged data variance the seeded model accounts for over a
    /// window.
    ///
    /// At each sample the measured topography is projected onto the span of the
    /// model topographies — a least-squares fit of the dipole amplitudes with
    /// their positions and orientations held at the seeded values — and the
    /// residual is accumulated. This is the paper's "signal variance explained
    /// by the dipolar model", and it is the criterion that separated the methods
    /// most sharply in their results.
    static func explainedVariance(
        average: [[Double]],
        samplingRate: Double,
        preSamples: Int,
        modelTopographies: [[Double]],
        startSeconds: Double,
        endSeconds: Double
    ) -> Double {
        guard !modelTopographies.isEmpty, !average.isEmpty else { return 0 }
        let channelCount = average.count
        let epochLength = average[0].count
        let start = min(max(0, preSamples + Int((startSeconds * samplingRate).rounded())), epochLength)
        let end = min(max(start, preSamples + Int((endSeconds * samplingRate).rounded())), epochLength)
        guard end > start else { return 0 }

        // Orthonormal basis for the model span, so the projection is a sum of
        // squared inner products rather than a normal-equation solve.
        var basis: [[Double]] = []
        for topography in modelTopographies {
            var vector = (0..<channelCount).map { $0 < topography.count ? topography[$0] : 0 }
            for existing in basis {
                let dot = zip(vector, existing).reduce(0.0) { $0 + $1.0 * $1.1 }
                for index in vector.indices { vector[index] -= dot * existing[index] }
            }
            let norm = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-12 else { continue }
            basis.append(vector.map { $0 / norm })
        }
        guard !basis.isEmpty else { return 0 }

        var totalSquares = 0.0
        var explainedSquares = 0.0
        for sample in start..<end {
            let column = (0..<channelCount).map { average[$0][sample] }
            totalSquares += column.reduce(0.0) { $0 + $1 * $1 }
            for vector in basis {
                let projection = zip(column, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
                explainedSquares += projection * projection
            }
        }
        guard totalSquares > 1e-30 else { return 0 }
        return min(1, explainedSquares / totalSquares)
    }

    private static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0.0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }
}
