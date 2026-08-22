# EVA Simulate — ROADMAP

Planning document for `Tools/EVASimulate`. Written 2026-08-21.

The tool started as a benchmark harness: reproduce Grouiller et al. (2007)'s
forward model, generate EEG with known ground truth, and measure what EVA's
artifact-correction methods actually do to the signal underneath. It has since
grown a teaching role — blinks, eye movements, bad electrodes, mains hum, a real
montage, impedance — and the obvious next step is the one that motivates this
file: **making it good enough to carry a methods paper.**

That is a higher bar than either of its current jobs. A benchmark only has to be
consistent. A teaching recording only has to be recognizable. A simulator that
underwrites a published claim has to be *defensible* — every departure from
physiology has to be either justified or declared, and a reviewer has to be able
to regenerate the exact data.

---

## Completion status

This table is the authoritative progress summary. A checkmark means the item is
implemented, tested, and documented—not merely started.

| Item | Status | Note |
| --- | --- | --- |
| 1.1 Source-space simulation | ✅ Complete | Delivered 2026-08-21. |
| 1.2 ERPs with trial variability | ✅ Complete | Delivered 2026-08-21 with average and single-trial scoring truth. |
| 1.3 Non-stationarity | ✅ Complete | Delivered 2026-08-21 with bursts, spectral dynamics, microstates, and PAC truth/scoring. |
| 2.1 More artifact types | ✅ Complete | Delivered 2026-08-21 across all seven requested artifact families. |
| 2.2 Impedance-coupled noise | ✅ Complete | Delivered 2026-08-21 with thermal and mains coupling. |
| 2.3 Richer metrics | ✅ Complete | Delivered 2026-08-21 across waveform, channel, detection, source, and ERP scoring. |
| 2.4 Scenario files | ✅ Complete | Delivered 2026-08-21 with a versioned catalog and override tests. |
| 3.1 Multi-subject simulation | Not started | Depends on 2.4. |
| 3.2 Comparison harness | Blocked | Depends on 2.3/2.4 and the MFF event-precision fix. |
| 3.3 Measured template library | Partial | Gradient-template import exists; the curated library and BCG import do not. |
| 3.4 Clinical patterns | Not started | Interictal spikes are first priority. |
| 4.4 Correlated-source band identity | ✅ Complete | Delivered 2026-08-21 with within-band correlation construction and truth tests. |
| 4.5 Lead-field convergence check | ✅ Complete | Delivered 2026-08-21 with N→2N diagnostics, eccentricity coverage, and runtime warnings. |
| 4.6 One reference convention | ✅ Complete | Delivered 2026-08-21 with one recorded additive-boundary reference. |
| 4.7 Split ERP streams | ✅ Complete | Delivered 2026-08-21 with five named, recorded seed domains. |
| 4.8 Declare ERP overlap | ✅ Complete | Delivered 2026-08-21 with directional flags and non-overlap scoring. |

**Next:** do **4.3 placeable ERP dipoles**, then **4.9 sub-millisecond MFF event
times**; alternatively begin **3.1 multi-subject simulation**.

---

## Where it is now

Implemented, tested, and documented in `Tools/EVASimulate/README.md`:

- **EEG**: seven band-limited Gaussian sources, 1-70 Hz with a notch gap,
  modulated alpha, circular or geometric spatial correlation.
- **Gradient artifact**: slice/volume structure, EEG-MRI clock drift, slow
  amplitude modulation, anti-alias modelling, measured-template import.
- **BCG**: rate modulation, heart-rate variability, beat-to-beat amplitude
  correlation, per-channel latency and polarity, separate true and *detected*
  beat times.
- **Ocular**: blinks as transients, eye movements as gaze-position steps.
- **Muscle**: opt-in deterministic 20-200 Hz bursts localized to left/right
  temporalis and posterior neck, with complete burst and topography truth.
- **Additional artifacts**: rhythmic chewing, stereotyped swallowing, broad
  cable movement, local sweat drift, true channel bridges, common bad-reference
  contamination, and hard amplifier clipping.
- **Recording defects**: five bad-channel kinds, mains noise, per-electrode
  impedance tied to the defect, Johnson-Nyquist contact noise, and
  impedance-scaled mains pickup.
- **Montage**: 10-20 positions with `sensorLayout.xml` and `coordinates.xml`.
- **Source space**: deterministic neural dipoles, three-shell forward model,
  difficult separability scenarios, moving sources, ocular dipoles, and
  localization/component-recovery scoring.
- **ERPs**: target/standard designs, analytic or measured components, dipole
  topography, skewed/correlated trial variability, omissions, MFF markers, and
  average/single-trial recovery truth.
- **Neural non-stationarity**: discrete alpha spindles, independent slow
  per-band amplitude dynamics, switching microstate maps, and known PAC with
  complete truth and parameter scoring.
- **Scoring**: SNR, RMSE, correlation, power ratio, spectral distortion, and
  per-channel breakdowns; optimal source assignment; event detection with
  timing/ROC metrics; and ERP amplitude/latency recovery metrics.
- **Scenarios**: versioned JSON configuration files, explicit flag precedence,
  config-only export, and four reviewed configurations in a shipped catalog.
- **60 passing self-test outcomes** on the model's own behaviour, and byte-level
  determinism.

## Principles to hold onto

These are what make the tool trustworthy; every item below should preserve them.

1. **Determinism is not negotiable.** Same seed, byte-identical output. A
   benchmark that moves between runs cannot support a claim.
2. **Paper reproduction stays explicit.** The operational default is 1000 Hz so
   event samples survive the current MFF writer; the reviewed
   `scenarios/paper-default.json` retains the paper's 1024 Hz rate and every
   addition has a documented switch or scenario value restoring the published
   behaviour.
3. **Declare what was invented.** The README's "what comes from the paper and
   what does not" split is load-bearing. A result that turns on an invented
   waveform shape is weaker evidence than one that turns on a measured
   parameter, and the reader has to be able to tell which they are looking at.
4. **Self-test anything that could silently stop working.** A harness that
   quietly stops reproducing the phenomenon it studies is worse than no harness,
   because everything it emits still looks like evidence.

---

# Tier 1 — the ones that change what is possible

## 1.1 Source-space simulation (dipoles + lead field → sensors)

**Status (2026-08-21): complete.** `--eeg-model dipole` adds deterministic
neural sources, an arbitrary-shell analytic forward model with the classic
three-shell preset, free- and fixed-orientation gain matrices, average
referencing, source-count-isolated artifact RNG streams, and complete
truth-sidecar provenance. Controlled correlated and near-degenerate pairs,
time-varying source position/orientation, and an opt-in two-eye homogeneous
dipole model cover the difficult separability cases. `--write-sources` exposes
true source time courses, and `score-sources` evaluates inverse locations and
recovered components with optimal, order- and polarity-invariant assignment.
Source-space invariants and end-to-end workflow checks are included in
`selftest`.

**The largest structural change here, and the one most other items compose
with.**

Before 1.1, every topography was an ad-hoc weight vector: the blink was a cubed
cosine to an assumed eye direction, and neural EEG was created directly in
sensor space. The completed dipole path now provides:

- Volume-conducted topographies for every neural source and the opt-in ocular
  model.
- **Known source locations**, so source-localization methods can be scored.
- **Controllable ICA separability** — the number of true sources becomes a
  parameter, and you can generate the cases that break unmixing (more sources
  than channels; two sources with near-identical topographies; sources that move).
- Correlated-source scenarios, which is where most blind-separation methods
  actually fail.

**Implementation.** The analytic concentric-sphere model needs no mesh or
external dependency. Sources are `(position, orientation, timecourse)` records;
the static projection uses a `channels × sources` gain matrix, while moving
sources interpolate between recorded endpoint operators. A later BEM option can
import an individual head model without changing this interface.

**Delivered effort:** large. **Unblocks:** 1.2, 1.3, meaningful ICA evaluation,
and anything about topography.

## 1.2 ERPs with trial-to-trial variability

**Status (2026-08-21): complete.** The opt-in ERP layer emits deterministic
standard/target designs with exact MFF markers, dipole-projected Gaussian,
biphasic, or measured waveforms, and complete per-trial onset, latency,
amplitude, condition, and omission truth. Latency distributions can be Gaussian
or skewed; latency and amplitude variability have a controlled correlation.
Condition-average truth incorporates jitter and omissions, while `score-erp`
scores either average components or non-omitted trials by stable ID. A reviewed
`oddball-erp.json` scenario ships with the catalog.

**Highest value per unit of work in Tier 1, and it needs nothing else first.**

EVA's Trials module implements Woody, RIDE and CWT-ridge single-trial latency
estimation. It now has deterministic per-trial latency and amplitude truth to
test against, enabling recovered-versus-true figures across SNR.

**Implementation.**

- Component definition: Gaussian, biphasic, or measured waveform; a peak
  latency; an explicit dipole topography; and an amplitude.
- Per-trial draws: latency jitter (normal or skewed), amplitude jitter,
  occasional omissions, and a *latency-amplitude correlation* — the confound
  that motivates most single-trial methods.
- Experimental design: conditions, trial counts, ISI distributions, oddball and
  target/standard structure. Emit condition codes as MFF events so EVA's own
  epoching path consumes it unchanged.
- Ground truth to the sidecar: per trial, its true latency and amplitude.

**Delivered effort:** medium. **Unblocks:** validation of everything in
`EVA/Trials/` and `EVA/Epoching/SingleTrialAnalyzer.swift`. **Note:** this is the item most likely
to produce a publishable result quickly.

## 1.3 Non-stationarity

**Status (2026-08-21): complete.** The opt-in layer (`--with-nonstationarity`)
now provides deterministic alpha spindles, independent log-amplitude OU
dynamics for every band, four-state topographic switching with constrained
40–250 ms dwell times, and known theta-to-gamma phase-amplitude coupling.
Every realized event, envelope, state/map and PAC parameter is written to the
truth sidecar; `score-pac` reports coupling-strength and circular preferred-phase
error. The paper-compatible default remains stationary, and individual
mechanisms have numeric controls and ablation switches. Five self-tests pin the
stationary compatibility path, deterministic truth, burst timing, slow spectral
continuity, distinct microstates and phase-locked gamma amplitude.

**The paper's own stated weakness, and the reason to distrust every ICA number
the harness currently produces.**

Grouiller et al. conclude that the discrepancy between their simulated and
experimental ICA results is most likely explained by their model's stationarity:
real neural signals are strongly non-stationary, which violates ICA's
assumptions. Our model inherits the flaw exactly. Until it is fixed, the honest
position — currently stated in the docs — is that simulation says nothing
trustworthy about ICA.

**Sketch, cheapest first:**

- **Bursts instead of continuous rhythms.** Alpha as discrete spindles with
  realistic durations and inter-burst intervals, not an amplitude-modulated
  continuous process. Small change, large realism gain.
- **Time-varying spectra.** Let band amplitudes follow a slow stochastic process
  rather than a constant.
