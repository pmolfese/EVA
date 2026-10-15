# Run-Grade Calibration (SI-4 generalization)

Measured-results record for the Good / Watch / Poor run grades beyond PCA-S
(ROADMAP § Processing run-grade). Each section names the truth-free number the
app grades on, the simulated truth it was checked against, and where the band
edges came from. Evidence, not specification: the bands live in code
(`GradientRunGrade`, `ICARunGrade`, `ArtifactCleanRunGrade`) with regression
tests pinning them.

- **Date:** 2026-09-26; FASTR C5 follow-up 2026-09-27
- **Harness:** env-gated EVATests calibrations run by `scripts/calibrate.sh
  <gradient|ica|artifact>`; each drives EVA's real engines on EVACore simulator
  data, in parallel across cores. C5 uses the separately gated
  `FASTRC5EvaluationTests`; its acquisition and recommendation follow-ups used
  temporary gated evaluation harnesses and retained CSV outputs rather than an
  application entry point. Raw tables are in
  `docs/provenance/data/*-calibration/`.
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
- **Re-run after the simulator's template was band-limited (2026-09-26, ROADMAP
  MRI-1).** The template is now padded before its anti-alias filter (Engine
  findings, below), which removes the simulator's own floor: baseline FASTR
  truth p90 fell from the thousands to 54 at 500 Hz and 9 at 1 kHz; synced
  FASTR 1.4 (500 Hz) and 0.22 (1 kHz). Allen IAR and local-median barely move —
  they cannot shift by a sub-sample. The metric now tracks truth: Spearman
  run-level 0.47 broadband / 0.68 ≤ 40 Hz (per channel 0.54 / 0.81), against
  −0.10 / −0.11 before. The campaign has 128 truth-poor runs and 4 in the Watch
  range (0.1–1), still none truth-good:

  | metric ≥ τ | flags truth-poor (≥ 1) | flags the 4 truth-watch runs |
  |---:|---:|---:|
  | 0.05 | 127/128 | 4/4 |
  | 0.08 | 127/128 | 1/4 |
  | 0.10 | 127/128 | 0/4 |
  | 0.30 | 121/128 | 0/4 |
  | 0.50 | 117/128 | 0/4 |

  **Bands kept: Good < 0.10, Watch 0.10–0.30, Poor ≥ 0.30.** The ≤ 40 Hz metric
  still separates worse (at 0.10: 87/90 poor, 35/42 watch flagged). Removed
  variance still separates as before: runs that corrected well removed
  ≥ 0.999; Allen IAR with jittered markers (10, 50 samples) now removes 61 and
  211 — a template subtracted where the artifact was not — and with dropped
  markers 0.84–0.87, Poor either way. Data:
  `data/gradient-calibration/eva-gradient-run-grade.{txt,csv}`. The earlier
  numbers in this section are kept as the record of the pre-fix campaign.
  Re-run again the same day after Allen IAR stopped leaving the final TR
  uncorrected (ROADMAP MRI-1): its synced truth fell 268 → 3.8 at 500 Hz and
  124 → 39 at 1 kHz, clock-offset-0 truth 220 → 7.8, coverage 0.98 → 1.00. The
  band tables did not move.
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
- **FASTR's 8-lobe fractional delay is a limit on volume epochs at 1×
  upsampling**, not a general FASTR limit. The original CPU experiment used the
  calibration harness's default `GradientCorrectionConfig` (one slice, 1×) and
  took the padded-template case from ~59 to ~23 with 24 lobes. C4/C5 later
  reproduced the volume benefit but found that 24 lobes worsens slice epochs;
  see the C5 ablation below. The Metal kernels hard-code 16 taps, so any change
  still needs both backends.
- The local-template engine leaves the last sample of each TR epoch uncorrected
  at 1 kHz.
- Allen IAR over-subtracts with missing markers and underperforms local-median
  on synced clocks.

### FASTR C5 brain-signal ablation (2026-09-27)

The C5 campaign ran the real CPU FASTR engine twice for every configuration:
once on clean dipole EEG carrying MRI triggers but **no** MRI artifact, and once
on the same EEG with the simulator's band-limited gradient artifact. A perfect
brain-only run has truth 0, correlation 1 and beta 1. Conditions: deterministic
single seed, 500 Hz, 60 s, 8 channels, TR 3 s, 41 slices, 152 µs/s clock drift,
10 % slow modulation, four donors on each side. Volume mode used 1× unless the
row says otherwise; slice mode used 5×, the best point in the preceding
1/2/4/5/10 factor sweep. Values below are channel medians. Raw table:
`data/gradient-calibration/eva-fastr-c5-ablation.csv`.

