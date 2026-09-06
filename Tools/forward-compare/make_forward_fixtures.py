#!/usr/bin/env python
"""Reference EEG lead fields for the imported-BEM forward operator (R3.5).

Run with the MNE env:
    /Users/molfesepj/micromamba/envs/mne/bin/python Tools/forward-compare/make_forward_fixtures.py

EVA Resolve no longer builds BEMs (EVA_RESOLVE2.md R3, 2026-09-06); it imports a
finished head model from MNE-Python or OpenMEEG and evaluates the forward field
itself.  This script produces the reference the Swift side is measured against:
the *same* geometry, electrodes and dipoles, with the gain matrix computed by
MNE's own `make_forward_solution`, once per BEM solver.

Written, per case:

    <case>-bem.fif          geometry only (surfaces + conductivities)
    <case>-bem-sol-mne.fif      solution, solver='mne'
    <case>-bem-sol-openmeeg.fif solution, solver='openmeeg'
    <case>-electrodes-dig.fif   electrodes + fiducials, head frame
    <case>-trans.fif            head -> MRI

plus `forward_reference.json` holding the gain matrices and every number needed
to reproduce them (frames, units, source and electrode order).

Cases (`--cases`; the committed pair is the default):
    fsaverage-ico2   committed; the everyday regression fixture
    sphere-ico2      committed; 3 concentric spheres, so the imported BEM can be
                     checked against EVA's analytic SphericalForwardModel, with
                     MNE's own analytic gain in the JSON as a third opinion
    fsaverage-ico3 / sphere-ico3 / fsaverage-ico4   finer meshes, git-ignored
                     `local/`, where accuracy claims get made

Caveat worth knowing before reading the OpenMEEG numbers: an OpenMEEG solution
file is the symmetric-BEM head-matrix inverse (potentials *and* normal currents,
packed), which MNE evaluates by calling back into libOpenMEEG.  EVA can evaluate
an MNE solution from the file alone; the OpenMEEG gains here are a reference and
an accuracy datum, not something EVA reproduces.  See README.md.

Everything here comes from MNE-Python / OpenMEEG (BSD-3 / GPL-3 run as a
separate program, never linked), so the Swift implementation is checked against
an independent one.
"""
import argparse, json, os, sys, warnings

# OpenMEEG's assembly is multi-threaded and its reduction order is not fixed, so
# repeated runs disagree — by 3% of the peak gain at ico2 and 0.8% at ico3, which
# also says the coarse system is poorly conditioned.  Single-threaded it is
# bit-reproducible, and a fixture that cannot be regenerated is not a fixture.
# Must be set before the OpenMP runtime loads, i.e. before importing mne.
os.environ.setdefault("OMP_NUM_THREADS", "1")

import numpy as np
import mne
from mne.io.constants import FIFF

# numpy's blocked matmul kernel raises spurious FP warnings on perfectly finite
# input (reproducible with random arrays of the same shape); MNE's electrode
# specification hits it. Verified the gains come back finite.
warnings.filterwarnings("ignore", message=r".*encountered in matmul", category=RuntimeWarning)

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.abspath(os.path.join(HERE, "..", "..", "EVATests", "Fixtures", "Resolve", "Forward"))
LOCAL = os.path.abspath(os.path.join(HERE, "..", "..", "EVATests", "Fixtures", "Resolve", "local", "forward"))

# MNE EEG gain is volts per ampere-metre; EVA's lead fields are
# microvolts per nanoampere-metre.  1 V/(A m) = 1e6 uV / 1e9 nA m = 1e-3.
MNE_TO_EVA_GAIN = 1e-3

# 32 electrodes spread over the whole head; a subset of standard_1020 so the
# montage is reproducible from MNE alone.
CHANNELS = ["Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8", "FT9", "FC5", "FC1", "FC2", "FC6",
            "FT10", "T7", "C3", "Cz", "C4", "T8", "TP9", "CP5", "CP1", "CP2", "CP6", "TP10",
            "P7", "P3", "Pz", "P4", "P8", "O1", "Oz", "O2"]


def log(*a):
    print(*a, flush=True)


