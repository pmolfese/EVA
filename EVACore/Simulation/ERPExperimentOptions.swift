// Copyright-free US Government work; see LICENSE.
// Shared, testable parser for repeatable CLI experiment definitions.
import Foundation

nonisolated enum ERPExperimentOptions {
    static let repeatedKeys: Set<String> = ["erp-condition", "erp-peak", "erp-mixture", "erp-recipe", "erp-contrast"]
    static let keys = repeatedKeys.union(["erp-experiment", "erp-reference", "erp-peak-jitter",
                                         "erp-width-jitter", "erp-noise", "erp-noise-kind", "erp-fit-duration"])
    static let legacyShapeKeys: Set<String> = ["erp-target-fraction", "erp-latency", "erp-amplitude",
        "erp-standard-ratio", "erp-waveform", "erp-width", "erp-template", "erp-template-rate",
        "erp-latency-skew", "erp-latency-amplitude-correlation"]

    static func fields(_ raw: String, counts: ClosedRange<Int>, flag: String) throws -> [String] {
        let values = raw.split(separator: ":", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard counts.contains(values.count), values.allSatisfy({ !$0.isEmpty }) else {
            throw SimulateError.usage("Invalid --\(flag) '\(raw)'; use the colon-separated format in --help.")
        }
        return values
    }
    static func number(_ raw: String, flag: String) throws -> Double {
        guard let value = Double(raw), value.isFinite else {
            throw SimulateError.usage("--\(flag) expects finite numeric values; got '\(raw)'.")
        }
        return value
    }
    static func parseWeights(_ raw: String) throws -> [String: Double] {
        var result: [String: Double] = [:]
        for token in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = token.split(separator: "=", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, result[pair[0]] == nil else {
                throw SimulateError.usage("Contrast weights must be unique condition=weight pairs separated by commas.")
            }
            result[pair[0]] = try number(pair[1], flag: "erp-contrast")
        }
        return result
    }

    /// Repeatable conditions replace the condition list; repeatable peaks replace
    /// the peaks of each named condition. Unmentioned conditions keep their peaks.
    static func apply(_ options: [String: [String]], to erp: inout ERPConfig) throws {
        guard !options.isEmpty else { return }
        for key in options.keys {
            guard keys.contains(key) else { throw SimulateError.usage("Unknown experiment option --\(key).") }
            if !repeatedKeys.contains(key), options[key]!.count != 1 {
                throw SimulateError.usage("Specify --\(key) only once.")
            }
        }
        for flag in ["erp-experiment", "erp-fit-duration"] {
            if let value = options[flag]?.first, value != "true" {
                throw SimulateError.usage("--\(flag) is a switch and takes no value.")
            }
        }
        let explicitConditions = options["erp-condition"] ?? []
        var design: ERPExperimentConfig
        if let existing = erp.experiment { design = existing }
        else if !explicitConditions.isEmpty { design = ERPExperimentConfig() }
        else if let converted = ERPExperimentConfig.editing(erp) { design = converted }
        else { throw SimulateError.usage("Cannot convert placed/measured/biphasic ERPs implicitly. Supply --erp-condition and --erp-peak to replace the design.") }
        if !explicitConditions.isEmpty {
            design.conditions = try explicitConditions.map { raw in
                let f = try fields(raw, counts: 4...4, flag: "erp-condition")
                return ERPConditionConfig(id: f[0], name: f[1], eventCode: f[2],
                    fraction: try number(f[3], flag: "erp-condition"), peaks: [ERPWaveformPeak(id: "p1")])
            }
            design.groupReferenceConditionID = nil
            design.groupContrasts = nil
        }
        func conditionIndex(_ id: String) throws -> Int {
            guard let index = design.conditions.firstIndex(where: { $0.id == id }) else {
                throw SimulateError.usage("Unknown ERP condition '\(id)'; use its ID from --erp-condition.")
            }
            return index
        }
        var replacedPeaks = Set<String>()
        for raw in options["erp-peak"] ?? [] {
            let f = try fields(raw, counts: 5...6, flag: "erp-peak"), index = try conditionIndex(f[0])
            if replacedPeaks.insert(f[0]).inserted { design.conditions[index].peaks = [] }
            design.conditions[index].peaks.append(ERPWaveformPeak(id: f[1],
                latencySeconds: try number(f[2], flag: "erp-peak") / 1000,
                amplitudeMicrovolts: try number(f[3], flag: "erp-peak"),
                widthSeconds: try number(f[4], flag: "erp-peak") / 1000,
                occurrenceFraction: f.count == 6 ? try number(f[5], flag: "erp-peak") : 1))
        }
        for key in ["erp-mixture", "erp-recipe"] {
            var seen = Set<String>()
            for raw in options[key] ?? [] {
                let length = key == "erp-mixture" ? 4 : 5
                let f = try fields(raw, counts: length...length, flag: key), index = try conditionIndex(f[0])
                guard seen.insert(f[0]).inserted else { throw SimulateError.usage("Duplicate --\(key) for '\(f[0])'.") }
                let values = try f.dropFirst().map { try number($0, flag: key) }
                if key == "erp-mixture" {
                    design.conditions[index].recipes.attenuatedFraction = values[0]
                    design.conditions[index].recipes.invertedFraction = values[1]
                    design.conditions[index].recipes.divergentFraction = values[2]
                } else {
                    design.conditions[index].recipes.attenuatedGain = values[0]
                    design.conditions[index].recipes.divergentLatencyRangeSeconds = values[1] / 1000
                    design.conditions[index].recipes.divergentWidthMinimum = values[2]
                    design.conditions[index].recipes.divergentWidthMaximum = values[3]
                }
            }
        }
        if let reference = options["erp-reference"]?.first { design.groupReferenceConditionID = reference }
        if let contrasts = options["erp-contrast"] {
            design.groupContrasts = try contrasts.map { raw in
                let f = try fields(raw, counts: 2...2, flag: "erp-contrast")
                return ERPGroupContrast(id: f[0], weights: try parseWeights(f[1]))
            }
        }
        if let raw = options["erp-peak-jitter"]?.first {
            design.independentLatencyJitterSDSeconds = try number(raw, flag: "erp-peak-jitter") / 1000
        }
        if let raw = options["erp-width-jitter"]?.first {
            design.widthJitterFraction = try number(raw, flag: "erp-width-jitter")
        }
        if let raw = options["erp-noise"]?.first {
            design.addedNoiseRMSMicrovolts = try number(raw, flag: "erp-noise")
        }
        if let raw = options["erp-noise-kind"]?.first {
            guard let kind = ERPAddedNoiseKind(rawValue: raw) else {
                throw SimulateError.usage("--erp-noise-kind expects white or smoothed.")
            }
            design.addedNoiseKind = kind
        }
        guard erp.latencySkew == 0, erp.latencyAmplitudeCorrelation == 0 else {
            throw SimulateError.usage("Editable experiments require zero legacy latency skew/correlation; these options apply only to legacy ERP models.")
        }
        try design.validate(erp: erp)
        erp.experiment = design
        erp.components = nil
    }
}
