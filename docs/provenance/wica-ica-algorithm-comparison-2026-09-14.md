# W-ICA ICA algorithm comparison — 2026-09-14

This is the paired follow-up to the first
[W-ICA campaign](wica-campaign-2026-09-14.md). It asks whether the ICA solver,
rather than the subsequent reconstruction policy, is responsible for the long
fixture runtime or changes cleaning quality.

## Invocation

```bash
scripts/compare-wica-ica-algorithms.sh
```

The run completed 90 ICA fits (10 seeds × blink, EMG, and electrode-pop
fixtures × Picard, Picard-O, and FastICA) with no failures in 1,180 seconds.
Each algorithm received the same samples and configuration: medium artifact
severity, 20 channels, 20 requested components, 100 Hz fit data, a 0.99999 PCA
variance target, a `1e-7` convergence tolerance, and a 250-iteration cap. The
raw per-arm table and generated summary are
`.wica-campaign/eva-wica-ica-algorithms.{csv,md}`.

## Results

| Artifact | FastICA | Picard | Picard-O | Picard / FastICA | Picard-O / FastICA |
| --- | ---: | ---: | ---: | ---: | ---: |
| Blink | 0.186 s | 2.021 s | 7.401 s | 10.9× | 39.8× |
| EMG | 0.364 s | 2.500 s | 8.137 s | 6.9× | 22.4× |
| Electrode pop | 0.235 s | 1.953 s | 7.240 s | 8.3× | 30.9× |
| Pooled | 0.261 s | 2.158 s | 7.593 s | 8.3× | 29.0× |

FastICA and Picard-O target the same orthogonally constrained problem and were
effectively equivalent here. Their mean absolute difference in artifact
reduction across every matched reconstruction arm was 0.000434. Their pooled
oracle-rejection reductions were 0.775425 and 0.775426, respectively. The
truth-ranked artifact concentration was also the same to the reported
precision: approximately 0.999 for blink, 0.619 for EMG, and 1.000 for pop.

Plain Picard solves the unconstrained maximum-likelihood problem, so a different
component geometry is expected. Its pooled oracle-rejection result remained
essentially the same (0.776168), but individual ICLabel-driven arms could change
because ICLabel saw a different component basis. Pooled ICLabel artifact-energy
recall was 0.329 for Picard, 0.369 for FastICA, and 0.368 for Picard-O. These
small synthetic results do not establish one classifier-compatible basis as
better; they show that automatic routing must be calibrated for the selected
ICA family.

FastICA reached the iteration cap in 11 of 30 fits, compared with 24 of 30 for
both Picard variants. A cap hit is not automatically a failed fit: capped
FastICA solutions still matched Picard-O's artifact concentration and cleaning
scores. Also, `finalChange` is algorithm-specific (a fixed-point change for
FastICA and a gradient norm for Picard/Picard-O), so its absolute values should
not be compared across algorithms as though they were the same statistic.

All three methods isolated electrode pops almost perfectly by simulator truth,
yet ICLabel recall for pops was effectively zero. The solver is therefore not
the pop-routing bottleneck.

## Decision

Use FastICA as the default solver for the fixture-only W-ICA campaign. Keep
Picard-O as the orthogonal reference/fallback and plain Picard as an alternate
basis for classifier-robustness checks. Do not change EVA's general ICA default
from this synthetic, 20-channel experiment alone; first repeat the comparison
on representative real recordings, higher-density montages, and deliberately
mixed artifact/brain components.

The next campaign should focus on ICLabel/class-specific routing—especially
Channel Noise/electrode pops—and mixed-component hard rejection versus wavelet
shrinkage. Solver changes alone did not improve that limitation.
