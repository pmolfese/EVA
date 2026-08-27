//
//  EpochingViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  L4 store for the PSA epoching / averaging domain and the averaged-data
//  display state (butterfly, overlaid categories, noise band), extracted from
//  WaveformView (REFACTOR.md slice 4). State-ownership extraction: the store
//  holds the epoching parameters, rejection settings, results, and display
//  toggles; WaveformView still drives the epoching orchestration.
//

import SwiftUI

/// How a joint marker box arranges more than one condition's topomap. See
/// `EpochingViewModel.jointBoxOrientation`.
enum JointBoxOrientation: String, CaseIterable, Identifiable, Sendable {
    case vertical = "Vertical"
    case horizontal = "Horizontal"
    /// A roughly-square grid (e.g. 4 conditions → 2×2) instead of one long
    /// row or column — for when there are enough conditions that either of
    /// those gets unwieldy.
    case fit = "Fit"
    var id: String { rawValue }
}

/// One joint-plot time marker: a shared latency with a linked, draggable
/// topomap box on every butterfly plot it's shown on (MNE `plot_joint`-style,
/// but attached to whichever butterfly you right-click rather than a
/// dedicated tab). `id` is stable across drags so SwiftUI doesn't recreate
/// the topomap/box views mid-gesture; `relativeSample` is an epoch-relative
/// sample index, same units as `EpochingViewModel.butterflyTopomapRelativeSample`.
/// Session-only — not persisted to eva.xml, like the other `showsAverages*`
/// display toggles.
struct JointPlotMarker: Identifiable, Hashable, Sendable {
    let id: UUID
    var relativeSample: Int
    /// `nil` inherits the plot-wide auto scale shared across every marker
    /// (today's default). Set via right-click on the marker's topomap box to
    /// give this one marker its own independent µV or Z-score scale,
    /// computed from just its own values instead of every marker's.
    var scaleMode: EpochingViewModel.TopomapScaleMode?

    init(id: UUID = UUID(), relativeSample: Int, scaleMode: EpochingViewModel.TopomapScaleMode? = nil) {
        self.id = id
        self.relativeSample = relativeSample
        self.scaleMode = scaleMode
    }
}

/// Which flow the "Group…" popover is showing — pooling whole codes together,
/// or sub-selecting one code's events by a regex on their description.
enum CategoryGroupMode: String, CaseIterable, Identifiable {
    case codes = "Multiple codes"
    case regex = "Regex on description"

    var id: String { rawValue }
}

/// Which per-event text field a `CategoryRegexRule`'s pattern is matched
/// against.
enum CategoryRegexMatchField: String, CaseIterable, Identifiable, Codable, Sendable {
    case description = "Description"
    case label = "Label"

    var id: String { rawValue }
}

/// One regex sub-selection rule: within `sourceCode`'s events, any whose
/// `eventDescription` or `label` (per `matchField`) matches `pattern` get
/// filed under `categoryName` in addition to their normal category. See
/// `EpochingViewModel.categoryRegexRules`.
struct CategoryRegexRule: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var sourceCode: String
    var pattern: String
    /// Absent from older saved eva.xml — decodes to `.description` so
    /// existing rules keep matching against descriptions as before.
    var matchField: CategoryRegexMatchField = .description
    /// May reference the pattern's capture groups as `$1`, `$2`, … — e.g.
    /// pattern `n2_(\w+)` + this template `n2_$1` resolves per event to
    /// `n2_nov`, `n2_rep`, etc., so one rule can fan out into several
    /// categories instead of needing one rule per captured value.
    var categoryName: String
    var isCaseSensitive: Bool = false

    /// Substitutes this rule's `$1`/`$2`/… references with `match`'s captured
    /// substrings. A template with no `$` references (the common case) is
    /// returned unchanged. An out-of-range or unmatched group (e.g. `$2` when
    /// the pattern only has one capture, or an optional group that didn't
    /// participate) is dropped rather than left as literal `$2` text.
    func resolvedCategoryName(for match: Regex<AnyRegexOutput>.Match) -> String {
        guard categoryName.contains("$") else { return categoryName }
        let chars = Array(categoryName)
        var result = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1].isNumber {
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isNumber {
                    digits.append(chars[j])
                    j += 1
                }
                if let index = Int(digits), index < match.output.count,
                   let substring = match.output[index].substring {
                    result += String(substring)
                }
                i = j
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }
}

