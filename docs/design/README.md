# EVA — design documents

These are **method and design references**, not status files. They hold the
material that stays true regardless of what is scheduled: equations, file-format
contracts, algorithm specifications, licence surveys, and the reasoning behind
decisions already taken.

**`ROADMAP.md` decides priority and what is left to do. `ROADMAP_COMPLETE.md`
records what shipped.** If a document here disagrees with either about whether
something is done, the roadmap files are right.

| Document | What it holds |
|---|---|
| [`source-informed-correction.md`](source-informed-correction.md) | The Berg–Scherg surrogate-source model behind PCA-S/MSEC, and the contracts every source-informed correction must meet. |
| [`head-models.md`](head-models.md) | Why EVA Resolve imports BEM/FEM head models instead of building them, and the licensing boundary that follows. |
| [`source-analysis.md`](source-analysis.md) | The 2026 brainstorm that led to EVA Resolve: head-model tiers, forward/inverse options, and a public-code licence survey. Largely superseded — read the banner. |
| [`trial-level-analysis.md`](trial-level-analysis.md) | The RIDE port plan and the `.eva` interchange-package design. Unbuilt — read the banner. |
| [`rhythmicity.md`](rhythmicity.md) | LAVI, ABBA, WTPL and burst analysis: definitions, kernel conventions, data contracts, UI specification, validation strategy, and risk register. |
| [`sleep-eeg.md`](sleep-eeg.md) | The literature the synthetic-sleep model is built on, and the design decisions already settled. |
| [`rsa.md`](rsa.md) | The `3dRSA` interchange contract, its two traps, the estimator ladder, and the scientific hazards RSA must state. |
| [`metal-acceleration.md`](metal-acceleration.md) | The June 2026 GPU-porting audit: eligibility rubric and per-area option matrix. |

Documents absorbed into the roadmap files and deleted: `LAVI.md`, `SLEEP.md`,
`EVA_RESOLVE.md`, `EVA_RESOLVE2.md`, `RSA_PLAN.md`, `SOURCE_ANALYSIS.md`,
`metal_options.md` (2026-09-11), following `REWIND.md`, `TRIALWISE.md` and
others before them.
