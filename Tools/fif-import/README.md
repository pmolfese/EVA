# fif-import — fixtures for EVA's native FIF reader

EVA reads MNE/Neuromag FIF recordings natively, with no Python at run time
(`EVACore/IO/FIF/`). That only stays true if the Swift reader agrees with
MNE-Python exactly, so this generates small recordings covering the shapes and
encodings the reader treats differently, and dumps MNE's own answer beside each.

```bash
/Users/molfesepj/micromamba/envs/mne/bin/python Tools/fif-import/make_fif_fixtures.py
```

Writes to `EVATests/Fixtures/FIF/` (~1.3 MB, committed):

| File | What it covers |
|---|---|
| `sample_raw.fif` | continuous, float32 buffers, 12 EEG + EOG + stim, annotations, montage |
| `sample_short_raw.fif` | the same data as int16 (`fmt='short'`) — the encoding that only comes out right if `range × cal` is applied |
| `sample_gz_raw.fif.gz` | the gzip path |
| `sample-epo.fif` | 5 epochs, 2 named conditions (a sixth was dropped by a `bad_blink` annotation, on purpose) |
| `sample-ave.fif` | 2 condition averages with different `nave`, and fewer channels than the epochs they came from |
| `*.f32` | the exact samples MNE returns, channels-major float32, **in volts** |
| `fif_reference.json` | channel info, events, annotations, segment metadata |

The `.f32` sidecars are what make the tests worth having: they compare every
sample against MNE rather than a summary statistic
(`EVATests/IO/FIFRecordingTests.swift`).

## Conventions the reader has to match

- **Scaling.** Continuous samples scale by `range × cal` (MNE's `info._cals`);
  epoched and averaged data scale by `cal` alone. `unit_mul` is *not* applied —
  MNE ignores it for FIF, so EVA does too and warns if a file sets it.
- **Buffer layout.** A `FIFF_DATA_BUFFER` is sample-major: all channels of
  sample 0, then sample 1. Reshape `(nsamp, nchan)` and transpose.
- **Units.** FIF is in the channel's own unit — volts for EEG. EVA works in
  microvolts and converts once, at the import boundary.
- **Isotrak frame.** Digitization inside a recording's measurement info carries
  no coordinate-frame tag; FIF defines those points to be in head coordinates.
- **Events live in two places.** Annotations and stimulus channels. EVA reads
  both and labels which is which; rising edges on a stim channel are read the way
  `mne.find_events` reads them.

## Quick Look

The same fixtures back `EVATests/IO/FIFPreviewTests.swift`, which renders every
preview panel and thumbnail to PNG (light and dark) in the test host's temporary
directory and prints the path. A picture can only really be reviewed by looking at
it, so the renders are left behind rather than only asserted about.

Non-recording FIFs for the classifier — a covariance and an event list — are written
here too; head models, transforms and digitizations come from
`EVATests/Fixtures/Resolve/`, which the head-model work already generates.

## The generator is not the test

The fixtures are deliberately small and structured (per-channel sinusoids of
known amplitude, 25 ms stim pulses at known samples), so a transposed read, a
missing calibration or a volts-vs-microvolts slip fails loudly rather than
looking plausible.
