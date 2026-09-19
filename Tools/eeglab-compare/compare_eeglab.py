#!/usr/bin/env python
"""Compares EVA's already-computed pipeline outputs against EEGLAB's
(Tools/eeglab-compare/run_eeglab_pipeline.m), on the same real flanker
recording. Reuses EVA's existing exports rather than re-running the Swift
side — EVA's pipeline didn't change between the MNE and EEGLAB comparisons,
only the reference package did.

Usage:
    /Users/molfesepj/micromamba/envs/mne/bin/python Tools/eeglab-compare/compare_eeglab.py
"""
import json
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
LOCAL = os.path.join(ROOT, "EVATests", "Fixtures", "Compare", "local")
EEGLAB_DIR = os.path.join(LOCAL, "eeglab")

EVA_PIPELINE_JSON = os.path.join(LOCAL, "eva_full_pipeline_erp.json")
EVA_REAL_REFERENCE_JSON = os.path.join(LOCAL, "real_reference.json")
EEGLAB_PIPELINE_JSON = os.path.join(EEGLAB_DIR, "eeglab_full_pipeline_erp.json")
EEGLAB_FILTER_INTERP_JSON = os.path.join(EEGLAB_DIR, "eeglab_filter_and_interp.json")


def agreement(a, b, label):
    diff = a - b
    rms = np.sqrt((diff ** 2).mean())
    ref_rms = np.sqrt((b ** 2).mean())
    corr = np.corrcoef(a.ravel(), b.ravel())[0, 1]
    print(f"{label}: relative RMS diff = {rms / ref_rms:.4%}, correlation = {corr:.6f}, "
          f"max |diff| = {np.max(np.abs(diff)):.3f} µV (signal RMS {ref_rms:.2f} µV)")
    return rms / ref_rms, corr


