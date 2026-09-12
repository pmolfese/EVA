# EVA — ROADMAP

**The single "what is left to do" plan for the whole project**, organized by EVA
subsystem. Everything that has shipped lives in
[`ROADMAP_COMPLETE.md`](ROADMAP_COMPLETE.md), under the *same twelve section
headings*, so a subsystem's remaining work and its history sit at the same place
in both files. Method specifications, file-format contracts, and licence surveys
live in [`docs/design/`](docs/design/README.md).

This file decides **priority and status**. A design document may explain a
method; it does not decide whether the method is scheduled.

Status values are deliberately few:

- **NEXT** — the next milestone to execute.
- **IN PROGRESS** — partially implemented; remaining exit criteria are listed.
- **NOT STARTED** — approved work, ordered but not begun.
- **DEFERRED** — intentionally waiting for evidence or a dependency.

Checklist legend: `[x]` done · `[ ]` not started · `[~]` partially there today.

---

## Priority

Work top-to-bottom within a section. Do not pull a lower item forward merely
because it is smaller. A lower item may proceed only when the earlier work is
blocked, or when it is an independent bug fix required for safe use.

Across sections, the ordered spine is unchanged:

| Order | Milestone | Section | Status |
|---:|---|---|---|
| 1 | **SI-4 — Adversarial evaluation** | [§2 Processing & Cleaning](#2-processing--cleaning) | **NEXT** |
| 2 | **PB-1 — Batch/replay completion** | [§10 Batch, Replay & Provenance](#10-batch-replay--provenance) | NOT STARTED |
| 3 | **MRI-1 — FASTR reliability and motion semantics** | [§3 MRI / fMRI](#3-mri--fmri-artifact-correction) | NOT STARTED |
| 4 | **SI-5 — Ocular MSEC/PCA-S** | [§2 Processing & Cleaning](#2-processing--cleaning) | NOT STARTED |
| 5 | **TW-4 / TW-5 — Trial diagnostics and exclusions** | [§4 Trial-wise](#4-epoching-averaging--trial-wise) | IN PROGRESS |
| 6 | **UI-1 / UX-1 — Display density, Figure Composer 2** | [§9 UI, Figures & Export](#9-ui-figures--export) | NOT STARTED |
| 7 | **DEV-1 — Developer documentation** | [§12 Developer Documentation](#12-developer-documentation) | IN PROGRESS (DEV-1a, 1b done) |

**SI-4 is what decides whether PCA-S is production-ready.** The method ships with
defaults that are defensible rather than measured — the component-reliability
gate in particular — and its operating envelope is unmeasured until the
adversarial sweeps run.

**Scheduled independently of that spine**, because each is self-contained and
blocks nothing: the Rhythmicity Explorer's WTPL and burst milestones
([§5](#5-time-frequency--rhythmicity)), EVA Resolve's R2.4–R6 head-model and
inverse work ([§6](#6-source--forward-modeling)), the EVASimulate tiers and
synthetic sleep ([§7](#7-simulation)), and RSA ([§8](#8-rsa)).

### Owner priority guardrail

**SHA-256 is not a project priority.** Do not propose content digests, hash
manifests, template hashing, or expanded hash-based reproducibility work as a
next step. The existing determinism check may remain unchanged, but it should
not drive the roadmap or become a prerequisite for other features. Revisit this
only if the owner explicitly asks to reopen it.

## Sections

1. [Ingest & Formats](#1-ingest--formats)
2. [Processing & Cleaning](#2-processing--cleaning)
3. [MRI / fMRI Artifact Correction](#3-mri--fmri-artifact-correction)
4. [Epoching, Averaging & Trial-wise](#4-epoching-averaging--trial-wise)
5. [Time-Frequency & Rhythmicity](#5-time-frequency--rhythmicity)
6. [Source & Forward Modeling](#6-source--forward-modeling)
7. [Simulation](#7-simulation)
8. [RSA](#8-rsa)
9. [UI, Figures & Export](#9-ui-figures--export)
10. [Batch, Replay & Provenance](#10-batch-replay--provenance)
11. [Performance & Metal](#11-performance--metal)
12. [Developer Documentation](#12-developer-documentation)

---

# 1. Ingest & Formats

MFF read/write, FIF read, BrainVision/EDF/Persyst/BESA import, Quick Look and
thumbnails all ship. What remains is export surface and importer polish — none
of it ordered above the spine, all of it selected by user demand.

## IO-1 — Export formats — **DEFERRED**

- [ ] BESA Connectivity `.generic` export.
- [ ] BESA Statistics ERP/ERF `.avr` export; invert the existing reader.
- [ ] Auto-map auxiliary/biological channels into `pnsSignal` for BrainVision
  and EDF imports.

## IO-2 — FIF writing (MNE / Neuromag) — **NOT STARTED**

The reader shipped 2026-09-06; its record is in `ROADMAP_COMPLETE.md` § 1.

Writing is the other half, and it is worth doing because it is how EVA hands work
*back* to the MNE/FieldTrip/Brainstorm world — a cleaned recording, an epoched
set, a condition average — without a detour through `.mff` or a Python bridge.
The tag writer already exists and already produces files MNE reads
(`FIFWriter`, validated for trans / dig / BEM by
`Tools/resolve-validate/check_swift_fif.py`), so this is mostly measurement-info
assembly rather than new format work.

- [ ] **`FIFF_CH_INFO` writer** — the 96-byte struct: scanno, logno, kind,
  range, cal, coil type, `loc[12]`, unit, unit multiplier, 16-byte name. The
  keystone, exactly as it was for reading. EVA holds microvolts, so write
  `cal = 1e-6` with `range = 1` and let the file be in volts like every other
  FIF, rather than inventing a unit.
- [ ] **Measurement info block** — sfreq, nchan, first sample, filter settings,
  measurement date, bad channels (`FIFFB_MNE_BAD_CHANNELS`), and the Isotrak
  digitization from the montage EVA already has. `Digitization.append(to:)`
  writes that block today.
- [ ] **Continuous writing** — `FIFFB_RAW_DATA` with float32 buffers of a fixed
  size (MNE's default is 10 s, and the buffer boundary is visible in how MNE
  reads it back), plus annotations from EVA's event list.
- [ ] **Epoched and averaged writing** — the `FIFF_EPOCH` matrix (3-D for
  epochs, 2-D per condition for averages), the event list and event-id mapping,
  `nave` per condition, and `first_sample`. EVA's `EpochSegment` table already
  carries everything these need.
- [ ] **Round-trip validation** — extend the fixture tooling with a
  `check_swift_fif_recording.py` that reads EVA-written raw / epochs / evoked
  back with MNE and compares against the source, the way the BEM and OpenMEEG
  writers are already checked. Round-tripping an imported file back out is the
  cheapest strong test: read `sample_raw.fif`, write it, and require MNE to see
  the same samples, channels, events and montage.
- [ ] **Decide the export surface** — whether FIF joins the existing MFF export
  flow as another destination, or is a separate File ▸ Export ▸ MNE FIF. Do not
  build the UI before the writer round-trips.

Not planned unless a need appears: SSP projector writing, CTF compensation, MEG
channels, and split-file output (`-1.fif`, `-2.fif`). The reader reports
projectors rather than applying them, and the writer should refuse to invent
them.


---

# 2. Processing & Cleaning

Filtering, ICA (incl. PICARD-O and ICLabel), wavelet denoising with empirical
Bayes, cardiac detection, channel/segment health, and source-informed BCG
correction (PCA-S) all ship. The open work is **measuring PCA-S's operating
envelope**, then reusing the validated engine for other artifact families.

Method reference:
[`docs/design/source-informed-correction.md`](docs/design/source-informed-correction.md).

## SI-4 — Adversarial evaluation — **IN PROGRESS**

SI-4 is a **measurement** milestone, not an infrastructure one: the head-model
work and the `evaluate-surrogate` flags (`--seeds --offsets --sources --components
--brain-regularization --duration --channels --coordinates --rate --correction-head
--with-erp --json`) already exist. What remains is to run the adversarial campaign,
report the full metric set, and turn the evidence into the refusal/warning
thresholds the shipped code currently only *assumes* — `minimumAcceptedBeats = 10`
and `minimumComponentReliability = 0.9` in `BCGSurrogateCorrection` are placeholders;
geometry-missing is already a hard refusal. Three tracks (owner decisions 2026-08-30):

**Track 1 — tooling gaps — SHIPPED 2026-08-30:**

- [x] **Missing sweep controls** added to `evaluate-surrogate`: `--bcg-morphology-jitter`,
  `--max-beats` (accepted-beat axis), and independent head-model params
  `--correction-scalp-radius` / `--correction-skull-ratio` / `--correction-head-center` /
  `--correction-electrode-jitter` (the last builds the brain basis on a jittered
  montage while truth stays on the real one; the head params perturb only the swept
  parameter of the truth head via `perturbedCorrectionHead`).
- [x] **Full metric set** in the per-seed report — sensor-space distortion (clean
  distortion dB, per-band residual/correlation, removed-variance fraction) added to
  both the text table and the `--json`, reusing `SNRMetrics.score`.
- [x] **`evaluate-surrogate-grid` subcommand** — `--axis <name> --values <a,b,c>
  [--output <csv>]` cross-runs an axis (duration, channels, rate, components,
  brain-regularization, sources, offset, max-beats, bcg-morphology-jitter,
  correction-scalp-radius/-skull-ratio/-electrode-jitter) and writes one aggregated
  CSV (corrected/uncorrected SNR, clean distortion, removed variance, accepted-beat
  fraction, nearest source), all in memory via the shared `evaluateSurrogateCore`.
  Self-test now 107/0 (adds a grid-core check). **Already surfaced a breakpoint:**
  ≤6 accepted beats makes PCA-S *hurt* (corrected SNR below uncorrected; removed-
  variance blows past 1.0) — Track 2/3 territory.

**Track 2 — run the campaign (experiments):**

- [ ] Sweep each axis with enough seeds — length, accepted beats, rank/morphology
  jitter, component count, regularization, channels, rate, basis richness — plus the
  independent head-model params. The channel sweep runs on the **built-in montage at
  32/64/128/256** for the trend now; real HydroCel geometry stays deferred (below).
- [ ] Record mean ± SD and the **breakpoint** per axis (where corrected stops beating
  uncorrected, or ERP distortion exceeds a committed bound). Write the findings into
  `docs/provenance/` and summarize here — like the head-mismatch finding already on
  record.
- [x] **Head-model mismatch (done):** `evaluate-surrogate --correction-head <name>`
  builds the correction basis on a different standard head than the truth.
  **Measured: PCA-S degrades gracefully** — an extreme 1:80→1:20 skull mismatch moves
  broadband SNR ~25% but the correction still beats uncorrected (>1.8×), because the
  brain basis spans most of sensor space. (Independent per-parameter versions are the
  Track-1 head-model item above.)

**Track 3 — evidence → guardrails (closes SI-4):**

- [ ] Confirm or **recalibrate** `minimumAcceptedBeats` and
  `minimumComponentReliability` from the data; add an **ill-conditioning guard**
  (condition number of the regularized brain system) only if the sweeps show it
  matters.
- [ ] Surface the refusals/warnings as user-visible messages + provenance events,
  with tests. Only then is PCA-S production-ready.

**Enabling head-model work (SI-1 shipped only one head model; the geometry
sweeps above cannot run without a second and third).** These are shared
infrastructure — added to EVA's `EVA/Core/Forward/` and mirrored in
EVASimulate's boundary types so a generate-with-one, invert-with-another
mismatch is expressible:

- [x] **4-shell concentric sphere** (brain/CSF/skull/scalp). Nearly free: the
  shell recurrence already handles arbitrary shell count, so this is a new head
  constant plus a CSF conductivity, on both the EVA and EVASimulate sides. This
  is the geometry the Rusiniak et al. (2022) PCA-S paper actually used.
- [x] **Affine-scaled ellipsoid** (BESA-style), `EllipsoidalForwardModel`. The
  paper's "4-shell ellipsoidal" model is a per-axis affine warp of a concentric
  sphere, not true ellipsoidal harmonics: transform electrode and source
  geometry into sphere-space, run the existing analytic solver, map back.
  Documented as a first-order geometric approximation (no moment/conductivity
  anisotropy); the unit-scale case reduces bit-for-bit to the sphere, which is
  the load-bearing self-test.
- [x] **Alternative standard 3-shell parameterizations**: a `threeShell(...)`
  factory keyed on the skull-conductivity *ratio* (the parameter SI-4 most needs
  to sweep), plus named presets — `rushDriscollThreeShell` (1:80),
  `standardThreeShell` (1:40, the modern default), `highSkullConductivityThreeShell`
  (1:20). Mirrored on both sides.
- [x] **BEM forward solver** (`BEMForwardModel`): meshed shells, Van Oosterom–
  Strackee solid angles, deflated double-layer (Geselowitz) system, multi-RHS
  LU. **Validated for single AND multi-compartment** — converges to the analytic
  sphere at first order for a full 3-shell head at realistic skull contrast
  (subdiv 2/3/4 → 6.5%/2.9%/0.8% at 1:40; 11%/5.7%/1.65% at 1:80). The default
  subdivision (3) gives ≈3% at 1:40. The self-test asserts 3-shell convergence.
  (The earlier ~170% multi-shell error was a diagonal auto-solid-angle sign bug,
  not an ISA deficiency; the plain double-layer BEM is genuinely accurate here.)
- [ ] **IPA / isolated-skull BEM — optional efficiency, no longer a blocker.**
  The plain BEM is already correct; IPA (Hämäläinen & Sarvas 1989) would buy the
  same accuracy at a coarser mesh for very high skull contrast, cutting the dense
  solve cost. Schedule only if BEM mesh cost becomes a bottleneck for
  generation-side use.
- [ ] **EGI HydroCel 128- and 256-channel montages** as EVASimulate scenarios —
  **deferred within SI-4** (owner 2026-08-30): the channel sweep runs first on the
  built-in montage at 32/64/128/256 to get the trend; author the real HydroCel
  geometries only if that trend shows montage-specific effects the spiral montage
  misses. No need to reproduce the paper's exact 64-channel protocol.

**Exit:** the safe operating envelope and failure messages are measured. Only
then call PCA-S production-ready or generalize it.


### Later source-informed methods

These remain grouped with the shared scientific rationale, but their execution
slots are the ones in the milestone table: SI-5 follows MRI-1; SI-6 through SI-8
follow the Trial-wise milestones.

#### SI-3a — Manual / by-eye BCG exemplar — **NOT STARTED**

A near-term addition to shipped PCA-S, and a prerequisite shape for SI-5's
ocular calibration (user-provided exemplars → same engine). Today BCG
topography discovery always begins from detected beats
(`BCGSurrogateTopographies.components(beatSeconds:)`); when there is no ECG
channel — and the synthesized/virtual-ECG detectors are not trusted for a
given recording — the user has no way to assert the artifact directly. The
brain-basis and operator halves are unchanged; this is a new discovery
front-end only.

- [ ] **Hand-marked beats**: let the user click BCG peaks in the waveform view
  and feed those times into the existing pipeline unchanged (smallest path).
- [ ] **Highlighted exemplar window**: let the user drag a selection over one
  clear BCG complex and use that window as the template/correlation-search seed,
  bypassing beat detection — the truest analogue to the paper's manual
  representative-beat step. Add as a new `BCGArtifactPatternSearch` case
  (e.g. `.manualExemplar`) alongside `.paper`/`.iterative`.
- [ ] Record the manual provenance in `eva.xml` and the audit log so a manual
  correction replays exactly rather than re-deriving from criteria.

**Exit:** a recording with no usable ECG can be corrected from a user-defined
BCG exemplar, with the manual selection recorded as replayable provenance.

#### SI-5 — Ocular MSEC/PCA-S — **NOT STARTED**

- [ ] Derive distinct blink, vertical, and horizontal topographies from explicit
  calibration or high-confidence events.
- [ ] Reuse the same engine/basis while keeping discovery provenance ocular.
- [ ] Add truth-backed held-out ocular events to EVASimulate.

**Exit:** held-out ocular artifacts improve without exceeding committed ERP
topography/amplitude distortion.

#### SI-5b — Manual BCG component selection as a CleanArtifact method — **NOT STARTED**

- [ ] Let the user click/identify a component (e.g. in an ICA/PCA component
  browser) and tag it as BCG.
- [ ] Add a `CleanArtifact` case that takes the user-selected component and
  runs it through the existing PCA-S subtraction/removal path — reuse the
  removal math, only the selection step differs from automatic detection.
- [ ] No new removal engine: this is a manual-selection front end onto the
  same PCA-S engine used elsewhere in SI-5.

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


## Detector comparators and follow-ups — **DEFERRED**

- [ ] Engzee/Engelse–Zeelenberg QRS comparator.
- [ ] Hilbert/energy-transform QRS comparator.
- [ ] Reconcile the dormant `ecgDetection` history operation: emit it from the
  canonical ECG-detection state if it belongs in lineage, or retire it if it is
  provenance-only.
- [ ] Editable resting-state spectral bands after the dashboard workflow settles.
- [ ] Seed BCG Spatial PCA from a selected trajectory-strip frame, bypassing
  covariance/PCA derivation when the exemplar is too short or noisy.


---

# 3. MRI / fMRI Artifact Correction

Nine gradient-correction engines ship and have been measured head-to-head
(EVASimulate item 3.2, `ROADMAP_COMPLETE.md` § 7). What is open is reliability
semantics: what the correction does when motion data is missing or the
correction is untrustworthy.

## MRI-1 — FASTR reliability and motion semantics — **NOT STARTED**

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


**Carried from the comparison harness:** Moosmann cannot appear in any headless
comparison today, because it weights donor volumes by realignment parameters
that come from an external motion file no replayable script carries. That is
this milestone's motion-policy item seen from the results side.

---

# 4. Epoching, Averaging & Trial-wise

## Trial-wise similarity, drift, and reviewed exclusion

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

The engine is complete and tested — operation, `eva.xml` element, per-category
merge, review state, commit control, re-average safety, restore-on-navigate.
The record is in `ROADMAP_COMPLETE.md` § 4. Two verification items remain:

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


### TL-1 — Trial-level analysis package — **DEFERRED**

RIDE decomposition and Woody latency alignment already ship inside EVA
(`EVA/Trials/RIDEAnalyzer.swift`, `WoodyAlignmentAnalyzer.swift`). The larger
design they came from — a `.eva` interchange package, batch subject/condition
analysis, ERP-image plots sorted by trial metadata, and trial-wise regression
against behaviour — was never built, and the "EVA Resolve" name it was written
under now belongs to the source-analysis app in [§6](#6-source--forward-modeling).

Design: [`docs/design/trial-level-analysis.md`](docs/design/trial-level-analysis.md).
Schedule only with a product decision about where it lives and what it is called.

---

# 5. Time-Frequency & Rhythmicity

ERSP, ITPC and DPSS multitaper ship and cross-check against MNE below 1e-6, with
NPY and tidy-CSV export. The Rhythmicity Explorer ships LAVI, ABBA, on-demand
significance, WTPL, and burst analysis with reproducible exports and explicit
Time-Frequency band adoption, measured Metal acceleration, and recording-scoped
result persistence with revision-aware staleness (Milestones 0–8). Exact,
checksummed per-channel paper-significance caching additionally reuses completed
aperiodic fits, ribbons, and diagnostics across scientifically identical runs.

Method reference: [`docs/design/rhythmicity.md`](docs/design/rhythmicity.md).

## TF-4 — Frequency-axis cluster permutation stats — **NOT STARTED**

The big group-analysis win, and mostly generalization of existing code.

- [ ] Generalize `ClusterSpatialAdjacency` to add a **frequency neighbor axis**
  alongside time + channels.
- [ ] Feed TF maps (power and ITPC) into the existing `ClusterPermutationAnalyzer` /
  F-variant with the extended adjacency.
- [ ] Document the two accepted group paths: (a) cluster-permutation over the full
  TF × channel space (dominant method, controls the massive multiple-comparison
  problem); (b) a-priori band × window ROI scalars → LMM/ANOVA in R/JASP (the TF-3
  scalar CSV, zero new stats code).

**Effort:** medium — the adjacency generalization is the careful part but
well-scoped; the permutation engine is untouched.

**Overall exit:** a user selects epochs, opens the Time-Frequency tab, sees a
baseline-normalized ERSP / ITPC map, exports full maps + tidy scalars, and runs a
frequency-aware cluster-permutation test — all on the same epoch selection the ERP
views use. **Effort:** medium overall; TF-1 is the gate and independently valuable.

---


**Also open, carried from TF-1/TF-2:** the GPU path for the Morlet transform,
and a visual/design pass over the Time-Frequency tab.

---

# 6. Source & Forward Modeling

**Goal:** EVA Resolve is a *focused sibling app* to EVA for EEG source analysis.
It owns everything that is about *where in the head* a signal comes from: the
Source Simulator, dipole fitting, distributed inverse imaging, head models
imported from MNE / OpenMEEG (and later DUNEuro), electrode coregistration,
and (long term) FEM. EVA stays the recording editor and cleaning pipeline.
Both share IO and math through `EVACore/`.

EVA Resolve is a separate app target that owns everything about *where in the
head* a signal comes from. Shipped: the target itself, `EVACore/`, the head
frame, NIfTI/GIFTI in core, electrode coregistration with a `.evahead` package,
BEM **geometry** import from MNE and OpenMEEG with quality gates, the analytic
spherical/ellipsoidal/BEM forward models, the Source Simulator through Stage 3c,
and dipole fitting at 43× its original speed.

**Decision (2026-09-06): EVA Resolve does not build head models — it imports
them.** Segmentation, surface extraction and the BEM solve are mature, validated,
freely licensed work in MNE-Python and OpenMEEG. Rationale and the licensing
boundary: [`docs/design/head-models.md`](docs/design/head-models.md).

## Sequencing


```
R0 done ─► R1 done ─► R2.1–R2.3 done ─► R2.4 coreg UI (brainstorm pending)
                                       │
                     ┌─────────────────┴──────────────────┐
                     ▼                                    ▼
       R3.1 import geometry + gates          R4 inverse on sphere grid
                     ▼                                    │
       R3.2 import solution                               │
                     ▼                                    │
       R3.3 BEMSolutionForwardModel ──► R3.4 ForwardOperator ──► R4 on BEM, R5 on BEM
                     ▼                                    │
       R3.5 validation vs. MNE + OpenMEEG                 │
                     ▼                                    ▼
       R3.6 import UI                       R3.7 lead-field import ──► R6 FEM (DUNEuro)
```

- R3.5's `Tools/forward-compare/` fixtures were generated **first**, before R3.2, so
  R3.2/R3.3 are now a matter of driving one number to zero against a committed
  reference gain matrix.
- R3.1 and R3.2 are independent of each other's UI; R3.3 needs both.
- R4 (sphere) does not wait on any of R3, and R3.4 is what lets R4 switch head models.
- R5's perf work (3c-perf) can be done any time; its PCA/multi-dipole work wants R3.4's
  `ForwardOperator` first.
- R3 is no longer the long pole. The remaining long pole is R4/R5 science plus R2.4's
  UI design.


## R2.4 — Coregistration UI — **IN PROGRESS**

The first pass is built (see `ROADMAP_COMPLETE.md` § 6). What remains:

- [ ] **Brainstorm the UI with the owner** before polishing: window structure (one
  head-model window vs. a study/project document), the fiducial-picking interaction,
  whether the 3-D view should be the primary surface with slices secondary, residual
  presentation, and how the head model is handed to Fit mode / inverse imaging.
- [ ] Cached lead fields in the package (R4), `.evahead` document type registration,
  drag-and-drop of NIfTI / .mff onto the window, undo for nudges.

---

## R3.2–R3.7 — Import the BEM solution and evaluate it — **IN PROGRESS**
### R3.2 Import the BEM *solution*

This is the part that makes the import worth doing: with the solution matrix in hand we
can evaluate a forward field for **any** dipole, not just the source space someone else
chose.

> **Found 2026-09-06 while building the R3.5 fixtures: only `solver='mne'` solutions
> are importable as *operators*.** MNE writes an OpenMEEG solution into the same
> `-bem-sol.fif`, but it is a different object: the symmetric-BEM head-matrix inverse,
> whose unknowns are vertex potentials *plus* normal currents on the inner interfaces
> (486 → 1126 for a 162-vertex-per-shell head), stored packed as the n(n+1)/2 upper
> triangle. MNE never evaluates it itself — `_compute_forwards_openmeeg` calls back
> into libOpenMEEG (`DipSourceMat` / `Head2EEGMat` / `GainEEG`) to re-assemble the
> source and sensor matrices. Reproducing that means implementing OpenMEEG's symmetric
> BEM, which is exactly the work this redirection exists to avoid.
>
> **The geometry, though, always travels.** Verified on the fixtures: `-bem.fif`,
> `-bem-sol-mne.fif` and `-bem-sol-openmeeg.fif` all carry the same BEM surfaces —
> identical vertices, triangles and conductivities — because `write_bem_solution`
> writes the surface blocks too. Only the solution matrix is solver-specific. So an
> OpenMEEG file is never a dead end; R3.1 reads it like any other.
>
> That leaves an OpenMEEG user three routes, and the UI should offer all three by name:
> (a) re-solve the same imported surfaces with `solver='mne'` — costs OpenMEEG's
> coarse-mesh accuracy, keeps the general operator; (b) solve the imported surfaces
> with EVA's own constant-element BEM, labelled as ours and approximate; (c) export a
> `-fwd.fif` lead field from `make_forward_solution` and accept a fixed source space.
> R3.7 is therefore no longer optional — see it below.

- [x] `BEMSolution` (`EVACore/Core/Forward/BEMSolution.swift`): reads
  `FIFF_BEM_POT_SOLUTION` (3110) and `FIFF_BEM_APPROX` — which is **3111, not 3108**;
  our `FIF.bemApprox` constant said 3108, which is not a tag at all and had never been
  exercised. The solver is not a tag either: MNE records a non-default one as JSON in
  `FIFF_DESCRIPTION` (206) inside the BEM block.
- [x] `FIFReader` now maps the file (`.mappedIfSafe`) and keeps tag payloads as slices
  of that mapping instead of copying each one, plus `matrixDimensions()` and a
  single-precision `floatValues()` — a 3×5120-vertex head is a 15360² float32 matrix
  ≈ 940 MB and there is no accuracy in doubling it. Oversized solutions are refused
  before allocation with a size estimate (2 GB default limit).
- [x] Geometry + solution + approximation + `source_mult` / `field_mult` from
  `_add_gamma_multipliers` (MNE, BSD-3), with the per-shell block ranges the matrix is
  laid out in — **outer first**, the file's surface order, which is the reverse of how
  `BEMGeometry` stores the shells. R3.3 has to keep that straight.
- [x] An OpenMEEG solution is detected (solver tag, 1-D packed storage, `nsol` ≠ vertex
  count) and declined *by name*, keeping its geometry and naming the three routes that
  work — verified in the tests down to the wording.
- [x] Isolated-skull (IPA) is already baked into whatever MNE wrote; we inherit it for
  free and record the approximation in provenance.
- [ ] Store the solution inside `.evahead` verbatim (the original FIF, not a re-encode),
  so the package stays MNE-readable and the provenance chain is intact. Needs R2.4's
  package to grow a slot; do it with R3.6.

### R3.3 `BEMSolutionForwardModel` — evaluating the imported operator

The forward evaluation, given a solution matrix, is small and well-defined; this is the
only real math R3 still owns.

- [ ] **Electrode specification**: project each electrode onto the scalp surface
  (`SurfaceRegistration` already projects), take the barycentric weights of the hit
  triangle, and build the per-electrode row `w · solution[triangle vertices, :]`,
  scaled by the outer sigma. Replaces the current nearest-centroid interpolation and is
  computed once per montage.
- [ ] **Per-dipole evaluation**: infinite-medium potentials of the dipole at every BEM
  vertex, contracted with the electrode rows — a `n_electrodes × n_vertices` by
  `n_vertices × 3` product per dipole, i.e. one BLAS call for a whole source set.
  Target: a 10 000-source free-orientation lead field in seconds, not minutes.
- [ ] **Frames and units, stated once and tested**: surfaces arrive in MRI (metres);
  dipoles and electrodes live in head frame; the `-trans.fif` from R2.4 is the bridge.
  Output in EVA's µV/(nA·m) with the conversion asserted against MNE, not assumed.
- [ ] Reference handling (`average` / `infinity`) identical to the spherical model, so
  swapping head models never silently changes the reference.

### R3.4 `ForwardOperator` protocol and wiring *(kept from the old R3.4)*

- [ ] `ForwardOperator` with `leadField(sources:) -> ForwardLeadField`, adopted by
  spherical, ellipsoidal, our icosphere BEM, and `BEMSolutionForwardModel` — so dipole
  fit, inverse imaging and the simulator are head-model-agnostic.
- [ ] Head-model picker wherever a forward is chosen (Source Simulator, Fit mode, R4),
  with the chosen model's provenance carried into every result and export. A result
  produced under an imported subject BEM must say so, next to one produced under a
  sphere.
- [ ] Lead-field cache keyed by (head model id, montage, reference, source set).

### R3.5 Validation  *(reference fixtures built 2026-09-06)*

- [x] `Tools/forward-compare/make_forward_fixtures.py` (+ `README.md`): for four cases —
  fsaverage watershed surfaces and 72/79/85 mm spheres, at ico2 (committed, ~7 MB) and
  ico3/ico4 (git-ignored `local/`) — writes `-bem.fif`, `-bem-sol-mne.fif`,
  `-bem-sol-openmeeg.fif`, a 32-electrode `-dig.fif` projected onto the scalp, and
  `-trans.fif`, then dumps MNE's EEG gain for 12 fixed dipoles into
  `forward_reference.json`. Runs in ~20 s; bit-reproducible.
- [x] Both solvers on identical geometry, and MNE's analytic sphere as a third opinion.
  Relative Frobenius difference of the whole gain matrix:

  | Comparison | ico2 | ico3 |
  |---|---|---|
  | MNE vs OpenMEEG, fsaverage | 24.3 % | 9.8 % |
  | MNE vs OpenMEEG, spheres | 25.8 % | 8.0 % |
  | MNE BEM vs analytic sphere | 18.3 % | 6.9 % |
  | OpenMEEG BEM vs analytic sphere | 8.7 % | 2.0 % |

  **The two engines are not interchangeable at coarse meshes** — OpenMEEG's symmetric
  BEM is ~3× closer to the analytic sphere than MNE's linear collocation at the same
  mesh. Both converge. Provenance must record which solver produced a head model, and
  the UI should say so wherever a result is shown.
- [x] **OpenMEEG is nondeterministic when threaded**: repeated `make_bem_solution(
  solver='openmeeg')` runs differ by 3 % of peak gain at ico2, 0.8 % at ico3 (parallel
  reduction order, amplified by a poorly conditioned coarse system). The generator sets
  `OMP_NUM_THREADS=1` and computes each gain *from the solution file it just wrote*, so
  the committed (solution, gain) pair answers exactly the question the importer has to:
  given these bytes, what does MNE produce? Worth remembering before we ever quote an
  OpenMEEG number to more than two significant figures.
- [x] Conventions the Swift side must match, pinned in the README and the JSON: gain
  scale 1e-3 from MNE's V/(A·m) to EVA's µV/(nA·m); `n_electrodes × 3·n_dipoles` x/y/z
  layout; **reference is infinity, not average**; surfaces and dipoles in MRI metres
  with electrodes in the head frame; and `make_bem_model` returns surfaces **outer
  first**, the opposite of EVA's stacking — index by surface id, never by position.
  (That one already cost a debugging round: projecting the electrodes onto `surfs[-1]`
  put them 28 mm inside the skull.)
- [ ] The Swift side of the comparison — target <0.1 % relative, the bar the FIF and
  coregistration work already meets. Blocked on R3.2/R3.3.
- [ ] Sphere cross-check against `SphericalForwardModel` itself (the fixture already
  carries MNE's analytic gain for the same dipoles, so this is a Swift-side test).
- [ ] Degenerate-input tests: non-nested surfaces, wrong coordinate frame, missing
  trans, solution/geometry vertex-count mismatch, single-shell head.

### R3.6 UI (Resolve head-model window)

- [ ] An **Import BEM** step next to the existing MRI → Fiducials → Electrodes → Fit →
  Save flow: pick a `-bem-sol.fif` (or geometry-only `-bem.fif`, or an OpenMEEG
  `.geom`), see the shells rendered over the T1 slices and in the 3-D view, see the
  quality-gate report, see which electrodes project where.
- [ ] Clear failure text for the common cases: solution and surfaces disagree, geometry
  is in the wrong frame, no trans yet, file is a bare geometry with no solution (offer
  the `make_bem_solution` recipe, and offer to solve it with our own solver on the
  imported surfaces — that path exists and should be labelled as approximate).
- [ ] Documentation page: "Bringing a head model into EVA Resolve", with the MNE and
  OpenMEEG recipes, what each file is for, and what EVA does and does not compute.

### R3.7 Precomputed lead-field import  *(promoted 2026-09-06 — this is the OpenMEEG path)*

- [ ] Import MNE `-fwd.fif`: the source space (positions + orientations), the gain
  matrix, channel names, coordinate frame and `source_ori`. Needs the FIF reader
  extended to the forward-solution blocks, which is more tags but no new math.
- [ ] Also accept a plain matrix (`.npy` / `.mat` / TSV) plus a source-position file,
  for tools that do not speak FIF. This is the door R6/DUNEuro walks through, and it
  makes FieldTrip and SimNIBS output usable without EVA understanding their internals.
- [ ] A lead field fixes the source space at export time, so the consumers that want an
  arbitrary dipole (R5's fitting) either interpolate within the grid or refuse. Say
  which, in the UI, per consumer — an imported lead field is not a drop-in for a
  solution and must not silently behave like one.
- [ ] Solve on imported surfaces with our own BEM (R3.1 geometry → `BEMForwardModel`)
  for users who have surfaces but no MNE install. Cheap to expose once R3.1 lands;
  label it as our constant-element solver, not MNE's.

---


## R4 — Distributed inverse imaging

Follows ROADMAP Tier 6 (§6.1–6.5) almost verbatim; that design holds. None of this
needs a BEM to start — the sphere lead field is the exact gain matrix — so R4 can begin
in parallel with R3 once R2.1 lands.

- [ ] **6.1 `SourceGrid`**: regular grid clipped to the inner-skull compartment (sphere
  or BEM), fixed or free orientation, deterministic ordering, neighbourhood Laplacian,
  and a cached gain matrix (`channels × 3N`) keyed by head model + montage + reference.
  Later: cortical surface source space from a GIFTI/FreeSurfer surface with
  normal-constrained orientation.
- [ ] **6.2 Minimum-norm family engine**: one operator builder parameterized by
  weighting → MNE, dSPM, sLORETA, eLORETA. Noise covariance from a baseline window
  (with shrinkage), or supplied exactly by the simulator. Regularization as a declared,
  sweepable parameter (fixed λ, L-curve, GCV).
- [ ] **6.3 Spatial priors**: LORETA (Laplacian) and LAURA (local autoregressive) via
  the grid neighbourhood structure. Compartment-edge handling gets its own tests.
- [ ] **6.4 Resolution metrics**: resolution matrix, point-spread, cross-talk, peak
  localization error, spatial dispersion — computed without a simulation run.
- [ ] **6.5 Inverse-crime controls**: generate with one head model, invert with another
  (sphere parameter mismatch first; BEM-vs-sphere once R3 exists). Every result labels
  its regime.
- [ ] **UI**: source-space viewer as MRI slice overlays (volumetric grid) and surface
  colouring (cortical space), time scrubber, threshold/percentile controls, per-method
  tabs on the same data, export of source time courses and maps (NIfTI for volumes,
  GIFTI `.func.gii` for surfaces so AFNI/SUMA can open them directly).

---


## R5 — Dipole fitting on real data — **IN PROGRESS**

Today's `SingleDipoleFit` is a diagnostic against simulated truth on a sphere.
Turn it into the production ECD tool.

Fit mode, the Workbench layout, drag-to-seed refitting, progress and
cancellation, and the 43× performance work are built (`ROADMAP_COMPLETE.md`
§ 6). The layout brainstorm left three questions open, and the science is
untouched.



Brainstormed three window layouts for the `.fit` side of the existing `Simulate | Fit`
`Picker` in `SourceSimulatorWindowView` (that master switch already exists — see
`SourceSimulatorController.WindowMode`; this is about what `SourceFitModeView` shows,
not a new window). Sketches: `resolve-layouts.html` (published as a Claude artifact,
not checked into the repo).

**Chosen: "Workbench"** — three fixed panes, always visible, no drawer/mode switching:
- Left: condition list (extends the per-condition concepts already in
  `FitConditionPalette`; today there's no dedicated chooser control, just legends).
- Center: the glass head, replaced by **three linked orthogonal views** — axial,
  sagittal, coronal — stacked vertically, each a generic head silhouette (not real MRI)
  around the same skull/brain rings. A dipole dragged in any one view updates one shared
  `(x, y, z)` per source, so the other two views move with it immediately.
- Right: waveform panel with a **raw / PCA / both** toggle (new — no PCA toggle exists
  in EVAResolve's `Waveform` view today).

Rejected: "Split Stage" (waveform + single head side by side, closest to today's shape
but the head gets small on a laptop) and "Head-First Drawer" (head as hero, waveform in
a bottom drawer — good for skimming many fits, worse for careful raw-vs-PCA QC).

**Open questions to resolve before implementation:**
- The sketch draws one fixed sphere behind all three head silhouettes (a sphere's
  silhouette is a circle from any angle, so this is free in the mockup). The real head
  model (R3's BEM, or even R2's ellipsoid) is not a sphere — each of the three views
  would need its own slice of the actual geometry, not one shared circle.
- Whether dragged sources clamp to a free sphere interior (as sketched) or to the real
  source space / grey-white boundary once R4's `SourceGrid` exists.
- Whether the views need a numeric (x/y/z or mm) readout for precision editing, or stay
  drag-only.


- [ ] **Head-model agnostic**: fit against any `ForwardOperator` (R3.4), including BEM.
- [~] **Stage 3c-perf** from ROADMAP: precomputed free lead-field grid per geometry,
  trilinear interpolation, Levenberg–Marquardt / Nelder–Mead refinement from the grid
  seed, Accelerate for the linear moment solves. Target: single ECD instant, multi-ECD
  sub-second.
  - [x] **First pass done 2026-09-05 — 6.4× (40.87 s → 6.34 s)** on the benchmark
    (64 channels, 256 samples, 2 conditions, 3 dipoles; `benchmarkSharedFit`). All 35
    EVAResolve tests still pass, so positions/GOF are unchanged — only the cost moved.
    Three changes, none of them the ROADMAP items above:
    1. **Flat buffers.** The candidate loop was allocating one small `[Double]` per
       channel per candidate (~70k allocations per dipole search). Designs are now
       flat row-major with preallocated per-worker scratch.
    2. **Rank-reduced covariance.** `C ≈ W·Wᵀ` keeping `3·dipoles + 8` components, so
       the objective is `LᵀCL = (WᵀL)ᵀ(WᵀL)` at O(r·C·p) instead of forming `C·L` at
       O(C²·p). A model with `p` free spatial dimensions cannot explain more than `p`
       components, so this is the standard signal-subspace argument. Search-only:
       `finalize` still uses the exact full covariance, so reported GOF is untouched.
    3. **Parallel candidate scan.** Note the ordering trap: parallelising only the
       scoring gave just 2.1×, because `freeLeadField` still ran serially ahead of the
       parallel region. Each worker must solve the forward model for *its own slice* —
       the spherical-harmonic series is the dominant cost, not the linear algebra.
       That took it from 19.5 s to 6.34 s.
  - [x] **Second pass done 2026-09-05 — 43× on cached fits (40.87 s → 0.95 s),
    14× on a cold one (2.88 s).** Single ECD is 0.18 s, so the ROADMAP's "single
    ECD instant, multi-ECD sub-second" target is met once the grid is warm.
    All 35 EVAResolve tests still pass.
    - **Phase timing** added to `ProgressReporter` (`PhaseTimings`), which is how
      each step below was targeted instead of guessed. Reachable from tests via
      `runSharedFitNow(reporter:)`.
    - **Reduced harmonic order in the search** (24 terms, vs the caller's 60 for
      `finalize` / `deflateCovariance` / `decompose`, which stay exact): 6.13 s →
      3.56 s. Sources are clamped to 0.97 R, well inside the shell, where the
      series has converged by ~24 terms.
    - **Precomputed lead-field grid** (`LeadFieldGrid`) at `brainRadius/12`,
      trilinear interpolation, `Float` storage, cached per geometry (≈19 MB at 64
      channels, ≈75 MB at 256; at most 3 kept). Candidate scoring stops solving
      the forward model entirely: refinement 2.42 s → 0.59 s, coarse 0.95 s →
      0.24 s. Nodes at/outside the innermost shell are unsolvable, so they are
      marked invalid and the few candidates needing them fall back to an exact
      solve; `finalize` is always exact.
    - **Hoisted fixed-dipole blocks** in the joint objective (`FixedBlocks`):
      exact, but a modest ~10% — the refinement was forward-bound, not
      objective-bound.
    - Measured trap, twice: *anything solved serially ahead of a parallel region
      becomes the bottleneck.* First on `freeLeadField` before the candidate scan,
      then again on the grid build itself (5.99 s serial → 1.79 s parallel).
  - **Not needed after the above:** Levenberg–Marquardt / Nelder–Mead refinement
    and RAP-MUSIC seeding. With the grid warm, refinement is 0.59 s and the coarse
    search 0.24 s; replacing either would be significant algorithmic risk for a
    fraction of a second. Revisit only if a realistic BEM (R3) makes per-candidate
    evaluation expensive again — at which point the grid is the thing that scales,
    not the search strategy.
  - [ ] Remaining cost is the one-time grid build (1.89 s, 66%). If that matters,
    build it lazily in the background when a dataset loads, or coarsen the lattice
    and lean on the exact final refinement.
- [ ] **PCA-driven model order**: SVD of the channels × samples window; show the
  explained-variance ladder; seed one dipole per retained component (Scherg-style
  spatio-temporal model), then jointly refine positions with fixed or rotating
  orientations. Extend `fitSpatioTemporal` / `fitSharedGeometry`, which already hold the
  shared-geometry, per-condition-moment structure.
- [ ] **Regional sources** (three orthogonal dipoles at one location) as a fit type.
- [ ] Residual variance over time, goodness-of-fit per interval, confidence volumes
  (Hessian-based), symmetric dipole-pair constraint, and "fit this interval" interaction
  in the butterfly plot.
- [ ] Export dipoles (position, orientation, moment time course) as JSON and as a
  NIfTI marker volume in the head model's frame.

---


## R6 — FEM: **import from DUNEuro** (long term)

Same decision as R3, one step further out. Writing a hex-FEM solver, a 6-tissue
segmentation and an anisotropy pipeline is a multi-year project that SimBio/DUNEuro and
SimNIBS have already done under free licenses; EVA's contribution is not a better
solver.

- [ ] **Import a DUNEuro transfer matrix / lead field** for a source space the user
  defines outside EVA (`.npy` / `.mat` / DUNEuro's own output plus a source-position
  file). This is R3.7's precomputed-lead-field importer, generalized — build it once,
  and BEM-from-anywhere and FEM-from-DUNEuro both arrive through the same door.
- [ ] Carry FEM provenance (tissue set, conductivities, anisotropy, solver settings) as
  opaque metadata into every result and export, so a FEM result is never mistaken for a
  BEM or sphere result.
- [ ] Optional viewer support for a labelled volume (the FEM's segmentation) as an
  overlay on the T1, since we already read NIfTI — display only, not computation.
- [ ] Validation: the same fixed dipole set through sphere, imported BEM and imported
  FEM, reported as a head-model sensitivity table. That comparison *is* the deliverable
  (Tier 6.5 inverse-crime study); the solver behind each column is not.
- Only reconsider writing a solver if a concrete need appears that no external tool
  serves — and record that need here before writing a line of it.

---


## Source Simulator — Stage 4: SIM-3 tier A (SceneKit) — **DEFERRED** until tier B proves out

- [ ] **Tier A:** a true orbiting, zoomable glass brain in SceneKit, once tier B
  proves the interaction is worth the 3D dependency.
- [ ] **Tier C** (MRI-backed mesh) only if real segmented anatomy is imported —
  not required for the parametric sphere/ellipsoid heads.

**Overall exit:** a user builds a multi-source scenario interactively in the Source
Simulator window, sees its live field, drives it with time courses, and reads a
truth-backed score. **Effort:** large overall; Stage 1 is small–medium and
independently valuable.

---


---

# 7. Simulation

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


Tiers 1, 2, 4 and 5 are complete, as are 3.1, 7.1–7.3 and 8.1; the completion
status table and every delivered tier are in `ROADMAP_COMPLETE.md` § 7.

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

## EVASimulate — open tiers

### Tier 3 — valuable, more work

#### 3.2 Comparison harness

Run N methods × M scenarios, emit the table and the figure. This is the step that
turns "we have a simulator" into "here is the results section."

**Effort:** medium-large. **Depends on:** 2.3, 2.4. **No longer blocked:** the
event-precision bug that made EVA's gradient stage intermittently refuse
generated recordings was 4.9, fixed 2026-08-21.

##### Phase A — DELIVERED (2026-08-27)

`EVATests/Pipeline/MethodComparison/` — matrix, runner, tests — plus
`scripts/compare-methods.sh`.

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
container, and `scripts/compare-methods.sh` copies the results back into
`.comparison/` from outside. That script also passes `TEST_RUNNER_EVA_COMPARISON=1`, which is
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
the completion-status table in `ROADMAP_COMPLETE.md` § 7. If the two
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

---

## Synthetic sleep EEG (SL-1 … SL-7) — **NOT STARTED**

Generate a whole night of EEG with a known hypnogram, and with every spindle,
K-complex, slow wave, vertex wave and sawtooth train labelled to the sample. The
output is a normal EVA recording, so it flows through filter / ICA / PCA-S /
scoring exactly like any other, and the truth sidecar answers questions no real
dataset can answer at all.

**Why this is worth building, in one paragraph.** Sleep-EEG methods are validated
against expert scoring, and expert scoring is the weakest link in the chain:
MASS and DREAMS between them offer a few dozen records, spindle marking is
famously low-agreement between scorers, and nobody can tell you the *true* onset
of a spindle in a real recording because there is no such fact to appeal to. A
generator inverts that. A thousand nights, every event's onset and frequency
known exactly, detection scored as a curve rather than as agreement with a
second opinion. EVA already owns the two pieces that make its version of this
better than a generic one: a **dipole forward model**, so slow waves can be a
frontal-midline source and spindles a centroparietal one and the topography is
correct by construction rather than asserted; and the **EEG–fMRI artifact stack**,
which makes "does my BCG correction survive sleep data" answerable for the first
time. That second one is not a hypothetical: the BCG lives around 1 Hz, directly
on top of the slow oscillation, and gradient residuals sit near the spindle band.
Anyone doing sleep in the scanner is correcting artifacts whose spectra overlap
the signals they came for, and right now there is no way to measure what that
costs them.

**The one architectural rule.** Two layers, separated absolutely:

1. **The hypnogram generator** decides the stage sequence. Nothing else.
2. **The signal model** synthesizes EEG conditioned on a stage sequence it is
   handed. It never decides what stage it is in.

Everything good follows from that split. A hand-written hypnogram, a drawn one,
and one imported from a real scored night are the same input to layer 2, so
"resynthesize EEG onto this patient's real architecture" costs nothing extra. It
also means the hypnogram is testable on its own — against transition statistics
from the literature — without generating a single sample.

**The rule that keeps it honest.** *Do not add a waveform the truth file cannot
label.* If a feature cannot be written down as "event of type X at time T on
source S with parameters P", it buys realism at the cost of the only thing that
makes this worth building. This is the reason the plan below phenomenologically
places templates rather than porting a thalamocortical neural-mass model: the
neural-mass models produce beautiful signals that nobody can annotate.


Literature and settled design decisions:
[`docs/design/sleep-eeg.md`](docs/design/sleep-eeg.md).

## SL-1 — Hypnogram generator, truth, and the Sleep tab skeleton — **NOT STARTED**

The whole milestone generates no EEG. That is deliberate: the hypnogram is
separately testable against published transition statistics, and getting it
wrong is the failure that would poison every later milestone invisibly.

- [ ] `SleepStage`: `wake`, `n1`, `n2`, `n3`, `rem`. `Codable`, `CaseIterable`,
  with `aasmLabel` ("W", "N1", "N2", "N3", "R") for export. Epoch length is
  **30 s**, fixed, because that is what the scoring rules and every external
  tool assume.
- [ ] `HypnogramGenerator.draw(config:seed:) -> [SleepStage]` — second-order
  Markov chain over 30 s epochs, with **time-varying rates**. State is the
  current stage *and* the previous one, per PMID 30089099.
- [ ] **Process S** drives the N3 propensity: `S(t) = S₀·exp(−t/τ)`, with `S₀`
  from `sleepPressure` and τ from `processSDecayHours`. The N2→N3 rate scales
  with S, and the N3→N2 rate inversely. This is the mechanism that makes N3
  concentrate in the first two cycles without anything hard-coding "first two
  cycles".
- [ ] **REM propensity** rises with time since sleep onset and with cycle count,
  so REM bouts lengthen toward morning. Target REM latency and cycle period are
  parameters, not constants.
- [ ] **Minimum bout length** per stage, enforced after drawing. Without it the
  chain emits 30 s N3 flickers that no real hypnogram contains and no scorer
  would mark.
- [ ] **Skip-transition control** — an explicit probability for non-ordinal
  moves (N1→N3, N2→W). Real hypnograms are overwhelmingly ordinal; an
  unconstrained chain produces far too many jumps, and detectors trained on real
  data fail in strange ways when handed them. This is a knob, not a constant,
  because deliberately raising it is a legitimate robustness test.
- [ ] Arousals (brief W intrusions, 3-15 s, scored within the epoch) and
  sustained awakenings, as separate rates.
- [ ] `HypnogramSource`: `.markov` (drawn) · `.scripted` (a stage list authored
  in the config) · `.imported` (read a scored hypnogram file). Support at least
  one real format — Sleep-EDF `.hyp` / EDF+ annotations is the widest — so
  "resynthesize EEG onto this patient's real night" works from day one.
- [ ] **Truth:** the hypnogram as an epoch array, plus per-epoch Process S,
  cycle index, and time since sleep onset. Written to the existing truth sidecar.
- [ ] **Events:** each stage transition as an MFF event, so the hypnogram is
  visible on the EVA timeline without any new UI.
- [ ] **Sleep tab skeleton** in Simulator Studio: source picker, duration,
  onset/REM latency, cycle period, sleep pressure, transition preset, and a
  **live hypnogram preview** (a small staircase plot — it costs almost nothing
  and it is the only way to tell at a glance that the parameters are sane).
- [ ] **CLI:** `--sleep`, `--sleep-hours`, `--sleep-preset`, `--hypnogram <file>`,
  `--sleep-pressure`, `--rem-latency`, `--cycle-minutes`, `--skip-transitions`,
  `--arousals-per-hour`.
- [ ] **Gate:** generate 100 nights and check the aggregate statistics against
  the literature — total sleep time, N3 concentrated in the first half, REM
  proportion rising across the night, REM-onset intervals centred near 90 min,
  ordinal transitions dominating. Assert on distributions, not on single nights;
  a single night is legitimately allowed to be unusual.

**Effort:** medium. The chain is small; the calibration gate is the work.

## SL-2 — Stage-conditioned background: aperiodic slope and band content — **NOT STARTED**

Makes the stages distinguishable to anything spectral, before a single discrete
event exists. This is a surprisingly large fraction of the perceived realism for
a small fraction of the effort.

- [ ] **Per-stage aperiodic exponent**, defaulting to the eNeuro values (wake
  −1.11, N1 −2.4, N2 −2.58, N3 −2.34, REM −3.3). Synthesize 1/f^β noise per
  epoch and cross-fade across epoch boundaries — a hard switch at an epoch
  boundary is an audible step and an artifact in every spectral estimate.
- [ ] **Per-stage band amplitudes**, reusing the existing `EEGBand` machinery:
  alpha dominant in wake and attenuating into N1, theta rising in N1, delta
  dominating N3, and REM's mixed-frequency low-amplitude profile.
- [ ] **Overnight drift** of slope and intercept, per Sci Rep 2022, tied to the
  same Process S the hypnogram uses — so the background and the architecture
  are driven by one quantity rather than two that can disagree.
- [ ] **Cross-fade window** as a parameter, defaulting to a few seconds.
- [ ] **Gate:** fit the aperiodic exponent back out of each generated epoch (over
  30-45 Hz, the paper's range) and recover the requested β within tolerance.
  This is a closed loop — the number that goes in comes back out — and it is
  worth more than any amount of eyeballing the trace.

**Effort:** medium. 1/f^β synthesis is standard; the epoch cross-fade is the
fiddly part.

## SL-3 — Spindles and slow waves as dipole sources — **NOT STARTED**

The first milestone whose output an external tool can score, and the point at
which the feature starts earning its keep.

- [ ] **Source placement** (`SleepSourceLayout`): slow waves as a frontal-midline
  source, fast spindles centroparietal, slow spindles frontal. Under
  `--eeg-model dipole` these project through the existing forward model and the
  topography is correct by construction. Under the Grouiller model, fall back to
  a fixed topography and **say so in the truth file** — a topography that was
  asserted must be distinguishable from one that was derived.
- [ ] **Spindle events** as `HighRateTemplate` instances — the same mechanism the
  BCG and ERP already use. Gaussian-windowed sinusoid, waxing and waning.
  Parameters per spindle, drawn from the PMC12172134 ranges: frequency,
  duration, amplitude. Fast/slow ratio and per-stage density are config.
- [ ] **Slow-wave events**: 0.5-2 Hz, with the asymmetric down-state/up-state
  morphology rather than a sinusoid. Density and amplitude per stage.
- [ ] **The N3 rule as a closed loop.** Amplitude is calibrated so that a
  generated N3 epoch actually meets the AASM criterion — ≥ 20% of the epoch at
  ≥ 75 µV peak-to-peak in 0.5-2 Hz, measured frontally. Do not set an amplitude
  and hope. Measure the generated epoch, and make the test assert it.
- [ ] **Truth:** every spindle (onset, duration, peak frequency, amplitude,
  source, fast/slow) and every slow wave (onset, duration, amplitude, source),
  as a typed array in the sidecar. This is the deliverable.
- [ ] **Gate:** (1) the N3 rule above; (2) run **YASA**'s spindle detector over a
  generated night and check detection rate and onset error against the truth
  file. An external detector agreeing with the generator is the first real
  evidence the morphology is right — and where it disagrees, the disagreement is
  interesting rather than embarrassing.

**Effort:** medium-large. The templates are easy; source placement and the N3
calibration loop are the work.

## SL-4 — K-complexes, vertex waves, sawtooth waves, SO-spindle coupling — **NOT STARTED**

- [ ] **K-complexes**: negative sharp wave then positive component, total ≥ 0.5 s,
  frontal-maximal per AASM. Both spontaneous and evoked — the evoked path should
  reuse the ERP machinery's stimulus timing, which makes auditory-stimulation
  sleep protocols expressible.
- [ ] **Vertex sharp waves**: < 0.5 s, Cz source, N1.
- [ ] **Sawtooth waves**: 2-6 Hz serrated trains, central, placed just before REM
  saccade bursts (SL-5) so the temporal relation AASM describes actually holds.
- [ ] **SO-spindle coupling** — spindles preferentially placed at a configurable
  phase of the slow oscillation, with configurable strength. `PhaseAmplitudeCoupling
  Config` already exists and this is the same machinery pointed at a new pair of
  bands. Truth records each spindle's SO phase, which makes coupling-strength
  estimators scoreable against a known answer. This is the most-published measure
  in the sleep/memory literature and the one where a generator with known ground
  truth is worth the most.
- [ ] **Gate:** recover the imposed coupling phase and strength from the generated
  signal, the same closed-loop shape as SL-2's exponent check.

**Effort:** medium.

## SL-5 — REM: saccade bursts and muscle atonia — **NOT STARTED**

- [ ] **REM saccade bursts** on the EOG channels, using the existing ocular model
  with REM-appropriate timing and density.
- [ ] **Chin EMG atonia** — muscle tone *drops* in REM, which the existing EMG
  model can express with a per-stage amplitude scale. Worth calling out because
  no threshold-based artifact detector expects a channel to get quieter, and
  several will mis-handle it.
- [ ] Per-stage EMG and movement-artifact scaling generally: a sleeping subject
  moves less, and then moves a lot at an arousal.
- [ ] **Gate:** REM epochs show the expected EOG burst density and reduced EMG
  amplitude relative to NREM.

**Effort:** small. Both models exist; this is per-stage modulation of them.

## SL-6 — Scoring: `score-sleep` and `score-hypnogram` — **NOT STARTED**

Ground truth that cannot be scored is decoration. `score-events` already exists
and does most of this; these are two thin subcommands over it.

- [ ] `eva-simulate score-hypnogram --truth <truth.json> --scored <hypnogram>` —
  epoch-wise agreement, Cohen's κ, and a confusion matrix by stage. κ against a
  *known* hypnogram is a fundamentally different measurement from κ between two
  scorers, and the distinction is worth stating in the output.
- [ ] `eva-simulate score-sleep --truth <truth.json> --detected <events> --type
  spindle|slow-wave|k-complex` — detection rate, false-positive rate, onset error
  distribution, and duration error. Reuse `score-events`' matching logic.
- [ ] Tidy CSV export of both, in the same schema the rest of the simulator's
  scoring uses.

**Effort:** small. Mostly plumbing over machinery that exists.

## SL-7 — Pathology presets and EEG-fMRI sleep composition — **NOT STARTED**

- [ ] **Presets**, each a transition matrix plus per-stage content overrides:
  *healthy young adult* · *elderly* (reduced N3, fragmented) · *sleep-onset REM*
  (narcolepsy) · *periodic arousals* (apnea-like) · *suppressed N3* (depression) ·
  *spindle deficit* (the schizophrenia phenotype; see Nature Schizophrenia
  2019;5:9 for the distributed slow-wave dynamics).
- [ ] **Sleep-in-scanner composition** — a scenario that layers the gradient
  artifact and BCG on top of a generated night. This is the milestone the whole
  part is pointed at: the BCG sits around 1 Hz, on top of the slow oscillation,
  and gradient residuals sit near the spindle band, so a correction that looks
  fine on awake resting-state data may be removing the signal. With this, "how
  many true spindles survive AAS + OBS correction" is a number.
- [ ] Ship it as `scenarios/sleep-in-scanner.json` and add it to the determinism
  baseline.
- [ ] **Gate:** score spindle recovery through the full artifact-correction
  pipeline, against the truth file, at several BCG amplitudes. That curve is a
  publishable figure and it is the argument for the entire part.

**Effort:** medium. The presets are data; the composition scenario is the
valuable half.

---


---

# 8. RSA

Making EVA a near-seamless producer of the representational dissimilarity
matrices `3dRSA` consumes, plus the sensor-space RSA that belongs in EVA itself.
**Nothing is scheduled**; these phases enter the priority table when the work is
picked up.

The interchange contract (verified against `3dRSA` source), its two traps — sign
sense and condition order — the estimator ladder, the scientific hazards, and
the `3dRSA`-side changes worth requesting are all in
[`docs/design/rsa.md`](docs/design/rsa.md).

## Phases

### RS-1 — Core RDM engine — *foundation*

`RSAPatternExtractor` + `RSADistance` + `RSAMatrix`. Condition-average patterns
over a `ChannelSet` and a time window; correlation and Euclidean distance;
pooled-condition detection wired in from `TrialSimilarityAnalyzer.pooledRelations`
so a pooled pair is flagged rather than silently reported as near-zero distance.

**Exit criteria**
- Round-trip test: a synthetic geometry recovers to within tolerance.
- Symmetry and finiteness hold by construction, asserted in tests.
- Pooled conditions surface as a warning carrying both category names.
- Unequal-N is reported per condition, with the ≈1/n bias stated numerically.

### RS-2 — Crossnobis and noise normalization

`RSACrossnobis` + `RSANoiseCovariance`. Block-contiguous folds; `none`/`diag`/
`shrinkage` matching `3dRSA`'s `-noise_norm` vocabulary exactly.

**Exit criteria**
- Numerical parity with `THD_simmat_crossnobis` on shared fixtures, to float
  tolerance. Fixtures live in `EVATests/RSA/`.
- Rank accounting from `eva.xml` (reference, ICA, interpolation) reported, and
  `shrinkage` forced when the covariance is singular.
- Negative distances preserved, never clipped, with a test asserting it.
- Refuses < 2 folds, or < 3 trials per condition per fold, with a message that
  says what to do instead.

### RS-3 — Export to 3dRSA (P1)

`RSAExport`. Writes:

```
<prefix>.1D            square matrix, zero diagonal, # header
<prefix>.rsa.json      manifest
<prefix>.3dRSA.txt     ready-to-run command template
```

Header (skipped by `mri_read_1D`, retained in `comment_buffer`):

```
# EVA RDM
# sense: dissimilarity
# estimator: crossnobis
# noise_norm: shrinkage
# n_conditions: 6
# conditions: LC++ RC++ LI++ RI++ Neut Fix
# channels: occipital (24 of 128)
# window: 80..180 ms
# eva_pipeline: <digest>
```

The manifest carries the same plus per-condition trial counts, fold structure,
sampling rate, reference, rank, and the full `eva.xml` step list.

**Exit criteria**
- Files pass `THD_simmat_read_1D` unmodified — verified by an actual `3dRSA` run
  in the test script, not by inspection.
- Symmetry margin is well inside `1e-5 * (1 + max|entry|)`; the writer
  symmetrizes as `0.5 * (M + Mᵀ)` before writing rather than trusting arithmetic.
- The command template names a **sense-consistent** neural metric, and the
  exporter refuses to emit a template that mixes senses.
- `Tools/check-rdm-order.sh` compares the manifest's condition order against
  `3dinfo -label` on a named fMRI dataset and exits non-zero on mismatch.

### RS-4 — Time-resolved series (P2)

A stack of spatial RDMs, one per latency bin, plus the `-model_series` list.

**Exit criteria**
- Time labels are single tokens, unique, monotonic, and encode sign and unit
  unambiguously (`m100ms`, `p000ms`, `p100ms` — leading `-` is legal in the file
  but reads badly in the output table and sorts wrongly by eye).
- Matrices written beside the list with bare relative filenames.
- ≥ 2 time points enforced in EVA, with EVA's own message, before the user
  discovers it from `3dRSA`.
- **Default to time bins, not raw samples.** 250 Hz over −200…800 ms is 250
  matrices and a 250 × n_searchlight joint FWE family. Default bin ≈ 10 ms with
  the count and the resulting family size shown before writing.
- A note in the template that joint/contrast/commonality/LOO are rejected under
  `-model_series`, so the user is not surprised.

### RS-5 — Subject × subject RDMs (P3)

From combined multi-subject data: each subject's condition RDM triangle becomes
their feature vector; the subject × subject matrix is the distance between those
triangles. This is exactly `3dRSA`'s second-order IS-RSA feature construction
(`3dRSA.c:1705`) — including the `1 - s` conversion that puts correlation-based
inner RDMs into a common dissimilarity sense — so it must match it.

**Exit criteria**
- Subject order in the matrix matches the `dataTable` `Subj` order; the manifest
  states it and the checker verifies it.
- Parity with `rsa_subject_rdm`'s sense handling on shared fixtures.
- Refuses < 6 subjects, matching `3dRSA`'s own floor (`3dRSA.c:3052`).

### RS-6 — Frequency and time-frequency RDMs

Reuse `ContinuousWaveletTransform` / `WaveletScalogram`. Patterns become
channels × frequencies at a latency, or channels × frequencies × time in a window.
Per-band RDMs (theta, alpha, beta, gamma) exported as separate `-model_mat`
files, which then support `-model_contrast alpha-gamma` at the group level.

**Exit criteria**
- Band edges and wavelet parameters recorded in the header and manifest.
- Power is log-transformed before distance by default, with the choice recorded —
  raw power is heavy-tailed and a Euclidean distance on it is dominated by one
  condition's outlier trials.
- Explicit warning that wavelet time-smearing correlates adjacent latency bins,
  so a time-frequency `-model_series` has a smoother, more autocorrelated time
  axis than a broadband one, and the joint FWE family is correspondingly less
  independent than its size suggests.

### RS-7 — EEG↔EEG and EEG↔behavior, inside EVA

Not everything needs `3dRSA`. Two analyses are naturally EVA's:

- **Temporal generalization.** Correlate the RDM at time *t* with the RDM at
  time *t′* for all pairs — the standard "is the representation stable or
  dynamic?" matrix. Purely internal; renders as a heatmap.
- **Model / behavior RDMs.** Build an RDM from a per-condition covariate
  (accuracy, RT, a rating, a stimulus property) or from a categorical design, and
  Mantel-test it against the EEG RDM with condition permutation. Single-subject
  level only; the group test stays in `3dRSA`.

The behavior side needs a table importer — conditions × covariates. `TW-6 —
Trial covariates` in `ROADMAP.md` is the same importer; build it once.

**Exit criteria**
- Permutation relabels **conditions**, applied to rows and columns together —
  never the triangle entries. That is the classic Mantel error and `3dRSA` calls
  it out by name (`3dRSA.c:361`).
- Below 6 conditions the Mantel test is refused, matching `3dRSA`.
- Model RDMs export through the same RS-3 writer, so a design matrix built in
  EVA can be a `-model_mat` too.

### RS-8 — Display

Heatmap with condition labels (from `ClusterStatisticHeatmap`), classical MDS
scatter (from `symmetricEigenDecomposition`), hierarchical dendrogram, and a
filmstrip/animation over the time-resolved stack (from `TopoFilmstripView`).
All routed through `FigureExportBasket` so an RDM figure composes with the rest.

**Exit criteria**
- Diverging colormap centred on zero whenever the estimator is crossnobis, since
  the sign is meaningful there and a sequential map hides it.
- MDS reports the variance explained by the plotted dimensions; a 2-D MDS of a
  6-condition RDM can be nearly meaningless and must say so.
- Every figure caption carries estimator, sense, channel set, window, and n.

### RS-9 — Headless and batch

RDM export as a step in the batch/replay path, so a study's 40 subjects produce
40 manifests without 40 trips through the UI.

**Exit criteria**
- Deterministic: the same input and parameters produce byte-identical `.1D`
  files. Folds derive from `SeededGenerator` with the seed recorded.
- Runs under `scripts/check-determinism.sh`.
- A group-level convenience script assembles per-subject manifests into a
  `dataTable`/`runwiseTable` skeleton.

---


---

# 9. UI, Figures & Export

## UI-1 — Display density and montage control — **NOT STARTED**

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

## UX-1 — Figure Composer Phase 2 — **NOT STARTED**

Replace contact-sheet-only layout with a freeform publication canvas: drag,
resize, multi-select, snapping/alignment guides, and multiple pages. Preserve
vector PDF as the primary format; SVG remains out of scope unless a dependable
writer is adopted.


### Averages and topography

#### F-1a — Topomap variability through marker size — **DEFERRED (planned 2026-09-05)**

Add the “marker size change” display: keep the interpolated scalp colour as the
mean voltage at the selected latency, and scale each electrode marker by that
channel's trial-to-trial uncertainty. This is an **opt-in display feature**, off
by default in Preferences. It is not a processing step, must not modify the
signal, and does not belong in `eva.xml` or the history graph.

**Recommended v1 contract.** Name the control **“Scale electrode markers by
trial standard error”**, not the broader “variability.” For a category with
`n` retained trials, at each channel and latency compute the unbiased sample
standard deviation across trials and show `SEM = SD / sqrt(n)`. Standard error
matches the proposed figure and communicates uncertainty in the displayed mean;
standard deviation would answer a different question. The hover detail and
legend must say **Trial SEM (µV)** and report `n`, so the encoding cannot be read
as voltage magnitude or electrode importance.

**What already exists.** This is assembly, not new rendering infrastructure:

- `TopomapView` draws every electrode in one overlay loop after the cached IDW
  field raster. Add an optional marker-encoding input there; `nil` must preserve
  today's fixed 3.2-point dots byte-for-byte in appearance. Marker changes do
  not belong in `FieldCacheKey`, because they do not change the interpolated
  voltage image.
- Interactive PSA retains the pre-average trials in
  `EpochingViewModel.segmentedEpochSignal` / `segmentedEpochSegments`.
- `channelInspectorTrialStandardErrorBands` already implements trial SEM from
  sums, sums of squares, and counts. Extract the statistical kernel, but do not
  reuse that path unchanged: it currently builds a selected-channel time band
  and does not itself guarantee that every trial excluded from the displayed
  average is also excluded from the SEM.
- `EpochSNR.categorySNR` already walks the retained trial/category structure,
  but its scalar metrics and channel-collapsed noise curve are not a substitute
  for channel-by-sample SEM. Likewise, topomap Z scaling is spatial SD across
  the values feeding the maps, not trial variability.
- Preferences already use `EVAGeneralPreferences` keys plus `@AppStorage`.
  Add an off-by-default key and a **Topography** section in General preferences.

**Data and statistical pipeline.** Introduce a pure, testable
`AverageTopomapVariability` calculator/store keyed by category. Its source is the
same raw trial cache used to create the average, and its retained-index set is
the union of manual bad-segment exclusions and resolved committed trial
exclusions. For every retained trial, apply the same average reference and
per-channel baseline correction used for the displayed average *before*
accumulating `sum`, `sumSquares`, and `n`. Non-finite samples do not contribute;
return unavailable unless at least two observations contribute to a cell.
Per-epoch bad-channel interpolations already present in the raw epoch cache are
part of the trial values. A channel patched only after global bad-channel
escalation is not equivalent: either perform the same interpolation per trial or
mark its SEM unavailable in v1. Do not silently report variability from the
unpatched source beneath a patched mean.

Compute/cache a `Float` channel × sample SEM matrix for each category when this
preference is enabled, preferably beside the background SNR work. This avoids
rescanning all trials on every latency-slider or joint-marker redraw. Invalidate
it whenever the raw epoch cache, retained trial set, reference/baseline state,
bad-channel decisions, or recording session changes. Calculation must remain off
the main actor; publish only a session-checked completed result, following the
existing SNR task pattern.

**Visual encoding.** Add a small value object to `TopomapView` rather than making
the generic renderer know about epochs or preferences. It should carry the
per-channel values, physical unit/label, contributing count, and a shared scale
domain. Draw hollow, high-contrast circles like the reference design. Preserve
the existing channel hit radius and cluster highlight semantics; if both marker
encoding and `highlightedChannels` are ever supplied, the yellow cluster ring
must remain visually distinct outside the variability circle.

- Map value to **marker area**, not diameter. Equivalently interpolate squared
  radii, then take the square root; retain a small nonzero base dot for zero SEM.
- Use one `0...maxSEM` domain across every condition in the currently displayed
  set. A filmstrip shares one domain across all of its times and conditions;
  joint maps share one across all visible marker boxes. Never auto-normalize
  each map independently, which would make equal-sized circles mean different
  values.
- Clamp maximum diameter from the rendered map size and the layout's nearest-
  neighbour spacing. Dense 128/256-channel nets and 130-point filmstrip tiles
  must remain legible. If a robust percentile cap is later introduced, disclose
  the cap in the legend rather than silently saturating outliers.
- Add a compact three-circle legend (zero/small, midpoint, maximum) labeled
  `Trial SEM (µV)`. Exported figures must include it whenever variable markers
  are present. Hover text shows mean voltage, SEM, and `n`; unavailable cells
  retain a neutral fixed dot and explicitly say why SEM is unavailable.

**Surfaces in v1.** Wire the optional encoding through all views of a category
mean so screen and export agree:

- Averages workspace Topography grid and its figure export.
- The averaged topography side panel and its export.
- Joint-marker topomaps in Butterfly and Multi-Butterfly, including export.
- Topography filmstrips and their export.

All other `TopomapView` callers pass `nil` and remain unchanged: continuous
recording maps, ICA component maps, artifact/BCG previews and templates,
cluster-statistic maps, source-simulator fields, and other maps without a
well-defined trial SEM. Difference maps are also deliberately outside v1. Their
uncertainty needs paired covariance when conditions share observations, or the
independent-samples formula when they do not; using either condition's SEM or
blindly adding SEMs would be wrong.

**Availability and persistence boundary.** The current MFF averaged-data path
persists `contributingEpochCount`, but not channel-by-sample second moments.
Count alone cannot reconstruct SEM. Therefore v1 shows variable markers only
while the contributing single trials are available in memory and gracefully
falls back to fixed dots after opening an average-only package. Do not estimate
SEM from neighbouring channels or from the scalar SNR/noise curve.

A later persistence phase may store `n` and a second-moment/M2 matrix alongside
the average, with import/export versioning and backwards-compatible absence.
Grand averages are also a later phase: their observational unit is normally the
subject/file average rather than every underlying trial, inverse-variance
weights require weighted variance and effective sample-size handling, and the
current grand-average output retains only a channel-collapsed noise curve.

**Tests and exit criteria.**

- [ ] Pure SEM fixtures: known two-/three-trial values, zero variance, `n < 2`,
  non-finite cells, unequal valid counts, and no negative variance from floating
  point cancellation.
- [ ] Retained-trial parity: manual and committed exclusions change both the
  average and SEM source set identically.
- [ ] Transform parity: average reference and baseline correction are applied
  per trial; the resulting trial mean matches the displayed average within
  tolerance before its SEM is accepted.
- [ ] Cache invalidation and stale-task tests cover recording changes,
  re-averaging, exclusions, reference/baseline toggles, and cancellation.
- [ ] Marker-scaling tests verify area proportionality, finite clamping, a
  shared multi-map domain, adaptive dense-layout limits, and exact fixed-dot
  fallback when the encoding is absent.
- [ ] View/export coverage verifies the preference defaults off, all v1 average
  surfaces agree, a marker legend is present in exports, and unsupported or
  reopened average-only data never displays invented SEM.
- [ ] Visual QA on 32-, 64-, 128-, and 256-channel layouts at full pane, joint
  box, and filmstrip sizes; circles must not obscure the voltage topology or
  make electrode selection/cluster highlighting ambiguous.

**Effort.** A main-pane, in-memory prototype is about one engineer-day. A
production v1 across the listed screen/export surfaces, with caching, legend,
fallbacks, and tests, is a **small-to-medium lift (about 3–5 engineering days)**.
Persisting uncertainty through averaged exports and adding statistically correct
difference/grand-average support is a separate **3–7 day** design and file-format
follow-up, not a reason to hold the in-memory v1.


### App and pipeline polish

- [ ] Reuse an already-open empty window for Finder open events if the stray
  window is confirmed important enough to justify app-delegate routing.
- [ ] Verify platform window-position restoration across relaunch.
- [ ] Publish Channel Set focus from a windowed batch review and wire existing
  net filters into the relevant pickers where useful.
- [ ] Hoist `EventTrackEventSignature`, make displayed-event cache misses async,
  and audit `.task(id:)` signatures only if a new trace shows these paths hot.

### Larger separate workstreams

Both former standalone documents are now tracked in their own sections: the
per-recording quality/provenance report in
[§10 Batch, Replay & Provenance](#10-batch-replay--provenance), and distributed
source imaging in [§6 Source & Forward Modeling](#6-source--forward-modeling).
Neither belongs inside the artifact-correction milestone.


---

# 10. Batch, Replay & Provenance

The batch/replay suite and the REWIND history graph are operational and hardened
(RW-1 closed 2026-08-27). What remains are usability edges.

## PB-1 — Processing and batch completion — **NOT STARTED**

The suite is operational; these are deferred usability edges, not prerequisites
for ordinary batch work.

- [ ] **Partial-then-resume:** run a portable prefix headlessly, then load its
  partially processed signal into a fresh windowed session for decision steps.
- [ ] **Skip all decisions:** optional per-file policy that drops unsupported
  decision steps rather than making the entire script windowed.
- [ ] **Setup compatibility preflight:** inspect chosen files before execution;
  runtime protection already exists in both batch paths.


## REPORTS — typed per-recording quality/provenance report — **DEFERRED**

A typed per-recording quality and provenance report with JSON / HTML / Markdown
output. Previously tracked in `REPORTS.md`, absorbed here.

---

# 11. Performance & Metal

Wavelets and gradient/local-template correction are on the GPU
(`ROADMAP_COMPLETE.md` § 11). The June 2026 audit surveyed thirteen areas;
the eligibility rubric and full option matrix are in
[`docs/design/metal-acceleration.md`](docs/design/metal-acceleration.md).

## PERF-1 — Remaining GPU ports — **DEFERRED, benchmark-gated**

None of these is scheduled. Each is gated on a profile showing the path is
actually hot — the audit's own advice, and the reason its recommended ordering
was not followed. Ordered by the audit's expected payoff:

- [ ] **Artifact template topography and trajectory scans**
  (`EVA/Artifacts/ArtifactTemplateDetector.swift`) — excellent Metal fit, high
  payoff. Dense score buffer on GPU, threshold/merge on CPU.
- [ ] **BCG detection scores** (`EVA/Cardiac/BCGDetector.swift`) — projection,
  GFP, and rolling normalization.
- [ ] **Common reductions** shared by filtering, average reference, GFP, RMS and
  health metrics (`EVA/Filtering/EEGSignalFilter.swift` and callers).
- [ ] **OBS / SSP cleaning** (`EVA/Artifacts/ArtifactCleaner.swift`) — per-window
  fit and taper on GPU, PCA on CPU.
- [ ] **FASTR remainder** — OBS, ANC and sinc resampling; the template/correction
  half is already ported. Do this only after DSP correctness is stable.
- [ ] **Channel and segment health** (`EVA/Health/`) — Welch and windowed
  correlations; mixed fit.
- [ ] **ICA fit/cleaning** (`EVA/ICA/ICAArtifactDetector.swift`) — block matmul
  and tanh, not a full GPU solver, and only after the simpler paths are proven.
- [ ] **Topomap / ICLabel feature-image generation** — self-contained IDW grid to
  texture; schedule only if UI redraw becomes a visible bottleneck.

**Explicitly not porting:** ICLabel inference (already delegated to Core ML on
`.all` compute units) and MFF I/O / XML parsing (poor fit, low payoff).

**Two rules that hold for every port**, learned from the shipped ones and from
the dipole-fit work: express every regression expectation as a tolerance, never
an equality, and pin CPU backends in assertions — CI runners have no usable Metal
device. And *anything solved serially ahead of a parallel region becomes the
bottleneck*; that trap was measured twice in the Resolve fit work alone.

---

# 12. Developer Documentation


A `docs/developers/` tree that traces EVA's features to the code that implements
them — a cross between a Read-the-Docs-style API reference and an onboarding
manual, so a maintainer can find *where* a feature lives and *how* to change it.
Distinct from `docs/manual/` (user-facing) and `docs/provenance/` (method
specs). Independent of every other milestone; it can proceed at any time and in
small increments.

**Two facts that shape the structure.** EVA's source is already grouped into ~23
subsystems under `EVA/` (`Core`, `IO`, `Filtering`, `Gradient`, `ICA`,
`Wavelet`, `Cardiac`, `Epoching`, `Trials`, `Health`, `Channels`, `Artifacts`,
`Pipeline`, `Waveform`, `App`, …), and **nearly every source file already opens
with a rich doc-comment header** describing what it does. So the per-file
synopsis layer is largely *extractable*, and the high-value hand-written work is
the architecture map and the feature→code index that no header can give.

- [x] **DEV-1a — Architecture map.** `docs/developers/architecture.md`: one
  paragraph per subsystem (purpose + key entry-point types), the end-to-end data
  flow (IO → Core → cleaning stages: Filtering/Gradient/ICA/Wavelet/Cardiac →
  Epoching → Trials → Waveform/PSA UI), and the cross-cutting spines (the
  Pipeline history/replay + `eva.xml` provenance, the shared forward model, MFF
  I/O). A diagram is welcome but the prose map is the deliverable.
- [x] **DEV-1b — Per-subsystem pages.** `docs/developers/subsystems/<group>.md`,
  one per top-level group: purpose, the public types/entry points a newcomer
  starts from, a one-line synopsis of each file (seeded from its header comment,
  then curated), and a short "how to extend this" note. This is the "outline of
  each source file" the request started from.
- [ ] **DEV-1c — Feature → code map.** `docs/developers/features.md`: a table
  from user-facing feature (BCG detection, PCA-S correction, wavelet denoising,
  gradient/FASTR, ICA labelling, cluster-permutation stats, trial diagnostics,
  history/undo, batch/replay, MFF QuickLook, figure export, …) to the files and
  entry points that implement it and where behaviour would change. This is the
  index that motivated the whole effort ("where did we build X").
- [ ] **DEV-1d — Keep-it-in-sync.** A lightweight check, in the spirit of the
  existing `docs/manual/contributor-guide`, that flags a new source file with no
  subsystem-page entry (and, ideally, a file whose header changed without its
  synopsis following). Optional: a small extractor that regenerates the
  header-derived synopses so the file layer cannot silently rot.

**Exit:** a maintainer can open `docs/developers/`, find any feature in the
feature map, jump to its subsystem page, and see every file's role — without
reading the source first. **Effort:** medium, mostly writing; DEV-1b is
partly mechanical from headers, DEV-1a/1c are the real authorship.

---
