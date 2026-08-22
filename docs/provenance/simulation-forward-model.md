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
  the sigmoid motion-sensor nonlinearity. The operational sample-rate default is
  1000 Hz so the current millisecond-precision MFF event writer preserves sample
  indices; `scenarios/paper-default.json` retains the paper's 1024 Hz rate.
- **Waveform shapes** are EVA's. The paper used a gradient template measured on
  their own 3T Bruker and characterizes the BCG only by "global features". The
  synthetic gradient waveform here is built as the time derivative of a modelled
  slice-select trapezoid plus EPI readout train (induced EMF goes as dB/dt); the
  BCG is four Gaussian lobes. `--gradient-template` accepts a measured template
  and should be preferred for published work.

### Opt-in source-space model

`--eeg-model dipole` is separate from the Grouiller reproduction and is off by
default. It projects deterministic neural current dipoles through concentric,
homogeneous, isotropic shells. The arbitrary-shell recurrence and
spherical-harmonic surface potential follow:

> Bruña R, Fuggetta G, Pereda E (2023). One Definition to Join Them All: The
> N-Spherical Solution for the EEG Lead Field. Sensors 23(19):8136.
> doi:10.3390/s23198136

`SphericalForwardModel.swift` was written independently from the equations in
the CC BY article. The authors' GPL reference implementation was not copied or
translated. The initial brain/skull/scalp preset (72/79/85 mm;
0.33/0.0042/0.33 S/m) is the standard model reported in spherical-head
validation literature. Source placement, orientation sequencing, average
reference and the common 10.9 µV calibration are EVA's and are recorded in the
truth sidecar.

### Source identity, reference, and ERP design contracts

Correlated dipole sources are now mixed only within a configured band: S002 is
assigned S001's band before the exact Pearson-correlation construction. This
keeps the band label in source truth valid. The construction itself remains an
EVA-controlled scenario choice.

The complete additive sensor mixture has one declared recording reference,
`average` by default or `infinity` on request. Neural/ERP activity, scanner and
physiological artifacts, contact noise, and mains pickup are combined before
that reference is applied. Bad-reference corruption, channel defects, bridges,
and clipping occur afterward because those physical failures can break the
nominal reference. The sidecar records the convention and boundary.
The operational default is average reference; the reviewed paper-default
scenario selects infinity to preserve the simulator's legacy Grouiller path.

ERP latency, amplitude, condition assignment, onset jitter, and omission use
separate named seed domains. Their seeds are recorded so changing one factor
does not invisibly consume another factor's draws. Component-window endpoints
and directional overlap flags are also truth: overlapping trials remain valid
source-space simulations, while `score-erp --exclude-overlap` defines an
unambiguous sensor-peak subset.

### Opt-in roadmap 2.1 artifacts

The EMG layer is EVA's controlled validation model and is not part of Grouiller
et al. It uses three independent 20-200 Hz Gaussian carriers localized by
spherical angular kernels at left temporalis, right temporalis, and posterior
neck. Smooth stochastic burst envelopes vary onset, duration, source region, and
amplitude. These choices reproduce the broad spectral, spatial, and temporal
properties needed to challenge correction methods; they are not a fitted
motor-unit or subject-specific volume-conduction model. All parameters and
realized burst/topography truth are retained in the scenario and sidecar.
Chewing adds rhythmic temporalis envelopes and swallowing a stereotyped
double-lobed posterior-neck envelope. Cable movement uses a broad angular field
and sub-Hz oscillation; sweat uses slow local drift. Channel bridging, common
bad-reference contamination, and hard symmetric clipping operate on the final
recorded voltage and retain exact pair/RMS/count truth. These are controlled EVA
models rather than parameters derived from the Grouiller paper.

Electrode impedance is realized before recording noise. The operational model
adds per-contact Johnson-Nyquist voltage noise using `sqrt(4 k T R B)` at
298.15 K over the sampled Nyquist bandwidth, and scales mains pickup by an
explicit impedance power law relative to 12 kΩ (linear by default) with small seeded lead-dress
variation. Exact impedance, thermal RMS, and mains-gain vectors are retained in
truth. This coupling is an EVA realism model, not part of Grouiller et al.; the
paper-default scenario disables it. Flat and explicitly bridged contacts retain
low impedance, deliberately breaking the usual impedance/data-quality
relationship. The Johnson calculation treats impedance magnitude as an
effective resistance; real electrode-skin impedance is complex and
frequency-dependent.

### Opt-in neural non-stationarity

Roadmap 1.3 is an EVA-controlled validation model, off by default so the
Grouiller reproduction remains stationary. Alpha onsets follow a moderate-CV
lognormal renewal process; durations are Gaussian-constrained and multiplied by
sin² spindle envelopes. Each configured EEG band's amplitude follows an
independently seeded log-amplitude Ornstein–Uhlenbeck process. Microstates use
generated, zero-mean unit-RMS sensor topographies, constrained lognormal dwell
times and a seeded 2–20 Hz carrier with smooth transitions. PAC adds a known
phase oscillator and applies a normalized cosine amplitude gain to the selected
higher-frequency band.

These laws and their defaults are phenomenological simulator choices, not
parameters reported by Grouiller et al. The sidecar retains alpha events,
one-Hz amplitude envelopes, microstate episodes and maps, carrier provenance,
and full PAC parameters. In dipole mode the microstate term is added in sensor
space after lead-field projection, so it is intentionally absent from the
intracranial `_sources.mff` catalog.

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

The source-space checks separately pin the centered homogeneous-sphere closed
form, free- and fixed-orientation average-reference constraints, orientation
sign reversal, prefix-stable source placement, independence of BCG draws from
source count, target-amplitude calibration and sample-for-sample determinism.
The truncation diagnostic additionally compares every free-orientation gain
column at `N` and `2N` terms using an L2-relative change. Its `1e-4` threshold is
tested across source-radius fractions 0.01 through 0.999999 for the classic
three-shell model, and a deliberately under-resolved 10-term case must fail.
This establishes numerical series convergence; it is not an independent check
of the forward-model equations.
The EMG checks pin deterministic samples and markers, zero output outside burst
windows, dominant 20-200 Hz power, and temporalis/posterior localization.
Five further checks pin deterministic orofacial events, broad movement versus
local sweat, exact bridge equality, common-reference identity, and clipping
rails/counts.
Three impedance-coupling checks pin the Johnson square-root resistance law and
disabled path, ordered impedance-dependent mains gains, and the low-impedance
true-bridge counterexample.
Five non-stationarity checks pin stationary-default compatibility and seeded
determinism, plausible alpha burst timing and quiet intervals, slow continuous
band envelopes, distinct 40–250 ms microstate episodes without immediate state
repeats, and gamma amplitude maximal at the known PAC phase.
Four further correctness checks pin within-band correlated-source identity, the
shared reference boundary, ERP factor-stream prefix stability, and explicit
overlap classification.

## Determinism

Two runs of the same seed produce byte-identical packages and sidecars, verified
by hash. All randomness comes from `SeededGenerator` (SplitMix64), the recording
timestamp is fixed rather than `Date()`, and JSON output is written with sorted
keys. This matters for the same reason `REWIND.md` item 5 does: a benchmark that
moves between runs cannot support a claim about which method is better.

## Known limitations

Stated at length in the tool's README. The paper-compatible default remains
stationary, while the opt-in non-stationarity layer supplies controlled bursts,
spectral dynamics, microstates and PAC. The paper itself identifies stationarity
as the likely reason ICA performed much better in simulation than experimental
data, so ICA studies must enable and sweep that layer and still require an
experimental check; one phenomenological law is not population validation.
