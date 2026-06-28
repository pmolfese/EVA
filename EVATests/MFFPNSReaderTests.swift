//
//  MFFPNSReaderTests.swift
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

struct MFFPNSReaderTests {

    @Test func readsPNSChannelsFromExample3() throws {
        // example_3.mff has signal2.bin (PNSData) + pnsSet.xml (ECG, EMG, …).
        let url = Fixtures.url("example_3.mff")
        let pns = try #require(try MFFReader().loadPNSSignal(from: url),
                               "expected a PNS signal in example_3.mff")

        #expect(pns.numberOfChannels > 0)
        #expect(pns.data.count == pns.numberOfChannels)
        #expect(pns.signalType.range(of: "pns", options: .caseInsensitive) != nil)

        // Names come from pnsSet.xml, keyed by sensor number (0-based).
        let names = try #require(pns.channelNames)
        #expect(names.first == "ECG")
        #expect(names.contains("EMG"))
        #expect(names.count == pns.numberOfChannels)

        // Every channel has the same sample count.
        let sampleCounts = Set(pns.data.map(\.count))
        #expect(sampleCounts.count == 1)
        #expect((sampleCounts.first ?? 0) > 0)
    }

    @Test func pnsTimebaseMatchesEEG() throws {
        let url = Fixtures.url("example_3.mff")
        let reader = MFFReader()
        let eeg = try reader.loadSignal(from: url)
        let pns = try #require(try reader.loadPNSSignal(from: url))

        // PNS is recorded on the same acquisition clock as the EEG, so the
        // durations should line up closely (within a sample or two).
        #expect(abs(pns.duration - eeg.duration) < 0.05)
    }

    @Test func recordingsWithoutPNSReturnNil() throws {
        // example_1.mff has only signal1.bin (EEG), no PNS.
        let url = Fixtures.url("example_1.mff")
        #expect(try MFFReader().loadPNSSignal(from: url) == nil)
    }

    @Test func importedRecordingExposesPNS() throws {
        let imported = try SignalImportReader.load(from: Fixtures.url("example_3.mff"))
        #expect(imported.pnsSignal != nil)
        #expect(imported.pnsSignal?.channelNames?.first == "ECG")
    }
}