- **Topographic switching (microstates).** Piecewise-stationary spatial patterns
  with realistic dwell times — the specific structure that breaks the
  "sources are fixed in space" assumption ICA rests on.
- **Cross-frequency coupling.** Phase-amplitude coupling with a known coupling
  strength, which is also a directly testable ground truth for PAC methods.

**Delivered effort:** large. **Unblocks:** controlled ICA evaluation; PAC method
validation. The generated laws remain phenomenological and should be swept, not
treated as a fitted population model.

---

# Tier 2 — high value, self-contained

## 2.1 More artifact types

**Status (2026-08-21): complete.** EMG is delivered as an opt-in, deterministic
surface-muscle model with independent 20-200 Hz carriers for left temporalis,
right temporalis, and posterior neck; smooth stochastic burst envelopes;
configurable rate, amplitude, duration, and band edges; MFF duration markers;
complete burst/topography truth; `score-events --type emg`; teaching-scenario
coverage; and three behavioral self-tests. Chewing and swallowing add distinct
stereotyped orofacial episodes; cable sway is low-frequency, broad, and spatially
correlated; sweat drift is slow and channel-local; true bridges average a named
pair into one shared signal; bad-reference noise is identical across every
channel; and clipping applies recorded symmetric amplifier rails. Duration
markers and truth support event scoring for every episodic family. All remain
off in the operational and paper defaults.

The completed expansion covers:

- **EMG / muscle. ✅** Broadband above ~20 Hz, temporalis- and neck-weighted,
  and bursty, with exact event and spatial truth.
- **Chewing and swallowing. ✅** Stereotyped bursts with distinct truth markers.
- **Cable sway / movement. ✅** Low-frequency, spatially broad, correlated across
  neighbouring channels.
- **Sweat. ✅** Very low frequency drift on explicit channels.
- **True electrode bridging. ✅** Two channels sharing one signal. This is a
  *different* failure from the current `flat` defect and is the case that
  bridging detectors are built to catch — model it as a correlated pair.
- **A bad reference. ✅** Contaminating every channel identically. Distinctive,
  common, and routinely misdiagnosed as global noise.
- **Saturation / clipping. ✅** Hard rails, which break linear methods in a way
  additive artifacts do not.

**Effort:** small each; they share the injection machinery in
`ChannelDefectModel.swift` and `OcularArtifactModel.swift`.

## 2.2 Impedance-coupled noise

**Status (2026-08-21): complete.** Contact impedance is now realized before
sample noise and drives per-channel Johnson-Nyquist noise through
`sqrt(4 k T R B)`. When mains interference is enabled, pickup follows an
explicit impedance power law with a small seeded lead-dress term. The exact
latent impedance, analytic thermal RMS, and realized mains-gain vectors are
retained in truth even when ICAL export is disabled. Flat contacts and explicit
bridged pairs keep deceptively low impedance, preserving the intended
counterexample. Dedicated seed streams, CLI controls, impedance sweeps,
paper-default opt-out, and three behavioral regression tests complete the item.

We record per-electrode impedance and we generate per-channel noise, and the two
were previously **independent**. Physically they are not: a high-impedance contact
picks up more thermal noise and more interference. Wiring noise amplitude and
mains pickup to impedance makes the recording internally consistent and makes
impedance genuinely predictive rather than decorative — with the `flat`/bridged
case still deliberately breaking the correlation, since that is the lesson.

**Delivered effort:** small. **Methods caution:** because this model makes
impedance predictive by construction, an impedance-rejection study should test
held-out coupling parameters and the low-impedance exceptions rather than claim
the built-in correlation itself as validation.

## 2.3 Richer metrics

**Status (2026-08-21): complete.** `score` now reports broadband, per-band, and
per-channel RMSE, correlation, spectral distortion, SNR, and power ratio from a
shared Welch analysis. `score-events` performs optimal one-to-one temporal
assignment and reports precision, sensitivity, time-bin specificity, F1,
false-positive rate, timing error, and confidence ROC/AUC. `score-erp` reports
signed bias, MAE, and RMSE for recovered component amplitude and latency. Source
location and waveform assignment from 1.1 completes the source-specific side.
All metrics have text and machine-readable output plus regression tests.

SNR alone is thin for a paper, and the paper itself lists its limitations.

- **RMSE and per-band correlation**, which are not normalized and so say
  different things than SNR.
- **ERP-specific**: amplitude and latency bias in the recovered average, which is
  what an ERP researcher actually cares about.
- **Spectral distortion**: how much the corrected PSD deviates from truth, per
  band — over-filtering made visible.
- **Detection metrics.** ROC, sensitivity and specificity for artifact
  *detection*, scored against the known event times already in the sidecar. Many
  methods papers are about *finding* artifacts; this closes the former gap where
  the ground truth existed but could not be scored.
- **Per-channel breakdown**, so a single bad channel is visible instead of
  averaged away.

**Delivered effort:** medium. **Dependency:** none. The ERP simulation now
populates the same average and single-trial metric contract.

## 2.4 Scenario files

**Status (2026-08-21): complete.** `--config` loads a versioned JSON envelope
containing the complete `SimulationConfig` and seed; explicit flags override
loaded values. `--write-config` saves the final resolved scenario and can be used
without generating data. The shipped `scenarios/` catalog includes the paper
default, teaching demo, and difficult dipole-separability case. Schema checks,
full-config round trips, precedence tests, truth-sidecar equality, and
byte-deterministic catalog generation are verified.

Forty command-line flags do not fit in a methods section. A scenario file —
YAML or JSON, holding the whole configuration plus the seed — means a paper can
say "scenario `bcg-jitter-sweep`, seed 20260821" and a reviewer can regenerate
the data byte-for-byte.

**Implementation.** The schema wraps `SimulationConfig` with a version, stable
name, and description. The complete resolved configuration is the same object
written into `sim_truth.json`. Unsupported future schema versions fail loudly.
Measured-template asset paths are retained in the configuration as well.

**Delivered effort:** small. **Value:** disproportionate — this makes results
citable and composes with 3.2.

---

# Tier 3 — valuable, more work

## 3.1 Multi-subject and group simulation

Per-subject parameter draws (montage variation, artifact severity, alpha
amplitude, impedance quality) so group-level and mixed-effects methods can be
tested. Export straight to BIDS through `Tools/EVABIDS` and the result is a
synthetic dataset any pipeline can be run over — which is a useful artifact in
its own right, independent of EVA.

**Effort:** medium. **Depends on:** 2.4 (scenario files) to stay manageable.

## 3.2 Comparison harness

Run N methods × M scenarios, emit the table and the figure. This is the step that
turns "we have a simulator" into "here is the results section." It needs a
headless way to invoke EVA's correction methods; `Tools/EVAHelper` is the
existing precedent for driving processing from a command line, and
`EVA/Pipeline/EVAProcessingScript.swift` already describes a processing run as
data.

**Effort:** medium-large. **Depends on:** 2.3, 2.4. **No longer blocked:** the
event-precision bug that made EVA's gradient stage intermittently refuse
generated recordings was 4.9, fixed 2026-08-21.

## 3.3 Measured template library

The synthetic gradient and BCG waveforms are the weakest link in any claim that
depends on artifact *shape*. A small library of real templates — gradient
artifacts from different scanners and sequences, BCG at different field strengths
— with provenance for each, would let a result be stated as "on a measured 3T
GE-EPI template" rather than "on our modelled waveform." `--gradient-template`
already accepts one; what is missing is the library and a BCG equivalent.

**Effort:** small in code, larger in data collection and permission.

## 3.4 Clinical patterns

- **Interictal spikes.** The paper's *own* second evaluation case, and the one
  where it found FASTR performs badly because spikes are not orthogonal to
  residual gradient artifact. We cannot reproduce that finding today.
- **Sleep spindles and K-complexes**, for sleep-scoring method work.
- **Seizure evolution**, for detection work.

**Effort:** medium. **Note:** spikes are the highest priority of these — they
close a gap against the source paper.

---

# Tier 4 — consistency and correctness debts

Written 2026-08-21 after a full read of the implemented tool alongside Rusiniak
et al. (2022). Tier 1-3 describe capabilities the simulator does not yet have.
Tier 4 is different: these are places where the simulator *does* have the
capability but applies it inconsistently, or where a modelling choice that was
harmless as a benchmark becomes load-bearing now that results are meant to be
defensible. They are mostly small. They are listed before Tier 5 because Tier 5
cannot be trusted until 4.1 and 4.2 are done.

## 4.1 Give the BCG a geometric topography

**Status: closed by 5.1 (2026-08-21).** Superseded rather than fixed
separately — the interim single-dipole fix was never needed, because the
multi-generator model landed directly.

**The single largest inconsistency in the tool today.**

1.1 replaced invented topographies with dipoles projected through a forward
model — for the ongoing EEG, for the ERP, and for the eyes. The BCG never got
that treatment. `BCGArtifactModel.inject` still assigns each channel a scale of
`(0.35 + 0.65 · cos(2π · channel / N))`: a smooth function of **channel index**,
not of position.

This is the same circular-neighbour structure the README already declares as a
limitation of the default Grouiller spatial model — except it survives
`--eeg-model dipole`, so a run that is otherwise physically consistent still
hands every spatially-aware correction method a topography no montage produces.
PCA, ICA, and EVA's topography-gated/aligned/weighted OBS strategies all key on
exactly this structure. Any comparison among them on the current model is
scoring their response to an artefact of channel ordering.

**Sketch.** Even before 5.1's multi-generator model, the interim fix is cheap:
place one equivalent dipole (or a small fixed set) in the existing head model and
project it through `SphericalForwardModel`, exactly as the ocular model does.
Polarity reversal across the head then falls out of the field instead of being
imposed by a cosine.

**Effort:** small. **Blocks:** 5.x entirely, and any current claim about
topography-aware BCG correction.

## 4.2 The BCG is rank-1 in space

**Status: closed by 5.1 (2026-08-21).** Realized rank is now 4, and it emerges
from having four distinct physical generators rather than being asserted by
adding components — which was the requirement.

One template waveform times one scalar per channel. Per-channel latency adds
only approximate rank. The whole artifact therefore lives in ~one spatial
dimension.

Rusiniak et al. report 4-8 principal components per subject (mean 5.7), and
FMRIB's OBS default of 4 exists because the real artifact has that rank. Against
a rank-1 artifact, OBS-4 is trivially near-optimal, and PCA-S, ICA-S and OBS
become indistinguishable — the comparison most worth running is the one the
current model cannot resolve.

**Sketch.** Rank should *emerge* from having several physically distinct
generators, not be asserted by adding components. See 5.1.

**Effort:** medium, and mostly the same work as 5.1. **Note:** the current model
flatters every template-based method. The README's "fixed waveform with varying
amplitude" caveat understates this — the spatial degeneracy matters more than the
morphological one.

## 4.3 Make the ERP dipole placeable

**Status (2026-08-22): complete.** `ERPConfig.components` takes an array of
explicitly placed generators, each with its own position, orientation, waveform,
latency, width and per-condition amplitudes. When absent, the single legacy
component is used unchanged.

