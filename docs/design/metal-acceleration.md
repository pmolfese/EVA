# Metal acceleration — porting audit (June 2026)

The eligibility rubric and per-area option matrix behind EVA's GPU work.

**Status is in `ROADMAP.md` § Performance & Metal (what is left) and
`ROADMAP_COMPLETE.md` (wavelets and gradient correction, both shipped).** The
document's own "Recommended order", "Architecture proposal" and "Practical first
project" sections are historical: the shipped work did not follow them.

---

# EVA Metal options - June 30, 2026

> ## Status, revised 2026-08-11
>
> This document is a **June 2026 design audit**, kept for the areas that are
> still un-ported. Three things about it are now out of date — read these first.
>
> **1. Three areas have shipped**, and none of them followed this doc's ordering:
> - **Wavelets** — `EVA/Wavelet/WaveletMetalBackend.swift` + `WaveletKernels.metal`,
>   covered by `EVATests/Wavelet/WaveletMetalBackendTests.swift`. (Ranked #2 here;
>   the "SWT first" advice held up.)
> - **Gradient correction** — `EVA/Gradient/GradientMetalBackend.swift` +
>   `GradientCleanroomKernels.metal`. Ranked #7 with a "benchmark first, payoff may
>   be smaller than wavelets" caveat; it was done early anyway.
> - **Local-template correction** — `EVA/Gradient/LocalTemplateMetalBackend.swift`
>   + `LocalTemplateKernels.metal`. Not anticipated by this doc at all.
>
> **2. The "Architecture proposal" section below did NOT happen** — treat it as a
> rejected alternative, not a description of EVA. There is no `ComputeBackend`
> enum, no `MetalSignalContext`, no `MetalSignalKernels`, no `MetalSignalBuffer`
> anywhere in the tree. What shipped instead is **one self-contained backend per
> domain**, each owning its own `.metal` file, with the CPU path as the reference.
> Any future port should match the shipped pattern unless there's a reason to
> revisit. Likewise the "Practical first project" section describes a path not
> taken.
>
> **3. The prerequisites in "Before starting Metal" are resolved or obsolete.**
> `bugs_june29.md` no longer exists, and the `DSP` correctness work it gated on has
> since been through the clean-room reimplementation pass. The still-live items are
> the canonical channel-major layout (item 4) and signpost timing (item 5).
>
> File paths in the option matrix and per-area sections have been updated for the
> directory reorg. `FastrCorrector.swift` and `GradientRemover.swift` no longer
> exist as such — that code now lives across `EVA/Gradient/` (`GradientAAS`,
> `GradientTemplateCorrector`, `GradientOBS`, `GradientANC`,
> `GradientSincResampler`, `GradientDonorSelection`, …).
>
> Everything below the header is the original June audit. The eligibility rubric,
> the poor-candidate list, and the per-area risk notes for the ten un-ported areas
> are why it's still here.

---

This is a static design audit of EVA paths that could reasonably get an Apple
Metal compute pathway. It focuses on pathways beyond the Moosmann neighbor
selection discussion, though FASTR pieces are included where they overlap with
shared signal-processing kernels.

The short version: the best first Metal targets are the repeated, dense,
same-shape operations that already run over channels, samples, windows, levels,
or pixels. The weak targets are small matrix solves, sorting/percentiles,
event bookkeeping, file I/O, and any algorithm whose work is mostly branchy
control flow.

## Eligibility rubric

A path is a good Metal candidate when most of these are true:

- The same operation is repeated over many channels, samples, epochs, windows,
  wavelet levels, or pixels.
- The input and output can be represented as flat `Float` buffers.
- Data can stay resident on the GPU across several kernels.
- The output can be a dense score/correction buffer, with CPU doing the final
  thresholding, sorting, merging, or UI object creation.
- The CPU implementation is currently spending time in scalar loops rather than
  already being a tiny BLAS/LAPACK call.

A path is a poor first candidate when most of these are true:

