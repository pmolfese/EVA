//
//  EventAnchorSettings.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  User rules for how imported event markers should be read: which codes mark
//  the *start* of what they describe and which mark its middle. Backs the
//  Preferences ▸ Events tab.
//
//  Every file format EVA reads records event onsets, so that is what importers
//  stamp. But a marker's meaning is the experimenter's, not the format's: a lab
//  that writes one `blnk` marker at the apex of each blink has recorded a
//  centered event in a format with no way to say so. Without these rules such a
//  marker reads as an onset, and every window derived from it — cleaning,
//  epoching previews, the waveform highlight band — sits half a duration late.
//
//  Scope note: these rules deliberately apply only to a recording's *imported*
//  events (`MFFSignalData.events`). EVA's own detectors measure where their
//  events sit and stamp `EventTimeAnchor` from that measurement, so there is
//  nothing for a user guess to improve — and detector output lives in a
//  separate collection (`ArtifactViewModel.events` / `DefinedArtifact.events`),
//  so the two cannot be confused by accident.
//

import Foundation
import Observation
import SwiftUI

/// One user rule: "events whose code looks like this are anchored like that".
nonisolated struct EventAnchorRule: Codable, Identifiable, Sendable, Equatable, Hashable {
    var id: UUID
    /// Unchecked rules are kept but skipped, so a rule can be parked without
    /// being retyped.
    var isEnabled: Bool
    /// Event code to match. Case-insensitive, and a trailing `*` matches any
    /// suffix (`stim*` matches `stim1`, `stimA`); a bare `*` matches every code.
    var codePattern: String
    /// Restrict the rule to events imported from one file, matched against
    /// `MFFEvent.sourceFile`. `nil` (or empty) applies it to every source —
    /// the usual case, since a lab's marker convention is a property of the lab
    /// rather than of one file.
    var sourceScope: String?
    var anchor: EventTimeAnchor
    /// Duration to assume for matched events that record none.
    ///
    /// This is what makes a rule useful rather than merely correct. Most
    /// imported stimulus markers are instantaneous, and an anchor on a
    /// zero-duration event changes nothing — onset, center and peak all name
    /// the same instant. Supplying the width the experimenter knows the event
    /// to have ("our blink markers sit at the apex of a ~400 ms blink") is what
    /// gives EVA a span to draw and to clean over. Never overrides a duration
    /// the file itself recorded.
    var assumedDurationSeconds: Double?

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        codePattern: String = "",
        sourceScope: String? = nil,
        anchor: EventTimeAnchor = .center,
        assumedDurationSeconds: Double? = nil
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.codePattern = codePattern
        self.sourceScope = sourceScope
        self.anchor = anchor
        self.assumedDurationSeconds = assumedDurationSeconds
    }

    /// Whether this rule governs `event`. Disabled and blank-pattern rules
    /// match nothing — a half-typed rule should not quietly capture every event
    /// in the recording.
    func matches(_ event: MFFEvent) -> Bool {
        guard isEnabled else { return false }
        let pattern = codePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }

        if let scope = sourceScope?.trimmingCharacters(in: .whitespacesAndNewlines), !scope.isEmpty {
            guard event.sourceFile.compare(scope, options: .caseInsensitive) == .orderedSame else {
                return false
            }
        }

        return Self.matches(code: event.code, pattern: pattern)
    }

    /// Exact match, or prefix match when the pattern ends in `*`.
    static func matches(code: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            guard !prefix.isEmpty else { return true }
            return code.lowercased().hasPrefix(prefix.lowercased())
        }
        return code.compare(pattern, options: .caseInsensitive) == .orderedSame
    }
}

/// An immutable snapshot of the rules, safe to hand to a background context.
///
/// The `@Observable` settings object is main-actor state bound to the
/// Preferences UI; this is the value that actually does the work, so applying
/// rules never requires hopping actors or threading the settings object through
/// reader signatures.
nonisolated struct EventAnchorRuleSet: Sendable, Equatable {
    let rules: [EventAnchorRule]

    static let empty = EventAnchorRuleSet(rules: [])

    init(rules: [EventAnchorRule]) {
        self.rules = rules
    }

    var isEmpty: Bool { rules.allSatisfy { !$0.isEnabled } }

    /// The first enabled rule matching `event`, or `nil` if none does.
    ///
    /// First match wins, so the list is ordered by precedence and the user can
    /// put a specific rule above a `*` catch-all.
    func rule(for event: MFFEvent) -> EventAnchorRule? {
        rules.first { $0.matches(event) }
    }

    /// `event` re-read under these rules — the same instant, reinterpreted.
    ///
    /// Nothing here moves `beginTimeSeconds`: the sample the file marked is a
    /// fact, and only EVA's reading of which part of the event it names is the
    /// user's to set.
    func applied(to event: MFFEvent) -> MFFEvent {
        guard let rule = rule(for: event) else { return event }
        // A file-recorded duration is evidence and outranks the rule's guess.
        let duration = event.durationSeconds ?? rule.assumedDurationSeconds
        guard rule.anchor != event.timeAnchor || duration != event.durationSeconds else {
            return event
        }
        return event.reanchored(to: rule.anchor, durationSeconds: duration)
    }

    func applied(to events: [MFFEvent]) -> [MFFEvent] {
        guard !isEmpty else { return events }
        return events.map { applied(to: $0) }
    }

    /// A stable one-line description of the rules that actually bit, for the
    /// process log. Rules that matched nothing are omitted, so the log records
    /// what happened rather than what was configured.
    func appliedSummary(for events: [MFFEvent]) -> String? {
        guard !isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for event in events {
            guard let rule = rule(for: event) else { continue }
            counts["\(rule.codePattern)→\(rule.anchor.rawValue)", default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: ", ")
    }
}

/// Persisted event-anchor rules, bound to Preferences ▸ Events.
@MainActor
@Observable
final class EventAnchorSettings {
    /// Shared instance, following `ProcessingDefaults`. A singleton rather than
    /// injected state because the rules are consumed by `MFFRecording` at load
    /// — a model object with no view hierarchy to inherit an environment from.
    static let shared = EventAnchorSettings()

    private static let storageKey = "EventAnchorSettings.v1"

    var rules: [EventAnchorRule] {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([EventAnchorRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
    }

    /// Test seam: builds an instance from rules without touching `UserDefaults`.
    init(rules: [EventAnchorRule], persists: Bool = false) {
        self.rules = rules
        if persists { persist() }
    }

    var ruleSet: EventAnchorRuleSet { EventAnchorRuleSet(rules: rules) }

    func addRule(_ rule: EventAnchorRule = EventAnchorRule()) {
        rules.append(rule)
    }

    func removeRules(with ids: Set<EventAnchorRule.ID>) {
        rules.removeAll { ids.contains($0.id) }
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: offsets, toOffset: destination)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
