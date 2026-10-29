// Copyright-free US Government work; see LICENSE.
import Foundation

nonisolated enum SweepEvaluationMode: String, Codable, CaseIterable, Sendable {
    case none, average, reject
    var title: String {
        switch self { case .none: return "Generate only"; case .average: return "Generate + Evaluate: ERP average"; case .reject: return "Generate + Evaluate: reject + average" }
    }
}
nonisolated struct SweepEvaluationOptions: Codable, Sendable {
    var mode: SweepEvaluationMode = .none
    var preSeconds: Double = 0.2
    var postSeconds: Double = 0.8
    var peakStartSeconds: Double = 0.05
    var peakEndSeconds: Double = 0.7
    var peakChannel: Int = 1 // Human-facing, one-based; fixed across all cells.
    var rejectionMicrovolts: Double = 120
    func validate(rate: Double? = nil, channels: Int? = nil) throws {
        guard [preSeconds, postSeconds, peakStartSeconds, peakEndSeconds, rejectionMicrovolts].allSatisfy(\.isFinite) else {
            throw SimulateError.usage("Evaluation settings must be finite.")
        }
        guard mode != .none else { return }
        guard [preSeconds, postSeconds, peakStartSeconds, peakEndSeconds, rejectionMicrovolts].allSatisfy(\.isFinite),
              preSeconds > 0, postSeconds > 0, peakStartSeconds >= 0, peakEndSeconds > peakStartSeconds,
              peakEndSeconds <= postSeconds, rejectionMicrovolts > 0, peakChannel >= 1 else {
            throw SimulateError.usage("Evaluation needs positive epoch lengths/rejection threshold and an ordered peak window inside the post-stimulus epoch.")
        }
        if let rate {
            guard preSeconds * rate >= 1, (peakEndSeconds - peakStartSeconds) * rate >= 1,
                  (preSeconds + postSeconds) * rate < 10_000_000 else { throw SimulateError.usage("Evaluation windows must contain samples and be reasonably sized at every swept rate.") }
        }
        if let channels, peakChannel > channels { throw SimulateError.usage("Evaluation channel is outside the recording.") }
    }
}

nonisolated struct SweepConditionEvaluation: Codable, Sendable {
    var conditionID: String
    var conditionName: String
    var scheduled: Int
    var candidates: Int
    var retained: Int
    var status: String
    var waveformRMSE: Double? = nil
    var correlation: Double? = nil
    var peakAmplitudeError: Double? = nil
    var peakLatencyErrorMS: Double? = nil
    var cleanPeakAmplitude: Double? = nil
    var measuredPeakAmplitude: Double? = nil
    var cleanPeakLatencyMS: Double? = nil
    var measuredPeakLatencyMS: Double? = nil
    var retainedFraction: Double? { candidates > 0 ? Double(retained) / Double(candidates) : nil }
}

/// Baseline-corrected, unfiltered epochs. Trial selection uses noisy data only.
/// The reference averages ALL complete clean epochs, including omitted trials,
/// background EEG and overlap; rejecting trials can therefore introduce error.
/// Metrics describe recovery of the clean recording average, not isolated peaks
/// or a claim that generation recipes equal TrialsView classifications.
nonisolated enum SweepEvaluation {
    static func evaluate(clean: [[Double]], noisy: [[Double]], rate: Double,
                         trials: [ERPTrialTruth], conditions: [(String, String)],
                         options: SweepEvaluationOptions) throws -> [SweepConditionEvaluation] {
        guard options.mode != .none else { return [] }
        try options.validate(rate: rate, channels: clean.count)
        guard !clean.isEmpty, clean.count == noisy.count,
              let count = clean.first?.count, count > 0,
              clean.allSatisfy({ $0.count == count }), noisy.allSatisfy({ $0.count == count }),
              clean.allSatisfy({ $0.allSatisfy(\.isFinite) }), noisy.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw SimulateError.usage("Evaluation needs matching finite clean/noisy recordings.")
        }
        let pre = Int((options.preSeconds * rate).rounded()), post = Int((options.postSeconds * rate).rounded())
        let length = pre + post
        let peakStart = pre + Int((options.peakStartSeconds * rate).rounded())
        let peakEnd = min(length, pre + Int((options.peakEndSeconds * rate).rounded()))
        var results: [SweepConditionEvaluation] = []
        for (id, name) in conditions {
            let selected = trials.filter { $0.condition == id }
            var reference = Array(repeating: Array(repeating: 0.0, count: length), count: clean.count)
            var estimate = reference
            var candidates = 0, retained = 0
            for trial in selected {
                let start = Int((trial.onsetSeconds * rate).rounded()) - pre
                guard start >= 0, start + length <= count else { continue }
                candidates += 1
                let accepted = options.mode != .reject || noisy.allSatisfy { channel in
                    let epoch = channel[start..<(start + length)]
                    return (epoch.max()! - epoch.min()!) <= options.rejectionMicrovolts
                }
                if accepted { retained += 1 }
                for c in clean.indices {
                    let base = clean[c][start..<(start + pre)].reduce(0, +) / Double(pre)
                    let observedBase = accepted ? noisy[c][start..<(start + pre)].reduce(0, +) / Double(pre) : 0
                    for t in 0..<length {
                        reference[c][t] += clean[c][start + t] - base
                        if accepted { estimate[c][t] += noisy[c][start + t] - observedBase }
                    }
                }
            }
            var result = SweepConditionEvaluation(conditionID: id, conditionName: name, scheduled: selected.count,
                candidates: candidates, retained: retained, status: candidates == 0 ? "no-complete-epochs" : (retained == 0 ? "all-rejected" : "ok"))
            guard retained > 0 else { results.append(result); continue }
            for c in clean.indices { for t in 0..<length {
                reference[c][t] /= Double(candidates); estimate[c][t] /= Double(retained)
            } }
            // Waveform metrics cover every EEG channel and the full post-stimulus window.
            let a = reference.flatMap { Array($0[pre..<length]) }
            let b = estimate.flatMap { Array($0[pre..<length]) }
            result.waveformRMSE = sqrt(zip(a, b).reduce(0) { $0 + pow($1.0 - $1.1, 2) } / Double(a.count))
            let am = a.reduce(0, +) / Double(a.count), bm = b.reduce(0, +) / Double(b.count)
            var aa = 0.0, bb = 0.0, ab = 0.0
            for i in a.indices { let x = a[i] - am, y = b[i] - bm; aa += x*x; bb += y*y; ab += x*y }
            if aa > 1e-20, bb > 1e-20 { result.correlation = max(-1, min(1, ab / sqrt(aa * bb))) }
            let c = options.peakChannel - 1
            func peak(_ x: [Double]) -> Int { (peakStart..<peakEnd).max { abs(x[$0]) < abs(x[$1]) } ?? peakStart }
            let ai = peak(reference[c]), bi = peak(estimate[c])
            // A zero reference has no identifiable peak; don't fabricate a latency.
            if abs(reference[c][ai]) > 1e-10 {
                result.cleanPeakAmplitude = reference[c][ai]; result.measuredPeakAmplitude = estimate[c][bi]
                result.peakAmplitudeError = estimate[c][bi] - reference[c][ai]
                result.cleanPeakLatencyMS = Double(ai - pre) / rate * 1000
                if abs(estimate[c][bi]) > 1e-10 {
                    result.measuredPeakLatencyMS = Double(bi - pre) / rate * 1000
                    result.peakLatencyErrorMS = Double(bi - ai) / rate * 1000
                }
            }
            results.append(result)
        }
        return results
    }
}

