# Source Analysis in EVA — Planning Notes

Brainstorm document. Nothing here is committed to; it's a starting map for a
conversation about whether/how to add EEG source analysis, and whether that
lives in EVA itself or in a companion app (tentatively **EVA Resolve**).

## 1. Why this is on the table

Two distinct motivations, and they pull toward different amounts of machinery:

1. **BCG removal via a source-space / BESA-style method.** BESA Research's
   artifact-correction workflow (and the related literature on source-space
   BCG suppression, e.g. Cannon et al. 2015 "L1-norm" and the older
   BESA-associated component-space approaches) projects the data into a small
   set of spatial sources — anatomically-informed or PCA-derived — regresses
   out the ones that load on cardiac topography, then projects back to
   channel space. This is a lightweight version of "source analysis": it
   needs a **head model good enough to define a source space and a lead
   field**, but not necessarily individual anatomy, and no user-facing
   localization results. It's the low-effort, high-value target.
2. **General distributed-source imaging (LORETA/sLORETA/eLORETA/LAURA-family)**
   for people who want to look at cortical current density maps, not just
   clean the scalp signal. This is the full source-localization feature set
   EVA does not currently perform source
   localization at all. It's a much bigger, longer-lived effort with its own UI,
   its own validation burden, and its own dependency graph (head models,
   coregistration, forward solvers).

Both share the same first three building blocks — **electrode coregistration,
a head model, and a forward (lead field) solution** — so it's worth designing
those once, then letting (1) and (2) sit on top as increasingly heavy
consumers.

## 2. Where this should live: EVA vs. "EVA Resolve"

Arguments for a separate app:
- **Dependency weight.** Even a "light" pipeline needs a decent linear-algebra
  stack for lead-field computation (BEM/FEM matrix solves), mesh handling,
  and (optionally) FreeSurfer surfaces. EVA today is deliberately lean
  (Accelerate/vDSP, no heavy scientific dependency tree), and that leanness is
  part of the "runs natively on macOS" positioning.
  Bundling a mesh/BEM solver into the main waveform-editing app risks bloating
  build time, binary size, and the app's cognitive scope.
- **Different audience/workflow.** Source analysis is a *between-recordings*,
  *per-subject-anatomy* workflow (import MRI or template → coregister →
  solve forward model → cache lead field → run inverse on one or many
  recordings). That's a project-based mental model, closer to a "study"
  object than a single-recording editor. EVA's UI is single-recording-first.
- **Independent release cadence / risk.** Source localization correctness is
  much harder to validate than scalp-level filtering. Shipping it inside EVA
  couples EVA's release quality bar to a much harder problem.
- **Still shares code.** Both apps can depend on the same Swift Package
  modules: `SensorLayout`/`ElectrodeGeometry` (already exist in
  [EVA/Channels](EVA/Channels)), the signal-processing core
  (`EEGSignalFilter`, Accelerate-based FFT/filter helpers), and file I/O
  (`.mff`/BrainVision/EDF readers). EVA Resolve would import EVA's existing
  "core" packages rather than re-implement channel geometry or file parsing.

