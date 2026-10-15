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

    @Test func readsPositiveUpConventionFromPnsSet() throws {
        // example_3.mff's pnsSet.xml marks both ECG and EMG <positiveUp>false</positiveUp>.
        let url = Fixtures.url("example_3.mff")
        let pns = try #require(try MFFReader().loadPNSSignal(from: url))
        let flags = try #require(pns.positiveUpFlags)
        #expect(flags.count == pns.numberOfChannels)
        #expect(flags.allSatisfy { $0 == false })
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

    @Test func writerPreservesPNSValuesNamesAndPolarityConvention() throws {
        let source = Fixtures.url("example_3.mff")
        let reader = MFFReader()
        let eeg = try reader.loadSignal(from: source)
        let pns = try #require(try reader.loadPNSSignal(from: source))
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-pns-roundtrip-\(UUID().uuidString).mff")
        defer { try? FileManager.default.removeItem(at: output) }

        try MFFWriter.write(
            signal: eeg, pnsSignal: pns, segments: [], kind: .continuous,
            to: output, preserveSourceFileInfo: false
        )
        let recovered = try #require(try reader.loadPNSSignal(from: output))

        #expect(recovered.samplingRate == pns.samplingRate)
        #expect(recovered.channelNames == pns.channelNames)
        #expect(recovered.positiveUpFlags == pns.positiveUpFlags)
        #expect(recovered.data == pns.data)

        // External readers dispatch on the exact namespaced root and expect
        // the standard PNSSet container/units, not EVA's permissive flat form.
        let pnsSet = try String(
            contentsOf: output.appendingPathComponent("pnsSet.xml"),
            encoding: .utf8
        )
        #expect(pnsSet.contains("xmlns=\"http://www.egi.com/pnsSet_mff\""))
        #expect(pnsSet.contains("<sensors>"))
        #expect(pnsSet.components(separatedBy: "<unit>uV</unit>").count - 1 == pns.numberOfChannels)
        #expect(!pnsSet.contains("<type>PNS</type>"))
    }

    @Test func writerDoesNotInventPolarityFlagsForUnflaggedPNS() throws {
        // A PNS signal with no <positiveUp> metadata must read back as nil.
        // Defaulting to "true" on write turned nil into all-true on every
        // round trip and broke exact PNS preservation in the pipeline
        // regression corpus (PipelineRegressionTests.cleanAverageReferenceControlDoesNoHarm).
        let source = Fixtures.url("example_3.mff")
        let reader = MFFReader()
        let eeg = try reader.loadSignal(from: source)
        let flagged = try #require(try reader.loadPNSSignal(from: source))
        let pns = MFFSignalData(
            signalURL: flagged.signalURL,
            signalType: flagged.signalType,
            numberOfChannels: flagged.numberOfChannels,
            samplingRate: flagged.samplingRate,
            duration: flagged.duration,
            recordingStartTime: flagged.recordingStartTime,
            events: [],
            data: flagged.data,
            channelNames: flagged.channelNames,
            positiveUpFlags: nil
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-pns-noflags-\(UUID().uuidString).mff")
        defer { try? FileManager.default.removeItem(at: output) }

        try MFFWriter.write(
            signal: eeg, pnsSignal: pns, segments: [], kind: .continuous,
            to: output, preserveSourceFileInfo: false
        )
        let recovered = try #require(try reader.loadPNSSignal(from: output))

        #expect(recovered.positiveUpFlags == nil)
        #expect(recovered.channelNames == pns.channelNames)
        #expect(recovered.data == pns.data)
    }
}
