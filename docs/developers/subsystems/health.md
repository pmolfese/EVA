# Health — `EVA/Health`

**Purpose.** Score data *quality* so bad channels and bad time-segments can be
flagged, interpolated, or excluded. Two axes: per-**channel** health (is this
electrode good for the whole recording?) and per-**segment** health (is this
stretch of time usable?).

**Start here.** `ChannelHealthAnalyzer` and `SegmentHealthAnalyzer` are the
engines (features → metrics → grade); their view models
(`ChannelHealthViewModel`, `SegmentHealthViewModel`) run them and hold results;
`ChannelGoodnessSettings`/`SegmentGoodnessSettings` (in
[channels.md](channels.md) / here) hold the thresholds.

## Files

| File | Synopsis |
|---|---|
| `ChannelHealthAnalyzer.swift` | Per-channel quality engine: features (`ChannelHealthFeatures`), spectral/RANSAC/impedance checks, baselines → `ChannelHealthGrade` + `ChannelHealthResult`. |
| `SegmentHealthAnalyzer.swift` | Per-segment quality engine: segment definitions, features/baselines, artifact-interval assessment → `SegmentHealthResult`. |
| `HealthScoring.swift` | Shared scoring helper turning metrics into grades. |
| `ChannelRelationshipAnalyzer.swift` | Inter-channel relationships (`ChannelRelationshipKind`, bridging/reference integrity) — finds shorted/bridged/duplicated channels and reference problems. |
| `SegmentGoodnessSettings.swift` | Persisted segment thresholds + their settings view and metric help. |
| `ChannelHealthViewModel.swift` / `SegmentHealthViewModel.swift` | Run the analyzers and expose results (`SegmentQualityLabel`). |
| `ChannelHealthDetailViews.swift` / `SegmentHealthDetailViews.swift` / `HealthDetailViews.swift` | Badges, tables, and popovers rendering the scores. |
| `ChannelHealthTrainingExport.swift` / `SegmentHealthTrainingExport.swift` | Export labelled datasets (`SavedChannelHealthDataset` / `SavedSegmentHealthDataset`) for tuning the classifiers offline. |

## How to extend this

A new **metric** is a field in the relevant `*Features`/`*Metric` type computed
in the analyzer, with a threshold in the goodness settings and a row in the
detail view. If it should feed classifier tuning, add it to the `*TrainingExport`
schema too. Keep the analyzers UI-free and deterministic — they run over many
channels/segments concurrently (note the `ConcurrentProgressCounter` /
`*UnsafeSendableBuffer` patterns) so avoid shared mutable state. Health feeds
interpolation and PSA bad-channel escalation, so a grading change affects
[epoching.md](epoching.md).
