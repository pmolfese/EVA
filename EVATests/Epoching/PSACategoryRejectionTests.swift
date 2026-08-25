//
//  PSACategoryRejectionTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Per-category drop tracking during segmentation. An MFF stores only the
//  segments that survived, so unless PSABuild records what it discarded, the
//  retention story is lost the moment the package is written.
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct PSACategoryRejectionTests {

    private func makeCore() -> ProcessingCore {
        let store = RecordingStore()
        return ProcessingCore(
            store: store,
            filter: FilterViewModel(store: store),
            gradient: GradientViewModel(store: store),
            ica: ICAViewModel(store: store),
            artifactVM: ArtifactViewModel(store: store),
            epoching: EpochingViewModel(store: store),
            wavelet: WaveletReductionViewModel(store: store),
            template: ArtifactTemplateViewModel(store: store),
            segHealth: SegmentHealthViewModel(store: store)
        )
    }

    /// `nEvents` triggers on one channel, evenly spaced, plus one trigger placed
    /// deliberately at the very end so its post-stimulus window runs off the end
    /// of the recording.
    private func signal(
        spacing: Int = 1000,
        nEvents: Int = 6,
        samplingRate: Double = 500,
        trailingOutOfBounds: Bool = false
    ) -> MFFSignalData {
        let sampleCount = spacing * (nEvents + 1)
        var channel = [Float](repeating: 0, count: sampleCount)
        var state: UInt64 = 99
        for i in channel.indices {
            state = state &* 6364136223846793005 &+ 1
            channel[i] = Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
        }

        var events = (1 ... nEvents).map { index in
            MFFEvent(
                id: "stim\(index)",
                code: "stim",
                beginTimeSeconds: Double(index * spacing) / samplingRate,
                rawBeginTime: "\(index * spacing)",
                sourceFile: "test"
            )
        }
        if trailingOutOfBounds {
            events.append(
                MFFEvent(
                    id: "stim-edge",
                    code: "stim",
                    beginTimeSeconds: Double(sampleCount - 2) / samplingRate,
                    rawBeginTime: "\(sampleCount - 2)",
                    sourceFile: "test"
                )
            )
        }

        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/psa-rejection.bin"),
            signalType: "EEG",
            numberOfChannels: 1,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: events,
            data: [channel],
            channelNames: ["E1"]
        )
    }

    private func segmentScript(extra: [String: String] = [:]) -> EVAProcessingScript {
        var parameters = [
            "eventCodes": "stim",
            "preStimulusMs": "40",
            "postStimulusMs": "120",
            "average": "false",
            "interpolateBadChannelsPerEpoch": "false"
        ]
        parameters.merge(extra) { _, new in new }

        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .segment, parameters: parameters))
        return script
    }

    @Test func everyAcceptedEpochIsCountedAgainstItsCategory() async throws {
        let core = makeCore()
        _ = await core.applyAutoSteps(segmentScript(), to: signal(nEvents: 6))

        let summary = core.epoching.psaExclusionSummary
        let tally = try #require(summary.perCategory["stim"])
        #expect(tally.candidates == 6)
        #expect(tally.accepted == 6)
        #expect(tally.excluded == 0)
        #expect(tally.reasons.isEmpty)
    }

    @Test func anEpochRunningOffTheEndIsDebitedToItsCategory() async throws {
        let core = makeCore()
        _ = await core.applyAutoSteps(
            segmentScript(),
            to: signal(nEvents: 6, trailingOutOfBounds: true)
        )

        let summary = core.epoching.psaExclusionSummary
        let tally = try #require(summary.perCategory["stim"])
        #expect(tally.candidates == 7)
        #expect(tally.accepted == 6)
        #expect(tally.excluded == 1)
        #expect(tally.reasons["Out of bounds"] == 1)

        // The per-category books agree with the global ones for a single
        // category, where no event can be double-counted.
        #expect(summary.candidateEvents == 7)
        #expect(summary.categoriesOverlap == false)
    }

    @Test func tallesBecomeTheCategoryRejectionsEvaXMLWrites() async throws {
        let core = makeCore()
        _ = await core.applyAutoSteps(
            segmentScript(),
            to: signal(nEvents: 6, trailingOutOfBounds: true)
        )

        let rejections = core.epoching.psaExclusionSummary.categoryRejections
        let stim = try #require(rejections.first { $0.category == "stim" })
        #expect(stim.total == 7)
        #expect(stim.included == 6)
        #expect(stim.excluded == 1)
        #expect(stim.reasons["Out of bounds"] == 1)
    }

    @Test func rejectionsSurviveAWriteAndReadOfEvaXML() throws {
        // The record has to make it through the file, since that is the whole
        // point -- a reader coming back to this package later has nothing else
        // to go on.
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(
            operation: .segment,
            parameters: ["average": "false"],
            rejections: [
                CategoryRejection(
                    category: "correct",
                    total: 100,
                    included: 62,
                    reasons: ["Eye Blink": 30, "Too many bad channels": 8]
                )
            ]
        ))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("psa-rejection-\(UUID().uuidString).mff")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try EVAProcessingScriptXML.write(script, toPackage: directory)
        let reloaded = try #require(EVAProcessingScriptXML.read(fromPackage: directory))

        let step = try #require(reloaded.steps.first { $0.operation == .segment })
        let rejection = try #require(step.rejections.first)
        #expect(rejection.category == "correct")
        #expect(rejection.total == 100)
        #expect(rejection.included == 62)
        #expect(rejection.reasons["Eye Blink"] == 30)
        #expect(rejection.reasons["Too many bad channels"] == 8)
    }

    @Test func aPooledGroupDebitsTheDropToBothTheCodeAndTheGroup() async throws {
        // A category group pools codes that are themselves selected categories,
        // so every event feeds at least two categories. One dropped event is
        // therefore debited twice, and the per-category candidates sum past the
        // global candidate count. That is correct, not a bug -- the global
        // counters count events, the per-category ones count contributions.
        let core = makeCore()
        _ = await core.applyAutoSteps(
            segmentScript(extra: ["categoryGroup.pooled": "stim"]),
            to: signal(nEvents: 6, trailingOutOfBounds: true)
        )

        let summary = core.epoching.psaExclusionSummary
        let own = try #require(summary.perCategory["stim"])
        let pooled = try #require(summary.perCategory["pooled"])

        #expect(own.candidates == 7)
        #expect(pooled.candidates == 7)
        #expect(own.accepted == 6)
        #expect(pooled.accepted == 6)
        #expect(own.reasons["Out of bounds"] == 1)
        #expect(pooled.reasons["Out of bounds"] == 1)

        // 14 contributions from 7 events.
        #expect(summary.candidateEvents == 7)
        #expect(summary.categoriesOverlap)
    }

    @Test func summaryStartsEmptyForPackagesSegmentedBeforeThisExisted() {
        // Older exports carry no per-category record at all; the absence has to
        // be distinguishable from "nothing was rejected".
        let summary = PSAExclusionSummary()
        #expect(summary.perCategory.isEmpty)
        #expect(summary.categoryRejections.isEmpty)
        #expect(summary.categoriesOverlap == false)
    }
}
