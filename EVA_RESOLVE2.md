# EVA Resolve — Program Plan

**Goal:** EVA Resolve is a *focused sibling app* to EVA for EEG source analysis. It owns
everything that is about *where in the head* a signal comes from: the Source Simulator,
dipole fitting, distributed inverse imaging, head models built from a subject's NIfTI,
electrode coregistration, and (long term) FEM. EVA stays the recording editor and cleaning
pipeline. Both share IO and math through `EVACore/`.

Legend: `[x]` done · `[ ]` not started · `[~]` partially there today

---

## R0 — Foundation *(done 2026-09-02)*

- [x] **No new `.xcodeproj`.** Resolve is another target in `EVA.xcodeproj`, next to
  `EVA`, `EVASimulate`, `EVAQuickLook`, `EVAThumbnail`, `EVATests`, `EVAUITests`.
- [x] **Shared code lives in `EVACore/`**, an Xcode synchronized folder group attached
  to `EVA` and `EVASimulate` (later: Resolve). The 38 files EVASimulate used to borrow by
  per-file membership were moved there with sub-folders preserved. Same mechanism as
  `MFFPreviewKit/` and `EVAPreviewKit/`. No framework, no `public` pass; everything
  stays in the `EVA` module for tests.
- [x] **EVASimulate re-pointed** at the folder; per-file references deleted.
- [x] `Tools/EVABIDS/build.sh` and `Tools/EVAHelper/build.sh` re-pointed at new paths.
- [x] Verified: EVA, EVASimulate, EVATests build; 1542 tests pass; both tool scripts build.

**Why not a framework.** The candidate folders were not UI-free (`IO/` has 8 SwiftUI
files, `Simulation/` has controllers, `Models/` is only ICLabel), and a module boundary
would have forced a `public` pass over ~13k lines / ~2,300 declarations plus test-import
churn. The folder can become a framework later without moving anything again.

**Rule going forward:** anything visible to more than one app or tool goes in
`EVACore/`; anything importing SwiftUI/AppKit stays in the owning app's folder.

Current `EVACore/` layout (after R1–R2.3):

```
EVACore/
  Core/            AccelerateCompat, DSP, LinearAlgebra, SeededGenerator
  Core/Forward/    ForwardTypes, SphericalForwardModel, EllipsoidalForwardModel, BEMForwardModel
  Geometry/        HeadTransform (frames, Umeyama fit, SVD3), TriangleMesh + SurfaceIndex
  Imaging/         VolumeMorphology (BinaryVolume, VolumeOps)
  Registration/    SurfaceRegistration (ICP, projection, template scalp fit)
  IO/              EGISensorXMLParser, MFFFileType, MFFReader, MFFWriter
  IO/NIfTI/        NIfTIHeader, NIfTIByteSource, NIfTIScalarDecoder, NIfTIVolume (+ writer)
  IO/GIFTI/        GIFTIPreviewModel, GIFTIQuickLookReader, GIFTICompanionSurfaceResolver
  IO/FIF/          FIFFile (tags), FIFInterop (trans, digitization, BEM surfaces)
  Channels/        ElectrodeGeometry, SensorLayout, ElectrodePositions, StandardMontage(+Data)
  Epoching/        EpochModel
  Pipeline/        EVAProcessingScript
  Simulation/      generators, artifact models, config/scenario types, Montage,
                   SingleDipoleFit, SourceSimulatorNoise, SourceSimulatorArtifacts
  Artifacts/SourceInformed/  SourceInformedOperator
```

---

## What already exists (the inventory the rest of the plan builds on)

