# Run-Grade Calibration (SI-4 generalization)

Measured-results record for the Good / Watch / Poor run grades beyond PCA-S
(ROADMAP § Processing run-grade). Each section names the truth-free number the
app grades on, the simulated truth it was checked against, and where the band
edges came from. Evidence, not specification: the bands live in code
(`GradientRunGrade`, `ICARunGrade`, `ArtifactCleanRunGrade`) with regression
tests pinning them.

- **Date:** 2026-09-26
- **Harness:** env-gated EVATests calibrations run by `scripts/calibrate.sh
  <gradient|ica|artifact>`; each drives EVA's real engines on EVACore simulator
  data, in parallel across cores. Raw tables in `docs/provenance/data/*-calibration/`.
- **Caveat carried from the PCA-S campaign:** these measure against a
  simulator's truth. Real inter-subject and non-stationary variability is wider,
  and the synthetic gradient waveform is EVA's own model, not a measured one.

## Gradient (`GradientRunGrade`)

### What is graded

1. **TR-locked residual** — the corrected scan is folded into TR epochs and, at
   every phase of the TR cycle, the variance across epochs is taken. Brain
   activity has no preferred TR phase, so that profile is flat on a clean run;
   residual artifact piles up at the phases where the artifact lives. The metric
   is the share of corrected energy above the profile's flat floor (a quartile,
   corrected for its own χ² spread by Wilson–Hilferty). p90 across channels.
2. **Removed variance** — `var(input − output) / var(input)` over the scan,
   both sides demeaned. Graded only at its extremes.
3. **Epoch coverage** — epochs the engine corrected / was given. A structural
   rule (≥ 0.98 good, < 0.90 poor), not calibrated: no simulated condition
   reduced coverage below 0.98.

A 40 Hz low-passed version of (1) is reported in the breakdown but not graded
(see below).

### Truth and scenarios

`residual error = var(corrected − clean) / var(clean)` over the scan, per
channel, p90 across channels. 20 channels, TR 3 s, 41 slices, 150 s, 500 Hz, 2
seeds, three engines (FASTR with sub-sample alignment, Allen IAR, local-template
median). One axis at a time from the paper's rig (152 µs/s clock offset, 10 %
slow amplitude modulation): clock offset 0–5000 µs/s, modulation 0–0.6,
anti-alias filter off, 250/1000 Hz, marker jitter 1–50 samples, 5–20 % of
markers dropped, FASTR donors 1–15/side, FASTR alignment off, FASTR with a
15-sample search radius, and clock-synced runs at 500 Hz and 1 kHz.
126 runs, 2520 channel pairs.

### Findings

- **The simulator's gradient problem is hard.** At 500 Hz without clock sync,
  every engine leaves a residual far above the brain (truth p90 in the hundreds
  to thousands). Only clock-synced local-median correction reached the brain's
  own scale (truth 0.17–0.23). This matches the literature's advice — sync the
  clocks and sample fast — and it means the grade will read Poor for most
  unsynchronised low-rate recordings. That is the honest reading of this
  simulator; whether real scanners are as harsh is the open question (a measured
  template via `--gradient-template` would settle it).
- **The locked-residual metric is a classifier, not an estimator.** It
  saturates near 1 once residue dominates while truth spans 1–10⁵, so rank
  correlation is poor (Spearman −0.42 run-level). As a separator it is clean:

  | metric ≥ τ | flags truth-poor (≥ 1) | flags the 4 non-poor runs |
  |---:|---:|---:|
  | 0.05 | 122/122 | 3/4 |
  | 0.08 | 121/122 | 0/4 |
  | 0.10 | 121/122 | 0/4 |
  | 0.30 | 116/122 | 0/4 |
  | 0.50 | 104/122 | 0/4 |

  **Bands: Good < 0.10, Watch 0.10–0.30, Poor ≥ 0.30.**
