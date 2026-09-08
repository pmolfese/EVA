#!/usr/bin/env python
"""Read an OpenMEEG head model EVA wrote, with OpenMEEG itself.

A clean pass prints no "Global reorientation of interface ..." lines: OpenMEEG's
.tri winding is the reverse of MNE's, EVA writes it that way deliberately, and a
reorientation message means the writer has drifted back to MNE's convention.

    /Users/molfesepj/micromamba/envs/mne/bin/python \
        Tools/forward-compare/check_swift_openmeeg.py <directory-with-.geom>

EVA's `OpenMEEGGeometry.write` exists so a model EVA is holding can be handed to
`om_assemble`. That claim is only worth making if OpenMEEG can actually load the
files, which is what this checks — the same role `check_swift_fif.py` plays for
the FIF writer. Run it after the Swift side writes a model (the round-trip test
in EVATests/IO/BEMImportTests.swift writes one to a temporary directory; point
this at a copy).
"""
import glob, os, sys

def main(directory):
    geoms = sorted(glob.glob(os.path.join(directory, "*.geom")))
    if not geoms:
        print(f"no .geom in {directory}", file=sys.stderr)
        return 1
    import openmeeg as om
    for geom in geoms:
        cond = os.path.splitext(geom)[0] + ".cond"
        if not os.path.exists(cond):
            print(f"FAIL {geom}: no matching .cond", file=sys.stderr)
            return 1
        geometry = om.read_geometry(geom, cond)
        ok = bool(geometry.selfCheck())
        nested = bool(geometry.is_nested())
        ok = ok and nested
        print(f"{'OK  ' if ok else 'FAIL'} {os.path.basename(geom)}: "
              f"conductivities={bool(geometry.has_conductivities())}, "
              f"nested={nested}, selfCheck={bool(geometry.selfCheck())}")
        if not ok:
            return 1
        # The real test: OpenMEEG assembles a head matrix from what EVA wrote.
        head = om.HeadMat(geometry)
        print(f"     om.HeadMat assembled: {head.nlin()} x {head.ncol()}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
