# Recipe 2: add a persisted processing parameter

**Goal:** add a teaching option that inverts EEG sample signs after filtering,
leaves PNS polarity unchanged, and survives parameter/XML restoration. This is
a small way to learn the full processing path; it is not a recommendation to
invert EEG in a scientific workflow. Read [data/lifecycle](../data-and-lifecycle.md)
and [compatibility](../compatibility.md). Apply
[02-persisted-parameter.patch](../examples/02-persisted-parameter.patch) only in
your practice checkout.

## 1. State the contract

`invertEEGPolarity` is a Boolean, defaults to `false`, and changes each processed
EEG sample `x` to `-x`. It preserves channel order, sample count, event timing,
and reference convention. Acquisition gaps remain gaps. PNS does not receive
the inversion, even if the existing filter operation processes PNS. A script
without the new key means **no inversion**, including when restored into a
model that previously had the option enabled.

| Boundary | Exact source / change |
| --- | --- |
| Control | [FilteringViews](../../../EVA/Filtering/FilteringViews.swift): bind a toggle to the filter model. |
| Settings/defaults | [FilterViewModel](../../../EVA/Filtering/FilterViewModel.swift): property, reset, summary, preset recognition and no-operation validation. |
| Serialization/restoration | Same model's `parameters` and `apply(parameters:)`: explicit string Boolean and absent-key policy. |
| Worker request | `apply`: capture the Boolean beside other local settings before worker execution. |
| Computation | `filteredChannels`: defaulted argument, recursive recorded-run forwarding, final EEG sign inversion. PNS call uses the default `false`. |
| Publication/invalidation | Existing request guard and `FilteringViews.postFilterInvalidation`; no duplicate publication path. |
| History/export | [HistoryStepSummary](../../../EVA/Pipeline/HistoryStepSummary.swift) adds a readable label; [MFFExportFlowViews](../../../EVA/IO/MFFExportFlowViews.swift) already builds `.filter` steps from `filter.parameters`. |
| Restore/replay/batch | [WaveformHistoryRail](../../../EVA/Waveform/WaveformHistoryRail.swift), [ReplaySettingsRestore](../../../EVA/Pipeline/ReplaySettingsRestore.swift), and [ProcessingCore](../../../EVA/Pipeline/ProcessingCore.swift) already route filter dictionaries through the same model. |

## 2. Read the patch from input to output

The parameter bridge explicitly records and restores the choice:

```swift
        params["invertEEGPolarity"] = "\(invertEEGPolarity)"
```

```swift
        invertEEGPolarity = p["invertEEGPolarity"] == "true"
```

The second line deliberately differs from “only assign if a key exists.” An
older script must not inherit a previously enabled new operation. This exercise
uses the existing Boolean-string convention; broader malformed-value handling
and forward compatibility require the policy discussed below.

Inside `apply`, `let invertEEGPolarity = self.invertEEGPolarity` captures this
request's choice. Passing that local into the EEG worker prevents a later UI
edit from changing the running calculation. The PNS worker does not receive it.
Inside `filteredChannels`, the recorded-range recursion also forwards the value;
forgetting that call would make discontinuous recordings behave differently.

After filtering/reference work on each recorded run:

```swift
        if invertEEGPolarity {
            bandPassed = bandPassed.map { channel in channel.map { -$0 } }
        }
```

The nested `map` preserves channel/sample shape. The existing publication code
uses `replacingSamples`, yielding a fresh data revision. The patch updates the
empty-operation guard so inversion alone is a valid request, the reset path,
and the summary/preset display so the UI describes the actual operation.

## 3. Run the focused tests

The patch adds `EVATests/Filtering/GuideFilterParameterTests.swift` with the NIH
header and three tests:

- Save parameters in real `eva.xml`, read them back, restore into a fresh model,
  compare dictionaries, then verify absent-key and reset behavior.
- Run live and restored filter settings on small known arrays. Check expected
  negative EEG samples, unchanged PNS samples, a new revision, unchanged input,
  and the commit callback.
- Process two recorded ranges separated by a gap. Confirm the option reaches
  both recursive calls and the gap is not transformed into measured data.

```sh
xcodebuild test -project EVA.xcodeproj -scheme EVA -destination 'platform=macOS' \
  -only-testing:EVATests/GuideFilterParameterTests \
  -only-testing:EVATests/FilterReplayTests
```

These tests establish serialization and shared transform behavior; they do not
instantiate a full history window or exercise every batch policy. Run relevant
`PipelineSnapshotTests`, `ProcessingCoreTests`, `PairedValidationTests`, and
export/replay tests with their fixture/backend requirements as part of integration.

## 4. Check the whole user workflow

With the normal app build, open a synthetic recording. Apply the option, verify
trace polarity, inspect its history summary, undo/redo, export to a **new** MFF
destination, and reopen. Confirm the samples and `eva.xml` agree. Replay the saved
filter step on the original input with the option initially disabled, then try
batch processing the same input. Compare output samples, not merely settings.
Inspect cancellation/close while work runs and ensure a stale request cannot
publish or create a misleading history step. Changing controls during a run
should also be tested so recorded parameters describe the committed request.

No new `Operation` case or `PipelineSnapshot` parameter field is added: this is
an option within an existing filter operation, and snapshots already retain its
output while the history path carries parameters. No learned payload is needed
for multiplying samples by -1. Global startup preferences are unchanged; adding
a persisted app default would be a separate preferences/defaults requirement.

## 5. Compatibility and review

The tests prove new code reads an old missing key safely. An **older app can
ignore the new key and replay different samples**. This teaching patch does not
solve cross-version capability negotiation. Before shipping such a change,
establish required-reader behavior, unsupported-value rejection, and a migration/
version policy in [compatibility](../compatibility.md). An app-version stamp alone
does not force older code to refuse the script.

Review the four changed files and the test output. Common omissions are the
worker capture, recursive calls, reused-model missing-key behavior, presets,
history labels, and a round-trip test that uses only the default value.

**Exercise:** add a test comparing live and restored behavior with a nonzero
frequency cutoff as well as inversion. Explain which assertions can be exact
because both paths share arithmetic, and which require a numerical tolerance
against an independently computed reference.
