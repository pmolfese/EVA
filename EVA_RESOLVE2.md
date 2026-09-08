# EVA Resolve — Program Plan

**Goal:** EVA Resolve is a *focused sibling app* to EVA for EEG source analysis. It owns
everything that is about *where in the head* a signal comes from: the Source Simulator,
dipole fitting, distributed inverse imaging, head models imported from MNE / OpenMEEG
(and later DUNEuro), electrode coregistration, and (long term) FEM. EVA stays the recording editor and cleaning
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
| Constant-collocation double-layer BEM, Van Oosterom solid angles, Lynn–Timlake deflation, icosphere mesher | `EVACore/Core/Forward/BEMForwardModel` | shipped, converges to sphere; 3-shell 1:80 skull error 11%→1.65% by mesh level. **Generation-side / inverse-crime use only** as of 2026-09-06; subject BEMs are imported (R3) |
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

## R3 — BEM head models **imported** from MNE / OpenMEEG  *(direction changed 2026-09-06)*

**Decision.** EVA Resolve does not build BEMs. Segmentation, surface extraction and the
BEM solve are mature, validated, freely licensed work in MNE-Python and OpenMEEG, and
re-deriving them is the single largest cost in this plan for the least differentiated
result. Resolve **imports** a finished head model and owns everything downstream of it:
coregistration, the forward operator, dipole fitting, inverse imaging, and the
simulate↔fit comparison. FEM (R6) follows the same rule, importing from DUNEuro.

What survives from the old R3, and why:

- The NIfTI reader, `HeadTransform`, `SurfaceRegistration` and the `.evahead` package
  (R2) are **not** wasted — an imported BEM is in the subject's MRI frame and is useless
  until the electrodes are coregistered to it. That transform is the thing only Resolve
  can compute, because only Resolve knows where the electrodes are.
- `BEMForwardModel` (our own constant-element solver on icosphere shells) **stays**, in
  its current role: a *generation-side* forward operator for inverse-crime studies
  (SI-4 / R4.5), where the point is that it is not the analytic sphere. It is not on the
  path to subject BEMs any more, so IPA and linear collocation drop off the plan.
- Dropped entirely: T1 preprocessing/bias correction, BET/watershed brain extraction,
  skull estimation, marching cubes, Taubin smoothing, quadric decimation, atlas priors.

**What the user does outside EVA** (documented, with a copy-pasteable recipe):

```
mne watershed_bem -s subject -d $SUBJECTS_DIR        # or FLASH / SimNIBS / FieldTrip
python -c "import mne; mne.write_bem_solution('subject-bem-sol.fif',
           mne.make_bem_solution(mne.make_bem_model('subject'), solver='mne'))"
```

`solver='openmeeg'` writes the same file with an OpenMEEG-computed solution, so one
importer covers both engines. That is the whole external dependency.

---

### R3.1 Import the geometry (surfaces + conductivities)  *(done 2026-09-06)*

- [x] MNE `-bem.fif` / `-head.fif` surfaces (`BEMSurface.readFIF`, R2.3) — already read
  and written, fsaverage-validated.
- [x] `BEMGeometry` (`EVACore/Core/Forward/BEMGeometry.swift`): shells stored
  **inner → outer** whatever the file's order, one `CoordinateFrame`, and `Provenance`
  (source file, format, solver, approximation, subject, note). Reads from every file
  MNE writes surfaces into — geometry-only `-bem.fif`, `-head.fif`, and either
  solver's `-bem-sol.fif` — and writes back in MNE's outer-first order.
- [x] OpenMEEG native geometry (`EVACore/IO/OpenMEEG/OpenMEEGGeometry.swift`): `.geom`
  + `.cond` with `.tri`, `.off` and `.bnd` meshes, read and written. Conductivities are
  resolved through OpenMEEG's **signed** domain bounds (`-Interface` = the domain
  inside it), not by name matching — an interface bounds two domains and only one of
  them is the sigma FIF means.
- [x] **OpenMEEG's `.tri` winding is the reverse of MNE's**, established by experiment,
  not documentation: hand it a mesh wound MNE's way and it announces "Global
  reorientation of interface …" and assembles a head matrix ~3e-4 different. The
  per-vertex normals in the file are ignored; only the winding is read. EVA writes the
  reversed winding and normalizes anything it reads back to outward normals.
