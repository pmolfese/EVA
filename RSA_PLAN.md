# EVA — RSA_PLAN

Making EVA the near-seamless producer of the representational dissimilarity
matrices that `3dRSA` consumes, plus the sensor-space RSA that belongs in EVA
itself.

This is a design document, not a status file. `ROADMAP.md` decides priority and
milestone status; when this work is scheduled, it enters that table as **RSA-1**
and following. Status values here are proposals.

---

## 1. The seam

`3dRSA` does the group-level lifting: permutation inference, FDR/FWE over the
joint time × space family, joint fits, contrasts, commonality, noise ceilings.
It does not — and should not — build sensor-space M/EEG geometry. Its own help
says so:

> Sensor-space M/EEG belongs in fixed `-model_mat` matrices or a time-resolved
> `-model_series`, not in `-model_dset`. — `3dRSA.c:711`

So the seam is a **file**: a square, symmetric, finite matrix in AFNI 1D format,
plus (for time-resolved work) an ordered list file naming one such matrix per
latency. EVA's job is to make those files trivially correct, fully provenanced,
and impossible to mis-order.

Three distinct products, because `3dRSA` has three distinct entry points:

| Product | Rows/cols | Feeds | 3dRSA invocation |
|---|---|---|---|
| **P1** Condition RDM | conditions | `-model_mat` | `-mode RSA -dataTableFile …` |
| **P2** Condition RDM series | conditions, one file per latency | `-model_series` | `-mode RSA … -model_series list.txt` |
| **P3** Subject RDM | subjects | `-model_mat` | `-mode IS-RSA -featuretype rdm` |

P1 and P2 are the EEG→fMRI fusion path (Cichy-style). P3 is the inter-subject
path: "do subjects whose EEG geometry is similar have similar fMRI geometry?"
EVA can build P3 today from combined multi-subject recordings
(`EVA/Combine/RecordingCombiner.swift`, `EpochSegment.subject`).

---

## 2. The contract, verified against source

Read from `thd_simmatrix.c:563` (`THD_simmat_read_1D`) and `3dRSA.c`.

### 2.1 The matrix file

- AFNI 1D text, whitespace-delimited, read by `mri_read_1D`.
- **Square.** `nx != ny` → hard exit.
- **Dimension must equal the neural matrix's** — condition count for `-mode RSA`,
  subject count for IS-RSA. Mismatch → hard exit naming both sizes.
- **Every off-diagonal entry finite.** A single NaN/Inf → hard exit with the
  offending `(i,j)`.
- **Symmetric to `1e-5 * (1 + max|entry|)`.** Asymmetry is fatal, and correctly
  so: the permutation relabels rows and columns together, so an asymmetric input
  produces a silently wrong null.
- **The diagonal is never read.** It is not validated either. Write zeros.
- `#` and `//` lines are skipped by the reader (`mri_read.c:2213`), and are
  *retained* in `comment_buffer` when `save_comments` is set. A commented header
  is therefore free to write today and recoverable by a future reader — see §6.1.

### 2.2 The series list file

From `rsa_read_model_series` (`3dRSA.c:1423`) and the help at `3dRSA.c:664`:

```
Time     ModelFile
-100ms   eeg_m100.1D
   0ms   eeg_000.1D
 100ms   eeg_p100.1D
```

- Header optional; `#` comments and blanks skipped.
- Exactly two tokens per row. Extra text → hard exit. **So time labels cannot
  contain whitespace.**
- Time labels must be **unique**; duplicates → hard exit.
- Relative `ModelFile` paths resolve **relative to the list file**, so EVA should
  write the list beside its matrices and use bare filenames.
- **At least two time points.** Input order is preserved and is the output order.
- Every matrix re-validated under the §2.1 contract.
- `-model_series` **defines the complete model set**: it cannot be combined with
  `-model`, `-model_mat`, `-model_dset`, or `-model_label`, and joint fits,
  contrasts, commonality, and LOO are rejected (`3dRSA.c:2676`, `:2680`).

### 2.3 Trap one — sense (sign)

