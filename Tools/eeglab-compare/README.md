# eeglab-compare — EVA vs EEGLAB (MATLAB) parity on shared processing steps

Same goal as `Tools/mne-compare`, against real EEGLAB (via MATLAB) instead of
MNE-Python, on the same real flanker recording. EVA's `.eeglabMNE` FIR design
rule specifically targets EEGLAB's `pop_eegfiltnew`, so this is the direct
check of that claim, plus the same full-pipeline and interpolation checks run
against MNE.

## Running it

EEGLAB has no MFF-import plugin installed here, so the real recording is
exported to `.set` via MNE first:

```bash
/Users/molfesepj/micromamba/envs/mne/bin/python Tools/eeglab-compare/export_eeglab_set.py \
    /path/to/recording.mff
```

Verified by hand: the export carries over real digitized channel positions
(X/Y/Z, sph_theta/phi/radius) and real annotation event types
(LC++/LI++/RI++/RC++/blk+/cue+) — both required for the checks below.
Writes `EVATests/Fixtures/Compare/local/eeglab/full.set` (git-ignored, ~270
MB, real subject EEG).

```bash
/Applications/MATLAB_R2026a.app/bin/matlab -batch "run('Tools/eeglab-compare/run_eeglab_pipeline.m')"
```

Runs EEGLAB's own `pop_eegfiltnew` / `eeg_interp` / `pop_reref` / `pop_epoch`
/ `pop_rmbase`, writing two JSON files next to `full.set`. Then:

```bash
/Users/molfesepj/micromamba/envs/mne/bin/python Tools/eeglab-compare/compare_eeglab.py
```

This reuses EVA's *already-computed* exports
(`EVATests/Fixtures/Compare/local/eva_full_pipeline_erp.json`,
`.../real_reference.json`, from `Tools/mne-compare`) rather than re-running
the Swift side — EVA's pipeline is identical between the MNE and EEGLAB
comparisons, only the reference package changes.

## Results

**Full pipeline** (filter 1-40 Hz → interpolate E82/E66 → average-reference
→ epoch congruent/incongruent → baseline → average, 100 trials/condition,
matching exactly on both sides): relative RMS diff 0.6-0.9%, correlation
>0.99996 — a bit looser than the EVA-vs-MNE full-pipeline result (0.1-0.15%,
`Tools/mne-compare`), fully explained by the interpolation finding below,
diluted across a 128-channel average reference and a 100-trial average.

**Filter, isolated** (1-40 Hz, same 20 s/12-channel window as
`make_real_reference.py`, interior after trimming edge transients):
EEGLAB vs MNE relative RMS diff 1.9%, correlation 0.9998 — same ballpark as
the EVA-vs-MNE filter finding (0.5-1%), consistent with three independent
implementations of the same nominal design (transition width, taps, and
-6dB-at-passband-edge convention all confirmed identical by reading
`pop_eegfiltnew.m` directly: `TRANSWIDTHRATIO=0.25`, `filtorder =
3.3/(df/sfreq)`, `cutoff = edge + df/2`).

**Bad-channel interpolation, isolated — a real, substantial discrepancy.**
Interpolating E50 from the same 12-channel real-electrode window, EEGLAB's
`eeg_interp('spherical')` disagrees with MNE's (and EVA's, already shown
equivalent to MNE at the 1e-6 level) Perrin-spline result by **20-36%
relative RMS, correlation as low as 0.53** — not a rounding-level
discrepancy, a materially different waveform (see
`interpolation_eeglab_default_vs_matched.png`). This holds even feeding
EEGLAB's own `eeg_interp` EVA's exact regularization/order/term-count
(`params = [1e-5 4 40]`), so it isn't just EEGLAB's much softer default
(`lambda=0`, order 4, only **7** Legendre terms vs EVA's 40 / MNE's 50 —
those alone move the answer by 22% relative RMS, from
`eeg_interp.m`'s own header comment).

**Root cause, read directly from `eeg_interp.m`'s nested `computeg`
function:** Perrin's spline (and MNE's `_calc_g`, and EVA's `SphericalSpline.g`)
evaluates the Legendre-polynomial series at `cos(gamma) = dot(unit_i,
unit_j)`, the cosine of the angle between two unit electrode vectors.
EEGLAB's `computeg` instead builds

```matlab
EI = 1 - sqrt((xi-xj)^2 + (yi-yj)^2 + (zi-zj)^2)   % Euclidean chord distance of unit vectors
```

and feeds *that* into `legendre(n, EI)` as if it were `cos(gamma)`. For unit
vectors, `chord = sqrt(2 - 2*cos(gamma))`, so `EI = 1 - sqrt(2-2cos(gamma))`
— a different, nonlinear function of the angle. The two formulas agree only
at the two points where they must (`gamma=0`: chord=0, EI=1=cos; `gamma=180°`:
chord=2, EI=-1=cos) and diverge substantially in between — at 90° separation,
the correct value is `cos(90°)=0`, EEGLAB's substitute gives `1-sqrt(2)
≈ -0.414`. A 12-electrode subset spanning most of the head (as used here)
has plenty of near-90° pairs, which is exactly the regime where this shows up
worst. This is EEGLAB's own long-standing implementation (present verbatim
in `eeg_interp.m`'s `spheric_spline`/`computeg`), not something EVA or MNE
get wrong — but it means **"spherical spline interpolation" is not one
algorithm across packages**, and a bad-channel-heavy analysis pipeline
ported between EEGLAB and EVA/MNE should expect real numeric differences
from this step specifically, not just filter-design noise.

## What's not covered here

- **Average reference and epoch/baseline mechanics** weren't isolated the
  way `Tools/mne-compare` isolates them for MNE (no EEGLAB-specific
  `MNEReferenceTests`-style Swift suite) — only exercised as part of the
  full pipeline above. `pop_reref`/`pop_epoch`/`pop_rmbase` are simple enough
  (mean subtraction; sample-window extraction) that the full-pipeline
  agreement number is a reasonable stand-in, but a real regression in one of
  them specifically wouldn't necessarily be localized by this suite alone.
- **Epoch-length convention**: EEGLAB's `pop_epoch([-0.2 0.8])` produced
  exactly 1000 samples — matching EVA's own (exclusive) convention, *not*
  MNE's inclusive `+1` (see `Tools/mne-compare/README.md`). Worth knowing:
  EVA's epoch-length formula agrees with EEGLAB, not MNE, on this specific
  point, even though EVA's *filter* design targets MNE/EEGLAB's shared
  convention. Not chased further/re-verified beyond this one run.