- [x] Quality gates, as a list of pass/warning/failure `Check`s the UI can show, never
  a silent pass: closed and manifold (every edge in exactly two triangles), genus 0
  (Euler characteristic), outward normals (signed volume), nesting inner ⊂ outer with a
  2 mm separation warning, self-intersection (grid-accelerated Möller triangle pairs,
  `EVACore/Geometry/TriangleMeshIntersection.swift`), conductivity positivity and skull
  ordering, plausible compartment volumes (which is what catches millimetre input).
- [x] Validated both directions: 14 tests in `EVATests/IO/BEMImportTests.swift` covering
  the three FIF variants, each gate against a deliberately broken model, the OpenMEEG
  round trip and all three mesh formats — and
  `Tools/forward-compare/check_swift_openmeeg.py`, which loads what EVA wrote with
  **OpenMEEG itself**: `selfCheck` and `is_nested` pass, `om.HeadMat` assembles
  1126×1126, no reorientation.
- [ ] fsaverage at ico2 legitimately trips the separation warning (outer skull within
  1.5 mm of the scalp). Right answer, but the threshold wants a look against real ico4
  models before the UI shows it to anyone.

### R3.2 Import the BEM *solution*

This is the part that makes the import worth doing: with the solution matrix in hand we
can evaluate a forward field for **any** dipole, not just the source space someone else
chose.

> **Found 2026-09-06 while building the R3.5 fixtures: only `solver='mne'` solutions
> are importable as *operators*.** MNE writes an OpenMEEG solution into the same
> `-bem-sol.fif`, but it is a different object: the symmetric-BEM head-matrix inverse,
> whose unknowns are vertex potentials *plus* normal currents on the inner interfaces
> (486 → 1126 for a 162-vertex-per-shell head), stored packed as the n(n+1)/2 upper
> triangle. MNE never evaluates it itself — `_compute_forwards_openmeeg` calls back
> into libOpenMEEG (`DipSourceMat` / `Head2EEGMat` / `GainEEG`) to re-assemble the
> source and sensor matrices. Reproducing that means implementing OpenMEEG's symmetric
> BEM, which is exactly the work this redirection exists to avoid.
>
> **The geometry, though, always travels.** Verified on the fixtures: `-bem.fif`,
> `-bem-sol-mne.fif` and `-bem-sol-openmeeg.fif` all carry the same BEM surfaces —
> identical vertices, triangles and conductivities — because `write_bem_solution`
> writes the surface blocks too. Only the solution matrix is solver-specific. So an
> OpenMEEG file is never a dead end; R3.1 reads it like any other.
>
> That leaves an OpenMEEG user three routes, and the UI should offer all three by name:
> (a) re-solve the same imported surfaces with `solver='mne'` — costs OpenMEEG's
> coarse-mesh accuracy, keeps the general operator; (b) solve the imported surfaces
> with EVA's own constant-element BEM, labelled as ours and approximate; (c) export a
> `-fwd.fif` lead field from `make_forward_solution` and accept a fixed source space.
> R3.7 is therefore no longer optional — see it below.

- [x] `BEMSolution` (`EVACore/Core/Forward/BEMSolution.swift`): reads
  `FIFF_BEM_POT_SOLUTION` (3110) and `FIFF_BEM_APPROX` — which is **3111, not 3108**;
  our `FIF.bemApprox` constant said 3108, which is not a tag at all and had never been
  exercised. The solver is not a tag either: MNE records a non-default one as JSON in
  `FIFF_DESCRIPTION` (206) inside the BEM block.
- [x] `FIFReader` now maps the file (`.mappedIfSafe`) and keeps tag payloads as slices
  of that mapping instead of copying each one, plus `matrixDimensions()` and a
  single-precision `floatValues()` — a 3×5120-vertex head is a 15360² float32 matrix
  ≈ 940 MB and there is no accuracy in doubling it. Oversized solutions are refused
  before allocation with a size estimate (2 GB default limit).
