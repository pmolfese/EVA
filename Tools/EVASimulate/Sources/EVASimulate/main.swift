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

    generate — writes <dir>/<prefix>_clean.mff, <dir>/<prefix>_noisy.mff,
               <dir>/<prefix>_truth.json  (prefix defaults to "sim")

      Recording
        --output <dir>              Directory to write into. Required.
        --prefix <name>             Filename prefix (default "sim"), so
                                    --prefix test1 gives test1_clean.mff,
                                    test1_noisy.mff and test1_truth.json.
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
        --hrv <fraction>            Beat-to-beat heart-rate variability as a
                                    fraction of RR (default 0.04). 0 restores
                                    the paper's exact metronomic timing.
        --respiration <hz>          Breathing rate (default 0.25 = 15/min).
                                    Drives sinus arrhythmia, ECG amplitude
                                    modulation and baseline wander.

      EEG
        --alpha-low <uv>            Eyes-open alpha amplitude (default 10).
        --alpha-high <uv>           Eyes-closed alpha amplitude (default 30).
        --eeg-std <uv>              Target EEG standard deviation (default 10.9).

      Ocular artifacts (off by default — the paper's model has none)
        --blinks <per-min>          Blink rate; 12-20 is a resting adult.
        --blink-amplitude <uv>      Peak amplitude at Fp1/Fp2 (default 100).
        --eye-movements <per-min>   Saccade rate.
        --eye-movement-amplitude <uv>  Scalp amplitude at full gaze (default 40).

      Recording defects (off by default)
        --bad-channels <spec>       Comma-separated <channel>:<kind>, 1-based,
                                    e.g. "7:noisy,15:drift". Kinds: flat, noisy,
                                    drift, pop, line. Kind defaults to noisy.
        --line-noise <hz>           Mains frequency; 0 is off. Try 60.
        --line-noise-amplitude <uv> Default 8.
        --impedance <kohm>          Typical impedance of a healthy electrode
                                    (default 12). Bad channels instead get a
                                    value matching their defect — high for a
                                    poor contact, but deliberately LOW for
                                    "flat", since a bridged electrode reads
                                    excellent and records nothing.
        --no-impedance              Record no impedance measurement at all.

      Scanner window
        --pre-scan <s>              Quiet time before the sequence starts.
        --post-scan <s>             Quiet time after it stops.
                                    The BCG continues through both — the static
                                    field is on the whole time the subject is in
                                    the bore; only the gradients stop.

      Modelling
        --artifact-oversample <n>   Internal artifact rate, x output rate (default 64).
        --artifact-anti-alias <f>   Anti-alias cutoff as a fraction of output
                                    Nyquist; 0 disables (default 0.9).
        --no-ecg                    Omit the synthetic ECG channel.
        --no-motion-sensor          Omit the synthetic motion-sensor channel.
        --spatial-model <name>      circular (the paper's, default) or geometric
                                    (smooth by real electrode distance — prefer
                                    this for demos and topography).
        --spatial-smoothing <n>     Kernel width in channels (default 4).
        --demo                      Preset for teaching recordings: blinks, eye
                                    movements, 60 Hz line noise, geometric
                                    spatial model, pre/post-scan quiet, and two
                                    bad channels. Any explicit flag still wins.

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
                                    --prefix applies inside each of them.
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
    "hrv", "respiration",
    "alpha-low", "alpha-high", "eeg-std", "spatial-model", "spatial-smoothing",
    "artifact-oversample", "artifact-anti-alias", "no-ecg", "no-motion-sensor",
    "prefix", "pre-scan", "post-scan",
    "blinks", "blink-amplitude", "eye-movements", "eye-movement-amplitude",
    "bad-channels", "line-noise", "line-noise-amplitude", "demo",
    "impedance", "no-impedance"
]

/// Validates the output filename prefix and normalizes it to bare stem.
///
/// A trailing underscore is stripped rather than rejected, so `--prefix test1`
/// and `--prefix test1_` both produce `test1_clean.mff`. Separators are refused
/// outright: a prefix containing a slash would place files outside the directory
/// the user named, which is not something a filename option should be able to do.
func normalizedPrefix(_ raw: String) throws -> String {
    var prefix = raw.trimmingCharacters(in: .whitespaces)
    while prefix.hasSuffix("_") { prefix.removeLast() }

    guard !prefix.isEmpty else {
        throw SimulateError.usage("--prefix cannot be empty")
    }
    guard !prefix.contains("/"), !prefix.contains(":"), prefix != ".", prefix != ".." else {
        throw SimulateError.usage(
            "--prefix is a filename prefix, not a path; \"\(raw)\" contains a path separator"
        )
    }
    return prefix
}

func parseBadChannels(_ spec: String) throws -> [Int: ChannelDefect] {
    var result: [Int: ChannelDefect] = [:]
    for entry in spec.split(separator: ",") {
        let parts = entry.split(separator: ":", maxSplits: 1)
        guard let number = Int(parts[0].trimmingCharacters(in: .whitespaces)), number > 0 else {
            throw SimulateError.usage(
                "--bad-channels entry \"\(entry)\" should start with a 1-based channel number"
            )
        }
        // Default to the most generally useful defect when none is named, so
        // `--bad-channels 7` does something sensible.
        guard parts.count > 1 else {
            result[number] = .noisy
            continue
        }
        let kind = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        guard let defect = ChannelDefect(rawValue: kind) else {
            throw SimulateError.usage(
                "unknown defect \"\(kind)\"; expected one of "
                + ChannelDefect.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        result[number] = defect
    }
    return result
}

func makeConfig(_ arguments: Arguments) throws -> SimulationConfig {
    var config = SimulationConfig.default

    // `--demo` is a preset, applied first so that any explicit flag still wins.
    // It exists because the settings that make a good teaching recording are not
    // the settings that reproduce the paper, and asking someone to remember six
    // flags to get a usable classroom file is a good way to have them not bother.
    if arguments.flag("demo") {
        config.blinksPerMinute = 15
        config.saccadesPerMinute = 25
        config.lineNoiseHz = 60
        config.spatialModel = .geometric
        config.preScanSeconds = 15
        config.postScanSeconds = 10
        config.badChannels = [7: .noisy, 15: .drift]
    }

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
    if let value = try arguments.double("hrv") { config.heartRateVariability = value }
    if let value = try arguments.double("respiration") { config.respirationHz = value }

    if let value = try arguments.double("alpha-low") { config.alphaLowMicrovolts = value }
    if let value = try arguments.double("alpha-high") { config.alphaHighMicrovolts = value }
    if let value = try arguments.double("eeg-std") { config.eegTargetStdMicrovolts = value }
    if let value = try arguments.double("spatial-smoothing") { config.spatialSmoothingChannels = value }
    if let raw = arguments.string("spatial-model") {
        guard let model = SpatialModel(rawValue: raw) else {
            throw SimulateError.usage("--spatial-model expects circular or geometric, got \"\(raw)\"")
        }
        config.spatialModel = model
    }

    if let value = try arguments.double("pre-scan") { config.preScanSeconds = value }
    if let value = try arguments.double("post-scan") { config.postScanSeconds = value }

    if let value = try arguments.double("blinks") { config.blinksPerMinute = value }
    if let value = try arguments.double("blink-amplitude") { config.blinkAmplitudeMicrovolts = value }
    if let value = try arguments.double("eye-movements") { config.saccadesPerMinute = value }
    if let value = try arguments.double("eye-movement-amplitude") { config.eyeMovementAmplitudeMicrovolts = value }

    if let spec = arguments.string("bad-channels") { config.badChannels = try parseBadChannels(spec) }
    if let value = try arguments.double("line-noise") { config.lineNoiseHz = value }
    if let value = try arguments.double("line-noise-amplitude") { config.lineNoiseAmplitudeMicrovolts = value }
    if arguments.flag("no-impedance") { config.includeImpedance = false }
    if let value = try arguments.double("impedance") {
        guard value > 0 else { throw SimulateError.usage("--impedance must be positive") }
        config.impedanceTypicalKOhm = value
    }

    if let value = try arguments.int("artifact-oversample") { config.artifactOversampleFactor = value }
    if let value = try arguments.double("artifact-anti-alias") { config.artifactAntiAliasFraction = value }
    if arguments.flag("no-ecg") { config.includeECG = false }
    if arguments.flag("no-motion-sensor") { config.includeMotionSensor = false }

    guard config.channelCount > 0 else { throw SimulateError.usage("--channels must be positive") }
    guard config.samplingRate > 0 else { throw SimulateError.usage("--rate must be positive") }
    // Checked here rather than at write time: MFF stores an integer sample rate,
    // and finding that out after generating three minutes of data wastes the run.
    guard config.samplingRate == config.samplingRate.rounded() else {
        throw SimulateError.usage(
            "--rate must be a whole number of hertz (MFF stores an integer sample rate), got \(config.samplingRate)"
        )
    }
    guard config.durationSeconds > 0 else { throw SimulateError.usage("--duration must be positive") }
    guard config.artifactOversampleFactor >= 1 else { throw SimulateError.usage("--artifact-oversample must be at least 1") }
    guard config.preScanSeconds >= 0, config.postScanSeconds >= 0 else {
        throw SimulateError.usage("--pre-scan and --post-scan cannot be negative")
    }
    guard config.preScanSeconds + config.postScanSeconds < config.durationSeconds else {
        throw SimulateError.usage(
            "--pre-scan + --post-scan (\(config.preScanSeconds + config.postScanSeconds) s) leaves no "
            + "scanning time inside a \(config.durationSeconds) s recording"
        )
    }
    for number in config.badChannels.keys where number > config.channelCount {
        throw SimulateError.usage(
            "--bad-channels names channel \(number), but the montage has \(config.channelCount)"
        )
    }

    return config
}

// MARK: - generate

@discardableResult
func runGenerate(config: SimulationConfig, arguments: Arguments, outputDirectory: URL) throws -> CorrectionScore {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let prefix = try normalizedPrefix(arguments.string("prefix") ?? "sim")

    var source = GaussianSource(seed: config.seed)
    let montage = Montage.standard(count: config.channelCount)
    FileHandle.standardError.write(Data(
        "Generating EEG (\(config.channelCount) channels, \(montage.name), \(Int(config.durationSeconds)) s)...\n".utf8
    ))
    let eeg = EEGGenerator.generate(config: config, montage: montage, source: &source)

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
        gradient = GradientArtifactModel.inject(into: &noisy, config: config, montage: montage, template: template)
    }

    var bcg: BCGInjection?
    if config.bcgEnabled {
        FileHandle.standardError.write(Data("Injecting ballistocardiogram...\n".utf8))
        bcg = BCGArtifactModel.inject(into: &noisy, config: config, source: &source)
    }

    var ocular: OcularInjection?
    if config.blinksPerMinute > 0 || config.saccadesPerMinute > 0 {
        FileHandle.standardError.write(Data("Injecting blinks and eye movements...\n".utf8))
        ocular = OcularArtifactModel.inject(into: &noisy, config: config, montage: montage, source: &source)
    }

    if config.lineNoiseHz > 0 {
        ChannelDefectModel.applyLineNoise(to: &noisy, config: config, source: &source)
    }

    // Bad channels go last: a defect is something that happens to the recording
    // of a channel, on top of everything the channel was already carrying.
    let badChannels = ChannelDefectModel.apply(to: &noisy, config: config, source: &source)

    // Impedance is a property of the electrodes, not of the samples, so it is
    // written to *both* packages. That is not an oversight: EVA treats impedance
    // as a stable property of the recording and scores it independently of the
    // data, so the ground-truth file showing a poor electrode alongside perfect
    // samples is exactly the lesson — the measurement was taken before anything
    // was recorded.
    let impedances: [Float]? = config.includeImpedance
        ? ImpedanceModel.values(config: config, montage: montage, source: &source)
        : nil

    let cleanURL = outputDirectory.appendingPathComponent("\(prefix)_clean.mff")
    let noisyURL = outputDirectory.appendingPathComponent("\(prefix)_noisy.mff")
    let truthURL = outputDirectory.appendingPathComponent("\(prefix)_truth.json")
    let events = SimulationWriter.events(gradient: gradient, bcg: bcg, ocular: ocular, config: config)

    var ecg: [Double]?
    var motion: [Double]?
    if let bcg {
        if config.includeECG {
            ecg = BCGArtifactModel.ecgChannel(
                beats: bcg.trueBeatSeconds,
                rrIntervals: bcg.rrIntervalsSeconds,
                config: config,
                source: &source
            )
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
            signalType: "EEG Simulated Ground Truth", events: events, packageURL: cleanURL,
            names: montage.channelNames
        ),
        segments: [],
        kind: .continuous,
        to: cleanURL,
        preserveSourceFileInfo: false
    )
    try MFFWriter.write(
        signal: SimulationWriter.signal(
            channels: noisy, config: config,
            signalType: "EEG Simulated", events: events, packageURL: noisyURL,
            names: montage.channelNames
        ),
        pnsSignal: SimulationWriter.pnsSignal(
            ecg: ecg, motion: motion,
            veog: ocular?.veog, heog: ocular?.heog,
            config: config, packageURL: noisyURL
        ),
        segments: [],
        kind: .continuous,
        to: noisyURL,
        preserveSourceFileInfo: false
    )

    // Electrode geometry, which MFFWriter cannot synthesize because it normally
    // copies it from the source package a simulation does not have.
    try MontageWriter.writeLayoutFiles(montage: montage, to: cleanURL)
    try MontageWriter.writeLayoutFiles(montage: montage, to: noisyURL)

    if let impedances {
        try ImpedanceModel.writeInfoXML(impedances: impedances, to: cleanURL)
        try ImpedanceModel.writeInfoXML(impedances: impedances, to: noisyURL)
    }

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
        bcgChannelLatenciesSeconds: bcg?.channelLatenciesSeconds ?? [],
        montageName: montage.name,
        channelNames: montage.channelNames,
        badChannels: badChannels,
        blinkSeconds: ocular?.blinkSeconds ?? [],
        saccadeSeconds: ocular?.saccadeSeconds ?? [],
        blinkTopography: ocular?.blinkTopography ?? [],
        horizontalEyeTopography: ocular?.horizontalTopography ?? [],
        impedancesKOhm: impedances?.map(Double.init) ?? [],
        scanStartSeconds: config.gradientEnabled ? config.preScanSeconds : 0,
        scanEndSeconds: config.gradientEnabled
            ? config.durationSeconds - config.postScanSeconds
            : 0
    )
    try SimulationWriter.writeTruth(truth, to: truthURL)

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
    print("Wrote \(truthURL.path)")
    print("")
    print(String(format: "EEG std: %.2f µV   beats: %d   volumes: %d   montage: %@",
                 eeg.standardDeviation,
                 bcg?.trueBeatSeconds.count ?? 0,
                 gradient?.volumeOnsetsSeconds.count ?? 0,
                 montage.name))
    if let ocular {
        print("Blinks: \(ocular.blinkSeconds.count)   eye movements: \(ocular.saccadeSeconds.count)")
    }
    if config.gradientEnabled, config.preScanSeconds > 0 || config.postScanSeconds > 0 {
        print(String(format: "Scanner running %.1f-%.1f s (BCG runs the whole recording)",
                     config.preScanSeconds, config.durationSeconds - config.postScanSeconds))
    }
    if let impedances, !impedances.isEmpty {
        let sorted = impedances.map(Double.init).sorted()
        print(String(format: "Impedance: median %.1f kΩ, worst %.1f kΩ",
                     sorted[sorted.count / 2], sorted.last ?? 0))
    }
    if !badChannels.isEmpty {
        let described = badChannels.sorted { Int($0.key)! < Int($1.key)! }.map { number, defect -> String in
            let index = Int(number)! - 1
            let name = index < montage.channelNames.count ? montage.channelNames[index] : "#\(number)"
            return "\(name) (\(defect))"
        }
        print("Bad channels: " + described.joined(separator: ", "))
    }
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
            let mark = outcome.passed ? "PASS" : (outcome.knownLimitation == nil ? "FAIL" : "KNOWN")
            if !outcome.passed, outcome.knownLimitation == nil { failures += 1 }
            print(String(format: "  [%@] %@", mark, outcome.name))
            print(String(format: "         %.3f   (expected %@)", outcome.snr, outcome.expectation))
            if let limitation = outcome.knownLimitation, !outcome.passed {
                print("         known limitation: " + limitation)
            }
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
