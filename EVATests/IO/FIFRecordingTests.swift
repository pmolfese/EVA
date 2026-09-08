//
//  FIFRecordingTests.swift
//  EVATests
//
//  Native FIF reading against MNE-Python's own answer. Fixtures and references
//  come from Tools/fif-import/make_fif_fixtures.py, which writes the exact
//  sample values MNE returns into `.f32` sidecars — so these compare every
//  sample, not a summary statistic.
//

import Foundation
import Testing
@testable import EVA

@Suite("FIF recordings")
struct FIFRecordingTests {
    struct Reference: Decodable {
        struct Channel: Decodable {
            var name: String
            var kind: Int
            var range: Double
            var cal: Double
            var unit: Int
            var unit_mul: Int
            /// `null` for a channel with no position (STIM, and MNE's NaN rows).
            var loc3: [Double?]
        }
        struct Annotation: Decodable { var onset: Double; var duration: Double; var description: String }
        struct Segment: Decodable { var code: Int?; var name: String; var sample: Int?; var nave: Int? }
        struct File: Decodable {
            var content: String
            var samples_file: String
            var n_channels: Int?
            var n_samples: Int
            var sfreq: Double
            var first_samp: Int?
            var highpass: Double?
            var lowpass: Double?
            var channels: [Channel]
            var annotations: [Annotation]?
            var stim_events: [[Int]]?
            var n_epochs: Int?
            var n_conditions: Int?
            var tmin: Double?
            var event_id: [String: Int]?
            var segments: [Segment]?
        }
        var files: [String: File]
    }