# `make_bem_model` returns surfaces OUTER FIRST (head, outer skull, inner skull),
# which is the opposite of how EVA stacks shells.  Never index this list by
# position; ask for the surface you mean.
def surface_by_id(surfs, surf_id):
    for s in surfs:
        if int(s["id"]) == int(surf_id):
            return s
    raise KeyError(f"no BEM surface with id {surf_id} (have {[int(s['id']) for s in surfs]})")


def scalp_of(surfs):
    return surface_by_id(surfs, FIFF.FIFFV_BEM_SURF_ID_HEAD)


def inner_skull_of(surfs):
    return surface_by_id(surfs, FIFF.FIFFV_BEM_SURF_ID_BRAIN)


# --- geometry ---------------------------------------------------------------

def fsaverage_surfaces(subjects_dir, ico, conductivity=(0.3, 0.006, 0.3)):
    """Watershed BEM surfaces MNE ships with fsaverage, downsampled to `ico`."""
    return mne.make_bem_model("fsaverage", ico=ico, conductivity=conductivity,
                              subjects_dir=subjects_dir, verbose="ERROR")


def sphere_surfaces(radii=(0.072, 0.079, 0.085), sigmas=(0.33, 0.0042, 0.33), ico=2, tmpdir=None):
    """Three concentric icosphere shells as BEM surfaces, centred on the origin.

    Written to a `-bem.fif` and read back so MNE fills in the derived fields
    (normals, areas, neighbourhoods) exactly as it does for a real subject.
    """
    ico_surf = mne.surface._get_ico_surface(ico)
    rr_unit = ico_surf["rr"] / np.linalg.norm(ico_surf["rr"], axis=1, keepdims=True)
    ids = (FIFF.FIFFV_BEM_SURF_ID_BRAIN, FIFF.FIFFV_BEM_SURF_ID_SKULL, FIFF.FIFFV_BEM_SURF_ID_HEAD)
    surfs = []
    # written outer-first, matching `make_bem_model`
    for radius, sigma, sid in list(zip(radii, sigmas, ids))[::-1]:
        surfs.append(dict(rr=rr_unit * radius, tris=ico_surf["tris"].copy(),
                          ntri=len(ico_surf["tris"]), np=len(rr_unit), id=sid,
                          sigma=sigma, coord_frame=FIFF.FIFFV_COORD_MRI))
    path = os.path.join(tmpdir, "sphere-raw-bem.fif")
    mne.write_bem_surfaces(path, surfs, overwrite=True)
    return mne.read_bem_surfaces(path, verbose="ERROR")


# --- electrodes and dipoles -------------------------------------------------

def head_frame_electrodes(surfs, radius_hint=None):
    """standard_1020 subset, in head coordinates, projected onto the scalp.

    The montage is defined in fsaverage MRI space; `set_montage` moves it to the
    head frame through the fiducials.  We then push each electrode radially onto
    the outer BEM surface so the electrodes sit exactly on the conductor
    boundary, which is what the barycentric electrode specification assumes.
    """
    montage = mne.channels.make_standard_montage("standard_1020")
    info = mne.create_info(CHANNELS, 1000.0, "eeg")
    info.set_montage(montage)
    pos = np.array([info["chs"][i]["loc"][:3] for i in range(len(CHANNELS))])
    fids = {int(d["ident"]): np.asarray(d["r"], float) for d in info["dig"]
            if d["kind"] == FIFF.FIFFV_POINT_CARDINAL}
    return pos, fids, info


def project_to_surface(points, surf_rr, surf_tris):
    """Nearest point on the triangulated surface, per input point."""
    from mne.surface import _project_onto_surface
    surf = dict(rr=surf_rr, tris=surf_tris, np=len(surf_rr), ntri=len(surf_tris))
    surf = mne.surface.complete_surface_info(surf, copy=True, verbose="ERROR")
    out = _project_onto_surface(points, surf, project_rrs=True, return_nn=True)
    return out[2]


