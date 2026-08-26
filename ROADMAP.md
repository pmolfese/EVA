# EVA — ROADMAP

This is EVA's single execution plan. Detailed design documents may explain a
project, but this file decides priority, milestone status, and what comes next.

Status values are deliberately few:

- **NEXT** — the next milestone to execute.
- **IN PROGRESS** — partially implemented; remaining exit criteria are listed.
- **NOT STARTED** — approved work, ordered but not begun.
- **DEFERRED** — intentionally waiting for evidence or a dependency.
- **COMPLETED** — shipped or explicitly closed; details live at the bottom.

## Milestone overview

Work top-to-bottom. Do not pull a lower milestone forward merely because it is
smaller. A lower milestone may proceed only when the earlier work is blocked or
when it is an independent bug fix required for safe use.

| Order | Milestone | Brief description | Status |
|---:|---|---|---|
| 1 | **SI-0 — Characterize source-informed contracts** | Pin the current EVASimulate leadfield and surrogate-filter behavior before moving code. | **NEXT** |
| 2 | **SI-1 — Shared spherical forward model** | Move app-neutral forward math into EVA and make EVASimulate consume it. | **NOT STARTED** |
| 3 | **SI-2 — Shared surrogate-filter engine** | Extract the UI-free PCA-S operator, diagnostics, and stable linear algebra into EVA. | **NOT STARTED** |
| 4 | **RW-1 — Harden history/replay foundations** | Close the bounded REWIND correctness and paired-validation gaps needed by a new correction stage. | **IN PROGRESS** |
| 5 | **SI-3 — EVA broadband BCG PCA-S** | Integrate PCA-S through interactive, headless, replay, history, provenance, and export paths. | **NOT STARTED** |
| 6 | **SI-4 — Adversarial validation** | Measure operating limits under geometry, head-model, rank, channel, and data-quality mismatch. | **NOT STARTED** |
| 7 | **PB-1 — Batch/replay completion** | Add partial resume, decision-skipping policy, and setup compatibility preflight. | **NOT STARTED** |
| 8 | **MRI-1 — FASTR reliability and motion semantics** | Finish motion policy, unreliable-epoch provenance, PSA overlap behavior, and attenuation analysis. | **NOT STARTED** |
| 9 | **SI-5 — Ocular MSEC/PCA-S** | Reuse the validated engine for blink, vertical, and horizontal ocular topographies. | **NOT STARTED** |
| 10 | **TW-4 — Multi-peak trial diagnostics** | Finish the UI and scoring integrations for already-tested alignment metrics. | **IN PROGRESS** |
| 11 | **TW-5 — Persist trial exclusions** | Commit reviewed exclusions as replayable, provenance-bearing processing decisions. | **NOT STARTED** |
| 12 | **TW-6 — Trial covariates** | Join eye tracking and other trial-level covariates for validation and visualization. | **DEFERRED** |
| 13 | **SI-6 — SSP–SIR comparator** | Add an independently named projection-and-reconstruction comparator. | **NOT STARTED** |
| 14 | **SI-7 — SOUND channel-health experiment** | Evaluate source-informed channel noise estimation against EVA Health. | **NOT STARTED** |
| 15 | **SI-8 — Shared spatial-filter abstraction** | Extract common abstractions only after multiple concrete engines expose them. | **DEFERRED** |
| 16 | **UI-1 — Display density and montages** | Decouple sensitivity from row pitch, add channels-per-screen, then named subsets/order. | **NOT STARTED** |
| 17 | **UX-1 — Figure Composer Phase 2** | Add a freeform, multi-page publication-layout canvas. | **NOT STARTED** |
| 18 | **F-1 — Focused feature backlog** | Finish exports, importer mapping, detector comparators, and other bounded follow-ups. | **DEFERRED** |
| C1 | **Performance/Observation refactor** | Remove measured SwiftUI invalidation, struct-copy, sheet, and scroll hot spots. | **COMPLETED** |
| C2 | **Processing and batch core** | Establish shared headless transforms, replay compatibility, export, and parity. | **COMPLETED** |
| C3 | **REWIND foundation** | History tree, snapshots, navigation, payloads, progress center, branching, and multi-window support. | **COMPLETED** |
| C4 | **App/window stability fixes** | Correct multi-window routing, Batch scene dependencies, focus publication, and new-window workflows. | **COMPLETED** |
| C5 | **Channel-set geometry catalog** | Persist real net geometries and manage net-specific channel sets. | **COMPLETED** |
| C6 | **Physical display/export scales** | Label and persist physical display units and correct exported-figure scale metadata. | **COMPLETED** |
| C7 | **Figure Composer Phase 1** | Basket, reorder/remove, and vector contact-sheet export. | **COMPLETED** |
| C8 | **Trial-wise diagnostics foundation** | LOO similarity, drift plots, reviewed selection previews, multi-peak metrics, and the dashboard. | **COMPLETED** |

