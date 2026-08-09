# FASTR-Family Clean-Room Audit Log

Internal record of the clean-room implementation pass. This is not a legal
opinion. Companion to `docs/provenance/fastr-functional-spec.md` and
`README.md`.

## Session: 2026-08-08

- Role: clean-room implementer
- Implementer: Claude (Sonnet 5), via Claude Code
- Authorizing decisions made by P. Molfese at the start of the session:
  - Spec-derived tests govern acceptance; the pre-existing dirty-room test file
    is advisory/black-box only.
  - Scope for this pass: CPU core — epoch model, alignment, donor selection,
    template subtraction. OBS and ANC were added to the same pass on request.
  - The new code lands as a standalone type with no app wiring.

### Materials Inspected

Permitted and used:

- `docs/provenance/fastr-functional-spec.md` (the governing spec)
- `docs/provenance/copyleft-plan.md`
- `README.md`
- `EVA/Gradient/MotionParameters.swift` — EVA-owned motion parsing and
  framewise-displacement definition; reused directly. Not a port of any
  reference toolbox.
- `EVA/Gradient/GradientViewModel.swift` lines 355-465 — read to learn the
  public call contract only (function signature, config field names, progress
  and cancellation idiom). No algorithm bodies are present in this file.
- `EVA.xcodeproj/project.pbxproj` — build settings only.
- `EVATests/SyntheticSignal.swift` — EVA-owned test helpers.
- `EVATests/Gradient/FastrCorrectorTests.swift` — **names of test functions
  only** (via grep), read before the scope decision, to categorize the existing
  suite. No test bodies were read. See "Deliberate Exclusions" below.

### Deliberate Exclusions

Not opened at any point during this session:

- `EVA/Gradient/FastrCorrector.swift`
- `EVA/Gradient/FastrMetalBackend.swift`
- `EVA/Gradient/FastrKernels.metal`
- `resources/fmrib/`
- `resources/facet/`
- `resources/BERGEN/`

The Metal files are not named in the roadmap's exclusion list, but they are GPU
implementations of the same ported algorithm and were treated as tainted for the
purposes of this pass.

### Separation Breach — Disclosed

After the implementation and all tests were written and on disk, the clean-room
implementer opened the assistant memory file `fmri-motion-fastr.md` to correct a
stale status line. That file turned out to contain dirty-room notes describing
FMRIB/FACET/BERGEN internals in structural detail — auto-component threshold
names, the ANC step-size formula, alignment control flow, and explicit
"line-for-line equal" comparisons between toolboxes. Under
`README.md`'s separation rules this is material a clean-room
implementer must not inspect.

Assessment:

- No code or test in `EVA/Gradient/` or `EVATests/Gradient/`
  was written or modified after that file was read. The implementation is
  unaffected.
- The file has since been marked with a do-not-read header pointing at the
  clean-room spec instead.
- **Any future clean-room work on this track should be done by a session that has
  not read `fmri-motion-fastr.md`.** This session should be treated as tainted
  for further FASTR clean-room implementation.

### Note on the Existing Test Suite

The pre-existing `FastrCorrectorTests.swift` contains three kinds of test. Only
the first kind is compatible with a clean-room acceptance gate:

1. Spec-derived behavioral tests (shape, finiteness, variance reduction,
   determinism, censoring, graceful fallback, signal preservation).
2. Metal-vs-CPU backend parity tests, which test a backend this pass does not
   provide.
3. White-box compatibility tests that assert the reference toolbox's exact
   internal selection behavior — donor-row saturation, slice donor parity,
   OBS epoch pick sequence. Gating the clean implementation on these would
   reintroduce, through the test suite, the precise behavior the clean-room
   process is meant to avoid deriving.

Accordingly the new implementation ships with its own test file written from the
spec's "Edge Cases" and "Acceptance Tests" sections.

### Deviations and Judgment Calls

Recorded because the spec leaves these open, or because the clean implementation
intentionally differs:

