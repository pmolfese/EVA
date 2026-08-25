//
//  ICAComponentLabellerBenchmark.swift
//  EVA
//
//  Per-class evaluation of component suggestions against graded simulator truth.
//  A recovered ICA map can legitimately overlap several generating subspaces,
//  so truth is a distribution derived from squared topographic correlations,
//  not a forced one-hot label.
//

import Foundation

nonisolated struct ICAComponentTruthClass: Sendable {
    var label: String
    var topographies: [[Double]]
}

nonisolated struct ICAComponentBenchmarkRecord: Codable, Sendable {
    var componentIndex: Int
    var predictedClass: String
    var confidence: Double
    var truthMembership: [String: Double]
}

nonisolated struct ICAClassBenchmarkMetrics: Codable, Sendable {
    var support: Double
    var truePositiveWeight: Double
    var precision: Double
    var recall: Double
    var f1: Double
}

nonisolated struct ICALabellerBenchmarkResult: Codable, Sendable {
    var schemaVersion = 1
    var labeller: String
    var componentCount: Int
    var classifiedCount: Int
    var macroF1: Double
    var perClass: [String: ICAClassBenchmarkMetrics]
    var components: [ICAComponentBenchmarkRecord]
}

nonisolated enum ICAComponentLabellerBenchmark {
    static let knownClasses = [
        "Brain", "Muscle", "Eye", "Heart", "Line Noise", "Channel Noise"
    ]

    static func evaluate(
        labeller: String,
        decomposition: ICADecomposition,
        suggestions: [Int: ICAComponentSuggestion],
        truthClasses: [ICAComponentTruthClass]
    ) -> ICALabellerBenchmarkResult {
        let labels = knownClasses + ["Other"]
        var support = Dictionary(uniqueKeysWithValues: labels.map { ($0, 0.0) })
        var truePositive = Dictionary(uniqueKeysWithValues: labels.map { ($0, 0.0) })
        var predictedCount = Dictionary(uniqueKeysWithValues: labels.map { ($0, 0.0) })
        var records: [ICAComponentBenchmarkRecord] = []

        for component in 0..<decomposition.componentCount {
            let map = decomposition.componentMaps.indices.contains(component)
                ? decomposition.componentMaps[component] : []
            let membership = gradedMembership(map: map, truthClasses: truthClasses)
            let suggestion = suggestions[component]
            let predicted = canonicalClass(from: suggestion?.label) ?? "Other"
            for label in labels { support[label, default: 0] += membership[label, default: 0] }
            predictedCount[predicted, default: 0] += 1
            truePositive[predicted, default: 0] += membership[predicted, default: 0]
            records.append(ICAComponentBenchmarkRecord(
                componentIndex: component,
                predictedClass: predicted,
                confidence: suggestion?.confidence ?? 0,
                truthMembership: membership
            ))
        }

        var perClass: [String: ICAClassBenchmarkMetrics] = [:]
        for label in labels {
            let classSupport = support[label, default: 0]
            let tp = truePositive[label, default: 0]
            let predicted = predictedCount[label, default: 0]
            let precision = predicted > 0 ? tp / predicted : 0
            let recall = classSupport > 0 ? tp / classSupport : 0
            let f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
            perClass[label] = ICAClassBenchmarkMetrics(
                support: classSupport, truePositiveWeight: tp,
                precision: precision, recall: recall, f1: f1
            )
        }
        let supportedKnown = knownClasses.compactMap { label -> Double? in
            guard (perClass[label]?.support ?? 0) > 1e-9 else { return nil }
            return perClass[label]?.f1
        }
        let macroF1 = supportedKnown.isEmpty
            ? 0 : supportedKnown.reduce(0, +) / Double(supportedKnown.count)
        return ICALabellerBenchmarkResult(
            labeller: labeller,
            componentCount: decomposition.componentCount,
            classifiedCount: suggestions.count,
            macroF1: macroF1,
            perClass: perClass,
            components: records
        )
    }

    static func gradedMembership(
        map: [Double], truthClasses: [ICAComponentTruthClass]
    ) -> [String: Double] {
        var scores = Dictionary(uniqueKeysWithValues: knownClasses.map { ($0, 0.0) })
        for truthClass in truthClasses where knownClasses.contains(truthClass.label) {
            let best = truthClass.topographies.map {
                let correlation = absoluteCorrelation(map, $0)
                return correlation * correlation
            }.max() ?? 0
            scores[truthClass.label] = max(scores[truthClass.label, default: 0], best)
        }
        let strongest = scores.values.max() ?? 0
        scores["Other"] = max(0, 1 - strongest)
        let total = scores.values.reduce(0, +)
        guard total > 1e-12 else {
            return Dictionary(uniqueKeysWithValues:
                (knownClasses + ["Other"]).map { ($0, $0 == "Other" ? 1 : 0) })
        }
        return scores.mapValues { $0 / total }
    }

    /// Continuous BCG target used by roadmap 5.4. Unlike the general Tier 8
    /// benchmark's best-pair correlation, this measures projection onto the
    /// complete BCG and neural spans, so a component containing two recovered
    /// BCG generators is not penalized for failing to resemble either one alone.
    static func bcgSubspaceMembership(
        map: [Double],
        bcgTopographies: [[Double]],
        neuralTopographies: [[Double]]
    ) -> Double {
        let bcgEnergy = projectionEnergy(of: map, onto: bcgTopographies)
        let neuralEnergy = projectionEnergy(of: map, onto: neuralTopographies)
        let total = bcgEnergy + neuralEnergy
        return total > 1e-20 ? min(max(bcgEnergy / total, 0), 1) : 0
    }

    static func canonicalClass(from label: String?) -> String? {
        guard let label else { return nil }
        return (knownClasses + ["Other"])
            .sorted { $0.count > $1.count }
            .first { label.caseInsensitiveCompare($0) == .orderedSame
                || label.lowercased().hasPrefix($0.lowercased() + " ") }
    }

    private static func absoluteCorrelation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 1 else { return 0 }
        let leftMean = lhs.prefix(count).reduce(0, +) / Double(count)
        let rightMean = rhs.prefix(count).reduce(0, +) / Double(count)
        var covariance = 0.0
        var leftEnergy = 0.0
        var rightEnergy = 0.0
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


    private static func projectionEnergy(of vector: [Double], onto candidates: [[Double]]) -> Double {
        guard !vector.isEmpty else { return 0 }
        let count = vector.count
        let mean = vector.reduce(0, +) / Double(count)
        let centered = vector.map { $0 - mean }
        let totalEnergy = centered.reduce(0) { $0 + $1 * $1 }
        guard totalEnergy > 1e-20 else { return 0 }

        // Modified Gram-Schmidt gives an orthonormal basis for the supplied
        // topographic span and naturally drops redundant/correlated generators.
        var basis: [[Double]] = []
        for candidate in candidates where candidate.count >= count {
            let candidateMean = candidate.prefix(count).reduce(0, +) / Double(count)
            var residual = candidate.prefix(count).map { $0 - candidateMean }
            for direction in basis {
                let dot = zip(residual, direction).reduce(0) { $0 + $1.0 * $1.1 }
                for index in residual.indices { residual[index] -= dot * direction[index] }
            }
            let norm = sqrt(residual.reduce(0) { $0 + $1 * $1 })
            guard norm > 1e-9 else { continue }
            basis.append(residual.map { $0 / norm })
        }
        let captured = basis.reduce(0.0) { total, direction in
            let dot = zip(centered, direction).reduce(0) { $0 + $1.0 * $1.1 }
            return total + dot * dot
        }
        return min(max(captured / totalEnergy, 0), 1)
    }
}
