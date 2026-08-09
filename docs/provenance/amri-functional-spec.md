# AMRI-Style Template Methods Functional Specification

Dirty-room specification for a future clean-room implementation. Do not treat
this file as source code. It describes EVA's desired AMRI-style local template
methods without reproducing AMRI MATLAB source structure.

## Status

- Track: AMRI-style MAS/MAR/wAAS/wAAR
- Started: 2026-08-08
- Implementation status: clean-room implementation complete in
  `EVA/Gradient/LocalTemplateArtifactCorrector.swift`; app/UI wiring
  pending
- Dirty-room reviewer: Codex, with access to current EVA code and local
  reference trees
- Intended clean-room implementer: a separate LLM/session/person with no access
  to AMRI source or current EVA AMRI-style implementation source
- Clean-room test path:
  `EVATests/Gradient/LocalTemplateArtifactCorrectorTests.swift`
- Dirty-room compatibility test path:
  `EVATests/Gradient/LocalTemplateArtifactCompatibilityTests.swift`

## Purpose

Remove stereotyped but slowly changing artifacts by building a local template
from neighboring events or scanner volumes. EVA uses this family in two places:

- gradient artifact removal from volume/TR events.
- artifact cleaning for user-defined events such as BCG/ECG-like artifacts.

The implementation should support median local templates, exponentially
weighted local average templates, and optional least-squares amplitude scaling
before subtraction.

## Historical References

Use these as scientific and historical references, not as implementation source:

- Liu Z, de Zwart JA, van Gelderen P, Kuo L-W, Duyn JH. Statistical feature
  extraction for artifact removal from concurrent fMRI-EEG recordings.
  NeuroImage 59(3):2073-2087, 2012.
- Goldman RI, Stern JM, Engel J Jr, Cohen MS. Acquiring simultaneous EEG and
  functional MRI. Clinical Neurophysiology 111(11):1974-1980, 2000.
- Allen PJ, Josephs O, Turner R. A method for removing imaging artifact from
  continuous EEG recorded during functional MRI. NeuroImage 12(2):230-239,
  2000.

Historical/reference software to cite, but not inspect during clean
implementation:

- AMRI EEG-fMRI MATLAB toolbox. Local files carry GPL-3.0 headers while also
  identifying Advanced MRI / NINDS / NIH Government-work authorship. Treat that
  as a provenance item to verify separately.

## Non-Goals

- Do not reproduce the full AMRI MATLAB toolbox.
- Do not implement PCA, ICA, or Taylor-series AMRI methods in this spec.
- Do not copy AMRI option names or helper structure unless they are generic
  method names already used in the literature.
- Do not make the gradient and user-event implementations diverge without a
  documented reason.

## Inputs

For TR/gradient correction:

- `channels`: EEG data as channel-major arrays.
- `trSamples`: sorted or sortable volume trigger sample indices.
- `samplingRate`: samples per second.
- configuration:
  - event/epoch window length.
  - donor window before/after or centered donor count.
  - donor exclusion set.
  - minimum donor distance, if needed.
  - template reducer: mean, median, or weighted mean.
  - fit mode: subtract as-is or regress/scale before subtracting.

For user-defined artifact cleaning:

- `channels`: EEG data as channel-major arrays.
- artifact event list with center time and duration.
- correction window around each event.
- optional event exclusions.
- same donor/reducer/fit settings as above.

## Outputs

Return:

- cleaned channels with the same shape as input.
- optional artifact estimate with the same shape as input.
- per-event or per-TR summaries:
  - donor count.
  - skipped reason, if skipped.
  - template scale factor, if used.
  - method name.

All finite input should produce finite output.

## Event/Epoch Model

1. Convert event centers to sample windows.
2. Reject or skip events whose correction window is fully outside the recording.
3. Clip or pad edge windows according to a documented policy.
4. For gradient correction, infer epoch length from the median TR interval when
   no explicit length is supplied.
5. For user-defined artifacts, allow variable event duration when the event has
   a measured duration.

## Donor Selection

For each target event:

1. Start from neighboring events before and after the target.
2. Exclude the target itself unless a method explicitly requires self-inclusion.
3. Exclude events marked ignored, censored, stale, or otherwise ineligible.
4. Exclude donors too close to the target when a minimum distance is configured.
5. At recording boundaries, use a deterministic edge policy:
   - shrink the window, or
   - shift the window to keep donor count when possible.
6. If too few donors remain, either:
   - fall back to all eligible nearby donors, or
   - skip the target and report a warning.

The implementation must state the minimum donor count for each method.

