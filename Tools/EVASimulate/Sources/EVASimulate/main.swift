//
//  main.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A forward-model EEG/fMRI simulator and scorer, after Grouiller et al. (2007).
//
//  The problem it solves: EVA offers a dozen artifact-correction methods and
//  several OBS strategies, and on real data there is no way to tell which one is
//  right, because the true EEG underneath is unknown. Correction methods have
//  historically been validated by looking at the result — which cannot
//  distinguish "removed the artifact" from "removed the artifact and a good deal
//  of the brain signal with it". Simulated data with known ground truth can.
//
//    generate  — write a ground-truth recording and its contaminated twin
//    score     — compare a corrected recording against the ground truth
//    sweep     — generate a series varying one parameter, for a full curve
//

import Foundation

// MARK: - Argument parsing

nonisolated struct Arguments {
    private var values: [String: String] = [:]
    private(set) var positional: [String] = []

    init(_ tokens: [String]) {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    values[key] = tokens[index + 1]
                    index += 2
                } else {
                    values[key] = "true"
                    index += 1
                }
            } else {
                positional.append(token)
                index += 1
            }
        }
    }

    /// Rejects anything not in `known`. A research tool that silently ignored a
    /// misspelled flag would quietly report results for the default value
    /// instead of the requested one, and nothing downstream would ever catch it.
    func validate(known: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(known).sorted()
        guard unknown.isEmpty else {
            throw SimulateError.usage("Unknown option(s): " + unknown.map { "--\($0)" }.joined(separator: ", "))
        }
    }

    func string(_ key: String) -> String? { values[key] }

    func double(_ key: String) throws -> Double? {
        guard let raw = values[key] else { return nil }
        guard let value = Double(raw) else {
            throw SimulateError.usage("--\(key) expects a number, got \"\(raw)\"")
        }
        return value
    }

    func int(_ key: String) throws -> Int? {
        guard let raw = values[key] else { return nil }
        guard let value = Int(raw) else {
            throw SimulateError.usage("--\(key) expects an integer, got \"\(raw)\"")
        }
        return value
    }

    func uint64(_ key: String) throws -> UInt64? {
        guard let raw = values[key] else { return nil }
        guard let value = UInt64(raw) else {
            throw SimulateError.usage("--\(key) expects a non-negative integer, got \"\(raw)\"")
        }
        return value
    }

    func flag(_ key: String) -> Bool { values[key] == "true" }
}

