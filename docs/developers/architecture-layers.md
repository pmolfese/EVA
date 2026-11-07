# Responsibilities and state ownership

This page replaces references to the retired `REFACTOR.md` notes. Historical labels L3, L4 and L5 still appear in some comments; they describe the following roles rather than Swift language features.

| Historical label | Current responsibility | Example |
| --- | --- | --- |
| L3 | Computation over explicit inputs: validate, transform and return results. Avoid depending on a live view. | `EyeArtifactThresholdDetector` |
| L4 | A model/coordinator owns configuration, current results and run lifecycle for a feature. | `FilterViewModel` |
| L5 | UI composition, presentation and user actions. | `WaveformChannelRows` |

The division is a reading aid, not a claim that every existing file already fits one role. Some legacy `WaveformView` extensions combine UI with orchestration. A file split does not alter that ownership.

## Lifetimes

Application settings and utility-window coordinators can live at the scene/app level. `ContentView` owns a recording window's context. `RecordingStore` collects shared per-recording state. Feature models own their parameters and results. Child views should receive the inputs and actions they need instead of reaching through the entire recording context.

Distinguish four kinds of state in comments and declarations:

- **Persistent configuration:** saved defaults or recorded operation parameters.
- **Committed processing result:** samples and provenance represented in history.
- **Derived cache:** replaceable data tied to an input revision/signature.
- **Presentation state:** selection, hover, disclosure and navigation that do not by themselves change recorded samples.

Use value snapshots for worker inputs; publish through the owning model after checking request identity. Explain any cache key that intentionally excludes a setting. A reference capture is not an immutable snapshot of its fields.

## Extraction checklist

Move a coherent declaration or operation, preserve its access requirements, and update every target that compiles it. EVACore files are compiled into several targets, and standalone CLI build scripts list sources explicitly. Preserve private helpers within an appropriate namespace rather than exposing generic global functions. Keep a numerical inner loop intact unless its behavior and performance are specifically being changed and tested.

For views, prefer an existing or new standalone `View` with explicit values/actions. For algorithms, retain a readable top-level sequence and name domain stages. See [history and replay](history-and-replay.md) before moving commit or invalidation code.
