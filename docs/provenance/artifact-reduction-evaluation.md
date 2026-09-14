# Artifact-Reduction Evaluation Toolkit

Design record for the method-agnostic tools that measure any EEG cleaning step
against simulated ground truth. These grew out of the SI-4 run-grade work: to set
a Good/Watch/Poor band for a cleaning step honestly, we first need to *measure*
what "good" is for that method, and removed variance alone cannot say
(`CleaningVarianceAccount` says so in its own source: "It is not a quality score").

All three live in `Tools/EVASimulate` and are covered by the self-test (109/109 as
of 2026-09-13). The user-facing reference is the simulator manual page,
"Evaluating artifact reduction (any method)".

## `score-cleaning`

Correlates the run-time metric a correction can compute *without* truth
(`removed_variance_fraction = var(noisy − corrected) / var(noisy)`) against the
truth-based `residual_error_fraction`, corrected/uncorrected SNR, and
`artifact_reduction_fraction = 1 − var(corrected − clean) / var(noisy − clean)`.

**Why it exists:** removed variance is ambiguous — a method that deletes brain and
one that removes artifact can report the same fraction. Tying it to residual-vs-
truth is how a band is calibrated per method (gradient legitimately removes far
more variance than ICA, so bands do not transfer). An early demo already made the
point: a PCA-S run reported removed-variance 0.96 with artifact-reduction −0.32 —
high removal, destructive result.

## `evaluate-retention`

Reframes blink-cleaning quality as the question users actually ask — "can I save
this data?" — as a bias–variance trade on the ERP average. For an ERP experiment
with blinks contaminating some trials, it scores three strategies against the true
ERP (measured off the clean recording the same way): **reject** contaminated
trials, **keep-dirty**, and **clean-and-keep** (built-in Gratton–Coles VEOG
regression). Reports trials kept, ERP-average SNR, and peak amplitude/latency bias.

**What it showed at first run (10 seeds):** the verdict is regime-dependent, which
is the honest result.

| Blinks/min | trials contaminated | reject peak bias | clean-and-keep peak bias | trials saved |
|---:|---:|---:|---:|---:|
| 40 (light) | ~7 / 80 | −1.46 µV | +1.45 µV (regression *adds* bias) | 6.9 (not worth it) |
| 150 (heavy) | ~11 / 80 | +5.35 µV (5 noisy trials) | +2.34 µV (16 trials) | 10.8 (clear win) |

So cleaning wins only when it lifts SNR without biasing the peak — at light
contamination, rejecting a few trials is cheaper than the distortion the
correction introduces. This metric is method-agnostic and is the intended honest
band-setter for ocular cleaning (SI-5) and ICA/wavelet blink removal. For
removal-only methods it collapses to "does threshold detection still catch the
artifact afterward" (`score-events`).

## Non-Gaussian source model (`--source-burstiness`)

The paper's EEG sources are band-limited **Gaussian**. That is fine for PCA-S and
gradient, but close to pathological for methods that separate sources by their
statistics:

- **ICA** is identifiable only when at most one source is Gaussian — Gaussian
  sources cannot be unmixed, so evaluating ICA on them measures the simulator.
- **BSS-CCA** (muscle) relies on a non-Gaussian / low-autocorrelation marginal.

`NonGaussianSourceModel` multiplies each dipole source's in-band signal by a slow
(≈1–2 Hz) log-normal burst envelope: the marginal becomes super-Gaussian (kurtotic,
sparse) while the signal stays in its passband and keeps its RMS, so amplitude and
SNR bookkeeping are untouched. Burstiness 0 is the identity, so the field is
Optional with a nil default and the determinism baseline is byte-identical (8/8
scenarios). Dipole model only — the Grouiller model is not a linear-mixing ICA
generative model. The true mixing (lead field) and source time courses are already
exposed via `GeneratedSourceSpace`, so unmixing quality is scorable.

## BCG spatial rank (`--bcg-generators`) and Amari index (`score-mixing`)

Two additions for OBS and ICA specifically (2026-09-13):

- **`--bcg-generators <1–4>`** sets how many of the four physical BCG generators
  are active, and therefore the artifact's spatial rank. OBS keeps the top-k
  principal components of the beat-aligned epochs, so its whole question is
  "how many components," and this knob varies the true answer — letting a sweep
  find where OBS keeps too few (residual left) or too many (brain eaten). The
  generators model already reports `spatialRank` and the normalized singular
  values, so the realized rank is checkable. Optional/nil-default (= all four), so
  the determinism baseline is unchanged.
