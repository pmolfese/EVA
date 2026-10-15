# Rhythmicity Explorer — design reference

LAVI, ABBA, WTPL and burst analysis: the scientific model, data contracts, UI
specification, validation strategy, risk register and non-goals.

**Status lives in the roadmap, not here.** Milestones 0–8 shipped 2026-09-11
(see `ROADMAP_COMPLETE.md` § Time-Frequency & Rhythmicity).

Built from:

- Karvat et al. (2026), *Universal rhythmic architecture uncovers two modes of neural dynamics*: <https://www.nature.com/articles/s41467-026-73553-8>
- Open-access full text: <https://pmc.ncbi.nlm.nih.gov/articles/PMC13392403/>
- Authors' LAVI/ABBA implementations: <https://github.com/laaanchic/LAVI>
- Authors' WTPL and burst implementation: <https://github.com/laaanchic/WTPL>

EVA's LAVI oracle is the pinned upstream Python implementation. WTPL uses a
separate independent Python paper-equation oracle because the upstream WTPL
repository is MATLAB-only and the LAVI burst-layer WTPL path is explicitly
unvalidated. MATLAB files remain provenance and historical-comparison material.
EVA does not launch Python or MATLAB at runtime.

---

## 1. Executive decision

Build the paper's methods as a new, first-class **Rhythmicity Explorer** domain under `EVA/Rhythmicity/`.

Do **not**:

- rename or extend EVA's current Wavelet Explorer, which is an artifact-discovery and cleaning tool;
- make LAVI another ordinary Time-Frequency heatmap measure;
- put the full workflow inside `EpochingViewModel.AveragedDisplayMode`;
- treat LAVI as power, ITPC, or evidence that an oscillation is stronger;
- silently replace EVA's user-defined frequency bands with ABBA bands.

The scientific boundary is:

- **Time-Frequency workspace:** event-related power and cross-trial phase consistency—ERSP and ITPC—over frequency × time.
- **Rhythmicity Explorer:** temporal phase persistence, individualized sustained/transient band discovery, within-trial rhythmicity, and rhythmic burst characterization.

The two domains share complex Morlet transforms, frequency axes, heatmap/scalp rendering, channel selection, progress infrastructure, and export formats. The Rhythmicity Explorer publishes recording-scoped detected bands that the Time-Frequency workspace can explicitly adopt.

### 1.1 Product layout

The Rhythmicity Explorer is a standalone sheet or window launched from the main waveform workspace. It has three result modes:

```text
Rhythmicity Explorer
├── Bands
│   ├── LAVI rhythmicity spectrum
│   ├── surrogate noise ribbon
│   ├── ABBA sustained/transient bands
│   └── individual-band table and scalp summaries
├── Event-related
│   ├── WTPL frequency × time map
│   ├── ΔWTPL baseline-relative map
│   ├── condition and channel comparisons
│   └── links to ERSP/ITPC using the same bands
└── Bursts
    ├── time-frequency peak detection
    ├── WTPL- and power-defined boundaries
    ├── burst timeline/table
    └── rate, occupancy, duration, relative power, and band consistency
```

The **Bands**, **Event-related**, and **Bursts** modes are shipped.

---

## 2. Scientific model and terminology

### 2.1 LAVI

The Lagged-Angle Vector Index estimates rhythmicity at a frequency from the persistence of the complex time-frequency representation across a fixed lag measured in cycles.

For complex coefficients `x[t, f]`, sampling rate `fs`, frequency `f`, and lag `τ` cycles:

```text
lagSamples(f) = τ × fs / f

LAVI(f) = abs(
    Σ_t x[t, f] × conj(x[t + lagSamples(f), f])
    / sqrt(
        Σ_t abs(x[t, f])²
        × Σ_t abs(x[t + lagSamples(f), f])²
    )
)
```

The result is in `[0, 1]`:

- values nearer 1 indicate phase relations that persist over the chosen lag;
- values nearer 0 indicate less predictable phase evolution;
- the value is not an amplitude or power estimate;
- multiplying a signal by a nonzero constant should not change its LAVI, aside from floating-point effects.

Although the paper describes a vector mean of phase differences, the published equation and reference implementation use a normalized complex cross-product. EVA's canonical definition will follow the equation and reference implementation exactly.

### 2.2 ABBA

The Automated Band-Border Algorithm operates on a LAVI frequency profile:

1. Compute the median LAVI across analyzed frequencies.
2. Split the profile into contiguous regions above and below the median.
3. Use the largest absolute deviation from the median within each region as its peak or trough.
4. Compare that extremum with a frequency-dependent surrogate noise ribbon.
5. Classify significant above-median regions as **sustained** bands.
6. Classify significant below-median regions as **transient** bands.
7. Anchor names on the strongest sustained peak between 6 and 14 Hz, when present.
8. Assign relative identities outward from alpha.

ABBA produces individualized frequency boundaries. It does not prove that every detected band has a single functional role, nor that a below-median band consists only of discrete bursts.

### 2.3 WTPL

Within-Trial Phase Locking measures local phase persistence around each time point. For the paper's one-cycle before/after form:

```text
WTPL[t, f, trial] = 0.5 × abs(
    exp(i × (phase[t] - phase[t - oneCycle]))
    + exp(i × (phase[t] - phase[t + oneCycle]))
)
```

WTPL differs from ITPC:

- ITPC compares phase **across trials** at a fixed time and frequency.
- WTPL compares phase **within one trial** across nearby times.
- Mean WTPL is formed only after computing WTPL independently within each trial.
- ΔWTPL subtracts a pre-event WTPL baseline and is appropriate for between-frequency event-related comparisons.

The UI and exports must never label WTPL as ITPC or generic “phase locking.” Use the full term in help text.

### 2.4 Burst analysis

The paper's burst workflow uses power and/or WTPL time-frequency maps to locate peaks, estimate onset/offset, merge overlapping candidates, and calculate per-band statistics. This is distinct from EVA's artifact Wavelet Explorer: these bursts are candidate neural rhythms, not automatically artifacts and not automatically marked for cleaning.

---

## 3. Reproducibility presets

### 3.1 Paper preset

Create `RhythmicityPreset.paper2026` with locked defaults:

| Parameter | Value |
|---|---:|
| Frequency grid | `10 ** arange(0.5, 1.65, 0.025)` inclusive |
| Approximate range | 3.162–44.668 Hz |
| Frequency count | 47 |
| Frequency spacing | logarithmic |
| Morlet width | 5 cycles, fixed at every frequency |
| LAVI lag | 1.5 cycles |
| Alpha anchor | 6–14 Hz |
| Surrogate repetitions | 200 |
| Two-sided alpha | 0.05 |
| Lower/upper ribbon | validated against the cited implementation |
| Burst peak threshold | 90th power percentile |
| Initial burst boundary | 75th percentile |

The preset is the default and should be visually identified as **Paper 2026**. Users may duplicate it into a custom preset, but editing a parameter changes the preset identity to **Custom**.

### 3.2 Exactness rule

The significance lookup table is valid only for the configuration used to generate it. Its key must include at least:

```text
methodVersion
frequencyGrid
samplingRateModel
durationModel
aperiodicExponentModel
morletWidthCycles
lagCycles
surrogateCount
tailDefinition
```

Changing wavelet width, lag, frequency grid, tail definition, or surrogate count invalidates a cached/bundled significance table. EVA must either:

- generate matching surrogates on demand; or
- show the LAVI/median bands as exploratory and clearly mark significance as unavailable.

Never reuse the paper lookup table after a custom parameter change.

### 3.3 Frequency-range warnings

Surface nonblocking validity warnings based on the paper:

