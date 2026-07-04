//
//  ReplayControllerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Unit coverage for the interactive replay engine: step classification, the pure
//  config→actions reduction, and the async decision gate (resume/skip/cancel and
//  the resume-before-suspend race).
//

import Testing
import Foundation
@testable import EVA

@MainActor
struct ReplayControllerTests {

    private func script(_ ops: [EVAProcessingStep.Operation]) -> EVAProcessingScript {
        var s = EVAProcessingScript()
        for op in ops { s.append(EVAProcessingStep(operation: op)) }
        return s
    }

    @Test func classifiesEveryOperation() {
        #expect(EVAProcessingStep(operation: .filter).replayInteraction == .auto)
        #expect(EVAProcessingStep(operation: .thresholdArtifactDetection).replayInteraction == .auto)
        #expect(EVAProcessingStep(operation: .mriGradientCorrection).replayInteraction == .review)
        #expect(EVAProcessingStep(operation: .icaClean).replayInteraction == .decision)
        #expect(EVAProcessingStep(operation: .artifactClean).replayInteraction == .decision)
        #expect(EVAProcessingStep(operation: .interpolateChannels).replayInteraction == .skip)
        #expect(EVAProcessingStep(operation: .markBad).replayInteraction == .skip)
        #expect(EVAProcessingStep(operation: .waveletReduce).replayInteraction == .auto)
    }

    @Test func fullAutoGatesGradientReviewAndICADecisionOnly() {
        let c = ReplayController()
        c.configure(script: script([.mriGradientCorrection, .filter, .icaClean, .markBad]), sourceName: "A")

        let actions = c.plannedActions()
        #expect(actions.map(\.operation) == [.mriGradientCorrection, .filter, .icaClean]) // markBad dropped
        #expect(actions.first { $0.operation == .mriGradientCorrection }?.gate == .review)
        #expect(actions.first { $0.operation == .filter }?.gate == nil)
        #expect(actions.first { $0.operation == .icaClean }?.gate == .decision)
    }

    @Test func artifactCleanGatesAsDecision() {
        let c = ReplayController()
        c.configure(script: script([.filter, .artifactClean]), sourceName: "A")
        #expect(c.plannedActions().first { $0.operation == .artifactClean }?.gate == .decision)
    }

    @Test func reviewEachGatesAutoSteps() {
        let c = ReplayController()
        c.configure(script: script([.filter]), sourceName: "A")
        c.mode = .reviewEach
        #expect(c.plannedActions().first?.gate == .review)
    }

    @Test func gradientReviewToggleOffDropsItsGate() {
        let c = ReplayController()
        c.configure(script: script([.mriGradientCorrection]), sourceName: "A")
        c.steps[0].pauseToReview = false
        #expect(c.plannedActions().first?.gate == nil)
    }

    @Test func excludedStepIsDropped() {
        let c = ReplayController()
        c.configure(script: script([.filter, .mriGradientCorrection]), sourceName: "A")
        c.steps[0].included = false
        #expect(c.plannedActions().map(\.operation) == [.mriGradientCorrection])
    }

    @Test func resumeBeforeGateIsBuffered() async {
        let c = ReplayController()
        c.resume(.skip) // no waiter yet
        let r = await c.gate(.awaitingReview(index: 0), banner: nil)
        #expect(r == .skip)
    }

    @Test func gateThenResume() async {
        let c = ReplayController()
        let task = Task { await c.gate(.awaitingDecision(index: 1), banner: nil) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        c.resume(.proceed)
        #expect(await task.value == .proceed)
    }

    @Test func doubleResumeIsHarmless() async {
        let c = ReplayController()
        let task = Task { await c.gate(.awaitingReview(index: 0), banner: nil) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        c.resume(.proceed)
        c.resume(.skip) // no waiter; buffered, must not corrupt the resolved gate
        #expect(await task.value == .proceed)
    }

    @Test func cancelResolvesGateWithCancel() async {
        let c = ReplayController()
        let task = Task { await c.gate(.awaitingReview(index: 0), banner: nil) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        c.cancel()
        #expect(await task.value == .cancel)
    }
}
