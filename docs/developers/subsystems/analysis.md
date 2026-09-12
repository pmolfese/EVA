# Analysis — `EVA/Analysis`

**Purpose.** Resting-style quantitative EEG: band-power spectra per channel and
functional **connectivity** between channels, computed over selected time
segments.

**Start here.** `EEGAnalysisEngine.analyze(...)` is the compute entry;
`EEGAnalysisModels` defines every input/result type; `EEGAnalysisViewModel` +
`EEGAnalysisSheet` are the UI.

## Files

| File | Synopsis |
|---|---|
| `EEGAnalysisEngine.swift` | Computes spectra + connectivity: per-channel spectral work, node spectra, connectivity pairs, band-window spectra; `analyze`, `exportResult`, CSV rows. |
| `EEGAnalysisModels.swift` | The data vocabulary: `EEGFrequencyBand`, `EEGConnectivityMetric`, configuration, per-channel/per-pair results, and the aggregate `EEGAnalysisResult`. |
| `EEGAnalysisViewModel.swift` | Runs the engine over chosen segments and holds results. |
| `EEGAnalysisSheet.swift` | The analysis sheet UI (`EEGAnalysisTab`). |

## How to extend this

A new **band** or **connectivity metric** is a case in `EEGFrequencyBand` /
`EEGConnectivityMetric` computed in `EEGAnalysisEngine`, surfaced through the
result types in `EEGAnalysisModels` and a tab/row in the sheet. Keep the compute
in the engine and the segment selection consistent with how Health defines usable
segments ([health.md](health.md)). Export goes through the engine's CSV path so
new metrics appear in exports automatically.