- Below 3 Hz, recommend several minutes of usable data.
- Above approximately 40–45 Hz, recommend at least 1 kHz sampling.
- Warn when 50/60 Hz or a harmonic falls inside or close to the requested range.
- Warn when a strong notch has been applied because neighboring rhythmicity may be distorted.
- Prefer EVA's adaptive line-noise removal over a broad/strong notch, but report the actual processing history rather than presuming it.

Warnings must be exported as provenance, not only shown in the UI.

---

## 4. Relationship to existing EVA code

### 4.1 Directly reusable pieces

| Existing code | Reuse |
|---|---|
| `EVA/TimeFrequency/ComplexMorlet.swift` | Complex Morlet model, kernel conventions, short-epoch direct convolution reference |
| `EVA/TimeFrequency/TimeFrequencyModels.swift` | Frequency-plan concepts and Sendable result style |
| `EVA/TimeFrequency/TimeFrequencyEngine.swift` | Trial iteration patterns and phase normalization examples |
| `EVA/TimeFrequency/TimeFrequencyMetalBackend.swift` | Device discovery, buffer allocation, fallback policy, batch conventions |
| `EVA/TimeFrequency/TimeFrequencyHeatmap.swift` | Frequency × time rendering for WTPL/ΔWTPL |
| `EVA/TimeFrequency/TimeFrequencyOverviewView.swift` | Channel scalp/matrix/gallery presentation patterns |
| `EVA/TimeFrequency/TimeFrequencyExport.swift` | NPY writer, axes sidecar, tidy scalar export conventions |
| `EVA/Analysis/EEGAnalysisEngine.swift` | Welch spectral-analysis approach and segment-aware FFT patterns |
| `EVA/Health/ChannelHealthAnalyzer.swift` | Existing aperiodic slope logic, to be refactored rather than duplicated |
| `EVA/Wavelet/WaveletArtifactExplorerViewModel.swift` | Observable run-state, generation guard, progress/log, cancellation patterns only |
| `EVA/Wavelet/WaveletArtifactExplorerViews.swift` | Sheet orchestration and result-table interaction patterns only |
| `EVA/Pipeline/ProcessingDefaults.swift` | Persistent user-default pattern for compute backend and custom presets |

### 4.2 Pieces that cannot be reused unchanged

1. `ComplexMorlet.kernel` follows MNE's zero-mean and normalization conventions. The paper used a FieldTrip-style Morlet. Constant normalization cancels from LAVI, and the five-cycle zero-mean correction is tiny, but numerical parity must be demonstrated rather than assumed.
2. `ComplexMorlet.convolveSame` is direct convolution. It is a good reference for short epochs but unsuitable for minutes of all-channel continuous data.
3. `TimeFrequencyEngine.decompose` reduces coefficients immediately into mean power and ITPC. LAVI and WTPL need different within-signal lag reductions.
4. `TimeFrequencyMetalBackend` outputs only mean power and ITPC. It does not expose complex coefficients or accumulate lagged cross-products.
5. `TimeFrequencyTrials.stack` averages selected channels and trims epochs. LAVI should normally remain channel-resolved and must preserve discontinuities between segments.
6. `ProcessingDefaults.timeFrequencyBands` is global. ABBA bands are recording-, channel-, selection-, and parameter-specific and must not overwrite global defaults implicitly.

### 4.3 Naming boundary

Keep these names distinct:

- **Wavelet Explorer**: existing artifact scanner and cleaner.
- **Time-Frequency**: existing ERSP/ITPC workspace.
- **Rhythmicity Explorer**: new LAVI/ABBA/WTPL/burst workspace.

Use “Morlet” or “wavelet” only in the Rhythmicity Explorer's method and provenance controls, not as the product name.

---

## 5. Module and file layout

Create a new folder:

```text
EVA/Rhythmicity/
├── RhythmicityModels.swift
├── RhythmicityPreset.swift
├── RhythmicityDataSelection.swift
├── ComplexCoefficientProvider.swift
├── AccelerateFFTComplexCoefficientProvider.swift
├── LAVIEngine.swift
├── ABBAEngine.swift
├── AperiodicSpectrumEstimator.swift
├── IAAFTSurrogateGenerator.swift
├── LAVISignificanceProvider.swift
├── WTPLEngine.swift
├── RhythmicBurstDetector.swift
├── RhythmicityExport.swift
├── RhythmicityExplorerViewModel.swift
├── RhythmicityExplorerView.swift
├── LAVISpectrumView.swift
├── ABBABandTableView.swift
├── WTPLView.swift
├── RhythmicBurstView.swift
└── RhythmicityHelp.swift
```

Optional performance follow-on:

```text
EVA/Rhythmicity/
├── RhythmicityMetalBackend.swift
└── RhythmicityKernels.metal
```

Tests:

```text
EVATests/Rhythmicity/
├── ComplexCoefficientProviderTests.swift
├── AccelerateFFTComplexCoefficientProviderTests.swift
├── LAVIEngineTests.swift
├── ABBAEngineTests.swift
├── AperiodicSpectrumEstimatorTests.swift
├── IAAFTSurrogateGeneratorTests.swift
├── LAVISignificanceProviderTests.swift
├── WTPLEngineTests.swift
├── RhythmicBurstDetectorTests.swift
├── RhythmicityExportTests.swift
├── RhythmicityIntegrationTests.swift
└── RhythmicityPerformanceTests.swift
```

Fixtures:

```text
EVATests/Fixtures/Rhythmicity/
├── reference-input.json
├── python-reference.json
├── python-author-example-report.json
├── mff-integration-manifest.json
├── milestone3-benchmark.json
├── upstream-manifest.json
├── wtpl-python-oracle.json
└── README.md
```

`wtpl-python-oracle.json` is generated by the standard-library-only
`Tools/RhythmicityReference/generate_wtpl_oracle.py` and contains deterministic
inputs plus full raw, delta, variance, and valid-count maps.

The project uses filesystem-synchronized Xcode groups, so adding files under `EVA/` and `EVATests/` should not require hand-editing `project.pbxproj`. Confirm target membership during the first build.

---

## 6. Core data contracts

All compute-side types should be `nonisolated`, `Sendable`, and independent of SwiftUI. UI state belongs in a `@MainActor @Observable` view model.

### 6.1 Configuration

```swift
nonisolated struct RhythmicityConfiguration: Sendable, Equatable, Codable {
    var presetID: String
    var frequenciesHz: [Double]
    var morletWidthCycles: Double
    var laviLagCycles: Double
    var wtplLagCycles: [Double]
    var alphaAnchorHz: ClosedRange<Double>
    var significance: LAVISignificanceConfiguration
    var edgePolicy: RhythmicityEdgePolicy
    var precision: RhythmicityPrecision
    var backend: RhythmicityComputeBackend
    var computePolicy: RhythmicityComputePolicy
}
```

The first release supports Morlet only. Do not add Multitaper to the picker until a scientifically defined LAVI/WTPL interpretation and reference implementation exist for it.

### 6.2 Segment-aware input

```swift
nonisolated struct RhythmicityInput: Sendable {
    var channels: [RhythmicityChannelInput]
    var samplingRate: Double
    var segments: [RhythmicitySegment]
    var source: RhythmicitySourceDescriptor
    var processingProvenance: RhythmicityProcessingProvenance
}

nonisolated struct RhythmicitySegment: Sendable, Codable, Equatable {
    var startSample: Int
    var endSample: Int
    var label: String?
    var trialID: String?
}
```

Segments are logically discontinuous. No LAVI or WTPL pair may cross from one segment/trial into another. This remains true even if data are packed into one contiguous scratch buffer.

### 6.3 LAVI output

