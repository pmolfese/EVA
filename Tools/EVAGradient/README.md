# EVA gradient / ERP experiments

**User preference (2026-10-28): do not run the legacy `aas`/`evaLocal` method.**
The requested AAS comparator is EVA’s dedicated slice-group Allen AAS preset.
The current `baseline` method is local same-group subtraction, not that Allen
preset; historical plots labeled “Slice-group AAS” refer to this local baseline.
An actual Allen-preset run is required before comparing against Allen AAS.

Implements all four approaches in [the test plan](../../eva-gradient-test-plan.md):
event-aware donor exclusion, joint regression, iterative ERP/artifact estimation,
and a prospective timing-jitter experiment. These are experimental research
methods, validated with synthetic fixtures, not yet with the user's real data.

## Build and run

```sh
sh Tools/EVAGradient/build.sh
Tools/EVAGradient/.build/eva-gradient self-test

Tools/EVAGradient/.build/eva-gradient inspect /path/to/recording.mff \
  --tr-code TREV --slices 60 --multiband 3 --events std,targ \
  --protect-ms 0:800 --report /path/to/timing.json

# All retrospective methods plus the standard baseline (the default method set).
Tools/EVAGradient/.build/eva-gradient compare /path/to/recording.mff \
  --tr-code TREV --slices 60 --multiband 3 --events std,targ \
  --methods baseline,exclude,iterative,joint \
  --protect-ms 0:800 --fir-bin-ms 10 --iterations 5 \
  --output-dir /path/to/new-comparison

# Fourth approach: proposed timing + paired synthetic recordings and comparisons.
Tools/EVAGradient/.build/eva-gradient jitter /path/to/recording.mff \
  --tr-code TREV --slices 60 --multiband 3 --events std,targ \
  --jitter-ms 500 --minimum-isi 0.1 --seed 71 \
  --output-dir /path/to/new-jitter-experiment
```

Output paths must not exist. Input is continuous MFF; no CWL channels are needed.
Event codes are case-insensitive; unknown codes are errors. `--slices` means the
anatomical slice count. Uniform acquisition groups = slices / multiband, with
exact divisibility required. `--group-offsets 0,0.05,...` supplies actual group
starts in seconds, increasing, one per group and inside every observed TR.
Scanner sidecar import and BrainVision IO are not implemented.

## Methods

| Method | Estimator | Main controls |
| --- | --- | --- |
| `baseline` | Local same-group AAS using all eligible donors | `--donors`, `--min-donors`, `--max-donor-distance` |
| `exclude` | Same AAS, excluding event-contaminated donor windows | Above plus `--events`, `--protect-ms` |
| `iterative` | Alternate local AAS and condition-specific overlap-aware ERP regression | Above plus `--iterations`, `--tolerance`, `--fir-bin-ms`, `--ridge` |
| `joint` | Simultaneously fit stationary scanner-phase artifact and condition FIR coefficients | `--protect-ms`, `--fir-bin-ms`, `--ridge`, `--allow-confounded` |
| `jitter` command | Propose onset jitter and test original/jittered synthetic schedules with the chosen methods | `--jitter-ms`, `--minimum-isi`, `--seed`, `--artifact-amplitude` |

All correction uses CPU, no alignment/resampling, OBS off and ANC off. Local
methods use unscaled templates with no self-donation. PNS is copied unchanged in
real-data comparisons. No downsampling, ERP filtering or baseline correction is
performed. These settings isolate the estimators, not a final scanner pipeline.

### 1. Donor exclusion

Defaults: 30 requested donors, minimum 4, maximum distance 60 seconds in either
direction. `--protect-ms 0:800` defines merged half-open protection intervals.
Any overlapping artifact window is barred from donating, but remains a target
for correction. The shared engine's policy also accounts conservatively for
interpolation support if another caller enables resampling/alignment. All donor
selection/fallback paths enforce the restrictions. Unsupported targets pass
through and are reported; protected donors are never reintroduced to fill gaps.

