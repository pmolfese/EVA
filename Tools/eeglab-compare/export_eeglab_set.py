#!/usr/bin/env python
"""Exports a real MFF recording to EEGLAB .set format via MNE, so MATLAB/
EEGLAB can load it without the mffmatlabio plugin (not installed here).

Verified by hand that the round trip preserves what the EEGLAB-side
comparison needs: real channel positions (X/Y/Z, sph_theta/phi/radius) and
real annotation event types (LC++/LI++/RI++/RC++/blk+/cue+) both survive.

Usage:
    /Users/molfesepj/micromamba/envs/mne/bin/python \\
        Tools/eeglab-compare/export_eeglab_set.py [path/to/recording.mff]

Writes EVATests/Fixtures/Compare/local/eeglab/full.set (git-ignored, real
subject EEG — ~270 MB for the reference flanker recording, data embedded
inline rather than a separate .fdt).
"""
import os
import sys
import mne

mne.set_log_level("WARNING")

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
OUT_DIR = os.path.join(ROOT, "EVATests", "Fixtures", "Compare", "local", "eeglab")
DEFAULT_PATH = os.path.expanduser(
    "~/Desktop/MFF_tests/24624/24624_flanker_run1_20240322_053029.mff"
)


def main():
    mff_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
    if not os.path.isdir(mff_path):
        print(f"no MFF package at {mff_path}", file=sys.stderr)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)

    raw = mne.io.read_raw_egi(mff_path, preload=True)
    raw.pick([ch for ch in raw.ch_names if ch.startswith("E") and ch[1:].isdigit()])
    out_path = os.path.join(OUT_DIR, "full.set")
    raw.export(out_path, fmt="eeglab", overwrite=True)
    print(f"wrote {out_path}: {len(raw.ch_names)} channels, {raw.info['sfreq']} Hz, {raw.times[-1]:.1f} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
