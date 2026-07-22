//
//  FIRFilterTests.swift
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

struct FIRFilterTests {

    private let samplingRate = 250.0
    private let count = 2000

    private func rms(_ values: [Float]) -> Double {
        SignalStatistics.rootMeanSquare(values.map(Double.init))
    }

    private func interiorRMS(_ v: [Float]) -> Double {
        rms(Array(v[400..<(count - 400)]))
    }

    // MARK: - FIR band-pass behavior

    @Test func firBandPassKeepsInBandAndAttenuatesOutOfBand() async throws {
        let inBand = SyntheticSignal.sine(frequency: 10, samplingRate: samplingRate, count: count)
        let lowDrift = SyntheticSignal.sine(frequency: 0.2, samplingRate: samplingRate, count: count)
        let highTone = SyntheticSignal.sine(frequency: 90, samplingRate: samplingRate, count: count)

        let filtered = try await EEGSignalFilter.bandPass(
            channels: [inBand, lowDrift, highTone],
            samplingRate: samplingRate,
            lowCutoff: 1,
            highCutoff: 40,
            highPassFamily: .fir,
            lowPassFamily: .fir
        )

        let inBandRatio = interiorRMS(filtered[0]) / rms(Array(inBand[400..<(count - 400)]))
        #expect(inBandRatio > 0.7, "in-band attenuated too much: \(inBandRatio)")

        let driftRatio = interiorRMS(filtered[1]) / rms(Array(lowDrift[400..<(count - 400)]))
        #expect(driftRatio < 0.3, "low drift not attenuated: \(driftRatio)")

        let highRatio = interiorRMS(filtered[2]) / rms(Array(highTone[400..<(count - 400)]))
        #expect(highRatio < 0.3, "high tone not attenuated: \(highRatio)")
    }

    // MARK: - Linear phase / zero group delay

    @Test func firFilterIsZeroPhaseForInBandTone() async throws {
        // A linear-phase FIR applied zero-phase (filtfilt) must not shift an
        // in-band tone in time: the filtered output stays aligned with the input.
        let tone = SyntheticSignal.sine(frequency: 10, samplingRate: samplingRate, count: count)
        let filtered = try await EEGSignalFilter.bandPass(
            channels: [tone],
            samplingRate: samplingRate,
            lowCutoff: 1,
            highCutoff: 40,
            highPassFamily: .fir,
            lowPassFamily: .fir
        )[0]

        // Normalized cross-correlation at zero lag should be near 1 (aligned),
        // measured on the interior to avoid edge transients.
        let a = tone[400..<(count - 400)].map(Double.init)
        let b = filtered[400..<(count - 400)].map(Double.init)
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let corr = dot / (na.squareRoot() * nb.squareRoot())
        #expect(corr > 0.98, "FIR filter introduced phase shift: corr = \(corr)")
    }

    // MARK: - Kernel design