### 2. Joint regression

Fits `y = G alpha + E beta + error` per channel. `G` is a disjoint indicator basis
with one coefficient per acquisition group and native-sample lag, shared across
the run. `E` contains separate piecewise-constant FIR bins per event code. Event
responses add when their windows overlap. The output is **raw minus G alpha**;
the fitted ERP stays in the data.

The solver eliminates `G` analytically with its projection, solves the smaller
ERP Schur-complement system, then estimates artifact coefficients from raw minus
the ERP prediction. It never allocates a dense samples-by-regressors matrix.
Group epochs do not overlap; pre/post-scan samples and unmodeled gaps pass through.
Each group owns the full interval up to the next group or volume boundary,
including extra samples from fractional-spacing rounding. Missing-volume gaps
remain unmodeled. Drift still requires careful residual inspection.

This is a **stationary whole-run artifact model**. It differs from local AAS and
cannot follow arbitrary motion-related artifact changes. Local donor settings do
not apply. Do not attribute every difference from AAS solely to ERP protection.

`--fir-bin-ms 10` is rounded to at least one native sample. FIR support uses
`--protect-ms`, including negative lags if supplied. The implementation caps the
ERP model at 512 columns, 20 million sparse entries and 16 million artifact/ERP
cross-products, with errors suggesting smaller models when limits are exceeded.

`--ridge 0.000001` penalizes normalized ERP coefficients; artifact coefficients
are unpenalized. Reports include rank, minimum eigenvalue and condition of the
**unregularized normalized residual Gram matrix**. This is a Gram condition,
not the design matrix's condition. Rank uses eigenvalues above
`max(1e-10, maximumEigenvalue * 1e-8)`.

Rank deficiency fails that method by default. `--allow-confounded true` explicitly
permits a regularized sensitivity experiment and retains the rank warning.
Regularization does not recover unique neural/artifact attribution. Compare
multiple ridge values on development data before interpreting near-confounded
fits; full rank alone does not establish model adequacy.

### 3. Iterative estimation

Starts with zero ERP, then for each iteration:

1. Run local AAS on original raw minus the previous ERP prediction.
2. Recover the estimated artifact as training input minus its corrected output.
3. Form original raw minus that artifact.
4. Fit separate condition FIRs to that residual, accounting for event overlap.

Returns **original raw minus the last artifact estimate**, not the ERP-stripped
training data. Default maximum is 5 iterations (up to 100). Stops after at least
two iterations when both ERP and artifact relative RMS changes are below
`--tolerance 0.001`. Reports include both changes at every iteration and whether
the tolerance was reached. The ERP solver's rank is checked, but this does not
establish joint artifact/ERP identifiability. A phase-locked ERP can still be
absorbed by the initial template and remain lost. This is an experimental
alternating estimator, without cross-validation or a convergence guarantee.

### 4. Design jitter

The `jitter` command does **not** move events in real EEG and pretend they changed
physiologically. It reads timing/geometry from the input and creates:

- `proposed-events.csv`: original/proposed onset and offset per stimulus.
- `original-synthetic.mff`, `jittered-synthetic.mff`: identical synthetic gradient
  samples with known Gaussian ERPs placed at each schedule's event times.
- `original-truth.mff`, `jittered-truth.mff`: exact ERP-only truth.
- `original-comparison/`, `jittered-comparison/`: selected methods and injection
  diagnostics, using the normal comparison workflow.
- `jitter-report.json`: truth RMSE per method, uncorrected truth RMSE, fit failures,
  per-condition TR/group phase histograms (20 bins), and occupied-bin counts.

Offsets are drawn uniformly within `± --jitter-ms`, quantized to native samples,
and rejection-sampled to retain recording boundaries, trial order, complete ERP
windows and `--minimum-isi`. Thus accepted offsets are conditional, not uniformly
distributed near constraints. A seed reproduces the schedule. Impossible requests
fail explicitly. Both schedules retain selected event codes/counts. PNS and
unrelated real markers are omitted from synthetic recordings. Histograms omit
events outside complete non-gap TRs and report their count.