| Asset | Where | State |
|---|---|---|
| Analytic 3-shell spherical forward (60-term series, free-orientation lead field) | `EVACore/Core/Forward/SphericalForwardModel` | shipped, tested vs. ground truth |
| Ellipsoidal forward | `EVACore/Core/Forward/EllipsoidalForwardModel` | shipped |
| Constant-collocation double-layer BEM, Van Oosterom solid angles, Lynn–Timlake deflation, icosphere mesher | `EVACore/Core/Forward/BEMForwardModel` | shipped, converges to sphere; 3-shell 1:80 skull error 11%→1.65% by mesh level (no isolated-skull approach yet) |
| `ForwardDipole`, `SimulatedSource`, `LeadField`, `EEGReference`, `Vector3D` | `EVACore/Core/Forward/ForwardTypes`, `EVACore/Simulation/SimulationForwardDomain` | shipped |
| Single / multiple / spatio-temporal / shared-geometry ECD fit (grid search, sphere only) | `EVA/Simulation/SingleDipoleFit` | shipped (ROADMAP Stage 3c); slow (Stage 3c-perf not started) |
| Source Simulator window: glass-brain, live scalp field, activations, noise + truth scoring, Fit mode | `EVA/App/SourceSimulatorWindowView`, `HeadProjectionView`, `ScalpFieldView`, `SourceButterflyView`, `SourceFitModeView`, `SourceTimelineView`; `EVA/Simulation/SourceSimulatorController`, `…Noise`, `…Artifacts` | shipped, Stages 1–3c |
| "Fit Source Model" bridge from a recording's averaged butterfly/topography into the Source window | `EVA/Waveform/WaveformSourceFit`, `EVA/App/PendingSourceFit` | shipped; in-process Notification handoff |
| EGI `coordinates.xml` true 3-D electrode positions (unit sphere) | `EVACore/Channels/ElectrodeGeometry` | shipped; **fiducial entries (type 2) are parsed and discarded** |
| 10-20 style synthetic montages | `EVACore/Simulation/Montage` | shipped |
| NIfTI-1/2 reader: gzip, all common datatypes, qform/sform affine | `EVAPreviewKit/NIfTI/*` | shipped for QuickLook; not yet in `EVACore/` |
| GIFTI surface reader + SceneKit surface renderer | `EVAPreviewKit/GIFTI/*` | shipped for QuickLook; not yet in `EVACore/` |
| Surrogate-source BCG separation (29 regional sources, sphere lead field) | `EVA/Artifacts/SourceInformed/SurrogateBrainBasis`, `EVACore/…/SourceInformedOperator` | shipped; **stays in EVA** (it is cleaning, not localization) |
| ROADMAP Tier 6 design for source grids and the minimum-norm family | `ROADMAP.md` §6.1–6.5 | design only |

---

## R1 — Stand up the EVA Resolve target and move the Source Simulator out of EVA  *(done 2026-09-02)*

Goal: EVA has zero source-localization UI; Resolve opens with the Source Simulator working
exactly as it does today, and "Fit Source Model" in EVA opens Resolve instead of an EVA
window.