@MainActor
@Observable
final class EpochingViewModel {
    enum AveragedDisplayMode: String, CaseIterable, Identifiable {
        case waveform = "Waveform"
        case averages = "Averages"
        case trials = "Trials"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .waveform: return "waveform.path.ecg"
            case .averages: return "chart.xyaxis.line"
            case .trials: return "waveform.path.ecg.rectangle"
            }
        }
    }

    /// Held directly so this VM can read channel state itself — see
    /// `FilterViewModel.store` for the rationale (RecordingStore direct-injection pass).
    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
    }

    // MARK: Sheet / selection
    var showsSheet = false
    var segmentField = PSASegmentField.code
    var eventSearchText = ""
    var selectedEventCodes = Set<String>()

    /// Whether anything is actually selected to segment on — checkbox codes,
    /// **or** a regex sub-selection rule with none of its source codes ticked.
    ///
    /// The second half matters: a regex rule can drive a live PSA build on its
    /// own (`sourceCode` need not also be in `selectedEventCodes`), so
    /// `selectedEventCodes.isEmpty` alone reads as "nothing selected" for a
    /// regex-only session. That mismatch is exactly what let a genuine PSA
    /// average — segment, per-epoch bad detection, interpolation escalation, SNR
    /// — leave a `segment` result in the audit log but no `segment` step in
    /// `eva.xml`: the export builder checked `selectedEventCodes` alone while
    /// `canApplyPSA` (the actual live gate) already checked both. One property
    /// for both callers, so they cannot drift apart again.
    var hasSegmentSelection: Bool { !selectedEventCodes.isEmpty || !categoryRegexRules.isEmpty }

    // MARK: Epoch window (portable → eva.xml)
    var preStimulus = 0.2
    var postStimulus = 0.8
    var offset = 0.0
    var baselineCorrected = true
    var averageReference = true
    var averageOnApply = false

    // MARK: Category naming / timing markers
    var categoryNames = [String: String]()
    /// Named groups that pool several event codes into one shared category for
    /// averaging, IN ADDITION to each code's own category (not instead of it) —
    /// e.g. "face" = {happy, sad, angry} produces segments for "face" as well as
    /// segments for "happy"/"sad"/"angry" individually. Value = member codes.
    var categoryGroups = [String: Set<String>]()
    /// Sub-selects a new category out of ONE event code's individual events by
    /// matching a regex against `MFFEvent.eventDescription` (the per-event
    /// "description" field EGI `Events_ECI` tracks populate) — finer-grained
    /// than `categoryGroups`, which only pools whole codes together. Matching
    /// events get the rule's category IN ADDITION to their code's own category
    /// (and the source code doesn't need to be individually selected). Keyed by
    /// `CategoryRegexRule.id.uuidString`.
    var categoryRegexRules = [String: CategoryRegexRule]()
    var timingMarkerEnabledValues = Set<String>()
    var timingMarkerValuesBySegmentValue = [String: String]()
    var timingTolerance = 0.5

    // MARK: Artifact rejection
    var skipIfContainsArtifact = true
    var skipEyeBlinks = true
    var skipEyeMovements = true
    /// Drives the popover listing which artifact kinds to reject on.
    var showsArtifactRejectionOptions = false
    /// Restricts rejection to a sub-window of the epoch instead of the whole
    /// thing, so an artifact late in a long post-stimulus interval (a blink at
    /// 750 ms in a −100…800 ms epoch) doesn't have to cost the trial. Off by
    /// default: the whole epoch counts, which is the historical behaviour.
    var limitsArtifactRejectionWindow = false
    /// Bounds of that window in **seconds relative to the anchor** (negative =
    /// before it), matching how `preStimulus`/`postStimulus` are expressed.
    /// Clamped to the epoch by `effectiveArtifactRejectionWindow`.
    var artifactRejectionWindowStart = -0.2
    var artifactRejectionWindowEnd = 0.8
    var skippedDefinedArtifactIDs = Set<DefinedArtifact.ID>()
    var knownArtifactIDsForRejection = Set<DefinedArtifact.ID>()
    /// Excludes segments the user manually marked "Bad" (Segment Health
    /// right-click / popover) from category averages. Independent of
    /// `skipIfContainsArtifact` — this is a manual call, not detector-driven.
    var skipIfLabeledBad = true

    // MARK: Per-epoch bad-channel interpolation
    /// Detects and interpolates channels that are only bad WITHIN a given
    /// epoch (transient per-trial artifacts a whole-recording health scan
    /// misses), instead of rejecting the whole epoch or leaving it uncorrected.
    var interpolatesBadChannelsPerEpoch = true
    var epochBadChannelThresholds = EpochBadChannelThresholds()
    /// When a channel is flagged bad in at least this fraction of epochs, mark
    /// it bad for the whole recording and interpolate it there instead of
    /// leaving it as a per-epoch-only correction.
    var escalatesBadChannelsToGlobal = true
    var escalationThresholdPercent = 50.0
    /// One line per channel escalated by the last Apply, e.g. "Ch12: bad in
    /// 62% of epochs (31/50)" — surfaced in the status message and folded into
    /// the exported process log via `currentProcessingAuditLogLines()`.
    var escalatedChannelSummaries: [String] = []
    /// One line per channel flagged bad in at least one epoch by the last
    /// Apply, e.g. "Ch12 (14 of 120 epochs)" — including channels that never
    /// crossed the escalation threshold. Surfaced in the status message and
    /// folded into the exported process log via `currentProcessingAuditLogLines()`.
    var epochBadChannelSummary: [String] = []
    /// Channels flagged bad in every accepted segment from the last PSA run.
    var epochBadChannelAllSegmentsSummary: [String] = []
    /// One line per channel showing the accepted segment numbers where it was
    /// interpolated, e.g. "Ch1(4,5,6)".
    var interpolatedChannelsBySegmentSummary: [String] = []
    /// Segments omitted from averaging because the user manually labeled them bad.
    var skippedLabeledBadSegmentsSummary: [String] = []

    // MARK: Reviewed trial exclusion (ROADMAP TW-5)
    /// The committed `trialExclusion` step, or nil when no reviewed exclusion is
    /// part of this recording's current processing.
    ///
    /// Deliberately the *step*, not a set of indices. The step is what
    /// `eva.xml` writes, what the history node hashes, and what a headless run
    /// is handed — holding indices here would put this back where Segment
    /// Health's labels still are: session state a batch run cannot reproduce.
    var committedTrialExclusion: EVAProcessingStep?
    /// What the last resolution of `committedTrialExclusion` against real
    /// segments found. Non-empty `unresolved` means the average on screen is not
    /// the one that was reviewed, and the status line has to say so.
    var trialExclusionResolution: TrialExclusionResolver.Resolution?

    // MARK: Run state
    var statusMessage: String?
    var isApplying = false
    var phaseMessage: String?
    /// Fraction complete (0...1) while segmenting; nil for indeterminate
    /// phases (e.g. averaging), which fall back to a spinner.
    var segmentingProgress: Double?

    // MARK: Results
    /// Pre-average raw epochs, cached so PSA options can be re-toggled without
    /// rebuilding. Lives here (rather than on `WaveformView`) so the shared
    /// invalidation cascade can clear it without a live view — see
    /// `PipelineInvalidation`.
    var segmentedEpochSignal: MFFSignalData?
    var segmentedEpochSegments: [EpochSegment] = []
    var epochedSignal: MFFSignalData?
    var epochSegments: [EpochSegment] = []
    var isAveraged = false
    /// Per-category signal-to-noise metrics for the current average, computed
    /// from the single trials at average time. Empty when the last apply did not
    /// average (SNR needs the trial set, which only the averaging path builds).
    /// Surfaced in the Averages workspace and the export audit log.
    var averageSNRByCategory: [String: SNRMetrics] = [:]
    /// True while SNR is being computed on a background task after the PSA sheet
    /// has already closed, so the Averages workspace can show a spinner in the
    /// SNR area instead of blocking the user from seeing their data.
    var isComputingAverageSNR = false

    // MARK: Averaged-data display
    var showsButterflyPlot = false
    var showsNoiseBand = true
    var showsOverlaidCategories = false
    var butterflyTopomapRelativeSample: Int?
    var averagedDisplayMode: AveragedDisplayMode = .waveform
    var showsAveragesButterfly = true
    var showsAveragesTopography = true
    var showsAveragesInspector = true
    var showsAveragesLog = true
    /// Joint-plot time markers: added via right-click "Add Joint" on ANY
    /// butterfly plot (Butterfly pane, or a Multi-Butterfly row), not a
    /// separate tab — each marker gets a linked, draggable topomap box on
    /// every butterfly it's shown on. Shared across hosts so the same marker
    /// (same latency) appears consistently on all of them.
    var jointPlotMarkers: [JointPlotMarker] = []
    /// Transient: set while a joint marker's box is being dragged, so every
    /// host currently showing that marker (e.g. every Multi-Butterfly row)
    /// updates live together, not just the row the drag started in. `nil`
    /// when nothing is being dragged.
    var jointMarkerLiveDrag: (id: UUID, relativeSample: Int)?
    /// How the Butterfly pane arranges a joint marker box that holds more
    /// than one condition's topomap (Multi-Butterfly rows always hold
    /// exactly one, so this setting doesn't apply there). `.vertical` stacks
    /// conditions with the label to the left of each map; `.horizontal` puts
    /// them in a row, each with its own label above, and one time label
    /// centered over the whole row.
    var jointBoxOrientation: JointBoxOrientation = .vertical
    /// Multiplier on the joint marker box's base topomap size — one shared
    /// setting so it stays consistent everywhere joint boxes appear
    /// (Butterfly pane, Multi-Butterfly).
    var jointTopomapScale: Double = 1.0
    /// Size multiplier for the Topomaps tab's grid (`averagesTopographyPane`)
    /// — separate from `jointTopomapScale` since it's a different display
    /// with its own tile size baseline.
    var topographyTopomapScale: Double = 1.0
    /// Multi-Butterfly's grid column count ("play with doing two per row" —
    /// 1 keeps the original single-column stack).
    var multiButterflyColumns: Int = 2
    /// Width of the Averages workspace's Topography pane, dragged by its left
    /// edge. Clamped to `averagesTopographyWidthRange` and further clamped to
    /// the space actually available, so a width dragged wide on a big display
    /// cannot push the layout off a smaller one.
    var averagesTopographyWidth: Double = 430

    static let averagesTopographyWidthRange: ClosedRange<Double> = 280 ... 1000

    /// Adds a joint marker at exactly `relativeSample` — used by "Add Joint"
    /// in a butterfly's right-click menu, where the click location itself is
    /// the placement, not a default the user then has to drag into place.
    func addJointMarker(atRelativeSample relativeSample: Int) {
        jointPlotMarkers.append(JointPlotMarker(relativeSample: relativeSample))
    }

    func removeJointMarker(_ id: UUID) {
        jointPlotMarkers.removeAll { $0.id == id }
    }

    func updateJointMarker(_ id: UUID, relativeSample: Int, epochLength: Int) {
        guard let index = jointPlotMarkers.firstIndex(where: { $0.id == id }) else { return }
        jointPlotMarkers[index].relativeSample = min(max(relativeSample, 0), max(epochLength - 1, 0))
    }

    /// Sets (or clears, with `nil`) one marker's own independent scale mode.
    /// `nil` reverts it to inheriting the plot-wide shared scale.
    func setJointMarkerScaleMode(_ id: UUID, mode: TopomapScaleMode?) {
        guard let index = jointPlotMarkers.firstIndex(where: { $0.id == id }) else { return }
        jointPlotMarkers[index].scaleMode = mode
    }

    var showsAveragesMultiButterfly = false
    /// Shows a Global Field Power trace under every butterfly plot (Butterfly,
    /// Multi-Butterfly) — one shared toggle since it's the same display
    /// decision everywhere it appears.
    var showsAveragesGFP = true
    var showsAveragesDifference = false
    var differenceCategoryA: String?
    var differenceCategoryB: String?
    var differenceRelativeSample: Int?
    var showsAveragesFilmstrip = false
    var filmstripTileCount = 8
    var psaExclusionSummary = PSAExclusionSummary()

    // MARK: Figure labeling (session-only; never mutates EpochSegment.category)
    /// Category → user-facing display name, for publication figures/legends.
    var categoryRenames = [String: String]()

    /// The display label for a category, honoring any session rename.
    func displayCategory(_ category: String) -> String {
        let renamed = categoryRenames[category]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (renamed?.isEmpty == false) ? renamed! : category
    }

    // MARK: Topomap color scale (Cmd-hold control in the topography pane)
    enum TopomapScaleMode: String, CaseIterable, Identifiable, Hashable { case microvolts = "µV", zScore = "Z"; var id: String { rawValue } }
    var topomapScaleMode: TopomapScaleMode = .microvolts

    /// µV mode: when true, topomaps use the manual min/max below instead of the
    /// auto symmetric ±scale. Tightening the range intensifies the colors.
    var topomapScaleManual = false
    var topomapScaleMin = -5.0
    var topomapScaleMax = 5.0
    /// Lock min = −max so the scale stays symmetric about 0.
    var topomapSymmetric = true

    /// Z-score mode: color scale spans ±`topomapZSigma` SD about the mean. Mean/SD
    /// auto-compute from the displayed maps unless the user overrides them.
    var topomapZSigma = 2.0
    var topomapZMean = 0.0
    var topomapZSD = 1.0
    var topomapZManual = false

    // MARK: Multi-condition overlay (figure building)
    /// Categories chosen for overlay. Empty == all (so no seeding is needed).
    var overlaySelectedCategories: Set<String> = []
    /// Butterfly panel: overlay selected conditions on shared axes vs. stacked.
    var showsOverlayButterfly = false

    /// Effective overlay selection over the currently-available categories
    /// (empty selection resolves to "all").
    func overlayCategories(available: [String]) -> Set<String> {
        overlaySelectedCategories.isEmpty ? Set(available) : overlaySelectedCategories.intersection(available)
    }

    func isOverlaySelected(_ category: String, available: [String]) -> Bool {
        overlayCategories(available: available).contains(category)
    }

    func toggleOverlayCategory(_ category: String, available: [String]) {
        var current = overlayCategories(available: available) // resolves "all" first
        if current.contains(category) { current.remove(category) } else { current.insert(category) }
        // Keep at least one selected.
        if current.isEmpty { current = [category] }
        overlaySelectedCategories = current
    }

    /// The artifact-rejection window actually applied, in seconds relative to
    /// the anchor, or `nil` for "the whole epoch".
    ///
    /// Clamped to the epoch, since an artifact outside the epoch was never a
    /// rejection candidate. An inverted window (end before start) collapses to a
    /// zero-width instant rather than falling back to the whole epoch — a
    /// mistyped bound should reject *less*, never silently reject everything.
    var effectiveArtifactRejectionWindow: ClosedRange<Double>? {
        guard limitsArtifactRejectionWindow else { return nil }
        let lower = max(artifactRejectionWindowStart, -preStimulus)
        let upper = min(artifactRejectionWindowEnd, postStimulus)
        return lower...max(lower, upper)
    }

    /// True when the configured bounds are inverted, so the UI can say so
    /// instead of silently rejecting nothing.
    var artifactRejectionWindowIsInverted: Bool {
        limitsArtifactRejectionWindow && artifactRejectionWindowEnd <= artifactRejectionWindowStart
    }

    /// Seeds the window from the current epoch bounds, so switching the limit on
    /// starts from "the whole epoch" and is narrowed from there rather than
    /// starting at stale numbers from a different epoch length.
    func seedArtifactRejectionWindowFromEpoch() {
        artifactRejectionWindowStart = -preStimulus
        artifactRejectionWindowEnd = postStimulus
    }

    var parameters: [String: String] {
        var p: [String: String] = [
            // Which field the segmentation reads. Both apply paths branch on it
            // — `.artifact` segments on detected artifacts instead of on event
            // codes, an entirely different set of epochs — and it was not
            // serialized until the REWIND determinism audit (2026-08-13).
            "segmentField": segmentField.rawValue,
            "preStimulusMs": String(format: "%.0f", preStimulus * 1000),
            "postStimulusMs": String(format: "%.0f", postStimulus * 1000),
            "offsetMs": String(format: "%.0f", offset * 1000),
            "average": "\(averageOnApply)",
            "skipEyeBlinks": "\(skipEyeBlinks)",
            "skipEyeMovements": "\(skipEyeMovements)",
            "skipArtifacts": "\(skipIfContainsArtifact)",
            "skipLabeledBad": "\(skipIfLabeledBad)",
            "interpolateBadChannelsPerEpoch": "\(interpolatesBadChannelsPerEpoch)"
        ]
        if skipIfContainsArtifact, limitsArtifactRejectionWindow {
            p["artifactWindowLimited"] = "true"
            p["artifactWindowStartMs"] = String(format: "%.0f", artifactRejectionWindowStart * 1000)
            p["artifactWindowEndMs"] = String(format: "%.0f", artifactRejectionWindowEnd * 1000)
        }
        if interpolatesBadChannelsPerEpoch {
            p.merge(epochBadChannelThresholds.flatParameters(prefix: "badChannel")) { current, _ in current }
            p["badChannel.escalateToGlobal"] = "\(escalatesBadChannelsToGlobal)"
            p["badChannel.globalEscalationThresholdPercent"] = String(format: "%.0f", escalationThresholdPercent)
        }
        if !selectedEventCodes.isEmpty {
            p["eventCodes"] = selectedEventCodes.sorted().joined(separator: ",")
        }
        // Only non-default category names (a code defaults to itself) need carrying.
        for code in selectedEventCodes where (categoryNames[code].map { $0 != code } ?? false) {
            p["category.\(code)"] = categoryNames[code]!
        }
        // Category groups pool several codes into one extra shared category
        // (`correct` = {LC++, RC++}), producing segments IN ADDITION to each
        // code's own. Without these the script is not a complete description of
        // the processing: a batch or Copy Processing replay silently produced
        // only the raw codes, which is how an interactive run with groups came
        // out as 6 categories / 134 evaluated epochs and its headless replay as
        // 4 / 67 (2026-08-13).
        for (name, members) in categoryGroups where !members.isEmpty {
            p["categoryGroup.\(name)"] = members.sorted().joined(separator: ",")
        }
        // Regex sub-selection rules, one flattened key per field so a pattern
        // containing separators cannot corrupt the encoding.
        for (index, rule) in categoryRegexRules.values
            .sorted(by: { $0.id.uuidString < $1.id.uuidString })
            .enumerated() {
            p["categoryRegex.\(index).source"] = rule.sourceCode
            p["categoryRegex.\(index).pattern"] = rule.pattern
            p["categoryRegex.\(index).name"] = rule.categoryName
            p["categoryRegex.\(index).caseSensitive"] = "\(rule.isCaseSensitive)"
        }
        // DIN (timing marker) adjustment: which segment values use it, and which
        // marker code each one pairs with. Only emitted when at least one is on,
        // matching the "only non-default state" convention above.
        let enabledWithMarker = timingMarkerEnabledValues
            .compactMap { value -> (String, String)? in
                guard let marker = timingMarkerValuesBySegmentValue[value] else { return nil }
                return (value, marker)
            }
        if !enabledWithMarker.isEmpty {
            p["timingTolerance"] = String(format: "%.3f", timingTolerance)
            for (value, marker) in enabledWithMarker {
                p["din.\(value)"] = marker
            }
        }
        return p
    }

    /// Deserialization inverse of `parameters` for Copy Processing / replay.
    /// Event codes are portable when the target recording has the same codes;
    /// DIN pairings are portable when the target also has the paired marker
    /// code's events (`makeBuildJob` already validates that at apply time).
    func apply(parameters p: [String: String]) {
        // Absent means a pre-audit script, which could only have been `.code` —
        // that was the only value `parameters` was capable of describing.
        if let v = p["segmentField"].flatMap(PSASegmentField.init(rawValue:)) { segmentField = v }
        if let v = p["preStimulusMs"].flatMap(Double.init) { preStimulus = v / 1000 }
        if let v = p["postStimulusMs"].flatMap(Double.init) { postStimulus = v / 1000 }
        if let v = p["offsetMs"].flatMap(Double.init) { offset = v / 1000 }
        // Read but no longer written: the `baseline` step owns this now, and a
        // pre-`baseline` eva.xml still replays correctly from the old key.
        if let v = p["baselineCorrected"] { baselineCorrected = (v == "true") }
        if let v = p["averageReference"] { averageReference = (v == "true") }
        if let v = p["average"] { averageOnApply = (v == "true") }
        if let v = p["skipEyeBlinks"] { skipEyeBlinks = (v == "true") }
        if let v = p["skipEyeMovements"] { skipEyeMovements = (v == "true") }
        if let v = p["skipArtifacts"] { skipIfContainsArtifact = (v == "true") }
        // Absent keys mean "not limited", matching how `parameters` only writes
        // them when the limit is on.
        limitsArtifactRejectionWindow = p["artifactWindowLimited"] == "true"
        if let v = p["artifactWindowStartMs"].flatMap(Double.init) { artifactRejectionWindowStart = v / 1000 }
        if let v = p["artifactWindowEndMs"].flatMap(Double.init) { artifactRejectionWindowEnd = v / 1000 }
        if let v = p["skipLabeledBad"] { skipIfLabeledBad = (v == "true") }
        if let v = p["interpolateBadChannelsPerEpoch"] { interpolatesBadChannelsPerEpoch = (v == "true") }
        epochBadChannelThresholds = EpochBadChannelThresholds.fromFlatParameters(
            p,
            prefix: "badChannel",
            base: epochBadChannelThresholds
        )
        if let v = p["badChannel.escalateToGlobal"] { escalatesBadChannelsToGlobal = (v == "true") }
        if let v = p["badChannel.globalEscalationThresholdPercent"].flatMap(Double.init) {
            escalationThresholdPercent = v
        }
        if let codes = p["eventCodes"] {
            selectedEventCodes = Set(codes.split(separator: ",").map(String.init))
        }
        for (key, value) in p where key.hasPrefix("category.") {
            categoryNames[String(key.dropFirst("category.".count))] = value
        }
        var groups = [String: Set<String>]()
        for (key, value) in p where key.hasPrefix("categoryGroup.") {
            let name = String(key.dropFirst("categoryGroup.".count))
            let members = value.split(separator: ",").map(String.init)
            if !members.isEmpty { groups[name] = Set(members) }
        }
        if !groups.isEmpty { categoryGroups = groups }

        var rules = [String: CategoryRegexRule]()
        let regexIndices = Set(p.keys.compactMap { key -> Int? in
            guard key.hasPrefix("categoryRegex.") else { return nil }
            return Int(key.dropFirst("categoryRegex.".count).prefix(while: \.isNumber))
        })
        for index in regexIndices.sorted() {
            guard let source = p["categoryRegex.\(index).source"],
                  let pattern = p["categoryRegex.\(index).pattern"],
                  let name = p["categoryRegex.\(index).name"] else { continue }
            let rule = CategoryRegexRule(
                sourceCode: source,
                pattern: pattern,
                categoryName: name,
                isCaseSensitive: p["categoryRegex.\(index).caseSensitive"] == "true"
            )
            rules[rule.id.uuidString] = rule
        }
        if !rules.isEmpty { categoryRegexRules = rules }

        if let v = p["timingTolerance"].flatMap(Double.init) { timingTolerance = v }
        var dinEnabled = Set<String>()
        var dinValues = [String: String]()
        for (key, value) in p where key.hasPrefix("din.") {
            let segmentValue = String(key.dropFirst("din.".count))
            dinEnabled.insert(segmentValue)
            dinValues[segmentValue] = value
        }
        if !dinEnabled.isEmpty {
            timingMarkerEnabledValues = dinEnabled
            timingMarkerValuesBySegmentValue = dinValues
        }
    }

    // MARK: - PSA build job + apply (headless-capable)

    /// This VM's own event-code/label projection for segmenting, matching
    /// `WaveformView.psaSegmentValue(for:)`. `.artifact` mode also resolves to
    /// the event code — callers segmenting on artifacts pass artifact-detection
    /// events in as `events` already, so no WaveformView-only artifact lookup
    /// is needed here.
    func segmentValue(for event: MFFEvent) -> String {
        switch segmentField {
        case .code, .artifact: return event.code
        case .label: return event.label ?? event.code
        }
    }

    private func selectedCategoriesByCode() -> [String: [String]]? {
        var categoriesByCode = [String: [String]]()
        for code in selectedEventCodes {
            let category = (categoryNames[code] ?? code).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { return nil }
            categoriesByCode[code] = [category]
        }
        for (groupName, members) in categoryGroups {
            let category = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { continue }
            for member in members where selectedEventCodes.contains(member) {
                categoriesByCode[member, default: []].append(category)
            }
        }
        return categoriesByCode
    }

    /// Eligible for DIN, not just the codes the user checked as their own
    /// category: also any code that's only present as a `CategoryRegexRule`
    /// source, since a regex-derived category's epochs come from that code's
    /// events too and should get the same nearest-marker correction — see
    /// `psaSegmentEventRow`, which enables the DIN checkbox for both.
    private func selectedTimingMarkersBySegmentValue(events: [MFFEvent]) -> [String: String]? {
        let availableValues = Set(events.map(segmentValue(for:)))
        let regexSourceCodes = Set(categoryRegexRules.values.map(\.sourceCode))
        let eligibleValues = selectedEventCodes.union(regexSourceCodes)
        var timingMarkersBySegmentValue = [String: String]()
        for value in eligibleValues where timingMarkerEnabledValues.contains(value) {
            guard let timingValue = timingMarkerValuesBySegmentValue[value],
                  availableValues.contains(timingValue), timingValue != value else {
                return nil
            }
            timingMarkersBySegmentValue[value] = timingValue
        }
        return timingMarkersBySegmentValue
    }

    /// Stable per-category color index, assigned in localized-sorted order.
    ///
    /// Not private: `ButterflyPanelViews` held a verbatim copy, which is exactly
    /// how two renderings of the same averages drift into different colors.
    /// (`MFFReader` and `RecordingCombiner` have their own, deliberately
    /// different, orderings — first-appearance and positional respectively — so
    /// those are *not* the same function and must not be merged in.)
    static func colorIndices(for categories: [String]) -> [String: Int] {
        let uniqueCategories = Array(Set(categories)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: uniqueCategories.enumerated().map { index, category in
            (category, index)
        })
    }

    /// Builds a `PSABuildJob` from this VM's configuration + `allEvents`
    /// (already resolved to whatever `segmentField` needs — e.g. the caller
    /// supplies artifact-detection events when segmenting on `.artifact`).
    /// Headless-capable: unlike `WaveformView.psaBuildJob(from:)`, this
    /// doesn't read `template.definedArtifacts`/`electrodeGeometry`/
    /// SwiftData markers off the view — those are passed in (or default to
    /// empty/off, which degrades gracefully: no defined-artifact rejection,
    /// no per-epoch-interpolation donor positions).
    func makeBuildJob(
        from signal: MFFSignalData,
        events allEvents: [MFFEvent],
        artifactRejectionEvents: [MFFEvent] = [],
        electrodePositions: [Int: SIMD3<Double>] = [:],
        globallyBadChannels: Set<Int> = []
    ) -> PSABuildJob? {
        guard let categoriesBySegmentValue = selectedCategoriesByCode() else {
            statusMessage = "Enter a category name for each selected event."
            return nil
        }
        let sortedEvents = allEvents.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        guard let timingMarkersBySegmentValue = selectedTimingMarkersBySegmentValue(events: sortedEvents) else {
            statusMessage = "Choose a timing marker for each DIN-adjusted event."
            return nil
        }
        let timingEventsBySegmentValue = Dictionary(grouping: sortedEvents, by: segmentValue(for:))
        for (segValue, timingValue) in timingMarkersBySegmentValue {
            guard timingEventsBySegmentValue[timingValue]?.isEmpty == false else {
                statusMessage = "No \(timingValue) timing markers found for \(segValue)."
                return nil
            }
        }
        let regexSourceCodes = Set(categoryRegexRules.values.map(\.sourceCode))
        let events = sortedEvents.filter {
            let value = segmentValue(for: $0)
            return selectedEventCodes.contains(value) || regexSourceCodes.contains(value)
        }
        guard !events.isEmpty else {
            statusMessage = segmentField == .artifact
                ? "Select at least one artifact type."
                : "Select at least one event \(segmentField.rawValue.lowercased())."
            return nil
        }
        guard signal.samplingRate > 0, let sampleCount = signal.data.first?.count, sampleCount > 0 else {
            statusMessage = "This signal has no readable samples."
            return nil
        }
        let preSamples = max(Int((preStimulus * signal.samplingRate).rounded()), 0)
        let epochLength = max(Int(((preStimulus + postStimulus) * signal.samplingRate).rounded()), 1)
        guard epochLength > 0 else {
            statusMessage = "Epoch duration must be greater than zero."
            return nil
        }
        let skipArtifacts = skipIfContainsArtifact && segmentField != .artifact
        let regexRules = Array(categoryRegexRules.values)
        return PSABuildJob(
            signal: signal,
            events: events,
            categoriesBySegmentValue: categoriesBySegmentValue,
            categoryRegexRules: regexRules,
            timingMarkersBySegmentValue: timingMarkersBySegmentValue,
            timingEventsBySegmentValue: timingEventsBySegmentValue,
            artifactEventsForRejection: skipArtifacts ? artifactRejectionEvents : [],
            artifactEventsForRejectionByLabel: skipArtifacts && !artifactRejectionEvents.isEmpty ? ["artifacts": artifactRejectionEvents] : [:],
            preSamples: preSamples,
            epochLength: epochLength,
            psaOffset: offset,
            sampleCount: sampleCount,
            colorIndices: Self.colorIndices(for: categoriesBySegmentValue.values.flatMap { $0 } + regexRules.map(\.categoryName)),
            skipIfContainsArtifact: skipArtifacts,
            artifactRejectionLabel: "artifacts",
            timingTolerance: timingTolerance,
            interpolatesBadChannelsPerEpoch: interpolatesBadChannelsPerEpoch,
            epochBadChannelThresholds: epochBadChannelThresholds,
            electrodePositions: electrodePositions,
            globallyBadChannels: globallyBadChannels,
            artifactRejectionWindow: skipArtifacts ? effectiveArtifactRejectionWindow : nil
        )
    }

    /// Headless build → (average) → post-process for `job`, writing results
    /// into this VM. Returns the final signal, or `nil` if nothing survived.
    ///
    /// Unlike `WaveformView.applyPSACore`, this has no `recordingSessionID`
    /// staleness guard (safe — it only ever writes to `self`; see
    /// `GradientViewModel.apply` for why a one-shot headless caller doesn't
    /// need one), doesn't cache the raw pre-average epochs for later
    /// re-toggling (`segmentedEpochSignal`/`segmentedEpochSegments` are a
    /// `WaveformView`-only *display* cache), and doesn't escalate per-epoch
    /// bad channels to globally-bad + interpolate (that reaches into
    /// `WaveformView.interpolate(_:in:)`, which needs live electrode geometry
    /// and updates view-only status text — a live-view-only feature, not
    /// meaningful for a one-shot headless run).
    /// Result of the shared PSA sequence: the raw per-trial build and the
    /// post-processed (optionally averaged) output.
    struct PSAApplyOutcome {
        /// Raw single trials, before averaging. SNR and per-epoch bad-channel
        /// reporting must read this — `average()`/`postProcessed()` build fresh
        /// results that no longer carry per-trial information.
        let built: PSABuildResult
        let finalResult: PSABuildResult
        let wasAveraged: Bool
        /// Every segment position dropped from the average — the caller's own
        /// manual exclusions unioned with the resolved reviewed exclusion.
        var excludedSegmentIndices: Set<Int> = []
        /// How `committedTrialExclusion` resolved against these segments, or
        /// nil when there is no committed exclusion. Carried out so the caller
        /// can attribute the counts and report an incomplete resolution.
        var trialExclusion: TrialExclusionResolver.Resolution?
    }

    /// Resolves the committed reviewed exclusion against a real set of segments.
    ///
    /// The one entry point for it, called from inside `buildAndPostProcess` so
    /// interactive and headless cannot diverge — the divergence this method
    /// exists to prevent is precisely the one Segment Health's session-only
    /// labels still have.
    func resolvedTrialExclusion(for segments: [EpochSegment]) -> TrialExclusionResolver.Resolution? {
        guard let step = committedTrialExclusion else { return nil }
        return TrialExclusionResolver.resolve(step: step, segments: segments)
    }

    /// Attributes a resolved exclusion into an exclusion summary, so the
    /// per-category retention story reaches `eva.xml`, QuickLook, and combine.
    func foldTrialExclusion(
        _ resolution: TrialExclusionResolver.Resolution?,
        step: EVAProcessingStep?,
        segments: [EpochSegment],
        into summary: inout PSAExclusionSummary
    ) {
        // Always stated, including as "nothing" — `recordExclusions` sets this
        // reason rather than adding to it, so clearing a committed exclusion has
        // to reach it with empty counts or the removed decision would go on
        // being reported by a summary nobody updated.
        var counts: [String: Int] = [:]
        if let resolution, let step {
            counts = TrialExclusionResolver.excludedCountsByCategory(
                step: step, segments: segments, resolution: resolution
            )
        }
        summary.recordExclusions(counts, reason: TrialExclusionResolver.reasonLabel)
    }

    /// Build epochs → optionally average → post-process.
    ///
    /// The single implementation of the PSA sequence, shared by the interactive
    /// path (`WaveformView.applyPSACore`) and the headless one
    /// (`applyBuildJob`). Those two used to each carry their own copy, and every
    /// headless/interactive divergence found on 2026-08-13 came from that shape
    /// of duplication.
    ///
    /// What stays with the callers, because it genuinely differs:
    /// - **SNR scheduling.** Interactive computes it in the background so the
    ///   sheet can close immediately; headless awaits it inline because it is
    ///   about to export.
    /// - **Status composition and UI teardown** (selection reset, sheet
    ///   dismissal, segment-health enable) — view-only.
    /// - **`excludedSegmentIndices`.** Interactive supplies segments the user
    ///   labelled bad in Segment Health. Those labels are session state that a
    ///   batch run has no equivalent of, so headless legitimately passes none.
    ///   The committed reviewed exclusion (TW-5) is deliberately NOT routed
    ///   through this argument: it is recorded in `eva.xml`, so both paths owe
    ///   the same answer, and it is resolved once inside this method.
    ///
    /// `isCurrent` is the interactive session guard: the view can outlive a run
    /// (same-window "Close Recording" mid-flight), so it re-checks between
    /// phases. Headless has no such concept and leaves it at the default.
    ///
    /// Returns `nil` when cancelled, superseded, or nothing survived — having
    /// already cleared `isApplying`/`phaseMessage` and set `statusMessage`.
    func buildAndPostProcess(
        job: PSABuildJob,
        shouldAverage: Bool,
        averageReference: Bool,
        baselineCorrect: Bool,
        badChannels: Set<Int>,
        excludedSegmentIndices: ([EpochSegment]) -> Set<Int> = { _ in [] },
        isCurrent: () -> Bool = { true }
    ) async -> PSAApplyOutcome? {
        isApplying = true
        phaseMessage = "Segmenting…"
        segmentingProgress = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] (update: EpochBuildProgress) in
            self?.phaseMessage = "Segmenting… (\(update.completed) of \(update.total))"
            self?.segmentingProgress = update.fraction
        }
        let buildWorker = Task.detached(priority: .userInitiated) {
            await job.buildEpochs { completed, total in
                progressContinuation.yield(EpochBuildProgress(completed: completed, total: total))
            }
        }
        let built = await withTaskCancellationHandler(
            operation: { await buildWorker.value },
            onCancel: { buildWorker.cancel() }
        )
        progressContinuation.finish()
        progressTask.cancel()
        segmentingProgress = nil

        guard !Task.isCancelled, isCurrent() else {
            finishApplying()
            return nil
        }
        guard let built else {
            finishApplying()
            statusMessage = "No trials survived PSA segmentation. All candidate epochs were rejected, skipped, or out of bounds."
            return nil
        }

        let finalResult: PSABuildResult
        let wasAveraged: Bool
        var appliedExclusions = Set<Int>()
        var resolution: TrialExclusionResolver.Resolution?

        if shouldAverage {
            phaseMessage = "Averaging…"
            let colorIndices = Self.colorIndices(for: built.segments.map(\.category))
            // Two sources, unioned here rather than in either caller: the
            // caller's own manual exclusions (Segment Health labels, which only
            // the interactive path has) and the committed reviewed exclusion,
            // which both paths must apply identically or a batch run reproduces
            // a different average than the one that was reviewed.
            resolution = resolvedTrialExclusion(for: built.segments)
            let excluded = excludedSegmentIndices(built.segments)
                .union(resolution?.excludedIndices ?? [])
            appliedExclusions = excluded
            let averageWorker = Task.detached(priority: .userInitiated) {
                built.average(colorIndices: colorIndices, excludedIndices: excluded)
            }
            let averagedOpt = await withTaskCancellationHandler(
                operation: { await averageWorker.value },
                onCancel: { averageWorker.cancel() }
            )
            guard !Task.isCancelled, isCurrent(), let averaged = averagedOpt else {
                finishApplying()
                statusMessage = "No averages could be computed."
                return nil
            }
            phaseMessage = "Post-processing…"
            let postWorker = Task.detached(priority: .userInitiated) {
                averaged.postProcessed(
                    averageReference: averageReference,
                    baselineCorrect: baselineCorrect,
                    badChannels: badChannels
                )
            }
            finalResult = await withTaskCancellationHandler(
                operation: { await postWorker.value },
                onCancel: { postWorker.cancel() }
            )
            wasAveraged = true
        } else {
            phaseMessage = "Post-processing…"
            let postWorker = Task.detached(priority: .userInitiated) {
                built.postProcessed(
                    averageReference: averageReference,
                    baselineCorrect: baselineCorrect,
                    badChannels: badChannels
                )
            }
            finalResult = await withTaskCancellationHandler(
                operation: { await postWorker.value },
                onCancel: { postWorker.cancel() }
            )
            wasAveraged = false
        }

        guard !Task.isCancelled, isCurrent() else {
            finishApplying()
            return nil
        }
        // Only meaningful when averaging: an exclusion removes a trial from an
        // average, and there is no average to remove it from otherwise.
        trialExclusionResolution = wasAveraged ? resolution : nil
        return PSAApplyOutcome(
            built: built,
            finalResult: finalResult,
            wasAveraged: wasAveraged,
            excludedSegmentIndices: appliedExclusions,
            trialExclusion: resolution
        )
    }

    /// Clears the in-progress flags. Every early exit from the PSA sequence has
    /// to do this — forgetting it is what leaves the spinner stuck on.
    private func finishApplying() {
        isApplying = false
        phaseMessage = nil
    }

    func applyBuildJob(
        _ job: PSABuildJob,
        averageReference: Bool,
        baselineCorrect: Bool,
        badChannels: Set<Int>,
        electrodePositions: [Int: SIMD3<Double>] = [:],
        continuousSignal: MFFSignalData? = nil
    ) async -> MFFSignalData? {
        guard let outcome = await buildAndPostProcess(
            job: job,
            shouldAverage: averageOnApply,
            averageReference: averageReference,
            baselineCorrect: baselineCorrect,
            badChannels: badChannels
            // No `excludedSegmentIndices`: Segment Health quality labels are a
            // manual, session-only decision that a batch run has no equivalent
            // of. A *committed* reviewed exclusion is the opposite — it is on
            // disk precisely so this path can apply it — and
            // `buildAndPostProcess` resolves it for both paths rather than
            // taking it through this argument.
        ) else {
            return nil
        }

        let built = outcome.built
        let finalResult = outcome.finalResult
        let epochBadChannelCounts = built.epochBadChannelCounts
        let totalEpochsEvaluated = built.totalEpochsEvaluated

        // SNR from the RAW single trials — awaited inline here (unlike the
        // interactive path, which backgrounds it) because the caller is about to
        // export and the metrics belong in that package's audit log.
        if outcome.wasAveraged {
            // SNR must be measured on the trials that made the average, or a
            // batch export reports the SNR of trials the operator excluded.
            let excluded = outcome.excludedSegmentIndices
            let snrWorker = Task.detached(priority: .userInitiated) {
                built.categorySNR(excludedIndices: excluded)
            }
            averageSNRByCategory = await withTaskCancellationHandler(
                operation: { await snrWorker.value },
                onCancel: { snrWorker.cancel() }
            )
        } else {
            averageSNRByCategory = [:]
        }

        // Raw epochs cached so post-processing can be re-toggled, matching the
        // interactive path.
        segmentedEpochSignal = built.signal
        segmentedEpochSegments = built.segments

        epochedSignal = finalResult.signal
        epochSegments = finalResult.segments
        isAveraged = outcome.wasAveraged

        var exclusionSummary = built.exclusionSummary
        foldTrialExclusion(
            outcome.trialExclusion,
            step: committedTrialExclusion,
            segments: built.segments,
            into: &exclusionSummary
        )
        exclusionSummary.outputSegments = finalResult.segments.count
        exclusionSummary.badChannelCount = epochBadChannelCounts.count
        psaExclusionSummary = exclusionSummary
        showsButterflyPlot = outcome.wasAveraged
        if !outcome.wasAveraged {
            averagedDisplayMode = .waveform
        }

        var statusText = finalResult.message
        epochBadChannelSummary = []
        if interpolatesBadChannelsPerEpoch, totalEpochsEvaluated > 0, !epochBadChannelCounts.isEmpty {
            let segmentBadChannels = epochBadChannelCounts.keys.sorted().map { "Ch\($0 + 1)" }
            epochBadChannelSummary = epochBadChannelCounts.keys.sorted().map {
                "Ch\($0 + 1) (\(epochBadChannelCounts[$0] ?? 0) of \(totalEpochsEvaluated) epochs)"
            }
            statusText += " · \(epochBadChannelCounts.count) channel\(epochBadChannelCounts.count == 1 ? "" : "s") bad in \u{2265}1 epoch (\(segmentBadChannels.joined(separator: ", ")))"
            if built.rejectedForTooManyBadChannels > 0 {
                statusText += " · \(built.rejectedForTooManyBadChannels) epoch\(built.rejectedForTooManyBadChannels == 1 ? "" : "s") rejected for too many bad channels"
            }
        }

        // Promote persistently-bad channels to globally bad and interpolate them.
        var resultSignal = finalResult.signal
        if let continuousSignal {
            let escalation = await PSABadChannelEscalation.escalate(
                counts: epochBadChannelCounts,
                totalEpochs: totalEpochsEvaluated,
                isEnabled: escalatesBadChannelsToGlobal,
                thresholdPercent: escalationThresholdPercent,
                continuousSignal: continuousSignal,
                epochedSignal: resultSignal,
                positions: electrodePositions,
                channels: store.channels
            )
            escalatedChannelSummaries = escalation.summaries
            if let patched = escalation.patchedEpochedSignal {
                resultSignal = patched
                // `epochedSignal` is what callers export
                // (`HeadlessBatchProcessor` snapshots it, not this return value),
                // so the patch has to land there too — otherwise the escalation
                // runs, reports itself in the log, and is silently discarded.
                epochedSignal = patched
            }
            if !escalation.errors.isEmpty {
                statusText += " · " + escalation.errors.joined(separator: " · ")
            }
        }

        statusMessage = statusText
        isApplying = false
        phaseMessage = nil
        return resultSignal
    }

    func resetForClose() {
        showsSheet = false
        eventSearchText = ""
        selectedEventCodes.removeAll()
        categoryNames.removeAll()
        categoryGroups.removeAll()
        categoryRegexRules.removeAll()
        timingMarkerEnabledValues.removeAll()
        timingMarkerValuesBySegmentValue.removeAll()
        skippedDefinedArtifactIDs.removeAll()
        knownArtifactIDsForRejection.removeAll()
        escalatedChannelSummaries.removeAll()
        epochBadChannelSummary.removeAll()
        epochBadChannelAllSegmentsSummary.removeAll()
        interpolatedChannelsBySegmentSummary.removeAll()
        skippedLabeledBadSegmentsSummary.removeAll()
        committedTrialExclusion = nil
        trialExclusionResolution = nil
        statusMessage = nil
        isApplying = false
        phaseMessage = nil
        epochedSignal = nil
        epochSegments = []
        isAveraged = false
        showsButterflyPlot = false
        showsOverlaidCategories = false
        butterflyTopomapRelativeSample = nil
        averagedDisplayMode = .waveform
        showsAveragesButterfly = true
        showsAveragesTopography = true
        showsAveragesInspector = true
        showsAveragesLog = true
        jointPlotMarkers.removeAll()
        jointMarkerLiveDrag = nil
        jointBoxOrientation = .vertical
        jointTopomapScale = 1.0
        topographyTopomapScale = 1.0
        multiButterflyColumns = 2
        showsAveragesMultiButterfly = false
        showsAveragesGFP = true
        showsAveragesDifference = false
        differenceCategoryA = nil
        differenceCategoryB = nil
        differenceRelativeSample = nil
        showsAveragesFilmstrip = false
        filmstripTileCount = 8
        psaExclusionSummary = PSAExclusionSummary()
        categoryRenames.removeAll()
        overlaySelectedCategories.removeAll()
        showsOverlayButterfly = false
        topomapScaleMode = .microvolts
        topomapScaleManual = false
        topomapSymmetric = true
        topomapZManual = false
        topomapZSigma = 2.0
    }
}