```swift
nonisolated struct LAVIChannelResult: Sendable {
    var channelIndex: Int
    var channelName: String
    var frequenciesHz: [Double]
    var values: [Double]
    var validPairCounts: [Int]
    var effectiveDurationsSeconds: [Double]
    var median: Double
    var lowerSignificance: [Double]?
    var upperSignificance: [Double]?
    var bands: [ABBABand]
    var warnings: [RhythmicityWarning]
}
```

`validPairCounts` is required. A finite LAVI value without its evidence count is insufficient when low frequencies, short segments, NaNs, or artifact masks remove many pairs.

### 6.4 ABBA band

```swift
nonisolated struct ABBABand: Identifiable, Sendable, Codable, Equatable {
    var id: UUID
    var beginIndex: Int
    var endIndex: Int
    var peakIndex: Int
    var beginFrequencyHz: Double
    var endFrequencyHz: Double
    var peakFrequencyHz: Double
    var peakLAVI: Double
    var deviationFromMedian: Double
    var direction: ABBADirection       // sustained or transient
    var relativeToAlpha: Int?
    var canonicalName: String?
    var isSignificant: Bool?
    var significanceMargin: Double?
}
```

Preserve fields corresponding to the reference toolbox's `BegI`, `EndI`, `PeakI`, `BegF`, `EndF`, `PeakF`, `PeakLAVI`, `PeakRel`, `Dir`, `Rel_alpha`, and `Sig` so parity is directly testable.

### 6.5 WTPL output

```swift
nonisolated struct WTPLResult: Sendable {
    var meanWTPL: [[Double]]           // frequency × time
    var deltaWTPL: [[Double]]?         // baseline-subtracted
    var perTrialWTPL: [[[Double]]?     // optional/export-on-request
    var frequenciesHz: [Double]
    var timesMs: [Double]
    var validTrialCounts: [[Int]]
    var trialCount: Int
    var baselineWindowMs: ClosedRange<Double>?
    var warnings: [RhythmicityWarning]
}
```

Avoid retaining `perTrialWTPL` by default for large datasets. Compute condition means online and retain per-trial arrays only when explicitly requested for export or downstream statistics.

### 6.6 Recording-scoped band set

```swift
nonisolated struct DetectedRhythmicityBandSet: Sendable, Codable {
    var methodVersion: String
    var recordingIdentity: String
    var sourceRevision: String
    var channelScope: RhythmicityChannelScope
    var dataSelection: RhythmicitySelectionDescriptor
    var configuration: RhythmicityConfiguration
    var bands: [ABBABand]
    var createdAt: Date
}
```

This is a derived analysis result, not a global preference. “Use in Time-Frequency” creates a session-scoped band selection or an explicit saved copy. It must not edit `ProcessingDefaults.shared.timeFrequencyBands` without a separate “Save as global preset” action.

---

## 7. Input selection and provenance

### 7.1 Supported sources

The explorer should support:

1. **Entire processed recording**—default for LAVI/ABBA.
2. **Current visible range**—exploratory; warn if short.
3. **Selected event-free or user-defined segments**—preserve gaps.
4. **All epochs in one category**—valid for WTPL; LAVI pools only within-epoch pairs.
5. **Selected trials**—valid for WTPL and condition-specific LAVI.

Do not require averaged data for Bands mode. Event-related WTPL requires epochs/trials.

### 7.2 Signal snapshot

At run start, capture an immutable snapshot containing:

- the exact processed signal displayed/analyzed;
- sampling rate and channel metadata;
- applied channel interpolations;
- bad-channel exclusions;
- selected segments/trials;
- filter, referencing, line-noise, ICA, artifact-cleaning, and wavelet-reduction history available from EVA;
- a stable source/revision token for cache invalidation.

The run must not observe half-applied changes while filters or interpolation are being recomputed.

### 7.3 Artifact and NaN policy

Default behavior:

- exclude globally bad channels;
- keep interpolated channels but label them as reconstructed;
- split valid analysis segments around nonfinite samples and excluded artifact intervals;
- never replace invalid samples with zero for the scientific reduction;
- never allow a lag pair to bridge an excluded interval;
- report excluded duration and remaining usable duration.

Provide an expert option to include marked artifacts, off by default. Export that choice.

### 7.4 Channel scope

Initial scopes:

- current channel;
- visible good channels;
- named Channel Set;
- all good EEG channels.

Compute LAVI per channel first. Channel-group summaries are derived from channel-level LAVI profiles; never average raw signals across channels unless the user explicitly selects a signal-average scope.

---

## 8. Complex coefficient layer

### 8.1 Why a shared coefficient provider is needed

ERSP, ITPC, LAVI, and WTPL use the same complex Morlet coefficients but reduce them differently. Introduce a low-level coefficient provider instead of copying convolution loops into each engine.

```swift
nonisolated protocol ComplexCoefficientProvider: Sendable {
    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile
}
```

The provider returns one frequency tile at a time. The production implementation
constructs that tile from bounded overlap-save blocks. LAVI immediately reduces
and releases it, so the API never materializes `channel × frequency × time ×
complex` in memory.

### 8.2 Kernel convention spike

The Milestone 1 convention spike established the production kernel contract:

1. Generate the paper's five-cycle FieldTrip/reference kernel.
2. Generate EVA's existing `ComplexMorlet.kernel(..., nCycles: 5)`.
3. Compare phase, envelope, normalization, support, center sample, zero-mean correction, and edge behavior.
4. Run both through the authors' reference signal.
5. Measure maximum and RMS differences in complex coefficients and LAVI.

Decision rule:

- If EVA's existing kernel matches LAVI within the agreed tolerance, reuse it under the paper preset and document normalization invariance.
- If it does not, add a `ComplexMorletConvention.fieldTripLAVI2026` case. Do not modify the existing MNE-compatible behavior and risk ERSP/ITPC regressions.

### 8.3 CPU backends

EVA provides two CPU paths:

- **Direct reference path:** existing-style double-precision convolution for small fixtures and short epochs. This is the canonical correctness implementation.
- **FFT production path:** Accelerate/vDSP real-to-complex convolution using overlap-save or overlap-add, double precision where practical.

FFT path requirements:

- deterministic output for the same hardware/backend;
- linear convolution, not circular convolution;
- exactly specified central alignment;
- bounded scratch memory;
- tile boundaries that do not change valid coefficients;
- cancellation checks between frequency/channel tiles;
- direct-vs-FFT parity tests, including odd/even signal lengths and low-frequency long kernels.

### 8.4 Edge policy

Define explicit policies:

- `.referenceSamePadding`: reproduce reference zero-padded “same” convolution.
- `.validOnly`: exclude coefficients whose wavelet support touches padding.

Use reference padding for toolbox parity fixtures. Prefer valid-only for scientific display unless parity mode is explicitly requested. Always export the policy.

For LAVI, a valid sample must satisfy both:

- the coefficient at `t` is valid; and
- the coefficient at `t + lag` is valid.

For WTPL, `t`, `t - lag`, and `t + lag` must all be valid.

### 8.5 GPU implementation

Milestone 8 implements the coefficient-tile design in a compiled standalone
`RhythmicityKernels.metal` source. One dispatch produces one channel/run/frequency
Float32 coefficient tile; the existing CPU reduction consumes it immediately.
This preserves auditability and exact reduction semantics while avoiding a full
all-channel complex cube. Shared buffers remain under the same conservative
production memory policy as the FFT backend.

Paper-significance generation adds a second, batch-oriented path in the same
compiled shader. CPU workers generate deterministic IAAFT surrogates with
worker-local transform plans. Metal then produces one run/frequency coefficient
tile for every surrogate in a bounded batch and immediately accumulates compact
LAVI reductions on the GPU. Only the surrogate × frequency profiles return to
the CPU; full coefficient arrays do not. Float reductions use compensated sums,
and batch size accounts for retained Double surrogates as well as shared Metal
buffers.

