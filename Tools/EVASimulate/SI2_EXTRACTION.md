# SI-2 — Shared source-informed operator extraction

This is the phase log for ROADMAP milestone SI-2. The numerical and scientific
acceptance criteria remain the contracts in `SI0_CONTRACTS.md`; this file records
the ownership move and verification as extraction proceeds.

## Phase status

| Phase | Status | Result |
|---|---|---|
| 1. Shared API and ownership boundary | ✅ Complete | The UI-free operator boundary, diagnostics, typed failures, and BCG-policy boundary are fixed below. |
| 2. EVA-owned operator and stable solve | ✅ Complete | EVA now owns normalization, artifact projection, LAPACK Cholesky construction, strict application, diagnostics, and typed failures. |
| 3. EVASimulate adapters and BCG policy parity | ✅ Complete | EVASimulate retains source placement and named paper/iterative BCG discovery while correction/evaluation call EVA's operator directly. |
| 4. Scientific, determinism, and EVA verification | ✅ Complete | 99 simulator outcomes, 8 unchanged scenarios, 19 focused tests, and all 1,271 EVA tests pass. |
| 5. Documentation and milestone closeout | ✅ Complete | README, SI-0 contracts, simulator roadmap, and authoritative ROADMAP agree; RW-1 is next. |

## Phase 1 record — 2026-08-26

The reusable boundary begins after domain-specific source and artifact discovery:

- EVA receives an ordered electrodes × brain-columns basis, zero or more
  electrode-length artifact topographies, and a non-negative brain ridge.
- EVA normalizes brain columns, orthonormalizes the artifact subspace, projects
  that subspace out, constructs the brain-only sensor operator, and applies it
  to ordered electrodes × samples data.
- The returned value owns the square operator and diagnostics describing input
  dimensions, retained/dropped artifact columns, effective ridge, and the
  positive-definite system's numerical range.
- Typed failures cover malformed/non-finite inputs, invalid regularization,
  degenerate projected bases or solves, malformed signal matrices, channel
  mismatch, and non-finite output.

The boundary deliberately does not own physical source placement, spherical
lead-field generation, heartbeat detection, BCG epoch filtering, representative
beat choice, or template PCA. EVASimulate retains those scientific policies;
`paper` and `iterative` remain explicit names rather than hidden tuning modes.

The implementation will solve the regularized positive-definite system for all
sensor right-hand sides through EVA's LAPACK-backed linear algebra. It will not
materialize an eigendecomposition-derived inverse. Phase 2 begins from this
recorded contract.

## Phase 2 record — 2026-08-26

`EVA/Artifacts/SourceInformed/SourceInformedOperator.swift` now owns the shared
implementation. It returns a deterministic electrodes × electrodes matrix and
diagnostics for dimensions, requested/effective regularization, retained and
dropped artifact columns, projected brain power, and the Cholesky-factor range.

`EVA/Core/LinearAlgebra.swift` now provides a reusable LAPACK `dpotrf_`/`dpotrs_`
factorization that solves several right-hand sides without constructing an
inverse. The engine uses a positive ridge floor for an explicitly unregularized
request, but rejects a zero-norm brain column, a completely projected-out basis,
or a system LAPACK cannot factor/solve. Application rejects empty, mismatched,
ragged, or non-finite signals instead of truncating them.

Five focused engine tests and two new Cholesky tests pass alongside the twelve
existing linear-algebra tests: 19 tests across two suites. This is phase-local
verification; complete app and simulator suites remain phase 4 work.

## Phase 3 record — 2026-08-26

EVASimulate now compiles the EVA-owned operator source directly, just as it does
the shared forward model. Its adapter passes `SurrogateBrainModel.matrix` across
the boundary; correction and repeated-seed evaluation construct and apply the
shared value directly, and JSON correction reports retain its diagnostics.

BCG-domain ownership did not move. Regional-source placement, beat windows,
1–20 Hz template filtering, candidate selection, and template construction stay
in `SurrogateSeparation`. `ArtifactPatternSearchMode.paper` still performs one
representative-beat comparison; `.iterative` still refines the all-beat average.
Template PCA now consumes EVA's LAPACK-backed symmetric decomposition rather
than the simulator-local Jacobi helper.

The optimized simulator builds and all 99 outcomes pass. The paper/iterative
policy fixture still reports 25 accepted paper beats, and every SI-0 metric is
unchanged at its printed precision. Full determinism and EVA-suite verification
remain phase 4 work.

## Phase 4 record — 2026-08-26

The extraction passes every project-level backstop:

- The optimized EVASimulate build succeeds and all 99 outcomes pass.
- The fixed and generated source-informed measurements remain unchanged at
  printed precision: 21.915 artifact-free residual SNR, 0.995 regularized
  topography correlation, 11.967 fixed-fixture residual SNR, 0.947 worst
  artifact-aware brain correlation, and 2.613 known-BCG corrected SNR.
- Operator construction is exactly repeatable within the build; a unit artifact
  column remains below the `1e-8` gain ceiling; paper and iterative discovery
  remain distinct and deterministic; malformed and degenerate cases fail.
- The existing, unchanged determinism checker reports `8 scenarios match the
  committed baseline.` No scenario fingerprint or hashing infrastructure was
  added or updated.
- The complete EVA test target passes 1,271 tests in 131 suites. This includes
  five shared-engine tests, two new Cholesky tests, the existing linear-algebra
  suite, and all application/pipeline regression tests.

## Phase 5 record — 2026-08-26

Documentation now reflects implemented ownership and verification:

- `README.md` describes the shared engine and report diagnostics.
- `SI0_CONTRACTS.md` names the implemented API, expanded explicit failures,
  stable solve, and SI-2 closeout results.
- `EVAsimulate_ROADMAP.md` records SI-2 as complete and defers sequencing to the
  authoritative cross-project ROADMAP.
- `ROADMAP.md` marks SI-2 complete and leaves RW-1 as the next dependency before
  SI-3 app integration.

SI-2 exit criterion: satisfied. EVASimulate calls the EVA-owned engine, the
scientific acceptance measurements are retained, the generated-scenario
baseline is unchanged, and no second operator implementation remains in the
simulator.
