# EVA BIDS

Command-line converter between EVA's native MFF format and BIDS-EEG datasets.
Three subcommands:

- `to-bids` — MFF recording -> BIDS-EEG dataset (EDF signal + TSV/JSON sidecars).
- `from-bids` — BIDS-EEG recording (EDF + sidecars) -> MFF package.
- `inspect-bids` — checks a BIDS-EEG recording's sidecars for the things
  `from-bids` depends on, and reports PASS/WARN/FAIL per file.

Signal data is carried as plain EDF (not EDF+): BIDS event/channel metadata
lives in the `_events.tsv`/`_channels.tsv` sidecars, so there is no need for an
EDF+ annotations channel.

Build:

```sh
sh Tools/EVABIDS/build.sh
```

## to-bids

```sh
Tools/EVABIDS/.build/eva-bids to-bids /path/to/recording.mff \
  --bids-root /path/to/bids-dataset --subject 01 --task rest
```

Writes `sub-01/eeg/sub-01_task-rest_eeg.edf` plus `_channels.tsv`,
`_events.tsv`, `_eeg.json`, and (when the source MFF has `coordinates.xml`)
`_electrodes.tsv`/`_coordsystem.json`. Creates `dataset_description.json` and
appends to `participants.tsv` at the dataset root if not already present.

If the source MFF package contains `eva.xml` and/or `log_eva_*.txt` (i.e. it
was previously exported by EVA), they are copied into
`code/eva/sub-01/eeg/sub-01_task-rest_eva.xml` etc. — outside the
BIDS-validated tree, so a validator won't flag them, but `from-bids` (or any
batch tooling) can find them again by the same relative path.

Flags:

```
--session <label>          Session label, no "ses-" prefix.
--run <n>                  Run index, written as run-<NN>.
--power-line-freq <hz>     PowerLineFrequency for eeg.json (default 60).
--eeg-reference <name>     EEGReference for eeg.json (default "n/a").
--overwrite                Replace an existing EDF/sidecars.
--verbose                  Print step-by-step detail.
```

## from-bids

```sh
Tools/EVABIDS/.build/eva-bids from-bids /path/to/bids-dataset/sub-01/eeg \
  --output /path/to/recording.mff
```

Accepts either a direct `*_eeg.edf` path or a directory to search for exactly
one. Reads `_channels.tsv` to classify channels as EEG vs. peripheral (ECG,
EOG, EMG, etc. by name/type; anything else falls back to a PNS "MISC"
channel), `_events.tsv` for event markers, and `_electrodes.tsv` (with
`_coordsystem.json`, if present) for sensor positions. If the dataset was
produced by `to-bids` and still has its `code/eva/.../*_eva.xml` /
`*_log_eva_*.txt` stash, those are restored into the output MFF package;
otherwise the output MFF simply has none (the expected case for BIDS data
from elsewhere).

Electrode positions from `_electrodes.tsv` are written generically (any
numeric x/y, optional z) regardless of their original coordinate system —
EVA's own `SensorLayout`/`ElectrodeGeometry` readers re-center and rescale on
load, so they don't need to match EGI's own unit-sphere convention.

## inspect-bids

```sh
Tools/EVABIDS/.build/eva-bids inspect-bids /path/to/bids-dataset/sub-01
```

Point it at a single `*_eeg.edf`, or a directory (subject folder, dataset
root, etc.) to check every recording found underneath, optionally narrowed
with `--subject`/`--session`/`--task`/`--run`. Reports, per recording:

- EDF header parses, and its channel count matches `_channels.tsv`.
- `_channels.tsv` has the `name`/`type`/`units` columns.
- `_events.tsv` has `onset`/`duration` columns, if present (WARN if missing).
- `_eeg.json` has `TaskName`/`SamplingFrequency`/`EEGReference`/
  `PowerLineFrequency`/`SoftwareFilters`, and its declared sampling frequency
  matches an actual EDF signal rate.
- `_electrodes.tsv` and `_coordsystem.json` are both present or both absent.
- `dataset_description.json` and `participants.tsv` exist at the dataset root
  (found by walking up from the recording).

Exits non-zero if any check reports FAIL (missing/malformed required files);
WARN findings don't affect the exit code.