**The confound is gone, and measured.** The old path derived the ERP source from
`makeSources`, so it sat **exactly** on ongoing-EEG source #1 — signal and noise
in the same place. `selftest` demonstrates rather than asserts this: the legacy
component reports 0 mm to the nearest neural source, placed components report
more than 10 mm, and the distance is written to the truth sidecar for every
component so the confound stays visible.

**Coordinate frame is declared.** `+x` right, `+y` anterior, `+z` vertex, origin
at the head-model centre, millimetres — the same frame `Montage` and
`SimulatedSource` already use, and it is recorded in the sidecar as
`erpCoordinateFrame`. `ERPComponentConfig.talairachApproximate` converts
published coordinates under a **stated approximation**: the simulator's origin is
a sphere centre, not the anterior commissure, so a fixed offset is applied and no
scaling or shear is attempted. Relative geometry — what makes a bilateral pair
bilateral — survives far better than absolute anatomical position, and the
documentation says so rather than implying anatomical fidelity.

**New scenario:** `scenarios/aep-bilateral.json` — Rusiniak et al.'s Table 1 AEP,
two dipoles perpendicular to the left and right Sylvian fissure with N100 peaks
2 ms apart, converted from Talairach (-49,-18,12) and (49,-15,13). This is what
5.3's remaining criteria need in order to have anything to localize.

**Per-component per-trial truth.** Each component records its realized latency
and amplitude for every trial, from its **own** seed streams — components of a
real complex do not jitter together, and that independence is precisely what
single-trial latency estimation has to contend with. A self-test pins that two
components' per-trial latencies are close to uncorrelated.

**4.5a's third follow-up landed with it.** `SphericalForwardModel.leadField` now
takes `verifyConvergence`, and the placed-ERP path passes `true`. The run-level
check in `runGenerate` covered every call site only because all sources shared
one eccentricity; a placed component can sit at any depth. A self-test confirms
that a component 0.5 mm inside the brain boundary with 8 series terms is
**rejected** rather than producing a plausible-looking topography.

**Backward compatibility, verified not assumed.** With the new truth fields
suppressed, `oddball-erp` reproduces the recorded pre-4.3 directory hash
`ad80ae2b…` exactly; it was also the only existing scenario whose hash moved, and
only its sidecar changed. `components` is Optional, so scenarios written before
4.3 — including users' own — still decode.

**Self-tests added (78 total, 0 failures):** the coincidence defect and its fix;
placed topographies reproduce a directly computed lead field to 1e-9 while the
bilateral pair stays non-degenerate; independent per-component jitter; and
rejection of an under-resolved placement.

**Not done here:** condition-dependent *source location* (targets and standards
can differ in amplitude per component but share a generator), and habituation.

---

**Original plan:**

`ERPGenerator.makeSource` calls `DipoleEEGGenerator.makeSources(config)[0]` and
renames the result. The ERP therefore inherits the golden-spiral position and
orientation pattern of ongoing-EEG source #1 — and is **coincident with it**.
The signal sits exactly where one of the noise sources sits.

Two consequences. First, single-trial latency validation (the whole point of
1.2) is run with a confound nobody chose. Second, published dipole models cannot
be reproduced: Rusiniak's bilateral AEP is two dipoles perpendicular to the
Sylvian fissure at stated Talairach coordinates, and there is currently no way
to express that.

**Sketch.**

- Explicit `(position, orientation)` per component, in millimetres, in a
  **declared coordinate frame** — the simulator's own frame is fine, but it must
  be named and a Talairach/MNI-to-frame mapping documented, or published models
  cannot be entered.
- N components rather than one, each with its own waveform, latency, amplitude
  and topography, so P1/N1/P2/P3 overlap can be modelled.
- Condition-dependent amplitude *and* condition-dependent source, so target and
  standard are no longer forced to share a topography.
- Refuse, or at minimum declare in the truth sidecar, an ERP source that
  coincides with an ongoing-EEG source.

**Effort:** small-medium. **Unblocks:** 5.3, and makes 1.2's results
interpretable.

## 4.4 Correlated-source band identity

**Status (2026-08-21): complete.** When correlation is non-zero, S002 is assigned
S001's configured band before the exact correlation transform, and waveform
generation now follows each source's recorded `bandName`. The truth therefore
remains spectrally honest; without correlation, the normal round-robin band
catalog is unchanged. A self-test pins both paths.

Before this fix, `--dipole-source-correlation` mixed source 1's timecourse into
source 2 even though sources cycled through different `eegBands`. Source 2 was
therefore no longer band-limited while per-band scoring assumed it was.

**The self-test measures the spectrum, not the label.** S002 must keep over 90%
of its power inside S001's band — realized 0.94, the shortfall being Welch
leakage at the narrow delta edge. Under the old cross-band construction the same
measurement would have been roughly 0.36, so relabelling a source without
changing its signal cannot pass. The test also requires the shared-band decision
to appear in `scenarioRole`, since an undeclared change is the failure mode the
item was about.

**Baseline impact.** `scenarios/dipole-separability` is the only shipped scenario
with a non-zero correlation, and it was the only determinism hash that moved. The
other three were confirmed unchanged before the baseline was re-recorded — which
is the determinism check earning its keep on its first real change.

**Fix:** either correlate within band, or record the realized spectrum change in
`sim_truth.json` and say so in the docs. Choosing silently is the only option
that is wrong.

**Delivered effort:** small.

## 4.5 Lead-field series convergence check

**Status (2026-08-21): complete.** Every dipole generation now compares the
complete free-orientation gain matrix at the requested truncation `N` and
`2 × N`. It evaluates the L2-relative change of each source/orientation column,
reports the worst change, and emits a runtime warning above `1e-4` (0.01%),
including the responsible source and axis. The self-test spans source-radius
fractions 0.01 through 0.999999 and verifies the 100-term default converges,
while a deliberately under-resolved 10-term field at 0.99 is rejected.

The Legendre series in `potentialPerUnitMoment` converges slowly as the source
approaches the brain-shell boundary, and `--dipole-source-radius-fraction` is
user-settable. Nothing asserts that `leadFieldTerms` is sufficient at the
configured eccentricity.

This is exactly principle 4's failure mode: silently wrong topographies that
still look entirely plausible, in a component every other result now depends on.

**Fix:** a self-test that computes the gain matrix at `terms` and `2 × terms`
and asserts a relative change below tolerance across the eccentricity range the
tool permits; and a runtime warning when the configured eccentricity needs more
terms than requested.

**Delivered effort:** small. The diagnostic is numerical truncation evidence,
not an independent validation of the spherical forward equations.

**Verified 2026-08-21:** at the default 0.85 depth the 100→200 term change is
6.49e-15 — machine precision. No existing output moves, so no scenario
regeneration and no determinism-baseline change was required by this item.

### 4.5a Follow-ups

**Status (2026-08-21): complete.** The self-test now reports
`worstConvergenceChange` — the quantity it actually asserts — instead of the
negative control's value. The control tests the metric's *shape* rather than
only its threshold: truncation error must fall monotonically over 10/25/50/100
terms at 0.99 eccentricity, which a metric broken toward always-large values
would fail. And the runtime check in `runGenerate` now carries a comment
recording that it covers every call site only because all sources share one
eccentricity, with the pointer to move it inside
`SphericalForwardModel.leadField` when 4.3 lands.

Original items:

- **The self-test prints the wrong number.** `Outcome.snr` carries the
  *negative control's* value, so the line reads `0.043` beside a claim that
  every tested depth is below `1e-4`. It looks like a failure to anyone reading
  selftest output cold. Report `worstConvergenceChange` — the quantity actually
  asserted — and keep the control's value in the expectation string if it is
  wanted.
- **Strengthen the negative control.** At 10 terms the *default* 0.85 depth
  already changes by 0.0256, so the 0.99 eccentricity is not doing much work and
  the control would still pass if the metric were broken in a direction that
  always returns large values. Assert monotone decrease across 10 → 25 → 50 →
  100 terms instead, which tests the metric rather than only its threshold.
- **The single check covers all call sites only by coincidence, and 4.3 ends
  that.** `runGenerate` checks convergence once, for `makeSources(config)`. That
  happens to cover `ERPGenerator` (its source comes from `makeSources`, same
  radius fraction) and `applyMotionIfNeeded` (rotation preserves radius);
  `OcularDipoleModel` uses a closed form and no series at all. Coverage is
  complete today **only because every source shares one eccentricity**. An
  explicitly placed ERP dipole from 4.3 can be more eccentric than the ongoing
  sources, and the single check would silently stop covering it. Either leave a
  comment now recording that the check assumes uniform eccentricity, or — better,
  when 4.3 lands — move the check inside `SphericalForwardModel.leadField` as an
  opt-in parameter so it travels with every call site.

## 4.6 One reference convention across all injection layers

**Status (2026-08-21): complete.** `--reference average|infinity` defines one
recording convention for both EEG models. The complete additive mixture—neural
EEG, ERPs, scanner/physiological artifacts, contact noise, and mains—is
referenced once at a shared boundary. Bad-reference corruption, channel defects,
bridges, and clipping are deliberately later recording failures. Convention and
application stage are explicit in truth and every shipped scenario.

Before this fix, the neural lead field and ocular topographies were
average-referenced while BCG, EMG and the other Tier 2.1 artifacts were not. The
composite recording consequently had no well-defined reference, which matters
because average-referencing is a step in nearly every published pipeline —
including all five methods in Rusiniak et al.

**Fix:** define the reference once at the injection boundary and enforce it for
every layer; record it in the truth sidecar.

**Delivered effort:** small.

**Audited 2026-08-21.** Every layer confirmed to build in
`effectiveRecordingReference` — no call site left using the legacy
`dipoleReference` or a hardcoded `.average`. One gap was found and closed: the
self-test covered `EEGReferencing` on a synthetic matrix and on the clean neural
EEG, but nothing exercised the *complete* mixture, which is what 4.6 actually
claims — BCG, ocular and EMG were precisely the layers that previously met no
reference at all. `selftest` now builds EEG + gradient + BCG + ocular + EMG in
one recording and checks the boundary lands.

That test carries an infinity-reference negative control, and it is the half that
makes it a test: without it, "the channel mean is zero" could pass because every
layer happened to be constructed zero-mean and the referencing step was doing
nothing. The same mixture at infinity is asserted to retain a common mode above
1 µV.

## 4.7 Split the ERP random stream

**Status (2026-08-21): complete.** Latency, amplitude, target/standard order,
onset jitter, and omission now use five independent named seed domains recorded
in truth. Trial-count changes preserve the existing prefix of unrelated factor
draws; exact latency–amplitude correlation remains a deliberate within-design
batch constraint. A focused self-test verifies prefix stability and seed
separation.

Previously, latency draws, amplitude draws, the target/standard shuffle, ISI
jitter and omission draws all came from one interleaved `GaussianSource`. The
per-model domain-mixing idiom in `SimulationSeedStreams` already exists; apply
it within the ERP layer so a one-factor sweep does not re-roll the other
factors. Varying trial count currently changes every draw downstream of it,
which makes trial-count sweeps harder to interpret than they need to be.

