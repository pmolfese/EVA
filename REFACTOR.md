# EVA Refactor Map

Decompose the `WaveformView` god object into a testable, layered architecture,
and — as a first dual-purpose slice — lay the substrate for the "Copy Processing
From…" replay feature.

This file is the whole map. Companion memory notes: `eva-refactor-plan`,
`eva-refactor-next-steps` (keep in sync with this file).

---

## 1. The problem

`WaveformView.swift` — current state:

| Metric | Value |
|---|---|
| File lines | ~15,400 |
| `@State` vars | ~303 |
| `private func`s | ~323 |
| `// MARK` domains | ~24 |

The `WaveformView` struct owns ~20 unrelated domains, its signal-processing
pipeline is a chain of `@State` optionals mutated by view methods, and ~62 of the
`@State` vars are settings knobs. The rest of the codebase (L1–L3 below) is already
reasonably modular; **the view is where the debt is concentrated.**

## 2. Goal & target layering

Introduce the **missing L4 layer** and move domain logic into it. Dependencies point
downward only:

```
L1 Foundation   LinearAlgebra, SignalStatistics, SphericalSpline, Downsampler,
                ElectrodeGeometry, SignalSelection, HealthScoring
L2 Models/IO    MFFReader/Writer, SignalImportReader, EGISensorXMLParser,
                SensorLayout, ChannelModel, EVAProcessingScript, MultiRecordingModels
L3 Algorithms   EEGSignalFilter, GradientRemover, ArtifactCleaner,
                ArtifactTemplateDetector, ICAArtifactDetector, WaveletArtifactAnalyzer,
                Channel/SegmentHealthAnalyzer, BCGDetector, RWaveDetector, EpochSNR,
                RecordingCombiner
L4 ViewModels/  ← THE MISSING LAYER — the work. Domain stores that own state +
   Stores         orchestrate L3 engines. WaveformView keeps thin @StateObject refs.
L4.5 Accel.     ← Acceleration-boundary cleanup (see §11 / fix_deprecations.md).
   boundary       Done after L4, before touching L5 views.
L5 Views        WaveformView (now thin), panels, sheets
```

L1–L3 are largely done and tested. L5 exists but is bloated. **L4 is what we build.**

## 3. Current state / what's done

- **Regression-test foundation** (branch `refactor`): ~17 suites / ~38 tests, green.
  Covers L1/L2/L3 engines via public entry points + mffpy fixtures under `EVA/Fixtures/`.
  Does NOT cover the ~323 in-view privates — those get tested per-slice as extracted.
- **Combine-era additions** (already L2/L3/L4-shaped, good precedents to follow):
  `EVAProcessingScript` + `eva.xml`, `EVAProcessLog`, `MultiRecordingModels`, `EpochSNR`,
  `RecordingCombiner`, `NoiseSidecar`, and the `CombineRecordingsSheet` (a self-contained
  L5 sheet backed by L3 logic — the shape we want everywhere).
- **`ChannelGoodnessSettings`** is the one existing L4-ish settings store; generalize it
  for the settings consolidation.

## 4. The full extraction map

Every `WaveformView` domain, grouped by kind, with its target L4 store, an
isolation/coupling rating (how safe the extraction is), and whether it's **dual-purpose**
(also unblocks the replay/copy-processing feature).

### 4a. Processing domains — transform the signal → feed `ProcessingPipeline`
These are the replay substrate. Extract these FIRST.

| Domain (MARK) | L3 engine (exists) | Target L4 | Coupling | Dual-purpose |
|---|---|---|---|---|
| Filtering | `EEGSignalFilter` | `ProcessingPipeline` step | low | ✅ (do first) |
| MRI gradient removal | `GradientRemover` | pipeline step | medium | ✅ |
| Wavelet reduction | `WaveletArtifactAnalyzer` | pipeline step | medium | ✅ |
| Artifact detection/cleaning | `ArtifactCleaner`, detectors | pipeline step | high | ✅ |
| ICA artifact exploration | `ICAArtifactDetector` | pipeline step (config) + result annotation | high | partial |
| PSA epoching / averaging | (in-view) | pipeline step (`segment`/`average`/`baseline`) | high | ✅ |
| Channel interpolation | `SphericalSpline` | **recording annotation** (not a step) | low | result, not param |

