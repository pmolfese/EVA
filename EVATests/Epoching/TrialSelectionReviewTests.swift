//
//  TrialSelectionReviewTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ROADMAP TW-5 step 2: the operator's overrides on top of the criteria.
//
//  The interesting cases are all about what an override *means* once the
//  criteria have moved underneath it. Overrides are never pruned — a slider drag
//  must not silently destroy a decision — so every one of them has to keep
//  answering correctly against a proposal that no longer looks like the one it
//  was made against.
//

import Testing
import Foundation
@testable import EVA

struct TrialSelectionReviewTests {

    private func proposal(_ index: Int, _ reasons: [String] = ["r < 0.30"]) -> TrialSelectionAnalyzer.Exclusion {
        TrialSelectionAnalyzer.Exclusion(trialIndex: index, reasons: reasons)
    }

    private func reviewed(
        _ proposals: [TrialSelectionAnalyzer.Exclusion],
        restored: Set<Int> = [],
        manual: Set<Int> = []
    ) -> [TrialSelectionAnalyzer.Exclusion] {
        TrialSelectionAnalyzer.reviewed(
            proposals: proposals,
            review: TrialSelectionAnalyzer.Review(restored: restored, manual: manual)
        )
    }

    // MARK: - Precedence

    @Test func withNoOverridesTheProposalsPassThroughUnchanged() {
        let rows = reviewed([proposal(1), proposal(4)])
        #expect(rows.map(\.trialIndex) == [1, 4])
        #expect(rows.allSatisfy { $0.origin == .rule })
        #expect(rows.allSatisfy { $0.isExcluded })
    }

    /// A restored trial stays listed. Dropping it from the list would hide the
    /// fact that the rule was overruled — and leave no way to change your mind.
    @Test func aRestoredTrialIsListedButExcludesNothing() {
        let rows = reviewed([proposal(1), proposal(4)], restored: [1])
        let restored = rows.first { $0.trialIndex == 1 }

        #expect(restored?.origin == .restored)
        #expect(restored?.isExcluded == false)
        #expect(rows.first { $0.trialIndex == 4 }?.isExcluded == true)
        #expect(rows.count == 2, "a restoration must not remove the row")
    }

    /// It also keeps the rule's reasons, which are the only account of why it
    /// was flagged in the first place.
    @Test func aRestoredTrialKeepsTheReasonItWasFlaggedFor() {
        let rows = reviewed([proposal(1, ["β < 0.40"])], restored: [1])
        #expect(rows.first?.reasons == ["β < 0.40"])
    }

    @Test func aHandExcludedTrialIsListedAsManual() {
        let rows = reviewed([proposal(1)], manual: [7])
        let manual = rows.first { $0.trialIndex == 7 }

        #expect(manual?.origin == .manual)
        #expect(manual?.isExcluded == true)
        #expect(rows.map(\.trialIndex) == [1, 7], "rows stay in trial order")
    }

    /// The case that decides whether the record credits the operator with a
    /// decision the rule now makes on its own. Once the criteria catch up with a
    /// hand-excluded trial, it is the rule's call.
    @Test func aHandExcludedTrialTheRuleCatchesUpWithBecomesARuleExclusion() {
        let rows = reviewed([proposal(7)], manual: [7])
        #expect(rows.count == 1)
        #expect(rows.first?.origin == .rule)
        #expect(rows.first?.reasons == ["r < 0.30"], "the rule's reason replaces 'by operator'")
    }

    /// …and the override survives underneath, so loosening the threshold again
    /// returns the trial to a hand exclusion rather than losing it.
    @Test func theManualOverrideSurvivesTheRuleCatchingUpAndBackOff() {
        let review = TrialSelectionAnalyzer.Review(manual: [7])
        let whileFlagged = TrialSelectionAnalyzer.reviewed(proposals: [proposal(7)], review: review)
        #expect(whileFlagged.first?.origin == .rule)

        let afterLoosening = TrialSelectionAnalyzer.reviewed(proposals: [], review: review)
        #expect(afterLoosening.first?.origin == .manual)
        #expect(afterLoosening.first?.isExcluded == true)
    }

    /// A restoration of a trial nothing flags undoes nothing, so there is
    /// nothing to show — but it must not resurrect the trial as an exclusion.
    @Test func aRestorationOfAnUnflaggedTrialDisappearsQuietly() {
        let rows = reviewed([proposal(1)], restored: [9])
        #expect(rows.map(\.trialIndex) == [1])
    }

