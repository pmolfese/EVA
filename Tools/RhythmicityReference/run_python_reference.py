#!/usr/bin/env python3
"""Run a pinned LAVI Python checkout as a black-box numerical oracle."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import scipy
from scipy.io import loadmat


def revision(checkout: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()


def finite_list(values) -> list:
    array = np.asarray(values)
    if np.iscomplexobj(array):
        raise TypeError("complex values must be split before serialization")
    return [None if not np.isfinite(value) else float(value) for value in array.ravel()]


def matrix(values) -> list[list[float | None]]:
    array = np.asarray(values)
    return [finite_list(row) for row in array]


def band_matrices(values) -> list[list[list[float | None]]]:
    return [matrix(value) for value in values]


def run_author_example(lavi_python: Path, lavi_module) -> dict:
    data_dir = lavi_python / "data"
    loaded = loadmat(data_dir / "data.mat", squeeze_me=True, struct_as_record=False)["data"]
    frequencies = 10 ** np.arange(0.5, 1.65 + 1e-12, 0.025)
    current, _ = lavi_module.prepare_lavi(
        {
            "fs": float(loaded.fs),
            "foi": frequencies,
            "lag": 1.5,
            "width": 5.0,
            "verbose": False,
        },
        np.asarray(loaded.trial),
    )
    bundled_python = loadmat(data_dir / "python_lavi_results.mat")["LAVI"]
    bundled_matlab = loadmat(data_dir / "matlab_lavi_results.mat")["LAVI"]

    # Reproduce walkthrough Option A (legacy lookup table) and Option C (no
    # inferential limits). Option B's 20 raw extrema is intentionally not run:
    # it is an exploratory envelope, not the paper's alpha=.05 procedure.
    lookup = loadmat(data_dir / "SIGLIM.mat", squeeze_me=True, struct_as_record=False)
    limits_table = lookup["SIGLIM"]
    parameters = lookup["pmtrSIG"]
    duration = float(np.asarray(loaded.time)[-1] - np.asarray(loaded.time)[0])
    duration_index = int(np.argmin(np.abs(np.asarray(parameters.DUR) - duration)))
    rate_index = int(np.argmin(np.abs(np.asarray(parameters.FS) - float(loaded.fs))))
    limits = np.zeros((current.shape[0], current.shape[1], 2), dtype=float)
    slopes = []
    for channel in range(current.shape[0]):
        _, slope = lavi_module.get_ap_of_power(
            np.asarray(loaded.trial)[channel],
            float(loaded.fs),
            flim=(float(frequencies[0]), float(frequencies[-1])),
        )
        slopes.append(float(slope))
        slope_index = int(np.argmin(np.abs(np.asarray(parameters.B) - slope)))
        limits[channel] = limits_table[duration_index, rate_index, slope_index]
    lookup_borders, _, lookup_significance = lavi_module.abba(
        current, frequencies, [6.0, 14.0], limits, per_freq=False
    )
    exploratory_borders, _, _ = lavi_module.abba(current, frequencies)

    def comparison(reference) -> dict:
        difference = np.abs(current - reference)
        return {
            "maxAbsoluteDifference": float(np.nanmax(difference)),
            "meanAbsoluteDifference": float(np.nanmean(difference)),
            "correlation": float(np.corrcoef(current.ravel(), reference.ravel())[0, 1]),
        }

    return {
        "inputShape": list(np.asarray(loaded.trial).shape),
        "samplingRateHz": float(loaded.fs),
        "outputShape": list(current.shape),
        "walkthroughOptionA": {
            "durationTableValueSeconds": float(np.asarray(parameters.DUR)[duration_index]),
            "samplingRateTableValueHz": float(np.asarray(parameters.FS)[rate_index]),
            "estimatedAperiodicSlopes": slopes,
            "bandCounts": [int(item.shape[0]) for item in lookup_borders],
            "significantBandCounts": [int(np.sum(item[:, 10])) for item in lookup_borders],
            "significantFrequencyCounts": [
                int(np.count_nonzero(item)) for item in lookup_significance
            ],
        },
        "walkthroughOptionC": {
            "bandCounts": [int(item.shape[0]) for item in exploratory_borders],
        },
        "currentVersusBundledPython": comparison(bundled_python),
        "currentVersusBundledMatlab": comparison(bundled_matlab),
        "bundledPythonVersusBundledMatlab": {
            "maxAbsoluteDifference": float(np.nanmax(np.abs(bundled_python - bundled_matlab))),
            "meanAbsoluteDifference": float(np.nanmean(np.abs(bundled_python - bundled_matlab))),
            "correlation": float(np.corrcoef(bundled_python.ravel(), bundled_matlab.ravel())[0, 1]),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lavi-checkout", required=True, type=Path)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--author-example-report", type=Path)
    args = parser.parse_args()

    found_revision = revision(args.lavi_checkout)
    if found_revision != args.expected_commit:
        raise SystemExit(
            f"wrong LAVI revision: expected {args.expected_commit}, found {found_revision}"
        )

    lavi_python = args.lavi_checkout / "python"
    sys.path.insert(0, str(lavi_python))
    import lavi
    from lavi.wavelets import wavelet_light

    source = json.loads(args.input.read_text(encoding="utf-8"))
    signal = source["signal"]
    samples = np.asarray(signal["channels"], dtype=float)
    frequencies = np.asarray(signal["frequenciesHz"], dtype=float)
    config = {
        "fs": signal["samplingRateHz"],
        "foi": frequencies,
        "lag": signal["lagCycles"],
        "width": signal["waveletWidthCycles"],
        "verbose": False,
    }
    lavi_profile, _ = lavi.prepare_lavi(config, samples)

    impulse = source["impulseKernel"]
    impulse_signal = np.zeros((1, impulse["sampleCount"]), dtype=float)
    impulse_signal[0, impulse["impulseIndexZeroBased"]] = 1.0
    impulse_spectrum = wavelet_light(
        impulse_signal,
        impulse["samplingRateHz"],
        np.asarray([impulse["frequencyHz"]]),
        impulse["waveletWidthCycles"],
    )[0, 0, :]
    selected = np.asarray(impulse["selectedIndicesZeroBased"], dtype=int)

    lag = source["fractionalLag"]
    lag_spectrum = np.asarray(lag["real"]) + 1j * np.asarray(lag["imaginary"])
    lag_result = lavi.compute_lavi(
        lag_spectrum,
        lag["samplingRateHz"],
        lag["frequencyHz"],
        lag["lagCycles"],
    )

    abba_input = source["abba"]
    abba_profile = np.asarray(abba_input["lavi"], dtype=float)
    abba_frequencies = np.asarray(abba_input["frequenciesHz"], dtype=float)
    limits = np.vstack([abba_input["lowerLimits"], abba_input["upperLimits"]])
    borders_global, names, significance_global = lavi.abba(
        abba_profile,
        abba_frequencies,
        abba_input["alphaRangeHz"],
        limits.copy(),
        per_freq=False,
        matlab_indices=True,
    )
    borders_per_frequency, _, significance_per_frequency = lavi.abba(
        abba_profile,
        abba_frequencies,
        abba_input["alphaRangeHz"],
        limits.copy(),
        per_freq=True,
        matlab_indices=True,
    )

    output = {
        "schemaVersion": 1,
        "oracle": "LAVI Python",
        "upstreamCommit": found_revision,
        "runtime": {
            "python": sys.version.split()[0],
            "numpy": np.__version__,
            "scipy": scipy.__version__,
        },
        "lavi": matrix(lavi_profile),
        "impulseKernel": {
            "selectedIndicesZeroBased": selected.tolist(),
            "real": finite_list(impulse_spectrum[selected].real),
            "imaginary": finite_list(impulse_spectrum[selected].imag),
        },
        "fractionalLagLAVI": finite_list(lag_result),
        "abba": {
            "columnNames": names,
            "globalEnvelope": {
                "borders": band_matrices(borders_global),
                "significance": [finite_list(item) for item in significance_global],
            },
            "perFrequency": {
                "borders": band_matrices(borders_per_frequency),
                "significance": [finite_list(item) for item in significance_per_frequency],
            },
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(output, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )

    if args.author_example_report:
        report = {
            "schemaVersion": 1,
            "upstreamCommit": found_revision,
            "note": "Bundled snapshots predate the fractional-lag behavior at the pinned commit.",
            "result": run_author_example(lavi_python, lavi),
        }
        args.author_example_report.write_text(
            json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
