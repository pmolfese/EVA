# Filter, Epoch, And Average

This tutorial covers a basic event-related workflow: apply review-appropriate filtering, segment around events, compute averages, and inspect results.

## Goal

Create category averages that can be inspected as waveforms, butterfly plots, and topographic maps.

## Steps

1. Open a recording with event markers.
2. Review channel quality and mark obvious bad channels.
3. Open the filtering controls.
4. Choose high-pass, low-pass, and notch settings appropriate for the dataset.
5. Confirm the reference choice.
6. Open the epoching controls.
7. Select event categories.
8. Set the epoch window and baseline interval.
9. Compute category averages.
10. Inspect averages as channel traces, butterfly plots, and topographic maps.

## Checks

- The baseline interval should not include task-evoked activity.
- Category trial counts should be plausible.
- Bad-channel handling should be consistent across conditions.
- Filtering should not introduce visible ringing around sharp artifacts.

## Export

When the averages look correct, export the processed or averaged data needed for downstream analysis.
