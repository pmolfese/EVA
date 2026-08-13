//
//  ParameterSerializationAuditTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  `REWIND.md` determinism audit, item 2: **anything a stage reads but does not
//  serialize is invisible to replay** — and it shows up not as an error but as
//  quietly different results. `categoryGroups` was the first instance found; the
//  2026-08-13 sweep found four more, one per view model with a `parameters`
//  block:
//
//  | View model | Missing keys | What it silently changed on replay |
//  |---|---|---|
//  | `FilterViewModel` | `lineNoiseWindowSeconds`, `lineNoiseStrength`, `filterPNS` | adaptive CleanLine fell back to the destination's defaults; PNS filtering silently switched |
//  | `GradientViewModel` | `skipStart`, `skipEnd`, `appliesToPNS`, `excludeHighMotion` | which TR volumes were corrected at all |
//  | `EpochingViewModel` | `segmentField` | segmenting on artifacts replayed as segmenting on event codes |
//  | `ICAViewModel` | 9 fit inputs incl. the activation pre-filter | a different decomposition |
//
//  These tests pin the *round trip*, not the key names: every property the apply
//  path reads is set to a non-default, serialized, and restored into a fresh
//  view model. A future property added to an apply path without a matching
//  `parameters` entry does not fail here automatically — nothing can catch that
//  mechanically — but a regression in one of the known ones does, and the table
//  above is the checklist for the next stage that gets added.
//

import Testing
import Foundation
import SwiftUI
@testable import EVA

struct ParameterSerializationAuditTests {

    // MARK: - Filter

    @MainActor
    @Test func filterCarriesAdaptiveCleanLineSettings() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.lineNoiseMode = .adaptiveCleanLine
        vm.lineNoiseFrequency = 50
        vm.lineNoiseHarmonics = 3
        vm.lineNoiseWindowSeconds = 7.5
        vm.lineNoiseStrength = 0.25

        let p = vm.parameters
        #expect(p["lineNoiseWindowSeconds"] == "7.5")
        #expect(p["lineNoiseStrength"] == "0.25")

