# Epoching — `EVA/Epoching`

**Purpose.** Turn the cleaned *continuous* recording into *epochs* and condition
**averages** (PSA = Peristimulus Averaging), reject bad epochs (especially
ocular), and provide the trial-review and single-trial analysis UI. This is the
bridge from "a cleaned recording" to "an ERP you can analyze."

**Start here.** `EpochingViewModel` is the hub. `PSAAveraging.commit(...)` builds
the averages from accepted epochs. `EpochSegment` (defined in `EVACore/Epoching`)
is the epoch unit. Bad-epoch rejection: `EyeArtifactThresholdDetector`,
`EpochBadChannelDetector`, `PSABadChannelEscalation`. The single-trial statistical
math is delegated to [trials.md](trials.md).

## Files

**Averaging & epoch handling**

| File | Synopsis |
|---|---|
| `EpochingViewModel.swift` | The workspace hub: category grouping (`CategoryGroupMode`, regex rules), display modes, topomap scaling, PSA apply flow. |
| `PSAAveraging.swift` | Builds condition averages from accepted epochs (`commit`). |
| `PSABadChannelEscalation.swift` | Decides when a channel is too bad within epochs to keep (`Outcome`). |
| `PSAGlobalBadChannelInterpolator.swift` | Interpolates channels marked globally bad before averaging. |
| `EpochBadChannelDetector.swift` | Flags per-epoch bad channels (with a cached spline-weight helper). |
| `EpochSNR.swift` | Per-average SNR metrics (`SNRMetrics`). |
| `RegexPatternLibrary.swift` | Preset regexes + suggestions for turning event codes into categories. |

**Ocular / eye-artifact rejection**

| File | Synopsis |
|---|---|
| `EyeArtifactThresholdDetector.swift` | Detects blink/saccade epochs by ocular topology (`EyeArtifactKind`, `OcularNetModel`). |
| `EyeArtifactThresholdConfiguration.swift` | Persisted thresholds/polarity/topology mode for the above. |
| `EyeArtifactThresholdSheet.swift` | Its configuration sheet. |

**Single-trial analysis (UI; math is in `Trials`)**

| File | Synopsis |
|---|---|
| `SingleTrialAnalyzer.swift` | Aggregates per-trial values into split-group stats (`TrialInput`, `Result`). |
| `SingleTrialAnalysisViewModel.swift` | State for the single-trial sheet (Woody/RIDE/CWT modes). |
| `SingleTrialAnalysisViews.swift` | The large single-trial UI: run jobs (Woody/RIDE/CWT), previews, per-channel inspector. |
| `TrialAlignmentMetrics.swift` | Alignment scores/affine-fit metrics over an analysis window. |
| `TrialDriftStatistics.swift` | Trial-order drift/rank-correlation/convergence stats. |
| `TrialSimilarityAnalyzer.swift` | Classifies trials by similarity to a reference (`Classification`, `CategoryResult`). |
| `TrialSelectionAnalyzer.swift` / `TrialExclusionResolver.swift` | Turn selection criteria into an exclusion set and resolve reviewed exclusions. |

**Review & display**

| File | Synopsis |
|---|---|
| `TrialDiagnosticsDashboard.swift` / `TrialDiagnosticsViews.swift` | The trial-diagnostics dashboard: score table, scatter/heatmap/convergence charts. |
| `TrialSelectionViews.swift` | Criteria controls, exclusion list, null-distribution and average-comparison views. |
| `AveragesWorkspaceViews.swift` | The averages workspace: butterfly pane, latency scrubber, topography. |
| `MultiButterflyView.swift` / `DifferenceWaveView.swift` | Multi-condition butterfly grid and difference-wave view. |
| `TopoFilmstripView.swift` | Topomap "filmstrip" across time. |
| `JointMarkerOverlay.swift` | Draggable joint time/latency markers over the plots. |

## How to extend this

A new **rejection criterion** is a detector (mirror `EpochBadChannelDetector` /
`EyeArtifactThresholdDetector`) whose outcome feeds `PSAAveraging`. A new
**single-trial measure** usually means a new analyzer in `Trials/`, a run job in
`SingleTrialAnalysisViews`, and a column in the diagnostics dashboard. Keep the
averaging math in `PSAAveraging`/`SingleTrialAnalyzer` and the statistics in
`Trials/`; the files here should stay UI + orchestration. PSA parameters are part
of provenance, so thresholds flow into the processing script
([pipeline.md](pipeline.md)).
