# FASTR GPU Backend — Port Plan

Internal planning document for the remaining work on the FASTR-family clean-room
track. Companion to `fastr-functional-spec.md` and
`fastr-audit-log.md`. Not a legal opinion.

Written 2026-08-08, from EVA's own clean-room CPU implementation.

## Status — COMPLETE 2026-08-09

All phases including Phase 7 are done. The historical FASTR files are deleted,
the UI is wired to `GradientTemplateCorrector`, and `THIRD_PARTY_NOTICES.md`
carries the clean-room entry.

**A note on paths and tense.** Everything below the status sections is the
original plan, preserved as the record of what was decided and why. It was
written when the clean-room code lived in a `Cleanroom/` subdirectory and the
ported files still shipped. Paths have been updated to the current layout — the
subdirectory was flattened into `EVA/Gradient/` once every engine in it was
clean-room — but statements about what "still ships" or is "not yet done"
describe the state at the time of writing, not now. File counts in the original
text are likewise from then.

What landed:

- `EVA/Gradient/GradientAcceleration.swift` — `GradientComputeBackend`,
  the batched per-stage `GradientBackend` protocol, and `GradientCPUBackend`.
- `EVA/Gradient/GradientMetalBackend.swift` and
  `GradientCleanroomKernels.metal` — eight kernels.
- `GradientTemplateCorrector` restructured as a driver: it owns every discrete
  decision and hands the dense arithmetic to a backend, tiled across channels.
- `EVATests/Gradient/GradientBackendParityTests.swift`, plus the 50
  end-to-end tests in the two corrector suites parameterised over both backends.

### What the profile actually said

Apple silicon, Release build. 64 channels, 10 minutes at 1 kHz, 30 slices per 2 s
TR (`E = 9000`, `W = 67`) unless noted.

| Configuration | CPU | Metal | Speedup |
| --- | --- | --- | --- |
| Template subtraction only | 0.74 s | 0.36 s | 2.1x |
| + `upsampleFactor = 2` | 1.11 s | 0.43 s | 2.6x |
| + OBS (`.automatic`) | 1.13 s | 0.74 s | 1.5x |
| + ANC | 1.37 s | 1.06 s | 1.3x |
| + OBS + ANC | 1.74 s | 1.47 s | 1.2x |
| Correlation-ranked donors, 32 ch, 300 volumes | 2.2-5.1 s | ~1.0 s | 2.2-5x |

The correlation row is given as a range because the CPU figure is thermally
sensitive — it measured 5.07 s immediately after a heavy benchmark and 2.15 s
from cool. The Metal figure was stable at ~1.0 s in both. Treat the low end as
the honest claim.

Four things this changed about the plan above:

1. **The plan was right about correlation donor scoring.** It is the largest
   single stage and the clearest GPU win. Phase 2 was correctly prioritised.
2. **The CPU baseline is not what the plan assumed.** The plan describes a serial
   channel loop; `GradientCPUBackend` now runs channels concurrently across
   cores, which is most of the "batch across channels" win on its own and is why
   the remaining GPU speedups are 2-3x rather than 10x. Accelerate was not needed
   to get there and was deliberately not used — `vDSP` reassociates sums, and a
   reference implementation that drifts is not one.
