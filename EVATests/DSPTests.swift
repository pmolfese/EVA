//
//  DSPTests.swift
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
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct DSPTests {

    // MARK: - Correlation

    @Test func pearsonPerfectCorrelation() {
        let a = [1.0, 2, 3, 4, 5]
        let b = a.map { 2 * $0 + 1 }  // affine transform => r = 1
        #expect(abs(DSP.pearson(a[...], b[...]) - 1) < 1e-9)
    }

    @Test func pearsonAntiCorrelation() {
        let a = [1.0, 2, 3, 4, 5]
        let b = a.map { -$0 }
        #expect(abs(DSP.pearson(a[...], b[...]) + 1) < 1e-9)
    }

    @Test func pearsonOrthogonal() {
        let a = [1.0, -1, 1, -1]
        let b = [1.0, 1, 1, 1]   // constant => zero variance handled as 0
        #expect(DSP.pearson(a[...], b[...]) == 0)
    }

    // MARK: - firls

    @Test func firlsIsSymmetric() {
        let h = DSP.firls(numtaps: 65,
                          bands: [(0, 0.2), (0.3, 1)],
                          desired: [(1, 1), (0, 0)])
        for i in 0..<h.count {
            #expect(abs(h[i] - h[h.count - 1 - i]) < 1e-9)
        }
    }

    @Test func firlsLowPassPassesDCStopsNyquist() {
        let h = DSP.firls(numtaps: 65,
                          bands: [(0, 0.2), (0.35, 1)],
                          desired: [(1, 1), (0, 0)])
        // DC gain = sum of taps ~ 1
        let dc = h.reduce(0, +)
        #expect(abs(dc - 1) < 0.05)
        // Response at Nyquist = sum h[n] * (-1)^n ~ 0
        var nyq = 0.0
        for (n, v) in h.enumerated() { nyq += v * (n % 2 == 0 ? 1 : -1) }
        #expect(abs(nyq) < 0.05)
    }

    @Test func firlsHighPassStopsDC() {
        let h = DSP.firls(numtaps: 65,
                          bands: [(0, 0.2), (0.35, 1)],
                          desired: [(0, 0), (1, 1)])
        let dc = h.reduce(0, +)
        #expect(abs(dc) < 0.05)
    }

    // MARK: - FIR filtering

    @Test func firFilterMatchesConvolution() {
        let b = [0.5, 0.25, 0.125]
        let x = [1.0, 0, 0, 0, 0]   // impulse
        let y = DSP.firFilter(b, x)
        // impulse response == b padded with zeros
        #expect(abs(y[0] - 0.5) < 1e-12)
        #expect(abs(y[1] - 0.25) < 1e-12)
        #expect(abs(y[2] - 0.125) < 1e-12)
        #expect(abs(y[3]) < 1e-12)
    }

    @Test func convolveSameIsZeroPhaseForSymmetricKernel() {
        // Symmetric kernel => no net delay; a symmetric input stays centered.
        let b = [0.25, 0.5, 0.25]
        let x = [0.0, 0, 1, 0, 0]
        let y = DSP.convolveSame(b, x)
        #expect(y.count == x.count)
        // peak stays at the center index 2
        let peak = y.firstIndex(of: y.max()!)!
        #expect(peak == 2)
    }

    @Test func filtfiltPreservesConstant() {
        let h = DSP.firls(numtaps: 33, bands: [(0, 0.2), (0.35, 1)], desired: [(1, 1), (0, 0)])
        let x = [Double](repeating: 3.0, count: 200)
        let y = DSP.filtfiltFIR(h, x)
        #expect(y.count == x.count)
        // A constant is scaled by the filter's DC gain squared (filtfilt = two
        // passes); firls does not constrain DC gain to be exactly 1, so allow a
        // small tolerance and require no edge ringing.
        for v in y { #expect(abs(v - 3.0) < 0.05) }
    }

    @Test func filtfiltRemovesHighFrequency() {
        // low-frequency sine + high-frequency sine; low-pass keeps the low one.
        let n = 512
        let lowF = 0.01, highF = 0.45  // cycles/sample
        var x = [Double](repeating: 0, count: n)
        for t in 0..<n {
            x[t] = sin(2 * .pi * lowF * Double(t)) + sin(2 * .pi * highF * Double(t))
        }
        let h = DSP.firls(numtaps: 65, bands: [(0, 0.1), (0.25, 1)], desired: [(1, 1), (0, 0)])
        let y = DSP.filtfiltFIR(h, x)
        // Compare to the pure low component on the interior (avoid edges).
        var err = 0.0
        for t in 64..<(n - 64) {
            err += abs(y[t] - sin(2 * .pi * lowF * Double(t)))
        }
        err /= Double(n - 128)
        #expect(err < 0.15)
    }

    // MARK: - Resampling

    @Test func interpUpsamplesLength() {
        let x = (0..<50).map { sin(0.2 * Double($0)) }
        let up = DSP.interp(x, factor: 4)
        #expect(up.count == x.count * 4)
        // original samples approximately preserved at multiples of L
        for i in 5..<45 {
            #expect(abs(up[i * 4] - x[i]) < 0.05)
        }
    }

    @Test func decimateReducesLength() {
        let x = (0..<200).map { sin(0.05 * Double($0)) }
        let down = DSP.decimate(x, factor: 4)
        #expect(abs(down.count - x.count / 4) <= 1)
    }

    @Test func interpThenDecimateRoundTrips() {
        let x = (0..<128).map { sin(0.1 * Double($0)) + 0.5 * cos(0.03 * Double($0)) }
        let up = DSP.interp(x, factor: 4)
        let down = DSP.decimate(up, factor: 4)
        let count = min(down.count, x.count)
        var err = 0.0
        for i in 16..<(count - 16) { err += abs(down[i] - x[i]) }
        err /= Double(count - 32)
        #expect(err < 0.05)
    }

    // MARK: - FFT & fractional shift

    @Test func fftInverseRoundTrips() {
        var re = [1.0, 2, 3, 4, 5, 6, 7, 8]
        var im = [Double](repeating: 0, count: 8)
        let orig = re
        DSP.fft(re: &re, im: &im, inverse: false)
        DSP.fft(re: &re, im: &im, inverse: true)
        for i in 0..<8 {
            #expect(abs(re[i] / 8 - orig[i]) < 1e-9)
        }
    }

    @Test func fractionalShiftByIntegerMatchesShift() {
        let n = 64
        let x = (0..<n).map { sin(2 * .pi * 3 * Double($0) / Double(n)) }
        let shifted = DSP.fractionalShift(x, by: 1)  // delay by 1 sample
        // Interior should match x shifted by one (circular).
        var err = 0.0
        for i in 10..<(n - 10) { err += abs(shifted[i] - x[i - 1]) }
        err /= Double(n - 20)
        #expect(err < 1e-6)
    }

    @Test func fractionalShiftZeroIsIdentity() {
        let x = (0..<32).map { Double($0) }
        let y = DSP.fractionalShift(x, by: 0)
        #expect(y == x)
    }

    // MARK: - LMS adaptive filter

    @Test func lmsCancelsCorrelatedNoise() {
        // data = signal + noise; reference correlated with the noise.
        let n = 4000
        var rng = SystemRandomNumberGenerator()
        var reference = [Double](repeating: 0, count: n)
        var data = [Double](repeating: 0, count: n)
        for t in 0..<n {
            let noise = sin(0.3 * Double(t))
            let signal = 0.2 * sin(0.01 * Double(t))
            reference[t] = noise + 0.001 * Double.random(in: -1...1, using: &rng)
            data[t] = signal + noise
        }
        let (out, _) = DSP.lmsAdaptiveFilter(reference: reference, data: data, order: 8, mu: 0.01)
        // Residual after convergence should be much smaller than raw noise power.
        var residual = 0.0, raw = 0.0
        for t in (n / 2)..<n {
            residual += out[t] * out[t]
            raw += (data[t]) * (data[t])
        }
        #expect(residual < raw * 0.5)
    }

    // MARK: - PCA & least squares

    @Test func pcaRecoversDominantDirection() {
        // Epochs = scaled copies of a single waveform + tiny noise => 1 dominant PC.
        let length = 64
        let base = (0..<length).map { sin(2 * .pi * Double($0) / Double(length)) }
        var epochs: [[Double]] = []
        for k in 1...20 {
            let scale = Double(k) / 10
            var e = base.map { $0 * scale }
            let mean = e.reduce(0, +) / Double(length)
            e = e.map { $0 - mean }
            epochs.append(e)
        }
        let (basis, oev) = DSP.pca(epochs: epochs)
        #expect(!basis.isEmpty)
        // First component explains nearly all variance.
        #expect(oev.first! > 95)
        // First basis vector is collinear with the (demeaned) base waveform.
        let demeanedBase: [Double] = {
            let m = base.reduce(0, +) / Double(length)
            return base.map { $0 - m }
        }()
        let r = abs(DSP.pearson(basis[0][...], demeanedBase[...]))
        #expect(r > 0.99)
    }

    @Test func leastSquaresFitReconstructsLinearCombo() {
        let n = 50
        let c0 = (0..<n).map { Double($0) }
        let c1 = (0..<n).map { sin(0.2 * Double($0)) }
        let target = (0..<n).map { 2 * c0[$0] - 3 * c1[$0] }
        let fit = DSP.leastSquaresFit(target: target, design: [c0, c1])
        var err = 0.0
        for i in 0..<n { err += abs(fit[i] - target[i]) }
        #expect(err / Double(n) < 1e-6)
    }
}
