# Maintenance Scripts

Three loose scripts in `Tools/`, each for a specific recurring job. Unlike the
Swift tools, these need no build step.

---

## `compare-paired-run.sh` — prove two runs match

```bash
Tools/compare-paired-run.sh <interactive.mff> <headless.mff>
```

Byte-compares two MFF packages produced by the same processing, one run through
the app interactively and one headless. It exists because nothing in the test
suite can prove interactive/headless parity: every divergence this project has
found came from comparing bytes, and **twice the logs agreed while the data did
not**.

What it checks, and how strictly:

| Section | Comparison |
| --- | --- |
| Signal data | `signal1.bin` and `signal2.bin` must be byte-identical. This is the one that matters. |
| Structure | `categories.xml`, `epochs.xml`, `info1.xml`, `coordinates.xml`, `sensorLayout.xml`, `Events_EVA.xml` must be identical. |
| `eva.xml` | Identical after stripping `writtenAt` and `appliedAt` timestamps. |
| Payload sidecars | `eva_ica.json` and `eva_artifacts.json` identical, ignoring `createdAt`. A sidecar present in only one package is a failure — it means the headless output did not carry it forward. |
| `log_eva_*.txt` | Identical after stripping per-line timestamps and the header naming the package. |

Differences that are *expected* — `subject.xml` (the Patient ID is seeded from
the package name), the `eva.xml` timestamps, the log header, and sidecar
`createdAt` — are reported as notes rather than failures.

Exit status is `0` when everything that must match does, `1` when something
differs, and `2` for a usage or access problem. It distinguishes "cannot read
inside this package" from "this package differs", because a permissions problem
masquerading as a parity failure wastes exactly the time the script exists to
save.

It re-executes itself under `bash` if invoked as `sh`, since it uses process
substitution.

---

## `convert_iclabel_to_coreml.py` — rebuild the ICLabel model

```bash
python Tools/convert_iclabel_to_coreml.py \
    --mat /path/to/netICL.mat \
    --output EVA/Models/ICLabel.mlpackage
```

Converts the official ICLabel MatConvNet weights into the Core ML package EVA
uses to auto-label ICA components. Run it only when the upstream network
changes — the converted model is committed, so a normal build does not need it.

Requires `coremltools`, `numpy`, `scipy` and `torch`.

The source `.mat` is the default ICLabel network from
<https://github.com/sccn/ICLabel>. ICLabel is attributed to SCCN and to Luca
Pion-Tonachini, Ken Kreutz-Delgado and Scott Makeig; no upstream license was
found, and the attribution is recorded in `THIRD_PARTY_NOTICES.md`.

---

## `generate_ebayes_reference.R` — regenerate a test fixture

```bash
Rscript Tools/generate_ebayes_reference.R
# If the package is missing:
Rscript -e 'install.packages("EbayesThresh")'
```

Writes `EVATests/Fixtures/ebayes-thresh-reference.json`, the golden values that
`EmpiricalBayesThresholdTests` checks EVA's Swift implementation of Johnstone &
Silverman (2005) empirical Bayes thresholding against.

!!! important "The R package is an oracle, not a source"
    EbayesThresh is GPL. It is used here strictly to *run it and record its
    numbers*. EVA's Swift implementation was written from the published
    mathematics and derives nothing from the package's code, so no license
    obligation attaches. **Do not port from the R sources.** If the comparison
    fails, fix the Swift against the paper.

One detail that trips people up: the R package defaults to a Laplace prior, while
MATLAB's `wdenoise` 'Bayes' option — and therefore HAPPE, and therefore EVA —
uses the quasi-Cauchy. Every call in the script passes `prior = "cauchy"`
accordingly.
