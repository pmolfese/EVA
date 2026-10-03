//
//  GradientBrainSafetyRegressionTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Fast, always-on sentinels distilled from the MRI-1 C5 measurement campaign.
//  These fixtures establish engineering invariants and preserve a known
//  counterexample; they are not evidence that a simulator-derived threshold is
//  clinically valid on real simultaneous EEG/fMRI.
//

import Foundation
import Testing
@testable import EVA

struct GradientBrainSafetyRegressionTests {

    private struct Fidelity {
        var errorRatio: Double
        var correlation: Double
    }

    private struct EpochFixture {
        var channels: [[Float]]
        var triggers: [Int]
        var epochCount: Int
        var period: Int
        var samplingRate: Double
    }

    /// Pooled clean-signal error and correlation over complete epochs.
    private func fidelity(
        truth: [[Float]],
        output: [[Float]],
        sampleRange: Range<Int>
    ) -> Fidelity {
        var truthMean = 0.0
        var outputMean = 0.0
        var count = 0
        for channel in 0..<min(truth.count, output.count) {
            for sample in sampleRange {
                truthMean += Double(truth[channel][sample])
                outputMean += Double(output[channel][sample])
                count += 1
            }
        }
        guard count > 1 else { return Fidelity(errorRatio: .infinity, correlation: 0) }
        truthMean /= Double(count)
        outputMean /= Double(count)

        var errorEnergy = 0.0
        var truthEnergy = 0.0
        var outputEnergy = 0.0
        var cross = 0.0
        for channel in 0..<min(truth.count, output.count) {
            for sample in sampleRange {
                let x = Double(truth[channel][sample]) - truthMean
                let y = Double(output[channel][sample]) - outputMean
                let error = y - x
                errorEnergy += error * error
                truthEnergy += x * x
                outputEnergy += y * y
                cross += x * y
            }
        }
        return Fidelity(
            errorRatio: truthEnergy > 0 ? errorEnergy / truthEnergy : .infinity,
            correlation: truthEnergy > 0 && outputEnergy > 0
                ? cross / (truthEnergy * outputEnergy).squareRoot()
                : 0
        )
    }

    /// Deterministic, non-epoch-locked EEG-like activity. The non-integral
    /// frequencies deliberately move through the scanner epoch so a temporal
    /// donor average behaves like an average of unrelated brain samples.
    private func nonLockedBrainFixture() -> EpochFixture {
        let rate = 500.0
        let period = 100
        let epochs = 64
        let sampleCount = (epochs + 1) * period
        var channels = [[Float]](repeating: [Float](repeating: 0, count: sampleCount), count: 4)

        for channel in channels.indices {
            var state = UInt64(0x5AFE_2026 + channel * 101)
            for sample in 0..<sampleCount {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = (Double(state >> 11) / Double(1 << 53) - 0.5) * 0.8
                let time = Double(sample) / rate
                let phase = Double(channel) * 0.41
                channels[channel][sample] = Float(
                    4.0 * sin(2 * .pi * (7.13 + 0.19 * Double(channel)) * time + phase)
                    + 2.5 * cos(2 * .pi * (11.37 + 0.11 * Double(channel)) * time - phase)
                    + 1.2 * sin(2 * .pi * 2.31 * time + 0.7 * phase)
                    + noise
                )
            }
        }
        return EpochFixture(
            channels: channels,
            triggers: (0..<epochs).map { $0 * period },
            epochCount: epochs,
            period: period,
            samplingRate: rate
        )
    }

    /// Alternating event and control epochs. The event has a fixed scanner
    /// phase, so raw waveform-correlation ranking can choose event epochs for
    /// event targets and control epochs for control targets, subtracting away
    /// the between-condition response. Temporal neighbors mix both kinds.
    private func phaseLockedResponseFixture() -> EpochFixture {
        let rate = 512.0
        let period = 128
        let epochs = 48
        let sampleCount = (epochs + 1) * period
        let amplitudes = [18.0, -14.0, 11.0, -9.0]
        var channels = [[Float]](repeating: [Float](repeating: 0, count: sampleCount), count: amplitudes.count)

        for channel in channels.indices {
            var state = UInt64(0xE2F0_2026 + channel * 131)
            for sample in 0..<sampleCount {
                state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                let noise = (Double(state >> 11) / Double(1 << 53) - 0.5) * 0.5
                let time = Double(sample) / rate
                let epoch = sample / period
                let position = sample % period
                let background = 2.8 * sin(
                    2 * .pi * (7.21 + 0.17 * Double(channel)) * time + 0.3 * Double(channel)
                ) + 1.7 * cos(2 * .pi * 12.43 * time - 0.2 * Double(channel)) + noise
                let distance = (Double(position) - 42.0) / 8.0
                let response = epoch < epochs && epoch.isMultiple(of: 2)
                    ? amplitudes[channel] * exp(-0.5 * distance * distance)
                    : 0
                channels[channel][sample] = Float(background + response)
            }
        }
        return EpochFixture(
            channels: channels,
            triggers: (0..<epochs).map { $0 * period },
            epochCount: epochs,
            period: period,
            samplingRate: rate
        )
    }

