# Head models — import, don't build

Why EVA Resolve imports BEM head models from MNE / OpenMEEG and FEM from
DUNEuro rather than deriving them, and the licensing boundary that follows.

**Status is in `ROADMAP.md` § Source & Forward Modeling (R3 … R6).**

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
