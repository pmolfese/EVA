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
//  ## Derived from the chain, with linear undo inside one window
//
//  Every time the pipeline chain moves, the canonical script is folded into the
//  history. Content addressing makes the unchanged prefix resolve to existing
//  nodes. Moving to a prefix retains descendants for redo; applying a different
//  action after that discards the abandoned future, matching standard Mac undo
//  semantics. Deliberate experiments survive by using Fork to New Window, where
//  each window receives its own value-copy of the history and snapshots.
//
//  It is driven from the chain rather than from each apply site on purpose.
//  Applying a stage upstream of one already applied — gradient after filter —
//  invalidates the downstream stage, so the order things *happened* in is not the
//  order that describes the resulting signal. Appending in application order
//  would record a lineage that does not reproduce the bytes, and reproducing the
//  bytes is the whole promise of a node ID. See `EVAHistory.adopt`.
//
//  Navigation restores from `PipelineSnapshot` rather than re-deriving, which is
//  what makes undo/redo instant — see that file for why the design's
//  re-derivation model is right for reproducing a package and wrong for moving
//  around inside a session.
//
//  **Still missing:** measured `computeCost` per node, which only the apply sites
//  know, and re-derivation for nodes whose snapshot has been evicted (today they
//  are simply not offered). Both are `REWIND.md` work item 2's territory.
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
    /// **Preserves redo, replaces abandoned futures.** Removing the current
    /// stage moves to its existing parent and keeps the removed chain reachable
    /// by Forward. Applying a different filter (or any other divergent action)
    /// then deletes that retained future before recording the replacement.
    ///
    /// It is still driven from the chain rather than from each apply site, and
    /// that is on purpose — see `EVAHistory.adopt` for why application order is
    /// the wrong thing to record.
    func record(
        recordingKey: String,
        script: EVAProcessingScript,
        payloadDigests: [EVAProcessingStep.Operation: String] = [:]
    ) {
        guard !isNavigating else { return }
        if recordingKey != self.recordingKey {
            self.recordingKey = recordingKey
            history = EVAHistory(recordingKey: recordingKey)
            // A new recording means a new file, and `onDiskPrefix` describes the
            // *previous* one — clear it here rather than only in `seedOnDiskPrefix`,
            // so a recording opened without a prefix (or before seeding runs) does
            // not inherit the last file's history. See `seedOnDiskPrefix`.
            onDiskPrefix = []
            onDiskPayloadDigests = [:]
        }
        adopt(liveSteps: script.steps, payloadDigests: payloadDigests)
    }

    /// What `eva.xml` already said happened to this file when it was opened —
    /// steps that produced the bytes on disk, before this session touched
    /// anything.
    ///
    /// Every `record()` call walks `onDiskPrefix + <live steps>` rather than the
    /// live steps alone. Without this, a freshly-opened processed file records as
    /// a bare "raw" root: `currentProcessingScript()` is built from the pipeline
    /// view models (`filter.output`, `ica.cleanedSignal`, …), and those are all
    /// `nil` until *this session* applies something — they have no way to know
    /// the loaded signal already went through a filter, threshold detection, and
    /// interpolation on a previous run. The file's own `eva.xml` does know, and
    /// this is what lets the rail show that lineage instead of discarding it.
    ///
    /// There is no snapshot for any node in this prefix except its tip: the
    /// intermediate signals were never in memory this session and cannot be
    /// recovered, only re-derived (REWIND work item 2, not built). The rail's
    /// existing "no snapshot" affordance — disabled row, tooltip — already
    /// covers exactly this, which is the point of seeding real nodes rather than
    /// a label: "shown but not navigable" falls out of machinery that already
    /// exists rather than needing its own.
    @ObservationIgnored private(set) var onDiskPrefix: [EVAProcessingStep] = []
    /// Payload digests for `onDiskPrefix`'s own subject-specific steps (ICA's
    /// operator, on disk) — kept separate from a live `record()` call's digests
    /// since the two describe different steps and must not overwrite each other.
    @ObservationIgnored private var onDiskPayloadDigests: [EVAProcessingStep.Operation: String] = [:]

    /// Seeds `onDiskPrefix` from the package's `eva.xml` when a recording opens.
    ///
    /// Idempotent and safe to call before, after, or interleaved with `record()`
    /// — `WaveformView.recordProcessingHistory()` fires from an `.onChange` that
    /// runs once before the file has finished loading (recording state still
    /// nil) and again once it has, so call order between this and `record()` is
    /// not guaranteed. Storing the prefix as state that every `record()` call
    /// re-reads, rather than a one-time tree mutation, makes the result the same
    /// regardless of which arrives first.
    func seedOnDiskPrefix(
        recordingKey: String,
        steps: [EVAProcessingStep],
        payloadDigests: [EVAProcessingStep.Operation: String] = [:]
    ) {
        if recordingKey != self.recordingKey {
            self.recordingKey = recordingKey
            history = EVAHistory(recordingKey: recordingKey)
        }
        guard steps != onDiskPrefix else { return }
        onDiskPrefix = steps
        onDiskPayloadDigests = payloadDigests
        adopt(liveSteps: [])
    }

    private func adopt(
        liveSteps: [EVAProcessingStep],
        payloadDigests: [EVAProcessingStep.Operation: String] = [:]
    ) {
        var updated = history
        let removed = updated.adoptReplacingAbandonedFuture(
            EVAProcessingScript(steps: onDiskPrefix + liveSteps),
            payloadDigests: onDiskPayloadDigests.merging(payloadDigests) { _, live in live }
        )
        // Assign only on a real change: `EVAHistory` is `Equatable` over small
        // values, far cheaper than the SwiftUI invalidation an unconditional
        // write would cause every time the chain signature moves.
        guard updated != history else { return }
        history = updated
        discardSnapshots(for: removed)
    }

    // MARK: - Snapshots

    /// Stage outputs per node, so navigating restores instead of recomputing.
    ///
    /// A side table rather than a field on `EVAHistoryNode`, deliberately:
    /// `EVAHistory` is a pure `Codable` value that work item 6 writes to disk,
    /// and sample buffers must never end up in `eva_history.json`. Snapshots are
    /// session-lived; the tree outlives them.
    @ObservationIgnored private var snapshots: [EVAHistoryNodeID: PipelineSnapshot] = [:]
    /// Node ids in the order they were snapshotted, oldest first — the eviction
    /// queue.
    @ObservationIgnored private var snapshotOrder: [EVAHistoryNodeID] = []

    /// How much sample data snapshots may hold before the oldest are dropped.
    ///
    /// Dropping a snapshot does not lose anything: the node keeps its steps, so
    /// it can still be re-derived. It only means that click is slow rather than
    /// instant, which is the right thing to trade away first. Some stages are
    /// fast enough that re-deriving them is imperceptible anyway.
    ///
    /// Sized from physical memory rather than a flat constant, because the number
    /// that matters is a *fraction of this machine*, not an absolute. One signal
    /// from a 129-channel, 9-minute, 1 kHz recording is ~276 MB, and a snapshot
    /// whose gradient/ICA/filter/artifact outputs are all distinct is over a
    /// gigabyte — so a fixed 2 GB budget was several snapshots' worth on a small
    /// machine and nothing on a large one. The first version used exactly that,
    /// and it made the app swap.
    ///
    /// A default rather than a preference for now — the mechanism is here so the
    /// preference is a one-line change when it is wanted.
    var snapshotByteBudget = RecordingHistoryModel.defaultSnapshotByteBudget

    /// ~14% of physical memory, clamped to a range that is neither useless nor
    /// ruinous: below ~384 MB a single stage output would not fit, and past
    /// 1.5 GB the snapshots start competing with the live pipeline, which needs
    /// its own copy of everything it is currently showing. The ceiling is
    /// deliberately *below* the 2 GB constant this replaced — scaling down on a
    /// small machine was the point, and scaling up on a large one was not.
    static let defaultSnapshotByteBudget: Int = {
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        return min(max(physical / 7, 384_000_000), 1_500_000_000)
    }()

    /// A second guard, independent of size. Bookkeeping stays bounded even when
    /// every snapshot is small — a short recording can produce hundreds of nodes
    /// in a session without ever approaching the byte budget.
    var snapshotCountLimit = 24

    /// Whether navigating to `id` would be instant.
    func hasSnapshot(for id: EVAHistoryNodeID) -> Bool { snapshots[id] != nil }

    var snapshotBytes: Int { snapshots.values.reduce(0) { $0 + $1.estimatedBytes } }
    var snapshotCount: Int { snapshots.count }

    /// Files the snapshot under the current node, evicting oldest-first if that
    /// puts the total over budget.
    ///
    /// The current node is never evicted — it describes the state on screen, and
    /// dropping it would make navigating *away and back* slow for no reason.
    func storeSnapshot(_ snapshot: PipelineSnapshot) {
        let id = history.currentID
        if snapshots[id] == nil { snapshotOrder.append(id) }
        snapshots[id] = snapshot
        evictSnapshotsBeyondBudget()
    }

    func snapshot(for id: EVAHistoryNodeID) -> PipelineSnapshot? { snapshots[id] }

    private func discardSnapshots(for removed: Set<EVAHistoryNodeID>) {
        guard !removed.isEmpty else { return }
        for id in removed {
            snapshots.removeValue(forKey: id)
        }
        snapshotOrder.removeAll { removed.contains($0) }
    }

    private func evictSnapshotsBeyondBudget() {
        var total = snapshotBytes
        var index = 0
        while index < snapshotOrder.count,
              total > snapshotByteBudget || snapshots.count > snapshotCountLimit {
            let candidate = snapshotOrder[index]
            guard candidate != history.currentID, let victim = snapshots[candidate] else {
                index += 1
                continue
            }
            total -= victim.estimatedBytes
            snapshots.removeValue(forKey: candidate)
            snapshotOrder.remove(at: index)
        }
    }

    // MARK: - Navigation

    /// True while a restore is in flight.
    ///
    /// Restoring changes every stage output, which trips the chain-signature
    /// observer that folds the chain back into the tree — and that would move
    /// the pointer straight back to the tip, undoing the navigation the user just
    /// asked for. The convergence *should* be harmless (the restored state
    /// derives the same script, so `adopt` lands on the same node), but relying
    /// on that would make undo silently depend on every view model's
    /// `parameters` being a perfect inverse of its `apply`. This is the belt.
    private(set) var isNavigating = false

    /// Moves the current pointer without touching the pipeline. The caller
    /// restores, because only it holds the view models.
    @discardableResult
    func beginNavigation(to id: EVAHistoryNodeID) -> PipelineSnapshot? {
        guard history.node(id) != nil, history.navigate(to: id) else { return nil }
        isNavigating = true
        return snapshots[id]
    }

    func endNavigation() {
        isNavigating = false
    }

    var canStepBack: Bool { history.canStepBack }
    var canStepForward: Bool { history.canStepForward }
    var stepBackTarget: EVAHistoryNodeID? { history.current.parent }
    var stepForwardTarget: EVAHistoryNodeID? { history.forwardChild }

    /// Rail rows for the current tree, root first.
    ///
    /// Value types, resolved here rather than in the view, so the rail's `View`
    /// structs take plain data and can be `Equatable` — the pattern ROADMAP B2
    /// measured as the one that actually pays (`ChannelLabelRow`'s one-line
    /// `Equatable` was the single biggest win in the whole refactor).
    func railNodes(rawSubtitle: String) -> [HistoryRailNode] {
        let onPath = Set(history.currentPath.map(\.id))
        var rows: [HistoryRailNode] = []

        func walk(_ id: EVAHistoryNodeID, depth: Int) {
            guard let node = history.node(id) else { return }
            rows.append(HistoryRailNode(
                id: node.id.hex,
                title: node.step.map { HistoryStepSummary.title(for: $0.operation) } ?? node.displayLabel,
                subtitle: node.step.map { HistoryStepSummary.subtitle(for: $0) } ?? rawSubtitle,
                isCurrent: node.id == history.currentID,
                isPinned: node.isPinned,
                isInstant: snapshots[node.id] != nil,
                depth: depth,
                isOnCurrentPath: onPath.contains(node.id)
            ))
            // Indent only at a fork. A linear history stays flat — indenting
            // every step would turn an ordinary session into a staircase.
            let children = node.children
            let childDepth = children.count > 1 ? depth + 1 : depth
            for child in children { walk(child, depth: childDepth) }
        }

        walk(history.rootID, depth: 0)
        return rows
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
        onDiskPrefix = []
        onDiskPayloadDigests = [:]
        snapshots.removeAll()
        snapshotOrder.removeAll()
        isNavigating = false
    }

    // MARK: - Forking

    /// Everything a forked window's own `RecordingHistoryModel` needs to
    /// start with the *same* tree and cache this one has — see REWIND.md
    /// "Forking to a new window": "`EVAHistory` copies whole, not just the
    /// current node" and "Snapshots copy whole too". Both are cheap for the
    /// same reason undo/redo already is: `MFFSignalData.data` is
    /// copy-on-write, so a snapshot dictionary copy shares buffers rather
    /// than duplicating megabytes of samples.
    ///
    /// A plain struct rather than handing out mutable references to this
    /// model's own storage — the two windows must be independent from the
    /// moment of the fork, and a struct copy is what makes that automatic:
    /// `history`/`snapshots` are already value types, so assigning them into
    /// the new model's storage is the whole isolation guarantee, with
    /// nothing further to get wrong.
    struct ForkSeed {
        var recordingKey: String
        var history: EVAHistory
        var snapshots: [EVAHistoryNodeID: PipelineSnapshot]
        var snapshotOrder: [EVAHistoryNodeID]
        var onDiskPrefix: [EVAProcessingStep]
        var onDiskPayloadDigests: [EVAProcessingStep.Operation: String]
    }

    func forkSeed() -> ForkSeed {
        ForkSeed(
            recordingKey: recordingKey,
            history: history,
            snapshots: snapshots,
            snapshotOrder: snapshotOrder,
            onDiskPrefix: onDiskPrefix,
            onDiskPayloadDigests: onDiskPayloadDigests
        )
    }

    /// Applies a `ForkSeed` wholesale, replacing whatever this model already
    /// has. Used once, right after a forked window's own on-disk seeding has
    /// already run (harmlessly redundant — same file, same `eva.xml`) — this
    /// call is what makes the fork's full, possibly-live-edited history win
    /// over it. See `WaveformView.applyForkSeed`.
    func seedFork(_ seed: ForkSeed) {
        recordingKey = seed.recordingKey
        history = seed.history
        snapshots = seed.snapshots
        snapshotOrder = seed.snapshotOrder
        onDiskPrefix = seed.onDiskPrefix
        onDiskPayloadDigests = seed.onDiskPayloadDigests
    }
}

/// One row of the rail. A value, not a node reference — see `railNodes`.
nonisolated struct HistoryRailNode: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var isCurrent: Bool
    var isPinned: Bool
    /// Whether navigating here restores from a snapshot rather than needing a
    /// re-derivation that does not exist yet. `REWIND.md` asks for the cost hint
    /// to be shown *before* the click, not after.
    var isInstant: Bool = true
    /// Indentation level. Only increases at a fork, so a linear session stays
    /// flat rather than becoming a staircase.
    var depth: Int = 0
    /// Whether this node is an ancestor of, or is, the current one. Off-path
    /// nodes are the branches you left — dimmed, but reachable.
    var isOnCurrentPath: Bool = true
}