    @Test func firKernelIsSymmetricAndOddLength() {
        let kernel = EEGSignalFilter.firKernel(
            cutoff: 30, samplingRate: samplingRate, edge: .lowPass,
            transitionHz: nil, maxChannelLength: count
        )
        #expect(kernel.count % 2 == 1, "Type-I FIR kernel must be odd length")
        #expect(kernel.count > 1)
        // Symmetric coefficients → linear phase.
        for i in 0..<(kernel.count / 2) {
            #expect(abs(kernel[i] - kernel[kernel.count - 1 - i]) < 1e-9,
                    "kernel not symmetric at index \(i)")
        }
    }

    // MARK: - Auto (Net Station hybrid) routing

    @Test func autoRoutesLowHighPassToIIRAndLowPassToFIR() {
        // High-pass below the crossover → IIR.
        #expect(EEGSignalFilter.resolvedFamily(
            .auto, edge: .highPass, cutoff: 0.1,
            crossoverHz: EEGSignalFilter.defaultFIRCrossoverHz) == .iir)
        // High-pass at/above the crossover → FIR.
        #expect(EEGSignalFilter.resolvedFamily(
            .auto, edge: .highPass, cutoff: 2.0,
            crossoverHz: EEGSignalFilter.defaultFIRCrossoverHz) == .fir)
        // Low-pass is always FIR under auto.
        #expect(EEGSignalFilter.resolvedFamily(
            .auto, edge: .lowPass, cutoff: 30,
            crossoverHz: EEGSignalFilter.defaultFIRCrossoverHz) == .fir)
    }

    @Test func autoHybridFiltersReasonably() async throws {
        // 0.1 Hz HP (→ IIR) + 30 Hz LP (→ FIR): 10 Hz survives, 90 Hz removed.
        let inBand = SyntheticSignal.sine(frequency: 10, samplingRate: samplingRate, count: count)
        let highTone = SyntheticSignal.sine(frequency: 90, samplingRate: samplingRate, count: count)

        let filtered = try await EEGSignalFilter.bandPass(
            channels: [inBand, highTone],
            samplingRate: samplingRate,
            lowCutoff: 0.1,
            highCutoff: 30,
            highPassFamily: .auto,
            lowPassFamily: .auto
        )

        let inBandRatio = interiorRMS(filtered[0]) / rms(Array(inBand[400..<(count - 400)]))
        #expect(inBandRatio > 0.7, "in-band attenuated too much: \(inBandRatio)")
        let highRatio = interiorRMS(filtered[1]) / rms(Array(highTone[400..<(count - 400)]))
        #expect(highRatio < 0.3, "high tone not attenuated: \(highRatio)")
    }

    // MARK: - FIR notch

    @Test func firNotchRemovesLineFrequencyKeepsNeighbors() async throws {
        // 60 Hz should be nulled; 50 Hz and 10 Hz (in a wide passband) survive.
        let line = SyntheticSignal.sine(frequency: 60, samplingRate: samplingRate, count: count)
        let near = SyntheticSignal.sine(frequency: 50, samplingRate: samplingRate, count: count)
        let low = SyntheticSignal.sine(frequency: 10, samplingRate: samplingRate, count: count)

        let filtered = try await EEGSignalFilter.bandPass(
            channels: [line, near, low],
            samplingRate: samplingRate,
            lowCutoff: nil,
            highCutoff: nil,
            notch60HzEnabled: true,
            notchFrequency: 60,
            notchIsFIR: true,
            notchHarmonics: 1
        )

        let lineRatio = interiorRMS(filtered[0]) / rms(Array(line[400..<(count - 400)]))
        #expect(lineRatio < 0.2, "60 Hz not notched: \(lineRatio)")
        let nearRatio = interiorRMS(filtered[1]) / rms(Array(near[400..<(count - 400)]))
        #expect(nearRatio > 0.7, "50 Hz over-attenuated by notch: \(nearRatio)")
        let lowRatio = interiorRMS(filtered[2]) / rms(Array(low[400..<(count - 400)]))
        #expect(lowRatio > 0.9, "10 Hz disturbed by notch: \(lowRatio)")
    }

    @Test func firNotchNullsHarmonics() async throws {
        // With 2 harmonics, both 60 and 120 Hz are nulled in one kernel.
        let h1 = SyntheticSignal.sine(frequency: 60, samplingRate: samplingRate, count: count)
        let h2 = SyntheticSignal.sine(frequency: 120, samplingRate: samplingRate, count: count)

        let filtered = try await EEGSignalFilter.bandPass(
            channels: [h1, h2],
            samplingRate: samplingRate,
            lowCutoff: nil,
            highCutoff: nil,
            notch60HzEnabled: true,
            notchFrequency: 60,
            notchIsFIR: true,
            notchHarmonics: 2
        )

        let r1 = interiorRMS(filtered[0]) / rms(Array(h1[400..<(count - 400)]))
        let r2 = interiorRMS(filtered[1]) / rms(Array(h2[400..<(count - 400)]))
        #expect(r1 < 0.2, "60 Hz harmonic not notched: \(r1)")
        #expect(r2 < 0.2, "120 Hz harmonic not notched: \(r2)")
    }

    @Test func firNotchKernelIsSymmetric() {
        let kernel = EEGSignalFilter.firNotchKernel(
            frequency: 60, harmonics: 2, samplingRate: samplingRate,
            transitionHz: nil, maxChannelLength: count
        )
        #expect(kernel.count % 2 == 1)
        #expect(kernel.count > 1)
        for i in 0..<(kernel.count / 2) {
            #expect(abs(kernel[i] - kernel[kernel.count - 1 - i]) < 1e-9,
                    "notch kernel not symmetric at index \(i)")
        }
    }
}
