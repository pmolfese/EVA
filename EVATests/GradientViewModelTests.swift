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
        let vm = GradientViewModel()
        vm.method = .fastr
        vm.trMarkerCode = "TREV"
        vm.windowBefore = 3
        vm.windowAfter = 2
        vm.fastrSlices = 32

        let p = vm.parameters
        #expect(p["method"] == "FASTR")
        #expect(p["trMarkerCode"] == "TREV")
        #expect(p["windowBefore"] == "3")
        #expect(p["slices"] == "32")
    }

    @MainActor
    @Test func highMotionSetEmptyWhenDisabled() {
        let vm = GradientViewModel()
        vm.excludeHighMotion = false
        #expect(vm.highMotionVolumeSet().isEmpty)
    }
}
