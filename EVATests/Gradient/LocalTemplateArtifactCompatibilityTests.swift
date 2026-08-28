//
//  LocalTemplateArtifactCompatibilityTests.swift
//  EVATests
//
//  Dirty-room compatibility checks.
//
//  These tests intentionally call EVA's older AMRI-facing implementations as
//  black-box behavioral oracles and compare them with the clean-room
//  LocalTemplateArtifactCorrector. They are validation tests, not implementation
//  source for the clean-room component.
//

import Foundation
import Testing
@testable import EVA

struct LocalTemplateArtifactCompatibilityTests {

    private let samplingRate = 1_000.0

    // The two gradient MAS/MAR cases that compared against `GradientRemover`
    // were removed with that engine on 2026-08-09. Their oracle no longer
    // exists, and their result is recorded in docs/provenance/README.md. The
    // cases below compare against `ArtifactCleaner`, which is still present.

    @Test func cleanLocalMASMatchesOldArtifactCleanerWhenSmoothingIsDisabled() throws {
        let windowSamples = 40
        let centers = [120, 260, 400, 540, 680]
        let template = bump(width: windowSamples).map(Float.init)
        let scales: [Float] = [2.0, 1.8, 2.2, 1.9, 2.1]
        let channel = artifactChannel(
            template: template,
            centers: centers,
            scales: scales,
            sampleCount: 820
        )
        var artifact = makeArtifact(
            events: makeEvents(centers: centers, samplingRate: samplingRate),
            template: template,
            windowSamples: windowSamples,
            method: .mas
        )
        artifact.localTemplateWindowSize = 3
        artifact.localTemplatePreservesLocalBaseline = false
        artifact.localTemplateEdgeTaperSeconds = 0

        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)
        let old = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: []).signal.data[0]

        var config = LocalTemplateConfiguration()
        config.donorsBefore = 1
        config.donorsAfter = 1
        config.reducer = .median
        config.fit = .unscaled
        let clean = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: sampleEvents(centers: centers, windowSamples: windowSamples),
            configuration: config
        ).cleanedChannels[0].map(Double.init)

        let interiorCenters = Array(centers.dropFirst().dropLast())
        #expect(
            rmsDifference(
                eventSamples(old.map(Double.init), centers: interiorCenters, windowSamples: windowSamples),
                eventSamples(clean, centers: interiorCenters, windowSamples: windowSamples)
            ) < 0.002
        )
    }

    @Test func cleanLocalWAASDocumentsOldGlobalSelfDonationDifference() throws {
        let windowSamples = 40
        let centers = [100, 220, 340, 460, 580, 700, 820]
        let scales = [10.0, 20, 30, 40, 50, 60, 70]
        let template = impulseTemplate(width: windowSamples, centerValue: 1).map(Float.init)
        var channel = [Float](repeating: 0, count: 920)
        for (center, scale) in zip(centers, scales) {
            channel[center] += Float(scale)
        }

        var artifact = makeArtifact(
            events: makeEvents(centers: centers, samplingRate: samplingRate),
            template: template,
            windowSamples: windowSamples,
            method: .waas
        )
        artifact.localTemplateWindowSize = 3
        artifact.waasDecayFactor = 0.9
        artifact.waasUsesAMRIGlobalWeights = true
        artifact.localTemplatePreservesLocalBaseline = false
        artifact.localTemplateEdgeTaperSeconds = 0

        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)
        let old = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: []).signal.data[0]

        var config = LocalTemplateConfiguration()
        config.donorsBefore = centers.count
        config.donorsAfter = centers.count
        config.reducer = .exponentiallyWeighted(timeConstantSamples: -Double(centers[1] - centers[0]) / log(artifact.waasDecayFactor))
        config.fit = .unscaled
        let clean = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: sampleEvents(centers: centers, windowSamples: windowSamples, donorEligible: true),
            configuration: config
        ).cleanedChannels[0].map(Double.init)

        let oldEnergy = eventEnergy(old.map(Double.init), centers: centers, windowSamples: windowSamples)
        let cleanEnergy = eventEnergy(clean, centers: centers, windowSamples: windowSamples)
        let inputEnergy = eventEnergy(channel.map(Double.init), centers: centers, windowSamples: windowSamples)

        #expect(oldEnergy < inputEnergy)
        #expect(cleanEnergy < inputEnergy)
        // Dirty-room note: the old AMRI-global wAAS path includes the target
        // event as its own donor. The clean-room generic local-template
        // corrector deliberately excludes self-donation, so exact equality is
        // not expected unless we add an explicit self-donation option.
        #expect(abs(Double(old[centers[0]]) - clean[centers[0]]) > 1e-3)
    }

    @Test func cleanLocalWAARAndOldWAARBothReduceScaledEvents() throws {
        let windowSamples = 40
        let centers = [100, 240, 380, 520, 660, 800]
        let template = bump(width: windowSamples).map(Float.init)
        let scales: [Float] = [1.0, 1.8, 1.2, 2.1, 1.4, 2.4]
        let channel = artifactChannel(
            template: template,
            centers: centers,
            scales: scales,
            sampleCount: 940
        )

        var artifact = makeArtifact(
            events: makeEvents(centers: centers, samplingRate: samplingRate),
            template: template,
            windowSamples: windowSamples,
            method: .waar
        )
        artifact.localTemplateWindowSize = 3
        artifact.waasDecayFactor = 0.85
        artifact.waasUsesAMRIGlobalWeights = false
        artifact.localTemplatePreservesLocalBaseline = false
        artifact.localTemplateEdgeTaperSeconds = 0

        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)
        let old = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: []).signal.data[0]

        var config = LocalTemplateConfiguration()
        config.donorsBefore = 1
        config.donorsAfter = 1
        config.reducer = .exponentiallyWeighted(timeConstantSamples: -Double(centers[1] - centers[0]) / log(artifact.waasDecayFactor))
        config.fit = .leastSquares
        let clean = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: sampleEvents(centers: centers, windowSamples: windowSamples),
            configuration: config
        ).cleanedChannels[0].map(Double.init)

        let oldEnergy = eventEnergy(old.map(Double.init), centers: centers, windowSamples: windowSamples)
        let cleanEnergy = eventEnergy(clean, centers: centers, windowSamples: windowSamples)
        let inputEnergy = eventEnergy(channel.map(Double.init), centers: centers, windowSamples: windowSamples)

        // Both paths now use the conventional template-denominator
        // least-squares coefficient, so neither should preserve the historical
        // amplification bug on scaled events.
        #expect(oldEnergy < inputEnergy)
        #expect(cleanEnergy < inputEnergy)
    }

    private func gradientMASConfiguration(spacing: Int) -> LocalTemplateConfiguration {
        var config = LocalTemplateConfiguration()
        // Four neighbours each side, the donor window the historical engine used.
        config.donorsBefore = 4
        config.donorsAfter = 4
        config.minimumDonorDistanceSamples = Int((0.3 * samplingRate).rounded()) + 1
        config.reducer = .median
        config.fit = .unscaled
        return config
    }

    private func repeatedGradientChannel(spacing: Int, volumeCount: Int) -> [Float] {
        let sampleCount = spacing * volumeCount
        return (0..<sampleCount).map { sample in
            let position = sample % spacing
            return 80 * Float(sin(Double(position) * 0.25)) + 25 * Float(position % 11)
        }
    }

    private func makeEvents(centers: [Int], samplingRate: Double) -> [MFFEvent] {
        centers.enumerated().map { index, center in
            MFFEvent(
                id: "compat-\(index)",
                code: "COMPAT",
                beginTimeSeconds: Double(center) / samplingRate,
                rawBeginTime: String(format: "%.4f", Double(center) / samplingRate),
                sourceFile: "dirty-room-compat"
            )
        }
    }

    private func makeArtifact(
        events: [MFFEvent],
        template: [Float],
        windowSamples: Int,
        method: ArtifactCleaningMethod
    ) -> DefinedArtifact {
        let average = ArtifactTemplateAverage(
            samplingRate: samplingRate,
            windowSizeSeconds: Double(windowSamples) / samplingRate,
            eventCount: events.count,
            selectedChannelIndices: [0],
            allChannelSamples: [template],
            channelSummaries: [
                ArtifactTemplateChannelSummary(channelIndex: 0, peakAbsoluteMicrovolts: 80, rmsMicrovolts: 20)
            ]
        )
        return DefinedArtifact(
            type: .ocular,
            name: "Compatibility",
            eventCode: "COMPAT",
            events: events,
            selectedChannelIndices: [0],
            windowSizeSeconds: Double(windowSamples) / samplingRate,
            average: average,
            topography: nil,
            cleaningMethod: method
        )
    }

    private func sampleEvents(
        centers: [Int],
        windowSamples: Int,
        donorEligible: Bool = true
    ) -> [LocalTemplateSampleEvent] {
        let window = LocalTemplateSampleWindow(
            startOffset: -windowSamples / 2,
            endOffset: windowSamples - windowSamples / 2
        )
        return centers.map {
            LocalTemplateSampleEvent(
                centerSample: $0,
                window: window,
                isDonorEligible: donorEligible
            )
        }
    }

    private func artifactChannel(
        template: [Float],
        centers: [Int],
        scales: [Float],
        sampleCount: Int
    ) -> [Float] {
        var channel = [Float](repeating: 0, count: sampleCount)
        for (center, scale) in zip(centers, scales) {
            let start = center - template.count / 2
            for offset in template.indices where channel.indices.contains(start + offset) {
                channel[start + offset] += scale * template[offset]
            }
        }
        return channel
    }

    private func bump(width: Int) -> [Double] {
        (0..<width).map { sample in
            let x = (Double(sample) - Double(width - 1) / 2) / (Double(width) / 8)
            return exp(-0.5 * x * x)
        }
    }

    private func impulseTemplate(width: Int, centerValue: Double) -> [Double] {
        var template = [Double](repeating: 0, count: width)
        template[width / 2] = centerValue
        return template
    }

    private func eventEnergy(_ values: [Double], centers: [Int], windowSamples: Int) -> Double {
        centers.reduce(0.0) { total, center in
            let start = center - windowSamples / 2
            return total + (0..<windowSamples).reduce(0.0) { subtotal, offset in
                let index = start + offset
                guard values.indices.contains(index) else { return subtotal }
                return subtotal + values[index] * values[index]
            }
        }
    }

    private func eventSamples(_ values: [Double], centers: [Int], windowSamples: Int) -> [Double] {
        centers.flatMap { center in
            let start = center - windowSamples / 2
            return (0..<windowSamples).compactMap { offset in
                let index = start + offset
                return values.indices.contains(index) ? values[index] : nil
            }
        }
    }

    private func interiorEnergy(_ values: [Double], spacing: Int, dropVolumes: Int) -> Double {
        let start = spacing * dropVolumes
        let end = max(start, values.count - spacing * dropVolumes)
        return values[start..<end].reduce(0) { $0 + $1 * $1 }
    }

    private func rmsDifference(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        let total = zip(lhs, rhs).reduce(0.0) { sum, pair in
            let delta = pair.0 - pair.1
            return sum + delta * delta
        }
        return (total / Double(lhs.count)).squareRoot()
    }

    private func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return 0 }
        let meanL = lhs.reduce(0, +) / Double(lhs.count)
        let meanR = rhs.reduce(0, +) / Double(rhs.count)
        var ll = 0.0
        var rr = 0.0
        var lr = 0.0
        for index in lhs.indices {
            let dl = lhs[index] - meanL
            let dr = rhs[index] - meanR
            ll += dl * dl
            rr += dr * dr
            lr += dl * dr
        }
        let denominator = (ll * rr).squareRoot()
        return denominator > 1e-12 ? lr / denominator : 0
    }
}
