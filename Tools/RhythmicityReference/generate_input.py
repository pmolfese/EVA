#!/usr/bin/env python3
"""Generate EVA-owned deterministic inputs for LAVI/ABBA reference runs.

This file deliberately contains no code from either upstream toolbox.  It
creates a compact synthetic signal and hand-authored edge cases that can be
fed to the independently installed MATLAB and Python implementations.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def build_input() -> dict:
    sampling_rate = 200.0
    sample_count = 2400
    channel_1 = []
    channel_2 = []
    for sample in range(sample_count):
        time = sample / sampling_rate
        # Continuous alpha plus a short 18-Hz packet.  The second channel has
        # deterministic phase resets every two seconds, which makes it useful
        # for checking that LAVI responds to persistence rather than power.
        packet = math.exp(-0.5 * ((time - 6.0) / 0.55) ** 2)
        channel_1.append(
            1.25 * math.sin(2 * math.pi * 10 * time)
            + 0.45 * math.sin(2 * math.pi * 6 * time + 0.3)
            + 1.10 * packet * math.sin(2 * math.pi * 18 * time - 0.2)
        )
        phase_reset = (sample // int(2 * sampling_rate)) * 0.9
        channel_2.append(
            1.25 * math.sin(2 * math.pi * 10 * time + phase_reset)
            + 0.45 * math.sin(2 * math.pi * 6 * time + 0.3)
            + 1.10 * packet * math.sin(2 * math.pi * 18 * time - 0.2)
        )

    frequencies = [10 ** (0.5 + 0.025 * index) for index in range(47)]

    lag_real = []
    lag_imag = []
    for sample in range(192):
        phase = 0.071 * sample + 0.00073 * sample * sample
        amplitude = 1.0 + 0.18 * math.sin(0.13 * sample)
        lag_real.append(amplitude * math.cos(phase))
        lag_imag.append(amplitude * math.sin(phase))

    abba_frequencies = [3, 4, 5, 6, 8, 10, 12, 14, 18, 24, 32, 44]
    abba_profile = [0.43, 0.51, 0.39, 0.34, 0.47, 0.66, 0.54, 0.41, 0.27, 0.46, 0.58, 0.37]
    lower = [0.34, 0.35, 0.35, 0.36, 0.36, 0.37, 0.37, 0.36, 0.35, 0.35, 0.34, 0.34]
    upper = [0.55, 0.56, 0.56, 0.57, 0.57, 0.58, 0.58, 0.57, 0.56, 0.56, 0.55, 0.55]

    return {
        "schemaVersion": 1,
        "generator": "Tools/RhythmicityReference/generate_input.py",
        "signal": {
            "samplingRateHz": sampling_rate,
            "sampleCount": sample_count,
            "channels": [channel_1, channel_2],
            "frequenciesHz": frequencies,
            "waveletWidthCycles": 5.0,
            "lagCycles": 1.5,
        },
        "impulseKernel": {
            "samplingRateHz": sampling_rate,
            "sampleCount": 1025,
            "impulseIndexZeroBased": 512,
            "frequencyHz": 10.0,
            "waveletWidthCycles": 5.0,
            "selectedIndicesZeroBased": [462, 487, 512, 537, 562],
        },
        "fractionalLag": {
            "samplingRateHz": sampling_rate,
            "frequencyHz": 13.0,
            "lagCycles": 1.5,
            "real": lag_real,
            "imaginary": lag_imag,
        },
        "abba": {
            "frequenciesHz": abba_frequencies,
            "lavi": abba_profile,
            "alphaRangeHz": [6.0, 14.0],
            "lowerLimits": lower,
            "upperLimits": upper,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(build_input(), indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
