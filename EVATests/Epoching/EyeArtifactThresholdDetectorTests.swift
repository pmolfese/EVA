//
//  EyeArtifactThresholdDetectorTests.swift
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

struct EyeArtifactThresholdDetectorTests {

    private func channelsWithBlink(channelCount: Int, sampleCount: Int, blinkChannels: [Int], at range: Range<Int>) -> [[Float]] {
        var channels = (0..<channelCount).map { _ in [Float](repeating: 5, count: sampleCount) }
        for ch in blinkChannels {
            for i in range { channels[ch][i] = 200 }
        }
        return channels
    }

    @Test func hydroCel128LayoutNameUsesTableOcularChannels() {
        let layoutName = "HydroCel GSN 128 1.0"

        let blink = EyeArtifactThresholdDetector.autoOcularChannelIndices(
            kind: .blink,
            channelCount: 129,
            sensorLayoutName: layoutName
        )
        let movement = EyeArtifactThresholdDetector.autoOcularChannelIndices(
            kind: .movement,
            channelCount: 129,
            sensorLayoutName: layoutName
        )

        #expect(blink.map { $0 + 1 } == [25, 127, 21, 8, 126, 14])
        #expect(movement.map { $0 + 1 } == [125, 128])
    }

    @Test func hydroCelLayoutNamesUseTableOcularChannelsForAllSupportedSizes() {
        let expectedByLayout: [(String, Int, [Int], [Int])] = [
            ("HydroCel GSN 32 1.0", 33, [2, 30, 1, 29], [31, 32]),
            ("HydroCel GSN 64 1.0", 65, [10, 63, 5, 62], [61, 64]),
            ("HydroCel GSN 128 1.0", 129, [25, 127, 21, 8, 126, 14], [125, 128]),
            ("HydroCel GSN 256 1.0", 257, [37, 241, 32, 18, 238, 25], [226, 252])
        ]

        for (layoutName, channelCount, expectedBlink, expectedMovement) in expectedByLayout {
            let blink = EyeArtifactThresholdDetector.autoOcularChannelIndices(
                kind: .blink,
                channelCount: channelCount,
                sensorLayoutName: layoutName
            )
            let movement = EyeArtifactThresholdDetector.autoOcularChannelIndices(
                kind: .movement,
                channelCount: channelCount,
                sensorLayoutName: layoutName
            )

            #expect(blink.map { $0 + 1 } == expectedBlink)
            #expect(movement.map { $0 + 1 } == expectedMovement)
        }
    }

    @Test func loadedNominalPlusOneChannelCountUsesHydroCelTableFallback() {
        let blink = EyeArtifactThresholdDetector.autoOcularChannelIndices(
            kind: .blink,
            channelCount: 129
        )
        let movement = EyeArtifactThresholdDetector.autoOcularChannelIndices(
            kind: .movement,
            channelCount: 129
        )

        #expect(blink.map { $0 + 1 } == [25, 127, 21, 8, 126, 14])
        #expect(movement.map { $0 + 1 } == [125, 128])
    }

