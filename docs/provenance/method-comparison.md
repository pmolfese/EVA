# Method Comparison Harness — Design Record

Record for the comparison harness in `EVATests/Pipeline/MethodComparison/`
(ROADMAP Part II, item 3.2). This is the reasoning and the measured results;
the how-to is `docs/manual/tools/method-comparison.md`.

Written 2026-08-27, covering Phases A and B.

## What it is

One loop, run per (scenario, seed, method arm):

    eva-simulate generate  →  EVA processes headlessly  →  eva-simulate score

which is the Tier 7 pipeline-regression loop pointed at a different question.
Tier 7 asks whether a method is still as good as it was and answers pass or
fail. This asks which method is better and by how much, and answers with a
table.

## Decisions, and why

### It lives in EVA's test target, not in `Tools/EVASimulate`

`Tools/EVASimulate` is a standalone SwiftPM package. It cannot link EVA's app
code, so it cannot invoke `MRIGradientMethod` at all. Driving EVA headlessly
means being inside the app module, which the test target already is — and
`HeadlessBatchProcessor` plus `EVAProcessingScript` is the seam
`PipelineRegressionTests` has used since Tier 7.

`Tools/EVAHelper` is not a precedent for doing it from a command line: it
carries its own copies of the engines. Building a second driver for the sake of
a nicer invocation would put a second implementation between the published
numbers and the shipped app.

### The matrix is data

`comparison-matrix.json`, schemaVersion 1, declares scenarios, seeds, method arms
with their literal step parameters, citations, analytic ceilings, and the
reference arm. Adding a method to a published table is a JSON edit, and
`EVA_COMPARISON_MATRIX` runs a one-off matrix without disturbing the committed
one.

`validate()` rejects a matrix that names an unknown operation, duplicates an arm
id, names a missing reference arm, or omits the uncorrected baseline.

### Scoring shells out to `eva-simulate score --json`

The rich metric set — per-band residuals, spectral distortion, per-channel
breakdown — exists once, in `SNRMetrics`. A table for publication should be
computed by that implementation rather than by a second one written beside it.

`PipelineRegressionTests` deliberately keeps its own in-process broadband SNR:
a regression check must not depend on an external binary having been built.
Having two implementations is tolerable only because
`harnessSNRAgreesWithInProcessSNR` scores the same recording both ways and
compares them. Without that test, the paper's table and the regression watermark
could drift into describing different quantities.

### A mandatory baseline, and per-arm ceilings

The uncorrected arm is required. The same corrected score is excellent or
worthless depending on it.

The ceiling is the leakage check. For an N-donor average template with locked
clocks the artifact cancels exactly and the residual is the EEG the template
averaged in, giving `sqrt(N + 1)`; a score above that means ground truth reached
the correction. The harness is report-only except here — an arm over its ceiling
fails the run, because a table with an impossible number in it is worse than no
table. Tolerance is 2%, for numerical error only: a 25% allowance on a ceiling of
3.0 admits every score up to 3.75, which is the whole range the check exists to
reject.

Ceilings are declared only where derivable. FASTR's OBS residual fit and Allen
IAR's correlation-gated running sections have no closed form, and asserting one
would weaken the check everywhere rather than strengthen it there.

### Audit capture (added during Phase A, not planned)

Each arm's `log_eva_*.txt` is read back from the processed package into the
result. The first run made the reason obvious: FASTR scored 0.13 and nothing
anywhere said why.

A method that falls back — no motion parameters, too few donors, a rejected
template scale — still emits a perfectly valid recording and a perfectly
plausible score. Without the audit lines, the table reports that fallback as the
method's performance. Parsing the emitted log rather than reaching into a view
model is also deliberate: `HeadlessBatchProcessor` owns its own `ProcessingCore`,
and constructing a second one here so the harness could hold a reference would
mean the comparison ran through a different path than the one it measures.

### Paired differences (Phase B)

Every arm sees the identical recording at a given seed, so the comparison is
`method − reference` within seed. The spread that survives is the spread of the
difference, which is much smaller than either arm's own — MAR beats MAS by
0.277 ± 0.011 while each arm varies by about 0.05 across seeds.

Pairing is by seed, never by position: a missing cell narrows the comparison
rather than silently misaligning it. `referenceMethod` is declared in the matrix
because picking the best-scoring arm afterwards makes every comparison a foregone
conclusion.

Intervals use Student's t with `seeds − 1` degrees of freedom, from a short table
of critical values rather than an inverse-CDF implementation: the degrees of
freedom are a small number chosen by hand in the matrix, and a table exact for
the values actually used beats a numerical routine that would need its own tests.
An interval excluding zero is reported as *larger than this setup's seed-to-seed
noise* — never as "significant", which would imply a claim about EEG recordings
that a simulator cannot support.

### Provenance

