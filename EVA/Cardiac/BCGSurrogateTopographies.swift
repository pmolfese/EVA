//
//  BCGSurrogateTopographies.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The artifact half of the surrogate model for the ballistocardiogram: from
//  detected beats to a small dictionary of BCG topographies (ROADMAP SI-3).
//
//  This is a *domain adapter*, and it lives with its evidence. The operator
//  construction is app-wide (`SourceInformedSeparation`), the brain basis is
//  app-neutral (`SurrogateBrainModel`), and how you find out what a BCG looks
//  like in this recording is cardiac knowledge: beat-locked epochs, a band the
//  artifact lives in, a pattern search over beats, and the principal components
//  of the resulting template. Ocular calibration will supply its own adapter and
//  reuse everything else.
//
//  ## Method
//
//  Follows the procedure described in:
//
//    Rusiniak M, Bornfleth H, Cho J-H, Wolak T, Ille N, Berg P, Scherg M (2022).
//    EEG-fMRI: Ballistocardiogram Artifact Reduction by Surrogate Method for
//    Improved Source Localization. Front. Neurosci. 16:842420.
//
//  which applies the source-space separation of Berg & Scherg (1994). Written
//  from the published description; no implementation is copied.
//
//  ## The two pattern searches, and why both exist
//
//  The publication picks one representative beat by eye and keeps the beats that
//  correlate with it above 60%. Matching against a *single* epoch is a poor
//  automatic substitute: one beat carries a full share of ongoing EEG, so the
//  correlation is diluted and the threshold rejects most of the recording — and
//  a template built from what survives is contaminated enough that its
//  lower-variance components are EEG rather than artifact, which the filter then
//  removes from the data.
//
//  Averaging first and re-matching against the average suppresses EEG by √N
//  before the comparison, so the threshold judges beats against the artifact
//  rather than against one noisy example. That is `.iterative`, and it is what
//  EVA offers by default. `.paper` is retained exactly so a methods comparison
//  can separate fidelity to the publication from the practical improvement,
//  instead of conflating them.
//

import Foundation

/// How the representative BCG pattern is chosen before beat averaging.
nonisolated enum BCGArtifactPatternSearch: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The published procedure: one representative beat, then a single
    /// correlation pass over the candidates.
    case paper
    /// EVA's noise-tolerant variant: start from the all-beat average and refine
    /// the accepted set twice.
    case iterative

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .paper: return "Paper (single representative beat)"
        case .iterative: return "Iterative (refine from the average)"
        }
    }
}

/// The BCG topography dictionary and how it was arrived at.
nonisolated struct BCGArtifactComponents: Sendable {
    /// components × channels, unit norm, in the good-channel row order supplied
    /// to `components(...)`.
    var topographies: [[Double]]
    /// Share of template variance carried by each retained component.
    var varianceFractions: [Double]
    /// Split-half reliability of each retained component: the correlation
    /// between its time course in the odd-beat template and in the even-beat
    /// template. A real artifact component repeats beat to beat and scores near
    /// 1; a component that is ongoing EEG surviving the average does not.
    var reliabilities: [Double]
    /// Components dropped for failing the reliability gate, with their variance
    /// share — recorded because "we found six components and used three" is a
    /// fact about the recording, not an implementation detail.
    var rejectedForReliability: [(varianceFraction: Double, reliability: Double)]
    var acceptedBeatCount: Int
    var candidateBeatCount: Int
    /// The averaged artifact template, channels × samples.
    var template: [[Double]]
    var templateStartSeconds: Double
    var patternSearch: BCGArtifactPatternSearch
    /// Candidate-epoch index chosen as the representative beat in paper mode.
    var representativeBeatIndex: Int?
}

