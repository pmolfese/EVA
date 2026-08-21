# EVA Provenance: Copyleft Risk, Ports, and Clean-Room Reimplementation

Internal planning document. This is not a legal opinion and is not intended as
user-facing license text.

## Goal

Replace or re-ground license-sensitive method implementations with documented
independent implementations. EVA should cite the relevant scientific papers and
historical toolboxes while avoiding copied, translated, or structurally mirrored
source code from GPL or unclear-license reference implementations.

## Where Everything Lives

Final placement as of 2026-08-09, after the FASTR-family and AMRI-style tracks
completed and the historical engines were deleted.

### Documentation — `docs/provenance/`

| File | What it is |
| --- | --- |
| `README.md` | This document: process, separation rules, per-track status. |
| `copyleft-plan.md` | The provenance/risk ledger: which components are copyleft-sensitive, which tracks are closed, which are open. |
| `empirical-bayes-port.md` | The EbayesShrink port record — written from the paper and the GPL upstream's documented behavior, R-validated. |
| `fastr-functional-spec.md` | The FASTR-family specification the clean implementation was written from. |
| `fastr-audit-log.md` | What happened and why, including the 2026-08-09 validation and its limits. |
| `fastr-gpu-port-plan.md` | The GPU port plan, with the measured profile and the parity argument. |
| `amri-functional-spec.md` | The AMRI-style local-template specification. |
| `simulation-forward-model.md` | Derivation record for `Tools/EVASimulate`, the ground-truth simulation harness the correction methods are measured against. |
| `dirty-vs-clean-comparison.md` | Dirty-room audit note comparing the old and new implementations. Validation material, not implementation guidance. |

`docs/dirty-room/` holds dirty-room notes that quote reference-toolbox internals.
It is blocked by `.claude/hooks/block-dirty-room.sh` and must not be read during
clean-room work.

### Code — `EVA/Gradient/`

The clean-room implementations were developed in `EVA/Gradient/Cleanroom/` to keep
them visibly separate from the ported code they were replacing. That separation
stopped meaning anything once the ported code was deleted — every engine in the
directory is now clean-room — so the subdirectory was flattened away on
2026-08-09. The same happened to `EVATests/Gradient/Cleanroom/`.

Three engines, chosen by `MRIGradientMethod.engine`:

| Engine | Methods | GPU |
| --- | --- | --- |
| `GradientAAS` | Allen AAS (and the retired Fast AAS) | no — already at parity with the engine it replaced |
| `LocalTemplateArtifactCorrector` | MAS, MAR, wAAS, wAAR | yes, `LocalTemplateMetalBackend` |
| `GradientTemplateCorrector` | FASTR Original, Moosmann, FARM | yes, `GradientMetalBackend` |

Both GPU backends follow the same rule: the CPU settles every discrete choice
before a backend sees anything, so the two paths agree *exactly* on decisions and
only within a documented tolerance on numbers. Each has a parity suite asserting
both, plus bit-identical repeat runs. Each falls back to the CPU on its own —
`GradientMetalBackend` below a workload floor, `LocalTemplateMetalBackend` past
the donor count its kernels reduce in registers. Backend choice is a preference,
not a per-run control.

Metal: `GradientCleanroomKernels.metal`, `LocalTemplateKernels.metal`.

Shared support: `GradientEpochLayout`, `GradientEpochAligner`,
`GradientDonorSelection`, `GradientSincResampler`, `GradientOBS`,
`GradientFilters`, `GradientANC`, `GradientCorrectionTypes`,
`GradientAcceleration` (the FASTR backend seam).

Product layer, not clean-room: `GradientViewModel`, `MRIGradientArtifactViews`,
`MotionConfigView`, `MotionParameters`, `TRSpacing`.

### Retired

`GradientAAS.Preset.evaLocal` — "Fast AAS" — was withdrawn from the method picker
on 2026-08-09. It earned its place by being the quick option, and that
distinction went away: the local-template and FASTR engines are both GPU-backed,
and MAS now corrects a 64-channel ten-minute recording in about a tenth of a
second, faster than Fast AAS ever was.

Allen AAS is the shipped default in its place — the same family, done closer to
the published description. MAS is the nearer match if what is wanted is
specifically a local-neighbour template.