func usage() -> String {
    """
    Usage:
      eva-simulate generate --output <dir> [model options]
      eva-simulate score --truth <clean.mff> --corrected <file.mff> [options]
      eva-simulate sweep --parameter <name> --values <a,b,c> --output <dir> [model options]
      eva-simulate selftest

    generate — writes <dir>/sim_clean.mff, <dir>/sim_noisy.mff, <dir>/sim_truth.json

      Recording
        --channels <n>              Channel count (default 20).
        --rate <hz>                 Sampling rate (default 1024).
        --duration <s>              Duration in seconds (default 180).
        --seed <n>                  Seed; same seed gives the same recording.

      Gradient artifact
        --no-gradient               Omit the imaging artifact entirely.
        --tr <s>                    Repetition time (default 3.0).
        --slices <n>                Slices per volume (default 41).
        --gradient-amplitude <uv>   Peak-to-peak on the strongest channel (default 7000).
        --gradient-amplitude-min <uv>  ... on the weakest channel (default 500).
        --clock-offset <us-per-s>   EEG/MRI clock drift (default 152).
        --slow-modulation <frac>    Slow amplitude drift, 0-0.25 (default 0.10).
        --gradient-template <path>  Use a measured slice template (one sample per
                                    line) instead of the synthetic waveform.
        --gradient-template-rate <hz>  Rate that template was sampled at.

      Ballistocardiogram
        --no-bcg                    Omit the cardiac artifact entirely.
        --bcg-amplitude <uv>        Mean peak-to-peak amplitude (default 100).
        --qrs-jitter <ms>           SD of detected-beat timing error (default 25).
        --heart-rate-min <bpm>      Default 65.
        --heart-rate-max <bpm>      Default 85.

      EEG
        --alpha-low <uv>            Eyes-open alpha amplitude (default 10).
        --alpha-high <uv>           Eyes-closed alpha amplitude (default 30).
        --eeg-std <uv>              Target EEG standard deviation (default 10.9).

      Modelling
        --artifact-oversample <n>   Internal artifact rate, x output rate (default 64).
        --artifact-anti-alias <f>   Anti-alias cutoff as a fraction of output
                                    Nyquist; 0 disables (default 0.9).
        --no-ecg                    Omit the synthetic ECG channel.
        --no-motion-sensor          Omit the synthetic motion-sensor channel.

    score — reports SNR per frequency band against ground truth

        --truth <clean.mff>         Ground-truth recording from `generate`. Required.
        --corrected <file.mff>      The recording after correction. Required.
        --baseline <noisy.mff>      Also score the uncorrected recording, so the
                                    table shows what the correction actually bought.
        --label <name>              Name for this correction in the output.
        --pad-seconds <s>           Ignore this much at each end (default 2).
        --csv <path>                Also write the per-band table as CSV.
        --json <path>               Also write the full result as JSON.

    sweep — one `generate` per value of a swept parameter

        --parameter <name>          One of: qrs-jitter, bcg-amplitude,
                                    gradient-amplitude, slow-modulation,
                                    clock-offset, rate.
        --values <a,b,c>            Comma-separated values to sweep.
        --output <dir>              Parent directory; one subdirectory per value.
        Plus any `generate` model option, applied to every run.

    Model defaults follow Grouiller F, Vercueil L, Krainik A, Segebarth C,
    Kahane P, David O (2007), NeuroImage 38(1):124-37. See the README for which
    parameters come from the paper and which are EVA's own.
    """
}

// MARK: - Config assembly

let generateOptions: Set<String> = [
    "output", "channels", "rate", "duration", "seed",
    "no-gradient", "tr", "slices", "gradient-amplitude", "gradient-amplitude-min",
    "clock-offset", "slow-modulation", "gradient-template", "gradient-template-rate",
    "no-bcg", "bcg-amplitude", "qrs-jitter", "heart-rate-min", "heart-rate-max",
    "alpha-low", "alpha-high", "eeg-std",
    "artifact-oversample", "artifact-anti-alias", "no-ecg", "no-motion-sensor"
]

func makeConfig(_ arguments: Arguments) throws -> SimulationConfig {
    var config = SimulationConfig.default

    if let value = try arguments.int("channels") { config.channelCount = value }
    if let value = try arguments.double("rate") { config.samplingRate = value }
    if let value = try arguments.double("duration") { config.durationSeconds = value }
    if let value = try arguments.uint64("seed") { config.seed = value }

    if arguments.flag("no-gradient") { config.gradientEnabled = false }
    if let value = try arguments.double("tr") { config.repetitionTimeSeconds = value }
    if let value = try arguments.int("slices") { config.slicesPerVolume = value }
    if let value = try arguments.double("gradient-amplitude") { config.gradientAmplitudeMaxMicrovolts = value }
    if let value = try arguments.double("gradient-amplitude-min") { config.gradientAmplitudeMinMicrovolts = value }
    if let value = try arguments.double("clock-offset") { config.clockOffsetMicrosecondsPerSecond = value }
    if let value = try arguments.double("slow-modulation") { config.slowModulationFraction = value }

    if arguments.flag("no-bcg") { config.bcgEnabled = false }
    if let value = try arguments.double("bcg-amplitude") { config.bcgAmplitudeMicrovolts = value }
    if let value = try arguments.double("qrs-jitter") { config.qrsDetectionJitterSDSeconds = value / 1000 }
    if let value = try arguments.double("heart-rate-min") { config.heartRateMinBPM = value }
    if let value = try arguments.double("heart-rate-max") { config.heartRateMaxBPM = value }

    if let value = try arguments.double("alpha-low") { config.alphaLowMicrovolts = value }
    if let value = try arguments.double("alpha-high") { config.alphaHighMicrovolts = value }
    if let value = try arguments.double("eeg-std") { config.eegTargetStdMicrovolts = value }

    if let value = try arguments.int("artifact-oversample") { config.artifactOversampleFactor = value }
    if let value = try arguments.double("artifact-anti-alias") { config.artifactAntiAliasFraction = value }
    if arguments.flag("no-ecg") { config.includeECG = false }
    if arguments.flag("no-motion-sensor") { config.includeMotionSensor = false }

    guard config.channelCount > 0 else { throw SimulateError.usage("--channels must be positive") }
    guard config.samplingRate > 0 else { throw SimulateError.usage("--rate must be positive") }
    guard config.durationSeconds > 0 else { throw SimulateError.usage("--duration must be positive") }
    guard config.artifactOversampleFactor >= 1 else { throw SimulateError.usage("--artifact-oversample must be at least 1") }

    return config
}