`THD_simmat_new` uses `calloc`, so `is_dist = 0`, and `THD_simmat_read_1D` never
sets it. **Every `-model_mat` file is assumed to be a SIMILARITY.**

The neural side's sense depends on the fMRI pipeline:

| fMRI input | Neural condition RDM | Sense |
|---|---|---|
| `-dataTable` + `-neural_metric corr` (default) | Pearson | similarity |
| `-dataTable` + `-neural_metric euclid` | Euclidean | **distance** |
| `-runwiseTable` (crossnobis) | cross-validated squared Euclidean | **distance** |

An RDM is a *dissimilarity*. Hand a true RDM to the default path and the reported
correlation is sign-flipped, and `3dRSA`'s advisory message
(`3dRSA.c:3366`) confidently says the opposite of the truth, because it believes
the file is a similarity. `3dRSA` prints the sense and will not stop you
(`3dRSA.c:1195`) — but it cannot know.

**Decision: EVA exports a true dissimilarity and never silently converts.**
Rationale: crossnobis distances are unbounded and validly negative; `1 - d` is
not a similarity in any meaningful sense for them, and inventing one would be a
lie that survives into a figure. Instead EVA (a) stamps `# sense: dissimilarity`
into the file header, (b) records it in the manifest, and (c) emits a ready-to-run
command template that pairs the file with a distance-sense neural metric.
Where the user's fMRI side is known to be correlation-based, the exporter offers
`1 - r` similarity export **only** for correlation-distance RDMs, where it is
exact and reversible, and refuses it for crossnobis.

### 2.4 Trap two — condition order

Row *i* of the EEG RDM must be the same condition as sub-brick *i* of every
subject's fMRI `InputFile`. Nothing in the current contract checks this. A
transposed pair of conditions produces a plausible, publishable, wrong number.

EVA is well placed to close this: it knows its own condition labels
(`EpochSegment.category`). Mitigations, in order of strength:

1. Commented header naming the ordered conditions (free, §2.1).
2. A sidecar `<prefix>.rsa.json` manifest with the ordered labels.
3. A checker in `Tools/` that runs `3dinfo -label` on the fMRI dataset and
   diffs the order, refusing on mismatch.
4. **Recommended `3dRSA` change:** `-model_labels` — see §6.1.

---

## 3. What EVA already has

Almost every hard piece exists. This is assembly, not invention.

| Need | Existing |
|---|---|
| condition × trial × channel × time tensor | `multichannelTrials`, `SingleTrialAnalysisViews.swift:1679` |
| trial rejection / reviewed exclusion | `TrialExclusionResolver`, `TrialSelectionAnalyzer` |
| pooled-condition detection | `TrialSimilarityAnalyzer.pooledRelations`, `:88` |
| Cholesky (whitening) | `LinearAlgebra.factorSymmetricPositiveDefinite`, `:228` |
| symmetric eigendecomposition (MDS) | `LinearAlgebra.symmetricEigenDecomposition`, `:412` |
| correlation kernels | `TrialSimilarityAnalyzer.correlation`, `TrialAlignmentMetrics.timeResolvedCorrelation` |
| time-frequency | `ContinuousWaveletTransform.transform`, `WaveletScalogram`, Metal backend |
| matrix heatmap view | `ClusterStatisticHeatmap`, `ClusterStatisticsViews.swift:1114` |
| time-stepped display | `TopoFilmstripView` |
| tabular export + save panel | `exportTrialMatrix`, `SingleTrialAnalysisViews.swift:2903` |
| figure export (PNG/PDF/contact sheet) | `FigureExportBasket` |
| channel subsets / ROIs | `ChannelSet`, `ChannelSetStore` |
| multi-subject grand average | `EVA/Combine/`, `EpochSegment.subject` |
| provenance | `EVAProcessingScript`, `eva.xml`, history tree |

Two things EVA has that a generic Python RDM script does not, and which are the
actual argument for building this here:

- **It knows the rank of the data.** Average referencing costs one rank; ICA
  component removal costs one per component; interpolated channels cost one each.
  EVA performed all three and has them in `eva.xml`. A channel × channel noise
  covariance from such data is singular, so shrinkage is not a tuning knob — it
  is a correctness requirement, and EVA can say so with the actual numbers rather
  than warning generically.
