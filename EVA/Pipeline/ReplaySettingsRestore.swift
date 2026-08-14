//
//  ReplaySettingsRestore.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Derives the settings a step list implies, for the settings that decide whether
//  a step *exists at all*.
//
//  ## You enter a room, you turn on a light; you leave the room, you turn it off
//
//  That is the whole model, and it is the operator's, not an implementation
//  detail. A history node is a room. The lights that are on in it are exactly the
//  decisions its path names — no more, and importantly no fewer *and no leftover*.
//  Walking back to an earlier node has to turn off every light switched on since,
//  or the room is not the room you were in.
//
//  ## Why the leftovers are not merely cosmetic
//
//  `PipelineSnapshot` restores stage outputs; `restoreStageSettings` replays each
//  step's parameters into its view model. Between them they cover every setting
//  whose value lives *inside* a step — a filter's cutoffs live in the `filter`
//  step, so landing on a node without one leaves stale numbers in a sheet nobody
//  is reading. Harmless.
//
//  A setting that decides whether its step appears is not harmless, because **an
//  absent step cannot say it is absent**. Blink detection is a plain `Bool`: turn
//  it on and `thresholdArtifactDetection` joins the script; navigate back to a
//  node before it and the `Bool` is still true, so the chain-signature observer
//  re-derives a script that still contains the step and `adopt` walks the pointer
//  straight past the node the user just clicked.
//
//  That was the reported bug exactly: raw → filter → detect blinks, click back to
//  *filter*, and the artifact step "stays"; click back to *raw* and a **second**
//  artifact node appears, because from the root the same step has a different
//  ancestry (`root → threshold` rather than `root → filter → threshold`) and
//  therefore a different content address.
//
//  So these have to be derived **totally over the operation set** rather than
//  from the steps that happen to be present: start with every light off, then let
//  the path switch back on what it names.
//
//  ## Both directions use this
//
//  Interactive navigation and headless replay have the same problem for the same
//  reason. A headless run whose script contains no `reference` step must not
//  average-reference — and `epoching.averageReference` *defaults to true*, so
//  "leave it alone" silently referenced every batch output. One derivation, two
//  callers, so the two cannot drift; that is the same argument
//  `ChannelDecisionSteps` makes about the outgoing script.
//
//  Every future setting that gates a step's existence belongs here, and nowhere
//  else.
//

import Foundation

nonisolated enum ReplaySettingsRestore {

    /// The settings whose values decide which steps exist. All-off is the state
    /// of the root: no lights on in an empty room.
    struct Settings: Equatable, Sendable {
        // `thresholdArtifactDetection`
        var detectsBlinks = false
        var detectsMovements = false
        /// Whether the path asks for threshold detection at all. Only ever set
        /// *true* by a path that names the step — a node without one leaves the
        /// operator's chosen method alone, because a method with no detection
        /// enabled produces no step either way and silently rewriting the
        /// operator's choice would be a surprise.
        var selectsThresholdMethod = false

        // `reference`, one per domain — see `Rereferencing` for why the two are
        // not the same operation.
        var continuousReference: ReferenceScheme?
        var epochReference: ReferenceScheme?
    }

    /// What `steps` implies. Absent by default: see the file header for why the
    /// absence has to be derived rather than merely left alone.
    static func settings(for steps: [EVAProcessingStep]) -> Settings {
        var result = Settings()
        for step in steps {
            switch step.operation {
            case .thresholdArtifactDetection:
                result.detectsBlinks = step.parameters["eyeBlink"] == "true"
                result.detectsMovements = step.parameters["eyeMovement"] == "true"
                result.selectsThresholdMethod = true

            case .reference:
                let scheme = Rereferencing.scheme(from: step.parameters)
                switch Rereferencing.domain(from: step.parameters) {
                case .continuous: result.continuousReference = scheme
                case .epoch: result.epochReference = scheme
                }

            default:
                continue
            }
        }
        return result
    }
}
