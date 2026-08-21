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

## Where it is now

Implemented, tested, and documented in `docs/manual/tools/eva-simulate.md`:

- **EEG**: seven band-limited Gaussian sources, 1-70 Hz with a notch gap,
  modulated alpha, circular or geometric spatial correlation.
- **Gradient artifact**: slice/volume structure, EEG-MRI clock drift, slow
  amplitude modulation, anti-alias modelling, measured-template import.
- **BCG**: rate modulation, heart-rate variability, beat-to-beat amplitude
  correlation, per-channel latency and polarity, separate true and *detected*
  beat times.
- **Ocular**: blinks as transients, eye movements as gaze-position steps.
- **Recording defects**: five bad-channel kinds, mains noise, per-electrode
  impedance tied to the defect.
- **Montage**: 10-20 positions with `sensorLayout.xml` and `coordinates.xml`.
- **Scoring**: per-band SNR and power ratio against ground truth.
- **13 self-tests** on the model's own behaviour, and byte-level determinism.

## Principles to hold onto

These are what make the tool trustworthy; every item below should preserve them.

1. **Determinism is not negotiable.** Same seed, byte-identical output. A
   benchmark that moves between runs cannot support a claim.
2. **Defaults reproduce the paper.** Every addition ships off by default, or
   with a documented flag that restores the published behaviour (`--hrv 0` is
   the pattern). A user who wants the benchmark must not have to know what was
   added since.
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

**The largest structural change here, and the one most other items compose
with.**

Today every topography is an ad-hoc weight vector: the blink is a cubed cosine to
an assumed eye direction, the BCG is a smooth function of channel angle. They
look right and they are entirely made up. Replacing them with dipoles projected
through a forward model would give, in one move:

- Physiologically correct topographies, for free, for every source.
- **Known source locations**, so source-localization methods can be scored.
- **Controllable ICA separability** — the number of true sources becomes a
  parameter, and you can generate the cases that break unmixing (more sources
  than channels; two sources with near-identical topographies; sources that move).
- Correlated-source scenarios, which is where most blind-separation methods
  actually fail and which no current parameter can produce.

**Sketch.** A three-shell spherical head model gets most of the value for a
fraction of the work of a BEM: analytic lead field, no meshes, no external
dependency. Define sources as `(position, orientation, timecourse)`; compute the
`channels × sources` gain matrix once; the projection is a matrix multiply.
`EVA/Channels/SphericalSpline.swift` already carries spherical-harmonic machinery
worth reading before starting. A later BEM option could import a real head model
without changing the interface.

**Effort:** large. **Unblocks:** 1.2, 1.3, meaningful ICA evaluation, anything
about topography. **Risk:** the interface, not the maths — get
`SimulatedSource` right and the rest follows.

## 1.2 ERPs with trial-to-trial variability

**Highest value per unit of work in Tier 1, and it needs nothing else first.**

EVA's Trials module implements Woody, RIDE and CWT-ridge single-trial latency
estimation, and there is currently **no ground truth to test any of it against**.
A simulator that emits trials with *known* per-trial latency and amplitude is the
natural test bed, and the resulting figure — recovered versus true latency,
across SNR — is the core of a methods paper on its own.

**Sketch.**

- Component definition: a waveform (Gaussian-derivative or measured), a peak
  latency, a topography (ad hoc now, a dipole after 1.1), and an amplitude.
- Per-trial draws: latency jitter (normal or skewed), amplitude jitter,
  occasional omissions, and a *latency-amplitude correlation* — the confound
  that motivates most single-trial methods.
- Experimental design: conditions, trial counts, ISI distributions, oddball and
  target/standard structure. Emit condition codes as MFF events so EVA's own
  epoching path consumes it unchanged.
- Ground truth to the sidecar: per trial, its true latency and amplitude.

**Effort:** medium. **Unblocks:** validation of everything in `EVA/Trials/` and
`EVA/Epoching/SingleTrialAnalyzer.swift`. **Note:** this is the item most likely
to produce a publishable result quickly.

## 1.3 Non-stationarity

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

**Effort:** medium (bursts) to large (microstates). **Unblocks:** trustworthy
ICA evaluation; PAC method validation.

---

# Tier 2 — high value, self-contained

## 2.1 More artifact types

The current set is MR-centric plus ocular. The gaps most often needed:

- **EMG / muscle.** The most-requested missing artifact. Broadband above ~20 Hz,
  temporalis- and neck-weighted, bursty. Defeats spectral methods in a way
  nothing currently modelled does.
