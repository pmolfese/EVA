#!/usr/bin/env python3
"""Generate a dependency-free, independent map-domain burst oracle.

This deliberately starts from fixed power/WTPL matrices rather than reusing
EVA's Morlet implementation. It exercises P90 peaks, P75 boundaries,
deterministic plateaus, frequency-near overlap merging, and band metrics.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

FREQUENCIES = [8.0, 10.0, 20.0]
N = 60
RATE = 100.0


def percentile(values: list[float], p: float) -> float:
    values = sorted(values)
    position = p / 100.0 * (len(values) - 1)
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return values[lower]
    fraction = position - lower
    return values[lower] + fraction * (values[upper] - values[lower])


def fixture_maps() -> tuple[list[list[float]], list[list[float]]]:
    power = [[1.0 + 0.001 * t + 0.01 * f for t in range(N)] for f in range(3)]
    wtpl = [[0.35 + 0.001 * ((t + f) % 9) for t in range(N)] for f in range(3)]
    for t in range(12, 29):
        power[0][t] += max(0.0, 6.0 - 0.55 * abs(t - 20))
        wtpl[0][t] = 0.72
    power[0][19] = power[0][20] = 8.5  # deterministic 2-pixel plateau
    for t in range(16, 33):
        power[1][t] += max(0.0, 8.5 - 0.72 * abs(t - 23))
        wtpl[1][t] = 0.84
    for t in range(15, 31):
        power[2][t] += max(0.0, 7.4 - 0.66 * abs(t - 22))
        wtpl[2][t] = 0.78
    return power, wtpl


def active_range(center: int, row: list[float], threshold: float) -> tuple[int, int]:
    lower = upper = center
    while lower > 0 and row[lower - 1] >= threshold:
        lower -= 1
    while upper + 1 < len(row) and row[upper + 1] >= threshold:
        upper += 1
    return lower, upper


def regional_peaks(power: list[list[float]], thresholds: list[float]) -> list[tuple[int, int]]:
    visited: set[tuple[int, int]] = set()
    peaks: list[tuple[int, int]] = []
    for t in range(N):
        for f in range(len(power)):
            if (f, t) in visited or power[f][t] < thresholds[f]:
                continue
            value = power[f][t]
            component = [(f, t)]
            visited.add((f, t))
            maximum, lower_neighbor = True, False
            cursor = 0
            while cursor < len(component):
                cf, ct = component[cursor]
                cursor += 1
                for df in (-1, 0, 1):
                    for dt in (-1, 0, 1):
                        nf, nt = cf + df, ct + dt
                        if (df == 0 and dt == 0) or not (0 <= nf < len(power) and 0 <= nt < N):
                            continue
                        neighbor = power[nf][nt]
                        maximum &= neighbor <= value
                        lower_neighbor |= neighbor < value
                        if neighbor == value and (nf, nt) not in visited:
                            visited.add((nf, nt))
                            component.append((nf, nt))
            if maximum and lower_neighbor:
                peaks.append(min(component, key=lambda item: (item[1], item[0])))
    return sorted(peaks, key=lambda item: (item[1], item[0]))


def detect(power: list[list[float]], wtpl: list[list[float]]) -> tuple[list[dict], list[float], list[float]]:
    peak_thresholds = [percentile(row, 90.0) for row in power]
    boundary_thresholds = [percentile(row, 75.0) for row in power]
    candidates: list[dict] = []
    for f, peak in regional_peaks(power, peak_thresholds):
        initial = active_range(peak, power[f], peak_thresholds[f])
        involved = {f}
        lower, upper = peak, peak
        while lower > 0 and any(power[k][lower - 1] >= boundary_thresholds[k] for k in involved):
            lower -= 1
        while upper + 1 < N and any(power[k][upper + 1] >= boundary_thresholds[k] for k in involved):
            upper += 1
        duration = (upper - lower) / RATE
        if duration * FREQUENCIES[f] < 1.0:
            continue
        candidates.append({
            "peakFrequencyIndex": f,
            "peakFrequencyHz": FREQUENCIES[f],
            "peakSample": peak,
            "onsetSample": lower,
            "offsetSample": upper,
            "initialOnsetSample": initial[0],
            "initialOffsetSample": initial[1],
            "durationMilliseconds": duration * 1000.0,
            "durationCycles": duration * FREQUENCIES[f],
            "peakPower": power[f][peak],
            "relativePeakPowerDB": 10.0 * math.log10(power[f][peak] / peak_thresholds[f]),
            "peakWTPL": wtpl[f][peak],
            "meanWTPL": sum(wtpl[f][lower:upper + 1]) / (upper - lower + 1),
            "bandName": "Alpha" if FREQUENCIES[f] <= 13 else "Beta",
        })
    # Reference-style overlap pruning: near-frequency overlapping candidates
    # collapse to the higher power×duration representative and union interval.
    changed = True
    while changed:
        changed = False
        for i in range(len(candidates)):
            for j in range(i + 1, len(candidates)):
                a, b = candidates[i], candidates[j]
                overlap = max(a["onsetSample"], b["onsetSample"]) <= min(a["offsetSample"], b["offsetSample"])
                gap = max(4.0, min(a["peakFrequencyHz"], b["peakFrequencyHz"]) * 0.25)
                if not overlap or abs(a["peakFrequencyHz"] - b["peakFrequencyHz"]) > gap:
                    continue
                winner = b if b["peakPower"] * b["durationMilliseconds"] > a["peakPower"] * a["durationMilliseconds"] else a
                winner = dict(winner)
                winner["onsetSample"] = min(a["onsetSample"], b["onsetSample"])
                winner["offsetSample"] = max(a["offsetSample"], b["offsetSample"])
                winner["durationMilliseconds"] = (winner["offsetSample"] - winner["onsetSample"]) / RATE * 1000.0
                winner["durationCycles"] = winner["durationMilliseconds"] / 1000.0 * winner["peakFrequencyHz"]
                candidates[i] = winner
                candidates.pop(j)
                changed = True
                break
            if changed:
                break
    return sorted(candidates, key=lambda item: (item["peakSample"], item["peakFrequencyHz"])), peak_thresholds, boundary_thresholds


def main() -> None:
    power, wtpl = fixture_maps()
    bursts, p90, p75 = detect(power, wtpl)
    payload = {
        "schemaVersion": 1,
        "generator": "Tools/RhythmicityReference/generate_burst_oracle.py",
        "reference": {
            "repository": "https://github.com/laaanchic/WTPL",
            "commit": "6da57b71f1084c62cfa1a4deaebee227d38f2584",
            "file": "Bursts_detection_WTPL_v1_0_0.m",
            "fileSHA256": "76375d0f2e972ed34654abdbed12b410754876ca5b8ea8286eca2c291c101c29",
        },
        "samplingRateHz": RATE,
        "frequenciesHz": FREQUENCIES,
        "power": power,
        "wtpl": wtpl,
        "configuration": {"peakPercentile": 90.0, "boundaryPercentile": 75.0, "minimumDurationCycles": 1.0},
        "expected": {"peakThresholds": p90, "boundaryThresholds": p75, "bursts": bursts},
    }
    destination = Path(__file__).parents[2] / "EVATests/Fixtures/Rhythmicity/burst-python-oracle.json"
    destination.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