| configuration | clean truth | clean r / beta | artifact truth | artifact r |
|---|---:|---:|---:|---:|
| volume, temporal baseline | 0.067 | 0.969 / 0.963 | 6.95 | 0.421 |
| volume, 5× | 0.102 | 0.957 / 0.966 | 26.33 | 0.230 |
| slice, temporal baseline | 0.078 | 0.977 / 1.123 | 35.65 | 0.237 |
| slice, correlation, default threshold | 0.195 | 0.919 / 0.980 | 4.15 | 0.506 |
| slice, correlation, permissive threshold | 0.547 | 0.695 / 0.522 | 4.11 | 0.507 |
| slice, temporal + OBS | 0.296 | 0.855 / 0.786 | 0.60 | 0.867 |
| slice, temporal + ANC | 0.323 | 0.832 / 0.740 | 7.73 | 0.467 |
| slice, permissive correlation + ANC | 0.737 | 0.576 / 0.417 | 1.70 | 0.672 |

Measured explanation:

- **The low artifact-present correlation is predominantly residual artifact,
  not interpolation erasing the brain.** The baseline brain-only correlations
  are 0.97–0.98 while their artifact-present counterparts are 0.24–0.42. FASTR
  is not a no-op on clean EEG—it changes 6.7–7.8 % of brain variance—but that
  bounded distortion is much smaller than the residual in the failing runs.
- **Sub-sample alignment is necessary, not the cause.** With it disabled,
  artifact truth is 786 in volume mode and 666 in slice mode; integer-only
  alignment reads 691 and 45.8. The corresponding clean runs change 5–8 % of
  brain variance, approximately the baseline. The sub-sample stage is what
  makes the artifact tractable.
- **Template scaling does not explain the low correlation.** Volume artifact
  truth is 6.95 drift-tracked, 7.09 unscaled and 7.11 least-squares. Slice
  temporal is 35.65, 34.72 and 35.23. Scaling changes clean-signal safety more
  than artifact removal: in volume mode clean truth is 0.067 drift-tracked,
  0.186 unscaled and 0.104 least-squares.
- **Upsampling has opposite mode-dependent effects.** Volume truth jumps 6.95
  → 26.33 at 5×. For correlation-ranked slice epochs the earlier factor sweep
  improved truth 28.3 → 16.8 → 5.45 → 4.19 at 1/2/4/5×, with no further gain
  at 10×. “Slice versus volume” therefore cannot be evaluated while also
  changing the upsample factor.
- **Correlation ranking finds artifact-compatible donors but can select brain.**
  On artifact data, the default and permissive thresholds both reach truth
  ~4.1. On clean EEG the default changes 19.5 % of brain variance; admitting
  every candidate changes 54.7 %, with beta 0.52. The raw epoch waveform is not
  a safe donor-ranking signal when artifact evidence is weak.
- **OBS and ANC trade artifact for brain rather than resolving the deficit.**
  Slice OBS is the best artifact score (truth 0.60, r 0.87) but changes 29.6 %
  of clean variance and attenuates beta to 0.79. ANC improves artifact scores
  but changes 25–32 % of clean variance on the volume/temporal baselines and
  73.7 % after permissive correlation ranking. On the volume artifact run OBS
  selected zero components and changed nothing, while its clean run still
  changed 52 %—the residual-energy floor is not an artifact-presence gate.
- **Rounding slice triggers before upsampling is secondary and factor-dependent.**
  At 5×, constructing triggers directly on the high-rate grid worsened temporal
  truth 35.65 → 43.22 and default-correlation truth 4.15 → 4.92, with no clean
  benefit. An exploratory 10× run moved correlation truth 4.22 → 3.41. This is
  not the missing fix and should not be changed without a factor-by-factor
  parity campaign.

Proposed fix and acceptance work, not yet implemented:

1. Add an independent **artifact-present confidence gate** before
   correlation-ranked donation, OBS and ANC. Trigger presence alone is not
   evidence that an artifact reference is informative. Below the gate, skip the
   aggressive stage and report the fallback.
2. Evaluate a shared, same-slice donor strategy based on alignment phase or a
   robust cross-channel artifact reference, rather than ranking each channel's
   raw EEG waveform. It must improve artifact truth without exceeding the
   temporal baseline's clean-signal bound.
