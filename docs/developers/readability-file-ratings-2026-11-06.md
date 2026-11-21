# EVA source file readability ratings

## Readability and comment summary

All 774 files, ordered from lowest to highest **corrected score where available, otherwise original score**, with filenames breaking ties. Scores consider code readability and explanatory comments together for a programmer with undergraduate CS coursework who is new to Swift/SwiftUI.

**Reassessment: November 7, 2026.** All **60 source files edited in the comment passes** now have corrected scores: **53 increased and 7 stayed the same**. An unchanged score still means the file was reassessed. The remaining **714** show “—” because they have not been reassessed.

These are editorial judgments using the original 1–5 rubric, based on focused reading of changed comments, representative implementations, and the original readability concerns, informed by the preceding comment pass. This is not a new line-by-line correctness review or a measured learner study. More comments do not automatically earn a higher score: large workflows, cross-file dependencies, unfamiliar Swift mechanisms, and specialist mathematics still count against ease of understanding. Scores of 5 are reserved here for the two small, self-contained helpers whose examples and contracts make their implementations directly traceable.

Updated-score distribution among the 60 reviewed files: **10 at 2/5, 42 at 3/5, 6 at 4/5, and 2 at 5/5**. Original scores remain visible for comparison. [Jump to the original rubric and detailed evidence](#original-assessment).

| File | Original score | Corrected score | Comment update | Reason for corrected score |
| --- | --- | --- | --- | --- |
| [EVA/Artifacts/ArtifactCleaner.swift](../../EVA/Artifacts/ArtifactCleaner.swift) | 1/5 | **2/5** | Expanded comments complete | Function contracts now explain fitting, subtraction, weights, and matrix layouts, but one large file still combines many cleaning algorithms and configuration models. |
| [EVA/Artifacts/ArtifactTemplateDetector.swift](../../EVA/Artifacts/ArtifactTemplateDetector.swift) | 1/5 | **2/5** | Expanded comments complete | Sample-coordinate conventions, candidate merging, and reference trajectories are clearer; the long trajectory search and numerical matching still demand specialist background. |
| [EVA/Epoching/PSADecisionMatrix.swift](../../EVA/Epoching/PSADecisionMatrix.swift) | 1/5 | **2/5** | Expanded comments complete | Sorted-to-original indices, decision snapshots, selections, and geometry contracts are clearer; the large combination of evidence preparation, interaction, and custom rendering still needs extensive tracing. |
| [EVA/Epoching/SingleTrialAnalysisViews.swift](../../EVA/Epoching/SingleTrialAnalysisViews.swift) | 1/5 | **2/5** | Expanded comments complete | Raw-trial versus average inputs, commit callbacks, bindings, and analysis panels are documented; more than 5,000 lines and many different analyses remain a difficult entry point. |
| [EVA/ICA/ICAArtifactDetector.swift](../../EVA/ICA/ICAArtifactDetector.swift) | 1/5 | **2/5** | Expanded comments complete | Matrix axes, fit preprocessing, solver roles, and reconstruction contracts are clearer; multiple optimization algorithms and dense flat workspaces still require considerable numerical expertise. |
| [EVA/Waveform/WaveformView.swift](../../EVA/Waveform/WaveformView.swift) | 1/5 | **2/5** | Expanded comments complete | The composition role, shared-state forwarding, cache inputs, and lifecycle actions now have explanations; the central view still spans thousands of lines and many feature extensions. |
| [EVA/Wavelet/WaveletArtifactAnalyzer.swift](../../EVA/Wavelet/WaveletArtifactAnalyzer.swift) | 1/5 | **2/5** | Expanded comments complete | Preparation, band summaries, preview reconstruction limits, and candidate contracts are clearer; the large mix of matching, classification, and transform processing remains difficult independently. |
| [Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift](../../Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift) | 1/5 | **2/5** | Expanded comments complete | Preparation, matrix transposition, regression windows, Metal fencing, and kernel roles are now documented; numerical backends and embedded shader implementations still require substantial specialist reading. |
| [Tools/EVASimulate/Sources/EVASimulate/main.swift](../../Tools/EVASimulate/Sources/EVASimulate/main.swift) | 1/5 | **2/5** | Expanded comments complete | Command contracts, option precedence, repeated flags, scoring units, and sweep preflight are documented; configuration assembly and many commands still occupy one very large file. |
| [Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift](../../Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift) | 1/5 | **2/5** | Expanded comments complete | Nested fixture helpers, measurement meanings, units, and comparison controls are clearer; one enormous run method still combines many scientific test scenarios. |
| [docs/figures/REWIND_FIG_1.html](../../docs/figures/REWIND_FIG_1.html) | 3/5 | — | No changes in these passes | — |
| [EVA/Analysis/EEGAnalysisEngine.swift](../../EVA/Analysis/EEGAnalysisEngine.swift) | 2/5 | **3/5** | Expanded comments complete | The analysis stages, array axes, cancellation outcome, and parallel result ordering are now explicit; spectral/connectivity calculations still need DSP guidance. |
| [EVA/Analysis/EEGAnalysisViewModel.swift](../../EVA/Analysis/EEGAnalysisViewModel.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/App/ContentView.swift](../../EVA/App/ContentView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/App/ERPExperimentEditor.swift](../../EVA/App/ERPExperimentEditor.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/App/EVAApp.swift](../../EVA/App/EVAApp.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/App/PreferencesView.swift](../../EVA/App/PreferencesView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactCleaningExecutor.swift](../../EVA/Artifacts/ArtifactCleaningExecutor.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactDetectionSummaryViews.swift](../../EVA/Artifacts/ArtifactDetectionSummaryViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactPreviewViews.swift](../../EVA/Artifacts/ArtifactPreviewViews.swift) | 1/5 | **3/5** | Expanded comments complete | Popover ownership, hover cancellation, binding side effects, and preview controls are explained; the many panels and OBS choices still require guided reading. |
| [EVA/Artifacts/ArtifactReviewWorkspace.swift](../../EVA/Artifacts/ArtifactReviewWorkspace.swift) | 1/5 | **3/5** | Expanded comments complete | Cache policy, parent bindings, session state, review decisions, and navigation now have local explanations; tracing the full review workflow still crosses several models. |
| [EVA/Artifacts/ArtifactSpatialGrouping.swift](../../EVA/Artifacts/ArtifactSpatialGrouping.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactTemplateDefinitionViews.swift](../../EVA/Artifacts/ArtifactTemplateDefinitionViews.swift) | 2/5 | **3/5** | Expanded comments complete | State initialization, detection-source selection, callbacks, and cleaning eligibility are documented; the large sheet and shared WaveformView dependencies remain substantial. |
| [EVA/Artifacts/CorneoRetinalCorrectionViews.swift](../../EVA/Artifacts/CorneoRetinalCorrectionViews.swift) | 2/5 | **3/5** | Expanded comments complete | The setup–analysis–acceptance sequence, blink-edit bindings, and invalidation rules are explained; CRD estimation and shared waveform state still need context. |
| [EVA/Artifacts/MovementPCACorrection.swift](../../EVA/Artifacts/MovementPCACorrection.swift) | 2/5 | **3/5** | Expanded comments complete | Temporal-PCA axes, factor-removal rules, skipped epochs, and column-major storage are explicit; understanding the decomposition still requires numerical guidance. |
| [EVA/Artifacts/MovementPCACorrectionViews.swift](../../EVA/Artifacts/MovementPCACorrectionViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Artifacts/MuscleBSSCCACorrection.swift](../../EVA/Artifacts/MuscleBSSCCACorrection.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Artifacts/MuscleBSSCCACorrectionViews.swift](../../EVA/Artifacts/MuscleBSSCCACorrectionViews.swift) | 2/5 | **3/5** | Expanded comments complete | Configuration bindings, analysis snapshots, worker cancellation, and review-only results are explained; the component workflow remains spread across UI and analysis models. |
| [EVA/Artifacts/SaccadicSpikeCorrection.swift](../../EVA/Artifacts/SaccadicSpikeCorrection.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Cardiac/BCGDetectionViews.swift](../../EVA/Cardiac/BCGDetectionViews.swift) | 1/5 | **3/5** | Expanded comments complete | Method controls, source-signal distinctions, event replacement, and refinement are documented; the large method-options switch and multiple correction paths still need guidance. |
| [EVA/Cardiac/BCGDetector.swift](../../EVA/Cardiac/BCGDetector.swift) | 2/5 | **3/5** | Expanded comments complete | Channel shape, exemplar precedence, rate conversions, whitening, and peak-selection contracts are clearer; PCA and adaptive normalization remain domain-heavy. |
| [EVA/Cardiac/BCGSurrogateCorrection.swift](../../EVA/Cardiac/BCGSurrogateCorrection.swift) | 2/5 | **3/5** | Expanded comments complete | Corrected versus fitting data, selected-row ordering, portable settings, and failure behavior are explicit; building the source-informed spatial operator still needs linear-algebra context. |
| [EVA/Cardiac/BCGSurrogateTopographies.swift](../../EVA/Cardiac/BCGSurrogateTopographies.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Cardiac/CWLCorrector.swift](../../EVA/Cardiac/CWLCorrector.swift) | 1/5 | **3/5** | Expanded comments complete | Regression windows, lagged references, factorization reuse, downsampling, and removal interpolation now have contracts; multiple algorithms and parallel numerical work remain complex. |
| [EVA/Cardiac/RWaveDetector.swift](../../EVA/Cardiac/RWaveDetector.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelInspectorViews.swift](../../EVA/Channels/ChannelInspectorViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelModel.swift](../../EVA/Channels/ChannelModel.swift) | 2/5 | **3/5** | Expanded comments complete | Interpolation recipes, original-input donor semantics, and focused-window bindings are documented; model state and global menu routing still share the file. |
| [EVA/Channels/ChannelSetEditorView.swift](../../EVA/Channels/ChannelSetEditorView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelsPanelViews.swift](../../EVA/Channels/ChannelsPanelViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelsWindowModel.swift](../../EVA/Channels/ChannelsWindowModel.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelsWindowView.swift](../../EVA/Channels/ChannelsWindowView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Combine/CombineRecordingsSheet.swift](../../EVA/Combine/CombineRecordingsSheet.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Epoching/AveragesWorkspaceViews.swift](../../EVA/Epoching/AveragesWorkspaceViews.swift) | 2/5 | **3/5** | Expanded comments complete | Shared epoch-relative selection, missing-value sorting, layout decisions, and export behavior are explained; several panels still depend on the wider waveform workspace. |
| [EVA/Epoching/EpochingViewModel.swift](../../EVA/Epoching/EpochingViewModel.swift) | 2/5 | **3/5** | Expanded comments complete | Build jobs, selective parameter restoration, review choices, and publication responsibilities are clearer; configuration, replay, and asynchronous result state remain combined. |
| [EVA/Epoching/PSAEpochingViews.swift](../../EVA/Epoching/PSAEpochingViews.swift) | 1/5 | **3/5** | Expanded comments complete | Event reconciliation, eligibility, queued application, review pauses, and session guards now explain the workflow; the large shared-state UI still benefits from guidance. |
| [EVA/Epoching/TrialDiagnosticsViews.swift](../../EVA/Epoching/TrialDiagnosticsViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Filtering/EEGSignalFilter.swift](../../EVA/Filtering/EEGSignalFilter.swift) | 2/5 | **3/5** | Expanded comments complete | Filter-family resolution, stage order, precision retry, FIR sizing, and numerical validation are clearer; several DSP families and long configuration paths still require background. |
| [EVA/Filtering/FilteringViews.swift](../../EVA/Filtering/FilteringViews.swift) | 2/5 | **3/5** | Expanded comments complete | Bindings, enabled controls, queued application, replay gates, and export responsibilities are explained; filtering UI and replay/export actions still span a broad workflow. |
| [EVA/Filtering/FilterViewModel.swift](../../EVA/Filtering/FilterViewModel.swift) | 3/5 | **3/5** | Initial focused comments | The new lifecycle explanation distinguishes snapshots, cancellation, and publication ownership; the long apply path and compatibility restoration still keep this at the guided-reading level. |
| [EVA/Gradient/GradientAAS.swift](../../EVA/Gradient/GradientAAS.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientEpochAligner.swift](../../EVA/Gradient/GradientEpochAligner.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientMetalBackend.swift](../../EVA/Gradient/GradientMetalBackend.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientTemplateCorrector.swift](../../EVA/Gradient/GradientTemplateCorrector.swift) | 2/5 | **3/5** | Expanded comments complete | The stage roadmap, tile/slot layout, donor fallback, and OBS return behavior are explicit; backend buffers and multistage numerical processing still need DSP guidance. |
| [EVA/Gradient/GradientTimingCheck.swift](../../EVA/Gradient/GradientTimingCheck.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientViewModel.swift](../../EVA/Gradient/GradientViewModel.swift) | 2/5 | **3/5** | Expanded comments complete | Timing-probe keys, worker publication, serialized settings, and correction ownership are documented; several engines and compatibility rules remain in one large model. |
| [EVA/Gradient/LocalTemplateArtifactCorrector.swift](../../EVA/Gradient/LocalTemplateArtifactCorrector.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Gradient/MotionConfigView.swift](../../EVA/Gradient/MotionConfigView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Gradient/MRIGradientArtifactViews.swift](../../EVA/Gradient/MRIGradientArtifactViews.swift) | 2/5 | **3/5** | Expanded comments complete | Marker coordinates, timing eligibility, bounded bindings, and engine-specific controls are explained; acquisition timing and motion requirements still need domain context. |
| [EVA/Health/ChannelHealthAnalyzer.swift](../../EVA/Health/ChannelHealthAnalyzer.swift) | 2/5 | **3/5** | Expanded comments complete | Feature sampling, recording-wide baselines, scoring, and invalid-data behavior are clearer; interpreting the many signal-quality features remains a guided task. |
| [EVA/Health/ChannelHealthDetailViews.swift](../../EVA/Health/ChannelHealthDetailViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Health/ChannelRelationshipAnalyzer.swift](../../EVA/Health/ChannelRelationshipAnalyzer.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Health/HealthDetailViews.swift](../../EVA/Health/HealthDetailViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Health/SegmentHealthAnalyzer.swift](../../EVA/Health/SegmentHealthAnalyzer.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Health/SegmentHealthDetailViews.swift](../../EVA/Health/SegmentHealthDetailViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/ICA/BCGComponentLabeller.swift](../../EVA/ICA/BCGComponentLabeller.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/ICA/ICAComponentAutoLabeler.swift](../../EVA/ICA/ICAComponentAutoLabeler.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/ICA/ICAComponentLabellerBenchmark.swift](../../EVA/ICA/ICAComponentLabellerBenchmark.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/ICA/ICADebugReportViews.swift](../../EVA/ICA/ICADebugReportViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/ICA/ICAExplorationViews.swift](../../EVA/ICA/ICAExplorationViews.swift) | 2/5 | **3/5** | Expanded comments complete | Fit versus removal, exclusion bindings, source-index conversion, and cancellation/session checks are explicit; component interpretation and shared model state still need guidance. |
| [EVA/ICA/ICAReplayPayload.swift](../../EVA/ICA/ICAReplayPayload.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/ICA/ICLabelClassifier.swift](../../EVA/ICA/ICLabelClassifier.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/IO/MFFExportFlowViews.swift](../../EVA/IO/MFFExportFlowViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/IO/MFFRecording.swift](../../EVA/IO/MFFRecording.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/IO/MFFSignalSplitter.swift](../../EVA/IO/MFFSignalSplitter.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/IO/SignalImportReader.swift](../../EVA/IO/SignalImportReader.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Pipeline/BatchCheckpoint.swift](../../EVA/Pipeline/BatchCheckpoint.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Pipeline/BatchSetupSheet.swift](../../EVA/Pipeline/BatchSetupSheet.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ProcessingCore.swift](../../EVA/Pipeline/ProcessingCore.swift) | 2/5 | **3/5** | Expanded comments complete | Starting-signal selection, physiology input, rejection events, and replay/payload ownership are clearer; the long sequencing switch still requires following downstream model effects. |
| [EVA/Rhythmicity/ABBABandTableView.swift](../../EVA/Rhythmicity/ABBABandTableView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/ABBAEngine.swift](../../EVA/Rhythmicity/ABBAEngine.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/AccelerateFFTComplexCoefficientProvider.swift](../../EVA/Rhythmicity/AccelerateFFTComplexCoefficientProvider.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/AperiodicSpectrumEstimator.swift](../../EVA/Rhythmicity/AperiodicSpectrumEstimator.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/IAAFTSurrogateGenerator.swift](../../EVA/Rhythmicity/IAAFTSurrogateGenerator.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/LAVIEngine.swift](../../EVA/Rhythmicity/LAVIEngine.swift) | 2/5 | **3/5** | Expanded comments complete | Backend fallback, finite-run orchestration, lag interpolation, and synchronized result slots are explained; the rhythmicity statistic and significance machinery still need scientific guidance. |
| [EVA/Rhythmicity/LAVISignificanceProvider.swift](../../EVA/Rhythmicity/LAVISignificanceProvider.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/LAVISpectrumView.swift](../../EVA/Rhythmicity/LAVISpectrumView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicBurstDetector.swift](../../EVA/Rhythmicity/RhythmicBurstDetector.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicBurstRunner.swift](../../EVA/Rhythmicity/RhythmicBurstRunner.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicBurstView.swift](../../EVA/Rhythmicity/RhythmicBurstView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityExplorerView.swift](../../EVA/Rhythmicity/RhythmicityExplorerView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityExplorerViewModel.swift](../../EVA/Rhythmicity/RhythmicityExplorerViewModel.swift) | 1/5 | **3/5** | Expanded comments complete | Main-actor ownership, worker snapshots, context synchronization, staleness, and retained results now have explicit contracts; coordinating three analysis modes remains substantial. |
| [EVA/Rhythmicity/RhythmicityExport.swift](../../EVA/Rhythmicity/RhythmicityExport.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityMetalBackend.swift](../../EVA/Rhythmicity/RhythmicityMetalBackend.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityModels.swift](../../EVA/Rhythmicity/RhythmicityModels.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityPersistence.swift](../../EVA/Rhythmicity/RhythmicityPersistence.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/WTPLEngine.swift](../../EVA/Rhythmicity/WTPLEngine.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/WTPLExport.swift](../../EVA/Rhythmicity/WTPLExport.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/WTPLView.swift](../../EVA/Rhythmicity/WTPLView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyExport.swift](../../EVA/TimeFrequency/TimeFrequencyExport.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyHeatmap.swift](../../EVA/TimeFrequency/TimeFrequencyHeatmap.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyKernels.metal](../../EVA/TimeFrequency/TimeFrequencyKernels.metal) | 3/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyOverviewView.swift](../../EVA/TimeFrequency/TimeFrequencyOverviewView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyView.swift](../../EVA/TimeFrequency/TimeFrequencyView.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Trials/ClusterFormation.swift](../../EVA/Trials/ClusterFormation.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Trials/ClusterPermutationAnalyzer.swift](../../EVA/Trials/ClusterPermutationAnalyzer.swift) | 2/5 | **3/5** | Expanded comments complete | Exchangeability, trial layout, paired sign flips, deterministic seeds, and cancellation are documented; cluster/TFCE inference still requires statistical background. |
| [EVA/Trials/ClusterPermutationFAnalyzer.swift](../../EVA/Trials/ClusterPermutationFAnalyzer.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Trials/ClusterStatisticsRunner.swift](../../EVA/Trials/ClusterStatisticsRunner.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Trials/ClusterStatisticsViews.swift](../../EVA/Trials/ClusterStatisticsViews.swift) | 2/5 | **3/5** | Expanded comments complete | Input signatures, threshold bindings, local-to-recording indices, and result formatting are explained; the two statistical designs and multi-panel state still need guided reading. |
| [EVA/Trials/RIDEAnalyzer.swift](../../EVA/Trials/RIDEAnalyzer.swift) | 2/5 | **3/5** | Expanded comments complete | The decomposition roadmap, timing units, lag search, support clipping, and failure conventions are clearer; the long iterative S/C/R algorithm still needs method-specific context. |
| [EVA/Trials/WoodyAlignmentAnalyzer.swift](../../EVA/Trials/WoodyAlignmentAnalyzer.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Waveform/ButterflyPanelViews.swift](../../EVA/Waveform/ButterflyPanelViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformHistoryRail.swift](../../EVA/Waveform/WaveformHistoryRail.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformPlotViews.swift](../../EVA/Waveform/WaveformPlotViews.swift) | 2/5 | **3/5** | Expanded comments complete | Viewport/content coordinates, event-signature limits, scaling, scrubbing, and hover behavior are documented; many custom drawing paths remain beyond introductory SwiftUI. |
| [EVA/Waveform/WaveformSheetHost.swift](../../EVA/Waveform/WaveformSheetHost.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformSupportingTypes.swift](../../EVA/Waveform/WaveformSupportingTypes.swift) | 2/5 | **3/5** | Expanded comments complete | Epoch job planning, rejection tallies, progress callbacks, averaging, and reference/baseline order are clearer; the long epoch builder and mixed supporting types still need guidance. |
| [EVA/Wavelet/EmpiricalBayesThreshold.swift](../../EVA/Wavelet/EmpiricalBayesThreshold.swift) | 3/5 | **3/5** | Initial focused comments | The added reading aid clarifies what the estimator returns, but prior/posterior reasoning and threshold derivation still exceed ordinary introductory CS; the score remains 3. |
| [EVA/Wavelet/WaveletArtifactExplorerViews.swift](../../EVA/Wavelet/WaveletArtifactExplorerViews.swift) | 1/5 | **3/5** | Expanded comments complete | Preset side effects, inverted inclusion bindings, preview selection, and cancellation/cache behavior are explained; reduction and exploration still share extensive waveform state. |
| [EVA/Wavelet/WaveletMetalBackend.swift](../../EVA/Wavelet/WaveletMetalBackend.swift) | 2/5 | **3/5** | Expanded comments complete | Buffer dimensions, lifetimes, in-place changes, pipeline setup, and dispatch ownership are documented; Metal command ordering and external kernels still need specialist lookup. |
| [EVA/Wavelet/WaveletModels.swift](../../EVA/Wavelet/WaveletModels.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WaveletReducer.swift](../../EVA/Wavelet/WaveletReducer.swift) | 2/5 | **3/5** | Expanded comments complete | CPU/GPU orchestration, threshold assumptions, artifact reconstruction, and edge conventions are clearer; several transforms and numerical paths still require wavelet background. |
| [EVA/Wavelet/WaveletReductionSheetViews.swift](../../EVA/Wavelet/WaveletReductionSheetViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WICAExplorationViews.swift](../../EVA/Wavelet/WICAExplorationViews.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WICAProcessor.swift](../../EVA/Wavelet/WICAProcessor.swift) | 3/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WICAViewModel.swift](../../EVA/Wavelet/WICAViewModel.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Artifacts/SourceInformed/SourceInformedOperator.swift](../../EVACore/Artifacts/SourceInformed/SourceInformedOperator.swift) | 2/5 | **3/5** | Expanded comments complete | Basis dimensions, orthogonal projection, regularization, and validation are explicit; the matrix derivation and BLAS layout remain beyond routine application code. |
| [EVACore/Core/DSP.swift](../../EVACore/Core/DSP.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Core/Forward/ForwardOperator.swift](../../EVACore/Core/Forward/ForwardOperator.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Core/Forward/SphericalForwardModel.swift](../../EVACore/Core/Forward/SphericalForwardModel.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Core/LinearAlgebra.swift](../../EVACore/Core/LinearAlgebra.swift) | 3/5 | **3/5** | Initial focused comments | The added shape and failure contracts help, but several elementary helpers remain undocumented and LAPACK adds a second storage convention; the score stays 3. |
| [EVACore/IO/BDFRecording.swift](../../EVACore/IO/BDFRecording.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/IO/GIFTI/GIFTIPreviewModel.swift](../../EVACore/IO/GIFTI/GIFTIPreviewModel.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/IO/GIFTI/GIFTIQuickLookReader.swift](../../EVACore/IO/GIFTI/GIFTIQuickLookReader.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/IO/MFFReader.swift](../../EVACore/IO/MFFReader.swift) | 2/5 | **3/5** | Expanded comments complete | Signal axes, revisions, event timing, calibration, binary blocks, and XML helpers are documented; several models and file-format layers still share a large file. |
| [EVACore/IO/NIfTI/NIfTIHeader.swift](../../EVACore/IO/NIfTI/NIfTIHeader.swift) | 2/5 | **3/5** | Expanded comments complete | Version-specific layouts, endian reading, units, and sform/qform precedence are clearer; fixed offsets and quaternion/affine geometry still require format knowledge. |
| [EVACore/Simulation/AdditionalArtifactModel.swift](../../EVACore/Simulation/AdditionalArtifactModel.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Simulation/DipoleEEGGenerator.swift](../../EVACore/Simulation/DipoleEEGGenerator.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Simulation/EMGArtifactModel.swift](../../EVACore/Simulation/EMGArtifactModel.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Simulation/ERPExperiment.swift](../../EVACore/Simulation/ERPExperiment.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Simulation/ERPGenerator.swift](../../EVACore/Simulation/ERPGenerator.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Simulation/NonstationaryEEGModel.swift](../../EVACore/Simulation/NonstationaryEEGModel.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SimulationSweep.swift](../../EVACore/Simulation/SimulationSweep.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SingleDipoleFit.swift](../../EVACore/Simulation/SingleDipoleFit.swift) | 3/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SweepEvaluation.swift](../../EVACore/Simulation/SweepEvaluation.swift) | 3/5 | — | No changes in these passes | — |
| [EVAPreviewKit/CIFTI/CIFTIQuickLookReader.swift](../../EVAPreviewKit/CIFTI/CIFTIQuickLookReader.swift) | 3/5 | — | No changes in these passes | — |
| [EVAPreviewKit/CIFTI/CIFTIXMLParser.swift](../../EVAPreviewKit/CIFTI/CIFTIXMLParser.swift) | 3/5 | — | No changes in these passes | — |
| [EVAPreviewKit/DICOM/DICOMQuickLookReader.swift](../../EVAPreviewKit/DICOM/DICOMQuickLookReader.swift) | 2/5 | **3/5** | Expanded comments complete | The parse-to-preview route, borrowed-byte lifetime, VR/endian rules, and pixel conversion are explained; transfer syntaxes, tags, and sequence handling remain specialized. |
| [EVAPreviewKit/FIF/FIFQuickLookReader.swift](../../EVAPreviewKit/FIF/FIFQuickLookReader.swift) | 3/5 | — | No changes in these passes | — |
| [EVAPreviewKit/GIFTI/GIFTISceneFactory.swift](../../EVAPreviewKit/GIFTI/GIFTISceneFactory.swift) | 3/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MFF/MFFQuickLookSummaryReader.swift](../../EVAPreviewKit/MFF/MFFQuickLookSummaryReader.swift) | 3/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MGH/MGHQuickLookReader.swift](../../EVAPreviewKit/MGH/MGHQuickLookReader.swift) | 3/5 | — | No changes in these passes | — |
| [EVAPreviewKit/NIfTI/NIfTIQuickLookReader.swift](../../EVAPreviewKit/NIfTI/NIfTIQuickLookReader.swift) | 3/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/SourceSimulatorController.swift](../../EVAResolve/Simulator/SourceSimulatorController.swift) | 3/5 | — | No changes in these passes | — |
| [EVAResolveTests/SourceSimulatorControllerTests.swift](../../EVAResolveTests/SourceSimulatorControllerTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ArtifactCleanerTests.swift](../../EVATests/Artifacts/ArtifactCleanerTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ArtifactReviewTests.swift](../../EVATests/Artifacts/ArtifactReviewTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Cardiac/BCGSurrogateCorrectionTests.swift](../../EVATests/Cardiac/BCGSurrogateCorrectionTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Combine/RecordingCombinerTests.swift](../../EVATests/Combine/RecordingCombinerTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Epoching/EpochBadChannelDetectorTests.swift](../../EVATests/Epoching/EpochBadChannelDetectorTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Epoching/TrialExclusionResolverTests.swift](../../EVATests/Epoching/TrialExclusionResolverTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/EVATests.swift](../../EVATests/EVATests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Gradient/FASTRC5EvaluationTests.swift](../../EVATests/Gradient/FASTRC5EvaluationTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientRunGradeMeasurementTests.swift](../../EVATests/Gradient/GradientRunGradeMeasurementTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientTemplateCorrectorTests.swift](../../EVATests/Gradient/GradientTemplateCorrectorTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientViewModelTests.swift](../../EVATests/Gradient/GradientViewModelTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/IO/BDFImportTests.swift](../../EVATests/IO/BDFImportTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/IO/CIFTIQuickLookReaderTests.swift](../../EVATests/IO/CIFTIQuickLookReaderTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/IO/DICOMQuickLookReaderTests.swift](../../EVATests/IO/DICOMQuickLookReaderTests.swift) | 3/5 | **3/5** | Initial focused comments | The fixture's scaled pixel values now explain the main assertions; constructing the synthetic binary dataset and interpreting syntax UIDs still require DICOM knowledge, so the score stays 3. |
| [EVATests/IO/GIFTIQuickLookReaderTests.swift](../../EVATests/IO/GIFTIQuickLookReaderTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/IO/NIfTIQuickLookReaderTests.swift](../../EVATests/IO/NIfTIQuickLookReaderTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/MethodComparison/MethodComparisonRunner.swift](../../EVATests/Pipeline/MethodComparison/MethodComparisonRunner.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/PairedValidationTests.swift](../../EVATests/Pipeline/PairedValidationTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/PipelineRegressionTests.swift](../../EVATests/Pipeline/PipelineRegressionTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/AccelerateFFTComplexCoefficientProviderTests.swift](../../EVATests/Rhythmicity/AccelerateFFTComplexCoefficientProviderTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/LAVISignificanceProviderTests.swift](../../EVATests/Rhythmicity/LAVISignificanceProviderTests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/RhythmicityMilestone8Tests.swift](../../EVATests/Rhythmicity/RhythmicityMilestone8Tests.swift) | 3/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WICACampaignTests.swift](../../EVATests/Wavelet/WICACampaignTests.swift) | 3/5 | — | No changes in these passes | — |
| [Tools/convert_iclabel_to_coreml.py](../../Tools/convert_iclabel_to_coreml.py) | 3/5 | — | No changes in these passes | — |
| [Tools/EVAGradient/main.swift](../../Tools/EVAGradient/main.swift) | 3/5 | — | No changes in these passes | — |
| [Tools/EVAHelper/Sources/EVAHelper/BrainVisionHelperReader.swift](../../Tools/EVAHelper/Sources/EVAHelper/BrainVisionHelperReader.swift) | 3/5 | — | No changes in these passes | — |
| [Tools/EVAHelper/Sources/EVAHelper/main.swift](../../Tools/EVAHelper/Sources/EVAHelper/main.swift) | 2/5 | **3/5** | Expanded comments complete | Argument handling, EEG/PNS rate differences, processing order, comparisons, and export behavior are explained; the long end-to-end runner still benefits from guidance. |
| [Tools/EVAHelper/Sources/EVAHelper/OriginalCWLCorrectorEngine.swift](../../Tools/EVAHelper/Sources/EVAHelper/OriginalCWLCorrectorEngine.swift) | 3/5 | — | No changes in these passes | — |
| [Tools/RhythmicityReference/generate_wtpl_oracle.py](../../Tools/RhythmicityReference/generate_wtpl_oracle.py) | 3/5 | — | No changes in these passes | — |
| [docs/figures/REWIND_FIG_2.html](../../docs/figures/REWIND_FIG_2.html) | 4/5 | — | No changes in these passes | — |
| [EVA/Analysis/EEGAnalysisModels.swift](../../EVA/Analysis/EEGAnalysisModels.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Analysis/EEGAnalysisSheet.swift](../../EVA/Analysis/EEGAnalysisSheet.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/BatchWindowView.swift](../../EVA/App/BatchWindowView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/DebugLog.swift](../../EVA/App/DebugLog.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/ERPStudioHelp.swift](../../EVA/App/ERPStudioHelp.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/EventAnchorCatalog.swift](../../EVA/App/EventAnchorCatalog.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/EventAnchorPreferencesView.swift](../../EVA/App/EventAnchorPreferencesView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/EventAnchorSettings.swift](../../EVA/App/EventAnchorSettings.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/OpenRecordingRegistry.swift](../../EVA/App/OpenRecordingRegistry.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/PendingWindowForks.swift](../../EVA/App/PendingWindowForks.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/PendingWindowOpens.swift](../../EVA/App/PendingWindowOpens.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/RecordingStore.swift](../../EVA/App/RecordingStore.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/SimulatorGenerateView.swift](../../EVA/App/SimulatorGenerateView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/SimulatorGroupView.swift](../../EVA/App/SimulatorGroupView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/SimulatorHelp.swift](../../EVA/App/SimulatorHelp.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/SimulatorScoreView.swift](../../EVA/App/SimulatorScoreView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/SimulatorSweepView.swift](../../EVA/App/SimulatorSweepView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/SimulatorWindowView.swift](../../EVA/App/SimulatorWindowView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/SweepHelp.swift](../../EVA/App/SweepHelp.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/TemporaryFileSweeper.swift](../../EVA/App/TemporaryFileSweeper.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/UpdateChecker.swift](../../EVA/App/UpdateChecker.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/App/WindowCloseBehavior.swift](../../EVA/App/WindowCloseBehavior.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactCleaningCore.swift](../../EVA/Artifacts/ArtifactCleaningCore.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactCleanRunGrade.swift](../../EVA/Artifacts/ArtifactCleanRunGrade.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactReplayPayload.swift](../../EVA/Artifacts/ArtifactReplayPayload.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactReview.swift](../../EVA/Artifacts/ArtifactReview.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactTemplateViewModel.swift](../../EVA/Artifacts/ArtifactTemplateViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactViewModel.swift](../../EVA/Artifacts/ArtifactViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ArtifactWaveformGrouping.swift](../../EVA/Artifacts/ArtifactWaveformGrouping.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/CorneoRetinalCorrection.swift](../../EVA/Artifacts/CorneoRetinalCorrection.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/CorneoRetinalHelp.swift](../../EVA/Artifacts/CorneoRetinalHelp.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/CorneoRetinalViewModel.swift](../../EVA/Artifacts/CorneoRetinalViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/MAACPreliminaryBlinkDetector.swift](../../EVA/Artifacts/MAACPreliminaryBlinkDetector.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/MovementPCAViewModel.swift](../../EVA/Artifacts/MovementPCAViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/MuscleBSSCCAViewModel.swift](../../EVA/Artifacts/MuscleBSSCCAViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/SaccadicSpikeCorrectionViews.swift](../../EVA/Artifacts/SaccadicSpikeCorrectionViews.swift) | 2/5 | **4/5** | Expanded comments complete | The focused setup/detect/accept workflow now explains channel roles, index conversion, validation, and stale-result guards; remaining lookups are localized to the detector and shared state. |
| [EVA/Artifacts/SaccadicSpikeHelp.swift](../../EVA/Artifacts/SaccadicSpikeHelp.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/SaccadicSpikeViewModel.swift](../../EVA/Artifacts/SaccadicSpikeViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/SourceInformed/SurrogateBrainBasis.swift](../../EVA/Artifacts/SourceInformed/SurrogateBrainBasis.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Artifacts/ThresholdOcularReviewViews.swift](../../EVA/Artifacts/ThresholdOcularReviewViews.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Cardiac/BCGDetectionPreviewEstimator.swift](../../EVA/Cardiac/BCGDetectionPreviewEstimator.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Cardiac/BCGDetectionViewModel.swift](../../EVA/Cardiac/BCGDetectionViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Cardiac/BCGDurationEstimator.swift](../../EVA/Cardiac/BCGDurationEstimator.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Cardiac/ECGDetectionViewModel.swift](../../EVA/Cardiac/ECGDetectionViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Cardiac/ECGDetectionViews.swift](../../EVA/Cardiac/ECGDetectionViews.swift) | 2/5 | **4/5** | Expanded comments complete | Source selection, PNS/EEG naming heuristics, bindings, and preview publication are explained, including where event refresh actually happens; the workflow is focused enough for localized lookups. |
| [EVA/Cardiac/PCASRunGrade.swift](../../EVA/Cardiac/PCASRunGrade.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelGoodnessSettings.swift](../../EVA/Channels/ChannelGoodnessSettings.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelInterpolationSolver.swift](../../EVA/Channels/ChannelInterpolationSolver.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelLocationImportViews.swift](../../EVA/Channels/ChannelLocationImportViews.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelSetMapView.swift](../../EVA/Channels/ChannelSetMapView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelSetPickerView.swift](../../EVA/Channels/ChannelSetPickerView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelSetStore.swift](../../EVA/Channels/ChannelSetStore.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/DisplayChannels.swift](../../EVA/Channels/DisplayChannels.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ElectrodeGeometry+Forward.swift](../../EVA/Channels/ElectrodeGeometry+Forward.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/InterpolatedSignalResolver.swift](../../EVA/Channels/InterpolatedSignalResolver.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ScalpTopography3DView.swift](../../EVA/Channels/ScalpTopography3DView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/TopomapView.swift](../../EVA/Channels/TopomapView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Combine/MultiRecordingModels.swift](../../EVA/Combine/MultiRecordingModels.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Combine/RecordingCombiner.swift](../../EVA/Combine/RecordingCombiner.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Compare/CompareWindowsSheet.swift](../../EVA/Compare/CompareWindowsSheet.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Compare/SignalComparison.swift](../../EVA/Compare/SignalComparison.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Compare/WindowComparisonRegistry.swift](../../EVA/Compare/WindowComparisonRegistry.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Core/CleaningVarianceAccount.swift](../../EVA/Core/CleaningVarianceAccount.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Core/Downsampler.swift](../../EVA/Core/Downsampler.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Core/SphericalSpline.swift](../../EVA/Core/SphericalSpline.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/DifferenceWaveView.swift](../../EVA/Epoching/DifferenceWaveView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/EpochBadChannelDetector.swift](../../EVA/Epoching/EpochBadChannelDetector.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/EpochSNR.swift](../../EVA/Epoching/EpochSNR.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/EyeArtifactThresholdConfiguration.swift](../../EVA/Epoching/EyeArtifactThresholdConfiguration.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/EyeArtifactThresholdDetector.swift](../../EVA/Epoching/EyeArtifactThresholdDetector.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/EyeArtifactThresholdSheet.swift](../../EVA/Epoching/EyeArtifactThresholdSheet.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/JointMarkerOverlay.swift](../../EVA/Epoching/JointMarkerOverlay.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/MultiButterflyView.swift](../../EVA/Epoching/MultiButterflyView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/PSAAmplitudeRangeSlider.swift](../../EVA/Epoching/PSAAmplitudeRangeSlider.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/PSAAveraging.swift](../../EVA/Epoching/PSAAveraging.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/PSABadChannelEscalation.swift](../../EVA/Epoching/PSABadChannelEscalation.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/PSAConfigurationComponents.swift](../../EVA/Epoching/PSAConfigurationComponents.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/PSADecisionMatrixNavigation.swift](../../EVA/Epoching/PSADecisionMatrixNavigation.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/PSADecisionMatrixPanel.swift](../../EVA/Epoching/PSADecisionMatrixPanel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/PSAGlobalBadChannelInterpolator.swift](../../EVA/Epoching/PSAGlobalBadChannelInterpolator.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/PSAWaveformDecisionControls.swift](../../EVA/Epoching/PSAWaveformDecisionControls.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/RegexPatternLibrary.swift](../../EVA/Epoching/RegexPatternLibrary.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/SingleTrialAnalysisViewModel.swift](../../EVA/Epoching/SingleTrialAnalysisViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/SingleTrialAnalyzer.swift](../../EVA/Epoching/SingleTrialAnalyzer.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TopoFilmstripView.swift](../../EVA/Epoching/TopoFilmstripView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TrialAlignmentMetrics.swift](../../EVA/Epoching/TrialAlignmentMetrics.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TrialChannelResidualAnalyzer.swift](../../EVA/Epoching/TrialChannelResidualAnalyzer.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TrialDiagnosticsDashboard.swift](../../EVA/Epoching/TrialDiagnosticsDashboard.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TrialDriftStatistics.swift](../../EVA/Epoching/TrialDriftStatistics.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TrialExclusionResolver.swift](../../EVA/Epoching/TrialExclusionResolver.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TrialSelectionAnalyzer.swift](../../EVA/Epoching/TrialSelectionAnalyzer.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TrialSelectionViews.swift](../../EVA/Epoching/TrialSelectionViews.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Epoching/TrialSimilarityAnalyzer.swift](../../EVA/Epoching/TrialSimilarityAnalyzer.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Filtering/EllipticFilterDesign.swift](../../EVA/Filtering/EllipticFilterDesign.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Filtering/Rereferencing.swift](../../EVA/Filtering/Rereferencing.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientAcceleration.swift](../../EVA/Gradient/GradientAcceleration.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientANC.swift](../../EVA/Gradient/GradientANC.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientCleanroomKernels.metal](../../EVA/Gradient/GradientCleanroomKernels.metal) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientCorrectionTypes.swift](../../EVA/Gradient/GradientCorrectionTypes.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientCoverage.swift](../../EVA/Gradient/GradientCoverage.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientDonorSelection.swift](../../EVA/Gradient/GradientDonorSelection.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientEpochLayout.swift](../../EVA/Gradient/GradientEpochLayout.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientFilters.swift](../../EVA/Gradient/GradientFilters.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientOBS.swift](../../EVA/Gradient/GradientOBS.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientRunGrade.swift](../../EVA/Gradient/GradientRunGrade.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/GradientSincResampler.swift](../../EVA/Gradient/GradientSincResampler.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/LocalTemplateKernels.metal](../../EVA/Gradient/LocalTemplateKernels.metal) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/LocalTemplateMetalBackend.swift](../../EVA/Gradient/LocalTemplateMetalBackend.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/MotionParameters.swift](../../EVA/Gradient/MotionParameters.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Gradient/TRSpacing.swift](../../EVA/Gradient/TRSpacing.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Health/ChannelHealthTrainingExport.swift](../../EVA/Health/ChannelHealthTrainingExport.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Health/ChannelHealthViewModel.swift](../../EVA/Health/ChannelHealthViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Health/HealthScoring.swift](../../EVA/Health/HealthScoring.swift) | 4/5 | **4/5** | Initial focused comments | The short functions now distinguish heuristic goodness from probability and state threshold behavior; choosing and interpreting the heuristic cutoffs still needs domain context, so the score stays 4. |
| [EVA/Health/SegmentGoodnessSettings.swift](../../EVA/Health/SegmentGoodnessSettings.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Health/SegmentHealthTrainingExport.swift](../../EVA/Health/SegmentHealthTrainingExport.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Health/SegmentHealthViewModel.swift](../../EVA/Health/SegmentHealthViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Help/MarkdownDocument.swift](../../EVA/Help/MarkdownDocument.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Help/MarkdownView.swift](../../EVA/Help/MarkdownView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Help/ReleaseNotesCatalog.swift](../../EVA/Help/ReleaseNotesCatalog.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Help/ReleaseNotesView.swift](../../EVA/Help/ReleaseNotesView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/ICA/ICAComponentRemoval.swift](../../EVA/ICA/ICAComponentRemoval.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/ICA/ICARunGrade.swift](../../EVA/ICA/ICARunGrade.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/ICA/ICAViewModel.swift](../../EVA/ICA/ICAViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/BDFSignalReader.swift](../../EVA/IO/BDFSignalReader.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/ChannelExportViews.swift](../../EVA/IO/ChannelExportViews.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/DatasetInfoSheet.swift](../../EVA/IO/DatasetInfoSheet.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/FigureExport.swift](../../EVA/IO/FigureExport.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/FigureExportBasket.swift](../../EVA/IO/FigureExportBasket.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/FigureExportBasketView.swift](../../EVA/IO/FigureExportBasketView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/MFFExportWriter.swift](../../EVA/IO/MFFExportWriter.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/PhysioImportViews.swift](../../EVA/IO/PhysioImportViews.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/PhysioPaneViews.swift](../../EVA/IO/PhysioPaneViews.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/IO/PhysioTextImporter.swift](../../EVA/IO/PhysioTextImporter.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Markers/UserMarker.swift](../../EVA/Markers/UserMarker.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/BatchController.swift](../../EVA/Pipeline/BatchController.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/BatchDecisionPolicy.swift](../../EVA/Pipeline/BatchDecisionPolicy.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/BatchPrefixPlanner.swift](../../EVA/Pipeline/BatchPrefixPlanner.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/BatchPreflight.swift](../../EVA/Pipeline/BatchPreflight.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ChannelDecisionReplaySheet.swift](../../EVA/Pipeline/ChannelDecisionReplaySheet.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ChannelDecisionSteps.swift](../../EVA/Pipeline/ChannelDecisionSteps.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/CleaningVarianceLedger.swift](../../EVA/Pipeline/CleaningVarianceLedger.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/EVAHistory.swift](../../EVA/Pipeline/EVAHistory.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/EVAProcessLog.swift](../../EVA/Pipeline/EVAProcessLog.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/HeadlessBatchProcessor.swift](../../EVA/Pipeline/HeadlessBatchProcessor.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/HistoryStepSummary.swift](../../EVA/Pipeline/HistoryStepSummary.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/LatestOnlyRunner.swift](../../EVA/Pipeline/LatestOnlyRunner.swift) | 4/5 | **4/5** | Initial focused comments | Publication ownership versus cancellation is now especially clear, with an overlapping-run example; generic async closures and actor reentrancy still require some Swift familiarity. |
| [EVA/Pipeline/OperationProgress.swift](../../EVA/Pipeline/OperationProgress.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/OperationProgressCenter.swift](../../EVA/Pipeline/OperationProgressCenter.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/PayloadConsistency.swift](../../EVA/Pipeline/PayloadConsistency.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/PipelineInvalidation.swift](../../EVA/Pipeline/PipelineInvalidation.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/PipelineSnapshot.swift](../../EVA/Pipeline/PipelineSnapshot.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/PipelineStageToggles.swift](../../EVA/Pipeline/PipelineStageToggles.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ProcessingAuditLog.swift](../../EVA/Pipeline/ProcessingAuditLog.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ProcessingDefaults.swift](../../EVA/Pipeline/ProcessingDefaults.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ProcessingQueue.swift](../../EVA/Pipeline/ProcessingQueue.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ProgressBridge.swift](../../EVA/Pipeline/ProgressBridge.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/RecordingHistoryModel.swift](../../EVA/Pipeline/RecordingHistoryModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ReplayCompatibility.swift](../../EVA/Pipeline/ReplayCompatibility.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ReplayConfigSheet.swift](../../EVA/Pipeline/ReplayConfigSheet.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ReplayController.swift](../../EVA/Pipeline/ReplayController.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/ReplaySettingsRestore.swift](../../EVA/Pipeline/ReplaySettingsRestore.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Pipeline/StepQuality.swift](../../EVA/Pipeline/StepQuality.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/ComplexCoefficientProvider.swift](../../EVA/Rhythmicity/ComplexCoefficientProvider.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/DetectedRhythmicityBandSet.swift](../../EVA/Rhythmicity/DetectedRhythmicityBandSet.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicBurstExport.swift](../../EVA/Rhythmicity/RhythmicBurstExport.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityDataSelection.swift](../../EVA/Rhythmicity/RhythmicityDataSelection.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityHelp.swift](../../EVA/Rhythmicity/RhythmicityHelp.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityKernels.metal](../../EVA/Rhythmicity/RhythmicityKernels.metal) | 4/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/RhythmicityPreset.swift](../../EVA/Rhythmicity/RhythmicityPreset.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Rhythmicity/WTPLModels.swift](../../EVA/Rhythmicity/WTPLModels.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Simulation/SimulatorController.swift](../../EVA/Simulation/SimulatorController.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Simulation/SimulatorRunner.swift](../../EVA/Simulation/SimulatorRunner.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Simulation/SimulatorScenarioLibrary.swift](../../EVA/Simulation/SimulatorScenarioLibrary.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/ComplexMorlet.swift](../../EVA/TimeFrequency/ComplexMorlet.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/DPSS.swift](../../EVA/TimeFrequency/DPSS.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/Multitaper.swift](../../EVA/TimeFrequency/Multitaper.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyEngine.swift](../../EVA/TimeFrequency/TimeFrequencyEngine.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyMetalBackend.swift](../../EVA/TimeFrequency/TimeFrequencyMetalBackend.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyModels.swift](../../EVA/TimeFrequency/TimeFrequencyModels.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/TimeFrequency/TimeFrequencyTrials.swift](../../EVA/TimeFrequency/TimeFrequencyTrials.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Trials/ClusterSpatialAdjacency.swift](../../EVA/Trials/ClusterSpatialAdjacency.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Trials/ClusterStatisticsDistributions.swift](../../EVA/Trials/ClusterStatisticsDistributions.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Trials/CWTRidgePipeline.swift](../../EVA/Trials/CWTRidgePipeline.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Trials/NonlinearAligner.swift](../../EVA/Trials/NonlinearAligner.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/EventsPanelView.swift](../../EVA/Waveform/EventsPanelView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/GFPPlot.swift](../../EVA/Waveform/GFPPlot.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/HistoryRailView.swift](../../EVA/Waveform/HistoryRailView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/HistoryTransportCommands.swift](../../EVA/Waveform/HistoryTransportCommands.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/PhysioPaneView.swift](../../EVA/Waveform/PhysioPaneView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/ProcessingStatusPopover.swift](../../EVA/Waveform/ProcessingStatusPopover.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/StatusLogView.swift](../../EVA/Waveform/StatusLogView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/TopomapPanelView.swift](../../EVA/Waveform/TopomapPanelView.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformAxisViews.swift](../../EVA/Waveform/WaveformAxisViews.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformChannelRows.swift](../../EVA/Waveform/WaveformChannelRows.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformDensityLayout.swift](../../EVA/Waveform/WaveformDensityLayout.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformOverlays.swift](../../EVA/Waveform/WaveformOverlays.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformScaleUnits.swift](../../EVA/Waveform/WaveformScaleUnits.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformSourceFit.swift](../../EVA/Waveform/WaveformSourceFit.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Waveform/WaveformUIModels.swift](../../EVA/Waveform/WaveformUIModels.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Wavelet/ContinuousWaveletTransform.swift](../../EVA/Wavelet/ContinuousWaveletTransform.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Wavelet/CWTRidgeDetector.swift](../../EVA/Wavelet/CWTRidgeDetector.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Wavelet/MatchedWaveletTemplate.swift](../../EVA/Wavelet/MatchedWaveletTemplate.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WaveletArtifactExplorerViewModel.swift](../../EVA/Wavelet/WaveletArtifactExplorerViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WaveletDenoiser.swift](../../EVA/Wavelet/WaveletDenoiser.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WaveletKernels.metal](../../EVA/Wavelet/WaveletKernels.metal) | 4/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WaveletReductionViewModel.swift](../../EVA/Wavelet/WaveletReductionViewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Wavelet/WaveletScalogram.swift](../../EVA/Wavelet/WaveletScalogram.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Channels/BVEFMontage.swift](../../EVACore/Channels/BVEFMontage.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Channels/ElectrodeGeometry.swift](../../EVACore/Channels/ElectrodeGeometry.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Channels/ElectrodeLocationFile.swift](../../EVACore/Channels/ElectrodeLocationFile.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Channels/ElectrodePositions.swift](../../EVACore/Channels/ElectrodePositions.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Channels/SensorLayout.swift](../../EVACore/Channels/SensorLayout.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Channels/StandardMontage.swift](../../EVACore/Channels/StandardMontage.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Channels/StandardMontageData.swift](../../EVACore/Channels/StandardMontageData.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Core/AccelerateCompat.swift](../../EVACore/Core/AccelerateCompat.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Core/Forward/BEMForwardModel.swift](../../EVACore/Core/Forward/BEMForwardModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Core/Forward/BEMGeometry.swift](../../EVACore/Core/Forward/BEMGeometry.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Core/Forward/BEMSolution.swift](../../EVACore/Core/Forward/BEMSolution.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Core/Forward/EllipsoidalForwardModel.swift](../../EVACore/Core/Forward/EllipsoidalForwardModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Core/Forward/ForwardTypes.swift](../../EVACore/Core/Forward/ForwardTypes.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Core/SeededGenerator.swift](../../EVACore/Core/SeededGenerator.swift) | 4/5 | **4/5** | Initial focused comments | Wrapping arithmetic and fixed-sequence constraints are now explained; the bit-mixing constants and generator construction still require specialist context for deeper understanding. |
| [EVACore/Epoching/EpochModel.swift](../../EVACore/Epoching/EpochModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Geometry/HeadTransform.swift](../../EVACore/Geometry/HeadTransform.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Geometry/TriangleMesh.swift](../../EVACore/Geometry/TriangleMesh.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Geometry/TriangleMeshIntersection.swift](../../EVACore/Geometry/TriangleMeshIntersection.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Imaging/ScalpFromVolume.swift](../../EVACore/Imaging/ScalpFromVolume.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Imaging/VolumeMorphology.swift](../../EVACore/Imaging/VolumeMorphology.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/EDFAnnotationDecoder.swift](../../EVACore/IO/EDFAnnotationDecoder.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/EGISensorXMLParser.swift](../../EVACore/IO/EGISensorXMLParser.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/FIF/FIFDocument.swift](../../EVACore/IO/FIF/FIFDocument.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/FIF/FIFFile.swift](../../EVACore/IO/FIF/FIFFile.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/FIF/FIFInterop.swift](../../EVACore/IO/FIF/FIFInterop.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/FIF/FIFMeasurementInfo.swift](../../EVACore/IO/FIF/FIFMeasurementInfo.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/FIF/FIFRecording.swift](../../EVACore/IO/FIF/FIFRecording.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/GIFTI/GIFTICompanionSurfaceResolver.swift](../../EVACore/IO/GIFTI/GIFTICompanionSurfaceResolver.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/MFFFileType.swift](../../EVACore/IO/MFFFileType.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/MFFWriter.swift](../../EVACore/IO/MFFWriter.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/NIfTI/NIfTIByteSource.swift](../../EVACore/IO/NIfTI/NIfTIByteSource.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/NIfTI/NIfTIScalarDecoder.swift](../../EVACore/IO/NIfTI/NIfTIScalarDecoder.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/NIfTI/NIfTIVolume.swift](../../EVACore/IO/NIfTI/NIfTIVolume.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/IO/OpenMEEG/OpenMEEGGeometry.swift](../../EVACore/IO/OpenMEEG/OpenMEEGGeometry.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Pipeline/EVAProcessingScript.swift](../../EVACore/Pipeline/EVAProcessingScript.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Registration/SurfaceRegistration.swift](../../EVACore/Registration/SurfaceRegistration.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/BCGArtifactModel.swift](../../EVACore/Simulation/BCGArtifactModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/BCGGeneratorModel.swift](../../EVACore/Simulation/BCGGeneratorModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/BrainTransientModel.swift](../../EVACore/Simulation/BrainTransientModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/ChannelDefectModel.swift](../../EVACore/Simulation/ChannelDefectModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/EEGGenerator.swift](../../EVACore/Simulation/EEGGenerator.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/ERPExperimentOptions.swift](../../EVACore/Simulation/ERPExperimentOptions.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/ERPTruth.swift](../../EVACore/Simulation/ERPTruth.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/GradientArtifactModel.swift](../../EVACore/Simulation/GradientArtifactModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/GroupSimulation.swift](../../EVACore/Simulation/GroupSimulation.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/ImpedanceModel.swift](../../EVACore/Simulation/ImpedanceModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/Montage.swift](../../EVACore/Simulation/Montage.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/NonGaussianSourceModel.swift](../../EVACore/Simulation/NonGaussianSourceModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/OcularArtifactModel.swift](../../EVACore/Simulation/OcularArtifactModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/OcularDipoleModel.swift](../../EVACore/Simulation/OcularDipoleModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SignalSynthesis.swift](../../EVACore/Simulation/SignalSynthesis.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SimulationConfig.swift](../../EVACore/Simulation/SimulationConfig.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SimulationError.swift](../../EVACore/Simulation/SimulationError.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SimulationForwardDomain.swift](../../EVACore/Simulation/SimulationForwardDomain.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SimulationScenario.swift](../../EVACore/Simulation/SimulationScenario.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SourceSimulatorArtifacts.swift](../../EVACore/Simulation/SourceSimulatorArtifacts.swift) | 4/5 | — | No changes in these passes | — |
| [EVACore/Simulation/SourceSimulatorNoise.swift](../../EVACore/Simulation/SourceSimulatorNoise.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/CIFTI/CIFTIMatrixRenderer.swift](../../EVAPreviewKit/CIFTI/CIFTIMatrixRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/CIFTI/CIFTIPreviewModel.swift](../../EVAPreviewKit/CIFTI/CIFTIPreviewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/CIFTI/CIFTIPreviewView.swift](../../EVAPreviewKit/CIFTI/CIFTIPreviewView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/CIFTI/CIFTIThumbnailRenderer.swift](../../EVAPreviewKit/CIFTI/CIFTIThumbnailRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/DICOM/DICOMImageRenderer.swift](../../EVAPreviewKit/DICOM/DICOMImageRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/DICOM/DICOMPreviewModel.swift](../../EVAPreviewKit/DICOM/DICOMPreviewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/DICOM/DICOMPreviewView.swift](../../EVAPreviewKit/DICOM/DICOMPreviewView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/DICOM/DICOMThumbnailRenderer.swift](../../EVAPreviewKit/DICOM/DICOMThumbnailRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/EVAPreviewFormat.swift](../../EVAPreviewKit/EVAPreviewFormat.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/EVAQuickLookPreferences.swift](../../EVAPreviewKit/EVAQuickLookPreferences.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/FIF/FIFPreviewView.swift](../../EVAPreviewKit/FIF/FIFPreviewView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/FIF/FIFQuickLookSummary.swift](../../EVAPreviewKit/FIF/FIFQuickLookSummary.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/FIF/FIFThumbnailRenderer.swift](../../EVAPreviewKit/FIF/FIFThumbnailRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/GIFTI/GIFTIPreviewView.swift](../../EVAPreviewKit/GIFTI/GIFTIPreviewView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/GIFTI/GIFTIThumbnailRenderer.swift](../../EVAPreviewKit/GIFTI/GIFTIThumbnailRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MFF/MFFPreviewView.swift](../../EVAPreviewKit/MFF/MFFPreviewView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MFF/MFFQuickLookSummary.swift](../../EVAPreviewKit/MFF/MFFQuickLookSummary.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MFF/MFFThumbnailRenderer.swift](../../EVAPreviewKit/MFF/MFFThumbnailRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MGH/MGHHeader.swift](../../EVAPreviewKit/MGH/MGHHeader.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MGH/MGHPreviewModel.swift](../../EVAPreviewKit/MGH/MGHPreviewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MGH/MGHPreviewView.swift](../../EVAPreviewKit/MGH/MGHPreviewView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/MGH/MGHThumbnailRenderer.swift](../../EVAPreviewKit/MGH/MGHThumbnailRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/NIfTI/NIfTIPreviewModel.swift](../../EVAPreviewKit/NIfTI/NIfTIPreviewModel.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/NIfTI/NIfTIPreviewView.swift](../../EVAPreviewKit/NIfTI/NIfTIPreviewView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/NIfTI/NIfTISliceRenderer.swift](../../EVAPreviewKit/NIfTI/NIfTISliceRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAPreviewKit/NIfTI/NIfTIThumbnailRenderer.swift](../../EVAPreviewKit/NIfTI/NIfTIThumbnailRenderer.swift) | 4/5 | — | No changes in these passes | — |
| [EVAQuickLook/PreviewViewController.swift](../../EVAQuickLook/PreviewViewController.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/App/EVAResolveApp.swift](../../EVAResolve/App/EVAResolveApp.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/App/EVAResolvePreferencesView.swift](../../EVAResolve/App/EVAResolvePreferencesView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/HeadModel/CoregistrationSceneView.swift](../../EVAResolve/HeadModel/CoregistrationSceneView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/HeadModel/HeadModelController.swift](../../EVAResolve/HeadModel/HeadModelController.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/HeadModel/HeadModelDocument.swift](../../EVAResolve/HeadModel/HeadModelDocument.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/HeadModel/HeadModelWindowView.swift](../../EVAResolve/HeadModel/HeadModelWindowView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/HeadModel/MRISliceView.swift](../../EVAResolve/HeadModel/MRISliceView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/FitWaveformPanels.swift](../../EVAResolve/Simulator/FitWaveformPanels.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/HeadProjectionView.swift](../../EVAResolve/Simulator/HeadProjectionView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/HeadSilhouette.swift](../../EVAResolve/Simulator/HeadSilhouette.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/PendingSourceFit.swift](../../EVAResolve/Simulator/PendingSourceFit.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/ScalpFieldView.swift](../../EVAResolve/Simulator/ScalpFieldView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/SourceButterflyView.swift](../../EVAResolve/Simulator/SourceButterflyView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/SourceFitImporter.swift](../../EVAResolve/Simulator/SourceFitImporter.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/SourceFitModeView.swift](../../EVAResolve/Simulator/SourceFitModeView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/SourceSimulatorWindowView.swift](../../EVAResolve/Simulator/SourceSimulatorWindowView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolve/Simulator/SourceTimelineView.swift](../../EVAResolve/Simulator/SourceTimelineView.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolveTests/HeadModelControllerTests.swift](../../EVAResolveTests/HeadModelControllerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVAResolveTests/SourceFitImporterTests.swift](../../EVAResolveTests/SourceFitImporterTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Analysis/EEGAnalysisEngineTests.swift](../../EVATests/Analysis/EEGAnalysisEngineTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/App/EventAnchorCatalogTests.swift](../../EVATests/App/EventAnchorCatalogTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/App/EventAnchorSettingsTests.swift](../../EVATests/App/EventAnchorSettingsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/App/TemporaryFileSweeperTests.swift](../../EVATests/App/TemporaryFileSweeperTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/App/UpdateCheckerTests.swift](../../EVATests/App/UpdateCheckerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/App/WaveformAppearancePreferencesTests.swift](../../EVATests/App/WaveformAppearancePreferencesTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ArtifactCleanRunGradeMeasurementTests.swift](../../EVATests/Artifacts/ArtifactCleanRunGradeMeasurementTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ArtifactCleanRunGradeTests.swift](../../EVATests/Artifacts/ArtifactCleanRunGradeTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ArtifactDetectorEventMergerTests.swift](../../EVATests/Artifacts/ArtifactDetectorEventMergerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ArtifactReplayPayloadTests.swift](../../EVATests/Artifacts/ArtifactReplayPayloadTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ArtifactReviewWorkspaceTests.swift](../../EVATests/Artifacts/ArtifactReviewWorkspaceTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ArtifactTemplateDetectorTests.swift](../../EVATests/Artifacts/ArtifactTemplateDetectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/CorneoRetinalCorrectionTests.swift](../../EVATests/Artifacts/CorneoRetinalCorrectionTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/MAACPreliminaryBlinkDetectorTests.swift](../../EVATests/Artifacts/MAACPreliminaryBlinkDetectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/MovementPCACorrectionTests.swift](../../EVATests/Artifacts/MovementPCACorrectionTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/MuscleBSSCCACorrectionTests.swift](../../EVATests/Artifacts/MuscleBSSCCACorrectionTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/SaccadicSpikeCorrectionTests.swift](../../EVATests/Artifacts/SaccadicSpikeCorrectionTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/SourceInformedOperatorTests.swift](../../EVATests/Artifacts/SourceInformedOperatorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Artifacts/ThresholdOcularReviewTests.swift](../../EVATests/Artifacts/ThresholdOcularReviewTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Cardiac/BCGDetectionViewModelTests.swift](../../EVATests/Cardiac/BCGDetectionViewModelTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Cardiac/BCGDetectorTests.swift](../../EVATests/Cardiac/BCGDetectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Cardiac/CWLCorrectorTests.swift](../../EVATests/Cardiac/CWLCorrectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Cardiac/PCASRunGradeTests.swift](../../EVATests/Cardiac/PCASRunGradeTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Cardiac/RWaveDetectorTests.swift](../../EVATests/Cardiac/RWaveDetectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/BVEFMontageTests.swift](../../EVATests/Channels/BVEFMontageTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/ChannelInterpolationComposerTests.swift](../../EVATests/Channels/ChannelInterpolationComposerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/ChannelSetStoreTests.swift](../../EVATests/Channels/ChannelSetStoreTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/DisplayChannelsResolverTests.swift](../../EVATests/Channels/DisplayChannelsResolverTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/ElectrodeGeometryTests.swift](../../EVATests/Channels/ElectrodeGeometryTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/ElectrodePositionsTests.swift](../../EVATests/Channels/ElectrodePositionsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/MFFLocationImportTests.swift](../../EVATests/Channels/MFFLocationImportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/SensorLayoutTests.swift](../../EVATests/Channels/SensorLayoutTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Channels/TopomapFieldRasterTests.swift](../../EVATests/Channels/TopomapFieldRasterTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Compare/FilterEdgeExport.swift](../../EVATests/Compare/FilterEdgeExport.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Compare/FullPipelineERPExport.swift](../../EVATests/Compare/FullPipelineERPExport.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Compare/MNERealFileReferenceTests.swift](../../EVATests/Compare/MNERealFileReferenceTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Compare/MNEReferenceTests.swift](../../EVATests/Compare/MNEReferenceTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Compare/SignalComparisonTests.swift](../../EVATests/Compare/SignalComparisonTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Compare/WindowComparisonRegistryTests.swift](../../EVATests/Compare/WindowComparisonRegistryTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/CleaningVarianceAccountTests.swift](../../EVATests/Core/CleaningVarianceAccountTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/DownsamplerTests.swift](../../EVATests/Core/DownsamplerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/DSPTests.swift](../../EVATests/Core/DSPTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/ForwardOperatorTests.swift](../../EVATests/Core/ForwardOperatorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/HeadTransformTests.swift](../../EVATests/Core/HeadTransformTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/LinearAlgebraTests.swift](../../EVATests/Core/LinearAlgebraTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/SignalStatisticsTests.swift](../../EVATests/Core/SignalStatisticsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/SphericalForwardModelTests.swift](../../EVATests/Core/SphericalForwardModelTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/SphericalSplineTests.swift](../../EVATests/Core/SphericalSplineTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/SurfaceRegistrationTests.swift](../../EVATests/Core/SurfaceRegistrationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/TriangleMeshTests.swift](../../EVATests/Core/TriangleMeshTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Core/VolumeMorphologyTests.swift](../../EVATests/Core/VolumeMorphologyTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/EpochingViewModelTests.swift](../../EVATests/Epoching/EpochingViewModelTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/EpochSNRDeterminismTests.swift](../../EVATests/Epoching/EpochSNRDeterminismTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/EventTrackIndexTests.swift](../../EVATests/Epoching/EventTrackIndexTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/EyeArtifactThresholdDetectorTests.swift](../../EVATests/Epoching/EyeArtifactThresholdDetectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/PSAAmplitudeCutoffTests.swift](../../EVATests/Epoching/PSAAmplitudeCutoffTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/PSACategoryRejectionTests.swift](../../EVATests/Epoching/PSACategoryRejectionTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/PSAConfigurationTests.swift](../../EVATests/Epoching/PSAConfigurationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/PSADecisionMatrixArtifactStatusTests.swift](../../EVATests/Epoching/PSADecisionMatrixArtifactStatusTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/PSADecisionMatrixLayoutTests.swift](../../EVATests/Epoching/PSADecisionMatrixLayoutTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/SingleTrialAnalyzerTests.swift](../../EVATests/Epoching/SingleTrialAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/TrialAlignmentMetricsTests.swift](../../EVATests/Epoching/TrialAlignmentMetricsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/TrialChannelResidualAnalyzerTests.swift](../../EVATests/Epoching/TrialChannelResidualAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/TrialDriftStatisticsTests.swift](../../EVATests/Epoching/TrialDriftStatisticsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/TrialExclusionApplicationTests.swift](../../EVATests/Epoching/TrialExclusionApplicationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/TrialSelectionAnalyzerTests.swift](../../EVATests/Epoching/TrialSelectionAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/TrialSelectionReviewTests.swift](../../EVATests/Epoching/TrialSelectionReviewTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Epoching/TrialSimilarityAnalyzerTests.swift](../../EVATests/Epoching/TrialSimilarityAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Filtering/EEGSignalFilterTests.swift](../../EVATests/Filtering/EEGSignalFilterTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Filtering/EllipticFilterTests.swift](../../EVATests/Filtering/EllipticFilterTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Filtering/FilterViewModelTests.swift](../../EVATests/Filtering/FilterViewModelTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Filtering/FIRDesignRuleTests.swift](../../EVATests/Filtering/FIRDesignRuleTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Filtering/FIRFilterTests.swift](../../EVATests/Filtering/FIRFilterTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Fixtures.swift](../../EVATests/Fixtures.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Fixtures/generate_tf_reference.py](../../EVATests/Fixtures/generate_tf_reference.py) | 4/5 | — | No changes in these passes | — |
| [EVATests/Fixtures/SimulationTruthFixture.swift](../../EVATests/Fixtures/SimulationTruthFixture.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientAASTests.swift](../../EVATests/Gradient/GradientAASTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientANCTests.swift](../../EVATests/Gradient/GradientANCTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientBackendParityTests.swift](../../EVATests/Gradient/GradientBackendParityTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientBrainSafetyRegressionTests.swift](../../EVATests/Gradient/GradientBrainSafetyRegressionTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientCorrectorStagesTests.swift](../../EVATests/Gradient/GradientCorrectorStagesTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientCoverageTests.swift](../../EVATests/Gradient/GradientCoverageTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientDonorSelectionTests.swift](../../EVATests/Gradient/GradientDonorSelectionTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientEpochAlignerTests.swift](../../EVATests/Gradient/GradientEpochAlignerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientEpochLayoutTests.swift](../../EVATests/Gradient/GradientEpochLayoutTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientFiltersTests.swift](../../EVATests/Gradient/GradientFiltersTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientOBSTests.swift](../../EVATests/Gradient/GradientOBSTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientRunGradeTests.swift](../../EVATests/Gradient/GradientRunGradeTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientSincResamplerTests.swift](../../EVATests/Gradient/GradientSincResamplerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/GradientTimingCheckTests.swift](../../EVATests/Gradient/GradientTimingCheckTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/LocalTemplateArtifactCompatibilityTests.swift](../../EVATests/Gradient/LocalTemplateArtifactCompatibilityTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/LocalTemplateArtifactCorrectorTests.swift](../../EVATests/Gradient/LocalTemplateArtifactCorrectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/LocalTemplateBackendParityTests.swift](../../EVATests/Gradient/LocalTemplateBackendParityTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/MotionParametersTests.swift](../../EVATests/Gradient/MotionParametersTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Gradient/TRSpacingTests.swift](../../EVATests/Gradient/TRSpacingTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Health/ChannelHealthAnalyzerTests.swift](../../EVATests/Health/ChannelHealthAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Health/ChannelHealthViewModelTests.swift](../../EVATests/Health/ChannelHealthViewModelTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Health/ChannelRelationshipAnalyzerTests.swift](../../EVATests/Health/ChannelRelationshipAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Health/HealthScoringTests.swift](../../EVATests/Health/HealthScoringTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Health/SegmentHealthAnalyzerTests.swift](../../EVATests/Health/SegmentHealthAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Help/MarkdownDocumentTests.swift](../../EVATests/Help/MarkdownDocumentTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Help/ReleaseNotesCatalogTests.swift](../../EVATests/Help/ReleaseNotesCatalogTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/BCGComponentLabellerTests.swift](../../EVATests/ICA/BCGComponentLabellerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICAArtifactDetectorTests.swift](../../EVATests/ICA/ICAArtifactDetectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICAComponentAutoLabelerTests.swift](../../EVATests/ICA/ICAComponentAutoLabelerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICAComponentLabellerBenchmarkTests.swift](../../EVATests/ICA/ICAComponentLabellerBenchmarkTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICAComponentRemovalTests.swift](../../EVATests/ICA/ICAComponentRemovalTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICAPicardOReferenceCrossCheckTests.swift](../../EVATests/ICA/ICAPicardOReferenceCrossCheckTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICAReplayPayloadTests.swift](../../EVATests/ICA/ICAReplayPayloadTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICARunGradeMeasurementTests.swift](../../EVATests/ICA/ICARunGradeMeasurementTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICARunGradeTests.swift](../../EVATests/ICA/ICARunGradeTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/ICA/ICLabelClassifierTests.swift](../../EVATests/ICA/ICLabelClassifierTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/BEMImportTests.swift](../../EVATests/IO/BEMImportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/BESAImportTests.swift](../../EVATests/IO/BESAImportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/BrainVisionImportTests.swift](../../EVATests/IO/BrainVisionImportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/EDFImportTests.swift](../../EVATests/IO/EDFImportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/EGISensorXMLParserTests.swift](../../EVATests/IO/EGISensorXMLParserTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/EventTimeAnchorTests.swift](../../EVATests/IO/EventTimeAnchorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/FIFImportTests.swift](../../EVATests/IO/FIFImportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/FIFInteropTests.swift](../../EVATests/IO/FIFInteropTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/FIFPreviewTests.swift](../../EVATests/IO/FIFPreviewTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/FIFRecordingTests.swift](../../EVATests/IO/FIFRecordingTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/FigureExportTests.swift](../../EVATests/IO/FigureExportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/ForwardFixtureTests.swift](../../EVATests/IO/ForwardFixtureTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/GrandAverageReaderTests.swift](../../EVATests/IO/GrandAverageReaderTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MFFAcquisitionGapTests.swift](../../EVATests/IO/MFFAcquisitionGapTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MFFAveragedRoundTripTests.swift](../../EVATests/IO/MFFAveragedRoundTripTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MFFEventPrecisionTests.swift](../../EVATests/IO/MFFEventPrecisionTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MFFExportWriterTests.swift](../../EVATests/IO/MFFExportWriterTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MFFFileTypeTests.swift](../../EVATests/IO/MFFFileTypeTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MFFPNSReaderTests.swift](../../EVATests/IO/MFFPNSReaderTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MFFQuickLookSummaryTests.swift](../../EVATests/IO/MFFQuickLookSummaryTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MFFSignalSplitterTests.swift](../../EVATests/IO/MFFSignalSplitterTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/MGHQuickLookReaderTests.swift](../../EVATests/IO/MGHQuickLookReaderTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/NIfTIVolumeTests.swift](../../EVATests/IO/NIfTIVolumeTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/PersystImportTests.swift](../../EVATests/IO/PersystImportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/IO/PhysioTextImporterTests.swift](../../EVATests/IO/PhysioTextImporterTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/BatchCheckpointTests.swift](../../EVATests/Pipeline/BatchCheckpointTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/BatchControllerTests.swift](../../EVATests/Pipeline/BatchControllerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/BatchPrefixPlannerTests.swift](../../EVATests/Pipeline/BatchPrefixPlannerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ChannelDecisionStepsTests.swift](../../EVATests/Pipeline/ChannelDecisionStepsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/CleaningVarianceLedgerTests.swift](../../EVATests/Pipeline/CleaningVarianceLedgerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/EVAHistoryTests.swift](../../EVATests/Pipeline/EVAHistoryTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/EVAProcessingScriptIOTests.swift](../../EVATests/Pipeline/EVAProcessingScriptIOTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/EVAProcessingScriptXMLTests.swift](../../EVATests/Pipeline/EVAProcessingScriptXMLTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/FilterReplayTests.swift](../../EVATests/Pipeline/FilterReplayTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/GradientReplayTests.swift](../../EVATests/Pipeline/GradientReplayTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/HeadlessBatchProcessorTests.swift](../../EVATests/Pipeline/HeadlessBatchProcessorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/HistoryRailDerivationTests.swift](../../EVATests/Pipeline/HistoryRailDerivationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/HistoryReDerivationSourceTests.swift](../../EVATests/Pipeline/HistoryReDerivationSourceTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/HistorySurfaceTests.swift](../../EVATests/Pipeline/HistorySurfaceTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/InvalidationAuthorityTests.swift](../../EVATests/Pipeline/InvalidationAuthorityTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/LatestOnlyRunnerTests.swift](../../EVATests/Pipeline/LatestOnlyRunnerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/MethodComparison/ComparisonMatrix.swift](../../EVATests/Pipeline/MethodComparison/ComparisonMatrix.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/MethodComparison/MethodComparisonTests.swift](../../EVATests/Pipeline/MethodComparison/MethodComparisonTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/OperationProgressTests.swift](../../EVATests/Pipeline/OperationProgressTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ParameterSerializationAuditTests.swift](../../EVATests/Pipeline/ParameterSerializationAuditTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/PipelineInvalidationTests.swift](../../EVATests/Pipeline/PipelineInvalidationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/PipelineSnapshotTests.swift](../../EVATests/Pipeline/PipelineSnapshotTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/PipelineStageTogglesTests.swift](../../EVATests/Pipeline/PipelineStageTogglesTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ProcessingCoreTests.swift](../../EVATests/Pipeline/ProcessingCoreTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ProcessingQueueTests.swift](../../EVATests/Pipeline/ProcessingQueueTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ProcessingStoreTests.swift](../../EVATests/Pipeline/ProcessingStoreTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/RecordingHistoryForkTests.swift](../../EVATests/Pipeline/RecordingHistoryForkTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/RecordingHistoryOnDiskPrefixTests.swift](../../EVATests/Pipeline/RecordingHistoryOnDiskPrefixTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ReplayCompatibilityTests.swift](../../EVATests/Pipeline/ReplayCompatibilityTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ReplayControllerTests.swift](../../EVATests/Pipeline/ReplayControllerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ReplaySettingsRestoreTests.swift](../../EVATests/Pipeline/ReplaySettingsRestoreTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/SnapshotPolicyTests.swift](../../EVATests/Pipeline/SnapshotPolicyTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/StageCommitTests.swift](../../EVATests/Pipeline/StageCommitTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ThresholdAndPSAReplayTests.swift](../../EVATests/Pipeline/ThresholdAndPSAReplayTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Pipeline/ThresholdConfigCommitTests.swift](../../EVATests/Pipeline/ThresholdConfigCommitTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/ABBAEngineTests.swift](../../EVATests/Rhythmicity/ABBAEngineTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/AperiodicSpectrumEstimatorTests.swift](../../EVATests/Rhythmicity/AperiodicSpectrumEstimatorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/ComplexCoefficientProviderTests.swift](../../EVATests/Rhythmicity/ComplexCoefficientProviderTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/IAAFTSurrogateGeneratorTests.swift](../../EVATests/Rhythmicity/IAAFTSurrogateGeneratorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/LAVIEngineTests.swift](../../EVATests/Rhythmicity/LAVIEngineTests.swift) | 3/5 | **4/5** | Initial focused comments | The pinned independent oracle, coupled fixture settings, and Double-only tolerance are explained; descriptive test names and simple signal cases make remaining scientific lookups localized. |
| [EVATests/Rhythmicity/RhythmicBurstDetectorTests.swift](../../EVATests/Rhythmicity/RhythmicBurstDetectorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/RhythmicityExportTests.swift](../../EVATests/Rhythmicity/RhythmicityExportTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/RhythmicityMFFIntegrationTests.swift](../../EVATests/Rhythmicity/RhythmicityMFFIntegrationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/RhythmicityMilestone0Tests.swift](../../EVATests/Rhythmicity/RhythmicityMilestone0Tests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/RhythmicityTimeFrequencyIntegrationTests.swift](../../EVATests/Rhythmicity/RhythmicityTimeFrequencyIntegrationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/WTPLEngineTests.swift](../../EVATests/Rhythmicity/WTPLEngineTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Rhythmicity/WTPLIntegrationTests.swift](../../EVATests/Rhythmicity/WTPLIntegrationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Simulation/ERPExperimentTests.swift](../../EVATests/Simulation/ERPExperimentTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Simulation/ERPGroupAndOptionsTests.swift](../../EVATests/Simulation/ERPGroupAndOptionsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Simulation/EVASimulateSelfTestTests.swift](../../EVATests/Simulation/EVASimulateSelfTestTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Simulation/GradientTemplateBandLimitTests.swift](../../EVATests/Simulation/GradientTemplateBandLimitTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Simulation/SimulationSweepTests.swift](../../EVATests/Simulation/SimulationSweepTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Simulation/SimulatorRunnerTests.swift](../../EVATests/Simulation/SimulatorRunnerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/SyntheticSignal.swift](../../EVATests/SyntheticSignal.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/TimeFrequency/TimeFrequencyEngineTests.swift](../../EVATests/TimeFrequency/TimeFrequencyEngineTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/ClusterFormationTests.swift](../../EVATests/Trials/ClusterFormationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/ClusterPermutationAnalyzerTests.swift](../../EVATests/Trials/ClusterPermutationAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/ClusterPermutationFAnalyzerTests.swift](../../EVATests/Trials/ClusterPermutationFAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/ClusterRepeatedMeasuresTests.swift](../../EVATests/Trials/ClusterRepeatedMeasuresTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/ClusterSpatialAdjacencyTests.swift](../../EVATests/Trials/ClusterSpatialAdjacencyTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/ClusterStatisticsDistributionsTests.swift](../../EVATests/Trials/ClusterStatisticsDistributionsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/CWTRidgePipelineTests.swift](../../EVATests/Trials/CWTRidgePipelineTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/RIDEAnalyzerTests.swift](../../EVATests/Trials/RIDEAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Trials/WoodyAlignmentAnalyzerTests.swift](../../EVATests/Trials/WoodyAlignmentAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Waveform/EpochedOverlayEventMapperTests.swift](../../EVATests/Waveform/EpochedOverlayEventMapperTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Waveform/HistoryRailRenderTests.swift](../../EVATests/Waveform/HistoryRailRenderTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Waveform/WaveformDensityLayoutTests.swift](../../EVATests/Waveform/WaveformDensityLayoutTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Waveform/WaveformDensityScrollingTests.swift](../../EVATests/Waveform/WaveformDensityScrollingTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Waveform/WaveformScaleUnitsTests.swift](../../EVATests/Waveform/WaveformScaleUnitsTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Waveform/WaveformScrollingPerformanceTests.swift](../../EVATests/Waveform/WaveformScrollingPerformanceTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/EmpiricalBayesThresholdTests.swift](../../EVATests/Wavelet/EmpiricalBayesThresholdTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WaveletArtifactAnalyzerTests.swift](../../EVATests/Wavelet/WaveletArtifactAnalyzerTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WaveletArtifactClassificationTests.swift](../../EVATests/Wavelet/WaveletArtifactClassificationTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WaveletMetalBackendTests.swift](../../EVATests/Wavelet/WaveletMetalBackendTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WaveletOversmoothingMeasurementTests.swift](../../EVATests/Wavelet/WaveletOversmoothingMeasurementTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WaveletReductionViewModelTests.swift](../../EVATests/Wavelet/WaveletReductionViewModelTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WaveletScalogramTests.swift](../../EVATests/Wavelet/WaveletScalogramTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WICAPreservationMeasurementTests.swift](../../EVATests/Wavelet/WICAPreservationMeasurementTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVATests/Wavelet/WICAProcessorTests.swift](../../EVATests/Wavelet/WICAProcessorTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVAThumbnail/ThumbnailProvider.swift](../../EVAThumbnail/ThumbnailProvider.swift) | 4/5 | — | No changes in these passes | — |
| [EVAUITests/EVAUITests.swift](../../EVAUITests/EVAUITests.swift) | 4/5 | — | No changes in these passes | — |
| [EVAUITests/EVAUITestsLaunchTests.swift](../../EVAUITests/EVAUITestsLaunchTests.swift) | 4/5 | — | No changes in these passes | — |
| [EVAUITests/EVAWorkflowUITests.swift](../../EVAUITests/EVAWorkflowUITests.swift) | 4/5 | — | No changes in these passes | — |
| [run-all-tests.sh](../../run-all-tests.sh) | 4/5 | — | No changes in these passes | — |
| [scripts/calibrate.sh](../../scripts/calibrate.sh) | 4/5 | — | No changes in these passes | — |
| [scripts/check-determinism.sh](../../scripts/check-determinism.sh) | 4/5 | — | No changes in these passes | — |
| [scripts/compare-methods.sh](../../scripts/compare-methods.sh) | 4/5 | — | No changes in these passes | — |
| [scripts/compare-wica-ica-algorithms.sh](../../scripts/compare-wica-ica-algorithms.sh) | 4/5 | — | No changes in these passes | — |
| [scripts/evaluate-wica-campaign.sh](../../scripts/evaluate-wica-campaign.sh) | 4/5 | — | No changes in these passes | — |
| [scripts/evaluate-wica-mixed-campaign.sh](../../scripts/evaluate-wica-mixed-campaign.sh) | 4/5 | — | No changes in these passes | — |
| [scripts/release.sh](../../scripts/release.sh) | 4/5 | — | No changes in these passes | — |
| [scripts/sync-planning-docs.py](../../scripts/sync-planning-docs.py) | 4/5 | — | No changes in these passes | — |
| [Tools/bdf-import/make_bdf_fixtures.py](../../Tools/bdf-import/make_bdf_fixtures.py) | 4/5 | — | No changes in these passes | — |
| [Tools/compare-paired-run.sh](../../Tools/compare-paired-run.sh) | 4/5 | — | No changes in these passes | — |
| [Tools/eeglab-compare/compare_eeglab.py](../../Tools/eeglab-compare/compare_eeglab.py) | 4/5 | — | No changes in these passes | — |
| [Tools/eeglab-compare/export_eeglab_set.py](../../Tools/eeglab-compare/export_eeglab_set.py) | 4/5 | — | No changes in these passes | — |
| [Tools/eeglab-compare/run_eeglab_pipeline.m](../../Tools/eeglab-compare/run_eeglab_pipeline.m) | 4/5 | — | No changes in these passes | — |
| [Tools/EVABIDS/build.sh](../../Tools/EVABIDS/build.sh) | 4/5 | — | No changes in these passes | — |
| [Tools/EVABIDS/Sources/EVABIDS/BIDSCommon.swift](../../Tools/EVABIDS/Sources/EVABIDS/BIDSCommon.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVABIDS/Sources/EVABIDS/EDFCodec.swift](../../Tools/EVABIDS/Sources/EVABIDS/EDFCodec.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVABIDS/Sources/EVABIDS/FromBIDS.swift](../../Tools/EVABIDS/Sources/EVABIDS/FromBIDS.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVABIDS/Sources/EVABIDS/InspectBIDS.swift](../../Tools/EVABIDS/Sources/EVABIDS/InspectBIDS.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVABIDS/Sources/EVABIDS/main.swift](../../Tools/EVABIDS/Sources/EVABIDS/main.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVABIDS/Sources/EVABIDS/ToBIDS.swift](../../Tools/EVABIDS/Sources/EVABIDS/ToBIDS.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVAGradient/build.sh](../../Tools/EVAGradient/build.sh) | 4/5 | — | No changes in these passes | — |
| [Tools/EVAGradient/EngineAddons.swift](../../Tools/EVAGradient/EngineAddons.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVAGradient/ExperimentMethods.swift](../../Tools/EVAGradient/ExperimentMethods.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVAGradient/JitterExperiment.swift](../../Tools/EVAGradient/JitterExperiment.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVAGradient/MethodSelfTests.swift](../../Tools/EVAGradient/MethodSelfTests.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVAGradient/run_addon_campaign.py](../../Tools/EVAGradient/run_addon_campaign.py) | 4/5 | — | No changes in these passes | — |
| [Tools/EVAGradient/run_controlled_p3.py](../../Tools/EVAGradient/run_controlled_p3.py) | 4/5 | — | No changes in these passes | — |
| [Tools/EVAHelper/build.sh](../../Tools/EVAHelper/build.sh) | 4/5 | — | No changes in these passes | — |
| [Tools/EVASimulate/Sources/EVASimulate/ERPEvaluation.swift](../../Tools/EVASimulate/Sources/EVASimulate/ERPEvaluation.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVASimulate/Sources/EVASimulate/RichMetrics.swift](../../Tools/EVASimulate/Sources/EVASimulate/RichMetrics.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVASimulate/Sources/EVASimulate/SI0ContractFixtures.swift](../../Tools/EVASimulate/Sources/EVASimulate/SI0ContractFixtures.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVASimulate/Sources/EVASimulate/SimulationWriter.swift](../../Tools/EVASimulate/Sources/EVASimulate/SimulationWriter.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVASimulate/Sources/EVASimulate/SNRMetrics.swift](../../Tools/EVASimulate/Sources/EVASimulate/SNRMetrics.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVASimulate/Sources/EVASimulate/SourceMetrics.swift](../../Tools/EVASimulate/Sources/EVASimulate/SourceMetrics.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/EVASimulate/Sources/EVASimulate/SurrogateSeparation.swift](../../Tools/EVASimulate/Sources/EVASimulate/SurrogateSeparation.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/fif-import/make_fif_fixtures.py](../../Tools/fif-import/make_fif_fixtures.py) | 4/5 | — | No changes in these passes | — |
| [Tools/forward-compare/check_swift_openmeeg.py](../../Tools/forward-compare/check_swift_openmeeg.py) | 4/5 | — | No changes in these passes | — |
| [Tools/forward-compare/make_forward_fixtures.py](../../Tools/forward-compare/make_forward_fixtures.py) | 4/5 | — | No changes in these passes | — |
| [Tools/generate_ebayes_reference.R](../../Tools/generate_ebayes_reference.R) | 4/5 | — | No changes in these passes | — |
| [Tools/mffTimingTool/build.sh](../../Tools/mffTimingTool/build.sh) | 4/5 | — | No changes in these passes | — |
| [Tools/mffTimingTool/Sources/mffTimingTool/main.swift](../../Tools/mffTimingTool/Sources/mffTimingTool/main.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/mne-compare/make_filter_edges_reference.py](../../Tools/mne-compare/make_filter_edges_reference.py) | 4/5 | — | No changes in these passes | — |
| [Tools/mne-compare/make_full_pipeline_reference.py](../../Tools/mne-compare/make_full_pipeline_reference.py) | 4/5 | — | No changes in these passes | — |
| [Tools/mne-compare/make_real_reference.py](../../Tools/mne-compare/make_real_reference.py) | 4/5 | — | No changes in these passes | — |
| [Tools/mne-compare/make_reference.py](../../Tools/mne-compare/make_reference.py) | 4/5 | — | No changes in these passes | — |
| [Tools/resolve-validate/check_swift_fif.py](../../Tools/resolve-validate/check_swift_fif.py) | 4/5 | — | No changes in these passes | — |
| [Tools/resolve-validate/check_swift_nifti.py](../../Tools/resolve-validate/check_swift_nifti.py) | 4/5 | — | No changes in these passes | — |
| [Tools/resolve-validate/export_montages.py](../../Tools/resolve-validate/export_montages.py) | 4/5 | — | No changes in these passes | — |
| [Tools/resolve-validate/make_fixtures.py](../../Tools/resolve-validate/make_fixtures.py) | 4/5 | — | No changes in these passes | — |
| [Tools/RhythmicityReference/generate_burst_oracle.py](../../Tools/RhythmicityReference/generate_burst_oracle.py) | 4/5 | — | No changes in these passes | — |
| [Tools/RhythmicityReference/generate_input.py](../../Tools/RhythmicityReference/generate_input.py) | 4/5 | — | No changes in these passes | — |
| [Tools/RhythmicityReference/inspect_mff.py](../../Tools/RhythmicityReference/inspect_mff.py) | 4/5 | — | No changes in these passes | — |
| [Tools/RhythmicityReference/run_python_reference.py](../../Tools/RhythmicityReference/run_python_reference.py) | 4/5 | — | No changes in these passes | — |
| [Tools/spatial-benchmark/Benchmark.swift](../../Tools/spatial-benchmark/Benchmark.swift) | 4/5 | — | No changes in these passes | — |
| [Tools/spatial-benchmark/run.sh](../../Tools/spatial-benchmark/run.sh) | 4/5 | — | No changes in these passes | — |
| [Tools/spatial-benchmark/Support.swift](../../Tools/spatial-benchmark/Support.swift) | 4/5 | — | No changes in these passes | — |
| [EVA/Channels/ChannelSet.swift](../../EVA/Channels/ChannelSet.swift) | 5/5 | — | No changes in these passes | — |
| [EVA/Core/SignalSelection.swift](../../EVA/Core/SignalSelection.swift) | 4/5 | **5/5** | Initial focused comments | Short selection routines now state shape/index assumptions and give a concrete example of the greedy merge rule, making its moving representative directly traceable. |
| [EVA/Core/SignalStatistics.swift](../../EVA/Core/SignalStatistics.swift) | 4/5 | **5/5** | Initial focused comments | Small arithmetic routines now state sorted-input assumptions, interpolation examples, units, variance denominators, and empty/nonfinite behavior alongside readable implementations. |
| [EVATests/Core/SignalSelectionTests.swift](../../EVATests/Core/SignalSelectionTests.swift) | 5/5 | — | No changes in these passes | — |

