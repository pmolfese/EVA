//
//  FIFImportTests.swift
//  EVATests
//
//  The import path — FIF file to the recording EVA actually shows. The format
//  reading itself is covered sample-for-sample against MNE in
//  FIFRecordingTests; this covers the policy on top of it: which channels are
//  the recording, what becomes an event, the volts-to-microvolts conversion, and
//  how epoched and averaged files land on a single timeline.
//

import Foundation
import Testing
@testable import EVA

@Suite("FIF import")
struct FIFImportTests {
    static func url(_ name: String) -> URL { Fixtures.url("FIF/\(name)") }

    @Test("a continuous FIF opens as a recording, in microvolts")
    func continuousImport() throws {
        let url = Self.url("sample_raw.fif")
        #expect(SignalImportReader.isSupportedRecordingURL(url))
        let imported = try SignalImportReader.load(from: url)
        let signal = imported.signal

        // EEG only: the EOG goes to the PNS pane and the stim channel is events.
        #expect(signal.numberOfChannels == 12)
        #expect(signal.channelNames?.first == "Fp1")
        #expect(signal.channelNames?.contains("STI 014") == false)
        #expect(signal.channelNames?.contains("EOG061") == false)
        #expect(signal.samplingRate == 200)
        #expect(abs(signal.duration - 20) < 1e-9)
        #expect(signal.isSegmented == false && signal.isAveraged == false)

        // The generator writes channel i as a sine of amplitude 20·(i+1)/12 µV
        // plus 3 µV of noise, so a volts-vs-microvolts slip is three orders of
        // magnitude away from these bounds in either direction.
        for (index, channel) in signal.data.enumerated() {
            let peak = channel.map(abs).max() ?? 0
            let expected = Float(20 * Double(index + 1) / 12)
            #expect(peak > expected * 0.8 && peak < expected + 20,
                    "channel \(index) peak \(peak) µV, expected about \(expected)")
        }

        let pns = try #require(imported.pnsSignal)
        #expect(pns.numberOfChannels == 1 && pns.channelNames == ["EOG061"])
        #expect((pns.data[0].map(abs).max() ?? 0) > 70)      // the 80 µV EOG swing

        // Electrode positions come from the file's own channel info.
        let geometry = try #require(imported.geometry)
        #expect(geometry.positions.count == 12)
        #expect(imported.layout != nil)
    }

    @Test("annotations and stimulus edges both become events")
    func events() throws {
        let imported = try SignalImportReader.load(from: Self.url("sample_raw.fif"))
        let events = imported.signal.events

        let annotations = events.filter { $0.eventDescription == "FIF annotation" }
        #expect(annotations.count == 2)
        let blink = try #require(annotations.first { $0.code == "bad_blink" })
        #expect(abs(blink.beginTimeSeconds - 2.0) < 1e-6)
        #expect(abs((blink.durationSeconds ?? 0) - 0.5) < 1e-6)

        // Six 25 ms pulses on STI 014: one event each, at the rising edge, with
        // the pulse value as the code — the same events mne.find_events reports.
        let stimulus = events.filter { $0.eventDescription?.hasPrefix("Stimulus channel") == true }
        #expect(stimulus.count == 6)
        #expect(stimulus.map(\.code) == ["1", "2", "1", "2", "1", "2"])
        let onsets = stimulus.map { ($0.beginTimeSeconds * 200).rounded() }
        #expect(onsets == [400, 1200, 2000, 2800, 3200, 3600])
        #expect(events == events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds })
    }

    @Test("epoched FIF lands as a segmented recording")
    func epochedImport() throws {
        let imported = try SignalImportReader.load(from: Self.url("sample-epo.fif"))
        let signal = imported.signal

        #expect(signal.isSegmented && !signal.isAveraged)
        #expect(signal.numberOfChannels == 12)
        #expect(signal.epochSegments.count == 5)

        // One concatenated timeline, segments abutting, 141 samples each.
        let length = 141
        for (i, segment) in signal.epochSegments.enumerated() {
            #expect(segment.startSample == i * length)
            #expect(segment.endSample == i * length + length - 1)
            // tmin = −0.2 s at 200 Hz, so the event sits 40 samples in.
            #expect(segment.stimulusOffsetSamples == 40)
            #expect(segment.contributingEpochCount == 1)
        }
        #expect(signal.data.allSatisfy { $0.count == length * 5 })
        #expect(Set(signal.epochSegments.map(\.category)) == ["target", "standard"])
        // Categories keep distinct colours so the butterfly plot can tell them apart.
        let colours = Dictionary(grouping: signal.epochSegments, by: \.category)
            .mapValues { Set($0.map(\.colorIndex)) }
        #expect(colours.values.allSatisfy { $0.count == 1 })
        #expect(Set(colours.values.flatMap { $0 }).count == 2)
    }

    @Test("averaged FIF lands as an averaged recording, one segment per condition")
    func averagedImport() throws {
        let imported = try SignalImportReader.load(from: Self.url("sample-ave.fif"))
        let signal = imported.signal

        #expect(signal.isSegmented && signal.isAveraged)
        #expect(signal.numberOfChannels == 12)
        #expect(signal.epochSegments.count == 2)
        #expect(signal.epochSegments.map(\.category) == ["target", "standard"])
        // nave: the blink annotation cost the target condition one trial.
        #expect(signal.epochSegments.map(\.contributingEpochCount) == [2, 3])
        #expect(signal.data.allSatisfy { $0.count == 141 * 2 })
        // An average of a ±20 µV signal is still in microvolts.
        #expect((signal.data.last?.map(abs).max() ?? 0) > 1)
    }

    @Test("a gzipped FIF opens exactly like the uncompressed one")
    func gzippedImport() throws {
        let url = Self.url("sample_gz_raw.fif.gz")
        #expect(SignalImportReader.isSupportedRecordingURL(url))
        let plain = try SignalImportReader.load(from: Self.url("sample_raw.fif"))
        let zipped = try SignalImportReader.load(from: url)
        #expect(zipped.signal.numberOfChannels == plain.signal.numberOfChannels)
        #expect(zipped.signal.channelNames == plain.signal.channelNames)
        #expect(zipped.signal.data == plain.signal.data)
        #expect(zipped.signal.events.count == plain.signal.events.count)
    }

    @Test("a bare .gz that is not a FIF is still refused")
    func gzipIsNotAWildcard() {
        #expect(!SignalImportReader.isSupportedRecordingURL(URL(fileURLWithPath: "/tmp/archive.tar.gz")))
        #expect(!SignalImportReader.isSupportedRecordingURL(URL(fileURLWithPath: "/tmp/notes.txt.gz")))
        #expect(SignalImportReader.isSupportedRecordingURL(URL(fileURLWithPath: "/tmp/x_raw.fif.gz")))
    }
}
