//
//  ChannelRelationshipAnalyzerTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct ChannelRelationshipAnalyzerTests {
    private let samplingRate = 250.0
    private let sampleCount = 2_500

    @Test func exactPersistentPairIsReportedAsLikelyBridgeWithContext() {
        var channels = distinctChannels(count: 8)
        let source = channels[0]
        channels[7] = source.enumerated().map { index, value in
            value + Float(0.02 * sin(Double(index) * 0.37))
        }
        let health = [
            0: healthResult(channel: 0, ransac: "median r 0.91, 0% bad windows"),
            7: healthResult(channel: 7, ransac: "median r 0.93, 0% bad windows")
        ]

        let findings = ChannelRelationshipAnalyzer.analyze(
            signal: signal(channels),
            layout: nil,
            healthResults: health
        )

        let finding = try! #require(findings.first { $0.contains(channel: 0) && $0.contains(channel: 7) })
        #expect(finding.kind == .likelyBridge)
        #expect(finding.medianCorrelation > 0.999)
        #expect(finding.medianDifferentialRMSMicrovolts < 0.1)
        #expect(finding.persistentWindowFraction >= 0.8)
        #expect(finding.firstNeighborPrediction?.contains("median r") == true)
    }

    @Test func scaledCopyIsHighCorrelationButNotBridge() {
        var channels = distinctChannels(count: 8)
        channels[1] = channels[0].map { $0 * 1.8 }

        let findings = ChannelRelationshipAnalyzer.analyze(signal: signal(channels), layout: nil)
        let finding = try! #require(findings.first { $0.contains(channel: 0) && $0.contains(channel: 1) })

        #expect(finding.kind == .highCorrelation)
        #expect(finding.medianCorrelation > 0.999)
        #expect(finding.medianDifferentialRMSMicrovolts > 1)
    }

    @Test func detailedAnalysisRetainsStrongestPartnerWhenNothingIsFlagged() {
        let analysis = ChannelRelationshipAnalyzer.analyzeDetailed(
            signal: signal(distinctChannels(count: 8)),
            layout: nil
        )

        #expect(analysis.findings.isEmpty)
        let summary = try! #require(analysis.strongestByChannel[0])
        #expect(summary.channel == 0)
        #expect(summary.partner != 0)
        #expect(summary.medianCorrelation.isFinite)
        #expect(!summary.isFlaggedFinding)
    }

    @Test func detailedAnalysisMarksTheStrongestSummaryWhenItsPairIsAFinding() {
        var channels = distinctChannels(count: 8)
        channels[7] = channels[0]

        let analysis = ChannelRelationshipAnalyzer.analyzeDetailed(
            signal: signal(channels),
            layout: nil
        )

        let summary = try! #require(analysis.strongestByChannel[0])
        #expect(summary.partner == 7)
        #expect(summary.isFlaggedFinding)
        #expect(summary.medianCorrelation > 0.999)
    }

    @Test func strongCommonModeDoesNotBecomeLikelyBridgeAndRaisesReferenceFinding() {
        var channels = distinctChannels(count: 12, amplitude: 5)
        let common = SyntheticSignal.sine(
            frequency: 1.7,
            samplingRate: samplingRate,
            count: sampleCount,
            amplitude: 35
        )
        for channel in channels.indices {
            channels[channel] = zip(channels[channel], common).map(+)
        }
        let synthetic = signal(channels)

        let relationships = ChannelRelationshipAnalyzer.analyze(signal: synthetic, layout: nil)
        let reference = try! #require(ChannelReferenceAnalyzer.analyze(signal: synthetic))

        #expect(!relationships.contains { $0.kind == .likelyBridge })
        #expect(reference.hasFinding)
        #expect(reference.positiveLoadingFraction >= 0.8)
        #expect(reference.commonModeRMSMicrovolts > 10)
    }

    @Test func distinctCleanChannelsHaveGoodReferenceAssessment() {
        let reference = try! #require(
            ChannelReferenceAnalyzer.analyze(signal: signal(distinctChannels(count: 12)))
        )

        #expect(reference.grade == .good)
        #expect(reference.positiveLoadingFraction < 0.65)
    }

    @Test func averageReferenceRestoresAnOmittedAcquisitionReferenceBeforeTakingTheMean() throws {
        let source = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/omitted-reference.bin"),
            signalType: "EEG",
            numberOfChannels: 2,
            samplingRate: 1_000,
            duration: 0.002,
            recordingStartTime: nil,
            events: [],
            data: [[1, 2], [3, 4]],
            channelNames: ["E1", "E2"],
            acquisitionReference: EEGAcquisitionReference(
                channelIndex: 2,
                name: "Cz",
                isRecorded: false
            ),
            referenceState: .acquisition
        )

        let referenced = Rereferencing.applied(source)

        #expect(referenced.numberOfChannels == 3)
        #expect(referenced.channelNames == ["E1", "E2", "Cz"])
        #expect(referenced.referenceState == .average)
        #expect(referenced.acquisitionReference?.isRecorded == false)
        for sample in 0..<2 {
            let sum = referenced.data.reduce(Float(0)) { $0 + $1[sample] }
            #expect(abs(sum) < 1e-6)
        }
        #expect(abs(referenced.data[2][0] + 4.0 / 3.0) < 1e-6)
        #expect(abs(referenced.data[2][1] + 2.0) < 1e-6)
    }

    @Test func globalFingerprintFindsNonNeighborPairInLargeMontage() {
        var channels = distinctChannels(count: 70, amplitude: 15)
        channels[69] = channels[0]
        let positions = (0..<70).map { index in
            let angle = 2 * Double.pi * Double(index) / 70
            return SensorPosition(channelIndex: index, x: cos(angle), y: sin(angle))
        }
        let layout = SensorLayout(name: "Synthetic 70", positions: positions)

        let findings = ChannelRelationshipAnalyzer.analyze(signal: signal(channels), layout: layout)

        #expect(findings.contains {
            $0.kind == .likelyBridge && $0.contains(channel: 0) && $0.contains(channel: 69)
        })
    }

    private func distinctChannels(count: Int, amplitude: Float = 20) -> [[Float]] {
        (0..<count).map { channel in
            let frequency = 3.1 + Double(channel) * 0.731
            let phase = Double(channel) * 0.41
            return (0..<sampleCount).map { sample in
                let time = Double(sample) / samplingRate
                let primary = Double(amplitude) * sin(2 * .pi * frequency * time + phase)
                let secondary = 0.23 * Double(amplitude) * sin(2 * .pi * (frequency * 1.73) * time + phase / 2)
                return Float(primary + secondary)
            }
        }
    }

    private func signal(_ data: [[Float]]) -> MFFSignalData {
        let impedances = data.indices.map { Float(20 + $0) }
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/channel-relationships.bin"),
            signalType: "EEG",
            numberOfChannels: data.count,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: Date(timeIntervalSince1970: 0),
            events: [],
            data: data,
            impedancesKOhm: impedances
        )
    }

    private func healthResult(channel: Int, ransac: String) -> ChannelHealthResult {
        ChannelHealthResult(
            channelIndex: channel,
            goodPercentage: 90,
            grade: .good,
            summary: "Good",
            metrics: [
                ChannelHealthMetric(
                    name: "Neighbor Prediction",
                    score: 0.9,
                    grade: .good,
                    detail: ransac,
                    weight: 1.4
                )
            ]
        )
    }
}
