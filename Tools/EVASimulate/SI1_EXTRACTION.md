# SI-1 — Shared spherical forward-model extraction

This is the phase log for ROADMAP milestone SI-1. The numerical and scientific
acceptance criteria remain the contracts in `SI0_CONTRACTS.md`; this file records
ownership changes and verification as the extraction proceeds.

## Phase status

| Phase | Status | Result |
|---|---|---|
| 1. Shared types and API | ✅ Complete | Added app-neutral head, electrode, dipole, reference, leadfield, convergence, and typed-error values under `EVA/Core/Forward/`. |
| 2. Shared spherical solver and boundary adapters | ✅ Complete | EVA owns the one spherical-harmonic implementation; both EVA geometry and EVASimulate domain values have boundary adapters. |
| 3. Consumer compilation and forward parity | ✅ Complete | Both consumers compile; 99 simulator outcomes and 5 focused EVA shared-forward tests pass. |
| 4. Full scientific/determinism verification | ✅ Complete | All 8 existing scenario fingerprints match and all 1,264 EVA tests in 130 suites pass. |
| 5. Documentation and milestone closeout | ✅ Complete | README, SI-0 contract, simulator roadmap, and authoritative ROADMAP agree; SI-2 is next. |

## Phase 1 record — 2026-08-26

The shared ownership boundary is now explicit:

- `ForwardHeadShell` and `ForwardHeadModel` own physical shell geometry.
- `OrderedElectrodes` owns physical electrode positions in authoritative row
  order; it does not infer or substitute a montage.
- `ForwardDipole` owns position and fixed orientation, not time courses.
- `ForwardEEGReference` distinguishes average and infinity reference without
  depending on an app or file format.
- `ForwardLeadField` retains free x/y/z columns and oriented columns in the
  units and order pinned by SI-0.
- `SphericalForwardError` distinguishes malformed geometry, identity, head,
  dipole, truncation, convergence, and non-finite-output failures.

EVASimulate's JSON-facing `Vector3D`, `SphericalHeadModel`, `EEGReference`,
`SimulatedSource`, and truth `LeadField` remain domain types. Phase 2 adapters
will translate those values to the shared API so existing scenario and truth
files do not change.

## Phase 2 record — 2026-08-26

The spherical-harmonic potential, arbitrary-shell transfer recurrence,
average-reference operation, orientation projection, and convergence comparison
now have one implementation in `EVA/Core/Forward/SphericalForwardModel.swift`.
The shared solver validates all SI-0 input/error classes and rejects non-finite
output.

Ownership at the two boundaries is explicit:

- `ElectrodeGeometry.orderedForwardElectrodes(...)` converts EVA's indexed unit
  directions to ordered physical positions on the requested scalp shell and
  fails on incomplete geometry.
- EVASimulate maps its head, montage, sources, and reference to shared values,
  then maps the shared leadfield back to the unchanged truth-sidecar model.
- Those simulator-facing domain values and adapters live in
  `SimulationForwardDomain.swift`; the old simulator solver filename was retired
  so Swift can compile the EVA-owned `SphericalForwardModel.swift` directly.
- `Tools/EVASimulate/build.sh` compiles the two EVA-owned forward sources
  directly. There is no copied solver and no new package/runtime dependency.

Compilation and numerical parity are phase 3 acceptance work; phase 2 records
the ownership move, not a passing claim.

## Phase 3 record — 2026-08-26

Both build boundaries now compile the shared implementation:

- The optimized direct-source EVASimulate build succeeds with the EVA-owned
  forward files. The only emitted warning is the pre-existing `DSP.swift`
  immutable-variable suggestion.
- All 99 EVASimulate outcomes pass. This includes centered homogeneous-sphere
  and equal-conductivity analytic identities, convergence/rejection behavior,
  average-reference column means, sign/rotation/order behavior, source-space
  generation, and all nine SI-0 extraction fixtures.
- `EVATests/Core/SphericalForwardModelTests.swift` adds five app-side tests for
  the closed form, dimensions/identity, average reference, typed failures, and
  complete/incomplete `ElectrodeGeometry` adaptation. All five pass.

The simulator's printed forward/scientific metrics equal the SI-0 values. Exact
generated-scenario parity is intentionally reserved for phase 4's existing
determinism check; no baseline has been changed.

## Phase 4 record — 2026-08-26

The extraction passes every project-level backstop:

- The existing, unchanged determinism checker reports: `8 scenarios match the
  committed baseline.` No fingerprint or baseline was updated and no hashing
  infrastructure was added.
- The EVA unit/scientific target passes all 1,264 tests in 130 suites with a
  clean `xcodebuild` exit. This includes the five new shared-forward tests and
  all pipeline regression cases.
- A first unscoped scheme run also passed those same 1,264 tests, then the
  separate UI-test runner could not initialize because macOS canceled Touch ID.
  Re-running explicitly as `-only-testing:EVATests` produced `TEST SUCCEEDED`;
  the UI-runner environment error is unrelated to SI-1 and did not mask a test
  failure.

This establishes byte-identical generated scenarios, pinned numerical forward
behavior, and no detected EVA regression.

## Phase 5 record — 2026-08-26

Documentation now reflects the implemented ownership rather than the former
simulator-local architecture:

- `Tools/EVASimulate/README.md` explains that simulator adapters exercise the
  EVA-owned forward solver.
- `SI0_CONTRACTS.md` records that its extraction contract was fulfilled without
  changing the existing scenario baseline.
- the merged `ROADMAP.md` records SI-1 under the completed source-space work
  and corrects the self-test count to 99.
- The authoritative `ROADMAP.md` marks SI-1 complete and promotes SI-2 to NEXT.

SI-1 exit criterion: satisfied. EVA and EVASimulate compile one forward solver,
the simulator's leadfields remain inside every pinned numerical tolerance, and
all generated scenario fingerprints remain unchanged.
