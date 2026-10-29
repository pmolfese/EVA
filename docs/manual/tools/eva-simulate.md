# EVA Simulate

`eva-simulate` generates synthetic EEG recordings with **known ground truth**,
contaminated by modelled MR gradient and cardiac artifacts — and optionally by
blinks, eye movements, muscle bursts, mains hum and broken electrodes. It also
scores a corrected recording against that ground truth, band by band.

Two audiences, one program:

- **Teaching.** A recording where you know exactly what is signal and what is
  artifact, with every artifact type switchable, and a clean twin to overlay.
- **Method evaluation.** On real data there is no way to tell whether a
  correction removed the artifact or removed the artifact *and* a good deal of
  the brain signal with it — both look like a cleaner trace. With ground truth,
  the difference is measurable.

The model reproduces the forward model in:

> Grouiller F, Vercueil L, Krainik A, Segebarth C, Kahane P, David O (2007).
> *A comparative study of different artefact removal algorithms for EEG signals
> acquired during functional MRI.* NeuroImage 38(1):124-37.

The operational default is 1000 Hz so each sample aligns exactly with the
current MFF writer's millisecond event timestamps. The published model used
1024 Hz; use `--rate 1024` or `scenarios/paper-default.json` to reproduce it.

---

## Building and running

EVASimulate is a target in `EVA.xcodeproj`. Build it in Release and stage the
binary at `Tools/EVASimulate/.build/eva-simulate`:

```bash
xcodebuild -project EVA.xcodeproj -target EVASimulate -configuration Release build
cp "$(xcodebuild -project EVA.xcodeproj -target EVASimulate -configuration Release -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/EVASimulate" Tools/EVASimulate/.build/eva-simulate
```

`run-all-tests.sh` does this automatically. The binary lands at
`Tools/EVASimulate/.build/eva-simulate`; building the EVA app also embeds the same
tool at `EVA.app/Contents/MacOS/EVASimulate`. Every example below assumes you are
at the repository root; substitute the full path if not.

Eight subcommands:

| Subcommand | What it does |
| --- | --- |
| `generate` | Write one ground-truth/contaminated recording pair. |
| `score` | Compare a corrected recording against ground truth. |
| `score-sources` | Score recovered dipole locations and source waveforms. |
| `score-events` | Score event detection and timing. |
| `score-erp` | Score recovered ERP amplitude and latency. |
| `score-pac` | Score recovered PAC strength and preferred phase. |
| `sweep` | Run `generate` once per value of a swept parameter. |
| `selftest` | Check that the model still reproduces the phenomena it claims to. |

`eva-simulate --help` prints the same option list summarized below.

---

## Quick start

### GUI: waveform and condition editor

Open **File → New Simulated Recording → ERP** and enable event-related
potentials. The editor starts with **Frequent** and **Target**, and supports
additional named conditions through **Add condition** or **Duplicate**. Each
condition has its own waveform, event code, trial percentage, and trial recipe
mix. Use unique 1–4 character alphanumeric event codes for epoching. The condition
name is written as the event label; its stable internal ID links truth and scores.

- Double-click the waveform to add a Gaussian peak; drag a handle horizontally
  for latency and vertically for amplitude. Numeric fields offer the same edits
  without dragging. Width is Gaussian σ in milliseconds. Overlapping peaks sum,
  and negative amplitudes create negative deflections.
- **Present in** controls the fraction of non-omitted trials containing that
  individual peak. **Omitted** removes the whole ERP but retains the stimulus.
- Whole-response latency jitter moves all peaks together. Independent peak
  jitter moves them separately. Amplitude and width variation use shared
  trial-level multipliers. The **?** buttons explain units, distributions,
  clipping, and interactions.
- Mean ISI and its ± range specify uniformly varied onset-to-onset intervals.
  **Fit recording** extends recording duration to contain the actual seeded
  schedule and all realized waveform tails. Short ISIs can produce overlapping
  responses in the recording.
- Added white or smoothed sensor noise is continuous and independent across
  channels. It affects the noisy recording only and adds to other configured
  background/artifact sources. Smoothed noise has a 20 ms time constant.
- Each condition's non-omitted trials receive one **Typical**, **Attenuated**,
  **Inverted**, or **Divergent** recipe. Typical fills the remainder to 100%.
  Recipe parameters control attenuation gain, extra latency shift, and width
  distortion. These are generation recipes, not guaranteed TrialsView labels:
  the latter depend on measured similarity to the reference average.

Condition counts and recipe counts use largest-remainder rounding; omission and
peak-presence counts round to the nearest trial within each condition. Peak
presence is shuffled independently per peak and may overlap. Condition shares
must total 100%; **Normalize shares** rescales the entered proportions. Adding a
condition gives it 20% while scaling existing shares proportionally. All
assignments are reproducible from the seed.

**Trial preview** shows the template, all-trial mean (including omissions), and
up to twelve example trials. **Show other conditions** shows/hides the remaining
conditions; all plots share time and voltage scales. The preview uses the same
trial sampler as generation, with illustrative added noise. It excludes spatial
projection, re-referencing, other background/artifact sources, and neighboring
trial overlap. Peaks share one source in this editor; arbitrary placed-source
models remain available through existing scenarios.

The scenario's optional `config.erp.experiment` stores conditions, peaks,
recipes, and noise settings. The truth sidecar records `conditionName`, `recipe`,
and `realizedPeaks` for every trial, in addition to existing event and overlap
information. Existing scenarios without `experiment` retain their original
two-condition generation path and random streams. A legacy single Gaussian can
be copied into the editor with **Open waveform & condition editor**; this opts
into the new scheduling and allocation rules. Placed, biphasic, and measured
legacy models are not silently converted.

### Define conditions, peaks, and mixtures from the CLI

Both `generate` and `generate-group` accept inline experiment definitions. No
scenario file is required. For example, this makes a three-condition cohort with
two target peaks, including a negative peak present in half of responding target
trials:

```bash
Tools/EVASimulate/.build/eva-simulate generate-group \
  --output ~/sim-group --subjects 12 --group-seed 42 \
  --erp-condition frequent:Frequent:FREQ:0.5 \
  --erp-condition target:Target:TARG:0.3 \
  --erp-condition novel:Novel:NOVL:0.2 \
  --erp-peak frequent:p1:180:4:30 \
  --erp-peak target:p1:300:8:60 \
  --erp-peak target:p2:500:-3:40:0.5 \
  --erp-peak novel:p1:450:6:50 \
  --erp-mixture target:0.1:0.2:0.15 \
  --erp-recipe target:0.3:100:0.65:1.6 \
  --erp-trials 100 --erp-isi 1.2 --erp-isi-jitter 0.2 \
  --erp-latency-jitter 30 --erp-peak-jitter 10 \
  --erp-width-jitter 0.1 --erp-noise 1.5 --erp-noise-kind white \
  --erp-reference frequent --erp-effect-sd 0.3 --erp-fit-duration
```

| Flag | Value and meaning |
|---|---|
| `--erp-experiment` | Enable editable Frequent/Target defaults without defining conditions. |
| `--erp-condition` | `id:name:eventCode:fraction`; repeat for each condition. Shares must sum to 1. |
| `--erp-peak` | `conditionID:peakID:latency_ms:amplitude_uV:width_ms[:occurrence]`; repeat for every peak. Width is Gaussian σ; occurrence defaults to 1. |
| `--erp-mixture` | `conditionID:attenuated:inverted:divergent`; Typical fills the remainder. These fractions apply after omissions. |
| `--erp-recipe` | `conditionID:attenuated_gain:shift_ms:width_min:width_max`; shift is the ± range of extra divergent latency, widths are multipliers. |
| `--erp-peak-jitter` | Independent per-peak latency SD, in milliseconds. |
| `--erp-width-jitter` | Shared trial width multiplier SD, as a fraction. |
| `--erp-noise`, `--erp-noise-kind` | Continuous sensor noise RMS in µV; `white` or `smoothed` (20 ms time constant). |
| `--erp-reference` | Condition ID used as the group reference; defaults to the first condition. |
| `--erp-contrast` | `name:conditionID=weight,conditionID=weight,...`; repeat for named comparisons. Weights must sum to zero. |
| `--erp-fit-duration` | Extend recording duration to fit the actual seeded responses; applied separately to each group subject. |

All fractions use **0–1**, not percentages. IDs and names cannot contain colons;
quote a whole value when its name contains spaces. Condition IDs used in contrast
weights should also avoid commas and equals signs. Supplying `--erp-condition`
replaces the entire condition list and resets group comparisons. Each new
condition initially has peak `p1` at 300 ms, 8 µV, σ 60 ms. Supplying `--erp-peak`
replaces all peaks in each mentioned condition; unmentioned conditions retain
their peaks. These same rules apply when overriding a loaded `--config` file.

Shared flags remain available: `--erp-trials` (total across all conditions),
`--erp-start` (seconds), `--erp-isi` and `--erp-isi-jitter` (seconds),
`--erp-latency-jitter` (whole-response SD in milliseconds),
`--erp-amplitude-jitter`, and `--erp-omission-rate` (fractions). Experiment ISI
jitter varies successive intervals uniformly. Legacy shape, target-fraction,
skew, and latency/amplitude correlation flags are rejected for editable
experiments rather than silently ignored. Use `generate --write-config path.json`
with these flags to save a reusable scenario without generating a recording.

