# Artifacts — `EVA/Artifacts` (+ `EVACore/Artifacts`)

**Purpose.** User-defined, spatial-temporal **artifact templates** and the
cleaning that removes them — the general path for artifacts that aren't the
gradient, cardiac, or ICA special cases. You draw/define an artifact's shape,
EVA detects matching occurrences, and subtracts them (OBS or local-template).

**Start here.** `ArtifactTemplateDetector` builds and matches templates;
`ArtifactCleaner` (with `ArtifactCleaningCore`) removes them; `ArtifactViewModel`
/ `ArtifactTemplateViewModel` drive the UI; `ArtifactReplayPayload` makes it
reproducible.

## Files

| File | Synopsis |
|---|---|
| `ArtifactTemplateDetector.swift` | Defines and matches templates: config (`ArtifactTemplateConfiguration`), topography/polarity/scan options, detection results, and the on-disk `SavedArtifactTemplate` schema. |
| `ArtifactCleaner.swift` | The cleaning engine: `DefinedArtifactType`, `ArtifactCleaningMethod`, `ArtifactOBSStrategy`; OBS correction with per-channel basis and variance report. |
| `ArtifactCleaningCore.swift` | The small UI-free core the cleaner builds on. |
| `ArtifactReplayPayload.swift` | Serializable payload so a template cleaning replays deterministically. |
| `ArtifactViewModel.swift` / `ArtifactTemplateViewModel.swift` | Observable state for cleaning and for template definition. |
| `ArtifactPreviewViews.swift` | Live before/after preview UI, OBS/local-template option sheets, wavelet-cleaning preview, scalogram popover. |
| `ArtifactTemplateDefinitionViews.swift` | The template *authoring* UI (a `WaveformView` extension). |
| `ArtifactDetectionSummaryViews.swift` | Detection-summary UI (a `WaveformView` extension). |
| `SourceInformed/SurrogateBrainBasis.swift` | Surrogate regional-source basis (`SurrogateBrainModel`) for source-informed separation; pairs with `EVACore/Artifacts/SourceInformed`. |

## How to extend this

A new **cleaning strategy** is a case in `ArtifactCleaningMethod` /
`ArtifactOBSStrategy` implemented in `ArtifactCleaner`. A new **matching feature**
extends `ArtifactTemplateDetector` (and the `SavedArtifactTemplate*` schema — bump
it carefully so old saved templates still decode). Keep the numerical core in
`ArtifactCleaningCore`/`ArtifactCleaner` and only parameters in the view models.
Anything reproducible must round-trip through `ArtifactReplayPayload`.
