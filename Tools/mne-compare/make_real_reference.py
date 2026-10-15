#!/usr/bin/env python
"""Same parity checks as make_reference.py, but sourced from a real EGI MFF
acquisition instead of an idealized synthetic montage — real digitized
electrode positions (not unit-sphere 10-20 idealizations), a real recording's
noise floor, and real task events (an arrow-flanker paradigm).

Also covers band-pass filtering, which make_reference.py does not: EVA's
`.eeglabMNE` FIR design rule exists specifically to reproduce MNE's
`filter_data(..., fir_design='firwin')`, and this is a genuine numeric check
of that claim rather than a re-statement of it.

Usage:

    /Users/molfesepj/micromamba/envs/mne/bin/python Tools/mne-compare/make_real_reference.py \\
        [path/to/recording.mff]

Defaults to the path given on the command line; falls back to
`~/Desktop/MFF_tests/24624/24624_flanker_run1_20240322_053029.mff` if omitted.
Writes `EVATests/Fixtures/Compare/local/real_reference.json`, which is
git-ignored (see the note in Tools/mne-compare/README.md) — this is a real
subject's EEG, not something to commit. `MNERealFileReferenceTests.swift`
skips cleanly when the fixture is absent, the same pattern
`FIFInteropTests.readBEM` uses for its git-ignored fsaverage fixtures.
"""
import json
import os
import sys
import numpy as np
import mne

mne.set_log_level("WARNING")

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
OUT_DIR = os.path.join(ROOT, "EVATests", "Fixtures", "Compare", "local")
OUT_PATH = os.path.join(OUT_DIR, "real_reference.json")

DEFAULT_PATH = os.path.expanduser(
    "~/Desktop/MFF_tests/24624/24624_flanker_run1_20240322_053029.mff"
)

# Twelve channels spread across the GSN-128 numbering (which spirals outward
# from vertex), not a spatially curated subset — the point is real digitized
# geometry, not a hand-picked best case.
CHANNEL_NUMBERS = [1, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110]
TARGET_NUMBER = 50    # interpolated
REF_EXCLUDED_NUMBER = 110  # excluded from the average reference


def main():
    mff_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
    if not os.path.isdir(mff_path):
        print(f"no MFF package at {mff_path}; pass a path or edit DEFAULT_PATH", file=sys.stderr)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)

    channels = [f"E{n}" for n in CHANNEL_NUMBERS]
    target = f"E{TARGET_NUMBER}"
    ref_excluded = f"E{REF_EXCLUDED_NUMBER}"
    alpha = 1e-5

    raw_full = mne.io.read_raw_egi(mff_path, preload=True)
    sfreq = raw_full.info["sfreq"]
    events, event_id = mne.events_from_annotations(raw_full, verbose=False)

    # A 20 s window that contains several real flanker events (blk+/cue+/
    # LC++/LI++/RI++/RC++), picked by inspection of this file's annotations.
    crop_start_s = 15.0
    crop_end_s = 35.0
    raw = raw_full.copy().pick(channels).crop(tmin=crop_start_s, tmax=crop_end_s, include_tmax=False)
    data_uv = raw.get_data() * 1e6

    montage = raw_full.get_montage()
    dig_pos = montage.get_positions()["ch_pos"]
    positions = {ch: dig_pos[ch] for ch in channels}

    # ---------------------------------------------------------------- interpolation
    good_labels = [c for c in channels if c != target]
    pos_from = np.array([positions[c] for c in good_labels])
    pos_to = np.array([positions[target]])
    from mne.channels.interpolation import _make_interpolation_matrix
    with np.errstate(divide="ignore", over="ignore", invalid="ignore"):
        weight_row = _make_interpolation_matrix(pos_from, pos_to, alpha=alpha)[0]
    assert np.isfinite(weight_row).all() and abs(weight_row.sum() - 1) < 1e-6
    good_idx_interp = [channels.index(c) for c in good_labels]
    with np.errstate(divide="ignore", over="ignore", invalid="ignore"):
        interpolated_uv = weight_row @ data_uv[good_idx_interp]
    assert np.isfinite(interpolated_uv).all()

    # ---------------------------------------------------------------- average reference
    excluded_idx = channels.index(ref_excluded)
    good_idx_ref = [i for i in range(len(channels)) if i != excluded_idx]
    ref_signal = data_uv[good_idx_ref].mean(axis=0)
    avg_ref_uv = data_uv - ref_signal

    # ---------------------------------------------------------------- band-pass filter
    # `.eeglabMNE` + `.delayCompensated` + Hamming is EVA's claimed
    # reproduction of `mne.filter.filter_data(..., method='fir',
    # fir_design='firwin', fir_window='hamming', phase='zero')` — the
    # zero-phase default. Both use the 3.3/transition Hamming length rule and
    # the same 25%-clamped-at-2Hz transition width, so this checks that claim
    # against a real recording's filter response rather than a synthetic one.
    l_freq, h_freq = 1.0, 40.0
    filtered_mne = raw.copy().filter(
        l_freq=l_freq, h_freq=h_freq, method="fir", fir_design="firwin",
        fir_window="hamming", phase="zero", verbose=False,
    )
    filtered_mne_uv = filtered_mne.get_data() * 1e6

    def r(arr, ndigits=6):
        return np.round(np.asarray(arr), ndigits).tolist()

    fixture = {
        "description": "Real-recording reference values for EVA-vs-MNE parity tests (see Tools/mne-compare). Not for distribution — a real subject's EEG.",
        "source_path": mff_path,
        "channels": channels,
        "positions": {c: positions[c].tolist() for c in channels},
        "sampling_rate": sfreq,
        "signal_uv": r(data_uv),
        "interpolation": {
            "target": target,
            "good_channels": good_labels,
            "alpha": alpha,
            "weights": r(weight_row),
            "interpolated_uv": r(interpolated_uv),
        },
        "average_reference": {
            "excluded": ref_excluded,
            "output_uv": r(avg_ref_uv),
        },
        "filter": {
            "l_freq": l_freq,
            "h_freq": h_freq,
            "filtered_mne_uv": r(filtered_mne_uv),
        },
    }

    with open(OUT_PATH, "w") as f:
        json.dump(fixture, f, indent=1)
    print("wrote", OUT_PATH)
    print("interpolation weight sum:", weight_row.sum())
    print("recording:", mff_path)
    print("window:", crop_start_s, "-", crop_end_s, "s;", data_uv.shape[1], "samples;", len(channels), "channels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