## Execution order and dependency map

```text
SI-0 → SI-1 → SI-2 → RW-1 → SI-3 → SI-4
                                      │
                                      ├─→ PB-1 → MRI-1
                                      ├─→ SI-5 → SI-6 / SI-7 → SI-8
                                      └─→ TW-4 → TW-5 → TW-6

After the scientific and replay-critical work:
UI-1 → UX-1 → F-1
```

The first six milestones are the committed near-term program. SI-0 through SI-2
create one numerical implementation shared by EVA and EVASimulate. RW-1 makes
the app boundary safe for a new derived-signal stage. SI-3 ships the feature.
SI-4 determines whether it is production-ready and what should follow.

---

# ACTIVE PROJECTS — IN EXECUTION ORDER

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

`BCGDetectionViewModel.correctedSignal` already owns this slot for CWL. PCA-S is
a BCG correction option fed by existing detected/refined beats, not a new
top-level wavelet or ICA stage.

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

### SI-0 — Characterize contracts — **NEXT**

- [ ] Add deterministic fixtures for leadfield and PCA-S matrix dimensions,
  finiteness, reference, artifact-free near-identity behavior, known artifact
  attenuation, brain-topography preservation, and invalid-input failures.
- [ ] Record current EVASimulate self-test metrics and determinism hashes.
- [ ] Separate exact invariants from scientific metrics allowed a documented
  tolerance when the eigensolver changes.
- [ ] Define ordered-electrode and `ForwardDipole` APIs, including units,
  coordinate frame, reference, and errors.

**Exit:** extraction cannot silently change the science, and later score changes
can be attributed.

### SI-1 — Extract the shared spherical forward model — **NOT STARTED**

- [ ] Move only app-neutral forward types and math into `EVA/Core/Forward/`.
- [ ] Adapt EVA `ElectrodeGeometry` and EVASimulate `Montage`/
  `SimulatedSource` at their own boundaries.
- [ ] Compile the shared EVA sources from EVASimulate's existing build without
  copying the implementation or adding a heavy dependency.
- [ ] Run forward self-tests, complete simulator tests, determinism checks, and
  the EVA suite with no intended generated-signal change.

**Exit:** both programs use one forward solver and simulator leadfields remain
within the pinned numerical tolerance.

### SI-2 — Extract the surrogate spatial-filter engine — **NOT STARTED**

- [ ] Separate regional-basis generation, artifact-topography input, operator
  construction/application, and diagnostics from BCG template discovery.
- [ ] Replace the simulator-only Jacobi dependency with EVA's LAPACK-backed
  routines and explicit errors; solve regularized positive-definite systems
  instead of constructing an inverse where practical.
- [ ] Preserve paper versus iterative template discovery as named BCG policies.
- [ ] Pin operator determinism, artifact attenuation, artifact-free residual
  SNR, brain-map gain/correlation, and degeneracy failures.

**Exit:** EVASimulate calls the app-owned engine and retains or improves the
committed repeated-seed results.

## 2. RW-1 — REWIND hardening required by SI-3 — **IN PROGRESS**

The history foundation is built; do not reopen its architecture. This milestone
is a bounded correctness/validation pass so `bcgCorrection` can join a reliable
pipeline. `REWIND.md` remains the detailed design record.

- [ ] Run paired byte comparisons for artifact-template re-derivation, ICA
  replay, `markBad`, gradient motion parameters, and continuous/epoch reference.
- [ ] Instrument—not guess—the observed impossible state where `eva_ica.json`
  existed without an `icaClean` step.
- [ ] Finish `markBad`/interpolation carry-through and resolve their position
  relative to wavelet and segment operations.
- [ ] Make replay interaction represent “resolved from this file's payload”
  rather than relying on a batch-local workaround.
- [ ] Ensure threshold configuration edits produce deliberate history nodes
  without recording one node per slider tick.
- [ ] Re-derive evicted snapshots and expose the memory-budget preference;
  disabled, unreachable history nodes are not the final behavior.
- [ ] Add A/B compare only after two nodes can be selected reliably.

**Exit:** a new correction stage can be recorded, restored, replayed, exported,
and compared without introducing another view-only or non-deterministic path.

## 3. SI-3 — Ship broadband BCG PCA-S — **NOT STARTED**

- [ ] Add PCA-S after BCG detection/refinement as a correction choice.
- [ ] Plumb geometry, reference, and good-channel selection through interactive
  and headless paths.
- [ ] Add `bcgCorrection`, replay compatibility, audit diagnostics, variance
  accounting, history snapshots, toggles, and invalidation.
- [ ] Add a generated BCG PCA-S case to `PipelineRegressionTests` with a quality
  floor, a defensible anti-leakage ceiling, and a reviewable watermark.