// MARK: - generate

@discardableResult
func runGenerate(config: SimulationConfig, arguments: Arguments, outputDirectory: URL) throws -> CorrectionScore {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    var source = GaussianSource(seed: config.seed)
    FileHandle.standardError.write(Data("Generating EEG (\(config.channelCount) channels, \(Int(config.durationSeconds)) s)...\n".utf8))
    let eeg = EEGGenerator.generate(config: config, source: &source)

    var noisy = eeg.channels

    var gradient: GradientInjection?
    if config.gradientEnabled {
        FileHandle.standardError.write(Data("Injecting gradient artifact...\n".utf8))
        var template: HighRateTemplate?
        if let path = arguments.string("gradient-template") {
            guard let rate = try arguments.double("gradient-template-rate") else {
                throw SimulateError.usage("--gradient-template also needs --gradient-template-rate")
            }
            template = try GradientArtifactModel.loadTemplate(path: path, templateRate: rate, config: config)
        }
        gradient = GradientArtifactModel.inject(into: &noisy, config: config, template: template)
    }

    var bcg: BCGInjection?
    if config.bcgEnabled {
        FileHandle.standardError.write(Data("Injecting ballistocardiogram...\n".utf8))
        bcg = BCGArtifactModel.inject(into: &noisy, config: config, source: &source)
    }

    let cleanURL = outputDirectory.appendingPathComponent("sim_clean.mff")
    let noisyURL = outputDirectory.appendingPathComponent("sim_noisy.mff")
    let events = SimulationWriter.events(gradient: gradient, bcg: bcg, config: config)

    var ecg: [Double]?
    var motion: [Double]?
    if let bcg {
        if config.includeECG {
            ecg = BCGArtifactModel.ecgChannel(beats: bcg.trueBeatSeconds, config: config)
        }
        if config.includeMotionSensor {
            motion = BCGArtifactModel.motionSensorChannel(
                meanBCG: bcg.meanWaveform,
                gain: config.motionSensorSigmoidGain
            )
        }
    }

    FileHandle.standardError.write(Data("Writing MFF packages...\n".utf8))
    try MFFWriter.write(
        signal: SimulationWriter.signal(
            channels: eeg.channels, config: config,
            signalType: "EEG Simulated Ground Truth", events: events, packageURL: cleanURL
        ),
        segments: [],
        kind: .continuous,
        to: cleanURL,
        preserveSourceFileInfo: false
    )
    try MFFWriter.write(
        signal: SimulationWriter.signal(
            channels: noisy, config: config,
            signalType: "EEG Simulated", events: events, packageURL: noisyURL
        ),
        pnsSignal: SimulationWriter.pnsSignal(ecg: ecg, motion: motion, config: config, packageURL: noisyURL),
        segments: [],
        kind: .continuous,
        to: noisyURL,
        preserveSourceFileInfo: false
    )

    let truth = SimulationTruth(
        config: config,
        cleanStandardDeviation: eeg.standardDeviation,
        alphaEnvelope1Hz: SimulationWriter.decimateToOneHz(eeg.alphaEnvelope, samplingRate: config.samplingRate),
        gradientVolumeOnsetsSeconds: gradient?.volumeOnsetsSeconds ?? [],
        gradientQuantizedVolumeOnsetsSeconds: gradient?.quantizedVolumeOnsetsSeconds ?? [],
        gradientChannelAmplitudesMicrovolts: gradient?.channelAmplitudesMicrovolts ?? [],
        bcgTrueBeatSeconds: bcg?.trueBeatSeconds ?? [],
        bcgDetectedBeatSeconds: bcg?.detectedBeatSeconds ?? [],
        bcgChannelScales: bcg?.channelScales ?? [],
        bcgChannelLatenciesSeconds: bcg?.channelLatenciesSeconds ?? []
    )
    try SimulationWriter.writeTruth(truth, to: outputDirectory.appendingPathComponent("sim_truth.json"))

    // The uncorrected recording's own score, which every correction has to beat
    // to have been worth running.
    let baseline = SNRMetrics.score(
        label: "uncorrected",
        clean: eeg.channels,
        corrected: noisy,
        samplingRate: config.samplingRate
    )

    print("Wrote \(cleanURL.path)")
    print("Wrote \(noisyURL.path)")
    print("Wrote \(outputDirectory.appendingPathComponent("sim_truth.json").path)")
    print("")
    print(String(format: "EEG std: %.2f µV   beats: %d   volumes: %d",
                 eeg.standardDeviation,
                 bcg?.trueBeatSeconds.count ?? 0,
                 gradient?.volumeOnsetsSeconds.count ?? 0))
    print(String(format: "Uncorrected broadband SNR: %.4f", baseline.broadbandSNR))
    return baseline
}

