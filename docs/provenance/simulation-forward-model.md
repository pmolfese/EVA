# Simulation Forward Model — Derivation Record

Covers `Tools/EVASimulate`. Written 2026-08-21.

## What it is

A generator of synthetic EEG with known ground truth, contaminated by modelled
MR gradient and ballistocardiogram artifacts, plus a scorer that compares a
corrected recording against that ground truth per frequency band.

It is a measurement instrument for EVA's correction methods, not a correction
method itself. Nothing in the app links against it; it is a standalone CLI in
the same shape as `Tools/EVABIDS` and `Tools/EVAHelper`, reusing only
`EVA/Core/DSP.swift`, `EVA/Core/SeededGenerator.swift`, `EVA/Core/LinearAlgebra.swift`
and the MFF reader/writer.

## Source of the model

Everything is written from the published description in:

> Grouiller F, Vercueil L, Krainik A, Segebarth C, Kahane P, David O (2007).
> A comparative study of different artefact removal algorithms for EEG signals
> acquired during functional MRI. NeuroImage 38(1):124-37.
> doi:10.1016/j.neuroimage.2007.07.025

No source code from that work, from EEGLAB/FMRIB, from FACET, or from any other
toolbox was consulted or translated. The paper describes its forward model in
prose and equations only — there is no reference implementation to port — so
this track raises none of the copyleft questions tracked in `copyleft-plan.md`.

The one equation reproduced verbatim is the evaluation metric,
`SNR = std(EEG) / std(EEG − EEG_corrected)`, which is stated in the paper's
Equation 2 and is not a creative artifact.

## Derived versus invented

`Tools/EVASimulate/README.md` carries the full list under "What comes from the
paper and what does not", and it is the authoritative one. In summary:

- **Parameters** are the paper's throughout — band structure, alpha modulation
  depth and period, spatial smoothing kernel, EPI geometry, artifact amplitude
  ranges, the 152 µs/s clock offset, slow modulation depth and period, heart
  rate range, BCG amplitude statistics, channel latency spread, QRS jitter, and
  the sigmoid motion-sensor nonlinearity.
- **Waveform shapes** are EVA's. The paper used a gradient template measured on
  their own 3T Bruker and characterizes the BCG only by "global features". The
  synthetic gradient waveform here is built as the time derivative of a modelled
  slice-select trapezoid plus EPI readout train (induced EMF goes as dB/dt); the
  BCG is four Gaussian lobes. `--gradient-template` accepts a measured template
  and should be preferred for published work.

## Validation

`eva-simulate selftest` pins three properties of the generated data:

1. **Locked clocks hit the sqrt(N) ceiling.** With `--clock-offset 0` and a TR
   that is a whole number of samples, every volume's artifact is identical, so
   average-artifact subtraction cancels it exactly. The only residual is the EEG
   the template averaged in, std(EEG)/sqrt(N) — so the SNR of a "perfect" naive
   AAS is sqrt(N), not infinity. Measured 4.73 against a predicted 4.47 for
   N = 20 volumes.
2. **The paper's clock drift defeats it.** The same subtraction with 152 µs/s
   scores 0.053, roughly 90x worse, because slice artifacts no longer repeat
   their sub-sample phase.
3. **QRS jitter penalizes timing-dependent correction.** AAS at the jittered
   detected beat times scores below AAS at the true beat times (1.33 versus
   4.51), reproducing the mechanism behind the paper's Figure 5B.

A fourth check is implicit in any scoring run: the uncorrected recording's
per-band SNR is worst at harmonics of the slice rate, which is the signature a
real EPI artifact has.

The minimal AAS used in these checks is written inside `SelfTest.swift` rather
than borrowed from EVA. The checks are testing the *data*, so the corrector has
to be simple enough to be obviously correct; using EVA's own corrector would
make a failure ambiguous between the model and the method.

## Determinism

Two runs of the same seed produce byte-identical packages and sidecars, verified
by hash. All randomness comes from `SeededGenerator` (SplitMix64), the recording
timestamp is fixed rather than `Date()`, and JSON output is written with sorted
keys. This matters for the same reason `REWIND.md` item 5 does: a benchmark that
moves between runs cannot support a claim about which method is better.

## Known limitations

Stated at length in the tool's README. The one with the sharpest consequence:
the modelled EEG is stationary, and the paper itself concludes that this is the
likely reason ICA performed far better in their simulations than on their
experimental data. Simulation results about ICA specifically should not be
trusted without an experimental check.
