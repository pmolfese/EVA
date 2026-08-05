//
//  OperationProgressTests.swift
//  EVATests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation
import Testing
@testable import EVA

@Suite("Operation progress")
struct OperationProgressTests {
    @Test("Starting activates the first stage")
    func startingActivatesFirstStage() {
        let progress = OperationProgress.started(
            source: "gradient",
            title: "Removing MRI gradient artifact",
            subtitle: "FASTR · Metal GPU",
            phase: "Preparing TR grid",
            stages: ["Preparing", "Correcting EEG", "Finalizing"]
        )

        #expect(progress.fraction == 0)
        #expect(progress.detail == nil)
        #expect(progress.stages.map(\.state) == [.active, .pending, .pending])
    }

    @Test("Updating advances stages and preserves operation identity")
    func updatingAdvancesStages() {
        let started = OperationProgress.started(
            source: "filter",
            title: "Filtering recording",
            subtitle: "EEG and PNS",
            phase: "Preparing filters",
            stages: ["Preparing", "EEG filtering", "PNS filtering", "Finalizing"]
        )

        let updated = started.updating(
            fraction: 0.62,
            phase: "Filtering PNS channels",
            detail: "PNS channels 2 of 4",
            activeStage: 2
        )

        #expect(updated.source == started.source)
        #expect(updated.title == started.title)
        #expect(updated.startedAt == started.startedAt)
        #expect(updated.fraction == 0.62)
        #expect(updated.phase == "Filtering PNS channels")
        #expect(updated.detail == "PNS channels 2 of 4")
        #expect(updated.stages.map(\.state) == [.complete, .complete, .active, .pending])
    }

    @Test("Fractions are clamped to the display range")
    func fractionsAreClamped() {
        let started = OperationProgress.started(
            source: "gradient",
            title: "Removing MRI gradient artifact",
            subtitle: "MAS · CPU",
            phase: "Preparing",
            stages: ["Preparing", "Correcting"]
        )

        let belowRange = started.updating(
            fraction: -0.2,
            phase: "Preparing",
            activeStage: 0
        )
        let aboveRange = started.updating(
            fraction: 1.2,
            phase: "Correcting",
            activeStage: 1
        )

        #expect(belowRange.fraction == 0)
        #expect(aboveRange.fraction == 1)
        #expect(OperationProgress(
            source: "test",
            title: "Test",
            subtitle: "Test",
            phase: "Test",
            detail: nil,
            fraction: 2,
            stages: [],
            startedAt: Date()
        ).clampedFraction == 1)
    }
}
