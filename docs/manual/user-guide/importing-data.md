# Importing Data

EVA opens EGI/MagStim `.mff` recordings and several additional EEG formats through native readers. BioSemi BDF import does not require Python or conversion to EDF.

## Supported Inputs

- EGI/MagStim `.mff`
- BrainVision `.vhdr`, `.vmrk`, `.eeg`
- EDF and EDF+
- BioSemi BDF and continuous BDF+ (`.bdf`)
- Persyst `.lay` and `.dat`
- BESA `.avr` and `.mul`

Some non-MFF formats are not fully tested. See [Supported Formats](../reference/supported-formats.md) for details.

## BioSemi BDF

Open or drop a `.bdf` file directly. EVA reads signed 24-bit samples, applies the
file's per-channel calibration, and converts voltage channels to microvolts.
The recorded reference is preserved; rereferencing is an explicit processing step.

- **Triggers:** event codes use the lower 16 bits of Status. Each change to a
  nonzero code creates an event, including a code present at sample zero and
  direct changes between nonzero codes. A sustained code creates one event,
  with its duration retained across data-record boundaries. Upper equipment-status
  bits do not create experimental events. No automatic inversion or byte shift
  is applied.
- **Status and physiological channels:** the full unsigned 24-bit Status values
  remain available in the physiological pane. Recognizable ECG, EOG, EMG,
  respiration, and other peripheral channels are kept separate from scalp EEG.
  Ambiguous `EXG` channels remain in EEG; use the channel-role controls to assign
  them according to the acquisition wiring. Non-voltage sensors retain their
  native numeric values; EVA's generic physiological display does not currently
  carry per-channel unit labels for these sensors or raw Status words.
- **Mixed sample rates:** EEG and physiological groups each use their highest
  native rate. Lower-rate analog channels are upsampled with a windowed-sinc
  interpolator; Status uses sample-and-hold. Native-rate channels are unchanged,
  and trigger timing is decoded at the Status channel's original rate.
- **BDF+:** UTF-8 annotations, durations, record clocks, fractional first-sample
  offsets, and four-digit start dates are supported. Files with actual gaps or
  overlapping data records are refused rather than joined into a false
  continuous timeline. A `BDF+D` file whose records are contiguous can open.
- **Locations:** BDF does not provide electrode coordinates. Use a location
  sidecar for BioSemi bank labels such as `A1`; EVA does not guess a cap montage
  from the number of channels. Recognized standard electrode names can use the
  existing standard-position fallback.

Export the processed recording to MFF as usual. Events, physiological channels,
`eva.xml`, and an audit note describing BDF trigger decoding are included.
The original BDF remains unchanged. BDF export is not provided.

## MFF Acquisition Pauses

For continuous MFF recordings, EVA preserves the elapsed acquisition timeline
declared in `epochs.xml`. A pause in saving EEG is represented by zero
placeholders and a duration-bearing **Acquisition gap** (`BAD_ACQ_SKIP`) event.
Those zeros are missing data, not measured EEG. Event timestamps remain on the
original clock, so events after a pause stay aligned with their recorded samples.
PNS channels use the same acquisition intervals.

The main filter processes the recorded intervals independently, including
adaptive line-noise reduction. PSA excludes any epoch overlapping a gap even
when artifact rejection is disabled or decisions are deferred to the Decision
Matrix. Continuous MFF export retains the discontinuous acquisition intervals.
Intentionally segmented and averaged files retain their existing epoch layout.

MRI correction is allowed when the gap is outside its trigger-window support.
If a pause falls inside that support, EVA stops and asks for the uninterrupted
intervals to be processed separately rather than fitting templates across missing
data. Other analysis tools should likewise use recorded intervals only; a zero
placeholder must not be interpreted as a physiological observation.

Reopen the original recording to use the corrected reader. Previously generated
epochs and averages need rebuilding; an older export that already discarded the
acquisition timing cannot recover it automatically.

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
