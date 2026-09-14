# Explore Rhythmicity With Trials And Averages

This tutorial explains EVA's Rhythmicity Explorer from top to bottom and shows
how its results connect to the **Trials**, **Averages**, and **Time-Frequency**
workspaces.

## Goal

Use a processed EEG recording to:

1. discover individualized frequency bands with LAVI and ABBA;
2. inspect event-related within-trial phase persistence with WTPL;
3. describe intermittent rhythmic bursts; and
4. reuse the discovered band borders in the Time-Frequency workspace without
   changing the underlying averages, ERSP, ITPC, or saved band preferences.

## The Mental Model

Rhythmicity is about the persistence of phase relationships over time. It is
not a synonym for amplitude, power, or a larger evoked response.

```text
Processed recording
├── Bands: LAVI spectrum → ABBA sustained/transient regions
├── Bursts: power peaks + power/WTPL boundaries
└── Epoch into trials
    ├── Trials: inspect and measure pre-average epochs
    ├── Averages: inspect category means
    ├── Rhythmicity Event-related: WTPL from the pre-average epochs
    └── Time-Frequency: ERSP, ITPC, or the shared WTPL engine
          ↑
          └── optional ABBA borders and ROI ranges published from Bands
```

The three Rhythmicity modes answer different questions:

| Mode | Question | Input | Main result |
|---|---|---|---|
| **Bands** | Which frequencies are relatively sustained or transient in this recording? | Processed recording, visible range, or waveform selection | One LAVI spectrum and ABBA band set per channel |
| **Event-related** | Does phase persist locally within each trial, and does that persistence change around an event? | Pre-average epochs grouped by condition | Raw WTPL, baseline-relative ΔWTPL, or valid-trial counts over frequency × time |
| **Bursts** | Where are short rhythmic episodes, and how long and frequent are they? | Processed recording, visible range, or waveform selection | Linked power/WTPL maps, burst annotations, and band summaries |

!!! important
    Rhythmicity Explorer is a neural-analysis workspace. A sustained band, a
    transient band, and a rhythmic burst are not artifact labels. Bursts never
    enter artifact rejection or cleaning automatically.

## Before You Start

For Bands or Bursts, open a readable recording and finish the preprocessing you
intend to analyze. Rhythmicity uses the current **processed recording**, including
the current reference and interpolated-channel state.

For Event-related WTPL and the Time-Frequency workspace, first create epochs:

1. Open **PROCESS** and configure segmentation around the desired events.
2. Choose the epoch window and any segmentation-time artifact rejection.
3. Apply the segmentation. Compute averages if you want the four workspace
   buttons—**Waveform**, **Averages**, **Trials**, and **Time-Frequency**—to remain
   available together.
4. Inspect trial counts and confirm that the requested WTPL baseline fits fully
   inside every epoch. EVA's default WTPL baseline is −1000 to −500 ms, so a
   shorter prestimulus epoch requires an explicit adjustment.

The Events/epoch categories become the condition names in Event-related WTPL and
Time-Frequency. WTPL is computed from the pre-average epoch stack, not from the
category-average waveform shown in Averages.

## Open Rhythmicity Explorer

From the main waveform toolbar:

1. Open the **EEG** menu.
2. Choose **Rhythmicity Explorer…**.
3. Use the segmented control at the top to choose **Bands**, **Event-related**,
   or **Bursts**.

The window has the same overall structure in every mode:

- the toolbar identifies the mode and reference preset;
- the left inspector selects data, channels, and method controls;
- the main canvas displays the result;
- the footer contains the run log, status, progress, Run/Cancel, and Close; and
- **Export** writes a mode-specific provenance package.

Changing a scientific input after a run keeps the previous result visible but
marks it **stale**. Re-run before using it as the current result. Cancelling a run
discards partial output and retains the last completed result, if one exists.

## 1. Discover Individualized Bands

Choose **Bands** when you want a recording-level rhythmicity spectrum and
subject-specific frequency borders.

### Choose the inference profile

At the top of the window, choose one of:

- **Paper 2026**: computes LAVI plus 200 deterministic, recording-matched IAAFT
  surrogates per channel. The surrogate ribbon supports inferential labels and
  can take substantially longer.
- **Exploratory — no significance**: computes LAVI and median-defined ABBA
  regions without the surrogate run. Use this while checking a range, channel,
  or preprocessing choice. “Not computed” is not the same as “not significant.”