**Delivered effort:** small.

## 4.8 Declare ERP trial overlap

**Status (2026-08-21): complete.** Every trial records its component-window end
and previous/next/any overlap flags. Dense schedules remain allowed, but the CLI
summary declares their count and `score-erp --level trial --exclude-overlap`
scores only the unambiguous subset. Tests cover both dense and separated
schedules.

`onsets` may place a trial inside the previous trial's component window. That is
realistic and worth keeping, but sensor-space peak truth then becomes ambiguous
even though source-space truth stays exact. Document it, and consider emitting
an overlap flag per trial in the sidecar so a method can be scored on the
non-overlapping subset.

**Delivered effort:** small.

## 4.9 Sub-millisecond MFF event times (the 1024 Hz blocker)

**Status (2026-08-21): complete.** Event times now survive a write/read round
trip at microsecond precision, verified end to end: every TREV, QRSd and QRSt
marker in a 1024 Hz `paper-default` run recovers its **exact** sample index, and
the TR train's only remaining variation (3072/3073 samples) is the simulator's
own intentional 152 µs/s clock drift, inside EVA's one-sample tolerance.

**A second half of the bug was found during the fix.** The write side was as
diagnosed, but `MFFReader.parseMFFDate` truncated too — `ISO8601DateFormatter`'s
`.withFractionalSeconds` stops at milliseconds. Fixing only the writer would not
have fixed 1024 Hz. The reader now splits the fraction off, parses the
whole-second instant with Foundation, and adds the fraction back as a Double
(any digit count: files in the wild use three, six, and nine).

The simulator's own millisecond workaround in `SimulationWriter` — which
correctly concluded "the fix has to be in the writer's precision, not here" —
has been removed; event times now snap to the sample grid, which is the real
resolution of a discrete recording. Its record of three failed repair schemes is
kept as a comment so they are not retried.

`MFFTimestamp` carries integer seconds + integer nanoseconds, snapped to whole
microseconds on construction so `recordTime` and every event quantize onto one
grid and the reader's subtraction does not inherit two roundings. `DateFormatter`
is only ever handed a whole-second instant.

**Tests:** `EVATests/IO/MFFEventPrecisionTests.swift` round-trips events at 500,
1000, 1024, 2048 and 20000 Hz and pins TR spacing at 1024 Hz; the simulator's own
self-test now sweeps four rates rather than asserting the 1000 Hz default alone.
1000 Hz and 500 Hz are kept in both, but note they *cannot* detect a regression —
their sample period is a whole millisecond, so they passed even with the bug
present.

**The 1000 Hz default is now a free choice rather than a constraint.**
`scenarios/paper-default.json` was already at the paper's 1024 Hz and now
round-trips exactly; whether to move the operational default back is a
scientific decision, not a workaround, and is left open.

---

**Original analysis, kept because `TODO_Aug21.md` is not in the repository:** The interim mitigation —
defaulting the simulator to 1000 Hz — is in place and works, because at 1000 Hz
a sample is exactly 1 ms and every sample index survives a millisecond-resolution
round trip. It is a mitigation, not a fix: it means the paper's own 1024 Hz rate,
and every non-integer-millisecond rate (500 Hz is fine, 512, 2048 and 20000 Hz
are not), cannot be written and read back reliably.

**What actually happens.** `MFFWriter.mffDateString` already asks for six
fractional digits (`yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx`), so the format string is
not the problem — an earlier note in this roadmap that blamed a millisecond
format is out of date. The problem is `DateFormatter` itself, which carries
millisecond internal precision and zero-fills the remaining digits, so a
microsecond-looking timestamp is still millisecond-quantized in practice.
`Date` is not the limitation: as a `Double` of seconds since 2001 it resolves to
roughly 0.1 µs at present-day epochs.

At 1024 Hz a sample is 976.5625 µs, so millisecond rounding displaces an event by
up to ±0.5 ms, or ±0.51 samples. Two adjacent TR markers can therefore land
1.02 samples apart in the round trip, which is what trips EVA's own one-sample
TR-spacing tolerance and produces the intermittent "TRs are not evenly spaced"
rejection. The failure is intermittent because it depends on where each marker
falls relative to the millisecond grid.

**Why microseconds are sufficient.** 976.5625 µs is not an integer number of
microseconds either, so microsecond formatting still quantizes — but the residual
is at most 0.5 µs, which is 0.0005 samples. That is four orders of magnitude
inside the tolerance, and it holds for any plausible sampling rate. Nanoseconds
are permitted by MNE's parser (its regex accepts six *or* nine fractional digits)
but buy nothing here.

**The fix.**

1. **Stop routing timestamps through `DateFormatter` for the fractional part.**
   Format the whole-second calendar fields with the existing POSIX formatter,
   and append the fractional digits as a zero-padded integer computed
   separately. The numeric timezone offset comes from
   `TimeZone.secondsFromGMT`, which strict readers require and which the current
   `xxx` token already satisfies.
2. **Compute the fraction with integer arithmetic from the sample index, not
   from a `Double` offset.** `microseconds = round(sampleIndex × 1_000_000 /
   sampleRate)` as integer math avoids a second rounding on top of the first.
   This means `MFFEvent` wants an optional `beginSample: Int` that takes
   precedence over `beginTimeSeconds` when the caller knows the exact sample —
   which the simulator always does.
3. **Anchor `recordTime` and every event to the same integer-nanosecond origin.**
   The reader computes `round((beginTime − recordTime) × sfreq)`, so if
   `recordTime` is quantized differently from the events, the difference inherits
   both errors. Writing both from one integer origin makes the subtraction exact.
4. **A round-trip regression test.** Write TR markers at 1024 Hz, read them back
   through EVA's own reader, and assert exact sample-index recovery and that the
   TR-spacing check passes. Then do the same at 512, 2048 and 20000 Hz. Without
   this the bug returns silently, which is precisely the class of failure
   principle 4 exists to catch.

**Once fixed:** revisit the default sampling rate. The 1000 Hz default was chosen
to dodge this bug, not on scientific grounds, and `scenarios/paper-default.json`
should go back to the paper's 1024 Hz so the benchmark reproduces the published
configuration exactly.

**Effort:** small — a focused change in `EVA/IO/MFFWriter.swift` plus tests.
**Blocks:** general-rate support in 3.2, reliable 1024 Hz runs in 3.1, and exact
reproduction of the Grouiller configuration. **Priority:** high relative to
effort; it is currently being worked around rather than solved.

---

# Tier 5 — surrogate-source BCG separation

The goal: reproduce and then improve on Rusiniak, Bornfleth, Cho, Wolak, Ille,
Berg & Scherg (2022), *EEG-fMRI: Ballistocardiogram Artifact Reduction by
Surrogate Method for Improved Source Localization*, Front. Neurosci. 16:842420.

**Why this is now reachable.** The surrogate method is a *source-space* method:
it builds a spatial filter from a basis of brain regional sources plus artifact
topographies, and back-projects only the non-artifact subspace. Before 1.1 there
was no forward model to build such a basis with. There is now — and the design
decision to retain the free-orientation `channels × 3·sources` operator in
`LeadField` was, whether or not it was intended this way, precisely what a
regional source needs: three orthogonal dipoles at one location.

**Why our version can be stronger than theirs.** Rusiniak et al. superimposed a
simulated AEP onto *real* resting-state EEG. They had ground truth for the
evoked response and none at all for the BCG they were removing, so every
statement about artifact removal is indirect — inferred from what survived in
the AEP. We would have ground truth for both. "Does surrogate separation
preserve source-space truth when the artifact itself is known?" is a question
their design cannot ask.

## 5.1 A physically-generated, correctly-ranked BCG

**Status (2026-08-21): complete.** `--bcg-model generators` replaces the
channel-index cosine with four physically placed generators. **This supersedes
4.1 and 4.2, which are now closed.**

**The generators**, in the order they arrive after the R wave: aortic flow
(deep, broad, earliest), vessel pulsation left and right (focal, lateral,
separately seeded with slightly different transit delays), and head rotation
(broad, latest, largest). Realized spatial rank is **4**, with normalized
singular values 1.000 / 0.527 / 0.462 / 0.182 — a genuinely multi-dimensional
artifact rather than one dominant component plus numerical dust. The old model's
rank was 1, which is why OBS-4 could not fail against it and why PCA-S, ICA-S
and OBS were indistinguishable.

**Derived versus modelled, declared.** The head-rotation topography is derived:
a rigid rotation with angular velocity ω about the left-right axis in a
head-foot bore field gives a motional field `E = v × B = -ωB·z·x̂`, which
integrates to `Φ ∝ x·z`. The aortic topography is derived as a
homogeneous-conductor current dipole in the chest oriented along `v × B`. The
vessel kernels are **modelled, not derived** — electrode motion over an artery
is a moving half-cell potential, not a current source, so there is no dipole to
project. Relative amplitudes and delays are plausible, not measured.

**Beat-to-beat morphology now varies in shape, not only amplitude.** Each
generator's share is drawn independently per beat
(`--bcg-morphology-jitter`, default 0.20); because the generators differ in
topography *and* delay, the composite changes shape. This closes the README
limitation that mattered most for 5.2, since PCA- and ICA-based methods differ
precisely in how they handle shape variability.

**Field strength** is a real parameter now (`--bcg-field-strength`, default 3 T).
Both motional EMF and the Hall separation are linear in B, so one factor scales
every generator from the 3 T reference the paper's 10-200 µV range describes.

**Backward compatibility.** `.channelIndex` remains the default and its draw
order is preserved verbatim. Verified, not assumed: with the new truth fields
suppressed, `paper-default` reproduces the recorded pre-5.1 directory hash
`db7db7f5…` exactly, and every signal binary in all four shipped scenarios is
byte-identical. The only change is one added `bcgSpatialModel` key in
`sim_truth.json`.

The three new configuration fields are **Optional with `effective…`
accessors**, following the `recordingReference` precedent. Swift's synthesized
`Decodable` does not fall back to a property's default for a missing key, and
every scenario file carries the complete configuration — so non-optional
additions would have broken every scenario a user already had. A self-test now
pins that contract by decoding a configuration with all three keys removed.

**New scenario:** `scenarios/bcg-generators.json`, the paper configuration with
the generator BCG substituted.

**Self-tests added (68 total, 0 failures):** the channel-index model is shown to
ignore electrode geometry entirely (reversing the montage leaves every weight
identical — the 4.1 defect, demonstrated rather than asserted); generator
topographies permute with their electrodes to within 1e-9 *and* are non-flat, so
a uniform topography cannot pass for the wrong reason; spatial rank is 4 with the
smallest singular value above 5% of the largest, against rank 1 for the legacy
model; amplitude-normalized beats correlate above 0.999 with morphology jitter
off and below 0.99 with it on; and field strength scales peak-to-peak exactly
linearly.