- **It knows which trials were excluded and why.** Unequal trial counts bias
  non-cross-validated distances by ≈ 1/n. EVA's own exclusion machinery *creates*
  that imbalance, so it must be the thing that reports and corrects it.

---

## 4. Design

### 4.1 The pattern vector

An RDM entry is a distance between two condition **patterns**. EVA supports four
pattern definitions, all reducing to a vector per condition per trial:

| Pattern | Vector | Use |
|---|---|---|
| `spatial` | channels, at one time point | time-resolved RDM series (P2) |
| `spatiotemporal` | channels × samples in a window | one summary RDM (P1) |
| `spectral` | channels × frequencies, from CWT | frequency-resolved RDM |
| `temporal` | samples, one channel/ROI | rarely right; offered, warned |

Channels come from a `ChannelSet`, so an occipital-only RDM is a montage choice,
not a code change.

### 4.2 The estimator ladder

Three estimators, presented in increasing order of trustworthiness, with the
third the default wherever it is available:

1. **Correlation distance** `1 - r` over condition-average patterns. Cheap,
   familiar, and **positively biased by noise ∝ 1/n_trials**. Available always.
2. **Euclidean / Mahalanobis distance** over condition averages, with optional
   diagonal or shrinkage whitening. Same bias.
3. **Crossnobis** — cross-validated squared Mahalanobis. Unbiased, zero-centred
   under the null, validly negative. Requires ≥ 2 independent folds.

Matching `3dRSA`'s `THD_simmat_crossnobis` (`thd_simmatrix.c:413`) exactly is the
goal, including its denominator (`nfold * (nfold-1) * nfeature`, over ordered
fold pairs) and its refusal to clip negatives. A parity test against that C code
is an exit criterion, not a nicety.

**Folding.** EEG has no "runs" in the fMRI sense. Fold by **time-contiguous
blocks of trials**, not interleaved trials. Interleaved folds share slow drift,
electrode impedance change, and alertness state, which is precisely the shared
noise cross-validation is meant to cancel — interleaving puts the bias back while
appearing to remove it. Where the recording genuinely has blocks or was combined
from several files, use those boundaries; EVA knows them.

**Noise covariance.** Estimated from **baseline-window residuals** across trials
(channels × channels), never from the condition estimates being compared.
Ledoit–Wolf shrinkage toward a scaled identity, eigenvalues floored — mirroring
`THD_noise_whalf` (`thd_simmatrix.c:483`). Mandatory, not optional, for the
reasons in §3.

### 4.3 The RSA workspace

A new `EVA/RSA/` module. RSA is a **read-only analysis** — it does not modify the
signal — so it needs no `EVAProcessingStep.Operation` case and does not enter the
history tree, in the same way `SingleTrialAnalyzer` does not. But the *export*
must carry the pipeline that produced the epochs: the manifest embeds the
`eva.xml` step list and its digest. An RDM without its preprocessing provenance
is not reproducible, and this is cheap to get right at the point of writing.

```
EVA/RSA/
  RSAPatternExtractor.swift    condition × trial × feature tensors
  RSADistance.swift            correlation / euclid / mahalanobis
  RSACrossnobis.swift          folds + unbiased estimator (3dRSA parity)
  RSANoiseCovariance.swift     Ledoit-Wolf, rank-aware
  RSAMatrix.swift              square matrix + labels + sense + metadata
  RSAExport.swift              1D writer, series list, manifest, cmd template
  RSAViewModel.swift
  RSAViews.swift               heatmap, MDS, dendrogram, filmstrip
```

---

## 5. Phases

### RS-1 — Core RDM engine — *foundation*

`RSAPatternExtractor` + `RSADistance` + `RSAMatrix`. Condition-average patterns
over a `ChannelSet` and a time window; correlation and Euclidean distance;
pooled-condition detection wired in from `TrialSimilarityAnalyzer.pooledRelations`
so a pooled pair is flagged rather than silently reported as near-zero distance.