    @Test func detectsBlinkAboveThreshold() {
        // 128-channel layout: blink channels are 1-based [8, 25, 126, 127] -> 0-based.
        let channelCount = 129
        let sampleCount = 1000
        let samplingRate = 250.0
        let range = 100..<130 // 120 ms, above the 50 ms minimum duration
        let channels = channelsWithBlink(
            channelCount: channelCount, sampleCount: sampleCount,
            blinkChannels: [7, 24], at: range
        )
        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate
        )
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.code == EyeArtifactKind.blink.eventCode })
        let time = events[0].beginTimeSeconds
        #expect(time >= Double(range.lowerBound) / samplingRate - 0.01)
        #expect(time <= Double(range.upperBound) / samplingRate + 0.01)
        // The window span is carried as duration (≈ range length) for highlighting.
        let expectedDuration = Double(range.count) / samplingRate
        #expect(events[0].durationSeconds != nil)
        #expect(abs((events[0].durationSeconds ?? 0) - expectedDuration) <= 1.0 / samplingRate + 1e-6)
    }

    @Test func defaultBlinkConfigPreservesLegacyUnconstrainedTiming() {
        let channelCount = 129
        let sampleCount = 1000
        let samplingRate = 250.0
        let range = 100..<300 // 800 ms: legacy threshold detection had no max-duration gate.
        let channels = channelsWithBlink(
            channelCount: channelCount, sampleCount: sampleCount,
            blinkChannels: [7], at: range
        )

        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate
        )

        #expect(events.count == 1)
    }

    @Test func explicitMaxDurationCanRejectLongBlinkRuns() {
        let channelCount = 129
        let sampleCount = 1000
        let samplingRate = 250.0
        let channels = channelsWithBlink(
            channelCount: channelCount, sampleCount: sampleCount,
            blinkChannels: [7], at: 100..<300
        )
        var config = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        config.maxDurationSeconds = 0.5

        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate, configuration: config
        )

        #expect(events.isEmpty)
    }

    @Test func mergedRunsUseStrongestPeakForEventTime() {
        let channelCount = 129
        let sampleCount = 1000
        let samplingRate = 250.0
        var channels = (0..<channelCount).map { _ in [Float](repeating: 0, count: sampleCount) }
        for i in 100..<115 { channels[7][i] = 200 }
        for i in 130..<145 { channels[7][i] = 350 }

        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate
        )

        #expect(events.count == 1)
        #expect(abs((events.first?.beginTimeSeconds ?? 0) - Double(130) / samplingRate) < 1e-9)
    }

    @Test func ignoresBriefSubThresholdDurationBlips() {
        let channelCount = 129
        let sampleCount = 1000
        let channels = channelsWithBlink(
            channelCount: channelCount, sampleCount: sampleCount,
            blinkChannels: [7], at: 100..<102 // 8 ms, below the 50 ms minimum
        )
        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: 250,
            duration: Double(sampleCount) / 250
        )
        #expect(events.isEmpty)
    }

    @Test func noEventsWhenBelowThreshold() {
        let channels = (0..<129).map { _ in [Float](repeating: 5, count: 1000) }
        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: 250, duration: 4
        )
        #expect(events.isEmpty)
    }

    @Test func amplitudeMaxRejectsSaturation() {
        let channelCount = 129
        let sampleCount = 1000
        // A 900 µV deflection: above the 150 min but above a 500 max cap.
        var channels = (0..<channelCount).map { _ in [Float](repeating: 5, count: sampleCount) }
        for i in 100..<130 { channels[7][i] = 900 }
        var config = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        config.amplitudeMaxMicrovolts = 500
        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: 250,
            duration: Double(sampleCount) / 250, configuration: config
        )
        #expect(events.isEmpty)
    }

    @Test func positivePolarityIgnoresNegativeDeflection() {
        let channelCount = 129
        let sampleCount = 1000
        var channels = (0..<channelCount).map { _ in [Float](repeating: 0, count: sampleCount) }
        for i in 100..<130 { channels[7][i] = -200 } // negative-going
        var config = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        config.polarity = .positive
        let positiveOnly = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: 250,
            duration: Double(sampleCount) / 250, configuration: config
        )
        #expect(positiveOnly.isEmpty)

        config.polarity = .bipolar
        let bipolar = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: 250,
            duration: Double(sampleCount) / 250, configuration: config
        )
        #expect(!bipolar.isEmpty)
    }

    @Test func velocityGateRejectsSlowRamp() {
        let channelCount = 129
        let sampleCount = 1000
        let samplingRate = 250.0
        // Slow ramp from 0 to 300 over 200 samples (0.8 s): reaches amplitude
        // but its slope is gentle.
        var channels = (0..<channelCount).map { _ in [Float](repeating: 0, count: sampleCount) }
        for i in 0..<200 { channels[7][100 + i] = Float(i) * 1.5 }
        for i in 300..<sampleCount { channels[7][i] = 300 }
        var config = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        config.maxDurationSeconds = 0 // don't reject on duration
        config.velocityEnabled = true
        config.velocityThresholdMicrovoltsPerMillisecond = 5 // ramp slope ≈ 0.375 µV/ms
        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate, configuration: config
        )
        #expect(events.isEmpty)
    }

    @Test func channelOverrideDetectsOnCustomChannel() {
        let channelCount = 129
        let sampleCount = 1000
        // Put the deflection on channel 50 (0-based), not in the auto set.
        var channels = (0..<channelCount).map { _ in [Float](repeating: 5, count: sampleCount) }
        for i in 100..<130 { channels[50][i] = 200 }

        let auto = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: 250,
            duration: Double(sampleCount) / 250
        )
        #expect(auto.isEmpty) // channel 50 isn't in the default net set

        var config = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        config.channelOverride = [50]
        let overridden = EyeArtifactThresholdDetector.detect(
            kind: .blink, channels: channels, samplingRate: 250,
            duration: Double(sampleCount) / 250, configuration: config
        )
        #expect(!overridden.isEmpty)
    }
}