- It solves a very small linear system or eigendecomposition once.
- It requires irregular Swift collections, dictionaries, sets, or nested arrays.
- It spends most time in sorting, parsing, file I/O, or UI state transitions.
- It has recursive sample dependencies, such as IIR biquad filtering.
- It would require copying huge buffers to the GPU for one small operation.

## Before starting Metal

Do these first, because Metal will make numerical bugs harder to see:

1. ~~Fix and test `DSP.convolveSame`, `DSP.firFilter`, `DSP.interp`, and
   `DSP.decimate`.~~ *(Resolved by the clean-room DSP pass.)*
2. ~~Lock down `DSP.lmsAdaptiveFilter` with a deterministic reference test.~~
   *(Resolved.)*
3. ~~Fix the concurrent Swift array write patterns listed in `bugs_june29.md`.~~
   *(File no longer exists; superseded.)*
4. Decide on one canonical signal layout for compute paths:
   `channel-major Float`, flattened as `buffer[channel * sampleCount + sample]`.
5. Add signpost timing around each candidate before porting, so we know what
   actually costs time on real EEG-fMRI recordings.

## Recommended order

*(Original June ordering, kept for its reasoning. Actual history: wavelets and
gradient/local-template shipped; the shared utility layer in step 1 was never
built — see the status header. Steps 3-9 are the live queue.)*

1. ~~Metal utility layer and benchmarking harness.~~ *(Not built; per-domain
   backends won instead.)*
2. ~~Wavelet analyzer/reducer kernels.~~ *(Shipped.)*
3. Artifact template topography and trajectory scans.
4. BCG projection, GFP, smoothing, and rolling normalization.
5. Common reductions shared by filtering, average reference, GFP, RMS, and
   health metrics.
6. OBS/SSP correction kernels.
7. FASTR resampling/template/OBS kernels after DSP correctness is stable.
   *(Partly shipped: gradient/local-template correction are on GPU; OBS/ANC/
   resampling are not.)*
8. ICA block matmul/tanh kernels only after the simpler GPU paths are proven.
9. Topomap rendering or ICLabel feature image generation if UI redraw becomes
   a visible bottleneck.

## Option matrix

| Area | Files | Metal fit | Expected payoff | First version |
| --- | --- | --- | --- | --- |
| **✅ SHIPPED** Wavelet artifact analyzer | `EVA/Wavelet/WaveletArtifactAnalyzer.swift`, `WaveletMetalBackend.swift` | Excellent | High | SWT smoothing/detail/threshold kernels |
| **✅ SHIPPED** Wavelet reducer | `EVA/Wavelet/WaveletReducer.swift`, `WaveletMetalBackend.swift` | Excellent for SWT, moderate for DWT | High | SWT path first |
| Artifact template scans | `EVA/Artifacts/ArtifactTemplateDetector.swift` | Excellent | High | Dense score buffer, CPU threshold/merge |
| BCG detection scores | `EVA/Cardiac/BCGDetector.swift` | Excellent | Medium-high | Projection/GFP/rolling stats |
| Common reductions | `EVA/Filtering/EEGSignalFilter.swift`, `EVA/ICA/ICAArtifactDetector.swift`, `EVA/Cardiac/BCGDetector.swift` | Excellent | Medium | mean, RMS, GFP, average reference |
| OBS/SSP cleaning | `EVA/Artifacts/ArtifactCleaner.swift` | Good but trickier | Medium-high | per-window fit and taper, CPU PCA |
| FASTR core math | `EVA/Gradient/ (GradientTemplateCorrector, GradientOBS, GradientANC, GradientSincResampler)`, `EVA/Core/DSP.swift` | Good after fixes | Medium-high | FIR/resampling, template subtraction |
| **✅ SHIPPED** Gradient remover | `EVA/Gradient/GradientMetalBackend.swift`, `LocalTemplateMetalBackend.swift` | Good but maybe lower priority | Medium | TR detrend/template kernels |
| Channel/segment health | `EVA/Health/ChannelHealthAnalyzer.swift`, `EVA/Health/SegmentHealthAnalyzer.swift` | Mixed | Medium | Welch and windowed correlations |
| ICA fit/cleaning | `EVA/ICA/ICAArtifactDetector.swift` | High potential, high lift | Medium-high | block matmul + tanh, not full solver first |
| Topomap rendering | `EVA/Channels/TopomapView.swift`, `EVA/ICA/ICLabelClassifier.swift` | Excellent, self-contained | Medium UI payoff | IDW grid to texture |
| ICLabel inference | `EVA/ICA/ICLabelClassifier.swift` | Already delegated | Low | Leave Core ML on `.all` compute units |
| I/O and XML parsing | `EVA/IO/MFFReader.swift`, `EVA/IO/MFFWriter.swift` | Poor | Low | Do not port |

