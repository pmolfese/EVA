# Dirty vs Clean Gradient Comparison

Internal dirty-room audit note. This is not legal advice and is not clean-room
implementation guidance.

This file records a high-level comparison between EVA's older gradient-related
implementation paths under `EVA/Gradient/` and the clean-room implementations
under `EVA/Gradient/`. It intentionally describes missing features and
behavioral deltas at the requirement level rather than reproducing source-code
structure.

## Summary

The clean-room gradient implementation is broadly complete for the current
FASTR-family and AMRI/local-template specifications. The remaining differences
are mostly intentionally omitted compatibility knobs, post-processing
conveniences, or product-integration choices rather than evidence that the
clean-room implementation is incomplete.

FASTR-family and AMRI/local-template remediation can be treated as clean-room
adequate, with the caveats below.

## What the Clean-Room Implementation Covers

### AAS Family

- EVA-local AAS-style correction exists in `GradientAAS`.
- Allen/IAR-style volume and slice modes exist.
- Local detrending exists for EVA-local AAS.
- Section-based templates are supported.
- Correlation gating is supported.
- Initial always-include epochs are supported.
- Optional sinc upsampling is supported.
- Optional ANC is supported.

### FASTR Family

- Temporal-neighbor FASTR-style correction.
- FARM-like correlation-ranked donors.
- Moosmann/motion-informed donors.
- BERGEN-style squared-correlation donor ranking.
- Synthetic slice epochs.
- Integer and fractional alignment.
- OBS off/automatic/fixed modes.
- ANC.
- Motion censoring.
- CPU and Metal clean-room backends.
- Backend parity tests.
- Diagnostics and warnings.
- EVA safety additions:
  - smoothed/drift-tracking template scaling.
  - OBS residual-energy floor.
  - conservative ANC defaults and guards.

### AMRI / Local Template Family

- MAS/MAR-style local median templates.
- wAAS/wAAR-style exponentially weighted templates.
- Gradient/TR entry point.
- User-event entry point.
- Variable event-duration windows.
- Donor exclusions.
- Minimum donor count policy.
- Artifact estimate output.
- Overlap-add/taper behavior.
- Dirty-room compatibility tests pass.

## Potentially Missing or Intentionally Not Preserved

### 1. Old FASTR Optional Low-Pass Output Filter

Older `FastrCorrector` exposed a `lowPassHz` option. I do not see an equivalent
option in `GradientCorrectionConfig`.

Assessment: not a clean-room blocker. This is a post-correction filtering
convenience rather than core FASTR behavior. EVA already has filtering elsewhere.
If users relied on "FASTR plus low-pass in one button," this is a product/UI
migration question.

Recommendation: do not add this to core clean-room FASTR unless the UI needs a
single-stage convenience. Prefer the normal EVA filter stage.

### 2. Old FASTR Random OBS Epoch Selection

Older FASTR exposed random OBS epoch selection.

Assessment: intentionally not preserved. The clean-room spec prefers
deterministic behavior and says not to emulate random behavior unless explicitly
requested.

Recommendation: no action.

### 3. Exact FACET Averaging-Window Matrix Semantics

Older FASTR exposed a FACET-style averaging-window compatibility mode.

Assessment: the clean-room implementation preserves the scientific intent
through temporal windows, slice handling, correlation ranking, and diagnostics,
but should not be described as exact FACET window-matrix compatibility.

Recommendation: no core action. If exact FACET compatibility matters, treat it
as a separate plugin/preset requirement rather than part of EVA Core.

### 4. Excluded-Channel Semantics Changed

Older FASTR used an excluded-channel concept where channels could still receive
template subtraction while skipping OBS/ANC or using fixed template scaling.

Clean-room `excludedChannels` are documented as passed through untouched.

Assessment: this is a real behavior change, but likely a cleaner one. If EVA
needs "apply template subtraction but skip OBS/ANC," that should be a separate
clean-room option rather than hidden under `excludedChannels`.

