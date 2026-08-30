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