        let restored = FilterViewModel(store: RecordingStore())
        restored.apply(parameters: p)
        #expect(restored.lineNoiseWindowSeconds == 7.5)
        #expect(restored.lineNoiseStrength == 0.25)
        #expect(restored.lineNoiseMode == .adaptiveCleanLine)
    }

    @MainActor
    @Test func filterCarriesWhetherPNSWasFiltered() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.filterPNS = false
        #expect(vm.parameters["filterPNS"] == "false")

        let restored = FilterViewModel(store: RecordingStore())
        #expect(restored.filterPNS, "default is on, so this is a real change")
        restored.apply(parameters: vm.parameters)
        #expect(!restored.filterPNS)
    }

    /// A pre-audit `eva.xml` has none of the new keys. It must replay exactly as
    /// it did before they existed — absent means "leave it alone", never
    /// "reset it".
    @MainActor
    @Test func filterLeavesAbsentKeysAlone() {
        let restored = FilterViewModel(store: RecordingStore())
        restored.lineNoiseWindowSeconds = 9
        restored.lineNoiseStrength = 0.5
        restored.filterPNS = false
        restored.apply(parameters: ["highPassHz": "0.1", "lowPassHz": "40"])

        #expect(restored.lineNoiseWindowSeconds == 9)
        #expect(restored.lineNoiseStrength == 0.5)
        #expect(!restored.filterPNS)
    }

    // MARK: - Gradient

    @MainActor
    @Test func gradientCarriesTRTrimAndPNSAndMotionSwitch() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .fastr
        vm.skipStart = 3
        vm.skipEnd = 2
        vm.appliesToPNS = false
        vm.excludeHighMotion = true
        vm.motionFDThreshold = 0.75

        let p = vm.parameters
        #expect(p["skipStart"] == "3")
        #expect(p["skipEnd"] == "2")
        #expect(p["appliesToPNS"] == "false")
        #expect(p["excludeHighMotion"] == "true")

        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: p)
        #expect(restored.skipStart == 3)
        #expect(restored.skipEnd == 2)
        #expect(!restored.appliesToPNS)
        #expect(restored.excludeHighMotion)
        #expect(restored.motionFDThreshold == 0.75)
    }

    /// Motion censoring off must survive the round trip. Before the explicit key,
    /// a present `motionFDThreshold` was *inferred* to mean censoring was on —
    /// which is right for old files and wrong for a method that needs motion for
    /// another reason.
    @MainActor
    @Test func gradientCarriesMotionCensoringTurnedOff() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .fastr
        vm.excludeHighMotion = false

        let restored = GradientViewModel(store: RecordingStore())
        restored.excludeHighMotion = true
        restored.apply(parameters: vm.parameters)
        #expect(!restored.excludeHighMotion)
    }

    /// The legacy inference still applies when the explicit key is absent.
    @MainActor
    @Test func gradientStillInfersCensoringFromALegacyThreshold() {
        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: ["method": "FASTR", "motionFDThreshold": "0.40"])
        #expect(restored.excludeHighMotion)
        #expect(restored.motionFDThreshold == 0.40)
    }

    // MARK: - Epoching

    @MainActor
    @Test func epochingCarriesTheSegmentField() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.segmentField = .artifact
        #expect(vm.parameters["segmentField"] == PSASegmentField.artifact.rawValue)

        let restored = EpochingViewModel(store: RecordingStore())
        restored.apply(parameters: vm.parameters)
        #expect(restored.segmentField == .artifact)

        // And the label variant, which is neither the default nor the one the
        // apply paths special-case.
        vm.segmentField = .label
        let other = EpochingViewModel(store: RecordingStore())
        other.apply(parameters: vm.parameters)
        #expect(other.segmentField == .label)
    }

    @MainActor
    @Test func epochingLeavesAnAbsentSegmentFieldAlone() {
        let restored = EpochingViewModel(store: RecordingStore())
        restored.apply(parameters: ["preStimulusMs": "-100", "postStimulusMs": "600"])
        #expect(restored.segmentField == .code, "the only value a pre-audit script could mean")
    }

    // MARK: - ICA

    @MainActor
    @Test func icaCarriesEveryFitInput() {
        let vm = ICAViewModel(store: RecordingStore())
        vm.method = .picardO
        vm.componentCount = 33
        vm.usesAverageReference = false
        vm.varianceThreshold = 0.95
        vm.downsampleRate = 250
        vm.maxIterations = 77
        vm.minimumIterations = 5
        vm.convergenceTolerance = 1e-9
        vm.usesFitFilter = true
        vm.fitLowCutoff = 2
        vm.fitHighCutoff = 35
        vm.fitNotch60HzEnabled = true

        let restored = ICAViewModel(store: RecordingStore())
        restored.apply(parameters: vm.parameters)

        #expect(restored.method == .picardO)
        #expect(restored.componentCount == 33)
        #expect(!restored.usesAverageReference)
        #expect(restored.varianceThreshold == 0.95)
        #expect(restored.downsampleRate == 250)
        #expect(restored.maxIterations == 77)
        #expect(restored.minimumIterations == 5)
        #expect(restored.convergenceTolerance == 1e-9)
        #expect(restored.usesFitFilter)
        #expect(restored.fitLowCutoff == 2)
        #expect(restored.fitHighCutoff == 35)
        #expect(restored.fitNotch60HzEnabled)
    }

    @MainActor
    @Test func icaCarriesTheFitFilterTurnedOff() {
        let vm = ICAViewModel(store: RecordingStore())
        vm.usesFitFilter = false
        #expect(vm.parameters["fitFilter"] == "false")
        #expect(vm.parameters["fitLowCutoff"] == nil, "no cutoffs when the filter is off")

        let restored = ICAViewModel(store: RecordingStore())
        restored.apply(parameters: vm.parameters)
        #expect(!restored.usesFitFilter)
    }

    @MainActor
    @Test func icaLeavesAbsentKeysAlone() {
        let restored = ICAViewModel(store: RecordingStore())
        restored.varianceThreshold = 0.5
        restored.maxIterations = 11
        restored.apply(parameters: ["method": "picard", "components": "20"])
        #expect(restored.varianceThreshold == 0.5)
        #expect(restored.maxIterations == 11)
    }

    // MARK: - Through eva.xml

    /// The keys have to survive the XML layer too, not just the dictionary — the
    /// `categoryGroups` bug was found on that boundary.
    @MainActor
    @Test func newKeysSurviveTheXMLRoundTrip() throws {
        let filter = FilterViewModel(store: RecordingStore())
        filter.lineNoiseMode = .adaptiveCleanLine
        filter.lineNoiseWindowSeconds = 6
        filter.filterPNS = false
        let epoching = EpochingViewModel(store: RecordingStore())
        epoching.segmentField = .artifact

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .filter, parameters: filter.parameters))
        script.append(EVAProcessingStep(operation: .segment, parameters: epoching.parameters))

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try EVAProcessingScriptXML.write(script, toPackage: package)
        let read = try #require(EVAProcessingScriptXML.read(fromPackage: package))

        let filterStep = try #require(read.steps.first { $0.operation == .filter })
        #expect(filterStep.parameters["lineNoiseWindowSeconds"] == "6")
        #expect(filterStep.parameters["filterPNS"] == "false")

        let segmentStep = try #require(read.steps.first { $0.operation == .segment })
        #expect(segmentStep.parameters["segmentField"] == PSASegmentField.artifact.rawValue)
    }
}
