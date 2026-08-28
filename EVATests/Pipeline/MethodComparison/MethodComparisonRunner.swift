//
//  MethodComparisonRunner.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The executable half of the method-comparison harness (roadmap 3.2).
//
//  The loop, per (scenario, seed, method arm):
//
//      eva-simulate generate -> EVA processes headlessly -> eva-simulate score
//
//  which is the Tier 7 loop with a different question asked of it. Tier 7 asks
//  "is this method still as good as it was?" and answers pass or fail. This asks
//  "which method is better, and by how much?" and answers with a table.
//
//  ## Why this lives in the test target
//
//  `Tools/EVASimulate` is a standalone SwiftPM package and cannot link EVA's app
//  code, so it cannot invoke `MRIGradientMethod` at all. Driving EVA headlessly
//  requires being inside the app target's module, which is what the test target
//  already is — and `HeadlessBatchProcessor` + `EVAProcessingScript` is the seam
//  `PipelineRegressionTests` has been using for this since Tier 7. Building a
//  second way to drive the pipeline for the sake of a nicer command line would
//  put a second implementation between the paper's numbers and the shipped app.
//
//  ## Why scoring shells out
//
//  The rich metric set — per-band residuals, spectral distortion, per-channel
//  breakdown — exists once, in `SNRMetrics`, inside the simulator package. A
//  table for publication should be computed by that implementation rather than
//  by a second one written here, so the comparison harness invokes
//  `eva-simulate score --json` and decodes the result.
//
//  This is deliberately *not* what `PipelineRegressionTests` does: its
//  assertions recompute broadband SNR in-process so a regression check never
//  depends on an external binary being built. The two are kept honest against
//  each other by `harnessSNRAgreesWithInProcessSNR`, which is the check that
//  actually matters — one number, two implementations, compared.
//
//  ## Running
//
//      EVA_COMPARISON=1 xcodebuild test -only-testing:EVATests/MethodComparisonTests
//
//  Nothing runs without that variable. A full matrix is minutes of compute per
//  arm, and a comparison is something someone asks for, not something a routine
//  test run should pay for.
//

import Foundation
@testable import EVA

// MARK: - Results

/// One scored cell: one method arm, on one scenario, at one seed.
struct ComparisonResult: Codable, Sendable {
    var scenario: String
    var seed: Int
    var method: String
    var methodLabel: String
    var broadbandSNR: Double
    var broadbandRMSEMicrovolts: Double
    var broadbandCorrelation: Double
    var spectralDistortionDbRMS: Double
    /// The arm's analytic best case, where one exists.
    var ceiling: Double?
    /// True when the arm scored above its own ceiling — evidence of ground
    /// truth reaching the correction, not of an unusually good method.
    var exceedsCeiling: Bool
    /// Wall-clock seconds for the EVA processing run. Zero for the uncorrected
    /// arm, which does no processing.
    var processingSeconds: Double
    /// What EVA recorded about its own run, read back from the audit log in the
    /// processed package: the resolved method, epoch counts, removed variance,
    /// and any warnings.
    ///
    /// A comparison without this is not interpretable. A method that fell back
    /// — no motion parameters, too few donors, a rejected template scale — still
    /// emits a perfectly valid recording and a perfectly plausible score, and
    /// the table would report that fallback as the method's performance. This
    /// is the same failure the matrix documents for Moosmann, except discovered
    /// after the fact instead of before.
    var auditLines: [String]
    /// Audit lines EVA labelled as warnings. Present in the table so a reader
    /// can see which rows ran clean.
    var warnings: [String]
}

/// Per-(scenario, method) summary across seeds. Written *alongside* the
/// per-seed rows, never instead of them: a collapsed mean is not enough to
/// re-derive a paired comparison, and 2.3 already settled that a repeated
/// evaluation must publish every value it averaged.
struct ComparisonSummary: Codable, Sendable {
    var scenario: String
    var method: String
    var methodLabel: String
    var seedCount: Int
    var meanBroadbandSNR: Double
    /// Sample standard deviation, or `nil` from a single seed — where the
    /// honest answer is that the spread is unmeasured, not that it is zero.
    var sdBroadbandSNR: Double?
    var meanBroadbandRMSEMicrovolts: Double
    var sdBroadbandRMSEMicrovolts: Double?
    var meanBroadbandCorrelation: Double
}