1. **Template scaling.** Spec §Template Subtraction step 5 fits the scale by
   least-squares projection. After dirty-room review (see "Dirty-Room Review"
   below) the spec gained a "Template Scale Safety" section, and the default is
   now a median-smoothed fit (`.driftTracking`) rather than the raw per-epoch
   value. Raw per-epoch fitting and unscaled subtraction both remain available.
   Fitted scales are also rejected when non-finite, non-positive, or outside a
   plausible range.
2. **Artifact-domain subtraction.** Rather than upsampling the signal, correcting
   it, and downsampling the result, the implementation upsamples, estimates the
   artifact, decimates the *artifact estimate*, and subtracts it from the
   original samples. This makes "samples outside corrected epochs are bit-identical
   to the input" exactly true for any upsample factor, rather than true only to
   within resampling error.
3. **Resampling kernel.** Windowed-sinc (Lanczos) interpolation, `a = 4` for
   integer upsampling and `a = 8` for fractional delay, with clamped edge
   extension. Chosen over FFT phase shifting because it needs no transform setup
   and is directly testable on synthetic shifted sinusoids, as the spec requires.
   The kernel is exactly 1 at zero offset and exactly 0 at every other integer,
   so integer-grid samples survive the round trip unchanged.
4. **Motion magnitude is framewise, not absolute.** Spec §Motion-Informed step 3
   says "displacement" without specifying. EVA already defines a per-volume
   motion magnitude in mm — `MotionParameters.framewiseDisplacement`, Power et
   al. 2012, rotations converted to arc length on a configurable radius — and the
   spec's stated purpose (avoid averaging *across motion events*, treat
   high-motion volumes as barriers) describes transitions rather than absolute
   position. The implementation reuses EVA's existing definition.
   `translationOnly` uses the translation terms of the same framewise sum.
5. **Temporal donor edge policy.** Of the two policies the spec permits, this
   implementation uses saturation: donors are the nearest eligible epochs in time,
   expanding outward until the requested count is met, preferring the earlier
   epoch when two candidates are equidistant. At the recording boundaries this
   draws more donors from the available side rather than returning fewer.
6. **Overlapping epochs.** With the spec's window definition, adjacent epochs
   share exactly one boundary sample. The artifact estimate is accumulated with a
   per-sample coverage count and averaged where coverage exceeds one, instead of
   letting a later epoch overwrite an earlier one.
7. **Bounded correlation search.** Spec §Correlation-Ranked does not bound the
   candidate pool, which would be O(epochs²) — untenable at, say, 300 volumes ×
   30 slices. Candidates are restricted to a configurable window of same-slice
   epochs on each side of the target (`correlationSearchWindow`, default 240).
8. **Alignment reference.** Two passes: pass one aligns against the first
   in-bounds epoch, then the reference is rebuilt as the mean of the aligned
   early epochs and every epoch is realigned. Sub-sample offset comes from
   parabolic interpolation of the correlation peak.
9. **Representative channel.** Alignment is estimated once, on the highest-variance
   non-excluded channel (ties broken by lowest index), and the resulting shifts
   are applied to every channel, per spec §Alignment.
10. **OBS uses the Gram matrix, not the sample covariance.** A chunk holds far
    fewer epochs than an epoch holds samples, and the two matrices have the same
    non-zero spectrum, so the epoch-by-epoch Gram matrix is decomposed instead.
    Residuals are not mean-centered across epochs: the average leftover shape is
    itself artifact, and leaving it in lets the first component capture it.
    Eigen-decomposition reuses EVA's own LAPACK-backed
    `LinearAlgebra.symmetricEigenDecomposition`.
11. **OBS high-passes by linear detrending, not by an IIR filter.** The spec calls
    for a high-pass before basis estimation, but an artifact epoch is one artifact
    period long — there is nothing for a filter with a cutoff below the artifact
    rate to act on. Removing offset and slope accomplishes what the high-pass is
    there for. ANC, which filters whole channels, uses a zero-phase Butterworth.
12. **OBS will not run on a chunk whose residual is negligible.** Not in the spec;
    added after testing. See "Findings" below.
13. **ANC's default step size is 0.01, not a faster-converging value.** See
    "Findings" below.

### Dirty-Room Review of the Three Findings

