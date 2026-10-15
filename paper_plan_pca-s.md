# PCA-S paper and headless OBS comparison plan

Working plan recorded 2026-09-13. This document collects the scientific story,
the Phase-C implementation boundary, and the first publication-facing comparison
of PCA-S and OBS. It is a plan, not a measured-results record. Completed PCA-S
adversarial results remain in
`docs/provenance/pca-s-adversarial-evaluation.md`; comparison results should get
their own dated provenance record rather than being written back into this plan.

## Proposed paper-level claim

PCA-S adds a source-informed BCG correction method to EVA, but the larger
contribution is a truth-backed process for determining when correction helps,
when it removes neural signal, and when software should warn or refuse. A clean
looking trace is insufficient evidence: EVASimulate supplies the missing clean
counterfactual and lets the shipped methods be scored against it.

The narrow Phase-C question is deliberately sensor-space and waveform-only:

> On identical simulated BCG-contaminated recordings, how do shipped iterative
> PCA-S and a predeclared Standard OBS configuration differ in residual error and
> clean-signal preservation, and how does that difference change as BCG
> morphology and available beat evidence deteriorate?

This comparison does not by itself establish population performance, source
localization accuracy, or production readiness on real EEG-fMRI recordings.

## What already exists

### EVASimulate

- Deterministic clean/noisy MFF pairs and a truth sidecar.
- A physically generated, spatial-rank-four BCG with aortic, bilateral vessel,
  and head-rotation generators rather than a rank-one channel-index artifact.
- Beat-to-beat morphology variation, field strength, heart-rate variability,
  detected-beat timing error, real electrode geometry, and explicit head models.
- `QRSd` events representing jittered detector output and `QRSt` events recording
  oracle injection times.
- Waveform scoring against clean truth: broadband, band, and channel SNR; RMSE;
  correlation; corrected/clean band-power ratio; and spectral distortion.
- Repeated-seed PCA-S evaluation and adversarial single-axis grids.

### EVA

- Shipped iterative PCA-S as a portable `bcgCorrection` step that refits from
  the target file's own coordinates and beats.
- Standard OBS plus six explicit EVA OBS variants in `ArtifactCleaner`.
- `ArtifactReplayPayload` (`eva_artifacts.json`), which stores a recording's own
  artifact definitions and lets `HeadlessBatchProcessor` resolve
  `artifactClean` without a person.
- A method-comparison harness that generates one corpus cell per scenario/seed,
  runs every arm through the shipped headless pipeline, scores through
  EVASimulate, captures the exported audit log, and computes paired differences
  and 95% intervals within seed.

### The remaining gap

An EVASimulate MFF carries beat events but no artifact-cleaning decision.
Headless OBS correctly requires a `DefinedArtifact` payload stating which events
to use and how OBS is configured. Phase C must translate a method recipe plus
the target recording's own `QRSd` events into that payload without placing
correction policy inside EVASimulate or contaminating the shared generated
corpus.

## Ownership boundary

Keep the four responsibilities separate:

1. **EVASimulate generates evidence.** It writes signals, geometry, physiological
   markers, and truth. It should not choose an OBS strategy or component count.
2. **The comparison matrix defines method arms.** It states the observable event
   code, window, strategy, component count, and other method settings.
3. **EVA performs correction.** `HeadlessBatchProcessor`, `ProcessingCore`, and
   `ArtifactCleaner` remain the path under test; do not create a simulator-only
   OBS implementation.
4. **EVASimulate scores outcomes.** The same scorer evaluates uncorrected,
   PCA-S, and OBS recordings against the same clean truth.

Do not make EVASimulate write `eva_artifacts.json`. That sidecar is a
method-specific decision, and the simulator cannot know which of EVA's seven OBS
strategies or which parameterization an experiment intends. Do not add a general
payload override to `HeadlessBatchProcessor`; staging a package preserves its
important invariant that subject-specific payloads come from the input package.

## Phase-C implementation

### 1. Extend the comparison matrix with artifact recipes

Add an optional `inputArtifacts` collection to `ComparisonMatrix.Method`. Use
stable identifiers rather than EVA's display-string enum raw values. A recipe
needs at least:

- Stable type (`bcg`).
- Human-readable name.
- Observable event code (`QRSd`).
- Window start and end relative to the marker.
- Cleaning method (`obs`).
- OBS strategy (`standard` for the primary comparison).
- Residual PCA component count.
- Edge taper.
- Local-baseline preservation.
- Overlap-add behavior.
- Optional alignment/topography parameters only for strategies that use them.

The matrix remains the single hand-authored source of method configuration.
Runtime `artifactClean` parameters should be derived from the constructed
`DefinedArtifact`, not independently copied into the JSON and allowed to drift.

Validation must reject:

- An `artifactClean` step without a recipe, or a recipe without the step.
- Empty event codes.
- A window whose start is not before its end.
- Component counts outside EVA's supported range.
- Unknown methods or strategies.
- Topography-dependent strategies without a declared way to construct a
  topography.
- Oracle `QRSt` input in an ordinary arm. An oracle arm, if ever wanted, must be
  explicitly labelled as such in its id, label, and note.

When determining whether a matrix arm can run unattended, call
`replayInteraction(given:)` with artifact-payload availability derived from the
recipe. The context-free `replayInteraction` must continue to classify an
ordinary `artifactClean` as a human decision.

### 2. Add `SimulatedArtifactPayloadFactory`

Place the adapter in `EVATests/Pipeline/MethodComparison/`, where it can use the
app-owned definitions through `@testable import EVA`. For each recipe it should:

1. Load the staged noisy MFF with `MFFReader`.
2. Select and sort events with the requested code.
3. Fail clearly when no events match.
4. Convert the requested relative window into the centered-window convention
   used by `ArtifactCleaner`.
5. Drop or report events whose complete requested window cannot fit inside the
   recording.
6. Construct a `DefinedArtifact` with no stored derived average; the normal
   replay path will rederive the template against the signal being cleaned.
7. Apply the recipe's OBS settings.
8. Return `ArtifactReplayPayload` and the resolved flat provenance parameters
   produced by `DefinedArtifact.processingParameters`.

#### Window conversion

PCA-S currently examines `-0.1 ... +0.6 s` relative to a detected beat. Standard
OBS takes a symmetric window around `event.centerTimeSeconds`. To give both
methods the same core samples, convert a relative `[start, end]` recipe to:

```text
window length = end - start
center offset = (start + end) / 2
OBS event center = detected beat + center offset
```

For `[-0.1, +0.6]`, the length is 0.7 s and the center offset is +0.25 s. The
payload-specific event should therefore be centered at `QRSd + 0.25 s`, yielding
the same `QRSd - 0.1 ... QRSd + 0.6 s` core. This does not modify the source
recording's original marker stream.

Edge taper extends the actual OBS correction beyond the core window in the
current implementation. The primary comparison should set it explicitly rather
than inheriting a UI default. Use zero for a matched-core, publication-style
primary arm and treat EVA's 0.1 s taper as a separately labelled sensitivity
arm if desired.

### 3. Stage a private package for each OBS arm

`MethodComparisonRunner.corpus` caches one `sim_noisy.mff` for every
scenario/seed, and all methods must see those identical samples. Never add a
payload to that cached package.

For a method with `inputArtifacts`:

1. Create the ordinary per-run output directory.
2. Copy `sim_noisy.mff` to an arm-specific staging name inside it.
3. Build the payload from that staged package's own events.
4. Write `eva_artifacts.json` into the staged package.
5. Replace the runtime `artifactClean` step parameters with the resolved
   artifact provenance fields.
6. Pass the staged input and resolved script to `HeadlessBatchProcessor`.
7. Retain or remove the staging copy according to the comparison-output policy;
   the matrix, scenario, payload recipe, and result must remain sufficient to
   recreate it.

Uncorrected and PCA-S arms continue to read the pristine cached package.

### 4. Refuse silent no-op correction

Today an `artifactClean` invocation can produce an empty summary and still leave
a valid-looking output path. That would allow an unchanged signal to be scored
under an OBS label.

For a requested headless artifact correction:

- A payload missing at application time remains unresolved.
- A payload whose requested artifact produces no applicable correction must
  leave the step in `remainingSteps` or return another explicit incomplete
  outcome.
- A comparison arm must fail when any required artifact silently disappears.
- Mixed multi-artifact payloads may continue only when every requested
  contribution has an explicit success or recorded warning policy.

This is an execution-validity guard, not a quality threshold. An OBS result that
executes correctly and scores below uncorrected is valid scientific evidence.

### 5. Expand artifact-cleaning audit evidence

The output must state what OBS actually did, not merely that `artifactClean`
appeared in `eva.xml`. Extend the cleaning summary/audit path to report:

- Artifact name and type.
- Resolved method and OBS strategy.
- Requested and usable event counts.
- Number of events sampled for basis construction (currently capped at 80).
- Corrected channel count.
- Core relative window and edge taper.
- Mean-template plus residual-PC convention and residual component count.
- Baseline-preservation, overlap-add, and alignment settings.
- Removed-variance fraction through the shared cleaning ledger.
- Skipped windows and other warnings.

The exported `eva.xml` should contain the matching resolved definition, and the
comparison result should continue to obtain audit information from emitted
artifacts rather than from a second privately held `ProcessingCore`.

The header comment in `ArtifactCleaningCore.swift` predates persisted artifact
payloads and still says that `artifactClean` is not headless-replayable. Update
that stale explanation while touching this boundary.

