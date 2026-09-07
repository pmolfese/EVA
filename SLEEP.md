# EVA — Synthetic Sleep EEG

A standalone copy of **PART Sleep** from `ROADMAP.md`, kept here so the plan can
be read and worked on without carrying the whole roadmap around. `ROADMAP.md`
remains authoritative for priority and status; if the two disagree about whether
something is done, the roadmap is right.

Nothing here is started. The milestones are ordered so that SL-1 is useful and
testable on its own — it generates no EEG at all — and each later one is
independently shippable. SL-3 is the first point at which an external tool can
score the output, and is the natural place to stop if the appetite runs out.

---

# PART Sleep — SYNTHETIC SLEEP EEG

Generate a whole night of EEG with a known hypnogram, and with every spindle,
K-complex, slow wave, vertex wave and sawtooth train labelled to the sample. The
output is a normal EVA recording, so it flows through filter / ICA / PCA-S /
scoring exactly like any other, and the truth sidecar answers questions no real
dataset can answer at all.

**Why this is worth building, in one paragraph.** Sleep-EEG methods are validated
against expert scoring, and expert scoring is the weakest link in the chain:
MASS and DREAMS between them offer a few dozen records, spindle marking is
famously low-agreement between scorers, and nobody can tell you the *true* onset
of a spindle in a real recording because there is no such fact to appeal to. A
generator inverts that. A thousand nights, every event's onset and frequency
known exactly, detection scored as a curve rather than as agreement with a
second opinion. EVA already owns the two pieces that make its version of this
better than a generic one: a **dipole forward model**, so slow waves can be a
frontal-midline source and spindles a centroparietal one and the topography is
correct by construction rather than asserted; and the **EEG–fMRI artifact stack**,
which makes "does my BCG correction survive sleep data" answerable for the first
time. That second one is not a hypothetical: the BCG lives around 1 Hz, directly
on top of the slow oscillation, and gradient residuals sit near the spindle band.
Anyone doing sleep in the scanner is correcting artifacts whose spectra overlap
the signals they came for, and right now there is no way to measure what that
costs them.

**The one architectural rule.** Two layers, separated absolutely:

1. **The hypnogram generator** decides the stage sequence. Nothing else.
2. **The signal model** synthesizes EEG conditioned on a stage sequence it is
   handed. It never decides what stage it is in.

Everything good follows from that split. A hand-written hypnogram, a drawn one,
and one imported from a real scored night are the same input to layer 2, so
"resynthesize EEG onto this patient's real architecture" costs nothing extra. It
also means the hypnogram is testable on its own — against transition statistics
from the literature — without generating a single sample.

**The rule that keeps it honest.** *Do not add a waveform the truth file cannot
label.* If a feature cannot be written down as "event of type X at time T on
source S with parameters P", it buys realism at the cost of the only thing that
makes this worth building. This is the reason the plan below phenomenologically
places templates rather than porting a thalamocortical neural-mass model: the
neural-mass models produce beautiful signals that nobody can annotate.

## Literature the model is built on

Every default in this part traces to one of these. Cited so a future reader can
check a number rather than trust it.

**Hypnogram and architecture**

- Kemp B, Kamphuisen HAC (1986). *Simulation of human hypnograms using a Markov
  chain model.* Sleep 9(3):405-414. The original; fitted to 95 hypnograms from
  23 subjects. Its central negative result is the one that matters: a
  **stationary** chain does not reproduce real sleep. Only time-varying rates
  give sleep-onset behaviour, the decline of SWS across the night, and REM-NREM
  periodicity.
- Markov modeling of sleep stage transitions and ultradian REM sleep rhythm
  (2018), PMID 30089099. Second-order transitions plus stage-specific survival
  functions recover the ~90 min REM-onset interval. Take the second-order
  version — first-order chains emit N3 → W → N3 at rates real sleep does not.
- Borbély AA et al. (2016). *The two-process model of sleep regulation: a
  reappraisal.* J Sleep Res 25(2):131-143. And the 2022 *Beginnings and outlook*
  retrospective, J Sleep Res 31(1):e13598. Process S decays exponentially across
  sleep and slow-wave activity is its marker. This is the parameter that makes
  eight hours look like a night instead of like eight repetitions of an hour,
  and it is *physiological* — "prior wakefulness", not an arbitrary decay knob.

