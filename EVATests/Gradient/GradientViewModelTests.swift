//
//  GradientViewModelTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
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
        vm.fastrUseMetal = true

        let p = vm.parameters
        #expect(p["method"] == "FASTR")
        #expect(p["trMarkerCode"] == "TREV")
        #expect(p["windowBefore"] == "3")
        #expect(p["slices"] == "32")
        #expect(p["facetWindow"] == "true")
        #expect(p["obsRandomSampling"] == "true")
        #expect(p["ancSliceHighPass"] == "true")
        #expect(p["metal"] == "true")

        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: [
            "method": "FASTR",
            "facetWindow": "true",
            "obsRandomSampling": "true",
            "ancSliceHighPass": "true",
            "metal": "true"
        ])
        #expect(restored.fastrUseFacetWindow)
        #expect(restored.fastrOBSRandomSampling)
        #expect(restored.fastrANCSliceHighPass)
        #expect(restored.fastrUseMetal)
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
    @Test func parametersPersistMetalForMASAndMAR() {
        for method in [MRIGradientMethod.mas, .mar] {
            let source = GradientViewModel(store: RecordingStore())
            source.method = method
            source.fastrUseMetal = true
            #expect(source.parameters["metal"] == "true")

            let restored = GradientViewModel(store: RecordingStore())
            restored.apply(parameters: source.parameters)
            #expect(restored.method == method)
            #expect(restored.fastrUseMetal)
        }

        let aas = GradientViewModel(store: RecordingStore())
        aas.method = .aas
        aas.fastrUseMetal = true
        #expect(aas.parameters["metal"] == nil)
    }

    @MainActor
    @Test func highMotionSetEmptyWhenDisabled() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.excludeHighMotion = false
        #expect(vm.highMotionVolumeSet().isEmpty)
    }

    @MainActor
    @Test func highMotionSetUsesLoadedMotionAndFDThreshold() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.motionParameters = MotionParameters(
            samples: [
                MotionSample(id: 0, roll: 0, pitch: 0, yaw: 0, dS: 0.0, dL: 0, dP: 0),
                MotionSample(id: 1, roll: 0, pitch: 0, yaw: 0, dS: 0.2, dL: 0, dP: 0),
                MotionSample(id: 2, roll: 0, pitch: 0, yaw: 0, dS: 1.2, dL: 0, dP: 0),
                MotionSample(id: 3, roll: 0, pitch: 0, yaw: 0, dS: 1.3, dL: 0, dP: 0)
            ],
            sourceName: "synthetic.1D"
        )
        vm.motionFDThreshold = 0.5
        vm.excludeHighMotion = true

        #expect(vm.highMotionVolumeSet() == [2])
    }
}
