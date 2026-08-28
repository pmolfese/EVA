# FASTR-Family Functional Specification

Dirty-room specification for a future clean-room implementation. Do not treat
this file as source code. It intentionally describes behavior, math, inputs,
outputs, and validation goals without reproducing toolbox implementation
structure.

## Status

- Track: FASTR-family gradient correction
- Started: 2026-08-08
- Dirty-room reviewer: Codex, with access to current EVA code and local
  reference trees
- Intended clean-room implementer: a separate LLM/session/person with no access
  to FMRIB, FACET, BERGEN, or current EVA FASTR implementation source

## Purpose

Remove periodic MRI gradient artifact from EEG recorded during fMRI acquisition.
The method family should support:

- baseline FASTR: slice/volume artifact template subtraction with optional OBS
  residual removal and ANC
- Moosmann / RP-informed averaging: choose template donors using fMRI motion
  information
- FARM-style donor selection: choose template donors by waveform similarity
- BERGEN-style squared-correlation donor ranking as an optional donor mode

## Historical References

Use these as scientific and historical references, not as implementation source:

- Niazy RK, Beckmann CF, Iannetti GD, Brady JM, Smith SM. Removal of FMRI
  environment artifacts from EEG data using optimal basis sets. NeuroImage
  28(3):720-737, 2005.
- Moosmann M, Schoenfelder VH, Specht K, Scheeringa R, Nordby H, Hugdahl K.
  Realignment parameter-informed artefact correction for simultaneous EEG-fMRI
  recordings. NeuroImage 45(4):1144-1150, 2009.
- van der Meer JN et al. Robust EMG-fMRI artifact reduction for motion (FARM).
  Clinical Neurophysiology 121(5):766-776, 2010.
- Glaser J, Beisteiner R, Bauer H, Fischmeister FPS. FACET: a flexible artifact
  correction and evaluation toolbox for concurrently recorded EEG/fMRI data.
  BMC Neuroscience 14:138, 2013.

Historical toolboxes to cite, but not inspect during clean implementation:

- FMRIB FASTR: GPL-2.0-or-later
- FACET: GPL-2.0-or-later
- BERGEN EEG-fMRI Toolbox: local source has Bergen copyright, no explicit local
  license found

## Non-Goals

- Do not reproduce an old MATLAB toolbox user interface.
- Do not emulate random behavior unless explicitly requested by an option.
- Do not require slice triggers in the file; EVA may synthesize slice epochs by
  subdividing volume intervals when the number of slices is known.
- Do not implement arbitrary BERGEN weighting-matrix editing in EVA Core for the
  first clean implementation.

## Inputs

The implementation receives:

- `channels`: EEG data as channel-major arrays, all same sample count.
- `volumeTriggers`: sample indices for regularly spaced scanner volume/TR
  markers.
- `samplingRate`: samples per second before any internal upsampling.
- `config`:
  - `upsampleFactor`: integer >= 1.
  - `numberOfSlices`: integer >= 1. A value of 1 means volume-level epochs.
  - `relativeTriggerPosition`: fraction in [0, 1] locating the trigger within
    an artifact epoch.
  - `averagingWindowBefore` and `averagingWindowAfter`, or a symmetric window
    fallback.
  - `templateScheme`: temporal neighbors, motion-informed, or
    correlation-ranked.
  - optional motion parameters with translations and rotations.
  - optional censored/high-motion volumes that must be corrected but must not be
    used as template donors.
  - OBS mode: off, automatic component count, or fixed component count.
  - ANC enabled/disabled and ANC high-pass mode.

## Outputs

Return corrected EEG with the same shape, sample count, and channel order as the
input. All finite input samples should produce finite output samples unless the
input contains non-finite values outside the method's documented support.

The implementation should also be structured so EVA can later expose diagnostic
outputs, even if the first implementation returns only corrected data:

- estimated artifact template per epoch
- residual removed by OBS
- residual removed by ANC
- donor indices per epoch
- alignment shifts per epoch
- warning list for fallbacks and rejected options

## Epoch Model

1. Sort volume triggers.
2. Reject input with fewer than two volume triggers.
3. If `numberOfSlices > 1`, divide each volume interval into equal slice
   intervals and create synthetic slice-epoch triggers. Do not create triggers
   beyond the data length.
4. Upsample internally by `upsampleFactor`.
5. Compute the median interval between adjacent epoch triggers on the upsampled
   axis. Use this interval as the nominal artifact period.
6. Define each artifact epoch as a fixed-length window around its trigger:
   - samples before trigger: `round(period * relativeTriggerPosition)`
   - samples after trigger: `round(period * (1 - relativeTriggerPosition))`
   - total length includes the trigger sample

## Alignment

The implementation should support two alignment stages:

- Initial epoch alignment: move each epoch trigger by a small integer shift that
  improves similarity to a reference artifact shape.
- Optional fractional-sample alignment: apply a sub-sample phase shift to reduce
  residual timing mismatch after integer alignment.

Clean-room implementation guidance:

- The first valid artifact epoch may be used as a reference, or a robust
  reference may be built from early valid epochs.