### Group effects across multiple conditions

The GUI's **Group** panel supports all conditions in the ERP editor. Select a
reference condition, keep the default comparisons (each other condition minus
the reference), or add named pairwise comparisons. **Fit recording length for
each subject** extends durations as needed for individual schedules. The **?**
buttons explain the group model and duration setting.

The CLI also supports weighted comparisons. For example, append this to the
command above to report Target minus the average of Frequent and Novel instead
of the default comparisons:

```bash
--erp-contrast 'target-vs-others:target=1,frequent=-0.5,novel=-0.5'
```

For a reference waveform B(t), condition waveform A(t), and subject multiplier
s, the subject waveform is **B(t) + s × (A(t) − B(t))**. The reference stays fixed.
The existing `--erp-effect-sd` controls the SD of s around 1 (default 0.30).
One shared multiplier scales every condition difference within a subject, so
their effect variation is correlated, not independent. Negative draws reverse
the differences; `--homogeneous` sets all between-subject SDs to zero, with
explicit SD flags able to override it.

`group_truth.json` stores exact Gaussian terms for population contrasts in
`erpExperimentEstimand` and each subject's contrasts in `erpWaveformContrasts`.
These describe **nominal source waveforms before** trial mixtures, peak
occurrence, omissions, jitter, noise, and sensor projection. They are not
predictions of observed trial averages. Different peak times and widths remain
separate terms; the truth does not collapse them to a sum of peak amplitudes.
Existing legacy two-condition group scenarios retain their original effect model.

```bash
Tools/EVASimulate/.build/eva-simulate generate --output ~/sim
```

### For a class demo

The paper's defaults make a *benchmark*, not a teaching recording: no blinks, no
mains hum, no bad electrodes, and the scanner running from the first sample. One
flag turns on the lot:

```bash
Tools/EVASimulate/.build/eva-simulate generate --output ~/Desktop/demo --demo
```