3. **OBS was dominated by the eigen-decomposition, not the Gram — and that has
   been fixed.** Before the fix, cost against `obsMaximumEpochsPerChunk` (64 ch,
   10 min, CPU / Metal) was 32 → 1.07 / 0.78 s, 64 → 1.18 / 0.90 s,
   128 → 2.10 / 1.83 s, 256 → 7.96 / 5.22 s: an `n^3` blow-up in the `dsyev`
   calls, which the GPU Gram could not touch. Two changes removed it:
   - `LinearAlgebra.leadingSymmetricEigenpairs` asks LAPACK's `dsyevr` for only
     the top `k` eigenpairs by index range. `.automatic` never keeps more than
     `obsMaximumComponents` (default 5) and `.fixed` asks for a specific small
     number, so the old code was computing 256 eigenvectors to use 5. The total
     variance that `.automatic` compares against now comes from the Gram's
     **trace**, which is the sum of the eigenvalues exactly, so no spectrum is
     needed for it either. This is exact, not approximate — same reduction, same
     solver, asked for less.
   - The per-job OBS pass in `GradientTemplateCorrector.applyOBS` now runs across
     jobs concurrently. Chunks partition the epochs and slots are distinct
     channels, so every job writes to a disjoint range; diagnostics are merged
     back in job order so what the diagnostic channel reports does not depend on
     scheduling.

   After: 32 → 0.97 / 0.58 s, 64 → 0.96 / 0.56 s, 128 → 1.00 / 0.63 s,
   256 → 1.07 / 0.73 s. **7.5x on CPU and 7.2x on Metal at the default limit**,
   and the cost is now essentially flat in `obsMaximumEpochsPerChunk` — the
   `n^3` term is gone rather than merely divided across cores. Raising the cap
   for a better basis is no longer something you pay for in minutes.
4. **ANC did not move, and should not.** See below. It is now the largest single
   stage in the default-plus-ANC configuration.

### Crossover, and the automatic fallback

Workload is epoch samples summed over corrected channels
(`channels x epochs x windowLength`).

| Workload | CPU | Metal | Speedup |
| --- | --- | --- | --- |
| 10,117 | 0.9 ms | 3.7 ms | 0.25x |
| 162,408 | 5.1 ms | 5.2 ms | 0.99x |
| 486,688 | 11.3 ms | 8.3 ms | 1.37x |
| 7,795,584 | 143.4 ms | 66.2 ms | 2.17x |

`GradientCorrectionConfig.metalMinimumWorkload` defaults to 250,000, which is
where those cross. Below it a `.metal` run silently uses the CPU and says so in
`diagnostics.computeBackend`. Tests set it to 0.

### Deviation: ANC stays on the CPU

Phase 6 asked for batched NLMS on the GPU. It is not implemented, and the reason
is parity rather than effort or occupancy.

NLMS is recursive: each sample's weight update feeds the next. Over 600,000
adaptation steps a float32 weight trajectory does not track a float64 one to
anything near the 1e-5-of-artifact-amplitude bound the rest of this backend
meets — the errors compound rather than cancelling. The plan's own float32
guidance covers bulk sums and threshold comparisons; a long recursion is neither.

ANC is not free — about 0.65 s of the numbers above — so this is a real cost. If
it is ever moved, it needs its own documented tolerance, its own
`GradientANC.Result`-equivalent divergence flags read back to the CPU, and its own
argument. It should not inherit this one.

## Why This Track Exists

`EVA/Gradient/` now contains a complete, tested, EVA-owned CPU
implementation of the FASTR family. But EVA still ships two files that are GPU
implementations of the *earlier ported* algorithm:

- `EVA/Gradient/FastrMetalBackend.swift` (~45 KB)
- `EVA/Gradient/FastrKernels.metal` (~15 KB)

Until those are replaced, the derivation the clean-room process was meant to
remove is still in the shipping product. A clean CPU path that falls back to
tainted GPU kernels closes nothing.

**Goal:** a Metal backend for `GradientTemplateCorrector` that is a port of the
clean-room CPU code and nothing else, after which the old FASTR files (CPU and
GPU) can be deleted.

## Provenance Rules — Read This First

The rules here are **not** the same as the CPU clean-room track, and it is worth
being clear about why. You are porting EVA's own code to a different execution
target. That is ordinary engineering, not a clean-room reimplementation.

**You must read** (this is the specification):

- `EVA/Gradient/` — all nine files. This is the source of truth. The
  GPU backend must reproduce what this code does.
- `EVATests/Gradient/` — all eight suites. These are the acceptance
  criteria and they must pass against the GPU backend too.
- `docs/provenance/fastr-functional-spec.md` — behavior and the EVA safety
  constraints.
- `docs/provenance/fastr-audit-log.md` — why things are the way they are.

**You must not read:**

- `EVA/Gradient/FastrMetalBackend.swift` and `EVA/Gradient/FastrKernels.metal` —
  the files being replaced. Reading them to see "how it was done before" is
  exactly the derivation this track exists to remove. If you need to know what
  the old kernels did, the answer is: it does not matter, port the CPU code.
