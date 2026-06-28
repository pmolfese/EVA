//
//  ChannelHealthAnalyzerTests.swift
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

struct ChannelHealthAnalyzerTests {

    private let samplingRate = 250.0
    private let count = 2500

    /// Deterministic small-noise clean EEG-like channel.
    private func cleanChannel(seed: UInt64, frequency: Double) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1
            let noise = (Double(state >> 33) / Double(UInt32.max) - 0.5) * 4
            return Float(20 * sin(2 * .pi * frequency * Double(i) / samplingRate) + noise)
        }
    }

    @Test func flatAndClippingChannelsGradeWorseThanCleanChannels() {
        var channels: [[Float]] = []
        // Six clean channels establish the recording baseline.
        for c in 0..<6 {
            channels.append(cleanChannel(seed: UInt64(c + 1), frequency: 8 + Double(c)))
        }
        let flatIndex = channels.count
        channels.append([Float](repeating: 0, count: count))            // dead/flat
        let clipIndex = channels.count
        channels.append([Float](repeating: 6000, count: count))         // railed/clipping

        let signal = SyntheticSignal.make(channels, samplingRate: samplingRate)
        let analysis = ChannelHealthAnalyzer.analyze(signal: signal, layout: nil)

        let clean = try! #require(analysis.resultsByChannel[0])
        let flat = try! #require(analysis.resultsByChannel[flatIndex])
        let clip = try! #require(analysis.resultsByChannel[clipIndex])

        #expect(analysis.resultsByChannel.count == channels.count)
        #expect(flat.goodPercentage < clean.goodPercentage, "flat channel should score worse")
        #expect(clip.goodPercentage < clean.goodPercentage, "clipping channel should score worse")
        // The clean channel should not itself be graded poor.
        #expect(clean.grade != .poor)
    }

    @Test func emptySignalYieldsNoResults() {
        let empty = SyntheticSignal.make([], samplingRate: samplingRate)
        let analysis = ChannelHealthAnalyzer.analyze(signal: empty, layout: nil)
        #expect(analysis.resultsByChannel.isEmpty)
    }
}
