# Time-Frequency — `EVA/TimeFrequency`

**Purpose.** Time-frequency decomposition of epochs: event-related spectral
perturbation (ERSP/power) and inter-trial phase coherence (ITPC), via complex
Morlet wavelets or DPSS multitaper, with heatmap display and NPY/CSV export.

**Start here.** `TimeFrequencyEngine` is the orchestration entry; `ComplexMorlet`
and `Multitaper`/`DPSS` are the two transforms; `TimeFrequencyResult` /
`TimeFrequencyModels` define the outputs; `TimeFrequencyView` /
`TimeFrequencyOverviewView` render them.

## Files

| File | Synopsis |
|---|---|
| `TimeFrequencyEngine.swift` | Orchestrates a TF run: builds the frequency plan, decomposes per trial, baselines, and averages to ERSP/ITPC. |
| `ComplexMorlet.swift` | Complex-Morlet kernel + convolution (`kernel`, `convolveSame`) — MNE-cross-checked. |
| `Multitaper.swift` | Multitaper spectral estimate. |
| `DPSS.swift` | Slepian (DPSS) tapers (scipy-exact) used by the multitaper path. |
| `TimeFrequencyModels.swift` | Method/power/baseline enums, `TFFrequencyPlan`, `TFBaselineSpec`, `TimeFrequencyResult`. |
| `TimeFrequencyTrials.swift` | Per-trial TF stacking (`Stack`) for single-trial views. |
| `TimeFrequencyMetalBackend.swift` | GPU (Metal) TF decomposition. |
| `TimeFrequencyHeatmap.swift` | Renders a TF map to an image (`TFRender`, `TFColorMap`, colour bar). |
| `TimeFrequencyOverviewView.swift` | Multi-channel TF overview grid (`TFChannelMatrix`, display cache). |
| `TimeFrequencyView.swift` | The main TF tab view (`Job`). |
| `TimeFrequencyExport.swift` | Writes NPY (byte-identical to numpy) + tidy CSV for a TF run. |

## How to extend this

A new **transform** is a case in `TFMethod` implemented alongside
`ComplexMorlet`/`Multitaper`, plugged into `TimeFrequencyEngine`. A new **baseline
or power mode** is a case in `TFBaselineMethod`/`TFPowerMode`. Keep the CPU
transform authoritative and mirror it in `TimeFrequencyMetalBackend`. Validate any
new transform against MNE (the existing bar is <1e-6 agreement) and keep the
export byte-exact against numpy.