P. Molfese reviewed the findings below against the reference implementations and
papers, and reported back. No reference source was shown to the clean-room
implementer — only these behavioral conclusions, which is the permitted channel
under `README.md`'s separation rules.

Summary of what the review established:

- **Template scaling.** The reference toolboxes do compute a scale factor, and
  cite the same two reasons EVA found: artifact amplitude changes over time, and
  edge templates are biased. They also sanity-check the factor for NaN, negative,
  and outlier values. Neither the papers nor the code address the short-window
  signal-absorption failure mode.
- **Automatic OBS.** The papers support temporal PCA for capturing residual
  artifact variability, and the reference code implements automatic component
  selection from variance/eigenvalue criteria. No equivalent of EVA's residual
  energy floor was found. The existing approach asks how many components describe
  the residual without first asking whether the residual is still
  artifact-dominated.
- **ANC.** Step size is central to the reference implementation, which derives it
  from a constant, the filter order, and the reference variance, and which warns
  on numerical failure. No guard against adapting into unrelated physiology was
  found.

Conclusion recorded by the reviewer: the literature and reference code support
the *existence* of scaling, OBS, and ANC, but do not solve these three safety
questions. They are therefore documented as EVA-specific safeguards in the
functional spec's new "EVA Safety Constraints" section.

Changes made in response:

1. The scale-factor sanity guards (reject non-finite, non-positive, out-of-range)
   were added after the review reported that the reference toolboxes perform an
   equivalent check. Implemented from that behavioral description; no source was
   consulted.
2. `.driftTracking` was added and made the default, implementing the reviewer's
   "make least-squares conditional on clear artifact-amplitude drift."
3. `obsResidualEnergyFloor` was promoted from an undocumented implementation
   detail into the spec.

One further result came out of testing the new default, and it narrows what
template scaling is for: **a sustained amplitude change needs no scaling at all.**
Once the donor window has moved past the transition, the donors carry the new
amplitude and the template is already correct. The measurable benefit of scaling
is confined to recording edges and transition regions, where the donor window is
one-sided — which is the same edge-bias rationale the reference toolboxes give.
Both behaviors are now covered by tests.

### Findings Worth Carrying Forward

Three of these came out of writing the spec's acceptance tests and finding they
failed for reasons that were not implementation bugs. They are recorded because
they affect what EVA should ship as defaults, and they are captured as tests.

1. **Raw per-epoch template scaling costs signal.** The scale is estimated from a
   single epoch-length window, and over a window that short a physiological
   rhythm is not orthogonal to the artifact — a 7 Hz rhythm against a 10 Hz
   artifact fundamental over 101 samples correlates at roughly 0.57, and that
   share of the signal is absorbed into the scale and subtracted away. In the
   synthetic test this drops the correlation with the clean signal from 0.99
   (unscaled) to 0.77 (raw per-epoch fit). **Resolved** by defaulting to
   `.driftTracking`, which medians the fit across neighbouring epochs: it
   recovers most of the preserved signal (correlation above 0.95) while keeping
   the edge-bias correction that scaling exists for. All three modes are tested.
2. **Automatic OBS will remove brain signal when there is no artifact left.**
   Variance-explained component selection is scale-free: it removes whatever
   dominates the residual, and PCA cannot tell structured signal from structured
   artifact. Where template subtraction has already explained the artifact, the
   residual *is* the signal, and OBS deleted essentially all of it in testing.
   `obsResidualEnergyFloor` (default 1%) makes the stage stand down when the
   residual carries too little energy relative to what was already removed. Now
   documented in the spec's "EVA Safety Constraints" section.
3. **ANC's step size governs how much uncorrelated signal it eats.** A 32-tap
   filter driven by a periodic reference cannot synthesize an unrelated frequency
   with fixed weights, but weights that chase every sample can, because the weight
   trajectory itself carries the beat. At step 0.05 the filter removed roughly
   two-thirds of an uncorrelated 7 Hz signal. The default is 0.01, and the
   relationship is covered by a test that sweeps the step.
4. **ANC needs a relative variance floor, not just an absolute one.** A reference
   that is numerically non-zero but negligible makes normalized LMS divide by an
   almost-zero energy; the weights grow without bound and the filter fits and
   subtracts the brain signal. The guard now also requires the reference to carry
   at least 1e-4 of the signal's variance.
