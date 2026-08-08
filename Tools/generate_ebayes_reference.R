#!/usr/bin/env Rscript
#
# generate_ebayes_reference.R
#
# Writes EVATests/Fixtures/ebayes-thresh-reference.json — golden values for
# EmpiricalBayesThresholdTests, which checks EVA's independent Swift
# implementation of Johnstone & Silverman (2005) empirical Bayes thresholding
# against the authors' own R package.
#
#   Johnstone, I. M. & Silverman, B. W. (2005). "Empirical Bayes selection of
#   wavelet thresholds." The Annals of Statistics 33(4), 1700-1752.
#   EbayesThresh (CRAN), Johnstone & Silverman, GPL (>= 2).
#
# EbayesThresh is used here strictly as an external oracle: this script runs it
# and records its numeric output. The Swift implementation was written from the
# published mathematics and derives nothing from the package's code, so no
# licence obligation attaches to EVA. Do not port from the R sources; if the
# comparison fails, fix the Swift against the paper.
#
# Note the prior: the package defaults to Laplace, MATLAB's wdenoise 'Bayes'
# (and therefore HAPPE, and therefore EVA) uses the quasi-Cauchy, so every call
# below passes prior = "cauchy".
#
# Usage:  Rscript Tools/generate_ebayes_reference.R
#         Rscript -e 'install.packages("EbayesThresh")'   # if not installed

suppressMessages(library(EbayesThresh))

set.seed(20260808)

num <- function(x) paste(sprintf("%.17g", x), collapse = ", ")

# ---- bands -----------------------------------------------------------------
# Each band exercises a different regime of the estimator. "scaled" must come
# out at exactly 137x its unscaled twin: the threshold is equivariant in the
# band's units.
bands <- list()
add <- function(name, x, note) bands[[length(bands) + 1]] <<-
  list(name = name, x = x, note = note)

spike <- function(n, count, amplitude) {
  x <- rnorm(n)
  x[sample.int(n, count)] <- amplitude * sample(c(-1, 1), count, replace = TRUE)
  x
}

add("gaussian-64",    rnorm(64),   "pure noise, short band")
add("gaussian-256",   rnorm(256),  "pure noise")
add("gaussian-1024",  rnorm(1024), "pure noise")
add("gaussian-4096",  rnorm(4096), "pure noise, long band")
add("sparse-1",       spike(1024, 1, 7),    "one outlier in 1024")
add("sparse-5",       spike(1024, 5, 6),    "very sparse")
add("sparse-25",      spike(1024, 25, 5),   "sparse")
add("sparse-100",     spike(1024, 100, 4),  "moderately dense")
add("sparse-400",     spike(1024, 400, 3),  "dense: the spikes inflate the robust sigma until the band standardises back to noise-like")
add("heavy-tailed",   rt(1024, df = 2),     "heavy tails, no discrete spikes")
add("offset-noise",   rnorm(512) + 3,       "noise on a large offset: no coefficient looks null, so the fit saturates at w = 1")

unscaled <- spike(1024, 10, 6)
add("scale-base",   unscaled,       "reference for the scale-equivariance check")
add("scale-137x",   unscaled * 137, "same band, 137x the units")

# ---- per-band reference ----------------------------------------------------
# Mirrors what EVA does: robust sigma by MAD about the median, normalise,
# fit the weight by marginal MLE, convert to the posterior-median threshold,
# rescale into the band's units.
band_json <- vapply(bands, function(b) {
  sigma <- mad(b$x)
  z <- b$x / sigma
  w <- wfromx(z, prior = "cauchy")
  t <- tfromw(w, prior = "cauchy")
  sprintf(
    '    {\n      "name": "%s",\n      "note": "%s",\n      "sigma": %.17g,\n      "weight": %.17g,\n      "normalizedThreshold": %.17g,\n      "threshold": %.17g,\n      "x": [%s]\n    }',
    b$name, b$note, sigma, w, t, sigma * t, num(b$x)
  )
}, character(1))

# ---- scalar relations -----------------------------------------------------
# weight <-> threshold, checked on their own so a failure localises. Kept below
# t ~ 5.5 so both implementations are well inside their search brackets.
thresholds <- c(0.05, 0.25, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, sqrt(2 * log(1024)), 4.5, 5.25)
weights <- c(1e-4, 1e-3, 0.005, 0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 0.7, 0.9, 0.99)

wfromt_json <- vapply(thresholds, function(t) {
  sprintf('    { "t": %.17g, "w": %.17g }', t, wfromt(t, prior = "cauchy"))
}, character(1))

tfromw_json <- vapply(weights, function(w) {
  sprintf('    { "w": %.17g, "t": %.17g }', w, tfromw(w, prior = "cauchy"))
}, character(1))

out <- sprintf(
  '{\n  "generator": "Tools/generate_ebayes_reference.R",\n  "oracle": "EbayesThresh %s (R %s.%s), prior = cauchy",\n  "weightFromThreshold": [\n%s\n  ],\n  "thresholdFromWeight": [\n%s\n  ],\n  "bands": [\n%s\n  ]\n}\n',
  as.character(packageVersion("EbayesThresh")),
  R.version$major, R.version$minor,
  paste(wfromt_json, collapse = ",\n"),
  paste(tfromw_json, collapse = ",\n"),
  paste(band_json, collapse = ",\n")
)

path <- file.path("EVATests", "Fixtures", "ebayes-thresh-reference.json")
if (!dir.exists(dirname(path))) stop("run this from the repository root")
cat(out, file = path)
cat("wrote", path, "\n")