Argument for keeping it in EVA: users doing BCG cleanup are already inside
EVA's EEG-fMRI workflow (gradient correction, BCG detection panels already
live in `EVA/Cardiac`), so a source-space BCG option is a natural extension
of an existing panel, not a new app. This suggests: **(1) BCG source-space
regression as a mode inside EVA's existing BCG correction UI, reusing a
"lightweight" head model; (2) full distributed source imaging as EVA
Resolve**, a separate app/target that EVA can optionally hand a recording off
to (or that reads EVA's exported/annotated files).

## 3. Head model tiers (pick per use case, not one-size-fits-all)

| Tier | What it is | Effort | Good for |
|---|---|---|---|
| **Spherical (single/3-shell)** | Analytic forward solution, no meshing | Very low — closed-form, easy to port to Swift | BCG source regression; "good enough" localization for coarse review |
| **Template BEM (e.g. ICBM152 / fsaverage boundary meshes)** | Precomputed scalp/skull/brain surfaces, generic head, only electrode coregistration is subject-specific | Medium — need a BEM solver, but meshes ship precomputed | Default source imaging for users without a T1 |
| **Individual BEM/FEM from subject MRI** | Full segmentation + meshing pipeline (typically FreeSurfer + MNE watershed/BEM, or FEM with SimNIBS-like segmentation) | High — heavy dependency, long compute, fragile on edge-case anatomy | Best accuracy; power users with a T1 |

Recommendation: **ship spherical first** (unblocks BCG source-space removal
with almost no new dependency), **template BEM second** (unblocks
LORETA/sLORETA-style maps for the common no-MRI case), **individual
MRI/FreeSurfer path last and optional**, not a requirement to use the
feature at all.

### On FreeSurfer specifically

Reasonable to be nervous about a hard FreeSurfer dependency:
- It's a huge (multi-GB), Linux/macOS command-line toolchain with its own
  license (mostly permissive, but not a Swift package — you'd be shelling out
  to an external binary, not linking code), multi-hour `recon-all` runtimes,
  and its own failure modes on atypical anatomy (pediatric, lesioned, low-res
  T1). Requiring it as a hard dependency would make "I have a T1" users wait
  hours before they can do anything, and would make EVA Resolve responsible
  for babysitting an external process it doesn't control.
- Alternatives for "do our own segmentation," roughly in order of effort:
  1. **Skip individual segmentation for v1** — template head model is
     "good enough" for most clinical/cognitive EEG use (this is what
     MNE-Python and Brainstorm both default new users toward anyway, when no
     good T1 exists).
  2. **Coregistration-only individual model** — keep template *shape*, warp
     to a few fiducials/digitized head points (a cheap fit, not a
     segmentation) — this is what happens today when there's no MRI at all
     in MNE/FieldTrip, and it's a big accuracy jump over ignoring anatomy.
  3. **Lightweight own segmentation** — a fast, approximate 3-layer
     (scalp/skull/brain) segmentation from a T1 using classical image
     processing (intensity thresholds + morphological ops + surface
     extraction, e.g. marching cubes) rather than full cortical
     surface reconstruction. Much less accurate than FreeSurfer but avoids
     the dependency and the multi-hour wait; probably fine for BEM shells
     (which don't need gyral-level cortical surfaces, only 3 smooth
     boundaries).
  4. **Optional FreeSurfer import** — if a user already has `recon-all`
     output (many EEG-fMRI/epilepsy-surgery labs do, for other reasons), let
     EVA Resolve *read* FreeSurfer surfaces (`.pial`/`.white`/`.inflated`,
     `wm.mgz`, etc.) as an optional high-accuracy path, without ever
     requiring the app itself to run FreeSurfer. This gets the "best case"
     accuracy without owning the segmentation pipeline.

  (3) and (4) together seem like the right long-term shape: own lightweight
  segmentation as the built-in path, FreeSurfer import as the power-user
  escape hatch.

## 4. Forward modeling

All of these solve the same quasi-static Poisson equation for volume-conducted
potential; they differ in how they discretize the head.

- **Spherical/analytic**: closed-form, trivial to port to Swift/Accelerate,
  no external code needed at all — can likely write this directly rather
  than "port" anything.
- **BEM (Boundary Element Method)**: assumes each tissue compartment
  (scalp/skull/brain) is homogeneous and isotropic; only the *boundaries
  between* compartments need meshing — 2D triangulated surfaces, not the 3D
  volume. Small, dense, directly-solvable linear system. Cannot represent
  skull anisotropy (skull is layered compact/spongy bone with real
  conductivity differences) or skull holes/defects. This is the default in
  MNE-Python, FieldTrip, and Brainstorm alike. Reference implementations:
  - **OpenMEEG** (C++, CeCILL-B license) — the solver MNE-Python calls into
    for BEM. CeCILL-B is a French free-software license, roughly BSD-like,
    permissive/free-software terms; check attribution terms before
    vendoring/porting code.
  - **MNE-Python's own linear-collocation BEM** (BSD-3) — simpler to read
    and port than OpenMEEG's C++; MNE reimplemented a subset of OpenMEEG's
    math in pure Python at one point, which is a more approachable reference
    for a from-scratch Swift port than OpenMEEG's C++ codebase.
- **FEM (Finite Element Method)**: discretizes the *entire 3D volume* into
  tetrahedra, conductivity (isotropic or full anisotropic tensor) assigned
  per element. Handles what BEM can't — skull/white-matter anisotropy (if
  DTI is available), skull defects, arbitrarily heterogeneous tissue. The
  real cost is **volumetric mesh generation**: producing a valid,
  non-degenerate tetrahedral mesh that conforms to internal boundaries
  (including a CSF layer that can be <1-2mm thick) is a hard computational-
  geometry problem in its own right, and in practice essentially nobody
  writes this from scratch — everyone leans on an existing mesh generator
  (Gmsh, TetGen, CGAL) or a purpose-built pipeline (SimNIBS's
  `headreco`/`charm`). Solve is a large sparse system (preconditioned
  conjugate gradient), not BEM's dense-but-small one. SimBio/DUNEuro is the
  relevant open FEM reference if this is ever revisited.
