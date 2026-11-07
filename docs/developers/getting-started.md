# Reading EVA for the first time

EVA works with multichannel recordings: each channel is a sequence of samples over time. Start with the data and one operation before exploring a whole screen. This guide assumes undergraduate CS coursework, but no SwiftUI or EEG background.

For a hands-on first day, complete [setup](setup.md) and the
[first-change tutorial](first-change.md) first. This chapter then connects that
small testable helper to the larger application.

## A reading path

1. Read the [glossary](glossary.md) and the [Swift guide](swift-in-eva.md) as needed.
2. Open `EVA/Channels/ChannelSet.swift`: a small value type with zero-based channel indices. Follow it with `EVA/Core/SignalSelection.swift` and `EVATests/Core/SignalSelectionTests.swift`. Predict the output of each small test before running it.
3. Read `MFFSignalData` in `EVACore/IO/MFFReader.swift`. Its outer array indexes channels; the inner array indexes samples. A copy retains its sample revision; replacing samples gives the new data a different revision.
4. Read `EVA/App/RecordingStore.swift` for the per-window state, then `EVA/Pipeline/LatestOnlyRunner.swift` for the rule governing stale asynchronous results.
5. Trace the filtering example below, then use the [architecture map](architecture.md) and [subsystem index](subsystems/README.md) to find the next feature.

The large waveform view is a composition and integration point. It is easier to read after learning the types it connects.

## Follow a filter from click to history

| Stage | Code to read | What crosses the boundary |
| --- | --- | --- |
| Open a recording | `EVA/App/ContentView.swift`, `EVA/IO/SignalImportReader.swift`, `EVA/IO/MFFRecording.swift` | A file URL becomes recording metadata and signal arrays. Format-specific readers live in `EVACore/IO`. |
| Choose the input | `EVA/Filtering/FilteringViews.swift`, `applyBandpassFilter` | The current upstream signal and optional peripheral channels are passed to the filter model. A recording-session identity protects against closing/replacing the recording during the work. |
| Prepare and compute | `EVA/Filtering/FilterViewModel.swift`, `apply`; `EVA/Filtering/EEGSignalFilter.swift`, `bandPass` | The model snapshots settings and runs computation away from the UI. The engine validates cutoffs and processes channel arrays. |
| Publish | `FilterViewModel.apply` | Only the still-current request may publish its result and status. Publication happens on the model's actor. |
| Invalidate derived work | `FilteringViews.postFilterInvalidation`, `EVA/Pipeline/PipelineInvalidation.swift` | Results derived from the old filtered samples are cleared through the shared cascade. |
| Record | `EVA/Waveform/WaveformHistoryRail.swift`, `recordProcessingHistory` | A changed processing-chain signature drives recording of the step and a snapshot. Recording is not done once per progress update or render. |

`SignalSelection.validChannels` illustrates how callers can normalize channel indices; it is not a claim that every filter path calls that helper. Follow the actual call site when changing a particular operation.

## Three questions before editing

- Is this a display choice, a persistent setting, or a transformation of recorded samples?
- Is the result specific to one recording, one sample revision, or the whole application?
- Does this action need an invalidation cascade and a replayable processing step?

Use [history and replay](history-and-replay.md) for the last question and [testing](testing.md) to choose verification. The [commenting guide](commenting.md) gives the standard for explaining a change.
