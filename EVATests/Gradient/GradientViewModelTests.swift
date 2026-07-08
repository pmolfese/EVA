//
//  GradientViewModelTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Coverage for the L4 gradient store (REFACTOR.md slice 2): parameter bridge
//  and the high-motion gating.
//

import Testing
import Foundation
@testable import EVA

struct GradientViewModelTests {

    @MainActor
    @Test func parametersReflectMethodAndWindow() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .fastr
        vm.trMarkerCode = "TREV"
        vm.windowBefore = 3
        vm.windowAfter = 2
        vm.fastrSlices = 32
        vm.fastrUseFacetWindow = true
        vm.fastrOBSRandomSampling = true
        vm.fastrANCSliceHighPass = true

        let p = vm.parameters
        #expect(p["method"] == "FASTR")
        #expect(p["trMarkerCode"] == "TREV")
        #expect(p["windowBefore"] == "3")
        #expect(p["slices"] == "32")
        #expect(p["facetWindow"] == "true")
        #expect(p["obsRandomSampling"] == "true")
        #expect(p["ancSliceHighPass"] == "true")

        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: [
            "method": "FASTR",
            "facetWindow": "true",
            "obsRandomSampling": "true",
            "ancSliceHighPass": "true"
        ])
        #expect(restored.fastrUseFacetWindow)
        #expect(restored.fastrOBSRandomSampling)
        #expect(restored.fastrANCSliceHighPass)
    }

    @MainActor
    @Test func parametersPersistFastrDonorSelection() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .fastr
        vm.fastrDonorSelection = .bergenRSquare

        let p = vm.parameters
        #expect(p["fastrDonorSelection"] == "bergenRSquare")
        #expect(p["bergenRSquareDonors"] == "true")

        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: ["method": "FASTR", "fastrDonorSelection": "bergenRSquare"])
        #expect(restored.fastrDonorSelection == .bergenRSquare)

        let legacy = GradientViewModel(store: RecordingStore())
        legacy.apply(parameters: ["method": "FASTR", "bergenRSquareDonors": "true"])
        #expect(legacy.fastrDonorSelection == .bergenRSquare)
    }

    @MainActor
    @Test func highMotionSetEmptyWhenDisabled() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.excludeHighMotion = false
        #expect(vm.highMotionVolumeSet().isEmpty)
    }
}
