//
//  TrialChannelResidualAnalyzerTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct TrialChannelResidualAnalyzerTests {
    private let samplingRate = 1_000.0
    private let stimulusOffset = 20
    private let length = 80

    private func base(channel: Int) -> [Float] {
        (0..<length).map { sample in
            Float(2 + sin(Double(sample) * 0.12 + Double(channel) * 0.3))
        }
    }

    private func trials(mutating target: (Int, Int, inout [Float]) -> Void) -> [TrialChannelResidualAnalyzer.TrialInput] {
        (0..<4).map { trial in
            let channels = (0..<4).map { channel -> TrialChannelResidualAnalyzer.ChannelInput in
                var samples = base(channel: channel)
                target(trial, channel, &samples)
                return .init(channelIndex: channel, channelName: "E\(channel + 1)", samples: samples)
            }
            return .init(trialIndex: trial, stimulusOffsetSamples: stimulusOffset, channels: channels)
        }
    }

    private var window: TrialAlignmentMetrics.AnalysisWindow {
        .init(name: "P1", startMs: 0, endMs: 40)
    }

    @Test func oneBadSensorIsLocalizedAndDominatesContribution() throws {
        let inputs = trials { trial, channel, samples in
            if trial == 0, channel == 2 {
                for sample in 30..<50 { samples[sample] += 12 }
            }
        }

        let summary = try #require(TrialChannelResidualAnalyzer.analyze(
            trials: inputs,
            samplingRate: samplingRate,
            windows: [window]
        ))
        let result = try #require(summary.trials.first { $0.trialIndex == 0 })
        let dominant = try #require(result.channels.max { $0.contributionFraction < $1.contributionFraction })

        #expect(result.pattern == .localized)
        #expect(result.dominantChannelIndex == 2)
        #expect(dominant.channelName == "E3")
        #expect(dominant.contributionFraction > 0.95)
        #expect(result.effectiveChannelCount < 1.2)
    }

    @Test func wholeTrialMismatchIsDistributedAcrossChannels() throws {
        let inputs = trials { trial, _, samples in
            if trial == 0 {
                for sample in 30..<50 { samples[sample] += 8 }
            }
        }

        let summary = try #require(TrialChannelResidualAnalyzer.analyze(
            trials: inputs,
            samplingRate: samplingRate,
            windows: [window]
        ))
        let result = try #require(summary.trials.first { $0.trialIndex == 0 })

        #expect(result.pattern == .distributed)
        #expect(result.dominantContributionFraction < 0.30)
        #expect(result.effectiveChannelCount > 3.8)
    }

    @Test func disjointWindowsExcludeArtifactsInTheirGap() throws {
        let inputs = trials { trial, channel, samples in
            if trial == 0, channel == 1 {
                for sample in 45..<55 { samples[sample] += 20 }
            }
        }
        let windows = [
            TrialAlignmentMetrics.AnalysisWindow(name: "early", startMs: 0, endMs: 15),
            TrialAlignmentMetrics.AnalysisWindow(name: "late", startMs: 40, endMs: 55)
        ]

        let summary = try #require(TrialChannelResidualAnalyzer.analyze(
            trials: inputs,
            samplingRate: samplingRate,
            windows: windows
        ))
        let result = try #require(summary.trials.first { $0.trialIndex == 0 })

        #expect(result.totalNormalizedResidualRMS < 1e-6)
        #expect(result.pattern == .distributed)
    }
}