- `EVA/Gradient/FastrCorrector.swift`
- `resources/fmrib/`, `resources/facet/`, `resources/BERGEN/`
- The assistant memory `fmri-motion-fastr.md`, which carries dirty-room notes on
  reference-toolbox internals and is marked accordingly.

**Start a fresh session for this work.** The session that wrote the CPU
implementation read `fmri-motion-fastr.md` at the end of its run and is recorded
as tainted for further FASTR clean-room work. That taint does not extend to this
document — everything below is derived from EVA's own clean code — but it does
mean the porting work itself should begin somewhere clean.

## Before You Write Any Metal

The CPU implementation was written for clarity and correctness in its first pass.
Every hot loop is plain Swift over `[Double]` and `[Float]` with no vectorisation
at all — no `vDSP`, no `simd`, no unsafe buffer access.

**Measure first, and try Accelerate before Metal.** A `vDSP` pass over the same
code may get most of the available speedup for a fraction of the complexity and
with none of the float32 parity problems described below. `vDSP_dotprD`,
`vDSP_vsmulD`, and `vDSP_vaddD` alone cover the template build, the projection,
and the artifact accumulation while staying in `Double`.

Reach for Metal for the two stages where the arithmetic genuinely is enormous and
embarrassingly parallel — correlation-ranked donor scoring and the OBS Gram
matrix — and only if profiling on a real recording says they dominate.

## What You Are Porting

The pipeline, in `GradientTemplateCorrector.correct(channels:volumeTriggers:config:samplingRate:progress:)`.

Dimensions used below, with realistic ranges for EEG–fMRI:

| Symbol | Meaning | Typical |
| --- | --- | --- |
| `C` | channels | 32–256 |
| `N` | samples per channel | 1e5–1e7 |
| `L` | `upsampleFactor` | 1–10 |
| `E` | epochs | 100–20,000 |
| `W` | epoch window length, upsampled | `period + 1` |
| `D` | donors per epoch | ~30 |
| `S` | `correlationSearchWindow` | 240 |
| `K` | OBS components | 1–5 |

Stage costs, ordered as they run. "Channel-independent" stages happen once for
the whole recording, not per channel.

| Stage | Where | Cost | Parallel over |
| --- | --- | --- | --- |
| Epoch layout | `GradientEpochLayout.build` | trivial | — (channel-independent) |
| Motion / high-motion volumes | `GradientDonorSelection` | trivial | — (channel-independent) |
| Alignment | `GradientEpochAligner.align` | `E · R · W`, one channel only | leave on CPU |
| Upsampling | `GradientSincResampler.upsample` | `C · N · L · 8` | every output sample |
| Epoch extraction + fractional delay | corrector | `C · E · W · 16` | every epoch sample |
| Temporal / motion donor selection | `GradientDonorSelection` | trivial | — (channel-independent) |
| **Correlation donor scoring** | `GradientDonorSelection.correlationRankedDonors` | `C · E · 2S · W` | every (epoch, candidate) pair |
| Template build | corrector | `C · E · D · W` | every (epoch, sample) |
| Energy + projection | corrector | `C · E · W` | every (epoch, sample), reduce |
| Scale resolution | `resolveScales` | `E · window` | leave on CPU |
| Residual + artifact accumulation | corrector | `C · E · W` | every output sample (see "Gather") |
| **OBS Gram matrix** | `GradientOBS.basis` | `C · chunks · n² · W` | every (i, j) pair |
| OBS eigen-decomposition | `LinearAlgebra` | `C · chunks · n³`, `n ≤ 256` | leave on CPU |
| OBS basis + projection | `GradientOBS` | `C · E · K · W` | every (epoch, sample) |
| Coverage normalise + decimate | corrector | `C · N · L` | every sample |
| ANC high-pass | `GradientFilters` | `C · N` | across channels only |
| ANC NLMS | `GradientANC.apply` | `C · N · taps` | across channels only |