Recommendation: consider adding a separate `obsExcludedChannels` /
`ancExcludedChannels` or "template-only channels" UI/API concept if needed.

### 5. Old `GradientRemover` Weighted-Mean Side-Window AAS Is Not the Same as `LocalTemplateArtifactCorrector`

The clean-room `LocalTemplateArtifactCorrector` is the replacement home for the
AMRI-style MAS/MAR/local-template family. It should not be described as replacing
every behavior of old `GradientRemover`.

The simpler detrended AAS-style volume-template path belongs with
`GradientAAS.evaLocal`.

Assessment: not a blocker, but documentation should be precise.

Recommendation: describe `GradientAAS.evaLocal` as the clean-room replacement
for the older practical AAS/volume-template behavior, and
`LocalTemplateArtifactCorrector` as the clean-room replacement for AMRI-style
local-template MAS/MAR/wAAS/wAAR behavior.

### 6. Old AMRI-Style Correlation-Outlier Rejection Is Not a First-Class Local-Template Option

Older AMRI-style gradient behavior filtered low-correlation donor TRs in some
paths. The clean-room local-template implementation has donor eligibility,
explicit exclusions, minimum distance, and minimum donor count, but not an
automatic correlation-outlier rejection mode for local templates.

Assessment: compatibility tests passed for representative MAS/MAR behaviors.
This does not appear required by the current spec.

Recommendation: no action unless EVA wants an explicit "auto donor outlier
rejection" option. If added, specify it cleanly from first principles and test it
independently.

### 7. Broader Artifact-Cleaner AMRI Options Are Not Fully Represented in Gradient Cleanroom

This is technically outside `EVA/Gradient`, but it matters because the
AMRI/local-template spec mentions user-defined events.

Older artifact-cleaner AMRI-style paths include additional user-facing options:

- BCG/R-marker preprocessing or alignment.
- Preserving local baseline.
- AMRI-global wAAS self-donation behavior.
- Explicit edge-taper setting.

The clean-room `LocalTemplateArtifactCorrector` supports user-event windows,
weighted templates, overlap taper, donor exclusions, and artifact estimates, but
not all exact old artifact-cleaner compatibility modes.

Assessment: if the scope is only `EVA/Gradient`, this is not a blocker. If the
scope is full AMRI-style artifact-cleaner replacement, the spec should either
explicitly exclude these behaviors or add clean-room-safe requirements for them.

Recommendation: decide separately whether artifact-cleaner AMRI paths are in
scope. If yes, add a clean-room artifact-cleaner integration/spec addendum.

## Does the Clean-Room Implementation Meet the Spec?

Yes, for the current FASTR-family spec and AMRI/local-template spec, with one
scope nuance:

- The AMRI/local-template implementation supports both gradient/TR events and
  user-defined events at the API level.
- The app wiring currently appears focused on gradient MAS/MAR usage.
- User-defined artifact-cleaner integration is a separate product step if that
  remains in scope.

## Was the Spec Missing Things from the Original Code?

Yes. The omissions are mostly compatibility choices rather than core scientific
requirements:

- Old FASTR low-pass option.
- Exact FACET averaging-window compatibility.
- Random OBS epoch sampling.
- Older excluded-channel semantics.
- Local-template automatic correlation-outlier rejection.
- Broader artifact-cleaner AMRI options, especially BCG preprocessing and local
  baseline preservation, if artifact-cleaner replacement is considered in scope.

## Recommended Disposition

Do not reopen the clean-room implementation as incomplete.

Instead:

1. Add a "legacy behavior not carried forward" note to clean-room/provenance
   docs where useful.
2. Treat omitted exact-compatibility behavior as optional future plugins or
   explicitly named presets.
3. Keep low-pass filtering in EVA's normal filter stage unless a product need
   says otherwise.
4. Consider a separate clean-room requirement for "template subtraction but skip
   OBS/ANC" if excluded-channel semantics matter.
5. Decide whether broader artifact-cleaner AMRI options are in scope. If yes,
   write a focused addendum before implementation.