### 6. Preserve complete waveform score files

`MethodComparisonRunner` currently decodes aggregate waveform metrics from a
temporary EVASimulate JSON and deletes the file. Preserve one complete score
JSON per scenario/seed/arm in the comparison output. This retains:

- Broadband SNR, RMSE, correlation, and spectral distortion.
- SNR, residual RMS, correlation, power ratio, and spectral distortion for each
  frequency band.
- Per-channel broadband and band results.

The report model may continue to decode only the compact fields it needs for
the main table. The complete score files become the source for figures and
secondary analyses without duplicating `SNRMetrics` in the app test target.

## First comparison matrix

### Scenario

Start from `Tools/EVASimulate/scenarios/bcg-generators.json` and override:

- `--no-gradient`, so uncorrected imaging artifact cannot dominate a BCG
  comparison.
- `--rate 250`, matching the SI-4 baseline and reducing the cost of the first
  repeated run.
- Preserve the 180 s duration, 20-channel baseline, detected-beat jitter, and
  BCG morphology jitter 0.20 unless a scenario says otherwise.

Consider a 32-channel replication after the first matrix because the shipped
PCA-S regression case found 20 channels somewhat conservative. Do not mix that
question into the initial implementation check.

### Arms

1. **Uncorrected.** The mandatory baseline.
2. **PCA-S iterative.** Shipped settings, `QRSd`, full electrode geometry, and
   an explicit settings record.
3. **Standard OBS primary.** `QRSd`, the matched `-0.1 ... +0.6 s` core window,
   zero edge taper for the primary matched-window arm, and a predeclared residual
   PCA count.
4. **OBS component sensitivity.** Separate labelled arms over a small residual
   count such as 2, 3, 4, and 5. Do not select the best one after looking and
   then describe it as the primary method.
5. **Optional EVA-default OBS sensitivity.** The UI's current default includes
   two residual PCs and 0.1 s edge taper; report it as an EVA configuration,
   distinct from the matched-window primary arm.

EVA's OBS always includes the mean artifact waveform and then adds the requested
number of residual PCA components. Reconcile this convention carefully with the
component language in Niazy et al. and Rusiniak et al. before labelling an arm
“published OBS.” Until then, use exact names such as “Standard OBS, mean + 4
residual PCs.”

### Seeds and pairing

Use 30 seeds per scenario, matching SI-4. Every arm at a given seed receives the
same clean/noisy samples and the same observable `QRSd` marker stream. Compute
PCA-S minus OBS within seed, then report the mean difference, sample SD, and 95%
interval. Also report every per-seed value and the proportion of seeds in which
each method performs worse than uncorrected.

### Primary waveform outcome

Predeclare paired broadband corrected SNR difference:

```text
Delta SNR = SNR(PCA-S) - SNR(primary OBS)
```

Positive favors PCA-S. The uncorrected score remains visible in every table and
figure; neither corrected value is interpretable without it.

### Secondary waveform outcomes

- Broadband RMSE and clean/corrected correlation.
- Spectral distortion over the full evaluated range.
- Per-band SNR, residual RMS, correlation, and corrected/clean power ratio.
- Per-channel SNR and distortion distribution.
- Removed-variance fraction, interpreted only as a diagnostic. Approaching or
  exceeding artifact energy is a distortion warning, not a success measure.
- Probability of harm across seeds: `P(corrected SNR < uncorrected SNR)`.
- Processing time, reported as implementation evidence rather than a scientific
  performance endpoint.

### Adversarial follow-up scenarios

A single default comparison is insufficient. Once the primary matrix runs,
repeat the paired comparison across the SI-4 axes most likely to distinguish the
methods:

- BCG morphology jitter: 0.0, 0.2, 0.4, 0.8.
- Available beat evidence or recording duration, centered on the PCA-S
  breakpoint.
- Detected-beat timing jitter.
- Artifact rank/component count.
- Channel count as a secondary replication.

Keep one-factor changes explicit. A difference across scenarios should be
attributable to the named axis rather than to a bundle of simultaneous changes.

## Harness semantics

Separate two kinds of failure:

### Execution failure

The arm is invalid and must not receive a scientific score when:

- Its payload cannot be built or decoded.
- Its event code is absent.
- Its geometry or required samples are unavailable.
- Headless processing returns remaining steps.
- OBS produces no applicable correction or silently falls back.
- The output lacks the resolved method evidence expected in its script, payload,
  or audit.

### Scientific harm

The arm ran correctly and the correction degraded the waveform. This must remain
in the results when:

- Corrected SNR falls below uncorrected.
- Band power indicates neural attenuation.
- Correlation falls or spectral distortion rises.
- Removed variance becomes implausibly large.

The existing gradient-matrix test asserts that every corrected arm beats
uncorrected. Do not carry that assertion into adversarial BCG matrices. The
harness should fail bad execution and faithfully report bad correction.