The code stays. `MRIGradientMethod.aas` still resolves, still routes, and still
runs, so a file that selects it reproduces; it is simply not offered for new
work, and the sheet says so when a loaded file has it selected. Retiring a method
from the picker and deleting its implementation are different decisions, and only
the first has been made.

### Deleted

Removed once their clean-room replacements were validated and wired:

- `FastrCorrector.swift`, `FastrMetalBackend.swift`, `FastrKernels.metal` and
  `FastrCorrectorTests.swift` — the FASTR port derived from GPL reference
  toolboxes. Deleted 2026-08-09.
- `GradientRemover.swift`, `GradientRemoverMetalBackend.swift`,
  `GradientRemoverKernels.metal` and `GradientRemoverTests.swift` — NIH
  Government work, never a provenance liability, deleted 2026-08-09 only because
  nothing called it any more.
- The one-shot dirty-room comparison artifacts, deleted with the implementations
  they validated against. A comparison outlives its oracle only as a recorded
  result, never as a test.

All of it remains recoverable from git history.

## Working Model

EVA will use a dirty-room / clean-room process:

1. A dirty-room reviewer may inspect EVA's current implementation, local
   reference source trees, papers, tests, UI behavior, and historical notes.
2. The dirty-room reviewer writes a functional specification in plain language,
   formulas, input/output contracts, edge cases, and validation criteria.
3. A clean-room implementer receives only the specification, public papers,
   public documentation, and approved test fixtures. They do not inspect the
   protected or unclear-license source code, and they do not inspect EVA files
   marked as tainted or potentially tainted for that method.
4. The clean-room implementer produces new code and tests from the specification.
5. A reviewer compares behavior against the specification, synthetic tests,
   paper-derived expectations, and black-box outputs where permitted.
6. Once accepted, EVA updates source headers and `THIRD_PARTY_NOTICES.md` to
   record the clean-room provenance.

This process reduces copyright-provenance risk. It does not replace legal
review, and it does not grant rights to distribute third-party assets or models.

## Separation Rules

- Clean-room implementers must not receive local reference trees under
  `resources/` for the method being reimplemented.
- Clean-room implementers must not receive current EVA source files that are
  described as ports, reimaginings, or compatibility implementations of those
  reference tools.
- Dirty-room specifications must not include copied code, copied comments,
  variable names used only by the reference implementation, line-by-line control
  flow, or helper decomposition that exists only because a reference toolbox was
  structured that way.
- Specifications may include formulas, scientific citations, public method
  names, file-format contracts, UI requirements, error cases, numerical
  tolerances, and independently written tests.
- Black-box comparison is allowed when the reference tool's license permits
  running it and when no source code is exposed to the clean implementer.

## Documentation Pattern

Each clean-room effort should have:

- `docs/provenance/<method>-functional-spec.md`
- optional `docs/provenance/<method>-validation-plan.md`
- optional `docs/provenance/<method>-audit-log.md`

Each functional spec should include:

- scope and non-goals
- allowed inputs and outputs
- cited papers and historical toolboxes
- clean-room implementer constraints
- algorithmic behavior described from first principles
- EVA-specific intentional deviations or improvements
- edge cases
- validation requirements
- notes to add to `THIRD_PARTY_NOTICES.md` after replacement

## Priority Order

1. FASTR-family gradient correction — **complete (2026-08-09)**
2. AMRI-style MAS/MAR/wAAS/wAAR — **complete (2026-08-09)**
3. Any plugin-packaged compatibility method that remains useful but should not
   live in EVA Core

## FASTR-Family Track

Status: started on 2026-08-08.

Dirty-room reviewer may inspect:

- `EVA/Gradient/FastrCorrector.swift`
- `EVA/Gradient/MRIGradientArtifactViews.swift`
- `EVATests/Gradient/FastrCorrectorTests.swift`
- local FMRIB, FACET, and BERGEN reference trees
- papers by Niazy et al. 2005, Moosmann et al. 2009, van der Meer et al. 2010,
  and Glaser et al. 2013

Clean-room implementer must not inspect:

- `EVA/Gradient/FastrCorrector.swift`
- `resources/fmrib/`
- `resources/facet/`
- `resources/BERGEN/`
- any dirty-room notes that quote or structurally reproduce those files

Deliverables:

- [fastr-functional-spec.md](fastr-functional-spec.md)
- [fastr-audit-log.md](fastr-audit-log.md)
- [fastr-gpu-port-plan.md](fastr-gpu-port-plan.md)

Status as of 2026-08-08: the CPU implementation is complete in
`EVA/Gradient/` with 144 spec-derived tests in
`EVATests/Gradient/`. A clean Metal backend is complete alongside it —
`GradientAcceleration.swift`, `GradientMetalBackend.swift` and
`GradientCleanroomKernels.metal`, ported from EVA's own clean-room CPU code — with
the end-to-end suites parameterised over both backends and a dedicated parity
suite asserting exact agreement on every discrete decision. Neither is yet wired
to the app.

UI wiring completed 2026-08-08. `GradientViewModel` routes every method to one
of the three clean-room engines — `GradientAAS` (Fast AAS, Allen AAS),
`LocalTemplateArtifactCorrector` (MAS, MAR, wAAS, wAAR),
`GradientTemplateCorrector` (FASTR, Moosmann, FARM). The sheet presents them as
Template / FASTR families with a per-family method dropdown, exposes the full
configuration surface behind an Advanced disclosure including the three EVA
safety constraints, and reports what each run excluded and why into the exported
`log_eva_<date>_<time>.txt`. Defaults for the family, the per-family method, and
the FASTR compute backend live in Preferences.

**Status: COMPLETE as of 2026-08-09.** Dirty-room behavioral validation passed,
after which `FastrCorrector.swift`, `FastrMetalBackend.swift`,
`FastrKernels.metal`, their tests, and the one-shot comparison artifact were all
deleted. `THIRD_PARTY_NOTICES.md` carries the clean-room entry. See the audit
log's 2026-08-09 section for the scope and the known limits of that evidence —
in particular that both the dirty-room comparison and the CPU/GPU parity suite
use synthetic recordings, and that parity covers the FASTR family only.

`GradientRemover` was deliberately kept: it is NIH Government work, not a
provenance liability. It is now unreferenced, pending a separate cleanup decision.

**The GPU port is a port of EVA's own clean-room code, so its separation rules
differ from the rules below.** The implementer must read
`EVA/Gradient/`; what stays off-limits is the old Metal backend, the
old corrector, and the reference trees. Start it in a session that has not read
the dirty-room notes in the `fmri-motion-fastr` assistant memory.

Implementation strategy:

1. Build a new implementation behind the existing user-facing FASTR controls.
2. Keep the public API shape compatible enough that existing replay/session
   files continue to work.
3. Add new tests from the clean-room spec before swapping behavior into the app.
4. Compare the new output with the current EVA implementation on synthetic
   recordings for broad sanity, while accepting intentional differences where
   the spec says EVA should improve behavior.
5. Replace the old implementation only after the clean implementation passes
   the spec tests and produces stable, finite, variance-reducing output on
   representative synthetic recordings.

## AMRI-Style Local Template Track

**Status: COMPLETE as of 2026-08-09.** The clean-room implementation lives in
`EVA/Gradient/LocalTemplateArtifactCorrector.swift` and covers MAS/MAR/wAAS/wAAR
for both gradient/TR events and user-defined artifact events.

All four methods are wired: they appear in the Template family of the MR Gradient
Removal sheet, routed through `GradientViewModel` by `MRIGradientMethod.engine`.
MAS and MAR use the median reducer (unscaled and least-squares respectively);
wAAS and wAAR use the exponentially weighted reducer with a configurable time
constant. `THIRD_PARTY_NOTICES.md` carries the AMRI entry.

Added during wiring, both from first principles rather than from the reference:

- `minimumDonorCorrelation` — audit item #6's automatic donor outlier rejection.
  A donor's window must reach a configurable correlation against the target's,
  scored on the highest-variance channel so the donor set stays shared across
  channels. Defaults to off. A target no donor reaches is reported as
  `.noCorrelatedDonors` and left uncorrected rather than having a mismatched
  template subtracted.
- `rejectedDonors` on each event summary, so a run records which donors it turned
  away and at what score. That reaches the exported
  `log_eva_<date>_<time>.txt` — the exclusions are the part of a run that cannot
  be reconstructed from the corrected samples.

Not wired, and deliberately out of scope for this pass:
`correctTimedEvents` supports arbitrary user-defined events at the API level, but
the gradient sheet only drives the TR-locked path. Arbitrary-event correction
needs its own event-selection surface and its own design conversation.