**A reusable piece:** `SymmetricEigen` (cyclic Jacobi) was written for the rank
diagnostic but is deliberately general — 5.2's PCA of the beat-averaged artifact
template is the same computation on a channels × channels covariance.

**Still open for Tier 5:** 5.2 (surrogate spatial filter) and 5.3 (the
evaluation). Morphology now varies, but every beat still shares one waveform
*family* per generator; a measured BCG template library (3.3) remains the
stronger footing for any claim that turns on artifact shape.

---

**Original plan:**

Supersedes 4.1 and 4.2 rather than following them; do the interim fix in 4.1
only if 5.1 is not being started immediately.

Model the BCG as several **distinct physical generators**, each with its own
timecourse, its own dipolar or geometric topography, and its own delay relative
to the R wave:

- **Head rotation / translation** about the cardiac axis — spatially broad,
  latest, largest.
- **Scalp and electrode motion over superficial vessels** — focal, localized to
  the vessel paths, earlier.
- **Aortic and carotid flow (Hall effect in the static field)** — deep, broad,
  and the component whose amplitude should scale with field strength.

Spatial rank then emerges from physiology rather than being asserted, and the
model gains a real handle on field strength — a 1.5T versus 3T versus 7T
parameter that is currently just an amplitude scalar.

**Also needed:** morphology that varies beat to beat, not just amplitude and
latency. The README already names the fixed waveform as a limitation; it becomes
a confound the moment PCA-based and ICA-based methods are being compared, since
they differ precisely in how they handle shape variability.

**Effort:** medium-large. **Blocks:** everything else in Tier 5.

## 5.2 The surrogate spatial filter

**Status (2026-08-22): complete for PCA-S.** `eva-simulate correct` builds the
brain surrogate basis, extracts artifact topographies, forms the spatial filter,
and writes a corrected recording that `score` consumes directly, so the whole
loop is `generate → correct → score` against known truth.

**Measured:** broadband SNR **2.5-3.0x** against a known generator BCG
(uncorrected ~1.1), with 4-5 artifact components from the paper's 0.5% variance
threshold — inside the 4-8 the paper reports.

**The optimum matches the artifact's true rank, which cross-validates 5.1.** A
component sweep gives SNR 1.45 / 2.35 / 3.00 / 1.58 at k = 2/3/4/5. The
generator BCG has spatial rank 4, and k=4 is the optimum; the fifth component
carries about 1% of template variance and is ongoing EEG, so removing it costs
more than it recovers. Two independent pieces of the model agreeing on 4 is
stronger evidence than either alone.

**Template quality is the binding constraint, and it is now quantified.**
Broadband SNR by recording length at 250 Hz: 0.99 at 60 s, 2.81 at 120 s, 2.48 at
240 s, 2.47 at 480 s. Below roughly 70 accepted beats the template retains enough
EEG that its lower components are brain activity rather than artifact, and the
correction is *worse than doing nothing*. This is a real property of the method,
not a defect of the implementation, and it is the kind of thing the harness
exists to measure.

**Implementation notes worth keeping.**

- The pattern search matches against an **iteratively refined average**, not a
  single seed beat. The paper's operator picks a representative beat by eye;
  matching automatically against one epoch is a poor substitute because that
  epoch carries a full share of EEG. Seeding from one median-energy beat
  accepted 30 of 149; averaging first and re-matching accepts 70-75.
- The filter is built by **partialling out the unpenalized artifact block**
  rather than inverting the combined Gram. `[brain | artifact]` has more columns
  than channels, so its Gram is singular by construction, and with zero
  regularization on part of the diagonal no truncation rescues it — the first
  attempt produced filters that *inverted* the topographies they were meant to
  preserve. Solving for the free block first leaves `Bᵀ M B + λI` with λ positive
  on every column, which is positive definite and needs no truncation.
- Brain columns are **normalized to unit norm** before combining. Lead-field
  entries are in µV/(nA·m) and artifact topographies are unit vectors; without
  normalization a regularization expressed as a fraction of the brain block means
  something entirely different to each block.
- The brain basis reaches to **0.95 of the brain radius** — past the 0.85 the
  simulator places sources at. A basis that stops short cannot describe
  superficial topographies without large coefficients that the regularization
  then suppresses.
- The filter is built in the **recording's own reference**, read from the truth
  sidecar (roadmap 4.6). An average-referenced lead field against
  infinity-referenced data is not a subtle degradation.

**Guard against the 5.3 trap, in the output.** The report records the distance
from each surrogate regional source to the nearest simulated source (15.9 mm
minimum in the runs above). A surrogate basis sitting on top of the simulated
sources would fit the brain activity perfectly and rig the comparison; the number
is printed so a reader can check rather than trust.

**Self-tests added (73 total, 0 failures):** the eigensolver reconstructs its
input and returns orthonormal vectors; the brain model reproduces real dipole
topographies (1.000 unregularized, 0.995 at 2%); a whole artifact-free recording
survives the filter at residual SNR 21.9 — measured as SNR, not correlation,
because correlation is scale-invariant and cannot see a filter that preserves
shape while shrinking amplitude; and end-to-end separation improves SNR by at
least 1.8x at the artifact's true rank.

**Still open:** **ICA-S**. It differs from PCA-S only in where the artifact
topographies come from, so the filter machinery is already in place — and the
Gram-Schmidt step in `spatialFilter` is what makes it work, since ICA
topographies, unlike PCA ones, are not orthogonal.

The solver is nearly free: `EVA/ICA/ICAArtifactDetector.swift` is a
`nonisolated enum` depending only on Accelerate, Foundation and `MFFSignalData`,
all of which EVASimulate already links, and Extended Infomax — the paper's
algorithm — is among its solvers.

What is missing is **component selection**, which the paper does by eye. See
**5.4**: rather than inventing a heuristic threshold, use the simulator's known
generator topographies to produce graded ground-truth labels and train a
labeller that plugs into EVA's existing ICLabel infrastructure. Do not build a
hand-rolled beat-correlation criterion first if 5.4 is being done — it is the
heuristic 5.4 replaces.

A fair evaluation also depended on the non-stationarity work, since stationary
Gaussian sources satisfy ICA's assumptions artificially well; 1.3 has landed, so
that is no longer a blocker — but the comparison now rests on how well our
bursts, OU dynamics and microstates resemble real non-stationarity, which is a
modelling assumption to state rather than assume. Also open: the method is implemented in
EVASimulate rather than in EVA's own pipeline; porting it is a separate decision
with a much larger surface (UI, replay, history, serialization).

---

**Original plan:**

Implement the Berg & Scherg (1994) source-space separation the paper uses.

- A **brain surrogate basis**: 29 regional sources distributed through the brain
  compartment, each expanded to 3 orthogonal dipoles → 87 columns, built with one
  `SphericalForwardModel.leadField` call.
- **Artifact topographies** from either a PCA of the beat-averaged template
  (PCA-S; the paper keeps components above 0.5% of template variance, giving 4-8)
  or manually/automatically selected ICA components (ICA-S).
- The combined `[brain | artifact]` operator, inverted with **regularization of
  2% on the brain block and none on the artifact block**, per the paper.
- Back-projection to sensor space using the brain subspace only.

The template step needs the paper's spatio-temporal pattern search — a
representative beat selected once, then matched at a correlation threshold of
60% — which is also independently useful for EVA.

**Effort:** medium. **Depends on:** 5.1 for the comparison to be meaningful;
the filter itself can be written before it.

## 5.3 The evaluation, and the trap in it

**Status (2026-08-22): complete except for dipole localization error.**
`eva-simulate evaluate-surrogate --config scenarios/aep-bilateral.json --with-erp`
runs the paper's evaluation across repeated seeds and reports every criterion as
mean ± SD.

`eva-simulate evaluate-surrogate` runs repeated seeds across a swept condition
entirely in memory (8 seeds x 4 conditions in 16 seconds) and reports mean ± SD.

### The headline finding: repeats are not optional

Across five seeds at one fixed configuration, corrected broadband SNR ranged
**1.39 to 2.53**. That spread is wider than most differences anyone would want to
claim between methods or conditions. Every single-run comparison made while
developing this item would have supported a confident and wrong conclusion.

Rusiniak et al. used 55 subjects. That was not incidental generosity; it is what
the variance demands. Any Tier 5 or 3.2 result must be reported as mean ± SD over
seeds, and the harness now prints the spread next to every mean and says so.

### The trap is real but points the other way

The roadmap warned that a surrogate basis coinciding with the simulated sources
would rig the comparison in PCA-S's favour. **Measured, the opposite happens.**

Broadband SNR at 8 seeds per condition, 64 channels, 29 regional sources:

| basis offset | corrected SNR | uncorrected |
| --- | --- | --- |
| 0 mm | 1.82 ± 0.44 | 1.14 |
| 10 mm | 1.92 ± 0.46 | 1.14 |
| 20 mm | 2.08 ± 0.54 | 1.14 |
| 40 mm | 2.27 ± 0.53 | 1.14 |

And by basis richness, at 0 and 40 mm offset:

| regional sources | columns | SNR at 0 mm | SNR at 40 mm |
| --- | --- | --- | --- |
| 8 | 24 | 2.13 ± 0.53 | 2.45 ± 0.64 |
| 16 | 48 | 2.20 ± 0.61 | 2.44 ± 0.62 |
| 29 | 87 | 1.82 ± 0.44 | 2.27 ± 0.53 |
| 60 | 180 | 1.50 ± 0.32 | 2.08 ± 0.47 |

**A better brain model makes the artifact removal worse.** The mechanism follows
from 5.2: separation is bought entirely by the asymmetry between a penalized
brain block and an unpenalized artifact block. A richer or better-placed brain
model can represent the artifact too, so it competes for it and less is left to
the columns meant to carry it. `selftest` pins this deterministically — more of a
BCG generator topography survives the filter with 60 regional sources than with 8
— rather than resting on the seeded sweep, whose differences are close to its own
spread.

**Read this carefully.** It does not say the surrogate method is insensitive to
its brain model in general; it says that *on this simulator, at this channel
count, scored by broadband SNR against clean EEG*, a coincident basis does not
flatter the method. Scored instead by ERP distortion — what the paper actually
cares about — a brain model that absorbs artifact may well look different, since
the cost there is to the evoked response rather than to broadband residual. That
comparison needs the ERP criteria below.

### The evaluation, with the bilateral AEP

8 seeds, 64 channels, 200 s, the `aep-bilateral` model over a generator BCG:

| condition | trials kept | ERP SNR | latency err | amplitude | explained var |
| --- | --- | --- | --- | --- | --- |
| uncorrected | 76.0 ± 1.6 | 2.81 ± 0.59 | +0.0 ± 0.0 ms | 1.09 ± 0.11 | 0.89 ± 0.10 |
| PCA-S, 0 mm | 78.6 ± 2.5 | 3.36 ± 0.68 | +0.5 ± 3.3 ms | 0.98 ± 0.12 | 0.89 ± 0.13 |
| PCA-S, 40 mm | 80.1 ± 2.5 | 3.62 ± 0.68 | +0.5 ± 3.3 ms | 0.96 ± 0.11 | 0.90 ± 0.13 |