// MARK: - score

func loadChannels(_ path: String, padSeconds: Double) throws -> (channels: [[Double]], rate: Double) {
    let url = URL(fileURLWithPath: path)
    let signal = try MFFReader().loadSignal(from: url)
    let pad = max(0, Int((padSeconds * signal.samplingRate).rounded()))
    let channels = signal.data.map { channel -> [Double] in
        let usable = channel.count - 2 * pad
        guard usable > 0 else { return channel.map(Double.init) }
        return channel[pad..<(pad + usable)].map(Double.init)
    }
    return (channels, signal.samplingRate)
}

/// Left-pads in Swift rather than via `%-8s`, which needs a C string whose
/// lifetime is not guaranteed past the call that produced it.
func padded(_ text: String, to width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func formatted(_ score: CorrectionScore, baseline: CorrectionScore?) -> String {
    var lines: [String] = []
    lines.append("")
    lines.append(String(format: "%@: broadband SNR %.4f  (clean std %.2f µV, residual std %.2f µV)",
                        score.label, score.broadbandSNR,
                        score.cleanStandardDeviation, score.residualStandardDeviation))
    if let baseline {
        lines.append(String(format: "uncorrected: broadband SNR %.4f", baseline.broadbandSNR))
    }
    lines.append("")

    if baseline == nil {
        lines.append("  band      SNR    power dB   clean RMS   resid RMS")
        lines.append("  ---------------------------------------------------")
        for band in score.bands {
            lines.append("  " + padded(band.name, to: 8)
                + String(format: " %6.2f  %+8.2f  %9.3f  %10.3f",
                         band.snr, band.powerRatioDb, band.cleanRMS, band.residualRMS))
        }
    } else {
        lines.append("  band      SNR    uncorr    gain   power dB")
        lines.append("  ------------------------------------------")
        for (index, band) in score.bands.enumerated() {
            let uncorrected = index < baseline!.bands.count ? baseline!.bands[index].snr : .nan
            // The number that matters: a correction that leaves a band worse
            // than it found it has a gain below 1, and the paper's Figure 5C
            // finding is precisely that every BCG method does this above 10 Hz.
            let gain = uncorrected > 0 ? band.snr / uncorrected : .nan
            lines.append("  " + padded(band.name, to: 8)
                + String(format: " %6.2f  %6.2f  %6.2fx  %+8.2f",
                         band.snr, uncorrected, gain, band.powerRatioDb))
        }
    }
    lines.append("")
    lines.append("  SNR = std(clean) / std(clean - corrected), per band. Higher is better.")
    lines.append("  power dB = corrected band power vs clean; negative means EEG was removed")
    lines.append("  along with the artifact.")
    return lines.joined(separator: "\n")
}

func csv(_ score: CorrectionScore, baseline: CorrectionScore?) -> String {
    var lines = ["label,band,low_hz,high_hz,snr,uncorrected_snr,power_ratio_db,clean_rms_uv,residual_rms_uv"]
    for (index, band) in score.bands.enumerated() {
        let uncorrected = baseline.flatMap { index < $0.bands.count ? $0.bands[index].snr : nil }
        lines.append([
            score.label, band.name, "\(band.lowHz)", "\(band.highHz)",
            String(format: "%.6f", band.snr),
            uncorrected.map { String(format: "%.6f", $0) } ?? "",
            String(format: "%.6f", band.powerRatioDb),
            String(format: "%.6f", band.cleanRMS),
            String(format: "%.6f", band.residualRMS)
        ].joined(separator: ","))
    }
    lines.append([
        score.label, "broadband", "", "",
        String(format: "%.6f", score.broadbandSNR),
        baseline.map { String(format: "%.6f", $0.broadbandSNR) } ?? "",
        "", String(format: "%.6f", score.cleanStandardDeviation),
        String(format: "%.6f", score.residualStandardDeviation)
    ].joined(separator: ","))
    return lines.joined(separator: "\n") + "\n"
}

func runScore(_ arguments: Arguments) throws {
    try arguments.validate(known: ["truth", "corrected", "baseline", "label", "pad-seconds", "csv", "json"])

    guard let truthPath = arguments.string("truth") else {
        throw SimulateError.usage("score needs --truth <clean.mff>")
    }
    guard let correctedPath = arguments.string("corrected") else {
        throw SimulateError.usage("score needs --corrected <file.mff>")
    }
    let pad = try arguments.double("pad-seconds") ?? 2

    let truth = try loadChannels(truthPath, padSeconds: pad)
    let corrected = try loadChannels(correctedPath, padSeconds: pad)
    guard truth.channels.count == corrected.channels.count else {
        throw SimulateError.io(
            "channel count differs: truth has \(truth.channels.count), corrected has \(corrected.channels.count)"
        )
    }
    guard abs(truth.rate - corrected.rate) < 1e-6 else {
        throw SimulateError.io(
            "sampling rate differs: truth \(truth.rate) Hz, corrected \(corrected.rate) Hz"
        )
    }

    let label = arguments.string("label") ?? URL(fileURLWithPath: correctedPath).lastPathComponent
    let score = SNRMetrics.score(
        label: label,
        clean: truth.channels,
        corrected: corrected.channels,
        samplingRate: truth.rate
    )

    var baseline: CorrectionScore?
    if let baselinePath = arguments.string("baseline") {
        let noisy = try loadChannels(baselinePath, padSeconds: pad)
        guard noisy.channels.count == truth.channels.count else {
            throw SimulateError.io("baseline channel count differs from truth")
        }
        baseline = SNRMetrics.score(
            label: "uncorrected",
            clean: truth.channels,
            corrected: noisy.channels,
            samplingRate: truth.rate
        )
    }

    print(formatted(score, baseline: baseline))

    if let path = arguments.string("csv") {
        try csv(score, baseline: baseline).write(toFile: path, atomically: true, encoding: .utf8)
        print("\nWrote \(path)")
    }
    if let path = arguments.string("json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var payload = [score]
        if let baseline { payload.append(baseline) }
        try encoder.encode(payload).write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

// MARK: - sweep

func applySweep(_ parameter: String, value: Double, to config: inout SimulationConfig) throws {
    switch parameter {
    case "qrs-jitter": config.qrsDetectionJitterSDSeconds = value / 1000
    case "bcg-amplitude": config.bcgAmplitudeMicrovolts = value
    case "gradient-amplitude": config.gradientAmplitudeMaxMicrovolts = value
    case "slow-modulation": config.slowModulationFraction = value
    case "clock-offset": config.clockOffsetMicrosecondsPerSecond = value
    case "rate": config.samplingRate = value
    default:
        throw SimulateError.usage(
            "unknown --parameter \"\(parameter)\"; expected one of qrs-jitter, bcg-amplitude, "
            + "gradient-amplitude, slow-modulation, clock-offset, rate"
        )
    }
}

func runSweep(_ arguments: Arguments) throws {
    try arguments.validate(known: generateOptions.union(["parameter", "values"]))

    guard let parameter = arguments.string("parameter") else {
        throw SimulateError.usage("sweep needs --parameter <name>")
    }
    guard let rawValues = arguments.string("values") else {
        throw SimulateError.usage("sweep needs --values <a,b,c>")
    }
    guard let output = arguments.string("output") else {
        throw SimulateError.usage("sweep needs --output <dir>")
    }
    let values = try rawValues.split(separator: ",").map { token -> Double in
        guard let value = Double(token.trimmingCharacters(in: .whitespaces)) else {
            throw SimulateError.usage("--values contains a non-number: \"\(token)\"")
        }
        return value
    }
    guard !values.isEmpty else { throw SimulateError.usage("--values is empty") }

    let root = URL(fileURLWithPath: output)
    var summary: [String] = ["parameter,value,uncorrected_broadband_snr,directory"]

    for value in values {
        var config = try makeConfig(arguments)
        try applySweep(parameter, value: value, to: &config)
        let name = "\(parameter)-\(formatSweepValue(value))"
        let directory = root.appendingPathComponent(name)
        print("=== \(name) ===")
        let baseline = try runGenerate(config: config, arguments: arguments, outputDirectory: directory)
        summary.append("\(parameter),\(value),\(String(format: "%.6f", baseline.broadbandSNR)),\(directory.path)")
        print("")
    }

    let summaryURL = root.appendingPathComponent("sweep_summary.csv")
    try (summary.joined(separator: "\n") + "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
    print("Wrote \(summaryURL.path)")
}

func formatSweepValue(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}

// MARK: - Entry point

let tokens = Array(CommandLine.arguments.dropFirst())
guard let command = tokens.first else {
    print(usage())
    exit(2)
}
let arguments = Arguments(Array(tokens.dropFirst()))

do {
    switch command {
    case "generate":
        try arguments.validate(known: generateOptions)
        guard let output = arguments.string("output") else {
            throw SimulateError.usage("generate needs --output <dir>")
        }
        let config = try makeConfig(arguments)
        try runGenerate(config: config, arguments: arguments, outputDirectory: URL(fileURLWithPath: output))
    case "score":
        try runScore(arguments)
    case "sweep":
        try runSweep(arguments)
    case "selftest":
        try arguments.validate(known: [])
        var failures = 0
        print("")
        for outcome in SelfTest.run() {
            let mark = outcome.passed ? "PASS" : "FAIL"
            if !outcome.passed { failures += 1 }
            print(String(format: "  [%@] %@", mark, outcome.name))
            print(String(format: "         SNR %.3f   (expected %@)", outcome.snr, outcome.expectation))
        }
        print("")
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) check(s) failed\n".utf8))
            exit(1)
        }
    case "-h", "--help", "help":
        print(usage())
    default:
        FileHandle.standardError.write(Data("Unknown command \"\(command)\"\n\n".utf8))
        print(usage())
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
