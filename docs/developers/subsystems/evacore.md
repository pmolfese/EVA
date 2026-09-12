# EVACore — core library — `EVACore/` (Core, Forward, Geometry, Channels, Registration, Imaging, Epoching)

**Purpose.** The UI-free computational heart, reusable by the app, the CLI tools,
QuickLook, and Resolve. This page covers the math and geometry groups; the format
readers are on [evacore-io.md](evacore-io.md), synthetic-data generation is on
[evacore-simulation.md](evacore-simulation.md), and the `eva.xml` schema
(`EVACore/Pipeline`) is documented with [pipeline.md](pipeline.md).

**Start here.** `DSP` (filters/FFT/convolution) and `LinearAlgebra`
(LU/Cholesky) are the primitives. The **forward model** is the crown jewel:
`ForwardTypes` defines the vocabulary and `SphericalForwardModel` /
`EllipsoidalForwardModel` / `BEMForwardModel` are the three tiers. `SensorLayout`
/ `ElectrodeGeometry` are the electrode-geometry substrate.

## Core / math — `EVACore/Core`

| File | Synopsis |
|---|---|
| `DSP.swift` | The shared DSP namespace: filtering, FFT, convolution, windows. |
| `LinearAlgebra.swift` | Dense linear algebra: `LUFactorization`, `CholeskyFactorization`, solves. |
| `SeededGenerator.swift` | Deterministic seeded RNG (reproducible simulation/permutation). |
| `AccelerateCompat.swift` | Shims over Accelerate API differences. |

## Forward model — `EVACore/Core/Forward`

| File | Synopsis |
|---|---|
| `ForwardTypes.swift` | The shared vocabulary: `ForwardHeadModel`, `ForwardHeadShell`, `ForwardDipole`, `ForwardLeadField`, EEG reference, convergence report. |
| `SphericalForwardModel.swift` | Analytic 3/4-shell spherical forward solution (`leadField`, `convergenceReport`, `potentialPerUnitMoment`). |
| `EllipsoidalForwardModel.swift` | Affine-ellipsoid forward model (`ForwardEllipsoidModel`). |
| `BEMForwardModel.swift` | Boundary-element forward model: `leadField`, `solveSurfacePotentials`, icosphere meshing, solid angles. |
| `BEMGeometry.swift` | BEM geometry + provenance + quality checks (`Solver`, `QualityReport`, import errors). |
| `BEMSolution.swift` | A solved BEM operator (`BEMSolution`). |

## Geometry & registration — `EVACore/Geometry`, `EVACore/Registration`

| File | Synopsis |
|---|---|
| `HeadTransform.swift` | Coordinate frames and fits between them (`CoordinateFrame`, `HeadTransform`, SVD-based `Fit`). |
| `TriangleMesh.swift` | Triangle mesh + spatial index + closest-point queries (`SurfaceIndex`). |
| `TriangleMeshIntersection.swift` | Ray/segment–mesh intersection tests. |
| `Registration/SurfaceRegistration.swift` | ICP surface registration (`ICPResult`, `ICPOptions`). |

## Channels (geometry substrate) — `EVACore/Channels`

| File | Synopsis |
|---|---|
| `SensorLayout.swift` | `SensorPosition` / `SensorReference` / `SensorLayout` — the electrode-layout model. |
| `ElectrodeGeometry.swift` | 3-D electrode geometry. |
| `ElectrodePositions.swift` | Parsed electrode positions with units/kind and read errors. |
| `StandardMontage.swift` / `StandardMontageData.swift` | Built-in standard montages and their coordinate data. |

## Imaging & epoching — `EVACore/Imaging`, `EVACore/Epoching`, `EVACore/Artifacts`

| File | Synopsis |
|---|---|
| `Imaging/ScalpFromVolume.swift` | Extracts a scalp surface from an MRI volume (`Options`, `Result`). |
| `Imaging/VolumeMorphology.swift` | Binary-volume morphology ops (erode/dilate/connectivity) for segmentation. |
| `Epoching/EpochModel.swift` | `EpochSegment` — the epoch unit shared with the app. |
| `Artifacts/SourceInformed/SourceInformedOperator.swift` | Source-informed separation operator (`SourceInformedSeparation`, diagnostics). |

## How to extend this

This module has **no UI and no app dependencies** — keep it that way so tests,
CLI tools, and QuickLook can use it. The forward model is shared by
interpolation, topomaps, the simulator, and source fitting; a change to
`ForwardTypes`/`SensorLayout` ripples into all of them, so validate against
`Tools/forward-compare` and the Resolve validation fixtures. New forward tiers
implement the pattern in `ForwardTypes` (a `leadField(...)` + convergence report)
so callers stay tier-agnostic.
