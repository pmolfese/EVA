# History, replay and derived results

This is the maintained starting point for code that formerly referred to the retired `REWIND.md` design notes. Historical work-item numbers in comments describe development context; the implementation and current tests define behavior.

## Ownership and flow

`RecordingHistoryModel` owns the recording's history state. `EVAHistory` represents the tree. `PipelineSnapshot` captures/restores derived stage state. `WaveformHistoryRail` connects a processing-chain signature to recording and navigation in the UI.

A new sample result changes the chain signature. History records the corresponding processing description and can retain a snapshot. Navigating history must not create an ordinary new processing commit. A snapshot is an optimization and state capture, not a substitute for portable provenance.

`EVAProcessingScript` is the `eva.xml` representation. `ReplayController` handles interactive replay and decisions; `ProcessingCore` applies supported headless operations. Exact fitted results may additionally require recording-specific ICA/artifact payloads. Copying a script to another recording does not authorize reusing the original recording's fitted operator.

## Invariants to preserve

- Keep operation order: a headless run stops at an unsupported required step and returns the remaining suffix for its caller.
- Channel decisions are ambient state in the processing model; read the preapplication rules in `ProcessingCore` before changing their position.
- Apply downstream invalidation through `PipelineInvalidation`. Clearing only the visible output can leave stale epochs, interpolation or health analysis elsewhere.
- A worker may publish only while it still owns its request and recording context. Cancellation alone does not establish ownership.
- Serialized operation names, enum raw values and replay payload formats are compatibility contracts. Changing a display label need not change a persistence key.
- Deterministic recomputation depends on seeds, random draw order, matrix/reduction order and timing conventions, not just the absence of explicit randomness in a top-level function.

## Tests to read

Start with `LatestOnlyRunnerTests`, `PipelineInvalidationTests`, `PipelineSnapshotTests`, `RecordingHistoryForkTests` and `ProcessingCoreTests`. `PairedValidationTests` exercises agreement between processing paths; the IO round-trip tests protect event and sample representation. The test guide explains how to run them.
