# EVA Helper

Proof-of-concept command-line helper for simultaneous EEG/fMRI MFF cleanup.

It reads an MFF or BrainVision recording, asks which event code should be used
as the TR marker, applies EVA's AAS MRI gradient correction, selects channels
whose names start with `CWL`, optionally downsamples before Carbon Wire Loop
regression, runs CWL, and writes a new MFF package.

For MFF input, CWL channels are selected from the PNS signal. For BrainVision
input (`.vhdr`, `.eeg`, `.vmrk`), all channel names are scanned; channels named
`CWL*`, `ECG*`, or `EKG*` are split out as PNS/reference channels, and all
remaining channels are treated as EEG. CWL regression still uses only the
`CWL*` subset of those PNS channels.

Build:

```sh
sh Tools/EVAHelper/build.sh
```

Run:

```sh
Tools/EVAHelper/.build/eva-helper /path/to/input.mff --prefix cleaned_
Tools/EVAHelper/.build/eva-helper /path/to/input.vhdr --prefix cleaned_
```

Useful flags:

```sh
--tr-code TREV              Skip the interactive TR prompt.
--downsample 500            Downsample after AAS and before CWL.
--overwrite                 Replace an existing output package.
--verbose                   Print CPU/GPU preparation and submission details.
--cwl-backend compare       Run Metal and CPU/LAPACK, report timing/diff.
--cwl-gpu-kernel serial     Use the older serial Metal kernel.
--gpu-batch-windows 8       Submit several CWL windows per command buffer.
--cwl-lag-min 0             Minimum CWL lag in ms (default -50).
--cwl-lag-max 120           Maximum CWL lag in ms (default 150).
--cwl-lag-step 20           CWL lag step in ms (default 10).
--cwl-window 8              CWL regression window in seconds (default 4).
--cwl-hop 4                 Hop between CWL windows (default half window).
--compare-max-diff 1e-2     Max absolute diff tolerance for compare mode.
--compare-rms-diff 1e-3     RMS diff tolerance for compare mode.
--compare-relative-max-diff 5e-2
                            Relative max diff tolerance vs correction magnitude.
--compare-relative-rms-diff 1e-2
                            Relative RMS diff tolerance vs correction magnitude.
--compare-no-assert         Print compare metrics but never fail on mismatch.
```

`--cwl-backend compare` runs the selected Metal path and the CPU/LAPACK path,
prints the numerical difference, and by default fails before writing output if
neither the absolute tolerance nor the relative rough-equivalence tolerance
passes. Use `--compare-no-assert` for timing-only experiments.

Downsampling happens after AAS and before the CWL lagged-regressor setup, so it
reduces both CPU prep and GPU work. For example, use `--downsample 500` to run
CWL at 500 Hz and write a 500 Hz output MFF.