- **Its blind spot is residue not locked to the given markers** — grossly
  jittered markers (50 samples: Allen 0.26, local 0.10) and aliased artifact
  (anti-alias off: FASTR 0.18). **Removed variance covers exactly those cases:**
  every run that corrected well removed ≥ 0.999 of the scan's variance; those
  blind-spot failures removed 0.04–0.64; Allen IAR with dropped markers removed
  2.1–4.3 (subtracting a template where there was no artifact).
  **Bands: Poor < 0.90 or ≥ 1.05, else Good** — no Watch band, because nothing
  in the data distinguishes one.
- **The in-band (≤ 40 Hz) metric separates worse** (at 0.10: 113/122 poor, 2/4
  non-poor flagged) — Allen IAR's ANC stage leaves residue whose low-frequency
  part is not phase-locked (modulation 0.3/0.6 read 0.000–0.001 in-band against a
  truth of 10³). Reported for context, not graded.
- **Design traps met on the way, kept here so they are not re-tried:**
  - *Projecting onto span{A, A′}* (template and derivative) fails: at EEG
    sampling rates the residue is sub-sample spike jitter and uncorrected edge
    slices, which no first-order template model describes (Spearman 0.05).
  - *Centring each epoch* makes slow brain activity swing widest at the epoch
    edges — a false TR-locked shape.
  - *High-passing before profiling* smears a one-sample residue across its
    neighbours and inflated one run's metric 12× (0.07 → 0.83).
  - *Removed variance with an un-demeaned numerator* read ~2.8 on every run: the
    artifact carries an offset.

### Engine findings (filed under ROADMAP MRI-1)

- FASTR's alignment search radius (`period / 20`) exceeds the slice period on
  volume epochs, so it slips by a whole slice (±37 samples at 500 Hz) and
  leaves ~35 samples per epoch edge uncorrected. Bounding the radius to 15
  samples did not by itself fix FASTR here (truth still ~10³), so the slip is
  not the only cost.
- The local-template engine leaves the last sample of each TR epoch uncorrected
  at 1 kHz.
- Allen IAR over-subtracts with missing markers and underperforms local-median
  on synced clocks.

### Not measured

Over-removal of brain (an aggressive OBS stage): it leaves nothing TR-locked and
removes ~1.0 of the variance, so it grades Good. Nothing truth-free in the
corrected scan separates removed brain from removed artifact.

## ICA (`ICARunGrade`)

### What is graded

1. **Removed components** — the largest ICLabel Brain probability among the
   removed components: Poor ≥ 0.5 (ICLabel reads it as brain), Watch ≥ 0.25.
   Without probabilities (heuristic labeller, headless replay) a removed
   component *labelled* Brain is Watch. **A convention, not a measurement** —
   ICLabel labels synthetic sources unreliably (the W-ICA fixture had it call
   the ocular source Muscle), so it cannot be calibrated on this simulator.
2. **Data per component** — κ = analysis samples / components². Watch below
   20 (the Onton & Makeig 2006 rule of thumb). **Also a convention** — see
   the null result below.

Reported, not graded: convergence (iterations vs the cap) and removed variance.

### Campaign

EVA's Picard, 125 Hz analysis rate, on seeded dipole EEG with non-Gaussian
(bursty) sources and 16 blinks/min; 20 and 32 channels; durations chosen for κ
≈ 4–150; 3 seeds. The source count was set to n − 4 so brain plus ocular
sources fill the rank of average-referenced data — at the simulator's default
of 7 sources, PCA trims every decomposition to the true rank and every run is
data-rich, which is the first attempt's (discarded) result. The removed
component was chosen by **oracle** (best correlation with the true ocular
signal), so the numbers describe the decomposition, not the labeller.

### Findings

- **Null result for κ.** The oracle component matched the blink at
  |r| ≥ 0.993 from κ ≈ 4 to κ ≈ 150, and neither blink removal (0.64–0.80) nor
  brain lost (0.06–0.37) tracked κ; both tracked each seed's ocular share. A
  blink is ICA's easiest case — large and strongly non-Gaussian — so this says
  the 20 × n² rule is not needed *for blinks*, and says nothing about weaker
  sources (muscle, small cardiac, residual BCG). Hence Watch, not Poor, and the
  band stays on the published convention.
