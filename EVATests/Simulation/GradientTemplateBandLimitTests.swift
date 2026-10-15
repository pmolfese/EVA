//
//  GradientTemplateBandLimitTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP MRI-1: the simulator's anti-aliased gradient template must actually
//  be band-limited. Filtering the bare window wrapped its ringing around the
//  FFT buffer, so it started at +0.28 and ended at −0.34 of peak-to-peak and put
//  1.5 % of its energy above the output Nyquist — a floor no correction engine
//  could get below.
//

import Testing
import Foundation
@testable import EVA

struct GradientTemplateBandLimitTests {

    private func template(rate: Double) -> (raw: HighRateTemplate, filtered: HighRateTemplate, config: SimulationConfig) {
        var config = SimulationConfig.default
        config.samplingRate = rate
        let raw = GradientArtifactModel.syntheticTemplate(config: config)
        return (raw, GradientArtifactModel.antiAliasedTemplate(raw, config: config), config)
    }

    /// Share of the template's energy above `hz`, from its own spectrum.
    private func energyFraction(above hz: Double, in template: HighRateTemplate) -> Double {
        var n = 1
        while n < template.samples.count { n <<= 1 }
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        for (i, v) in template.samples.enumerated() { re[i] = v }
        DSP.fft(re: &re, im: &im, inverse: false)
        let bin = template.rate / Double(n)
        var total = 0.0, above = 0.0
        for k in 0...(n / 2) {
            let p = re[k] * re[k] + im[k] * im[k]
            total += p
            if Double(k) * bin > hz { above += p }
        }
        return total > 0 ? above / total : 0
    }

    @Test(arguments: [500.0, 1000.0])
    func theAntiAliasedTemplateStartsAndEndsAtBaseline(rate: Double) {
        let t = template(rate: rate)
        #expect(t.filtered.edgeDiscontinuity < 0.01)
    }

    @Test(arguments: [500.0, 1000.0])
    func almostNoEnergyIsLeftAboveTheOutputNyquist(rate: Double) {
        let t = template(rate: rate)
        let fraction = energyFraction(above: t.config.samplingRate / 2, in: t.filtered)
        #expect(fraction < 1e-3, "energy above the output Nyquist: \(fraction)")
    }

    /// The front margin moves the waveform within its window; the lead-in has
    /// to move with it, or every slice lands 30 ms late.
    @Test func theLeadInFollowsTheMargin() {
        let t = template(rate: 500)
        let margin = (GradientArtifactModel.antiAliasMarginSeconds * t.raw.rate).rounded() / t.raw.rate
        #expect(abs(t.filtered.leadInSeconds - (t.raw.leadInSeconds + margin)) < 1e-12)
        // Timing: against the same waveform filtered with a much wider margin
        // (a clean zero-phase reference), the template must sit exactly where
        // the lead-in says — so each slice still lands where the scanner put
        // it, not 30 ms late.
        let marginSamples = Int((GradientArtifactModel.antiAliasMarginSeconds * t.raw.rate).rounded())
        let wide = 3 * marginSamples
        let zeros = [Double](repeating: 0, count: wide)
        let reference = SpectralNoise.lowPassed(
            zeros + t.raw.samples + zeros, samplingRate: t.raw.rate,
            cutoffHz: t.config.artifactAntiAliasFraction * t.config.samplingRate / 2)
        var bestLag = -1, best = -Double.infinity
        for lag in 0...(2 * wide) {
            var dot = 0.0
            for (i, v) in t.filtered.samples.enumerated() where lag + i < reference.count {
                dot += v * reference[lag + i]
            }
            if dot > best { best = dot; bestLag = lag }
        }
        #expect(bestLag == wide - marginSamples, "lag \(bestLag) vs \(wide - marginSamples)")
    }

    /// Normalization still means what `--gradient-amplitude` promises.
    @Test func theTemplateIsStillUnitPeakToPeak() {
        let t = template(rate: 500)
        let span = (t.filtered.samples.max() ?? 0) - (t.filtered.samples.min() ?? 0)
        #expect(abs(span - 1) < 1e-9)
    }
}
