# EVA readability assessment and improvement plan

> Historical baseline assessment. See the [comment pass and deferred structural changes](readability-comment-pass-2026-11-06.md) for subsequent work. Source line numbers below refer to the baseline snapshot.

November 6, 2026 · Source snapshot `af2de90420d8`

EVA has many approachable helpers and useful explanations of design decisions, but its main workflows are difficult entry points for a programmer with undergraduate CS coursework who is new to Swift. The largest gains will come from explaining data contracts and state ownership, then dividing the broadest files into coherent pieces. Adding more comments indiscriminately would obscure the simple code and would not resolve the difficult dependencies.

The [complete file scorecard](readability-file-ratings-2026-11-06.md) rates **all 774 tracked source files** and gives each an improvement recommendation. It includes production Swift, tests, Metal kernels, command-line tools, scripts and two HTML figures: **280,580 lines** in total.

This is a static assessment, not a full line-by-line semantic review. All files received a structural scan and their individual summaries were examined; selected source sections in **40 files** received closer reading and individual rating adjustments. The other **734 ratings are provisional scan-based estimates**, identified explicitly in the scorecard. No application source was changed, and builds/tests were not run for this documentation-only review.

## Rating scale and findings

The reader is assumed to understand variables, loops, functions, basic data structures, classes, testing and introductory algorithms. SwiftUI, actor isolation, Accelerate/LAPACK, GPU programming, EEG and specialized numerical methods are not assumed knowledge.

| Rating | Interpretation | Files |
| --- | --- | ---: |
| 5/5 | Immediately approachable; a useful teaching example | 2 |
| 4/5 | Mostly approachable, with a few targeted explanations or lookups | 587 |
| 3/5 | Needs a guide to its framework, data flow or domain | 135 |
| 2/5 | Difficult to follow independently | 33 |
| 1/5 | Poor onboarding entry point; requires substantial context and decomposition | 17 |

The scan-based scores are capped at 4; a 5 requires closer confirmation. These are readability judgments for this audience, not correctness or scientific-quality grades. The many small tests and helpers make the distribution look healthier than the experience of opening the central application files.

| Area | Files | Rated 1–2 | Rated 3 | Rated 4–5 |
| --- | ---: | ---: | ---: | ---: |
| Main app, `EVA` | 330 | 42 | 80 | 208 |
| Shared library, `EVACore` | 76 | 3 | 16 | 57 |
| Preview library and Finder entry points | 36 | 1 | 7 | 28 |
| Resolve app | 18 | 0 | 1 | 17 |
| All three test directories | 246 | 0 | 25 | 221 |
| Command-line tools | 57 | 4 | 5 | 48 |
| Repository scripts and HTML figures | 11 | 0 | 1 | 10 |

Five recurring obstacles matter most:

1. **A file boundary often is not a responsibility boundary.** Several UI files are `WaveformView` extensions that still depend on a large shared context. `SingleTrialAnalysisViews.swift` explicitly calls its initial split “a file split, not a state extraction.” Moving additional methods to another extension would not by itself make those dependencies easier to understand.
2. **Central data contracts are less explicit than their importance warrants.** In `MFFReader.swift`, `MFFSignalData.dataRevision` has a useful explanation, but `data: [[Float]]` lacks an adjacent description of its axes and permitted shapes. A newcomer needs the meaning of each index, the unit conventions, and the relationship to channel metadata before following a filter or renderer. Do not assume all PNS channels carry EEG voltage units.
3. **Specialist terms and representations accumulate.** ICA solvers, wavelet reduction, LAVI/ABBA, RIDE, file formats and flat GPU buffers require both programming and scientific context. A citation establishes provenance but does not substitute for a local explanation of inputs, stages and outputs.
4. **Some explanations describe development history before current behavior.** This can be valuable, especially for subtle regressions, but long incident narratives slow initial reading. Also, **57 source files reference `REWIND.md` or `REFACTOR.md`; neither file exists in this checkout.** Replace those pointers with maintained documentation and explain terms such as L3/L4/L5 locally or remove them from introductory comments.
5. **Small tests are often the best teaching material.** `SignalSelectionTests.swift` shows concrete arrays and the expected retained hits. More complex parity tests need a short explanation of fixture provenance and numerical tolerances so readers understand why an assertion is meaningful.

## Highest-value files to address

These ratings were adjusted after closer reading of selected source sections. Sizes are physical line counts; routine sizes are approximate lexical measurements. The scorecard contains the rest of the project.