The paper profile uses 47 logarithmically spaced frequencies from approximately
3.16 to 44.67 Hz, a five-cycle Morlet transform, and a 1.5-cycle LAVI lag.

### Work down the Configuration panel

1. **Source** is the processed recording and is currently fixed.
2. **Data** chooses **Entire recording**, **Visible range**, or **Waveform
   selection**. Set the visible range or waveform selection before opening the
   explorer.
3. **Channels** chooses **Selected channel**, **Visible good channels**, a named
   **Channel set**, or **All good EEG channels**.
4. Leave **Include marked artifacts** off for the ordinary workflow. EVA removes
   marked artifact intervals and splits the valid data around them, so LAVI lag
   pairs never bridge an excluded interval. Turning it on is an expert override.

Globally bad channels are excluded from every channel scope. Hidden channels are
also excluded from **Visible good channels**. Interpolated channels can be
analyzed, but remain identified in provenance.

Prefer the entire clean recording when defining stable subject-level bands. A
short selection may not contain enough valid cycles at the low-frequency end.
The inspector warns when the evidence is short or when the sampling rate is low
for the top of the frequency range.

### Check Validity & provenance

Before and after the run, read this panel rather than treating every colored
region as equally supported:

- **Ready** means no result has been computed for the selection.
- **Exploratory** means LAVI and ABBA regions exist without significance.
- **Reference-valid** means the paper settings have a complete matched
  200-surrogate ribbon.
- **Custom significance** means an on-demand ribbon matches a non-paper
  configuration.
- **Invalid / insufficient** means the input produced no usable evidence.
- **Stale** means the displayed result no longer matches the signal or controls.

The same area records the signal revision, sampling rate, reference state,
warnings, and the status of any compact recording-scoped result restored from a
previous session.

### Run and read the result

Select **Run Analysis**. The footer reports the current channel × frequency ×
profile workload. Expand **Run Log** to see validation, Morlet transformation,
aperiodic fitting, surrogate generation, and ABBA assignment.

LAVI ranges from 0 to 1. A value nearer 1 means that the complex time-frequency
representation maintains a more predictable phase relationship over the chosen
lag. It does not mean that the signal has greater power.

ABBA divides each channel's LAVI profile around that profile's median:

- an above-median region is **sustained**;
- a below-median region is **transient**;
- the largest deviation from the median is the region's peak or trough; and
- when a sustained peak exists from 6–14 Hz, EVA anchors it as **Alpha** and
  names neighboring regions relative to it. Otherwise the bands remain
  **Unanchored**.

Use the presentation control above the canvas:

- **Spectrum** shows one channel's LAVI curve, median, surrogate ribbon, and
  linked ABBA table.
- **Matrix** compares sensor × frequency LAVI and keeps the selected channel
  linked to the table.
- **Gallery** shows compact channel spectra.
- **Topography** maps the selected region's peak LAVI across sensors when an
  electrode layout is available.

The ABBA table reports band limits, peak frequency, peak LAVI, deviation from the
median, inference state, significance margin, and valid pair count.

## 2. Send ABBA Bands To The Averages/Time-Frequency Workspace

This connection is deliberately explicit and session-only.

1. In Bands, choose the channel whose borders you want to reuse with **Displayed
   channel**.
2. Confirm that the result is current and that the channel has at least one ABBA
   region.
3. Select **Use in Time-Frequency**.

EVA then:

1. publishes the displayed channel's ABBA borders, peaks, sustained/transient
   identities, and provenance for the current recording session;
2. closes Rhythmicity Explorer;
3. switches the averaged-data workspace to **Time-Frequency**; and
4. selects **Rhythmicity Explorer** as the Time-Frequency **Band source**.

Nothing is re-epoched or re-averaged. The action does not alter the ERSP, ITPC,
or WTPL values, and it does not overwrite the band definitions saved in EVA's
preferences.

In Time-Frequency, the published bands do two jobs:

- the heatmaps receive tinted sustained/transient regions, solid band borders,
  dashed peak-frequency lines, labels, and band details on hover; and
- the **Band** picker uses the same frequency ranges for band × time-window ROI
  summaries and scalar exports.

When an all-channel Time-Frequency view is shown, EVA applies the one displayed
source channel's borders to every channel and says so in a warning. It does not
silently mix a different set of ABBA borders into every sensor's ROI.

If the processed signal changes, the published set becomes stale and is refused.
Re-run Bands and publish it again. If no set has been published, choosing the
Rhythmicity Explorer band source produces an unavailable-band warning.

