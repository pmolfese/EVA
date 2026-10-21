#!/usr/bin/env python3
"""Build a tiny BDF and independent MNE reference; optionally validate vendor files.

Run in a Python environment with mne/numpy installed. The application never
requires Python. --vendor-dir points to the extracted public BioSemi test ZIP;
those third-party recordings and their reference data stay outside tracked files.
"""
import argparse
import json
from pathlib import Path

import mne
import numpy as np

ROOT = Path(__file__).resolve().parents[2]


def field(value, width):
    encoded = str(value).encode("ascii")
    assert len(encoded) <= width
    return encoded.ljust(width, b" ")


def make_sample(path):
    rng = np.random.default_rng(20261016)
    n = 64
    data = [rng.integers(-8388608, 8388608, size=n),
            rng.integers(-1000, 1001, size=n), np.zeros(n, dtype=np.int64)]
    data[0][:7] = [-8388608, -65537, -1, 0, 1, 65536, 8388607]
    # Initial event, changes without returning to zero, and pulses spanning a
    # record boundary. Upper bits change independently of the trigger word.
    data[2][:4] = 5
    data[2][4:9] = 2
    data[2][30:36] = 513
    data[2][60:] = 65535
    data[2] |= 0x900000
    data[2][2:7] ^= 0x400000
    labels = ["Fz", "Cz", "Status"]
    header = bytearray(b"\xffBIOSEMI")
    for value, width in [("X", 80), ("Startdate X", 80), ("16.10.26", 8),
                         ("12.00.00", 8), (1024, 8), ("24BIT", 44),
                         (2, 8), (1, 8), (3, 4)]:
        header.extend(field(value, width))
    columns = [(labels, 16), (["", "", ""], 80), (["uV", "uV", ""], 8),
               ([-262144, 10, -8388608], 8), ([262144, 20, 8388607], 8),
               ([-8388608, -1000, -8388608], 8), ([8388607, 1000, 8388607], 8),
               (["", "", ""], 80), ([32, 32, 32], 8), (["", "", ""], 32)]
    for values, width in columns:
        for value in values:
            header.extend(field(value, width))
    assert len(header) == 1024
    for record in range(2):
        for channel in data:
            for value in channel[record * 32:(record + 1) * 32]:
                header.extend((int(value) & 0xFFFFFF).to_bytes(3, "little"))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header)


def reference(path):
    raw = mne.io.read_raw_bdf(path, preload=True, verbose="ERROR")
    samples = raw.get_data(units="uV")
    # Field widths/sign extension/calibration and byte order are decoded by
    # MNE, independently of both the Swift parser and this fixture writer.
    samples.astype("<f4").tofile(path.with_suffix(".f32"))
    events = mne.find_events(raw, mask=0xFFFF, consecutive=True, initial_event=True,
                             shortest_event=1, verbose="ERROR")
    summary = {
        "mne_version": mne.__version__,
        # MNE's STIM output keeps only 17 bits. EVA deliberately preserves all
        # 24 raw bits, so compare through MNE's mask and test the upper bits in
        # the synthetic Swift tests against independently specified words.
        "status_reference_mask": 0x1FFFF,
        "channel_names": raw.ch_names,
        "duration": raw.n_times / raw.info["sfreq"],
        "events": [[float(sample / raw.info["sfreq"]), int(code)]
                   for sample, _, code in events],
    }
    path.with_suffix(".json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"{path.name}: {samples.shape}, {len(events)} events; MNE {mne.__version__}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor-dir", type=Path)
    args = parser.parse_args()
    path = ROOT / "EVATests/Fixtures/BDF/sample.bdf"
    make_sample(path)
    reference(path)
    if args.vendor_dir:
        for name in ["Newtest17-256.bdf", "Newtest17-2048.bdf"]:
            reference(args.vendor_dir / name)


if __name__ == "__main__":
    main()
