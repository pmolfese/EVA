# EVA Architecture Map

> **Audience:** maintainers who need to find *where* a feature lives and *how* to
> change it — not end users. Start at the [developer guide](README.md) for setup and a first-change tutorial.
> It is deliberately distinct from `docs/manual/` (user-facing) and
> `docs/provenance/` (method specifications).
>
> **Status:** DEV-1a (architecture map). The per-subsystem deep dives (DEV-1b)
> and the feature→code index (DEV-1c) are separate pages; see
> [Continue through the guide](#continue-through-the-developer-guide).

## How to read this page

The map is organized to mirror how a recording actually moves through EVA:
**load it → clean it → cut it into epochs → analyze the epochs → look at the
result**, with a few *spines* running underneath the whole thing (history/undo,
provenance, channel geometry, the forward model).

Each subsystem gets one paragraph: its **purpose**, the **entry-point types** a
newcomer starts from, and the **key functions** where the real work happens — so
you can jump from "I need to change BCG detection" to the exact
`RWaveDetector.detect(...)` call without reading the tree first. Types are named
as they appear in source; files are given relative to their source-group directory.

A note on build organization before the subsystems: EVA is **not** one target.

---

## Source groups and build targets

EVA is a macOS SwiftUI app with companion apps, Finder extensions, tests, and
command-line tools. A **target** produces a build product. A **source group** is
an organization of files that one or more targets compile. In particular,
`EVACore/` and `EVAPreviewKit/` are shared source groups, not standalone library
targets or separately imported Swift modules in this project.

```mermaid
graph TD
    App["EVA app target"]
    Resolve["EVAResolve app target"]
    QL["EVAQuickLook / EVAThumbnail targets"]
    Tools["EVASimulate target / other CLI build scripts"]
    Core["EVACore shared sources"]
    Preview["EVAPreviewKit shared sources"]
    App -->|compiles| Core
    Resolve -->|compiles| Core
    QL -->|compiles| Core
    Tools -->|compile shared source selections| Core
    App -->|compiles| Preview
    QL -->|compiles| Preview
```

| Source group / product | Role | Build relationship |
| --- | --- | --- |
| `EVA/` → `EVA` | Main application: feature engines, state models, and SwiftUI views. | Also compiles `EVACore/` and `EVAPreviewKit/`; embeds the simulator and Finder extensions. |
| `EVACore/` | Shared computation, format I/O, geometry, simulator models, and `eva.xml` schema. | Compiled into multiple targets. Uses frameworks such as Foundation, Accelerate, Compression, and simd; does not own UI. |
| `EVAResolve/` → `EVAResolve` | Separate head-model/coregistration app. | Also compiles `EVACore/`. |
| `EVAQuickLook/`, `EVAThumbnail/` | Finder preview and thumbnail extension products. | Compile their own entry points plus shared `EVAPreviewKit/` and `EVACore/` sources. |
| `EVAPreviewKit/` | Shared preview readers and views. | Compiled into EVA and its Finder extensions; it is not itself an extension product. |
| `Tools/` | CLI programs such as EVASimulate, EVABIDS, EVAHelper, and format/validation tools. | EVASimulate is an Xcode target. Other tools may compile explicit source lists in their build scripts. |
| `EVATests/`, `EVAUITests/`, `EVAResolveTests/` | App unit/integration tests, UI automation, and Resolve tests. | Separate test targets, selected through the shared EVA and EVAResolve schemes. |

The [setup guide](setup.md#2-open-the-checkout-and-understand-the-build-choices)
lists the eight native targets. Target membership and exception lists in
`EVA.xcodeproj/project.pbxproj`, plus standalone CLI build scripts, determine
which files actually compile into each product; a directory name alone is not
a dependency declaration.

**Placement guidance:** code reused by several products belongs in an appropriate
shared group. App-only engines can remain UI-independent within `EVA/` and be
tested through `EVATests`; testability alone does not require moving them.
SwiftUI recording-window behavior belongs in the app layer. When adding shared
code, verify every consuming target and applicable CLI source list.

---

## The central data model

These types explain the main data and state boundaries. Learn these first.

- **`MFFSignalData`** — `EVACore/IO/MFFReader.swift`. The in-memory
  multichannel signal: sample buffers, sample rate, channel metadata, events. It
  is the currency every cleaning stage consumes and produces. `MFFReader` parses
  the `.mff` package into an `MFFPackage` / `MFFSignalData` / `[MFFEvent]`;
  `MFFWriter` (`EVACore/IO/MFFWriter.swift`) serializes it back out.
- **`MFFRecording`** — `EVA/IO/MFFRecording.swift`. An observable loaded/loading
  recording with file identity, metadata, EEG/peripheral signals, channel-role
  overrides, and security-scoped access. It is not a SwiftUI `FileDocument`:
  EVA uses a normal `WindowGroup` and explicit import/export flows.
- **`RecordingStore`** — `EVA/App/RecordingStore.swift`. Per-window state owner:
  channel state, selection, event/physio display, viewport, status, processing
  history, progress, and export/history task runners. It owns the
  `RecordingHistoryModel`; do not infer history ownership from the recording's
  file identity. See [state ownership](architecture-layers.md).
- **`ChannelModel`** — `EVA/Channels/ChannelModel.swift`. Observable channel state
  owned by `RecordingStore`. Besides channel/interpolation state, this file defines the many
  SwiftUI **environment "command keys"** (`MFFExportRequestKey`,
  `PSAViewControlsKey`, `ArtifactMenuControlsKey`, …) that wire menu bar commands
  to whatever recording is frontmost.
- **`RecordingHistoryModel`** — `EVA/Pipeline/RecordingHistoryModel.swift`. The
  undo/redo **and branching** history tree. `record(...)`, `storeSnapshot(...)`,
  `snapshot(...)` capture state; `ForkSeed` / `adopt(...)` handle branching into
  new windows.
- **`EVAProcessingScript`** — `EVACore/Pipeline/EVAProcessingScript.swift`. The
  `eva.xml` provenance schema: an ordered list of `EVAProcessingStep`s (each an
  `Operation` with parameters and optional `ReplayPayloadAvailability`). This is
  what makes a session reproducible and replayable.

---

## End-to-end data flow

```
  IO ─────────────► Core data ─────► CLEANING STAGES ─────► Epoching ─► Trials ─► UI / export
  SignalImportReader   MFFSignalData   Filtering               PSAAveraging  ClusterPermutation   Waveform
  MFFReader            MFFRecording    Gradient (FASTR/OBS)     EpochSegment  RIDE / Woody         PSA / TF views
  FIF / NIfTI / GIFTI  ChannelModel    Cardiac (BCG/ECG)                      SingleTrialAnalyzer  EEGAnalysis
                                       ICA                                                          FigureExport
                                       Wavelet
                                       Artifacts (template/OBS)
        ▲                                     │
        └──── Channels / forward geometry ────┘   (feeds interpolation, topomaps, source fits)

  Underneath everything:  Pipeline (history · replay · batch · eva.xml provenance)
```

1. **Load.** `SignalImportReader` / `MFFReader` (and the FIF/NIfTI/GIFTI readers)
   produce an `MFFSignalData`, wrapped by an `MFFRecording`.
2. **Clean.** A committed cleaning stage reads the current signal and produces
   a result. Its integration must invalidate downstream work, record the
   appropriate history node/snapshot, and encode a replayable processing step.
   Previews and progress updates are not committed history. See the
   [filtering trace](getting-started.md#follow-a-filter-from-click-to-history)
   and [history/replay contracts](history-and-replay.md).
3. **Epoch.** `EpochingViewModel` prepares and applies a build job that cuts
   event-aligned segments from the signal. `PSAAveraging.commit(...)` commits
   an average of already-built epochs; segmentation and averaging are distinct steps.
4. **Analyze.** Trial-level analyzers (cluster permutation, RIDE, Woody, CWT
   ridges) and the spectral/connectivity engine run over epochs or averages.
5. **View / export.** The Waveform, PSA, Time-Frequency, and Analysis views
   render the result; `FigureExport` turns any of them into publication figures.

The rest of this page walks the subsystems in that order, then the spines.

---

## Subsystems

### Core computation — `EVACore/Core`, `EVA/Core`

The math primitives everything else calls.

- **`EVACore/Core`** — `DSP` (`DSP.swift`) is the shared filter/FFT/convolution
  toolbox; `LinearAlgebra` (`LinearAlgebra.swift`) provides `LUFactorization` and
  `CholeskyFactorization`; `SeededGenerator` gives deterministic RNG (critical
  for the simulator and any reproducible run). `AccelerateCompat` smooths over
  Accelerate API differences.
- **`EVA/Core`** — app-side numeric helpers: `Downsampler`
  (`strided` / `windowedSincDecimated` / `blockAveraged`), `SignalStatistics`
  (percentiles, RMS, variance), `SignalSelection` (valid-channel/segment
  selection), `SphericalSpline` (`interpolationWeights` /
  `interpolationWeightsBatch` — the spherical-spline math behind channel
  interpolation and topomaps), and `CleaningVarianceAccount`, which quantifies
  how much variance a cleaning step removed (`between(...)`, `fromArtifact(...)`,
  `summary(...)`).

### I/O — `EVACore/IO`, `EVA/IO`

Reading and writing every supported file format, plus the app's import/export UI.

- **`EVACore/IO`** — the format readers, all UI-free. `MFFReader` /
  `MFFWriter` (EGI `.mff`); the `FIF/` group (`FIFFile`, `FIFRecording`,
  `FIFMeasurementInfo`, `FIFInterop`, `FIFDocument`) for MNE `.fif`; `NIfTI/`
  (`NIfTIHeader`, `NIfTIVolume`, gzip-aware `NIfTIByteSource`) for volumes;
  `GIFTI/` for surfaces; `EGISensorXMLParser` for sensor layouts; and
  `OpenMEEG/OpenMEEGGeometry` for importing BEM geometries.
- **`EVA/IO`** — the app layer over those readers: `SignalImportReader` (the
  front door for opening a file), `MFFRecording` (the document type),
  `MFFExportWriter` + `MFFExportFlowViews` + `MFFSignalSplitter` (export and
  split-by-category), `PhysioTextImporter` / `PhysioImportViews` (align external
  physio traces), `FigureExport` (`FigureExporter`, `FigureFormat`,
  `FigureCard`) and `FigureExportBasket` (collect figures across the session for
  batch export), and `DatasetInfoSheet`.

### Channels & geometry — `EVA/Channels`, `EVACore/Channels`, `EVACore/Geometry`

Everything about *where* electrodes are and how bad channels are repaired.

- **`EVACore/Channels`** — the geometry substrate: `ElectrodeGeometry` /
  `ElectrodePositions`, `SensorLayout` (`SensorPosition`, `SensorReference`), and
  the built-in `StandardMontage` / `StandardMontageData`.
- **`EVACore/Geometry`** — `HeadTransform` / `CoordinateFrame` (fitting between
  coordinate frames), `TriangleMesh` (+ `SurfaceIndex`, intersection tests) used
  by the forward model and 3-D scalp views.
- **`EVA/Channels`** — the interactive layer: `ChannelModel` (see
  [central data model](#the-central-data-model)); `ChannelSet` / `ChannelSetStore`
  / the editor & picker views for saved montages; `ChannelInterpolationSolver`
  (`Solution`) and `InterpolatedSignalResolver` which lazily materialize
  interpolated bad channels; `TopomapView` (`FieldRaster`, `TopomapZScaling`) and
  `ScalpTopography3DView` for scalp maps; and `ElectrodeGeometry+Forward`, the
  bridge from a montage to the forward model.

### Cleaning stage — Filtering — `EVA/Filtering`

Frequency-domain cleanup and re-referencing.

- `EEGSignalFilter` (`EEGSignalFilter.swift`) is the workhorse:
  `bandPass(...)`, `filterChannel(...)`, `adaptiveLineNoiseReduction(...)`, and
  `averageReferenced(...)`, parameterized by `FilterFamily` / `IIRDesign` /
  `FIRWindow` / `FilterSlope`. IIR design lives in `EllipticFilterDesign`
  (Orfanidis prototype → stable second-order sections).
- `Rereferencing` (`applyInPlace(...)` / `applied(...)`) handles reference
  schemes. `FilterViewModel` / `FilteringViews` are the UI.

### Cleaning stage — Gradient (MRI/FASTR) — `EVA/Gradient`

Removing the MRI gradient artifact from EEG-in-scanner recordings. The largest
cleaning subsystem.

- **Template correction.** `GradientAAS` (Average Artifact Subtraction):
  `correct(...)`, `buildPlans(...)`, `meanTemplate(...)` /
  `meanUpdating(...)`, with donor selection in `GradientDonorSelection` and
  `GradientEpochAligner` / `GradientEpochLayout` establishing the TR grid.
  `GradientTemplateCorrector` and `LocalTemplateArtifactCorrector` are the
  general template engines (the latter also cleans non-gradient repetitive
  artifacts).
- **Residual reduction.** `GradientOBS` (Optimal Basis Set — PCA of the residual:
  `computeBasis(...)`, `projection(...)`) and `GradientANC` (Adaptive Noise
  Cancellation: `apply(...)`, `cutoffHz(...)`).
- **Support.** `GradientSincResampler`, `GradientFilters`, `TRSpacing`,
  `MotionParameters` (`GradientAcceleration`) for motion regressors, and
  `GradientMetalBackend` / `LocalTemplateMetalBackend` for the GPU paths.
  `GradientViewModel` + `MRIGradientArtifactViews` / `MotionConfigView` drive it.

### Cleaning stage — Cardiac (BCG / ECG) — `EVA/Cardiac`

Detecting heartbeats to remove the ballistocardiogram.

- `RWaveDetector` is the core: `detect(...)` / `detectCandidates(...)` with
  selectable `ECGDetectionAlgorithm` (Pan–Tompkins, Hamilton, pulse, simple) via
  the per-algorithm `*ProcessedChannel(...)` methods; results are `RWaveCandidate`s.
- `ECGDetectionViewModel` runs it against a real ECG channel;
  `BCGDetectionViewModel` drives beat-locked BCG cleaning. Downstream, ICA
  consumes beat timing (see `BCGComponentLabeller`).

### Cleaning stage — ICA — `EVA/ICA`

Independent Component Analysis for artifact separation and labelling.

- `ICAArtifactDetector` runs the decomposition and cleanup: `fit(...)`,
  `cleanedSignal(...)`, `componentContributions(...)`, configured by
  `ICAConfiguration` / `ICAMethod`, producing a `SavedICAArtifactSet`.
- Labelling: `ICLabelClassifier` (`suggestions(...)`, `predict(...)` — a CoreML
  IC-Label model), plus `ICAComponentAutoLabeler` and the scanner-specific
  `BCGComponentLabeller`. `ICAComponentRemoval` (`apply` / `commit` /
  `stagedPayload`) turns selected components into a cleaned signal and a
  replayable payload (`ICAReplayPayload`). UI: `ICAViewModel`,
  `ICAExplorationViews`, `ICADebugReportViews`. Evaluation harnesses
  (`ICAComponentLabellerBenchmark`) score suggestions against simulator truth.

### Cleaning stage — Wavelet — `EVA/Wavelet`

Wavelet-domain denoising and artifact reduction (HAPPE-style).

- `ContinuousWaveletTransform` (`kernel(...)`, `transform(...)`) and
  `CWTRidgeDetector` do the transform + ridge tracking. Threshold denoising uses
  `EmpiricalBayesThreshold` (`threshold(...)`, `robustSigma(...)`,
  `universalThreshold(...)` — the empirical-Bayes shrinkage validated against R's
  EbayesThresh). `MatchedWaveletTemplate` and `WaveletArtifactAnalyzer` support
  matched-template artifact work. UI: `WaveletReductionViewModel` /
  `WaveletArtifactExplorerViewModel` and their views.

### Cleaning stage — Artifacts (template / source-informed) — `EVA/Artifacts`, `EVACore/Artifacts`

General artifact templates that don't fit the gradient/cardiac/ICA buckets.

- `ArtifactTemplateDetector` builds and matches spatial-temporal templates
  (`ArtifactTemplateConfiguration`, `SavedArtifactTemplate`,
  `ArtifactTemplateDetectionResult`). `ArtifactCleaner` /
  `ArtifactCleaningCore` apply cleaning (`DefinedArtifactType`,
  `ArtifactCleaningMethod`, `ArtifactOBSStrategy`). `ArtifactViewModel` /
  `ArtifactTemplateViewModel` + preview views drive it, with
  `ArtifactReplayPayload` for reproducibility.
- `EVACore/Artifacts/SourceInformed/SourceInformedOperator` is the UI-free
  source-informed separation operator.

### Quality — Health — `EVA/Health`

Scoring channel and time-segment quality.

- `ChannelHealthViewModel` and `SegmentHealthViewModel` (with
  `SegmentQualityLabel`) compute per-channel and per-segment goodness;
  `ChannelRelationshipAnalyzer` looks at inter-channel agreement.
  `SegmentGoodnessSettings` holds the thresholds. The `*TrainingExport` files
  emit labelled data for tuning classifiers; `*DetailViews` render the badges and
  tables.

### Epoching & PSA — `EVA/Epoching`

Cutting the cleaned continuous signal into epochs and building condition
averages (PSA, called post-stimulus averaging in the source). Epoch windows can
also include a pre-event baseline.

- `EpochingViewModel` is the hub (category grouping via `CategoryGroupMode` /
  `CategoryRegexMatchField`, display modes, topomap scaling). `PSAAveraging`
  (`commit(...)`) produces the averages; `PSABadChannelEscalation` decides when a
  channel is too bad to keep. `EyeArtifactThresholdDetector` +
  `EyeArtifactThresholdSheet` reject ocular epochs. `EpochSegment` itself is
  defined UI-free in `EVACore/Epoching/EpochModel.swift`.
- Views: `AveragesWorkspaceViews`, `MultiButterflyView`, `DifferenceWaveView`,
  `TopoFilmstripView`, `JointMarkerOverlay`, and the trial-review dashboards
  (`TrialDiagnosticsDashboard`, `TrialSelectionViews`). Note the **single-trial**
  analysis UI (`SingleTrialAnalysisViewModel` / `SingleTrialAnalyzer`) lives here
  but delegates its math to the `Trials` subsystem below.

### Trials — single-trial & cluster statistics — `EVA/Trials`

The statistical engines that run over epochs.

- **Cluster permutation.** `ClusterPermutationAnalyzer` (`analyze(...)`,
  `analyzeIndependent(...)` / `analyzePaired(...)`, `runPermutations(...)`) and the
  F-test variant `ClusterPermutationFAnalyzer`; cluster building in
  `ClusterFormation`; orchestration/preparation in `ClusterStatisticsRunner`;
  display in `ClusterStatisticsViews`.
- **Latency-variable analysis.** `RIDEAnalyzer` (`decompose(...)`,
  `estimateTemplate(...)`, `reconstruct(...)`) and `WoodyAlignmentAnalyzer`
  (`align(...)`, `bestLag(...)`) for trial-by-trial latency alignment;
  `NonlinearAligner` (functional PCA warping) and `CWTRidgePipeline` for
  ridge-based single-trial features. `SingleTrialAnalyzer` (in `Epoching`)
  aggregates these into review tables.

### Time-Frequency & Rhythmicity — `EVA/TimeFrequency`, `EVA/Rhythmicity`

- **Time-Frequency.** `ComplexMorlet` (`kernel(...)`, `convolveSame(...)`) is the
  complex-Morlet transform behind ERSP/ITPC; `TimeFrequencyMetalBackend` is the
  GPU path; `TimeFrequencyHeatmap` / `TimeFrequencyOverviewView` render it;
  `TimeFrequencyExport` writes NPY/CSV; `TimeFrequencyTrials` handles per-trial
  stacks. Entry view: `TimeFrequencyView`.
- **Rhythmicity.** LAVI/ABBA-style rhythmicity detection.
  `RhythmicityExplorerViewModel` orchestrates runs; `WTPLEngine`
  (`analyze(...)`, `matrix(...)`) computes the wavelet-based measure;
  `ComplexCoefficientProvider` / `AccelerateFFTComplexCoefficientProvider` supply
  kernels; `RhythmicityExport` writes a full provenance bundle. Views:
  `RhythmicityExplorerView`, `LAVISpectrumView`, `ABBABandTableView`.

### Analysis — spectral & connectivity — `EVA/Analysis`

- `EEGAnalysisEngine` (`analyze(...)`, `exportResult(...)`) computes band-power
  spectra and connectivity over selected segments (`SpectralChannelWork`,
  `ConnectivityPairWork`, `BandWindowSpectrum`); `EEGAnalysisViewModel` /
  `EEGAnalysisSheet` are the UI.

### Forward modeling, Simulation & Resolve — `EVACore/Core/Forward`, `EVACore/Simulation`, `EVAResolve`

The shared physics: given sources and a head model, predict scalp potentials —
and the inverse, fitting sources to data.

- **Forward models** (`EVACore/Core/Forward`). `ForwardTypes` defines the common
  vocabulary (`ForwardHeadModel`, `ForwardDipole`, `ForwardLeadField`).
  `SphericalForwardModel` (3/4-shell, `leadField(...)`),
  `EllipsoidalForwardModel` (affine ellipsoid), and `BEMForwardModel`
  (`leadField(...)`, `solveSurfacePotentials(...)`) are the three tiers, with
  geometry/quality in `BEMGeometry`.
- **Simulation** (`EVACore/Simulation`). `SimulationConfig` is the master config;
  `EEGGenerator` / `DipoleEEGGenerator` (`mixed(...)`, `dipoleSource(...)`)
  synthesize scalp EEG from dipoles through a `SimulationForwardDomain`, adding
  artifact models (`BCGArtifactModel`, `OcularArtifactModel`, `EMGArtifactModel`,
  `GradientArtifactModel`, `ChannelDefectModel`, `ImpedanceModel`) and
  neural non-stationarity (`NonstationaryEEGModel`, `ERPGenerator`,
  `GroupSimulation`). Every model emits a **truth** struct (e.g. `ERPTrialTruth`,
  `BCGGeneratorTruth`) so detectors can be scored. Source *fitting* is
  `SingleDipoleFit` (`fit(...)`, `fitMultiple(...)`, `fitSpatioTemporal` via
  `SharedGeometryResult` / `LeadFieldGrid`). `Montage` bridges a real montage
  into the simulator.
- **Resolve** (`EVAResolve/`). A separate app for head-model authoring:
  `HeadModelController` / `HeadModelDocument`, MRI slice viewing
  (`MRISliceView`), and coregistration (`CoregistrationSceneView`), importing BEM
  geometries via the `EVACore/IO/OpenMEEG` and `EVACore/Registration`
  (`SurfaceRegistration`, ICP) code.
- The in-app **Simulator Studio** and **Source Simulator** windows live in
  `EVA/App` (`SimulatorWindowView`, `SimulatorGenerateView`, `SimulatorScoreView`,
  `SimulatorSweepView`, `SimulatorGroupView`) driven by `EVA/Simulation`
  (`SimulatorController`, `SimulatorRunner`, `SimulatorScenarioLibrary`).

### Combine & Compare — `EVA/Combine`, `EVA/Compare`

- **Combine** — `RecordingCombiner` appends or grand-averages multiple files
  (`CombineMode`, `WeightingMode`, `BadChannelPolicy`, `GrandAverageOutput`); UI
  in `CombineRecordingsSheet`.
- **Compare** — `SignalComparison` (`ChannelDifference`, `Result`) diffs two
  recordings/windows; `WindowComparisonRegistry` tracks which windows are being
  compared; `CompareWindowsSheet` is the UI.

---

## Cross-cutting spines

These are not "stages" — they run underneath every stage.

### Pipeline: history, replay, batch & `eva.xml` provenance — `EVA/Pipeline`, `EVACore/Pipeline`

The reproducibility backbone. **Every cleaning action goes through here.**

- `RecordingHistoryModel` holds the branching history tree; `PipelineSnapshot`
  (`PipelineSnapshotting`) captures/restores full state; `ProcessingCore`
  (`applyAutoSteps(...)`) is the shared "apply a stage" path.
- `ReplayController` (`configure(...)`, `plannedActions(...)`, `gate(...)`,
  `resume(...)`) re-runs a recorded `EVAProcessingScript` against a new recording,
  pausing at interactive gates. `EVAProcessingScript` (in `EVACore`) is the
  on-disk `eva.xml` schema; `EVAProcessLog` / `ProcessingAuditLog` write the human
  log; `PayloadConsistency` validates replay payloads.
- Batch: `BatchController` / `HeadlessBatchProcessor` / `ProcessingQueue` /
  `LatestOnlyRunner` run scripts across many files without the UI.
  `CleaningVarianceLedger` accumulates the variance-removed accounting.
- The REWIND-style history tree, the `eva.xml` provenance format, and the
  batch/replay flow all originate here — a change to any one usually touches the
  other two.

### Channel geometry & the forward model

`EVACore/Channels` + `EVACore/Core/Forward` are shared by four otherwise
unrelated features: bad-channel **interpolation** (spherical spline),
**topomaps** (`TopomapView` field rasters), the **simulator** (lead fields), and
**source fitting** (`SingleDipoleFit`). A change to `SensorLayout` or
`ForwardLeadField` ripples into all four — check them together.

### MFF I/O round-trip

`EVACore/IO/MFFReader` + `MFFWriter` are the one place the `.mff` on-disk format
is understood. The QuickLook/Thumbnail targets use `EVAPreviewKit/MFF` and read
the *same* format through the *same* core, so a reader change that isn't in
`EVACore` will desync the Finder previews from the app.

### Figure export

`EVA/IO/FigureExport` + `FigureExportBasket` are the shared rendering path for
publication figures. Individual views (butterfly, topomap, TF heatmap, cluster
map) expose a `FigureCard`; the basket collects them across the session for a
single multi-page export.

### Simulation truth as a test oracle

The simulator's per-model **truth structs** are not just for display — they are
the ground truth that `ICAComponentLabellerBenchmark`, the BCG/ECG detector
tests, and the source-fit tests score against. When you add a generator, add its
truth struct, or nothing downstream can be evaluated.

---

## Continue through the developer guide

Use the [feature-to-code-and-tests map](features.md) for a user-visible task,
[subsystem pages](subsystems/README.md) for responsibilities, and
[the checked source inventory](source-inventory.md) for complete file coverage.
Read [data and lifecycle](data-and-lifecycle.md) before changing shared state.

The [extension recipes](recipes/README.md) walk through concrete changes; the
[onboarding milestones](onboarding-milestones.md) and
[validation record](guide-validation.md) distinguish delivered material from
manual acceptance still outstanding. The parent plan remains
[ROADMAP §13](../../ROADMAP.md#13-developer-documentation).
