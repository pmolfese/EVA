#!/usr/bin/env python
"""Generate the MNE cross-check fixture for EVA's PART TF-1 validation gate.

Produces a deterministic multi-trial, single-channel dataset containing a known
oscillatory burst, runs MNE's Morlet time-frequency transform on it, and writes
both the input trials and the reference trial-averaged power to a committed JSON
fixture. EVA's `TimeFrequencyEngine` is asserted against this fixture in
`EVATests/TimeFrequency/TimeFrequencyEngineTests.swift`.

The fixture is generated OFFLINE and committed because the XCTest sandbox cannot
shell out to Python or write files. Regenerate with:

    /Users/molfesepj/micromamba/envs/mne/bin/python \
        EVATests/Fixtures/generate_tf_reference.py

Determinism: fixed RNG seed; the JSON round-trips exactly (full float precision).
"""

import json
import os

import numpy as np
from mne.time_frequency import tfr_array_morlet, tfr_array_multitaper
from scipy.signal.windows import dpss as scipy_dpss

# ---- Signal design ---------------------------------------------------------
SFREQ = 250.0            # Hz
N_TIMES = 1000           # 4.0 s epoch, t = [0, 4) s (long enough for a
                         # 7-cycle wavelet down to 4 Hz)
N_TRIALS = 40
BURST_FREQ = 6.0         # Hz — the injected oscillation
BURST_CENTER_S = 2.0     # s — burst latency (event-locked, mid-epoch)
BURST_SIGMA_S = 0.10     # s — Gaussian envelope width
BURST_AMP = 3.0          # µV — burst peak amplitude
NOISE_AMP = 1.0          # µV — white background
SEED = 0

# ---- Analysis grid (matches TFFrequencyPlan.explicit on the Swift side) ----
FREQS = list(np.arange(4.0, 40.0 + 1e-9, 2.0))   # 4..40 Hz by 2
N_CYCLES = 7.0
ZERO_MEAN = True         # tfr_array_morlet default
TIME_BANDWIDTH = 4.0     # multitaper: 3 good tapers

# A standalone DPSS case for the taper-generation unit test. Length matches a
# real multitaper wavelet: f=10 Hz, n_cycles=7, fs=250 → t_win=0.7 s → 175 samples.
DPSS_M = 175
DPSS_NW = TIME_BANDWIDTH / 2.0
DPSS_KMAX = int(np.floor(TIME_BANDWIDTH - 1))


def build_trials():
    rng = np.random.default_rng(SEED)
    t = np.arange(N_TIMES) / SFREQ
    envelope = np.exp(-((t - BURST_CENTER_S) ** 2) / (2.0 * BURST_SIGMA_S ** 2))
    burst = BURST_AMP * envelope * np.sin(2.0 * np.pi * BURST_FREQ * t)
    trials = np.empty((N_TRIALS, N_TIMES), dtype=np.float64)
    for i in range(N_TRIALS):
        noise = NOISE_AMP * rng.standard_normal(N_TIMES)
        trials[i] = burst + noise
    return trials


def main():
    trials = build_trials()
    freqs = np.asarray(FREQS, dtype=np.float64)

    # tfr_array_morlet wants (n_epochs, n_channels, n_times).
    data = trials[:, np.newaxis, :]
    avg_power = tfr_array_morlet(
        data,
        sfreq=SFREQ,
        freqs=freqs,
        n_cycles=N_CYCLES,
        zero_mean=ZERO_MEAN,
        use_fft=True,
        output="avg_power",
    )  # -> (n_channels=1, n_freqs, n_times)
    avg_power = np.asarray(avg_power)[0]  # (n_freqs, n_times)

    itc = tfr_array_morlet(
        data,
        sfreq=SFREQ,
        freqs=freqs,
        n_cycles=N_CYCLES,
        zero_mean=ZERO_MEAN,
        use_fft=True,
        output="itc",
    )
    itc = np.asarray(itc)[0]  # (n_freqs, n_times)

    # Multitaper references.
    mt_power = np.asarray(tfr_array_multitaper(
        data, sfreq=SFREQ, freqs=freqs, n_cycles=N_CYCLES,
        time_bandwidth=TIME_BANDWIDTH, use_fft=True, output="avg_power",
    ))[0]
    mt_itc = np.asarray(tfr_array_multitaper(
        data, sfreq=SFREQ, freqs=freqs, n_cycles=N_CYCLES,
        time_bandwidth=TIME_BANDWIDTH, use_fft=True, output="itc",
    ))[0]

    # Standalone DPSS tapers + concentration ratios (scipy, sym=False, L2 norm).
    dpss_tapers, dpss_ratios = scipy_dpss(
        DPSS_M, DPSS_NW, DPSS_KMAX, sym=False, return_ratios=True
    )

    fixture = {
        "description": "PART TF-1 MNE cross-check: burst + noise, tfr_array_morlet avg_power",
        "samplingRate": SFREQ,
        "nTimes": N_TIMES,
        "nTrials": N_TRIALS,
        "burstFrequencyHz": BURST_FREQ,
        "burstCenterSeconds": BURST_CENTER_S,
        "freqsHz": freqs.tolist(),
        "nCycles": N_CYCLES,
        "zeroMean": ZERO_MEAN,
        "trials": trials.tolist(),           # (n_trials, n_times)
        "avgPower": avg_power.tolist(),        # (n_freqs, n_times)
        "itc": itc.tolist(),                   # (n_freqs, n_times)
        "timeBandwidth": TIME_BANDWIDTH,
        "mtAvgPower": mt_power.tolist(),       # (n_freqs, n_times)
        "mtItc": mt_itc.tolist(),              # (n_freqs, n_times)
        "dpss": {
            "length": DPSS_M,
            "halfNBW": DPSS_NW,
            "kMax": DPSS_KMAX,
            "tapers": dpss_tapers.tolist(),    # (kMax, length)
            "ratios": dpss_ratios.tolist(),    # (kMax,)
        },
    }

    out_path = os.path.join(os.path.dirname(__file__), "tf_morlet_reference.json")
    with open(out_path, "w") as fh:
        json.dump(fixture, fh)
    print(f"wrote {out_path}")
    print(f"  trials={trials.shape}, avg_power={avg_power.shape}, freqs={freqs.size}")
    peak_fi, peak_ti = np.unravel_index(np.argmax(avg_power), avg_power.shape)
    print(f"  MNE peak at {freqs[peak_fi]:.1f} Hz, t={peak_ti / SFREQ:.3f} s")


if __name__ == "__main__":
    main()
