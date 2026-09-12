# Trial-level analysis and the `.eva` package — design reference

> **Unbuilt, and the name moved.** This is the original (early 2026) conception
> of "EVA Resolve": a companion app for trial-level ERP analysis with RIDE as
> its flagship method, fed by a native `.eva` interchange package.
>
> **The app that shipped under that name does source analysis instead** — head
> models, coregistration, dipole fitting, inverse imaging (`ROADMAP.md` § Source
> & Forward Modeling). The handoff it uses is an averaged `.mff` plus a JSON
> sidecar, not `.eva`.
>
> **Parts of it landed in EVA itself instead of a second app:**
> `EVA/Trials/RIDEAnalyzer.swift` and `EVA/Trials/WoodyAlignmentAnalyzer.swift`
> ship RIDE decomposition and Woody latency alignment inside EVA's Trials
> subsystem, with tests. So the "native Swift RIDE plan" below is partly
> delivered — what was never built is the separate app, the `.eva` package, and
> the batch/behavioural-regression layer around it.
>
> Nothing further here is scheduled. It is kept because the RIDE port plan, the
> validation ladder, and the `.eva` package shape are still the design anyone
> would start from — under a different product name. Tracked as **TL-1** in
> `ROADMAP.md` § Epoching, Averaging & Trial-wise.

---

# EVA Resolve Planning Notes

## Working Name

**EVA Resolve** is a proposed companion macOS app for trial-level ERP analysis. RIDE would be one flagship method inside it, but the app should be broader than the RIDE algorithm: a home for latency variability, component decomposition, single-trial metrics, behavior-linked modeling, and export-ready trial datasets.

## Product Shape

EVA Resolve should begin as a second app target in the EVA Xcode project rather than a separate repository.

That keeps the codebase close enough to share core models and tests while allowing the app to have its own workflow, document model, UI density, terminology, and release identity. A separate repository can happen later if the shared boundary becomes stable and the release cadence diverges.

Proposed structure:

```text
EVA.xcodeproj
  EVA.app
  EVA Resolve.app
  EVATests
  EVAResolveTests

Shared modules over time:
  EVACore          signal, epochs, channels, MFF I/O, shared DSP
  RIDECore         pure Swift RIDE implementation
  EVAResolveCore   trial-analysis engines and result models
```

The current repo is still a single Xcode project with one app target and synchronized source groups. That is enough to start planning and to add a sibling target later, but not enough to share code cleanly forever without some extraction.

## What EVA Resolve Owns

EVA Resolve should focus on analyses where individual accepted epochs remain meaningful after preprocessing:

- RIDE decomposition into stimulus-locked, central latency-variable, and response-locked components.
- Single-trial peak, mean, adaptive-mean, area, onset, slope, and peak-to-peak measures.
- Latency alignment methods such as Woody filtering, cross-correlation alignment, and possibly dynamic time warping.
- ERP-image style plots sorted by response time, amplitude, latency, condition, or imported trial metadata.
- Trial-wise spectral and time-frequency summaries.
- Trial-wise regression against behavior or stimulus metadata.
- Bootstrap reliability, trial-count curves, split-half checks, and condition separability summaries.
- Batch subject/condition analysis using the same configuration across many EVA outputs.

EVA should remain the primary app for opening recordings, preprocessing, filtering, artifact handling, segmentation, averaging, visualization, and MFF export. EVA Resolve should start from analysis-ready accepted epochs plus metadata. It should not need continuous raw data, and it should not redo EVA preprocessing by default.

## Native Swift RIDE Plan

EVA Resolve should not shell out to MATLAB. The MATLAB RIDE toolbox should be treated as the reference implementation for a native Swift port.

Initial Swift components:

- `RIDETensor`: explicit `time x channel x trial` storage, probably internally `Double`.
- `RIDEConfiguration`: sampling interval, epoch time window, baseline window, resampling interval, cutoff, latency search mode, and component specs.
- `RIDEComponentSpec`: component name, time window, and latency source.
- `RIDELatencySource`: `.stimulusLocked`, `.unknown`, `.responseLocked([Double])`, and later imported/event-derived sources.
- `RIDEAnalyzer`: Swift equivalent of `RIDE_call.m`.
- `RIDEIteration`: Swift equivalent of `RIDE_iter.m`.
- `RIDEOutput`: ERP, reconstructed ERP, component waveforms, stimulus-locked component waveforms, per-trial latencies, amplitudes, convergence diagnostics, and residue.

Helper ports:

- Baseline correction.
- Tukey and Hann windows.
- Detrending.
- Sample shifting/moving with edge behavior matching the MATLAB toolbox.
- Mean/median with NaN handling.
- Resampling/interpolation back to original sampling resolution.
- Low-pass filtering used during latency estimation.
- Cross-covariance/correlation.
- Peak and nearest-latency search.
- Woody latency initialization.

Implementation should start as a close behavioral port, even if the first Swift code is not beautiful. Once tests prove parity, reshape it into more idiomatic and faster Swift.

## Validation Strategy

Parity matters because RIDE is a scientific method, not just a UI feature.

Validation layers:

1. Unit-test helper functions against small hand-computed fixtures.
2. Validate tensor reshaping from EVA epochs into RIDE input.
3. Compare Swift output against MATLAB output for one or more frozen fixtures.
4. Use synthetic jittered ERP data where the expected C latency shift is known.
5. Verify `erp_new` equals the sum of estimated components within tolerance.
6. Verify response-locked components recover RT-minus-median behavior when response latencies are supplied.
7. Run performance tests on realistic channel/trial counts before wiring long-running UI flows.

## Native `.eva` Package And Data Handoff

The first transport should be explicit and file-backed, but not MFF-as-the-only-interface. The file extension should be `.eva`: a general native EVA-family EEG package that can move data between EVA, EVA Resolve, and future EVA tools. MFF remains an important import/export format, but `.eva` should be the richer internal interchange format for processed EEG data, provenance, trial metadata, and analysis-ready tensors.

The first user-facing workflow should be **Send to EVA Resolve**. This should not be limited to whatever the current Trials tab can display. It should open a dedicated send/export sheet that packages richer information from the current recording/session, prefilled from the current processing state but explicit about what will be included.

Recommended first package shape:

```text
Example.eva/
  manifest.json
  eeg.float32.bin
  epochs.json
  events.json
  channels.json
  sensorLayout.json
  processingSummary.json
  optionalTrialMetadata.tsv
```

The `.eva` manifest should be designed around multiple package profiles from the beginning:

- `continuous`: continuous sample data plus events/provenance.
- `epoched`: segmented/epoched sample data plus per-epoch metadata.
- `averaged`: averaged condition data plus contributing-trial metadata when known.

Only the `epoched` profile needs to be implemented first. The initial EVA Resolve workflow should consume `epoched` packages.

Binary sample files should use explicit tensor metadata rather than relying on implicit conventions. For the first `epoched` profile, write a float32 tensor with a declared dimension order, preferably:

```json
{
  "dataFile": "eeg.float32.bin",
  "sampleType": "float32",
  "endianness": "little",
  "dimensions": {
    "order": ["trial", "channel", "sample"],
    "trialCount": 120,
    "channelCount": 128,
    "sampleCount": 700
  }
}
```

Analysis engines can sort or transpose internally. The file format should make the stored order explicit and stable.

This package would contain the processed epoch data that the user intends to analyze, not a parallel raw/unprocessed copy. The numeric traces should be the final data EVA produced for analysis: accepted segmented/epoched data with any chosen filtering, artifact correction, bad-channel handling, interpolation, average reference, and baseline correction already applied.

The package must carry enough provenance for EVA Resolve to interpret the numbers correctly:

- Category labels.
- Stable trial IDs generated during export.
- Source file/package path or identifier.
- Trial/source event times.
- Stimulus offsets.
- Channel names.
- Sampling rate.
- Trial-count summary, including accepted/exported trial count and excluded/rejected trial count when available.
- Whether baseline correction was applied, and what baseline window/sample count was used.
- Whether average reference was applied.
- Globally bad/interpolated channels.
- Per-trial interpolated channel metadata, where available.
- Processing summary/version information.

EVA Resolve should use the final data as authoritative. Interpolation provenance should be visible and usable for labels, filtering, grouping, warnings, and exports, but Resolve does not need uninterpolated copies of those channels.

Response-time and other event-derived latency vectors should be created in EVA Resolve from either:

- Events/flags present within or near each exported epoch, such as `RESP` or another user-selected trial flag.
- A user-selected response-time table, initially CSV and JSON, matched by trial order, source event time, event id, or another explicit key.

The first table matching keys should be:

1. Stable trial ID.
2. Trial order.
3. Source event time.
4. Event ID, where EVA has stable event IDs for the source markers.

For event-derived response times, the user should be able to choose the event code and matching rule, such as first matching event after stimulus, nearest matching event, or matching event within a configured latency window. Missing values should be handled explicitly, for example by excluding those trials from response-locked RIDE components or by making the response-locked component unavailable.

Events should be exported as per-epoch event lists with a configurable margin beyond the original epoch boundary. This lets Resolve use response-time or other behavioral metadata even when the event is slightly outside the analysis epoch itself.

Transport options:

- Write `.eva` packages to disk and open them in EVA Resolve.
- Custom URL scheme such as `evaresolve://open?path=...` or normal document-opening integration can be considered to launch or foreground EVA Resolve after EVA writes a package.
- App Group shared container for private `.eva` packages and returned results, later if automatic private handoff becomes important.
- XPC for control messages, progress, cancellation, and small metadata.
- Shared memory or memory-mapped files later if the package copy cost becomes a real bottleneck.
- Pasteboard or drag-and-drop for user-driven transfer.

Avoid Distributed Objects. Apple has deprecated the `NSConnection` mechanism in favor of XPC.

Returned result package:

```text
Example.evaresolveresult/
  manifest.json
  ride_config.json
  ride_components.float32.bin
  ride_trial_metrics.tsv
  ride_component_waveforms.tsv
  diagnostics.json
```

The first integration should be one-way: EVA writes a self-contained `.eva` package to disk and opens it in EVA Resolve, or asks the user to open it there. EVA Resolve owns analysis, visualization, and result export. EVA does not need to import Resolve results in the first version.

## Does EVA Need Refactoring?

Not immediately for planning, and probably not much before the first prototype. EVA can first export a well-defined accepted-epoch package from the existing Trials/PSA state.

However, a polished two-app design will benefit from targeted refactoring. The goal should be extraction, not churn.

Likely needed:

- Move shared data models into a reusable module or package:
  - `MFFSignalData`
  - `EpochSegment`
  - `MFFEvent`
  - channel names/layout structures
  - `ChannelSet`
- Extract MFF reading/writing and shared signal metadata out of the app target if EVA Resolve needs native MFF support.
- Extract `.eva` package writing/reading into a stable `EVAFile` / `EVAExchange` layer.
- Extract pure DSP helpers already used across EVA into a shared module.
- Add explicit public/internal access boundaries, since many current types assume one app target.
- Add tests for the handoff package as a compatibility contract.
- Pass baseline-correction and average-reference provenance through the handoff, since RIDE and other single-trial analyses need to know whether the epoch data is already baselined/referenced.

Probably not needed at first:

- Rewriting EVA's waveform UI.
- Moving all PSA segmentation logic.
- Turning every EVA file into a framework.
- Making EVA Resolve understand every intermediate state EVA can display.
- Forcing MFF export/reimport as the normal handoff.

Good first step:

1. Add `EVAFile` / `EVAExchange` models and package writer inside EVA.
2. Add a tiny EVA Resolve target that opens and validates the package.
3. Once the package contract stabilizes, extract shared model code into a Swift package or framework.
4. Then add `RIDECore`.

This keeps the initial refactor small and lets the data contract teach us what actually needs to be shared.

## Current Decisions

- EVA Resolve receives processed, analysis-ready accepted epochs, not continuous raw data and not a parallel uninterpolated audit copy.
- The handoff traces are authoritative final data. Interpolated channels should be represented in the data and annotated in metadata.
- Interpolation provenance should support display, filtering, grouping, warnings, and export, but Resolve does not rerun interpolation by default.
- Response-time vectors can come from user-selected events/flags inside or near each epoch, or from a user-selected CSV/JSON response-time table.
- Baseline-correction provenance must be included: whether baseline correction was applied, and the window/sample count used.
- Average-reference provenance should also be included.
- The first integration is one-way from EVA to EVA Resolve through a native `.eva` package.
- `.eva` should be designed as a general EVA-family EEG package that can eventually move data between EVA programs, not only Resolve.
- `.eva` should be a package directory, like MFF, rather than a single monolithic file.
- `.eva` should support `continuous`, `epoched`, and `averaged` profiles in the manifest design, but implement `epoched` first.
- Epoched sample tensors should declare their dimension order explicitly; v1 should prefer `trial x channel x sample`.
- EVA should generate stable trial IDs during export and include source-file/source-package metadata plus accepted/excluded trial counts.
- Per-epoch event lists should include a configurable margin outside the epoch boundary so response-time metadata can be available even when it falls outside the analysis window.
- Interpolation provenance is per-trial channel list for v1.
- V1 transport is ordinary disk-based `.eva` package writing/opening. Smoother app-to-app handoff can come later.
- The `.eva` format should be versioned and designed as if it may become public, but treated as internal until workflows stabilize.

## Remaining Open Questions

- Should EVA Resolve support opening ordinary averaged MFFs later, or only `.eva` packages in the first version?
- How much of the `.eva` package format should be documented publicly before the format reaches `1.0`?
- Should `Send to EVA Resolve` default to a user-chosen destination, an app-managed temporary location, or remember the last destination?
- What should the default event margin be for per-epoch event lists?