## 1. Wavelet artifact analyzer — ✅ SHIPPED

*Implemented in `EVA/Wavelet/WaveletMetalBackend.swift` + `WaveletKernels.metal`,
tested by `EVATests/Wavelet/WaveletMetalBackendTests.swift`. Notes below are the
original plan, kept for the DWT path and the robust-sigma percentile question,
which remain open.*

Files:

- `EVA/Wavelet/WaveletArtifactAnalyzer.swift`
- `EVA/Wavelet/WaveletReducer.swift`

Why it fits:

- `prepareChannel` and `undecimatedDetails` repeatedly run the same small
  smoothing kernels over long sample vectors.
- SWT detail extraction is naturally data-parallel by channel, level, and sample.
- Thresholding, artifact-energy accumulation, signed salience, and energy
  salience are all simple per-element or reduction kernels.

Good Metal shape:

- Upload a flattened `channels x samples` buffer.
- Kernel 1: downsample/demean per channel.
- Kernel 2: for each level, compute low-pass smooth and detail with the dilated
  kernel.
- Kernel 3: compute per-level energy and sampled statistics for thresholding.
- Kernel 4: threshold details and accumulate salience.
- Return compact per-channel summaries plus optional artifact buffers.

What should stay CPU:

- Candidate/event creation.
- Sorting strong channels/levels.
- UI summaries and saved template construction.

Risks:

- Robust sigma currently sorts sampled absolute values. A GPU path should either
  return sampled values for CPU percentile calculation, or use a histogram or
  selection kernel later.
- DWT has downsampling and reconstruction dependencies that are less uniform
  than SWT. Start with SWT/undecimated paths.

First milestone:

- Implement a Metal `undecimatedDetails` equivalent for `Float`, compare against
  CPU with fixed inputs, then wire it only into preview/analyzer code behind a
  feature flag.

## 2. Artifact template waveform and topography scans

Files:

- `EVA/Artifacts/ArtifactTemplateDetector.swift`
- `EVA/Wavelet/WaveletArtifactAnalyzer.swift`

Why it fits:

- The slow part is many candidate windows scored against one template.
- Window normalization and dot products are repeated with identical shape.
- Topography and trajectory matching score many candidate samples/maps.

Good Metal shape:

- Prepack downsampled channels as `channel x sample`.
- For waveform matching, output one score per candidate start.
- For topography matching, output one score per decimated sample.
- For trajectory matching, output one best score per candidate start across
  shifts and scales.
- CPU then thresholds, merges nearby hits, and creates `MFFEvent`s.

Better than atomic hit writes:

- Do not append hits from the GPU.
- Write dense `score[candidateIndex]` or `score[sampleIndex]`.
- Threshold and merge on CPU. This avoids atomics, dynamic allocation, and
  nondeterministic hit order.

Optimization opportunities:

- Precompute normalized spatial maps once as a flat buffer.
- For waveform scanning, consider rolling prefix sums for window mean and norm,
  so the GPU dot kernel does not re-normalize from scratch every time.
- For trajectory search, each thread can own one candidate and loop over
  shift/scale/reference frames.

Risks:

- The fallback candidate grid can be large. Chunk long recordings.
- Floating-point differences can move scores around a threshold. Keep CPU and
  Metal tests with tolerant but explicit score comparisons.

First milestone:

- Port `detectTopography` static map scan first. It is smaller than trajectory
  scan and has a clean `sample -> score` mapping.

## 3. BCG detection pathways

Files:

- `EVA/Cardiac/BCGDetector.swift`
- `EVA/Filtering/EEGSignalFilter.swift`

Why it fits:

- `computeGFP`, cardiac weighted projection, spatial PCA projection, boxcar
  smoothing, sliding RMS normalization, and sliding z-score are all dense
  sample-wise kernels.
- BCG uses long recordings, so GPU launch overhead is amortized.
- The eigendecomposition itself is small and can stay CPU-side.

Good Metal shape:

- CPU computes or receives filter output and small PCA/whitening matrices.
- Metal computes `W * channels`, component projections, RSS score, GFP, smooth,
  local RMS, and local z-score.
- CPU performs robust threshold estimation, non-maximum suppression, and event
  object creation.

Possible shared kernels:

- `gfp(channels) -> score`
- `weightedSum(channels, weights) -> score`
- `rollingMean`, `rollingSumSquares`, `rollingRMS`, `rollingZ`
- `matrixChannelsMultiply(matrix, channels) -> transformedChannels`

Risks:

- The current BCG whitening/projection correctness issues should be fixed first.
- BCG paths call `EEGSignalFilter.bandPass`, whose current biquad implementation
  is recursive. Do not try to port that recursive filter first.

First milestone:

- Keep filtering on CPU and port only the post-filter projection/normalization
  stage. That gives a useful speed path with less numerical risk.

## 4. Common reductions and signal transforms

Files:

- `EVA/Filtering/EEGSignalFilter.swift`
- `EVA/ICA/ICAArtifactDetector.swift`
- `EVA/Cardiac/BCGDetector.swift`
- `EVA/Core/SignalStatistics.swift`

Why it fits:

- EVA repeats the same operations in many places: channel mean, per-sample mean,
  RMS, sum of squares, absolute max, GFP, average reference, weighted sum, and
  centered dot products.
- A small reusable Metal kernel library could pay off across multiple features.

Good Metal shape:

- `averageReference(channels, badMask) -> channels`
- `perChannelMean(channels) -> means`
- `perSampleMean(channels) -> meanTrace`
- `perChannelRMS(channels) -> rms`
- `gfp(channels) -> gfpTrace`
- `centeredDotWindows(signal, template, starts) -> scores`

Risks:

- Reductions are easy to write poorly. Use threadgroup reductions and compare
  to vDSP on realistic sizes.
- On Apple Silicon, `storageModeShared` avoids explicit copies, but memory
  bandwidth still matters. A CPU vDSP path may beat GPU for small data.

First milestone:

- Build a shared `MetalSignalKernels` wrapper with CPU fallback and a benchmark
  that can run average reference, GFP, and weighted projection.

## 5. OBS and SSP/PCA artifact cleaning

Files:

- `EVA/Artifacts/ArtifactCleaner.swift`

Why it fits:

- Once bases/components are known, every event window performs similar projection,
  correction, taper, and subtract/accumulate operations.
- Large event counts make this attractive.

Good Metal shape:

- Keep PCA/eigendecomposition and component selection on CPU.
- Upload channel data, event ranges, basis vectors, taper, and component vectors.
- Kernel per `(event, channel)` or `(event, channel, sample)` computes the fitted
  correction.
- For non-overlap mode, write a compact correction buffer and subtract serially
  or in a second kernel.
- For overlap-add, accumulate into `weightedValues` and `weights`, then apply.

Risks:

- Overlap-add needs deterministic accumulation. Atomic float adds are possible
  only on some GPU families and should be avoided as the first design.
- Event windows are irregular and can overlap. The safest first version emits
  per-event corrections and lets CPU merge/apply them.
