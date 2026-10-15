# When Artifact Correction Removes the ERP

## Paper concept: acquisition-phase locking, multiband timing, and signal preservation in simultaneous EEG-fMRI

**Status:** Working literature assessment and study plan  
**Prepared:** 2026-09-27

## Central argument

There is a scientific paper in the FASTR reliability work, but its strongest
claim is not that we invented upsampling, alignment, moving templates, or
slice-based gradient correction. Those ideas are established. The gap is that
their interactions have not been evaluated adequately for modern multiband
acquisition and event-related EEG.

The central result is:

> Slice-based gradient correction can systematically erase genuine ERPs when
> task timing is commensurate with the scanner cycle, and conventional
> artifact-quality metrics may fail to reveal the loss.

The paper should show how this failure depends jointly on:

1. scanner acquisition timing;
2. experimental event timing;
3. donor-selection strategy;
4. clock synchronization and alignment behavior; and
5. the temporal shape of the neural response.

A suitable working title is:

> **When artifact correction removes the ERP: acquisition-phase locking,
> multiband timing, and signal preservation in simultaneous EEG-fMRI**

## What the literature already establishes

| EVA observation | Existing literature | Remaining gap |
|---|---|---|
| Accurate EEG-scanner synchronization is critical. | Hardware synchronization greatly improves template subtraction and can eliminate the need for oversampling. [Mandelkow et al., 2006](https://pubmed.ncbi.nlm.nih.gov/16861010/) | When synchronization is known, should fractional alignment be disabled because it can make correction worse? |
| Upsampling and trigger alignment help asynchronous data. | These are core FASTR stages. [Niazy et al., 2005](https://www.sciencedirect.com/science/article/pii/S1053811905004726). FACET used 10-fold interpolation. [FACET](https://pmc.ncbi.nlm.nih.gov/articles/PMC3840732/) | The useful interpolation plateau, its interaction with epoch geometry, and harm from unnecessary fractional alignment have not been mapped systematically. |
| Very high recorded sampling rates plateau. | Grouiller et al. reported little additional improvement above approximately 1–2 kHz. [Grouiller et al., 2007](https://pubmed.ncbi.nlm.nih.gov/17766149/) | Recorded sampling rate has not been cleanly separated from internal upsampling, donor count, multiband geometry, and clock synchronization. |
| Too few template epochs can absorb EEG, while too many can track changing artifacts poorly. | Allen chose at least 25 volume epochs and 100 slice epochs based on assumed EEG independence. [Allen et al., 2000](https://web.mit.edu/swg/ImagingPubs/Multimodal%20Imaging/Allen.NeuroImage.2000.pdf). Later work explicitly recognizes the short-window signal-removal versus long-window residual-artifact trade-off. [Ferreira et al., 2016](https://pmc.ncbi.nlm.nih.gov/articles/PMC4942699/) | There is little systematic evidence tying the useful number of volumes to TR, recording duration, stationarity, sampling rate, and donor-selection strategy. |
| Motion-sensitive donor selection helps nonstationary artifacts. | This is established by realignment-informed and other movement-aware templates. [Moosmann et al., 2009](https://pubmed.ncbi.nlm.nih.gov/19349230/); [Sun and Hinrichs, 2009](https://pubmed.ncbi.nlm.nih.gov/19365799/) | The neural-signal safety of the donor rule has received much less attention than residual-artifact suppression. |
| Correlation-selected donors may select brain signal. | FARM-style matching selects similar artifact epochs. FARM was originally developed primarily for motion-corrupted EMG rather than cognitive ERPs. [van der Meer et al., 2010](https://pubmed.ncbi.nlm.nih.gov/20117046/). FACET uses the 12 best-correlated artifacts from a 50-slice window. [FACET](https://pmc.ncbi.nlm.nih.gov/articles/PMC3840732/) | The located literature does not directly demonstrate that correlation ranking preferentially selects and subtracts a repeatable ERP when its phase is stable relative to the TR. |
| Multiband slices occur in simultaneous acquisition groups. | This is a fundamental property of multiband imaging. An EEG-multiband study showed acceptable corrected spectra using traditional subtraction and scanner/RF markers. [Egan et al., 2021](https://pubmed.ncbi.nlm.nih.gov/34214093/) | The located literature does not systematically quantify the error from treating anatomical slice count as sequential artifact epochs instead of using distinct acquisition groups. |
| Scanner-locked events can leave time-locked residuals. | Kraljič et al. warned that volume-locked experimental events can make residual MR artifacts survive ERP averaging and systematically deform ERPs; they proposed approximately 50 ms of event jitter. [Kraljič et al., 2022](https://www.frontiersin.org/journals/neuroimaging/articles/10.3389/fnimg.2022.968363/pdf) | Their concern was primarily residual-artifact enhancement or deformation. EVA's result is different and more severe: the correction template itself can absorb and remove the true ERP. |

## The clearest scientific gap

Classical template subtraction assumes that neuronal EEG is uncorrelated
across artifact epochs. That assumption fails when experimental events occupy
the same low-order phase relationship to the TR, such as exactly one TR,
one-half TR, one-third TR, or two-thirds TR.

Correlation-ranked donor selection compounds the problem. It cannot determine
whether two epochs correlate because their gradient artifacts are similar or
because they contain the same P300, N400, P600, or other repeatable neural
response. A more repeatable ERP may therefore become a more attractive artifact
donor.

This creates a mechanistic prediction:

> When event timing is concentrated at a stable phase of the scanner cycle,
> correlation-ranked slice templates can treat the ERP as part of the gradient
> artifact and subtract it.

The current EVA simulations quantify that mechanism:

- Exact low-order ERP/TR relationships produced near-total ERP loss under
  correlation-ranked slice templates.
- Representative P50, N100, N170, P200, N200, P300, N400, and P600 components
  retained only about 18–20% of amplitude in the locked condition.
- Detuning the schedule and adding jitter restored approximately 100–106% of
  amplitude in that simulation.
- A corrected waveform could retain correlation of 0.87–1.00 with the expected
  ERP while containing almost none of its true amplitude.
- Apparent corrected ERP SNR could be approximately equal to the no-ERP
  false-positive SNR.
- Temporal-neighbor donors protected early components much better, but broad
  late components were still narrowed or attenuated.
- Circular phase concentration of at least 0.8 over the first four TR
  harmonics bounded retained amplitude to at most approximately one-third in
  the tested phase sweep.

The combination of a demonstrated mechanism, component-specific transfer
functions, false-positive SNR, and a computable phase-risk indicator appears to
be genuinely under-addressed in the existing literature.

## A second contribution: multiband acquisition timing

Published multiband EEG-fMRI work shows that traditional correction can
produce plausible spectra, but generally does not ask what happens when
software reconstructs slice epochs incorrectly from volume markers.

EVA's simulations found:

- Correct acquisition-group timing left residual artifact fractions around
  0.0001–0.001.
- Treating all anatomical slices as sequential acquisitions could increase the
  residual to approximately 0.006–0.325, depending on acquisition geometry.
- The failures depended non-monotonically on TR and slice count, making them
  resemble unexplained FASTR instability rather than a timing-model defect.
- Rounding acquisition positions on the native EEG grid before upsampling
  caused similarly large, geometry-specific failures.

This supports a concrete methods claim:

> In multiband EEG-fMRI, the gradient-correction epoch is the distinct
> acquisition time, not the reconstructed anatomical slice, and timing should
> be projected directly onto the correction grid.

For uniform multiband timing, total anatomical slices plus multiband factor is
sufficient to derive acquisition groups. Nonuniform schedules require explicit
timing offsets from sequence metadata, a JSON sidecar, or another reliable
source.

## Synchronization and alignment

The literature already demonstrates the benefits of synchronizing the EEG and
scanner clocks. The potential contribution here is narrower: alignment should
depend on the acquisition's synchronization regime.

The current evidence supports these profiles:

- **Scanner-slaved, known schedule:** no alignment by default, with an optional
  very small integer-grid diagnostic or correction.
- **Independent or drifting clocks:** bounded integer alignment followed by
  fractional refinement.
- **Unexpectedly large shifts in a scanner-slaved recording:** warn about
  synchronization or acquisition-metadata problems rather than silently
  following the shifts.

In the scanner-slaved sweep, fractional refinement increased residual artifact
despite improving epoch correlation. This also shows that correlation
improvement alone is not a sufficient alignment-quality or brain-safety gate.

## Sampling rate, upsampling, and recording duration

The sampling-rate result largely corroborates prior reports rather than
establishing a wholly new plateau. Its useful addition is separating recorded
sampling rate from the internal interpolation grid.

The current results show:

- The dominant improvement in correlation-ranked slice correction was related
  to the number and suitability of donor volumes, not a separate minimum TR at
  each sampling rate.
- Approximately 100–200 usable volumes was the main knee in the stationary
  simulations.
- A 500 Hz recording with 5-fold internal upsampling captured most of the
  useful interpolation gain in the tested geometry.
- Increasing from 5-fold to 10-fold roughly halved the remaining artifact but
  took almost four times as long.
- Equal nominal effective sampling rates were not interchangeable because
  interpolation phase and epoch geometry also mattered.
- More recording time enlarged the donor candidate pool for correlation-ranked
  selection, but did not necessarily justify using the entire run as a single
  donor neighborhood.
- Under gain or phase regime changes, broad donor windows could be worse than
  local windows. Approximately 100–200 volumes is therefore useful coverage,
  not evidence that all available volumes should become donors.

The paper should describe these as conditional knees rather than universal
minimums or universal plateaus.

## What should not be claimed as novel

The paper should not claim novelty for:

- upsampling itself;
- sub-sample alignment itself;
- hardware synchronization;
- moving artifact templates;
- motion-informed templates;
- the general warning that artifact correction may remove neuronal signal;
- event jitter as a general recommendation; or
- the broad observation that recorded sampling above 1–2 kHz offers
  diminishing returns.

The novel value is the interaction map, quantitative neural-signal transfer
measurements, and safeguards derived from those measurements.

The 8-versus-24-lobe Lanczos result is useful supporting engineering but is not
the scientific headline. It explains why more elaborate interpolation is not
universally better, especially when volume and slice epochs occupy different
bandwidth regimes. It is best treated in a methods appendix or supplement.

## Proposed research questions

The manuscript can be organized around four questions.

### 1. When does slice-based correction erase task-evoked EEG?

Sweep:

- event-to-TR phase relationships;
- phase concentration and event jitter;
- ERP component shape and width;
- temporal, correlation-ranked, and motion-informed donors;
- template scaling;
- OBS and ANC stages; and
- slice-based versus volume-template methods.

### 2. Can conventional quality metrics detect the loss?

Compare:

- gradient residual energy;
- waveform correlation;
- ordinary corrected ERP SNR;
- trigger-matched no-event or permuted false-positive SNR;
- amplitude-transfer coefficient or beta;
- peak latency;
- half-height width;
- signed area; and
- absolute area.

A high waveform correlation must not be interpreted as signal preservation. A
cleaned trace can preserve the outline of a component while losing most of its
effect size.

### 3. How does modern acquisition geometry affect correction?

Test:

- single-band and multiband sequences;
- correct acquisition groups versus anatomical-slice assumptions;
- uniform and nonuniform slice-timing schedules;
- native-grid rounding versus direct high-rate-grid projection;
- scanner-slaved and drifting clocks;
- recorded rates of 250, 500, 1,000, 2,000, and 5,000 Hz; and
- internal upsampling factors and fractional-delay kernels.

### 4. What safeguards follow from the measurements?

Evaluate:

- an ERP/scanner phase-concentration Watch;
- a side-by-side temporal-donor diagnostic rerun;
- acquisition-group metadata validation;
- synchronization-specific alignment profiles;
- an artifact-present confidence gate before correlation ranking, OBS, or ANC;
- warnings for implausibly large alignment shifts; and
- reporting that exposes both residual artifact and neural-signal transfer.

## Recommended paper figures

1. **Mechanism diagram:** event timing, scanner phase, same-slice donor epochs,
   and how a repeatable ERP enters the artifact template.
2. **ERP transfer heatmap:** retained beta across event/TR phase concentration,
   donor rule, sampling rate, and component shape.
3. **Artifact-versus-brain Pareto plot:** residual artifact on one axis and ERP
   amplitude or area retention on the other. A method that creates a clean
   trace by removing both artifact and ERP should be visibly unsafe.
4. **Component-shape panel:** P50/N100/N170/P200/N200/P300/N400/P600 truth,
   corrected average, and false-positive average.
5. **Multiband geometry panel:** correct acquisition groups versus the naive
   anatomical-slice interpretation across TR and multiband factor.
6. **Sampling and duration panel:** donor-volume knee, upsampling/runtime
   trade-off, and stationary versus nonstationary donor-window behavior.
7. **Guardrail panel:** circular phase-concentration Watch and the proposed
   temporal-versus-correlation donor comparison.

## Evidence needed before submission

The simulations provide a strong mechanistic foundation, but the main claim
should be validated beyond one synthetic artifact model.

### Tier 1: Real-artifact digital injection

- Obtain real gradient-artifact recordings from a phantom, shorted channels,
  or otherwise brain-free acquisition.
- Add known outside-scanner EEG and ERP signals.
- Use the exact same underlying ERP under phase-locked and jittered schedules.
- This provides true signal and artifact ground truth while retaining realistic
  gradient morphology.

### Tier 2: Acquisition validation

- Include at least one single-band and one multiband sequence.
- Use scanner markers or sequence metadata to establish true acquisition-group
  timing.
- Compare correct timing with common incorrect reconstructions from volume
  markers and anatomical slice count.
- Test a scanner-slaved configuration and introduce controlled synthetic clock
  drift for the asynchronous condition.

### Tier 3: Human ERP validation

- Record the same task outside and inside the scanner.
- Within the scanner, compare a phase-locked schedule with a deliberately
  jittered schedule.
- Include at least one early narrow response and one broad late response.
- If practical, include more than one scanner sequence or vendor because
  gradient morphology is sequence-specific.

### Methods to compare

- a conservative volume-template method;
- temporal-neighbor slice templates;
- correlation-ranked slice templates;
- motion-informed templates;
- OBS variants;
- ANC on and off; and
- a relevant vendor or commonly used toolbox default.

### Primary outcomes

Predefine joint outcomes rather than declaring the cleanest trace the winner:

1. residual gradient artifact;
2. corrected ERP SNR;
3. trigger-matched false-positive SNR;
4. amplitude-transfer beta;
5. peak latency;
6. half-height width;
7. signed and absolute area; and
8. trial- and participant-level effect-size recovery.

## Practical contribution

The manuscript should finish with recommendations that can be implemented by
toolboxes and used by investigators:

- Describe FASTR, Moosmann, and FARM as variants of the **Slice-Based** family,
  distinct from volume-level **Template** methods.
- Require acquisition-group timing for multiband slice-based correction.
- Do not interpret anatomical slice count as the number of sequential
  acquisition epochs.
- Prefer a scanner-slaved alignment profile when the EEG amplifier is slaved to
  the scanner.
- Warn when task events are strongly concentrated at a low-order phase of the
  TR.
- For flagged data, offer a temporal-neighbor diagnostic correction and compare
  ERP peak, width, area, waveform shape, residual artifact, and SNR side by
  side.
- Do not silently switch donor strategies because temporal donors can also
  attenuate or amplify broad late components.
- For prospective studies, jitter event timing relative to the scanner cycle.
  Software cannot reliably reconstruct a neural response after it has been
  incorporated into and removed with an artifact template.

## Position in the literature

The systematic review by Bullock et al. found that practical use remains
dominated by a few established defaults, that newer methods are rarely compared
comprehensively on independent datasets, and that signal-preservation risks
remain important. [Bullock et al., 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC7991907/)

Kraljič et al. advanced real-world evaluation through outside-scanner
references, ERP effect sizes, SNR, waveform correlation, and RMS difference.
They also explicitly identified event/scanner time locking as a concern and
recommended jitter as an idea for future study. [Kraljič et al., 2022](https://www.frontiersin.org/journals/neuroimaging/articles/10.3389/fnimg.2022.968363/pdf)

This proposed paper would extend that literature by showing that event/scanner
locking can cause subtraction of the true ERP itself, identifying the donor
selection mechanism, quantifying component-specific transfer, distinguishing
real ERP SNR from false-positive SNR, testing modern multiband acquisition
geometry, and translating the results into measurable software safeguards.

## Current assessment

The ERP/TR-phase result should be the scientific center of the paper.
Multiband acquisition-group timing and synchronization-specific alignment make
it a modern and practically consequential methods paper rather than merely a
simulator report.

The existing EVA evidence and raw-data references are documented in
[`docs/provenance/run-grade-calibration.md`](docs/provenance/run-grade-calibration.md),
particularly the sections beginning with **FASTR C5 follow-up: duration,
sampling rate and slice timing** and **Brain-safety bound tightened: evaluate
SNR and ERP transfer shape**.

