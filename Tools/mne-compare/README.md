# mne-compare — EVA vs MNE-Python parity on shared processing steps

EVA and MNE-Python both implement bad-channel interpolation, average
referencing, epoch extraction, baseline correction, and trial averaging.
This directory holds the reference values MNE produces for those steps, in
the same fixture-pair pattern as `Tools/forward-compare` and
`Tools/resolve-validate`: Python computes the answer with MNE, writes it to a
committed JSON fixture, and an EVATests suite (`EVATests/Compare/MNEReferenceTests.swift`)
feeds the *same* inputs to EVA's own functions and diffs the outputs.

```bash
/Users/molfesepj/micromamba/envs/mne/bin/python Tools/mne-compare/make_reference.py
```

Regenerates `EVATests/Fixtures/Compare/mne_reference.json` (~650 KB,
committed — a synthetic 12-channel, 4-second recording, small enough to keep
in git). Run the comparison suite with:

```bash
xcodebuild test -project EVA.xcodeproj -scheme EVA -destination 'platform=macOS' \
    -only-testing:EVATests/MNEReferenceTests
```

## What's covered, and how

| EVA | MNE-Python reference | Comparison |
|---|---|---|
| `SphericalSpline.interpolationWeights` | `mne.channels.interpolation._make_interpolation_matrix` | weights, donor-by-donor, tolerance 1e-6 |
| `ChannelInterpolationSolver.solve` | weights above applied to the same signal | reconstructed waveform, tolerance 1e-3 µV |
| `Rereferencing.applyInPlace` (average, excluding a bad channel) | mean of the non-excluded channels, subtracted from every channel | element-wise, tolerance 1e-3 µV |
| `EpochingViewModel`'s `preSamples`/`epochLength` formula | `mne.Epochs(tmin, tmax)`'s `n_times` | see "Epoch length" below — a documented difference, not equality |
| `PSABuildResult.average()` + `.postProcessed(baselineCorrect: true)` | `mne.Epochs(..., baseline=...).average()` | evoked waveform, tolerance 1e-3 µV — see "Baseline window" below |

Both electrode positions and the interpolation regularization constant
(`alpha`/`lambda = 1e-5`) come from the same source on both sides: EVA's
`StandardMontageData` and this script both read MNE's bundled
`spherical_1005.tsv`, so a mismatch in the interpolation test is EVA's spline
math, not a coordinate disagreement.

## Two real convention differences (found, not "fixed")

**Epoch length.** MNE's `Epochs(tmin, tmax)` is closed at both ends:
`n_times = round((tmax - tmin) * sfreq) + 1`. EVA's `makeBuildJob` computes
`epochLength = round((preStimulus + postStimulus) * sfreq)` — one sample
short of MNE's convention for the same window. `MNEReferenceTests` asserts
this relationship explicitly (`mne_n_times == eva_epoch_length + 1`) so it
stays visible rather than silently comparing arrays MNE would consider
different lengths.

**Baseline window endpoint.** MNE's default `baseline=(None, 0)` includes the
sample *at* the event (t=0) in the mean it subtracts. EVA's
`PSABuildResult.withBaselineCorrection` uses `preStart..<preEnd` — the
pre-stimulus window only, excluding the event sample. The fixture computes
MNE's evoked both ways (`baseline=(None, 0)` and `baseline=(None, -1/sfreq)`,
i.e. explicitly excluding the boundary sample) so the test can show EVA
matches MNE's *exclusive* convention exactly (differences ~1e-14, pure
floating-point noise) while genuinely diverging from MNE's *default*
(differences on the order of the sample-to-sample signal change, not noise).

Both are worth knowing before assuming an MNE-authored epoch window or
baseline period can be typed into EVA (or vice versa) unchanged.

## Order of operations: average-then-baseline vs baseline-then-average

MNE baseline-corrects each trial before averaging. EVA's PSA "average first"
path averages raw trials, then baseline-corrects the average
(`buildAndPostProcess` calls `.average()` before `.postProcessed(...)`).
Because both operations are linear means over the same fixed window in every
trial, they commute — `mean_i(x_i) - mean_i(baseline_i) == mean_i(x_i -
baseline_i)` — and `MNEReferenceTests.evokedMatchesMNEUnderSameBaselineWindow`
confirms EVA's order produces the same evoked as MNE's, to floating-point
precision, once the baseline-window endpoint convention above is matched.
EVA's non-averaged PSA path (`shouldAverage == false`) baseline-corrects each
trial individually, matching MNE's order directly, so this equivalence is
what makes the two paths consistent with each other as well as with MNE.

## Real-recording fixture

`make_real_reference.py` runs the same interpolation and average-reference
checks, plus a band-pass filter check, against a real EGI acquisition (real
digitized electrode geometry, real task events, real 1000 Hz noise floor)
instead of the synthetic idealized montage:

```bash
/Users/molfesepj/micromamba/envs/mne/bin/python Tools/mne-compare/make_real_reference.py \
    /path/to/a/real/recording.mff
```

