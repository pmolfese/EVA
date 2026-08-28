//
//  BCGComponentLabeller.swift
//  EVA
//
//  Scanner-specific, beat-locked ICA component suggestions. Simulator truth is
//  deliberately absent from this file: at inference the labeller sees only the
//  recovered component sources, user-detected R waves, optional ECG, and the
//  ordinary ICLabel/heuristic suggestion used as a weak prior.
//

import Foundation

nonisolated struct BCGComponentFeatures: Codable, Sendable, Equatable {
    /// Fraction of beat-epoch energy explained by the average beat template.
    var beatLockedFraction: Double
    /// Mean absolute correlation between individual beat epochs and the template.
    var beatConsistency: Double
    /// Evidence that the template occurs after, rather than before, the R wave.
    var postQRSProminence: Double
    /// Maximum absolute ECG/component correlation over physiologic BCG delays.
    var ecgRelationship: Double
    /// Existing ICLabel/heuristic Heart probability, used only as a weak prior.
    var heartPrior: Double

    var vector: [Double] {
        [beatLockedFraction, beatConsistency, postQRSProminence, ecgRelationship, heartPrior]
    }
}

nonisolated struct BCGComponentTrainingExample: Sendable {
    var features: BCGComponentFeatures
    /// Continuous simulator target: BCG-subspace energy / (BCG + neural energy).
    var target: Double
}

/// A deliberately small, inspectable logistic model. The named coefficients can
/// be re-fit from simulator examples and printed in a methods section; no model
/// archive or opaque learned representation is involved.
nonisolated struct BCGComponentLogisticModel: Codable, Sendable, Equatable {
    var intercept: Double
    var weights: [Double]

    /// Version 1 pilot calibration, fit by `BCGComponentLabellerTests` on the
    /// 1.5 T/20-channel and 3 T/32-channel EVASimulate corpora. The 7 T/24-channel
    /// generator configuration is held out. Coefficient order matches `vector`.
    static let simulatorPilotV1 = BCGComponentLogisticModel(
        intercept: -1.038499661457266,
        weights: [
            0.30722572072485255,
            0.2618746147707277,
            0.22657120306462822,
            0.5565726796360381,
            -0.00034699945259303793
        ]
    )

    func probability(for features: BCGComponentFeatures) -> Double {
        let value = zip(weights, features.vector).reduce(intercept) { $0 + $1.0 * $1.1 }
        if value >= 0 {
            let inverse = exp(-value)
            return 1 / (1 + inverse)
        }
        let exponential = exp(value)
        return exponential / (1 + exponential)
    }

    /// Fits the same inspectable model against graded (not forced-binary) truth.
    /// This is used by the simulator evaluation path, never during user analysis.
    static func fit(
        _ examples: [BCGComponentTrainingExample],
        iterations: Int = 2_000,
        learningRate: Double = 0.08,
        l2Penalty: Double = 0.02
    ) -> BCGComponentLogisticModel {
        guard !examples.isEmpty else { return .simulatorPilotV1 }
        var intercept = 0.0
        var weights = [Double](repeating: 0, count: 5)
        let count = Double(examples.count)
        for iteration in 0..<max(iterations, 1) {
            var interceptGradient = 0.0
            var gradients = [Double](repeating: 0, count: weights.count)
            for example in examples {
                let vector = example.features.vector
                let linear = zip(weights, vector).reduce(intercept) { $0 + $1.0 * $1.1 }
                let predicted = 1 / (1 + exp(-min(max(linear, -30), 30)))
                let error = predicted - min(max(example.target, 0), 1)
                interceptGradient += error
                for index in gradients.indices { gradients[index] += error * vector[index] }
            }
            let step = learningRate / sqrt(1 + Double(iteration) / 250)
            intercept -= step * interceptGradient / count
            for index in weights.indices {
                weights[index] -= step * (gradients[index] / count + l2Penalty * weights[index])
            }
        }
        return BCGComponentLogisticModel(intercept: intercept, weights: weights)
    }
}

