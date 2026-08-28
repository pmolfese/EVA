# SI-0 — Forward-model and PCA-S characterization contracts

Recorded 2026-08-26 from the optimized EVASimulate build on macOS. This file is
the handoff boundary for SI-1 and SI-2: extraction may reorganize ownership and
replace the eigensolver, but it may not silently change these meanings.

The executable fixtures live in
`Sources/EVASimulate/SI0ContractFixtures.swift` and run as part of `selftest`.
The broader simulator self-test remains the scientific backstop.

## What is exact and what has tolerance

| Contract | Classification | Rule |
|---|---|---|
| Matrix dimensions and rectangularity | Exact | Oriented leadfield is electrodes × dipoles; free leadfield is electrodes × `3 * dipoles`; PCA-S operator is electrodes × electrodes. |
| Electrode and dipole identity/order | Exact | Input electrode order is output row order; dipole order is oriented-column order; free columns are x, y, z for each dipole in dipole order. |
| Reference identity | Exact | The requested reference is recorded in the result; average-referenced columns have zero channel mean within floating tolerance. |
| Finiteness and invalid-input behavior | Exact | Non-finite, ragged, empty, dimension-mismatched, negative-regularization, invalid-shell, outside-brain, non-unit-orientation, and invalid-term inputs fail explicitly. No padding, truncation, or plausible partial operator. |
| Repeatability in one implementation/build | Exact | Repeating a fixed leadfield or PCA-S construction produces exactly equal matrices. Paper-mode pattern selection produces the same representative beat and template. |
| Existing generated scenarios | Exact | The eight pre-existing scenario fingerprints in `determinism-baseline.txt` must remain unchanged unless generated data intentionally changes. SI-0 adds no new hashing system. |
| Analytic forward identities | Numerical tolerance | Centered homogeneous-sphere and equal-conductivity-shell relative errors remain below `1e-12`; average-reference means remain below `1e-14`. |
| Harmonic convergence | Numerical tolerance | Default 100→200-term maximum relative column change remains below `1e-4`; truncation error decreases over 10/25/50/100 terms and an under-resolved field is rejected. |
| Artifact-free preservation | Scientific tolerance | Fixed-fixture residual SNR stays above 5 and worst topographic correlation above 0.97. The 2026-08-26 residual-SNR baseline is 11.967. |
| Known-artifact attenuation | Scientific tolerance | Unit-norm artifact-column output/input norm stays below `1e-8`. |
| Brain preservation with an artifact block | Scientific tolerance | Fixed-fixture worst topographic correlation stays above 0.93. The 2026-08-26 baseline is 0.947. |
| Full generated-recording behavior | Scientific tolerance | Artifact-free residual SNR stays above 5 (baseline 21.915); regularized dipole correlation stays above 0.95 (baseline 0.995); known-BCG corrected SNR remains at least 1.8× uncorrected (corrected baseline 2.613). |

An eigensolver change is allowed to move values inside the documented numerical
and scientific tolerances. It is not allowed to change shape, order, reference,
error semantics, or determinism. A tolerance failure requires investigation; it
must not be answered by merely widening the threshold.

## Shared forward API for SI-1

The extracted API uses ordered physical positions rather than simulator montage
angles:

```swift
struct OrderedElectrodes: Sendable {
    var names: [String]
    var positionsMeters: [SIMD3<Double>]
}

struct ForwardDipole: Sendable, Identifiable {
    var id: String
    var positionMeters: SIMD3<Double>
    var orientationUnit: SIMD3<Double>
}

enum ForwardEEGReference: Sendable {
    case average
    case infinity
}

struct ForwardLeadField: Sendable {
    var electrodeNames: [String]
    var dipoleIDs: [String]
    var reference: ForwardEEGReference
    var freeMicrovoltsPerNanoampereMeter: [[Double]] // electrodes × 3*dipoles
    var orientedMicrovoltsPerNanoampereMeter: [[Double]] // electrodes × dipoles
}

static func leadField(
    head: ForwardHeadModel,
    electrodes: OrderedElectrodes,
    dipoles: [ForwardDipole],
    reference: ForwardEEGReference,
    harmonicTerms: Int,
    verifyConvergence: Bool
) throws -> ForwardLeadField
```

SI-1 phase 1 adopted the `Forward` prefixes shown above so the app-neutral
values can coexist with EVASimulate's stable JSON/truth schema during boundary
adaptation. This is a naming clarification only; the pinned order, units,
reference, and error contracts are unchanged. Phase progress is recorded in
`SI1_EXTRACTION.md`.

Coordinate and unit contract:

- Positions are metres in a head-centered right/anterior/superior frame:
  `+x` right, `+y` anterior/nose, `+z` vertex/superior.
- `SphericalHeadModel.centerMeters` is the coordinate origin of the concentric
  shells. Electrode positions are physical positions on the outer shell; the
  shared solver must not silently substitute a standard montage.
- `ForwardDipole.orientationUnit` is a finite unit vector in the same frame.
- Leadfield entries are microvolts per nanoampere-metre. Dipole moment time
  series are not part of `ForwardDipole`; applying the operator supplies them.