Writes `EVATests/Fixtures/Compare/local/real_reference.json` — **git-ignored**
(a real subject's EEG is never committed), so `MNERealFileReferenceTests`
skips cleanly with a printed message when it's absent, the same pattern
`EVATests/IO/FIFInteropTests.readBEM` uses for its own git-ignored fsaverage
fixtures. Regenerate it locally to actually run those four tests.

The filter check (`bandPassFilterMatchesMNE`) is real-data-only: it needs a
signal with genuine 1/f content and a realistic noise floor to be a
meaningful test of a band-pass filter, which the synthetic fixture's
sine-plus-noise signal doesn't have. It found something worth documenting:

**Filter design agrees on paper, not to the bit.** EVA's `.eeglabMNE` FIR
design rule exists to reproduce `mne.filter.filter_data(fir_design='firwin',
phase='zero')`, and the transition-width and −6dB-shift formulas do match
(verified by hand: a 1 Hz high-pass clamps to a 1 Hz transition on both
sides via MNE's `min(max(f·0.25,2),f)` and EVA's headroom cap, giving both a
shared ~3300-tap combined-kernel length at 1000 Hz). Measured on the real
recording, after trimming 4 s of edge transient from each end, the two
filtered signals differ by roughly 0.5-1% relative RMS — small, and nowhere
near a different design, but not floating-point noise either. The most
likely source is `scipy.signal.firwin`'s window normalization differing in
its last bit from EVA's own `DSP.windowedSincLowPass`; not chased further
here. `MNERealFileReferenceTests.bandPassFilterMatchesMNE` asserts the
*quantified* gap (relative RMS < 2%) rather than bit-identity, so a real
regression (e.g. a wrong cutoff or transition width) still fails it.

## What's not covered here (yet)

- **Per-epoch bad-channel interpolation** (`interpolatesBadChannelsPerEpoch`,
  `PSAGlobalBadChannelInterpolator`) — same spline math as the continuous
  case above, but re-solved per epoch against a possibly different good set;
  not separately cross-checked yet.
- **Epoching/baseline/averaging on the real recording** — covered on the
  synthetic fixture only so far; the real-recording fixture doesn't include
  it yet.
- **Notch filtering** — EVA's biquad notch and FIR notch aren't compared
  against `mne.filter.notch_filter`, which uses a different (spectrum
  fit/regression) method by default.

## Simulator MFF-writer namespace bug (fixed)

EVA's own synthetic-simulator MFF output (`.regression-corpus/**/*.mff`,
`resources/EyeBlink.mff` predating this fix) did **not** parse under MNE's
`mffpy`-based reader, even though real EGI acquisitions and EVA's own
`MFFReader` both read it fine. Root cause: `mffpy`'s tag registry keys
strictly on the namespaced root tag
(e.g. `{http://www.egi.com/sensorLayout_mff}sensorLayout`), and several of
EVA's from-scratch XML writers (used when there is no source MFF to copy
metadata from — i.e. every file EVASimulate produces) omitted the `xmlns`
declaration entirely. `sensorLayout.xml` and `coordinates.xml` had a second,
structural bug on top of that: their `<sensor>` elements were direct
siblings of `<name>` rather than nested inside a `<sensors>` (and, for
coordinates, `<sensorLayout>`) wrapper, which `mffpy`'s parser requires
(`self.find('sensors')`) regardless of namespace. EVA's own reader
(`EGISensorXMLParser`) is a flat, namespace-and-nesting-agnostic
`XMLParser` delegate, so it never noticed either bug — only external readers
did. Fixed in:

- `EVACore/IO/MFFWriter.swift` — `writeSignalInfoXML` (info1.xml),
  `writePNSInfoXML` (info2.xml), `writeEventsXML` (Events_EVA.xml),
  `writeSensorLayoutXML`'s synthesized fallback, and `writePNSSetXML`
  (pnsSet.xml's `pnsSet_mff` namespace, `<sensors>` container, and channel
  units/metadata).
- `EVACore/Simulation/ImpedanceModel.swift` — `writeInfoXML`, which rewrites
  info1.xml after `MFFWriter` to add the `ICAL` calibration block (was
  overwriting the now-correct namespace with its own unnamespaced template).
- `EVACore/Simulation/Montage.swift` — `MontageWriter.sensorLayoutXML` and
  `.coordinatesXML`, which is what EVASimulate actually calls (it overwrites
  `MFFWriter`'s fallback layout files to add real electrode geometry) — the
  same file `MFFWriter.swift`'s fallback was fixed for, but a separate,
  independent template. Simulator coordinates are also scaled from unit
  vectors to the simulated scalp radius in EGI's required centimetres, so MNE
  does not interpret them as a 1 cm-radius head.

Verified: both clean and PNS-bearing noisy packages from a scenario generated
with the fixed simulator (`EVASimulate generate ...`) now load under
`mne.io.read_raw_egi` with the expected EEG/PNS channels, a correctly scaled
montage, and annotations. Previously they failed in
`mffpy.xml_files.XML.from_file` while dispatching the unnamespaced XML roots.
