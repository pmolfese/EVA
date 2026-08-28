//
//  MethodComparisonTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Entry point and guardrails for the method-comparison harness (roadmap 3.2).
//
//  Two kinds of test live here, and the distinction matters:
//
//  * **Always-on** checks of the committed matrix — that it decodes, that every
//    operation it names exists, that it carries an uncorrected baseline. These
//    cost milliseconds and catch the failure mode that would otherwise surface
//    only when someone sits down to produce a table.
//  * **The run itself**, gated behind `EVA_COMPARISON=1`. Nine arms of headless
//    processing is minutes of compute, which is not something a routine test
//    run should pay for.
//

import Testing
import Foundation
@testable import EVA

struct MethodComparisonTests {

    /// The committed matrix, or one named by `EVA_COMPARISON_MATRIX` — so a
    /// one-off comparison (a different scenario, a narrower set of arms) does
    /// not require editing the file everyone else's runs are compared against.
    static var matrixURL: URL {
        if let override = ProcessInfo.processInfo.environment["EVA_COMPARISON_MATRIX"] {
            return URL(fileURLWithPath: override)
        }
        return committedMatrixURL
    }

    static let committedMatrixURL = MethodComparisonRunner.matrixDirectory
        .appendingPathComponent("comparison-matrix.json")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_COMPARISON"] == "1"
    }

    // MARK: - Always-on: the committed matrix is well formed

    @Test func committedMatrixLoadsAndValidates() throws {
        let matrix = try ComparisonMatrix.load(from: Self.committedMatrixURL)
        #expect(matrix.schemaVersion == ComparisonMatrix.currentSchemaVersion)
        #expect(!matrix.methods.isEmpty)
        #expect(matrix.methods.contains { $0.kind == .uncorrected })
        // Every EVA arm must produce a script, and every script must be one
        // `HeadlessBatchProcessor` can actually run start to finish. An arm that
        // stops halfway would otherwise appear in the table as a poor method
        // rather than as an unrunnable one.
        for method in matrix.methods where method.kind == .eva {
            let script = try #require(matrix.script(for: method))
            #expect(!script.steps.isEmpty, "\(method.id) produced an empty script")
            // `.auto` runs unattended; `.review` runs unattended too and only
            // pauses when a *person* asked to be shown the panel first. Anything
            // else needs a human, and `HeadlessBatchProcessor` would stop at it.
            for step in script.steps {
                #expect(
                    [.auto, .review].contains(step.replayInteraction),
                    "\(method.id) step \(step.operation) is \(step.replayInteraction), which cannot run headlessly"
                )
            }
        }
    }

    @Test func matrixWithoutAnUncorrectedArmIsRejected() throws {
        var matrix = try ComparisonMatrix.load(from: Self.committedMatrixURL)
        matrix.methods.removeAll { $0.kind == .uncorrected }
        #expect(throws: ComparisonMatrix.LoadError.self) { try matrix.validate() }
    }

    @Test func matrixNamingAnUnknownOperationIsRejected() throws {
        var matrix = try ComparisonMatrix.load(from: Self.committedMatrixURL)
        let index = try #require(matrix.methods.firstIndex { $0.kind == .eva })
        matrix.methods[index].steps[0].operation = "polishTheData"
        #expect(throws: ComparisonMatrix.LoadError.self) { try matrix.validate() }
    }

    @Test func duplicateMethodIDsAreRejected() throws {
        var matrix = try ComparisonMatrix.load(from: Self.committedMatrixURL)
        let first = try #require(matrix.methods.first)
        matrix.methods.append(first)
        #expect(throws: ComparisonMatrix.LoadError.self) { try matrix.validate() }
    }

    // MARK: - Always-on: the ceiling rule computes what it claims

    @Test func donorCeilingFollowsSqrtOfDonorsPlusOne() throws {
        let matrix = try ComparisonMatrix.load(from: Self.committedMatrixURL)
        let mas = try #require(matrix.methods.first { $0.id == "mas" })
        let ceiling = try #require(mas.ceiling?.resolved(for: mas))
        // Eight donor volumes: the residual carries the target's own EEG plus
        // 1/8 of each donor's, so the bound is sqrt(9) = 3, plus the small
        // numerical tolerance the matrix declares.
        #expect(abs(ceiling - 3.0 * 1.02) < 1e-9)
    }

    @Test func armsWithoutAClosedFormBestCaseDeclareNoCeiling() throws {
        let matrix = try ComparisonMatrix.load(from: Self.committedMatrixURL)
        for id in ["fastr", "farm", "allen-iar"] {
            let method = try #require(matrix.methods.first { $0.id == id })
            #expect(
                method.ceiling == nil,
                "\(id) declares an analytic ceiling; none is derivable for it"
            )
        }
    }

    @Test func summaryReportsUnmeasuredSpreadRatherThanZero() throws {
        // One seed measures no spread at all. Reporting 0.0 there would claim a
        // precision the run never established.
        #expect(MethodComparisonRunner.standardDeviation([2.9]) == nil)
        let sd = try #require(MethodComparisonRunner.standardDeviation([1, 2, 3]))
        #expect(abs(sd - 1.0) < 1e-12)
    }

    // MARK: - Always-on: the paired statistics

    /// Builds results by hand so the arithmetic is checkable against values
    /// worked out on paper, rather than against whatever the harness happened
    /// to produce last time.
    static func result(
        method: String, seed: Int, snr: Double, scenario: String = "s"
    ) -> ComparisonResult {
        ComparisonResult(
            scenario: scenario, seed: seed, method: method, methodLabel: method,
            broadbandSNR: snr, broadbandRMSEMicrovolts: 0, broadbandCorrelation: 0,
            spectralDistortionDbRMS: 0, ceiling: nil, exceedsCeiling: false,
            processingSeconds: 0, auditLines: [], warnings: []
        )
    }

    static func matrix(
        methods ids: [String], seeds: [Int], reference: String?
    ) -> ComparisonMatrix {
        ComparisonMatrix(
            schemaVersion: ComparisonMatrix.currentSchemaVersion,
            name: "unit", description: "", seeds: seeds,
            scenarios: [.init(
                id: "s", scenarioFile: "x.json", generateArguments: [],
                padSeconds: 0, description: nil
            )],
            methods: ids.map {
                .init(id: $0, label: $0, kind: .uncorrected, citation: nil,
                      steps: [], ceiling: nil, note: nil)
            },
            referenceMethod: reference
        )
    }

    @Test func pairedDifferencesAreComputedWithinSeed() throws {
        // Reference and method both rise steeply across seeds — the recordings
        // differ — while the *difference* is a near-constant +0.5. An unpaired
        // comparison would report that as noise; a paired one sees it.
        let results = [
            Self.result(method: "ref", seed: 1, snr: 1.0), Self.result(method: "arm", seed: 1, snr: 1.5),
            Self.result(method: "ref", seed: 2, snr: 3.0), Self.result(method: "arm", seed: 2, snr: 3.5),
            Self.result(method: "ref", seed: 3, snr: 5.0), Self.result(method: "arm", seed: 3, snr: 5.5)
        ]
        let matrix = Self.matrix(methods: ["ref", "arm"], seeds: [1, 2, 3], reference: "ref")
        let paired = try #require(
            MethodComparisonRunner.pairedDifferences(results, matrix: matrix).first
        )
        #expect(paired.method == "arm")
        #expect(paired.versus == "ref")
        #expect(paired.seedCount == 3)
        #expect(abs(paired.meanDifference - 0.5) < 1e-12)
        // Every per-seed difference is identical, so there is no spread and no
        // finite t — reporting one would be inventing precision.
        #expect(paired.sdDifference == 0)
        #expect(paired.tStatistic == nil)
        #expect(paired.intervalExcludesZero == false)
    }

    @Test func pairedDifferencesIgnoreSeedsTheOtherArmIsMissing() throws {
        // Seed 3 has no reference cell. Pairing by position rather than by seed
        // would compare seed 3 against seed 1's baseline and produce a number
        // that looks perfectly reasonable.
        let results = [
            Self.result(method: "ref", seed: 1, snr: 1.0), Self.result(method: "arm", seed: 1, snr: 2.0),
            Self.result(method: "ref", seed: 2, snr: 1.0), Self.result(method: "arm", seed: 2, snr: 2.0),
            Self.result(method: "arm", seed: 3, snr: 9.0)
        ]
        let matrix = Self.matrix(methods: ["ref", "arm"], seeds: [1, 2, 3], reference: "ref")
        let paired = try #require(
            MethodComparisonRunner.pairedDifferences(results, matrix: matrix).first
        )
        #expect(paired.seedCount == 2)
        #expect(abs(paired.meanDifference - 1.0) < 1e-12)
    }

    @Test func aConfidenceIntervalExcludesZeroOnlyWhenItShould() throws {
        // Differences 0.4, 0.5, 0.6, 0.5, 0.5: mean 0.5, SD 0.0707, SE 0.0316,
        // t(4) = 2.776, so the interval is 0.5 ± 0.0878 and clears zero.
        var results: [ComparisonResult] = []
        for (index, difference) in [0.4, 0.5, 0.6, 0.5, 0.5].enumerated() {
            results.append(Self.result(method: "ref", seed: index, snr: 2.0))
            results.append(Self.result(method: "arm", seed: index, snr: 2.0 + difference))
        }
        let matrix = Self.matrix(
            methods: ["ref", "arm"], seeds: Array(0..<5), reference: "ref"
        )
        let paired = try #require(
            MethodComparisonRunner.pairedDifferences(results, matrix: matrix).first
        )
        let low = try #require(paired.confidenceIntervalLow)
        let high = try #require(paired.confidenceIntervalHigh)
        #expect(abs(low - 0.41216) < 1e-4)
        #expect(abs(high - 0.58784) < 1e-4)
        #expect(paired.intervalExcludesZero)

        // Same mean, ten times the spread: the interval now straddles zero.
        var noisy: [ComparisonResult] = []
        for (index, difference) in [-1.0, 2.0, 0.5, -0.5, 1.5].enumerated() {
            noisy.append(Self.result(method: "ref", seed: index, snr: 2.0))
            noisy.append(Self.result(method: "arm", seed: index, snr: 2.0 + difference))
        }
        let wide = try #require(
            MethodComparisonRunner.pairedDifferences(noisy, matrix: matrix).first
        )
        #expect(abs(wide.meanDifference - 0.5) < 1e-12)
        #expect(wide.intervalExcludesZero == false)
    }

    @Test func noReferenceMethodMeansNoPairedTableRatherThanAGuess() {
        let results = [
            Self.result(method: "a", seed: 1, snr: 1.0), Self.result(method: "b", seed: 1, snr: 2.0)
        ]
        let matrix = Self.matrix(methods: ["a", "b"], seeds: [1], reference: nil)
        #expect(MethodComparisonRunner.pairedDifferences(results, matrix: matrix).isEmpty)
    }

    @Test func aMatrixNamingAMissingReferenceArmIsRejected() throws {
        var matrix = try ComparisonMatrix.load(from: Self.committedMatrixURL)
        matrix.referenceMethod = "a-method-that-is-not-here"
        #expect(throws: ComparisonMatrix.LoadError.self) { try matrix.validate() }
    }

    // MARK: - Gated: the comparison run

    @Test func gradientMethodComparisonProducesATable() async throws {
        guard Self.isEnabled else {
            print("""
                MethodComparisonTests: set EVA_COMPARISON=1 to run the comparison \
                matrix. Skipping.
                """)
            return
        }
        guard FileManager.default.fileExists(
            atPath: MethodComparisonRunner.simulatorBinary.path
        ) else {
            Issue.record("""
                EVA_COMPARISON=1 was set but there is no eva-simulate binary at \
                \(MethodComparisonRunner.simulatorBinary.path). Build it first — an \
                explicitly requested comparison should fail loudly, not skip quietly.
                """)
            return
        }

        let matrix = try ComparisonMatrix.load(from: Self.matrixURL)
        print("Comparison working directory: \(MethodComparisonRunner.workingDirectory.path)")
        let report = try await MethodComparisonRunner.run(matrix: matrix)
        let directory = try MethodComparisonRunner.write(report)

        print("\n" + MethodComparisonRunner.markdown(report))
        print("Wrote \(directory.path)\n")

        #expect(report.results.count == matrix.methods.count * matrix.scenarios.count * matrix.seeds.count)

        // Leakage check. A method scoring above its own analytic best case is
        // not a good result; it means the clean signal reached the correction.
        // The comparison harness is report-only in every other respect, but
        // this one has to fail, because a table containing an impossible number
        // is worse than no table.
        for result in report.results where result.exceedsCeiling {
            Issue.record("""
                \(result.method) on \(result.scenario) seed \(result.seed) scored \
                \(result.broadbandSNR), above its analytic ceiling of \
                \(result.ceiling ?? .nan). That is evidence of ground truth reaching \
                the correction, not of an unusually good method.
                """)
        }

        // Warnings do not fail the run — several are benign, such as the final
        // epoch running past the end of the recording — but they must never be
        // silent, because the ones that are not benign look identical in the
        // score column.
        for result in report.results where !result.warnings.isEmpty {
            print("  ⚠︎ \(result.method) on \(result.scenario) seed \(result.seed):")
            for warning in result.warnings { print("      \(warning)") }
        }

        // The baseline has to be worse than the methods, or the table is
        // measuring something other than correction.
        for scenario in matrix.scenarios {
            let rows = report.summaries.filter { $0.scenario == scenario.id }
            let baseline = try #require(rows.first { $0.method == "no-correction" })
            for row in rows where row.method != "no-correction" {
                #expect(
                    row.meanBroadbandSNR > baseline.meanBroadbandSNR,
                    "\(row.method) scored no better than doing nothing on \(scenario.id)"
                )
            }
        }
    }

    // MARK: - Gated: the two SNR implementations agree

    /// The harness scores through `eva-simulate`; `PipelineRegressionTests`
    /// recomputes broadband SNR in-process. Both definitions are
    /// `std(clean) / std(clean - corrected)`, and if they ever drift apart the
    /// paper's table and the regression watermark would quietly describe
    /// different quantities. This is the check that keeps two implementations
    /// tolerable.
    @Test func harnessSNRAgreesWithInProcessSNR() throws {
        guard Self.isEnabled else { return }
        guard FileManager.default.fileExists(
            atPath: MethodComparisonRunner.simulatorBinary.path
        ) else { return }

        let matrix = try ComparisonMatrix.load(from: Self.matrixURL)
        let scenario = try #require(matrix.scenarios.first)
        let seed = try #require(matrix.seeds.first)
        let corpus = try MethodComparisonRunner.corpus(for: scenario, seed: seed)

        // Score the uncorrected recording: no processing is involved, so any
        // disagreement is in the metric rather than in the pipeline.
        let viaCLI = try MethodComparisonRunner.score(
            truth: corpus.clean,
            corrected: corpus.noisy,
            label: "agreement-check",
            padSeconds: scenario.padSeconds
        )

        let reader = MFFReader()
        let clean = try reader.loadSignal(from: corpus.clean)
        let noisy = try reader.loadSignal(from: corpus.noisy)
        let inProcess = PipelineRegressionTests.broadbandSNR(
            clean: clean.data,
            corrected: noisy.data,
            padSeconds: Int(scenario.padSeconds * clean.samplingRate)
        )

        #expect(
            abs(viaCLI.broadbandSNR - inProcess) / max(inProcess, 1e-9) < 1e-3,
            "eva-simulate scored \(viaCLI.broadbandSNR); in-process scored \(inProcess)"
        )
    }
}
