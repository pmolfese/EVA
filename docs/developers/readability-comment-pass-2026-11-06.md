# Comment and onboarding pass

## Expanded pass: all original 1/5 and 2/5 files

Completed **all 50 requested files: 17 originally rated 1/5 and 33 rated 2/5**. Each now has function-level explanations and additional inline guidance for complex control flow, Swift/SwiftUI state and bindings, cancellation, matrix layouts, units, file parsing, or command handling as applicable. Existing useful comments were retained; misleading comments were corrected. The original scores remain historical. A November 7 focused reassessment of all 60 edited source files now appears in the [sorted ratings summary](readability-file-ratings-2026-11-06.md#readability-and-comment-summary), with corrected scores and a reason for each.

A final declaration scan found preceding comments for **all 1,743 detected Swift functions/initializers/deinitializers** in these files, including nested helpers. Embedded Metal source strings were left byte-for-byte intact; the helper's surrounding Swift comments explain their kernels. The exact requested NIH header is present in every file in this pass. The two test files edited in the initial pass also received the missing header, so all 60 source files changed across both passes contain it.

**Structural changes made: none.** No functions/types were moved, renamed, split, or rewritten. Executable source, embedded shaders, serialized values, tests, fixtures, and the repository's Xcode project settings were preserved. The work was sequential: each source file received a focused verification run before the next source edit.

### Verification and limits

- All 50 files passed Swift parsing, a whole-line-comment-only diff check against the start of this expanded pass, and a normalized parsed syntax-tree comparison. Normalization removes source positions and compiler-generated addresses; expressions, declarations, and literal contents remain identical. `git diff --check` passed.
- Each application/core/preview file has a passing focused existing test run below. For views, some checks exercise underlying models or selected rendering rather than every interactive workflow. Repeated suites are repeated verification, not additional unique tests.
- Both command-line tools built successfully. EVAHelper's existing CWL diagnostic completed both serial and sample-parallel Metal comparisons against CPU/LAPACK: maximum difference `1.3411e-7`, RMS difference `2.08939e-8` on its synthetic fixture. This diagnostic prints differences rather than enforcing a numerical tolerance.
- EVASimulate's Release build and **125 self-tests passed after each of its two file edits**, with no failed or known-limitation outcomes.
- The application test build still uses the temporary project described below because this command-line environment lacks the app's Metal toolchain/library. Tests that initialize that unavailable library were excluded in favor of applicable CPU/state checks. This affects selected artifact-workspace, channel-decision, PSA category/configuration, gradient, ICA-removal, pipeline, and wavelet paths. In particular, `ProcessingCoreTests` and the app's GPU kernels were not exercised; the pipeline row below covers related replay/invalidation tests. EVAHelper compiles its own shader string at runtime, so its successful Metal diagnostic does not establish app GPU coverage. These environment limitations are not evidence that the user's normal Xcode build is broken.

### Expanded-pass file table

“Comments +/−” counts comment lines added/replaced during this pass, including headers. Every row is now documented; the original ratings and sizes are preserved in the [full original table, now with a comment-status column](readability-file-ratings-2026-11-06.md).

| File improved | Original score | Comments +/− | Verification after edit |
| --- | --- | --- | --- |
| [EVA/Analysis/EEGAnalysisEngine.swift](../../EVA/Analysis/EEGAnalysisEngine.swift) | 2/5 | +96 / −0 | 1 passed: `EEGAnalysisEngineTests` |
| [EVA/Artifacts/ArtifactCleaner.swift](../../EVA/Artifacts/ArtifactCleaner.swift) | 1/5 | +220 / −0 | 20 passed: `ArtifactCleanerTests` |
| [EVA/Artifacts/ArtifactPreviewViews.swift](../../EVA/Artifacts/ArtifactPreviewViews.swift) | 1/5 | +185 / −0 | 7 passed: `CorneoRetinalCorrectionTests` |
| [EVA/Artifacts/ArtifactReviewWorkspace.swift](../../EVA/Artifacts/ArtifactReviewWorkspace.swift) | 1/5 | +195 / −0 | 43 passed: `ArtifactReviewTests`, `ArtifactReviewWorkspaceTests (selected)` |
| [EVA/Artifacts/ArtifactTemplateDefinitionViews.swift](../../EVA/Artifacts/ArtifactTemplateDefinitionViews.swift) | 2/5 | +149 / −0 | 8 passed: `ArtifactTemplateDetectorTests` |
| [EVA/Artifacts/ArtifactTemplateDetector.swift](../../EVA/Artifacts/ArtifactTemplateDetector.swift) | 1/5 | +77 / −0 | 8 passed: `ArtifactTemplateDetectorTests` |
| [EVA/Artifacts/CorneoRetinalCorrectionViews.swift](../../EVA/Artifacts/CorneoRetinalCorrectionViews.swift) | 2/5 | +72 / −0 | 7 passed: `CorneoRetinalCorrectionTests` |
| [EVA/Artifacts/MovementPCACorrection.swift](../../EVA/Artifacts/MovementPCACorrection.swift) | 2/5 | +116 / −0 | 13 passed: `MovementPCACorrectionTests` |
| [EVA/Artifacts/MuscleBSSCCACorrectionViews.swift](../../EVA/Artifacts/MuscleBSSCCACorrectionViews.swift) | 2/5 | +100 / −0 | 16 passed: `MuscleBSSCCACorrectionTests` |
| [EVA/Artifacts/SaccadicSpikeCorrectionViews.swift](../../EVA/Artifacts/SaccadicSpikeCorrectionViews.swift) | 2/5 | +39 / −0 | 6 passed: `SaccadicSpikeCorrectionTests` |
| [EVA/Cardiac/BCGDetectionViews.swift](../../EVA/Cardiac/BCGDetectionViews.swift) | 1/5 | +86 / −0 | 27 passed: `BCGDetectionViewModelTests`, `BCGDetectorTests` |
| [EVA/Cardiac/BCGDetector.swift](../../EVA/Cardiac/BCGDetector.swift) | 2/5 | +73 / −4 | 20 passed: `BCGDetectorTests` |
| [EVA/Cardiac/BCGSurrogateCorrection.swift](../../EVA/Cardiac/BCGSurrogateCorrection.swift) | 2/5 | +50 / −2 | 14 passed: `BCGSurrogateCorrectionTests` |
| [EVA/Cardiac/CWLCorrector.swift](../../EVA/Cardiac/CWLCorrector.swift) | 1/5 | +113 / −2 | 4 passed: `CWLCorrectorTests` |
| [EVA/Cardiac/ECGDetectionViews.swift](../../EVA/Cardiac/ECGDetectionViews.swift) | 2/5 | +44 / −0 | 10 passed: `RWaveDetectorTests` |
| [EVA/Channels/ChannelModel.swift](../../EVA/Channels/ChannelModel.swift) | 2/5 | +62 / −2 | 16 passed: `ChannelInterpolationComposerTests`, `RecordingHistoryForkTests` |
| [EVA/Epoching/AveragesWorkspaceViews.swift](../../EVA/Epoching/AveragesWorkspaceViews.swift) | 2/5 | +77 / −2 | 7 passed: `EpochSNRDeterminismTests` |
| [EVA/Epoching/EpochingViewModel.swift](../../EVA/Epoching/EpochingViewModel.swift) | 2/5 | +64 / −14 | 54 passed: `EpochingViewModelTests`, `TrialExclusionResolverTests` |
| [EVA/Epoching/PSADecisionMatrix.swift](../../EVA/Epoching/PSADecisionMatrix.swift) | 1/5 | +190 / −0 | 11 passed: `PSADecisionMatrixArtifactStatusTests`, `PSADecisionMatrixLayoutTests`, `PSAAmplitudeCutoffTests` |
| [EVA/Epoching/PSAEpochingViews.swift](../../EVA/Epoching/PSAEpochingViews.swift) | 1/5 | +105 / −6 | 20 passed: `EpochingViewModelTests`, `PSAAmplitudeCutoffTests` |
| [EVA/Epoching/SingleTrialAnalysisViews.swift](../../EVA/Epoching/SingleTrialAnalysisViews.swift) | 1/5 | +217 / −0 | 61 passed: `SingleTrialAnalyzerTests`, `TrialSelectionAnalyzerTests`, `TrialSelectionReviewTests`, `WoodyAlignmentAnalyzerTests`, `RIDEAnalyzerTests`, `CWTRidgePipelineTests` |
| [EVA/Filtering/EEGSignalFilter.swift](../../EVA/Filtering/EEGSignalFilter.swift) | 2/5 | +76 / −11 | 30 passed: `EEGSignalFilterTests`, `FIRFilterTests`, `FIRDesignRuleTests`, `EllipticFilterTests` |
| [EVA/Filtering/FilteringViews.swift](../../EVA/Filtering/FilteringViews.swift) | 2/5 | +50 / −1 | 41 passed: `FilterViewModelTests`, `ReplayControllerTests` |
| [EVA/Gradient/GradientTemplateCorrector.swift](../../EVA/Gradient/GradientTemplateCorrector.swift) | 2/5 | +52 / −0 | 10 passed: `GradientBrainSafetyRegressionTests`, `GradientTemplateCorrectorTests (selected)`, `GradientCorrectorStagesTests (selected)` |
| [EVA/Gradient/GradientViewModel.swift](../../EVA/Gradient/GradientViewModel.swift) | 2/5 | +79 / −14 | 36 passed: `GradientViewModelTests` |
| [EVA/Gradient/MRIGradientArtifactViews.swift](../../EVA/Gradient/MRIGradientArtifactViews.swift) | 2/5 | +54 / −3 | 43 passed: `TRSpacingTests`, `GradientViewModelTests` |
| [EVA/Health/ChannelHealthAnalyzer.swift](../../EVA/Health/ChannelHealthAnalyzer.swift) | 2/5 | +64 / −0 | 12 passed: `ChannelHealthAnalyzerTests`, `HealthScoringTests` |
| [EVA/ICA/ICAArtifactDetector.swift](../../EVA/ICA/ICAArtifactDetector.swift) | 1/5 | +105 / −4 | 14 passed: `ICAArtifactDetectorTests`, `ICAPicardOReferenceCrossCheckTests`, `ICAComponentRemovalTests (selected)` |
| [EVA/ICA/ICAExplorationViews.swift](../../EVA/ICA/ICAExplorationViews.swift) | 2/5 | +39 / −0 | 23 passed: `ICAReplayPayloadTests`, `ICAArtifactDetectorTests` |
| [EVA/Pipeline/ProcessingCore.swift](../../EVA/Pipeline/ProcessingCore.swift) | 2/5 | +22 / −5 | 41 passed: `ReplayCompatibilityTests`, `ReplaySettingsRestoreTests`, `PipelineInvalidationTests` |
| [EVA/Rhythmicity/LAVIEngine.swift](../../EVA/Rhythmicity/LAVIEngine.swift) | 2/5 | +51 / −0 | 14 passed: `LAVIEngineTests`, `RhythmicityMilestone0Tests` |
| [EVA/Rhythmicity/RhythmicityExplorerViewModel.swift](../../EVA/Rhythmicity/RhythmicityExplorerViewModel.swift) | 1/5 | +105 / −0 | 6 passed: `RhythmicityTimeFrequencyIntegrationTests`, `WTPLIntegrationTests` |
| [EVA/Trials/ClusterPermutationAnalyzer.swift](../../EVA/Trials/ClusterPermutationAnalyzer.swift) | 2/5 | +31 / −0 | 33 passed: `ClusterPermutationAnalyzerTests`, `ClusterRepeatedMeasuresTests`, `ClusterFormationTests` |
| [EVA/Trials/ClusterStatisticsViews.swift](../../EVA/Trials/ClusterStatisticsViews.swift) | 2/5 | +65 / −0 | 21 passed: `ClusterStatisticsDistributionsTests`, `ClusterSpatialAdjacencyTests`, `ClusterPermutationFAnalyzerTests` |
| [EVA/Trials/RIDEAnalyzer.swift](../../EVA/Trials/RIDEAnalyzer.swift) | 2/5 | +51 / −0 | 15 passed: `RIDEAnalyzerTests`, `WoodyAlignmentAnalyzerTests` |
| [EVA/Waveform/WaveformPlotViews.swift](../../EVA/Waveform/WaveformPlotViews.swift) | 2/5 | +92 / −1 | 24 passed: `EventTrackIndexTests`, `WaveformScaleUnitsTests`, `WaveformAppearancePreferencesTests` |
| [EVA/Waveform/WaveformSupportingTypes.swift](../../EVA/Waveform/WaveformSupportingTypes.swift) | 2/5 | +79 / −10 | 64 passed: `EpochedOverlayEventMapperTests`, `EpochingViewModelTests`, `TrialExclusionResolverTests`, `EpochSNRDeterminismTests` |
| [EVA/Waveform/WaveformView.swift](../../EVA/Waveform/WaveformView.swift) | 1/5 | +159 / −14 | 32 passed: `WaveformDensityLayoutTests`, `WaveformScaleUnitsTests`, `EventTrackIndexTests`, `EpochedOverlayEventMapperTests` |
| [EVA/Wavelet/WaveletArtifactAnalyzer.swift](../../EVA/Wavelet/WaveletArtifactAnalyzer.swift) | 1/5 | +91 / −38 | 14 passed: `WaveletArtifactAnalyzerTests`, `WaveletArtifactClassificationTests` |
| [EVA/Wavelet/WaveletArtifactExplorerViews.swift](../../EVA/Wavelet/WaveletArtifactExplorerViews.swift) | 1/5 | +54 / −8 | 6 passed: `WaveletArtifactAnalyzerTests`, `WaveletScalogramTests` |
| [EVA/Wavelet/WaveletMetalBackend.swift](../../EVA/Wavelet/WaveletMetalBackend.swift) | 2/5 | +38 / −7 | 6 passed: `WaveletArtifactAnalyzerTests`, `WaveletScalogramTests` |
| [EVA/Wavelet/WaveletReducer.swift](../../EVA/Wavelet/WaveletReducer.swift) | 2/5 | +57 / −5 | 21 passed: `EmpiricalBayesThresholdTests`, `EVATests (selected)` |
| [EVACore/Artifacts/SourceInformed/SourceInformedOperator.swift](../../EVACore/Artifacts/SourceInformed/SourceInformedOperator.swift) | 2/5 | +25 / −0 | 7 passed: `SourceInformedOperatorTests` |
| [EVACore/IO/MFFReader.swift](../../EVACore/IO/MFFReader.swift) | 2/5 | +87 / −0 | 46 passed: `MFFAcquisitionGapTests`, `MFFEventPrecisionTests`, `MFFPNSReaderTests`, `EventTimeAnchorTests`, `MFFAveragedRoundTripTests`, `MFFFileTypeTests`, `EVATests (selected)` |
| [EVACore/IO/NIfTI/NIfTIHeader.swift](../../EVACore/IO/NIfTI/NIfTIHeader.swift) | 2/5 | +58 / −0 | 18 passed: `NIfTIQuickLookReaderTests`, `NIfTIVolumeTests` |
| [EVAPreviewKit/DICOM/DICOMQuickLookReader.swift](../../EVAPreviewKit/DICOM/DICOMQuickLookReader.swift) | 2/5 | +51 / −1 | 6 passed: `DICOMQuickLookReaderTests` |
| [Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift](../../Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift) | 1/5 | +53 / −0 | Build + CPU/Metal diagnostic completed |
| [Tools/EVAHelper/Sources/EVAHelper/main.swift](../../Tools/EVAHelper/Sources/EVAHelper/main.swift) | 2/5 | +51 / −0 | Build + CPU/Metal diagnostic completed |
| [Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift](../../Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift) | 1/5 | +70 / −0 | Release build + 125 self-tests passed |
| [Tools/EVASimulate/Sources/EVASimulate/main.swift](../../Tools/EVASimulate/Sources/EVASimulate/main.swift) | 1/5 | +159 / −24 | Release build + 125 self-tests passed |

Across these 50 files: **4,298 comment lines added, 178 replaced/removed**. This count is descriptive, not a quality score.

## Initial 22-file pass (historical)

The scope was narrowed during implementation to comments and developer documentation. No implementation was refactored: no source files were moved or split, and no functions, types, state ownership, numerical operations, serialized formats or project settings were changed. The changes target shared contracts and the difficult entry points identified in the original audit; they do not constitute a rewrite of every source file.

Start with [the beginner reading path](getting-started.md). It links the Swift guide, domain glossary, data flow, ownership/history guidance, commenting standard and test guide. The root `REWIND.md` and `REFACTOR.md` files are compatibility pointers to maintained documentation, so historical source references have a useful destination again.

### Initial-pass verification

Focused existing tests are run after each edited source file before moving to the next. A separate diff check verifies that all source additions/removals are whole-line comments or blank lines and that all other source text is identical to the starting revision. The original Xcode project file is unchanged.

The command-line Xcode environment reports a missing Metal toolchain. A fresh test build in the tool sandbox also attempted to flatten fixture directories into duplicate bundle resources. These observations do not establish that the user's usual Xcode build is broken. Verification uses a temporary project copy outside the repository, excludes Metal compilation, and excludes non-Swift fixture resources from that copy only. Tests still use the real repository source and fixtures. The Swift compiler macro plugins require execution outside the tool sandbox.

The passing checks cover selected CPU, state, reader and rendering behavior; they do not validate GPU kernels, all UI workflows, or an ordinary fully configured release build. No toolchain was installed and no test expectations or fixture contents were changed.

At the end of the initial pass, three planned source-comment edits were deferred (all three are now included in the expanded pass above): `ProcessingCore.swift` and `RhythmicityExplorerViewModel.swift` were restored after their suites required unavailable Metal resources; `ArtifactReviewWorkspace.swift` was left untouched because its test path also initializes the Metal-dependent model. The pipeline suite hit the existing debug assertion for a missing shader library; five rhythmicity tests required a Metal coefficient provider. These are limitations of the temporary CPU-only setup, not evidence of regressions from comments. The successful MFF fixture run also experienced a long host/tool delay; its final result was 19 passing tests.

The initial pass completed **22 source-file comment edits**, sequentially. Each retained file has a passing focused test run after its edit. SignalStatisticsTests was rerun successfully after the final finite-input wording correction (7 passed). Counts below are per run; repeated suites are not additional unique tests. The view checks cover selected layout/rendering or underlying analysis behavior, not complete interactive workflows.

| Edited file | Existing suites | Result |
| --- | --- | --- |
| [EVA/Core/SignalSelection.swift](../../EVA/Core/SignalSelection.swift) | `SignalSelectionTests` | 4 passed |
| [EVA/Core/SignalStatistics.swift](../../EVA/Core/SignalStatistics.swift) | `SignalStatisticsTests` | 7 passed |
| [EVA/Health/HealthScoring.swift](../../EVA/Health/HealthScoring.swift) | `HealthScoringTests` | 8 passed |
| [EVA/Pipeline/LatestOnlyRunner.swift](../../EVA/Pipeline/LatestOnlyRunner.swift) | `LatestOnlyRunnerTests` | 6 passed |
| [EVACore/IO/MFFReader.swift](../../EVACore/IO/MFFReader.swift) | `MFFAcquisitionGapTests`, `MFFAveragedRoundTripTests`, `MFFPNSReaderTests` | 19 passed |
| [EVACore/Core/LinearAlgebra.swift](../../EVACore/Core/LinearAlgebra.swift) | `LinearAlgebraTests` | 14 passed |
| [EVA/Filtering/EEGSignalFilter.swift](../../EVA/Filtering/EEGSignalFilter.swift) | `EEGSignalFilterTests`, `FIRFilterTests` | 19 passed |
| [EVA/Filtering/FilterViewModel.swift](../../EVA/Filtering/FilterViewModel.swift) | `FilterViewModelTests` | 26 passed |
| [EVA/Rhythmicity/LAVIEngine.swift](../../EVA/Rhythmicity/LAVIEngine.swift) | `LAVIEngineTests` | 11 passed |
| [EVA/Trials/RIDEAnalyzer.swift](../../EVA/Trials/RIDEAnalyzer.swift) | `RIDEAnalyzerTests` | 8 passed |
| [EVA/ICA/ICAArtifactDetector.swift](../../EVA/ICA/ICAArtifactDetector.swift) | `ICAArtifactDetectorTests` | 9 passed |
| [EVA/Wavelet/EmpiricalBayesThreshold.swift](../../EVA/Wavelet/EmpiricalBayesThreshold.swift) | `EmpiricalBayesThresholdTests` | 15 passed |
| [EVA/Wavelet/WaveletReducer.swift](../../EVA/Wavelet/WaveletReducer.swift) | `EmpiricalBayesThresholdTests` | 15 passed |
| [EVA/Waveform/WaveformView.swift](../../EVA/Waveform/WaveformView.swift) | `WaveformDensityLayoutTests`, `HistoryRailRenderTests` | 16 passed |
| [EVA/Epoching/SingleTrialAnalysisViews.swift](../../EVA/Epoching/SingleTrialAnalysisViews.swift) | `SingleTrialAnalyzerTests`, `TrialSelectionReviewTests` | 23 passed |
| [EVA/Epoching/PSADecisionMatrix.swift](../../EVA/Epoching/PSADecisionMatrix.swift) | `PSADecisionMatrixLayoutTests`, `PSADecisionMatrixArtifactStatusTests` | 5 passed |
| [EVA/Artifacts/ArtifactCleaner.swift](../../EVA/Artifacts/ArtifactCleaner.swift) | `ArtifactCleanerTests` | 20 passed |
| [EVACore/IO/NIfTI/NIfTIHeader.swift](../../EVACore/IO/NIfTI/NIfTIHeader.swift) | `NIfTIQuickLookReaderTests` | 13 passed |
| [EVAPreviewKit/DICOM/DICOMQuickLookReader.swift](../../EVAPreviewKit/DICOM/DICOMQuickLookReader.swift) | `DICOMQuickLookReaderTests` | 6 passed |
| [EVATests/Rhythmicity/LAVIEngineTests.swift](../../EVATests/Rhythmicity/LAVIEngineTests.swift) | `LAVIEngineTests` | 11 passed |
| [EVATests/IO/DICOMQuickLookReaderTests.swift](../../EVATests/IO/DICOMQuickLookReaderTests.swift) | `DICOMQuickLookReaderTests` | 6 passed |
| [EVACore/Core/SeededGenerator.swift](../../EVACore/Core/SeededGenerator.swift) | `EpochSNRDeterminismTests` | 7 passed |

## Recommended structural changes for a separate pass

None of the following was implemented in this comment pass. Work through them individually with the appropriate original build configuration and regression tests.

| Priority | Files | Proposed boundary | What must remain stable |
| --- | --- | --- | --- |
| 1 | `EVACore/IO/MFFReader.swift` | Separate signal/event value models from package, XML and binary reading. Update every explicit CLI source list. | Sample revision semantics, event anchors, units, decoding and round trips. |
| 1 | `EVA/Waveform/WaveformView.swift` | Move gradient method/configuration enums into the gradient domain, then extract independent child views with explicit inputs/actions. | Persisted raw values, focus/menu routing and per-window state. |
| 1 | `Tools/EVASimulate/Sources/EVASimulate/main.swift` | Separate argument parsing, configuration assembly and command handlers; retain a small entry point. | Flag precedence, defaults, exit behavior and generated output. |
| 2 | `EVA/Epoching/SingleTrialAnalysisViews.swift` | Separate the waveform bridge, latency runner, inspector/result views and export work. | Raw versus averaged inputs, review decisions, bindings and commit callbacks. |
| 2 | `EVA/Epoching/PSADecisionMatrix.swift` | Separate preparation/decision models, layout geometry, rendering and interaction. | Stable channel/epoch identities, sorting, hit-testing and decisions. |
| 2 | `EVA/Artifacts/ArtifactReviewWorkspace.swift` | Isolate cached analysis/navigation from independent presentation panels. | Cache policy, review persistence across refreshes and artifact bindings. |
| 2 | `EVA/Channels/ChannelModel.swift` | Separate channel state, environment contracts and menu commands. | Focused-window command routing and interpolation ownership. |
| 2 | `EVA/Pipeline/ProcessingCore.swift` | Extract named operation handlers under one readable sequencer. | Ambient channel decisions, operation order, stop/skip outcomes and invalidation. |
| 3 | `EVA/Artifacts/ArtifactCleaner.swift` | Separate models, dispatch, individual cleaning methods and shared numerical support. | Method ordering, event-window rules and unchanged numerical operations. |
| 3 | `EVA/ICA/ICAArtifactDetector.swift` | Separate solver implementations within a deliberate namespace behind the existing entry point. | Matrix axes, whitening/reconstruction, seeds, floating-point order and fitted payloads. |
| 3 | `EVA/Rhythmicity/RhythmicityExplorerViewModel.swift` | Separate mode-specific state/run inputs while retaining one clear publication owner. | Generation checks, stale-result labels, cache signatures and persistence. |
| 3 | `EVA/Rhythmicity/LAVIEngine.swift`, `EVA/Trials/RIDEAnalyzer.swift` | Extract named initialization, computation and result-assembly stages. | Segment boundaries, normalization, iteration order and reference parity. |
| 3 | `EVA/Filtering/EEGSignalFilter.swift`, `EVA/Gradient/GradientViewModel.swift` | Separate configuration/run-input assembly from numerical design or run lifecycle. | Parameter defaults, serialization, phase/padding and publication rules. |
| 3 | `EVA/Wavelet/WaveletArtifactAnalyzer.swift`, `EVA/Wavelet/WaveletReducer.swift` | Separate configuration/results, transform/matching work and backend orchestration. | Coefficient layout, detection versus reduction semantics and CPU/GPU parity. |
| 3 | `Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift` | Extract named scientific scenario groups and fixture helpers. | Scenario order, random draws, expected values and non-vacuous check counts. |
| 3 | `Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift` | Separate regression preparation, CPU solve, GPU dispatch and embedded shader source. | Buffer layout, coefficients, overlap handling and backend parity; requires a working Metal toolchain. |

The first structural change should be small enough to explain and validate independently. A successful comment-only pass does not establish that a later numerical or state-ownership refactor is safe.
