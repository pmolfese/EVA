//
//  GradientANC.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Independent implementation written from EVA's own functional specification
//  (docs/provenance/fastr-functional-spec.md) under the clean-room process
//  described in docs/provenance/README.md. No third-party artifact-correction source
//  was consulted. Method reference: Niazy et al., NeuroImage 28(3):720-737, 2005.
//
//  Adaptive noise cancellation.
//
//  Template subtraction and OBS both work epoch by epoch, so neither can follow
//  artifact whose amplitude or shape wanders continuously through a scan. ANC
//  takes what those stages removed as a reference for what the artifact looks
//  like, and adaptively estimates how much of it is still present in the cleaned
//  signal.
//
//  The filter is normalized LMS. Normalizing the step by the reference's running
//  energy is what keeps it stable across the enormous dynamic range of gradient
//  artifact — a plain LMS step tuned for one recording would diverge on another.
//  The spec is explicit that stability and finite output matter more here than
//  matching any historical implementation, so the filter also bails out and
//  returns the input untouched rather than emitting anything non-finite.
//

import Foundation

nonisolated enum GradientANC {

    /// Which cutoff the pre-filter uses.
    nonisolated enum HighPassPolicy: String, CaseIterable, Identifiable, Sendable {
        /// A fixed 2 Hz cutoff.
        case fixed2Hz
        /// A cutoff derived from the rate at which artifact epochs arrive, for
        /// slice-level correction where that rate is well above 2 Hz.
        case sliceTriggerDependent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fixed2Hz: return "Fixed 2 Hz"
            case .sliceTriggerDependent: return "Slice-Rate Derived"
            }
        }
    }

    /// Resolves the policy to an actual cutoff in Hz.
    ///
    /// The slice-derived cutoff sits at half the epoch rate: high enough to keep
    /// drift out of the adaptation, low enough to leave the artifact fundamental
    /// and its harmonics intact. It falls back to 2 Hz when the epoch rate is not
    /// meaningfully above it, which is the case for volume-level correction.
    static func cutoffHz(
        policy: HighPassPolicy,
        epochPeriodSamples: Int,
        samplingRate: Double
    ) -> Double {
        switch policy {
        case .fixed2Hz:
            return 2
        case .sliceTriggerDependent:
            guard epochPeriodSamples > 0, samplingRate > 0 else { return 2 }
            let epochRate = samplingRate / Double(epochPeriodSamples)
            let derived = epochRate / 2
            return derived > 2 ? min(derived, samplingRate / 4) : 2
        }
    }

    struct Result {
        let output: [Float]
        let applied: Bool
    }

    /// Removes whatever part of `reference` still correlates with `cleaned`.
    ///
    /// - Parameters:
    ///   - cleaned: Signal after template subtraction and any OBS.
    ///   - reference: The artifact estimate those stages removed.
    ///   - cutoffHz: High-pass applied to both before adaptation.
    ///   - samplingRate: Samples per second.
    ///   - filterLength: Adaptive filter taps.
    ///   - stepSize: NLMS step, stable for 0 < step < 2.
    /// - Returns: The corrected signal, and whether ANC actually ran. A reference
    ///   with no variance carries no information about the artifact, so the input
    ///   is returned unchanged in that case.
    static func apply(
        cleaned: [Float],
        reference: [Float],
        cutoffHz: Double,
        samplingRate: Double,
        filterLength: Int,
        stepSize: Double
    ) -> Result {
        let count = cleaned.count
        guard count > 0, reference.count == count else { return Result(output: cleaned, applied: false) }
        let taps = max(1, min(filterLength, count))
        guard stepSize > 0, stepSize < 2 else { return Result(output: cleaned, applied: false) }

        let desired = GradientFilters.highPassZeroPhase(cleaned, cutoffHz: cutoffHz, samplingRate: samplingRate)
        let source = GradientFilters.highPassZeroPhase(reference, cutoffHz: cutoffHz, samplingRate: samplingRate)

        func variance(of values: [Float]) -> Double {
            var mean = 0.0
            for value in values { mean += Double(value) }
            mean /= Double(values.count)
            var total = 0.0
            for value in values {
                let deviation = Double(value) - mean
                total += deviation * deviation
            }
            return total / Double(values.count)
        }

        let referenceVariance = variance(of: source)
        let signalVariance = variance(of: desired)

        // A reference has to carry real artifact power to be worth adapting
        // against. The absolute floor catches an all-zero reference; the relative
        // floor catches one that is numerically non-zero but negligible next to
        // the signal — without it, normalized LMS divides by an almost-zero
        // energy, the weights grow without bound, and the filter ends up fitting
        // and subtracting the brain signal itself.
        // The relative floor is set well below any real artifact-to-EEG ratio
        // (gradient artifact runs one to two orders of magnitude above the
        // signal, so hundreds to millions in variance terms) and well above the
        // numerical residue a high-pass leaves behind on a flat input.
        guard referenceVariance > 1e-12,
              referenceVariance > 1e-4 * signalVariance
        else {
            return Result(output: cleaned, applied: false)
        }
        let variance = referenceVariance

        // Regularizer keeps the normalized step finite through quiet stretches;
        // scaling it to the reference's own power keeps that behavior consistent
        // whatever units the recording is in.
        let regularizer = max(variance * 1e-6, Double.leastNormalMagnitude)

        var weights = [Double](repeating: 0, count: taps)
        var estimate = [Float](repeating: 0, count: count)

        for sample in 0..<count {
            var predicted = 0.0
            var energy = 0.0
            for tap in 0..<taps {
                let index = sample - tap
                guard index >= 0 else { break }
                let value = Double(source[index])
                predicted += weights[tap] * value
                energy += value * value
            }
            guard predicted.isFinite, energy.isFinite else {
                return Result(output: cleaned, applied: false)
            }

            let error = Double(desired[sample]) - predicted
            let normalizer = energy + regularizer
            let gain = stepSize * error / normalizer
            for tap in 0..<taps {
                let index = sample - tap
                guard index >= 0 else { break }
                weights[tap] += gain * Double(source[index])
            }
            estimate[sample] = Float(predicted)
        }

        var output = [Float](repeating: 0, count: count)
        for sample in 0..<count {
            let value = cleaned[sample] - estimate[sample]
            guard value.isFinite else { return Result(output: cleaned, applied: false) }
            output[sample] = value
        }
        return Result(output: output, applied: true)
    }
}
