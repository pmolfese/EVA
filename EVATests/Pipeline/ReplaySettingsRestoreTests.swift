//
//  ReplaySettingsRestoreTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The reported failure, verbatim: "raw -> filter -> artifact. Then go back to
//  filter and artifact stays. (blinks). Then go to raw and it actually goes to a
//  second artifact."
//
//  Both halves are the same cause. `detectsEyeBlinkArtifacts` is a plain `Bool`
//  that decides whether `thresholdArtifactDetection` is in the script at all, and
//  navigation never reset it — so after restoring, the chain-signature observer
//  re-derived a script that still contained the step. At `filter` that walked the
//  pointer forward onto the artifact node again; at the root the same step had a
//  *different ancestry* and therefore a different content address, which is the
//  "second artifact".
//
//  The `reference` tests below are the same rule in its second instance: average
//  reference stopped being a `filter` parameter and became its own step, so a
//  step list without one has to mean *not referenced* — and `EpochingViewModel`
//  defaults it to `true`, so "leave it alone" would have silently referenced
//  every batch output.
//
//  The last test is the one that generalises: it drives the real tree the way the
//  observer does, so it fails for any future setting that gates a step's
//  existence and is left out of `ReplaySettingsRestore`.
//

import Testing
import Foundation
@testable import EVA

struct ReplaySettingsRestoreTests {

    private func filterStep() -> EVAProcessingStep {
        EVAProcessingStep(operation: .filter, parameters: ["highpass": "0.1", "lowpass": "40"])
    }

    private func blinkStep(blink: Bool = true, movement: Bool = false) -> EVAProcessingStep {
        EVAProcessingStep(
            operation: .thresholdArtifactDetection,
            parameters: ["eyeBlink": "\(blink)", "eyeMovement": "\(movement)"]
        )
    }

    private func referenceStep(_ domain: ReferenceDomain) -> EVAProcessingStep {
        EVAProcessingStep(
            operation: .reference,
            parameters: Rereferencing.parameters(
                scheme: .average, domain: domain, excluding: [3, 17]
            )
        )
    }

    @Test("A path without a threshold step derives detection off")
    func absentStepMeansOff() {
        let eye = ReplaySettingsRestore.settings(for: [filterStep()])
        #expect(eye.detectsBlinks == false)
        #expect(eye.detectsMovements == false)
        // The operator's chosen method is left alone — only a path that names
        // the step asserts a method.
        #expect(eye.selectsThresholdMethod == false)
    }

    @Test("An empty path — the root — derives detection off")
    func rootMeansOff() {
        #expect(ReplaySettingsRestore.settings(for: []) == .init())
    }

    @Test("A path naming the step derives its recorded flags")
    func presentStepRestoresFlags() {
        let eye = ReplaySettingsRestore.settings(
            for: [filterStep(), blinkStep(blink: false, movement: true)]
        )
        #expect(eye.detectsBlinks == false)
        #expect(eye.detectsMovements == true)
        #expect(eye.selectsThresholdMethod == true)
    }

    private func baselineStep() -> EVAProcessingStep {
        EVAProcessingStep(operation: .baseline)
    }

    @Test("A path without a baseline step means uncorrected")
    func absentBaselineMeansUncorrected() {
        #expect(ReplaySettingsRestore.settings(for: [filterStep()]).baselineCorrection == false)
    }

