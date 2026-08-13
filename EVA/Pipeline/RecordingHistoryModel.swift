//
//  RecordingHistoryModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Owns the recording window's `EVAHistory` and the rail's display state.
//
//  ## Derived today, authoritative later
//
//  Right now the history is **rebuilt from `currentProcessingScript()`** whenever
//  the pipeline chain changes. Nothing calls `EVAHistory.apply(_:)` at the moment
//  a stage runs, so the tree is a projection of live view model state rather than
//  the record of what happened. Two consequences worth being honest about:
//
//  - **The tree is always linear.** A branch is a path you left behind, and the
//    script only describes the state you are in. Forks appear when the apply
//    paths record nodes themselves.
//  - **Re-applying a stage with the same parameters produces the same node**, so
//    the rail does not grow while someone tunes a cutoff and re-applies. That is
//    the right behavior and it comes free from content addressing — but it is
//    worth knowing it is not yet evidence that node *recording* dedups, because
//    nothing is recording.
//
//  This is deliberately the cheap half of `REWIND.md` work item 1. It puts a
//  real, correct rail on screen against real recordings, which is how the
//  granularity question — the one the design flags as most likely to be got
//  wrong — gets answered by looking rather than by reasoning.
//
//  It lives here rather than in `WaveformUIModels.swift` because that file is
//  explicitly display state that "nothing here belongs in eva.xml or affects
//  processing output". `EVAHistory` will not stay on that side of the line.
//

import SwiftUI

@MainActor
@Observable
final class RecordingHistoryModel {
    /// The tree. Rebuilt from the processing script until the apply paths record
    /// nodes directly — see the file header.
    private(set) var history = EVAHistory(recordingKey: "")

    /// Rebuilds from `script`, keyed to `recordingKey` so two recordings never
    /// share node identities.
    ///
    /// Annotations on surviving nodes are carried across
    /// (`EVAHistory.adoptAnnotations`), so a rebuild does not discard a pin the
    /// user set — and so an unchanged chain rebuilds to something genuinely
    /// equal, which is what makes the guard below work at all.
    ///
    /// Assigns only when the result differs. The comparison is a dictionary of
    /// small values, far cheaper than the SwiftUI invalidation an unconditional
    /// write would cause every time the chain signature moves — including the
    /// many changes that produce the same tree.
    func rebuild(recordingKey: String, script: EVAProcessingScript) {
        var rebuilt = EVAHistory(recordingKey: recordingKey, script: script)
        rebuilt.adoptAnnotations(from: history)
        guard rebuilt != history else { return }
        history = rebuilt
    }

    /// Rail rows for the current tree, root first.
    ///
    /// Value types, resolved here rather than in the view, so the rail's `View`
    /// structs take plain data and can be `Equatable` — the pattern ROADMAP B2
    /// measured as the one that actually pays (`ChannelLabelRow`'s one-line
    /// `Equatable` was the single biggest win in the whole refactor).
    func railNodes(rawSubtitle: String) -> [HistoryRailNode] {
        history.currentPath.map { node in
            HistoryRailNode(
                id: node.id.hex,
                title: node.step.map { HistoryStepSummary.title(for: $0.operation) } ?? node.displayLabel,
                subtitle: node.step.map { HistoryStepSummary.subtitle(for: $0) } ?? rawSubtitle,
                isCurrent: node.id == history.currentID,
                isPinned: node.isPinned
            )
        }
    }

    /// Short id of the current node, shown in the rail header the way git shows
    /// an abbreviated hash.
    var currentShortID: String { history.currentID.short }

    func reset() {
        history = EVAHistory(recordingKey: "")
    }
}

/// One row of the rail. A value, not a node reference — see `railNodes`.
nonisolated struct HistoryRailNode: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var isCurrent: Bool
    var isPinned: Bool
}