- **`score-mixing`** computes the Amari performance index of an estimated
  unmixing against the true mixing: 0 for perfect separation (a permutation-and-
  scaling of identity), positive as sources leak. `generate --write-mixing`
  exports the true mixing (the dipole lead field) so the loop closes. Pair with
  `--source-burstiness > 0` — ICA cannot separate Gaussian sources, so the Amari
  index is only meaningful on non-Gaussian ones.

## Sharp brain transients (`--brain-transients`) and `score-preservation`

For the wavelet reducer and any transient-thresholding method, the failure mode is
oversmoothing — deleting genuine sharp brain features. `BrainTransientModel` seeds
K-complexes, spindles and sharp waves into the *clean* EEG (central-maximal, with
per-event truth), and `score-preservation` reports, per type, how much of each
survived cleaning on its strongest channel (1 = intact, 0 = flattened, negative =
distorted). Generate exports the truth with `--write-transients`. Optional/nil
default, determinism preserved. The sharpest type (sharp waves) is the most
demanding, by design.

## Wavelet calibration result (2026-09-13) — hard vs soft

`WaveletOversmoothingMeasurementTests` (`EVA_CALIBRATION=1`) sweeps the threshold
over both shipped presets. Scenario: 500 Hz, 120 s, physiological per-type
amplitudes (K-complex 150 µV, spindle ~25 µV, sharp wave ~80 µV), with blinks /
cable movement / a popping electrode / muscle present to remove. `preserve` is the
fraction of a brain transient kept (1 = intact); `remove` is the fraction of an
artifact removed (1 = gone). Tables in `data/wavelet-calibration/`.

**HARD / continuous-EEG preset (bior4.4)** — the more aggressive path:

| threshold | removed var | preserve K / spin / sharp | remove blink / move / pop / emg |
|---:|---:|---|---|
| 0.50 | 0.91 | 0.00 / 0.01 / 0.00 | 0.75 / 0.98 / 0.99 / 0.60 |
| 1.00 | 0.80 | 0.00 / 0.02 / 0.02 | 0.87 / 0.98 / 0.99 / 0.89 |
| 2.00 | 0.74 | 0.03 / 0.06 / 0.05 | 0.80 / 0.99 / 0.99 / 0.93 |
| 5.00 | 0.62 | 0.17 / 0.25 / 0.33 | 0.46 / 0.87 / 0.89 / 0.81 |

**SOFT / ERP preset (coif4)** — shrinks rather than removes; much gentler:

| threshold | removed var | preserve K / spin / sharp | remove blink / move / pop / emg |
|---:|---:|---|---|
| 0.50 | 0.80 | 0.14 / 0.16 / 0.18 | 0.88 / 0.95 / 0.88 / 0.91 |
| 1.00 | 0.68 | 0.25 / 0.26 / 0.33 | 0.81 / 0.90 / 0.77 / 0.93 |
| 2.00 | 0.59 | 0.43 / 0.38 / 0.55 | 0.59 / 0.81 / 0.69 / 0.85 |
| 3.00 | 0.52 | 0.57 / 0.38 / 0.71 | 0.36 / 0.70 / 0.65 / 0.77 |
| 5.00 | 0.42 | 0.76 / 0.26 / 0.88 | 0.10 / 0.60 / 0.61 / 0.65 |

Findings:

1. **Both presets remove spiky artifacts well** — cable movement and pops
   0.9–0.99, muscle ~0.9, blinks up to ~0.87 (hard) / ~0.88 (soft).
2. **Hard destroys sharp brain transients** (~0–0.05 preserved up through scale 2);
   there is no hard operating point that preserves them while removing blinks.
3. **Soft is ~5–15× gentler on transients at the same threshold** (scale 1:
   K-complex 0.25 vs 0.00, sharp wave 0.33 vs 0.02) while removing artifacts nearly
   as well — but it is still a **tradeoff, not a free lunch**: at blink-removing
   thresholds (scale ≤1) even soft keeps only ~0.25–0.33 of the transients, and
   pushing preservation past 0.5 (scale ≥2) drops blink removal to ~0.6. Sharp waves
   survive soft best; **spindles are the stubborn case** (peaks ~0.38, non-monotone),
   likely because they are low-amplitude oscillatory bursts.
