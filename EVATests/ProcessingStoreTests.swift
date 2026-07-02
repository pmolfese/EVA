//
//  ProcessingStoreTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
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
        let vm = WaveletReductionViewModel()
        #expect(vm.isEnabled)
        #expect(vm.reducedSignal == nil)
        vm.candidates = []
        vm.clearResults()
        #expect(!vm.isActive)
        #expect(vm.parameters["mode"] != nil)
    }

    @MainActor
    @Test func epochingParameters() {
        let vm = EpochingViewModel()
        vm.preStimulus = 0.1
        vm.postStimulus = 0.5
        vm.baselineCorrected = true
        let p = vm.parameters
        #expect(p["preStimulusMs"] == "100")
        #expect(p["postStimulusMs"] == "500")
        #expect(p["baselineCorrected"] == "true")
    }

    @MainActor
    @Test func artifactDefaults() {
        let vm = ArtifactViewModel()
        #expect(vm.cleaningIsEnabled)
        #expect(vm.events.isEmpty)
        #expect(!vm.isCleaningActive)
    }

    @MainActor
    @Test func icaParameters() {
        let vm = ICAViewModel()
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
        #expect(GradientViewModel().parameters["method"] != nil)
        #expect(WaveletReductionViewModel().parameters["mode"] != nil)
    }
}
