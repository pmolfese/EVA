//
//  SimulatorRunner.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-1: drives the EVASimulate command-line tool that ships inside the app
//  bundle (SIM-0 embeds it at Contents/MacOS/EVASimulate) to generate a
//  simulated recording, then hands the resulting `.mff` back so the GUI can open
//  it through the ordinary recording path.
//
//  Why shell out rather than generate in-process: the generation *core* now lives
//  in the EVA module and can be called directly, but the MFF *writer*
//  (SimulationWriter) is deliberately CLI-side. Authoring the same
//  `SimulationScenario` JSON the CLI reads — via `SimulationScenarioFile.write`,
//  which is in-module — and letting the CLI serialize it guarantees the GUI
//  produces exactly the artifact the tool produces (round-trip parity), and the
//  output is a real MFF that flows through EVA's pipeline unchanged.
//
//  Sandbox note: the CLI always writes into a container-temp directory the app
//  controls, because a child process does NOT inherit the app's security-scoped
//  access to a user-picked folder. When the user chooses an output directory, the
//  *app* (which does hold that access) copies the results there afterwards.
//

import Foundation

nonisolated enum SimulatorRunner {

    /// User-facing generation options beyond the model config itself.
    struct Options: Sendable {
        /// Where the finished files should end up. `nil` leaves them in the
        /// container-temp working directory (fine for a throwaway open).
        var outputDirectory: URL?
        /// Filename prefix — `sim` gives `sim_noisy.mff`, etc.
        var prefix: String = "sim"
        /// Also write the source-space ground truth (`--write-sources`). Requires
        /// the dipole EEG model; the CLI errors otherwise, which we surface.
        var writeSources: Bool = false
        /// A user-picked `coordinates.xml` or MFF whose montage overrides the
        /// built-in one. Staged into the run's temp dir so the sandboxed CLI child
        /// can read it, then referenced as the config's `coordinatesPath`.
        var coordinatesFile: URL?
    }

    /// The files a successful `generate` run leaves behind.
    struct Output: Sendable {
        /// The contaminated recording — what a user reviews and cleans. This is
        /// the one SIM-1 opens.
        let noisyURL: URL
        /// The uncontaminated ground-truth EEG.
        let cleanURL: URL
        /// The truth sidecar (true beat times, artifact amplitudes, seed, …).
        let truthURL: URL
        /// The exact scenario JSON handed to the tool (the reproducible input).
        let scenarioURL: URL
        /// A record of the exact command used to generate this run.
        let commandURL: URL
        /// The directory holding everything, so the caller can reveal or clean it.
        let directory: URL
    }

    // MARK: - Scoring DTOs
    //
    // `CorrectionScore` and its nested types live in the CLI-side SNRMetrics.swift
    // (not the app module), so we decode the tool's `--json` output into these
    // app-side mirrors rather than sharing the type.

    struct ScoreBand: Decodable, Sendable, Identifiable {
        var name: String
        var lowHz: Double
        var highHz: Double
        var snr: Double
        var powerRatioDb: Double
        var cleanRMS: Double
        var residualRMS: Double
        var correlation: Double
        var spectralDistortionDbRMS: Double
        var id: String { name }
    }

    struct ScoreChannel: Decodable, Sendable, Identifiable {
        var name: String
        var snr: Double
        var rmseMicrovolts: Double
        var correlation: Double
        var cleanStandardDeviation: Double
        var residualStandardDeviation: Double
        var spectralDistortionDbRMS: Double
        var id: String { name }
    }

    struct Score: Decodable, Sendable, Identifiable {
        var label: String
        var broadbandSNR: Double
        var cleanStandardDeviation: Double
        var residualStandardDeviation: Double
        var broadbandRMSEMicrovolts: Double
        var broadbandCorrelation: Double
        var spectralDistortionDbRMS: Double
        var bands: [ScoreBand]
        var channels: [ScoreChannel]
        var id: String { label }
    }

    enum RunError: LocalizedError {
        case cliNotFound(String)
        case failed(status: Int32, log: String)
        case missingOutput(URL, log: String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound(let detail):
                return "Could not find the bundled EVASimulate tool. \(detail)"
            case .failed(let status, let log):
                let tail = SimulatorRunner.tail(of: log)
                return "EVASimulate exited with status \(status).\(tail.isEmpty ? "" : "\n\(tail)")"
            case .missingOutput(let url, let log):
                let tail = SimulatorRunner.tail(of: log)
                return "EVASimulate reported success but \(url.lastPathComponent) is missing."
                    + (tail.isEmpty ? "" : "\n\(tail)")
            }
        }
    }

    /// A record of exactly how a recording was generated, written next to the
    /// outputs as `<prefix>_command.json` so a run is reproducible from disk.
    private struct CommandRecord: Codable {
        var command: String
        var executable: String
        var arguments: [String]
        var generatedAt: String
        var generatedBy: String
    }

    /// The embedded CLI, sitting next to the app's own executable in
    /// `Contents/MacOS/`. `Bundle.main` is the EVA app bundle at runtime, so its
    /// executable's directory is where SIM-0's Copy Files phase placed the tool.
    static func locateCLI() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let candidate = executable.deletingLastPathComponent()
            .appendingPathComponent("EVASimulate")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Serializes `config` to a scenario JSON, runs `EVASimulate generate`, writes
    /// a command record, optionally relocates everything into a user-chosen
    /// directory, and returns the written files. Blocking — call it off the main
    /// thread.
    static func generate(
        config: SimulationConfig,
        name: String,
        options: Options = Options()
    ) throws -> Output {
        guard let cli = locateCLI() else {
            throw RunError.cliNotFound(
                "Expected it beside the app executable at Contents/MacOS/EVASimulate."
            )
        }

        let fm = FileManager.default
        // Always generate into a container-temp workspace the child can write to.
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("EVASimulate", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let prefix = options.prefix.isEmpty ? "sim" : options.prefix

        // Stage an imported coordinates file into the workspace so the sandboxed
        // child can read it, and point the config at that copy.
        var config = config
        try applyCoordinates(options.coordinatesFile, into: &config, workDir: workDir)

        let scenarioURL = workDir.appendingPathComponent("\(prefix)_scenario.json")
        try SimulationScenarioFile.write(
            config: config,
            to: scenarioURL,
            name: name.isEmpty ? "Simulated Recording" : name,
            description: "Authored in EVA (SIM-1)"
        )

        var arguments = [
            "generate",
            "--config", scenarioURL.path,
            "--output", workDir.path,
            "--prefix", prefix,
        ]
        if options.writeSources { arguments.append("--write-sources") }

        // Record the command before running, so a failed run is still explained.
        let commandURL = workDir.appendingPathComponent("\(prefix)_command.json")
        try writeCommandRecord(
            executable: cli, arguments: arguments, to: commandURL
        )

        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Drain before waiting so a chatty run cannot deadlock on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw RunError.failed(status: process.terminationStatus, log: log)
        }

        let noisyInWork = workDir.appendingPathComponent("\(prefix)_noisy.mff")
        guard fm.fileExists(atPath: noisyInWork.path) else {
            throw RunError.missingOutput(noisyInWork, log: log)
        }

        // Relocate into the chosen directory if any, using the app's own
        // (security-scoped) access rather than the sandboxed child's.
        let directory = try relocateIfNeeded(
            from: workDir, prefix: prefix, to: options.outputDirectory
        )

        return Output(
            noisyURL: directory.appendingPathComponent("\(prefix)_noisy.mff"),
            cleanURL: directory.appendingPathComponent("\(prefix)_clean.mff"),
            truthURL: directory.appendingPathComponent("\(prefix)_truth.json"),
            scenarioURL: directory.appendingPathComponent("\(prefix)_scenario.json"),
            commandURL: directory.appendingPathComponent("\(prefix)_command.json"),
            directory: directory
        )
    }

    // MARK: - Scoring

    /// The outcome of a `score` run: the corrected recording's fidelity against
    /// truth, and — when a baseline was supplied — the uncorrected recording's,
    /// so the UI can show what the correction actually bought.
    struct ScoreOutcome: Sendable {
        var corrected: Score
        var baseline: Score?
    }

    /// Runs `EVASimulate score`, comparing `corrected` against the ground-truth
    /// `truth` recording (optionally alongside the uncorrected `baseline`), and
    /// returns the decoded metrics. Blocking — call it off the main thread.
    ///
    /// Inputs are staged into a container-temp directory first: the CLI child
    /// cannot read user-picked `.mff` packages outside the app's container, but
    /// the app (which holds the scoped access) can copy them in.
    static func score(
        truth: URL,
        corrected: URL,
        baseline: URL? = nil,
        label: String? = nil,
        padSeconds: Double? = nil
    ) throws -> ScoreOutcome {
        guard let cli = locateCLI() else {
            throw RunError.cliNotFound(
                "Expected it beside the app executable at Contents/MacOS/EVASimulate."
            )
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("EVASimulateScore", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let truthLocal = try stageInput(truth, into: workDir, as: "truth.mff")
        let correctedLocal = try stageInput(corrected, into: workDir, as: "corrected.mff")
        let baselineLocal = try baseline.map { try stageInput($0, into: workDir, as: "baseline.mff") }

        let jsonURL = workDir.appendingPathComponent("score.json")
        var arguments = [
            "score",
            "--truth", truthLocal.path,
            "--corrected", correctedLocal.path,
            "--json", jsonURL.path,
        ]
        if let baselineLocal { arguments += ["--baseline", baselineLocal.path] }
        if let label, !label.isEmpty { arguments += ["--label", label] }
        if let padSeconds { arguments += ["--pad-seconds", String(padSeconds)] }

        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw RunError.failed(status: process.terminationStatus, log: log)
        }
        guard fm.fileExists(atPath: jsonURL.path) else {
            throw RunError.missingOutput(jsonURL, log: log)
        }

        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let scores = try decoder.decode([Score].self, from: Data(contentsOf: jsonURL))
        guard let corrected = scores.first else {
            throw RunError.missingOutput(jsonURL, log: log)
        }
        // The CLI writes [score] or [score, baseline] in that order.
        return ScoreOutcome(corrected: corrected, baseline: scores.dropFirst().first)
    }

    /// Copies a (possibly security-scoped, possibly outside-container) `.mff`
    /// package into `workDir` so the sandboxed CLI child can read it.
    private static func stageInput(_ source: URL, into workDir: URL, as name: String) throws -> URL {
        let fm = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let destination = workDir.appendingPathComponent(name)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
        return destination
    }

    // MARK: - Sweep

    /// The parameters the CLI `sweep` accepts.
    static let sweepParameters = [
        "rate", "bcg-amplitude", "gradient-amplitude", "clock-offset",
        "slow-modulation", "qrs-jitter", "impedance", "emg-rate", "emg-amplitude", "sources",
    ]

    struct SweepRun: Sendable, Identifiable {
        let id = UUID()
        let value: Double
        let uncorrectedSNR: Double
        let noisyURL: URL
        let directory: URL
    }
    struct SweepOutcome: Sendable {
        let parameter: String
        let runs: [SweepRun]
        let directory: URL
    }

    /// Runs `EVASimulate sweep`: one generation per value of a parameter, varying
    /// the current base `config`. Returns the parsed `sweep_summary.csv`.
    static func sweep(
        config: SimulationConfig, name: String,
        parameter: String, values: [Double], options: Options
    ) throws -> SweepOutcome {
        guard let cli = locateCLI() else {
            throw RunError.cliNotFound("Expected it beside the app executable at Contents/MacOS/EVASimulate.")
        }
        let fm = FileManager.default
        let workDir = try makeWorkDir("EVASimulateSweep")

        var config = config
        try applyCoordinates(options.coordinatesFile, into: &config, workDir: workDir)
        let prefix = options.prefix.isEmpty ? "sim" : options.prefix
        let scenarioURL = workDir.appendingPathComponent("\(prefix)_scenario.json")
        try SimulationScenarioFile.write(config: config, to: scenarioURL,
                                         name: name.isEmpty ? "Sweep base" : name,
                                         description: "Sweep base (SIM-1)")

        let csv = values.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }.joined(separator: ",")
        let log = try run(cli, [
            "sweep", "--config", scenarioURL.path, "--parameter", parameter,
            "--values", csv, "--output", workDir.path, "--prefix", prefix,
        ])

        let summary = workDir.appendingPathComponent("sweep_summary.csv")
        guard fm.fileExists(atPath: summary.path) else { throw RunError.missingOutput(summary, log: log) }

        let directory = try relocateTree(from: workDir, to: options.outputDirectory)
        let text = try String(contentsOf: directory.appendingPathComponent("sweep_summary.csv"), encoding: .utf8)
        var runs: [SweepRun] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let value = Double(fields[1]), let snr = Double(fields[2]) else { continue }
            let subdir = directory.appendingPathComponent((fields[3] as NSString).lastPathComponent)
            runs.append(SweepRun(value: value, uncorrectedSNR: snr,
                                 noisyURL: subdir.appendingPathComponent("\(prefix)_noisy.mff"),
                                 directory: subdir))
        }
        return SweepOutcome(parameter: parameter, runs: runs, directory: directory)
    }

    // MARK: - Group

    /// Between-subject variability for a group run (SDs; 0 leaves the CLI default).
    struct GroupVariability: Sendable {
        var homogeneous = false
        var headRadiusSD = 0.08
        var placementSD = 3.0
        var alphaSD = 0.25
        var bcgSD = 0.2
        var impedanceSD = 0.3
        var heartRateSD = 8.0
        var erpEffectSD = 0.3
    }

    struct GroupSubject: Sendable, Identifiable {
        let id = UUID()
        let label: String
        let noisyURL: URL
        let directory: URL
    }
    struct GroupOutcome: Sendable {
        let subjects: [GroupSubject]
        let participantsTSV: URL?
        let directory: URL
    }

    /// Runs `EVASimulate generate-group`: a cohort of subjects drawn around the
    /// base `config` with the given between-subject variability.
    static func generateGroup(
        config: SimulationConfig, name: String,
        subjects: Int, groupSeed: UInt64?, variability: GroupVariability, options: Options
    ) throws -> GroupOutcome {
        guard let cli = locateCLI() else {
            throw RunError.cliNotFound("Expected it beside the app executable at Contents/MacOS/EVASimulate.")
        }
        let fm = FileManager.default
        let workDir = try makeWorkDir("EVASimulateGroup")

        var config = config
        try applyCoordinates(options.coordinatesFile, into: &config, workDir: workDir)
        let prefix = options.prefix.isEmpty ? "sim" : options.prefix
        let scenarioURL = workDir.appendingPathComponent("\(prefix)_scenario.json")
        try SimulationScenarioFile.write(config: config, to: scenarioURL,
                                         name: name.isEmpty ? "Group base" : name,
                                         description: "Group base (SIM-1)")

        var arguments = [
            "generate-group", "--config", scenarioURL.path,
            "--subjects", String(subjects), "--output", workDir.path, "--prefix", prefix,
        ]
        if let groupSeed { arguments += ["--group-seed", String(groupSeed)] }
        if variability.homogeneous {
            arguments.append("--homogeneous")
        } else {
            arguments += ["--head-radius-sd", String(variability.headRadiusSD)]
            arguments += ["--placement-sd", String(variability.placementSD)]
            arguments += ["--alpha-sd", String(variability.alphaSD)]
            arguments += ["--bcg-sd", String(variability.bcgSD)]
            arguments += ["--impedance-sd", String(variability.impedanceSD)]
            arguments += ["--heart-rate-sd", String(variability.heartRateSD)]
            arguments += ["--erp-effect-sd", String(variability.erpEffectSD)]
        }
        _ = try run(cli, arguments)

        let directory = try relocateTree(from: workDir, to: options.outputDirectory)
        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let subjectDirs = contents
            .filter { $0.lastPathComponent.hasPrefix("sub-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let subjectList = subjectDirs.map { dir in
            GroupSubject(label: String(dir.lastPathComponent.dropFirst("sub-".count)),
                         noisyURL: dir.appendingPathComponent("\(prefix)_noisy.mff"),
                         directory: dir)
        }
        let tsv = contents.first { $0.pathExtension == "tsv" }
        return GroupOutcome(subjects: subjectList, participantsTSV: tsv, directory: directory)
    }

    // MARK: - Shared helpers

    private static func makeWorkDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stages an imported coordinates file into `workDir` and points the config at
    /// the copy, so the sandboxed child can read it.
    private static func applyCoordinates(_ file: URL?, into config: inout SimulationConfig, workDir: URL) throws {
        guard let source = file else { return }
        let fm = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let staged = workDir.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        config.coordinatesPath = staged.path
    }

    /// Runs the CLI with `arguments`, draining output; throws on non-zero exit.
    @discardableResult
    private static func run(_ cli: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw RunError.failed(status: process.terminationStatus, log: log)
        }
        return log
    }

    /// Copies every child of `workDir` into `destination` (or returns `workDir`
    /// when `destination` is nil), using the app's security-scoped access.
    private static func relocateTree(from workDir: URL, to destination: URL?) throws -> URL {
        guard let destination else { return workDir }
        let fm = FileManager.default
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in (try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? [] {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: child, to: target)
        }
        try? fm.removeItem(at: workDir)
        return destination
    }

    // MARK: - Helpers

    private static func writeCommandRecord(
        executable: URL, arguments: [String], to url: URL
    ) throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let record = CommandRecord(
            command: shellCommand(executable: executable, arguments: arguments),
            executable: executable.path,
            arguments: arguments,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            generatedBy: "EVA \(version ?? "?") · SIM-1 Simulated Recording"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    /// A copy-pasteable command line, quoting any argument that needs it.
    private static func shellCommand(executable: URL, arguments: [String]) -> String {
        ([executable.lastPathComponent] + arguments).map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ token: String) -> String {
        guard token.contains(where: { " \t\n\"'\\$`".contains($0) }) else { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Copies the produced files (mff packages, truth, scenario, command record)
    /// into `destination`, overwriting only same-prefix entries. Returns the
    /// directory the files now live in.
    private static func relocateIfNeeded(
        from workDir: URL, prefix: String, to destination: URL?
    ) throws -> URL {
        guard let destination else { return workDir }
        let fm = FileManager.default

        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let names = [
            "\(prefix)_noisy.mff",
            "\(prefix)_clean.mff",
            "\(prefix)_sources.mff",
            "\(prefix)_truth.json",
            "\(prefix)_scenario.json",
            "\(prefix)_command.json",
        ]
        for name in names {
            let source = workDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue } // sources is optional
            let target = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: source, to: target)
        }
        // Best-effort cleanup of the temp workspace.
        try? fm.removeItem(at: workDir)
        return destination
    }

    /// Last few non-empty lines of the tool's output, for surfacing a failure
    /// reason without dumping the whole log into an alert.
    private static func tail(of log: String, lines: Int = 4) -> String {
        log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
    }
}
