# Gradient — `EVA/Gradient`

**Purpose.** Remove the MRI **gradient artifact** from EEG recorded during
simultaneous EEG-fMRI. This is the largest cleaning subsystem because the
artifact is huge, periodic (one instance per volume/slice), and the correction
has several cooperating stages: build a template per TR epoch → subtract it (AAS)
→ mop up the residual (OBS/ANC).

**Start here.** `GradientTemplateCorrector` / `GradientAAS.correct(...)` do the
template subtraction; `GradientOBS.computeBasis(...)` and `GradientANC.apply(...)`
reduce the residual; `GradientViewModel` orchestrates it. `GradientEpochAligner`
+ `GradientEpochLayout` + `TRSpacing` establish the TR grid everything keys off.

## Files

| File | Synopsis |
|---|---|
| `GradientAAS.swift` | Average Artifact Subtraction: `correct`, `buildPlans`, `meanTemplate`/`meanUpdating`; config (`Preset`, `TemplateWindow`, `DetrendMode`). |
| `GradientTemplateCorrector.swift` | General template-correction engine (`Job`) shared by the gradient path. |
| `LocalTemplateArtifactCorrector.swift` | Template correction for *event-locked, non-gradient* repetitive artifacts (donor selection, reducers, per-event decisions). |
| `GradientOBS.swift` | Optimal Basis Set: PCA of the residual (`computeBasis`, `projection`) subtracted to remove residual structure. |
| `GradientANC.swift` | Adaptive Noise Cancellation of the residual (`apply`, `cutoffHz`, `HighPassPolicy`). |
| `GradientDonorSelection.swift` | Chooses which epochs donate to a template (`ScoredCandidate` ranking). |
| `GradientEpochAligner.swift` | Sub-sample alignment of TR epochs before averaging (`GradientEpochAlignment`). |
| `GradientEpochLayout.swift` | Lays out the TR/slice epoch grid over the recording. |
| `TRSpacing.swift` | Infers TR/slice timing (`TRSpacingInfo`). |
| `GradientSincResampler.swift` | Sinc resampling used for sub-sample template alignment. |
| `GradientFilters.swift` | Biquad filters used inside the gradient pipeline. |
| `GradientCorrectionTypes.swift` | The shared config/result/diagnostics vocabulary (`GradientCorrectionConfig`, `GradientCorrectionResult`, warnings). |
| `GradientAcceleration.swift` | Compute-backend plumbing: batch plans, device buffers, `GradientBackend` protocol, `GradientCPUBackend`, parallelism. |
| `GradientMetalBackend.swift` | GPU (Metal) implementation of the template/Gram/residual kernels. |
| `LocalTemplateMetalBackend.swift` | GPU backend for the local-template corrector. |
| `MotionParameters.swift` | Reads AFNI-style motion files (`MotionFileFormat`, `MotionSample`) for motion regressors. |
| `GradientViewModel.swift` | Orchestrates the whole correction; OBS/donor selection strategy enums. |
| `MRIGradientArtifactViews.swift` / `MotionConfigView.swift` | The correction UI and motion-file configuration. |

## How to extend this

The pipeline is **template → residual reduction**; slot a new method into the
matching stage: a template variant near `GradientAAS`/`GradientTemplateCorrector`,
a residual method alongside `GradientOBS`/`GradientANC`. Add its knobs to
`GradientCorrectionConfig` and surface them via `GradientViewModel`. Every compute
kernel has a CPU path (`GradientCPUBackend`) that is authoritative and a Metal
mirror (`GradientMetalBackend`) that must match it — add both, and gate the GPU
path behind the `GradientBackend` protocol. Timing changes (TR/slice inference)
ripple into every downstream stage, so validate `TRSpacing`/`GradientEpochLayout`
first.
