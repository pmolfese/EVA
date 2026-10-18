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

## Review Epochs In The Decision Matrix

After PSA segmentation, the Decision Matrix opens as a compact floating window
above the epoched waveform, starting in Overview. Use **Processing → Show/Hide
Decision Matrix** to toggle it. Hiding or closing the window preserves the review.
The floating window remembers its position and size, including across launches.
New matrices start with the most recently used layout; each open recording keeps
its own window placement. A restored window is kept on an available screen when
the monitor setup changes.

With **Average by category** checked, leave **Use Decision Matrix** unchecked for
the usual direct averaging. Checking both keeps the guided PSA review sheet
(Configure → Review decisions → Average); it does not open the floating window.

- Click a cell to jump to its channel and epoch in the waveform. Click it again,
  or use **Details**, to inspect evidence and make a decision.
- Click a channel or epoch header to navigate; drag headers to select ranges.
- Drag a rectangle in Overview to zoom or act on an area. Sorting changes the
  display order while decisions remain attached to the original trials.
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
