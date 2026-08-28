# EVA — ROADMAP

This is the single execution plan for the whole project. Detailed design
documents may explain a project, but this file decides priority, milestone
status, and what comes next. It covers two spheres of influence:

- **Part I — EVA proper**, the application itself, including REWIND (RW),
  processing/batch (PB), MRI/FASTR (MRI), trial-wise review (TW), UI/UX, and the
  source-informed correction program (SI) as it lands in the app.
- **Part II — EVASimulate**, the `Tools/EVASimulate` simulator and its tiers.
- **Part III — Completed**, everything already shipped, sorted by the same two
  spheres.

Status values are deliberately few:

- **NEXT** — the next milestone to execute.
- **IN PROGRESS** — partially implemented; remaining exit criteria are listed.
- **NOT STARTED** — approved work, ordered but not begun.
- **DEFERRED** — intentionally waiting for evidence or a dependency.
- **COMPLETED** — shipped or explicitly closed; details live in Part III.

Cross-sphere note: SI-0, SI-1, and SI-2 were shared-code extractions executed
across both spheres, and SI-3 shipped the first correction built on them; all
four are recorded in Part III. The app-side remainder (SI-4 onward) is in
Part I, and the simulator-side remainder is in Part II.

---

# PART I — EVA PROPER

## Milestone overview

Work top-to-bottom. Do not pull a lower milestone forward merely because it is
smaller. A lower milestone may proceed only when the earlier work is blocked or
when it is an independent bug fix required for safe use.

| Order | Milestone | Brief description | Status |
|---:|---|---|---|
| 1 | **SI-4 — Adversarial validation** | Measure operating limits under geometry, head-model, rank, channel, and data-quality mismatch. | **NOT STARTED** |
| 2 | **PB-1 — Batch/replay completion** | Add partial resume, decision-skipping policy, and setup compatibility preflight. | **NOT STARTED** |
| 3 | **MRI-1 — FASTR reliability and motion semantics** | Finish motion policy, unreliable-epoch provenance, PSA overlap behavior, and attenuation analysis. | **NOT STARTED** |
| 4 | **SI-5 — Ocular MSEC/PCA-S** | Reuse the validated engine for blink, vertical, and horizontal ocular topographies. | **NOT STARTED** |
| 5 | **TW-4 — Multi-peak trial diagnostics** | Finish the UI and scoring integrations for already-tested alignment metrics. | **IN PROGRESS** |
| 6 | **TW-5 — Persist trial exclusions** | Commit reviewed exclusions as replayable, provenance-bearing processing decisions. | **IN PROGRESS** |
| 7 | **TW-6 — Trial covariates** | Join eye tracking and other trial-level covariates for validation and visualization. | **DEFERRED** |
| 8 | **SI-6 — SSP–SIR comparator** | Add an independently named projection-and-reconstruction comparator. | **NOT STARTED** |
| 9 | **SI-7 — SOUND channel-health experiment** | Evaluate source-informed channel noise estimation against EVA Health. | **NOT STARTED** |
| 10 | **SI-8 — Shared spatial-filter abstraction** | Extract common abstractions only after multiple concrete engines expose them. | **DEFERRED** |
| 11 | **UI-1 — Display density and montages** | Decouple sensitivity from row pitch, add channels-per-screen, then named subsets/order. | **NOT STARTED** |
| 12 | **UX-1 — Figure Composer Phase 2** | Add a freeform, multi-page publication-layout canvas. | **NOT STARTED** |
| 13 | **F-1 — Focused feature backlog** | Finish exports, importer mapping, detector comparators, and other bounded follow-ups. | **DEFERRED** |

## Execution order and dependency map

```text
[SI-0 → SI-1 → SI-2 → RW-1 → SI-3 done] → SI-4
                                             │
                                             ├─→ PB-1 → MRI-1
                                             ├─→ SI-5 → SI-6 / SI-7 → SI-8
                                             └─→ TW-4 → TW-5 → TW-6

After the scientific and replay-critical work:
UI-1 → UX-1 → F-1
```