EVA's version string, OS, architecture, and the resolved scenario configuration
for each scenario, written by `generate --write-config` beside the results. The
resolved configuration is the useful artifact: a reviewer regenerates from a file
rather than reconstructing a command line from prose.

Per the project guardrail, no content digests or hash manifests are involved and
none are planned.

### The sandbox

The test host is the sandboxed EVA app. It can read the working tree but writing
to it fails with `NSCocoaErrorDomain 513`, and `eva-simulate` inherits the
sandbox as a child process. The harness therefore generates and writes inside the
app container; `compare-methods.sh` copies the results into `.comparison/` from
outside, and passes `TEST_RUNNER_EVA_COMPARISON=1`, which is the only way an
environment variable reaches an xcodebuild test process.

## Measured results, 2026-08-27

Nine arms, five seeds, EVA 0.1.7 (20260828), macOS 26.6.2 arm64, CPU backend,
no alignment, no upsampling. `gradient-steady` is `gradient-locked` with
`slowModulationFraction` set to zero — one parameter, so any difference between
the columns is attributable to amplitude drift and nothing else.

Broadband SNR, mean ± SD over seeds:

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

Paired against MAS, on `gradient-locked`:

| Method − MAS | Mean Δ | SD of Δ | 95% CI | t |
| --- | --- | --- | --- | --- |
| MAR | +0.2772 | 0.0112 | +0.2632 to +0.2911 | 55.27 |
| wAAR | −0.2884 | 0.0376 | −0.3351 to −0.2417 | −17.14 |
| wAAS | −0.3055 | 0.0371 | −0.3515 to −0.2594 | −18.42 |
| FARM | −0.5851 | 0.0407 | −0.6356 to −0.5346 | −32.16 |
| Fast AAS | −1.8648 | 0.0413 | −1.9161 to −1.8135 | −100.86 |
| Allen IAR | −2.3033 | 0.0431 | −2.3568 to −2.2497 | −119.41 |
| FASTR | −2.3248 | 0.0432 | −2.3784 to −2.2713 | −120.45 |
| No correction | −2.3915 | 0.0434 | −2.4454 to −2.3377 | −123.27 |

No arm exceeded its ceiling. The local-template arms sit just under the analytic
3.06 where they should.

### Confirmed: MAR's advantage over MAS is amplitude tracking

MAR − MAS falls from **+0.2772 ± 0.0112** with modulation to
**+0.0010 ± 0.0004** without it. MAR is MAS plus a least-squares template scale,
so it should have nothing left to do once the amplitude stops drifting. This is
the cleanest available evidence that the harness measures what it claims to: a
mechanism was predicted from the method definitions, isolated by changing one
parameter, and found.

### Refuted: slow modulation does not explain the engine-family gap

Phase A hypothesised that the slice-template and global-average engines scored an
order of magnitude worse because a global template cannot track drifting
amplitude. Removing the drift moved FASTR 0.130 → 0.139 and Allen IAR
0.152 → 0.163. The gap is unchanged; every method improved slightly because the
artifact got easier. That explanation is dead.

### Open

- **FASTR versus FARM.** Same slice-template engine, nearly fifteenfold apart
  (0.130 vs 1.870). They differ in donor selection: FARM ranks donors by
  correlation, FASTR takes temporal neighbours. With TR = 3.000 s at 1000 Hz a
  volume is exactly 3000 samples but a slice interval is 73.17 — not an integer —
  so successive slice artifacts land on different sub-sample phases, which the
  simulator models deliberately. Correlation ranking would pick phase-matched
  donors; temporal neighbours would not. Leading hypothesis, testable with an
  alignment/upsampling axis.
- **Fast AAS and Allen IAR.** Also poor, and Fast AAS runs on integer
  3000-sample volume epochs, so it is not slice-phase-limited in the same way.
  Whatever it shares with FASTR is a third thing, unidentified.
- **Configuration is not a neutral pin.** A probe at each method's own defaults
  moved FASTR 0.130 → 0.331 and moved FARM the other way, 1.825 → 0.450, while
  Allen IAR did not move at all. Any published table must state which
  configuration it used.

None of the three should be quoted as a comparison of the *published* methods
until at least the first is resolved. As they stand, they compare EVA's
implementations at one pinned configuration against one artifact model.

## Known limits

- One artifact model. Every number here is a statement about the simulator's
  gradient model, not about EPI artifacts in general. The measured-template
  library (ROADMAP Part II, 3.3) is what would change that.
- Moosmann cannot be compared at all. It weights donors by realignment
  parameters, and motion is an external file no replayable script carries, so a
  Moosmann arm would silently degrade to unweighted averaging. Same
  external-input gap RW-1 item 11 and MRI-1 both name, seen from the results
  side.
- CPU only, by design. Metal and CPU agree within a tolerance, and a table mixing
  backends would not be reproducible.
- No artifact-cleaning axis yet (ROADMAP Part II, 3.2 Phase C), and no BCG PCA-S
  arm until SI-3 ships it as a correction stage.
