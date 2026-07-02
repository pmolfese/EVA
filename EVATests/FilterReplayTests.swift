//
//  FilterReplayTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Round-trip coverage for the reproducible eva.xml pipeline (slice 1): the
//  FilterViewModel `parameters` getter and its `apply(parameters:)` inverse must
//  be true inverses, so a captured filter step replays to the identical config.
//

import Testing
import Foundation
@testable import EVA

struct FilterReplayTests {

    /// The getter/setter are exact inverses: serialize a non-default config,
    /// deserialize into a fresh VM, and the re-serialized parameters must match.
    /// This is the "one code path" proof at the config level — the deserialized
    /// config drives the same transform the interactive button would.
    @MainActor
    @Test func filterApplyParametersRoundTrip() {
        let a = FilterViewModel()
        a.lowCutoff = 0.5      // high-pass edge
        a.highCutoff = 40      // low-pass edge
        a.averageReference = true
        a.notch60HzEnabled = true
        a.highPassSlope = .dB36
        a.lowPassSlope = .dB12
        a.precision = .double

        let params = a.parameters
        let b = FilterViewModel()
        b.apply(parameters: params)

        #expect(b.parameters == params)
        #expect(b.activeLineNoiseMode == .notch)
        #expect(b.highPassSlope == .dB36)
        #expect(b.lowPassSlope == .dB12)
        #expect(b.precision == .double)
    }

    @MainActor
    @Test func applyParametersHandlesMissingKeys() {
        let vm = FilterViewModel()
        vm.notch60HzEnabled = true
        vm.averageReference = true
        vm.apply(parameters: [:])

        #expect(vm.activeLineNoiseMode == .off)
        #expect(vm.averageReference == false)
        #expect(vm.parameters["highPassHz"] == nil)
        #expect(vm.parameters["lowPassHz"] == nil)
    }

    @MainActor
    @Test func applyParametersRestoresCleanLineMode() {
        let a = FilterViewModel()
        a.lineNoiseMode = .adaptiveCleanLine
        a.lineNoiseFrequency = 50
        a.lineNoiseHarmonics = 3

        let b = FilterViewModel()
        b.apply(parameters: a.parameters)

        #expect(b.activeLineNoiseMode == .adaptiveCleanLine)
        #expect(b.lineNoiseFrequency == 50)
        #expect(b.lineNoiseHarmonics == 3)
        #expect(b.parameters == a.parameters)
    }

    @MainActor
    @Test func notchModeRoundTrips() {
        let a = FilterViewModel()
        a.lineNoiseMode = .off
        a.notch60HzEnabled = true

        let b = FilterViewModel()
        b.apply(parameters: a.parameters)

        #expect(b.activeLineNoiseMode == .notch)
        #expect(b.parameters["lineNoiseMode"] == "IIR Notch")
    }
}
