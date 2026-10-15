# Filtering — `EVA/Filtering`

**Purpose.** Frequency-domain cleanup: band-pass / high-pass / low-pass, line-noise
reduction, and re-referencing.

**Start here.** `EEGSignalFilter` is the engine — `bandPass(...)` /
`filterChannel(...)` for the frequency response, `adaptiveLineNoiseReduction(...)`
for mains hum. `Rereferencing.applyInPlace(...)` changes the reference.
`FilterViewModel` is the sheet's state; the actual math never lives in the view.

## Files

| File | Synopsis |
|---|---|
| `EEGSignalFilter.swift` | The filter engine and all its option enums (`FilterFamily`, `IIRDesign`, `FIRWindow`, `FilterSlope`, `AutoCrossoverRule`); designs and applies FIR/IIR responses, average reference, and adaptive line-noise removal. |
| `EllipticFilterDesign.swift` | Elliptic (Cauer) IIR design in zero-pole-gain form converted to stable second-order sections (Orfanidis prototype). |
| `Rereferencing.swift` | Reference schemes (`ReferenceScheme`/`ReferenceDomain`) applied via `applyInPlace`/`applied`, recording excluded channels. |
| `FilterViewModel.swift` | Observable state for the filter sheet: approximation presets, cutoff validation (`FilterCutoffs`), error surfacing. |
| `FilteringViews.swift` | The SwiftUI filter panel (a `WaveformView` extension) plus `InfoPopoverButton` help. |

## How to extend this

A new filter *response* is a new case in `FilterFamily`/`IIRDesign` plus a design
routine (mirror `EllipticFilterDesign`); wire it through
`EEGSignalFilter.filterChannel(...)`. A new *reference* is a `ReferenceScheme`
case handled in `Rereferencing`. Keep design math in the engine files and only
surface parameters through `FilterViewModel` — the view should stay declarative.
Every applied filter is recorded as a pipeline step, so add its parameters to the
processing script (see [pipeline.md](pipeline.md)).
