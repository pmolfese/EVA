//
//  EventAnchorSettingsTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Preferences ▸ Events rule matching and application.
//
//  The rules decide how a lab's own event markers are read, so the properties
//  worth pinning are the ones a user would be surprised by: a half-typed rule
//  must not capture the whole recording, a specific rule must be able to
//  outrank a catch-all, and applying a rule must never move the sample the file
//  actually recorded.
//

import Testing
import Foundation
@testable import EVA

struct EventAnchorSettingsTests {

    private func event(
        code: String,
        begin: Double = 10,
        duration: Double? = nil,
        sourceFile: String = "study.mff",
        anchor: EventTimeAnchor = .onset
    ) -> MFFEvent {
        MFFEvent(
            id: "\(code)-\(begin)",
            code: code,
            beginTimeSeconds: begin,
            rawBeginTime: "\(begin)",
            sourceFile: sourceFile,
            durationSeconds: duration,
            timeAnchor: anchor
        )
    }

    // MARK: - Matching

    @Test func exactCodeMatchesCaseInsensitively() {
        let rule = EventAnchorRule(codePattern: "blnk", anchor: .peak)
        #expect(rule.matches(event(code: "blnk")))
        #expect(rule.matches(event(code: "BLNK")))
        #expect(!rule.matches(event(code: "blnkx")))
        #expect(!rule.matches(event(code: "stim")))
    }

    @Test func trailingStarMatchesAnySuffix() {
        let rule = EventAnchorRule(codePattern: "stim*", anchor: .center)
        #expect(rule.matches(event(code: "stim1")))
        #expect(rule.matches(event(code: "stimA")))
        #expect(rule.matches(event(code: "stim")))
        #expect(!rule.matches(event(code: "resp1")))
    }

    @Test func bareStarMatchesEverything() {
        let rule = EventAnchorRule(codePattern: "*", anchor: .center)
        #expect(rule.matches(event(code: "anything")))
        #expect(rule.matches(event(code: "")))
    }

    /// A rule being typed is empty for a keystroke or two. Matching everything
    /// in that window would silently re-anchor the whole recording.
    @Test func blankPatternMatchesNothing() {
        #expect(!EventAnchorRule(codePattern: "").matches(event(code: "blnk")))
        #expect(!EventAnchorRule(codePattern: "   ").matches(event(code: "blnk")))
    }

    @Test func disabledRuleMatchesNothing() {
        let rule = EventAnchorRule(isEnabled: false, codePattern: "blnk")
        #expect(!rule.matches(event(code: "blnk")))
    }

    @Test func sourceScopeRestrictsTheRule() {
        let rule = EventAnchorRule(codePattern: "blnk", sourceScope: "study.mff")
        #expect(rule.matches(event(code: "blnk", sourceFile: "study.mff")))
        #expect(!rule.matches(event(code: "blnk", sourceFile: "other.mff")))

        let unscoped = EventAnchorRule(codePattern: "blnk", sourceScope: nil)
        #expect(unscoped.matches(event(code: "blnk", sourceFile: "other.mff")))

        let blankScope = EventAnchorRule(codePattern: "blnk", sourceScope: "  ")
        #expect(blankScope.matches(event(code: "blnk", sourceFile: "other.mff")))
    }

    // MARK: - Precedence

