//
//  LocalTemplateBackendParityTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Acceptance gate for the local-template Metal backend, on the same terms as
//  GradientBackendParityTests: the CPU path is the definition of correct, and a
//  disagreement is never resolved by changing it.
//
//  Two kinds of agreement, and they are not the same kind. Decisions — which
//  events are corrected, which donors each used, which skip reason applied —
//  must match **exactly**, because every one of them is made on the CPU before a
//  backend sees anything, so any divergence is a plumbing bug rather than a
//  rounding one. Numbers must match within a documented tolerance, because Metal
//  has no double.
//
//  Every test skips rather than fails where no Metal device is present.
//

import Testing
import Foundation
@testable import EVA

struct LocalTemplateBackendParityTests {

    private var metalAvailable: Bool { LocalTemplateMetalBackend.isAvailable }

    // MARK: - Fixtures

    /// Channels carrying a repeating artifact at a different amplitude each, plus
    /// a rhythm that is not TR-locked, so the channels are not copies of one
    /// another and a channel-indexing mistake shows up.
    private func makeChannels(count: Int, samples: Int, period: Int) -> [[Float]] {
        (0..<count).map { channel in
            let gain = 1.0 - 0.12 * Double(channel % 5)
            let rhythm = 6.0 + Double(channel % 3)
            return (0..<samples).map { sample in
                let phase = Double(sample % period) / Double(period)
                let artifact = gain * (120 * sin(2 * .pi * phase) + 55 * sin(6 * .pi * phase + 0.7))
                let physiology = 5 * sin(2 * .pi * rhythm * Double(sample) / 1000.0)
                return Float(artifact + physiology)
            }
        }
    }

    private func events(centers: [Int], start: Int, end: Int) -> [LocalTemplateSampleEvent] {
        let window = LocalTemplateSampleWindow(startOffset: start, endOffset: end)
        return centers.map { LocalTemplateSampleEvent(centerSample: $0, window: window) }
    }

    private func amplitude(_ channels: [[Float]]) -> Double {
        channels.reduce(0.0) { best, channel in
            max(best, channel.reduce(0.0) { max($0, abs(Double($1))) })
        }
    }

    // MARK: - Shared assertions

