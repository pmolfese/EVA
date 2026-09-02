#!/usr/bin/env python
"""Read the FIF files FIFInteropTests wrote with MNE-Python. Run after the Swift tests."""
import os, sys, tempfile, numpy as np, mne
d = os.path.join(tempfile.gettempdir(), "EVAResolveValidation")
ok = True
ref = mne.read_trans(os.path.join(os.path.dirname(__file__), "..", "..", "EVATests", "Fixtures", "Resolve", "fsaverage-trans.fif"))
t = mne.read_trans(os.path.join(d, "swift-trans.fif"))
if t["from"] != ref["from"] or t["to"] != ref["to"] or np.abs(t["trans"] - ref["trans"]).max() > 1e-6: print("trans mismatch"); ok = False
t2 = mne.read_trans(os.path.join(d, "swift-headmri-trans.fif")); print("head→mri trans frames", t2["from"], t2["to"])
dig, frame = mne.io.read_fiducials(os.path.join(d, "swift-dig.fif"))
kinds = [int(p["kind"]) for p in dig]
print("dig: frame", frame, "n", len(dig), "cardinal", kinds.count(1), "eeg", kinds.count(3), "extra", kinds.count(4))
if kinds.count(1) != 3 or kinds.count(3) != 8 or kinds.count(4) != 1: print("dig counts wrong"); ok = False
surfs = mne.read_bem_surfaces(os.path.join(d, "swift-bem.fif"), verbose=False)
print("bem:", [(s["id"], s["np"], s["ntri"], round(float(s["sigma"]), 4), s["coord_frame"]) for s in surfs])
if [s["id"] for s in surfs] != [4, 3, 1] or any(s["np"] != 162 or s["ntri"] != 320 for s in surfs): print("bem surfaces wrong"); ok = False
# MNE's BEM solver accepts the surfaces (closed, oriented, nested) — the real interop test.
try:
    sol = mne.make_bem_solution(surfs, verbose=False)
    print("MNE make_bem_solution OK:", sol["solution"].shape)
except Exception as e:
    print("make_bem_solution failed:", type(e).__name__, str(e)[:160]); ok = False
print("swift-written FIF OK (MNE)" if ok else "FAILED"); sys.exit(0 if ok else 1)
