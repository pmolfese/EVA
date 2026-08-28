//
//  GradientANCTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Covers the "Adaptive Noise Cancellation" section of the FASTR-family
//  functional spec, including its requirement that stability and finite output
//  take priority over matching any historical implementation.
//

import Testing
import Foundation
@testable import EVA

struct GradientANCTests {

    private let samplingRate = 1000.0

    private func rootMeanSquare(_ values: [Float], over range: Range<Int>) -> Double {
        var total = 0.0
        for index in range { total += Double(values[index]) * Double(values[index]) }
        return (total / Double(range.count)).squareRoot()
    }

    private func difference(_ a: [Float], _ b: [Float], over range: Range<Int>) -> Double {
        var total = 0.0
        for index in range {
            let d = Double(a[index]) - Double(b[index])
            total += d * d
        }
        return (total / Double(range.count)).squareRoot()
    }

    /// An artifact-like reference: a strong periodic waveform.
    private func reference(count: Int) -> [Float] {
        (0..<count).map { sample in
            let phase = Double(sample % 100) / 100
            return Float(80 * sin(2 * .pi * phase) + 35 * sin(6 * .pi * phase + 0.5))
        }
    }

    private func brainSignal(count: Int) -> [Float] {
        (0..<count).map { Float(8 * sin(2 * .pi * 7 * Double($0) / 1000)) }
    }

    // MARK: - Cutoff policy