Automatic mode uses the measured frequency × sample crossover and otherwise
keeps the bounded Double-precision Accelerate FFT path. Device, pipeline, shape,
allocation, command, or memory-budget failures also fall back to FFT and leave a
warning in the result. The recorded 32,768-sample/4 Hz profile was 36.95 ms for
CPU FFT and 7.25 ms for Metal on the reference Apple-Silicon host.

Acceptance is pinned by compiled-shader tests: real/imaginary coefficient error
below `2e-4`, end-to-end LAVI error below `2e-5`, identical valid-pair counts,
and exact ABBA begin/end/peak/direction boundaries. Cancellation and progress use
the existing engine contracts. Batched significance parity additionally covers
multiple finite runs and exact seed/order preservation between serial and
parallel CPU execution.

---

## 9. LAVI engine

### 9.1 Public API

```swift
nonisolated enum LAVIEngine {
    static func analyze(
        input: RhythmicityInput,
        configuration: RhythmicityConfiguration,
        coefficientProvider: any ComplexCoefficientProvider,
        progress: (@Sendable (RhythmicityProgress) -> Void)?
    ) throws -> LAVIAnalysisResult
}
```

### 9.2 Fractional lag

Use:

```text
exactLag = lagCycles × samplingRate / frequency
wholeLag = floor(exactLag)
fraction = exactLag - wholeLag

xLagged[t] =
    (1 - fraction) × x[t + wholeLag]
    + fraction × x[t + wholeLag + 1]
```

The authors' current Python implementation uses this interpolation to avoid high-frequency rounding artifacts. Add an internal `.integerReference` mode only if a legacy-parity diagnostic becomes necessary; do not expose it as the normal UI default.

### 9.3 Segment-aware online reduction

For each channel, frequency, and valid segment:

```text
numerator += Σ x0 × conj(x1)
energy0   += Σ abs(x0)²
energy1   += Σ abs(x1)²
pairCount += number of accepted pairs
```

After all segments:

```text
if pairCount == 0 or energy0 == 0 or energy1 == 0:
    LAVI = NaN
else:
    LAVI = abs(numerator / sqrt(energy0 × energy1))
```

Do not average per-segment LAVI values. Pool numerator and denominator components so long segments contribute proportionally to the number and energy of valid pairs, matching a single discontinuity-aware analysis.

### 9.4 Numerical protections

- Accumulate real and imaginary numerator terms separately in `Double`.
- Use compensated summation if direct-vs-reference error shows long-recording drift.
- Reject nonfinite coefficient pairs.
- Treat zero-energy frequency rows as unavailable, not zero rhythmicity.
- Clamp only final values within a small floating-point tolerance of `[0, 1]`; do not hide larger violations.
- Store the unclamped diagnostic maximum in debug/test builds.

### 9.5 Progress

Suggested weighted phases:

| Phase | Progress |
|---|---:|
| Validate/snapshot input | 0–3% |
| Prepare kernels/FFT plans | 3–8% |
| Transform and reduce channels | 8–68% |
| Estimate aperiodic spectra | 68–74% |
| Resolve/generate significance | 74–94% |
| ABBA and summaries | 94–99% |
| Publish/cache | 99–100% |

Progress detail should include channel, frequency tile, backend, and significance source without logging one line per sample or frequency.

---

## 10. Aperiodic spectrum and IAAFT surrogates

### 10.1 Shared spectral estimator

Extract/refactor the existing private Welch and aperiodic-slope logic into a reusable, tested component rather than calling Channel Health internals.

```swift
nonisolated struct AperiodicSpectrumFit: Sendable {
    var frequenciesHz: [Double]
    var observedPower: [Double]
    var fittedPower: [Double]
    var exponent: Double
    var intercept: Double
    var fitRangeHz: ClosedRange<Double>
    var excludedRangesHz: [ClosedRange<Double>]
    var rSquared: Double
}
```

Requirements:

- Hann-window Welch PSD;
- segment-aware windows that never bridge gaps;
- documented overlap and FFT length;
- exclude DC;
- exclude configurable bands around 50/60 Hz and harmonics from the aperiodic fit;
- report fit quality;
- preserve the exact fit needed by the reference implementation in paper-parity mode.

Do not silently substitute FOOOF/specparam. The paper used an aperiodic fit for surrogate generation and specparam only for a comparison analysis. A later specparam implementation would be a separate feature.

### 10.2 IAAFT implementation

Implement the Iterative Amplitude Adjusted Fourier Transform in `IAAFTSurrogateGenerator`:

1. Start from a deterministic shuffle of the target amplitude distribution.
2. FFT the candidate.
3. replace spectral magnitudes with the target aperiodic magnitudes while retaining phases;
4. inverse FFT;
5. rank-order values and replace them with the target sorted amplitude distribution;
6. repeat until both amplitude and spectral errors meet the configured threshold, progress stalls, cancellation occurs, or the iteration cap is reached.

Default parity parameters:

- error threshold: `2e-4` of original standard deviation;
- maximum iterations: 1000;
- seed: generated once per analysis and stored in provenance;
- surrogate count: 200.

Each surrogate records iteration count and convergence status. The run summary reports nonconverged count. Decide during validation whether a nonconverged surrogate is retained to match the reference or regenerated with a derived seed; make that policy explicit and tested.

### 10.3 Amplitude distribution

The reference paths may use the original sample distribution or a standardized/random distribution depending on the lookup-table generator. The validation spike must pin the precise maintained-toolbox behavior for:

- per-recording on-demand surrogates;
- general lookup-table surrogates;
- detrending/demeaning;
- target FFT magnitude orientation and normalization.

Do not merge these paths until parity fixtures show they are equivalent for the intended threshold.

### 10.4 Significance provider

```swift
nonisolated enum LAVISignificanceMode: Sendable, Codable, Equatable {
    case bundledLookup
    case onDemand(repetitions: Int, seed: UInt64)
    case none
}
```

`LAVISignificanceProvider` returns:

```swift
nonisolated struct LAVISignificanceRibbon: Sendable {
    var lower: [Double]
    var upper: [Double]
    var frequenciesHz: [Double]
    var source: LAVISignificanceSource
    var surrogateCount: Int
    var alpha: Double
    var tailRule: LAVITailRule
    var interpolationDiagnostics: LookupInterpolationDiagnostics?
}
```

### 10.5 Lookup-table strategy

Ship a bundled table only after:

- its generator is in the repo;
- generation parameters and source commit are recorded;
- a checksum is fixed in a test;
- interpolation/nearest-neighbor rules match the maintained reference;
- duration, sampling rate, and exponent bounds are explicit;
- out-of-range input falls back to on-demand generation or “significance unavailable.”

Never clamp an out-of-range recording silently to the lookup table's edge.

### 10.6 Tail-definition validation gate

The paper describes the lower and upper 2.5% tails of 200 surrogates. Some reference scripts historically use extrema or precomputed limits. Before shipping significance:

- capture outputs from the exact tagged/committed maintained implementation;
- identify whether thresholds are quantiles, order statistics, or extrema;
- document the result in `EVATests/Fixtures/Rhythmicity/README.md`;
- encode the behavior in `LAVITailRule`;
- display/export the rule.

This is a release blocker for “significant” labels. Median-only bands may exist earlier but must be marked exploratory.

---

## 11. ABBA engine

### 11.1 Public API

