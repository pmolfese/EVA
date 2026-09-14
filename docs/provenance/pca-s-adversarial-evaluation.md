# PCA-S Adversarial Evaluation (SI-4, Track 2)

Measured-results record for the source-informed BCG correction (PCA-S) adversarial
campaign. This is evidence, not a specification, and not a change to shipped
defaults — Track 3 (turning these numbers into refusal/warning thresholds) is a
separate, later step. The companion user-facing summary lives in the simulator
manual page (`docs/manual/tools/eva-simulate.md`, "Operating envelope of PCA-S").

- **Date:** 2026-09-12
- **Harness:** `Tools/EVASimulate` `evaluate-surrogate-grid`, rebuilt from source
  the same day (the committed `.build/eva-simulate` was stale — a known trap;
  the binary was rebuilt via `xcodebuild -scheme EVASimulate -configuration
  Release` and re-installed before running). Self-test 107/107.
- **Raw CSVs:** `docs/provenance/data/pca-s-si4/` — one per axis, plus
  `max-beats_paper.csv` for the paper-mode contrast arm.
- **Seeds:** 30 realizations per grid point (the harness warns that a difference
  smaller than the standard deviation is not a result; SDs are reported below).

## The metric

`corrected SNR` and `uncorrected SNR` are `sqrt(signal power / residual power)`
against the average-referenced clean truth, so **higher is better and the bar to
clear is the uncorrected column** — a correction that leaves corrected below
uncorrected has actively hurt. `clean distortion (dB)`, `removed variance`, and
`accepted-beat fraction` are the supporting diagnostics; removed-variance above
~1.0 means the operator subtracted more energy than the artifact carried, which
is a distortion signature, not a quality signature.

## The most important finding: mode, not a sign error

An early probe showed PCA-S making SNR **worse** at the harness defaults. That is
**not** an operator-direction (sign/flip) bug. The `SourceInformedSeparation`
operator reconstructs the brain subspace (`M = B (PᵀP + λI)⁻¹ Pᵀ`, `P =
(I − AAᵀ)B`); the identical operator delivers a large *improvement* the moment it
is fed good artifact topographies. The failure was upstream, in artifact-topography
estimation, and it is entirely explained by the **pattern-search mode**:

- **The shipped app defaults to `.iterative`** (`BCGSurrogateCorrection.swift:140`;
  `BCGSurrogateTopographies.swift:46` states iterative "is what EVA offers by
  default" and `.paper` "is retained exactly so a methods comparison" is possible).
- **At the time of the campaign the `evaluate-surrogate` /
  `evaluate-surrogate-grid` harness defaulted to `--pattern-search paper`.** Paper
  mode accepts a small fraction of beats at these settings (≈4% at 20 ch / 250 Hz)
  and its topographies point partly at brain, so the operator projects out brain
  directions and corrected SNR falls below uncorrected across the board.

**Consequence:** the campaign was run with an explicit `--pattern-search iterative`
to measure the envelope of the mode EVA actually ships. Paper mode is reported only
as a labeled contrast arm and must not seed any guardrail. The paper-mode contrast
(`max-beats_paper.csv`) never beats uncorrected at any beat count (0.94–1.06 vs
~1.25).

**Follow-up (2026-09-13):** the harness default was then changed to `iterative` at
all three sites (`correct`, `evaluate-surrogate`, `evaluate-surrogate-grid`) and the
help text expanded, so future sweeps measure the shipped mode by default and only an
explicit `--pattern-search paper` selects the comparison arm. The self-test always
passes the mode explicitly, so it was unaffected (107/107).

## Baseline (iterative, matched head, defaults)

20 ch, 250 Hz, 180 s, 29 brain sources, 4 artifact components, brain
regularization 0.02, BCG morphology jitter 0.20 (the `SimulationConfig` default):

> corrected **2.08 ± 0.76** vs uncorrected **1.26** — about a 1.65× SNR gain.

The spread is load-bearing: SD ≈ 0.76 is ~half the mean gain, so the
corrected-minus-uncorrected margin is on the order of a single standard deviation.
This is the operating point every single-axis sweep below perturbs from.

## Results by axis (iterative, 30 seeds)

Breakpoint = where corrected stops reliably beating uncorrected, or removed
variance climbs toward/over 1.0.

### Accepted-beat count — dominant driver (breakpoint)

`--axis max-beats` caps the candidate beats used to build the artifact
topographies. Corrected SNR scales with beat count and is **below uncorrected for
every cap ≤ 30**:

| max-beats | corrected | uncorrected | beats kept | removed var |
|---:|---|---|---:|---:|
| 2 | 0.95 ± 0.05 | 1.26 | 100% | 0.97 |
| 10 | 0.99 ± 0.06 | 1.26 | 49% | 0.94 |
| 30 | 1.03 ± 0.07 | 1.26 | 34% (~10 beats) | 0.91 |
| 50 | 1.26 ± 0.27 | 1.26 | 45% (~22 beats) | 0.78 |
| 100 | 1.82 ± 0.67 | 1.26 | 44% (~44 beats) | 0.62 |

**Reliable benefit needs ~40+ accepted beats.** The shipped
`minimumAcceptedBeats = 10` gate sits inside the hurting regime (max-beats 30 ≈ 10
accepted beats still gives 1.03 < 1.26). This is the clearest Track-3 signal: the
minimum-beat gate is optimistic and should be recalibrated upward. Caveat: this
axis caps beats *artificially*; in a real recording beat count scales with
duration, so the practical control is a minimum recording length / minimum
accepted-beat count, not an isolated cap.

### Duration (breakpoint <~60 s)

| duration (s) | corrected | uncorrected |
|---:|---|---|
| 30 | 1.20 ± 0.23 | 1.11 |
| 60 | 1.39 ± 0.47 | 1.17 |
| 120 | 2.02 ± 0.67 | 1.22 |
| 300 | 2.36 ± 0.63 | 1.26 |

Same mechanism as beat count (more time = more beats). Below ~60 s the margin is
within one SD and not a result.

### BCG morphology jitter — the physiological breakpoint

`--axis bcg-morphology-jitter` injects beat-to-beat morphology variability. As it
rises, beat acceptance collapses and the correction **crosses below uncorrected at
~0.4**:

| jitter | corrected | uncorrected | beats kept |
|---:|---|---|---:|
| 0.0 | 2.72 ± 0.76 | 0.99 | 68% |
| 0.1 | 2.59 ± 0.81 | 1.09 | 56% |
| 0.2 *(default)* | 2.08 ± 0.76 | 1.26 | 39% |
| 0.4 | 1.51 ± 0.44 | 1.55 | 18% |
| 0.8 | 1.18 ± 0.22 | 1.95 | 8% |

This is the axis that most directly represents the real-world variance PCA-S is
exposed to, and it is the one most likely to break it. The `SimulationConfig`
default (0.20) sits comfortably in the safe zone; the failure begins at 2× that.
(The uncorrected SNR *rises* with jitter because heavy morphology variation makes
the artifact more noise-like and less coherent.)

### Electrode/montage mismatch (breakpoint ~10°)

`--axis correction-electrode-jitter` builds the brain basis on a jittered montage
while truth stays on the real one:

| jitter (deg) | corrected | uncorrected | removed var |
|---:|---|---|---:|
| 0 | 2.08 ± 0.76 | 1.26 | 0.57 |
| 5 | 1.62 ± 0.59 | 1.26 | 0.68 |
| 10 | 1.12 ± 0.21 | 1.26 | 0.90 |
| 15 | 1.12 ± 0.26 | 1.26 | 0.91 |

Safe to ~5° (typical digitization error), broken by ~10°. **There is no guard for
this today** — a Track-3 candidate (an ill-conditioning / co-registration check).

### Artifact components — non-monotone, optimum ~3

| components | corrected | removed var |
|---:|---|---:|
| 1 | 1.83 ± 0.12 | 0.33 |
| 3 | 2.38 ± 0.45 | 0.47 |
| 4 *(default)* | 2.08 ± 0.76 | 0.57 |
| 6 | 1.42 ± 0.41 | 0.73 |
| 8 | 1.42 ± 0.41 | 0.73 |

An overcomplete artifact dictionary removes brain signal. The peak is ~3; the
shipped default of 4 is slightly past it and still positive. Worth revisiting the
default, but not a failure.

### Robust axes (no breakpoint in range)

| Axis | Range | Behavior |
|---|---|---|
| Channels | 20 → 256 | 2.0–2.5×, distortion *falls* with more channels (14.3→12.0 dB). No montage-specific failure on the built-in montage → **real HydroCel 128/256 authoring stays deferred**, as the ROADMAP anticipated. |
| Sampling rate | 250 / 512 / 1024 | Identical SNR; higher rate only lowers distortion. |
| Brain sources | 9 → 69 | Plateau at ~29 (the default); diminishing returns above. |
| Basis offset | 0 → 20 mm | Graceful (2.08 → 1.97). |
| Skull-conductivity ratio | 1:20 → 1:160 | Graceful (2.21 → 1.99); confirms the earlier head-mismatch finding. |
| Scalp radius | 0.08 → 0.11 m | No effect (normalized topographies absorb the scale). |
| Brain regularization | 0.002 → 0.2 | Flat-to-slightly-better; robust. Default 0.02 is fine. |

## Component-reliability gate (0.9) — measured and confirmed (2026-09-13)

The campaign harness does not run the app's split-half reliability gate, so
`minimumComponentReliability = 0.9` was recalibrated separately, in-app, by
`EVATests/Cardiac/BCGSurrogateCorrectionTests.reliabilityGateSeparatesArtifactFromBrain`.
The test builds a rank-3 artifact from three known orthonormal spatial patterns
plus a separate (non-beat-locked) brain signal, opens the gate to 0 to keep every
component, then scores each component's split-half reliability against its energy
overlap with the true artifact subspace — sweeping artifact amplitude from
artifact-dominated to brain-dominated so brain leaks in as its own components.

| Artifact amplitude | true-artifact reliability (overlap > 0.7) | brain-leakage reliability (overlap < 0.3) |
|---|---|---|
| 55 µV | 0.999–1.000 | (no brain component appears) |
| 15 µV | 0.982–0.999 | 0.490 |
| 6 µV (brain-dominated) | 0.956–0.996 | 0.567, 0.737, 0.790 |

**Finding: 0.9 is well-placed — keep it.** In every regime where both kinds of
component appear, true-artifact components score ≥ 0.956 and brain-leakage
components score ≤ 0.790, so 0.9 sits in the separating gap: it keeps the artifact
and rejects the brain. The gap narrows as the artifact weakens (0.956 vs 0.790 at
6 µV) but never closes; 0.9 leaves ~0.06 of headroom against dropping a real
component and ~0.11 against keeping a brain one. Lowering it toward 0.8 would start
admitting brain leakage; there is no measured reason to move it. The test asserts
this separation and remains as a regression guard.

## Ill-conditioning guard — measured and rejected (2026-09-13)

The ROADMAP proposed an ill-conditioning guard "only if the sweeps show it
matters." To test that, `evaluate-surrogate-grid` was extended to emit a
conditioning indicator (`condition_indicator_mean`): the squared ratio of the
largest to smallest Cholesky pivot of the regularized brain system `PᵀP + λI`, a
lower bound on its true condition number and a number the shipped operator already
computes. The electrode-jitter axis (the failure a conditioning guard would target)
was run against it, and repeated at three regularizations.

| λ | condition 0° → 15° | corrected SNR @ 10° (uncorrected 1.26) | removed variance @ 10° |
|---|---|---|---|
| 0.002 | 683 → 850 | 0.95 (hurts) | 1.10 |
| 0.02 *(shipped)* | 70 → 87 | 1.13 (hurts) | 0.88 |
| 0.2 | 8 → 10 | 1.46 (still helps) | 0.72 |

**Finding: the condition number does not discriminate this failure — do not add
the guard.** Two reasons: (1) its absolute value is set by the ridge λ (≈10× per
10× of λ), not by the mismatch, so no fixed threshold is meaningful; (2) the
*relative* rise from 0° to a broken 15° is only ~1.24× at every λ — at the shipped
λ=0.02 the still-helping 5° point (cond ≈ 81) and the broken 10° point (cond ≈ 87)
differ by ~7%, far too little to gate on. The ridge keeps the system
well-conditioned *by design*, so the electrode-mismatch failure is geometry
mismatch, not ill-conditioning, and a condition number is blind to it. (Higher λ
even improves mismatch tolerance while lowering the condition number — the opposite
of the guard's premise.)

**What does track it: removed variance.** Across all three λ, removed variance
climbs from ~0.57 toward or past 1.0 exactly as the correction breaks
(0.57 → 0.88 → 1.10 at λ=0.02/0.002). So the removed-variance band already in the
recommended set (watch 0.6–1.0, poor ≥ 1.0) *is* the electrode/co-registration
guard; no separate conditioning metric is warranted. The `condition_indicator`
column remains in the grid output as a diagnostic and as the evidence for this
decision. Raw: `data/pca-s-si4/correction-electrode-jitter_cond.csv`.

## Settled gate decisions (with the owner, 2026-09-12/13)

The grade tiers below feed a planned Good/Watch/Poor run-grade (surfaced as a dot
in the history rail); the code constants named are the hard refusals that exist
today. Numbers were agreed with the owner.

1. **`minimumAcceptedBeats`: keep the hard-refuse floor at 10; make 40 the
   good/watch boundary.** Reliable benefit needs ~40+ accepted beats, but that is
   an argument for a *warning*, not a block — raising the refuse to 40 would
   hard-block legitimate short recordings. So 10 stays as the "cannot estimate a
   topography" floor, and 10–40 becomes the watch band.
2. **`minimumComponentReliability`: keep 0.9 — now measured** (see the reliability
   section above). Confirmed to sit in the artifact/brain separating gap; no change.
3. **Removed variance: good < 0.6, watch 0.6–1.0, poor ≥ 1.0.** Campaign-backed,
   and it doubles as the **electrode/co-registration guard** — the condition-number
   guard the ROADMAP hypothesized was measured and rejected (see above), and
   removed variance is what actually tracks that failure.
4. **No condition-number guard.** Measured, does not discriminate at the shipped
   regularization.
5. **Default component count (4) is slightly past the ~3 optimum.** Low priority;
   not changing it now.

## Honest limits of this evidence (the variance caveat)

- Every SD above is **realization noise on a single generator model.** The only
  axis that injects *structural* beat-to-beat variability is morphology jitter —
  and it is the axis that breaks the method. Real BCG carries more that this
  campaign does not: non-stationary morphology over minutes, respiration coupling,
  movement-locked amplitude changes, slow electrode drift, and genuine
  inter-subject topography differences. **This campaign therefore probably
  understates the real-world failure rate**, and the safe zones above should be
  read as necessary, not sufficient, conditions.
- A matched generator/filter result is not robustness evidence on its own; the
  mismatch sweeps (head, montage, offset, morphology) are the parts that carry
  weight, and they are the ones with the largest SDs.
- Removed variance is a report, not proof of quality. Where it climbs toward 1.0
  (electrode jitter ≥ 10°, many components) it is flagging distortion, and that is
  how it is used above — never as a success metric.
