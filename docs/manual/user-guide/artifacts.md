# Artifact Review And Cleaning

EVA supports artifact definition, detection, preview, and cleaning. The workflow starts from the data: identify an artifact, define what it looks like, then decide how EVA should search for and clean similar patterns.

![Artifact workflow](../assets/images/readme_artifact_workflow.png)

## Define Artifacts

You can define artifacts from waveform regions or scalp topography. Use this when you know the artifact pattern you want to find, such as eye blinks, movement bursts, scanner artifacts, or repeated physiological noise.

When defining an artifact, consider:

- Which channels express the artifact most clearly
- Whether the artifact is time-locked or variable
- Whether waveform shape, topography, or both should guide matching
- Whether similar-looking neural activity could be mistaken for artifact

## Preview Cleaning

EVA includes several cleaning approaches, including regression, OBS, SSP/PCA, and averaging-based methods. Preview the result before applying a cleaning step.

Threshold detection and ICA are independent. **Eye Blink** and **Eye Movement**
can remain enabled while you run or review **ICA…**; applying an ICA removal
automatically reruns the enabled threshold detectors on the updated signal.

## Movement Artifact PCA (MAAC-3)

Choose **Artifacts > Movement Artifact (PCA)…** to open the MAAC-3 movement
detection sheet. Choose **Analyze Movement** to run temporal PCA separately
within each analysis range, apply an oblique Promax rotation, and identify
factors whose channel back-projection exceeds the configured peak-to-peak
threshold (200 µV by default). Review the affected ranges, then choose **Add
Movement Markers**. EVA adds one duration-bearing `MOV` marker per affected
range and creates a **MAAC Movement** definition for **Clean Artifacts**.

The default **Automatic** boundary mode uses stored epoch boundaries when the
recording contains them. For continuous recordings it falls back to
non-overlapping one-second windows, including a shorter final window. The
detection sheet can force either mode and change the window length, threshold,
Promax power, and maximum factor count. These settings are saved with the
definition so its markers and later correction use the same configuration.

Adding markers closes the detection sheet; it does not open or run **Clean
Artifacts**. When you are ready, open **Clean Artifacts** yourself. The **MAAC
Movement** row is already set to **MAAC-3 Movement PCA**. Applying it reruns the
saved analysis and subtracts the selected movement factors while leaving bad
and unselected channels unchanged. MAAC-3 is intentionally unavailable for
averaged data.

## Muscle Artifact BSS-CCA (MAAC-4)

Choose **Artifacts > Muscle Artifact (BSS-CCA)…** to open MAAC-4's detection
and review sheet. EVA separates sources by canonical correlation between the
multichannel signal and its one-sample-delayed copy. Muscle-like sources have
relatively low temporal autocorrelation and relatively high high-frequency
power; no samples are changed during this analysis step.

Automatic range selection uses stored epoch boundaries when present. Otherwise
it uses 10-second continuous windows with 50% overlap and crossfades the removed
contributions at window boundaries. The CCA operator is estimated near 250 Hz
for efficiency, then applied to the native-rate samples. Bad, already
interpolated, and unselected EEG channels are unchanged, and PNS channels are
not part of the EEG matrix.

Choose **Analyze Muscle** to review the suggestions. The descriptive progress
panel reports the current CCA/spectral stage, ranges and samples completed,
flagged and skipped ranges, component counts, throughput, and estimated time
remaining. The default classifier marks a component when its mean 15–30 Hz
power divided by its mean 1–15 Hz power is at least 1/7, following De Vos et
al. You can edit the bands, ratio, analysis rate, and windowing.

Each affected range appears in the review list. Use its scope button or the
**Previous**, **Next**, and **Show in Waveform** controls to center and highlight
the full interval, then check or uncheck its components. Overrides are stored
by range and component, so applying or replaying the same definition is
deterministic. If upstream ICA/ICLabel results exist, the panel shows its Muscle
labels as a QC cross-check only; ICLabel never prevents or forces BSS-CCA
removal.

**Add Muscle Markers** adds duration-bearing `EMG` markers and a **MAAC Muscle**
definition, then closes the detection sheet. It does not open or run **Clean
Artifacts**. Open that sheet yourself when you are ready to preview and apply
the saved BSS-CCA decisions.