**Exit criteria**
- Round-trip test: a synthetic geometry recovers to within tolerance.
- Symmetry and finiteness hold by construction, asserted in tests.
- Pooled conditions surface as a warning carrying both category names.
- Unequal-N is reported per condition, with the ≈1/n bias stated numerically.

### RS-2 — Crossnobis and noise normalization

`RSACrossnobis` + `RSANoiseCovariance`. Block-contiguous folds; `none`/`diag`/
`shrinkage` matching `3dRSA`'s `-noise_norm` vocabulary exactly.

**Exit criteria**
- Numerical parity with `THD_simmat_crossnobis` on shared fixtures, to float
  tolerance. Fixtures live in `EVATests/RSA/`.
- Rank accounting from `eva.xml` (reference, ICA, interpolation) reported, and
  `shrinkage` forced when the covariance is singular.
- Negative distances preserved, never clipped, with a test asserting it.
- Refuses < 2 folds, or < 3 trials per condition per fold, with a message that
  says what to do instead.

### RS-3 — Export to 3dRSA (P1)

`RSAExport`. Writes:

```
<prefix>.1D            square matrix, zero diagonal, # header
<prefix>.rsa.json      manifest
<prefix>.3dRSA.txt     ready-to-run command template
```

Header (skipped by `mri_read_1D`, retained in `comment_buffer`):

```
# EVA RDM
# sense: dissimilarity
# estimator: crossnobis
# noise_norm: shrinkage
# n_conditions: 6
# conditions: LC++ RC++ LI++ RI++ Neut Fix
# channels: occipital (24 of 128)
# window: 80..180 ms
# eva_pipeline: <digest>
```

The manifest carries the same plus per-condition trial counts, fold structure,
sampling rate, reference, rank, and the full `eva.xml` step list.

**Exit criteria**
- Files pass `THD_simmat_read_1D` unmodified — verified by an actual `3dRSA` run
  in the test script, not by inspection.
- Symmetry margin is well inside `1e-5 * (1 + max|entry|)`; the writer
  symmetrizes as `0.5 * (M + Mᵀ)` before writing rather than trusting arithmetic.
- The command template names a **sense-consistent** neural metric, and the
  exporter refuses to emit a template that mixes senses.
- `Tools/check-rdm-order.sh` compares the manifest's condition order against
  `3dinfo -label` on a named fMRI dataset and exits non-zero on mismatch.

### RS-4 — Time-resolved series (P2)

A stack of spatial RDMs, one per latency bin, plus the `-model_series` list.

**Exit criteria**
- Time labels are single tokens, unique, monotonic, and encode sign and unit
  unambiguously (`m100ms`, `p000ms`, `p100ms` — leading `-` is legal in the file
  but reads badly in the output table and sorts wrongly by eye).
- Matrices written beside the list with bare relative filenames.
- ≥ 2 time points enforced in EVA, with EVA's own message, before the user
  discovers it from `3dRSA`.
- **Default to time bins, not raw samples.** 250 Hz over −200…800 ms is 250
  matrices and a 250 × n_searchlight joint FWE family. Default bin ≈ 10 ms with
  the count and the resulting family size shown before writing.
- A note in the template that joint/contrast/commonality/LOO are rejected under
  `-model_series`, so the user is not surprised.

### RS-5 — Subject × subject RDMs (P3)

From combined multi-subject data: each subject's condition RDM triangle becomes
their feature vector; the subject × subject matrix is the distance between those
triangles. This is exactly `3dRSA`'s second-order IS-RSA feature construction
(`3dRSA.c:1705`) — including the `1 - s` conversion that puts correlation-based
inner RDMs into a common dissimilarity sense — so it must match it.

**Exit criteria**
- Subject order in the matrix matches the `dataTable` `Subj` order; the manifest
  states it and the checker verifies it.
- Parity with `rsa_subject_rdm`'s sense handling on shared fixtures.
- Refuses < 6 subjects, matching `3dRSA`'s own floor (`3dRSA.c:3052`).

### RS-6 — Frequency and time-frequency RDMs

