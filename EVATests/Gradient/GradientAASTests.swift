//
//  GradientAASTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//

import Foundation
import Testing
@testable import EVA

struct GradientAASTests {

    @Test func evaLocalPresetRemovesRepeatedVolumeArtifact() throws {
        let spacing = 100
        let volumes = 24
        let sampleCount = spacing * volumes
        let triggers = (0..<volumes).map { $0 * spacing }
        let channel = (0..<sampleCount).map { sample -> Float in
            let artifact = 70 * Float(sin(Double(sample % spacing) * 0.31))
                + 20 * Float((sample % spacing) % 7)
            let signal = 4 * Float(sin(2 * .pi * Double(sample) / 63))
            return artifact + signal
        }

        let result = try GradientAAS.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: .evaLocal,
            samplingRate: 1_000
        )

        #expect(result.channels.count == 1)
        #expect(result.channels[0].count == sampleCount)
        let lo = spacing * 6
        let hi = spacing * 18
        let before = energy(channel, range: lo..<hi)
        let after = energy(result.channels[0], range: lo..<hi)
        #expect(after < before * 0.25)
        #expect(result.diagnostics.correctedEpochCount > 0)
    }

    @Test func allenPresetUsesFixedSectionsAndCorrelationGate() throws {
        let spacing = 80
        let volumes = 30
        let sampleCount = spacing * volumes
        let triggers = (0..<volumes).map { $0 * spacing }
        var channel = (0..<sampleCount).map { sample -> Float in
            50 * Float(sin(Double(sample % spacing) * 0.4))
        }

        // Poison one donor epoch in the first fixed section. The running
        // template should reject it once the initial always-include epochs are
        // established.
        for sample in (10 * spacing)..<(11 * spacing) {
            channel[sample] += 500 * Float(sin(Double(sample) * 0.17))
        }

        var config = GradientAAS.Config.allenIARVolume
        config.templateWindow = .fixedSections(epochCount: 15)
        config.timingInterpolation = .none
        config.anc = false

        let result = try GradientAAS.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 1_000
        )

        let epochFive = try #require(result.diagnostics.epochs.first { $0.epoch == 5 })
        #expect(!epochFive.donorIndices.contains(10))
        #expect(epochFive.donorIndices.count >= config.alwaysIncludeInitialEpochs - 1)
    }

    @Test func allenSlicePresetBuildsSliceEpochs() throws {
        let spacing = 120
        let slices = 4
        let volumes = 10
        let sampleCount = spacing * volumes
        let triggers = (0..<volumes).map { $0 * spacing }
        let channel = (0..<sampleCount).map { sample -> Float in
            30 * Float(sin(Double(sample % (spacing / slices)) * 0.5))
        }

        var config = GradientAAS.Config.allenIARSlice(
            slicesPerVolume: slices,
            samplingRate: 1_000,
            trSeconds: Double(spacing) / 1_000
        )
        config.templateWindow = .fixedSections(epochCount: 12)
        config.timingInterpolation = .none
        config.anc = false

        let result = try GradientAAS.correct(
            channels: [channel],
            volumeTriggers: triggers,
            config: config,
            samplingRate: 1_000
        )

        #expect(result.diagnostics.epochCount == volumes * slices)
        #expect(result.diagnostics.period == spacing / slices)
        #expect(result.channels[0].count == sampleCount)
    }

    private func energy(_ values: [Float], range: Range<Int>) -> Double {
        range.reduce(0.0) { sum, index in
            sum + Double(values[index] * values[index])
        }
    }

    // MARK: - Motion censoring

    /// A censored volume is still corrected, but never contributes to anyone
    /// else's template — the same rule the FASTR family follows. Before this was
    /// wired, the sheet's "Exclude high-motion TRs" toggle was shown for Allen
    /// AAS and silently did nothing.
    @Test func censoredVolumesAreCorrectedButNeverDonate() throws {
        let period = 100
        let volumes = 40
        let sampleCount = period * volumes + period
        // Volume 20 carries a wildly different artifact, so if it donates it
        // visibly contaminates its neighbours' templates.
        var channel = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            let volume = min(sample / period, volumes - 1)
            let phase = Double(sample % period) / Double(period)
            let gain = volume == 20 ? 6.0 : 1.0
            channel[sample] = Float(gain * 100 * sin(2 * .pi * phase))
        }
        let triggers = (0..<volumes).map { $0 * period }

        var config = GradientAAS.Config.evaLocal
        config.templateWindow = .localNeighbors(before: 4, after: 4)
        var censored = config
        censored.censoredVolumes = [20]

        let plain = try GradientAAS.correct(
            channels: [channel], volumeTriggers: triggers,
            config: config, samplingRate: 1000
        )
        let withCensor = try GradientAAS.correct(
            channels: [channel], volumeTriggers: triggers,
            config: censored, samplingRate: 1000
        )

        // Neighbours of volume 20 come out cleaner once it stops donating.
        func residual(_ corrected: [Float], _ range: Range<Int>) -> Double {
            let total = range.reduce(0.0) { $0 + Double(corrected[$1]) * Double(corrected[$1]) }
            return (total / Double(range.count)).squareRoot()
        }
        let neighbours = (18 * period)..<(20 * period)
        #expect(residual(withCensor.channels[0], neighbours)
                < residual(plain.channels[0], neighbours))

        // And volume 20 itself is still corrected, not passed through.
        let target = (20 * period)..<(21 * period)
        let inputEnergy = residual(channel, target)
        #expect(residual(withCensor.channels[0], target) < inputEnergy)
    }

    /// Allen's fixed sections honour the censor list too, not just the
    /// local-neighbour window.
    @Test func censoringAppliesToAllenSectionsAsWell() throws {
        let period = 100
        let volumes = 40
        let sampleCount = period * volumes + period
        var channel = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            let phase = Double(sample % period) / Double(period)
            channel[sample] = Float(100 * sin(2 * .pi * phase))
        }
        let triggers = (0..<volumes).map { $0 * period }

        var config = GradientAAS.Config.allenIARVolume
        config.templateWindow = .fixedSections(epochCount: 10)
        config.anc = false
        var censored = config
        censored.censoredVolumes = Set(0..<10)

        let plain = try GradientAAS.correct(
            channels: [channel], volumeTriggers: triggers, config: config, samplingRate: 1000
        )
        let withCensor = try GradientAAS.correct(
            channels: [channel], volumeTriggers: triggers, config: censored, samplingRate: 1000
        )
        // Censoring an entire section changes the outcome, so the list is read.
        #expect(plain.channels[0] != withCensor.channels[0])
        #expect(withCensor.channels[0].allSatisfy { $0.isFinite })
    }
}
