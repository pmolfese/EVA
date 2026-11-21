// Copyright-free US Government work; see LICENSE.
import Foundation

nonisolated struct SimulationSweepParameter: Identifiable, Sendable {
    enum Scope: Sendable { case global, condition, peak }
    var id: String
    var title: String
    var unit: String
    var scope: Scope = .global
    var example: String
    var label: String { unit.isEmpty ? title : "\(title) (\(unit))" }
}

/// One registry shared by the CLI and GUI. All axes are absolute settings except
/// background-gain, which multiplies the original base amplitudes once per cell.
nonisolated enum SimulationSweep {
    static let parameters: [SimulationSweepParameter] = [
        .init(id: "erp-latency-jitter", title: "ERP response jitter", unit: "ms SD", example: "0, 15, 30, 60"),
        .init(id: "erp-peak-jitter", title: "Independent peak jitter", unit: "ms SD", example: "0, 10, 30"),
        .init(id: "erp-amplitude-jitter", title: "ERP amplitude variation", unit: "fraction SD", example: "0, 0.2, 0.4"),
        .init(id: "erp-width-jitter", title: "ERP width variation", unit: "fraction SD", example: "0, 0.1, 0.3"),
        .init(id: "erp-peak-amplitude", title: "Peak amplitude", unit: "µV", scope: .peak, example: "2, 4, 8"),
        .init(id: "erp-peak-latency", title: "Peak latency", unit: "ms", scope: .peak, example: "200, 300, 400"),
        .init(id: "erp-peak-width", title: "Peak width σ", unit: "ms", scope: .peak, example: "30, 60, 90"),
        .init(id: "erp-peak-occurrence", title: "Peak occurrence", unit: "fraction", scope: .peak, example: "0.25, 0.5, 1"),
        .init(id: "erp-inverted", title: "Inverted trials", unit: "fraction", scope: .condition, example: "0, 0.1, 0.3"),
        .init(id: "erp-attenuated", title: "Attenuated trials", unit: "fraction", scope: .condition, example: "0, 0.1, 0.3"),
        .init(id: "erp-divergent", title: "Divergent trials", unit: "fraction", scope: .condition, example: "0, 0.1, 0.3"),
        .init(id: "erp-attenuated-gain", title: "Attenuation gain", unit: "fraction", scope: .condition, example: "0.1, 0.3, 0.6"),
        .init(id: "erp-divergent-shift", title: "Divergent latency range ±", unit: "ms", scope: .condition, example: "20, 80, 150"),
        .init(id: "erp-divergent-width-min", title: "Divergent minimum width", unit: "× width", scope: .condition, example: "0.5, 0.7, 1"),
        .init(id: "erp-divergent-width-max", title: "Divergent maximum width", unit: "× width", scope: .condition, example: "1, 1.5, 2"),
        .init(id: "erp-omission-rate", title: "Omitted responses", unit: "fraction", example: "0, 0.1, 0.3"),
        .init(id: "erp-trials", title: "Total trials", unit: "trials", example: "20, 40, 80"),
        .init(id: "erp-condition-share", title: "Condition trial share", unit: "fraction", scope: .condition, example: "0.1, 0.2, 0.5"),
        .init(id: "erp-isi", title: "Mean ISI", unit: "s", example: "0.5, 1, 1.5"),
        .init(id: "erp-isi-jitter", title: "ISI range ±", unit: "s", example: "0, 0.1, 0.3"),
        .init(id: "erp-noise", title: "Added sensor noise", unit: "µV RMS", example: "0, 1.5, 5"),
        .init(id: "background-gain", title: "Background EEG gain", unit: "× base", example: "0.5, 1, 2"),
        .init(id: "bcg-amplitude", title: "BCG amplitude", unit: "µV", example: "50, 100, 200"),
        .init(id: "qrs-jitter", title: "QRS detection jitter", unit: "ms SD", example: "0, 10, 25"),
        .init(id: "bcg-morphology", title: "BCG morphology variation", unit: "fraction", example: "0, 0.1, 0.3"),
        .init(id: "bcg-latency", title: "BCG channel latency variation", unit: "ms SD", example: "0, 15, 30"),
        .init(id: "gradient-amplitude", title: "Gradient amplitude", unit: "µV", example: "1000, 3000, 7000"),
        .init(id: "clock-offset", title: "Clock offset", unit: "µs/s", example: "0, 1, 5"),
        .init(id: "slow-modulation", title: "Slow artifact modulation", unit: "fraction", example: "0, 0.1, 0.25"),
        .init(id: "rate", title: "Sampling rate", unit: "Hz", example: "250, 500, 1000"),
        .init(id: "impedance", title: "Impedance", unit: "kΩ", example: "5, 12, 40"),
        .init(id: "emg-rate", title: "EMG rate", unit: "bursts/min", example: "1, 5, 10"),
        .init(id: "emg-amplitude", title: "EMG amplitude", unit: "µV", example: "10, 30, 60"),
        .init(id: "blink-rate", title: "Blink rate", unit: "/min", example: "0, 10, 20"),
        .init(id: "blink-amplitude", title: "Blink amplitude", unit: "µV", example: "50, 100, 200"),
        .init(id: "bad-channel-fraction", title: "Bad-channel fraction", unit: "fraction", example: "0, 0.1, 0.2"),
        .init(id: "sources", title: "Dipole sources", unit: "sources", example: "4, 8, 16")
    ]
    static func parameter(_ id: String) throws -> SimulationSweepParameter {
        guard let p = parameters.first(where: { $0.id == id }) else { throw SimulateError.usage("Unknown sweep parameter '\(id)'. See sweep --help.") }
        return p
    }
    /// Explicit list or inclusive start:stop:step, with bounded expansion.
    static func values(_ text: String) throws -> [Double] {
        func number(_ s: String) throws -> Double {
            guard let x = Double(s.trimmingCharacters(in: .whitespaces)), x.isFinite else { throw SimulateError.usage("Sweep values must be finite numbers.") }
            return x
        }
        let result: [Double]
        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw SimulateError.usage("Use start:stop:step for a range.") }
            let a = try number(String(parts[0])), b = try number(String(parts[1])), step = try number(String(parts[2]))
            let distance = (b - a) / step
            guard step != 0, distance.isFinite, distance >= 0, distance < 1000 else { throw SimulateError.usage("Range step must reach stop in at most 1000 values.") }
            result = (0...Int(floor(distance + 1e-10))).map { a + Double($0) * step }
        } else {
            result = try text.split(separator: ",", omittingEmptySubsequences: false).map { try number(String($0)) }
        }
        guard !result.isEmpty, result.count <= 1000, result.allSatisfy(\.isFinite), Set(result).count == result.count else { throw SimulateError.usage("Use 1–1000 distinct finite sweep values.") }
        return result
    }
    static func apply(_ axis: SimulationSweepAxis, value: Double, to config: inout SimulationConfig) throws {
        let p = try parameter(axis.parameter)
        guard value.isFinite else { throw SimulateError.usage("Sweep value must be finite.") }
        guard p.scope != .global || (axis.conditionID == nil && axis.peakID == nil),
              p.scope == .peak || axis.peakID == nil else { throw SimulateError.usage("Selected scope does not apply to \(p.title).") }
        func require(_ valid: Bool, _ message: String) throws { if !valid { throw SimulateError.usage(message) } }
        let signed = ["erp-peak-amplitude", "clock-offset"]
        try require(signed.contains(p.id) || value >= 0, "\(p.title) cannot be negative.")
        if p.unit == "fraction" { try require(value <= 1, "\(p.title) must be between 0 and 1.") }
        if p.id.hasPrefix("erp-") {
            guard var erp = config.erp, var design = erp.experiment else { throw SimulateError.usage("ERP sweeps require an editable experiment. Enable the ERP editor or pass --erp-experiment/--erp-condition.") }
            if let id = axis.conditionID { try require(design.conditions.contains { $0.id == id }, "Unknown sweep condition '\(id)'.") }
            if axis.peakID != nil { try require(axis.conditionID != nil, "Select a condition when selecting an individual peak.") }
            if let id = axis.peakID { try require(design.conditions.first(where: { $0.id == axis.conditionID })!.peaks.contains { $0.id == id }, "Unknown sweep peak '\(id)'.") }
            switch p.id {
            case "erp-latency-jitter": erp.latencyJitterSDSeconds = value / 1000
            case "erp-peak-jitter": design.independentLatencyJitterSDSeconds = value / 1000
            case "erp-amplitude-jitter": erp.amplitudeJitterFraction = value
            case "erp-width-jitter": design.widthJitterFraction = value
            case "erp-noise": design.addedNoiseRMSMicrovolts = value
            case "erp-omission-rate": erp.omissionRate = value
            case "erp-trials":
                try require(value >= 1 && value <= 100_000 && value.rounded() == value, "Trial counts must be integers from 1 to 100,000.")
                erp.trialCount = Int(value)
            case "erp-isi": erp.interStimulusIntervalSeconds = value
            case "erp-isi-jitter": erp.interStimulusJitterSeconds = value
            case "erp-condition-share":
                guard let id = axis.conditionID else { throw SimulateError.usage("Condition-share sweeps require a selected condition.") }
                let others = design.conditions.indices.filter { design.conditions[$0].id != id }
                try require(!others.isEmpty || value == 1, "A single condition must have share 1.")
                let total = others.reduce(0.0) { $0 + design.conditions[$1].fraction }
                for i in design.conditions.indices {
                    design.conditions[i].fraction = design.conditions[i].id == id ? value :
                        (1 - value) * (total > 0 ? design.conditions[i].fraction / total : 1 / Double(others.count))
                }
            default:
                for c in design.conditions.indices where axis.conditionID == nil || design.conditions[c].id == axis.conditionID {
                    switch p.id {
                    case "erp-inverted": design.conditions[c].recipes.invertedFraction = value
                    case "erp-attenuated": design.conditions[c].recipes.attenuatedFraction = value
                    case "erp-divergent": design.conditions[c].recipes.divergentFraction = value
                    case "erp-attenuated-gain": design.conditions[c].recipes.attenuatedGain = value
                    case "erp-divergent-shift": design.conditions[c].recipes.divergentLatencyRangeSeconds = value / 1000
                    case "erp-divergent-width-min": design.conditions[c].recipes.divergentWidthMinimum = value
                    case "erp-divergent-width-max": design.conditions[c].recipes.divergentWidthMaximum = value
                    default:
                        for k in design.conditions[c].peaks.indices where axis.peakID == nil || design.conditions[c].peaks[k].id == axis.peakID {
                            switch p.id {
                            case "erp-peak-amplitude": design.conditions[c].peaks[k].amplitudeMicrovolts = value
                            case "erp-peak-latency": design.conditions[c].peaks[k].latencySeconds = value / 1000
                            case "erp-peak-width": design.conditions[c].peaks[k].widthSeconds = value / 1000
                            case "erp-peak-occurrence": design.conditions[c].peaks[k].occurrenceFraction = value
                            default: break
                            }
                        }
                    }
                }
            }
            // Validate after both axes, so an ISI grid can change both mean and range.
            erp.experiment = design; config.erp = erp
            return
        }
        switch p.id {
        case "qrs-jitter": try require(config.bcgEnabled, "Enable BCG for a QRS sweep."); config.qrsDetectionJitterSDSeconds = value / 1000
        case "bcg-amplitude": config.bcgEnabled = true; config.bcgAmplitudeMicrovolts = value
        case "bcg-latency": config.bcgEnabled = true; config.bcgChannelLatencySDSeconds = value / 1000
        case "bcg-morphology": config.bcgEnabled = true; config.bcgSpatialModel = .generators; config.bcgMorphologyJitterFraction = value
        case "gradient-amplitude":
            config.gradientEnabled = true
            let ratio = config.gradientAmplitudeMaxMicrovolts > 0 ? config.gradientAmplitudeMinMicrovolts / config.gradientAmplitudeMaxMicrovolts : 0
            config.gradientAmplitudeMaxMicrovolts = value; config.gradientAmplitudeMinMicrovolts = ratio * value
        case "slow-modulation": try require(config.gradientEnabled, "Enable gradients before sweeping modulation."); config.slowModulationFraction = value
        case "clock-offset": try require(config.gradientEnabled, "Enable gradients before sweeping clock offset."); config.clockOffsetMicrosecondsPerSecond = value
        case "rate": try require(value > 0, "Sampling rate must be positive."); config.samplingRate = value
        case "impedance":
            try require(value > 0, "Impedance must be positive.")
            config.impedanceTypicalKOhm = value; config.includeImpedance = true; config.impedanceNoise = config.impedanceNoise ?? ImpedanceNoiseConfig()
        case "emg-rate":
            if value == 0 { config.emg = nil } else { var e = config.emg ?? EMGConfig(); e.burstsPerMinute = value; config.emg = e }
        case "emg-amplitude":
            try require(value > 0, "EMG amplitude must be positive; use EMG rate 0 for no bursts.")
            var e = config.emg ?? EMGConfig(); e.amplitudeMicrovolts = value; config.emg = e
        case "blink-rate": config.blinksPerMinute = value
        case "blink-amplitude": try require(config.blinksPerMinute > 0, "Enable blinks before sweeping their amplitude."); config.blinkAmplitudeMicrovolts = value
        case "bad-channel-fraction":
            try require(config.badChannels.isEmpty, "Remove explicitly named bad channels before sweeping their fraction.")
            config.badChannelCount = Int((value * Double(config.channelCount)).rounded())
        case "background-gain":
            config.eegTargetStdMicrovolts *= value
        case "sources":
            try require(config.eegGenerationModel == .dipole && value >= 1 && value <= 10000 && value.rounded() == value, "Source sweep requires dipole mode and positive whole numbers ≤10000.")
            config.dipoleSourceCount = Int(value)
        default: break
        }
    }
}

