# Synthetic sleep EEG — design reference

The literature the sleep model is built on, and the design decisions already
settled. **Milestone status is in `ROADMAP.md` § Simulation (SL-1 … SL-7);
nothing is started.**

---

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

---

