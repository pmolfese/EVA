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
//  Coverage for the compatibility pre-flight (TODO.md Priority 1): a step
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
