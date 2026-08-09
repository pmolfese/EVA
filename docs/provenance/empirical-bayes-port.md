# Implementing empirical Bayes thresholding

Status: **implemented**, 2026-08-08 — `EVA/Wavelet/EmpiricalBayesThreshold.swift`,
and the Reducer's default threshold model. Validated against the authors' R
package; see "How it was actually done" at the end of this document, which
supersedes the forward-looking instructions above it wherever they differ.

The route taken was the licence-free one this document recommended weighing
first: **implemented from the paper alone**, with EbayesThresh used only as an
oracle for test fixtures. EVA takes on **no copyleft obligation**, `LICENSE`
section 3 and `THIRD_PARTY_NOTICES.md` still correctly state that EVA
incorporates no copyleft code, and no file carries an SPDX marker.

The rest of the document is kept as written, because the constraints in
"Licensing constraints" are permanent and apply to anyone revisiting this code.

Read the whole of "Licensing constraints" before opening any source.

---

## Why this is wanted

EVA's Wavelet Artifact Reducer uses wavelet decomposition, per-level
thresholding, reconstruction, and subtraction. HAPPE is useful context because
its public pipeline configuration calls MATLAB's `wdenoise` with
`'DenoisingMethod','Bayes'` and subtracts the denoised reconstruction as its
artifact estimate; EVA should match the public method behavior without treating
HAPPE source as implementation material.

`'Bayes'` there means the **Johnstone–Silverman empirical Bayes** method — a
sparse mixture prior fitted per level by marginal maximum likelihood. It is
*not* BayesShrink, despite the name. The two adapt in opposite directions on
artifact-laden EEG:

- **Empirical Bayes** treats artifacts as sparse outliers, fits a small mixing
  weight, and lands the threshold several σ out — so only genuine artifacts get
  subtracted and the ongoing EEG survives.
- **BayesShrink** (`T = σ_n² / σ_s`) sees the artifacts inflate the observed
  variance, drives `σ_s` up and `T` toward zero, and classifies nearly the whole
  band as artifact. The dirtier the data, the more real EEG it destroys. This
  was the original "the reducer just oversmooths everything" bug.

The universal threshold (MAD σ · √(2 ln N)) behaves similarly to empirical
Bayes in the sparse regime and is a reasonable stand-in, but it is a fixed rule
rather than one fitted to each band.

## Licensing constraints — read this first

A previous attempt implemented this by reading MATLAB's Wavelet Toolbox
internals under `/Applications/MATLAB_R2026a.app/toolbox/wavelet/` and porting
them. **That work was removed and must not be repeated.** MATLAB's
`license_agreement.txt` prohibits it explicitly:

- **§3.1** — creating a derivative work of a Program.
- **§3.2** — "developing, producing, or testing a computer program containing a
  feature or functionality that is substantially similar **in its expression**
  to the expression contained in a Program."
- **§3.3** — attempting to gain access to its method of operation or source code.
- **§3.4** — "adapt, translate, copy, convert, use, **test, benchmark** … in
  order to make or distribute an application … a principal purpose of which is
  to perform the same or similar functions as a Program."

§3.4 also rules out generating golden test vectors by calling MATLAB internals
(`wavelet.internal.*`) to validate a reimplementation. That is not a loophole;
it is named in the clause.

### Do

- Work from **EbayesThresh** (CRAN), licensed **GPL (>= 2)**, authored by
  Silverman — the original author of the method. MathWorks' own file headers
  state their version is a port of this package, so it is the upstream source.
- Work from the paper: Johnstone, I. & Silverman, B. (2005), *EbayesThresh: R
  Programs for Empirical Bayes Thresholding*, **Journal of Statistical
  Software** 12(1), pp. 1–38. Equation (9) gives the quasi-Cauchy marginal.
- Cite both in the code.

### Do not

- Do not open, read, or consult anything under
  `/Applications/MATLAB_R2026a.app/toolbox/`.