## 3. Compare Power, ITPC, And WTPL In Time-Frequency

The **Time-Frequency** button beside **Averages** and **Trials** analyzes the same
condition-labeled pre-average epochs. Select **Power**, **ITPC**, or **WTPL** at
the top of that workspace.

| Measure | What it compares | Interpretation |
|---|---|---|
| **Power / ERSP** | Signal energy over frequency and time | Amplitude-related event dynamics |
| **ITPC** | Phase across trials at the same frequency and time | Cross-trial phase consistency |
| **WTPL** | Phase at nearby times within each trial, then averages trial-level values | Local within-trial phase persistence |

A response can have high WTPL and low ITPC when its phase evolves consistently
inside each trial but is not aligned across trials. A stimulus-aligned phase
reset can raise ITPC while local WTPL behaves differently. Report them as
separate measures.

The Time-Frequency WTPL option is a convenience path through the same validated
WTPL engine used by Rhythmicity Explorer. It fixes Morlet width at five cycles,
uses signed one-cycle lags, and disables Multitaper. Its frequency and baseline
controls belong to the Time-Frequency workspace; publishing bands does not copy
an already-computed Event-related map or its settings into this workspace.

Use **A − B** to subtract completed condition means. Use **ΔWTPL** to subtract,
at each frequency, the mean WTPL over the explicit baseline. These operations
are distinct and can be combined.

!!! warning
    The complete WTPL baseline interval must fit inside the contributing epochs.
    EVA never shortens it automatically. If the interval is unavailable, choose
    a valid baseline or show raw WTPL.

Build the all-channel overview after changing measure, conditions, frequencies,
or method settings. The published ABBA ranges remain display/ROI metadata; they
do not participate in the Morlet or WTPL calculation.

## 4. Run Event-Related WTPL In Rhythmicity Explorer

Return to **EEG > Rhythmicity Explorer…** and choose **Event-related** for the
complete WTPL inspection and export workflow.

### Conditions & measure

1. Choose **Condition A**.
2. Optionally enable **Difference (A − B)** and choose a different Condition B.
3. Choose **Raw WTPL**, **ΔWTPL**, or **Valid counts**.

Raw WTPL is bounded from 0 to 1. ΔWTPL is raw WTPL minus that frequency's mean
over the explicit baseline and can be positive or negative. For a difference,
EVA computes each condition mean first and then subtracts B from A. In a
Valid-count difference view, each cell displays the smaller supporting count
from A and B.

### Channels and WTPL configuration

Choose the channel scope. A named set or all-good scope schedules a separate
WTPL result for each eligible channel; it does not average those channels into
one virtual trace.

The paper WTPL method uses −1 and +1 cycle lags and a fixed five-cycle Morlet
transform. Set the minimum frequency, maximum frequency, number of logarithmic
frequency bins, and explicit ΔWTPL baseline. The maximum frequency must remain
below Nyquist.

### Band overlay & ROI

Choose **EVA defaults**, **User preferences**, or **Rhythmicity Explorer** as the
band source. A fresh published ABBA set adds the same display overlay and defines
the band used by the ROI control below the map.

After the run:

- the summary chips show measure, conditions, channel, trial counts, valid
  trials per cell, and lags;
- the heatmap shows frequency × event-relative time;
- hatched cells are invalid or unsupported, not zero;
- the **Band** and **Window** controls calculate an on-screen ROI mean; and
- changing an epoch, condition, channel scope, frequency plan, lag, or baseline
  marks the previous result stale until it is rerun.

Invalid edge cells are expected because the complex Morlet coefficient and both
signed one-cycle lag positions must exist. Lower frequencies generally lose more
edge samples. Use **Valid counts** before interpreting apparent edge effects.

## 5. Understand The Trials And Averages Interface

The workspaces share data, but they do not share every decision:

| Workspace or mode | Reads | Writes or affects |
|---|---|---|
| **Trials** | Raw pre-average epochs and category labels | Trial measurements; a committed review can rebuild category averages |
| **Averages** | Category means built from the eligible trial set | Displays waveforms, butterfly plots, topomaps, differences, and related summaries |
| **Rhythmicity Event-related** | Raw pre-average epochs and category labels | A separate WTPL result; never changes trial samples or averages |
| **Time-Frequency** | Raw pre-average epochs and category labels | Separate ERSP, ITPC, or WTPL maps; never changes averages |
| **Rhythmicity Bands → Time-Frequency** | One selected channel's published ABBA result | Overlay and ROI band definitions only |

