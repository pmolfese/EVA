//
//  EventAnchorCatalogTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Ties `EventAnchorCatalog` to reality.
//
//  The catalog is displayed in Preferences ▸ Events as a statement of fact
//  about how EVA reads its own detectors' events. A hand-maintained table like
//  that rots silently, and a UI confidently stating the wrong anchor is worse
//  than one that says nothing — a user would trust it and misread their data.
//
//  So these tests do not check the catalog against a second hardcoded list.
//  They *run each producer* on a synthetic signal and assert the anchor it
//  actually stamps is the one the catalog advertises. Change a detector's
//  anchor without updating its entry and this fails.
//

import Testing
import Foundation
@testable import EVA

struct EventAnchorCatalogTests {

    private func entry(_ name: String) throws -> EventAnchorCatalogEntry {
        try #require(
            EventAnchorCatalog.entries.first { $0.name == name },
            "no catalog entry named '\(name)'"
        )
    }

    /// Asserts every event a producer emitted carries the catalog's anchor, and
    /// that the producer emitted anything at all — a silently empty detector
    /// would otherwise pass this vacuously and leave the entry unverified.
    private func expectAnchor(_ events: [MFFEvent], matches entry: EventAnchorCatalogEntry) {
        #expect(!events.isEmpty, "\(entry.name) produced no events, so its catalog entry went unverified")
        for event in events {
            #expect(
                event.timeAnchor == entry.anchor,
                "\(entry.name) stamped .\(event.timeAnchor.rawValue) but the catalog advertises .\(entry.anchor.rawValue)"
            )
        }
    }

    // MARK: - Peak producers

    @Test func eyeArtifactThresholdMatchesCatalog() throws {
        let entry = try entry("Eye-artifact threshold")
        let sampleCount = 1000
        var channels = (0..<129).map { _ in [Float](repeating: 5, count: sampleCount) }
        for channel in [7, 24] {
            for sample in 100..<130 { channels[channel][sample] = 200 }
        }

        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink,
            channels: channels,
            samplingRate: 250,
            duration: Double(sampleCount) / 250
        )
        expectAnchor(events, matches: entry)
    }

    @Test func rWaveDetectorMatchesCatalog() throws {
        let entry = try entry("ECG (R wave)")
        let samplingRate = 250.0
        let sampleCount = 5000
        let bumpWidth = 16
        let bump = SyntheticSignal.bump(width: bumpWidth)

        var channel = [Float](repeating: 0, count: sampleCount)
        var state: UInt64 = 12345
        for index in 0..<sampleCount {
            state = state &* 6364136223846793005 &+ 1
            channel[index] = Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
        }
        for start in stride(from: bumpWidth, to: sampleCount - bumpWidth, by: 250) {
            for k in 0..<bumpWidth where start + k < sampleCount {
                channel[start + k] += bump[k]
            }
        }

        let source = ECGDetectionSource(
            id: "synthetic",
            label: "Synthetic ECG",
            channelLabels: ["ECG1"],
            channels: [channel],
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate
        )
        let events = RWaveDetector.detect(
            sources: [source],
            configuration: ECGDetectionConfiguration(
                algorithm: .simple,
                thresholdSD: 2.5,
                minimumRRSeconds: 0.4,
                polarity: .positive
            )
        )
        expectAnchor(events, matches: entry)
    }

    @Test func bcgDetectorMatchesCatalog() throws {
        let entry = try entry("BCG")
        let events = BCGDetector.makeEvents(times: [1.0, 2.0, 3.0], windowSeconds: 0.6)
        expectAnchor(events, matches: entry)
    }

    // MARK: - Template-scan producers

    private let templateRate = 250.0
    private let templateCount = 2500
    private let templateWidth = 50

    private func templateConfig(exemplar: ClosedRange<Int>) -> ArtifactTemplateConfiguration {
        ArtifactTemplateConfiguration(
            name: "CatalogTest",
            eventCode: "CTLG",
            selectedChannelIndices: [0, 1, 2, 3],
            comparisonChannelIndices: [0, 1, 2, 3],
            exemplarRange: exemplar,
            matchThreshold: 0.8,
            windowSizeSeconds: Double(templateWidth) / templateRate,
            downsampleRate: templateRate,
            mergeWindowSeconds: 0.1,
            polarity: .same
        )
    }

    @Test func waveformTemplateMatchesCatalog() throws {
        let entry = try entry("Waveform template match")
        let planted = SyntheticSignal.plantedBumps(
            channelCount: 4, count: templateCount,
            positions: [200, 700, 1200, 1700, 2200],
            width: templateWidth, samplingRate: templateRate
        )
        let signal = SyntheticSignal.make(planted.data, samplingRate: templateRate)
        let result = ArtifactTemplateDetector.detect(
            in: signal, configuration: templateConfig(exemplar: planted.exemplar)
        )
        expectAnchor(result.selectedEvents, matches: entry)
    }

    @Test func topographyScanMatchesCatalog() throws {
        let entry = try entry("Topography scan")
        let planted = SyntheticSignal.plantedBumps(
            channelCount: 4, count: templateCount,
            positions: [200, 700, 1200, 1700, 2200],
            width: templateWidth, samplingRate: templateRate
        )
        let signal = SyntheticSignal.make(planted.data, samplingRate: templateRate)

        var config = templateConfig(exemplar: planted.exemplar)
        config.topographyMode = .peak
        config.topographyChannelIndices = [0, 1, 2, 3]
        config.topographyScanStyle = .windowed

        let (events, _) = ArtifactTemplateDetector.detectTopography(in: signal, configuration: config)
        expectAnchor(events, matches: entry)
    }

    @Test func continuousScanMatchesCatalog() throws {
        let entry = try entry("Continuous scan")
        let longWidth = 300
        let position = 800
        let spatialShape: [Float] = [1.0, -0.8, 0.6, -0.4]

        var data = (0..<4).map { channel -> [Float] in
            var state = UInt64(channel + 3)
            return (0..<templateCount).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 0.05)
            }
        }
        let envelope = SyntheticSignal.bump(width: longWidth)
        for channel in 0..<4 {
            for k in 0..<longWidth {
                data[channel][position + k] += spatialShape[channel] * 60 * envelope[k]
            }
        }
        let signal = SyntheticSignal.make(data, samplingRate: templateRate)

        let peakCenter = position + longWidth / 2
        var config = templateConfig(exemplar: (peakCenter - 10)...(peakCenter + 10))
        config.topographyMode = .peak
        config.topographyChannelIndices = [0, 1, 2, 3]
        config.topographyScanStyle = .continuous
        config.continuousMinDurationSeconds = 0.05
        config.continuousSmoothingSeconds = 0.08

        let (events, _) = ArtifactTemplateDetector.detectTopography(in: signal, configuration: config)
        expectAnchor(events, matches: entry)
    }

    @Test func trajectoryScanMatchesCatalog() throws {
        let entry = try entry("Trajectory scan")
        let rate = 100.0
        var data = [[Float]](repeating: [Float](repeating: 0, count: 400), count: 4)
        for t in 0..<10 {
            let frame = (0..<4).map { channel in
                Float(50 * sin(2 * .pi * Double(channel) / 4 + Double(t) * 0.3))
            }
            for channel in 0..<4 {
                data[channel][50 + t] = frame[channel]
                data[channel][200 + t] = frame[channel]
            }
        }
        let signal = SyntheticSignal.make(data, samplingRate: rate)

        let config = ArtifactTemplateConfiguration(
            name: "CatalogTrajectory",
            eventCode: "TRAJ",
            selectedChannelIndices: [0, 1, 2, 3],
            comparisonChannelIndices: [0, 1, 2, 3],
            exemplarRange: 50...59,
            matchThreshold: 0.85,
            windowSizeSeconds: 10 / rate,
            downsampleRate: rate,
            mergeWindowSeconds: 0.1,
            polarity: .same,
            topographyMode: .trajectory,
            trajectoryShiftSeconds: 0,
            trajectoryScaleRange: 0,
            trajectoryGFPWeighted: false
        )
        let (events, _) = ArtifactTemplateDetector.detectTopography(in: signal, configuration: config)
        expectAnchor(events, matches: entry)
    }

    // MARK: - Import

    /// The catalog's "Imported events" row is a claim about every reader, so it
    /// is verified against a real file rather than a constructed event.
    @Test func importedEventsMatchCatalog() throws {
        let entry = try entry("Imported events")
        let samplingRate = 250.0
        let sampleCount = 2500
        let source = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/dev/null"),
            signalType: "EEG",
            numberOfChannels: 2,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: Date(timeIntervalSince1970: 1_760_000_000),
            events: [
                MFFEvent(
                    id: "e1", code: "STIM", beginTimeSeconds: 1.5, rawBeginTime: "1.5",
                    sourceFile: "test", durationSeconds: 0.25, timeAnchor: .onset
                )
            ],
            data: Array(repeating: [Float](repeating: 0, count: sampleCount), count: 2),
            channelNames: ["E1", "E2"]
        )

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-catalog-\(UUID().uuidString).mff")
        defer { try? FileManager.default.removeItem(at: out) }
        try MFFWriter.write(
            signal: source, segments: [], kind: .continuous, to: out,
            preserveSourceFileInfo: false
        )

        let readback = try MFFReader().loadSignal(from: out)
        expectAnchor(readback.events, matches: entry)
    }

    // MARK: - Catalog shape

    /// Every anchor must be represented, or the Preferences table would quietly
    /// omit a whole category of behaviour.
    @Test func catalogCoversEveryAnchor() {
        for anchor in EventTimeAnchor.allCases {
            #expect(
                !EventAnchorCatalog.entries(for: anchor).isEmpty,
                "no catalog entry uses .\(anchor.rawValue)"
            )
        }
    }

    @Test func catalogEntryNamesAreUnique() {
        let names = EventAnchorCatalog.entries.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// The detector-backed entries name a real `sourceFile` constant, so the
    /// table's provenance column cannot drift from what detectors stamp.
    @Test func catalogSourcePrefixesMatchDetectorConstants() throws {
        #expect(try entry("Eye-artifact threshold").sourceFilePrefix == EyeArtifactThresholdDetector.sourceFile)
        #expect(try entry("ECG (R wave)").sourceFilePrefix == RWaveDetector.sourceFile)
        #expect(try entry("BCG").sourceFilePrefix == BCGDetector.sourceFile)
        #expect(try entry("Wavelet Explorer").sourceFilePrefix == WaveletArtifactExplorerViewModel.candidateSourceFile)
    }
}