See [Recipes for teaching](#recipes-for-teaching) below for what to show with it.

---

## What `generate` writes

Three things, into the directory you name:

| File | Contents |
| --- | --- |
| `sim_clean.mff` | The ground-truth EEG. No artifacts of any kind. |
| `sim_noisy.mff` | The same EEG plus every artifact you enabled, with markers and physio channels. |
| `sim_truth.json` | Everything the recordings cannot carry — the seed, the *true* beat times as opposed to the detected ones, per-channel artifact amplitudes, topographies, and the full configuration. |

`sim` is just the default prefix. `--prefix test1` names the three files
`test1_clean.mff`, `test1_noisy.mff` and `test1_truth.json` instead, which lets
several recordings share one directory:

```bash
eva-simulate generate --output ~/class --prefix baseline --no-gradient --no-bcg
eva-simulate generate --output ~/class --prefix blinks   --no-gradient --no-bcg --blinks 18
eva-simulate generate --output ~/class --prefix withmr   --demo
```

Both packages carry a real 10-20 electrode montage, including
`sensorLayout.xml` and `coordinates.xml`, so channel selection by name,
topographic maps and spherical-spline interpolation all work in EVA.

### Markers in `sim_noisy.mff`

| Code | Meaning |
| --- | --- |
| `TREV` | Volume trigger. The code EVA's gradient stage looks for by default. |
| `QRSd` | Heartbeat **as an automatic detector would report it** — jittered. This is what a correction method should be given. |
| `QRSt` | The **true** beat time, where the artifact was actually injected. Ground truth; do not correct with it unless you are deliberately measuring the best case. |
| `blnk` | Blink onset (only when `--blinks` is on). |
| `eyem` | Eye movement onset (only when `--eye-movements` is on). |
| `emg` | Muscle-burst onset and duration (only when EMG is enabled). |
| `chew`, `swal` | Chewing-episode and swallowing onset/duration. |
| `move`, `swet` | Cable-movement and sweat-drift onset/duration. |

The separation between `QRSd` and `QRSt` is the point of the cardiac model. A
method that leans on beat timing sees a mis-registered template; one that does
not is unaffected.

### Physio (PNS) channels in `sim_noisy.mff`

| Channel | Present when | What it is |
| --- | --- | --- |
| `ECG` | default (`--no-ecg` to omit) | Synthetic P-QRS-T at the true beat times, ~1 mV. Morphology follows McSharry et al. (2003), the standard synthetic-ECG model. Lets R-wave detection be exercised rather than bypassed. |
| `Motion` | default (`--no-motion-sensor` to omit) | A modelled motion sensor: the mean BCG seen through a saturating sigmoid, as the paper models a piezo sensor. Deliberately *not* a linear copy of the artifact. |
| `VEOG`, `HEOG` | when ocular artifacts are on | The EOG pair, which sees the ocular artifact far larger than any scalp electrode. |

### `sim_truth.json`

| Key | Contents |
| --- | --- |
| `config` | Every model parameter used, including ones with no command-line flag. |
| `cleanStandardDeviation` | Pooled standard deviation of the ground-truth EEG, in µV. The denominator of every SNR. |
| `channelNames`, `montageName` | The montage that was used. |
| `recordingReference`, `referenceApplicationStage` | The single sensor-space reference and its position before physical recording defects. |
| `alphaEnvelope1Hz` | The eyes-open/eyes-closed alpha envelope, decimated to 1 Hz, for correlating recovered alpha power against the block design. |
| `neuralNonstationarity` | Opt-in alpha-burst events, per-band 1 Hz amplitude envelopes, microstate episodes/maps/carrier provenance, and PAC parameters. |
| `gradientVolumeOnsetsSeconds` | Continuous volume onsets, before quantization to the sample grid. |
| `gradientQuantizedVolumeOnsetsSeconds` | The same onsets as a recorded trigger carries them. |
| `gradientChannelAmplitudesMicrovolts` | Per-channel artifact amplitude. |
| `bcgTrueBeatSeconds` / `bcgDetectedBeatSeconds` | Ground-truth versus jittered beat times. |
| `bcgChannelScales`, `bcgChannelLatenciesSeconds` | Per-channel BCG polarity/scale and arrival latency. |
| `blinkSeconds`, `saccadeSeconds` | Ocular event times. |
| `blinkTopography`, `horizontalEyeTopography` | Per-channel weights of the injected ocular components, so a recovered ICA component can be checked against the one that went in. |
| `emgBursts` | Muscle-burst onset, duration, source region, and realized RMS amplitude. |
| `emgLeftTemporalisTopography`, `emgRightTemporalisTopography`, `emgPosteriorNeckTopography` | Normalized per-channel weights for the three EMG source regions. |
| `chewingEpisodes`, `swallowingEpisodes`, `cableMovementEpisodes`, `sweatEpisodes` | Exact onset, duration, amplitude, affected channels, and event-specific topography where applicable. |
| `bridgedChannelPairs`, `badReferenceRMSMicrovolts`, `clippedSampleCounts` | Truth for the non-additive recording defects. |
| `badChannels` | 1-based channel number to defect kind. |
| `impedancesKOhm` | Per-channel electrode impedance, empty when `--no-impedance` was used. |
| `simulatedImpedancesKOhm` | Latent contact impedance used by the noise model, retained even without ICAL export. |
| `impedanceThermalNoiseRMSMicrovolts` | Analytic Johnson-noise RMS injected per channel. |
| `impedanceLineNoiseGainsMicrovolts` | Realized per-channel mains fundamental gain before slow wander. |
| `scanStartSeconds`, `scanEndSeconds` | When the scanner was actually running. |
| `sourceSpace` | Dipole mode only: shell geometry/conductivity, source positions/orientations/bands/seeds/moments, common calibration, and both free- and fixed-orientation gain matrices. |
| `erpTrials` | Per-trial ERP peaks, component-window end, and previous/next/any overlap flags. |
| `erpRandomSeeds` | Independent seeds for latency, amplitude, condition order, onset jitter, and omission. |

---

## `generate` options in full

### Recording

| Option | Default | Notes |
| --- | --- | --- |
| `--output <dir>` | *required* | Created if missing. Existing packages with the same prefix are replaced. |
| `--prefix <name>` | `sim` | Filename prefix for all three outputs. A trailing underscore is optional — `test1` and `test1_` behave the same. Must be a bare name, not a path. |
| `--channels <n>` | `20` | See [Montage](#montage-and-electrode-positions) for what the montage does at other counts. |
| `--rate <hz>` | `1000` | Must be a positive integer rate; MFF cannot store a fractional one. Use `1024` for the paper's rate. |
| `--duration <s>` | `180` | |
| `--seed <n>` | `20260821` | The same seed produces byte-identical output. |

### Gradient (imaging) artifact

| Option | Default | Notes |
| --- | --- | --- |
| `--no-gradient` | off | Omit the imaging artifact entirely. |
| `--tr <s>` | `3.0` | Repetition time. |
| `--slices <n>` | `41` | Slices per volume. |
| `--gradient-amplitude <uv>` | `7000` | Peak-to-peak on the *strongest* channel. |
| `--gradient-amplitude-min <uv>` | `500` | ... on the weakest. |
| `--clock-offset <us-per-s>` | `152` | EEG-to-MRI clock drift. Set to `0` to model an amplifier synchronized to the scanner. |
| `--slow-modulation <frac>` | `0.10` | Slow drift in artifact amplitude, as a fraction of the mean. The paper sweeps 0 to 0.25. Stands in for subject motion. |
| `--gradient-template <path>` | — | Use a measured slice template instead of the synthetic waveform. One sample per line, or a single comma-separated row. |
| `--gradient-template-rate <hz>` | — | Required with `--gradient-template`. Must divide the internal artifact rate by a whole number, which it does whenever the template was exported at the simulated recording rate. |

### Ballistocardiogram

| Option | Default | Notes |
| --- | --- | --- |
| `--no-bcg` | off | Omit the cardiac artifact entirely. |
| `--bcg-amplitude <uv>` | `100` | Mean peak-to-peak. 10 µV is low field; 100-200 µV is 3T and up. |
| `--qrs-jitter <ms>` | `25` | SD of the error in *detected* beat timing. The single most discriminating parameter in the model. |
| `--heart-rate-min <bpm>` | `65` | |
| `--heart-rate-max <bpm>` | `85` | Rate wanders between the two on a one-minute cycle. |
| `--hrv <fraction>` | `0.04` | Beat-to-beat heart-rate variability as a fraction of RR. `0` restores the paper's exact metronomic timing. |
| `--respiration <hz>` | `0.25` | Breathing rate (15/min). Drives sinus arrhythmia, ECG amplitude modulation and baseline wander. |

### EEG

| Option | Default | Notes |
| --- | --- | --- |
| `--alpha-low <uv>` | `10` | Eyes-open alpha amplitude. |
| `--alpha-high <uv>` | `30` | Eyes-closed alpha amplitude. Alternates every 20 s. |
| `--eeg-std <uv>` | `10.9` | Target standard deviation of the generated EEG. The paper's value, which is what makes SNRs comparable with theirs. |
| `--eeg-model <name>` | `grouiller` | `grouiller` preserves the paper's channel-smoothing model; `dipole` generates explicit neural sources through a concentric-sphere lead field. |
| `--reference <name>` | `average` | `average` or `infinity`; applied once to every additive sensor-space layer before recording defects. |
| `--sources <n>` | `7` | Number of true neural sources in dipole mode. Sources beyond seven cycle through the frequency bands again. |
| `--source-depth <fraction>` | `0.85` | Source radius divided by the innermost brain-shell radius. Must lie strictly between 0 and 1. |
| `--source-orientations <pattern>` | `mixed` | `radial`, `tangential`, `mixed`, or deterministic oblique `free` orientations. |
| `--lead-field-terms <n>` | `100` | Terms in the spherical-harmonic series. |

### Neural non-stationarity

Off by default to preserve the paper-compatible stationary path.
`--with-nonstationarity` enables all four controlled mechanisms; specifying any
numeric mechanism option also enables the layer.

| Option | Enabled default | Notes |
| --- | --- | --- |
| `--alpha-bursts <per-min>` | `12` | Smooth spindle-like alpha bursts with a low inter-burst background. |
| `--alpha-burst-duration <s>` | `1` | Mean duration; realized durations have 0.25 s SD. |
| `--spectral-variation <sd>` | `0.35` | Stationary SD of each independent log-amplitude OU process. |
| `--spectral-timescale <s>` | `12` | OU correlation time constant. |
| `--microstates <n>` | `4` | Number of distinct switching sensor maps. |
| `--microstate-dwell <ms>` | `100` | Mean dwell, constrained to 40–250 ms with 10 ms transitions. |
| `--microstate-amplitude <uv>` | `4` | RMS of the added 2–20 Hz carrier before common EEG calibration. |
| `--pac <strength>` | `0.7` | Cosine modulation depth, from 0 through 0.99. |
| `--pac-low <hz>` | `6` | Phase-providing oscillator frequency. |
| `--pac-band <name>` | `gamma-low` | Amplitude-modulated configured EEG band. |
| `--pac-phase <deg>` | `0` | Known preferred phase. |

Use `--no-alpha-bursts`, `--no-spectral-dynamics`, `--no-microstates`, or
`--no-pac` for ablations. `--no-nonstationarity` disables the complete layer.
Truth records every realized event and map, the one-Hz envelopes, stochastic
carrier provenance, and exact PAC coupling. In dipole mode, microstates are an
explicit sensor-space component after dipole projection and are therefore not
present in `_sources.mff`.

PAC tools can emit `{"strength":...,"preferredPhaseRadians":...}` and run:

```bash
eva-simulate score-pac \
  --truth ~/nonstationary/sim_truth.json \
  --estimated ~/nonstationary/recovered_pac.json
```

The report gives signed strength error and shortest circular phase error.

#### Dipole model

Dipole mode uses an analytic concentric-sphere forward solution with no runtime
dependency. The default preset is brain/skull/scalp at 72/79/85 mm and
0.33/0.0042/0.33 S/m. The API supports arbitrary shells so a CSF-inclusive or
imported model does not require a new source interface.

Source positions form a deterministic, prefix-stable sequence: increasing
`--sources` preserves all earlier locations, orientations, bands and seeds.
With `--source-correlation`, S002 is assigned S001's configured band before the
exact correlation is imposed, so waveform mixing cannot silently invalidate its
band label. Without correlation, normal round-robin band assignment remains.
The sidecar records the `channels × (3 × sources)` free-orientation gain matrix
and the `channels × sources` matrix after orientation projection, both in
µV/(nA·m). Columns use the declared recording reference. Full-rate source signals are
regenerable from their individual seeds and the configuration; a common recorded
factor calibrates them to `--eeg-std`.

Before generation, the simulator recomputes the free-orientation operator at
`--lead-field-terms` and twice that count. It reports the largest L2-relative
column change and warns when it exceeds `1e-4` (0.01%), identifying the worst
source and orientation axis. Increase `--lead-field-terms` until the warning
clears. The 100-term default passes the self-tested classic-three-shell range
from 0.01 through 0.999999 of the brain radius.

The sweep command accepts `--parameter sources` with positive integer values,
which makes undercomplete and overcomplete ICA scenarios reproducible without
changing the artifact draws.

Only neural EEG uses this lead field. BCG, gradients and electrode defects are
not neural dipoles. Ocular sources will require an eye-aware volume conductor.

### Recording reference

The `average` default applies one reference after neural EEG, ERPs, scanner and
physiological artifacts, thermal contact noise, and mains pickup have been
combined. Bad-reference corruption, channel defects, bridges, and clipping are
then applied as physical recording failures that may break the nominal
reference. `--reference infinity` skips the re-reference. Both the convention
and application stage are explicit in `sim_truth.json`. The reviewed
`paper-default.json` scenario selects `infinity` to preserve the legacy paper
reproduction exactly.

### ERP random streams and overlap

ERP latency, amplitude, condition order, onset jitter, and omission each have a
separate deterministic seed recorded under `erpRandomSeeds`. A one-factor or
trial-count sweep therefore does not consume unrelated factors' draws.

Every `erpTrials` entry records `componentWindowEndSeconds` plus directional
`overlapsPreviousTrial`, `overlapsNextTrial`, and `overlapsAnotherTrial` flags.
Overlap is permitted because it is realistic, but it makes isolated
sensor-space peak truth ambiguous. Score the clean subset with:

```bash
eva-simulate score-erp \
  --truth sim_truth.json \
  --estimated recovered_trials.json \
  --level trial \
  --exclude-overlap
```

### Ocular artifacts

Off by default: the paper's simulations were explicitly free of ocular
artifacts, and enabling them by default would silently change every benchmark
number.

| Option | Default | Notes |
| --- | --- | --- |
| `--blinks <per-min>` | `0` | 12-20 is a resting adult. |
| `--blink-amplitude <uv>` | `100` | Peak at Fp1/Fp2. Real blinks run 50-200 µV. |
| `--eye-movements <per-min>` | `0` | Saccade rate. |
| `--eye-movement-amplitude <uv>` | `40` | Scalp amplitude at full gaze deflection. |

### Muscle artifact

EMG is off by default. `--with-emg` enables an 8-burst/minute model; specifying
any EMG parameter also enables it. `--no-emg` disables a loaded scenario.

| Option | Enabled default | Notes |
| --- | --- | --- |
| `--emg <per-min>` | `8` | Mean burst rate. Intervals are stochastic with a refractory floor. |
| `--emg-amplitude <uv>` | `50` | RMS carrier amplitude at the strongest electrode during an average plateau. |
| `--emg-duration <s>` | `0.75` | Mean duration; realized bursts vary from 0.6x to 1.4x. |
| `--emg-low <hz>` | `20` | Broadband carrier low edge. |
| `--emg-high <hz>` | `200` | High edge; must remain below Nyquist. |

Bursts independently select left temporalis, right temporalis, or posterior neck
and project most strongly near F7, F8, or Oz. Smooth attack and release edges
avoid introducing artificial step transients. Exact burst truth and topographies
are written to the sidecar, and `score-events --type emg` scores onset detection.
Sweeps accept `--parameter emg-rate` and `--parameter emg-amplitude`.

### Additional artifact families

| Artifact | Enable with | Default model |
| --- | --- | --- |
| Chewing | `--chewing <episodes/min>` | 100 µV, 4 s rhythmic temporalis episodes at 1.5 Hz. |
| Swallowing | `--swallowing <events/min>` | 120 µV, 1 s double-lobed posterior-neck bursts. |
| Cable movement | `--cable-movement <events/min>` | 150 µV, 3 s broad correlated sway at 0.8 Hz. |
| Sweat | `--sweat <episodes/min>` | 500 µV, 30 s drift on one channel, before referencing. |
| True bridge | `--bridge 3:4,8:9` | Each named pair is replaced by its shared mean signal. |
| Bad reference | `--bad-reference <uv>` | Common 0.2-30 Hz contamination at the requested RMS. |
| Saturation | `--clip <uv>` | Symmetric hard rails, applied after every additive artifact and bridge. |

Amplitude and duration controls use `--chewing-amplitude`,
`--swallowing-duration`, `--cable-amplitude`, and `--sweat-duration`;
`--sweat-channels` controls locality. Matching `--no-*` flags clear scenario
values. Episodic truth is available through `score-events --type chewing`,
`swallowing`, `movement`, or `sweat`.

Simulator Studio exposes sweat rate, drift amplitude, duration, and channels per
episode in the Muscle tab. Amplitude is the nominal excursion before referencing;
each episode varies in amplitude, duration, and polarity. Average referencing
spreads a smaller opposite drift across the other electrodes.

**Large, widespread shifts** sets 1500 µV, six episodes per minute, 30-second
durations, and up to eight electrodes. **Allow overlapping shifts** lets the
requested rate create new episodes during ongoing drift. **Vary amplitude and
polarity by channel** keeps broad shifts from cancelling as a common signal
under average reference. CLI equivalents are `--sweat-overlap` and
`--sweat-vary-channels`, with matching `--no-*` flags.

**GSR channel (linked to sweat)** adds a separate auxiliary conductance channel
in µS. The positive GSR responses follow the EEG sweat episode onsets and smooth
envelopes, scale with absolute episode amplitude, and add when episodes overlap.
The baseline and nominal response default to 2 µS and 1 µS. This is a controlled
synthetic proxy; EEG polarity and referencing do not alter it. Enabling GSR also
enables default sweat when needed; disabling sweat afterward leaves a flat GSR
baseline. CLI controls are `--with-gsr`, `--no-gsr`, `--gsr-baseline`, and
`--gsr-response`. Explicit `--no-sweat` allows baseline-only GSR. Disabling GSR
leaves EEG generation unchanged.

Sweat **Placement** defaults to **Frontal-biased clusters** for new configurations.
The GUI also offers **Frontal only**, **Anywhere**, and **Selected electrodes**.
Frontal preference defaults to 85%: that probability selects the cluster center
from frontal electrodes; otherwise the center is drawn from the full cap. Spread
defaults to 35° and controls the reach and taper of neighboring electrodes.
Frontal classification uses normalized nose-forward y > 0.35, rather than
channel labels, so it also supports imported and dense montages. These thresholds
and defaults are simulation choices.

Frontal-only and selected modes use up to the requested channel count from the
eligible set. Selected electrodes are edited with GUI checkboxes in recording
channel order. Generation reports when the eligible set is smaller than requested
and rejects an empty set. Existing scenarios without placement retain Anywhere.

CLI controls are `--sweat-placement frontal-biased|frontal-only|anywhere|selected`,
`--sweat-frontal-preference 0.85`, `--sweat-spread 35`, and
`--sweat-selected-channels 1,2,5` (which enables selected mode). Placement specifies
the electrodes receiving drift **before referencing**; amplitude remains fully
adjustable. Cluster weights and the actual affected channels are saved in truth.
GSR follows the same sweat episodes for every placement.

### Recording defects

| Option | Default | Notes |
| --- | --- | --- |
| `--bad-channels <spec>` | none | Comma-separated `<channel>:<kind>`, 1-based. `--bad-channels 7` defaults that channel to `noisy`. |
| `--line-noise <hz>` | `0` (off) | Mains frequency. Try `60`. |
| `--line-noise-amplitude <uv>` | `8` | Per-channel pickup varies around this, with slowly wandering amplitude so a fixed notch cannot cancel it perfectly. |
| `--impedance <kohm>` | `12` | Typical impedance of a *healthy* electrode. Channels scatter lognormally around it. |
| `--no-impedance` | off | Record no impedance measurement at all. |
| `--no-impedance-noise` | coupling on | Disable impedance-driven thermal noise and mains scaling. |
| `--electrode-temperature <K>` | `298.15` | Temperature used by the Johnson-Nyquist noise equation. |
| `--impedance-line-exponent <x>` | `1` | Exponent relating contact impedance to mains gain, from 0 to 2. |

Defect kinds:

| Kind | Models | Defeats |
| --- | --- | --- |
| `flat` | Dead or shorted electrode — near-zero signal plus amplifier noise. | Anything that normalizes per channel. |
| `noisy` | High-impedance contact — broadband noise swamping the EEG. | Averaging; variance-based rejection thresholds. |
| `drift` | Slowly failing contact — a large wandering baseline. | Notch filters and amplitude thresholds; needs a high-pass. |
| `pop` | Intermittent electrode pops — sudden steps decaying back over ~1 s. | Epoch rejection. |
| `line` | Heavy mains pickup on one channel only. | The assumption that filtering is a per-recording decision. Requires `--line-noise`. |

Defects are applied to `sim_noisy.mff` only. The ground truth stays clean, so a
correction that fails to recover a dead channel *should* score badly on it.

### Electrode impedance

Both packages carry a per-electrode impedance measurement, written as the `ICAL`
calibration block in `info1.xml` — the same place a real EGI system records it,
and the place EVA reads it from to feed [channel health scoring](../user-guide/health-scoring.md).

Healthy electrodes scatter around `--impedance` (default 12 kΩ). Bad channels get
a value matching their defect:

| Defect | Impedance | EVA health band | Why |
| --- | --- | --- | --- |
| *(healthy)* | ~4-30 kΩ | great | |
| `flat` | **0.4-3 kΩ** | **great** | A bridged or shorted electrode reads *low* — the electrolyte path is too good. |
| `noisy` | 110-220 kΩ | zero | High-impedance contact. |
| `drift` | 65-95 kΩ | fair to poor | Slowly failing contact. |
| `pop` | 75-130 kΩ | poor | Intermittent contact. |
| `line` | 60-100 kΩ | fair to poor | Mains pickup rides on high impedance. |

The operational model uses these same values to generate the samples. Contact
thermal noise has RMS `sqrt(4 k T R B)`, with `B` equal to Nyquist, so its RMS
rises with the square root of impedance. When `--line-noise` is enabled, pickup
scales approximately linearly against a fixed 12 kΩ reference by default, with a small seeded
lead-dress variation. The exact latent impedances, analytic thermal RMS values,
and realized mains gains are written to the truth sidecar.

`--no-impedance` removes the ICAL measurement from both MFF packages but does
not change the latent electrode or its noise. Use `--no-impedance-noise` to
restore the earlier measurement-only model; the paper-default scenario does so
because Grouiller et al. did not specify this coupling. An impedance sweep is
available as `sweep --parameter impedance --values 5,12,40,100`.
The thermal calculation treats the recorded impedance magnitude as an effective
resistance; real electrode-skin impedance is complex and frequency-dependent.

!!! tip "The `flat` case is the one worth teaching"
    Impedance is a useful screen, not a proxy for data quality. It catches the
    electrode that is barely connected and misses the two that are connected to
    *each other*. A bridged channel scores a perfect 1.0 on impedance while
    recording nothing usable. Both the `flat` defect and explicit `--bridge`
    pairs produce this low-impedance exception deliberately.

Impedance is written to **both** packages, including the clean one. That is not
an oversight: EVA treats impedance as a stable property of the recording, scored
independently of the samples, because the measurement was taken before anything
was recorded. Ground-truth data under a poor electrode is a coherent state, and
seeing it makes the point.

Setting `--impedance` high is a legitimate way to model a badly prepped cap —
`--impedance 45` puts the median around 47 kΩ and pushes the worst channels into
EVA's fair band, with no defects involved at all.

### Scanner window

| Option | Default | Notes |
| --- | --- | --- |
| `--pre-scan <s>` | `0` | Quiet time before the sequence starts. |
| `--post-scan <s>` | `0` | Quiet time after it stops. |

The gradient artifact is absent in these windows; **the BCG is not**. That
asymmetry is physical: the cardiac artifact comes from pulsatile motion inside
the *static* B0 field, which is on the whole time the subject is in the bore,
while the imaging artifact only exists while gradients are switching. A recording
that starts before the sequence does therefore shows clean-*looking* EEG that is
already contaminated.

A second, practical reason to use `--pre-scan`: with no lead-in, the first
volume's artifact is clipped by the start of the recording, which makes it differ
from every other volume and puts a small floor under what template subtraction
can achieve.

### Modelling

| Option | Default | Notes |
| --- | --- | --- |
| `--artifact-oversample <n>` | `64` | Internal artifact rate, as a multiple of the output rate. This is what makes the clock-offset model meaningful — the drift is a fraction of an output sample per TR, so the artifact has to exist at a finer resolution than the output grid. |
| `--artifact-anti-alias <f>` | `0.9` | Anti-alias cutoff as a fraction of output Nyquist, standing in for the amplifier's own filter. `0` disables it, modelling an amplifier whose anti-aliasing is inadequate for gradient-rate content. |
| `--no-ecg` | off | Omit the synthetic ECG channel. |
| `--no-motion-sensor` | off | Omit the synthetic motion-sensor channel. |
| `--spatial-model <name>` | `circular` | Grouiller model only. `circular` is the paper's model (smooth across adjacent channel indices, wrapping). `geometric` smooths by real electrode distance. Dipole mode uses its lead field instead. |
| `--spatial-smoothing <n>` | `4` | Kernel width in channels. Means approximately the same amount of smoothing under either spatial model. |
| `--demo` | off | Preset described below. |

### The `--demo` preset

`--demo` is shorthand for these settings, applied *before* any explicit flag, so
anything you also pass still wins (`--demo --line-noise 50` does what it looks
like):

| Setting | Value |
| --- | --- |
| `--blinks` | 15 |
| `--eye-movements` | 25 |
| `--with-emg` | 8 bursts/min |
| `--line-noise` | 60 |
| `--spatial-model` | geometric |
| `--pre-scan` | 15 |
| `--post-scan` | 10 |
| `--bad-channels` | `7:noisy,15:drift` — F8 and Pz on the default montage |

---

### The ECG model

The complex follows the standard synthetic-ECG model:

> McSharry PE, Clifford GD, Tarassenko L, Smith LA (2003). *A dynamical model for
> generating synthetic electrocardiogram signals.* IEEE Trans Biomed Eng
> 50(3):289-294.

P, Q, R, S and T sit at that model's published angles and widths, with amplitude
ratios derived from integrating its z-dynamics. Three things are added on top,
each because leaving it out is what makes a synthetic ECG look drawn rather than
recorded:

- **The QT interval scales with rate but the QRS does not.** In a literal
  angular model everything compresses as RR shortens; a real QRS stays at
  80-100 ms across the physiological range. P and T are scaled as √RR, after
  Bazett; the QRS is left alone.
- **The T wave is asymmetric**, rising more slowly than it falls.
- **Beat-to-beat variability.** Heart-rate variability (`--hrv`) combines
  respiratory sinus arrhythmia at the breathing rate, Mayer waves near 0.1 Hz,
  and a little uncorrelated noise, in the proportions a real tachogram shows.
  R amplitude also breathes by a few percent, because respiration moves the heart
  in the chest.

Without HRV the RR interval walks smoothly and monotonically from beat to beat,
which no living heart does. The default of 4% puts the RR standard deviation at
around 5-6% of the mean, inside the 3-8% a resting adult shows.

!!! note "HRV is EVA's addition, not the paper's"
    The paper's cardiac timing is a smooth 60 s sine with no beat-to-beat
    variability. `--hrv 0` restores it exactly, which is the setting to use when
    reproducing their figures. HRV changes beat *times*, so it affects the BCG as
    well as the ECG.

## Montage and electrode positions

Channels are a real 10-20 montage. At the default 20 channels that is the
standard 19 electrodes plus Oz, ordered front to back:

```
Fp1 Fp2 F7 F3 Fz F4 F8 T7 C3 Cz C4 T8 P7 P3 Pz P4 P8 O1 Oz O2
```

- **Below 20 channels** the set is *subsampled across the head* rather than
  truncated. Truncating a front-to-back ordering would hand back an all-frontal
  montage.
- **21 to 41 channels** fills out from the 10-10 system (Fpz, AF7/AF3/AF4/AF8,
  FT7/FC5/FC1/FC2/FC6/FT8, TP7/CP5/CP1/CP2/CP6/TP8, PO7/PO3/PO4/PO8).
- **Above 41** falls back to a Fibonacci spiral over the scalp, named
  `Spiral (synthetic)` so it cannot be mistaken for a real montage.

Positions follow the 10-20 construction directly for the midline and outer ring,
and are accurate to within a few degrees for the intermediate and 10-10 sites.
That is adequate for simulating where a blink is large and for drawing a
recognizable head map. It is not a digitized montage and should not be used as
one.

!!! note "The circular spatial model and real geometry disagree"
    Under the default `--spatial-model circular`, EEG channels are made
    correlated by smoothing across adjacent *channel indices*, which is the
    paper's model and has nothing to do with where the electrodes are. Because
    the montage is ordered front to back it is roughly anatomical anyway, but
    topographic maps of the ongoing EEG will look more convincing under
    `--spatial-model geometric`. Ocular topographies always use real positions
    regardless of this setting.

---

## Scoring a correction

The workflow is: generate, correct in EVA, export, score.

!!! tip "To compare several methods, don't do this by hand"
    Scoring one correction is what `score` is for. Comparing *methods* — the same
    recordings through every correction EVA offers, with mean ± SD over seeds and
    the difference between two methods measured on the same recording — is
    automated by [Method Comparison](method-comparison.md), which drives EVA
    headlessly and calls this subcommand for every cell.

```bash
Tools/EVASimulate/.build/eva-simulate score \
  --truth ~/sim/sim_clean.mff \
  --corrected ~/sim/corrected.mff \
  --baseline ~/sim/sim_noisy.mff \
  --label "OBS, 4 components"
```

| Option | Default | Notes |
| --- | --- | --- |
| `--truth <clean.mff>` | *required* | The `sim_clean.mff` from `generate`. |
| `--corrected <file.mff>` | *required* | Your corrected recording, exported from EVA. |
| `--baseline <noisy.mff>` | — | Also score the uncorrected recording, adding `uncorr` and `gain` columns. Strongly recommended. |
| `--label <name>` | filename | Name for this correction in the output. |
| `--pad-seconds <s>` | `2` | Ignore this much at each end, where filter edge effects live. |
| `--csv <path>` | — | Also write the per-band table as CSV, for plotting or for collecting many runs. |
| `--json <path>` | — | Also write the full result as JSON. |

Channel count and sampling rate must match between truth and corrected, and the
tool refuses with a clear message rather than silently comparing mismatched data.

### Reading the output

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
```

| Column | Meaning |
| --- | --- |
| `SNR` | `std(clean) / std(clean − corrected)` within the band. The paper's Equation 2. Higher is better. |
| `uncorr` | The same figure for the uncorrected recording (needs `--baseline`). |
| `gain` | `SNR / uncorr`. **Below 1.0 means the correction made that band worse than leaving it alone.** |
| `power dB` | `10·log10(corrected band power / clean band power)`. Catches over-filtering. |
| `clean RMS`, `resid RMS` | Band-limited RMS of the ground truth, and of what the correction got wrong, in µV. |

Read SNR and `power dB` together. SNR is normalized, so it cannot distinguish
signal *attenuation* from *amplification* — a method that halves the EEG and one
that doubles it can land on the same number. A high SNR with a strongly negative
`power dB` is a method quietly deleting your signal, which the paper warns is the
real hazard.

The band structure is the paper's: 4 Hz wide to 20 Hz, then 5 Hz wide to 70 Hz.
Band power comes from a Welch periodogram (Hann window, 4096-sample segments, 50%
overlap), which keeps the enormous low-frequency content of an uncorrected
recording from leaking upward and making a broken correction look fine at 60 Hz.

!!! tip "The table is also a check on the model"
    In the example above the worst bands are 12-16, 25-30, 40-45 and 50-55 —
    the harmonics of the 13.67 Hz slice rate (3 s ÷ 41 slices). A slice-rate comb
    is exactly what a real EPI artifact produces. Alpha survives best because the
    comb has a null near 8-12 Hz and alpha is the largest thing in the EEG.

---

## Single-subject sweeps: generate and evaluate

The **Sweep** tab and CLI use the same parameter registry. A sweep changes the
current Generate-tab scenario for one subject; seed repetitions are repeated
simulations, not a cohort. Group sweeps are not implemented.

In the GUI, choose an axis, its values, and any condition/peak scope. **Example
values** fills a suitable list. Enter either `0, 15, 30, 60` or an inclusive
`start:stop:step` range such as `0:60:15`. Enable **Two-axis grid** to cross every
value of one parameter with every value of another. The recording count is shown
before running: first-axis values × second-axis values × seed repetitions.
Every new control has contextual **?** help.

### Axes and scope

| Category | CLI parameter names | Units / scope |
|---|---|---|
| Response variability | `erp-latency-jitter`, `erp-peak-jitter` | ms SD; whole experiment |
| Gain/width variability | `erp-amplitude-jitter`, `erp-width-jitter` | Fraction SD; whole experiment |
| Peak shape | `erp-peak-amplitude`, `erp-peak-latency`, `erp-peak-width` | µV, ms, ms σ; all peaks, one condition, or one peak |
| Peak presence | `erp-peak-occurrence` | Fraction of responding trials; peak scope |
| Mixtures | `erp-inverted`, `erp-attenuated`, `erp-divergent` | Fractions; all conditions or one condition |
| Recipe severity | `erp-attenuated-gain`, `erp-divergent-shift` | Fraction gain, extra ± ms; condition scope |
| Divergent width | `erp-divergent-width-min`, `erp-divergent-width-max` | Positive width multipliers with min ≤ max; condition scope |
| Omissions/count | `erp-omission-rate`, `erp-trials` | Fraction, integer; whole experiment |
| Allocation | `erp-condition-share` | Fraction; one selected condition required |
| Timing | `erp-isi`, `erp-isi-jitter` | Seconds; whole experiment |
| Noise | `erp-noise`, `background-gain` | Added sensor µV RMS, multiplier of base background EEG SD |
| Cardiac artifacts | `bcg-amplitude`, `qrs-jitter`, `bcg-latency`, `bcg-morphology` | µV, ms SD, ms SD, fraction |
| Scanner | `gradient-amplitude`, `clock-offset`, `slow-modulation` | µV, µs/s, fraction |
| Other artifacts | `blink-rate`, `blink-amplitude`, `emg-rate`, `emg-amplitude` | Events/min, µV, bursts/min, µV |
| Recording/model | `rate`, `impedance`, `sources`, `bad-channel-fraction` | Hz, kΩ, integer, fraction rounded to channel count |

ERP axes require an editable experiment, enabled in **Generate → ERP** or with
`--erp-experiment` / inline `--erp-condition` definitions. Complex legacy ERP
models are not silently converted. Global jitter, noise, omissions, and scheduling
cannot currently be restricted to one condition.

Use `--condition ID` to restrict a condition/peak axis, and `--peak ID` to select
one peak within that condition. Without these flags, the setting applies to all
eligible conditions/peaks. Axis 2 uses `--condition2` and `--peak2`. Condition-share
sweeps redistribute other shares proportionally; if all others have zero shares,
they divide the remainder equally. Recipe fractions consume the Typical remainder
and leave other recipes fixed. Totals above 1 fail validation. All fractions use
**0–1**, not percentages; trial and recipe allocations still round to actual counts.

Background gain changes the calibrated background amplitude, preserving its
spectral proportions. Gradient amplitude preserves the base minimum/maximum
ratio. BCG amplitude/latency axes enable BCG; BCG morphology also selects the
spatial generator model. Blink amplitude requires a nonzero blink rate. EMG rate
zero disables bursts. Clock offset requires gradients; QRS jitter requires BCG.
Bad-channel fraction requires no explicitly named bad channels and uses the base
placement/defect settings. Source count requires the dipole EEG model.

### Example: jitter × noise with repeated seeds

```bash
Tools/EVASimulate/.build/eva-simulate sweep \
  --erp-experiment --erp-trials 80 \
  --parameter erp-latency-jitter --values 0:60:15 \
  --parameter2 erp-noise --values 0,1.5,5 \
  --repeats 5 --seed 42 \
  --evaluate average --eval-channel 1 \
  --no-gradient --no-bcg --no-impedance-noise \
  --output ~/sweeps/jitter-noise
```

This produces 75 recordings. The same five seeds are used at every grid point;
the first is the base seed and the rest are deterministically derived from it.
Independent model streams preserve unrelated draws where possible. Changing a
schedule, duration, or legacy model structure can still change realized samples.

For a condition-specific mixture sweep, replace the axes above with:

```bash
--parameter erp-inverted --condition target --values 0:0.5:0.1
```

For one selected peak:

```bash
--parameter erp-peak-latency --condition target --peak p1 --values 200,300,400
```

Recording duration automatically extends for editable ERP schedules, including
response tails and evaluation post-stimulus windows. `--sweep-fixed-duration`
keeps the base duration; a waveform extending outside it fails preflight. Missing
pre-stimulus baselines are excluded from evaluation and reported in counts.
Every cell is validated before any recordings are generated. Existing run
folders are rejected rather than overwritten. Each axis supports up to 1000
values, repetitions range from 1–100, and a sweep is limited to 10,000 recordings.

### Generate + Evaluate

Choose a GUI evaluation mode or pass `--evaluate`:

- `none`: generate recordings and broadband SNR only (default).
- `average`: baseline-correct and average complete ERP epochs for every condition.
- `reject`: first reject any noisy epoch whose peak-to-peak amplitude on **any**
  EEG channel exceeds `--eval-reject` (default 120 µV), then average the survivors.

These initial pipelines use **unfiltered** data. They do not perform artifact
correction or TrialsView classification. Decisions use noisy data only. The
reference is the average of **all complete clean epochs**, including omitted
responses, background EEG, and overlapping responses. The estimate averages
retained noisy epochs, so trial-selection distortion contributes to the error.
This measures recovery of the clean recording average, not recovery of an
isolated Gaussian component or agreement with generation recipe labels.

| Evaluation flag | Default | Meaning |
|---|---|---|
| `--eval-pre` | 0.2 s | Pre-stimulus epoch length and baseline interval |
| `--eval-post` | 0.8 s | Post-stimulus epoch length |
| `--eval-peak-start` | 0.05 s | Peak search start |
| `--eval-peak-end` | 0.7 s | Peak search end, within post-stimulus epoch |
| `--eval-channel` | 1 | Fixed one-based EEG channel for peaks |
| `--eval-reject` | 120 µV | Unfiltered peak-to-peak rejection threshold |

Each condition reports scheduled trials, complete candidate epochs, retained
trials, retention fraction, post-stimulus waveform RMSE and Pearson correlation
across all EEG channel/sample pairs, clean/measured peak amplitudes and latencies,
and their signed measured-minus-clean errors. Peaks are the largest absolute
signed deflection in the fixed channel/search window. Narrow the search window
when targeting a component; a broad window can switch between components.
Clean peak amplitude is useful for seeing how jitter/mixtures change the clean
average even when noisy-to-clean recovery error is small.

No complete epochs or no retained trials produces an explicit status and missing
recovery metrics. Constant waveforms have undefined correlation; a zero clean
response has no defined peak. These are not reported as successful zero errors.
Infinite/undefined broadband SNR is stored as missing in JSON and excluded from
finite aggregate statistics. A zero added-noise setting does not remove other
artifacts or default impedance noise; disable these explicitly for an identity
check, as in the example above.

### Outputs and results

Every run contains clean/noisy MFFs, trial truth, a resolved `scenario.json`, and
`evaluation.json`. The sweep root contains:

- `sweep_results.json`: plan, evaluation settings, base/repetition seeds, relative
  run directories, and all per-condition results.
- `sweep_summary.csv`: one row per recording, with values, repetition, seed, and
  uncorrected broadband SNR.
- `sweep_aggregates.csv`: per-cell/condition/metric means, sample SD, and valid n.

The GUI plots means with **sample SD**, not confidence intervals, across seed
repetitions. For grids, each second-axis value gets a separate line. Select a
condition and metric, inspect n and missing-result notices, or open any recording.
One valid repetition has no SD. Undefined values are excluded and reflected in n.
For QRS jitter, uncorrected broadband SNR can remain unchanged because only event
timestamps change; these ERP pipelines do not use QRS markers for correction.

---

## Evaluating source-informed BCG correction (PCA-S)

`generate` / `score` measure any correction you can run through a file. Two extra
subcommands measure **PCA-S** (the source-informed / Berg–Scherg BCG correction)
directly and in memory, without writing MFFs, by generating clean + BCG-noisy
recordings over many seeds, correcting them, and scoring against the clean truth.
They are the workhorses behind the SI-4 adversarial evaluation.

```bash
# One condition, repeated over seeds, with the full metric set.
Tools/EVASimulate/.build/eva-simulate evaluate-surrogate \
  --seeds 30 --pattern-search iterative

# Cross one axis and write an aggregated CSV — the campaign workhorse.
Tools/EVASimulate/.build/eva-simulate evaluate-surrogate-grid \
  --axis bcg-morphology-jitter --values 0,0.1,0.2,0.4,0.8 \
  --seeds 30 --pattern-search iterative --output jitter.csv
```

`evaluate-surrogate-grid` axes: `duration`, `channels`, `rate`, `components`,
`brain-regularization`, `sources`, `offset`, `max-beats`, `bcg-morphology-jitter`,
`correction-scalp-radius`, `correction-skull-ratio`, `correction-electrode-jitter`.
Every other option fixes the base condition. Each row reports corrected and
uncorrected SNR (mean ± SD over seeds), clean distortion (dB), removed-variance
fraction, and accepted-beat fraction.

Read the two SNR columns together: **the bar to clear is the uncorrected column.**
A corrected value below it means the correction hurt. A removed-variance fraction
climbing toward or past 1.0 is a distortion signature, not a quality one.

!!! note "`--pattern-search` defaults to `iterative`, the mode EVA ships"
    `iterative` refines the artifact template from the average of accepted beats
    and is what the EVA app corrects with, so it is the default here too. The only
    alternative, `paper`, is the single-representative-beat method retained to
    reproduce Rusiniak et al. (2022); at these settings it accepts a small fraction
    of beats and its topographies point partly at brain, so PCA-S can land *below*
    uncorrected — a comparison-arm artifact, not a bug in the shipped correction.
    Pass `--pattern-search paper` only for an explicit paper-parity run.

### Operating envelope of PCA-S (the important case)

The SI-4 Track-2 campaign (2026-09-12; 30 seeds/point; iterative mode; full
tables and raw CSVs in `docs/provenance/pca-s-adversarial-evaluation.md`) measured
where PCA-S helps and where it stops. At the default condition PCA-S gains about
**1.65×** broadband SNR (corrected 2.08 ± 0.76 vs uncorrected 1.26). The SD is
about half the gain — a difference smaller than one SD is not a result.

| Axis | Safe | Breaks / degrades |
|---|---|---|
| Accepted beats | ~40+ | ≤ ~30 beats → at or below uncorrected (the dominant driver) |
| Recording length | ≥ 120 s | < 60 s (margin within one SD) |
| BCG morphology variability | jitter ≤ 0.2 | ≥ 0.4 crosses below uncorrected; 0.8 fails |
| Electrode/montage mismatch | ≤ 5° | ~10° co-registration error breaks it |
| Artifact components | 3–4 (optimum ~3) | ≥ 6 removes brain signal |
| Channels 20–256, rate, sources ≥ 29, basis offset ≤ 20 mm, skull ratio, scalp radius, regularization | robust | no breakpoint in range |

!!! note "This is a native reimplementation, and its direction is sound"
    The `evaluate-surrogate` operator (`SourceInformedSeparation`) reconstructs the
    brain subspace; it is not a subtraction that could be sign-flipped. The
    identical operator gains ~1.8× the moment it is fed good artifact topographies,
    so where PCA-S underperforms the cause is upstream beat acceptance / template
    quality, never a reversed correction.

!!! warning "Simulator variance is narrower than a real subject's"
    Every SD above is realization noise on one generator model. The only axis that
    injects structural beat-to-beat variability — morphology jitter — is also the
    axis that breaks PCA-S. Real BCG adds non-stationary morphology, respiration
    coupling, movement-locked amplitude changes, and electrode drift that this
    harness does not model, so these safe zones are necessary, not sufficient. Treat
    a passing simulation as a floor on the failure rate, not a ceiling.

---

## Evaluating artifact reduction (any method)

PCA-S has its own harness above. These three tools are method-agnostic — they
measure *any* cleaning step against ground truth, and they exist because
"removed variance" is not a quality score on its own (the source of
`CleaningVarianceAccount` says exactly that). Each answers a different honest
question.

### `score-cleaning` — what a run-time number means

A live correction can compute how much variance it removed *without* truth. This
ties that number to the truth so a Good/Watch/Poor band can be set on it, per
method.

```bash
eva-simulate generate --output ~/sc --no-gradient --with-bcg --duration 120
eva-simulate correct --input ~/sc/sim_noisy.mff --output ~/sc/sim_corrected.mff \
  --assume-standard-montage
eva-simulate score-cleaning --clean ~/sc/sim_clean.mff --noisy ~/sc/sim_noisy.mff \
  --corrected ~/sc/sim_corrected.mff
```

It reports `removed_variance_fraction` (run-time, no truth) beside
`residual_error_fraction`, corrected/uncorrected SNR, and
`artifact_reduction_fraction` (1 = perfect, 0 = did nothing, **negative = made it
worse**). Correlating removed-variance against artifact-reduction across many runs
is how a band gets calibrated: a high removed-variance with a negative reduction
is a method deleting brain, not artifact.

### `evaluate-retention` — "can I save this data?"

The user-facing question for blink cleaning is rarely "how much artifact came
out" — it is "can I keep these hard-won trials instead of throwing them away." For
an ERP experiment where blinks contaminate some trials, this compares three
strategies against the true ERP:

| Strategy | What it does |
| --- | --- |
| reject | drop contaminated trials, average the survivors — unbiased, but fewer trials |
| keep-dirty | average every trial uncorrected — more trials, but blink bias |
| clean & keep | correct then keep every trial — the win, *if* the correction didn't bias the component |

```bash
eva-simulate evaluate-retention --seeds 20 --blinks 150
```

It reports trials kept, ERP-average SNR, and peak amplitude/latency bias per
strategy (built-in cleaner: Gratton–Coles VEOG regression). The result is
regime-dependent, which is the point: at light contamination, rejecting is cheap
and regression can *add* bias; at heavy contamination, clean-and-keep saves many
trials and lowers bias. Cleaning wins only when it lifts SNR without biasing the
peak — and the harness will tell you when it doesn't.

!!! note "For removal-only methods, the question becomes detection"
    A technique that flags rather than corrects doesn't save trials directly; the
    honest test is whether threshold-based artifact detection still catches what
    it should afterward. Use `score-events` (detection vs truth) before and after.

### `--source-burstiness` — honest sources for ICA and BSS

The paper EEG is band-limited **Gaussian**, which is close to pathological for
methods that separate sources by statistics: ICA is only identifiable when at
most one source is Gaussian, and BSS-CCA relies on a non-Gaussian marginal. So
evaluating ICA on the default sources would measure the simulator, not the method.

`--source-burstiness <0–1>` (dipole model only) makes the sources bursty and
super-Gaussian via a slow amplitude envelope — band-preserving and RMS-preserving,
so amplitudes and SNR are unchanged and only the *shape* of the distribution
moves. `0` is the exact Gaussian paper model, so scenarios that omit it are
byte-identical.

```bash
eva-simulate generate --output ~/ica --eeg-model dipole --source-burstiness 0.8
```

### `score-mixing` — ICA unmixing quality

Scores an estimated unmixing matrix against the true source mixing with the Amari
performance index (0 = perfect separation, higher = source leakage). Export the
true mixing from a dipole recording, run your ICA, then score its unmixing:

```bash
eva-simulate generate --output ~/ica --eeg-model dipole --source-burstiness 0.8 \
  --write-mixing ~/ica/A.json
# ...run ICA, save its unmixing W as sources × channels JSON...
eva-simulate score-mixing --true-mixing ~/ica/A.json --unmixing ~/ica/W.json
```

Only meaningful on non-Gaussian sources — hence the `--source-burstiness`.

### `--bcg-generators` — spatial rank for OBS

`--bcg-generators <1–4>` (generators BCG model) sets how many physical generators
are active, and so the artifact's spatial rank. An OBS-style correction keeps the
top-k principal components of the beat-aligned epochs, so varying the true rank is
how you find where it keeps too few (residual left) or too many (brain eaten).

### `score-preservation` — did a cleaner keep the real brain transients?

A wavelet reducer that thresholds transient coefficients will happily delete a
real K-complex or sharp wave — oversmoothing. The only way to catch it is to seed
genuine sharp *brain* features and check they survived. `--brain-transients
<per-min>` adds K-complexes, spindles and sharp waves to the clean EEG (they're
brain, not artifact — central-maximal, with per-event truth), and
`score-preservation` reports how much of each survived, per type.

```bash
eva-simulate generate --output ~/wav --eeg-model dipole --brain-transients 20 \
  --write-transients ~/wav/T.json
# ...run the wavelet reducer, save its output...
eva-simulate score-preservation --clean ~/wav/sim_clean.mff \
  --corrected ~/wav/reduced.mff --transients ~/wav/T.json
```

1 = kept intact, 0 = flattened, negative = distorted. A reducer that oversmooths
scores low, most visibly on the sharpest type (sharp waves).

### `--emg-autocorrelation` — the BSS-CCA muscle stressor

BSS-CCA separates muscle from brain by *autocorrelation*: surface EMG is broadband
(low autocorrelation), brain is not. `--emg-autocorrelation <0–0.99>` colors the
EMG carrier (AR-1) toward brain-like autocorrelation, so the separation can be
pushed until it fails — with brain gamma present, that failure shows up as gamma
lost from the cleaned data (`score`'s per-band SNR). Default off (broadband).

---

## Recipes for teaching

With `--demo`:

| To show | Look at |
| --- | --- |
| Raw versus filtered | The whole trace: mains hum on every channel, drift on Pz, gradient artifact from 15 s. |
| What a blink looks like | `blnk` markers; Fp1/Fp2 against Cz. Frontal-maximal, with a slight reversal posteriorly. |
| Blinks versus eye movements | `eyem` markers. Blinks are transients; eye movements are **steps** that hold until the eyes move again, with opposite polarity at F7 and F8 — because the scalp potential follows gaze *position*, not gaze velocity. |
| Why we keep an EOG | The VEOG/HEOG channels see the same artifact far larger than any scalp electrode. |
| Muscle versus neural gamma | `emg` markers; compare F7/F8 and Oz with Cz. Muscle is broadband, bursty, and spatially local. |
| Bad channel detection | F8 (noisy) and Pz (drift) against their neighbours. |
| Impedance vs. data quality | Health scoring on a recording made with `--bad-channels "3:flat,7:noisy"`: one channel scores poor on impedance and looks bad; the other scores *perfect* on impedance and is flat. |
| Why notch filtering is per channel | Add `--bad-channels "3:line"` — one contaminated channel, the rest clean. |
| The scanner turning on | 15 s in. Before that the EEG looks clean but already carries the BCG. |
| Ground truth | `sim_clean.mff` is the same EEG with none of it. Overlay them. |

Smaller, more focused recordings:

```bash
# Just blinks on clean EEG — nothing else to distract from them.
eva-simulate generate --output ~/blinks --no-gradient --no-bcg --blinks 18 --duration 60

# Bursty temporalis and posterior-neck EMG on otherwise clean EEG.
eva-simulate generate --output ~/emg --no-gradient --no-bcg --emg 12 --duration 120

# One bad channel of each kind, side by side.
eva-simulate generate --output ~/bad --no-gradient \
  --bad-channels "3:flat,7:noisy,11:drift,15:pop,19:line" --line-noise 60

# Filtering practice: mains hum and drift, no MR artifacts at all.
eva-simulate generate --output ~/filtering --no-gradient --no-bcg \
  --line-noise 60 --blinks 15 --duration 120

# Cardiac artifact alone, with a clean ECG to detect from.
eva-simulate generate --output ~/bcg --no-gradient --bcg-amplitude 150
```

!!! warning "The gradient artifact swamps everything else"
    Its amplitude varies strongly across the head by design — the paper varies it
    from 0 to 7000 µV peak-to-peak between channels, and here it scales with arc
    angle from the vertex, so Cz sees the least and the temporal sites the most.
    During scanning that buries a deliberately bad channel completely. Inspect bad
    channels in the pre-scan window, after gradient correction, or with
    `--no-gradient`.

---

## What comes from the paper and what does not

This matters when interpreting a result: a finding that turns on a parameter the
paper measured is stronger evidence than one that turns on a shape this tool
invented.

**From the paper, used verbatim.** Seven band-limited Gaussian EEG sources over
1-70 Hz with a 45-55 Hz notch gap and a target SD of 10.9 µV; alpha modulated
10 µV to 30 µV on a 20 s alternation; spatial correlation as circular
connectivity smoothed with an SD-4-channel kernel; TR 3 s with 41 slices and
~60 ms of artifact per slice; gradient amplitude varying to 7000 µV peak-to-peak
across channels; the 152 µs/s clock offset; slow amplitude modulation as a 200 s
sine at 10% of the mean; heart rate 65-85 bpm on a one-minute cycle; BCG mean
amplitude 10-200 µV; beat-to-beat amplitude weighting the previous beat and a
fresh 15% draw equally; 15 ms SD channel latency; 25 ms SD QRS detection jitter;
the sigmoid motion-sensor nonlinearity at gain 0.1; and the SNR metric with its
evaluation bands.

**EVA's own.** Heart-rate variability and the respiration model (`--hrv 0`
restores the paper's timing); the ECG morphology, which follows McSharry et al.
(2003) rather than the paper, which does not specify one; the *shape* of the
gradient waveform (built as the time derivative
of a modelled slice-select trapezoid plus EPI readout train, since induced EMF
goes as dB/dt — use `--gradient-template` to substitute a measured one); the
shape of the BCG waveform; the synthetic ECG and its morphology; the per-band
amplitudes of the seven EEG sources; the anti-alias model; gradient amplitude
scaling with electrode position rather than channel index; and everything under
ocular and orofacial artifacts, cable movement, sweat, true bridging,
bad-reference contamination, clipping, recording defects, the montage and the
scanner window — all of which are off by default, so the benchmark numbers are
unaffected by their existence.

The opt-in non-stationarity layer is also EVA's: lognormal alpha-burst renewal,
sin² spindle envelopes, independent per-band log-amplitude OU processes,
generated microstate maps and dwell times, and cosine phase-amplitude gain.
These are controlled validation laws, not fitted physiological claims; all
realized truth is retained so results can be stratified by the actual draws.

---

## Limitations

Stated plainly, because a harness whose limits are unstated gets over-trusted.

- **The paper-compatible default EEG is stationary.** Use
  `--with-nonstationarity` for ICA/PAC experiments and sweep its controls; one
  phenomenological stochastic model still cannot establish population realism.
- **Microstates are generated sensor-space maps.** In dipole mode they are an
  additional known component, not an intracranial source in `_sources.mff`, and
  they do not reproduce subject-specific canonical microstate classes.
- **The default spatial model is circular, not anatomical.** Methods that exploit
  real topography — EVA's topography-gated, -aligned and -weighted OBS strategies
  — are being handed a spatial structure no montage produces. Use
  `--eeg-model dipole` for a spherical volume conductor, and evaluate those
  methods on real data too; a sphere is still not individual anatomy.
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
- **One template shape for all channels.** Real gradient artifacts differ in
  shape, not only in scale, across the montage.
- **The muscle models use fixed source regions and controlled carrier
  families.** EMG, chewing, and swallowing do not model subject-specific muscle
  anatomy, motor-unit recruitment, or individual volume conduction.

### Event-time precision

MFF stores event times as absolute ISO-8601 datetimes, and event positions
survive a write/read round trip at **microsecond** precision, at any sampling
rate.

This was not always the case, and it is worth knowing if you are reading older
output. Both halves of the round trip used to quantize to 1 ms: `DateFormatter`
carries millisecond internal precision no matter how many fractional digits are
requested, and `ISO8601DateFormatter`'s fractional-seconds parsing truncates past
three digits. At 1024 Hz a sample is 0.977 ms, so markers could move by half a
sample and a generated recording was sometimes rejected with *"TRs are not
evenly spaced"*. Rates whose sample period is a whole millisecond — including the
1000 Hz operational default — were never affected.

Both sides are now fixed, and `scenarios/paper-default.json` runs at the paper's
1024 Hz with every marker recovering its exact sample index.

---

## Self-test

```bash
Tools/EVASimulate/.build/eva-simulate selftest
```

Sixty passing outcomes on the *model* rather than on any EVA code. Run it after changing
anything in the model: a harness that silently stops reproducing the phenomenon
it exists to study is worse than no harness, because everything it emits still
looks like evidence.

| Check | What it pins |
| --- | --- |
| Locked clocks hit the √N ceiling | With `--clock-offset 0`, the artifact cancels *exactly* and the only residual is the EEG the template averaged in, at `std(EEG)/√N`. So a "perfect" naive average-artifact subtraction over 19 volumes scores 4.36, not infinity. |
| Drifting clocks fall far below it | The paper's 152 µs/s drift takes the same subtraction to ~0.06. |
| QRS jitter penalizes timing-dependent correction | Subtraction at the jittered beat times scores below subtraction at the true ones. |
| Templates start and end at baseline (×3) | A template still non-zero where its window closes injects a step discontinuity at *every* event — a square edge repeating at the heart rate or blink rate. Checked for the BCG, blink and gradient waveforms. |
| TR markers stay within EVA's tolerance | The 1000 Hz default preserves the intentionally drifting trigger train through the millisecond timestamp round trip. |
| No gradient artifact before the scanner starts | |
| BCG continues through the pre-scan window | |
| Blink topography is frontally maximal | Peaks at Fp1/Fp2 and vanishes at the vertex. |
| EMG truth and markers are deterministic | The same seed reproduces every burst sample and duration marker. |
| EMG is bursty and broadband | Samples are zero outside truth windows and 20-200 Hz power dominates 1-15 Hz. |
| EMG topographies are localized | Left/right temporalis peak laterally and posterior-neck activity peaks near Oz. |
| Chewing/swallowing truth is deterministic | Samples, durations, and distinct event codes repeat exactly. |
| Cable movement versus sweat | Movement is broad; sweat changes exactly its recorded local channels. |
| True bridging | A requested pair becomes sample-identical at its shared mean. |
| Bad reference | Every channel receives the exact same common contamination. |
| Saturation | Only out-of-range samples hit symmetric rails and counts match. |
| Impedance tracks the defect (×3) | Healthy electrodes stay inside the good band; poor-contact defects read high; and a bridged electrode still reads **low** despite recording nothing. |
| Impedance drives recording noise (×3) | Johnson RMS follows √R and disables cleanly; mains pickup rises with R; explicit bridges retain deceptively low impedance. |
| Centered dipole matches a closed form | A central dipole in one homogeneous insulated sphere matches `3 p·r̂ / (4πσR²)`, including physical units. |
| Shell and rotation invariants (×2) | Equal-conductivity boundaries disappear, and jointly rotating a source and every sensor preserves the field. |
| Lead-field reference and orientation (×3) | Average-referenced fixed and free `x/y/z` columns sum to zero, and reversing a dipole reverses every potential. |
| Source catalog and artifact isolation (×2) | Adding sources preserves existing source metadata and cannot change the BCG realization. |
| Dipole amplitude and determinism (×2) | Projection reaches `--eeg-std`, and repeated generation is sample-identical. |
| Lead-field convergence | The 100→200-term change stays below 0.01% across eccentricities; an under-resolved 10-term case is rejected. |
| Correlated-source band identity | Mixed S001/S002 waveforms share one declared configured band. |
| One recording reference | Average reference produces zero channel mean at the additive boundary; infinity leaves native voltages unchanged. |
| ERP stream isolation and overlap (×2) | Trial-count changes preserve unrelated factor draws; dense component windows receive directional overlap flags. |
| Non-stationarity is deterministic and opt-in | The stationary default remains unchanged; samples and complete truth repeat for one seed. |
| Alpha bursts and slow spectra (×2) | Burst counts/quiet intervals and continuously correlated per-band envelopes satisfy their controls. |
| Microstates and PAC (×2) | Distinct 40–250 ms map episodes switch without immediate repeats, and gamma amplitude peaks at the recorded phase. |

Two facts worth carrying away from those checks:

- **Naive AAS has a ceiling of √N.** Any method scoring meaningfully above it is
  doing something smarter than a global average; any method well below it on
  locked-clock data has a problem.
- **Slice spacing is usually not a whole number of samples.** In the 1024 Hz paper scenario with
  TR 3 s and 41 slices, one slice is 74.93 samples, so slice artifacts never
  repeat their sub-sample phase even with clocks perfectly locked. That is why
  IAR and FASTR interpolate to ~10 kHz before attempting slice-level alignment.

---

## Reproducibility

Two runs of the same seed produce byte-identical packages and sidecars. All
randomness comes from seeded SplitMix64 generators, the recording timestamp is
fixed rather than taken from the clock, and JSON is written with sorted keys.
Dipole mode derives stable named streams for each neural source and artifact
family, so changing source count does not change BCG, ocular, defect, impedance,
or contact-noise draws. A benchmark that moved between runs could not support a claim about which
method is better.

Runtime for the defaults (20 channels, 180 s, 1000 Hz) is about 6 seconds,
producing about 30 MB.