**Stage-specific waveforms**

- Schellenberg M et al. (2016). *A thalamocortical neural mass model of the EEG
  during NREM sleep and its response to auditory stimulation.* PLoS Comput Biol;
  PMC5008627. Generates spindles, slow oscillations and K-complexes *and their
  temporal relations* from one mechanism. Read for the phenomenology; do not
  port (see the honesty rule above).
- Cross-frequency slow oscillation-spindle coupling in a biophysically realistic
  thalamocortical neural mass model (bioRxiv 2021.08.29.458101). Same caveat,
  same use: it tells you what the coupling should look like.

**Quantitative parameters**

- *Threshold values of sleep spindle features in healthy adults using scalp-EEG*
  (PMC12172134). Fast spindles: 13.4-14.3 Hz, 0.80-1.11 s, 5.2-15.2 µV,
  1.0-5.8/min. Slow spindles: 12.3-12.9 Hz, 0.79-1.17 s, 4.1-13.2 µV,
  0.03-3.15/min. These are the defaults in SL-3.
- *Individual differences in frequency and topography of slow and fast sleep
  spindles* (PMC5591792). The slow-frontal / fast-centroparietal split, which is
  what SL-3's two source placements encode.

**The aperiodic background**

- *Sources of variation in the spectral slope of the sleep EEG.* eNeuro 2022;
  9(5):ENEURO.0094-22.2022. Fitted over **30-45 Hz**, linked-mastoid: wake
  β = −1.11, N1 ≈ −2.4, N2 = −2.58, N3 ≈ −2.34, REM = −3.3. The slope steepens
  monotonically wake → NREM → REM, REM steepest. **Check this direction against
  the paper before changing it** — secondary summaries of it circulate with the
  sign of the REM effect reversed.
- *Overnight dynamics in scale-free and oscillatory spectral parameters of NREM
  sleep EEG.* Sci Rep 2022;12:18409. Across-night drift of slope and intercept,
  and their relation to slow-wave activity.

**The scoring contract**

AASM Manual for the Scoring of Sleep and Associated Events. The quantitative
rules the generator must satisfy, which is what makes SL-2's acceptance test a
measurement rather than an opinion:

- **N3** — 0.5-2 Hz activity at ≥ 75 µV peak-to-peak occupying ≥ 20% of the
  30 s epoch, frontal derivations.
- **Spindle** — 11-16 Hz, ≥ 0.5 s, maximal centrally.
- **K-complex** — well-delineated negative sharp wave followed by a positive
  component, total duration ≥ 0.5 s, maximal frontally.
- **Vertex sharp wave** — < 0.5 s, maximal centrally. N1.
- **Sawtooth waves** — 2-6 Hz trains, sharply contoured/serrated, maximal
  centrally, often preceding a REM burst.

**Validation targets**

- MASS (Montreal Archive of Sleep Studies) and DREAMS — expert-scored spindles
  and K-complexes, for calibrating morphology against real marking.
- YASA (Vallat & Walker, eLife 2021;10:e70092) — the open detector to benchmark
  against, and the first external check that generated N3 actually scores as N3.

Dependency map:

```text
SL-1 (hypnogram generator + truth + Sleep tab skeleton)  ← testable with zero signal work
   └─→ SL-2 (stage-conditioned aperiodic background + band content)
           └─→ SL-3 (spindles + slow waves as dipole sources)      ← first externally scoreable milestone
                   ├─→ SL-4 (K-complexes, vertex waves, sawtooth, SO-spindle coupling)
                   ├─→ SL-5 (REM: saccade bursts + chin EMG atonia)
                   ├─→ SL-6 (event-level scoring: score-sleep + score-hypnogram)
                   └─→ SL-7 (pathology presets + EEG-fMRI sleep composition)
```

New module: `EVACore/Simulation/Sleep/`
`SleepStage.swift` · `HypnogramGenerator.swift` · `SleepConfig.swift` ·
`SleepBackgroundModel.swift` · `SleepEventModel.swift` · `SleepSourceLayout.swift` ·
`SleepTruth.swift`
App surface: `EVA/App/SimulatorSleepTab.swift` (a tab in Simulator Studio,
alongside Cardiac / Ocular / Muscle).