- **FDM (Finite Difference Method)**: uses the MRI's own voxel grid directly
  as the discretization — no explicit meshing step at all, conductivity
  assigned per voxel from the segmentation. This sidesteps FEM's hardest
  subproblem (meshing) entirely, at the cost of "staircasing" curved
  boundaries (skull, CSF) into the voxel grid unless resolution is pushed
  high (which then costs solve time). Historically popular (Hallez et al.,
  DeMunck) before FEM meshing tools matured, largely because it avoids
  meshing. A reasonable middle ground if FEM-level tissue heterogeneity is
  ever wanted without taking on a mesh generator dependency.

**Reciprocity matters for FEM/FDM.** Naively you'd re-solve the whole system
once per candidate source location (thousands of points × 3 orientations).
Nobody does this — Helmholtz reciprocity lets you solve once per *electrode*
instead, producing a transfer matrix that maps any source to sensor
potentials via a dot product. This is the standard DUNEuro/SimBio approach
and is essential for FEM/FDM to be practical at all; BEM's small dense
system doesn't need the trick as badly but often uses an analogous
approach anyway.

Practically: **port the math from MNE-Python's pure-Python BEM implementation
(BSD-3, most permissive and most readable)** rather than OpenMEEG's C++,
given the goal is a from-scratch Swift implementation, not FFI-wrapping
someone else's binary.

### 4.1 What "generate our own from MRI" actually takes, per method

1. **NIfTI I/O.** No mature NIfTI reader exists in Swift today — needs a
   small from-scratch parser. The format itself (NIfTI-1) is simple and
   well-specified; the real gotcha is getting the affine/RAS-vs-LAS
   orientation convention right, a classic source of silent, hard-to-spot
   bugs (wrong handedness produces a plausible-looking but mirrored head).
2. **Segmentation** — the hard part, and its scope depends on the method:
   - *BEM* needs only 3 compartments (scalp / skull / brain-as-one) —
     tractable.
   - *FEM/FDM* ideally want 5-6 tissue types (scalp, compact skull, spongy
     skull, CSF, gray matter, white matter) for the anisotropy/heterogeneity
     to actually pay off — substantially more segmentation work.
   - **Skull is the hard tissue to get right from a T1 alone** — bone has
     little/no MR signal, so it's dark just like air, and naive intensity
     thresholding can't separate them. Real pipelines lean on atlas-based
     registration (warp a pre-labeled template into subject space) rather
     than pure intensity segmentation, specifically to work around this.
     Fully matching FreeSurfer/SPM-level robustness across arbitrary
     real-world scans (different scanners, ages, pathology) is a
     multi-year problem; a "good enough for a clean adult T1, 3-shell BEM"
     version is realistically weeks-to-months for a small, focused effort,
     atlas-based registration probably the most tractable route.
3. **Meshing:**
   - *BEM*: marching cubes on the segmented volume → smooth/decimate to a
     few thousand triangles per surface, ensure surfaces are nested and
     non-self-intersecting. Standard, well-trodden algorithms (this is what
     `mne watershed_bem` does).
   - *FEM*: full 3D tetrahedral meshing respecting internal boundaries —
     the step nobody reasonably builds from scratch; would mean adopting an
     existing mesh generator. Worth flagging a licensing wrinkle here:
     **TetGen's license is not free for proprietary/commercial
     redistribution** without a separate arrangement with its author —
     check carefully before depending on it. Gmsh is GPL (compatible with
     EVA, but another heavy external dependency to embed or shell out to).
   - *FDM*: none needed — this is its main practical advantage over FEM.
4. **Conductivity assignment**: literature constants per tissue (skull
   ~0.006–0.01 S/m, brain/CSF ~0.33–1.79 S/m, scalp ~0.33–0.44 S/m) — the
   easy part, unless anisotropy from DTI is also wanted (rarely available
   for a typical EEG session; probably skip).
