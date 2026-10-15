//
//  SaccadicSpikeCorrectionTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation
import Testing
@testable import EVA

struct SaccadicSpikeCorrectionTests {
    private let samplingRate = 500.0
    private let topography: [Float] = [-1.0, -0.9, 0.0, 0.7]

    private var selection: SaccadicSpikeChannelSelection {
        SaccadicSpikeChannelSelection(
            czIndex: 2,
            verticalEOGIndices: [0, 1],
            lowerVerticalEOGIndices: [0, 1],
            horizontalEOGIndices: [],
            analysisIndices: [0, 1, 2, 3]
        )
    }

    private func signal(
        pulses: [Int],
        biphasic: Bool = true,
        commonOffset: Float = 0,
        sampleCount: Int = 800
    ) -> MFFSignalData {
        var data = Array(
            repeating: [Float](repeating: commonOffset, count: sampleCount),
            count: topography.count
        )
        for onset in pulses {
            let end = biphasic ? onset + 3 : sampleCount
            for channel in data.indices {
                for sample in (onset + 1)..<min(end, sampleCount) {
                    data[channel][sample] += topography[channel] * 20
                }
            }
        }
        return SyntheticSignal.make(data, samplingRate: samplingRate)
    }

    private func detect(_ signal: MFFSignalData) throws -> SaccadicSpikeDetectionResult {
        try SaccadicSpikeDetector.detect(
            in: signal,
            selection: selection,
            configuration: .default,
            canonicalTopography: topography
        )
    }

    @Test func detectsOnlyBiphasicVEOGDominantSpikes() throws {
        let result = try detect(signal(pulses: [200, 500]))
        #expect(result.preliminaryCandidateCount == 2)
        #expect(result.events.count == 2)
        #expect(result.events.allSatisfy { $0.durationSeconds == 0.024 })

        let monophasic = try detect(signal(pulses: [200], biphasic: false))
        #expect(monophasic.preliminaryCandidateCount == 1)
        #expect(monophasic.events.isEmpty)
    }

    @Test func detectionIsIndependentOfCommonReferenceOffset() throws {
        let baseline = try detect(signal(pulses: [200, 500]))
        let shifted = try detect(signal(pulses: [200, 500], commonOffset: 12_345))
        #expect(shifted.events.map(\.beginTimeSeconds) == baseline.events.map(\.beginTimeSeconds))
        #expect(shifted.topography.channelValues == baseline.topography.channelValues)
    }

    @Test func refractoryGateKeepsOneSpikeWithinOneHundredMilliseconds() throws {
        // 30 samples at 500 Hz = 60 ms.
        let result = try detect(signal(pulses: [200, 230, 500]))
        #expect(result.preliminaryCandidateCount == 3)
        #expect(result.events.count == 2)
        #expect(result.events.map { Int(($0.beginTimeSeconds * samplingRate).rounded()) } == [200, 500])
    }

    @Test func spatialFilterRemovesCanonicalPatternAndPreservesExcludedChannel() throws {
        let input = signal(pulses: [200, 500])
        let result = try detect(input)
        let artifact = DefinedArtifact(
            type: .saccadicSpike,
            name: "Saccadic Spike Potential",
            eventCode: SaccadicSpikeDetector.eventCode,
            events: result.events,
            selectedChannelIndices: result.topography.channelIndices,
            windowSizeSeconds: 0.024,
            average: nil,
            topography: result.topography,
            cleaningMethod: .spikeTemplate,
            saccadicSpikeConfiguration: .default
        )
        var data = input.data
        let excludedBefore = data[3]
        let channelCount = SaccadicSpikeSpatialFilter.apply(
            artifact: artifact,
            data: &data,
            samplingRate: samplingRate,
            excluding: [3]
        )

        #expect(channelCount == 3)
        #expect(data[3] == excludedBefore)
        for channel in 0..<2 {
            #expect(abs(data[channel][201]) < 1e-4)
            #expect(abs(data[channel][501]) < 1e-4)
        }
    }

    @Test func templateNormalizationUsesCzToLowerVEOGDifference() throws {
        let normalized = try SaccadicSpikeDetector.normalizedTemplate(
            [4, 2, 7, 10],
            selection: selection
        )
        #expect(abs(normalized[2]) < 1e-6)
        let lowerMean = (normalized[0] + normalized[1]) / 2
        #expect(abs(lowerMean + 1) < 1e-6)
    }

    @Test func replayPayloadPreservesSpatialFilterAndConfiguration() throws {
        let result = try detect(signal(pulses: [200]))
        var configuration = SaccadicSpikeConfiguration.default
        configuration.templateSource = .sessionAverage
        configuration.sensitivitySigma = 6.25
        let artifact = DefinedArtifact(
            type: .saccadicSpike,
            name: "Saccadic Spike Potential",
            eventCode: SaccadicSpikeDetector.eventCode,
            events: result.events,
            selectedChannelIndices: result.topography.channelIndices,
            windowSizeSeconds: configuration.windowSeconds,
            average: nil,
            topography: result.topography,
            cleaningMethod: .spikeTemplate,
            saccadicSpikeConfiguration: configuration
        )

        let encoded = try ArtifactReplayPayload.encoder().encode(
            ArtifactReplayPayload(artifacts: [artifact])
        )
        let decoded = try ArtifactReplayPayload.decoder().decode(
            ArtifactReplayPayload.self,
            from: encoded
        )
        let restored = try #require(decoded.artifacts.first)
        #expect(restored.type == .saccadicSpike)
        #expect(restored.cleaningMethod == .spikeTemplate)
        #expect(restored.saccadicSpikeConfiguration == configuration)
        #expect(restored.topography?.channelIndices == result.topography.channelIndices)
        #expect(restored.topography?.channelValues == result.topography.channelValues)
    }
}
