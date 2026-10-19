# Epochs And Averages

EVA can segment recordings around events, compute category averages, and support single-trial analysis.

![Epoching controls](../assets/images/readme_epoching.png)

## Create Epochs

When creating epochs, choose:

- Event categories
- Time window around each event
- Baseline interval
- Whether to apply average reference
- Inclusion or exclusion rules for bad channels and artifacts

The PSA configuration sheet uses an editable **Events & Categories** table and a
resizable inspector. Drag the divider to give either side more room. The table
keeps event selection, counts, category names, and each code's DIN toggle and
timing-marker picker together. **Segment On** still supports codes, labels, and
artifacts, and the event filter and clear button remain available.

**Group…** creates either pooled categories or regex sub-selections, including
label/description matching, capture-group category names, suggestions, and match
previews. Groups and regex rules appear alongside events in the table and remain
visible when filtering event codes. The trash buttons remove them; a group's DIN
toggle still applies each selected member's own timing-marker settings. A regex
rule inherits its source code's onset settings even when that code is unchecked.

The inspector contains all processing options:

- **Epoch Window:** pre-stimulus and post-stimulus durations, offset, DIN
  tolerance, and warnings about events without a matching DIN. The preview marks
  onset and shades the pre-stimulus baseline when baseline correction is enabled.
- **Artifact Handling:** artifact rejection on/off, uncorrected-versus-any-artifact
  policy, and exclusion of epochs labeled Bad. The sliders button opens the
  existing artifact selector, including detected ocular artifacts, unreliable MRI
  spans, user-defined artifacts, and the optional rejection sub-window with its
  start/end values and clamping warnings.
- **Channel Interpolation:** per-epoch interpolation, minimum/maximum amplitude,
  slope and acceleration thresholds, rejection limits in percent or channel
  count, global escalation with its percentage threshold, and Reset to Defaults.
- **Output:** averaging by category, optional Decision Matrix review, average
  reference, and pre-stimulus baseline correction.

Expand the inspector sections to edit their options; the inspector scrolls
independently of the table. **Apply**, **Cancel**, progress, validation, and error
reporting retain their existing behavior.

## Review Epochs In The Decision Matrix

After PSA segmentation, the Decision Matrix opens as a compact floating window
above the epoched waveform, starting in Overview. Use **Processing → Show/Hide
Decision Matrix** to toggle it. Hiding or closing the window preserves the review.
The floating window remembers its position and size, including across launches.
Opening **Configure…**, cancelling, and then showing the matrix again reuses
the existing review and health evidence. Artifact-rule edits update decisions
without rescanning health; real signal, reference, baseline, or detector-threshold
changes still refresh the affected evidence.
New matrices start with the most recently used layout; each open recording keeps
its own window placement. A restored window is kept on an available screen when
the monitor setup changes.

With **Average by category** checked, leave **Use Decision Matrix** unchecked for
the usual direct averaging. Checking both keeps the guided PSA review sheet
(Configure → Review decisions → Average); it does not open the floating window.

- Click a cell to jump to its channel and epoch in the waveform and inspect its
  evidence in a docked details pane. The PSA review sheet uses the same pane,
  without waveform navigation. No second click or selection pop-up is needed.
  Drag the divider to resize the pane, or use **Hide Details** to recover matrix space.
  The compact pane prioritizes the outcome, exclusion reasons, and Cell/Epoch
  controls. Expand **Artifacts** or **Health & measurements** for event timing,
  correction evidence, and detailed scores. **Whole channel…** applies a decision
  across epochs; **Cell** applies only to the selected channel/epoch pair.
- Hover over an epoch-health badge or channel-health strip for a small health
  summary, without selecting anything. This works in Overview and the pinned
  Detail headers, including after sorting or scrolling.
  Hovering an epoch status icon also explains its meaning: ocular, cardiac/BCG,
  MRI/gradient, timing/marker, or another exclusion. These symbols are in the
  horizontally scrollable legend; an artifact icon alone does not mean rejection.
- Cell and epoch details show **corrected**, **uncorrected**, and **correction
  disabled** event counts. Expand artifact events for cleaning method and RMS
  evidence. A channel selection summarizes artifacts across the reviewed epochs,
  counting overlapping events once—not once per channel. This is event/epoch-level
  context, not proof that an individual channel is artifact-free after cleaning.
- **Max interpolated / epoch** adjusts the number of channels allowed to be
  repaired in each epoch. Counts and exclusions update immediately using the
  cached evidence, and averaging uses the same limit. Raising it can rescue an
  epoch rejected by the original count limit, but does not bypass artifact rules,
  epoch-health thresholds, electrode-position requirements, or spatial safety checks.
- **Amplitude (µV)** adds a fourth slider with independent minimum and maximum
  thumbs. Drag either thumb, use arrow keys on a focused thumb, or type exact
  bounds below it. Changes immediately reclassify the stored raw and reviewed
  amplitude evidence and update cell decisions, trial counts, and averaging.
  Widening the range can retain trials that exceeded the interpolation limit
  solely because of amplitude violations. Slope/acceleration limits, other health
  criteria, globally bad channels, artifact exclusions, spatial constraints, and
  manual decisions still apply. These are review cutoffs: they preserve the
  displayed reference/baseline and health evidence and do not change the PSA
  configuration sheet's processing thresholds. Edited bounds survive hiding or
  rebuilding the current review.
- Click a channel or epoch header to navigate; drag headers to select ranges.
- Drag a rectangle in Overview to zoom or act on an area. The details pane shows
  kept/excluded epoch counts and rejection reasons (which can overlap).
  Keep or interpolate just the selected cells, or keep/reject the selected whole
  epochs. Keeping cells alone does not override an epoch exclusion. Sorting changes
  the display order while decisions remain attached to the original trials.
- Rejected trials stay in the epoched view, with red health shading and a red
  epoch-health strip. They are excluded when you press **Average N Epochs**.
- Blue cells indicate planned interpolation; purple indicates an applied
  artifact correction. The legend remains available above the matrix.
- Option-click the epoch's health band in the waveform to edit its epoch
  decision or interpolate the channel under the pointer in that epoch. These
  controls and the matrix share the same decisions, so counts, cell colors and
  exclusion shading update immediately. A later manual edit takes precedence.
  The channel-label menu's recording-wide interpolation remains a separate action.

Reopening the matrix after averaging returns to the complete source epoch set,
so a rejected trial can be inspected and kept in a new average. Changing a
reference or baseline setting refreshes the evidence while preserving manual
decisions.

## Inspect Averages

After averaging, inspect the result as:

- Channel waveforms
- Butterfly plots
- Topographic maps
- Category overlays

![Trial analysis](../assets/images/readme_trial_analysis.png)

## Single-Trial Analysis

Single-trial tools can extract peak and amplitude values from selected channels and windows. Use these exports for downstream statistics when trial-level variability matters.

Before exporting, confirm:

- The measurement window matches the component of interest.
- Baseline choices are consistent.
- Rejected or cleaned trials are handled consistently.

For phase-persistence analysis and individualized frequency bands, continue with
[Explore Rhythmicity With Trials And Averages](../tutorials/rhythmicity-trials-averages.md).