## Original assessment

> Historical baseline assessment. See the [comment pass and deferred structural changes](readability-comment-pass-2026-11-06.md) for subsequent work. Source line numbers below refer to the baseline snapshot.

Assessment date: November 6, 2026. Tracked working-tree sources at commit `af2de90420d8`. Audience: a programmer with undergraduate CS coursework, new to Swift and without assumed EEG, signal-processing, neuroimaging or GPU expertise.

[Read the findings and improvement plan](readability-audit-2026-11-06.md).

## Scope and interpretation

Every one of the **774 tracked source files** has a row below: **727 Swift, 5 Metal, 24 Python, 14 shell, 1 MATLAB, 1 R and 2 HTML/CSS files**, totaling **280,580 physical lines**. Tests, tooling, and generated Swift data are included. Build/project metadata, declarative configuration, documentation prose, binaries, caches, images and untracked scratch work are excluded. There were no additional untracked source files outside the scratch directories.

**This is a complete static inventory and a provisional readability assessment, not a line-by-line semantic review of all 280,580 lines.** All files were read by the scanner; their individual structural summaries were examined. **C** marks 40 files whose source sections were additionally inspected and whose ratings/recommendations were individually adjusted. **S** marks 734 files with scan-based estimates. C means closer reading of selected sections, not a full correctness review. Use S ratings to prioritize a closer pass before refactoring.