4. **Removed variance is not a usable grade proxy within a preset** — it does not
   track transient loss; it only loosely separates the gentler preset from the
   harsher one.

**Conclusion:** the guidance is preset-specific, not a blanket caution. **Use the
soft/ERP preset on data with sharp brain features** (sleep transients, sharp/
epileptiform waves); the hard/EEG preset will eat them. Even soft partially
attenuates spindles and sharp features at artifact-removing thresholds, so a
**caution still applies for the sharpest features** — and because removed variance
doesn't track that loss, wavelet still gets a caution rather than a truth-free
Good/Watch/Poor pill. This harness stays a truth-based regression on the reducer.

Remaining: **ERP components** — severity is shape/amplitude dependent (sharp waves ≈
K-complexes worst; broad low-frequency P300/N400 largely safe, and single-trial
averaging protects them further; N170 intermediate). Put numbers on that ordering
with `ERPGenerator`/`score-erp`.

### How this sits against the HAPPE papers (2026-09-13)

Reviewed HAPPE (Gabard-Durnam et al., 2018) and HAPPE+ER (Monachino et al., 2022)
to place the finding. No source was read — published papers only; EVA's clean-room
wavelet provenance is unaffected.

- **Application context — corrected.** The 2018 paper describes **W-ICA**: wavelet-
  threshold the *ICA component* timeseries, then back-project (Castellanos &
  Makarov, 2006). But EVA's own measured parity ([`happe-wavelet-parity.md`](happe-wavelet-parity.md),
  HAPPE **4.1.0**, using HAPPE's own `prewav`/`wavclean`) shows current HAPPE
  wavelet-thresholds **per channel, in channel space, no ICA** — EVA reproduces it
  at removed-artifact correlation ≈ 1.0, which is only possible if HAPPE is
  channel-space. So current HAPPE dropped W-ICA-on-components for channel-space
  wavelet. **Our channel-space calibration therefore tests HAPPE's actual current
  method, not a misuse.**
- **HAPPE+ER deliberately chose wavelet over ICA for ERPs** (§2.7), with soft/hard
  options, and **validated it on a simulated VEP** (SEREEGA N1/P1/N2, embedded in
  real EEG with real artifacts) using bias-vs-contamination, SE-around-the-mean, and
  trial-rejection metrics — essentially our `evaluate-retention` framing. They
  concluded wavelet best removes artifact while retaining the simulated ERP.
- **No conflict — complementary.** HAPPE+ER measured **broad evoked components**
  (the safe end); it did **not** simulate sharp brain transients (K-complexes,
  spindles, epileptiform sharp waves) — the regime our calibration covers, and the
  one HAPPE 2018 explicitly flagged as untested pathological waveforms. So: wavelet
  preserves broad evoked ERPs (their result) **and** attenuates sharp transients,
  hard especially (our result). Same operation, different signal classes.
- **Paper thread.** This is a constructive extension of HAPPE+ER into the
  sharp-transient regime they left for future work, on shared, truth-backed,
  simulation-based terms (they publish the simulated VEP + `generateERPs`) — the
  basis for a MAAC-vs-HAPPE comparison. Not a rebuttal.

## EMG carrier autocorrelation (`--emg-autocorrelation`)

BSS-CCA separates muscle from brain on autocorrelation — surface EMG is broadband
(low autocorrelation), brain is not. The EMG carrier's first-order (AR-1) coloring
knob lifts its autocorrelation toward brain-like, stressing the separation until
it fails; with brain gamma present, failure appears as gamma lost from the cleaned
data. Variance-preserving and Optional/nil default (byte-identical). Low-rank
movement for movement-PCA is already provided by `cableMovement`, whose truth
carries a per-episode topography.

## Honest limits

- These measure against a *simulator's* truth; realistic inter-subject and
  non-stationary variability is narrower here than in real recordings (the same
  caveat as the PCA-S campaign — see [[pca-s-adversarial-evaluation]]).
- `evaluate-retention`'s built-in cleaner is Gratton–Coles regression; other
  methods (ICA, MSEC/PCA-S ocular) should be run through the same harness before
  their bands are trusted.