def dipole_set(inner_surf, n=12, fraction=0.65, seed=20260906):
    """Dipoles well inside the inner-skull surface, deterministic.

    Each is a vertex of the inner skull pulled `fraction` of the way back to the
    surface centroid, with an orientation that is neither radial nor tangential
    (both are special cases a bug can hide behind).
    """
    rng = np.random.default_rng(seed)
    rr_surf = inner_surf["rr"]
    centre = rr_surf.mean(0)
    idx = np.linspace(0, len(rr_surf) - 1, n).astype(int)
    rr = centre + fraction * (rr_surf[idx] - centre)
    radial = rr - centre
    radial /= np.linalg.norm(radial, axis=1, keepdims=True)
    tangent = np.cross(radial, rng.normal(size=radial.shape))
    tangent /= np.linalg.norm(tangent, axis=1, keepdims=True)
    nn = 0.6 * radial + 0.8 * tangent
    nn /= np.linalg.norm(nn, axis=1, keepdims=True)
    return rr, nn


# --- one case ---------------------------------------------------------------

def run_case(name, surfs, trans, out_dir, solvers=("mne", "openmeeg"), subject=None,
             subjects_dir=None):
    os.makedirs(out_dir, exist_ok=True)
    prefix = os.path.join(out_dir, name)

    mne.write_bem_surfaces(prefix + "-bem.fif", surfs, overwrite=True)

    pos, fids, info = head_frame_electrodes(surfs)
    scalp = scalp_of(surfs)
    # Electrodes are in head coords, surfaces in MRI coords: move to MRI, project,
    # move back, so "on the scalp" is true in the frame the surface lives in.
    head_to_mri = trans["trans"]
    pos_mri = mne.transforms.apply_trans(head_to_mri, pos)
    projected = project_to_surface(pos_mri, scalp["rr"], scalp["tris"])
    shift_mm = np.linalg.norm(projected - pos_mri, axis=1) * 1000
    log(f"    electrodes moved onto the scalp by {shift_mm.mean():.1f} mm "
        f"(max {shift_mm.max():.1f} mm)")
    pos_mri = projected
    pos = mne.transforms.apply_trans(np.linalg.inv(head_to_mri), pos_mri)
    # Rebuild the montage (and the info) from the projected positions, so the dig
    # we write and the positions the forward uses are the same numbers.
    montage = mne.channels.make_dig_montage(
        ch_pos=dict(zip(CHANNELS, pos)), coord_frame="head",
        nasion=fids[FIFF.FIFFV_POINT_NASION], lpa=fids[FIFF.FIFFV_POINT_LPA],
        rpa=fids[FIFF.FIFFV_POINT_RPA])
    info = mne.create_info(CHANNELS, 1000.0, "eeg")
    info.set_montage(montage)
    pos = np.array([info["chs"][i]["loc"][:3] for i in range(len(CHANNELS))])
    montage.save(prefix + "-electrodes-dig.fif", overwrite=True)
    mne.write_trans(prefix + "-trans.fif", trans, overwrite=True)

    rr_mri, nn_mri = dipole_set(inner_skull_of(surfs))
    src = mne.setup_volume_source_space(subject=subject, pos=dict(rr=rr_mri, nn=nn_mri),
                                        subjects_dir=subjects_dir, verbose="ERROR")

    case = {
        "name": name,
        "surface_order": "as written to -bem.fif: outer first, like mne.make_bem_model",
        "surfaces": [{"id": int(s["id"]), "np": int(s["np"]), "ntri": int(s["ntri"]),
                      "sigma": float(s["sigma"]), "coord_frame": int(s["coord_frame"])} for s in surfs],
        "electrode_names": CHANNELS,
        "electrodes_head_m": pos.tolist(),
        "fiducials_head_m": {"nasion": fids[FIFF.FIFFV_POINT_NASION].tolist(),
                             "lpa": fids[FIFF.FIFFV_POINT_LPA].tolist(),
                             "rpa": fids[FIFF.FIFFV_POINT_RPA].tolist()},
        "dipoles_mri_m": rr_mri.tolist(),
        "dipole_normals_mri": nn_mri.tolist(),
        "src_coord_frame": int(src[0]["coord_frame"]),
        "head_to_mri_trans": head_to_mri.tolist(),
        "gain_units": "microvolts per nanoampere-metre (MNE V/(A m) * %g)" % MNE_TO_EVA_GAIN,
        "gain_layout": "n_electrodes x (3 * n_dipoles), x/y/z columns per dipole, reference=infinity(MNE raw)",
        "solvers": {},
    }

    gains = {}
    for solver in solvers:
        log(f"  [{name}] make_bem_solution(solver={solver!r}) ...")
        sol_path = f"{prefix}-bem-sol-{solver}.fif"
        mne.write_bem_solution(sol_path, mne.make_bem_solution(surfs, solver=solver, verbose="ERROR"),
                               overwrite=True)
        # Compute the gain from the *file*, not from the in-memory solution, so the
        # committed pair (solution, gain) is self-consistent: it is the answer to
        # "given exactly these bytes, what does MNE produce?", which is exactly the
        # question the Swift importer has to answer.
        bem = mne.read_bem_solution(sol_path, verbose="ERROR")
        fwd = mne.make_forward_solution(info, trans, src, bem, eeg=True, meg=False,
                                        mindist=0.0, n_jobs=1, verbose="ERROR")
        assert fwd["source_ori"] == FIFF.FIFFV_MNE_FREE_ORI, fwd["source_ori"]
        gain = fwd["sol"]["data"] * MNE_TO_EVA_GAIN
        gains[solver] = gain
        case["solvers"][solver] = {
            "solution_file": os.path.basename(sol_path),
            "solution_bytes": os.path.getsize(sol_path),
            "approx": int(bem["bem_method"]) if "bem_method" in bem else None,
            "solver_field": str(bem.get("solver", "mne")),
            "nsol": int(bem["nsol"]),
            "solution_shape": list(bem["solution"].shape),
            # 'mne': dense (n_vertices x n_vertices) potential solution, evaluable
            #        from the file alone.
            # 'openmeeg': the symmetric-BEM head matrix inverse, unknowns = vertex
            #        potentials + normal currents on the inner interfaces, stored
            #        PACKED as the n(n+1)/2 upper triangle.  MNE evaluates it by
            #        calling back into libOpenMEEG (DipSourceMat / Head2EEGMat /
            #        GainEEG), so the file is not self-sufficient.
            "solution_layout": ("dense n_vertices x n_vertices"
                                if str(bem.get("solver", "mne")) == "mne"
                                else "packed symmetric %d x %d (%d entries)"
                                     % (bem["nsol"], bem["nsol"], bem["solution"].shape[0])),
            "channel_names": list(fwd["info"]["ch_names"]),
            "source_rr_head_m": fwd["source_rr"].tolist(),
            "source_nn_head": fwd["source_nn"].tolist(),
            "gain": gain.tolist(),
        }
        log(f"    gain {gain.shape}, |g|max = {np.abs(gain).max():.4g} uV/(nA m), "
            f"solution {os.path.getsize(sol_path) / 1e6:.1f} MB")

    if len(gains) == 2:
        a, b = gains["mne"], gains["openmeeg"]
        denom = np.linalg.norm(a)
        case["solver_agreement"] = {
            "relative_frobenius_difference": float(np.linalg.norm(a - b) / denom),
            "max_relative_elementwise": float(np.abs(a - b).max() / np.abs(a).max()),
            "column_correlation_min": float(min(
                np.corrcoef(a[:, i], b[:, i])[0, 1] for i in range(a.shape[1]))),
        }
        log("    MNE vs OpenMEEG: rel. Frobenius %.3g, max elementwise %.3g, min column r %.6f"
            % (case["solver_agreement"]["relative_frobenius_difference"],
               case["solver_agreement"]["max_relative_elementwise"],
               case["solver_agreement"]["column_correlation_min"]))
    return case, info, src, pos


