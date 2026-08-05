//
//  WaveletScalogramTests.swift
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

struct WaveletScalogramTests {

    private let samplingRate = 250.0

    @Test func peakPowerLandsNearInjectedFrequency() {
        let targetFrequency = 12.0
        let sampleCount = 2000
        let channel = SyntheticSignal.sine(frequency: targetFrequency, samplingRate: samplingRate, count: sampleCount, amplitude: 30)
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let result = WaveletScalogram.compute(
            signal: signal,
            channelIndex: 0,
            startSample: 500,
            endSample: 1500
        )

        let unwrapped = try! #require(result)
        #expect(!unwrapped.power.isEmpty)
        #expect(unwrapped.frequenciesHz.count == unwrapped.power.count)

        // Average power per frequency row across time; the row nearest the
        // injected frequency should carry substantially more power than rows
        // far away from it.
        let rowMeans = unwrapped.power.map { row in row.reduce(0, +) / Double(max(row.count, 1)) }
        let peakRow = rowMeans.indices.max { rowMeans[$0] < rowMeans[$1] } ?? 0
        let peakFrequency = unwrapped.frequenciesHz[peakRow]

        #expect(abs(peakFrequency - targetFrequency) / targetFrequency < 0.5, "peak frequency \(peakFrequency) far from injected \(targetFrequency)")
    }

    @Test func emptyWindowReturnsNil() {
        let signal = SyntheticSignal.make([[Float](repeating: 0, count: 100)], samplingRate: samplingRate)
        let result = WaveletScalogram.compute(signal: signal, channelIndex: 0, startSample: 50, endSample: 40)
        #expect(result == nil)
    }

    @Test func invalidChannelReturnsNil() {
        let signal = SyntheticSignal.make([[Float](repeating: 0, count: 100)], samplingRate: samplingRate)
        let result = WaveletScalogram.compute(signal: signal, channelIndex: 5, startSample: 10, endSample: 50)
        #expect(result == nil)
    }
}
