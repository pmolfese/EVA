# Copyleft Provenance and Reimplementation Plan

Internal, uncommitted planning note. This is not a legal opinion and should not
ship as user-facing license text.

The controlling clean-room process is now tracked in `docs/provenance/README.md`.
This file remains the short provenance/risk ledger for copyleft-sensitive
components.

## Status as of 2026-08-09

Two of the tracks described below are **closed**, and the sections about them
record the plan as it stood, not the current state:

- **FASTR / FACET** — closed. `FastrCorrector.swift`, `FastrMetalBackend.swift`
  and `FastrKernels.metal` were deleted after the clean-room replacement passed
  dirty-room behavioral validation. Nothing derived from the reference toolboxes
  ships. See `docs/provenance/README.md` and the audit log's 2026-08-09 entry.
- **AMRI MAS/MAR/wAAS/wAAR** — closed. Replaced by
  `EVA/Gradient/LocalTemplateArtifactCorrector.swift`, written from
  `docs/provenance/amri-functional-spec.md`. The AMRI toolbox is
  cited, not incorporated, and its local copy is git-ignored.
- **`nimh-sfim/gradient_remover`** — the Swift translation was deleted on
  2026-08-09 as dead code once every method routed to a clean-room engine. It
  was never a copyleft item (NIH Government work); it is simply gone.

Still open: ICLabel permission, plus the two HAPPE-adjacent tracks below —
"Wavelet Reduction / HAPPE Configuration Audit" and "Channel Health /
EEGLAB-Like Metrics". Neither has a functional spec of its own; the sections in
this file are their record, alongside `empirical-bayes-port.md` for the wavelet
thresholding numerics.

## Current Working Premises

- EVA's own code is NIH-authored Government work covered by the Public Use /
  Government-work license posture in `LICENSE`.
- `nimh-sfim/gradient_remover` is not an unresolved third-party dependency:
  P. Molfese and Joshua Teves wrote it, and it is covered by the same
  Government-work provenance.
- ICLabel model redistribution permission has been requested. Until that
  permission is granted in writing, keep ICLabel marked as permission-pending in
  `THIRD_PARTY_NOTICES.md`.
- AMRI's local MATLAB files carry GPL-3.0 headers, but the code is also
  Advanced MRI / NINDS / NIH Government work. Treat that GPL marker as a
  provenance issue to verify, not as copied code incorporated into EVA.

## GPL-Version References Seen in Local Reference Trees

- FMRIB FASTR reference: GPL-2.0 text in `resources/fmrib/gpl.txt`.
- FACET reference: GPL-2.0-or-later text in `resources/facet/src/COPYING` and
  project README.
- HAPPE reference: GPL-3.0 text in `resources/HAPPE/LICENSE`.
- AMRI `amri_eeg_gac.m` / `amri_eeg_cbc.m`: headers say GPL-3.0, while also
  identifying NINDS/NIH authorship.
- EbayesThresh numerical oracle: CRAN records GPL >= 2, represented in SPDX
  terms as GPL-2.0-or-later / GPL-3.0-or-later.

## Components To De-Risk

### FASTR / FACET Path

Current status: `EVA/Gradient/FastrCorrector.swift` is explicitly described as
a Swift port of the FASTR/FACET algorithm family. It contains implementation-
specific compatibility behavior such as FACET averaging-window semantics,
second-pass alignment, OBS epoch selection, and ANC options.

Metal status: `EVA/Gradient/FastrMetalBackend.swift` and
`EVA/Gradient/FastrKernels.metal` are GPU accelerators for the same ported
FASTR path. They should be treated as part of the FASTR/FACET tainted surface,
not as independently clean code, even though the kernels themselves are mostly
generic resampling, template, FIR, and OBS linear-algebra operations.

Plan:

1. Write an EVA-owned FASTR specification from papers and observed public
   behavior only: Niazy 2005, Moosmann 2009, van der Meer 2010, and Glaser
   2013. Started in `docs/provenance/fastr-functional-spec.md`.
2. Split compatibility modes into named, testable concepts: trigger epoching,
   donor selection, alignment, template scaling, OBS, and ANC.
3. Reimplement donor selection and alignment from the written specification,
   without consulting FACET/FMRIB source during implementation.