SPHERE_RADII = (0.072, 0.079, 0.085)
SPHERE_SIGMAS = (0.33, 0.0042, 0.33)


def sphere_analytic(info, src, trans, radii=SPHERE_RADII, sigmas=SPHERE_SIGMAS):
    """MNE's analytic multi-shell sphere gain for the same dipoles.

    Gives the end-to-end sanity check: an imported BEM built on spheres has to
    agree with EVA's own `SphericalForwardModel`, and this is the third opinion.
    """
    sphere = mne.make_sphere_model(r0=(0.0, 0.0, 0.0), head_radius=radii[-1],
                                   relative_radii=[r / radii[-1] for r in radii],
                                   sigmas=list(sigmas), verbose="ERROR")
    fwd = mne.make_forward_solution(info, trans, src, sphere, eeg=True, meg=False,
                                    mindist=0.0, n_jobs=1, verbose="ERROR")
    return fwd["sol"]["data"] * MNE_TO_EVA_GAIN


# name -> (geometry, ico, committed?)
#
# Committed cases stay coarse on purpose: the load-bearing assertion is that EVA
# reproduces MNE's gain matrix *exactly* on the same geometry, and a coarse mesh
# tests that just as well as a fine one for a fraction of the bytes.  The fine
# cases (git-ignored) are where accuracy claims get made.
CASES = {
    "fsaverage-ico2": ("fsaverage", 2, True),
    "sphere-ico2": ("sphere", 2, True),
    "fsaverage-ico3": ("fsaverage", 3, False),
    "sphere-ico3": ("sphere", 3, False),
    "fsaverage-ico4": ("fsaverage", 4, False),   # ~240 MB per solution; run deliberately
}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cases", default="fsaverage-ico2,sphere-ico2",
                    help="comma-separated subset of: " + ", ".join(CASES))
    args = ap.parse_args()
    wanted = [c.strip() for c in args.cases.split(",") if c.strip()]
    for name in wanted:
        if name not in CASES:
            ap.error(f"unknown case {name!r}; choose from {', '.join(CASES)}")

    os.makedirs(FIXTURES, exist_ok=True)
    os.makedirs(LOCAL, exist_ok=True)
    fs_dir = mne.datasets.fetch_fsaverage(verbose=False)
    subjects_dir = os.path.dirname(fs_dir)
    fs_trans = mne.read_trans(os.path.join(fs_dir, "bem", "fsaverage-trans.fif"))

    header = {
        "generator": "Tools/forward-compare/make_forward_fixtures.py",
        "mne_version": mne.__version__,
        "gain_scale_from_mne": MNE_TO_EVA_GAIN,
    }
    try:
        import openmeeg
        header["openmeeg_version"] = openmeeg.__version__
    except Exception:
        header["openmeeg_version"] = None

    committed, local = {}, {}
    for name in wanted:
        geometry, ico, is_committed = CASES[name]
        out_dir = FIXTURES if is_committed else LOCAL
        log(f"{name} ({'committed' if is_committed else 'git-ignored local'} fixture)")
        if geometry == "fsaverage":
            surfs = fsaverage_surfaces(subjects_dir, ico=ico)
            case, _, _, _ = run_case(name, surfs, fs_trans, out_dir,
                                     subject="fsaverage", subjects_dir=subjects_dir)
        else:
            identity = mne.transforms.Transform("head", "mri", np.eye(4))
            surfs = sphere_surfaces(radii=SPHERE_RADII, sigmas=SPHERE_SIGMAS, ico=ico, tmpdir=LOCAL)
            case, info, src, _ = run_case(name, surfs, identity, out_dir)
            analytic = sphere_analytic(info, src, identity)
            case["analytic_sphere_gain"] = analytic.tolist()
            case["analytic_sphere_model"] = {"radii_m": list(SPHERE_RADII),
                                             "sigmas_s_per_m": list(SPHERE_SIGMAS),
                                             "centre_m": [0.0, 0.0, 0.0],
                                             "mne_model": "make_sphere_model (Berg approximation)"}
            case["bem_vs_analytic"] = {}
            for solver, entry in case["solvers"].items():
                g = np.array(entry["gain"])
                rel = float(np.linalg.norm(g - analytic) / np.linalg.norm(analytic))
                case["bem_vs_analytic"][solver] = {"relative_frobenius_difference": rel}
                log(f"    {solver} BEM vs analytic sphere: rel. Frobenius {rel:.3g}")
        (committed if is_committed else local)[name] = case

    if committed:
        with open(os.path.join(FIXTURES, "forward_reference.json"), "w") as f:
            json.dump({**header, "cases": committed}, f, indent=1)
        log("wrote", os.path.join(FIXTURES, "forward_reference.json"))
    if local:
        with open(os.path.join(LOCAL, "forward_reference_local.json"), "w") as f:
            json.dump({**header, "cases": local}, f, indent=1)
        log("wrote", os.path.join(LOCAL, "forward_reference_local.json"))


if __name__ == "__main__":
    sys.exit(main())
