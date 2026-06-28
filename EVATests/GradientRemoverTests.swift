//
//  GradientRemoverTests.swift
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

import Testing
import Foundation
@testable import EVA

struct GradientRemoverTests {

    @Test func removesPeriodicGradientArtifact() throws {
        // Build a channel = small physiological signal + a large repeating
        // gradient template, one identical copy per TR.
        let spacing = 100
        let nTR = 20
        let sampleCount = spacing * nTR

        // A distinctive gradient shape, repeated every TR.
        func gradient(_ k: Int) -> Float { 50 * Float(sin(Double(k) * 0.3)) + 30 * Float(k % 7) }
        // A slow physiological signal we want to preserve.
        func physio(_ t: Int) -> Float { 5 * Float(sin(2 * .pi * 3 * Double(t) / 1000)) }

        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount {
            channel[t] = physio(t) + gradient(t % spacing)
        }

        let triggers = Array(stride(from: 0, to: sampleCount, by: spacing))
        let corrected = try GradientRemover.correct(
            channels: [channel],
            trSamples: triggers,
            window: .default
        )

        #expect(corrected.count == 1)
        #expect(corrected[0].count == sampleCount)

        // The residual after correction should be far smaller than the original
        // gradient energy in the interior (away from edge TRs the method skips).
        let lo = spacing * 5, hi = spacing * 15
        let originalEnergy = (lo..<hi).reduce(0.0) { $0 + Double(channel[$1] * channel[$1]) }
        let residualEnergy = (lo..<hi).reduce(0.0) { $0 + Double(corrected[0][$1] * corrected[0][$1]) }
        #expect(residualEnergy < originalEnergy * 0.2, "gradient not substantially removed")
    }

    @Test func excludedTRsAreNotUsedAsDonorsButAreStillCorrected() throws {
        let spacing = 100
        let nTR = 20
        let sampleCount = spacing * nTR
        func gradient(_ k: Int) -> Float { 50 * Float(sin(Double(k) * 0.3)) + 30 * Float(k % 7) }
        func physio(_ t: Int) -> Float { 5 * Float(sin(2 * .pi * 3 * Double(t) / 1000)) }
        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount { channel[t] = physio(t) + gradient(t % spacing) }
        let triggers = Array(stride(from: 0, to: sampleCount, by: spacing))

        // Corrupt TR 9 with a big spike so it would poison neighbors' templates.
        let badTR = 9
        for i in 0..<spacing { channel[badTR * spacing + i] += 500 }

        let baseline = try GradientRemover.correct(
            channels: [channel], trSamples: triggers, window: .default
        )
        let censored = try GradientRemover.correct(
            channels: [channel], trSamples: triggers, window: .default,
            excludedTRs: [badTR]
        )

        #expect(censored[0].count == sampleCount)
        // A neighbor of the bad TR (TR 7) is cleaner when the spike is excluded
        // from its template.
        func energy(_ x: [Float], tr: Int) -> Double {
            (0..<spacing).reduce(0.0) { $0 + Double(x[tr * spacing + $1] * x[tr * spacing + $1]) }
        }
        #expect(energy(censored[0], tr: 7) < energy(baseline[0], tr: 7))
        // The excluded TR is still corrected (not left untouched/huge).
        #expect(energy(censored[0], tr: badTR) < energy(channel, tr: badTR))
    }

    @Test func preservesNonArtifactSignal() throws {
        // A physiological oscillation NOT phase-locked to the TR grid should
        // survive correction: the neighbor-average template averages it out, so
        // the corrected signal must still track the physio (not be flattened).
        let spacing = 100
        let nTR = 30
        let sampleCount = spacing * nTR
        // Period 62.5 samples vs TR 100 => not TR-locked.
        func physio(_ t: Int) -> Float { 10 * Float(sin(2 * .pi * Double(t) / 62.5)) }
        func gradient(_ k: Int) -> Float { 80 * Float(sin(Double(k) * 0.4)) + 40 * Float(k % 9) }
        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount { channel[t] = physio(t) + gradient(t % spacing) }

        let triggers = Array(stride(from: 0, to: sampleCount, by: spacing))
        let corrected = try GradientRemover.correct(
            channels: [channel], trSamples: triggers, window: .default
        )

        // On the interior, the corrected signal should correlate strongly with the
        // pure physio it was carrying.
        let lo = spacing * 6, hi = spacing * 24
        let cleanInterior = (lo..<hi).map { physio($0) }
        let gotInterior = Array(corrected[0][lo..<hi])
        #expect(correlation(cleanInterior, gotInterior) > 0.85,
                "physiological signal was not preserved")
    }

    @Test func producesDeterministicOutput() throws {
        let spacing = 100, nTR = 24
        let sampleCount = spacing * nTR
        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount {
            channel[t] = 5 * Float(sin(Double(t) * 0.07)) + 60 * Float(sin(Double(t % spacing) * 0.3))
        }
        let triggers = Array(stride(from: 0, to: sampleCount, by: spacing))
        let a = try GradientRemover.correct(channels: [channel, channel], trSamples: triggers)
        let b = try GradientRemover.correct(channels: [channel, channel], trSamples: triggers)
        #expect(a == b)
    }

    @Test func emptyExclusionEqualsNoExclusion() throws {
        let spacing = 100, nTR = 24
        let sampleCount = spacing * nTR
        var channel = [Float](repeating: 0, count: sampleCount)
        for t in 0..<sampleCount {
            channel[t] = 5 * Float(sin(Double(t) * 0.07)) + 60 * Float(sin(Double(t % spacing) * 0.3))
        }
        let triggers = Array(stride(from: 0, to: sampleCount, by: spacing))
        let plain = try GradientRemover.correct(channels: [channel], trSamples: triggers)
        let empty = try GradientRemover.correct(channels: [channel], trSamples: triggers,
                                                excludedTRs: [])
        #expect(plain == empty)
    }

    @Test func throwsWithTooFewTriggers() {
        #expect(throws: GradientRemoverError.self) {
            _ = try GradientRemover.correct(channels: [[0, 1, 2, 3]], trSamples: [0])
        }
    }

    /// Pearson correlation between two equal-length Float vectors.
    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        let n = Double(a.count)
        let ma = a.reduce(0, +) / Float(a.count)
        let mb = b.reduce(0, +) / Float(b.count)
        var sa = 0.0, sb = 0.0, sab = 0.0
        for i in 0..<a.count {
            let da = Double(a[i] - ma), db = Double(b[i] - mb)
            sa += da * da; sb += db * db; sab += da * db
        }
        _ = n
        let denom = (sa * sb).squareRoot()
        return denom == 0 ? 0 : sab / denom
    }

    @Test func throwsOnUnevenSpacing() {
        let channel = [Float](repeating: 1, count: 400)
        #expect(throws: GradientRemoverError.self) {
            // Gaps 100,150,100 deviate beyond the default tolerance of 1 sample.
            _ = try GradientRemover.correct(channels: [channel], trSamples: [0, 100, 250, 350])
        }
    }
}