- **Chewing and swallowing.** Stereotyped bursts, useful for detection work.
- **Cable sway / movement.** Low-frequency, spatially broad, correlated across
  neighbouring channels.
- **Sweat.** Very low frequency drift, often single-channel.
- **True electrode bridging.** Two channels sharing one signal. This is a
  *different* failure from the current `flat` defect and is the case that
  bridging detectors are built to catch — model it as a correlated pair.
- **A bad reference.** Contaminating every channel identically. Distinctive,
  common, and routinely misdiagnosed as global noise.
- **Saturation / clipping.** Hard rails, which break linear methods in a way
  additive artifacts do not.

**Effort:** small each; they share the injection machinery in
`ChannelDefectModel.swift` and `OcularArtifactModel.swift`.

## 2.2 Impedance-coupled noise

We record per-electrode impedance and we generate per-channel noise, and the two
are currently **independent**. Physically they are not: a high-impedance contact
picks up more thermal noise and more interference. Wiring noise amplitude and
mains pickup to impedance would make the recording internally consistent and make
impedance genuinely predictive rather than decorative — with the `flat`/bridged
case still deliberately breaking the correlation, since that is the lesson.

**Effort:** small. **Note:** do this before anyone uses the harness to evaluate
impedance-based channel rejection, or the evaluation is circular.

## 2.3 Richer metrics

SNR alone is thin for a paper, and the paper itself lists its limitations.

- **RMSE and per-band correlation**, which are not normalized and so say
  different things than SNR.
- **ERP-specific**: amplitude and latency bias in the recovered average, which is
  what an ERP researcher actually cares about.
- **Spectral distortion**: how much the corrected PSD deviates from truth, per
  band — over-filtering made visible.
- **Detection metrics.** ROC, sensitivity and specificity for artifact
  *detection*, scored against the known event times already in the sidecar. Many
  methods papers are about *finding* artifacts, and the harness currently cannot
  score that at all despite having the ground truth sitting right there.
- **Per-channel breakdown**, so a single bad channel is visible instead of
  averaged away.

**Effort:** small to medium. **Dependency:** none. **Note:** the detection
metrics are the notable gap — everything needed is already written to
`sim_truth.json`.

## 2.4 Scenario files

Forty command-line flags do not fit in a methods section. A scenario file —
YAML or JSON, holding the whole configuration plus the seed — means a paper can
say "scenario `bcg-jitter-sweep`, seed 20260821" and a reviewer can regenerate
the data byte-for-byte.

**Sketch.** `SimulationConfig` is already `Codable`, and `sim_truth.json` already
embeds the complete configuration — so a run is *already* self-describing. The
work is: `--config <file>` to load one, `--write-config <file>` to save one, and
flags that override a loaded file. A `scenarios/` directory of named, versioned
configurations would ship with the tool.

**Effort:** small. **Value:** disproportionate — this is what makes results
citable, and it composes with 3.2.

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

**Effort:** medium-large. **Depends on:** 2.3, 2.4. **Blocked by:** the event
precision bug in `TODO_Aug21.md` item 3 — an automated sweep cannot tolerate
recordings that EVA's own gradient stage intermittently refuses.

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

# Suggested order

For the stated goal of supporting methods papers:

1. **2.4 scenario files** and **2.3 richer metrics** — cheap, and they are what
   make any result publishable. Do these first regardless of what follows.
2. **1.2 ERPs with trial jitter** — self-contained, needs no forward model, and
   immediately serves work already in EVA that has no ground truth today.
3. **2.1 artifact types** (EMG first) and **2.2 impedance coupling** — small,
   independent, high realism return.
4. **1.3 non-stationarity**, starting with bursts — until this lands, ICA
   conclusions from simulation stay untrustworthy and must be labelled as such.
5. **1.1 source-space simulation** — commit to it when ready; it reshapes the
   architecture and everything after it gets easier.
6. **3.2 comparison harness** — once metrics and scenarios exist, and once
   `TODO_Aug21.md` item 3 is fixed.

## Known blockers carried from elsewhere

- **`TODO_Aug21.md` item 3** — MFF event times are quantized to milliseconds by
  `MFFWriter`, so at 1024 Hz a generated recording's TR markers can be rejected
  by EVA's own spacing check. Diagnosed, fix verified, not yet applied. Blocks
  3.2 and makes 3.1 unreliable.