    private func expectParity(
        _ label: String,
        channels: [[Float]],
        events: [LocalTemplateSampleEvent],
        _ mutate: (inout LocalTemplateConfiguration) -> Void = { _ in }
    ) throws {
        var cpuConfig = LocalTemplateConfiguration()
        mutate(&cpuConfig)
        cpuConfig.computeBackend = .cpu
        var metalConfig = cpuConfig
        metalConfig.computeBackend = .metal

        let cpu = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: events, configuration: cpuConfig
        )
        let metal = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: events, configuration: metalConfig
        )

        // Decisions, exactly.
        #expect(cpu.eventSummaries.count == metal.eventSummaries.count, "\(label): summary count")
        for (left, right) in zip(cpu.eventSummaries, metal.eventSummaries) {
            #expect(left.eventIndex == right.eventIndex, "\(label): event order")
            #expect(left.donorIndices == right.donorIndices,
                    "\(label): event \(left.eventIndex) donors")
            #expect(left.skippedReason == right.skippedReason,
                    "\(label): event \(left.eventIndex) skip reason")
            #expect(left.rejectedDonors.map(\.eventIndex) == right.rejectedDonors.map(\.eventIndex),
                    "\(label): event \(left.eventIndex) rejected donors")
            #expect((left.scaleFactors == nil) == (right.scaleFactors == nil),
                    "\(label): event \(left.eventIndex) scale presence")
        }

        // Numbers, within tolerance, as a fraction of the artifact amplitude so
        // the bound cannot silently weaken on larger-amplitude data.
        let peak = amplitude(channels)
        let rmsBound = peak * 1e-4
        let maxBound = peak * 1e-3
        for channel in cpu.cleanedChannels.indices {
            let left = cpu.cleanedChannels[channel]
            let right = metal.cleanedChannels[channel]
            #expect(left.count == right.count)
            var total = 0.0
            var worst = 0.0
            for index in left.indices {
                let difference = abs(Double(left[index]) - Double(right[index]))
                total += difference * difference
                worst = max(worst, difference)
            }
            let rms = (total / Double(max(left.count, 1))).squareRoot()
            #expect(rms < rmsBound, "\(label): channel \(channel) RMS \(rms) exceeded \(rmsBound)")
            #expect(worst < maxBound, "\(label): channel \(channel) max \(worst) exceeded \(maxBound)")
        }

        // Fitted scales, where they exist.
        for (left, right) in zip(cpu.eventSummaries, metal.eventSummaries) {
            guard let a = left.scaleFactors, let b = right.scaleFactors else { continue }
            for (x, y) in zip(a, b) {
                #expect(abs(x - y) < 1e-3, "\(label): event \(left.eventIndex) scale \(x) vs \(y)")
            }
        }
    }

    // MARK: - Across the configuration space

    @Test func medianAndMeanAgree() throws {
        guard metalAvailable else { return }
        let channels = makeChannels(count: 8, samples: 6_000, period: 200)
        let centers = stride(from: 0, to: 6_000, by: 200).map { $0 }
        let list = events(centers: centers, start: 0, end: 200)

        try expectParity("MAS median", channels: channels, events: list) {
            $0.donorsBefore = 4; $0.donorsAfter = 4; $0.reducer = .median
        }
        try expectParity("mean", channels: channels, events: list) {
            $0.donorsBefore = 4; $0.donorsAfter = 4; $0.reducer = .mean
        }
    }

    @Test func leastSquaresFitAgrees() throws {
        guard metalAvailable else { return }
        let channels = makeChannels(count: 6, samples: 6_000, period: 200)
        let list = events(centers: stride(from: 0, to: 6_000, by: 200).map { $0 }, start: 0, end: 200)
        try expectParity("MAR", channels: channels, events: list) {
            $0.donorsBefore = 4; $0.donorsAfter = 4
            $0.reducer = .median; $0.fit = .leastSquares
        }
    }

    @Test func weightedReducersAgree() throws {
        guard metalAvailable else { return }
        let channels = makeChannels(count: 6, samples: 6_000, period: 200)
        let list = events(centers: stride(from: 0, to: 6_000, by: 200).map { $0 }, start: 0, end: 200)
        try expectParity("wAAS", channels: channels, events: list) {
            $0.donorsBefore = 3; $0.donorsAfter = 3
            $0.reducer = .exponentiallyWeighted(timeConstantSamples: 400)
        }
        try expectParity("wAAR", channels: channels, events: list) {
            $0.donorsBefore = 3; $0.donorsAfter = 3
            $0.reducer = .exponentiallyWeighted(timeConstantSamples: 400)
            $0.fit = .leastSquares
        }
    }

    /// The floor changes the donor set, so the two backends must reach the same
    /// set — this is the decision most likely to leak.
    @Test func theCorrelationFloorAgrees() throws {
        guard metalAvailable else { return }
        let channels = makeChannels(count: 5, samples: 5_000, period: 250)
        let list = events(centers: stride(from: 0, to: 5_000, by: 250).map { $0 }, start: 0, end: 250)
        try expectParity("correlation floor", channels: channels, events: list) {
            $0.donorsBefore = 4; $0.donorsAfter = 4
            $0.minimumDonorCorrelation = 0.5
        }
    }

    /// Windows centred on the event, so neighbouring corrections overlap and the
    /// raised-cosine overlap-add is exercised. The GPU builds this from the
    /// output side rather than scattering, which is the part worth checking.
    @Test func overlappingWindowsAgree() throws {
        guard metalAvailable else { return }
        let channels = makeChannels(count: 4, samples: 4_000, period: 200)
        let list = events(centers: stride(from: 200, to: 3_800, by: 150).map { $0 }, start: -120, end: 120)
        try expectParity("overlapping windows", channels: channels, events: list) {
            $0.donorsBefore = 3; $0.donorsAfter = 3
        }
    }

    @Test func degenerateShapesAgree() throws {
        guard metalAvailable else { return }

        // One channel.
        try expectParity(
            "single channel",
            channels: makeChannels(count: 1, samples: 3_000, period: 150),
            events: events(centers: stride(from: 0, to: 3_000, by: 150).map { $0 }, start: 0, end: 150)
        ) { $0.donorsBefore = 2; $0.donorsAfter = 2 }

        // Events hanging off both ends, so windows clip.
        try expectParity(
            "clipped edges",
            channels: makeChannels(count: 3, samples: 2_000, period: 200),
            events: events(centers: [-50, 0, 200, 400, 1_900, 2_100], start: -100, end: 100)
        ) { $0.donorsBefore = 2; $0.donorsAfter = 2 }

        // Skips: a minimum nothing meets, with the skip policy on.
        try expectParity(
            "everything skipped",
            channels: makeChannels(count: 3, samples: 2_000, period: 200),
            events: events(centers: stride(from: 0, to: 2_000, by: 200).map { $0 }, start: 0, end: 200)
        ) {
            $0.donorsBefore = 1; $0.donorsAfter = 1
            $0.minimumDonorCount = 12
            $0.insufficientDonorPolicy = .skipTarget
        }

        // Channel count that is not a comfortable multiple of anything.
        try expectParity(
            "33 channels",
            channels: makeChannels(count: 33, samples: 1_500, period: 150),
            events: events(centers: stride(from: 0, to: 1_500, by: 150).map { $0 }, start: 0, end: 150)
        ) { $0.donorsBefore = 2; $0.donorsAfter = 2 }
    }

    // MARK: - Guarantees

    @Test func theGPUPathIsDeterministic() throws {
        guard metalAvailable else { return }
        let channels = makeChannels(count: 6, samples: 5_000, period: 250)
        let list = events(centers: stride(from: 0, to: 5_000, by: 250).map { $0 }, start: -60, end: 190)
        var config = LocalTemplateConfiguration()
        config.donorsBefore = 4
        config.donorsAfter = 4
        config.fit = .leastSquares
        config.computeBackend = .metal

        let first = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: list, configuration: config
        )
        let second = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: list, configuration: config
        )
        // Bit-identical, not approximately equal. Anything else means a
        // nondeterministic accumulation order — an atomic add, most likely.
        #expect(first.cleanedChannels == second.cleanedChannels)
        #expect(first.artifactEstimate == second.artifactEstimate)
    }

    /// A donor list past what the kernels can reduce in registers must fall back
    /// rather than fail or silently truncate.
    @Test func anOversizedDonorListFallsBackToTheCPU() throws {
        guard metalAvailable else { return }
        let channels = makeChannels(count: 2, samples: 4_000, period: 100)
        let list = events(centers: stride(from: 0, to: 4_000, by: 100).map { $0 }, start: 0, end: 100)

        var config = LocalTemplateConfiguration()
        config.donorsBefore = 30
        config.donorsAfter = 30   // 60 donors, past LocalTemplateMetalBackend.maximumDonors
        var metalConfig = config
        metalConfig.computeBackend = .metal

        let cpu = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: list, configuration: config
        )
        let fellBack = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: list, configuration: metalConfig
        )
        // Fell back, so this is the CPU result exactly — not merely close.
        #expect(cpu.cleanedChannels == fellBack.cleanedChannels)
    }

    /// Samples no event covers must come through untouched on the GPU too.
    @Test func uncoveredSamplesArePassedThrough() throws {
        guard metalAvailable else { return }
        let channels = makeChannels(count: 4, samples: 3_000, period: 100)
        // A gap between 1500 and 2500 that no window reaches.
        let centers = stride(from: 0, to: 1_400, by: 100).map { $0 }
            + stride(from: 2_500, to: 3_000, by: 100).map { $0 }
        var config = LocalTemplateConfiguration()
        config.donorsBefore = 3
        config.donorsAfter = 3
        config.computeBackend = .metal

        let result = try LocalTemplateArtifactCorrector.correct(
            channels: channels,
            events: events(centers: centers, start: 0, end: 100),
            configuration: config
        )
        for channel in channels.indices {
            for sample in 1_600..<2_400 {
                #expect(result.cleanedChannels[channel][sample] == channels[channel][sample],
                        "channel \(channel) sample \(sample) was modified")
                #expect(result.artifactEstimate[channel][sample] == 0)
            }
        }
    }

    /// The default is the CPU, so nothing changes for a caller that did not ask.
    @Test func theDefaultBackendIsTheCPU() {
        #expect(LocalTemplateConfiguration().computeBackend == .cpu)
    }
}
