# Overview

EVA keeps the recording visible while analysis tools remain close at hand. The main workflow is:

1. Open a supported recording.
2. Inspect the waveform, events, channels, and sensor layout.
3. Mark bad channels or hide channels that are not relevant to the current review.
4. Apply filtering, notch correction, reference changes, or artifact-correction tools as needed.
5. Segment the data into epochs, compute averages, and inspect category-level results.
6. Export processed recordings, figures, or analysis summaries.

EVA is designed as a transparent review environment rather than an autopilot. When it flags a channel, segment, component, or artifact, the goal is to expose the evidence behind that judgment so the researcher can verify it.

## Major Workspaces

The exact layout depends on the recording and active tools, but EVA's main view centers on the waveform. Around it are panels and popovers for:

- Channels and sensor layout review
- Event browsing and user markers
- Filtering, line-noise removal, and reference changes
- MRI gradient artifact correction for simultaneous EEG/fMRI recordings
- Artifact definition, detection, preview, and cleaning
- ICA component review with ICLabel support
- Channel and segment health scoring
- Epoching, category averages, butterfly plots, and single-trial analysis

![EVA controls](../assets/images/readme_controls.png)
