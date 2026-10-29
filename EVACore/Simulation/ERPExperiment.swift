// Copyright-free US Government work; see LICENSE.
// Editable Gaussian ERP complexes, arbitrary conditions, and reproducible trial recipes.
import Foundation

nonisolated struct ERPWaveformPeak: Codable, Sendable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var latencySeconds: Double = 0.3
    var amplitudeMicrovolts: Double = 8
    /// Gaussian standard deviation, not FWHM.
    var widthSeconds: Double = 0.06
    var occurrenceFraction: Double = 1

    func value(at seconds: Double) -> Double {
        guard seconds.isFinite, seconds >= 0, widthSeconds.isFinite, widthSeconds > 0,
              latencySeconds.isFinite, amplitudeMicrovolts.isFinite else { return 0 }
        return amplitudeMicrovolts * exp(-0.5 * pow((seconds - latencySeconds) / widthSeconds, 2))
    }
}

nonisolated enum ERPTrialRecipe: String, Codable, Sendable, CaseIterable {
    case typical, attenuated, inverted, divergent, omitted
}

nonisolated struct ERPTrialRecipeMix: Codable, Sendable, Equatable {
    var attenuatedFraction: Double = 0
    var invertedFraction: Double = 0
    var divergentFraction: Double = 0
    var attenuatedGain: Double = 0.3
    var divergentLatencyRangeSeconds: Double = 0.08
    var divergentWidthMinimum: Double = 0.6
    var divergentWidthMaximum: Double = 1.6
    var typicalFraction: Double { 1 - attenuatedFraction - invertedFraction - divergentFraction }
}

nonisolated struct ERPConditionConfig: Codable, Sendable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = "Condition"
    var eventCode: String = "C001"
    var fraction: Double = 1
    var peaks: [ERPWaveformPeak] = [ERPWaveformPeak()]
    var recipes = ERPTrialRecipeMix()

    func value(at seconds: Double) -> Double { peaks.reduce(0) { $0 + $1.value(at: seconds) } }
}

nonisolated enum ERPAddedNoiseKind: String, Codable, Sendable, CaseIterable {
    case white, smoothed
}

