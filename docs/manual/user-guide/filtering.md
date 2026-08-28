# Filtering And Referencing

Filtering, notch correction, and average reference controls are available from EVA's processing controls.

![Filter controls](../assets/images/readme_controls.png)

## Filtering

Filtering can make patterns easier to inspect, but it can also change waveform shape and latency interpretation. Choose cutoffs based on the research question and downstream analysis.

Common decisions include:

- High-pass cutoff for slow drift
- Low-pass cutoff for muscle noise or high-frequency activity
- IIR design: smooth Butterworth or steep elliptic with configurable ripple and stopband attenuation
- FIR window: Hamming or Kaiser with configurable attenuation
- FIR application: zero-phase forward/backward, delay-compensated single pass, or causal forward-only
- Notch correction for line noise
- Whether filtering should be previewed, applied, or exported

The **Auto** family chooses IIR for a high-pass below (or, when selected, through)
its crossover and FIR for the other edges. The IIR design and FIR window remain
independently selectable, so Auto can use either Butterworth/Hamming or an
elliptic/Kaiser combination.

The **Approximate…** menu configures the implementation mechanics to resemble
EEGLAB, ERPLAB, MNE-Python, or EGI Net Station. Applying a package approximation
does not change the entered high-pass or low-pass cutoffs, line-noise mode,
notch frequency or harmonics, referencing, PNS selection, or precision. The
resolved mechanics are saved directly in `eva.xml`; the package label is not a
persistent mode.

An FIR notch is selected independently from the passband family, so changing a
package approximation cannot silently convert an existing FIR notch to IIR (or
vice versa).

!!! note
    Forward/backward filtering squares the one-pass magnitude response and
    doubles attenuation and ripple when expressed in dB. Delay-compensated FIR
    uses one pass without shifting the samples. Forward-only FIR is causal and
    retains the kernel's fixed group delay.

## Referencing

Average reference is available as a processing option. Referencing changes the interpretation of every channel because each trace is expressed relative to a different reference signal.

Before comparing conditions or exporting processed data, confirm that all datasets in the analysis use compatible reference choices.

!!! caution
    Avoid documenting one-size-fits-all filter defaults. Good cutoffs depend on acquisition, task design, artifact profile, and analysis goals.
