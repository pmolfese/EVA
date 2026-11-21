# Recipe 3: add a report metric with export support

**Goal:** report the fraction of recording duration retained by the analysis
segment-selection rules. Read [recipe setup](README.md), then apply
[03-analysis-metric.patch](../examples/03-analysis-metric.patch). The metric is a
dimensionless quality/coverage measure, not a new EEG correction algorithm.

## 1. Define meaning and invalid inputs

The value is `includedDurationSeconds / signal.duration`. Five retained seconds
out of ten gives `0.5`; the UI displays `50%`. It uses the included-duration
summary already produced by the analysis engine. It is not the fraction of
channels retained, a probability of clean EEG, or an amplitude measurement.

If total duration is zero/nonfinite, included duration is negative/nonfinite,
or included duration exceeds the total, return `nil`. Overlapping or otherwise
inconsistent totals must not be silently clamped to a convincing 100% result.
Zero included duration with a valid positive total is a real measured zero.

## 2. Follow the result through every representation

| File | Edit |
| --- | --- |
| [EEGAnalysisModels](../../../EVA/Analysis/EEGAnalysisModels.swift) | Add optional `retainedDurationFraction` to `EEGAnalysisResult`; a missing field in legacy JSON stays unavailable. |
| [EEGAnalysisEngine](../../../EVA/Analysis/EEGAnalysisEngine.swift) | Add the pure ratio helper; compute it from the actual summary; carry it through `exportResult`; add the CSV summary row. |
| [EEGAnalysisSheet](../../../EVA/Analysis/EEGAnalysisSheet.swift) | Add a percentage summary tile when the field exists. |
| [EEGAnalysisEngineTests](../../../EVATests/Analysis/EEGAnalysisEngineTests.swift) | Extend the real analysis test to check report/export/JSON/CSV and missing-key decoding. |
| New `GuideRetentionMetricTests` | Test exact simple ratios, zero, invalid totals, excess duration and nonfinite input. |

The pure helper is small enough to inspect directly:

```swift
    static func retainedDurationFraction(included: Double, total: Double) -> Double? {
        guard included.isFinite, total.isFinite, total > 0,
              included >= 0, included <= total else { return nil }
        return included / total
    }
```

It has no UI/model state. Tests use exact binary-representable examples such as
0.5; that does not establish a blanket exact-equality policy for numerical work.

The result is optional because older reports do not contain it. Synthesized
Codable decoding accepts a missing optional field. The patch does not make it a
required field with a default initializer and assume that old JSON will decode.

## 3. Do not lose the metric during export

`EEGAnalysisEngine.exportResult` constructs a new result with optional detail
arrays removed according to export options. Merely adding the new field to the
engine's original result would leave the exported copy's default `nil` in place.
The patch explicitly copies `result.retainedDurationFraction` into that result.
The extended test covers this boundary.

CSV gets the stable key `retained_duration_fraction` and a fraction, not a
percentage string. JSON keeps the optional numeric field. The UI alone multiplies
by 100 and formats the percentage; business meaning must not depend on a label
or locale-specific display string. Unavailable results do not acquire a false
zero CSV row or UI tile.

`EEGAnalysisViewModel` already snapshots the analysis request, publishes the
result, and delegates JSON/CSV export. This metric uses that result path and does
not require another task, signal mutation, history node, or processing replay
parameter. It is recomputed with the report rather than stored as a correction.

## 4. Run and inspect

```sh
xcodebuild test -project EVA.xcodeproj -scheme EVA -destination 'platform=macOS' \
  -only-testing:EVATests/GuideRetentionMetricTests \
  -only-testing:EVATests/EEGAnalysisEngineTests
```

The helper tests check edge cases. The engine test runs the existing synthetic
analysis, verifies a fraction in range, checks the CSV row, compares the exported
copy, encodes/decodes current JSON, removes the new key from that JSON, and
confirms the legacy result decodes with `nil`.

In the normal app, run EEG Analysis on a synthetic recording, inspect the
Retained tile, and export both JSON and CSV with detailed arrays disabled.
Compare the percentage with the numeric exported fraction and the duration
summary. Change segment inclusion rules and rerun; a previously published report
should not silently become a mixture of old results and new settings. Inspect
the summary layout at the sheet's supported sizes.

Common mistakes are dividing by segment count instead of duration, writing a
percentage into a field documented as a fraction, dropping the field from the
export copy, and decoding an absent field as measured zero. New semantic schema
changes need the review in [compatibility](../compatibility.md); an additive
optional report field alone does not redefine older metrics.

**Exercise:** add a CSV test that locates the metric by key and parses its numeric
value, then compares it to the result object. Avoid asserting a whole CSV string
whose unrelated row order/formatting is not the behavior under test.