    @Test func fixedPolicyAlwaysResolvesToTwoHertz() {
        #expect(GradientANC.cutoffHz(
            policy: .fixed2Hz, epochPeriodSamples: 100, samplingRate: samplingRate
        ) == 2)
        #expect(GradientANC.cutoffHz(
            policy: .fixed2Hz, epochPeriodSamples: 4000, samplingRate: samplingRate
        ) == 2)
    }

    @Test func sliceDerivedPolicyFollowsTheEpochRate() {
        // 100-sample epochs at 1000 Hz arrive at 10 Hz; half of that is 5 Hz.
        #expect(GradientANC.cutoffHz(
            policy: .sliceTriggerDependent, epochPeriodSamples: 100, samplingRate: samplingRate
        ) == 5)
    }

    @Test func sliceDerivedPolicyFallsBackWhenEpochsAreSlow() {
        // Volume-level epochs two seconds apart give an epoch rate of 0.5 Hz,
        // well under the 2 Hz floor.
        #expect(GradientANC.cutoffHz(
            policy: .sliceTriggerDependent, epochPeriodSamples: 2000, samplingRate: samplingRate
        ) == 2)
        #expect(GradientANC.cutoffHz(
            policy: .sliceTriggerDependent, epochPeriodSamples: 0, samplingRate: samplingRate
        ) == 2)
    }

    // MARK: - Behavior

    @Test func residualArtifactCorrelatedWithTheReferenceIsRemoved() {
        let count = 6000
        let source = reference(count: count)
        let brain = brainSignal(count: count)
        // A quarter of the artifact survived the earlier stages.
        let cleaned = zip(brain, source).map { $0 + 0.25 * $1 }

        let result = GradientANC.apply(
            cleaned: cleaned, reference: source, cutoffHz: 2,
            samplingRate: samplingRate, filterLength: 32, stepSize: 0.05
        )
        #expect(result.applied)

        let settled = 2000..<count
        let before = difference(cleaned, brain, over: settled)
        let after = difference(result.output, brain, over: settled)
        #expect(after < before * 0.5, "residual \(after) vs \(before)")
    }

    @Test func aFlatReferenceIsSkipped() {
        let count = 3000
        let cleaned = brainSignal(count: count)
        let flat = [Float](repeating: 0, count: count)
        let result = GradientANC.apply(
            cleaned: cleaned, reference: flat, cutoffHz: 2,
            samplingRate: samplingRate, filterLength: 32, stepSize: 0.05
        )
        #expect(!result.applied)
        #expect(result.output == cleaned)
    }

    @Test func aConstantReferenceCarriesNoInformationAndIsSkipped() {
        let count = 3000
        let cleaned = brainSignal(count: count)
        let constant = [Float](repeating: 42, count: count)
        let result = GradientANC.apply(
            cleaned: cleaned, reference: constant, cutoffHz: 2,
            samplingRate: samplingRate, filterLength: 32, stepSize: 0.05
        )
        // The high-pass strips the offset, leaving nothing to adapt against.
        #expect(!result.applied)
        #expect(result.output == cleaned)
    }

    /// The step size is the knob that decides how much uncorrelated signal ANC
    /// eats. A 32-tap filter driven by a periodic reference cannot synthesize a
    /// 7 Hz sinusoid from a 10 Hz fundamental with fixed weights — but weights
    /// that chase every sample can, because their own trajectory carries the
    /// beat. Smaller steps keep the filter tracking slow artifact drift instead.
    @Test func smallerStepSizesEatLessUncorrelatedSignal() {
        let count = 6000
        let source = reference(count: count)
        let brain = brainSignal(count: count)
        let settled = 2000..<count
        let amplitude = rootMeanSquare(brain, over: settled)

        var previous = Double.infinity
        for step in [0.05, 0.01, 0.002] {
            let result = GradientANC.apply(
                cleaned: brain, reference: source, cutoffHz: 2,
                samplingRate: samplingRate, filterLength: 32, stepSize: step
            )
            #expect(result.applied)
            let distortion = difference(result.output, brain, over: settled)
            #expect(distortion < previous, "step \(step) distorted \(distortion), more than the larger step")
            previous = distortion
        }
        #expect(previous < amplitude * 0.15,
                "at the smallest step, distortion \(previous) vs signal \(amplitude)")
    }

    @Test func theDefaultStepSizeKeepsSignalDistortionModest() {
        let count = 6000
        let source = reference(count: count)
        let brain = brainSignal(count: count)
        let defaultStep = GradientCorrectionConfig().ancStepSize

        let result = GradientANC.apply(
            cleaned: brain, reference: source, cutoffHz: 2,
            samplingRate: samplingRate, filterLength: 32, stepSize: defaultStep
        )
        let settled = 2000..<count
        let distortion = difference(result.output, brain, over: settled)
        let amplitude = rootMeanSquare(brain, over: settled)
        #expect(distortion < amplitude * 0.35, "distortion \(distortion) vs signal \(amplitude)")
    }

    @Test func outOfRangeStepSizesAreRefused() {
        let count = 2000
        let cleaned = brainSignal(count: count)
        let source = reference(count: count)
        for step in [0.0, -0.1, 2.0, 5.0] {
            let result = GradientANC.apply(
                cleaned: cleaned, reference: source, cutoffHz: 2,
                samplingRate: samplingRate, filterLength: 32, stepSize: step
            )
            #expect(!result.applied, "step \(step) should be refused")
            #expect(result.output == cleaned)
        }
    }

    @Test func mismatchedLengthsAreRefused() {
        let cleaned = brainSignal(count: 2000)
        let source = reference(count: 1500)
        let result = GradientANC.apply(
            cleaned: cleaned, reference: source, cutoffHz: 2,
            samplingRate: samplingRate, filterLength: 32, stepSize: 0.05
        )
        #expect(!result.applied)
        #expect(result.output == cleaned)
    }

    @Test func outputStaysFiniteAndBoundedOnAnExtremeReference() {
        let count = 4000
        let source = reference(count: count).map { $0 * 1e5 }
        let cleaned = brainSignal(count: count)
        let result = GradientANC.apply(
            cleaned: cleaned, reference: source, cutoffHz: 2,
            samplingRate: samplingRate, filterLength: 64, stepSize: 0.1
        )
        let finite = result.output.allSatisfy { $0.isFinite }
        #expect(finite)
        // Normalized LMS must not amplify: the output should stay on the scale of
        // the signal it was given, not the reference.
        let peak = result.output.map { abs($0) }.max() ?? 0
        #expect(peak < 1000, "peak amplitude \(peak)")
    }

    @Test func adaptationIsDeterministic() {
        let count = 3000
        let source = reference(count: count)
        let cleaned = zip(brainSignal(count: count), source).map { $0 + 0.2 * $1 }
        let first = GradientANC.apply(
            cleaned: cleaned, reference: source, cutoffHz: 2,
            samplingRate: samplingRate, filterLength: 32, stepSize: 0.05
        )
        let second = GradientANC.apply(
            cleaned: cleaned, reference: source, cutoffHz: 2,
            samplingRate: samplingRate, filterLength: 32, stepSize: 0.05
        )
        #expect(first.output == second.output)
    }
}
