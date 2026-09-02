#!/usr/bin/env python
"""Generate the Resolve validation fixtures in EVATests/Fixtures/Resolve/.

Run with the MNE env:  /Users/molfesepj/micromamba/envs/mne/bin/python Tools/resolve-validate/make_fixtures.py

Everything here is produced by nibabel / MNE-Python (BSD-3) so the Swift side
(NIfTIVolume, HeadTransform) is checked against an independent implementation.
"""
import json, os, numpy as np, nibabel as nib
from scipy.ndimage import map_coordinates
import mne
from mne.coreg import fit_matched_points

out = os.path.join(os.path.dirname(__file__), "..", "..", "EVATests", "Fixtures", "Resolve")
os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(20260902)

# --- phantom volume: RAS, anisotropic voxels, offset origin -----------------
nx, ny, nz = 20, 24, 16
vs = np.array([1.5, 2.0, 2.5])
affine = np.diag([vs[0], vs[1], vs[2], 1.0])
affine[:3, 3] = [-14.0, -20.0, -12.0]
data = np.zeros((nx, ny, nz), np.float32)
ii, jj, kk = np.meshgrid(np.arange(nx), np.arange(ny), np.arange(nz), indexing="ij")
data += (ii + 2 * jj + 3 * kk).astype(np.float32)          # smooth gradient
# "left marker": a bright cube whose world x is negative (left), y anterior, z superior
marker_vox = (slice(2, 5), slice(18, 21), slice(11, 14))
data[marker_vox] = 1000.0
marker_center_vox = np.array([3, 19, 12], float)
marker_center_world = affine @ np.r_[marker_center_vox, 1]

nib.save(nib.Nifti1Image(data, affine), os.path.join(out, "phantom_ras.nii.gz"))

# LAS: flip the first voxel axis; affine keeps every voxel at the same world spot
flip_x = np.eye(4); flip_x[0, 0] = -1; flip_x[0, 3] = nx - 1
nib.save(nib.Nifti1Image(np.flip(data, 0).copy(), affine @ flip_x), os.path.join(out, "phantom_las.nii"))

# PIR-ish: voxel axes (j reversed, k reversed, i) -> world (P, I, R)
perm = np.array([[0, 0, 1, 0], [-1, 0, 0, ny - 1], [0, -1, 0, nz - 1], [0, 0, 0, 1]], float)  # old = perm @ new
new_data = np.transpose(data, (1, 2, 0))[::-1, ::-1, :].copy()
nib.save(nib.Nifti1Image(new_data, affine @ perm), os.path.join(out, "phantom_pir.nii"))

# qform-only with a rotation about z (30 deg), int16 with scaling
theta = np.deg2rad(30)
rot = np.array([[np.cos(theta), -np.sin(theta), 0], [np.sin(theta), np.cos(theta), 0], [0, 0, 1]])
aff_rot = np.eye(4); aff_rot[:3, :3] = rot @ np.diag(vs); aff_rot[:3, 3] = [-10, -8, -6]
img = nib.Nifti1Image(np.round(data / 4).astype(np.int16), None)
img.header.set_qform(aff_rot, code=1); img.header.set_sform(None, code=0)
img.header.set_slope_inter(4.0, 1.0)
nib.save(img, os.path.join(out, "phantom_qform_int16.nii"))

# sample points for trilinear check (world mm) on the RAS phantom
sample_world = np.array([[-5.0, 3.0, 4.0], [0.25, -1.75, 8.5], [10.0, 20.0, 17.5]])
sample_vox = (np.linalg.inv(affine) @ np.c_[sample_world, np.ones(3)].T)[:3]
sample_values = map_coordinates(data, sample_vox, order=1, mode="constant", cval=0.0)

# --- Umeyama references from MNE -------------------------------------------
src = rng.normal(size=(8, 3)) * 0.05                      # metres
rot_true = mne.transforms.rotation3d(0.3, -0.5, 1.1)
t_true = np.array([0.01, -0.02, 0.03])
scale_true = 1.15
tgt_rigid = src @ rot_true.T + t_true
tgt_scale = scale_true * (src @ rot_true.T) + t_true
noise = rng.normal(size=src.shape) * 0.001
tgt_rigid_noisy = tgt_rigid + noise
trans_rigid = fit_matched_points(src, tgt_rigid_noisy, scale=False, out="trans")
trans_scale = fit_matched_points(src, tgt_scale + noise, scale=1, out="trans")
fid_src = np.array([[0.0, 0.1, 0.0], [-0.08, 0.0, -0.01], [0.08, 0.0, -0.01]])  # nas, lpa, rpa
fid_tgt = fid_src @ rot_true.T + t_true
trans_fid = fit_matched_points(fid_src, fid_tgt, scale=False, out="trans")