- **Convergence did not predict quality.** Most fits stopped at the 200
  iteration cap even at tolerance 1e-7; the two conditions with both converged
  and capped runs are confounded by seed. The app's default tolerance is 1e-12,
  so grading the cap would flag nearly every run on no evidence.
- **Oracle removal of one component takes 0.64–0.80 of the ocular artifact and
  removes brain worth 0.06–0.37 of the brain's variance.** The eye model spans
  more than one dimension; a single-component removal is a partial correction
  even when the decomposition is right.

### Not measured

Weak or less non-Gaussian artifact sources vs κ; ICLabel accuracy on real data
(which is where the Removed-components band actually does its work).

## Artifact clean (`ArtifactCleanRunGrade`)

### What is graded

1. **Recording touched** — the fraction of time points at which any graded
   channel changed (> 1e-4 µV). Watch at ≥ 20 %; **no Poor band**. Not graded
   when a continuous correction (MAAC corneo-retinal regression, movement PCA,
   BSS-CCA) ran — those touch every sample by design, and MAAC grading is
   deferred.
2. **Events for OBS/SSP** — the fewest events behind a pooled-basis artifact:
   Watch below 20.

Reported, not graded: removed variance.

### Campaign

Oracle blink events (true onsets, 0.8 s windows) at 3–100 blinks/min; OBS
(2 components), MAS, per-event wavelet; 20 channels, 250 Hz, 120 s, 2 seeds.
`err = var(· − clean) / var(clean)`; brain lost = the part of each change that
was not artifact, inside touched samples.

| method | touched | err before | err after | gain | brain lost |
|---|---:|---:|---:|---:|---:|
| OBS | 0.07 | 0.12 | 0.105 | 1.1 | 0.105 |
| OBS | 0.20 | 0.34 | 0.083 | 4.1 | 0.082 |
| OBS | 0.40 | 0.69 | 0.144 | 4.8 | 0.144 |
| OBS | 0.92 | 1.66 | 0.284 | 5.8 | 0.278 |
| MAS | 0.16 | 0.34 | 0.041 | 8.2 | 0.040 |
| MAS | 0.46 | 1.02 | 0.122 | 8.4 | 0.114 |
| MAS | 0.73 | 1.66 | 0.211 | 7.9 | 0.205 |
| Wavelet | 0.16 | 0.34 | 0.067 | 5.1 | 0.066 |
| Wavelet | 0.46 | 1.02 | 0.241 | 4.2 | 0.233 |
| Wavelet | 0.73 | 1.66 | 0.395 | 4.2 | 0.388 |

### Findings

- **Cleaning beats keeping the artifact at every density** — 4–8× less error
  even with 90 % of the recording touched. There is no touched fraction at
  which the run becomes harmful relative to not cleaning, so no Poor band.
- **The residual error is almost all brain distortion, and it scales with the
  touched fraction:** inside rewritten windows ~30 % (OBS, MAS) to ~50 %
  (wavelet) of the brain's variance is distorted. On the same truth scale as the
  gradient grade (error < 0.1 of brain variance = good), the error crosses 0.1
  at 20–35 % touched depending on method → **Watch from 20 %**, the
  method-agnostic lower edge. It never reached the ≥ 1 "poor" line (max 0.40).
- **OBS needs events.** With ~6 events (3 blinks/min) OBS cut the error only
  1.1×; with ~20 it cut it 4×. MAS and wavelet, which do not pool a basis, were
  fine at 6. → **Watch below 20 events** for OBS/SSP. Two points, so the edge is
  "where it was measured to work", not a fitted threshold.

### Not measured

Real (non-oracle) detection, where missed and false events change both the
touched fraction and the harm; regression and SSP/PCA directly; the MAAC
continuous methods (deferred).

## MAAC — deferred

Not graded yet, by owner decision (2026-09-26): MAAC adoption itself is not
settled, so its run grades wait with it. The bands the ROADMAP proposed — gamma
preservation for BSS-CCA muscle correction, and a movement-PCA equivalent — need
their own campaigns. Until then, a cleaning run that includes a continuous MAAC
method reports its touched fraction without grading it.