The shared-code extractions (SI-0 through SI-2), the history/replay hardening
(RW-1), and the PCA-S feature itself (SI-3) are complete; their records are in
[Part III](#a-eva-proper--completed). **SI-4 is next**, and it is what decides
whether PCA-S is production-ready: the method ships with defaults that are
defensible rather than measured — the component-reliability gate in particular —
and its operating envelope is unmeasured until the adversarial sweeps run.

---

## 1. Source-informed artifact correction

**Decision (2026-08-25):** independently implement the surrogate-source filter
already evaluated in EVASimulate, beginning with broadband BCG PCA-S. Do not
begin with a GEDAI-shaped generalized-eigenvalue pipeline. Treat GEVD and other
methods as separately named comparators with their own truth-backed use cases.

This project ends at a cleaned sensor-space recording. Full distributed source
imaging remains a separate EVA Resolve question; see `SOURCE_ANALYSIS.md`.

### Method and scientific rationale

“Surrogate” means the Berg–Scherg multiple-source family, not surrogate
time-series data. The recording is modeled as a simultaneous mixture:

```text
X ≈ B S + A U
```

- `B`: plausible brain topographies from free-orientation regional dipoles.
- `A`: a small empirically estimated artifact-topography dictionary.
- `S`, `U`: fitted brain and artifact time courses.

The brain block is regularized; the artifact block is not. The filter then
reconstructs only `B S`, yielding one inspectable channels × channels operator.
This asymmetry—not an inability of `B` to span the sensor space—is the separation
mechanism. Brain regularization, artifact component count, reference, channel
selection, and head-model mismatch are scientific parameters to measure.

Direct precedents include ocular MSEC (Berg & Scherg 1991/1994), ongoing
ocular/cardiac correction (Ille, Berg & Scherg 2002), TMS correction (Litvak et
al. 2007), and EEG-fMRI BCG PCA-S/ICA-S (Rusiniak et al. 2022). These are
correction filters, not complete artifact detectors: beat, blink, saccade, or
TMS-event detection supplies epochs/topographies upstream.

### Existing assets and ownership decision

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

### Mandatory contracts

- **Geometry:** one ordered `ElectrodeGeometry` value must reach interactive and
  headless paths. Missing/incomplete geometry fails by default; an approximate
  montage is an explicit, audited opt-in.
- **Channels/reference:** construct and apply over the exact good EEG subset and
  matching reference. Never include PNS rows or silently mix reference models.
- **Invalidation/accounting:** publish to `bcg.correctedSignal`, use shared
  `PipelineInvalidation`, and maintain a `CleaningVarianceAccount` named
  `surrogateSeparation` for the output lifetime.
- **Replay/provenance:** add `bcgCorrection`; portable settings and fitted,
  recording-specific results must remain distinct.
- **Headless parity:** `ProcessingCore`, Copy Processing, windowed use, and the
  regression corpus call the same engine. A sheet-only path is incomplete.

Every contract above is met by SI-3 for BCG and is the reference implementation
for SI-5 onward; see [Part III, C13](#a-eva-proper--completed).

SI-0 through SI-3 are complete, as is the RW-1 history/replay hardening they fed
into: the shared numerical layer, the app boundary, and the first shipped
source-informed correction. Their records are in
[Part III](#a-eva-proper--completed); what remains here is measurement (SI-4)
and the later methods below.

## 2. SI-4 — Adversarial evaluation — **NOT STARTED**

- [ ] Sweep recording length, accepted beats, BCG rank/morphology jitter,
  component count, regularization, channels, sampling rate, and basis richness.
- [ ] Add independent shell-radius, skull-conductivity, head-center, and
  electrode-position mismatch to the existing basis-offset sweep.
- [ ] Report broadband/per-band residuals, clean distortion, ERP amplitude,
  latency/topography, removed variance, and mean ± SD over seeds.
- [ ] Derive refusal/warning thresholds for inadequate beat count,
  ill-conditioning, and missing geometry from evidence.

**Exit:** the safe operating envelope and failure messages are measured. Only
then call PCA-S production-ready or generalize it.

### Later source-informed methods

These remain grouped with the shared scientific rationale, but their execution
slots are the ones in the milestone table: SI-5 follows MRI-1; SI-6 through SI-8
follow the Trial-wise milestones.

#### SI-5 — Ocular MSEC/PCA-S — **NOT STARTED**

- [ ] Derive distinct blink, vertical, and horizontal topographies from explicit
  calibration or high-confidence events.
- [ ] Reuse the same engine/basis while keeping discovery provenance ocular.
- [ ] Add truth-backed held-out ocular events to EVASimulate.

**Exit:** held-out ocular artifacts improve without exceeding committed ERP
topography/amplitude distortion.

#### SI-6 — SSP–SIR comparator — **NOT STARTED**

- [ ] Implement a separately named projection + source-informed reconstruction
  engine and operation.
- [ ] Compare it with simultaneous surrogate fitting as artifact and brain
  topographies become congruent.
- [ ] Use TMS-like, BCG, or ocular cases only where the simulator has honest
  truth; do not infer generality from one artifact family.

#### SI-7 — SOUND for channel health — **NOT STARTED**

- [ ] Test noisy, drifting, bridged, clipped, and clean-control channels.
- [ ] Compare with `ChannelHealthAnalyzer` while preserving the distinction
  between sensor failure and coherent physiological artifact.
- [ ] Decide whether SOUND initially reports/flags or also corrects data;
  automatic correction requires a visible policy and regression evidence.

#### SI-8 — Shared spatial-filter abstraction — **DEFERRED**

Multiple-source correction, SSP–SIR, SOUND, Wiener filters, and related methods
can share constrained-spatial-filter concepts. Do not design this abstraction
prospectively. Extract it only after PCA-S and at least one of SSP–SIR/SOUND have
exposed stable shared concepts; preserve differences in artifact topographies,
noise covariance, and reconstruction constraints.

### GEVD and band-wise work — **DEFERRED**

GEVD remains a valid comparator, not the baseline. It uses a forward covariance
`G Gᵀ`, solves a data-to-brain generalized eigenproblem, and selects high-ratio
directions. It may help with heterogeneous or unknown artifacts and adapts
naturally per epoch/band, but it adds forward-covariance mismatch, local
covariance instability, and automatic component-selection risk.

Schedule GEVD only when SI-4 reveals a concrete PCA-S failure it could plausibly
solve. Keep the eigensolver, selection rule, and threshold search separately
documented; compare with PCA-S and SSP–SIR using identical truth and distortion
metrics. Start PCA-S broadband. EVA's existing SWT/MRA machinery can support a
later band-wise experiment without a second MODWT implementation.

### Scientific stop conditions

- Never silently assume geometry, channel order, reference, or head parameters.
- A matched generator/filter result is not robustness evidence; require mismatch
  sweeps and repeated seeds.
- Removed variance is a report, not proof of quality or sensor failure.
- Never reuse fitted artifact components across subjects by default.
- A generic topography input does not validate ocular, movement, EMG, or ICA
  adapters; each requires its own discovery path and truth.
- Do not make optimized rejection/correction thresholds automatic defaults
  without validation.
- Preserve independent-development and provenance headers on implementations.

## 3. PB-1 — Processing and batch completion — **NOT STARTED**

The suite is operational; these are deferred usability edges, not prerequisites
for ordinary batch work.

- [ ] **Partial-then-resume:** run a portable prefix headlessly, then load its
  partially processed signal into a fresh windowed session for decision steps.
- [ ] **Skip all decisions:** optional per-file policy that drops unsupported
  decision steps rather than making the entire script windowed.
- [ ] **Setup compatibility preflight:** inspect chosen files before execution;
  runtime protection already exists in both batch paths.

## 4. MRI-1 — FASTR reliability and motion semantics — **NOT STARTED**

- [ ] Decide and document strict Bergen translation-speed versus EVA full-FD
  semantics for Moosmann; expose the alternative explicitly.
- [ ] Add real explanation popovers for MRI-gradient options.
- [ ] Serialize motion metric and unreliable-epoch policy; pause/stop when motion
  is required but unavailable unless a resolver is configured.
- [ ] Return per-volume coverage diagnostics and distinguish normal edge TRs
  from correction fallback/failure.
- [ ] Emit duration-bearing `MRI_GRAD_UNRELIABLE` provenance events by default
  for genuinely unreliable corrections.
- [ ] Add PSA rejection for unreliable MRI correction and use interval overlap,
  not event-start-only tests.
- [ ] Investigate FASTR's low non-artifact correlation (~0.5–0.7 versus AAS
  >0.85), including alpha-scaling and interpolation/decimation effects.
- [ ] Add `aff12` affine-motion decomposition to the motion panel.

**Exit:** motion-dependent correction refuses unsafe inputs, unreliable regions
round-trip into PSA, and signal attenuation is explained or bounded.

## 5. Trial-wise similarity, drift, and reviewed exclusion

The purpose is to find trials that differ from their category average and say
*how* they differ. Two motivating cases are an attenuated response consistent
with inattention and a trial whose waveform better matches another label.

Regressing a trial on its category average separates shape from magnitude:

| Shape (`r`) | Magnitude (`β`) | Interpretation |
|---|---|---|
| high | ≈ 1 | ordinary trial |
| high | ≈ 0 | response absent/attenuated; candidate inattention |
| low | any | noise, artifact, or divergent morphology |
| high | negative | inversion, possible mislabel, or reference problem |

Everything that uses a mean reference must be leave-one-out. Comparing a trial
with an average containing itself creates a `1/n` self-correlation bias exactly
where small categories are most vulnerable. Median/trimmed-mean references are
the deliberate exception because one trial barely moves a robust reference.

Cross-category matching is the sharper mislabel test, but it is gated: the best
alternative must clear correlation 0.3 and beat the own-category correlation by
0.1. Pooled categories are hierarchical; a member matching a sibling inside the
same pool is not called a mislabel. These are heuristics until validated on real
behavioral/covariate data.

### TW-4 — Complete multi-peak diagnostics — **IN PROGRESS**

The tested analyzer already provides named-window `r`/`β`/residual scores,
time-resolved correlation, bounded-lag affine gain/offset fitting, and
ridge-regularized multi-component regression. Draggable per-mode windows,
per-window panels, and the two-column diagnostics dashboard are also complete.

- [ ] Add panels for `timeResolvedCorrelation` and `affineFit`.
- [ ] Add a bounded time-dilation term, `average(α·t − lag)`, for uniformly
  slowed responses; report deformation beside residual, never instead of it.
- [ ] Make Measurements and CWT consume their existing windows rather than only
  drawing the overlays.
- [ ] Add per-channel residual contribution through a genuinely multichannel
  analyzer path so missed channel problems are distinguishable from bad trials.
- [ ] Decide whether to add cross-category small multiples and multiple-testing
  correction for the displayed drift statistics.

**Exit:** multi-peak morphology, latency, amplitude, and channel-local failures
are visible without letting unconstrained alignment explain every trial away.

### TW-5 — Persist reviewed exclusions — **IN PROGRESS**

Phase 3 deliberately previews but does not alter data. Committing must use the
same provenance and replay machinery as other category rejections.

#### Why this is not just another parameter step

Every other step in the script has the property that its settings *are* its
result: re-running `filter highPassHz=0.1 lowPassHz=30` reproduces the samples.
A similarity threshold does not. Re-running `r < 0.3` after any upstream change
proposes a *different* set of trials, and no threshold value can express an
operator putting one flagged trial back. So the committed step records **both**:
the thresholds, because they say why and are the only portable half, and the
resolved trial set, because it is the decision. Replay applies the recorded set
verbatim and never silently re-derives it.

#### Canonical decisions (2026-08-26)

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

#### Work

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
#### Remaining: the commit control (planned 2026-08-26)

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

#### Tests

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

#### Deliberately out of scope

Segment Health's manual quality labels stay session-only in this milestone. They
are a different judgement (a bad *segment*, not a trial unlike its category) and
folding them into the same persisted step would widen TW-5 into a rewrite of
Segment Health's semantics. Both feed the one key-resolution path added here, so
promoting them later is a small step — carried in F-1.

### TW-6 — Eye tracking and other trial covariates — **DEFERRED**

- [ ] Add an open `covariates: [String: Double]` bag to each trial.
- [ ] Join on `sourceTimeSeconds` plus source event ID, both already retained by
  `EpochSegment`.
- [ ] Support fixation duration, pupil diameter, saccade count, blink flags, and
  “color by covariate” in diagnostics.
- [ ] Test whether low-`β` trials actually coincide with failures to fixate; use
  this evidence to recalibrate or reject the inattention interpretation.

**Exit:** the scientific meaning of trial-wise flags is evaluated against an
independent behavioral measure rather than inferred from waveform similarity.

### Trial-wise stop conditions

- Selection thresholds use MAD with meaningful floors (`r` 0.05, `β` 0.10,
  residual 0.10); do not substitute SD, which the target outliers inflate.
- Do not report unstable small-sample Mahalanobis distance without a validated
  robust covariance estimator.
- Keep the seeded random-exclusion null beside before/after SNR and SME. It
  controls trial-count effects but does not prove selected trials were bad.
- Bound lag/warp searches and score overlap only—zero padding or unconstrained
  warping can manufacture a clean fit.
- A confident but uninterpretable trial flag is worse than no flag. Preserve the
  checkable `r`–`β`, cross-category, and per-reason explanations.

## 6. UI-1 — Display density and montage control — **NOT STARTED**

Build Phase A and B together. `channelIndices(in:)` is the membership/order
choke point, while row height currently participates in sensitivity. A naive
“show N channels” control would silently change µV/mm.

### Phase A — how many channels

- [ ] Make sensitivity (µV/mm) and row pitch independent user settings.
- [ ] Define channels-per-screen from the available waveform viewport, excluding
  event track and physio pane.
- [ ] Preserve physical sensitivity while row pitch changes; overlap at dense
  settings is expected.
- [ ] Set a readable row-height floor. Do not pretend the labeled row renderer
  can show 129 channels; treat a carpet/raster overview as a separate renderer.
- [ ] Keep this display-only: no `eva.xml` or history-node changes.
- [ ] Measure high-density scrolling before and after; do not reintroduce the
  horizontal `LazyVStack` regression.

### Phase B — which channels

- [ ] Define one coherent relationship between montage membership and the
  existing hidden-channel state.
- [ ] Support saved named subsets with explicit ordering and net compatibility.
- [ ] Keep uniform pitch unless group spacers justify changing hover arithmetic.

Optional follow-ons: honest per-display calibration and a carpet/raster view.

## 7. UX-1 — Figure Composer Phase 2 — **NOT STARTED**

Replace contact-sheet-only layout with a freeform publication canvas: drag,
resize, multi-select, snapping/alignment guides, and multiple pages. Preserve
vector PDF as the primary format; SVG remains out of scope unless a dependable
writer is adopted.

## 8. F-1 — Focused feature backlog — **DEFERRED**

These are independent and should be selected by user demand after the ordered
projects above, not treated as one parallel program.

### Data interchange

- [ ] BESA Connectivity `.generic` export.
- [ ] BESA Statistics ERP/ERF `.avr` export; invert the existing reader.
- [ ] Auto-map auxiliary/biological channels into `pnsSignal` for BrainVision
  and EDF imports.

### Detectors and analysis

- [ ] Engzee/Engelse–Zeelenberg QRS comparator.
- [ ] Hilbert/energy-transform QRS comparator.
- [ ] Reconcile the dormant `ecgDetection` history operation: emit it from the
  canonical ECG-detection state if it belongs in lineage, or retire it if it is
  provenance-only.
- [ ] Editable resting-state spectral bands after the dashboard workflow settles.
- [ ] Seed BCG Spatial PCA from a selected trajectory-strip frame, bypassing
  covariance/PCA derivation when the exemplar is too short or noisy.

### App and pipeline polish

- [ ] Reuse an already-open empty window for Finder open events if the stray
  window is confirmed important enough to justify app-delegate routing.
- [ ] Verify platform window-position restoration across relaunch.
- [ ] Publish Channel Set focus from a windowed batch review and wire existing
  net filters into the relevant pickers where useful.
- [ ] Hoist `EventTrackEventSignature`, make displayed-event cache misses async,
  and audit `.task(id:)` signatures only if a new trace shows these paths hot.

### Larger separate workstreams

- [ ] `REPORTS.md`: typed per-recording quality/provenance report with
  JSON/HTML/Markdown output.
- [ ] `SOURCE_ANALYSIS.md`: distributed source imaging / EVA Resolve exploration;
  do not fold it into the artifact-correction milestone.

---

# PART II — EVASIMULATE

Planning document for `Tools/EVASimulate`. Written 2026-08-21.

The tool started as a benchmark harness: reproduce Grouiller et al. (2007)'s
forward model, generate EEG with known ground truth, and measure what EVA's
artifact-correction methods actually do to the signal underneath. It has since
grown a teaching role — blinks, eye movements, bad electrodes, mains hum, a real
montage, impedance — and the obvious next step is the one that motivates this
file: **making it good enough to carry a methods paper.**

That is a higher bar than either of its current jobs. A benchmark only has to be
consistent. A teaching recording only has to be recognizable. A simulator that
underwrites a published claim has to be *defensible* — every departure from
physiology has to be either justified or declared, and a reviewer has to be able
to regenerate the exact data.

---

## Completion status

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

### Owner priority guardrail

**SHA-256 is not a project priority.** Do not propose content digests, hash
manifests, template hashing, or expanded hash-based reproducibility work as a
next step. The existing determinism check may remain unchanged, but it should
not drive the roadmap or become a prerequisite for other features. Revisit this
only if the owner explicitly asks to reopen it.

### Next, in order

The authoritative cross-project sequence is Part I of this file. SI-2, the RW-1
history/replay hardening, and SI-3 — broadband BCG PCA-S shipped through EVA —
are done, so the next simulator-side obligation is **SI-4**: measuring PCA-S's
adversarial operating limits, including the component-reliability threshold it
now ships with as a defensible-but-unmeasured default. Bridge/reference
calibration, cross-machine corpus tolerances, ICA-S, and broader component
labelling remain valuable follow-ups, but they do not move ahead of that.

The full reasoning behind this order is in [Suggested order](#suggested-order) at
the end of the document; this list is the short form and should agree with it.

---

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

## Principles to hold onto

These are what make the tool trustworthy; every item below should preserve them.

1. **Determinism is not negotiable.** Same seed, byte-identical output. A
   benchmark that moves between runs cannot support a claim.
2. **Paper reproduction stays explicit.** The operational default is 1000 Hz;
   the reviewed `scenarios/paper-default.json` retains the paper's 1024 Hz rate.
   The event-time round trip is now exact at both rates, and every addition has a
   documented switch or scenario value restoring the published behaviour.
3. **Declare what was invented.** The README's "what comes from the paper and
   what does not" split is load-bearing. A result that turns on an invented
   waveform shape is weaker evidence than one that turns on a measured
   parameter, and the reader has to be able to tell which they are looking at.
4. **Self-test anything that could silently stop working.** A harness that
   quietly stops reproducing the phenomenon it studies is worse than no harness,
   because everything it emits still looks like evidence.

---

## EVASimulate — open work

Tiers 1, 2, 4 and 5 are complete, as are 3.1, 7.1-7.3 and 8.1; those records are
in [Part III](#b-evasimulate--completed). What follows is what remains.

### Tier 3 — valuable, more work

#### 3.2 Comparison harness

Run N methods × M scenarios, emit the table and the figure. This is the step that
turns "we have a simulator" into "here is the results section."

**Effort:** medium-large. **Depends on:** 2.3, 2.4. **No longer blocked:** the
event-precision bug that made EVA's gradient stage intermittently refuse
generated recordings was 4.9, fixed 2026-08-21.

##### Phase A — DELIVERED (2026-08-27)

`EVATests/Pipeline/MethodComparison/` — matrix, runner, tests — plus
`compare-methods.sh` at the repository root.

Four decisions, each with a reason that outlives this phase:

1. **It lives in the test target, not in `Tools/EVASimulate`.** The simulator is
   a standalone SwiftPM package and cannot link EVA's app code, so it cannot
   invoke `MRIGradientMethod` at all. The test target already drives
   `HeadlessBatchProcessor` with an `EVAProcessingScript` — the Tier 7 seam —
   and building a second driver for a nicer command line would put a second
   implementation between the paper's numbers and the shipped app. `EVAHelper`
   is not that precedent: it carries its own copies of the engines.
2. **The matrix is data.** `comparison-matrix.json` (schemaVersion 1) declares
   scenarios, seeds, and method arms with their literal step parameters,
   citations, and analytic ceilings, so adding a method to a published table is
   a JSON edit. `EVA_COMPARISON_MATRIX` points a run at a one-off matrix without
   editing the committed one.
3. **Scoring shells out to `eva-simulate score --json`.** The rich metric set
   exists once, in `SNRMetrics`, and a published table should be computed by it.
   `PipelineRegressionTests` keeps its in-process broadband SNR — a regression
   check must not depend on an external binary being built — and
   `harnessSNRAgreesWithInProcessSNR` compares the two implementations on the
   same recording, which is what makes having two of them tolerable.
4. **A mandatory uncorrected arm, and per-arm ceilings.** `validate()` refuses a
   matrix with no `uncorrected` arm: the same corrected score is excellent or
   worthless depending on the baseline. The harness is report-only except for
   the leakage check — an arm scoring above its own analytic ceiling fails the
   run, because a table containing an impossible number is worse than no table.

**Each arm's audit lines are read back from the processed package's
`log_eva_*.txt` and carried into the results.** This was not in the original
plan and is the phase's most important addition: a method that falls back — no
motion parameters, too few donors, a rejected template scale — still emits a
perfectly valid recording and a perfectly plausible score, and without the audit
capture the table would report that fallback as the method's performance. The
Markdown table names the warning kinds; the JSON carries every audit line.

Outputs are `comparison_results.{json,csv,md}`. The CSV is long format — one row
per (scenario, seed, method, metric) — because a wide table invites comparisons
across a row that was never a comparison.

**Sandbox note.** The test host is the sandboxed EVA app: it can read the
working tree but cannot write to it, and `eva-simulate` inherits that sandbox as
a child process. The harness therefore generates and writes inside the app
container, and `compare-methods.sh` copies the results back into `.comparison/`
from outside. That script also passes `TEST_RUNNER_EVA_COMPARISON=1`, which is
the only way an environment variable reaches an xcodebuild test process.

##### Phase A first results, and what they raise

Nine arms on `regression-gradient-locked`, one seed, all pinned to
`backend=cpu`, no alignment, no upsampling:

| Method | Broadband SNR | Warnings |
| --- | --- | --- |
| No correction | 0.064 | — |
| MAR | 2.758 | — |
| MAS | 2.470 | — |
| wAAR | 2.214 | — |
| wAAS | 2.196 | — |
| FARM | 1.825 | epochOutOfBounds (tail) |
| Fast AAS | 0.592 | epochOutOfBounds (tail) |
| Allen IAR | 0.152 | epochOutOfBounds (tail) |
| FASTR | 0.130 | epochOutOfBounds (tail) |

No arm exceeded its ceiling, and the local-template arms sit just under the
analytic 3.06 where they should. Two things are open questions rather than
findings, and neither should be quoted as a result yet:

- **The slice-template and global-average engines score an order of magnitude
  worse than the local-template ones on this scenario.** Their audit lines say
  they ran: FASTR corrected 1229 of 1230 epochs at the right 73-sample period
  and removed 74% of the variance; Allen IAR removed 101%. *Phase B settled
  half of this: the slow-modulation explanation is refuted — see the Phase B
  result below.*
- **Alignment and upsampling are not a neutral pin.** A probe run at each
  method's own defaults moved FASTR from 0.130 to 0.331 and moved FARM the other
  way, 1.825 to 0.450, while Allen IAR did not move at all. Any published table
  has to state which configuration it used: "each method at its own defaults"
  and "every method at one shared configuration" answer different questions, and
  Phase A committed to the second.

##### Phase B — DELIVERED (2026-08-27)

Five seeds, two scenarios, nine arms — 90 cells.

- **Paired differences, within seed.** Every arm sees the identical recording at
  a given seed, so the comparison is `method − reference` per seed, and the
  spread reported is the spread of the *difference*. It is far smaller than
  either arm's own spread: MAR beats MAS by 0.277 ± 0.011 while each arm's own
  SD across seeds is about 0.05. `referenceMethod` is declared in the matrix
  rather than inferred — choosing the best-scoring arm as the reference after
  the fact makes every comparison a foregone conclusion.
- **95% intervals** from Student's t with `seeds − 1` degrees of freedom, using
  a short table of critical values rather than an inverse-CDF implementation:
  the degrees of freedom are a small number chosen by hand in the matrix, and a
  table exact for the values actually used beats a numerical routine needing its
  own tests. An interval excluding zero is marked ✓ and labelled for what it is
  — larger than this setup's seed-to-seed noise, not a claim about EEG.
- **Provenance.** EVA's version, OS, architecture, and — the useful part — the
  *resolved* scenario configuration for each scenario, written beside the
  results by `generate --write-config`. A reviewer regenerates from that file
  instead of reconstructing a command line. Emitted as `comparison_paired.csv`
  and `scenario-<id>.json` alongside the Phase A outputs.

##### Phase B result: one hypothesis confirmed, one refuted

`gradient-steady` is `gradient-locked` with `slowModulationFraction` set to
zero — one parameter, so any change between them is attributable to amplitude
drift and nothing else. Broadband SNR, mean ± SD over five seeds:

| Method | gradient-locked | gradient-steady |
| --- | --- | --- |
| No correction | 0.0634 ± 0.0003 | 0.0679 ± 0.0004 |
| MAR | 2.7320 ± 0.0536 | 2.7483 ± 0.0550 |
| MAS | 2.4549 ± 0.0436 | 2.7472 ± 0.0552 |
| wAAR | 2.1665 ± 0.0551 | 2.1642 ± 0.0554 |
| wAAS | 2.1494 ± 0.0547 | 2.1624 ± 0.0557 |
| FARM | 1.8698 ± 0.0350 | 1.8959 ± 0.0342 |
| Fast AAS | 0.5901 ± 0.0036 | 0.6123 ± 0.0038 |
| Allen IAR | 0.1516 ± 0.0008 | 0.1626 ± 0.0009 |
| FASTR | 0.1300 ± 0.0007 | 0.1393 ± 0.0008 |

**Confirmed: MAR's advantage over MAS is entirely amplitude tracking.** The
paired difference MAR − MAS falls from **+0.2772 ± 0.0112** with modulation to
**+0.0010 ± 0.0004** without it. MAR is MAS with a least-squares template scale,
so it should have exactly nothing left to do once the amplitude stops drifting,
and that is what the numbers say. This is the cleanest available demonstration
that the harness measures what it claims to.

**Refuted: slow modulation does not explain the engine-family gap.** Phase A
guessed that the slice-template and global-average engines scored an order of
magnitude worse because a global template cannot track drifting amplitude.
Removing the drift moved FASTR 0.130 → 0.139 and Allen IAR 0.152 → 0.163 — the
gap is essentially unchanged, and every method improved by a similar small
amount simply because the artifact got easier. That explanation is dead.

What the same table now points at instead, unresolved:

- **FASTR and FARM share the slice-template engine and differ by nearly
  fifteenfold** (0.130 vs 1.870). They differ in donor selection: FARM ranks
  donors by correlation, FASTR takes temporal neighbours. With TR = 3.000 s at
  1000 Hz, a volume is exactly 3000 samples but a slice interval is 73.17 — not
  an integer — so successive slice artifacts land on different sub-sample
  phases, which the simulator's own model documents deliberately. Correlation
  ranking would pick phase-matched donors; temporal neighbours would not. That
  is the leading hypothesis and it is directly testable with an alignment sweep.
- **Fast AAS and Allen IAR are also poor, and neither is slice-phase-limited in
  the same way** (Fast AAS runs on 3000-sample volume epochs). Whatever they
  share with FASTR is a third thing, not yet identified.

Neither belongs in a paper until one of them is pinned down. Both are cheap
Phase C/D matrix work — an alignment/upsampling axis, which the Phase A probe
already showed is not a neutral pin.

##### Phases C-D — open

- **C.** The second axis: `ArtifactCleaningMethod` × `ArtifactOBSStrategy` on the
  BCG scenarios. The PCA-S row is now buildable — SI-3 shipped it as a
  correction stage with portable settings in `eva.xml` — so the matrix can carry
  it rather than declaring it dark.
- **D.** Reporting: a figure script, and the docs in
  `Tools/EVASimulate/README.md` and `docs/`.

**A gap Phase A exposed.** Moosmann cannot appear in any headless comparison
today, because it weights donor volumes by realignment parameters and those come
from an external motion file that no replayable script carries. That is the same
external-input problem RW-1 item 11 and MRI-1 both name, seen from the results
side.

#### 3.3 Measured template library

The synthetic gradient and BCG waveforms are the weakest link in any claim that
depends on artifact *shape*. A small library of real templates — gradient
artifacts from different scanners and sequences, BCG at different field strengths
— with provenance for each, would let a result be stated as "on a measured 3T
GE-EPI template" rather than "on our modelled waveform." `--gradient-template`
already accepts one; what is missing is the library and a BCG equivalent.

**Effort:** small in code, larger in data collection and permission.

#### 3.4 Clinical patterns

- **Interictal spikes.** The paper's *own* second evaluation case, and the one
  where it found FASTR performs badly because spikes are not orthogonal to
  residual gradient artifact. We cannot reproduce that finding today.
- **Sleep spindles and K-complexes**, for sleep-scoring method work.
- **Seizure evolution**, for detection work.

**Effort:** medium. **Note:** spikes are the highest priority of these — they
close a gap against the source paper.

---

### Tier 6 — distributed inverse methods

The natural consequence of 1.1, and the item with the largest gap between what
it sounds like it costs and what it actually costs.

Once there are **known source locations**, distributed inverse methods have
exactly the ground truth they lack in almost every other setting. Published
comparisons of MNE, dSPM, sLORETA, eLORETA, LORETA and LAURA are forced to score
each other, or to score against a single seeded dipole in a phantom. A simulator
that emits several sources at known positions, with known orientations, known
timecourses, and a known noise covariance can score all of them directly.

**These do not need a BEM.** This is the common misconception and it is worth
stating plainly in the roadmap, because it changes what is reachable today. A
distributed inverse needs two things: a **source space** — a discrete grid of
candidate locations — and a **lead field for that grid**. Both are computable in
the concentric-sphere model already implemented. `SphericalForwardModel.leadField`
called on N grid points with free orientation *is* the gain matrix these methods
consume; the free-orientation operator retained in `LeadField` is already the
right shape. Historically this is how the family was introduced — Pascual-Marqui's
original LORETA used a three-shell sphere with a Talairach-registered grid.

What separates the methods is **weighting, not the head model**. All are
minimum-norm variants. A BEM improves fidelity to a real head; it is not a
precondition for the methods to run, and for *comparing* methods the analytic
sphere is arguably better, because the forward model is exact and no mesh
discretization error confounds the comparison. That is a defensible statement in
a methods paper rather than an apology.

**Effort overall:** medium, and front-loaded — 6.1 is most of the work, after
which each method in 6.2 is a small addition.

#### 6.1 Source-space grid abstraction

The prerequisite, and the piece worth designing carefully.

- A `SourceGrid`: candidate positions inside the brain compartment, with a
  spacing parameter, plus fixed-orientation (radial/normal) or free-orientation
  modes. Regular Cartesian sampling clipped to the sphere is sufficient and is
  what most reference implementations use; keep the generation deterministic and
  prefix-stable the way `stableDirection` is, so grid refinement sweeps stay
  interpretable.
- A **neighbourhood Laplacian** over the grid, needed by 6.3 and cheap to build
  at construction time.
- The gain matrix for the grid, computed once and cached — this is `channels ×
  3N` and will be the largest object the tool handles, so it wants an on-disk
  form and a hash tied to the head model and montage.

The same abstraction serves 5.2: the surrogate method's 29 regional sources are
a very coarse source grid with free orientation, so building this first makes
5.2 a special case rather than separate code.

**Effort:** medium. **Blocks:** all of Tier 6, simplifies 5.2.

#### 6.2 The minimum-norm family

With the gain matrix, an SVD, and a regularization parameter, these are each
roughly a page of linear algebra:

- **MNE** — ridge-regularized minimum norm. The baseline everything else is
  measured against.
- **dSPM** — MNE noise-normalized by the projected noise covariance.
- **sLORETA** — normalized by the resolution-matrix variance, which buys zero
  localization error for a single point source in the noiseless case.
- **eLORETA** — reweighted to achieve that exactly, iteratively.

**The noise covariance is itself a ground truth we can emit and nobody else has.**
dSPM and its relatives are sensitive to how the noise covariance is estimated,
and in practice it is always estimated from a baseline window and always wrong by
an unknown amount. The simulator knows it exactly. Emitting both the true
covariance and a baseline-window estimate, and scoring the same method under
each, isolates a source of error that the literature can only discuss
qualitatively. This is the most novel thing in Tier 6.

Regularization choice (fixed λ, L-curve, generalized cross-validation) should be
a declared, swept parameter rather than a hidden default — it moves the rankings
more than the choice among the methods does, and comparisons that fix it
arbitrarily are a known weak point in the literature.

**Effort:** small each, after 6.1.

#### 6.3 The spatial-prior family

**LORETA** and **LAURA** add a smoothness prior via the grid Laplacian from 6.1.
Mechanically a small addition once the Laplacian exists; the work is in getting
the boundary handling at the compartment edge right, which is where these methods
are most often implemented subtly differently from the published description.

**Effort:** small-medium. **Depends on:** 6.1.

#### 6.4 Resolution metrics

Most of what one wants to say about a distributed inverse comes from the
**resolution matrix** `R = G⁺G`, which is computable analytically from the gain
matrix and the inverse operator — **no simulation run required at all**. From it:

- **Point-spread and cross-talk functions** per grid point.
- **Peak localization error** — the distance from a seeded point to the maximum
  of its point-spread function.
- **Spatial dispersion** — how smeared the reconstruction is, which is the axis
  on which the smoothness-prior methods trade against the minimum-norm ones.

These belong alongside `SourceMetrics`, and they are cheap enough to compute
across the whole grid for every method and every regularization value, which
makes them the natural substrate for a sweep figure. Simulation is then needed
only for the questions resolution analysis cannot answer — noise, correlated
sources, non-stationarity, and residual artifact.

**Effort:** small. **Note:** the highest value-per-unit-work item in Tier 6, and
it can be done immediately after 6.1 and 6.2's MNE alone.

#### 6.5 Forward-model mismatch, and the inverse crime

**The item that makes the rest honest.**

If data is generated with the same lead field used to invert it, every method
scores better than it deserves and the ranking may not survive contact with a
real head. This is the inverse crime, and a simulator is the easiest place in the
world to commit it accidentally.

**The cheap fix needs no BEM.** `SphericalHeadModel` already parameterizes shell
radii and conductivities: generate with one set, invert with another, and sweep
the mismatch. Skull conductivity in particular is the parameter real pipelines
get most wrong, and its effect on distributed-inverse ranking is a publishable
question on its own.

**The expensive fix is where BEM finally earns its place** — generate through a
realistic head model, invert through the sphere, report the degradation. Note
that the BEM is wanted here for the *generation* side, to create realistic
mismatch, not because the inverse methods require it. That is the honest
argument for importing a real head model, and it is a better one than "BEM is
more accurate."

Every Tier 6 result should state which regime it was computed in. A number from
a matched forward model is a statement about the algorithm; a number from a
mismatched one is a statement about the method as it would be used.

**Effort:** small (parameter mismatch) to large (BEM import). **Priority:** the
parameter-mismatch version is not optional — do it with 6.2, not after.

---

### Tier 7 — end-to-end pipeline regression

Everything in Tiers 1-6 makes the simulator better. This tier makes the
simulator *useful to EVA every day*, by closing a loop:

> **generate a recording with known truth → let EVA process it headlessly →
> score the result against that truth → assert the score.**

The existing `selftest` validates the simulator's own model. The determinism
baseline (`scripts/check-determinism.sh`) validates that the *generator* does not
drift. Neither says anything about whether EVA's correction pipeline still does
what it did last month — and that is the larger risk, because the pipeline is
where features land.

**Relationship to 3.2.** This is the same machinery as the comparison harness,
pointed at a different question. 3.2 asks *"which method is better?"* and its
output is a table for a paper. Tier 7 asks *"is this method still as good as it
was?"* and its output is a pass or a fail. Build 7 first: it pays off on every
commit, and it leaves 3.2 needing little more than a different reporting layer.

**How much already exists.** More than it looks:

- **Generate** — `eva-simulate generate --config`, with the complete
  `sim_truth.json` sidecar.
- **Process headlessly** — `HeadlessBatchProcessor.process(url:script:outputFolder:)`,
  already exercised in `EVATests/Pipeline/HeadlessBatchProcessorTests.swift`.
  `EVAProcessingScript` already describes a whole pipeline as data, with XML
  read/write in `EVAProcessingScriptXML`.
- **Score** — `score`, `score-events` and `score-erp` from 2.3, all against the
  truth sidecar.

The missing pieces were the glue and — much more importantly — the assertion
policy in 7.2; the delivered section below records the completed design.

#### 7.4 Non-determinism is a constraint, not a bug to fix

**The generator is deterministic and gets hashed. The pipeline is not and gets
scored.** Keeping that distinction is what stops this suite from becoming a
source of false failures.

`EVAHelper` already exposes `--cwl-backend metal|cpu|compare` with
`--compare-max-diff`, `--compare-rms-diff` and relative variants, and
`WaveletMetalBackendTests` compares the GPU reduction against the CPU one — so
the divergence is already known and already tolerated deliberately. CI runners
are virtual machines without a usable Metal device, so a hash or an exact
expectation recorded on a development Mac would fail on CI permanently and for no
real reason.

Therefore:

- **Pin CPU backends** in every regression script. Determinism of the *assertion*
  matters more here than exercising the fast path; GPU/CPU agreement is already
  covered by its own dedicated test.
- **Express every expectation as a tolerance**, never an equality.
- Record in the watermark which backend produced each number.

#### 7.5 Continuous integration — GitHub Actions

**Use GitHub Actions, not CircleCI.** CircleCI has macOS executors and would
work, but the repository already runs GitHub Actions
(`.github/workflows/docs.yml`), so adding a second provider means a second
credential set, a second YAML dialect, and a second thing to keep working, for no
capability gain.

EVA needs a macOS runner regardless — SwiftUI, Accelerate, Metal, `xcodebuild`.

**Staging, following the structure `run-all-tests.sh` already has:**

| Trigger | Stages | Rationale |
| --- | --- | --- |
| Every push | tool builds, `eva-simulate selftest`, determinism check | Fast (~45 s of real work) and pure computation. Catches the majority of breakage. |
| Pull request to `main` | the above, plus `EVATests` and the Tier 7 regression suite | The expensive, valuable pass, run where review happens. |
| Never | `EVAUITests` | Its runner fails to initialize on a busy or headless machine, for reasons unrelated to the code. |

**Budget expectations.** A cold macOS runner spends several minutes before it
does anything useful, so plan for 8-15 minutes wall clock even though the local
run is about two. Public repositories get macOS minutes cheaply; if EVA ever
becomes private, macOS bills at roughly ten times the Linux rate and the split
above stops being a nicety.

**Failure output matters.** `run-all-tests.sh` already logs to files and prints
only the tail of a failing stage; keep that behaviour in CI. A job that dumps
thirty thousand lines of `xcodebuild` output is a job whose failures stop being
read.

#### 7.6 Effort and sequencing

**Effort:** medium. 7.1 and 7.3 are mostly assembly of parts that exist. 7.2 is
the real design work, and it is worth doing slowly — a floor set carelessly is
either noise or decoration.

**Depends on:** 2.3 (metrics) and 2.4 (scenario files), both complete.

**Suggested first slice:** one scenario, one script, one floor, one watermark
entry — the locked-clock gradient case, because its expected value is known
analytically from the √N ceiling rather than merely observed. Get that green in
CI before adding a second entry. A corpus assembled before the assertion policy
is settled will need rewriting anyway.

---

### Tier 8 — simulator-supervised component labelling

Generalizes 5.4 from the BCG to artifact classification as a whole.

**The observation that makes it worth a tier:** EVASimulate already generates
**six of ICLabel's seven classes**, and knows the topography of each.

| ICLabel class | EVASimulate source | Ground truth quality |
| --- | --- | --- |
| Brain | 1.1 dipole sources | **Derived** — three-shell forward model |
| Eye | Ocular dipoles (2.1) | **Derived** — dipole field, approximate eye centres |
| Heart | BCG generators (5.1) | **Derived + modelled** — see 5.1's split |
| Muscle | EMG/chewing/swallowing (2.1) | **Modelled** — fixed regions, controlled carriers |
| Line Noise | Mains model (2.1) | Trivially known per-channel gains |
| Channel Noise | Defects, bridging, bad reference (2.1) | Trivially known |
| Other | — | Not modelled |

So for any ICA decomposition of a simulated recording, every component's true
class membership is computable by projecting its topography onto each known
subspace — and it comes out **graded**, not binary, which is more information
than a human rater can give. That is the same lever as 5.4, applied across the
board.

#### 8.0 What I would not do

Stated first, because the failure modes here are more attractive than the
successes.

- **Do not report aggregate accuracy.** It will be dominated by the easy classes
  and will hide failure on the hard ones. Line noise is identifiable from one
  spectral peak; a single bad channel produces a component with a
  one-electrode topography that any rule finds. A classifier scoring 95%
  overall while failing to separate muscle from gamma is worse than useless,
  because the 95% is what gets quoted. **Per-class, always.**
- **Do not train a large model.** Simulated data is unlimited, which makes
  over-parameterization easy and its consequence invisible: the model learns the
  simulator, scores beautifully against the simulator, and transfers poorly. A
  small model over named features is defensible in a methods section; a black box
  trained on synthetic data is not.
- **Do not try to replace ICLabel.** Produce `ICAComponentSuggestion`s that
  compose with it, the way `ICAComponentAutoLabeler` already does.
- **Do not treat the classes as equally well-founded.** See 8.2.

#### 8.2 Priority follows provenance, not convenience

The reliability of a simulator-trained classifier inherits the reliability of the
generative model behind each class. That ordering is already documented in the
README's "what comes from the paper and what does not" split, and it should drive
the order of work:

1. **Ocular** — highest value after BCG. Dipole topographies, a genuinely
   distinct spatial signature, and the class where a mislabel costs the most,
   because removing a frontal component takes real frontal EEG with it.
2. **Heart/BCG** — 5.4, already scoped.
3. **Muscle** — valuable but the most hazardous. The README already states that
   EMG uses fixed source regions and controlled carrier families, with no
   motor-unit recruitment or subject-specific anatomy. Real EMG is heterogeneous,
   and that heterogeneity is precisely why it is the hardest class for existing
   labellers. A classifier trained on our EMG learns a stereotype. Worth doing,
   worth labelling clearly as a lower-confidence class, and worth validating
   against real data before anyone relies on it.
4. **Line Noise and Channel Noise** — low priority. Existing heuristics already
   handle them, and the simulator would mostly be teaching the easy case. Useful
   as *negative controls* in the benchmark rather than as targets.

#### 8.3 The figure nobody else can produce: controlled overlap

The interesting question in component labelling is not the clean cases, it is the
overlapping ones — a component that is part muscle and part gamma, or part blink
and part frontal delta. Real labelled datasets cannot vary that: whatever overlap
the recording happened to contain is what you get, and the human labels are least
reliable exactly there.

The simulator can dial it continuously — 4.4's shared-band machinery,
`--dipole-near-pair-separation`, EMG band edges against the neural gamma band,
ocular amplitude against frontal source amplitude — and knows the answer at every
setting.

**Classifier performance as a function of controlled brain/artifact overlap** is
the deliverable of this tier. It says where a labeller stops working, which is
what a user actually needs to know, and it is not obtainable any other way.

#### 8.4 A second use: ICA identifiability itself

The same corpora answer a question 1.1 raised and nothing has used yet. The true
source count is known — neural dipoles plus BCG generators plus ocular plus
muscle regions — so the simulator can generate the cases where unmixing must
fail: more sources than channels, two sources with near-identical topographies,
sources that move (1.1 already supports all three).

Scoring *decomposition* quality rather than *labelling* quality, with
`SourceMetrics.recoveryScore`, is nearly free once the corpora exist, and it
tells you whether a mislabel was the labeller's fault or whether ICA never
recovered the component in the first place. Those are different problems and are
routinely confused.

#### 8.5 The circularity discipline, inherited from 5.4

Everything 5.4 says applies here and matters more, because the weaker generative
models are in this tier:

- Hold out generator configurations; report on the held-out ones.
- Treat simulator-derived thresholds as a prior to test on real data.
- **3.3 (measured template library) is load-bearing**, and for muscle it is close
  to mandatory.
- Record which model version produced each corpus. `sim_truth.json` already
  carries the complete configuration.

#### Effort and sequencing

**Effort:** 8.1 small; 8.2-8.3 medium; 8.4 small once the corpora exist.

**Depends on:** Tier 7's corpus machinery, and 5.4 as the pilot — do one class
end to end before generalizing. **Wants:** 3.3 for external validation.

**Note:** the deliverable lands in `EVA/ICA/` rather than in the simulator, which
makes this the first item where the simulator's main product is a *feature of
EVA* rather than a measurement. That is a good sign for the tool, and a reason to
keep the training corpora and their provenance under version control alongside
the model.

---

### Suggested order

For the stated goal of supporting methods papers. **Tiers 1, 2 and 4 are
complete** (4.1 and 4.2 subsumed by 5.1), Tier 3 has 3.1 done, and Tier 5 is
complete apart from ICA-S and the localization criterion, which waits on Tier 6.

This is the reasoning behind the short list in
[Completion status](#completion-status) at the top of the document. If the two
ever disagree, the top table is the one people read — fix it first.

**Done through this pass:** 3.1, 4.1-4.9 (4.1/4.2 subsumed by 5.1), 5.1, 5.2
for PCA-S, and 5.3 apart from dipole localization error. The 2026-08-25 audit
also fixed the ERP filtering order, split paper/iterative pattern searches,
preserved component-wise group estimands, tightened the pipeline ceiling, and
completed repeated-evaluation JSON. The correction input contract is also
closed: actual MFF/override geometry, truth head parameters, explicit fallback,
and exact PNS preservation are regression-tested. Tier 7.3 now has all six
planned corpus cases, and 8.1 supplies the first per-class graded-truth baseline
for both existing component-labelling paths.

**Next:**

1. **Real-recording calibration for bridge/reference diagnostics** — the unified
   review-only Channels UI and Channel Health deep-link are complete; validate
   thresholds, then add overlay/difference previews plus explicit mark/exclude
   actions. Reference metadata and before/after rereference context are complete.
2. **ICA-S** (5.2) — 5.4 now supplies the missing component-selection layer, so
   this is assembly plus comparison against PCA-S rather than classifier design.
3. **7.4-7.5** — establish cross-machine tolerances, then stage the complete
   nine-case corpus in GitHub Actions.
4. **Tier 8 proper (8.2-8.4)** — extend the proven pilot workflow to other weak
   classes, with dataset provenance and real-data checks rather than a class dump.
5. **3.2 comparison harness** — unblocked now that 4.9 is fixed, and mostly a
   reporting layer over Tier 7's machinery by this point.

**Tier 6 is deliberately deferred.** It is a capability that would later support
a paper; Tier 5 is the paper. The one exception worth pulling forward is **6.1**,
because the surrogate model's 29 regional sources in 5.2 are a coarse source
grid — building the grid abstraction first makes 5.2 a special case instead of
separate code. If 6.1 gets written for 5.2, then MNE from 6.2 and **6.4
resolution metrics** become cheap enough to do opportunistically, and 6.5's
parameter-mismatch check should travel with them rather than follow later.

The curated-library part of 3.3 remains deferred and permission-heavy. The
measured-template portability proposal is also deferred by owner decision.
**SHA-256/content-digest work is not a priority:** do not propose or revive
digest, hash-manifest, or embedding work unless the owner explicitly reopens
it. Also deferred: 3.4 clinical patterns and the rest of Tier 6.

#### Known blockers carried from elsewhere

- **Sub-millisecond MFF event times** — **resolved 2026-08-21**; see **4.9**.
  Both `EVA/IO/MFFWriter.swift` and `EVA/IO/MFFReader.swift` were quantizing to
  milliseconds. No longer blocks general-rate support in 3.2 or 1024 Hz runs in
  3.1.

---

# PART III — COMPLETED

Completed work is archived here so the active half of the roadmap contains no
finished checklists. Dates describe landing or verification, not necessarily
release dates. Sorted by sphere of influence: EVA proper first, then
EVASimulate.

## A. EVA proper — completed

| Order | Milestone | Brief description | Status |
|---:|---|---|---|
| C1 | **Performance/Observation refactor** | Remove measured SwiftUI invalidation, struct-copy, sheet, and scroll hot spots. | ✅ **COMPLETED** |
| C2 | **Processing and batch core** | Establish shared headless transforms, replay compatibility, export, and parity. | ✅ **COMPLETED** |
| C3 | **REWIND foundation** | Linear per-window undo/redo, snapshots, navigation, payloads, progress center, explicit window forks, and multi-window support. | ✅ **COMPLETED** |
| C4 | **App/window stability fixes** | Correct multi-window routing, Batch scene dependencies, focus publication, and new-window workflows. | ✅ **COMPLETED** |
| C5 | **Channel-set geometry catalog** | Persist real net geometries and manage net-specific channel sets. | ✅ **COMPLETED** |
| C6 | **Physical display/export scales** | Label and persist physical display units and correct exported-figure scale metadata. | ✅ **COMPLETED** |
| C7 | **Figure Composer Phase 1** | Basket, reorder/remove, and vector contact-sheet export. | ✅ **COMPLETED** |
| C8 | **Trial-wise diagnostics foundation** | LOO similarity, drift plots, reviewed selection previews, multi-peak metrics, and the dashboard. | ✅ **COMPLETED** |
| C12 | **RW-1 — REWIND hardening** | Close the bounded REWIND correctness and paired-validation gaps needed by a new correction stage; all sixteen audit items. | ✅ **COMPLETED 2026-08-27** |
| C13 | **SI-3 — Broadband BCG PCA-S** | Surrogate-source BCG correction through interactive, headless, replay, history, provenance, and export paths. | ✅ **COMPLETED 2026-08-27** |

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

### SI-2 — Extract the surrogate spatial-filter engine — ✅ **COMPLETED 2026-08-26**

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

### C5. Channel-set geometry catalog — completed 2026-08-15

- Added persisted `KnownNetGeometry` entries sourced only from real recordings.
- Added net selection/editing, rename with merge-on-collision, deletion, and
  net filtering.
- Made Channel Set storage injectable so tests never mutate a user's real
  Application Support data.
- Deliberately did not fabricate bundled HydroCel geometry or automate cross-net
  equivalence judgments.

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

### C10. Earlier refactor and cleanup — completed 2026-07-04

- Enabled the modern Accelerate LAPACK boundary with a clean build.
- Backfilled ICA auto-labeler/classifier tests.
- Centralized processing defaults and extracted the remaining VM-less domains.
- Completed the original `WaveformView` file/state decomposition and BCG
  iterative exemplar refinement.

### C11. Superseded planning documents

`TODO.md`, `REFACTOR_July.md`, `REFACTOR.md`, `TODO_BATCH.md`, `GEDAI_PLAN.md`,
and `TRIALWISE.md` were absorbed and deleted. `SOURCE_ANALYSIS.md`, `REWIND.md`,
and `REPORTS.md` remain design references, but milestone status and execution
order are authoritative only here.

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
3. [x] **Finish channel-decision identity and carry-through — completed
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
4. [x] **Complete the paired validation and impossible-state instrumentation —
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
5. [x] **Commit threshold edits deliberately — completed 2026-08-26.** It was
   the zero-state end of that range: `ProcessingChainSignature` carries no
   parameter values and threshold detection produces no signal, so a retuned
   detector never reached the history at all. `ArtifactViewModel`
   `.thresholdConfigCommits` is bumped once when the ocular threshold sheet
   commits (Done, Restore Defaults, or dismissal) and is the signature's only
   count-valued term, so a drag mints nothing and a commit mints one node.
   Navigating to a threshold node now also restores its blink/movement
   configurations, so the detector re-runs off the values that node's hash was
   built from. Covered by `ThresholdConfigCommitTests`.
6. [x] **Represent “resolved from this file's payload” in replay policy —
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
7. [x] **Make the snapshot policy truthful — completed 2026-08-26.** Four
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
8. [x] **Choose the real Queue/History contract — completed 2026-08-26.** The
   two tabs are adjacent views, and now say so: Queue is “what is running now,
   and what it has reported”, History is “the steps that produced the signal on
   screen” (`ProcessingStatusTab.summary`, surfaced on each tab). No node
   lifecycle is shared between them — a node never appears in Queue, and a
   running operation is not a node until it has produced something. Queued,
   dependency, and speculative node states stay unbuilt; `REWIND.md`'s lifecycle
   design is relabelled as the starting point *if* full-rate background rebuilds
   are ever built, not as pending work.
9. [x] **Finish the minimum Mac history surface and trim aspirational UI —
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
10. [x] **Define A/B comparison around related forked windows — completed
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
11. [x] **Decide portable history versus session cache — completed
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
12. [x] **Make forks reliable for non-MFF imports — completed 2026-08-26.** The
    security scope is preserved, and no normalized cache was needed.
    `MFFRecording` already accepted `securityScopedURLs` and the BrainVision open
    path already threaded the folder scope through; the *fork* dropped them —
    `PendingWindowForks.Payload` carried only `packageURL`, so the claiming
    window re-read a header whose `.vmrk`/`.eeg` it had no access to, and failed
    to load a file the source window had open. The payload now carries the
    scopes. They are process-wide and refcounted, so handing the same URLs to
    the second window is the whole fix: no bookmark round-trip, and no copy of
    the recording.
13. [x] **Reconcile `REWIND.md` and code comments with shipped behavior —
    completed 2026-08-25.** Removed stale claims about the sidebar, persistent
    sibling branches, disabled evicted nodes, missing re-derivation, unbuilt
    transport, `Window` rather than `WindowGroup`, and the already-finished
    Observation refactor. Historical design sections remain, clearly labeled as
    historical.
14. [x] **Close or justify history-derived invalidation — completed
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
15. [x] **Define provenance for combined recordings — completed 2026-08-27.**
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
16. [x] **Separate "not assessed" from "good" — completed 2026-08-27.** The
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

## B. EVASimulate — completed

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