- Small basis counts mean CPU can be very competitive.

First milestone:

- Port the per-window `fittedCorrection + taper` math for non-overlap mode only.
  Keep PCA, event range construction, and final event merging on CPU.

## 6. FASTR, FARM, Moosmann, and shared DSP

Files:

- `EVA/Gradient/ (GradientTemplateCorrector, GradientOBS, GradientANC, GradientSincResampler)`
- `EVA/Core/DSP.swift`

Why it fits:

- Upsampling/downsampling, FIR filtering, per-epoch template subtraction, OBS
  residual projection, and ANC are dense numeric operations.
- FASTR repeats similar work for every channel and slice/volume epoch.

Good Metal shape:

- ~~Port only after DSP correctness is fixed.~~ *(That gate is now cleared — see
  the status header. Template subtraction has since shipped on GPU; OBS, ANC, and
  resampling have not.)*
- FIR convolution/resampling can become a batched channel kernel.
- Template averaging and subtraction can be expressed as `epoch x sample`.
- OBS residual fitting can use the same window-projection kernels as
  `ArtifactCleaner`.

What should stay CPU at first:

- Trigger slicing.
- Donor selection and motion logic.
- FARM correlation sorting.
- Moosmann neighbor index construction, unless recordings are enormous.
- Event/censoring bookkeeping.

Risks:

- FASTR has lots of algorithmic branch points. A monolithic GPU port would be
  hard to validate.
- Fractional shift currently uses a custom FFT. A Metal FFT path would likely
  require MPS or a separate FFT implementation and should not be the first port.
- ANC/LMS is recursive over samples. It is eligible only across channels or with
  a more advanced block algorithm.

First milestone:

- After `DSP.convolveSame` and resampling are fixed, port batched FIR/resampling
  as a shared utility and let FASTR call it.

## 7. Gradient remover — ✅ SHIPPED

*Implemented in `EVA/Gradient/GradientMetalBackend.swift` +
`GradientCleanroomKernels.metal`, plus `LocalTemplateMetalBackend.swift` +
`LocalTemplateKernels.metal` for local-template correction (an area this audit
did not anticipate). Notes below are the original plan.*

Files:

- `EVA/Gradient/ (GradientAAS, GradientTemplateCorrector)`

Why it fits:

- TR detrending, neighbor-template averaging, and subtraction repeat across
  channels and TRs.
- Segment length is fixed within a run.

Good Metal shape:

- Flatten as `channel x tr x sampleWithinTR`.
- Kernel 1: linear detrend each TR.
- Kernel 2: build before/after mean templates.
- Kernel 3: subtract templates and write corrected signal.

Risks:

- This code already uses vDSP and parallelizes by channel, so Metal payoff may
  be smaller than wavelets/template scans.
- Excluded TRs add branchy donor logic. CPU can precompute donor weights and
  pass a dense donor-weight table to the GPU.

First milestone:

- Benchmark first. If it is actually slow on real data, port detrend and
  template subtraction, not the trigger validation logic.

## 8. Channel and segment health analysis

Files:

- `EVA/Health/ChannelHealthAnalyzer.swift`
- `EVA/Health/SegmentHealthAnalyzer.swift`

Why it fits:

- Welch band power, RANSAC-style windowed correlations, GFP summaries, and
  channel RMS/derivative metrics are dense scans.

Good Metal shape:

- Kernel per channel for finite count, sum, sum of squares, derivative energy,
  max abs, and downsampled summaries.
- Kernel per channel/window for RANSAC correlations.
- Use MPS/Metal FFT only if Welch becomes a confirmed hotspot.

What should stay CPU:

- Percentile sorting unless we replace it with approximate histograms.
- Final grading and metric text.
- Neighbor selection by sensor distance.
- Artifact interval overlap.

Risks:

- Health paths intentionally sample the data to cap cost, so the raw payoff may
  be lower than expected.
- Approximate GPU percentiles could change channel grades. Keep exact CPU
  percentile logic until performance demands otherwise.