Defaults: ±500 ms, 100-ms minimum ISI, seed 1, gradient amplitude 1000 native
units, ERP base amplitude 5 native units. The artifact is a stationary
sample-phase sinusoid/harmonic model; the ERP is a 300-ms Gaussian, sigma 60 ms,
truncated to 0–800 ms, with channel gains from 1 to 2. There is no ongoing EEG,
motion or physiological artifact. This intentionally simple fixture favors the
joint model's assumptions. Validate with measured artifacts, realistic ERP
variability and held-out data before scientific conclusions. The proposed
schedule still needs acquisition-specific feasibility and phase-coverage review;
jitter is not a guarantee of balanced phases or sufficient clean donors.

## Reports and preservation metrics

`inspect` writes configuration, event counts, TR min/median/max, long gaps,
stimulus phases and clean donor support per target. Phase records omit stimuli
outside complete non-gap TRs and report that count. Group phase is seconds since
the preceding group. Coverage uses the same unaligned local geometry as AAS.

`compare` defaults to `baseline,exclude,iterative,joint` and writes each successful
method's `.mff`, `-donors.csv`, `-erp.csv`, and a shared `report.json`.

Donor CSV indices are zero-based. It includes correction status, counts, maximum
distance and donor indices; joint regression has no donor list (header-only CSV
and null epoch coverage). Its modeled artifact sample count is in method details.
ERP CSV contains condition/channel averages from -200 to +800 ms, complete-trial
counts, raw/corrected/removed waveforms, without filtering or baseline correction.
The reporting and injection windows stay fixed even when the FIR/protection
window changes. Iteration diagnostics refer to the final artifact estimate.

Each method also refits raw plus a known injected Gaussian ERP at the selected
events, then measures `correction(raw + injection) - correction(raw)`:

- `injectedERPRMSE`: error versus the injection over the whole recording, including
  leakage outside injection support.
- `injectedERPAmplitudeRatio`: projection onto injection divided by its energy
  (ideal 1).
- `removedRMS`: correction magnitude, **not** an artifact-quality score.

`--inject-amplitude 5` is in **native signal units**. Confirm input units before
choosing a scientific amplitude. This tests incremental preservation, not truth
for the native ERP. Unsupported AAS regions can preserve injection perfectly
because they pass through: always inspect coverage. Both original and injected
fit diagnostics are retained. A failed method is recorded with its error while
others continue; if all fail, comparison exits nonzero after saving the report.
Jitter continues to its second schedule even if all methods fail on the first.

## Verification and limits

`self-test` checks exclusions and fallback paths, interval boundaries, shortages,
distance/group restrictions, compatibility, known ERP recovery, and MFF IO.
Additional tests exercise overlapping condition recovery by joint regression,
iterative improvement, exact-lock rank failure and explicit opt-in, seeded jitter
bounds/ISI, restored rank and improved baseline recovery on a paired fixture.

Real-data validation, measured-artifact simulations, cross-validation, standalone
plots, spectral artifact metrics, provenance hashes, scanner sidecar import and
BrainVision IO remain future work. No GUI changes are required for this tool.

Optional `--methods aas,farm` adds two whole-TR comparison presets: `aas` uses
EVA's legacy `.evaLocal` AAS (4 preceding + 4 following donors, linear detrending);
`farm` uses 30 donors, first-difference Pearson correlation >=0.9, +/-20-TR
candidates, and temporal fallback below 30 qualified donors. FARM scaling,
alignment, OBS and ANC are off. These preset comparisons override the local
experimental donor/geometry settings; details are saved per method.


## Allen / FARM ERP add-ons (2026-10-28)

Choose `--methods allen,allen-exclude,allen-iterative,allen-joint,farm,farm-exclude,farm-iterative,farm-joint`.
Legacy `aas` is rejected. The older `baseline`, `exclude`, `iterative`, `joint`
remain diagnostic methods; `baseline` is a generic local template, not Allen.

