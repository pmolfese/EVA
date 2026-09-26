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
15-sample search radius, clock-synced runs at 500 Hz and 1 kHz, and the
simulator's slice template zero-padded before its anti-alias filter (see
Engine findings). 132 runs, 2640 channel pairs.

The table was re-run after the FASTR alignment fix (ROADMAP MRI-1) on
2026-09-26; the pre-fix table is in git history. Only FASTR rows changed.

### Findings

- **The simulator's gradient problem is hard.** At 500 Hz without clock sync,
  every engine leaves a residual far above the brain (truth p90 in the hundreds
  to thousands). Clock-synced runs reach the brain's own scale with FASTR (truth
  0.13 at 500 Hz, 0.21 at 1 kHz) and local-median (0.17, 0.23). This matches the
  literature's advice — sync the clocks and sample fast — and it means the grade
  will read Poor for most unsynchronised low-rate recordings on this simulator.
  Part of that harshness is the simulator's own: its slice template is not
  band-limited (Engine findings), and with it zero-padded FASTR reaches truth
  60 at 500 Hz without clock sync. Whether real scanners are as harsh is still
  the open question (a measured template via `--gradient-template` would settle
  it, once the template edge problem is fixed).
- **The locked-residual metric is a classifier, not an estimator.** It
  saturates near 1 once residue dominates while truth spans 1–10⁵, so rank
  correlation is poor (Spearman −0.10 run-level; −0.42 before the FASTR fix).
  As a separator it is clean:

  | metric ≥ τ | flags truth-poor (≥ 1) | flags the 8 non-poor runs |
  |---:|---:|---:|
  | 0.05 | 124/124 | 7/8 |
  | 0.08 | 123/124 | 0/8 |
  | 0.10 | 123/124 | 0/8 |
  | 0.30 | 118/124 | 0/8 |
  | 0.50 | 102/124 | 0/8 |

  **Bands: Good < 0.10, Watch 0.10–0.30, Poor ≥ 0.30** — unchanged by the
  re-run. The non-poor runs are now the four clock-synced FASTR runs as well as
  the four local-median ones; the highest of them reads 0.078.
- **Its blind spot is residue not locked to the given markers** — grossly
  jittered markers (50 samples: Allen 0.26, local 0.10) and aliased artifact
  (anti-alias off: FASTR 0.18). **Removed variance covers exactly those cases:**
  every run that corrected well removed ≥ 0.999 of the scan's variance; those
  blind-spot failures removed 0.04–0.64; Allen IAR with dropped markers removed
  2.1–4.3 (subtracting a template where there was no artifact).
  **Bands: Poor < 0.90 or ≥ 1.05, else Good** — no Watch band, because nothing
  in the data distinguishes one.
- **The in-band (≤ 40 Hz) metric separates worse** (at 0.10: 110/124 poor, 4/8
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

- **FASTR alignment — fixed 2026-09-26.** Three separate things left residue,
  not one:
  1. *The slip.* The default search radius (`period / 20`, capped at 64)
     exceeded the slice period on volume epochs, so epochs locked onto the
     neighbouring slice (±37 samples at 500 Hz) and ~35 samples per epoch edge
     were left uncorrected. The default is now capped below half the lag at
     which the reference epoch first correlates ≥ 0.5 with itself again — the
     slice period on volume epochs, giving 18 at 500 Hz. Slice-level epochs and
     artifacts that do not repeat keep the period bound.
  2. *A final epoch one sample short.* A window includes the next epoch's
     trigger, so a recording that stops exactly one TR after its last trigger
     (every clock-synced simulation) lacks the final window's closing sample.
     The aligner then pushed that epoch 2–3 samples off its artifact to make it
     fit. That single epoch was the whole of FASTR's synced residue (truth 93 →
     0.13 at 500 Hz, 230 → 0.21 at 1 kHz). The corrector now repeats the last
     sample in exactly that case and crops it from the output.
  3. *A biased sub-sample estimate.* A parabola through Pearson correlations at
     whole-sample lags missed the true phase by 0.09 samples (SD) on this sharp
     artifact. The offset is now the peak of the cross-correlation interpolated
     with the corrector's own fractional-delay kernel, and the second-pass
     reference is built from sub-sample-aligned epochs: 0.018 samples on the
     simulator's template, 0.004 on a band-limited one.

  Bounding the radius alone (the old `FASTR r15` row) did not help because (2)
  and (3) were still there. After the fix the drifting-clock rows barely move at
  500 Hz (baseline 1254 → 1322) — that is the simulator's floor, next item: with
  the *true* phases supplied, FASTR on the simulator's template still reads
  ~1300. At 1 kHz it halves (243 → 128). One row moved the wrong way and is
  unexplained on two seeds: 2 donors/side, 1398 → 1825.
- **The simulator's slice template is not band-limited** (EVACore
  `GradientArtifactModel.antiAliasedTemplate`). The FFT low-pass is applied to
  the template's own window, so the filtered waveform starts at +0.28 and ends
  at −0.34 of peak-to-peak — against `HighRateTemplate`'s own rule that a
  template start and end at zero. Those steps leave 1.5 % of its energy above
  the output Nyquist, which aliases: shifting one simulated volume onto another
  by its exact sub-sample phase leaves ~5 % of the artifact's energy even with
  a 64-lobe sinc. Zero-padding the template by 30 ms before filtering (the `sim
  template padded` row) brings FASTR to truth 60 at 500 Hz; Allen IAR and
  local-median stay in the thousands, since neither shifts on a sub-sample grid.
  A `--gradient-template` goes through the same filter.
- **FASTR's 8-lobe fractional delay is the next limit** on a band-limited
  artifact: 24 lobes took the padded-template case from ~59 to ~23 in a CPU-only
  experiment. The Metal kernels hard-code 16 taps, so this needs both backends.
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