    private func conservativeConfig() -> GradientCorrectionConfig {
        var config = GradientCorrectionConfig()
        config.averagingWindowBefore = 8
        config.averagingWindowAfter = 8
        config.templateScaling = .unscaled
        config.alignmentEnabled = false
        config.subSampleAlignment = false
        config.computeBackend = .cpu
        return config
    }

    private func conditionDifference(
        _ channels: [[Float]],
        fixture: EpochFixture,
        epochs: Range<Int>
    ) -> [Double] {
        var event = [Double](repeating: 0, count: channels.count * fixture.period)
        var control = [Double](repeating: 0, count: channels.count * fixture.period)
        var eventCount = 0
        var controlCount = 0
        for epoch in epochs {
            let isEvent = epoch.isMultiple(of: 2)
            if isEvent { eventCount += 1 } else { controlCount += 1 }
            for channel in channels.indices {
                let start = epoch * fixture.period
                for offset in 0..<fixture.period {
                    let index = channel * fixture.period + offset
                    if isEvent {
                        event[index] += Double(channels[channel][start + offset])
                    } else {
                        control[index] += Double(channels[channel][start + offset])
                    }
                }
            }
        }
        return event.indices.map {
            event[$0] / Double(eventCount) - control[$0] / Double(controlCount)
        }
    }

    private func transferBeta(reference: [Double], candidate: [Double]) -> Double {
        guard reference.count == candidate.count else { return .nan }
        let denominator = reference.reduce(0) { $0 + $1 * $1 }
        guard denominator > 0 else { return .nan }
        return zip(reference, candidate).reduce(0) { $0 + $1.0 * $1.1 } / denominator
    }

    @Test func productionDefaultsKeepAggressiveStagesOptIn() {
        let config = GradientCorrectionConfig()
        #expect(config.templateScheme == .temporalNeighbors)
        #expect(config.obs == .off)
        #expect(!config.anc)
        #expect(config.correlationThreshold == 0.9)
        #expect(config.minimumCorrelatedDonors == 4)
    }

    @Test func temporalTemplateStaysInsideCleanSignalDevelopmentBound() throws {
        let fixture = nonLockedBrainFixture()
        let result = try GradientTemplateCorrector.correct(
            channels: fixture.channels,
            volumeTriggers: fixture.triggers,
            config: conservativeConfig(),
            samplingRate: fixture.samplingRate
        )

        // Interior epochs have the full donor set. These are deliberately the
        // C5 development bounds, not a claim about safety on real EEG/fMRI.
        let interior = (8 * fixture.period)..<((fixture.epochCount - 8) * fixture.period)
        let measured = fidelity(
            truth: fixture.channels,
            output: result.channels,
            sampleRange: interior
        )
        #expect(measured.errorRatio <= 0.10, "clean truth error was \(measured.errorRatio)")
        #expect(measured.correlation >= 0.95, "clean correlation was \(measured.correlation)")
        #expect(result.diagnostics.obsComponentCounts.isEmpty)
        #expect(result.diagnostics.ancAppliedChannels.isEmpty)
    }

    @Test func rawCorrelationRankingErasesAPhaseLockedConditionDifference() throws {
        let fixture = phaseLockedResponseFixture()
        var temporalConfig = conservativeConfig()
        temporalConfig.averagingWindowBefore = 4
        temporalConfig.averagingWindowAfter = 4
        let temporal = try GradientTemplateCorrector.correct(
            channels: fixture.channels,
            volumeTriggers: fixture.triggers,
            config: temporalConfig,
            samplingRate: fixture.samplingRate
        )

        var rankedConfig = temporalConfig
        rankedConfig.templateScheme = .correlationRanked
        rankedConfig.correlationThreshold = -1
        rankedConfig.minimumCorrelatedDonors = 1
        rankedConfig.correlationSearchWindow = 20
        let ranked = try GradientTemplateCorrector.correct(
            channels: fixture.channels,
            volumeTriggers: fixture.triggers,
            config: rankedConfig,
            samplingRate: fixture.samplingRate
        )

        let interiorEpochs = 6..<(fixture.epochCount - 6)
        let reference = conditionDifference(
            fixture.channels,
            fixture: fixture,
            epochs: interiorEpochs
        )
        let temporalDifference = conditionDifference(
            temporal.channels,
            fixture: fixture,
            epochs: interiorEpochs
        )
        let rankedDifference = conditionDifference(
            ranked.channels,
            fixture: fixture,
            epochs: interiorEpochs
        )
        let temporalBeta = transferBeta(reference: reference, candidate: temporalDifference)
        let rankedBeta = transferBeta(reference: reference, candidate: rankedDifference)

        // This deliberately preserves a known counterexample. When an
        // artifact-evidence gate is introduced, this test should be changed to
        // require the gate to choose the conservative path—not weakened or
        // deleted merely because the implementation changed.
        #expect(temporalBeta >= 0.75, "temporal transfer beta was \(temporalBeta)")
        #expect(rankedBeta <= 0.40, "correlation-ranked transfer beta was \(rankedBeta)")
        #expect(rankedBeta < temporalBeta * 0.5)
    }
}
