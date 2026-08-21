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

## Self-test

```sh
Tools/EVASimulate/.build/eva-simulate selftest
```

Three checks, each on the model rather than on any EVA code: that locked clocks
put template subtraction exactly on the sqrt(N) ceiling; that the paper's
152 µs/s drift pushes it far below that; and that QRS jitter penalizes correction
which relies on beat timing. Run it after touching anything in the model — a
harness that silently stops reproducing the phenomenon it exists to study is
worse than no harness, because everything it emits still looks like evidence.
