//
//  RichMetrics.swift
//  EVA Simulate
//
//  Event-detection and ERP-specific ground-truth metrics. These are separate
//  from waveform correction: finding an artifact and removing it are different
//  claims and should not share a headline number.
//

import Foundation

nonisolated struct DetectedEvent: Codable, Sendable {
    var id: String? = nil
    var timeSeconds: Double
    /// Optional confidence; larger means more likely to be an event.
    var score: Double? = nil
}

nonisolated struct DetectedEventSet: Codable, Sendable {
    var events: [DetectedEvent]
}

nonisolated struct ROCPoint: Codable, Sendable {
    var threshold: Double
    var sensitivity: Double
    var falsePositiveRate: Double
}

nonisolated struct EventDetectionScore: Codable, Sendable {
    var eventType: String
    var toleranceMilliseconds: Double
    var truthCount: Int
    var detectionCount: Int
    var truePositives: Int
    var falsePositives: Int
    var falseNegatives: Int
    var precision: Double
    var sensitivity: Double
    /// Time-bin specificity; bin width is twice the matching tolerance.
    var specificity: Double
    var specificityBinWidthMilliseconds: Double
    var f1: Double
    var falsePositivesPerMinute: Double
    var meanAbsoluteTimingErrorMilliseconds: Double
    var maximumAbsoluteTimingErrorMilliseconds: Double
    /// Present only when at least one detection supplies a confidence score.
    var rocAUC: Double?
    var roc: [ROCPoint]
}

nonisolated enum DetectionMetrics {
    static func score(
        eventType: String,
        truth: [Double],
        detected: [DetectedEvent],
        durationSeconds: Double,
        toleranceSeconds: Double
    ) -> EventDetectionScore {
        let tolerance = max(1e-9, toleranceSeconds)
        let errors = optimalTimingErrors(
            truth: truth.sorted(),
            detected: detected.map(\.timeSeconds).sorted(),
            tolerance: tolerance
        )

        let tp = errors.count
        let fp = max(0, detected.count - tp)
        let fn = max(0, truth.count - tp)
        let precision = tp + fp > 0 ? Double(tp) / Double(tp + fp) : (truth.isEmpty ? 1 : 0)
        let sensitivity = tp + fn > 0 ? Double(tp) / Double(tp + fn) : 1
        let f1 = precision + sensitivity > 0
            ? 2 * precision * sensitivity / (precision + sensitivity) : 0
        let bins = binnedClassification(
            truth: truth, detected: detected, durationSeconds: durationSeconds,
            binWidth: 2 * tolerance
        )
        let specificity = bins.trueNegatives + bins.falsePositives > 0
            ? Double(bins.trueNegatives) / Double(bins.trueNegatives + bins.falsePositives) : 1
        let roc = detected.contains(where: { $0.score != nil })
            ? rocCurve(labels: bins.labels, scores: bins.scores) : []

        return EventDetectionScore(
            eventType: eventType,
            toleranceMilliseconds: tolerance * 1000,
            truthCount: truth.count,
            detectionCount: detected.count,
            truePositives: tp,
            falsePositives: fp,
            falseNegatives: fn,
            precision: precision,
            sensitivity: sensitivity,
            specificity: specificity,
            specificityBinWidthMilliseconds: 2 * tolerance * 1000,
            f1: f1,
            falsePositivesPerMinute: durationSeconds > 0 ? Double(fp) * 60 / durationSeconds : 0,
            meanAbsoluteTimingErrorMilliseconds: errors.isEmpty
                ? 0 : errors.reduce(0, +) * 1000 / Double(errors.count),
            maximumAbsoluteTimingErrorMilliseconds: (errors.max() ?? 0) * 1000,
            rocAUC: roc.isEmpty ? nil : auc(roc),
            roc: roc
        )
    }

    /// Dynamic-programming sequence assignment: maximize the number of valid
    /// one-to-one matches first, then minimize their total timing error. A
    /// nearest-pair greedy rule can lose a valid match when events are close.
    private static func optimalTimingErrors(
        truth: [Double], detected: [Double], tolerance: Double
    ) -> [Double] {
        struct State {
            var matches: Int = 0
            var error: Double = 0
        }
        let rows = truth.count + 1
        let columns = detected.count + 1
        var states = [[State]](repeating: [State](repeating: State(), count: columns), count: rows)
        var actions = [[UInt8]](repeating: [UInt8](repeating: 0, count: columns), count: rows)
        func better(_ lhs: State, _ rhs: State) -> Bool {
            lhs.matches != rhs.matches ? lhs.matches > rhs.matches : lhs.error < rhs.error
        }
        if rows > 1, columns > 1 {
            for i in 1..<rows {
                for j in 1..<columns {
                    var best = states[i - 1][j]
                    var action: UInt8 = 1 // skip truth
                    if better(states[i][j - 1], best) {
                        best = states[i][j - 1]
                        action = 2 // skip detection
                    }
                    let error = abs(truth[i - 1] - detected[j - 1])
                    if error <= tolerance {
                        var matched = states[i - 1][j - 1]
                        matched.matches += 1
                        matched.error += error
                        if better(matched, best) {
                            best = matched
                            action = 3
                        }
                    }
                    states[i][j] = best
                    actions[i][j] = action
                }
            }
        }
        var errors: [Double] = []
        var i = truth.count
        var j = detected.count
        while i > 0, j > 0 {
            switch actions[i][j] {
            case 3:
                errors.append(abs(truth[i - 1] - detected[j - 1]))
                i -= 1
                j -= 1
            case 2: j -= 1
            default: i -= 1
            }
        }
        return errors
    }

    private static func binnedClassification(
        truth: [Double], detected: [DetectedEvent], durationSeconds: Double, binWidth: Double
    ) -> (labels: [Bool], scores: [Double], trueNegatives: Int, falsePositives: Int) {
        let count = max(1, Int(ceil(max(durationSeconds, binWidth) / binWidth)))
        var labels = [Bool](repeating: false, count: count)
        var scores = [Double](repeating: -.infinity, count: count)
        for time in truth where time >= 0 && time < durationSeconds {
            labels[min(count - 1, Int(time / binWidth))] = true
        }
        for event in detected where event.timeSeconds >= 0 && event.timeSeconds < durationSeconds {
            let bin = min(count - 1, Int(event.timeSeconds / binWidth))
            scores[bin] = max(scores[bin], event.score ?? 1)
        }
        var tn = 0
        var fp = 0
        for index in labels.indices where !labels[index] {
            if scores[index].isFinite { fp += 1 } else { tn += 1 }
        }
        return (labels, scores, tn, fp)
    }

    private static func rocCurve(labels: [Bool], scores: [Double]) -> [ROCPoint] {
        let finite = scores.filter(\.isFinite)
        let thresholds = Array(Set(finite)).sorted(by: >)
        let positives = labels.filter { $0 }.count
        let negatives = labels.count - positives
        guard positives > 0, negatives > 0 else { return [] }
        var points = [ROCPoint(
            threshold: Double.greatestFiniteMagnitude,
            sensitivity: 0, falsePositiveRate: 0
        )]
        for threshold in thresholds {
            var tp = 0
            var fp = 0
            for index in labels.indices where scores[index] >= threshold {
                if labels[index] { tp += 1 } else { fp += 1 }
            }
            points.append(ROCPoint(
                threshold: threshold,
                sensitivity: Double(tp) / Double(positives),
                falsePositiveRate: Double(fp) / Double(negatives)
            ))
        }
        points.append(ROCPoint(
            threshold: -Double.greatestFiniteMagnitude,
            sensitivity: 1, falsePositiveRate: 1
        ))
        return points
    }

    private static func auc(_ points: [ROCPoint]) -> Double {
        let sorted = points.sorted { $0.falsePositiveRate < $1.falsePositiveRate }
        guard sorted.count > 1 else { return 0 }
        var area = 0.0
        for index in 1..<sorted.count {
            let width = sorted[index].falsePositiveRate - sorted[index - 1].falsePositiveRate
            area += width * (sorted[index].sensitivity + sorted[index - 1].sensitivity) / 2
        }
        return max(0, min(1, area))
    }
}