ref = {
    "phantom": {
        "dimensions": [nx, ny, nz], "voxel_size": vs.tolist(), "affine": affine.tolist(),
        "marker_center_voxel": marker_center_vox.tolist(), "marker_center_world": marker_center_world[:3].tolist(),
        "marker_voxel_min": [2, 18, 11], "marker_voxel_max": [4, 20, 13],
        "sample_world": sample_world.tolist(), "sample_values": sample_values.tolist(),
        "qform_affine": aff_rot.tolist(),
        "value_at_voxel_5_6_7": float(data[5, 6, 7]),
    },
    "umeyama": {
        "source": src.tolist(), "target_rigid_noisy": tgt_rigid_noisy.tolist(), "target_scale_noisy": (tgt_scale + noise).tolist(),
        "mne_rigid": trans_rigid.tolist(), "mne_scale": trans_scale.tolist(),
        "fiducials_source": fid_src.tolist(), "fiducials_target": fid_tgt.tolist(), "mne_fiducials": trans_fid.tolist(),
        "true_rotation": rot_true.tolist(), "true_translation": t_true.tolist(), "true_scale": scale_true,
    },
}
with open(os.path.join(out, "resolve_reference.json"), "w") as f:
    json.dump(ref, f, indent=1)
print("wrote fixtures to", os.path.abspath(out))

# --- digitizer files read back by MNE ---------------------------------------
from mne.channels import read_custom_montage
from mne.transforms import get_ras_to_neuromag_trans
names = ["Fp1", "Fp2", "Cz", "O1", "O2", "T7", "T8", "Pz"]
pts_m = np.array([[-0.03, 0.09, 0.01], [0.03, 0.09, 0.01], [0.0, 0.0, 0.1], [-0.03, -0.09, 0.01],
                  [0.03, -0.09, 0.01], [-0.095, 0.0, 0.0], [0.095, 0.0, 0.0], [0.0, -0.05, 0.085]])
fid_m = {"nasion": np.array([0.0, 0.1, -0.02]), "lpa": np.array([-0.085, 0.005, -0.03]), "rpa": np.array([0.085, 0.005, -0.03])}
# sfp in cm with BESA fiducial names
with open(os.path.join(out, "sample.sfp"), "w") as f:
    f.write("FidNz %.4f %.4f %.4f\nFidT9 %.4f %.4f %.4f\nFidT10 %.4f %.4f %.4f\n" % (*(fid_m["nasion"] * 100), *(fid_m["lpa"] * 100), *(fid_m["rpa"] * 100)))
    for n, p in zip(names, pts_m * 100): f.write("%s %.4f %.4f %.4f\n" % (n, *p))
# elc in mm
with open(os.path.join(out, "sample.elc"), "w") as f:
    f.write("# ASA electrode file\nReferenceLabel\tavg\nUnitPosition\tmm\nNumberPositions=\t%d\nPositions\n" % (len(names) + 3))
    for p in [fid_m["nasion"], fid_m["lpa"], fid_m["rpa"], *pts_m]: f.write("%.4f %.4f %.4f\n" % tuple(p * 1000))
    f.write("Labels\nNz\nLPA\nRPA\n" + "\n".join(names) + "\n")
# Cartool xyz in mm
with open(os.path.join(out, "sample.xyz"), "w") as f:
    # (MNE's reader takes no count line; ours accepts either.)
    for i, (n, p) in enumerate([("Nz", fid_m["nasion"]), ("LPA", fid_m["lpa"]), ("RPA", fid_m["rpa"]), *zip(names, pts_m)]):
        f.write("%d\t%.4f\t%.4f\t%.4f\t%s\n" % (i + 1, *(p * 1000), n))
# csv in m, tsv in mm
with open(os.path.join(out, "sample.csv"), "w") as f:
    f.write("name,x,y,z\n")
    for n, p in [("NAS", fid_m["nasion"]), ("LPA", fid_m["lpa"]), ("RPA", fid_m["rpa"]), *zip(names, pts_m)]:
        f.write("%s,%.6f,%.6f,%.6f\n" % (n, *p))
with open(os.path.join(out, "sample.tsv"), "w") as f:
    f.write("label\tx\ty\tz\n")
    for n, p in [("Nz", fid_m["nasion"]), ("LPA", fid_m["lpa"]), ("RPA", fid_m["rpa"]), *zip(names, pts_m)]:
        f.write("%s\t%.4f\t%.4f\t%.4f\n" % (n, *(p * 1000)))

