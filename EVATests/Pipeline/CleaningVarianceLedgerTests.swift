//
//  CleaningVarianceLedgerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Testing
import Foundation
@testable import EVA

struct CleaningVarianceLedgerTests {

    private func account(_ stage: String, removed: Double = 0.1) -> CleaningVarianceAccount {
        CleaningVarianceAccount(
            stageName: stage,
            channelIndices: [0, 1],
            globalRemovedFraction: removed,
            removedFractionByChannel: [0: removed, 1: removed / 2],
            undefinedChannels: [],
            removedRMSByChannel: [0: 1, 1: 0.5],
            removedFractionByEpoch: [],
            epochSeconds: nil
        )
    }

    @Test func keepsStageOrder() {
        let ledger = CleaningVarianceLedger()
        ledger.record(account("mriGradientCorrection"))
        ledger.record(account("icaClean"))
        ledger.record(account("waveletReduction"))
        #expect(ledger.accounts.map(\.stageName)
                == ["mriGradientCorrection", "icaClean", "waveletReduction"])
    }

    @Test func rerunSupersedesRatherThanAppends() {
        let ledger = CleaningVarianceLedger()
        ledger.record(account("icaClean", removed: 0.1))
        ledger.record(account("waveletReduction"))
        ledger.record(account("icaClean", removed: 0.4))

        #expect(ledger.accounts.count == 2)
        // The re-run takes the newer position: it is when the stage most
        // recently touched the data.
        #expect(ledger.accounts.map(\.stageName) == ["waveletReduction", "icaClean"])
        #expect(ledger.accounts.last?.globalRemovedFraction == 0.4)
    }

    @Test func clearRemovesOnlyTheNamedStage() {
        let ledger = CleaningVarianceLedger()
        ledger.record(account("icaClean"))
        ledger.record(account("artifactClean"))
        ledger.clear(stageName: "artifactClean")
        #expect(ledger.accounts.map(\.stageName) == ["icaClean"])
        #expect(!ledger.isEmpty)

        ledger.removeAll()
        #expect(ledger.isEmpty)
    }

    // MARK: - Audit line

    @Test func auditLineUsesHouseStyleAndOneBasedChannels() {
        let ledger = CleaningVarianceLedger()
        ledger.record(account("waveletReduction", removed: 0.25))
        let line = ledger.auditLogLines[0]
        #expect(line.hasPrefix("waveletReduction variance: "))
        #expect(line.contains("removed=25.0%"))
        #expect(line.contains("channels=2"))
        // Channel 0 is reported as 1, matching how the audit log names channels.
        #expect(line.contains("worst=1:25.0%,2:12.5%"))
    }

    @Test func auditLineNamesFlatChannels() {
        let flat = CleaningVarianceAccount(
            stageName: "icaClean",
            channelIndices: [0, 1],
            globalRemovedFraction: 0.2,
            removedFractionByChannel: [0: 0.2],
            undefinedChannels: [1],
            removedRMSByChannel: [0: 1, 1: 0],
            removedFractionByEpoch: [],
            epochSeconds: nil
        )
        let ledger = CleaningVarianceLedger()
        ledger.record(flat)
        #expect(ledger.auditLogLines[0].contains("flatUnaccounted=2"))
    }

    @Test func emptyLedgerContributesNoLines() {
        #expect(CleaningVarianceLedger().auditLogLines.isEmpty)
    }
}
