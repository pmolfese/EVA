#!/usr/bin/env python3
"""Generate EVA's independent paper-equation WTPL fixture.

This script intentionally uses only Python's standard library and does not call
the MATLAB-only WTPL repository. It is a clean equation-level oracle: direct
linear convolution, complex-plane fractional interpolation, per-trial WTPL,
online-equivalent condition means, explicit validity, and baseline subtraction.
"""

from __future__ import annotations

import argparse
import json
import math
import platform
from pathlib import Path


FS = 64.0
N = 128
FREQUENCIES = [8.0, 11.0]
WIDTHS = [5.0, 5.0]
LAGS = [-1.0, 1.0]
EVENT = 64
BASELINE = [24, 32]


def trials() -> list[list[float]]:
    result = []
    for trial in range(3):
        phase = [0.1, 1.7, -2.2][trial]
        row = []
        for index in range(N):
            time = index / FS
            reset = 0.9 if index >= 72 else 0.0
            chirp = 0.0025 * max(index - 64, 0) ** 2
            row.append(
                math.sin(2 * math.pi * 8 * time + phase + reset + chirp)
                + 0.28 * math.sin(2 * math.pi * 13 * time - 0.4 * phase)
            )
        result.append(row)
    return result


def morlet(frequency: float, width: float) -> list[complex]:
    sigma_frequency = frequency / width
    sigma_time = 1.0 / (2.0 * math.pi * sigma_frequency)
    tap_count = max(math.floor(6.0 * sigma_time * FS + 1e-12) + 1, 1)
    amplitude = 1.0 / math.sqrt(sigma_time * math.sqrt(math.pi))
    transform_scale = math.sqrt(2.0 / FS)
    phase_step = 2.0 * math.pi * frequency / FS
    phase_start = -(tap_count - 1) / 2.0
    envelope_start = -3.0 * sigma_time
    values = []
    for index in range(tap_count):
        envelope_time = envelope_start + index / FS
        envelope = (
            amplitude
            * math.exp(-(envelope_time**2) / (2.0 * sigma_time**2))
            * transform_scale
        )
        phase = (phase_start + index) * phase_step
        values.append(envelope * complex(math.cos(phase), math.sin(phase)))
    return values


def coefficients(signal: list[float], frequency: float, width: float) -> tuple[list[complex], range]:
    kernel = morlet(frequency, width)
    crop = len(kernel) // 2
    output = []
    for output_index in range(len(signal)):
        full_index = output_index + crop
        first_tap = max(0, full_index - (len(signal) - 1))
        last_tap = min(len(kernel) - 1, full_index)
        output.append(sum(signal[full_index - tap] * kernel[tap] for tap in range(first_tap, last_tap + 1)))
    lower = min(max(math.ceil(len(kernel) / 2.0) - 1, 0), len(signal))
    upper = max(min(math.ceil(len(signal) - len(kernel) / 2.0 - 1.0), len(signal)), 0)
    return output, range(lower, upper)


def interpolate(values: list[complex], valid: range, position: float) -> complex | None:
    lower = math.floor(position)
    fraction = position - lower
    if lower not in valid:
        return None
    if fraction <= 1e-12:
        return values[lower]
    if lower + 1 not in valid:
        return None
    return values[lower] + fraction * (values[lower + 1] - values[lower])


def trial_wtpl(signal: list[float], frequency: float, width: float) -> list[float | None]:
    values, valid = coefficients(signal, frequency, width)
    output: list[float | None] = [None] * len(signal)
    for time in valid:
        center = values[time]
        if abs(center) == 0:
            continue
        relations = []
        for lag in LAGS:
            lagged = interpolate(values, valid, time + lag / frequency * FS)
            if lagged is None or abs(lagged) == 0:
                break
            relations.append(center / abs(center) * (lagged / abs(lagged)).conjugate())
        if len(relations) == len(LAGS):
            output[time] = abs(sum(relations) / len(relations))
    return output


def clean(value: float | None) -> float | None:
    return None if value is None or not math.isfinite(value) else round(value, 15)


def generate() -> dict:
    input_trials = trials()
    per_trial = [
        [trial_wtpl(signal, frequency, width) for frequency, width in zip(FREQUENCIES, WIDTHS)]
        for signal in input_trials
    ]
    means = []
    counts = []
    variances = []
    deltas = []
    for fi in range(len(FREQUENCIES)):
        mean_row, count_row, variance_row = [], [], []
        for ti in range(N):
            finite = [per_trial[trial][fi][ti] for trial in range(len(input_trials))]
            finite = [value for value in finite if value is not None]
            count_row.append(len(finite))
            if not finite:
                mean_row.append(None)
                variance_row.append(None)
            else:
                mean = sum(finite) / len(finite)
                mean_row.append(mean)
                variance_row.append(
                    sum((value - mean) ** 2 for value in finite) / (len(finite) - 1)
                    if len(finite) > 1 else None
                )
        baseline_values = [mean_row[index] for index in range(BASELINE[0], BASELINE[1] + 1) if mean_row[index] is not None]
        baseline_mean = sum(baseline_values) / len(baseline_values)
        delta_row = [None if value is None else value - baseline_mean for value in mean_row]
        means.append([clean(value) for value in mean_row])
        counts.append(count_row)
        variances.append([clean(value) for value in variance_row])
        deltas.append([clean(value) for value in delta_row])
    return {
        "schema": "org.nih.eva.wtpl-oracle",
        "schemaVersion": 1,
        "methodVersion": "paper-equation-python-v1",
        "generator": "Tools/RhythmicityReference/generate_wtpl_oracle.py",
        "python": platform.python_version(),
        "equation": "abs(mean(unit(z[t]) * conj(unit(z[t + lag])) over lag))",
        "input": {
            "samplingRateHz": FS,
            "eventSampleIndex": EVENT,
            "frequenciesHz": FREQUENCIES,
            "nCycles": WIDTHS,
            "lagCycles": LAGS,
            "baselineSamplesInclusive": BASELINE,
            "trials": input_trials,
        },
        "expected": {
            "meanWTPL": means,
            "deltaWTPL": deltas,
            "validTrialCounts": counts,
            "varianceWTPL": variances,
        },
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="write JSON to this path; stdout when omitted")
    arguments = parser.parse_args()
    text = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(text, encoding="utf-8")
    else:
        print(text, end="")