**Scheduling note:** PART Sleep does not preempt the Part EVA Core execution
order, and it does not block anything. SL-1 through SL-3 are the milestone worth
finishing; SL-4 onward is additive and can be picked up in any order.

---

## SL-1 — Hypnogram generator, truth, and the Sleep tab skeleton — **NOT STARTED**

The whole milestone generates no EEG. That is deliberate: the hypnogram is
separately testable against published transition statistics, and getting it
wrong is the failure that would poison every later milestone invisibly.

- [ ] `SleepStage`: `wake`, `n1`, `n2`, `n3`, `rem`. `Codable`, `CaseIterable`,
  with `aasmLabel` ("W", "N1", "N2", "N3", "R") for export. Epoch length is
  **30 s**, fixed, because that is what the scoring rules and every external
  tool assume.
- [ ] `HypnogramGenerator.draw(config:seed:) -> [SleepStage]` — second-order
  Markov chain over 30 s epochs, with **time-varying rates**. State is the
  current stage *and* the previous one, per PMID 30089099.
- [ ] **Process S** drives the N3 propensity: `S(t) = S₀·exp(−t/τ)`, with `S₀`
  from `sleepPressure` and τ from `processSDecayHours`. The N2→N3 rate scales
  with S, and the N3→N2 rate inversely. This is the mechanism that makes N3
  concentrate in the first two cycles without anything hard-coding "first two
  cycles".
- [ ] **REM propensity** rises with time since sleep onset and with cycle count,
  so REM bouts lengthen toward morning. Target REM latency and cycle period are
  parameters, not constants.
- [ ] **Minimum bout length** per stage, enforced after drawing. Without it the
  chain emits 30 s N3 flickers that no real hypnogram contains and no scorer
  would mark.
- [ ] **Skip-transition control** — an explicit probability for non-ordinal
  moves (N1→N3, N2→W). Real hypnograms are overwhelmingly ordinal; an
  unconstrained chain produces far too many jumps, and detectors trained on real
  data fail in strange ways when handed them. This is a knob, not a constant,
  because deliberately raising it is a legitimate robustness test.
- [ ] Arousals (brief W intrusions, 3-15 s, scored within the epoch) and
  sustained awakenings, as separate rates.
- [ ] `HypnogramSource`: `.markov` (drawn) · `.scripted` (a stage list authored
  in the config) · `.imported` (read a scored hypnogram file). Support at least
  one real format — Sleep-EDF `.hyp` / EDF+ annotations is the widest — so
  "resynthesize EEG onto this patient's real night" works from day one.
- [ ] **Truth:** the hypnogram as an epoch array, plus per-epoch Process S,
  cycle index, and time since sleep onset. Written to the existing truth sidecar.
- [ ] **Events:** each stage transition as an MFF event, so the hypnogram is
  visible on the EVA timeline without any new UI.
- [ ] **Sleep tab skeleton** in Simulator Studio: source picker, duration,
  onset/REM latency, cycle period, sleep pressure, transition preset, and a
  **live hypnogram preview** (a small staircase plot — it costs almost nothing
  and it is the only way to tell at a glance that the parameters are sane).
- [ ] **CLI:** `--sleep`, `--sleep-hours`, `--sleep-preset`, `--hypnogram <file>`,
  `--sleep-pressure`, `--rem-latency`, `--cycle-minutes`, `--skip-transitions`,
  `--arousals-per-hour`.
- [ ] **Gate:** generate 100 nights and check the aggregate statistics against
  the literature — total sleep time, N3 concentrated in the first half, REM
  proportion rising across the night, REM-onset intervals centred near 90 min,
  ordinal transitions dominating. Assert on distributions, not on single nights;
  a single night is legitimately allowed to be unusual.

**Effort:** medium. The chain is small; the calibration gate is the work.

## SL-2 — Stage-conditioned background: aperiodic slope and band content — **NOT STARTED**

Makes the stages distinguishable to anything spectral, before a single discrete
event exists. This is a surprisingly large fraction of the perceived realism for
a small fraction of the effort.

- [ ] **Per-stage aperiodic exponent**, defaulting to the eNeuro values (wake
  −1.11, N1 −2.4, N2 −2.58, N3 −2.34, REM −3.3). Synthesize 1/f^β noise per
  epoch and cross-fade across epoch boundaries — a hard switch at an epoch
  boundary is an audible step and an artifact in every spectral estimate.