- [ ] State assumed geometry/head parameters in the UI and refuse silent
  standard-montage fallback.

**Exit:** the same recording/settings produce equivalent interactive, headless,
and replayed output, and repeated-seed truth tests clear artifact-removal and
brain-preservation gates.

## 4. SI-4 — Adversarial evaluation — **NOT STARTED**

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

## 5. PB-1 — Processing and batch completion — **NOT STARTED**

The suite is operational; these are deferred usability edges, not prerequisites
for ordinary batch work.

- [ ] **Partial-then-resume:** run a portable prefix headlessly, then load its
  partially processed signal into a fresh windowed session for decision steps.
- [ ] **Skip all decisions:** optional per-file policy that drops unsupported
  decision steps rather than making the entire script windowed.
- [ ] **Setup compatibility preflight:** inspect chosen files before execution;
  runtime protection already exists in both batch paths.

## 6. MRI-1 — FASTR reliability and motion semantics — **NOT STARTED**

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

## 7. Trial-wise similarity, drift, and reviewed exclusion

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

### TW-5 — Persist reviewed exclusions — **NOT STARTED**

Phase 3 deliberately previews but does not alter data. Committing must use the
same provenance and replay machinery as other category rejections.

- [ ] Commit a reviewed exclusion set as a processing step carrying
  `CategoryRejection(reason: "Low similarity")`.
- [ ] Serialize it in `eva.xml`, display it in history and QuickLook retention
  bars, and reload/replay it without changing the decision.
- [ ] Preserve per-trial reasons and distinguish an operator-reviewed decision
  from the analyzer's proposed set.
- [ ] Verify interactive, headless, history-restored, and exported outcomes.

**Exit:** exclusions survive the file and remain attributable to both the rule
and the human decision; previewing alone never removes a trial.

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

## 8. UI-1 — Display density and montage control — **NOT STARTED**

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

## 9. UX-1 — Figure Composer Phase 2 — **NOT STARTED**

Replace contact-sheet-only layout with a freeform publication canvas: drag,
resize, multi-select, snapping/alignment guides, and multiple pages. Preserve
vector PDF as the primary format; SVG remains out of scope unless a dependable
writer is adopted.

## 10. F-1 — Focused feature backlog — **DEFERRED**

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

# COMPLETED

Completed work is archived here so the active half of the roadmap contains no
finished checklists. Dates describe landing or verification, not necessarily
release dates.

## C1. Performance and architecture refactor — completed 2026-08-13

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

## C2. Processing and batch core — completed 2026-07-04; parity closed 2026-08-13

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

## C3. REWIND foundation — completed 2026-08-15

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

## C4. App/window stability fixes — completed 2026-08-15

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

## C5. Channel-set geometry catalog — completed 2026-08-15

- Added persisted `KnownNetGeometry` entries sourced only from real recordings.
- Added net selection/editing, rename with merge-on-collision, deletion, and
  net filtering.
- Made Channel Set storage injectable so tests never mutate a user's real
  Application Support data.
- Deliberately did not fabricate bundled HydroCel geometry or automate cross-net
  equivalence judgments.

## C6. Physical display and export scales — completed 2026-08-13

- Added nominal µV/mm and mm/s readouts, typed entry, clinical presets, and
  portable physical-unit defaults.
- Unified scale constants, used the real sampling-rate-dependent display stride,
  and fixed raster export metadata at 144 dpi.
- Added exact figure-scale calculation for vector PDF output.
- Deferred per-display calibration and row-height-independent sensitivity to
  UI-1, where they belong.

## C7. Figure Composer Phase 1 — completed 2026-08-14

- Added “Add to Export” to figure menus.
- Added a session-wide basket with thumbnails, reorder, and removal.
- Added vector PDF contact-sheet export in Letter and square layouts with
  automatic page wrapping.

## C8. Trial-wise diagnostics foundation — Phases 1–3 and Phase 4 core complete

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

## C9. Feature work landed since 2026-07-13

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

## C10. Earlier refactor and cleanup — completed 2026-07-04

- Enabled the modern Accelerate LAPACK boundary with a clean build.
- Backfilled ICA auto-labeler/classifier tests.
- Centralized processing defaults and extracted the remaining VM-less domains.
- Completed the original `WaveformView` file/state decomposition and BCG
  iterative exemplar refinement.

## C11. Superseded planning documents

`TODO.md`, `REFACTOR_July.md`, `REFACTOR.md`, `TODO_BATCH.md`, `GEDAI_PLAN.md`,
and `TRIALWISE.md` were absorbed and deleted. `SOURCE_ANALYSIS.md`, `REWIND.md`,
and `REPORTS.md` remain design references, but milestone status and execution
order are authoritative only here.