* `allen`: the shared Allen IAR **slice-group** implementation, fixed sections
  (~7.5 seconds, at least 25 groups), correlation gate .975, first 5 accepted
  donors, explicit MRI offsets supported. ANC is off for this experiment.
  It pools eligible slice epochs within a section; it does not restrict donors
  to the same ordinal group across volumes.
* `farm`: shared app whole-TR FARM preset, 30 temporal donors, correlation search
  +/-20 TR, first differences, threshold .9, minimum 30 correlated donors then
  temporal fallback. Alignment, scaling, ANC and OBS are off.
* `-exclude`: veto every donor whose full window overlaps protected events.
  Allen applies this **before** seed/template construction; FARM applies it to
  all candidate/fallback paths. At least `--min-donors` must remain. Shortage
  leaves the target unchanged and records a warning; protected targets are
  still corrected when donors are available. Allen retains section boundaries;
  FARM retains its candidate window. Generic distance/donor-count controls do
  not override these presets.
* `-iterative`: alternate engine correction of `raw - estimated ERP` with an
  overlap-aware condition FIR fit. Output is always `raw - estimated artifact`.
  Both ERP and artifact relative changes must converge; reaching the iteration
  cap is reported, not silently treated as convergence.
* `-joint`: **exclusion + local joint gain fitting**. Construct the artifact
  basis with event-excluded templates, then jointly fit continuous piecewise
  linear artifact gains and condition FIRs. `--joint-block-seconds 30` sets the
  approximate gain-knot spacing. Ridge shrinks gain changes toward zero (unit
  gain) and ERP coefficients toward zero. Only artifact is subtracted.
  Per-channel unregularized rank, conditioning and gain coefficients are saved.
  This is conditional regression on learned templates, not an exact simultaneous
  estimator of every template sample. It cannot repair missing artifact shapes.
  Compare against exclusion alone to isolate the benefit of gain fitting.

Use `run_addon_campaign.py --input INPUT.mff --manifest MANIFEST.json --binary
.build/eva-gradient --output NEW_DIRECTORY` for the full campaign (numpy, scipy,
matplotlib required). The manifest supplies sample rate, sample count, stable
volume triggers, slices/MB, acquisition offsets and the 30-second plot window.
The script preserves the input, creates a seeded P3/ongoing-EEG/drifting-gradient
fixture, runs all eight methods plus paired injection checks on both fixture
and real data, and exports native waveform/filtered ERP figures and metrics.
The fixture uses the real event timing; it is not a jitter intervention. P3 truth
is stored separately from clean EEG truth. Simulation has amplitude/latency
variability but no BCG or motion transients; one seed is an exploratory test.
ERP figures use identical 0.5–30Hz filtering and -200–0ms baseline, all Stim
trials, no rejection or rereferencing. Harmonic power is a residual diagnostic,
not proof of neural preservation. Injection measures the incremental response
of the estimator and does not establish the true endogenous ERP.


### GUI scaling parity audit and options

The 2026-10-28 source audit confirms that `GradientViewModel` GUI FARM defaults
match the CLI: whole TR,30 donors,±20 TR candidates,first-difference correlation
>=.9,minimum30 then temporal fallback,unscaled,alignment/upsampling/OBS/ANC off.
Do not confuse these with `GradientCorrectionConfig()` low-level defaults: the
GUI overrides scaling,correlation settings and alignment. This is a source
configuration audit, not inspection of unsaved settings in an open recording.

`--farm-scaling unscaled|leastSquares|driftTracking` now exposes both GUI scaling
alternatives using the shared correction engine. Default remains `unscaled`.
`--farm-scale-smoothing 15` controls the running-median width for `driftTracking`;
both fitted modes use the GUI gain range0.2–5. These options apply to every FARM
method selected in that invocation. To compare ordinary scaled FARM against
joint using unscaled templates, use separate invocations and the same input.
The amplitude-drift comparison retains5s joint knots and omits the30s joint curve.