A Metal backend was added on 2026-08-09 (`LocalTemplateMetalBackend`,
`LocalTemplateKernels.metal`), restoring — and overtaking — the GPU option MAS
and MAR had under the retired engine. On 64 channels x 10 minutes it runs the MAS
configuration in about 0.13 s against 1.25 s on the CPU and 0.25 s on the old
engine. It is driven from the output side, one thread per (channel, sample)
recomputing the template of each covering event, so overlapping windows combine
without atomics and repeated runs are bit-identical.

Clean-room deliverables:

- [amri-functional-spec.md](amri-functional-spec.md)
- `EVA/Gradient/LocalTemplateArtifactCorrector.swift`
- `EVATests/Gradient/LocalTemplateArtifactCorrectorTests.swift`

Dirty-room validation:

- `EVATests/Gradient/LocalTemplateArtifactCompatibilityTests.swift`
  compares old EVA/AMRI-facing behavior against the clean-room implementation
  as a black-box behavioral oracle.
- The compatibility test is dirty-room validation material only. Do not use it
  as implementation guidance for a clean-room session.
- The two gradient MAS/MAR cases in it compared against `GradientRemover` and
  were removed with that engine on 2026-08-09; their result is recorded here and
  in the run below. The remaining cases compare against `ArtifactCleaner`, which
  is still present.
- Focused dirty-room compatibility run passed on 2026-08-08:

  ```sh
  xcodebuild test -project EVA.xcodeproj -scheme EVA -destination 'platform=macOS' -derivedDataPath /Users/molfesepj/Documents/Programming/EVA/.codex-derived-data CODE_SIGNING_ALLOWED=NO EXCLUDED_SOURCE_FILE_NAMES='*.metal ICLabel.mlpackage' -only-testing:EVATests/LocalTemplateArtifactCompatibilityTests
  ```

Audit follow-ups closed:

- Item #4 (excluded-channel semantics) is resolved by separating the concepts
  rather than overloading one. `excludedChannels` still means "pass this channel
  through untouched"; `obsExcludedChannels` and the new `ancExcludedChannels`
  mean "correct it, but keep it out of the stage that models the residual". The
  sheet exposes the pair as one "Template-only channels" concept, selected with
  the app's existing `ChannelSetPickerView`, and the summary and audit log both
  report how many channels it covered.

- Item #6 (automatic donor outlier rejection) is implemented as
  `LocalTemplateConfiguration.minimumDonorCorrelation`, specified from first
  principles rather than from the AMRI reference: a donor's window must reach a
  configurable Pearson correlation against the target's before it may contribute.
  Scored on the highest-variance channel, so the donor set stays shared across
  channels. Defaults to nil — an added option must not change an existing run.
  A target no donor reaches is reported as `.noCorrelatedDonors` and left
  uncorrected rather than having a mismatched template subtracted. Future option
  noted in the source: make the scoring channel selectable
  ("representative | all | subset").

Known intentional differences captured during validation:

- The clean-room local template corrector excludes the target event as a donor.
  The old AMRI-global wAAS-compatible path could include the target event as its
  own donor.
- The clean-room scaling path uses the conventional
  `dot(target, template) / dot(template, template)` coefficient. The old local
  wAAR-compatible path can behave differently and may increase a simple
  synthetic event-window energy metric.
- Local MAS is numerically very close to the old path on the synthetic
  compatibility fixture, but not bit-identical.

Conclusion: the AMRI/local-template clean-room remediation can be treated as
substantively complete. Remaining work is integration, user-facing naming,
normal real-data validation, and final notice text once the old paths are no
longer used.

## Notice Update Template

After a track is completed, add a concise entry to `THIRD_PARTY_NOTICES.md`:

> EVA implements [method] through a documented dirty-room / clean-room process.
> The implementation was written from published papers, public method
> descriptions, and EVA-owned functional specifications. [Toolbox names] are
> cited as historical/scientific references; their source code is not
> incorporated.

Record the date, clean-room spec path, implementation PR/commit, and validation
test path when those exist.

## Spec Inventory

- FASTR-family gradient correction:
  [fastr-functional-spec.md](fastr-functional-spec.md)
- AMRI-style template methods:
  [amri-functional-spec.md](amri-functional-spec.md)
