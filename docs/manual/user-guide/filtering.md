# Filtering And Referencing

Filtering, notch correction, and average reference controls are available from EVA's processing controls.

![Filter controls](../assets/images/readme_controls.png)

## Filtering

Filtering can make patterns easier to inspect, but it can also change waveform shape and latency interpretation. Choose cutoffs based on the research question and downstream analysis.

Common decisions include:

- High-pass cutoff for slow drift
- Low-pass cutoff for muscle noise or high-frequency activity
- Notch correction for line noise
- Whether filtering should be previewed, applied, or exported

## Referencing

Average reference is available as a processing option. Referencing changes the interpretation of every channel because each trace is expressed relative to a different reference signal.

Before comparing conditions or exporting processed data, confirm that all datasets in the analysis use compatible reference choices.

!!! caution
    Avoid documenting one-size-fits-all filter defaults. Good cutoffs depend on acquisition, task design, artifact profile, and analysis goals.
