//
//  WindowComparisonRegistry.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Which recording windows can be compared with which, and what each of them is
//  currently showing (ROADMAP RW-1 item 10).
//
//  ## Why windows rather than nodes
//
//  REWIND originally specified A/B compare as "select two sibling nodes". One
//  window's history is linear — applying a divergent action deletes the
//  abandoned future — so two siblings only coexist while one of them is an
//  un-replaced redo branch, which is not a state anyone can deliberately set up.
//  Fork to New Window is the deliberate branch operation, so *windows* are what
//  A/B compare has to relate.
//
//  ## The relation
//
//  A window carries a `groupID`. Forking copies the parent's, so every window
//  descended from one original shares it: those windows are the same recording
//  at different points in one experiment, and comparing them is meaningful
//  without further explanation.
//
//  Opening the same file again independently produces a window with its own
//  group. **That is offered for comparison too, and labelled as unrelated
//  lineage** — it is not warned about and not blocked. Two windows on one file
//  is a supported thing to do (see REWIND's multi-window section), a modal on
//  open would teach nothing, and refusing to compare them would be refusing the
//  one question the operator plainly has. What matters is that the sheet never
//  claims a shared ancestor it cannot prove — hence the distinction is carried
//  in the relation rather than smoothed away.
//
//  ## Shape
//
//  Windows *push* value snapshots, the way `ChannelsWindowModel` already
//  receives its context, rather than the registry holding references into view
//  models it does not own. A closed window unregisters; a stale entry can
//  therefore never hand out a signal belonging to a window that has torn down.
//

import Foundation
import Observation

/// One recording window, as seen by another window's compare sheet.
nonisolated struct ComparableWindow: Sendable, Identifiable, Equatable {
    /// The window's recording identity (`MFFRecording.id`), stable for its life.
    let id: UUID
    /// Windows that share this were produced by forking one from another.
    var groupID: UUID
    var packageName: String
    var packageURL: URL
    /// Short ID of the history node this window is currently showing.
    var currentNode: String
    /// Human-readable lineage tip — the step labels leading to `currentNode`.
    var lineageSummary: String
    /// Where this window was forked from, when it was: the node it started at.
    var forkedFromNode: String?
    /// What the waveform is showing right now.
    var signal: MFFSignalData?
    var badChannelCount: Int
    var interpolatedChannelCount: Int
    /// Mean segment-health "good" percentage, when Segment Health has run.
    var segmentHealthMeanGood: Int?
    /// Whether labeled artifacts have been assessed at all (RW-1 item 16).
    var artifactsAssessed: Bool

    static func == (lhs: ComparableWindow, rhs: ComparableWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.groupID == rhs.groupID
            && lhs.currentNode == rhs.currentNode
            && lhs.lineageSummary == rhs.lineageSummary
            && lhs.forkedFromNode == rhs.forkedFromNode
            && lhs.signal?.dataRevision == rhs.signal?.dataRevision
            && lhs.badChannelCount == rhs.badChannelCount
            && lhs.interpolatedChannelCount == rhs.interpolatedChannelCount
            && lhs.segmentHealthMeanGood == rhs.segmentHealthMeanGood
            && lhs.artifactsAssessed == rhs.artifactsAssessed
    }
}

/// How two windows are related — the thing the compare sheet must not overstate.
nonisolated enum WindowRelation: Sendable, Equatable {
    /// Forked from one another, directly or through a chain: one experiment.
    case forkedLineage
    /// The same file, opened twice with no shared history.
    case sameFileIndependent
    /// Different recordings.
    case differentRecordings

    var label: String {
        switch self {
        case .forkedLineage: return "Forked lineage"
        case .sameFileIndependent: return "Same file, opened independently"
        case .differentRecordings: return "Different recordings"
        }
    }

    var detail: String {
        switch self {
        case .forkedLineage:
            return "These windows share a history: one was forked from the other."
        case .sameFileIndependent:
            return "Same file, but these windows were opened separately — nothing guarantees they were processed from the same starting point."
        case .differentRecordings:
            return "Different files. Channels are matched by name; anything that cannot be matched is listed."
        }
    }
}

@MainActor
@Observable
final class WindowComparisonRegistry {
    static let shared = WindowComparisonRegistry()

    private(set) var windows: [ComparableWindow] = []

    /// Registers or updates one window's snapshot.
    ///
    /// Called on every signal change, which is often — so an unchanged snapshot
    /// writes nothing. `ComparableWindow`'s equality compares the signal by
    /// `dataRevision` rather than by samples, so this stays O(1) and does not
    /// invalidate every observer on a redundant publish.
    func publish(_ window: ComparableWindow) {
        if let index = windows.firstIndex(where: { $0.id == window.id }) {
            guard windows[index] != window else { return }
            windows[index] = window
        } else {
            windows.append(window)
        }
    }

    func unregister(id: UUID) {
        windows.removeAll { $0.id == id }
    }

    func window(id: UUID) -> ComparableWindow? {
        windows.first { $0.id == id }
    }

    /// Every other window that can be compared against `id`, best relation
    /// first: forked lineage, then the same file, then everything else.
    func comparisonCandidates(for id: UUID) -> [(window: ComparableWindow, relation: WindowRelation)] {
        guard let source = window(id: id) else { return [] }
        return windows
            .filter { $0.id != id && $0.signal != nil }
            .map { ($0, relation(source, $0)) }
            .sorted { first, second in
                let order: (WindowRelation) -> Int = { relation in
                    switch relation {
                    case .forkedLineage: return 0
                    case .sameFileIndependent: return 1
                    case .differentRecordings: return 2
                    }
                }
                if order(first.relation) != order(second.relation) {
                    return order(first.relation) < order(second.relation)
                }
                return first.window.packageName.localizedStandardCompare(second.window.packageName) == .orderedAscending
            }
    }

    func relation(_ a: ComparableWindow, _ b: ComparableWindow) -> WindowRelation {
        if a.groupID == b.groupID { return .forkedLineage }
        if a.packageURL == b.packageURL { return .sameFileIndependent }
        return .differentRecordings
    }
}
