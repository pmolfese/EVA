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
//  ## Accumulated from the chain, not appended per apply
//
//  Every time the pipeline chain moves, the canonical script is folded into the
//  tree with `EVAHistory.adopt`. Content addressing makes that cheap and makes it
//  *accumulate*: the unchanged prefix resolves to the nodes that already exist,
//  and a changed stage forks at exactly that stage while the branch you came from
//  survives with its cache, pin, and label. The tree therefore remembers states
//  you have left, which is the property that separates a history from a readout.
//
//  It is driven from the chain rather than from each apply site on purpose.
//  Applying a stage upstream of one already applied — gradient after filter —
//  invalidates the downstream stage, so the order things *happened* in is not the
//  order that describes the resulting signal. Appending in application order
//  would record a lineage that does not reproduce the bytes, and reproducing the
//  bytes is the whole promise of a node ID. See `EVAHistory.adopt`.
//
//  **Still missing before this is a full record:** measured `computeCost` per
//  node, which only the apply sites know, and navigation — clicking a node does
//  nothing yet. Both are `REWIND.md` work item 2's territory.
//
//  It lives here rather than in `WaveformUIModels.swift` because that file is
//  explicitly display state that "nothing here belongs in eva.xml or affects
//  processing output". `EVAHistory` will not stay on that side of the line.
//

import SwiftUI

@MainActor
@Observable
final class RecordingHistoryModel {
    /// The tree. Accumulated from the processing chain — see the file header.
    private(set) var history = EVAHistory(recordingKey: "")

    /// The recording the current tree belongs to. A different key means a
    /// different file, and nodes must not be shared across files.
    private var recordingKey = ""

    /// Folds the current processing chain into the tree and moves the pointer to
    /// its tip.
    ///
    /// **Accumulates rather than rebuilds.** The previous version discarded the
    /// tree and derived a fresh one every time the chain moved, which made
    /// branches impossible by construction — every state you left was thrown
    /// away. `EVAHistory.adopt` re-walks the canonical chain from the root
    /// instead, and content addressing turns that into a no-op for the part that
    /// has not changed and a fork at exactly the stage that has. Widen a filter
    /// after narrowing it and both nodes now exist, with the branch you came from
    /// still carrying its pin and its label.
    ///
    /// It is still driven from the chain rather than from each apply site, and
    /// that is on purpose — see `EVAHistory.adopt` for why application order is
    /// the wrong thing to record.
    func record(
        recordingKey: String,
        script: EVAProcessingScript,
        payloadDigests: [EVAProcessingStep.Operation: String] = [:]
    ) {
        if recordingKey != self.recordingKey {
            self.recordingKey = recordingKey
            history = EVAHistory(recordingKey: recordingKey)
        }
        var updated = history
        updated.adopt(script, payloadDigests: payloadDigests)
        // Assign only on a real change: `EVAHistory` is `Equatable` over small
        // values, far cheaper than the SwiftUI invalidation an unconditional
        // write would cause every time the chain signature moves.
        guard updated != history else { return }
        history = updated
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

    func setPinned(_ pinned: Bool, for id: EVAHistoryNodeID) {
        history.setPinned(pinned, for: id)
    }

    func setLabel(_ label: String?, for id: EVAHistoryNodeID) {
        history.setLabel(label, for: id)
    }

    /// Short id of the current node, shown in the rail header the way git shows
    /// an abbreviated hash.
    var currentShortID: String { history.currentID.short }

    func reset() {
        recordingKey = ""
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
