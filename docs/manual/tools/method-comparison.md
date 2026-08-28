# Method Comparison

`compare-methods.sh` runs every correction method EVA offers over the same
simulated recordings and emits a table saying how each one did — mean ± SD over
several seeds, with the difference between any two methods measured on the
*same* recording.

It answers a different question from the pipeline-regression suite. That suite
asks "is this method still as good as it was?" and answers pass or fail. This
asks "which method is better, and by how much?" and answers with numbers you
could put in a paper.

The comparison is only possible because the recordings are synthetic. On real
data there is no way to know what the clean signal was, so there is nothing to
score against; with [EVA Simulate](eva-simulate.md) generating both the
contaminated recording and its clean twin, every method's residual is measurable
against the same truth.

---

## Running it

```bash
./compare-methods.sh
```

From the repository root. The script builds `eva-simulate` if it is missing,
builds EVA for testing, runs the matrix, and copies the results into
`.comparison/` at the repository root.

The default matrix is nine gradient-correction methods over two scenarios at
five seeds — 90 corrections. Expect several minutes on first run, less after
that: generated recordings are reused, because the generator is deterministic in
its seed.

```bash
EVA_COMPARISON_REGENERATE=1 ./compare-methods.sh   # regenerate the recordings
./compare-methods.sh path/to/my-matrix.json        # run a different matrix
```

!!! note "Why a script rather than a plain test run"
    The harness runs inside EVA's test target, because only code inside the app
    module can drive EVA's own correction methods. The test host is the sandboxed
    EVA app: it can read the repository but cannot write to it, and `eva-simulate`
    inherits that sandbox when the harness launches it. So the run writes into the
    app container, and the script copies the results back out — which is something
    only a process outside the sandbox can do. The script also sets
    `TEST_RUNNER_EVA_COMPARISON=1`, the only way an environment variable reaches
    an xcodebuild test process.

Running the test suite normally does **not** run a comparison. The matrix-validation
tests run in milliseconds and always run; the comparison itself is skipped unless
that variable is set, so a routine `xcodebuild test` stays fast.

---

## What it writes

Into `.comparison/<matrix-name>/`:

| File | What it is |
| --- | --- |
| `comparison_results.md` | The tables, ready to read. Start here. |
| `comparison_results.csv` | Long format: one row per scenario, seed, method, and metric. |
| `comparison_paired.csv` | One row per paired comparison, with intervals. |
| `comparison_results.json` | Everything, including each run's audit lines and per-seed values. |
| `scenario-<id>.json` | The complete resolved configuration each scenario was generated from. |

The CSV is long rather than wide on purpose: a wide table invites comparisons
across a row that was never a comparison, and it has to be reshaped before
plotting or statistics anyway.

`scenario-<id>.json` is the file to keep if you keep only one. It is the scenario
file with every command-line override already applied, so regenerating the exact
recordings later is `eva-simulate generate --config scenario-gradient-locked.json`
— no reconstructing a command line from notes.

---

## Reading the output

### The score table

```
| Method       | Broadband SNR   | RMSE (µV) | Correlation | Seeds | Warnings         |
| No correction| 0.0634 ± 0.0003 | 170.815   | 0.0774      | 5     | —                |
| MAS          | 2.4549 ± 0.0436 | 4.411     | 0.9262      | 5     | —                |
| FASTR        | 0.1300 ± 0.0007 | 83.244    | 0.1478      | 5     | epochOutOfBounds |
```

Broadband SNR is `std(clean) / std(clean − corrected)` — the same definition
`eva-simulate score` uses, and in fact computed by it. The ± is the sample
standard deviation across seeds, and it is absent with one seed, where the spread
is unmeasured rather than zero.

**The `No correction` row is not optional.** A matrix without it is rejected
before anything runs. The same corrected score means something entirely different
depending on whether doing nothing scores 0.06 or 2.8, and a table that leaves
the reader to guess is not a table.

**The Warnings column is what EVA said about its own run**, read back from the
`log_eva_*.txt` in each processed package. This matters more than it looks:
a method that quietly fell back — no motion parameters, too few donors, a
rejected template scale — still emits a perfectly valid recording and a perfectly
plausible score. Without this column the table would report that fallback as the
method's performance. `epochOutOfBounds` on a final epoch is expected, since a
recording ends mid-epoch; anything else means the row may not describe the method
it names, and the full audit lines are in the JSON.

### The paired table

```
| Method − mas | Mean Δ SNR | SD of Δ | 95% CI              | t      |
| MAR          | +0.2772    | 0.0112  | +0.2632 to +0.2911 ✓| 55.27  |
| wAAS         | -0.3055    | 0.0371  | -0.3515 to -0.2594 ✓| -18.42 |
```

Every arm sees the identical recording at a given seed, so this is
`method − reference` computed **within** each seed and then averaged. That
removes recording-to-recording variation instead of averaging over it, and the
spread that remains is usually far smaller than either method's own: in the run
above, MAR beats MAS by 0.277 ± 0.011 while each of them varies by about 0.05
across seeds on its own.

The interval is from Student's t with `seeds − 1` degrees of freedom. A ✓ marks
an interval that excludes zero.

!!! warning "What ✓ does and does not mean"
    It means the difference is larger than the seed-to-seed noise **of this
    simulated setup, at these settings**. It is not a claim about EEG recordings,
    or about how these methods rank on your data. A simulator can only tell you
    how a method responds to the artifact you modelled.

