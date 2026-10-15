# ICA — `EVA/ICA`

**Purpose.** Independent Component Analysis: decompose the EEG into components,
label which ones are artifacts (eye, muscle, heart, line, channel noise), and
subtract the ones you reject.

**Start here.** `ICAArtifactDetector.fit(...)` runs the decomposition and
`cleanedSignal(...)` reconstructs after removal; `ICLabelClassifier.suggestions(...)`
(a CoreML IC-Label model) proposes labels; `ICAComponentRemoval.commit(...)`
turns a rejection set into a cleaned signal and a replay payload.

## Files

| File | Synopsis |
|---|---|
| `ICAArtifactDetector.swift` | The decomposition + cleanup engine: `fit`, `cleanedSignal`, `componentContributions`, config (`ICAMethod`, `ICAConfiguration`); produces `ICADecomposition` / `SavedICAArtifactSet`. |
| `ICLabelClassifier.swift` | CoreML IC-Label classifier (`suggestions`, `predict`, `features` → `ICLabelFeatures`). |
| `ICAComponentAutoLabeler.swift` | Heuristic auto-labeler from scalp/time/spectral features (fallback / complement to IC-Label). |
| `BCGComponentLabeller.swift` | Scanner-specific, beat-locked cardiac-component suggestions (logistic model over beat-locked features). |
| `ICAComponentRemoval.swift` | Applies a rejection set (`apply`/`commit`/`stagedPayload`) to produce the cleaned signal. |
| `ICAReplayPayload.swift` | Serializable ICA matrices + rejection set (`ICAMatrix`, `ICAReplay`) so a decomposition can be replayed deterministically. |
| `ICAComponentLabellerBenchmark.swift` | Scores label suggestions against graded simulator truth (per-class metrics). |
| `ICAViewModel.swift` | Observable state for the ICA workflow. |
| `ICAExplorationViews.swift` / `ICADebugReportViews.swift` | Component browser UI and the debug report (extensions on `WaveformView`). |

## How to extend this

A new **decomposition algorithm** is a case in `ICAMethod` handled in
`ICAArtifactDetector.fit`. A new **label class** touches the classifier
(`ICLabelClassifier`/`ICAComponentAutoLabeler`), the truth classes in
`ICAComponentLabellerBenchmark`, and the removal logic. Because ICA is
replay-critical, any change to how the unmixing matrix is stored must go through
`ICAReplayPayload` (and keep `PayloadConsistency` in [pipeline.md](pipeline.md)
happy). Evaluate new labelling against the simulator's component truth rather
than by eye.
