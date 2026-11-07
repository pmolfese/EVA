# Pipeline — `EVA/Pipeline` (+ `EVACore/Pipeline`)

**Purpose.** The reproducibility **spine**. Every cleaning action becomes a node
in a branching history tree, is captured as a snapshot, and is appended to the
`eva.xml` processing script so the whole session can be replayed on new data or
run headlessly in batch. If you touch what a stage *does*, you touch this to make
it undoable and reproducible.

**Start here.** `RecordingHistoryModel` (the branching history tree),
`PipelineSnapshot` (capture/restore), `ProcessingCore.applyAutoSteps(...)` (the
shared "apply a stage" path), `ReplayController` (re-run a script with gates), and
`EVAProcessingScript` (the on-disk `eva.xml` schema, in `EVACore/Pipeline`).

## Files

**History & snapshots**

| File | Synopsis |
|---|---|
| `RecordingHistoryModel.swift` | The branching history tree: `record`, `storeSnapshot`, `snapshot`, forking (`ForkSeed`), re-derivation reasons. |
| `EVAHistory.swift` | The persisted history graph (`EVAHistoryNode`, `EVAHistory`, visited edges). |
| `PipelineSnapshot.swift` | Full-state capture/restore for a history node (`PipelineSnapshotting`). |
| `HistoryStepSummary.swift` | Human-readable summary of a history step. |

**Applying stages**

| File | Synopsis |
|---|---|
| `ProcessingCore.swift` | The shared apply path: `applyAutoSteps`, PNS filtering, PSA rejection events; `Result`, `ProgressUpdate`. |
| `PipelineStageToggles.swift` | Which stages are enabled in an auto-run. |
| `PipelineInvalidation.swift` | Decides which downstream results a change invalidates. |
| `ProcessingDefaults.swift` | Persisted default parameters for each stage. |
| `ProcessingQueue.swift` | Queues operations (`QueuedOperation`) for sequential execution. |
| `CleaningVarianceLedger.swift` | Accumulates the per-stage variance-removed accounting. |
| `ChannelDecisionSteps.swift` | Encodes per-channel good/bad/interpolate decisions as replayable steps. |

**Replay**

| File | Synopsis |
|---|---|
| `ReplayController.swift` | Re-runs a recorded script: `configure`, `plannedActions`, `gate`, `resume`; gate kinds/states/resolutions. |
| `ReplayConfigSheet.swift` | The replay configuration UI (per-step settings, progress). |
| `ReplayCompatibility.swift` | Flags when a saved script is incompatible with the current recording/app. |
| `ReplaySettingsRestore.swift` | Restores per-step settings from a saved script. |
| `PayloadConsistency.swift` | Validates that replay payloads (ICA/artifact matrices) are self-consistent. |
| `ChannelDecisionReplaySheet.swift` | UI for reviewing replayed channel decisions. |

**Batch & progress**

| File | Synopsis |
|---|---|
| `BatchController.swift` | Runs a script across many files (`BatchJob`, `JobStatus`, `BatchSummary`). |
| `HeadlessBatchProcessor.swift` | The UI-free batch executor (`Outcome`). |
| `BatchSetupSheet.swift` | Batch configuration UI. |
| `LatestOnlyRunner.swift` | Coalesces rapid re-runs to only the latest request. |
| `OperationProgress.swift` / `OperationProgressCenter.swift` / `ProgressBridge.swift` | Stage-level progress model, central registry, and the bridge that reports it to the UI. |
| `EVAProcessLog.swift` / `ProcessingAuditLog.swift` | The human-readable process log and the structured audit log. |

**Schema (in `EVACore/Pipeline`)**

| File | Synopsis |
|---|---|
| `EVAProcessingScript.swift` | The `eva.xml` schema: ordered `EVAProcessingStep`s, `Operation`, replay-payload availability, XML (de)serialization. |

## How to extend this

**Every new cleaning stage must round-trip through here.** Concretely: add an
`Operation` case to `EVAProcessingScript`, apply it in `ProcessingCore`, capture
what it needs in `PipelineSnapshot`, declare what it invalidates in
`PipelineInvalidation`, and — if it has learned state (an unmixing matrix, a
template) — give it a replay payload validated by `PayloadConsistency`. Add its
defaults to `ProcessingDefaults` and a summary to `HistoryStepSummary`.

These are integration points, not an automatic guarantee. Also wire interactive
settings restoration and replay dispatch where applicable. Test snapshot/restore,
undo and branching, serialized parameter round-trip, replay on the intended
recording, batch execution, downstream invalidation, and cancellation/stale-result
publication. Learned payloads may be recording-specific: verify compatibility
rather than reusing a matrix or template merely because it decodes. See
[history and replay](../history-and-replay.md) and [testing](../testing.md).

## Additional source files

These entries complete the source-group inventory at this review. The
[checked repository inventory](../source-inventory.md) lists nested/shared groups
and test/tool sources as well.

| File | Responsibility |
| --- | --- |
| [BatchCheckpoint.swift](../../../EVA/Pipeline/BatchCheckpoint.swift) | Persists batch progress for resumable jobs. |
| [BatchDecisionPolicy.swift](../../../EVA/Pipeline/BatchDecisionPolicy.swift) | Applies per-file rules for unsupported recorded decisions without reordering supported steps. |
| [BatchPrefixPlanner.swift](../../../EVA/Pipeline/BatchPrefixPlanner.swift) | Plans reuse of a recording’s existing processing prefix during batch replay. |
| [BatchPreflight.swift](../../../EVA/Pipeline/BatchPreflight.swift) | Inspects input metadata and replay compatibility before batch execution. |
| [StepQuality.swift](../../../EVA/Pipeline/StepQuality.swift) | Represents quality information attached to processing steps. |