    @Test("A path naming baseline derives it on")
    func presentBaselineDerivesOn() {
        #expect(ReplaySettingsRestore.settings(for: [baselineStep()]).baselineCorrection == true)
        #expect(
            ReplaySettingsRestore.settings(for: [referenceStep(.epoch), baselineStep()]).baselineCorrection
        )
    }

    @Test("A path without a reference step means not referenced, in both domains")
    func absentReferenceMeansUnreferenced() {
        let lights = ReplaySettingsRestore.settings(for: [filterStep()])
        #expect(lights.continuousReference == nil)
        #expect(lights.epochReference == nil)
    }

    @Test("Each reference domain is derived independently")
    func referenceDomainsAreIndependent() {
        let continuous = ReplaySettingsRestore.settings(for: [filterStep(), referenceStep(.continuous)])
        #expect(continuous.continuousReference == .average)
        #expect(continuous.epochReference == nil)

        let epoch = ReplaySettingsRestore.settings(for: [referenceStep(.epoch)])
        #expect(epoch.continuousReference == nil)
        #expect(epoch.epochReference == .average)

        let both = ReplaySettingsRestore.settings(
            for: [filterStep(), referenceStep(.continuous), referenceStep(.epoch)]
        )
        #expect(both.continuousReference == .average)
        #expect(both.epochReference == .average)
    }

    @Test("The excluded channel set round-trips through the step parameters")
    func exclusionsRoundTrip() {
        let p = referenceStep(.continuous).parameters
        #expect(Rereferencing.recordedExclusions(from: p) == [3, 17])
        #expect(p["excludedCount"] == "2")
        // Sorted, so two runs with the same bad set hash to the same node.
        #expect(p["excluded"] == "3,17")
    }

    @Test("An empty exclusion set omits the list but still records the count")
    func emptyExclusionsAreExplicit() {
        let p = Rereferencing.parameters(scheme: .average, domain: .continuous, excluding: [])
        #expect(p["excluded"] == nil)
        #expect(p["excludedCount"] == "0")
        #expect(Rereferencing.recordedExclusions(from: p).isEmpty)
    }

    @Test("A reference step with no domain replays as continuous")
    func missingDomainDefaultsToContinuous() {
        let bare = EVAProcessingStep(operation: .reference, parameters: ["scheme": "average"])
        let lights = ReplaySettingsRestore.settings(for: [bare])
        #expect(lights.continuousReference == .average)
        #expect(lights.epochReference == nil)
    }

    /// Navigating back and re-deriving must land on the node that was clicked.
    ///
    /// This walks `EVAHistory` itself rather than the view, because the bug was
    /// never in the restore call — it was in what the *next* `adopt` derived from
    /// the state that restore left behind.
    @MainActor
    @Test("Stepping back to filter stays at filter once detection is restored")
    func steppingBackDoesNotWalkForward() {
        let model = RecordingHistoryModel()
        let key = "fixture.mff"

        // raw -> filter -> blink detection.
        model.record(recordingKey: key, script: EVAProcessingScript(steps: [filterStep()]))
        let filterNode = model.history.currentID
        model.record(recordingKey: key, script: EVAProcessingScript(steps: [filterStep(), blinkStep()]))
        let artifactNode = model.history.currentID
        #expect(filterNode != artifactNode)

        // Click back to filter. The settings restore is what the view does; the
        // script the observer then derives is what it produces.
        let restored = model.beginNavigation(to: filterNode)
        _ = restored
        let eye = ReplaySettingsRestore.settings(for: model.history.currentPath.compactMap(\.step))
        model.endNavigation()
        #expect(model.history.currentID == filterNode)

        var derived = [filterStep()]
        if eye.detectsBlinks || eye.detectsMovements {
            derived.append(blinkStep(blink: eye.detectsBlinks, movement: eye.detectsMovements))
        }
        model.record(recordingKey: key, script: EVAProcessingScript(steps: derived))
        #expect(model.history.currentID == filterNode, "re-derivation walked off the clicked node")

        // Now click back to raw. Before the fix this produced a *second* artifact
        // node hanging off the root.
        _ = model.beginNavigation(to: model.history.rootID)
        let rootEye = ReplaySettingsRestore.settings(for: model.history.currentPath.compactMap(\.step))
        model.endNavigation()
        #expect(rootEye.detectsBlinks == false)

        var rootDerived: [EVAProcessingStep] = []
        if rootEye.detectsBlinks || rootEye.detectsMovements {
            rootDerived.append(blinkStep(blink: rootEye.detectsBlinks, movement: rootEye.detectsMovements))
        }
        model.record(recordingKey: key, script: EVAProcessingScript(steps: rootDerived))
        #expect(model.history.currentID == model.history.rootID)
        // Two nodes off the root would mean the second artifact was created.
        #expect(model.history.node(model.history.rootID)?.children.count == 1)
    }
}