- Search only within a small bounded neighborhood around each trigger.
- The similarity measure should be correlation or squared error after removing
  a local mean.
- Fractional alignment may use interpolation or frequency-domain phase shifting,
  but the chosen method must be documented and tested on synthetic shifted
  sinusoids/artifacts.
- Alignment should be computed once from a representative channel or reference
  trace, then applied consistently across channels to preserve cross-channel
  timing.

## Template Subtraction

For each channel and each valid target epoch:

1. Select donor epochs using the configured donor strategy.
2. Exclude censored donors and donors whose artifact window falls outside the
   recording.
3. Build an artifact template by averaging the donor epoch waveforms sample by
   sample.
4. If no donors remain, use a documented fallback:
   - nearest valid temporal donors, or
   - skip correction for that epoch with a warning.
5. Scale the template amplitude to the target epoch before subtracting:
   - fit the scale by least-squares projection of target onto template,
     `alpha = dot(target, template) / dot(template, template)`.
   - how much of that fit is applied is governed by "Template Scale Safety"
     below. Applying it raw per epoch is available but is not the default.
   - if the template has near-zero energy, use alpha = 0 or skip subtraction.
6. Subtract `alpha * template` from the target epoch.

Output outside corrected epochs should remain identical to the input unless a
later processing stage explicitly modifies it.

## Donor Strategies

### Temporal Neighbor Donors

For each target epoch, choose nearby epochs before and after the target. Use
the configured window sizes. The target epoch itself should normally be excluded
from a simple temporal-neighbor template unless a compatibility option
explicitly includes it.

At boundaries, prefer a documented edge policy:

- clamp/saturate the donor window to valid epochs, or
- use fewer donors near edges.

The policy must be deterministic and covered by tests.

### Motion-Informed Donors

Purpose: avoid averaging across head-motion events and avoid using high-motion
volumes as donors.

Inputs:

- one motion vector per volume, usually translations and rotations from an fMRI
  realignment tool
- threshold in millimeters
- optional rotation radius to convert rotations into displacement-like units
- target donor count

Behavior:

1. If no motion is supplied, return no motion-informed donors and let the caller
   fall back to temporal neighbors.
2. If motion has fewer rows than volumes because dummy scans were dropped,
   front-pad with zero-motion rows so rows align to volume indices.
3. Compute a per-volume motion magnitude. EVA supports:
   - translation-only displacement
   - all-parameter displacement with rotations scaled by a configurable radius
4. Mark volumes whose motion magnitude exceeds the threshold as high-motion.
5. High-motion volumes are corrected but excluded as donors.
6. For each target volume, select low-motion donor volumes near the target while
   avoiding donors across high-motion barriers when possible.
7. If there is no supra-threshold motion, the motion-informed strategy may
   return nil so the caller can use the normal temporal strategy.

Slice-level correction should map selected donor volumes to the corresponding
slice/epoch positions.

### Correlation-Ranked Donors

Purpose: choose artifacts whose waveform shape is most similar to the target,
rather than closest in time.

Behavior:

1. Prepare candidate epochs from the same slice position when slice-level
   correction is active.
2. Optionally restrict candidates using motion-informed donor pools.
3. Compute Pearson correlation between target and candidate artifact waveforms.
4. Rank candidates by correlation or squared correlation according to the
   selected option.
5. FARM-style mode should prefer candidates above a configurable correlation
   threshold and fall back to temporal donors if too few candidates qualify.
6. BERGEN-style squared-correlation mode may include the target epoch as a
   candidate if the option explicitly says so.

The implementation must document whether the target epoch is eligible as its
own donor for each mode.

## OBS Residual Removal

OBS is an optional post-template-subtraction stage.

Behavior:

1. Compute the residual: original upsampled artifact epoch minus the scaled
   template estimate.
2. High-pass the residual before PCA basis estimation.
3. Build a PCA basis from residual epochs within the current OBS chunk.
4. Remove a fixed number of components, or automatically choose a count from
   variance-explained criteria.
5. Apply OBS only to epochs/channels that are not excluded from this stage.
6. Support chunked OBS so long recordings do not assume one stationary residual
   basis across the whole scan.

Clean-room details are intentionally open:

- PCA may be implemented by SVD or eigen-decomposition.
- Automatic component selection must be deterministic and tested.
- The maximum number of PCA epochs should be capped for memory/performance, with
  deterministic subsampling.

## Adaptive Noise Cancellation

ANC is optional and runs after template subtraction and optional OBS.

Behavior:

1. Treat the removed artifact/noise estimate as the reference signal.
2. High-pass the signal before adaptive filtering.
3. Support at least two high-pass policies:
   - fixed 2 Hz
   - slice-rate-derived cutoff for slice-level correction
4. Use a stable adaptive filter such as normalized LMS or bounded-step LMS.
5. If the reference has near-zero variance, skip ANC and return the current
   cleaned signal.

The implementation must prioritize stability and finite output over exact
compatibility with historical toolboxes.

## EVA Safety Constraints

Added 2026-08-08 after the clean-room implementation pass. These are EVA-specific
safeguards, not descriptions of historical behavior.