On a 64-channel, 10-minute, 1 kHz recording with 30 slices per 2 s TR
(`E ≈ 9000`, `W ≈ 67`, `L = 2`), correlation donor scoring is around 1.9e10
operations and the OBS Gram around 2.8e9 — an order of magnitude above everything
else. That is where the work is.

## Design Principles

### 1. The CPU owns every decision; the GPU owns only arithmetic

This is the most important rule in the document, and the one that makes CPU/GPU
parity testable at all.

The pipeline makes several **discrete** choices, and a one-ULP difference in a
float can flip any of them into a completely different output:

- which epochs are selected as donors, and in what rank order
- how many OBS components are removed (`.automatic` compares a running variance
  ratio against a threshold)
- whether a fitted template scale is rejected as implausible
- whether an OBS chunk is skipped for falling under the residual energy floor
- whether ANC runs at all

Keep every one of those on the CPU, decided from values that are either computed
on the CPU or deterministically rounded before comparison. Let the GPU produce
the dense intermediates that feed them. The result is a backend whose *decisions*
match the CPU bit-for-bit, and whose *numbers* differ only within a bounded
tolerance. Anything else is untestable.

Concretely for correlation ranking: compute the correlation matrix on the GPU,
copy it back, then quantise (round to ~1e-6) before sorting on the CPU with the
existing tie-break — score descending, then distance from target, then epoch
index. Without the quantisation step, near-ties reorder between backends and
donor sets diverge.

### 2. Batch across channels

The CPU implementation loops channels serially — one `for channelIndex in
channels.indices` around the entire per-channel pipeline. Channels are completely
independent right up until the diagnostics are collected.

That loop is the single largest structural win available. Every stage becomes
`(channel × epoch × sample)`-parallel instead of `(epoch × sample)`-parallel,
which is the difference between under-occupying the GPU and saturating it. Design
the buffers channel-major from the start rather than porting the serial loop
kernel by kernel and batching later.

It is also what makes ANC worth moving at all: NLMS is inherently sequential
*within* a channel, since each sample's weight update depends on the previous
one, but `C` independent sequential streams run perfectly well in parallel.

### 3. Gather, don't scatter

The CPU accumulates the artifact estimate with `artifact[start + index] +=` and a
parallel `coverage[start + index] += 1`, then divides where coverage exceeds one.
The obvious GPU translation is atomic float adds. Don't.

Atomics on float are slow, and — because the summation order becomes
nondeterministic — they break run-to-run reproducibility, which
`repeatedRunsProduceIdenticalOutput` and `obsAndAncTogetherStayFiniteAndDeterministic`
both assert.

Invert it instead. Epoch windows are `W = period + 1` samples long and start
roughly `period` apart, so with alignment shifts bounded by
`GradientEpochAligner.defaultSearchRadius` (5% of the period) **at most two or
three epochs can cover any given sample**. Precompute, on the CPU, a small
fixed-width table mapping each output sample to the epochs covering it, then run
one thread per output sample that gathers from those epochs in index order. No
atomics, deterministic order, and it fuses the coverage division for free.

### 4. Metal is float32; the CPU implementation is not

Metal Shading Language has no `double`. The CPU code accumulates templates,
energies, projections, Gram entries, and correlations in `Double` throughout, and
`GradientCorrectionConfig.templateScaleRange`, the OBS variance threshold, and the
ANC variance floors are all `Double` comparisons.

Exact parity is therefore impossible and should not be a goal. What matters:

- **Bulk sums** (templates, artifact accumulation, dot products) are fine in
  float32 with compensated (Kahan) summation. A dot product over a few thousand
  terms lands around 1e-6 relative error, which propagates to well under
  0.01 µV of output — negligible against a 100 µV artifact.
- **The Gram matrix is not fine.** Eigenvalue ratios drive a discrete component
  count, and a float32 Gram can shift them enough to change `K`. Compute the Gram
  entries on the GPU if you like, but accumulate in compensated float32, return
  them as `Double`, and keep `LinearAlgebra.symmetricEigenDecomposition` on the
  CPU. It is an `n ≤ 256` decomposition — it is not the bottleneck.
- **Never compare a float32 value against a `Double` threshold** without an
  explicit, documented rounding step. That is rule 1 restated.