Read with the spreads, not past them:

- **Amplitude fidelity is the clear win.** Uncorrected, the recovered N100 peak
  is 9% too large — BCG residual adds to it. Corrected, the bias is 2%. That is
  the one difference here comfortably larger than its own spread.
- **Trial retention and ERP SNR improve modestly**, in the paper's direction, but
  by roughly one standard deviation. Suggestive, not established at 8 seeds.
- **Topographic fidelity does not change.** Explained variance is 0.89 either
  way. This is not a failure of the correction — it is that averaging ~76 trials
  already suppresses an artifact that is not time-locked to the stimulus, so the
  uncorrected average starts out clean. The paper's large explained-variance
  gaps (97.3% for PCA-S against 90.3% for BSS) came from methods that actively
  *distort*; a method that does not distort has little room to show an advantage
  on this criterion.
- **Correction adds latency jitter** (±3.3 ms) where the uncorrected average had
  none. Small, but it is a cost, and it is the kind of thing that only shows up
  when the truth is known.

### Remaining

- **Dipole localization error.** The paper fits free dipoles with Nelder-Mead and
  reports distance to the seeded positions. That needs an inverse solver, which
  is Tier 6 work (6.1-6.2). Explained variance addresses the same concern —
  topographic distortion — without one, and is the metric the paper leans on for
  its grand average.
- **ICA-S**, per 5.2.

**Self-tests added (80 total, 0 failures):** explained variance is exactly 1.0
for data built from the model topographies and falls below 0.7 once a foreign
topography is added — both halves, since a metric that always returned 1 would
pass the first alone; and epoch rejection drops exactly the one trial carrying a
400 µV excursion, out of four candidates.

---

**Original plan:**

Their four criteria map onto metrics we already have: accepted-trial count after
amplitude/gradient rejection; SNR as the ratio of post-stimulus to pre-stimulus
RMS; N100 peak latency and amplitude at Cz; and explained variance plus dipole
localization error against the seeded model over the FWHM window. `score-erp`
covers the third, and `SourceMetrics.locationScore` already does Hungarian
matching with axial orientation error, so left/right dipole ordering is a
non-issue.

**The trap: do not let the simulated brain sources live in the surrogate
basis.** If the 7 EEG dipoles sit at or near the 29 regional-source positions,
the surrogate model fits the brain activity perfectly and the comparison is
rigged in PCA-S's favour before it starts. The simulated sources must be drawn
from a distribution deliberately offset from the surrogate grid — and the
**degree of mismatch should be a swept parameter**. That sweep is arguably the
most interesting figure available here, and it is a question the original paper
structurally could not ask.

**The second trap: 1.3 decides PCA-S versus ICA-S.** ICA's assumptions are
satisfied artificially well by the stationary compatibility path. The completed
1.3 model makes the ICA-S arm possible, but that comparison must explicitly use
and sweep the opt-in non-stationarity controls rather than relying on defaults.

**Third:** their pipeline down-samples to 1 kHz after gradient removal, uses a
4-shell ellipsoidal head model, average reference, and Talairach coordinates.
The ellipsoid is not required, but the coordinate frame question from 4.3 is —
their dipole model cannot be entered without it.

**Effort:** medium. **Depends on:** 4.3, 5.1, 5.2, 1.3, and 3.2 for the sweep
machinery.

## 5.4 A simulator-trained BCG component labeller

**Generalized by Tier 8**, which applies the same lever to ocular, muscle and
channel artifacts. This item is the pilot: do one class end to end here before
committing to the rest.

**The idea:** use the simulator to generate the one thing component
classification has never had — *ground-truth labels for ICA components* — and
feed them back into EVA's existing ICLabel infrastructure as a scanner-specific
BCG class.

This is the honest way to do ICA-S's component selection. The paper picks BCG
components by eye; an automatic substitute needs a criterion, and a criterion
invented by hand is just a heuristic with a threshold nobody can defend.

### Why the simulator can do this and real data cannot

Real component labelling is supervised by *human judgement*, which is why ICLabel
was trained on crowd-labelled components and why its labels carry that
disagreement. The simulator has something better: it knows what it injected.

After 5.1, the BCG is four generators with known topographies; after 1.1, the
neural sources have known topographies too. So for any ICA decomposition of a
simulated recording, each component's **true** BCG content is computable, not
guessed: project its topography onto the span of the known BCG generators and
onto the span of the neural sources, and the ratio is a continuous
ground-truth "BCG-ness" — a *graded* target, not a binary label, which is
strictly more information than any human rater can supply.

That is the whole basis of the item. Everything else is machinery.

### What exists already

More than expected, and the integration point is clean:

- **`ICLabelClassifier`** (`EVA/ICA/`) runs a Core ML model over seven classes —
  Brain, Muscle, Eye, **Heart**, Line Noise, Channel Noise, Other — from three
  features: an interpolated scalp image, relative PSD, and autocorrelation. It
  returns `[Int: ICAComponentSuggestion]`.
- **`ICAComponentAutoLabeler`** is the heuristic fallback when no Core ML model
  is present, with hand-built scalp (dipolarity, focality), time and spectral
  features.
- **`ICADecomposition`** already carries `labelSuggestions`, so a new labeller
  slots in beside these rather than replacing anything.
- **`ICAArtifactDetector.fit`** is a `nonisolated enum` depending only on
  Accelerate, Foundation and `MFFSignalData` — all of which EVASimulate already
  links. Extended Infomax, the paper's algorithm, is among its solvers.

**The gap worth naming:** ICLabel's "Heart" class was trained on ordinary
cardiac contamination recorded *outside* a scanner. BCG is a different
phenomenon — motion-induced rather than volume-conducted from the heart, an
order of magnitude larger, with a topography set by head movement in B0 rather
than by the cardiac dipole. There is no reason to expect the Heart class to
transfer, and **measuring how badly it transfers is itself a result** the
simulator can produce before any new model is trained.

### Sketch

1. **Score ICLabel as it stands.** Run `ICAArtifactDetector.fit` over simulated
   recordings, compute the graded truth above, and ask how well the existing
   Heart probability ranks the genuinely BCG components. Cheap, and it decides
   whether the rest of the item is needed or merely nice.
2. **Add beat-locked features**, which is what the existing feature sets lack and
   what the paper's human rater was actually using: the component's
   beat-triggered average, its spatio-temporal self-consistency across beats
   (`SurrogateSeparation.spatioTemporalCorrelation` already does this), and its
   relationship to the ECG channel the simulator emits. All computable from
   *detected* QRS times, so nothing depends on ground truth at inference.
3. **Fit a classifier** on generated corpora spanning field strength, montage,
   BCG amplitude, and the generator mix — the parameters 5.1 made explicit.
   Keep it small and inspectable; a logistic model over a handful of named
   features is defensible in a methods section in a way a black box is not.
4. **Deliver it as an `ICAComponentSuggestion` producer**, so it works
   everywhere ICLabel already does, and ICA-S gets its component selection for
   free.
5. **Close the loop**: feed the labeller's selections back into 5.2's spatial
   filter and score with 5.3's criteria. That is the "back and forth" — the
   classifier is judged by whether the *correction* improves, not by
   classification accuracy on its own.

### The circularity, stated plainly

A classifier trained on simulated BCG learns **our BCG model**, not BCG. If the
four generators are wrong in some respect, the classifier inherits the error and
then looks confident about it — and it would keep scoring well against the
simulator that taught it.

This is the same trap 2.2 flags for impedance-based channel rejection, and it
needs the same discipline:

- Treat simulator-derived thresholds as a **prior to be tested on real data**,
  never as a validated result.
- Hold out generator configurations at training time and report performance on
  the held-out ones, not on the ones fitted.
- **3.3 (measured template library) becomes load-bearing here.** A classifier
  validated against measured BCG templates from real scanners is evidence; one
  validated only against its own training model is an assertion.
- State in any write-up which BCG model produced the training corpus, with its
  parameters — `sim_truth.json` already records all of them.

### Effort and sequencing

**Effort:** medium. Step 1 is small and worth doing on its own. Steps 2-4 are the
substance. Step 5 is nearly free once 5.2 and 5.3 exist, which they do.

**Depends on:** 5.1 (known generator topographies — without them there is no
graded truth), 1.3 (complete), and 5.2/5.3 for the closing loop. **Wants:** 3.3
for external validation, and Tier 7's corpus machinery, which is why this sits
after the 7.1-7.2 slice.

**Supersedes:** the hand-rolled beat-correlation criterion sketched in 5.2's
ICA-S notes. If this item is being done, do not build that first — it would be
the heuristic this replaces.

---

# Tier 6 — distributed inverse methods

The natural consequence of 1.1, and the item with the largest gap between what
it sounds like it costs and what it actually costs.

Once there are **known source locations**, distributed inverse methods have
exactly the ground truth they lack in almost every other setting. Published
comparisons of MNE, dSPM, sLORETA, eLORETA, LORETA and LAURA are forced to score
each other, or to score against a single seeded dipole in a phantom. A simulator
that emits several sources at known positions, with known orientations, known
timecourses, and a known noise covariance can score all of them directly.

**These do not need a BEM.** This is the common misconception and it is worth
stating plainly in the roadmap, because it changes what is reachable today. A
distributed inverse needs two things: a **source space** — a discrete grid of
candidate locations — and a **lead field for that grid**. Both are computable in
the concentric-sphere model already implemented. `SphericalForwardModel.leadField`
called on N grid points with free orientation *is* the gain matrix these methods
consume; the free-orientation operator retained in `LeadField` is already the
right shape. Historically this is how the family was introduced — Pascual-Marqui's
original LORETA used a three-shell sphere with a Talairach-registered grid.

What separates the methods is **weighting, not the head model**. All are
minimum-norm variants. A BEM improves fidelity to a real head; it is not a
precondition for the methods to run, and for *comparing* methods the analytic
sphere is arguably better, because the forward model is exact and no mesh
discretization error confounds the comparison. That is a defensible statement in
a methods paper rather than an apology.

**Effort overall:** medium, and front-loaded — 6.1 is most of the work, after
which each method in 6.2 is a small addition.

## 6.1 Source-space grid abstraction

The prerequisite, and the piece worth designing carefully.

- A `SourceGrid`: candidate positions inside the brain compartment, with a
  spacing parameter, plus fixed-orientation (radial/normal) or free-orientation
  modes. Regular Cartesian sampling clipped to the sphere is sufficient and is
  what most reference implementations use; keep the generation deterministic and
  prefix-stable the way `stableDirection` is, so grid refinement sweeps stay
  interpretable.
- A **neighbourhood Laplacian** over the grid, needed by 6.3 and cheap to build
  at construction time.
- The gain matrix for the grid, computed once and cached — this is `channels ×
  3N` and will be the largest object the tool handles, so it wants an on-disk
  form and a hash tied to the head model and montage.

