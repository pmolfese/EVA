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

## Import BrainVision Electrode Locations

Use **Channels → Import Locations…** to load a BrainVision Electrode File
(`.bvef`) for the focused recording. This also works when Brain Products data
arrive inside an MFF with a different or incorrect sensor layout.

1. Choose the `.bvef` file.
2. Review the matches. **Electrode names** matches labels without case
   differences or an `EEG` prefix / `-REF` suffix. **Channel numbers** maps the
   file's `Number` field to the recording's one-based channel order; confirm that
   the acquisition order matches before applying it.
3. Select **Apply Locations**. The 2D scalp map and 3D EEG geometry update
   together. Existing channel interpolations are recalculated for the new
   locations.
4. Export a new MFF to retain the locations for reopening or sharing. The import
   does not edit the source MFF. Exports carry the replacement sensor layout,
   coordinates, and an audit entry identifying the location file and matching
   method. Window forks and EVA Resolve handoffs also retain the override.

Unnumbered `REF` and `GND` entries do not shift numbered channels or create new
signal rows. Radius-zero entries and unmatched channels receive no scalp
coordinates; old positions from an unrelated net are removed for those channels.
Channel labels, order, and recorded samples are preserved by the location import.

Channel role is separate from location availability. Channels explicitly
identified as ECG or EOG normally belong in Physio/PNS, and can be moved using
**Move to Physio**. Missing coordinates alone do not identify a peripheral
channel: an unlocalized EEG electrode remains an EEG electrode. The location
import does not automatically move channels between EEG and PNS.
