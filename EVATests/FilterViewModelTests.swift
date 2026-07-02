//
//  FilterViewModelTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Unit coverage for the L4 filter store extracted from WaveformView
//  (REFACTOR.md slice 1). Covers the portable-parameters bridge and the
//  transform's DC/high-pass behavior.
//

import Testing
import Foundation
@testable import EVA

struct FilterViewModelTests {

    @MainActor
    @Test func parametersReflectSettings() {
        let vm = FilterViewModel()
        vm.lowCutoff = 0.5
        vm.highCutoff = 40
        vm.averageReference = true
        vm.notch60HzEnabled = true

        let params = vm.parameters
        #expect(params["highPassHz"] == "0.5")
        #expect(params["lowPassHz"] == "40")
        #expect(params["averageReference"] == "true")
        #expect(params["notchHz"] == "60")
        #expect(params["precision"] == "auto")
    }

    @MainActor
    @Test func precisionDefaultsToAutoAndCanBeSerialized() {
        let vm = FilterViewModel()
        #expect(vm.precision == .auto)
        #expect(vm.parameters["precision"] == "auto")

        vm.precision = .float
        #expect(vm.parameters["precision"] == "float")

        vm.precision = .double
        #expect(vm.parameters["precision"] == "double")
    }

    @MainActor
    @Test func blankCutoffFieldsOmitThatFilterEdge() {
        let vm = FilterViewModel()

        vm.lowCutoff = 0.5
        vm.lowPassCutoffText = ""
        var params = vm.parameters
        #expect(params["highPassHz"] == "0.5")
        #expect(params["lowPassHz"] == nil)
        #expect(vm.frequencySummary == "Butterworth high-pass 0.5 Hz")

        vm.highPassCutoffText = ""
        vm.highCutoff = 30
        params = vm.parameters
        #expect(params["highPassHz"] == nil)
        #expect(params["lowPassHz"] == "30")
        #expect(vm.frequencySummary == "Butterworth low-pass 30 Hz")
    }

    @MainActor
    @Test func activeLineNoiseModeFollowsNotchToggle() {
        let vm = FilterViewModel()
        vm.lineNoiseMode = .off
        vm.notch60HzEnabled = true
        #expect(vm.activeLineNoiseMode == .notch)

        vm.lineNoiseMode = .adaptiveCleanLine
        #expect(vm.activeLineNoiseMode == .adaptiveCleanLine)
    }

    @Test func transformRemovesDCOffset() async throws {
        // A constant-offset + slow ramp channel should lose its DC after a
        // 1 Hz high-pass.
        let n = 2000
        let sr = 250.0
        let channel = (0..<n).map { _ in Float(5) }   // pure DC
        let filtered = try await FilterViewModel.filteredChannels(
            [channel],
            samplingRate: sr,
            lowCutoff: 1.0,
            highCutoff: 40.0,
            lineNoiseMode: .off,
            notchFrequency: 60,
            lineNoiseHarmonics: 2,
            lineNoiseWindowSeconds: 4,
            lineNoiseStrength: 1,
            averageReference: false,
            excludedChannels: [],
            progress: { _ in }
        )
        let mean = filtered[0].reduce(Float(0), +) / Float(n)
        #expect(abs(mean) < 0.5)   // DC largely removed
    }
}