The same abstraction serves 5.2: the surrogate method's 29 regional sources are
a very coarse source grid with free orientation, so building this first makes
5.2 a special case rather than separate code.

**Effort:** medium. **Blocks:** all of Tier 6, simplifies 5.2.

## 6.2 The minimum-norm family

With the gain matrix, an SVD, and a regularization parameter, these are each
roughly a page of linear algebra:

- **MNE** — ridge-regularized minimum norm. The baseline everything else is
  measured against.
- **dSPM** — MNE noise-normalized by the projected noise covariance.
- **sLORETA** — normalized by the resolution-matrix variance, which buys zero
  localization error for a single point source in the noiseless case.
- **eLORETA** — reweighted to achieve that exactly, iteratively.

**The noise covariance is itself a ground truth we can emit and nobody else has.**
dSPM and its relatives are sensitive to how the noise covariance is estimated,
and in practice it is always estimated from a baseline window and always wrong by
an unknown amount. The simulator knows it exactly. Emitting both the true
covariance and a baseline-window estimate, and scoring the same method under
each, isolates a source of error that the literature can only discuss
qualitatively. This is the most novel thing in Tier 6.

Regularization choice (fixed λ, L-curve, generalized cross-validation) should be
a declared, swept parameter rather than a hidden default — it moves the rankings
more than the choice among the methods does, and comparisons that fix it
arbitrarily are a known weak point in the literature.

**Effort:** small each, after 6.1.

## 6.3 The spatial-prior family

**LORETA** and **LAURA** add a smoothness prior via the grid Laplacian from 6.1.
Mechanically a small addition once the Laplacian exists; the work is in getting
the boundary handling at the compartment edge right, which is where these methods
are most often implemented subtly differently from the published description.

**Effort:** small-medium. **Depends on:** 6.1.

## 6.4 Resolution metrics

Most of what one wants to say about a distributed inverse comes from the
**resolution matrix** `R = G⁺G`, which is computable analytically from the gain
matrix and the inverse operator — **no simulation run required at all**. From it:

- **Point-spread and cross-talk functions** per grid point.
- **Peak localization error** — the distance from a seeded point to the maximum
  of its point-spread function.
- **Spatial dispersion** — how smeared the reconstruction is, which is the axis
  on which the smoothness-prior methods trade against the minimum-norm ones.

These belong alongside `SourceMetrics`, and they are cheap enough to compute
across the whole grid for every method and every regularization value, which
makes them the natural substrate for a sweep figure. Simulation is then needed
only for the questions resolution analysis cannot answer — noise, correlated
sources, non-stationarity, and residual artifact.

**Effort:** small. **Note:** the highest value-per-unit-work item in Tier 6, and
it can be done immediately after 6.1 and 6.2's MNE alone.

## 6.5 Forward-model mismatch, and the inverse crime

**The item that makes the rest honest.**

If data is generated with the same lead field used to invert it, every method
scores better than it deserves and the ranking may not survive contact with a
real head. This is the inverse crime, and a simulator is the easiest place in the
world to commit it accidentally.

**The cheap fix needs no BEM.** `SphericalHeadModel` already parameterizes shell
radii and conductivities: generate with one set, invert with another, and sweep
the mismatch. Skull conductivity in particular is the parameter real pipelines
get most wrong, and its effect on distributed-inverse ranking is a publishable
question on its own.

**The expensive fix is where BEM finally earns its place** — generate through a
realistic head model, invert through the sphere, report the degradation. Note
that the BEM is wanted here for the *generation* side, to create realistic
mismatch, not because the inverse methods require it. That is the honest
argument for importing a real head model, and it is a better one than "BEM is
more accurate."

Every Tier 6 result should state which regime it was computed in. A number from
a matched forward model is a statement about the algorithm; a number from a
mismatched one is a statement about the method as it would be used.

**Effort:** small (parameter mismatch) to large (BEM import). **Priority:** the
parameter-mismatch version is not optional — do it with 6.2, not after.

---

# Tier 7 — end-to-end pipeline regression

Everything in Tiers 1-6 makes the simulator better. This tier makes the
simulator *useful to EVA every day*, by closing a loop:

> **generate a recording with known truth → let EVA process it headlessly →
> score the result against that truth → assert the score.**

The existing `selftest` validates the simulator's own model. The determinism
baseline (`scripts/check-determinism.sh`) validates that the *generator* does not
drift. Neither says anything about whether EVA's correction pipeline still does
what it did last month — and that is the larger risk, because the pipeline is
where features land.

**Relationship to 3.2.** This is the same machinery as the comparison harness,
pointed at a different question. 3.2 asks *"which method is better?"* and its
output is a table for a paper. Tier 7 asks *"is this method still as good as it
was?"* and its output is a pass or a fail. Build 7 first: it pays off on every
commit, and it leaves 3.2 needing little more than a different reporting layer.

**How much already exists.** More than it looks:

- **Generate** — `eva-simulate generate --config`, with the complete
  `sim_truth.json` sidecar.
- **Process headlessly** — `HeadlessBatchProcessor.process(url:script:outputFolder:)`,
  already exercised in `EVATests/Pipeline/HeadlessBatchProcessorTests.swift`.
  `EVAProcessingScript` already describes a whole pipeline as data, with XML
  read/write in `EVAProcessingScriptXML`.
- **Score** — `score`, `score-events` and `score-erp` from 2.3, all against the
  truth sidecar.

The missing pieces are the glue and — much more importantly — the assertion
policy in 7.2.

## 7.1 Where the suite lives

**In `EVATests`, not in a new tool.** A separate batch runner would be a fourth
way to describe a pipeline, alongside `EVAProcessingScript` XML, `EVAHelper`'s
flags, and `HeadlessBatchProcessor`'s in-process API. Putting the suite where the
headless processor already lives means it rides `xcodebuild test`, which
`run-all-tests.sh` already runs, which CI already runs. No new binary, no new
configuration format, no new CI stage.

**The generation wrinkle.** EVASimulate is a separate command-line tool, and
EVATests runs under sandbox restrictions that make writing generated packages
from inside a test awkward. The clean split:

- `run-all-tests.sh` gains a stage that generates the regression corpus into a
  temporary directory and exports its path in an environment variable.
- The tests read that variable, and **skip cleanly when it is absent**, so a bare
  `xcodebuild test` stays fast and green for someone working on unrelated code.
- The corpus is regenerated every run rather than committed. No binary blobs in
  git, and the generator/pipeline seam is exercised rather than frozen.

## 7.2 What to assert — the part that decides whether this works

Suites of this kind die one of two deaths. Assert exact values and every
legitimate improvement breaks the build until somebody mutes it. Assert loose
bounds and nothing is ever caught. The way out is that **we have ground truth**,
so assertions can be about meaning rather than about bytes.

**Never hash EVA's output.** See 7.4.

### Metric floors

Each corpus entry declares what its pipeline must achieve, scored against truth:

- **Broadband and per-band SNR floors** after gradient and BCG correction.
- **Spectral fidelity** — corrected band power within a stated percentage of the
  known clean spectrum. This is what makes *over-filtering* visible, and it is
  the failure a naive SNR floor will happily pass.
- **Detection quality** — F1, sensitivity and timing error for BCG beats and TR
  markers, scored by `score-events` against the event times already in the
  sidecar.
- **ERP recovery** — amplitude and latency bias against per-trial truth, which
  1.2 and 4.8 already emit (use the non-overlapping subset via
  `--exclude-overlap`).
- **Per-channel floors**, so one destroyed channel cannot be averaged away by a
  broadband number that still passes.

### The √N ceiling as an *upper* bound

The README establishes that naive average-artifact subtraction has a ceiling of
`std(EEG)/sqrt(N)` — a "perfect" AAS on 20 volumes scores SNR 4.47, not infinity.
That makes an upper-bound assertion available, and it is worth more than it
looks: a result that scores *above* the ceiling is either doing something
genuinely smarter or **leaking ground truth into the correction**, and the second
is precisely the bug that an end-to-end harness would otherwise conceal. Assert
both sides.

### The watermark file

Floors alone hide slow drift: a number can fall from 6.2 to 4.1 for years and
never trip a floor of 4.0. So alongside the floors, commit a **watermark file**
recording the *achieved* value of every metric — the same shape as
`determinism-baseline.txt`, but with tolerance rather than equality.

- A meaningful change shows up as a reviewable diff, the way the determinism
  hashes do.
- Improvements are visible instead of silent, which is the point: "wavelet
  reduction improved alpha fidelity from 94% to 98%" is a fact worth having in
  the commit history.
- Regeneration is deliberate and its own commit, and that commit is the record
  that pipeline behaviour changed.

Tolerance bands need to be wide enough to absorb float-level differences across
machines (7.4) and narrow enough to catch a real change. Start generous, tighten
as the numbers prove stable.

## 7.3 The corpus

The point of a corpus rather than one recording is that different scenarios fail
in different ways. A reasonable starting set, all short — 60 s is enough:

- **Locked-clock gradient.** The case where template subtraction should cancel
  exactly, so the score is compared against the √N ceiling. The most sensitive
  entry in the corpus.
- **Drifting-clock gradient.** The realistic case, with the paper's 152 µs/s.
- **BCG with QRS detection jitter.** Separates timing-dependent methods (AAS and
  relatives) from ones that do not use beat timing. The truth sidecar's separate
  true and *detected* beat times are what make this scoreable at all.
- **Oddball ERP under noise.** Scores `EVA/Trials/` and
  `SingleTrialAnalyzer.swift`, which have no ground truth today.
- **Bad channels, bridging, and a bad reference.** Detection metrics rather than
  correction metrics — scoring whether EVA *finds* the defect it was told about.
- **Clean control.** No artifact at all. Asserts that the pipeline does not
  damage a recording that needed no correction, which is a real regression class
  and one no artifact-focused entry can catch.

Each entry pairs a scenario file with an `EVAProcessingScript`, both committed,
both versioned. Reuse the shipped `scenarios/` where they fit rather than
duplicating configuration.

## 7.4 Non-determinism is a constraint, not a bug to fix

**The generator is deterministic and gets hashed. The pipeline is not and gets
scored.** Keeping that distinction is what stops this suite from becoming a
source of false failures.

`EVAHelper` already exposes `--cwl-backend metal|cpu|compare` with
`--compare-max-diff`, `--compare-rms-diff` and relative variants, and
`WaveletMetalBackendTests` compares the GPU reduction against the CPU one — so
the divergence is already known and already tolerated deliberately. CI runners
are virtual machines without a usable Metal device, so a hash or an exact
expectation recorded on a development Mac would fail on CI permanently and for no
real reason.

Therefore:

- **Pin CPU backends** in every regression script. Determinism of the *assertion*
  matters more here than exercising the fast path; GPU/CPU agreement is already
  covered by its own dedicated test.
- **Express every expectation as a tolerance**, never an equality.
- Record in the watermark which backend produced each number.

## 7.5 Continuous integration — GitHub Actions

