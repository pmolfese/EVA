# Rhythmicity — `EVA/Rhythmicity`

**Purpose.** Detect *rhythmicity* — sustained oscillatory structure — as opposed
to transient power. Three related methods: **LAVI** (lagged auto/coherence-based
rhythmicity), **ABBA** (band-wise rhythmicity direction), and **WTPL** (wavelet
phase-locking), with IAAFT surrogate testing for significance.

**Start here.** `RhythmicityExplorerViewModel` orchestrates runs;
`LAVIEngine.analyze(...)`, `ABBAEngine`, and `WTPLEngine.analyze(...)` are the
three engines; `RhythmicityModels`/`WTPLModels` hold config and results;
significance comes from `IAAFTSurrogateGenerator` + `LAVISignificanceProvider`.

## Files

**Engines**

| File | Synopsis |
|---|---|
| `LAVIEngine.swift` | The LAVI rhythmicity computation (per-frequency outcome/failure stores, compensated reduction). |
| `ABBAEngine.swift` | ABBA band-wise rhythmicity detection. |
| `WTPLEngine.swift` | Wavelet phase-locking measure (`analyze`, `matrix`, per-trial rows). |
| `AperiodicSpectrumEstimator.swift` | Welch spectrum + aperiodic (1/f) fit used to separate rhythmic from broadband. |

**Kernels & surrogates**

| File | Synopsis |
|---|---|
| `ComplexCoefficientProvider.swift` | Complex Morlet coefficient tiles (`LAVI2026Morlet`) — the direct provider. |
| `AccelerateFFTComplexCoefficientProvider.swift` | FFT-based (Accelerate) coefficient provider + kernel-spectrum cache for speed. |
| `IAAFTSurrogateGenerator.swift` | Iterative amplitude-adjusted FT surrogates (seeded RNG) for significance testing. |
| `LAVISignificanceProvider.swift` | Resolves LAVI significance from surrogates (`LAVISignificanceResolution`). |

**Models, results, export**

| File | Synopsis |
|---|---|
| `RhythmicityModels.swift` | The full config/result vocabulary: `RhythmicityConfiguration`, LAVI/ABBA results, precision/backend/edge policies, progress, errors. |
| `WTPLModels.swift` | WTPL config/result types (`WTPLResult`, `FrequencyTimeMaps`, per-condition results). |
| `DetectedRhythmicityBandSet.swift` | Detected rhythmic bands and their resolution against a TF band plan. |
| `RhythmicityDataSelection.swift` | Which signal/channels/segments feed a run (`RhythmicitySignalSource`, scope, validity). |
| `RhythmicityPreset.swift` | Built-in parameter presets. |
| `RhythmicityExport.swift` / `WTPLExport.swift` | Provenance bundles (manifest + Morlet/LAVI/ABBA/significance sections). |

**UI**

| File | Synopsis |
|---|---|
| `RhythmicityExplorerViewModel.swift` | Orchestrates LAVI/ABBA/WTPL runs, snapshots, run signatures. |
| `RhythmicityExplorerView.swift` | The explorer window. |
| `LAVISpectrumView.swift` / `ABBABandTableView.swift` / `WTPLView.swift` | LAVI spectrum, ABBA band table + multi-channel matrix, WTPL view. |
| `RhythmicityHelp.swift` | In-app help. |

## How to extend this

A new **rhythmicity method** is a new engine (mirror `LAVIEngine`/`WTPLEngine`)
plus result types in `RhythmicityModels`/`WTPLModels`, a runner in
`RhythmicityExplorerViewModel`, and an export section. Significance goes through
`IAAFTSurrogateGenerator` — reuse the seeded RNG so runs stay reproducible. The
coefficient providers are hot loops with a direct and an FFT path that must agree;
validate new kernels against the Python oracle in
`Tools/RhythmicityReference/`.
