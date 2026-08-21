# EVA User Manual

**EVA** is a native macOS application for opening, viewing, cleaning, and exploring EEG recordings. EVA stands for **Electrophysiology Viewer and Analysis**.

This manual is written for researchers, students, and lab staff who want to stay close to the signal while reviewing EEG data. It focuses on practical workflows: opening data, inspecting traces, managing channels, filtering, reviewing artifacts, computing epochs and averages, and exporting results.

![EVA waveform overview](assets/images/readme_waveform_overview.png)

## Start Here

- New users should begin with [Getting Started](user-guide/getting-started.md).
- If you want a guided walk-through, use [Open And Inspect A Recording](tutorials/open-and-inspect.md).
- If you are preparing documentation with an LLM, read [Writing With An LLM](contributor-guide/llm-docs-workflow.md).
- If you want to convert formats in bulk, generate test recordings, or check event timing from a terminal, see [Command-Line Tools](tools/index.md).

## Teaching With EVA

[EVA Simulate](tools/eva-simulate.md) generates synthetic recordings with known
ground truth — clean EEG alongside the same EEG carrying blinks, eye movements,
mains hum, bad electrodes and MR artifacts, each switchable. It is built for
demonstrating what an artifact looks like and what a filter actually did, since
you have the uncontaminated recording to compare against.

## Documentation Status

This is an initial manual scaffold built from the current README, repository notes, and visible feature structure. It should be reviewed against the live app before being treated as complete release documentation.

Use the callouts marked **Verify in app** as a checklist for places where exact button names, menu labels, or defaults should be confirmed from the current build.
