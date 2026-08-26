//
//  PayloadConsistency.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Instrumentation for a state that should be impossible: a package whose
//  sidecar and whose `eva.xml` disagree about what happened to it.
//
//  ## The observation this exists for
//
//  The REWIND determinism audit found packages carrying an `eva_ica.json` whose
//  `eva.xml` had no `icaClean` step. Nobody could say how: either an ICA removal
//  ran and the script failed to record it, or a payload was written for a
//  removal that was staged and never applied, or the package was assembled from
//  two sources. Each has a different fix, and the three are indistinguishable
//  after the fact — which is exactly why ROADMAP RW-1 item 4 asks for this to be
//  *instrumented rather than guessed*.
//
//  So both directions are checked at the two moments the pair is in hand — when
//  a package is written, and when one is opened — and the finding is recorded in
//  the export's audit log and the window's status history. The next occurrence
//  arrives with a note saying which way round it was and where it came from,
//  instead of being noticed months later by someone reading a directory listing.
//
//  ## Not an error
//
//  Nothing here blocks an export or a load. A disagreement is a fact about a
//  file, and refusing to open the file would destroy the evidence rather than
//  explain it. These are notes, and they are deliberately phrased so that the
//  person who reads one knows which of the three stories to go looking for.
//

import Foundation

nonisolated enum PayloadConsistency {

    /// A disagreement between a script and the sidecars beside it.
    enum Finding: Equatable, Sendable {
        /// A payload exists for a step the script never records.
        case payloadWithoutStep(kind: Kind)
        /// The script records a step whose subject-specific payload is missing.
        /// Expected for a script *copied* from another recording; notable for a
        /// package's own `eva.xml`, since that means the package cannot
        /// reproduce its own bytes.
        case stepWithoutPayload(kind: Kind)

        var message: String {
            switch self {
            case .payloadWithoutStep(let kind):
                return "\(kind.payloadName) is present but eva.xml records no \(kind.stepName) step — either the step was applied and not recorded, or the payload was written for a removal that was never applied."
            case .stepWithoutPayload(let kind):
                return "eva.xml records a \(kind.stepName) step but \(kind.payloadName) is absent — this package cannot re-apply that step without a refit."
            }
        }
    }

    enum Kind: Equatable, Sendable {
        case ica
        case artifact

        var payloadName: String {
            switch self {
            case .ica: return "eva_ica.json"
            case .artifact: return "the artifact payload"
            }
        }

        var stepName: String {
            switch self {
            case .ica: return "icaClean"
            case .artifact: return "artifactClean"
            }
        }

        var operation: EVAProcessingStep.Operation {
            switch self {
            case .ica: return .icaClean
            case .artifact: return .artifactClean
            }
        }
    }

    /// Every disagreement between `script` and the payloads present beside it.
    ///
    /// Pure, so the rule is testable without writing a package — and so the
    /// export path and the open path cannot drift into two versions of it.
    static func findings(
        script: EVAProcessingScript,
        hasICAPayload: Bool,
        hasArtifactPayload: Bool
    ) -> [Finding] {
        var findings: [Finding] = []
        for (kind, hasPayload) in [(Kind.ica, hasICAPayload), (Kind.artifact, hasArtifactPayload)] {
            let hasStep = script.steps.contains { $0.operation == kind.operation }
            switch (hasStep, hasPayload) {
            case (false, true): findings.append(.payloadWithoutStep(kind: kind))
            case (true, false): findings.append(.stepWithoutPayload(kind: kind))
            default: break
            }
        }
        return findings
    }

    /// Audit-log lines for the findings, prefixed so they are greppable across a
    /// directory of packages.
    static func auditLogLines(
        script: EVAProcessingScript,
        hasICAPayload: Bool,
        hasArtifactPayload: Bool
    ) -> [String] {
        findings(
            script: script, hasICAPayload: hasICAPayload, hasArtifactPayload: hasArtifactPayload
        ).map { "payload consistency: \($0.message)" }
    }
}
