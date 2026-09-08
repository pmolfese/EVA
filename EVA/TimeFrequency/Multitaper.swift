//
//  Multitaper.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Short-time DPSS multitaper wavelets for the time-frequency engine — the
//  Fieldtrip-style alternative to Morlet, with better high-frequency control.
//  Reproduces MNE's `_make_dpss` / `tfr_array_multitaper` (Morlet-family output),
//  so the multitaper ERSP/ITPC cross-check against MNE to floating-point
//  tolerance (the tapers come from `DPSS`, which reproduces scipy exactly).
//

import Foundation

nonisolated enum Multitaper {

    /// The complex multitaper wavelets for one frequency (one per kept taper),
    /// plus each taper's concentration ratio (the combination weight `w_m² =
    /// conc_m`).
    ///
    /// Per MNE `_make_dpss`: `t = arange(0, n_cycles/f, 1/fs)`, oscillation
    /// `exp(2iπf(t − t_win/2))` (centered before tapering), multiplied by DPSS
    /// taper m, zero-meaned, then normalized by `√0.5·‖W‖`.
    static func wavelets(
        frequencyHz f: Double,
        nCycles: Double,
        samplingRate fs: Double,
        timeBandwidth: Double,
        zeroMean: Bool = true
    ) -> (kernels: [ComplexMorlet.Kernel], concentrations: [Double]) {
        guard f > 0, fs > 0, nCycles > 0, timeBandwidth >= 2 else { return ([], []) }
        let tWin = nCycles / f
        let dt = 1.0 / fs
        let n = max(Int((tWin / dt).rounded(.up)), 1)   // numpy arange length
        let kMax = max(Int((timeBandwidth - 1).rounded(.down)), 1)

        let (tapers, concentrations) = DPSS.tapers(length: n, halfNBW: timeBandwidth / 2.0, kMax: kMax)
        guard !tapers.isEmpty else { return ([], []) }

        var kernels: [ComplexMorlet.Kernel] = []
        kernels.reserveCapacity(tapers.count)
        let half = tWin / 2.0
        for taper in tapers {
            let count = min(n, taper.count)
            var re = [Double](repeating: 0, count: count)
            var im = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let t = Double(i) * dt
                let angle = 2.0 * Double.pi * f * (t - half)
                re[i] = cos(angle) * taper[i]
                im[i] = sin(angle) * taper[i]
            }
            if zeroMean {
                var meanRe = 0.0, meanIm = 0.0
                for i in 0..<count { meanRe += re[i]; meanIm += im[i] }
                meanRe /= Double(count); meanIm /= Double(count)
                for i in 0..<count { re[i] -= meanRe; im[i] -= meanIm }
            }
            var normSq = 0.0
            for i in 0..<count { normSq += re[i] * re[i] + im[i] * im[i] }
            let denom = (0.5).squareRoot() * normSq.squareRoot()
            if denom > 0 { for i in 0..<count { re[i] /= denom; im[i] /= denom } }
            kernels.append(ComplexMorlet.Kernel(re: re, im: im, frequencyHz: f, nCycles: nCycles))
        }
        return (kernels, concentrations)
    }
}