- Array order is authoritative. Names/IDs are identity and provenance, not a
  license to reorder behind the caller's back.
- Average reference is applied once to every free-orientation column before
  oriented columns are formed. Infinity reference performs no subtraction.

The extracted forward error type must distinguish at least: empty electrodes,
name/position count mismatch, duplicate or empty identity, non-finite position,
invalid shell order/conductivity, dipole outside the brain shell, non-finite or
non-unit orientation, invalid harmonic term count/tolerance, failed convergence,
and non-finite numerical output.

## Shared source-informed operator API for SI-2

The UI-free operator boundary is:

```swift
static func makeOperator(
    brainBasis: [[Double]],             // electrodes × brain columns
    artifactTopographies: [[Double]],   // one electrodes-length vector each
    brainRegularization: Double
) throws -> SourceInformedOperator

struct SourceInformedOperator: Sendable {
    var matrix: [[Double]]               // electrodes × electrodes
    var diagnostics: SourceInformedOperatorDiagnostics
}
```

It must reject empty/ragged/non-finite bases, artifact vectors whose length does
not equal the electrode count, non-finite artifact values, and non-finite or
negative regularization. Application requires an electrodes × samples signal
with the same ordered electrode identity used to construct the operator. Domain
adapters—not this engine—own BCG template discovery and paper versus iterative
pattern selection.

SI-2 implemented this boundary in
`EVA/Artifacts/SourceInformed/SourceInformedOperator.swift`. The engine also
rejects zero-norm brain columns, a basis wholly removed by the artifact
subspace, non-positive-definite/failed solves, malformed operators, and empty,
ragged, mismatched, or non-finite application signals. Diagnostics retain
dimensions, artifact-column retention, requested/effective regularization,
projected brain power, and the Cholesky-factor range. Construction uses an EVA
LAPACK Cholesky solve rather than materializing an inverse.

## Recorded simulator baseline

The optimized self-test passes 99 outcomes, including nine SI-0 boundary
fixtures. Relevant current measurements are:

| Measurement | 2026-08-26 value |
|---|---:|
| Locked-clock AAS SNR | 4.328 |
| Drifted-clock AAS SNR | 0.045 |
| Artifact-free PCA-S residual SNR | 21.915 |
| Regularized dipole-topography correlation | 0.995 |
| Fixed-fixture artifact-free residual SNR | 11.967 |
| Fixed-fixture artifact-aware worst brain correlation | 0.947 |
| End-to-end known-BCG corrected SNR | 2.613 |
| Paper-mode accepted beats in the full self-test fixture | 25 |

The pre-existing scenario fingerprints remain authoritative in
`determinism-baseline.txt`:

| Scenario | SHA-256 fingerprint |
|---|---|
| `aep-bilateral` | `0e0cb55df75517b951581c0bd5bb9f36f7f48d212fa96cab925a94a93e64b4e4` |
| `bcg-generators` | `929e9ed3d1856919776b7bac5f4169738d5de2675bdad17b96ead26b3650d9b8` |
| `dipole-separability` | `f95de8a788c62c2637f8a1ee442a117fd62608b8555f1e9d3f950a979104f37f` |
| `group-oddball` | `c3aae87f105bd28ef746bacba3083e22d78f9a9ffca9ca372c74f62ff42d9eb4` |
| `oddball-erp` | `ede105a1e59c0642c681fc6af0c0a7b64b273b157f31f161183f46e09299f1a0` |
| `paper-default` | `05250c8849b024cf20fff736cb280b58887aed7c38d70800356b018c56af06af` |
| `regression-gradient-locked` | `4c4888c5d8668a1c9a371286011360d63440e403861a5e6c7b06e54da3e7c650` |
| `teaching-demo` | `5297ef635a4ace218b99a469b63d8083b40fe381d7830b7e7fdd4c2441c4d4a2` |

Verification commands:

```sh
Tools/EVASimulate/build.sh
Tools/EVASimulate/.build/eva-simulate selftest
scripts/check-determinism.sh
```

## SI-1 closeout

SI-1 completed this extraction on 2026-08-26. The API above is implemented in
`EVA/Core/Forward/`, EVASimulate consumes it through boundary adapters, all 99
simulator outcomes pass, all eight existing generated scenarios remain
byte-identical, and all 1,264 EVA tests pass. See `SI1_EXTRACTION.md` for the
phase-by-phase ownership and verification record. No determinism baseline or
hashing infrastructure was changed.

## SI-2 closeout

SI-2 completed the operator extraction on 2026-08-26. EVASimulate now calls the
EVA-owned engine directly while retaining paper/iterative BCG discovery as
named simulator policies. All 99 simulator outcomes pass with the recorded
scientific values unchanged at printed precision, all eight existing generated
scenarios remain byte-identical, and all 1,271 EVA tests across 131 suites pass.
See `SI2_EXTRACTION.md` for the phase record. The existing determinism baseline
and hashing infrastructure were not changed.