/// One arm's difference from the reference arm, measured *within* seed.
///
/// The comparison that matters is not "method A averaged 2.47 and method B
/// averaged 2.76". Both arms saw the identical recording at each seed, so the
/// per-seed difference removes the recording-to-recording variation entirely
/// and the spread that remains is the spread of the *difference* — which is
/// usually far smaller than the spread of either arm, and is the quantity a
/// reader needs in order to believe a ranking.
struct PairedDifference: Codable, Sendable {
    var scenario: String
    /// The arm being described.
    var method: String
    var methodLabel: String
    /// The arm it is measured against — `ComparisonMatrix.referenceMethod`.
    var versus: String
    var seedCount: Int
    /// Mean of (method − reference) across seeds, in broadband SNR.
    var meanDifference: Double
    /// Sample SD of those per-seed differences, or `nil` from a single seed.
    var sdDifference: Double?
    /// 95% confidence interval for the mean difference, from Student's t with
    /// `seedCount - 1` degrees of freedom. Absent below two seeds.
    var confidenceIntervalLow: Double?
    var confidenceIntervalHigh: Double?
    /// `meanDifference / (sd / sqrt(n))`. Absent below two seeds, or when every
    /// seed produced exactly the same difference.
    var tStatistic: Double?
    /// True when the 95% interval excludes zero. Deliberately not called
    /// "significant": with five seeds of a deterministic simulator this says
    /// the difference is larger than the seed-to-seed noise of *this* setup,
    /// which is a much narrower claim than a result about EEG recordings.
    var intervalExcludesZero: Bool
}

/// What produced these numbers, recorded so a table can be re-derived rather
/// than trusted.
struct ComparisonProvenance: Codable, Sendable {
    /// EVA's own version string, the same one it writes into every export.
    var evaVersion: String
    var operatingSystem: String
    var architecture: String
    /// Resolved scenario configurations written beside the results, by scenario
    /// id. Each is the *complete* configuration the generator actually used —
    /// the scenario file with every override already applied — so a reviewer
    /// regenerates from that file rather than reconstructing a command line.
    var resolvedScenarioFiles: [String: String]
    /// Free-text note about what was pinned across all arms.
    var note: String
}

/// The complete, self-describing output of one comparison run.
struct ComparisonReport: Codable, Sendable {
    var schemaVersion: Int
    var matrixName: String
    var matrixDescription: String
    var generatedAt: Date
    var seeds: [Int]
    var scenarios: [String]
    /// id -> citation, so a table can be captioned from the results file alone.
    var citations: [String: String]
    var results: [ComparisonResult]
    var summaries: [ComparisonSummary]
    var pairedDifferences: [PairedDifference]
    var provenance: ComparisonProvenance
}

// MARK: - Runner

enum MethodComparisonRunner {

    enum RunError: Error, CustomStringConvertible {
        case simulatorMissing(URL)
        case scenarioMissing(URL)
        case commandFailed(command: String, status: Int32, output: String)
        case scoreUnreadable(URL, Error)
        case scoreEmpty(URL)
        case processingIncomplete(method: String, detail: String)

        var description: String {
            switch self {
            case let .simulatorMissing(url):
                return """
                    no eva-simulate binary at \(url.path). Build it with \
                    `swift build -c release --package-path Tools/EVASimulate` (or run \
                    ./run-all-tests.sh, which builds it).
                    """
            case let .scenarioMissing(url):
                return "no scenario file at \(url.path)"
            case let .commandFailed(command, status, output):
                return "`\(command)` exited \(status):\n\(output)"
            case let .scoreUnreadable(url, error):
                return "could not decode score JSON at \(url.path): \(error)"
            case let .scoreEmpty(url):
                return "score JSON at \(url.path) contained no scores"
            case let .processingIncomplete(method, detail):
                return "method arm \"\(method)\" did not complete: \(detail)"
            }
        }
    }