3. Turn the brain-only run into an acceptance test: initially require median
   clean truth ≤ 0.10 and r ≥ 0.95 for a default configuration, then validate
   that bound on multiple seeds and injected ERP/oscillation fixtures before
   treating it as normative.
4. Keep OBS and ANC optional until that gate exists. Do not make permissive
   correlation ranking the slice default despite its artifact-present score.

#### Always-on brain-safety sentinels (2026-10-03)

The first acceptance slice is now in the ordinary test suite as
`GradientBrainSafetyRegressionTests`; unlike the C5 campaign, it is not gated by
an environment variable. Three small deterministic tests pin only conclusions
the existing evidence supports:

1. production defaults remain temporal-neighbour donation with OBS and ANC off;
2. the conservative temporal-template path stays inside the C5 development
   bounds (clean truth error ≤ 0.10 and correlation ≥ 0.95) on one fixed,
   non-epoch-locked engineering fixture; and
3. a fixed-phase alternating event/control fixture preserves the known
   counterexample: raw correlation ranking retains less than half the condition
   difference preserved by temporal neighbours.

The third test deliberately records a current hazard. When an artifact-evidence
gate is implemented, it must be converted into an assertion that the gate chose
the conservative path; an apparent algorithmic improvement is not grounds to
weaken or delete it without reviewing ERP transfer. These are regression
sentinels, not real-data validation and not clinical thresholds. Gate thresholds
and production-default changes remain blocked on measured gradient/phantom and
human evidence.

### FASTR C5 follow-up: duration, sampling rate and slice timing (2026-09-27)

This follow-up separates **artifact removal** from the brain-safety scores
above. Unless stated otherwise it runs one artifact-only channel from the same
band-limited simulator through the Metal backend at 500 Hz, 40 slices, plain
correlation-ranked donors, four requested donors on each side and 5× internal
upsampling. The number below is residual artifact energy divided by input
artifact energy; lower is better. It is not the C5 brain-normalized truth
metric, and an excellent value does not establish brain safety. Complete raw
tables are `eva-fastr-next-acquisition-grid.csv`,
`eva-fastr-next-rate-factor.csv`, `eva-fastr-next-timing-oracle.csv`,
`eva-fastr-next-artifact-only.csv`, `eva-fastr-next-donors.csv`,
`eva-fastr-next-retention.csv` and `eva-fastr-next-delay.csv` in
`data/gradient-calibration/`.

#### Recording length: count volumes, not minutes

| TR (s) | 30 s | 60 s | 120 s | 300 s | 600 s |
|---:|---:|---:|---:|---:|---:|
| 0.50 | .04638 | .04453 | .04790 | .04805 | .04826 |
| 1.00 | .00553 | .00175 | .000454 | .000389 | .000391 |
| 1.50 | .01248 | .00394 | .00114 | .000372 | .000346 |
| 2.00 | .01673 | .00517 | .00172 | .000709 | .000293 |
| 2.25 | .01380 | .00502 | .00175 | .000670 | .000349 |
| 2.50 | .03650 | .02614 | .02383 | .02254 | .02220 |
| 2.75 | .10513 | .08996 | .08522 | .08370 | .08294 |
| 3.00 | .02534 | .00801 | .00256 | .000664 | .000307 |

The hard data minimum is much smaller than the useful one. Correlation ranking
can operate with the target plus four qualifying same-slice volumes; a full
eight-donor template needs nine usable volumes. Temporal and volume modes use a
fixed-size nearest-neighbour pool, so once that pool exists extra recording
length does not improve their template. Correlation ranking is different:
more volumes enlarge the pool from which the best same-slice donors are chosen.

For phase-compatible geometries, the large gain continues to roughly 100
volumes. TR 1 s is effectively flat by 120 volumes, and TR 1.5 s changes only
7% from 200 to 400 volumes. The TR 2–3 s cases still improve between the last
two tested points, however, so this sweep does **not** prove a universal plateau
at 200 volumes. A defensible development recommendation is therefore at least
100 usable volumes and preferably about 200 for evaluating correlation-ranked
slice FASTR. At TR 3 s, 200 volumes is the full ten minutes; at TR 2 s, ten
minutes supplies 300. This is an evaluation target, not yet a refusal threshold
for shorter recordings.

