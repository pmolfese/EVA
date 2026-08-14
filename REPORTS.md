# EVA — REPORTS

Design for **EVA Reports**: a per-recording quality/provenance report generated
from a processed EVA session or a saved MFF package.

Written 2026-08-11. Nothing here is implemented yet.

---

## Scope decision

The **report writer lives in EVA proper**, not a separate app or executable
target. It renders to multiple formats (JSON, HTML, Markdown). A dedicated
reader/comparer/visualizer is deferred until we know we need one — and if the
JSON contract below holds, that tool is easy to add later and easy to write in
any language.

---

## Design principles

Borrowed deliberately from MRIQC / fBIRN rather than MNE Report.

**1. The HTML is a rendering, not the artifact.**
MNE Report is a scrapbook: `add_figure()` in a loop, no schema, so nothing
downstream can consume it. MRIQC's individual HTML is a view over
`sub-X_T1w.json` — a flat dict of scalar IQMs with stable names. Group reports
and every cross-subject analysis read the JSON and never touch the HTML.

EVA follows MRIQC. The writer builds a typed `EVAReport` value; each format is a
pure function of that value.

**2. Flat scalars, stable names, one level deep.**
`snr_plusminus_target`, `chan_bad_n`, `ica_excluded_n`. No nesting, no arrays of
dicts in the scalar block (structured detail goes in a separate `detail`
object that the group tooling ignores). This is what makes assembling a
200-subject dataframe a one-liner.

**3. Flags are dataset-relative by default.**
MRIQC and fBIRN benefit from fixed acquisition — same protocol, same scanner, so
absolute thresholds mean something. EEG montages and paradigms vary far more, and
a hardcoded "line noise > X µV²" will be wrong across labs. Flags are
configurable, and where possible compare a subject against the rest of its batch
rather than an absolute cutoff. `ChannelHealthBaselines` already computes
dataset-relative medians; extend that pattern rather than hardcoding.

**4. Show the evidence, not just the verdict.**
The fBIRN move: a metric page plots the measurement against its threshold so it
reads as pass/fail on its own. Concretely for us — when a channel is failed,
show its raw trace, not only its grade.