- [x] **New macOS App target `EVAResolve`** (display name "EVA Resolve"), folder
  `EVAResolve/`, bundle ID `gov.nih.nimh.cmn.eva.resolve`, own Info.plist (registers the
  `.mff` document type) and asset catalog (EVA's icon for now). `EVACore` attached via
  `fileSystemSynchronizedGroups`. `EVAResolveTests` bundle hosted in the app; scheme
  `EVAResolve` builds and tests it.
- [x] **Moved to `EVACore/Simulation/`:** `SingleDipoleFit`, `SourceSimulatorNoise`,
  `SourceSimulatorArtifacts`.
- [x] **Moved to `EVAResolve/Simulator/`:** `SourceSimulatorWindowView`,
  `HeadProjectionView`, `ScalpFieldView`, `SourceButterflyView`, `SourceFitModeView`,
  `SourceTimelineView`, `PendingSourceFit`, `SourceSimulatorController`; tests to
  `EVAResolveTests/`. Nothing else had to move — the views only used `EVACore` types.
- [x] **Handoff is a file, not a URL scheme.** `WaveformSourceFit` in EVA writes the
  averaged conditions as an averaged `.mff` (MFFWriter carries coordinates.xml /
  sensorLayout.xml across) plus an `eva-resolve-fit.json` sidecar naming the viewed
  sample, then asks Launch Services to open the package in Resolve. Opening a document
  through Launch Services is what grants the sandboxed Resolve access to it, so no app
  group or scheme is needed. Resolve's `SourceFitImporter` rebuilds the `FitDataset`
  from any averaged MFF (EVA handoff, Finder, or File ▸ Open — one code path).
  Round-trip covered by `SourceFitImporterTests`.
- [x] Generated recordings from the simulator open in EVA via Launch Services (falls
  back to the default `.mff` handler).
- [x] `EVAApp.swift` no longer has the Source Simulator scene, controller, or menu
  item. "Fit Source Model" reports "EVA Resolve is not installed" in the status log
  when Launch Services cannot find the bundle ID.
- [ ] Help: no Source Simulator help page existed in EVA's help book, so nothing to
  move; write Resolve's help when the UI settles.

Exit criterion met: EVA builds with no reference to `SourceSimulator*` or
`SingleDipoleFit`; `EVAResolveTests` (simulator + importer) pass.

---

## R2 — Head frame, NIfTI in core, and electrode coregistration  *(R2.1–R2.3 done 2026-09-02; R2.4 UI pending)*

Everything in R3–R6 needs one coordinate frame, a volume reader in core, and a way to put
the electrodes on a head. Built once, in `EVACore/`, validated against nibabel and
MNE-Python from the `mne` micromamba env (`Tools/resolve-validate/`).

**Units and frames (decided):** geometry is in **metres** everywhere in `EVACore/`
(forward models, `HeadTransform`, `ElectrodePositions`, meshes), matching MNE. `NIfTIVolume`
keeps its affine in millimetres (NIfTI-native) and exposes `voxelToWorldMeters`.
`CoordinateFrame` uses the FIFF numbering (head = 4, mri = 5, …) so transforms round-trip
to MNE without translation.

### R2.1 Volume and surface IO into `EVACore/`  — done
- [x] `NIfTIHeader`, `NIfTIByteSource`, `NIfTIScalarDecoder` moved from `EVAPreviewKit/` to
  `EVACore/IO/NIfTI/`; GIFTI model, reader and companion resolver to `EVACore/IO/GIFTI/`.
  `EVACore` is now also attached to `EVAQuickLook` / `EVAThumbnail`; `EVAPreviewKit` is
  attached to `EVA` (it declares the NIfTI/GIFTI document types) and dropped from
  `EVATests`, whose reader tests reach the code through the host app.
- [x] `NIfTIVolume`: whole-volume load (first 3-D volume, slope/intercept applied, fast
  paths for float32/int16/uint16/uint8), voxel↔world, trilinear sampling, **RAS
  canonicalization** without resampling, NIfTI-1 writer (float32/int16/uint8, sform +
  qform, gzip). Tests: nibabel-generated RAS / LAS / PIR / qform-only-int16 phantoms with a
  left-marker cube all canonicalize to the same voxels and world positions; write→read
  round trip; nibabel reads what we write (`check_swift_nifti.py`).
- [x] `VolumeMorphology`: `BinaryVolume` (ball dilate/erode, open/close, 6/26 connected
  components, largest component, hole fill, surface voxels, centroid/bbox) and `VolumeOps`
  (thresholds, Otsu, separable Gaussian, isotropic resampling).
- [x] `HeadTransform` + `CoordinateFrame` + `SVD3`: Umeyama/Kabsch fit (rigid or
  similarity) matching MNE `fit_matched_points` to 1e-6 (rigid) and to the optimizer's
  1e-5 (scale; our closed form has the lower residual). Rank-2 (three fiducials) handled
  exactly.

### R2.2 Electrode positions with fiducials  — done
- [x] `ElectrodePositions` (metres; EEG / reference / nasion / LPA / RPA / head-shape
  points) with readers for EGI `coordinates.xml` (cm; fiducials by identifier 2002/2011/2010
  — `EGISensorXMLParser` now keeps `<identifier>`), BESA `.sfp`, ASA `.elc`, Cartool `.xyz`,
  CSV/TSV/TXT; unit auto-detection; fiducial aliases across conventions. Validated against
  MNE `read_custom_montage` on the same files for every format.
- [x] `HeadTransform.headFrame(nasion:lpa:rpa:)` = MNE `get_ras_to_neuromag_trans`
  (matches to 1e-9); `ElectrodePositions.inHeadFrame()`.
- [x] `toGeometry()` / `toMontage()` feed the existing spherical forward models.
- [x] Bundled templates: idealized spherical 10-20 / 10-10 / 10-05 (`StandardMontage`,
  generated from eeg_positions data via MNE, BSD-3, `export_montages.py`). EGI HydroCel
  nets are deliberately not bundled — every MFF carries `coordinates.xml`.

### R2.3 Coregistration engine and MNE interop  — done
- [x] `TriangleMesh` (normals, area/volume, icosphere) and `SurfaceIndex` (uniform-grid
  exact closest point, verified against brute force).
- [x] `SurfaceRegistration`: fiducial alignment → ICP to the scalp surface (rigid or
  similarity, trimming, distance cap), projection onto the surface, and
  `fitTemplateScalp` for the no-MRI path (recovers an 8 % head-size change to <1 %).
  With fiducials the pose is recovered to <1 mm on the fsaverage scalp; blind ICP from
  a centroid start lands points on the scalp but, as expected, cannot pin rotation on a
  symmetric head.
- [x] **MNE FIF interop** (`EVACore/IO/FIF/`): tag reader/writer; `-trans.fif` read/write
  (`HeadTransform`), fiducials / `-dig.fif` read/write (`Digitization`,
  `ElectrodePositions`), `-bem.fif` / `-head.fif` read/write (`BEMSurface`). fsaverage
  trans, fiducials, head and 3-shell BEM read identically to MNE; MNE reads our trans,
  dig and BEM files and `make_bem_solution` accepts our surfaces (`check_swift_fif.py`).

Validation workflow: `Tools/resolve-validate/make_fixtures.py` (MNE env) regenerates
`EVATests/Fixtures/Resolve/` and copies fsaverage surfaces into the git-ignored
`Fixtures/Resolve/local/` (the sandboxed test host cannot read `~/Desktop`, where MNE
keeps its data). After the Swift tests, `check_swift_nifti.py` and `check_swift_fif.py`
read the Swift-written files back with nibabel / MNE.

### R2.4 Coregistration UI (Resolve)  — first pass built 2026-09-02, **UI brainstorm pending**
- [x] `HeadModelController` (`EVAResolve/HeadModel/`): T1 load (canonicalized) with a
  quick **star-shaped scalp** from the head mask (`ScalpFromVolume`, a stand-in until
  R3's marching cubes), scalp from MNE `-head.fif` / GIFTI, fiducials by clicking or from
  `-fiducials.fif`, electrodes from any `ElectrodePositions` format / MNE dig / template
  montage, fiducial alignment + ICP (scale optional, trimming), nudge (rotate / move /
  scale about the electrode centroid), refine-from-pose, snap-to-scalp, MNE exports.
- [x] `MRISliceView`: three orthogonal planes (canonical volume, anatomical-positive
  up, labelled L/R/A/P/S/I), click-to-pick fiducials, scalp contour, electrodes near the
  plane coloured by residual, brightness slider.
- [x] `CoregistrationSceneView`: SceneKit scalp (translucent) + electrode spheres
  coloured by residual + fiducials + RAS axes, orbit camera.
- [x] `HeadModelWindowView`: 2×2 viewports (axial, coronal, sagittal, 3-D) plus a
  five-step inspector (MRI → Fiducials → Electrodes → Fit → Save/Export). File ▸ New
  Head Model (⇧⌘H) in `EVAResolveApp`.
- [x] **`.evahead` package** (`HeadModelDocument`): `manifest.json`, `t1.nii.gz`,
  `scalp-head.fif`, `electrodes-dig.fif`, `head-mri-trans.fif` — every piece in a format
  MNE reads directly. Save / open round-trips through the controller.
- [x] End-to-end test on fsaverage (`HeadModelControllerTests`): T1 → scalp within a few
  mm of MNE's watershed head above the ears; fiducials + scaled 10-10 template fit;
  snap; nudge/refine; package round trip.
- [ ] **Brainstorm the UI with the owner** before polishing: window structure (one
  head-model window vs. a study/project document), the fiducial-picking interaction,
  whether the 3-D view should be the primary surface with slices secondary, residual
  presentation, and how the head model is handed to Fit mode / inverse imaging.
- [ ] Cached lead fields in the package (R4), `.evahead` document type registration,
  drag-and-drop of NIfTI / .mff onto the window, undo for nudges.

---

## R3 — BEM head models from a subject's NIfTI

Target: a clean adult T1 in, a validated 3-shell BEM out, with no external tools. Skull
is the hard tissue (dark like air on T1), so the pipeline mirrors what `mne
watershed_bem` does rather than pure intensity segmentation. Port math from MNE-Python
(BSD-3) and the published papers; FieldTrip/Brainstorm/FSL are design references only.

### R3.1 T1 preprocessing (`EVACore/Segmentation/`)
- [ ] Intensity normalization and robust range clipping.
- [ ] Bias-field correction: a lightweight N4-style iterative B-spline/polynomial fit is
  enough for shell segmentation. Validate on BrainWeb phantoms (public, free).
- [ ] Optional 1 mm isotropic resample.

### R3.2 Three-compartment segmentation
- [ ] **Head (outer skin) mask**: Otsu/percentile threshold on the normalized T1 →
  largest connected component → hole fill → light closing. Straightforward.
- [ ] **Brain mask**: implement the BET deformable-surface algorithm from Smith (2002)
  — an icosphere inflated under local intensity forces. No FSL code (FSL's license is
  non-commercial). Alternative/fallback: watershed on the gradient image seeded at the
  centre of mass, which is what MNE's watershed BEM uses.
- [ ] **Inner skull**: brain mask dilated by a few mm and smoothed.
- [ ] **Outer skull**: head mask eroded by a minimum scalp thickness, constrained to lie
  outside inner skull by a minimum skull thickness (MNE's approach). Not "real"
  skull, but adequate for 3-shell BEM, which only needs three smooth nested boundaries.
- [ ] Quality gates: nesting, minimum inter-surface distance, volume sanity ranges, and
  a slice overlay in the UI so the user sees exactly where the boundaries landed.
- [ ] Later accuracy upgrade (separate phase): atlas-based tissue priors by affine
  registration of ICBM152 (needs a mutual-information affine registration step, which
  is also what FreeSurfer-free skull estimation wants).

### R3.3 Surface extraction and mesh conditioning (`EVACore/Mesh/`)
- [ ] Marching cubes on each mask → triangle mesh.
- [ ] Taubin smoothing (does not shrink like plain Laplacian).
- [ ] Quadric-edge-collapse decimation to a chosen triangle budget (default 2562/5120
  per shell, matching the icosphere levels already validated).
- [ ] Checks: closed, consistently oriented (outward normals), no self-intersections,
  shells do not intersect each other. Fail loudly with a picture.
- [ ] Optional: replace marching-cubes topology by projecting an icosphere onto each
  mask boundary (gives regular, nested, guaranteed-genus-0 meshes; it is what the BEM
  tests already use). Probably the better default for BEM.

### R3.4 BEM solver upgrades (`EVACore/Core/Forward/`)
- [ ] **Isolated Skull Approach** (Hämäläinen & Sarvas 1989) — needed for realistic
  1:80 skull ratios; the current plain double-layer BEM is 11% at coarse mesh.
- [ ] **Linear collocation** elements (MNE default) as an option next to the existing
  constant elements.
- [ ] Dense solve through LAPACK (`AccelerateCompat`), and cache the inverted system
  matrix per head model so per-source evaluation is a matrix–vector product.
- [ ] Electrode potentials by interpolation on the outer-surface triangle containing
  the projected electrode, not nearest-centroid.
- [ ] `ForwardOperator` protocol (`leadField(sources:) -> LeadField`) adopted by
  spherical, ellipsoidal, BEM, and later FEM, so every consumer (fit, inverse,
  simulator) is head-model-agnostic.

### R3.5 Validation and bundled template
- [ ] Extend the existing sphere-convergence tests to IPA and linear collocation.
- [ ] `Tools/forward-compare/`: a small MNE-Python script and fixture (MNE sample
  subject or ICBM152 surfaces) that dumps a lead field for a fixed dipole set;
  Swift test asserts agreement within tolerance. This is the real cost of R3; budget
  for it from the first commit.
- [ ] Bundle ICBM152 template surfaces (scalp/outer skull/inner skull) as a resource
  with attribution; verify the license of whichever surface set is shipped (ICBM152
  is fine; fsaverage-derived surfaces carry the FreeSurfer license — avoid).

---

## R4 — Distributed inverse imaging

Follows ROADMAP Tier 6 (§6.1–6.5) almost verbatim; that design holds. None of this
needs a BEM to start — the sphere lead field is the exact gain matrix — so R4 can begin
in parallel with R3 once R2.1 lands.

- [ ] **6.1 `SourceGrid`**: regular grid clipped to the inner-skull compartment (sphere
  or BEM), fixed or free orientation, deterministic ordering, neighbourhood Laplacian,
  and a cached gain matrix (`channels × 3N`) keyed by head model + montage + reference.
  Later: cortical surface source space from a GIFTI/FreeSurfer surface with
  normal-constrained orientation.
- [ ] **6.2 Minimum-norm family engine**: one operator builder parameterized by
  weighting → MNE, dSPM, sLORETA, eLORETA. Noise covariance from a baseline window
  (with shrinkage), or supplied exactly by the simulator. Regularization as a declared,
  sweepable parameter (fixed λ, L-curve, GCV).
- [ ] **6.3 Spatial priors**: LORETA (Laplacian) and LAURA (local autoregressive) via
  the grid neighbourhood structure. Compartment-edge handling gets its own tests.
- [ ] **6.4 Resolution metrics**: resolution matrix, point-spread, cross-talk, peak
  localization error, spatial dispersion — computed without a simulation run.
- [ ] **6.5 Inverse-crime controls**: generate with one head model, invert with another
  (sphere parameter mismatch first; BEM-vs-sphere once R3 exists). Every result labels
  its regime.
- [ ] **UI**: source-space viewer as MRI slice overlays (volumetric grid) and surface
  colouring (cortical space), time scrubber, threshold/percentile controls, per-method
  tabs on the same data, export of source time courses and maps (NIfTI for volumes,
  GIFTI `.func.gii` for surfaces so AFNI/SUMA can open them directly).

---

## R5 — Dipole fitting on real data

Today's `SingleDipoleFit` is a diagnostic against simulated truth on a sphere. Turn it
into the production ECD tool.

### R5.0 Fit-mode UI direction — decided and built 2026-09-05

**Built:** the Workbench layout in both modes (2+1 head grid: axial + coronal above,
sagittal below), anatomical head silhouettes (`EVAResolve/Simulator/HeadSilhouette.swift`
— outline, ear arcs and neck in box space, with a per-plane `Layout` that seats the
brain sphere in the cranium so the neck can hang below), drag-to-seed-then-refit
(optional `seeds:` on `fitSharedGeometry`), an explicit **Fit button** with a
determinate progress bar, verbose per-phase messages and cancellation
(`SingleDipoleFit.ProgressReporter`, threaded into the chunked `covarianceSearch`),
a resizable timeline splitter in Simulate, and the three waveform panels below.

**Waveform panels (right column).** Measured butterfly → **source waveforms** (each
dipole's moment over time, conditions overlaid) → **residual components**. The residual
PCA is deliberately computed on the *unexplained* field: `SingleDipoleFit.decompose`
projects the data through the fitted lead field, subtracts the modelled field, and
eigendecomposes what is left, reporting each component's share of the ORIGINAL variance.
So placing dipoles that explain the highlighted interval makes those components shrink,
and whatever remains is structure still to be modelled. Covered by
`decompositionTracksUnexplainedVariance` (3 dipoles explain >95% of the noiseless demo
field; 1 dipole leaves strictly more residual).

Still open: no residual-component *topography* is drawn yet (the data is computed);
`fitSeedPositions` is view-agnostic but only Fit mode drags it.

Original decision record follows.


Brainstormed three window layouts for the `.fit` side of the existing `Simulate | Fit`
`Picker` in `SourceSimulatorWindowView` (that master switch already exists — see
`SourceSimulatorController.WindowMode`; this is about what `SourceFitModeView` shows,
not a new window). Sketches: `resolve-layouts.html` (published as a Claude artifact,
not checked into the repo).

**Chosen: "Workbench"** — three fixed panes, always visible, no drawer/mode switching:
- Left: condition list (extends the per-condition concepts already in
  `FitConditionPalette`; today there's no dedicated chooser control, just legends).
- Center: the glass head, replaced by **three linked orthogonal views** — axial,
  sagittal, coronal — stacked vertically, each a generic head silhouette (not real MRI)
  around the same skull/brain rings. A dipole dragged in any one view updates one shared
  `(x, y, z)` per source, so the other two views move with it immediately.
- Right: waveform panel with a **raw / PCA / both** toggle (new — no PCA toggle exists
  in EVAResolve's `Waveform` view today).

Rejected: "Split Stage" (waveform + single head side by side, closest to today's shape
but the head gets small on a laptop) and "Head-First Drawer" (head as hero, waveform in
a bottom drawer — good for skimming many fits, worse for careful raw-vs-PCA QC).

**Open questions to resolve before implementation:**
- The sketch draws one fixed sphere behind all three head silhouettes (a sphere's
  silhouette is a circle from any angle, so this is free in the mockup). The real head
  model (R3's BEM, or even R2's ellipsoid) is not a sphere — each of the three views
  would need its own slice of the actual geometry, not one shared circle.
- Whether dragged sources clamp to a free sphere interior (as sketched) or to the real
  source space / grey-white boundary once R4's `SourceGrid` exists.
- Whether the views need a numeric (x/y/z or mm) readout for precision editing, or stay
  drag-only.

- [ ] **Head-model agnostic**: fit against any `ForwardOperator` (R3.4), including BEM.
- [~] **Stage 3c-perf** from ROADMAP: precomputed free lead-field grid per geometry,
  trilinear interpolation, Levenberg–Marquardt / Nelder–Mead refinement from the grid
  seed, Accelerate for the linear moment solves. Target: single ECD instant, multi-ECD
  sub-second.
  - [x] **First pass done 2026-09-05 — 6.4× (40.87 s → 6.34 s)** on the benchmark
    (64 channels, 256 samples, 2 conditions, 3 dipoles; `benchmarkSharedFit`). All 35
    EVAResolve tests still pass, so positions/GOF are unchanged — only the cost moved.
    Three changes, none of them the ROADMAP items above:
    1. **Flat buffers.** The candidate loop was allocating one small `[Double]` per
       channel per candidate (~70k allocations per dipole search). Designs are now
       flat row-major with preallocated per-worker scratch.
    2. **Rank-reduced covariance.** `C ≈ W·Wᵀ` keeping `3·dipoles + 8` components, so
       the objective is `LᵀCL = (WᵀL)ᵀ(WᵀL)` at O(r·C·p) instead of forming `C·L` at
       O(C²·p). A model with `p` free spatial dimensions cannot explain more than `p`
       components, so this is the standard signal-subspace argument. Search-only:
       `finalize` still uses the exact full covariance, so reported GOF is untouched.
    3. **Parallel candidate scan.** Note the ordering trap: parallelising only the
       scoring gave just 2.1×, because `freeLeadField` still ran serially ahead of the
       parallel region. Each worker must solve the forward model for *its own slice* —
       the spherical-harmonic series is the dominant cost, not the linear algebra.
       That took it from 19.5 s to 6.34 s.
  - [x] **Second pass done 2026-09-05 — 43× on cached fits (40.87 s → 0.95 s),
    14× on a cold one (2.88 s).** Single ECD is 0.18 s, so the ROADMAP's "single
    ECD instant, multi-ECD sub-second" target is met once the grid is warm.
    All 35 EVAResolve tests still pass.
    - **Phase timing** added to `ProgressReporter` (`PhaseTimings`), which is how
      each step below was targeted instead of guessed. Reachable from tests via
      `runSharedFitNow(reporter:)`.
    - **Reduced harmonic order in the search** (24 terms, vs the caller's 60 for
      `finalize` / `deflateCovariance` / `decompose`, which stay exact): 6.13 s →
      3.56 s. Sources are clamped to 0.97 R, well inside the shell, where the
      series has converged by ~24 terms.
    - **Precomputed lead-field grid** (`LeadFieldGrid`) at `brainRadius/12`,
      trilinear interpolation, `Float` storage, cached per geometry (≈19 MB at 64
      channels, ≈75 MB at 256; at most 3 kept). Candidate scoring stops solving
      the forward model entirely: refinement 2.42 s → 0.59 s, coarse 0.95 s →
      0.24 s. Nodes at/outside the innermost shell are unsolvable, so they are
      marked invalid and the few candidates needing them fall back to an exact
      solve; `finalize` is always exact.
    - **Hoisted fixed-dipole blocks** in the joint objective (`FixedBlocks`):
      exact, but a modest ~10% — the refinement was forward-bound, not
      objective-bound.
    - Measured trap, twice: *anything solved serially ahead of a parallel region
      becomes the bottleneck.* First on `freeLeadField` before the candidate scan,
      then again on the grid build itself (5.99 s serial → 1.79 s parallel).
  - **Not needed after the above:** Levenberg–Marquardt / Nelder–Mead refinement
    and RAP-MUSIC seeding. With the grid warm, refinement is 0.59 s and the coarse
    search 0.24 s; replacing either would be significant algorithmic risk for a
    fraction of a second. Revisit only if a realistic BEM (R3) makes per-candidate
    evaluation expensive again — at which point the grid is the thing that scales,
    not the search strategy.
  - [ ] Remaining cost is the one-time grid build (1.89 s, 66%). If that matters,
    build it lazily in the background when a dataset loads, or coarsen the lattice
    and lean on the exact final refinement.
- [ ] **PCA-driven model order**: SVD of the channels × samples window; show the
  explained-variance ladder; seed one dipole per retained component (Scherg-style
  spatio-temporal model), then jointly refine positions with fixed or rotating
  orientations. Extend `fitSpatioTemporal` / `fitSharedGeometry`, which already hold the
  shared-geometry, per-condition-moment structure.
- [ ] **Regional sources** (three orthogonal dipoles at one location) as a fit type.
- [ ] Residual variance over time, goodness-of-fit per interval, confidence volumes
  (Hessian-based), symmetric dipole-pair constraint, and "fit this interval" interaction
  in the butterfly plot.
- [ ] Export dipoles (position, orientation, moment time course) as JSON and as a
  NIfTI marker volume in the head model's frame.

---

## R6 — FEM (long term)

Decision to record now so R2–R3 do not paint us into a corner:

- [ ] **Hexahedral, voxel-based FEM** (as in SimBio/DUNEuro's hex mode, optionally with
  geometry-adapted node shifting), not tetrahedral. It needs no volumetric mesher, so
  it sidesteps TetGen (non-free) and Gmsh (GPL, heavy). The segmentation from R3.2 is
  the mesh.
- [ ] Segmentation extension to 5–6 tissues (scalp, compact skull, spongy skull, CSF,
  grey, white). Realistically atlas-prior based (the R3.2 "later" item) — this is the
  bulk of the FEM effort, not the solver.
- [ ] Solver: assemble the sparse SPD stiffness matrix; solve with Accelerate Sparse
  Solvers (preconditioned CG); **reciprocity** — one solve per electrode giving a
  transfer matrix, then any source is a dot product. Venant or partial-integration
  source model.
- [ ] Optional anisotropy from DTI tensors (rare in EEG sessions; keep the interface,
  defer the implementation).
- [ ] Validation: 4-layer analytic sphere; then the BEM-vs-FEM comparison on the same
  subject, which is itself a Tier 6.5 inverse-crime study.
- FDM on the voxel grid is the fallback if hex FEM proves too slow at 1 mm.

---

## Sequencing and parallelism

```
R0 done ─► R1 (target + move simulator)  ─► R2.1 NIfTI/GIFTI into core
                                         │
                       ┌─────────────────┴──────────────────┐
                       ▼                                    ▼
             R2.2–R2.4 electrodes + coreg         R4 inverse on sphere grid
                       │                                    │
                       ▼                                    ▼
             R3 BEM from NIfTI  ─────────────────► R4 on BEM, R5 on BEM
                       │
                       ▼
             R6 FEM (hex, atlas-prior segmentation)
```

- R1 is a pure move; do it next and keep it to one PR-sized change.
- R2.1 is small and unblocks both branches.
- R4 (sphere) and R2.2–R2.4 are independent and can interleave. R4 on the sphere is
  shippable science on its own (ROADMAP Tier 6's argument) and does not wait on R3.
- R3 is the long pole; R3.5 validation tooling should be built alongside R3.2, not
  after.
- R5's perf work (3c-perf) can be done any time after R1; its PCA/multi-dipole work
  wants R3.4's `ForwardOperator` first.

## Membership map (what lives where when this is done)

| Folder | Targets | Content |
|---|---|---|
| `EVACore/` | EVA, EVASimulate, EVA Resolve, tests | IO (MFF, NIfTI, GIFTI, electrode files), forward models, segmentation, meshing, registration math, source grids, inverse operators, dipole fit, simulation generators |
| `EVA/` | EVA | recording editor, cleaning pipeline (incl. surrogate-source BCG), epoching, exports; "Fit Source Model" launcher only |
| `EVAResolve/` | EVA Resolve | head-model documents, coregistration UI, Source Simulator, dipole-fit UI, inverse-imaging UI |
| `Tools/EVASimulate/` | EVASimulate | CLI generation/scoring; gains inverse scoring from `EVACore/` for free |

## Licensing notes to keep honest

- Port from MNE-Python (BSD-3) and from papers (BET: Smith 2002; IPA: Hämäläinen &
  Sarvas 1989; BEM: Geselowitz / Van Oosterom; hex FEM: Wolters et al.). No code from
  FSL, FreeSurfer, FieldTrip, EEGLAB, Brainstorm, or TetGen.
- Bundled templates: ICBM152 (free with attribution). Avoid fsaverage-derived surfaces.
- Record every ported algorithm in `THIRD_PARTY_NOTICES.md` as it lands.