digit = {}
for fname, unit in [("sample.sfp", "cm"), ("sample.elc", "mm"), ("sample.xyz", "mm"), ("sample.csv", "m"), ("sample.tsv", "mm")]:
    # MNE rescales every custom montage to head_size, so undo that uniform scale
    # with the known true |Cz| = 0.1 m before recording the reference.
    m = read_custom_montage(os.path.join(out, fname))
    pos = m.get_positions()
    k = 0.1 / np.linalg.norm(pos["ch_pos"]["Cz"])
    # MNE's .xyz path keeps fiducial rows as channels and reports no fiducials;
    # drop those rows and fall back to the values we wrote, so the reference is
    # the same truth for every format.
    fid_labels = {"Nz", "NAS", "LPA", "RPA"}
    chans = [c for c in pos["ch_pos"] if c not in fid_labels]
    fids = {key: (pos[key] * k).tolist() if pos[key] is not None else fid_m[key].tolist() for key in ("nasion", "lpa", "rpa")}
    digit[fname] = {"ch_names": chans, "ch_pos": [(pos["ch_pos"][c] * k).tolist() for c in chans],
                    "mne_reported_fiducials": pos["nasion"] is not None, **fids}
head_trans = get_ras_to_neuromag_trans(fid_m["nasion"], fid_m["lpa"], fid_m["rpa"])
ref["digitizers"] = digit
ref["head_frame"] = {"nasion": fid_m["nasion"].tolist(), "lpa": fid_m["lpa"].tolist(), "rpa": fid_m["rpa"].tolist(), "trans": head_trans.tolist()}
ref["egi_fixture"] = {"nasion_cm": [0.0, 10.564, -2.051], "lpa_cm": [-8.592, 0.498, -4.128], "rpa_cm": [8.592, 0.498, -4.128], "eeg_count": 256}
with open(os.path.join(out, "resolve_reference.json"), "w") as f:
    json.dump(ref, f, indent=1)
print("digitizer fixtures written")

# --- fsaverage FIF references (MNE readers) ----------------------------------
import shutil
bem = os.path.join(mne.datasets.fetch_fsaverage(verbose=False), "bem")
local = os.path.join(out, "local"); os.makedirs(local, exist_ok=True)
for name in ("fsaverage-head.fif", "fsaverage-5120-5120-5120-bem.fif", "fsaverage-trans.fif", "fsaverage-fiducials.fif"):
    shutil.copy(os.path.join(bem, name), local if name.startswith("fsaverage-h") or "5120" in name else out)
t = mne.read_trans(os.path.join(bem, "fsaverage-trans.fif"))
fids, frame = mne.io.read_fiducials(os.path.join(bem, "fsaverage-fiducials.fif"))
head = mne.read_bem_surfaces(os.path.join(bem, "fsaverage-head.fif"), verbose=False)[0]
surfs = mne.read_bem_surfaces(os.path.join(bem, "fsaverage-5120-5120-5120-bem.fif"), verbose=False)
ref["fif"] = {
    "trans": {"from": int(t["from"]), "to": int(t["to"]), "matrix": t["trans"].tolist()},
    "fiducials": {"frame": int(frame), "points": [{"kind": int(d["kind"]), "ident": int(d["ident"]), "r": d["r"].tolist()} for d in fids]},
    "head_surface": {"path": "local/fsaverage-head.fif", "id": int(head["id"]), "np": int(head["np"]), "ntri": int(head["ntri"]), "coord_frame": int(head["coord_frame"]),
                     "rr_first": head["rr"][:3].tolist(), "tris_first": head["tris"][:3].tolist(), "rr_mean": head["rr"].mean(0).tolist()},
    "bem_surfaces": {"path": "local/fsaverage-5120-5120-5120-bem.fif",
                     "surfaces": [{"id": int(s["id"]), "np": int(s["np"]), "ntri": int(s["ntri"]), "sigma": float(s["sigma"]), "rr_mean": s["rr"].mean(0).tolist()} for s in surfs]},
}
with open(os.path.join(out, "resolve_reference.json"), "w") as f:
    json.dump(ref, f, indent=1)
print("fif references written; local surfaces in", local)

# --- fsaverage T1 as NIfTI for the head-model end-to-end test (git-ignored) ----
t1 = nib.load(os.path.join(os.path.dirname(bem), "mri", "T1.mgz"))
t1_nii = nib.Nifti1Image(np.asarray(t1.dataobj, np.uint8), t1.affine)
nib.save(t1_nii, os.path.join(local, "fsaverage-T1.nii.gz"))
print("fsaverage T1 →", os.path.join(local, "fsaverage-T1.nii.gz"), t1_nii.shape)