- Do not run MATLAB to produce reference values for tests.
- Do not name MATLAB internal functions in comments. Citing the *public* API
  (`wdenoise`, its documented `DenoisingMethod`/`ThresholdRule` options) is fine
  and factual — that is public documentation, and describing what HAPPE calls is
  necessary context.

### Auditing the result

Audit **positively, against the permitted source**: every constant, bracket,
iteration count, termination test, and choice of algebraic form in the finished
implementation should be traceable to a specific line of `EbayesThresh/R/*.R` or
to an equation in the paper. Anything you cannot point at came from somewhere
else, and that is the thing to investigate.

Deliberately audit the *arbitrary* choices, not the mathematical ones. Two
implementations of the same estimator must agree on the mathematics, so
agreement there proves nothing. Where they can differ freely — a search
bracket's upper bound, how many bisections, whether a loop stops on a tolerance
or a fixed count, which of two algebraically identical expressions gets written
down — matching is evidence of copying rather than of competence. Those choices
carry no mathematical content, which is exactly what makes them copyrightable
expression.

Do not audit by diffing against the MATLAB implementation. That requires reading
it, which is the thing being avoided.

## Getting the R reference

R is already installed on this machine (`/opt/homebrew/bin/R`). You do not need
to install the package into R to read it — the source tarball is enough:

```bash
curl -O https://cran.r-project.org/src/contrib/EbayesThresh_1.4-12.tar.gz
tar xzf EbayesThresh_1.4-12.tar.gz
```

Confirm the license before relying on it:

```bash
grep -i "^License" EbayesThresh/DESCRIPTION    # expect: GPL (>= 2)
```

The upstream repository is <https://github.com/stephenslab/EbayesThresh>, and
the JSS paper is open access.

### The files that matter

Everything needed is in `EbayesThresh/R/`. For the **Cauchy** prior (the one
`wdenoise` uses — note the package's own default is Laplace, so pass
`prior = "cauchy"` when generating references):

| File | Role |
|---|---|
| `beta.cauchy.R` | β(x) = g(x)/φ(x) − 1, the quasi-Cauchy marginal ratio |
| `wfromt.R` | weight implied by a given threshold (the `"c"` branch) |
| `wfromx.R` | marginal-MLE mixing weight from the data |
| `cauchy.threshzero.R` | objective whose root is the posterior-median threshold |
| `tfromw.R` | threshold from weight (the `"c"`, non-`bayesfac` branch) |
| `vecbinsolv.R` | the bisection helper `tfromw` uses |
| `ebayesthresh.R` | the driver — shows how σ, weight, and rule compose |
| `ebayesthresh.wavelet.dwt.R` | how it is applied per DWT level |

Read those directly. This document deliberately does not reproduce their code:
copying it here would make this file a derivative work and pull GPL obligations
onto the doc itself.

## What to implement

The shape of the estimator, so you know what you are looking at. Per **detail
level**, independently (HAPPE passes `'NoiseEstimate','LevelDependent'`):

1. Estimate the level's noise σ robustly. R uses its built-in `mad()`, which is
   the median absolute deviation *about the median*, scaled by 1.4826. Note this
   differs slightly from EVA's existing `WaveletReducer.robustSigma`, which uses
   median(|x|) and assumes a zero-centred band — close on real detail
   coefficients, but not the same estimator. Decide deliberately which to use
   and say why.
2. Normalise the band by σ, so the coefficients have unit noise variance.
3. Fit the mixing weight `w` by marginal maximum likelihood: find the root of
   `S(w) = Σ β(xᵢ)/(1 + w·β(xᵢ))`, searched between a lower bound derived from
   the universal threshold and 1, bisecting on the geometric mean. Handle the
   two degenerate cases where the root lies outside the bracket.
4. Convert `w` into a threshold by finding where the posterior median first
   becomes zero.
5. Return σ × that, so the gate is in the band's own units and callers can apply
   it exactly like the existing models.

Steps 3 and 4 are both one-dimensional root-finds on monotone functions; R does
both by plain bisection with fixed iteration counts.

## Wiring into EVA

The existing threshold machinery already has the right shape — one scalar gate
per band — so this drops in:

