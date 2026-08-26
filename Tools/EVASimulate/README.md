# EVA Simulate

A forward-model EEG/fMRI simulator and scorer: it writes a ground-truth EEG
recording and a contaminated twin, then scores any corrected version of that
recording against the truth, per frequency band.

It exists because on real data there is no way to tell whether a correction
removed the artifact or removed the artifact *and* a good deal of the brain
signal with it. Both look like a cleaner trace. EVA now offers ten artifact
cleaning methods and seven OBS strategies, and choosing between them by eye is
not a method. With known ground truth, the choice becomes measurable.

The model reproduces:

> Grouiller F, Vercueil L, Krainik A, Segebarth C, Kahane P, David O (2007).
> *A comparative study of different artefact removal algorithms for EEG signals
> acquired during functional MRI.* NeuroImage 38(1):124-37.
> [doi:10.1016/j.neuroimage.2007.07.025](https://doi.org/10.1016/j.neuroimage.2007.07.025)

The operational default is 1000 Hz, which gives every sample an exactly
representable millisecond MFF event timestamp. The paper used 1024 Hz; load
`scenarios/paper-default.json` or pass `--rate 1024` for that exact rate.

The concentric-sphere forward solver is shared production code in
`EVA/Core/Forward/`. EVASimulate owns scenario/source/truth representations and
adapts them to that ordered physical-electrode API; it does not keep a second
copy of the spherical-harmonic implementation. This lets simulator fixtures
test the same forward mathematics EVA will use for source-informed methods.

Build:

```sh
sh Tools/EVASimulate/build.sh
```

## Quick start

```sh
Tools/EVASimulate/.build/eva-simulate generate --output ~/sim
```

Writes three things into `~/sim`:

| File | What it is |
| --- | --- |
| `sim_clean.mff` | The ground-truth EEG. No artifacts. |
| `sim_noisy.mff` | The same EEG plus gradient and BCG artifacts, with TREV volume markers, jittered QRS markers, and synthetic ECG / motion-sensor PNS channels. |
| `sim_truth.json` | Everything the recordings cannot carry: the seed, the *true* beat times as opposed to the detected ones, per-channel artifact amplitudes and latencies, and optional neural non-stationarity truth. |

`--prefix test1` renames all three to `test1_clean.mff`, `test1_noisy.mff` and
`test1_truth.json`, so several recordings can share one directory.

Open `sim_noisy.mff` in EVA, correct it however you like, export the result, and
score it:

```sh
Tools/EVASimulate/.build/eva-simulate score --truth ~/sim/sim_clean.mff --corrected ~/sim/corrected.mff --baseline ~/sim/sim_noisy.mff
```

Scoring the *uncorrected* recording against the truth — the baseline every
correction has to beat — looks like this on the defaults:

```
uncorrected: broadband SNR 0.0355  (clean std 10.90 µV, residual std 307.28 µV)

  band      SNR    power dB   clean RMS   resid RMS
  ---------------------------------------------------
  0-4        0.30    +10.80      3.651      12.138
  4-8        0.32    +10.30      2.948       9.236
  8-12       2.12     +0.73      9.828       4.645
  12-16      0.09    +21.16      1.986      22.657
  16-20      0.27    +11.82      0.968       3.638
  20-25      0.18    +15.19      0.673       3.816
  25-30      0.03    +29.72      0.656      20.091
  ...
  50-55      0.00    +54.86      0.038      21.222
```

That table is itself a check on the model: the worst bands are 12-16, 25-30,
40-45, 50-55 and 65-70, which are the harmonics of the 13.67 Hz slice rate
(3 s / 41 slices). A slice-rate comb is exactly what a real EPI artifact
produces. Alpha survives best because the comb has a null near 8-12 Hz and
alpha is the largest thing in the EEG.

Passing `--baseline sim_noisy.mff` adds the uncorrected SNR and a `gain` column
to the table for a corrected file.

`SNR` is the paper's Equation 2 — `std(clean) / std(clean - corrected)` — computed
within each band. `gain` is how much the correction improved it over the
uncorrected recording; **below 1.0 means the correction made that band worse than
leaving it alone.** `power dB` compares corrected band power against clean band
power, which is the number that catches over-filtering: a high SNR with a
strongly negative dB is a method quietly deleting your signal.

The current table also reports absolute RMSE, clean/corrected correlation, and
RMS spectral-shape error in dB for every band, followed by the same headline
metrics for every channel. JSON retains the complete channel × band breakdown;
CSV rows identify `aggregate` or `channel` scope.

## Commands

- `generate` — write one ground-truth/contaminated pair.
- `score` — compare a corrected recording against ground truth.
- `score-sources` — compare estimated locations and/or recovered components
  against dipole ground truth.
- `score-events` — score physiological, movement, and scanner-event detection against
  true sidecar times.
- `score-erp` — score recovered ERP peak amplitude and latency by component ID.
- `score-pac` — score recovered PAC strength and preferred phase against truth.
- `sweep` — one `generate` per value of a swept parameter, for a full curve.
- `selftest` — check that the model still reproduces the phenomena it claims to.

`eva-simulate --help` lists every option. The ones that matter most:

| Option | Why you would change it |
| --- | --- |
| `--qrs-jitter <ms>` | Separates methods that depend on beat timing from those that do not. The paper's Figure 5B. |
| `--slow-modulation <frac>` | Artifact amplitude drift, i.e. subject motion. The paper's Figure 4B, and where frequency-domain filtering wins. |
| `--bcg-amplitude <uv>` | Field strength, effectively. 10 µV is low field, 100-200 µV is 3T and up. |
| `--rate <hz>` | Defaults to 1000 Hz so sample timestamps survive the current MFF writer exactly. The paper used 1024 Hz and found 1-2 kHz sufficient for everything except ICA, which wanted 4 kHz. |
| `--clock-offset <us-per-s>` | Set to 0 to model an EEG amplifier synchronized to the scanner clock. |
| `--gradient-template <path>` | Use a template measured on your own scanner instead of the synthetic waveform. Strongly preferred for anything you intend to publish. |
| `--impedance <kohm>` | Typical impedance of a healthy electrode (default 12). Bad channels get a value matching their defect — high for a poor contact, but deliberately *low* for `flat`, because a bridged electrode reads excellent and records nothing. |
| `--no-impedance-noise` | Disable the operational default that couples contact impedance to Johnson noise and mains pickup; this restores paper/legacy measurement-only behavior. |
| `--prefix <name>` | Name the output files something other than `sim_*`, so a directory can hold more than one recording. |
| `--config <json>` | Load a complete, versioned scenario before applying explicit command-line overrides. |
| `--write-config <json>` | Save the final resolved scenario, with or without generating a recording. |
| `--with-nonstationarity` | Enable alpha spindles, slow spectral dynamics, switching microstates, and known phase-amplitude coupling. |
| `--eeg-model dipole` | Generate explicit neural dipoles through the three-shell forward model instead of the paper's channel-smoothing model. |
| `--reference average\|infinity` | Apply one declared reference to the complete additive sensor mixture before recording defects (default `average`). |
| `--sources <n>` | Control the number of true neural sources in dipole mode, including undercomplete ICA cases with more sources than sensors. |
| `--source-correlation <r>` | Impose an exact within-band Pearson correlation between S001 and S002. |
| `--near-source-separation <deg>` | Put S002 close to S001 to create nearly identical sensor topographies. |
| `--source-motion <deg>` | Rotate S001 during the recording and retain both endpoint operators in truth. |
| `--ocular-model dipole` | Project blink and gaze fields from two explicit corneo-retinal dipoles. |
| `--with-emg` / `--emg <per-min>` | Add localized, bursty 20-200 Hz temporalis and posterior-neck muscle activity. |
| `--write-sources` | Write calibrated true source moments to `<prefix>_sources.mff`. |

## Rich scoring metrics

`score` reports complementary measures because no single number distinguishes
all failure modes:

- **SNR** preserves the Grouiller paper's normalized correction score.
- **RMSE (µV)** exposes absolute error and DC bias that standard-deviation SNR
  can miss entirely.
- **Correlation** reports waveform preservation broadband and within each band.
- **PSD distortion (dB RMS)** compares Welch spectral shape bin by bin; zero is
  perfect. A global numerical floor prevents empty notch bands from being
  dominated by floating-point dust.
- **Power ratio (dB)** retains the signed over-filtering/under-correction view.
- **Per-channel results** make isolated failures visible in text, CSV, and JSON.

Artifact detection is scored separately from correction. A detector can supply
an MFF with markers or JSON with optional confidence values:

```json
{"events":[{"id":"beat-1","timeSeconds":1.234,"score":0.97}]}
```

```sh
eva-simulate score-events \
  --truth ~/sim/sim_truth.json \
  --detected ~/sim/detected.mff \
  --type bcg \
  --tolerance-ms 50 \
  --json ~/sim/bcg_detection.json
```

Truth and detections receive maximum-cardinality, minimum-timing-error,
one-to-one assignment inside the tolerance. The report includes TP/FP/FN,
precision, sensitivity, F1, timing MAE/max error, false positives per minute,
and specificity over time bins of twice the tolerance. Confidence-bearing JSON
also produces a threshold ROC curve and AUC. Default MFF codes are `TREV`,
`QRSd`, `blnk`, `eyem`, `emg`, `chew`, `swal`, `move`, and `swet`;
`--event-code` overrides them.

ERP peak estimates use a small forward-compatible contract:

```json
{"components":[{"id":"P300","peakLatencySeconds":0.320,"peakAmplitudeMicrovolts":7.4}]}
```

`score-erp --truth true.json --estimated recovered.json` matches component IDs
and reports signed bias, MAE, and RMSE for amplitude and latency. Roadmap item
1.2 now populates the same contract directly in simulation truth; add
`--level trial` to score non-omitted single-trial estimates by trial ID. Add
`--exclude-overlap` to restrict that score to trials whose simulated component
windows do not overlap another trial.

PAC estimates use this compact contract:

```json
{"strength":0.65,"preferredPhaseRadians":6.18}
```

`score-pac --truth sim_truth.json --estimated recovered_pac.json` reports signed
coupling-strength error and the shortest circular preferred-phase error, so
estimates near 0 and 2π are compared correctly.

## Neural non-stationarity

The paper-compatible path remains stationary. Add `--with-nonstationarity` to
enable four deterministic, independently configurable challenges:

```sh
eva-simulate generate --output ~/nonstationary --with-nonstationarity
```

- Alpha becomes smooth spindle-like bursts (12/min, 1 s mean duration) with a
  low inter-burst background, while retaining the eyes-open/closed block scale.
- Every EEG band receives an independent log-amplitude Ornstein–Uhlenbeck
  envelope (log SD 0.35, 12 s time constant).
- A 2–20 Hz carrier switches among four distinct, average-referenced scalp maps
  with 100 ms mean dwell, constrained to 40–250 ms, and 10 ms crossfades.
- A visible 6 Hz theta carrier modulates `gamma-low` amplitude at a known
  coupling strength of 0.7 and preferred phase of 0 radians.

Individual controls are `--alpha-bursts`, `--alpha-burst-duration`,
`--spectral-variation`, `--spectral-timescale`, `--microstates`,
`--microstate-dwell`, `--microstate-amplitude`, `--pac`, `--pac-low`,
`--pac-band`, and `--pac-phase`; each mechanism also has a `--no-*` switch.
Supplying an individual numeric control enables non-stationarity even without
the umbrella flag. `--no-nonstationarity` restores the stationary path.

The sidecar records every alpha burst, each band's one-Hz amplitude envelope,
every microstate episode and map, the microstate carrier seed/band and realized
scale, and complete PAC parameters including initial phase and the analytic
preferred/opposite gain ratio. In dipole mode, the switching microstate term is
an explicitly recorded sensor-space addition after dipole projection; it is not
included among the intracranial source channels in `_sources.mff`.

## ERP trial simulation

ERPs are opt-in, so the Grouiller benchmark remains unchanged. The default ERP
design is an 80-trial target/standard oddball sequence:

```sh
eva-simulate generate \
  --output ~/erp-sim \
  --with-erp \
  --erp-latency-jitter 30 \
  --erp-amplitude-jitter 0.2 \
  --erp-latency-amplitude-correlation -0.4
```

`std` and `targ` MFF markers identify every stimulus. Trial count, ISI and onset
jitter, target fraction, nominal latency/amplitude, latency skew, latency and
amplitude jitter, their correlation, and response omissions are independently
controlled. Targets and standards use the same component with a configurable
amplitude ratio. An omitted trial retains its stimulus marker and truth record
but contributes no evoked samples.

Latency, amplitude, condition order, onset jitter, and omission decisions use
five independently seeded random streams. Changing trial count or one design
factor therefore does not consume and reroll the other factors' random draws.

The analytic waveform can be Gaussian or biphasic. A measured waveform is a
text/CSV series loaded with `--erp-template` and `--erp-template-rate`; its
largest absolute peak is aligned to each trial's true latency and normalized
before amplitude scaling. Every component uses an explicit, recording-referenced
spherical dipole topography even when the ongoing EEG uses the legacy Grouiller
sensor-space model.

The truth sidecar records:

- Every trial's ID, condition, event code, onset, true latency, absolute peak
  time, amplitude, omission state, component-window end, and directional overlap
  flags.
- Exact standard/target average peaks, including jitter and omitted responses,
  ready for `score-erp`'s default `--level average` mode.
- The ERP dipole position/orientation, normalized scalp topography, waveform
  provenance, realized latency–amplitude correlation, and all five stream seeds.

For a single-trial method such as Woody, RIDE, or CWT-ridge, write recovered
peaks using `trial-0001`, `trial-0002`, etc. and run:

```sh
eva-simulate score-erp \
  --truth ~/erp-sim/sim_truth.json \
  --estimated ~/erp-sim/recovered_trials.json \
  --level trial \
  --exclude-overlap
```

Omitted trials are excluded from latency/amplitude recovery scoring because no
neural peak exists to estimate; their presence remains available for separate
response-detection evaluation.

## Recording reference

`average` is the default recording reference for both the Grouiller and dipole
paths. Neural EEG, ERPs, scanner artifacts, physiological artifacts, contact
noise, and mains pickup are combined and referenced once at a common additive
boundary. A deliberately bad physical reference, channel defects, bridges, and
clipping are applied afterward because those recording failures can break the
nominal reference. The sidecar records both the convention and this application
stage. `--reference infinity` preserves native potentials without
re-referencing; `scenarios/paper-default.json` uses that legacy convention so
the reviewed paper-reproduction waveform is not changed by this addition.

## Cohorts

`generate-group` writes a cohort of subjects rather than one recording:

```sh
eva-simulate generate-group --config scenarios/group-oddball.json \
    --subjects 20 --output cohort/
```

Each subject gets a `sub-XX/` directory with the usual packages, and the root
gets `participants.tsv` (BIDS covariate table, with each subject's *true* drawn
parameters) and `group_truth.json`.

The reason this is more than running the generator N times: a group study has two
levels of ground truth, and both are recorded — the **population** condition
difference a group analysis is trying to recover, and the **between-subject
variance** around it. N draws from one distribution have no between-subject
structure at all, so a mixed-effects model fitted to them estimates a variance
component that is zero by construction and appears to work regardless.

`group_truth.json` records the group ERP estimand explicitly by component ID,
nominal peak latency, units, and target-minus-standard contrast. A scalar
`populationEffectMicrovolts` is emitted only when exactly one non-zero ERP
component carries the contrast (or zero for a negative control). Multiple
components are never summed across latencies or polarities into a scientifically
meaningless scalar. Score every component against `erpEstimand.components`, not
against any one subject.

Per subject the tool varies head radius (which changes the forward model, so
topographies differ even for identical sources), electrode placement, alpha
amplitude, BCG severity, impedance quality, heart rate, and the ERP effect size —
each declared as a standard deviation and recorded. `--homogeneous` zeroes all of
them, which is the negative control: a group method that finds structure in a
homogeneous cohort is finding noise.

Cohorts are **prefix-stable**: the first 6 subjects of a 12-subject cohort are
byte-identical to a 6-subject cohort, so growing a cohort never resamples the
subjects already in it.

For BIDS, run `eva-bids to-bids` once per subject; the two tools are kept
separate rather than one calling the other.

## PCA-S correction and evaluation

The surrogate correction supports two explicit beat-pattern searches:

- `--pattern-search paper` is the default. It matches every beat once against
  one representative beat, as in the paper. Supply the paper operator's
  one-based choice with `--representative-beat N`; when it is omitted, the CLI
  uses a deterministic median-energy candidate as an unattended stand-in.
- `--pattern-search iterative` starts from the all-beat average and performs two
  match-and-refine passes. It is an intentional robustness extension, not the
  paper algorithm.

The selected mode, actual representative candidate, accepted-beat fraction,
artifact-component count, and correction parameters are written to the report.
Operator construction and application use EVA's shared UI-free
`SourceInformedSeparation` engine; EVASimulate owns only regional-basis and BCG
template discovery policies at this boundary. The report also records operator
dimensions, retained/dropped artifact columns, requested and effective ridge,
projected brain power, and the Cholesky-factor range. `evaluate-surrogate --json`
emits a versioned machine-readable result containing the full per-seed values
and mean/SD for broadband and, with `--with-erp`, every ERP criterion.

PCA-S uses the recording's electrode geometry instead of silently substituting
the built-in montage. For generated data, give `correct` its truth sidecar so it
can also reproduce the exact spherical head model and lead-field truncation:

```sh
eva-simulate correct \
  --input sim_noisy.mff \
  --output sim_corrected.mff \
  --truth sim_truth.json \
  --pattern-search iterative \
  --report sim_correction.json
```

Geometry resolution is explicit and ordered: `--coordinates <path>` wins, then
the input MFF's `coordinates.xml`, then a coordinates asset referenced by the
truth configuration. The override accepts either a standalone `coordinates.xml`
or an MFF/package containing one. If none is valid, correction stops; the legacy
built-in approximation is available only with `--assume-standard-montage`.
Real recordings have no shell geometry in MFF, so their reports declare the
classic three-shell approximation; simulation truth supplies exact shell radii
and series terms. The corrected MFF preserves the input coordinates and all PNS
channels, including samples, names, rate, and `positiveUp` convention. The JSON
report records all of this provenance.

ERP evaluation follows the paper's order: reject single epochs, average the
accepted epochs, apply the 0.3-30 Hz zero-phase filter to the completed average,
then baseline and score it. Filtering only the inputs is not equivalent because
the epoch edges alter the filter response.

## Scenario files

A scenario is a versioned JSON envelope containing a name, description, schema
version, complete `SimulationConfig`, and seed. Load one with `--config`; any
explicit model flags come afterward and therefore override it:

```sh
eva-simulate generate \
  --config Tools/EVASimulate/scenarios/dipole-separability.json \
  --duration 60 \
  --output ~/dipole-study
```

The precedence is deliberately simple:

```text
built-in defaults < loaded scenario < --demo preset < explicit model flags
```

Boolean settings can be changed in both directions with paired flags such as
`--with-gradient`/`--no-gradient`, `--with-bcg`/`--no-bcg`,
`--with-ecg`/`--no-ecg`, and
`--with-motion-sensor`/`--no-motion-sensor`. `--no-gradient-template` returns a
loaded measured-template scenario to the synthetic waveform.

Save the final resolved configuration without doing an expensive simulation:

```sh
eva-simulate generate \
  --config Tools/EVASimulate/scenarios/paper-default.json \
  --qrs-jitter 40 \
  --seed 20260822 \
  --write-config ~/scenarios/bcg-jitter-40ms.json
```

Supplying both `--output` and `--write-config` generates data and saves the exact
resolved scenario embedded in the truth sidecar. Measured gradient-template
paths written by the CLI are canonicalized to absolute paths. A relative path
authored directly in JSON is resolved relative to that scenario file.

Eight reviewed scenarios ship in `Tools/EVASimulate/scenarios/`:

| Scenario | Purpose |
| --- | --- |
| `paper-default.json` | Exact Grouiller benchmark defaults, without teaching additions. |
| `teaching-demo.json` | Ocular and muscle artifacts, mains noise, bad channels, and scanner lead-in/out. |
| `dipole-separability.json` | Correlated, near-degenerate, moving neural sources plus non-stationarity and ocular dipoles. |
| `oddball-erp.json` | Trial-variable target/standard ERP design with skew, correlation, and omissions. |
| `aep-bilateral.json` | Bilateral auditory N100 evaluation over the generator BCG. |
| `bcg-generators.json` | Four placed BCG generators with genuine spatial rank and morphology variation. |
| `group-oddball.json` | Multi-component oddball cohort with a known component-wise group contrast. |
| `regression-gradient-locked.json` | Analytically anchored locked-clock pipeline regression fixture. |

Scenario schema versions are checked when loading. A newer unsupported schema
fails loudly instead of silently dropping or misreading model parameters.

The Tier 7 regression runner derives six short corpora in
`.regression-corpus/`: locked- and drifting-clock gradient, QRS-driven BCG,
oddball ERP, recording defects, and an artifact-free clean control. The clean
control comes from the locked-gradient fixture by disabling gradient and
impedance noise and setting BCG EEG amplitude to zero. BCG timing remains
enabled solely to produce realistic ECG and motion PNS streams for the MFF
round-trip check. Keeping these reviewed overrides in `run-all-tests.sh` avoids
near-duplicate scenario files.

Run the complete generate → process → score loop with:

```sh
./run-all-tests.sh
```

The EVA tests watermark correction quality, detector timing, ERP peak recovery,
bad-channel recall, planted bridge/reference signatures, and clean-signal
preservation with tolerances. The generated MFFs remain local and uncommitted;
the recipes and score watermarks are the reviewed artifacts.

The same stage generates a deliberately mixed 60-second recording for the Tier
8.1 ICA component-labelling benchmark. One Picard-O decomposition is scored
against graded class membership derived from the simulator's known Brain, Eye,
Heart, Muscle, Line Noise, and Channel Noise topographies. ICLabel and the
transparent heuristic branch of `ICAComponentAutoLabeler` are reported
separately, per class. The initial macro-F1 baselines are 0.100 and 0.170,
respectively; these are regression measurements on simulated data, not claims of
external validity.

## Source-space EEG

The Grouiller model remains the default, unchanged. Its spatial structure is a
correlation imposed between channels; it does not define recoverable neural
sources. An opt-in model generates actual source time courses and projects them
through an analytic concentric-sphere lead field:

```sh
eva-simulate generate --output ~/dipoles --eeg-model dipole --sources 7
```

The head preset has brain, skull and scalp radii of 72, 79 and 85 mm and
conductivities of 0.33, 0.0042 and 0.33 S/m. The implementation accepts an
arbitrary number of shells even though this first preset has three. Electrodes
use the montage's angular positions scaled to the scalp radius; sources occupy
deterministic, prefix-stable positions inside the brain shell. Adding source 8
does not move or reseed sources 1-7.

Each source is assigned one of the existing frequency bands in turn. When
correlation is requested, S002 is assigned S001's band before their waveforms
are mixed, so both remain inside the band recorded in truth. Each source's
position, unit orientation, band, seed and calibrated RMS moment are written to
`sim_truth.json`, together with both the free-orientation (`x/y/z`) gain matrix
and the orientation-projected matrix, in µV/(nA·m). Sensor potentials use the
declared recording reference. One recorded calibration factor scales all source moments
so the final sensor EEG still has the requested 10.9 µV pooled standard
deviation.

The source count, depth, orientation pattern and harmonic-series length are
controlled by `--sources`, `--source-depth`, `--source-orientations` and
`--lead-field-terms`. `--source-correlation r` makes S001/S002 have exactly the
requested sample Pearson correlation within one band while retaining S002's independent
residual. `--near-source-separation degrees` transports S002's location and
orientation to a controlled angular distance from S001. The two controls can be
combined to make sources difficult in both time and space.

Every dipole run checks numerical convergence of the spherical-harmonic series.
It recomputes the full free-orientation gain matrix at `N` and `2N` terms and
reports the largest L2-relative column change. Changes above `1e-4` (0.01%) emit
a warning naming the worst source/orientation axis and recommend increasing
`--lead-field-terms`. The 100-term default passes from source-radius fractions
0.01 through 0.999999 in the classic three-shell model; deliberately requesting
too few terms is reported rather than silently producing a plausible map.

`--source-motion degrees` rotates S001's position and orientation beginning at
`--source-motion-start` and linearly interpolates its gain vector over
`--source-motion-transition`; both arguments are fractions of recording
duration. The initial and endpoint positions, orientations, times, and complete
endpoint lead field are retained in truth. The interpolation is an explicit
simulator approximation, not a claim that real head motion follows a linear
sensor-gain path.

Dipole mode also splits neural, BCG, ocular, line-noise, channel-defect and
impedance randomness into named seed streams, so a source-count sweep cannot
silently change the artifact realization.

`sweep --parameter sources --values 4,7,20,30 --eeg-model dipole` produces a
controlled ICA-rank series while holding every earlier source and artifact seed
stable. The common calibration still holds total sensor EEG at `--eeg-std`.

The neural lead field applies to **neural EEG only**. Gradient pickup, bad
contacts and BCG are not intracranial neural sources and remain in their
existing sensor-space models. `--ocular-model dipole` separately places two
corneo-retinal dipoles at approximate eye centers in a homogeneous conductor;
its average-referenced blink/vertical and horizontal fields are normalized
before the existing ocular amplitude controls are applied. This is more
physical than the default heuristic cosine field, but it is deliberately not
misrepresented as part of the intracranial three-shell model.

### Source-space scoring

Add `--write-sources` to write the calibrated source moments as an MFF package,
in nA·m. An inverse method can instead emit estimated locations as JSON:

```json
{"sources":[{"id":"estimate-1","positionMeters":{"x":0.01,"y":0.02,"z":0.03},"orientation":{"x":0,"y":0,"z":1}}]}
```

Score either or both outputs against the simulation sidecar:

```sh
eva-simulate score-sources \
  --truth ~/dipoles/sim_truth.json \
  --estimated ~/dipoles/estimated.json \
  --recovered ~/dipoles/recovered_sources.mff \
  --json ~/dipoles/source_score.json
```

Location matching minimizes total Euclidean error and reports millimeters;
orientation error is axial, so a flipped orientation is equivalent to a source
waveform sign flip. Signal matching maximizes absolute Pearson correlation.
Both use rectangular optimal assignment and report unmatched true or estimated
sources, so neither source order nor component polarity can inflate the error.
Location scoring currently targets the initial source position; a moving
source's endpoint is available separately in the motion truth record.

## Muscle artifact

EMG is off by default. Enable the standard model with `--with-emg`, or set its
mean burst rate directly:

```sh
eva-simulate generate --output ~/emg --no-gradient --no-bcg \
  --emg 12 --emg-amplitude 50 --duration 120
```

Each burst selects a left-temporalis, right-temporalis, or posterior-neck source
region. Its independent stochastic carrier is confined to 20-200 Hz, multiplied
by a smooth attack/plateau/release envelope, and projected with a normalized
anatomical weighting strongest near F7, F8, or Oz. Burst interval, duration, and
amplitude vary deterministically from the run seed.

`emg` MFF markers carry each burst's duration. The truth sidecar retains its
onset, duration, muscle region, realized RMS amplitude, and all three channel
topographies. `score-events --type emg` evaluates a detector against those
onsets. `--emg-duration`, `--emg-low`, and `--emg-high` expose the remaining
model controls; the high edge must remain below Nyquist. Sweeps accept
`--parameter emg-rate` and `--parameter emg-amplitude`.

This is a controlled surface-EMG model, not a claim that real motor-unit spectra
or volume conduction are fixed. It is meant to test the overlap between muscle
and neural beta/gamma activity and the burst detection/removal tradeoff.

## Additional artifact families

The rest of roadmap item 2.1 is also opt-in:

| Artifact | Enable with | Model and truth |
| --- | --- | --- |
| Chewing | `--chewing <episodes/min>` | Rhythmic temporalis EMG episodes, `chew` duration markers. |
| Swallowing | `--swallowing <events/min>` | Stereotyped double-lobed posterior-neck EMG, `swal` markers. |
| Cable movement | `--cable-movement <events/min>` | Broad, correlated low-frequency sway around a recorded channel center, `move` markers. |
| Sweat | `--sweat <episodes/min>` | Very slow drift on `--sweat-channels` explicit electrodes, `swet` markers. |
| True bridge | `--bridge 3:4,8:9` | Each pair is replaced by its shared mean signal; exact pairs are retained in truth. |
| Bad reference | `--bad-reference <uv>` | The same 0.2-30 Hz contamination is added to every channel at the requested RMS. |
| Saturation | `--clip <uv>` | Symmetric hard rails applied last, with clipped-sample counts per channel. |

Amplitude and duration controls follow the obvious names (`--chewing-amplitude`,
`--swallowing-duration`, `--cable-amplitude`, `--sweat-duration`). Paired
`--no-*` flags remove artifacts loaded from a scenario. `score-events` accepts
`chewing`, `swallowing`, `movement`, and `sweat`; bridges, reference corruption,
and clipping are sample-level defects rather than onset-detection targets.

## Impedance-coupled noise

The operational default creates electrode impedance before recording noise and
uses the same realization for both the samples and the ICAL measurement. Each
contact receives independent Johnson-Nyquist voltage noise, `sqrt(4 k T R B)`,
where `R` is that channel's impedance, `T` defaults to 298.15 K, and `B` is the
recording's Nyquist bandwidth. With mains interference enabled, per-channel gain
scales as `(R / 12 kΩ)^x`; `x` defaults to 1 and small lead-dress variation
remains.

Use `--electrode-temperature`, `--impedance-line-exponent`, or an
`--parameter impedance` sweep to control the model. `--no-impedance-noise`
restores the old independent behavior and is retained by `paper-default.json`.
`--no-impedance` suppresses the recorded ICAL block only: latent contact
impedance still affects the samples and remains in truth.

Flat contacts and true bridged pairs deliberately read 0.4-3 kΩ. They therefore
have little thermal or mains pickup while their waveforms remain unusable—the
important counterexample showing why impedance is predictive, not synonymous
with data quality. The coupling law is an EVA model, not a parameter reported by
Grouiller et al. It treats the measured impedance magnitude as an effective
resistance; real electrode-skin impedance is complex and frequency-dependent.

## For class demos

The paper's defaults make a *benchmark*, not a teaching recording: no blinks, no
mains hum, no bad electrodes, and the scanner running from the first sample. One
flag turns on the lot:

```sh
Tools/EVASimulate/.build/eva-simulate generate --output ~/Desktop/demo --demo
```

That is shorthand for 15 blinks/min, 25 eye movements/min, 8 muscle bursts/min,
60 Hz line noise, the geometric spatial model, 15 s of quiet before the scanner
starts and 10 s after it stops, and two deliberately bad channels. Any explicit
flag still overrides it, so `--demo --line-noise 50` does what it looks like.

The recording that comes out supports most of the obvious lecture beats:

| To show | Look at |
| --- | --- |
| Raw vs. filtered | The whole trace: mains hum on every channel, drift on Pz, gradient artifact from 15 s. |
| What a blink looks like | `blnk` markers; Fp1/Fp2 versus Cz. The topography is frontal-maximal and reverses slightly at the back. |
| Blinks vs. eye movements | `eyem` markers. Blinks are transients; eye movements are *steps* that hold until the eyes move again, with opposite polarity at F7 and F8 — because the potential follows gaze position, not gaze velocity. |
| Why we keep an EOG | The VEOG/HEOG PNS channels see the same artifact far larger than any scalp electrode. |
| Muscle versus neural gamma | `emg` markers; compare F7/F8 and Oz with Cz. The broadband burst is spatially local rather than a global high-frequency change. |
| Bad channel detection | F8 (noisy) and Pz (drift) against their neighbours. Easiest to see in the pre-scan window or after gradient correction. |
| Impedance is not data quality | Health scoring with `--bad-channels "3:flat,7:noisy"`: the noisy channel reads 100+ kΩ, the bridged one reads under 3 kΩ and scores perfect while recording nothing. |
| Why notch filtering is per channel | Add `--bad-channels "3:line"` — one channel with heavy mains pickup and the rest clean. |
| The scanner turning on | 15 s in. Before that the EEG looks clean but is already carrying the BCG, because the static field never switches off — only the gradients stop. |
| Ground truth | `sim_clean.mff` is the same EEG with none of it. Overlay them. |

Some smaller recipes:

```sh
# Just blinks on clean EEG — nothing else to distract from them.
eva-simulate generate --output ~/blinks --no-gradient --no-bcg --blinks 18 --duration 60

# Bursty temporalis and posterior-neck muscle activity on otherwise clean EEG.
eva-simulate generate --output ~/emg --no-gradient --no-bcg --emg 12 --duration 120

# One bad channel of each kind, to compare how they look.
eva-simulate generate --output ~/bad --no-gradient \
  --bad-channels "3:flat,7:noisy,11:drift,15:pop,19:line" --line-noise 60

# Filtering practice: mains hum and drift, no MR artifacts at all.
eva-simulate generate --output ~/filtering --no-gradient --no-bcg \
  --line-noise 60 --blinks 15 --duration 120
```

### Channels and layout

Channels are a real 10-20 montage — Fp1, Fp2, F7 … Oz, O2 at 20 channels — and
both `sensorLayout.xml` and `coordinates.xml` are written, so channel selection
by name, topographic maps, and spherical-spline interpolation all work. Below 20
channels the set is subsampled across the head rather than truncated (truncating
a front-to-back ordering would hand back an all-frontal montage); above 41 it
falls back to a spiral, which is named "Spiral (synthetic)" so nobody mistakes it
for a real montage.

Use a digitized or project-specific layout at generation time with
`--coordinates <path>`. The path may be a standalone `coordinates.xml` or an
MFF/package containing it; when `--channels` is omitted, the simulator infers
the EEG channel count from the file. Sensor names and normalized 3D directions
are retained, subject-level montage jitter still applies when requested, and
the resolved absolute path is stored in scenario/truth configuration. Relative
paths in a scenario are resolved from that scenario file's directory.

Positions are the 10-20 construction for the midline and outer ring, and
eyeballed to a few degrees for the intermediate and 10-10 sites. Fine for
simulating where a blink is large and for drawing a recognizable head map; not a
digitized montage.

### A caveat about the gradient artifact

Its amplitude varies strongly across the head by design — the paper varies it
from 0 to 7000 µV peak-to-peak between channels — and here it scales with arc
angle from the vertex, so Cz sees the least and the temporal sites the most.
During scanning that swamps everything else, including a deliberately bad
channel. Inspect bad channels in the pre-scan window, after gradient correction,
or with `--no-gradient`.

## What comes from the paper and what does not

This matters when interpreting a result. A finding that depends on a parameter
the paper measured is stronger evidence than one that depends on a shape this
tool invented.

**From the paper, used verbatim:**

- EEG as a linear mixture of seven band-limited Gaussian sources over 1-70 Hz,
  with a 45-55 Hz notch dropout, and a target standard deviation of 10.9 µV.
- Alpha modulated between 10 µV (eyes open) and 30 µV (eyes closed) on a 20 s
  alternation.
- Spatial correlation as circular connectivity smoothed with a Gaussian kernel of
  SD 4 channels.
- GE-EPI geometry: TR 3 s, 41 slices, ~60 ms of artifact per slice.
- Gradient amplitude varying across channels up to 7000 µV peak-to-peak.
- A 152 µs/s EEG-to-MRI clock offset.
- Slow gradient amplitude modulation, sine of 200 s period, 10% of mean.
- Heart rate wandering 65-85 bpm on a one-minute cycle; mean BCG amplitude
  10-200 µV; beat-to-beat amplitude weighting the previous beat and a fresh 15%
  draw equally; per-channel latency 15 ms SD; QRS detection jitter 25 ms SD.
- The motion sensor's saturating sigmoid nonlinearity, gain 0.1.
- `SNR = std(EEG) / std(EEG - EEG_corrected)`, and the evaluation bands.

**EVA's own, not the paper's:**

- The four-generator BCG (`--bcg-model generators`): the aortic-flow and
  head-rotation topographies are *derived* (a homogeneous-conductor dipole in
  the chest, and the leading-order motional potential `phi ∝ x·z` of a rigid
  nod in a uniform B0); the vessel-pulsation kernels are *modelled*, because
  electrode motion over an artery is a moving half-cell potential and not a
  current source. Relative amplitudes and delays are plausible, not measured.
  `--bcg-generator-scales a,l,r,h` sweeps the four physical shares without
  changing the requested composite peak-to-peak amplitude; the default
  `1,1,1,1` preserves the original generator model. Off by default.


- Everything under "For class demos" above plus the expanded 2.1 artifacts:
  blinks, eye movements, muscle/orofacial bursts, cable movement, sweat,
  bridging, bad-reference contamination, clipping, bad channels, mains noise,
  the electrode montage, and the pre/post-scan windows. All are off by default,
  so the benchmark numbers are unaffected by their existence.
- Gradient amplitude scaling with electrode position rather than channel index.

- The *shape* of the gradient waveform. The paper used a template measured on
  their 3T Bruker; this builds one as the time derivative of a modelled
  slice-select trapezoid plus EPI readout train, since induced EMF goes as
  dB/dt. Use `--gradient-template` to substitute a measured one.
- The *shape* of the BCG waveform — four Gaussian lobes putting the dominant
  negative deflection ~120 ms after the R wave.
- The synthetic ECG, whose morphology follows McSharry et al. (2003), the
  standard synthetic-ECG model, since the paper does not specify one.
- Heart-rate variability and the respiration model. The paper's cardiac timing
  has no beat-to-beat variability; `--hrv 0` restores it exactly.
- Per-band amplitudes of the seven EEG sources (roughly 1/f; the paper fit theirs
  to one subject and does not print them).
- The anti-alias model: the artifact is band-limited at 0.9 × output Nyquist
  before being point-sampled, standing in for the amplifier's own filter.
- Reporting band power ratio in dB alongside SNR.
- The opt-in dipole model: source positions and orientation patterns, the
  classical three-shell preset, average reference and common amplitude
  calibration. Its shell recurrence follows Bruña, Fuggetta & Pereda (2023),
  implemented independently from the published equations.
- The exact within-band correlated-pair construction, controlled near-source placement,
  linear moving-gain interpolation, approximate eye centers, homogeneous ocular
  conductor, and optimal-assignment source scores. These are declared simulator
  choices, not parameters reported by Grouiller et al.
- The ERP oddball design, analytic component shapes, trial distributions,
  omission model, amplitude ratio, and latency–amplitude correlation. These are
  controlled validation scenarios, not parameters from Grouiller et al.; use a
  measured ERP template when waveform morphology is central to a claim.
- The common additive-boundary recording-reference contract, five ERP seed
  domains, and the precise component-window definition used for overlap flags.
- The opt-in non-stationarity laws and defaults: lognormal alpha-renewal timing,
  sin² spindle envelopes, per-band log-amplitude OU processes, generated
  microstate maps and dwell distribution, sensor-space microstate carrier, and
  cosine PAC gain. They are controlled test conditions rather than parameters
  fitted by Grouiller et al.; their complete realized truth is retained.

## Known limitations

These are worth stating plainly, because a harness whose limits are unstated
gets over-trusted.

- **The default EEG is stationary for paper compatibility.** Use
  `--with-nonstationarity` for ICA/PAC evaluation, and sweep its parameters;
  one controlled stochastic model still does not establish population realism.
- **Microstates are phenomenological sensor-space maps.** In dipole mode their
  component is not reconstructed from the intracranial dipole catalog, and the
  generated maps are not subject-specific microstate classes.
- **The spatial model is circular, not anatomical.** Channel 1 neighbours
  channel N. Methods that exploit real topography — EVA's topography-gated,
  -aligned and -weighted OBS strategies — are being handed a spatial structure
  that no montage produces. This applies to the default Grouiller model;
  `--eeg-model dipole` replaces it with a spherical volume conductor, which is
  still an approximation rather than an individual anatomical head model.
- **ERP generators are spherical and fixed within a scenario.** Scenarios can
  contain multiple placed components with independent latency streams and
  overlapping windows, but do not yet model individual anatomy, habituation, or
  condition-dependent source locations.
- **The default BCG is a fixed waveform with varying amplitude and latency**,
  not the genuinely varying morphology of a real one, and its topography is a
  function of channel *index* rather than electrode position — which makes the
  whole artifact rank one. This flatters template-based methods considerably:
  against a rank-one artifact, an OBS that removes four components cannot fail.
  `--bcg-model generators` replaces it with four physically placed generators
  (spatial rank 4, real topographies, beat-to-beat morphology variation) and is
  what anything turning on BCG topography or component count should use. The
  channel-index model remains the default so the published benchmark reproduces
  unchanged.
- **The paper-default benchmark has no ocular or muscular artifacts, electrode
  drift, or bad channels.** Ocular, EMG, and recording-defect additions are
  opt-in.
- **Muscle models use fixed source regions and controlled carrier families.**
  EMG, chewing, and swallowing do not model subject-specific muscle anatomy,
  motor-unit recruitment, or individual volume conduction.
- **One template shape for all channels.** Real gradient artifacts differ in
  shape, not just scale, across the montage.

## Notes from building it

Two things surfaced while validating the model that are worth knowing:

**Slice spacing is usually not an integer number of samples.** At 1024 Hz with
TR 3 s and 41 slices, a slice is 74.93 samples. Slice artifacts therefore never
repeat their sub-sample phase, even with the EEG and MRI clocks perfectly
locked — before any clock drift enters the picture. This is exactly why IAR and
FASTR interpolate up to ~10 kHz before attempting slice-level alignment, and it
means slice-level template subtraction has a floor that volume-level subtraction
does not. The volume period *is* an integer here (3072 samples), which is what
`selftest` uses to isolate the clock-drift effect.

**Naive average-artifact subtraction has a ceiling of sqrt(N).** With the clocks
locked, the artifact cancels exactly and the only thing left is the EEG that the
template averaged in along the way, whose standard deviation is std(EEG)/sqrt(N)
over N epochs. So a "perfect" AAS on 20 volumes scores SNR 4.47, not infinity.
Any method scoring meaningfully above that ceiling is doing something smarter
than a global average — and any method well below it on locked-clock data has a
problem. `selftest` pins this.

## Event-time precision

Event times survive a write/read round trip at microsecond precision, at any
sampling rate. This was not always true: MFF stores event times as absolute
ISO-8601 datetimes, and both halves of EVA's round trip used to quantize to
1 ms — `DateFormatter` carries millisecond internal precision no matter how many
fractional digits the format string requests, and `ISO8601DateFormatter`'s
`.withFractionalSeconds` truncates past three digits on read.

At 1024 Hz a sample is 976.5625 µs, so that displaced markers by up to half a
sample, and two adjacent TR markers could round-trip 1.02 samples apart — enough
for EVA's own gradient stage to reject the recording with "TRs are not evenly
spaced". Rates whose sample period is a whole millisecond (1000 Hz, 500 Hz) were
unaffected, which is why the operational default was set to 1000 Hz.

Both sides are fixed (roadmap item 4.9). `scenarios/paper-default.json` runs at
the paper's 1024 Hz and every marker recovers its exact sample index. The 1000 Hz
default remains, now as an ordinary choice rather than a workaround.

## Self-test

```sh
Tools/EVASimulate/.build/eva-simulate selftest
```

Ninety-nine passing outcomes, including the compact SI-0 extraction-boundary
fixtures documented in `SI0_CONTRACTS.md`. The forward and source-informed
fixtures exercise EVA's shared solvers through EVASimulate's adapters; the remaining fixtures exercise
the simulator model: locked clocks put
template subtraction exactly on the sqrt(N) ceiling; that the paper's 152 µs/s
drift pushes it far below that; that QRS jitter penalizes correction which relies
on beat timing; that every injected waveform starts and ends at baseline rather
than injecting a step at each event; that the scanner window is respected while
the BCG carries on through it; that a blink is frontally maximal; and that the
dipole lead field obeys its analytic, reference, linearity, isolation and
determinism invariants. It also pins correlated/near/moving source scenarios,
ocular dipole fields, and permutation- and polarity-invariant source scoring.
They also verify complete scenario round trips and the
defaults → scenario → explicit-flags precedence contract.
They also pin imported MFF/standalone coordinates, strict correction geometry
fallback, truth-head reconstruction, exact coordinate copying, and ECG/motion
PNS preservation.
The metric checks pin perfect-reconstruction behavior, DC-error sensitivity,
optimal event matching/ROC generation, and ERP amplitude/latency statistics.
ERP-specific checks also pin deterministic designs and markers, exact controlled
variability, dipole topography, condition averages, true response omissions,
factor-isolated streams, explicit component-window overlap, filtering of the
completed accepted-trial average, and distinct component-wise group estimands.
Five non-stationarity checks pin stationary-default compatibility, deterministic
truth, burst timing and quiet intervals, slowly continuous stochastic spectra,
distinct microstate switching, and phase-locked gamma modulation.
The lead-field convergence check spans the permitted eccentricity range and
also rejects a deliberately under-resolved truncation.
Reference and correlated-source checks pin zero-mean average referencing at the
shared additive boundary and truthful within-band source mixing.
Three impedance checks pin the square-root resistance law, ordered mains pickup,
the disabled compatibility path, and deceptively low true bridges.
Surrogate checks pin deterministic paper and iterative pattern-search modes,
artifact attenuation, artifact-free preservation, end-to-end separation,
brain-map correlation, explicit degeneracy failures, and the brain-basis
competition effect. The phase-by-phase extraction record is
`SI2_EXTRACTION.md`.
Run it after touching anything in the model — a
harness that silently stops reproducing the phenomenon it exists to study is
worse than no harness, because everything it emits still looks like evidence.
