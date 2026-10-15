# Wavelet — `EVA/Wavelet`

**Purpose.** Wavelet-domain denoising and artifact reduction (HAPPE-style), an
artifact *explorer* that scores candidate artifacts, and the scalogram view. This
is where transient, non-stationary artifacts are shrunk without a template.

**Start here.** `WaveletReducer` is the reduction engine (SWT/DWT +
thresholding); `EmpiricalBayesThreshold.threshold(...)` is the shrinkage rule
(empirical-Bayes, validated against R's EbayesThresh). `WaveletDenoiser` is the
simpler denoiser. `WaveletArtifactAnalyzer` powers the explorer.

## Files

| File | Synopsis |
|---|---|
| `WaveletReducer.swift` | The reduction engine: filter banks, (stationary) wavelet transform, thresholded reconstruction; config + per-channel metrics + result. |
| `WaveletDenoiser.swift` | Simpler threshold denoiser (`ThresholdModel`, `Configuration`). |
| `EmpiricalBayesThreshold.swift` | Empirical-Bayes shrinkage (`threshold`, `robustSigma`, `universalThreshold`) — the statistically-tuned threshold behind reduction. |
| `ContinuousWaveletTransform.swift` | CWT (`kernel`, `transform`) with selectable `CWTWavelet`. |
| `CWTRidgeDetector.swift` | Tracks ridges/peaks in the CWT plane (`Ridge`, `RidgePoint`, `Peak`) for transient detection. |
| `MatchedWaveletTemplate.swift` | Matched-template fit in the wavelet domain (`Fit`). |
| `WaveletScalogram.swift` | Computes a scalogram (`WaveletScalogramResult`) for display. |
| `WaveletArtifactAnalyzer.swift` | The big artifact-explorer engine: scans channels, scores candidate artifacts, builds exemplars and feature vectors, and channel-goodness metrics. |
| `WaveletMetalBackend.swift` | GPU (Metal) SWT/DWT/IDWT + shrink kernels for the reducer and analyzer. |
| `WaveletModels.swift` | Cleaning config/result/metrics types (`WaveletCleaningConfiguration`, previews). |
| `WaveletReductionViewModel.swift` / `WaveletReductionSheetViews.swift` | Reduction sheet state and UI. |
| `WaveletArtifactExplorerViewModel.swift` / `WaveletArtifactExplorerViews.swift` | Explorer state and UI (candidate table, summary chips). |

## How to extend this

A new **wavelet family** is a case in `WaveletFilters`/`WaveletReductionFamily`
with its filter bank. A new **threshold rule** is a case in
`WaveletCleaningThresholdRule` plus a routine (mirror `EmpiricalBayesThreshold`).
Keep the CPU path authoritative and mirror it in `WaveletMetalBackend` — the two
must match numerically (there is an established parity discipline here). The
reducer historically over-smoothed when a threshold model was mismatched, so
validate any new shrinkage against a reference implementation before shipping.