A dirty-room review of the reference toolboxes confirmed that they implement
template scaling, automatic OBS component selection, and LMS-based ANC, and that
they guard those stages against *numerical* failure — NaN, negative or outlier
scale factors, adaptive filters that blow up. What the review did not find, in
either the papers or the reference code, is any guard against these three stages
removing legitimate physiological signal. The clean-room acceptance tests
surfaced all three failure modes, so EVA specifies its own constraints here.

Each of these must be configurable and covered by tests.

### Template Scale Safety

The problem: the template scale is fitted from a single epoch-length window, and
over a window that short a physiological rhythm is not orthogonal to the
artifact. A 7 Hz rhythm against a 10 Hz artifact fundamental over 101 samples
correlates at roughly 0.57, and that share of the signal is absorbed into the
fitted scale and subtracted along with the artifact.

Two further observations narrow what scaling is actually for:

- A *sustained* amplitude change needs no scaling. Once the donor window has
  moved past the transition, the donors already carry the new amplitude.
- The genuine benefit is at recording edges and across transitions, where the
  donor window is one-sided and the template is systematically biased. This is
  the same rationale the reference toolboxes give.

Requirements:

1. Offer at least: unscaled subtraction, a raw per-epoch fit, and a smoothed fit.
2. Default to the smoothed fit. It must reject epoch-to-epoch scatter while
   passing a sustained change through sharply — a running median over
   neighbouring epochs satisfies both.
3. Reject a fitted scale that is non-finite, non-positive, or outside a
   configurable plausible range, and fall back rather than applying it.
4. Document that a single-epoch amplitude spike is rejected by the smoothed mode
   by design, and that the raw per-epoch fit is the mode for tracking one.

### OBS Residual Floor

The problem: variance-explained component selection is scale-free. It removes
whatever dominates the residual, and PCA cannot distinguish structured brain
signal from structured artifact. Where template subtraction has already explained
the artifact, the residual *is* the signal — and automatic OBS removed
essentially all of it in testing.

Requirement: before estimating a basis for a chunk, compare the residual energy
against the energy template subtraction already removed. If the residual carries
less than a configurable fraction of it (default 1%), skip OBS for that chunk and
record a warning. The stage must ask whether the residual is still
artifact-dominated before asking how many components describe it.

### ANC Over-Adaptation

The problem: a short adaptive filter driven by a periodic reference cannot
synthesize an unrelated frequency with fixed weights, but weights that adapt at
every sample can, because the weight trajectory itself carries the beat. At a
step size of 0.05 the filter removed roughly two-thirds of an uncorrelated 7 Hz
signal.

Requirements:

1. Default to a conservative step size, favouring slow tracking of artifact drift
   over fast convergence. Document the relationship and cover it with a test that
   sweeps the step.
2. Guard the reference on *relative* as well as absolute variance. A reference
   that is numerically non-zero but negligible next to the signal makes normalized
   LMS divide by an almost-zero energy, and the filter ends up fitting and
   subtracting the brain signal. Skip ANC when the reference carries less than a
   configurable fraction of the signal's variance.

## EVA Intentional Deviations and Improvements

- Deterministic behavior is preferred over random sampling.
- GPU acceleration is optional and must not change numerical behavior beyond a
  documented tolerance.
- Motion-loaded but non-Moosmann FASTR may use high-motion volumes as censoring
  information: correct those volumes, but do not use them as template donors.
- A clean implementation may simplify old compatibility options if EVA preserves
  the user-facing scientific intent.
- Diagnostics should be designed from the start, even if not all are exposed in
  the first UI.

## Edge Cases

Tests must cover:

- too few triggers
- uneven or invalid trigger spacing
- one slice versus multiple synthetic slices
- target epochs near recording start/end
- censored/high-motion volumes
- missing or shorter motion files
- no supra-threshold motion
- flat or near-flat artifact templates
- single-channel and multi-channel recordings
- OBS off/auto/fixed
- ANC with zero-variance reference
- deterministic repeated runs

## Acceptance Tests

The clean implementation should pass tests that demonstrate:

- output shape matches input shape
- all output samples are finite for finite synthetic input
- temporal-neighbor FASTR substantially reduces variance in synthetic periodic
  gradient artifacts
- non-TR-locked physiological signal is largely preserved when OBS and ANC are
  disabled
- censored epochs are corrected but not used as donors
- motion-informed mode avoids high-motion donors and falls back gracefully
- FARM-style mode selects high-correlation donors and falls back gracefully
- BERGEN-style squared-correlation mode ranks by squared correlation and states
  whether self-donation is allowed
- OBS reduces residual artifact without exploding low-rank or short recordings
- ANC is skipped or bounded when the reference signal is unsuitable

## Future THIRD_PARTY_NOTICES Entry

After replacement and validation, update `THIRD_PARTY_NOTICES.md` along these
lines:

> EVA's FASTR-family implementation was produced through a documented
> dirty-room / clean-room process. FMRIB FASTR, FACET, and BERGEN are cited as
> historical and scientific references; their source code is not incorporated.
> The implementation is based on the cited papers, EVA's functional
> specification, and independently written tests.
