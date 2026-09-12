//
//  RhythmicBurstDetectorTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct RhythmicBurstDetectorTests {
    private struct Oracle: Decodable {
        struct Configuration: Decodable {
            var peakPercentile: Double
            var boundaryPercentile: Double
            var minimumDurationCycles: Double
        }
        struct Expected: Decodable {
            struct Burst: Decodable {
                var peakFrequencyIndex: Int
                var peakFrequencyHz: Double
                var peakSample: Int
                var onsetSample: Int
                var offsetSample: Int
                var durationMilliseconds: Double
                var durationCycles: Double
                var peakPower: Double
                var relativePeakPowerDB: Double
                var peakWTPL: Double
                var bandName: String
            }
            var peakThresholds: [Double]
            var boundaryThresholds: [Double]
            var bursts: [Burst]
        }
        var samplingRateHz: Double
        var frequenciesHz: [Double]
        var power: [[Double]]
        var wtpl: [[Double]]
        var configuration: Configuration
        var expected: Expected
    }

    @Test func matchesIndependentPythonMapOracle() throws {
        let data = try Data(contentsOf: Fixtures.url("Rhythmicity/burst-python-oracle.json"))
        let fixture = try JSONDecoder().decode(Oracle.self, from: data)
        var configuration = RhythmicBurstConfiguration.paper2026
        configuration.peakPercentile = fixture.configuration.peakPercentile
        configuration.boundaryPercentile = fixture.configuration.boundaryPercentile
        configuration.minimumDurationCycles = fixture.configuration.minimumDurationCycles
        let output = try RhythmicBurstDetector.detect(
            power: fixture.power, wtpl: fixture.wtpl,
            frequenciesHz: fixture.frequenciesHz, samplingRate: fixture.samplingRateHz,
            channelIndex: 0, channelName: "E1", segmentIndex: 0,
            bands: bands, configuration: configuration
        )
        compare(output.peakPowerThresholds, fixture.expected.peakThresholds)
        compare(output.boundaryPowerThresholds, fixture.expected.boundaryThresholds)
        #expect(output.bursts.count == fixture.expected.bursts.count)
        for (actual, expected) in zip(output.bursts, fixture.expected.bursts) {
            #expect(actual.peakFrequencyIndex == expected.peakFrequencyIndex)
            #expect(actual.peakFrequencyHz == expected.peakFrequencyHz)
            #expect(actual.peakLocalSample == expected.peakSample)
            #expect(actual.onsetLocalSample == expected.onsetSample)
            #expect(actual.offsetLocalSample == expected.offsetSample)
            #expect(abs(actual.durationMilliseconds - expected.durationMilliseconds) < 1e-10)
            #expect(abs(actual.durationCycles - expected.durationCycles) < 1e-10)
            #expect(abs(actual.peakPower - expected.peakPower) < 1e-10)
            #expect(abs(actual.relativePeakPowerDB - expected.relativePeakPowerDB) < 1e-10)
            #expect(abs((actual.peakWTPL ?? .nan) - expected.peakWTPL) < 1e-10)
            #expect(actual.bandName == expected.bandName)
        }
    }

    @Test func plateauHasOneDeterministicPeak() throws {
        var power = [[Double](repeating: 1, count: 20)]
        power[0][8] = 9
        power[0][9] = 9
        var config = looseConfiguration
        config.peakPercentile = 90
        config.boundaryPercentile = 80
        let result = try RhythmicBurstDetector.detect(
            power: power, frequenciesHz: [10], samplingRate: 100,
            channelIndex: 2, channelName: "E3", segmentIndex: 0, configuration: config
        )
        #expect(result.bursts.count == 1)
        #expect(result.bursts.first?.peakLocalSample == 8)
        #expect(result.bursts.first?.id == "c2-s0-t8-f0")
    }

    @Test func p75BoundaryAndSampleStrideStayInsideSegment() throws {
        let row = [0, 0, 1, 2, 5, 10, 5, 2, 1, 0, 0].map(Double.init)
        var config = looseConfiguration
        config.peakPercentile = 90
        config.boundaryPercentile = 50
        let result = try RhythmicBurstDetector.detect(
            power: [row], frequenciesHz: [10], samplingRate: 50, sampleStride: 2,
            channelIndex: 0, channelName: "E1", segmentIndex: 0, segmentStartSample: 100,
            configuration: config
        )
        let burst = try #require(result.bursts.first)
        #expect(burst.onsetGlobalSample >= 100)
        #expect(burst.offsetGlobalSample <= 120)
        #expect(burst.peakGlobalSample == 110)
    }

    @Test func overlappingNearPeaksMergeButDistantFrequencyRemains() throws {
        var power = [[Double]](repeating: [Double](repeating: 1, count: 30), count: 4)
        for t in 10...20 { power[0][t] = Double(8 - abs(t - 15)) }
        for t in 12...22 { power[1][t] = Double(10 - abs(t - 17)) }
        for t in 12...22 { power[3][t] = Double(9 - abs(t - 17)) }
        let result = try RhythmicBurstDetector.detect(
            power: power, frequenciesHz: [8, 10, 15, 25], samplingRate: 100,
            channelIndex: 0, channelName: "E1", segmentIndex: 0, configuration: looseConfiguration
        )
        #expect(result.bursts.count == 2)
        #expect(result.bursts.contains { $0.peakFrequencyHz == 10 })
        #expect(result.bursts.contains { $0.peakFrequencyHz == 25 })
    }

    @Test func wtplBoundarySourceRefinesTheIntervalAndExportsMetrics() throws {
        var power = [[Double](repeating: 1, count: 30)]
        power[0][15] = 10
        var wtpl = [[Double](repeating: 0.2, count: 30)]
        for t in 9...21 { wtpl[0][t] = 0.8 }
        var config = looseConfiguration
        config.boundarySource = .wtplThreshold
        config.wtplThreshold = 0.5
        let output = try RhythmicBurstDetector.detect(
            power: power, wtpl: wtpl, frequenciesHz: [10], samplingRate: 100,
            channelIndex: 0, channelName: "E1", segmentIndex: 0, bands: bands, configuration: config
        )
        let burst = try #require(output.bursts.first)
        #expect(burst.onsetLocalSample == 9)
        #expect(burst.offsetLocalSample == 21)
        #expect(burst.peakWTPL == 0.8)
        #expect(abs((burst.meanWTPL ?? 0) - 0.8) < 1e-12)
        #expect(RhythmicBurstExport.burstRows(output.bursts)[1].last == RhythmicBurstBoundarySource.wtplThreshold.rawValue)
    }

    @Test func summariesUseIntervalUnionForOccupancy() throws {
        var power = [[Double](repeating: 1, count: 100)]
        for t in 10...30 { power[0][t] += 8 - 0.4 * Double(abs(t - 20)) }
        for t in 60...80 { power[0][t] += 9 - 0.4 * Double(abs(t - 70)) }
        let output = try RhythmicBurstDetector.detect(
            power: power, frequenciesHz: [10], samplingRate: 100,
            channelIndex: 0, channelName: "E1", segmentIndex: 0, bands: bands, configuration: looseConfiguration
        )
        let summaries = RhythmicBurstDetector.summarize(
            bursts: output.bursts, bands: bands, analyzedDurationSecondsByChannel: [0: 1],
            samplingRateHz: 100, fallbackFrequencyRangeHz: 5...30
        )
        let summary = try #require(summaries.first)
        #expect(summary.burstCount == 2)
        #expect(summary.occupancyPercent >= 0 && summary.occupancyPercent <= 100)
        #expect(abs(summary.ratePerMinutePerHz - 20) < 1e-12)
    }

    @Test func exportBundleContainsMapsTablesProvenanceAndSafetyBoundary() throws {
        let selection = RhythmicitySelectionDescriptor(
            source: .processed, dataSelection: .selectedRange,
            segments: [.init(startSample: 0, endSample: 2, label: "selection")],
            channelScope: .current, channelSetName: nil, includedChannelIndices: [0],
            excludedBadChannelIndices: [], interpolatedChannelIndices: [], includedMarkedArtifacts: false
        )
        let map = RhythmicBurstMap(
            id: "c0-s0", channelIndex: 0, channelName: "E1", segmentIndex: 0,
            segmentID: nil, segmentLabel: "selection", segmentStartSample: 0, segmentEndSample: 2,
            sampleStride: 1, frequenciesHz: [10], timesSeconds: [0, 0.01, 0.02],
            normalizedPower: [[0.5, 2, 0.5]], wtpl: [[0.2, 0.8, 0.2]],
            waveformTimesSeconds: [0, 0.01, 0.02], waveform: [0, 1, 0]
        )
        let analysis = RhythmicBurstAnalysisResult(
            configuration: .paper2026,
            source: .init(recordingIdentity: "fixture#revision", displayName: "Fixture"),
            processingProvenance: .init(sourceRevision: "revision", processingSummary: ["processed"]),
            selection: selection, samplingRateHz: 100, frequenciesHz: [10], morletWidthCycles: 5,
            wtplLagCycles: [-1, 1], bandSourceDescription: "test", bandDefinitions: bands,
            maps: [map], bursts: [], summaries: [], warnings: ["test warning"]
        )
        let bundle = try RhythmicBurstExport.bundle(
            result: analysis, exportedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(bundle.files.keys.contains("manifest.json"))
        #expect(bundle.files.keys.contains("bursts.csv"))
        #expect(bundle.files.keys.contains("burst-band-summary.csv"))
        #expect(bundle.files.keys.contains("burst-power-c0-s0.npy"))
        #expect(bundle.files.keys.contains("burst-wtpl-c0-s0.npy"))
        let manifest = try #require(bundle.files["manifest.json"])
        let text = String(decoding: manifest, as: UTF8.self)
        #expect(text.contains(RhythmicBurstDetector.referenceFileSHA256))
        #expect(text.contains("not artifact detection, rejection, or cleaning"))
        #expect(text.contains("revision"))
    }

    private static let bands = [
        RhythmicBurstBandDefinition(id: "alpha", name: "Alpha", lowHz: 7, highHz: 13, direction: .sustained, source: "test"),
        RhythmicBurstBandDefinition(id: "beta", name: "Beta", lowHz: 14, highHz: 30, direction: .transient, source: "test"),
    ]

    private static var looseConfiguration: RhythmicBurstConfiguration {
        var value = RhythmicBurstConfiguration.paper2026
        value.peakPercentile = 90
        value.boundaryPercentile = 75
        value.minimumDurationCycles = 0
        return value
    }

    private func compare(_ actual: [Double], _ expected: [Double]) {
        #expect(actual.count == expected.count)
        for (a, e) in zip(actual, expected) { #expect(abs(a - e) < 1e-12) }
    }

    private var bands: [RhythmicBurstBandDefinition] { Self.bands }
    private var looseConfiguration: RhythmicBurstConfiguration { Self.looseConfiguration }
}
