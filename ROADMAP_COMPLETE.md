# EVA — ROADMAP_COMPLETE

Everything that has shipped, closed, or been explicitly abandoned. Organized by
the **same twelve subsystem sections** as `ROADMAP.md`, so a subsystem's history
and its remaining work sit at the same heading in both files.

`ROADMAP.md` is the single "what is left" plan and decides priority.
`docs/design/` holds method and format references. If any of the three disagree
about whether something is done, this file and `ROADMAP.md` are right.

A record is here only when the work is implemented, tested, and documented —
not merely started.

## Sections

1. [Ingest & Formats](#1-ingest--formats)
2. [Processing & Cleaning](#2-processing--cleaning)
3. [EEG Artifact Correction (MAAC)](#3-eeg-artifact-correction-maac)
4. [MRI / fMRI Artifact Correction](#4-mri--fmri-artifact-correction)
5. [Epoching, Averaging & Trial-wise](#5-epoching-averaging--trial-wise)
6. [Time-Frequency & Rhythmicity](#6-time-frequency--rhythmicity)
7. [Source & Forward Modeling](#7-source--forward-modeling)
8. [Simulation](#8-simulation)
9. [RSA](#9-rsa)
10. [UI, Figures & Export](#10-ui-figures--export)
11. [Batch, Replay & Provenance](#11-batch-replay--provenance)
12. [Performance & Metal](#12-performance--metal)
13. [Developer Documentation](#13-developer-documentation)

## Absorbed planning documents

`TODO.md`, `REFACTOR_July.md`, `REFACTOR.md`, `TODO_BATCH.md`, `GEDAI_PLAN.md`,
`TRIALWISE.md`, `REWIND.md` and `REPORTS.md` were absorbed and deleted in
earlier passes.

**2026-09-11:** `LAVI.md`, `SLEEP.md`, `EVA_RESOLVE.md`, `EVA_RESOLVE2.md`,
`RSA_PLAN.md`, `SOURCE_ANALYSIS.md` and `metal_options.md` were absorbed into
this file, `ROADMAP.md`, and `docs/design/`. `SLEEP.md` was a byte-identical
duplicate of the roadmap's sleep section and carried no unique content.

---

# 1. Ingest & Formats

## FIF reading and Quick Look — completed 2026-09-06


Native FIF **reading** is done: `EVACore/IO/FIF/FIFMeasurementInfo.swift` and
`FIFRecording.swift` read continuous (`*_raw.fif`, float32 / int16 / DAU-pack16
buffers, `.fif.gz`), epoched (`*-epo.fif`) and averaged (`*-ave.fif`) files
natively, validated sample-for-sample against MNE-Python
(`Tools/fif-import/make_fif_fixtures.py`, `EVATests/IO/FIFRecordingTests.swift`,
`FIFImportTests.swift`). `.fif` and `.fif.gz` open by drag-and-drop and File ▸
Open like any other recording.

**Quick Look shipped with the reader** (`EVAPreviewKit/FIF/`): `.fif` and `.fif.gz`
preview and thumbnail in Finder. Because a `.fif` is a container for a dozen
different documents, `FIFDocument` classifies by *block structure* rather than by
filename convention, and each kind gets its own picture — recordings get the MFF
treatment (montage, event timeline, waveform, per-condition butterfly), head models
get their shells sliced and drawn as nested sagittal/axial contours, transforms get
their matrix plus a translation/rotation decomposition, digitizations get the point
cloud from two angles, and anything else (forward solutions, source spaces,
covariances, ICA) gets a structural outline with its headline scalars. The same
classifier gives the importer its error message: a head model dropped on EVA now says
what it is and to open it in Resolve.

## C5. Channel-set geometry catalog — completed 2026-08-15

- Added persisted `KnownNetGeometry` entries sourced only from real recordings.
- Added net selection/editing, rename with merge-on-collision, deletion, and
  net filtering.
- Made Channel Set storage injectable so tests never mutate a user's real
  Application Support data.
- Deliberately did not fabricate bundled HydroCel geometry or automate cross-net
  equivalence judgments.


## Sub-millisecond MFF event times — completed 2026-08-21

Both `EVA/IO/MFFWriter.swift` and `EVA/IO/MFFReader.swift` were quantizing event
times to milliseconds; 1024 Hz is now exact in both directions. The full record
is EVASimulate item 4.9 in [§8 Simulation](#8-simulation),
because that is where the blocker was found and fixed.

---

# 2. Processing & Cleaning

### SI-0 — Characterize contracts — ✅ **COMPLETED 2026-08-26**

- [x] Add deterministic fixtures for leadfield and PCA-S matrix dimensions,
  finiteness, reference, artifact-free near-identity behavior, known artifact
  attenuation, brain-topography preservation, and invalid-input failures.
- [x] Record current EVASimulate self-test metrics and determinism hashes.
- [x] Separate exact invariants from scientific metrics allowed a documented
  tolerance when the eigensolver changes.
- [x] Define ordered-electrode and `ForwardDipole` APIs, including units,
  coordinate frame, reference, and errors.

Implementation record:

- `SI0ContractFixtures.swift` adds nine compact extraction-boundary checks to the
  existing scientific self-test, bringing it to 99 passing outcomes.
- `SI0_CONTRACTS.md` records exact versus tolerance-bearing contracts, the
  ordered physical-electrode/`ForwardDipole` API, units/frame/reference/errors,
  current metrics, and the eight existing determinism fingerprints.
- PCA-S construction now rejects empty, ragged, non-finite, channel-mismatched,
  and negative-regularization inputs instead of padding/truncating them.
- EVASimulate's direct-source build now includes EVA's `SensorLayout.swift`, a
  dependency added to `MFFReader` after the simulator build list was last synced.
- Verification: optimized build succeeds; all 99 self-tests pass; all eight
  generated scenarios match the committed determinism baseline without updating
  it. No new hashing system was introduced.

**Exit:** extraction cannot silently change the science, and later score changes
can be attributed.


### SI ownership decision — where the shared numerical code lives


EVASimulate already provides:

- `SphericalForwardModel`, including oriented/free-orientation leadfields and
  spherical-harmonic convergence checks;
- `SurrogateSeparation`, including a 29-region basis, BCG template PCA,
  artifact partialling, operator construction, and application;
- separately named paper and iterative pattern searches;
- repeated-seed, component-count, and basis-displacement sweeps;
- source-distance, ERP, geometry, reference, and PNS contracts;
- a generate → headless EVA → score regression loop.

The code is in the wrong ownership layer. Production numerical code belongs to
EVA. EVASimulate must become a generator and adversarial evaluator of that same
code—not a runtime dependency and not a second implementation.

The shared boundary is:

1. `EVA/Core/Forward/`: app-neutral head shells, head model, EEG reference,
   dipoles, leadfields, and `SphericalForwardModel` using ordered
   `SIMD3<Double>` positions.
2. `EVA/Artifacts/SourceInformed/`: a UI-free engine accepting a brain basis,
   artifact topographies, and regularization, returning a validated spatial
   operator plus diagnostics.
3. Domain adapters stay with their evidence: BCG template PCA in `EVA/Cardiac`,
   ocular calibration in the ocular domain, ICA topographies in `EVA/ICA`, and
   channel-noise estimation in `EVA/Health`.

The first app integration uses the existing base-signal position:

```text
raw → gradient → BCG correction → ICA → filter → artifact-clean → wavelet → interpolation
```

`BCGDetectionViewModel.correctedSignal` already owned this slot for CWL, and
PCA-S joined it there as a correction option fed by existing detected/refined
beats — not a new top-level wavelet or ICA stage. **Shipped in SI-3
(2026-08-27):** `SurrogateBrainModel` in `EVA/Artifacts/SourceInformed/`,
`BCGSurrogateTopographies` and `BCGSurrogateCorrection` in `EVA/Cardiac/`. The
later methods below reuse the first two and supply their own domain adapter.


## SI-2 — Extract the surrogate spatial-filter engine — ✅ **COMPLETED 2026-08-26**

- [x] Separate regional-basis generation, artifact-topography input, operator
  construction/application, and diagnostics from BCG template discovery.
- [x] Replace the simulator-only Jacobi dependency with EVA's LAPACK-backed
  routines and explicit errors; solve regularized positive-definite systems
  instead of constructing an inverse where practical.
- [x] Preserve paper versus iterative template discovery as named BCG policies.
- [x] Pin operator determinism, artifact attenuation, artifact-free residual
  SNR, brain-map gain/correlation, and degeneracy failures.

**Exit:** EVASimulate calls the app-owned engine and retains or improves the
committed repeated-seed results.

Implementation record:

- `EVA/Artifacts/SourceInformed/SourceInformedOperator.swift` owns validated
  basis normalization, artifact-subspace projection, operator construction and
  application, typed failures, and auditable numerical diagnostics.
- `LinearAlgebra.CholeskyFactorization` uses LAPACK `dpotrf_`/`dpotrs_` to solve
  the regularized positive-definite system for all sensor right-hand sides; the
  former eigendecomposition-built inverse is gone from EVASimulate.
- EVASimulate retains regional-source placement and named paper/iterative BCG
  template discovery, but correction and repeated evaluation call the shared
  operator directly and correction reports include its diagnostics.
- Verification: 99/99 simulator outcomes; all SI-0 measurements unchanged at
  printed precision; 19/19 focused engine/linear-algebra tests; all eight
  existing generated scenarios unchanged; 1,271/1,271 EVA tests across 131
  suites. No baseline or hashing infrastructure changed.
- The complete phase record is `Tools/EVASimulate/SI2_EXTRACTION.md`; SI-0
  remains the scientific acceptance contract.


### C13. SI-3 — Broadband BCG PCA-S — completed 2026-08-27

Surrogate-source separation ships as a BCG correction method, through one
engine shared by the sheet, `ProcessingCore`, batch, windowed replay, and the
regression corpus.

- [x] **PCA-S as a correction choice fed by existing beats.**
  `BCGDetectionMethod.surrogatePCAS` sits beside CWL as a direct correction and
  consumes whatever already found the beats — BCG detection, or ECG/QRS when the
  BCG detector has not run. It detects nothing itself.
- [x] **The engine, split along the ownership line SI-1/SI-2 drew.**
  `SurrogateBrainModel` (app-neutral, `EVA/Artifacts/SourceInformed/`) places 29
  volumetric regional sources and builds the free-orientation basis from
  `SphericalForwardModel`; `BCGSurrogateTopographies` (`EVA/Cardiac/`) is the
  domain adapter that turns beats into a topography dictionary; operator
  construction stays in `SourceInformedSeparation`. The regional-source
  constants match EVASimulate's so a number measured there describes the code
  that ships.
- [x] **Geometry, reference, and channel contracts enforced rather than
  assumed.** Missing or partial coordinates are a refusal with the channels
  named — there is no standard-montage fallback, because a filter built on
  someone else's head removes something other than this subject's artifact. The
  operator is built and applied over the good EEG subset only, and bad rows come
  back untouched. The correction is expressed as a *removal* computed in average
  reference, which reduces to `Op·X` when the recording is already
  average-referenced and otherwise leaves its reference untouched.
- [x] **`bcgCorrection`, with portable settings and fitted results kept apart.**
  The step carries only settings and the beat event code; the fitted
  topographies, beat counts, reliabilities, and diagnostics go to the report and
  the audit log. `replayInteraction(given:)` classifies it `.auto` only when the
  target file has both coordinates and beats of the recorded code, and
  `.decision` otherwise; `ReplayCompatibility` flags a file with no such beats
  before a batch starts. Variance is accounted as `surrogateSeparation`,
  invalidation runs through the shared base-signal cascade, and the snapshot
  carries the applied method and report so a navigated node still says what
  produced it.
- [x] **Regression case with a floor, an anti-leakage ceiling, and a
  watermark.** `surrogatePCASCorrectionHoldsItsQuality` runs on the 32-channel
  generated case (a 20-channel evaluation understates the method). The ceiling
  is the **oracle spatial filter** — the best channels × channels matrix that
  exists, fitted with the clean recording in hand — because PCA-S is one linear
  spatial filter and cannot beat the best one. An earlier ceiling derived from
  what the operator does to the clean signal was dropped: it is exact only when
  the artifact lies entirely inside the removed subspace, and it came out
  *below* the achieved score.
- [x] **The UI states its assumptions.** The panel names the coordinate source,
  the head model and its radii, the beat count and code, and the corrected and
  excluded channel counts before anything runs — and repeats the fitted result
  after.

**One finding worth carrying into SI-4.** Taking every template component above
the paper's 0.5% variance threshold removes brain signal when the artifact is
weak: on a brain-dominated fixture it turned a 2.8:1 recording into a 1.3:1 one,
because the low-variance components of a beat average are ongoing EEG rather
than artifact. What separates them is repetition, not size, so each component's
time course is now correlated between the odd-beat and even-beat halves of the
template and one below 0.9 is rejected. The same fixture then improved to 6.0:1
and removed 12.7% of the variance for a 13% artifact. On the generated corpus
case the gate rejects nothing and four components are retained at reliabilities
0.95–1.00, matching the paper's reported 4–8 per subject. **The threshold itself
is not yet evidence-based** — it is a defensible default chosen to err toward
keeping brain — and calibrating it against beat count, channel count, and
artifact strength is SI-4 work.

**Exit met:** interactive and headless runs are byte-identical on the same
recording and settings (`PairedValidationTests`), and the truth-backed unit
suite clears artifact-removal and brain-preservation gates in both the
artifact-dominated and brain-dominated regimes
(`BCGSurrogateCorrectionTests`).

---

---


---

# 3. EEG Artifact Correction (MAAC)

The MAAC (Multi-Algorithm Artifact Correction, Dien 2024) is being adopted
artifact-by-artifact. Delivered so far:

- **MAAC-1 saccadic spike potential — COMPLETE.** Dedicated spatial-filter
  correction per Dien §1.8: Cz-reference first-difference detection, VEOG-
  dominant preliminary scan, biphasic 4/8 ms confirmation, 100 ms refractory,
  Semlitsch (1986) canonical scalp-map template with a session-average
  alternative, and least-squares spatial-filter subtraction. `.saccadicSpike`
  artifact type, replay-aware (`ArtifactReplayPayload`), own Waveform sheet +
  view model + help, `SaccadicSpikeCorrectionTests` (biphasic detection,
  reference-independence, refractory gate, spatial-filter removal, template
  normalization, replay round-trip). Files: `EVA/Artifacts/SaccadicSpike*`.
- **MAAC-5 mains removal — SHIPPED** as EVA's adaptive **CleanLine**
  (`EEGSignalFilter.adaptiveLineNoiseReduction`, `lineNoiseMode ==
  .adaptiveCleanLine`): sliding-window cos/sin regression at the line frequency
  + harmonics with Hann-taper overlap-add — the PREP/CleanLine mechanism — with
  a notch alternative. Recorded under § 2 (Filtering) as the delivering
  subsystem; noted here for the MAAC mapping.
- **Blink** correction (one of the four matched algorithms) is delivered via
  EVA's ICA + ICLabel "Eye" path (see § 2 above).

Open MAAC work — corneo-retinal dipole regression (MAAC-2), temporal-PCA/Promax
movement (MAAC-3), BSS-CCA EMG (MAAC-4), alpha (MAAC-6), and the ordered
orchestration (MAAC-7) — is tracked in `ROADMAP.md` § 3.

---

# 4. MRI / fMRI Artifact Correction

Gradient correction (AAS/MAR/MAS/wAAR/wAAS/FARM/FASTR/Allen IAR), the clean-room
FASTR replacement, Metal gradient compute, and true iterative sub-sample
alignment all shipped — see C9 in [§10 UI, Figures & Export](#10-ui-figures--export) and
[§12 Performance & Metal](#12-performance--metal). The head-to-head measurement
of these engines is the method-comparison harness recorded under
EVASimulate item 3.2 in [§8 Simulation](#8-simulation).

Nothing else in this subsystem is closed; MRI-1 remains open in `ROADMAP.md`.

---

# 5. Epoching, Averaging & Trial-wise

### C8. Trial-wise diagnostics foundation — Phases 1–3 and Phase 4 core complete

- Added `TrialSimilarityAnalyzer` with leave-one-out correlation, slope,
  normalized residual RMS, MAD-standardized robust distance, cross-category
  matching, and interpretable classifications.
- Added drift statistics and Trial Diagnostics plots: `r`–`β`, measure over
  trial order/time, contiguous split groups, convergence, and residual heatmap.
- Added hierarchical pooled-category matching and correlation/margin gates that
  prevent noise or near-identical categories from producing false mislabels.
- Added rule-based selection previews with named reasons, full multichannel SNR
  and SME before/after, survivor averages, and a seeded 200-draw random-exclusion
  null. Previewing does not modify or persist the data.
- Added tested multi-peak metrics: named-window scores, time-resolved
  correlation, bounded-lag affine fit, and ridge component regression.
- Generalized draggable windows across RIDE, Measurements, CWT, Woody, and Trial
  Diagnostics; added per-window peak/correlation panels.
- Replaced the long stacked view with `TrialDiagnosticsDashboard`, including a
  persistent context rail, tabbed plots, sortable trial table, shared selection,
  responsive narrow layout, and condition-aware Setup disclosure.

Key retained decisions: use MAD rather than SD, apply metric floors, skip
categories with fewer than two trials, use RMS rather than correlation alone for
convergence, use running medians for trends, and show the limitations of
uncorrected p-values and selection-on-the-outcome directly in the UI.


## C13-adjacent: TW-5 reviewed trial exclusions — engine completed 2026-08-27

The `trialExclusion` operation, its `eva.xml` element, per-category merge,
review state, commit control, re-average safety, and restore-on-navigate are all
built and tested. Two verification items remain open and are carried in
`ROADMAP.md` § Epoching, Averaging & Trial-wise.

#### Why this is not just another parameter step

Every other step in the script has the property that its settings *are* its
result: re-running `filter highPassHz=0.1 lowPassHz=30` reproduces the samples.
A similarity threshold does not. Re-running `r < 0.3` after any upstream change
proposes a *different* set of trials, and no threshold value can express an
operator putting one flagged trial back. So the committed step records **both**:
the thresholds, because they say why and are the only portable half, and the
resolved trial set, because it is the decision. Replay applies the recorded set
verbatim and never silently re-derives it.


### Canonical decisions (2026-08-26)

1. **A new operation, `trialExclusion`, positioned before `average`.** Not an
   extension of the `average` step's `rejections`: `EVAHistory` deliberately
   excludes `rejections` from node identity as "a result of the step", so
   attaching the decision there would produce no distinct node — committing
   could not be navigated to, forked from, or undone with `stepBack()`. As its
   own operation it hashes into the lineage like everything else, and
   re-committing an identical set at the same parent deduplicates for free.
2. **Trials are identified by source event key, not by index.** `category +
   sourceCode + sourceTimeSeconds`, all already carried on `EpochSegment`. The
   trial index the analyzer and UI speak is positional and silently re-points at
   a different trial after any upstream change that drops or reorders an epoch.
   The index is recorded alongside the key as a human-readable cross-check, so a
   mismatch can be *reported* rather than applied. This is the same join key
   TW-6 needs for covariates.
3. **Exclusion removes a trial from the average, not from the data.** Excluded
   trials stay in the segmented signal and stay visible — flagged, not gone — in
   Single Trial Analysis, using the existing `excludedSegmentIndices` path in
   `EpochingViewModel.buildAndPostProcess`. This keeps "previewing alone never
   removes a trial" true of committing as well, and keeps the decision
   reversible without a re-segment.
4. **No new sidecar.** The thresholds and the trial list both live in `eva.xml`
   under the step, consistent with RW-1 item 3's interpolation ruling: a record
   that is a pure function of things the package already carries does not earn a
   file of its own.

### Work

- [x] Add `EVAProcessingStep.Operation.trialExclusion` and its `eva.xml`
  element: `<param>`s for the criteria (`minCorrelation`, `minSlope`,
  `maxResidualRMS`, `maxRobustDistance`, excluded classifications,
  `excludesMislabels`) plus a `<trial>` child list carrying the source event
  key, the recorded index, the per-trial reason strings
  `TrialSelectionAnalyzer.Exclusion` already produces, and an `origin` of
  `rule` or `operator`.
- [x] Record the scoring context the scores are meaningless without: category,
  `SingleTrialChannelScope` (the single channel, or the ROI membership),
  the scoring window, and the leave-one-out premise. A reader must be able to
  tell what the `r` and `β` in the reasons were computed on.
- [x] Distinguish the reviewed decision from the proposal in both directions.
  An `origin=operator` trial is one the rule did not flag; a rule-flagged trial
  the operator restored is recorded as a restoration rather than vanishing, so
  the file shows the rule was overridden and not merely re-tuned.
- [x] Resolve keys to segment indices in one place, shared by the interactive
  and headless paths, and feed the existing `excludedSegmentIndices` closure.
  This is the first thing to close the session-only gap documented at
  `EpochingViewModel.applyBuildJob` — a batch run currently has no equivalent of
  a manual exclusion because there was nothing on disk to give it.
- [x] Never apply a partially-resolved set silently. Every recorded key resolves
  → apply. Some or none resolve → surface the count that did not and require a
  decision; a re-segment that changes the epoch window is the expected cause.
- [x] Feed the aggregate counts downstream: a `"Low similarity"` reason in
  `PSAExclusionSummary.CategoryTally.reasons`, so the existing
  `categoryRejections` bridge carries it into the `average` step's
  `CategoryRejection` and from there into QuickLook retention bars,
  `RecordingCombiner`, and the export audit log with no new plumbing.
- [x] Classify replay by whether *this* file can resolve the keys, extending the
  `replayInteraction(given:)` split RW-1 item 6 established. Same file, all keys
  resolve → `.resolvedFromPayload`, applied with no prompt. A script copied to
  another subject resolves nothing → `.decision`: the thresholds are re-proposed
  in the Phase 3 UI for review, and one subject's trial list never crosses into
  another's. The step stays `replayable: true` — the portable half is real.
- [x] A history row that reads as the decision it is —
  `HistoryStepSummary` renders `exclude trials · 2 trials · r<0.3, β<0.4 ·
  1 restored`, with the count read from the step's payload rather than its
  parameters.
### Remaining: the commit control (planned 2026-08-26)

**Nothing in the UI yet produces a `trialExclusion` step.** Everything under it
— resolution, averaging, attribution, `eva.xml`, history, replay — is built and
tested against steps constructed directly. Two decisions settled before starting:
**commit re-averages immediately**, and **the first version supports both
restoring a flagged trial and excluding one by hand.**

Two properties of the existing machinery shape the sequence below:

- Committing needs no new history plumbing. `recordProcessingHistory()` already
  builds from `currentProcessingScript()` and `currentPayloadDigests()`, both of
  which now carry the step and its digest, and a re-average moves
  `ProcessingChainSignature.epoched`. Re-averaging on commit is therefore also
  what makes the node appear — the two decisions reinforce each other.
- `ReplaySettingsRestore.Settings` carries no exclusion term, so navigating to a
  node *before* a commit would leave the exclusion applied. That is the exact
  case that file's header is about: the absence has to be derived, not left
  alone.

- [x] **Per-category merge — done 2026-08-26.**
  `TrialExclusionResolver.merged(reviewed:for:criteria:context:into:segments:)`
  replaces one category and leaves the others standing, keeping the step's `id`
  so a merge edits the decision rather than starting a new one (a fresh id would
  invalidate `resolvedTrialExclusionStepIDs` and turn a resolvable exclusion back
  into a prompt). Criteria *and* scoring context are keyed per category —
  `LC++.minCorrelation`, `LC++.channels` — parsed on the last dot so a category
  named `stim.1` still resolves, with unkeyed keys still reading as a rule that
  applied to everything. A bound switched off during re-review is removed rather
  than left stale. `removing(category:from:)` returns nil when the last category
  goes, since an empty step would persist as a decision that excludes nothing.
  `HistoryStepSummary` reads the keyed form and says `2 rules` when categories
  disagree instead of attributing one category's thresholds to another's
  decision.
- [x] **Review state — done 2026-08-26.** `TrialSelectionAnalyzer.Review`
  (`restored`/`manual` trial indices) held per category in
  `selectionReviews`, with `selectionReview` addressing the category under
  review. `TrialSelectionAnalyzer.reviewed(proposals:review:)` applies it, and
  `TrialSelectionAnalyzer.Exclusion` gained an `origin` reusing
  `ExcludedTrial.Origin` rather than a parallel enum needing a mapping.
  `refreshTrialSelection()` folds the overrides on the one path that also feeds
  the overlay and the null, so the preview and a commit cannot describe
  different decisions.

  Overrides are **never pruned** when a re-tune makes them moot — a slider drag
  must not destroy a decision — so precedence decides what one *means* against
  the current proposal: a restoration beats everything, a rule-flagged trial
  absorbs a hand exclusion the criteria have caught up with (recording it as
  manual would credit the operator with the rule's own decision), and a
  restoration of a trial nothing flags drops out silently. Dragging the
  threshold back restores the operator's decision intact.
- [x] **The control — done 2026-08-26.** A checkbox per row in
  `TrialExclusionList`, an "Exclude #N by hand" action offered only for a
  scatter-selected trial *not already listed* (two controls for one decision is
  how they end up disagreeing), and `TrialExclusionCommitBar` — commit behind a
  confirmation naming its counts, reset, and clear. Committing is never a side
  effect of dragging a threshold. The plan said the control would be shared by
  the dashboard rail and the Phase 3 section; there is only one host, because
  the Phase 3 section *is* the dashboard.
- [x] **The action — done 2026-08-26.** `commitTrialExclusion()` merges the
  category under review into whatever is committed, refusing outright when any
  reviewed trial cannot be matched to a segment rather than writing a record
  that silently fails to resolve. The sheet reaches the pipeline through an
  `onCommitTrialExclusion` closure rather than `EpochingViewModel` directly, so
  it stays presentable from a context with no pipeline — where the panel
  correctly previews and commits nothing. Committing re-averages through
  `refreshEpochDisplay()`, which is also what mints the history node.
  The overrides deliberately survive a commit: clearing them would snap the
  list back to the rule's raw proposal, showing something other than what was
  just committed.
- [x] **Per-category clearing — done 2026-08-27.** Clearing splits into "only
  this category" and "all N categories" *only* when more than one category is
  committed and the one under review is in the record; with one committed
  category the two are the same act and offering both is two names for one
  button. `removing(category:from:)` now returns nil when what remains excludes
  nothing — tested for a remaining *exclusion*, not for remaining trials, so
  clearing down to restorations-only cannot leave a record committing could
  never have produced. The session review survives a clear: it is unsaved work,
  and discarding it as a side effect would lose a review nobody asked to throw
  away.
- [x] **Re-average safety — found while wiring the above.**
  `refreshEpochDisplay()` (any post-processing toggle) did not apply the
  committed exclusion, so a toggle after a commit would silently restore every
  excluded trial. It now resolves and applies it, keeping Segment Health's
  labels counted separately so reviewed exclusions are not attributed to a
  control the operator never touched. `PSAExclusionSummary.recordExclusions` was
  made **idempotent per reason** in the same pass: it previously incremented,
  and re-averaging from an already-folded summary would have grown the counts on
  every toggle until the file claimed more exclusions than the category had
  trials.
- [x] **Restore on navigate — done 2026-08-26.**
  `ReplaySettingsRestore.Settings.trialExclusion` carries the *step*, not a
  `Bool`, because the decision is the payload: two nodes can both "have an
  exclusion" and exclude different trials, so restoring a mere on/off would
  leave whichever trial list happened to be loaded. Set totally from the path —
  nil included — in both `restoreStageSettings` and the `ProcessingCore` walk.
  This is the blink-detection bug one payload larger, and it has a third
  instance the navigation case does not cover: a batch reuses one
  `ProcessingCore`, so a file whose script names no exclusion must *clear* the
  previous file's rather than inherit it — silently, as "0 excluded, 2
  unresolved" rather than as an error. Both directions are pinned.

### Tests

- [x] `eva.xml` round-trip of criteria, keys, indices, reasons, origins, and
  restorations.
- [x] Key resolution survives a re-segment that changes epoch bounds, and an
  unresolvable key is reported rather than dropped.
- [x] A test proving the exclusion is observable in the samples at all, so the
  count-based tests cannot pass vacuously
  (`anExcludedTrialActuallyChangesTheAverage`), plus end-to-end application
  through `ProcessingCore` — the path a headless batch takes.
- [ ] Paired *interactive* vs headless sample equality in
  `PairedValidationTests`. Both paths now resolve inside the one
  `buildAndPostProcess`, so they agree by construction; the comparison is still
  owed, on the RW-1 item 4 principle that construction arguments are not
  evidence.
- [x] History: committing forks a node, committing the identical set at the same
  parent deduplicates, review order and restorations do not move the node, and
  re-tuned thresholds fork even when the trial set matches.
- [x] Navigating back before a commit restores the full-trial average, and does
  not walk the pointer forward onto the commit again
  (`steppingBackBeforeACommitStays`, driving the real tree the way the
  chain-signature observer does).
- [ ] QuickLook summary and `RecordingCombiner` see the new reason code.
  Structurally they must — both read `categoryRejections`, which now carries it
  — but neither is asserted on directly.

**Exit:** exclusions survive the file and remain attributable to both the rule
and the human decision; previewing alone never removes a trial; and the same
recording produces the same average interactively, headlessly, after reload, and
after replay.

### Deliberately out of scope

Segment Health's manual quality labels stay session-only in this milestone. They
are a different judgement (a bad *segment*, not a trial unlike its category) and
folding them into the same persisted step would widen TW-5 into a rewrite of
Segment Health's semantics. Both feed the one key-resolution path added here, so
promoting them later is a small step — carried in F-1.


---

# 6. Time-Frequency & Rhythmicity

## Time-Frequency — scope and the organs it was built from


Bring frequency-domain analysis to the epoch level: not just "what is the spectral
power of this recording" (already shipped) but "how does power and phase-locking
evolve, time-locked to the event" — ERSP and ITPC, the frequency-lens counterpart
to the Average / Trials waveform views. The payoff is that EVA can measure
oscillatory responses in established bands (δ/θ/α/β/γ) or continuously, export them
in the forms the field actually publishes, and feed them into the cluster-based
permutation stats EVA already owns.

**Why this is far cheaper than it looks — most organs already exist:**

- **Whole-recording spectral band power is already shipped** —
  `EVA/Analysis/EEGAnalysisEngine.swift` `spectralAnalysis` does FFT/PSD absolute +
  relative power per band, per channel, with a tidy long-format CSV export. PART TF
  reuses its band definitions and its CSV schema verbatim.
- **A Morlet CWT + scalogram already exist** — `EVA/Wavelet/
  ContinuousWaveletTransform.swift` (Morlet, w0=6, scale↔freq) and
  `WaveletScalogram.swift` (`power[freq][time]`, log-spaced). Currently **real part
  only** — good for a picture, but it yields no phase and a biased power estimate.
- **The cluster-based permutation stack is already written** — `EVA/Trials/
  ClusterPermutationAnalyzer.swift`, the F-variant, `ClusterSpatialAdjacency`, null
  distributions (Maris–Oostenveld). The hardest group-stats code is done.
- **Epoch / average scaffolding** — `EVA/Epoching/AveragesWorkspaceViews.swift`
  (EpochSegment, overlays, channel/baseline selection) and the **Metal wavelet
  backend** (`WaveletMetalBackend.swift`) are both reusable.

**The genuine gaps:** (1) a **complex analytic Morlet** (add the imaginary part to
the existing kernel) so we get phase → ITPC and an unbiased `|c|²` power; (2)
**per-trial stack aggregation** into ERSP + ITPC; (3) a **frequency axis on cluster
adjacency**; (4) a small **binary map writer**.


```text
TF-1 (complex Morlet + ERSP + validation)      ← the only hard numerical piece
   ├─→ TF-2 (ITPC + multitaper + TF tab UI)
   │       └─→ TF-3 (binary maps + tidy scalar CSV export)
   │               └─→ TF-4 (frequency-axis cluster permutation stats)
```

New module: `EVA/TimeFrequency/`
`TimeFrequencyModels.swift` · `ComplexMorlet.swift` · `Multitaper.swift` ·
`TimeFrequencyEngine.swift` · `TimeFrequencyMetalBackend.swift` ·
`TimeFrequencyView.swift` · `TimeFrequencyExport.swift`


## TF-1 — Complex Morlet + ERSP + validation — **DONE (except GPU path)**

The one hard part; its numbers are proven against MNE. New module
`EVA/TimeFrequency/` (`ComplexMorlet.swift`, `TimeFrequencyModels.swift`,
`TimeFrequencyEngine.swift`); gate in `EVATests/TimeFrequency/`.

- [x] Complex Morlet kernel returning `(re, im)` — `ComplexMorlet.kernel`.
  Reproduces MNE's `mne.time_frequency.morlet` convention exactly (`σ_t =
  n/2πf`, ±5σ support, `√0.5·‖W‖` normalization, `zero_mean=True`). NOTE: this
  is a *new* complex kernel, not the real `ContinuousWaveletTransform.kernel` —
  variable cycles require reparameterizing by `(f, n_cycles)`, which the fixed-
  width real kernel cannot express. Same scale↔freq convention, different kernel.
- [x] **Variable cycles:** `TFFrequencyPlan.logSpaced` ramps `nCycles` linearly
  3 → 10 across the band (per-frequency `nCycles` array).
- [x] Per-trial complex CWT → mean over trials of `|c|²` → baseline-normalized —
  `TimeFrequencyEngine.meanPower` / `.ersp`. Matches MNE
  `tfr_array_morlet(output='avg_power')` for the Morlet path.
- [x] **Baseline picker:** dB (default), percent, z-score, divisive, none —
  `TFBaselineMethod` + `TimeFrequencyEngine.normalize` over a sample-range window.
- [ ] Run the per-trial loop on `WaveletMetalBackend` (trials × channels × scales
  is embarrassingly parallel). **DEFERRED within TF-1** — correctness gate is
  green on the CPU direct-convolution path; the GPU/FFT port is a pure perf
  follow-on (the CPU path is ~16 s for 40 trials × 19 freqs × 1000 samples).
- [x] **Validation gate:** `TimeFrequencyEngineTests` — (1) MNE cross-check vs the
  committed fixture `Fixtures/tf_morlet_reference.json` (offline-generated by
  `Fixtures/generate_tf_reference.py`, since the XCTest sandbox can't shell out),
  max error < 1e-6 relative to peak; (2) physics recovery of a 6 Hz burst
  (frequency, latency ±150 ms, elevated dB); (3) determinism; (4) kernel norm.

**Effort:** small–medium — the complex kernel is ~30 lines; validation was the work.

## TF-2 — ITPC, multitaper, and the Time-Frequency tab — **DONE (visual pass pending)**

- [x] **ITPC** = `|mean over trials of (c/|c|)|` — computed in the SAME pass as
  ERSP power (`TimeFrequencyEngine.decompose`). Cross-checked against MNE
  `tfr_array_morlet(output='itc')`, max error < 1e-6; plus a phase-locked-burst
  physics check (ITPC ≈ 1 at the burst, low at baseline).
- [x] **Multitaper** path (DPSS tapers, short-time) as a `TFMethod` picker option.
  `DPSS.swift` reproduces `scipy.signal.windows.dpss(sym=False, norm=2)` exactly
  (L2 eigenvectors of the Slepian tridiagonal via LAPACK `dstevr_`, sign
  conventions, autocorrelation·sinc concentration ratios) — matches scipy to
  < 1e-9. `Multitaper.swift` builds the short-time wavelets
  (`exp(2iπf(t−t_win/2))·taper_m`, `t_win=n_cycles/f`); the engine combines them
  as `2·Σ conc_m·mean|c|² / Σ conc_m` (power) and `Σ_m|Σ c/|c||/n_trials` (ITC).
  Both cross-check against MNE `tfr_array_multitaper` at < 1e-6. Wired into the TF
  view's Method picker with a time-bandwidth control.
- [x] **UI:** third view mode beside Average / Trials (`AveragedDisplayMode
  .timeFrequency` → `TimeFrequencyView`). freq × time heatmap (Canvas, log-freq
  axis, event marker), channel selector, condition selector, Power/ITPC toggle,
  A − B condition-difference map, baseline + frequency/cycle controls. Reads the
  raw per-trial epochs (`segmentedEpochSignal`/`segmentedEpochSegments`) via the
  shared `TimeFrequencyTrials.stack` reduction. Settings persist on
  `EpochingViewModel`. Diverging (blue–white–red) map for dB/difference,
  viridis for ITPC. Data-prep unit-tested; visual pass on a real recording still
  pending.

**Effort:** medium — ITPC is trivial; DPSS multitaper is the new lift.

## TF-3 — Export: binary maps + tidy scalar CSV — **DONE**

All in `TimeFrequencyExport.swift`; Export menu wired into the TF view header.

- [x] **Full maps:** `channel × freq × time` per condition as dependency-free NPY
  (numpy v1.0 header + little-endian float32, C order). Byte-identical to
  `numpy.save` (test compares against a committed `numpy.save` fixture). A JSON
  sidecar carries the axes (channel names, frequencies, times) and parameters,
  since NPY holds no metadata.
- [x] **Scalar CSV ("single numbers"):** mean ERSP / ITPC per condition × channel
  × band × window, reducing over the frequency bins in each `EEGFrequencyBand
  .restingDefaults` band and the samples in each ROI window. Emitted in the long
  "summary + rows" convention `EEGAnalysisEngine.csvRows` uses (columns
  `row_type, scope, condition, channel_index, channel_name, band, window,
  measure, value`) — TF adds the `condition` and `window` columns it genuinely
  needs. Drops straight into a mixed model / JASP.
- [x] Baseline method, cycle settings, method, and time-bandwidth are reported —
  as `summary` rows in the CSV and in the NPY JSON sidecar.

**Effort:** medium — NPY writer is tiny; the scalar reduction reuses existing schema.


## Rhythmicity Explorer — LAVI, ABBA, WTPL, bursts, Metal, and persistence, Milestones 0–8

Shipped through Milestone 8 on 2026-09-11. Method reference:
[`docs/design/rhythmicity.md`](docs/design/rhythmicity.md).

### Milestone 0 — Reference and licensing lock

- [x] Pin the LAVI and WTPL commits; use the LAVI Python tree as the executable oracle.
- [x] Audit file-level licenses and third-party provenance.
- [x] Run the authors' Python LAVI example successfully outside EVA. Per user direction, do not require MATLAB; defer WTPL oracle execution to milestone 6.
- [x] Capture small deterministic input/output fixtures.
- [x] Resolve kernel convention differences.
- [x] Resolve fractional vs integer lag parity.
- [x] Resolve tail-definition and lookup-table behavior.
- [x] Write `EVATests/Fixtures/Rhythmicity/README.md`.

**Exit:** every externally defined numerical behavior needed for milestones 1–5 is pinned by a fixture or an explicit written decision.

#### Milestone 0 completion record (2026-09-11)

Milestone 0 is complete for the LAVI/ABBA work in milestones 1–5. The durable
record is `EVATests/Fixtures/Rhythmicity/README.md`; this section summarizes the
decisions that constrain implementation:

- LAVI is pinned at commit `78386879eeb8cf9be06a1edfa6917c91b2d0d2ba`.
  WTPL provenance is pinned at `6da57b71f1084c62cfa1a4deaebee227d38f2584`,
  but the maintained Python WTPL layer is explicitly unvalidated and is not an
  oracle. WTPL fixture work is a milestone-6 gate.
- The pinned LAVI Python smoke suite passes, and the authors' 3-channel,
  300-second example runs through current Python HEAD. The checked-in upstream
  result MAT files predate the current fractional-lag change and no longer match
  HEAD; EVA uses regenerated output from the pinned source, not the stale MAT
  snapshot.
- The maintained fractional rule linearly interpolates complex coefficients at
  `floor(lagCycles / f * fs)` and the following sample. EVA will match it. The
  commented integer/rounded v1.0.0 path is not the default.
- EVA's MNE-compatible `ComplexMorlet` is not sufficiently close for the paper
  preset (the deterministic spike reached approximately 0.54524 absolute LAVI
  difference). Add an isolated FieldTrip/LAVI-2026 convention and leave the
  ERSP/ITPC kernel unchanged.
- Paper-valid α=.05 inference means 200 surrogates and the fifth-lowest and
  fifth-highest order statistics at each frequency. The toolbox's 20-surrogate
  minimum/maximum envelope is exploratory, not α=.05.
- The paper preset applies that lower/upper rule per frequency. Preserve the
  toolbox's global minimum/maximum only as an explicitly labeled compatibility
  option, and export the significance source and rule with every result.
- Do not ship either upstream MAT lookup table initially. Their maintained
  generator, walkthrough consumer, repetition count, slope grid, dimension
  ordering, and global/per-frequency behavior are not mutually reproducible.
  Milestone 2 begins with on-demand, seed-controlled 200-surrogate inference.
- The two supplied high-density MFF recordings remain external. A deidentified
  manifest pins their hashes and structure; an opt-in test loads both through
  EVA via `EVA_RHYTHMICITY_MFF_ROOT` or the documented temporary marker. No
  participant waveform is copied or persisted in the repository.
- Repository-level MIT files do not eliminate the FieldTrip GPL and Venema
  IAAFT file-level provenance. Upstream code is reference-only. EVA's production
  implementation must be independently written from the paper and the pinned
  behavioral fixtures.

### Milestone 1 — Models and direct numerical reference

- [x] Add `RhythmicityModels.swift` and `RhythmicityPreset.swift`.
- [x] Add segment-aware input validation.
- [x] Add direct complex coefficient provider.
- [x] Implement fractional complex interpolation.
- [x] Implement segment-aware LAVI online accumulators.
- [x] Implement ABBA without significance.
- [x] Add synthetic/unit/reference tests.
- [x] Add deterministic cancellation hooks.

**Exit:** selected-channel LAVI and median-defined ABBA match pinned reference fixtures. Results are explicitly exploratory because significance is not yet available.

#### Milestone 1 completion record (2026-09-11)

Milestone 1 is complete as a numerical reference implementation. The new
engine deliberately computes one channel, segment, and frequency tile at a
time and retains only compact sufficient statistics and result arrays. It does
not duplicate or persist the EEG waveform, and it never constructs a complete
channel × frequency × time complex-coefficient cube.

- The paper preset contains the pinned 47 log-spaced frequencies, five-cycle
  FieldTrip/LAVI-2026 Morlet convention, 1.5-cycle lag, 6–14 Hz alpha anchor,
  valid-only edge policy, and no significance source.
- The direct scalar convolution path matches the pinned FieldTrip-style impulse
  coefficients to less than `1e-12`, including even-length kernels,
  half-sample phase, Python/FFT cropping, and valid-edge support.
- Fractional-lag LAVI for both channels across all 47 pinned frequencies
  matches the Python oracle to less than `1e-10` absolute error. Pair counts,
  pair durations, segmentation, non-finite gaps, zero-energy behavior, and
  amplitude invariance are independently tested.
- ABBA matches the pinned median, crossings, discrete boundary indices,
  extrema, directions, alpha-relative identities, and optional compatibility
  ribbon behavior. Milestone 1 normally supplies no ribbon; therefore each
  band's `isSignificant` and the channel's `lowerSignificance` and
  `upperSignificance` remain unavailable rather than implying an inferential
  result.
- Cooperative cancellation is checked during convolution and accumulation;
  progress is deterministic and monotonic across multi-channel work.
- The focused Milestone 0/1 suite passes 25 tests in four suites. The opt-in
  real-data gate additionally loaded both supplied 257-channel MFF recordings
  through EVA and analyzed a 12-second first-channel window at 6, 10, 20, and
  40 Hz without retaining participant samples; it passed in 88.601 seconds.

The direct backend is the correctness oracle, not the production path for an
entire multi-minute, high-density recording. The explorer's Run Analysis action
must remain unavailable until Milestone 4 provides complete UI orchestration.
This keeps the current shell honest while preserving the direct engine for
parity tests and small, bounded diagnostic workloads.

### Milestone 2 — Aperiodic fit and statistical significance

- [x] Refactor shared Welch/aperiodic spectrum code.
- [x] Implement and validate IAAFT.
- [x] Implement 200-surrogate on-demand ribbon.
- [x] Implement tail rule established in milestone 0.
- [x] Implement significance-aware ABBA.
- [x] Add fixed-seed and distributional tests.
- [x] Decide whether a bundled lookup table is justified for first release: no.
- [x] If yes, add generator, table, checksum, range handling, and validation — not applicable because lookup tables are intentionally unavailable.

**Exit:** EVA can truthfully label sustained/transient bands significant for a paper-valid or exactly matched custom configuration.

#### Milestone 2 completion record (2026-09-11)

Milestone 2 is complete as a tested, on-demand inferential path. The Paper 2026
preset now requests exactly 200 IAAFT surrogates, two-sided α=.05, and the
per-frequency fifth-order-statistic rule. A separate
`paperLAVI2026Exploratory` configuration keeps reference and bounded ingestion
tests from accidentally launching inference.

- `AperiodicSpectrumEstimator` owns the shared Hann/50%-overlap Welch primitive.
  Windows are wholly contained in finite selected segments and never bridge a
  discontinuity or NaN. Channel Health now calls this primitive and its shared
  log/log exponent helper while retaining the health metric's established fit
  policy. Rhythmicity uses a named positive power-law fit in linear power and
  stores frequencies, observed/fitted power, exponent, log intercept, R²,
  fit/exclusion ranges, window size, overlap, and accepted-window count.
- `IAAFTSurrogateGenerator` implements the published alternating projections:
  seeded shuffle, spectral-magnitude projection, inverse transform, and exact
  rank remapping to the observed finite sample distribution. It uses Accelerate
  where a native DFT is available and an exact-length Bluestein fallback for
  unsupported/prime lengths; signals are never trimmed or zero-padded merely to
  satisfy an FFT size. Transform plans and Bluestein chirps are reused across
  the 200 draws for each finite run.
- The 2×10⁻⁴ error threshold, 10⁻⁶ stall threshold, and 1000-iteration cap are
  explicit. Every retained surrogate records its derived seed, iteration count,
  spectral/amplitude adaptation errors, and convergence status. Stable stalled
  or iteration-limited final iterates are retained and reported, matching the
  maintained toolbox policy; their count is also surfaced as a result warning.
- On-demand generation preserves each run's observed amplitude distribution,
  as described in the paper. EVA does not reproduce the maintained Python
  shortcut that supplies sorted uniform random values. That shortcut remains a
  documented compatibility difference rather than being labeled paper-valid.
- Null LAVI profiles are computed using the same signal segments, complex
  coefficient provider, frequencies, wavelet width, lag, edge policy, precision,
  and backend as the observed profile. Only the seed and input phase structure
  differ. Cancellation checks occur between IAAFT iterations, runs, surrogates,
  and LAVI tiles; partial ribbons are never returned.
- `LAVISignificanceProvider` rejects any claim to the validated paper rule unless
  the configuration contains exactly 200 surrogates, α=.05, observed-sample
  amplitudes, and per-frequency fifth-order-statistic tails. At each frequency,
  the sorted null values at indices 4 and 195 become the lower and upper limits;
  percentile interpolation is not used.
- `LAVIEngine` now passes that ribbon into ABBA. Every region receives a Boolean
  significance value and signed margin only when a complete validated ribbon is
  available. The result stores the compact ribbon, aperiodic fit, base seed, and
  surrogate summary; it still stores no raw or surrogate waveform.
- The combined Milestone 0–2 plus Channel Health regression gate passes 42 named
  tests (44 executions including parameterized white/pink/steep cases). Coverage
  includes exact amplitude-distribution preservation, seed determinism,
  different-seed variation, white/pink/steep spectral shape, prime-length DFT
  round trips, segment isolation, power-law recovery, line-band exclusion,
  cancellation, nonconvergence reporting, exact fifth-tail extraction, full
  significance-aware ABBA, and a real direct-Morlet 200-surrogate smoke run.
- The opt-in external-data gate also passed against both supplied 257-channel
  MFF recordings in 125.364 seconds. After whole-recording ingestion, each file
  contributes a bounded observed-data window to the 200-surrogate Milestone 2
  path; the test verifies compact fits, ribbons, diagnostics, and band labels
  without copying or persisting participant waveforms.

No bundled lookup table is included. The two upstream MAT tables cannot be
reproduced consistently from their maintained generators and consumers, and
silently selecting or interpolating one would weaken the inferential claim. A
future table remains possible only after EVA owns its generator, schema,
checksum, bounds, and held-out validation.

Milestone 2 established correctness rather than acceptable whole-recording
speed. The direct Morlet backend remains appropriate only for tests and bounded
diagnostic data; Milestone 3 below supplies the production FFT path.

### Milestone 3 — Production CPU backend

- [x] Implement Accelerate/vDSP FFT convolution.
- [x] Implement overlap-save/add tiling.
- [x] Add direct-vs-FFT parity tests.
- [x] Add multi-segment boundary tests.
- [x] Add bounded worker pool and memory budget.
- [x] Add progress/cancellation.
- [x] Benchmark representative workloads.

**Exit:** multi-minute, multi-channel LAVI is practical without excessive memory, and the direct backend remains the numerical oracle.

#### Milestone 3 completion record (2026-09-11)

Milestone 3 is complete. The Paper 2026 preset now selects the production
`.accelerateFFTCPU` backend with a 512 MiB total working-memory budget, EVA's
global CPU-worker cap, and a preferred 32,768-sample output tile. Callers can
still select `.directReferenceCPU`, which remains the coefficient and LAVI
oracle used by parity tests.

- `AccelerateFFTComplexCoefficientProvider` performs exact linear complex
  convolution through Accelerate DFTs. It uses overlap-save blocks with
  `M - 1` samples of history and copies only the uncontaminated `N - M + 1`
  outputs into the same central crop used by the direct provider. It never
  allocates the full convolution or a channel × frequency × time cube.
- `RhythmicityProductionWorkPlanner` resolves a power-of-two transform length,
  output samples per block, block range, and a conservative per-worker working
  set before allocation. Worker count is the minimum of the job count, explicit
  user cap, EVA's global CPU cap, and the count affordable under the configured
  memory budget. A job fails visibly before transform allocation if even one
  worker cannot fit.
- The default 512 MiB allowance includes copied finite input runs, active FFT
  tiles, returned complex coefficient tiles, and a thread-safe LRU kernel-
  spectrum cache capped at one eighth of the total budget and no more than
  128 MiB. Finite segment runs are copied once per channel and shared read-only
  across frequency workers.
- `LAVIEngine` schedules frequency work concurrently only for providers marked
  as production providers. Results are gathered by original frequency index,
  so worker scheduling cannot reorder the spectrum. Direct and custom providers
  retain the serial path. The same production provider instance is passed into
  all 200 null analyses, allowing bounded kernel spectra to be reused.
- Progress callbacks are serialized at frequency-tile completion and therefore
  remain monotonic even when workers finish out of order. Cancellation is
  checked before allocation, between overlap-save blocks, between finite runs,
  and during LAVI reduction. Errors or cancellation discard the incomplete
  frequency set; no partial result is published.
- Forced multi-block coefficient tests compare both real and imaginary outputs
  with the direct oracle to less than `1e-11`. Engine tests also match LAVI and
  pair counts across explicit segments, a NaN split, and an unselected gap whose
  contents are changed by six orders of magnitude. A two-worker instrumented
  provider reaches but never exceeds two concurrent calls, and identical jobs
  are restored to frequency order.
- The Debug-build benchmark on a Mac Studio (arm64, macOS 26.6.2) completed a
  two-minute × four-channel × 47-frequency paper profile in 1.633 seconds with
  a 128 MiB budget, four-worker cap, and 4,096-sample requested tiles. A separate
  32,768-sample, 4 Hz long-kernel gate verifies the FFT path is faster than the
  direct oracle while remaining below `1e-11` coefficient error. These are
  developer regression measurements, not release SLAs.
- The opt-in integration gate passed both supplied 257-channel, 1 kHz MFF
  recordings in 125.364 seconds total. It loads each full package, compares
  direct and production LAVI on the same 12-second observed window, and runs
  200-surrogate production inference on 2,048 real samples. No waveform or
  surrogate is copied into the repository or retained in the result.
- The final combined Milestones 0–3 plus Channel Health regression gate passes
  49 named tests (51 executions including parameterized spectral-shape cases)
  with zero failures and no compiler warnings.

The recorded environment and workloads live in
`EVATests/Fixtures/Rhythmicity/milestone3-benchmark.json`. Production throughput
still scales with selected channels, frequencies, duration, and 200 surrogate
draws; Milestone 4 should present an estimate and retain cancellation rather
than implying that every whole-head, whole-recording request is instantaneous.

### Milestone 4 — Bands explorer UI and export

- [x] Add `RhythmicityExplorerViewModel`.
- [x] Wire it into `WaveformView` as a standalone explorer.
- [x] Add source, segment, and channel-scope controls.
- [x] Build LAVI spectrum with median/ribbon/band overlays.
- [x] Build ABBA band table.
- [x] Add selected-channel and multi-channel summaries.
- [x] Add validity warnings and stale-result behavior.
- [x] Add CSV/NPY/JSON package export.
- [x] Add Help and citation copy.
- [x] Add release notes.

**Exit:** a user can run research-grade LAVI/ABBA on a processed recording, understand validity, inspect channels, and export reproducible results.

#### Milestone 4 completion record (2026-09-11)

Milestone 4 is complete for the recording-level Bands workflow. The waveform
EEG menu opens a standalone, resizable explorer with Paper 2026 and explicitly
exploratory runs; entire-recording, visible-range, and waveform-selection data
scopes; selected, visible-good, named-set, and all-good channel scopes; and an
expert-only override for including marked artifact intervals.

- The selected-channel spectrum fixes LAVI to `[0, 1]` on a log-frequency axis
  and links the observed curve, median, significance ribbon, ABBA region fills,
  peak/trough markers, hover readout, table selection, and topography.
- Multi-channel results add a sensor × frequency matrix, spectrum gallery,
  per-band peak topography, and detection-rate summaries without plotting every
  channel's ribbon simultaneously.
- Runs snapshot their signal revision, configuration, ranges, channel state,
  interpolation revision, artifact definition, processing provenance, and seed.
  Changes visibly stale an old result; cancellation discards partial work and
  retains the last complete result.
- Directory exports contain `manifest.json`, long-form `lavi.csv` and
  `abba-bands.csv`, channel-major `lavi.npy`, `lavi-ribbon.npy`, and
  `warnings.txt`. The manifest pins schema/method/reference versions, axes,
  selection, backend, valid counts/durations, surrogate settings, processing
  history, warnings, and EVA build identity.
- Help and 0.1.9 release notes preserve the interpretation safeguards and cite
  the Karvat et al. paper and pinned LAVI/ABBA toolbox. Event-related WTPL and
  bursts remain explicitly unavailable until milestones 6 and 7.
- Two focused Milestone 4 tests pass. The opt-in real-data integration gate also
  passes both supplied 257-channel, 1 kHz Josh MFF recordings in 120.758 seconds,
  including full package ingestion, direct-vs-production FFT parity on bounded
  observed windows, and a complete 200-surrogate significance path for each
  recording. No participant waveform is copied into the repository or export.

### Milestone 5 — Time-Frequency band integration

- [x] Add recording-scoped `DetectedRhythmicityBandSet` state.
- [x] Add explicit “Use in Time-Frequency” action.
- [x] Add TF band-source picker.
- [x] Overlay ABBA boundaries and peaks on TF maps.
- [x] Use selected ABBA bands for TF ROI scalars.
- [x] Preserve global band preferences unless explicitly saved.
- [x] Export band-source provenance with TF results.
- [x] Add invalidation and integration tests.

**Exit:** individualized ABBA bands can guide ERSP/ITPC exploration and export without changing the underlying TF values or global defaults.

#### Milestone 5 completion record (2026-09-11)

- “Use in Time-Frequency” snapshots the displayed channel's current ABBA result
  into recording-session state and switches TF to that explicit source. Stale
  results and channels without detected bands cannot be published.
- The TF band-source picker separates immutable EVA defaults, saved user
  preferences, and the published Rhythmicity Explorer result. No source choice
  writes `ProcessingDefaults.shared.timeFrequencyBands`.
- ABBA sustained/transient regions, boundaries, labels, and peak markers are a
  display-only heatmap layer. The underlying ERSP/ITPC grids and color scales are
  unchanged.
- TF overview ROI reductions and scalar exports use the same selected source.
  When ABBA bands come from one channel, EVA states that those boundaries are
  applied to every displayed channel instead of mixing channel-specific bands.
- NPY JSON sidecars and scalar CSV summaries include the band source, recording
  identity/revision, channel and scope, selection, preset, method version,
  creation time, ranges, directions, peaks, and significance labels.
- Three focused integration tests cover explicit publication and preference
  isolation, stale-result rejection without fallback, and ABBA ROI/export
  provenance. The app target and focused suite pass on macOS.

### Milestone 6 — Within-Trial Phase Locking

- [x] Implement shared `WTPLEngine`.
- [x] Establish and match a validated independent Python WTPL oracle fixture.
- [x] Add raw WTPL and ΔWTPL.
- [x] Add condition comparisons and valid-count maps.
- [x] Build Event-related explorer mode.
- [x] Reuse/generalize TF heatmap and overview components.
- [x] Add NPY/scalar exports.
- [x] Add optional TF WTPL shortcut.
- [x] Add WTPL-vs-ITPC interpretation tests/help.

**Exit:** users can analyze event-related within-trial rhythmicity with explicit baseline and condition semantics.

#### Milestone 6 completion record (2026-09-11)

- `WTPLEngine` is the single double-precision implementation used by
  Rhythmicity Explorer and the Time-Frequency shortcut. It evaluates signed
  one-cycle phase relations after complex-plane fractional interpolation,
  isolates every trial, retains invalid edges as NaN, and computes condition
  means, unbiased variance, and valid-trial counts with online accumulators.
- The independent standard-library Python paper-equation generator and its
  committed fixture pin full raw, delta, variance, and count maps. Swift matches
  the fixture within `2e-12`; the fixture SHA-256 is
  `b6a46ff865a1e1f721ad77589a4bc6f1cdfc8e23fb0514c906241fabda5fa90a`.
  The MATLAB-only upstream WTPL repository remains provenance/API context, not
  copied code or an executable oracle.
- Event-related mode uses retained epoch conditions and channel scopes, supports
  raw WTPL, ΔWTPL, A − B comparisons, and a valid-count display (minimum A/B
  support for differences), and reuses the NaN-hatched TF heatmap plus ABBA band
  overlays and band × window ROI summaries. Runs are cancellable and stale when
  epochs, signal revision, conditions, channels, frequencies, lags, or baseline
  settings change.
- Baseline semantics are explicit: raw WTPL is always available when the
  transform is valid; ΔWTPL subtracts each frequency's mean over the requested
  complete interval. EVA never silently shrinks an out-of-epoch baseline and
  reports frequencies with no valid baseline support.
- Event exports contain condition-specific raw WTPL, ΔWTPL, and valid-count NPY
  maps; tidy band × window scalars; a versioned manifest with axes, settings,
  source and processing provenance; and warnings. The Time-Frequency WTPL option
  delegates to the same engine and records the same method, lag, baseline, and
  invalid-value semantics.
- Help and the consolidated 0.1.9 release notes distinguish within-trial phase persistence from
  across-trial ITPC. Eleven focused tests cover the oracle, phase reset,
  amplitude invariance, fractional lags, edge masks, trial isolation, online
  means, strict baselines, WTPL-vs-ITPC interpretation, TF-engine delegation,
  condition support, and package export.
- The opt-in external gate also passes both supplied 257-channel, 1 kHz MFF
  recordings in 117.466 seconds. Each contributes four bounded observed-data
  trial containers to direct-vs-production WTPL parity checks at 8, 10, and
  20 Hz, including raw/delta maps, NaN masks, and valid counts; no participant
  waveform is copied into the repository or exports.

### Milestone 7 — Burst analysis

- [x] Pin maintained burst reference behavior.
- [x] Implement deterministic 2D peak detection.
- [x] Implement power- and WTPL-defined onset/offset refinement.
- [x] Implement overlap merge.
- [x] Implement metrics and channel-specific band assignment.
- [x] Build the burst map, linked timeline, sortable table, summaries, and filters.
- [x] Keep event annotation out of scope because no product requirement demands it.
- [x] Add versioned NPY/CSV exports and focused/reference/real-MFF tests.

**Exit:** burst detections and statistics reproduce the reference workflow and remain clearly separated from artifact cleaning.

#### Milestone 7 completion record (2026-09-11)

- EVA pins `Bursts_detection_WTPL_v1_0_0.m` from WTPL commit
  `6da57b71f1084c62cfa1a4deaebee227d38f2584` and file SHA-256
  `76375d0f2e972ed34654abdbed12b410754876ca5b8ea8286eca2c291c101c29`.
  The upstream file supplies the maintained thresholds and workflow, but calls
  helper functions absent from the repository; it is therefore provenance and
  behavioral reference material rather than an executable oracle.
- `RhythmicBurstDetector` computes per-frequency P90/P75 thresholds, consolidates
  regional-max plateaus deterministically, refines candidate boundaries without
  crossing selection segments, and repeatedly merges overlapping close-frequency
  candidates using the higher power×duration representative. The optional WTPL
  boundary uses the same signed-lag reducer as Milestone 6.
- Every burst records duration in milliseconds/cycles, rate and occupancy inputs,
  relative P90 power, energy, frequency span, peak/mean WTPL, band consistency,
  channel/segment identity, and LAVI/ABBA sustained/transient identity when fresh
  channel-specific bands are available.
- Bursts mode includes selectable power/WTPL maps with peak and interval overlays,
  a linked waveform, filters, band summaries, duration histogram, and sortable
  table. It deliberately exposes no clean/apply or artifact-event action.
- Export bundles contain burst and band-summary CSV, normalized-power and WTPL NPY
  maps with axis sidecars, a method/reference/source/selection manifest, and all
  warnings. The manifest explicitly identifies the result as neural-rhythmicity
  analysis rather than artifact rejection.
- A dependency-free Python map oracle (SHA-256
  `e6e01fd37cc4ad365b3ae3b1f51295a8cc075dc114541deb7890b35afca0de00`)
  plus focused Swift tests cover thresholding, P75 and WTPL boundaries, plateaus,
  merge/non-merge behavior, metrics, occupancy union, export rows, and segment
  clamping. The opt-in MFF gate passes the production transform-to-detection
  chain on bounded observed data from both supplied recordings; no participant
  waveform is copied into the repository or exports.

### Milestone 8 — Metal acceleration and persistence

- [x] Profile CPU FFT bottlenecks first.
- [x] Implement bounded, frequency-tiled Metal coefficient computation.
- [x] Add CPU/GPU parity and boundary-stability tests.
- [x] Add automatic fallback and preferences.
- [x] Add recording-scoped persisted result payload.
- [x] Add method, upstream-reference, and signal-revision staleness checks.

**Exit:** high-density workloads are accelerated where measurement justifies it,
and saved results cannot be mistaken for current results after preprocessing
changes.

#### Milestone 8 completion record (2026-09-11)

- CPU profiling established the crossover before automatic GPU selection. On the
  reference Apple-Silicon host, a 32,768-sample 4 Hz coefficient tile took
  36.95 ms through bounded Accelerate FFT and 7.25 ms through Metal, a 5.1×
  improvement. Automatic mode retains CPU FFT for work below the measured
  frequency × sample threshold and when no compatible Metal library is present.
- `RhythmicityKernels.metal` contains the compiled Float32 Morlet coefficient
  kernel so Xcode shader diagnostics and GPU capture remain available. The Swift
  backend dispatches one channel/run/frequency tile at a time, uses shared bounded
  buffers, applies the same central crop and validity range as the Double CPU
  oracle, and never constructs an all-channel complex cube.
- Runtime device, pipeline, shape, allocation, command, and memory-budget failures
  fall back to the existing bounded Double-precision Accelerate FFT path and are
  recorded as result warnings. Preferences expose CPU-only or automatic Metal-
  preferred operation; each result records the backend and precision actually
  used rather than merely the requested policy.
- Compiled-kernel tests compare real and imaginary coefficients with the direct
  CPU oracle below `2e-4`. End-to-end LAVI agrees below `2e-5`, valid-pair counts
  are identical, and every ABBA begin/end/peak/direction boundary is exact on the
  validated fixture. Progress, cancellation, valid-edge semantics, and the
  existing 512 MiB production policy remain in force.
- Each completed Bands analysis saves only its compact result and selection in
  Application Support, keyed by a SHA-256 recording-path identity. The envelope
  includes a schema version, EVA method revision, pinned upstream reference
  commit, processed-signal revision, save time, and content checksum; it contains
  neither source samples nor surrogate waveforms.
- Reopening a recording restores the saved spectrum for inspection, but marks it
  visibly stale unless the signal revision, current selection/channel context,
  method version, and upstream reference revision all still match. Stale results
  cannot be republished as current Time-Frequency bands. Checksum tampering is
  rejected rather than shown.
- Six focused Milestone 8 tests cover automatic crossover and fallback, compiled
  Metal parity, exact band stability, the recorded CPU/GPU profile, compact
  persistence round-trip, revision staleness, non-finite result encoding, and
  checksum rejection. The app build compiles and links the standalone shader into
  `default.metallib`. The opt-in MFF gate also passes both supplied 257-channel,
  1 kHz recordings in 119.729 seconds through the complete bounded LAVI/WTPL/
  burst validation chain without copying or persisting participant waveforms.


---

# 7. Source & Forward Modeling

### SI-1 — Extract the shared spherical forward model — ✅ **COMPLETED 2026-08-26**

- [x] Establish app-neutral forward types and typed validation errors in
  `EVA/Core/Forward/`.
- [x] Move the spherical-harmonic solver math into `EVA/Core/Forward/`.
- [x] Adapt EVA `ElectrodeGeometry` and EVASimulate `Montage`/
  `SimulatedSource` at their own boundaries.
- [x] Wire the shared EVA sources into EVASimulate's existing build without
  copying the implementation or adding a heavy dependency.
- [x] Compile both consumers and pass focused forward parity/contracts (99
  simulator outcomes and 5 focused EVA tests).
- [x] Run forward self-tests, complete simulator tests, determinism checks, and
  the EVA suite with no intended generated-signal change.

**Exit:** both programs use one forward solver and simulator leadfields remain
within the pinned numerical tolerance.

Implementation record:

- EVA owns app-neutral head/electrode/dipole/reference/leadfield values, typed
  errors, the arbitrary-shell spherical-harmonic solver, and convergence checks
  under `EVA/Core/Forward/`.
- EVA's `ElectrodeGeometry` and EVASimulate's stable montage/source/truth values
  adapt at their own boundaries; EVASimulate compiles the EVA sources directly
  and contains no second solver implementation.
- Verification: optimized simulator build; 99/99 simulator outcomes; 5/5
  focused shared-forward tests; unchanged fingerprints for all eight existing
  scenarios; 1,264/1,264 EVA tests across 130 suites. No baseline or hashing
  infrastructure changed.
- The complete phase record is `Tools/EVASimulate/SI1_EXTRACTION.md`; SI-0
  remains the acceptance contract.


## The forward-model and Resolve asset inventory


| Asset | Where | State |
|---|---|---|
| Analytic 3-shell spherical forward (60-term series, free-orientation lead field) | `EVACore/Core/Forward/SphericalForwardModel` | shipped, tested vs. ground truth |
| Ellipsoidal forward | `EVACore/Core/Forward/EllipsoidalForwardModel` | shipped |
| Constant-collocation double-layer BEM, Van Oosterom solid angles, Lynn–Timlake deflation, icosphere mesher | `EVACore/Core/Forward/BEMForwardModel` | shipped, converges to sphere; 3-shell 1:80 skull error 11%→1.65% by mesh level. **Generation-side / inverse-crime use only** as of 2026-09-06; subject BEMs are imported (R3) |
| `ForwardDipole`, `SimulatedSource`, `LeadField`, `EEGReference`, `Vector3D` | `EVACore/Core/Forward/ForwardTypes`, `EVACore/Simulation/SimulationForwardDomain` | shipped |
| Single / multiple / spatio-temporal / shared-geometry ECD fit (grid search, sphere only) | `EVA/Simulation/SingleDipoleFit` | shipped (ROADMAP Stage 3c); slow (Stage 3c-perf not started) |
| Source Simulator window: glass-brain, live scalp field, activations, noise + truth scoring, Fit mode | `EVA/App/SourceSimulatorWindowView`, `HeadProjectionView`, `ScalpFieldView`, `SourceButterflyView`, `SourceFitModeView`, `SourceTimelineView`; `EVA/Simulation/SourceSimulatorController`, `…Noise`, `…Artifacts` | shipped, Stages 1–3c |
| "Fit Source Model" bridge from a recording's averaged butterfly/topography into the Source window | `EVA/Waveform/WaveformSourceFit`, `EVA/App/PendingSourceFit` | shipped; in-process Notification handoff |
| EGI `coordinates.xml` true 3-D electrode positions (unit sphere) | `EVACore/Channels/ElectrodeGeometry` | shipped; **fiducial entries (type 2) are parsed and discarded** |
| 10-20 style synthetic montages | `EVACore/Simulation/Montage` | shipped |
| NIfTI-1/2 reader: gzip, all common datatypes, qform/sform affine | `EVAPreviewKit/NIfTI/*` | shipped for QuickLook; not yet in `EVACore/` |
| GIFTI surface reader + SceneKit surface renderer | `EVAPreviewKit/GIFTI/*` | shipped for QuickLook; not yet in `EVACore/` |
| Surrogate-source BCG separation (29 regional sources, sphere lead field) | `EVA/Artifacts/SourceInformed/SurrogateBrainBasis`, `EVACore/…/SourceInformedOperator` | shipped; **stays in EVA** (it is cleaning, not localization) |
| ROADMAP Tier 6 design for source grids and the minimum-norm family | `ROADMAP.md` §7.1–7.5 | design only |

---


## R0 — Foundation *(done 2026-09-02)*

- [x] **No new `.xcodeproj`.** Resolve is another target in `EVA.xcodeproj`, next to
  `EVA`, `EVASimulate`, `EVAQuickLook`, `EVAThumbnail`, `EVATests`, `EVAUITests`.
- [x] **Shared code lives in `EVACore/`**, an Xcode synchronized folder group attached
  to `EVA` and `EVASimulate` (later: Resolve). The 38 files EVASimulate used to borrow by
  per-file membership were moved there with sub-folders preserved. Same mechanism as
  `EVAPreviewKit/`. No framework, no `public` pass; everything
  stays in the `EVA` module for tests.
- [x] **EVASimulate re-pointed** at the folder; per-file references deleted.
- [x] `Tools/EVABIDS/build.sh` and `Tools/EVAHelper/build.sh` re-pointed at new paths.
- [x] Verified: EVA, EVASimulate, EVATests build; 1542 tests pass; both tool scripts build.

**Why not a framework.** The candidate folders were not UI-free (`IO/` has 8 SwiftUI
files, `Simulation/` has controllers, `Models/` is only ICLabel), and a module boundary
would have forced a `public` pass over ~13k lines / ~2,300 declarations plus test-import
churn. The folder can become a framework later without moving anything again.

**Rule going forward:** anything visible to more than one app or tool goes in
`EVACore/`; anything importing SwiftUI/AppKit stays in the owning app's folder.

Current `EVACore/` layout (after R1–R2.3):

```
EVACore/
  Core/            AccelerateCompat, DSP, LinearAlgebra, SeededGenerator
  Core/Forward/    ForwardTypes, SphericalForwardModel, EllipsoidalForwardModel, BEMForwardModel
  Geometry/        HeadTransform (frames, Umeyama fit, SVD3), TriangleMesh + SurfaceIndex
  Imaging/         VolumeMorphology (BinaryVolume, VolumeOps)
  Registration/    SurfaceRegistration (ICP, projection, template scalp fit)
  IO/              EGISensorXMLParser, MFFFileType, MFFReader, MFFWriter
  IO/NIfTI/        NIfTIHeader, NIfTIByteSource, NIfTIScalarDecoder, NIfTIVolume (+ writer)
  IO/GIFTI/        GIFTIPreviewModel, GIFTIQuickLookReader, GIFTICompanionSurfaceResolver
  IO/FIF/          FIFFile (tags), FIFInterop (trans, digitization, BEM surfaces)
  Channels/        ElectrodeGeometry, SensorLayout, ElectrodePositions, StandardMontage(+Data)
  Epoching/        EpochModel
  Pipeline/        EVAProcessingScript
  Simulation/      generators, artifact models, config/scenario types, Montage,
                   SingleDipoleFit, SourceSimulatorNoise, SourceSimulatorArtifacts
  Artifacts/SourceInformed/  SourceInformedOperator
```

---


## R1 — Stand up the EVA Resolve target and move the Source Simulator out of EVA  *(done 2026-09-02)*

Goal: EVA has zero source-localization UI; Resolve opens with the Source Simulator working
exactly as it does today, and "Fit Source Model" in EVA opens Resolve instead of an EVA
window.

- [x] **New macOS App target `EVAResolve`** (display name "EVA Resolve"), folder
  `EVAResolve/`, bundle ID `gov.nih.nimh.cmn.eva.resolve`, own Info.plist (registers the
  `.mff` document type) and asset catalog (EVA's icon for now). `EVACore` attached via
  `fileSystemSynchronizedGroups`. `EVAResolveTests` bundle hosted in the app; scheme
  `EVAResolve` builds and tests it.
- [x] **Moved to `EVACore/Simulation/`:** `SingleDipoleFit`, `SourceSimulatorNoise`,
  `SourceSimulatorArtifacts`.
- [x] **Moved to `EVAResolve/Simulator/`:** `SourceSimulatorWindowView`,
  `HeadProjectionView`, `ScalpFieldView`, `SourceButterflyView`, `SourceFitModeView`,
  `SourceTimelineView`, `PendingSourceFit`, `SourceSimulatorController`; tests to
  `EVAResolveTests/`. Nothing else had to move — the views only used `EVACore` types.
- [x] **Handoff is a file, not a URL scheme.** `WaveformSourceFit` in EVA writes the
  averaged conditions as an averaged `.mff` (MFFWriter carries coordinates.xml /
  sensorLayout.xml across) plus an `eva-resolve-fit.json` sidecar naming the viewed
  sample, then asks Launch Services to open the package in Resolve. Opening a document
  through Launch Services is what grants the sandboxed Resolve access to it, so no app
  group or scheme is needed. Resolve's `SourceFitImporter` rebuilds the `FitDataset`
  from any averaged MFF (EVA handoff, Finder, or File ▸ Open — one code path).
  Round-trip covered by `SourceFitImporterTests`.
- [x] Generated recordings from the simulator open in EVA via Launch Services (falls
  back to the default `.mff` handler).
- [x] `EVAApp.swift` no longer has the Source Simulator scene, controller, or menu
  item. "Fit Source Model" reports "EVA Resolve is not installed" in the status log
  when Launch Services cannot find the bundle ID.
- [ ] Help: no Source Simulator help page existed in EVA's help book, so nothing to
  move; write Resolve's help when the UI settles.

Exit criterion met: EVA builds with no reference to `SourceSimulator*` or
`SingleDipoleFit`; `EVAResolveTests` (simulator + importer) pass.

---


## R2 — Head frame, NIfTI in core, and electrode coregistration  *(R2.1–R2.3 done 2026-09-02; R2.4 UI pending)*

Everything in R3–R6 needs one coordinate frame, a volume reader in core, and a way to put
the electrodes on a head. Built once, in `EVACore/`, validated against nibabel and
MNE-Python from the `mne` micromamba env (`Tools/resolve-validate/`).

**Units and frames (decided):** geometry is in **metres** everywhere in `EVACore/`
(forward models, `HeadTransform`, `ElectrodePositions`, meshes), matching MNE. `NIfTIVolume`
keeps its affine in millimetres (NIfTI-native) and exposes `voxelToWorldMeters`.
`CoordinateFrame` uses the FIFF numbering (head = 4, mri = 5, …) so transforms round-trip
to MNE without translation.

### R2.1 Volume and surface IO into `EVACore/`  — done
- [x] `NIfTIHeader`, `NIfTIByteSource`, `NIfTIScalarDecoder` moved from `EVAPreviewKit/` to
  `EVACore/IO/NIfTI/`; GIFTI model, reader and companion resolver to `EVACore/IO/GIFTI/`.
  `EVACore` is now also attached to `EVAQuickLook` / `EVAThumbnail`; `EVAPreviewKit` is
  attached to `EVA` (it declares the NIfTI/GIFTI document types) and dropped from
  `EVATests`, whose reader tests reach the code through the host app.
- [x] `NIfTIVolume`: whole-volume load (first 3-D volume, slope/intercept applied, fast
  paths for float32/int16/uint16/uint8), voxel↔world, trilinear sampling, **RAS
  canonicalization** without resampling, NIfTI-1 writer (float32/int16/uint8, sform +
  qform, gzip). Tests: nibabel-generated RAS / LAS / PIR / qform-only-int16 phantoms with a
  left-marker cube all canonicalize to the same voxels and world positions; write→read
  round trip; nibabel reads what we write (`check_swift_nifti.py`).
- [x] `VolumeMorphology`: `BinaryVolume` (ball dilate/erode, open/close, 6/26 connected
  components, largest component, hole fill, surface voxels, centroid/bbox) and `VolumeOps`
  (thresholds, Otsu, separable Gaussian, isotropic resampling).
- [x] `HeadTransform` + `CoordinateFrame` + `SVD3`: Umeyama/Kabsch fit (rigid or
  similarity) matching MNE `fit_matched_points` to 1e-6 (rigid) and to the optimizer's
  1e-5 (scale; our closed form has the lower residual). Rank-2 (three fiducials) handled
  exactly.

### R2.2 Electrode positions with fiducials  — done
- [x] `ElectrodePositions` (metres; EEG / reference / nasion / LPA / RPA / head-shape
  points) with readers for EGI `coordinates.xml` (cm; fiducials by identifier 2002/2011/2010
  — `EGISensorXMLParser` now keeps `<identifier>`), BESA `.sfp`, ASA `.elc`, Cartool `.xyz`,
  CSV/TSV/TXT; unit auto-detection; fiducial aliases across conventions. Validated against
  MNE `read_custom_montage` on the same files for every format.
- [x] `HeadTransform.headFrame(nasion:lpa:rpa:)` = MNE `get_ras_to_neuromag_trans`
  (matches to 1e-9); `ElectrodePositions.inHeadFrame()`.
- [x] `toGeometry()` / `toMontage()` feed the existing spherical forward models.
- [x] Bundled templates: idealized spherical 10-20 / 10-10 / 10-05 (`StandardMontage`,
  generated from eeg_positions data via MNE, BSD-3, `export_montages.py`). EGI HydroCel
  nets are deliberately not bundled — every MFF carries `coordinates.xml`.

### R2.3 Coregistration engine and MNE interop  — done
- [x] `TriangleMesh` (normals, area/volume, icosphere) and `SurfaceIndex` (uniform-grid
  exact closest point, verified against brute force).
- [x] `SurfaceRegistration`: fiducial alignment → ICP to the scalp surface (rigid or
  similarity, trimming, distance cap), projection onto the surface, and
  `fitTemplateScalp` for the no-MRI path (recovers an 8 % head-size change to <1 %).
  With fiducials the pose is recovered to <1 mm on the fsaverage scalp; blind ICP from
  a centroid start lands points on the scalp but, as expected, cannot pin rotation on a
  symmetric head.
- [x] **MNE FIF interop** (`EVACore/IO/FIF/`): tag reader/writer; `-trans.fif` read/write
  (`HeadTransform`), fiducials / `-dig.fif` read/write (`Digitization`,
  `ElectrodePositions`), `-bem.fif` / `-head.fif` read/write (`BEMSurface`). fsaverage
  trans, fiducials, head and 3-shell BEM read identically to MNE; MNE reads our trans,
  dig and BEM files and `make_bem_solution` accepts our surfaces (`check_swift_fif.py`).

Validation workflow: `Tools/resolve-validate/make_fixtures.py` (MNE env) regenerates
`EVATests/Fixtures/Resolve/` and copies fsaverage surfaces into the git-ignored
`Fixtures/Resolve/local/` (the sandboxed test host cannot read `~/Desktop`, where MNE
keeps its data). After the Swift tests, `check_swift_nifti.py` and `check_swift_fif.py`
read the Swift-written files back with nibabel / MNE.


### R2.4 Coregistration UI (Resolve) — first pass built 2026-09-02

The UI brainstorm and the package/document follow-ups are open — see
`ROADMAP.md` § Source & Forward Modeling.

- [x] `HeadModelController` (`EVAResolve/HeadModel/`): T1 load (canonicalized) with a
  quick **star-shaped scalp** from the head mask (`ScalpFromVolume`, a stand-in until
  R3's marching cubes), scalp from MNE `-head.fif` / GIFTI, fiducials by clicking or from
  `-fiducials.fif`, electrodes from any `ElectrodePositions` format / MNE dig / template
  montage, fiducial alignment + ICP (scale optional, trimming), nudge (rotate / move /
  scale about the electrode centroid), refine-from-pose, snap-to-scalp, MNE exports.
- [x] `MRISliceView`: three orthogonal planes (canonical volume, anatomical-positive
  up, labelled L/R/A/P/S/I), click-to-pick fiducials, scalp contour, electrodes near the
  plane coloured by residual, brightness slider.
- [x] `CoregistrationSceneView`: SceneKit scalp (translucent) + electrode spheres
  coloured by residual + fiducials + RAS axes, orbit camera.
- [x] `HeadModelWindowView`: 2×2 viewports (axial, coronal, sagittal, 3-D) plus a
  five-step inspector (MRI → Fiducials → Electrodes → Fit → Save/Export). File ▸ New
  Head Model (⇧⌘H) in `EVAResolveApp`.
- [x] **`.evahead` package** (`HeadModelDocument`): `manifest.json`, `t1.nii.gz`,
  `scalp-head.fif`, `electrodes-dig.fif`, `head-mri-trans.fif` — every piece in a format
  MNE reads directly. Save / open round-trips through the controller.
- [x] End-to-end test on fsaverage (`HeadModelControllerTests`): T1 → scalp within a few
  mm of MNE's watershed head above the ears; fiducials + scaled 10-10 template fit;
  snap; nudge/refine; package round trip.

## R3 — BEM head models imported from MNE / OpenMEEG *(R3.1 done 2026-09-06)*

Rationale and the licensing boundary: [`docs/design/head-models.md`](docs/design/head-models.md).
R3.2 onward is open — see `ROADMAP.md` § Source & Forward Modeling.

### R3.1 Import the geometry (surfaces + conductivities)  *(done 2026-09-06)*

- [x] MNE `-bem.fif` / `-head.fif` surfaces (`BEMSurface.readFIF`, R2.3) — already read
  and written, fsaverage-validated.
- [x] `BEMGeometry` (`EVACore/Core/Forward/BEMGeometry.swift`): shells stored
  **inner → outer** whatever the file's order, one `CoordinateFrame`, and `Provenance`
  (source file, format, solver, approximation, subject, note). Reads from every file
  MNE writes surfaces into — geometry-only `-bem.fif`, `-head.fif`, and either
  solver's `-bem-sol.fif` — and writes back in MNE's outer-first order.
- [x] OpenMEEG native geometry (`EVACore/IO/OpenMEEG/OpenMEEGGeometry.swift`): `.geom`
  + `.cond` with `.tri`, `.off` and `.bnd` meshes, read and written. Conductivities are
  resolved through OpenMEEG's **signed** domain bounds (`-Interface` = the domain
  inside it), not by name matching — an interface bounds two domains and only one of
  them is the sigma FIF means.
- [x] **OpenMEEG's `.tri` winding is the reverse of MNE's**, established by experiment,
  not documentation: hand it a mesh wound MNE's way and it announces "Global
  reorientation of interface …" and assembles a head matrix ~3e-4 different. The
  per-vertex normals in the file are ignored; only the winding is read. EVA writes the
  reversed winding and normalizes anything it reads back to outward normals.
- [x] Quality gates, as a list of pass/warning/failure `Check`s the UI can show, never
  a silent pass: closed and manifold (every edge in exactly two triangles), genus 0
  (Euler characteristic), outward normals (signed volume), nesting inner ⊂ outer with a
  2 mm separation warning, self-intersection (grid-accelerated Möller triangle pairs,
  `EVACore/Geometry/TriangleMeshIntersection.swift`), conductivity positivity and skull
  ordering, plausible compartment volumes (which is what catches millimetre input).
- [x] Validated both directions: 14 tests in `EVATests/IO/BEMImportTests.swift` covering
  the three FIF variants, each gate against a deliberately broken model, the OpenMEEG
  round trip and all three mesh formats — and
  `Tools/forward-compare/check_swift_openmeeg.py`, which loads what EVA wrote with
  **OpenMEEG itself**: `selfCheck` and `is_nested` pass, `om.HeadMat` assembles
  1126×1126, no reorientation.
- [ ] fsaverage at ico2 legitimately trips the separation warning (outer skull within
  1.5 mm of the scalp). Right answer, but the threshold wants a look against real ico4
  models before the UI shows it to anyone.


## R5.0 — Fit-mode UI, built 2026-09-05

The layout brainstorm that preceded it, and its three open questions, are in
`ROADMAP.md` § Source & Forward Modeling.

**Built:** the Workbench layout in both modes (2+1 head grid: axial + coronal above,
sagittal below), anatomical head silhouettes (`EVAResolve/Simulator/HeadSilhouette.swift`
— outline, ear arcs and neck in box space, with a per-plane `Layout` that seats the
brain sphere in the cranium so the neck can hang below), drag-to-seed-then-refit
(optional `seeds:` on `fitSharedGeometry`), an explicit **Fit button** with a
determinate progress bar, verbose per-phase messages and cancellation
(`SingleDipoleFit.ProgressReporter`, threaded into the chunked `covarianceSearch`),
a resizable timeline splitter in Simulate, and the three waveform panels below.

**Waveform panels (right column).** Measured butterfly → **source waveforms** (each
dipole's moment over time, conditions overlaid) → **residual components**. The residual
PCA is deliberately computed on the *unexplained* field: `SingleDipoleFit.decompose`
projects the data through the fitted lead field, subtracts the modelled field, and
eigendecomposes what is left, reporting each component's share of the ORIGINAL variance.
So placing dipoles that explain the highlighted interval makes those components shrink,
and whatever remains is structure still to be modelled. Covered by
`decompositionTracksUnexplainedVariance` (3 dipoles explain >95% of the noiseless demo
field; 1 dipole leaves strictly more residual).

Still open: no residual-component *topography* is drawn yet (the data is computed);
`fitSeedPositions` is view-agnostic but only Fit mode drags it.

## Source Simulator — SIM-0, SIM-1, and Stages 1–3c

### The Source Simulator window (SIM-2 + SIM-3 home)

Stages 1, 2, 3a, 3b and 3c shipped; 3c-perf is mostly shipped. Stage 4
(SceneKit tier-A glass brain) is deferred — see `ROADMAP.md` § Source &
Forward Modeling.


SIM-2 and SIM-3 are two halves of one interactive tool — SIM-3 is SIM-2's
viewport — so they ship together in **their own dedicated window, "Source
Simulator"** (File ▸ New ▸ Source Simulator), *not* as another mode inside the
Simulator Studio. Rationale: the Studio's Generate/Score modes are form-and-file
work that drives the bundled CLI; the Source Simulator is a live, spatial,
direct-manipulation tool with a fundamentally different interaction paradigm and
its own persistent state (sources, positions, time courses, the live field). It
mirrors the Studio's scaffolding — a single-instance `Window(id:)` scene owning a
`SourceSimulatorController`, opened from a `File ▸ New` menu command — but is a
separate window, as the owner suggested (2026-08-29).

**Crucial architectural point:** unlike SIM-1/Score, this window does **not**
shell out to the CLI. It calls the in-module forward solver
(`SphericalForwardModel.leadField(head:montage:sources:reference:terms:)`, which
returns a µV/(nA·m) matrix) **directly, in-process**, so dragging a dipole
recomputes the scalp field with no file round-trip. This is exactly the payoff
SIM-0 unlocked by moving the generation/forward core into the app module.

Reused building blocks (all in-module): `ForwardDipole` / `SimulatedSource`
(`EVA/Core/Forward/ForwardTypes.swift`), the analytic-sphere / ellipsoid / BEM
solvers, `Montage.forwardElectrodes(head:)`, `SensorLayout` + an existing topomap
renderer (e.g. `TopoFilmstripView`'s scalp interpolation) for the live field, the
head-model picker already built for Generate, and the BEM icosphere mesh for the
head/brain outline. Mind the shared MFF/SensorLayout y-flip when projecting.

**Layout:** a split view — left, the glass-brain viewport (SIM-3); right, the live
scalp topomap plus a source inspector (position, orientation, moment, time
course); a source list with add/remove, and (stage 2+) a time-course editor and
timeline scrubber.


### SIM-0 — Link EVASimulate into the app — **COMPLETED (2026-08-29)**

The prerequisite for everything else, and the one real refactor. Previously
EVASimulate built via `Tools/EVASimulate/build.sh` — a standalone `swiftc`
file list — and was **not** linked into the EVA app target, so the app could not
call the generation path. The simulator is now callable from the GUI's own module
**and** ships as a bundled CLI at `EVA.app/Contents/MacOS/EVASimulate`, with
`build.sh` retired and the self-test running under `xcodebuild test`.

### What shipped (2026-08-29 execution)

Key discovery: `EVA.xcodeproj` is a modern Xcode-26 project using **file-system-
synchronized groups**, not classic per-file target membership. That reshaped the
plan below but confirmed its direction.

- **Generation core moved into `EVA/Simulation/`** (19 files) so it auto-compiles
  into the app module — the GUI (SIM-1) can now call the generators/scenario/
  forward directly, no import, no `public`. Two shared truth/error types
  (`SimulateError`, `ERPComponent`/`ERPComponentSet`) were extracted into their
  own core files (`SimulationError.swift`, `ERPTruth.swift`) because they are used
  by core generators but were declared in CLI-side files. The 9 CLI/eval-side glue
  files (`main`, `SelfTest`, `SNRMetrics`, `RichMetrics`, `SourceMetrics`,
  `ERPEvaluation`, `SI0ContractFixtures`, `SimulationWriter`, `SurrogateSeparation`)
  stayed out of the app; two of them (`SNRMetrics`, `SurrogateBrainModel`) collide
  by name with EVA types, which is exactly why they must not join the app module.
- **`EVASimulate` command-line-tool target added to `EVA.xcodeproj`.** Because a
  sync root group is all-or-nothing per target, the CLI cannot "include just the
  17 shared EVA files" by membership; it **duplicate-compiles** the exact 47-file
  closure (glue + core + 17 shared) via a classic Sources phase with explicit file
  references — mirroring what `build.sh` did, and honoring the no-public-API
  constraint. Builds green; self-test 107/107 (106 at SIM-0; +1 from SI-4 Track 1).
- **CLI embedded in the app bundle** via a Copy Files phase (dstSubfolderSpec 6 →
  `Contents/MacOS`), with an app→CLI target dependency. The embedded binary is
  codesigned (team 7V8RRF84QH, hardened runtime) and runs.
- **Self-test reachable from `EVATests`** as a subprocess wrapper
  (`EVATests/Simulation/EVASimulateSelfTestTests.swift`) that execs the bundled
  `EVASimulate selftest` and asserts zero failures — the in-process option was
  rejected because `SelfTest`'s `SNRMetrics`/`SurrogateBrainModel` would shadow
  EVA's own types that existing tests depend on. `xcodebuild test` passes (137s;
  it *is* the determinism corpus).
- **`build.sh` retired.** `run-all-tests.sh` and `scripts/check-determinism.sh`
  now build the `EVASimulate` Release target via `xcodebuild` and stage the product
  at `Tools/EVASimulate/.build/eva-simulate`; determinism still matches the
  committed baseline byte-for-byte (8/8 scenarios). Docs updated.

### What we learned (2026-08-29 planning pass)

- **The shared foundation is bounded to 17 EVA files** — exactly what `build.sh`
  compiles alongside the simulator: `Core/Forward/{ForwardTypes, Spherical,
  Ellipsoidal, BEM}ForwardModel`, `Core/{AccelerateCompat, DSP, LinearAlgebra,
  SeededGenerator}`, `Artifacts/SourceInformed/SourceInformedOperator`,
  `Channels/{ElectrodeGeometry, SensorLayout}`, `IO/{EGISensorXMLParser,
  MFFFileType, MFFReader, MFFWriter}`, `Epoching/EpochModel`,
  `Pipeline/EVAProcessingScript`. This is the CLI's full transitive closure
  (that list builds and passes 107 self-test checks today).
- **Those files are woven into the app**: `SensorLayout` is used in ~34 files,
  `EVAProcessingScript` ~20, `ElectrodeGeometry` ~15, `LinearAlgebra` ~12,
  `DSP` ~10, `ForwardHeadModel` ~8. So a package boundary makes their API a
  public surface to maintain.
- **The simulator's *core* (generators, scenario, forward) is clean** — it does
  NOT touch the app-coupled types. Only `Montage`, `SimulationWriter`,
  `ImpedanceModel`, `SelfTest`, and `main.swift` reach `SensorLayout` / MFF I/O,
  and that is coordinate-file reading + MFF writing (CLI-ish glue), not the
  math.

### Chosen approach (owner, 2026-08-29): simulator lives in EVA, CLI built from it

Rather than a separate SwiftPM package, **move the simulator sources into the
EVA structure and build the CLI as a second target from what already exists in
EVA.** This avoids inverting the dependency (the simulator already depends on
EVA core, not the other way round) and needs no public-API pass.

- [x] **Bring the generation core into the EVA target's source tree** at
  `EVA/Simulation/` (19 files + 2 extracted shared types), so the app compiles the
  generators/scenario/forward and the GUI (SIM-1) can call them directly — no
  import, no `public`, same module. CLI-only glue stayed out of the app.
- [x] **Add an `EVASimulate` command-line-tool target** to `EVA.xcodeproj`. Under
  the sync-group model, membership is an explicit Sources phase duplicate-compiling
  the exact 47-file closure (glue + core + 17 shared). `main.swift` stays the CLI
  entry point (it cannot live under `EVA/` — top-level code vs the app's `@main`).
- [x] **Embed the CLI in the app bundle**: a Copy Files build phase
  (dstSubfolderSpec 6 → `Contents/MacOS/`) copies the `EVASimulate` product, with
  an app→CLI target dependency. Confirmed a plain codesigned executable (not a
  nested `.app`), hardened runtime, team 7V8RRF84QH.
- [x] **Retire `build.sh`** — done; `run-all-tests.sh` and `check-determinism.sh`
  reroute to the `xcodebuild` Release product.
- [x] **Migrate the self-test**: reachable as the CLI `selftest` subcommand *and*
  from `EVATests` via a subprocess wrapper (execs the bundled CLI, `#expect`s zero
  failures). The in-process `SelfTest.run()` wrapper was rejected — its
  `SNRMetrics`/`SurrogateBrainModel` shadow EVA types that existing tests use.

### Alternative kept on record: full `EVASimulationKit` SwiftPM package

The cleaner-in-principle option (one source of truth, CLI as a thin driver).
Feasible because the closure is only 17 files, and app *import* churn is
avoidable with a single `@_exported import EVASimulationKit` in one app file.
Cost that made the owner prefer the in-EVA path: a public-API pass over MFF I/O
/ `SensorLayout` / `DSP` / `LinearAlgebra`, plus hand-wiring the local-package
dependency in `EVA.xcodeproj`. Revisit only if the app itself later wants to be
split into a core package for other reasons.

### Resolved during execution

- **Group layout:** one flat `EVA/Simulation/` folder (the sync group compiles it
  into the app automatically); no mirror of the old file grouping was needed.
- **Duplicate-compile vs static lib:** duplicate-compile won, forced by the
  sync-group model (a root group is all-or-nothing per target, so "just the 17
  shared files" cannot be a second target's membership) and by the no-public-API
  constraint. A static lib would reintroduce the `import` pass that was rejected.
- **Codesigning:** the embedded CLI is codesigned by the normal build (automatic
  signing, team 7V8RRF84QH, hardened runtime). Notarization is a release-time
  concern, not a build-time one, and is inherited from the app's flow.

**Exit — met:** EVA compiles the generation core in its own module (in-memory
generation is a direct call for SIM-1); the CLI is a bundled, codesigned
executable at `EVA.app/Contents/MacOS/EVASimulate`; `xcodebuild test` runs the
107-check corpus (via the CLI subprocess wrapper); `build.sh` is gone.


### Simulator UI — per-band background amplitudes

- [x] **Per-band background amplitudes** — shipped in SIM-1 (2026-08-30): the Studio's
  **Background** tab exposes the alpha envelope and per-band σ for δ / θ / β / γ. The
  Source Simulator's own background spectrum could reuse this later if wanted.

### SIM-1 — New → Simulated Recording panel — **COMPLETED (2026-08-30)**

A dedicated panel modeled directly on Batch Process. The batch scaffolding was
the template: a `Window(id:)` scene (`BatchWindowView`) opened from a menu
command (`OpenBatchWindowButton`) that owns a controller (`BatchController`) and
shows a setup sheet (`BatchSetupSheet`) on first open. Mirrored:

- [x] **`SimulatorWindowView`** — a `Window(id:)` scene registered in
  `EVAApp.swift`, opened from **File ▸ New ▸ Simulated Recording**
  (`OpenSimulatorWindowButton`, ⇧⌘N), owning a `SimulatorController`. Single-
  instance like Batch; setup sheet on first appearance, then a
  generating/done/failed view.
- [x] **`SimulatorSetupSheet`** — exposes the high-value knobs (channels,
  duration, rate, seed, and BCG / gradient / blink / EMG toggles) rather than all
  40+ CLI flags, binding straight to an in-module `SimulationConfig`
  (`SimulationConfig.default` as the starting point).
- [x] **Generate** runs off the main thread via `SimulatorRunner` and opens the
  contaminated `.mff` as an ordinary recording (`PendingWindowOpens` +
  `openWindow("main")`). The clean recording and `_truth.json` sidecar are written
  alongside. **How it works:** the GUI serializes its `SimulationConfig` to a
  scenario JSON with the in-module `SimulationScenarioFile.write`, then drives the
  bundled `EVASimulate generate` (SIM-0's embedded CLI) — round-trip parity, and
  the write path reuses the CLI's `SimulationWriter` rather than duplicating MFF
  serialization in the app. Verified end-to-end by `SimulatorRunnerTests` (runs in
  the sandboxed app host: locates the CLI, generates, deterministic by seed).
- [x] Drives a full `SimulationConfig` directly (superset of "existing scenarios
  and presets").
- [x] **Studio window (v2, 2026-08-29):** enlarged window with a top **mode
  selector** (Generate implemented; Score / Sweep / Group are visible-but-inert
  placeholders the shell makes room for), and Generate is a **tabbed inspector**
  (`SimulatorGenerateView`): Recording · Sources & Head · Gradient · Cardiac ·
  Ocular · Muscle & Other · ERP · Defects · Output — curated high/medium-value
  knobs per tab, with a persistent bottom bar (seed · summary · Generate) and a
  status strip. The whole config still round-trips, so unsurfaced fields keep
  their defaults.
- [x] **Output directory** picker (Output tab) + filename prefix + "open after".
  Sandbox-safe: the CLI always writes into a container-temp dir (a child cannot
  inherit the app's scoped access to a chosen folder), then the app copies the
  results into the chosen directory.
- [x] **Command provenance:** each run writes `<prefix>_command.json` (exact argv
  + copy-pasteable command line + timestamp/app version) and `<prefix>_scenario.json`
  alongside the recordings, so both the inputs and the invocation are on disk.

- [x] **Score mode (2026-08-29):** the generate → clean → score loop, in-window.
  Pick a ground-truth `_clean.mff`, the corrected recording (cleaned + exported
  from EVA), and optionally the uncorrected `_noisy.mff` baseline; runs
  `EVASimulate score --json`, decodes `CorrectionScore` into app-side DTOs, and
  shows broadband metrics (corrected vs uncorrected) + a per-band table.
  Sandbox-safe: inputs are staged into container-temp (the CLI child can't read
  user-picked packages outside the container), then scored. "Fill truth & baseline
  from last generation" wires the two modes together. Verified by two Score tests
  (identical → correlation > 0.99; noisy-vs-clean → populated bands/channels).

**Core shipped:** a person picks knobs across the Generate tabs, chooses an output
folder, clicks Generate, a simulated recording opens and flows through the normal
pipeline, and they can Score their cleaning against ground truth — all without
leaving EVA.

**Remaining pieces — all shipped 2026-08-30:**

- [x] **Sweep mode** — a Studio mode that varies one of the CLI's 10 sweepable
  parameters across comma-separated values off the current Generate config, runs
  `EVASimulate sweep`, and shows `sweep_summary.csv` as a value → uncorrected-SNR
  table with per-run Open. (`SimulatorSweepView`, `SimulatorRunner.sweep`.)
- [x] **Group mode** — a Studio mode: subject count, group seed, homogeneous or
  seven between-subject SD sliders; runs `EVASimulate generate-group` and lists the
  `sub-<label>` subjects + the participants TSV. (`SimulatorGroupView`,
  `SimulatorRunner.generateGroup`.)
- [x] **Scenario-preset picker** — the 8 `Tools/EVASimulate/scenarios/*.json` are
  bundled into the app as a **folder reference** (single source of truth with the
  CLI) and offered as a "Load a preset…" menu at the top of Generate that replaces
  the current config. (`SimulatorScenarioLibrary`.)
- [x] **Per-band amplitudes** — a **Background** tab exposes the alpha envelope and
  a per-band σ for δ / θ / β / γ (`eegBands[i].amplitudeMicrovolts`) plus the global
  target σ. **Coordinate/montage import** — a coordinates.xml / MFF picker (staged
  into the run's temp dir for the sandboxed child) plus a montage-jitter knob, in
  Sources & Head. (Named built-in nets — HydroCel 64/128/256 — remain deferred to
  SI-4, per owner 2026-08-30.)

All four are verified in `SimulatorRunnerTests` (sweep runs, group subjects, preset
library loads) from the sandboxed host. Interactive source placement / a live field
is deliberately **not** part of SIM-1 — that is the Source Simulator window below.


### Stage 1 — SIM-3 tier B + SIM-2 static field — **SHIPPED 2026-08-29**

The fastest visible win and the single most useful teaching object; shipped first.

- [x] `SourceSimulatorController` (`@Observable`) + `SourceSimulatorWindowView` +
  the `File ▸ New ▸ New Source Simulator…` command and single-instance `Window`
  scene (mirrors the Studio scaffolding).
- [x] **Glass-brain viewport (tier B):** three orthographic projections (axial /
  coronal / sagittal) in SwiftUI `Canvas` (`HeadProjectionView`), scalp + brain
  shell outlines from the sphere radii, each source a dot + orientation arrow at
  its projected position, drag to move within a plane's two axes (the third is
  held; a source is clamped inside the brain shell). Laid out 2×2 with the field.
- [x] **Live forward field:** `SourceSimulatorController.scalpPotentials()` builds
  the lead field **in-process** via `SphericalForwardModel.leadField(...)` (60
  harmonic terms for responsiveness) and multiplies by each source's moment; a
  compact IDW topomap (`ScalpFieldView`) redraws as sources move. Inspector:
  moment slider, orientation quick-sets (radial/X/Y/Z), head-model (3/4-shell),
  channel count (19/32/64/128), reference.
- [x] **In-canvas orientation:** ⌥-drag grabs a dipole's arrow and aims it. Each
  projection rotates about its own normal axis (axial→z, coronal→y, sagittal→x),
  preserving the out-of-plane tilt, so the three views together point anywhere.
  Move vs rotate is chosen from `NSEvent.modifierFlags` at grab time.
- Verified by `SourceSimulatorControllerTests` (field exists + spatially varies,
  average-ref zero-sums, moving changes the field, brain-clamp keeps the solver
  valid, ⌥-rotation aims in-plane while staying unit length).
- [x] **Glass-brain surface:** the projections draw a faint BEM-icosphere
  wireframe (`BEMForwardModel.icosphere(subdivisions: 1)`, cached once) behind a
  crisp boundary circle; both layers toggle independently in the inspector. Channel
  counts now include **256**.
- [ ] **Deferred within Stage 1:** ellipsoid/BEM in the field picker (3/4-shell
  only so far), and a true anatomical (MRI-backed) silhouette — the sphere/icosphere
  is correct for the parametric heads.

**Stage-1 exit — met:** a dipole can be placed/dragged in the glass brain and its
scalp topography read off live, entirely in-process.

### Stage 2 — SIM-2 time courses and scalp EEG — **SHIPPED 2026-08-30**

- [x] **Per-source time-course editor:** a `TimeCourse` per source — constant,
  sine (frequency), ERP bump (Gaussian: latency + width), pulse (onset + length),
  and seeded coloured noise — edited in the inspector; the moment slider is the
  peak amplitude the course modulates.
- [x] **Timeline + animation:** a transport (play/pause) + scrubber over the epoch
  (duration × rate); a 30 fps tick advances `currentTime`, and the scalp field is
  shown at that instant. Fast because the lead matrix and the per-source series are
  cached (keyed by geometry / by moments+courses+duration+rate), so a playback
  frame is a matrix-vector product, not a fresh solve.
- [x] **"Generate scalp EEG":** assembles the full channels × samples recording
  (lead field × source series) and writes it as an MFF **entirely in-process** via
  the app's own `MFFWriter` + `MontageWriter.writeLayoutFiles` (coordinates
  included), then opens it as an ordinary recording — no CLI, no scenario file. It
  flows through EVA's pipeline and can be exported and fed to the Studio's Score
  mode. Verified by `SourceSimulatorControllerTests` (sine field varies / is flat
  at t=0, ERP peaks at its latency, and the written MFF reads back with the right
  dimensions and a loadable topomap layout).

### Stage 3a — Activation timeline — **SHIPPED 2026-08-30**

Time is authored as a list of *activations* per dipole rather than one continuous
course: a dipole is silent except during its activations, and can have any number
at any times — so "a new time with new and/or old dipoles" is just later activations
on new or existing dipoles (a dipole reused = a later activation; a new dipole = a
new object starting later).

- [x] **Model:** `Source.activations: [Activation]`; each `Activation` is a windowed
  waveform — hold / sine / ERP bump (Gaussian centred in the window) / seeded noise —
  with a **variable per-activation amplitude** (negative allowed, for polarity),
  start, and length. A dipole's moment series is the sum of its activations; the
  default dipole gets one full-epoch hold so static placement still shows a field.
- [x] **Multi-track timeline** (`SourceTimelineView`): one row per dipole, each
  activation a draggable/resizable block (drag to move, right-edge to resize, click
  to select); a red playhead scrubs the live field; **Play** watches the whole scene
  evolve; add/remove activation; a per-activation editor in the inspector.
- [x] Verified by `SourceSimulatorControllerTests` (activations fire only inside
  their window, the sine field is flat at t=0 and varies at peak, the ERP peaks at
  the window centre, and the generated MFF still reads back correctly).

### Stage 3b — Noise + truth-backed scoring (the EVA differentiator) — **SHIPPED 2026-08-30**

The clean field is known exactly at every instant, so noise and scoring stay honest
and need no inverse solver (distributed source imaging remains EVA Resolve's job).
New files: `EVA/Simulation/SourceSimulatorNoise.swift` (white/pink + SNR scaling +
scoring math), `EVA/Simulation/SourceSimulatorArtifacts.swift` (reuses the in-module
Ocular/EMG/BCG generators with the parametric montage, keeps timing truth).
Controller gained clean/noisy/contamination matrices, live + whole-recording scores,
and a truth sidecar; inspector gained a Noise & artifacts section with a live
SNR/correlation-vs-truth readout. 18/18 Source Simulator tests green.

- [x] **Noise model — white + pink** at a target SNR (`SourceSimulatorNoise
  .noiseMatrix` scales the background so whole-recording SNR equals the requested
  dB, exact to fp; deterministic in seed). Further noise models
  worth adding later, roughly by value:
  - **Measured-EEG background** — resample real resting EEG (or match its spectrum) so
    the background carries a physiological 1/f + alpha shape, not synthetic colour.
  - **Spatially-correlated noise** — a realistic channel covariance (e.g. the field of
    many shallow random sources) so noise is *not* independent per electrode; this is
    what actually challenges spatial filters (PCA-S/ICA/SSP).
  - **Per-band noise** — dial noise power per band (δ/θ/α/β/γ).
  - **Sensor faults** — per-channel drift, pops, high-impedance hiss, a bad-reference
    offset (sensor-space, not physiological).
- [x] **Physiological artifacts as an option under noise** — blink / saccade / EMG /
  BCG injected on top of the clean field via the in-module generators
  (`OcularArtifactModel` / `EMGArtifactModel` / `BCGArtifactModel`, driven by the
  parametric `Montage`), each keeping its timing truth in the sidecar. (Gradient
  is available in-module too but omitted — it's an fMRI-scanner artifact, not a
  general contamination.)
- [x] **Scoring:** on Generate, when contamination is on, writes `source_sim_clean
  .mff` + `source_sim_noisy.mff` + `source_sim_truth.json` (dipole positions/
  orientations/activations, noise settings, artifact timing, overall SNR/corr) —
  ready to hand to the Studio's **Score** mode (noisy vs the clean truth). A live
  SNR/correlation-vs-truth readout (current sample + whole recording) updates as
  you scrub, and a "Show noisy field" toggle overlays the contamination on the
  topomap while the clean field stays the scoring truth.

### Stage 3c — Single-dipole-fit localization diagnostic — **SHIPPED 2026-08-30**

The BESA-adjacent source-space check, after 3a/3b: fit one equivalent dipole to the
field at the playhead (nonlinear position, linear moment) and report localization
error (mm) and orientation error (deg) vs the true active dipole. A classic bounded
inverse used purely as a validation diagnostic — explicitly *not* distributed
imaging, so it stays on the right side of the EVA Resolve boundary.

- [x] **Solver** (`EVA/Simulation/SingleDipoleFit.swift`): one ECD, nonlinear in
  position / linear in moment. A coarse grid inside the brain shell, then several
  local refinements, each a *single batched* `SphericalForwardModel.leadField`
  call over all its candidates — so the whole search costs a handful of
  spherical-harmonic setups, not one per position. The moment is solved in closed
  form from the free-orientation (x/y/z) columns that call already keeps
  (normal equations, tiny Tikhonov diagonal for near-degenerate deep/central
  points). Reports goodness-of-fit and RMS residual alongside position/moment.
- [x] **Controller hook** (`liveLocalization()`): fits the *displayed* field, so
  the "Show noisy field" toggle drives clean-field recovery (~0 mm) vs how
  contamination degrades it; compares to the dominant instantaneous source
  (single-ECD fitting genuinely degrades under simultaneous sources, and comparing
  to the dominant one keeps the error honest). Cached by geometry + playhead +
  contamination signature so re-renders and playback are cheap. Orientation error
  folds the dipole's sign ambiguity.
- [x] **Multiple dipoles (one per placed source)**: `fitMultiple` fits K = the
  number of sources the user has placed — sequential deflation for an initial
  guess, then **joint coordinate descent on the true joint objective** (each
  candidate position re-solves *all* moments and scores the full field), then a
  closing joint moment re-solve. Scoring the joint residual (not the peeled
  `b − others`) is what recovers well-separated sources to a few mm rather than the
  ~1.5 cm compromise plain peeling settles into. Each fitted dipole is paired
  one-to-one to its nearest true source. This is still not a global simultaneous
  optimizer — close/synchronous/noisy sources can converge to a swapped or merged
  configuration, which the diagnostic surfaces rather than hides.
- [x] **Spatiotemporal (interval) fit + SVD model order — the Scherg/Berg method.**
  A single instantaneous topography is one spatial vector, so it cannot separate
  simultaneous sources; a time *interval* can, if the sources have distinct time
  courses (the data is then rank ≥ 2). `fitSpatioTemporal` fits over an interval by
  reducing everything to the channels×channels covariance `C = data·dataᵀ` — the
  residual of a dipole set with free per-sample moments is
  `trace(C) − trace((LᵀL)⁻¹ LᵀC L)`, so positions come from the same deflation +
  joint-objective coordinate descent scored on `C`, and per-dipole
  orientation/RMS-magnitude come from the moment covariance `G⁻¹(LᵀC L)G⁻¹` — all
  at the same cost as the instantaneous fit. The **eigenvalues of `C`** give the
  variance spectrum = the model-order picture ("how many dipoles the data
  supports"). A **fit-mode toggle** (Instant / Interval) chooses per-instant vs
  interval; interval is the default.
- [x] **Butterfly plot + interval selection** (`SourceButterflyView`): all channels
  of the produced field overlaid vs time, with a playhead and drag-to-select a
  time window (click clears → whole epoch). The selection is what the interval fit
  runs over. Shown in the Source Simulator window when the interval fit is active.
- [x] **Glass-brain overlay + right-click**: right-click any of the three
  projections → "Fit Dipoles at Playhead" draws each fitted dipole as a purple
  diamond with an orientation arrow, and a dashed error line to its paired true
  source, so the localization error is visible in the views — not only a number.
  The inspector shows per-dipole mm/deg errors and, for an interval fit, a small
  **SVD spectrum sparkline** (bars beyond the dipole count drawn faint, so an
  over-/under-specified model is visible). The fit runs off the main thread with a
  "Fitting…" spinner and a generation guard so a fast change never lands a stale
  result.
- [x] **Inspector readout**: a "Localization diagnostic" section — a show/hide
  toggle and a live GOF / magnitude / position-error-mm / orientation-error-deg
  readout, labelled clean vs noisy.

**Real-data source-analysis mode (built on 3c, EVA Resolve is now part of EVA):**

- [x] **Simulate ↔ Fit mode switch** on the Source window. Fit mode
  (`SourceFitModeView`) fits a dataset of averaged conditions instead of the
  authored scene.
- [x] **Shared-geometry, per-condition-moment fit** (`SingleDipoleFit
  .fitSharedGeometry`): positions come from the *combined* covariance of all
  conditions (so no condition's noise pulls the geometry), then each condition's
  own moments are solved at those shared positions. That makes "does the model
  differ between conditions?" a clean question — same generators, the difference
  lives in per-condition moment amplitude/orientation, shown as **moment-by-
  condition bars per dipole**. The overall **SVD spectrum** (combined covariance)
  gives the model order for real data with no ground truth; the readout drops mm
  error and reports GOF / residual / moment when truth is absent.
- [x] **Fit-mode UI**: a multi-condition butterfly (all conditions overlaid,
  colored) with drag-to-select interval; three ortho glass-brain projections
  showing the shared dipoles (and true sources when known); a dipole-count
  stepper; a built-in demo dataset.
- [x] **"Fit Source Model" bridge**: right-click a recording's **averaged
  butterfly or topography** → hands *every* averaged condition (channels × samples)
  plus the recording's real montage (via `Montage.fromGeometry`, average-
  referenced to match the forward) to the Source window's Fit mode via
  `PendingSourceFit` (+ notification, since the single-instance window may already
  be open), pre-highlighting a window around the viewed latency.
- [x] Verified by `SourceSimulatorControllerTests` (clean field recovered
  sub-centimetre; noise degrades GOF and moves the fitted position; one dipole
  cannot fully explain two simultaneous sources; a silent playhead has nothing to
  fit; the multi-dipole fit recovers two separated sources within a centimetre with
  GOF > 0.99 and beats the single-dipole GOF; the **interval** fit recovers two
  *simultaneous* distinct-time-course sources the instant fit can't, and the SVD
  spectrum shows two significant components for two sources vs ~one for one; the
  **shared-geometry** fit keeps positions fixed while a doubled-drive condition
  doubles that dipole's moment; the **Fit-mode demo dataset** recovers three
  sources across two conditions). 29/29 Source Simulator tests green.

Deferred follow-on: before any BESA-Simulator parity claim, check their current
feature list rather than cloning from memory.


### Stage 3c-perf — Make dipole fitting BESA-fast — **MOSTLY SHIPPED 2026-09-05** (R5.0; see § 7 above)

The fit is correct but slow: a single ECD is a few hundred ms and a multi-dipole /
shared / interval fit is seconds, where BESA fits a single ECD nearly instantly.
The gap is *how* we compute, not the math — the objective, geometry, and results
stay identical. Root causes, measured against the current code:

1. **The forward model is recomputed from scratch inside the search loop.** Every
   candidate position calls `SphericalForwardModel.leadField`, which sums a
   60-term spherical-harmonic series over every electrode. The position search is
   a brute-force grid (coarse ~hundreds of points + several refinement levels), so
   one fit makes many series-summed forward calls; multi-dipole coordinate descent
   repeats that over sweeps × dipoles.
2. **Grid search instead of a gradient optimizer** — hundreds of evaluations per
   level where a Levenberg–Marquardt/simplex walk from a seed needs ~5–15.
3. **Plain `[[Double]]` nested loops, not Accelerate/BLAS**, plus per-call forward
   overhead, plus reactive re-fitting on every selection/count change.

Plan, in payoff order (each step is independently shippable and must keep the fit
results within tolerance of the current tests):

- [x] **Precompute a free lead-field grid once (biggest win).** Shipped
  2026-09-05 as `LeadFieldGrid` (`brainRadius/12`, trilinear interpolation,
  `Float` storage, cached per geometry, ≤3 kept). Candidate scoring no longer
  solves the forward model at all; unsolvable near-shell nodes fall back to an
  exact solve and `finalize` stays exact. See R5.0 in § 7 above.
- [x] **Rank-reduced covariance and flat/parallel candidate scan** (not on the
  original list, but the actual first-pass win): flat preallocated buffers, a
  rank-reduced `C ≈ W·Wᵀ` objective, and parallelizing the candidate scan
  *including* each worker's own forward solve. 6.4× (40.87 s → 6.34 s) on the
  benchmark, all 35 EVAResolve tests unchanged.
- [x] **Reduced harmonic order in the search** (24 terms vs 60 for the exact
  `finalize`/`deflateCovariance`/`decompose` paths) plus hoisted fixed-dipole
  blocks in the joint objective. Combined with the lead-field grid: 43× on
  cached fits (40.87 s → 0.95 s), 14× cold (2.88 s); single ECD 0.18 s — meets
  the "single ECD instant, multi-ECD sub-second" target once the grid is warm.
- [~] **Levenberg–Marquardt / Nelder–Mead position refinement** — decided
  **not needed**: with the grid warm, refinement is 0.59 s and the coarse
  search 0.24 s, so replacing the search strategy is algorithmic risk for
  fractions of a second. Revisit only if a realistic BEM (R3) makes
  per-candidate evaluation expensive again.
- [x] **Phase-timing instrumentation** (`ProgressReporter.PhaseTimings`,
  reachable via `runSharedFitNow(reporter:)`) — what made each optimization
  above targeted rather than guessed.
- [ ] Remaining cost: the one-time grid build itself (1.89 s, ~66% of a cold
  fit). Candidate follow-ups: build it lazily in the background on dataset
  load, or coarsen the lattice and lean on the exact final refinement.
- [ ] **Analytic / cheaper forward for the search** beyond the 24-term
  reduction (e.g. closed-form Sarvas single-shell) — not needed yet given the
  grid result above.
- [ ] **Cache the forward across reactive re-fits** and debounce interval-drag /
  dipole-count changes so a fit isn't relaunched mid-gesture.
- [ ] **Benchmark harness** as a persisted regression test (today it's the
  ad hoc `benchmarkSharedFit`/timing runs above, not a committed budget
  assertion): assert single-ECD and 2-dipole fit wall time stay under a budget
  on the standard montage, and that accuracy stays within the current tests'
  tolerances.
- [ ] **Head-model agnostic fit** against any `ForwardOperator` (R3.4),
  including an imported BEM.

**Exit:** met for the sphere/spherical-harmonic path — single ECD and
multi-dipole/shared/interval fits are interactive with the grid warm, and the
localization tests still pass (35/35 EVAResolve tests). Still open: the
one-time grid-build cost, a committed benchmark/regression test, and
head-model-agnostic fitting once BEM import (R3) lands.


---

# 8. Simulation

## Where it is now

Implemented, tested, and documented in `Tools/EVASimulate/README.md`:

- **EEG**: seven band-limited Gaussian sources, 1-70 Hz with a notch gap,
  modulated alpha, circular or geometric spatial correlation.
- **Gradient artifact**: slice/volume structure, EEG-MRI clock drift, slow
  amplitude modulation, anti-alias modelling, measured-template import.
- **BCG**: rate modulation, heart-rate variability, beat-to-beat amplitude
  correlation, per-channel latency and polarity, separate true and *detected*
  beat times.
- **Ocular**: blinks as transients, eye movements as gaze-position steps.
- **Muscle**: opt-in deterministic 20-200 Hz bursts localized to left/right
  temporalis and posterior neck, with complete burst and topography truth.
- **Additional artifacts**: rhythmic chewing, stereotyped swallowing, broad
  cable movement, local sweat drift, true channel bridges, common bad-reference
  contamination, and hard amplifier clipping.
- **Recording defects**: five bad-channel kinds, mains noise, per-electrode
  impedance tied to the defect, Johnson-Nyquist contact noise, and
  impedance-scaled mains pickup.
- **Montage**: built-in 10-20 positions or an imported standalone
  `coordinates.xml`/MFF package, with matching `sensorLayout.xml` and
  `coordinates.xml` written to every generated MFF.
- **Source space**: deterministic neural dipoles, three-shell forward model,
  difficult separability scenarios, moving sources, ocular dipoles, and
  localization/component-recovery scoring.
- **ERPs**: target/standard designs, analytic or measured components, dipole
  topography, skewed/correlated trial variability, omissions, MFF markers, and
  average/single-trial recovery truth.
- **Neural non-stationarity**: discrete alpha spindles, independent slow
  per-band amplitude dynamics, switching microstate maps, and known PAC with
  complete truth and parameter scoring.
- **Scoring**: SNR, RMSE, correlation, power ratio, spectral distortion, and
  per-channel breakdowns; optimal source assignment; event detection with
  timing/ROC metrics; and ERP amplitude/latency recovery metrics.
- **Scenarios**: versioned JSON configuration files, explicit flag precedence,
  config-only export, and eight reviewed configurations in a shipped catalog.
- **99 passing self-test outcomes** on the model and shared-forward boundaries,
  and byte-level
  determinism.

## Completion status table


The authoritative progress summary. A checkmark means implemented, tested, and
documented — not merely started. **Keep this table current in the same commit
that completes an item**; a stale row here is worse than no table, because this
is what gets read instead of scrolling 1,800 lines.

| Item | Status | Note |
| --- | --- | --- |
| 1.1 Source-space simulation | ✅ Complete | 2026-08-21. |
| 1.2 ERPs with trial variability | ✅ Complete | 2026-08-21, average and single-trial truth. |
| 1.3 Non-stationarity | ✅ Complete | 2026-08-21: bursts, spectral dynamics, microstates, PAC. |
| 2.1 More artifact types | ✅ Complete | 2026-08-21, all seven families. |
| 2.2 Impedance-coupled noise | ✅ Complete | 2026-08-21, thermal and mains coupling. |
| 2.3 Richer metrics | ✅ Complete | 2026-08-25, waveform/channel/detection/source/ERP plus versioned repeated-evaluation JSON with all per-seed values. |
| 2.4 Scenario files | ✅ Complete | 2026-08-21, versioned catalog with override tests. |
| 3.1 Multi-subject simulation | ✅ Complete | 2026-08-25. `generate-group`, explicit component-wise ERP estimands + between-subject variance, prefix-stable cohorts. |
| 3.2 Comparison harness | Phase B complete | 2026-08-27. Nine gradient arms × two scenarios × five seeds, within-seed paired differences with 95% intervals, and resolved-configuration provenance. Phases C-D open. |
| 3.3 Measured template library | Partial | Gradient-template import exists; curated library and BCG import do not. Load-bearing for real-data validation of 5.4/Tier 8. |
| 3.4 Clinical patterns | Not started | Interictal spikes first. |
| 4.1 BCG geometric topography | ✅ Closed by 5.1 | 2026-08-21, superseded rather than fixed separately. |
| 4.2 BCG spatial rank | ✅ Closed by 5.1 | 2026-08-21, rank 4 emerges from four generators. |
| 4.3 Placeable ERP dipoles | ✅ Complete | 2026-08-22, with `scenarios/aep-bilateral.json` and the 4.5a convergence follow-up. |
| 4.4 Correlated-source band identity | ✅ Complete | 2026-08-21, within-band construction, spectrum tested. |
| 4.5 Lead-field convergence check | ✅ Complete | 2026-08-21; 4.5a follow-ups closed 2026-08-22. |
| 4.6 One reference convention | ✅ Complete | 2026-08-21, one recorded additive-boundary reference. |
| 4.7 Split ERP streams | ✅ Complete | 2026-08-21, five named seed domains. |
| 4.8 Declare ERP overlap | ✅ Complete | 2026-08-21, directional flags and non-overlap scoring. |
| 4.9 Sub-millisecond MFF event times | ✅ Complete | 2026-08-21. Reader *and* writer were quantizing; 1024 Hz now exact. |
| 5.1 Multi-generator BCG | ✅ Complete | 2026-08-21, four physical generators, spatial rank 4. |
| 5.2 Surrogate spatial filter | ✅ PCA-S complete | 2026-08-25. Paper/iterative searches are explicit, correction uses recording geometry and truth head parameters, and PNS is preserved; ICA-S remains open, see 5.4. |
| 5.3 The evaluation | ✅ Complete except localization | 2026-08-25. Completed averages are filtered per paper and all outcomes are in JSON; dipole localization needs 6.1-6.2. |
| 5.4 Simulator-trained BCG labeller | ✅ Pilot complete | 2026-08-25. Beat-locked + ECG logistic model composes with ICLabel, is fitted on two simulator configurations, and improves correction on a held-out third configuration. Real-data validation remains explicitly open. |
| 6.x Distributed inverse methods | Not started | Deferred; 6.1 worth pulling forward if 5.2 needs a source grid. |
| 7.1-7.2 Pipeline regression | ✅ Complete | 2026-08-25. Headless harness, assertion policy, analytic gradient case, and watermark. |
| 7.3 Corpus | ✅ Complete | 2026-08-25. Six generated, watermarked cases cover locked/drifting gradient, QRS-driven BCG, oddball ERP, recording defects, and a clean control. |
| User-facing recording diagnostics | ✅ Pilot complete | 2026-08-25. The unified Channels window exposes Channel Sets, Health, Impedance, review-only relationships, and reference-aware common-mode context. Channel Health automatically evaluates relationships and distinguishes analyzing, no-finding, and flagged states. MFF reference metadata, before/after average-reference checks, and omitted-reference reconstruction are complete; real-recording threshold calibration remains open. |
| 7.4-7.5 Execution and CI | Not started | Establish cross-machine tolerances, then GitHub Actions staging. |
| 8.1 Existing-labeller benchmark | ✅ Complete | 2026-08-25. ICLabel and the independent `ICAComponentAutoLabeler` heuristic path are scored per class against graded topographic truth. |
| 8.2-8.4 Component labelling | Heart/BCG pilot complete | 5.4 proves the narrow workflow; the remaining classes and broader dataset/model-card work are open. |
| SI-1 Shared spherical forward model | ✅ Complete | 2026-08-26. EVA owns the app-neutral solver in `EVA/Core/Forward/`; EVASimulate uses boundary adapters with unchanged scenario/truth schemas and generated outputs. |
| SI-2 Shared source-informed operator | ✅ Complete | 2026-08-26. EVA owns validated PCA-S/MSEC operator construction, diagnostics, application, and the LAPACK Cholesky solve; EVASimulate retains regional-source and paper/iterative BCG discovery policies. |


## EVASimulate tiers — completed

#### 2026-08-25 implementation-audit follow-up

| Finding | Status | Resolution or remaining work |
| --- | --- | --- |
| Correction assumes the standard montage/head and needs an explicit PNS-preservation test | ✅ Fixed | `correct` resolves an explicit `--coordinates` XML/MFF override, then input MFF geometry, then truth-referenced geometry; missing geometry fails unless `--assume-standard-montage` is explicit. Truth shell radii/series terms are reused, real data declares the classic approximation, and ECG/motion PNS round-trip exactly. |
| ERP evaluation omitted the paper's filter on the completed average | ✅ Fixed | Accepted epochs are averaged, then zero-phase filtered 0.3-30 Hz before baseline and scoring; a 100 Hz regression test pins the order. |
| PCA-S used only the iterative pattern-search extension | ✅ Fixed | `paper` and `iterative` are separate modes. Paper mode accepts an operator-selected representative beat or deterministic unattended stand-in; reports preserve the choice. |
| Measured-template scenarios depend on mutable external paths | Deferred by owner | **SHA-256/content-digest work is not a priority.** Do not add digest or template-embedding infrastructure unless the owner explicitly reopens it; the attempted approach was intentionally backed out on 2026-08-25. |
| Multi-component group truth collapsed peaks into one scalar | ✅ Fixed | `group_truth.json` and subject draws now preserve each component ID, latency, units, and contrast; no cross-latency scalar sum. |
| Pipeline ceiling was too permissive to catch information leakage | ✅ Fixed | Ceiling is the analytic `sqrt(N+1)` bound with only 2% numerical tolerance; focused pipeline regression passes. |
| `evaluate-surrogate --json` omitted most evaluation outcomes | ✅ Fixed | Versioned JSON now contains configuration, per-seed values, mean/SD, correction diagnostics, and every ERP criterion. |
| Determinism checker exists only in the untracked `scripts/` tree | Deferred by owner | Leave the existing checker unchanged. Do not prioritize new SHA-256/hash infrastructure or couple it to unrelated roadmap work. |


### Tier 1 — the ones that change what is possible

#### 1.1 Source-space simulation (dipoles + lead field → sensors)

**Status (2026-08-21): complete.** `--eeg-model dipole` adds deterministic
neural sources, an arbitrary-shell analytic forward model with the classic
three-shell preset, free- and fixed-orientation gain matrices, average
referencing, source-count-isolated artifact RNG streams, and complete
truth-sidecar provenance. Controlled correlated and near-degenerate pairs,
time-varying source position/orientation, and an opt-in two-eye homogeneous
dipole model cover the difficult separability cases. `--write-sources` exposes
true source time courses, and `score-sources` evaluates inverse locations and
recovered components with optimal, order- and polarity-invariant assignment.
Source-space invariants and end-to-end workflow checks are included in
`selftest`.

**Structural integration (2026-08-26): complete.** The app-neutral head,
ordered-electrode, dipole, reference, leadfield, convergence, validation, and
spherical-harmonic solver now live in `EVA/Core/Forward/`. EVASimulate adapts
its stable montage/source/truth types at its boundary. All 99 simulator outcomes,
all eight existing generated-scenario fingerprints, and all 1,264 EVA tests
pass without changing a baseline.

**The largest structural change here, and the one most other items compose
with.**

Before 1.1, every topography was an ad-hoc weight vector: the blink was a cubed
cosine to an assumed eye direction, and neural EEG was created directly in
sensor space. The completed dipole path now provides:

- Volume-conducted topographies for every neural source and the opt-in ocular
  model.
- **Known source locations**, so source-localization methods can be scored.
- **Controllable ICA separability** — the number of true sources becomes a
  parameter, and you can generate the cases that break unmixing (more sources
  than channels; two sources with near-identical topographies; sources that move).
- Correlated-source scenarios, which is where most blind-separation methods
  actually fail.

**Implementation.** The analytic concentric-sphere model needs no mesh or
external dependency. Sources are `(position, orientation, timecourse)` records;
the static projection uses a `channels × sources` gain matrix, while moving
sources interpolate between recorded endpoint operators. A later BEM option can
import an individual head model without changing this interface.

**Delivered effort:** large. **Unblocks:** 1.2, 1.3, meaningful ICA evaluation,
and anything about topography.

#### 1.2 ERPs with trial-to-trial variability

**Status (2026-08-21): complete.** The opt-in ERP layer emits deterministic
standard/target designs with exact MFF markers, dipole-projected Gaussian,
biphasic, or measured waveforms, and complete per-trial onset, latency,
amplitude, condition, and omission truth. Latency distributions can be Gaussian
or skewed; latency and amplitude variability have a controlled correlation.
Condition-average truth incorporates jitter and omissions, while `score-erp`
scores either average components or non-omitted trials by stable ID. A reviewed
`oddball-erp.json` scenario ships with the catalog.

**Highest value per unit of work in Tier 1, and it needs nothing else first.**

EVA's Trials module implements Woody, RIDE and CWT-ridge single-trial latency
estimation. It now has deterministic per-trial latency and amplitude truth to
test against, enabling recovered-versus-true figures across SNR.

**Implementation.**

- Component definition: Gaussian, biphasic, or measured waveform; a peak
  latency; an explicit dipole topography; and an amplitude.
- Per-trial draws: latency jitter (normal or skewed), amplitude jitter,
  occasional omissions, and a *latency-amplitude correlation* — the confound
  that motivates most single-trial methods.
- Experimental design: conditions, trial counts, ISI distributions, oddball and
  target/standard structure. Emit condition codes as MFF events so EVA's own
  epoching path consumes it unchanged.
- Ground truth to the sidecar: per trial, its true latency and amplitude.

**Delivered effort:** medium. **Unblocks:** validation of everything in
`EVA/Trials/` and `EVA/Epoching/SingleTrialAnalyzer.swift`. **Note:** this is the item most likely
to produce a publishable result quickly.

#### 1.3 Non-stationarity

**Status (2026-08-21): complete.** The opt-in layer (`--with-nonstationarity`)
now provides deterministic alpha spindles, independent log-amplitude OU
dynamics for every band, four-state topographic switching with constrained
40–250 ms dwell times, and known theta-to-gamma phase-amplitude coupling.
Every realized event, envelope, state/map and PAC parameter is written to the
truth sidecar; `score-pac` reports coupling-strength and circular preferred-phase
error. The paper-compatible default remains stationary, and individual
mechanisms have numeric controls and ablation switches. Five self-tests pin the
stationary compatibility path, deterministic truth, burst timing, slow spectral
continuity, distinct microstates and phase-locked gamma amplitude.

**The paper's own stated weakness, and the reason to distrust every ICA number
the harness currently produces.**

Grouiller et al. conclude that the discrepancy between their simulated and
experimental ICA results is most likely explained by their model's stationarity:
real neural signals are strongly non-stationary, which violates ICA's
assumptions. Our model inherits the flaw exactly. Until it is fixed, the honest
position — currently stated in the docs — is that simulation says nothing
trustworthy about ICA.

**Sketch, cheapest first:**

- **Bursts instead of continuous rhythms.** Alpha as discrete spindles with
  realistic durations and inter-burst intervals, not an amplitude-modulated
  continuous process. Small change, large realism gain.
- **Time-varying spectra.** Let band amplitudes follow a slow stochastic process
  rather than a constant.
- **Topographic switching (microstates).** Piecewise-stationary spatial patterns
  with realistic dwell times — the specific structure that breaks the
  "sources are fixed in space" assumption ICA rests on.
- **Cross-frequency coupling.** Phase-amplitude coupling with a known coupling
  strength, which is also a directly testable ground truth for PAC methods.

**Delivered effort:** large. **Unblocks:** controlled ICA evaluation; PAC method
validation. The generated laws remain phenomenological and should be swept, not
treated as a fitted population model.

---


### Tier 2 — high value, self-contained

#### 2.1 More artifact types

**Status (2026-08-21): complete.** EMG is delivered as an opt-in, deterministic
surface-muscle model with independent 20-200 Hz carriers for left temporalis,
right temporalis, and posterior neck; smooth stochastic burst envelopes;
configurable rate, amplitude, duration, and band edges; MFF duration markers;
complete burst/topography truth; `score-events --type emg`; teaching-scenario
coverage; and three behavioral self-tests. Chewing and swallowing add distinct
stereotyped orofacial episodes; cable sway is low-frequency, broad, and spatially
correlated; sweat drift is slow and channel-local; true bridges average a named
pair into one shared signal; bad-reference noise is identical across every
channel; and clipping applies recorded symmetric amplifier rails. Duration
markers and truth support event scoring for every episodic family. All remain
off in the operational and paper defaults.

The completed expansion covers:

- **EMG / muscle. ✅** Broadband above ~20 Hz, temporalis- and neck-weighted,
  and bursty, with exact event and spatial truth.
- **Chewing and swallowing. ✅** Stereotyped bursts with distinct truth markers.
- **Cable sway / movement. ✅** Low-frequency, spatially broad, correlated across
  neighbouring channels.
- **Sweat. ✅** Very low frequency drift on explicit channels.
- **True electrode bridging. ✅** Two channels sharing one signal. This is a
  *different* failure from the current `flat` defect and is the case that
  bridging detectors are built to catch — model it as a correlated pair.
- **A bad reference. ✅** Contaminating every channel identically. Distinctive,
  common, and routinely misdiagnosed as global noise.
- **Saturation / clipping. ✅** Hard rails, which break linear methods in a way
  additive artifacts do not.

**Effort:** small each; they share the injection machinery in
`ChannelDefectModel.swift` and `OcularArtifactModel.swift`.

#### 2.2 Impedance-coupled noise

**Status (2026-08-21): complete.** Contact impedance is now realized before
sample noise and drives per-channel Johnson-Nyquist noise through
`sqrt(4 k T R B)`. When mains interference is enabled, pickup follows an
explicit impedance power law with a small seeded lead-dress term. The exact
latent impedance, analytic thermal RMS, and realized mains-gain vectors are
retained in truth even when ICAL export is disabled. Flat contacts and explicit
bridged pairs keep deceptively low impedance, preserving the intended
counterexample. Dedicated seed streams, CLI controls, impedance sweeps,
paper-default opt-out, and three behavioral regression tests complete the item.

We record per-electrode impedance and we generate per-channel noise, and the two
were previously **independent**. Physically they are not: a high-impedance contact
picks up more thermal noise and more interference. Wiring noise amplitude and
mains pickup to impedance makes the recording internally consistent and makes
impedance genuinely predictive rather than decorative — with the `flat`/bridged
case still deliberately breaking the correlation, since that is the lesson.

**Delivered effort:** small. **Methods caution:** because this model makes
impedance predictive by construction, an impedance-rejection study should test
held-out coupling parameters and the low-impedance exceptions rather than claim
the built-in correlation itself as validation.

#### 2.3 Richer metrics

**Status (2026-08-21): complete.** `score` now reports broadband, per-band, and
per-channel RMSE, correlation, spectral distortion, SNR, and power ratio from a
shared Welch analysis. `score-events` performs optimal one-to-one temporal
assignment and reports precision, sensitivity, time-bin specificity, F1,
false-positive rate, timing error, and confidence ROC/AUC. `score-erp` reports
signed bias, MAE, and RMSE for recovered component amplitude and latency. Source
location and waveform assignment from 1.1 completes the source-specific side.
All metrics have text and machine-readable output plus regression tests.

SNR alone is thin for a paper, and the paper itself lists its limitations.

- **RMSE and per-band correlation**, which are not normalized and so say
  different things than SNR.
- **ERP-specific**: amplitude and latency bias in the recovered average, which is
  what an ERP researcher actually cares about.
- **Spectral distortion**: how much the corrected PSD deviates from truth, per
  band — over-filtering made visible.
- **Detection metrics.** ROC, sensitivity and specificity for artifact
  *detection*, scored against the known event times already in the sidecar. Many
  methods papers are about *finding* artifacts; this closes the former gap where
  the ground truth existed but could not be scored.
- **Per-channel breakdown**, so a single bad channel is visible instead of
  averaged away.

**Delivered effort:** medium. **Dependency:** none. The ERP simulation now
populates the same average and single-trial metric contract.

#### 2.4 Scenario files

**Status (2026-08-21): complete.** `--config` loads a versioned JSON envelope
containing the complete `SimulationConfig` and seed; explicit flags override
loaded values. `--write-config` saves the final resolved scenario and can be used
without generating data. The shipped `scenarios/` catalog includes the paper
default, teaching demo, and difficult dipole-separability case. Schema checks,
full-config round trips, precedence tests, truth-sidecar equality, and
byte-deterministic catalog generation are verified.

Forty command-line flags do not fit in a methods section. A scenario file —
YAML or JSON, holding the whole configuration plus the seed — means a paper can
say "scenario `bcg-jitter-sweep`, seed 20260821" and a reviewer can regenerate
the data byte-for-byte.

**Implementation.** The schema wraps `SimulationConfig` with a version, stable
name, and description. The complete resolved configuration is the same object
written into `sim_truth.json`. Unsupported future schema versions fail loudly.
Measured-template asset paths are retained in the configuration as well.

**Delivered effort:** small. **Value:** disproportionate — this makes results
citable and composes with 3.2.

---

#### 3.1 Multi-subject and group simulation

**Status (2026-08-22): complete.** `eva-simulate generate-group` writes a cohort
of `sub-XX/` packages plus `participants.tsv` and `group_truth.json`. 12 subjects
in ~23 s.

**The part that matters most is not "run the generator N times".** N draws from
one distribution have no between-subject structure, so a mixed-effects model
fitted to them estimates a variance component that is zero by construction — and
looks like it works regardless. A group study needs *two* levels of ground truth,
and both are now recorded:

- **The population estimand** — each ERP component's ID, nominal peak latency,
  units, and target-minus-standard condition difference. Components at different
  latencies and polarities are scored separately, never summed into one scalar.
- **Between-subject variance** — each subject's departure from it, drawn from
  declared distributions.

Score group results against `group_truth.json`'s `erpEstimand.components`, never
against one subject's realization. The compatibility scalar
`populationEffectMicrovolts` is present only for a one-effect design (or zero for
a negative control); it is `null` when multiple non-zero components would make a
scalar ambiguous.

**What varies per subject:** head radius (which changes the forward model, so
topographies differ even for identical sources), electrode placement, alpha
amplitude, BCG severity, impedance quality, heart rate, and the ERP effect size.
Every draw is declared as an SD and recorded. `--homogeneous` zeroes them all,
which is the negative control: a group method that finds structure in a
homogeneous cohort is finding noise.

**Effect scaling moves the contrast, not the response.** Multiplying both
condition amplitudes would be a gain difference, leaving target-minus-standard
proportionally identical across subjects — no between-subject variance in the
quantity being estimated. The per-subject draw adjusts the standard ratio
instead, so the *difference* varies and the common response barely moves.

**Covariates are exact**, which is unusual and useful. `participants.tsv` carries
each subject's true drawn parameters in BIDS format. Real group analyses regress
on covariates measured with error and often mis-specified; here they are known,
so it is possible to ask how much of a group result survives perfect covariate
knowledge — and how much was mis-specification all along.

**Determinism is prefix-stable.** Subject seeds depend on the group seed and
index alone, never on cohort size: verified that the first 6 subjects of a
12-subject cohort are byte-identical to a 6-subject cohort. Growing a cohort must
not resample the subjects already in it.

**New scenario:** `scenarios/group-oddball.json` — the bilateral Sylvian N100
identical across conditions plus a midline target-only P300, so the contrast is
carried entirely by the P300 and its component estimand is a clean 6.00 µV.
`aep-bilateral` deliberately has **no** contrast (Rusiniak's AEP is one repeated
stimulus), and `generate-group` now says so explicitly rather than reporting a
between-subject SD for a quantity that is identically zero.

**BIDS export is left to `Tools/EVABIDS`** rather than built in — one
`eva-bids to-bids` call per subject. Keeping the tools composable beats coupling
them.

**Self-tests (90 total, 0 failures):** prefix stability; realized
between-subject SD within 0.05 of the request over 400 subjects; `--homogeneous`
fixing every parameter at 1 while leaving each subject its own seed; effect
scaling moving the contrast and giving exactly zero when conditions are
identical; multi-component effects remaining distinct; and `participants.tsv`
shape.

**Not done:** per-subject *source* variation beyond head size (individual
anatomy), and sessions/runs.

---

**Original plan:**

Per-subject parameter draws (montage variation, artifact severity, alpha
amplitude, impedance quality) so group-level and mixed-effects methods can be
tested. Export straight to BIDS through `Tools/EVABIDS` and the result is a
synthetic dataset any pipeline can be run over — which is a useful artifact in
its own right, independent of EVA.

**Effort:** medium. **Depends on:** 2.4 (scenario files) to stay manageable.


### Tier 4 — consistency and correctness debts

Written 2026-08-21 after a full read of the implemented tool alongside Rusiniak
et al. (2022). Tier 1-3 describe capabilities the simulator does not yet have.
Tier 4 is different: these are places where the simulator *does* have the
capability but applies it inconsistently, or where a modelling choice that was
harmless as a benchmark becomes load-bearing now that results are meant to be
defensible. They are mostly small. They are listed before Tier 5 because Tier 5
cannot be trusted until 4.1 and 4.2 are done.

#### 4.1 Give the BCG a geometric topography

**Status: closed by 5.1 (2026-08-21).** Superseded rather than fixed
separately — the interim single-dipole fix was never needed, because the
multi-generator model landed directly.

**The single largest inconsistency in the tool today.**

1.1 replaced invented topographies with dipoles projected through a forward
model — for the ongoing EEG, for the ERP, and for the eyes. The BCG never got
that treatment. `BCGArtifactModel.inject` still assigns each channel a scale of
`(0.35 + 0.65 · cos(2π · channel / N))`: a smooth function of **channel index**,
not of position.

This is the same circular-neighbour structure the README already declares as a
limitation of the default Grouiller spatial model — except it survives
`--eeg-model dipole`, so a run that is otherwise physically consistent still
hands every spatially-aware correction method a topography no montage produces.
PCA, ICA, and EVA's topography-gated/aligned/weighted OBS strategies all key on
exactly this structure. Any comparison among them on the current model is
scoring their response to an artefact of channel ordering.

**Sketch.** Even before 5.1's multi-generator model, the interim fix is cheap:
place one equivalent dipole (or a small fixed set) in the existing head model and
project it through `SphericalForwardModel`, exactly as the ocular model does.
Polarity reversal across the head then falls out of the field instead of being
imposed by a cosine.

**Effort:** small. **Blocks:** 5.x entirely, and any current claim about
topography-aware BCG correction.

#### 4.2 The BCG is rank-1 in space

**Status: closed by 5.1 (2026-08-21).** Realized rank is now 4, and it emerges
from having four distinct physical generators rather than being asserted by
adding components — which was the requirement.

One template waveform times one scalar per channel. Per-channel latency adds
only approximate rank. The whole artifact therefore lives in ~one spatial
dimension.

Rusiniak et al. report 4-8 principal components per subject (mean 5.7), and
FMRIB's OBS default of 4 exists because the real artifact has that rank. Against
a rank-1 artifact, OBS-4 is trivially near-optimal, and PCA-S, ICA-S and OBS
become indistinguishable — the comparison most worth running is the one the
current model cannot resolve.

**Sketch.** Rank should *emerge* from having several physically distinct
generators, not be asserted by adding components. See 5.1.

**Effort:** medium, and mostly the same work as 5.1. **Note:** the current model
flatters every template-based method. The README's "fixed waveform with varying
amplitude" caveat understates this — the spatial degeneracy matters more than the
morphological one.

#### 4.3 Make the ERP dipole placeable

**Status (2026-08-22): complete.** `ERPConfig.components` takes an array of
explicitly placed generators, each with its own position, orientation, waveform,
latency, width and per-condition amplitudes. When absent, the single legacy
component is used unchanged.

**The confound is gone, and measured.** The old path derived the ERP source from
`makeSources`, so it sat **exactly** on ongoing-EEG source #1 — signal and noise
in the same place. `selftest` demonstrates rather than asserts this: the legacy
component reports 0 mm to the nearest neural source, placed components report
more than 10 mm, and the distance is written to the truth sidecar for every
component so the confound stays visible.

**Coordinate frame is declared.** `+x` right, `+y` anterior, `+z` vertex, origin
at the head-model centre, millimetres — the same frame `Montage` and
`SimulatedSource` already use, and it is recorded in the sidecar as
`erpCoordinateFrame`. `ERPComponentConfig.talairachApproximate` converts
published coordinates under a **stated approximation**: the simulator's origin is
a sphere centre, not the anterior commissure, so a fixed offset is applied and no
scaling or shear is attempted. Relative geometry — what makes a bilateral pair
bilateral — survives far better than absolute anatomical position, and the
documentation says so rather than implying anatomical fidelity.

**New scenario:** `scenarios/aep-bilateral.json` — Rusiniak et al.'s Table 1 AEP,
two dipoles perpendicular to the left and right Sylvian fissure with N100 peaks
2 ms apart, converted from Talairach (-49,-18,12) and (49,-15,13). This is what
5.3's remaining criteria need in order to have anything to localize.

**Per-component per-trial truth.** Each component records its realized latency
and amplitude for every trial, from its **own** seed streams — components of a
real complex do not jitter together, and that independence is precisely what
single-trial latency estimation has to contend with. A self-test pins that two
components' per-trial latencies are close to uncorrelated.

**4.5a's third follow-up landed with it.** `SphericalForwardModel.leadField` now
takes `verifyConvergence`, and the placed-ERP path passes `true`. The run-level
check in `runGenerate` covered every call site only because all sources shared
one eccentricity; a placed component can sit at any depth. A self-test confirms
that a component 0.5 mm inside the brain boundary with 8 series terms is
**rejected** rather than producing a plausible-looking topography.

**Backward compatibility, verified not assumed.** With the new truth fields
suppressed, `oddball-erp` reproduces the recorded pre-4.3 directory hash
`ad80ae2b…` exactly; it was also the only existing scenario whose hash moved, and
only its sidecar changed. `components` is Optional, so scenarios written before
4.3 — including users' own — still decode.

**Self-tests added (78 total, 0 failures):** the coincidence defect and its fix;
placed topographies reproduce a directly computed lead field to 1e-9 while the
bilateral pair stays non-degenerate; independent per-component jitter; and
rejection of an under-resolved placement.

**Not done here:** condition-dependent *source location* (targets and standards
can differ in amplitude per component but share a generator), and habituation.

---

**Original plan:**

`ERPGenerator.makeSource` calls `DipoleEEGGenerator.makeSources(config)[0]` and
renames the result. The ERP therefore inherits the golden-spiral position and
orientation pattern of ongoing-EEG source #1 — and is **coincident with it**.
The signal sits exactly where one of the noise sources sits.

Two consequences. First, single-trial latency validation (the whole point of
1.2) is run with a confound nobody chose. Second, published dipole models cannot
be reproduced: Rusiniak's bilateral AEP is two dipoles perpendicular to the
Sylvian fissure at stated Talairach coordinates, and there is currently no way
to express that.

**Sketch.**

- Explicit `(position, orientation)` per component, in millimetres, in a
  **declared coordinate frame** — the simulator's own frame is fine, but it must
  be named and a Talairach/MNI-to-frame mapping documented, or published models
  cannot be entered.
- N components rather than one, each with its own waveform, latency, amplitude
  and topography, so P1/N1/P2/P3 overlap can be modelled.
- Condition-dependent amplitude *and* condition-dependent source, so target and
  standard are no longer forced to share a topography.
- Refuse, or at minimum declare in the truth sidecar, an ERP source that
  coincides with an ongoing-EEG source.

**Effort:** small-medium. **Unblocks:** 5.3, and makes 1.2's results
interpretable.

#### 4.4 Correlated-source band identity

**Status (2026-08-21): complete.** When correlation is non-zero, S002 is assigned
S001's configured band before the exact correlation transform, and waveform
generation now follows each source's recorded `bandName`. The truth therefore
remains spectrally honest; without correlation, the normal round-robin band
catalog is unchanged. A self-test pins both paths.

Before this fix, `--dipole-source-correlation` mixed source 1's timecourse into
source 2 even though sources cycled through different `eegBands`. Source 2 was
therefore no longer band-limited while per-band scoring assumed it was.

**The self-test measures the spectrum, not the label.** S002 must keep over 90%
of its power inside S001's band — realized 0.94, the shortfall being Welch
leakage at the narrow delta edge. Under the old cross-band construction the same
measurement would have been roughly 0.36, so relabelling a source without
changing its signal cannot pass. The test also requires the shared-band decision
to appear in `scenarioRole`, since an undeclared change is the failure mode the
item was about.

**Baseline impact.** `scenarios/dipole-separability` is the only shipped scenario
with a non-zero correlation, and it was the only determinism hash that moved. The
other three were confirmed unchanged before the baseline was re-recorded — which
is the determinism check earning its keep on its first real change.

**Fix:** either correlate within band, or record the realized spectrum change in
`sim_truth.json` and say so in the docs. Choosing silently is the only option
that is wrong.

**Delivered effort:** small.

#### 4.5 Lead-field series convergence check

**Status (2026-08-21): complete.** Every dipole generation now compares the
complete free-orientation gain matrix at the requested truncation `N` and
`2 × N`. It evaluates the L2-relative change of each source/orientation column,
reports the worst change, and emits a runtime warning above `1e-4` (0.01%),
including the responsible source and axis. The self-test spans source-radius
fractions 0.01 through 0.999999 and verifies the 100-term default converges,
while a deliberately under-resolved 10-term field at 0.99 is rejected.

The Legendre series in `potentialPerUnitMoment` converges slowly as the source
approaches the brain-shell boundary, and `--dipole-source-radius-fraction` is
user-settable. Nothing asserts that `leadFieldTerms` is sufficient at the
configured eccentricity.

This is exactly principle 4's failure mode: silently wrong topographies that
still look entirely plausible, in a component every other result now depends on.

**Fix:** a self-test that computes the gain matrix at `terms` and `2 × terms`
and asserts a relative change below tolerance across the eccentricity range the
tool permits; and a runtime warning when the configured eccentricity needs more
terms than requested.

**Delivered effort:** small. The diagnostic is numerical truncation evidence,
not an independent validation of the spherical forward equations.

**Verified 2026-08-21:** at the default 0.85 depth the 100→200 term change is
6.49e-15 — machine precision. No existing output moves, so no scenario
regeneration and no determinism-baseline change was required by this item.

##### 4.5a Follow-ups

**Status (2026-08-21): complete.** The self-test now reports
`worstConvergenceChange` — the quantity it actually asserts — instead of the
negative control's value. The control tests the metric's *shape* rather than
only its threshold: truncation error must fall monotonically over 10/25/50/100
terms at 0.99 eccentricity, which a metric broken toward always-large values
would fail. And the runtime check in `runGenerate` now carries a comment
recording that it covers every call site only because all sources share one
eccentricity, with the pointer to move it inside
`SphericalForwardModel.leadField` when 4.3 lands.

Original items:

- **The self-test prints the wrong number.** `Outcome.snr` carries the
  *negative control's* value, so the line reads `0.043` beside a claim that
  every tested depth is below `1e-4`. It looks like a failure to anyone reading
  selftest output cold. Report `worstConvergenceChange` — the quantity actually
  asserted — and keep the control's value in the expectation string if it is
  wanted.
- **Strengthen the negative control.** At 10 terms the *default* 0.85 depth
  already changes by 0.0256, so the 0.99 eccentricity is not doing much work and
  the control would still pass if the metric were broken in a direction that
  always returns large values. Assert monotone decrease across 10 → 25 → 50 →
  100 terms instead, which tests the metric rather than only its threshold.
- **The single check covers all call sites only by coincidence, and 4.3 ends
  that.** `runGenerate` checks convergence once, for `makeSources(config)`. That
  happens to cover `ERPGenerator` (its source comes from `makeSources`, same
  radius fraction) and `applyMotionIfNeeded` (rotation preserves radius);
  `OcularDipoleModel` uses a closed form and no series at all. Coverage is
  complete today **only because every source shares one eccentricity**. An
  explicitly placed ERP dipole from 4.3 can be more eccentric than the ongoing
  sources, and the single check would silently stop covering it. Either leave a
  comment now recording that the check assumes uniform eccentricity, or — better,
  when 4.3 lands — move the check inside `SphericalForwardModel.leadField` as an
  opt-in parameter so it travels with every call site.

#### 4.6 One reference convention across all injection layers

**Status (2026-08-21): complete.** `--reference average|infinity` defines one
recording convention for both EEG models. The complete additive mixture—neural
EEG, ERPs, scanner/physiological artifacts, contact noise, and mains—is
referenced once at a shared boundary. Bad-reference corruption, channel defects,
bridges, and clipping are deliberately later recording failures. Convention and
application stage are explicit in truth and every shipped scenario.

Before this fix, the neural lead field and ocular topographies were
average-referenced while BCG, EMG and the other Tier 2.1 artifacts were not. The
composite recording consequently had no well-defined reference, which matters
because average-referencing is a step in nearly every published pipeline —
including all five methods in Rusiniak et al.

**Fix:** define the reference once at the injection boundary and enforce it for
every layer; record it in the truth sidecar.

**Delivered effort:** small.

**Audited 2026-08-21.** Every layer confirmed to build in
`effectiveRecordingReference` — no call site left using the legacy
`dipoleReference` or a hardcoded `.average`. One gap was found and closed: the
self-test covered `EEGReferencing` on a synthetic matrix and on the clean neural
EEG, but nothing exercised the *complete* mixture, which is what 4.6 actually
claims — BCG, ocular and EMG were precisely the layers that previously met no
reference at all. `selftest` now builds EEG + gradient + BCG + ocular + EMG in
one recording and checks the boundary lands.

That test carries an infinity-reference negative control, and it is the half that
makes it a test: without it, "the channel mean is zero" could pass because every
layer happened to be constructed zero-mean and the referencing step was doing
nothing. The same mixture at infinity is asserted to retain a common mode above
1 µV.

#### 4.7 Split the ERP random stream

**Status (2026-08-21): complete.** Latency, amplitude, target/standard order,
onset jitter, and omission now use five independent named seed domains recorded
in truth. Trial-count changes preserve the existing prefix of unrelated factor
draws; exact latency–amplitude correlation remains a deliberate within-design
batch constraint. A focused self-test verifies prefix stability and seed
separation.

Previously, latency draws, amplitude draws, the target/standard shuffle, ISI
jitter and omission draws all came from one interleaved `GaussianSource`. The
per-model domain-mixing idiom in `SimulationSeedStreams` already exists; apply
it within the ERP layer so a one-factor sweep does not re-roll the other
factors. Varying trial count currently changes every draw downstream of it,
which makes trial-count sweeps harder to interpret than they need to be.

**Delivered effort:** small.

#### 4.8 Declare ERP trial overlap

**Status (2026-08-21): complete.** Every trial records its component-window end
and previous/next/any overlap flags. Dense schedules remain allowed, but the CLI
summary declares their count and `score-erp --level trial --exclude-overlap`
scores only the unambiguous subset. Tests cover both dense and separated
schedules.

`onsets` may place a trial inside the previous trial's component window. That is
realistic and worth keeping, but sensor-space peak truth then becomes ambiguous
even though source-space truth stays exact. Document it, and consider emitting
an overlap flag per trial in the sidecar so a method can be scored on the
non-overlapping subset.

**Delivered effort:** small.

#### 4.9 Sub-millisecond MFF event times (the 1024 Hz blocker)

**Status (2026-08-21): complete.** Event times now survive a write/read round
trip at microsecond precision, verified end to end: every TREV, QRSd and QRSt
marker in a 1024 Hz `paper-default` run recovers its **exact** sample index, and
the TR train's only remaining variation (3072/3073 samples) is the simulator's
own intentional 152 µs/s clock drift, inside EVA's one-sample tolerance.

**A second half of the bug was found during the fix.** The write side was as
diagnosed, but `MFFReader.parseMFFDate` truncated too — `ISO8601DateFormatter`'s
`.withFractionalSeconds` stops at milliseconds. Fixing only the writer would not
have fixed 1024 Hz. The reader now splits the fraction off, parses the
whole-second instant with Foundation, and adds the fraction back as a Double
(any digit count: files in the wild use three, six, and nine).

The simulator's own millisecond workaround in `SimulationWriter` — which
correctly concluded "the fix has to be in the writer's precision, not here" —
has been removed; event times now snap to the sample grid, which is the real
resolution of a discrete recording. Its record of three failed repair schemes is
kept as a comment so they are not retried.

`MFFTimestamp` carries integer seconds + integer nanoseconds, snapped to whole
microseconds on construction so `recordTime` and every event quantize onto one
grid and the reader's subtraction does not inherit two roundings. `DateFormatter`
is only ever handed a whole-second instant.

**Tests:** `EVATests/IO/MFFEventPrecisionTests.swift` round-trips events at 500,
1000, 1024, 2048 and 20000 Hz and pins TR spacing at 1024 Hz; the simulator's own
self-test now sweeps four rates rather than asserting the 1000 Hz default alone.
1000 Hz and 500 Hz are kept in both, but note they *cannot* detect a regression —
their sample period is a whole millisecond, so they passed even with the bug
present.

**The 1000 Hz default is now a free choice rather than a constraint.**
`scenarios/paper-default.json` was already at the paper's 1024 Hz and now
round-trips exactly; whether to move the operational default back is a
scientific decision, not a workaround, and is left open.

---

**Original analysis, kept because `TODO_Aug21.md` is not in the repository:** The interim mitigation —
defaulting the simulator to 1000 Hz — is in place and works, because at 1000 Hz
a sample is exactly 1 ms and every sample index survives a millisecond-resolution
round trip. It is a mitigation, not a fix: it means the paper's own 1024 Hz rate,
and every non-integer-millisecond rate (500 Hz is fine, 512, 2048 and 20000 Hz
are not), cannot be written and read back reliably.

**What actually happens.** `MFFWriter.mffDateString` already asks for six
fractional digits (`yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx`), so the format string is
not the problem — an earlier note in this roadmap that blamed a millisecond
format is out of date. The problem is `DateFormatter` itself, which carries
millisecond internal precision and zero-fills the remaining digits, so a
microsecond-looking timestamp is still millisecond-quantized in practice.
`Date` is not the limitation: as a `Double` of seconds since 2001 it resolves to
roughly 0.1 µs at present-day epochs.

At 1024 Hz a sample is 976.5625 µs, so millisecond rounding displaces an event by
up to ±0.5 ms, or ±0.51 samples. Two adjacent TR markers can therefore land
1.02 samples apart in the round trip, which is what trips EVA's own one-sample
TR-spacing tolerance and produces the intermittent "TRs are not evenly spaced"
rejection. The failure is intermittent because it depends on where each marker
falls relative to the millisecond grid.

**Why microseconds are sufficient.** 976.5625 µs is not an integer number of
microseconds either, so microsecond formatting still quantizes — but the residual
is at most 0.5 µs, which is 0.0005 samples. That is four orders of magnitude
inside the tolerance, and it holds for any plausible sampling rate. Nanoseconds
are permitted by MNE's parser (its regex accepts six *or* nine fractional digits)
but buy nothing here.

**The fix.**

1. **Stop routing timestamps through `DateFormatter` for the fractional part.**
   Format the whole-second calendar fields with the existing POSIX formatter,
   and append the fractional digits as a zero-padded integer computed
   separately. The numeric timezone offset comes from
   `TimeZone.secondsFromGMT`, which strict readers require and which the current
   `xxx` token already satisfies.
2. **Compute the fraction with integer arithmetic from the sample index, not
   from a `Double` offset.** `microseconds = round(sampleIndex × 1_000_000 /
   sampleRate)` as integer math avoids a second rounding on top of the first.
   This means `MFFEvent` wants an optional `beginSample: Int` that takes
   precedence over `beginTimeSeconds` when the caller knows the exact sample —
   which the simulator always does.
3. **Anchor `recordTime` and every event to the same integer-nanosecond origin.**
   The reader computes `round((beginTime − recordTime) × sfreq)`, so if
   `recordTime` is quantized differently from the events, the difference inherits
   both errors. Writing both from one integer origin makes the subtraction exact.
4. **A round-trip regression test.** Write TR markers at 1024 Hz, read them back
   through EVA's own reader, and assert exact sample-index recovery and that the
   TR-spacing check passes. Then do the same at 512, 2048 and 20000 Hz. Without
   this the bug returns silently, which is precisely the class of failure
   principle 4 exists to catch.

**Once fixed:** revisit the default sampling rate. The 1000 Hz default was chosen
to dodge this bug, not on scientific grounds, and `scenarios/paper-default.json`
should go back to the paper's 1024 Hz so the benchmark reproduces the published
configuration exactly.

**Effort:** small — a focused change in `EVA/IO/MFFWriter.swift` plus tests.
**Blocks:** general-rate support in 3.2, reliable 1024 Hz runs in 3.1, and exact
reproduction of the Grouiller configuration. **Priority:** high relative to
effort; it is currently being worked around rather than solved.

---


### Tier 5 — surrogate-source BCG separation

The goal: reproduce and then improve on Rusiniak, Bornfleth, Cho, Wolak, Ille,
Berg & Scherg (2022), *EEG-fMRI: Ballistocardiogram Artifact Reduction by
Surrogate Method for Improved Source Localization*, Front. Neurosci. 16:842420.

**Why this is now reachable.** The surrogate method is a *source-space* method:
it builds a spatial filter from a basis of brain regional sources plus artifact
topographies, and back-projects only the non-artifact subspace. Before 1.1 there
was no forward model to build such a basis with. There is now — and the design
decision to retain the free-orientation `channels × 3·sources` operator in
`LeadField` was, whether or not it was intended this way, precisely what a
regional source needs: three orthogonal dipoles at one location.

**Why our version can be stronger than theirs.** Rusiniak et al. superimposed a
simulated AEP onto *real* resting-state EEG. They had ground truth for the
evoked response and none at all for the BCG they were removing, so every
statement about artifact removal is indirect — inferred from what survived in
the AEP. We would have ground truth for both. "Does surrogate separation
preserve source-space truth when the artifact itself is known?" is a question
their design cannot ask.

#### 5.1 A physically-generated, correctly-ranked BCG

**Status (2026-08-21): complete.** `--bcg-model generators` replaces the
channel-index cosine with four physically placed generators. **This supersedes
4.1 and 4.2, which are now closed.**

**The generators**, in the order they arrive after the R wave: aortic flow
(deep, broad, earliest), vessel pulsation left and right (focal, lateral,
separately seeded with slightly different transit delays), and head rotation
(broad, latest, largest). Realized spatial rank is **4**, with normalized
singular values 1.000 / 0.527 / 0.462 / 0.182 — a genuinely multi-dimensional
artifact rather than one dominant component plus numerical dust. The old model's
rank was 1, which is why OBS-4 could not fail against it and why PCA-S, ICA-S
and OBS were indistinguishable.

**Derived versus modelled, declared.** The head-rotation topography is derived:
a rigid rotation with angular velocity ω about the left-right axis in a
head-foot bore field gives a motional field `E = v × B = -ωB·z·x̂`, which
integrates to `Φ ∝ x·z`. The aortic topography is derived as a
homogeneous-conductor current dipole in the chest oriented along `v × B`. The
vessel kernels are **modelled, not derived** — electrode motion over an artery
is a moving half-cell potential, not a current source, so there is no dipole to
project. Relative amplitudes and delays are plausible, not measured.

**Beat-to-beat morphology now varies in shape, not only amplitude.** Each
generator's share is drawn independently per beat
(`--bcg-morphology-jitter`, default 0.20); because the generators differ in
topography *and* delay, the composite changes shape. This closes the README
limitation that mattered most for 5.2, since PCA- and ICA-based methods differ
precisely in how they handle shape variability.

**Field strength** is a real parameter now (`--bcg-field-strength`, default 3 T).
Both motional EMF and the Hall separation are linear in B, so one factor scales
every generator from the 3 T reference the paper's 10-200 µV range describes.

**Backward compatibility.** `.channelIndex` remains the default and its draw
order is preserved verbatim. Verified, not assumed: with the new truth fields
suppressed, `paper-default` reproduces the recorded pre-5.1 directory hash
`db7db7f5…` exactly, and every signal binary in all four shipped scenarios is
byte-identical. The only change is one added `bcgSpatialModel` key in
`sim_truth.json`.

The four generator configuration fields are **Optional with `effective…`
accessors**, following the `recordingReference` precedent. Swift's synthesized
`Decodable` does not fall back to a property's default for a missing key, and
every scenario file carries the complete configuration — so non-optional
additions would have broken every scenario a user already had. A self-test now
pins that contract by decoding a configuration with all four keys removed.

**New scenario:** `scenarios/bcg-generators.json`, the paper configuration with
the generator BCG substituted.

**Self-tests added (68 total, 0 failures):** the channel-index model is shown to
ignore electrode geometry entirely (reversing the montage leaves every weight
identical — the 4.1 defect, demonstrated rather than asserted); generator
topographies permute with their electrodes to within 1e-9 *and* are non-flat, so
a uniform topography cannot pass for the wrong reason; spatial rank is 4 with the
smallest singular value above 5% of the largest, against rank 1 for the legacy
model; amplitude-normalized beats correlate above 0.999 with morphology jitter
off and below 0.99 with it on; and field strength scales peak-to-peak exactly
linearly.

**A reusable piece:** `SymmetricEigen` (cyclic Jacobi) was written for the rank
diagnostic but is deliberately general — 5.2's PCA of the beat-averaged artifact
template is the same computation on a channels × channels covariance.

**Still open for Tier 5:** 5.2 (surrogate spatial filter) and 5.3 (the
evaluation). Morphology now varies, but every beat still shares one waveform
*family* per generator; a measured BCG template library (3.3) remains the
stronger footing for any claim that turns on artifact shape.

---

**Original plan:**

Supersedes 4.1 and 4.2 rather than following them; do the interim fix in 4.1
only if 5.1 is not being started immediately.

Model the BCG as several **distinct physical generators**, each with its own
timecourse, its own dipolar or geometric topography, and its own delay relative
to the R wave:

- **Head rotation / translation** about the cardiac axis — spatially broad,
  latest, largest.
- **Scalp and electrode motion over superficial vessels** — focal, localized to
  the vessel paths, earlier.
- **Aortic and carotid flow (Hall effect in the static field)** — deep, broad,
  and the component whose amplitude should scale with field strength.

Spatial rank then emerges from physiology rather than being asserted, and the
model gains a real handle on field strength — a 1.5T versus 3T versus 7T
parameter that is currently just an amplitude scalar.

**Also needed:** morphology that varies beat to beat, not just amplitude and
latency. The README already names the fixed waveform as a limitation; it becomes
a confound the moment PCA-based and ICA-based methods are being compared, since
they differ precisely in how they handle shape variability.

**Effort:** medium-large. **Blocks:** everything else in Tier 5.

#### 5.2 The surrogate spatial filter

**Status (2026-08-22): complete for PCA-S.** `eva-simulate correct` builds the
brain surrogate basis, extracts artifact topographies, forms the spatial filter,
and writes a corrected recording that `score` consumes directly, so the whole
loop is `generate → correct → score` against known truth.

**Measured with the iterative mode:** broadband SNR **2.45 ± 0.57** at 0 mm and
**2.76 ± 0.54** at 40 mm against a known generator BCG (uncorrected ~1.14),
with 4 artifact components at the paper's 0.5% variance threshold. The unattended
paper mode is much weaker here (**0.82 ± 0.16** and **1.01 ± 0.12**) because its
deterministic representative candidate accepts only ~9% of beats. That is a
result to report, not hide by calling the iterative extension "the paper mode."

**The optimum matches the artifact's true rank, which cross-validates 5.1.** A
component sweep gives SNR 1.45 / 2.35 / 3.00 / 1.58 at k = 2/3/4/5. The
generator BCG has spatial rank 4, and k=4 is the optimum; the fifth component
carries about 1% of template variance and is ongoing EEG, so removing it costs
more than it recovers. Two independent pieces of the model agreeing on 4 is
stronger evidence than either alone.

**Template quality is the binding constraint, and it is now quantified for the
iterative extension.**
Broadband SNR by recording length at 250 Hz: 0.99 at 60 s, 2.81 at 120 s, 2.48 at
240 s, 2.47 at 480 s. Below roughly 70 accepted beats the template retains enough
EEG that its lower components are brain activity rather than artifact, and the
correction is *worse than doing nothing*. This is a real property of the method,
not a defect of the implementation, and it is the kind of thing the harness
exists to measure.

**Implementation notes worth keeping.**

- The pattern search is now an explicit choice. **`paper`** matches every epoch
  once against one representative beat. `--representative-beat N` records the
  operator's one-based choice; without it, median energy is a deterministic
  unattended stand-in. **`iterative`** starts from the all-beat average and
  performs two refinement passes. It is much more robust on simulated data, but
  it is an extension and must not be attributed to the paper.
- The filter is built by **partialling out the unpenalized artifact block**
  rather than inverting the combined Gram. `[brain | artifact]` has more columns
  than channels, so its Gram is singular by construction, and with zero
  regularization on part of the diagonal no truncation rescues it — the first
  attempt produced filters that *inverted* the topographies they were meant to
  preserve. Solving for the free block first leaves `Bᵀ M B + λI` with λ positive
  on every column, which is positive definite and needs no truncation.
- Brain columns are **normalized to unit norm** before combining. Lead-field
  entries are in µV/(nA·m) and artifact topographies are unit vectors; without
  normalization a regularization expressed as a fraction of the brain block means
  something entirely different to each block.
- The brain basis reaches to **0.95 of the brain radius** — past the 0.85 the
  simulator places sources at. A basis that stops short cannot describe
  superficial topographies without large coefficients that the regularization
  then suppresses.
- The filter is built in the **recording's own reference**, read from the truth
  sidecar (roadmap 4.6). An average-referenced lead field against
  infinity-referenced data is not a subtle degradation.

**Guard against the 5.3 trap, in the output.** The report records the distance
from each surrogate regional source to the nearest simulated source (15.9 mm
minimum in the runs above). A surrogate basis sitting on top of the simulated
sources would fit the brain activity perfectly and rig the comparison; the number
is printed so a reader can check rather than trust.

**Self-tests (90 total, 0 failures):** the eigensolver reconstructs its
input and returns orthonormal vectors; the brain model reproduces real dipole
topographies (1.000 unregularized, 0.995 at 2%); a whole artifact-free recording
survives the filter at residual SNR 21.9 — measured as SNR, not correlation,
because correlation is scale-invariant and cannot see a filter that preserves
shape while shrinking amplitude; and end-to-end separation improves SNR by at
least 1.8x at the artifact's true rank. A separate check pins both pattern modes,
the paper representative candidate, and deterministic repeatability.
The correction-contract regression additionally proves that PCA-S reconstructs
the input MFF montage, reuses truth shell radii and lead-field truncation, copies
the exact `coordinates.xml`, and preserves ECG/motion PNS samples, names, rate,
and polarity convention. A geometry-free input is rejected unless the caller
explicitly opts into the built-in standard-montage approximation.

**Still open:** **ICA-S**. It differs from PCA-S only in where the artifact
topographies come from, so the filter machinery is already in place — and the
Gram-Schmidt step in `spatialFilter` is what makes it work, since ICA
topographies, unlike PCA ones, are not orthogonal.

The solver is nearly free: `EVA/ICA/ICAArtifactDetector.swift` is a
`nonisolated enum` depending only on Accelerate, Foundation and `MFFSignalData`,
all of which EVASimulate already links, and Extended Infomax — the paper's
algorithm — is among its solvers.

What is missing is **component selection**, which the paper does by eye. See
**5.4**: rather than inventing a heuristic threshold, use the simulator's known
generator topographies to produce graded ground-truth labels and train a
labeller that plugs into EVA's existing ICLabel infrastructure. Do not build a
hand-rolled beat-correlation criterion first if 5.4 is being done — it is the
heuristic 5.4 replaces.

A fair evaluation also depended on the non-stationarity work, since stationary
Gaussian sources satisfy ICA's assumptions artificially well; 1.3 has landed, so
that is no longer a blocker — but the comparison now rests on how well our
bursts, OU dynamics and microstates resemble real non-stationarity, which is a
modelling assumption to state rather than assume. Also open: the method is implemented in
EVASimulate rather than in EVA's own pipeline; porting it is a separate decision
with a much larger surface (UI, replay, history, serialization).

---

**Original plan:**

Implement the Berg & Scherg (1994) source-space separation the paper uses.

- A **brain surrogate basis**: 29 regional sources distributed through the brain
  compartment, each expanded to 3 orthogonal dipoles → 87 columns, built with one
  `SphericalForwardModel.leadField` call.
- **Artifact topographies** from either a PCA of the beat-averaged template
  (PCA-S; the paper keeps components above 0.5% of template variance, giving 4-8)
  or manually/automatically selected ICA components (ICA-S).
- The combined `[brain | artifact]` operator, inverted with **regularization of
  2% on the brain block and none on the artifact block**, per the paper.
- Back-projection to sensor space using the brain subspace only.

The template step needs the paper's spatio-temporal pattern search — a
representative beat selected once, then matched at a correlation threshold of
60% — which is also independently useful for EVA.

**Effort:** medium. **Depends on:** 5.1 for the comparison to be meaningful;
the filter itself can be written before it.

#### 5.3 The evaluation, and the trap in it

**Status (2026-08-25): complete except for dipole localization error.**
`eva-simulate evaluate-surrogate --config scenarios/aep-bilateral.json --with-erp`
runs the paper's evaluation across repeated seeds and reports every criterion as
mean ± SD. `--json` is a versioned result, not a summary stub: it includes the
resolved evaluation configuration, correction diagnostics, every per-seed value,
and mean/SD for broadband and every ERP criterion.

`eva-simulate evaluate-surrogate` runs repeated seeds across a swept condition
entirely in memory (8 seeds x 4 conditions in 16 seconds) and reports mean ± SD.

##### The headline finding: repeats are not optional

Across five seeds at one fixed configuration, corrected broadband SNR ranged
**1.39 to 2.53**. That spread is wider than most differences anyone would want to
claim between methods or conditions. Every single-run comparison made while
developing this item would have supported a confident and wrong conclusion.

Rusiniak et al. used 55 subjects. That was not incidental generosity; it is what
the variance demands. Any Tier 5 or 3.2 result must be reported as mean ± SD over
seeds, and the harness now prints the spread next to every mean and says so.

##### The trap is real but points the other way

The roadmap warned that a surrogate basis coinciding with the simulated sources
would rig the comparison in PCA-S's favour. **Measured, the opposite happens.**

Broadband SNR with the iterative search at 8 seeds per condition, 64 channels,
29 regional sources:

| basis offset | corrected SNR | uncorrected |
| --- | --- | --- |
| 0 mm | 1.82 ± 0.44 | 1.14 |
| 10 mm | 1.92 ± 0.46 | 1.14 |
| 20 mm | 2.08 ± 0.54 | 1.14 |
| 40 mm | 2.27 ± 0.53 | 1.14 |

And by basis richness, at 0 and 40 mm offset:

| regional sources | columns | SNR at 0 mm | SNR at 40 mm |
| --- | --- | --- | --- |
| 8 | 24 | 2.13 ± 0.53 | 2.45 ± 0.64 |
| 16 | 48 | 2.20 ± 0.61 | 2.44 ± 0.62 |
| 29 | 87 | 1.82 ± 0.44 | 2.27 ± 0.53 |
| 60 | 180 | 1.50 ± 0.32 | 2.08 ± 0.47 |

**A better brain model makes the artifact removal worse.** The mechanism follows
from 5.2: separation is bought entirely by the asymmetry between a penalized
brain block and an unpenalized artifact block. A richer or better-placed brain
model can represent the artifact too, so it competes for it and less is left to
the columns meant to carry it. `selftest` pins this deterministically — more of a
BCG generator topography survives the filter with 60 regional sources than with 8
— rather than resting on the seeded sweep, whose differences are close to its own
spread.

**Read this carefully.** It does not say the surrogate method is insensitive to
its brain model in general; it says that *on this simulator, at this channel
count, scored by broadband SNR against clean EEG*, a coincident basis does not
flatter the method. Scored instead by ERP distortion — what the paper actually
cares about — a brain model that absorbs artifact may well look different, since
the cost there is to the evoked response rather than to broadband residual. That
comparison needs the ERP criteria below.

##### The evaluation, with the bilateral AEP

The evaluation order now matches the paper: reject individual epochs, average
the accepted epochs, zero-phase filter the **completed average** at 0.3-30 Hz,
then baseline and measure. The earlier implementation documented this step but
did not perform it. A high-frequency regression check would fail if filtering
were again moved to only the epoch inputs.

8 seeds, 64 channels, 200 s, the `aep-bilateral` model over a generator BCG:

| condition | trials kept | ERP SNR | latency err | amplitude | explained var |
| --- | --- | --- | --- | --- | --- |
| uncorrected | 76.0 ± 1.6 | 2.96 ± 0.67 | -0.5 ± 2.6 ms | 1.11 ± 0.12 | 0.88 ± 0.10 |
| paper PCA-S, 0 mm | 61.8 ± 40.2 | 2.90 ± 0.91 | -3.0 ± 30.9 ms | 0.92 ± 0.64 | 0.80 ± 0.25 |
| paper PCA-S, 40 mm | 98.5 ± 1.9 | 3.54 ± 0.69 | -2.5 ± 12.6 ms | 0.83 ± 0.19 | 0.86 ± 0.15 |
| iterative PCA-S, 0 mm | 78.6 ± 2.5 | 3.44 ± 0.67 | +0.5 ± 1.4 ms | 0.99 ± 0.13 | 0.89 ± 0.13 |
| iterative PCA-S, 40 mm | 80.1 ± 2.5 | 3.67 ± 0.70 | +0.0 ± 2.1 ms | 0.97 ± 0.11 | 0.90 ± 0.13 |

Read with the spreads, not past them:

- **The iterative mode is the stable automated method.** It keeps about half of
  candidate beats and has tight trial-count/latency spreads. The paper-style
  unattended representative accepts only ~9%; at 0 mm that instability reaches
  the final ERP result. A manually chosen representative may improve it and is
  now expressible with `--representative-beat`, but must be recorded.
- **Iterative amplitude fidelity improves.** Uncorrected, the recovered N100
  peak is 11% too large; iterative correction reduces that to 1-3% while modestly
  improving trial retention and ERP SNR.
- **Topographic fidelity does not change.** Explained variance is 0.89 either
  way. This is not a failure of the correction — it is that averaging ~76 trials
  already suppresses an artifact that is not time-locked to the stimulus, so the
  uncorrected average starts out clean. The paper's large explained-variance
  gaps (97.3% for PCA-S against 90.3% for BSS) came from methods that actively
  *distort*; a method that does not distort has little room to show an advantage
  on this criterion.
- **Iterative correction does not add meaningful latency jitter here.** The
  post-filter errors remain within about 2 ms SD. Paper-mode instability is a
  different and much larger effect.

##### Remaining

- **Dipole localization error.** The paper fits free dipoles with Nelder-Mead and
  reports distance to the seeded positions. That needs an inverse solver, which
  is Tier 6 work (6.1-6.2). Explained variance addresses the same concern —
  topographic distortion — without one, and is the metric the paper leans on for
  its grand average.
- **ICA-S**, per 5.2.

**Self-tests (90 total, 0 failures):** explained variance is exactly 1.0
for data built from the model topographies and falls below 0.7 once a foreign
topography is added — both halves, since a metric that always returned 1 would
pass the first alone; and epoch rejection drops exactly the one trial carrying a
400 µV excursion, out of four candidates. The suite also pins the completed-
average filtering order and the two distinct pattern-search contracts.

---

**Original plan:**

Their four criteria map onto metrics we already have: accepted-trial count after
amplitude/gradient rejection; SNR as the ratio of post-stimulus to pre-stimulus
RMS; N100 peak latency and amplitude at Cz; and explained variance plus dipole
localization error against the seeded model over the FWHM window. `score-erp`
covers the third, and `SourceMetrics.locationScore` already does Hungarian
matching with axial orientation error, so left/right dipole ordering is a
non-issue.

**The trap: do not let the simulated brain sources live in the surrogate
basis.** If the 7 EEG dipoles sit at or near the 29 regional-source positions,
the surrogate model fits the brain activity perfectly and the comparison is
rigged in PCA-S's favour before it starts. The simulated sources must be drawn
from a distribution deliberately offset from the surrogate grid — and the
**degree of mismatch should be a swept parameter**. That sweep is arguably the
most interesting figure available here, and it is a question the original paper
structurally could not ask.

**The second trap: 1.3 decides PCA-S versus ICA-S.** ICA's assumptions are
satisfied artificially well by the stationary compatibility path. The completed
1.3 model makes the ICA-S arm possible, but that comparison must explicitly use
and sweep the opt-in non-stationarity controls rather than relying on defaults.

**Third:** their pipeline down-samples to 1 kHz after gradient removal, uses a
4-shell ellipsoidal head model, average reference, and Talairach coordinates.
The ellipsoid is not required, but the coordinate frame question from 4.3 is —
their dipole model cannot be entered without it.

**Effort:** medium. **Depends on:** 4.3, 5.1, 5.2, 1.3, and 3.2 for the sweep
machinery.

#### 5.4 A simulator-trained BCG component labeller

**Status (2026-08-25): pilot complete.** `BCGComponentLabeller` now extracts five
named, inspectable features from each recovered component: beat-template energy,
beat-to-beat template consistency, post-QRS prominence, lagged ECG relationship,
and the existing Heart result as a weak prior. It requires at least eight
*detected* `R Wave` events. Simulator beat truth is used only by tests, never by
the app. Scores compose with ICLabel in `ICAComponentSuggestion`; low scores
leave its label intact, while high scores produce a review-only `Heart BCG`
suggestion with the feature values in the explanation. Nothing is selected for
removal automatically.

The target is the specified graded projection onto the full BCG-generator span
versus the neural-source span, with redundant topographies removed by modified
Gram-Schmidt. The committed five-coefficient logistic model is regenerated and
pinned by the test suite from two training corpora spanning 1.5 T/20 channels
and 3 T/32 channels, different BCG amplitudes, physical-generator mixes,
morphology variability, neural source counts and seeds. A 7 T/24-channel
configuration with an unseen generator mix is held out entirely.
On that held-out case, the generic Heart prior's graded ranking concordance is
**0.2373**, versus **0.7797** for the beat-locked model. Feeding suggestions back
through EVA's ICA reconstruction improves broadband SNR from **0.9347** to
**1.8785**; because the residual is measured against the untouched clean EEG,
this score penalizes removal of neural signal as well as residual BCG.

`run-all-tests.sh` generates all three model corpora. Six focused tests cover
feature separation, the eight-beat safety gate, composition with existing class
probabilities, fitting to continuous truth, subspace truth, held-out ranking,
coefficient provenance, and the correction loop. This is still a simulator
prior, not a clinically validated classifier. Measured-template and real-scanner
validation from 3.3 remain the gate for stronger claims.

**Generalized by Tier 8**, which applies the same lever to ocular, muscle and
channel artifacts. This item is the pilot: do one class end to end here before
committing to the rest.

**The idea:** use the simulator to generate the one thing component
classification has never had — *ground-truth labels for ICA components* — and
feed them back into EVA's existing ICLabel infrastructure as a scanner-specific
BCG class.

This is the honest way to do ICA-S's component selection. The paper picks BCG
components by eye; an automatic substitute needs a criterion, and a criterion
invented by hand is just a heuristic with a threshold nobody can defend.

##### Why the simulator can do this and real data cannot

Real component labelling is supervised by *human judgement*, which is why ICLabel
was trained on crowd-labelled components and why its labels carry that
disagreement. The simulator has something better: it knows what it injected.

After 5.1, the BCG is four generators with known topographies; after 1.1, the
neural sources have known topographies too. So for any ICA decomposition of a
simulated recording, each component's **true** BCG content is computable, not
guessed: project its topography onto the span of the known BCG generators and
onto the span of the neural sources, and the ratio is a continuous
ground-truth "BCG-ness" — a *graded* target, not a binary label, which is
strictly more information than any human rater can supply.

That is the whole basis of the item. Everything else is machinery.

##### What exists already

More than expected, and the integration point is clean:

- **`ICLabelClassifier`** (`EVA/ICA/`) runs a Core ML model over seven classes —
  Brain, Muscle, Eye, **Heart**, Line Noise, Channel Noise, Other — from three
  features: an interpolated scalp image, relative PSD, and autocorrelation. It
  returns `[Int: ICAComponentSuggestion]`.
- **`ICAComponentAutoLabeler`** is the heuristic fallback when no Core ML model
  is present, with hand-built scalp (dipolarity, focality), time and spectral
  features.
- **`ICADecomposition`** already carries `labelSuggestions`, so a new labeller
  slots in beside these rather than replacing anything.
- **`ICAArtifactDetector.fit`** is a `nonisolated enum` depending only on
  Accelerate, Foundation and `MFFSignalData` — all of which EVASimulate already
  links. Extended Infomax, the paper's algorithm, is among its solvers.

**The gap worth naming:** ICLabel's "Heart" class was trained on ordinary
cardiac contamination recorded *outside* a scanner. BCG is a different
phenomenon — motion-induced rather than volume-conducted from the heart, an
order of magnitude larger, with a topography set by head movement in B0 rather
than by the cardiac dipole. There is no reason to expect the Heart class to
transfer, and **measuring how badly it transfers is itself a result** the
simulator can produce before any new model is trained.

##### Sketch

1. **Score ICLabel as it stands.** Run `ICAArtifactDetector.fit` over simulated
   recordings, compute the graded truth above, and ask how well the existing
   Heart probability ranks the genuinely BCG components. Cheap, and it decides
   whether the rest of the item is needed or merely nice.
2. **Add beat-locked features**, which is what the existing feature sets lack and
   what the paper's human rater was actually using: the component's
   beat-triggered average, its spatio-temporal self-consistency across beats
   (`SurrogateSeparation.spatioTemporalCorrelation` already does this), and its
   relationship to the ECG channel the simulator emits. All computable from
   *detected* QRS times, so nothing depends on ground truth at inference.
3. **Fit a classifier** on generated corpora spanning field strength, montage,
   BCG amplitude, and the generator mix — the parameters 5.1 made explicit.
   Keep it small and inspectable; a logistic model over a handful of named
   features is defensible in a methods section in a way a black box is not.
4. **Deliver it as an `ICAComponentSuggestion` producer**, so it works
   everywhere ICLabel already does, and ICA-S gets its component selection for
   free.
5. **Close the loop**: feed the labeller's selections back into 5.2's spatial
   filter and score with 5.3's criteria. That is the "back and forth" — the
   classifier is judged by whether the *correction* improves, not by
   classification accuracy on its own.

##### The circularity, stated plainly

A classifier trained on simulated BCG learns **our BCG model**, not BCG. If the
four generators are wrong in some respect, the classifier inherits the error and
then looks confident about it — and it would keep scoring well against the
simulator that taught it.

This is the same trap 2.2 flags for impedance-based channel rejection, and it
needs the same discipline:

- Treat simulator-derived thresholds as a **prior to be tested on real data**,
  never as a validated result.
- Hold out generator configurations at training time and report performance on
  the held-out ones, not on the ones fitted.
- **3.3 (measured template library) becomes load-bearing here.** A classifier
  validated against measured BCG templates from real scanners is evidence; one
  validated only against its own training model is an assertion.
- State in any write-up which BCG model produced the training corpus, with its
  parameters — `sim_truth.json` already records all of them.

##### Effort and sequencing

**Effort:** medium. Step 1 is small and worth doing on its own. Steps 2-4 are the
substance. Step 5 is nearly free once 5.2 and 5.3 exist, which they do.

**Depends on:** 5.1 (known generator topographies — without them there is no
graded truth), 1.3 (complete), and 5.2/5.3 for the closing loop. **Wants:** 3.3
for external validation, and Tier 7's corpus machinery, which is why this sits
after the 7.1-7.2 slice.

**Supersedes:** the hand-rolled beat-correlation criterion sketched in 5.2's
ICA-S notes. If this item is being done, do not build that first — it would be
the heuristic this replaces.

---


### Tier 7 — delivered pipeline regression (7.1-7.3)

#### 7.1-7.3 — DELIVERED

**Status (2026-08-25): complete.** Six short, generated cases run in the full
suite. Each uses committed generation arguments, known truth, a headless EVA
operation or detector, and a tolerance watermark:

    generate (locked-clock gradient) -> EVA processes headlessly -> score vs truth
    generate (drifting-clock gradient) -> aligned/subsampled MAS -> score vs truth
    generate (BCG + ECG) -> detect QRS -> correct BCG -> score detection and correction
    generate (oddball ERP) -> segment/baseline/average -> score peak recovery
    generate (recording defects) -> channel health + defect signatures -> score
    generate (artifact-free control) -> redundant CAR -> assert no harm

- **`Tools/EVASimulate/scenarios/regression-gradient-locked.json`** — zero clock
  drift, gradient only, no BCG or ocular activity, no defects.
- **`EVATests/Pipeline/PipelineRegressionTests.swift`** — drives
  `HeadlessBatchProcessor` with an `EVAProcessingScript`, scores the output
  against `sim_clean.mff`.
- **`EVATests/Fixtures/pipeline-watermark.json`** — the committed achieved value.
- **`run-all-tests.sh`** gains a `regression corpus` stage that generates into
  `.regression-corpus/` (gitignored). The tests **skip** when it is absent, so a
  bare `xcodebuild test` stays fast for someone working on unrelated code.

##### 7.3 completed corpus results

The four cases added after the first slice establish these initial regression
baselines:

| Case | EVA path | Recorded result |
| --- | --- | --- |
| Drifting-clock gradient | MAS, CPU, alignment + 10x subsampling | Broadband SNR **0.138567**. |
| BCG with QRS jitter | Pan–Tompkins ECG detection + 21-beat local MAS with AMRI preprocessing | Correction improvement **1.663343x**; event F1 **1.000**; timing MAE **1.138 ms**. |
| Oddball ERP | Headless segmentation, baseline and category average | Target peak amplitude error **4.383 µV**; latency error **8.0 ms**. |
| Recording defects | Channel-health ranking plus planted-signature checks | Bad-channel recall **1.000**; bridge correlation **1.000**; bad-reference common-mode RMS **30.699 µV**. |

The recording-defect case now has an explainable user-facing path. EVA's unified
Channels window groups persistent pairs using very high robust correlation and
near-zero differential RMS, with montage proximity as supporting evidence rather
than a hard gate. The Relationships inspector shows cluster membership, window
persistence, impedance, and RANSAC/neighbor-prediction context; Channel Health
deep-links to the selected pair. A separate recording-level Common-mode
Structure assessment uses common-mode RMS/variance fraction and broad,
same-signed leave-one-out channel loadings. It reads a declared type-1 physical
reference from MFF metadata, shows the acquisition and current processing
reference separately, and does not infer a named electrode when metadata is
absent.

The Reference tab performs a temporary average-reference comparison before
presenting elevated structure and explicitly explains that collapse toward zero
is an arithmetic consequence, not proof of a faulty physical reference. When an
MFF declares a reference sensor but omits its sample row, EVA reconstructs that
row as zero in the acquisition-reference space before taking the channel mean;
the resulting rereferenced channel is added to the signal, scalp layout, and
Channel Sets context while the original recording remains unchanged.
The Channel Sets editor now uses the same native three-pane organization as the
diagnostic tabs: a macOS source list, a dedicated scalp-map canvas, and a
right-side inspector for set identity, symmetry, save, duplicate, export, and
delete actions. Net filtering and catalog-wide import/export remain in the
source-list controls rather than competing with per-set editing.
Opening Channels now also starts Channel Health automatically when the focused
signal revision has no current results. A completed result is reused, tab
switches do not restart the scan, and Refresh remains available for a forced
rerun. Opening a channel's Health popover likewise runs relationship analysis
for that exact signal revision. While it runs the popover says so; afterward it
either shows the flagged persistent pair or explicitly reports that no pair
crossed the review threshold, including the strongest evaluated partner and its
median correlation. Relationship findings remain contextual and do not change
the Channel Health percentage.

Both diagnostics remain explicitly review-only. Synthetic exact bridges, scaled
copies, non-neighbor duplicates, common-mode contamination, and clean controls
are regression-tested, but thresholds still need real-recording calibration.
Pair overlay/difference traces and explicit mark/exclude actions remain the next
UI follow-up before any automated repair.

##### 7.3 clean control

The second case derives an artifact-free recording from the locked-gradient
scenario using `--no-gradient`, `--with-bcg --bcg-amplitude 0`,
`--no-impedance`, and `--no-impedance-noise`. Zero BCG amplitude keeps the EEG
clean while BCG timing still produces ECG and motion PNS streams, because
preservation of auxiliary signals is part of the pipeline contract even when
the EEG needs no correction.

The simulator's clean EEG is already common-average referenced. The test runs an
empty filter stage followed by a second continuous common-average reference;
that operation is analytically idempotent, so this is a meaningful pipeline and
not merely an MFF copy test. The calibrated result is:

- broadband clean-versus-output SNR: **38,014,060.1955**;
- RMS amplitude ratio: **1.0000000000**;
- maximum absolute sample error: **0.0000038147 µV**.

The test enforces analytic bounds of 1 ppm on RMS amplitude and 0.0001 µV on any
sample, plus a tolerance watermark for drift. It also verifies channel names,
event codes, exact PNS samples and polarity, byte-identical `coordinates.xml`,
and the recorded filter/reference provenance in `eva.xml`.

##### The analytic anchor paid off immediately

This case was chosen because its best possible result is known in advance rather
than merely observed. A mean template over 8 donor volumes ceilings at
`sqrt(9) = 3.00`; a median is less efficient by `sqrt(pi/2) = 1.253`, predicting
about **2.39**. The pipeline delivered **2.4701**.

Theory and implementation agreeing to that tolerance is worth more than the
number itself: it means the floor is anchored to something real, and it validates
the √N reasoning the README has carried since the beginning.

##### Three assertions, each doing a different job

1. **Floor** — 15% below the watermark. The regression check proper.
2. **Ceiling** — `sqrt(N+1) x 1.02`. The previous 25% allowance was so large that
   meaningful information leakage could pass. Two percent is reserved for
   floating-point and estimator details; a score above it means the correction is
   using information it should not have. On a simulated recording, with the clean
   signal sitting in the next directory, that is a real possibility an end-to-end
   harness would otherwise conceal.
3. **Watermark** — an improvement above 15% fails too, with instructions to
   re-record. A floor alone hides slow drift: a number can fall from 6.2 to 4.1
   over years without ever tripping a floor of 4.0.

**All three were verified to fire**, by moving the watermark up, moving it down,
and temporarily lowering the ceiling. An assertion nobody has seen fail is
decoration until proven otherwise — and the ceiling in particular would never
fire in normal operation.

##### Decisions worth keeping

- **CPU backend is pinned.** Metal and CPU agree only to a tolerance, CI machines
  have no usable Metal device, and a watermark recorded on one backend would fail
  forever on the other. GPU/CPU agreement has its own dedicated test.
- **Alignment and upsampling off.** This case is about template subtraction with
  locked clocks; interpolation would put a second mechanism between input and
  score.
- **The corpus is generated, never committed.** No binary blobs in git, and the
  generator/pipeline seam is exercised rather than frozen. It is also covered by
  `check-determinism.sh`, so the regression input is itself reproducible.
- **`EVAHelper` was evaluated and rejected** as the runner: it is a fixed AAS+CWL
  pipeline requiring PNS channels, with no AAS-only path, so it could not give
  the clean case whose value is analytically known. `EVAProcessingScript` through
  `HeadlessBatchProcessor` takes an arbitrary pipeline, which is why 7.1 chose it.

##### Next for Tier 7

- The method is a one-line constant in the test. **`AllenAAS`, once it lands**,
  is a natural second case — and a *mean* template would restore the exact
  `sqrt(N)` anchor that MAS's median blurs.
- 7.4: record the six scores on a second machine and tighten or widen only the
  tolerances that demonstrate real cross-machine movement.
- 7.5: stage the corpus in GitHub Actions after 7.4, keeping UI tests excluded.
- Dedicated bridge and bad-reference diagnosis would strengthen the recording-
  defect case, but it is an EVA health-feature follow-up rather than missing
  corpus coverage.

---

**Original plan:**

#### 7.1 Where the suite lives

**In `EVATests`, not in a new tool.** A separate batch runner would be a fourth
way to describe a pipeline, alongside `EVAProcessingScript` XML, `EVAHelper`'s
flags, and `HeadlessBatchProcessor`'s in-process API. Putting the suite where the
headless processor already lives means it rides `xcodebuild test`, which
`run-all-tests.sh` already runs, which CI already runs. No new binary, no new
configuration format, no new CI stage.

**The generation wrinkle.** EVASimulate is a separate command-line tool, and
EVATests runs under sandbox restrictions that make writing generated packages
from inside a test awkward. The clean split:

- `run-all-tests.sh` gains a stage that generates the regression corpus into a
  temporary directory and exports its path in an environment variable.
- The tests read that variable, and **skip cleanly when it is absent**, so a bare
  `xcodebuild test` stays fast and green for someone working on unrelated code.
- The corpus is regenerated every run rather than committed. No binary blobs in
  git, and the generator/pipeline seam is exercised rather than frozen.

#### 7.2 What to assert — the part that decides whether this works

Suites of this kind die one of two deaths. Assert exact values and every
legitimate improvement breaks the build until somebody mutes it. Assert loose
bounds and nothing is ever caught. The way out is that **we have ground truth**,
so assertions can be about meaning rather than about bytes.

**Never hash EVA's output.** See 7.4.

##### Metric floors

Each corpus entry declares what its pipeline must achieve, scored against truth:

- **Broadband and per-band SNR floors** after gradient and BCG correction.
- **Spectral fidelity** — corrected band power within a stated percentage of the
  known clean spectrum. This is what makes *over-filtering* visible, and it is
  the failure a naive SNR floor will happily pass.
- **Detection quality** — F1, sensitivity and timing error for BCG beats and TR
  markers, scored by `score-events` against the event times already in the
  sidecar.
- **ERP recovery** — amplitude and latency bias against per-trial truth, which
  1.2 and 4.8 already emit (use the non-overlapping subset via
  `--exclude-overlap`).
- **Per-channel floors**, so one destroyed channel cannot be averaged away by a
  broadband number that still passes.

##### The √N ceiling as an *upper* bound

The README establishes that naive average-artifact subtraction has a ceiling of
`std(EEG)/sqrt(N)` — a "perfect" AAS on 20 volumes scores SNR 4.47, not infinity.
That makes an upper-bound assertion available, and it is worth more than it
looks: a result that scores *above* the ceiling is either doing something
genuinely smarter or **leaking ground truth into the correction**, and the second
is precisely the bug that an end-to-end harness would otherwise conceal. Assert
both sides.

##### The watermark file

Floors alone hide slow drift: a number can fall from 6.2 to 4.1 for years and
never trip a floor of 4.0. So alongside the floors, commit a **watermark file**
recording the *achieved* value of every metric — the same shape as
`determinism-baseline.txt`, but with tolerance rather than equality.

- A meaningful change shows up as a reviewable diff, the way the determinism
  hashes do.
- Improvements are visible instead of silent, which is the point: "wavelet
  reduction improved alpha fidelity from 94% to 98%" is a fact worth having in
  the commit history.
- Regeneration is deliberate and its own commit, and that commit is the record
  that pipeline behaviour changed.

Tolerance bands need to be wide enough to absorb float-level differences across
machines (7.4) and narrow enough to catch a real change. Start generous, tighten
as the numbers prove stable.

#### 7.3 The corpus

The point of a corpus rather than one recording is that different scenarios fail
in different ways. A reasonable starting set, all short — 60 s is enough:

- **Locked-clock gradient.** The case where template subtraction should cancel
  exactly, so the score is compared against the √N ceiling. The most sensitive
  entry in the corpus.
- **Drifting-clock gradient.** The realistic case, with the paper's 152 µs/s.
- **BCG with QRS detection jitter.** Separates timing-dependent methods (AAS and
  relatives) from ones that do not use beat timing. The truth sidecar's separate
  true and *detected* beat times are what make this scoreable at all.
- **Oddball ERP under noise.** Scores `EVA/Trials/` and
  `SingleTrialAnalyzer.swift`, which have no ground truth today.
- **Bad channels, bridging, and a bad reference.** Detection metrics rather than
  correction metrics — scoring whether EVA *finds* the defect it was told about.
- **Clean control.** No artifact at all. Asserts that the pipeline does not
  damage a recording that needed no correction, which is a real regression class
  and one no artifact-focused entry can catch.

Each entry pairs a committed generation recipe — a scenario plus any explicit
CLI overrides — with an `EVAProcessingScript` in the tests. Both sides are
therefore reviewed and versioned. Reuse the shipped `scenarios/` where they fit
rather than duplicating configuration.


### Tier 8 — delivered (8.1)

#### 8.1 Benchmark the labellers we already have — do this first

**Status (2026-08-25): complete.** A 60-second mixed recording is generated by
the Tier 7 corpus stage with five neural dipoles, ocular dipoles, four BCG
generators, three EMG regions, 60 Hz line noise, impedance coupling, and two bad
channels. EVA fits one Picard-O decomposition and feeds that exact decomposition
to both labellers. The benchmark derives each component's graded membership from
the squared correlation of its scalp map with every known class subspace;
membership is normalized rather than forced into a one-hot label.

`ICAComponentAutoLabeler` normally prefers ICLabel and uses its transparent
rules only as a fallback. Scoring that combined wrapper against ICLabel would
therefore duplicate ICLabel whenever the model labels every component. The
benchmark exposes and scores the heuristic branch independently, which is the
meaningful comparison while leaving production fallback behaviour unchanged.

Initial per-class F1 baselines:

| Class | ICLabel | EVA heuristic |
| --- | ---: | ---: |
| Brain | 0.213 | 0.213 |
| Muscle | 0.186 | 0.335 |
| Eye | 0.000 | 0.000 |
| Heart | 0.096 | 0.00009 |
| Line Noise | 0.106 | 0.304 |
| Channel Noise | 0.000 | 0.170 |
| **Macro F1** | **0.100** | **0.170** |

These are deliberately reported as a baseline, not as external validity. They
combine decomposition failure, simulated-to-real domain mismatch, and labeller
error; 8.4 is what will separate the first from the other two. The important
result for sequencing is that the weakness is not Heart-only: Eye is missed by
both paths and ICLabel also misses Channel Noise in this mixed case. That argues
for keeping Tier 8, beginning narrowly with 5.4 rather than training all classes
at once.

The evaluator, full per-component graded truth records, per-class
precision/recall/F1 structures, and tolerance watermarks live in
`EVA/ICA/ICAComponentLabellerBenchmark.swift` and
`EVATests/ICA/ICAComponentLabellerBenchmarkTests.swift`.

**Original rationale:** before training anything, score **ICLabel** and
**`ICAComponentAutoLabeler`**
against graded truth on simulated recordings, per class.

This is cheap, it needs no new model, and it is a result on its own: nobody has a
per-class, graded-truth benchmark for these labellers, because nobody else can
make one. It also decides how much of the rest of the tier is warranted — if the
existing labellers are already strong on ocular and weak only on Heart, then 5.4
is the whole job and Tier 8 collapses to a paragraph.

That conditional did not hold in the first mixed corpus: the gaps span several
classes, as the completed results above show.

Expect the Heart class to do poorly: it was trained on cardiac contamination
recorded *outside* a scanner, and BCG is a different phenomenon (see 5.4).

**Effort:** small. **Do this before committing to anything else here.**

---

# 9. RSA

Nothing shipped. The interchange contract and estimator design are in
[`docs/design/rsa.md`](docs/design/rsa.md); the phases are in `ROADMAP.md` § RSA.

The assets RSA would build on — epoching, category averaging, channel ROIs,
cluster statistics, and the figure/export basket — are recorded in
[§5](#5-epoching-averaging--trial-wise) and [§10](#10-ui-figures--export).

---

# 10. UI, Figures & Export

### C4. App/window stability fixes — completed 2026-08-15

- Corrected cold-launch Finder double-window behavior while preserving real
  multi-window support.
- Injected required environments/model container into the Batch scene.
- Moved Batch Process to the Window menu.
- Removed broken UUID-based frame autosave and returned persistence to the
  platform.
- Replaced the stale focused-value Channel Set mirror with explicit publication
  on load, role edits, and main-window focus.
- Added File → New Window and made multi-file combine discoverable.
- Deferred the harmless post-close Finder stray-window case pending demand.


### C6. Physical display and export scales — completed 2026-08-13

- Added nominal µV/mm and mm/s readouts, typed entry, clinical presets, and
  portable physical-unit defaults.
- Unified scale constants, used the real sampling-rate-dependent display stride,
  and fixed raster export metadata at 144 dpi.
- Added exact figure-scale calculation for vector PDF output.
- Deferred per-display calibration and row-height-independent sensitivity to
  UI-1, where they belong.


### C7. Figure Composer Phase 1 — completed 2026-08-14

- Added “Add to Export” to figure menus.
- Added a session-wide basket with thumbnails, reorder, and removal.
- Added vector PDF contact-sheet export in Letter and square layouts with
  automatic page wrapping.


### C9. Feature work landed since 2026-07-13

- Wavelet reducer/explorer, empirical-Bayes thresholding, and Metal backend.
- Metal gradient/local-template compute and FASTR fixes.
- PICARD-O ICA.
- RIDE and Woody single-trial alignment plus time markers.
- Persyst and BESA `.avr`/`.mul` importers and manual physio text import.
- Pan–Tompkins, Hamilton, WFDB, Wavelet, and Christov cardiac detectors.
- True iterative sub-sample gradient alignment on CPU and Metal.
- Display-scale preferences, File → Import Physio, figure export basket, and
  Channel Set catalog.
- Licensing notices, clean-room provenance, release notes, and paper drafts.


---

# 11. Batch, Replay & Provenance

### C2. Processing and batch core — completed 2026-07-04; parity closed 2026-08-13

- Added view-independent `ProcessingCore` sequencing for filter, MRI gradient,
  threshold detection, wavelet reduction, and PSA.
- Added headless batch processing, windowed fallback, replay compatibility, and
  shared MFF export.
- Unified interactive/headless PSA in `EpochingViewModel.buildAndPostProcess`.
- Threaded electrode geometry through headless PSA, centralized globally bad
  escalation, and fixed the discarded escalated-signal result.
- Achieved byte-identical `signal1.bin`, `categories.xml`, and `epochs.xml` in the
  controlled paired run; seeded SME removed the remaining metric randomness.
- Added shared invalidation, processing audit logs, authoritative file type,
  category-group serialization, and build-version provenance.


### C3. REWIND foundation — completed 2026-08-15

- Built content-addressed `EVAHistory`, canonical-chain adoption, snapshots,
  navigation, back/forward transport, branching display, and history seeding from
  an on-disk `eva.xml` prefix.
- Added ICA and artifact payloads plus channel-decision steps.
- Added `LatestOnlyRunner`, deterministic async tests, and consolidated progress
  in `OperationProgressCenter`.
- Added multi-window ownership and forking to a new window.
- Made continuous/epoch reference and baseline correction explicit processing
  operations rather than hidden booleans inside filter/segment.
- Fixed navigation state restoration, stale segment-health display, regex-only
  segment omission, and multiple parameter-serialization gaps.

The remaining validation and re-derivation work is intentionally separated into
active milestone RW-1; it does not make these foundations “not done.”


### C12. RW-1 — REWIND hardening — completed 2026-08-27

The bounded correctness/validation pass that made the app boundary safe for
a new derived-signal stage. All sixteen audit items are closed; the canonical
decisions below remain the reference for any work that touches history,
replay, or invalidation. `REWIND.md` is the detailed design archive.

The history foundation is built; do not reopen its architecture. This milestone
is a bounded correctness/validation pass so `bcgCorrection` can join a reliable
pipeline. `REWIND.md` remains the detailed design record.

#### REWIND consistency audit — prioritized TODOs (2026-08-25)

These are ordered by correctness risk, then by user-facing coherence. Several
replace stale items in `REWIND.md`: evicted-node re-derivation already exists,
history is linear within one window, and A/B alternatives are explicit window
forks rather than persistent sibling nodes.

1. [x] **Make on-disk-prefix navigation safe — completed 2026-08-26.**
   `RecordingHistoryModel.reDerivationSource(for:)` is now the single rule for
   what a snapshot-less node may be rebuilt from: the loaded signal is the
   on-disk prefix's *output*, so only the steps after the prefix are replayed,
   and a node at or inside the prefix (or one whose lineage does not lead with
   the prefix) is `.unavailable`. Unreachable rows render greyed with an
   explanation instead of offering a click, and their Fork menu is withheld;
   `undoSegmentationTarget` now asks the same `isReachable` question every other
   entry point does. This also fixed a quieter half: a *live* node in a
   processed file previously replayed the on-disk steps too. Covered by
   `HistoryReDerivationSourceTests`, including the numeric premise that a second
   filter application really does change the samples. The pre-prefix source
   cache is deferred to item 11's cache policy.
2. [x] **Make re-derivation latest-only and commit-safe — completed 2026-08-26.**
   Rebuilds run through `RecordingStore.historyReDeriveRunner`
   (`LatestOnlyRunner`), so a superseded run publishes nothing and cannot clear
   a newer run's spinner; a new snapshot-less click cancels the previous task,
   and closing the recording cancels and disowns it. The derivation itself moved
   into a `deriveSnapshot` helper that only *returns* a snapshot — the commit is
   a separate block that re-checks the recording name, the source signal's
   `dataRevision`, the node's continued existence, and the history model's
   identity before moving the window, and says so when it discards a late
   arrival.
4. [x] **Finish channel-decision identity and carry-through — completed
   2026-08-26.** Four answers:
   - **Position vs application order.** `markBad` stays where
     `ChannelDecisionSteps` writes it and carries `scope: ambient`;
     `ProcessingCore` applies every mark *before* the walk, since wavelet,
     referencing, and PSA all consult the final bad set and can precede that
     position. Moving the step to the front of the script was rejected: a
     mid-session bad mark would then change the first node and discard the whole
     content-addressed lineage, snapshots included.
   - **Interpolation inputs are re-solved, not persisted.** The donor recipe is
     a pure function of electrode positions and the ambient channel state, both
     already recorded, so `ChannelInterpolationSolver` is now the single
     implementation behind the click, replay, batch, and re-derivation — and
     re-derivation no longer refuses a path containing an interpolation when the
     package has geometry. No new sidecar.
   - **Epoch caches move together.** The averaged `epochedSignal` and the
     pre-average `segmentedEpochSignal` are patched all-or-nothing; patching
     only the averages left Single Trial Analysis reading the unrepaired
     channel.
   - **Failure is explicit.** An unsolvable repair drops any replacement
     samples, returns the channel to bad, and records `interpolationLost` —
     surfaced in the channel row (its own badge and a retry), the status
     history, and an `interpolateChannels lost:` audit-log line.
   Parity is covered by byte comparison in `PairedValidationTests`.
5. [x] **Complete the paired validation and impossible-state instrumentation —
   completed 2026-08-26.** `PairedValidationTests` compares interactive against
   headless by sample equality for `markBad` (including the ambient rule above),
   channel interpolation, ICA replay driven through `ProcessingCore`, and
   continuous and epoch referencing — each paired with a test proving the thing
   being compared is observable at all, so none of them can pass vacuously.
   Artifact-template re-derivation and payload-level ICA replay were already
   byte-compared in `ArtifactReplayPayloadTests` and `ICAReplayPayloadTests`
   and are referenced rather than duplicated. Gradient motion is compared on the
   volume-exclusion set its parameters drive rather than on corrected samples:
   the repository carries no MRI fixture with TR markers, and that set is the
   decision the parameters actually make. `PayloadConsistency` now checks script
   against sidecars in both directions at the two moments both are in hand — the
   export audit log records any disagreement, and opening a package surfaces the
   unexplainable direction (a payload with no step) in the status line.
6. [x] **Commit threshold edits deliberately — completed 2026-08-26.** It was
   the zero-state end of that range: `ProcessingChainSignature` carries no
   parameter values and threshold detection produces no signal, so a retuned
   detector never reached the history at all. `ArtifactViewModel`
   `.thresholdConfigCommits` is bumped once when the ocular threshold sheet
   commits (Done, Restore Defaults, or dismissal) and is the signature's only
   count-valued term, so a drag mints nothing and a commit mints one node.
   Navigating to a threshold node now also restores its blink/movement
   configurations, so the detector re-runs off the values that node's hash was
   built from. Covered by `ThresholdConfigCommitTests`.
7. [x] **Represent “resolved from this file's payload” in replay policy —
   completed 2026-08-26.** `ReplayInteraction` gains `.resolvedFromPayload`, and
   `EVAProcessingStep.replayInteraction(given:)` classifies against a
   `ReplayPayloadAvailability` describing *the file being processed* — ICA and
   artifact sidecars, and electrode geometry. The rule that lived privately in
   `BatchSetupSheet` (and, differently, inside `ProcessingCore`) is now one
   function every path asks. Channel decisions were the real divergence, not a
   labelling problem: headless batch applied the source recording's bad-channel
   list to every file while windowed replay ignored the step entirely. Both are
   now `.decision` — windowed replay pauses on
   `ChannelDecisionReplaySheet`, which lists the carried channels, flags the ones
   this file cannot honour, and applies only what the operator keeps; batch
   cannot ask, so the steps start **unchecked** and applying them is a
   deliberate tick. BCG detection stays inert (2026-08-26 decision) and is
   carried in F-1's detector work.
8. [x] **Make the snapshot policy truthful — completed 2026-08-26.** Four
   promises, each now kept or withdrawn:
   - **Supported-step matrix** is one pure function on the model
     (`RecordingHistoryModel.firstNonReDerivableStep`), folded into
     `reDerivationSource(for:availability:)` so a node that cannot be rebuilt —
     BCG anywhere on its path, ICA without this file's sidecar, interpolation
     without geometry — is greyed with a reason *before* the click instead of
     failing after it. The rule reads the same `ReplayPayloadAvailability` the
     replay engine classifies with (item 6).
   - **Pin is wired** into the row menu and exempted during eviction — and
     **capped**: pinned snapshots may hold at most `pinnedByteShare` of the
     budget, because an unlimited exemption is a way to switch the budget off by
     accident. A refused pin says what is already held and what the ceiling is.
   - **The budget is visible** in the History tab footer (`420 MB of 1.5 GB
     cached · 6 of 24`), so eviction stops being invisible.
   - **`computeCost` is measured or absent.** Re-derivation times itself and
     records the result; a row offers a duration only when one was measured, and
     there is no fast/slow guess from a table of stage names.
9. [x] **Choose the real Queue/History contract — completed 2026-08-26.** The
   two tabs are adjacent views, and now say so: Queue is “what is running now,
   and what it has reported”, History is “the steps that produced the signal on
   screen” (`ProcessingStatusTab.summary`, surfaced on each tab). No node
   lifecycle is shared between them — a node never appears in Queue, and a
   running operation is not a node until it has produced something. Queued,
   dependency, and speculative node states stay unbuilt; `REWIND.md`'s lifecycle
   design is relabelled as the starting point *if* full-rate background rebuilds
   are ever built, not as pending work.
10. [x] **Finish the minimum Mac history surface and trim aspirational UI —
   completed 2026-08-26.** ⌘Z / ⇧⌘Z route to back/forward through a focused
   scene value (`HistoryTransportCommands`), replacing the standard Edit-menu
   pair; the items name the step they act on — “Undo Filter”, not a bare “Undo”
   — and are disabled rather than hidden when no recording window is focused.
   Undo stays *navigation*, never an appended inverse.
   The row menu is settled at three actions: Fork to New Window (shipped),
   Pin/Unpin (item 7), and Rename. **Delete future, reopen stage, and
   export/report from node were dropped, not deferred** — delete-future is
   already what applying a divergent action does, and offering it separately
   would be a second way to destroy work; reopen-stage is a restore-the-sheet
   feature far larger than a menu item; per-node export belongs with F-1's
   reports. `REWIND.md`'s interaction section now matches.
11. [x] **Define A/B comparison around related forked windows — completed
    2026-08-27.** The old "select two sibling nodes" prerequisite was
    unbuildable by design: one window's history is linear, so two siblings only
    coexist while one is an unreplaced redo branch. Windows are the unit
    instead. Each window carries a comparison group; forking copies the
    parent's, so an experiment is exactly the set of windows descended from one
    original (`PendingWindowForks.Payload.comparisonGroupID`). Windows publish a
    value snapshot — identity, current node, lineage tip, live signal, channel
    and health state — to `WindowComparisonRegistry` from the call sites that
    already fire on signal change, and unregister on close, so a compare sheet
    can never reach a signal a closed window has released.
    `SignalComparison` does the measurement: channels matched **by name** where
    both sides have names (positional matching silently compares the wrong rows
    after an interpolation or an import that reordered them), samples truncated
    to the shorter side, a sampling-rate mismatch refused rather than resampled,
    and everything dropped from the comparison named in the result. Per channel:
    RMS and max difference, correlation, and change relative to A; plus overlay
    and A − B traces for the selected channel and a side-by-side health column.
    `CompareWindowsSheet` opens from the History footer beside Fork to New
    Window. **Independently opening the same file relates the windows without
    warning:** it is offered for comparison and labelled "same file, opened
    independently", because two windows on one file is supported, a modal would
    teach nothing, and refusing the comparison would refuse the operator's
    actual question — what must not happen is the sheet claiming a shared
    ancestor it cannot prove. In-place waveform overlay across two windows was
    deliberately not built: viewport, montage, and display scale are independent
    per window, and syncing them is a far larger feature than the measurement.
    Covered by `SignalComparisonTests` and `WindowComparisonRegistryTests`.
12. [x] **Decide portable history versus session cache — completed
    2026-08-27.** Three decisions and one implementation.
    - **Export carries the current lineage, and only that.** `eva.xml` already
      records the steps that produced the bytes; a second portable history file
      would be a second source of truth that can disagree with it, and the only
      thing it would add is abandoned redo branches — session state, not
      provenance. No `eva_history.json`. Node annotations (labels, pins) stay
      machine-local for the same reason.
    - **There is no on-disk snapshot cache, and none is planned.** Snapshots
      live in memory under item 7's byte budget; re-derivation is the fallback,
      and it is exact. If a disk tier is ever justified by measurement, its
      staleness rule is fixed in advance: cheap source metadata (mtime + size),
      plus a build and compute-backend stamp so a snapshot derived on GPU or a
      different Accelerate version is not trusted on an incompatible machine —
      and deleting the cache may cost only speed. Item 1's deferred pre-prefix
      source cache closes under this: interior nodes of an on-disk prefix stay
      non-navigable, which is already the shipped behaviour.
    - **External inputs get the staleness rule now, because one already
      mattered.** Motion parameters are the one correction input that lives
      outside the package, and nothing recorded *which* file was used — so
      replaying a gradient step against a different or edited motion file
      produced different censored volumes under an identical history node.
      `MotionSourceFingerprint` (name, size, modification time, and row count
      *after* any trim) is recorded in the step's parameters, compared on
      restore, and reported both in the Motion panel and in the export audit
      log. Cheap metadata, no content digest, consistent with the no-expanded-
      hashing decision. Covered by `GradientViewModelTests`.
13. [x] **Make forks reliable for non-MFF imports — completed 2026-08-26.** The
    security scope is preserved, and no normalized cache was needed.
    `MFFRecording` already accepted `securityScopedURLs` and the BrainVision open
    path already threaded the folder scope through; the *fork* dropped them —
    `PendingWindowForks.Payload` carried only `packageURL`, so the claiming
    window re-read a header whose `.vmrk`/`.eeg` it had no access to, and failed
    to load a file the source window had open. The payload now carries the
    scopes. They are process-wide and refcounted, so handing the same URLs to
    the second window is the whole fix: no bookmark round-trip, and no copy of
    the recording.
14. [x] **Reconcile `REWIND.md` and code comments with shipped behavior —
    completed 2026-08-25.** Removed stale claims about the sidebar, persistent
    sibling branches, disabled evicted nodes, missing re-derivation, unbuilt
    transport, `Window` rather than `WindowGroup`, and the already-finished
    Observation refactor. Historical design sections remain, clearly labeled as
    historical.
15. [x] **Close or justify history-derived invalidation — completed
    2026-08-27.** Closed: `PipelineInvalidation` is the final design, and
    REWIND's history-derived proposal is not pending work. It was not only a
    documentation problem — four call sites (gradient apply and clear, CWL apply
    and disable) re-assembled the base-signal cascade out of the primitives
    instead of calling it, and every one had drifted the same way: the caches
    were cleared and the variance ledger was not, so an export after an
    *interactive* gradient correction could carry a variance line describing
    cleaning that had just been invalidated — while the headless path, which
    called the shared cascade, cleared it. All four now go through one
    interactive entry point, `WaveformView.invalidateDownstreamOfBaseSignalChange`,
    and a removed stage clears its own account. `InvalidationAuthorityTests`
    pins the ledger as part of the cascade and audits the sources so a second
    cascade cannot quietly reappear — a behavioural test cannot catch that,
    since a hand-written copy passes every cache assertion and diverges on
    whatever its author forgot.
16. [x] **Define provenance for combined recordings — completed 2026-08-27.**
    A combined output starts a **fresh history**, and the contributors are
    recorded at its root rather than spliced into its lineage. Merging them was
    rejected on the terms the tree is built on: undo in a window is linear,
    there is no single "step before" a grand average of six files, and a lineage
    that cannot reproduce the bytes at each node breaks the one promise a node
    ID makes. `RecordingCombiner.contributorProvenanceSteps` writes one
    non-replayable `combineInput` step per contributor — file name, the tip of
    *that file's own* content-addressed history (derived from its `eva.xml` the
    same way its window would), and its step count — for both append and grand
    average, where previously append recorded only a file count and grand
    average named files only in its bad-channel policy steps. Enough to find
    every contributor's exact processed state, without implying the result can
    be undone back into it. Covered by `RecordingCombinerTests`.
17. [x] **Separate "not assessed" from "good" — completed 2026-08-27.** The
    "Labeled Artifacts" metric scored 1.0 whenever no artifact intervals were
    supplied, and carried its full weight into the segment percentage — so a
    recording nobody had examined scored at least as well as an examined clean
    one, and that number went into the training export.
    `SegmentHealthArtifactAssessment` makes the caller state which it means, and
    `SegmentHealthAnalyzer.analyze` has no default for it. An unassessed metric
    is marked `notAssessed` and excluded from *both* halves of the weighted
    ratio, so the percentage describes what was measured; its score is 0 rather
    than 1 so a consumer that ignores the flag errs pessimistic; its artifact
    features are `nil` rather than `0`; and it is not named as a weak metric.
    "Detection ran and found nothing" is now distinguishable from "nothing has
    looked" via `ArtifactViewModel.hasAssessedArtifacts`, a token compared
    against `detectionRefreshToken` so an upstream stage that invalidates
    detection also invalidates the verdict. The training export is schema 2 with
    an explicit `artifactsAssessed`, the UI renders an unassessed metric with a
    hollow marker and "Not assessed", and the analysis sheet shows "—" instead of
    0% overlap. A segment cannot be rejected for exceeding an artifact threshold
    nobody measured. Covered by `SegmentHealthAnalyzerTests`.

#### REWIND material carried into this ROADMAP

`REWIND.md` is retained as the detailed rationale and implementation archive.
This section is the completeness index: every execution-relevant proposal,
decision, gap, and deferred question from that document has a home here. If the
two documents disagree, this ROADMAP controls priority and current behavior.

| REWIND material | Authoritative ROADMAP home |
|---|---|
| Core content-addressed history model, canonical script adoption, linear per-window undo/redo | C3 completed foundation; RW-1 items 1–2 harden navigation |
| Navigation snapshots, memory budget, eviction, re-derivation, preview/cost ideas | RW-1 items 1, 2, and 7; portable/session storage in item 11 |
| Node granularity, toggles, preview-versus-apply, threshold configuration | Canonical decisions below; RW-1 items 5 and 9 |
| Queue/History lifecycle, work classes, stale descendants, preview race | RW-1 item 8; original lifecycle proposal is deferred unless full-rate queued rebuilds require it |
| History interactions: transport, keyboard, pin, rename, delete, reopen, export/report | RW-1 items 7 and 9 |
| A/B overlay, difference, health comparison | RW-1 item 10, using related forked windows |
| Generic invalidation | RW-1 item 14; centralized `PipelineInvalidation` is the current implementation |
| ICA/artifact payloads, bad-channel decisions, interpolation recipes and failure visibility | C2/C3 completed payload foundation; RW-1 items 3, 4, and 6 |
| Determinism and paired interactive/headless validation | RW-1 item 4 |
| Session persistence, `eva_history.json`, snapshot cache, normalized imports | RW-1 items 11 and 12 |
| Replay/batch per-file decisions and payload resolution | RW-1 item 6; PB-1 later completes batch policy |
| Copy-processing semantics, batch target-state identity, and node-specific reports | PB-1; RW-1 items 9–10; REPORTS work in F-1 |
| BCG detection decisions and the dormant `ecgDetection` history operation | RW-1 item 6 and SI-3; dormant ECG operation is carried in F-1 detector work |
| Processed-file lineage and unavailable interior snapshots | C3 seeding foundation; RW-1 item 1 correctness fix |
| Reference and baseline as explicit domain-aware operations | C2/C3 completed foundation; paired validation remains RW-1 item 4 |
| Segment-history fixes, regex-only segmentation, total settings restoration | C2/C3 completed foundation |
| Segment Health “not assessed” semantics | RW-1 item 16 |
| Explicit Fork to New Window and multi-window ownership | C3/C4 completed foundation; non-MFF reliability is RW-1 item 12 |
| Same-file multi-window identity and cross-window comparison | RW-1 item 10 |
| Dedicated Batch window and window-scoped recording state | C4 completed foundation |
| Multi-recording combine/grand-average provenance | RW-1 item 15 |
| Observation/performance refactor | C1 completed; snapshot policy follow-up is RW-1 item 7 |
| Machine-local GPU/Accelerate cache limits and external motion-file inputs | RW-1 item 11; motion policy in MRI-1 |

#### Canonical REWIND decisions carried forward

- **One window has linear history.** Removing a stage retains redo; applying a
  different action at that point discards the abandoned future and snapshots.
  Re-applying the exact undone action reuses it. Preserve alternatives by
  explicitly forking a window.
- **The canonical processing script describes state.** History follows pipeline
  order, not the chronological order in which sheets happened to be applied.
- **A node is committed processing, not editing UI.** Panning, scaling, opening a
  sheet, and preview/slider motion are not nodes. Applying a signal- or
  export-changing state is a node. Undo-shaped actions navigate rather than
  append inverse steps.
- **Snapshots make ordinary navigation instant; re-derivation is fallback.** A
  fallback must be exact, latest-only, source-valid, and all-or-nothing. A
  plausible partial reconstruction is a correctness failure.
- **Subject-specific fitted state needs its own payload.** Portable parameters
  and recording-specific ICA/artifact/channel decisions remain distinct. Replay
  may use a payload only when it belongs to the file being processed.
- **Reference is an explicit operation with a domain.** Continuous and epoch
  reference share a scheme type but occur at different pipeline positions and
  carry their excluded-channel set.
- **Centralized invalidation is the current design.** `PipelineInvalidation`
  serves interactive and headless paths. History-derived invalidation remains
  closed unless evidence shows a concrete safety advantage.
- **Queue and History are adjacent views today.** Queue owns active progress and
  the status log; History owns processing lineage. If queued rebuilds later make
  nodes lifecycle-bearing, work classes remain user-initiated, dependency, and
  speculative, in that priority order, with speculative work preemptible.
- **No native EVA project format is planned.** Portable lineage may remain a
  small sidecar while large snapshots and normalized imports live in an optional,
  disposable machine-local cache. Deleting that cache must lose only speed.
- **Do not expand hashing as a project.** Existing node identity remains an
  implementation detail already in use; new SHA-256 manifests or whole-recording
  hash infrastructure are not a priority or prerequisite.

**Exit:** a new correction stage can be recorded, restored, replayed, exported,
and compared without introducing another view-only or non-deterministic path.

---


---

# 12. Performance & Metal

### C1. Performance and architecture refactor — completed 2026-08-13

- Throttled progress publication and migrated domain view models plus
  `MFFRecording` to property-granular Observation.
- Moved marker queries into a small container and extracted independently
  diffable channel rows, panels, overlays, and status snapshots.
- Consolidated sheets and moved transient UI state into narrow observable models.
- Memoized interpolation snapshots and waveform marker-style decoding.
- Replaced the horizontally misplaced `LazyVStack` with `VStack`.
- Centralized pipeline-stage toggles and stage-application cores outside
  `WaveformView`.

Measured outcome from `trace3.trace`: `initializeWithCopy for WaveformView`
fell 1.48% → 0.33%, `ChannelLabelRow` 1.32% → 0.20%, and total observed
`WaveformView` symbols 9.76% → 5.91%. Canvas was only ~1.6%, so the proposed
min/max pyramid was rejected by evidence. Naive `WaveformAreaView` and
`ControlsBar` extraction was also rejected because it would add generic/closure
cost without removing the measured work.


### C10. Earlier refactor and cleanup — completed 2026-07-04

- Enabled the modern Accelerate LAPACK boundary with a clean build.
- Backfilled ICA auto-labeler/classifier tests.
- Centralized processing defaults and extracted the remaining VM-less domains.
- Completed the original `WaveformView` file/state decomposition and BCG
  iterative exemplar refinement.


## Metal backends shipped

Two of the areas surveyed in the June 2026 audit
([`docs/design/metal-acceleration.md`](docs/design/metal-acceleration.md)) are
ported, and neither followed the audit's recommended ordering:

- **Wavelets** — `EVA/Wavelet/WaveletMetalBackend.swift` +
  `WaveletKernels.metal`, covered by
  `EVATests/Wavelet/WaveletMetalBackendTests.swift`. Ranked #2 in the audit; the
  "SWT first" advice held up.
- **Gradient correction** — `EVA/Gradient/GradientMetalBackend.swift` +
  `GradientCleanroomKernels.metal`. Ranked #7 with a "benchmark first, payoff may
  be smaller than wavelets" caveat; done early anyway.

The audit's **architecture proposal was not adopted** and its **"practical first
project" was superseded**. GPU/CPU divergence is deliberate and tolerated:
`EVAHelper` exposes `--cwl-backend metal|cpu|compare` with difference tolerances,
and regression assertions pin CPU backends.

---

# 13. Developer Documentation

`docs/manual/` (user guide, tutorials, tools, contributor guide) and
`docs/provenance/` (method specs, audit logs, port plans, copyleft plan) are
established and maintained. `docs/design/` was created 2026-09-11 in this
consolidation pass.

DEV-1 — the `docs/developers/` tree tracing features to the code that implements
them — has not started and is in `ROADMAP.md` § Developer Documentation.
