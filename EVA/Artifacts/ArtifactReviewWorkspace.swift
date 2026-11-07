//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

nonisolated private struct ArtifactSpatialDragPayload: Codable, Sendable {
    let sourceArtifactID: UUID
    let eventIDs: [String]
    let familyNumber: Int
}

private enum ArtifactSpatialGroupingControl: String, CaseIterable, Identifiable {
    case cohesion = "Cohesion"
    case targetCount = "Force count"
    var id: String { rawValue }
}

private enum ArtifactSpatialCardMapMode: String, CaseIterable, Identifiable {
    case centroid = "Canonical centroids"
    case representative = "Representative events"
    var id: String { rawValue }
}

/// Bounded workspace storage makes completed results available during the same
/// render pass as an artifact switch, without an asynchronous cache lookup.
struct ArtifactReviewResultCache<Value> {
    let capacity: Int
    private var entries: [String: Value] = [:]
    private var order: [String] = []

    /// Looks up a completed result without changing eviction order; reads are synchronous.
    subscript(key: String) -> Value? { entries[key] }

    /// Stores a result and moves its key to the newest insertion position. Evicts
    /// oldest inserted/updated entries beyond capacity (at least one); reads do not
    /// refresh recency, so this is not a least-recently-read cache.
    mutating func insert(_ value: Value, for key: String) {
        entries[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > max(1, capacity) {
            entries.removeValue(forKey: order.removeFirst())
        }
    }
}

/// A stable frame keeps workflow tabs in the same place throughout artifact work.
struct ArtifactWorkspace<Content: View>: View {
    @Binding var tab: ArtifactTemplateViewModel.WorkspaceTab
    let isBusy: Bool
    @ViewBuilder let content: () -> Content

