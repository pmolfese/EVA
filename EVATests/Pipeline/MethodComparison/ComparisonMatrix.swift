//
//  ComparisonMatrix.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The declarative half of the method-comparison harness (roadmap 3.2).
//
//  A comparison is described entirely by data: which scenarios to generate,
//  which seeds to generate them with, and which EVA method arms to run over
//  them. Adding a method to a published table is then a JSON edit and a re-run,
//  not a code change — which is what separates a harness that can carry a
//  results section from a script that produced one table once.
//
//  ## Why the reference arm is mandatory
//
//  A table of corrected scores is unreadable without the uncorrected one. Six
//  methods scoring 2.9 to 3.1 means something entirely different depending on
//  whether doing nothing scores 0.05 or 2.8. `validate()` therefore refuses a
//  matrix with no `.reference` arm rather than letting the harness emit a table
//  that a reader would have to take on trust.
//
//  ## Why the ceiling is here rather than in the runner
//
//  `PipelineRegressionTests` already argues the case: on simulated data, where
//  the clean signal sits in the next directory, a score *above* the method's
//  best attainable value is evidence of ground-truth leakage, and no floor can
//  ever catch it. That bound is a property of the method arm — how many donor
//  volumes its template averages — so it belongs beside the arm's parameters.
//

import Foundation
@testable import EVA

/// A versioned description of one method-comparison run.
struct ComparisonMatrix: Codable, Sendable {

    /// Bumped when the meaning of an existing field changes. Additive fields do
    /// not require a bump; the decoder tolerates them by construction.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Stable identifier, used to name the output directory and to label the
    /// results file so two matrices cannot be confused after the fact.
    var name: String
    var description: String
    /// Every scenario is generated once per seed, and every method arm sees the
    /// *same* recording for a given (scenario, seed). Differences between arms
    /// are therefore paired.
    var seeds: [Int]
    var scenarios: [Scenario]
    var methods: [Method]
    /// The arm every other arm is compared *against* in the paired-difference
    /// table, by id.
    ///
    /// Declared rather than inferred. Picking the best-scoring arm as the
    /// reference after the fact turns every comparison into a foregone
    /// conclusion, and picking the uncorrected arm answers a question nobody is
    /// asking by the time there are eight methods on the table. Optional: with
    /// no reference declared, per-seed results and summaries are still emitted
    /// and the paired table is simply absent.
    var referenceMethod: String?

    // MARK: - Scenario

    struct Scenario: Codable, Sendable {
        /// Directory name under the comparison corpus. Also the table row label.
        var id: String
        /// File name inside `Tools/EVASimulate/scenarios/`.
        var scenarioFile: String
        /// Extra `eva-simulate generate` flags, applied after `--config` and so
        /// overriding it. `--seed` and `--output` are supplied by the runner.
        var generateArguments: [String]
        /// Seconds trimmed from each end before scoring. The first and last
        /// template windows have fewer donors available, so their residual is
        /// not representative of the method and would make every score depend
        /// on recording length.
        var padSeconds: Double
        var description: String?
    }

    // MARK: - Method

    /// How an arm produces the recording that gets scored.
    enum Kind: String, Codable, Sendable {
        /// Run `steps` through `HeadlessBatchProcessor`.
        case eva
        /// Score the generated `sim_noisy.mff` unchanged. The floor of the
        /// table: what the numbers would be if EVA did nothing at all.
        case uncorrected
    }

    struct Method: Codable, Sendable {
        var id: String
        var label: String
        var kind: Kind
        /// Published reference for the method, carried into the results file so
        /// a table can be captioned without re-deriving its provenance.
        var citation: String?
        /// Empty for `.uncorrected`.
        var steps: [Step]
        var ceiling: Ceiling?
        var note: String?

        struct Step: Codable, Sendable {
            var operation: String
            var parameters: [String: String]
        }
    }

    /// The best score this arm could attain if it were working perfectly.
    ///
    /// Either stated outright (`value`) or derived from the arm's own
    /// parameters (`rule`), so the ceiling cannot drift out of step with the
    /// donor count it is a function of.
    struct Ceiling: Codable, Sendable {
        /// Currently the only rule: `sqrtDonorVolumesPlusOne`.
        ///
        /// Average-artifact subtraction with locked clocks cancels the artifact
        /// exactly; what remains is the EEG the template averaged in, whose
        /// standard deviation is `std(EEG)/sqrt(N)` over an N-volume template.
        /// The residual therefore carries the target volume's own EEG plus
        /// `1/N` of each donor's, giving `sqrt(N+1)`.
        var rule: String?
        var value: Double?
        /// Multiplicative slack for numerical error only. Keep it small: a 25%
        /// allowance on a ceiling of 3.0 admits every score up to 3.75, which
        /// is the entire range the leakage check exists to reject.
        var tolerance: Double?
        var note: String?