- [ ] **Per-stage band amplitudes**, reusing the existing `EEGBand` machinery:
  alpha dominant in wake and attenuating into N1, theta rising in N1, delta
  dominating N3, and REM's mixed-frequency low-amplitude profile.
- [ ] **Overnight drift** of slope and intercept, per Sci Rep 2022, tied to the
  same Process S the hypnogram uses — so the background and the architecture
  are driven by one quantity rather than two that can disagree.
- [ ] **Cross-fade window** as a parameter, defaulting to a few seconds.
- [ ] **Gate:** fit the aperiodic exponent back out of each generated epoch (over
  30-45 Hz, the paper's range) and recover the requested β within tolerance.
  This is a closed loop — the number that goes in comes back out — and it is
  worth more than any amount of eyeballing the trace.

**Effort:** medium. 1/f^β synthesis is standard; the epoch cross-fade is the
fiddly part.

## SL-3 — Spindles and slow waves as dipole sources — **NOT STARTED**

The first milestone whose output an external tool can score, and the point at
which the feature starts earning its keep.

- [ ] **Source placement** (`SleepSourceLayout`): slow waves as a frontal-midline
  source, fast spindles centroparietal, slow spindles frontal. Under
  `--eeg-model dipole` these project through the existing forward model and the
  topography is correct by construction. Under the Grouiller model, fall back to
  a fixed topography and **say so in the truth file** — a topography that was
  asserted must be distinguishable from one that was derived.
- [ ] **Spindle events** as `HighRateTemplate` instances — the same mechanism the
  BCG and ERP already use. Gaussian-windowed sinusoid, waxing and waning.
  Parameters per spindle, drawn from the PMC12172134 ranges: frequency,
  duration, amplitude. Fast/slow ratio and per-stage density are config.
- [ ] **Slow-wave events**: 0.5-2 Hz, with the asymmetric down-state/up-state
  morphology rather than a sinusoid. Density and amplitude per stage.
- [ ] **The N3 rule as a closed loop.** Amplitude is calibrated so that a
  generated N3 epoch actually meets the AASM criterion — ≥ 20% of the epoch at
  ≥ 75 µV peak-to-peak in 0.5-2 Hz, measured frontally. Do not set an amplitude
  and hope. Measure the generated epoch, and make the test assert it.
- [ ] **Truth:** every spindle (onset, duration, peak frequency, amplitude,
  source, fast/slow) and every slow wave (onset, duration, amplitude, source),
  as a typed array in the sidecar. This is the deliverable.
- [ ] **Gate:** (1) the N3 rule above; (2) run **YASA**'s spindle detector over a
  generated night and check detection rate and onset error against the truth
  file. An external detector agreeing with the generator is the first real
  evidence the morphology is right — and where it disagrees, the disagreement is
  interesting rather than embarrassing.

**Effort:** medium-large. The templates are easy; source placement and the N3
calibration loop are the work.

## SL-4 — K-complexes, vertex waves, sawtooth waves, SO-spindle coupling — **NOT STARTED**

- [ ] **K-complexes**: negative sharp wave then positive component, total ≥ 0.5 s,
  frontal-maximal per AASM. Both spontaneous and evoked — the evoked path should
  reuse the ERP machinery's stimulus timing, which makes auditory-stimulation
  sleep protocols expressible.
- [ ] **Vertex sharp waves**: < 0.5 s, Cz source, N1.
- [ ] **Sawtooth waves**: 2-6 Hz serrated trains, central, placed just before REM
  saccade bursts (SL-5) so the temporal relation AASM describes actually holds.
- [ ] **SO-spindle coupling** — spindles preferentially placed at a configurable
  phase of the slow oscillation, with configurable strength. `PhaseAmplitudeCoupling
  Config` already exists and this is the same machinery pointed at a new pair of
  bands. Truth records each spindle's SO phase, which makes coupling-strength
  estimators scoreable against a known answer. This is the most-published measure
  in the sleep/memory literature and the one where a generator with known ground
  truth is worth the most.
- [ ] **Gate:** recover the imposed coupling phase and strength from the generated
  signal, the same closed-loop shape as SL-2's exponent check.

**Effort:** medium.

## SL-5 — REM: saccade bursts and muscle atonia — **NOT STARTED**

- [ ] **REM saccade bursts** on the EOG channels, using the existing ocular model
  with REM-appropriate timing and density.
- [ ] **Chin EMG atonia** — muscle tone *drops* in REM, which the existing EMG
  model can express with a per-stage amplitude scale. Worth calling out because
  no threshold-based artifact detector expects a channel to get quieter, and
  several will mis-handle it.
- [ ] Per-stage EMG and movement-artifact scaling generally: a sleeping subject
  moves less, and then moves a lot at an arousal.
- [ ] **Gate:** REM epochs show the expected EOG burst density and reduced EMG
  amplitude relative to NREM.

**Effort:** small. Both models exist; this is per-stage modulation of them.

## SL-6 — Scoring: `score-sleep` and `score-hypnogram` — **NOT STARTED**

Ground truth that cannot be scored is decoration. `score-events` already exists
and does most of this; these are two thin subcommands over it.

- [ ] `eva-simulate score-hypnogram --truth <truth.json> --scored <hypnogram>` —
  epoch-wise agreement, Cohen's κ, and a confusion matrix by stage. κ against a
  *known* hypnogram is a fundamentally different measurement from κ between two
  scorers, and the distinction is worth stating in the output.
- [ ] `eva-simulate score-sleep --truth <truth.json> --detected <events> --type
  spindle|slow-wave|k-complex` — detection rate, false-positive rate, onset error
  distribution, and duration error. Reuse `score-events`' matching logic.
- [ ] Tidy CSV export of both, in the same schema the rest of the simulator's
  scoring uses.

**Effort:** small. Mostly plumbing over machinery that exists.

## SL-7 — Pathology presets and EEG-fMRI sleep composition — **NOT STARTED**

- [ ] **Presets**, each a transition matrix plus per-stage content overrides:
  *healthy young adult* · *elderly* (reduced N3, fragmented) · *sleep-onset REM*
  (narcolepsy) · *periodic arousals* (apnea-like) · *suppressed N3* (depression) ·
  *spindle deficit* (the schizophrenia phenotype; see Nature Schizophrenia
  2019;5:9 for the distributed slow-wave dynamics).
- [ ] **Sleep-in-scanner composition** — a scenario that layers the gradient
  artifact and BCG on top of a generated night. This is the milestone the whole
  part is pointed at: the BCG sits around 1 Hz, on top of the slow oscillation,
  and gradient residuals sit near the spindle band, so a correction that looks
  fine on awake resting-state data may be removing the signal. With this, "how
  many true spindles survive AAS + OBS correction" is a number.
- [ ] Ship it as `scenarios/sleep-in-scanner.json` and add it to the determinism
  baseline.
- [ ] **Gate:** score spindle recovery through the full artifact-correction
  pipeline, against the truth file, at several BCG amplitudes. That curve is a
  publishable figure and it is the argument for the entire part.

**Effort:** medium. The presets are data; the composition scenario is the
valuable half.

---

### Design decisions already made, and why

Recorded so they are not relitigated from scratch later.

- **Phenomenological templates, not a neural-mass model.** The thalamocortical
  models in the literature are better physics and produce signals nobody can
  annotate. The entire value proposition here is event-level ground truth. If a
  neural-mass background is ever wanted, it belongs *underneath* the labelled
  events, not instead of them.
- **Second-order Markov, not first-order.** First-order chains emit implausible
  transitions at rates that make the output useless for anything trained on real
  hypnograms.
- **Sources, not channels.** Generating per-channel sleep waveforms would be
  faster and would waste the forward model EVA already has. Source-space sleep
  truth is a thing no other synthetic sleep data offers.
- **30 s epochs, fixed.** Every scoring rule and every external tool assumes it.
  A configurable epoch length would buy nothing and break interoperability.
- **Process S is one quantity, used twice.** Both the hypnogram's N3 propensity
  and the background's overnight slope drift read the same `S(t)`. Two decay
  parameters that could disagree would be a bug waiting to happen.
- **Defaults are off.** `sleepEnabled` defaults false, and all new config fields
  are Optional — Swift's synthesized `Decodable` requires every non-Optional key,
  so a non-Optional addition makes every scenario file written before it
  undecodable. This has already bitten once; see the `effective*` accessors on
  `SimulationConfig`.