```swift
nonisolated enum ABBAEngine {
    static func detectBands(
        lavi: [Double],
        frequenciesHz: [Double],
        alphaAnchorHz: ClosedRange<Double>,
        ribbon: LAVISignificanceRibbon?
    ) -> ABBAResult
}
```

### 11.2 Exact algorithm

1. Validate equal nonempty arrays and ascending positive frequencies.
2. Calculate the median over finite LAVI values only.
3. Form `relative[i] = lavi[i] - median`.
4. Resolve exact zeros with the maintained toolbox's preceding-value/one-tenth rule for parity, isolated in a named helper and unit-tested.
5. Calculate sign per frequency.
6. End a region when adjacent signs change.
7. Include the first and last frequency in boundary regions.
8. Select the index with the maximum absolute `relative` value inside each region.
9. Set direction from the region sign: positive = sustained; negative = transient.
10. If a ribbon exists, mark the band significant only when its extremum crosses the appropriate upper/lower bound according to the validated reference rule.
11. Find sustained peak candidates in 6–14 Hz.
12. Choose the candidate with maximum absolute/actual LAVI according to reference parity.
13. Assign it `relativeToAlpha = 0`, then assign signed ordinal offsets to neighboring regions.
14. Map known offsets to display names only when the alpha anchor is valid.

### 11.3 Alpha-anchor failure

If no valid sustained peak exists in 6–14 Hz:

- retain all detected regions and peak frequencies;
- leave `relativeToAlpha` and `canonicalName` nil;
- show “Unanchored bands”; and
- allow export and manual inspection.

Do not choose the largest arbitrary peak outside the anchor range and call it alpha.

### 11.4 Boundary representation

Store reference-compatible discrete begin/end frequency bins. The plot may additionally render a linearly interpolated median crossing for visual polish, but:

- the table/export default remains the discrete toolbox-compatible boundary;
- interpolated display crossings are never substituted into parity fields;
- the sidecar states which representation is displayed and exported.

### 11.5 Group and scalp summaries

For multiple channels, derive:

- detection rate per named/relative band;
- median peak frequency and interquartile range;
- topography of peak LAVI or median-relative deviation;
- number of significant sustained/transient bands per channel;
- channels lacking an alpha anchor;
- consensus borders, clearly labeled as summaries rather than a new ABBA run.

Do not average channel LAVI profiles and call the resulting bands individualized.

---

## 12. WTPL engine

### 12.1 Placement

WTPL is implemented inside the Rhythmicity module and rendered in Event-related
mode. The Time-Frequency measure picker exposes a **WTPL** shortcut that calls
the same engine. There is only one numerical implementation.

### 12.2 API

```swift
nonisolated enum WTPLEngine {
    static func analyze(
        trials: [[Double]],
        samplingRate: Double,
        plan: TFFrequencyPlan,
        lagCycles: [Double],
        baseline: WTPLBaselineSpec?,
        coefficientProvider: any ComplexCoefficientProvider,
        retainPerTrial: Bool,
        progress: (@Sendable (RhythmicityProgress) -> Void)?
    ) throws -> WTPLResult
}
```

### 12.3 Computation

For each trial and frequency:

1. compute complex Morlet coefficients;
2. interpolate complex coefficients at each requested lag, not wrapped phase angles;
3. normalize valid complex coefficients to unit magnitude;
4. compute `unit(center) × conj(unit(lagged))` for each lag;
5. average these unit phase relations over lags;
6. take the magnitude;
7. mark times without all required lags invalid;
8. update online condition mean, variance, and valid-trial count.

The paper-specific shortcut uses lags `[-1, +1]` cycles. Support a family of lags internally to match the WTPL toolbox, but keep the first UI narrow.

### 12.4 Baseline and comparisons

Provide:

- raw WTPL `[0, 1]`;
- ΔWTPL = raw WTPL minus mean baseline WTPL per frequency;
- A − B raw or ΔWTPL difference maps;
- selected band × time-window scalar summaries.

Default the event-related paper preset to `-1000...-500 ms` only when the epoch actually contains that interval. Otherwise require a valid user choice or mark ΔWTPL unavailable; never silently shrink the baseline to whatever prestimulus samples exist.

### 12.5 Integration with existing TF results

Extend, rather than overload, the current result model. Preferred direction:

```swift
nonisolated struct FrequencyTimeMaps: Sendable {
    var power: [[Double]]?
    var itpc: [[Double]]?
    var wtpl: [[Double]]?
    var deltaWTPL: [[Double]]?
    var frequenciesHz: [Double]
    var timesMs: [Double]
}
```

Do not put WTPL into `TimeFrequencyResult.itpc` or repurpose `baselineMethod`, because WTPL baseline subtraction has different semantics from power normalization.

---

## 13. Burst analysis

Burst analysis shipped in milestone 7 after LAVI/ABBA and WTPL stabilized.

EVA pins the maintained MATLAB entry point at WTPL commit
`6da57b71f1084c62cfa1a4deaebee227d38f2584` and separately pins the file hash.
That entry point calls duration/frequency-span helper functions which are not
distributed in the upstream repository, so EVA validates its independent
implementation against a deterministic standard-library Python map oracle and
focused behavioral tests rather than claiming executable MATLAB parity.

### 13.1 Candidate peaks

For each trial/session and channel:

1. calculate five-cycle Morlet power on the selected frequency grid;
2. derive the 90th power percentile per frequency using valid time points;
3. identify strict/local maxima in the two-dimensional frequency × time plane above threshold;
4. resolve plateaus deterministically;
5. record peak time, frequency, power, trial/session identity, and channel.

### 13.2 Initial and final boundaries

For each candidate:

1. find initial onset/offset where power at peak frequency falls below its 75th percentile;
2. collect frequencies peaking within that initial time window;
3. derive final onset/offset when all involved frequencies fall below the chosen 75th-percentile power or WTPL criterion;
4. clamp only to the current trial/continuous segment, never across boundaries;
5. store whether boundaries came from power or WTPL.

### 13.3 Merge rule

Merge two bursts when:

- their time intervals overlap; and
- peak-frequency difference is less than one quarter of either burst's peak frequency, matching the maintained reference interpretation.

The merged burst receives the peak frequency of the candidate with greater `power × duration` energy. Apply merges deterministically until no eligible overlaps remain.

### 13.4 Metrics

Compute and export:

- duration in milliseconds and cycles;
- rate normalized by analyzed duration and band width;
- occupancy as percent of valid analyzed samples;
- relative peak power in dB against the frequency's 90th percentile;
- band consistency: percent of burst samples whose peak frequency stays inside its LAVI/ABBA band;
- peak WTPL and mean WTPL;
- band identity and sustained/transient class;
- channel and trial/session identity.

### 13.5 Safety boundary with artifact tools

Rhythmic bursts are not artifact candidates. The Bursts view must not offer “Clean selected” or automatically create a `DefinedArtifact`. If a future workflow permits event creation, stamp a distinct source such as `Rhythmicity Explorer Bursts` and describe it as analysis annotation, not artifact rejection.

---

## 14. Explorer view model and orchestration

### 14.1 Ownership

Create:

```swift
@MainActor
@Observable
final class RhythmicityExplorerViewModel {
    let store: RecordingStore

    var showsExplorer = false
    var mode: RhythmicityExplorerMode = .bands
    var configuration: RhythmicityConfiguration = .paper2026
    var dataSelection: RhythmicityDataSelection = .entireProcessedRecording
    var channelScope: RhythmicityChannelScope = .current

    var isRunning = false
    var progress = 0.0
    var statusTitle = ""
    var statusDetail = ""
    var log: [RhythmicityLogLine] = []
    var runGeneration = 0

    var laviResult: LAVIAnalysisResult?
    var wtplResult: WTPLAnalysisResult?
    var burstResult: RhythmicBurstAnalysisResult?
    var selectedBandID: ABBABand.ID?
    var selectedChannelIndex: Int?
}
```