5. **Alignment can rescue an edge epoch that would otherwise be dropped.** The
   search only considers shifts that keep the window inside the recording, so an
   epoch whose nominal window runs one sample past the end is corrected at a
   shift of -1 rather than skipped. Reasonable, but worth knowing when reading
   diagnostics.

### Status

- Implementation: `EVA/Gradient/` — 8 files.
  - `GradientTemplateCorrector.swift` — orchestration and public entry point
  - `GradientCorrectionTypes.swift` — config, errors, warnings, diagnostics
  - `GradientEpochLayout.swift` — trigger/epoch geometry
  - `GradientSincResampler.swift` — Lanczos upsampling and fractional delay
  - `GradientEpochAligner.swift` — integer and sub-sample alignment
  - `GradientDonorSelection.swift` — the four donor strategies
  - `GradientOBS.swift` — chunking, PCA basis, projection
  - `GradientANC.swift` — NLMS adaptive cancellation
  - `GradientFilters.swift` — zero-phase Butterworth high-pass, detrending
- Tests: `EVATests/Gradient/` — 8 suites written from the spec.
- Full EVATests target passes (696 cases), including the pre-existing
  `FastrCorrectorTests`, which was not modified.
- App wiring: none. `FastrCorrector` remains the only path reachable from the UI.
- Remaining before this track can close: a clean GPU backend to replace
  `FastrMetalBackend.swift` / `FastrKernels.metal`, a decision on which
  implementation the UI calls, and the `THIRD_PARTY_NOTICES.md` update.

### Dirty-Room Follow-Up: FASTR Metal Backend

Reviewed after the clean CPU pass. This review was for provenance triage only;
it does not make these files available as clean-room implementation material.

- `FastrMetalBackend.swift` is explicitly wired to `FastrCorrector`'s ported
  pipeline. It accelerates interpolation, shared donor-row template noise,
  OBS fitting, FIR filtering, and final decimation while leaving alignment,
  donor selection, OBS preparation, and ANC decisions in `FastrCorrector`.
- `FastrKernels.metal` contains GPU kernels for those dense numeric stages. The
  kernels are generic in expression, but their buffers and dispatch shapes are
  designed around the current ported FASTR data flow.
- `EVATests/Gradient/FastrCorrectorTests.swift` contains Metal-vs-CPU parity
  tests for this backend. Those tests are useful while the old path exists, but
  they should not gate a clean replacement because they preserve exact behavior
  of the tainted implementation.

Conclusion: replace or retire the FASTR Metal backend when wiring the clean
FASTR implementation into the app. A new GPU backend is allowed, but it should
be implemented from `docs/provenance/fastr-functional-spec.md`, the clean
CPU implementation in `EVA/Gradient/`, and newly written
spec-derived backend tests.

## Dirty-Room Behavioral Validation: 2026-08-08

- Role: dirty-room validator.
- Validation artifact:
  `EVATests/Gradient/FastrDirtyRoomValidationTests.swift`. It is
  explicitly labelled for deletion with the old FASTR implementation and must
  not become a compatibility contract for the clean-room code.
- No file under `EVA/Gradient/` was modified during validation.
- Focused run passed:

  ```sh
  xcodebuild test -project EVA.xcodeproj -scheme EVA \
    -destination 'platform=macOS' -parallel-testing-enabled NO \
    -derivedDataPath .codex-derived-data \
    -only-testing:EVATests/FastrDirtyRoomValidationTests
  ```

### Fixtures and scoring

The fixtures reuse the clean-room acceptance suite's `gradientWave`,
`physiology`, and `makeRecording` construction: 36 volumes at 1,000 Hz, a
100-sample volume period, and known physiological ground truth. The six cases
are plain periodic artifact, linear per-volume amplitude drift, one 3x-amplitude
epoch, ±2-sample repeating timing jitter, four 25-sample slice epochs per
volume, and two channels with different physiology and artifact phase/scale.