First milestone:

- Port RANSAC windowed correlation after creating the shared centered-dot kernel.

## 9. ICA fitting and ICA cleaning

Files:

- `EVA/ICA/ICAArtifactDetector.swift`

Why it fits:

- ICA fit uses large dense matrix multiplies, `tanh`, gradient matrices, and
  repeated source projections.
- ICA cleaning already works in blocks and uses skinny matrix multiplication.

Best Metal entry points:

- `cleanedSignal`: use MPSMatrixMultiplication for the two block matmuls:
  `unmixingRows * centeredBlock` and `mixingColumns * sourceBlock`.
- `fastICAFloat`: keep control flow on CPU, move `W * X`, `tanh`, row means,
  and `gU * X^T` into a single GPU-backed iteration.
- `picardFloat`: possible later, but line search, L-BFGS memory, and loss
  evaluation make it a more complex port.

What should stay CPU:

- PCA eigen solve and selected component bookkeeping.
- Convergence decisions and annealing/restart logic.
- Core ML ICLabel inference. It already uses `MLModelConfiguration.computeUnits
  = .all`, so the system can choose CPU/GPU/ANE.

Risks:

- ICA is convergence-sensitive. Tiny numerical differences can change iteration
  counts and component order.
- Repeated CPU-GPU synchronization per iteration can erase the matmul win.
- `Accelerate`/BLAS on Apple Silicon is already strong; benchmark before doing
  more than ICA cleaning.

First milestone:

- Port only ICA cleaning block projection first. It is deterministic and easier
  to compare against CPU than the ICA optimizer itself.

## 10. Filtering, resampling, and adaptive line noise

Files:

- `EVA/Filtering/EEGSignalFilter.swift`
- `EVA/Core/DSP.swift`
- `EVA/Core/Downsampler.swift`

Good candidates:

- FIR convolution.
- `interp` and `decimate`.
- Common-average reference.
- Linear upsample and block-average downsample.
- Adaptive line noise window fits, if large recordings make it expensive.

Weak candidates:

- Current zero-phase Butterworth biquad filtering is recursive. Metal can
  parallelize across channels, but not across samples in a simple way.
- `subtractAdaptiveSinusoid` has overlapping windows, small 2x2 solves, and
  repeated trig. It is eligible, but not a first target.

Better approach:

- Keep IIR biquad on CPU for now.
- Add a shared Metal FIR/resampling path after DSP correctness is fixed.
- If we later need GPU band-pass, consider FIR/FFT overlap-save rather than
  porting the recursive biquad.

## 11. Topomap and small image generation

Files:

- `EVA/Channels/TopomapView.swift`
- `EVA/ICA/ICLabelClassifier.swift`

Why it fits:

- Topomap IDW interpolation is one independent calculation per output pixel.
- ICLabel scalp image generation is also a small grid interpolation.

Good Metal shape:

- Upload sensor positions and values.
- Kernel writes a 2D texture or flat RGBA/image buffer.
- SwiftUI/MetalKit displays the texture, or CPU reads back the small 32x32
  feature image for Core ML.

Risks:

- For ICLabel, the grid is only 32x32, so CPU is probably fine.
- For visible topomaps, integration with SwiftUI may cost more time than the
  kernel unless the topomap redraws frequently or at high resolution.

First milestone:

- If topomap redraw is visible, port `drawInterpolatedField` to a texture
  generator. This is a very self-contained Metal experiment.

## 12. Rendering waveforms

Files:

- `EVA/Waveform/WaveformView.swift`

Current shape:

- Waveform plots, butterfly plots, ICA previews, and physio tracks build
  SwiftUI `Path`s in `Canvas`.
- They already decimate to roughly pixel density in most places.

Metal eligibility:

- A true Metal renderer could draw many channel traces from a vertex buffer.
- This is more of a UI/rendering project than a signal-processing speedup.

Recommendation:

- Do not start here unless scrolling/zooming is visibly janky after compute
  paths are stable.
