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
defaults to `ProcessingDefaults` and a summary to `HistoryStepSummary`. Get this
right and undo, branching, replay, and batch all work for free; get it wrong and
the stage silently breaks reproducibility.
