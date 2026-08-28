//
//  ProcessingStoreTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Smoke coverage for the L4 processing stores extracted from WaveformView
//  (REFACTOR.md slices 3–6): default state + eva.xml parameter bridges.
//

import Testing
import Foundation
@testable import EVA

struct ProcessingStoreTests {

    @MainActor
    @Test func waveletDefaultsAndClear() {
        let vm = WaveletReductionViewModel(store: RecordingStore())
        #expect(vm.isEnabled)
        #expect(vm.reducedSignal == nil)
        vm.candidates = []
        vm.clearResults()
        #expect(!vm.isActive)
        #expect(vm.parameters["mode"] != nil)
    }

    @MainActor
    @Test func epochingParameters() {
        let vm = EpochingViewModel(store: RecordingStore())
        vm.preStimulus = 0.1
        vm.postStimulus = 0.5
        vm.baselineCorrected = true
        let p = vm.parameters
        #expect(p["preStimulusMs"] == "100")
        #expect(p["postStimulusMs"] == "500")
        // Deliberately absent: baseline correction moved out to its own
        // `baseline` step, for the same reason average reference did — see
        // `ReplaySettingsRestore`.
        #expect(p["baselineCorrected"] == nil)
    }

    @MainActor
    @Test func artifactDefaults() {
        let vm = ArtifactViewModel(store: RecordingStore())
        #expect(vm.cleaningIsEnabled)
        #expect(vm.events.isEmpty)
        #expect(!vm.isCleaningActive)
    }

    @MainActor
    @Test func icaParameters() {
        let vm = ICAViewModel(store: RecordingStore())
        vm.method = .picard
        vm.componentCount = 25
        let p = vm.parameters
        #expect(p["method"] == "picard")
        #expect(p["components"] == "25")
    }

    // Faithful-capture: gradient and wavelet steps must carry real params so
    // eva.xml records them (previously dropped / omitted).
    @MainActor
    @Test func gradientAndWaveletExposeCaptureParameters() {
        #expect(GradientViewModel(store: RecordingStore()).parameters["method"] != nil)
        #expect(WaveletReductionViewModel(store: RecordingStore()).parameters["mode"] != nil)
    }
}