The TR 0.5 s / 40-slice row was a parameterisation error, not a demonstrated
short-TR limit: it treated 40 anatomical slices as 40 sequential acquisitions.
An explicit multiband follow-up used the number of simultaneous acquisition
groups instead. With exact group timing and fractional alignment, TR 0.5 s left
only .000127/.000191/.000243/.000265/.000341 residual for MB
1/2/4/5/8 (40/20/10/8/5 groups). Supplying 40 anatomical slices to the same
engine left .00698–.06439. At TR 2 s the error was worse: true group timing
left .00074–.00112, while the anatomical-slice interpretation reached .325.
FASTR therefore needs actual acquisition-group timing (BIDS `SliceTiming`,
sequence metadata or an explicit array), not anatomical slice count.

#### Recorded rate versus internal upsampling

At TR 3 s the compact sampling-rate sweep compared 20, 100 and 200 volumes.
Factors were chosen to put low-rate recordings near a 2–2.5 kHz internal grid,
while 5 kHz stayed at 1×:

| recorded rate / factor | 20 volumes | 100 volumes | 200 volumes |
|---|---:|---:|---:|
| 250 Hz / 10× | .00505 | .000521 | .000465 |
| 500 Hz / 5× | .00769 | .000729 | .000321 |
| 1 kHz / 2× | .01704 | .000648 | .000460 |
| 2 kHz / 1× | .02752 | .000469 | .000161 |
| 5 kHz / 1× | .01261 | .000356 | .000108 |

There is no separate minimum-TR rule emerging for each recorded rate: the
dominant knee is still donor count, near 100–200 volumes in this experiment.
Nor are equal effective rates interchangeable; interpolation phase and epoch
geometry matter. On the same 40-volume, 500 Hz recording, 1/2/5/10× left
.00541/.00560/.00256/.00129 residual while runtime rose
.32/.77/3.78/14.12 s. Thus 5× captures most of the useful gain; 10× roughly
halves the remaining artifact at almost four times the 5× runtime. On
artifact-only **volume** epochs, 1/2/4/5/10× left
.397/.118/.0515/.0328/.0207, confirming that upsampling itself helps volume
subtraction. The earlier full-EEG 5× volume regression was therefore an
interaction with template/brain handling, not evidence that interpolation
cannot represent the artifact.

#### Slice count exposed a timing-grid/alignment defect

Slice performance is not monotonic in slice count. Examples at ten minutes are
TR 1 s / 45 slices = .02634 while 20, 32, 40 and 50 slices are approximately
.00028–.00046; TR 2 s / 30 and 32 slices = .05955 and .02219 while 20, 40 and
50 slices are approximately .00029–.00035; TR 3 s / 45 slices = .05957 while
the other requested counts are approximately .00031–.00033. Extra data does
not remove these failures.

The requested high-rate-grid experiment confirms a real rounding defect. At
120 seconds, constructing nominal slice positions before the final high-rate
rounding changed TR 1 s / 45 slices / 5× from .02677 to .000596, TR 2 s / 30
slices / 5× from .06092 to .00131, TR 2.75 s / 40 slices / 5× from .08522 to
.00250, and TR 3 s / 45 slices / 5× from .06245 to .00241. Supplying the
simulator's exact slice positions gave similar or slightly better results.

The apparent second defect was an evaluation confound. The timing-oracle
harness above used integer-only alignment; its residuals match the integer-only
rows in the confirmation run. Repeating the five formerly failing geometries
for 120 s with exact positions **and fractional alignment** reduced every case
below .00055: TR 2 s / 30 slices / 10× fell .000798 → .000158, TR 2 s / 32
slices / 5× .001345 → .000274, TR 2.25 s / 40 slices / 10× .001037 → .000154,
TR 2.5 s / 40 slices / 5× .001793 → .000380, and TR 3 s / 45 slices / 10×
.001276 → .000262. Raw rows:
`data/gradient-calibration/eva-fastr-recommend-duration-confirmation.csv`.

The 60 s stage isolation explains why. Rounded slice positions can make the
integer aligner choose p90 shifts of 3–10 high-rate samples and can make the
residual *worse* than no alignment. Exact timing collapses that to 0–1 sample;
the fractional stage then lowers the residual another 3–8×. For example, TR 2
s / 30 slices / 10× moved from .12094 (rounded, fractional) to .000391 (exact,
fractional); TR 3 s / 45 slices / 10× moved .12069 → .00121. Drift-tracked
scaling consistently beat unscaled templates. The engine fix begins by
representing supplied or rational acquisition positions on the upsampled grid.
Whether alignment should then run depends on synchronization; the slaved-clock
confirmation below supersedes a universal “fractional alignment on” rule.
Widening the Lanczos kernel is not the first-line fix.

