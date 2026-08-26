# EVA Helper

`eva-helper` applies EVA's simultaneous EEG/fMRI cleanup from the command line:
average-artifact-subtraction gradient correction followed by carbon-wire-loop
(CWL) regression, writing a new MFF package. It exists for batch processing and
for benchmarking the CWL backends against each other.

!!! note "Build script was repaired 2026-08-21"
    The script had gone stale — it listed `EVA/Gradient/GradientRemover.swift`,
    a file removed when the `Gradient` directory was reorganized, and failed
    immediately with `error opening input file`. It now compiles against the
    current gradient sources and builds cleanly.

It is described in the source as a proof of concept, and the flags reflect that
— several exist for comparing implementations rather than for routine use.

```bash
sh Tools/EVAHelper/build.sh
Tools/EVAHelper/.build/eva-helper /path/to/input.mff --prefix cleaned_
```

## What it does

1. Reads an MFF or BrainVision recording.
2. Asks which event code marks the TR, unless `--tr-code` is given.
3. Applies AAS gradient correction.
4. Selects channels whose names start with `CWL`.
5. Optionally downsamples.
6. Runs CWL regression.
7. Writes a new MFF package.

**Input handling differs by format.** For MFF, CWL channels are taken from the
PNS signal. For BrainVision (`.vhdr`, `.eeg`, `.vmrk`), every channel name is
scanned: those named `CWL*`, `ECG*` or `EKG*` are split out as PNS/reference
channels and the rest are treated as EEG. CWL regression uses only the `CWL*`
subset either way.

The input must be **continuous** — segmented and averaged MFF files are rejected.

## Common options

| Option | Default | Notes |
| --- | --- | --- |
| `--prefix <text>` | *required* | Prefix for the output package name. |
| `--tr-code <code>` | — | Skip the interactive TR prompt. |
| `--downsample <hz>` | — | Downsample after AAS, before CWL. |
| `--overwrite` | off | Replace an existing output package. |
| `--verbose` | off | Print CPU/GPU preparation and submission detail. |

## Gradient correction

| Option | Default | Notes |
| --- | --- | --- |
| `--window-before <n>` | `4` | AAS template TRs taken before the current one. |
| `--window-after <n>` | `4` | AAS template TRs taken after it. |

## CWL regression parameters

| Option | Default | Notes |
| --- | --- | --- |
| `--cwl-lag-min <ms>` | `-50` | Minimum regression lag. |
| `--cwl-lag-max <ms>` | `150` | Maximum regression lag. |
| `--cwl-lag-step <ms>` | `10` | Spacing between lag taps. |
| `--cwl-window <s>` | `4` | Sliding regression window. |
| `--cwl-hop <s>` | half the window | Hop between windows. |

The lag range spans the mechanical and hemodynamic delay between wire-loop motion
and its EEG signature; the sliding window is what lets the coupling coefficients
drift over a recording instead of being fixed globally.

## MATLAB-compatible mode

| Option | Default | Notes |
| --- | --- | --- |
| `--orig` | off | Use the MATLAB CWRegrTool-style tapered Hann CWL. |
| `--orig-delay <s>` | `0.021` | Delay half-width. |
| `--orig-taper-factor <n>` | `1` | Taper factor. |

## Backend comparison

These exist to check the Metal and CPU paths against one another, which is how
the GPU port was validated.

| Option | Default | Notes |
| --- | --- | --- |
| `--cwl-backend <name>` | `metal` | `metal`, `cpu`, or `compare` — the last runs both and reports timing and numerical difference. |
| `--cwl-gpu-kernel <name>` | `sample-parallel` | `serial` selects the older Metal kernel. |
| `--gpu-batch-windows <n>` | `1` | Submit several CWL windows per command buffer. |
| `--compare-max-diff <x>` | `1e-2` | Absolute max-difference tolerance. |
| `--compare-rms-diff <x>` | `1e-3` | RMS difference tolerance. |
| `--compare-relative-max-diff <x>` | `5e-2` | Max difference relative to correction magnitude. |
| `--compare-relative-rms-diff <x>` | `1e-2` | RMS difference relative to correction magnitude. |
| `--compare-no-assert` | off | Print the metrics but never fail on mismatch. |

In `compare` mode the tool fails **before writing output** unless either the
absolute tolerance or the relative rough-equivalence tolerance passes. Use
`--compare-no-assert` for timing-only experiments where you expect a difference.