    static let reference: Reference = {
        try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: Fixtures.url("FIF/fif_reference.json")))
    }()

    static func url(_ name: String) -> URL { Fixtures.url("FIF/\(name)") }

    /// MNE's own samples for a fixture: channels-major float32, in volts.
    static func expectedSamples(_ file: Reference.File) throws -> [Float] {
        let data = try Data(contentsOf: url(file.samples_file))
        return (0..<(data.count / 4)).map { i in
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
        }
    }

    /// Volts, so the tolerance is against a ~100 µV signal stored as float32.
    static let tolerance = 1e-12

    private func expectChannels(_ info: FIFMeasurementInfo, _ reference: [Reference.Channel]) {
        #expect(info.channels.count == reference.count)
        for (channel, expected) in zip(info.channels, reference) {
            #expect(channel.name == expected.name)
            #expect(Int(channel.rawKind) == expected.kind, "\(expected.name) kind")
            #expect(abs(channel.range - expected.range) < 1e-12, "\(expected.name) range")
            #expect(abs(channel.cal - expected.cal) < 1e-18, "\(expected.name) cal")
            #expect(Int(channel.unit) == expected.unit, "\(expected.name) unit")
            #expect(Int(channel.unitMultiplier) == expected.unit_mul, "\(expected.name) unit_mul")
            let expectedPosition = expected.loc3.compactMap { $0 }
            if let position = channel.positionMeters, expectedPosition.count == 3 {
                #expect(abs(position.x - expectedPosition[0]) < 1e-6, "\(expected.name) x")
                #expect(abs(position.y - expectedPosition[1]) < 1e-6, "\(expected.name) y")
                #expect(abs(position.z - expectedPosition[2]) < 1e-6, "\(expected.name) z")
            } else if expectedPosition.count < 3 {
                // A NaN position must not be reported as a usable electrode.
                #expect(channel.positionMeters == nil, "\(expected.name) should have no position")
            }
        }
    }

    // MARK: - Continuous

    @Test("continuous FIF matches MNE sample for sample",
          arguments: ["sample_raw.fif", "sample_short_raw.fif", "sample_gz_raw.fif.gz"])
    func continuousData(name: String) throws {
        let expected = try #require(Self.reference.files[name])
        let recording = try FIFRecording.read(from: Self.url(name))

        #expect(recording.content == .continuous)
        #expect(recording.info.samplingRate == expected.sfreq)
        #expect(recording.info.firstSample == expected.first_samp)
        #expect(recording.samples.count == expected.n_channels)
        #expect(recording.sampleCount == expected.n_samples)
        expectChannels(recording.info, expected.channels)

        // Every sample, against MNE's own read of the same file. The int16
        // fixture is the one that proves range × cal is applied correctly: its
        // stored values are quantized integers and only the calibration turns
        // them back into volts.
        let reference = try Self.expectedSamples(expected)
        var worst = 0.0
        var worstAt = (0, 0)
        for c in 0..<recording.samples.count {
            for s in 0..<recording.sampleCount {
                let delta = abs(recording.samples[c][s] - Double(reference[c * expected.n_samples + s]))
                if delta > worst { worst = delta; worstAt = (c, s) }
            }
        }
        #expect(worst < Self.tolerance,
                "worst sample mismatch \(worst) V at channel \(worstAt.0) sample \(worstAt.1)")
    }

    @Test("channel kinds separate brain, peripheral and stimulus channels")
    func channelKinds() throws {
        let recording = try FIFRecording.read(from: Self.url("sample_raw.fif"))
        #expect(recording.info.brainChannelIndices.count == 12)
        #expect(recording.info.peripheralChannelIndices == [12])          // EOG061
        #expect(recording.info.stimulusChannelIndices == [13])            // STI 014
        #expect(recording.info.channels[12].kind == .eog)
        #expect(recording.info.channels[13].kind == .stim)
        #expect(recording.info.channels[0].kind?.isBrainSignal == true)
    }

    @Test("annotations come back with onset, duration and label")
    func annotations() throws {
        let expected = try #require(Self.reference.files["sample_raw.fif"]?.annotations)
        let recording = try FIFRecording.read(from: Self.url("sample_raw.fif"))
        #expect(recording.annotations.count == expected.count)
        for (annotation, reference) in zip(recording.annotations, expected) {
            #expect(abs(annotation.onsetSeconds - reference.onset) < 1e-6)
            #expect(abs(annotation.durationSeconds - reference.duration) < 1e-6)
            #expect(annotation.description == reference.description)
        }
    }

    @Test("digitization rides along with the measurement info")
    func digitization() throws {
        let recording = try FIFRecording.read(from: Self.url("sample_raw.fif"))
        let dig = try #require(recording.info.digitization)
        #expect(dig.frame == .head)
        #expect(dig.points.contains { $0.kind == .cardinal })
        #expect(dig.points.filter { $0.kind == .eeg }.count >= 12)
    }

    // MARK: - Epoched

    @Test("epoched FIF: segments, names, codes and samples")
    func epochedData() throws {
        let expected = try #require(Self.reference.files["sample-epo.fif"])
        let recording = try FIFRecording.read(from: Self.url("sample-epo.fif"))

        #expect(recording.content == .epoched)
        #expect(recording.segments.count == expected.n_epochs)
        #expect(recording.sampleCount == expected.n_samples)
        #expect(abs(recording.segmentStartSeconds - (expected.tmin ?? 0)) < 1e-9)
        expectChannels(recording.info, expected.channels)

        let expectedSegments = try #require(expected.segments)
        for (segment, reference) in zip(recording.segments, expectedSegments) {
            #expect(segment.name == reference.name)
            #expect(segment.code == reference.code)
            #expect(segment.sourceSample == reference.sample)
            #expect(segment.contributingCount == 1)
        }

        let reference = try Self.expectedSamples(expected)
        let nchan = expected.channels.count, nsamp = expected.n_samples
        var worst = 0.0
        for (e, segment) in recording.segments.enumerated() {
            for c in 0..<nchan {
                for s in 0..<nsamp {
                    let index = (e * nchan + c) * nsamp + s
                    worst = max(worst, abs(segment.data[c][s] - Double(reference[index])))
                }
            }
        }
        #expect(worst < Self.tolerance, "worst epoch sample mismatch \(worst) V")
    }

    @Test("an epoch dropped when the file was written is reported, not hidden")
    func dropLog() throws {
        // The generator puts a `bad_blink` annotation over the first event, so
        // MNE rejected that epoch: 6 events in, 5 epochs out.
        let recording = try FIFRecording.read(from: Self.url("sample-epo.fif"))
        #expect(recording.segments.count == 5)
        let mentioned = recording.warnings.contains(where: { $0.contains("dropped") })
        #expect(mentioned, "warnings were: \(recording.warnings)")
    }

    // MARK: - Averaged

    @Test("averaged FIF: one segment per condition, with nave")
    func averagedData() throws {
        let expected = try #require(Self.reference.files["sample-ave.fif"])
        let recording = try FIFRecording.read(from: Self.url("sample-ave.fif"))

        #expect(recording.content == .averaged)
        #expect(recording.segments.count == expected.n_conditions)
        #expect(recording.sampleCount == expected.n_samples)
        #expect(abs(recording.segmentStartSeconds - (expected.tmin ?? 0)) < 1e-6)
        // The average drops the stim channel, so this file describes fewer
        // channels than the epochs it came from — the reader must follow the
        // file, not the family.
        #expect(recording.info.channels.count == expected.channels.count)
        expectChannels(recording.info, expected.channels)

        let expectedSegments = try #require(expected.segments)
        for (segment, reference) in zip(recording.segments, expectedSegments) {
            #expect(segment.name == reference.name)
            #expect(segment.contributingCount == reference.nave)
        }

        let reference = try Self.expectedSamples(expected)
        let nchan = expected.channels.count, nsamp = expected.n_samples
        var worst = 0.0
        for (e, segment) in recording.segments.enumerated() {
            for c in 0..<nchan {
                for s in 0..<nsamp {
                    worst = max(worst, abs(segment.data[c][s] - Double(reference[(e * nchan + c) * nsamp + s])))
                }
            }
        }
        #expect(worst < Self.tolerance, "worst average sample mismatch \(worst) V")
    }
}