    /// Provides a fixed-size tab frame around caller-supplied content. The tab
    /// binding belongs to the parent, and busy work temporarily disables tab changes.
    var body: some View {
        VStack(spacing: 0) {
            Picker("Artifact workflow", selection: $tab) {
                ForEach(ArtifactTemplateViewModel.WorkspaceTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)
            .frame(width: 360)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(0.025))
            .overlay(alignment: .bottom) { Divider() }

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 1280, height: 820)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Coordinates review choices, browsing and cached analyses for artifact definitions.
/// Bindings write back to the owning workflow; State holds session-only selection,
/// grouping controls and caches. Analysis/grouping tasks use keys to prevent stale
/// results from replacing the currently selected artifact’s data.
struct ArtifactReviewWorkspace: View {
    @Binding var artifacts: [DefinedArtifact]
    @Binding var selectedArtifactID: UUID?
    let signal: MFFSignalData
    let excludedChannels: Set<Int>
    let sensorLayoutName: String?
    let sensorLayout: SensorLayout?
    let onChange: () -> Void
    let onClose: () -> Void
    let onClean: () -> Void

    // These bounded caches belong to this view identity. Persisted review choices
    // are stored in artifacts instead, so switching the visible class does not lose them.
    @State private var analysisCache = ArtifactReviewResultCache<ArtifactReviewAnalysis>(capacity: 12)
    @State private var spatialCache = ArtifactReviewResultCache<ArtifactSpatialHierarchy>(capacity: 24)
    @State private var cutCache = ArtifactReviewResultCache<ArtifactSpatialCut>(capacity: 48)
    @State private var waveformCache = ArtifactReviewResultCache<ArtifactWaveformGroupingResult>(capacity: 12)
    @State private var analysis: ArtifactReviewAnalysis?
    @State private var loadedKey = ""
    @State private var selectedEventID: String?
    @State private var usesSpatialGroups = false
    @State private var spatialHierarchy: ArtifactSpatialHierarchy?
    @State private var spatialLoadedKey = ""
    @State private var spatialPreview: ArtifactSpatialHierarchy?
    @State private var spatialPreviewLoadedKey = ""
    @State private var selectedSpatialGroupIDs: Set<Int> = []
    @State private var spatialSelectionAnchorID: Int?
    @State private var spatialThreshold = 0.85
    @State private var spatialPolarityOverride: ArtifactSpatialPolarityMode?
    @State private var spatialSimilarityMetric = ArtifactSpatialSimilarityMetric.globalPearson
    @State private var spatialGroupingControl = ArtifactSpatialGroupingControl.cohesion
    @State private var spatialTargetCount = 2
    @State private var spatialCohesionRule = ArtifactSpatialCohesionRule.tenthPercentile
    @State private var spatialOutlierFloor = 0.60
    @State private var spatialCut: ArtifactSpatialCut?
    @State private var spatialCutLoadedKey = ""
    @State private var spatialCardMapMode = ArtifactSpatialCardMapMode.centroid
    @State private var manuallyMergedSpatialGroups: [ArtifactSpatialGroup] = []
    @State private var isSidebarDropTarget = false
    @State private var selectedArtifactIDs: Set<UUID> = []
    @State private var artifactSelectionAnchorID: UUID?
    @State private var showsSpatialEssentials = true
    @State private var showsSpatialQuality = false
    @State private var showsAutoSelection = false
    @State private var showsWaveformInspector = false
    @State private var waveformGrouping: ArtifactWaveformGroupingResult?
    @State private var waveformLoadedKey = ""
    @State private var waveformGroupID: Int?
    @State private var waveformThreshold = 0.90
    @State private var waveformPolarityOverride: ArtifactWaveformPolarityMode?
    @State private var band: ArtifactReviewBand?
    @State private var channel = 0
    @State private var tilePreview = ArtifactReviewTilePreview.waveforms
    @State private var displayMode = ArtifactReviewDisplayMode.top3
    @State private var contextSeconds = 0.5
    @State private var showsSplit = false
    @State private var splitName = "Artifact variation"
    @State private var splitMethod = ArtifactCleaningMethod.obs
    @State private var splitDestinationID: UUID?
    @State private var ruleUndo: [String: ArtifactReviewChoice]?
    @FocusState private var eventFocus: Bool

    /// Filters to definitions supported by the review engine that still have candidates.
    private var reviewable: [DefinedArtifact] {
        artifacts.filter { ArtifactReviewEngine.canReview($0) && !ArtifactReviewEngine.candidates(for: $0).isEmpty }
    }
    /// Resolves the focused artifact, falling back to the first reviewable definition.
    private var selected: DefinedArtifact? {
        reviewable.first { $0.id == selectedArtifactID } ?? reviewable.first
    }
    /// Removes stale IDs from the batch selection and falls back to the focused artifact
    /// when no selected IDs remain. This computed view does not mutate stored selection.
    private var effectiveSelectedArtifactIDs: Set<UUID> {
        let reviewableIDs = Set(reviewable.map(\.id))
        // Set intersection discards IDs whose artifacts were removed or became unreviewable.
        // This avoids applying a batch treatment to hidden/stale selection entries.
        let retained = selectedArtifactIDs.intersection(reviewableIDs)
        if !retained.isEmpty { return retained }
        return selected.map { [$0.id] } ?? []
    }
    /// Returns reviewable definitions affected by a batch treatment change.
    private var treatmentTargets: [DefinedArtifact] {
        let ids = effectiveSelectedArtifactIDs
        return reviewable.filter { ids.contains($0.id) }
    }
    /// Returns the shared method of all treatment targets, or nil for mixed/empty selection.
    private var commonTreatment: ArtifactCleaningMethod? {
        guard let first = treatmentTargets.first?.cleaningMethod,
              treatmentTargets.dropFirst().allSatisfy({ $0.cleaningMethod == first }) else { return nil }
        return first
    }
    /// Intersects allowed method lists so a batch menu offers only choices valid for every target.
    private var batchCleaningMethods: [ArtifactCleaningMethod] {
        guard let first = treatmentTargets.first else { return [] }
        return cleaningMethods(first).filter { method in
            treatmentTargets.dropFirst().allSatisfy { cleaningMethods($0).contains(method) }
        }
    }
    /// Offers sibling classes from the same source and compatible threshold ocular
    /// classes, excluding the current class. Transfer validity is also checked by the engine.
    private var compatibleSplitDestinations: [DefinedArtifact] {
        guard let selected else { return [] }
        let sourceID = selected.reviewState?.sourceArtifactID ?? selected.id
        return reviewable.filter {
            guard $0.id != selected.id else { return false }
            let sameSource = ($0.reviewState?.sourceArtifactID ?? $0.id) == sourceID
            let crossOcular = ArtifactReviewEngine.isThresholdFamily(selected)
                && ArtifactReviewEngine.isThresholdFamily($0)
            return sameSource || crossOcular
        }
    }
    /// Hashes inputs that affect example analysis, including sample revision, events,
    /// window settings and sensor geometry. Hasher values are session-local, not stable
    /// serialized identifiers. Review decisions alone do not rebuild the fixed reference.
    private var analysisKey: String {
        guard let artifact = selected else { return "empty" }
        var hasher = Hasher()
        hasher.combine(signal.dataRevision)
        hasher.combine(artifact.id)
        hasher.combine(artifact.windowSizeSeconds)
        hasher.combine(artifact.obsEdgeTaperSeconds)
        hasher.combine(artifact.selectedChannelIndices)
        hasher.combine(artifact.reviewState?.referenceEventIDs ?? ArtifactReviewEngine.candidates(for: artifact).map(\.id))
        hasher.combine(ArtifactReviewEngine.candidates(for: artifact))
        hasher.combine(excludedChannels.sorted())
        hasher.combine(sensorLayoutName)
        hasher.combine(sensorLayout?.positions)
        hasher.combine(artifact.thresholdOcularKind)
        hasher.combine(artifact.reviewState?.sourceThresholdKind)
        hasher.combine(artifact.thresholdOcularConfiguration?.channelOverride)
        for candidate in artifact.thresholdOcularCandidates ?? [] {
            hasher.combine(candidate.id)
            hasher.combine(candidate.startTimeSeconds)
            hasher.combine(candidate.endTimeSeconds)
            hasher.combine(candidate.peakMicrovolts)
        }
        return String(hasher.finalize())
    }
    /// Uses the active result only if its key matches; otherwise checks the synchronous cache.
    private var currentAnalysis: ArtifactReviewAnalysis? { loadedKey == analysisKey ? analysis : analysisCache[analysisKey] }
    /// Defaults ocular-like artifacts to polarity-insensitive grouping, others to signed grouping.
    private var defaultSpatialPolarityMode: ArtifactSpatialPolarityMode {
        switch selected?.type {
        case .ocular, .saccadicSpike, .corneoRetinal: return .ignoreGlobalPolarity
        default: return .signed
        }
    }
    /// Uses the user’s override when present, otherwise the type-specific default.
    private var spatialPolarityMode: ArtifactSpatialPolarityMode {
        spatialPolarityOverride ?? defaultSpatialPolarityMode
    }
    /// Defaults waveform orientation to match the spatial family when global polarity is ignored.
    private var waveformPolarityMode: ArtifactWaveformPolarityMode {
        waveformPolarityOverride ?? (spatialPolarityMode == .ignoreGlobalPolarity ? .orientToSpatialFamily : .preserve)
    }
    /// Exposes the selected spatial comparison metric for keys, grouping and labels.
    private var effectiveSpatialSimilarityMetric: ArtifactSpatialSimilarityMetric {
        spatialSimilarityMetric
    }
    /// Labels Pearson scores as signed r or absolute |r|; other comparisons use score.
    private var spatialScoreLabel: String {
        effectiveSpatialSimilarityMetric == .globalPearson ? (spatialPolarityMode == .signed ? "r" : "|r|") : "score"
    }
    /// Chooses spatial browsing initially for definitions with maps or threshold-family provenance.
    private func prefersSpatialGroups(_ artifact: DefinedArtifact?) -> Bool {
        guard let artifact else { return false }
        return artifact.topography != nil || ArtifactReviewEngine.isThresholdFamily(artifact)
    }
    /// Resets session grouping controls when entering another artifact. Extracted
    /// standalone families start as one group because the user already chose that partition.
    private func resetGroupingDefaults(for artifact: DefinedArtifact?) {
        usesSpatialGroups = prefersSpatialGroups(artifact)
        spatialPolarityOverride = nil
        spatialSimilarityMetric = .globalPearson
        spatialGroupingControl = artifact?.type == .ocular ? .targetCount : .cohesion
        // A dragged family is already an explicit spatial decision. Start its
        // independent review as one family instead of immediately splitting it again.
        spatialTargetCount = artifact?.reviewState?.displaysAsStandaloneArtifact == true ? 1 : 2
        spatialCohesionRule = .tenthPercentile
        spatialOutlierFloor = 0.60
    }
    /// Identifies the expensive hierarchy by analysis, polarity and comparison metric.
    /// An empty key disables building when spatial browsing or analysis is unavailable.
    private var spatialTaskKey: String {
        usesSpatialGroups && currentAnalysis != nil
            ? "\(analysisKey)/spatial/\(spatialPolarityMode.rawValue)/\(effectiveSpatialSimilarityMetric.rawValue)" : ""
    }
    /// Identifies the cheaper hierarchy-cut settings separately from the hierarchy itself.
    private var spatialCutParametersKey: String {
        "\(spatialGroupingControl.rawValue)/\(spatialTargetCount)/\(spatialThreshold)/\(spatialCohesionRule.rawValue)/\(spatialOutlierFloor)"
    }
    /// Combines hierarchy and cut identities so an early preview matches current controls.
    private var spatialPreviewRequestKey: String { "\(spatialTaskKey)/cut/\(spatialCutParametersKey)" }
    /// Prefers a complete active hierarchy, then a cached hierarchy, then a matching
    /// early preview. Never displays a preview computed for different cut settings.
    private var currentSpatial: ArtifactSpatialHierarchy? {
        if spatialLoadedKey == spatialTaskKey, let spatialHierarchy { return spatialHierarchy }
        if let cached = spatialCache[spatialTaskKey] { return cached }
        return spatialPreviewLoadedKey == spatialPreviewRequestKey ? spatialPreview : nil
    }
    /// Enables cutting only after a usable full or preview hierarchy is available.
    private var spatialCutTaskKey: String {
        currentSpatial != nil ? spatialPreviewRequestKey : ""
    }
    /// Returns a cut matching current controls from active state or the local cache.
    private var currentSpatialCut: ArtifactSpatialCut? {
        spatialCutLoadedKey == spatialCutTaskKey ? spatialCut : cutCache[spatialCutTaskKey]
    }
    /// Overlays manual session merges on the computed groups, removing overlapping
    /// original groups, then sorts by size. Merges here change browsing groups, not event data.
    private var spatialGroups: [ArtifactSpatialGroup] {
        var groups = currentSpatialCut?.groups ?? []
        for merged in manuallyMergedSpatialGroups {
            let ids = Set(merged.eventIDs)
            groups.removeAll { !ids.isDisjoint(with: $0.eventIDs) }
            groups.append(merged)
        }
        return groups.sorted {
            if $0.eventIDs.count == $1.eventIDs.count { return $0.id < $1.id }
            return $0.eventIDs.count > $1.eventIDs.count
        }
    }
    /// Exposes events that the current spatial cut could not assign to a family.
    private var spatialUnassignedIDs: [String] { currentSpatialCut?.unassignedIDs ?? [] }
    /// Chooses one nonzero amplitude limit for all visible spatial cards, based on
    /// canonical centroids or representative events according to the display mode.
    private var spatialCardScale: Double {
        switch spatialCardMapMode {
        case .centroid:
            return max(spatialGroups.compactMap { canonicalTopography(for: $0)?.maximumAbsoluteAmplitude }.max() ?? 1, 1e-9)
        case .representative:
            return max(spatialGroups.compactMap { group in
                currentAnalysis?.examples.first { $0.id == group.representativeID }?.topography?.maximumAbsoluteAmplitude
            }.max() ?? 1, 1e-9)
        }
    }
    /// Checks every unordered pair and returns the highest-similarity pair. IDs are
    /// for selection; indices supply current one-based display labels after sorting.
    private var closestSpatialGroups: (leftID: Int, rightID: Int, leftIndex: Int, rightIndex: Int, score: Double)? {
        guard let hierarchy = currentSpatial, spatialGroups.count >= 2 else { return nil }
        var best: (Int, Int, Int, Int, Double)?
        for left in 0..<(spatialGroups.count - 1) {
            for right in (left + 1)..<spatialGroups.count {
                let score = hierarchy.similarity(between: spatialGroups[left], and: spatialGroups[right])
                if best == nil || score > best!.4 {
                    best = (spatialGroups[left].id, spatialGroups[right].id, left, right, score)
                }
            }
        }
        return best.map { ($0.0, $0.1, $0.2, $0.3, $0.4) }
    }
    /// Resolves exactly one real family. The sentinel ID −1 means unassigned, not a family.
    private var selectedSpatialFamily: ArtifactSpatialGroup? {
        guard selectedSpatialGroupIDs.count == 1, let id = selectedSpatialGroupIDs.first, id != -1 else { return nil }
        return spatialGroups.first { $0.id == id }
    }
    /// Keys waveform grouping by its selected spatial family, event membership and
    /// polarity policy. No single family selected means no waveform hierarchy is requested.
    private var waveformTaskKey: String {
        guard usesSpatialGroups, let family = selectedSpatialFamily else { return "" }
        var hasher = Hasher()
        hasher.combine(family.eventIDs)
        return "\(spatialTaskKey)/waveform/\(family.id)/\(hasher.finalize())/\(waveformPolarityMode.rawValue)"
    }
    /// Uses only waveform grouping matching the current family, with local-cache fallback.
    private var currentWaveform: ArtifactWaveformGroupingResult? {
        !waveformTaskKey.isEmpty && waveformLoadedKey == waveformTaskKey ? waveformGrouping : waveformCache[waveformTaskKey]
    }
    /// Returns the subgroup filter, including the −1 unassigned sentinel. nil means
    /// no subgroup filter; an empty set means the chosen subgroup contains no events.
    private var waveformEventIDs: Set<String>? {
        guard let id = waveformGroupID, let result = currentWaveform else { return nil }
        return Set(id == -1 ? result.hierarchy.unassignedIDs
            : result.hierarchy.groups(minimumCorrelation: waveformThreshold).first { $0.id == id }?.eventIDs ?? [])
    }
    /// Unions members of selected spatial families, optionally including unassigned
    /// events. nil means no spatial filter rather than an empty selection result.
    private var spatialEventIDs: Set<String>? {
        guard usesSpatialGroups, !selectedSpatialGroupIDs.isEmpty else { return nil }
        var ids = Set<String>()
        for id in selectedSpatialGroupIDs {
            if id == -1 { ids.formUnion(spatialUnassignedIDs) }
            else { ids.formUnion(spatialGroups.first { $0.id == id }?.eventIDs ?? []) }
        }
        return ids
    }
    /// Filters by spatial/subgroup membership or fixed waveform band, then sorts
    /// by descending correlation and event time. Missing correlations sort after scored events.
    private var examples: [ArtifactReviewExample] {
        let spatialIDs = spatialEventIDs
        let waveformIDs = waveformEventIDs
        return (currentAnalysis?.examples ?? []).filter {
            if usesSpatialGroups {
                return (spatialIDs?.contains($0.id) ?? true) && (waveformIDs?.contains($0.id) ?? true)
            }
            return band == nil || $0.band == band
        }.sorted {
            if $0.correlation == $1.correlation { return $0.event.centerTimeSeconds < $1.event.centerTimeSeconds }
            return ($0.correlation ?? -2) > ($1.correlation ?? -2)
        }
    }
    /// Builds pagination from filtered examples and the selected event’s current position.
    private var navigation: ArtifactReviewNavigation {
        let items = examples
        return ArtifactReviewNavigation(count: items.count,
            selectedIndex: items.firstIndex { $0.id == selectedEventID } ?? 0)
    }
    /// Finds one nonzero scalp-map scale for the currently visible page of examples.
    private var topographyScale: Double {
        let items = examples
        let page = ArtifactReviewNavigation(count: items.count,
            selectedIndex: items.firstIndex { $0.id == selectedEventID } ?? 0).visibleRange
        return max(items[page].compactMap { $0.topography?.maximumAbsoluteAmplitude }.max() ?? 1, 1e-6)
    }
    /// Resolves the selected event within the current filter, falling back to its first example.
    private var selectedExample: ArtifactReviewExample? {
        examples.first { $0.id == selectedEventID } ?? examples.first
    }
    /// Keeps the chosen overview channel only if analysis supports it, otherwise uses the first.
    private var activeChannel: Int {
        currentAnalysis?.channelIndices.contains(channel) == true ? channel : currentAnalysis?.channelIndices.first ?? 0
    }
    /// Reads stored auto-selection rules or their defaults without applying any decisions.
    private var rules: ArtifactReviewRules { selected?.reviewState?.rules ?? ArtifactReviewRules() }

    /// Composes sidebar, analysis canvas and inspector, then attaches four keyed tasks
    /// for analysis, spatial hierarchy, cuts and waveform subgroups. onChange handlers
    /// clear incompatible browsing state; actual event decisions remain in artifact bindings.
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                classList
                Divider()
                if let artifact = selected {
                    VStack(spacing: 0) {
                        reviewHeader(artifact)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                if let result = currentAnalysis {
                                    if result.channelIndices.isEmpty {
                                        Text("No usable definition channels. Check the definition’s channel selection and marked-bad channels.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Picker("Group by", selection: $usesSpatialGroups) {
                                        Text("Waveforms").tag(false)
                                        Text("Spatial").tag(true)
                                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                                    if usesSpatialGroups {
                                        spatialGroupingCanvas(result)
                                        waveformGroupingPreview()
                                    }
                                    else { similarityGroups(result) }
                                    splitControls(artifact)
                                    eventWorkspace(artifact, result)
                                } else {
                                    ProgressView("Comparing detected examples…")
                                        .frame(maxWidth: .infinity, minHeight: 330)
                                }
                            }.padding(18)
                        }
                    }
                    Divider()
                    reviewInspector(artifact)
                } else {
                    ContentUnavailableView("No Detected Artifacts", systemImage: "waveform",
                        description: Text("Run an artifact detector or define an artifact, then review its matches here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Review selects the events used to fit and apply each artifact’s treatment.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Clean Artifacts…", action: onClean)
                    .disabled(!artifacts.contains { !$0.events.isEmpty })
            }.padding(16)
        }
        .frame(height: 770)
        // SwiftUI cancels/restarts each task when its ID changes. Separate keys let
        // a threshold adjustment recut an existing hierarchy without recomputing features.
        .task(id: analysisKey) { await loadAnalysis() }
        .task(id: spatialTaskKey) { await loadSpatialGrouping() }
        .task(id: spatialCutTaskKey) { await loadSpatialCut() }
        .task(id: waveformTaskKey) { await loadWaveformGrouping() }
        .onAppear {
            resetGroupingDefaults(for: selected)
            synchronizeArtifactSelection()
        }
        .onChange(of: waveformTaskKey) { _, _ in
            waveformGroupID = nil
        }
        .onChange(of: waveformThreshold) { _, _ in
            waveformGroupID = nil; selectedEventID = nil
        }
        .onChange(of: spatialCutTaskKey) { _, _ in
            clearSpatialSelection()
            manuallyMergedSpatialGroups = []
            selectedEventID = nil; showsSplit = false
        }
        .onChange(of: usesSpatialGroups) { _, _ in
            clearSpatialSelection(); band = nil; selectedEventID = nil; showsSplit = false
        }
        .onChange(of: analysisKey) { _, _ in
            ruleUndo = nil; clearSpatialSelection(); selectedEventID = nil; showsSplit = false
        }
        .onChange(of: selected?.id) { _, _ in
            synchronizeArtifactSelection()
            band = nil
            clearSpatialSelection()
            resetGroupingDefaults(for: selected)
            manuallyMergedSpatialGroups = []
            waveformPolarityOverride = nil
            selectedEventID = nil
            showsSplit = false
            ruleUndo = nil
        }
    }

    /// Displays reviewable artifact classes with multi-selection and batch-treatment
    /// status. The sidebar accepts a spatial-family drag to create an independent class.
    private var classList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("ARTIFACTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ArtifactReviewHelp(title: "Artifacts", text: "Click to inspect one artifact. Shift-click selects a contiguous range; Command-click or Control-click toggles individual artifacts. Treatment changes apply to every highlighted artifact. Drag a spatial family anywhere over this sidebar to extract it as a new top-level artifact.")
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
                ForEach(Array(reviewable.enumerated()), id: \.element.id) { index, artifact in
                    Button {
                        selectArtifact(artifact, at: index)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: artifactSymbol(artifact))
                                .frame(width: 16).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(artifact.name).font(.callout.weight(.medium)).lineLimit(2)
                                Text("\(ArtifactReviewEngine.candidates(for: artifact).count) examples")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(artifact.cleaningMethod == .doNothing ? "—" : artifact.cleaningMethod.rawValue)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(effectiveSelectedArtifactIDs.contains(artifact.id)
                            ? Color.accentColor.opacity(selected?.id == artifact.id ? 0.22 : 0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, artifact.reviewState?.sourceArtifactID != nil
                        && artifact.reviewState?.displaysAsStandaloneArtifact != true ? 10 : 0)
                }
            }.padding(10)
        }
        .frame(width: 195)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
        .overlay {
            if isSidebarDropTarget {
                ZStack {
                    Color.accentColor.opacity(0.10)
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.fill").font(.title2)
                        Text("Release to create artifact").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(3) }
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.utf8PlainText.identifier], isTargeted: $isSidebarDropTarget,
                perform: acceptSpatialFamilyDrop)
    }

