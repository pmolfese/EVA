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
| 1 | **SI-0 — Characterize source-informed contracts** | Pin the current EVASimulate leadfield and surrogate-filter behavior before moving code. | ✅ **COMPLETED** |
| 2 | **SI-1 — Shared spherical forward model** | Move app-neutral forward math into EVA and make EVASimulate consume it. | ✅ **COMPLETED** |
| 3 | **SI-2 — Shared surrogate-filter engine** | Extract the UI-free PCA-S operator, diagnostics, and stable linear algebra into EVA. | ✅ **COMPLETED** |
| 4 | **RW-1 — Harden history/replay foundations** | Close the bounded REWIND correctness and paired-validation gaps needed by a new correction stage. | **IN PROGRESS** |
| 5 | **SI-3 — EVA broadband BCG PCA-S** | Integrate PCA-S through interactive, headless, replay, history, provenance, and export paths. | **NOT STARTED** |
| 6 | **SI-4 — Adversarial validation** | Measure operating limits under geometry, head-model, rank, channel, and data-quality mismatch. | **NOT STARTED** |
| 7 | **PB-1 — Batch/replay completion** | Add partial resume, decision-skipping policy, and setup compatibility preflight. | **NOT STARTED** |
| 8 | **MRI-1 — FASTR reliability and motion semantics** | Finish motion policy, unreliable-epoch provenance, PSA overlap behavior, and attenuation analysis. | **NOT STARTED** |
| 9 | **SI-5 — Ocular MSEC/PCA-S** | Reuse the validated engine for blink, vertical, and horizontal ocular topographies. | **NOT STARTED** |
| 10 | **TW-4 — Multi-peak trial diagnostics** | Finish the UI and scoring integrations for already-tested alignment metrics. | **IN PROGRESS** |
| 11 | **TW-5 — Persist trial exclusions** | Commit reviewed exclusions as replayable, provenance-bearing processing decisions. | **IN PROGRESS** |
| 12 | **TW-6 — Trial covariates** | Join eye tracking and other trial-level covariates for validation and visualization. | **DEFERRED** |
| 13 | **SI-6 — SSP–SIR comparator** | Add an independently named projection-and-reconstruction comparator. | **NOT STARTED** |
| 14 | **SI-7 — SOUND channel-health experiment** | Evaluate source-informed channel noise estimation against EVA Health. | **NOT STARTED** |
| 15 | **SI-8 — Shared spatial-filter abstraction** | Extract common abstractions only after multiple concrete engines expose them. | **DEFERRED** |
| 16 | **UI-1 — Display density and montages** | Decouple sensitivity from row pitch, add channels-per-screen, then named subsets/order. | **NOT STARTED** |
| 17 | **UX-1 — Figure Composer Phase 2** | Add a freeform, multi-page publication-layout canvas. | **NOT STARTED** |
| 18 | **F-1 — Focused feature backlog** | Finish exports, importer mapping, detector comparators, and other bounded follow-ups. | **DEFERRED** |
| C1 | **Performance/Observation refactor** | Remove measured SwiftUI invalidation, struct-copy, sheet, and scroll hot spots. | ✅ **COMPLETED** |
| C2 | **Processing and batch core** | Establish shared headless transforms, replay compatibility, export, and parity. | ✅ **COMPLETED** |
| C3 | **REWIND foundation** | Linear per-window undo/redo, snapshots, navigation, payloads, progress center, explicit window forks, and multi-window support. | ✅ **COMPLETED** |
| C4 | **App/window stability fixes** | Correct multi-window routing, Batch scene dependencies, focus publication, and new-window workflows. | ✅ **COMPLETED** |
| C5 | **Channel-set geometry catalog** | Persist real net geometries and manage net-specific channel sets. | ✅ **COMPLETED** |
| C6 | **Physical display/export scales** | Label and persist physical display units and correct exported-figure scale metadata. | ✅ **COMPLETED** |
| C7 | **Figure Composer Phase 1** | Basket, reorder/remove, and vector contact-sheet export. | ✅ **COMPLETED** |
| C8 | **Trial-wise diagnostics foundation** | LOO similarity, drift plots, reviewed selection previews, multi-peak metrics, and the dashboard. | ✅ **COMPLETED** |

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

## 2. RW-1 — REWIND hardening required by SI-3 — **IN PROGRESS**

The history foundation is built; do not reopen its architecture. This milestone
is a bounded correctness/validation pass so `bcgCorrection` can join a reliable
pipeline. `REWIND.md` remains the detailed design record.

### REWIND consistency audit — prioritized TODOs (2026-08-25)

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
10. [ ] **Define A/B comparison around related forked windows.** Replace the old
    “select two sibling nodes” prerequisite with a way to identify two windows
    forked from the same state, align their signals/viewport, and compare overlay,
    difference, and health metrics. Decide whether independently opening the same
    file should warn, relate the windows, or remain unrelated.
11. [ ] **Decide portable history versus session cache.** Settle whether export
    carries the whole history or only the current lineage, and whether a slim
    `eva_history.json` accompanies an optional machine-local snapshot/import
    cache. Cache staleness should use cheap source metadata such as mtime + size;
    record enough build/backend compatibility to avoid trusting GPU- or
    Accelerate-derived snapshots across incompatible machines. External motion
    inputs need the same explicit staleness rule. Expanded SHA-256 infrastructure
    is not a prerequisite or project priority.
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
14. [ ] **Close or justify history-derived invalidation.** REWIND still proposes
    replacing clear/cascade logic with history navigation, while the shipped
    architecture centralizes those rules in `PipelineInvalidation`. Treat the
    centralized shared cascade as the final design unless a concrete bug proves
    that deriving invalidation from history would be safer; do not maintain two
    competing architectural promises.
15. [ ] **Define provenance for combined recordings.** Decide whether append,
    grand average, and other multi-recording outputs start a fresh history that
    records input recording/node identities, rather than implying that multiple
    histories can be merged into one linear undo chain.
16. [ ] **Separate “not assessed” from “good.”** Segment Health currently treats
    an artifact metric with no detection run as fully good. Decide and regression
    test an explicit unavailable/not-assessed state before changing exported
    training scores.

### REWIND material carried into this ROADMAP

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

### Canonical REWIND decisions carried forward

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
