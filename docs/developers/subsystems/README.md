# Subsystem Pages

One page per top-level source group. Each page lists its **purpose**, the
**entry-point types** to start from, a **one-line synopsis of every file**, and a
short **"how to extend this"** note. Start from
[the architecture map](../architecture.md) for the big picture and data flow.

## The `EVA/` app

Load → clean → epoch → analyze → view, plus the spines underneath.

| Group | Page | What lives here |
|---|---|---|
| Core | [core.md](core.md) | Shared DSP helpers: downsampling, statistics, spline interpolation, variance accounting. |
| IO | [io.md](io.md) | Opening/importing files (all formats), MFF export & split, physio import, figure export. |
| Channels | [channels.md](channels.md) | Electrode geometry, montages, bad-channel interpolation, topomaps, the Channels window. |
| Filtering | [filtering.md](filtering.md) | Band-pass/notch filters, filter design, re-referencing. |
| Gradient | [gradient.md](gradient.md) | MRI gradient-artifact removal (FASTR/AAS, OBS, ANC), motion params, GPU backends. |
| Cardiac | [cardiac.md](cardiac.md) | R-wave/ECG detection and BCG (ballistocardiogram) correction. |
| ICA | [ica.md](ica.md) | Independent Component Analysis: decomposition, labelling, component removal. |
| Wavelet | [wavelet.md](wavelet.md) | Wavelet denoising/reduction, artifact explorer, scalogram, GPU backend. |
| Artifacts | [artifacts.md](artifacts.md) | User-defined artifact templates + OBS/local-template cleaning. |
| Health | [health.md](health.md) | Channel- and segment-level quality scoring and training-data export. |
| Epoching | [epoching.md](epoching.md) | Epoch segmentation, PSA averaging, eye-artifact rejection, single-trial & diagnostics UI. |
| Trials | [trials.md](trials.md) | Statistical engines: cluster permutation, RIDE, Woody, nonlinear alignment. |
| Time-Frequency | [timefrequency.md](timefrequency.md) | Morlet/multitaper ERSP & ITPC, heatmaps, export. |
| Rhythmicity | [rhythmicity.md](rhythmicity.md) | LAVI / ABBA / WTPL rhythmicity detection and surrogates. |
| Analysis | [analysis.md](analysis.md) | Band-power spectra and connectivity. |
| Combine / Compare | [combine-compare.md](combine-compare.md) | Combining/grand-averaging recordings; diffing two windows. |
| Pipeline | [pipeline.md](pipeline.md) | **Spine:** history tree, snapshots, replay, batch, `eva.xml` provenance. |
| Waveform | [waveform.md](waveform.md) | The recording window and every panel/plot in it. |
| App & UI shell | [app.md](app.md) | App entry point, windows, preferences, update check, and the Simulator/help windows. |

## The `EVACore/` library (UI-free)

| Group | Page | What lives here |
|---|---|---|
| Core / Forward / Geometry | [evacore.md](evacore.md) | DSP, linear algebra, the shared forward models, meshes, registration, imaging. |
| IO | [evacore-io.md](evacore-io.md) | The MFF / FIF / NIfTI / GIFTI / OpenMEEG format readers and writers. |
| Simulation | [evacore-simulation.md](evacore-simulation.md) | Synthetic scalp-EEG generation, artifact models with truth, source fitting. |
