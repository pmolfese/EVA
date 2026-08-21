# EVA Simulate

A forward-model EEG/fMRI simulator and scorer: it writes a ground-truth EEG
recording and a contaminated twin, then scores any corrected version of that
recording against the truth, per frequency band.

It exists because on real data there is no way to tell whether a correction
removed the artifact or removed the artifact *and* a good deal of the brain
signal with it. Both look like a cleaner trace. EVA now offers ten artifact
cleaning methods and seven OBS strategies, and choosing between them by eye is
not a method. With known ground truth, the choice becomes measurable.

The model reproduces:

> Grouiller F, Vercueil L, Krainik A, Segebarth C, Kahane P, David O (2007).
> *A comparative study of different artefact removal algorithms for EEG signals
> acquired during functional MRI.* NeuroImage 38(1):124-37.
> [doi:10.1016/j.neuroimage.2007.07.025](https://doi.org/10.1016/j.neuroimage.2007.07.025)

Build:

```sh
sh Tools/EVASimulate/build.sh
```

## Quick start

```sh
Tools/EVASimulate/.build/eva-simulate generate --output ~/sim
```

Writes three things into `~/sim`:

| File | What it is |
| --- | --- |
| `sim_clean.mff` | The ground-truth EEG. No artifacts. |
| `sim_noisy.mff` | The same EEG plus gradient and BCG artifacts, with TREV volume markers, jittered QRS markers, and synthetic ECG / motion-sensor PNS channels. |
| `sim_truth.json` | Everything the recordings cannot carry: the seed, the *true* beat times as opposed to the detected ones, per-channel artifact amplitudes and latencies, and the alpha block design. |

`--prefix test1` renames all three to `test1_clean.mff`, `test1_noisy.mff` and
`test1_truth.json`, so several recordings can share one directory.

Open `sim_noisy.mff` in EVA, correct it however you like, export the result, and
score it:

```sh
Tools/EVASimulate/.build/eva-simulate score --truth ~/sim/sim_clean.mff --corrected ~/sim/corrected.mff --baseline ~/sim/sim_noisy.mff
```

Scoring the *uncorrected* recording against the truth — the baseline every
correction has to beat — looks like this on the defaults:

```
uncorrected: broadband SNR 0.0355  (clean std 10.90 µV, residual std 307.28 µV)

  band      SNR    power dB   clean RMS   resid RMS
  ---------------------------------------------------
  0-4        0.30    +10.80      3.651      12.138
  4-8        0.32    +10.30      2.948       9.236
  8-12       2.12     +0.73      9.828       4.645
  12-16      0.09    +21.16      1.986      22.657
  16-20      0.27    +11.82      0.968       3.638
  20-25      0.18    +15.19      0.673       3.816
  25-30      0.03    +29.72      0.656      20.091
  ...
  50-55      0.00    +54.86      0.038      21.222
```

That table is itself a check on the model: the worst bands are 12-16, 25-30,
40-45, 50-55 and 65-70, which are the harmonics of the 13.67 Hz slice rate
(3 s / 41 slices). A slice-rate comb is exactly what a real EPI artifact
produces. Alpha survives best because the comb has a null near 8-12 Hz and
alpha is the largest thing in the EEG.

Passing `--baseline sim_noisy.mff` adds the uncorrected SNR and a `gain` column
to the table for a corrected file.

`SNR` is the paper's Equation 2 — `std(clean) / std(clean - corrected)` — computed
within each band. `gain` is how much the correction improved it over the
uncorrected recording; **below 1.0 means the correction made that band worse than
leaving it alone.** `power dB` compares corrected band power against clean band
power, which is the number that catches over-filtering: a high SNR with a
strongly negative dB is a method quietly deleting your signal.

## Commands

- `generate` — write one ground-truth/contaminated pair.
- `score` — compare a corrected recording against ground truth.
- `sweep` — one `generate` per value of a swept parameter, for a full curve.
- `selftest` — check that the model still reproduces the phenomena it claims to.

`eva-simulate --help` lists every option. The ones that matter most:

| Option | Why you would change it |
| --- | --- |
| `--qrs-jitter <ms>` | Separates methods that depend on beat timing from those that do not. The paper's Figure 5B. |
| `--slow-modulation <frac>` | Artifact amplitude drift, i.e. subject motion. The paper's Figure 4B, and where frequency-domain filtering wins. |
| `--bcg-amplitude <uv>` | Field strength, effectively. 10 µV is low field, 100-200 µV is 3T and up. |
| `--rate <hz>` | The paper found 1-2 kHz sufficient for everything except ICA, which wanted 4 kHz. |
| `--clock-offset <us-per-s>` | Set to 0 to model an EEG amplifier synchronized to the scanner clock. |
| `--gradient-template <path>` | Use a template measured on your own scanner instead of the synthetic waveform. Strongly preferred for anything you intend to publish. |
| `--impedance <kohm>` | Typical impedance of a healthy electrode (default 12). Bad channels get a value matching their defect — high for a poor contact, but deliberately *low* for `flat`, because a bridged electrode reads excellent and records nothing. |
| `--prefix <name>` | Name the output files something other than `sim_*`, so a directory can hold more than one recording. |

## For class demos

The paper's defaults make a *benchmark*, not a teaching recording: no blinks, no
mains hum, no bad electrodes, and the scanner running from the first sample. One
flag turns on the lot:

```sh
Tools/EVASimulate/.build/eva-simulate generate --output ~/Desktop/demo --demo
```

That is shorthand for 15 blinks/min, 25 eye movements/min, 60 Hz line noise, the
geometric spatial model, 15 s of quiet before the scanner starts and 10 s after
it stops, and two deliberately bad channels. Any explicit flag still overrides
it, so `--demo --line-noise 50` does what it looks like.

The recording that comes out supports most of the obvious lecture beats:

| To show | Look at |
| --- | --- |
| Raw vs. filtered | The whole trace: mains hum on every channel, drift on Pz, gradient artifact from 15 s. |
| What a blink looks like | `blnk` markers; Fp1/Fp2 versus Cz. The topography is frontal-maximal and reverses slightly at the back. |
| Blinks vs. eye movements | `eyem` markers. Blinks are transients; eye movements are *steps* that hold until the eyes move again, with opposite polarity at F7 and F8 — because the potential follows gaze position, not gaze velocity. |
| Why we keep an EOG | The VEOG/HEOG PNS channels see the same artifact far larger than any scalp electrode. |
| Bad channel detection | F8 (noisy) and Pz (drift) against their neighbours. Easiest to see in the pre-scan window or after gradient correction. |
| Impedance is not data quality | Health scoring with `--bad-channels "3:flat,7:noisy"`: the noisy channel reads 100+ kΩ, the bridged one reads under 3 kΩ and scores perfect while recording nothing. |
| Why notch filtering is per channel | Add `--bad-channels "3:line"` — one channel with heavy mains pickup and the rest clean. |
| The scanner turning on | 15 s in. Before that the EEG looks clean but is already carrying the BCG, because the static field never switches off — only the gradients stop. |
| Ground truth | `sim_clean.mff` is the same EEG with none of it. Overlay them. |

Some smaller recipes:

```sh
# Just blinks on clean EEG — nothing else to distract from them.
eva-simulate generate --output ~/blinks --no-gradient --no-bcg --blinks 18 --duration 60

# One bad channel of each kind, to compare how they look.
eva-simulate generate --output ~/bad --no-gradient \
  --bad-channels "3:flat,7:noisy,11:drift,15:pop,19:line" --line-noise 60

# Filtering practice: mains hum and drift, no MR artifacts at all.
eva-simulate generate --output ~/filtering --no-gradient --no-bcg \
  --line-noise 60 --blinks 15 --duration 120
```

### Channels and layout

Channels are a real 10-20 montage — Fp1, Fp2, F7 … Oz, O2 at 20 channels — and
both `sensorLayout.xml` and `coordinates.xml` are written, so channel selection
by name, topographic maps, and spherical-spline interpolation all work. Below 20
channels the set is subsampled across the head rather than truncated (truncating
a front-to-back ordering would hand back an all-frontal montage); above 41 it
falls back to a spiral, which is named "Spiral (synthetic)" so nobody mistakes it
for a real montage.

Positions are the 10-20 construction for the midline and outer ring, and
eyeballed to a few degrees for the intermediate and 10-10 sites. Fine for
simulating where a blink is large and for drawing a recognizable head map; not a
digitized montage.

### A caveat about the gradient artifact

Its amplitude varies strongly across the head by design — the paper varies it
from 0 to 7000 µV peak-to-peak between channels — and here it scales with arc
angle from the vertex, so Cz sees the least and the temporal sites the most.
During scanning that swamps everything else, including a deliberately bad
channel. Inspect bad channels in the pre-scan window, after gradient correction,
or with `--no-gradient`.

## What comes from the paper and what does not

This matters when interpreting a result. A finding that depends on a parameter
the paper measured is stronger evidence than one that depends on a shape this
tool invented.

**From the paper, used verbatim:**

- EEG as a linear mixture of seven band-limited Gaussian sources over 1-70 Hz,
  with a 45-55 Hz notch dropout, and a target standard deviation of 10.9 µV.
- Alpha modulated between 10 µV (eyes open) and 30 µV (eyes closed) on a 20 s
  alternation.
- Spatial correlation as circular connectivity smoothed with a Gaussian kernel of
  SD 4 channels.
- GE-EPI geometry: TR 3 s, 41 slices, ~60 ms of artifact per slice.
- Gradient amplitude varying across channels up to 7000 µV peak-to-peak.
- A 152 µs/s EEG-to-MRI clock offset.
- Slow gradient amplitude modulation, sine of 200 s period, 10% of mean.
- Heart rate wandering 65-85 bpm on a one-minute cycle; mean BCG amplitude
  10-200 µV; beat-to-beat amplitude weighting the previous beat and a fresh 15%
  draw equally; per-channel latency 15 ms SD; QRS detection jitter 25 ms SD.
- The motion sensor's saturating sigmoid nonlinearity, gain 0.1.
- `SNR = std(EEG) / std(EEG - EEG_corrected)`, and the evaluation bands.

**EVA's own, not the paper's:**

- Everything under "For class demos" above: blinks, eye movements, bad channels,
  mains noise, the electrode montage, and the pre/post-scan windows. All are off
  by default, so the benchmark numbers are unaffected by their existence.
- Gradient amplitude scaling with electrode position rather than channel index.

- The *shape* of the gradient waveform. The paper used a template measured on
  their 3T Bruker; this builds one as the time derivative of a modelled
  slice-select trapezoid plus EPI readout train, since induced EMF goes as
  dB/dt. Use `--gradient-template` to substitute a measured one.
- The *shape* of the BCG waveform — four Gaussian lobes putting the dominant
  negative deflection ~120 ms after the R wave.
- The synthetic ECG and its P-QRS-T morphology.
- Per-band amplitudes of the seven EEG sources (roughly 1/f; the paper fit theirs
  to one subject and does not print them).
- The anti-alias model: the artifact is band-limited at 0.9 × output Nyquist
  before being point-sampled, standing in for the amplifier's own filter.
- Reporting band power ratio in dB alongside SNR.

## Known limitations

These are worth stating plainly, because a harness whose limits are unstated
gets over-trusted.

- **The EEG is stationary; real EEG is not.** The paper names this as the most
  likely reason ICA looked excellent in their simulations and poor on their
  experimental data. Treat any ICA result from this harness with suspicion, and
  do not conclude anything about ICA from simulation alone.
- **The spatial model is circular, not anatomical.** Channel 1 neighbours
  channel N. Methods that exploit real topography — EVA's topography-gated,
  -aligned and -weighted OBS strategies — are being handed a spatial structure
  that no montage produces. Evaluate those on real data.
- **The BCG is a fixed waveform with varying amplitude and latency**, not the
  genuinely varying morphology of a real one. This flatters template-based
  methods somewhat.
- **No ocular or muscular artifacts, no electrode drift, no bad channels.**
- **One template shape for all channels.** Real gradient artifacts differ in
  shape, not just scale, across the montage.

## Notes from building it

Two things surfaced while validating the model that are worth knowing:

**Slice spacing is usually not an integer number of samples.** At 1024 Hz with
TR 3 s and 41 slices, a slice is 74.93 samples. Slice artifacts therefore never
repeat their sub-sample phase, even with the EEG and MRI clocks perfectly
locked — before any clock drift enters the picture. This is exactly why IAR and
FASTR interpolate up to ~10 kHz before attempting slice-level alignment, and it
means slice-level template subtraction has a floor that volume-level subtraction
does not. The volume period *is* an integer here (3072 samples), which is what
`selftest` uses to isolate the clock-drift effect.

**Naive average-artifact subtraction has a ceiling of sqrt(N).** With the clocks
locked, the artifact cancels exactly and the only thing left is the EEG that the
template averaged in along the way, whose standard deviation is std(EEG)/sqrt(N)
over N epochs. So a "perfect" AAS on 20 volumes scores SNR 4.47, not infinity.
Any method scoring meaningfully above that ceiling is doing something smarter
than a global average — and any method well below it on locked-clock data has a
problem. `selftest` pins this.

## A known limitation of the file format

`eva-simulate selftest` reports one check as KNOWN rather than PASS: TR marker
spacing. MFF stores event times as a datetime, and `MFFWriter` formats them with
`DateFormatter`, which resolves only milliseconds — at 1024 Hz a sample is
0.977 ms, so marker sample indices cannot survive the round trip and come back
displaced by up to half a millisecond. EVA's gradient stage tolerates one sample
of deviation from the median and refuses to correct beyond it, so a generated
recording can be rejected with "TRs are not evenly spaced".

This is a writer limitation rather than a modelling one, it affects any EVA
export carrying events, and it cannot be worked around from this side — a
0.977 ms grid is not representable on a 1 ms one. The diagnosis and the verified
fix are in `TODO_Aug21.md`. Meanwhile `--clock-offset 0` produces markers that
pass, at the cost of an unrealistically stationary gradient artifact.

## Self-test

```sh
Tools/EVASimulate/.build/eva-simulate selftest
```

Ten checks, each on the model rather than on any EVA code: that locked clocks put
template subtraction exactly on the sqrt(N) ceiling; that the paper's 152 µs/s
drift pushes it far below that; that QRS jitter penalizes correction which relies
on beat timing; that every injected waveform starts and ends at baseline rather
than injecting a step at each event; that the scanner window is respected while
the BCG carries on through it; and that a blink is frontally maximal. Run it
after touching anything in the model — a
harness that silently stops reproducing the phenomenon it exists to study is
worse than no harness, because everything it emits still looks like evidence.