nonisolated enum BCGComponentLabeller {
    static let minimumBeatCount = 8
    /// The graded target is not a binary posterior. This review threshold was
    /// selected on the training corpora and is not a claim of clinical certainty.
    static let suggestionThreshold = 0.46

    /// Adds scanner-specific BCG evidence to the ordinary suggestions. Low BCG
    /// scores leave the original label intact; high scores become a Heart BCG
    /// suggestion but are never automatically selected for removal.
    static func augmenting(
        _ base: [Int: ICAComponentSuggestion],
        decomposition: ICADecomposition,
        detectedBeatTimes: [Double],
        ecg: [Float]? = nil,
        ecgSamplingRate: Double? = nil,
        model: BCGComponentLogisticModel = .simulatorPilotV1
    ) -> [Int: ICAComponentSuggestion] {
        let beats = detectedBeatTimes.filter { $0.isFinite }.sorted()
        guard beats.count >= minimumBeatCount else { return base }
        var result = base
        for component in 0..<decomposition.componentCount {
            guard decomposition.componentSources.indices.contains(component),
                  let features = features(
                    source: decomposition.componentSources[component],
                    samplingRate: decomposition.analysisSamplingRate,
                    detectedBeatTimes: beats,
                    ecg: ecg,
                    ecgSamplingRate: ecgSamplingRate,
                    heartPrior: heartPrior(from: base[component])
                  ) else { continue }
            let probability = model.probability(for: features)
            let evidence = String(
                format: "BCG %.0f%%: beat locking %.2f, beat consistency %.2f, post-QRS prominence %.2f, ECG relationship %.2f; uses %d detected R waves",
                probability * 100, features.beatLockedFraction, features.beatConsistency,
                features.postQRSProminence, features.ecgRelationship, beats.count
            )
            var probabilities = base[component]?.probabilities ?? [:]
            // BCG is an extra scanner-specific diagnostic, not an eighth member
            // of ICLabel's mutually exclusive seven-class probability vector.
            probabilities["BCG"] = probability
            if probability >= suggestionThreshold {
                result[component] = ICAComponentSuggestion(
                    label: "Heart BCG \(Int((probability * 100).rounded()))%",
                    confidence: probability,
                    reason: evidence + ". Review the beat-locked trace before selecting this component for removal.",
                    probabilities: probabilities
                )
            } else if var existing = result[component] {
                existing.probabilities = probabilities
                existing.reason += "; " + evidence
                result[component] = existing
            }
        }
        return result
    }

    static func features(
        source: [Double],
        samplingRate: Double,
        detectedBeatTimes: [Double],
        ecg: [Float]? = nil,
        ecgSamplingRate: Double? = nil,
        heartPrior: Double = 0
    ) -> BCGComponentFeatures? {
        guard samplingRate > 0, source.count > 2 else { return nil }
        let preSamples = max(Int((0.20 * samplingRate).rounded()), 1)
        let postSamples = max(Int((0.70 * samplingRate).rounded()), 2)
        let epochCount = preSamples + postSamples + 1
        var epochs: [[Double]] = []
        for time in detectedBeatTimes where time.isFinite {
            let center = Int((time * samplingRate).rounded())
            guard center - preSamples >= 0, center + postSamples < source.count else { continue }
            let baselineRange = (center - preSamples)..<center
            let baseline = baselineRange.reduce(0.0) { $0 + source[$1] } / Double(preSamples)
            epochs.append((center - preSamples...center + postSamples).map { source[$0] - baseline })
        }
        guard epochs.count >= minimumBeatCount else { return nil }

        var template = [Double](repeating: 0, count: epochCount)
        for epoch in epochs {
            for index in template.indices { template[index] += epoch[index] }
        }
        for index in template.indices { template[index] /= Double(epochs.count) }

        let templateEnergy = template.reduce(0) { $0 + $1 * $1 }
        let epochEnergy = epochs.reduce(0.0) { total, epoch in
            total + epoch.reduce(0) { $0 + $1 * $1 }
        } / Double(epochs.count)
        let beatLocked = clamp01(templateEnergy / max(epochEnergy, 1e-20))
        let consistency = epochs.reduce(0.0) { $0 + absCorrelation($1, template) }
            / Double(epochs.count)

        let earlyPost = min(preSamples + max(Int(0.04 * samplingRate), 1), template.count - 1)
        let latePost = min(preSamples + max(Int(0.60 * samplingRate), 2), template.count - 1)
        let preEnergy = template[..<preSamples].reduce(0) { $0 + $1 * $1 } / Double(preSamples)
        let postLength = max(latePost - earlyPost + 1, 1)
        let postEnergy = template[earlyPost...latePost].reduce(0) { $0 + $1 * $1 } / Double(postLength)
        let prominence = clamp01((postEnergy / max(preEnergy, 1e-20) - 1) / 5)

        let relationship: Double
        if let ecg, let ecgSamplingRate, ecgSamplingRate > 0 {
            relationship = ecgRelationship(
                source: source, sourceRate: samplingRate,
                ecg: ecg, ecgRate: ecgSamplingRate
            )
        } else {
            relationship = 0
        }
        return BCGComponentFeatures(
            beatLockedFraction: beatLocked,
            beatConsistency: clamp01(consistency),
            postQRSProminence: prominence,
            ecgRelationship: relationship,
            heartPrior: clamp01(heartPrior)
        )
    }

    /// Finds the first plausibly named ECG PNS channel. Explicitly conservative:
    /// pulse, respiration and motion channels are not treated as ECG.
    static func likelyECG(in pns: MFFSignalData?) -> (samples: [Float], samplingRate: Double)? {
        guard let pns else { return nil }
        let names = pns.channelNames ?? []
        let tokens = ["ecg", "ekg", "cardiac"]
        for index in pns.data.indices where names.indices.contains(index) {
            let name = names[index].lowercased()
            if tokens.contains(where: name.contains) {
                return (pns.data[index], pns.samplingRate)
            }
        }
        return nil
    }

    private static func heartPrior(from suggestion: ICAComponentSuggestion?) -> Double {
        guard let suggestion else { return 0 }
        if let probability = suggestion.probabilities["Heart"] { return probability }
        return suggestion.label.lowercased().hasPrefix("heart") ? suggestion.confidence : 0
    }

    private static func ecgRelationship(
        source: [Double], sourceRate: Double, ecg: [Float], ecgRate: Double
    ) -> Double {
        let duration = min(Double(source.count) / sourceRate, Double(ecg.count) / ecgRate)
        let count = min(source.count, Int(duration * sourceRate))
        guard count > 10 else { return 0 }
        var sampledECG = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let position = Double(index) * ecgRate / sourceRate
            let lower = min(max(Int(position.rounded(.down)), 0), ecg.count - 1)
            let upper = min(lower + 1, ecg.count - 1)
            let fraction = position - Double(lower)
            sampledECG[index] = Double(ecg[lower]) * (1 - fraction) + Double(ecg[upper]) * fraction
        }
        var best = 0.0
        let minimumLag = max(Int(0.04 * sourceRate), 1)
        let maximumLag = max(Int(0.60 * sourceRate), minimumLag)
        let step = max(Int(0.02 * sourceRate), 1)
        for lag in stride(from: minimumLag, through: maximumLag, by: step) where lag < count - 2 {
            best = max(best, absCorrelation(
                Array(source[lag..<count]), Array(sampledECG[0..<(count - lag)])
            ))
        }
        return clamp01(best / 0.35)
    }

    private static func absCorrelation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 1 else { return 0 }
        let leftMean = lhs.prefix(count).reduce(0, +) / Double(count)
        let rightMean = rhs.prefix(count).reduce(0, +) / Double(count)
        var covariance = 0.0, leftEnergy = 0.0, rightEnergy = 0.0
        for index in 0..<count {
            let left = lhs[index] - leftMean
            let right = rhs[index] - rightMean
            covariance += left * right
            leftEnergy += left * left
            rightEnergy += right * right
        }
        guard leftEnergy > 1e-20, rightEnergy > 1e-20 else { return 0 }
        return abs(covariance / sqrt(leftEnergy * rightEnergy))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}