    @Test func firstMatchingRuleWins() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(codePattern: "stim1", anchor: .peak),
            EventAnchorRule(codePattern: "stim*", anchor: .center),
        ])
        #expect(ruleSet.rule(for: event(code: "stim1"))?.anchor == .peak)
        #expect(ruleSet.rule(for: event(code: "stim2"))?.anchor == .center)
    }

    /// Ordering is the user's lever: a catch-all placed first shadows the
    /// specific rule below it, which is why the list is reorderable.
    @Test func aCatchAllPlacedFirstShadowsWhatFollows() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(codePattern: "*", anchor: .center),
            EventAnchorRule(codePattern: "stim1", anchor: .peak),
        ])
        #expect(ruleSet.rule(for: event(code: "stim1"))?.anchor == .center)
    }

    @Test func disabledRulesAreSkippedNotHonoured() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(isEnabled: false, codePattern: "stim*", anchor: .peak),
            EventAnchorRule(codePattern: "stim*", anchor: .center),
        ])
        #expect(ruleSet.rule(for: event(code: "stim1"))?.anchor == .center)
    }

    @Test func anAllDisabledRuleSetIsEmptyAndChangesNothing() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(isEnabled: false, codePattern: "*", anchor: .center),
        ])
        #expect(ruleSet.isEmpty)
        let events = [event(code: "stim1"), event(code: "blnk")]
        #expect(ruleSet.applied(to: events) == events)
    }

    // MARK: - Application

    /// The sample the file recorded is a fact. A rule changes how EVA reads it,
    /// never where it is.
    @Test func applyingARuleNeverMovesTheMarkedInstant() throws {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(codePattern: "blnk", anchor: .peak, assumedDurationSeconds: 0.4),
        ])
        let source = event(code: "blnk", begin: 10)
        let applied = ruleSet.applied(to: source)

        #expect(applied.beginTimeSeconds == 10)
        #expect(applied.timeAnchor == .peak)
        #expect(applied.durationSeconds == 0.4)
        // Tolerance, not equality: 9.8 + 0.4 is 10.200000000000001 in binary
        // floating point.
        let span = try #require(applied.spanSeconds)
        #expect(abs(span.lowerBound - 9.8) < 1e-12)
        #expect(abs(span.upperBound - 10.2) < 1e-12)
    }

    /// The assumed duration is what makes a rule useful: most imported stimulus
    /// markers are instantaneous, and an anchor alone has nothing to act on.
    @Test func anchorWithoutADurationLeavesTheEventAPoint() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(codePattern: "blnk", anchor: .peak),
        ])
        let applied = ruleSet.applied(to: event(code: "blnk"))
        #expect(applied.timeAnchor == .peak)
        #expect(applied.spanSeconds == nil)
        #expect(applied.onsetTimeSeconds == applied.centerTimeSeconds)
    }

    /// A duration the file itself recorded is evidence, and outranks a guess.
    @Test func recordedDurationOutranksTheAssumedOne() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(codePattern: "blnk", anchor: .peak, assumedDurationSeconds: 5),
        ])
        let applied = ruleSet.applied(to: event(code: "blnk", duration: 0.4))
        #expect(applied.durationSeconds == 0.4)
    }

    @Test func unmatchedEventsPassThroughUntouched() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(codePattern: "blnk", anchor: .peak, assumedDurationSeconds: 0.4),
        ])
        let untouched = event(code: "stim1", duration: 0.1)
        #expect(ruleSet.applied(to: untouched) == untouched)
    }

    @Test func applyingIsIdempotent() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(codePattern: "blnk", anchor: .peak, assumedDurationSeconds: 0.4),
        ])
        let once = ruleSet.applied(to: event(code: "blnk"))
        let twice = ruleSet.applied(to: once)
        #expect(once == twice)
    }

    // MARK: - Summary

    @Test func summaryCountsOnlyRulesThatMatched() {
        let ruleSet = EventAnchorRuleSet(rules: [
            EventAnchorRule(codePattern: "blnk", anchor: .peak, assumedDurationSeconds: 0.4),
            EventAnchorRule(codePattern: "never", anchor: .center),
        ])
        let events = [event(code: "blnk"), event(code: "blnk", begin: 20), event(code: "stim1")]
        let summary = try! #require(ruleSet.appliedSummary(for: events))
        #expect(summary.contains("blnk→peak×2"))
        #expect(!summary.contains("never"))
    }

    @Test func summaryIsNilWhenNothingMatched() {
        let ruleSet = EventAnchorRuleSet(rules: [EventAnchorRule(codePattern: "never")])
        #expect(ruleSet.appliedSummary(for: [event(code: "blnk")]) == nil)
    }

    // MARK: - Persistence

    @Test func rulesSurviveAnEncodeDecodeRoundTrip() throws {
        let rules = [
            EventAnchorRule(codePattern: "blnk", anchor: .peak, assumedDurationSeconds: 0.4),
            EventAnchorRule(isEnabled: false, codePattern: "stim*", sourceScope: "a.mff", anchor: .center),
        ]
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([EventAnchorRule].self, from: data)
        #expect(decoded == rules)
    }
}
