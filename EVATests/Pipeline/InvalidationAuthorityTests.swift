//
//  InvalidationAuthorityTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP RW-1 item 14: `PipelineInvalidation` is the single invalidation
//  authority, and the history-derived alternative REWIND once proposed is closed.
//
//  `PipelineInvalidationTests` pins what the cascade clears. These pin the part
//  that decayed anyway: four call sites re-assembled the base-signal cascade out
//  of the primitives instead of calling it, and every one of them drifted the
//  same way — the caches were cleared, the variance accounts describing those
//  caches were not, so an export after an interactive gradient correction could
//  carry a variance line for cleaning that had just been thrown away.
//
//  Two tests, because the failure has two halves: the ledger has to be part of
//  the cascade, and no second cascade may exist to forget it.
//

import Foundation
import Testing
@testable import EVA

@MainActor
struct InvalidationAuthorityTests {

    private func account(stageName: String) -> CleaningVarianceAccount {
        CleaningVarianceAccount.between(
            original: [[0, 1, 0, -1, 0, 1, 0, -1]],
            cleaned: [[0, 0, 0, 0, 0, 0, 0, 0]],
            samplingRate: 8,
            epochSeconds: CleaningVarianceAccount.defaultEpochSeconds,
            stageName: stageName
        )
    }

    /// The ledger's own documentation calls a stale line "worse than a missing
    /// one: it looks like provenance". This is that rule as a test.
    @Test func baseSignalChangeClearsTheVarianceLinesItInvalidates() {
        let store = RecordingStore()
        let ica = ICAViewModel(store: store)
        let filter = FilterViewModel(store: store)
        let artifactVM = ArtifactViewModel(store: store)
        let template = ArtifactTemplateViewModel(store: store)
        let epoching = EpochingViewModel(store: store)
        let segHealth = SegmentHealthViewModel(store: store)

        store.cleaningVariance.record(account(stageName: "icaClean"))
        store.cleaningVariance.record(account(stageName: "artifactClean"))
        store.cleaningVariance.record(account(stageName: "cwlCorrection"))

        // The premise: all three lines are really there to begin with, so a
        // pass cannot come from an empty ledger.
        #expect(store.cleaningVariance.accounts.count == 3)

        PipelineInvalidation.downstreamOfBaseSignalChange(
            store: store,
            ica: ica,
            filter: filter,
            artifactVM: artifactVM,
            template: template,
            epoching: epoching,
            segHealth: segHealth
        )

        let remaining = store.cleaningVariance.accounts.map(\.stageName)
        // The two cleared stages lose their lines; the stage that *caused* the
        // change keeps the account it just recorded.
        #expect(remaining == ["cwlCorrection"])
    }

    /// ICA runs the cascade for its own output, so its line has to survive it —
    /// otherwise the stage would erase the account it just wrote.
    @Test func icaExemptionKeepsItsOwnVarianceLine() {
        let store = RecordingStore()
        let ica = ICAViewModel(store: store)
        let filter = FilterViewModel(store: store)
        let artifactVM = ArtifactViewModel(store: store)
        let template = ArtifactTemplateViewModel(store: store)
        let epoching = EpochingViewModel(store: store)
        let segHealth = SegmentHealthViewModel(store: store)

        store.cleaningVariance.record(account(stageName: "icaClean"))
        store.cleaningVariance.record(account(stageName: "artifactClean"))

        PipelineInvalidation.downstreamOfBaseSignalChange(
            store: store,
            ica: ica,
            filter: filter,
            artifactVM: artifactVM,
            template: template,
            epoching: epoching,
            segHealth: segHealth,
            clearsICA: false
        )

        #expect(store.cleaningVariance.accounts.map(\.stageName) == ["icaClean"])
    }

    /// Source audit: nothing outside the authority may assemble a base-signal
    /// cascade of its own.
    ///
    /// Clearing the band-pass output *and* the ICA output together is the
    /// signature of that recipe — no single stage legitimately needs both, since
    /// filtering is downstream of ICA. Two files are allowed to do it:
    /// `PipelineInvalidation` defines the cascade, and `WaveformView` tears the
    /// whole recording down in `resetToOriginalData`, which is a teardown rather
    /// than a stage invalidation.
    ///
    /// A behavioural test cannot catch this: a hand-written copy that clears the
    /// same caches passes every cache assertion and still diverges on whatever
    /// the author did not think to copy.
    @Test func noHandAssembledBaseSignalCascades() throws {
        let repository = URL(fileURLWithPath: #filePath)   // EVATests/Pipeline/…
            .deletingLastPathComponent()                    // EVATests/Pipeline
            .deletingLastPathComponent()                    // EVATests
            .deletingLastPathComponent()                    // <repo>
        let sources = repository.appendingPathComponent("EVA")

        let allowed: Set<String> = [
            "PipelineInvalidation.swift",
            "WaveformView.swift",
        ]

        let enumerator = try #require(FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        ))

        var offenders: [String] = []
        var scannedFileCount = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFileCount += 1
            guard !allowed.contains(url.lastPathComponent),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("filter.output = nil"), text.contains("ica.cleanedSignal = nil") {
                offenders.append(url.lastPathComponent)
            }
        }

        // The premise: the scan really did read the sources. A wrong path would
        // otherwise report a clean result forever.
        #expect(scannedFileCount > 100)
        #expect(offenders.isEmpty, "Assemble the cascade in PipelineInvalidation, not in: \(offenders.joined(separator: ", "))")
    }
}
