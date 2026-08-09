//
//  LocalTemplateArtifactCorrectorTests.swift
//  EVATests
//
//  Synthetic tests independently derived from
//  docs/provenance/amri-functional-spec.md.
//

import Foundation
import Testing
@testable import EVA

struct LocalTemplateArtifactCorrectorTests {

    private let twoSampleWindow = LocalTemplateSampleWindow(startOffset: 0, endOffset: 2)

    private func events(
        _ centers: [Int],
        window: LocalTemplateSampleWindow? = nil
    ) -> [LocalTemplateSampleEvent] {
        centers.map {
            LocalTemplateSampleEvent(centerSample: $0, window: window ?? twoSampleWindow)
        }
    }

    private func configuration(
        before: Int = 1,
        after: Int = 1,
        reducer: LocalTemplateReducer = .mean,
        fit: LocalTemplateFit = .unscaled
    ) -> LocalTemplateConfiguration {
        var configuration = LocalTemplateConfiguration()
        configuration.donorsBefore = before
        configuration.donorsAfter = after
        configuration.reducer = reducer
        configuration.fit = fit
        return configuration
    }

    @Test func outputShapeIsPreservedAndFinite() throws {
        let channels: [[Float]] = [
            [1.0, 2, 1, 2, 1, 2],
            [-3.0, 4, -3, 4, -3, 4]
        ]
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: channels,
            events: events([0, 2, 4]),
            configuration: configuration()
        )

