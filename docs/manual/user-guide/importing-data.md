# Importing Data

EVA can open EGI/MagStim `.mff` recordings natively. Through MNE-Python-backed readers, EVA can also read several additional EEG formats.

## Supported Inputs

- EGI/MagStim `.mff`
- BrainVision `.vhdr`, `.vmrk`, `.eeg`
- EDF and EDF+
- Persyst `.lay` and `.dat`
- BESA `.avr` and `.mul`

Some non-MFF formats are not fully tested. See [Supported Formats](../reference/supported-formats.md) for details.

## Sensor Locations

When a file format does not include electrode geometry, EVA can use optional electrode-location sidecars such as:

- `.sfp`
- `.elp`
- `.loc`

Sensor geometry is important for topographic maps, spatial plausibility checks, and spherical-spline interpolation.

## Import Checklist

- Keep the recording and sidecar files together.
- Preserve event marker files for formats that split signal and event data.
- Confirm the imported channel count against the acquisition system.
- Confirm the sampling rate before interpreting latency or frequency-domain results.

!!! note "Verify in app"
    Add screenshots for the file importer and any format-specific warnings once the current release UI is final.
