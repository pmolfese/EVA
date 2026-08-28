//
//  WindowComparisonRegistryTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP RW-1 item 10: which windows are relatable, and — the part the sheet
//  must not get wrong — on what evidence.
//

import Foundation
import Testing
@testable import EVA

@MainActor
struct WindowComparisonRegistryTests {

    private func signal(_ value: Float = 1) -> MFFSignalData {
        SyntheticSignal.make([[value, value, value, value]], samplingRate: 250)
    }

    private func window(
        id: UUID = UUID(),
        group: UUID,
        package: String,
        node: String = "aaaa1111",
        forkedFrom: String? = nil,
        signal: MFFSignalData? = nil
    ) -> ComparableWindow {
        ComparableWindow(
            id: id,
            groupID: group,
            packageName: package,
            packageURL: URL(fileURLWithPath: "/tmp/\(package)"),
            currentNode: node,
            lineageSummary: "raw",
            forkedFromNode: forkedFrom,
            signal: signal ?? self.signal(),
            badChannelCount: 0,
            interpolatedChannelCount: 0,
            segmentHealthMeanGood: nil,
            artifactsAssessed: false
        )
    }

    /// A registry per test: this one is a singleton in the app, and tests that
    /// shared it would depend on each other's leftovers.
    private func makeRegistry() -> WindowComparisonRegistry {
        let registry = WindowComparisonRegistry()
        return registry
    }

    @Test func forkedWindowsAreRelatedAndIndependentOpensAreNot() {
        let registry = makeRegistry()
        let group = UUID()
        let source = window(group: group, package: "subject.mff")
        let fork = window(group: group, package: "subject.mff", node: "bbbb2222", forkedFrom: "aaaa1111")
        let independent = window(group: UUID(), package: "subject.mff")
        let unrelated = window(group: UUID(), package: "other.mff")

        for entry in [source, fork, independent, unrelated] { registry.publish(entry) }

        #expect(registry.relation(source, fork) == .forkedLineage)
        // Same file, no shared history: offered, but never described as one
        // experiment.
        #expect(registry.relation(source, independent) == .sameFileIndependent)
        #expect(registry.relation(source, unrelated) == .differentRecordings)
    }

    /// Ordering is the whole of the UI's advice: the fork is what the operator
    /// almost always means.
    @Test func candidatesAreOfferedBestRelationFirst() {
        let registry = makeRegistry()
        let group = UUID()
        let source = window(group: group, package: "subject.mff")
        let unrelated = window(group: UUID(), package: "other.mff")
        let independent = window(group: UUID(), package: "subject.mff")
        let fork = window(group: group, package: "subject.mff", node: "bbbb2222")

        // Published in the least helpful order on purpose.
        for entry in [source, unrelated, independent, fork] { registry.publish(entry) }

        let candidates = registry.comparisonCandidates(for: source.id)
        #expect(candidates.map(\.relation) == [.forkedLineage, .sameFileIndependent, .differentRecordings])
        #expect(candidates.first?.window.id == fork.id)
        // Never itself.
        #expect(!candidates.contains { $0.window.id == source.id })
    }

    @Test func aWindowWithNoLoadedSignalIsNotOffered() {
        let registry = makeRegistry()
        let group = UUID()
        let source = window(group: group, package: "subject.mff")
        var loading = window(group: group, package: "subject.mff", node: "cccc3333")
        loading.signal = nil

        registry.publish(source)
        registry.publish(loading)
        #expect(registry.comparisonCandidates(for: source.id).isEmpty)
    }

    /// A closed window must disappear: its `MFFRecording` nils its signal on
    /// teardown, and another window's sheet must not be holding one.
    @Test func unregisteringRemovesAWindowFromEveryOffer() {
        let registry = makeRegistry()
        let group = UUID()
        let source = window(group: group, package: "subject.mff")
        let fork = window(group: group, package: "subject.mff", node: "bbbb2222")
        registry.publish(source)
        registry.publish(fork)
        #expect(registry.comparisonCandidates(for: source.id).count == 1)

        registry.unregister(id: fork.id)
        #expect(registry.comparisonCandidates(for: source.id).isEmpty)
        #expect(registry.window(id: fork.id) == nil)
    }

    /// Publishing happens on every signal revision; an unchanged snapshot must
    /// not churn the roster.
    @Test func republishingTheSameSnapshotReplacesRatherThanDuplicates() {
        let registry = makeRegistry()
        let entry = window(group: UUID(), package: "subject.mff")
        registry.publish(entry)
        registry.publish(entry)
        #expect(registry.windows.count == 1)

        var moved = entry
        moved.currentNode = "dddd4444"
        registry.publish(moved)
        #expect(registry.windows.count == 1)
        #expect(registry.window(id: entry.id)?.currentNode == "dddd4444")
    }
}
