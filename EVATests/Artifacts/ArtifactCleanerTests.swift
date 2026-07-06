//
//  ArtifactCleanerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct ArtifactCleanerTests {

    private let samplingRate = 250.0
    private let windowSamples = 40

    private func makeSignal(
        template: [Float],
        centers: [Int],
        scales: [Float],
        sampleCount: Int
    ) -> [Float] {
        var state: UInt64 = 42
        var channel = (0..<sampleCount).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1
            return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 0.5)
        }
        for (center, scale) in zip(centers, scales) {
            let start = center - windowSamples / 2
            for k in 0..<windowSamples where start + k >= 0 && start + k < sampleCount {
                channel[start + k] += scale * template[k]
            }
        }
        return channel
    }

    private func makeArtifact(
        events: [MFFEvent],
        template: [Float],
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
            name: "Blink",
            eventCode: "BLINK",
            events: events,
            selectedChannelIndices: [0],
            windowSizeSeconds: Double(windowSamples) / samplingRate,
            average: average,
            topography: nil,
            cleaningMethod: method
        )
    }

    private func makeEvents(centers: [Int]) -> [MFFEvent] {
        centers.enumerated().map { index, center in
            MFFEvent(
                id: "blink-\(index)",
                code: "BLINK",
                beginTimeSeconds: Double(center) / samplingRate,
                rawBeginTime: String(format: "%.4f", Double(center) / samplingRate),
                sourceFile: "test"
            )
        }
    }

    private func windowEnergy(_ channel: [Float], center: Int) -> Double {
        let start = center - windowSamples / 2
        return (0..<windowSamples).reduce(0.0) { total, k in
            let s = start + k
            guard s >= 0, s < channel.count else { return total }
            return total + Double(channel[s] * channel[s])
        }
    }

    private func windowEnergy(_ data: [[Float]], centers: [Int]) -> Double {
        centers.reduce(0.0) { total, center in
            total + data.reduce(0.0) { channelTotal, channel in
                channelTotal + windowEnergy(channel, center: center)
            }
        }
    }

    private func makeTopographicSignal(
        centers: [Int],
        sampleCount: Int
    ) -> (signal: MFFSignalData, topography: [Float], template: [Float]) {
        let template = SyntheticSignal.bump(width: windowSamples)
        let topography: [Float] = [1.0, -0.85, 0.55, -0.40]
        var data = (0..<topography.count).map { channel -> [Float] in
            var state = UInt64(channel + 11)
            return (0..<sampleCount).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 0.05)
            }
        }

        for center in centers {
            let start = center - windowSamples / 2
            for channel in data.indices {
                for offset in 0..<windowSamples where data[channel].indices.contains(start + offset) {
                    data[channel][start + offset] += topography[channel] * template[offset]
                }
            }
        }

        return (SyntheticSignal.make(data, samplingRate: samplingRate), topography, template)
    }

    private func makeTopographicArtifact(
        events: [MFFEvent],
        template: [Float],
        topography: [Float],
        strategy: ArtifactOBSStrategy
    ) -> DefinedArtifact {
        var artifact = makeArtifact(events: events, template: template, method: .obs)
        artifact.selectedChannelIndices = Array(topography.indices)
        artifact.topography = ArtifactTemplateTopography(
            mode: .peak,
            referenceSample: Int((events.first?.beginTimeSeconds ?? 0) * samplingRate),
            referenceTimeSeconds: events.first?.beginTimeSeconds ?? 0,
            channelValues: topography,
            channelIndices: Array(topography.indices),
            matchThreshold: 0.80,
            matchCount: events.count
        )
        artifact.obsStrategy = strategy
        artifact.obsPCAComponentCount = 1
        artifact.obsEdgeTaperSeconds = 0
        artifact.obsUsesOverlapAdd = false
        artifact.obsClusterCount = 2
        return artifact
    }

    @Test func regressionSubstantiallyReducesTemplateArtifact() {
        let template = SyntheticSignal.bump(width: windowSamples)
        let centers = [100, 400, 700]
        let scales: [Float] = [2.0, 1.5, 2.5]
        let sampleCount = 1000

        let channel = makeSignal(template: template, centers: centers, scales: scales, sampleCount: sampleCount)
        let events = makeEvents(centers: centers)
        let artifact = makeArtifact(events: events, template: template, method: .regression)
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let (cleaned, summaries) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])

        #expect(summaries.count == 1)
        #expect(summaries[0].method == .regression)
        #expect(summaries[0].eventCount == 3)
        #expect(summaries[0].channelCount == 1)

        for center in centers {
            let before = windowEnergy(channel, center: center)
            let after = windowEnergy(cleaned.data[0], center: center)
            #expect(after < before * 0.3, "regression left too much artifact energy at \(center)")
        }
    }

    @Test func doNothingLeavesSignalUnchanged() {
        let template = SyntheticSignal.bump(width: windowSamples)
        let centers = [100, 400]
        let channel = makeSignal(template: template, centers: centers, scales: [2, 2], sampleCount: 800)
        let events = makeEvents(centers: centers)
        let artifact = makeArtifact(events: events, template: template, method: .doNothing)
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let (cleaned, summaries) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])

        #expect(summaries.isEmpty)
        #expect(cleaned.data[0] == channel)
    }

    @Test func emptyArtifactListLeavesSignalUnchanged() {
        let channel: [Float] = (0..<500).map { Float($0) * 0.01 }
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let (cleaned, summaries) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [], excluding: [])

        #expect(summaries.isEmpty)
        #expect(cleaned.data[0] == channel)
    }

    @Test func artifactWithNoEventsProducesNoSummary() {
        let template = SyntheticSignal.bump(width: windowSamples)
        let artifact = makeArtifact(events: [], template: template, method: .regression)
        let channel: [Float] = (0..<500).map { Float($0) * 0.01 }
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let (_, summaries) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])
        #expect(summaries.isEmpty)
    }

    @Test func obsStrategiesReduceTopographicArtifactEnergy() {
        let centers = [120, 260, 400, 540, 680]
        let (signal, topography, template) = makeTopographicSignal(centers: centers, sampleCount: 820)
        let events = makeEvents(centers: centers)
        let strategies: [ArtifactOBSStrategy] = [
            .standard,
            .topographyGated,
            .topographyAligned,
            .topographyWeighted,
            .virtualChannel,
            .clustered,
            .spatiotemporal
        ]

        for strategy in strategies {
            let artifact = makeTopographicArtifact(
                events: events,
                template: template,
                topography: topography,
                strategy: strategy
            )

            let (cleaned, summaries) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])
            let before = windowEnergy(signal.data, centers: centers)
            let after = windowEnergy(cleaned.data, centers: centers)

            #expect(summaries.count == 1, "\(strategy.rawValue) should report a cleaning summary")
            #expect(after < before * 0.70, "\(strategy.rawValue) left too much topographic artifact energy")
        }
    }

    @Test func obsVarianceReportFindsDominantFirstComponent() {
        // Every event carries almost the same template (small per-event jitter),
        // so nearly all residual variance should load onto the first PC.
        let template = SyntheticSignal.bump(width: windowSamples)
        let centers = stride(from: 100, to: 2000, by: 60).map { $0 }
        var state: UInt64 = 7
        let scales: [Float] = centers.map { _ in
            state = state &* 6364136223846793005 &+ 1
            return 1.8 + Float(Double(state >> 40) / Double(UInt32.max)) * 0.1 // ~1.8-1.9
        }
        let channel = makeSignal(template: template, centers: centers, scales: scales, sampleCount: 2100)
        let events = makeEvents(centers: centers)
        let artifact = makeArtifact(events: events, template: template, method: .obs)
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let report = ArtifactCleaner.obsVarianceReport(for: artifact, in: signal, maximumComponents: 4)
        let unwrapped = try! #require(report)
        #expect(unwrapped.eventCount == centers.count)
        #expect(!unwrapped.components.isEmpty)
        #expect(unwrapped.components[0].explainedVariance > 0.8, "expected the first PC to dominate a near-identical artifact")
        // Cumulative variance is monotonically non-decreasing and capped at 1.
        var previous = 0.0
        for component in unwrapped.components {
            #expect(component.cumulativeVariance >= previous - 1e-9)
            #expect(component.cumulativeVariance <= 1.0 + 1e-9)
            previous = component.cumulativeVariance
        }
    }

    // MARK: - MFFEvent.centerTimeSeconds

    /// Waveform-template and Trajectory scanning stamp `beginTimeSeconds` as
    /// the event's *center* directly (a pre-existing quirk of those two
    /// scanners) — `centerTimeSeconds` must pass that through unchanged, or
    /// every cleaning method (which centers its window on it) would shift.
    @Test func centerTimeSecondsPassesThroughForCenterTaggedSources() {
        let templateEvent = MFFEvent(
            id: "t", code: "BLINK", beginTimeSeconds: 12.5, rawBeginTime: "12.5",
            sourceFile: "Template 80%", durationSeconds: 0.3
        )
        #expect(templateEvent.centerTimeSeconds == 12.5)

        let trajectoryEvent = MFFEvent(
            id: "j", code: "BCG", beginTimeSeconds: 4.0, rawBeginTime: "4.0",
            sourceFile: "Trajectory 85%", durationSeconds: 0.5
        )
        #expect(trajectoryEvent.centerTimeSeconds == 4.0)
    }

    /// Single-map Topography and Continuous-scan events stamp `beginTimeSeconds`
    /// as the true *onset* — `centerTimeSeconds` must add half the event's own
    /// (possibly variable) duration to find the middle, or a cleaning window
    /// centered on it lands near the artifact's leading edge instead, which is
    /// what motivated this fix (reported as a polarity-looking mismatch on a
    /// long, variable-duration Continuous-scan artifact).
    @Test func centerTimeSecondsAddsHalfDurationForOnsetTaggedSources() {
        let topographyEvent = MFFEvent(
            id: "p", code: "EYEM", beginTimeSeconds: 10.0, rawBeginTime: "10.0",
            sourceFile: "Topography 80%", durationSeconds: 0.2
        )
        #expect(abs(topographyEvent.centerTimeSeconds - 10.1) < 1e-9)

        let continuousEvent = MFFEvent(
            id: "c", code: "EYEM", beginTimeSeconds: 20.0, rawBeginTime: "20.0",
            sourceFile: "Continuous 80%", durationSeconds: 1.2
        )
        #expect(abs(continuousEvent.centerTimeSeconds - 20.6) < 1e-9)
    }

    @Test func obsVarianceReportNilWhenNoEventsFallInRange() {
        let template = SyntheticSignal.bump(width: windowSamples)
        // Event far beyond the signal's duration.
        let events = [MFFEvent(id: "far", code: "BLINK", beginTimeSeconds: 100, rawBeginTime: "100", sourceFile: "test")]
        let artifact = makeArtifact(events: events, template: template, method: .obs)
        let channel: [Float] = (0..<500).map { _ in 0 }
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let report = ArtifactCleaner.obsVarianceReport(for: artifact, in: signal)
        #expect(report == nil)
    }
}
