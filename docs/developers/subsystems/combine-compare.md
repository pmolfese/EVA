# Combine & Compare — `EVA/Combine`, `EVA/Compare`

Two small, related groups: **Combine** merges several recordings into one
(append or grand-average); **Compare** diffs two open windows.

## Combine — `EVA/Combine`

**Purpose.** Append multiple recordings end-to-end, or grand-average several files
/ subjects, handling channel-layout mismatches and bad-channel policy.

**Start here.** `RecordingCombiner` is the engine; `MultiRecordingModels` holds
the modes and compatibility types; `CombineRecordingsSheet` is the UI.

| File | Synopsis |
|---|---|
| `RecordingCombiner.swift` | The engine: `CombineInput` → `Result`/`GrandAverageOutput`/`FileAverage`; handles interpolation, bad-channel restoration, noise sidecars, errors. |
| `MultiRecordingModels.swift` | `CombineMode`, `WeightingMode`, `BadChannelPolicy`, channel-layout signatures/mapping, `CombineProvenance`, `Contributor`. |
| `CombineRecordingsSheet.swift` | The combine UI. |

## Compare — `EVA/Compare`

**Purpose.** Compare two recording windows channel-by-channel (e.g. before/after
a cleaning step in different windows).

**Start here.** `SignalComparison` computes the diff; `WindowComparisonRegistry`
tracks which windows are paired; `CompareWindowsSheet` renders it.

| File | Synopsis |
|---|---|
| `SignalComparison.swift` | Per-channel difference between two signals (`ChannelDifference`, `Result`, `Pair`, `Failure`). |
| `WindowComparisonRegistry.swift` | Registry of comparable windows and their relation (`ComparableWindow`, `WindowRelation`). |
| `CompareWindowsSheet.swift` | The comparison UI (`PlotTraces`). |

## How to extend this

A new **combine mode** is a case in `CombineMode`/`WeightingMode` implemented in
`RecordingCombiner`, with its provenance recorded in `CombineProvenance` (combine
is a provenance-bearing operation — see [pipeline.md](pipeline.md)). Channel-layout
mismatches are resolved by the mapping types in `MultiRecordingModels`; extend
those rather than special-casing in the engine. For Compare, a new **diff metric**
extends `SignalComparison.Result`.