Metrics are computed over the common fully corrected range, volumes 16...35.
This exclusion is substantive: at relative trigger position 0.03 the first
epoch starts before sample zero, and the old volume-level path rejects a whole
template whenever that invalid epoch is its first donor. Consequently volumes
1...15 on that path are not covered by template subtraction. Including them
produced an apparent 52–65% disagreement that was untouched edge data, not an
interior algorithm comparison.

- Residual is RMS(corrected - truth); lower is better.
- `r` is Pearson correlation(corrected, truth); higher is better.
- Amplitude is RMS(corrected) / RMS(truth); closer to 1 is better.
- The final column names the closer implementation in residual / `r` /
  amplitude order. The magnitude is the difference between the adjacent raw
  values (for amplitude, compare absolute distance from 1).

| Configuration | Synthetic case | Clean residual | Old residual | Clean r | Old r | Clean amplitude | Old amplitude | Closer to truth: residual / r / amplitude |
|---|---|---:|---:|---:|---:|---:|---:|---|
| A template only | Plain periodic | 3.3080 | 3.1601 | 0.6487 | 0.6879 | 0.8173 | 0.8545 | old / old / old |
| A template only | Amplitude drift | 3.7691 | 3.6361 | 0.5785 | 0.6196 | 0.9296 | 0.9632 | old / old / old |
| A template only | Single-epoch spike | 5.1215 | 4.9065 | 0.4432 | 0.4932 | 1.2516 | 1.2552 | old / old / clean |
| A template only | Jittered timing | 9.0697 | 19.9236 | 0.2623 | 0.1228 | 2.1690 | 4.7128 | clean / clean / clean |
| A template only | Slice level | 1.0783 | 1.0697 | 0.9683 | 0.9696 | 1.0160 | 1.0300 | old / old / clean |
| A template only | Multi-channel | 2.9491 | 2.8783 | 0.6681 | 0.6933 | 1.0068 | 1.0351 | old / old / clean |
| B automatic OBS | Plain periodic | 3.3080 | 3.1705 | 0.6487 | 0.6870 | 0.8173 | 0.8607 | old / old / old |
| B automatic OBS | Amplitude drift | 3.7691 | 3.6843 | 0.5785 | 0.6146 | 0.9296 | 0.9770 | old / old / old |
| B automatic OBS | Single-epoch spike | 5.1215 | 3.6756 | 0.4432 | 0.6189 | 1.2516 | 0.9841 | old / old / old |
| B automatic OBS | Jittered timing | 6.8271 | 19.3217 | 0.3372 | 0.1273 | 1.6408 | 4.5721 | clean / clean / clean |
| B automatic OBS | Slice level | 1.0783 | 1.0633 | 0.9684 | 0.9705 | 1.0160 | 1.0390 | old / old / clean |
| B automatic OBS | Multi-channel | 2.9491 | 2.9682 | 0.6681 | 0.6809 | 1.0068 | 1.0552 | clean / old / clean |
| B ANC | Plain periodic | 3.4706 | 4.4790 | 0.6140 | 0.1589 | 0.8275 | 0.5325 | clean / clean / clean |
| B ANC | Amplitude drift | 4.0074 | 4.7057 | 0.5378 | 0.1500 | 0.9626 | 0.6523 | clean / clean / clean |
| B ANC | Single-epoch spike | 5.3917 | 5.6469 | 0.4221 | 0.1463 | 1.3127 | 1.0367 | clean / clean / old |
| B ANC | Jittered timing | 9.1313 | 16.3196 | 0.2545 | 0.0317 | 2.1762 | 3.7461 | clean / clean / clean |
| B ANC | Slice level | 1.1026 | 0.9818 | 0.9673 | 0.9777 | 1.0236 | 1.0749 | old / old / clean |
| B ANC | Multi-channel | 3.1363 | 3.8337 | 0.6324 | 0.2565 | 1.0268 | 0.6987 | clean / clean / clean |
| C defaults | Plain periodic | 0.3811 | 3.3826 | 0.9963 | 0.6366 | 1.0182 | 0.8382 | clean / clean / clean |
| C defaults | Amplitude drift | 3.3781 | 3.9045 | 0.7701 | 0.5647 | 1.2464 | 0.9713 | clean / clean / old |
| C defaults | Single-epoch spike | 47.5441 | 3.8407 | -0.1098 | 0.5721 | 11.0523 | 0.9552 | old / old / old |
| C defaults | Jittered timing | 3.8128 | 9.6483 | 0.7539 | 0.2427 | 1.3666 | 2.2995 | clean / clean / clean |
| C defaults | Slice level | 0.4093 | 0.9993 | 0.9981 | 0.9740 | 1.0729 | 1.0383 | clean / clean / old |
| C defaults | Multi-channel | 0.3504 | 3.1599 | 0.9960 | 0.6389 | 1.0294 | 1.0574 | clean / clean / clean |

