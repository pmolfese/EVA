# Mark And Interpolate Bad Channels

This tutorial walks through deciding whether a channel should be hidden, marked bad, or interpolated.

## Goal

Identify a bad EEG channel and document the decision before interpolation.

## Steps

1. Open a recording and inspect the waveform.
2. Find a channel that is flat, saturated, disconnected, or consistently noisy.
3. Compare the channel with nearby electrodes.
4. Check whether the problem persists across the recording.
5. Mark the channel as bad.
6. If sensor geometry is available and neighboring channels are reliable, apply spherical-spline interpolation.
7. Review the interpolated trace in the waveform view.

## Decision Guide

- Hide a channel when it is irrelevant to the current display.
- Mark a channel bad when it should be excluded from analysis decisions.
- Interpolate only when replacing the channel is appropriate for the analysis.

## Quality Note

Record:

- Channel label
- Reason for marking
- Whether interpolation was applied
- Any uncertainty about the decision

Example:

> E57 marked bad due to persistent flat signal across the recording. Interpolated from neighboring electrodes after confirming sensor layout.
