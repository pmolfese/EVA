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

    @Test func obsLeavesExcludedInterpolatedTargetUntouched() {
        let template = SyntheticSignal.bump(width: windowSamples)
        let centers = [100, 300, 500]
        let target = makeSignal(template: template, centers: centers, scales: [2, 2, 2], sampleCount: 650)
        let donor = makeSignal(template: template, centers: centers, scales: [1.5, 1.5, 1.5], sampleCount: 650)
        let events = makeEvents(centers: centers)
        var artifact = makeArtifact(events: events, template: template, method: .obs)
        artifact.obsPCAComponentCount = 1
        artifact.obsEdgeTaperSeconds = 0
        let signal = SyntheticSignal.make([target, donor], samplingRate: samplingRate)

        let (cleaned, summaries) = ArtifactCleaner.cleanedSignal(
            from: signal,
            artifacts: [artifact],
            excluding: [0]
        )

        #expect(cleaned.data[0] == target)
        #expect(summaries.first?.channelCount == 1)
        #expect(windowEnergy(cleaned.data[1], center: centers[1]) < windowEnergy(donor, center: centers[1]))
    }

    /// MAS now applies the same edge-taper + local-baseline mechanism as OBS
    /// (default on) before subtracting its local template — verifies that
    /// addition didn't break MAS's core job of substantially reducing a
    /// repeated planted artifact.
    @Test func masWithDefaultTaperAndBaselineStillReducesArtifact() {
        let template = SyntheticSignal.bump(width: windowSamples)
        let centers = [100, 250, 400, 550, 700]
        let scales: [Float] = [2.0, 1.8, 2.2, 1.9, 2.1]
        let sampleCount = 1000

        let channel = makeSignal(template: template, centers: centers, scales: scales, sampleCount: sampleCount)
        let events = makeEvents(centers: centers)
        let artifact = makeArtifact(events: events, template: template, method: .mas)
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let (cleaned, summaries) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])

        #expect(summaries.count == 1)
        #expect(summaries[0].method == .mas)

        for center in centers {
            let before = windowEnergy(channel, center: center)
            let after = windowEnergy(cleaned.data[0], center: center)
            #expect(after < before * 0.3, "MAS (with taper + baseline preservation) left too much artifact energy at \(center)")
        }
    }

    @Test func amriBCGPreprocessingIsIgnoredForNonBCGArtifacts() {
        var template = [Float](repeating: 0, count: windowSamples)
        template[windowSamples / 2 + 6] = 1
        let centers = [100, 220, 340, 460, 580]
        let scales: [Float] = [12, 18, 24, 30, 36]
        let sampleCount = 720

        let channel = makeSignal(template: template, centers: centers, scales: scales, sampleCount: sampleCount)
        let events = makeEvents(centers: centers)
        var baselineArtifact = makeArtifact(events: events, template: template, method: .mas)
        baselineArtifact.localTemplatePreservesLocalBaseline = false
        baselineArtifact.localTemplateEdgeTaperSeconds = 0

        var staleFlagArtifact = baselineArtifact
        staleFlagArtifact.localTemplateUsesAMRIPreprocessing = true

        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)
        let (baselineCleaned, _) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [baselineArtifact], excluding: [])
        let (staleFlagCleaned, _) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [staleFlagArtifact], excluding: [])

        #expect(staleFlagArtifact.type != .bcg)
        #expect(staleFlagCleaned.data == baselineCleaned.data)
    }

    @Test func waasDefaultsToAMRIGlobalWeights() {
        var template = [Float](repeating: 0, count: windowSamples)
        template[windowSamples / 2] = 1
        let centers = [100, 220, 340, 460, 580, 700, 820]
        let scales: [Float] = [10, 20, 30, 40, 50, 60, 70]
        let sampleCount = 920
        var channel = [Float](repeating: 0, count: sampleCount)
        for (center, scale) in zip(centers, scales) {
            let start = center - windowSamples / 2
            for sample in 0..<windowSamples {
                channel[start + sample] += scale * template[sample]
            }
        }

        let events = makeEvents(centers: centers)
        var artifact = makeArtifact(events: events, template: template, method: .waas)
        artifact.localTemplateWindowSize = 3
        artifact.waasDecayFactor = 0.9
        artifact.localTemplatePreservesLocalBaseline = false
        artifact.localTemplateEdgeTaperSeconds = 0
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let (cleaned, _) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])

        let weights = scales.indices.map { pow(artifact.waasDecayFactor, Double($0)) }
        let expectedTemplate = zip(scales, weights).reduce(0.0) { $0 + Double($1.0) * $1.1 } / weights.reduce(0, +)
        let centerSample = centers[0]
        #expect(abs(Double(cleaned.data[0][centerSample]) - (Double(scales[0]) - expectedTemplate)) < 1e-4)
    }

    @Test func waasCanUseEVALocalWeightedWindow() {
        var template = [Float](repeating: 0, count: windowSamples)
        template[windowSamples / 2] = 1
        let centers = [100, 220, 340, 460, 580]
        let scales: [Float] = [10, 20, 30, 40, 50]
        let sampleCount = 700
        var channel = [Float](repeating: 0, count: sampleCount)
        for (center, scale) in zip(centers, scales) {
            let start = center - windowSamples / 2
            channel[start + windowSamples / 2] += scale
        }

        let events = makeEvents(centers: centers)
        var artifact = makeArtifact(events: events, template: template, method: .waas)
        artifact.waasUsesAMRIGlobalWeights = false
        artifact.localTemplateWindowSize = 3
        artifact.waasDecayFactor = 0.9
        artifact.localTemplatePreservesLocalBaseline = false
        artifact.localTemplateEdgeTaperSeconds = 0
        let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)

        let (cleaned, _) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])

        // With a half-window of 1 and EVA-local weighting, the first event's
        // only donor is the second event. AMRI global weighting would include
        // all valid events and the current event itself.
        #expect(abs(Double(cleaned.data[0][centers[0]]) - Double(scales[0] - scales[1])) < 1e-4)
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

    /// Verifies the variable-event-duration toggle actually does something:
    /// a single event 3x longer than the artifact's saved average template
    /// should be cleaned much more completely when `usesVariableEventDuration`
    /// is on (the template is resampled to the event's own measured length)
    /// than when it's off (the fixed, short base window only corrects a
    /// small central slice of the long artifact).
    @Test func variableEventDurationSizesCorrectionToEachEventsOwnLength() {
        let baseWidth = windowSamples // matches the saved average template
        let longWidth = baseWidth * 3
        let sampleCount = 2000
        let center = 1000
        let start = center - longWidth / 2

        let baseTemplate = SyntheticSignal.bump(width: baseWidth)
        let longShape = SyntheticSignal.bump(width: longWidth)

        var state: UInt64 = 99
        var channel = (0..<sampleCount).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1
            return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 0.5)
        }
        for k in 0..<longWidth where start + k >= 0 && start + k < sampleCount {
            channel[start + k] += 60 * longShape[k]
        }

        let event = MFFEvent(
            id: "long-event",
            code: "BLINK",
            beginTimeSeconds: Double(center) / samplingRate,
            rawBeginTime: String(format: "%.4f", Double(center) / samplingRate),
            sourceFile: "test",
            durationSeconds: Double(longWidth) / samplingRate
        )
        let average = ArtifactTemplateAverage(
            samplingRate: samplingRate,
            windowSizeSeconds: Double(baseWidth) / samplingRate,
            eventCount: 1,
            selectedChannelIndices: [0],
            allChannelSamples: [baseTemplate],
            channelSummaries: [ArtifactTemplateChannelSummary(channelIndex: 0, peakAbsoluteMicrovolts: 80, rmsMicrovolts: 20)]
        )

        func residualEnergy(usesVariableEventDuration: Bool) -> Double {
            var artifact = DefinedArtifact(
                type: .ocular, name: "Blink", eventCode: "BLINK", events: [event],
                selectedChannelIndices: [0], windowSizeSeconds: Double(baseWidth) / samplingRate,
                average: average, topography: nil, cleaningMethod: .regression
            )
            artifact.usesVariableEventDuration = usesVariableEventDuration
            let signal = SyntheticSignal.make([channel], samplingRate: samplingRate)
            let (cleaned, _) = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])
            let s = max(start, 0)
            let e = min(start + longWidth, cleaned.data[0].count)
            return (s..<e).reduce(0.0) { total, i in total + Double(cleaned.data[0][i] * cleaned.data[0][i]) }
        }

        let fixedResidual = residualEnergy(usesVariableEventDuration: false)
        let variableResidual = residualEnergy(usesVariableEventDuration: true)

        #expect(
            variableResidual < fixedResidual * 0.6,
            "variable-duration cleaning (\(variableResidual)) should remove substantially more of the long artifact than the fixed base window (\(fixedResidual))"
        )
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

    @Test func processingParametersCaptureArtifactCleaningSettings() {
        let template = SyntheticSignal.bump(width: windowSamples)
        let events = [
            MFFEvent(id: "bcg-1", code: "BCG", beginTimeSeconds: 1, rawBeginTime: "1", sourceFile: "test", durationSeconds: 0.20),
            MFFEvent(id: "bcg-2", code: "BCG", beginTimeSeconds: 2.5, rawBeginTime: "2.5", sourceFile: "test")
        ]
        var artifact = makeArtifact(events: events, template: template, method: .waar)
        artifact.type = .bcg
        artifact.obsStrategy = .clustered
        artifact.obsPCAComponentCount = 4
        artifact.obsEdgeTaperSeconds = 0.12
        artifact.localTemplateWindowSize = 31
        artifact.waasDecayFactor = 0.85
        artifact.waasUsesAMRIGlobalWeights = false
        artifact.localTemplateUsesAMRIPreprocessing = true
        artifact.localTemplatePreservesLocalBaseline = false
        artifact.localTemplateEdgeTaperSeconds = 0.07
        artifact.usesVariableEventDuration = true
        artifact.appliedMethod = .waar

        let p = artifact.processingParameters(prefix: "artifact1")

        #expect(p["artifact1.type"] == DefinedArtifactType.bcg.rawValue)
        #expect(p["artifact1.eventOnsetsSeconds"] == "1.000000,2.500000")
        #expect(p["artifact1.eventDurationsSeconds"] == "0.200000,")
        #expect(p["artifact1.cleaningMethod"] == ArtifactCleaningMethod.waar.rawValue)
        #expect(p["artifact1.appliedMethod"] == ArtifactCleaningMethod.waar.rawValue)
        #expect(p["artifact1.obsStrategy"] == ArtifactOBSStrategy.clustered.rawValue)
        #expect(p["artifact1.obsPCAComponentCount"] == "4")
        #expect(p["artifact1.localTemplateWindowSize"] == "31")
        #expect(p["artifact1.waasDecayFactor"] == "0.850000")
        #expect(p["artifact1.waasUsesAMRIGlobalWeights"] == "false")
        #expect(p["artifact1.localTemplateUsesAMRIPreprocessing"] == "true")
        #expect(p["artifact1.localTemplateAMRIPreprocessingEffective"] == "true")
        #expect(p["artifact1.localTemplatePreservesLocalBaseline"] == "false")
        #expect(p["artifact1.localTemplateEdgeTaperSeconds"] == "0.070000")
        #expect(p["artifact1.usesVariableEventDuration"] == "true")
        #expect(p["artifact1.averagePresent"] == "true")
        #expect(p["artifact1.averageSampleCount"] == "\(windowSamples)")
    }
}
