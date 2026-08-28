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
//    score         — compare a corrected recording against the ground truth
//    score-sources — score inverse locations and recovered source waveforms
//    score-events  — score event detection and timing against true events
//    score-erp     — score recovered ERP peak amplitude and latency
//    score-pac     — score recovered phase-amplitude coupling parameters
//    sweep         — generate a series varying one parameter, for a full curve
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
      eva-simulate generate [--output <dir>] [--write-config <json>] [model options]
      eva-simulate score --truth <clean.mff> --corrected <file.mff> [options]
      eva-simulate score-sources --truth <truth.json> [source options]
      eva-simulate score-events --truth <truth.json> --detected <json-or-mff> --type <event>
      eva-simulate score-erp --truth <components.json> --estimated <components.json>
      eva-simulate score-pac --truth <truth.json> --estimated <pac.json>
      eva-simulate sweep --parameter <name> --values <a,b,c> --output <dir> [model options]
      eva-simulate selftest

    generate — writes <dir>/<prefix>_clean.mff, <dir>/<prefix>_noisy.mff,
               <dir>/<prefix>_truth.json  (prefix defaults to "sim"), or writes
               only a resolved scenario when --write-config is used alone

      Recording
        --config <json>             Load a versioned scenario file. Explicit
                                    model flags override the loaded values.
        --write-config <json>       Save the final resolved scenario. Without
                                    --output, save it and exit without simulating.
        --output <dir>              Directory to write into. Required.
        --prefix <name>             Filename prefix (default "sim"), so
                                    --prefix test1 gives test1_clean.mff,
                                    test1_noisy.mff and test1_truth.json.
        --channels <n>              Channel count (default 20).
        --coordinates <path>       Use a standalone coordinates.xml or an MFF
                                    containing coordinates.xml. When --channels
                                    is omitted, its EEG sensor count is used.
        --no-coordinates            Return a loaded scenario to the built-in montage.
        --rate <hz>                 Sampling rate (default 1000; paper used 1024).
        --duration <s>              Duration in seconds (default 180).
        --seed <n>                  Seed; same seed gives the same recording.

      Gradient artifact
        --with-gradient             Enable gradients if a scenario disables them.
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
        --no-gradient-template      Return a loaded scenario to the synthetic template.

      Ballistocardiogram
        --with-bcg                  Enable BCG if a scenario disables it.
        --no-bcg                    Omit the cardiac artifact entirely.
        --bcg-amplitude <uv>        Mean peak-to-peak amplitude (default 100).
    --bcg-model <name>          channelIndex (default, reproduces the paper) or
                                generators. channelIndex weights each channel by
                                its INDEX and is rank one; generators places four
                                physical sources with real topographies.
    --bcg-field-strength <T>    Static field for the generator model (default 3).
    --bcg-morphology-jitter <f> Per-generator beat-to-beat weight SD (default
                                0.20). Zero fixes the composite morphology.
    --bcg-generator-scales <a,l,r,h>
                                Relative aortic, left-vessel, right-vessel and
                                head-rotation shares (default 1,1,1,1).
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
        --eeg-model <name>          grouiller (paper default) or dipole.
        --reference <name>          average (default) or infinity; applies to
                                    every additive sensor-space layer.
        --sources <n>               Neural dipoles in dipole mode (default 7).
        --source-depth <fraction>   Source radius / brain radius (default 0.85).
        --source-orientations <p>   radial, tangential, mixed, or free (default mixed).
        --lead-field-terms <n>      Spherical-harmonic terms (default 100).
        --source-correlation <r>    Correlate S001/S002 at Pearson r (-0.99...0.99).
        --near-source-separation <deg>  Put S002 this many degrees from S001.
        --source-motion <deg>       Rotate S001 by this angle during the run.
        --source-motion-start <f>   Motion start as recording fraction (default 0.45).
        --source-motion-transition <f>  Transition duration fraction (default 0.10).
        --write-sources             Also write <prefix>_sources.mff ground truth.

      Neural non-stationarity (off by default)
        --with-nonstationarity      Enable bursts, spectral dynamics, microstates, and PAC.
        --no-nonstationarity        Restore the stationary paper model.
        --alpha-bursts <per-min>    Alpha spindle rate (default 12).
        --alpha-burst-duration <s>  Mean spindle duration (default 1).
        --no-alpha-bursts           Keep continuous block-modulated alpha.
        --spectral-variation <sd>   Slow log-amplitude SD (default 0.35).
        --spectral-timescale <s>    OU time constant (default 12).
        --no-spectral-dynamics      Disable slow band-amplitude evolution.
        --microstates <n>           Number of switching scalp maps (default 4).
        --microstate-dwell <ms>     Mean map dwell time (default 100).
        --microstate-amplitude <uv> Broadband map-carrier RMS (default 4).
        --no-microstates            Disable topographic switching.
        --pac <strength>            Phase-amplitude modulation depth (0...0.99).
        --pac-low <hz>              Phase oscillator frequency (default 6).
        --pac-band <name>           Modulated EEG band (default gamma-low).
        --pac-phase <deg>           Preferred phase (default 0 degrees).
        --no-pac                    Disable phase-amplitude coupling.

      Event-related potentials (off by default)
        --with-erp                  Enable the default 80-trial oddball design.
        --no-erp                    Disable ERPs loaded from a scenario.
        --erp-trials <n>            Number of standard/target trials.
        --erp-isi <s>               Inter-stimulus interval (default 1.5).
        --erp-isi-jitter <s>        Uniform onset jitter (default ±0.2).
        --erp-target-fraction <f>   Target-trial fraction (default 0.2).
        --erp-latency <ms>          Nominal component peak (default 300).
        --erp-latency-jitter <ms>   Trial latency SD (default 30).
        --erp-latency-skew <x>      Signed non-Gaussian latency skew (default 0).
        --erp-amplitude <uv>        Target peak at strongest sensor (default 8).
        --erp-standard-ratio <f>    Standard/target amplitude ratio (default 0.5).
        --erp-amplitude-jitter <f>  Trial amplitude SD fraction (default 0.2).
        --erp-latency-amplitude-correlation <r>  Correlated trial variability.
        --erp-omission-rate <f>     Fraction of stimulus events with no response.
        --erp-waveform <name>       gaussian or biphasic.
        --erp-width <ms>            Analytic component width (default 60).
        --erp-template <path>       Measured waveform, one sample per line.
        --erp-template-rate <hz>    Sampling rate of the measured ERP waveform.

      Ocular artifacts (off by default — the paper's model has none)
        --blinks <per-min>          Blink rate; 12-20 is a resting adult.
        --blink-amplitude <uv>      Peak amplitude at Fp1/Fp2 (default 100).
        --eye-movements <per-min>   Saccade rate.
        --eye-movement-amplitude <uv>  Scalp amplitude at full gaze (default 40).
        --ocular-model <name>       heuristic (default) or homogeneous dipole.

      Muscle artifact (off by default)
        --with-emg                  Enable bursty temporalis/neck EMG defaults.
        --no-emg                    Disable EMG loaded from a scenario.
        --emg <bursts-per-min>      Mean burst rate (default 8 when enabled).
        --emg-amplitude <uv>        RMS at the strongest electrode (default 50).
        --emg-duration <s>          Mean burst duration (default 0.75).
        --emg-low <hz>              Carrier low edge (default 20).
        --emg-high <hz>             Carrier high edge (default 200).

      Additional artifacts (off by default)
        --chewing <episodes/min>    Rhythmic temporalis episodes.
        --chewing-amplitude <uv>    Default 100 RMS.
        --chewing-duration <s>      Default 4.
        --chewing-cycle <hz>        Jaw cycle rate (default 1.5).
        --swallowing <events/min>   Stereotyped posterior-neck bursts.
        --swallowing-amplitude <uv> Default 120 RMS.
        --swallowing-duration <s>   Default 1.
        --cable-movement <events/min>  Broad low-frequency cable sway.
        --cable-amplitude <uv>      Default 150.
        --cable-duration <s>        Default 3.
        --sweat <episodes/min>      Very-low-frequency local drift.
        --sweat-amplitude <uv>      Default 100.
        --sweat-duration <s>        Default 15.
        --sweat-channels <n>        Channels per episode (default 1).
        --bridge <a:b,...>          Make channel pairs share their averaged signal.
        --bad-reference <uv>        Common 0.2-30 Hz reference contamination.
        --clip <uv>                 Apply symmetric hard amplifier rails.
        --no-chewing/--no-swallowing/--no-cable-movement/--no-sweat
        --no-bridges/--no-bad-reference/--no-clipping
                                    Disable the corresponding scenario artifact.

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
        --with-impedance            Enable measurements if a scenario disables them.
        --no-impedance              Record no impedance measurement at all.
        --with-impedance-noise      Couple contact impedance to thermal/mains noise.
        --no-impedance-noise        Restore decorative, measurement-only impedance.
        --electrode-temperature <K> Johnson-noise temperature (default 298.15 K).
        --impedance-line-exponent <x>
                                    Mains scaling exponent (default 1, linear).

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
        --with-ecg                  Enable ECG if a scenario disables it.
        --no-motion-sensor          Omit the synthetic motion-sensor channel.
        --with-motion-sensor        Enable it if a scenario disables it.
        --spatial-model <name>      circular (the paper's, default) or geometric
                                    (smooth by real electrode distance — prefer
                                    this for demos and topography). Grouiller
                                    model only; dipole mode uses its lead field.
        --spatial-smoothing <n>     Kernel width in channels (default 4).
        --demo                      Preset for teaching recordings: blinks, eye
                                    movements, 60 Hz line noise, geometric
                                    spatial model, pre/post-scan quiet, and two
                                    bad channels. Any explicit flag still wins.

    correct — apply PCA surrogate BCG separation to an MFF recording

        --input <noisy.mff>         Recording to correct. Required.
        --output <corrected.mff>    Corrected recording to write. Required.
        --truth <truth.json>        Use the simulation reference/source truth.
        --coordinates <path>       Override the input recording's coordinates
                                    with coordinates.xml or another MFF package.
        --assume-standard-montage  Explicitly allow the built-in montage when
                                    no valid coordinates.xml is available.
        --pattern-search <mode>     paper (default) or iterative.
        --representative-beat <n>   Optional 1-based candidate beat selected for
                                    paper mode; otherwise median-energy is used.
        --report <json>             Write filter construction and provenance.

    evaluate-surrogate — repeated-seed PCA-S evaluation

        --config <scenario.json>    Base scenario; AEP evaluation needs placed ERP.
        --seeds <n>                 Repeated realizations per condition (default 5).
        --offsets <mm,...>          Surrogate-basis mismatch sweep.
        --pattern-search <mode>     paper (default) or iterative.
        --representative-beat <n>   Optional 1-based paper-mode candidate beat.
        --with-erp                  Report accepted trials, ERP SNR, peak errors,
                                    and explained variance against clean truth.
        --json                      Emit full statistics and per-seed values.

    score — reports waveform, spectral, band, and channel fidelity against truth

        --truth <clean.mff>         Ground-truth recording from `generate`. Required.
        --corrected <file.mff>      The recording after correction. Required.
        --baseline <noisy.mff>      Also score the uncorrected recording, so the
                                    table shows what the correction actually bought.
        --label <name>              Name for this correction in the output.
        --pad-seconds <s>           Ignore this much at each end (default 2).
        --csv <path>                Also write the per-band table as CSV.
        --json <path>               Also write the full result as JSON.

    score-sources — score inverse locations and/or recovered source signals

        --truth <truth.json>        Dipole simulation truth sidecar. Required.
        --estimated <json>          Estimated source locations. JSON object with
                                    a `sources` array; each item has
                                    `positionMeters` and optional `id` and
                                    `orientation` (x/y/z objects).
        --recovered <mff>           Recovered ICA/source signals as MFF channels.
                                    Assignment is sign- and order-invariant.
        --pad-seconds <s>           Ignore this much at each signal end (default 0).
        --json <path>               Write machine-readable location/recovery scores.

    score-events — score artifact/event detection against simulation truth

        --truth <truth.json>        Simulation truth sidecar. Required.
        --detected <json-or-mff>    JSON events or an MFF carrying detected markers.
        --type <name>               gradient, bcg, blink, saccade, emg, chewing,
                                    swallowing, movement, or sweat.
        --event-code <code>         Override the corresponding MFF marker code.
        --tolerance-ms <ms>         Maximum one-to-one timing error.
        --json <path>               Write the full score and optional ROC curve.

    score-erp — score recovered ERP peak amplitude and latency

        --truth <json>              True component set or array.
        --estimated <json>          Recovered component set or array, matched by id.
        --level <name>              average (default) or non-omitted trial truth.
        --exclude-overlap           With --level trial, score only trials whose
                                    component windows do not overlap another.
        --json <path>               Write machine-readable bias/MAE/RMSE metrics.

    score-pac — score recovered phase-amplitude coupling parameters

        --truth <truth.json>        Simulation truth sidecar with PAC enabled.
        --estimated <json>          Object with `strength` and
                                    `preferredPhaseRadians`.
        --json <path>               Write strength and circular-phase errors.

    sweep — one `generate` per value of a swept parameter

        --parameter <name>          One of: qrs-jitter, bcg-amplitude,
                                    gradient-amplitude, slow-modulation,
                                    clock-offset, rate, impedance, sources,
                                    emg-rate, emg-amplitude.
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
    "config", "write-config", "output", "channels", "coordinates", "no-coordinates",
    "rate", "duration", "seed",
    "with-gradient", "no-gradient", "tr", "slices", "gradient-amplitude", "gradient-amplitude-min",
    "clock-offset", "slow-modulation", "gradient-template", "gradient-template-rate",
    "no-gradient-template", "with-bcg", "no-bcg", "bcg-amplitude", "bcg-model", "bcg-field-strength",
    "bcg-morphology-jitter", "bcg-generator-scales", "qrs-jitter", "heart-rate-min", "heart-rate-max",
    "hrv", "respiration",
    "alpha-low", "alpha-high", "eeg-std", "eeg-model", "sources", "source-depth",
    "source-orientations", "lead-field-terms", "source-correlation", "reference",
    "near-source-separation", "source-motion", "source-motion-start",
    "source-motion-transition", "write-sources", "spatial-model", "spatial-smoothing",
    "with-nonstationarity", "no-nonstationarity", "alpha-bursts",
    "alpha-burst-duration", "no-alpha-bursts", "spectral-variation",
    "spectral-timescale", "no-spectral-dynamics", "microstates",
    "microstate-dwell", "microstate-amplitude", "no-microstates",
    "pac", "pac-low", "pac-band", "pac-phase", "no-pac",
    "with-erp", "no-erp", "erp-trials", "erp-isi", "erp-isi-jitter",
    "erp-target-fraction", "erp-latency", "erp-latency-jitter", "erp-latency-skew",
    "erp-amplitude", "erp-standard-ratio", "erp-amplitude-jitter",
    "erp-latency-amplitude-correlation", "erp-omission-rate", "erp-waveform",
    "erp-width", "erp-template", "erp-template-rate",
    "artifact-oversample", "artifact-anti-alias", "with-ecg", "no-ecg",
    "with-motion-sensor", "no-motion-sensor", "with-impedance",
    "with-impedance-noise", "no-impedance-noise", "electrode-temperature",
    "impedance-line-exponent",
    "prefix", "pre-scan", "post-scan",
    "blinks", "blink-amplitude", "eye-movements", "eye-movement-amplitude", "ocular-model",
    "with-emg", "no-emg", "emg", "emg-amplitude", "emg-duration", "emg-low", "emg-high",
    "chewing", "chewing-amplitude", "chewing-duration", "chewing-cycle", "no-chewing",
    "swallowing", "swallowing-amplitude", "swallowing-duration", "no-swallowing",
    "cable-movement", "cable-amplitude", "cable-duration", "no-cable-movement",
    "sweat", "sweat-amplitude", "sweat-duration", "sweat-channels", "no-sweat",
    "bridge", "no-bridges", "bad-reference", "no-bad-reference", "clip", "no-clipping",
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

nonisolated struct ImportedMontageResolution {
    var montage: Montage
    var sourceDescription: String
    var sourcePath: String
}

/// Loads a standalone coordinates.xml or an MFF/package containing one and
/// aligns it to the EEG channel order. For an MFF source, names from its EEG
/// descriptor take precedence over names embedded in coordinates.xml.
func importedMontage(
    path: String,
    channelCount: Int,
    signalChannelNames: [String]? = nil
) throws -> ImportedMontageResolution {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard let geometry = ElectrodeGeometry.load(from: url) else {
        throw SimulateError.io(
            "could not load EEG coordinates from \(url.path); expected coordinates.xml "
                + "or an MFF/package directory containing it"
        )
    }

    var names = signalChannelNames
    var source = "standalone coordinates.xml"
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
       isDirectory.boolValue {
        source = "MFF/package coordinates.xml"
        if names == nil, let signal = try? MFFReader().loadSignal(from: url) {
            names = signal.channelNames
        }
    }

    do {
        return ImportedMontageResolution(
            montage: try Montage.fromGeometry(
                geometry, channelCount: channelCount, signalChannelNames: names
            ),
            sourceDescription: source,
            sourcePath: url.path
        )
    } catch {
        throw SimulateError.usage("invalid imported montage at \(url.path): \(error.localizedDescription)")
    }
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

func parseChannelBridges(_ spec: String) throws -> [ChannelBridge] {
    try spec.split(separator: ",").map { entry in
        let parts = entry.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let first = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let second = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              first > 0, second > 0, first != second else {
            throw SimulateError.usage(
                "--bridge entry \"\(entry)\" must be two distinct 1-based channels, e.g. 3:4"
            )
        }
        return ChannelBridge(firstChannel: first, secondChannel: second)
    }
}

func makeConfig(_ arguments: Arguments) throws -> SimulationConfig {
    var config: SimulationConfig
    if let path = arguments.string("config") {
        guard !arguments.flag("config") else {
            throw SimulateError.usage("--config needs a JSON file path")
        }
        config = try SimulationScenarioFile.load(
            from: URL(fileURLWithPath: path)
        ).config
    } else {
        config = SimulationConfig.default
    }

    // `--demo` is a preset, applied after a scenario but before individual
    // flags, so every explicit model flag remains the final authority.
    // It exists because the settings that make a good teaching recording are not
    // the settings that reproduce the paper, and asking someone to remember six
    // flags to get a usable classroom file is a good way to have them not bother.
    if arguments.flag("demo") {
        config.blinksPerMinute = 15
        config.saccadesPerMinute = 25
        config.emg = EMGConfig()
        config.lineNoiseHz = 60
        config.spatialModel = .geometric
        config.preScanSeconds = 15
        config.postScanSeconds = 10
        config.badChannels = [7: .noisy, 15: .drift]
    }

    if let value = try arguments.int("channels") { config.channelCount = value }
    if arguments.flag("no-coordinates") { config.coordinatesPath = nil }
    if let path = arguments.string("coordinates") {
        guard !arguments.flag("coordinates") else {
            throw SimulateError.usage("--coordinates needs a coordinates.xml or MFF path")
        }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        config.coordinatesPath = canonical
        if arguments.string("channels") == nil {
            guard let geometry = ElectrodeGeometry.load(from: URL(fileURLWithPath: canonical)) else {
                throw SimulateError.io(
                    "could not load EEG coordinates from \(canonical); expected coordinates.xml "
                        + "or an MFF/package directory containing it"
                )
            }
            config.channelCount = geometry.positions.count
        }
    }
    if let value = try arguments.double("rate") { config.samplingRate = value }
    if let value = try arguments.double("duration") { config.durationSeconds = value }
    if let value = try arguments.uint64("seed") { config.seed = value }

    if arguments.flag("with-gradient") { config.gradientEnabled = true }
    if arguments.flag("no-gradient") { config.gradientEnabled = false }
    if let value = try arguments.double("tr") { config.repetitionTimeSeconds = value }
    if let value = try arguments.int("slices") { config.slicesPerVolume = value }
    if let value = try arguments.double("gradient-amplitude") { config.gradientAmplitudeMaxMicrovolts = value }
    if let value = try arguments.double("gradient-amplitude-min") { config.gradientAmplitudeMinMicrovolts = value }
    if let value = try arguments.double("clock-offset") { config.clockOffsetMicrosecondsPerSecond = value }
    if let value = try arguments.double("slow-modulation") { config.slowModulationFraction = value }
    if arguments.flag("no-gradient-template") {
        config.gradientTemplatePath = nil
        config.gradientTemplateRateHz = nil
    }
    if let path = arguments.string("gradient-template") {
        // Resolve command-line asset paths now so a simultaneously written
        // scenario reproduces this run even if that JSON is saved elsewhere.
        config.gradientTemplatePath = URL(fileURLWithPath: path).standardizedFileURL.path
    }
    if let value = try arguments.double("gradient-template-rate") {
        config.gradientTemplateRateHz = value
    }

    if arguments.flag("with-bcg") { config.bcgEnabled = true }
    if arguments.flag("no-bcg") { config.bcgEnabled = false }
    if let value = try arguments.double("bcg-amplitude") { config.bcgAmplitudeMicrovolts = value }
    if let raw = arguments.string("bcg-model") {
        guard let model = BCGSpatialModel(rawValue: raw) else {
            throw SimulateError.usage(
                "unknown --bcg-model '\(raw)'; expected channelIndex or generators"
            )
        }
        config.bcgSpatialModel = model
    }
    if let value = try arguments.double("bcg-field-strength") {
        guard value > 0 else {
            throw SimulateError.usage("--bcg-field-strength must be positive")
        }
        config.bcgFieldStrengthTesla = value
    }
    if let value = try arguments.double("bcg-morphology-jitter") {
        guard value >= 0 else {
            throw SimulateError.usage("--bcg-morphology-jitter cannot be negative")
        }
        config.bcgMorphologyJitterFraction = value
    }
    if let raw = arguments.string("bcg-generator-scales") {
        let values = try raw.split(separator: ",").map { token -> Double in
            guard let value = Double(token.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                throw SimulateError.usage("--bcg-generator-scales expects four non-negative numbers")
            }
            return value
        }
        guard values.count == 4, values.contains(where: { $0 > 0 }) else {
            throw SimulateError.usage("--bcg-generator-scales expects four values with at least one above zero")
        }
        config.bcgGeneratorAmplitudeScales = values
    }
    if let value = try arguments.double("qrs-jitter") { config.qrsDetectionJitterSDSeconds = value / 1000 }
    if let value = try arguments.double("heart-rate-min") { config.heartRateMinBPM = value }
    if let value = try arguments.double("heart-rate-max") { config.heartRateMaxBPM = value }
    if let value = try arguments.double("hrv") { config.heartRateVariability = value }
    if let value = try arguments.double("respiration") { config.respirationHz = value }

    if let value = try arguments.double("alpha-low") { config.alphaLowMicrovolts = value }
    if let value = try arguments.double("alpha-high") { config.alphaHighMicrovolts = value }
    if let value = try arguments.double("eeg-std") { config.eegTargetStdMicrovolts = value }
    if let raw = arguments.string("reference") {
        guard let reference = EEGReference(rawValue: raw) else {
            throw SimulateError.usage("--reference expects average or infinity, got \"\(raw)\"")
        }
        config.recordingReference = reference
    }
    if let raw = arguments.string("eeg-model") {
        guard let model = EEGGenerationModel(rawValue: raw) else {
            throw SimulateError.usage("--eeg-model expects grouiller or dipole, got \"\(raw)\"")
        }
        config.eegGenerationModel = model
    }
    if let value = try arguments.int("sources") { config.dipoleSourceCount = value }
    if let value = try arguments.double("source-depth") { config.dipoleSourceRadiusFraction = value }
    if let raw = arguments.string("source-orientations") {
        guard let pattern = DipoleOrientationPattern(rawValue: raw) else {
            throw SimulateError.usage(
                "--source-orientations expects radial, tangential, mixed, or free, got \"\(raw)\""
            )
        }
        config.dipoleOrientationPattern = pattern
    }
    if let value = try arguments.int("lead-field-terms") { config.leadFieldTerms = value }
    if let value = try arguments.double("source-correlation") {
        config.dipoleSourceCorrelation = value
    }
    if let value = try arguments.double("near-source-separation") {
        config.dipoleNearPairSeparationDegrees = value
    }
    if let value = try arguments.double("source-motion") { config.dipoleMotionDegrees = value }
    if let value = try arguments.double("source-motion-start") {
        config.dipoleMotionStartFraction = value
    }
    if let value = try arguments.double("source-motion-transition") {
        config.dipoleMotionTransitionFraction = value
    }
    if let value = try arguments.double("spatial-smoothing") { config.spatialSmoothingChannels = value }
    if let raw = arguments.string("spatial-model") {
        guard let model = SpatialModel(rawValue: raw) else {
            throw SimulateError.usage("--spatial-model expects circular or geometric, got \"\(raw)\"")
        }
        config.spatialModel = model
    }

    var nonstationarity = config.neuralNonstationarity ?? NeuralNonstationarityConfig()
    var nonstationarityChanged = arguments.flag("with-nonstationarity")

    var alphaBursts = nonstationarity.alphaBursts ?? AlphaBurstConfig()
    var alphaBurstsChanged = false
    if let value = try arguments.double("alpha-bursts") {
        alphaBursts.burstsPerMinute = value; alphaBurstsChanged = true
    }
    if let value = try arguments.double("alpha-burst-duration") {
        alphaBursts.meanDurationSeconds = value; alphaBurstsChanged = true
    }
    if arguments.flag("no-alpha-bursts") {
        nonstationarity.alphaBursts = nil; nonstationarityChanged = true
    } else if alphaBurstsChanged {
        nonstationarity.alphaBursts = alphaBursts; nonstationarityChanged = true
    }

    var spectra = nonstationarity.spectralDynamics ?? SpectralDynamicsConfig()
    var spectraChanged = false
    if let value = try arguments.double("spectral-variation") {
        spectra.logAmplitudeSD = value; spectraChanged = true
    }
    if let value = try arguments.double("spectral-timescale") {
        spectra.timeConstantSeconds = value; spectraChanged = true
    }
    if arguments.flag("no-spectral-dynamics") {
        nonstationarity.spectralDynamics = nil; nonstationarityChanged = true
    } else if spectraChanged {
        nonstationarity.spectralDynamics = spectra; nonstationarityChanged = true
    }

    var microstates = nonstationarity.microstates ?? MicrostateConfig()
    var microstatesChanged = false
    if let value = try arguments.int("microstates") {
        microstates.stateCount = value; microstatesChanged = true
    }
    if let value = try arguments.double("microstate-dwell") {
        microstates.meanDwellSeconds = value / 1_000; microstatesChanged = true
    }
    if let value = try arguments.double("microstate-amplitude") {
        microstates.amplitudeMicrovolts = value; microstatesChanged = true
    }
    if arguments.flag("no-microstates") {
        nonstationarity.microstates = nil; nonstationarityChanged = true
    } else if microstatesChanged {
        nonstationarity.microstates = microstates; nonstationarityChanged = true
    }

    var pac = nonstationarity.phaseAmplitudeCoupling ?? PhaseAmplitudeCouplingConfig()
    var pacChanged = false
    if let value = try arguments.double("pac") { pac.strength = value; pacChanged = true }
    if let value = try arguments.double("pac-low") { pac.phaseFrequencyHz = value; pacChanged = true }
    if let value = arguments.string("pac-band") { pac.targetBandName = value; pacChanged = true }
    if let value = try arguments.double("pac-phase") {
        pac.preferredPhaseRadians = value * Double.pi / 180; pacChanged = true
    }
    if arguments.flag("no-pac") {
        nonstationarity.phaseAmplitudeCoupling = nil; nonstationarityChanged = true
    } else if pacChanged {
        nonstationarity.phaseAmplitudeCoupling = pac; nonstationarityChanged = true
    }

    if arguments.flag("no-nonstationarity") {
        config.neuralNonstationarity = nil
    } else if nonstationarityChanged {
        config.neuralNonstationarity = nonstationarity
    }

    if let value = try arguments.double("pre-scan") { config.preScanSeconds = value }
    if let value = try arguments.double("post-scan") { config.postScanSeconds = value }

    if let value = try arguments.double("blinks") { config.blinksPerMinute = value }
    if let value = try arguments.double("blink-amplitude") { config.blinkAmplitudeMicrovolts = value }
    if let value = try arguments.double("eye-movements") { config.saccadesPerMinute = value }
    if let value = try arguments.double("eye-movement-amplitude") { config.eyeMovementAmplitudeMicrovolts = value }
    if let raw = arguments.string("ocular-model") {
        guard let model = OcularSpatialModel(rawValue: raw) else {
            throw SimulateError.usage("--ocular-model expects heuristic or dipole, got \"\(raw)\"")
        }
        config.ocularSpatialModel = model
    }

    var emg = config.emg ?? EMGConfig()
    var emgChanged = arguments.flag("with-emg")
    if let value = try arguments.double("emg") {
        emg.burstsPerMinute = value
        emgChanged = true
    }
    if let value = try arguments.double("emg-amplitude") {
        emg.amplitudeMicrovolts = value
        emgChanged = true
    }
    if let value = try arguments.double("emg-duration") {
        emg.burstDurationSeconds = value
        emgChanged = true
    }
    if let value = try arguments.double("emg-low") {
        emg.lowHz = value
        emgChanged = true
    }
    if let value = try arguments.double("emg-high") {
        emg.highHz = value
        emgChanged = true
    }
    if arguments.flag("no-emg") {
        config.emg = nil
    } else if emgChanged {
        config.emg = emg
    }

    var chewing = config.chewing ?? ChewingConfig()
    var chewingChanged = false
    if let value = try arguments.double("chewing") { chewing.episodesPerMinute = value; chewingChanged = true }
    if let value = try arguments.double("chewing-amplitude") { chewing.amplitudeMicrovolts = value; chewingChanged = true }
    if let value = try arguments.double("chewing-duration") { chewing.durationSeconds = value; chewingChanged = true }
    if let value = try arguments.double("chewing-cycle") { chewing.cycleHz = value; chewingChanged = true }
    if arguments.flag("no-chewing") { config.chewing = nil }
    else if chewingChanged { config.chewing = chewing }

    var swallowing = config.swallowing ?? SwallowingConfig()
    var swallowingChanged = false
    if let value = try arguments.double("swallowing") { swallowing.eventsPerMinute = value; swallowingChanged = true }
    if let value = try arguments.double("swallowing-amplitude") { swallowing.amplitudeMicrovolts = value; swallowingChanged = true }
    if let value = try arguments.double("swallowing-duration") { swallowing.durationSeconds = value; swallowingChanged = true }
    if arguments.flag("no-swallowing") { config.swallowing = nil }
    else if swallowingChanged { config.swallowing = swallowing }

    var cable = config.cableMovement ?? CableMovementConfig()
    var cableChanged = false
    if let value = try arguments.double("cable-movement") { cable.eventsPerMinute = value; cableChanged = true }
    if let value = try arguments.double("cable-amplitude") { cable.amplitudeMicrovolts = value; cableChanged = true }
    if let value = try arguments.double("cable-duration") { cable.durationSeconds = value; cableChanged = true }
    if arguments.flag("no-cable-movement") { config.cableMovement = nil }
    else if cableChanged { config.cableMovement = cable }

    var sweat = config.sweat ?? SweatConfig()
    var sweatChanged = false
    if let value = try arguments.double("sweat") { sweat.episodesPerMinute = value; sweatChanged = true }
    if let value = try arguments.double("sweat-amplitude") { sweat.amplitudeMicrovolts = value; sweatChanged = true }
    if let value = try arguments.double("sweat-duration") { sweat.durationSeconds = value; sweatChanged = true }
    if let value = try arguments.int("sweat-channels") { sweat.affectedChannelCount = value; sweatChanged = true }
    if arguments.flag("no-sweat") { config.sweat = nil }
    else if sweatChanged { config.sweat = sweat }

    if arguments.flag("no-bridges") { config.bridgedChannelPairs = nil }
    else if let spec = arguments.string("bridge") {
        config.bridgedChannelPairs = try parseChannelBridges(spec)
    }
    if arguments.flag("no-bad-reference") { config.badReference = nil }
    else if let value = try arguments.double("bad-reference") {
        var reference = config.badReference ?? BadReferenceConfig()
        reference.amplitudeMicrovolts = value
        config.badReference = reference
    }
    if arguments.flag("no-clipping") { config.clippingThresholdMicrovolts = nil }
    else if let value = try arguments.double("clip") {
        config.clippingThresholdMicrovolts = value
    }

    var erp = config.erp ?? ERPConfig()
    var erpChanged = arguments.flag("with-erp")
    if let value = try arguments.int("erp-trials") { erp.trialCount = value; erpChanged = true }
    if let value = try arguments.double("erp-isi") { erp.interStimulusIntervalSeconds = value; erpChanged = true }
    if let value = try arguments.double("erp-isi-jitter") { erp.interStimulusJitterSeconds = value; erpChanged = true }
    if let value = try arguments.double("erp-target-fraction") { erp.targetFraction = value; erpChanged = true }
    if let value = try arguments.double("erp-latency") { erp.peakLatencySeconds = value / 1000; erpChanged = true }
    if let value = try arguments.double("erp-latency-jitter") { erp.latencyJitterSDSeconds = value / 1000; erpChanged = true }
    if let value = try arguments.double("erp-latency-skew") { erp.latencySkew = value; erpChanged = true }
    if let value = try arguments.double("erp-amplitude") { erp.targetAmplitudeMicrovolts = value; erpChanged = true }
    if let value = try arguments.double("erp-standard-ratio") { erp.standardAmplitudeRatio = value; erpChanged = true }
    if let value = try arguments.double("erp-amplitude-jitter") { erp.amplitudeJitterFraction = value; erpChanged = true }
    if let value = try arguments.double("erp-latency-amplitude-correlation") {
        erp.latencyAmplitudeCorrelation = value; erpChanged = true
    }
    if let value = try arguments.double("erp-omission-rate") { erp.omissionRate = value; erpChanged = true }
    if let raw = arguments.string("erp-waveform") {
        guard let waveform = ERPWaveformKind(rawValue: raw), waveform != .measured else {
            throw SimulateError.usage("--erp-waveform expects gaussian or biphasic")
        }
        erp.waveform = waveform; erpChanged = true
    }
    if let value = try arguments.double("erp-width") { erp.widthSeconds = value / 1000; erpChanged = true }
    if let path = arguments.string("erp-template") {
        erp.measuredTemplatePath = URL(fileURLWithPath: path).standardizedFileURL.path
        erp.waveform = .measured
        erpChanged = true
    }
    if let value = try arguments.double("erp-template-rate") {
        erp.measuredTemplateRateHz = value; erpChanged = true
    }
    if arguments.flag("no-erp") {
        config.erp = nil
    } else if erpChanged {
        config.erp = erp
    }

    if let spec = arguments.string("bad-channels") { config.badChannels = try parseBadChannels(spec) }
    if let value = try arguments.double("line-noise") { config.lineNoiseHz = value }
    if let value = try arguments.double("line-noise-amplitude") { config.lineNoiseAmplitudeMicrovolts = value }
    if arguments.flag("with-impedance") { config.includeImpedance = true }
    if arguments.flag("no-impedance") { config.includeImpedance = false }
    if let value = try arguments.double("impedance") {
        guard value > 0 else { throw SimulateError.usage("--impedance must be positive") }
        config.includeImpedance = true
        config.impedanceTypicalKOhm = value
    }
    if arguments.flag("with-impedance-noise") {
        config.impedanceNoise = config.impedanceNoise ?? ImpedanceNoiseConfig()
    }
    if arguments.flag("no-impedance-noise") { config.impedanceNoise = nil }
    if let value = try arguments.double("electrode-temperature") {
        var model = config.impedanceNoise ?? ImpedanceNoiseConfig()
        model.temperatureKelvin = value
        config.impedanceNoise = model
    }
    if let value = try arguments.double("impedance-line-exponent") {
        var model = config.impedanceNoise ?? ImpedanceNoiseConfig()
        model.lineNoiseImpedanceExponent = value
        config.impedanceNoise = model
    }

    if let value = try arguments.int("artifact-oversample") { config.artifactOversampleFactor = value }
    if let value = try arguments.double("artifact-anti-alias") { config.artifactAntiAliasFraction = value }
    if arguments.flag("with-ecg") { config.includeECG = true }
    if arguments.flag("no-ecg") { config.includeECG = false }
    if arguments.flag("with-motion-sensor") { config.includeMotionSensor = true }
    if arguments.flag("no-motion-sensor") { config.includeMotionSensor = false }

    guard config.channelCount > 0 else { throw SimulateError.usage("--channels must be positive") }
    if let path = config.coordinatesPath {
        _ = try importedMontage(path: path, channelCount: config.channelCount)
    }
    guard config.samplingRate > 0 else { throw SimulateError.usage("--rate must be positive") }
    // Checked here rather than at write time: MFF stores an integer sample rate,
    // and finding that out after generating three minutes of data wastes the run.
    guard config.samplingRate == config.samplingRate.rounded() else {
        throw SimulateError.usage(
            "--rate must be a whole number of hertz (MFF stores an integer sample rate), got \(config.samplingRate)"
        )
    }
    guard config.durationSeconds > 0 else { throw SimulateError.usage("--duration must be positive") }
    if let model = config.impedanceNoise {
        guard model.temperatureKelvin > 0 else {
            throw SimulateError.usage("--electrode-temperature must be positive")
        }
        guard model.lineNoiseImpedanceExponent >= 0,
              model.lineNoiseImpedanceExponent <= 2 else {
            throw SimulateError.usage("--impedance-line-exponent must be between 0 and 2")
        }
        guard model.maximumLineNoiseScale >= 1 else {
            throw SimulateError.usage("impedance maximumLineNoiseScale must be at least 1")
        }
        guard (model.referenceImpedanceKOhm ?? 12) > 0 else {
            throw SimulateError.usage("impedance referenceImpedanceKOhm must be positive")
        }
    }
    if config.gradientTemplatePath != nil {
        guard let rate = config.gradientTemplateRateHz, rate > 0 else {
            throw SimulateError.usage(
                "a measured gradient template needs a positive --gradient-template-rate"
            )
        }
    } else if config.gradientTemplateRateHz != nil {
        throw SimulateError.usage(
            "--gradient-template-rate needs --gradient-template (or a template in the loaded scenario)"
        )
    }
    guard !config.eegBands.isEmpty else { throw SimulateError.usage("EEG needs at least one frequency band") }
    guard config.dipoleSourceCount > 0 else { throw SimulateError.usage("--sources must be positive") }
    guard config.dipoleSourceRadiusFraction > 0, config.dipoleSourceRadiusFraction < 1 else {
        throw SimulateError.usage("--source-depth must be greater than 0 and less than 1")
    }
    guard config.leadFieldTerms >= 1 else { throw SimulateError.usage("--lead-field-terms must be positive") }
    guard abs(config.dipoleSourceCorrelation) <= 0.99 else {
        throw SimulateError.usage("--source-correlation must be between -0.99 and 0.99")
    }
    if abs(config.dipoleSourceCorrelation) > 0, config.dipoleSourceCount < 2 {
        throw SimulateError.usage("--source-correlation needs at least two sources")
    }
    guard config.dipoleNearPairSeparationDegrees >= 0,
          config.dipoleNearPairSeparationDegrees < 45 else {
        throw SimulateError.usage("--near-source-separation must be from 0 up to (but not including) 45 degrees")
    }
    if config.dipoleNearPairSeparationDegrees > 0, config.dipoleSourceCount < 2 {
        throw SimulateError.usage("--near-source-separation needs at least two sources")
    }
    guard config.dipoleMotionDegrees >= 0, config.dipoleMotionDegrees < 180 else {
        throw SimulateError.usage("--source-motion must be from 0 up to (but not including) 180 degrees")
    }
    guard config.dipoleMotionStartFraction >= 0, config.dipoleMotionStartFraction < 1 else {
        throw SimulateError.usage("--source-motion-start must be at least 0 and below 1")
    }
    guard config.dipoleMotionTransitionFraction >= 0,
          config.dipoleMotionStartFraction + config.dipoleMotionTransitionFraction <= 1 else {
        throw SimulateError.usage("source motion must finish within the recording")
    }
    if let error = config.sphericalHeadModel.validationError() {
        throw SimulateError.usage("invalid spherical head model: \(error)")
    }
    if let model = config.neuralNonstationarity {
        if let bursts = model.alphaBursts {
            guard bursts.burstsPerMinute > 0, bursts.meanDurationSeconds > 0,
                  bursts.durationSDSeconds >= 0,
                  (0...1).contains(bursts.backgroundFraction) else {
                throw SimulateError.usage(
                    "alpha-burst rate/duration must be positive, duration SD non-negative, and background 0...1"
                )
            }
            guard config.eegBands.contains(where: \.isAlpha) else {
                throw SimulateError.usage("alpha bursts require an EEG band with nil amplitudeMicrovolts")
            }
        }
        if let spectra = model.spectralDynamics {
            guard spectra.logAmplitudeSD > 0, spectra.timeConstantSeconds > 0,
                  spectra.updateIntervalSeconds > 0 else {
                throw SimulateError.usage("spectral variation, timescale, and update interval must be positive")
            }
        }
        if let microstates = model.microstates {
            guard microstates.stateCount >= 2, microstates.meanDwellSeconds > 0,
                  microstates.minimumDwellSeconds > 0,
                  microstates.maximumDwellSeconds >= microstates.meanDwellSeconds,
                  microstates.meanDwellSeconds >= microstates.minimumDwellSeconds,
                  microstates.transitionSeconds >= 0,
                  microstates.transitionSeconds <= microstates.minimumDwellSeconds,
                  microstates.amplitudeMicrovolts > 0 else {
                throw SimulateError.usage("microstates need >=2 states, ordered positive dwell bounds, and positive amplitude")
            }
            guard microstates.carrierLowHz >= 0,
                  microstates.carrierHighHz > microstates.carrierLowHz,
                  microstates.carrierHighHz < config.samplingRate / 2 else {
                throw SimulateError.usage("microstate carrier band must be ordered and below Nyquist")
            }
        }
        if let pac = model.phaseAmplitudeCoupling {
            guard pac.strength >= 0, pac.strength <= 0.99,
                  pac.phaseFrequencyHz > 0, pac.phaseCarrierFraction >= 0 else {
                throw SimulateError.usage("PAC strength must be 0...0.99; phase frequency positive; carrier non-negative")
            }
            guard config.eegBands.contains(where: {
                $0.lowHz <= pac.phaseFrequencyHz && pac.phaseFrequencyHz < $0.highHz
            }) else {
                throw SimulateError.usage("--pac-low must fall inside one configured EEG band")
            }
            guard let target = config.eegBands.first(where: { $0.name == pac.targetBandName }) else {
                throw SimulateError.usage("--pac-band must name a configured EEG band")
            }
            guard target.lowHz > pac.phaseFrequencyHz else {
                throw SimulateError.usage("--pac-band must be above the phase frequency")
            }
        }
    }
    if let erp = config.erp {
        guard erp.trialCount > 0 else { throw SimulateError.usage("--erp-trials must be positive") }
        guard erp.startSeconds >= erp.interStimulusJitterSeconds,
              erp.interStimulusIntervalSeconds > 0,
              erp.interStimulusJitterSeconds >= 0,
              2 * erp.interStimulusJitterSeconds < erp.interStimulusIntervalSeconds else {
            throw SimulateError.usage(
                "ERP start must cover onset jitter; ISI must exceed twice its jitter"
            )
        }
        guard (0...1).contains(erp.targetFraction), (0...1).contains(erp.omissionRate) else {
            throw SimulateError.usage("ERP target fraction and omission rate must be from 0 to 1")
        }
        guard erp.peakLatencySeconds > 0, erp.latencyJitterSDSeconds >= 0,
              erp.widthSeconds > 0 else {
            throw SimulateError.usage("ERP latency/width must be positive and latency jitter non-negative")
        }
        guard erp.targetAmplitudeMicrovolts != 0, erp.standardAmplitudeRatio >= 0,
              erp.amplitudeJitterFraction >= 0 else {
            throw SimulateError.usage("ERP amplitude must be non-zero; ratio/jitter must be non-negative")
        }
        guard abs(erp.latencyAmplitudeCorrelation) <= 0.99 else {
            throw SimulateError.usage("ERP latency-amplitude correlation must be between -0.99 and 0.99")
        }
        let lastOnset = erp.startSeconds + Double(erp.trialCount - 1)
            * erp.interStimulusIntervalSeconds + erp.interStimulusJitterSeconds
        guard lastOnset < config.durationSeconds else {
            throw SimulateError.usage("ERP trial schedule does not fit inside the recording")
        }
        if erp.waveform == .measured {
            guard erp.measuredTemplatePath != nil,
                  let rate = erp.measuredTemplateRateHz, rate > 0 else {
                throw SimulateError.usage("a measured ERP template needs --erp-template-rate")
            }
        }
    }
    if let emg = config.emg {
        guard emg.burstsPerMinute > 0 else {
            throw SimulateError.usage("--emg must be positive; use --no-emg to disable it")
        }
        guard emg.amplitudeMicrovolts > 0, emg.burstDurationSeconds > 0 else {
            throw SimulateError.usage("EMG amplitude and duration must be positive")
        }
        guard emg.lowHz >= 0, emg.highHz > emg.lowHz else {
            throw SimulateError.usage("EMG high frequency must be greater than its non-negative low frequency")
        }
        guard emg.highHz < config.samplingRate / 2 else {
            throw SimulateError.usage(
                "--emg-high must be below Nyquist (\(config.samplingRate / 2) Hz at this sample rate)"
            )
        }
    }
    if let chewing = config.chewing {
        guard chewing.episodesPerMinute > 0, chewing.amplitudeMicrovolts > 0,
              chewing.durationSeconds > 0, chewing.cycleHz > 0 else {
            throw SimulateError.usage("chewing rate, amplitude, duration, and cycle must be positive")
        }
        guard chewing.lowHz >= 0, chewing.highHz > chewing.lowHz,
              chewing.highHz < config.samplingRate / 2 else {
            throw SimulateError.usage("chewing carrier band must be ordered and below Nyquist")
        }
    }
    if let swallowing = config.swallowing {
        guard swallowing.eventsPerMinute > 0, swallowing.amplitudeMicrovolts > 0,
              swallowing.durationSeconds > 0 else {
            throw SimulateError.usage("swallowing rate, amplitude, and duration must be positive")
        }
        guard swallowing.lowHz >= 0, swallowing.highHz > swallowing.lowHz,
              swallowing.highHz < config.samplingRate / 2 else {
            throw SimulateError.usage("swallowing carrier band must be ordered and below Nyquist")
        }
    }
    if let cable = config.cableMovement {
        guard cable.eventsPerMinute > 0, cable.amplitudeMicrovolts > 0,
              cable.durationSeconds > 0, cable.oscillationHz > 0 else {
            throw SimulateError.usage("cable-movement rate, amplitude, duration, and frequency must be positive")
        }
    }
    if let sweat = config.sweat {
        guard sweat.episodesPerMinute > 0, sweat.amplitudeMicrovolts > 0,
              sweat.durationSeconds > 0 else {
            throw SimulateError.usage("sweat rate, amplitude, and duration must be positive")
        }
        guard sweat.affectedChannelCount > 0,
              sweat.affectedChannelCount <= config.channelCount else {
            throw SimulateError.usage("--sweat-channels must be between 1 and the EEG channel count")
        }
    }
    if let pairs = config.bridgedChannelPairs {
        var used: Set<Int> = []
        for pair in pairs {
            guard pair.firstChannel > 0, pair.secondChannel > 0,
                  pair.firstChannel <= config.channelCount,
                  pair.secondChannel <= config.channelCount,
                  pair.firstChannel != pair.secondChannel else {
                throw SimulateError.usage("bridged channel pairs must name distinct channels in the montage")
            }
            guard !used.contains(pair.firstChannel), !used.contains(pair.secondChannel) else {
                throw SimulateError.usage("a channel may appear in only one --bridge pair")
            }
            used.insert(pair.firstChannel)
            used.insert(pair.secondChannel)
        }
    }
    if let reference = config.badReference {
        guard reference.amplitudeMicrovolts > 0, reference.lowHz >= 0,
              reference.highHz > reference.lowHz,
              reference.highHz < config.samplingRate / 2 else {
            throw SimulateError.usage("bad-reference amplitude/band must be positive, ordered, and below Nyquist")
        }
    }
    if let threshold = config.clippingThresholdMicrovolts, threshold <= 0 {
        throw SimulateError.usage("--clip must be positive")
    }
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

    // Canonicalize legacy scenarios that only carry `dipoleReference`. New
    // resolved scenarios then state the recording-wide convention explicitly.
    if config.recordingReference == nil {
        config.recordingReference = config.dipoleReference
    }

    return config
}

// MARK: - generate

@discardableResult
func runGenerate(config: SimulationConfig, arguments: Arguments, outputDirectory: URL) throws -> CorrectionScore {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let prefix = try normalizedPrefix(arguments.string("prefix") ?? "sim")

    // Preserve the legacy single stream exactly. Dipole mode deliberately uses
    // independent domains so changing source count cannot change an artifact.
    var legacySource = GaussianSource(seed: config.seed)
    var montage: Montage
    if let path = config.coordinatesPath {
        montage = try importedMontage(path: path, channelCount: config.channelCount).montage
    } else {
        montage = Montage.standard(count: config.channelCount)
    }
    if let jitter = config.montageJitterDegrees {
        montage = montage.jittered(
            degrees: jitter, seed: SimulationSeedStreams.montageJitter(base: config.seed)
        )
    }
    var leadFieldConvergence: LeadFieldConvergenceReport?
    // One check covers every lead field this run builds — the ERP's (its source
    // comes from `makeSources`, same radius fraction) and the moving-source
    // endpoint's (rotation preserves radius) — because **every source shares one
    // eccentricity**, and truncation error depends on r/R. The ocular model uses
    // a closed form and no series at all.
    //
    // Roadmap 4.3 ends that assumption: an explicitly placed ERP dipole can sit
    // deeper than the ongoing sources, and this check would silently stop
    // covering it. When 4.3 lands, move the check inside
    // `SphericalForwardModel.leadField` as an opt-in parameter so it travels
    // with every call site instead of being computed once here.
    if config.eegGenerationModel == .dipole {
        let sources = DipoleEEGGenerator.makeSources(config: config)
        let report = try SphericalForwardModel.convergenceReport(
            head: config.sphericalHeadModel,
            montage: montage,
            sources: sources,
            reference: config.effectiveRecordingReference,
            terms: config.leadFieldTerms
        )
        leadFieldConvergence = report
        if !report.converged {
            let source = report.worstSourceID ?? "unknown source"
            let axis = report.worstOrientationAxis ?? "?"
            let warning = String(
                format: "WARNING: lead field changes by %.4g between %d and %d terms "
                    + "(%@ %@ axis; tolerance %.4g). Increase --lead-field-terms.\n",
                report.maximumRelativeColumnChange, report.terms,
                report.comparisonTerms, source, axis, report.tolerance
            )
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }
    FileHandle.standardError.write(Data(
        "Generating EEG (\(config.channelCount) channels, \(montage.name), \(Int(config.durationSeconds)) s)...\n".utf8
    ))
    var eeg: GeneratedEEG
    switch config.eegGenerationModel {
    case .grouiller:
        eeg = EEGGenerator.generate(config: config, montage: montage, source: &legacySource)
    case .dipole:
        eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
    }

    let erp = try ERPGenerator.inject(into: &eeg.channels, config: config, montage: montage)

    var noisy = eeg.channels

    // Coupled impedance must exist before sample noise is generated. It is a
    // latent electrode property even when --no-impedance suppresses the ICAL
    // measurement in the MFF package.
    let coupledImpedances: [Float]?
    var thermalNoiseRMSMicrovolts = [Double](repeating: 0, count: config.channelCount)
    if config.impedanceNoise != nil {
        var impedanceSource = GaussianSource(seed: SimulationSeedStreams.impedance(base: config.seed))
        let realizedImpedances = ImpedanceModel.values(
            config: config, montage: montage, source: &impedanceSource
        )
        coupledImpedances = realizedImpedances
        var noiseSource = GaussianSource(seed: SimulationSeedStreams.impedanceNoise(base: config.seed))
        thermalNoiseRMSMicrovolts = ImpedanceModel.applyThermalNoise(
            to: &noisy, impedances: realizedImpedances, config: config, source: &noiseSource
        )
    } else {
        coupledImpedances = nil
    }

    var gradient: GradientInjection?
    if config.gradientEnabled {
        FileHandle.standardError.write(Data("Injecting gradient artifact...\n".utf8))
        var template: HighRateTemplate?
        if let path = config.gradientTemplatePath,
           let rate = config.gradientTemplateRateHz {
            template = try GradientArtifactModel.loadTemplate(
                path: path, templateRate: rate, config: config
            )
        }
        gradient = GradientArtifactModel.inject(into: &noisy, config: config, montage: montage, template: template)
    }

    var bcg: BCGInjection?
    var isolatedBCGSource = GaussianSource(seed: SimulationSeedStreams.bcg(base: config.seed))
    if config.bcgEnabled {
        FileHandle.standardError.write(Data("Injecting ballistocardiogram...\n".utf8))
        if config.eegGenerationModel == .grouiller {
            bcg = BCGArtifactModel.inject(
                into: &noisy, config: config, montage: montage, source: &legacySource
            )
        } else {
            bcg = BCGArtifactModel.inject(
                into: &noisy, config: config, montage: montage, source: &isolatedBCGSource
            )
        }
    }

    var ocular: OcularInjection?
    var isolatedOcularSource = GaussianSource(seed: SimulationSeedStreams.ocular(base: config.seed))
    if config.blinksPerMinute > 0 || config.saccadesPerMinute > 0 {
        FileHandle.standardError.write(Data("Injecting blinks and eye movements...\n".utf8))
        if config.eegGenerationModel == .grouiller {
            ocular = OcularArtifactModel.inject(
                into: &noisy, config: config, montage: montage, source: &legacySource
            )
        } else {
            ocular = OcularArtifactModel.inject(
                into: &noisy, config: config, montage: montage, source: &isolatedOcularSource
            )
        }
    }

    var emg: EMGInjection?
    if config.emg != nil {
        FileHandle.standardError.write(Data("Injecting muscle artifact...\n".utf8))
        var random = GaussianSource(seed: SimulationSeedStreams.emg(base: config.seed))
        emg = EMGArtifactModel.inject(
            into: &noisy, config: config, montage: montage, source: &random
        )
    }

    if config.chewing != nil || config.swallowing != nil || config.cableMovement != nil
        || config.sweat != nil || config.badReference != nil {
        FileHandle.standardError.write(Data("Injecting additional recording artifacts...\n".utf8))
    }
    var additional = AdditionalArtifactModel.injectAdditive(
        into: &noisy, config: config, montage: montage, includeBadReference: false
    )

    var lineNoiseGainsMicrovolts = [Double](repeating: 0, count: config.channelCount)
    if config.lineNoiseHz > 0 {
        if config.eegGenerationModel == .grouiller, coupledImpedances == nil {
            lineNoiseGainsMicrovolts = ChannelDefectModel.applyLineNoise(
                to: &noisy, config: config, source: &legacySource
            )
        } else {
            var random = GaussianSource(seed: SimulationSeedStreams.lineNoise(base: config.seed))
            lineNoiseGainsMicrovolts = ChannelDefectModel.applyLineNoise(
                to: &noisy, config: config, impedances: coupledImpedances, source: &random
            )
        }
    }

    // All additive neural, physiological, scanner, contact-noise, and mains
    // layers meet at this boundary and receive one declared reference. Physical
    // recording defects are applied below because they can legitimately break
    // the nominal reference after it was established.
    EEGReferencing.apply(config.effectiveRecordingReference, to: &eeg.channels)
    EEGReferencing.apply(config.effectiveRecordingReference, to: &noisy)
    eeg.standardDeviation = EEGGenerator.pooledStandardDeviation(eeg.channels)
    additional.badReferenceRMSMicrovolts = AdditionalArtifactModel.injectBadReference(
        into: &noisy, config: config
    )

    // Bad channels go last: a defect is something that happens to the recording
    // of a channel, on top of everything the channel was already carrying.
    let badChannels: [String: String]
    if config.eegGenerationModel == .grouiller {
        badChannels = ChannelDefectModel.apply(
            to: &noisy, config: config, impedances: coupledImpedances, source: &legacySource
        )
    } else {
        var random = GaussianSource(seed: SimulationSeedStreams.defects(base: config.seed))
        badChannels = ChannelDefectModel.apply(
            to: &noisy, config: config, impedances: coupledImpedances, source: &random
        )
    }

    if let pairs = config.bridgedChannelPairs {
        additional.bridgedChannelPairs = AdditionalArtifactModel.applyBridging(
            to: &noisy, pairs: pairs
        )
    }
    if let threshold = config.clippingThresholdMicrovolts {
        additional.clippedSampleCounts = AdditionalArtifactModel.applyClipping(
            to: &noisy, thresholdMicrovolts: threshold
        )
    }

    // Impedance is a property of the electrodes, not of the samples, so it is
    // written to *both* packages. That is not an oversight: EVA treats impedance
    // as a stable property of the recording and scores it independently of the
    // data, so the ground-truth file showing a poor electrode alongside perfect
    // samples is exactly the lesson — the measurement was taken before anything
    // was recorded.
    let impedances: [Float]?
    if !config.includeImpedance {
        impedances = nil
    } else if let coupledImpedances {
        impedances = coupledImpedances
    } else if config.eegGenerationModel == .grouiller {
        impedances = ImpedanceModel.values(config: config, montage: montage, source: &legacySource)
    } else {
        var random = GaussianSource(seed: SimulationSeedStreams.impedance(base: config.seed))
        impedances = ImpedanceModel.values(config: config, montage: montage, source: &random)
    }

    let cleanURL = outputDirectory.appendingPathComponent("\(prefix)_clean.mff")
    let noisyURL = outputDirectory.appendingPathComponent("\(prefix)_noisy.mff")
    let truthURL = outputDirectory.appendingPathComponent("\(prefix)_truth.json")
    let sourcesURL = outputDirectory.appendingPathComponent("\(prefix)_sources.mff")
    let events = SimulationWriter.events(
        gradient: gradient, bcg: bcg, ocular: ocular, erp: erp, emg: emg,
        additional: additional, config: config
    )

    var ecg: [Double]?
    var motion: [Double]?
    if let bcg {
        if config.includeECG {
            if config.eegGenerationModel == .grouiller {
                ecg = BCGArtifactModel.ecgChannel(
                    beats: bcg.trueBeatSeconds, rrIntervals: bcg.rrIntervalsSeconds,
                    config: config, source: &legacySource
                )
            } else {
                ecg = BCGArtifactModel.ecgChannel(
                    beats: bcg.trueBeatSeconds, rrIntervals: bcg.rrIntervalsSeconds,
                    config: config, source: &isolatedBCGSource
                )
            }
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

    if arguments.flag("write-sources") {
        guard let sourceSpace = eeg.sourceSpace else {
            throw SimulateError.usage("--write-sources requires --eeg-model dipole")
        }
        try MFFWriter.write(
            signal: SimulationWriter.signal(
                channels: sourceSpace.timecoursesNanoampereMeters,
                config: config,
                signalType: "Simulated Source Ground Truth (nA m)",
                events: [],
                packageURL: sourcesURL,
                names: sourceSpace.sources.map(\.id)
            ),
            segments: [],
            kind: .continuous,
            to: sourcesURL,
            preserveSourceFileInfo: false
        )
    }
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
        neuralNonstationarity: eeg.neuralNonstationarity,
        gradientVolumeOnsetsSeconds: gradient?.volumeOnsetsSeconds ?? [],
        gradientQuantizedVolumeOnsetsSeconds: gradient?.quantizedVolumeOnsetsSeconds ?? [],
        gradientChannelAmplitudesMicrovolts: gradient?.channelAmplitudesMicrovolts ?? [],
        bcgTrueBeatSeconds: bcg?.trueBeatSeconds ?? [],
        bcgDetectedBeatSeconds: bcg?.detectedBeatSeconds ?? [],
        bcgChannelScales: bcg?.channelScales ?? [],
        bcgChannelLatenciesSeconds: bcg?.channelLatenciesSeconds ?? [],
        bcgSpatialModel: bcg == nil ? nil : config.effectiveBCGSpatialModel.rawValue,
        bcgGenerators: bcg?.generatorSet?.generators,
        bcgNormalizedSingularValues: bcg?.generatorSet?.normalizedSingularValues,
        bcgSpatialRank: bcg?.generatorSet?.spatialRank,
        bcgFieldStrengthTesla: bcg?.generatorSet?.fieldStrengthTesla,
        montageName: montage.name,
        channelNames: montage.channelNames,
        recordingReference: config.effectiveRecordingReference,
        referenceApplicationStage: "after additive signal layers, before recording defects",
        badChannels: badChannels,
        blinkSeconds: ocular?.blinkSeconds ?? [],
        saccadeSeconds: ocular?.saccadeSeconds ?? [],
        blinkTopography: ocular?.blinkTopography ?? [],
        horizontalEyeTopography: ocular?.horizontalTopography ?? [],
        emgBursts: emg?.bursts,
        emgLeftTemporalisTopography: emg?.leftTemporalisTopography,
        emgRightTemporalisTopography: emg?.rightTemporalisTopography,
        emgPosteriorNeckTopography: emg?.posteriorNeckTopography,
        chewingEpisodes: additional.chewingEpisodes,
        swallowingEpisodes: additional.swallowingEpisodes,
        cableMovementEpisodes: additional.cableMovementEpisodes,
        sweatEpisodes: additional.sweatEpisodes,
        chewingTopography: additional.chewingTopography,
        swallowingTopography: additional.swallowingTopography,
        badReferenceRMSMicrovolts: additional.badReferenceRMSMicrovolts,
        bridgedChannelPairs: additional.bridgedChannelPairs,
        clippedSampleCounts: additional.clippedSampleCounts,
        impedancesKOhm: impedances?.map(Double.init) ?? [],
        simulatedImpedancesKOhm: coupledImpedances?.map(Double.init),
        impedanceThermalNoiseRMSMicrovolts: config.impedanceNoise == nil
            ? nil : thermalNoiseRMSMicrovolts,
        impedanceLineNoiseGainsMicrovolts: config.impedanceNoise == nil
            ? nil : lineNoiseGainsMicrovolts,
        scanStartSeconds: config.gradientEnabled ? config.preScanSeconds : 0,
        scanEndSeconds: config.gradientEnabled
            ? config.durationSeconds - config.postScanSeconds
            : 0,
        sourceSpace: eeg.sourceSpace.map {
            SourceSpaceTruth(
                model: "concentric-sphere dipole lead field",
                headModel: $0.headModel,
                sources: $0.sources,
                leadField: $0.leadField,
                calibrationFactor: $0.calibrationFactor,
                sourceCorrelationMatrix: $0.sourceCorrelationMatrix,
                topographicCorrelationMatrix: $0.topographicCorrelationMatrix,
                motions: $0.motions
            )
        },
        ocularDipoles: ocular?.dipoles ?? [],
        erpComponents: erp?.components,
        erpTrials: erp?.trials,
        erpSource: erp?.source,
        erpTopography: erp?.topography,
        erpWaveformDescription: erp?.waveformDescription,
        erpRealizedLatencyAmplitudeCorrelation: erp?.realizedLatencyAmplitudeCorrelation,
        erpRandomSeeds: erp?.randomSeeds,
        erpComponentSources: (erp?.componentSources).flatMap { $0.isEmpty ? nil : $0 },
        erpCoordinateFrame: erp == nil ? nil
            : "+x right, +y anterior, +z vertex; origin at the head-model centre; millimetres"
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
    if arguments.flag("write-sources") { print("Wrote \(sourcesURL.path)") }
    print("")
    print(String(format: "EEG std: %.2f µV   beats: %d   volumes: %d   montage: %@",
                 eeg.standardDeviation,
                 bcg?.trueBeatSeconds.count ?? 0,
                 gradient?.volumeOnsetsSeconds.count ?? 0,
                 montage.name))
    print("Recording reference: \(config.effectiveRecordingReference.rawValue) (before recording defects)")
    if let set = bcg?.generatorSet {
        let values = set.normalizedSingularValues.prefix(5)
            .map { String(format: "%.3f", $0) }
            .joined(separator: " ")
        print("BCG: \(set.generators.count) physical generators at "
            + String(format: "%.1f T", set.fieldStrengthTesla)
            + "   spatial rank \(set.spatialRank)   singular values \(values)")
    }
    if let sourceSpace = eeg.sourceSpace {
        print("Neural sources: \(sourceSpace.sources.count)   head model: \(sourceSpace.headModel.name)")
        if let report = leadFieldConvergence {
            print(String(format: "Lead-field convergence: %.3g max relative change (%d → %d terms)%@",
                         report.maximumRelativeColumnChange, report.terms,
                         report.comparisonTerms, report.converged ? "" : "  WARNING"))
        }
    }
    if let truth = eeg.neuralNonstationarity {
        print("Non-stationary EEG: \(truth.alphaBursts.count) alpha bursts, "
            + "\(truth.microstateEpisodes.count) microstates, "
            + "\(truth.bandAmplitudeEnvelopes1Hz.count) dynamic bands, "
            + (truth.phaseAmplitudeCoupling == nil ? "PAC off" : "PAC on"))
    }
    if let ocular {
        print("Blinks: \(ocular.blinkSeconds.count)   eye movements: \(ocular.saccadeSeconds.count)")
    }
    if let emg {
        print("EMG bursts: \(emg.bursts.count)")
    }
    let addedEpisodes = additional.chewingEpisodes.count
        + additional.swallowingEpisodes.count
        + additional.cableMovementEpisodes.count
        + additional.sweatEpisodes.count
    if addedEpisodes > 0 {
        print("Additional artifact episodes: \(addedEpisodes)")
    }
    if !additional.bridgedChannelPairs.isEmpty {
        print("Bridged channel pairs: \(additional.bridgedChannelPairs.count)")
    }
    let clipped = additional.clippedSampleCounts.reduce(0, +)
    if clipped > 0 { print("Clipped samples: \(clipped)") }
    if let erp {
        let targets = erp.trials.filter { $0.condition == "target" }.count
        let omitted = erp.trials.filter(\.omitted).count
        let overlapping = erp.trials.filter { $0.overlapsAnotherTrial == true }.count
        print("ERP trials: \(erp.trials.count) (\(targets) targets, \(omitted) omitted responses, "
            + "\(overlapping) overlapping windows)")
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
    if config.impedanceNoise != nil {
        let medianThermal = thermalNoiseRMSMicrovolts.sorted()[thermalNoiseRMSMicrovolts.count / 2]
        print(String(format: "Impedance-coupled contact noise: median %.3f µV RMS", medianThermal))
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

func loadChannels(_ path: String, padSeconds: Double) throws
    -> (channels: [[Double]], rate: Double, names: [String]?) {
    let url = URL(fileURLWithPath: path)
    let signal = try MFFReader().loadSignal(from: url)
    let pad = max(0, Int((padSeconds * signal.samplingRate).rounded()))
    let channels = signal.data.map { channel -> [Double] in
        let usable = channel.count - 2 * pad
        guard usable > 0 else { return channel.map(Double.init) }
        return channel[pad..<(pad + usable)].map(Double.init)
    }
    return (channels, signal.samplingRate, signal.channelNames)
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
    lines.append(String(format: "  RMSE %.3f µV   correlation %.4f   spectral distortion %.3f dB RMS",
                        score.broadbandRMSEMicrovolts, score.broadbandCorrelation,
                        score.spectralDistortionDbRMS))
    if let baseline {
        lines.append(String(format: "uncorrected: broadband SNR %.4f", baseline.broadbandSNR))
    }
    lines.append("")

    if baseline == nil {
        lines.append("  band      SNR     corr    RMSE   PSD dB RMS  power dB")
        lines.append("  --------------------------------------------------------")
        for band in score.bands {
            lines.append("  " + padded(band.name, to: 8)
                + String(format: " %6.2f  %7.3f  %6.3f  %10.3f  %+8.2f",
                         band.snr, band.correlation, band.residualRMS,
                         band.spectralDistortionDbRMS, band.powerRatioDb))
        }
    } else {
        lines.append("  band      SNR    uncorr    gain    corr    RMSE  PSD dB RMS")
        lines.append("  --------------------------------------------------------------")
        for (index, band) in score.bands.enumerated() {
            let uncorrected = index < baseline!.bands.count ? baseline!.bands[index].snr : .nan
            // The number that matters: a correction that leaves a band worse
            // than it found it has a gain below 1, and the paper's Figure 5C
            // finding is precisely that every BCG method does this above 10 Hz.
            let gain = uncorrected > 0 ? band.snr / uncorrected : .nan
            lines.append("  " + padded(band.name, to: 8)
                + String(format: " %6.2f  %6.2f  %6.2fx  %6.3f  %6.3f  %10.3f",
                         band.snr, uncorrected, gain, band.correlation,
                         band.residualRMS, band.spectralDistortionDbRMS))
        }
    }
    lines.append("")
    lines.append("  channel   SNR     corr    RMSE µV  PSD dB RMS")
    lines.append("  -----------------------------------------------")
    for channel in score.channels {
        lines.append("  " + padded(channel.name, to: 8)
            + String(format: " %6.2f  %7.3f  %8.3f  %10.3f",
                     channel.snr, channel.correlation, channel.rmseMicrovolts,
                     channel.spectralDistortionDbRMS))
    }
    lines.append("")
    lines.append("  SNR = std(clean) / std(clean - corrected), per band. Higher is better.")
    lines.append("  PSD dB RMS = spectral-shape error; 0 is perfect. RMSE is absolute error.")
    lines.append("  power dB = corrected band power vs clean; negative means EEG was removed")
    lines.append("  along with the artifact.")
    return lines.joined(separator: "\n")
}

func csv(_ score: CorrectionScore, baseline: CorrectionScore?) -> String {
    var lines = ["label,scope,channel,band,low_hz,high_hz,snr,uncorrected_snr,correlation,rmse_uv,spectral_distortion_db_rms,power_ratio_db,clean_rms_uv,residual_rms_uv"]
    for (index, band) in score.bands.enumerated() {
        let uncorrected = baseline.flatMap { index < $0.bands.count ? $0.bands[index].snr : nil }
        lines.append([
            score.label, "aggregate", "", band.name, "\(band.lowHz)", "\(band.highHz)",
            String(format: "%.6f", band.snr),
            uncorrected.map { String(format: "%.6f", $0) } ?? "",
            String(format: "%.6f", band.correlation),
            String(format: "%.6f", band.residualRMS),
            String(format: "%.6f", band.spectralDistortionDbRMS),
            String(format: "%.6f", band.powerRatioDb),
            String(format: "%.6f", band.cleanRMS),
            String(format: "%.6f", band.residualRMS)
        ].joined(separator: ","))
    }
    lines.append([
        score.label, "aggregate", "", "broadband", "", "",
        String(format: "%.6f", score.broadbandSNR),
        baseline.map { String(format: "%.6f", $0.broadbandSNR) } ?? "",
        String(format: "%.6f", score.broadbandCorrelation),
        String(format: "%.6f", score.broadbandRMSEMicrovolts),
        String(format: "%.6f", score.spectralDistortionDbRMS),
        "", String(format: "%.6f", score.cleanStandardDeviation),
        String(format: "%.6f", score.residualStandardDeviation)
    ].joined(separator: ","))
    for channel in score.channels {
        lines.append([
            score.label, "channel", channel.name, "broadband", "", "",
            String(format: "%.6f", channel.snr), "",
            String(format: "%.6f", channel.correlation),
            String(format: "%.6f", channel.rmseMicrovolts),
            String(format: "%.6f", channel.spectralDistortionDbRMS), "",
            String(format: "%.6f", channel.cleanStandardDeviation),
            String(format: "%.6f", channel.residualStandardDeviation)
        ].joined(separator: ","))
        for band in channel.bands {
            lines.append([
                score.label, "channel", channel.name, band.name,
                "\(band.lowHz)", "\(band.highHz)", String(format: "%.6f", band.snr), "",
                String(format: "%.6f", band.correlation),
                String(format: "%.6f", band.residualRMS),
                String(format: "%.6f", band.spectralDistortionDbRMS),
                String(format: "%.6f", band.powerRatioDb),
                String(format: "%.6f", band.cleanRMS),
                String(format: "%.6f", band.residualRMS)
            ].joined(separator: ","))
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

// MARK: - generate-group

/// Generates a cohort of simulated subjects (roadmap 3.1).
///
/// Writes `sub-XX/` directories carrying the usual per-subject packages, plus
/// `participants.tsv` and `group_truth.json` at the root. Push the result
/// through `eva-bids to-bids` per subject to get a BIDS dataset; the two tools
/// are kept separate deliberately rather than one calling the other.
func runGenerateGroup(_ arguments: Arguments) throws {
    let known = generateOptions.union([
        "subjects", "group-seed", "head-radius-sd", "placement-sd", "alpha-sd",
        "bcg-sd", "impedance-sd", "heart-rate-sd", "erp-effect-sd", "homogeneous"
    ])
    try arguments.validate(known: known)

    let subjectCount = try arguments.int("subjects") ?? 12
    guard subjectCount > 0 else { throw SimulateError.usage("--subjects must be positive") }
    guard let outputPath = arguments.string("output") else {
        throw SimulateError.usage("generate-group needs --output <dir>")
    }
    let base = try makeConfig(arguments)
    let groupSeed = try arguments.uint64("group-seed") ?? base.seed

    var variation = arguments.flag("homogeneous") ? GroupVariation.none : GroupVariation()
    if let value = try arguments.double("head-radius-sd") { variation.headRadiusSD = value }
    if let value = try arguments.double("placement-sd") {
        variation.electrodePlacementSDDegrees = value
    }
    if let value = try arguments.double("alpha-sd") { variation.alphaAmplitudeSD = value }
    if let value = try arguments.double("bcg-sd") { variation.bcgAmplitudeSD = value }
    if let value = try arguments.double("impedance-sd") { variation.impedanceSD = value }
    if let value = try arguments.double("heart-rate-sd") { variation.heartRateSDBPM = value }
    if let value = try arguments.double("erp-effect-sd") { variation.erpEffectSD = value }

    let root = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var subjects: [SubjectDraw] = []
    for index in 0..<subjectCount {
        let draw = GroupSimulation.draw(
            index: index, groupSeed: groupSeed, variation: variation, base: base
        )
        subjects.append(draw)
        let config = GroupSimulation.configure(base, with: draw)
        FileHandle.standardError.write(Data(
            "[sub-\(draw.label)] \(index + 1)/\(subjectCount)\n".utf8
        ))
        _ = try runGenerate(
            config: config, arguments: arguments,
            outputDirectory: root.appendingPathComponent("sub-\(draw.label)")
        )
    }

    let truth = GroupSimulation.truth(
        subjects: subjects, groupSeed: groupSeed, variation: variation, base: base
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(truth).write(
        to: root.appendingPathComponent("group_truth.json"), options: .atomic
    )
    try GroupSimulation.participantsTSV(truth).write(
        to: root.appendingPathComponent("participants.tsv"), atomically: true, encoding: .utf8
    )

    print("")
    print("Cohort: \(subjectCount) subjects in \(root.lastPathComponent)")
    let componentEffects = truth.erpEstimand?.components ?? []
    let nonzeroEffects = componentEffects.filter { abs($0.targetMinusStandardMicrovolts) > 1e-9 }
    if let effect = truth.populationEffectMicrovolts, abs(effect) > 1e-9,
       nonzeroEffects.count == 1 {
        let realized = truth.realizedBetweenSubjectSD["erpEffectScale"] ?? 0
        print(String(
            format: "  population ERP effect %@: %.2f µV, between-subject SD %.0f%% requested / "
                + "%.0f%% realized",
            nonzeroEffects[0].componentID as NSString, effect,
            100 * variation.erpEffectSD, 100 * realized
        ))
    } else if !nonzeroEffects.isEmpty {
        let realized = truth.realizedBetweenSubjectSD["erpEffectScale"] ?? 0
        print("  population ERP estimand: target-minus-standard peak amplitude, per component")
        for component in nonzeroEffects {
            print(String(
                format: "    %@ at %.0f ms: %+.2f µV",
                component.componentID as NSString,
                1000 * component.nominalPeakLatencySeconds,
                component.targetMinusStandardMicrovolts
            ))
        }
        print(String(
            format: "  between-subject effect SD %.0f%% requested / %.0f%% realized",
            100 * variation.erpEffectSD, 100 * realized
        ))
        print("  no scalar populationEffectMicrovolts is reported: component peaks cannot be summed")
    } else if truth.erpEstimand != nil {
        // Reporting a between-subject SD here would be actively misleading: the
        // effect-scale draws multiply zero, so they vary nothing. A cohort with
        // no condition contrast is a legitimate *negative control* — a group
        // method that finds an effect in it is finding noise — but it cannot be
        // used to test effect recovery, and saying so is cheaper than letting
        // someone discover it from a null result.
        print("  NOTE: every ERP component has standardAmplitudeRatio 1, so target and")
        print("        standard are identical and the population effect is exactly 0 µV.")
        print("        Useful as a negative control; useless for testing effect recovery.")
        print("        Use scenarios/group-oddball.json for a cohort with a real contrast.")
    } else {
        print("  no ERP in this scenario, so there is no population effect to recover")
    }
    print(String(
        format: "  realized between-subject SD: head %.3f, alpha %.3f, BCG %.3f, impedance %.3f",
        truth.realizedBetweenSubjectSD["headRadiusScale"] ?? 0,
        truth.realizedBetweenSubjectSD["alphaAmplitudeScale"] ?? 0,
        truth.realizedBetweenSubjectSD["bcgAmplitudeScale"] ?? 0,
        truth.realizedBetweenSubjectSD["impedanceScale"] ?? 0
    ))
    print("  wrote participants.tsv and group_truth.json")
    print("")
    print("  A requested SD and a realized SD are different things at small N.")
    print("  Score group results against group_truth.json's per-component ERP estimand,")
    print("  not against any one subject.")
}

// MARK: - evaluate-surrogate

/// Repeated-seed evaluation of surrogate separation across a swept condition.
///
/// Exists because single runs cannot support the comparison. Measured across
/// five seeds at one fixed configuration, corrected broadband SNR ranged 1.39 to
/// 2.53 — a spread wider than most of the differences anyone would want to claim
/// between conditions. Rusiniak et al. used 55 subjects; that was not incidental
/// generosity, it is what the variance demands.
///
/// Everything runs in memory: no MFF is written, so a sweep of dozens of runs
/// costs seconds rather than minutes.
func runEvaluateSurrogate(_ arguments: Arguments) throws {
    try arguments.validate(known: [
        "seeds", "offsets", "sources", "components", "brain-regularization",
        "duration", "channels", "coordinates", "rate", "config", "with-erp", "pattern-search",
        "representative-beat", "json"
    ])

    let seedCount = try arguments.int("seeds") ?? 5
    guard seedCount > 0 else { throw SimulateError.usage("--seeds must be positive") }
    let offsets = (arguments.string("offsets") ?? "0")
        .split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard !offsets.isEmpty else {
        throw SimulateError.usage("--offsets needs at least one value, in millimetres")
    }
    let regionalCount = try arguments.int("sources") ?? 29
    let componentCount = try arguments.int("components") ?? 4
    let regularization = try arguments.double("brain-regularization") ?? 0.02
    let patternSearchRaw = arguments.string("pattern-search") ?? "paper"
    guard let patternSearchMode = ArtifactPatternSearchMode(rawValue: patternSearchRaw) else {
        throw SimulateError.usage("--pattern-search expects paper or iterative")
    }
    let requestedRepresentative = try arguments.int("representative-beat").map { $0 - 1 }
    if let requestedRepresentative, requestedRepresentative < 0 {
        throw SimulateError.usage("--representative-beat is 1-based and must be positive")
    }
    if requestedRepresentative != nil, patternSearchMode != .paper {
        throw SimulateError.usage("--representative-beat applies only to --pattern-search paper")
    }

    var base = SimulationConfig.default
    if let path = arguments.string("config") {
        base = try SimulationScenarioFile.load(from: URL(fileURLWithPath: path)).config
    }
    base.channelCount = try arguments.int("channels") ?? base.channelCount
    if let path = arguments.string("coordinates") {
        guard !arguments.flag("coordinates") else {
            throw SimulateError.usage("--coordinates needs a coordinates.xml or MFF path")
        }
        base.coordinatesPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if arguments.string("channels") == nil,
           let geometry = ElectrodeGeometry.load(from: URL(fileURLWithPath: path)) {
            base.channelCount = geometry.positions.count
        }
    }
    base.samplingRate = try arguments.double("rate") ?? 250
    base.durationSeconds = try arguments.double("duration") ?? 180
    base.eegGenerationModel = .dipole
    base.recordingReference = .average
    base.bcgSpatialModel = .generators
    base.gradientEnabled = false
    let evaluateERP = arguments.flag("with-erp")
    if evaluateERP, base.erp?.components == nil {
        throw SimulateError.usage(
            "--with-erp needs a scenario whose ERP has explicitly placed components; "
                + "try --config scenarios/aep-bilateral.json"
        )
    }
    if !evaluateERP { base.erp = nil }
    let montage = try base.coordinatesPath.map {
        try importedMontage(path: $0, channelCount: base.channelCount).montage
    } ?? Montage.standard(count: base.channelCount)

    struct ConditionResult {
        var offsetMillimetres: Double
        var successfulSeeds: [UInt64]
        var erpSuccessfulSeeds: [UInt64]
        var correctedSNR: [Double]
        var uncorrectedSNR: [Double]
        var nearestSourceMillimetres: [Double]
        var acceptedBeatFraction: [Double]
        var artifactComponentCounts: [Double]
        var representativeCandidateBeats: [Int]
        // Rusiniak's four criteria, corrected and uncorrected.
        var correctedTrials: [Double] = []
        var uncorrectedTrials: [Double] = []
        var correctedERPSNR: [Double] = []
        var uncorrectedERPSNR: [Double] = []
        var correctedLatencyErrorMilliseconds: [Double] = []
        var uncorrectedLatencyErrorMilliseconds: [Double] = []
        var correctedAmplitudeErrorFraction: [Double] = []
        var uncorrectedAmplitudeErrorFraction: [Double] = []
        var correctedExplainedVariance: [Double] = []
        var uncorrectedExplainedVariance: [Double] = []
    }

    var results: [ConditionResult] = []
    for offset in offsets {
        var successfulSeeds: [UInt64] = []
        var erpSuccessfulSeeds: [UInt64] = []
        var corrected: [Double] = []
        var uncorrected: [Double] = []
        var nearest: [Double] = []
        var accepted: [Double] = []
        var artifactCounts: [Double] = []
        var representativeBeats: [Int] = []
        var correctedTrialsBuffer: [Double] = []
        var uncorrectedTrialsBuffer: [Double] = []
        var correctedERPSNRBuffer: [Double] = []
        var uncorrectedERPSNRBuffer: [Double] = []
        var correctedLatencyBuffer: [Double] = []
        var uncorrectedLatencyBuffer: [Double] = []
        var correctedAmplitudeBuffer: [Double] = []
        var uncorrectedAmplitudeBuffer: [Double] = []
        var correctedVarianceBuffer: [Double] = []
        var uncorrectedVarianceBuffer: [Double] = []

        for seedIndex in 0..<seedCount {
            var config = base
            config.seed = UInt64(seedIndex + 1)

            var clean = try DipoleEEGGenerator.generate(config: config, montage: montage).channels
            var erpInjection: ERPInjection?
            if evaluateERP {
                erpInjection = try ERPGenerator.inject(
                    into: &clean, config: config, montage: montage
                )
            }
            var noisy = clean
            var stream = GaussianSource(seed: SimulationSeedStreams.bcg(base: config.seed))
            let bcg = BCGArtifactModel.inject(
                into: &noisy, config: config, montage: montage, source: &stream
            )
            var cleanReferenced = clean
            EEGReferencing.apply(.average, to: &cleanReferenced)
            EEGReferencing.apply(.average, to: &noisy)

            guard let components = SurrogateSeparation.artifactComponents(
                channels: noisy,
                samplingRate: config.samplingRate,
                beatSeconds: bcg.detectedBeatSeconds,
                patternSearchMode: patternSearchMode,
                representativeBeatIndex: requestedRepresentative
            ) else { continue }
            let brain = try SurrogateSeparation.brainModel(
                head: config.sphericalHeadModel, montage: montage, count: regionalCount,
                reference: .average, terms: config.leadFieldTerms, offsetMillimetres: offset
            )
            let sourceInformedOperator = try SurrogateSeparation.sourceInformedOperator(
                brain: brain,
                artifactTopographies: Array(components.topographies.prefix(componentCount)),
                brainRegularization: regularization
            )
            let output = try SourceInformedSeparation.apply(sourceInformedOperator, to: noisy)

            func snr(_ candidate: [[Double]]) -> Double {
                var signal = 0.0
                var residual = 0.0
                for channel in cleanReferenced.indices {
                    for sample in cleanReferenced[channel].indices
                    where sample < candidate[channel].count {
                        let value = cleanReferenced[channel][sample]
                        signal += value * value
                        let error = value - candidate[channel][sample]
                        residual += error * error
                    }
                }
                return residual > 1e-30 ? (signal / residual).squareRoot() : .infinity
            }
            successfulSeeds.append(config.seed)
            corrected.append(snr(output))
            uncorrected.append(snr(noisy))
            accepted.append(
                Double(components.acceptedBeatCount) / Double(max(1, components.candidateBeatCount))
            )
            artifactCounts.append(Double(min(componentCount, components.topographies.count)))
            if let representative = components.representativeBeatIndex {
                representativeBeats.append(representative + 1)
            }
            let simulated = DipoleEEGGenerator.makeSources(config: config)
            nearest.append(
                brain.sources.map { surrogate in
                    simulated.map { (surrogate.positionMeters - $0.positionMeters).norm * 1000 }
                        .min() ?? 0
                }.min() ?? 0
            )

            if let erpInjection, !erpInjection.componentSources.isEmpty {
                let onsets = erpInjection.trials.map(\.onsetSeconds)
                let conditions = erpInjection.trials.map(\.condition)
                let topographies = erpInjection.componentSources.map(\.topography)
                // The paper's FWHM window, 81-114 ms, around the seeded N100.
                let nominal = erpInjection.componentSources
                    .map(\.nominalPeakLatencySeconds).min() ?? 0.1
                let fwhmStart = nominal - 0.020
                let fwhmEnd = nominal + 0.013
                // Truth for the peak comes from the *clean* recording scored the
                // same way, not from the nominal configuration: overlapping
                // components and trial jitter both move the realized peak, and
                // scoring against a number the data never had would charge every
                // method for the simulator's own design.
                func evaluate(_ data: [[Double]]) -> ERPEvaluationResult? {
                    ERPEvaluation.evaluate(
                        channels: data, samplingRate: config.samplingRate,
                        onsets: onsets, conditions: conditions,
                        modelTopographies: topographies,
                        fwhmStartSeconds: fwhmStart, fwhmEndSeconds: fwhmEnd
                    )
                }
                var cleanReferencedERP = clean
                EEGReferencing.apply(.average, to: &cleanReferencedERP)
                if let truthResult = evaluate(cleanReferencedERP),
                   let correctedResult = evaluate(output),
                   let uncorrectedResult = evaluate(noisy),
                   abs(truthResult.peakAmplitudeMicrovolts) > 1e-12 {
                    erpSuccessfulSeeds.append(config.seed)
                    correctedTrialsBuffer.append(Double(correctedResult.acceptedTrials))
                    uncorrectedTrialsBuffer.append(Double(uncorrectedResult.acceptedTrials))
                    correctedERPSNRBuffer.append(correctedResult.signalToNoise)
                    uncorrectedERPSNRBuffer.append(uncorrectedResult.signalToNoise)
                    correctedLatencyBuffer.append(
                        1000 * (correctedResult.peakLatencySeconds - truthResult.peakLatencySeconds)
                    )
                    uncorrectedLatencyBuffer.append(
                        1000 * (uncorrectedResult.peakLatencySeconds - truthResult.peakLatencySeconds)
                    )
                    correctedAmplitudeBuffer.append(
                        correctedResult.peakAmplitudeMicrovolts
                            / truthResult.peakAmplitudeMicrovolts
                    )
                    uncorrectedAmplitudeBuffer.append(
                        uncorrectedResult.peakAmplitudeMicrovolts
                            / truthResult.peakAmplitudeMicrovolts
                    )
                    correctedVarianceBuffer.append(correctedResult.explainedVariance)
                    uncorrectedVarianceBuffer.append(uncorrectedResult.explainedVariance)
                }
            }
        }
        results.append(ConditionResult(
            offsetMillimetres: offset, successfulSeeds: successfulSeeds,
            erpSuccessfulSeeds: erpSuccessfulSeeds,
            correctedSNR: corrected, uncorrectedSNR: uncorrected,
            nearestSourceMillimetres: nearest, acceptedBeatFraction: accepted,
            artifactComponentCounts: artifactCounts,
            representativeCandidateBeats: representativeBeats,
            correctedTrials: correctedTrialsBuffer,
            uncorrectedTrials: uncorrectedTrialsBuffer,
            correctedERPSNR: correctedERPSNRBuffer,
            uncorrectedERPSNR: uncorrectedERPSNRBuffer,
            correctedLatencyErrorMilliseconds: correctedLatencyBuffer,
            uncorrectedLatencyErrorMilliseconds: uncorrectedLatencyBuffer,
            correctedAmplitudeErrorFraction: correctedAmplitudeBuffer,
            uncorrectedAmplitudeErrorFraction: uncorrectedAmplitudeBuffer,
            correctedExplainedVariance: correctedVarianceBuffer,
            uncorrectedExplainedVariance: uncorrectedVarianceBuffer
        ))
    }

    func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        return (values.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1))
            .squareRoot()
    }

    if arguments.flag("json") {
        func jsonNumber(_ value: Double) -> Any {
            value.isFinite ? value : NSNull()
        }
        func statistics(_ values: [Double]) -> [String: Any] {
            guard !values.isEmpty else {
                return [
                    "count": 0,
                    "mean": NSNull(),
                    "standardDeviation": NSNull(),
                    "values": []
                ]
            }
            return [
                "count": values.count,
                "mean": jsonNumber(mean(values)),
                "standardDeviation": jsonNumber(standardDeviation(values)),
                "values": values.map(jsonNumber)
            ]
        }
        var conditions: [[String: Any]] = []
        for result in results {
            var condition: [String: Any] = [
                "offsetMillimetres": result.offsetMillimetres,
                "successfulSeedCount": result.successfulSeeds.count,
                "successfulSeeds": result.successfulSeeds,
                "broadbandSNR": [
                    "corrected": statistics(result.correctedSNR),
                    "uncorrected": statistics(result.uncorrectedSNR)
                ],
                "nearestSourceMillimetres": statistics(result.nearestSourceMillimetres),
                "acceptedBeatFraction": statistics(result.acceptedBeatFraction),
                "artifactComponentCount": statistics(result.artifactComponentCounts),
                "representativeCandidateBeats": result.representativeCandidateBeats
            ]
            if evaluateERP {
                condition["erp"] = [
                    "successfulSeeds": result.erpSuccessfulSeeds,
                    "acceptedTrials": [
                        "corrected": statistics(result.correctedTrials),
                        "uncorrected": statistics(result.uncorrectedTrials)
                    ],
                    "signalToNoise": [
                        "corrected": statistics(result.correctedERPSNR),
                        "uncorrected": statistics(result.uncorrectedERPSNR)
                    ],
                    "latencyErrorMilliseconds": [
                        "corrected": statistics(result.correctedLatencyErrorMilliseconds),
                        "uncorrected": statistics(result.uncorrectedLatencyErrorMilliseconds)
                    ],
                    "amplitudeFractionOfClean": [
                        "corrected": statistics(result.correctedAmplitudeErrorFraction),
                        "uncorrected": statistics(result.uncorrectedAmplitudeErrorFraction)
                    ],
                    "explainedVariance": [
                        "corrected": statistics(result.correctedExplainedVariance),
                        "uncorrected": statistics(result.uncorrectedExplainedVariance)
                    ]
                ] as [String: Any]
            }
            conditions.append(condition)
        }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "method": "PCA-S",
            "patternSearchMode": patternSearchMode.rawValue,
            "requestedSeedsPerCondition": seedCount,
            "configuration": [
                "channels": base.channelCount,
                "samplingRateHz": base.samplingRate,
                "durationSeconds": base.durationSeconds,
                "regionalSourceCount": regionalCount,
                "artifactComponentLimit": componentCount,
                "brainRegularization": regularization,
                "requestedRepresentativeBeat": requestedRepresentative.map { ($0 + 1) as Any }
                    ?? NSNull(),
                "erpEvaluationEnabled": evaluateERP
            ] as [String: Any],
            "conditions": conditions
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        )
        print(String(data: data, encoding: .utf8) ?? "[]")
        return
    }

    print("Surrogate separation, \(seedCount) requested seeds per condition")
    print("  \(base.channelCount) channels, \(Int(base.samplingRate)) Hz, "
        + "\(Int(base.durationSeconds)) s, \(regionalCount) regional sources, "
        + "\(componentCount) artifact components")
    print("  pattern search: \(patternSearchMode.rawValue)")
    print("")
    print("  offset    corrected SNR      uncorrected   nearest src   beats kept")
    print("  ---------------------------------------------------------------------")
    for result in results {
        print(String(
            format: "  %5.0f mm   %5.2f ± %-5.2f     %5.2f         %5.1f mm      %3.0f%%",
            result.offsetMillimetres,
            mean(result.correctedSNR), standardDeviation(result.correctedSNR),
            mean(result.uncorrectedSNR),
            mean(result.nearestSourceMillimetres),
            100 * mean(result.acceptedBeatFraction)
        ))
    }
    if evaluateERP, results.contains(where: { !$0.correctedExplainedVariance.isEmpty }) {
        print("")
        print("  Rusiniak criteria, corrected vs uncorrected (mean ± SD over seeds)")
        print("  ---------------------------------------------------------------------")
        // One row per arm with its own spread. A compact corrected/uncorrected
        // table reads well and invites precisely the mistake this command warns
        // about — comparing two means whose spreads overlap completely.
        print("  condition        trials kept    ERP SNR       latency err     "
            + "amplitude      explained var")
        func describe(_ label: String, _ result: ConditionResult, corrected: Bool) {
            let trials = corrected ? result.correctedTrials : result.uncorrectedTrials
            let snr = corrected ? result.correctedERPSNR : result.uncorrectedERPSNR
            let latency = corrected
                ? result.correctedLatencyErrorMilliseconds
                : result.uncorrectedLatencyErrorMilliseconds
            let amplitude = corrected
                ? result.correctedAmplitudeErrorFraction
                : result.uncorrectedAmplitudeErrorFraction
            let variance = corrected
                ? result.correctedExplainedVariance : result.uncorrectedExplainedVariance
            print(String(
                format: "  %-15@  %5.1f±%-4.1f  %5.2f±%-4.2f  %+5.1f±%-4.1f ms  "
                    + "%4.2f±%-4.2f  %4.2f±%-4.2f",
                label as NSString,
                mean(trials), standardDeviation(trials),
                mean(snr), standardDeviation(snr),
                mean(latency), standardDeviation(latency),
                mean(amplitude), standardDeviation(amplitude),
                mean(variance), standardDeviation(variance)
            ))
        }
        if let first = results.first(where: { !$0.uncorrectedExplainedVariance.isEmpty }) {
            describe("uncorrected", first, corrected: false)
        }
        for result in results where !result.correctedExplainedVariance.isEmpty {
            describe(String(format: "PCA-S %.0f mm", result.offsetMillimetres),
                     result, corrected: true)
        }
        print("")
        print("  amplitude is the recovered peak as a fraction of the same measurement on")
        print("  the clean recording; 1.00 is undistorted. explained var is the share of")
        print("  the averaged topography accounted for by the seeded dipole model.")
    }
    print("")
    print("  The spread matters as much as the means: a difference smaller than the")
    print("  standard deviation is not a result. Increase --seeds before concluding.")
}

// MARK: - correct

/// Applies the PCA-surrogate BCG correction to a generated recording.
///
/// Beat times come from the recording's own event stream by default, and the
/// default code is `QRSd` — the *detected* beats, jittered, not the true ones.
/// That is deliberate: a correction method that quietly used ground-truth beat
/// timing would score well for a reason no real pipeline can reproduce.
func runCorrect(_ arguments: Arguments) throws {
    try arguments.validate(known: [
        "input", "output", "truth", "reference", "beat-code", "beat-times", "surrogate-sources",
        "brain-regularization", "artifact-variance", "correlation-threshold",
        "surrogate-offset-mm", "pattern-search", "representative-beat", "coordinates",
        "assume-standard-montage",
        "components", "low-hz", "high-hz", "report", "json"
    ])

    guard let inputPath = arguments.string("input") else {
        throw SimulateError.usage("correct needs --input <noisy.mff>")
    }
    guard let outputPath = arguments.string("output") else {
        throw SimulateError.usage("correct needs --output <corrected.mff>")
    }

    let inputURL = URL(fileURLWithPath: inputPath)
    let reader = MFFReader()
    let signal = try reader.loadSignal(from: inputURL)
    let pnsSignal = try reader.loadPNSSignal(from: inputURL)
    let channels = signal.data.map { $0.map(Double.init) }
    guard !channels.isEmpty else { throw SimulateError.io("\(inputPath) has no channels") }

    let beatCode = arguments.string("beat-code") ?? "QRSd"
    var beats: [Double]
    if let path = arguments.string("beat-times") {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        beats = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    } else {
        beats = signal.events.filter { $0.code == beatCode }.map(\.beginTimeSeconds).sorted()
    }
    guard beats.count >= 2 else {
        throw SimulateError.usage(
            "no usable beat times: found \(beats.count) events with code '\(beatCode)'. "
                + "Use --beat-code or --beat-times."
        )
    }

    let regionalCount = try arguments.int("surrogate-sources") ?? 29
    let regularization = try arguments.double("brain-regularization") ?? 0.02
    let varianceThreshold = try arguments.double("artifact-variance") ?? 0.005
    let correlationThreshold = try arguments.double("correlation-threshold") ?? 0.6
    let lowHz = try arguments.double("low-hz") ?? 1
    let highHz = try arguments.double("high-hz") ?? 20
    let patternSearchRaw = arguments.string("pattern-search") ?? "paper"
    guard let patternSearchMode = ArtifactPatternSearchMode(rawValue: patternSearchRaw) else {
        throw SimulateError.usage("--pattern-search expects paper or iterative")
    }
    let requestedRepresentative = try arguments.int("representative-beat").map { $0 - 1 }
    if let requestedRepresentative, requestedRepresentative < 0 {
        throw SimulateError.usage("--representative-beat is 1-based and must be positive")
    }
    if requestedRepresentative != nil, patternSearchMode != .paper {
        throw SimulateError.usage("--representative-beat applies only to --pattern-search paper")
    }

    guard let componentSet = SurrogateSeparation.artifactComponents(
        channels: channels,
        samplingRate: signal.samplingRate,
        beatSeconds: beats,
        lowHz: lowHz,
        highHz: highHz,
        correlationThreshold: correlationThreshold,
        varianceThreshold: varianceThreshold,
        patternSearchMode: patternSearchMode,
        representativeBeatIndex: requestedRepresentative
    ) else {
        throw SimulateError.io("could not build an artifact template from \(beats.count) beats")
    }

    var topographies = componentSet.topographies
    if let requested = try arguments.int("components") {
        guard requested > 0 else {
            throw SimulateError.usage("--components must be positive")
        }
        topographies = Array(topographies.prefix(requested))
    }

    // The brain model has to be built in the *recording's* reference. Getting
    // this wrong is not a subtle degradation: an average-referenced lead field
    // against infinity-referenced data leaves the common mode unexplainable by
    // the brain block, the artifact block absorbs it, and the filter removes
    // most of the brain signal along with it. Prefer the truth sidecar, which
    // records the convention (roadmap 4.6); fall back to the flag.
    var reference: EEGReference = .average
    var simulatedSources: [SimulatedSource] = []
    var simulationTruth: SimulationTruth?
    if let truthPath = arguments.string("truth") {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: truthPath))
            let truth = try JSONDecoder().decode(SimulationTruth.self, from: data)
            simulationTruth = truth
            if let recorded = truth.recordingReference { reference = recorded }
            simulatedSources = truth.sourceSpace?.sources ?? []
        } catch {
            throw SimulateError.io(
                "could not read simulation truth \(truthPath): \(error.localizedDescription)"
            )
        }
    }
    if let raw = arguments.string("reference") {
        guard let explicit = EEGReference(rawValue: raw) else {
            throw SimulateError.usage("unknown --reference '\(raw)'; expected average or infinity")
        }
        reference = explicit
    }

    // Electrode coordinates are observable recording metadata; never silently
    // replace them with an unrelated standard montage. An explicit override can
    // be either coordinates.xml or another MFF package. If the input lacks
    // geometry, a truth-sidecar asset is the next-best exact source. The legacy
    // standard montage remains available only behind an opt-in flag.
    let explicitCoordinates = arguments.string("coordinates")
    if arguments.flag("coordinates") {
        throw SimulateError.usage("--coordinates needs a coordinates.xml or MFF path")
    }
    let geometryResolution: ImportedMontageResolution
    let assumedStandardMontage: Bool
    if let explicitCoordinates {
        geometryResolution = try importedMontage(
            path: explicitCoordinates, channelCount: channels.count,
            signalChannelNames: signal.channelNames
        )
        assumedStandardMontage = false
    } else if ElectrodeGeometry.load(from: inputURL) != nil {
        geometryResolution = try importedMontage(
            path: inputURL.path, channelCount: channels.count,
            signalChannelNames: signal.channelNames
        )
        assumedStandardMontage = false
    } else if let path = simulationTruth?.config.coordinatesPath,
              ElectrodeGeometry.load(from: URL(fileURLWithPath: path)) != nil {
        geometryResolution = try importedMontage(
            path: path, channelCount: channels.count,
            signalChannelNames: signal.channelNames
        )
        assumedStandardMontage = false
    } else if arguments.flag("assume-standard-montage") {
        geometryResolution = ImportedMontageResolution(
            montage: Montage.standard(count: channels.count),
            sourceDescription: "explicit built-in standard-montage assumption",
            sourcePath: ""
        )
        assumedStandardMontage = true
    } else {
        throw SimulateError.usage(
            "the input has no valid coordinates.xml. Supply --coordinates <coordinates.xml|mff> "
                + "or explicitly opt into --assume-standard-montage"
        )
    }
    let montage = geometryResolution.montage

    // MFF carries electrodes but not individual brain/skull/scalp shells. A
    // simulation truth sidecar does, so it is exact; real recordings use the
    // declared classic approximation until EVA gains MRI/BEM import.
    let head = simulationTruth?.config.sphericalHeadModel ?? .classicThreeShell
    let headModelSource = simulationTruth == nil
        ? "declared classic three-shell approximation"
        : "simulation truth config"
    let leadFieldTerms = simulationTruth?.config.leadFieldTerms ?? 100
    let surrogateOffset = try arguments.double("surrogate-offset-mm") ?? 0
    let brain = try SurrogateSeparation.brainModel(
        head: head, montage: montage, count: regionalCount,
        reference: reference, terms: leadFieldTerms, offsetMillimetres: surrogateOffset
    )
    let sourceInformedOperator = try SurrogateSeparation.sourceInformedOperator(
        brain: brain,
        artifactTopographies: topographies,
        brainRegularization: regularization
    )
    let corrected = try SourceInformedSeparation.apply(sourceInformedOperator, to: channels)

    var report = SurrogateFilterReport(
        method: "PCA-S",
        regionalSourceCount: regionalCount,
        brainColumnCount: brain.columnCount,
        artifactComponentCount: topographies.count,
        artifactVarianceFractions: Array(componentSet.varianceFractions.prefix(topographies.count)),
        acceptedBeatCount: componentSet.acceptedBeatCount,
        candidateBeatCount: componentSet.candidateBeatCount,
        patternSearchMode: componentSet.patternSearchMode.rawValue,
        representativeBeatIndex: componentSet.representativeBeatIndex,
        brainRegularization: regularization,
        operatorDiagnostics: sourceInformedOperator.diagnostics,
        geometrySource: geometryResolution.sourceDescription,
        geometryPath: geometryResolution.sourcePath.isEmpty
            ? nil : geometryResolution.sourcePath,
        montageName: montage.name,
        electrodeCount: montage.electrodes.count,
        assumedStandardMontage: assumedStandardMontage,
        headModelSource: headModelSource,
        headModelName: head.name,
        headShellRadiiMeters: head.shells.map(\.radiusMeters),
        leadFieldTerms: leadFieldTerms,
        pnsPreserved: true,
        pnsChannelCount: pnsSignal?.numberOfChannels ?? 0,
        pnsChannelNames: pnsSignal?.channelNames ?? [],
        surrogateOffsetMillimetres: surrogateOffset,
        nearestSimulatedSourceMillimetres: nil,
        minimumSourceSeparationMillimetres: nil
    )

    // Record how far the surrogate basis sits from the sources that actually
    // generated the data. A basis sitting on top of them would rig the
    // comparison — see roadmap 5.3.
    if !simulatedSources.isEmpty {
        let distances = brain.sources.map { surrogate in
            simulatedSources.map { (surrogate.positionMeters - $0.positionMeters).norm * 1000 }
                .min() ?? 0
        }
        report.nearestSimulatedSourceMillimetres = distances
        report.minimumSourceSeparationMillimetres = distances.min()
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    let correctedSignal = signal.replacingSamples(
        corrected.map { $0.map(Float.init) }, signalTypeSuffix: "surrogate-corrected"
    )
    try MFFWriter.write(
        signal: correctedSignal, pnsSignal: pnsSignal,
        segments: [], kind: .continuous,
        to: outputURL, preserveSourceFileInfo: false
    )

    if let path = arguments.string("report") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    if arguments.flag("json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try encoder.encode(report), encoding: .utf8) ?? "{}")
    } else {
        let shares = report.artifactVarianceFractions
            .map { String(format: "%.1f%%", $0 * 100) }.joined(separator: " ")
        print("PCA-S: \(report.artifactComponentCount) artifact components from "
            + "\(report.acceptedBeatCount)/\(report.candidateBeatCount) beats "
            + "(variance \(shares))")
        let representative = report.representativeBeatIndex.map {
            ", representative candidate beat \($0 + 1)"
        }
            ?? ""
        print("  pattern search: \(report.patternSearchMode)\(representative)")
        print("  brain surrogate: \(regionalCount) regional sources, "
            + "\(brain.columnCount) columns, \(Int(regularization * 100))% regularization")
        print("  electrodes: \(montage.name), \(montage.electrodes.count) channels "
            + "[\(geometryResolution.sourceDescription)]")
        print("  head model: \(head.name) [\(headModelSource)]")
        if let pnsSignal {
            let names = pnsSignal.channelNames?.joined(separator: ", ") ?? "unnamed"
            print("  preserved PNS: \(pnsSignal.numberOfChannels) channels (\(names))")
        } else {
            print("  preserved PNS: none present")
        }
        if let minimum = report.minimumSourceSeparationMillimetres {
            print(String(
                format: "  nearest surrogate-to-simulated source: %.1f mm "
                    + "(a small value means the basis is fitted to the truth)", minimum
            ))
        }
        print("  wrote \(outputURL.lastPathComponent)")
    }
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
        samplingRate: truth.rate,
        channelNames: truth.names
    )

    var baseline: CorrectionScore?
    if let baselinePath = arguments.string("baseline") {
        let noisy = try loadChannels(baselinePath, padSeconds: pad)
        guard noisy.channels.count == truth.channels.count else {
            throw SimulateError.io("baseline channel count differs from truth")
        }
        guard abs(noisy.rate - truth.rate) < 1e-6 else {
            throw SimulateError.io("baseline sampling rate differs from truth")
        }
        baseline = SNRMetrics.score(
            label: "uncorrected",
            clean: truth.channels,
            corrected: noisy.channels,
            samplingRate: truth.rate,
            channelNames: truth.names
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
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        var payload = [score]
        if let baseline { payload.append(baseline) }
        try encoder.encode(payload).write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

// MARK: - event-detection score

func loadDetectedEvents(_ path: String, eventCode: String) throws -> [DetectedEvent] {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension.lowercased() == "json" {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let set = try? decoder.decode(DetectedEventSet.self, from: data) { return set.events }
        if let events = try? decoder.decode([DetectedEvent].self, from: data) { return events }
        throw SimulateError.io(
            "could not decode \(path): expected {\"events\":[{\"timeSeconds\":...,\"score\":...}]}"
        )
    }
    let signal = try MFFReader().loadSignal(from: url)
    return signal.events.filter { $0.code == eventCode }.map {
        DetectedEvent(id: $0.id, timeSeconds: $0.beginTimeSeconds)
    }
}

func runEventScore(_ arguments: Arguments) throws {
    try arguments.validate(known: [
        "truth", "detected", "type", "event-code", "tolerance-ms", "json"
    ])
    guard let truthPath = arguments.string("truth"),
          let detectedPath = arguments.string("detected"),
          let type = arguments.string("type") else {
        throw SimulateError.usage(
            "score-events needs --truth <truth.json> --detected <json-or-mff> --type <event>"
        )
    }
    let truth = try JSONDecoder().decode(
        SimulationTruth.self,
        from: Data(contentsOf: URL(fileURLWithPath: truthPath))
    )
    let eventTimes: [Double]
    let defaultCode: String
    let defaultTolerance: Double
    switch type {
    case "gradient":
        eventTimes = truth.gradientVolumeOnsetsSeconds
        defaultCode = "TREV"
        defaultTolerance = 2
    case "bcg":
        eventTimes = truth.bcgTrueBeatSeconds
        defaultCode = "QRSd"
        defaultTolerance = 50
    case "blink":
        eventTimes = truth.blinkSeconds
        defaultCode = "blnk"
        defaultTolerance = 100
    case "saccade":
        eventTimes = truth.saccadeSeconds
        defaultCode = "eyem"
        defaultTolerance = 50
    case "emg":
        eventTimes = (truth.emgBursts ?? []).map(\.onsetSeconds)
        defaultCode = "emg"
        defaultTolerance = 100
    case "chewing":
        eventTimes = (truth.chewingEpisodes ?? []).map(\.onsetSeconds)
        defaultCode = "chew"
        defaultTolerance = 150
    case "swallowing":
        eventTimes = (truth.swallowingEpisodes ?? []).map(\.onsetSeconds)
        defaultCode = "swal"
        defaultTolerance = 100
    case "movement":
        eventTimes = (truth.cableMovementEpisodes ?? []).map(\.onsetSeconds)
        defaultCode = "move"
        defaultTolerance = 150
    case "sweat":
        eventTimes = (truth.sweatEpisodes ?? []).map(\.onsetSeconds)
        defaultCode = "swet"
        defaultTolerance = 250
    default:
        throw SimulateError.usage(
            "--type expects gradient, bcg, blink, saccade, emg, chewing, swallowing, movement, or sweat"
        )
    }
    let tolerance = try arguments.double("tolerance-ms") ?? defaultTolerance
    guard tolerance > 0 else { throw SimulateError.usage("--tolerance-ms must be positive") }
    let detected = try loadDetectedEvents(
        detectedPath, eventCode: arguments.string("event-code") ?? defaultCode
    )
    let score = DetectionMetrics.score(
        eventType: type, truth: eventTimes, detected: detected,
        durationSeconds: truth.config.durationSeconds,
        toleranceSeconds: tolerance / 1000
    )
    print("")
    print(String(format: "%@: %d TP, %d FP, %d FN within %.1f ms",
                 type, score.truePositives, score.falsePositives,
                 score.falseNegatives, score.toleranceMilliseconds))
    print(String(format: "  precision %.4f   sensitivity %.4f   specificity %.4f   F1 %.4f",
                 score.precision, score.sensitivity, score.specificity, score.f1))
    print(String(format: "  timing MAE %.3f ms   max %.3f ms   false positives %.3f/min",
                 score.meanAbsoluteTimingErrorMilliseconds,
                 score.maximumAbsoluteTimingErrorMilliseconds,
                 score.falsePositivesPerMinute))
    if let auc = score.rocAUC { print(String(format: "  ROC AUC %.4f", auc)) }
    if let path = arguments.string("json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(score).write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

// MARK: - ERP score

func loadERPComponents(
    _ path: String, level: String = "average", excludeOverlap: Bool = false
) throws -> [ERPComponent] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JSONDecoder()
    if let set = try? decoder.decode(ERPComponentSet.self, from: data) { return set.components }
    if let components = try? decoder.decode([ERPComponent].self, from: data) { return components }
    if let truth = try? decoder.decode(SimulationTruth.self, from: data) {
        if level == "trial", let trials = truth.erpTrials {
            return trials.filter {
                !$0.omitted && (!excludeOverlap || $0.overlapsAnotherTrial != true)
            }.map {
                ERPComponent(
                    id: $0.id,
                    peakLatencySeconds: $0.peakLatencySeconds,
                    peakAmplitudeMicrovolts: $0.peakAmplitudeMicrovolts
                )
            }
        }
        if let components = truth.erpComponents { return components }
    }
    throw SimulateError.io(
        "could not decode \(path): expected {\"components\":[{\"id\":...,"
        + "\"peakLatencySeconds\":...,\"peakAmplitudeMicrovolts\":...}]}"
    )
}

func runERPScore(_ arguments: Arguments) throws {
    try arguments.validate(known: ["truth", "estimated", "level", "exclude-overlap", "json"])
    guard let truthPath = arguments.string("truth"),
          let estimatedPath = arguments.string("estimated") else {
        throw SimulateError.usage("score-erp needs --truth <json> --estimated <json>")
    }
    let level = arguments.string("level") ?? "average"
    guard level == "average" || level == "trial" else {
        throw SimulateError.usage("--level expects average or trial")
    }
    let excludeOverlap = arguments.flag("exclude-overlap")
    if excludeOverlap, level != "trial" {
        throw SimulateError.usage("--exclude-overlap requires --level trial")
    }
    let score = ERPMetrics.score(
        truth: try loadERPComponents(
            truthPath, level: level, excludeOverlap: excludeOverlap
        ),
        estimated: try loadERPComponents(estimatedPath, level: level)
    )
    print("")
    print("ERP \(level) recovery\(excludeOverlap ? " (non-overlapping only)" : ""): "
        + "\(score.matchedCount) matched, \(score.missingEstimates) missing, "
        + "\(score.extraEstimates) extra")
    print(String(format: "  amplitude: bias %+.3f µV   MAE %.3f µV   RMSE %.3f µV",
                 score.amplitudeBiasMicrovolts, score.amplitudeMAEMicrovolts,
                 score.amplitudeRMSEMicrovolts))
    print(String(format: "  latency:   bias %+.3f ms   MAE %.3f ms   RMSE %.3f ms",
                 score.latencyBiasMilliseconds, score.latencyMAEMilliseconds,
                 score.latencyRMSEMilliseconds))
    if let path = arguments.string("json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(score).write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

// MARK: - phase-amplitude coupling score

nonisolated struct PACEstimate: Codable, Sendable {
    var strength: Double
    var preferredPhaseRadians: Double
}

nonisolated struct PACScoreReport: Codable, Sendable {
    var trueStrength: Double
    var estimatedStrength: Double
    var strengthError: Double
    var truePreferredPhaseRadians: Double
    var estimatedPreferredPhaseRadians: Double
    var circularPhaseErrorRadians: Double
    var circularPhaseErrorDegrees: Double
}

func runPACScore(_ arguments: Arguments) throws {
    try arguments.validate(known: ["truth", "estimated", "json"])
    guard let truthPath = arguments.string("truth"),
          let estimatedPath = arguments.string("estimated") else {
        throw SimulateError.usage("score-pac needs --truth <truth.json> --estimated <pac.json>")
    }

    let decoder = JSONDecoder()
    let truth = try decoder.decode(
        SimulationTruth.self,
        from: Data(contentsOf: URL(fileURLWithPath: truthPath))
    )
    guard let known = truth.neuralNonstationarity?.phaseAmplitudeCoupling else {
        throw SimulateError.io("truth sidecar does not contain phase-amplitude coupling truth")
    }
    let estimated = try decoder.decode(
        PACEstimate.self,
        from: Data(contentsOf: URL(fileURLWithPath: estimatedPath))
    )
    let signedPhaseError = atan2(
        sin(estimated.preferredPhaseRadians - known.preferredPhaseRadians),
        cos(estimated.preferredPhaseRadians - known.preferredPhaseRadians)
    )
    let report = PACScoreReport(
        trueStrength: known.strength,
        estimatedStrength: estimated.strength,
        strengthError: estimated.strength - known.strength,
        truePreferredPhaseRadians: known.preferredPhaseRadians,
        estimatedPreferredPhaseRadians: estimated.preferredPhaseRadians,
        circularPhaseErrorRadians: abs(signedPhaseError),
        circularPhaseErrorDegrees: abs(signedPhaseError) * 180 / Double.pi
    )

    print("")
    print("PAC recovery")
    print(String(format: "  strength: true %.4f   estimated %.4f   error %+.4f",
                 report.trueStrength, report.estimatedStrength, report.strengthError))
    print(String(format: "  preferred phase: true %.4f rad   estimated %.4f rad   circular error %.3f°",
                 report.truePreferredPhaseRadians, report.estimatedPreferredPhaseRadians,
                 report.circularPhaseErrorDegrees))
    if let path = arguments.string("json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

// MARK: - source-space score

func loadEstimatedSources(_ path: String) throws -> [EstimatedSource] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JSONDecoder()
    if let set = try? decoder.decode(EstimatedSourceSet.self, from: data) {
        return set.sources
    }
    if let array = try? decoder.decode([EstimatedSource].self, from: data) {
        return array
    }
    throw SimulateError.io(
        "could not decode \(path): expected {\"sources\":[{\"positionMeters\":{\"x\":...,\"y\":...,\"z\":...}}]}"
    )
}

func formatted(_ score: SourceLocationScore) -> String {
    var lines = [
        "",
        String(format: "source locations: %d matched, %d missed, %d extra",
               score.matchedCount, score.missedTrueSources, score.extraEstimatedSources),
        String(format: "  distance: mean %.3f mm   median %.3f mm   max %.3f mm",
               score.meanDistanceMillimeters, score.medianDistanceMillimeters,
               score.maximumDistanceMillimeters)
    ]
    if let orientation = score.meanOrientationErrorDegrees {
        lines.append(String(format: "  mean axial orientation error: %.3f°", orientation))
    }
    for match in score.matches {
        var line = String(format: "  %@ <- %@: %.3f mm",
                          match.trueSourceID, match.estimatedSourceID,
                          match.distanceMillimeters)
        if let orientation = match.orientationErrorDegrees {
            line += String(format: ", %.3f°", orientation)
        }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

func formatted(_ score: SourceRecoveryScore) -> String {
    var lines = [
        "",
        String(format: "source recovery: %d matched, %d missed, %d extra",
               score.matchedCount, score.missedTrueSources, score.extraRecoveredComponents),
        String(format: "  |r|: mean %.4f   median %.4f   minimum %.4f",
               score.meanAbsoluteCorrelation, score.medianAbsoluteCorrelation,
               score.minimumAbsoluteCorrelation)
    ]
    for match in score.matches {
        lines.append(String(format: "  %@ <- %@: r=%+.4f",
                            match.trueSourceID, match.recoveredComponent, match.correlation))
    }
    return lines.joined(separator: "\n")
}

func runSourceScore(_ arguments: Arguments) throws {
    try arguments.validate(known: ["truth", "estimated", "recovered", "pad-seconds", "json"])
    guard let truthPath = arguments.string("truth") else {
        throw SimulateError.usage("score-sources needs --truth <truth.json>")
    }
    guard arguments.string("estimated") != nil || arguments.string("recovered") != nil else {
        throw SimulateError.usage("score-sources needs --estimated <json>, --recovered <mff>, or both")
    }

    let truthData = try Data(contentsOf: URL(fileURLWithPath: truthPath))
    let truth = try JSONDecoder().decode(SimulationTruth.self, from: truthData)
    guard let sourceTruth = truth.sourceSpace else {
        throw SimulateError.usage("the truth sidecar has no source space; generate with --eeg-model dipole")
    }

    var locationScore: SourceLocationScore?
    if let path = arguments.string("estimated") {
        locationScore = SourceMetrics.locationScore(
            truth: sourceTruth.sources,
            estimated: try loadEstimatedSources(path)
        )
        print(formatted(locationScore!))
    }

    var recoveryScore: SourceRecoveryScore?
    if let path = arguments.string("recovered") {
        let recovered = try MFFReader().loadSignal(from: URL(fileURLWithPath: path))
        guard abs(recovered.samplingRate - truth.config.samplingRate) < 1e-9 else {
            throw SimulateError.io(
                "recovered sampling rate \(recovered.samplingRate) does not match truth \(truth.config.samplingRate)"
            )
        }
        let scoringMontage = try truth.config.coordinatesPath.map {
            try importedMontage(path: $0, channelCount: truth.config.channelCount).montage
        } ?? Montage.standard(count: truth.config.channelCount)
        let regenerated = try DipoleEEGGenerator.generate(
            config: truth.config, montage: scoringMontage
        )
        guard let regeneratedSources = regenerated.sourceSpace else {
            throw SimulateError.io("could not regenerate source time courses from the truth configuration")
        }
        let recoveredSignals = recovered.data.map { $0.map(Double.init) }
        let allSignals = regeneratedSources.timecoursesNanoampereMeters + recoveredSignals
        let minimumCount = allSignals.map(\.count).min() ?? 0
        let pad = max(0, Int(((try arguments.double("pad-seconds") ?? 0)
                              * truth.config.samplingRate).rounded()))
        guard minimumCount > 2 * pad else {
            throw SimulateError.usage("--pad-seconds leaves no source samples to score")
        }
        let range = pad..<(minimumCount - pad)
        let trueSignals = regeneratedSources.timecoursesNanoampereMeters.map {
            Array($0[range])
        }
        let trimmedRecovered = recoveredSignals.map { Array($0[range]) }
        let names = recovered.channelNames
            ?? (0..<trimmedRecovered.count).map { "component-\($0 + 1)" }
        recoveryScore = SourceMetrics.recoveryScore(
            trueIDs: sourceTruth.sources.map(\.id),
            trueSignals: trueSignals,
            recoveredNames: names,
            recoveredSignals: trimmedRecovered
        )
        print(formatted(recoveryScore!))
    }

    if let path = arguments.string("json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SourceScoreReport(
            location: locationScore,
            recovery: recoveryScore
        ))
        try data.write(to: URL(fileURLWithPath: path))
        print("\nWrote \(path)")
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
    case "impedance":
        guard value > 0 else { throw SimulateError.usage("an impedance sweep needs positive values") }
        config.impedanceTypicalKOhm = value
        config.includeImpedance = true
        config.impedanceNoise = config.impedanceNoise ?? ImpedanceNoiseConfig()
    case "emg-rate":
        guard value > 0 else { throw SimulateError.usage("an EMG-rate sweep needs positive values") }
        var emg = config.emg ?? EMGConfig()
        emg.burstsPerMinute = value
        config.emg = emg
    case "emg-amplitude":
        guard value > 0 else { throw SimulateError.usage("an EMG-amplitude sweep needs positive values") }
        var emg = config.emg ?? EMGConfig()
        emg.amplitudeMicrovolts = value
        config.emg = emg
    case "sources":
        guard config.eegGenerationModel == .dipole else {
            throw SimulateError.usage("a sources sweep requires --eeg-model dipole")
        }
        guard value > 0, value == value.rounded() else {
            throw SimulateError.usage("a sources sweep needs positive whole-number values")
        }
        config.dipoleSourceCount = Int(value)
    default:
        throw SimulateError.usage(
            "unknown --parameter \"\(parameter)\"; expected one of qrs-jitter, bcg-amplitude, "
            + "gradient-amplitude, slow-modulation, clock-offset, rate, impedance, sources, "
            + "emg-rate, emg-amplitude"
        )
    }
}

func runSweep(_ arguments: Arguments) throws {
    try arguments.validate(known: generateOptions.union(["parameter", "values"]))

    if arguments.string("write-config") != nil {
        throw SimulateError.usage(
            "--write-config is ambiguous for a sweep; save the base scenario with generate first"
        )
    }

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
        let config = try makeConfig(arguments)
        if let path = arguments.string("write-config") {
            guard !arguments.flag("write-config") else {
                throw SimulateError.usage("--write-config needs a JSON file path")
            }
            let url = URL(fileURLWithPath: path)
            try SimulationScenarioFile.write(config: config, to: url)
            print("Wrote \(url.path)")
        }
        if let output = arguments.string("output") {
            try runGenerate(
                config: config,
                arguments: arguments,
                outputDirectory: URL(fileURLWithPath: output)
            )
        } else if arguments.string("write-config") == nil {
            throw SimulateError.usage("generate needs --output <dir> or --write-config <json>")
        }
    case "generate-group":
        try runGenerateGroup(arguments)
    case "correct":
        try runCorrect(arguments)
    case "evaluate-surrogate":
        try runEvaluateSurrogate(arguments)
    case "score":
        try runScore(arguments)
    case "score-sources":
        try runSourceScore(arguments)
    case "score-events":
        try runEventScore(arguments)
    case "score-erp":
        try runERPScore(arguments)
    case "score-pac":
        try runPACScore(arguments)
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
