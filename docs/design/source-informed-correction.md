# Source-informed artifact correction — design reference

The Berg–Scherg surrogate-source model behind PCA-S and MSEC, and the contracts
every source-informed correction in EVA must meet. Shipped for broadband BCG in
SI-3; the reference implementation for SI-5 onward.

**Status is in `ROADMAP.md` § Processing & Cleaning (SI-4 and later methods) and
`ROADMAP_COMPLETE.md` (SI-0 … SI-3).**

---

**Decision (2026-08-25):** independently implement the surrogate-source filter
already evaluated in EVASimulate, beginning with broadband BCG PCA-S. Do not
begin with a GEDAI-shaped generalized-eigenvalue pipeline. Treat GEVD and other
methods as separately named comparators with their own truth-backed use cases.

This project ends at a cleaned sensor-space recording. Full distributed source
imaging remains a separate EVA Resolve question; see `SOURCE_ANALYSIS.md`.

### Method and scientific rationale

“Surrogate” means the Berg–Scherg multiple-source family, not surrogate
time-series data. The recording is modeled as a simultaneous mixture:

```text
X ≈ B S + A U
```

- `B`: plausible brain topographies from free-orientation regional dipoles.
- `A`: a small empirically estimated artifact-topography dictionary.
- `S`, `U`: fitted brain and artifact time courses.

The brain block is regularized; the artifact block is not. The filter then
reconstructs only `B S`, yielding one inspectable channels × channels operator.
This asymmetry—not an inability of `B` to span the sensor space—is the separation
mechanism. Brain regularization, artifact component count, reference, channel
selection, and head-model mismatch are scientific parameters to measure.

Direct precedents include ocular MSEC (Berg & Scherg 1991/1994), ongoing
ocular/cardiac correction (Ille, Berg & Scherg 2002), TMS correction (Litvak et
al. 2007), and EEG-fMRI BCG PCA-S/ICA-S (Rusiniak et al. 2022). These are
correction filters, not complete artifact detectors: beat, blink, saccade, or
TMS-event detection supplies epochs/topographies upstream.


### Mandatory contracts

- **Geometry:** one ordered `ElectrodeGeometry` value must reach interactive and
  headless paths. Missing/incomplete geometry fails by default; an approximate
  montage is an explicit, audited opt-in.
- **Channels/reference:** construct and apply over the exact good EEG subset and
  matching reference. Never include PNS rows or silently mix reference models.
- **Invalidation/accounting:** publish to `bcg.correctedSignal`, use shared
  `PipelineInvalidation`, and maintain a `CleaningVarianceAccount` named
  `surrogateSeparation` for the output lifetime.
- **Replay/provenance:** add `bcgCorrection`; portable settings and fitted,
  recording-specific results must remain distinct.
- **Headless parity:** `ProcessingCore`, Copy Processing, windowed use, and the
  regression corpus call the same engine. A sheet-only path is incomplete.

Every contract above is met by SI-3 for BCG and is the reference implementation
for SI-5 onward; its record is C13 in `ROADMAP_COMPLETE.md` § 2.

SI-0 through SI-3 are complete, as is the RW-1 history/replay hardening they fed
into: the shared numerical layer, the app boundary, and the first shipped
source-informed correction. Their records are in
`ROADMAP_COMPLETE.md` § 2; what remains here is measurement (SI-4)
and the later methods below.