Ratings describe the ease of understanding the file for this audience, not scientific correctness, code quality in general, test coverage or author skill. A numerical method can be well implemented and still require specialist background. No application code was changed or executed for this review.

| Score | Meaning for this reader |
| --- | --- |
| 5 | Immediately approachable; a strong learning example with clear intent and contracts. |
| 4 | Mostly approachable; localized Swift/domain lookups or a few contract comments would help. |
| 3 | Understandable with guidance; framework, data-flow or scientific context is missing. |
| 2 | Difficult independently; substantial background or cross-file tracing is required. |
| 1 | Very difficult as an entry point; broad responsibilities or long workflows overwhelm local explanation. |

The **Comment status** column records subsequent work: all 50 original 1/5–2/5 files have expanded comments, and 10 other files retain the initial focused additions. “—” means no comment changes in these passes. Scores, line counts, and evidence in the detailed tables below remain the original assessment. The summary above contains the November 7 corrected scores and file-specific reasons; the comment-status column below records the implementation work.

## How to read the evidence

Each row provides an integer score, physical size, review depth, file-specific evidence and a first edit. Source links open the largest detected routine where available; line references reflect this snapshot. Function lengths are lexical estimates, not compiler measurements. They include signatures, comments and nested functions; computed properties other than SwiftUI `body`, shell functions and embedded shaders are not exhaustively measured. String/comment masking is approximate.

Scan ratings combine file/routine size, explanatory comments and Python docstrings, async and unsafe-memory operations, numerical/GPU calls, UI state and shared `WaveformView` extensions. Small tests are treated differently from production algorithms, and generated tables are treated as data. Scientific and file-format code with sparse explanation receives additional scrutiny. Sparse comments alone do not imply poor readability. License/provenance prose and UI help strings are not substitutes for explaining developer contracts. The scan cannot reliably judge whether every comment is correct or whether naming is sufficient; that is why its scores remain provisional and are capped at 4. Closer-reading scores may override the heuristic.

The aggregate distribution is **17 files at 1, 33 at 2, 135 at 3, 587 at 4, and 2 at 5**. The two scores of 5 reflect confirmed teaching examples, not a claim that every other small file needs changes. Do not use this distribution as a code-quality KPI or optimize for comment count.

## Index