5. **Solver**: BEM needs a dense boundary-integral solve — tractable, and
   the MNE-Python math already identified above as the porting reference.
   FEM/FDM need a sparse SPD solve; worth noting the Accelerate framework's
   **Sparse Solvers** (which support conjugate-gradient and direct sparse
   solves) make this more native-Swift-friendly than it might sound, so the
   solver itself isn't the blocker — the volumetric mesh (for FEM) or the
   segmentation resolution (for FDM) is.

**Bottom line**: BEM is the realistic "build our own" target for a small
team — smaller mesh problem, only 3 tissue compartments to segment, and a
linear-algebra core already slated for porting from MNE-Python. FEM's
accuracy gain (anisotropy, skull defects) is real but gated by volumetric
mesh generation, which is the one piece that would mean adopting an external
mesher (with the TetGen/Gmsh licensing question above) rather than "our
own." FDM is a legitimate middle ground if FEM-level heterogeneity is ever
wanted without the meshing dependency, at the cost of voxel staircasing
error — worth keeping in mind as a fallback if FEM's mesh-generation
dependency turns out to be a dealbreaker.

### 4.2 Could OpenMEEG / MNE be used directly for FEM? No — a correction

Worth being precise here since it's a natural-sounding but wrong shortcut:
**neither OpenMEEG nor MNE-Python implements FEM.** OpenMEEG has only ever
been a BEM (boundary-integral) library. MNE-Python's own forward solver is
also BEM-based — it has no volumetric solver of its own. The actual FEM
engine in that ecosystem is **DUNEuro** (via its `duneuropy` bindings), a
separate C++ library built on the DUNE PDE framework; MNE can *read a
forward solution DUNEuro already computed*, but doesn't compute it. DUNEuro
is a substantially larger and more complex codebase than OpenMEEG, so
porting *it* to Swift would dwarf the BEM-porting effort.

That reframes the real choice for either method as **port vs. link**:
- **Port the math to Swift** (as planned for BEM, from MNE-Python's
  pure-Python implementation) — keeps the dependency graph pure-Swift, at
  the cost of re-deriving and re-validating numerically tricky code
  ourselves.
- **Link the existing C++ library directly** (Swift/C++ interop or a C
  bridging header) instead of reimplementing it — skips re-validating
  math that's already been proven out over years in the field, at the cost
  of pulling a full C++/CMake build into an otherwise Swift-first project,
  and a license check per library (OpenMEEG's CeCILL-B is roughly BSD-like
  and should be fine to link; DUNEuro's licensing, inherited from DUNE's
  mixed LGPL-with-linking-exception-style module terms, needs verifying
  before committing to it — not assumed).

Realistic split: **BEM — port MNE's math (already the plan) or link
OpenMEEG, either is viable. FEM — if ever pursued, link DUNEuro rather than
attempt a from-scratch port**, since reimplementing DUNEuro's FEM assembly
ourselves would dwarf even the segmentation/meshing effort already flagged
in §4.1 as the hard part.

## 5. Inverse methods — what "LORETA/sLORETA/LAURA" actually means here

Loose terminology worth pinning down before design, since these are often
conflated:

- **MNE (minimum-norm estimate)**: the base linear inverse (weighted
  pseudoinverse of the lead field + Tikhonov regularization). Everything
  below is a variant of this.
- **dSPM**: MNE, noise-normalized.
- **sLORETA** (standardized LORETA): MNE, standardized by estimated
  resolution-matrix variance — in practice, another cheap noise/resolution
  normalization on top of the same minimum-norm core. Zero localization
  bias for a single point source, which is the property that made it
  popular.
- **eLORETA** (exact LORETA): an iterative, depth-weighted variant with a
  different (data-dependent) resolution kernel — more expensive than
  sLORETA but still a linear-per-iteration solve.
- **LORETA (original, 1994)**: a Laplacian-weighted minimum-norm variant,
  largely superseded in practice by sLORETA/eLORETA; still cited a lot
  because "LORETA" became a genericized name for the whole family.
- **LAURA** (Local AUtoRegressive Average): a different weighting scheme
  (uses a local-autoregressive spatial coherence assumption instead of a
  Laplacian) — less commonly reimplemented outside GeoSource/Cartool; would
  need its own literature dig if actually wanted (references: Grave de
  Peralta Menendez et al.).