**5. Never parse prose.**
Everything the report needs must come from typed inputs. Today, bad channels,
interpolation, and SNR are recoverable only by regex over
`log_eva_<date>_<time>.txt` (see [Upstream work required](#upstream-work-required)).

---

## Section outline

Order follows MRIQC's individual report (Summary → Visual → Verbose → Metadata →
References), adapted to EEG.

### 1. Summary

Package name, subject/session, EVA version + git hash, run timestamp, total wall
time, and the IQM table.

Plus a **flag strip** — the fBIRN contribution. A handful of graded checks
rendered as colored chips, readable in one glance when triaging 60 subjects:

- `>10%` of channels interpolated
- line noise above threshold
- any condition with `<20` retained trials
- split-half reliability `<0.6`
- ICA removed `>30%` of variance
- chain hash differs from batch mode (see §3)

### 2. Acquisition

MRIQC's Metadata section. Montage / `SensorLayout` name, channel count, sampling
rate, duration, amplifier info from `MFFRecording`, recording date, event-code
inventory with counts, and a **concurrent-MRI flag** (gradient correction present
⇒ EEG-fMRI, which changes how every other metric should be read).

### 3. Processing chain

`eva.xml` rendered as an ordered chain — one row per step: operation, parameters,
`replayable`, timestamp.

Also emit a **chain hash**: a digest over the ordered `(operation, sorted
params)` tuples, *excluding* subject-specific results. Two subjects with the same
hash were processed identically. A group report can then flag the one subject
whose filter cutoff differed. This single scalar is worth more than the whole
settings table.

### 4. Signal overview

The carpet-plot analogue, and the centerpiece — as in MRIQC's BOLD summary plot.

Channels × time heatmap (channels ordered by health grade, or posterior →
anterior), with tracks stacked underneath:

- GFP over time
- per-sample bad-channel count
- marked bad segments
- event markers

Before/after pairs wherever a stage changed the data globally. For EEG-fMRI, the
gradient-artifact residual trace belongs here.

### 5. Channels

`ChannelHealthFeatures` (`EVA/Health/ChannelHealthAnalyzer.swift`) is already an
IQM vector and already `Codable` — `rmsMicrovolts`, `p95/p99AbsMicrovolts`,
`flatlineFraction`, `clippingFraction`, `driftRMSMicrovolts`, `lineNoisePower`,
`neighborAgreement`, plus the typicality scores. Render as:

1. topomap colored by `goodPercentage`, bad marked ✕, interpolated ○
2. sortable per-channel feature table
3. small-multiples strip of the worst N channels' raw traces — *why* each channel
   was failed

(3) is what makes the report trustworthy rather than decorative.

### 6. Spectra

- PSD before/after filtering, overlaid
- per-channel PSD heatmap (channel × frequency)
- line-noise bar at 50/60 Hz with harmonics

Cheap to compute; catches a large fraction of real problems.

### 7. ICA

Header row: components fit, retained after PCA, excluded, variance removed.

Then one card per **excluded** component:

- topomap (`componentMaps`)
- time-course excerpt
- PSD
- ERP-image, when epoched
- auto-label from `ICAComponentAutoLabeler` / `ICLabelClassifier` with confidence
- the human decision, when it differed from the suggestion

Record **auto-label vs. human-override disagreement rate** as a scalar — a
genuinely useful QC number nobody publishes.

### 8. Segmentation & conditions

The trial-count table, already structured as `CategoryRejection` in `eva.xml`:
category, total, included, excluded-by-reason. Render as a stacked bar per
condition. Plus the per-epoch bad-channel summary and skipped-labeled-bad-segment
list currently emitted by `currentProcessingAuditLogLines()`.

### 9. ERP quality

Per condition: butterfly plot shaded by `SNRMetrics.noiseCurve`, GFP trace, and
the metrics row — `plusMinusSNR`, `baselineSNR`, `gfpSNR`,
`standardizedMeasurementError`, `splitHalfReliability`, `rootN`.

Add an **SNR vs. trials-included curve** if cheap: it answers "would more trials
have helped?", which is the question everyone asks after the fact.

### 10. Provenance & references

EVA version, git hash, platform; method citations for each step actually used
(Picard, wavelet thresholding, the clean-room FASTR implementation); the raw
`log_eva_*.txt` in a collapsed `<details>`.

MRIQC's References section exists so the methods paragraph writes itself. Given
`paper.md` is in flight, generating a **methods-paragraph draft** from the chain
is a small addition with outsized payoff.

---

## Output formats

| Format | Purpose | Figures |
|---|---|---|
| **JSON** | primary artifact; group analysis, batch QC | manifest only (names + paths) |
| **HTML** | human review, sharing | base64-inlined, self-contained single file |
| **Markdown** | pasting into lab notebooks, PRs, issues | sidecar PNGs in a `_figures/` dir |

JSON layout:

```json
{
  "schemaVersion": 1,
  "generator": { "app": "EVA", "version": "...", "gitHash": "...", "generatedAt": "..." },
  "source":    { "package": "...", "subject": "...", "session": "..." },
  "chainHash": "sha256:...",
  "scalars":   { "chan_bad_n": 4, "snr_plusminus_target": 3.12, "...": 0 },
  "flags":     [ { "id": "high_interpolation", "grade": "warn", "detail": "..." } ],
  "detail":    { "channels": [...], "conditions": [...], "ica": [...] },
  "figures":   [ { "id": "carpet", "path": "...", "caption": "..." } ]
}
```

`scalars` is the contract. `detail` and `figures` may evolve freely; anything
promoted to a cross-subject comparison must move into `scalars` with a stable
name.

---

## Scalar name registry

Prefix by domain. Non-exhaustive starting set — grow it deliberately, never
rename.

| Name | Meaning |
|---|---|
| `acq_channel_n` | channels in the recording |
| `acq_sampling_rate_hz` | sampling rate |
| `acq_duration_s` | recording duration |
| `acq_concurrent_mri` | 0/1, gradient correction present |
| `chan_bad_n` | channels marked bad |
| `chan_interpolated_n` | channels interpolated |
| `chan_bad_frac` | bad ÷ total |
| `chan_median_rms_uv` | median across channels of `rmsMicrovolts` |
| `chan_median_line_noise` | median `lineNoisePower` |
| `chan_min_neighbor_agreement` | worst `neighborAgreement` |
| `seg_total_n` / `seg_kept_n` | segments before/after rejection |
| `seg_bad_frac` | rejected ÷ total |
| `ica_component_n` | components fit |
| `ica_excluded_n` | components removed |
| `ica_variance_removed_frac` | variance attributable to removed components |
| `ica_label_override_frac` | human decisions differing from auto-label |
| `snr_plusminus_<condition>` | per-condition `plusMinusSNR` |
| `snr_gfp_<condition>` | per-condition `gfpSNR` |
| `snr_splithalf_<condition>` | per-condition `splitHalfReliability` |
| `snr_sme_<condition>` | per-condition standardized measurement error |
| `trials_included_<condition>` | trials surviving into the average |
| `trials_total_<condition>` | trials available |

Condition-suffixed names are the one concession to variable keys; group tooling
handles them by prefix match.

---

## Upstream work required

The report cannot be built from a saved package today. In dependency order:

1. ~~**ICA sidecar.**~~ **Done 2026-08-13** — `ICAReplayPayload`
   (`EVA/ICA/ICAReplayPayload.swift`), written into the package as
   `eva_ica.json` by `MFFExportWriter`, read back by
   `ICAReplayPayload.read(fromPackage:)`. It carries the excluded components with
   their labels and normalized topographies (the `SavedICAComponent` block), the
   per-component explained variance, and the fit provenance — everything §7 asks
   for except the time-course excerpt and PSD, which still need adding.

   Two notes for whoever writes §7 against it:
   - **`componentSources` is deliberately absent**, as this item always said —
     61 MB for a 128-ch/20-min run, 1.5 GB at 256 ch/60 min. The time-course
     excerpt and PSD must therefore be *computed at removal time and stored*, not
     derived later from the sidecar.
   - Both the `unmixingMatrix` **and the `mixingMatrix`** are persisted, not the
     `unmixingMatrix` + `channelMeans` this item used to suggest. `REWIND.md`'s
     ICA payload section explains why; the short version is that the apply path
     reads both matrices and never reads the fitted means. Matrices go to disk as
     base64 little-endian `Float64` so no value round-trips through decimal text.

   (`SavedICAArtifactSet` was not, as this item claimed, unreferenced —
   `saveICAJSON` has been writing it from the ICA sheet's manual export.)

2. **Typed results in `eva.xml`.** Promote the bad-channel, interpolation, and
   per-condition SNR lines out of `currentProcessingAuditLogLines()` prose into
   structured `<result>` elements, following the existing `<category>` pattern.
   Keep the text log as the human-readable mirror.

3. **Report builder** against those typed inputs.

---

## Interaction with the history tree

Once `REWIND.md`'s history tree exists, a report is generated **from a node**, not
from "the current state of the app". Two consequences:

- `EVAReport` carries the node ID it describes, so a report is unambiguous about
  which point in the processing history it measures. "Report from here…" is an
  item in the node's right-click menu; the tip is merely the default.
- A **comparison report** between two nodes of the same recording becomes
  possible — same subject, same data, one processing difference. That answers
  "what did ICA actually buy me?" with numbers rather than an impression, and it
  is a genuinely novel artifact to offer.

The `scalars` block is what makes the comparison cheap: two flat dicts, one diff.

---

## Deferred, but design for it now

**Group reports.** MRIQC's individual pages are useful; the
boxplot-of-every-IQM-with-this-subject-marked is what actually catches outliers.
If each subject emits flat JSON, the group report is an easy later addition. If
it doesn't, it never happens.

**Dedicated reader/comparer app.** Revisit only once the JSON contract has proven
stable across a real batch.