- [x] Geometry + solution + approximation + `source_mult` / `field_mult` from
  `_add_gamma_multipliers` (MNE, BSD-3), with the per-shell block ranges the matrix is
  laid out in — **outer first**, the file's surface order, which is the reverse of how
  `BEMGeometry` stores the shells. R3.3 has to keep that straight.
- [x] An OpenMEEG solution is detected (solver tag, 1-D packed storage, `nsol` ≠ vertex
  count) and declined *by name*, keeping its geometry and naming the three routes that
  work — verified in the tests down to the wording.
- [x] Isolated-skull (IPA) is already baked into whatever MNE wrote; we inherit it for
  free and record the approximation in provenance.
- [ ] Store the solution inside `.evahead` verbatim (the original FIF, not a re-encode),
  so the package stays MNE-readable and the provenance chain is intact. Needs R2.4's
  package to grow a slot; do it with R3.6.

### R3.3 `BEMSolutionForwardModel` — evaluating the imported operator

The forward evaluation, given a solution matrix, is small and well-defined; this is the
only real math R3 still owns.

- [ ] **Electrode specification**: project each electrode onto the scalp surface
  (`SurfaceRegistration` already projects), take the barycentric weights of the hit
  triangle, and build the per-electrode row `w · solution[triangle vertices, :]`,
  scaled by the outer sigma. Replaces the current nearest-centroid interpolation and is
  computed once per montage.
- [ ] **Per-dipole evaluation**: infinite-medium potentials of the dipole at every BEM
  vertex, contracted with the electrode rows — a `n_electrodes × n_vertices` by
  `n_vertices × 3` product per dipole, i.e. one BLAS call for a whole source set.
  Target: a 10 000-source free-orientation lead field in seconds, not minutes.
- [ ] **Frames and units, stated once and tested**: surfaces arrive in MRI (metres);
  dipoles and electrodes live in head frame; the `-trans.fif` from R2.4 is the bridge.
  Output in EVA's µV/(nA·m) with the conversion asserted against MNE, not assumed.
- [ ] Reference handling (`average` / `infinity`) identical to the spherical model, so
  swapping head models never silently changes the reference.

### R3.4 `ForwardOperator` protocol and wiring *(kept from the old R3.4)*

- [ ] `ForwardOperator` with `leadField(sources:) -> ForwardLeadField`, adopted by
  spherical, ellipsoidal, our icosphere BEM, and `BEMSolutionForwardModel` — so dipole
  fit, inverse imaging and the simulator are head-model-agnostic.
- [ ] Head-model picker wherever a forward is chosen (Source Simulator, Fit mode, R4),
  with the chosen model's provenance carried into every result and export. A result
  produced under an imported subject BEM must say so, next to one produced under a
  sphere.
- [ ] Lead-field cache keyed by (head model id, montage, reference, source set).

### R3.5 Validation  *(reference fixtures built 2026-09-06)*

- [x] `Tools/forward-compare/make_forward_fixtures.py` (+ `README.md`): for four cases —
  fsaverage watershed surfaces and 72/79/85 mm spheres, at ico2 (committed, ~7 MB) and
  ico3/ico4 (git-ignored `local/`) — writes `-bem.fif`, `-bem-sol-mne.fif`,
  `-bem-sol-openmeeg.fif`, a 32-electrode `-dig.fif` projected onto the scalp, and
  `-trans.fif`, then dumps MNE's EEG gain for 12 fixed dipoles into
  `forward_reference.json`. Runs in ~20 s; bit-reproducible.
- [x] Both solvers on identical geometry, and MNE's analytic sphere as a third opinion.
  Relative Frobenius difference of the whole gain matrix:

  | Comparison | ico2 | ico3 |
  |---|---|---|
  | MNE vs OpenMEEG, fsaverage | 24.3 % | 9.8 % |
  | MNE vs OpenMEEG, spheres | 25.8 % | 8.0 % |
  | MNE BEM vs analytic sphere | 18.3 % | 6.9 % |
  | OpenMEEG BEM vs analytic sphere | 8.7 % | 2.0 % |

  **The two engines are not interchangeable at coarse meshes** — OpenMEEG's symmetric
  BEM is ~3× closer to the analytic sphere than MNE's linear collocation at the same
  mesh. Both converge. Provenance must record which solver produced a head model, and
  the UI should say so wherever a result is shown.
