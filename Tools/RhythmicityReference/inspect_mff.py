#!/usr/bin/env python3
"""Inventory large external MFF inputs without copying or materializing EEG."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


def read_int32(handle) -> int:
    value = handle.read(4)
    if len(value) != 4:
        raise ValueError("unexpected end of MFF signal header")
    return struct.unpack("<i", value)[0]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_signal(path: Path) -> dict:
    block_count = 0
    total_samples = 0
    configurations = set()
    last_header = None
    with path.open("rb") as handle:
        while flag_bytes := handle.read(4):
            if len(flag_bytes) != 4:
                raise ValueError(f"truncated block flag in {path}")
            flag = struct.unpack("<i", flag_bytes)[0]
            if flag == 1:
                header_size = read_int32(handle)
                block_size = read_int32(handle)
                channel_count = read_int32(handle)
                handle.seek(4 * channel_count, 1)  # offsets
                rate_depth = [read_int32(handle) for _ in range(channel_count)]
                handle.seek(header_size - (16 + 8 * channel_count), 1)
                rates = {value >> 8 for value in rate_depth}
                depths = {value & 0xFF for value in rate_depth}
                if len(rates) != 1 or len(depths) != 1:
                    raise ValueError(f"inconsistent channels within block in {path}")
                sampling_rate = rates.pop()
                sample_depth = depths.pop()
                samples = block_size // (channel_count * (sample_depth // 8))
                last_header = (block_size, channel_count, sampling_rate, sample_depth, samples)
            elif flag != 0 or last_header is None:
                raise ValueError(f"unexpected MFF block flag {flag} in {path}")

            block_size, channels, rate, depth, samples = last_header
            configurations.add((channels, rate, depth))
            total_samples += samples
            block_count += 1
            handle.seek(block_size, 1)

    if len(configurations) != 1:
        raise ValueError(f"inconsistent block configuration in {path}")
    channels, rate, depth = configurations.pop()
    return {
        "signalFile": path.name,
        "signalFileBytes": path.stat().st_size,
        "signalFileSHA256": sha256(path),
        "blockCount": block_count,
        "channelCount": channels,
        "samplingRateHz": rate,
        "sampleDepthBits": depth,
        "sampleCountPerChannel": total_samples,
        "durationSeconds": total_samples / rate,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    packages = []
    for index, package in enumerate(sorted(args.root.glob("*.mff")), start=1):
        record = inspect_signal(package / "signal1.bin")
        # Do not commit subject-like filenames. The digest still lets a local
        # test runner detect that the expected external package was selected.
        record["packageID"] = f"external-mff-{index:02d}"
        record["sourceNameSHA256"] = hashlib.sha256(package.name.encode("utf-8")).hexdigest()
        packages.append(record)
    if not packages:
        raise SystemExit(f"no .mff packages found beneath {args.root}")
    output = {
        "schemaVersion": 1,
        "storagePolicy": "external-integration-input; raw EEG is not copied into EVA",
        "packages": packages,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(output, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