MAAC-4 requires an unaveraged signal whose available sampling bandwidth covers
the configured EMG band. EVA refuses insufficient Nyquist bandwidth and warns
when an active low-pass has already attenuated part of that band. In standalone
Clean Artifacts use, definitions run in the order shown. EVA's full-MAAC
ordering mode instead guarantees that movement correction runs before muscle
correction; the future one-click MAAC preset will select that mode across the
complete pipeline.

Check whether:

- The artifact is reduced.
- Neighboring neural signal remains plausible.
- New edge artifacts or ringing have not been introduced.
- The method behaves consistently across events or channels.

## Saccadic Spike Potential

Choose **Artifacts > Saccadic Spike Potential…** to detect and correct the brief,
biphasic potential produced at saccade onset. This workflow is separate from
blink correction: it works in the first-difference domain, rereferenced to Cz,
and uses a spatial scalp template because these fast spikes are not reliably
isolated by ICA.

EVA proposes Cz, vertical EOG, lower vertical EOG, and horizontal EOG channel
roles from channel names or the active sensor layout. Confirm those one-based
channel numbers before detection, especially for a custom montage. Marked-bad
and already-interpolated channels are omitted. If Cz is not present as a
recorded or restored channel, restore the acquisition reference or select the
correct Cz-equivalent channel before continuing.

The default **Canonical** template maps the EP Toolkit's 33-channel canonical
saccadic-spike topography onto the recording montage and normalizes it so the
absolute Cz-to-lower-VEOG difference is one. **Session average** instead derives
the map from preliminary candidates in the current recording; use it when the
canonical map is visibly inappropriate, recognizing that it is more vulnerable
to a poor candidate set. Raising the threshold makes detection more
conservative.

After detection, inspect the number of preliminary and confirmed events and the
template topography. **Use Detected SPs** adds the result to Clean Artifacts with
the dedicated **SP Spatial Filter** treatment. The cleaning preview shows the
estimated **Subtracted SPs** beside the data **With SPs removed**. Look for a
sharp ocular/parietal spike in the removed estimate without broader ERP-shaped
activity; if the removed estimate looks neural, revise the channel roles or
threshold before applying it.

## MRI Gradient Artifact Correction

For simultaneous EEG/fMRI workflows, EVA includes MRI gradient artifact correction tools. Treat scanner-artifact correction as a high-stakes processing step and validate parameters against known acquisition timing whenever possible.

EVA's fMRI gradient-removal methods are independent re-implementations written from the published papers and EVA's own clean-room functional specifications. They are not copied from, or intended to be bit-identical to, FMRIB FASTR, FACET, BERGEN, AMRI, or other MATLAB toolbox implementations. The same method names describe the scientific family and user-facing intent, but details such as edge handling, donor fallback, numerical tolerances, interpolation, OBS safeguards, and GPU/CPU execution can differ from historical toolbox versions.

### Template Methods: AAS, MAS, And MAR

These methods build a local scanner-artifact template from neighboring TRs or artifact epochs, then subtract that template from the target epoch.

| Method | Template | Scaling | Best fit | Main trade-off |
| --- | --- | --- | --- | --- |
| AAS | Arithmetic mean of neighboring epochs | No fitted scale in EVA's retired Fast AAS path; Allen AAS uses a more guarded running-template variant | Low-motion, stable scanner artifact | Fast and simple, but a contaminated donor can pull the mean and unscaled subtraction cannot track amplitude drift well |
| MAS | Sample-wise median of neighboring epochs | Unscaled | Local-template replacement when the artifact is mostly stable but occasional donor epochs are bad | More robust than AAS to one bad donor, but still assumes the template amplitude is close enough to subtract directly |
| MAR | Sample-wise median of neighboring epochs | Least-squares amplitude fit before subtraction | Artifact amplitude changes across the run | Tracks amplitude better than MAS, but fitted scaling can remove signal that happens to correlate with the template |

Fast AAS is retired from new selections in EVA, but old processing files that name it still reproduce. For new work, MAS is the closest practical replacement when you want the same local-neighbor template idea with better resistance to contaminated donors. Allen AAS remains available as the closer Allen-style average-template method, using fixed sections, correlation-gated template updates, and optional ANC.

