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

```bash
sh Tools/EVASimulate/build.sh
```

The binary lands at `Tools/EVASimulate/.build/eva-simulate`. Every example below
assumes you are at the repository root; substitute the full path if not.

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
| Sweat | `--sweat <episodes/min>` | 100 µV, 15 s drift on one channel. |
| True bridge | `--bridge 3:4,8:9` | Each named pair is replaced by its shared mean signal. |
| Bad reference | `--bad-reference <uv>` | Common 0.2-30 Hz contamination at the requested RMS. |
| Saturation | `--clip <uv>` | Symmetric hard rails, applied after every additive artifact and bridge. |

Amplitude and duration controls use `--chewing-amplitude`,
`--swallowing-duration`, `--cable-amplitude`, and `--sweat-duration`;
`--sweat-channels` controls locality. Matching `--no-*` flags clear scenario
values. Episodic truth is available through `score-events --type chewing`,
`swallowing`, `movement`, or `sweat`.

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

## Sweeping a parameter

```bash
Tools/EVASimulate/.build/eva-simulate sweep \
  --parameter qrs-jitter --values 0,10,25,50 \
  --output ~/sweeps --duration 120
```

One `generate` per value, into `~/sweeps/qrs-jitter-0/`, `qrs-jitter-10/` and so
on, plus `sweep_summary.csv` at the top listing each run's uncorrected broadband
SNR and directory. `--prefix` applies inside each subdirectory.

Sweepable parameters: `qrs-jitter`, `bcg-amplitude`, `gradient-amplitude`,
`slow-modulation`, `clock-offset`, `rate`. Any `generate` option may be passed
alongside and applies to every run.

!!! note
    For `qrs-jitter` the summary's baseline SNR is identical across runs, and that
    is correct — jitter perturbs only the event times written to the file, never
    the signal. The column is informative for the amplitude sweeps.

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
