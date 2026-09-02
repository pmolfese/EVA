#!/usr/bin/env python
"""Read the NIfTI that NIfTIVolumeTests wrote and compare with the source fixture
through nibabel (independent reader). Run after the Swift tests."""
import os, sys, tempfile, numpy as np, nibabel as nib
here = os.path.dirname(__file__)
swift = os.path.join(tempfile.gettempdir(), "EVAResolveValidation", "swift_written.nii.gz")
ref = nib.load(os.path.join(here, "..", "..", "EVATests", "Fixtures", "Resolve", "phantom_qform_int16.nii"))
ref_can = nib.as_closest_canonical(ref)
img = nib.load(swift)
ok = True
if img.shape != ref_can.shape: print("shape mismatch", img.shape, ref_can.shape); ok = False
da = np.abs(img.affine - ref_can.affine).max()
if da > 1e-3: print("affine mismatch", da); ok = False
qa = np.abs(img.get_qform() - ref_can.affine).max()
if qa > 1e-3: print("qform mismatch", qa); ok = False
dv = np.abs(np.asarray(img.dataobj, np.float32) - np.asarray(ref_can.get_fdata(), np.float32)).max()
if dv > 1e-3: print("voxel mismatch", dv); ok = False
print("header codes: sform", int(img.header["sform_code"]), "qform", int(img.header["qform_code"]), "units", img.header.get_xyzt_units())
print("swift-written NIfTI OK (nibabel)" if ok else "FAILED")
sys.exit(0 if ok else 1)
