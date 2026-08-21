//
//  EVAHistory.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  `REWIND.md` work item 1: the history tree. Git-style navigation over a
//  recording's processing history — real undo/redo, branching, and step-by-step
//  scrubbing.
//
//  ## The model
//
//  **The step list is the truth. The signal is a cache.** A node is not a saved
//  copy of the data; it is the ordered list of steps that produced it, plus a
//  digest of whatever subject-specific payload those steps need (the ICA
//  operator, a bad-channel list, an artifact template). The signal at a node is
//  derived, cacheable, and evictable — none of that lives here.
//
//  This type is a **pure value**: no SwiftUI, no view models, no signals, no
//  I/O. It knows the shape of the history and nothing about how to compute it.
//  That is deliberate — it is the piece that has to be exhaustively testable, and
//  it is what work items 2 (the signal cache), 3 (derived invalidation), and 6
//  (session persistence) all hang off.
//
//  ## Node identity
//
//  A node's ID is `SHA-256(parentID, operation, sorted parameters, payload
//  digest)`. Because the parent ID is itself such a hash, an ID transitively
//  covers the node's entire ancestry: **equal ID means equal ancestry means equal
//  bytes**, which is what lets replay trust a cache instead of recomputing.
//
//  Excluded from the hash, on purpose:
//
//  - `EVAProcessingStep.id` and `appliedAt` — a UUID and a wall clock make every
//    node unique, which would destroy the whole property.
//  - `note`, `rejections`, `replayable` — prose, a *result* of the step, and a
//    classification. None of them is an input to the computation.
//  - `label`, `isPinned`, `computeCost` — annotations on a node, not part of what
//    the node *is*. Renaming a node must not move it.
//
//  ## What self-deduplication does and does not give you
//
//  `REWIND.md` says a user flipping a toggle back and forth six times should not
//  produce six nodes, and that the ancestry hash makes this automatic. **Half
//  true, and the half that isn't matters.** Appending "artifact correction off"
//  and then "artifact correction on" yields the ancestry `[…, off, on]`, which is
//  a genuinely different node from `[…]` — same samples, different identity, no
//  deduplication. Only re-applying the *same* step at the *same* parent
//  deduplicates, which `apply(_:)` does by returning the existing child.
//
//  So an undo-shaped action must be expressed as `stepBack()` — navigation — not
//  as appending an inverse step. That is not an implementation detail to be
//  papered over later; it is the rule that keeps the tree finite while someone
//  explores. See `applyDeduplicatesAnIdenticalStep` and
//  `togglingViaAnInverseStepDoesNotDeduplicate` in the tests, which pin both
//  halves.
//

import Foundation
import CryptoKit

