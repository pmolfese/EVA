# EVACore Simulation — synthetic EEG & source fitting — `EVACore/Simulation`

**Purpose.** Generate synthetic scalp EEG with **known ground truth** — brain
sources through a forward model, plus a full menagerie of artifacts and noise —
and fit sources back from data. The truth structs are the oracle that every
detector and source-fit is scored against, so this module is as much a *test
substrate* as a feature.

**Start here.** `SimulationConfig` is the master config. `DipoleEEGGenerator` /
`EEGGenerator` synthesize the signal through a `SimulationForwardDomain`.
`SingleDipoleFit` is the inverse (fit dipoles to data). Every artifact model emits
a `*Truth` struct.

## Configuration & scenarios

| File | Synopsis |
|---|---|
| `SimulationConfig.swift` | The master config: bands, spatial/generation models, ERP/EMG/ocular/impedance/defect sub-configs, non-stationarity. |
| `SimulationScenario.swift` | A named scenario (config + file bindings). |
| `SimulationForwardDomain.swift` | The forward context: head shell/model, references, `SimulatedSource`, `LeadField`, motion truth. |
| `SimulationError.swift` | Simulation error type. |

## Generators

| File | Synopsis |
|---|---|
| `EEGGenerator.swift` | Top-level generator producing `GeneratedEEG`. |
| `DipoleEEGGenerator.swift` | Dipole → scalp via lead field (`mixed`, `dipoleSource`, seed streams, group jitter). |
| `SignalSynthesis.swift` | Building blocks: `GaussianSource`, spectral noise, high-rate templates. |
| `NonstationaryEEGModel.swift` | Neural non-stationarity: alpha bursts, microstates, phase-amplitude coupling (with truth). |
| `ERPGenerator.swift` / `ERPTruth.swift` | Injects ERP components with per-trial truth (`ERPComponent`, `ERPTrialTruth`). |
| `GroupSimulation.swift` | Group-level variation across simulated subjects (estimands + truth). |

## Artifact models (each with truth)

| File | Synopsis |
|---|---|
| `BCGArtifactModel.swift` / `BCGGeneratorModel.swift` | Ballistocardiogram injection + the spatial generator model (`BCGGeneratorTruth`). |
| `OcularArtifactModel.swift` / `OcularDipoleModel.swift` | Blink/saccade artifacts and their dipole topographies (`OcularDipoleTruth`). |
| `EMGArtifactModel.swift` | Muscle bursts (`EMGMuscle`, `EMGBurstTruth`). |
| `GradientArtifactModel.swift` | MRI gradient-artifact injection (`GradientInjection`). |
| `AdditionalArtifactModel.swift` | Chewing/swallowing/cable/sweat and other episodic artifacts (`ArtifactEpisodeTruth`). |
| `ChannelDefectModel.swift` | Bad/flat/bridged channel defects. |
| `ImpedanceModel.swift` | Electrode-impedance noise. |
| `SourceSimulatorArtifacts.swift` / `SourceSimulatorNoise.swift` | Artifact/noise layering with truth + SNR scoring for the Source Simulator window. |

## Geometry & inverse

| File | Synopsis |
|---|---|
| `Montage.swift` | Simulator electrode montage (`Electrode`, `Montage`, writer) — bridges a real montage in. |
| `SingleDipoleFit.swift` | Source fitting: `fit`, `search` (grid), `fitMultiple` (deflation + joint objective), `fitSpatioTemporal` (Scherg/Berg via covariance), shared-geometry per-condition fit; `LeadFieldGrid`. |

## How to extend this

A new **artifact** is a model here that (a) injects into the signal and (b) emits
a `*Truth` struct — without the truth, nothing downstream can score a detector
against it. Add its knobs to `SimulationConfig`, and remember the config-decoding
trap: **new `SimulationConfig` fields must be `Optional`** or every existing
scenario JSON stops decoding. Use the seeded RNG streams
(`SimulationSeedStreams`) so runs stay deterministic (the determinism check
compares against a stored binary — rebuild before trusting it). Forward-model
changes must stay consistent with `EVACore/Core/Forward` ([evacore.md](evacore.md)).