### FASTR Family: FASTR, Moosmann, And FARM

FASTR-family methods use EVA's shared slice-template correction engine. They can operate at volume level or slice level, align artifact epochs, fit template scale, subtract the estimated scanner artifact, and optionally run OBS residual removal and ANC. The family differences are mainly how donor epochs are chosen.

| Method | Donor rule | Use when | Notes |
| --- | --- | --- | --- |
| FASTR Original | Temporal neighbors | Scanner artifact is stable enough that nearby epochs are good donors | This is the baseline slice-template method with optional sub-sample alignment, OBS, and ANC |
| Moosmann | Motion-informed neighbors | Head motion changes the artifact, and a motion file is available | High-motion volumes are still corrected but are avoided as donors; EVA tries not to average across a motion event when possible |
| FARM | Correlation-ranked donors | Artifact waveform similarity matters more than proximity in time | EVA searches candidate epochs and prefers donors whose artifact waveform correlates strongly with the target; if too few qualify, it falls back to temporal neighbors |

Shared FASTR-family controls include slices per volume, trigger position, donor-window size, alignment and sub-sample alignment, template scaling, OBS mode, ANC, and optional high-motion donor exclusion. OBS and ANC can improve residual suppression, but they can also remove plausible EEG when the residual or adaptive reference is not artifact-dominated. Preview the correction and inspect representative channels before applying it broadly.

### Motion And Timing Checks

All fMRI gradient-removal methods assume regularly spaced scanner markers and a known relationship between TR markers, slice timing, and EEG samples. Before applying correction:

- Confirm the selected TR marker is the scanner marker, not a task event.
- Check that skipped first/last markers match any dummy scans or trimmed motion rows.
- Use the correct slices-per-volume value for slice-level correction.
- Load motion parameters before using Moosmann or high-motion donor exclusion.
- Record method settings in your analysis notes, especially donor windows, motion threshold, OBS, ANC, and template scaling.

## Ballistocardiogram Correction

The pulse artifact is corrected separately from the gradient artifact, in the BCG panel. EVA offers detection-plus-cleaning methods, carbon-wire-loop (CWL) regression, and surrogate-source separation (PCA-S).

### PCA-S: Surrogate-Source Separation

PCA-S models the recording as a fixed brain model plus a small BCG topography dictionary, fits both at once, and reconstructs only the brain part. The brain block is regularized and the artifact block is not — that asymmetry is what separates them, since any variance the artifact topographies can explain is cheaper to place there. Unlike template subtraction, which removes an average artifact along with whatever evoked signal shares its timing, PCA-S removes only what the brain model cannot explain.

It is a *correction*, not a detector: it consumes beats another step already found (BCG detection, or ECG/QRS detection) and never invents them.

**What it needs, and what it refuses:**

- **3D electrode coordinates for every corrected channel.** The brain model is physical, so an approximate montage would build a filter for someone else's head. EVA refuses rather than substituting one, and the panel names the channels it lacks coordinates for.
- **Detected beats.** With none, the Correct button stays disabled.
- **A head model, which is always an assumption.** EVA uses a classic three-shell sphere (72/79/85 mm), and states so in the panel and in the export audit log for every corrected recording.

**Settings worth understanding:**

| Setting | Default | What moving it does |
| --- | --- | --- |
| Brain regularization | 2% | The mechanism, not a tuning knob. Lower it and less is removed; raise it and the filter starts removing brain signal. |
| Regional sources | 29 | The size of the brain model — 29 sources of three orthogonal dipoles each, the published configuration. More sources describe brain activity more richly and leave the artifact block less to absorb. |
| Pattern search | Iterative | Iterative judges each beat against the running average; Paper follows the publication's single representative beat. |
| Beat match | 0.60 | Spatio-temporal correlation a beat must reach to join the template. |
| Component reliability | 0.90 | The split-half correlation a template component must reach to be treated as artifact. Components that do not repeat between odd and even beats are residual EEG, and removing them costs brain signal. |

The panel reports what each run fitted: how many beats were accepted, how many components were kept and at what reliability, how many were rejected, and what share of the variance was removed. The same facts go into `log_eva_*.txt`, and the portable settings into `eva.xml`, so a corrected recording can be re-corrected the same way — or checked.