## Required tests

- [ ] Artifact recipe encodes, decodes, and validates.
- [ ] Unknown strategy, invalid window, and unsupported component count fail.
- [ ] A normal BCG arm selects `QRSd` and never silently uses `QRSt`.
- [ ] Relative-to-centered window conversion is sample-exact at supported rates.
- [ ] Out-of-bounds events are counted and handled deterministically.
- [ ] `ArtifactReplayPayload` round-trips every effective OBS setting and event.
- [ ] Staging leaves the cached corpus package byte-for-byte or file-for-file
  unchanged and adds the payload only to the OBS arm.
- [ ] `artifactClean` plus the staged payload classifies as
  `resolvedFromPayload`; the same step without it remains a decision.
- [ ] A missing marker code produces an incomplete arm rather than an unchanged
  recording.
- [ ] An empty cleaning outcome cannot be exported and scored as OBS.
- [ ] One generated BCG seed completes end to end and emits resolved OBS audit
  evidence.
- [ ] Interactive and headless application of the identical `DefinedArtifact`
  produce identical samples.
- [ ] A compact multi-arm matrix produces one uncorrected, PCA-S, and OBS result
  for every requested seed, with paired differences aligned by seed.
- [ ] The complete per-cell EVASimulate score JSON is retained and decodable.

## Publication narrative

### The scientific lineage

Give explicit credit to:

- Berg and Scherg (1994), multiple-source eye correction with a brain model.
- Ille, Berg, and Scherg (2002), spatial filtering from artifact and brain
  topographies in ongoing EEG.
- Niazy et al. (2005), optimal basis sets for the fMRI environment.
- Grouiller et al. (2007), forward simulation to expose correction-induced
  degradation that a clean-looking waveform hides.
- Litvak et al. (2007), source-informed correction applied to TMS-EEG.
- Rusiniak et al. (2022), PCA-S/ICA-S for BCG correction and preservation of
  source localization.
- Bullock, Jackson, and Abbott (2021), the field-wide need for accessible,
  adequately compared, and fully reported EEG-fMRI artifact methods.

Frame EVA as an independent native implementation and evaluation of this
lineage, not as the origin of the surrogate-source concept.

### What is new beyond cleaner traces

- A physical brain basis and recording-specific BCG topographies separate brain
  and artifact explanations before reconstructing corrected sensor-space EEG.
- Geometry, channel, and reference contracts are explicit and auditable.
- The same implementation runs interactively, headlessly, in batch, and during
  replay.
- Split-half component reliability protects weak-artifact recordings from
  treating residual ongoing EEG as artifact.
- EVASimulate converts method claims into falsifiable measurements against known
  neural and artifact truth.
- The adversarial campaign identifies operating limits and candidate software
  guardrails rather than reporting only a favorable baseline.

### Honest limits

- The current SI-4 variance is seed variation within one generator family, not
  population or inter-subject evidence.
- Morphology nonstationarity is the most important existing structural axis and
  the one that already breaks PCA-S.
- A matched generator/filter experiment alone is weak; mismatch and held-out
  scenarios carry more weight.
- The waveform comparison will not establish source localization preservation.
- Measured BCG templates, semi-synthetic data, and real recordings remain
  necessary before broad clinical or production claims.

## Publication extensions after Phase C

- Hold out simulator regimes when choosing guardrails, then report performance
  on those untouched conditions.
- Add measured BCG templates or semi-synthetic recordings with clear provenance.
- Validate minimum-beat and montage warnings on real recordings.
- Add source-localization and ERP/topographic preservation outcomes to connect
  directly with Rusiniak et al.'s scientific endpoint.
- Compare other shipped BCG arms under the same observable inputs and truth.
- Publish resolved scenarios, seeds, method recipes, full score JSON, raw CSVs,
  software version, OS/architecture, and audit lines.

## Documentation cleanup before results are published

- Reconcile the EVASimulate README's description of the pattern-search default
  with the SI-4 record stating that `correct`, `evaluate-surrogate`, and
  `evaluate-surrogate-grid` now default to iterative mode.
- Update SI-4/Track-2 roadmap status to match the completed adversarial record.
- Replace the stale `ArtifactCleaningCore.swift` comment that says persisted
  artifact payloads do not yet exist.
- Keep the PCA-S/OBS comparison in a new dated provenance record and link it
  from `docs/provenance/README.md` after the run.

## Resume point

Start with the matrix schema and `SimulatedArtifactPayloadFactory`, then prove a
single generated OBS arm completes headlessly. Do not begin the 30-seed run until
the no-op guard, audit evidence, corpus-immutability test, and full score-file
retention are in place. Once that one-cell path is trustworthy, the repeated
matrix is configuration and compute rather than new scientific code.