## Proposed Seam

Add a backend selector to the config, mirroring the shape the app already expects
(`GradientViewModel` passes an equivalent for the old corrector):

```swift
nonisolated enum GradientComputeBackend: String, CaseIterable, Sendable {
    case cpu
    case metal
}

// in GradientCorrectionConfig
var computeBackend: GradientComputeBackend = .cpu
```

Keep `.cpu` as the default until parity is demonstrated, and expose an
availability check (`GradientTemplateCorrector.isMetalAvailable`) so the caller
can fall back silently on machines without a usable device.

The public entry point must not change. `correct(channels:volumeTriggers:config:samplingRate:progress:)`
keeps its signature and its `GradientCorrectionResult`, including diagnostics. A
GPU run must populate `GradientCorrectionDiagnostics` identically — that is what
the parity tests assert against.

Prefer a seam at the level of *stages*, not one monolithic `correctOnGPU`. A
protocol with one method per accelerated stage lets you port incrementally, run
mixed CPU/GPU pipelines, and bisect a parity failure to a single stage. A
monolithic GPU path gives you one boolean and no way to find out which kernel is
wrong.

## Test Plan

The clean-room suites already do most of this work; the job is to run them twice.

1. **Parameterise the existing suites over the backend.** All 144 tests in
   `EVATests/Gradient/` should run against both backends. Swift Testing
   `@Test(arguments:)` over `GradientComputeBackend.allCases` is the cheapest
   route. Skip the Metal case when no device is available rather than failing.
2. **Assert decision parity exactly.** This is the high-value test the diagnostics
   were designed for. For the same input and config, CPU and GPU must agree
   *exactly* on:
   - `diagnostics.epochs[i].donorIndices`
   - `diagnostics.epochs[i].integerShift`
   - `diagnostics.obsComponentCounts`
   - `diagnostics.ancAppliedChannels`
   - `diagnostics.highMotionVolumes`
   - the set of warnings raised
   Any divergence here is a design bug, not a tolerance problem — it means a
   decision leaked onto the GPU.
3. **Assert numerical parity within tolerance.** Corrected samples should agree to
   a documented bound. Suggested starting point: RMS difference below 1e-3 µV and
   max absolute difference below 1e-2 µV on the synthetic recordings, tightened
   once real numbers are in hand. Express it as a fraction of the artifact
   amplitude, not an absolute, so the test does not silently weaken on
   larger-amplitude data.
4. **Assert GPU determinism.** Same input twice on the GPU must give bit-identical
   output. If this fails, something is using atomics or a nondeterministic
   reduction order.
5. **Cover the degenerate shapes on both backends.** Single channel, single
   epoch-worth of data, flat channels, channel counts that are not a multiple of
   the threadgroup size, `upsampleFactor = 1`, `numberOfSlices = 1`. Threadgroup
   tail handling is where GPU ports break.
6. **Keep a CPU-only reference test.** The CPU path stays the definition of
   correct. Do not "fix" a CPU/GPU disagreement by changing the CPU.

## Phasing

Each phase should land green before the next starts.

- **Phase 0 — seam and harness.** Add `computeBackend`, the availability check,
  and a `.metal` path that simply delegates to the CPU implementation.
  Parameterise the test suites. Everything passes trivially, and you now have the
  parity harness before any kernel exists.
- **Phase 1 — profile.** Run a real recording. Confirm where the time actually
  goes before committing to the ordering below; the table above is an estimate,
  not a measurement. Try `vDSP` on the top stage and see how much is left.
- **Phase 2 — correlation donor scoring.** The largest single cost, and a clean
  first kernel: a batched correlation with no discrete logic inside it. Ranking
  stays on the CPU per rule 1.
- **Phase 3 — upsampling and epoch extraction.** Simple, high-volume, and
  produces the channel-major buffers the later stages want.
- **Phase 4 — template build, dot products, artifact gather.** Includes the
  gather-table design from principle 3. After this the core subtraction path is
  on the GPU.