#### Scanner-slaved confirmation: group count is enough for uniform timing

A focused zero-clock-drift experiment treated each EGI volume marker as the
anchor for one repeated, uniformly spaced acquisition-group schedule. Forty
anatomical slices were tested as single-band and MB 4/8 (40/10/5 acquisition
groups), at TR 0.5/2/3 s and 500/1000 Hz. Supplying total slices plus multiband
factor is therefore sufficient for this common case; an explicit timing array
is needed only for a nonuniform schedule.

Once exact group positions were used, **no alignment was the appropriate
slaved-clock default**. At 1 kHz, no alignment and the ±1-internal-sample
integer search were identical in all nine geometries. Fractional refinement
increased residual 1.4–7.2×, albeit from already small baselines. At 500 Hz,
the integer search helped two single-band geometries and was otherwise a no-op;
fractional refinement never beat integer-only. A gate based on increased epoch
correlation selected fractional alignment in every case, including those where
subtraction worsened, so correlation improvement is not a sufficient safety
gate. Raw rows:
`data/gradient-calibration/eva-fastr-slaved-alignment.csv`.

Recommended profiles are consequently:

- scanner-slaved + known schedule: no alignment by default; optional ±1
  internal-sample integer diagnostic/correction;
- unsynchronised or demonstrably drifting clocks: bounded integer plus
  fractional alignment;
- unexpectedly large shifts in the slaved profile: warn about incorrect
  acquisition metadata or synchronization rather than silently following them.

#### More donors plateau only for a stationary artifact

The ten-minute window sweep separates recording length from donor locality. On
the stationary simulation, widening the correlation search from ±8 to ±240
same-slice volumes improved residual monotonically, .00332 → .000206. With a
single gain regime change, the optimum was ±16–32 (.00087); ±120–240 was more
than twice as bad. With phase changes, the knee was approximately ±64
(.000919), after which it was flat. With combined gain and phase changes, ±16
was best globally (.00250) and in the worst quarter (.00927); ±64 degraded to
.00694 globally and .02751 in the worst quarter.

Thus “ten minutes” is useful coverage, not a reason to use all ten minutes as
one donor pool. About 100–200 usable volumes remains a good stationary
evaluation target, but production selection should be regime-local or adaptive
to motion/phase/gain changes. A fixed ±240-volume window is not a safe default.

#### Brain-safety bound tightened: evaluate SNR and ERP transfer shape

Paired-signal tests subtract the corrected no-signal baseline from the
corrected signal-present run. Non-TR-locked transients were retained reasonably
in artifact-present runs (r .93–.95, beta .99–1.03), although clean-only runs
show donor-switching sensitivity. A deliberately repeated 1.5 s ERP is the
important counterexample: slice temporal donors retained r .84 / beta .76,
whereas plain correlation ranking retained only r .31–.33 / beta .12–.13 and
same-slice/squared variants could nearly erase it. This makes the earlier
artifact-only correlation results an upper bound on removal, not a candidate
default. The artifact-present confidence gate and independent brain-safety
acceptance test remain required.

Finally, the existing 8-lobe delay round-trip is effectively transparent below
0.3 cycles/sample, reaches relative MSE .0021 at 0.4 cycles/sample for a
half-sample round trip, and rises to .139 at 0.45 cycles/sample. That localizes
the wider-kernel opportunity to near-Nyquist content and supports evaluating
estimation and application kernels separately rather than widening every slice
path.

The follow-up ERP sweep used exact acquisition timing and compared temporal
versus correlation-ranked slice donors. For a 1.5 s ERP exactly locked to half
of the 3 s TR, correlation ranking retained only 18–20% of amplitude across
representative P50, N100, N170, P200, N200, P300, N400 and P600 shapes. Shape
correlation was often deceptively high (.87–1.00), while the corrected-average
SNR (12.2–13.3 dB) was approximately the no-ERP false-positive SNR
(12.28 dB). In other words, the apparent ERP-sized feature was mostly the
background/residual after the real ERP had been removed.

| shape | temporal beta, locked | correlation beta, locked | correlation beta, detuned + jittered |
|---|---:|---:|---:|
| P50 | 1.087 | .198 | 1.003 |
| N100 | 1.089 | .190 | 1.023 |
| N170 | 1.033 | .186 | 1.029 |
| P200 | .996 | .180 | 1.032 |
| N200 | .916 | .191 | 1.038 |
| P300 | .692 | .180 | 1.046 |
| N400 | .574 | .182 | 1.047 |
| P600 | .455 | .180 | 1.063 |