### 4b. Analysis domains — produce events/scores, don't transform the signal

| Domain | L3 engine | Target L4 | Coupling |
|---|---|---|---|
| Channel health | `ChannelHealthAnalyzer` | `ChannelHealthViewModel` | low (engine tested) |
| Segment health | `SegmentHealthAnalyzer` | `SegmentHealthViewModel` | low |
| BCG detection | `BCGDetector`, `RWaveDetector` | `BCGDetectionViewModel` | medium |
| Artifact template definition | `ArtifactTemplateDetector` | `ArtifactTemplateViewModel` | high |

### 4c. View/panel domains — mostly presentation, split into own `View` files

| Domain | Notes |
|---|---|
| Topomap panel | already partly its own view (`TopomapView`); extract glue |
| Butterfly panel | self-contained; extract to own file + VM for averaged state |
| Events panel + event track | mostly done inline; move to own file |
| Physio (PNS) pane | own view + small VM |
| Status log | trivial extract |
| Controls (toolbar) | thin, but touches everything — extract last |
| Waveform area (core render) | the actual scope/plot; keep in view, isolate render structs |

### 4d. Infrastructure / cross-cutting

| Domain | Target |
|---|---|
| MFF export | `RecordingExporter` (L4) — pull the snapshot + write orchestration out |
| SwiftData markers | `MarkerStore` |
| Keyboard state | `KeyboardMonitor` helper |
| Geometry helpers | fold into L1 or a small `PlotGeometry` util |

## 5. Cross-cutting stores (the backbone of L4)

Three stores everything else hangs off:

1. **`RecordingStore`** — shared source of truth: the loaded `MFFRecording`, `ChannelModel`
   (bad/hidden/interpolated), viewport (scroll/zoom/amplitude). Domain VMs read this
   instead of threading raw `[[Float]]` arrays through each other. (Memory plan step 6.)

2. **`ProcessingPipeline`** — `source: MFFSignalData`, `steps: [ProcessingStep]`, async
   `output`. Each step applies itself via an L3 engine. Replaces the `@State`-optional
   chain (`rawSignal → gradientCorrected → filtered → … → continuous`). See §7.

3. **Settings stores (L4)** — bucket the ~62 settings `@State` into per-domain stores,
   each tagged **global-default** vs **per-run**. Config STRUCT definitions stay
   decentralized per algorithm (L3); the stores just hold/persist them. Then a centralized
   **Preferences panel** binds to them (generalize `ChannelGoodnessSettingsView`).

## 6. Sequencing

Ordered so each step is a small, tested, committable slice, and the early slices are
**dual-purpose** (advance the decomposition AND unblock replay).

1. **`ProcessingPipeline` + filter slice.** Build the store; refactor the Filtering domain
   (the `filteredSignal` @State, view methods, ~10 knobs) to drive it. Unit-test the store.
2. **Prove replay on filter** — apply one file's filter step to another via the store,
   confirming interactive + replay share one path.
3. **Extend the pipeline by isolation:** gradient → wavelet → PSA epoching/averaging →
   artifact-clean → (last, most coupled) ICA. Test per slice.
4. **`RecordingStore`** — introduce as shared truth once ≥2 pipeline domains exist and the
   array-threading pain is concrete.
5. **Replay UI** ("Copy Processing From…") on top of the pipeline: source picker →
   compatibility-gated step checklist → apply. Add the combine sheet's "Match processing
   to reference" button here too.
6. **Analysis-domain VMs:** channel health → segment health → BCG → artifact template.
   (Their engines are already tested; extract only the view glue.)
7. **Settings consolidation** + Preferences panel.
8. **View/panel splits** (butterfly, events, physio, topomap glue, status log), controls
   last.
9. **Infrastructure:** `RecordingExporter`, `MarkerStore`, keyboard/geometry helpers.
10. **Backfill deferred tests:** ICLabelClassifier (bundled CoreML), ICAComponentAutoLabeler;
    verify `ICAArtifactDetector.fit()` thread-safety (possible shared-mutable-state bug).