### Configuration matching

Configuration A matched CPU execution, 10x upsampling, one or four slices,
relative trigger position 0.03, temporal-neighbour templates, no motion or
censoring, no OBS, no ANC, fractional alignment, and raw per-epoch
least-squares scaling. The old ±15 inclusive window contains 31 epochs including
the target. The clean selector was therefore allowed self-donation and asked for
31 donors (directional counts 15 + 16) so the interior donor set matched.

The old corrector's `alignToAverageArtifact` default is `true`. It performs an
additional template-specific alignment pass for which the clean corrector has
no corresponding option, so it was disabled in A and B; both sides still ran
their shared integer and fractional alignment pipelines with a 30-upsampled-
sample search radius. Leaving the old-only pass enabled did not explain the
volume-edge behavior above and would have compared different alignment stages.

Configuration B added automatic OBS, then ANC in separate runs. Clean OBS kept
its default 1% residual-energy floor; old automatic OBS has no equivalent. Clean
ANC used its conservative default NLMS step 0.01; the old path derives a plain-
LMS step from filter order and reference variance and exposes no matching step
control. Configuration C used each implementation's defaults, changing only the
fixture's slice count and forcing CPU execution.

Objective geometry agreed in every run: 36 epochs and a 100-sample period for
volume cases; 144 epochs and a 25-sample period for the slice case. Clean
diagnostic triggers and periods are stored on the upsampled axis and matched the
same sample-grid positions after division by the configured factor. No output
was non-finite, and both implementations reduced artifact RMS in all 24 cases.

### Known intentional differences captured during validation

- In five of six A fixtures the old/clean output RMS difference was only
  0.20–1.34% of input artifact RMS, supporting close interior agreement. The
  clean raw-fit result nevertheless had `r` lower by 0.0013–0.0500 in those
  cases; this is small in output scale but is not claimed as an improvement.
- A timing jitter was the exception: output disagreement was 15.76% of artifact
  RMS. The clean result was substantially closer to truth on every metric
  (residual 9.07 versus 19.92), so this is a Configuration A divergence red flag,
  but not evidence that the clean result should be changed toward the old one.
- The plain, drift, spike, slice, and multi-channel clean B-OBS metrics exactly
  equal A, consistent with the residual floor standing down. OBS did run on
  timing jitter, improving clean residual from 9.07 to 6.83. Old OBS improved the spike
  from 4.91 to 3.68 because it has no floor; on this constructed artifact outlier
  that behavior is closer to truth, while the clean floor preserves the stated
  safeguard against PCA consuming low-energy structured physiology.
- Clean ANC was closer on residual and correlation in five of six fixtures and
  preserved amplitude better in five. The slice-level exception favored old
  residual by 0.121 (12.3%) and `r` by 0.0104; clean amplitude was closer to 1.
- Defaults strongly favored clean for plain, drift, jitter, slice, and
  multi-channel residual/correlation. This is consistent with the intended
  drift tracking, OBS floor, and conservative ANC behavior.
- The single-epoch spike is the material exception. Clean drift tracking rejects
  it as non-persistent scatter by design, leaving residual 47.54 versus 3.84 for
  old defaults (12.4x), correlation -0.110 versus 0.572, and amplitude 11.05
  versus 0.955. The direction is explained by the specified scaling trade-off,
  but the magnitude is a red flag: users needing isolated artifact-amplitude
  jumps must select raw least-squares scaling. This finding must not be used to
  alter the clean implementation to mimic the tainted one.

### Conclusion