**Use GitHub Actions, not CircleCI.** CircleCI has macOS executors and would
work, but the repository already runs GitHub Actions
(`.github/workflows/docs.yml`), so adding a second provider means a second
credential set, a second YAML dialect, and a second thing to keep working, for no
capability gain.

EVA needs a macOS runner regardless — SwiftUI, Accelerate, Metal, `xcodebuild`.

**Staging, following the structure `run-all-tests.sh` already has:**

| Trigger | Stages | Rationale |
| --- | --- | --- |
| Every push | tool builds, `eva-simulate selftest`, determinism check | Fast (~45 s of real work) and pure computation. Catches the majority of breakage. |
| Pull request to `main` | the above, plus `EVATests` and the Tier 7 regression suite | The expensive, valuable pass, run where review happens. |
| Never | `EVAUITests` | Its runner fails to initialize on a busy or headless machine, for reasons unrelated to the code. |

**Budget expectations.** A cold macOS runner spends several minutes before it
does anything useful, so plan for 8-15 minutes wall clock even though the local
run is about two. Public repositories get macOS minutes cheaply; if EVA ever
becomes private, macOS bills at roughly ten times the Linux rate and the split
above stops being a nicety.

**Failure output matters.** `run-all-tests.sh` already logs to files and prints
only the tail of a failing stage; keep that behaviour in CI. A job that dumps
thirty thousand lines of `xcodebuild` output is a job whose failures stop being
read.

## 7.6 Effort and sequencing

**Effort:** medium. 7.1 and 7.3 are mostly assembly of parts that exist. 7.2 is
the real design work, and it is worth doing slowly — a floor set carelessly is
either noise or decoration.

**Depends on:** 2.3 (metrics) and 2.4 (scenario files), both complete.

**Suggested first slice:** one scenario, one script, one floor, one watermark
entry — the locked-clock gradient case, because its expected value is known
analytically from the √N ceiling rather than merely observed. Get that green in
CI before adding a second entry. A corpus assembled before the assertion policy
is settled will need rewriting anyway.

---

# Tier 8 — simulator-supervised component labelling

Generalizes 5.4 from the BCG to artifact classification as a whole.

**The observation that makes it worth a tier:** EVASimulate already generates
**six of ICLabel's seven classes**, and knows the topography of each.

| ICLabel class | EVASimulate source | Ground truth quality |
| --- | --- | --- |
| Brain | 1.1 dipole sources | **Derived** — three-shell forward model |
| Eye | Ocular dipoles (2.1) | **Derived** — dipole field, approximate eye centres |
| Heart | BCG generators (5.1) | **Derived + modelled** — see 5.1's split |
| Muscle | EMG/chewing/swallowing (2.1) | **Modelled** — fixed regions, controlled carriers |
| Line Noise | Mains model (2.1) | Trivially known per-channel gains |
| Channel Noise | Defects, bridging, bad reference (2.1) | Trivially known |
| Other | — | Not modelled |

So for any ICA decomposition of a simulated recording, every component's true
class membership is computable by projecting its topography onto each known
subspace — and it comes out **graded**, not binary, which is more information
than a human rater can give. That is the same lever as 5.4, applied across the
board.

## 8.0 What I would not do

Stated first, because the failure modes here are more attractive than the
successes.

- **Do not report aggregate accuracy.** It will be dominated by the easy classes
  and will hide failure on the hard ones. Line noise is identifiable from one
  spectral peak; a single bad channel produces a component with a
  one-electrode topography that any rule finds. A classifier scoring 95%
  overall while failing to separate muscle from gamma is worse than useless,
  because the 95% is what gets quoted. **Per-class, always.**
- **Do not train a large model.** Simulated data is unlimited, which makes
  over-parameterization easy and its consequence invisible: the model learns the
  simulator, scores beautifully against the simulator, and transfers poorly. A
  small model over named features is defensible in a methods section; a black box
  trained on synthetic data is not.
- **Do not try to replace ICLabel.** Produce `ICAComponentSuggestion`s that
  compose with it, the way `ICAComponentAutoLabeler` already does.
- **Do not treat the classes as equally well-founded.** See 8.2.

## 8.1 Benchmark the labellers we already have — do this first

Before training anything, score **ICLabel** and **`ICAComponentAutoLabeler`**
against graded truth on simulated recordings, per class.

This is cheap, it needs no new model, and it is a result on its own: nobody has a
per-class, graded-truth benchmark for these labellers, because nobody else can
make one. It also decides how much of the rest of the tier is warranted — if the
existing labellers are already strong on ocular and weak only on Heart, then 5.4
is the whole job and Tier 8 collapses to a paragraph.

Expect the Heart class to do poorly: it was trained on cardiac contamination
recorded *outside* a scanner, and BCG is a different phenomenon (see 5.4).

**Effort:** small. **Do this before committing to anything else here.**

## 8.2 Priority follows provenance, not convenience

The reliability of a simulator-trained classifier inherits the reliability of the
generative model behind each class. That ordering is already documented in the
README's "what comes from the paper and what does not" split, and it should drive
the order of work:

1. **Ocular** — highest value after BCG. Dipole topographies, a genuinely
   distinct spatial signature, and the class where a mislabel costs the most,
   because removing a frontal component takes real frontal EEG with it.
2. **Heart/BCG** — 5.4, already scoped.
3. **Muscle** — valuable but the most hazardous. The README already states that
   EMG uses fixed source regions and controlled carrier families, with no
   motor-unit recruitment or subject-specific anatomy. Real EMG is heterogeneous,
   and that heterogeneity is precisely why it is the hardest class for existing
   labellers. A classifier trained on our EMG learns a stereotype. Worth doing,
   worth labelling clearly as a lower-confidence class, and worth validating
   against real data before anyone relies on it.
4. **Line Noise and Channel Noise** — low priority. Existing heuristics already
   handle them, and the simulator would mostly be teaching the easy case. Useful
   as *negative controls* in the benchmark rather than as targets.

## 8.3 The figure nobody else can produce: controlled overlap

The interesting question in component labelling is not the clean cases, it is the
overlapping ones — a component that is part muscle and part gamma, or part blink
and part frontal delta. Real labelled datasets cannot vary that: whatever overlap
the recording happened to contain is what you get, and the human labels are least
reliable exactly there.

The simulator can dial it continuously — 4.4's shared-band machinery,
`--dipole-near-pair-separation`, EMG band edges against the neural gamma band,
ocular amplitude against frontal source amplitude — and knows the answer at every
setting.

**Classifier performance as a function of controlled brain/artifact overlap** is
the deliverable of this tier. It says where a labeller stops working, which is
what a user actually needs to know, and it is not obtainable any other way.

## 8.4 A second use: ICA identifiability itself

The same corpora answer a question 1.1 raised and nothing has used yet. The true
source count is known — neural dipoles plus BCG generators plus ocular plus
muscle regions — so the simulator can generate the cases where unmixing must
fail: more sources than channels, two sources with near-identical topographies,
sources that move (1.1 already supports all three).

Scoring *decomposition* quality rather than *labelling* quality, with
`SourceMetrics.recoveryScore`, is nearly free once the corpora exist, and it
tells you whether a mislabel was the labeller's fault or whether ICA never
recovered the component in the first place. Those are different problems and are
routinely confused.

## 8.5 The circularity discipline, inherited from 5.4

Everything 5.4 says applies here and matters more, because the weaker generative
models are in this tier:

- Hold out generator configurations; report on the held-out ones.
- Treat simulator-derived thresholds as a prior to test on real data.
- **3.3 (measured template library) is load-bearing**, and for muscle it is close
  to mandatory.
- Record which model version produced each corpus. `sim_truth.json` already
  carries the complete configuration.

## Effort and sequencing

**Effort:** 8.1 small; 8.2-8.3 medium; 8.4 small once the corpora exist.

**Depends on:** Tier 7's corpus machinery, and 5.4 as the pilot — do one class
end to end before generalizing. **Wants:** 3.3 for external validation.

**Note:** the deliverable lands in `EVA/ICA/` rather than in the simulator, which
makes this the first item where the simulator's main product is a *feature of
EVA* rather than a measurement. That is a good sign for the tool, and a reason to
keep the training corpora and their provenance under version control alongside
the model.

---

# Suggested order

For the stated goal of supporting methods papers. **Tiers 1, 2 and 4 are now
complete** (4.1 and 4.2 subsumed by 5.1). Tier 5 is complete apart from ICA-S
and the localization criterion, which waits on Tier 6.

**Done in this pass:** 4.1-4.9 (4.1/4.2 subsumed by 5.1), 5.1, 5.2 for PCA-S,
and 5.3 apart from dipole localization error.

**Next:**

1. **7.1-7.2, first slice only** — one scenario, one processing script, one
   floor, one watermark entry, green in CI. First on purpose: it is the only
   item that pays off on *every* later commit, and the locked-clock gradient
   case has an analytically known expected value to anchor it. Do not build the
   whole corpus yet; settle the assertion policy first.
2. **8.1 benchmark the labellers we already have** — score ICLabel and
   `ICAComponentAutoLabeler` against graded truth, per class. Small, needs no new
   model, and it is a result nobody else can produce. Do it before committing to
   5.4 or the rest of Tier 8: if the existing labellers turn out to be strong
   everywhere except Heart, then 5.4 is the whole job and Tier 8 collapses.
3. **5.4 simulator-trained BCG component labelling** — the pilot for Tier 8 and
   the interesting way to finish ICA-S. One class end to end before
   generalizing. Sits here because it wants Tier 7's corpus machinery.
4. **7.3-7.5** — the rest of the corpus and the GitHub Actions staging, once the
   assertion policy from step 1 has proven itself on one entry.
   **Tier 8 proper (8.2-8.4)** follows here, once 5.4 has shown one class works
   end to end.
5. **3.2 comparison harness** — unblocked now that 4.9 is fixed, and mostly a
   reporting layer over Tier 7's machinery by this point.
6. **ICA-S** (5.2) — the last piece of the Rusiniak comparison, and mostly
   assembly once 5.4 supplies the component selection.

**Tier 6 is deliberately deferred.** It is a capability that would later support
a paper; Tier 5 is the paper. The one exception worth pulling forward is **6.1**,
because the surrogate model's 29 regional sources in 5.2 are a coarse source
grid — building the grid abstraction first makes 5.2 a special case instead of
separate code. If 6.1 gets written for 5.2, then MNE from 6.2 and **6.4
resolution metrics** become cheap enough to do opportunistically, and 6.5's
parameter-mismatch check should travel with them rather than follow later.

Deferred entirely for now: 3.1 multi-subject, 3.3 the measured-template library
(small in code, slow in permissions — start collecting in parallel if it is
wanted), 3.4 clinical patterns, and the rest of Tier 6.

## Known blockers carried from elsewhere

- **Sub-millisecond MFF event times** — **resolved 2026-08-21**; see **4.9**.
  Both `EVA/IO/MFFWriter.swift` and `EVA/IO/MFFReader.swift` were quantizing to
  milliseconds. No longer blocks general-rate support in 3.2 or 1024 Hz runs in
  3.1.
