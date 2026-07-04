//
//  SignalSelectionTests.swift
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

struct SignalSelectionTests {

    @Test func validChannelsInDataFiltersMismatchedLengths() {
        let data: [[Float]] = [
            [0, 1, 2],   // ok
            [0, 1],      // wrong length
            [3, 4, 5]    // ok
        ]
        #expect(SignalSelection.validChannels(in: data, sampleCount: 3) == [0, 2])
    }

    @Test func validChannelsInSignalDedupesSortsAndBoundsChecks() {
        let signal = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/x.bin"),
            signalType: "EEG",
            numberOfChannels: 3,
            samplingRate: 1000,
            duration: 0.003,
            recordingStartTime: nil,
            events: [],
            data: [[0, 1, 2], [3, 4, 5], [6, 7, 8]]
        )
        // Duplicates, out-of-range, and negative indices are removed; result sorted.
        let result = SignalSelection.validChannels([2, 0, 0, 5, -1, 1], in: signal)
        #expect(result == [0, 1, 2])
    }

    @Test func mergeNearbyStartsKeepsHigherScoreWithinWindow() {
        let hits: [(start: Int, score: Float)] = [
            (start: 100, score: 0.5),
            (start: 105, score: 0.9), // within 10 of 100 -> merges, higher score wins
            (start: 200, score: 0.7)  // far away -> separate
        ]
        let merged = SignalSelection.mergeNearbyStarts(hits, mergeSamples: 10)
        #expect(merged.count == 2)
        // The higher-scoring hit replaces the kept entry wholesale (start and score).
        #expect(merged[0].start == 105)
        #expect(merged[0].score == 0.9)
        #expect(merged[1].start == 200)
    }

    @Test func mergeNearbyStartsKeepsDistinctWhenBeyondWindow() {
        let hits: [(start: Int, score: Float)] = [
            (start: 0, score: 0.5),
            (start: 20, score: 0.5),
            (start: 40, score: 0.5)
        ]
        let merged = SignalSelection.mergeNearbyStarts(hits, mergeSamples: 10)
        #expect(merged.map(\.start) == [0, 20, 40])
    }
}