- [x] **OpenMEEG is nondeterministic when threaded**: repeated `make_bem_solution(
  solver='openmeeg')` runs differ by 3 % of peak gain at ico2, 0.8 % at ico3 (parallel
  reduction order, amplified by a poorly conditioned coarse system). The generator sets
  `OMP_NUM_THREADS=1` and computes each gain *from the solution file it just wrote*, so
  the committed (solution, gain) pair answers exactly the question the importer has to:
  given these bytes, what does MNE produce? Worth remembering before we ever quote an
  OpenMEEG number to more than two significant figures.
- [x] Conventions the Swift side must match, pinned in the README and the JSON: gain
  scale 1e-3 from MNE's V/(A·m) to EVA's µV/(nA·m); `n_electrodes × 3·n_dipoles` x/y/z
  layout; **reference is infinity, not average**; surfaces and dipoles in MRI metres
  with electrodes in the head frame; and `make_bem_model` returns surfaces **outer
  first**, the opposite of EVA's stacking — index by surface id, never by position.
  (That one already cost a debugging round: projecting the electrodes onto `surfs[-1]`
  put them 28 mm inside the skull.)
- [ ] The Swift side of the comparison — target <0.1 % relative, the bar the FIF and
  coregistration work already meets. Blocked on R3.2/R3.3.