- [EVA/Analysis (4 files)](#evaanalysis)
- [EVA/App (24 files)](#evaapp)
- [EVA/Artifacts (32 files)](#evaartifacts)
- [EVA/Cardiac (12 files)](#evacardiac)
- [EVA/Channels (18 files)](#evachannels)
- [EVA/Combine (3 files)](#evacombine)
- [EVA/Compare (3 files)](#evacompare)
- [EVA/Core (5 files)](#evacore)
- [EVA/Epoching (34 files)](#evaepoching)
- [EVA/Filtering (5 files)](#evafiltering)
- [EVA/Gradient (24 files)](#evagradient)
- [EVA/Health (12 files)](#evahealth)
- [EVA/Help (4 files)](#evahelp)
- [EVA/ICA (11 files)](#evaica)
- [EVA/IO (14 files)](#evaio)
- [EVA/Markers (1 files)](#evamarkers)
- [EVA/Pipeline (31 files)](#evapipeline)
- [EVA/Rhythmicity (28 files)](#evarhythmicity)
- [EVA/Simulation (3 files)](#evasimulation)
- [EVA/TimeFrequency (12 files)](#evatimefrequency)
- [EVA/Trials (11 files)](#evatrials)
- [EVA/Waveform (21 files)](#evawaveform)
- [EVA/Wavelet (18 files)](#evawavelet)
- [EVACore/Artifacts (1 files)](#evacoreartifacts)
- [EVACore/Channels (7 files)](#evacorechannels)
- [EVACore/Core (11 files)](#evacorecore)
- [EVACore/Epoching (1 files)](#evacoreepoching)
- [EVACore/Geometry (3 files)](#evacoregeometry)
- [EVACore/IO (19 files)](#evacoreio)
- [EVACore/Imaging (2 files)](#evacoreimaging)
- [EVACore/Pipeline (1 files)](#evacorepipeline)
- [EVACore/Registration (1 files)](#evacoreregistration)
- [EVACore/Simulation (30 files)](#evacoresimulation)
- [EVAPreviewKit/CIFTI (6 files)](#evapreviewkitcifti)
- [EVAPreviewKit/DICOM (5 files)](#evapreviewkitdicom)
- [EVAPreviewKit/EVAPreviewFormat.swift (1 files)](#evapreviewkitevapreviewformatswift)
- [EVAPreviewKit/EVAQuickLookPreferences.swift (1 files)](#evapreviewkitevaquicklookpreferencesswift)
- [EVAPreviewKit/FIF (4 files)](#evapreviewkitfif)
- [EVAPreviewKit/GIFTI (3 files)](#evapreviewkitgifti)
- [EVAPreviewKit/MFF (4 files)](#evapreviewkitmff)
- [EVAPreviewKit/MGH (5 files)](#evapreviewkitmgh)
- [EVAPreviewKit/NIfTI (5 files)](#evapreviewkitnifti)
- [EVAQuickLook (1 files)](#evaquicklook)
- [EVAResolve/App (2 files)](#evaresolveapp)
- [EVAResolve/HeadModel (5 files)](#evaresolveheadmodel)
- [EVAResolve/Simulator (11 files)](#evaresolvesimulator)
- [EVAResolveTests (3 files)](#evaresolvetests)
- [EVATests/Analysis (1 files)](#evatestsanalysis)
- [EVATests/App (5 files)](#evatestsapp)
- [EVATests/Artifacts (15 files)](#evatestsartifacts)
- [EVATests/Cardiac (6 files)](#evatestscardiac)
- [EVATests/Channels (9 files)](#evatestschannels)
- [EVATests/Combine (1 files)](#evatestscombine)
- [EVATests/Compare (6 files)](#evatestscompare)
- [EVATests/Core (13 files)](#evatestscore)
- [EVATests/EVATests.swift (1 files)](#evatestsevatestsswift)
- [EVATests/Epoching (19 files)](#evatestsepoching)
- [EVATests/Filtering (5 files)](#evatestsfiltering)
- [EVATests/Fixtures (2 files)](#evatestsfixtures)
- [EVATests/Fixtures.swift (1 files)](#evatestsfixturesswift)
- [EVATests/Gradient (23 files)](#evatestsgradient)
- [EVATests/Health (5 files)](#evatestshealth)
- [EVATests/Help (2 files)](#evatestshelp)
- [EVATests/ICA (10 files)](#evatestsica)
- [EVATests/IO (30 files)](#evatestsio)
- [EVATests/Pipeline (38 files)](#evatestspipeline)
- [EVATests/Rhythmicity (15 files)](#evatestsrhythmicity)
- [EVATests/Simulation (6 files)](#evatestssimulation)
- [EVATests/SyntheticSignal.swift (1 files)](#evatestssyntheticsignalswift)
- [EVATests/TimeFrequency (1 files)](#evateststimefrequency)
- [EVATests/Trials (9 files)](#evateststrials)
- [EVATests/Waveform (6 files)](#evatestswaveform)
- [EVATests/Wavelet (10 files)](#evatestswavelet)
- [EVAThumbnail (1 files)](#evathumbnail)
- [EVAUITests (3 files)](#evauitests)
- [Tools/EVABIDS (7 files)](#toolsevabids)
- [Tools/EVAGradient (8 files)](#toolsevagradient)
- [Tools/EVAHelper (5 files)](#toolsevahelper)
- [Tools/EVASimulate (9 files)](#toolsevasimulate)
- [Tools/RhythmicityReference (5 files)](#toolsrhythmicityreference)
- [Tools/bdf-import (1 files)](#toolsbdf-import)
- [Tools/compare-paired-run.sh (1 files)](#toolscompare-paired-runsh)
- [Tools/convert_iclabel_to_coreml.py (1 files)](#toolsconvert_iclabel_to_coremlpy)
- [Tools/eeglab-compare (3 files)](#toolseeglab-compare)
- [Tools/fif-import (1 files)](#toolsfif-import)
- [Tools/forward-compare (2 files)](#toolsforward-compare)
- [Tools/generate_ebayes_reference.R (1 files)](#toolsgenerate_ebayes_referencer)
- [Tools/mffTimingTool (2 files)](#toolsmfftimingtool)
- [Tools/mne-compare (4 files)](#toolsmne-compare)
- [Tools/resolve-validate (4 files)](#toolsresolve-validate)
- [Tools/spatial-benchmark (3 files)](#toolsspatial-benchmark)
- [docs (2 files)](#docs)
- [run-all-tests.sh (1 files)](#run-all-testssh)
- [scripts (8 files)](#scripts)

<a id="evaanalysis"></a>
## EVA/Analysis

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Analysis/EEGAnalysisEngine.swift](../../EVA/Analysis/EEGAnalysisEngine.swift#L36) | 2/5 | 1,037 | S | `analyze` is the largest detected routine (~111 lines, L36). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | **Expanded comments complete** |
| [EVA/Analysis/EEGAnalysisModels.swift](../../EVA/Analysis/EEGAnalysisModels.swift#L1) | 4/5 | 230 | S | Declarations include `EEGFrequencyBand`, `EEGConnectivityMetric`, `EEGArtifactRejectionSource`. Reading demands: numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Analysis/EEGAnalysisSheet.swift](../../EVA/Analysis/EEGAnalysisSheet.swift#L417) | 4/5 | 612 | S | `spectralChannelTable` is the largest detected routine (~34 lines, L417). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Analysis/EEGAnalysisViewModel.swift](../../EVA/Analysis/EEGAnalysisViewModel.swift#L97) | 3/5 | 221 | S | `run` is the largest detected routine (~79 lines, L97). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |

<a id="evaapp"></a>
## EVA/App

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/App/BatchWindowView.swift](../../EVA/App/BatchWindowView.swift#L69) | 4/5 | 329 | S | `var body` is the largest detected routine (~82 lines, L69). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REWIND.md references. | — |
| [EVA/App/ContentView.swift](../../EVA/App/ContentView.swift#L89) | 3/5 | 672 | C | Per-window recording ownership is explained, but scene lifecycle, opening and UI composition meet in one large view. | Document the open-file route and isolate lifecycle actions from view composition. | — |
| [EVA/App/DebugLog.swift](../../EVA/App/DebugLog.swift#L64) | 4/5 | 118 | S | `var body` is the largest detected routine (~54 lines, L64). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/ERPExperimentEditor.swift](../../EVA/App/ERPExperimentEditor.swift#L29) | 3/5 | 573 | S | `var body` is the largest detected routine (~41 lines, L29). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/ERPStudioHelp.swift](../../EVA/App/ERPStudioHelp.swift#L1) | 4/5 | 31 | S | Declarations include `ERPStudioHelp`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVA/App/EVAApp.swift](../../EVA/App/EVAApp.swift#L51) | 3/5 | 410 | C | Scene wiring is explicit, but long bug narratives interrupt the scene declaration and depend on SwiftUI environment ownership. | Lead with a scene/state ownership map; condense history into current invariants and move incident details to developer notes. | — |
| [EVA/App/EventAnchorCatalog.swift](../../EVA/App/EventAnchorCatalog.swift#L106) | 4/5 | 109 | S | `entries` is the largest detected routine (~3 lines, L106). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `entries`; preserve straightforward code. | — |
| [EVA/App/EventAnchorPreferencesView.swift](../../EVA/App/EventAnchorPreferencesView.swift#L265) | 4/5 | 373 | S | `var body` is the largest detected routine (~41 lines, L265). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/EventAnchorSettings.swift](../../EVA/App/EventAnchorSettings.swift#L80) | 4/5 | 219 | S | `matches` is the largest detected routine (~13 lines, L80). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/OpenRecordingRegistry.swift](../../EVA/App/OpenRecordingRegistry.swift#L58) | 4/5 | 65 | S | `register` is the largest detected routine (~3 lines, L58). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/PendingWindowForks.swift](../../EVA/App/PendingWindowForks.swift#L59) | 4/5 | 73 | S | `push` is the largest detected routine (~3 lines, L59). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `push`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/App/PendingWindowOpens.swift](../../EVA/App/PendingWindowOpens.swift#L41) | 4/5 | 51 | S | `push` is the largest detected routine (~3 lines, L41). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `push`; preserve straightforward code. | — |
| [EVA/App/PreferencesView.swift](../../EVA/App/PreferencesView.swift#L350) | 3/5 | 891 | S | `var body` is the largest detected routine (~190 lines, L350). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. Replace missing REFACTOR.md references. | — |
| [EVA/App/RecordingStore.swift](../../EVA/App/RecordingStore.swift#L1) | 4/5 | 99 | S | Declarations include `RecordingStore`. Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |
| [EVA/App/SimulatorGenerateView.swift](../../EVA/App/SimulatorGenerateView.swift#L1049) | 4/5 | 1,168 | S | `var body` is the largest detected routine (~72 lines, L1049). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/App/SimulatorGroupView.swift](../../EVA/App/SimulatorGroupView.swift#L24) | 4/5 | 259 | S | `var body` is the largest detected routine (~85 lines, L24). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/SimulatorHelp.swift](../../EVA/App/SimulatorHelp.swift#L103) | 4/5 | 965 | S | `var body` is the largest detected routine (~53 lines, L103). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/App/SimulatorScoreView.swift](../../EVA/App/SimulatorScoreView.swift#L64) | 4/5 | 243 | S | `inputsSection` is the largest detected routine (~33 lines, L64). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/SimulatorSweepView.swift](../../EVA/App/SimulatorSweepView.swift#L27) | 4/5 | 284 | S | `var body` is the largest detected routine (~62 lines, L27). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/SimulatorWindowView.swift](../../EVA/App/SimulatorWindowView.swift#L30) | 4/5 | 87 | S | `var body` is the largest detected routine (~18 lines, L30). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/App/SweepHelp.swift](../../EVA/App/SweepHelp.swift#L1) | 4/5 | 16 | S | Declarations include `SweepHelp`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVA/App/TemporaryFileSweeper.swift](../../EVA/App/TemporaryFileSweeper.swift#L56) | 4/5 | 154 | S | `sweep` is the largest detected routine (~17 lines, L56). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `sweep`; preserve straightforward code. | — |
| [EVA/App/UpdateChecker.swift](../../EVA/App/UpdateChecker.swift#L135) | 4/5 | 233 | S | `check` is the largest detected routine (~34 lines, L135). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/App/WindowCloseBehavior.swift](../../EVA/App/WindowCloseBehavior.swift#L53) | 4/5 | 64 | S | `applicationDidFinishLaunching` is the largest detected routine (~7 lines, L53). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |

<a id="evaartifacts"></a>
## EVA/Artifacts

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Artifacts/ArtifactCleanRunGrade.swift](../../EVA/Artifacts/ArtifactCleanRunGrade.swift#L121) | 4/5 | 228 | S | `addingEventEvidence` is the largest detected routine (~58 lines, L121). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `addingEventEvidence`; preserve straightforward code. | — |
| [EVA/Artifacts/ArtifactCleaner.swift](../../EVA/Artifacts/ArtifactCleaner.swift#L849) | 1/5 | 3,164 | C | 3,164 lines combine artifact types, configuration, dispatch, cleaning methods, basis fitting and matrix helpers. | Separate models and per-method implementations; document method inputs, units, ordering and no-op/cancellation outcomes. | **Expanded comments complete** |
| [EVA/Artifacts/ArtifactCleaningCore.swift](../../EVA/Artifacts/ArtifactCleaningCore.swift#L45) | 4/5 | 86 | S | `commit` is the largest detected routine (~41 lines, L45). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `commit`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/Artifacts/ArtifactCleaningExecutor.swift](../../EVA/Artifacts/ArtifactCleaningExecutor.swift#L20) | 3/5 | 211 | S | `cleanedSignal` is the largest detected routine (~191 lines, L20). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Artifacts/ArtifactDetectionSummaryViews.swift](../../EVA/Artifacts/ArtifactDetectionSummaryViews.swift#L273) | 3/5 | 434 | S | `updateArtifactEvents` is the largest detected routine (~115 lines, L273). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Artifacts/ArtifactPreviewViews.swift](../../EVA/Artifacts/ArtifactPreviewViews.swift#L885) | 1/5 | 2,651 | S | `var body` is the largest detected routine (~200 lines, L885). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. Replace missing REFACTOR.md references. | **Expanded comments complete** |
| [EVA/Artifacts/ArtifactReplayPayload.swift](../../EVA/Artifacts/ArtifactReplayPayload.swift#L105) | 4/5 | 191 | S | `artifacts` is the largest detected routine (~12 lines, L105). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `artifacts`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/Artifacts/ArtifactReview.swift](../../EVA/Artifacts/ArtifactReview.swift#L449) | 4/5 | 675 | S | `analyze` is the largest detected routine (~80 lines, L449). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Artifacts/ArtifactReviewWorkspace.swift](../../EVA/Artifacts/ArtifactReviewWorkspace.swift#L1077) | 1/5 | 1,942 | C | 1,942 lines combine review/cache state, interaction and many UI panels; long user-facing help strings do not explain developer state ownership. | Extract result-cache ownership, navigation and individual panels; document how review choices persist across refreshes. | **Expanded comments complete** |
| [EVA/Artifacts/ArtifactSpatialGrouping.swift](../../EVA/Artifacts/ArtifactSpatialGrouping.swift#L628) | 3/5 | 899 | S | `parallelHierarchy` is the largest detected routine (~79 lines, L628). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Artifacts/ArtifactTemplateDefinitionViews.swift](../../EVA/Artifacts/ArtifactTemplateDefinitionViews.swift#L1856) | 2/5 | 2,243 | S | `artifactCleaningSheet` is the largest detected routine (~206 lines, L1856). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Artifacts/ArtifactTemplateDetector.swift](../../EVA/Artifacts/ArtifactTemplateDetector.swift#L903) | 1/5 | 1,886 | S | `detectTrajectory` is the largest detected routine (~324 lines, L903). Reading demands: unsafe-memory APIs, numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. Separate major responsibilities into focused files. | **Expanded comments complete** |
| [EVA/Artifacts/ArtifactTemplateViewModel.swift](../../EVA/Artifacts/ArtifactTemplateViewModel.swift#L109) | 4/5 | 133 | S | `resetForClose` is the largest detected routine (~24 lines, L109). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |
| [EVA/Artifacts/ArtifactViewModel.swift](../../EVA/Artifacts/ArtifactViewModel.swift#L112) | 4/5 | 131 | S | `resetForClose` is the largest detected routine (~19 lines, L112). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |
| [EVA/Artifacts/ArtifactWaveformGrouping.swift](../../EVA/Artifacts/ArtifactWaveformGrouping.swift#L29) | 4/5 | 149 | S | `build` is the largest detected routine (~108 lines, L29). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Artifacts/CorneoRetinalCorrection.swift](../../EVA/Artifacts/CorneoRetinalCorrection.swift#L239) | 4/5 | 513 | S | `correct` is the largest detected routine (~154 lines, L239). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `correct`; preserve straightforward code. | — |
| [EVA/Artifacts/CorneoRetinalCorrectionViews.swift](../../EVA/Artifacts/CorneoRetinalCorrectionViews.swift#L32) | 2/5 | 733 | S | `corneoRetinalSheet` is the largest detected routine (~200 lines, L32). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Artifacts/CorneoRetinalHelp.swift](../../EVA/Artifacts/CorneoRetinalHelp.swift#L1) | 4/5 | 80 | S | Declarations include `CorneoRetinalReferences`, `CorneoRetinalHelpTopics`. Little explanatory commenting was detected. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVA/Artifacts/CorneoRetinalViewModel.swift](../../EVA/Artifacts/CorneoRetinalViewModel.swift#L77) | 4/5 | 141 | S | `setSpan` is the largest detected routine (~23 lines, L77). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Artifacts/MAACPreliminaryBlinkDetector.swift](../../EVA/Artifacts/MAACPreliminaryBlinkDetector.swift#L61) | 4/5 | 274 | S | `detect` is the largest detected routine (~163 lines, L61). Relatively localized scope. | Add the input/output contract and edge cases for `detect`; preserve straightforward code. | — |
| [EVA/Artifacts/MovementPCACorrection.swift](../../EVA/Artifacts/MovementPCACorrection.swift#L386) | 2/5 | 921 | S | `correctEpoch` is the largest detected routine (~140 lines, L386). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | **Expanded comments complete** |
| [EVA/Artifacts/MovementPCACorrectionViews.swift](../../EVA/Artifacts/MovementPCACorrectionViews.swift#L419) | 3/5 | 547 | S | `analyzeMovementPCA` is the largest detected routine (~79 lines, L419). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Artifacts/MovementPCAViewModel.swift](../../EVA/Artifacts/MovementPCAViewModel.swift#L35) | 4/5 | 46 | S | `resetForClose` is the largest detected routine (~11 lines, L35). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Artifacts/MuscleBSSCCACorrection.swift](../../EVA/Artifacts/MuscleBSSCCACorrection.swift#L299) | 3/5 | 796 | S | `process` is the largest detected routine (~114 lines, L299). Reading demands: asynchronous control flow, numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Artifacts/MuscleBSSCCACorrectionViews.swift](../../EVA/Artifacts/MuscleBSSCCACorrectionViews.swift#L888) | 2/5 | 1,096 | S | `analyzeMuscleBSSCCA` is the largest detected routine (~95 lines, L888). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Artifacts/MuscleBSSCCAViewModel.swift](../../EVA/Artifacts/MuscleBSSCCAViewModel.swift#L46) | 4/5 | 61 | S | `resetForClose` is the largest detected routine (~15 lines, L46). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Artifacts/SaccadicSpikeCorrection.swift](../../EVA/Artifacts/SaccadicSpikeCorrection.swift#L300) | 3/5 | 601 | S | `detect` is the largest detected routine (~187 lines, L300). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Artifacts/SaccadicSpikeCorrectionViews.swift](../../EVA/Artifacts/SaccadicSpikeCorrectionViews.swift#L35) | 2/5 | 343 | S | `saccadicSpikeSheet` is the largest detected routine (~151 lines, L35). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | **Expanded comments complete** |
| [EVA/Artifacts/SaccadicSpikeHelp.swift](../../EVA/Artifacts/SaccadicSpikeHelp.swift#L1) | 4/5 | 70 | S | Declarations include `SaccadicSpikeReferences`, `SaccadicSpikeHelpTopics`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVA/Artifacts/SaccadicSpikeViewModel.swift](../../EVA/Artifacts/SaccadicSpikeViewModel.swift#L37) | 4/5 | 47 | S | `resetForClose` is the largest detected routine (~9 lines, L37). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Artifacts/SourceInformed/SurrogateBrainBasis.swift](../../EVA/Artifacts/SourceInformed/SurrogateBrainBasis.swift#L115) | 4/5 | 156 | S | `basis` is the largest detected routine (~37 lines, L115). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `basis`; preserve straightforward code. | — |
| [EVA/Artifacts/ThresholdOcularReviewViews.swift](../../EVA/Artifacts/ThresholdOcularReviewViews.swift#L21) | 4/5 | 39 | S | `coveredSeconds` is the largest detected routine (~17 lines, L21). Relatively localized scope. | Add the input/output contract and edge cases for `coveredSeconds`; preserve straightforward code. | — |

<a id="evacardiac"></a>
## EVA/Cardiac

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Cardiac/BCGDetectionPreviewEstimator.swift](../../EVA/Cardiac/BCGDetectionPreviewEstimator.swift#L35) | 4/5 | 165 | S | `eventTimes` is the largest detected routine (~102 lines, L35). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Cardiac/BCGDetectionViewModel.swift](../../EVA/Cardiac/BCGDetectionViewModel.swift#L138) | 4/5 | 220 | S | `resetForClose` is the largest detected routine (~17 lines, L138). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |
| [EVA/Cardiac/BCGDetectionViews.swift](../../EVA/Cardiac/BCGDetectionViews.swift#L728) | 1/5 | 2,043 | S | `bcgMethodOptions` is the largest detected routine (~437 lines, L728). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Cardiac/BCGDetector.swift](../../EVA/Cardiac/BCGDetector.swift#L104) | 2/5 | 908 | S | `spatialPCAEvents` is the largest detected routine (~141 lines, L104). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | **Expanded comments complete** |
| [EVA/Cardiac/BCGDurationEstimator.swift](../../EVA/Cardiac/BCGDurationEstimator.swift#L75) | 4/5 | 274 | S | `estimateFiltered` is the largest detected routine (~145 lines, L75). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Cardiac/BCGSurrogateCorrection.swift](../../EVA/Cardiac/BCGSurrogateCorrection.swift#L416) | 2/5 | 670 | S | `correct` is the largest detected routine (~254 lines, L416). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | **Expanded comments complete** |
| [EVA/Cardiac/BCGSurrogateTopographies.swift](../../EVA/Cardiac/BCGSurrogateTopographies.swift#L135) | 3/5 | 382 | S | `components` is the largest detected routine (~189 lines, L135). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Cardiac/CWLCorrector.swift](../../EVA/Cardiac/CWLCorrector.swift#L121) | 1/5 | 1,277 | S | `correct` is the largest detected routine (~229 lines, L121). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. Separate major responsibilities into focused files. | **Expanded comments complete** |
| [EVA/Cardiac/ECGDetectionViewModel.swift](../../EVA/Cardiac/ECGDetectionViewModel.swift#L51) | 4/5 | 60 | S | `resetForClose` is the largest detected routine (~9 lines, L51). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Cardiac/ECGDetectionViews.swift](../../EVA/Cardiac/ECGDetectionViews.swift#L43) | 2/5 | 509 | S | `ecgDetectionSheet` is the largest detected routine (~170 lines, L43). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | **Expanded comments complete** |
| [EVA/Cardiac/PCASRunGrade.swift](../../EVA/Cardiac/PCASRunGrade.swift#L68) | 4/5 | 151 | S | `grade` is the largest detected routine (~28 lines, L68). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `grade`; preserve straightforward code. | — |
| [EVA/Cardiac/RWaveDetector.swift](../../EVA/Cardiac/RWaveDetector.swift#L236) | 3/5 | 1,143 | S | `detectCandidates` is the largest detected routine (~89 lines, L236). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `detectCandidates`; preserve straightforward code. Replace missing REFACTOR.md references. | — |

<a id="evachannels"></a>
## EVA/Channels

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Channels/ChannelGoodnessSettings.swift](../../EVA/Channels/ChannelGoodnessSettings.swift#L462) | 4/5 | 619 | S | `waveletSection` is the largest detected routine (~62 lines, L462). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Channels/ChannelInspectorViews.swift](../../EVA/Channels/ChannelInspectorViews.swift#L71) | 3/5 | 789 | S | `channelInspectorSheet` is the largest detected routine (~125 lines, L71). Reading demands: shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/Channels/ChannelInterpolationSolver.swift](../../EVA/Channels/ChannelInterpolationSolver.swift#L98) | 4/5 | 142 | S | `solve` is the largest detected routine (~44 lines, L98). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `solve`; preserve straightforward code. | — |
| [EVA/Channels/ChannelLocationImportViews.swift](../../EVA/Channels/ChannelLocationImportViews.swift#L44) | 4/5 | 137 | S | `var body` is the largest detected routine (~51 lines, L44). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Channels/ChannelModel.swift](../../EVA/Channels/ChannelModel.swift#L307) | 2/5 | 757 | C | Channel state shares its file with environment keys and menu Views; a reader looking for a model must also follow command routing. | Separate channel state, environment contracts and menu commands; show the focused-window routing path. | **Expanded comments complete** |
| [EVA/Channels/ChannelSet.swift](../../EVA/Channels/ChannelSet.swift#L1) | 5/5 | 57 | C | Small value types explain zero-based indices, optional net restrictions and the export envelope. | Keep this as a model example; add a short construction example only if onboarding needs one. | — |
| [EVA/Channels/ChannelSetEditorView.swift](../../EVA/Channels/ChannelSetEditorView.swift#L1120) | 3/5 | 1,219 | S | `var body` is the largest detected routine (~53 lines, L1120). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/Channels/ChannelSetMapView.swift](../../EVA/Channels/ChannelSetMapView.swift#L40) | 4/5 | 220 | S | `var body` is the largest detected routine (~56 lines, L40). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Channels/ChannelSetPickerView.swift](../../EVA/Channels/ChannelSetPickerView.swift#L60) | 4/5 | 84 | S | `var body` is the largest detected routine (~24 lines, L60). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Channels/ChannelSetStore.swift](../../EVA/Channels/ChannelSetStore.swift#L220) | 4/5 | 309 | S | `renameGeometry` is the largest detected routine (~18 lines, L220). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Channels/ChannelsPanelViews.swift](../../EVA/Channels/ChannelsPanelViews.swift#L541) | 3/5 | 725 | S | `waveformInteractionGesture` is the largest detected routine (~73 lines, L541). Reading demands: shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/Channels/ChannelsWindowModel.swift](../../EVA/Channels/ChannelsWindowModel.swift#L267) | 3/5 | 355 | S | `refreshDiagnostics` is the largest detected routine (~71 lines, L267). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Channels/ChannelsWindowView.swift](../../EVA/Channels/ChannelsWindowView.swift#L21) | 3/5 | 954 | S | `var body` is the largest detected routine (~69 lines, L21). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/Channels/DisplayChannels.swift](../../EVA/Channels/DisplayChannels.swift#L15) | 4/5 | 101 | S | `normalizedOrder` is the largest detected routine (~17 lines, L15). Relatively localized scope. | Add the input/output contract and edge cases for `normalizedOrder`; preserve straightforward code. | — |
| [EVA/Channels/ElectrodeGeometry+Forward.swift](../../EVA/Channels/ElectrodeGeometry+Forward.swift#L27) | 4/5 | 71 | S | `orderedForwardElectrodes` is the largest detected routine (~44 lines, L27). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `orderedForwardElectrodes`; preserve straightforward code. | — |
| [EVA/Channels/InterpolatedSignalResolver.swift](../../EVA/Channels/InterpolatedSignalResolver.swift#L66) | 4/5 | 119 | S | `resolve` is the largest detected routine (~26 lines, L66). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Channels/ScalpTopography3DView.swift](../../EVA/Channels/ScalpTopography3DView.swift#L235) | 4/5 | 395 | S | `scalpGeometry` is the largest detected routine (~60 lines, L235). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Channels/TopomapView.swift](../../EVA/Channels/TopomapView.swift#L358) | 4/5 | 700 | S | `draw` is the largest detected routine (~63 lines, L358). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |

<a id="evacombine"></a>
## EVA/Combine

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Combine/CombineRecordingsSheet.swift](../../EVA/Combine/CombineRecordingsSheet.swift#L418) | 3/5 | 569 | S | `build` is the largest detected routine (~118 lines, L418). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Combine/MultiRecordingModels.swift](../../EVA/Combine/MultiRecordingModels.swift#L348) | 4/5 | 442 | S | `autoMap` is the largest detected routine (~33 lines, L348). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `autoMap`; preserve straightforward code. | — |
| [EVA/Combine/RecordingCombiner.swift](../../EVA/Combine/RecordingCombiner.swift#L409) | 4/5 | 808 | S | `grandAverage` is the largest detected routine (~138 lines, L409). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `grandAverage`; preserve straightforward code. | — |

<a id="evacompare"></a>
## EVA/Compare

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Compare/CompareWindowsSheet.swift](../../EVA/Compare/CompareWindowsSheet.swift#L271) | 4/5 | 415 | S | `channelTable` is the largest detected routine (~45 lines, L271). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Compare/SignalComparison.swift](../../EVA/Compare/SignalComparison.swift#L115) | 4/5 | 286 | S | `compare` is the largest detected routine (~76 lines, L115). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `compare`; preserve straightforward code. | — |
| [EVA/Compare/WindowComparisonRegistry.swift](../../EVA/Compare/WindowComparisonRegistry.swift#L149) | 4/5 | 174 | S | `comparisonCandidates` is the largest detected routine (~19 lines, L149). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |

<a id="evacore"></a>
## EVA/Core

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Core/CleaningVarianceAccount.swift](../../EVA/Core/CleaningVarianceAccount.swift#L185) | 4/5 | 366 | S | `account` is the largest detected routine (~58 lines, L185). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `account`; preserve straightforward code. | — |
| [EVA/Core/Downsampler.swift](../../EVA/Core/Downsampler.swift#L59) | 4/5 | 148 | S | `windowedSincDecimated` is the largest detected routine (~18 lines, L59). Reading demands: unsafe-memory APIs, numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Core/SignalSelection.swift](../../EVA/Core/SignalSelection.swift#L27) | 4/5 | 53 | C | Small, named operations and guard clauses are approachable; mergeNearbyStarts uses a greedy representative rule that is not explained. | Document sorting, deduplication, tie handling and chained-hit behavior with one three-hit example. | Initial focused comments |
| [EVA/Core/SignalStatistics.swift](../../EVA/Core/SignalStatistics.swift#L26) | 4/5 | 66 | C | Short arithmetic routines are easy to follow; sorted-input assumptions, interpolation, empty results and variance conventions are implicit. | Add concise contracts for percentile, RMS, energy and population versus sample variance; keep the simple loops. | Initial focused comments |
| [EVA/Core/SphericalSpline.swift](../../EVA/Core/SphericalSpline.swift#L83) | 4/5 | 160 | S | `interpolationWeightsBatch` is the largest detected routine (~52 lines, L83). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `interpolationWeightsBatch`; preserve straightforward code. | — |

<a id="evaepoching"></a>
## EVA/Epoching

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Epoching/AveragesWorkspaceViews.swift](../../EVA/Epoching/AveragesWorkspaceViews.swift#L980) | 2/5 | 1,226 | S | `var body` is the largest detected routine (~128 lines, L980). Reading demands: shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Epoching/DifferenceWaveView.swift](../../EVA/Epoching/DifferenceWaveView.swift#L155) | 4/5 | 276 | S | `var body` is the largest detected routine (~121 lines, L155). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/EpochBadChannelDetector.swift](../../EVA/Epoching/EpochBadChannelDetector.swift#L234) | 4/5 | 274 | S | `interpolate` is the largest detected routine (~40 lines, L234). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `interpolate`; preserve straightforward code. | — |
| [EVA/Epoching/EpochSNR.swift](../../EVA/Epoching/EpochSNR.swift#L75) | 4/5 | 336 | S | `metrics` is the largest detected routine (~70 lines, L75). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `metrics`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/Epoching/EpochingViewModel.swift](../../EVA/Epoching/EpochingViewModel.swift#L1086) | 2/5 | 1,272 | S | `applyBuildJob` is the largest detected routine (~117 lines, L1086). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. Replace missing REFACTOR.md references. | **Expanded comments complete** |
| [EVA/Epoching/EyeArtifactThresholdConfiguration.swift](../../EVA/Epoching/EyeArtifactThresholdConfiguration.swift#L135) | 4/5 | 225 | S | `defaults` is the largest detected routine (~36 lines, L135). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `defaults`; preserve straightforward code. | — |
| [EVA/Epoching/EyeArtifactThresholdDetector.swift](../../EVA/Epoching/EyeArtifactThresholdDetector.swift#L67) | 4/5 | 543 | S | `detectCandidates` is the largest detected routine (~141 lines, L67). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `detectCandidates`; preserve straightforward code. | — |
| [EVA/Epoching/EyeArtifactThresholdSheet.swift](../../EVA/Epoching/EyeArtifactThresholdSheet.swift#L98) | 4/5 | 336 | S | `eyeThresholdTab` is the largest detected routine (~106 lines, L98). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/JointMarkerOverlay.swift](../../EVA/Epoching/JointMarkerOverlay.swift#L423) | 4/5 | 555 | S | `var body` is the largest detected routine (~108 lines, L423). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/MultiButterflyView.swift](../../EVA/Epoching/MultiButterflyView.swift#L155) | 4/5 | 325 | S | `var body` is the largest detected routine (~79 lines, L155). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/PSAAmplitudeRangeSlider.swift](../../EVA/Epoching/PSAAmplitudeRangeSlider.swift#L63) | 4/5 | 103 | S | `thumb` is the largest detected routine (~40 lines, L63). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/PSAAveraging.swift](../../EVA/Epoching/PSAAveraging.swift#L41) | 4/5 | 81 | S | `commit` is the largest detected routine (~40 lines, L41). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `commit`; preserve straightforward code. | — |
| [EVA/Epoching/PSABadChannelEscalation.swift](../../EVA/Epoching/PSABadChannelEscalation.swift#L57) | 4/5 | 149 | S | `escalate` is the largest detected routine (~92 lines, L57). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Epoching/PSAConfigurationComponents.swift](../../EVA/Epoching/PSAConfigurationComponents.swift#L62) | 4/5 | 99 | S | `var body` is the largest detected routine (~37 lines, L62). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/PSADecisionMatrix.swift](../../EVA/Epoching/PSADecisionMatrix.swift#L2223) | 1/5 | 2,793 | C | 2,793 lines join review state, navigation, rendering and viewport math; rendering coordinates and decision ownership require cross-file tracing. | Separate decision data, layout math, drawing and interaction; document pixel versus channel/epoch indices. | **Expanded comments complete** |
| [EVA/Epoching/PSADecisionMatrixNavigation.swift](../../EVA/Epoching/PSADecisionMatrixNavigation.swift#L78) | 4/5 | 111 | S | `decisionMatrixFocusOverlay` is the largest detected routine (~33 lines, L78). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/PSADecisionMatrixPanel.swift](../../EVA/Epoching/PSADecisionMatrixPanel.swift#L112) | 4/5 | 189 | S | `synchronizeVisibility` is the largest detected routine (~40 lines, L112). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/PSAEpochingViews.swift](../../EVA/Epoching/PSAEpochingViews.swift#L1841) | 1/5 | 2,983 | S | `applyPSACore` is the largest detected routine (~234 lines, L1841). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Epoching/PSAGlobalBadChannelInterpolator.swift](../../EVA/Epoching/PSAGlobalBadChannelInterpolator.swift#L37) | 4/5 | 142 | S | `interpolate` is the largest detected routine (~64 lines, L37). Relatively localized scope. | Add the input/output contract and edge cases for `interpolate`; preserve straightforward code. | — |
| [EVA/Epoching/PSAWaveformDecisionControls.swift](../../EVA/Epoching/PSAWaveformDecisionControls.swift#L16) | 4/5 | 55 | S | `var body` is the largest detected routine (~34 lines, L16). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/RegexPatternLibrary.swift](../../EVA/Epoching/RegexPatternLibrary.swift#L99) | 4/5 | 239 | S | `suggest` is the largest detected routine (~44 lines, L99). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `suggest`; preserve straightforward code. | — |
| [EVA/Epoching/SingleTrialAnalysisViewModel.swift](../../EVA/Epoching/SingleTrialAnalysisViewModel.swift#L375) | 4/5 | 417 | S | `resetForClose` is the largest detected routine (~42 lines, L375). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/SingleTrialAnalysisViews.swift](../../EVA/Epoching/SingleTrialAnalysisViews.swift#L1579) | 1/5 | 4,867 | C | 4,867 lines contain the WaveformView bridge, sheet state, analysis actions and many result panels; the header describes only the initial slice. | Separate the bridge, analysis coordinator, result panels and export actions; write a state/input/output map before moving code. | **Expanded comments complete** |
| [EVA/Epoching/SingleTrialAnalyzer.swift](../../EVA/Epoching/SingleTrialAnalyzer.swift#L147) | 4/5 | 403 | S | `analyze` is the largest detected routine (~90 lines, L147). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `analyze`; preserve straightforward code. | — |
| [EVA/Epoching/TopoFilmstripView.swift](../../EVA/Epoching/TopoFilmstripView.swift#L23) | 4/5 | 182 | S | `averagesFilmstripPane` is the largest detected routine (~83 lines, L23). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/TrialAlignmentMetrics.swift](../../EVA/Epoching/TrialAlignmentMetrics.swift#L209) | 4/5 | 435 | S | `affineFit` is the largest detected routine (~110 lines, L209). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `affineFit`; preserve straightforward code. | — |
| [EVA/Epoching/TrialChannelResidualAnalyzer.swift](../../EVA/Epoching/TrialChannelResidualAnalyzer.swift#L69) | 4/5 | 221 | S | `analyze` is the largest detected routine (~103 lines, L69). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `analyze`; preserve straightforward code. | — |
| [EVA/Epoching/TrialDiagnosticsDashboard.swift](../../EVA/Epoching/TrialDiagnosticsDashboard.swift#L146) | 4/5 | 538 | S | `summary` is the largest detected routine (~32 lines, L146). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/TrialDiagnosticsViews.swift](../../EVA/Epoching/TrialDiagnosticsViews.swift#L303) | 3/5 | 1,351 | S | `var body` is the largest detected routine (~116 lines, L303). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/Epoching/TrialDriftStatistics.swift](../../EVA/Epoching/TrialDriftStatistics.swift#L327) | 4/5 | 365 | S | `betaContinuedFraction` is the largest detected routine (~38 lines, L327). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `betaContinuedFraction`; preserve straightforward code. | — |
| [EVA/Epoching/TrialExclusionResolver.swift](../../EVA/Epoching/TrialExclusionResolver.swift#L356) | 4/5 | 428 | S | `resolve` is the largest detected routine (~35 lines, L356). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `resolve`; preserve straightforward code. | — |
| [EVA/Epoching/TrialSelectionAnalyzer.swift](../../EVA/Epoching/TrialSelectionAnalyzer.swift#L255) | 4/5 | 320 | S | `evaluate` is the largest detected routine (~52 lines, L255). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `evaluate`; preserve straightforward code. | — |
| [EVA/Epoching/TrialSelectionViews.swift](../../EVA/Epoching/TrialSelectionViews.swift#L321) | 4/5 | 408 | S | `var body` is the largest detected routine (~87 lines, L321). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Epoching/TrialSimilarityAnalyzer.swift](../../EVA/Epoching/TrialSimilarityAnalyzer.swift#L258) | 4/5 | 568 | S | `analyze` is the largest detected routine (~139 lines, L258). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `analyze`; preserve straightforward code. | — |

<a id="evafiltering"></a>
## EVA/Filtering

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Filtering/EEGSignalFilter.swift](../../EVA/Filtering/EEGSignalFilter.swift#L270) | 2/5 | 1,465 | C | Several filter families and configuration types share 1,465 lines; bandPass has a long parameter list and roughly 199-line body. | Document units, phase/padding and parameter interactions; group configuration and separate design from application. | **Expanded comments complete** |
| [EVA/Filtering/EllipticFilterDesign.swift](../../EVA/Filtering/EllipticFilterDesign.swift#L28) | 4/5 | 298 | S | `sections` is the largest detected routine (~47 lines, L28). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `sections`; preserve straightforward code. | — |
| [EVA/Filtering/FilterViewModel.swift](../../EVA/Filtering/FilterViewModel.swift#L527) | 3/5 | 1,007 | S | `apply` is the largest detected routine (~219 lines, L527). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. Replace missing REFACTOR.md references. | Initial focused comments |
| [EVA/Filtering/FilteringViews.swift](../../EVA/Filtering/FilteringViews.swift#L139) | 2/5 | 1,107 | S | `filterPopover` is the largest detected routine (~398 lines, L139). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Filtering/Rereferencing.swift](../../EVA/Filtering/Rereferencing.swift#L149) | 4/5 | 187 | S | `parameters` is the largest detected routine (~15 lines, L149). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `parameters`; preserve straightforward code. Replace missing REWIND.md references. | — |

<a id="evagradient"></a>
## EVA/Gradient

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Gradient/GradientAAS.swift](../../EVA/Gradient/GradientAAS.swift#L434) | 3/5 | 644 | S | `buildPlans` is the largest detected routine (~61 lines, L434). Reading demands: unsafe-memory APIs, numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Gradient/GradientANC.swift](../../EVA/Gradient/GradientANC.swift#L94) | 4/5 | 183 | S | `apply` is the largest detected routine (~89 lines, L94). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/GradientAcceleration.swift](../../EVA/Gradient/GradientAcceleration.swift#L408) | 4/5 | 696 | S | `buildTemplates` is the largest detected routine (~78 lines, L408). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Gradient/GradientCleanroomKernels.metal](../../EVA/Gradient/GradientCleanroomKernels.metal#L97) | 4/5 | 446 | S | `gcrExtractEpochs` is the largest detected routine (~51 lines, L97). Reading demands: numeric/GPU primitives. | Document every buffer shape, index mapping, thread responsibility and matching CPU operation. | — |
| [EVA/Gradient/GradientCorrectionTypes.swift](../../EVA/Gradient/GradientCorrectionTypes.swift#L505) | 4/5 | 508 | S | `permitsWindow` is the largest detected routine (~3 lines, L505). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/GradientCoverage.swift](../../EVA/Gradient/GradientCoverage.swift#L276) | 4/5 | 369 | S | `from` is the largest detected routine (~60 lines, L276). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/GradientDonorSelection.swift](../../EVA/Gradient/GradientDonorSelection.swift#L154) | 4/5 | 402 | S | `motionInformedDonorVolumes` is the largest detected routine (~69 lines, L154). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Gradient/GradientEpochAligner.swift](../../EVA/Gradient/GradientEpochAligner.swift#L155) | 3/5 | 353 | S | `align` is the largest detected routine (~121 lines, L155). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Gradient/GradientEpochLayout.swift](../../EVA/Gradient/GradientEpochLayout.swift#L139) | 4/5 | 263 | S | `build` is the largest detected routine (~124 lines, L139). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/GradientFilters.swift](../../EVA/Gradient/GradientFilters.swift#L77) | 4/5 | 157 | S | `highPassZeroPhase` is the largest detected routine (~40 lines, L77). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/GradientMetalBackend.swift](../../EVA/Gradient/GradientMetalBackend.swift#L684) | 3/5 | 771 | S | `assembleCorrection` is the largest detected routine (~72 lines, L684). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Gradient/GradientOBS.swift](../../EVA/Gradient/GradientOBS.swift#L171) | 4/5 | 285 | S | `computeBasis` is the largest detected routine (~99 lines, L171). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/GradientRunGrade.swift](../../EVA/Gradient/GradientRunGrade.swift#L120) | 4/5 | 424 | S | `measure` is the largest detected routine (~55 lines, L120). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/GradientSincResampler.swift](../../EVA/Gradient/GradientSincResampler.swift#L62) | 4/5 | 177 | S | `upsample` is the largest detected routine (~50 lines, L62). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/GradientTemplateCorrector.swift](../../EVA/Gradient/GradientTemplateCorrector.swift#L802) | 2/5 | 1,103 | S | `applyOBS` is the largest detected routine (~153 lines, L802). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | **Expanded comments complete** |
| [EVA/Gradient/GradientTimingCheck.swift](../../EVA/Gradient/GradientTimingCheck.swift#L100) | 3/5 | 169 | S | `measure` is the largest detected routine (~69 lines, L100). Reading demands: asynchronous control flow, numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Gradient/GradientViewModel.swift](../../EVA/Gradient/GradientViewModel.swift#L1142) | 2/5 | 1,675 | C | Sections explain settings, but 1,675 lines combine configuration, result state, serialization and asynchronous correction. | Document parameter/result ownership and the apply lifecycle; extract run-input assembly and settings serialization. | **Expanded comments complete** |
| [EVA/Gradient/LocalTemplateArtifactCorrector.swift](../../EVA/Gradient/LocalTemplateArtifactCorrector.swift#L194) | 3/5 | 1,101 | S | `correct` is the largest detected routine (~201 lines, L194). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Gradient/LocalTemplateKernels.metal](../../EVA/Gradient/LocalTemplateKernels.metal#L184) | 4/5 | 248 | S | `ltAccumulateAndSubtract` is the largest detected routine (~65 lines, L184). Reading demands: numeric/GPU primitives. | Document every buffer shape, index mapping, thread responsibility and matching CPU operation. | — |
| [EVA/Gradient/LocalTemplateMetalBackend.swift](../../EVA/Gradient/LocalTemplateMetalBackend.swift#L165) | 4/5 | 255 | S | `correct` is the largest detected routine (~90 lines, L165). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Gradient/MRIGradientArtifactViews.swift](../../EVA/Gradient/MRIGradientArtifactViews.swift#L49) | 2/5 | 1,200 | S | `mriPopover` is the largest detected routine (~309 lines, L49). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Gradient/MotionConfigView.swift](../../EVA/Gradient/MotionConfigView.swift#L58) | 3/5 | 528 | S | `var body` is the largest detected routine (~73 lines, L58). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Gradient/MotionParameters.swift](../../EVA/Gradient/MotionParameters.swift#L227) | 4/5 | 348 | S | `parse` is the largest detected routine (~61 lines, L227). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Gradient/TRSpacing.swift](../../EVA/Gradient/TRSpacing.swift#L73) | 4/5 | 80 | S | `from` is the largest detected routine (~7 lines, L73). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |

<a id="evahealth"></a>
## EVA/Health

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Health/ChannelHealthAnalyzer.swift](../../EVA/Health/ChannelHealthAnalyzer.swift#L1062) | 2/5 | 1,405 | S | `result` is the largest detected routine (~146 lines, L1062). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. Separate major responsibilities into focused files. | **Expanded comments complete** |
| [EVA/Health/ChannelHealthDetailViews.swift](../../EVA/Health/ChannelHealthDetailViews.swift#L69) | 3/5 | 695 | S | `runWaveletChannelGoodness` is the largest detected routine (~115 lines, L69). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Health/ChannelHealthTrainingExport.swift](../../EVA/Health/ChannelHealthTrainingExport.swift#L78) | 4/5 | 130 | S | `make` is the largest detected routine (~52 lines, L78). Relatively localized scope. | Add the input/output contract and edge cases for `make`; preserve straightforward code. | — |
| [EVA/Health/ChannelHealthViewModel.swift](../../EVA/Health/ChannelHealthViewModel.swift#L49) | 4/5 | 57 | S | `resetForClose` is the largest detected routine (~8 lines, L49). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |
| [EVA/Health/ChannelRelationshipAnalyzer.swift](../../EVA/Health/ChannelRelationshipAnalyzer.swift#L127) | 3/5 | 631 | S | `analyzeDetailed` is the largest detected routine (~166 lines, L127). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Health/HealthDetailViews.swift](../../EVA/Health/HealthDetailViews.swift#L631) | 3/5 | 1,022 | S | `var body` is the largest detected routine (~133 lines, L631). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. Replace missing REFACTOR.md references. | — |
| [EVA/Health/HealthScoring.swift](../../EVA/Health/HealthScoring.swift#L61) | 4/5 | 71 | C | Short scoring helpers are readable, but clipping cutoffs and grade thresholds are unexplained constants. | Document score direction/range and threshold provenance; name fixed thresholds without changing their values. | Initial focused comments |
| [EVA/Health/SegmentGoodnessSettings.swift](../../EVA/Health/SegmentGoodnessSettings.swift#L66) | 4/5 | 195 | S | `var body` is the largest detected routine (~54 lines, L66). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Health/SegmentHealthAnalyzer.swift](../../EVA/Health/SegmentHealthAnalyzer.swift#L610) | 3/5 | 881 | S | `result` is the largest detected routine (~171 lines, L610). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Health/SegmentHealthDetailViews.swift](../../EVA/Health/SegmentHealthDetailViews.swift#L373) | 3/5 | 516 | S | `saveSegmentHealthMetricsJSON` is the largest detected routine (~105 lines, L373). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Health/SegmentHealthTrainingExport.swift](../../EVA/Health/SegmentHealthTrainingExport.swift#L97) | 4/5 | 149 | S | `make` is the largest detected routine (~52 lines, L97). Relatively localized scope. | Add the input/output contract and edge cases for `make`; preserve straightforward code. | — |
| [EVA/Health/SegmentHealthViewModel.swift](../../EVA/Health/SegmentHealthViewModel.swift#L68) | 4/5 | 90 | S | `clearAnalysis` is the largest detected routine (~16 lines, L68). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |

<a id="evahelp"></a>
## EVA/Help

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Help/MarkdownDocument.swift](../../EVA/Help/MarkdownDocument.swift#L238) | 4/5 | 325 | S | `table` is the largest detected routine (~67 lines, L238). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `table`; preserve straightforward code. | — |
| [EVA/Help/MarkdownView.swift](../../EVA/Help/MarkdownView.swift#L58) | 4/5 | 217 | S | `var body` is the largest detected routine (~43 lines, L58). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Help/ReleaseNotesCatalog.swift](../../EVA/Help/ReleaseNotesCatalog.swift#L114) | 4/5 | 164 | S | `splitFrontMatter` is the largest detected routine (~36 lines, L114). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `splitFrontMatter`; preserve straightforward code. | — |
| [EVA/Help/ReleaseNotesView.swift](../../EVA/Help/ReleaseNotesView.swift#L30) | 4/5 | 130 | S | `var body` is the largest detected routine (~24 lines, L30). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |

<a id="evaica"></a>
## EVA/ICA

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/ICA/BCGComponentLabeller.swift](../../EVA/ICA/BCGComponentLabeller.swift#L156) | 3/5 | 284 | S | `features` is the largest detected routine (~60 lines, L156). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/ICA/ICAArtifactDetector.swift](../../EVA/ICA/ICAArtifactDetector.swift#L1276) | 1/5 | 1,946 | C | Multiple solvers and reconstruction share a 1,946-line file; picardFloat alone spans roughly 242 lines with flat matrix workspaces. | Split solver implementations behind the existing entry point; add matrix dimension tables and equation-to-variable mappings. | **Expanded comments complete** |
| [EVA/ICA/ICAComponentAutoLabeler.swift](../../EVA/ICA/ICAComponentAutoLabeler.swift#L296) | 3/5 | 479 | S | `powerSpectrum` is the largest detected routine (~111 lines, L296). Reading demands: unsafe-memory APIs, numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/ICA/ICAComponentLabellerBenchmark.swift](../../EVA/ICA/ICAComponentLabellerBenchmark.swift#L48) | 3/5 | 198 | S | `evaluate` is the largest detected routine (~57 lines, L48). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/ICA/ICAComponentRemoval.swift](../../EVA/ICA/ICAComponentRemoval.swift#L55) | 4/5 | 136 | S | `apply` is the largest detected routine (~23 lines, L55). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. Replace missing REWIND.md references. | — |
| [EVA/ICA/ICADebugReportViews.swift](../../EVA/ICA/ICADebugReportViews.swift#L35) | 3/5 | 205 | S | `icaDebugReport` is the largest detected routine (~100 lines, L35). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/ICA/ICAExplorationViews.swift](../../EVA/ICA/ICAExplorationViews.swift#L33) | 2/5 | 832 | S | `icaSheet` is the largest detected routine (~270 lines, L33). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/ICA/ICAReplayPayload.swift](../../EVA/ICA/ICAReplayPayload.swift#L366) | 3/5 | 405 | S | `activationSignal` is the largest detected routine (~39 lines, L366). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. Replace missing REWIND.md references. | — |
| [EVA/ICA/ICARunGrade.swift](../../EVA/ICA/ICARunGrade.swift#L147) | 4/5 | 182 | S | `removedMetric` is the largest detected routine (~22 lines, L147). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/ICA/ICAViewModel.swift](../../EVA/ICA/ICAViewModel.swift#L116) | 4/5 | 145 | S | `apply` is the largest detected routine (~15 lines, L116). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |
| [EVA/ICA/ICLabelClassifier.swift](../../EVA/ICA/ICLabelClassifier.swift#L248) | 3/5 | 407 | S | `relativePSD` is the largest detected routine (~56 lines, L248). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |

<a id="evaio"></a>
## EVA/IO

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/IO/BDFSignalReader.swift](../../EVA/IO/BDFSignalReader.swift#L19) | 4/5 | 151 | S | `load` is the largest detected routine (~60 lines, L19). Reading demands: asynchronous control flow. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVA/IO/ChannelExportViews.swift](../../EVA/IO/ChannelExportViews.swift#L168) | 4/5 | 265 | S | `channelExportEventSeries` is the largest detected routine (~44 lines, L168). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/DatasetInfoSheet.swift](../../EVA/IO/DatasetInfoSheet.swift#L78) | 4/5 | 220 | S | `var body` is the largest detected routine (~77 lines, L78). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/FigureExport.swift](../../EVA/IO/FigureExport.swift#L81) | 4/5 | 205 | S | `raster` is the largest detected routine (~28 lines, L81). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/FigureExportBasket.swift](../../EVA/IO/FigureExportBasket.swift#L171) | 4/5 | 229 | S | `exportContactSheet` is the largest detected routine (~58 lines, L171). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/FigureExportBasketView.swift](../../EVA/IO/FigureExportBasketView.swift#L25) | 4/5 | 165 | S | `var body` is the largest detected routine (~98 lines, L25). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/MFFExportFlowViews.swift](../../EVA/IO/MFFExportFlowViews.swift#L375) | 3/5 | 597 | S | `currentProcessingScript` is the largest detected routine (~140 lines, L375). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/MFFExportWriter.swift](../../EVA/IO/MFFExportWriter.swift#L20) | 4/5 | 109 | S | `write` is the largest detected routine (~89 lines, L20). Reading demands: asynchronous control flow. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVA/IO/MFFRecording.swift](../../EVA/IO/MFFRecording.swift#L333) | 3/5 | 654 | S | `movePhysioChannelToEEG` is the largest detected routine (~93 lines, L333). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/MFFSignalSplitter.swift](../../EVA/IO/MFFSignalSplitter.swift#L102) | 3/5 | 214 | S | `slice` is the largest detected routine (~45 lines, L102). Relatively localized scope. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVA/IO/PhysioImportViews.swift](../../EVA/IO/PhysioImportViews.swift#L80) | 4/5 | 396 | S | `var body` is the largest detected routine (~37 lines, L80). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/PhysioPaneViews.swift](../../EVA/IO/PhysioPaneViews.swift#L308) | 4/5 | 397 | S | `physioChannelContextMenu` is the largest detected routine (~73 lines, L308). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/IO/PhysioTextImporter.swift](../../EVA/IO/PhysioTextImporter.swift#L60) | 4/5 | 173 | S | `parse` is the largest detected routine (~56 lines, L60). Existing explanatory comments provide context. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVA/IO/SignalImportReader.swift](../../EVA/IO/SignalImportReader.swift#L769) | 3/5 | 2,000 | S | `load` is the largest detected routine (~132 lines, L769). Reading demands: asynchronous control flow. | Explain format fields, units and error/fallback behavior; give one decode/encode example. Separate major responsibilities into focused files. | — |

<a id="evamarkers"></a>
## EVA/Markers

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Markers/UserMarker.swift](../../EVA/Markers/UserMarker.swift#L1) | 4/5 | 35 | S | Declarations include `UserMarker`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |

<a id="evapipeline"></a>
## EVA/Pipeline

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Pipeline/BatchCheckpoint.swift](../../EVA/Pipeline/BatchCheckpoint.swift#L339) | 3/5 | 495 | S | `publish` is the largest detected routine (~83 lines, L339). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Pipeline/BatchController.swift](../../EVA/Pipeline/BatchController.swift#L197) | 4/5 | 257 | S | `startHeadless` is the largest detected routine (~60 lines, L197). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Pipeline/BatchDecisionPolicy.swift](../../EVA/Pipeline/BatchDecisionPolicy.swift#L32) | 4/5 | 91 | S | `apply` is the largest detected routine (~28 lines, L32). Relatively localized scope. | Add the input/output contract and edge cases for `apply`; preserve straightforward code. | — |
| [EVA/Pipeline/BatchPrefixPlanner.swift](../../EVA/Pipeline/BatchPrefixPlanner.swift#L76) | 4/5 | 206 | S | `plan` is the largest detected routine (~96 lines, L76). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `plan`; preserve straightforward code. | — |
| [EVA/Pipeline/BatchPreflight.swift](../../EVA/Pipeline/BatchPreflight.swift#L66) | 4/5 | 184 | S | `inspect` is the largest detected routine (~43 lines, L66). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Pipeline/BatchSetupSheet.swift](../../EVA/Pipeline/BatchSetupSheet.swift#L44) | 3/5 | 803 | S | `var body` is the largest detected routine (~70 lines, L44). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/Pipeline/ChannelDecisionReplaySheet.swift](../../EVA/Pipeline/ChannelDecisionReplaySheet.swift#L111) | 4/5 | 172 | S | `var body` is the largest detected routine (~52 lines, L111). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Pipeline/ChannelDecisionSteps.swift](../../EVA/Pipeline/ChannelDecisionSteps.swift#L76) | 4/5 | 164 | S | `steps` is the largest detected routine (~32 lines, L76). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `steps`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/Pipeline/CleaningVarianceLedger.swift](../../EVA/Pipeline/CleaningVarianceLedger.swift#L49) | 4/5 | 70 | S | `record` is the largest detected routine (~4 lines, L49). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Pipeline/EVAHistory.swift](../../EVA/Pipeline/EVAHistory.swift#L403) | 4/5 | 700 | S | `adoptReplacingAbandonedFuture` is the largest detected routine (~51 lines, L403). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. Replace missing REWIND.md references. | — |
| [EVA/Pipeline/EVAProcessLog.swift](../../EVA/Pipeline/EVAProcessLog.swift#L31) | 4/5 | 75 | S | `append` is the largest detected routine (~6 lines, L31). Relatively localized scope. | Add the input/output contract and edge cases for `append`; preserve straightforward code. | — |
| [EVA/Pipeline/HeadlessBatchProcessor.swift](../../EVA/Pipeline/HeadlessBatchProcessor.swift#L37) | 4/5 | 155 | S | `process` is the largest detected routine (~118 lines, L37). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Pipeline/HistoryStepSummary.swift](../../EVA/Pipeline/HistoryStepSummary.swift#L62) | 4/5 | 252 | S | `subtitle` is the largest detected routine (~119 lines, L62). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `subtitle`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/Pipeline/LatestOnlyRunner.swift](../../EVA/Pipeline/LatestOnlyRunner.swift#L78) | 4/5 | 106 | C | Explains stale results and cancellation ownership, with an exhaustive Outcome enum. Generic async closures and actor isolation still need Swift familiarity. | Add a tiny call-site example and a run A/run B timeline; preserve the ownership rationale. | Initial focused comments |
| [EVA/Pipeline/OperationProgress.swift](../../EVA/Pipeline/OperationProgress.swift#L41) | 4/5 | 84 | S | `updating` is the largest detected routine (~22 lines, L41). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `updating`; preserve straightforward code. | — |
| [EVA/Pipeline/OperationProgressCenter.swift](../../EVA/Pipeline/OperationProgressCenter.swift#L57) | 4/5 | 74 | S | `set` is the largest detected routine (~12 lines, L57). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REWIND.md references. | — |
| [EVA/Pipeline/PayloadConsistency.swift](../../EVA/Pipeline/PayloadConsistency.swift#L93) | 4/5 | 121 | S | `findings` is the largest detected routine (~16 lines, L93). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `findings`; preserve straightforward code. | — |
| [EVA/Pipeline/PipelineInvalidation.swift](../../EVA/Pipeline/PipelineInvalidation.swift#L69) | 4/5 | 220 | S | `epochsAndDerived` is the largest detected routine (~37 lines, L69). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `epochsAndDerived`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/Pipeline/PipelineSnapshot.swift](../../EVA/Pipeline/PipelineSnapshot.swift#L191) | 4/5 | 276 | S | `restore` is the largest detected routine (~85 lines, L191). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `restore`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/Pipeline/PipelineStageToggles.swift](../../EVA/Pipeline/PipelineStageToggles.swift#L67) | 4/5 | 130 | S | `revertWaveletReduction` is the largest detected routine (~22 lines, L67). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `revertWaveletReduction`; preserve straightforward code. Replace missing REWIND.md references. | — |
| [EVA/Pipeline/ProcessingAuditLog.swift](../../EVA/Pipeline/ProcessingAuditLog.swift#L41) | 4/5 | 135 | S | `lines` is the largest detected routine (~80 lines, L41). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `lines`; preserve straightforward code. | — |
| [EVA/Pipeline/ProcessingCore.swift](../../EVA/Pipeline/ProcessingCore.swift#L117) | 2/5 | 602 | C | Strong comments explain replay ordering and payload ownership, but applyAutoSteps spans roughly 440 lines. | Extract per-operation handlers while retaining one visible sequencer; document stop, skip and completion outcomes. | **Expanded comments complete** |
| [EVA/Pipeline/ProcessingDefaults.swift](../../EVA/Pipeline/ProcessingDefaults.swift#L398) | 4/5 | 460 | S | `restoreDefaults` is the largest detected routine (~17 lines, L398). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |
| [EVA/Pipeline/ProcessingQueue.swift](../../EVA/Pipeline/ProcessingQueue.swift#L48) | 4/5 | 61 | S | `run` is the largest detected routine (~13 lines, L48). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Pipeline/ProgressBridge.swift](../../EVA/Pipeline/ProgressBridge.swift#L27) | 4/5 | 58 | S | `make` is the largest detected routine (~19 lines, L27). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Pipeline/RecordingHistoryModel.swift](../../EVA/Pipeline/RecordingHistoryModel.swift#L571) | 4/5 | 718 | S | `railNodes` is the largest detected routine (~37 lines, L571). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. Replace missing REWIND.md references. | — |
| [EVA/Pipeline/ReplayCompatibility.swift](../../EVA/Pipeline/ReplayCompatibility.swift#L90) | 4/5 | 127 | S | `check` is the largest detected routine (~37 lines, L90). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `check`; preserve straightforward code. | — |
| [EVA/Pipeline/ReplayConfigSheet.swift](../../EVA/Pipeline/ReplayConfigSheet.swift#L160) | 4/5 | 327 | S | `var body` is the largest detected routine (~70 lines, L160). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Pipeline/ReplayController.swift](../../EVA/Pipeline/ReplayController.swift#L171) | 4/5 | 294 | S | `configure` is the largest detected routine (~30 lines, L171). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Pipeline/ReplaySettingsRestore.swift](../../EVA/Pipeline/ReplaySettingsRestore.swift#L100) | 4/5 | 130 | S | `settings` is the largest detected routine (~30 lines, L100). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `settings`; preserve straightforward code. | — |
| [EVA/Pipeline/StepQuality.swift](../../EVA/Pipeline/StepQuality.swift#L1) | 4/5 | 92 | S | Declarations include `RunGrade`, `QualityMetric`, `StepQuality`. Existing explanatory comments provide context. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |

<a id="evarhythmicity"></a>
## EVA/Rhythmicity

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Rhythmicity/ABBABandTableView.swift](../../EVA/Rhythmicity/ABBABandTableView.swift#L74) | 3/5 | 223 | S | `var body` is the largest detected routine (~56 lines, L74). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Rhythmicity/ABBAEngine.swift](../../EVA/Rhythmicity/ABBAEngine.swift#L13) | 3/5 | 266 | S | `detectBands` is the largest detected routine (~127 lines, L13). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Rhythmicity/AccelerateFFTComplexCoefficientProvider.swift](../../EVA/Rhythmicity/AccelerateFFTComplexCoefficientProvider.swift#L199) | 3/5 | 408 | S | `coefficients` is the largest detected routine (~134 lines, L199). Reading demands: numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Rhythmicity/AperiodicSpectrumEstimator.swift](../../EVA/Rhythmicity/AperiodicSpectrumEstimator.swift#L155) | 3/5 | 502 | S | `fitPowerLaw` is the largest detected routine (~71 lines, L155). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/ComplexCoefficientProvider.swift](../../EVA/Rhythmicity/ComplexCoefficientProvider.swift#L25) | 4/5 | 178 | S | `coefficients` is the largest detected routine (~81 lines, L25). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/DetectedRhythmicityBandSet.swift](../../EVA/Rhythmicity/DetectedRhythmicityBandSet.swift#L84) | 4/5 | 167 | S | `displayBands` is the largest detected routine (~34 lines, L84). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/IAAFTSurrogateGenerator.swift](../../EVA/Rhythmicity/IAAFTSurrogateGenerator.swift#L113) | 3/5 | 256 | S | `generate` is the largest detected routine (~97 lines, L113). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/LAVIEngine.swift](../../EVA/Rhythmicity/LAVIEngine.swift#L73) | 2/5 | 856 | C | analyzeOnce spans roughly 308 lines and combines backend selection, finite-run selection, reduction, significance and progress with little local explanation. | Add a staged algorithm outline, then extract backend resolution and per-channel analysis without changing numerical order. | **Expanded comments complete** |
| [EVA/Rhythmicity/LAVISignificanceProvider.swift](../../EVA/Rhythmicity/LAVISignificanceProvider.swift#L67) | 3/5 | 872 | S | `resolve` is the largest detected routine (~222 lines, L67). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/LAVISpectrumView.swift](../../EVA/Rhythmicity/LAVISpectrumView.swift#L42) | 3/5 | 226 | S | `var body` is the largest detected routine (~26 lines, L42). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Rhythmicity/RhythmicBurstDetector.swift](../../EVA/Rhythmicity/RhythmicBurstDetector.swift#L182) | 3/5 | 688 | S | `detect` is the largest detected routine (~160 lines, L182). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/RhythmicBurstExport.swift](../../EVA/Rhythmicity/RhythmicBurstExport.swift#L116) | 4/5 | 179 | S | `manifest` is the largest detected routine (~53 lines, L116). Little explanatory commenting was detected. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/RhythmicBurstRunner.swift](../../EVA/Rhythmicity/RhythmicBurstRunner.swift#L24) | 3/5 | 229 | S | `analyze` is the largest detected routine (~196 lines, L24). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/RhythmicBurstView.swift](../../EVA/Rhythmicity/RhythmicBurstView.swift#L179) | 3/5 | 291 | S | `burstOverlay` is the largest detected routine (~33 lines, L179). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Rhythmicity/RhythmicityDataSelection.swift](../../EVA/Rhythmicity/RhythmicityDataSelection.swift#L72) | 4/5 | 119 | S | `removing` is the largest detected routine (~33 lines, L72). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/RhythmicityExplorerView.swift](../../EVA/Rhythmicity/RhythmicityExplorerView.swift#L717) | 3/5 | 943 | S | `topography` is the largest detected routine (~39 lines, L717). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/Rhythmicity/RhythmicityExplorerViewModel.swift](../../EVA/Rhythmicity/RhythmicityExplorerViewModel.swift#L494) | 1/5 | 1,666 | C | A 1,666-line observable object coordinates three analysis modes, context signatures, snapshots and staleness with very little explanatory commenting. | Document the three run lifecycles and stale-result rules first; separate mode state and run orchestration next. | **Expanded comments complete** |
| [EVA/Rhythmicity/RhythmicityExport.swift](../../EVA/Rhythmicity/RhythmicityExport.swift#L84) | 3/5 | 299 | S | `bundle` is the largest detected routine (~96 lines, L84). Little explanatory commenting was detected. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/RhythmicityHelp.swift](../../EVA/Rhythmicity/RhythmicityHelp.swift#L108) | 4/5 | 154 | S | `var body` is the largest detected routine (~39 lines, L108). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Rhythmicity/RhythmicityKernels.metal](../../EVA/Rhythmicity/RhythmicityKernels.metal#L118) | 4/5 | 171 | S | `rhythmicityAccumulateLAVI` is the largest detected routine (~54 lines, L118). Reading demands: numeric/GPU primitives. | Document every buffer shape, index mapping, thread responsibility and matching CPU operation. | — |
| [EVA/Rhythmicity/RhythmicityMetalBackend.swift](../../EVA/Rhythmicity/RhythmicityMetalBackend.swift#L321) | 3/5 | 558 | S | `laviProfiles` is the largest detected routine (~180 lines, L321). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Rhythmicity/RhythmicityModels.swift](../../EVA/Rhythmicity/RhythmicityModels.swift#L172) | 3/5 | 460 | S | `entireRecording` is the largest detected routine (~18 lines, L172). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Rhythmicity/RhythmicityPersistence.swift](../../EVA/Rhythmicity/RhythmicityPersistence.swift#L107) | 3/5 | 366 | S | `load` is the largest detected routine (~36 lines, L107). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/RhythmicityPreset.swift](../../EVA/Rhythmicity/RhythmicityPreset.swift#L44) | 4/5 | 61 | S | `paperLAVI2026` is the largest detected routine (~9 lines, L44). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/WTPLEngine.swift](../../EVA/Rhythmicity/WTPLEngine.swift#L16) | 3/5 | 283 | S | `analyze` is the largest detected routine (~153 lines, L16). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/WTPLExport.swift](../../EVA/Rhythmicity/WTPLExport.swift#L69) | 3/5 | 220 | S | `scalarCSVRows` is the largest detected routine (~55 lines, L69). Little explanatory commenting was detected. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/WTPLModels.swift](../../EVA/Rhythmicity/WTPLModels.swift#L1) | 4/5 | 109 | S | Declarations include `WTPLBaselineSpec`, `WTPLResult`, `FrequencyTimeMaps`. Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Rhythmicity/WTPLView.swift](../../EVA/Rhythmicity/WTPLView.swift#L137) | 3/5 | 230 | S | `makeRender` is the largest detected routine (~28 lines, L137). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |

<a id="evasimulation"></a>
## EVA/Simulation

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Simulation/SimulatorController.swift](../../EVA/Simulation/SimulatorController.swift#L303) | 4/5 | 336 | S | `generateGroup` is the largest detected routine (~31 lines, L303). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Simulation/SimulatorRunner.swift](../../EVA/Simulation/SimulatorRunner.swift#L158) | 4/5 | 619 | S | `generate` is the largest detected routine (~85 lines, L158). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `generate`; preserve straightforward code. | — |
| [EVA/Simulation/SimulatorScenarioLibrary.swift](../../EVA/Simulation/SimulatorScenarioLibrary.swift#L38) | 4/5 | 49 | S | `load` is the largest detected routine (~11 lines, L38). Relatively localized scope. | Add the input/output contract and edge cases for `load`; preserve straightforward code. | — |

<a id="evatimefrequency"></a>
## EVA/TimeFrequency

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/TimeFrequency/ComplexMorlet.swift](../../EVA/TimeFrequency/ComplexMorlet.swift#L50) | 4/5 | 134 | S | `kernel` is the largest detected routine (~47 lines, L50). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/TimeFrequency/DPSS.swift](../../EVA/TimeFrequency/DPSS.swift#L85) | 4/5 | 180 | S | `topEigenvectors` is the largest detected routine (~50 lines, L85). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/TimeFrequency/Multitaper.swift](../../EVA/TimeFrequency/Multitaper.swift#L30) | 4/5 | 73 | S | `wavelets` is the largest detected routine (~43 lines, L30). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/TimeFrequency/TimeFrequencyEngine.swift](../../EVA/TimeFrequency/TimeFrequencyEngine.swift#L106) | 4/5 | 285 | S | `multitaperBin` is the largest detected routine (~44 lines, L106). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/TimeFrequency/TimeFrequencyExport.swift](../../EVA/TimeFrequency/TimeFrequencyExport.swift#L452) | 3/5 | 612 | S | `scalarCSVRows` is the largest detected routine (~85 lines, L452). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/TimeFrequency/TimeFrequencyHeatmap.swift](../../EVA/TimeFrequency/TimeFrequencyHeatmap.swift#L223) | 3/5 | 355 | S | `drawRhythmicityBands` is the largest detected routine (~49 lines, L223). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/TimeFrequency/TimeFrequencyKernels.metal](../../EVA/TimeFrequency/TimeFrequencyKernels.metal#L15) | 3/5 | 50 | C | The thread-to-coordinate mapping is explained and the kernel is short; buffer order, complex phase and normalization still need context. | Document buffer shapes, flattening formulas, zero-magnitude policy and the matching Swift dispatch code. | — |
| [EVA/TimeFrequency/TimeFrequencyMetalBackend.swift](../../EVA/TimeFrequency/TimeFrequencyMetalBackend.swift#L47) | 4/5 | 120 | S | `decompose` is the largest detected routine (~55 lines, L47). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/TimeFrequency/TimeFrequencyModels.swift](../../EVA/TimeFrequency/TimeFrequencyModels.swift#L83) | 4/5 | 148 | S | `logSpaced` is the largest detected routine (~18 lines, L83). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/TimeFrequency/TimeFrequencyOverviewView.swift](../../EVA/TimeFrequency/TimeFrequencyOverviewView.swift#L217) | 3/5 | 986 | S | `var body` is the largest detected routine (~78 lines, L217). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/TimeFrequency/TimeFrequencyTrials.swift](../../EVA/TimeFrequency/TimeFrequencyTrials.swift#L45) | 4/5 | 109 | S | `stack` is the largest detected routine (~38 lines, L45). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/TimeFrequency/TimeFrequencyView.swift](../../EVA/TimeFrequency/TimeFrequencyView.swift#L483) | 3/5 | 883 | S | `buildOverview` is the largest detected routine (~74 lines, L483). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |

<a id="evatrials"></a>
## EVA/Trials

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Trials/CWTRidgePipeline.swift](../../EVA/Trials/CWTRidgePipeline.swift#L107) | 4/5 | 268 | S | `run` is the largest detected routine (~110 lines, L107). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Trials/ClusterFormation.swift](../../EVA/Trials/ClusterFormation.swift#L303) | 3/5 | 513 | S | `tfceScores` is the largest detected routine (~110 lines, L303). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Trials/ClusterPermutationAnalyzer.swift](../../EVA/Trials/ClusterPermutationAnalyzer.swift#L465) | 2/5 | 628 | S | `runPermutations` is the largest detected routine (~121 lines, L465). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | **Expanded comments complete** |
| [EVA/Trials/ClusterPermutationFAnalyzer.swift](../../EVA/Trials/ClusterPermutationFAnalyzer.swift#L122) | 3/5 | 444 | S | `analyze` is the largest detected routine (~208 lines, L122). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Trials/ClusterSpatialAdjacency.swift](../../EVA/Trials/ClusterSpatialAdjacency.swift#L85) | 4/5 | 203 | S | `build` is the largest detected routine (~56 lines, L85). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Trials/ClusterStatisticsDistributions.swift](../../EVA/Trials/ClusterStatisticsDistributions.swift#L124) | 4/5 | 186 | S | `betaContinuedFraction` is the largest detected routine (~34 lines, L124). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Trials/ClusterStatisticsRunner.swift](../../EVA/Trials/ClusterStatisticsRunner.swift#L132) | 3/5 | 684 | S | `run` is the largest detected routine (~136 lines, L132). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVA/Trials/ClusterStatisticsViews.swift](../../EVA/Trials/ClusterStatisticsViews.swift#L818) | 2/5 | 1,276 | S | `clusterDetail` is the largest detected routine (~71 lines, L818). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Trials/NonlinearAligner.swift](../../EVA/Trials/NonlinearAligner.swift#L120) | 4/5 | 539 | S | `dtwAlign` is the largest detected routine (~72 lines, L120). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Trials/RIDEAnalyzer.swift](../../EVA/Trials/RIDEAnalyzer.swift#L160) | 2/5 | 884 | C | The header explains S/C/R components, but decompose spans roughly 415 lines of validation, latency setup and iterative decomposition. | Give a staged pseudocode overview and extract initialization, iteration and reconstruction phases. | **Expanded comments complete** |
| [EVA/Trials/WoodyAlignmentAnalyzer.swift](../../EVA/Trials/WoodyAlignmentAnalyzer.swift#L98) | 3/5 | 487 | S | `align` is the largest detected routine (~172 lines, L98). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |

<a id="evawaveform"></a>
## EVA/Waveform

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Waveform/ButterflyPanelViews.swift](../../EVA/Waveform/ButterflyPanelViews.swift#L23) | 3/5 | 772 | S | `butterflyPanel` is the largest detected routine (~190 lines, L23). Reading demands: shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVA/Waveform/EventsPanelView.swift](../../EVA/Waveform/EventsPanelView.swift#L139) | 4/5 | 253 | S | `eventList` is the largest detected routine (~55 lines, L139). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/GFPPlot.swift](../../EVA/Waveform/GFPPlot.swift#L56) | 4/5 | 96 | S | `var body` is the largest detected routine (~40 lines, L56). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/HistoryRailView.swift](../../EVA/Waveform/HistoryRailView.swift#L102) | 4/5 | 408 | S | `var body` is the largest detected routine (~43 lines, L102). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REWIND.md references. | — |
| [EVA/Waveform/HistoryTransportCommands.swift](../../EVA/Waveform/HistoryTransportCommands.swift#L98) | 4/5 | 111 | S | `var body` is the largest detected routine (~13 lines, L98). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/PhysioPaneView.swift](../../EVA/Waveform/PhysioPaneView.swift#L76) | 4/5 | 199 | S | `var body` is the largest detected routine (~52 lines, L76). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/ProcessingStatusPopover.swift](../../EVA/Waveform/ProcessingStatusPopover.swift#L248) | 4/5 | 459 | S | `var body` is the largest detected routine (~52 lines, L248). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REWIND.md references. | — |
| [EVA/Waveform/StatusLogView.swift](../../EVA/Waveform/StatusLogView.swift#L83) | 4/5 | 182 | S | `var body` is the largest detected routine (~40 lines, L83). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REWIND.md references. | — |
| [EVA/Waveform/TopomapPanelView.swift](../../EVA/Waveform/TopomapPanelView.swift#L35) | 4/5 | 70 | S | `var body` is the largest detected routine (~35 lines, L35). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/WaveformAxisViews.swift](../../EVA/Waveform/WaveformAxisViews.swift#L90) | 4/5 | 141 | S | `var body` is the largest detected routine (~31 lines, L90). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/WaveformChannelRows.swift](../../EVA/Waveform/WaveformChannelRows.swift#L193) | 4/5 | 270 | S | `var body` is the largest detected routine (~77 lines, L193). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/WaveformDensityLayout.swift](../../EVA/Waveform/WaveformDensityLayout.swift#L69) | 4/5 | 121 | S | `geometry` is the largest detected routine (~52 lines, L69). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `geometry`; preserve straightforward code. | — |
| [EVA/Waveform/WaveformHistoryRail.swift](../../EVA/Waveform/WaveformHistoryRail.swift#L370) | 3/5 | 713 | S | `reDeriveHistory` is the largest detected routine (~94 lines, L370). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. Replace missing REWIND.md references. | — |
| [EVA/Waveform/WaveformOverlays.swift](../../EVA/Waveform/WaveformOverlays.swift#L60) | 4/5 | 102 | S | `var body` is the largest detected routine (~17 lines, L60). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/WaveformPlotViews.swift](../../EVA/Waveform/WaveformPlotViews.swift#L1396) | 2/5 | 2,031 | S | `var body` is the largest detected routine (~118 lines, L1396). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. Replace missing REFACTOR.md references. | **Expanded comments complete** |
| [EVA/Waveform/WaveformScaleUnits.swift](../../EVA/Waveform/WaveformScaleUnits.swift#L266) | 4/5 | 293 | S | `sensitivityLabel` is the largest detected routine (~14 lines, L266). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `sensitivityLabel`; preserve straightforward code. | — |
| [EVA/Waveform/WaveformSheetHost.swift](../../EVA/Waveform/WaveformSheetHost.swift#L182) | 3/5 | 371 | S | `sheetContent` is the largest detected routine (~182 lines, L182). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REWIND.md references. | — |
| [EVA/Waveform/WaveformSourceFit.swift](../../EVA/Waveform/WaveformSourceFit.swift#L45) | 4/5 | 80 | S | `fitSourceModel` is the largest detected routine (~30 lines, L45). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/WaveformSupportingTypes.swift](../../EVA/Waveform/WaveformSupportingTypes.swift#L893) | 2/5 | 1,519 | S | `buildEpochs` is the largest detected routine (~373 lines, L893). Reading demands: unsafe-memory APIs, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Waveform/WaveformUIModels.swift](../../EVA/Waveform/WaveformUIModels.swift#L143) | 4/5 | 177 | S | `binding` is the largest detected routine (~9 lines, L143). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Waveform/WaveformView.swift](../../EVA/Waveform/WaveformView.swift#L1773) | 1/5 | 3,908 | C | The file itself warns against adding UI/state; 3,908 lines mix gradient method definitions, recording UI and shared orchestration. | Move method/configuration types to their domain, then extract standalone child Views with explicit inputs and actions. | **Expanded comments complete** |

<a id="evawavelet"></a>
## EVA/Wavelet

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVA/Wavelet/CWTRidgeDetector.swift](../../EVA/Wavelet/CWTRidgeDetector.swift#L121) | 4/5 | 333 | S | `detect` is the largest detected routine (~81 lines, L121). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Wavelet/ContinuousWaveletTransform.swift](../../EVA/Wavelet/ContinuousWaveletTransform.swift#L34) | 4/5 | 81 | S | `kernel` is the largest detected routine (~23 lines, L34). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Wavelet/EmpiricalBayesThreshold.swift](../../EVA/Wavelet/EmpiricalBayesThreshold.swift#L264) | 3/5 | 294 | C | Extensive equation-to-code explanations and small helpers are strong, but the prior/posterior vocabulary exceeds introductory CS. | Add a plain-language input/output summary before the derivation and a worked detail-band example; retain the derivation. | Initial focused comments |
| [EVA/Wavelet/MatchedWaveletTemplate.swift](../../EVA/Wavelet/MatchedWaveletTemplate.swift#L34) | 4/5 | 143 | S | `fit` is the largest detected routine (~39 lines, L34). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Wavelet/WICAExplorationViews.swift](../../EVA/Wavelet/WICAExplorationViews.swift#L39) | 3/5 | 331 | S | `var body` is the largest detected routine (~78 lines, L39). Reading demands: shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Wavelet/WICAProcessor.swift](../../EVA/Wavelet/WICAProcessor.swift#L79) | 3/5 | 343 | S | `reduce` is the largest detected routine (~121 lines, L79). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVA/Wavelet/WICAViewModel.swift](../../EVA/Wavelet/WICAViewModel.swift#L77) | 3/5 | 300 | S | `analyze` is the largest detected routine (~82 lines, L77). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Wavelet/WaveletArtifactAnalyzer.swift](../../EVA/Wavelet/WaveletArtifactAnalyzer.swift#L376) | 1/5 | 2,825 | C | 2,825 lines span preparation, matching, feature extraction, previews and candidate selection despite helpful section comments. | Separate configuration/results, feature extraction, matching and scan orchestration; document scale-to-frequency mapping. | **Expanded comments complete** |
| [EVA/Wavelet/WaveletArtifactExplorerViewModel.swift](../../EVA/Wavelet/WaveletArtifactExplorerViewModel.swift#L156) | 4/5 | 173 | S | `resetForClose` is the largest detected routine (~17 lines, L156). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Wavelet/WaveletArtifactExplorerViews.swift](../../EVA/Wavelet/WaveletArtifactExplorerViews.swift#L704) | 1/5 | 1,530 | S | `waveletExplorerConfigurationSection` is the largest detected routine (~221 lines, L704). Reading demands: asynchronous control flow, shared WaveformView context. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | **Expanded comments complete** |
| [EVA/Wavelet/WaveletDenoiser.swift](../../EVA/Wavelet/WaveletDenoiser.swift#L114) | 4/5 | 143 | S | `sureThreshold` is the largest detected routine (~29 lines, L114). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Wavelet/WaveletKernels.metal](../../EVA/Wavelet/WaveletKernels.metal#L127) | 4/5 | 445 | S | `waveletThresholdAccumulate` is the largest detected routine (~55 lines, L127). Reading demands: numeric/GPU primitives. | Document every buffer shape, index mapping, thread responsibility and matching CPU operation. | — |
| [EVA/Wavelet/WaveletMetalBackend.swift](../../EVA/Wavelet/WaveletMetalBackend.swift#L644) | 2/5 | 943 | S | `reductionFinish` is the largest detected routine (~169 lines, L644). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | **Expanded comments complete** |
| [EVA/Wavelet/WaveletModels.swift](../../EVA/Wavelet/WaveletModels.swift#L55) | 3/5 | 187 | S | `defaultLevelCount` is the largest detected routine (~12 lines, L55). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVA/Wavelet/WaveletReducer.swift](../../EVA/Wavelet/WaveletReducer.swift#L693) | 2/5 | 1,528 | C | Useful method rationale and sections exist, but CPU/GPU orchestration, thresholding and transform internals share 1,528 lines. | Separate transform and backend concerns; specify coefficient layout, threshold semantics and fallback behavior. | **Expanded comments complete** |
| [EVA/Wavelet/WaveletReductionSheetViews.swift](../../EVA/Wavelet/WaveletReductionSheetViews.swift#L110) | 3/5 | 543 | S | `applyArtifactCleaning` is the largest detected routine (~113 lines, L110). Reading demands: asynchronous control flow, shared WaveformView context. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVA/Wavelet/WaveletReductionViewModel.swift](../../EVA/Wavelet/WaveletReductionViewModel.swift#L274) | 4/5 | 311 | S | `bandLimitedVarianceRetained` is the largest detected routine (~31 lines, L274). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. Replace missing REFACTOR.md references. | — |
| [EVA/Wavelet/WaveletScalogram.swift](../../EVA/Wavelet/WaveletScalogram.swift#L44) | 4/5 | 100 | S | `compute` is the largest detected routine (~56 lines, L44). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |

<a id="evacoreartifacts"></a>
## EVACore/Artifacts

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Artifacts/SourceInformed/SourceInformedOperator.swift](../../EVACore/Artifacts/SourceInformed/SourceInformedOperator.swift#L116) | 2/5 | 363 | S | `makeOperator` is the largest detected routine (~155 lines, L116). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | **Expanded comments complete** |

<a id="evacorechannels"></a>
## EVACore/Channels

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Channels/BVEFMontage.swift](../../EVACore/Channels/BVEFMontage.swift#L212) | 4/5 | 280 | S | `write` is the largest detected routine (~61 lines, L212). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `write`; preserve straightforward code. | — |
| [EVACore/Channels/ElectrodeGeometry.swift](../../EVACore/Channels/ElectrodeGeometry.swift#L93) | 4/5 | 133 | S | `load` is the largest detected routine (~40 lines, L93). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `load`; preserve straightforward code. | — |
| [EVACore/Channels/ElectrodeLocationFile.swift](../../EVACore/Channels/ElectrodeLocationFile.swift#L54) | 4/5 | 211 | S | `parse` is the largest detected routine (~87 lines, L54). Relatively localized scope. | Add the input/output contract and edge cases for `parse`; preserve straightforward code. | — |
| [EVACore/Channels/ElectrodePositions.swift](../../EVACore/Channels/ElectrodePositions.swift#L252) | 4/5 | 370 | S | `readELC` is the largest detected routine (~39 lines, L252). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `readELC`; preserve straightforward code. | — |
| [EVACore/Channels/SensorLayout.swift](../../EVACore/Channels/SensorLayout.swift#L87) | 4/5 | 138 | S | `load` is the largest detected routine (~51 lines, L87). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `load`; preserve straightforward code. | — |
| [EVACore/Channels/StandardMontage.swift](../../EVACore/Channels/StandardMontage.swift#L49) | 4/5 | 73 | S | `positions` is the largest detected routine (~24 lines, L49). Relatively localized scope. | Add the input/output contract and edge cases for `positions`; preserve straightforward code. | — |
| [EVACore/Channels/StandardMontageData.swift](../../EVACore/Channels/StandardMontageData.swift#L1) | 4/5 | 382 | S | Explicitly marked as generated; the bulk is reference data, so length is not algorithm complexity. | Document units, coordinate frame and regeneration procedure in the generator; do not hand-edit the table. | — |

<a id="evacorecore"></a>
## EVACore/Core

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Core/AccelerateCompat.swift](../../EVACore/Core/AccelerateCompat.swift#L1) | 4/5 | 22 | S | 22 lines of declarations or top-level code. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. Replace missing REFACTOR.md references. | — |
| [EVACore/Core/DSP.swift](../../EVACore/Core/DSP.swift#L92) | 3/5 | 519 | S | `firls` is the largest detected routine (~72 lines, L92). Reading demands: unsafe-memory APIs, numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVACore/Core/Forward/BEMForwardModel.swift](../../EVACore/Core/Forward/BEMForwardModel.swift#L192) | 4/5 | 439 | S | `solveSurfacePotentials` is the largest detected routine (~146 lines, L192). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVACore/Core/Forward/BEMGeometry.swift](../../EVACore/Core/Forward/BEMGeometry.swift#L125) | 4/5 | 313 | S | `quality` is the largest detected routine (~114 lines, L125). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVACore/Core/Forward/BEMSolution.swift](../../EVACore/Core/Forward/BEMSolution.swift#L79) | 4/5 | 151 | S | `readFIF` is the largest detected routine (~47 lines, L79). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVACore/Core/Forward/EllipsoidalForwardModel.swift](../../EVACore/Core/Forward/EllipsoidalForwardModel.swift#L105) | 4/5 | 212 | S | `leadField` is the largest detected routine (~42 lines, L105). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVACore/Core/Forward/ForwardOperator.swift](../../EVACore/Core/Forward/ForwardOperator.swift#L328) | 3/5 | 583 | S | `leadField` is the largest detected routine (~75 lines, L328). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVACore/Core/Forward/ForwardTypes.swift](../../EVACore/Core/Forward/ForwardTypes.swift#L97) | 4/5 | 279 | S | `threeShell` is the largest detected routine (~32 lines, L97). Existing explanatory comments provide context. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVACore/Core/Forward/SphericalForwardModel.swift](../../EVACore/Core/Forward/SphericalForwardModel.swift#L26) | 3/5 | 388 | S | `leadField` is the largest detected routine (~90 lines, L26). Relatively localized scope. | Define domain terms, input/output units and algorithm stages; explain thresholds and boundary cases. | — |
| [EVACore/Core/LinearAlgebra.swift](../../EVACore/Core/LinearAlgebra.swift#L337) | 3/5 | 534 | C | The factorization documentation explains reuse and matrix order, but elementary helpers have implicit failure conventions and LAPACK adds a second representation. | Document matrix shapes, layout conversion, mutation and nil/zero fallbacks; show a 2×2 solve. | Initial focused comments |
| [EVACore/Core/SeededGenerator.swift](../../EVACore/Core/SeededGenerator.swift#L45) | 4/5 | 52 | C | Purpose and determinism are explained unusually well; wrapping arithmetic and bit mixing are unfamiliar to new Swift programmers. | Explain &+ and &* once, link the shared Swift guide and replace the missing REWIND.md pointer. | Initial focused comments |

<a id="evacoreepoching"></a>
## EVACore/Epoching

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Epoching/EpochModel.swift](../../EVACore/Epoching/EpochModel.swift#L1) | 4/5 | 34 | S | Declarations include `EpochSegment`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |

<a id="evacoregeometry"></a>
## EVACore/Geometry

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Geometry/HeadTransform.swift](../../EVACore/Geometry/HeadTransform.swift#L197) | 4/5 | 244 | S | `decompose` is the largest detected routine (~47 lines, L197). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `decompose`; preserve straightforward code. | — |
| [EVACore/Geometry/TriangleMesh.swift](../../EVACore/Geometry/TriangleMesh.swift#L189) | 4/5 | 222 | S | `closestPoint` is the largest detected routine (~33 lines, L189). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `closestPoint`; preserve straightforward code. | — |
| [EVACore/Geometry/TriangleMeshIntersection.swift](../../EVACore/Geometry/TriangleMeshIntersection.swift#L33) | 4/5 | 153 | S | `selfIntersectingTriangles` is the largest detected routine (~51 lines, L33). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `selfIntersectingTriangles`; preserve straightforward code. | — |

<a id="evacoreio"></a>
## EVACore/IO

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/IO/BDFRecording.swift](../../EVACore/IO/BDFRecording.swift#L52) | 3/5 | 307 | S | `read` is the largest detected routine (~217 lines, L52). Reading demands: asynchronous control flow, unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVACore/IO/EDFAnnotationDecoder.swift](../../EVACore/IO/EDFAnnotationDecoder.swift#L25) | 4/5 | 89 | S | `decode` is the largest detected routine (~45 lines, L25). Relatively localized scope. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/EGISensorXMLParser.swift](../../EVACore/IO/EGISensorXMLParser.swift#L86) | 4/5 | 131 | S | `parser` is the largest detected routine (~31 lines, L86). Little explanatory commenting was detected. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/FIF/FIFDocument.swift](../../EVACore/IO/FIF/FIFDocument.swift#L164) | 4/5 | 292 | S | `outline` is the largest detected routine (~58 lines, L164). Existing explanatory comments provide context. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/FIF/FIFFile.swift](../../EVACore/IO/FIF/FIFFile.swift#L174) | 4/5 | 341 | S | `matrix` is the largest detected routine (~24 lines, L174). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVACore/IO/FIF/FIFInterop.swift](../../EVACore/IO/FIF/FIFInterop.swift#L202) | 4/5 | 277 | S | `readFIF` is the largest detected routine (~40 lines, L202). Existing explanatory comments provide context. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/FIF/FIFMeasurementInfo.swift](../../EVACore/IO/FIF/FIFMeasurementInfo.swift#L231) | 4/5 | 305 | S | `read` is the largest detected routine (~52 lines, L231). Existing explanatory comments provide context. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/FIF/FIFRecording.swift](../../EVACore/IO/FIF/FIFRecording.swift#L227) | 4/5 | 386 | S | `readEpochs` is the largest detected routine (~75 lines, L227). Existing explanatory comments provide context. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/GIFTI/GIFTICompanionSurfaceResolver.swift](../../EVACore/IO/GIFTI/GIFTICompanionSurfaceResolver.swift#L17) | 4/5 | 104 | S | `attachIfAvailable` is the largest detected routine (~40 lines, L17). Relatively localized scope. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/GIFTI/GIFTIPreviewModel.swift](../../EVACore/IO/GIFTI/GIFTIPreviewModel.swift#L166) | 3/5 | 184 | S | `robustWindow` is the largest detected routine (~18 lines, L166). Little explanatory commenting was detected. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/GIFTI/GIFTIQuickLookReader.swift](../../EVACore/IO/GIFTI/GIFTIQuickLookReader.swift#L342) | 3/5 | 709 | S | `makePendingArray` is the largest detected routine (~77 lines, L342). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVACore/IO/MFFFileType.swift](../../EVACore/IO/MFFFileType.swift#L1) | 4/5 | 64 | S | Declarations include `MFFFileType`. Relatively localized scope. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/MFFReader.swift](../../EVACore/IO/MFFReader.swift#L1531) | 2/5 | 2,169 | C | 2,169 lines mix central signal/event models with package and binary/XML readers; dataRevision is documented but data itself lacks an array-shape contract. | Document MFFSignalData dimensions and unit conventions first, then separate models, binary reading and event/epoch parsing. | **Expanded comments complete** |
| [EVACore/IO/MFFWriter.swift](../../EVACore/IO/MFFWriter.swift#L75) | 4/5 | 1,024 | S | `write` is the largest detected routine (~65 lines, L75). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVACore/IO/NIfTI/NIfTIByteSource.swift](../../EVACore/IO/NIfTI/NIfTIByteSource.swift#L91) | 4/5 | 124 | S | `consumeGzipHeader` is the largest detected routine (~33 lines, L91). Relatively localized scope. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVACore/IO/NIfTI/NIfTIHeader.swift](../../EVACore/IO/NIfTI/NIfTIHeader.swift#L198) | 2/5 | 478 | C | Good bounds/endian rationale, but decodeV1 and decodeV2 contain many bare byte offsets and affine reconstruction rules. | Add a named field/offset map and explain qform/sform selection, voxel axes and physical units. | **Expanded comments complete** |
| [EVACore/IO/NIfTI/NIfTIScalarDecoder.swift](../../EVACore/IO/NIfTI/NIfTIScalarDecoder.swift#L13) | 4/5 | 62 | S | `value` is the largest detected routine (~20 lines, L13). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVACore/IO/NIfTI/NIfTIVolume.swift](../../EVACore/IO/NIfTI/NIfTIVolume.swift#L394) | 4/5 | 547 | S | `write` is the largest detected routine (~67 lines, L394). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVACore/IO/OpenMEEG/OpenMEEGGeometry.swift](../../EVACore/IO/OpenMEEG/OpenMEEGGeometry.swift#L332) | 4/5 | 471 | S | `write` is the largest detected routine (~41 lines, L332). Existing explanatory comments provide context. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |

<a id="evacoreimaging"></a>
## EVACore/Imaging

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Imaging/ScalpFromVolume.swift](../../EVACore/Imaging/ScalpFromVolume.swift#L75) | 4/5 | 103 | S | `scalp` is the largest detected routine (~28 lines, L75). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `scalp`; preserve straightforward code. | — |
| [EVACore/Imaging/VolumeMorphology.swift](../../EVACore/Imaging/VolumeMorphology.swift#L269) | 4/5 | 359 | S | `otsuThreshold` is the largest detected routine (~32 lines, L269). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `otsuThreshold`; preserve straightforward code. | — |

<a id="evacorepipeline"></a>
## EVACore/Pipeline

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Pipeline/EVAProcessingScript.swift](../../EVACore/Pipeline/EVAProcessingScript.swift#L457) | 4/5 | 534 | S | `parse` is the largest detected routine (~65 lines, L457). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `parse`; preserve straightforward code. | — |

<a id="evacoreregistration"></a>
## EVACore/Registration

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Registration/SurfaceRegistration.swift](../../EVACore/Registration/SurfaceRegistration.swift#L63) | 4/5 | 150 | S | `icp` is the largest detected routine (~45 lines, L63). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `icp`; preserve straightforward code. | — |

<a id="evacoresimulation"></a>
## EVACore/Simulation

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVACore/Simulation/AdditionalArtifactModel.swift](../../EVACore/Simulation/AdditionalArtifactModel.swift#L245) | 3/5 | 436 | S | `injectSweat` is the largest detected routine (~73 lines, L245). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `injectSweat`; preserve straightforward code. | — |
| [EVACore/Simulation/BCGArtifactModel.swift](../../EVACore/Simulation/BCGArtifactModel.swift#L148) | 4/5 | 567 | S | `injectGenerators` is the largest detected routine (~101 lines, L148). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `injectGenerators`; preserve straightforward code. | — |
| [EVACore/Simulation/BCGGeneratorModel.swift](../../EVACore/Simulation/BCGGeneratorModel.swift#L334) | 4/5 | 388 | S | `decompose` is the largest detected routine (~54 lines, L334). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `decompose`; preserve straightforward code. | — |
| [EVACore/Simulation/BrainTransientModel.swift](../../EVACore/Simulation/BrainTransientModel.swift#L124) | 4/5 | 168 | S | `inject` is the largest detected routine (~44 lines, L124). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `inject`; preserve straightforward code. | — |
| [EVACore/Simulation/ChannelDefectModel.swift](../../EVACore/Simulation/ChannelDefectModel.swift#L196) | 4/5 | 307 | S | `spoil` is the largest detected routine (~68 lines, L196). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `spoil`; preserve straightforward code. | — |
| [EVACore/Simulation/DipoleEEGGenerator.swift](../../EVACore/Simulation/DipoleEEGGenerator.swift#L119) | 3/5 | 492 | S | `generate` is the largest detected routine (~110 lines, L119). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `generate`; preserve straightforward code. | — |
| [EVACore/Simulation/EEGGenerator.swift](../../EVACore/Simulation/EEGGenerator.swift#L45) | 4/5 | 253 | S | `generate` is the largest detected routine (~82 lines, L45). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `generate`; preserve straightforward code. | — |
| [EVACore/Simulation/EMGArtifactModel.swift](../../EVACore/Simulation/EMGArtifactModel.swift#L45) | 3/5 | 223 | S | `inject` is the largest detected routine (~72 lines, L45). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `inject`; preserve straightforward code. | — |
| [EVACore/Simulation/ERPExperiment.swift](../../EVACore/Simulation/ERPExperiment.swift#L91) | 3/5 | 306 | S | `validate` is the largest detected routine (~63 lines, L91). Relatively localized scope. | Add the input/output contract and edge cases for `validate`; preserve straightforward code. | — |
| [EVACore/Simulation/ERPExperimentOptions.swift](../../EVACore/Simulation/ERPExperimentOptions.swift#L42) | 4/5 | 134 | S | `apply` is the largest detected routine (~92 lines, L42). Relatively localized scope. | Add the input/output contract and edge cases for `apply`; preserve straightforward code. | — |
| [EVACore/Simulation/ERPGenerator.swift](../../EVACore/Simulation/ERPGenerator.swift#L369) | 3/5 | 709 | S | `injectPlaced` is the largest detected routine (~205 lines, L369). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `injectPlaced`; preserve straightforward code. | — |
| [EVACore/Simulation/ERPTruth.swift](../../EVACore/Simulation/ERPTruth.swift#L1) | 4/5 | 28 | S | Declarations include `ERPComponent`, `ERPComponentSet`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVACore/Simulation/GradientArtifactModel.swift](../../EVACore/Simulation/GradientArtifactModel.swift#L52) | 4/5 | 372 | S | `inject` is the largest detected routine (~62 lines, L52). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `inject`; preserve straightforward code. | — |
| [EVACore/Simulation/GroupSimulation.swift](../../EVACore/Simulation/GroupSimulation.swift#L232) | 4/5 | 429 | S | `configure` is the largest detected routine (~73 lines, L232). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `configure`; preserve straightforward code. | — |
| [EVACore/Simulation/ImpedanceModel.swift](../../EVACore/Simulation/ImpedanceModel.swift#L70) | 4/5 | 225 | S | `values` is the largest detected routine (~50 lines, L70). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `values`; preserve straightforward code. | — |
| [EVACore/Simulation/Montage.swift](../../EVACore/Simulation/Montage.swift#L314) | 4/5 | 372 | S | `coordinatesXML` is the largest detected routine (~48 lines, L314). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `coordinatesXML`; preserve straightforward code. | — |
| [EVACore/Simulation/NonGaussianSourceModel.swift](../../EVACore/Simulation/NonGaussianSourceModel.swift#L47) | 4/5 | 101 | S | `shape` is the largest detected routine (~38 lines, L47). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `shape`; preserve straightforward code. | — |
| [EVACore/Simulation/NonstationaryEEGModel.swift](../../EVACore/Simulation/NonstationaryEEGModel.swift#L179) | 3/5 | 357 | S | `alphaPlan` is the largest detected routine (~43 lines, L179). Relatively localized scope. | Add the input/output contract and edge cases for `alphaPlan`; preserve straightforward code. | — |
| [EVACore/Simulation/OcularArtifactModel.swift](../../EVACore/Simulation/OcularArtifactModel.swift#L63) | 4/5 | 256 | S | `inject` is the largest detected routine (~136 lines, L63). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `inject`; preserve straightforward code. | — |
| [EVACore/Simulation/OcularDipoleModel.swift](../../EVACore/Simulation/OcularDipoleModel.swift#L38) | 4/5 | 118 | S | `topographies` is the largest detected routine (~55 lines, L38). Relatively localized scope. | Add the input/output contract and edge cases for `topographies`; preserve straightforward code. | — |
| [EVACore/Simulation/SignalSynthesis.swift](../../EVACore/Simulation/SignalSynthesis.swift#L73) | 4/5 | 221 | S | `bandLimited` is the largest detected routine (~28 lines, L73). Reading demands: numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVACore/Simulation/SimulationConfig.swift](../../EVACore/Simulation/SimulationConfig.swift#L829) | 4/5 | 885 | S | `talairachApproximate` is the largest detected routine (~5 lines, L829). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `talairachApproximate`; preserve straightforward code. | — |
| [EVACore/Simulation/SimulationError.swift](../../EVACore/Simulation/SimulationError.swift#L1) | 4/5 | 32 | S | Declarations include `SimulateError`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVACore/Simulation/SimulationForwardDomain.swift](../../EVACore/Simulation/SimulationForwardDomain.swift#L321) | 4/5 | 485 | S | `convergenceReport` is the largest detected routine (~26 lines, L321). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `convergenceReport`; preserve straightforward code. | — |
| [EVACore/Simulation/SimulationScenario.swift](../../EVACore/Simulation/SimulationScenario.swift#L24) | 4/5 | 84 | S | `load` is the largest detected routine (~36 lines, L24). Relatively localized scope. | Add the input/output contract and edge cases for `load`; preserve straightforward code. | — |
| [EVACore/Simulation/SimulationSweep.swift](../../EVACore/Simulation/SimulationSweep.swift#L80) | 3/5 | 213 | S | `apply` is the largest detected routine (~95 lines, L80). Relatively localized scope. | Add the input/output contract and edge cases for `apply`; preserve straightforward code. | — |
| [EVACore/Simulation/SingleDipoleFit.swift](../../EVACore/Simulation/SingleDipoleFit.swift#L1402) | 3/5 | 2,134 | S | `bestCandidate` is the largest detected routine (~134 lines, L1402). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. Separate major responsibilities into focused files. | — |
| [EVACore/Simulation/SourceSimulatorArtifacts.swift](../../EVACore/Simulation/SourceSimulatorArtifacts.swift#L60) | 4/5 | 115 | S | `inject` is the largest detected routine (~55 lines, L60). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `inject`; preserve straightforward code. | — |
| [EVACore/Simulation/SourceSimulatorNoise.swift](../../EVACore/Simulation/SourceSimulatorNoise.swift#L36) | 4/5 | 154 | S | `noiseMatrix` is the largest detected routine (~34 lines, L36). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `noiseMatrix`; preserve straightforward code. | — |
| [EVACore/Simulation/SweepEvaluation.swift](../../EVACore/Simulation/SweepEvaluation.swift#L60) | 3/5 | 189 | S | `evaluate` is the largest detected routine (~70 lines, L60). Relatively localized scope. | Add the input/output contract and edge cases for `evaluate`; preserve straightforward code. | — |

<a id="evapreviewkitcifti"></a>
## EVAPreviewKit/CIFTI

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/CIFTI/CIFTIMatrixRenderer.swift](../../EVAPreviewKit/CIFTI/CIFTIMatrixRenderer.swift#L10) | 4/5 | 126 | S | `image` is the largest detected routine (~35 lines, L10). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `image`; preserve straightforward code. | — |
| [EVAPreviewKit/CIFTI/CIFTIPreviewModel.swift](../../EVAPreviewKit/CIFTI/CIFTIPreviewModel.swift#L93) | 4/5 | 186 | S | `short` is the largest detected routine (~3 lines, L93). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `short`; preserve straightforward code. | — |
| [EVAPreviewKit/CIFTI/CIFTIPreviewView.swift](../../EVAPreviewKit/CIFTI/CIFTIPreviewView.swift#L176) | 4/5 | 273 | S | `var body` is the largest detected routine (~74 lines, L176). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAPreviewKit/CIFTI/CIFTIQuickLookReader.swift](../../EVAPreviewKit/CIFTI/CIFTIQuickLookReader.swift#L151) | 3/5 | 331 | S | `readSample` is the largest detected routine (~74 lines, L151). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVAPreviewKit/CIFTI/CIFTIThumbnailRenderer.swift](../../EVAPreviewKit/CIFTI/CIFTIThumbnailRenderer.swift#L13) | 4/5 | 55 | S | `draw` is the largest detected routine (~28 lines, L13). Relatively localized scope. | Add the input/output contract and edge cases for `draw`; preserve straightforward code. | — |
| [EVAPreviewKit/CIFTI/CIFTIXMLParser.swift](../../EVAPreviewKit/CIFTI/CIFTIXMLParser.swift#L92) | 3/5 | 276 | S | `parser` is the largest detected routine (~53 lines, L92). Relatively localized scope. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |

<a id="evapreviewkitdicom"></a>
## EVAPreviewKit/DICOM

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/DICOM/DICOMImageRenderer.swift](../../EVAPreviewKit/DICOM/DICOMImageRenderer.swift#L11) | 4/5 | 47 | S | `image` is the largest detected routine (~36 lines, L11). Relatively localized scope. | Add the input/output contract and edge cases for `image`; preserve straightforward code. | — |
| [EVAPreviewKit/DICOM/DICOMPreviewModel.swift](../../EVAPreviewKit/DICOM/DICOMPreviewModel.swift#L1) | 4/5 | 131 | S | Declarations include `DICOMTransferSyntax`, `DICOMPixelImage`, `DICOMPreviewModel`. Little explanatory commenting was detected. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVAPreviewKit/DICOM/DICOMPreviewView.swift](../../EVAPreviewKit/DICOM/DICOMPreviewView.swift#L11) | 4/5 | 119 | S | `var body` is the largest detected routine (~20 lines, L11). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAPreviewKit/DICOM/DICOMQuickLookReader.swift](../../EVAPreviewKit/DICOM/DICOMQuickLookReader.swift#L246) | 2/5 | 478 | C | The supported subset is stated, but transfer syntaxes, VR rules, tags, byte decoding and image conversion need format expertise. | Explain parser phases and supported syntax decisions; name recurring tags and link local format fixtures. | **Expanded comments complete** |
| [EVAPreviewKit/DICOM/DICOMThumbnailRenderer.swift](../../EVAPreviewKit/DICOM/DICOMThumbnailRenderer.swift#L13) | 4/5 | 54 | S | `draw` is the largest detected routine (~20 lines, L13). Relatively localized scope. | Add the input/output contract and edge cases for `draw`; preserve straightforward code. | — |

<a id="evapreviewkitevapreviewformatswift"></a>
## EVAPreviewKit/EVAPreviewFormat.swift

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/EVAPreviewFormat.swift](../../EVAPreviewKit/EVAPreviewFormat.swift#L56) | 4/5 | 87 | S | `identify` is the largest detected routine (~12 lines, L56). Relatively localized scope. | Add the input/output contract and edge cases for `identify`; preserve straightforward code. | — |

<a id="evapreviewkitevaquicklookpreferencesswift"></a>
## EVAPreviewKit/EVAQuickLookPreferences.swift

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/EVAQuickLookPreferences.swift](../../EVAPreviewKit/EVAQuickLookPreferences.swift#L14) | 4/5 | 22 | S | `isEnabled` is the largest detected routine (~4 lines, L14). Relatively localized scope. | Add the input/output contract and edge cases for `isEnabled`; preserve straightforward code. | — |

<a id="evapreviewkitfif"></a>
## EVAPreviewKit/FIF

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/FIF/FIFPreviewView.swift](../../EVAPreviewKit/FIF/FIFPreviewView.swift#L219) | 4/5 | 789 | S | `var body` is the largest detected routine (~47 lines, L219). Reading demands: declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVAPreviewKit/FIF/FIFQuickLookReader.swift](../../EVAPreviewKit/FIF/FIFQuickLookReader.swift#L70) | 3/5 | 366 | S | `readRecording` is the largest detected routine (~132 lines, L70). Existing explanatory comments provide context. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [EVAPreviewKit/FIF/FIFQuickLookSummary.swift](../../EVAPreviewKit/FIF/FIFQuickLookSummary.swift#L1) | 4/5 | 170 | S | Declarations include `FIFQuickLookSummary`, `Recording`, `Channel`. Existing explanatory comments provide context. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVAPreviewKit/FIF/FIFThumbnailRenderer.swift](../../EVAPreviewKit/FIF/FIFThumbnailRenderer.swift#L110) | 4/5 | 210 | S | `drawButterfly` is the largest detected routine (~35 lines, L110). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `drawButterfly`; preserve straightforward code. | — |

<a id="evapreviewkitgifti"></a>
## EVAPreviewKit/GIFTI

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/GIFTI/GIFTIPreviewView.swift](../../EVAPreviewKit/GIFTI/GIFTIPreviewView.swift#L408) | 4/5 | 496 | S | `var body` is the largest detected routine (~58 lines, L408). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAPreviewKit/GIFTI/GIFTISceneFactory.swift](../../EVAPreviewKit/GIFTI/GIFTISceneFactory.swift#L20) | 3/5 | 320 | S | `make` is the largest detected routine (~81 lines, L20). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVAPreviewKit/GIFTI/GIFTIThumbnailRenderer.swift](../../EVAPreviewKit/GIFTI/GIFTIThumbnailRenderer.swift#L32) | 4/5 | 109 | S | `drawSurface` is the largest detected routine (~46 lines, L32). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `drawSurface`; preserve straightforward code. | — |

<a id="evapreviewkitmff"></a>
## EVAPreviewKit/MFF

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/MFF/MFFPreviewView.swift](../../EVAPreviewKit/MFF/MFFPreviewView.swift#L349) | 4/5 | 634 | S | `var body` is the largest detected routine (~64 lines, L349). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAPreviewKit/MFF/MFFQuickLookSummary.swift](../../EVAPreviewKit/MFF/MFFQuickLookSummary.swift#L102) | 4/5 | 222 | S | `band` is the largest detected routine (~5 lines, L102). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `band`; preserve straightforward code. | — |
| [EVAPreviewKit/MFF/MFFQuickLookSummaryReader.swift](../../EVAPreviewKit/MFF/MFFQuickLookSummaryReader.swift#L31) | 3/5 | 629 | S | `read` is the largest detected routine (~236 lines, L31). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVAPreviewKit/MFF/MFFThumbnailRenderer.swift](../../EVAPreviewKit/MFF/MFFThumbnailRenderer.swift#L112) | 4/5 | 383 | S | `draw` is the largest detected routine (~55 lines, L112). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `draw`; preserve straightforward code. | — |

<a id="evapreviewkitmgh"></a>
## EVAPreviewKit/MGH

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/MGH/MGHHeader.swift](../../EVAPreviewKit/MGH/MGHHeader.swift#L52) | 4/5 | 158 | S | `decode` is the largest detected routine (~57 lines, L52). Relatively localized scope. | Add the input/output contract and edge cases for `decode`; preserve straightforward code. | — |
| [EVAPreviewKit/MGH/MGHPreviewModel.swift](../../EVAPreviewKit/MGH/MGHPreviewModel.swift#L1) | 4/5 | 27 | S | Declarations include `MGHPreviewModel`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [EVAPreviewKit/MGH/MGHPreviewView.swift](../../EVAPreviewKit/MGH/MGHPreviewView.swift#L11) | 4/5 | 127 | S | `var body` is the largest detected routine (~20 lines, L11). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAPreviewKit/MGH/MGHQuickLookReader.swift](../../EVAPreviewKit/MGH/MGHQuickLookReader.swift#L104) | 3/5 | 153 | S | `canonicalSlices` is the largest detected routine (~43 lines, L104). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVAPreviewKit/MGH/MGHThumbnailRenderer.swift](../../EVAPreviewKit/MGH/MGHThumbnailRenderer.swift#L13) | 4/5 | 55 | S | `draw` is the largest detected routine (~22 lines, L13). Relatively localized scope. | Add the input/output contract and edge cases for `draw`; preserve straightforward code. | — |

<a id="evapreviewkitnifti"></a>
## EVAPreviewKit/NIfTI

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAPreviewKit/NIfTI/NIfTIPreviewModel.swift](../../EVAPreviewKit/NIfTI/NIfTIPreviewModel.swift#L90) | 4/5 | 167 | S | `make` is the largest detected routine (~37 lines, L90). Relatively localized scope. | Add the input/output contract and edge cases for `make`; preserve straightforward code. | — |
| [EVAPreviewKit/NIfTI/NIfTIPreviewView.swift](../../EVAPreviewKit/NIfTI/NIfTIPreviewView.swift#L197) | 4/5 | 296 | S | `var body` is the largest detected routine (~54 lines, L197). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAPreviewKit/NIfTI/NIfTIQuickLookReader.swift](../../EVAPreviewKit/NIfTI/NIfTIQuickLookReader.swift#L149) | 3/5 | 243 | S | `canonicalSlices` is the largest detected routine (~81 lines, L149). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [EVAPreviewKit/NIfTI/NIfTISliceRenderer.swift](../../EVAPreviewKit/NIfTI/NIfTISliceRenderer.swift#L10) | 4/5 | 127 | S | `image` is the largest detected routine (~43 lines, L10). Relatively localized scope. | Add the input/output contract and edge cases for `image`; preserve straightforward code. | — |
| [EVAPreviewKit/NIfTI/NIfTIThumbnailRenderer.swift](../../EVAPreviewKit/NIfTI/NIfTIThumbnailRenderer.swift#L13) | 4/5 | 76 | S | `draw` is the largest detected routine (~42 lines, L13). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `draw`; preserve straightforward code. | — |

<a id="evaquicklook"></a>
## EVAQuickLook

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAQuickLook/PreviewViewController.swift](../../EVAQuickLook/PreviewViewController.swift#L30) | 4/5 | 89 | S | `preparePreviewOfFile` is the largest detected routine (~59 lines, L30). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |

<a id="evaresolveapp"></a>
## EVAResolve/App

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAResolve/App/EVAResolveApp.swift](../../EVAResolve/App/EVAResolveApp.swift#L33) | 4/5 | 100 | S | `var body` is the largest detected routine (~26 lines, L33). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/App/EVAResolvePreferencesView.swift](../../EVAResolve/App/EVAResolvePreferencesView.swift#L20) | 4/5 | 36 | S | `var body` is the largest detected routine (~16 lines, L20). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |

<a id="evaresolveheadmodel"></a>
## EVAResolve/HeadModel

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAResolve/HeadModel/CoregistrationSceneView.swift](../../EVAResolve/HeadModel/CoregistrationSceneView.swift#L31) | 4/5 | 123 | S | `makeScene` is the largest detected routine (~43 lines, L31). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/HeadModel/HeadModelController.swift](../../EVAResolve/HeadModel/HeadModelController.swift#L208) | 4/5 | 353 | S | `refit` is the largest detected routine (~27 lines, L208). Reading demands: asynchronous control flow, declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/HeadModel/HeadModelDocument.swift](../../EVAResolve/HeadModel/HeadModelDocument.swift#L45) | 4/5 | 68 | S | `write` is the largest detected routine (~13 lines, L45). Relatively localized scope. | Add the input/output contract and edge cases for `write`; preserve straightforward code. | — |
| [EVAResolve/HeadModel/HeadModelWindowView.swift](../../EVAResolve/HeadModel/HeadModelWindowView.swift#L86) | 4/5 | 242 | S | `inspector` is the largest detected routine (~68 lines, L86). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/HeadModel/MRISliceView.swift](../../EVAResolve/HeadModel/MRISliceView.swift#L190) | 4/5 | 226 | S | `drawOverlay` is the largest detected routine (~36 lines, L190). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |

<a id="evaresolvesimulator"></a>
## EVAResolve/Simulator

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAResolve/Simulator/FitWaveformPanels.swift](../../EVAResolve/Simulator/FitWaveformPanels.swift#L29) | 4/5 | 226 | S | `draw` is the largest detected routine (~42 lines, L29). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/Simulator/HeadProjectionView.swift](../../EVAResolve/Simulator/HeadProjectionView.swift#L181) | 4/5 | 354 | S | `draw` is the largest detected routine (~68 lines, L181). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/Simulator/HeadSilhouette.swift](../../EVAResolve/Simulator/HeadSilhouette.swift#L107) | 4/5 | 423 | S | `controlPoints` is the largest detected routine (~111 lines, L107). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `controlPoints`; preserve straightforward code. | — |
| [EVAResolve/Simulator/PendingSourceFit.swift](../../EVAResolve/Simulator/PendingSourceFit.swift#L40) | 4/5 | 57 | S | `push` is the largest detected routine (~5 lines, L40). Relatively localized scope. | Add the input/output contract and edge cases for `push`; preserve straightforward code. | — |
| [EVAResolve/Simulator/ScalpFieldView.swift](../../EVAResolve/Simulator/ScalpFieldView.swift#L51) | 4/5 | 124 | S | `draw` is the largest detected routine (~49 lines, L51). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/Simulator/SourceButterflyView.swift](../../EVAResolve/Simulator/SourceButterflyView.swift#L64) | 4/5 | 156 | S | `draw` is the largest detected routine (~50 lines, L64). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/Simulator/SourceFitImporter.swift](../../EVAResolve/Simulator/SourceFitImporter.swift#L90) | 4/5 | 172 | S | `makeDataset` is the largest detected routine (~60 lines, L90). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [EVAResolve/Simulator/SourceFitModeView.swift](../../EVAResolve/Simulator/SourceFitModeView.swift#L371) | 4/5 | 564 | S | `draw` is the largest detected routine (~42 lines, L371). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/Simulator/SourceSimulatorController.swift](../../EVAResolve/Simulator/SourceSimulatorController.swift#L785) | 3/5 | 1,339 | S | `scheduleSharedFit` is the largest detected routine (~88 lines, L785). Reading demands: asynchronous control flow, declarative UI/state. | Document state ownership and user-action flow; extract independent child Views with explicit inputs/actions. | — |
| [EVAResolve/Simulator/SourceSimulatorWindowView.swift](../../EVAResolve/Simulator/SourceSimulatorWindowView.swift#L40) | 4/5 | 582 | S | `var body` is the largest detected routine (~48 lines, L40). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |
| [EVAResolve/Simulator/SourceTimelineView.swift](../../EVAResolve/Simulator/SourceTimelineView.swift#L126) | 4/5 | 220 | S | `draw` is the largest detected routine (~36 lines, L126). Reading demands: declarative UI/state. | Explain owned versus injected state and non-obvious bindings; keep presentation helpers focused. | — |

<a id="evaresolvetests"></a>
## EVAResolveTests

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAResolveTests/HeadModelControllerTests.swift](../../EVAResolveTests/HeadModelControllerTests.swift#L23) | 4/5 | 97 | S | `endToEnd` is the largest detected routine (~61 lines, L23). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVAResolveTests/SourceFitImporterTests.swift](../../EVAResolveTests/SourceFitImporterTests.swift#L18) | 4/5 | 83 | S | `writeAveragedPackage` is the largest detected routine (~34 lines, L18). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVAResolveTests/SourceSimulatorControllerTests.swift](../../EVAResolveTests/SourceSimulatorControllerTests.swift#L600) | 3/5 | 642 | S | `decompositionTracksUnexplainedVariance` is the largest detected routine (~42 lines, L600). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestsanalysis"></a>
## EVATests/Analysis

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Analysis/EEGAnalysisEngineTests.swift](../../EVATests/Analysis/EEGAnalysisEngineTests.swift#L18) | 4/5 | 85 | S | `analyzeProducesSpectralAndConnectivityResults` is the largest detected routine (~67 lines, L18). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestsapp"></a>
## EVATests/App

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/App/EventAnchorCatalogTests.swift](../../EVATests/App/EventAnchorCatalogTests.swift#L70) | 4/5 | 299 | S | `rWaveDetectorMatchesCatalog` is the largest detected routine (~38 lines, L70). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/App/EventAnchorSettingsTests.swift](../../EVATests/App/EventAnchorSettingsTests.swift#L27) | 4/5 | 219 | S | `event` is the largest detected routine (~17 lines, L27). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/App/TemporaryFileSweeperTests.swift](../../EVATests/App/TemporaryFileSweeperTests.swift#L90) | 4/5 | 156 | S | `workAreaSweptPerRun` is the largest detected routine (~16 lines, L90). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/App/UpdateCheckerTests.swift](../../EVATests/App/UpdateCheckerTests.swift#L59) | 4/5 | 84 | S | `selectsNewestPublishedReleaseIncludingPrereleases` is the largest detected routine (~17 lines, L59). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/App/WaveformAppearancePreferencesTests.swift](../../EVATests/App/WaveformAppearancePreferencesTests.swift#L16) | 4/5 | 31 | S | `zeroLineColorClampsStoredComponents` is the largest detected routine (~9 lines, L16). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestsartifacts"></a>
## EVATests/Artifacts

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Artifacts/ArtifactCleanRunGradeMeasurementTests.swift](../../EVATests/Artifacts/ArtifactCleanRunGradeMeasurementTests.swift#L216) | 4/5 | 352 | S | `realDetectionVersusHarm` is the largest detected routine (~136 lines, L216). Existing explanatory comments provide context. | Split setup, execution and checks in `realDetectionVersusHarm`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/ArtifactCleanRunGradeTests.swift](../../EVATests/Artifacts/ArtifactCleanRunGradeTests.swift#L54) | 4/5 | 101 | S | `compactEventEvidenceStoresIDsAndRMSWithoutSamples` is the largest detected routine (~19 lines, L54). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Artifacts/ArtifactCleanerTests.swift](../../EVATests/Artifacts/ArtifactCleanerTests.swift#L377) | 3/5 | 733 | S | `perChannelAlignmentBeatsSharedWindowUnderElectrodeLatency` is the largest detected routine (~64 lines, L377). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/ArtifactDetectorEventMergerTests.swift](../../EVATests/Artifacts/ArtifactDetectorEventMergerTests.swift#L133) | 4/5 | 183 | S | `bridgeDefinitionsRoundTripAndDriveExistingCleaners` is the largest detected routine (~50 lines, L133). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/ArtifactReplayPayloadTests.swift](../../EVATests/Artifacts/ArtifactReplayPayloadTests.swift#L187) | 4/5 | 361 | S | `manualExemplarPCASDefinitionSurvivesButItsFittedReportIsStripped` is the largest detected routine (~97 lines, L187). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/Artifacts/ArtifactReviewTests.swift](../../EVATests/Artifacts/ArtifactReviewTests.swift#L594) | 3/5 | 882 | S | `afniInspiredSpatialCostsArePolarityInvariantButKeepOneGlobalOrientation` is the largest detected routine (~59 lines, L594). Reading demands: asynchronous control flow, unsafe-memory APIs. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/ArtifactReviewWorkspaceTests.swift](../../EVATests/Artifacts/ArtifactReviewWorkspaceTests.swift#L227) | 4/5 | 324 | S | `testWorkspaceRendersRealAnalysis` is the largest detected routine (~97 lines, L227). Reading demands: asynchronous control flow, declarative UI/state. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/ArtifactTemplateDetectorTests.swift](../../EVATests/Artifacts/ArtifactTemplateDetectorTests.swift#L59) | 4/5 | 312 | S | `stretchRecoversArtifactOfDifferentDuration` is the largest detected routine (~54 lines, L59). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/CorneoRetinalCorrectionTests.swift](../../EVATests/Artifacts/CorneoRetinalCorrectionTests.swift#L118) | 4/5 | 246 | S | `artifactCleanerRunsWithoutRejectableEventsAndReplayKeepsMasks` is the largest detected routine (~44 lines, L118). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/MAACPreliminaryBlinkDetectorTests.swift](../../EVATests/Artifacts/MAACPreliminaryBlinkDetectorTests.swift#L14) | 4/5 | 82 | S | `detectsFastUpperMinusLowerBlinkWithUnequalGroups` is the largest detected routine (~27 lines, L14). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Artifacts/MovementPCACorrectionTests.swift](../../EVATests/Artifacts/MovementPCACorrectionTests.swift#L159) | 4/5 | 334 | S | `affectedRangesBecomeOnsetAnchoredDurationMarkers` is the largest detected routine (~48 lines, L159). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/MuscleBSSCCACorrectionTests.swift](../../EVATests/Artifacts/MuscleBSSCCACorrectionTests.swift#L135) | 4/5 | 421 | S | `selectedWindowsBecomeOnsetAnchoredDurationMarkers` is the largest detected routine (~56 lines, L135). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/SaccadicSpikeCorrectionTests.swift](../../EVATests/Artifacts/SaccadicSpikeCorrectionTests.swift#L129) | 4/5 | 161 | S | `replayPayloadPreservesSpatialFilterAndConfiguration` is the largest detected routine (~32 lines, L129). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/SourceInformedOperatorTests.swift](../../EVATests/Artifacts/SourceInformedOperatorTests.swift#L136) | 4/5 | 190 | S | `constructionRejectsMalformedAndDegenerateInputs` is the largest detected routine (~35 lines, L136). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Artifacts/ThresholdOcularReviewTests.swift](../../EVATests/Artifacts/ThresholdOcularReviewTests.swift#L44) | 4/5 | 138 | S | `exclusionsSurviveIdenticalRefreshButResetForNewInputsOrSettings` is the largest detected routine (~31 lines, L44). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestscardiac"></a>
## EVATests/Cardiac

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Cardiac/BCGDetectionViewModelTests.swift](../../EVATests/Cardiac/BCGDetectionViewModelTests.swift#L116) | 4/5 | 151 | S | `parametersCaptureBCGAndCWLSettings` is the largest detected routine (~35 lines, L116). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Cardiac/BCGDetectorTests.swift](../../EVATests/Cardiac/BCGDetectorTests.swift#L55) | 4/5 | 302 | S | `durationEstimatorFindsTheRepeatingArtifactSupport` is the largest detected routine (~36 lines, L55). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Cardiac/BCGSurrogateCorrectionTests.swift](../../EVATests/Cardiac/BCGSurrogateCorrectionTests.swift#L725) | 3/5 | 821 | S | `reliabilityGateSeparatesArtifactFromBrain` is the largest detected routine (~62 lines, L725). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Cardiac/CWLCorrectorTests.swift](../../EVATests/Cardiac/CWLCorrectorTests.swift#L18) | 4/5 | 328 | S | `testCachedWindowRegressionMatchesLegacyPerChannelSolve` is the largest detected routine (~50 lines, L18). Reading demands: numeric/GPU primitives. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Cardiac/PCASRunGradeTests.swift](../../EVATests/Cardiac/PCASRunGradeTests.swift#L32) | 4/5 | 120 | S | `report` is the largest detected routine (~16 lines, L32). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Cardiac/RWaveDetectorTests.swift](../../EVATests/Cardiac/RWaveDetectorTests.swift#L21) | 4/5 | 215 | S | `syntheticECGSource` is the largest detected routine (~30 lines, L21). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestschannels"></a>
## EVATests/Channels

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Channels/BVEFMontageTests.swift](../../EVATests/Channels/BVEFMontageTests.swift#L88) | 4/5 | 194 | S | `testRecordingOverrideLeavesSamplesUntouchedAndSurvivesMFFExport` is the largest detected routine (~55 lines, L88). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Channels/ChannelInterpolationComposerTests.swift](../../EVATests/Channels/ChannelInterpolationComposerTests.swift#L152) | 4/5 | 259 | S | `resolverRetainsMountedWaveformDuringSameSignalRefresh` is the largest detected routine (~44 lines, L152). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Channels/ChannelSetStoreTests.swift](../../EVATests/Channels/ChannelSetStoreTests.swift#L115) | 4/5 | 182 | S | `renameCascadesIntoChannelSets` is the largest detected routine (~14 lines, L115). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Channels/DisplayChannelsResolverTests.swift](../../EVATests/Channels/DisplayChannelsResolverTests.swift#L32) | 4/5 | 82 | S | `invalidSelectionFallsBackToAll` is the largest detected routine (~21 lines, L32). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Channels/ElectrodeGeometryTests.swift](../../EVATests/Channels/ElectrodeGeometryTests.swift#L20) | 4/5 | 63 | S | `loadsUnitPositionsFromCoordinatesXML` is the largest detected routine (~26 lines, L20). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Channels/ElectrodePositionsTests.swift](../../EVATests/Channels/ElectrodePositionsTests.swift#L54) | 4/5 | 119 | S | `egi` is the largest detected routine (~20 lines, L54). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Channels/MFFLocationImportTests.swift](../../EVATests/Channels/MFFLocationImportTests.swift#L122) | 4/5 | 170 | S | `testFlatOverrideRemovesOldGeometryAndStays2DAcrossExportAndReexport` is the largest detected routine (~48 lines, L122). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Channels/SensorLayoutTests.swift](../../EVATests/Channels/SensorLayoutTests.swift#L19) | 4/5 | 54 | S | `loadsAndNormalizesToUnitCircle` is the largest detected routine (~16 lines, L19). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Channels/TopomapFieldRasterTests.swift](../../EVATests/Channels/TopomapFieldRasterTests.swift#L101) | 4/5 | 125 | S | `theHeadCircleIsOpaqueAndTheCornersAreTransparent` is the largest detected routine (~24 lines, L101). Existing explanatory comments provide context. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestscombine"></a>
## EVATests/Combine

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Combine/RecordingCombinerTests.swift](../../EVATests/Combine/RecordingCombinerTests.swift#L380) | 3/5 | 753 | S | `appendedTimelineMetadataSurvivesMFFRoundTrip` is the largest detected routine (~42 lines, L380). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestscompare"></a>
## EVATests/Compare

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Compare/FilterEdgeExport.swift](../../EVATests/Compare/FilterEdgeExport.swift#L36) | 4/5 | 101 | S | `exportFilterEdges` is the largest detected routine (~65 lines, L36). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Compare/FullPipelineERPExport.swift](../../EVATests/Compare/FullPipelineERPExport.swift#L56) | 4/5 | 193 | S | `exportFullPipelineERP` is the largest detected routine (~137 lines, L56). Reading demands: asynchronous control flow. | Split setup, execution and checks in `exportFullPipelineERP`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Compare/MNERealFileReferenceTests.swift](../../EVATests/Compare/MNERealFileReferenceTests.swift#L161) | 4/5 | 196 | S | `bandPassFilterMatchesMNE` is the largest detected routine (~35 lines, L161). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Compare/MNEReferenceTests.swift](../../EVATests/Compare/MNEReferenceTests.swift#L168) | 4/5 | 224 | S | `buildEvaEvoked` is the largest detected routine (~20 lines, L168). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Compare/SignalComparisonTests.swift](../../EVATests/Compare/SignalComparisonTests.swift#L59) | 4/5 | 178 | S | `differenceStatisticsDescribeTheChange` is the largest detected routine (~20 lines, L59). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Compare/WindowComparisonRegistryTests.swift](../../EVATests/Compare/WindowComparisonRegistryTests.swift#L27) | 4/5 | 138 | S | `window` is the largest detected routine (~23 lines, L27). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestscore"></a>
## EVATests/Core

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Core/CleaningVarianceAccountTests.swift](../../EVATests/Core/CleaningVarianceAccountTests.swift#L152) | 4/5 | 259 | S | `epochBreakdownLocalizesTheArtifact` is the largest detected routine (~20 lines, L152). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Core/DSPTests.swift](../../EVATests/Core/DSPTests.swift#L210) | 4/5 | 245 | S | `pcaRecoversDominantDirection` is the largest detected routine (~24 lines, L210). Reading demands: numeric/GPU primitives. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Core/DownsamplerTests.swift](../../EVATests/Core/DownsamplerTests.swift#L73) | 4/5 | 83 | S | `decimateThenUpsampleApproximatesLinearRamp` is the largest detected routine (~10 lines, L73). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Core/ForwardOperatorTests.swift](../../EVATests/Core/ForwardOperatorTests.swift#L198) | 4/5 | 297 | S | `malformedCatalogIsRejectedAtConstruction` is the largest detected routine (~40 lines, L198). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Core/HeadTransformTests.swift](../../EVATests/Core/HeadTransformTests.swift#L60) | 4/5 | 102 | S | `scaleMatchesMNE` is the largest detected routine (~13 lines, L60). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Core/LinearAlgebraTests.swift](../../EVATests/Core/LinearAlgebraTests.swift#L85) | 4/5 | 212 | S | `symmetricEigenDecompositionReconstructsMatrix` is the largest detected routine (~25 lines, L85). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Core/SignalSelectionTests.swift](../../EVATests/Core/SignalSelectionTests.swift#L28) | 5/5 | 67 | C | Small concrete arrays, behavioral names and expected retained hits make these effective executable examples. | Preserve the simple style; add a chained-hit/tie example when clarifying mergeNearbyStarts. | — |
| [EVATests/Core/SignalStatisticsTests.swift](../../EVATests/Core/SignalStatisticsTests.swift#L40) | 4/5 | 61 | S | `sampleVarianceExceedsPopulationVariance` is the largest detected routine (~9 lines, L40). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Core/SphericalForwardModelTests.swift](../../EVATests/Core/SphericalForwardModelTests.swift#L82) | 4/5 | 148 | S | `typedValidationRejectsMalformedInputs` is the largest detected routine (~25 lines, L82). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Core/SphericalSplineTests.swift](../../EVATests/Core/SphericalSplineTests.swift#L41) | 4/5 | 78 | S | `reproducesConstantField` is the largest detected routine (~10 lines, L41). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Core/SurfaceRegistrationTests.swift](../../EVATests/Core/SurfaceRegistrationTests.swift#L89) | 4/5 | 154 | S | `fsaveragePose` is the largest detected routine (~36 lines, L89). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Core/TriangleMeshTests.swift](../../EVATests/Core/TriangleMeshTests.swift#L26) | 4/5 | 53 | S | `closestPoint` is the largest detected routine (~17 lines, L26). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Core/VolumeMorphologyTests.swift](../../EVATests/Core/VolumeMorphologyTests.swift#L35) | 4/5 | 82 | S | `componentsAndHoles` is the largest detected routine (~13 lines, L35). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestsevatestsswift"></a>
## EVATests/EVATests.swift

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/EVATests.swift](../../EVATests/EVATests.swift#L386) | 3/5 | 613 | S | `makeMFFPackage` is the largest detected routine (~70 lines, L386). Reading demands: unsafe-memory APIs. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestsepoching"></a>
## EVATests/Epoching

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Epoching/EpochBadChannelDetectorTests.swift](../../EVATests/Epoching/EpochBadChannelDetectorTests.swift#L794) | 3/5 | 1,017 | S | `rejectionSummaryCountsOverlappingReasons` is the largest detected routine (~56 lines, L794). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/EpochSNRDeterminismTests.swift](../../EVATests/Epoching/EpochSNRDeterminismTests.swift#L41) | 4/5 | 128 | S | `metricsAreReproducibleAcrossRuns` is the largest detected routine (~13 lines, L41). Existing explanatory comments provide context. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. Replace missing REWIND.md references. | — |
| [EVATests/Epoching/EpochingViewModelTests.swift](../../EVATests/Epoching/EpochingViewModelTests.swift#L110) | 4/5 | 255 | S | `parametersRoundTripPerEpochBadChannelSettings` is the largest detected routine (~35 lines, L110). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/EventTrackIndexTests.swift](../../EVATests/Epoching/EventTrackIndexTests.swift#L17) | 4/5 | 51 | S | `testVisibleMarkersUseInclusiveBinarySearchBounds` is the largest detected routine (~19 lines, L17). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Epoching/EyeArtifactThresholdDetectorTests.swift](../../EVATests/Epoching/EyeArtifactThresholdDetectorTests.swift#L45) | 4/5 | 284 | S | `hydroCelLayoutNamesUseTableOcularChannelsForAllSupportedSizes` is the largest detected routine (~24 lines, L45). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/PSAAmplitudeCutoffTests.swift](../../EVATests/Epoching/PSAAmplitudeCutoffTests.swift#L95) | 4/5 | 150 | S | `artifactHealthAndManualDecisionsAreNotBypassed` is the largest detected routine (~26 lines, L95). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/PSACategoryRejectionTests.swift](../../EVATests/Epoching/PSACategoryRejectionTests.swift#L43) | 4/5 | 224 | S | `signal` is the largest detected routine (~47 lines, L43). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/PSAConfigurationTests.swift](../../EVATests/Epoching/PSAConfigurationTests.swift#L75) | 4/5 | 116 | S | `testSheetFitsMinimumAndIdealSizesInBothAppearances` is the largest detected routine (~41 lines, L75). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/PSADecisionMatrixArtifactStatusTests.swift](../../EVATests/Epoching/PSADecisionMatrixArtifactStatusTests.swift#L60) | 4/5 | 116 | S | `everyRenderedEpochIconHasALegendMeaningAndHoverExplanation` is the largest detected routine (~25 lines, L60). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Epoching/PSADecisionMatrixLayoutTests.swift](../../EVATests/Epoching/PSADecisionMatrixLayoutTests.swift#L10) | 4/5 | 85 | S | `testCompactCellInspectorFitsFloatingAndSheetLayouts` is the largest detected routine (~75 lines, L10). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/SingleTrialAnalyzerTests.swift](../../EVATests/Epoching/SingleTrialAnalyzerTests.swift#L34) | 4/5 | 229 | S | `computesMeanAndPeaksForSingleTrial` is the largest detected routine (~38 lines, L34). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/TrialAlignmentMetricsTests.swift](../../EVATests/Epoching/TrialAlignmentMetricsTests.swift#L307) | 4/5 | 417 | S | `displaySummaryUsesLeaveOneOutReferencesForBothPanels` is the largest detected routine (~59 lines, L307). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/TrialChannelResidualAnalyzerTests.swift](../../EVATests/Epoching/TrialChannelResidualAnalyzerTests.swift#L36) | 4/5 | 98 | S | `oneBadSensorIsLocalizedAndDominatesContribution` is the largest detected routine (~21 lines, L36). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Epoching/TrialDriftStatisticsTests.swift](../../EVATests/Epoching/TrialDriftStatisticsTests.swift#L170) | 4/5 | 229 | S | `anEarlyOutlierHoldsTheAverageAwayFromWhereItEndsUp` is the largest detected routine (~28 lines, L170). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/TrialExclusionApplicationTests.swift](../../EVATests/Epoching/TrialExclusionApplicationTests.swift#L52) | 4/5 | 413 | S | `signal` is the largest detected routine (~37 lines, L52). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/TrialExclusionResolverTests.swift](../../EVATests/Epoching/TrialExclusionResolverTests.swift#L158) | 3/5 | 789 | S | `everyRecordedFieldSurvivesTheFile` is the largest detected routine (~38 lines, L158). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/TrialSelectionAnalyzerTests.swift](../../EVATests/Epoching/TrialSelectionAnalyzerTests.swift#L131) | 4/5 | 233 | S | `droppingGenuinelyNoisyTrialsRaisesSNRBeyondTheNull` is the largest detected routine (~26 lines, L131). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/TrialSelectionReviewTests.swift](../../EVATests/Epoching/TrialSelectionReviewTests.swift#L31) | 4/5 | 206 | S | `reviewed` is the largest detected routine (~10 lines, L31). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Epoching/TrialSimilarityAnalyzerTests.swift](../../EVATests/Epoching/TrialSimilarityAnalyzerTests.swift#L219) | 4/5 | 399 | S | `flankerCategories` is the largest detected routine (~27 lines, L219). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestsfiltering"></a>
## EVATests/Filtering

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Filtering/EEGSignalFilterTests.swift](../../EVATests/Filtering/EEGSignalFilterTests.swift#L26) | 4/5 | 194 | S | `bandPassPreservesInBandAndAttenuatesOutOfBand` is the largest detected routine (~25 lines, L26). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Filtering/EllipticFilterTests.swift](../../EVATests/Filtering/EllipticFilterTests.swift#L18) | 4/5 | 67 | S | `ellipticBandPassPreservesPassbandAndRejectsStopbands` is the largest detected routine (~27 lines, L18). Reading demands: asynchronous control flow. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Filtering/FIRDesignRuleTests.swift](../../EVATests/Filtering/FIRDesignRuleTests.swift#L50) | 4/5 | 198 | S | `clampedRulesMatchMNEsTransitionWidths` is the largest detected routine (~23 lines, L50). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Filtering/FIRFilterTests.swift](../../EVATests/Filtering/FIRFilterTests.swift#L117) | 4/5 | 251 | S | `forwardFIRRetainsDelayWhileCompensatedModeRemovesIt` is the largest detected routine (~28 lines, L117). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Filtering/FilterViewModelTests.swift](../../EVATests/Filtering/FilterViewModelTests.swift#L135) | 4/5 | 494 | S | `approximationPresetsConfigureOnlyFilterMechanics` is the largest detected routine (~30 lines, L135). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REFACTOR.md references. | — |

<a id="evatestsfixtures"></a>
## EVATests/Fixtures

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Fixtures/SimulationTruthFixture.swift](../../EVATests/Fixtures/SimulationTruthFixture.swift#L68) | 4/5 | 71 | S | `load` is the largest detected routine (~3 lines, L68). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Fixtures/generate_tf_reference.py](../../EVATests/Fixtures/generate_tf_reference.py#L63) | 4/5 | 141 | S | `main` is the largest detected routine (~75 lines, L63). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestsfixturesswift"></a>
## EVATests/Fixtures.swift

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Fixtures.swift](../../EVATests/Fixtures.swift#L35) | 4/5 | 43 | S | `url` is the largest detected routine (~8 lines, L35). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestsgradient"></a>
## EVATests/Gradient

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Gradient/FASTRC5EvaluationTests.swift](../../EVATests/Gradient/FASTRC5EvaluationTests.swift#L224) | 3/5 | 359 | S | `cases` is the largest detected routine (~79 lines, L224). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientAASTests.swift](../../EVATests/Gradient/GradientAASTests.swift#L119) | 4/5 | 192 | S | `censoredVolumesAreCorrectedButNeverDonate` is the largest detected routine (~43 lines, L119). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientANCTests.swift](../../EVATests/Gradient/GradientANCTests.swift#L132) | 4/5 | 225 | S | `smallerStepSizesEatLessUncorrelatedSignal` is the largest detected routine (~21 lines, L132). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientBackendParityTests.swift](../../EVATests/Gradient/GradientBackendParityTests.swift#L130) | 4/5 | 435 | S | `expectDecisionParity` is the largest detected routine (~30 lines, L130). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientBrainSafetyRegressionTests.swift](../../EVATests/Gradient/GradientBrainSafetyRegressionTests.swift#L232) | 4/5 | 283 | S | `rawCorrelationRankingErasesAPhaseLockedConditionDifference` is the largest detected routine (~51 lines, L232). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientCorrectorStagesTests.swift](../../EVATests/Gradient/GradientCorrectorStagesTests.swift#L436) | 4/5 | 512 | S | `ancExcludedChannelsAreStillCorrectedButNotAdapted` is the largest detected routine (~29 lines, L436). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientCoverageTests.swift](../../EVATests/Gradient/GradientCoverageTests.swift#L229) | 4/5 | 444 | S | `aFailedRunMarksItsSpansOnTheCorrectedSignal` is the largest detected routine (~25 lines, L229). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientDonorSelectionTests.swift](../../EVATests/Gradient/GradientDonorSelectionTests.swift#L310) | 4/5 | 357 | S | `squaredCorrelationAdmitsTheTargetOnlyWhenSelfDonationIsRequested` is the largest detected routine (~19 lines, L310). Reading demands: unsafe-memory APIs. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientEpochAlignerTests.swift](../../EVATests/Gradient/GradientEpochAlignerTests.swift#L193) | 4/5 | 221 | S | `subSampleAlignmentBringsDriftingVolumeEpochsCloseToTheBrain` is the largest detected routine (~28 lines, L193). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientEpochLayoutTests.swift](../../EVATests/Gradient/GradientEpochLayoutTests.swift#L22) | 4/5 | 233 | S | `build` is the largest detected routine (~15 lines, L22). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientFiltersTests.swift](../../EVATests/Gradient/GradientFiltersTests.swift#L99) | 4/5 | 124 | S | `detrendingKeepsOscillationRidingOnATrend` is the largest detected routine (~18 lines, L99). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Gradient/GradientOBSTests.swift](../../EVATests/Gradient/GradientOBSTests.swift#L139) | 4/5 | 262 | S | `automaticModeStopsOnceTheVarianceThresholdIsMet` is the largest detected routine (~24 lines, L139). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientRunGradeMeasurementTests.swift](../../EVATests/Gradient/GradientRunGradeMeasurementTests.swift#L218) | 3/5 | 398 | S | `gradientResidualMetricVersusTruth` is the largest detected routine (~180 lines, L218). Reading demands: asynchronous control flow. | Split setup, execution and checks in `gradientResidualMetricVersusTruth`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientRunGradeTests.swift](../../EVATests/Gradient/GradientRunGradeTests.swift#L32) | 4/5 | 168 | S | `fixture` is the largest detected routine (~30 lines, L32). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientSincResamplerTests.swift](../../EVATests/Gradient/GradientSincResamplerTests.swift#L59) | 4/5 | 143 | S | `upsampleApproximatesTheUnderlyingContinuousSignal` is the largest detected routine (~17 lines, L59). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Gradient/GradientTemplateCorrectorTests.swift](../../EVATests/Gradient/GradientTemplateCorrectorTests.swift#L473) | 3/5 | 1,093 | S | `aFinalEpochShortOnlyOfItsClosingSampleIsCorrectedInPlace` is the largest detected routine (~33 lines, L473). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/GradientTimingCheckTests.swift](../../EVATests/Gradient/GradientTimingCheckTests.swift#L59) | 4/5 | 75 | S | `timingAssessmentPersistsWithoutBreakingOlderRunMetrics` is the largest detected routine (~16 lines, L59). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Gradient/GradientViewModelTests.swift](../../EVATests/Gradient/GradientViewModelTests.swift#L24) | 3/5 | 841 | S | `farmPresetAndLegacyReplay` is the largest detected routine (~43 lines, L24). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REFACTOR.md references. | — |
| [EVATests/Gradient/LocalTemplateArtifactCompatibilityTests.swift](../../EVATests/Gradient/LocalTemplateArtifactCompatibilityTests.swift#L70) | 4/5 | 328 | S | `cleanLocalWAASDocumentsOldGlobalSelfDonationDifference` is the largest detected routine (~48 lines, L70). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/LocalTemplateArtifactCorrectorTests.swift](../../EVATests/Gradient/LocalTemplateArtifactCorrectorTests.swift#L88) | 4/5 | 451 | S | `exponentialWeightingFavorsTheNearerDonorAndNormalizesConstants` is the largest detected routine (~32 lines, L88). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/LocalTemplateBackendParityTests.swift](../../EVATests/Gradient/LocalTemplateBackendParityTests.swift#L193) | 4/5 | 306 | S | `degenerateShapesAgree` is the largest detected routine (~35 lines, L193). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/MotionParametersTests.swift](../../EVATests/Gradient/MotionParametersTests.swift#L151) | 4/5 | 177 | S | `realFixturesParseAndTheTwoFormatsAgree` is the largest detected routine (~26 lines, L151). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Gradient/TRSpacingTests.swift](../../EVATests/Gradient/TRSpacingTests.swift#L19) | 4/5 | 70 | S | `evenlySpacedTriggers` is the largest detected routine (~9 lines, L19). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestshealth"></a>
## EVATests/Health

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Health/ChannelHealthAnalyzerTests.swift](../../EVATests/Health/ChannelHealthAnalyzerTests.swift#L32) | 4/5 | 101 | S | `flatAndClippingChannelsGradeWorseThanCleanChannels` is the largest detected routine (~24 lines, L32). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Health/ChannelHealthViewModelTests.swift](../../EVATests/Health/ChannelHealthViewModelTests.swift#L86) | 4/5 | 102 | S | `oldPreferencesEnableAutomaticWaveletsAndKeepCustomSettings` is the largest detected routine (~16 lines, L86). Reading demands: asynchronous control flow. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Health/ChannelRelationshipAnalyzerTests.swift](../../EVATests/Health/ChannelRelationshipAnalyzerTests.swift#L111) | 4/5 | 205 | S | `averageReferenceRestoresAnOmittedAcquisitionReferenceBeforeTakingTheMean` is the largest detected routine (~32 lines, L111). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Health/HealthScoringTests.swift](../../EVATests/Health/HealthScoringTests.swift#L66) | 4/5 | 75 | S | `formattingHelpers` is the largest detected routine (~9 lines, L66). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Health/SegmentHealthAnalyzerTests.swift](../../EVATests/Health/SegmentHealthAnalyzerTests.swift#L261) | 4/5 | 321 | S | `trainingExportRecordsWhetherArtifactsWereAssessed` is the largest detected routine (~60 lines, L261). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestshelp"></a>
## EVATests/Help

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Help/MarkdownDocumentTests.swift](../../EVATests/Help/MarkdownDocumentTests.swift#L230) | 4/5 | 262 | S | `fullDocument` is the largest detected routine (~32 lines, L230). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Help/ReleaseNotesCatalogTests.swift](../../EVATests/Help/ReleaseNotesCatalogTests.swift#L115) | 4/5 | 193 | S | `ordering` is the largest detected routine (~24 lines, L115). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestsica"></a>
## EVATests/ICA

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/ICA/BCGComponentLabellerTests.swift](../../EVATests/ICA/BCGComponentLabellerTests.swift#L111) | 4/5 | 276 | S | `simulatorTrainingGeneralizesToHeldOutGeneratorConfigurationAndImprovesCorrection` is the largest detected routine (~71 lines, L111). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/ICA/ICAArtifactDetectorTests.swift](../../EVATests/ICA/ICAArtifactDetectorTests.swift#L76) | 4/5 | 185 | S | `mixingReconstructsCenteredData` is the largest detected routine (~20 lines, L76). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/ICA/ICAComponentAutoLabelerTests.swift](../../EVATests/ICA/ICAComponentAutoLabelerTests.swift#L44) | 4/5 | 194 | S | `decomposition` is the largest detected routine (~31 lines, L44). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/ICA/ICAComponentLabellerBenchmarkTests.swift](../../EVATests/ICA/ICAComponentLabellerBenchmarkTests.swift#L44) | 4/5 | 200 | S | `simulatedPerClassBenchmark` is the largest detected routine (~100 lines, L44). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/ICA/ICAComponentRemovalTests.swift](../../EVATests/ICA/ICAComponentRemovalTests.swift#L81) | 4/5 | 269 | S | `applyingARemovalCommitsAndInvalidatesDownstream` is the largest detected routine (~25 lines, L81). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/ICA/ICAPicardOReferenceCrossCheckTests.swift](../../EVATests/ICA/ICAPicardOReferenceCrossCheckTests.swift#L51) | 4/5 | 93 | S | `crossCheckPicardOAgainstReference` is the largest detected routine (~42 lines, L51). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/ICA/ICAReplayPayloadTests.swift](../../EVATests/ICA/ICAReplayPayloadTests.swift#L137) | 4/5 | 310 | S | `rehydratedApplyRebuildsTheActivationCopy` is the largest detected routine (~25 lines, L137). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/ICA/ICARunGradeMeasurementTests.swift](../../EVATests/ICA/ICARunGradeMeasurementTests.swift#L185) | 4/5 | 330 | S | `dataSufficiencyVersusDecompositionQuality` is the largest detected routine (~145 lines, L185). Reading demands: asynchronous control flow. | Split setup, execution and checks in `dataSufficiencyVersusDecompositionQuality`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/ICA/ICARunGradeTests.swift](../../EVATests/ICA/ICARunGradeTests.swift#L22) | 4/5 | 115 | S | `decomposition` is the largest detected routine (~24 lines, L22). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/ICA/ICLabelClassifierTests.swift](../../EVATests/ICA/ICLabelClassifierTests.swift#L24) | 4/5 | 67 | S | `decomposition` is the largest detected routine (~26 lines, L24). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestsio"></a>
## EVATests/IO

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/IO/BDFImportTests.swift](../../EVATests/IO/BDFImportTests.swift#L305) | 3/5 | 346 | S | `make` is the largest detected routine (~41 lines, L305). Reading demands: asynchronous control flow, unsafe-memory APIs. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/BEMImportTests.swift](../../EVATests/IO/BEMImportTests.swift#L192) | 4/5 | 316 | S | `meshFormats` is the largest detected routine (~32 lines, L192). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/BESAImportTests.swift](../../EVATests/IO/BESAImportTests.swift#L52) | 4/5 | 112 | S | `testRaggedRowsAreRejectedForBothOrientations` is the largest detected routine (~27 lines, L52). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/BrainVisionImportTests.swift](../../EVATests/IO/BrainVisionImportTests.swift#L17) | 4/5 | 210 | S | `testMarkersPreserveTypeDescriptionAndDuration` is the largest detected routine (~58 lines, L17). Reading demands: unsafe-memory APIs. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/CIFTIQuickLookReaderTests.swift](../../EVATests/IO/CIFTIQuickLookReaderTests.swift#L202) | 3/5 | 263 | S | `make` is the largest detected routine (~39 lines, L202). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/DICOMQuickLookReaderTests.swift](../../EVATests/IO/DICOMQuickLookReaderTests.swift#L14) | 3/5 | 232 | C | The tests read as observable behavior, but transfer-syntax UIDs and synthetic binary fixture construction need format knowledge. | Name the fixture variants and document the expected raw-pixel-to-physical-value transformation. | Initial focused comments |
| [EVATests/IO/EDFImportTests.swift](../../EVATests/IO/EDFImportTests.swift#L106) | 4/5 | 163 | S | `makeEDF` is the largest detected routine (~46 lines, L106). Reading demands: unsafe-memory APIs. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/EGISensorXMLParserTests.swift](../../EVATests/IO/EGISensorXMLParserTests.swift#L59) | 4/5 | 75 | S | `simulatedCoordinatesUseEGICentimeters` is the largest detected routine (~16 lines, L59). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/EventTimeAnchorTests.swift](../../EVATests/IO/EventTimeAnchorTests.swift#L247) | 4/5 | 300 | S | `exportWritesTheOnsetOfACenteredEvent` is the largest detected routine (~21 lines, L247). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/FIFImportTests.swift](../../EVATests/IO/FIFImportTests.swift#L21) | 4/5 | 138 | S | `continuousImport` is the largest detected routine (~34 lines, L21). Existing explanatory comments provide context. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/FIFInteropTests.swift](../../EVATests/IO/FIFInteropTests.swift#L103) | 4/5 | 156 | S | `readBEM` is the largest detected routine (~34 lines, L103). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/FIFPreviewTests.swift](../../EVATests/IO/FIFPreviewTests.swift#L197) | 4/5 | 308 | S | `rendering` is the largest detected routine (~49 lines, L197). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/FIFRecordingTests.swift](../../EVATests/IO/FIFRecordingTests.swift#L201) | 4/5 | 233 | S | `averagedData` is the largest detected routine (~32 lines, L201). Reading demands: unsafe-memory APIs. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/FigureExportTests.swift](../../EVATests/IO/FigureExportTests.swift#L22) | 4/5 | 77 | S | `formatExtensionsAndTypes` is the largest detected routine (~15 lines, L22). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/ForwardFixtureTests.swift](../../EVATests/IO/ForwardFixtureTests.swift#L52) | 4/5 | 148 | S | `caseShape` is the largest detected routine (~29 lines, L52). Existing explanatory comments provide context. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/GIFTIQuickLookReaderTests.swift](../../EVATests/IO/GIFTIQuickLookReaderTests.swift#L248) | 3/5 | 444 | S | `surfaceXML` is the largest detected routine (~46 lines, L248). Reading demands: unsafe-memory APIs. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/GrandAverageReaderTests.swift](../../EVATests/IO/GrandAverageReaderTests.swift#L26) | 4/5 | 103 | S | `detectsGrandAverageFromAverageSegNameAndRepeatedCategory` is the largest detected routine (~63 lines, L26). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/MFFAcquisitionGapTests.swift](../../EVATests/IO/MFFAcquisitionGapTests.swift#L27) | 4/5 | 143 | S | `acquisitionEpochsRestoreMissingSamplesAndPreserveTaskTimes` is the largest detected routine (~30 lines, L27). Reading demands: asynchronous control flow. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/MFFAveragedRoundTripTests.swift](../../EVATests/IO/MFFAveragedRoundTripTests.swift#L177) | 4/5 | 221 | S | `eventRoundTripProducesIdenticalPSASampleRanges` is the largest detected routine (~44 lines, L177). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/MFFEventPrecisionTests.swift](../../EVATests/IO/MFFEventPrecisionTests.swift#L41) | 4/5 | 153 | S | `makeSignal` is the largest detected routine (~24 lines, L41). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/MFFExportWriterTests.swift](../../EVATests/IO/MFFExportWriterTests.swift#L20) | 4/5 | 54 | S | `exportKeepsProcessingRecordInsideActualPackage` is the largest detected routine (~34 lines, L20). Reading demands: asynchronous control flow. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/MFFFileTypeTests.swift](../../EVATests/IO/MFFFileTypeTests.swift#L60) | 4/5 | 92 | S | `overlaySelectionResolvesAllAndToggles` is the largest detected routine (~22 lines, L60). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/MFFPNSReaderTests.swift](../../EVATests/IO/MFFPNSReaderTests.swift#L105) | 4/5 | 140 | S | `writerDoesNotInventPolarityFlagsForUnflaggedPNS` is the largest detected routine (~35 lines, L105). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/MFFQuickLookSummaryTests.swift](../../EVATests/IO/MFFQuickLookSummaryTests.swift#L213) | 4/5 | 296 | S | `declaredRejectionsInEvaXMLDriveTheKeptRejectedSplit` is the largest detected routine (~36 lines, L213). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/MFFSignalSplitterTests.swift](../../EVATests/IO/MFFSignalSplitterTests.swift#L17) | 4/5 | 76 | S | `testSplitSlicesSamplesAndShiftsEvents` is the largest detected routine (~36 lines, L17). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/MGHQuickLookReaderTests.swift](../../EVATests/IO/MGHQuickLookReaderTests.swift#L70) | 4/5 | 121 | S | `make` is the largest detected routine (~21 lines, L70). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/NIfTIQuickLookReaderTests.swift](../../EVATests/IO/NIfTIQuickLookReaderTests.swift#L294) | 3/5 | 425 | S | `make` is the largest detected routine (~65 lines, L294). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/IO/NIfTIVolumeTests.swift](../../EVATests/IO/NIfTIVolumeTests.swift#L107) | 4/5 | 146 | S | `writeRoundTrip` is the largest detected routine (~28 lines, L107). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/PersystImportTests.swift](../../EVATests/IO/PersystImportTests.swift#L58) | 4/5 | 98 | S | `makeFixture` is the largest detected routine (~30 lines, L58). Reading demands: unsafe-memory APIs. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/IO/PhysioTextImporterTests.swift](../../EVATests/IO/PhysioTextImporterTests.swift#L36) | 4/5 | 86 | S | `parsesHeaderedMultiColumnWithoutTimeAxis` is the largest detected routine (~14 lines, L36). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evatestspipeline"></a>
## EVATests/Pipeline

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Pipeline/BatchCheckpointTests.swift](../../EVATests/Pipeline/BatchCheckpointTests.swift#L174) | 4/5 | 286 | S | `ICAIdentityMustMatchTheSidecarInsideTheCheckpoint` is the largest detected routine (~38 lines, L174). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/BatchControllerTests.swift](../../EVATests/Pipeline/BatchControllerTests.swift#L157) | 4/5 | 203 | S | `headlessSkipDecisionPolicyCompletesAndAuditsDroppedStep` is the largest detected routine (~28 lines, L157). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/BatchPrefixPlannerTests.swift](../../EVATests/Pipeline/BatchPrefixPlannerTests.swift#L86) | 4/5 | 170 | S | `supportedPCASIsEligibleButMissingEvidenceStopsOrDropsIt` is the largest detected routine (~37 lines, L86). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/ChannelDecisionStepsTests.swift](../../EVATests/Pipeline/ChannelDecisionStepsTests.swift#L205) | 4/5 | 293 | S | `headlessCoreAppliesMarkBadAndPreservesItOnTheWayOut` is the largest detected routine (~37 lines, L205). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/Pipeline/CleaningVarianceLedgerTests.swift](../../EVATests/Pipeline/CleaningVarianceLedgerTests.swift#L79) | 4/5 | 98 | S | `auditLineNamesFlatChannels` is the largest detected routine (~15 lines, L79). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Pipeline/EVAHistoryTests.swift](../../EVATests/Pipeline/EVAHistoryTests.swift#L152) | 4/5 | 549 | S | `linearAdoptionPrunesAtADeeperDivergenceAfterMultiStepUndo` is the largest detected routine (~25 lines, L152). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/Pipeline/EVAProcessingScriptIOTests.swift](../../EVATests/Pipeline/EVAProcessingScriptIOTests.swift#L42) | 4/5 | 62 | S | `readFromFileResolvesPackageDirectory` is the largest detected routine (~14 lines, L42). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Pipeline/EVAProcessingScriptXMLTests.swift](../../EVATests/Pipeline/EVAProcessingScriptXMLTests.swift#L115) | 4/5 | 140 | S | `regexRulesSurviveTheScript` is the largest detected routine (~19 lines, L115). Existing explanatory comments provide context. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Pipeline/FilterReplayTests.swift](../../EVATests/Pipeline/FilterReplayTests.swift#L28) | 4/5 | 93 | S | `filterApplyParametersRoundTrip` is the largest detected routine (~20 lines, L28). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Pipeline/GradientReplayTests.swift](../../EVATests/Pipeline/GradientReplayTests.swift#L24) | 4/5 | 230 | S | `gradientApplyParametersRoundTrip` is the largest detected routine (~65 lines, L24). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/HeadlessBatchProcessorTests.swift](../../EVATests/Pipeline/HeadlessBatchProcessorTests.swift#L31) | 4/5 | 84 | S | `filterOnlyScriptCompletesAndWritesOutput` is the largest detected routine (~22 lines, L31). Reading demands: asynchronous control flow. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Pipeline/HistoryRailDerivationTests.swift](../../EVATests/Pipeline/HistoryRailDerivationTests.swift#L217) | 4/5 | 386 | S | `applyingANewFilterAfterRemovalDiscardsTheUndoneFilter` is the largest detected routine (~23 lines, L217). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/HistoryReDerivationSourceTests.swift](../../EVATests/Pipeline/HistoryReDerivationSourceTests.swift#L116) | 4/5 | 239 | S | `doubleFilteringChangesTheSamples` is the largest detected routine (~29 lines, L116). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/HistorySurfaceTests.swift](../../EVATests/Pipeline/HistorySurfaceTests.swift#L67) | 4/5 | 158 | S | `undoIsNavigation` is the largest detected routine (~23 lines, L67). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/InvalidationAuthorityTests.swift](../../EVATests/Pipeline/InvalidationAuthorityTests.swift#L119) | 4/5 | 152 | S | `noHandAssembledBaseSignalCascades` is the largest detected routine (~33 lines, L119). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/LatestOnlyRunnerTests.swift](../../EVATests/Pipeline/LatestOnlyRunnerTests.swift#L77) | 4/5 | 206 | C | The gate explains why concurrency order is deterministic; continuations and cooperative scheduling remain advanced Swift. | Add a short event-order table for the superseded-run test and a pointer to the concurrency primer. | — |
| [EVATests/Pipeline/MethodComparison/ComparisonMatrix.swift](../../EVATests/Pipeline/MethodComparison/ComparisonMatrix.swift#L211) | 4/5 | 258 | S | `validate` is the largest detected routine (~36 lines, L211). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/MethodComparison/MethodComparisonRunner.swift](../../EVATests/Pipeline/MethodComparison/MethodComparisonRunner.swift#L392) | 3/5 | 848 | S | `run` is the largest detected routine (~74 lines, L392). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/MethodComparison/MethodComparisonTests.swift](../../EVATests/Pipeline/MethodComparison/MethodComparisonTests.swift#L249) | 4/5 | 357 | S | `gradientMethodComparisonProducesATable` is the largest detected routine (~65 lines, L249). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/OperationProgressTests.swift](../../EVATests/Pipeline/OperationProgressTests.swift#L61) | 4/5 | 94 | S | `fractionsAreClamped` is the largest detected routine (~33 lines, L61). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Pipeline/PairedValidationTests.swift](../../EVATests/Pipeline/PairedValidationTests.swift#L375) | 3/5 | 765 | S | `icaReplayThroughTheCoreMatchesDirectApply` is the largest detected routine (~58 lines, L375). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/ParameterSerializationAuditTests.swift](../../EVATests/Pipeline/ParameterSerializationAuditTests.swift#L172) | 4/5 | 283 | S | `icaCarriesEveryFitInput` is the largest detected routine (~33 lines, L172). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/Pipeline/PipelineInvalidationTests.swift](../../EVATests/Pipeline/PipelineInvalidationTests.swift#L35) | 4/5 | 235 | S | `baseSignalChangeClearsEveryDownstreamStage` is the largest detected routine (~44 lines, L35). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/PipelineRegressionTests.swift](../../EVATests/Pipeline/PipelineRegressionTests.swift#L227) | 3/5 | 885 | S | `lockedClockGradientCorrectionHoldsItsQuality` is the largest detected routine (~126 lines, L227). Reading demands: asynchronous control flow. | Split setup, execution and checks in `lockedClockGradientCorrectionHoldsItsQuality`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/PipelineSnapshotTests.swift](../../EVATests/Pipeline/PipelineSnapshotTests.swift#L118) | 4/5 | 414 | S | `everyStageSurvivesCaptureAndRestore` is the largest detected routine (~27 lines, L118). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/Pipeline/PipelineStageTogglesTests.swift](../../EVATests/Pipeline/PipelineStageTogglesTests.swift#L212) | 4/5 | 262 | S | `disablingBCGRemovesOnlyItsOwnContributions` is the largest detected routine (~25 lines, L212). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/Pipeline/ProcessingCoreTests.swift](../../EVATests/Pipeline/ProcessingCoreTests.swift#L218) | 4/5 | 417 | S | `stimSignal` is the largest detected routine (~30 lines, L218). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/ProcessingQueueTests.swift](../../EVATests/Pipeline/ProcessingQueueTests.swift#L19) | 4/5 | 148 | S | `operationsRunOneAtATimeNotConcurrently` is the largest detected routine (~35 lines, L19). Reading demands: asynchronous control flow. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Pipeline/ProcessingStoreTests.swift](../../EVATests/Pipeline/ProcessingStoreTests.swift#L34) | 4/5 | 73 | S | `epochingParameters` is the largest detected routine (~13 lines, L34). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. Replace missing REFACTOR.md references. | — |
| [EVATests/Pipeline/RecordingHistoryForkTests.swift](../../EVATests/Pipeline/RecordingHistoryForkTests.swift#L81) | 4/5 | 170 | S | `forkedHistoriesDivergeIndependently` is the largest detected routine (~25 lines, L81). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/Pipeline/RecordingHistoryOnDiskPrefixTests.swift](../../EVATests/Pipeline/RecordingHistoryOnDiskPrefixTests.swift#L68) | 4/5 | 162 | S | `onlyTheTipHasASnapshot` is the largest detected routine (~21 lines, L68). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/ReplayCompatibilityTests.swift](../../EVATests/Pipeline/ReplayCompatibilityTests.swift#L247) | 4/5 | 327 | S | `windowedBatchUsesTheSamePerFileDropAndAuditRule` is the largest detected routine (~47 lines, L247). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/ReplayControllerTests.swift](../../EVATests/Pipeline/ReplayControllerTests.swift#L154) | 4/5 | 165 | S | `aNewRunStartsUncancelled` is the largest detected routine (~11 lines, L154). Reading demands: asynchronous control flow. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/ReplaySettingsRestoreTests.swift](../../EVATests/Pipeline/ReplaySettingsRestoreTests.swift#L256) | 4/5 | 305 | S | `steppingBackBeforeACommitStays` is the largest detected routine (~49 lines, L256). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/SnapshotPolicyTests.swift](../../EVATests/Pipeline/SnapshotPolicyTests.swift#L219) | 4/5 | 282 | S | `supportedStepMatrix` is the largest detected routine (~37 lines, L219). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. Replace missing REWIND.md references. | — |
| [EVATests/Pipeline/StageCommitTests.swift](../../EVATests/Pipeline/StageCommitTests.swift#L165) | 4/5 | 280 | S | `definedArtifact` is the largest detected routine (~27 lines, L165). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Pipeline/ThresholdAndPSAReplayTests.swift](../../EVATests/Pipeline/ThresholdAndPSAReplayTests.swift#L49) | 4/5 | 106 | S | `epochingParametersRoundTrip` is the largest detected routine (~29 lines, L49). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Pipeline/ThresholdConfigCommitTests.swift](../../EVATests/Pipeline/ThresholdConfigCommitTests.swift#L92) | 4/5 | 153 | S | `oneNodePerCommittedChange` is the largest detected routine (~29 lines, L92). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestsrhythmicity"></a>
## EVATests/Rhythmicity

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Rhythmicity/ABBAEngineTests.swift](../../EVATests/Rhythmicity/ABBAEngineTests.swift#L34) | 4/5 | 165 | S | `medianOnlyBandsMatchPinnedPythonBorders` is the largest detected routine (~26 lines, L34). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/AccelerateFFTComplexCoefficientProviderTests.swift](../../EVATests/Rhythmicity/AccelerateFFTComplexCoefficientProviderTests.swift#L11) | 3/5 | 385 | S | `forcedMultiBlockCoefficientsMatchDirectOracle` is the largest detected routine (~54 lines, L11). Reading demands: numeric/GPU primitives. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/AperiodicSpectrumEstimatorTests.swift](../../EVATests/Rhythmicity/AperiodicSpectrumEstimatorTests.swift#L22) | 4/5 | 92 | S | `welchWindowsNeverBridgeSegments` is the largest detected routine (~27 lines, L22). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Rhythmicity/ComplexCoefficientProviderTests.swift](../../EVATests/Rhythmicity/ComplexCoefficientProviderTests.swift#L35) | 4/5 | 94 | S | `fieldTripConventionMatchesPinnedImpulseCoefficients` is the largest detected routine (~27 lines, L35). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Rhythmicity/IAAFTSurrogateGeneratorTests.swift](../../EVATests/Rhythmicity/IAAFTSurrogateGeneratorTests.swift#L36) | 4/5 | 130 | S | `followsWhitePinkAndSteepTargetSpectra` is the largest detected routine (~27 lines, L36). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Rhythmicity/LAVIEngineTests.swift](../../EVATests/Rhythmicity/LAVIEngineTests.swift#L27) | 3/5 | 316 | C | Behavioral test names and simple sine cases help; the pinned oracle, scientific configuration and 1e-10 tolerance lack local rationale. | Explain fixture provenance and tolerance once; distinguish expected behavior tests from numerical parity checks. | Initial focused comments |
| [EVATests/Rhythmicity/LAVISignificanceProviderTests.swift](../../EVATests/Rhythmicity/LAVISignificanceProviderTests.swift#L210) | 3/5 | 427 | S | `exactPerChannelCacheReusesOnlyCompleteMatchingSignificance` is the largest detected routine (~126 lines, L210). Test names and assertions provide the main narrative. | Split setup, execution and checks in `exactPerChannelCacheReusesOnlyCompleteMatchingSignificance`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/RhythmicBurstDetectorTests.swift](../../EVATests/Rhythmicity/RhythmicBurstDetectorTests.swift#L158) | 4/5 | 215 | S | `exportBundleContainsMapsTablesProvenanceAndSafetyBoundary` is the largest detected routine (~36 lines, L158). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/RhythmicityExportTests.swift](../../EVATests/Rhythmicity/RhythmicityExportTests.swift#L25) | 4/5 | 89 | S | `packageContainsVersionedManifestLongCSVsAndNumpyArrays` is the largest detected routine (~64 lines, L25). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/RhythmicityMFFIntegrationTests.swift](../../EVATests/Rhythmicity/RhythmicityMFFIntegrationTests.swift#L59) | 4/5 | 285 | S | `check` is the largest detected routine (~132 lines, L59). Existing explanatory comments provide context. | Split setup, execution and checks in `check`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/RhythmicityMilestone0Tests.swift](../../EVATests/Rhythmicity/RhythmicityMilestone0Tests.swift#L137) | 4/5 | 187 | S | `lavi` is the largest detected routine (~50 lines, L137). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/RhythmicityMilestone8Tests.swift](../../EVATests/Rhythmicity/RhythmicityMilestone8Tests.swift#L263) | 3/5 | 421 | S | `persistedPayloadRoundTripsAndTracksSourceAndUpstreamStaleness` is the largest detected routine (~56 lines, L263). Reading demands: numeric/GPU primitives. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/RhythmicityTimeFrequencyIntegrationTests.swift](../../EVATests/Rhythmicity/RhythmicityTimeFrequencyIntegrationTests.swift#L106) | 4/5 | 160 | S | `makeFixture` is the largest detected routine (~54 lines, L106). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/WTPLEngineTests.swift](../../EVATests/Rhythmicity/WTPLEngineTests.swift#L31) | 4/5 | 211 | S | `matchesIndependentPythonPaperEquationOracle` is the largest detected routine (~26 lines, L31). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Rhythmicity/WTPLIntegrationTests.swift](../../EVATests/Rhythmicity/WTPLIntegrationTests.swift#L61) | 4/5 | 177 | S | `timeFrequencyShortcutDelegatesToSharedEngine` is the largest detected routine (~73 lines, L61). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestssimulation"></a>
## EVATests/Simulation

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Simulation/ERPExperimentTests.swift](../../EVATests/Simulation/ERPExperimentTests.swift#L50) | 4/5 | 204 | S | `recipesAndOmissions` is the largest detected routine (~23 lines, L50). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Simulation/ERPGroupAndOptionsTests.swift](../../EVATests/Simulation/ERPGroupAndOptionsTests.swift#L62) | 4/5 | 179 | S | `invalidDefinitions` is the largest detected routine (~25 lines, L62). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Simulation/EVASimulateSelfTestTests.swift](../../EVATests/Simulation/EVASimulateSelfTestTests.swift#L47) | 4/5 | 76 | S | `selfTestPasses` is the largest detected routine (~29 lines, L47). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Simulation/GradientTemplateBandLimitTests.swift](../../EVATests/Simulation/GradientTemplateBandLimitTests.swift#L65) | 4/5 | 96 | S | `theLeadInFollowsTheMargin` is the largest detected routine (~24 lines, L65). Reading demands: numeric/GPU primitives. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Simulation/SimulationSweepTests.swift](../../EVATests/Simulation/SimulationSweepTests.swift#L114) | 4/5 | 191 | S | `gridCLI` is the largest detected routine (~27 lines, L114). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Simulation/SimulatorRunnerTests.swift](../../EVATests/Simulation/SimulatorRunnerTests.swift#L42) | 4/5 | 297 | S | `guiDefaultGradientSupportsBothEpochGeometries` is the largest detected routine (~62 lines, L42). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestssyntheticsignalswift"></a>
## EVATests/SyntheticSignal.swift

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/SyntheticSignal.swift](../../EVATests/SyntheticSignal.swift#L54) | 4/5 | 94 | S | `plantedBumps` is the largest detected routine (~25 lines, L54). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evateststimefrequency"></a>
## EVATests/TimeFrequency

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/TimeFrequency/TimeFrequencyEngineTests.swift](../../EVATests/TimeFrequency/TimeFrequencyEngineTests.swift#L239) | 4/5 | 400 | S | `erspRecoversBurstFrequencyLatencyAndPower` is the largest detected routine (~49 lines, L239). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evateststrials"></a>
## EVATests/Trials

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Trials/CWTRidgePipelineTests.swift](../../EVATests/Trials/CWTRidgePipelineTests.swift#L211) | 4/5 | 293 | S | `pipelineFiltersDetectedPeaksThroughEveryConfiguredWindow` is the largest detected routine (~36 lines, L211). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Trials/ClusterFormationTests.swift](../../EVATests/Trials/ClusterFormationTests.swift#L117) | 4/5 | 264 | S | `referenceTFCE` is the largest detected routine (~33 lines, L117). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Trials/ClusterPermutationAnalyzerTests.swift](../../EVATests/Trials/ClusterPermutationAnalyzerTests.swift#L58) | 4/5 | 150 | S | `findsAPlantedPositiveSpatiotemporalCluster` is the largest detected routine (~44 lines, L58). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Trials/ClusterPermutationFAnalyzerTests.swift](../../EVATests/Trials/ClusterPermutationFAnalyzerTests.swift#L30) | 4/5 | 118 | S | `findsAPlantedOmnibusSpatiotemporalEffect` is the largest detected routine (~50 lines, L30). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Trials/ClusterRepeatedMeasuresTests.swift](../../EVATests/Trials/ClusterRepeatedMeasuresTests.swift#L36) | 4/5 | 430 | S | `pairedDesignRecoversAnEffectTheIndependentDesignMisses` is the largest detected routine (~52 lines, L36). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Trials/ClusterSpatialAdjacencyTests.swift](../../EVATests/Trials/ClusterSpatialAdjacencyTests.swift#L92) | 4/5 | 161 | S | `summaryDetectsIsolatedSensorsAndComponents` is the largest detected routine (~25 lines, L92). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Trials/ClusterStatisticsDistributionsTests.swift](../../EVATests/Trials/ClusterStatisticsDistributionsTests.swift#L44) | 4/5 | 114 | S | `criticalTMatchesR` is the largest detected routine (~17 lines, L44). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Trials/RIDEAnalyzerTests.swift](../../EVATests/Trials/RIDEAnalyzerTests.swift#L57) | 4/5 | 225 | S | `decomposesStimulusAndCentralComponents` is the largest detected routine (~29 lines, L57). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Trials/WoodyAlignmentAnalyzerTests.swift](../../EVATests/Trials/WoodyAlignmentAnalyzerTests.swift#L133) | 4/5 | 191 | S | `returnsNilForInvalidInputs` is the largest detected routine (~30 lines, L133). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestswaveform"></a>
## EVATests/Waveform

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Waveform/EpochedOverlayEventMapperTests.swift](../../EVATests/Waveform/EpochedOverlayEventMapperTests.swift#L28) | 4/5 | 82 | S | `overlappingArtifactWhoseCenterPrecedesEpochGetsBoundaryFlag` is the largest detected routine (~20 lines, L28). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Waveform/HistoryRailRenderTests.swift](../../EVATests/Waveform/HistoryRailRenderTests.swift#L236) | 4/5 | 269 | S | `inkedRowCount` is the largest detected routine (~22 lines, L236). Reading demands: declarative UI/state. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Waveform/WaveformDensityLayoutTests.swift](../../EVATests/Waveform/WaveformDensityLayoutTests.swift#L74) | 4/5 | 127 | S | `densityPreservesPhysicalSensitivity` is the largest detected routine (~25 lines, L74). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Waveform/WaveformDensityScrollingTests.swift](../../EVATests/Waveform/WaveformDensityScrollingTests.swift#L16) | 4/5 | 144 | S | `densityChangesAtBottom` is the largest detected routine (~29 lines, L16). Reading demands: declarative UI/state. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Waveform/WaveformScaleUnitsTests.swift](../../EVATests/Waveform/WaveformScaleUnitsTests.swift#L300) | 4/5 | 321 | S | `clinicalPresetIsExact` is the largest detected routine (~21 lines, L300). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Waveform/WaveformScrollingPerformanceTests.swift](../../EVATests/Waveform/WaveformScrollingPerformanceTests.swift#L78) | 4/5 | 200 | S | `benchmark` is the largest detected routine (~29 lines, L78). Reading demands: declarative UI/state. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="evatestswavelet"></a>
## EVATests/Wavelet

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVATests/Wavelet/EmpiricalBayesThresholdTests.swift](../../EVATests/Wavelet/EmpiricalBayesThresholdTests.swift#L241) | 4/5 | 328 | S | `reducerRecoversTheEEGBetterThanBayesShrink` is the largest detected routine (~46 lines, L241). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Wavelet/WICACampaignTests.swift](../../EVATests/Wavelet/WICACampaignTests.swift#L373) | 3/5 | 1,134 | S | `runCell` is the largest detected routine (~284 lines, L373). Test names and assertions provide the main narrative. | Split setup, execution and checks in `runCell`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Wavelet/WICAPreservationMeasurementTests.swift](../../EVATests/Wavelet/WICAPreservationMeasurementTests.swift#L20) | 4/5 | 205 | S | `seededBrainTransientsAndBlinks` is the largest detected routine (~120 lines, L20). Test names and assertions provide the main narrative. | Split setup, execution and checks in `seededBrainTransientsAndBlinks`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Wavelet/WICAProcessorTests.swift](../../EVATests/Wavelet/WICAProcessorTests.swift#L130) | 4/5 | 225 | S | `selectiveWICAPreservesASharpBrainSourceWhileRemovingMixedArtifact` is the largest detected routine (~83 lines, L130). Test names and assertions provide the main narrative. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Wavelet/WaveletArtifactAnalyzerTests.swift](../../EVATests/Wavelet/WaveletArtifactAnalyzerTests.swift#L68) | 4/5 | 97 | S | `driftingBaselineDoesNotFlagRecordingBoundaries` is the largest detected routine (~29 lines, L68). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Wavelet/WaveletArtifactClassificationTests.swift](../../EVATests/Wavelet/WaveletArtifactClassificationTests.swift#L192) | 4/5 | 301 | S | `fastPassFindsBurstAboveDownsampledNyquist` is the largest detected routine (~55 lines, L192). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Wavelet/WaveletMetalBackendTests.swift](../../EVATests/Wavelet/WaveletMetalBackendTests.swift#L99) | 4/5 | 379 | S | `gpuScanFindsTheSameCandidatesAsCPU` is the largest detected routine (~76 lines, L99). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Wavelet/WaveletOversmoothingMeasurementTests.swift](../../EVATests/Wavelet/WaveletOversmoothingMeasurementTests.swift#L36) | 4/5 | 145 | S | `waveletPreservationVersusArtifactRemoval` is the largest detected routine (~109 lines, L36). Test names and assertions provide the main narrative. | Split setup, execution and checks in `waveletPreservationVersusArtifactRemoval`; explain fixture assumptions and why the expected result/tolerance is correct. | — |
| [EVATests/Wavelet/WaveletReductionViewModelTests.swift](../../EVATests/Wavelet/WaveletReductionViewModelTests.swift#L27) | 4/5 | 93 | S | `parametersRoundTripFullConfiguration` is the largest detected routine (~25 lines, L27). Reading demands: asynchronous control flow. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVATests/Wavelet/WaveletScalogramTests.swift](../../EVATests/Wavelet/WaveletScalogramTests.swift#L21) | 4/5 | 59 | S | `peakPowerLandsNearInjectedFrequency` is the largest detected routine (~26 lines, L21). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |

<a id="evathumbnail"></a>
## EVAThumbnail

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAThumbnail/ThumbnailProvider.swift](../../EVAThumbnail/ThumbnailProvider.swift#L24) | 4/5 | 105 | S | `provideThumbnail` is the largest detected routine (~81 lines, L24). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `provideThumbnail`; preserve straightforward code. | — |

<a id="evauitests"></a>
## EVAUITests

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [EVAUITests/EVAUITests.swift](../../EVAUITests/EVAUITests.swift#L31) | 4/5 | 48 | S | `testExample` is the largest detected routine (~9 lines, L31). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVAUITests/EVAUITestsLaunchTests.swift](../../EVAUITests/EVAUITestsLaunchTests.swift#L26) | 4/5 | 40 | S | `testLaunch` is the largest detected routine (~14 lines, L26). Test names and assertions provide the main narrative. | Keep behavioral test names and small examples; annotate only non-obvious fixtures or expectations. | — |
| [EVAUITests/EVAWorkflowUITests.swift](../../EVAUITests/EVAWorkflowUITests.swift#L89) | 4/5 | 395 | S | `testNEFMotionBCGAndPSA` is the largest detected routine (~95 lines, L89). Existing explanatory comments provide context. | Explain fixture assumptions and why the expected result/tolerance is correct. | — |

<a id="toolsevabids"></a>
## Tools/EVABIDS

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/EVABIDS/Sources/EVABIDS/BIDSCommon.swift](../../Tools/EVABIDS/Sources/EVABIDS/BIDSCommon.swift#L44) | 4/5 | 170 | S | `parse` is the largest detected routine (~18 lines, L44). Relatively localized scope. | Add the input/output contract and edge cases for `parse`; preserve straightforward code. | — |
| [Tools/EVABIDS/Sources/EVABIDS/EDFCodec.swift](../../Tools/EVABIDS/Sources/EVABIDS/EDFCodec.swift#L51) | 4/5 | 302 | S | `write` is the largest detected routine (~88 lines, L51). Reading demands: unsafe-memory APIs. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [Tools/EVABIDS/Sources/EVABIDS/FromBIDS.swift](../../Tools/EVABIDS/Sources/EVABIDS/FromBIDS.swift#L28) | 4/5 | 358 | S | `run` is the largest detected routine (~136 lines, L28). Relatively localized scope. | Add the input/output contract and edge cases for `run`; preserve straightforward code. | — |
| [Tools/EVABIDS/Sources/EVABIDS/InspectBIDS.swift](../../Tools/EVABIDS/Sources/EVABIDS/InspectBIDS.swift#L95) | 4/5 | 229 | S | `inspect` is the largest detected routine (~121 lines, L95). Relatively localized scope. | Add the input/output contract and edge cases for `inspect`; preserve straightforward code. | — |
| [Tools/EVABIDS/Sources/EVABIDS/ToBIDS.swift](../../Tools/EVABIDS/Sources/EVABIDS/ToBIDS.swift#L31) | 4/5 | 287 | S | `run` is the largest detected routine (~130 lines, L31). Relatively localized scope. | Add the input/output contract and edge cases for `run`; preserve straightforward code. | — |
| [Tools/EVABIDS/Sources/EVABIDS/main.swift](../../Tools/EVABIDS/Sources/EVABIDS/main.swift#L85) | 4/5 | 237 | S | `parseToBIDS` is the largest detected routine (~48 lines, L85). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `parseToBIDS`; preserve straightforward code. | — |
| [Tools/EVABIDS/build.sh](../../Tools/EVABIDS/build.sh#L1) | 4/5 | 30 | S | 30 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |

<a id="toolsevagradient"></a>
## Tools/EVAGradient

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/EVAGradient/EngineAddons.swift](../../Tools/EVAGradient/EngineAddons.swift#L35) | 4/5 | 140 | S | `runEngineAddon` is the largest detected routine (~51 lines, L35). Relatively localized scope. | Add the input/output contract and edge cases for `runEngineAddon`; preserve straightforward code. | — |
| [Tools/EVAGradient/ExperimentMethods.swift](../../Tools/EVAGradient/ExperimentMethods.swift#L161) | 4/5 | 232 | S | `runMethod` is the largest detected routine (~72 lines, L161). Relatively localized scope. | Add the input/output contract and edge cases for `runMethod`; preserve straightforward code. | — |
| [Tools/EVAGradient/JitterExperiment.swift](../../Tools/EVAGradient/JitterExperiment.swift#L71) | 4/5 | 138 | S | `runJitterExperiment` is the largest detected routine (~68 lines, L71). Relatively localized scope. | Add the input/output contract and edge cases for `runJitterExperiment`; preserve straightforward code. | — |
| [Tools/EVAGradient/MethodSelfTests.swift](../../Tools/EVAGradient/MethodSelfTests.swift#L3) | 4/5 | 129 | S | `methodSelfTests` is the largest detected routine (~127 lines, L3). Relatively localized scope. | Add the input/output contract and edge cases for `methodSelfTests`; preserve straightforward code. | — |
| [Tools/EVAGradient/build.sh](../../Tools/EVAGradient/build.sh#L1) | 4/5 | 49 | S | 49 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |
| [Tools/EVAGradient/main.swift](../../Tools/EVAGradient/main.swift#L215) | 3/5 | 402 | S | `run` is the largest detected routine (~110 lines, L215). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `run`; preserve straightforward code. | — |
| [Tools/EVAGradient/run_addon_campaign.py](../../Tools/EVAGradient/run_addon_campaign.py#L97) | 4/5 | 162 | S | `plot_campaign` is the largest detected routine (~64 lines, L97). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/EVAGradient/run_controlled_p3.py](../../Tools/EVAGradient/run_controlled_p3.py#L49) | 4/5 | 109 | S | `waveformfigure` is the largest detected routine (~14 lines, L49). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolsevahelper"></a>
## Tools/EVAHelper

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/EVAHelper/Sources/EVAHelper/BrainVisionHelperReader.swift](../../Tools/EVAHelper/Sources/EVAHelper/BrainVisionHelperReader.swift#L47) | 3/5 | 424 | S | `load` is the largest detected routine (~103 lines, L47). Little explanatory commenting was detected. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift](../../Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift#L703) | 1/5 | 1,251 | C | 1,251 lines combine preparation, regression backends, Metal dispatch and embedded shader code with almost no explanatory comments. | Document the regression model and buffer shapes; separate preparation, CPU solve, GPU dispatch and shader source. | **Expanded comments complete** |
| [Tools/EVAHelper/Sources/EVAHelper/OriginalCWLCorrectorEngine.swift](../../Tools/EVAHelper/Sources/EVAHelper/OriginalCWLCorrectorEngine.swift#L25) | 3/5 | 424 | S | `correct` is the largest detected routine (~155 lines, L25). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `correct`; preserve straightforward code. | — |
| [Tools/EVAHelper/Sources/EVAHelper/main.swift](../../Tools/EVAHelper/Sources/EVAHelper/main.swift#L437) | 2/5 | 1,039 | S | `run` is the largest detected routine (~317 lines, L437). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `run`; preserve straightforward code. | **Expanded comments complete** |
| [Tools/EVAHelper/build.sh](../../Tools/EVAHelper/build.sh#L1) | 4/5 | 48 | S | 48 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |

<a id="toolsevasimulate"></a>
## Tools/EVASimulate

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/EVASimulate/Sources/EVASimulate/ERPEvaluation.swift](../../Tools/EVASimulate/Sources/EVASimulate/ERPEvaluation.swift#L94) | 4/5 | 311 | S | `evaluate` is the largest detected routine (~159 lines, L94). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `evaluate`; preserve straightforward code. | — |
| [Tools/EVASimulate/Sources/EVASimulate/RichMetrics.swift](../../Tools/EVASimulate/Sources/EVASimulate/RichMetrics.swift#L107) | 4/5 | 268 | S | `optimalTimingErrors` is the largest detected routine (~53 lines, L107). Relatively localized scope. | Add the input/output contract and edge cases for `optimalTimingErrors`; preserve straightforward code. | — |
| [Tools/EVASimulate/Sources/EVASimulate/SI0ContractFixtures.swift](../../Tools/EVASimulate/Sources/EVASimulate/SI0ContractFixtures.swift#L22) | 4/5 | 299 | S | `run` is the largest detected routine (~277 lines, L22). Relatively localized scope. | Add the input/output contract and edge cases for `run`; preserve straightforward code. | — |
| [Tools/EVASimulate/Sources/EVASimulate/SNRMetrics.swift](../../Tools/EVASimulate/Sources/EVASimulate/SNRMetrics.swift#L87) | 4/5 | 431 | S | `score` is the largest detected routine (~79 lines, L87). Reading demands: numeric/GPU primitives. | Document dimensions, memory layout, lifetimes and numeric assumptions at the low-level call boundary. | — |
| [Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift](../../Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift#L84) | 1/5 | 3,597 | C | Scientific checks have useful rationale, but run spans roughly 3,513 lines including nested setup helpers and many scenarios. | Extract named scenario groups and fixture builders while preserving random seeds and execution order. | **Expanded comments complete** |
| [Tools/EVASimulate/Sources/EVASimulate/SimulationWriter.swift](../../Tools/EVASimulate/Sources/EVASimulate/SimulationWriter.swift#L216) | 4/5 | 425 | S | `events` is the largest detected routine (~144 lines, L216). Existing explanatory comments provide context. | Explain format fields, units and error/fallback behavior; give one decode/encode example. | — |
| [Tools/EVASimulate/Sources/EVASimulate/SourceMetrics.swift](../../Tools/EVASimulate/Sources/EVASimulate/SourceMetrics.swift#L165) | 4/5 | 233 | S | `hungarianRows` is the largest detected routine (~54 lines, L165). Relatively localized scope. | Add the input/output contract and edge cases for `hungarianRows`; preserve straightforward code. | — |
| [Tools/EVASimulate/Sources/EVASimulate/SurrogateSeparation.swift](../../Tools/EVASimulate/Sources/EVASimulate/SurrogateSeparation.swift#L289) | 4/5 | 572 | S | `artifactComponents` is the largest detected routine (~162 lines, L289). Existing explanatory comments provide context. | Add the input/output contract and edge cases for `artifactComponents`; preserve straightforward code. | — |
| [Tools/EVASimulate/Sources/EVASimulate/main.swift](../../Tools/EVASimulate/Sources/EVASimulate/main.swift#L832) | 1/5 | 4,612 | C | 4,612 lines contain parsing, config assembly, many commands and scoring; makeConfig alone spans roughly 823 lines. | Split argument/config handling and individual commands; document scenario → demo → explicit-flag precedence. | **Expanded comments complete** |

<a id="toolsrhythmicityreference"></a>
## Tools/RhythmicityReference

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/RhythmicityReference/generate_burst_oracle.py](../../Tools/RhythmicityReference/generate_burst_oracle.py#L86) | 4/5 | 168 | S | `detect` is the largest detected routine (~56 lines, L86). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/RhythmicityReference/generate_input.py](../../Tools/RhythmicityReference/generate_input.py#L17) | 4/5 | 103 | S | `build_input` is the largest detected routine (~72 lines, L17). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/RhythmicityReference/generate_wtpl_oracle.py](../../Tools/RhythmicityReference/generate_wtpl_oracle.py#L115) | 3/5 | 181 | C | The module docstring describes the independent oracle and helpers follow algorithm stages; equations, indices and constants still need domain context. | Document array shape, sample-index conventions and the meaning of the small synthetic fixture. | — |
| [Tools/RhythmicityReference/inspect_mff.py](../../Tools/RhythmicityReference/inspect_mff.py#L28) | 4/5 | 106 | S | `inspect_signal` is the largest detected routine (~48 lines, L28). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/RhythmicityReference/run_python_reference.py](../../Tools/RhythmicityReference/run_python_reference.py#L116) | 4/5 | 238 | S | `main` is the largest detected routine (~119 lines, L116). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolsbdf-import"></a>
## Tools/bdf-import

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/bdf-import/make_bdf_fixtures.py](../../Tools/bdf-import/make_bdf_fixtures.py#L24) | 4/5 | 96 | S | `make_sample` is the largest detected routine (~34 lines, L24). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolscompare-paired-runsh"></a>
## Tools/compare-paired-run.sh

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/compare-paired-run.sh](../../Tools/compare-paired-run.sh#L1) | 4/5 | 173 | S | 173 lines of shell orchestration. Existing explanatory comments provide context. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |

<a id="toolsconvert_iclabel_to_coremlpy"></a>
## Tools/convert_iclabel_to_coreml.py

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/convert_iclabel_to_coreml.py](../../Tools/convert_iclabel_to_coreml.py#L115) | 3/5 | 254 | C | Usage and input provenance are documented, with a helpful tensor-axis conversion comment; several frameworks and weight layouts raise the entry barrier. | Add a tensor-shape map and a conversion-stage outline with expected output validation. | — |

<a id="toolseeglab-compare"></a>
## Tools/eeglab-compare

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/eeglab-compare/compare_eeglab.py](../../Tools/eeglab-compare/compare_eeglab.py#L98) | 4/5 | 162 | S | `compare_filter_and_interp` is the largest detected routine (~59 lines, L98). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/eeglab-compare/export_eeglab_set.py](../../Tools/eeglab-compare/export_eeglab_set.py#L30) | 4/5 | 46 | S | `main` is the largest detected routine (~13 lines, L30). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/eeglab-compare/run_eeglab_pipeline.m](../../Tools/eeglab-compare/run_eeglab_pipeline.m#L1) | 4/5 | 124 | S | 124 lines of declarations or top-level code. Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolsfif-import"></a>
## Tools/fif-import

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/fif-import/make_fif_fixtures.py](../../Tools/fif-import/make_fif_fixtures.py#L87) | 4/5 | 192 | S | `main` is the largest detected routine (~102 lines, L87). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolsforward-compare"></a>
## Tools/forward-compare

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/forward-compare/check_swift_openmeeg.py](../../Tools/forward-compare/check_swift_openmeeg.py#L20) | 4/5 | 47 | S | `main` is the largest detected routine (~24 lines, L20). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/forward-compare/make_forward_fixtures.py](../../Tools/forward-compare/make_forward_fixtures.py#L176) | 4/5 | 386 | S | `run_case` is the largest detected routine (~110 lines, L176). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolsgenerate_ebayes_referencer"></a>
## Tools/generate_ebayes_reference.R

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/generate_ebayes_reference.R](../../Tools/generate_ebayes_reference.R#L1) | 4/5 | 104 | S | 104 lines of declarations or top-level code. Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolsmfftimingtool"></a>
## Tools/mffTimingTool

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/mffTimingTool/Sources/mffTimingTool/main.swift](../../Tools/mffTimingTool/Sources/mffTimingTool/main.swift#L225) | 4/5 | 537 | S | `parseOptions` is the largest detected routine (~50 lines, L225). Little explanatory commenting was detected. | Add the input/output contract and edge cases for `parseOptions`; preserve straightforward code. | — |
| [Tools/mffTimingTool/build.sh](../../Tools/mffTimingTool/build.sh#L1) | 4/5 | 16 | S | 16 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |

<a id="toolsmne-compare"></a>
## Tools/mne-compare

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/mne-compare/make_filter_edges_reference.py](../../Tools/mne-compare/make_filter_edges_reference.py#L33) | 4/5 | 107 | S | `main` is the largest detected routine (~71 lines, L33). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/mne-compare/make_full_pipeline_reference.py](../../Tools/mne-compare/make_full_pipeline_reference.py#L83) | 4/5 | 171 | S | `main` is the largest detected routine (~85 lines, L83). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/mne-compare/make_real_reference.py](../../Tools/mne-compare/make_real_reference.py#L49) | 4/5 | 147 | S | `main` is the largest detected routine (~95 lines, L49). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/mne-compare/make_reference.py](../../Tools/mne-compare/make_reference.py#L100) | 4/5 | 260 | S | `main` is the largest detected routine (~157 lines, L100). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolsresolve-validate"></a>
## Tools/resolve-validate

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/resolve-validate/check_swift_fif.py](../../Tools/resolve-validate/check_swift_fif.py#L1) | 4/5 | 23 | S | 23 lines of declarations or top-level code. Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/resolve-validate/check_swift_nifti.py](../../Tools/resolve-validate/check_swift_nifti.py#L1) | 4/5 | 20 | S | 20 lines of declarations or top-level code. Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/resolve-validate/export_montages.py](../../Tools/resolve-validate/export_montages.py#L11) | 4/5 | 46 | S | `load` is the largest detected routine (~8 lines, L11). Relatively localized scope. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
| [Tools/resolve-validate/make_fixtures.py](../../Tools/resolve-validate/make_fixtures.py#L1) | 4/5 | 172 | S | 172 lines of declarations or top-level code. Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |

<a id="toolsspatial-benchmark"></a>
## Tools/spatial-benchmark

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [Tools/spatial-benchmark/Benchmark.swift](../../Tools/spatial-benchmark/Benchmark.swift#L54) | 4/5 | 89 | S | `main` is the largest detected routine (~35 lines, L54). Reading demands: asynchronous control flow. | Explain task ownership, cancellation, stale results and where state is published. | — |
| [Tools/spatial-benchmark/Support.swift](../../Tools/spatial-benchmark/Support.swift#L1) | 4/5 | 11 | S | Declarations include `SensorPosition`, `SensorLayout`, `ArtifactReviewTopography`. Relatively localized scope. | Add a concise purpose/consumer note and document units, optional values and persistent keys. | — |
| [Tools/spatial-benchmark/run.sh](../../Tools/spatial-benchmark/run.sh#L1) | 4/5 | 12 | S | 12 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |

<a id="docs"></a>
## docs

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [docs/figures/REWIND_FIG_1.html](../../docs/figures/REWIND_FIG_1.html#L1) | 3/5 | 117 | C | Readable visual sections are mixed with compressed CSS declarations, short custom-property names and inline SVG paths. | Add visual-section comments and expand non-obvious color names; treat fixed illustration paths as data. | — |
| [docs/figures/REWIND_FIG_2.html](../../docs/figures/REWIND_FIG_2.html#L1) | 4/5 | 129 | S | 129 lines of markup/style. Little explanatory commenting was detected. | Label visual sections and clarify compact CSS names; leave illustration coordinates as data. | — |

<a id="run-all-testssh"></a>
## run-all-tests.sh

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [run-all-tests.sh](../../run-all-tests.sh#L1) | 4/5 | 262 | C | Usage, stage logging and failure behavior are explained clearly; shell arrays, expansion and orchestration are the main remaining barrier. | Add a compact stage map and explain --fast precisely as skipping the Xcode unit suite, not as a quick unit-test run. | — |

<a id="scripts"></a>
## scripts

| File | Score | Lines | Review | Evidence | First improvement | Comment status |
| --- | --- | --- | --- | --- | --- | --- |
| [scripts/calibrate.sh](../../scripts/calibrate.sh#L1) | 4/5 | 82 | S | 82 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |
| [scripts/check-determinism.sh](../../scripts/check-determinism.sh#L1) | 4/5 | 142 | S | 142 lines of shell orchestration. Existing explanatory comments provide context. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |
| [scripts/compare-methods.sh](../../scripts/compare-methods.sh#L1) | 4/5 | 72 | S | 72 lines of shell orchestration. Existing explanatory comments provide context. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |
| [scripts/compare-wica-ica-algorithms.sh](../../scripts/compare-wica-ica-algorithms.sh#L1) | 4/5 | 67 | S | 67 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |
| [scripts/evaluate-wica-campaign.sh](../../scripts/evaluate-wica-campaign.sh#L1) | 4/5 | 76 | S | 76 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |
| [scripts/evaluate-wica-mixed-campaign.sh](../../scripts/evaluate-wica-mixed-campaign.sh#L1) | 4/5 | 66 | S | 66 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |
| [scripts/release.sh](../../scripts/release.sh#L1) | 4/5 | 97 | S | 97 lines of shell orchestration. Relatively localized scope. | Document inputs, required environment, outputs and failure behavior; label non-obvious shell expansion. | — |
| [scripts/sync-planning-docs.py](../../scripts/sync-planning-docs.py#L116) | 4/5 | 154 | S | `main` is the largest detected routine (~35 lines, L116). Existing explanatory comments provide context. | Document invocation, dependencies, array shapes and reference-fixture provenance; label computation stages. | — |
