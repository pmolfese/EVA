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
//  Navigation restores from `PipelineSnapshot` when available, which makes the
//  common undo/redo path instant. Supported nodes whose snapshots were evicted
//  can be re-derived; that fallback must remain exact and source-valid.
//
//  **Still missing:** measured `computeCost` per node and a truthful
//  pin/eviction UI (ROADMAP RW-1 item 7). Re-derivation's source rule and
//  commit safety are settled — see `reDerivationSource(for:)` and
//  `WaveformView.reDeriveHistory`.
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
    /// intermediate signals were never in memory this session. Generic
    /// re-derivation cannot reach them either, because the loaded signal is the
    /// prefix's *output*, not its input — so they are explicitly non-navigable
    /// once their snapshot is gone, and the steps downstream of the prefix are
    /// replayed without it. That rule is `reDerivationSource(for:)`.
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
            // The current node is never evicted — it describes the state on
            // screen. A pinned node is never evicted either, which is the whole
            // content of the pin (ROADMAP RW-1 item 7); `setPinned` caps how
            // much may be held that way, so this exemption cannot grow to
            // disable the budget.
            guard candidate != history.currentID,
                  history.node(candidate)?.isPinned != true,
                  let victim = snapshots[candidate]
            else {
                index += 1
                continue
            }
            total -= victim.estimatedBytes
            snapshots.removeValue(forKey: candidate)
            snapshotOrder.remove(at: index)
        }
    }

    // MARK: - Pinning

    /// How much of the budget pinned snapshots may hold.
    ///
    /// A pin is an exemption from eviction, and an unlimited exemption is not a
    /// policy — pinning everything would silently disable the byte budget,
    /// which is the exact failure the budget exists to prevent (the app swapped
    /// when a flat 2 GB constant did that on a small machine). Half is the
    /// starting point: enough to keep several reference states, not enough to
    /// leave the live pipeline without room.
    var pinnedByteShare = 0.5

    var pinnedByteAllowance: Int { Int(Double(snapshotByteBudget) * pinnedByteShare) }

    var pinnedBytes: Int {
        snapshots.reduce(0) { total, entry in
            history.node(entry.key)?.isPinned == true ? total + entry.value.estimatedBytes : total
        }
    }

    enum PinOutcome: Equatable {
        case pinned
        case unpinned
        /// Refused: this pin would push the pinned total past its allowance.
        /// Carries what is already held and what the ceiling is, so the caller
        /// can say so rather than failing silently.
        case refused(pinnedBytes: Int, allowanceBytes: Int)
    }

    /// Pins or unpins `id`, refusing a pin that would exceed the allowance.
    @discardableResult
    func setPinned(_ pinned: Bool, for id: EVAHistoryNodeID) -> PinOutcome {
        guard pinned else {
            history.setPinned(false, for: id)
            return .unpinned
        }
        guard history.node(id)?.isPinned != true else { return .pinned }

        // Only a node that actually holds a snapshot spends the allowance; a
        // pin on an evicted node costs nothing until it is rebuilt, and
        // refusing it would be refusing an intent rather than a cost.
        let cost = snapshots[id]?.estimatedBytes ?? 0
        let allowance = pinnedByteAllowance
        guard cost == 0 || pinnedBytes + cost <= allowance else {
            return .refused(pinnedBytes: pinnedBytes, allowanceBytes: allowance)
        }
        history.setPinned(true, for: id)
        return .pinned
    }

    func isPinned(_ id: EVAHistoryNodeID) -> Bool {
        history.node(id)?.isPinned == true
    }

    // MARK: - Cache reporting

    /// What the snapshot cache is holding, for the History tab's footer.
    ///
    /// Shown rather than kept private because eviction is otherwise invisible:
    /// nodes quietly stop being instant and the operator has no way to see why,
    /// or that a budget exists at all (ROADMAP RW-1 item 7).
    var snapshotBudgetSummary: String {
        "\(Self.byteSummary(snapshotBytes)) of \(Self.byteSummary(snapshotByteBudget)) cached · \(snapshotCount) of \(snapshotCountLimit)"
    }

    static func byteSummary(_ bytes: Int) -> String {
        let gigabyte = 1_000_000_000.0
        let megabyte = 1_000_000.0
        if Double(bytes) >= gigabyte {
            return String(format: "%.1f GB", Double(bytes) / gigabyte)
        }
        return String(format: "%.0f MB", Double(bytes) / megabyte)
    }

    /// Records the measured wall time of a node's first computation.
    ///
    /// Measured, never estimated: `REWIND.md` is explicit that a cost hint must
    /// come from a real timing rather than a table of "expensive" stages, and a
    /// row shows no time at all until one exists (ROADMAP RW-1 item 7).
    func recordComputeCost(_ seconds: TimeInterval, for id: EVAHistoryNodeID) {
        history.recordComputeCost(seconds, for: id)
    }

    func computeCost(for id: EVAHistoryNodeID) -> TimeInterval? {
        history.node(id)?.computeCost
    }

    // MARK: - Re-derivation source

    /// What a node whose snapshot is gone can be rebuilt from.
    ///
    /// The only input a session reliably has is the signal it loaded, and for a
    /// processed file that signal is **not** the raw recording — it is the
    /// output of `onDiskPrefix`. Replaying a whole path against it therefore
    /// applies every prefix step a second time: the reported double-filter /
    /// double-reference / double-correct (ROADMAP RW-1 item 1). So the steps a
    /// caller may replay are the ones *after* the prefix, and a node at or
    /// inside the prefix has no available input at all.
    enum ReDerivationSource: Equatable {
        /// Replay these steps against the signal this session loaded
        /// (`recording.signal`). Empty means the loaded signal already *is*
        /// this node's state.
        case loadedSignal(steps: [EVAProcessingStep])
        /// Nothing this session holds can produce this node's state. Its
        /// snapshot is the only way to reach it, and that snapshot is gone.
        case unavailable(Reason)

        /// Why a rebuild is impossible, in the operator's terms.
        ///
        /// A reason rather than a bare `nil` because ROADMAP RW-1 item 7 asks
        /// for a truthful failure surface: the rail can grey the row *and* say
        /// what would make it reachable, before the click rather than after it.
        enum Reason: Equatable {
            /// No such node (a stale id from a discarded future, say).
            case unknownNode
            /// At or inside the steps the file arrived with. The loaded samples
            /// are this node's own output or something downstream of it, so its
            /// input was never in this session (item 1).
            case producedBeforeThisSession
            /// The path does not lead with the file's on-disk steps, so the
            /// loaded signal is the wrong starting point and there is nothing
            /// to subtract.
            case lineageDoesNotMatchFile
            /// A step on the path cannot be reproduced exactly here.
            case blockedStep(EVAProcessingStep.Operation)

            var message: String {
                switch self {
                case .unknownNode:
                    return "That point is no longer in this recording's history."
                case .producedBeforeThisSession:
                    return "This step happened before the file was saved, so the samples it started from aren't in this session. It stays reachable only while its snapshot is cached."
                case .lineageDoesNotMatchFile:
                    return "This point came from a different lineage than the file on disk, so it can't be rebuilt from the loaded signal."
                case .blockedStep(let operation):
                    return "Can't rebuild \(ReplayStepDisplay.label(for: operation)) from disk — it stays reachable only while its data is still cached."
                }
            }
        }

        var isAvailable: Bool {
            if case .loadedSignal = self { return true }
            return false
        }

        var unavailableReason: Reason? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// Where `id` can be rebuilt from, and with what — see `ReDerivationSource`.
    ///
    /// Both halves of the question are answered here (ROADMAP RW-1 item 7):
    /// which signal the steps may be replayed against, *and* whether every step
    /// on the way can be reproduced exactly given what this file carries. They
    /// were previously split between this method and a private helper on the
    /// view, so the rail could only report the first — a node blocked by a
    /// missing ICA sidecar still rendered as an ordinary click that failed.
    ///
    /// `availability` describes the file being rebuilt onto, the same value the
    /// replay engine classifies with (`EVAProcessingStep.replayInteraction(given:)`).
    func reDerivationSource(
        for id: EVAHistoryNodeID,
        availability: ReplayPayloadAvailability = .none
    ) -> ReDerivationSource {
        guard history.node(id) != nil else { return .unavailable(.unknownNode) }
        let steps = history.path(to: id).compactMap(\.step)

        let replayable: [EVAProcessingStep]
        if onDiskPrefix.isEmpty {
            replayable = steps
        } else if steps.count <= onDiskPrefix.count {
            // At or inside the prefix.
            return .unavailable(.producedBeforeThisSession)
        } else if !Self.stepsMatch(Array(steps.prefix(onDiskPrefix.count)), onDiskPrefix) {
            return .unavailable(.lineageDoesNotMatchFile)
        } else {
            replayable = Array(steps.dropFirst(onDiskPrefix.count))
        }

        if let blocker = Self.firstNonReDerivableStep(in: replayable, availability: availability) {
            return .unavailable(.blockedStep(blocker))
        }
        return .loadedSignal(steps: replayable)
    }

    /// The first step that cannot be reproduced exactly on a file with
    /// `availability`, or nil when the whole path can be.
    ///
    /// The supported-step matrix, in one place and pure. Faithfulness over
    /// reach: a step that would have to be *approximated* is refused, because a
    /// plausible-looking wrong signal is worse than a click that declines.
    static func firstNonReDerivableStep(
        in steps: [EVAProcessingStep],
        availability: ReplayPayloadAvailability
    ) -> EVAProcessingStep.Operation? {
        for step in steps {
            switch step.operation {
            // Portable, or carrying their own subject-specific list.
            case .filter, .reference, .baseline, .segment, .waveletReduce,
                 .thresholdArtifactDetection, .mriGradientCorrection, .markBad:
                continue
            // Re-appliable exactly from this file's own sidecar.
            case .icaClean where availability.hasICAPayload:
                continue
            case .artifactClean where availability.hasArtifactPayload:
                continue
            // Re-solvable from this file's electrode positions
            // (`ChannelInterpolationSolver`).
            case .interpolateChannels where availability.hasElectrodeGeometry:
                continue
            // Everything else — BCG above all, which is subject-specific with
            // no re-derive path at all.
            default:
                return step.operation
            }
        }
        return nil
    }

    /// Whether navigating to `id` can honestly land there — instantly from a
    /// snapshot, or by re-deriving from an available source.
    func isReachable(
        _ id: EVAHistoryNodeID,
        availability: ReplayPayloadAvailability = .none
    ) -> Bool {
        hasSnapshot(for: id) || reDerivationSource(for: id, availability: availability).isAvailable
    }

    /// Compares steps by what identifies them in the tree — operation and
    /// parameters. `EVAProcessingStep`'s synthesized `==` also covers its
    /// per-instance `id` and `appliedAt`, which two equal-in-content steps do
    /// not share.
    private static func stepsMatch(_ lhs: [EVAProcessingStep], _ rhs: [EVAProcessingStep]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.operation == $1.operation && $0.parameters == $1.parameters
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
    func railNodes(
        rawSubtitle: String,
        availability: ReplayPayloadAvailability = .none
    ) -> [HistoryRailNode] {
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
                isReachable: isReachable(node.id, availability: availability),
                unreachableReason: snapshots[node.id] != nil
                    ? nil
                    : reDerivationSource(for: node.id, availability: availability)
                        .unavailableReason?.message,
                rebuildSeconds: snapshots[node.id] == nil ? node.computeCost : nil,
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

    /// An empty or whitespace-only name clears the label rather than storing
    /// one, so "rename back to the default" needs no separate command
    /// (`EVAHistory.setLabel` does the trimming).
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
    /// Whether navigating here restores immediately from a snapshot rather than
    /// requiring re-derivation. `REWIND.md` asks for the cost hint to be shown
    /// *before* the click, not after.
    var isInstant: Bool = true
    /// Whether this node can be reached at all — instantly, or by re-deriving
    /// from a source this session actually has. False for a node the file
    /// arrived with whose snapshot is gone, and for one whose path contains a
    /// step this file cannot reproduce (BCG, or ICA with no sidecar): the rail
    /// shows those as history rather than offering a click that cannot honestly
    /// be honoured. See `RecordingHistoryModel.reDerivationSource(for:availability:)`.
    var isReachable: Bool = true
    /// Why it cannot be reached, ready to show. Nil when it can.
    var unreachableReason: String?
    /// Measured seconds the first computation took, when one was measured and
    /// this node's snapshot is gone — so the rail can say what a rebuild will
    /// cost. Nil means *unknown*, and the row says nothing rather than guessing.
    var rebuildSeconds: TimeInterval?
    /// Indentation level. Only increases at a fork, so a linear session stays
    /// flat rather than becoming a staircase.
    var depth: Int = 0
    /// Whether this node is an ancestor of, or is, the current one. Off-path
    /// nodes can occur in decoded legacy trees or explicit copied histories;
    /// ordinary recording-window replacement prunes an abandoned future.
    var isOnCurrentPath: Bool = true
}