/// Content-addressed node identity: the hex SHA-256 described in the file header.
nonisolated struct EVAHistoryNodeID: Hashable, Sendable, Codable, CustomStringConvertible {
    let hex: String

    init(hex: String) {
        self.hex = hex
    }

    init(from decoder: Decoder) throws {
        hex = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// First 8 characters, the way git abbreviates — for labels and logs.
    var short: String { String(hex.prefix(8)) }

    var description: String { short }
}

/// One point in a recording's processing history.
nonisolated struct EVAHistoryNode: Identifiable, Sendable, Codable, Hashable {
    let id: EVAHistoryNodeID
    /// `nil` only for the root — the unprocessed recording.
    let parent: EVAHistoryNodeID?
    /// The step that produced this node from its parent. `nil` for the root.
    let step: EVAProcessingStep?
    /// Digest of the subject-specific payload this step needs to be re-applied
    /// exactly — e.g. `ICAReplayPayload.replayIdentityBytes`. `nil` when the step
    /// is fully described by its parameters.
    let payloadDigest: String?

    /// Ordered children. Order is creation order, which is also the order the
    /// sidebar renders branches in.
    var children: [EVAHistoryNodeID] = []

    // MARK: Annotations — not part of identity
    /// User label, replacing the default rendering of the step.
    var label: String?
    /// Pinned nodes are exempt from cache eviction (work item 2).
    var isPinned: Bool = false
    /// Measured wall time of the first computation, in seconds. Drives
    /// cost-per-byte eviction — `REWIND.md` is explicit that this is measured,
    /// never guessed from a hardcoded table of "expensive" stages.
    var computeCost: TimeInterval?
    var createdAt: Date = Date()

    var isRoot: Bool { parent == nil }

    /// The label to show when the user has not renamed the node.
    var defaultLabel: String {
        guard let step else { return "raw" }
        return ReplayStepDisplay.label(for: step.operation)
    }

    var displayLabel: String { label ?? defaultLabel }
}

/// The tree. Insert, navigate, branch, prune.
nonisolated struct EVAHistory: Sendable, Codable, Equatable {

    private(set) var nodesByID: [EVAHistoryNodeID: EVAHistoryNode]
    private(set) var rootID: EVAHistoryNodeID
    private(set) var currentID: EVAHistoryNodeID
    /// Per node, the child most recently navigated *through*. Step-forward
    /// follows it so that back-then-forward is always a round trip, rather than
    /// dumping the user on whichever branch happens to be first.
    private(set) var lastVisitedChild: [EVAHistoryNodeID: EVAHistoryNodeID]

    // MARK: - Construction

    /// A history containing only the unprocessed recording.
    ///
    /// `recordingKey` seeds the root hash so two different recordings never share
    /// a root — and therefore never share any node. Pass something stable for the
    /// file (its package name or the signal's identity); it never has to be a
    /// path, and nothing here dereferences it.
    init(recordingKey: String) {
        let root = EVAHistoryNode(
            id: EVAHistoryNodeID(hex: EVAHistory.digest(["root", recordingKey])),
            parent: nil,
            step: nil,
            payloadDigest: nil
        )
        nodesByID = [root.id: root]
        rootID = root.id
        currentID = root.id
        lastVisitedChild = [:]
    }

    /// A history containing exactly one script's chain, root to tip.
    ///
    /// Convenience over `adopt` for a fresh tree — tests and one-shot
    /// derivations. A tree built this way is linear because one script describes
    /// one lineage; branches come from `adopt`-ing further chains into an
    /// existing tree, where content addressing forks at the stage that differs
    /// and leaves the rest alone.
    init(recordingKey: String, script: EVAProcessingScript) {
        self.init(recordingKey: recordingKey)
        for step in script.steps {
            apply(step)
        }
    }

    // MARK: - Reading

    var root: EVAHistoryNode { nodesByID[rootID]! }
    var current: EVAHistoryNode { nodesByID[currentID]! }
    var count: Int { nodesByID.count }

    func node(_ id: EVAHistoryNodeID) -> EVAHistoryNode? { nodesByID[id] }

    func children(of id: EVAHistoryNodeID) -> [EVAHistoryNode] {
        (nodesByID[id]?.children ?? []).compactMap { nodesByID[$0] }
    }

    /// Root → `id`, inclusive. Empty if the node is unknown.
    func path(to id: EVAHistoryNodeID) -> [EVAHistoryNode] {
        var reversed: [EVAHistoryNode] = []
        var cursor: EVAHistoryNodeID? = id
        while let currentCursor = cursor, let node = nodesByID[currentCursor] {
            reversed.append(node)
            cursor = node.parent
        }
        return reversed.reversed()
    }

    /// Root → current. This is the lineage `eva.xml` describes; the full tree is
    /// what work item 6 writes to `eva_history.json`.
    var currentPath: [EVAHistoryNode] { path(to: currentID) }

    /// The linear script for the current node — the steps along `currentPath`, in
    /// order. Equivalent to what `currentProcessingScript()` builds from live view
    /// model state, but derived from the tree instead of from three places that
    /// have to be kept in sync.
    var currentScript: EVAProcessingScript {
        var script = EVAProcessingScript()
        for node in currentPath {
            if let step = node.step { script.append(step) }
        }
        return script
    }

    /// The node a segmentation was built *from*: the parent of the first
    /// `segment` node on `path`, backing up past the `reference` and `baseline`
    /// steps that segmentation emits ahead of it.
    ///
    /// Those two are not separate stages the user can be returned to. Epoch
    /// referencing happens inside the PSA fold and baseline correction is a flag
    /// the same build folds in, so `currentProcessingScript()` emits both as
    /// settings the upcoming `segment` consumes — landing on one of them would
    /// be a state no single action ever produced. Undo has to clear the whole
    /// build, which is what backing up past them does.
    ///
    /// `nil` when `path` contains no `segment`. Pure and static so the rule is
    /// testable without a view; reachability of the result (snapshot present,
    /// or re-derivable) is the caller's problem — see
    /// `WaveformView.undoSegmentationTarget`.
    static func segmentationBuildParent(along path: [EVAHistoryNode]) -> EVAHistoryNode? {
        guard let segmentIndex = path.firstIndex(where: { $0.step?.operation == .segment })
        else { return nil }

        var index = segmentIndex - 1
        while index > 0, let operation = path[index].step?.operation,
              operation == .reference || operation == .baseline {
            index -= 1
        }
        guard index >= 0 else { return nil }
        return path[index]
    }

    func isAncestor(_ candidate: EVAHistoryNodeID, of id: EVAHistoryNodeID) -> Bool {
        var cursor = nodesByID[id]?.parent
        while let currentCursor = cursor {
            if currentCursor == candidate { return true }
            cursor = nodesByID[currentCursor]?.parent
        }
        return false
    }

    /// All descendants of `id`, parents before children.
    func descendants(of id: EVAHistoryNodeID) -> [EVAHistoryNodeID] {
        var out: [EVAHistoryNodeID] = []
        var queue = nodesByID[id]?.children ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            out.append(next)
            queue.append(contentsOf: nodesByID[next]?.children ?? [])
        }
        return out
    }

    // MARK: - Identity

    /// The ID a step would produce at a given parent. Pure — call it to ask
    /// "would this fork?" without mutating anything.
    func idFor(
        step: EVAProcessingStep,
        parent: EVAHistoryNodeID,
        payloadDigest: String? = nil
    ) -> EVAHistoryNodeID {
        var fields = [parent.hex, step.operation.rawValue]
        for key in step.parameters.keys.sorted() {
            fields.append(key)
            fields.append(step.parameters[key] ?? "")
        }
        fields.append(payloadDigest ?? "")
        return EVAHistoryNodeID(hex: EVAHistory.digest(fields))
    }

    /// SHA-256 over length-prefixed fields.
    ///
    /// Length-prefixed rather than joined by a separator: a parameter *value*
    /// containing the separator would otherwise let two different parameter sets
    /// hash identically, which in a content-addressed tree means silently
    /// serving one node's cached signal for another's. The same class of bug the
    /// `categoryRegex` serialization avoided by using one key per field.
    static func digest(_ fields: [String]) -> String {
        var hasher = SHA256()
        for field in fields {
            let bytes = Array(field.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hasher.update(data: Data($0)) }
            hasher.update(data: Data(bytes))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Mutation

    /// Applies `step` at the current node and makes the result current.
    ///
    /// Fork is the only primitive, exactly as `REWIND.md` specifies: if a child
    /// with this identity already exists, this **navigates** to it and creates
    /// nothing — its cached signal is still valid, because the ID matching means
    /// the bytes match. Otherwise a new child is created. Nothing downstream is
    /// discarded either way; pruning is a separate, explicit act.
    @discardableResult
    mutating func apply(
        _ step: EVAProcessingStep,
        payloadDigest: String? = nil,
        label: String? = nil
    ) -> EVAHistoryNodeID {
        let parentID = currentID
        let id = idFor(step: step, parent: parentID, payloadDigest: payloadDigest)

        if nodesByID[id] != nil {
            lastVisitedChild[parentID] = id
            currentID = id
            return id
        }

        let node = EVAHistoryNode(
            id: id,
            parent: parentID,
            step: step,
            payloadDigest: payloadDigest,
            label: label
        )
        nodesByID[id] = node
        nodesByID[parentID]?.children.append(id)
        lastVisitedChild[parentID] = id
        currentID = id
        return id
    }

    /// Walks `script` from the root, applying each step, and leaves the current
    /// pointer on the result.
    ///
    /// This is how the tree **accumulates** rather than being rebuilt. Content
    /// addressing does the work: a step that has been applied at this parent
    /// before resolves to the node that already exists, so re-adopting an
    /// unchanged chain touches nothing, while changing one stage's parameters
    /// forks at exactly that stage and leaves the branch you came from intact,
    /// cache, annotations, and all.
    ///
    /// Adopting the *canonical* chain rather than recording each apply as it
    /// happens is the deliberate choice here, and it avoids a trap. Applying a
    /// stage that sits upstream of one already applied — gradient after filter —
    /// invalidates the downstream stage, so the order things *happened* in is not
    /// the order that describes the resulting signal. A node appended in
    /// application order would claim filter → gradient produced this data when
    /// gradient → filter did. The canonical script is the one that reproduces
    /// the bytes, and reproducing the bytes is what a node ID promises.
    ///
    /// `payloadDigests` supplies the subject-specific identity for steps that
    /// need one (ICA's operator), keyed by operation — a script carries only
    /// portable parameters, so without this two different ICA removals would
    /// hash to one node.
    mutating func adopt(
        _ script: EVAProcessingScript,
        payloadDigests: [EVAProcessingStep.Operation: String] = [:]
    ) {
        currentID = rootID
        for step in script.steps {
            apply(step, payloadDigest: payloadDigests[step.operation])
        }
    }

    /// Moves the current pointer. Returns `false` for an unknown node.
    ///
    /// Records the descent through every edge on the path, so a later
    /// `stepForward()` retraces the branch the user actually came down rather
    /// than guessing.
    @discardableResult
    mutating func navigate(to id: EVAHistoryNodeID) -> Bool {
        guard nodesByID[id] != nil else { return false }
        let lineage = path(to: id)
        for (parent, child) in zip(lineage, lineage.dropFirst()) {
            lastVisitedChild[parent.id] = child.id
        }
        currentID = id
        return true
    }

    var canStepBack: Bool { current.parent != nil }

    /// Undo: navigate to the parent. Deliberately does *not* record a new
    /// last-visited edge — the edge we came down is the one to retrace.
    @discardableResult
    mutating func stepBack() -> Bool {
        guard let parent = current.parent else { return false }
        currentID = parent
        return true
    }

    var canStepForward: Bool { forwardChild != nil }

    /// The child `stepForward()` would move to: the branch last visited, else the
    /// first child.
    var forwardChild: EVAHistoryNodeID? {
        if let remembered = lastVisitedChild[currentID], nodesByID[remembered] != nil {
            return remembered
        }
        return current.children.first
    }

    /// Redo: navigate forward along the branch last visited, so back-then-forward
    /// is a round trip.
    @discardableResult
    mutating func stepForward() -> Bool {
        guard let child = forwardChild else { return false }
        currentID = child
        return true
    }

    /// Removes `id` and everything under it.
    ///
    /// Refuses on the root, on the current node, and on any ancestor of the
    /// current node — pruning the ground you are standing on has no sensible
    /// answer, so it is disallowed rather than silently relocating the user.
    /// Navigate away first. `REWIND.md` also asks for lazy pruning ("change it
    /// and move on" stays undoable for a while); that is a *policy* on top of
    /// this, and belongs with the cache in work item 2, not here.
    @discardableResult
    mutating func deleteBranch(_ id: EVAHistoryNodeID) -> Bool {
        guard id != rootID,
              id != currentID,
              nodesByID[id] != nil,
              !isAncestor(id, of: currentID) else { return false }

        let parentID = nodesByID[id]?.parent
        let doomed = [id] + descendants(of: id)
        for victim in doomed {
            nodesByID.removeValue(forKey: victim)
            lastVisitedChild.removeValue(forKey: victim)
        }
        // Also drop remembered edges *pointing into* the pruned subtree, or
        // `stepForward()` would try to descend into a node that no longer exists.
        let doomedSet = Set(doomed)
        for (key, value) in lastVisitedChild where doomedSet.contains(value) {
            lastVisitedChild.removeValue(forKey: key)
        }
        if let parentID {
            nodesByID[parentID]?.children.removeAll { $0 == id }
        }
        return true
    }

    // MARK: - Annotations

    mutating func setLabel(_ label: String?, for id: EVAHistoryNodeID) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        nodesByID[id]?.label = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    mutating func setPinned(_ pinned: Bool, for id: EVAHistoryNodeID) {
        nodesByID[id]?.isPinned = pinned
    }

    /// Records the measured wall time of a node's first computation. Ignores a
    /// second report so the stored figure stays "what it cost to compute this",
    /// not "what the last cache hit cost".
    mutating func recordComputeCost(_ seconds: TimeInterval, for id: EVAHistoryNodeID) {
        guard nodesByID[id]?.computeCost == nil else { return }
        nodesByID[id]?.computeCost = seconds
    }

    // MARK: - Codable

    // Hand-written so the persisted form is a flat, readable array of nodes
    // (work item 6's `eva_history.json`) rather than Swift's default encoding of
    // a dictionary with non-`String` keys, which is an unkeyed alternating list.

    private enum CodingKeys: String, CodingKey {
        case version, nodes, rootID, currentID, lastVisitedChild
    }

    private struct VisitedEdge: Codable {
        var from: EVAHistoryNodeID
        var to: EVAHistoryNodeID
    }

    static let currentVersion = 1

    /// The encoder work item 6 should write `eva_history.json` with.
    ///
    /// The encoder work item 6 should write `eva_history.json` with.
    ///
    /// Dates use `.deferredToDate` — `Date`'s own `timeIntervalSinceReferenceDate`
    /// — because it is the only strategy here that round-trips exactly, and a
    /// file whose job is to reproduce a state should decode back equal to what
    /// wrote it. The two obvious alternatives both lose information: `.iso8601`
    /// truncates at whole seconds, and `.secondsSince1970` re-bases the value by
    /// 978307200, which discards low mantissa bits on the way out and does not
    /// recover them on the way back. Neither would corrupt anything visible —
    /// node timestamps are annotations, not identity — but "the file decodes back
    /// equal" is a property worth being able to assert.
    ///
    /// The human-readable trail is `log_eva_*.txt`; this file is for the machine.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EVAHistory.currentVersion, forKey: .version)
        // Parents before children, so a decoder (or a human) can read the file
        // top-down and never meet a node before its parent.
        var ordered: [EVAHistoryNode] = []
        var queue = [rootID]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let node = nodesByID[id] else { continue }
            ordered.append(node)
            queue.append(contentsOf: node.children)
        }
        try container.encode(ordered, forKey: .nodes)
        try container.encode(rootID, forKey: .rootID)
        try container.encode(currentID, forKey: .currentID)
        try container.encode(
            lastVisitedChild.map { VisitedEdge(from: $0.key, to: $0.value) }
                .sorted { $0.from.hex < $1.from.hex },
            forKey: .lastVisitedChild
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nodes = try container.decode([EVAHistoryNode].self, forKey: .nodes)
        nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        rootID = try container.decode(EVAHistoryNodeID.self, forKey: .rootID)
        currentID = try container.decode(EVAHistoryNodeID.self, forKey: .currentID)
        let edges = try container.decodeIfPresent([VisitedEdge].self, forKey: .lastVisitedChild) ?? []
        lastVisitedChild = Dictionary(uniqueKeysWithValues: edges.map { ($0.from, $0.to) })

        // A history whose root or current pointer is missing cannot be repaired
        // by guessing — a wrong guess silently attributes someone's processing to
        // the wrong lineage.
        guard nodesByID[rootID] != nil, nodesByID[currentID] != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .nodes, in: container,
                debugDescription: "history references a node that is not in the file"
            )
        }
    }
}