    // MARK: Locations

    /// `<repo>`, resolved from this file rather than the working directory,
    /// which xcodebuild does not set predictably.
    static let repositoryRoot: URL = {
        URL(fileURLWithPath: #filePath)  // <repo>/EVATests/Pipeline/MethodComparison/ThisFile.swift
            .deletingLastPathComponent() // <repo>/EVATests/Pipeline/MethodComparison
            .deletingLastPathComponent() // <repo>/EVATests/Pipeline
            .deletingLastPathComponent() // <repo>/EVATests
            .deletingLastPathComponent() // <repo>
    }()

    static let simulatorBinary = repositoryRoot
        .appendingPathComponent("Tools/EVASimulate/.build/eva-simulate")

    static let scenarioDirectory = repositoryRoot
        .appendingPathComponent("Tools/EVASimulate/scenarios")

    static let matrixDirectory = repositoryRoot
        .appendingPathComponent("EVATests/Pipeline/MethodComparison")

    /// Generated recordings and results.
    ///
    /// **Not in the repository, and it cannot be.** The test host is the EVA
    /// app, which is sandboxed: it can read the working tree but writing to it
    /// fails with `NSCocoaErrorDomain 513`, and a child process it spawns —
    /// `eva-simulate` — inherits that sandbox. So the harness writes inside the
    /// app container, which is writable, deterministic, and survives between
    /// runs so a generated corpus can be reused.
    ///
    /// `compare-methods.sh` copies the results back into `<repo>/.comparison`
    /// afterwards, from outside the sandbox where that is allowed. Anyone
    /// running the test directly gets the container path printed instead.
    ///
    /// Safe to delete either way: it is rebuilt from the matrix plus the seeds,
    /// both of which are committed.
    static let workingDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["EVA_COMPARISON_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return (support ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("EVAComparison")
    }()

    // MARK: Corpus

    /// Generates `<working>/corpus/<scenario>/seed-<n>/sim_{clean,noisy}.mff`,
    /// reusing an existing directory unless `EVA_COMPARISON_REGENERATE=1`.
    ///
    /// Reuse is safe because the generator is deterministic in the seed — the
    /// determinism check exists precisely so this can be assumed — and matters
    /// because iterating on a method arm should not re-pay for generation.
    static func corpus(
        for scenario: ComparisonMatrix.Scenario, seed: Int
    ) throws -> (clean: URL, noisy: URL) {
        let directory = workingDirectory
            .appendingPathComponent("corpus")
            .appendingPathComponent(scenario.id)
            .appendingPathComponent("seed-\(seed)")
        let clean = directory.appendingPathComponent("sim_clean.mff")
        let noisy = directory.appendingPathComponent("sim_noisy.mff")

        let regenerate = ProcessInfo.processInfo.environment["EVA_COMPARISON_REGENERATE"] == "1"
        let present = FileManager.default.fileExists(atPath: clean.path)
            && FileManager.default.fileExists(atPath: noisy.path)
        if present, !regenerate { return (clean, noisy) }

        let scenarioURL = scenarioDirectory.appendingPathComponent(scenario.scenarioFile)
        guard FileManager.default.fileExists(atPath: scenarioURL.path) else {
            throw RunError.scenarioMissing(scenarioURL)
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var arguments = ["generate", "--config", scenarioURL.path, "--seed", String(seed)]
        arguments += scenario.generateArguments
        arguments += ["--output", directory.path]
        _ = try run(simulatorBinary, arguments)

        return (clean, noisy)
    }

    /// Asks the generator to resolve `scenario` — its file plus every override
    /// — and writes the complete configuration to `destination`.
    ///
    /// `generate --write-config` without `--output` resolves and exits without
    /// simulating, so this costs nothing and produces the one artifact a
    /// reviewer actually needs: not the command line that was typed, but the
    /// configuration it amounted to.
    static func writeResolvedScenario(
        _ scenario: ComparisonMatrix.Scenario, to destination: URL
    ) throws {
        let scenarioURL = scenarioDirectory.appendingPathComponent(scenario.scenarioFile)
        guard FileManager.default.fileExists(atPath: scenarioURL.path) else {
            throw RunError.scenarioMissing(scenarioURL)
        }
        var arguments = ["generate", "--config", scenarioURL.path]
        arguments += scenario.generateArguments
        arguments += ["--write-config", destination.path]
        _ = try run(simulatorBinary, arguments)
    }

    // MARK: One cell

    @MainActor
    static func evaluate(
        method: ComparisonMatrix.Method,
        scenario: ComparisonMatrix.Scenario,
        seed: Int,
        matrix: ComparisonMatrix
    ) async throws -> ComparisonResult {
        let (clean, noisy) = try corpus(for: scenario, seed: seed)

        let scored: URL
        var processingSeconds = 0.0

        switch method.kind {
        case .uncorrected:
            // The floor arm reads the generated recording unchanged. No EVA
            // step runs, which is the point: this is what the table's other
            // numbers are improvements *over*.
            scored = noisy

        case .eva:
            guard let script = matrix.script(for: method) else {
                throw RunError.processingIncomplete(method: method.id, detail: "no script")
            }
            let outputFolder = workingDirectory
                .appendingPathComponent("runs")
                .appendingPathComponent("\(scenario.id)-seed\(seed)-\(method.id)")
            try? FileManager.default.removeItem(at: outputFolder)
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

            let started = Date()
            let outcome = try await HeadlessBatchProcessor.process(
                url: noisy, script: script, outputFolder: outputFolder
            )
            processingSeconds = Date().timeIntervalSince(started)

            guard case let .completed(url) = outcome else {
                // `needsInput` here means the script asked for something a
                // headless run cannot supply. Surfacing it as a failed arm
                // rather than a missing row keeps the table's shape honest.
                throw RunError.processingIncomplete(
                    method: method.id, detail: "\(outcome) — the script is not fully headless-capable"
                )
            }
            scored = url
        }

        let score = try score(
            truth: clean, corrected: scored, label: method.id, padSeconds: scenario.padSeconds
        )
        let ceiling = method.ceiling?.resolved(for: method)
        let audit = method.kind == .eva ? auditLines(inPackage: scored) : []

        return ComparisonResult(
            scenario: scenario.id,
            seed: seed,
            method: method.id,
            methodLabel: method.label,
            broadbandSNR: score.broadbandSNR,
            broadbandRMSEMicrovolts: score.broadbandRMSEMicrovolts,
            broadbandCorrelation: score.broadbandCorrelation,
            spectralDistortionDbRMS: score.spectralDistortionDbRMS,
            ceiling: ceiling,
            exceedsCeiling: ceiling.map { score.broadbandSNR > $0 } ?? false,
            processingSeconds: processingSeconds,
            auditLines: audit,
            warnings: audit.filter { $0.contains("warning:") }
        )
    }

    // MARK: Whole matrix

    @MainActor
    static func run(matrix: ComparisonMatrix) async throws -> ComparisonReport {
        guard FileManager.default.fileExists(atPath: simulatorBinary.path) else {
            throw RunError.simulatorMissing(simulatorBinary)
        }

        var results: [ComparisonResult] = []
        for scenario in matrix.scenarios {
            for seed in matrix.seeds {
                for method in matrix.methods {
                    let result = try await evaluate(
                        method: method, scenario: scenario, seed: seed, matrix: matrix
                    )
                    print(String(
                        format: "  %-22@ %-16@ seed %d   SNR %.4f",
                        scenario.id as NSString, method.id as NSString, seed, result.broadbandSNR
                    ))
                    results.append(result)
                }
            }
        }

        var citations: [String: String] = [:]
        for method in matrix.methods where method.citation != nil {
            citations[method.id] = method.citation
        }

        // Resolved configurations go beside the results, one per scenario.
        let outputDirectory = workingDirectory.appendingPathComponent(matrix.name)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )
        var resolvedFiles: [String: String] = [:]
        for scenario in matrix.scenarios {
            let name = "scenario-\(scenario.id).json"
            try writeResolvedScenario(
                scenario, to: outputDirectory.appendingPathComponent(name)
            )
            resolvedFiles[scenario.id] = name
        }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        return ComparisonReport(
            schemaVersion: ComparisonMatrix.currentSchemaVersion,
            matrixName: matrix.name,
            matrixDescription: matrix.description,
            generatedAt: Date(),
            seeds: matrix.seeds,
            scenarios: matrix.scenarios.map(\.id),
            citations: citations,
            results: results,
            summaries: summarize(results, matrix: matrix),
            pairedDifferences: pairedDifferences(results, matrix: matrix),
            provenance: ComparisonProvenance(
                evaVersion: EVAProcessingScriptXML.currentAppVersion,
                operatingSystem: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                architecture: architecture,
                resolvedScenarioFiles: resolvedFiles,
                note: """
                    Compute backend is pinned per arm in the matrix; Metal and CPU \
                    agree only to a tolerance, so a table mixing them would not be \
                    reproducible. Every arm sees the identical recording at a given \
                    seed, so the paired differences are within-recording.
                    """
            )
        )
    }

    /// Collapses seeds into mean ± SD, preserving the matrix's arm order so the
    /// emitted table reads in the order the matrix declares rather than in
    /// whatever order a dictionary produced.
    static func summarize(
        _ results: [ComparisonResult], matrix: ComparisonMatrix
    ) -> [ComparisonSummary] {
        var summaries: [ComparisonSummary] = []
        for scenario in matrix.scenarios {
            for method in matrix.methods {
                let cells = results.filter { $0.scenario == scenario.id && $0.method == method.id }
                guard !cells.isEmpty else { continue }
                let snr = cells.map(\.broadbandSNR)
                summaries.append(ComparisonSummary(
                    scenario: scenario.id,
                    method: method.id,
                    methodLabel: method.label,
                    seedCount: cells.count,
                    meanBroadbandSNR: mean(snr),
                    sdBroadbandSNR: standardDeviation(snr),
                    meanBroadbandRMSEMicrovolts: mean(cells.map(\.broadbandRMSEMicrovolts)),
                    sdBroadbandRMSEMicrovolts: standardDeviation(cells.map(\.broadbandRMSEMicrovolts)),
                    meanBroadbandCorrelation: mean(cells.map(\.broadbandCorrelation))
                ))
            }
        }
        return summaries
    }

    /// Per-seed differences from the reference arm, one row per other arm.
    ///
    /// Only seeds where *both* arms produced a result are used, and the pairing
    /// is by seed rather than by position, so a missing cell narrows the
    /// comparison instead of silently misaligning it.
    static func pairedDifferences(
        _ results: [ComparisonResult], matrix: ComparisonMatrix
    ) -> [PairedDifference] {
        guard let referenceID = matrix.referenceMethod else { return [] }
        var rows: [PairedDifference] = []

        for scenario in matrix.scenarios {
            let inScenario = results.filter { $0.scenario == scenario.id }
            let reference = Dictionary(
                uniqueKeysWithValues: inScenario
                    .filter { $0.method == referenceID }
                    .map { ($0.seed, $0.broadbandSNR) }
            )
            guard !reference.isEmpty else { continue }

            for method in matrix.methods where method.id != referenceID {
                let differences = inScenario
                    .filter { $0.method == method.id }
                    .compactMap { cell -> Double? in
                        guard let base = reference[cell.seed] else { return nil }
                        return cell.broadbandSNR - base
                    }
                guard !differences.isEmpty else { continue }

                let meanDifference = mean(differences)
                let sd = standardDeviation(differences)
                var low: Double?
                var high: Double?
                var t: Double?
                if let sd, differences.count > 1 {
                    let standardError = sd / Double(differences.count).squareRoot()
                    if standardError > 0 {
                        let half = tCritical95(degreesOfFreedom: differences.count - 1) * standardError
                        low = meanDifference - half
                        high = meanDifference + half
                        t = meanDifference / standardError
                    }
                }

                rows.append(PairedDifference(
                    scenario: scenario.id,
                    method: method.id,
                    methodLabel: method.label,
                    versus: referenceID,
                    seedCount: differences.count,
                    meanDifference: meanDifference,
                    sdDifference: sd,
                    confidenceIntervalLow: low,
                    confidenceIntervalHigh: high,
                    tStatistic: t,
                    intervalExcludesZero: (low.map { $0 > 0 } ?? false)
                        || (high.map { $0 < 0 } ?? false)
                ))
            }
        }
        return rows
    }

    /// Two-sided 95% critical value of Student's t.
    ///
    /// A short table rather than an inverse-CDF implementation: the degrees of
    /// freedom here are the seed count minus one, which is a small number
    /// chosen by hand in the matrix, and a table that is exact for the values
    /// actually used beats a numerical routine that would need its own tests.
    /// Above 30 the normal value is used, where the error is under 2%.
    static func tCritical95(degreesOfFreedom: Int) -> Double {
        let table: [Int: Double] = [
            1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
            7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179,
            13: 2.160, 14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101,
            19: 2.093, 20: 2.086, 21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064,
            25: 2.060, 26: 2.056, 27: 2.052, 28: 2.048, 29: 2.045, 30: 2.042
        ]
        return table[degreesOfFreedom] ?? 1.960
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    /// Sample (n-1) standard deviation, or `nil` below two values.
    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let m = mean(values)
        let sumSquares = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (sumSquares / Double(values.count - 1)).squareRoot()
    }

    // MARK: - Emitting

    /// Long format — one row per (scenario, seed, method, metric).
    ///
    /// Wide tables invite a reader to compare across a row that was never a
    /// comparison, and they have to be restructured before any plotting or
    /// statistics anyway. The rendered table for humans is a separate artifact.
    static func csv(_ report: ComparisonReport) -> String {
        var lines = ["matrix,scenario,seed,method,metric,value"]
        for result in report.results {
            let prefix = "\(report.matrixName),\(result.scenario),\(result.seed),\(result.method)"
            let metrics: [(String, Double)] = [
                ("broadband_snr", result.broadbandSNR),
                ("broadband_rmse_uv", result.broadbandRMSEMicrovolts),
                ("broadband_correlation", result.broadbandCorrelation),
                ("spectral_distortion_db_rms", result.spectralDistortionDbRMS),
                ("processing_seconds", result.processingSeconds)
            ]
            for (name, value) in metrics {
                lines.append("\(prefix),\(name),\(String(format: "%.6f", value))")
            }
            if let ceiling = result.ceiling {
                lines.append("\(prefix),analytic_ceiling,\(String(format: "%.6f", ceiling))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Markdown table per scenario, for reading in a terminal or pasting into
    /// a notebook. Deliberately minimal: publication figures are their own job.
    static func markdown(_ report: ComparisonReport) -> String {
        var out = "# \(report.matrixName)\n\n\(report.matrixDescription)\n"
        out += "\nScores are broadband SNR against the known clean signal: "
        out += "`std(clean) / std(clean - corrected)`. The Warnings column names what EVA "
        out += "reported about its own run — `epochOutOfBounds` on a final epoch is expected, "
        out += "since the recording ends mid-epoch, while anything else means the row may not "
        out += "describe the method it names. Full audit lines for every cell are in "
        out += "`comparison_results.json`.\n"
        for scenario in report.scenarios {
            let rows = report.summaries.filter { $0.scenario == scenario }
            guard !rows.isEmpty else { continue }
            out += "\n## \(scenario)\n\n"
            out += "| Method | Broadband SNR | RMSE (µV) | Correlation | Seeds | Warnings |\n"
            out += "| --- | --- | --- | --- | --- | --- |\n"
            for row in rows {
                let snr = row.sdBroadbandSNR.map {
                    String(format: "%.4f ± %.4f", row.meanBroadbandSNR, $0)
                } ?? String(format: "%.4f", row.meanBroadbandSNR)
                // The *kinds* of warning, not a yes/no. A tail epoch running
                // past the end of the recording is expected and appears for
                // every slice-epoch method; a column that said "no" for that
                // would teach the reader to ignore the column, which is the
                // opposite of why it is here.
                let kinds = warningKinds(
                    in: report.results.filter { $0.scenario == scenario && $0.method == row.method }
                )
                out += String(
                    format: "| %@ | %@ | %.3f | %.4f | %d | %@ |\n",
                    row.methodLabel, snr, row.meanBroadbandRMSEMicrovolts,
                    row.meanBroadbandCorrelation, row.seedCount,
                    kinds.isEmpty ? "—" : kinds.joined(separator: ", ")
                )
            }

            let paired = report.pairedDifferences.filter { $0.scenario == scenario }
            if let reference = paired.first?.versus, !paired.isEmpty {
                out += "\nPaired differences against **\(reference)**, computed within "
                out += "seed — both arms saw the identical recording, so this removes "
                out += "recording-to-recording variation rather than averaging over it.\n\n"
                out += "| Method − \(reference) | Mean Δ SNR | SD of Δ | 95% CI | t |\n"
                out += "| --- | --- | --- | --- | --- |\n"
                for row in paired {
                    let interval: String
                    if let low = row.confidenceIntervalLow, let high = row.confidenceIntervalHigh {
                        interval = String(format: "%+.4f to %+.4f", low, high)
                    } else {
                        interval = "— (one seed)"
                    }
                    out += String(
                        format: "| %@ | %+.4f | %@ | %@%@ | %@ |\n",
                        row.methodLabel, row.meanDifference,
                        row.sdDifference.map { String(format: "%.4f", $0) } ?? "—",
                        interval, row.intervalExcludesZero ? " ✓" : "",
                        row.tStatistic.map { String(format: "%.2f", $0) } ?? "—"
                    )
                }
                out += "\n✓ marks an interval that excludes zero: the difference is larger "
                out += "than the seed-to-seed noise of this setup. That is a statement about "
                out += "this simulator at these settings, not about EEG recordings.\n"
            }
        }

        out += "\n## Provenance\n\n"
        out += "- EVA \(report.provenance.evaVersion) on \(report.provenance.operatingSystem)"
        out += " (\(report.provenance.architecture))\n"
        out += "- Seeds: \(report.seeds.map(String.init).joined(separator: ", "))\n"
        for (scenario, file) in report.provenance.resolvedScenarioFiles.sorted(by: { $0.key < $1.key }) {
            out += "- Resolved configuration for `\(scenario)`: `\(file)`\n"
        }
        out += "- \(report.provenance.note)\n"
        return out
    }

    /// The distinct warning names EVA emitted across these cells, e.g.
    /// `epochOutOfBounds`. The counts and epochs stay in the JSON's audit
    /// lines; the table needs to say *what*, not *how many*.
    static func warningKinds(in results: [ComparisonResult]) -> [String] {
        var kinds: [String] = []
        for line in results.flatMap(\.warnings) {
            guard let range = line.range(of: "warning: ") else { continue }
            let name = line[range.upperBound...]
                .prefix { $0 != " " && $0 != "(" }
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !kinds.contains(name) { kinds.append(name) }
        }
        return kinds.sorted()
    }

    /// Long format again, one row per paired comparison.
    static func pairedCSV(_ report: ComparisonReport) -> String {
        var lines = [
            "matrix,scenario,method,versus,seeds,mean_difference,sd_difference,ci_low,ci_high,t"
        ]
        for row in report.pairedDifferences {
            func number(_ value: Double?) -> String {
                value.map { String(format: "%.6f", $0) } ?? ""
            }
            lines.append([
                report.matrixName, row.scenario, row.method, row.versus,
                String(row.seedCount), number(row.meanDifference), number(row.sdDifference),
                number(row.confidenceIntervalLow), number(row.confidenceIntervalHigh),
                number(row.tStatistic)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `comparison_results.{json,csv,md}` and returns the directory.
    @discardableResult
    static func write(_ report: ComparisonReport) throws -> URL {
        let directory = workingDirectory.appendingPathComponent(report.matrixName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report)
            .write(to: directory.appendingPathComponent("comparison_results.json"))
        try csv(report)
            .write(to: directory.appendingPathComponent("comparison_results.csv"),
                   atomically: true, encoding: .utf8)
        if !report.pairedDifferences.isEmpty {
            try pairedCSV(report)
                .write(to: directory.appendingPathComponent("comparison_paired.csv"),
                       atomically: true, encoding: .utf8)
        }
        try markdown(report)
            .write(to: directory.appendingPathComponent("comparison_results.md"),
                   atomically: true, encoding: .utf8)
        return directory
    }

    /// Reads the `log_eva_*.txt` EVA writes into every package it exports.
    ///
    /// Parsing an emitted artifact rather than reaching into a view model is
    /// deliberate: `HeadlessBatchProcessor` owns its own `ProcessingCore`, and
    /// the alternative — building a second core here so the harness could hold
    /// a reference to it — would mean the comparison ran through a different
    /// path than the one it claims to measure.
    static func auditLines(inPackage url: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return []
        }
        let logs = names.filter { $0.hasPrefix("log_eva_") && $0.hasSuffix(".txt") }.sorted()
        guard let last = logs.last,
              let text = try? String(contentsOf: url.appendingPathComponent(last), encoding: .utf8)
        else { return [] }
        return text
            .split(separator: "\n")
            .map(String.init)
            // Drop the leading timestamp: it is noise in a results file and it
            // makes two otherwise identical runs differ.
            .map { line in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
                return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && !$0.contains("export —") }
    }

    // MARK: - Scoring, via the simulator's own implementation

    /// The subset of `eva-simulate score --json` this harness reads. Decoding a
    /// subset is intentional: the CLI's per-band and per-channel breakdowns
    /// stay in the emitted JSON for anyone who wants them without this file
    /// having to mirror their shape.
    struct SimulatorScore: Codable, Sendable {
        var label: String
        var broadbandSNR: Double
        var broadbandRMSEMicrovolts: Double
        var broadbandCorrelation: Double
        var spectralDistortionDbRMS: Double
    }

    static func score(
        truth: URL, corrected: URL, label: String, padSeconds: Double
    ) throws -> SimulatorScore {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-comparison-score-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        _ = try run(simulatorBinary, [
            "score",
            "--truth", truth.path,
            "--corrected", corrected.path,
            "--label", label,
            "--pad-seconds", String(padSeconds),
            "--json", jsonURL.path
        ])

        let decoder = JSONDecoder()
        // Match the encoder in `runScore`: a perfectly corrected channel has an
        // infinite SNR, and the CLI writes that as a string rather than failing.
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let scores: [SimulatorScore]
        do {
            scores = try decoder.decode([SimulatorScore].self, from: Data(contentsOf: jsonURL))
        } catch {
            throw RunError.scoreUnreadable(jsonURL, error)
        }
        guard let first = scores.first else { throw RunError.scoreEmpty(jsonURL) }
        return first
    }

    // MARK: - Subprocess

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a pipe buffer that fills while the parent waits
        // deadlocks the child, and the simulator is chatty.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RunError.commandFailed(
                command: ([executable.lastPathComponent] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }
}