nonisolated enum BCGSurrogateTopographies {

    /// Builds the averaged BCG template and its principal components.
    ///
    /// - Parameters:
    ///   - channels: the good EEG subset, already band-limited by the caller if
    ///     desired; this applies its own template band-pass regardless.
    ///   - beatSeconds: detected beat times. These come from EVA's existing
    ///     detectors — this does not detect anything.
    ///
    /// Returns `nil` when there is not enough evidence to build a dictionary:
    /// fewer than two usable beat epochs, an empty template, or no component
    /// above the variance threshold. A caller must treat that as a refusal, not
    /// as "no artifact present".
    static func components(
        channels: [[Double]],
        samplingRate: Double,
        beatSeconds: [Double],
        settings: BCGSurrogateSettings
    ) async -> BCGArtifactComponents? {
        guard !channels.isEmpty, !beatSeconds.isEmpty, samplingRate > 0 else { return nil }
        // EVA's own filter, not a private one: the band that defines the
        // template is a filtering decision, and a second implementation of
        // "band-pass 1-20 Hz" is exactly the kind of quiet divergence
        // `PipelineInvalidation` exists to prevent one level up. Zero phase
        // matters here because a phase shift moves the beat-locked template
        // relative to the beats it was cut on; the IIR path is already
        // forward-backward.
        guard let filtered = try? await EEGSignalFilter.bandPass(
            channels: channels.map { $0.map(Float.init) },
            samplingRate: samplingRate,
            lowCutoff: settings.bandLowHz,
            highCutoff: settings.bandHighHz,
            highPassFamily: .iir,
            lowPassFamily: .iir,
            iirDesign: .butterworth
        ).map({ $0.map(Double.init) }) else { return nil }
        guard let first = filtered.first, !first.isEmpty else { return nil }
        let sampleCount = first.count
        let offset = Int((settings.windowStartSeconds * samplingRate).rounded())
        let length = max(
            2,
            Int(((settings.windowEndSeconds - settings.windowStartSeconds) * samplingRate).rounded())
        )

        var epochs: [[[Double]]] = []
        for beat in beatSeconds.sorted() {
            let start = Int((beat * samplingRate).rounded()) + offset
            guard start >= 0, start + length <= sampleCount else { continue }
            epochs.append(filtered.map { Array($0[start..<(start + length)]) })
        }
        guard epochs.count >= 2 else { return nil }

        func average(_ selection: [[[Double]]]) -> [[Double]] {
            var result = [[Double]](
                repeating: [Double](repeating: 0, count: length), count: filtered.count
            )
            guard !selection.isEmpty else { return result }
            for epoch in selection {
                for channel in result.indices {
                    for sample in 0..<length { result[channel][sample] += epoch[channel][sample] }
                }
            }
            for channel in result.indices {
                for sample in 0..<length { result[channel][sample] /= Double(selection.count) }
            }
            return result
        }

        let template: [[Double]]
        let accepted: [[[Double]]]
        let representativeBeatIndex: Int?
        switch settings.patternSearch {
        case .paper:
            // The publication chooses the representative beat manually. An
            // unattended run needs a deterministic rule, so use the
            // median-energy epoch: unlike the largest beat it is not an outlier,
            // and unlike an all-beat average it does not leak every candidate
            // into the reference pattern.
            var ranked: [(index: Int, energy: Double)] = []
            ranked.reserveCapacity(epochs.count)
            for (index, epoch) in epochs.enumerated() {
                var energy = 0.0
                for channel in epoch {
                    for value in channel { energy += value * value }
                }
                ranked.append((index: index, energy: energy))
            }
            ranked.sort { $0.energy == $1.energy ? $0.index < $1.index : $0.energy < $1.energy }
            let representative = ranked[ranked.count / 2].index
            let seed = epochs[representative]
            let matched = epochs.filter {
                spatioTemporalCorrelation($0, seed) >= settings.correlationThreshold
            }
            guard matched.count >= 2 else { return nil }
            accepted = matched
            template = average(matched)
            representativeBeatIndex = representative

        case .iterative:
            var refinedTemplate = average(epochs)
            var refinedAccepted = epochs
            for _ in 0..<2 {
                let matched = epochs.filter {
                    spatioTemporalCorrelation($0, refinedTemplate) >= settings.correlationThreshold
                }
                // Never end up with nothing: if the threshold rejects everything,
                // the previous selection stands and the accepted count makes
                // that visible rather than silent.
                guard matched.count >= 2 else { break }
                refinedAccepted = matched
                refinedTemplate = average(refinedAccepted)
            }
            accepted = refinedAccepted
            template = refinedTemplate
            representativeBeatIndex = nil
        }

        // PCA over channels: the covariance is channels × channels, and its
        // eigenvectors are the spatial patterns the template is built from.
        let channelCount = template.count
        var covariance = [[Double]](
            repeating: [Double](repeating: 0, count: channelCount), count: channelCount
        )
        for row in 0..<channelCount {
            for column in row..<channelCount {
                var sum = 0.0
                for sample in 0..<length { sum += template[row][sample] * template[column][sample] }
                covariance[row][column] = sum
                covariance[column][row] = sum
            }
        }
        let decomposition = LinearAlgebra.symmetricEigenDecomposition(covariance)
        let total = decomposition.values.reduce(0.0) { $0 + max(0, $1) }
        guard total > 1e-30 else { return nil }

        // Split-half templates, for the reliability gate below. Odd and even
        // *accepted* beats, so both halves see the same pattern search.
        let oddTemplate = average(accepted.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        let evenTemplate = average(accepted.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))

        var topographies: [[Double]] = []
        var fractions: [Double] = []
        var reliabilities: [Double] = []
        var rejected: [(varianceFraction: Double, reliability: Double)] = []
        // `symmetricEigenDecomposition` stores eigenvectors as columns with
        // values ascending; PCA-S consumes the same pairs largest-first.
        for component in decomposition.values.indices.reversed() {
            let value = decomposition.values[component]
            let vector = (0..<channelCount).map { decomposition.vectors[$0][component] }
            let fraction = max(0, value) / total
            guard fraction > settings.varianceThreshold else { break }
            let norm = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-15 else { continue }
            let unit = vector.map { $0 / norm }

            // The gate that stops the dictionary filling up with brain.
            //
            // Every principal component of a beat-locked average carries *some*
            // variance, including the ongoing EEG the average failed to cancel —
            // and a filter handed an EEG topography as "artifact" removes brain
            // signal, confidently. Measured on a brain-dominated fixture, taking
            // every component above the variance threshold turned a 2.8:1
            // recording into a 1.3:1 one: the correction was the largest source
            // of error in it.
            //
            // What separates the two is repetition, not size: the artifact is
            // the same shape on the odd beats and the even beats, and ongoing
            // EEG is not. So each candidate's time course is projected out of
            // both half-templates and the two are correlated.
            let reliability = Self.componentReliability(
                topography: unit, odd: oddTemplate, even: evenTemplate
            )
            guard reliability >= settings.minimumComponentReliability else {
                rejected.append((varianceFraction: fraction, reliability: reliability))
                continue
            }
            topographies.append(unit)
            fractions.append(fraction)
            reliabilities.append(reliability)
        }
        guard !topographies.isEmpty else { return nil }

        return BCGArtifactComponents(
            topographies: topographies,
            varianceFractions: fractions,
            reliabilities: reliabilities,
            rejectedForReliability: rejected,
            acceptedBeatCount: accepted.count,
            candidateBeatCount: epochs.count,
            template: template,
            templateStartSeconds: settings.windowStartSeconds,
            patternSearch: settings.patternSearch,
            representativeBeatIndex: representativeBeatIndex
        )
    }

    /// Correlation between one component's time course in the odd-beat and
    /// even-beat halves of the template.
    ///
    /// Zero when either half carries no energy on this topography, which is the
    /// honest answer: no evidence is not the same as agreement.
    static func componentReliability(
        topography: [Double],
        odd: [[Double]],
        even: [[Double]]
    ) -> Double {
        func project(_ template: [[Double]]) -> [Double] {
            let sampleCount = template.first?.count ?? 0
            guard sampleCount > 0 else { return [] }
            return (0..<sampleCount).map { sample in
                var sum = 0.0
                for channel in 0..<min(topography.count, template.count) {
                    sum += topography[channel] * template[channel][sample]
                }
                return sum
            }
        }
        let first = project(odd)
        let second = project(even)
        let count = min(first.count, second.count)
        guard count > 1 else { return 0 }
        let firstMean = first.prefix(count).reduce(0, +) / Double(count)
        let secondMean = second.prefix(count).reduce(0, +) / Double(count)
        var covariance = 0.0, firstEnergy = 0.0, secondEnergy = 0.0
        for index in 0..<count {
            let a = first[index] - firstMean
            let b = second[index] - secondMean
            covariance += a * b
            firstEnergy += a * a
            secondEnergy += b * b
        }
        guard firstEnergy > 1e-30, secondEnergy > 1e-30 else { return 0 }
        return covariance / (firstEnergy * secondEnergy).squareRoot()
    }

    /// Correlation over channels and time at once, which is what makes the
    /// pattern search spatio-temporal rather than a per-channel match.
    static func spatioTemporalCorrelation(_ lhs: [[Double]], _ rhs: [[Double]]) -> Double {
        var dot = 0.0
        var leftSquares = 0.0
        var rightSquares = 0.0
        for channel in 0..<min(lhs.count, rhs.count) {
            for sample in 0..<min(lhs[channel].count, rhs[channel].count) {
                let a = lhs[channel][sample]
                let b = rhs[channel][sample]
                dot += a * b
                leftSquares += a * a
                rightSquares += b * b
            }
        }
        let denominator = (leftSquares * rightSquares).squareRoot()
        return denominator > 1e-30 ? dot / denominator : 0
    }
}
