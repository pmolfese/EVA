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

## Import Electrode Locations

Use **Channels → Import Locations…** to load a location file for the focused
recording. Supported files are:

- BrainVision Electrode Files (`.bvef`)
- MFF `coordinates.xml` (3D electrode locations)
- MFF `sensorLayout.xml` (2D scalp layout)

This also works when a recording arrives inside an MFF with a different or
incorrect sensor layout. The file picker lets you browse inside MFF packages.

1. Choose the `.bvef` or MFF location XML file.
2. Review the matches. **Electrode names** matches labels without case
   differences or an `EEG` prefix / `-REF` suffix. **Channel numbers** maps the
   file's `Number` field to the recording's one-based channel order; confirm that
   the acquisition order matches before applying it.
3. Select **Apply Locations**. The 2D scalp map and 3D EEG geometry update
   together for a 3D import. A `sensorLayout.xml` import supplies only 2D
   positions and removes old 3D coordinates; it does not enable spherical-spline
   interpolation. Existing channel repairs are recalculated where the new 3D
   locations permit it; repairs without valid geometry are removed and marked
   as needing attention.
4. Export a new MFF to retain the locations for reopening or sharing. The import
   does not edit the source MFF. Exports carry the replacement location metadata and an audit entry
   identifying the location file and matching method. Window forks and EVA Resolve handoffs also retain the override.

Unnumbered BrainVision `REF` and `GND` entries do not shift numbered channels or
create new signal rows. MFF fiducials and other non-EEG landmarks are excluded;
unnamed MFF electrodes use their `E1`, `E2`, … identities. Radius-zero entries
and unmatched channels receive no scalp coordinates; old positions from an unrelated net are removed for those channels.
A 2D choice remains 2D after export and reopening, without substituting an
inferred standard 3D montage. Channel labels, order, and recorded samples are
preserved by the location import.

Channel role is separate from location availability. Channels explicitly
identified as ECG or EOG normally belong in Physio/PNS, and can be moved using
**Move to Physio**. Missing coordinates alone do not identify a peripheral
channel: an unlocalized EEG electrode remains an EEG electrode. The location
import does not automatically move channels between EEG and PNS.