Event-related and Time-Frequency group the pre-average segments by category,
trim unequal trials to their shortest available length, preserve the common
time axis using the earliest stored event offset, and compute each selected
channel separately. That is why their
trial counts should agree with the available segmented stack, while their values
will not resemble an analysis performed directly on the category-average trace.

!!! note "Current reviewed-exclusion boundary"
    A trial exclusion committed in **Trials** is applied when EVA rebuilds the
    category averages. The current Event-related and Time-Frequency paths read
    the pre-average segmented cache, so that reviewed-average exclusion is not
    automatically removed from their input stack. Segmentation-time rejection
    happens earlier and is reflected in all of these workspaces. When trial
    inclusion must be identical across an average and WTPL/ERSP/ITPC analysis,
    verify the displayed trial counts and perform the exclusion during epoch
    construction until a shared reviewed-exclusion filter is available.

This boundary also explains why **Use in Time-Frequency** changes no averages:
the transfer is a band-definition handoff, not a signal-processing step.

## 6. Detect Rhythmic Bursts

Choose **Bursts** to characterize intermittent rhythmic episodes in continuous
or selected processed data.

### Data & channels

The data-range, channel-scope, bad-channel, and marked-artifact rules match Bands.
If the input is segmented, each segment remains a separate analysis unit.

### Detection

The paper workflow uses:

- a five-cycle Morlet transform;
- a frequency-specific 90th-percentile power threshold to find peaks;
- a 75th-percentile power boundary to estimate onset and offset;
- a minimum duration measured in cycles; and
- an overlap merge rule that also requires nearby peak frequencies.

For an analysis explicitly based on phase persistence, change **Boundary** to
**WTPL threshold** and provide the desired cutoff. This changes how duration is
defined; it is not interchangeable with the paper's P75 power boundary.

### Band assignment and result canvas

Choose a band source. A fresh channel-specific LAVI/ABBA result preserves each
channel's sustained/transient identity. EVA defaults or user preferences provide
fixed names and limits without that ABBA direction. With no current published or
in-memory ABBA result, bursts can still be detected but remain unassigned.

The result canvas links:

- a normalized-power or WTPL background map;
- burst boxes and peak markers;
- the corresponding waveform interval;
- rate, occupancy, duration, power, WTPL, and band summaries;
- a duration distribution; and
- a sortable burst table.

## 7. Export Reproducible Results

Select **Export**, choose a parent folder, and let EVA create a new folder named
from the recording plus the current mode. EVA does not overwrite an existing
destination folder.

| Mode | Main exported content |
|---|---|
| **Bands** | `manifest.json`, `lavi.csv`, `abba-bands.csv`, `lavi.npy`, `lavi-ribbon.npy`, and `warnings.txt` |
| **Event-related** | Per-condition raw and ΔWTPL NPY arrays, valid-count arrays, `wtpl-scalars.csv`, `manifest.json`, and `warnings.txt` |
| **Bursts** | `bursts.csv`, `burst-band-summary.csv`, per-map power/WTPL NPY arrays and axis sidecars, `manifest.json`, and `warnings.txt` |

Exports record the method version, source revision, settings, frequency and time
axes, processing information available to EVA, and validity warnings. Invalid
WTPL cells remain NaN and have separate valid-trial counts; they are never
exported as zero.

For a methods section, report at least the EVA version, processed-signal and
reference state, data selection, included channels, frequency grid, Morlet width,
lag definition, significance profile and seed when applicable, WTPL baseline,
condition trial counts, band source, warnings, and exported method version.

## Final Checks

Before interpreting or exporting a result, confirm that:

- the result is current rather than stale;
- the analyzed signal is the intended processed revision and reference;
- marked-artifact inclusion matches the analysis plan;
- the duration supports the lowest analyzed frequency;
- the sampling rate supports the highest analyzed frequency;
- WTPL trial counts match the intended epoch stack;
- the complete ΔWTPL baseline exists;
- valid-count maps support the time-frequency cells of interest;
- the published ABBA borders came from the intended displayed channel; and
- rhythmic bursts are being treated as neural-analysis annotations, not
  automatic cleaning decisions.

## Scientific Reference

EVA's LAVI, ABBA, WTPL, and burst workflows follow Karvat et al. (2026),
*Universal rhythmic architecture uncovers two modes of neural dynamics*. See
the [Rhythmicity Explorer design reference](../development/design/rhythmicity.md)
for the equations, pinned reference implementations, validation strategy, and
developer-level provenance details.