Reuse `ContinuousWaveletTransform` / `WaveletScalogram`. Patterns become
channels × frequencies at a latency, or channels × frequencies × time in a window.
Per-band RDMs (theta, alpha, beta, gamma) exported as separate `-model_mat`
files, which then support `-model_contrast alpha-gamma` at the group level.

**Exit criteria**
- Band edges and wavelet parameters recorded in the header and manifest.
- Power is log-transformed before distance by default, with the choice recorded —
  raw power is heavy-tailed and a Euclidean distance on it is dominated by one
  condition's outlier trials.
- Explicit warning that wavelet time-smearing correlates adjacent latency bins,
  so a time-frequency `-model_series` has a smoother, more autocorrelated time
  axis than a broadband one, and the joint FWE family is correspondingly less
  independent than its size suggests.

### RS-7 — EEG↔EEG and EEG↔behavior, inside EVA

Not everything needs `3dRSA`. Two analyses are naturally EVA's:

- **Temporal generalization.** Correlate the RDM at time *t* with the RDM at
  time *t′* for all pairs — the standard "is the representation stable or
  dynamic?" matrix. Purely internal; renders as a heatmap.
- **Model / behavior RDMs.** Build an RDM from a per-condition covariate
  (accuracy, RT, a rating, a stimulus property) or from a categorical design, and
  Mantel-test it against the EEG RDM with condition permutation. Single-subject
  level only; the group test stays in `3dRSA`.

The behavior side needs a table importer — conditions × covariates. `TW-6 —
Trial covariates` in `ROADMAP.md` is the same importer; build it once.

**Exit criteria**
- Permutation relabels **conditions**, applied to rows and columns together —
  never the triangle entries. That is the classic Mantel error and `3dRSA` calls
  it out by name (`3dRSA.c:361`).
- Below 6 conditions the Mantel test is refused, matching `3dRSA`.
- Model RDMs export through the same RS-3 writer, so a design matrix built in
  EVA can be a `-model_mat` too.

### RS-8 — Display

Heatmap with condition labels (from `ClusterStatisticHeatmap`), classical MDS
scatter (from `symmetricEigenDecomposition`), hierarchical dendrogram, and a
filmstrip/animation over the time-resolved stack (from `TopoFilmstripView`).
All routed through `FigureExportBasket` so an RDM figure composes with the rest.

**Exit criteria**
- Diverging colormap centred on zero whenever the estimator is crossnobis, since
  the sign is meaningful there and a sequential map hides it.
- MDS reports the variance explained by the plotted dimensions; a 2-D MDS of a
  6-condition RDM can be nearly meaningless and must say so.
- Every figure caption carries estimator, sense, channel set, window, and n.

### RS-9 — Headless and batch

RDM export as a step in the batch/replay path, so a study's 40 subjects produce
40 manifests without 40 trips through the UI.

**Exit criteria**
- Deterministic: the same input and parameters produce byte-identical `.1D`
  files. Folds derive from `SeededGenerator` with the seed recorded.
- Runs under `scripts/check-determinism.sh`.
- A group-level convenience script assembles per-subject manifests into a
  `dataTable`/`runwiseTable` skeleton.

---

## 6. Recommended `3dRSA`-side changes

Three small additions would close the remaining gaps from the other end. All are
in `thd_simmatrix.c` / `3dRSA.c` and none change existing behavior.

### 6.1 Honor a declared sense and labels in the 1D header

`mri_read_1D` already retains `#` lines in `comment_buffer` when `save_comments`
is set (`mri_read.c:2213`). `THD_simmat_read_1D` could scan them for:

```
# sense: dissimilarity
# conditions: LC++ RC++ LI++ RI++ Neut Fix
```

and set `sm->is_dist` accordingly, so the advisory at `3dRSA.c:3366` tells the
truth for file-borne models as it already does for built-in rules. ~20 lines.
Absent that, an explicit `-model_mat_dist FFF` (or a `-model_sense dist` modifier
applying to the next `-model_mat`) achieves the same thing with no parsing.