**Channel count matters more than it appears.** The brain model is a tighter description of what brains can produce as electrode count rises, so the artifact block absorbs more of the slack at 20 channels than at 64. A low-density evaluation understates the method.

### References

Dien, J. (2024). Multi-Algorithm Artifact Correction (MAAC) procedure part one: Algorithm and example. *Biological Psychology, 188*, 108775. https://doi.org/10.1016/j.biopsycho.2024.108775

De Clercq, W., Vergult, A., Vanrumste, B., Van Paesschen, W., & Van Huffel, S. (2006). Canonical correlation analysis applied to remove muscle artifacts from the electroencephalogram. *IEEE Transactions on Biomedical Engineering, 53*(12), 2583-2587. https://doi.org/10.1109/TBME.2006.879459

De Vos, M., Riès, S., Vanderperren, K., Vanrumste, B., Alario, F.-X., Van Huffel, S., & Burle, B. (2010). Removal of muscle artifacts from EEG recordings of spoken language production. *Neuroinformatics, 8*(2), 135-150. https://doi.org/10.1007/s12021-010-9071-0

Semlitsch, H. V., Anderer, P., Schuster, P., & Presslich, O. (1986). A solution for reliable and valid reduction of ocular artifacts, applied to the P300 ERP. *Psychophysiology, 23*(6), 695-703. https://doi.org/10.1111/j.1469-8986.1986.tb00696.x

Berg, P., & Scherg, M. (1994). A multiple source approach to the correction of eye artifacts. *Electroencephalography and Clinical Neurophysiology, 90*(3), 229-241. https://doi.org/10.1016/0013-4694(94)90094-9

Rusiniak, M., Bornfleth, H., Cho, J.-H., Wolak, T., Ille, N., Berg, P., & Scherg, M. (2022). EEG-fMRI: Ballistocardiogram artifact reduction by surrogate method for improved source localization. *Frontiers in Neuroscience, 16*, 842420. https://doi.org/10.3389/fnins.2022.842420

Masterton, R. A. J., Abbott, D. F., Fleming, S. W., & Jackson, G. D. (2007). Measurement and reduction of motion and ballistocardiogram artefacts from simultaneous EEG and fMRI recordings. *NeuroImage, 37*(1), 202-211. https://doi.org/10.1016/j.neuroimage.2007.02.060

Allen, P. J., Josephs, O., & Turner, R. (2000). A method for removing imaging artifact from continuous EEG recorded during functional MRI. *NeuroImage, 12*(2), 230-239. https://doi.org/10.1006/nimg.2000.0599

Glaser, J., Beisteiner, R., Bauer, H., & Fischmeister, F. P. S. (2013). FACET: A flexible artifact correction and evaluation toolbox for concurrently recorded EEG/fMRI data. *BMC Neuroscience, 14*, 138.

Liu, Z., de Zwart, J. A., van Gelderen, P., Kuo, L.-W., & Duyn, J. H. (2012). Statistical feature extraction for artifact removal from concurrent fMRI-EEG recordings. *NeuroImage, 59*(3), 2073-2087. https://doi.org/10.1016/j.neuroimage.2011.10.042

Moosmann, M., Schoenfelder, V. H., Specht, K., Scheeringa, R., Nordby, H., & Hugdahl, K. (2009). Realignment parameter-informed artefact correction for simultaneous EEG-fMRI recordings. *NeuroImage, 45*(4), 1144-1150. https://doi.org/10.1016/j.neuroimage.2009.01.024

Niazy, R. K., Beckmann, C. F., Iannetti, G. D., Brady, J. M., & Smith, S. M. (2005). Removal of FMRI environment artifacts from EEG data using optimal basis sets. *NeuroImage, 28*(3), 720-737. https://doi.org/10.1016/j.neuroimage.2005.06.067

van der Meer, J. N., Tijssen, M. A. J., Bour, L. J., van Rootselaar, A. F., & Nederveen, A. J. (2010). Robust EMG-fMRI artifact reduction for motion (FARM). *Clinical Neurophysiology, 121*(5), 766-776.
