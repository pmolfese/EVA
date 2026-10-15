//
//  ReplayCompatibilityTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Coverage for the compatibility pre-flight (ROADMAP.md (completed batch suite)): a step
//  captured on one file must be flagged, not silently no-op'd or crash, when
//  it doesn't fit a different target file.
//

import Testing
import Foundation
@testable import EVA

struct ReplayCompatibilityTests {

    private func signal(events: [MFFEvent] = [], numberOfChannels: Int = 32) -> MFFSignalData {
        MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/synthetic.bin"),
            signalType: "EEG",
            numberOfChannels: numberOfChannels,
            samplingRate: 250,
            duration: 10,
            recordingStartTime: nil,
            events: events,
            data: Array(repeating: [Float](repeating: 0, count: 2500), count: numberOfChannels)
        )
    }

    private func event(_ code: String, at time: Double = 0) -> MFFEvent {
        MFFEvent(id: "\(code)-\(time)", code: code, beginTimeSeconds: time, rawBeginTime: "\(time)", sourceFile: "test")
    }

    @Test func gradientFlagsMissingTRMarkers() {
        let step = EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["trMarkerCode": "TREV"])
        let flag = ReplayCompatibility.check(step, against: signal())
        #expect(flag == .missingTRMarkers(code: "TREV", found: 0))
    }

    @Test func gradientFlagsTooFewTRMarkers() {
        let step = EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["trMarkerCode": "TREV"])
        let sig = signal(events: [event("TREV", at: 1)])
        #expect(ReplayCompatibility.check(step, against: sig) == .missingTRMarkers(code: "TREV", found: 1))
    }

    @Test func gradientPassesWithEnoughTRMarkers() {
        let step = EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["trMarkerCode": "TREV"])
        let sig = signal(events: [event("TREV", at: 1), event("TREV", at: 2), event("TREV", at: 3)])
        #expect(ReplayCompatibility.check(step, against: sig) == nil)
    }

    @Test func gradientDefaultsToTREVWhenCodeParamMissing() {
        let step = EVAProcessingStep(operation: .mriGradientCorrection, parameters: [:])
        let sig = signal(events: [event("TREV", at: 1), event("TREV", at: 2)])
        #expect(ReplayCompatibility.check(step, against: sig) == nil)
    }

    @Test func thresholdFlagsOutOfRangeChannelOverride() {
        var config = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        config.channelOverride = [5, 40]
        let step = EVAProcessingStep(
            operation: .thresholdArtifactDetection,
            parameters: config.flatParameters(prefix: "blink")
        )
        let flag = ReplayCompatibility.check(step, against: signal(numberOfChannels: 32))
        guard case .channelIndicesOutOfRange(_, let indices, let channelCount) = flag else {
            Issue.record("expected .channelIndicesOutOfRange, got \(String(describing: flag))")
            return
        }
        #expect(indices == [40])
        #expect(channelCount == 32)
    }

    @Test func thresholdPassesWithInRangeChannelOverride() {
        var config = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        config.channelOverride = [5, 10]
        let step = EVAProcessingStep(
            operation: .thresholdArtifactDetection,
            parameters: config.flatParameters(prefix: "blink")
        )
        #expect(ReplayCompatibility.check(step, against: signal(numberOfChannels: 32)) == nil)
    }

    @Test func segmentFlagsMissingEventCodes() {
        let step = EVAProcessingStep(operation: .segment, parameters: ["eventCodes": "TAR,STD"])
        let sig = signal(events: [event("OTHER")])
        #expect(ReplayCompatibility.check(step, against: sig) == .missingEventCodes(["STD", "TAR"]))
    }

    @Test func segmentPassesWhenAtLeastOneCodeMatches() {
        let step = EVAProcessingStep(operation: .segment, parameters: ["eventCodes": "TAR,STD"])
        let sig = signal(events: [event("TAR")])
        #expect(ReplayCompatibility.check(step, against: sig) == nil)
    }

    @Test func filterHasNoCompatibilityOpinion() {
        let step = EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"])
        #expect(ReplayCompatibility.check(step, against: signal()) == nil)
    }

    @Test func lightTargetMatchesLoadedSignalCompatibility() {
        let sig = signal(events: [event("TREV"), event("TAR")], numberOfChannels: 32)
        let target = ReplayCompatibilityTarget(signal: sig)
        let steps = [
            EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["trMarkerCode": "TREV"]),
            EVAProcessingStep(operation: .segment, parameters: ["eventCodes": "STD,TAR"]),
            EVAProcessingStep(operation: .bcgCorrection, parameters: ["beatEventCode": "R128"]),
            EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"])
        ]

        for step in steps {
            #expect(
                ReplayCompatibility.check(step, against: target)
                    == ReplayCompatibility.check(step, against: sig)
            )
        }
    }

    @Test func metadataInspectionMatchesFullSignalWithoutReadingSamplesIntoResult() throws {
        let url = Fixtures.url("example_3.mff")
        let reader = MFFReader()
        let metadata = try reader.inspectSignalMetadata(from: url)
        let signal = try reader.loadSignal(from: url)

        #expect(metadata.signalURL == signal.signalURL)
        #expect(metadata.signalType == signal.signalType)
        #expect(metadata.numberOfChannels == signal.numberOfChannels)
        #expect(metadata.samplingRate == signal.samplingRate)
        #expect(metadata.events == signal.events)
    }

    @Test func preflightInspectorReportsTheFlaggedStep() throws {
        let url = Fixtures.url("example_1.mff")
        let step = EVAProcessingStep(
            operation: .mriGradientCorrection,
            parameters: ["trMarkerCode": "A_CODE_THAT_IS_NOT_PRESENT"]
        )

        let result = BatchPreflightInspector.inspect(url: url, steps: [step])

        #expect(result.inspectionError == nil)
        #expect(result.numberOfChannels != nil)
        #expect(result.samplingRate != nil)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.stepIndex == 0)
        #expect(result.issues.first?.operation == .mriGradientCorrection)
    }

    @Test func preflightStateRejectsStaleAndRemovedFileResults() {
        let first = URL(fileURLWithPath: "/tmp/first.mff")
        let second = URL(fileURLWithPath: "/tmp/second.mff")
        let result = { (url: URL) in
            BatchPreflightResult(
                url: url,
                numberOfChannels: 32,
                samplingRate: 250,
                eventCodes: [],
                issues: [],
                inspectionError: nil
            )
        }

        var state = BatchPreflightState()
        let staleRevision = state.begin(files: [first, second])
        let currentRevision = state.begin(files: [second])

        let rejectedStale = state.accept([result(first), result(second)], revision: staleRevision)
        #expect(!rejectedStale)
        #expect(state.results.isEmpty)
        #expect(state.pendingFiles == [second])

        let acceptedCurrent = state.accept([result(first), result(second)], revision: currentRevision)
        #expect(acceptedCurrent)
        #expect(Set(state.results.keys) == [second])
        #expect(state.pendingFiles.isEmpty)
    }

    // MARK: - PB-1 Phase B decision policy

    @Test func skipDecisionPolicyKeepsSupportedPCASAndDropsItOnlyForMissingEvidence() {
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(
            operation: .bcgCorrection,
            parameters: ["beatEventCode": "R128"]
        ))
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))

        let supported = BatchDecisionPolicy.apply(
            to: script,
            availability: ReplayPayloadAvailability(
                hasElectrodeGeometry: true,
                beatEventCodes: ["R128"]
            ),
            enabled: true
        )
        #expect(supported.drops.isEmpty)
        #expect(supported.script.steps.map(\.operation) == [.bcgCorrection, .filter])

        let unsupported = BatchDecisionPolicy.apply(
            to: script,
            availability: ReplayPayloadAvailability(),
            enabled: true
        )
        #expect(unsupported.script.steps.map(\.operation) == [.filter])
        #expect(unsupported.drops.count == 1)
        #expect(unsupported.drops[0].stepIndex == 0)
        #expect(unsupported.drops[0].operation == .bcgCorrection)
        #expect(unsupported.drops[0].reason.contains("electrode coordinates"))
        #expect(unsupported.drops[0].reason.contains("beat events named R128"))
        #expect(unsupported.drops[0].auditLogLine ==
            "dropped bcgCorrection: this recording is missing electrode coordinates and beat events named R128 (skip-decisions policy)")
    }

    @Test func skipDecisionPolicyIsIdentityWhenDisabled() {
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .icaClean))

        let result = BatchDecisionPolicy.apply(
            to: script, availability: .none, enabled: false
        )

        #expect(result.drops.isEmpty)
        #expect(result.script.steps == script.steps)
    }

    @Test func skipDecisionPolicyExemptsChannelAndTrialDecisions() {
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .markBad, parameters: ["channels": "1,2"]))
        script.append(EVAProcessingStep(operation: .interpolateChannels, parameters: ["channels": "3"]))
        script.append(EVAProcessingStep(operation: .trialExclusion))

        let result = BatchDecisionPolicy.apply(
            to: script, availability: .none, enabled: true
        )

        #expect(result.drops.isEmpty)
        #expect(result.script.steps == script.steps)
    }

    @MainActor
    @Test func windowedBatchUsesTheSamePerFileDropAndAuditRule() {
        let step = EVAProcessingStep(
            operation: .bcgCorrection,
            parameters: ["beatEventCode": "R128"]
        )
        var script = EVAProcessingScript()
        script.append(step)
        let batch = BatchController()
        batch.start(
            files: [URL(fileURLWithPath: "/tmp/windowed-policy.mff")],
            script: script,
            sourceName: "src",
            steps: [.init(
                id: 0, step: step, kind: .decision,
                included: true, pauseToReview: false, compatibilityFlag: nil
            )],
            mode: .fullAuto,
            outputFolder: URL(fileURLWithPath: "/tmp/out"),
            skipUnsupportedDecisions: true
        )
        defer { batch.stop() }

        let replay = ReplayController()
        let target = signal(events: [event("R128", at: 1)])
        replay.configure(
            fromBatch: batch,
            script: script,
            signal: target,
            availability: ReplayPayloadAvailability(beatEventCodes: ["R128"])
        )
        #expect(replay.plannedActions().isEmpty)
        #expect(replay.batchPolicyAuditLogLines == [
            "dropped bcgCorrection: this recording is missing electrode coordinates (skip-decisions policy)"
        ])

        replay.configure(
            fromBatch: batch,
            script: script,
            signal: target,
            availability: ReplayPayloadAvailability(
                hasElectrodeGeometry: true,
                beatEventCodes: ["R128"]
            )
        )
        #expect(replay.plannedActions().map(\.operation) == [.bcgCorrection])
        #expect(replay.batchPolicyAuditLogLines.isEmpty)
    }

    // MARK: - ReplayController integration

    @MainActor
    @Test func configureAutoExcludesIncompatibleStepAndSurfacesFlag() {
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["trMarkerCode": "TREV"]))
        script.append(EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1.0"]))

        let c = ReplayController()
        c.configure(script: script, sourceName: "src", signal: signal()) // no TREV events

        let gradientConfig = c.steps.first { $0.step.operation == .mriGradientCorrection }
        #expect(gradientConfig?.included == false)
        #expect(gradientConfig?.compatibilityFlag != nil)

        let filterConfig = c.steps.first { $0.step.operation == .filter }
        #expect(filterConfig?.included == true)
        #expect(filterConfig?.compatibilityFlag == nil)

        // The incompatible step must not appear in what actually runs.
        #expect(!c.plannedActions().map(\.operation).contains(.mriGradientCorrection))
    }

    @MainActor
    @Test func configureWithNoSignalSkipsPreflight() {
        var script = EVAProcessingScript()
        script.append(EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["trMarkerCode": "TREV"]))
        let c = ReplayController()
        c.configure(script: script, sourceName: "src") // no signal given
        #expect(c.steps.first?.compatibilityFlag == nil)
        #expect(c.steps.first?.included == true) // falls back to kind-based default
    }
}
