# Evaluating W-ICA

EVA's W-ICA campaign is a gated simulator evaluation, not an ordinary unit
test. It fits ICA once for each synthetic recording, then reuses that exact
decomposition for every cleaning arm. This avoids giving one method a luckier
ICA solution than another and keeps the normal test suite fast.

## Run it

Scientific W-ICA campaigns use 64, 128, and 256 channels. Counts below 64 are
reserved for unit tests and historical smoke results; they are not campaign
evidence. Recordings are 120 seconds long and contain 20 independent dipole
sources by default, providing 12,000 samples at the 100 Hz ICA fit rate.

From the repository root, run the two-seed solver pilot first:

```bash
scripts/compare-wica-ica-algorithms.sh --quick
```

Then run the two-seed baseline and mixed-component pilots:

```bash
scripts/evaluate-wica-campaign.sh --quick
scripts/evaluate-wica-mixed-campaign.sh --quick
```

The full 10-seed baseline and mixed-component campaigns are:

```bash
scripts/evaluate-wica-campaign.sh
scripts/evaluate-wica-mixed-campaign.sh
```

All scripts accept explicit protocol overrides for focused diagnosis:

```bash
scripts/evaluate-wica-campaign.sh --seeds 3 --channels 128,256 --duration 180 --sources 24
```

The solver pilot holds each in-memory fixture fixed across Picard, Picard-O, and
FastICA and reports runtime, iterations, final convergence change, component
count, artifact-energy concentration, ICLabel recall, and downstream
rejection/W-ICA scores. Its outputs are
`.wica-campaign/eva-wica-density-ica-algorithms.{md,csv}`.

The script prints each build/test command before executing it. During the test,
it also prints the equivalent `eva-simulate generate` command for every seed,
artifact, and severity. Results are copied to:

```text
.wica-campaign/eva-wica-density-baseline.md
.wica-campaign/eva-wica-density-baseline.csv
.wica-campaign/eva-wica-density-routing.md
.wica-campaign/eva-wica-density-routing.csv
.wica-campaign/eva-wica-density-mixed.md
.wica-campaign/eva-wica-density-mixed.csv
```

Reports are atomically checkpointed after every fit. The copy into
`.wica-campaign/` occurs when the script completes; during a run, the current
checkpoint lives in EVA's app-container temporary directory.

The campaign calls the simulator models in-process rather than reading the MFF
files produced by those printed commands. That is deliberate: it retains the
exact clean sample matrix and isolated artifact layer needed to identify which
ICA components actually carry artifact energy. The printed commands are useful
for opening a representative fixture in EVA. Electrode-pop severity is the one
exception: `eva-simulate` has a fixed pop amplitude distribution, so the
campaign scales the isolated pop layer by 0.5, 1, or 2 after injection; the
printed command annotates that scale in a shell comment.

## Experimental design

The primary baseline grid is 10 seeds × three channel densities × three
severities × three artifact classes:

| Artifact | Low | Medium | High |
| --- | ---: | ---: | ---: |
| Blink | 50 µV | 100 µV | 200 µV |
| EMG burst | 25 µV | 50 µV | 100 µV |
| Electrode pop | 0.5× | 1× | 2× |

Each 120-second recording contains 64, 128, or 256 average-referenced channels,
20 non-Gaussian dipole sources, and planted brain transients. Above 41 channels,
EVASimulate uses its deterministic evenly spaced synthetic spiral rather than
claiming a commercial montage. Scanner gradient and BCG artifacts are disabled
so the campaign measures one artifact class at a time. ICA requests up to the
channel count, retains the dimensions needed for 99.999% PCA variance, uses
100 Hz analysis data, and runs at most 250 iterations. The first historical
20-channel campaign used Picard-O; subsequent high-density campaigns default to
FastICA. This does not change EVA's general ICA default.

The mixed-component grid uses medium artifact severity and aligns 0.35, 0.65,
or 0.90 of artifact spatial power with a known neural-source topography while
preserving artifact RMS. This deliberately violates the clean spatial
separation that otherwise makes full component rejection an easy winner. It
adds soft-threshold W-ICA and soft-hybrid arms to the ordinary hard-threshold
policies.

Every fitted decomposition is evaluated with these arms:

| Arm | Component policy |
| --- | --- |
| `uncorrected` | No cleaning; establishes zero artifact reduction. |
| `channel-wavelet` | Apply the same wavelet reducer directly to sensor channels. |
| `ica-reject-iclabel` | Reject components classified as Eye, Muscle, Heart, Line Noise, or Channel Noise. |
| `ica-reject-oracle` | Reject the smallest truth-ranked set carrying 90% of projected artifact energy. |
| `wica-all` | Wavelet-clean every component and preserve the rank/PCA residual. |
| `wica-iclabel-t025/t050/t100` | Wavelet-clean only ICLabel artifact components at 0.25×, 0.50×, and 1.00× coefficient gates. |
| `wica-oracle-t025/t050/t100` | Wavelet-clean the truth-ranked 90% artifact-energy set at the same three gates. |
| `hybrid-oracle` | Reject selected components with at least 80% artifact purity; wavelet-clean the remaining selected mixed components at 0.50×. |

The oracle arms are upper bounds for understanding routing, not deployable
algorithms. A large oracle-versus-ICLabel gap means component classification or
selection needs work. If both perform poorly, the wavelet/reconstruction policy
is the likelier limitation.

## Read the scores

- `artifact_reduction`: `1 - corrected MSE / uncorrected MSE` against clean
  truth. One is perfect, zero is no improvement, and negative means cleaning
  made the recording worse.
- `rmse_uv`: pooled corrected-versus-clean error in microvolts; lower is better.
- `transient_preservation`: variance preserved in planted K-complex, spindle,
  and sharp-wave windows; one is ideal and negative values indicate severe
  distortion.
- `label_artifact_energy_recall`: the fraction of simulator-known artifact
  component energy captured by ICLabel's selected set.
- `ica_seconds`, `ica_iterations`, and `ica_final_change`: make algorithm speed
  and convergence regressions visible alongside cleaning quality.

Do not choose a winner from artifact reduction alone. Prefer a method on the
Pareto frontier: better artifact reduction without a material loss of neural
transient preservation. Review results by artifact and severity before pooling;
a policy that is excellent for isolated blinks may be harmful for focal
electrode pops.

The first full campaign and its interpretation are recorded in
[W-ICA campaign — 2026-09-14](../../provenance/wica-campaign-2026-09-14.md).
The paired solver follow-up is recorded in
[W-ICA ICA algorithm comparison — 2026-09-14](../../provenance/wica-ica-algorithm-comparison-2026-09-14.md).