The clean implementation is finite, variance-reducing, geometrically consistent,
and very close to the historical template-only path on five representative
fixtures. It is materially better against truth on jitter and on five of six
default cases. Validation also confirms two cases where the clean safeguards
trade artifact removal for signal-protection policy: OBS stands down on a
single-epoch outlier, and default drift tracking leaves that outlier largely
uncorrected. The latter is large enough to require explicit product/UI guidance
for raw least-squares mode, but it is the behavior required by the current spec,
not evidence of an implementation defect.

## Clean-Room Review: Isolated Amplitude Jump Policy

- Date: 2026-08-08
- Role: clean-room reviewer
- Scope: the functional specification, the clean implementation under
  `EVA/Gradient/`, and spec-derived clean tests only.
- Excluded: the historical implementation and backend, historical tests,
  dirty-room validation code, and reference toolbox source trees.

### Determination

Classification: **A, with qualification**. The severe default result for a
single isolated amplitude jump is the intended and unavoidable consequence of
the *currently specified drift-tracking policy*. It is not an unavoidable
limitation of template correction in general.

The specification requires the default smoothed fit to reject epoch-to-epoch
scatter and explicitly says that a single-epoch amplitude spike is rejected by
design. It directs users who need to follow such a jump to raw per-epoch
least-squares scaling. The clean implementation conforms: the default resolves
each epoch's fitted scale through a running median, while the raw mode applies
the independently fitted, range-checked scale. The clean tests exercise all
three scaling modes, rejection of an isolated fitted-scale outlier, passage of
a sustained step, and raw fitting of a single-epoch jump.

Therefore this is neither a missing requirement under the present specification
(B) nor an implementation defect relative to it (C). No implementation change
was made. Historical agreement was not used as an acceptance criterion.

The behavior is nevertheless a product risk. A finite, globally
variance-reducing result can still be unusable around one large untracked epoch;
whole-recording stability metrics alone do not adequately protect against that
local failure.

### Proposed Specification Change

Retain the current meanings of `driftTracking` and raw least-squares scaling.
Add a detection requirement before considering any automatic hybrid behavior:

1. Compare each valid raw fitted scale with the local robust drift estimate.
2. When the difference exceeds configurable absolute and relative thresholds,
   record an isolated-scale-jump diagnostic containing the epoch, raw fit,
   drift estimate, and whether the raw fit passed the existing plausibility
   range.
3. Surface a user-facing warning that drift tracking intentionally did not
   follow the event and recommend reviewing or rerunning with raw least-squares
   scaling when isolated scanner-amplitude jumps are expected.
4. Keep detection observational: it must not silently replace the applied
   drift-tracking scale.

As a separate, opt-in specification extension, evaluate a guarded hybrid mode.
It may use the raw scale for an isolated epoch only when independent evidence
indicates template-shaped residual artifact, such as a large reduction in
residual projection energy plus coherent scale excursions across multiple
non-excluded channels. Its thresholds, single-channel fallback, slice-position
grouping, diagnostic output, and failure behavior must be specified before
implementation. It should not become the default until synthetic tests show
that it improves isolated-jump correction without recreating the known
physiological-signal absorption of unconditional raw fitting.

### Proposed Spec-Derived Acceptance Tests

- On a single 3x artifact-amplitude epoch, default drift tracking applies a
  scale near the local robust estimate, emits exactly one isolated-jump
  diagnostic, remains finite, and identifies the correct epoch.
- On the same fixture, raw least-squares scaling applies a scale near 3 and
  materially lowers truth-referenced residual RMS versus drift tracking. Assert
  an absolute truth-based bound as well as a relative improvement; the current
  test's `raw residual < drift residual` condition is too weak.
- On a plain periodic artifact plus non-TR-locked physiology, the detector does
  not fire spuriously and drift tracking retains its signal-preservation bound.
- A sustained amplitude step is followed by drift tracking and is not labelled
  as an isolated jump after the configured transition allowance.
- A coherent multi-channel isolated artifact jump is detected across channels;
  a large excursion confined to one channel is diagnosed separately and is not
  automatically rescued by any guarded hybrid mode.