nonisolated struct SimulationSweepAxis: Codable, Sendable {
    var parameter: String
    var values: [Double]
    var conditionID: String? = nil
    var peakID: String? = nil
}
nonisolated struct SimulationSweepPlan: Codable, Sendable {
    var axes: [SimulationSweepAxis]
    var repeats: Int = 1
    var fitDuration: Bool = true
    var evaluation = SweepEvaluationOptions()
    var runCount: Int { axes.reduce(repeats) { $0 * $1.values.count } }
    func validate() throws {
        guard (1...2).contains(axes.count), (1...100).contains(repeats), runCount <= 10000 else { throw SimulateError.usage("Use 1–2 axes, 1–100 repeats, and at most 10,000 recordings.") }
        guard Set(axes.map(\.parameter)).count == axes.count else { throw SimulateError.usage("Grid axes must use different parameters.") }
        for axis in axes {
            _ = try SimulationSweep.parameter(axis.parameter)
            guard !axis.values.isEmpty, axis.values.count <= 1000, axis.values.allSatisfy(\.isFinite), Set(axis.values).count == axis.values.count else { throw SimulateError.usage("Each axis needs distinct finite values.") }
        }
        try evaluation.validate()
    }
}
nonisolated struct SimulationSweepRow: Codable, Sendable {
    var value: Double
    var secondValue: Double?
    var repetition: Int
    var seed: UInt64
    var directory: String
    var uncorrectedSNR: Double?
    var evaluations: [SweepConditionEvaluation]
}
nonisolated struct SimulationSweepReport: Codable, Sendable {
    var version = 1
    var plan: SimulationSweepPlan
    var baseSeed: UInt64
    var rows: [SimulationSweepRow]
}