nonisolated enum SweepMetric: String, CaseIterable, Identifiable, Sendable {
    case snr, rmse, correlation, amplitude, latency, retained, cleanAmplitude, measuredAmplitude, cleanLatency, measuredLatency
    var id: String { rawValue }
    var title: String {
        switch self {
        case .snr: return "Uncorrected broadband SNR"
        case .rmse: return "ERP waveform RMSE (µV)"
        case .correlation: return "ERP waveform correlation"
        case .amplitude: return "Peak amplitude error (µV)"
        case .latency: return "Peak latency error (ms)"
        case .retained: return "Retained trial fraction"
        case .cleanAmplitude: return "Clean peak amplitude (µV)"
        case .measuredAmplitude: return "Measured peak amplitude (µV)"
        case .cleanLatency: return "Clean peak latency (ms)"
        case .measuredLatency: return "Measured peak latency (ms)"
        }
    }
    func value(row: SimulationSweepRow, condition: String) -> Double? {
        if self == .snr { return row.uncorrectedSNR }
        guard let e = row.evaluations.first(where: { $0.conditionID == condition }) else { return nil }
        switch self {
        case .rmse: return e.waveformRMSE
        case .correlation: return e.correlation
        case .amplitude: return e.peakAmplitudeError
        case .latency: return e.peakLatencyErrorMS
        case .retained: return e.retainedFraction
        case .cleanAmplitude: return e.cleanPeakAmplitude
        case .measuredAmplitude: return e.measuredPeakAmplitude
        case .cleanLatency: return e.cleanPeakLatencyMS
        case .measuredLatency: return e.measuredPeakLatencyMS
        case .snr: return row.uncorrectedSNR
        }
    }
}
nonisolated struct SweepAggregate: Identifiable, Sendable {
    var id: String { "\(value)/\(secondValue.map(String.init(describing:)) ?? "none")/\(conditionID)/\(metric.rawValue)" }
    var value: Double
    var secondValue: Double?
    var conditionID: String
    var metric: SweepMetric
    var count: Int
    var mean: Double
    var sd: Double?
}
extension SimulationSweepReport {
    func aggregates(metric: SweepMetric, condition: String) -> [SweepAggregate] {
        var groups: [String: [SimulationSweepRow]] = [:]
        for row in rows { groups["\(row.value)/\(row.secondValue.map(String.init(describing:)) ?? "none")", default: []].append(row) }
        return groups.values.compactMap { rows in
            let values = rows.compactMap { metric.value(row: $0, condition: condition) }.filter(\.isFinite)
            guard let first = rows.first, !values.isEmpty else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            let sd = values.count > 1 ? sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)) : nil
            return SweepAggregate(value: first.value, secondValue: first.secondValue, conditionID: condition,
                                  metric: metric, count: values.count, mean: mean, sd: sd)
        }.sorted { ($0.secondValue ?? 0, $0.value) < ($1.secondValue ?? 0, $1.value) }
    }
}