    /// Shows current decisions and batch-selection count. Unreviewed events initially
    /// count as included, so unreviewed is not a mutually exclusive decision category.
    private func reviewHeader(_ artifact: DefinedArtifact) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.name).font(.title3.weight(.semibold))
                let choices = ArtifactReviewEngine.candidates(for: artifact).map { ArtifactReviewEngine.choice(for: $0.id, artifact: artifact).decision }
                HStack(spacing: 5) {
                    Text("\(choices.filter { $0 == .include }.count) included · \(choices.filter { $0 == .exclude }.count) excluded · \(choices.filter { $0 == .hold }.count) held · \(ArtifactReviewEngine.candidates(for: artifact).count - (artifact.reviewState?.choices.count ?? 0)) unreviewed")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    ArtifactReviewHelp(title: "Review counts", text: "Included events are eligible for cleaning. Held and excluded events stay out of the active cleaning event set. Unreviewed counts examples without an explicit decision; they initially remain included, so it overlaps the included count. Opening Review does not remove anything.")
                }
            }
            Spacer()
            if effectiveSelectedArtifactIDs.count > 1 {
                Text("\(effectiveSelectedArtifactIDs.count) artifacts selected")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    /// Builds treatment, grouping and auto-rule controls in collapsible sections.
    /// The proposed rule counts are a preview; Apply Rules commits them separately.
    private func reviewInspector(_ artifact: DefinedArtifact) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Inspector").font(.title3.weight(.semibold))
                    Spacer()
                    ArtifactReviewHelp(title: "Inspector", text: "The canvas stays focused on the data while treatment, grouping, and automatic-selection settings live here. Disclosure sections remember their state for this review session.")
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(effectiveSelectedArtifactIDs.count == 1
                        ? "TREATMENT" : "TREATMENT · \(effectiveSelectedArtifactIDs.count) SELECTED")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Menu {
                        ForEach(batchCleaningMethods) { method in
                            Button {
                                applyTreatment(method)
                            } label: {
                                Label(method.rawValue,
                                      systemImage: commonTreatment == method ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        HStack {
                            Text(commonTreatment?.rawValue ?? "Mixed")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    Text(effectiveSelectedArtifactIDs.count == 1
                        ? "Applied when you clean artifacts."
                        : "A change applies to every highlighted artifact.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if usesSpatialGroups {
                    Divider()
                    Text("Spatial Grouping").font(.headline)
                    DisclosureGroup(isExpanded: $showsSpatialEssentials) {
                        spatialEssentialsInspector
                            .padding(.top, 9)
                    } label: {
                        Text("Essentials").font(.callout.weight(.semibold))
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))

                    DisclosureGroup(isExpanded: $showsSpatialQuality) {
                        spatialQualityInspector
                            .padding(.top, 9)
                    } label: {
                        Text("Quality & Display").font(.callout.weight(.semibold))
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))

                    if selectedSpatialFamily != nil {
                        DisclosureGroup(isExpanded: $showsWaveformInspector) {
                            waveformInspector
                                .padding(.top, 9)
                        } label: {
                            Text("Waveform Subgroups").font(.callout.weight(.semibold))
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Divider()
                DisclosureGroup(isExpanded: $showsAutoSelection) {
                    autoRulesInspector(artifact)
                        .padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Auto-Selection").font(.callout.weight(.semibold))
                        if let result = currentAnalysis {
                            let proposed = result.examples.map {
                                ArtifactReviewEngine.proposedChoice(for: $0, artifact: artifact, rules: rules).decision
                            }
                            Text("\(proposed.filter { $0 == .include }.count) include · \(proposed.filter { $0 == .exclude }.count) exclude · \(proposed.filter { $0 == .hold }.count) hold")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(14)
        }
        .frame(width: 270)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.32))
    }

    /// Caps the requested family count by available features and the UI limit of 40.
    private var maximumSpatialFamilyCount: Int {
        max(1, min(40, currentSpatial?.features.count ?? 1))
    }

    /// Edits target count/cohesion, polarity and comparison mode. Polarity changes
    /// also clear waveform overrides and selections that depended on the old orientation.
    private var spatialEssentialsInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Grouping", selection: $spatialGroupingControl) {
                ForEach(ArtifactSpatialGroupingControl.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            if spatialGroupingControl == .targetCount {
                HStack(spacing: 4) {
                    Text("Families")
                    Spacer()
                    ForEach(1...3, id: \.self) { count in
                        Button("\(count)") { spatialTargetCount = count }
                            .buttonStyle(.bordered)
                            .tint(spatialTargetCount == count ? .accentColor : .secondary)
                            .controlSize(.small)
                            .disabled(count > maximumSpatialFamilyCount)
                            .accessibilityLabel("Set \(count) spatial families")
                    }
                    Stepper("\(spatialTargetCount)", value: $spatialTargetCount,
                        in: 1...maximumSpatialFamilyCount)
                        .labelsHidden()
                    Text("\(spatialTargetCount)").monospacedDigit().frame(width: 24, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Cohesion")
                        Spacer()
                        Text("\(spatialScoreLabel) ≥ \(spatialThreshold, specifier: "%.2f")")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $spatialThreshold, in: 0.50...0.98, step: 0.01)
                }
            }

            Picker("Polarity", selection: Binding(
                get: { spatialPolarityMode },
                set: { value in
                    spatialPolarityOverride = value
                    waveformPolarityOverride = nil
                    clearSpatialSelection(); selectedEventID = nil
                }
            )) {
                ForEach(ArtifactSpatialPolarityMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            Picker("Comparison", selection: $spatialSimilarityMetric) {
                ForEach(ArtifactSpatialSimilarityMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: spatialSimilarityMetric) { _, _ in
                clearSpatialSelection(); selectedEventID = nil
            }
        }
        .font(.caption)
    }

    /// Edits cohesion/outlier policy and card-map display. A completed hierarchy
    /// can suggest a target count without rebuilding the underlying feature comparisons.
    private var spatialQualityInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Cohesion rule", selection: $spatialCohesionRule) {
                ForEach(ArtifactSpatialCohesionRule.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Outlier floor")
                    Spacer()
                    Text("\(spatialOutlierFloor, specifier: "%.2f")")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $spatialOutlierFloor, in: 0.40...0.85, step: 0.01)
            }

            Picker("Card maps", selection: $spatialCardMapMode) {
                ForEach(ArtifactSpatialCardMapMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            if spatialGroupingControl == .targetCount, let hierarchy = currentSpatial, hierarchy.isComplete {
                let suggested = hierarchy.suggestedTargetCount(
                    maximum: min(40, hierarchy.features.count), cohesionRule: spatialCohesionRule)
                Button("Use suggested count: \(suggested)") { spatialTargetCount = suggested }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    /// Controls waveform subgroup orientation and threshold within one spatial family.
    /// These settings filter browsing; they do not themselves include or exclude events.
    private var waveformInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Polarity", selection: Binding(
                get: { waveformPolarityMode },
                set: { value in
                    waveformPolarityOverride = value
                    waveformGroupID = nil; selectedEventID = nil
                }
            )) {
                ForEach(ArtifactWaveformPolarityMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .disabled(spatialPolarityMode == .signed)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Cohesion")
                    Spacer()
                    Text("r ≥ \(waveformThreshold, specifier: "%.2f")")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $waveformThreshold, in: 0.65...0.98, step: 0.01)
            }
        }
        .font(.caption)
    }

    /// Provides compact rule controls plus apply/undo actions. Before committing
    /// proposals, saves the prior choices so Undo can restore automatic decisions.
    private func autoRulesInspector(_ artifact: DefinedArtifact) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Include when r ≥ \(rules.includeCorrelation, specifier: "%.2f")")
                Slider(value: ruleBinding(\.includeCorrelation), in: 0.50...0.99, step: 0.01)
                Text("Exclude when r < \(rules.excludeCorrelation, specifier: "%.2f")")
                Slider(value: ruleBinding(\.excludeCorrelation), in: -1...0.95, step: 0.01)
            }
            HStack {
                Toggle("Maximum peak", isOn: ruleBinding(\.limitsPeak)).toggleStyle(.checkbox)
                Spacer()
                TextField("µV", value: ruleBinding(\.maximumPeakMicrovolts), format: .number)
                    .frame(width: 58).disabled(!rules.limitsPeak)
            }
            HStack {
                Toggle("Maximum duration", isOn: ruleBinding(\.limitsDuration)).toggleStyle(.checkbox)
                Spacer()
                TextField("s", value: ruleBinding(\.maximumDurationSeconds), format: .number)
                    .frame(width: 58).disabled(!rules.limitsDuration)
            }
            Toggle("Require complete padded window", isOn: ruleBinding(\.requiresCompleteWindow))
                .toggleStyle(.checkbox)
            Toggle("Measured span must fit core", isOn: ruleBinding(\.requiresSpanInsideCore))
                .toggleStyle(.checkbox)
            Toggle("Keep manual decisions", isOn: ruleBinding(\.preservesManualChoices))
                .toggleStyle(.checkbox)
            HStack {
                Button("Undo", action: undoRules).disabled(ruleUndo == nil)
                Spacer()
                Button("Apply Rules") {
                    guard let result = currentAnalysis else { return }
                    ruleUndo = selected?.reviewState?.choices ?? [:]
                    edit { ArtifactReviewEngine.applyRules(rules, analysis: result, artifact: &$0) }
                }
                .disabled(currentAnalysis == nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.caption)
    }

    /// Builds the expanded rule panel with explanations and live proposed counts.
    /// Changing thresholds stores rule settings; Apply rules changes active event choices.
    private func autoRules(_ artifact: DefinedArtifact) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text("Include when r ≥ \(rules.includeCorrelation, specifier: "%.2f")").font(.caption)
                            ArtifactReviewHelp(title: "Include threshold", text: "r is signed waveform-shape correlation across the definition channels, after centering each channel. Values near 1 have a similar shape and polarity; negative values have opposite polarity. Scores at or above this threshold are proposed for inclusion unless a safety limit excludes them. Changing a slider only changes the preview until Apply rules.")
                        }
                        Slider(value: ruleBinding(\.includeCorrelation), in: 0.50...0.99, step: 0.01)
                        HStack(spacing: 5) {
                            Text("Exclude when r < \(rules.excludeCorrelation, specifier: "%.2f")").font(.caption)
                            ArtifactReviewHelp(title: "Exclude threshold", text: "Scores below this threshold are proposed for exclusion. Scores between the two thresholds are held for review. Examples without a usable similarity score are also held, unless a safety limit excludes them. This is a shape score, not a probability that an event is an artifact.")
                        }
                        Slider(value: ruleBinding(\.excludeCorrelation), in: -1...0.95, step: 0.01)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            HStack(spacing: 5) {
                                Toggle("Max peak (µV)", isOn: ruleBinding(\.limitsPeak)).toggleStyle(.checkbox)
                                ArtifactReviewHelp(title: "Maximum peak", text: "When checked, propose exclusion if the largest absolute, baseline-centered amplitude in the core window across the definition channels exceeds this value. This gate is applied before similarity thresholds. It does not measure every channel in the recording.")
                            }
                            TextField("µV", value: ruleBinding(\.maximumPeakMicrovolts), format: .number)
                                .frame(width: 65).disabled(!rules.limitsPeak)
                        }
                        HStack {
                            HStack(spacing: 5) {
                                Toggle("Max duration (s)", isOn: ruleBinding(\.limitsDuration)).toggleStyle(.checkbox)
                                ArtifactReviewHelp(title: "Maximum duration", text: "When checked, propose exclusion for measured event durations longer than this limit. Duration is the detector’s measured span when available, not the correction-window width. Unknown durations do not trigger this gate.")
                            }
                            TextField("Seconds", value: ruleBinding(\.maximumDurationSeconds), format: .number)
                                .frame(width: 65).disabled(!rules.limitsDuration)
                        }
                        HStack(spacing: 5) {
                            Toggle("Require complete padded window", isOn: ruleBinding(\.requiresCompleteWindow)).toggleStyle(.checkbox)
                            ArtifactReviewHelp(title: "Complete padded window", text: "Require the core correction window plus its edge taper to fit inside the recording. Events too close to the recording boundaries are proposed for exclusion. The cleaner skips incomplete padded windows even if manually included.")
                        }
                        HStack(spacing: 5) {
                            Toggle("Measured span must fit core", isOn: ruleBinding(\.requiresSpanInsideCore)).toggleStyle(.checkbox)
                            ArtifactReviewHelp(title: "Measured span and core", text: "For threshold detections with known onset and offset, propose exclusion if their measured span extends outside the core correction window. Unknown spans do not trigger this gate. Widen Core (s) if the correction window is too short.")
                        }
                    }.font(.caption)
                }
                HStack {
                    if let result = currentAnalysis {
                        let choices = result.examples.map { ArtifactReviewEngine.proposedChoice(for: $0, artifact: artifact, rules: rules).decision }
                        Text("Preview: \(choices.filter { $0 == .include }.count) include · \(choices.filter { $0 == .exclude }.count) exclude · \(choices.filter { $0 == .hold }.count) hold")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Toggle("Keep manual decisions", isOn: ruleBinding(\.preservesManualChoices))
                        ArtifactReviewHelp(title: "Keep manual decisions", text: "Preserve Include, Hold, or Exclude choices made by hand when applying rules. Turn this off to let the new rules replace those choices too. Undo rules restores earlier automatic choices and keeps subsequent manual decisions.")
                    }
                        .toggleStyle(.checkbox).font(.caption)
                    Button("Undo rules", action: undoRules).disabled(ruleUndo == nil)
                    Button("Apply rules") {
                        guard let result = currentAnalysis else { return }
                        ruleUndo = selected?.reviewState?.choices ?? [:]
                        edit { ArtifactReviewEngine.applyRules(rules, analysis: result, artifact: &$0) }
                    }.disabled(currentAnalysis == nil)
                }
                Text("Middle scores stay on hold. Unusable or flat examples have no similarity score. Peak and shape metrics use the selected definition channels; unknown durations/spans do not trigger those limits.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(5)
        } label: {
            HStack(spacing: 5) {
                Text("Auto-selection · preview before applying").font(.callout.weight(.medium))
                ArtifactReviewHelp(title: "Auto-selection", text: "These rules propose Include, Hold, or Exclude choices. Preview counts reflect the current rules and any protected manual choices. Apply rules commits the choices to this class and changes which events feed cleaning; it does not clean the recording. Undo rules reverses the last rule application while preserving manual decisions.")
            }
        }
    }

    /// Renders family cards, closest-pair suggestions, merge actions and unassigned
    /// events. Cards select/filter examples; drag payloads move membership only when dropped.
    private func spatialGroupingCanvas(_ result: ArtifactReviewAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("Topographic families").font(.headline)
                        ArtifactReviewHelp(title: "Spatial families", text: "Families are a preview of spatially similar matched events. Shift-click selects a range; Command-click or Control-click toggles individual families. Drag any selected family anywhere over the artifact sidebar to extract the entire selection into a new top-level artifact.")
                    }
                    if let hierarchy = currentSpatial, currentSpatialCut != nil {
                        Text("\(spatialGroups.count) families · \(hierarchy.features.count) mapped · \(spatialUnassignedIDs.count) unassigned · \(hierarchy.channels.count) shared sensors")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if !hierarchy.isComplete {
                            Text("Families ready · completing hierarchy in the background…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if selectedSpatialGroupIDs.filter({ $0 != -1 }).count >= 2 {
                    Button("Merge Selected") { mergeSpatialGroups(Array(selectedSpatialGroupIDs)) }
                        .controlSize(.small)
                }
                if !manuallyMergedSpatialGroups.isEmpty {
                    Button("Clear Merges") {
                        manuallyMergedSpatialGroups = []; clearSpatialSelection()
                    }
                    .controlSize(.small)
                }
            }

            if let hierarchy = currentSpatial, currentSpatialCut != nil {
                if let duplicate = closestSpatialGroups {
                    HStack(spacing: 8) {
                        Label("\(duplicate.score >= 0.90 ? "Likely duplicate" : "Closest pair"): Families \(duplicate.leftIndex + 1) + \(duplicate.rightIndex + 1) · \(spatialScoreLabel) \(duplicate.score, specifier: "%.2f")",
                              systemImage: duplicate.score >= 0.90 ? "rectangle.on.rectangle" : "arrow.left.and.right")
                            .font(.caption).foregroundStyle(duplicate.score >= 0.90 ? .orange : .secondary)
                        Spacer()
                        Button("Select") { selectSpatialPair(duplicate.leftID, duplicate.rightID) }
                            .controlSize(.small)
                        Button("Merge") { mergeSpatialGroups([duplicate.leftID, duplicate.rightID]) }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165, maximum: 230), spacing: 10)], spacing: 10) {
                    ForEach(Array(spatialGroups.enumerated()), id: \.element.id) { index, group in
                        let example = result.examples.first { $0.id == group.representativeID }
                        Button {
                            selectSpatialGroup(group, at: index)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Family \(index + 1)").font(.callout.weight(.semibold))
                                    Spacer()
                                    Text("\(group.eventIDs.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                ArtifactReviewTopomapPreview(
                                    topography: spatialCardMapMode == .centroid ? canonicalTopography(for: group) : example?.topography,
                                    layout: sensorLayout, scale: spatialCardScale)
                                    .frame(height: 96)
                                Text(spatialCardMapMode == .centroid ? "Canonical centroid" : "Representative event")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if group.polarityMode == .ignoreGlobalPolarity {
                                    let counts = displayedOrientationCounts(group)
                                    Text("+ \(counts.positive) · − \(counts.negative)")
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                        .help("Orientation relative to the displayed canonical centroid; raw event maps are unchanged.")
                                }
                                Text(group.eventIDs.count == 1 ? "Single example" : String(format: "min %.2f · p10 %.2f · med %.2f", group.minimumCorrelation, group.tenthPercentileCorrelation, group.medianCorrelation))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(selectedSpatialGroupIDs.contains(group.id)
                                ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.028),
                                in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedSpatialGroupIDs.contains(group.id)
                                        ? Color.accentColor : Color.primary.opacity(0.07), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .onDrag { spatialFamilyDragProvider(group, familyNumber: index + 1) }
                    }
                    if !spatialUnassignedIDs.isEmpty {
                        Button {
                            clearSpatialSelection(); selectedSpatialGroupIDs = [-1]
                            selectedEventID = spatialUnassignedIDs.first; eventFocus = true
                        } label: {
                            ContentUnavailableView("Unassigned", systemImage: "questionmark.circle",
                                description: Text("\(spatialUnassignedIDs.count) examples"))
                                .frame(maxWidth: .infinity, minHeight: 165)
                                .background(selectedSpatialGroupIDs.contains(-1)
                                    ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if hierarchy.features.isEmpty {
                    Text("No comparable spatial features. Check the sensor layout, complete windows, and common good channels.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView(currentSpatial == nil ? "Building spatial hierarchy in the background…" : "Refining spatial groups in the background…")
                    .font(.caption).frame(maxWidth: .infinity, minHeight: 140)
            }
        }
    }

    /// Displays waveform subgroups only within one selected spatial family, or
    /// explains why no subgroup view is available. Selection updates the event filter.
    @ViewBuilder
    private func waveformGroupingPreview() -> some View {
        if selectedSpatialFamily != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("Waveform subgroups · selected spatial family").font(.callout.weight(.medium))
                    ArtifactReviewHelp(title: "Waveform subgroups", text: "These groups compare temporal shapes only within the spatial family you selected; they cannot combine events from different spatial families. Up to five definition channels are chosen by typical normalized energy across this family and remain fixed across its events. Profiles use up to 64 points per channel, centered separately, then normalized together so overall strength is ignored while relative channel amplitudes and polarity are preserved. Each event is aligned to the family's representative usable waveform using a small shared time shift, at most 20 ms and four profile points; the same interior support is used for every event. This tolerates small timing errors without stretching the waveform. The broader/finer control uses minimum signed correlation to each subgroup centroid. Previews show the normalized aligned mean in blue and a real representative in gray on the labeled channel. Cohesion is descriptive and includes group members themselves; it is not independent confidence or an artifact probability. Incomplete, nonfinite, or flat waveforms remain unassigned. The hierarchy is built off the main thread and cached. Selecting a subgroup filters the examples only; cleaning, decisions, and original waveform confidence scores remain unchanged.")
                    Spacer()
                    Text("Adjust in Inspector").font(.caption).foregroundStyle(.secondary)
                }
                if let result = currentWaveform {
                    ArtifactWaveformSubgroupCards(result: result, threshold: waveformThreshold,
                        preferredChannel: activeChannel, selectedGroupID: $waveformGroupID) { eventID in
                        selectedEventID = eventID; eventFocus = true
                    }
                    let labels = result.channelIndices.map(channelName).joined(separator: ", ")
                    Text("Channels: \(labels.isEmpty ? "none usable" : labels) · alignment up to ±\(result.maximumAlignmentSeconds * 1000, specifier: "%.0f") ms · normalized shapes\(result.polarityMode == .orientToSpatialFamily ? " · \(result.reorientedEventCount) polarity-oriented" : "")")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView("Building waveform subgroups in the background…")
                        .font(.caption).frame(maxWidth: .infinity, minHeight: 90)
                }
            }
        } else if selectedSpatialGroupIDs.filter({ $0 != -1 }).count > 1 {
            Text("Multiple spatial families selected. Merge them for one combined waveform hierarchy, or move them together into a separate artifact class.")
                .font(.caption).foregroundStyle(.secondary)
        } else if selectedSpatialGroupIDs.isEmpty, currentSpatial?.features.isEmpty == false {
            Text("Select a spatial group to explore its waveform subgroups.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Shows fixed waveform-similarity bands with mean/example traces. Clicking
    /// a band filters browsing and focuses keyboard navigation without changing decisions.
    private func similarityGroups(_ result: ArtifactReviewAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("Waveform similarity bands").font(.caption.weight(.medium))
                ArtifactReviewHelp(title: "Similarity groups", text: "Click a card to filter examples by shape. Close match is r ≥ 0.90; Shape variation is 0.75 ≤ r < 0.90; Low similarity is r < 0.75. These fixed browsing bands do not change with the auto-selection sliders and do not include or exclude events by themselves. Blue is that group’s mean; gray traces show up to eight examples on the displayed channel. Unscored examples are available under All.")
            }
            HStack(spacing: 10) {
                ForEach(ArtifactReviewBand.allCases) { value in
                    let members = result.examples.filter { $0.band == value }
                    Button {
                        band = value
                        selectedEventID = members.sorted { ($0.correlation ?? -2) > ($1.correlation ?? -2) }.first?.id
                        eventFocus = true
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(value.rawValue).font(.callout.weight(.medium))
                            if members.isEmpty {
                                Text("No examples").font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 55)
                            } else {
                                ArtifactReviewTracePlot(
                                    traces: members.prefix(8).map { result.waveform($0.samples, channel: activeChannel) },
                                    reference: result.meanWaveform(of: members, channel: activeChannel))
                                    .frame(height: 55)
                            }
                            Text("\(members.count) examples · \(bandDescription(value))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(band == value ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(members.isEmpty)
                }
            }
        }
    }

    /// Presents controls to move the current filtered examples into a compatible
    /// existing class or a new class. The full-set/empty-set guards prevent meaningless splits.
    @ViewBuilder
    private func splitControls(_ artifact: DefinedArtifact) -> some View {
        let hasGroupSelection = usesSpatialGroups ? !selectedSpatialGroupIDs.isEmpty : band != nil
        HStack {
            Button("All \(currentAnalysis?.examples.count ?? 0)") {
                band = nil; clearSpatialSelection(); eventFocus = true
            }
            if usesSpatialGroups, !selectedSpatialGroupIDs.isEmpty {
                Text(selectedSpatialGroupIDs.contains(-1) ? "Spatially unassigned"
                    : selectedSpatialGroupIDs.count > 1 ? "\(selectedSpatialGroupIDs.count) spatial families · \(examples.count) examples"
                    : waveformGroupID == nil ? "Spatial family · \(examples.count) examples"
                    : waveformGroupID == -1 ? "Waveform unassigned · \(examples.count) examples"
                    : "Waveform subgroup · \(examples.count) examples")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let band { Text(band.rawValue).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Move selection to class…", systemImage: "arrow.triangle.branch") {
                splitName = "\(artifact.name) variation"
                splitMethod = .obs
                splitDestinationID = nil
                showsSplit = true
            }
            .disabled(!hasGroupSelection || examples.isEmpty || examples.count == ArtifactReviewEngine.candidates(for: artifact).count)
            ArtifactReviewHelp(title: "Move into a class", text: "Choose one or more spatial families, a waveform subgroup, or a waveform-similarity card. Move every filtered event into a new class, an existing sibling, or the other threshold ocular category (for example Eye Blinks to Eye Movements). Events leave the current class, carry their decisions, and retain their detector origin, so one occurrence cannot train or receive correction from both classes. Each destination has its own average and treatment. This does not perform cleaning.")
        }
        if showsSplit {
            HStack(alignment: .bottom) {
                Picker("Destination", selection: $splitDestinationID) {
                    Text("New class").tag(UUID?.none)
                    ForEach(compatibleSplitDestinations) { destination in
                        Text(destination.name).tag(Optional(destination.id))
                    }
                }.frame(width: 190)
                if splitDestinationID == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New class name").font(.caption)
                        TextField("Artifact variation", text: $splitName)
                    }
                    Picker("Treatment", selection: $splitMethod) {
                        Text("OBS").tag(ArtifactCleaningMethod.obs)
                        Text("SSP/PCA").tag(ArtifactCleaningMethod.sspPCA)
                        Text("Regress").tag(ArtifactCleaningMethod.regression)
                    }.frame(width: 150)
                }
                Text("Move \(examples.count) events; rebuild source and destination averages.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { showsSplit = false }
                Button(splitDestinationID == nil ? "Create class" : "Move to class", action: splitClass)
            }
        }
    }

    /// Combines paged example tiles, decision buttons, detailed traces and reference
    /// rebuilding. Keyboard focus routes arrows/space to review navigation. Display
    /// controls affect plots; decision and reference actions call the review engine.
    private func eventWorkspace(_ artifact: DefinedArtifact, _ result: ArtifactReviewAnalysis) -> some View {
        let browsedExamples = examples
        let mapScale = topographyScale
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("Individual examples · best match first").font(.caption.weight(.medium))
                    ArtifactReviewHelp(title: "Browse examples", text: "Examples are sorted from highest to lowest similarity, with unscored examples last. Each tile shows event time in seconds, waveform or peak-GFP topomap, an uncalibrated waveform shape-match score out of 100, and the current decision. The selected example explains the score and its supporting reference count. Click a tile to inspect it. With multiple sets, arrow buttons and left/right keys move between sets of eighteen and select the first example in the destination set. With one set, the detail arrows and keys move one example at a time. Click a tile or navigation arrow to focus keyboard navigation; Space toggles Include/Exclude.")
                }
                Picker("Exemplar preview", selection: $tilePreview) {
                    ForEach(ArtifactReviewTilePreview.allCases) { preview in Text(preview.rawValue).tag(preview) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if tilePreview == .topomaps {
                    HStack(spacing: 4) {
                        Group {
                            if sensorLayout == nil { Text("Sensor layout required") }
                            else { Text("Peak GFP · page scale ±\(mapScale, specifier: "%.1f") µV") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        ArtifactReviewHelp(title: "Exemplar topomaps", text: "Each map shows the instant of greatest global field power (spatial standard deviation) within that event’s core. The core mean is removed per channel, then the map is average-referenced across finite, mapped good channels. Bad/interpolated and nonfinite-core channels are omitted. All eighteen tiles share one color scale for the current page. Red and blue show opposite signed potentials, not good versus bad. A flat map, incomplete core, fewer than three valid sensors, or missing sensor coordinates shows Unavailable. The timestamps on tiles are event times; the larger selected map shows its peak time. The Wave match score, example ordering, auto-selection rules, and Waveform bands use waveform correlation. Spatial groups are a separate preview based on normalized signed electrode values. Switching thumbnail views does not change decisions or grouping.")
                    }
                }
                let navigation = navigation
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Array(browsedExamples[navigation.visibleRange])) { example in
                        Button {
                            selectedEventID = example.id
                            eventFocus = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(example.event.centerTimeSeconds, format: .number.precision(.fractionLength(2)))
                                    .font(.caption2.monospacedDigit())
                                if tilePreview == .waveforms {
                                    ArtifactReviewTracePlot(
                                        traces: [result.waveform(example.samples, channel: activeChannel)],
                                        reference: result.waveform(result.reference, channel: activeChannel))
                                        .frame(height: 54)
                                } else {
                                    ArtifactReviewTopomapPreview(topography: example.topography,
                                        layout: sensorLayout, scale: mapScale)
                                        .frame(height: 54)
                                }
                                Text(example.matchConfidence.score.map { "\(tilePreview == .topomaps ? "Wave" : "Match") \($0)/100" } ?? "Match unavailable")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(confidenceColor(example.matchConfidence))
                                    .help(example.matchConfidence.explanation)
                                Text(ArtifactReviewEngine.choice(for: example.id, artifact: artifact).decision.rawValue.capitalized)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            .background(selectedExample?.id == example.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Button { move(-1, byPage: true) } label: { Image(systemName: "chevron.left") }
                        .disabled(navigation.destination(-1, byPage: true) == nil)
                        .accessibilityLabel("Previous set").help("Previous set of examples")
                    Spacer()
                    Text(examples.isEmpty ? "No examples" : "Set \(navigation.page + 1) of \(navigation.pageCount) · \(navigation.visibleRange.lowerBound + 1)–\(navigation.visibleRange.upperBound) of \(examples.count)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { move(1, byPage: true) } label: { Image(systemName: "chevron.right") }
                        .disabled(navigation.destination(1, byPage: true) == nil)
                        .accessibilityLabel("Next set").help("Next set of examples")
                }
            }.frame(width: 290)
            VStack(alignment: .leading, spacing: 9) {
                if let example = selectedExample {
                    HStack {
                        Text("Event at \(example.event.centerTimeSeconds, specifier: "%.3f") s").font(.callout.weight(.medium))
                        Spacer()
                        Button { move(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(navigation.destination(-1) == nil)
                            .accessibilityLabel(navigation.pageCount > 1 ? "Previous set" : "Previous example")
                            .help(navigation.pageCount > 1 ? "Previous set of eighteen examples" : "Previous example")
                        Button { move(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(navigation.destination(1) == nil)
                            .accessibilityLabel(navigation.pageCount > 1 ? "Next set" : "Next example")
                            .help(navigation.pageCount > 1 ? "Next set of eighteen examples" : "Next example")
                    }
                    confidenceSummary(example)
                    HStack(spacing: 5) {
                        Text(metricDescription(example)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        ArtifactReviewHelp(title: "Example metrics", text: "r measures signed multichannel shape similarity to the class reference, not artifact probability. Peak is the largest absolute baseline-centered core amplitude across the definition channels. Span is the measured detector duration when available. The detail plot can show one channel or the top 3/5 impacted channels. Display controls do not change multichannel scoring.")
                    }
                    HStack {
                        ForEach(ArtifactReviewDecision.allCases, id: \.self) { decision in
                            Button(decision.rawValue.capitalized) { choose(decision) }
                                .tint(ArtifactReviewEngine.choice(for: example.id, artifact: artifact).decision == decision ? .accentColor : .secondary)
                        }
                        ArtifactReviewHelp(title: "Include, Hold, Exclude", text: "Include makes an event eligible for this class’s treatment. Hold leaves an uncertain event out of cleaning until you decide. Exclude leaves it out of this class’s treatment. These choices do not delete the detected candidate or alter the recording immediately. Use Clean → Apply to run the selected treatment. Space toggles Include and Exclude for the selected tile.")
                    }
                    Text(navigation.pageCount > 1 ? "← → Previous / next set · Click a tile to select · Space Include / exclude" : "← → Previous / next example · Space Include / exclude").font(.caption2).foregroundStyle(.secondary)
                    if tilePreview == .topomaps {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Selected exemplar · peak-GFP topography").font(.caption.weight(.medium))
                            ArtifactReviewTopomapPreview(topography: example.topography,
                                layout: sensorLayout, scale: mapScale, showsScale: true)
                                .frame(height: 220)
                            if let map = example.topography {
                                Text("Map at \(map.timeSeconds, specifier: "%.3f") s · \((map.timeSeconds - example.event.centerTimeSeconds) * 1000, specifier: "%+.0f") ms from event · \(map.channelIndices.count) channels")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    eventDisplay(artifact, example, result)
                    HStack(spacing: 12) {
                        Label("Event", systemImage: "waveform").foregroundStyle(.primary)
                        Label("Class average", systemImage: "line.diagonal").foregroundStyle(.blue)
                        Label("Core / taper", systemImage: "rectangle.fill").foregroundStyle(.secondary)
                    }.font(.caption2)
                    HStack {
                        Picker("Overview", selection: $channel) {
                            ForEach(result.channelIndices, id: \.self) { index in Text(channelName(index)).tag(index) }
                        }
                        Text("Core (s)").font(.caption)
                        TextField("Seconds", value: Binding(
                            get: { selected?.windowSizeSeconds ?? 0.5 },
                            set: { value in edit { $0.windowSizeSeconds = min(max(value.isFinite ? value : 0.5, 0.1), 5) } }
                        ), format: .number.precision(.fractionLength(2))).frame(width: 55)
                        ArtifactReviewHelp(title: "Display channel and correction window", text: "Overview selects the channel used for similarity cards, tiles, the class-average preview, and Single mode. Top 3/5 ranks good recording channels for the selected event by peak-to-peak amplitude inside the core, without DC offsets or surrounding context affecting that order. Core (s) changes the correction-window duration for the whole artifact class and recomputes its similarity analysis. Blue shading marks the core, pale cyan the added edge taper, and orange the measured threshold span when available. The vertical marker is the event center; the dashed blue trace is the class average.")
                    }
                    Text(example.hasCompleteWindow ? (example.spanInsideCore == false ? "Measured span extends beyond the core window." : "Complete padded correction window.") : "Incomplete recording-edge window; the cleaner skips this event.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        HStack(spacing: 5) {
                            Text("Class average · \(result.referenceCount) examples").font(.caption)
                            ArtifactReviewHelp(title: "Class average", text: "Blue shows the reference average; gray traces show up to sixteen candidates, including held and excluded examples. The reference initially uses all usable examples and stays fixed while you make decisions. Rebuild from included recomputes it using included examples and refreshes similarity scores. Reference members are scored against an average that leaves themselves out, so an event cannot artificially improve its own match score.")
                        }
                        Spacer()
                        Button("Rebuild from included") {
                            edit(invalidates: false) { ArtifactReviewEngine.rebuildReference(&$0) }
                        }.disabled(artifact.events.isEmpty)
                    }
                    ArtifactReviewTracePlot(
                        traces: result.examples.prefix(16).map { result.waveform($0.samples, channel: activeChannel) },
                        reference: result.waveform(result.reference, channel: activeChannel))
                        .frame(height: 95)
                    Text("Signed shape correlation across definition channels; members are scored against a leave-one-out average. The reference stays fixed until rebuilt.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ContentUnavailableView("No Examples in This Group", systemImage: "waveform",
                        description: Text("Choose All to inspect unscored or other examples."))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusable().focused($eventFocus)
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.space) {
            guard let artifact = selected, let example = selectedExample else { return .ignored }
            choose(ArtifactReviewEngine.choice(for: example.id, artifact: artifact).decision == .include ? .exclude : .include)
            return .handled
        }
    }

    /// Selects one overview channel or the event’s most impacted channels, then draws
    /// them with a shared time/amplitude scale and raw surrounding context. Context
    /// changes do not alter correction windows or multichannel similarity scoring.
    private func eventDisplay(_ artifact: DefinedArtifact, _ example: ArtifactReviewExample,
                              _ result: ArtifactReviewAnalysis) -> some View {
        let displayed = displayMode == .single ? [activeChannel]
            : Array(example.impactedChannels.prefix(displayMode.channelLimit).map(\.channelIndex))
        let window = ArtifactReviewEngine.contextWindow(for: example.event, artifact: artifact,
            signal: signal, contextSeconds: contextSeconds)
        let scale = window.map { ArtifactReviewEngine.displayScale(channels: displayed, window: $0,
            signal: signal, analysis: result) } ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Display channels", selection: $displayMode) {
                    ForEach(ArtifactReviewDisplayMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Picker("Context", selection: $contextSeconds) {
                    ForEach([0.25, 0.5, 1.0, 2.0], id: \.self) { seconds in
                        Text("\(seconds, specifier: "%g") s each side").tag(seconds)
                    }
                }
                ArtifactReviewHelp(title: "Multi-channel context", text: "Top 3 and Top 5 show the good recording channels with the largest peak-to-peak amplitude within this event’s core window, ranked separately for each event. Bad/interpolated channels, flat channels, incomplete cores, and channels with nonfinite core samples are omitted. The rows share a time axis and amplitude scale so their timing, polarity, and strength can be compared. Context adds raw data before and after the padded window; it does not change detection, scoring, or the correction window. The class-average overlay is available on definition channels; other channels show the event only. Overview controls the thumbnails and Single mode. Scroll down to see all rows; recording-edge gaps remain blank.")
            }
            if displayMode != .single {
                Text("\(displayed.count) most impacted channel\(displayed.count == 1 ? "" : "s") · ranked for this event · shared µV scale")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let window, !displayed.isEmpty {
                ForEach(displayed, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(channelName(index)).font(.caption.weight(.semibold))
                            if let impact = example.impactedChannels.first(where: { $0.channelIndex == index }) {
                                Text("\(impact.peakToPeakMicrovolts, specifier: "%.1f") µV p–p")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !result.channelIndices.contains(index) {
                                Text("Event only · outside definition channels")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        ArtifactReviewEventPlot(artifact: artifact, example: example, analysis: result,
                            signal: signal, channel: index, window: window, sharedScale: scale)
                            .frame(height: displayMode == .single ? 180 : 105)
                    }
                }
            } else {
                Text("No usable channels with a complete, non-flat core window for this event.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Displays the waveform match score and reference support, including missing
    /// score explanations. This is shape similarity, not a calibrated artifact probability.
    private func confidenceSummary(_ example: ArtifactReviewExample) -> some View {
        let confidence = example.matchConfidence
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Waveform similarity").font(.caption.weight(.semibold))
                ArtifactReviewHelp(title: "Waveform similarity", text: "This is a transparent shape-match score, not the probability that an event is an artifact. It is the positive part of signed multichannel correlation × 100, rounded to a whole number: r = 0.92 gives 92/100; opposite polarity gives 0. The score is withheld for incomplete correction windows, unusable waveforms, missing independent references, or undefined correlation. Reference members are compared to an average that excludes themselves. Limited reference means only one or two comparison examples; even a high score then has little supporting evidence. Decisions and cleaning remain controlled by your rules and manual choices.")
                Spacer()
                Text(confidence.score.map { "\($0)/100" } ?? "Unavailable")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(confidenceColor(confidence))
            }
            if let score = confidence.score {
                ProgressView(value: Double(score), total: 100)
                    .tint(confidenceColor(confidence))
                    .accessibilityLabel("Waveform similarity score")
                    .accessibilityValue("\(score) out of 100")
            }
            Text(confidence.explanation).font(.caption)
            if confidence.referenceCount > 0 {
                Text("Compared with \(confidence.referenceCount) other reference example\(confidence.referenceCount == 1 ? "" : "s")\(confidence.hasLimitedReference ? " · Limited reference" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Maps available match scores to display bands; absent scores use secondary styling.
    private func confidenceColor(_ confidence: ArtifactReviewMatchConfidence) -> Color {
        guard let score = confidence.score else { return .secondary }
        return score >= 90 ? .blue : score >= 75 ? .orange : .secondary
    }

    /// Builds a typed two-way binding to a rule field, preparing review state and
    /// clamping coupled thresholds/limits. invalidates:false stores settings without
    /// notifying the parent to invalidate cleaning; rules are committed by Apply Rules.
    private func ruleBinding<Value>(_ key: WritableKeyPath<ArtifactReviewRules, Value>) -> Binding<Value> {
        Binding(get: { rules[keyPath: key] }, set: { value in
            edit(invalidates: false) { artifact in
                ArtifactReviewEngine.prepare(&artifact)
                artifact.reviewState?.rules[keyPath: key] = value
                guard var updated = artifact.reviewState?.rules else { return }
                updated.includeCorrelation = min(max(updated.includeCorrelation, 0.50), 0.99)
                updated.excludeCorrelation = min(max(updated.excludeCorrelation, -1), updated.includeCorrelation)
                updated.maximumPeakMicrovolts = min(max(updated.maximumPeakMicrovolts.isFinite ? updated.maximumPeakMicrovolts : 300, 1), 1e6)
                updated.maximumDurationSeconds = min(max(updated.maximumDurationSeconds.isFinite ? updated.maximumDurationSeconds : 1, 0.001), 60)
                artifact.reviewState?.rules = updated
            }
        })
    }

    /// Copies the focused artifact, applies an inout mutation and writes it back
    /// through the array binding. The invalidates flag controls the parent callback,
    /// not whether the mutation is saved.
    private func edit(invalidates: Bool = true, _ mutation: (inout DefinedArtifact) -> Void) {
        guard let id = selected?.id, let index = artifacts.firstIndex(where: { $0.id == id }) else { return }
        var updated = artifacts[index]
        mutation(&updated)
        artifacts[index] = updated
        if invalidates { onChange() }
    }

    /// Removes no-longer-reviewable IDs and keeps focused and batch selections consistent.
    private func synchronizeArtifactSelection() {
        let validIDs = Set(reviewable.map(\.id))
        selectedArtifactIDs.formIntersection(validIDs)
        guard let id = selected?.id else {
            selectedArtifactIDs = []
            artifactSelectionAnchorID = nil
            return
        }
        if !selectedArtifactIDs.contains(id) {
            selectedArtifactIDs = [id]
            artifactSelectionAnchorID = id
        }
    }

    /// Implements desktop selection: Shift chooses an anchored range, Command/Control
    /// toggles members, and an ordinary click replaces selection. Keeps a focused
    /// artifact for the main canvas while a batch may contain several definitions.
    private func selectArtifact(_ artifact: DefinedArtifact, at index: Int) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift), let anchorID = artifactSelectionAnchorID,
           let anchor = reviewable.firstIndex(where: { $0.id == anchorID }) {
            let range = min(anchor, index)...max(anchor, index)
            selectedArtifactIDs = Set(range.map { reviewable[$0].id })
            selectedArtifactID = artifact.id
        } else if modifiers.contains(.command) || modifiers.contains(.control) {
            if selectedArtifactIDs.contains(artifact.id), selectedArtifactIDs.count > 1 {
                selectedArtifactIDs.remove(artifact.id)
                if selectedArtifactID == artifact.id {
                    selectedArtifactID = reviewable.first { selectedArtifactIDs.contains($0.id) }?.id
                }
            } else {
                selectedArtifactIDs.insert(artifact.id)
                selectedArtifactID = artifact.id
            }
            artifactSelectionAnchorID = artifact.id
        } else {
            selectedArtifactIDs = [artifact.id]
            artifactSelectionAnchorID = artifact.id
            selectedArtifactID = artifact.id
        }
    }

    /// Changes method on eligible selected artifacts, commits their current review
    /// choices and notifies the owner once if anything changed. Does not run cleaning.
    private func applyTreatment(_ method: ArtifactCleaningMethod) {
        let ids = effectiveSelectedArtifactIDs
        var changed = false
        for index in artifacts.indices where ids.contains(artifacts[index].id) {
            guard cleaningMethods(artifacts[index]).contains(method),
                  artifacts[index].cleaningMethod != method else { continue }
            artifacts[index].cleaningMethod = method
            ArtifactReviewEngine.commitChoices(&artifacts[index])
            changed = true
        }
        if changed { onChange() }
    }

    /// Chooses a sidebar SF Symbol for the artifact’s domain type.
    private func artifactSymbol(_ artifact: DefinedArtifact) -> String {
        switch artifact.type {
        case .ocular: return "eye"
        case .saccadicSpike: return "bolt"
        case .corneoRetinal: return "arrow.left.and.right"
        case .movement: return "arrow.up.and.down.and.arrow.left.and.right"
        case .muscle: return "waveform.path.ecg"
        case .ecg, .bcg: return "heart"
        case .other: return "ellipsis.circle"
        }
    }

    /// Commits one manual decision for the selected event and restores keyboard focus.
    private func choose(_ decision: ArtifactReviewDecision) {
        guard let example = selectedExample else { return }
        edit { ArtifactReviewEngine.setChoice(decision, eventID: example.id, artifact: &$0) }
        eventFocus = true
    }

    /// Restores the saved pre-rule automatic choices while preserving current manual
    /// choices, then rebuilds the active event set. This is a single-level rule undo.
    private func undoRules() {
        guard let previous = ruleUndo else { return }
        edit { artifact in
            for event in artifact.reviewState?.candidates ?? [] {
                if ArtifactReviewEngine.choice(for: event.id, artifact: artifact).isManual { continue }
                artifact.reviewState?.choices[event.id] = previous[event.id]
            }
            ArtifactReviewEngine.commitChoices(&artifact)
        }
        ruleUndo = nil
    }

    /// Moves currently filtered event IDs to an existing compatible class or a new
    /// child through the engine. Saves source/destination, focuses the destination and
    /// clears transient grouping/undo state. No signal samples are changed.
    private func splitClass() {
        let ids = Set(examples.map(\.id))
        guard let id = selected?.id, let index = artifacts.firstIndex(where: { $0.id == id }) else { return }
        if let destinationID = splitDestinationID,
           let destinationIndex = artifacts.firstIndex(where: { $0.id == destinationID }), destinationIndex != index {
            var source = artifacts[index], destination = artifacts[destinationIndex]
            guard ArtifactReviewEngine.transfer(eventIDs: ids, source: &source, destination: &destination) else { return }
            artifacts[index] = source; artifacts[destinationIndex] = destination
            selectedArtifactID = destinationID
        } else {
            guard let child = ArtifactReviewEngine.split(eventIDs: ids, name: splitName,
                method: splitMethod, parent: &artifacts[index]) else { return }
            artifacts.append(child)
            selectedArtifactID = child.id
        }
        onChange()
        band = nil
        clearSpatialSelection()
        manuallyMergedSpatialGroups = []
        showsSplit = false
        splitDestinationID = nil
        ruleUndo = nil
    }

    /// Encodes source artifact ID and unique event IDs as JSON text for AppKit drag/drop.
    /// Dragging a selected family includes the other selected real families; dragging
    /// an unselected family includes only that family. Encoding failure yields an empty provider.
    private func spatialFamilyDragProvider(_ group: ArtifactSpatialGroup,
                                           familyNumber: Int) -> NSItemProvider {
        guard let sourceID = selected?.id else { return NSItemProvider() }
        let draggedGroups: [ArtifactSpatialGroup]
        if selectedSpatialGroupIDs.contains(group.id) {
            let selectedIDs = selectedSpatialGroupIDs.subtracting([-1])
            draggedGroups = spatialGroups.filter { selectedIDs.contains($0.id) }
        } else {
            draggedGroups = [group]
        }
        let eventIDs = Array(Set(draggedGroups.flatMap(\.eventIDs))).sorted()
        let payload = ArtifactSpatialDragPayload(sourceArtifactID: sourceID,
            eventIDs: eventIDs, familyNumber: familyNumber)
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return NSItemProvider() }
        return NSItemProvider(object: text as NSString)
    }

    /// Starts loading the first text-capable drag item and decodes its JSON payload.
    /// Returns whether loading was accepted, not whether extraction later succeeds.
    /// The callback hops to MainActor before editing SwiftUI-bound state.
    private func acceptSpatialFamilyDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString,
                  let data = (text as String).data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ArtifactSpatialDragPayload.self, from: data) else {
                return
            }
            Task { @MainActor in extractSpatialFamily(payload) }
        }
        return true
    }

    /// Extracts dropped event IDs into a standalone artifact with OBS treatment.
    /// Keeps the source visible while its remaining families rebuild, appends the new
    /// artifact and clears session selections. Invalid/stale source payloads are ignored.
    @MainActor
    private func extractSpatialFamily(_ payload: ArtifactSpatialDragPayload) {
        guard !payload.eventIDs.isEmpty,
              let index = artifacts.firstIndex(where: { $0.id == payload.sourceArtifactID }) else { return }
        let sourceName = artifacts[index].name
        let name = "\(sourceName) – Family \(payload.familyNumber)"
        guard let extracted = ArtifactReviewEngine.split(eventIDs: Set(payload.eventIDs), name: name,
            method: .obs, displaysAsStandaloneArtifact: true, parent: &artifacts[index]) else { return }
        artifacts.append(extracted)
        // Keep the source visible so its remaining families rebuild and re-sort
        // in place. The extracted artifact is immediately available in the sidebar.
        selectedArtifactID = payload.sourceArtifactID
        onChange()
        band = nil
        clearSpatialSelection()
        manuallyMergedSpatialGroups = []
        showsSplit = false
        splitDestinationID = nil
        ruleUndo = nil
    }

    /// Selects the navigation helper’s next event/page destination and restores focus.
    /// An out-of-range destination leaves the selection unchanged.
    private func move(_ direction: Int, byPage: Bool? = nil) {
        guard let index = navigation.destination(direction, byPage: byPage) else { return }
        selectedEventID = examples[index].id
        eventFocus = true
    }

    /// Loads waveform grouping from local/shared caches or builds it off the UI actor.
    /// Forwards cancellation to the detached worker and checks the family key after
    /// awaits, preventing an old family’s result from replacing the current view.
    @MainActor
    private func loadWaveformGrouping() async {
        let key = waveformTaskKey
        guard !key.isEmpty, let analysis = currentAnalysis, let family = selectedSpatialFamily,
              let artifact = selected else { return }
        if waveformLoadedKey == key || waveformCache[key] != nil { return }
        if let cached = await ArtifactWaveformGroupingCache.shared.value(for: key) {
            guard !Task.isCancelled, waveformTaskKey == key else { return }
            waveformCache.insert(cached, for: key)
            waveformGrouping = cached; waveformLoadedKey = key
            return
        }
        let windowSeconds = artifact.windowSizeSeconds
        let polarityMode = waveformPolarityMode
        let worker = Task.detached(priority: .userInitiated) {
            await ArtifactWaveformGrouping.build(analysis: analysis, family: family,
                windowSeconds: windowSeconds, polarityMode: polarityMode)
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, waveformTaskKey == key, let result else { return }
        await ArtifactWaveformGroupingCache.shared.insert(result, for: key)
        guard !Task.isCancelled, waveformTaskKey == key else { return }
        waveformCache.insert(result, for: key)
        waveformGrouping = result; waveformLoadedKey = key
    }

    /// Loads or builds a spatial hierarchy, optionally publishing an early cut preview.
    /// Snapshots geometry/polarity/comparison inputs, forwards cancellation and checks
    /// request identity before caching/publishing. Missing layout yields unassigned events.
    @MainActor
    private func loadSpatialGrouping() async {
        let key = spatialTaskKey
        guard !key.isEmpty, let result = currentAnalysis else { return }
        if spatialLoadedKey == key || spatialCache[key] != nil { return }
        if let cached = await ArtifactSpatialGroupingCache.shared.value(for: key) {
            guard !Task.isCancelled, spatialTaskKey == key else { return }
            spatialCache.insert(cached, for: key)
            spatialHierarchy = cached; spatialLoadedKey = key
            return
        }
        let hasLayout = sensorLayout != nil
        let layout = sensorLayout
        let polarityMode = spatialPolarityMode
        let similarityMetric = effectiveSpatialSimilarityMetric
        let previewKey = spatialPreviewRequestKey
        let initialCut: ArtifactSpatialInitialCut = spatialGroupingControl == .targetCount
            ? .targetCount(spatialTargetCount, spatialCohesionRule)
            : .cohesion(spatialThreshold, spatialCohesionRule)
        let worker = Task.detached(priority: .userInitiated) {
            if !hasLayout {
                return ArtifactSpatialHierarchy(channels: [], features: [], unassignedIDs: result.examples.map(\.id), nodes: [], root: nil) as ArtifactSpatialHierarchy?
            }
            return await ArtifactSpatialGrouping.build(examples: result.examples, layout: layout,
                polarityMode: polarityMode, similarityMetric: similarityMetric, initialCut: initialCut,
                onInitialHierarchy: { preview in
                    await publishSpatialPreview(preview, taskKey: key, requestKey: previewKey)
                })
        }
        let hierarchy = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, spatialTaskKey == key, let hierarchy else { return }
        await ArtifactSpatialGroupingCache.shared.insert(hierarchy, for: key)
        guard !Task.isCancelled, spatialTaskKey == key else { return }
        spatialCache.insert(hierarchy, for: key)
        spatialHierarchy = hierarchy; spatialLoadedKey = key
        spatialPreview = nil; spatialPreviewLoadedKey = ""
    }

    /// Publishes an early hierarchy only while both its analysis and initial-cut
    /// request still match the controls; outdated preview callbacks are discarded.
    @MainActor
    private func publishSpatialPreview(_ preview: ArtifactSpatialHierarchy, taskKey: String, requestKey: String) {
        guard !Task.isCancelled, spatialTaskKey == taskKey, spatialPreviewRequestKey == requestKey else { return }
        spatialPreview = preview
        spatialPreviewLoadedKey = requestKey
    }

    /// Cuts the current hierarchy by cohesion or target count using captured settings.
    /// Caches/publishes only if the task is still current after the background calculation.
    @MainActor
    private func loadSpatialCut() async {
        let key = spatialCutTaskKey
        guard !key.isEmpty, let hierarchy = currentSpatial else { return }
        if spatialCutLoadedKey == key || cutCache[key] != nil { return }
        let control = spatialGroupingControl
        let threshold = spatialThreshold
        let targetCount = spatialTargetCount
        let cohesionRule = spatialCohesionRule
        let outlierFloor = spatialOutlierFloor
        let worker = Task.detached(priority: .userInitiated) {
            switch control {
            case .cohesion:
                return hierarchy.cohesionCut(minimumScore: threshold,
                    cohesionRule: cohesionRule, outlierFloor: outlierFloor)
            case .targetCount:
                return hierarchy.targetCut(count: targetCount,
                    cohesionRule: cohesionRule, outlierFloor: outlierFloor)
            }
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, spatialCutTaskKey == key else { return }
        cutCache.insert(result, for: key)
        spatialCut = result; spatialCutLoadedKey = key
    }

    /// Clears selected spatial families, range anchor and the dependent waveform subgroup.
    private func clearSpatialSelection() {
        selectedSpatialGroupIDs = []
        spatialSelectionAnchorID = nil
        waveformGroupID = nil
    }

    /// Chooses a consistent display polarity for sign-insensitive families: prefer
    /// positive mean over the frontmost quarter of located sensors, with peak-sign
    /// fallback. Returns ±1 for display only; recorded maps remain unchanged.
    private func canonicalDisplaySign(for group: ArtifactSpatialGroup) -> Double {
        guard group.polarityMode == .ignoreGlobalPolarity,
              let layout = sensorLayout, let hierarchy = currentSpatial,
              group.meanFeature.count == hierarchy.channels.count else { return 1 }
        // Resolve coordinates by channel ID, not by the position of an item in the
        // layout array; duplicate IDs retain the first coordinate.
        let positions = Dictionary(layout.positions.map { ($0.channelIndex, $0) },
            uniquingKeysWith: { first, _ in first })
        let located = hierarchy.channels.indices.compactMap { offset -> (Int, Double)? in
            positions[hierarchy.channels[offset]].map { (offset, $0.y) }
        }.sorted { $0.1 > $1.1 }
        let frontal = located.prefix(max(1, located.count / 4))
        let frontalMean = frontal.reduce(0.0) { $0 + group.meanFeature[$1.0] } / Double(max(frontal.count, 1))
        if abs(frontalMean) > 1e-10 { return frontalMean < 0 ? -1 : 1 }
        guard let peak = group.meanFeature.indices.max(by: { abs(group.meanFeature[$0]) < abs(group.meanFeature[$1]) }) else { return 1 }
        return group.meanFeature[peak] < 0 ? -1 : 1
    }

    /// Expands a family’s normalized centroid into recording-channel index space
    /// and applies its canonical display sign. This is a synthetic centroid map,
    /// so sample/time metadata are zero rather than an actual event timestamp.
    private func canonicalTopography(for group: ArtifactSpatialGroup) -> ArtifactReviewTopography? {
        guard let hierarchy = currentSpatial, group.meanFeature.count == hierarchy.channels.count,
              let last = hierarchy.channels.max() else { return nil }
        let sign = canonicalDisplaySign(for: group)
        var values = [Double](repeating: 0, count: last + 1)
        for offset in hierarchy.channels.indices { values[hierarchy.channels[offset]] = sign * group.meanFeature[offset] }
        let meanSquare = hierarchy.channels.reduce(0.0) { $0 + values[$1] * values[$1] }
            / Double(max(hierarchy.channels.count, 1))
        return ArtifactReviewTopography(values: values, channelIndices: hierarchy.channels,
            sampleIndex: 0, timeSeconds: 0, globalFieldPower: sqrt(meanSquare))
    }

    /// Swaps positive/negative member counts when the displayed canonical centroid is flipped.
    private func displayedOrientationCounts(_ group: ArtifactSpatialGroup) -> (positive: Int, negative: Int) {
        canonicalDisplaySign(for: group) < 0
            ? (group.negativeOrientationCount, group.positiveOrientationCount)
            : (group.positiveOrientationCount, group.negativeOrientationCount)
    }

    /// Handles anchored range/toggle/single selection of family cards, removes the
    /// unassigned sentinel, resets subgroup filtering and focuses a representative event.
    private func selectSpatialGroup(_ group: ArtifactSpatialGroup, at index: Int) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift), let anchorID = spatialSelectionAnchorID,
           let anchor = spatialGroups.firstIndex(where: { $0.id == anchorID }) {
            let range = min(anchor, index)...max(anchor, index)
            let rangeIDs = Set(range.map { spatialGroups[$0].id })
            if modifiers.contains(.command) || modifiers.contains(.control) {
                selectedSpatialGroupIDs.formUnion(rangeIDs)
            } else {
                selectedSpatialGroupIDs = rangeIDs
            }
        } else if modifiers.contains(.command) || modifiers.contains(.control) {
            if selectedSpatialGroupIDs.contains(group.id) { selectedSpatialGroupIDs.remove(group.id) }
            else { selectedSpatialGroupIDs.insert(group.id) }
            spatialSelectionAnchorID = group.id
        } else {
            selectedSpatialGroupIDs = [group.id]
            spatialSelectionAnchorID = group.id
        }
        selectedSpatialGroupIDs.remove(-1)
        waveformGroupID = nil
        selectedEventID = group.representativeID
        eventFocus = true
    }

    /// Selects the suggested two-family pair and clears the old waveform subgroup filter.
    private func selectSpatialPair(_ left: Int, _ right: Int) {
        selectedSpatialGroupIDs = [left, right]
        spatialSelectionAnchorID = left
        waveformGroupID = nil
        selectedEventID = spatialGroups.first { $0.id == left }?.representativeID
    }

    /// Creates a session-only merged browsing group from selected families. Replaces
    /// overlapping prior manual merges and selects the new representative. Negative
    /// IDs below −1000 distinguish manual groups from engine groups and unassigned −1.
    private func mergeSpatialGroups(_ ids: [Int]) {
        guard let hierarchy = currentSpatial else { return }
        let wanted = Set(ids.filter { $0 != -1 })
        let groups = spatialGroups.filter { wanted.contains($0.id) }
        guard groups.count >= 2 else { return }
        let mergedID = -1_000 - manuallyMergedSpatialGroups.count
        guard let merged = hierarchy.mergedGroup(groups, id: mergedID) else { return }
        let eventIDs = Set(merged.eventIDs)
        manuallyMergedSpatialGroups.removeAll { !eventIDs.isDisjoint(with: $0.eventIDs) }
        manuallyMergedSpatialGroups.append(merged)
        selectedSpatialGroupIDs = [mergedID]
        spatialSelectionAnchorID = mergedID
        waveformGroupID = nil
        selectedEventID = merged.representativeID
        eventFocus = true
    }

    /// Prepares review state, then loads or computes example analysis from a value
    /// snapshot. Cancellation is forwarded to the worker; a key check protects publication
    /// if the artifact, signal or settings changed while suspended.
    @MainActor
    private func loadAnalysis() async {
        guard let id = selected?.id, let index = artifacts.firstIndex(where: { $0.id == id }) else { return }
        ArtifactReviewEngine.prepare(&artifacts[index])
        let artifact = artifacts[index]
        let key = analysisKey
        if loadedKey == key { return }
        if let cached = analysisCache[key] {
            analysis = cached
            loadedKey = key
            if !cached.channelIndices.contains(channel) { channel = cached.channelIndices.first ?? 0 }
            return
        }
        let source = signal
        let excluded = excludedChannels
        let layout = sensorLayoutName
        let mappedChannels = sensorLayout.map { Set($0.positions.map(\.channelIndex)) }
        let worker = Task.detached(priority: .userInitiated) {
            ArtifactReviewEngine.analyze(artifact: artifact, signal: source, excluding: excluded,
                sensorLayoutName: layout, topographyChannelIndices: mappedChannels)
        }
        // A detached task does not inherit cancellation automatically. Forward it
        // explicitly, then also verify identity: cancellation alone cannot prove this
        // result still belongs to the selected artifact.
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, analysisKey == key else { return }
        analysisCache.insert(result, for: key)
        analysis = result
        loadedKey = key
        if !result.channelIndices.contains(channel) { channel = result.channelIndices.first ?? 0 }
    }

    /// Uses recorded channel names when in bounds, otherwise a one-based Ch label.
    private func channelName(_ index: Int) -> String {
        guard let names = signal.channelNames, names.indices.contains(index) else { return "Ch \(index + 1)" }
        return names[index]
    }
    /// Labels the fixed browsing-band thresholds independently of editable auto-selection rules.
    private func bandDescription(_ band: ArtifactReviewBand) -> String {
        switch band { case .close: return "r ≥ 0.90"; case .variation: return "0.75 ≤ r < 0.90"; case .low: return "r < 0.75" }
    }
    /// Formats available correlation, amplitude and measured duration with explicit missing-data labels.
    private func metricDescription(_ example: ArtifactReviewExample) -> String {
        let r = example.correlation.map { String(format: "r %.3f", $0) } ?? "No similarity score"
        let peak = example.peakMicrovolts.map { String(format: "%.1f µV peak", $0) } ?? "No finite waveform"
        let duration = example.durationSeconds.map { String(format: "%.0f ms span", $0 * 1000) } ?? "Span unknown"
        return "\(r) · \(peak) · \(duration)"
    }
    /// Offers general review treatments plus PCA-S for BCG, retaining an existing
    /// specialized method so an already-configured definition can still display it.
    private func cleaningMethods(_ artifact: DefinedArtifact) -> [ArtifactCleaningMethod] {
        var methods: [ArtifactCleaningMethod] = [.doNothing, .obs, .sspPCA, .regression, .mas, .mar, .waas, .waar, .wavelet]
        if artifact.type == .bcg { methods.append(.pcaS) }
        if !methods.contains(artifact.cleaningMethod) { methods.append(artifact.cleaningMethod) }
        return methods
    }
}

/// The same cards are used by the live review and native render checks.
struct ArtifactWaveformSubgroupCards: View {
    let result: ArtifactWaveformGroupingResult
    let threshold: Double
    let preferredChannel: Int
    @Binding var selectedGroupID: Int?
    let onSelect: (String?) -> Void

    /// Shows subgroup mean/representative traces with selection callbacks. nil means
    /// the whole spatial family; −1 selects unassigned waveforms. These bindings
    /// control browsing and never modify source waveforms.
    var body: some View {
        let groups = result.hierarchy.groups(minimumCorrelation: threshold)
        let channel = result.channelIndices.contains(preferredChannel) ? preferredChannel : result.channelIndices.first ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(groups.count) subgroups · \(result.hierarchy.features.count) usable · \(result.hierarchy.unassignedIDs.count) unassigned")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Whole spatial family") { selectedGroupID = nil; onSelect(nil) }
                    .font(.caption)
            }
            if !groups.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            let representative = result.hierarchy.features.first { $0.eventID == group.representativeID }
                            Button {
                                selectedGroupID = group.id; onSelect(group.representativeID)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Shape \(index + 1) · \(group.eventIDs.count)").font(.caption.weight(.medium))
                                    ArtifactReviewTracePlot(
                                        traces: [result.waveform(representative?.vector ?? [], channel: channel)],
                                        reference: result.waveform(group.meanFeature, channel: channel), minimumScale: 1e-6)
                                        .frame(height: 55)
                                    Text("Ch \(channel + 1) · normalized mean + example")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(group.eventIDs.count == 1 ? "Single example" : String(format: "Minimum waveform r %.2f", group.minimumCorrelation))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }.frame(width: 175).padding(8)
                                    .background(selectedGroupID == group.id ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 124)
            }
            if !result.hierarchy.unassignedIDs.isEmpty {
                Button("Waveform unassigned · \(result.hierarchy.unassignedIDs.count)") {
                    selectedGroupID = -1; onSelect(result.hierarchy.unassignedIDs.first)
                }.font(.caption).tint(selectedGroupID == -1 ? .accentColor : .secondary)
            }
        }
    }
}

struct ArtifactReviewTopomapPreview: View {
    let topography: ArtifactReviewTopography?
    let layout: SensorLayout?
    let scale: Double
    var showsScale = false

    /// Draws a noninteractive topomap with the supplied shared scale, or an accessible
    /// missing-data/layout placeholder. Detailed mode adds electrodes and a color bar.
    var body: some View {
        if let layout, let topography {
            TopomapView(layout: layout, values: topography.values, timeSeconds: topography.timeSeconds,
                fixedScale: scale, showsHeader: false,
                colorBarPlacement: showsScale ? .trailing : .none,
                minimumMapHeight: showsScale ? 180 : 48, contentPadding: 0,
                fieldResolution: showsScale ? 96 : 64, showsElectrodes: showsScale,
                visibleChannels: Set(topography.channelIndices))
                .allowsHitTesting(false)
                .accessibilityLabel("Exemplar scalp topography at peak field strength")
        } else {
            VStack(spacing: 2) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Unavailable").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(layout == nil ? "Topomap unavailable: missing sensor layout" : "Topomap unavailable: insufficient finite spatial signal")
        }
    }
}

private struct ArtifactReviewHelp: View {
    let title: String
    let text: String
    @State private var isPresented = false

    /// Displays a local help popover; State owns visibility and $ passes its dismissal binding.
    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help: \(title)")
        .help(title)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)
        }
    }
}

private struct ArtifactReviewTracePlot: View {
    let traces: [[Float]]
    let reference: [Float]
    var minimumScale: Float = 1
    /// Draws example traces and a reference with one finite-value amplitude scale.
    /// Multiple examples are translucent; the reference is emphasized in blue.
    var body: some View {
        Canvas { context, size in
            let all = traces.flatMap { $0 } + reference
            let scale = max(all.filter(\.isFinite).map { abs($0) }.max() ?? minimumScale, minimumScale)
            /// Maps normalized trace indices and amplitudes to canvas coordinates. Nonfinite
            /// values break the line instead of drawing across a data gap.
            func path(_ values: [Float]) -> Path {
                Path { p in
                    var started = false
                    for (index, value) in values.enumerated() {
                        guard value.isFinite else { started = false; continue }
                        let point = CGPoint(x: CGFloat(index) / CGFloat(max(values.count - 1, 1)) * size.width,
                                            y: size.height / 2 - CGFloat(value / scale) * size.height * 0.43)
                        if started { p.addLine(to: point) } else { p.move(to: point); started = true }
                    }
                }
            }
            for trace in traces { context.stroke(path(trace), with: .color(.secondary.opacity(traces.count > 1 ? 0.25 : 0.85)), lineWidth: 1) }
            context.stroke(path(reference), with: .color(.blue), lineWidth: 1.6)
        }
        .accessibilityLabel("Artifact examples and class average waveform")
    }
}

private struct ArtifactReviewEventPlot: View {
    let artifact: DefinedArtifact
    let example: ArtifactReviewExample
    let analysis: ArtifactReviewAnalysis
    let signal: MFFSignalData
    let channel: Int
    let window: ArtifactReviewContextWindow
    let sharedScale: Double

    /// Draws raw context, class reference and core/taper/measured-span overlays for one
    /// channel. Raw samples are centered using the finite core mean; the reference is
    /// positioned across the core, with time labels relative to the event center.
    var body: some View {
        Canvas { context, size in
            guard signal.data.indices.contains(channel), signal.samplingRate > 0 else { return }
            let core = window.core, padded = window.padded
            let row = signal.data[channel]
            let center = example.event.centerTimeSeconds * signal.samplingRate
            let start = window.displayed.lowerBound, end = window.displayed.upperBound
            let availableStart = max(0, start), availableEnd = min(row.count, end)
            guard availableEnd > availableStart else { return }
            let available = availableStart..<availableEnd
            let baselineStart = max(0, core.lowerBound), baselineEnd = min(row.count, core.upperBound)
            guard baselineEnd > baselineStart else { return }
            let baselineRange = baselineStart..<baselineEnd
            let finite = baselineRange.map { row[$0] }.filter(\.isFinite)
            let baseline = finite.reduce(0.0) { $0 + Double($1) } / Double(max(finite.count, 1))
            let indices = ArtifactReviewEngine.traceIndices(row, range: available)
            let reference = analysis.waveform(analysis.reference, channel: channel)
            let scale = sharedScale
            /// Maps an absolute sample index into horizontal canvas points with side padding.
            func x(_ sample: Double) -> Double { 5 + (sample - Double(start)) / Double(max(end - start, 1)) * (size.width - 10) }
            /// Maps a centered amplitude into vertical canvas points; positive values draw upward.
            func y(_ value: Double) -> Double { 15 + (1 - value / scale) / 2 * (size.height - 42) }
            /// Fills a sample-range background using the same x mapping as traces and event markers.
            func shade(_ range: Range<Int>, _ color: Color) {
                context.fill(Path(CGRect(x: x(Double(range.lowerBound)), y: 0,
                    width: x(Double(range.upperBound)) - x(Double(range.lowerBound)), height: size.height - 23)), with: .color(color))
            }
            shade(padded, .cyan.opacity(0.11))
            shade(core, .blue.opacity(0.12))
            if let detail = artifact.thresholdOcularCandidates?.first(where: { $0.id == example.id }) {
                let lower = max(start, Int((detail.startTimeSeconds * signal.samplingRate).rounded()))
                let upper = min(end, Int((detail.endTimeSeconds * signal.samplingRate).rounded()))
                if upper > lower { shade(lower..<upper, .orange.opacity(0.15)) }
            }
            // Break the path at nonfinite samples. Joining across such a gap would invent
            // a continuous waveform where no valid measurement is available.
            var raw = Path(), drawing = false
            for index in indices {
                guard row[index].isFinite else { drawing = false; continue }
                let point = CGPoint(x: x(Double(index)), y: y(Double(row[index]) - baseline))
                if drawing { raw.addLine(to: point) } else { raw.move(to: point); drawing = true }
            }
            context.stroke(raw, with: .color(.primary), lineWidth: 1)
            var average = Path()
            for (index, value) in reference.enumerated() {
                let sample = Double(core.lowerBound) + Double(index) / Double(max(reference.count - 1, 1)) * Double(core.count - 1)
                let point = CGPoint(x: x(sample), y: y(Double(value)))
                if index == 0 { average.move(to: point) } else { average.addLine(to: point) }
            }
            context.stroke(average, with: .color(.blue), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
            let peak = Path { p in p.move(to: CGPoint(x: x(center), y: 0)); p.addLine(to: CGPoint(x: x(center), y: size.height - 23)) }
            context.stroke(peak, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.draw(Text(String(format: "−%.0f µV / +%.0f µV", scale, scale)).font(.caption2),
                         at: CGPoint(x: 6, y: 8), anchor: .leading)
            context.draw(Text(String(format: "%.0f ms", (Double(start) - center) / signal.samplingRate * 1000)).font(.caption2),
                         at: CGPoint(x: 6, y: size.height - 8), anchor: .leading)
            context.draw(Text(String(format: "%.0f ms", (Double(end) - center) / signal.samplingRate * 1000)).font(.caption2),
                         at: CGPoint(x: size.width - 6, y: size.height - 8), anchor: .trailing)
        }
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Selected event and class average, with core, taper, measured span, and event-center marker")
    }
}