- [ ] Sphere cross-check against `SphericalForwardModel` itself (the fixture already
  carries MNE's analytic gain for the same dipoles, so this is a Swift-side test).
- [ ] Degenerate-input tests: non-nested surfaces, wrong coordinate frame, missing
  trans, solution/geometry vertex-count mismatch, single-shell head.

### R3.6 UI (Resolve head-model window)

- [ ] An **Import BEM** step next to the existing MRI → Fiducials → Electrodes → Fit →
  Save flow: pick a `-bem-sol.fif` (or geometry-only `-bem.fif`, or an OpenMEEG
  `.geom`), see the shells rendered over the T1 slices and in the 3-D view, see the
  quality-gate report, see which electrodes project where.
- [ ] Clear failure text for the common cases: solution and surfaces disagree, geometry
  is in the wrong frame, no trans yet, file is a bare geometry with no solution (offer
  the `make_bem_solution` recipe, and offer to solve it with our own solver on the
  imported surfaces — that path exists and should be labelled as approximate).
- [ ] Documentation page: "Bringing a head model into EVA Resolve", with the MNE and
  OpenMEEG recipes, what each file is for, and what EVA does and does not compute.

### R3.7 Precomputed lead-field import  *(promoted 2026-09-06 — this is the OpenMEEG path)*

- [ ] Import MNE `-fwd.fif`: the source space (positions + orientations), the gain
  matrix, channel names, coordinate frame and `source_ori`. Needs the FIF reader
  extended to the forward-solution blocks, which is more tags but no new math.
- [ ] Also accept a plain matrix (`.npy` / `.mat` / TSV) plus a source-position file,
  for tools that do not speak FIF. This is the door R6/DUNEuro walks through, and it
  makes FieldTrip and SimNIBS output usable without EVA understanding their internals.
- [ ] A lead field fixes the source space at export time, so the consumers that want an
  arbitrary dipole (R5's fitting) either interpolate within the grid or refuse. Say
  which, in the UI, per consumer — an imported lead field is not a drop-in for a
  solution and must not silently behave like one.
- [ ] Solve on imported surfaces with our own BEM (R3.1 geometry → `BEMForwardModel`)
  for users who have surfaces but no MNE install. Cheap to expose once R3.1 lands;
  label it as our constant-element solver, not MNE's.

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

## R6 — FEM: **import from DUNEuro** (long term)

Same decision as R3, one step further out. Writing a hex-FEM solver, a 6-tissue
segmentation and an anisotropy pipeline is a multi-year project that SimBio/DUNEuro and
SimNIBS have already done under free licenses; EVA's contribution is not a better
solver.

- [ ] **Import a DUNEuro transfer matrix / lead field** for a source space the user
  defines outside EVA (`.npy` / `.mat` / DUNEuro's own output plus a source-position
  file). This is R3.7's precomputed-lead-field importer, generalized — build it once,
  and BEM-from-anywhere and FEM-from-DUNEuro both arrive through the same door.
- [ ] Carry FEM provenance (tissue set, conductivities, anisotropy, solver settings) as
  opaque metadata into every result and export, so a FEM result is never mistaken for a
  BEM or sphere result.
- [ ] Optional viewer support for a labelled volume (the FEM's segmentation) as an
  overlay on the T1, since we already read NIfTI — display only, not computation.
- [ ] Validation: the same fixed dipole set through sphere, imported BEM and imported
  FEM, reported as a head-model sensitivity table. That comparison *is* the deliverable
  (Tier 6.5 inverse-crime study); the solver behind each column is not.
- Only reconsider writing a solver if a concrete need appears that no external tool
  serves — and record that need here before writing a line of it.

---

## Sequencing and parallelism

```
R0 done ─► R1 done ─► R2.1–R2.3 done ─► R2.4 coreg UI (brainstorm pending)
                                       │
                     ┌─────────────────┴──────────────────┐
                     ▼                                    ▼
       R3.1 import geometry + gates          R4 inverse on sphere grid
                     ▼                                    │
       R3.2 import solution                               │
                     ▼                                    │
       R3.3 BEMSolutionForwardModel ──► R3.4 ForwardOperator ──► R4 on BEM, R5 on BEM
                     ▼                                    │
       R3.5 validation vs. MNE + OpenMEEG                 │
                     ▼                                    ▼
       R3.6 import UI                       R3.7 lead-field import ──► R6 FEM (DUNEuro)
```

- R3.5's `Tools/forward-compare/` fixtures were generated **first**, before R3.2, so
  R3.2/R3.3 are now a matter of driving one number to zero against a committed
  reference gain matrix.
- R3.1 and R3.2 are independent of each other's UI; R3.3 needs both.
- R4 (sphere) does not wait on any of R3, and R3.4 is what lets R4 switch head models.
- R5's perf work (3c-perf) can be done any time; its PCA/multi-dipole work wants R3.4's
  `ForwardOperator` first.
- R3 is no longer the long pole. The remaining long pole is R4/R5 science plus R2.4's
  UI design.

## Membership map (what lives where when this is done)

| Folder | Targets | Content |
|---|---|---|
| `EVACore/` | EVA, EVASimulate, EVA Resolve, tests | IO (MFF, NIfTI, GIFTI, FIF, OpenMEEG, electrode files), forward models (analytic + imported BEM/FEM operators), registration math, source grids, inverse operators, dipole fit, simulation generators |
| `EVA/` | EVA | recording editor, cleaning pipeline (incl. surrogate-source BCG), epoching, exports; "Fit Source Model" launcher only |
| `EVAResolve/` | EVA Resolve | head-model documents, coregistration UI, Source Simulator, dipole-fit UI, inverse-imaging UI |
| `Tools/EVASimulate/` | EVASimulate | CLI generation/scoring; gains inverse scoring from `EVACore/` for free |

## Licensing notes to keep honest

- Port from MNE-Python (BSD-3) and from papers (BEM: Geselowitz / Van Oosterom;
  Umeyama; ICP). No code from FSL, FreeSurfer, FieldTrip, EEGLAB, Brainstorm, or
  TetGen. BET / watershed / IPA / hex-FEM ports are off the plan as of 2026-09-06.
- **OpenMEEG is GPL-3.** We never link it or copy from it — we read and write file
  formats it defines and let the user run their own OpenMEEG (usually through MNE).
  Reading a file format is not a derivative work; keep it that way and note it in
  `THIRD_PARTY_NOTICES.md` alongside the FIF reader.
- An imported head model carries someone else's license and someone else's subject
  data. Provenance travels with it; nothing gets re-bundled as an EVA template unless
  its license explicitly allows it (ICBM152 does; fsaverage-derived surfaces do not).
- Bundled templates: ICBM152 (free with attribution). Avoid fsaverage-derived surfaces.
- Record every ported algorithm in `THIRD_PARTY_NOTICES.md` as it lands.