4. Validate against synthetic signals and published method expectations first;
   use reference implementations only as black-box numerical comparators where
   allowed.
5. Replace the Metal backend only after the clean CPU path is selected for app
   wiring. The clean GPU backend should be written from the clean FASTR spec and
   the clean CPU implementation's public behavior, not from `FastrMetalBackend`
   or `FastrKernels.metal`.
5. After rewrite, update the header from "port/reimagining" to "independent
   implementation from literature/specification."

### Wavelet Reduction / HAPPE Configuration Audit

Current status: `EVA/Wavelet/WaveletReducer.swift` is intended to implement
published wavelet-denoising methods and documented MATLAB `wdenoise` behavior.
HAPPE is treated as a cited pipeline/configuration reference, not as
implementation source. The 2026-08-08 audit found no need for a full HAPPE
rewrite, but did identify UI/comment/doc language that should avoid implying
source-level derivation.

Audit result: no clean-room rewrite is currently required. EVA's implementation
is based on published wavelet-denoising literature, documented MATLAB
`wdenoise` behavior, and independently written EVA code. HAPPE remains a cited
pipeline/configuration reference only.

Plan:

1. Keep the implementation anchored to published wavelet methods, MATLAB
   behavior, and independently written tests.
2. Preserve `EmpiricalBayesThreshold.swift` as a math-from-paper implementation;
   use EbayesThresh only as an external oracle for expected numbers.
3. Keep HAPPE-specific defaults and UI text framed as cited configuration
   choices or public method behavior rather than source-code derivation.
4. Add a provenance note to any future tests that use HAPPE as a black-box
   comparator.

### Channel Health / EEGLAB-Like Metrics

Current status: `EVA/Health/ChannelHealthAnalyzer.swift` implements explainable
metrics from FASTER-style channel statistics, with UI/settings references to
HAPPE, EEGLAB `pop_rejchan`, and clean_rawdata `ChannelCriterion`.

Audit result: no clean-room rewrite is currently required. The implementation
appears to use paper/spec-level channel-quality concepts, not translated FASTER,
HAPPE, EEGLAB, or clean_rawdata source code. The local FASTER source is present
only inside the non-distributed HAPPE/EEGLAB reference tree under
`resources/HAPPE/Packages/eeglab2024.0/plugins/FASTER1.2.4/`.

Plan:

1. Keep metric definitions documented as formulas and behavior, not source
   translations.
2. Rephrase comments or UI help that imply code mirroring when only the metric
   concept is intended.
3. Where defaults come from HAPPE/EEGLAB/clean_rawdata, record them as parameter
   choices with literature/tool attribution.
4. Avoid adding any translated MATLAB implementation details unless they are
   independently specified first.

### AMRI MAS/MAR/wAAS/wAAR

Current status: clean-room local-template implementation is complete in
`EVA/Gradient/LocalTemplateArtifactCorrector.swift`; app/UI wiring is
still pending. AMRI's GPL-3.0 header should still be reconciled with the
NINDS/NIH Government-work provenance, but the implementation path no longer
depends on distributing translated AMRI source.

Clean-room spec: `docs/provenance/amri-functional-spec.md`.

Validation status: spec-derived tests exist in
`EVATests/Gradient/LocalTemplateArtifactCorrectorTests.swift`.
Dirty-room black-box compatibility tests exist in
`EVATests/Gradient/LocalTemplateArtifactCompatibilityTests.swift` and
passed on 2026-08-08 with a focused Xcode run.

Plan:

1. Verify AMRI ownership/licensing posture through the NIH/NINDS chain.
2. Wire the clean-room implementation into EVA's UI/pipeline.
3. Keep EVA's implementation documented from papers, this clean-room spec, and
   independently written tests.
4. Replace comments that imply copying with "same-named method" or
   "method-level parity" language.
5. If AMRI provenance is formally cleared, update `THIRD_PARTY_NOTICES.md` to
   remove the ambiguity around its GPL-3.0 header.

## Practical Rule Going Forward

Do not copy, paste, mechanically translate, or line-by-line port GPL reference
code into EVA. When a reference implementation is useful, write an EVA-owned
specification first, implement from that spec in a separate pass, and use the
reference only as a black-box comparator or citation source.