- Add a case to `WaveletCleaningThresholdModel` (`EVA/Wavelet/WaveletModels.swift`).
- Dispatch to it from `WaveletReducer.coefficientThreshold(for:model:populationCount:)`.
  Honour `populationCount`: the GPU path estimates from a strided subsample, and
  the universal lower bound needs the *full* band length as its N. The MLE root
  itself is unaffected by subsampling, since scaling `S(w)` by a constant does
  not move its root.
- `WaveletArtifactAnalyzer.coefficientThreshold` has a parallel `Float` switch
  that must handle the new case too, or the Explorer's picker will silently mean
  something different from the Reducer's.
- Consider making it the Reducer's default in
  `WaveletReductionMode.defaultConfiguration`. Leave the **Explorer**'s default
  (`WaveletCleaningPipeline.defaultThresholdModel`) alone unless asked — that
  seeds detection, not subtraction, and its current behaviour is tuned.

## Validating it

Generate golden vectors **from R**, which its GPL licence expressly permits.
Something like:

```bash
Rscript -e 'install.packages("EbayesThresh", repos="https://cloud.r-project.org")'
```

then a small script that, for a spread of bands, writes out the fitted weight
and threshold from `wfromx`/`tfromw` with `prior = "cauchy"`. Put the generator
in `tools/` and the fixture in `EVATests/Fixtures/`.

**Do not put a `.m` file anywhere under `EVATests/`** — Xcode picks it up and
compiles it as Objective-C. (An `.R` file is fine, but `tools/` is the right home
for generators regardless.)

Worth covering: pure Gaussian noise at several band lengths, sparse spikes at
several densities, a heavy-tailed band, and a scaled band (the threshold must
scale linearly with the data). Alongside the golden comparison, pin the
behavioural properties that motivated the work — on pure noise the gate should
land several σ out and keep almost nothing; sparse outliers should clear it; and
it should sit far above BayesShrink's gate on an artifact-heavy band.

Also worth checking once implemented, on a real recording: HAPPE typically
retains roughly 70–97% of variance. See `MEMORY.md` for the 129-channel flanker
file that prompted this work.

## Attribution required

EbayesThresh is GPL (>= 2). If EVA ships an implementation derived from it:

- Keep the authors' copyright notice and add an entry to `THIRD_PARTY_NOTICES.md`.
- Cite Johnstone & Silverman (2005) in the source file.
- Mark the file — and only that file — with `SPDX-License-Identifier: GPL-3.0-only`
  (or `GPL-2.0-or-later`, matching upstream). EbayesThresh is GPL-2-**or-later**,
  which upgrades cleanly to GPL-3, so either is available. EVA's source files
  otherwise carry no SPDX marker by design: an unmarked file is
  Government-authored and unrestricted.

**This would be EVA's first copyleft component.** `LICENSE` section 3 and the
"Copyleft components" section of `THIRD_PARTY_NOTICES.md` both currently state
that EVA incorporates none; both need updating in the same change. More
importantly, copyleft can govern the distribution of the whole application, so
this is a decision about how EVA ships, not just about one file — confirm it is
wanted before starting, and flag it for whoever handles software release.

An alternative worth weighing first: implement from the **paper alone**
(Johnstone & Silverman 2005 gives the quasi-Cauchy marginal in equation (9) and
the estimator in full). A genuinely independent implementation from the
published mathematics carries no licence obligation at all, and keeps EVA
copyleft-free. The R package would then serve only as a source of validation
data, which its licence permits regardless.

---

## How it was actually done

The paper-only route. Sources consulted: Johnstone & Silverman (2005), *Ann.
Statist.* 33(4), 1700–1752 — §1.3 (the constrained MML weight and the universal
upper limit), §2.2 (the score function, eq. 17–18; the posterior-median
condition, eq. 16), §2.3 (the quasi-Cauchy closed forms for `g` and `F̃₁`).
**Neither `EbayesThresh/R/*.R` nor anything under MATLAB's toolbox was opened.**

### The two derivations the code evaluates

Both are in the implementation's header in full. Neither appears in the paper in
the form used; they are reductions of the published expressions:

