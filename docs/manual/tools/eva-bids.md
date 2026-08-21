# EVA BIDS

`eva-bids` converts recordings between EVA's native MFF format and BIDS-EEG
datasets, and checks a BIDS-EEG recording before you try to import it.

```bash
sh Tools/EVABIDS/build.sh
```

The binary lands at `Tools/EVABIDS/.build/eva-bids`.

Three subcommands: `to-bids`, `from-bids`, and `inspect-bids`.

## How the data is carried

Signal data is written as **plain EDF**, not EDF+. BIDS keeps event and channel
metadata in `_events.tsv` and `_channels.tsv` sidecars, so there is no need for
an EDF+ annotations channel and none is written. Anything reading the dataset
should take events from the TSV.

## `to-bids` — MFF to BIDS-EEG

```bash
Tools/EVABIDS/.build/eva-bids to-bids /path/to/recording.mff \
  --bids-root /path/to/dataset --subject 01 --task rest
```

| Option | Default | Notes |
| --- | --- | --- |
| `--bids-root <dir>` | *required* | Dataset root to write into. |
| `--subject <label>` | *required* | No `sub-` prefix — just `01`. |
| `--session <label>` | — | No `ses-` prefix. |
| `--task <label>` | `task` | |
| `--run <n>` | — | Written as `run-<NN>`. |
| `--power-line-freq <hz>` | `60` | Recorded in `_eeg.json`. |
| `--eeg-reference <name>` | `n/a` | Recorded in `_eeg.json`. |
| `--overwrite` | off | Replace an existing EDF and sidecars. |
| `--verbose` | off | Print step-by-step detail. |

Writes `sub-01/eeg/sub-01_task-rest_eeg.edf` plus `_channels.tsv`,
`_events.tsv`, `_eeg.json`, and — when the source MFF has `coordinates.xml` —
`_electrodes.tsv` and `_coordsystem.json`. It creates `dataset_description.json`
and appends to `participants.tsv` at the dataset root if they are not already
there.

### EVA's own metadata survives the trip

If the source package contains `eva.xml` or `log_eva_*.txt` — that is, if EVA
exported it — those files are copied to
`code/eva/sub-01/eeg/sub-01_task-rest_eva.xml` and similar. That location is
outside the BIDS-validated tree, so a validator will not flag it, but
`from-bids` knows to look there and restores them on the way back.

## `from-bids` — BIDS-EEG to MFF

```bash
Tools/EVABIDS/.build/eva-bids from-bids /path/to/sub-01/eeg \
  --output /path/to/recording.mff
```

| Option | Default | Notes |
| --- | --- | --- |
| *(positional)* | *required* | A `*_eeg.edf` file, or a directory containing exactly one. |
| `--output <path>` | *required* | Output MFF package. |
| `--overwrite` | off | Replace an existing package. |
| `--verbose` | off | |

Channel types and events come from the sidecars, and `eva.xml` / `log_eva_*.txt`
are restored from `code/eva/…` when present.

## `inspect-bids` — check before converting

```bash
Tools/EVABIDS/.build/eva-bids inspect-bids /path/to/dataset --subject 01
```

Reports PASS, WARN or FAIL per sidecar file for the things `from-bids` depends
on. Run this first when a conversion fails, or when you have been handed a
dataset from elsewhere.

| Option | Notes |
| --- | --- |
| *(positional)* | A `*_eeg.edf`, or a directory searched recursively for one or more recordings. |
| `--subject`, `--session`, `--task`, `--run` | Restrict to matching recordings. |
| `--verbose` | Print step-by-step detail. |