// `ERPComponent` / `ERPComponentSet` moved to EVA/Simulation/ERPTruth.swift
// (SIM-0) so the ERP generator can emit them from the app-side core.

nonisolated struct ERPRecoveryScore: Codable, Sendable {
    var matchedCount: Int
    var missingEstimates: Int
    var extraEstimates: Int
    var amplitudeBiasMicrovolts: Double
    var amplitudeMAEMicrovolts: Double
    var amplitudeRMSEMicrovolts: Double
    var latencyBiasMilliseconds: Double
    var latencyMAEMilliseconds: Double
    var latencyRMSEMilliseconds: Double
}

nonisolated enum ERPMetrics {
    static func score(truth: [ERPComponent], estimated: [ERPComponent]) -> ERPRecoveryScore {
        let estimates = estimated.reduce(into: [String: ERPComponent]()) {
            if $0[$1.id] == nil { $0[$1.id] = $1 }
        }
        let pairs = truth.compactMap { item in estimates[item.id].map { (item, $0) } }
        let amplitudeErrors = pairs.map { $0.1.peakAmplitudeMicrovolts - $0.0.peakAmplitudeMicrovolts }
        let latencyErrors = pairs.map {
            ($0.1.peakLatencySeconds - $0.0.peakLatencySeconds) * 1000
        }
        return ERPRecoveryScore(
            matchedCount: pairs.count,
            missingEstimates: max(0, truth.count - pairs.count),
            extraEstimates: max(0, estimated.count - pairs.count),
            amplitudeBiasMicrovolts: mean(amplitudeErrors),
            amplitudeMAEMicrovolts: mean(amplitudeErrors.map(abs)),
            amplitudeRMSEMicrovolts: rms(amplitudeErrors),
            latencyBiasMilliseconds: mean(latencyErrors),
            latencyMAEMilliseconds: mean(latencyErrors.map(abs)),
            latencyRMSEMilliseconds: rms(latencyErrors)
        )
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func rms(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }
}