- **Phase 5 — OBS Gram and projection.** Eigen-decomposition stays on the CPU.
- **Phase 6 — ANC.** Batched across channels; sequential within one.
- **Phase 7 — retire the old files.** Delete `FastrCorrector.swift`,
  `FastrMetalBackend.swift`, `FastrKernels.metal`, and their tests. Wire the UI to
  `GradientTemplateCorrector`. Update `THIRD_PARTY_NOTICES.md`.

Phase 7 is the one that actually closes the track. Phases 2–6 are optimisation;
until the old files are gone, the provenance problem is unchanged.

## Gotchas

- **`GradientSincResampler.upsample` special-cases phase 0** to pass integer-grid
  samples through untouched, which is what makes `upsampleThenDecimateReturnsTheOriginalSamples`
  exact. Preserve that branch — without it the round trip stops being exact and
  `samplesOutsideCorrectedEpochsAreBitIdentical` fails.
- **`samplesOutsideCorrectedEpochsAreBitIdentical` asserts exact equality**, not
  approximate. The CPU implementation guarantees it by decimating the *artifact
  estimate* and subtracting, so uncovered samples are `input - 0`. Any GPU design
  that resamples the signal itself will fail this test, correctly.
- **`fractionalDelay` precomputes its taps once** because the delay is constant
  per call. Keep that; recomputing per sample is both slower and a source of
  drift.
- **The alignment reference channel is chosen by variance** in
  `representativeChannel`, with ties broken by lowest index. A parallel reduction
  that changes the summation order can change which channel wins on a near-tie,
  and every downstream shift with it. Compute it on the CPU, or reduce
  deterministically.
- **OBS eigenvector signs are arbitrary.** The CPU tests only assert on the
  *projection*, which is sign-invariant. Do not add a GPU test that compares basis
  vectors directly.
- **Progress reporting is currently per channel** (`progress(Double(channelIndex + 1) / Double(channels.count))`),
  and `progressReachesOne` asserts a monotonic sequence ending at exactly 1.0. A
  batched backend has no per-channel boundary, so report against a different
  granularity and update that test deliberately rather than letting it drift.
- **`try Task.checkCancellation()` runs once per channel.** A batched backend
  needs its own cancellation points, or long runs stop being interruptible.
- **Small recordings will be slower on the GPU.** Buffer setup and round-trip
  latency dominate below some size. Measure the crossover and fall back to the CPU
  automatically beneath it; do not make the user reason about it.

## What Is Still Outstanding

Phase 7 closed on 2026-08-09. For the record, it consisted of deleting the three
historical FASTR sources and their test suite, pointing `GradientViewModel` at
`GradientTemplateCorrector` (with parameter blocks from the previous correctors
detected and rejected rather than half-applied), adding the
`THIRD_PARTY_NOTICES.md` entry, and marking the track complete in `README.md`.

All of the above is DONE as of 2026-08-09. Two smaller follow-ups remain:

- ANC is now the largest single stage — about 0.65 s of the 1.47 s full-pipeline
  figure. Moving it needs the parity argument in "Deviation" below to be answered
  first, not skipped.
- The quantisation grid (`GradientTemplateCorrector.quantized`, 1e-6) makes donor
  ranking robust to backend rounding wherever competing scores are separated by
  more than the grid, which on real and synthetic recordings they are by two
  orders of magnitude. It cannot make a genuine near-tie deterministic across
  backends, and nothing can. The parity tests assert exact donor-set equality on
  recordings where scores are well separated; that is the honest scope of the
  guarantee.

## Definition of Done

- The GPU backend passes all clean-room suites, with decision parity exact and
  numerical parity within a documented tolerance.
- The GPU path is deterministic across repeated runs.
- `FastrCorrector.swift`, `FastrMetalBackend.swift`, and `FastrKernels.metal` are
  deleted, along with `EVATests/Gradient/FastrCorrectorTests.swift`.
- `GradientViewModel` calls `GradientTemplateCorrector`, and replay/session files
  from the old corrector either still load or are explicitly migrated.
- `THIRD_PARTY_NOTICES.md` carries the entry from the roadmap's template, naming
  the spec, the audit log, and the implementing commits.
- `README.md`'s FASTR-family track is marked complete.