Detuning the schedule to 1.47 s and adding onset/latency/amplitude jitter
largely protected correlation-ranked ERPs (beta 1.00–1.06), but that does not
make the method safe: real paradigms can be scanner-synchronised. Temporal
donors avoided the comb-like erasure but increasingly attenuated and narrowed
broad late components: locked beta fell from about 1.09 for P50/N100 to .69,
.57 and .45 for P300/N400/P600. The P600 retained only .62 of absolute area.
Raw component rows:
`data/gradient-calibration/eva-fastr-recommend-erp-components.csv`.

Real-data validation should therefore report at least (1) corrected ERP SNR,
(2) the same-window false-positive SNR from trigger-matched no-event or
permuted averages, (3) amplitude transfer/beta, (4) peak latency, (5)
half-height width and (6) signed/absolute area. A high waveform correlation is
not sufficient. Early narrow peaks need sample-level latency and peak checks;
broad P300/N400/P600-like responses need area and width checks because they can
retain a recognisable outline while losing most of their effect size.

The slaved-clock phase sweep tested exact TR, half-TR, third-TR and two-thirds-TR
schedules plus graded jitter/detuning at 500 and 1000 Hz. Correlation-ranked
templates retained approximately zero ERP amplitude for every exact low-order
relationship. Using the maximum circular concentration over the first four TR
harmonics, concentration ≥ .8 bounded the measured retained beta to ≤ .33.
This supports a high-confidence **Watch** pill for strongly phase-concentrated
event codes. It is not a safe/un-safe classifier: lower concentration still
allowed 15–32% attenuation in some deterministic schedules. The pill should
therefore describe demonstrated risk, not promise that an unflagged design is
protected. Raw rows:
`data/gradient-calibration/eva-fastr-slaved-erp-phase.csv`.

The Watch can offer a useful next action rather than only an alarm: **compare
with temporal-neighbour donors** and show the two corrected ERP averages side by
side. In this phase sweep, temporal donors retained beta approximately 1.00–1.22
where correlation-ranked donors were near zero for exact low-order TR
relationships. That is evidence for a diagnostic rerun, not an automatic winner:
other simulations found temporal donors can still attenuate or amplify a broad
late component. The comparison should therefore report peak/area retention
between the two corrected averages, waveform correlation, and the gradient
residual/SNR trade-off. For data collection that has not yet occurred, jittering
event-to-TR phase remains the stronger remedy; software cannot reconstruct an
ERP already absorbed into an artifact template with certainty.

#### Simulator coverage and recommended extensions

The simulator can already express every named component in this follow-up.
`ERPConfig.components` accepts any number of explicitly placed components with
independent source position/orientation, latency, width, Gaussian, biphasic or
measured waveform, target/standard amplitude ratio, latency jitter and
amplitude jitter. The shipped scenarios include bilateral N100 and an oddball
N100 + P300 complex. P50, N170, P200/N200, N400 and P600 are currently
constructible parameters, not validated named presets.

Recommended simulator work, in priority order:

1. Add provenance-backed JSON ERP-complex presets with ranges rather than a
   hard-coded physiological enum: auditory P50/N1/P2/N2, visual P1/N170/P2,
   oddball N1/P2/N2/P3a/P3b, semantic N400 and late P600 complexes.
2. Allow component-by-condition latency, amplitude, source/topography and more
   than the current target/standard contrast. Add correlated component jitter,
   trial-to-trial covariance and subject-level hierarchical variation.
3. Model habituation, refractory/sequence effects and overlapping responses;
   the present components sum linearly and share one trial schedule.
4. Add explicit acquisition groups, multiband factor, arbitrary/interleaved
   slice-timing arrays and generic JSON timing import to the gradient model
   (accept BIDS-style `SliceTiming` later, but do not require a BIDS dataset).
   Manual total-slices + multiband-factor input and JSON timing import are the
   first iteration. Best-effort NIfTI header/extension import is a second
   iteration: preview the inferred groups and require confirmation when the
   header does not resolve multiband timing.
5. Add nonstationary artifact regimes (motion-driven phase/gain steps,
   time-varying clock drift and group-specific waveforms) rather than relying
   only on one smoothly modulated rank-one template.
6. Generate one high-rate master recording and anti-aliased decimations for
   sampling-rate comparisons, and emit per-component event-average/topography
   truth plus the SNR/shape metrics above.

