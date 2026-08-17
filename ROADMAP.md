# EVA — ROADMAP

Unified plan. The single planning document for EVA. It absorbed and replaced
`TODO.md`, `REFACTOR_July.md`, `REFACTOR.md`, and `TODO_BATCH.md`, all of which
have been deleted.
Forward-looking priorities are up top; the completed history that still carries
design rationale is preserved at the bottom under **Done / status**.

Ordering reflects current reality: the processing/batch suite (old Priority 1) is
**essentially complete**, so the **performance & architecture refactor is now
Priority 1** — it's the largest remaining body of work and the one with live
user-visible symptoms (main-thread hangs).

> **Status pass 2026-08-11.** Checked every open box against the tree. Since the
> 2026-07-13 write-up, effort went almost entirely into *features* (wavelets,
> ICA, GPU backends, importers, single-trial) rather than Priority 1: **B2–B5,
> C1–C5, D1–D2 are all still open**, and `WaveformView.swift` has grown back from
> 2,720 → **3,014 lines** with **104 `@State`** and **21 `.sheet` modifiers**
> still in the same struct. See **Landed since 2026-07-13** at the bottom for
> what did ship, and the obsolete/superseded notes marked ~~struck~~ below.
>
> **Status pass 2026-08-12.** Re-verified by grep. Sub-sample alignment is done
> (removed). Progressive/streaming loading dropped as a goal. Still open despite
> assumptions to the contrary: **Engzee and Hilbert QRS detectors** (absent from
> `ECGDetectionAlgorithm`), the **BCG trajectory-frame seed**, the **FASTR
> unreliable-epoch / PSA-overlap** work (`MRI_GRAD_UNRELIABLE` exists nowhere), and
> **auto PNS mapping for BrainVision/EDF** (`SignalImportReader` populates
> `pnsSignal` only on the MFF branch).
>
> **Landed 2026-08-12: C4, D2, B3, B4, B5.** `trace2.trace` (Release, 32 s)
> confirms the earlier work: **one 358 ms hang in the whole session**, against
> 30+ hangs (worst 1.54 s) in ~107 s at baseline. That one hang is first-display
> type-metadata instantiation, which is what B3 attacks — re-trace to see whether
> it shrank. **D1 is now ruled out by measurement** (Canvas is 1.44%).
> `WaveformView.swift` is **2,825 lines** (from 3,014) / **67 `@State`** (was 104)
> / **1 `.sheet`** (was 18). **B2 is done as far as it is worth doing**:
> `EventsPanelView` (closing **C1**), `TopomapPanelView`, `StatusLogView`,
> `PhysioPaneView`, three drag-hot overlays, and `ChannelLabelRow` made
> `Equatable`. `WaveformAreaView` and `ControlsBar` were **deliberately not
> extracted** — see B2 for the evidence; both would move cost rather than remove
> it.
>
> **Status pass 2026-08-13 — Priority 1 is complete, and REWIND is unblocked.**
> `trace3.trace` confirmed the refactor: `initializeWithCopy for WaveformView`
> **1.48% → 0.33%**, `ChannelLabelRow` 1.32% → 0.20%, Observation overhead *down*
> (6.38% → 5.10%, disproving a worry recorded here earlier). Remaining Priority 1
> items are closed or ruled out: **C1** closed by the `EventsPanelView`
> extraction, **C4** done, **D1** ruled out by measurement (Canvas 1.59%), **D2**
> done, **C2/C3** not justified by any trace, **C5** absorbed into the async-path
> sweep. A separate wheel-scroll hang was found and fixed (`LazyVStack` inside a
> horizontal `ScrollView`).
>
> The day's larger result was **headless/interactive parity**, now verified
> **byte-identical** on a script exercising filter → threshold detection →
> segmentation → averaging → per-epoch bad-channel interpolation → globally-bad
> escalation → category grouping. Four divergences found and closed, plus two
> bugs found along the way that nobody was looking for (an escalation whose
> result was computed, logged, and then discarded; and category grouping never
> being serialized to `eva.xml` at all).
>
> **The pattern worth carrying forward:** every divergence came from logic living
> on `WaveformView`, so the headless path silently did less. The fix each time
> was the same shape — extract to a free function over explicitly-passed
> collaborators (`PipelineInvalidation`, `ProcessingAuditLog`,
> `PSABadChannelEscalation`, `EpochingViewModel.buildAndPostProcess`) and have
> both callers use it. And every one of them was found by **comparing bytes, not
> by reading code**: logs agreed while data didn't, twice.

---

## Idea: average reference and baseline correction as their own steps (2026-08-16, not started)

Raised during REWIND fork testing: *"pull average reference out of the
filtering step and add it as a separate 'function' that would get called (if
asked) by the averaging step. Baseline correction would be similar."*

**The problem today.** Neither operation is independently undoable. Average
reference is `FilterViewModel.averageReference`, a toggle applied *inside* one
atomic filter run (`EEGSignalFilter.averageReferenceInPlace`, called from
`FilterViewModel`'s own apply path right after the frequency filter). Baseline
correction is `EpochingViewModel.baselineCorrected`, folded into the segment
step the same way. Both only become their own `EVAProcessingStep` — `.reference`
/ `.baseline` — at **export time** (`MFFExportFlowViews.swift`), as
provenance-only entries synthesized from the toggles. Nothing about them exists
as a real node in the *live* history tree during a session: you cannot undo
just the reference without re-running the whole filter, and the history rail
cannot show "filter" and "reference" as two things that happened, only one.

**The shape of the fix.** Two genuinely separate pieces:

1. **A standalone function**, not a method wedged into `FilterViewModel`:
   something like `Rereferencing.averageReference(_ signal: MFFSignalData,
   excluding bad: Set<Int>) -> MFFSignalData` — `EEGSignalFilter.averageReferenceInPlace`
   already exists and is close to this; the work is exposing it as a
   independently-callable stage rather than a step embedded in
   `FilterViewModel.apply()`. Same idea for baseline correction, currently
   embedded in whatever `EpochingViewModel`'s segment/average path calls.
2. **A real history node.** When reference/baseline is turned on, `record()`
   a `.reference`/`.baseline` step chained *after* whatever produced its
   input (filter, or segment), the same way `icaClean` already chains after
   `filter` — content-addressed, independently navigable, independently
   evictable/re-derivable, and separately undo/redo-able from the step that
   fed it.

**"Called (if asked) by the averaging step"** — i.e. this isn't meant to run
eagerly the moment the toggle flips; it is invoked *by* whatever consumes it
(the averaging/epoching stage asks for a re-referenced signal when it needs
one), matching the existing `filter.averageReference` /
`epoching.averageReference` split, which already lets continuous and epoched
data be referenced independently. The refactor should preserve that split as
two call sites into one shared function, not collapse it into one.

**What this is not:** a change to what gets *exported* — `.reference`/`.baseline`
already exist as `EVAProcessingStep.Operation` cases and already round-trip
through `eva.xml` and batch replay (see "Channel Sets"-adjacent
`replayInteraction` fix, 2026-08-16, which made both `.auto` for batch). This
is specifically about making them real, undoable nodes in the *live* session
tree, not about the on-disk format.

**Open questions before starting:**
- Does `EVAHistoryNodeID` hashing already handle a step whose *input* signal
  can come from either a continuous or epoched path cleanly, or does
  content-addressing need a third disambiguator the way ICA needed a payload
  digest?
- `ReplaySettingsRestore`'s "lights" (`continuousReference`/`epochReference`/
  `baselineCorrection`) already model per-path reference/baseline as derived
  flags for replay — check whether that machinery can be reused directly for
  the live-tree version, or whether it was built assuming these stay bundled.
- Whether every existing snapshot/eviction assumption (`PipelineSnapshot`'s
  stage-output fields) needs a new field per new stage, matching how
  `icaSignal`/`filterOutput`/etc. are each their own field today.

Not scoped or estimated further than this — flagged here so it isn't lost,
not because it's next in line.

---

## Idea: Figure Composer (Phase 1 landed 2026-08-14, Phase 2 not started)

A print-dialog-style window for assembling publication figures from several
plots at once, instead of exporting each panel one at a time.

**Phase 1 — done.** Every plot's existing "Save Figure As…" menu
(`figureSaveMenu` in `ButterflyPanelViews.swift`) now also has "Add to
Export," which snapshots the figure as vector PDF + a thumbnail into
`FigureExportBasket.shared` (`EVA/IO/FigureExportBasket.swift`) — a
session-wide collection, independent of the source recording window staying
open. A new "Figure Export" window (Window menu, ⌘⇧E,
`FigureExportBasketView.swift`) lists the basket with reorder/remove, and
"Export Contact Sheet…" stacks everything into one multi-page vector PDF
(Letter or 8×8 square), one column, wrapping to a new page when full.

**Phase 2 — not started.** The actual "killer feature" this was scoped down
from: a freeform canvas where figures can be dragged, resized, and arranged
anywhere on the page (multi-select, snapping/alignment guides, multiple
pages), not just auto-stacked top to bottom. Biggest remaining chunk of work
in the whole idea — a small desktop-publishing UI, probably bigger than
everything in Phase 1 combined. SVG export was considered and dropped (no
native AppKit SVG writer; PDF already covers the vector/publication use
case).

---

## Priority 1 — Performance & architecture: the WaveformView / Observation refactor

Motivated by the 2026-07-13 Instruments session (`eva_hang.trace`: SwiftUI
template, Hangs + high-frequency Time Profiler, ~107 s, Release build) which
caught **30+ main-thread hangs** (worst 1.54 s). The hot frames are almost
entirely *SwiftUI re-evaluation machinery*, not signal processing:

| Samples | Frame |
|---|---|
| 393 | `initializeWithCopy for WaveformView` (whole-struct memcpy) |
| 530 | AttributeGraph `find1<A>` (graph lookup churn) |
| 240 | `WaveformView.content(for:…)` |
| 100s each | `waveformRow` / `channelLabel` / `eventsPanel` / `controls` closures, `ForEachChild.updateValue`, `PropertyList.Tracker.value` |
| **18** | `ChannelModel.applyingInterpolations(to:)` — the path the interpolation resolver already fixed |

Two structural causes, neither addressed by the interpolation-resolver work that
landed on `july13`:

1. **Observation granularity.** 14 domain VMs are Combine `ObservableObject`s held
   as `@StateObject` (~330 `@Published` properties total), plus
   `MFFRecording: ObservableObject`. `ObservableObject` has no per-property
   tracking, so **any** `@Published` write on **any** VM invalidates the **entire**
   `WaveformView` body. Worst case: the unthrottled `progress` publishers ticked a
   2,700-line body with ~20 sheets and every channel row on every update — the hang
   cadence in the trace.

2. **One giant view struct.** `WaveformView` is a single `View` type with ~118
   stored properties (95 `@State`, 15 `@StateObject`, `@ObservedObject`, `@Query`,
   `@AppStorage`, `@Environment`). Every AttributeGraph node that captures `self`
   (every `ForEach` row closure, every `.sheet`/`.contextMenu`/`.overlay`) copies
   the whole struct → the 393-sample `initializeWithCopy`. And because
   `channelLabel`/`waveformRow`/`eventsPanel` are *functions on the same struct*
   rather than child `View` types, SwiftUI has no per-child dependency boundary —
   everything re-evaluates together.