        static let sqrtDonorVolumesPlusOne = "sqrtDonorVolumesPlusOne"

        /// Resolves the ceiling against the arm it belongs to, or `nil` when
        /// this arm has no defensible analytic bound. Silence is the correct
        /// answer for a method whose best case is not known in closed form —
        /// inventing one would make the leakage check meaningless everywhere.
        func resolved(for method: Method) -> Double? {
            let slack = tolerance ?? 1.02
            if let value { return value * slack }
            guard rule == Self.sqrtDonorVolumesPlusOne else { return nil }
            guard let donors = method.steps
                .compactMap({ $0.parameters["donorVolumes"] })
                .compactMap(Int.init)
                .first
            else { return nil }
            return Double(donors + 1).squareRoot() * slack
        }
    }

    // MARK: - Loading and validation

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(URL, Error)
        case unsupportedSchema(found: Int, supported: Int)
        case noSeeds
        case noScenarios
        case noReferenceArm
        case duplicateMethodID(String)
        case duplicateScenarioID(String)
        case unknownOperation(method: String, operation: String)
        case armWithoutSteps(String)
        case unknownReferenceMethod(String)

        var description: String {
            switch self {
            case let .unreadable(url, error):
                return "could not read comparison matrix at \(url.path): \(error)"
            case let .unsupportedSchema(found, supported):
                return "comparison matrix schemaVersion \(found); this build understands \(supported)"
            case .noSeeds:
                return "comparison matrix has no seeds; a single-seed result cannot be reported as mean ± SD"
            case .noScenarios:
                return "comparison matrix has no scenarios"
            case .noReferenceArm:
                return """
                    comparison matrix has no arm of kind "uncorrected". A table of \
                    corrected scores without the uncorrected baseline cannot be read: \
                    the same corrected number is excellent or worthless depending on it.
                    """
            case let .duplicateMethodID(id):
                return "comparison matrix has two method arms with id \"\(id)\""
            case let .duplicateScenarioID(id):
                return "comparison matrix has two scenarios with id \"\(id)\""
            case let .unknownOperation(method, operation):
                return "method arm \"\(method)\" names operation \"\(operation)\", which EVA does not define"
            case let .armWithoutSteps(id):
                return "method arm \"\(id)\" is of kind \"eva\" but declares no steps"
            case let .unknownReferenceMethod(id):
                return "referenceMethod names \"\(id)\", which is not one of this matrix's arms"
            }
        }
    }

    static func load(from url: URL) throws -> ComparisonMatrix {
        let matrix: ComparisonMatrix
        do {
            matrix = try JSONDecoder().decode(ComparisonMatrix.self, from: Data(contentsOf: url))
        } catch {
            throw LoadError.unreadable(url, error)
        }
        try matrix.validate()
        return matrix
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LoadError.unsupportedSchema(
                found: schemaVersion, supported: Self.currentSchemaVersion
            )
        }
        guard !seeds.isEmpty else { throw LoadError.noSeeds }
        guard !scenarios.isEmpty else { throw LoadError.noScenarios }
        guard methods.contains(where: { $0.kind == .uncorrected }) else {
            throw LoadError.noReferenceArm
        }

        var seenMethods = Set<String>()
        for method in methods {
            guard seenMethods.insert(method.id).inserted else {
                throw LoadError.duplicateMethodID(method.id)
            }
            if method.kind == .eva, method.steps.isEmpty {
                throw LoadError.armWithoutSteps(method.id)
            }
            for step in method.steps where EVAProcessingStep.Operation(rawValue: step.operation) == nil {
                throw LoadError.unknownOperation(method: method.id, operation: step.operation)
            }
        }

        if let referenceMethod, !methods.contains(where: { $0.id == referenceMethod }) {
            throw LoadError.unknownReferenceMethod(referenceMethod)
        }

        var seenScenarios = Set<String>()
        for scenario in scenarios {
            guard seenScenarios.insert(scenario.id).inserted else {
                throw LoadError.duplicateScenarioID(scenario.id)
            }
        }
    }

    /// The processing script for one arm, or `nil` for a non-EVA arm.
    func script(for method: Method) -> EVAProcessingScript? {
        guard method.kind == .eva else { return nil }
        var script = EVAProcessingScript()
        for step in method.steps {
            guard let operation = EVAProcessingStep.Operation(rawValue: step.operation) else { continue }
            script.append(EVAProcessingStep(operation: operation, parameters: step.parameters))
        }
        return script
    }
}
