//
//  FilterReplayTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
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
        let a = FilterViewModel(store: RecordingStore())
        a.lowCutoff = 0.5      // high-pass edge
        a.highCutoff = 40      // low-pass edge
        a.averageReference = true
        a.notch60HzEnabled = true
        a.highPassSlope = .dB36
        a.lowPassSlope = .dB12
        a.precision = .double

        let params = a.parameters
        let b = FilterViewModel(store: RecordingStore())
        b.apply(parameters: params)

        #expect(b.parameters == params)
        #expect(b.activeLineNoiseMode == .notch)
        #expect(b.highPassSlope == .dB36)
        #expect(b.lowPassSlope == .dB12)
        #expect(b.precision == .double)
    }

    @MainActor
    @Test func applyParametersHandlesMissingKeys() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.notch60HzEnabled = true
        vm.averageReference = true
        vm.apply(parameters: [:])

        #expect(vm.activeLineNoiseMode == .off)
        // Unchanged by an empty `filter` step: the `reference` step owns this
        // now, and `ReplaySettingsRestore` is what turns it off when the script
        // does not name one. A `filter` step cannot speak for it either way.
        #expect(vm.averageReference == true)
        #expect(vm.parameters["highPassHz"] == nil)
        #expect(vm.parameters["lowPassHz"] == nil)
    }

    @MainActor
    @Test func applyParametersRestoresCleanLineMode() {
        let a = FilterViewModel(store: RecordingStore())
        a.lineNoiseMode = .adaptiveCleanLine
        a.lineNoiseFrequency = 50
        a.lineNoiseHarmonics = 3

        let b = FilterViewModel(store: RecordingStore())
        b.apply(parameters: a.parameters)

        #expect(b.activeLineNoiseMode == .adaptiveCleanLine)
        #expect(b.lineNoiseFrequency == 50)
        #expect(b.lineNoiseHarmonics == 3)
        #expect(b.parameters == a.parameters)
    }

    @MainActor
    @Test func notchModeRoundTrips() {
        let a = FilterViewModel(store: RecordingStore())
        a.lineNoiseMode = .off
        a.notch60HzEnabled = true

        let b = FilterViewModel(store: RecordingStore())
        b.apply(parameters: a.parameters)

        #expect(b.activeLineNoiseMode == .notch)
        #expect(b.parameters["lineNoiseMode"] == "IIR Notch")
    }
}