## Template Reducers

### Average Artifact Subtraction

Build a sample-wise arithmetic mean of donor epochs. Subtract the template from
the target event.

### Median Artifact Subtraction

Build a sample-wise median of donor epochs. This is more robust to occasional
bad donor events than a mean. Subtract the template from the target event.

### Weighted Average Artifact Subtraction

Build a sample-wise weighted average of donor epochs. Weights should decrease as
temporal distance from the target increases. A clean-room implementation may use
exponential or other monotonic weighting if the choice is documented and tested.

Weights must be normalized so a constant donor signal produces the same constant
template.

## Regression / Scaling Variant

For MAR and wAAR-style variants, scale the local template before subtraction.

Recommended clean-room formula:

`alpha = dot(target, template) / dot(template, template)`

Then subtract `alpha * template`.

If template energy is near zero, use `alpha = 0` or skip with a warning.

The implementation should document whether the fit includes intercept removal,
demeaning, or baseline correction. Demeaning the target/template before fitting
is acceptable if tested and consistently applied.

## Baseline and Overlap Handling

For event cleaning, each event window may overlap another event window. The
implementation must choose and document one policy:

- process events independently and overlap-add corrections with weights.
- process in chronological order and prevent later events from double-removing
  already-corrected samples.
- reject overlapping events for local-template methods.

Overlap-add with a smooth taper is preferred for variable event windows because
it avoids hard edges in the cleaned signal.

## EVA Intentional Deviations and Improvements

- Use one shared conceptual implementation for gradient TRs and user-defined
  events where possible.
- Preserve reversible artifact estimates for UI inspection.
- Prefer robust medians when donor contamination is likely.
- Correct high-motion or censored target events if requested, but do not use
  them as donors.
- Keep method names familiar for users, while documenting that EVA's code is an
  independent implementation.

## Edge Cases

Tests must cover:

- too few events/triggers
- uneven TR spacing for gradient mode
- target window near recording start/end
- excluded donors
- all donors excluded
- donor events with variable durations
- overlapping event windows
- flat template
- single-channel and multi-channel recordings
- weighted template normalization
- regression scaling on known synthetic scale factors

## Acceptance Tests

The clean implementation should pass tests that demonstrate:

- output shape matches input shape.
- all output samples are finite for finite input.
- mean template subtraction removes a repeated synthetic artifact.
- median template subtraction resists one contaminated donor.
- weighted average templates favor nearby donors.
- regression/scaling recovers a known synthetic amplitude scale.
- excluded donors never affect the template.
- target events can be corrected even when excluded as donors.
- overlap policy is deterministic and documented.

As of 2026-08-08, the clean-room implementation has spec-derived tests for the
generic local-template API and a separate dirty-room compatibility harness. The
dirty-room compatibility harness treats the old EVA/AMRI-facing paths as
black-box behavioral oracles and must not be used as source material for a
clean-room implementation.

The focused dirty-room compatibility run passed with:

```sh
xcodebuild test -project EVA.xcodeproj -scheme EVA -destination 'platform=macOS' -derivedDataPath /Users/molfesepj/Documents/Programming/EVA/.codex-derived-data CODE_SIGNING_ALLOWED=NO EXCLUDED_SOURCE_FILE_NAMES='*.metal ICLabel.mlpackage' -only-testing:EVATests/LocalTemplateArtifactCompatibilityTests
```

Compatibility validation covered:

- gradient MAS-style correction.
- gradient MAR-style correction.
- user-event local MAS-style correction.
- weighted average subtraction behavior.
- weighted average regression/scaling behavior.

Intentional differences from old EVA/AMRI-facing behavior:

- The clean-room implementation excludes the target event as its own donor.
  This avoids self-donation even where an old AMRI-global weighted path could
  include the target event.
- The clean-room implementation uses the conventional least-squares template
  coefficient `dot(target, template) / dot(template, template)` for scaling.
  Historical compatible behavior may use a different coefficient direction.
- Local MAS compatibility is close on synthetic data but not bit-identical;
  small numerical differences are acceptable when the spec-derived behavior is
  preserved.

## Future THIRD_PARTY_NOTICES Entry

After replacement and validation, update `THIRD_PARTY_NOTICES.md` along these
lines:

> EVA's AMRI-style MAS/MAR/wAAS/wAAR methods were produced through a documented
> dirty-room / clean-room process. The AMRI toolbox is cited as a historical and
> scientific reference; its source code is not incorporated. The implementation
> is based on published artifact-template methods, EVA's functional
> specification, and independently written tests.