        #expect(result.cleanedChannels.map(\.count) == channels.map(\.count))
        #expect(result.artifactEstimate.map(\.count) == channels.map(\.count))
        #expect(result.cleanedChannels.flatMap { $0 }.allSatisfy { $0.isFinite })
        #expect(result.artifactEstimate.flatMap { $0 }.allSatisfy { $0.isFinite })
    }

    @Test func meanTemplateRemovesARepeatedArtifact() throws {
        let artifact: [Float] = [1.0, -2, 3, -4]
        let channel = artifact + artifact + artifact + artifact
        let window = LocalTemplateSampleWindow(startOffset: 0, endOffset: artifact.count)
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: events([0, 4, 8, 12], window: window),
            configuration: configuration(before: 1, after: 1, reducer: .mean)
        )

        #expect(result.cleanedChannels[0].allSatisfy { abs($0) < 1e-12 })
        #expect(zip(result.artifactEstimate[0], channel).allSatisfy { abs($0 - $1) < 1e-12 })
    }

    @Test func medianResistsAContaminatedDonor() throws {
        let channel: [Float] = [
            2.0, 4,       // donor 0
            100, 200,     // contaminated donor 1
            8, 16,        // target 2
            2, 4          // donor 3
        ]
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: events([0, 2, 4, 6]),
            configuration: configuration(before: 2, after: 1, reducer: .median)
        )

        #expect(abs(result.artifactEstimate[0][4] - 2) < 1e-12)
        #expect(abs(result.artifactEstimate[0][5] - 4) < 1e-12)
    }

    @Test func exponentialWeightingFavorsTheNearerDonorAndNormalizesConstants() throws {
        let oneSample = LocalTemplateSampleWindow(startOffset: 0, endOffset: 1)
        let channel = [Float](repeating: 0, count: 31)
        var varying = channel
        varying[0] = 0
        varying[10] = 10
        varying[20] = 99

        let weighted = configuration(
            before: 2,
            after: 0,
            reducer: .exponentiallyWeighted(timeConstantSamples: 10)
        )
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [varying],
            events: events([0, 10, 20], window: oneSample),
            configuration: weighted
        )
        #expect(result.artifactEstimate[0][20] > 5)
        #expect(result.artifactEstimate[0][20] < 10)

        var constant = channel
        constant[0] = 7
        constant[10] = 7
        constant[20] = 7
        let normalized = try LocalTemplateArtifactCorrector.correct(
            channels: [constant],
            events: events([0, 10, 20], window: oneSample),
            configuration: weighted
        )
        #expect(abs(normalized.artifactEstimate[0][20] - 7) < 1e-12)
    }

    @Test func leastSquaresRecoversKnownPerChannelScales() throws {
        let channels: [[Float]] = [
            [1.0, 2, 1, 2, 3, 6],
            [2.0, -1, 2, -1, 1, -0.5]
        ]
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: channels,
            events: events([0, 2, 4]),
            configuration: configuration(before: 2, after: 0, reducer: .mean, fit: .leastSquares)
        )

        let scales = try #require(result.eventSummaries[2].scaleFactors)
        #expect(abs(scales[0] - 3) < 1e-12)
        #expect(abs(scales[1] - 0.5) < 1e-12)
        #expect(abs(result.cleanedChannels[0][4]) < 1e-12)
        #expect(abs(result.cleanedChannels[0][5]) < 1e-12)
    }

    @Test func flatTemplateUsesZeroLeastSquaresScale() throws {
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [[0, 0, 0, 0, 4, 8]],
            events: events([0, 2, 4]),
            configuration: configuration(before: 2, after: 0, fit: .leastSquares)
        )

        let scales = try #require(result.eventSummaries[2].scaleFactors)
        #expect(scales == [0])
        #expect(result.cleanedChannels[0][4] == 4)
        #expect(result.cleanedChannels[0][5] == 8)
    }

    @Test func excludedDonorCannotAffectTemplate() throws {
        var config = configuration(before: 2, after: 0)
        config.excludedDonorIndices = [1]
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [[2, 4, 200, 400, 8, 16]],
            events: events([0, 2, 4]),
            configuration: config
        )

        #expect(result.eventSummaries[2].donorIndices == [0])
        #expect(result.artifactEstimate[0][4] == 2)
        #expect(result.artifactEstimate[0][5] == 4)
    }

    @Test func IneligibleTargetIsStillCorrected() throws {
        var sampleEvents = events([0, 2, 4])
        sampleEvents[2].isDonorEligible = false
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [[1, 2, 1, 2, 1, 2]],
            events: sampleEvents,
            configuration: configuration(before: 2, after: 0)
        )

        #expect(result.eventSummaries[2].skippedReason == nil)
        #expect(result.cleanedChannels[0][4] == 0)
        #expect(result.cleanedChannels[0][5] == 0)
    }

    @Test func allDonorsExcludedLeavesTargetUnchangedWithReason() throws {
        var config = configuration(before: 1, after: 1)
        config.excludedDonorIndices = [0, 1, 2]
        let channel: [Float] = [1.0, 2, 3, 4, 5, 6]
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: events([0, 2, 4]),
            configuration: config
        )

        #expect(result.cleanedChannels == [channel])
        #expect(result.eventSummaries.allSatisfy { $0.skippedReason == .insufficientDonors })
    }

    @Test func minimumDistanceRemovesNearbyDonors() throws {
        var config = configuration(before: 2, after: 1)
        config.minimumDonorDistanceSamples = 4
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [[1, 0, 2, 0, 3, 0, 4, 0]],
            events: events([0, 2, 4, 6]),
            configuration: config
        )

        #expect(!result.eventSummaries[2].donorIndices.contains(1))
        #expect(!result.eventSummaries[2].donorIndices.contains(3))
        #expect(result.eventSummaries[2].donorIndices == [0])
    }

    @Test func edgeWindowsAreClippedAndFullyOutsideEventsAreSkipped() throws {
        let clipped = LocalTemplateSampleWindow(startOffset: -2, endOffset: 2)
        let result = try LocalTemplateArtifactCorrector.correct(
            channels: [[1, 2, 3, 4, 5, 6]],
            events: events([0, 4, 20], window: clipped),
            configuration: configuration(before: 1, after: 1)
        )

        #expect(result.eventSummaries[0].skippedReason == nil)
        #expect(result.eventSummaries[2].skippedReason == .outsideRecording)
        #expect(result.cleanedChannels[0].allSatisfy { $0.isFinite })
    }

    @Test func variableDurationEventsUseTheirOwnWindows() throws {
        let timedEvents = [
            LocalTemplateTimedEvent(centerTime: 0.2, duration: 0.2),
            LocalTemplateTimedEvent(centerTime: 0.6, duration: 0.4),
            LocalTemplateTimedEvent(centerTime: 1.2, duration: 0.6)
        ]
        let result = try LocalTemplateArtifactCorrector.correctTimedEvents(
            channels: [Array(repeating: 1.0, count: 20)],
            events: timedEvents,
            samplingRate: 10,
            window: .eventDuration(),
            configuration: configuration()
        )

        #expect(result.eventSummaries.count == 3)
        #expect(result.cleanedChannels[0].allSatisfy { $0.isFinite })
        // The last event spans six samples and has a constant one-valued donor
        // template wherever its donors' shorter windows overlap.
        #expect(result.artifactEstimate[0][12] == 1)
    }

    @Test func gradientLengthUsesMedianUnevenTRInterval() throws {
        let artifact = [1.0, 2, 3, 4]
        var channel = [Float](repeating: 0, count: 18)
        for trigger in [0, 4, 9, 13] {
            for offset in artifact.indices {
                channel[trigger + offset] = Float(artifact[offset])
            }
        }
        let result = try LocalTemplateArtifactCorrector.correctGradient(
            channels: [channel],
            trSamples: [13, 0, 9, 4, 4],
            samplingRate: 100,
            configuration: configuration()
        )

        #expect(result.eventSummaries.count == 4)
        #expect(result.cleanedChannels[0][0..<4].allSatisfy { abs($0) < 1e-12 })
    }

    @Test func tooFewEventsAreReportedOrRejectedWhenLengthCannotBeInferred() throws {
        let explicit = try LocalTemplateArtifactCorrector.correctGradient(
            channels: [[1, 2, 3, 4]],
            trSamples: [0],
            samplingRate: 100,
            epochLengthSamples: 4,
            configuration: configuration()
        )
        #expect(explicit.cleanedChannels == [[1, 2, 3, 4]])
        #expect(explicit.eventSummaries[0].skippedReason == .insufficientDonors)

        #expect(throws: LocalTemplateCorrectionError.cannotInferGradientEpochLength) {
            _ = try LocalTemplateArtifactCorrector.correctGradient(
                channels: [[1, 2, 3, 4]],
                trSamples: [0],
                samplingRate: 100
            )
        }
    }

    @Test func overlappingCorrectionsAreDeterministicAndReversible() throws {
        let overlapping = LocalTemplateSampleWindow(startOffset: -1, endOffset: 2)
        let channel: [Float] = [1.0, 2, 3, 4, 5, 6, 7]
        let sampleEvents = events([1, 3, 5], window: overlapping)
        let config = configuration()
        let first = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: sampleEvents,
            configuration: config
        )
        let second = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: sampleEvents,
            configuration: config
        )

        #expect(first == second)
        for sample in channel.indices {
            #expect(abs(first.cleanedChannels[0][sample] + first.artifactEstimate[0][sample] - channel[sample]) < 1e-12)
        }
    }

    @Test func raisedMinimumCanSkipOrUseAvailable() throws {
        var skip = configuration(before: 2, after: 2)
        skip.minimumDonorCount = 3
        skip.insufficientDonorPolicy = .skipTarget
        let channel: [Float] = [1.0, 2, 1, 2]
        let skipped = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: events([0, 2]),
            configuration: skip
        )
        #expect(skipped.cleanedChannels == [channel])

        skip.insufficientDonorPolicy = .useAvailable
        let corrected = try LocalTemplateArtifactCorrector.correct(
            channels: [channel],
            events: events([0, 2]),
            configuration: skip
        )
        #expect(corrected.cleanedChannels[0].allSatisfy { abs($0) < 1e-12 })
    }

    // MARK: - Minimum donor correlation

    /// Four events on one channel: the target and two donors share a waveform,
    /// the third donor is its inverse. Without a floor the contaminated donor
    /// pulls the template; with one it is dropped.
    private func correlationFixture() -> (channels: [[Float]], events: [LocalTemplateSampleEvent]) {
        let length = 40
        let period = Double(length)
        func shape(_ sign: Double, at start: Int, into channel: inout [Float]) {
            for i in 0..<length {
                channel[start + i] = Float(sign * 10 * sin(2 * .pi * Double(i) / period))
            }
        }
        var channel = [Float](repeating: 0, count: 400)
        // Target at 0, matching donors at 100 and 200, inverted donor at 300.
        shape(1, at: 0, into: &channel)
        shape(1, at: 100, into: &channel)
        shape(1, at: 200, into: &channel)
        shape(-1, at: 300, into: &channel)

        let window = LocalTemplateSampleWindow(startOffset: 0, endOffset: length)
        let events = [0, 100, 200, 300].map {
            LocalTemplateSampleEvent(centerSample: $0, window: window)
        }
        return ([channel], events)
    }

    @Test func donorCorrelationScoresMatchingAndInvertedDonors() throws {
        let (channels, events) = correlationFixture()
        let matching = LocalTemplateArtifactCorrector.donorCorrelation(
            channel: channels[0], target: events[0], donor: events[1]
        )
        let inverted = LocalTemplateArtifactCorrector.donorCorrelation(
            channel: channels[0], target: events[0], donor: events[3]
        )
        #expect(abs(matching - 1) < 1e-9)
        #expect(abs(inverted + 1) < 1e-9)
    }

    @Test func theCorrelationFloorDropsAnUnlikeDonor() throws {
        let (channels, events) = correlationFixture()
        var config = LocalTemplateConfiguration()
        config.donorsBefore = 3
        config.donorsAfter = 3
        config.reducer = .mean

        let unfiltered = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: events, configuration: config
        )
        config.minimumDonorCorrelation = 0.5
        let filtered = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: events, configuration: config
        )

        // The inverted donor is admitted without the floor and rejected with it.
        #expect(unfiltered.eventSummaries[0].donorIndices.contains(3))
        #expect(!filtered.eventSummaries[0].donorIndices.contains(3))
        #expect(filtered.eventSummaries[0].donorIndices == [1, 2])
        #expect(filtered.eventSummaries[0].skippedReason == nil)

        // And the template it produces is the one the matching donors describe,
        // so the target is removed rather than half-removed.
        let residual = (0..<40).map { abs(filtered.cleanedChannels[0][$0]) }.max() ?? 0
        let unfilteredResidual = (0..<40).map { abs(unfiltered.cleanedChannels[0][$0]) }.max() ?? 0
        #expect(residual < 1e-9)
        #expect(unfilteredResidual > residual)
    }

    /// The default must not change anything: this is an added option.
    @Test func noFloorMeansNoChange() throws {
        let (channels, events) = correlationFixture()
        var config = LocalTemplateConfiguration()
        config.donorsBefore = 3
        config.donorsAfter = 3
        #expect(config.minimumDonorCorrelation == nil)

        let a = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: events, configuration: config
        )
        config.minimumDonorCorrelation = -1.0   // admits everything
        let b = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: events, configuration: config
        )
        #expect(a.cleanedChannels == b.cleanedChannels)
        #expect(a.eventSummaries.map(\.donorIndices) == b.eventSummaries.map(\.donorIndices))
    }

    /// A floor nothing can reach leaves the target uncorrected and says why,
    /// rather than subtracting a template that does not describe it.
    @Test func aFloorNothingReachesSkipsTheTargetWithAReason() throws {
        let (channels, events) = correlationFixture()
        var config = LocalTemplateConfiguration()
        config.donorsBefore = 3
        config.donorsAfter = 3
        config.minimumDonorCorrelation = 1.5

        let result = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: events, configuration: config
        )
        #expect(result.eventSummaries.allSatisfy { $0.skippedReason == .noCorrelatedDonors })
        #expect(result.eventSummaries.allSatisfy { $0.donorIndices.isEmpty })
        #expect(result.cleanedChannels == channels)
    }

    /// Donors are scored once on the representative channel, so every channel
    /// corrects with the same donor set. A second channel that disagrees about
    /// similarity must not change the selection.
    @Test func donorSelectionIsSharedAcrossChannels() throws {
        let (single, events) = correlationFixture()
        // A quiet, contradictory second channel: inverted where channel 0 matches.
        let contrarian = single[0].map { -$0 * 0.01 }
        let channels = [single[0], contrarian]

        var config = LocalTemplateConfiguration()
        config.donorsBefore = 3
        config.donorsAfter = 3
        config.minimumDonorCorrelation = 0.5

        let result = try LocalTemplateArtifactCorrector.correct(
            channels: channels, events: events, configuration: config
        )
        // Channel 0 has by far the larger variance, so it is the reference.
        #expect(LocalTemplateArtifactCorrector.representativeChannelIndex(channels) == 0)
        #expect(result.eventSummaries[0].donorIndices == [1, 2])
        // One summary per event, not per channel — the set is shared.
        #expect(result.eventSummaries.count == events.count)
    }
}
