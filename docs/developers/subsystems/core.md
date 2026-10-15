# Core — `EVA/Core`

**Purpose.** App-side numeric helpers shared by every stage: rate conversion,
summary statistics, spherical-spline interpolation, and cleaning-variance
accounting. (The heavier math — DSP, linear algebra, forward models — lives in
the `EVACore` library; see [evacore.md](evacore.md).)

**Start here.** `SphericalSpline.interpolationWeights(...)` underlies both bad-channel
interpolation and topomap rasterization; `CleaningVarianceAccount.between(...)`
is how every cleaning stage reports "how much did this remove."

## Files

| File | Synopsis |
|---|---|
| `CleaningVarianceAccount.swift` | Quantifies signal variance removed by a cleaning step, per-channel and per-epoch; `summary(...)` renders the human-readable blurb shown in the log. |
| `Downsampler.swift` | Sample-rate reduction — `strided`, `windowedSincDecimated`, `blockAveraged` — plus `linearUpsample`. |
| `SignalSelection.swift` | Picks valid channels/segments (skips flat/NaN) and merges nearby event starts. |
| `SignalStatistics.swift` | Percentiles, RMS, population/sample variance, vector energy. |
| `SphericalSpline.swift` | Perrin spherical-spline weights (`interpolationWeights`, `interpolationWeightsBatch`) for interpolation and scalp fields. |

## How to extend this

Add a numeric primitive here only if it is **UI-free and reused across
subsystems**. Anything specific to one stage belongs in that stage; anything that
QuickLook/CLI would also need belongs in `EVACore` instead. Keep these as
`enum` namespaces of `static func`s (the existing convention) so they stay
stateless and trivially testable.