---

## Changing what gets compared

The matrix is data, not code — `EVATests/Pipeline/MethodComparison/comparison-matrix.json`.
Adding a method to the table is a JSON edit:

```json
{
  "id": "mas-16-donors",
  "label": "MAS, 16 donors",
  "kind": "eva",
  "citation": "Chen, Z., et al. AMRI toolbox, amri_eeg_gac.m (NINDS/NIH).",
  "steps": [
    {
      "operation": "mriGradientCorrection",
      "parameters": {
        "trMarkerCode": "TREV", "method": "MAS", "donorVolumes": "16",
        "backend": "cpu", "alignment": "false", "subSample": "false",
        "upsampleFactor": "1"
      }
    }
  ],
  "ceiling": { "rule": "sqrtDonorVolumesPlusOne", "tolerance": 1.02 }
}
```

The `parameters` are exactly the ones a processing step carries, so anything the
app can be told to do, an arm can be told to do.

| Field | Meaning |
| --- | --- |
| `kind` | `eva` runs the steps through EVA. `uncorrected` scores the generated recording unchanged — the baseline arm. |
| `steps` | The processing steps, in pipeline order. Each must be one a headless run can complete without asking a human. |
| `ceiling` | The best score this arm could attain if it worked perfectly. Optional — see below. |
| `citation` | Carried into the results file, so a table can be captioned from it. |
| `seeds` | Top level. Each scenario is generated once per seed and every arm sees all of them. |
| `referenceMethod` | Top level. The arm the paired table measures everything against. |

`referenceMethod` is declared rather than inferred deliberately: choosing the
best-scoring arm as the reference after the run makes every comparison a
foregone conclusion.

To try a variation without disturbing the committed matrix, copy it and pass the
copy's path to the script.

### The ceiling, and why a table can fail

Average-artifact subtraction with locked clocks cancels the artifact exactly.
What is left is the EEG that the template averaged in along the way, so over `N`
donor volumes the best attainable broadband SNR is about `sqrt(N + 1)` — a
*perfect* eight-donor template scores near 3, not infinity.

An arm scoring above its own ceiling has not discovered something; the clean
signal has reached the correction. On simulated data, where the truth is sitting
in the next directory, that is a real possibility, and no floor can ever catch
it. So a comparison run is report-only in every respect but this one: an arm over
its ceiling fails the run, because a table containing an impossible number is
worse than no table.

Declare a ceiling only where one is actually derivable. The local-template
methods have one; FASTR's residual fit and Allen IAR's correlation-gated running
sections do not, and asserting one for them would make the check meaningless
rather than stricter.

---

## Current results

A snapshot from 2026-08-27 — nine methods, five seeds, EVA 0.1.7. Two scenarios
differing in exactly one parameter: `gradient-locked` carries the scenario's 10%
slow amplitude modulation, `gradient-steady` sets it to zero.

Broadband SNR, mean ± SD:

| Method | gradient-locked | gradient-steady |
| --- | --- | --- |
| No correction | 0.0634 ± 0.0003 | 0.0679 ± 0.0004 |
| MAR | 2.7320 ± 0.0536 | 2.7483 ± 0.0550 |
| MAS | 2.4549 ± 0.0436 | 2.7472 ± 0.0552 |
| wAAR | 2.1665 ± 0.0551 | 2.1642 ± 0.0554 |
| wAAS | 2.1494 ± 0.0547 | 2.1624 ± 0.0557 |
| FARM | 1.8698 ± 0.0350 | 1.8959 ± 0.0342 |
| Fast AAS | 0.5901 ± 0.0036 | 0.6123 ± 0.0038 |
| Allen IAR | 0.1516 ± 0.0008 | 0.1626 ± 0.0009 |
| FASTR | 0.1300 ± 0.0007 | 0.1393 ± 0.0008 |

**MAR's advantage over MAS is entirely amplitude tracking.** The paired
difference MAR − MAS falls from **+0.2772 ± 0.0112** with the modulation to
**+0.0010 ± 0.0004** without it. MAR is MAS plus a least-squares template scale,
so once the artifact amplitude stops drifting it should have nothing left to do —
and that is exactly what the numbers say. It is the clearest available check that
the harness measures what it claims to.

**The bottom three rows are an open question, not a result.** Their audit lines
say they ran properly — FASTR corrected 1229 of 1230 epochs at the right period
and removed 74% of the variance — and removing the amplitude modulation barely
moved them, which rules out the obvious explanation. FASTR and FARM share an
engine and differ only in how they choose donor volumes, yet differ nearly
fifteenfold here. Until that is understood these numbers should not be quoted as
a comparison of the published methods; they are a comparison of EVA's
implementations at one pinned configuration, on one artifact model.

!!! warning "Configuration is not neutral"
    Every arm above is pinned to the same settings — CPU backend, no alignment, no
    upsampling — so the table compares methods rather than tunings. That choice
    changes the ranking: running each method at its own defaults instead moves
    FASTR up and FARM sharply down. "Each method at its own defaults" and "every
    method at one shared configuration" are different questions, and any table has
    to say which one it answered.

The design record, and the reasoning behind each of these decisions, is in
`docs/provenance/method-comparison.md`.