- ("sLAURA" doesn't appear to be a standard, separately-published method
  distinct from LAURA in the literature — worth double-checking this is a
  real separate algorithm and not a mixup with sLORETA before committing
  engineering time to it.)

**All of MNE/dSPM/sLORETA/eLORETA are the same linear-algebra core with
different weighting/normalization matrices** — implementing one gets you
90% of the way to all four. That's a good "do this first" target: a single
minimum-norm engine parameterized by a normalization strategy, covering
MNE/dSPM/sLORETA/eLORETA with shared code, LAURA (and true LORETA) as a
separate weighting matrix if there's demand.

**Reference implementation to port from**: MNE-Python's `mne.minimum_norm`
module (BSD-3) — it's the most-cited, most-validated open implementation of
this whole family, has readable Python, and its license is the most
permissive of the realistic options (vs. GPL-2 FieldTrip/EEGLAB, GPL
Brainstorm). Beamformers (LCMV/DICS) live in `mne.beamformer`, also BSD-3,
worth a look later if MEG-style spatial filtering is ever wanted, but is a
lower priority for scalp EEG BCG/ERP use cases than the minimum-norm family.

## 6. BESA-style source-space BCG removal — the concrete near-term target

Sketch of the pipeline, reusing what already exists in
[EVA/Cardiac/BCGDetector.swift](EVA/Cardiac/BCGDetector.swift):

1. Detect BCG event times (already done — GFP periodicity / spatial-PCA /
   cardiac power map / QRS-locking, all four implemented).
2. Build (or load a cached) lead field from a **spherical or template head
   model** — no MRI required for v1.
3. Project an exemplar window around each BCG event into source space via
   the lead-field pseudoinverse (this is just the MNE/minimum-norm math from
   §5, run once on a short window, not on the whole recording).
4. Identify the source components whose spatial pattern matches the known
   BCG cardiac topography (front-to-back, orbital/scalp-surface dominant —
   BESA's method and the existing `refineSpatialPCA`/OBS exemplar-refinement
   logic already characterize this in channel space; the source-space
   version does the analogous thing after the lead-field projection).
5. Zero/attenuate those source components, project back to channel space,
   subtract from (or replace) the original window.

This reuses the existing BCG detection and exemplar-refinement
infrastructure almost entirely — the new piece is steps 2–3 (lead field +
projection), which is exactly the "cheap, spherical, no-MRI" slice of the
bigger source-analysis problem. This is the natural **first shippable piece**
regardless of what happens with the larger EVA Resolve idea, and could
plausibly land as a mode inside the existing BCG panel rather than requiring
a new app at all.

## 7. Public code / license survey (for anything actually ported into Swift)

| Project | License | Relevant piece | Portability note |
|---|---|---|---|
| **MNE-Python** | BSD-3 | BEM solver, minimum-norm/dSPM/sLORETA/eLORETA, coregistration, forward modeling | Most permissive, most readable, already EVA's stated reference project (per [README.md](README.md)) — first choice to port from |
| **OpenMEEG** | CeCILL-B | BEM matrix assembly (C++) | More authoritative BEM math but harder to port (C++, less approachable); check CeCILL-B attribution terms if used as a reference |
| **FieldTrip** | Copyleft / GPL-family | Beamformers, dipole fitting, realistic head models | Useful as a validation/design reference, but denser MATLAB and less directly portable than MNE's Python |
| **EEGLAB / DIPFIT** | Copyleft / GPL-family | Dipole fitting UI/workflow | Dipole-fitting (single/few equivalent dipoles) is a *different* inverse paradigm from distributed LORETA-family and might be worth a mention as a third possible inverse mode later |
| **Brainstorm** | GPL | Full source pipeline UI/workflow reference | Useful for UI/workflow ideas (coregistration UX, head model caching), not for code porting given GPL/MATLAB mix |
| **FreeSurfer** | Custom (mostly permissive, non-commercial-ish clauses in places) | Individual segmentation | Treat as an optional external tool to *import from*, not a dependency to embed — see §3 |
| **nilearn / niBabel** style MRI I/O | BSD | NIfTI/DICOM reading for T1 import | Needed regardless of segmentation approach; Swift has no mature NIfTI reader today — likely a small from-scratch NIfTI-1 parser (simple format, well-specified) |

General rule: **port math/algorithms from BSD/permissive sources (MNE-Python
first choice); treat FieldTrip/EEGLAB/Brainstorm as design/validation
references, not code to translate line-by-line.** To be precise about why,
since license and portability are two separate axes:

- *Legally*, copyleft MATLAB projects need separate review before any code is
  adapted into EVA, which is now distributed as a public work rather than under
  a reciprocal software license.
- *Technically*, the real friction is that FieldTrip/EEGLAB/Brainstorm are
  MATLAB — dense vectorized indexing, implicit broadcasting, reliance on
  MATLAB-toolbox functions — which is genuinely harder to translate to Swift
  than MNE-Python's more explicit, well-tested, well-documented Python.

So the preference for MNE-Python is a translation-effort call (Python vs.
MATLAB), not a license workaround — BSD-3 is a nice-to-have (more future
flexibility if EVA's licensing ever changed) but not the deciding factor.

## 8. Pitfalls to expect

- **Numerical validation is the real cost, not the linear algebra.** Writing
  a BEM solver or a minimum-norm inverse in Swift is mechanical; *proving* it
  matches MNE-Python/FieldTrip on known test cases (sphere models have
  analytic ground truth — a good first validation target) is the actual
  work. Budget for a Swift-vs-MNE-Python numeric comparison test suite from
  day one. Note this cuts against how EVA has handled validation elsewhere —
  gradient correction deliberately does *not* chase reference-toolbox numerics
  (see ROADMAP.md) — so if source analysis needs reference parity, that's a
  new and heavier commitment, not the existing pattern.
- **Coregistration UX is fiddly and error-prone.** Aligning digitized
  electrode positions (or a generic montage) to a head model/MRI is a classic
  source of silent, hard-to-detect error (a few mm/degrees off produces
  plausible-looking but wrong maps). Needs its own careful UI, not just a
  "click three fiducials" afterthought.
- **No-MRI-by-default reality.** Most EEG (and even most EEG-fMRI) labs
  don't have a research-quality T1 registered to the EEG session. The
  template-head-model path is not a fallback — it's the primary path most
  users will actually hit. Design for that first, individual MRI as the
  enhancement.
- **EGI/MFF net registration quirks.** EVA already has hard-won institutional
  knowledge in `SensorLayout`/`ElectrodeGeometry` about handling EGI net
  coordinate conventions (y-flip issue tracked in the
  `mff-y-flip-shared-bug` memory). Any head-model coregistration work must
  reuse that existing geometry code rather than re-deriving electrode
  positions independently — a second, subtly-different electrode-position
  code path is a likely bug source.
- **Performance.** Lead-field computation and minimum-norm solves involve
  dense matrix operations over hundreds of source points/leadfield columns;
  needs Accelerate/BLAS-backed matrix ops (EVA already uses Accelerate
  elsewhere) rather than naive Swift loops, and lead fields should be cached
  per head-model/montage pair, not recomputed per recording.
- **Scope creep from "source analysis" meaning too many things at once.**
  BCG source-space removal, distributed imaging (LORETA family), and dipole
  fitting (DIPFIT-style) are three different features with different UIs and
  different validation needs. Worth treating as three separate roadmap items
  with the shared head-model/forward-model layer underneath, not one
  monolithic "add source analysis" project.
- **FreeSurfer version/format drift.** If FreeSurfer import is offered as an
  escape hatch (§3.4), its surface/volume formats have changed across
  versions; treat it as "read what we can, fail loud on unsupported
  versions," not a promise to support every FreeSurfer release.

## 9. Suggested phasing

1. **Spherical head model + lead field** (Swift, from scratch, no porting
   needed) — unblocks nothing user-visible yet but is the shared foundation.
2. **BCG source-space regression mode** inside the existing BCG panel
   (§6) — first shippable, reuses existing detection/refinement code,
   validates the lead-field math on a real, already-solved-in-channel-space
   problem before trusting it for anything else.
3. **Template BEM head model** (ICBM152/fsaverage-style precomputed
   surfaces, ported BEM math from MNE-Python) — unblocks a no-MRI
   minimum-norm/dSPM/sLORETA/eLORETA mode as a new feature (likely the start
   of "EVA Resolve" as its own target/app, per §2).
4. **T1 import + own lightweight segmentation**, with FreeSurfer-output
   import as the accuracy escape hatch — individual head models.
5. **Dipole fitting / LAURA / anything beyond the shared minimum-norm core**
   — only after (1)-(4) are validated and there's actual user demand.

Everything past step 2 is speculative and should be revisited once step 2
ships and there's a feel for actual user interest.
