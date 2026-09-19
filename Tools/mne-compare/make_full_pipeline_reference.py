#!/usr/bin/env python
"""Full preprocessing-to-average pipeline on a real flanker recording, run
with MNE, then compared against EVA's own pipeline output
(EVATests/Fixtures/Compare/local/eva_full_pipeline_erp.json, written by
running the `FullPipelineERPExport` Swift Testing suite).

Pipeline (same steps, same parameters, on both sides):
  1. Band-pass filter 1-40 Hz (FIR, firwin, Hamming, zero-phase)
  2. Interpolate two flagged-bad channels (E82, E66 — see README)
  3. Average reference (all 129 channels, post-interpolation)
  4. Epoch congruent (LC++/RC++) vs incongruent (LI++/RI++) flanker trials,
     tmin=-0.2, tmax=0.8
  5. Baseline-correct (pre-stimulus window only, EVA's exclusive convention)
  6. Average each condition

Usage:
    /Users/molfesepj/micromamba/envs/mne/bin/python \\
        Tools/mne-compare/make_full_pipeline_reference.py [path/to/recording.mff]

Writes a comparison figure to Tools/mne-compare/erp_comparison.png and prints
agreement statistics.
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
EVA_JSON = os.path.join(ROOT, "EVATests", "Fixtures", "Compare", "local", "eva_full_pipeline_erp.json")
FIG_PATH = os.path.join(os.path.dirname(__file__), "erp_comparison.png")

DEFAULT_PATH = os.path.expanduser(
    "~/Desktop/MFF_tests/24624/24624_flanker_run1_20240322_053029.mff"
)

BAD_CHANNELS = ["E82", "E66"]
CONGRUENT_CODES = ["LC++", "RC++"]
INCONGRUENT_CODES = ["LI++", "RI++"]
TMIN, TMAX = -0.2, 0.8


def run_mne_pipeline(mff_path, channel_names):
    raw = mne.io.read_raw_egi(mff_path, preload=True)
    # Pick exactly the channels EVA's export used, in that order — whatever
    # EVA's MFFReader found as "E<n>"-named channels, which is what actually
    # matters for this comparison to line up (not a hardcoded expected count).
    raw.pick(channel_names)

    raw.filter(l_freq=1.0, h_freq=40.0, method="fir", fir_design="firwin",
               fir_window="hamming", phase="zero", verbose=False)

    raw.info["bads"] = BAD_CHANNELS
    raw.interpolate_bads(reset_bads=True, method={"eeg": "spline"}, verbose=False)

    raw.set_eeg_reference(ref_channels="average", projection=False, verbose=False)

    events, event_id = mne.events_from_annotations(raw, verbose=False)
    sfreq = raw.info["sfreq"]
    # EVA's baseline window is pre-stimulus-only, excluding the event sample
    # itself (see MNEReferenceTests / README) — match that convention here so
    # the comparison isn't measuring the known baseline-window difference.
    baseline = (None, -1.0 / sfreq)

    congruent_id = {k: v for k, v in event_id.items() if k in CONGRUENT_CODES}
    incongruent_id = {k: v for k, v in event_id.items() if k in INCONGRUENT_CODES}

    epochs_congruent = mne.Epochs(raw, events, event_id=congruent_id, tmin=TMIN, tmax=TMAX,
                                   baseline=baseline, preload=True, verbose=False)
    epochs_incongruent = mne.Epochs(raw, events, event_id=incongruent_id, tmin=TMIN, tmax=TMAX,
                                     baseline=baseline, preload=True, verbose=False)

    evoked_congruent = epochs_congruent.average()
    evoked_incongruent = epochs_incongruent.average()
    return raw.ch_names, sfreq, evoked_congruent, evoked_incongruent, len(epochs_congruent), len(epochs_incongruent)


def main():
    mff_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
    if not os.path.isdir(mff_path):
        print(f"no MFF package at {mff_path}", file=sys.stderr)
        return 1
    if not os.path.exists(EVA_JSON):
        print(f"missing {EVA_JSON} — run the FullPipelineERPExport Swift test first "
              f"(xcodebuild test -only-testing:EVATests/FullPipelineERPExport)", file=sys.stderr)
        return 1

    with open(EVA_JSON) as f:
        eva = json.load(f)
    eva_names = eva["channelNames"]
    eva_data = np.array(eva["data"])  # (channels, concatenated-conditions samples), µV
    print(f"EVA export used {len(eva_names)} channels, bad={eva['badChannels']}")

    ch_names, sfreq, evoked_c, evoked_i, n_c, n_i = run_mne_pipeline(mff_path, eva_names)
    assert eva_names == ch_names, "channel order mismatch between EVA export and MNE pick order"

    conditions = {c["category"]: c for c in eva["conditions"]}
    eva_epoch_len = eva["epochLength"]
    mne_n_times = evoked_c.data.shape[1]
    print(f"EVA epoch length: {eva_epoch_len}, MNE n_times: {mne_n_times} "
          f"(expected MNE = EVA + 1, the documented epoch-length convention difference)")

    eva_congruent_uv = eva_data[:, conditions["congruent"]["startSample"]:conditions["congruent"]["endSample"] + 1]
    eva_incongruent_uv = eva_data[:, conditions["incongruent"]["startSample"]:conditions["incongruent"]["endSample"] + 1]
    mne_congruent_uv = evoked_c.data[:, :eva_epoch_len] * 1e6
    mne_incongruent_uv = evoked_i.data[:, :eva_epoch_len] * 1e6

    times_ms = (np.arange(eva_epoch_len) - eva["preSamples"]) / sfreq * 1000

    def agreement(a, b, label):
        diff = a - b
        rms = np.sqrt((diff ** 2).mean())
        ref_rms = np.sqrt((b ** 2).mean())
        corr = np.corrcoef(a.ravel(), b.ravel())[0, 1]
        print(f"{label}: relative RMS diff = {rms / ref_rms:.4%}, correlation = {corr:.6f}, "
              f"max |diff| = {np.max(np.abs(diff)):.2f} µV (signal RMS {ref_rms:.2f} µV)")
        return rms / ref_rms, corr

    print(f"trials: congruent EVA={conditions['congruent']['trialCount']} MNE={n_c}, "
          f"incongruent EVA={conditions['incongruent']['trialCount']} MNE={n_i}")
    agreement(eva_congruent_uv, mne_congruent_uv, "Congruent, all channels")
    agreement(eva_incongruent_uv, mne_incongruent_uv, "Incongruent, all channels")

    # A representative central-ish channel and the two worst-agreeing channels,
    # picked by correlation, so the figure isn't cherry-picked to look good.
    per_channel_corr = [
        np.corrcoef(eva_congruent_uv[i], mne_congruent_uv[i])[0, 1] for i in range(len(ch_names))
    ]
    worst = np.argsort(per_channel_corr)[:2]
    best_like = int(np.argmax(per_channel_corr))
    show_channels = sorted(set([best_like, *worst]))

    fig, axes = plt.subplots(len(show_channels), 2, figsize=(11, 3 * len(show_channels)), sharex=True)
    if len(show_channels) == 1:
        axes = axes[None, :]
    for row, ch in enumerate(show_channels):
        for col, (cond_name, eva_uv, mne_uv) in enumerate([
            ("Congruent", eva_congruent_uv, mne_congruent_uv),
            ("Incongruent", eva_incongruent_uv, mne_incongruent_uv),
        ]):
            ax = axes[row, col]
            ax.plot(times_ms, mne_uv[ch], label="MNE", color="#1f77b4", linewidth=1.5)
            ax.plot(times_ms, eva_uv[ch], label="EVA", color="#d62728", linewidth=1.2, linestyle="--")
            ax.axvline(0, color="gray", linewidth=0.7)
            ax.axhline(0, color="gray", linewidth=0.5)
            r = per_channel_corr[ch] if col == 0 else np.corrcoef(eva_incongruent_uv[ch], mne_incongruent_uv[ch])[0, 1]
            ax.set_title(f"{ch_names[ch]} — {cond_name} (r={r:.4f})", fontsize=10)
            if row == len(show_channels) - 1:
                ax.set_xlabel("Time (ms)")
            if col == 0:
                ax.set_ylabel("µV")
            if row == 0 and col == 0:
                ax.legend(loc="upper right", fontsize=8)
    fig.suptitle(
        f"EVA vs MNE full pipeline (filter → interpolate {'/'.join(BAD_CHANNELS)} → "
        f"avg-ref → epoch → baseline → average), flanker task",
        fontsize=11,
    )
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(FIG_PATH, dpi=150)
    print("wrote", FIG_PATH)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