11. **L4.5 — Acceleration-boundary cleanup** (see §11). Runs AFTER L4 is extracted and
    BEFORE the L5 view splits, so the Accelerate wrappers land on already-decomposed code.

Deviation from the original memory plan: it led with health/export. We **reorder to lead
with the processing pipeline**, because those slices are dual-purpose (feature + refactor).
Health/export move later.

## 7. `ProcessingPipeline` detail (the feature-driving slice)

```
ProcessingPipeline (L4)
  source: MFFSignalData
  steps:  [ProcessingStep]      // filter, reference, gradient, wavelet, epoch/average…
  output: MFFSignalData         // async fold of source through steps, recompute-on-change
```

Collapses four things into one representation:
- `eva.xml` = serialize `steps` (reuse `EVAProcessingScript`).
- `currentProcessingScript()` = `pipeline.steps` (delete the `@State`-inspection hack).
- Replay / Copy Processing = `pipeline.apply(otherFile.steps)` — same path as interactive.
- Combine "match processing to reference" = apply a reference file's steps to each input.

## 8. Test strategy

**Test-refactor-test, per slice.** In-view privates are unreachable until extracted, so the
first extraction of each is the leap of faith — write the unit test immediately after the
smallest compiling move, then clean up, then commit small. Also add ~5 XCUITest smoke tests
(load fixture → each panel opens → export produces a file) as a thin wiring-breakage net.

## 9. Design decisions to lock up front

- **Async recompute.** Filtering/gradient/wavelet are async with progress. `output` is not a
  synchronous computed property — needs async recompute-on-change with cancellation (reuse
  the channel-health task pattern).
- **Parameters vs. results.** Filter/reference/gradient are portable, replayable params →
  `steps`. **Bad-channel marks, interpolation, ICA component removal are subject-specific
  results** → recording annotations, NOT steps (already `replayable=false` in
  `EVAProcessingStep`). Same split as settings' global-vs-per-run.
- **One code path.** Interactive use and replay must both go through the pipeline store, or
  they drift.

## 11. L4.5 — Acceleration-boundary cleanup (Accelerate deprecations)

Runs between L4 and L5. Full brainstorm in `fix_deprecations.md`. Not a broad rewrite;
small passes that quiet build warnings and create a clean acceleration boundary before any
future Metal work. Warning-prone files: `DSP.swift`, `BCGDetector.swift`,
`ICAArtifactDetector.swift`, `EEGSignalFilter.swift`, `FastrCorrector.swift`,
`LinearAlgebra.swift`, `ICAComponentAutoLabeler.swift`.

Order:
1. Capture actual build warnings; group by API family.
2. Add `AccelerateCompat.swift` / `AccelerateMatrix.swift` wrapper layer.
3. Convert straightforward `vDSP` / `vForce` C-style calls to the Swift overlay
   (`vDSP_meanv → vDSP.mean`, `vvsqrtf → vForce.sqrt`, etc.). **Watch `vDSP_vsub` operand
   order** when moving to `vDSP.subtract` — verify sign.
4. Move CBLAS calls behind `AccelerateMatrix.*` wrappers — keep CBLAS, just contain the
   pointer/row-major details in one place (future Metal/BNNS swap point).
5. Move LAPACK calls behind one or two helpers (`LinearAlgebra.swift`, BCG whitening).
6. Enable `ACCELERATE_NEW_LAPACK` (`-Xcc -DACCELERATE_NEW_LAPACK`); fix compile issues only
   inside the wrapper layer.
7. Numerical comparison against known inputs before considering Metal.

Explicitly NOT worth it: replacing every `cblas_*` just to remove C-style code; combining
this with Metal migration in the same pass.

## 12. Risks / deferred

- ICA is the most coupled domain — extract last; verify fit() thread-safety first.
- The `WaveformView` render core (scope drawing) may be left largest on purpose; isolate its
  render structs but don't force it into a VM if it stays presentation-only.
- Keep L1–L3 clean while working: grep for `import SwiftUI` / upward refs in engine files and
  reject them (cheap invariant to enforce early).