nonisolated struct ERPExperimentConfig: Codable, Sendable, Equatable {
    var conditions: [ERPConditionConfig] = [
        ERPConditionConfig(id: "standard", name: "Frequent", eventCode: "std", fraction: 0.8,
                           peaks: [ERPWaveformPeak(id: "p1", amplitudeMicrovolts: 4)]),
        ERPConditionConfig(id: "target", name: "Target", eventCode: "targ", fraction: 0.2,
                           peaks: [ERPWaveformPeak(id: "p1")])
    ]
    var independentLatencyJitterSDSeconds: Double = 0
    var widthJitterFraction: Double = 0
    /// Continuous, independent sensor noise, applied only to the noisy recording.
    var addedNoiseRMSMicrovolts: Double = 0
    var addedNoiseKind: ERPAddedNoiseKind = .white
    /// Nil selects the first condition. Optional fields preserve earlier scenarios.
    var groupReferenceConditionID: String? = nil
    var groupContrasts: [ERPGroupContrast]? = nil

    var referenceConditionID: String { groupReferenceConditionID ?? conditions.first?.id ?? "" }
    var resolvedGroupContrasts: [ERPGroupContrast] {
        groupContrasts ?? conditions.filter { $0.id != referenceConditionID }.map {
            ERPGroupContrast(id: "\($0.id)-minus-\(referenceConditionID)",
                             weights: [$0.id: 1, referenceConditionID: -1])
        }
    }

    /// Import only the legacy single Gaussian: no spatial or measured-template
    /// information is discarded implicitly when opening existing scenarios.
    static func editing(_ erp: ERPConfig) -> ERPExperimentConfig? {
        if let experiment = erp.experiment { return experiment }
        guard erp.components == nil, erp.waveform == .gaussian,
              erp.latencySkew == 0, erp.latencyAmplitudeCorrelation == 0 else { return nil }
        var result = ERPExperimentConfig()
        for i in result.conditions.indices {
            result.conditions[i].fraction = i == 0 ? 1 - erp.targetFraction : erp.targetFraction
            result.conditions[i].peaks = [ERPWaveformPeak(
                id: "p1", latencySeconds: erp.peakLatencySeconds,
                amplitudeMicrovolts: erp.targetAmplitudeMicrovolts * (i == 0 ? erp.standardAmplitudeRatio : 1),
                widthSeconds: erp.widthSeconds)]
        }
        return result
    }

    func validate(erp: ERPConfig) throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw SimulateError.usage(message) }
        }
        func nonnegative(_ x: Double) -> Bool { x.isFinite && x >= 0 }
        func fraction(_ x: Double) -> Bool { x.isFinite && (0...1).contains(x) }
        try require(erp.trialCount > 0 && erp.trialCount <= 100_000, "ERP trial count must be 1…100,000.")
        try require(erp.latencySkew == 0 && erp.latencyAmplitudeCorrelation == 0,
                    "Editable experiments require zero legacy latency skew/correlation.")
        try require(nonnegative(erp.startSeconds) && erp.interStimulusIntervalSeconds.isFinite
                    && nonnegative(erp.interStimulusJitterSeconds)
                    && erp.interStimulusIntervalSeconds > erp.interStimulusJitterSeconds,
                    "Mean ISI must exceed its uniform ± range; start must be non-negative.")
        try require(nonnegative(erp.latencyJitterSDSeconds) && nonnegative(erp.amplitudeJitterFraction)
                    && fraction(erp.omissionRate), "ERP jitter must be non-negative; omission fraction must be 0…1.")
        try require(nonnegative(independentLatencyJitterSDSeconds) && nonnegative(widthJitterFraction)
                    && nonnegative(addedNoiseRMSMicrovolts), "Peak jitter, width variation, and added noise must be non-negative.")
        try require(!conditions.isEmpty, "Add at least one ERP condition.")
        try require(conditions.contains { $0.id == referenceConditionID }, "Group reference must identify an existing ERP condition.")
        let contrasts = resolvedGroupContrasts
        try require(Set(contrasts.map(\.id)).count == contrasts.count && contrasts.allSatisfy { !$0.id.trimmingCharacters(in: .whitespaces).isEmpty },
                    "Group contrast IDs must be unique and non-empty.")
        for contrast in contrasts {
            let weights = Array(contrast.weights.values)
            let norm = weights.reduce(0) { $0 + abs($1) }
            try require(contrast.weights.keys.allSatisfy { id in conditions.contains { $0.id == id } }
                        && weights.allSatisfy(\.isFinite) && norm.isFinite && norm > 0
                        && abs(weights.reduce(0, +)) <= 1e-9 * norm,
                        "Contrast '\(contrast.id)' needs known conditions and finite, nonzero weights summing to zero.")
        }
        try require(Set(conditions.map(\.id)).count == conditions.count
                    && conditions.allSatisfy { !$0.id.isEmpty }, "Condition IDs must be unique and non-empty.")
        let names = conditions.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        try require(!names.contains("") && Set(names).count == names.count, "Condition names must be unique and non-empty.")
        let codes = conditions.map(\.eventCode)
        let reserved: Set<String> = ["trev", "qrsd", "qrst", "blnk", "eyem", "emg", "chew", "swal", "move", "swet"]
        try require(Set(codes.map { $0.lowercased() }).count == codes.count && codes.allSatisfy {
            (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            } && !reserved.contains($0.lowercased())
        }, "Event codes must be unique, 1–4 ASCII letters/digits, and distinct from artifact codes.")
        try require(conditions.allSatisfy { fraction($0.fraction) }
                    && abs(conditions.reduce(0) { $0 + $1.fraction } - 1) < 1e-8,
                    "Condition trial percentages must total 100%.")
        for condition in conditions {
            try require(!condition.peaks.isEmpty && Set(condition.peaks.map(\.id)).count == condition.peaks.count,
                        "Each condition needs at least one peak with a unique ID.")
            for peak in condition.peaks {
                try require(peak.latencySeconds.isFinite && peak.latencySeconds > 0
                            && peak.widthSeconds.isFinite && peak.widthSeconds > 0
                            && peak.amplitudeMicrovolts.isFinite && fraction(peak.occurrenceFraction),
                            "Peak latency/width must be positive, amplitude finite, and occurrence 0…100%.")
            }
            let mix = condition.recipes
            try require(fraction(mix.attenuatedFraction) && fraction(mix.invertedFraction)
                        && fraction(mix.divergentFraction) && mix.typicalFraction >= -1e-8,
                        "Trial recipe percentages in \(condition.name) must not exceed 100%.")
            try require(fraction(mix.attenuatedGain) && nonnegative(mix.divergentLatencyRangeSeconds)
                        && mix.divergentWidthMinimum.isFinite && mix.divergentWidthMinimum > 0
                        && mix.divergentWidthMaximum.isFinite && mix.divergentWidthMaximum >= mix.divergentWidthMinimum,
                        "Recipe gain and divergent timing/width ranges are invalid in \(condition.name).")
        }
    }
}