| File | Score | Evidence and recommended direction |
| --- | ---: | --- |
| `EVA/Waveform/WaveformView.swift` | 1 | 3,908 lines; method definitions, UI and orchestration coexist. Move domain types first, then extract independent child views with explicit inputs/actions. |
| `EVA/Epoching/SingleTrialAnalysisViews.swift` | 1 | 4,867 lines; separate the waveform bridge, analysis actions, result panels and export responsibilities. |
| `EVA/Epoching/PSADecisionMatrix.swift` | 1 | 2,793 lines; separate review decisions, layout calculations, drawing and interaction. Explain channel/epoch versus pixel coordinates. |
| `EVA/Artifacts/ArtifactReviewWorkspace.swift` | 1 | 1,942 lines; make cache and review-state ownership explicit before extracting panels. |
| `EVA/Artifacts/ArtifactCleaner.swift` | 1 | 3,164 lines; split models, dispatch and individual cleaning implementations while retaining a simple entry point. |
| `EVA/ICA/ICAArtifactDetector.swift` | 1 | 1,946 lines; multiple solvers and reconstruction. Give matrix shapes and separate solvers behind the current API. |
| `EVA/Rhythmicity/RhythmicityExplorerViewModel.swift` | 1 | 1,666 lines; three analysis modes, signatures and stale-state logic need a lifecycle map and smaller owners. |
| `EVA/Wavelet/WaveletArtifactAnalyzer.swift` | 1 | 2,825 lines; separate configuration/results, preparation, matching, feature extraction and scan orchestration. |
| `Tools/EVASimulate/Sources/EVASimulate/main.swift` | 1 | 4,612 lines; `makeConfig` is about 823 lines. Separate command handlers and configuration assembly. |
| `Tools/EVASimulate/Sources/EVASimulate/SelfTest.swift` | 1 | `run` is about 3,513 lines. Extract named scenario groups, preserving random draw and execution order. |
| `Tools/EVAHelper/Sources/EVAHelper/CWLCorrectorEngine.swift` | 1 | 1,251 lines with very little explanation; separate regression preparation, CPU/GPU dispatch and embedded shader code. |
| `EVA/Pipeline/ProcessingCore.swift` | 2 | Good ordering/payload rationale, but `applyAutoSteps` is about 440 lines. Keep one sequencer with named operation handlers. |
| `EVACore/IO/MFFReader.swift` | 2 | Central models and package/binary/XML parsing share 2,169 lines. Document the models before separating readers. |
| `EVA/Rhythmicity/LAVIEngine.swift` | 2 | `analyzeOnce` is about 308 lines. Explain and separate backend resolution, channel processing and result assembly. |
| `EVA/Trials/RIDEAnalyzer.swift` | 2 | `decompose` is about 415 lines. Separate initialization, iterative estimation and reconstruction. |
| `EVA/Filtering/EEGSignalFilter.swift` | 2 | A long `bandPass` signature and several filter families require configuration and phase/padding explanations. |

There are already good patterns to preserve. `ChannelSet.swift` **(5)** explains indices and optional values in small value types. `SignalSelectionTests.swift` **(5)** provides simple executable examples. `LatestOnlyRunner.swift` **(4)** explains why stale work must not publish. `EmpiricalBayesThreshold.swift` **(3)** has strong equation-to-code documentation, but needs a plain-language introduction for this audience. Its lower score reflects the prerequisite mathematics, not a lack of care.

## Proposed sequence of changes

### 1. Establish the beginner reading path

Extend the existing [developer introduction](README.md) and [architecture map](architecture.md) rather than starting a competing documentation tree.

- Add a short Swift-in-EVA guide covering optionals/`guard`, structs versus classes, protocols and conformances, closures and captures, key paths, `some` versus `any`, `@State`/`@Binding`/`@Observable`/environment values, and `@MainActor`/`nonisolated`/`Sendable`/cancellation. Use examples already in this repository.
- Add a concise domain glossary: channel, sample, epoch/trial, ERP, artifact, reference, montage, lead field, ICA, PCA, BCG, CWT, LAVI/ABBA and PSA. Verify the project's intended expansion of PSA: source and architecture prose currently use different wording.
- Show one traced workflow: open a recording → select valid channels → apply a filter → publish the result → invalidate derived data → record the processing step. Identify each responsible type and its lifetime.
- Replace missing document pointers. Keep licensing, required attribution and algorithm provenance intact. Preserve the relevant invariant beside the code when moving historical incident details elsewhere.

**Done when:** a newcomer can identify the app's entry point, the central signal representation, the owner of per-recording state and the route from one user action to its recorded result.

### 2. Pilot the comment standard on shared contracts

Start with a small, reviewable batch: `SignalSelection.swift`, `SignalStatistics.swift`, `HealthScoring.swift`, the `MFFSignalData` declaration, and `LatestOnlyRunner.swift`. These expose recurring conventions without requiring an immediate rewrite of a large numerical method.

For nontrivial APIs, document purpose, inputs/outputs, axes and units, invalid-input behavior, mutation/side effects and any actor requirement. For configuration fields, document valid ranges and the meaning of defaults or `nil`. Explain behavior that differs between two similar-looking functions.

For example, this would be a useful proposed comment above the `Double` percentile overload in `SignalStatistics.swift`, matching its current implementation:

```swift
/// Returns a linearly interpolated percentile of values sorted in ascending order.
/// `fraction` is clamped to 0...1; empty input returns 0.
/// For [10, 20], a fraction of 0.25 returns 12.5.
```

