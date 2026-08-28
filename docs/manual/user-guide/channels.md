# Channels And Sensor Layouts

Channel review is one of the first steps in most EEG workflows. EVA supports channel hiding, bad-channel marking, sensor-layout inspection, and spherical-spline interpolation.

## Hide Versus Mark Bad

Use hiding when a channel is not relevant to the current view. Use bad-channel marking when a channel should be treated as problematic for analysis or interpolation.

Examples:

- Hide auxiliary channels when reviewing only EEG traces.
- Mark a flat or saturated EEG channel as bad.
- Interpolate a bad channel only after confirming that neighboring channels support a spatial estimate.

## Interpolation

EVA uses spherical-spline interpolation for bad channels. Interpolation depends on valid sensor geometry and should be treated as an analysis decision, not a cosmetic display operation.

Before interpolating:

- Confirm that the channel is truly bad.
- Confirm the neighboring channels are usable.
- Confirm sensor positions are correct.
- Document the decision if the dataset will be used for publication or model training.

## Sensor Layouts

Sensor layouts support topographic maps and spatial reasoning. If a dataset does not include sensor locations, provide a sidecar file when available.