- If we do start here, build a small `MTKView` trace renderer for waveform rows,
  keeping the existing SwiftUI path renderer as fallback.

## 13. Not worth porting soon

Leave these on CPU:

- MFF XML/binary import and export.
- Event merging, grouping, filtering, and `MFFEvent` construction.
- Small LAPACK solves/eigendecompositions unless they become batched.
- Spherical spline interpolation weights.
- Sensor layout parsing.
- Core ML ICLabel prediction.
- Any UI text, table, summary, or grading logic.

## Architecture proposal — ❌ NOT ADOPTED

> **This section describes a design EVA did not take.** None of these types
> exist. The shipped pattern is one self-contained Metal backend per domain
> (`WaveletMetalBackend`, `GradientMetalBackend`, `LocalTemplateMetalBackend`),
> each owning its `.metal` file, with the CPU implementation as the reference
> path. Kept as a record of the alternative — revisit only if enough per-domain
> backends accumulate duplicate kernels to justify a shared layer.
>
> **Still applicable regardless of which pattern wins:** the *Data layout*,
> *Validation*, and *Performance measurement* subsections at the end.

Add a small compute abstraction rather than embedding Metal calls directly in
each algorithm.

Suggested pieces:

- `ComputeBackend`: `.cpu`, `.metal`, `.automatic`.
- `MetalSignalContext`: owns `MTLDevice`, command queue, pipeline cache, and
  reusable buffers.
- `MetalSignalBuffer`: wraps flattened channel-major `Float` data plus shape.
- `MetalSignalKernels`: reusable kernels for reductions, projections,
  smoothing, window scores, thresholding, and taper/subtraction.
- Per-feature adapters:
  - `MetalWaveletAnalyzer`
  - `MetalArtifactTemplateScanner`
  - `MetalBCGScorer`
  - `MetalArtifactCleaner`

Runtime policy:

- Default to `.automatic`.
- Use CPU for small arrays, unsupported devices, ragged data, or debug mode.
- Use Metal only when `channelCount * sampleCount` or candidate count exceeds a
  measured threshold.
- Always keep CPU fallback as the reference path.

Data layout:

- Prefer `Float`.
- Flatten `[[Float]]` into one row-major buffer:
  `offset = channel * sampleCount + sample`.
- For event/window paths, pass `eventStarts` and fixed `windowLength` whenever
  possible.
- Avoid nested Swift arrays inside kernels. Pack everything into buffers before
  dispatch.

Validation:

- Golden CPU-vs-Metal tests for every kernel.
- Use absolute and relative tolerances, for example `1e-4` to `1e-5` for
  `Float` score paths, tighter only where justified.
- Test pathological inputs: empty, constant, NaN/Inf, ragged fallback, one
  channel, short windows, large sample counts.
- Compare downstream event times and counts, not only raw score arrays.

Performance measurement:

- Add `os_signpost` spans around CPU and Metal phases.
- Measure total wall time including packing/unpacking.
- Record memory footprint for large EEG-fMRI runs.
- Measure on representative recordings, not only synthetic arrays.

## Practical first project — ❌ SUPERSEDED

*Not the path taken; wavelets and gradient went first, without the shared kernel
layer. Kept for the reasoning about why a clean score buffer plus CPU fallback
makes a good validation target — that argument still applies to whatever gets
ported next (artifact topography scan is still the strongest remaining
candidate).*

The first real Metal project I would choose is:

1. Build `MetalSignalContext` and a CPU/Metal benchmark command path.
2. Implement three shared kernels:
   - `averageReference`
   - `gfp`
   - `weightedProjection`
3. Use those kernels in BCG post-filter scoring behind an `.automatic` feature
   flag.
4. Then port the artifact topography scan, because it has a clean score buffer
   and obvious UI-facing payoff.

The first big project after that should be the wavelet analyzer/reducer. That is
where the code has the best combination of repeated dense math, long buffers,
and a clean CPU fallback for validation.