- Slice-level tests compare only corresponding slice positions when estimating
  persistence or coherence, and identify the correct volume and slice.
- Threshold-boundary, rejected-scale, flat-template, recording-edge, and
  deterministic CPU/backend-parity cases remain finite and make identical
  discrete detection decisions.
- If a guarded hybrid mode is adopted, it must approach raw fitting's
  truth-referenced residual on the isolated-jump fixture while preserving the
  drift mode's correlation and amplitude bounds on fixtures with physiological
  rhythms but no artifact jump.

### User-Facing Guidance

- **Drift-Tracking (recommended default):** use for stable artifacts, gradual
  drift, and sustained amplitude changes. It prioritizes physiological-signal
  preservation and deliberately ignores a one-epoch scale excursion.
- **Per-Epoch Least Squares:** use when the recording is known or suspected to
  contain isolated scanner-amplitude jumps. It follows each epoch immediately,
  but can subtract physiological activity that happens to correlate with the
  artifact template inside that short epoch.
- Review isolated-jump warnings and corrected traces. If warnings coincide with
  genuine scanner events, rerun with raw scaling and compare local residuals and
  signal preservation. If the excursions look channel-local or physiological,
  retain drift tracking and investigate those epochs separately.

### Verification Note

A focused clean test run was attempted with historical test and dirty-room
validation files excluded. The first build could not compile Metal sources
because the optional Metal toolchain is unavailable. A CPU-only retry then
stopped on an unrelated, pre-existing placeholder token in
`MRIGradientArtifactViews.swift`. No test executed, and no unrelated source was
modified. The conformance determination above is based on direct review of the
governing requirements, clean scale-resolution path, and spec-derived test
assertions.

## 2026-08-09 — Dirty-room validation passed; historical implementation deleted

`FastrDirtyRoomValidationTests.compareHistoricalAndCleanRoomFASTRAgainstSyntheticTruth()`
passed. The clean-room FASTR-family implementation is behaviorally adequate
against the historical implementation across the tested synthetic scenarios:
template-only, automatic OBS, ANC, defaults, volume-level, slice-level, jittered
timing, amplitude drift, transient spike, and multi-channel.

Scope of that run, recorded so the claim is not read wider than it is:

- Synthetic recordings only. No real-recording comparison was made.
- The run excluded `*.metal` and `ICLabel.mlpackage` so the CPU comparison would
  build without unrelated Metal/CoreML noise. **It therefore validates nothing
  about Metal compilation or CPU/GPU parity.**

CPU/GPU parity is covered separately and independently by
`EVATests/Gradient/GradientBackendParityTests.swift` (17 cases, all
passing as of 2026-08-09), which compiles the kernels and asserts:

- exact agreement on every discrete decision — donor sets, integer shifts, OBS
  component counts, ANC-applied channels, high-motion volumes, the set of
  warnings, and per-epoch corrected flags;
- numerical agreement within RMS < 1e-5 and max < 1e-4 of artifact amplitude;
- bit-identical output across repeated GPU runs;
- bit-identical passthrough for samples no epoch covers.

Each parity case asserts `diagnostics.computeBackend == .metal`, so a silent
fallback to the CPU fails the test rather than passing vacuously.

Known limits of the combined evidence:

- Both validations use synthetic recordings.
- Parity covers the FASTR family only. `GradientAAS` and
  `LocalTemplateArtifactCorrector` have no GPU path.
- Donor ranking is made robust across backends by rounding scores onto a 1e-6
  grid before sorting. Competing scores on these recordings differ by two orders
  of magnitude more than that, but a genuine near-tie within the grid could still
  resolve differently, and no amount of rounding prevents that.

Following the validation, the historical implementation
(`EVA/Gradient/FastrCorrector.swift`, `FastrMetalBackend.swift`,
`FastrKernels.metal`) and `EVATests/Gradient/FastrCorrectorTests.swift` were
deleted, along with the one-shot dirty-room comparison artifact that referenced
them. They remain recoverable from git history. `GradientRemover` was
deliberately kept: it is NIH Government work, not a provenance liability, and it
is now unreferenced pending a separate cleanup decision.

This closes the FASTR-family clean-room track.