Implementation note (2026-09-27): recommendation 4's first iteration is now in
the FASTR-family engine and UI. Uniform group positions are rounded only after
projection onto the internal upsampled grid; users can supply total slices plus
multiband factor, a direct group count, or JSON offsets in seconds/fractions of
TR. The scanner-slaved profile uses a ±1 internal-grid integer search and turns
fractional alignment off. NIfTI inference and the ERP-phase Watch remain later
iterations.

### Remaining limitation

The simulator supplies clean truth; a real corrected recording does not.
TR-locked residual and removed variance can identify many artifact failures but
cannot, by themselves, distinguish correctly removed artifact from
trigger-correlated brain. The clean-signal acceptance test is therefore a
development gate, not a new run-grade metric.

## ICA (`ICARunGrade`)

### What is graded

1. **Removed components** — the largest ICLabel Brain probability among the
   removed components: Poor ≥ 0.5 (ICLabel reads it as brain), Watch ≥ 0.25.
   Without probabilities (heuristic labeller, headless replay) a removed
   component *labelled* Brain is Watch. **A convention, not a measurement** —
   ICLabel labels synthetic sources unreliably (the W-ICA fixture had it call
   the ocular source Muscle), so it cannot be calibrated on this simulator.
2. **Data per component** — κ = analysis samples / components². Watch below
   20. The weak-source follow-up below supports this as a measured Watch
   boundary, consistent with the Onton & Makeig 2006 rule of thumb.

Reported, not graded: convergence (iterations vs the cap) and removed variance.

### Campaign

The first campaign ran EVA's Picard at 125 Hz on seeded dipole EEG with bursty
sources and 16 blinks/min: 20 and 32 channels, κ ≈ 4–150 and 3 seeds. It used a
100 µV blink. The source count was set to n − 4 so brain plus ocular sources
fill the rank of average-referenced data — at the simulator's default of 7
sources, PCA trims every decomposition to the true rank and every run is
data-rich, which is the first attempt's (discarded) result.

The 2026-09-28 follow-up held the 20-channel geometry fixed and crossed four
requested data volumes (realized κ means ≈ 11, 19–21, 37–43 and 74–86), three
neural-source regimes (Gaussian; modestly super-Gaussian, mean excess kurtosis
about 4–10; strongly bursty), 10/30/100 µV blinks, and five seeds: 180 fits.
The removed component was chosen by **oracle** (best correlation with the true
ocular signal), so both campaigns measure decomposition quality rather than
classification. Raw rows are in
`data/ica-calibration/eva-ica-run-grade.csv`; the formatted table and grouped
means are in `eva-ica-run-grade.txt` beside it.

### Findings

- **κ matters for a weak source.** For the 10 µV blink, mean removal in the
  Gaussian-background control rose from 0.023 at realized κ ≈ 11 to 0.571 at
  κ ≈ 19 and 0.664 at κ ≈ 37; the modestly super-Gaussian background rose from
  0.376 to 0.643 and 0.681. Results plateaued above the current boundary. The
  exact numbers include occasional negative removal at low κ, meaning the
  selected component made ocular error worse rather than correcting it.
- **Strong sources remain easy.** Across source regimes the 30 µV blink stayed
  near 0.73–0.77 removal and the 100 µV blink near 0.77–0.78 from the smallest
  through largest data volume. This reproduces the original campaign's null
  result and explains it: a large, strongly non-Gaussian artifact does not need
  20 × n² samples to be identifiable.
- **Keep Watch below 20, with no Poor band.** The current boundary separates the
  unstable weak-source regime from the plateau and is consistent with the
  published convention. The failure is a risk of missing or poorly isolating a
  weak source, not evidence that every low-κ removal destroys brain; refusal or
  a Poor grade would overstate the result.
- **Convergence still did not predict quality.** Within matched durations,
  converged and capped fits had similar removal and brain-loss means. Strongly
  bursty backgrounds frequently reached the 200-iteration cap without worse
  truth scores, so the cap remains reported rather than graded.
- **Oracle removal of one component takes 0.64–0.80 of the ocular artifact and
  removes brain worth 0.06–0.37 of the brain's variance.** The eye model spans
  more than one dimension; a single-component removal is a partial correction
  even when the decomposition is right.

### Not measured

ICLabel accuracy on real data (which is where the Removed-components band
actually does its work); weak non-ocular sources such as muscle, cardiac and
residual BCG. The measured weak-blink result supports the generic data-volume
Watch, but does not claim those source families have identical behavior.

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

