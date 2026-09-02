# EVA Resolve — Setup Plan

**Goal:** Start EVA Resolve as a *focused sibling app* to EVA — a distinct, narrower
tool that shares EVA's IO + core math but has its own UI. This document covers how it is
stood up structurally (no new Xcode project) and the order of operations.

---

## Decision: no new `.xcodeproj`

EVA is already a **multi-target project**. `EVA.xcodeproj` contains:

- `EVA` — the main app
- `EVASimulate` — CLI target
- `EVAQuickLook`, `EVAThumbnail` — extensions
- `EVATests`, `EVAUITests` — test bundles

Adding **EVA Resolve is just a new app target** in this same project. A second
`.xcodeproj` would force a workspace + cross-project dependencies for no benefit.

## Sharing mechanism: a shared synchronized folder, not a framework  *(done 2026-09-02)*

`EVASimulate` used to reuse EVA code by **per-file dual target membership** — 38
individual `.swift` files referenced by path and added to its Sources phase. That is a
maintenance tax: every shared file needs manual membership and a forgotten file silently
breaks one target.

A framework target (`EVACore`) was considered and rejected for now:

- The candidate folders are not UI-free. `EVA/IO/` holds eight SwiftUI view files,
  `EVA/Simulation/` holds controllers, and `EVA/Models/` is only the ICLabel CoreML
  package. The real shared seam is the file list `EVASimulate` compiles, which spans
  Core, IO, Simulation, Channels, Epoching, Pipeline, and Artifacts.
- A framework boundary forces a `public` pass over ~13k lines / ~2,300 declarations,
  plus `@testable import EVACore` across the test suite and `Bundle.main` fixups. Large
  churn for no functional gain.
- The repo already shares code across targets another way: `MFFPreviewKit/` and
  `EVAPreviewKit/` are **Xcode synchronized folder groups** attached to several targets
  (QuickLook, Thumbnail, EVATests). Folder-level membership means any file dropped in the
  folder compiles into every attached target, with no module boundary and no `public`.

**What was done:** the 38 shared files were moved (`git mv`, sub-folder structure kept)
from `EVA/` into a top-level **`EVACore/`** synchronized folder that is attached to both
the `EVA` and `EVASimulate` targets. The per-file references were deleted from
`EVASimulate`. Everything stays in the `EVA` module, so `@testable import EVA` in tests
and all existing call sites are untouched. `Tools/EVABIDS/build.sh` and
`Tools/EVAHelper/build.sh`, which compile some of these files directly with `swiftc`,
were re-pointed at the new paths.

Layout:

```
EVACore/
  Core/            AccelerateCompat, DSP, LinearAlgebra, SeededGenerator
  Core/Forward/    ForwardTypes, Spherical/Ellipsoidal/BEM forward models
  IO/              EGISensorXMLParser, MFFFileType, MFFReader, MFFWriter
  Channels/        ElectrodeGeometry, SensorLayout
  Epoching/        EpochModel
  Pipeline/        EVAProcessingScript
  Simulation/      generators, artifact models, config/scenario types
  Artifacts/SourceInformed/  SourceInformedOperator
```

Rule going forward: **anything that must be visible to more than one app or tool goes in
`EVACore/`**; anything that imports SwiftUI/AppKit stays in `EVA/`. If a hard module
boundary is ever wanted, `EVACore/` is exactly the input a framework target would take, so
nothing is lost by deferring that.

---

## Next steps

### Step 2 — Add the Resolve app target

New **macOS App target "EVA Resolve"** in the same project:

- Attach the `EVACore` synchronized folder (one line in `fileSystemSynchronizedGroups`).
- Holds only its own UI / `App/` layer in a new `EVAResolve/` folder.
- Own bundle ID, Info.plist, entitlements.
- Add its own test bundle, or attach `EVACore` to `EVATests` if Resolve-only code needs
  testing there.

### Step 3 — Build Resolve's actual features

With the core shared, Resolve starts as a thin app shell that already has all of the
shared IO and math. Anything Resolve needs from `EVA/` that is not yet in `EVACore/`
(e.g. `SphericalSpline`, `Downsampler`, more of `Channels/`) is moved into `EVACore/`
first, on the same rule as above. No Resolve feature design is committed by Step 2.