Follow the existing Wavelet Explorer's generation guard:

- increment `runGeneration` on start/reset;
- cancel the old task;
- capture immutable input/configuration;
- publish only if the generation still matches;
- retain previous completed results while a rerun is underway, with a visible “stale for current settings” state.

### 14.2 Task ownership

Initially let `WaveformView` own `rhythmicityExplorerTask`, matching established patterns. If the window later becomes independently detachable, move orchestration into a recording-scoped coordinator so closing a sheet does not accidentally orphan or cancel user-requested work.

### 14.3 Cache key

The cache key must include:

```text
recording/source identity
processed-signal revision
interpolation revision
artifact-mask revision
selection segments/trials
channel indices
reference state
sampling rate
all rhythmicity configuration fields
significance source/table version/seed
backend and precision where results can differ
```

Do not use only file path, sample rate, and channel count; the current TF cache's lightweight token is insufficient for persistent scientific results.

The implemented paper-significance cache is exact and per channel. Its
checksummed key includes the recording path and source identity, processed-signal
revision and processing summary, selected segments, channel index/sample count/
interpolation state, sampling rate bit pattern, every resolved configuration
field (including backend and precision), significance seed, EVA method version,
and pinned upstream reference commit. Channel scope is intentionally excluded:
a completed current-channel result can therefore be reused when expanding to all
good channels, while every scientific input that can change the result still
invalidates the entry.

Only a completed aperiodic fit, significance ribbon, and surrogate convergence
diagnostics are stored. EEG samples, complex coefficients, surrogate waveforms,
and partial or cancelled runs are never cached. Cache entries also undergo
semantic validation after checksum and exact-key validation before reuse.

### 14.4 Cancellation

Cancellation checks are required:

- before each channel;
- before each frequency/tile;
- between IAAFT iterations at a bounded cadence;
- between surrogate jobs and Metal batches;
- before ABBA and export publication.

On cancellation:

- keep the last completed result;
- discard the partial new result unless a future explicit partial-results mode is designed;
- state “Cancelled; previous result retained”;
- never cache partial significance ribbons.

---

## 15. User interface specification

### 15.1 Launch point

Make the waveform workspace's **EEG** toolbar button a menu with two peers:

- **EEG Analysis…** — preserves the existing segments, spectral power,
  connectivity, and export workflow;
- **Rhythmicity Explorer…** — opens this new LAVI/ABBA/WTPL/burst domain.

Both actions should be available whenever a readable processed EEG signal exists.
Do not nest Rhythmicity Explorer inside EEG Analysis: the menu is the product
boundary between the two analysis families.

Do not add another `AveragedDisplayMode`; Bands mode must work before epoching.

### 15.2 Overall layout

Use a resizable sheet/window with:

```text
┌ Toolbar: mode | preset | data | channels | Run/Cancel | Export ┐
├ Left inspector ───────────┬ Main result canvas ────────────────┤
│ Configuration             │ LAVI / WTPL / Bursts               │
│ Validity and provenance   │ linked scalp/map/table views       │
│ Detection summary         │                                     │
├───────────────────────────┴─────────────────────────────────────┤
│ Progress, warnings, and collapsible run log                     │
└──────────────────────────────────────────────────────────────────┘
```

The main result remains visible when the inspector scrolls.

### 15.3 Bands mode

Primary plot requirements:

- log-scaled frequency x-axis;
- LAVI y-axis fixed to `[0, 1]` by default;
- observed LAVI line;
- horizontal observed median;
- lower/upper surrogate ribbon;
- alternating sustained/transient region fills;
- significant regions in full opacity, nonsignificant/exploratory regions subdued;
- labeled peak/trough markers;
- hover readout with frequency, LAVI, median difference, ribbon limits, band, and significance;
- selected-band highlight linked to the table and scalp view.

Band table columns:

- name/relative identity;
- type;
- begin Hz;
- end Hz;
- peak Hz;
- peak LAVI;
- median-relative value;
- significance;
- confidence/ribbon margin;
- valid duration or pair count.

Summary chips:

- analyzed duration;
- channel count;
- detected sustained bands;
- detected transient bands;
- alpha-anchor success;
- significance source;
- backend.

### 15.4 Multi-channel Bands mode

Provide linked presentations inspired by the existing TF overview:

- selected-channel spectrum plus scalp map;
- sensor × frequency LAVI matrix;
- small-multiple spectrum gallery;
- per-band peak-frequency topography;
- detection-rate summary.

Do not show every channel's significance ribbon simultaneously. The selected channel owns the detailed ribbon; aggregate views show compact summaries.

### 15.5 Event-related mode

Controls:

- condition A;
- optional condition B and A − B;
- raw WTPL vs ΔWTPL vs valid-trial counts;
- channel/channel set;
- frequency range and paper/custom preset;
- lag family, default one cycle before/after;
- explicit baseline window;
- detected-band overlay source.

Map requirements:

- reuse the TF heatmap renderer after generalizing labels/units;
- sequential scale `[0, 1]` for raw WTPL;
- symmetric diverging scale around zero for ΔWTPL and A − B;
- mark event time zero;
- hatch or mask invalid edge regions instead of painting them zero;
- overlay ABBA boundaries and optional band names;
- link band/time ROI selection to scalar summaries.

### 15.6 Bursts mode

Views:

- time-frequency power or WTPL background;
- peak markers and onset/offset contours;
- continuous waveform linked at the selected burst;
- sortable burst table;
- band-level rate/occupancy summary;
- histogram of duration in cycles;
- selected-band and selected-channel filters.

### 15.7 Validity states

Distinguish:

- **Ready**: valid configuration and sufficient input.
- **Exploratory**: LAVI/median bands available, significance absent.
- **Reference-valid**: paper preset with validated significance.
- **Custom significance**: matching on-demand surrogate run.
- **Invalid/insufficient**: no valid lag pairs, baseline absent, or input too short.
- **Stale**: displayed result does not match current controls.

Never represent “not computed” or “invalid” as nonsignificant.

---

## 16. Time-Frequency integration

### 16.1 Band overlay

Add an optional `DetectedRhythmicityBandSet` input to the TF render model. Render:

- subtle horizontal lines at ABBA borders;
- alternating sustained/transient labels or side-band tint;
- peak-frequency markers on demand;
- tooltip provenance identifying recording, channel scope, preset, and creation time.

The overlay must not alter ERSP/ITPC values.

### 16.2 ROI bands

Extend the TF band source picker:

```text
Band source
○ EVA defaults
○ User preferences
○ Rhythmicity Explorer: <result description>
```

If the selected ABBA result belongs to a single channel while the TF overview shows all channels, state that the same selected-channel boundaries are being applied to all displayed channels. Later support channel-specific ROI reduction explicitly; do not silently mix per-channel boundaries in a group scalar without a documented schema.

### 16.3 WTPL shortcut

After the Rhythmicity Event-related mode is validated, add `WTPL` to `EpochingViewModel.TFMeasure` as a convenience. Selecting it should:

- use the shared `WTPLEngine`;
- disable power mode and power baseline controls;
- expose raw/ΔWTPL and a valid WTPL baseline;
- disable Multitaper;
- preserve condition-difference behavior;
- export the correct measure and provenance.

The full Rhythmicity Explorer remains the destination for LAVI, ABBA, surrogate inference, and bursts.

### 16.4 Persistence

Initial release:

- retain result in memory for the open recording;
- export complete results;
- allow explicit “Use in Time-Frequency for this session.”

Follow-on:

- persist a compact analysis sidecar or recording-history payload containing configuration, bands, profile/ribbon arrays, source revision, and checksums;
- mark persisted results stale when upstream signal processing changes;
- provide recompute rather than silently applying stale bands.

---

## 17. Export and interoperability

### 17.1 Export bundle

Offer a directory/package export containing:

```text
<base>-rhythmicity/
├── manifest.json
├── lavi.csv
├── abba-bands.csv
├── lavi.npy
├── lavi-ribbon.npy
├── wtpl.npy                 # when available
├── delta-wtpl.npy           # when available
├── bursts.csv               # when available
└── warnings.txt
```

Single-file exports may remain available, but the package is the reproducible default.

### 17.2 Manifest

Version the manifest from day one:

```json
{
  "schema": "org.nih.eva.rhythmicity",
  "schemaVersion": 1,
  "methodVersion": "lavi-abba-2026-v1",
  "source": {},
  "selection": {},
  "channels": [],
  "samplingRateHz": 1000,
  "frequenciesHz": [],
  "morlet": {},
  "lavi": {},
  "significance": {},
  "abba": {},
  "wtpl": {},
  "burst": {},
  "processingHistory": {},
  "warnings": [],
  "software": {}
}
```

Record EVA version/build, backend, precision, random seed, lookup-table checksum, reference repository commit, edge policy, line-noise history, usable duration, excluded duration, and valid-pair counts.

### 17.3 LAVI CSV

Long format columns:

```text
row_type
condition_or_selection
channel_index
channel_name
frequency_hz
lavi
median_lavi
relative_lavi
lower_significance
upper_significance
classification
band_name
significant
valid_pair_count
effective_duration_seconds
```

### 17.4 ABBA CSV

Columns:

```text
channel_index
channel_name
band_id
band_name
relative_to_alpha
direction
begin_index
end_index
peak_index
begin_hz
end_hz
peak_hz
peak_lavi
peak_relative_lavi
significant
significance_margin
```

### 17.5 WTPL arrays

Use the existing dependency-free NPY writer with dimensions documented in the sidecar:

- condition mean: `channel × frequency × time`;
- per trial when requested: `trial × channel × frequency × time`;
- valid counts: separate integer or float NPY plus manifest description.

Do not encode invalid edges as zero. Use NaN and include a validity description.

### 17.6 Round-trip tests

- Verify NPY byte compatibility with NumPy for finite and NaN values.
- Decode every manifest fixture with a standalone Python script used only during fixture generation.
- Re-import exported ABBA bands into a test-only reader and assert exact identities/borders.

---

## 18. Validation strategy

### 18.1 Reference capture

Pin exact reference commits in the fixture README. Generate fixtures from:

- the pinned Python LAVI/ABBA implementation;
- paper-equation independent Python scripts where practical;
- a validated independent Python WTPL oracle before milestone 6.

Store source signal, sampling rate, configuration, output arrays, tool version/commit, platform, and commands. Never commit only derived output without its input and provenance.

### 18.2 LAVI unit tests

Required cases:

1. Pure stationary sine: high LAVI at the injected frequency.
2. Phase-randomized 1/f noise: flatter profile and lower dynamic range.
3. Repeated phase resets: decreasing LAVI as reset rate increases.
4. Amplitude scaling: LAVI invariant for positive and negative nonzero scaling.
5. Additive power change without phase change: expected limited LAVI change.
6. Fractional lag sweep: no high-frequency sawtooth from integer rounding.
7. Zero signal: unavailable/NaN, never fabricated zero.
8. One valid segment too short for lag: unavailable with zero pair count.
9. Multiple segments: result equals manual pooled accumulators.
10. Segment-boundary adversary: no pair crosses a discontinuity.
11. NaN island: pairs touching it are excluded.
12. Direct vs FFT backend parity.
13. MNE-style vs FieldTrip-style kernel spike outcome pinned.
14. Pinned Python fixture parity.
15. Determinism with identical configuration and backend.

### 18.3 ABBA unit tests

Required cases:

- exact alternating synthetic profile;
- profile beginning above vs below median;
- exact zeros at first, middle, and last bins;
- single region with no crossings;
- NaN frequency rows;
- multiple sustained alpha candidates;
- no alpha anchor;
- extrema tied across bins;
- significant sustained peak;
- significant transient trough;
- region peak inside ribbon and therefore nonsignificant;
- per-frequency ribbon vs scalar ribbon;
- 0-based reference indices and exported frequencies;
- exact expected band table from the pinned Python fixture.

Tie-breaking must be deterministic and match the maintained reference.

### 18.4 IAAFT tests

- preserves target sorted amplitude distribution within tolerance;
- matches target power spectrum within tolerance;
- converges on white, pink, and steep 1/f targets;
- deterministic with fixed seed;
- different seeds produce different time series with equivalent target properties;
- cancellation exits without publishing a partial ribbon;
- nonconvergence policy is exercised;
- 200-surrogate tail extraction is correct;
- lookup table and on-demand results agree statistically on held-out configurations.

### 18.5 WTPL tests

1. Sustained sine: WTPL near 1 away from edges.
2. Phase reset: local WTPL decrease around reset.
3. Amplitude scaling: invariant except at zero magnitude.
4. Random phase process: lower WTPL.
5. Exact one-cycle lag at integer and fractional samples.
6. Invalid edge mask width.
7. No crossing trial boundaries.
8. Online trial mean equals retained per-trial mean.
9. Baseline subtraction produces baseline mean near zero.
10. Independent Python WTPL oracle parity.
11. Distinguish WTPL from ITPC using trials with random between-trial phase but stable within-trial oscillation: high WTPL, low ITPC.
12. Distinguish the reverse constructed case where feasible.

### 18.6 Burst tests

- planted burst peak frequency/time recovery;
- 90th-percentile threshold behavior;
- 75th-percentile onset/offset behavior;
- overlapping same-band merge;
- overlapping distant-frequency non-merge;
- deterministic plateau handling;
- rate normalization by duration and band width;
- occupancy union avoids double counting;
- relative power dB calculation;
- band consistency calculation;
- session/trial boundary isolation;
- reference fixture parity.

### 18.7 Integration tests

- processed-signal revision invalidates result/cache;
- changing a harmless display control does not rerun computation;
- changing lag, width, frequency grid, selection, or channel scope does rerun;
- custom configuration invalidates bundled significance;
- ABBA bands transfer to TF without changing map values;
- global frequency-band preferences remain unchanged;
- WTPL shortcut and Rhythmicity Explorer yield identical maps;
- export contains every warning and provenance field;
- cancellation retains the prior result;
- stale run cannot overwrite a newer run.

### 18.8 Numerical tolerances

Define tolerances by layer:

- direct Double vs reference Double: strict relative/absolute tolerances established from fixtures;
- FFT Double vs direct Double: slightly wider, still below any band-boundary-changing error;
- Metal Float vs CPU Double: documented relative tolerance plus exact ABBA boundary checks;
- surrogate ribbon: seed-fixed exact/near-exact checks and distributional checks across seeds.

Avoid thousands of per-cell `#expect` calls. Aggregate maximum error, RMS error, boundary differences, and failure counts into a small number of assertions, following current TF tests.

---

## 19. Performance and resource budgets

### 19.1 Representative workloads

Benchmark at least:

| Workload | Channels | Duration/trials | Sampling rate | Frequencies |
|---|---:|---:|---:|---:|
| Quick selected-channel LAVI | 1 | 2 min | 250 Hz | 47 |
| Standard EEG LAVI | 64 | 5 min | 500 Hz | 47 |
| High-density EEG LAVI | 128 | 10 min | 1 kHz | 47 |
| Event WTPL | 64 | 100 × 2 s | 500 Hz | 47 |
| High-density event WTPL | 128 | 200 × 2 s | 1 kHz | 47 |