Two campaigns use the same truth metrics: `err = var(· − clean) /
var(clean)`; brain lost = the part of each change that was not artifact, inside
touched samples.

1. **Oracle cleaner campaign:** true blink onsets (0.8 s windows) at 3–100
   blinks/min; OBS (2 components), MAS, per-event wavelet; 20 channels, 250 Hz,
   120 s, 2 seeds.
2. **Real-detection campaign (2026-09-28):** the noisy signal went through the
   production `EyeArtifactThresholdDetector`, and only its peak-anchored events
   were passed to OBS, SSP/PCA, MAS and per-event wavelet. The 144 cleaner
   evaluations crossed 0/3/10/20/50/100 blinks/min, two seeds, and three
   amplitude/threshold conditions: 100 µV blinks with 50 and 150 µV detector
   thresholds, plus 200 µV blinks with the shipped 150 µV threshold. Signals
   were 20-channel 10-20, 250 Hz, 60 s. A detection matched truth when its peak
   was within 250 ms of the simulated blink peak (~onset + 120 ms).

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

Real detector performance, pooled across nonzero-density runs (clean false
events are the mean count in a 60 s zero-blink control):

| blink / threshold | precision | recall | clean false events |
|---|---:|---:|---:|
| 100 / 150 µV (shipped) | 1.000 | 0.018 | 0.0 |
| 200 / 150 µV (shipped) | 1.000 | 0.809 | 0.0 |
| 100 / 50 µV (sensitive) | 0.737 | 0.996 | 17.5 |

The 50 µV clean controls crossed the touched Watch boundary and created
brain-normalized error despite having no artifact to remove:

| method | touched | error after |
|---|---:|---:|
| OBS | 0.257 | 0.357 |
| SSP/PCA | 0.257 | 0.557 |
| MAS | 0.215 | 0.123 |
| Wavelet | 0.215 | 0.141 |

Raw rows are in
`data/artifact-clean-calibration/eva-artifact-clean-run-grade.csv`; grouped
means are in `eva-artifact-clean-run-grade.txt` beside it.

### Findings

- **Cleaning beats keeping the artifact only when its events are sufficiently
  real.** Oracle events gave the original 4–8× gains. With the precise 200 /
  150 µV detector, gains were 2.35–19.4× across methods and densities. With
  the sensitive detector, false positives made sparse cleaning worse than the
  dirty signal (minimum gains: OBS 0.21, SSP/PCA 0.11, MAS 0.38, wavelet 0.52)
  and damaged clean controls.
- **The residual error is almost all brain distortion, and it scales with the
  touched fraction:** inside rewritten windows ~30 % (OBS, MAS) to ~50 %
  (wavelet) of the brain's variance is distorted. On the same truth scale as the
  gradient grade (error < 0.1 of brain variance = good), the error crosses 0.1
  at 20–35 % touched depending on method → **Watch from 20 %**, the
  method-agnostic lower edge. The real-detection clean controls validate that
  warning as an exposure / false-positive caution. Tested clean-control harm
  stayed below the ≥ 1 "poor" truth line, so there is still no supported Poor
  band.
- **Keep Watch below 20 events for OBS/SSP, but weaken the claim.** In the
  oracle campaign ~6 weak events gave OBS only 1.1× gain while ~20 gave 4×.
  Real detection showed that strong, pure events can work below 20, while 20+
  impure events can fail. Event count measures estimator support, not event
  purity, so the boundary is a conservative caution rather than a guarantee.
- **Touched fraction is not a detector-quality metric.** The shipped 150 µV
  setting was precise, but its recall changed from 0.018 at 100 µV to 0.809 at
  200 µV. At 100 µV the cleaner touched almost nothing while leaving almost
  all artifact behind. The pill must therefore describe repair exposure, not
  successful detection or residual cleanliness.

### Not measured

Detector precision/recall on EOG- or manually labelled real recordings; other
detector configurations, net geometries and artifact families; regression; the
MAAC continuous methods (deferred). The synthetic threshold contrast exposes
the precision/recall tradeoff but does not establish a universal ocular
threshold for human recordings.

## MAAC — deferred

Not graded yet, by owner decision (2026-09-26): MAAC adoption itself is not
settled, so its run grades wait with it. The bands the ROADMAP proposed — gamma
preservation for BSS-CCA muscle correction, and a movement-PCA equivalent — need
their own campaigns. Until then, a cleaning run that includes a continuous MAAC
method reports its touched fraction without grading it.
