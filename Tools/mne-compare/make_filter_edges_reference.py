#!/usr/bin/env python
"""Checks whether EVA's continuous zero-phase filters show an edge artifact
at the start/end of a real recording, and whether MNE shows the same thing.

Reads EVATests/Fixtures/Compare/local/eva_filter_edges.json (written by the
FilterEdgeExport Swift Testing suite), runs MNE's IIR (Butterworth) and FIR
(firwin) filters on the SAME full continuous recording, and plots the first
and last few seconds of both against EVA's output.

Usage:
    /Users/molfesepj/micromamba/envs/mne/bin/python \\
        Tools/mne-compare/make_filter_edges_reference.py [path/to/recording.mff]
"""
import json
import os
import sys
import numpy as np
import mne
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

mne.set_log_level("WARNING")

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
EVA_JSON = os.path.join(ROOT, "EVATests", "Fixtures", "Compare", "local", "eva_filter_edges.json")
FIG_PATH = os.path.join(os.path.dirname(__file__), "filter_edges.png")
DEFAULT_PATH = os.path.expanduser(
    "~/Desktop/MFF_tests/24624/24624_flanker_run1_20240322_053029.mff"
)


def main():
    mff_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
    if not os.path.exists(EVA_JSON):
        print(f"missing {EVA_JSON} — run FilterEdgeExport first", file=sys.stderr)
        return 1

    with open(EVA_JSON) as f:
        eva = json.load(f)
    names = eva["channelNames"]
    sfreq = eva["samplingRate"]
    edge_seconds = eva["edgeSeconds"]
    edge_samples = int(edge_seconds * sfreq)

    raw = mne.io.read_raw_egi(mff_path, preload=True)
    raw.pick(names)

    raw_iir = raw.copy().filter(l_freq=1.0, h_freq=40.0, method="iir", verbose=False)
    raw_fir = raw.copy().filter(l_freq=1.0, h_freq=40.0, method="fir", fir_design="firwin",
                                 fir_window="hamming", phase="zero", verbose=False)
    iir_data = raw_iir.get_data() * 1e6
    fir_data = raw_fir.get_data() * 1e6
    n_times = iir_data.shape[1]

    fig, axes = plt.subplots(len(names), 4, figsize=(18, 3 * len(names)))
    for row, ch in enumerate(names):
        eva_iir_start = np.array(eva["iir"][row]["start"])
        eva_iir_end = np.array(eva["iir"][row]["end"])
        eva_fir_start = np.array(eva["fir"][row]["start"])
        eva_fir_end = np.array(eva["fir"][row]["end"])

        mne_iir_start = iir_data[row, :edge_samples]
        mne_iir_end = iir_data[row, n_times - edge_samples:]
        mne_fir_start = fir_data[row, :edge_samples]
        mne_fir_end = fir_data[row, n_times - edge_samples:]

        t_start = np.arange(edge_samples) / sfreq
        t_end = np.arange(edge_samples) / sfreq

        panels = [
            ("IIR (Butterworth) — start", t_start, mne_iir_start, eva_iir_start),
            ("IIR (Butterworth) — end", t_end, mne_iir_end, eva_iir_end),
            ("FIR (firwin/Hamming) — start", t_start, mne_fir_start, eva_fir_start),
            ("FIR (firwin/Hamming) — end", t_end, mne_fir_end, eva_fir_end),
        ]
        for col, (title, t, mne_sig, eva_sig) in enumerate(panels):
            ax = axes[row, col]
            ax.plot(t, mne_sig, label="MNE", color="#1f77b4", lw=1.3)
            ax.plot(t, eva_sig, label="EVA", color="#d62728", lw=1.0, ls="--")
            ax.set_title(f"{ch} — {title}", fontsize=9)
            if col == 0:
                ax.set_ylabel("µV")
            if row == len(names) - 1:
                ax.set_xlabel("Time (s)")
            if row == 0 and col == 0:
                ax.legend(fontsize=8)

    fig.suptitle(f"First/last {edge_seconds}s of the continuous 1-40 Hz filtered recording, EVA vs MNE",
                 fontsize=12)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(FIG_PATH, dpi=150)
    print("wrote", FIG_PATH)

    # Quantify: how much bigger is the edge than the "interior" typically gets?
    for row, ch in enumerate(names):
        interior = iir_data[row, edge_samples:n_times - edge_samples]
        interior_p2p = np.percentile(interior, 99) - np.percentile(interior, 1)
        for label, arr in [("EVA IIR start", eva["iir"][row]["start"]), ("MNE IIR start", mne_iir_start),
                            ("EVA FIR start", eva["fir"][row]["start"]), ("MNE FIR start", mne_fir_start)]:
            arr = np.array(arr)
            print(f"{ch} {label}: peak={np.max(np.abs(arr)):.1f} µV vs interior 1-99pct range {interior_p2p:.1f} µV")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