def compare_full_pipeline():
    with open(EVA_PIPELINE_JSON) as f:
        eva = json.load(f)
    with open(EEGLAB_PIPELINE_JSON) as f:
        eeglab = json.load(f)

    eva_names = eva["channelNames"]
    eeglab_names = eeglab["channelNames"]
    assert eva_names == eeglab_names, "channel order mismatch between EVA and EEGLAB exports"

    eva_data = np.array(eva["data"])
    conds = {c["category"]: c for c in eva["conditions"]}
    eva_epoch_len = eva["epochLength"]
    eva_congruent = eva_data[:, conds["congruent"]["startSample"]:conds["congruent"]["endSample"] + 1]
    eva_incongruent = eva_data[:, conds["incongruent"]["startSample"]:conds["incongruent"]["endSample"] + 1]

    eeglab_congruent = np.array(eeglab["evoked_congruent_uv"])
    eeglab_incongruent = np.array(eeglab["evoked_incongruent_uv"])
    n = eeglab["nTimesPerEpoch"]
    print(f"EVA epoch length: {eva_epoch_len}, EEGLAB nTimesPerEpoch: {n}")
    print(f"trials: congruent EVA={conds['congruent']['trialCount']} EEGLAB={eeglab['congruentTrialCount']}, "
          f"incongruent EVA={conds['incongruent']['trialCount']} EEGLAB={eeglab['incongruentTrialCount']}")

    m = min(eva_epoch_len, n)
    agreement(eva_congruent[:, :m], eeglab_congruent[:, :m], "Congruent, all channels (EVA vs EEGLAB)")
    agreement(eva_incongruent[:, :m], eeglab_incongruent[:, :m], "Incongruent, all channels (EVA vs EEGLAB)")

    sfreq = eva["samplingRate"]
    pre = eva["preSamples"]
    times_ms = (np.arange(m) - pre) / sfreq * 1000
    show_channels = ["E25", "E59", "E99"]

    fig, axes = plt.subplots(len(show_channels), 2, figsize=(11, 3 * len(show_channels)), sharex=True)
    for row, ch in enumerate(show_channels):
        i = eva_names.index(ch)
        for col, (label, eva_sig, eeglab_sig) in enumerate([
            ("Congruent", eva_congruent[i, :m], eeglab_congruent[i, :m]),
            ("Incongruent", eva_incongruent[i, :m], eeglab_incongruent[i, :m]),
        ]):
            ax = axes[row, col]
            ax.plot(times_ms, eeglab_sig, label="EEGLAB", color="#2ca02c", linewidth=1.5)
            ax.plot(times_ms, eva_sig, label="EVA", color="#d62728", linewidth=1.1, linestyle="--")
            ax.axvline(0, color="gray", linewidth=0.7)
            ax.axhline(0, color="gray", linewidth=0.5)
            r = np.corrcoef(eva_sig, eeglab_sig)[0, 1]
            ax.set_title(f"{ch} — {label} (r={r:.4f})", fontsize=10)
            if row == len(show_channels) - 1:
                ax.set_xlabel("Time (ms)")
            if col == 0:
                ax.set_ylabel("µV")
            if row == 0 and col == 0:
                ax.legend(fontsize=8)
    fig.suptitle("EVA vs EEGLAB full pipeline (filter → interpolate E82/E66 → avg-ref → epoch → baseline → average)",
                 fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    out = os.path.join(os.path.dirname(__file__), "erp_comparison_eeglab.png")
    fig.savefig(out, dpi=150)
    print("wrote", out)


def compare_filter_and_interp():
    with open(EEGLAB_FILTER_INTERP_JSON) as f:
        eeglab = json.load(f)
    with open(EVA_REAL_REFERENCE_JSON) as f:
        eva = json.load(f)

    # --- filter: same 20 s / 12-channel window as make_real_reference.py
    eva_channels = eva["channels"]
    eeglab_channels = eeglab["filter"]["channels"]
    assert eva_channels == eeglab_channels, (eva_channels, eeglab_channels)
    eva_filtered = None  # EVA's Swift-side filtered output isn't in real_reference.json (that's MNE-only);
    # this function compares EEGLAB's filter against MNE's (already computed) instead, plus prints EEGLAB's
    # own numbers for the record. The apples-to-apples EVA-vs-EEGLAB *filter* check is the full-pipeline
    # comparison above, which includes EVA's actual filtered/interpolated/referenced signal.
    mne_filtered = np.array(eva["filter"]["filtered_mne_uv"])
    eeglab_filtered = np.array(eeglab["filter"]["filtered_uv"])
    # EEGLAB's pop_select 'time' crop is inclusive of both endpoints (one
    # sample longer than MNE's half-open raw.crop(..., include_tmax=False),
    # matching the epoch-length convention difference documented elsewhere
    # in this comparison) — truncate to the shorter length before comparing.
    m = min(mne_filtered.shape[1], eeglab_filtered.shape[1])
    trim = int(4 * eva["sampling_rate"])
    a = eeglab_filtered[:, trim:m - trim]
    b = mne_filtered[:, trim:m - trim]
    agreement(a, b, "Filter (1-40 Hz), EEGLAB vs MNE, interior")

    # --- interpolation: EEGLAB defaults (lambda=0, 7 terms) vs EEGLAB with EVA's own (lambda, terms)
    default_uv = np.array(eeglab["interpolation"]["interpolated_default_uv"])
    eva_params_uv = np.array(eeglab["interpolation"]["interpolated_eva_params_uv"])
    mne_interp_uv_full = np.array(eva["interpolation"]["interpolated_uv"])
    m2 = min(default_uv.shape[0], eva_params_uv.shape[0], mne_interp_uv_full.shape[0])
    default_uv, eva_params_uv, mne_interp_uv_full = default_uv[:m2], eva_params_uv[:m2], mne_interp_uv_full[:m2]
    diff = default_uv - eva_params_uv
    rel = np.sqrt((diff ** 2).mean()) / np.sqrt((eva_params_uv ** 2).mean())
    print(f"eeg_interp: default params (lambda=0, 7 terms) vs EVA's params (lambda=1e-5, 40 terms) "
          f"run THROUGH EEGLAB's OWN function: relative RMS diff = {rel:.4%}, "
          f"max|diff| = {np.max(np.abs(diff)):.3f} µV — isolates the parameter choice from any "
          f"cross-package implementation difference.")

    # Also compare against MNE's interpolation of the *same* target/window from real_reference.json,
    # which used the same target channel (E50) and the same 12-channel set.
    agreement(default_uv[None, :], mne_interp_uv_full[None, :], "Interpolation of E50, EEGLAB defaults vs MNE")
    agreement(eva_params_uv[None, :], mne_interp_uv_full[None, :], "Interpolation of E50, EEGLAB w/ EVA's params vs MNE")

    sfreq = eeglab["interpolation"]["samplingRate"]
    t = np.arange(m2) / sfreq
    fig, ax = plt.subplots(figsize=(12, 4))
    ax.plot(t, mne_interp_uv_full, label="MNE (alpha=1e-5, 50 terms)", color="#1f77b4", linewidth=1.3)
    ax.plot(t, eva_params_uv, label="EEGLAB w/ EVA's params (lambda=1e-5, 40 terms)", color="#d62728",
            linewidth=1.1, linestyle="--")
    ax.plot(t, default_uv, label="EEGLAB DEFAULT (lambda=0, 7 terms)", color="#ff7f0e", linewidth=1.1, linestyle=":")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("µV")
    ax.set_title("Interpolated E50 (real recording): EEGLAB's default spherical-spline\nparameters diverge from EVA/MNE — same algorithm, very different regularization/order")
    ax.legend(fontsize=9)
    fig.tight_layout()
    out = os.path.join(os.path.dirname(__file__), "interpolation_eeglab_default_vs_matched.png")
    fig.savefig(out, dpi=150)
    print("wrote", out)


if __name__ == "__main__":
    compare_full_pipeline()
    print()
    compare_filter_and_interp()