nonisolated struct ERPRealizedPeak: Codable, Sendable {
    var id: String
    var latencySeconds: Double
    var amplitudeMicrovolts: Double
    var widthSeconds: Double
    var present: Bool

    func value(at seconds: Double) -> Double {
        guard seconds >= 0, present else { return 0 }
        return amplitudeMicrovolts * exp(-0.5 * pow((seconds - latencySeconds) / widthSeconds, 2))
    }
}

nonisolated struct ERPExperimentTrial: Sendable {
    var conditionIndex: Int
    var onsetSeconds: Double
    var recipe: ERPTrialRecipe
    var peaks: [ERPRealizedPeak]
    var windowSeconds: Double { peaks.map { $0.latencySeconds + 6 * $0.widthSeconds }.max() ?? 0 }
    func value(at seconds: Double) -> Double { peaks.reduce(0) { $0 + $1.value(at: seconds) } }
}

nonisolated enum ERPExperimentSampler {
    /// FNV-1a identity + SplitMix64 finalizer; never Swift's randomized Hasher.
    /// Factor, condition, and peak streams are independent of display order.
    static func seed(_ base: UInt64, _ identity: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        value = (value ^ base) &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    /// Largest remainder, with stable index tie-breaking. Fractions are validated
    /// by callers; normalization absorbs floating-point sum error only.
    static func counts(total: Int, fractions: [Double]) -> [Int] {
        let sum = fractions.reduce(0, +)
        guard total > 0, sum.isFinite, sum > 0, fractions.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return fractions.map { _ in 0 }
        }
        let raw = fractions.map { Double(total) * $0 / sum }
        var result = raw.map { Int($0.rounded(.down)) }
        let order = raw.indices.sorted {
            let a = raw[$0] - Double(result[$0]), b = raw[$1] - Double(result[$1])
            return a == b ? $0 < $1 : a > b
        }
        for i in order.prefix(max(0, total - result.reduce(0, +))) { result[i] += 1 }
        return result
    }

    static func shuffled<T>(_ values: [T], seed: UInt64) -> [T] {
        var values = values, random = GaussianSource(seed: seed)
        guard values.count > 1 else { return values }
        for i in stride(from: values.count - 1, through: 1, by: -1) {
            let j = min(i, Int(random.uniform() * Double(i + 1)))
            values.swapAt(i, j)
        }
        return values
    }

    static func trials(erp: ERPConfig, seed base: UInt64) throws -> [ERPExperimentTrial] {
        guard let design = erp.experiment else { return [] }
        try design.validate(erp: erp)
        let allocation = counts(total: erp.trialCount, fractions: design.conditions.map(\.fraction))
        let order = shuffled(allocation.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element) },
                             seed: seed(base, "experiment/conditions"))
        var recipes = [ERPTrialRecipe](repeating: .typical, count: erp.trialCount)
        var peakPresence = [[Set<Int>]]()
        for (c, condition) in design.conditions.enumerated() {
            let indices = order.indices.filter { order[$0] == c }
            let omissionCount = Int((Double(indices.count) * erp.omissionRate).rounded())
            let mix = condition.recipes
            let recipeCounts = counts(total: indices.count - omissionCount,
                                      fractions: [max(0, mix.typicalFraction), mix.attenuatedFraction,
                                                  mix.invertedFraction, mix.divergentFraction])
            let kinds: [ERPTrialRecipe] = [.typical, .attenuated, .inverted, .divergent]
            let assigned = shuffled(recipeCounts.enumerated().flatMap { Array(repeating: kinds[$0.offset], count: $0.element) }
                                    + Array(repeating: .omitted, count: omissionCount),
                                    seed: seed(base, "recipes/\(condition.id)"))
            for (i, index) in indices.enumerated() { recipes[index] = assigned[i] }
            let responding = indices.filter { recipes[$0] != .omitted }
            peakPresence.append(condition.peaks.map { peak in
                let count = Int((Double(responding.count) * peak.occurrenceFraction).rounded())
                return Set(shuffled(responding, seed: seed(base, "occurrence/\(condition.id)/\(peak.id)")).prefix(count))
            })
        }
        var onsetRandom = GaussianSource(seed: seed(base, "experiment/isi"))
        var onset = erp.startSeconds
        var result: [ERPExperimentTrial] = []
        for (index, c) in order.enumerated() {
            if index > 0 {
                onset += erp.interStimulusIntervalSeconds + (2 * onsetRandom.uniform() - 1) * erp.interStimulusJitterSeconds
            }
            let condition = design.conditions[c], recipe = recipes[index], mix = condition.recipes
            var latency = GaussianSource(seed: seed(base, "latency/\(index)"))
            var amplitude = GaussianSource(seed: seed(base, "amplitude/\(index)"))
            var width = GaussianSource(seed: seed(base, "width/\(index)"))
            var divergence = GaussianSource(seed: seed(base, "divergence/\(index)"))
            let shift = erp.latencyJitterSDSeconds * latency.gaussian()
                + (recipe == .divergent ? (2 * divergence.uniform() - 1) * mix.divergentLatencyRangeSeconds : 0)
            let gain = max(0, 1 + erp.amplitudeJitterFraction * amplitude.gaussian())
                * (recipe == .inverted ? -1 : recipe == .attenuated ? mix.attenuatedGain : 1)
            let stretch = max(0.05, 1 + design.widthJitterFraction * width.gaussian())
                * (recipe == .divergent ? mix.divergentWidthMinimum
                   + divergence.uniform() * (mix.divergentWidthMaximum - mix.divergentWidthMinimum) : 1)
            let peaks = condition.peaks.enumerated().map { p, peak in
                var independent = GaussianSource(seed: seed(base, "peak-latency/\(condition.id)/\(peak.id)/\(index)"))
                let present = peakPresence[c][p].contains(index)
                return ERPRealizedPeak(id: peak.id,
                    latencySeconds: max(0.005, peak.latencySeconds + shift
                                        + design.independentLatencyJitterSDSeconds * independent.gaussian()),
                    amplitudeMicrovolts: present ? peak.amplitudeMicrovolts * gain : 0,
                    widthSeconds: peak.widthSeconds * stretch, present: present)
            }
            result.append(ERPExperimentTrial(conditionIndex: c, onsetSeconds: onset, recipe: recipe, peaks: peaks))
        }
        guard result.allSatisfy({ $0.onsetSeconds.isFinite && $0.windowSeconds.isFinite
            && $0.peaks.allSatisfy { $0.amplitudeMicrovolts.isFinite && $0.latencySeconds.isFinite && $0.widthSeconds.isFinite } }) else {
            throw SimulateError.usage("ERP settings exceed the finite signal range.")
        }
        return result
    }

    static func requiredDuration(_ trials: [ERPExperimentTrial]) -> Double {
        trials.map { $0.onsetSeconds + $0.windowSeconds }.max() ?? 0
    }

    static func noise(count: Int, samplingRate: Double, rms: Double, kind: ERPAddedNoiseKind, seed: UInt64) -> [Double] {
        guard rms > 0 else { return [Double](repeating: 0, count: count) }
        var random = GaussianSource(seed: seed)
        // 20 ms time constant, stationary initialization, unit marginal variance.
        let a = exp(-1 / (0.02 * samplingRate)), b = sqrt(1 - a * a)
        var previous = random.gaussian()
        return (0..<count).map { _ in
            let z = random.gaussian()
            previous = a * previous + b * z
            return rms * (kind == .white ? z : previous)
        }
    }

    static func addSensorNoise(to channels: inout [[Double]], config: SimulationConfig) {
        guard let design = config.erp?.experiment, design.addedNoiseRMSMicrovolts > 0 else { return }
        for c in channels.indices {
            let values = noise(count: channels[c].count, samplingRate: config.samplingRate,
                               rms: design.addedNoiseRMSMicrovolts, kind: design.addedNoiseKind,
                               seed: seed(config.seed, "sensor-noise/\(c)"))
            for i in values.indices { channels[c][i] += values[i] }
        }
    }
}