**This is the single highest-value change.** It converts a silent sign error into
a correct message, and it costs almost nothing.

### 6.2 `-model_labels FFF` — assert the condition order

A one-column file of condition names, checked against the `InputFile` sub-brick
labels, erroring on mismatch. Turns the most dangerous class of RSA error — a
plausible, publishable, wrong answer from transposed conditions — into a startup
exit. EVA would emit the file from the same manifest that builds the matrix.

### 6.3 Per-subject `-model_mat` for `-mode RSA`

Today `-mode RSA` uses **one fixed model matrix for every subject**
(`3dRSA.c:3146`), so per-subject EEG RDMs cannot drive per-subject fMRI RDMs.
That is the statistically stronger fusion design — each subject's own EEG
geometry against their own fMRI geometry — and it is what EVA naturally produces.

A `-model_mat_col COLUMN` reading a matrix path per row of the `dataTable`, in
the same spirit as `-model_dset`, would enable it. Scope note: the permutation
scheme is unaffected (classic RSA already tests across subjects by sign flip), so
this is mostly plumbing in the model-construction block, plus validating that
every per-subject matrix satisfies §2.1 at the same dimension.

Until then, EVA exports **both** a group-average RDM (usable now with
`-mode RSA`) and the per-subject RDMs (usable now via `-mode IS-RSA
-featuretype rdm`, and later via 6.3), and the manifest says which is which.

---

## 7. Scientific hazards EVA must state, not hide

1. **Condition count.** RSA earns its keep with dozens of conditions. A typical
   ERP design has 4–8, giving 6–28 unique triangle entries. `3dRSA` refuses below
   6 items; EVA should refuse at the same threshold and, between 6 and about 12,
   say plainly that the geometry is thin. At n = 6 an RDM is close to a
   repackaged table of pairwise contrasts, and correlating it against a model RDM
   is very noisy.
2. **Sensor space is reference-dependent.** The RDM changes with average vs.
   mastoid reference. Volume conduction means channels are not independent
   features, so a Mahalanobis whitening is doing more work than it looks like.
   Record the reference in every export.
3. **Bias from unequal N.** Non-cross-validated distances are inflated ∝ 1/n, so
   the RDM partly encodes how many trials survived rejection. Since EVA's own
   exclusion machinery creates that imbalance, crossnobis is the default wherever
   folds exist, and the per-condition N is always shown.
4. **Filter smearing in time-resolved RDMs.** A 0.1 Hz high-pass and any
   low-pass spread information across latencies, so adjacent time-bin RDMs are
   not independent. The joint time × space FWE family is real, but its effective
   size is smaller than its nominal size. State the filter in the header.
5. **Baseline correction couples conditions.** Baseline subtraction over a shared
   window introduces a common component across conditions and shrinks distances
   slightly. Record the baseline window; do not quietly change it for RSA.
6. **Pooled conditions.** `pooledRelations` already detects that "correct"
   contains "LC++" and "RC++"; such a pair has near-zero distance by construction
   and must never enter an RDM silently.

---

## 8. Open questions

- **Default estimator when folds are unavailable.** A single-block recording with
  no natural boundary can still be folded by trial halves in acquisition order,
  but a 2-fold crossnobis is noisy. Is 2-fold crossnobis or biased correlation
  distance the better default there? Leaning crossnobis-with-a-warning, because
  its bias is zero and its variance is visible, whereas correlation distance's
  bias is invisible.
- **Do we need a `.mat`/`npy` export at all,** or is 1D + JSON sufficient? 1D is
  plain text and reads fine in numpy/R/MATLAB with one line; leaning no.
- **Where does the behavioral covariate table live** — RS-7's importer, or TW-6's?
  They are the same importer and should be built once, but TW-6 is currently
  **DEFERRED**. If RSA is scheduled first, RS-7 pulls the importer forward and
  TW-6 consumes it.
- **Should EVA ever write the `dataTable`/`runwiseTable` itself?** It knows the
  subjects and the condition order, but not the fMRI dataset paths. A skeleton
  with the EEG-side columns filled and the fMRI columns blank is probably the
  right amount of help.
