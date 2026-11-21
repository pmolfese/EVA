# EEG and processing vocabulary

These are working definitions for reading EVA, not a substitute for the method specifications in `docs/provenance`.

| Term | Meaning in the code |
| --- | --- |
| Channel | One recorded or derived signal. Channel indices are generally zero-based; a displayed electrode label is not an array index. |
| Sample / sampling rate | One value at one time; samples per second are measured in Hz. Convert between time and sample indices using the operation's documented rounding rule. |
| Epoch / trial | A finite interval selected around an event. An event need not be at its first sample. A trial often means one experimental repetition; stored epoch segments also describe averaged data. |
| ERP | Event-related potential: an event-aligned average across trials. |
| PSA | EVA's post-stimulus averaging/segmentation workflow. The window can include a pre-event baseline; the name does not constrain all samples to be after the event. |
| Artifact | A signal contribution unwanted for the analysis, such as eye movement, muscle, heartbeat or scanner interference. Removing an artifact can also remove brain signal, so preservation is tested separately. |
| Reference / rereferencing | The voltage comparison used for EEG samples. Average referencing subtracts an eligible-channel mean; channel eligibility is part of the operation's contract. |
| Montage / sensor layout | Electrode identities and positions. A flat layout, unit-sphere geometry and physical positions in metres are different representations. |
| Lead field / forward model | A mapping from a hypothetical source to measurements at electrodes. Matrix axes and reference convention must be explicit. |
| ICA | Independent component analysis. A fitted unmixing operator converts channels to components; reconstruction uses the associated mixing representation. |
| PCA / OBS | Principal components summarize variance. An optimal basis set uses selected components to model an artifact. Explained variance is not proof of biological origin. |
| BCG / ECG / CWL | Ballistocardiogram (heartbeat-related artifact), electrocardiogram (cardiac recording), and carbon-wire-loop reference signals used for correction. |
| AAS / TR | Average artifact subtraction, and the MRI repetition interval. Volume epochs and slice epochs have different timing grids. |
| CWT / Morlet / DPSS | Continuous wavelet transform, a complex wavelet family, and tapers used for spectral estimation. Their width and normalization conventions affect comparisons. |
| ERSP / ITPC | Event-related spectral perturbation and inter-trial phase coherence. Power and phase consistency answer different questions. |
| LAVI / ABBA | Local Auto-correlated Vector Index and automatic band-border assignment. LAVI describes frequency-dependent temporal structure; ABBA derives bands from that profile. |
| WTPL | Within-trial phase locking. Do not interchange it with ITPC, which compares phase across trials. |
| RIDE | Residue Iteration Decomposition: separates components with different relationships to stimulus timing and trial latency. |
| RMS / SNR | Root mean square amplitude and signal-to-noise ratio. Check whether a particular SNR is a linear ratio or in decibels. |
| Provenance / replay | A record of what processing occurred, and reapplying supported recorded operations. A record alone may not include fitted data required for exact replay. |
| Revision / stale result | Identity of a particular input state, and a result computed from inputs that no longer match it. A file URL alone does not identify processed samples. |
