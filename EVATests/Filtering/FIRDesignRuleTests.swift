//
//  FIRDesignRuleTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  `FIRDesignRule`: what a requested cutoff turns into, and whether the
//  `.eeglabMNE` rule genuinely reproduces MNE-Python.
//
//  The reference numbers below are not hand-derived. They were produced by
//  MNE-Python 1.12 and can be regenerated with:
//
//      import mne, numpy as np
//      k = mne.filter.create_filter(None, 250.0, l_freq=None, h_freq=30.0,
//                                   method='fir', fir_design='firwin',
//                                   fir_window='hamming', phase='zero')
//      print(k.size, k[k.size // 2], k.sum())
//
//  Tap counts are exact integers and are compared exactly; coefficients are
//  compared with a tolerance, since EVA builds its window in Swift and MNE goes
//  through scipy.
//

import Testing
import Foundation
@testable import EVA

struct FIRDesignRuleTests {

    private let sfreq = 250.0
    /// Long enough that the channel-length cap never binds, so these test the
    /// design rules rather than the capping behaviour.
    private let longRecording = 250 * 300

    // MARK: - Transition width

    /// MNE and EEGLAB both floor the transition at 2 Hz and cap it at the band
    /// available on that side. Every EVA rule adopts that.
    ///
    /// The floor is what keeps kernels finite at a low high-pass: an unfloored
    /// 25% of 0.1 Hz is a 0.025 Hz transition, which is 33,001 taps at 250 Hz —
    /// 132 s of data, longer than many recordings, and the reason the
    /// channel-length cap used to silently reshape the filter.
    @Test(arguments: FIRDesignRule.allCases)
    func clampedRulesMatchMNEsTransitionWidths(rule: FIRDesignRule) {
        // 0.1 Hz high-pass: 25% is 0.025, floored to 2, then capped to the
        // cutoff itself → 0.1. MNE logs "Lower transition bandwidth: 0.10 Hz".
        #expect(abs(EEGSignalFilter.automaticTransitionHz(
            cutoff: 0.1, samplingRate: sfreq, edge: .highPass, rule: rule
        ) - 0.1) < 1e-9)

        // 1 Hz high-pass: floored to 2, capped to 1 → 1.0.
        #expect(abs(EEGSignalFilter.automaticTransitionHz(
            cutoff: 1.0, samplingRate: sfreq, edge: .highPass, rule: rule
        ) - 1.0) < 1e-9)

        // 30 Hz low-pass: 25% is 7.5, above the floor and below the 95 Hz of
        // headroom → 7.5. MNE logs "Upper transition bandwidth: 7.50 Hz".
        #expect(abs(EEGSignalFilter.automaticTransitionHz(
            cutoff: 30, samplingRate: sfreq, edge: .lowPass, rule: rule
        ) - 7.5) < 1e-9)

        // 40 Hz low-pass → 10.0, matching MNE's log for that request.
        #expect(abs(EEGSignalFilter.automaticTransitionHz(
            cutoff: 40, samplingRate: sfreq, edge: .lowPass, rule: rule
        ) - 10.0) < 1e-9)
    }

    /// A low-pass close to Nyquist has little headroom left, and the transition
    /// must not run past it.
    @Test func transitionIsCappedByAvailableHeadroom() {
        let transition = EEGSignalFilter.automaticTransitionHz(
            cutoff: 120, samplingRate: sfreq, edge: .lowPass, rule: .eva
        )
        #expect(transition <= 5.0 + 1e-9, "125 Hz Nyquist leaves only 5 Hz above a 120 Hz cutoff")
    }

    // MARK: - MNE parity

    /// Tap counts must match MNE exactly — same 3.3/Δf rule, same odd length.
    @Test(arguments: [
        (0.1, FilterEdge.highPass, 8251),
        (1.0, FilterEdge.highPass, 825),
        (30.0, FilterEdge.lowPass, 111),
        (40.0, FilterEdge.lowPass, 83),
    ])
    func tapCountsMatchMNE(cutoff: Double, edge: FilterEdge, expected: Int) {
        let report = EEGSignalFilter.firDesignReport(
            cutoff: cutoff, samplingRate: sfreq, edge: edge,
            transitionHz: nil, maxChannelLength: longRecording, rule: .eeglabMNE
        )
        #expect(report.requestedTaps == expected)
        #expect(!report.wasCapped)
    }

    /// The centre tap and DC sum of the actual kernel, against MNE's.
    ///
    /// These catch the cutoff convention: designing at the requested frequency
    /// rather than half a transition beyond it shifts the centre tap well past
    /// this tolerance.
    @Test(arguments: [
        (30.0, FilterEdge.lowPass, 0.269706757947, 1.0),
        (40.0, FilterEdge.lowPass, 0.359604369587, 1.0),
        (1.0, FilterEdge.highPass, 0.995979829395, 0.0),
        (0.1, FilterEdge.highPass, 0.999598055215, 0.0),
    ])
    func kernelMatchesMNE(cutoff: Double, edge: FilterEdge, centerTap: Double, dcSum: Double) {
        let kernel = EEGSignalFilter.firKernel(
            cutoff: cutoff, samplingRate: sfreq, edge: edge,
            transitionHz: nil, maxChannelLength: longRecording,
            window: .hamming, rule: .eeglabMNE
        )
        #expect(!kernel.isEmpty)
        #expect(abs(kernel[kernel.count / 2] - centerTap) < 1e-6,
                "centre tap \(kernel[kernel.count / 2]) vs MNE \(centerTap)")
        #expect(abs(kernel.reduce(0, +) - dcSum) < 1e-6,
                "DC sum \(kernel.reduce(0, +)) vs MNE \(dcSum)")
    }

    /// The convention itself: EVA's own rule puts −6 dB at the requested
    /// frequency, EEGLAB/MNE put the passband edge there. The two therefore
    /// build measurably different kernels from the same request — which is the
    /// whole reason the rule is recorded rather than assumed.
    @Test func evaAndEEGLABRulesDifferForTheSameRequest() {
        let eva = EEGSignalFilter.firKernel(
            cutoff: 30, samplingRate: sfreq, edge: .lowPass,
            transitionHz: nil, maxChannelLength: longRecording, window: .hamming, rule: .eva
        )
        let eeglab = EEGSignalFilter.firKernel(
            cutoff: 30, samplingRate: sfreq, edge: .lowPass,
            transitionHz: nil, maxChannelLength: longRecording, window: .hamming, rule: .eeglabMNE
        )
        #expect(eva.count == eeglab.count, "same transition width, so same length")
        #expect(abs(eva[eva.count / 2] - eeglab[eeglab.count / 2]) > 1e-3,
                "the passband-edge shift must actually change the kernel")
    }

    // MARK: - Requested vs realized

    /// The defect this reporting exists for: the tap cap used to silently
    /// change the filter, so identical settings on a shorter recording produced
    /// a different result with nothing said about it.
    ///
    /// A hand-set transition is the remaining way to ask for more kernel than a
    /// recording can carry — the automatic width is floored now, but the manual
    /// field is deliberately not, since someone typing 0.02 Hz means it.
    @Test func shortRecordingReportsACappedKernelInsteadOfHidingIt() {
        // 0.02 Hz transition at 250 Hz → 41,251 taps, or 165 s of data.
        let short = EEGSignalFilter.firDesignReport(
            cutoff: 0.1, samplingRate: sfreq, edge: .highPass,
            transitionHz: 0.02, maxChannelLength: Int(sfreq * 60), rule: .eva
        )
        #expect(short.requestedTaps == 41251)
        #expect(short.wasCapped)
        #expect(short.realizedTaps < short.requestedTaps)
        // And it says how much data the full kernel needed.
        #expect(short.requiredRecordingSeconds > 300)
        #expect(short.summary.contains("asked"))
    }

    /// A capped kernel's realized transition is wider than requested, and the
    /// report says so rather than reporting the number that was asked for.
    @Test func realizedTransitionWidensWhenCapped() {
        let report = EEGSignalFilter.firDesignReport(
            cutoff: 0.1, samplingRate: sfreq, edge: .highPass,
            transitionHz: 0.02, maxChannelLength: Int(sfreq * 60), rule: .eva
        )
        #expect(report.realizedTransitionHz > report.requestedTransitionHz)
    }

    /// The floor is what makes the cap stop binding for ordinary settings: a
    /// 0.1 Hz high-pass needs 8,251 taps, which fits any recording over ~33 s.
    @Test(arguments: FIRDesignRule.allCases)
    func flooredRuleFitsOrdinaryRecordings(rule: FIRDesignRule) {
        let report = EEGSignalFilter.firDesignReport(
            cutoff: 0.1, samplingRate: sfreq, edge: .highPass,
            transitionHz: nil, maxChannelLength: Int(sfreq * 120), rule: rule
        )
        #expect(report.requestedTaps == 8251)
        #expect(!report.wasCapped, "8,251 taps fit inside 120 s at 250 Hz")
    }

    /// An explicit transition width overrides the rule's automatic one, whatever
    /// the rule — the manual field still means what it says.
    @Test(arguments: FIRDesignRule.allCases)
    func explicitTransitionOverridesTheRule(rule: FIRDesignRule) {
        let report = EEGSignalFilter.firDesignReport(
            cutoff: 0.1, samplingRate: sfreq, edge: .highPass,
            transitionHz: 5.0, maxChannelLength: longRecording, rule: rule
        )
        #expect(abs(report.requestedTransitionHz - 5.0) < 1e-9)
    }
}
