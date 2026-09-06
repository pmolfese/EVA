# forward-compare — reference lead fields for the imported-BEM forward operator

EVA Resolve imports finished BEM head models from MNE-Python or OpenMEEG and
evaluates the forward field itself (`EVA_RESOLVE2.md` R3). This directory holds
the reference those Swift implementations are measured against: identical
geometry, electrodes and dipoles, with the gain matrix computed by MNE's own
`make_forward_solution`, once per BEM solver.

```bash
/Users/molfesepj/micromamba/envs/mne/bin/python Tools/forward-compare/make_forward_fixtures.py
```

That regenerates the committed cases (~7 MB). The fine cases are opt-in and land
in the git-ignored `local/` tree:

```bash
/Users/molfesepj/micromamba/envs/mne/bin/python Tools/forward-compare/make_forward_fixtures.py \
    --cases fsaverage-ico3,sphere-ico3
```

## What gets written

`EVATests/Fixtures/Resolve/Forward/` (committed):

| File | Contents |
|---|---|
| `<case>-bem.fif` | surfaces + conductivities, outer first (MNE's order) |
| `<case>-bem-sol-mne.fif` | BEM solution, `solver='mne'` (linear collocation + ISA) |
| `<case>-bem-sol-openmeeg.fif` | BEM solution, `solver='openmeeg'` (symmetric BEM) |
| `<case>-electrodes-dig.fif` | 32 electrodes + fiducials, head frame, metres |
| `<case>-trans.fif` | head → MRI |
| `forward_reference.json` | the gain matrices and everything needed to reproduce them |

`EVATests/Fixtures/Resolve/local/forward/` (git-ignored) holds the same set for
the fine cases plus `forward_reference_local.json`.

## Cases

| Case | Geometry | Vertices/shell | Committed |
|---|---|---|---|
| `fsaverage-ico2` | fsaverage watershed surfaces, σ 0.3 / 0.006 / 0.3 | 162 | yes |
| `sphere-ico2` | 72/79/85 mm spheres, σ 0.33 / 0.0042 / 0.33 | 162 | yes |
| `fsaverage-ico3` | as above | 642 | no |
| `sphere-ico3` | as above | 642 | no |
| `fsaverage-ico4` | as above | 2562 | no (≈240 MB per solution) |

The committed cases are deliberately coarse. The load-bearing assertion is that
EVA reproduces MNE's gain matrix *exactly* from the same solution file, and a
coarse mesh tests that as well as a fine one for a fraction of the bytes.
Accuracy claims are made from the fine cases.

## Conventions the Swift side has to match

- **Units.** MNE's EEG gain is V/(A·m); EVA's is µV/(nA·m). The factor is
  `1e-3`, applied to every gain in the JSON (`gain_scale_from_mne`).
- **Layout.** `n_electrodes × (3 · n_dipoles)`, x/y/z columns per dipole, in the
  electrode and dipole order the JSON lists.
- **Reference.** MNE's raw gain, i.e. potential referenced to infinity — *not*
  average-referenced. Apply EVA's reference after the comparison, not before.
- **Frames.** Surfaces and dipoles are in MRI coordinates (metres); electrodes
  are in the head frame; `<case>-trans.fif` is the bridge. `source_rr_head_m` in
  the JSON is MNE's copy of the dipoles after transformation into the head
  frame — a useful independent check of `HeadTransform`.
- **Surface order.** `mne.make_bem_model` returns surfaces **outer first**
  (head, outer skull, inner skull), the opposite of how EVA stacks shells. The
  files preserve that order; index by surface id, never by position.
- **Electrodes sit on the scalp.** Each is projected onto the outer surface
  before the forward is computed, because the barycentric electrode
  specification assumes it. The script prints how far they moved (2 mm on
  fsaverage; ~30 mm for the sphere case, where a head-shaped montage is being
  pushed onto a 85 mm sphere).

## What the reference numbers say

Relative Frobenius difference of the whole gain matrix.

| Comparison | ico2 | ico3 |
|---|---|---|
| MNE vs OpenMEEG, fsaverage | 24.3 % | 9.8 % |
| MNE vs OpenMEEG, spheres | 25.8 % | 8.0 % |
| MNE BEM vs analytic sphere | 18.3 % | 6.9 % |
| OpenMEEG BEM vs analytic sphere | 8.7 % | 2.0 % |

Two things worth carrying into the plan:

1. **The two engines are not interchangeable at coarse meshes.** OpenMEEG's
   symmetric BEM is roughly three times closer to the analytic sphere than MNE's
   linear collocation at the same mesh. Both converge; the gap narrows with
   refinement. A result should record which solver produced its head model.
2. **OpenMEEG is not deterministic when threaded.** Repeated runs of
   `make_bem_solution(solver='openmeeg')` differ by 3 % of the peak gain at ico2
   and 0.8 % at ico3 — parallel reduction order, amplified by a poorly
   conditioned coarse system. This script sets `OMP_NUM_THREADS=1` before
   importing MNE, which makes it bit-reproducible, and computes each gain from
   the solution file it just wrote rather than from the in-memory model, so the
   committed (solution, gain) pair is self-consistent whatever the solver did.

## The OpenMEEG solution file is not an operator

`mne.write_bem_solution` writes both solvers into the same file shape, but they hold
different objects, and the fixture records it (`solver_field`, `nsol`,
`solution_shape`, `solution_layout`):

| | `solver='mne'` | `solver='openmeeg'` |
|---|---|---|
| unknowns | vertex potentials (486) | potentials + normal currents on the inner interfaces (1126) |
| storage | dense 486 × 486 | packed symmetric, 634 501 entries |
| evaluation | matrix algebra on the file's contents | MNE calls back into libOpenMEEG to re-assemble the source and sensor matrices |

So EVA can evaluate an MNE solution for any dipole, and cannot evaluate an OpenMEEG one
without reimplementing OpenMEEG's symmetric BEM. The OpenMEEG gains in this fixture were
computed by MNE through libOpenMEEG and are here as a reference and an accuracy datum,
not as something EVA reproduces from the solution file.

The **geometry is solver-independent and always present**: all three files above carry
the same surfaces, vertex for vertex, with their conductivities, because
`write_bem_solution` writes the surface blocks as well. An OpenMEEG file is therefore
still a perfectly good head model to import — re-solve it with `solver='mne'`, solve it
with EVA's own BEM, or import a `-fwd.fif` lead field instead
(`EVA_RESOLVE2.md` R3.2/R3.7).

## Checking what EVA writes

`check_swift_openmeeg.py <directory>` loads an OpenMEEG head model EVA wrote (the
round-trip test in `EVATests/IO/BEMImportTests.swift` leaves one in the test host's
temporary directory and prints the path) and reads it back with OpenMEEG itself:
`selfCheck`, `is_nested`, and an `om.HeadMat` assembly. It is the OpenMEEG counterpart
of `Tools/resolve-validate/check_swift_fif.py`.

A clean pass prints no "Global reorientation of interface …" lines. OpenMEEG's `.tri`
winding is the reverse of MNE's — established by experiment: MNE-wound input makes
OpenMEEG reorient and assemble a head matrix ~3e-4 different, and the per-vertex normals
in the file are ignored entirely. EVA writes the reversed winding deliberately, so a
reorientation message means the writer has drifted.

## Licensing

MNE-Python is BSD-3. OpenMEEG is GPL-3 and is run here as a separate program
through MNE — never linked into EVA, never copied from. The generated fixtures
are numbers, not code.
