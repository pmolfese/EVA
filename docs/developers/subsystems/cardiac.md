# Cardiac — `EVA/Cardiac`

**Purpose.** Detect heartbeats and remove the ballistocardiogram (BCG) artifact
that pulsing blood induces in EEG recorded inside an MRI scanner. Two problems:
find the beats (from ECG or from the EEG itself), then subtract the beat-locked
artifact.

**Start here.** `RWaveDetector.detect(...)` is the beat detector (Pan–Tompkins,
Hamilton, pulse, simple). `BCGDetector` / `BCGSurrogateCorrection` and
`CWLCorrector` are the three correction strategies. View models
(`ECGDetectionViewModel`, `BCGDetectionViewModel`) wire them to the UI.

## Files

| File | Synopsis |
|---|---|
| `RWaveDetector.swift` | Core R-wave detector: `detect` / `detectCandidates` with selectable `ECGDetectionAlgorithm` and per-algorithm `*ProcessedChannel` preprocessing; emits `RWaveCandidate`s. |
| `BCGDetector.swift` | Beat-locked BCG artifact detection over the EEG. |
| `BCGSurrogateCorrection.swift` | Surrogate/head-model-based BCG removal (`BCGSurrogateSettings`, `BCGSurrogateReport`, `Output`). |
| `BCGSurrogateTopographies.swift` | Builds the spatial BCG artifact patterns (`BCGArtifactComponents`) the surrogate corrector subtracts. |
| `BCGGeneratorModel.swift` *(in EVACore/Simulation)* | The *forward* BCG model the surrogate corrector is validated against — see [evacore-simulation.md](evacore-simulation.md). |
| `CWLCorrector.swift` | Carbon-wire-loop (CWL) reference regression: downsample-filter-regress pipeline (`Algorithm`, `RegressionWindow`, `ProgressUpdate`). |
| `BCGDetectionPreviewEstimator.swift` | Cheap preview of what BCG detection would find, for the live sheet. |
| `ECGDetectionViewModel.swift` | Drives R-wave detection against a real ECG channel. |
| `BCGDetectionViewModel.swift` | Drives BCG detection/correction over the EEG (`BCGAlgorithmResult`). |
| `ECGDetectionViews.swift` / `BCGDetectionViews.swift` | The SwiftUI sheets and help buttons (extensions on `WaveformView`). |

## How to extend this

A new **beat detector** is a case in `ECGDetectionAlgorithm` plus a
`*ProcessedChannel` preprocessing path in `RWaveDetector`. A new **BCG correction
method** is a new corrector type (mirror `BCGSurrogateCorrection` /
`CWLCorrector`) surfaced through `BCGDetectionViewModel`. If you touch the
surrogate head model, keep it consistent with the generator in
`EVACore/Simulation` so simulator truth still validates the corrector. ICA also
consumes beat timing for cardiac components — see
[ica.md](ica.md) (`BCGComponentLabeller`).
