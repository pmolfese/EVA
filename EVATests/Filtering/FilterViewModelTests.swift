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
        let vm = FilterViewModel(store: RecordingStore())
        vm.lowCutoff = 0.5
        vm.highCutoff = 40
        vm.averageReference = true
        vm.notch60HzEnabled = true

        let params = vm.parameters
        #expect(params["highPassHz"] == "0.5")
        #expect(params["lowPassHz"] == "40")
        // Deliberately absent: re-referencing moved out to its own `reference`
        // step so it can be branched and so its excluded-channel dependency is
        // recorded. See `Rereferencing` and `ReplaySettingsRestoreTests`.
        #expect(params["averageReference"] == nil)
        #expect(params["notchHz"] == "60")
        #expect(params["precision"] == "auto")
        // Enriched keys for exact replay.
        #expect(params["highPassSlope"] == "24")
        #expect(params["lowPassSlope"] == "24")
        #expect(params["lineNoiseMode"] == "IIR Notch")
    }

    @MainActor
    @Test func iirFamilyIsLabeledExplicitly() {
        // The family is always recorded — including the explicit "iir" label —
        // so eva.xml and the log_ file state the filter style unambiguously.
        let vm = FilterViewModel(store: RecordingStore())
        vm.filterFamily = .iir
        let params = vm.parameters
        #expect(params["filterFamily"] == "iir")
        #expect(params["firCrossoverHz"] == nil) // crossover only for auto
        #expect(params["firTransitionHz"] == nil) // transition only for fir/auto
    }

    @MainActor
    @Test func firFamilyRoundTrips() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.filterFamily = .fir
        vm.firTransitionHz = 2.5
        let params = vm.parameters
        #expect(params["filterFamily"] == "fir")
        #expect(params["firTransitionHz"] == "2.5")
        #expect(params["firCrossoverHz"] == nil) // crossover only matters for auto

        let restored = FilterViewModel(store: RecordingStore())
        restored.apply(parameters: params)
        #expect(restored.filterFamily == .fir)
        #expect(restored.firTransitionHz == 2.5)
    }

    @MainActor
    @Test func autoFamilyEmitsCrossoverAndRoundTrips() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.filterFamily = .auto
        vm.firCrossoverHz = 1.5
        vm.firCrossoverRule = .through
        let params = vm.parameters
        #expect(params["filterFamily"] == "auto")
        #expect(params["firCrossoverHz"] == "1.5")
        #expect(params["firCrossoverRule"] == "through")

        let restored = FilterViewModel(store: RecordingStore())
        restored.apply(parameters: params)
        #expect(restored.filterFamily == .auto)
        #expect(restored.firCrossoverHz == 1.5)
        #expect(restored.firCrossoverRule == .through)
    }

    @MainActor
    @Test func filterDesignAndApplicationSettingsRoundTrip() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.filterFamily = .auto
        vm.iirDesign = .elliptic
        vm.ellipticPassbandRippleDB = 0.25
        vm.ellipticStopbandAttenuationDB = 72
        vm.firWindow = .kaiser
        vm.firKaiserAttenuationDB = 80
        vm.firApplication = .forward

        let params = vm.parameters
        #expect(params["iirDesign"] == "elliptic")
        #expect(params["ellipticPassbandRippleDB"] == "0.25")
        #expect(params["ellipticStopbandAttenuationDB"] == "72")
        #expect(params["firWindow"] == "kaiser")
        #expect(params["firKaiserAttenuationDB"] == "80")
        #expect(params["firApplication"] == "forward")

        let restored = FilterViewModel(store: RecordingStore())
        restored.apply(parameters: params)
        #expect(restored.iirDesign == .elliptic)
        #expect(restored.ellipticPassbandRippleDB == 0.25)
        #expect(restored.ellipticStopbandAttenuationDB == 72)
        #expect(restored.firWindow == .kaiser)
        #expect(restored.firKaiserAttenuationDB == 80)
        #expect(restored.firApplication == .forward)
    }

    @MainActor
    @Test func missingDesignSettingsReplayHistoricalBehavior() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.iirDesign = .elliptic
        vm.firWindow = .kaiser
        vm.firApplication = .forward
        vm.apply(parameters: ["filterFamily": "fir", "highPassHz": "1", "lowPassHz": "30"])
        #expect(vm.iirDesign == .butterworth)
        #expect(vm.firWindow == .hamming)
        #expect(vm.firApplication == .zeroPhase)
        #expect(vm.firCrossoverRule == .below)
    }

    @MainActor
    @Test func approximationPresetsConfigureOnlyFilterMechanics() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.highPassCutoffText = "0.375"
        vm.lowPassCutoffText = "42.5"
        vm.lineNoiseMode = .notch
        vm.notchUsesFIR = true
        vm.lineNoiseFrequency = 50
        vm.lineNoiseHarmonics = 3
        vm.lineNoiseWindowSeconds = 7.5
        vm.lineNoiseStrength = 0.65
        vm.averageReference = true
        vm.filterPNS = false
        vm.precision = .double

        for preset in FilterApproximationPreset.allCases {
            vm.applyApproximation(preset)
            #expect(vm.highPassCutoffText == "0.375")
            #expect(vm.lowPassCutoffText == "42.5")
            #expect(vm.lineNoiseMode == .notch)
            #expect(vm.notchUsesFIR)
            #expect(vm.notchIsFIREffective)
            #expect(vm.lineNoiseFrequency == 50)
            #expect(vm.lineNoiseHarmonics == 3)
            #expect(vm.lineNoiseWindowSeconds == 7.5)
            #expect(vm.lineNoiseStrength == 0.65)
            #expect(vm.averageReference)
            #expect(vm.filterPNS == false)
            #expect(vm.precision == .double)
        }
    }

    @MainActor
    @Test func approximationPresetMappings() {
        let vm = FilterViewModel(store: RecordingStore())

        for preset in [FilterApproximationPreset.eeglab, .mnePython] {
            vm.applyApproximation(preset)
            #expect(vm.filterFamily == .fir)
            #expect(vm.firWindow == .hamming)
            #expect(vm.firApplication == .delayCompensated)
            #expect(vm.firTransitionHz == nil)
        }

        vm.applyApproximation(.erplab)
        #expect(vm.filterFamily == .iir)
        #expect(vm.iirDesign == .butterworth)
        #expect(vm.highPassSlope == .dB24)
        #expect(vm.lowPassSlope == .dB24)

        vm.applyApproximation(.egiNetStation)
        #expect(vm.filterFamily == .auto)
        #expect(vm.iirDesign == .elliptic)
        #expect(vm.firWindow == .kaiser)
        #expect(vm.firApplication == .forward)
        #expect(vm.firCrossoverHz == 1)
        #expect(vm.firCrossoverRule == .through)
        #expect(vm.firTransitionHz == nil)
    }

    // MARK: - Presets pop-up state

    /// Applying a preset must leave the pop-up naming that preset, or the
    /// control lies about what it just did.
    @MainActor
    @Test func activePresetNamesTheAppliedPreset() {
        let vm = FilterViewModel(store: RecordingStore())
        for preset in FilterApproximationPreset.allCases {
            vm.applyApproximation(preset)
            #expect(vm.matchesApproximation(preset))
            #expect(vm.activePreset == preset)
        }
    }

    /// EEGLAB and MNE-Python currently configure identical mechanics, so a
    /// plain "which preset matches?" search cannot tell them apart. The pop-up
    /// stays on whichever the user actually chose.
    @MainActor
    @Test func activePresetPrefersTheOneActuallyApplied() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.applyApproximation(.mnePython)
        #expect(vm.activePreset == .mnePython)
        #expect(vm.matchesApproximation(.eeglab))

        vm.applyApproximation(.eeglab)
        #expect(vm.activePreset == .eeglab)
    }

    /// Editing any field a preset governs drops the pop-up to Custom.
    @MainActor
    @Test func editingAGovernedFieldClearsTheActivePreset() {
        let vm = FilterViewModel(store: RecordingStore())

        vm.applyApproximation(.eeglab)
        vm.firWindow = .kaiser
        #expect(vm.activePreset == nil)

        vm.applyApproximation(.egiNetStation)
        vm.firCrossoverHz = 2
        #expect(vm.activePreset == nil)

        vm.applyApproximation(.erplab)
        vm.lowPassSlope = .dB48
        #expect(vm.activePreset == nil)
    }

    /// A field no preset governs must not disturb the pop-up — that is the
    /// whole promise of "presets configure mechanics only".
    @MainActor
    @Test func editingAnUngovernedFieldKeepsTheActivePreset() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.applyApproximation(.erplab)

        vm.highPassCutoffText = "0.5"
        vm.lineNoiseMode = .notch
        vm.averageReference = true
        vm.precision = .double

        #expect(vm.activePreset == .erplab)
    }

    /// A fresh view model reads Custom, even though EVA's defaults happen to be
    /// exactly ERPLAB's mechanics.
    ///
    /// Naming a preset nobody chose would imply EVA had applied one. Picking
    /// ERPLAB from here changes no setting, so nothing is lost by staying quiet
    /// until asked.
    @MainActor
    @Test func defaultsReadAsCustomEvenThoughTheyMatchERPLAB() {
        let vm = FilterViewModel(store: RecordingStore())
        #expect(vm.lastAppliedPreset == nil)
        #expect(vm.matchesApproximation(.erplab), "EVA's defaults are expected to be ERPLAB-shaped")
        #expect(vm.activePreset == nil)
    }

    /// Settings that arrive without going through the pop-up — a replayed
    /// `eva.xml`, a restored snapshot — also read as Custom. The mechanics are
    /// reproduced exactly from the individual fields either way; only the
    /// title is withheld, because no one picked it.
    @MainActor
    @Test func settingsAppliedDirectlyReadAsCustom() {
        let vm = FilterViewModel(store: RecordingStore())

        vm.filterFamily = .fir
        vm.firWindow = .hamming
        vm.firApplication = .delayCompensated
        vm.firTransitionHz = nil
        // The design rule is part of what makes these EEGLAB's mechanics, not
        // an incidental extra: without it EVA reads the requested cutoff as its
        // −6 dB point where EEGLAB reads it as the passband edge, so the two
        // build different kernels from the same numbers.
        vm.firDesignRule = .eeglabMNE

        #expect(vm.matchesApproximation(.eeglab))
        #expect(vm.activePreset == nil)
    }

    /// Reproducing every *other* EEGLAB field but leaving EVA's own design rule
    /// in place is not EEGLAB filtering, and must not be reported as a match.
    @MainActor
    @Test func matchingFieldsWithoutTheDesignRuleIsNotAMatch() {
        let vm = FilterViewModel(store: RecordingStore())

        vm.filterFamily = .fir
        vm.firWindow = .hamming
        vm.firApplication = .delayCompensated
        vm.firTransitionHz = nil
        vm.firDesignRule = .eva

        #expect(!vm.matchesApproximation(.eeglab))
        #expect(!vm.matchesApproximation(.mnePython))
    }

    /// A preset must carry the design rule, since that is where half the
    /// package-specific behaviour lives.
    @MainActor
    @Test func presetsSelectTheirDesignRule() {
        let vm = FilterViewModel(store: RecordingStore())

        vm.applyApproximation(.eeglab)
        #expect(vm.firDesignRule == .eeglabMNE)

        vm.applyApproximation(.mnePython)
        #expect(vm.firDesignRule == .eeglabMNE)

        // Switching to an IIR preset resets the rule, so returning to a FIR
        // family later does not silently inherit EEGLAB's cutoff convention.
        vm.applyApproximation(.erplab)
        #expect(vm.firDesignRule == .eva)

        vm.applyApproximation(.egiNetStation)
        #expect(vm.firDesignRule == .eva)
    }

    /// A step recorded before design rules existed replays under EVA's current
    /// rule. Deliberate while EVA is pre-1.0: those results change, and that is
    /// cheaper than carrying a compatibility rule indefinitely.
    @MainActor
    @Test func absentDesignRuleReplaysAsEVA() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.firDesignRule = .eeglabMNE // a non-default starting state

        vm.apply(parameters: ["highPassHz": "0.1", "lowPassHz": "30", "filterFamily": "fir"])

        #expect(vm.firDesignRule == .eva)
    }

    /// Every FIR run names its rule, so a saved file can be reproduced without
    /// knowing which EVA build wrote it. This is the property that makes the
    /// fallback above safe to have removed.
    @MainActor
    @Test func everyFIRRunRecordsItsDesignRule() {
        let vm = FilterViewModel(store: RecordingStore())
        vm.filterFamily = .fir
        #expect(vm.parameters["firDesignRule"] != nil)

        // Including at the default, so the file states the convention rather
        // than implying it by omission.
        vm.firDesignRule = .eva
        #expect(vm.parameters["firDesignRule"] == FIRDesignRule.eva.rawValue)
    }

    /// A recorded rule is honoured on replay rather than being re-derived.
    @MainActor
    @Test func recordedDesignRuleRoundTrips() {
        for rule in FIRDesignRule.allCases {
            let source = FilterViewModel(store: RecordingStore())
            source.filterFamily = .fir
            source.firDesignRule = rule
            let recorded = source.parameters
            #expect(recorded["firDesignRule"] == rule.rawValue)

            let replayed = FilterViewModel(store: RecordingStore())
            replayed.apply(parameters: recorded)
            #expect(replayed.firDesignRule == rule)
        }
    }

    /// Choosing a preset the settings already match is a no-op on every field —
    /// it only supplies the title.
    @MainActor
    @Test func choosingAnAlreadyMatchingPresetChangesNothing() {
        let vm = FilterViewModel(store: RecordingStore())
        let before = (vm.filterFamily, vm.iirDesign, vm.highPassSlope, vm.lowPassSlope)

        vm.applyApproximation(.erplab)

        #expect(vm.filterFamily == before.0)
        #expect(vm.iirDesign == before.1)
        #expect(vm.highPassSlope == before.2)
        #expect(vm.lowPassSlope == before.3)
        #expect(vm.activePreset == .erplab)
    }

    @MainActor
    @Test func missingFilterFamilyDefaultsToIIROnReplay() {
        // A pre-FIR eva.xml has no filterFamily key; it must deserialize to IIR
        // regardless of the user's new-work default preference.
        let vm = FilterViewModel(store: RecordingStore())
        vm.filterFamily = .fir // simulate a non-default starting state
        vm.apply(parameters: ["highPassHz": "0.1", "lowPassHz": "30"])
        #expect(vm.filterFamily == .iir)
    }

    @MainActor
    @Test func notchStyleIsLabeledAndRoundTrips() {
        // FIR notch remains FIR even when the passband family is IIR.
        let iir = FilterViewModel(store: RecordingStore())
        iir.lineNoiseMode = .notch
        iir.notchUsesFIR = true
        iir.filterFamily = .iir
        #expect(iir.notchIsFIREffective == true)
        #expect(iir.parameters["notchUsesFIR"] == "true")

        // FIR passband plus FIR notch also round-trips.
        let fir = FilterViewModel(store: RecordingStore())
        fir.lineNoiseMode = .notch
        fir.filterFamily = .fir
        fir.notchUsesFIR = true
        fir.lineNoiseFrequency = 50
        fir.lineNoiseHarmonics = 3
        #expect(fir.notchIsFIREffective == true)
        let params = fir.parameters
        #expect(params["notchUsesFIR"] == "true")
        #expect(params["filterFamily"] == "fir")

        let restored = FilterViewModel(store: RecordingStore())
        restored.apply(parameters: params)
        #expect(restored.lineNoiseMode == .notch)
        #expect(restored.notchUsesFIR == true)
        #expect(restored.filterFamily == .fir)
        #expect(restored.notchIsFIREffective == true)
    }

    @MainActor
    @Test func precisionDefaultsToAutoAndCanBeSerialized() {
        let vm = FilterViewModel(store: RecordingStore())
        #expect(vm.precision == .auto)
        #expect(vm.parameters["precision"] == "auto")

        vm.precision = .float
        #expect(vm.parameters["precision"] == "float")

        vm.precision = .double
        #expect(vm.parameters["precision"] == "double")
    }

    @MainActor
    @Test func blankCutoffFieldsOmitThatFilterEdge() {
        let vm = FilterViewModel(store: RecordingStore())

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
        let vm = FilterViewModel(store: RecordingStore())
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