1. `β(z) = (e^(z²/2) − 1)/z² − 1`, from `g(z)/φ(z) − 1`. Factoring the weight
   out of eq. (17) as `β(z,w) = β(z)/(1 + w·β(z))` is what lets the fit
   precompute one β per coefficient and reuse it for every candidate `w`.
2. The threshold equation `w·e^(z²/2)·A(z) = ½(1 − w)z²` with
   `A(z) = Φ(z) − ½ − zφ(z)`, from substituting `g` and `F̃₁(0|z)` into the
   boundary case of eq. (16) and clearing common factors. Solving the same
   equation for `w` gives `w(t) = t²/(t² + 2e^(t²/2)A(t))` in closed form, which
   is where the lower end of the weight bracket comes from — no second
   root-find.

### σ: MAD about the median

`EmpiricalBayesThreshold.robustSigma` uses median absolute deviation about the
median × 1.4826, *not* `WaveletReducer.robustSigma`'s median(|x|)/0.6745. The
band is not re-centred — only the scale is estimated. Rationale is in the
function's doc comment; the practical driver is that the fit reads sparsity off
the shape of the standardised band, so it is more sensitive to the
normalisation than a fixed rule is, and the fixture confirms exact agreement
with R's `mad()` to 1e-12 on every band.

### Arbitrary choices, declared

The audit this document asks for, done positively: these carry no mathematical
content, so they are where copying would show. Each was chosen for the stated
reason, and any implementation converging to the same roots is free to differ.

| Choice | Value | Why |
|---|---|---|
| Weight search space | `ln w` | The bracket's lower end is ≈ 2 ln N / N and the sparse solutions sit near it; a linear bisection would spend its iterations in the wrong decade. Bisecting `ln w` is the geometric mean of the bracket — which this document notes R also does. Same reason, presumably; the root is the same either way. |
| Weight iterations | 96 halvings, no tolerance test | Far inside double precision for any N; a fixed count keeps the per-band cost predictable, which matters because this runs per level per window per channel. |
| Threshold iterations | 64 halvings, no tolerance test | Same reasoning; 64 takes a bracket of ~6 below double precision. |
| Threshold bracket | `[0, √(2 ln N)]` | The upper end is the estimator's own constraint from §1.3, so no wider bracket is meaningful. `z = 0` is a root of the objective as written, so the low end is never evaluated — only strictly positive midpoints. |
| `A(z)` for small z | series below z = 0.05, four terms | Measured, not guessed: the closed form loses ~log₁₀(3/z²) digits to cancellation, which is only ~3 digits at 0.05. An earlier switch at 0.35 was *worse* than the closed form by six orders of magnitude and the fixture caught it. |
| β overflow | `.infinity` above z²/2 = 700, contributing its limit 1/w to the score | Keeps a huge coefficient from turning the whole score into NaN. |
| Saturated fit (`w = 1`) | returns 0 = "no estimate"; callers fall back to the universal threshold | The mathematics gives a threshold of 0 there, which in EVA's subtract-what-clears-the-gate paradigm would subtract the entire band. R reports the floor of its own search bracket (1e-5) instead, which is equally arbitrary. |

### Validation

- `Tools/generate_ebayes_reference.R` → `EVATests/Fixtures/ebayes-thresh-reference.json`
  (13 bands + the two scalar relations, `prior = "cauchy"`).
- `EVATests/Wavelet/EmpiricalBayesThresholdTests.swift` compares σ (1e-12),
  `w(t)` (1e-11), `t(w)` (1e-6), the fitted weight (1e-6), and the full
  band → threshold pipeline (1e-6), and pins the behavioural properties: pure
  noise gates exactly at the universal threshold and keeps <1% of coefficients;
  sparse spikes clear the gate and little else does; the gate sits >2× above
  BayesShrink's on an artifact-heavy band; and end to end, on a channel whose
  EEG and blinks are known separately, empirical Bayes recovers the EEG with
  less error than BayesShrink.
- Still open: the check on a real recording (HAPPE retains ~70–97% of variance)
  against the 129-channel flanker file.
