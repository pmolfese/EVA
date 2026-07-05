//
//  WaveletReductionViewModelTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Round-trip + headless-apply coverage for wavelet reduction (TODO.md
//  "Round out replayable steps"): `parameters`/`apply(parameters:)` must carry
//  the full `WaveletReductionConfiguration`, not just `mode`, and `apply(to:
//  excludedChannels:analysisBand:onApplied:)` must actually run the reduction
//  with no view involved — the same VM-owns-its-transform pattern as filter
//  and gradient.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct WaveletReductionViewModelTests {

    @Test func parametersRoundTripFullConfiguration() {
        let a = WaveletReductionViewModel(store: RecordingStore())
        a.mode = .erp
        a.config.kind = .swt
        a.config.family = .db4
        a.config.levelCount = 7
        a.config.thresholdRule = .soft
        a.config.thresholdModel = .robustUniversal
        a.config.thresholdScale = 1.25
        a.config.downsampleFactor = 2

        let p = a.parameters
        let b = WaveletReductionViewModel(store: RecordingStore())
        b.apply(parameters: p)

        #expect(b.mode == .erp)
        #expect(b.config.kind == .swt)
        #expect(b.config.family == .db4)
        #expect(b.config.levelCount == 7)
        #expect(b.config.thresholdRule == .soft)
        #expect(b.config.thresholdModel == .robustUniversal)
        #expect(b.config.thresholdScale == 1.25)
        #expect(b.config.downsampleFactor == 2)
        #expect(b.parameters == p)
    }

    @Test func applyParametersLeavesMissingKeysUntouched() {
        let vm = WaveletReductionViewModel(store: RecordingStore())
        vm.config.levelCount = 6
        vm.apply(parameters: [:])
        #expect(vm.config.levelCount == 6)
    }

    private func syntheticSignal(samplingRate: Double = 250, count: Int = 4000) -> MFFSignalData {
        let channels = (0..<2).map { c in
            SyntheticSignal.sine(frequency: 10 + Double(c), samplingRate: samplingRate, count: count)
        }
        return SyntheticSignal.make(channels, samplingRate: samplingRate)
    }

    @Test func applyRunsHeadlesslyAndProducesAReducedSignal() async throws {
        let signal = syntheticSignal()
        let vm = WaveletReductionViewModel(store: RecordingStore())
        vm.mode = .continuousEEG
        vm.config = vm.mode.defaultConfiguration(samplingRate: signal.samplingRate)

        await vm.apply(to: signal, excludedChannels: [], analysisBand: nil)

        #expect(!vm.isRunning)
        let reduced = try #require(vm.reducedSignal)
        #expect(reduced.data.count == signal.data.count)
        #expect(vm.result != nil)
        #expect(vm.isEnabled)
    }

    @Test func excludedChannelsAreLeftOutOfReduction() async {
        let signal = syntheticSignal()
        let vm = WaveletReductionViewModel(store: RecordingStore())
        vm.mode = .continuousEEG
        vm.config = vm.mode.defaultConfiguration(samplingRate: signal.samplingRate)

        await vm.apply(to: signal, excludedChannels: [0], analysisBand: nil)

        // Channel 0 was excluded from reduction, so it must pass through unchanged.
        #expect(vm.reducedSignal?.data[0] == signal.data[0])
    }
}