This section replaces the old TODO Priority 2 conditional item ("isolate the
waveform-area render structs … if it stays large") with a concrete, perf-justified
version: the reason to extract is no longer file size, it's diffing boundaries.

### A. Observation-model migration (biggest win, mostly mechanical)

- [x] **A1. Throttle progress publishers.** (2026-07-13) `ProgressBridge.make` now
  buffers newest-only (`.bufferingNewest(1)`) and paces applies to ~30 Hz, so a
  burst of worker yields collapses to one main-actor apply per frame instead of
  hundreds. One choke point; every VM benefits with zero call-site changes.
  Covered by new `ProcessingQueueTests` (burst-coalescing + final-value-always-applied).
- [x] **A2. Migrate the 14 Combine VMs (and `MFFRecording`) to `@Observable`.** (2026-07-13)
  All 14 domain VMs + `ReplayController` + `MFFRecording` are now `@Observable`:
  `FilterViewModel`, `GradientViewModel`, `ICAViewModel`, `BCGDetectionViewModel`,
  `EpochingViewModel`, `ArtifactTemplateViewModel`, `ArtifactViewModel`,
  `EEGAnalysisViewModel`, `ChannelHealthViewModel`, `SegmentHealthViewModel`,
  `SingleTrialAnalysisViewModel`, `WaveletReductionViewModel`,
  `WaveletArtifactExplorerViewModel`, `ECGDetectionViewModel`, `ReplayController`,
  `MFFRecording`. `ObservableObject`→`@Observable`; dropped `@Published`; removed the
  now-unused `import Combine`; `@StateObject`→`@State` (both the declaration and the
  `_x = StateObject(wrappedValue:)` init sites in `WaveformView`); `@ObservedObject`
  params in child sheets → plain `var` where read-only (`DatasetInfoSheet`) or
  **`@Bindable var vm`** where the sheet uses `$vm.prop` (`EyeArtifactThresholdSheet`,
  `EEGAnalysisSheet`, `SingleTrialAnalysisViews`, `ReplayConfigSheet`). `MFFRecording` dropped its manual `ObservableObjectPublisher` +
  all `objectWillChange.send()` batching (Observation coalesces same-tick writes into
  one view update); its owner chain (`EVAApp @State` → `ContentView @Binding` →
  `WaveformView`/`DatasetInfoSheet` plain `var`) needed no wrapper change.
  Traps hit in practice: private bookkeeping that `deinit`/detail-views touch
  (`task`, `loadTask`, `activeRequestID`, `isClosed`, init flags) must be
  `@ObservationIgnored` — otherwise the macro's property transform makes `deinit`'s
  access main-actor-isolated and it won't compile. **Left as `ObservableObject`
  (intentionally out of scope):** `ProcessingQueue` (a `let` on the already-`@Observable`
  `RecordingStore`, no view reads its props), `DebugLog` (global `.shared`, debug window
  only), and the private `SingleTrialChannelTraceCache`.
  Payoff: body invalidation becomes property-granular — a `progress` tick
  re-renders only the status row, not the channel stack. Composes with A1/B1.
  Verified: clean Debug build, full `EVATests` (412 pass), open-recording launch smoke
  test; loading→loaded transition confirmed (WaveformView body reads the tracked
  `recording.isLoading`/`loadProgress`/`signal`).
- [x] **A3. Scope `@Query private var markers` out of `WaveformView`.** (2026-07-13)
  New `WaveformMarkerContainer` (private, in `ContentView.swift`) now hosts the
  `@Query private var markers: [UserMarker]`, filters to `recording.packageName`,
  projects each to the Equatable `WaveformUserMarkerSignature` value, and passes the
  array into `WaveformView` as a plain `let userMarkers`. `ContentView` renders the
  container (keeping `.id(recording.id)` for per-recording state reset) instead of
  `WaveformView` directly. `WaveformView.userMarkerEvents` and the
  `displayedEventsCacheKey` user-marker branch now read the passed value instead of
  re-filtering the raw query. Net: a `UserMarker` table write re-evaluates only the
  tiny container; `WaveformView`'s body re-runs only when *this* recording's marker
  signatures actually change (Equatable value input). Marker *creation* was already
  query-independent (`modelContext.insert`), so it's unaffected. Verified: clean
  build, 412 EVATests pass, open-recording smoke test.

### B. Break the single-struct pattern (the real "L6")

Goal is *type* boundaries so SwiftUI can diff and skip — not more file splits.
Leaf-first, every step small and shippable.

- [x] **B1. Extract the per-channel rows into standalone `View` structs.** (2026-07-13)
  Highest leverage per line — done before B3/B4. New file `WaveformChannelRows.swift`:
  - `ChannelLabelRow` (from `ChannelsPanelViews.channelLabel`): inputs `index`,
    `label`, the resolved `isHidden`/`isBad`/`isInterpolated`/`color`, `healthResult`,
    and action *closures* — no `signal`, no `channels`, no `self` stored.
  - `WaveformChannelRow` (from `waveformRow`): inputs `samples`, `amplitudeScale`,
    `timeScale`, `sampleStride`, `visibleRange`, `color`, `rowHeight` + action closures.
    The input bundle is `Equatable` (compared by `(dataRevision, index, isHidden)` +
    viewport/scale/appearance — O(1), not a raw `[Float]` compare) and the row is
    marked `.equatable()` at the call site so rows whose data + viewport didn't change
    skip the Canvas redraw entirely (`canDefineArtifact` flips only at drag start/end,
    so a continuous selection drag no longer re-draws any row).
  The two `ForEach`s now build value+closure child structs instead of capturing the
  whole `WaveformView`, so each row is its own AttributeGraph node — the biggest
  `initializeWithCopy for WaveformView` source, and SwiftUI's first real skip boundary.
  `channelLabel`/`waveformRow` remain as thin parent-side builders that resolve the
  derived per-channel state. Verified: clean Debug build, full `EVATests` (412 pass),
  open-recording launch smoke test (Flanker) with no crash.
- [x] **B2. Extract the panels** — **complete 2026-08-13**, in the sense that
  everything measurement supports is done and the rest is explicitly declined
  below. Six extractions landed; three items were dropped on evidence.

  **One piece survived, re-scoped — and is now done (2026-08-13).**
  `ControlsBar` is dead as a *view* extraction (0.28% — see below), but
  re-rooting its actions was still wanted, justified by `REWIND.md` rather than
  by performance: an action that lives on `WaveformView` is a stage the history
  tree cannot replay headlessly.

  **Five actions, not thirty-five.** Most of the toolbar opens a sheet or flips a
  display flag; those are view concerns and stay on the view. The ones that
  matter are the five that *change what the exported samples are*, because each
  is a node in the history tree — `REWIND.md` names one directly ("turn artifact
  correction off is a real node"). Now in `PipelineStageToggles`
  (`EVA/Pipeline/PipelineStageToggles.swift`), same shape as
  `PipelineInvalidation`: free functions over explicitly-passed collaborators.
  Each returns whether it actually changed anything, so a caller recording
  history nodes can tell a real toggle from a redundant click. Covered by
  `PipelineStageTogglesTests` — 13 tests that could not exist before, because
  these were methods on a `View`.

  Two defects fell out of the extraction, both invisible from the call sites:
  - **`clearEpochs` had drifted from the shared cascade.** "Undo Segmentation"
    re-listed ~14 of `PipelineInvalidation.epochsAndDerived`'s assignments by
    hand and had fallen out of step: it never cleared `showsOverlaidCategories`.
    Latent rather than visible (the panel is also gated on `isAveraged`), but
    re-segmenting after an undo could bring back a panel nobody asked for. It now
    delegates. Exactly the hazard `PipelineInvalidation` exists to remove,
    reappearing because this copy lived on the view where the shared definition
    could not reach it.
  - **`bcgDefinedArtifactID` was a `let … = UUID()` on the `WaveformView`
    struct.** A `let` initialiser on a `View` runs whenever SwiftUI re-initialises
    the struct; if it ever did, every lookup keyed on that id — updating the
    artifact, removing it on disable, invalidating its OBS variance cache — would
    silently miss and strand a stale artifact. Now `BCGDetectionViewModel
    .definedArtifactID`, tied to the detector's lifetime rather than the view's.

  **The stage-*applying* actions followed the same day, and B2 is now closed in
  full.** Every action that changes the derived signal has its pipeline half off
  the view:

  | Action | Where it lives now |
  |---|---|
  | ICA component removal | `ICAComponentRemoval` — plus a `ProcessingCore.icaClean` case fed by the input package's own `eva_ica.json`, and a per-**file** headless batch gate. See `REWIND.md`. |
  | Average current epochs | `PSAAveraging.commit` |
  | Drawn-artifact cleaning | `ArtifactCleaningCore.commit` |
  | Gradient, filter, wavelet, segment | already VM-level; `ProcessingCore` drove them before this work |

  The split each time: the **pipeline** half moves (publish the signal, cascade
  the invalidation, stamp provenance); the **view and session** half stays
  (cancellable tasks, `recordingSessionID` guards, progress bridges, sheets,
  viewport, the replay gate). That boundary is not arbitrary — the window between
  "computed" and "still current" belongs to whoever owns the task, which is the
  same reason `EpochingViewModel.buildAndPostProcess` takes an `isCurrent`
  closure rather than checking for itself.

  **Two of the three did not gain a `ProcessingCore` case, on purpose.**
  Averaging existing epochs has no step of its own in `eva.xml` (it is a
  parameter of `segment`). Artifact cleaning is defined by hand-drawn templates
  with no persisted form — that is the remaining piece of `REWIND.md` work item
  4, and until templates round-trip through the package a headless run has
  nothing to re-apply. The extraction still pays: both cascades are now testable
  and exist once instead of waiting to be copied.

  Original plan, for reference — one at a time, in trace-hot order: `EventsPanelView`
  (see C1), `WaveformAreaView` (takes the extracted rows), `ControlsBar`, then
  `PhysioPaneView` / `TopomapPanelView` / `StatusLogView`. Each gets value inputs +
  action closures or a single narrow `@Observable` model — never the whole
  `WaveformView`. Landing B1+B2 closes the old TODO P2 render-struct item.

  **Now the last open Priority 1 item, and B4 set it up:** the four
  `@Observable` UI models are exactly the "single narrow model" an extracted
  panel should take (`EventsPanelView` takes `WaveformEventDisplayModel`,
  `PhysioPaneView` takes `PhysioDisplayModel`, `StatusLogView` takes
  `RecordingStatusModel`). As each panel starts reading its model directly, the
  matching forwarding properties on `WaveformView` come out — that is how B4's
  scaffolding gets retired, and it is the measurable end of
  `initializeWithCopy for WaveformView`.

  **Progress 2026-08-12 — first panel + the label-row win landed.**
  - [x] **`EventsPanelView`** extracted to `EVA/Waveform/EventsPanelView.swift`,
    with `EventCodeChip`. Value inputs + 4 action closures, `Equatable` on
    `(eventsKey, selectedEventCodes, selectedEventID)` and `.equatable()` at the
    call site. `eventsKey` is the `WaveformDisplayedEventsCache.Key` that
    `content(for:)` already computes once per pass, threaded down through
    `workspaceContent`/`waveformWorkspace` — so equality is a cheap signature
    compare, never an `[MFFEvent]` walk. Removed from `WaveformView`:
    `eventsPanel`, `codeChip`, `groupedEventSummaries`, `filteredEvents`,
    `eventMetadataRows`, `eventAccessibilitySummary` (~142 lines).
    `formattedEventTime` stays (two other files call it) but now delegates to the
    panel's `static` version so they cannot drift.
  - [x] **C1 is closed by this, and better than as specified.** C1 asked for a
    cache because `groupedEventSummaries`/`filteredEvents` ran every body pass.
    With the panel `Equatable` on its own inputs, unrelated changes — drag ticks,
    progress ticks — no longer re-run the body at all, so the derived lists are
    *not recomputed* rather than recomputed-and-cached. They stay plain `let`s.
  - [x] **`ChannelLabelRow` is now `Equatable` + `.equatable()`.** Required
    making `ChannelHealthResult`, `ChannelHealthMetric`, and `ChannelHealthGrade`
    `Equatable` (all synthesized).
  - [ ] **Dropped: hoisting the per-row "Move … to Physio" string.** The trace
    does not support it — `eegChannelDisplayName` is **1 sample**. Recorded here
    so it isn't re-proposed from first principles later.

  **2026-08-12/13 — remaining panels. Three extracted, two deliberately not.**
  - [x] **`TopomapPanelView`** (`Waveform/TopomapPanelView.swift`). Value inputs +
    closures; the parent resolves the scalp values. Intentionally *not*
    `Equatable`: its input is the `[Double]` sample slice, which changes exactly
    when the panel needs redrawing, so an equality key would compare the very
    data it is meant to skip.
  - [x] **`StatusLogView`** (`Waveform/StatusLogView.swift`), with
    `StatusLogSnapshot`, `StatusLogLine`, `StatusLogProgressRow`,
    `OperationProgressSummary`, `StatusLogProgressRowView`, `StatusLogLineView`.
    This one reads **eight** view models, so taking model references would
    re-render it on any change to any of them. The parent flattens them into an
    `Equatable` snapshot instead, and the view is `.equatable()` — it now
    re-renders only when the *displayed* status changes. `LogLine` (nested,
    private) became the shared `StatusLogLine`.
    **This is the progress-consolidation seam.** `REWIND.md` replaces per-VM
    `operationProgress` with one queue; `StatusLogSnapshot` is exactly the
    aggregation boundary that migration needs, so when the queue lands only the
    snapshot *builder* changes, not the view.
  - [x] **`PhysioPaneView`** (`Waveform/PhysioPaneView.swift`). Takes
    `PhysioDisplayModel` directly — unlike the status log, every property on that
    model affects what it draws, so flattening would be parameter noise for no
    gain. The two context menus arrive as generic `@ViewBuilder` closures. The
    `.task(id:)` range recompute and the rename `.alert` stay on the
    `WaveformView` side: they are state plumbing, not rendering.
  - [x] **`WaveformCursorOverlay` / `WaveformSelectionOverlay` /
    `WaveformArtifactHighlightOverlay`** (`Waveform/WaveformOverlays.swift`), all
    `Equatable`, taking pre-resolved content-space x ranges. These are the three
    overlays that redraw *during a selection drag* — the exact window where the
    trace shows `initializeWithCopy` spiking — and as methods each was a closure
    capturing `self`, so every drag tick copied the view struct six times over.
    `segmentHealthOverlay`/`epochBoundaryOverlay` were left alone on purpose:
    neither changes during an interaction, so extracting them is churn without a
    measured reason.

  - [ ] **`WaveformAreaView` — do NOT extract as one struct.** Evidence: the area
    carries 6 overlay closures, a `some Gesture`, scroll-geometry plumbing, and
    ~10 pieces of two-way state. As a single struct those become **7+ generic
    parameters**, and deep generic nesting is precisely what made the body's type
    metadata cost 358 ms to instantiate (see B3). A naive extraction here could
    make things *worse*, not better. The overlay extractions above are the part
    of this item that was worth doing; the rest of the area's cost is the row
    `ForEach`, which B1 already bounded.
  - [ ] **`ControlsBar` — extraction alone does not pay.** It references 12 view
    models across 35 interactive elements. Moving it to its own struct requires
    passing ~35 action closures, and **those closures are created in the parent
    and capture `self` anyway** — so the `initializeWithCopy` cost the extraction
    is meant to remove simply moves into the closure list. The prerequisite is
    re-rooting those actions onto the view models so the closures capture a VM
    instead of the view. That is a view-model refactor, not a view refactor, and
    it should be scoped as its own item.

  **`trace3.trace` (2026-08-13, Release, 57.9 s) — B2/B4 verified, and two of my
  own hypotheses disproved.** Compared as % of main thread, since trace3 ran 1.8×
  longer than trace2.

  | Frame | trace2 | trace3 | |
  |---|---|---|---|
  | `initializeWithCopy for WaveformView` | 1.48% | **0.33%** | −78% |
  | `ChannelLabelRow` | 1.32% | **0.20%** | −85% |
  | `channelLabel` | 1.23% | 0.20% | −84% |
  | `content(for:)` | 3.14% | 1.58% | −50% |
  | `ForEachChild.updateValue` | 5.84% | 3.11% | −47% |
  | any EVA `WaveformView` symbol | 9.76% | 5.91% | −39% |

  **B1's success criterion is now met** — `initializeWithCopy` is out of the top
  frames and `channelLabel` no longer appears among its callers. The single
  biggest lever was the one-line `Equatable` on `ChannelLabelRow`, not any of the
  larger extractions. Extracted panels are effectively free: `StatusLogView`
  0.02%, `EventsPanelView` 0.01%, the three overlays 0.01%, `PhysioPaneView` 0.00%.

  Two corrections to earlier claims in this document:
  - **Observation overhead did *not* increase** (the B4 worry below): total
    Observation 6.38% → **5.10%**, `RecordingStore.access` 0.49% → 0.42%,
    `ChannelModel.access` 0.30% → 0.17%. B4 did not trade struct-copy cost for
    tracking cost.
  - **The 358 ms hang was only ~a quarter sheets.** B3 halved the sheet term
    (8.72% → 4.57% of the hang) exactly as intended, and the hang fell 358 → 302 ms
    — but the dominant term in *both* traces is
    `ModifiedContent<ModifiedContent<opaque .task, _AppearanceActionModifier>, …>`
    at ~62%: the `.task`/`.onAppear`/`.onChange` chain, not the sheets. Deferred
    by decision 2026-08-13 (one-time, at first file open).

  **`ControlsBar` ruled out by measurement.** `WaveformView.controls` is 0.28%
  inclusive / 4 self samples, and `initializeWithCopy` is already down 78%, so the
  stated precondition for extracting it ("if it's still prominent, controls is the
  remaining source") was not met. The *architectural* case — re-rooting its actions
  onto view models so REWIND can replay stages headlessly — is unaffected and
  tracked separately.

  **Open question for the next trace, created by B4.** Under the row builders,
  `RecordingStore.access(keyPath:)` is 136 samples and `ChannelModel.access` 46 —
  that is Observation's per-read tracking. B4 moved 37 properties behind
  `@Observable` models, so per-row reads that were plain struct-field loads now
  register an observation access. B4 should still be a net win (it removes
  struct-copy cost, which was much larger), but this is **not** a pure win and
  should be confirmed rather than assumed. If per-read tracking shows up hot,
  the fix is for extracted panels to take plain values instead of reading the
  model through a forwarder — which is what the rest of B2 does anyway.
- [x] **B3. Collapse the `.sheet` modifiers into one host.** (2026-08-12)
  **18 → 1.** New `EVA/Waveform/WaveformSheetHost.swift`: an
  `enum ActiveRecordingSheet: Identifiable` (18 cases), a computed
  `WaveformView.activeSheet` deriving the active case from the existing per-VM
  presentation booleans in the original chain order, an `activeSheetBinding`
  whose `nil` write clears only the flag that is presenting, and a
  `sheetContent(_:base:cleaningBase:waveletInput:continuousSignal:)` builder.
  `content(for:)` now carries a single `.sheet(item:)`.

  No call site changed: `epoching.showsSheet = true` still opens PSA. Because the
  booleans are *derived* rather than each owning a modifier, they can be retired
  VM-by-VM later with no further view surgery. Four members lost `private`
  (`showsDatasetInfo`, `showsChannelGoodnessSettings`,
  `blinkChannelOverrideText`, `movementChannelOverrideText`) so the host can
  reach them; each is commented.

  **The measured justification turned out to be different from the one written
  here, and better.** It is not `find1` churn. In `trace2.trace` the session's
  *only* hang — 358 ms, at first display of the recording — was **98% Swift
  type-metadata instantiation** under `WaveformView.bodyChrome.getter`:
  `decodeMangledType`, `_checkGenericRequirements`, `_gatherGenericParameters`,
  `swift_getTypeByMangledName`, and `lazy protocol witness table accessor for
  type ModifiedContent<…>` — with the mangled names naming
  `View.sheet(isPresented:onDismiss:content:)` explicitly. Each chained `.sheet`
  adds a `ModifiedContent<…>` layer, so the body's concrete type became a deeply
  nested generic whose metadata costs ~350 ms to build on first use (once —
  metadata is cached, which is why there was exactly one hang). Collapsing 18
  layers into 1 attacks that directly.

  Verified: clean build (0 warnings), `EVATests` pass, launch smoke test with no
  runtime sheet warnings in `log show`. **Re-trace to confirm the 358 ms
  first-display hang shrinks** — that is the specific number to watch.
- [x] **B4. Move the `@State` into a few `@Observable` UI models.** (2026-08-12)
  **104 → 67.** New `EVA/Waveform/WaveformUIModels.swift` with the four models
  from the plan, hung off `RecordingStore` beside `channels`:
  `WaveformSelectionModel` (selection/drag/topomap sample/hover/highlight/scroll
  request), `WaveformEventDisplayModel` (events panel + the two derived-list
  caches + category-group popover), `PhysioDisplayModel` (the 8 `physio*` +
  synthetic PNS), `RecordingStatusModel` (status message/history/dedupe +
  the two disclosure flags). `StatusHistoryEntry` was lifted out of `WaveformView`
  to sit beside the model that owns it.

  **Scope note — the forwarding properties were kept, deliberately.** The plan
  says to delete them "once children read the store directly"; doing that now
  means editing all ~20 `extension WaveformView` files, which is B2's job and
  would have made this change unreviewable. So `WaveformView` keeps a
  `get`/`nonmutating set` forwarder for every moved property — the same pattern
  `RecordingStore` already used for the viewport — and **no extension file
  changed**. The forwarders are scaffolding to remove during B2.

  Migration gotcha worth remembering: a forwarding *computed* property has no
  `$` projection, so the 10 sites needing a real `Binding` (`TextField`,
  `Picker`, `popover`, `DisclosureGroup`, `scrollPosition`) had to change. They
  go through one generic helper, `binding(recordingStore.events, \.categoryGroupName)`,
  rather than 10 hand-written `Binding(get:set:)` pairs. Everything else — reads
  and plain writes — was untouched. Worth grepping `\$name` before moving any
  further state; that set is the only real work in a move like this.

  Still `@State` and intentionally so: the 16 domain view models (A2's
  convention), the 16 `Task` handles (cheap, lifecycle-bound), the
  `*Request` counters that drive `.onChange` menu plumbing, and the remaining
  sheet flags (which B3 already reduced to derived inputs).
  Verified: clean build (0 warnings), `EVATests` pass, launch smoke test with no
  "Modifying state during view update" or publishing warnings in `log show`.
- [x] **B5. Retire `extension WaveformView` for *new* view code.** (2026-08-12)
  Header note added to `WaveformView.swift` covering both halves: new *views* go
  in standalone `View` structs (pointing at `WaveformChannelRows.swift` as the
  pattern), and new *state* goes on the `@Observable` models in
  `WaveformUIModels.swift` rather than a new `@State`. Cites the measured
  `initializeWithCopy` cost so the reason is on the page, not just the rule.

### C. Body-work hygiene (small, independent wins)

- [x] **C1. Cache `eventsPanel`'s derived lists.** (2026-08-12) Closed by the
  `EventsPanelView` extraction in B2 — and without a cache. Making the panel a
  standalone `Equatable` view means the derived lists aren't recomputed on
  unrelated body passes in the first place. See B2 for detail.
- [ ] **C2. Hoist `EventTrackEventSignature(events:)`.** Built O(events) every
  `waveformArea` pass just to compare against the cached summary — compute it where
  the events list itself changes and store it alongside.
- [ ] **C3. Make `displayedEvents` cache misses async.** On key mismatch the body
  computes the full list synchronously before `onChange` refreshes the cache.
  Follow the resolver pattern: render stale/empty on miss, fill via `.task(id:)`.
- [x] **C4. Cache `ChannelModel.interpolationSnapshot`.** (2026-08-12) Now memoized
  on `interpolationState.revision` via an `@ObservationIgnored
  cachedInterpolationSnapshot`. The `@ObservationIgnored` is load-bearing: the
  snapshot is built lazily inside a getter that view bodies call, so a *tracked*
  cache would register a mutation during view update and re-invalidate the reader
  that just read it. Safe because every mutation path funnels through
  `interpolationState` and bumps `revision`, and the state is never reset to a
  fresh `InterpolationState()` — so the revision is monotonic and the key cannot
  go stale. Reading `interpolationState` in the getter still registers the
  observation dependency, so refresh behavior is unchanged.
- [ ] **C5. Audit the `.task(id:)` signature functions.**
  `artifactDetectionRequestID(for:)`, `channelHealthSignature(for:)`,
  `segmentHealthRequestID(for:)` run every body pass — confirm each is O(1)-ish over
  the signal (hash of revisions/counts, not of samples). Give any that touch sample
  data the `dataRevision` treatment.

### D0. Horizontal wheel-scroll jank — `LazyVStack` in a horizontal `ScrollView`

- [x] **Fixed 2026-08-13** (needs user confirmation by feel/re-trace). Reported
  symptom: mouse-wheel *horizontal* scrolling hitches, while the option-key jump
  bar, vertical scrolling, and click-drag selection all feel smooth.

  `trace3.trace` localizes it exactly. In the wheel-scroll window (t≈12–19 s),
  **~30% of main-thread CPU is `LazyVStack` placement**: `LazyStack.place` 10.6%,
  `LazyStack.resolveIndexAndPosition` 10.5%, and
  `StackPlacement.measureBackwards`/`flushBackwards` 9.1%. Those frames are
  **absent entirely** from the click-drag window, which is what pins the cost to
  scrolling rather than to rendering — and matches the report that dragging feels
  fine.

  Cause: the waveform rows lived in a `LazyVStack` whose scroll container is the
  *horizontal* `ScrollView`. A lazy stack re-runs its placement algorithm when its
  container's offset changes, but its laziness is vertical and governed by the
  *outer* vertical `ScrollView` — so it paid the cost on every wheel tick without
  getting the benefit. Now a plain `VStack`; the rows are `.equatable()`, so
  building them eagerly is cheap (`WaveformChannelRow` is 0.55% of the whole trace).

  The label-column `LazyVStack` is **unchanged** — it sits directly inside the
  vertical `ScrollView`, so its laziness is real.

  Reverting is one word if it regresses vertical scrolling on a high-channel-count
  file; that is the risk to watch, since a plain `VStack` materializes every row.

### D. Rendering (only if a re-trace still shows Canvas cost)

~~`metal_options.md` covers GPU *compute*~~ — **GPU compute has since landed**
(`GradientMetalBackend`, `LocalTemplateMetalBackend`, `WaveletMetalBackend`), so
`metal_options.md` is now historical for those paths. This section is the
CPU-side *drawing* step, still untouched.

- [ ] **D1. Per-channel min/max downsample pyramid.** If `WaveformPlot`'s Canvas
  re-reduces full-resolution `[Float]` per draw at wide zooms, precompute a
  2×/4×/8× min-max pyramid per channel keyed by `(signal.dataRevision, channelIndex)`
  (the `dataRevision` added on `july13` makes this key trivially correct). Reuse/
  extend `Downsampler.swift`.
- [~] **D2. Skip-equal plots.** *Structural half done 2026-08-12; the trace
  confirmation is still outstanding and needs a human at the keyboard.*

  **The lesson, worth keeping:** `.equatable()` skips a row's **`body`**, not the
  parent's **construction of that row's inputs**. Every drag tick writes
  `dragSelectionEndSample`, which invalidates `WaveformView.body` → `content(for:)`
  → `waveformArea` → the channel `ForEach`, so `waveformRow(index:…)` still runs
  once per channel per tick to build the struct that `==` then compares. Anything
  expensive in *building* those inputs is charged per channel per frame and is
  invisible to `.equatable()`. Audit input construction, not just the row body.

  Found and fixed by that audit:
  - `WaveformView.waveformTimeMarkerStyle` ran `JSONDecoder().decode(...)` +
    `normalized()` on **every access**, and is read once per channel row
    (`ChannelsPanelViews.swift:214`) — 128–256 decoder allocations per body pass.
    Now goes through `WaveformTimeMarkerStyleCache`, a `@MainActor` one-entry memo
    keyed on the raw `Data` (~150 bytes to compare vs. a full decode). Preferred
    over a `@State` cache refreshed in `onChange` because it can never serve a
    stale value for a frame. Also fixes the per-pane read in `PhysioPaneViews:218`.
  - `WaveformTimeMarkerStyle.defaultData` was a *computed* property running
    `JSONEncoder` on every access, and it is the `@AppStorage` default at three
    declaration sites — so it re-encoded on every containing-view `init`. Now a
    `static let`.

  Still to do: re-run the Instruments template (SwiftUI + Hangs>250 ms +
  high-frequency Time Profiler, Release) and do a selection drag over a
  high-channel-count recording, confirming (a) `WaveformPlot`'s `Canvas` does not
  appear per-row in the drag frames — only the overlays should redraw, per the
  overlay-layering comment in `waveformArea` — and (b) `JSONDecoder`/
  `WaveformTimeMarkerStyle.decoded` is gone from the profile. Diff against
  `~/Desktop/eva_hang.trace`.

  Remaining per-row construction cost, measured against that trace before
  optimizing further (all O(1) but not free at 256 channels × 60 fps):
  `activeSelectionRange(in:)`, `channelColor(_:)`, `displaySampleStride(for:)`,
  and the `"Move \(eegChannelDisplayName(…)) to Physio"` string interpolation,
  which allocates two strings per row per pass. The string is the obvious next
  candidate if the trace still shows row-construction cost — it only changes when
  `signal.channelNames` does.

  **`trace2.trace` results (2026-08-12, Release, 32 s: open → scroll → selection
  drag). Both D2 fixes confirmed, and one criterion still failing.**
  - Fixes landed: `JSONDecoder` 9 samples (0.02% of main thread),
    `WaveformTimeMarkerStyle` 8 (0.01%), `interpolationSnapshot` /
    `applyingInterpolations` **0**. All three are effectively out of the profile.
  - **D1 is not justified — do not build the pyramid.** `Canvas` /
    `GraphicsContext` is 1.44% inclusive, 85 samples self. Drawing is not the cost.
  - Rows are cheap now: `WaveformChannelRow` 235 inclusive, `WaveformPlot` 459.
    The `.equatable()` skip is doing its job.
  - **`initializeWithCopy for WaveformView` is still present** — 804 samples
    (1.48%), and it *spikes during the selection drag* (133–159 per 0.5 s at
    t≈21.5, 25.0, 27.5, 28.0). B1's success criterion ("drops out of the top-20
    frames") is **not met**. Remaining `self`-capturing closures are the cause,
    which is B2/B4's territory.
  - **New, cheap, actionable:** `ChannelLabelRow` was never made `Equatable` —
    B1 did that only for `WaveformChannelRow`. The label column costs **3× the
    trace rows** (721 vs 235 inclusive) and `WaveformView.channelLabel(index:signal:)`
    shows up as a direct caller of `initializeWithCopy`. Giving `ChannelLabelRow`
    the same `Equatable` + `.equatable()` treatment is a small change with a
    measured payoff; do it with B2.
  - Cautionary note for the next trace read: `EventTrack` looks hot at 4.19%
    inclusive, but 86% of that is `-[NSWindow trackEventsMatchingMask:…]`, AppKit's
    nested drag-tracking run loop — not EVA compute. Check callees before
    treating an inclusive number as a hot spot.

### Sequencing & measurement

1. **A1** — done. 2. **A3** (small). 3. **B1** (highest structural leverage).
4. **A2** (domain-by-domain; interleave with B2 extractions where files overlap).
5. **B3, B4, C1–C5** as their files get touched. Re-run the exact same Instruments
template (SwiftUI + Hangs>250 ms + high-freq Time Profiler, Release) after A1, B1,
and the first two VM migrations. Success criteria:
- after A1: no hang train during filter/gradient/ICA runs;
- after B1: `initializeWithCopy for WaveformView` drops out of the top-20 frames;
- after A2 (first 4 VMs): `find1`/AttributeGraph churn visibly down; no >500 ms
  hangs in a normal interaction session.

Keep `eva_hang.trace` (`~/Desktop/eva_hang.trace`) as the baseline to diff against.

---

## Priority 2 — Finish the processing / batch suite

The suite is functionally complete (see **Done / status**); these are the
deliberately-deferred edges, none blocking normal use.

- [ ] **Mid-script resume / partial-then-resume.** Today a script with any decision
  step never runs *any* of it headlessly, even a leading fully-portable prefix.
  `ProcessingCore.Result.remainingSteps` could support running the prefix headless
  then handing the partially-processed signal to a windowed session — the missing
  piece is "load a partially-processed signal into a fresh windowed session."
- [ ] **"Skip all decisions" batch switch.** Optional policy letting a batch with an
  ICA/artifact step run headlessly by dropping those steps per file (vs. today's
  whole-script all-or-nothing boundary).
- [ ] **`BatchSetupSheet` compatibility pre-check.** The config screen doesn't
  pre-check step/file compatibility (files aren't loaded when the script is picked).
  Run-time protection already covers both batch paths; this is a nicety only.

---

## Priority 3 — Feature follow-ups (not blocking anything)

### Export formats
Note: BESA **import** landed in the meantime (`BESAASCIIReader`, `.avr`/`.mul`);
`.generic` import is scaffolded but deliberately disabled pending sample files,
and `.foc/.fsg` are declined (no public byte-level spec). Export is still absent.
- [ ] **BESA Connectivity export** — BESA `.generic` format (raw binary + `.generic`
  text header: channel count, sampling rate, etc.; check BESA's Generic Data spec
  for exact header fields). For handing continuous/averaged data to BESA Connectivity.
- [ ] **BESA Statistics export** — BESA ERP/ERF ASCII Vectorized File Format (`.avr`),
  a plain-text averaged-waveform format BESA Statistics reads directly. The `.avr`
  reader already exists, so the writer is mostly the same layout inverted.

### Physio (PNS)
- [x] **File → Import Physio** for GE-scanner and Biopac text exports —
  `PhysioImportViews.swift` / `PhysioTextImporter.swift` shipped.
- [ ] Still open: automatically map aux/bio channels into `pnsSignal` for the
  non-MFF importers (BrainVision/EDF). `SignalImportReader` carries a `pnsSignal`
  field but only the MFF path populates it; other formats need the manual import.

### ECG / QRS detection
- [ ] Engzee / Engelse-Zeelenberg QRS detector — classic slope/intersection detector
  as a transparent comparator to Pan-Tompkins/Hamilton/WFDB/Wavelet/Christov.
- [ ] Hilbert / energy-transform QRS detector — own tab or internal feature transform
  for noisy ECG/PNS channels.

### Resting-state EEG analysis
- [ ] Editable spectral bands (currently fixed delta/theta/alpha/beta/low-gamma) —
  add once the first dashboard workflow settles.

### FASTR (fMRI gradient removal)
- [ ] **MRI gradient correction: motion semantics, replay, and unreliable-epoch
  artifacts** (design agreed 2026-07-04):
  - **Moosmann motion threshold semantics.** Default: strict Bergen behavior
    (threshold translation-speed changes only, ignore rotation). Add an unchecked
    `Use FD threshold for Moosmann` for EVA's full framewise-displacement metric
    (translation + rotations → mm via configured radius). UI must make the
    distinction explicit rather than presenting both as the same "FD threshold."
    *(2026-08-12: the shipped UI does the opposite — `MotionConfigView` states
    "Moosmann uses the same threshold with the RP-info metric above." Decide whether
    that is now the intended behavior or unintended drift from this design.)*
  - **Explanation popovers for MRI options.** FASTR-family controls are wired
    correctly (`FASTR`/`FARM`/`Moosmann` share the pipeline; shared Slices/volume,
    sub-sample alignment, OBS, ANC apply to all three) but have hover help only. Add
    real `?` popovers for every MRI-gradient option.
  - **Replay/headless motion requirements.** Serialize the Moosmann metric + any
    unreliable-epoch artifact setting into `eva.xml`. If a step requires motion
    (`Moosmann`, or AAS/FASTR/FARM with high-motion donor exclusion), don't silently
    run without it: interactive replay pauses on the MRI review step; headless stops
    with a compatibility issue unless batch was given a motion-file resolver.
  - **Correction diagnostics.** AAS/FASTR return coverage diagnostics (volume index,
    start time, duration, method, reason, severity). Track normal edge TRs in the
    summary but don't mark them as artifacts by default; mark true fallback/failure
    (no usable donors, out-of-bounds template windows, all clean donors censored).
  - **Mark unreliable MRI-correction epochs as artifacts.** Default-on MRI-sheet
    option generating duration-bearing `MRI_GRAD_UNRELIABLE` events for TRs/epochs
    that couldn't be corrected reliably — gradient-owned provenance events, not
    generic ocular detections later overwritten.
  - **PSA integration.** Add a PSA rejection row for "MRI correction unreliable" and
    include the events when `Segment On: Artifact` is selected. Switch artifact
    rejection to interval-overlap using `MFFEvent.durationSeconds` — the current
    start-time-only check misses an epoch overlapping the middle of a marked TR.
  - **Tests.** Strict-Bergen default, optional FD behavior, missing-motion
    compatibility failures in replay/headless, no-template diagnostics,
    duration-bearing unreliable events, PSA interval-overlap rejection, and
    `Segment On: Artifact` visibility for MRI unreliable events.
- [ ] Investigate FASTR signal attenuation — `preservesNonArtifactSignal` shows
  correlation only ~0.5–0.7 on non-TR-locked physiological signal (AAS >0.85);
  likely AAS alpha-scaling leakage + approximate windowed-sinc interp/decimate.
  Test uses a conservative 0.5 floor.
- [x] True iterative sub-sample alignment — **done** (verified 2026-08-12).
  `GradientEpochAligner` estimates a per-epoch `fractionalShifts` array and both the
  CPU path and `GradientMetalBackend` apply it. The old "plumbed but not applied"
  note was stale.

*(Dropped 2026-08-11: MATLAB/FACET reference validation and the bit-for-bit
odd/even neighbour-averaging and `decimate2` group-delay parity items. EVA's
gradient correction is its own implementation and is validated on its own terms —
synthetic-artifact tests plus the attenuation work above — not against a
reference toolbox's exact numerics.)*
- [ ] aff12 affine motion decomposition for the motion panel.

---

## App-level fixes (2026-08-13, revised 2026-08-15)

- **Double window on a Finder open — fixed 2026-08-13, then reopened by
  design 2026-08-15.** `EVAApp` originally used a `WindowGroup`, which can
  instantiate more than one window, and macOS does: on an open-file event the
  group creates its launch window *and* spawns a second one to deliver the
  URL to, so you got two windows with the recording in the front one.
  Intermittent because it depended on whether the Apple event landed before
  or after the launch window existed.

  The 2026-08-13 fix was `Window("EVA", id: "main")`, single-instance by
  construction. That held until EVA needed real multi-window support
  (REWIND.md "EVA as a multi-window app", 2026-08-15 — forking to a new
  window needs more than one `recording` to exist at all), which put
  `WindowGroup` back. The double-open risk didn't return with it: `recording`
  moved from `EVAApp`'s `@State` down into `ContentView`'s own, so each
  window instance now genuinely owns a different file rather than every
  window in the group rendering the same one — and `ContentView.onOpenURL`
  fills itself when its own `recording` is nil rather than always spawning,
  which is what keeps a *cold-launch* Finder double-click at exactly one
  window. Verified manually 2026-08-15 (see below) rather than only by
  construction this time.

- **Known gap, found in that same manual pass, left open on purpose.**
  Close a recording (window goes back to empty) and *then* double-click a
  file in Finder: `WindowGroup` was observed spawning a **fresh** scene for
  the open-file event rather than routing it to the already-open empty
  window. `ContentView.onOpenURL`'s "reuse if empty" check still runs — just
  on the new instance, whose `recording` is also nil, so it fills *itself*.
  Net effect: a stray empty window left next to the new one. Harmless
  (nothing lost, no confirmation dialog, just an extra window to close), but
  not what the code comment describes.

  **The real fix**: intercept the open request at the `NSApplicationDelegate`
  level — `application(_:open:)` on `EVAAppDelegate` (`WindowCloseBehavior.swift`,
  already the app delegate for the last-window-quits fix) — instead of
  `.onOpenURL`. That runs *before* `WindowGroup` decides whether to spawn a
  new scene, so EVA could check for an existing empty window itself and
  route to it, falling back to `openWindow` only when none exists. Not
  attempted yet: this needs its own small registry of "is there an empty
  recording window right now" (the `ContentView` instances would need to
  register/deregister themselves, similar in shape to `PendingWindowOpens`)
  and touches launch-routing internals this project has been burned by
  guessing at before (see the 0.1.7 double-window bug itself, and the
  `WindowCloseInterceptor`/`WindowAccessor` delegate-collision crash earlier
  the same week). Worth doing if the stray window turns out to bother people
  in practice; not worth the risk speculatively.

  **Verified by construction for the cold-launch case, by hand for the
  reopen case** — a Finder double-click is not reproducible from the build
  environment, so both were checked by a human, not a test.

- **Two real crash-causing bugs in the Batch window, found and fixed
  2026-08-15 by manual test — both were "missing environment, given to
  every other scene but this one."** `Window("Batch", ...)`'s content was
  never given `.environment(goodnessSettings)` /
  `.environment(segmentGoodnessSettings)` / `.environment(processingDefaults)`
  the way the "main" `WindowGroup` and `Settings` scenes are, and never got
  `.modelContainer(for: UserMarker.self)` either. `WaveformView` reads all
  three `@Environment(_.self)` values unconditionally, and
  `WaveformMarkerContainer`'s `@Query` needs a model container in scope —
  both are exactly the kind of missing-injection that SwiftUI turns into a
  hard crash (not a graceful fallback) the moment the view housing them is
  actually rendered. Reported as "shift-command-B crashed the application,
  as did Window ▸ Batch." Fixed by adding all four to the Batch window scene,
  matching the main scene.

  **Not fully explained, and worth saying so plainly**: `BatchSetupSheet` —
  what the Batch window shows *immediately* on open, before any of the
  fixed code paths render — does not itself touch any of the four missing
  dependencies, so this fix does not obviously explain a crash on simply
  opening the window before configuring anything. It was a real, confirmed,
  now-fixed bug regardless (it would certainly have crashed the moment a
  windowed batch run actually reached its first review step), but if the
  Batch window still crashes on bare open after this, that is a second,
  separate cause and needs its own crash log to chase rather than another
  guess.

- **Batch Process moved from the File menu to the Window menu**, alongside
  Debug Log / Channel Sets / Figure Export — found in the same test pass
  ("crashed... as did going to Window ▸ Batch," i.e. that is where it was
  looked for, not where it was). It had been placed in File out of habit
  from where the old `batchSetupRequest` counter used to live; now that it
  is a genuine single-instance utility window like the other three, it
  belongs where they are.

- **Window position/size were never actually being remembered — fixed
  2026-08-15.** Reported: two windows, repositioned differently, both
  snapped to "whichever moved most recently" after relaunch instead of each
  keeping its own spot. Cause: the per-window AppKit frame-autosave name was
  `@State private var windowInstanceID = UUID()` — regenerated fresh on
  every launch, so it could never match a name saved in a *previous*
  session, which means `setFrameAutosaveName` was never actually restoring
  anything. Worse, that call actively takes over frame persistence under
  its key, which likely suppressed whatever automatic per-window restoration
  `WindowGroup` provides on its own. Fixed by removing the custom
  frame-autosave call entirely — `WindowAccessor` now only handles the
  close-confirmation interception — on the reasoning that the platform
  default should take over once nothing is fighting it.

  **Unverified past that reasoning** — this fix has not itself been through
  a relaunch-and-check pass yet. If windows still don't remember their
  position after this, that is new information (the platform default isn't
  behaving as expected), not a sign the diagnosis above was wrong.

- **Channel Sets editor regressed to "no sensor layout available," fixed
  2026-08-15 by replacing the mechanism, not patching it.** The
  `ChannelSetFocusMirror` design (a `@FocusedValue`-based mirror living in
  `.commands`, added the same day as the multi-window work) turned out not
  to work at all — the editor reported no layout even with a recording open.
  Root cause not fully confirmed (see below), but the leading theory: an
  invisible, zero-size view mounted purely for a `.onChange` side effect
  most likely does not get re-evaluated by SwiftUI's command-content
  machinery the way a real, visible menu button does — `ChannelsCommands`
  and its siblings read `@FocusedValue` too, but they render actual buttons,
  which may be exactly what keeps them live.

  Replaced rather than debugged further: `WaveformView.publishChannelSetContext()`
  writes to `ChannelSetStore.shared` directly from three call sites — on
  load and on a channel-role edit (the original, pre-multi-window mechanism,
  restored unchanged) — plus a new one, `WindowAccessor`'s `onBecomeMain`,
  wired through a plain `NSWindow.didBecomeMainNotification` observer rather
  than through `@FocusedValue` at all. That's the one that makes the editor
  follow *focus* across multiple windows, which was the actual multi-window
  requirement the abandoned mirror was trying to satisfy.

  **Not done**: `BatchWindowView` has no `WindowAccessor` (it never needed
  the close-confirmation dance) and so has no `onBecomeMain` hookup either —
  its recording still publishes on load, just not on the batch window
  becoming main. Low priority (editing channel sets mid-batch-review is an
  edge case), but worth knowing if the editor is ever reported stale
  specifically while a windowed batch is frontmost.

- **`File ▸ New Window` added, 2026-08-15** — a blank window, nothing else,
  ⌘N. Raised as "I want to combine two files on disk, but there's no clear
  way to start that." Everything downstream already existed: an empty window
  already accepts a drop, dropping 2+ `.mff` files already shows the combine
  sheet, and that sheet already loads the result into the same window once
  you commit. The only missing piece was a way to *get* a blank window on
  purpose. Considered and set aside: a dedicated single-instance "Combine"
  window matching Batch's own — batch is a queue advancing through files
  chosen in advance, combine is "I just decided, right now, to drag these
  together," and the existing per-window sheet already fits the latter
  better. Also added a one-line hint on the empty-window screen itself
  ("drop two or more … to combine or average them"), since the capability
  existing was never the problem — nobody could see it was there.

## Channel Sets: a net-geometry catalog (2026-08-15)

Raised as a follow-on to the multi-window `activeSensorLayout` staleness fix:
`SensorLayout` had always come from exactly one place, a loaded recording's
own `sensorLayout.xml`, which meant creating or browsing channel sets
secretly required a recording open the whole time. Built the same day.

- **`KnownNetGeometry`** (`ChannelSet.swift`) — name + positions, a small
  catalog separate from `ChannelSet` itself, persisted to
  `netGeometries.json` next to `channelSets.json`. **Deliberately shipped
  empty** — the only sensorLayout.xml files in this repo are truncated test
  fixtures (13 sensors, sometimes 1, for nets that have hundreds), not real
  geometry, and fabricating electrode positions was ruled out outright: they
  feed directly into topomap rendering and spline interpolation weights.
- **Self-sourcing instead of bundling**: `ChannelSetEditorView` now shows a
  banner the first time it sees a real, focused recording's net that isn't
  in the catalog yet, offering to save it — defaulting to the file's own
  reported net name, editable. This is the *only* way the catalog grows,
  and it means every entry in it is real data from a real file, never a
  guess. Bundling the three common HydroCel nets (64/128/256) becomes
  "open one real recording of each, click save" whenever real files are
  available — no code change needed when that happens.
- **"+" now asks which net** — `netTypeControl`, a menu of
  `store.knownNetNames` (saved geometries *and* any net name already used by
  an existing set, so free-typed names are remembered too) plus free-text
  entry. Defaults to whatever net is currently focused, since "I have this
  file open, make a set for it" is the common case. Editable after the fact
  for existing sets too, not just at creation — `ChannelSet.netType` existed
  in the model since before this pass but nothing ever set it.
- **Rename, with merge-on-collision** — `ChannelSetStore.renameGeometry`,
  surfaced in a small "Manage Nets…" sheet (rename/delete list). Renaming
  onto an *existing* name is treated as a deliberate merge — the
  destination's already-saved positions win, the source's are discarded
  rather than silently overwriting real data, and every channel set tagged
  with the old name is reassigned to the new one. This is the direct answer
  to "typed '64 channel' two ways and now has two nets that need merging" —
  the rename operation *is* the merge.
- **Filter by net** in the editor's sidebar (a menu above the list; sets
  tagged "Any Net" stay visible under every filter, since they're explicitly
  net-agnostic) and in `ChannelSetPickerView` (`filterNetType`, a parameter
  its own doc comment had described since before this pass without it
  existing — now it does; defaults to `nil`/off, so none of the four
  existing call sites changed behavior, and none of them were wired to pass
  it yet — a fast-follow, not done here).
- **`ChannelSetStore`'s storage location became instance-scoped and
  injectable** (`init(testStorageDirectory:)`) specifically so this could be
  tested at all — the previous hardcoded static path meant any test
  exercising save/rename/delete would have silently read and written the
  real `~/Library/Application Support/EVA/channelSets.json`, mutating an
  actual person's saved sets. `.shared` is unaffected; only tests use the
  new initializer.
- **Explicitly deferred, per discussion**: cross-net comparison ("are these
  the same physical eye channels on two different nets") was raised and set
  aside on purpose — described as something a person does by eye, switching
  between two nets' set lists, not a capability EVA needs to compute. The
  net-name filter is what makes that toggling practical; nothing further is
  planned.

### BCG detection — Spatial PCA
- [ ] Seed Spatial PCA from a trajectory-strip frame picked in Define Artifact,
  bypassing the covariance step. Not implemented — no `seedMap` param in
  `BCGDetector.swift`; `template.trajectorySelectedFrame` (a single time-instant
  `[Float]`, one value per channel — not a multi-sample epoch) isn't wired to BCG at
  all. Needs a new param on `BCGDetector.spatialPCAEvents` (can't reuse
  `exemplarChannels`, which expects a full `[[Float]]` time series) that uses the
  picked frame as the seed spatial map, skipping covariance/PCA derivation — useful
  when the exemplar window is too short/noisy for a clean data-driven PC1.

---

## New design docs (written 2026-08-11, nothing implemented)

These are separate workstreams that post-date this roadmap; each has its own file.
- **`REWIND.md`** — history tree / real undo-redo, replacing the hand-written
  per-stage `clear*()` cascade. Flagged there as a correctness hazard by
  construction (a missed line leaves a stale downstream signal), which makes this
  the highest-value *non-perf* architectural item.

  **Started 2026-08-13.** Work items 1, 4-for-ICA, and 9 are built and item 5's
  first pass is done — `EVAHistory` (`EVA/Pipeline/EVAHistory.swift`),
  `ICAReplayPayload` (`eva_ica.json`, also closing `REPORTS.md` upstream item 1),
  and the determinism audit. Three things the audit turned up that belong here
  rather than only in `REWIND.md`:
  - **Four more instances of the `categoryGroups` bug class** — inputs a stage
    reads but does not serialize, so replay silently does something different.
    `FilterViewModel` (CleanLine window/strength, `filterPNS`),
    `GradientViewModel` (`skipStart`/`skipEnd`/`appliesToPNS`/`excludeHighMotion`),
    `EpochingViewModel` (`segmentField`), and `ICAViewModel` (9 fit inputs). All
    fixed, all covered by `ParameterSerializationAuditTests`, and **verified by a
    paired run the same day**: `signal1.bin` byte-identical, `eva.xml` identical
    apart from timestamps, and `sme` reproducible for the first time. Gradient's
    four keys and the `markBad` path were not exercised by that script — see
    `REWIND.md` for what remains unverified.
  - **`markBad` and `interpolateChannels` were declared operations that nothing
    ever emitted** — bad-channel marks and interpolation reached disk only as
    prose in `log_eva_*.txt`. **Fixed 2026-08-13** (`ChannelDecisionSteps`),
    emitted as `replayable: false` so replay behaviour is unchanged. Also closed
    a divergence: `HeadlessBatchProcessor` wrote back the script it was handed,
    so a batch run whose PSA escalation marked channels described a run that did
    not happen.
  - **`SeededGenerator`** (`EVA/Core/SeededGenerator.swift`) now exists; the SME
    bootstrap was the one unseeded RNG in the app. Use it, not
    `SystemRandomNumberGenerator`, in anything feeding a reported number or a
    written sample.
- **PSA unified — done 2026-08-13.** The interactive (`applyPSACore`) and
  headless (`applyBuildJob`) paths each carried their own copy of the
  build → average → post-process sequence. Every headless/interactive divergence
  found this session came from that duplication, so the sequence now lives once,
  in `EpochingViewModel.buildAndPostProcess`, and both call it. Only one
  `job.buildEpochs` call site remains in the codebase.

  The two blockers the old "PSA intentionally NOT unified" note cited are gone:
  escalation moved to `PSABadChannelEscalation`, and `segmentedEpochSignal` moved
  onto `EpochingViewModel` — so headless now caches the raw epochs too, which it
  previously did not.

  What deliberately stays per-path, because it is real variation rather than
  duplication — the shared core takes these as parameters:
  - **`excludedSegmentIndices`** — interactive supplies segments the user
    labelled bad in Segment Health. Those labels are session-only manual
    decisions with no batch equivalent, so headless passes none. **This is scope,
    not a bug**; it was tempting to "fix" and would have been wrong.
  - **`isCurrent`** — the interactive `recordingSessionID` guard, re-checked
    between phases because the view can outlive a run. Headless has no such
    concept.
  - **SNR scheduling** — interactive backgrounds it so the sheet closes
    immediately; headless awaits inline because it is about to export.
  - **Status composition and UI teardown** — view-only.

  Also folded in: `ButterflyPanelViews.categoryColorIndices` was a verbatim copy
  of `EpochingViewModel.colorIndices` and now delegates. The `MFFReader` and
  `RecordingCombiner` variants use *different* orderings (first-appearance and
  positional) and were deliberately left alone.

  **Byte parity confirmed for the unified core** (2026-08-13 10:59 paired run,
  *with* category groups active, which makes it a stricter test than the earlier
  one): `signal1.bin` **byte-identical**, `categories.xml` and `epochs.xml`
  identical, `categoryGroup.correct">LC++,RC++` present and equal in both
  `eva.xml`s, and the headless run produced the grouped `correct` category
  (trials=26) matching interactive. Only `sme` differs — see below.

  **Open, minor: `sme` is not reproducible run-to-run.** The 200-iteration
  bootstrap in `EpochSNR.standardizedMeasurementError` is unseeded, so paired
  runs differ (this run: 1.386 vs 1.146 on LI++, ~19% relative — larger than the
  ±0.005–0.016 seen earlier because these categories have fewer trials, 10–16,
  and higher SME overall). Not a parity defect and not a data defect: every
  sample and every other metric matches. But **`REWIND.md` should seed it** —
  "navigating back to a node returns you to the same data" is weakened if a
  reported metric changes on every recomputation.

- **Category grouping now round-trips through `eva.xml` — done 2026-08-13.**
  `categoryGroups` (pooling codes into an extra shared category) and
  `categoryRegexRules` (regex sub-selection on event description) were **never
  serialized**, while `categoryNames` was. So the script silently under-described
  the processing: Copy Processing, headless batch, and windowed replay all
  reproduced only the raw event codes.

  Found while trying to confirm PSA-unification parity — the comparison was
  impossible because the two runs weren't the same processing, and *that* was the
  bug. Now emitted as `categoryGroup.<name>` = comma-separated members, and
  `categoryRegex.<n>.{source,pattern,name,caseSensitive}` — one key per field so
  a pattern containing a comma or pipe cannot corrupt the encoding. Covered by
  `PSACategoryGroupingRoundTripTests`, including a pattern with a separator in it
  and an absent-grouping case that must leave defaults alone.

  Worth remembering as a class: **anything a stage reads but does not serialize
  is invisible to replay**, and shows up not as an error but as quietly different
  results. `REWIND.md`'s determinism audit (work item 5) should sweep every view
  model's `parameters` against the state its apply path actually reads.

- **Build version in `eva.xml` — done 2026-08-13.** `<evaProcessing appVersion="…">`,
  resolved once from the bundle as `"<short> (<build>)"`, and echoed into the
  `log_eva_*.txt` header. Read back into `EVAProcessingScript.appVersion`.
  Writing **always stamps the current build** rather than echoing the parsed
  value: a script replayed via Copy Processing carries the *source* package's
  version, and preserving it would attribute the new file to a build that never
  touched it. Covered by `EVAProcessingScriptXMLTests`, including that case.

- **Export panel intermittently never appeared — fixed 2026-08-13.** Menu commands
  arrive as `@State` request counters, so their `.onChange` handlers run inside
  SwiftUI's update, which AppKit performs within a CoreAnimation transaction
  commit. `NSSavePanel.runModal()` refuses to run there and AppKit logs
  *"Suppressing invocation of -[NSApplication runModalForWindow:] … cannot run
  inside a transaction begin/commit pair"* — the panel silently never opens.
  Intermittent because it depends on whether the command lands mid-transaction.
  `mffExportRequest`, `copyProcessingRequest`, and
  `channelLabelMetricsExportRequest` now hop through `afterCurrentTransaction`
  (a `DispatchQueue.main.async`, the same trick already used for the ICA sheet).
  Audited every other `*Request` handler: the rest only set booleans that drive
  `.sheet`, which is safe. Panels presented from button actions inside sheets are
  also unaffected — those run as event handlers, not during an update.

- **File-type provenance & override — done 2026-08-13.** Three related fixes,
  prompted by a headless batch run:
  - **Headless export was missing all subject-specific provenance.**
    `HeadlessBatchProcessor` called `MFFExportWriter.write` with no
    `auditLogLines` argument at all, so a batch package's `log_eva_*.txt` carried
    only the step lines — no `segment result:` bad-channel summaries, no
    `interpolateChannels result:` escalation record, no per-category
    `average SNR:` block. None of that is recoverable from the exported samples.
    Extracted `WaveformView.currentProcessingAuditLogLines()` into
    `EVA/Pipeline/ProcessingAuditLog.swift`; both paths now use it. Same failure
    shape as the invalidation cascade: logic on the view, so headless did less.
  - **`eva.xml` now records the file kind authoritatively.**
    `EVAProcessingScript.fileType` is written as a `fileType` attribute on
    `<evaProcessing>`, stamped by `MFFExportWriter` from the snapshot kind (the
    one place that knows for certain, serving both paths). `MFFReader` trusts it
    when present and falls back to the existing heuristic
    (`#seg` counts / `<name>Average</name>` / legacy `average=true`) for packages
    written before the field or by other tools. Grand-average detection still
    runs on read, since it depends on the segments' subjects.
  - **Dataset Info (⌘I) can override the type for the session.** Picker over all
    four kinds on `RecordingStore.fileTypeOverride`, with a "Reset" back to
    detection and a note showing what EVA detected. It **acts** rather than
    relabels: `applyFileTypeInterpretation()` adopts or drops the on-disk epochs
    and sets `epoching.isAveraged`, so choosing "Averaged" on a misread package
    genuinely enables the averaged workspace and butterfly plots. A misdetection
    can no longer block the work.

- **Headless/interactive parity — same file both ways, 2026-08-13.** First
  controlled comparison (`batch_in.mff` interactive vs `batch_out.mff` headless,
  identical source and script). Results:
  - **Passing:** identical trial counts per category (12/14/18/15), identical
    `perEpochBadChannels` summary, `fileType="averaged"` stamped and round-tripped
    both ways, and the audit provenance now present in the headless log.
  - [x] **Fixed: headless PSA had no electrode geometry.** `ProcessingCore` called
    `epoching.makeBuildJob` without `electrodePositions`, and
    `HeadlessBatchProcessor` never loaded `ElectrodeGeometry` at all — so
    `PSABuildJob`'s per-epoch bad-channel interpolation
    (`EpochBadChannelDetector.interpolate(… positions:)`) degraded to reject-only.
    Geometry is now loaded alongside the signal and threaded through
    `ProcessingCore.electrodePositions`. **Needs a re-run to confirm.**
  - [x] **SNR divergence — closed by the geometry fix** (confirmed
    `batch_out2.mff`). It was a *symptom*, not a separate bug: leaving channels
    8/21/25 raw changed the baseline-noise estimate. After the fix,
    `plusMinusSNR`, `baselineSNR`, `gfpSNR` and `splitHalfReliability` match the
    interactive run **to the digit on all four categories** (e.g. LC++
    baselineSNR 10.12 → 4.59, matching interactive exactly). `sme` differs by
    ±0.005–0.016, which is the 200-iteration bootstrap in
    `EpochSNR.standardizedMeasurementError` being stochastic — not a defect.
  - [x] **Globally-bad escalation now runs headlessly.** Extracted from
    `WaveformView.escalateBadChannelsIfNeeded` into
    `EVA/Epoching/PSABadChannelEscalation.swift` and called from
    `EpochingViewModel.applyBuildJob`, so both paths share one implementation.
    The interactive wrapper keeps only what is genuinely view-specific: the
    `recordingSessionID` guard and the status-line reporting.
    The outcome records `summaries` even when geometry is missing, so a headless
    run without geometry still reports which channels *would* have been escalated
    rather than silently omitting them.
    **Confirmed** (`batch_out3.mff`): the headless log's
    `interpolateChannels result: channels=8,21,25,
    escalatedFromPerEpochDetection=Ch8: 85%; Ch21: 64%; Ch25: 90%` line is now
    **byte-identical** to the interactive one.
  - [x] **Escalated channels' values — root-caused and fixed 2026-08-13.**
    The escalation ran headlessly and reported itself in the log, but the result
    was **discarded**: `applyBuildJob` assigns `epochedSignal = finalResult.signal`
    *before* the escalation block, the block patched only its local return value,
    and `HeadlessBatchProcessor` builds its export snapshot from
    `epoching.epochedSignal` — not from the returned signal. So the package
    shipped the raw channels while the log claimed they were interpolated. A
    wiring bug introduced when the escalation was first plumbed in, now fixed by
    assigning the patched signal back to `epochedSignal`.
    Diagnosis was measurement, not inspection: a fresh interactive run on the
    same build produced **byte-identical max differences** to the stale one
    (Ch8 8.9139, Ch21 48.7989, Ch25 28.1061 µV), which simultaneously proved the
    `PSABadChannelEscalation` extraction was behaviour-preserving *and* that the
    divergence was real and deterministic rather than a stale-build artifact.
    **Confirmed 2026-08-13** (`batch_in.mff` interactive vs `batch_out.mff`
    headless, both on the current build): **`signal1.bin` is byte-identical**, as
    are `categories.xml` and `epochs.xml`, and the provenance log matches except
    `sme` (bootstrap noise). Headless and interactive now produce the same package
    from the same input and script — the parity REWIND requires.
  - [ ] ~~Remaining divergence: the escalated channels' reconstructed values.~~
    After all three fixes, `categories.xml` and `epochs.xml` are byte-identical
    between an interactive and a headless run of the same file and script, and
    `signal1.bin` matches everywhere **except three channels**: 12,000 of 517,052
    float32 words differ (2.32%), and 3 of 130 channels is 2.31% — the escalated
    Ch8/Ch21/Ch25 and nothing else. Differences are substantive (mean 4.18 µV,
    max 48.8 µV, median relative 15%), so this is a different *reconstruction*,
    not float rounding.
    Ruled out so far: both paths pass `finalResult.signal` as the epoched input
    and load geometry through the same `ElectrodeGeometry.load`, and neither run
    had pre-existing bad/interpolated channels, so `excludedDonors` should be
    empty in both. **Not yet isolated.** The likeliest remaining cause is that
    interactive PSA still runs through `applyPSACore` while headless runs through
    `applyBuildJob` — the two implementations the "PSA intentionally NOT unified"
    note in **Processing / batch suite** describes. Closing this probably means
    unifying them, which is the larger follow-up that note already anticipates.

- **Shared invalidation cascade — done 2026-08-13** (precursor to `REWIND.md`
  work item 3). New `EVA/Pipeline/PipelineInvalidation.swift` +
  `EVATests/Pipeline/PipelineInvalidationTests.swift`.

  **This started as "re-root the controls actions onto view models" and the
  premise turned out to be wrong.** The actions are *already* on the view models
  — `gradient.apply`, `filter.apply`, `wavelet.apply`, `epoching.makeBuildJob`
  all exist and `ProcessingCore` already calls them headlessly. What lived on the
  view was the **cross-domain invalidation cascade**, passed to those methods as
  an `onApplied` closure. And it existed twice, disagreeing:

  | Cleared when gradient correction applies | `ProcessingCore` | `WaveformView` |
  |---|---|---|
  | `ica.cleanedSignal` / `decomposition` | yes | yes |
  | `filter.output` / `pnsOutput` / `pnsInputSignalType` | yes | yes |
  | applied artifact cleaning | **no** | yes |
  | `artifactVM.detectionRefreshToken` | **no** | yes |
  | epochs + segment health | **no** | yes |
  | channel interpolations | **no** | yes |

  So a headless or replayed gradient step left stale epochs, interpolations, and
  artifact cleaning behind — a signal silently contradicting the chain that
  produced it. Benign-ish in batch (fresh view models per file, steps in order),
  but a genuine wrong-data hazard for REWIND, where every node navigation
  re-applies stages.

  `PipelineInvalidation` is now the single definition, as free `@MainActor`
  functions over explicitly-passed view models: `epochsAndDerived`,
  `interpolations`, `appliedArtifactCleaning`, and
  `downstreamOfBaseSignalChange` (with `clearsICA: false` for when ICA is itself
  the stage that ran, so it doesn't discard its own output). Both callers now use
  it — `WaveformView.invalidateEpochsForSignalChange` /
  `invalidateInterpolations` / `clearAppliedArtifactCleaning` delegate, and
  `ProcessingCore`'s gradient step calls `downstreamOfBaseSignalChange`.

  Supporting moves: `segmentedEpochSignal`/`segmentedEpochSegments` moved from
  `WaveformView` `@State` onto `EpochingViewModel` (forwarders keep the ~10 call
  sites unchanged), since the cascade must clear them without a live view; and
  `ProcessingCore` gained `template` + `segHealth`, without which it could only
  run *part* of the cascade — which is how the divergence arose in the first place.

  **Cascade audit completed 2026-08-13 — the gradient gap was not the only one.**
  Comparing every `ProcessingCore` stage against its interactive counterpart
  found **three** divergences, not one:

  | Stage | Interactive cleared | `ProcessingCore` cleared |
  |---|---|---|
  | gradient | ICA, filter, cleaning, token, epochs, interpolations | ICA + filter only |
  | **filter** | cleaning, token, epochs, interpolations | **nothing** (`onApplied: {}`) |
  | **wavelet** | token, epochs, interpolations | **nothing** (no closure passed) |

  All three now route through `PipelineInvalidation`. Two new stage-position
  functions encode a real asymmetry rather than papering over it: the chain is
  `raw → gradient → BCG → ICA → filter → artifact-clean → wavelet → interpolate`,
  so `downstreamOfFilterChange` **does** clear applied artifact cleaning (cleaning
  consumes the filter's output) while `downstreamOfWaveletChange` **does not**
  (cleaning is upstream of wavelet and still valid). Both behaviours are pinned by
  tests, because the difference looks like an oversight until you trace the chain.

  Audited and correctly needing no cascade: `thresholdArtifactDetection` (writes
  config only, no signal change) and `segment`/`baseline`/`average` (produces
  epochs rather than replacing the base signal — the `invalidateEpochsForSignalChange`
  call in `PSAEpochingViews` is a per-epoch interpolation fallback, not a
  post-segment cascade).

  Passing view models explicitly, rather than moving all 14 onto `RecordingStore`,
  was deliberate: the view models are `@State` on `WaveformView` because ~240
  sites use `$vm.property` bindings, and a computed forwarder has no `$`
  projection. The explicit signatures also make the compiler name every call site
  when a new stage joins the cascade.

- **Async-ownership primitive — done 2026-08-13.** New
  `EVA/Pipeline/LatestOnlyRunner.swift` + `EVATests/Pipeline/LatestOnlyRunnerTests.swift`.

  Motivated by the shipped eye-blink bug: `updateArtifactEvents` finished its
  work, saw `Task.isCancelled`, and returned having published nothing — empty
  events, spinner stuck `true`, self-resolving once the request id settled. Two
  failure modes hid in one `guard`: a stale run clobbering a fresh one, and
  cleanup being skipped on the cancellation path.

  `LatestOnlyRunner.run(_:work:)` returns
  `.completed(value)` / `.superseded` / `.cancelled`. Identity is an internal
  monotonic generation counter rather than a caller-supplied token, so callers
  cannot get the bookkeeping wrong or reuse a token; the claim is synchronous
  before the first suspension point. Because `Outcome` must be switched over
  exhaustively, the original bug cannot be written without visibly typing a
  `case .cancelled:` that does nothing.

  Adopted in `updateArtifactEvents`, replacing the hand-rolled
  `activeDetectionRequestID` guard; `ArtifactViewModel.resetForClose()` now calls
  `detectionRunner.invalidate()`.

  **The tests were mutation-checked.** Reintroducing the original defect (drop the
  supersession guard, skip cleanup on cancel) fails **5 of 6** tests; restoring it
  passes all 6. That was done explicitly because the whole point of this item was
  that the bug had been untestable where it lived.

  **Async-path sweep completed 2026-08-13.** Audited every long-running path for
  the same defect shape. The result argues against blanket adoption:

  - **Already correct, left alone:** `FilterViewModel` (uses its own
    `activeRequestID` ownership check — effectively `LatestOnlyRunner` by hand),
    `GradientViewModel` (clears `isProcessing` on the cancel path *and* at the
    end), `WaveletReductionViewModel`, artifact cleaning, and the second scans in
    both health files — which already clear the flag *before* the publish guard.
  - **Five real leaks found and fixed**, all the same shape: a spinner set `true`
    at the start and cleared *only on the success path*, so a cancelled or
    unwanted run left the progress row stuck on —
    2× channel health (`ChannelHealthDetailViews`), 1× segment health
    (`SegmentHealthDetailViews`), 1× wavelet explorer, 2× MFF export.
  - **Only MFF export needed the runner.** The health and explorer sites already
    guard supersession correctly (`chanHealth.signature == signature`,
    `generation == waveletExplorer.runGeneration`), so the fix was to hoist the
    clear above the guard — matching the pattern those files already use
    correctly elsewhere. Converting them would have been churn.
    Export was different: **both export paths set `isExportingMFF = true` before
    cancelling the previous task**, so a superseded export resuming later would
    clear the flag the newer one had just set. No ordering fix works there;
    supersession detection is required. Both paths now run through
    `store.exportRunner`.

  **The rule worth remembering:** clear the spinner *before* the publish guard,
  never after — unless the run may be superseded, in which case use
  `LatestOnlyRunner` so the superseded run leaves the flag to its successor.

  **The regression tests were themselves flaky, and it bit.** The first versions
  used `Task.sleep` + `async let`, which does not promise the child starts before
  the next statement — so a "slow" run could finish before the "fast" one claimed
  the runner, inverting the ordering under test. They passed in isolation and
  failed in a later full-suite run. Rewritten around an explicit `RunGate`
  continuation so the interleaving is deterministic; verified with three
  consecutive clean full-suite runs. `ProcessingQueueTests` documents the same
  trap — worth reading before writing async ordering tests here.

- **Progress consolidation — done 2026-08-13** (`REWIND.md` work item 9).
  New `EVA/Pipeline/OperationProgressCenter.swift`, an `@Observable` on
  `RecordingStore` owning all in-flight `OperationProgress` keyed by the
  operation's own `source`, in start order. `GradientViewModel` and
  `FilterViewModel` keep their `operationProgress` property, but it is now a
  computed forwarder into the center — so their internal progress plumbing was
  untouched and any future stage joins by adding the same forwarder.
  `WaveformView.activeOperationProgress` and the `StatusLogSnapshot` builder now
  read the one list instead of reaching into two view models by name, so a new
  long-running stage shows up by *reporting* rather than by editing the status
  view. This is REWIND's Queue-tab prerequisite: "what is running" is now one
  value, independent of which stage owns it.
- **`REPORTS.md`** — per-recording quality/provenance report (typed `EVAReport`
  value → JSON/HTML/Markdown, MRIQC-style).
- **`SOURCE_ANALYSIS.md`** — brainstorm only; source-space BCG removal as the
  cheap first target, general distributed-source imaging as the large one.
- **`paper.md` / `paper.bib`** — JOSS-style paper draft. (`MANUSCRIPT.md`, the
  longer methods-inventory/positioning draft, was deleted 2026-08-11 — going a
  different direction on the write-up.)

---

## Done / status

### Landed since 2026-07-13 (from git history, not previously in this roadmap)
None of it is Priority 1; all of it is feature work, and most of it added new
surface to the same `WaveformView` struct.
- **Wavelets** — reducer rework, wavelet artifact explorer, empirical-Bayes
  thresholding (R-validated), `WaveletMetalBackend`.
- **GPU compute** — gradient removal on Metal (`GradientMetalBackend`,
  `LocalTemplateMetalBackend`); supersedes much of `metal_options.md`.
- **FASTR fixes** + aOBS experiment; MFF writer fixes.
- **ICA** — PICARD-O solver.
- **Single-trial** — RIDE and Woody alignment, time markers.
- **Importers** — Persyst + BESA `.avr`/`.mul` readers, physio text import.
- **Cardiac** — R-wave drawing; detectors now Pan-Tompkins / Hamilton / WFDB /
  Wavelet / Christov (Engzee and Hilbert are still the open ones).
- **Licensing/docs** — clean-room reimplementations, THIRD_PARTY_NOTICES, release
  notes, manuscript/paper drafts.

### Superseded documents
`TODO.md` was fully absorbed here and deleted (2026-08-11) — its Priority 1/2
were the same completed batch work, and its one live item ("isolate the
waveform-area render structs") is this roadmap's B2. Some source-file header
comments still cite it by name; they mean this file.

`WaveformView.swift` was down from ~15,400 lines to ~2,720 at the July write-up
and is **3,014 as of 2026-08-11**, split into
per-domain view files (21 `extension WaveformView` files) + view models. The
L4/L5 *state/line* decomposition is complete; Priority 1 above is the *type/diffing*
decomposition it didn't do.

### Recently landed (2026-07-13)
- **Interpolation resolver.** `InterpolatedSignalResolver` moves recipe-based
  channel interpolation off the main actor, caches it by `(signal.dataRevision,
  interpolationRevision)`, and uses vDSP. Added `MFFSignalData.dataRevision` for
  stable derived-signal cache keys. (Correct, but per the trace it was ~0.5 % of the
  hang cost — hence Priority 1.)
- **A1 progress throttle** (above).
- **PSA per-epoch bad-channel floor.** `PSABuildJob.buildEpochs` no longer lets a
  *positive* `maxBadChannelFraction` round down to 0 on small/low-density nets
  (0.10 × 4 = 0.4 → 0 rejected every epoch → `buildEpochs` returned nil → headless
  segment silently produced nothing). Fraction path now floors to 1 when the
  fraction is > 0; an *explicit* 0 (fraction or absolute count) still means "reject
  any epoch with a bad channel" (preserved, and covered by
  `PSABuildJobEpochRejectionTests`). Regression guarded by
  `ProcessingCoreTests.lowChannelCountSegmentSurvivesPerEpochBadChannelFloor`.
  Root cause of the earlier breakage: the `interpolatesBadChannelsPerEpoch` default
  flipped `false`→`true` on 2026-07-07, silently invalidating the slice-3
  segmentation tests (now pinned `interpolateBadChannelsPerEpoch: "false"` so they
  test segmentation, not rejection).

### Processing / batch suite (2026-07-04, complete)
- **Headless apply-core (`ProcessingCore`)** — view-independent `@MainActor`
  sequencer, tested with zero SwiftUI state. Supports **filter**, **MRI gradient
  correction** (AAS + FASTR/FARM/Moosmann), **threshold artifact detection**,
  **wavelet reduction**, and **PSA** (segment/baseline/average). Stops (doesn't
  skip) at the first unsupported/decision step and reports `remainingSteps` so
  callers can route to windowed replay without reordering the chain.
- **Each domain owns its headless transform** — `FilterViewModel.apply`,
  `GradientViewModel.apply`, `WaveletReductionViewModel.apply`,
  `EpochingViewModel.makeBuildJob`/`applyBuildJob`. `ProcessingCore` is just a
  sequencer wiring cross-domain `onApplied` invalidation. This avoided turning
  `ProcessingCore` into a second god object.
  - *Correctness caveat still relevant:* `GradientViewModel.apply` needs no
    staleness guard (only writes to `self`), but the **interactive** MRI Apply
    button needs its own `recordingSessionID` check around the call — that VM can
    outlive a run (same-window "Close Recording" mid-flight). Guard belongs at the
    call site, not in the VM.
- **PSA intentionally NOT unified with the interactive path** —
  `WaveformView.applyPSACore` also caches `segmentedEpochSignal`/`Segments` for
  post-hoc re-toggling and escalates per-epoch-bad channels to globally-bad via
  `interpolate(_:in:)` (needs live electrode geometry). Unifying means porting both;
  a separate larger follow-up, not a drop-in swap.
  - Headless PSA scope cuts (graceful, not crashes): no defined-artifact-template
    rejection (that's the drawn per-subject decision step the core stops at); no
    per-epoch-bad → globally-bad escalation (`electrodePositions` defaults empty →
    per-epoch interpolation degrades to reject-only). Per-epoch bad-channel
    *detection* + in-epoch interpolation still run.
- **Headless fast batch** — `HeadlessBatchProcessor.process(url:script:outputFolder:)`
  loads off-main, builds throwaway `RecordingStore`+VMs, `applyAutoSteps`, and (only
  on full success) writes via `MFFExportWriter` (shared with interactive export +
  replay finish-and-export). `BatchController.startHeadless` drives the loop; files
  needing a decision are `.needsInput` for windowed rerun (no mid-script resume — see
  Priority 2). `BatchSetupSheet` picks windowed-vs-headless upfront from the
  configured steps. Tested end-to-end (`HeadlessBatchProcessorTests`,
  `BatchControllerTests`).
- **Compatibility pre-flight** (`ReplayCompatibility.check(_:against:)`) — flags
  missing/too-few TR markers (gradient), out-of-range `channelOverride` (threshold),
  or absent PSA `eventCodes`, per step per file. Wired into
  `ReplayController.configure` (interactive Copy Processing + windowed batch) and
  `ProcessingCore.applyAutoSteps` (stops into `remainingSteps` instead of a silent
  no-op — e.g. gradient with no matching TR markers).
- **Replayable steps rounded out** — wavelet reduction now round-trips its full
  `WaveletReductionConfiguration` and replays (was `.skip`); PSA DIN timing markers
  (`din.<code>` + `timingTolerance`) now serialize and feed the existing
  `makeBuildJob` matching logic.

### Refactor cleanup (2026-07-04, complete)
- **L4.5 acceleration boundary** — `ACCELERATE_NEW_LAPACK` on, clean build 0 warnings.
- **Deferred tests backfilled** — `ICAComponentAutoLabelerTests` (7),
  `ICLabelClassifierTests` (2). `ICAArtifactDetector` is a stateless `nonisolated
  enum`, so `fit()` thread-safety is structural.
- **Settings consolidation** — `ProcessingDefaults`/`PreferencesView` centralize
  global defaults; the two remaining VM-less domains, **ECG detection**
  (`ECGDetectionViewModel`) and **Wavelet Artifact Explorer**
  (`WaveletArtifactExplorerViewModel`), were extracted state-ownership-style.
- **BCG iterative exemplar refinement** — already implemented
  (`BCGDetector.refineSpatialPCA`, "Refine" button + panel); nothing left there.

## Display scale in physical units (2026-08-13)

EVA's two display scales were unnamed numbers. They now read out in the units the
rest of the EEG world uses, and exported figures state theirs exactly.

**What they always were.** `amplitudeScale` is the µV filling half a channel row
(`pointsPerMicrovolt = rowHeight × fraction / amplitudeScale`); `timeScale` is
points per decimated display sample. At the defaults that is **~8.1 µV/mm and
~71 mm/s**, against clinical conventions of 7 µV/mm and 30 mm/s — close enough
that exposing the units was labelling, not rescaling.

The row fraction is **0.5 in the main waveform and 0.42 in the panel plots**.
Both are now `WaveformScaleUnits` constants rather than literals, so the readout
cannot drift from what is drawn. Do not unify them: the main waveform stacks rows
that must not collide, a panel plot owns its box.

**Phase 1 — on-screen readout.** `WaveformScaleUnits` converts both directions.
The toolbar shows µV/mm and mm/s under the existing numbers; clicking opens a
popover for typed entry plus a Clinical preset (7 µV/mm, 30 mm/s), both reachable
inside the sliders' ranges. Units are **nominal** — 72 pt/inch — and the popover
says so, because the true size of a point needs display dimensions macOS reports
from EDID, which is wrong or absent on plenty of monitors. `pointsPerMillimeter`
is a parameter throughout so a future per-display calibration is a single value.

**Phase 2 — exported figures.** These need no calibration: a PDF point is 1/72
inch by definition. `FigureScale` computes each figure's own sensitivity and
sweep from its own geometry, and `FigureCard` prints it. Raster exports now
declare 144 dpi — `NSBitmapImageRep(cgImage:)` took its size from the pixel
dimensions, so 2× renders claimed to be twice as large as drawn and every viewer
placed them at 72 dpi, which would have silently halved any stated sensitivity.

**A defect found on the way, and fixed.** The decimation aims for 200 display
samples/sec at any sampling rate, but the stride is an integer, so
`round(samplingRate / 200)` only hits it for multiples of 200: **+25% at 250 and
500 Hz, −15% at 512 Hz, +2.4% at 1024 Hz**, exact only at 1000 and 2000. That was
harmless while the control read "1.0×" — a unitless multiplier promises nothing —
and stops being harmless the moment a readout claims millimetres per second. All
sweep conversions take the sampling rate and use the real stride, and
`WaveformView.displaySampleStride` now delegates to the same function so the two
cannot diverge. Worth knowing separately: **the on-screen sweep speed genuinely
differs between files at different rates**, which is arguably worth fixing in the
decimation rather than only reporting.

**Defaults in Settings.** General preferences gained a "Default Display Scale"
section: sensitivity and sweep sliders plus Clinical (7 µV/mm, 30 mm/s) and EVA
Default presets, seeded into a recording by `seedDisplayScaleDefaults()` when it
opens.

Stored in **physical units, not raw scales**, and that is the useful choice
rather than the tidy one: a stored `timeScale` would start a 250 Hz file and a
1000 Hz file at visibly different sweep speeds, for the integer-stride reason
above. Storing mm/s and converting per file means 30 mm/s is 30 mm/s whatever you
opened — `sweepPreferenceIsPortableAcrossRates` pins it. The shipped defaults
(8.1 µV/mm, 70.6 mm/s) reproduce the old `amplitudeScale` 100 / `timeScale` 1
exactly, so nothing moves for anyone who never opens the panel.

Seeding runs **once per load, never on a settings change** — the preference is a
starting point, and pulling the view out from under someone who has since moved
the sliders would be worse than not having it.

**Not done (Phases 3 and 4, both optional).** Per-display calibration with an
honest uncalibrated state; and decoupling row height from amplitude so a true
sensitivity holds regardless of channel count — a literal 7 µV/mm across 129
channels needs a canvas taller than any screen, which is why clinical montages
show ~20. The PNS pane keeps its own separate scale and is out of scope.

## Planned: channels on screen (Phase A — how many)

Requested 2026-08-13: a setting for **how many channels fill the screen**, and
later **which** ones. Planning the first; the second is sketched at the end
because one function decides both.

### What the code looks like today

Three facts shape everything below, all verified rather than assumed:

1. **`channelIndices(in:)` is the single choke point.** It lives in
   `ChannelsPanelViews.swift:22` and is `Array(signal.data.indices)` — every
   channel, always. The label column, the trace column, and the hover hit-test
   all iterate it. Both features are changes to this one function plus whatever
   feeds it.
2. **Row pitch is uniform and barely load-bearing.** `channelRowHeight` (70) +
   `rowSpacing` (12) = 82 pt. The only code that depends on that arithmetic is
   `waveformHoverChannelIndex`, which does `Int(y / rowPitch)`. Every overlay —
   selection, cursor, artifact highlight, segment health, epoch boundaries — is
   **x-only and full-height**, so none of them care what the rows are. That is a
   much smaller blast radius than it looks from outside.
3. **"Hidden" is not "absent".** `channels.hidden` keeps a channel's row and
   draws no trace. So EVA already has two notions that Phase B will have to
   reconcile: a channel you have muted, and a channel that is not on screen.

### The crux: row height is the denominator of sensitivity

"Show N channels" means row height becomes derived — `(availableHeight − spacing)
/ N`. But since the physical-units work, row height is exactly what converts
`amplitudeScale` into µV/mm:

    pointsPerMicrovolt = rowHeight × channelRowFraction / amplitudeScale

So **changing the channel count silently changes the sensitivity** unless
something is held fixed. Three possible policies:

- **(a) Fix row height, let N follow the window.** Sensitivity constant, but this
  is really a window-size setting and does nothing for someone on a laptop — it
  does not answer the request.
- **(b) Derive row height from N, let sensitivity float.** Simple, and matches
  the naive expectation that more channels means smaller traces. But the µV/mm
  readout then moves every time you change the montage size, which makes the
  number nearly useless for the thing it was added for.
- **(c) Derive row height from N, hold sensitivity fixed** by rescaling
  `amplitudeScale` to compensate. This is what clinical systems do — sensitivity
  is a property of the review, not of how many channels you happen to be looking
  at — and the cost is that traces overlap their neighbours more at high counts.
  Clinical review accepts exactly that.

**(c) is right, and it is the same work as scales Phase 4.** Both amount to:
sensitivity (µV/mm) and row pitch (mm per channel) are two independent user
settings, and overlap is simply what happens when the signal needs more room than
the pitch allows. `channelOverflowHeight` (28 pt) already exists for a mild
version of this. These two items should be built together or not at all —
building channels-per-screen on top of (b) would make the µV/mm readout worse
than not having it.

### What N can actually be

There is a floor. Below roughly 18–24 pt a trace is unreadable and
`ChannelLabelRow` — which carries name, health badge, bad/interpolated state —
has nowhere to put itself. On a ~700 pt viewport that caps N at about 30.

So **129 channels on one screen is not reachable by shrinking rows**, and the
setting should say so rather than offering a number it cannot honour. The
birds-eye view people actually want at that density is a different renderer — no
labels, one row of pixels per channel, amplitude as colour — i.e. a carpet/raster
plot. Worth naming as its own future item rather than pretending the row list
scales down to it.

### Sketch

- `EVAGeneralPreferences` key, `@AppStorage`, default = current behaviour.
- The setting is **channels per screen**, preserved across window resize (row
  height recomputes); the alternative — fixed rows, floating N — is what already
  happens and is not what was asked for.
- Available height is the viewport minus `eventTrackHeight` (64) and any physio
  pane, not the window height.
- Natural affordance once it exists: ⌘+ / ⌘− and pinch as vertical zoom, since
  this is effectively that.
- Scope to the continuous waveform. The butterfly, averages, and single-trial
  workspaces lay themselves out and are out of scope.

### Two things it must not touch

- **Not provenance.** This is display state; it must stay out of `eva.xml`, and
  specifically out of `ProcessingChainSignature`, or every zoom would record a
  history node. `WaveformUIModels.swift` is the file whose header already draws
  that line.
- **Not the per-frame path.** ROADMAP Priority 1 measured the trace column into a
  plain eager `VStack` (a `LazyVStack` there cost ~30% of the wheel-scroll
  window). Raising N from ~8 visible rows to ~30 is a real 4× increase in Canvas
  draws per frame, and the horizontal cost per row does not shrink when the row
  does — the decimation stride is derived from sampling rate, not row height.
  Measure before and after; `usesPixelAdaptiveWaveformRendering` is the existing
  lever.

## Planned: channels on screen (Phase B — which ones)

Not planned in detail yet, but the shape is set by fact 1 above: it is a filter
and an ordering in front of `channelIndices(in:)`. The questions to settle when
we get there:

- Does selecting a subset **replace** `channels.hidden` or sit beside it? Two
  ways to make a channel not appear is one too many.
- Saved, named montages (frontal, midline, a 10-20 subset), and whether they are
  per-file or global.
- Ordering, not just membership — montages are conventionally ordered, and
  `channelIndices` currently returns natural order.
- Non-uniform pitch (group spacers) would break the one piece of pitch arithmetic
  in `waveformHoverChannelIndex`. Keeping pitch uniform is a cheap invariant to
  hold on to; give it up deliberately if at all.