    /// Restoring wins over a hand exclusion of the same trial: it is the only
    /// override that can contradict the rule, so it is the only one that gets to.
    @Test func restoringBeatsAHandExclusionOfTheSameTrial() {
        let rows = reviewed([proposal(3)], restored: [3], manual: [3])
        #expect(rows.first?.origin == .restored)
        #expect(rows.first?.isExcluded == false)
    }

    @Test func theExcludedCountIgnoresRestoredRows() {
        let rows = reviewed([proposal(1), proposal(2), proposal(3)], restored: [2], manual: [8])
        #expect(rows.count == 4)
        #expect(rows.filter(\.isExcluded).count == 3)
    }

    // MARK: - Toggle semantics on the view model

    @MainActor
    private func viewModel(category: String = "LC++", proposed: Set<Int> = []) -> SingleTrialAnalysisViewModel {
        let vm = SingleTrialAnalysisViewModel(store: RecordingStore())
        vm.selectedCategory = category
        vm.ruleProposedTrials = proposed
        return vm
    }

    @MainActor
    @Test func uncheckingARuleFlaggedTrialRestoresIt() {
        let vm = viewModel(proposed: [4])
        vm.setTrialExcluded(false, trialIndex: 4)

        #expect(vm.selectionReview.restored == [4])
        #expect(vm.selectionReview.manual.isEmpty)
    }

    @MainActor
    @Test func checkingATrialTheRuleIgnoredExcludesItByHand() {
        let vm = viewModel(proposed: [4])
        vm.setTrialExcluded(true, trialIndex: 9)

        #expect(vm.selectionReview.manual == [9])
        #expect(vm.selectionReview.restored.isEmpty)
    }

    /// Unchecking a hand-excluded trial forgets the override rather than
    /// recording a restoration of a rule that never flagged it.
    @Test @MainActor func uncheckingAHandExcludedTrialSimplyForgetsIt() {
        let vm = viewModel(proposed: [4])
        vm.setTrialExcluded(true, trialIndex: 9)
        vm.setTrialExcluded(false, trialIndex: 9)

        #expect(vm.selectionReview.manual.isEmpty)
        #expect(vm.selectionReview.restored.isEmpty, "the rule never flagged #9, so there is nothing to restore")
    }

    @MainActor
    @Test func recheckingARestoredTrialReturnsItToTheRule() {
        let vm = viewModel(proposed: [4])
        vm.setTrialExcluded(false, trialIndex: 4)
        vm.setTrialExcluded(true, trialIndex: 4)

        #expect(vm.selectionReview.isEmpty, "back to the rule's own decision, not a manual duplicate of it")
    }

    /// Switching the category picker must not carry `LC++`'s restored trial #4
    /// onto `RC++`'s trial #4, which is a different trial entirely.
    @MainActor
    @Test func overridesAreHeldPerCategory() {
        let vm = viewModel(category: "LC++", proposed: [4])
        vm.setTrialExcluded(false, trialIndex: 4)

        vm.selectedCategory = "RC++"
        #expect(vm.selectionReview.isEmpty)

        vm.selectedCategory = "LC++"
        #expect(vm.selectionReview.restored == [4])
    }

    @MainActor
    @Test func clearingReturnsToWhatTheCriteriaAlonePropose() {
        let vm = viewModel(proposed: [4])
        vm.setTrialExcluded(false, trialIndex: 4)
        vm.setTrialExcluded(true, trialIndex: 9)
        #expect(!vm.selectionReview.isEmpty)

        vm.clearSelectionReview()
        #expect(vm.selectionReview.isEmpty)
        #expect(vm.selectionReviews["LC++"] == nil, "an empty review is removed, not stored")
    }

    /// With no category under review there is nothing an override could refer
    /// to, so the toggle must be inert rather than writing under a nil key.
    @MainActor
    @Test func togglingWithNoCategorySelectedDoesNothing() {
        let vm = SingleTrialAnalysisViewModel(store: RecordingStore())
        vm.selectedCategory = nil
        vm.setTrialExcluded(true, trialIndex: 3)

        #expect(vm.selectionReviews.isEmpty)
    }
}