### 19.2 Initial targets

These are engineering targets, not scientific requirements:

- selected-channel standard LAVI returns interactively on Apple Silicon;
- all-channel transform does not allocate more than 768 MiB of working GPU/shared memory or an equivalently documented CPU cap;
- UI remains responsive and cancellable;
- progress updates at least every few seconds but no more than approximately 10 times per second;
- no full complex cube for continuous high-density data;
- on-demand 200-surrogate runs expose realistic time estimates and can be cancelled.

Measure actual baselines before setting release thresholds.

### 19.3 Caching

Cache reusable layers separately:

1. aperiodic PSD/fit;
2. complex coefficient tiles only when memory permits and another measure immediately reuses them;
3. LAVI profile;
4. significance ribbon keyed independently from observed LAVI;
5. ABBA result;
6. WTPL condition mean;
7. burst result.

A display color-map change must not invalidate computation. An ABBA naming/anchor change need not recompute LAVI. A significance change need not recompute observed coefficients.

The first implemented reusable layer is the independently keyed, per-channel
paper-significance result. Exact reruns reuse the fit, 200-surrogate ribbon, and
diagnostics; observed LAVI and ABBA assignment remain part of the live run. A
cache hit is explicit in progress and the run log.

---

## 20. Licensing and attribution

Before copying any source code:

1. record the license and commit for the current LAVI Python oracle and audit the LAVI MATLAB, WTPL, FieldTrip-derived, and IAAFT-derived files for provenance only;
2. distinguish repository-level licensing from third-party file headers;
3. prefer an independent Swift implementation from the published equations, verified against outputs;
4. retain required copyright/license notices for any directly translated code;
5. add citations and method descriptions to EVA Help and exports;
6. include the paper and toolbox citations in release notes.

The current repositories advertise permissive licensing for their own code, while the paper notes GPL/BSD provenance for some MATLAB dependencies. Treat license review as milestone 0, not an afterthought.

---

## 21. Documentation and interpretation safeguards

Add a Help article covering:

- what LAVI measures;
- why it is different from power and ITPC;
- sustained vs transient terminology;
- what the surrogate ribbon means;
- why bands can be unanchored or nonsignificant;
- minimum duration/sampling-rate considerations;
- line-noise/notch caveats;
- WTPL vs ITPC examples;
- why detected bursts are not automatically artifacts;
- exact citation and export instructions.

Required UI wording:

- “Higher rhythmicity” rather than “stronger oscillation.”
- “Significant relative to matched surrogate noise” rather than “real oscillation.”
- “Transient band” rather than “non-rhythmic band.”
- “Unanchored” rather than guessing a canonical identity.
- “Insufficient valid duration” rather than displaying zero.

The paper's proposed input/maintenance functional interpretation should be described as the authors' interpretation, not as a classification EVA has independently established for a new dataset.

---


## 23. Risk register

| Risk | Consequence | Mitigation |
|---|---|---|
| MNE vs FieldTrip kernel differences | Numerical mismatch | Separate convention, pinned fixtures, do not alter existing ERSP kernel |
| Integer lag rounding | High-frequency sawtooth | Fractional complex interpolation and sweep tests |
| Epoch concatenation | Artificial phase discontinuity pairs | Segment-aware accumulators with boundary tests |
| Short recordings | Unstable/invalid low-frequency inference | Pair counts, duration warnings, unavailable states |
| Notch filtering | Artificial neighboring rhythmicity structure | Processing-history warning and export provenance |
| Lookup misuse | False significance | Full configuration key, range rejection, on-demand fallback |
| Tail-rule ambiguity | Incorrect p-level | Milestone-0 reference lock; no “significant” labels before resolution |
| Alpha absent | Misnamed bands | Preserve unanchored relative bands; never guess |
| Full complex cube allocation | Memory failure | Streaming/tiled coefficient provider |
| Direct convolution on long data | Unusable runtime | Production FFT backend before all-channel release |
| GPU float differences | Band/significance instability | CPU oracle, boundary tests, fallback |
| Global band overwrite | Cross-recording scientific error | Recording-scoped results and explicit adoption |
| WTPL confused with ITPC | Interpretation error | Separate labels, models, controls, help, and tests |
| Neural bursts confused with artifacts | Accidental cleaning | Separate domain and no artifact-apply action |
| Young reference Python port | Behavioral drift | Pin commits and validate against independent equations and synthetic invariants |
| Upstream processing changes | Stale derived results | Complete revision key and visible stale state |

---

## 24. Explicit non-goals for the first release

- Reproducing every figure or inferential analysis in the paper.
- Implementing specparam/FOOOF as part of LAVI.
- Claiming causal input-vs-maintenance classification from one recording.
- LAVI with Multitaper.
- Frequencies outside the validated paper range without a custom-method warning.
- Group-level cluster permutation statistics over LAVI/WTPL.
- Automatic clinical interpretation.
- Automatically applying ABBA bands across participants or channels.
- Replacing canonical EVA frequency-band preferences.
- Treating neural burst detections as artifacts.

Group-level LAVI/WTPL inference can be planned after single-recording exports and statistical semantics are stable. The existing TF-4 frequency-axis cluster work may eventually be generalized for WTPL maps, but it is not a dependency of this plan.

---

## 25. Overall acceptance criteria

The feature is complete when all of the following are true:

### Scientific correctness

- [x] Paper-preset LAVI matches the pinned Python reference within documented tolerance.
- [x] ABBA borders, peaks, directions, alpha-relative identities, and significance match fixtures.
- [x] WTPL matches its validated independent Python oracle.
- [x] Segment/trial boundaries are never crossed.
- [x] Invalid/insufficient data are distinct from zero or nonsignificant results.
- [x] Surrogate significance is reproducible and configuration-matched.

### Product behavior

- [x] Rhythmicity Explorer works without requiring epochs for Bands mode.
- [x] Event-related mode clearly requires and uses trials.
- [x] Users can inspect single-channel and multi-channel results.
- [x] ABBA bands can be explicitly adopted by Time-Frequency.
- [x] Global band defaults are unchanged unless the user explicitly saves a preset.
- [x] Results become visibly stale when upstream signal processing changes.
- [x] Long runs are cancellable and never publish partial results as complete.

### Performance

- [x] Production LAVI uses FFT/tiled computation on long inputs.
- [x] Memory remains within documented limits.
- [x] Representative EEG workloads have recorded benchmarks.
- [x] CPU fallback is always available.

### Reproducibility

- [x] Exports include axes, configuration, source selection, processing history, valid counts, warnings, software version, backend, seed, and lookup checksum when applicable.
- [x] Reference fixture generation is documented.
- [x] Help and release notes cite the paper and toolboxes.
- [x] License review is complete.

---

## 26. Recommended first implementation slice

Start with a narrow vertical slice that proves the architecture without committing to the expensive surrogate and all-channel paths:

1. Add the paper preset and core models.
2. Implement direct, segment-aware selected-channel LAVI with fractional lag.
3. Implement median-only ABBA.
4. Validate against the pinned Python fixtures.
5. Build a minimal selected-channel spectrum with median and band coloring.
6. Label the result **Exploratory—significance not computed**.
7. Export LAVI and ABBA plus complete configuration.

Then immediately implement milestone 2 significance before presenting ABBA bands as research-grade detections. This slice settles kernel, lag, boundary, UI, and export contracts early, while keeping the first code review small enough to audit carefully.

Milestones 0–8 now constitute the completed recording-level Rhythmicity Explorer.
Future work should begin from new scientific or product requirements rather than
reopening the validated implementation slices.