`mergeNearbyStarts` needs a slightly different kind of explanation: merging compares against the currently retained representative, and replacing that representative changes the next comparison. A three-hit example will communicate that rule better than comments on each assignment.

**Done when:** the reader can predict one ordinary result and one boundary case from the contract. No new tests are necessary for comments alone; add a behavioral example test only where a genuinely uncovered contract needs confirmation.

### 3. Explain scientific and low-level boundaries

Apply the agreed standard to filtering, linear algebra, MFF/NIfTI/DICOM readers, ICA, rhythmicity, wavelets, forward models and the five Metal files.

- Put a short plain-language algorithm outline before the implementation: what is measured or transformed, why, and the major stages.
- Write array dimensions explicitly, such as `samples[channel][sample]`; verify each actual representation. For flattened buffers, show the stride formula and row-major/column-major conversion. Show a small matrix example where useful.
- Explain samples versus seconds/milliseconds, index bases, interval endpoints, coordinate frames, scaling, missing/nonfinite values and boundary padding where they cross APIs.
- Map important equation symbols to variable names. Keep conventional short mathematical names in tight equations where that improves correspondence; prefer descriptive names for outer workflow variables.
- Explain tolerances and thresholds: their numerical purpose, calibrated origin or compatibility requirement. Naming a constant is helpful, but does not explain why its value is appropriate.
- At concurrency/GPU boundaries, describe who owns buffers, when work completes, where cancellation is checked, which task may publish and what the CPU fallback means.

**Done when:** a reader can trace a tiny input through the stages and distinguish domain assumptions from implementation mechanics. An inherently advanced solver can reasonably target **3–4/5**, rather than pretending to be introductory material.

### 4. Decompose the largest workflows in separate changes

After the contracts are documented, address the highest-value files above in small batches. A useful order is simulator command/configuration boundaries, central model declarations, UI panels/state ownership, then numerical orchestration.

For UI, extract standalone `View` types with value inputs, bindings only where edits are needed, and named action closures. Keep calculation and commit/replay effects in the appropriate model or coordinator. Explain transient view state versus persisted settings, derived caches and processing results.

For engines, keep the existing top-level API and extract meaningful stages. Keep performance-sensitive inner loops together when splitting them would obscure the calculation or add overhead. Preserve floating-point reduction order, seeds, rounding, serialized keys, event timing and CPU/GPU parity during readability-only changes.

Use size as a prompt for review, not a mandatory limit: files beyond roughly 500–800 lines and routines beyond 60–100 lines deserve a responsibility check. Configuration tables, generated data and clear dispatch switches can be legitimate exceptions. Do not create a large collection of trivial helpers merely to satisfy a line target.

**Done when:** a newcomer can name each piece's responsibility and trace its inputs/outputs without reconstructing a giant shared object. Relevant behavior and performance remain unchanged.

### 5. Make tests and tools part of onboarding

Treat small, behaviorally named tests as worked examples. In larger numerical tests, explain the planted signal, expected invariant, reference source/version, seed and tolerance. Avoid comments that merely repeat `#expect` or enforce boilerplate setup/action/assert headings on obvious tests.

Split the simulator self-test by scientific scenario and the largest measurement campaigns by setup/run/report responsibilities. Keep shared fixtures small enough that a reader can still see what makes each case distinct.

Give scripts a compact invocation, dependency/environment list, input/output description and failure semantics. Clarify that `run-all-tests.sh --fast` skips the Xcode unit suite. For `StandardMontageData.swift`, improve the generator/regeneration documentation rather than annotating hundreds of generated coordinates individually.

**Done when:** a newcomer can run a relevant example, explain the expected outcome and find the production function it exercises.

## Validation and completion criteria

Keep comment/documentation changes separate from moves and behavioral refactors so each change is easy to assess. For the first batch, validate comment claims against the implementation and existing tests; a broad application run adds little for comments alone.

When declarations or implementation move, build affected targets, including relevant CLI/preview targets that reuse the source. Run the existing tests for the changed subsystem. For numerical or pipeline refactors, include the applicable reference/parity, determinism, replay and round-trip tests. For UI decomposition, exercise opening/closing windows, menu focus, bindings, cancellation and the affected scrolling or interaction path. Use the full repository test runner at a substantial integration checkpoint; its `--fast` option is not a replacement for unit tests.

Assess readability with five concrete questions, ideally using a short walkthrough with someone near the target experience level:

1. What does this file do, and who calls it?
2. What does each input index/unit mean, and what comes out?
3. Where does its state live, and who may change it?
4. What happens on empty input, failure, cancellation or stale results?
5. Which existing test demonstrates its essential behavior?

Prioritize files rated 1–2 that sit on common workflows, then foundational contracts that many other files rely on. Leave already-clear small helpers largely alone. Re-rate a changed file after its new source has been read; do not treat more comments or fewer lines as proof that it became easier to understand.
